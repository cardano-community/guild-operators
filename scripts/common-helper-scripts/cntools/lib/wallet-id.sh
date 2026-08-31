#!/usr/bin/env bash
# Missing-only wallet credential hashes plus local CIP-14 asset fingerprints.
# shellcheck disable=SC2034

cntools_wallet_id_validate() {
  local credential_file="${1:-}"
  local credential=""
  local nul_probe=""
  local -a lines=()

  cntools_wallet_safe_regular_file "${credential_file}" 256 || return 1
  if IFS= read -r -d '' nul_probe < "${credential_file}"; then
    return 1
  fi
  mapfile -t lines < "${credential_file}" || return 1
  [[ ${#lines[@]} -eq 1 ]] || return 1
  credential="${lines[0]}"
  [[ "${credential}" =~ ^[0-9a-fA-F]{56}$ ]]
}

cntools_wallet_id_credential_filename() {
  local kind="${1:-}"
  local prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"

  case "${kind}" in
    payment) printf '%s\n' "${CNTOOLS_WALLET_PAY_CRED_FILENAME}" ;;
    stake) printf '%s\n' "${CNTOOLS_WALLET_STAKE_CRED_FILENAME}" ;;
    ms-payment)
      printf '%s%s\n' "${prefix}" "${CNTOOLS_WALLET_PAY_CRED_FILENAME}"
      ;;
    ms-stake)
      printf '%s%s\n' "${prefix}" "${CNTOOLS_WALLET_STAKE_CRED_FILENAME}"
      ;;
    script-payment)
      printf '%s\n' "${CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME}"
      ;;
    script-stake)
      printf '%s\n' "${CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME}"
      ;;
    *) return 2 ;;
  esac
}

cntools_wallet_id_read_credential() {
  local _cntools_wallet_directory="${1:-}"
  local _cntools_kind="${2:-}"
  local _cntools_output_name="${3:-}"
  local _cntools_filename=""
  local _cntools_file=""
  local _cntools_value=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_directory_safe "${_cntools_wallet_directory}" || return 1
  _cntools_filename="$(cntools_wallet_id_credential_filename \
    "${_cntools_kind}")" || return 2
  _cntools_file="${_cntools_wallet_directory}/${_cntools_filename}"
  [[ -e "${_cntools_file}" || -L "${_cntools_file}" ]] || return 1
  cntools_wallet_id_validate "${_cntools_file}" || return 2
  IFS= read -r _cntools_value < "${_cntools_file}" || return 2
  _cntools_output_ref="${_cntools_value}"
}

cntools_wallet_id_generate_key_credential() {
  local wallet_directory="${1:-}"
  local role="${2:-}"
  local verification_filename="${3:-}"
  local credential_filename="${4:-}"
  local verification_file="${wallet_directory}/${verification_filename}"
  local credential_file="${wallet_directory}/${credential_filename}"
  local staged_file=""
  local error_file=""
  local status=0
  local -a arguments=()

  case "${role}" in
    payment)
      arguments=(address key-hash --payment-verification-key-file \
        "${verification_file}")
      ;;
    stake)
      arguments=(stake-address key-hash --stake-verification-key-file \
        "${verification_file}")
      ;;
    *) return 2 ;;
  esac
  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  if cntools_wallet_material_entry_exists "${credential_file}"; then
    cntools_wallet_material_existing_valid \
      "${credential_file}" cntools_wallet_id_validate
    return $?
  fi
  if ! cntools_wallet_material_entry_exists "${verification_file}"; then
    return 0
  fi
  cntools_wallet_safe_regular_file "${verification_file}" 65536 || {
    cntools_wallet_material_log ERROR \
      "Invalid verification key retained without deriving ${credential_filename} wallet=${wallet_directory##*/}"
    return 1
  }

  cntools_wallet_material_temp_file \
    staged_file "${wallet_directory}" "${role}-credential" || return 1
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" "${role}-credential-error" || {
      cntools_wallet_material_remove_temp "${staged_file}" || true
      return 1
    }
  if cntools_wallet_material_run_cli "${error_file}" -- \
      "${CNTOOLS_CLI}" "${arguments[@]}" --out-file "${staged_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_material_log_cli_failure \
      "Could not generate ${credential_filename}" "${status}" "${error_file}"
    cntools_wallet_material_remove_temp "${staged_file}" || true
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true
  cntools_wallet_material_publish \
    "${staged_file}" "${credential_file}" cntools_wallet_id_validate
}

cntools_wallet_id_generate_script_credential() {
  local wallet_directory="${1:-}"
  local script_filename="${2:-}"
  local credential_filename="${3:-}"
  local script_file="${wallet_directory}/${script_filename}"
  local credential_file="${wallet_directory}/${credential_filename}"
  local staged_file=""
  local error_file=""
  local status=0

  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  if cntools_wallet_material_entry_exists "${credential_file}"; then
    cntools_wallet_material_existing_valid \
      "${credential_file}" cntools_wallet_id_validate
    return $?
  fi
  if ! cntools_wallet_material_entry_exists "${script_file}"; then
    return 0
  fi
  cntools_wallet_safe_regular_file "${script_file}" 65536 || {
    cntools_wallet_material_log ERROR \
      "Invalid native script retained without deriving ${credential_filename} wallet=${wallet_directory##*/}"
    return 1
  }

  cntools_wallet_material_temp_file \
    staged_file "${wallet_directory}" "script-credential" || return 1
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" "script-credential-error" || {
      cntools_wallet_material_remove_temp "${staged_file}" || true
      return 1
    }
  if cntools_wallet_material_run_cli "${error_file}" -- \
      "${CNTOOLS_CLI}" hash script --script-file "${script_file}" \
      --out-file "${staged_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_material_log_cli_failure \
      "Could not generate ${credential_filename}" "${status}" "${error_file}"
    cntools_wallet_material_remove_temp "${staged_file}" || true
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true
  cntools_wallet_material_publish \
    "${staged_file}" "${credential_file}" cntools_wallet_id_validate
}

cntools_wallet_id_materialize_credentials() {
  local wallet_directory="${1:-}"
  local prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"
  local failures=0

  cntools_wallet_id_generate_key_credential \
    "${wallet_directory}" payment \
    "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_CRED_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_id_generate_key_credential \
    "${wallet_directory}" stake \
    "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
    "${CNTOOLS_WALLET_STAKE_CRED_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_id_generate_key_credential \
    "${wallet_directory}" payment \
    "${prefix}${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
    "${prefix}${CNTOOLS_WALLET_PAY_CRED_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_id_generate_key_credential \
    "${wallet_directory}" stake \
    "${prefix}${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
    "${prefix}${CNTOOLS_WALLET_STAKE_CRED_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_id_generate_script_credential \
    "${wallet_directory}" "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_id_generate_script_credential \
    "${wallet_directory}" "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" \
    "${CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME}" || failures=$((failures + 1))
  (( failures == 0 ))
}

cntools_wallet_id_temp_file() {
  local _cntools_output_name="${1:-}"
  local _cntools_label="${2:-cip14}"
  local _cntools_previous_umask=""
  local _cntools_file=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label}" =~ ^[A-Za-z0-9._-]+$ &&
     -d "${CNTOOLS_TMP_DIR:-}" && ! -L "${CNTOOLS_TMP_DIR}" &&
     -O "${CNTOOLS_TMP_DIR}" && -w "${CNTOOLS_TMP_DIR}" ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_file="$(mktemp \
    "${CNTOOLS_TMP_DIR}/.cntools-${_cntools_label}.XXXXXX")" || {
      umask "${_cntools_previous_umask}"
      return 1
    }
  umask "${_cntools_previous_umask}"
  [[ -f "${_cntools_file}" && ! -L "${_cntools_file}" &&
     -O "${_cntools_file}" ]] || {
    rm -f -- "${_cntools_file}" 2>/dev/null || true
    return 1
  }
  chmod 0600 "${_cntools_file}" || {
    rm -f -- "${_cntools_file}" 2>/dev/null || true
    return 1
  }
  CNTOOLS_WALLET_MATERIAL_TEMP_FILES+=("${_cntools_file}")
  _cntools_output_ref="${_cntools_file}"
}

cntools_wallet_id_remove_temp() {
  local temporary_file="${1:-}"

  cntools_wallet_material_remove_temp "${temporary_file}" || true
}

cntools_wallet_asset_fingerprint_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_policy_id="${2:-}"
  local _cntools_asset_name="${3:-}"
  local _cntools_hex=""
  local _cntools_byte=""
  local _cntools_hash=""
  local _cntools_extra=""
  local _cntools_fingerprint=""
  local _cntools_binary_file=""
  local _cntools_hash_file=""
  local _cntools_fingerprint_file=""
  local _cntools_b2sum=""
  local _cntools_bech32=""
  local _cntools_mask=""
  local _cntools_index=0
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_policy_id="${_cntools_policy_id,,}"
  _cntools_asset_name="${_cntools_asset_name,,}"
  [[ "${_cntools_policy_id}" =~ ^[0-9a-f]{56}$ &&
     "${_cntools_asset_name}" =~ ^([0-9a-f]{2}){0,32}$ ]] || return 2
  _cntools_b2sum="$(command -v b2sum 2>/dev/null || true)"
  _cntools_bech32="$(command -v bech32 2>/dev/null || true)"
  [[ "${_cntools_b2sum}" = /* && -x "${_cntools_b2sum}" &&
     "${_cntools_bech32}" = /* && -x "${_cntools_bech32}" ]] || return 1
  cntools_wallet_id_temp_file _cntools_binary_file cip14-bytes || return 1
  cntools_wallet_id_temp_file _cntools_hash_file cip14-hash || {
    cntools_wallet_id_remove_temp "${_cntools_binary_file}"
    return 1
  }
  cntools_wallet_id_temp_file _cntools_fingerprint_file cip14-fingerprint || {
    cntools_wallet_id_remove_temp "${_cntools_binary_file}"
    cntools_wallet_id_remove_temp "${_cntools_hash_file}"
    return 1
  }

  _cntools_hex="${_cntools_policy_id}${_cntools_asset_name}"
  : > "${_cntools_binary_file}"
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_hex};
         _cntools_index += 2 )); do
    _cntools_byte="${_cntools_hex:_cntools_index:2}"
    printf '%b' "\\x${_cntools_byte}" >> "${_cntools_binary_file}" || {
      cntools_wallet_id_remove_temp "${_cntools_binary_file}"
      cntools_wallet_id_remove_temp "${_cntools_hash_file}"
      cntools_wallet_id_remove_temp "${_cntools_fingerprint_file}"
      return 1
    }
  done
  printf -v _cntools_mask '%*s' 5 ''
  _cntools_mask="${_cntools_mask// /0}"
  if cntools_run_command "${_cntools_mask}" -- \
      "${_cntools_b2sum}" -l 160 -b "${_cntools_binary_file}" \
      > "${_cntools_hash_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status == 0 )); then
    read -r _cntools_hash _cntools_extra < "${_cntools_hash_file}" ||
      _cntools_status=1
    [[ "${_cntools_hash}" =~ ^[0-9a-fA-F]{40}$ ]] || _cntools_status=1
  fi
  if (( _cntools_status == 0 )); then
    printf '%s\n' "${_cntools_hash}" > "${_cntools_hash_file}"
    if cntools_run_command 00 -- "${_cntools_bech32}" asset \
        < "${_cntools_hash_file}" > "${_cntools_fingerprint_file}"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
  fi
  if (( _cntools_status == 0 )); then
    IFS= read -r _cntools_fingerprint < "${_cntools_fingerprint_file}" ||
      _cntools_status=1
    [[ "${_cntools_fingerprint}" =~ ^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$ ]] ||
      _cntools_status=1
  fi
  cntools_wallet_id_remove_temp "${_cntools_binary_file}"
  cntools_wallet_id_remove_temp "${_cntools_hash_file}"
  cntools_wallet_id_remove_temp "${_cntools_fingerprint_file}"
  (( _cntools_status == 0 )) || return 1
  _cntools_output_ref="${_cntools_fingerprint}"
}

cntools_wallet_asset_fingerprint() {
  local fingerprint=""

  cntools_wallet_asset_fingerprint_into \
    fingerprint "${1:-}" "${2:-}" || return $?
  printf '%s\n' "${fingerprint}"
}
