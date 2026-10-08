#!/usr/bin/env bash
# Legacy-compatible cold-key encryption. Runtime KES/VRF keys are not encrypted.
# shellcheck disable=SC2034,SC2015
CNTOOLS_POOL_PROTECTION_SOURCE=''
CNTOOLS_POOL_PROTECTION_TARGET=''
CNTOOLS_POOL_PROTECTION_STAGED=''
CNTOOLS_POOL_PROTECTION_DIRECTORY=''

cntools_pool_protection_preflight() {
  local directory="$1" operation="$2" file="" mode="" cold="" hws=""
  cntools_pool_filenames_validate || return 1
  [[ "${directory%/*}" == "${CNTOOLS_POOL_DIR%/}" ]] && cntools_transaction_path_components_safe "${directory}" &&
    [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" && -w "${directory}" ]] &&
    cntools_transaction_directory_ancestry_safe "${directory%/*}" || return 1
  for file in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    [[ -f "${file}" && ! -L "${file}" && -O "${file}" && "${file##*/}" != .cntools-* ]] || {
      cntools_pool_write_error 'The pool contains linked, unowned, nested or unfinished files. Nothing was changed.'; return 1;
    }
  done
  cntools_pool_file_name_into cold cold-skey; cntools_pool_file_name_into hws cold-hardware
  [[ ! ( -e "${directory}/${cold}" && -e "${directory}/${cold}.gpg" ) &&
     ! ( -e "${directory}/${hws}" && ( -e "${directory}/${cold}" || -e "${directory}/${cold}.gpg" ) ) ]] || {
    cntools_pool_write_error 'Mixed cold signing material must be resolved before protection.'; return 1;
  }
  for file in "${directory}"/*.gpg; do
    [[ -e "${file}" ]] || continue
    [[ "${file}" == "${directory}/${cold}.gpg" ]] || { cntools_pool_write_error 'Unsupported encrypted pool file. It was not changed.'; return 1; }
  done
  if [[ "${operation}" == encrypt && -e "${directory}/${cold}.gpg" ]]; then
    cntools_pool_write_error 'The cold key is already encrypted. Decrypt/unlock it first.'; return 1
  fi
  if [[ -e "${directory}/${cold}" ]]; then
    cntools_pool_key_validate "${directory}/${cold}" cold signing || { cntools_pool_write_error 'The cold signing key is invalid.'; return 1; }
  fi
  cntools_transaction_mode_into mode "${directory}" || return 1
  if (( (8#${mode} & 0022) != 0 )); then
    cntools_run_command 000 -- chmod "$(printf '%03o' "$((8#${mode} & 0755))")" "${directory}" || return 1
  fi
  cntools_pool_directory_writable "${directory}"
}

cntools_pool_cold_matches() {
  local signing="$1" directory="$2" public="" derived=""
  cntools_pool_key_validate "${signing}" cold signing || return 1
  cntools_pool_file_name_into public cold-vkey
  [[ -e "${directory}/${public}" ]] || return 0
  cntools_pool_key_validate "${directory}/${public}" cold verification || return 1
  cntools_pool_temp_into derived "${directory}" || return 1
  cntools_pool_cli key verification-key --signing-key-file "${signing}" --verification-key-file "${derived}" || return 1
  jq -es 'length == 2 and (.[0].cborHex|ascii_downcase) == (.[1].cborHex|ascii_downcase)' "${derived}" "${directory}/${public}" >/dev/null
}

cntools_pool_protection_cleanup() {
  # Only discard our new counterpart when the original still exists. An
  # interruption after source retirement must never discard the last key copy.
  if [[ -n "${CNTOOLS_POOL_PROTECTION_SOURCE}" && -f "${CNTOOLS_POOL_PROTECTION_SOURCE}" && ! -L "${CNTOOLS_POOL_PROTECTION_SOURCE}" &&
       -n "${CNTOOLS_POOL_PROTECTION_TARGET}" && -f "${CNTOOLS_POOL_PROTECTION_TARGET}" && ! -L "${CNTOOLS_POOL_PROTECTION_TARGET}" &&
       -O "${CNTOOLS_POOL_PROTECTION_TARGET}" && -n "${CNTOOLS_POOL_PROTECTION_STAGED}" &&
       "${CNTOOLS_POOL_PROTECTION_TARGET}" -ef "${CNTOOLS_POOL_PROTECTION_STAGED}" ]]; then
    rm -f -- "${CNTOOLS_POOL_PROTECTION_TARGET}" || true
  fi
  cntools_pool_locks_restore || true
  CNTOOLS_POOL_PROTECTION_SOURCE=''; CNTOOLS_POOL_PROTECTION_TARGET=''; CNTOOLS_POOL_PROTECTION_STAGED=''
  cntools_pool_files_cleanup
}

cntools_pool_protect() {
  local directory="$1" operation="$2" password="${3:-}" cold="" source="" target="" staged="" snapshot="" roundtrip="" errors="" binary="" status=0
  CNTOOLS_POOL_WRITE_ERROR=''; CNTOOLS_POOL_WRITE_WARNING=''
  CNTOOLS_POOL_PROTECTION_SOURCE=''; CNTOOLS_POOL_PROTECTION_TARGET=''; CNTOOLS_POOL_PROTECTION_STAGED=''; CNTOOLS_POOL_UNLOCKED=()
  [[ "${operation}" == encrypt || "${operation}" == decrypt ]] || return 2
  cntools_pool_protection_preflight "${directory}" "${operation}" || {
    [[ -n "${CNTOOLS_POOL_WRITE_ERROR}" ]] || cntools_pool_write_error 'The pool must be owned, writable and safe to modify.'; return 1;
  }
  cntools_pool_file_name_into cold cold-skey
  source="${directory}/${cold}"; target="${source}.gpg"
  [[ "${operation}" != decrypt ]] || { source="${directory}/${cold}.gpg"; target="${directory}/${cold}"; }
  if [[ -f "${source}" ]]; then
    [[ -n "${password}" && "${password}" != *$'\n'* && "${password}" != *$'\r'* ]] &&
      { [[ "${operation}" != encrypt ]] || (( ${#password} >= 12 )); } || {
      cntools_pool_write_error 'New encryption passwords require at least 12 characters. Decryption accepts any nonempty single-line password.'; return 1;
    }
    binary="$(type -P gpg || type -P gpg2 || true)"; [[ -n "${binary}" ]] || { cntools_pool_write_error 'GnuPG is required to protect/open the pool cold signing key.'; return 1; }
    cntools_pool_public_file_safe "${source}" 1048576 || return 1
    cntools_pool_temp_into snapshot "${directory}" && cntools_pool_temp_into staged "${directory}" && cntools_pool_temp_into errors "${directory}" || return 1
    cntools_run_command 0000 -- cp -- "${source}" "${snapshot}" || return 1
    status=0
    cntools_key_crypto_run "${binary}" "${operation}" "${snapshot}" "${staged}" "${password}" "${errors}" || status=$?
    if ((status != 0)); then
      cntools_transaction_log_cli_failure "Pool GPG ${operation} failed; original files retained" "${status}" "${errors}" ''
      cntools_pool_write_error 'The cold key could not be opened/protected. Check the password and GPG installation.'; return 1
    fi
    if [[ "${operation}" == encrypt ]]; then
      cntools_pool_temp_into roundtrip "${directory}" || return 1
      cntools_key_crypto_run "${binary}" decrypt "${staged}" "${roundtrip}" "${password}" "${errors}" &&
        cmp -s "${snapshot}" "${roundtrip}" && cntools_pool_cold_matches "${roundtrip}" "${directory}" || {
        cntools_pool_write_error 'Cold-key encryption could not be round-trip verified.'; return 1;
      }
    else
      cntools_pool_cold_matches "${staged}" "${directory}" || { cntools_pool_write_error 'The decrypted cold key is invalid or does not match the public key.'; return 1; }
    fi
    # Stage all validation before changing immutable flags or original files.
    cntools_pool_locks_unlock "${directory}" || return 1
    cntools_pool_public_file_safe "${source}" 1048576 && cmp -s "${source}" "${snapshot}" || {
      cntools_pool_write_error 'The cold-key source changed during preparation. Nothing was replaced.'; return 1;
    }
    [[ ! -e "${target}" && ! -L "${target}" ]] || return 1
    ln -T -- "${staged}" "${target}" || { cntools_pool_locks_restore || true; return 1; }
    CNTOOLS_POOL_PROTECTION_SOURCE="${source}"; CNTOOLS_POOL_PROTECTION_TARGET="${target}"; CNTOOLS_POOL_PROTECTION_STAGED="${staged}"
    if ! cntools_run_command 0000 -- rm -f -- "${source}"; then
      cntools_pool_protection_cleanup
      cntools_pool_write_error 'The original cold key could not be retired. Original protection was retained.'; return 1
    fi
    CNTOOLS_POOL_PROTECTION_SOURCE=''; CNTOOLS_POOL_PROTECTION_TARGET=''; CNTOOLS_POOL_PROTECTION_STAGED=''
  else
    # Hardware/watch-only pools can still lock or unlock their local files.
    cntools_pool_locks_unlock "${directory}" || return 1
  fi
  CNTOOLS_POOL_UNLOCKED=()
  cntools_pool_files_cleanup_temps
  cntools_pool_locks_apply "${directory}" "${operation}" || status=$?
  cntools_pool_files_cleanup_temps
  cntools_transaction_log POOL "Protection pool=${directory##*/} operation=${operation} lock=${CNTOOLS_POOL_LOCK_METHOD} warning=${CNTOOLS_POOL_WRITE_WARNING:-none}"
  return "${status}"
}
