#!/usr/bin/env bash
# Read-only operational diagnostics; never issue a certificate or alter counters.
# shellcheck disable=SC2034
declare -ag CNTOOLS_POOL_KES_STATUS=() CNTOOLS_POOL_KES_EXPIRY=() CNTOOLS_POOL_KES_REMAINING=()
declare -ag CNTOOLS_POOL_CERT_DISK=() CNTOOLS_POOL_CERT_CHAIN=() CNTOOLS_POOL_CERT_NEXT=() CNTOOLS_POOL_KES_SOURCE=()
declare -ag CNTOOLS_POOL_KES_TIME=()

# Minimal bounded CBOR uint reader for public certificate period/counter fields.
cntools_pool_health_uint_into() {
  local target="$1" remainder="$2" encoded="$3" head="${3:0:2}" digits=0 value=0
  [[ "${head}" =~ ^[0-9a-f]{2}$ ]] || return 1
  value=$((16#${head}))
  if ((value <= 23)); then
    printf -v "${target}" '%s' "${value}"; printf -v "${remainder}" '%s' "${encoded:2}"; return 0
  fi
  case "${head}" in 18) digits=2 ;; 19) digits=4 ;; 1a) digits=8 ;; 1b) digits=16 ;; *) return 1 ;; esac
  [[ "${encoded:2:digits}" =~ ^[0-9a-f]+$ && ${#encoded} -ge $((2+digits)) ]] || return 1
  # Values above the operationally meaningful signed range are not guessed.
  [[ "${digits}" != 16 || "${encoded:2:8}" == 00000000 ]] || return 1
  value=$((16#${encoded:2:digits}))
  ((value <= 2147483647)) || return 1
  printf -v "${target}" '%s' "${value}"; printf -v "${remainder}" '%s' "${encoded:2+digits}"
}

CNTOOLS_POOL_HEALTH_UINT='(0[0-9a-f]|1[0-7]|18[0-9a-f]{2}|19[0-9a-f]{4}|1a[0-9a-f]{8}|1b[0-9a-f]{16})'

# Why op.cert does not bind this pool's keys, as an Attention row: a
# certificate for another KES key, another pool, or no certificate at all.
cntools_pool_health_mismatch() {
  local index="$1" cert="$2" cold_hex="$3" hot="$4" encoded='' pattern='' opcert="${2##*/}"
  CNTOOLS_POOL_KES_STATUS[index]='Needs attention'
  encoded="$(jq -esr 'select(length == 1 and .[0].type == "NodeOperationalCertificate") | .[0].cborHex | ascii_downcase' "${cert}" 2>/dev/null)" || encoded=''
  pattern="^82845820[0-9a-f]{64}${CNTOOLS_POOL_HEALTH_UINT}${CNTOOLS_POOL_HEALTH_UINT}5840[0-9a-f]{128}5820${cold_hex}\$"
  if [[ -n "${encoded}" && "${encoded}" =~ ${pattern} ]]; then
    cntools_pool_warning_add "${index}" "${opcert} was issued for another KES key than ${hot}, so the node cannot use them together. Restore the matching KES key pair, or issue a new certificate with Pool → Rotate"
  elif [[ "${encoded}" =~ ^82845820[0-9a-f]{64} ]]; then
    cntools_pool_warning_add "${index}" "${opcert} was not issued by this pool's cold key"
  else
    cntools_pool_warning_add "${index}" "${opcert} is not a readable operational certificate"
  fi
}

# The op.cert counter bound to this pool's cold key only, whatever KES key it
# certifies: after a KES rotation outside CNTools, or a mixed restore, it no
# longer matches hot.vkey, yet Rotate must still stay at or above it.
cntools_pool_opcert_cold_counter_into() {
  local _cntools_occ_output="$1" _cntools_occ_cert="$2" _cntools_occ_cold="$3"
  local _cntools_occ_hex='' _cntools_occ_encoded='' _cntools_occ_counter='' _cntools_occ_rest='' _cntools_occ_pattern=''
  cntools_pool_public_file_safe "${_cntools_occ_cert}" && cntools_pool_public_file_safe "${_cntools_occ_cold}" || return 1
  _cntools_occ_hex="$(jq -er '.cborHex | ascii_downcase | select(test("^5820[0-9a-f]{64}$")) | .[4:]' "${_cntools_occ_cold}")" || return 1
  _cntools_occ_encoded="$(jq -esr 'select(length == 1 and .[0].type == "NodeOperationalCertificate") | .[0].cborHex | ascii_downcase' "${_cntools_occ_cert}" 2>/dev/null)" || return 1
  _cntools_occ_pattern="^82845820[0-9a-f]{64}${CNTOOLS_POOL_HEALTH_UINT}${CNTOOLS_POOL_HEALTH_UINT}5840[0-9a-f]{128}5820${_cntools_occ_hex}\$"
  [[ "${_cntools_occ_encoded}" =~ ${_cntools_occ_pattern} ]] || return 1
  cntools_pool_health_uint_into _cntools_occ_counter _cntools_occ_rest "${_cntools_occ_encoded:72}" || return 1
  printf -v "${_cntools_occ_output}" '%s' "${_cntools_occ_counter}"
}

# A certificate that does not match hot.vkey still gets its counters read:
# the cold-key-bound op.cert counter and the ledger counter (local node for a
# certificate of this pool, else Koios), so Rotate issues ledger counter + 1
# instead of stopping.
cntools_pool_health_counters_only() {
  local index="$1" cert="$2" cold="$3" query_node="${4:-Y}" disk='' response='' output='' errors='' chain=''
  if cntools_pool_opcert_cold_counter_into disk "${cert}" "${cold}"; then
    CNTOOLS_POOL_CERT_DISK[index]="${disk}"
    if [[ "${query_node}" == Y && "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true && -x "${CNTOOLS_CLI:-}" ]] &&
        cntools_wallet_query_local_socket_ready &&
        cntools_transaction_temp_file response kes-health && cntools_transaction_temp_file output kes-health-json &&
        cntools_transaction_temp_file errors kes-health-errors && cntools_wallet_query_network_arguments &&
        cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest query kes-period-info \
          "${CNTOOLS_WALLET_NETWORK_ARGS[@]}" --socket-path "${CNTOOLS_SOCKET}" --op-cert-file "${cert}" --output-json --out-file "${output}"; then
      chain="$(jq -sr 'if length == 1 and (.[0].qKesNodeStateOperationalCertificateNumber | type == "number" and . >= 0 and floor == . and . <= 2147483647)
        then .[0].qKesNodeStateOperationalCertificateNumber | tostring else "" end' "${output}" 2>/dev/null)" || chain=''
    fi
  fi
  [[ -n "${chain}" ]] || chain="$(jq -r '.op_cert_counter // ""' <<< "${CNTOOLS_POOL_CURRENT[index]:-}" 2>/dev/null)" || chain=''
  [[ ! "${chain}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || CNTOOLS_POOL_CERT_CHAIN[index]="${chain}"
  return 0
}

cntools_pool_health_collect() {
  local index="$1" query_node="${2:-Y}" directory="${CNTOOLS_POOL_DIRECTORIES[$1]}" filename='' cert='' counter='' start='' period='' rest='' saved_start=''
  local slots="${CNTOOLS_SLOTS_PER_KES_PERIOD:-}" evolutions='' genesis="${CNTOOLS_SHELLEY_GENESIS:-}" now='' current='' end=0 remaining=0 expires='' response='' output='' errors='' chain=''
  CNTOOLS_POOL_KES_STATUS[index]='Unavailable' CNTOOLS_POOL_KES_EXPIRY[index]='' CNTOOLS_POOL_KES_REMAINING[index]=''
  CNTOOLS_POOL_CERT_DISK[index]='' CNTOOLS_POOL_CERT_CHAIN[index]='' CNTOOLS_POOL_CERT_NEXT[index]='' CNTOOLS_POOL_KES_SOURCE[index]=''
  CNTOOLS_POOL_KES_TIME[index]=''
  cntools_pool_file_name_into filename opcert
  if ! cntools_pool_public_file_safe "${directory}/${filename}"; then CNTOOLS_POOL_KES_STATUS[index]='No operational certificate'; return 0; fi
  cert="${directory}/${filename}"
  # Bind to the pool and KES public keys using the existing structural validator.
  local cold='' hot='' cold_hex='' hot_hex='' cbor='' uint="${CNTOOLS_POOL_HEALTH_UINT}"
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into hot kes-vkey
  if ! cntools_pool_public_file_safe "${directory}/${cold}" || ! cntools_pool_public_file_safe "${directory}/${hot}"; then
    CNTOOLS_POOL_KES_STATUS[index]='Needs attention'
    cntools_pool_warning_add "${index}" "${hot} or ${cold} is missing or unsafe, so ${filename} cannot be checked"
    cntools_pool_health_counters_only "${index}" "${cert}" "${directory}/${cold}" "${query_node}"; return 0
  fi
  cold_hex="$(jq -er '.cborHex | ascii_downcase | select(test("^5820[0-9a-f]{64}$")) | .[4:]' "${directory}/${cold}")" || cold_hex=''
  hot_hex="$(jq -er '.cborHex | ascii_downcase | select(test("^5820[0-9a-f]{64}$")) | .[4:]' "${directory}/${hot}")" || hot_hex=''
  if [[ -z "${cold_hex}" || -z "${hot_hex}" ]]; then
    CNTOOLS_POOL_KES_STATUS[index]='Needs attention'
    cntools_pool_warning_add "${index}" "${hot} or ${cold} is not a valid public key, so ${filename} cannot be checked"; return 0
  fi
  cbor="$(jq -esr --arg pattern "^82845820${hot_hex}${uint}${uint}5840[0-9a-f]{128}5820${cold_hex}$" '
    select(length == 1 and .[0].type == "NodeOperationalCertificate") | .[0].cborHex | ascii_downcase | select(test($pattern))' "${cert}" 2>/dev/null)" || cbor=''
  if [[ -z "${cbor}" ]]; then
    cntools_pool_health_mismatch "${index}" "${cert}" "${cold_hex}" "${hot}"
    cntools_pool_health_counters_only "${index}" "${cert}" "${directory}/${cold}" "${query_node}"; return 0
  fi
  cntools_pool_health_uint_into counter rest "${cbor:72}" && cntools_pool_health_uint_into start rest "${rest}" || return 0
  CNTOOLS_POOL_CERT_DISK[index]="${counter}"
  cntools_pool_file_name_into filename kes-start
  if cntools_pool_public_file_safe "${directory}/${filename}" 64; then
    saved_start="$(< "${directory}/${filename}")"
    [[ "${saved_start}" == "${start}" ]] || cntools_pool_warning_add "${index}" 'kes.start differs from the operational certificate'
  fi
  cntools_pool_file_name_into filename counter
  if cntools_pool_public_file_safe "${directory}/${filename}"; then
    rest="$(jq -esr 'select(length == 1 and .[0].type == "NodeOperationalCertificateIssueCounter") | .[0].cborHex|ascii_downcase|select(test("^82[0-9a-f]+$"))|.[2:]' "${directory}/${filename}")" || rest=''
    if cntools_pool_health_uint_into period rest "${rest}" && [[ "${rest}" == "5820${cold_hex}" ]]; then
      CNTOOLS_POOL_CERT_NEXT[index]="${period}"
      ((period > counter)) || cntools_pool_warning_add "${index}" 'Issue counter is not ahead of the current certificate; do not reset it'
    fi
  fi
  # Local node data is authoritative for the on-chain counter and current tip.
  if [[ "${query_node}" == Y && "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true && -x "${CNTOOLS_CLI:-}" ]] && cntools_wallet_query_local_socket_ready; then
    cntools_transaction_temp_file response kes-health && cntools_transaction_temp_file output kes-health-json &&
      cntools_transaction_temp_file errors kes-health-errors || return 1
    cntools_wallet_query_network_arguments || return 1
    # kes-period-info always prints its diagnostic checks to stdout, so only
    # --out-file carries the JSON document alone.
    if cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest query kes-period-info \
        "${CNTOOLS_WALLET_NETWORK_ARGS[@]}" --socket-path "${CNTOOLS_SOCKET}" --op-cert-file "${cert}" --output-json --out-file "${output}" &&
        jq -se --argjson start "${start}" 'length == 1 and (.[0] | type == "object" and
          all(.qKesCurrentKesPeriod,.qKesStartKesInterval,.qKesEndKesInterval,.qKesSlotsPerKesPeriod,.qKesMaxKESEvolutions;
            type == "number" and . >= 0 and . <= 2147483647 and floor == .) and
          .qKesSlotsPerKesPeriod > 0 and .qKesMaxKESEvolutions > 0 and
          .qKesStartKesInterval == $start and .qKesEndKesInterval == ($start+.qKesMaxKESEvolutions) and
          (.qKesNodeStateOperationalCertificateNumber | . == null or (type == "number" and . >= 0 and floor == . and . <= 2147483647)))' "${output}" >/dev/null; then
      current="$(jq -r .qKesCurrentKesPeriod "${output}")"
      slots="$(jq -r .qKesSlotsPerKesPeriod "${output}")"; evolutions="$(jq -r .qKesMaxKESEvolutions "${output}")"
      chain="$(jq -r '.qKesNodeStateOperationalCertificateNumber // ""' "${output}")"
      CNTOOLS_POOL_KES_SOURCE[index]='Local node'
    else
      cntools_transaction_log WARN "KES node query unavailable pool=${CNTOOLS_POOL_NAMES[index]}; using certificate and wall clock"
    fi
  fi
  if [[ -z "${chain}" ]]; then
    chain="$(jq -r '.op_cert_counter // ""' <<< "${CNTOOLS_POOL_CURRENT[index]}")"
  fi
  if [[ "${chain}" =~ ^(0|[1-9][0-9]{0,9})$ ]]; then
    CNTOOLS_POOL_CERT_CHAIN[index]="${chain}"
    # Ledger permits the same counter or its immediate successor.
    if ((counter < chain || counter > chain+1)); then cntools_pool_warning_add "${index}" 'Operational certificate counter does not match the ledger or its next counter'; fi
  fi
  if [[ -z "${evolutions}" ]] && cntools_pool_public_file_safe "${genesis}" 1048576; then
    evolutions="$(jq -r '.maxKESEvolutions // ""' "${genesis}")"
    [[ -n "${slots}" ]] || slots="$(jq -r '.slotsPerKESPeriod // ""' "${genesis}")"
  fi
  [[ "${slots}" =~ ^[1-9][0-9]{0,9}$ && "${evolutions}" =~ ^[1-9][0-9]{0,3}$ ]] || return 0
  if [[ -z "${current}" ]]; then
    now="$(cntools_health_now)"; period="$(cntools_health_reference_slot "${CNTOOLS_NETWORK}" "${now}")" || return 0
    current=$((period / slots)); CNTOOLS_POOL_KES_SOURCE[index]='Certificate + wall-clock estimate'
  fi
  end=$((start+evolutions)); remaining=$((end-current))
  cntools_slot_datetime_into expires "$((end*slots))" || expires='Unavailable'
  CNTOOLS_POOL_KES_EXPIRY[index]="${expires}" CNTOOLS_POOL_KES_REMAINING[index]="${remaining}"
  now="$(cntools_health_now)"
  if period="$(cntools_health_reference_slot "${CNTOOLS_NETWORK}" "${now}")"; then
    local seconds=$((end*slots-period))
    if ((seconds <= 0)); then CNTOOLS_POOL_KES_TIME[index]=Expired
    else CNTOOLS_POOL_KES_TIME[index]="$((seconds/86400)) days $((seconds%86400/3600)) hours"; fi
  fi
  CNTOOLS_POOL_KES_STATUS[index]=Healthy
  if ((current < start)); then CNTOOLS_POOL_KES_STATUS[index]='Not yet valid'
  elif ((remaining <= 0)); then CNTOOLS_POOL_KES_STATUS[index]=Expired
  elif ((remaining <= 7)); then CNTOOLS_POOL_KES_STATUS[index]='Expiring soon'; fi
  cntools_transaction_log POOL "KES pool=${CNTOOLS_POOL_NAMES[index]} status=${CNTOOLS_POOL_KES_STATUS[index]} remaining=${remaining} source=${CNTOOLS_POOL_KES_SOURCE[index]}"
}

cntools_pool_health_rows() {
  local index="$1" detailed="${2:-N}" role=warning opcert='' counter=''
  [[ "${CNTOOLS_POOL_KES_STATUS[index]:-}" != Healthy ]] || role=success
  cntools_table_pair 'KES health' "${CNTOOLS_POOL_KES_STATUS[index]:-Not checked}" "${role}"
  [[ -z "${CNTOOLS_POOL_KES_REMAINING[index]:-}" ]] || cntools_table_pair 'KES periods remaining' "$(cntools_number_format "${CNTOOLS_POOL_KES_REMAINING[index]}")" "${role}"
  [[ "${detailed}" == Y ]] || return 0
  [[ -z "${CNTOOLS_POOL_KES_EXPIRY[index]:-}" ]] || cntools_table_pair 'KES expires' "${CNTOOLS_POOL_KES_EXPIRY[index]}" "${role}"
  [[ -z "${CNTOOLS_POOL_KES_TIME[index]:-}" ]] || cntools_table_pair 'Time until expiry · clock' "${CNTOOLS_POOL_KES_TIME[index]}" "${role}"
  [[ -z "${CNTOOLS_POOL_KES_SOURCE[index]:-}" ]] || cntools_table_pair 'KES source' "${CNTOOLS_POOL_KES_SOURCE[index]}" muted
  # Name the file each counter comes from: op.cert carries the certificate's
  # counter, cold.counter the next one to issue.
  cntools_pool_file_name_into opcert opcert; cntools_pool_file_name_into counter counter
  [[ -z "${CNTOOLS_POOL_CERT_DISK[index]:-}" ]] || cntools_table_pair "Certificate counter · ${opcert}" "${CNTOOLS_POOL_CERT_DISK[index]}" number
  cntools_table_pair 'Certificate counter · ledger' "${CNTOOLS_POOL_CERT_CHAIN[index]:-Unavailable}" muted
  [[ -z "${CNTOOLS_POOL_CERT_NEXT[index]:-}" ]] || cntools_table_pair "Next issue counter · ${counter}" "${CNTOOLS_POOL_CERT_NEXT[index]}" number
}
