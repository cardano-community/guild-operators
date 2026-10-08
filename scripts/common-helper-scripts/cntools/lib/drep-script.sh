#!/usr/bin/env bash
# Public-only native-script DRep identities. Never replaces wallet/DRep keys.
# shellcheck disable=SC2034
declare -ag CNTOOLS_DREP_SCRIPT_HASHES=() CNTOOLS_DREP_SCRIPT_LABELS=()
declare -ag CNTOOLS_DREP_SCRIPT_LINK_SOURCES=() CNTOOLS_DREP_SCRIPT_LINK_TARGETS=()
CNTOOLS_DREP_SCRIPT_THRESHOLD=''
CNTOOLS_DREP_SCRIPT_PARTICIPANTS=''

cntools_drep_script_fail() { cntools_drep_key_error "$1"; return 1; }

cntools_drep_script_participant_add() {
  local hash="${1,,}" label="$2" existing=''
  [[ "${hash}" =~ ^[0-9a-f]{56}$ && -n "${label}" && ${#label} -le 64 && ! "${label}" =~ [[:cntrl:]] ]] ||
    { cntools_drep_script_fail 'Use a DRep verification key or a 56-character signing-key credential hash.'; return 2; }
  (( ${#CNTOOLS_DREP_SCRIPT_HASHES[@]} < 20 )) || { cntools_drep_script_fail 'At most 20 participants are supported.'; return 1; }
  for existing in "${CNTOOLS_DREP_SCRIPT_HASHES[@]}"; do
    [[ "${existing}" != "${hash}" ]] || { cntools_drep_script_fail 'That participant is already included.'; return 1; }
  done
  CNTOOLS_DREP_SCRIPT_HASHES+=("${hash}"); CNTOOLS_DREP_SCRIPT_LABELS+=("${label}")
}

cntools_wallet_drep_script_id_validate() {
  local id='' canonical='' kind='' hash=''
  cntools_wallet_safe_regular_file "$1" 256 || return 1
  id="$(jq -Rers 'select(test("^drep1[023456789acdefghjklmnpqrstuvwxyz]+\\n?$")) | sub("\\n$"; "")' "$1")" || return 1
  cntools_drep_id_into canonical kind hash "${id}" && [[ "${kind}" == script ]]
}

cntools_drep_script_filename_safe() {
  local name="${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" variable='' reserved=''
  local -a names=()
  cntools_drep_key_filenames_into names || return 1
  [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${name}" != *.gpg ]] || return 1
  for reserved in "${names[@]}" "${names[0]}.gpg" drep.derivation.path; do [[ "${name}" != "${reserved}" ]] || return 1; done
  for variable in ${!CNTOOLS_WALLET_@}; do
    [[ "${variable}" == *_FILENAME && "${variable}" != CNTOOLS_WALLET_DREP_SCRIPT_FILENAME ]] || continue
    [[ "${name}" != "${!variable}" && "${name}" != "${!variable}.gpg" ]] || return 1
  done
}

cntools_drep_script_preflight() {
  local directory="$1" name=''
  local -a names=()
  if ! cntools_drep_script_filename_safe || ! cntools_drep_key_filenames_into names; then
    cntools_drep_script_fail 'Unsafe or conflicting DRep filenames.'; return 1
  fi
  cntools_wallet_protection_entries_safe "${directory}" ||
    { cntools_drep_script_fail "${CNTOOLS_WALLET_PROTECTION_ERROR:-Unsafe or unwritable wallet directory.}"; return 1; }
  # Adding public files does not require unlocking private keys. Any existing
  # DRep identity, however, must remain untouched (including incomplete ones).
  for name in "${names[@]}" "${names[0]}.gpg" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" \
    "${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" "${CNTOOLS_WALLET_DREP_REGISTER_CERT_FILENAME:-drep-reg.cert}" \
    "${CNTOOLS_WALLET_DREP_RETIRE_CERT_FILENAME:-drep-ret.cert}"; do
    if cntools_wallet_material_entry_exists "${directory}/${name}"; then
      cntools_drep_script_fail "Existing DRep material was retained (${name}). Use Info & Status to inspect it."
      return 1
    fi
  done
}

cntools_drep_script_id_into() {
  local destination="$1" script="$2" ds_hash='' ds_id=''
  cntools_transaction_native_script_hash_into ds_hash "${script}" || return 1
  # CIP-129: DRep (2) + script credential (3). The pinned CLI's DRep ID
  # command accepts keys only; share the existing checksum-tested encoder.
  cntools_drep_bech32_into ds_id "23${ds_hash}" || return 1
  printf -v "${destination}" '%s' "${ds_id}"
}

cntools_drep_script_vkey_hash_into() {
  local destination="$1" file="$2" ds_frozen='' ds_output='' ds_errors='' ds_id='' ds_kind='' ds_hash='' status=0
  if ! cntools_transaction_snapshot_into ds_frozen "${file}" 65536 drep-participant ||
    ! cntools_wallet_key_normal_envelope_valid "${ds_frozen}" drep verification; then
    cntools_drep_script_fail 'Use a normal DRep verification key envelope. No private keys are needed.'; return 1
  fi
  cntools_transaction_temp_file ds_output drep-participant-id && cntools_transaction_temp_file ds_errors drep-participant-errors || return 1
  cntools_transaction_run_cli "${ds_output}" "${ds_errors}" -- "${CNTOOLS_CLI}" latest governance drep id \
    --drep-verification-key-file "${ds_frozen}" --output-cip129 || status=$?
  if ((status != 0)); then
    cntools_transaction_log_cli_failure 'Could not identify the external DRep verification key' "${status}" "${ds_errors}" "${ds_output}"; return 1
  fi
  cntools_wallet_drep_id_validate "${ds_output}" && cntools_drep_id_into ds_id ds_kind ds_hash "$(< "${ds_output}")" || return 1
  printf -v "${destination}" '%s' "${ds_hash}"
}

cntools_drep_script_inspect() {
  local directory="$1" script="${1}/${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}"
  local idfile="${1}/${CNTOOLS_WALLET_DREP_ID_FILENAME:-drep.id}" frozen='' derived='' cached='' entry='' temporary=''
  local -a names=()
  CNTOOLS_DREP_SCRIPT_THRESHOLD='' CNTOOLS_DREP_SCRIPT_PARTICIPANTS=''
  CNTOOLS_DREP_KEY_VERIFIED=N
  cntools_drep_script_filename_safe && cntools_drep_key_filenames_into names || return 1
  for entry in "${names[0]}" "${names[1]}" "${names[3]}" "${names[0]}.gpg" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}"; do
    if cntools_wallet_material_entry_exists "${directory}/${entry}"; then
      cntools_drep_script_fail 'Conflicting script and key DRep identities. Existing files were retained.'; return 1
    fi
  done
  if ! cntools_transaction_snapshot_into frozen "${script}" 262144 drep-script || ! cntools_transaction_native_script_valid "${frozen}"; then
    cntools_drep_script_fail 'Invalid or unsafe DRep native script.'; return 1
  fi
  if [[ -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" ]]; then
    cntools_drep_script_id_into derived "${frozen}" || { cntools_drep_script_fail 'Could not verify the DRep script hash; see the command log.'; return 1; }
  fi
  if ! cntools_wallet_safe_regular_file "${script}" 262144 || ! cmp -s -- "${frozen}" "${script}"; then
    cntools_drep_script_fail 'The DRep script changed during inspection.'; return 1
  fi
  if cntools_wallet_material_entry_exists "${idfile}"; then
    cntools_wallet_drep_script_id_validate "${idfile}" || { cntools_drep_script_fail 'Invalid script DRep ID; existing files were retained.'; return 1; }
    cached="$(< "${idfile}")"
  elif [[ -n "${derived}" ]]; then
    cntools_wallet_material_temp_file temporary "${directory}" drep-script-id || return 1
    printf '%s\n' "${derived}" > "${temporary}" || return 1
    cntools_wallet_material_publish "${temporary}" "${idfile}" cntools_wallet_drep_script_id_validate || return 1
    cached="$(< "${idfile}")"
  else
    cntools_drep_script_fail 'Cardano CLI is needed to generate a missing script DRep ID. Restore the cached ID for offline inspection.'; return 1
  fi
  cntools_drep_id_into CNTOOLS_DREP_KEY_ID CNTOOLS_DREP_KEY_KIND CNTOOLS_DREP_KEY_HASH "${cached}" || return 1
  [[ -z "${derived}" || "${derived}" == "${CNTOOLS_DREP_KEY_ID}" ]] ||
    { cntools_drep_script_fail 'The DRep ID does not match the native script. Neither was changed.'; return 1; }
  # Detect source replacement during CLI verification before claiming a match.
  if ! cntools_wallet_safe_regular_file "${script}" 262144 || ! cmp -s -- "${frozen}" "${script}"; then
    cntools_drep_script_fail 'The DRep script changed during inspection.'; return 1
  fi
  [[ -z "${derived}" ]] || CNTOOLS_DREP_KEY_VERIFIED=Y
  CNTOOLS_DREP_SCRIPT_PARTICIPANTS="$(jq -r '[.. | objects | select(.type == "sig") | .keyHash | ascii_downcase] | unique | length' "${frozen}")" || return 1
  CNTOOLS_DREP_SCRIPT_THRESHOLD="$(jq -r 'if .type == "atLeast" and all(.scripts[]; .type == "sig") then .required else empty end' "${frozen}")" || return 1
}

cntools_drep_script_publication_cleanup() {
  local index=0 source='' target='' status=0
  for index in "${!CNTOOLS_DREP_SCRIPT_LINK_SOURCES[@]}"; do
    source="${CNTOOLS_DREP_SCRIPT_LINK_SOURCES[index]}"; target="${CNTOOLS_DREP_SCRIPT_LINK_TARGETS[index]}"
    cntools_wallet_create_stage_safe "${source%/*}" || { status=1; continue; }
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" && "${target}" -ef "${source}" ]] || continue
    rm -f -- "${target}" || status=1
  done
  CNTOOLS_DREP_SCRIPT_LINK_SOURCES=(); CNTOOLS_DREP_SCRIPT_LINK_TARGETS=()
  return "${status}"
}

cntools_drep_script_create() {
  local directory="$1" threshold="$2" stage='' name='' source='' id='' existing=''
  local -A seen=()
  local -a artifacts=("${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" "${CNTOOLS_WALLET_DREP_ID_FILENAME:-drep.id}")
  CNTOOLS_DREP_KEY_ERROR=''
  cntools_drep_script_preflight "${directory}" && cntools_transaction_require_cli || return 1
  if [[ ! "${threshold}" =~ ^[1-9][0-9]?$ ]] || ((threshold>${#CNTOOLS_DREP_SCRIPT_HASHES[@]} || ${#CNTOOLS_DREP_SCRIPT_HASHES[@]}>20)); then
    cntools_drep_script_fail 'Choose a threshold from one through the participant count (maximum 20).'; return 1
  fi
  for existing in "${CNTOOLS_DREP_SCRIPT_HASHES[@]}"; do
    [[ "${existing}" =~ ^[0-9a-f]{56}$ && -z "${seen[${existing}]+x}" ]] ||
      { cntools_drep_script_fail 'Invalid or duplicate DRep participant hash.'; return 1; }
    seen["${existing}"]=1
  done
  cntools_wallet_create_stage_into stage || return 1
  if ! cntools_multisig_script_write "${stage}/${artifacts[0]}" CNTOOLS_DREP_SCRIPT_HASHES "${threshold}" '' '' ||
    ! cntools_drep_script_id_into id "${stage}/${artifacts[0]}" ||
    ! printf '%s\n' "${id}" > "${stage}/${artifacts[1]}" ||
    ! cntools_wallet_drep_script_id_validate "${stage}/${artifacts[1]}" ||
    ! cntools_drep_script_preflight "${directory}"; then
    cntools_wallet_create_remove_stage "${stage}" || true
    cntools_drep_script_fail "${CNTOOLS_DREP_KEY_ERROR:-The DRep script could not be validated. No existing files were replaced.}"; return 1
  fi
  # Publish the ID first: an inspector must not see a script without its ID
  # and generate a competing cache file during this two-file publication.
  for name in "${artifacts[1]}" "${artifacts[0]}"; do
    source="${stage}/${name}"
    # Track before linking: interruption after ln must undo our inode only.
    CNTOOLS_DREP_SCRIPT_LINK_SOURCES+=("${source}"); CNTOOLS_DREP_SCRIPT_LINK_TARGETS+=("${directory}/${name}")
    if ! chmod 0600 "${source}" || ! ln -T -- "${source}" "${directory}/${name}" 2>/dev/null; then
      cntools_drep_script_publication_cleanup || true
      cntools_wallet_create_remove_stage "${stage}" || true
      cntools_drep_script_fail 'DRep publication failed. Existing files were retained; any partial new identity was removed.'; return 1
    fi
  done
  CNTOOLS_DREP_SCRIPT_LINK_SOURCES=(); CNTOOLS_DREP_SCRIPT_LINK_TARGETS=()
  cntools_wallet_create_remove_stage "${stage}" || return 1
  cntools_log WALLET "Script DRep created wallet=${directory##*/} threshold=${threshold} participants=${#CNTOOLS_DREP_SCRIPT_HASHES[@]} id=${id}" || true
}
