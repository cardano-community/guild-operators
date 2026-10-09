#!/usr/bin/env bash
# Legacy-compatible cold/Calidus encryption. Runtime KES/VRF keys stay readable.
# shellcheck disable=SC2034,SC2015
declare -ag CNTOOLS_POOL_PROTECTION_SOURCES=() CNTOOLS_POOL_PROTECTION_TARGETS=()
declare -ag CNTOOLS_POOL_PROTECTION_STAGED=() CNTOOLS_POOL_PROTECTION_SNAPSHOTS=() CNTOOLS_POOL_PROTECTION_MODES=()
CNTOOLS_POOL_PROTECTION_KEYS=0

cntools_pool_protection_preflight() {
  local directory="$1" operation="$2" file="" mode="" cold="" hws="" calidus="" key=""
  cntools_pool_filenames_validate || return 1
  [[ "${directory%/*}" == "${CNTOOLS_POOL_DIR%/}" ]] && cntools_filesystem_path_components_safe "${directory}" &&
    [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" && -w "${directory}" ]] &&
    cntools_filesystem_directory_ancestry_safe "${directory%/*}" || return 1
  for file in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    [[ -f "${file}" && ! -L "${file}" && -O "${file}" && "${file##*/}" != .cntools-* ]] || {
      cntools_pool_write_error 'The pool contains linked, unowned, nested or unfinished files. Nothing was changed.'; return 1;
    }
  done
  cntools_pool_file_name_into cold cold-skey; cntools_pool_file_name_into hws cold-hardware
  cntools_pool_file_name_into calidus calidus-skey
  [[ ! ( -e "${directory}/${hws}" && ( -e "${directory}/${cold}" || -e "${directory}/${cold}.gpg" ) ) ]] || {
    cntools_pool_write_error 'Mixed cold signing material must be resolved before protection.'; return 1;
  }
  for key in "${cold}" "${calidus}"; do
    [[ ! ( -e "${directory}/${key}" && -e "${directory}/${key}.gpg" ) ]] || {
      cntools_pool_write_error 'Both clear and encrypted copies of a signing key exist. Neither was changed.'; return 1;
    }
  done
  for file in "${directory}"/*.gpg; do
    [[ -e "${file}" ]] || continue
    [[ "${file}" == "${directory}/${cold}.gpg" || "${file}" == "${directory}/${calidus}.gpg" ]] || { cntools_pool_write_error 'Unsupported encrypted pool file. It was not changed.'; return 1; }
    [[ "${operation}" != encrypt ]] || {
      cntools_pool_write_error 'The pool already contains encrypted signing keys. Decrypt/unlock it first.'; return 1;
    }
  done
  if [[ -e "${directory}/${cold}" ]]; then
    cntools_pool_key_validate "${directory}/${cold}" cold signing || { cntools_pool_write_error 'The cold signing key is invalid.'; return 1; }
  fi
  cntools_filesystem_mode_into mode "${directory}" || return 1
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
  local index=0 source='' target='' staged='' snapshot='' recovery=N
  # Restore originals already retired before removing our own counterparts.
  # Never overwrite a new file, follow a link, or discard the last key copy.
  for index in "${!CNTOOLS_POOL_PROTECTION_TARGETS[@]}"; do
    source="${CNTOOLS_POOL_PROTECTION_SOURCES[index]}"; target="${CNTOOLS_POOL_PROTECTION_TARGETS[index]}"
    staged="${CNTOOLS_POOL_PROTECTION_STAGED[index]:-}"; snapshot="${CNTOOLS_POOL_PROTECTION_SNAPSHOTS[index]:-}"
    if ! cntools_pool_directory_writable "${source%/*}"; then recovery=Y; continue; fi
    if [[ ! -e "${source}" && ! -L "${source}" && -n "${snapshot}" && -f "${snapshot}" && ! -L "${snapshot}" && -O "${snapshot}" ]] &&
        cntools_pool_directory_writable "${source%/*}"; then
      chmod "${CNTOOLS_POOL_PROTECTION_MODES[index]}" "${snapshot}" && ln -T -- "${snapshot}" "${source}" || true
    fi
    if [[ -f "${target}" && ! -L "${target}" && -O "${target}" && -n "${staged}" && "${target}" -ef "${staged}" ]]; then
      if [[ -f "${source}" && ! -L "${source}" && -O "${source}" && -n "${snapshot}" ]] && cmp -s "${source}" "${snapshot}"; then
        rm -f -- "${target}" || cntools_transaction_log ERROR "Could not remove pool protection counterpart=${target}"
      fi
    elif [[ ! -f "${source}" || -L "${source}" ]]; then
      recovery=Y
    fi
  done
  if [[ "${recovery}" == Y ]]; then
    cntools_pool_write_error 'Pool files changed unexpectedly. Private recovery files were retained in the pool directory; review it before retrying.' || true
    CNTOOLS_POOL_WRITE_WARNING='Private recovery files were retained in the pool directory. Review them before retrying; never discard the last validated key copy.'
    # Detach private recovery files from automatic cleanup, including its
    # later invocation by the action's interruption/return hook.
    CNTOOLS_POOL_TEMP_FILES=()
  fi
  # Restored originals may be hard links to their snapshots. Remove temporary
  # aliases before reapplying +i or those aliases would become immutable too.
  cntools_pool_files_cleanup
  cntools_pool_locks_restore || true
  CNTOOLS_POOL_PROTECTION_SOURCES=(); CNTOOLS_POOL_PROTECTION_TARGETS=(); CNTOOLS_POOL_PROTECTION_STAGED=()
  CNTOOLS_POOL_PROTECTION_SNAPSHOTS=(); CNTOOLS_POOL_PROTECTION_MODES=()
}

cntools_pool_protection_key_matches() {
  case "$3" in
    cold-skey) cntools_pool_cold_matches "$1" "$2" ;;
    calidus-skey) cntools_calidus_signing_matches "$1" "$2" ;;
    *) return 2 ;;
  esac
}

cntools_pool_protect() {
  local directory="$1" operation="$2" password="${3:-}" kind='' name='' source='' target='' staged='' snapshot=''
  local roundtrip='' errors='' binary='' mode='' index=0 status=0
  local -a kinds=()
  CNTOOLS_POOL_WRITE_ERROR=''; CNTOOLS_POOL_WRITE_WARNING=''
  CNTOOLS_POOL_PROTECTION_KEYS=0
  CNTOOLS_POOL_PROTECTION_SOURCES=(); CNTOOLS_POOL_PROTECTION_TARGETS=(); CNTOOLS_POOL_PROTECTION_STAGED=()
  CNTOOLS_POOL_PROTECTION_SNAPSHOTS=(); CNTOOLS_POOL_PROTECTION_MODES=(); CNTOOLS_POOL_UNLOCKED=()
  [[ "${operation}" == encrypt || "${operation}" == decrypt ]] || return 2
  cntools_pool_protection_preflight "${directory}" "${operation}" || {
    [[ -n "${CNTOOLS_POOL_WRITE_ERROR}" ]] || cntools_pool_write_error 'The pool must be owned, writable and safe to modify.'; return 1;
  }
  for kind in cold-skey calidus-skey; do
    cntools_pool_file_name_into name "${kind}" || return 1
    source="${directory}/${name}"; target="${source}.gpg"
    [[ "${operation}" != decrypt ]] || { source="${directory}/${name}.gpg"; target="${directory}/${name}"; }
    [[ -f "${source}" ]] || continue
    CNTOOLS_POOL_PROTECTION_SOURCES+=("${source}"); CNTOOLS_POOL_PROTECTION_TARGETS+=("${target}"); kinds+=("${kind}")
  done
  if (( ${#kinds[@]} > 0 )); then
    [[ -n "${password}" && "${password}" != *$'\n'* && "${password}" != *$'\r'* ]] &&
      { [[ "${operation}" != encrypt ]] || (( ${#password} >= 12 )); } || {
      cntools_pool_write_error 'New encryption passwords require at least 12 characters. Decryption accepts any nonempty single-line password.'; return 1;
    }
    binary="$(type -P gpg || type -P gpg2 || true)"; [[ -n "${binary}" ]] || { cntools_pool_write_error 'GnuPG is required to protect/open pool signing keys.'; return 1; }
    # Freeze and round-trip every key before unlocking or publishing any key.
    for index in "${!kinds[@]}"; do
      source="${CNTOOLS_POOL_PROTECTION_SOURCES[index]}"
      cntools_pool_public_file_safe "${source}" 1048576 && cntools_filesystem_mode_into mode "${source}" &&
        cntools_pool_temp_into snapshot "${directory}" && cntools_pool_temp_into staged "${directory}" &&
        cntools_pool_temp_into errors "${directory}" && cntools_run_command 0000 -- cp -- "${source}" "${snapshot}" || return 1
      CNTOOLS_POOL_PROTECTION_STAGED+=("${staged}"); CNTOOLS_POOL_PROTECTION_SNAPSHOTS+=("${snapshot}"); CNTOOLS_POOL_PROTECTION_MODES+=("${mode}")
      status=0
      cntools_key_crypto_run "${binary}" "${operation}" "${snapshot}" "${staged}" "${password}" "${errors}" 60 65536 || status=$?
      if ((status != 0)); then
        cntools_transaction_log_cli_failure "Pool GPG ${operation} failed; originals retained" "${status}" "${errors}" ''
        cntools_pool_write_error 'A pool signing key could not be opened/protected. Check the password and GPG installation.'; return 1
      fi
      if [[ "${operation}" == encrypt ]]; then
        cntools_pool_temp_into roundtrip "${directory}" || return 1
        cntools_key_crypto_run "${binary}" decrypt "${staged}" "${roundtrip}" "${password}" "${errors}" 60 65536 &&
          cmp -s "${snapshot}" "${roundtrip}" && cntools_pool_protection_key_matches "${roundtrip}" "${directory}" "${kinds[index]}" || {
          cntools_pool_write_error 'Signing-key encryption could not be round-trip and identity verified.'; return 1;
        }
      else
        cntools_pool_protection_key_matches "${staged}" "${directory}" "${kinds[index]}" || {
          cntools_pool_write_error 'A decrypted signing key is invalid or does not match its public identity.'; return 1;
        }
      fi
    done
    cntools_pool_locks_unlock "${directory}" || return 1
    for index in "${!kinds[@]}"; do
      source="${CNTOOLS_POOL_PROTECTION_SOURCES[index]}"; target="${CNTOOLS_POOL_PROTECTION_TARGETS[index]}"
      cntools_pool_directory_writable "${directory}" && cntools_pool_public_file_safe "${source}" 1048576 &&
        cmp -s "${source}" "${CNTOOLS_POOL_PROTECTION_SNAPSHOTS[index]}" && [[ ! -e "${target}" && ! -L "${target}" ]] || {
        cntools_pool_protection_cleanup
        cntools_pool_write_error 'A pool source or destination changed during preparation. Nothing was overwritten.'; return 1;
      }
      ln -T -- "${CNTOOLS_POOL_PROTECTION_STAGED[index]}" "${target}" || {
        cntools_pool_protection_cleanup
        cntools_pool_write_error 'The signing keys could not all be published. Originals were retained.'; return 1;
      }
    done
    for index in "${!kinds[@]}"; do
      source="${CNTOOLS_POOL_PROTECTION_SOURCES[index]}"; target="${CNTOOLS_POOL_PROTECTION_TARGETS[index]}"
      if ! { cntools_pool_directory_writable "${directory}" && cntools_pool_public_file_safe "${source}" 1048576 &&
          cmp -s "${source}" "${CNTOOLS_POOL_PROTECTION_SNAPSHOTS[index]}" &&
          [[ -f "${target}" && ! -L "${target}" && "${target}" -ef "${CNTOOLS_POOL_PROTECTION_STAGED[index]}" ]] &&
          cntools_run_command 0000 -- rm -f -- "${source}"; }; then
        cntools_pool_protection_cleanup
        cntools_pool_write_error 'Not all original signing keys could be retired. Originals were restored where possible; validated counterparts were retained where required.'; return 1
      fi
    done
    CNTOOLS_POOL_PROTECTION_KEYS="${#kinds[@]}"
    CNTOOLS_POOL_PROTECTION_SOURCES=(); CNTOOLS_POOL_PROTECTION_TARGETS=(); CNTOOLS_POOL_PROTECTION_STAGED=()
    CNTOOLS_POOL_PROTECTION_SNAPSHOTS=(); CNTOOLS_POOL_PROTECTION_MODES=()
  else
    # Hardware/watch-only pools can still lock or unlock their local files.
    cntools_pool_locks_unlock "${directory}" || return 1
  fi
  CNTOOLS_POOL_UNLOCKED=()
  cntools_pool_files_cleanup_temps
  cntools_pool_locks_apply "${directory}" "${operation}" || status=$?
  cntools_pool_files_cleanup_temps
  cntools_transaction_log POOL "Protection pool=${directory##*/} operation=${operation} keys=${CNTOOLS_POOL_PROTECTION_KEYS} lock=${CNTOOLS_POOL_LOCK_METHOD} warning=${CNTOOLS_POOL_WRITE_WARNING:-none}"
  return "${status}"
}
