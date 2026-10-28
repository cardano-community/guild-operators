#!/usr/bin/env bash
# Durable KES rotation. Counter consumption never rolls back on failure.
# shellcheck disable=SC2034,SC2015
CNTOOLS_KES_DIRECTORY='' CNTOOLS_KES_STAGE='' CNTOOLS_KES_BUSY=''
CNTOOLS_KES_INDEX=0 CNTOOLS_KES_START='' CNTOOLS_KES_NEXT='' CNTOOLS_KES_LEDGER=''
CNTOOLS_KES_SOURCE='' CNTOOLS_KES_KIND='' CNTOOLS_KES_CURRENT='' CNTOOLS_KES_PERIOD_SOURCE=''
CNTOOLS_KES_COUNTER_APPROVED=N CNTOOLS_KES_INSTALL_APPROVED=N CNTOOLS_KES_DISK_NEXT='' CNTOOLS_KES_COUNTER_SOURCE=''
CNTOOLS_KES_ISSUED=N CNTOOLS_KES_LOCK_PATH='' CNTOOLS_KES_LOCK_KIND='' CNTOOLS_KES_LOCK_STAGED='' CNTOOLS_KES_LOCK_CERT=N CNTOOLS_KES_LOCK_RELEASABLE=N
CNTOOLS_KES_LOCK_CERT_COUNTER='' CNTOOLS_KES_LOCK_BUSY=N CNTOOLS_KES_ENCRYPTED=N

cntools_kes_error() { cntools_pool_write_error "$1"; }

cntools_kes_stage_safe() {
  local directory='' mode='' recovery=''
  cntools_state_path_into recovery recovery && [[ "${CNTOOLS_KES_STAGE}" == "${recovery}/kes-"* ]] || return 1
  for directory in "${CNTOOLS_KES_STAGE}" "${CNTOOLS_KES_STAGE}/original" "${CNTOOLS_KES_STAGE}/request" "${CNTOOLS_KES_STAGE}/replacement"; do
    cntools_pool_directory_writable "${directory}" && cntools_filesystem_mode_into mode "${directory}" &&
      [[ "${mode}" == 700 || "${mode}" == 0700 ]] || return 1
  done
}

cntools_kes_environment() {
  local help=''
  cntools_transaction_require_cli && cntools_transaction_require_signature_tools && cntools_pool_filenames_validate || return 1
  help="$(LC_ALL=C mv --help 2>&1)" || return 1
  [[ "${help}" == *--no-target-directory* ]] || { cntools_kes_error 'KES rotation requires GNU mv for safe file replacement.'; return 1; }
}

cntools_kes_identity() {
  local index="$1" cold='' counter='' signing='' hardware='' derived=''
  CNTOOLS_POOL_WRITE_ERROR='' CNTOOLS_POOL_WRITE_WARNING=''
  CNTOOLS_KES_INDEX="${index}" CNTOOLS_KES_DIRECTORY="${CNTOOLS_POOL_DIRECTORIES[index]}"
  CNTOOLS_KES_SOURCE='' CNTOOLS_KES_KIND='' CNTOOLS_KES_ENCRYPTED=N
  [[ "${CNTOOLS_POOL_IDENTITIES[index]}" == 'Verified cold public key' ]] &&
    cntools_pool_directory_writable "${CNTOOLS_KES_DIRECTORY}" || {
    cntools_kes_error 'A safe, owned, writable pool directory with a verified cold identity is required.'; return 1;
  }
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into counter counter
  cntools_pool_file_name_into signing cold-skey; cntools_pool_file_name_into hardware cold-hardware
  cntools_pool_counter_into CNTOOLS_KES_NEXT "${CNTOOLS_KES_DIRECTORY}/${counter}" "${CNTOOLS_KES_DIRECTORY}/${cold}" || {
    cntools_kes_error 'The original issue counter is missing, invalid or belongs to another pool. Restore the real counter; never reset it.'; return 1;
  }
  CNTOOLS_KES_DISK_NEXT="${CNTOOLS_KES_NEXT}" CNTOOLS_KES_COUNTER_SOURCE='cold.counter'
  if [[ -e "${CNTOOLS_KES_DIRECTORY}/${hardware}" || -L "${CNTOOLS_KES_DIRECTORY}/${hardware}" ]]; then
    [[ ! -e "${CNTOOLS_KES_DIRECTORY}/${signing}" && ! -e "${CNTOOLS_KES_DIRECTORY}/${signing}.gpg" ]] &&
      cntools_pool_hardware_pair_validate "${CNTOOLS_KES_DIRECTORY}" || {
      cntools_kes_error 'Resolve mixed or invalid cold hardware material before rotation.'; return 1;
    }
    CNTOOLS_KES_SOURCE="${CNTOOLS_KES_DIRECTORY}/${hardware}" CNTOOLS_KES_KIND=hardware
  elif [[ -e "${CNTOOLS_KES_DIRECTORY}/${signing}" || -L "${CNTOOLS_KES_DIRECTORY}/${signing}" ]]; then
    [[ ! -e "${CNTOOLS_KES_DIRECTORY}/${signing}.gpg" ]] || {
      cntools_kes_error "Both ${signing} and ${signing}.gpg exist. Keep only one of them before rotating."; return 1;
    }
    cntools_pool_key_validate "${CNTOOLS_KES_DIRECTORY}/${signing}" cold signing &&
      cntools_transaction_source_kind_into CNTOOLS_KES_KIND "${CNTOOLS_KES_DIRECTORY}/${signing}" || {
      cntools_kes_error "The cold signing key ${signing} is invalid or unsafe (it must be a private, regular file)."; return 1;
    }
    cntools_transaction_temp_file derived kes-cold-public || return 1
    cntools_pool_cli key verification-key --signing-key-file "${CNTOOLS_KES_DIRECTORY}/${signing}" --verification-key-file "${derived}" &&
      jq -es 'length == 2 and (.[0].cborHex|ascii_downcase) == (.[1].cborHex|ascii_downcase)' \
        "${derived}" "${CNTOOLS_KES_DIRECTORY}/${cold}" >/dev/null || {
      cntools_kes_error 'The cold signing key does not match this pool.'; return 1;
    }
    CNTOOLS_KES_SOURCE="${CNTOOLS_KES_DIRECTORY}/${signing}"
  elif [[ -f "${CNTOOLS_KES_DIRECTORY}/${signing}.gpg" && ! -L "${CNTOOLS_KES_DIRECTORY}/${signing}.gpg" ]]; then
    # Present but encrypted: Pool → Decrypt makes it usable here.
    CNTOOLS_KES_ENCRYPTED=Y
  fi
}

cntools_kes_period_collect() {
  local genesis="${CNTOOLS_SHELLEY_GENESIS:-}" slots="${CNTOOLS_SLOTS_PER_KES_PERIOD:-}" tip=''
  CNTOOLS_KES_CURRENT='' CNTOOLS_KES_PERIOD_SOURCE=''
  if [[ -z "${slots}" ]] && cntools_pool_public_file_safe "${genesis}" 1048576; then
    slots="$(jq -r '.slotsPerKESPeriod // empty' "${genesis}")"
  fi
  [[ "${slots}" =~ ^[1-9][0-9]{0,9}$ && "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  if cntools_transaction_local_backend_ready && cntools_funding_tip_into tip local; then
    CNTOOLS_KES_PERIOD_SOURCE='Local node'
  elif [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y ]] && cntools_funding_tip_into tip koios; then
    CNTOOLS_KES_PERIOD_SOURCE='Koios API'
  else return 0; fi
  CNTOOLS_KES_CURRENT=$((tip / slots))
}

# With a ledger counter (local node or Koios), the next certificate always uses
# the ledger counter + 1, whatever cold.counter holds.
cntools_kes_counter_from_ledger() {
  local ledger="${CNTOOLS_POOL_CERT_CHAIN[CNTOOLS_KES_INDEX]:-}"
  [[ "${ledger}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  CNTOOLS_KES_NEXT=$((ledger+1)) CNTOOLS_KES_COUNTER_SOURCE='Ledger counter + 1'
}

cntools_kes_counter_guard() {
  local index="${CNTOOLS_KES_INDEX}" cert='' cold='' disk=''
  CNTOOLS_KES_LEDGER="${CNTOOLS_POOL_CERT_CHAIN[index]:-}"
  [[ "${CNTOOLS_KES_NEXT}" =~ ^(0|[1-9][0-9]{0,9})$ ]] && ((CNTOOLS_KES_NEXT < 2147483647)) || return 1
  if [[ -n "${CNTOOLS_KES_LEDGER}" ]]; then
    [[ "${CNTOOLS_KES_LEDGER}" =~ ^(0|[1-9][0-9]{0,9})$ ]] && ((CNTOOLS_KES_NEXT == CNTOOLS_KES_LEDGER+1)) || {
      cntools_kes_error "The issue counter must be the ledger counter + 1 ($((CNTOOLS_KES_LEDGER+1))), not ${CNTOOLS_KES_NEXT}. Nothing was issued."; return 1;
    }
    return 0
  fi
  [[ "${CNTOOLS_KES_COUNTER_APPROVED}" == Y ]] || {
    cntools_kes_error 'The ledger counter is unavailable. Enter and approve the issue counter before proceeding.'; return 1;
  }
  # Without a ledger, never issue below the certificate already installed.
  # Only its cold-key binding counts: it may certify another KES key than
  # hot.vkey (a rotation outside CNTools), which this rotation replaces.
  cntools_pool_file_name_into cert opcert; cntools_pool_file_name_into cold cold-vkey
  if [[ -e "${CNTOOLS_KES_DIRECTORY}/${cert}" || -L "${CNTOOLS_KES_DIRECTORY}/${cert}" ]]; then
    cntools_pool_opcert_cold_counter_into disk "${CNTOOLS_KES_DIRECTORY}/${cert}" "${CNTOOLS_KES_DIRECTORY}/${cold}" || {
      cntools_kes_error "${cert} was not issued by this pool's cold key or is unreadable, so the issue counter cannot be checked against it. Move it out of the pool folder, then rotate again. Nothing was issued."; return 1;
    }
    ((CNTOOLS_KES_NEXT >= disk)) || {
      cntools_kes_error "The issue counter is below the counter of the installed certificate (${disk}). Nothing was issued."; return 1;
    }
  fi
}

cntools_kes_counter_recheck() {
  if [[ "${CNTOOLS_MODE:-offline}" != offline ]]; then
    cntools_pool_inspect_catalog "${CNTOOLS_KES_INDEX}" && cntools_pool_health_collect "${CNTOOLS_KES_INDEX}" || return 1
  fi
  cntools_kes_counter_guard
}

cntools_kes_phase_set() {
  local phase="$1" file=''
  cntools_kes_stage_safe || return 1
  [[ ! -L "${CNTOOLS_KES_STAGE}/phase" && ! -d "${CNTOOLS_KES_STAGE}/phase" ]] || return 1
  file="$(mktemp "${CNTOOLS_KES_STAGE}/.phase.XXXXXX")" || return 1
  printf '%s\n' "${phase}" > "${file}" && chmod 0600 "${file}" && mv -Tf -- "${file}" "${CNTOOLS_KES_STAGE}/phase" || return 1
  cntools_transaction_log POOL "KES phase=${phase} recovery=${CNTOOLS_KES_STAGE}"
}

cntools_kes_lock_acquire() {
  local prefix="$1" lock='' recovery='' saved=''
  ! cntools_pool_legacy_opcert_lock "${CNTOOLS_KES_DIRECTORY}" || {
    cntools_kes_error "An earlier CNTools build left an operational-certificate lock in ${CNTOOLS_KES_DIRECTORY}/.cntools-opcert-lock. Finish or inspect that operation manually; no new certificate was issued."; return 1;
  }
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" && cntools_state_directory_into recovery recovery || {
    cntools_kes_error 'The owner-only CNTools state folder (.cntools in the node home) is unavailable.'; return 1;
  }
  saved="$(umask)"; umask 077
  if ! mkdir -- "${lock}" 2>/dev/null; then
    umask "${saved}"; cntools_kes_error 'An operational-certificate operation is pending. Continue it or inspect its recovery files; do not issue another certificate.'; return 1
  fi
  CNTOOLS_KES_STAGE="$(mktemp -d "${recovery}/kes-${prefix}.XXXXXX")" || { umask "${saved}"; rmdir -- "${lock}"; return 1; }
  umask "${saved}"
  printf '%s\n' "${CNTOOLS_KES_STAGE##*/}" > "${lock}/rotation" && mkdir -m 700 -- "${lock}/busy" || {
    rm -f -- "${lock}/rotation"; rmdir -- "${lock}" 2>/dev/null; return 1;
  }
  CNTOOLS_KES_BUSY="${lock}/busy"
}

# A failure before any certificate was issued releases the lock so a retry
# can start; the recovery folder is kept for inspection.
cntools_kes_unlock_unissued() {
  cntools_kes_lock_release || return 1
  CNTOOLS_POOL_WRITE_ERROR="${CNTOOLS_POOL_WRITE_ERROR:-${CNTOOLS_TRANSACTION_ERROR:+${CNTOOLS_TRANSACTION_ERROR} }Preparation failed before any certificate was issued.} The lock was released and the recovery folder kept, so you can retry."
  cntools_transaction_log POOL "KES lock released; nothing was issued recovery=${CNTOOLS_KES_STAGE}"
}

# True for a lock that is not a node-side rotation request: a first
# operational certificate (opcert-*), an offline signing (kes-sign.*) or an
# unrecorded one.
cntools_kes_lock_foreign() {
  local lock=''
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" || return 1
  cntools_pool_public_file_safe "${lock}/rotation" 128 && [[ "$(< "${lock}/rotation")" =~ ^kes-rotate\.[A-Za-z0-9]+$ ]] && return 1
  return 0
}

# True for this node's own rotation lock left without a phase file: the
# session ended while preparing, before anything could be issued.
cntools_kes_lock_interrupted() {
  local lock='' recovery='' name=''
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" && cntools_state_path_into recovery recovery &&
    cntools_pool_public_file_safe "${lock}/rotation" 128 || return 1
  name="$(< "${lock}/rotation")"
  [[ "${name}" =~ ^kes-rotate\.[A-Za-z0-9]+$ && ! -e "${recovery}/${name}/phase" && ! -L "${recovery}/${name}/phase" ]]
}

# What a lock left by another or an interrupted operation holds, and whether
# releasing it is safe: nothing was issued, or the certificate in recovery
# carries a counter the live cold.counter has already moved past, so no new
# certificate can ever reuse it.
cntools_kes_lock_inspect() {
  local lock='' recovery='' name='' candidate='' suffix='' counter='' cold='' cert='' hot='' staged_counter='' staged_cert='' staged_hot=''
  local period='' signature='' pool="${CNTOOLS_KES_DIRECTORY##*/}"
  CNTOOLS_KES_LOCK_KIND='Unrecognised operation' CNTOOLS_KES_LOCK_STAGED='' CNTOOLS_KES_LOCK_CERT=N CNTOOLS_KES_LOCK_RELEASABLE=N CNTOOLS_KES_STAGE=''
  CNTOOLS_KES_LOCK_CERT_COUNTER='' CNTOOLS_KES_LOCK_BUSY=N
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" && cntools_state_path_into recovery recovery || return 1
  CNTOOLS_KES_LOCK_PATH="${lock}"
  [[ ! -d "${lock}/busy" || -L "${lock}/busy" ]] || CNTOOLS_KES_LOCK_BUSY=Y
  ! cntools_pool_public_file_safe "${lock}/rotation" 128 || name="$(< "${lock}/rotation")"
  if [[ -z "${name}" ]]; then
    # Earlier builds did not record a first certificate's stage: use the newest.
    for candidate in "${recovery}/opcert-${pool}."*; do
      [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
      [[ -n "${name}" && ! "${candidate}" -nt "${recovery}/${name}" ]] || name="${candidate##*/}"
    done
  fi
  cntools_pool_file_name_into counter counter; cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into cert opcert
  cntools_pool_file_name_into hot kes-vkey
  suffix="${name#"opcert-${pool}."}"
  if [[ "${name}" == "opcert-${pool}."* && "${suffix}" =~ ^[A-Za-z0-9]+$ ]]; then
    CNTOOLS_KES_LOCK_KIND='First operational certificate'
    staged_counter="${recovery}/${name}/${counter}" staged_cert="${recovery}/${name}/${cert}" staged_hot="${recovery}/${name}/${hot}"
  elif [[ "${name}" =~ ^kes-sign\.[A-Za-z0-9]+$ ]]; then
    CNTOOLS_KES_LOCK_KIND='Offline request signing'
    staged_counter="${recovery}/${name}/request/cold.counter" staged_cert="${recovery}/${name}/replacement/op.cert"
    staged_hot="${recovery}/${name}/request/hot.vkey"
    [[ ! -e "${staged_cert}" ]] || staged_counter="${recovery}/${name}/replacement/cold.counter"
  elif [[ "${name}" =~ ^kes-rotate\.[A-Za-z0-9]+$ ]]; then
    if [[ -e "${recovery}/${name}/phase" || -L "${recovery}/${name}/phase" ]]; then
      # A recorded rotation is continued by Rotate itself, never released here.
      CNTOOLS_KES_LOCK_KIND='KES rotation in progress'
      [[ ! -d "${recovery}/${name}" || -L "${recovery}/${name}" ]] || CNTOOLS_KES_STAGE="${recovery}/${name}"
      return 0
    fi
    CNTOOLS_KES_LOCK_KIND='Interrupted KES rotation'
    staged_counter="${recovery}/${name}/request/cold.counter" staged_cert="${recovery}/${name}/replacement/op.cert"
    staged_hot="${recovery}/${name}/request/hot.vkey"
  else
    return 0
  fi
  [[ -d "${recovery}/${name}" && ! -L "${recovery}/${name}" ]] || return 0
  CNTOOLS_KES_STAGE="${recovery}/${name}"
  [[ ! -e "${staged_cert}" && ! -L "${staged_cert}" ]] || CNTOOLS_KES_LOCK_CERT=Y
  cntools_pool_counter_into CNTOOLS_KES_LOCK_STAGED "${staged_counter}" "${CNTOOLS_KES_DIRECTORY}/${cold}" || CNTOOLS_KES_LOCK_STAGED=''
  if [[ "${CNTOOLS_KES_LOCK_CERT}" == N ]]; then
    CNTOOLS_KES_LOCK_RELEASABLE=Y
  elif cntools_pool_opcert_fields_into CNTOOLS_KES_LOCK_CERT_COUNTER period signature "${staged_cert}" \
         "${CNTOOLS_KES_DIRECTORY}/${cold}" "${staged_hot}" 2>/dev/null &&
       [[ "${CNTOOLS_KES_DISK_NEXT}" =~ ^(0|[1-9][0-9]{0,9})$ ]] && ((CNTOOLS_KES_DISK_NEXT > CNTOOLS_KES_LOCK_CERT_COUNTER)); then
    # The live counter already moved past the recovered certificate's.
    CNTOOLS_KES_LOCK_RELEASABLE=Y
  fi
  cntools_transaction_log POOL "Certificate lock kind=${CNTOOLS_KES_LOCK_KIND} recovery=${CNTOOLS_KES_STAGE} certificate=${CNTOOLS_KES_LOCK_CERT} certificateCounter=${CNTOOLS_KES_LOCK_CERT_COUNTER:-unknown} staged=${CNTOOLS_KES_LOCK_STAGED:-unknown} live=${CNTOOLS_KES_DISK_NEXT} busy=${CNTOOLS_KES_LOCK_BUSY} releasable=${CNTOOLS_KES_LOCK_RELEASABLE}"
}

# Inspected again first, so the release decision uses the current files.
cntools_kes_lock_force_release() {
  local lock=''
  cntools_kes_lock_inspect && [[ "${CNTOOLS_KES_LOCK_RELEASABLE}" == Y ]] || {
    cntools_kes_error 'The lock is no longer safe to release. Inspect it and its recovery folder.'; return 1;
  }
  lock="${CNTOOLS_KES_LOCK_PATH}"
  [[ -d "${lock}" && ! -L "${lock}" ]] && rm -f -- "${lock}/rotation" &&
    { [[ ! -d "${lock}/busy" ]] || rmdir -- "${lock}/busy"; } && rmdir -- "${lock}" || {
    cntools_kes_error "The lock could not be removed. Check that no CNTools session uses this pool, then remove ${lock} by hand."; return 1;
  }
  cntools_transaction_log POOL "Certificate lock released kind=${CNTOOLS_KES_LOCK_KIND} recovery kept=${CNTOOLS_KES_STAGE:-none}"
}

cntools_kes_pending_load() {
  local lock='' recovery='' name=''
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" && cntools_state_directory_into recovery recovery &&
    cntools_pool_directory_writable "${lock}" && cntools_pool_public_file_safe "${lock}/rotation" 128 || return 1
  name="$(< "${lock}/rotation")"
  [[ "${name}" =~ ^kes-rotate\.[A-Za-z0-9]+$ ]] || {
    cntools_kes_error 'The existing issuance lock requires manual recovery. No new certificate will be issued.'; return 1;
  }
  CNTOOLS_KES_STAGE="${recovery}/${name}"
  cntools_kes_stage_safe && cntools_kes_request_validate "${CNTOOLS_KES_STAGE}/request" &&
    cntools_pool_public_file_safe "${CNTOOLS_KES_STAGE}/phase" 128 || {
    cntools_kes_error 'The pending rotation request is incomplete, changed or no longer owner-only, so CNTools cannot continue it. Inspect its recovery folder and never restore an older counter.'; return 1;
  }
  mkdir -m 700 -- "${lock}/busy" 2>/dev/null || {
    cntools_kes_error 'This rotation is busy or was interrupted. Inspect the recovery directory before clearing only its busy marker.'; return 1;
  }
  CNTOOLS_KES_BUSY="${lock}/busy"
  CNTOOLS_KES_START="$(jq -r '.startPeriod' "${CNTOOLS_KES_STAGE}/request/request.json")"
  CNTOOLS_KES_NEXT="$(jq -r '.issueCounter' "${CNTOOLS_KES_STAGE}/request/request.json")"
  CNTOOLS_KES_COUNTER_SOURCE='Pending rotation request'
}

cntools_kes_request_validate() {
  local directory="$1" cold='' next='' pool='' pool_hex='' request=''
  for request in cold.vkey hot.vkey cold.counter request.json; do
    cntools_pool_public_file_safe "${directory}/${request}" || return 1
  done
  cntools_pool_key_validate "${directory}/hot.vkey" kes verification &&
    cntools_pool_counter_into next "${directory}/cold.counter" "${directory}/cold.vkey" || return 1
  jq -es --arg network "${CNTOOLS_NETWORK}" --argjson next "${next}" 'length == 1 and (.[0] |
    keys == ["issueCounter","network","poolId","schema","startPeriod"] and .schema == 1 and .network == $network and
    .issueCounter == $next and (.startPeriod | type == "number" and floor == . and . >= 0 and . < 2147483647) and
    (.poolId | type == "string"))' "${directory}/request.json" >/dev/null || return 1
  cntools_pool_file_name_into cold cold-vkey
  jq -es 'length == 2 and (.[0].cborHex|ascii_downcase) == (.[1].cborHex|ascii_downcase)' \
    "${directory}/cold.vkey" "${CNTOOLS_KES_DIRECTORY}/${cold}" >/dev/null || return 1
  cntools_pool_id_into pool pool_hex "$(jq -r .poolId "${directory}/request.json")" &&
    [[ "${pool}" == "${CNTOOLS_POOL_IDS[CNTOOLS_KES_INDEX]}" ]]
}

cntools_kes_prepare() {
  local period="$1" kind='' filename='' directory="${CNTOOLS_KES_DIRECTORY}"
  [[ "${period}" =~ ^(0|[1-9][0-9]{0,9})$ ]] && ((period < 2147483647)) && cntools_kes_counter_guard || return 1
  [[ -z "${CNTOOLS_KES_CURRENT}" || "${period}" == "${CNTOOLS_KES_CURRENT}" ]] || {
    cntools_kes_error 'Use the current KES period from the chain tip, not a past or future start period.'; return 1;
  }
  # All managed originals must be safe before obtaining an issuance lock.
  for kind in cold-vkey counter kes-vkey kes-skey opcert kes-start; do
    cntools_pool_file_name_into filename "${kind}"
    [[ ! -e "${directory}/${filename}.gpg" && ! -L "${directory}/${filename}.gpg" ]] || return 1
    [[ ! -e "${directory}/${filename}" && ! -L "${directory}/${filename}" ]] && continue
    cntools_pool_public_file_safe "${directory}/${filename}" && [[ -O "${directory}/${filename}" ]] || return 1
  done
  cntools_kes_lock_acquire rotate || return 1
  CNTOOLS_KES_START="${period}"
  cntools_kes_prepare_stage "${period}" && return 0
  # Nothing is issued while preparing: release the lock, keep the folder.
  cntools_kes_unlock_unissued || true
  return 1
}

cntools_kes_prepare_stage() {
  local period="$1" kind='' filename='' directory="${CNTOOLS_KES_DIRECTORY}" stage="${CNTOOLS_KES_STAGE}" derived=''
  mkdir -m 700 -- "${stage}/original" "${stage}/request" "${stage}/replacement" || return 1
  for kind in cold-vkey counter kes-vkey kes-skey opcert kes-start; do
    cntools_pool_file_name_into filename "${kind}"
    [[ -e "${directory}/${filename}" ]] || continue
    cp -p -- "${directory}/${filename}" "${stage}/original/${kind}" || return 1
  done
  cntools_pool_file_name_into filename cold-vkey
  cp -- "${directory}/${filename}" "${stage}/request/cold.vkey" || return 1
  cntools_pool_file_name_into filename counter
  if [[ "${CNTOOLS_KES_NEXT}" == "${CNTOOLS_KES_DISK_NEXT}" ]]; then
    cp -- "${directory}/${filename}" "${stage}/request/cold.counter" || return 1
  else
    # Issue at the selected counter. The live cold.counter changes only when
    # the issued certificate's advanced counter is consumed.
    cntools_pool_cli latest node new-counter --cold-verification-key-file "${stage}/request/cold.vkey" \
      --counter-value "${CNTOOLS_KES_NEXT}" --operational-certificate-issue-counter-file "${stage}/request/cold.counter" || return 1
  fi
  chmod 0600 "${stage}/request/"* || return 1
  cntools_pool_cli latest node key-gen-KES --verification-key-file "${stage}/replacement/hot.vkey" \
    --signing-key-file "${stage}/replacement/hot.skey" || return 1
  cntools_pool_key_validate "${stage}/replacement/hot.skey" kes signing &&
    cntools_pool_key_validate "${stage}/replacement/hot.vkey" kes verification || return 1
  cntools_transaction_temp_file derived kes-derived-public || return 1
  cntools_pool_cli key verification-key --signing-key-file "${stage}/replacement/hot.skey" --verification-key-file "${derived}" &&
    cmp -s <(jq -r .cborHex "${derived}") <(jq -r .cborHex "${stage}/replacement/hot.vkey") || return 1
  cp -- "${stage}/replacement/hot.vkey" "${stage}/request/hot.vkey" || return 1
  printf '%s\n' "${period}" > "${stage}/replacement/kes.start"
  jq -n --arg network "${CNTOOLS_NETWORK}" --arg pool "${CNTOOLS_POOL_IDS[CNTOOLS_KES_INDEX]}" \
    --argjson start "${period}" --argjson counter "${CNTOOLS_KES_NEXT}" \
    '{schema:1,network:$network,poolId:$pool,startPeriod:$start,issueCounter:$counter}' > "${stage}/request/request.json" || return 1
  chmod 0600 "${stage}/replacement/"* "${stage}/request/"* || return 1
  cntools_kes_request_validate "${stage}/request" && cntools_kes_phase_set prepared
}

cntools_kes_originals_match() {
  local allow_new="${1:-N}" kind='' filename='' replacement=''
  cntools_kes_stage_safe || return 1
  for kind in cold-vkey counter kes-vkey kes-skey opcert kes-start; do
    cntools_pool_file_name_into filename "${kind}"
    case "${kind}" in counter) replacement=cold.counter ;; kes-vkey) replacement=hot.vkey ;; kes-skey) replacement=hot.skey ;; opcert) replacement=op.cert ;; kes-start) replacement=kes.start ;; *) replacement='' ;; esac
    if [[ -e "${CNTOOLS_KES_DIRECTORY}/${filename}" || -L "${CNTOOLS_KES_DIRECTORY}/${filename}" ]]; then
      cntools_pool_public_file_safe "${CNTOOLS_KES_DIRECTORY}/${filename}" && [[ -O "${CNTOOLS_KES_DIRECTORY}/${filename}" ]] || return 1
      if [[ -f "${CNTOOLS_KES_STAGE}/original/${kind}" ]] && cmp -s "${CNTOOLS_KES_DIRECTORY}/${filename}" "${CNTOOLS_KES_STAGE}/original/${kind}"; then continue; fi
      if [[ "${allow_new}" == Y && -n "${replacement}" ]] && cntools_pool_public_file_safe "${CNTOOLS_KES_STAGE}/replacement/${replacement}" &&
          cmp -s "${CNTOOLS_KES_DIRECTORY}/${filename}" "${CNTOOLS_KES_STAGE}/replacement/${replacement}"; then continue; fi
      return 1
    else
      [[ ! -e "${CNTOOLS_KES_STAGE}/original/${kind}" ]] || return 1
    fi
  done
}

# Replace one known file, preserving its permissions/immutable status. No whole
# directory rename and no unlocking unrelated cold or VRF keys.
cntools_kes_replace() {
  local kind="$1" source="$2" filename='' target='' work='' mode=600 attributes='' immutable=N lsattr='' protection=''
  cntools_pool_file_name_into filename "${kind}" || return 1
  target="${CNTOOLS_KES_DIRECTORY}/${filename}"
  cntools_pool_public_file_safe "${source}" && [[ ! -L "${target}" && ! -d "${target}" ]] || return 1
  if [[ -e "${target}" ]]; then
    cntools_pool_public_file_safe "${target}" && [[ -O "${target}" ]] && cntools_filesystem_mode_into mode "${target}" || return 1
    # Never propagate public-write permissions to freshly generated private keys.
    (( (8#${mode} & 0022) == 0 )) || return 1
    mode="$(printf '%03o' "$((8#${mode} & 0600))")"
    lsattr="$(type -P lsattr 2>/dev/null || true)"
    if [[ -n "${lsattr}" ]]; then
      attributes="$(cntools_run_command 0000 -- "${lsattr}" -d -- "${target}" 2>/dev/null || true)"; attributes="${attributes%% *}"
      [[ "${attributes}" != *i* ]] || immutable=Y
    fi
  fi
  # Persist original immutable intent before replacing its inode. A failed +i
  # must still be retried on continuation, not mistaken for an unprotected file.
  protection="${CNTOOLS_KES_STAGE}/protection-${kind}"
  if [[ -e "${protection}" || -L "${protection}" ]]; then
    cntools_pool_public_file_safe "${protection}" 8 || return 1
    attributes="$(< "${protection}")"
    [[ "${attributes}" == Y || "${attributes}" == N ]] || return 1
    [[ "${attributes}" != Y ]] || immutable=Y
  else
    printf '%s\n' "${immutable}" > "${protection}" && chmod 0600 "${protection}" || return 1
  fi
  if [[ -f "${CNTOOLS_KES_STAGE}/original/${kind}" ]]; then
    cntools_filesystem_mode_into mode "${CNTOOLS_KES_STAGE}/original/${kind}" || return 1
    mode="$(printf '%03o' "$((8#${mode} & 0600))")"
  fi
  # The publish temporary shares the destination's filesystem (state work
  # folder or the destination itself), so the rename stays atomic even when
  # the recovery folder lives elsewhere.
  cntools_pool_temp_into work "${CNTOOLS_KES_DIRECTORY}" || return 1
  cp -- "${source}" "${work}" && chmod "${mode}" "${work}" || return 1
  if [[ "${immutable}" == Y ]]; then cntools_pool_chattr_prepare "${CNTOOLS_KES_DIRECTORY}" && cntools_pool_chattr -i "${target}" || return 1; fi
  if ! cntools_run_command 00000 -- mv -Tf -- "${work}" "${target}"; then
    [[ "${immutable}" != Y ]] || cntools_pool_chattr +i "${target}" || true
    return 1
  fi
  [[ "${immutable}" != Y ]] || cntools_pool_chattr +i "${target}" || {
    CNTOOLS_POOL_WRITE_WARNING="Could not restore the immutable flag on ${target}; recovery remains locked."; return 1;
  }
  cntools_transaction_log POOL "KES file published role=${kind} target=${target} mode=${mode} immutable=${immutable}"
}

cntools_kes_response_validate() {
  local directory="$1" advanced='' stage="${CNTOOLS_KES_STAGE}"
  cntools_kes_stage_safe && cntools_kes_request_validate "${stage}/request" &&
    [[ "$(jq -r '.startPeriod' "${stage}/request/request.json")" == "${CNTOOLS_KES_START}" &&
       "$(jq -r '.issueCounter' "${stage}/request/request.json")" == "${CNTOOLS_KES_NEXT}" ]] &&
    cntools_pool_counter_into advanced "${directory}/cold.counter" "${stage}/request/cold.vkey" &&
    ((advanced == CNTOOLS_KES_NEXT+1)) &&
    cntools_pool_opcert_verify "${directory}/op.cert" "${stage}/request/cold.vkey" "${stage}/request/hot.vkey" \
      "${CNTOOLS_KES_NEXT}" "${CNTOOLS_KES_START}"
}

cntools_kes_issue() {
  local phase='' response='' errors='' source_snapshot='' derived='' stage="${CNTOOLS_KES_STAGE}" status=0
  CNTOOLS_KES_ISSUED=N
  phase="$(< "${stage}/phase")"
  [[ "${phase}" == prepared && -n "${CNTOOLS_KES_SOURCE}" ]] && cntools_kes_originals_match || return 1
  cntools_kes_request_validate "${stage}/request" || return 1
  # Refresh advisory chain data before crossing the irreversible issuance point.
  # A previously verified ledger becoming unavailable needs renewed approval;
  # offline approval was already explicit and never triggers a network request.
  cntools_kes_counter_recheck || return 1
  cp -- "${stage}/request/cold.counter" "${stage}/replacement/cold.counter" && chmod 0600 "${stage}/replacement/cold.counter" || return 1
  # Snapshot and bind the signing reference immediately before the issuance.
  cntools_transaction_snapshot_into source_snapshot "${CNTOOLS_KES_SOURCE}" 65536 kes-cold-source || return 1
  cntools_transaction_source_kind_into CNTOOLS_KES_KIND "${source_snapshot}" || return 1
  if [[ "${CNTOOLS_KES_KIND}" == hardware ]]; then
    jq -es 'length == 2 and (.[0].cborXPubKeyHex[4:68]|ascii_downcase) == (.[1].cborHex[4:]|ascii_downcase)' \
      "${source_snapshot}" "${stage}/request/cold.vkey" >/dev/null && cntools_transaction_hardware_device_check || return 1
  else
    cntools_transaction_temp_file derived kes-issuing-cold-public || return 1
    cntools_pool_cli key verification-key --signing-key-file "${source_snapshot}" --verification-key-file "${derived}" &&
      jq -es 'length == 2 and (.[0].cborHex|ascii_downcase) == (.[1].cborHex|ascii_downcase)' \
        "${derived}" "${stage}/request/cold.vkey" >/dev/null || return 1
  fi
  cntools_kes_phase_set issuing || return 1
  if [[ "${CNTOOLS_KES_KIND}" == cli ]]; then
    cntools_pool_cli latest node issue-op-cert --kes-verification-key-file "${stage}/request/hot.vkey" \
      --cold-signing-key-file "${source_snapshot}" --operational-certificate-issue-counter-file "${stage}/replacement/cold.counter" \
      --kes-period "${CNTOOLS_KES_START}" --out-file "${stage}/replacement/op.cert" || status=$?
  else
    cntools_transaction_temp_file response kes-hardware-output; cntools_transaction_temp_file errors kes-hardware-errors
    local CNTOOLS_TRANSACTION_TIMEOUT="${CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT}"
    cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_TRANSACTION_HWCLI}" node issue-op-cert \
      --kes-verification-key-file "${stage}/request/hot.vkey" --hw-signing-file "${source_snapshot}" \
      --operational-certificate-issue-counter-file "${stage}/replacement/cold.counter" --kes-period "${CNTOOLS_KES_START}" \
      --out-file "${stage}/replacement/op.cert" || status=$?
    ((status == 0)) || cntools_transaction_log_cli_failure 'Hardware KES certificate issuance failed' "${status}" "${errors}" "${response}"
  fi
  if ((status != 0)); then
    # The command failed or timed out: no certificate was accepted and the
    # counter is unchanged, so the request is ready again.
    rm -f -- "${stage}/replacement/op.cert"
    cntools_kes_phase_set prepared || true
    # A node-side request stays prepared; an offline signing releases its lock
    # (cntools_kes_unlock_unissued adds that a retry can start).
    if [[ "${stage##*/}" == kes-sign.* ]]; then
      cntools_kes_error 'Certificate issuance failed or timed out. No certificate was accepted and the issue counter is unchanged.'
    else
      cntools_kes_error 'Certificate issuance failed or timed out. No certificate was accepted and the issue counter is unchanged. The prepared request is kept; reopen Pool → Rotate to issue it again or discard it.'
    fi
    return 1
  fi
  CNTOOLS_KES_ISSUED=Y
  cntools_kes_response_validate "${stage}/replacement" || {
    cntools_kes_error 'Certificate issuance did not complete validation. Recovery and lock were retained; do not retry issuance or restore an old counter.'; return 1;
  }
  chmod 0600 "${stage}/replacement/op.cert" "${stage}/replacement/cold.counter" || return 1
  cntools_kes_consume_counter
}

cntools_kes_consume_counter() {
  local stage="${CNTOOLS_KES_STAGE}"
  cntools_kes_response_validate "${stage}/replacement" && cntools_kes_originals_match Y || return 1
  # Consume before exposing the operational certificate. Never undo this step.
  cntools_kes_replace counter "${stage}/replacement/cold.counter" && cntools_kes_phase_set issued
}

cntools_kes_import_response() {
  local directory="$1" stage="${CNTOOLS_KES_STAGE}" certificate='' counter=''
  [[ "$(< "${stage}/phase")" == prepared || "$(< "${stage}/phase")" == awaiting ]] && cntools_kes_originals_match || return 1
  cntools_kes_counter_recheck || return 1
  cntools_transaction_snapshot_into certificate "${directory}/op.cert" 65536 kes-returned-certificate &&
    cntools_transaction_snapshot_into counter "${directory}/cold.counter" 65536 kes-returned-counter || return 1
  # Validate snapshots, not mutable transferred files.
  local response_dir=''
  response_dir="$(mktemp -d "${stage}/.response.XXXXXX")" || return 1
  cp -- "${certificate}" "${response_dir}/op.cert" && cp -- "${counter}" "${response_dir}/cold.counter" &&
    cntools_kes_response_validate "${response_dir}" || {
    cntools_kes_error 'The returned certificate, signature, period or advanced counter does not match this rotation.'; return 1;
  }
  cp -- "${response_dir}/op.cert" "${response_dir}/cold.counter" "${stage}/replacement/" &&
    chmod 0600 "${stage}/replacement/op.cert" "${stage}/replacement/cold.counter" &&
    cntools_kes_phase_set issuing && cntools_kes_consume_counter
}

cntools_kes_publish() {
  local phase='' stage="${CNTOOLS_KES_STAGE}" kind='' filename='' evolutions='' derived='' genesis="${CNTOOLS_SHELLEY_GENESIS:-}"
  [[ "${CNTOOLS_KES_INSTALL_APPROVED}" == Y ]] || { cntools_kes_error 'Confirm the installation before replacing KES operational files.'; return 1; }
  phase="$(< "${stage}/phase")"
  [[ "${phase}" == issued || "${phase}" == publishing ]] && cntools_kes_response_validate "${stage}/replacement" &&
    cntools_pool_key_validate "${stage}/replacement/hot.skey" kes signing && cntools_kes_originals_match Y || return 1
  cntools_transaction_temp_file derived kes-publication-pair || return 1
  cntools_pool_cli key verification-key --signing-key-file "${stage}/replacement/hot.skey" --verification-key-file "${derived}" &&
    cmp -s <(jq -r '.cborHex|ascii_downcase' "${derived}") <(jq -r '.cborHex|ascii_downcase' "${stage}/request/hot.vkey") &&
    cmp -s "${stage}/replacement/hot.vkey" "${stage}/request/hot.vkey" &&
    [[ "$(< "${stage}/replacement/kes.start")" == "${CNTOOLS_KES_START}" ]] || {
    cntools_kes_error 'The staged KES signing key, public key or start period does not match the signed certificate.'; return 1;
  }
  cntools_kes_period_collect || return 1
  if [[ -n "${CNTOOLS_KES_CURRENT}" ]] && cntools_pool_public_file_safe "${genesis}" 1048576; then
    evolutions="$(jq -r '.maxKESEvolutions // empty' "${genesis}")"
    [[ "${evolutions}" =~ ^[1-9][0-9]{0,3}$ ]] &&
      ((CNTOOLS_KES_START <= CNTOOLS_KES_CURRENT && CNTOOLS_KES_CURRENT < CNTOOLS_KES_START+evolutions)) || {
      cntools_kes_error 'The replacement KES start is future or expired. Keep recovery/counters intact and review a new rotation.'; return 1;
    }
  fi
  cntools_kes_phase_set publishing || return 1
  # The node reads only hot.skey and op.cert, and only at startup or reload.
  # Replace them last and back to back; reload once all five are in place.
  for kind in counter kes-vkey kes-start kes-skey opcert; do
    case "${kind}" in counter) filename=cold.counter ;; kes-skey) filename=hot.skey ;; kes-vkey) filename=hot.vkey ;; kes-start) filename=kes.start ;; opcert) filename=op.cert ;; esac
    cntools_kes_originals_match Y && cntools_kes_replace "${kind}" "${stage}/replacement/${filename}" || {
      cntools_kes_error 'Publication was interrupted. Do not restart or reload the node; continue this rotation to finish installing; its recovery copy and advanced counter were retained.'; return 1;
    }
  done
  cntools_kes_phase_set complete && cntools_kes_lock_release
}

# Issuance interrupted before the certificate was written (session closed
# while the CLI or device worked): nothing usable exists and the live counter
# never moved, so the request is ready again. Returns 1 when a certificate is
# in recovery; that one is validated and recovered, never issued again.
cntools_kes_issuing_reset() {
  cntools_kes_stage_safe && [[ "$(< "${CNTOOLS_KES_STAGE}/phase")" == issuing ]] || return 1
  [[ ! -e "${CNTOOLS_KES_STAGE}/replacement/op.cert" && ! -L "${CNTOOLS_KES_STAGE}/replacement/op.cert" ]] || return 1
  cntools_kes_phase_set prepared || return 1
  cntools_transaction_log POOL "KES issuance interrupted before a certificate was written; request ready again recovery=${CNTOOLS_KES_STAGE}"
}

# Abandon a request before any certificate was issued for it. The counter never
# advanced in these phases; the recovery folder is kept for inspection.
cntools_kes_discard() {
  local phase=''
  cntools_kes_stage_safe || return 1
  phase="$(< "${CNTOOLS_KES_STAGE}/phase")"
  [[ "${phase}" == prepared || "${phase}" == awaiting ]] || {
    cntools_kes_error 'Only a request that was prepared but not yet issued can be discarded.'; return 1;
  }
  # Released first: a failed release never leaves a discarded request locked.
  cntools_kes_lock_release || return 1
  cntools_kes_phase_set discarded || true
}

cntools_kes_lock_release() {
  local lock=''
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" &&
    cntools_pool_directory_writable "${lock}" && [[ "$(< "${lock}/rotation")" == "${CNTOOLS_KES_STAGE##*/}" ]] || return 1
  cntools_kes_cleanup
  rm -f -- "${lock}/rotation" && rmdir -- "${lock}"
}

cntools_kes_cleanup() {
  local lock=''
  if [[ -n "${CNTOOLS_KES_BUSY}" ]] && cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" &&
     [[ "${CNTOOLS_KES_BUSY}" == "${lock}/busy" ]]; then
    rmdir -- "${CNTOOLS_KES_BUSY}" 2>/dev/null || true
  fi
  CNTOOLS_KES_BUSY=''
  cntools_pool_files_cleanup_temps
  cntools_transaction_cleanup
}

# Signing-side flow: only public request data is copied in, and only the real
# local issue counter is consumed. No KES private key is exported or required.
cntools_kes_sign_request() {
  local directory="$1"
  # The node chose the counter (ledger + 1, or operator input when offline).
  [[ -n "${CNTOOLS_KES_SOURCE}" ]] && cntools_kes_request_validate "${directory}" || return 1
  CNTOOLS_KES_NEXT="$(jq -r '.issueCounter' "${directory}/request.json")" CNTOOLS_KES_COUNTER_SOURCE='Offline request'
  cntools_kes_counter_guard || return 1
  CNTOOLS_KES_ISSUED=N
  cntools_kes_lock_acquire sign || return 1
  if ! cntools_kes_sign_stage "${directory}"; then
    # Until the issuing command succeeds nothing was issued: release the lock.
    [[ "${CNTOOLS_KES_ISSUED}" == Y ]] || cntools_kes_unlock_unissued || true
    return 1
  fi
  cntools_kes_phase_set complete && cntools_kes_lock_release
}

cntools_kes_sign_stage() {
  local directory="$1" stage="${CNTOOLS_KES_STAGE}" file='' kind='' counter_name=''
  mkdir -m 700 -- "${stage}/request" "${stage}/original" "${stage}/replacement" || return 1
  for file in cold.vkey hot.vkey cold.counter request.json; do cp -- "${directory}/${file}" "${stage}/request/${file}" || return 1; done
  chmod 0600 "${stage}/request/"* || return 1
  cntools_kes_request_validate "${stage}/request" || return 1
  [[ "$(jq -r '.issueCounter' "${stage}/request/request.json")" == "${CNTOOLS_KES_NEXT}" ]] || return 1
  CNTOOLS_KES_START="$(jq -r '.startPeriod' "${stage}/request/request.json")"
  # Snapshot the signing system's existing operational files for unchanged checks.
  for kind in cold-vkey counter kes-vkey kes-skey opcert kes-start; do
    cntools_pool_file_name_into counter_name "${kind}"
    [[ ! -e "${CNTOOLS_KES_DIRECTORY}/${counter_name}" ]] || cp -p -- "${CNTOOLS_KES_DIRECTORY}/${counter_name}" "${stage}/original/${kind}" || return 1
  done
  cntools_kes_phase_set prepared && cntools_kes_issue
}
