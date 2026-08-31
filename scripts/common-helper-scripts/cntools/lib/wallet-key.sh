#!/usr/bin/env bash
# Missing-only derivation of public payment and stake verification keys.
# Private key contents never leave cardano-cli and are never logged.
# shellcheck disable=SC2034

cntools_wallet_key_envelope_type_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_key_file="${2:-}"
  local _cntools_key_type=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_safe_regular_file "${_cntools_key_file}" 65536 || return 1
  _cntools_key_type="$(jq -ers '
    if length == 1 and
       (.[0] | type == "object") and
       (.[0].type | type == "string") and
       (.[0].cborHex | type == "string" and
         test("^([0-9a-fA-F]{2})+$") and length <= 4096)
    then .[0].type
    else empty
    end
  ' "${_cntools_key_file}" 2>/dev/null)" || return 1
  [[ -n "${_cntools_key_type}" &&
     "${_cntools_key_type}" != *$'\n'* ]] || return 1
  _cntools_output_ref="${_cntools_key_type}"
}

cntools_wallet_key_signing_type() {
  local role="${1:-}"
  local key_file="${2:-}"
  local output_name="${3:-}"
  local key_type=""

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=""
  cntools_wallet_key_envelope_type_into key_type "${key_file}" || return 1
  case "${role}:${key_type}" in
    payment:PaymentSigningKeyShelley_ed25519)
      output_ref="normal"
      ;;
    payment:PaymentExtendedSigningKeyShelley_ed25519_bip32)
      output_ref="extended"
      ;;
    stake:StakeSigningKeyShelley_ed25519)
      output_ref="normal"
      ;;
    stake:StakeExtendedSigningKeyShelley_ed25519_bip32)
      output_ref="extended"
      ;;
    *) return 1 ;;
  esac
}

cntools_wallet_key_validate() {
  local key_file="${1:-}"
  local role="${2:-}"
  local form="${3:-normal}"
  local key_type=""

  cntools_wallet_key_envelope_type_into key_type "${key_file}" || return 1
  case "${role}:${form}:${key_type}" in
    payment:normal:PaymentVerificationKeyShelley_ed25519|\
    payment:extended:PaymentExtendedVerificationKeyShelley_ed25519_bip32|\
    payment:any:PaymentVerificationKeyShelley_ed25519|\
    payment:any:PaymentExtendedVerificationKeyShelley_ed25519_bip32|\
    stake:normal:StakeVerificationKeyShelley_ed25519|\
    stake:extended:StakeExtendedVerificationKeyShelley_ed25519_bip32|\
    stake:any:StakeVerificationKeyShelley_ed25519|\
    stake:any:StakeExtendedVerificationKeyShelley_ed25519_bip32)
      return 0
      ;;
    *) return 1 ;;
  esac
}

cntools_wallet_key_materialize_role() {
  local wallet_directory="${1:-}"
  local role="${2:-}"
  local signing_filename="${3:-}"
  local verification_filename="${4:-}"
  local hardware_filename="${5:-}"
  local signing_file="${wallet_directory}/${signing_filename}"
  local verification_file="${wallet_directory}/${verification_filename}"
  local hardware_file="${wallet_directory}/${hardware_filename}"
  local extended_file=""
  local normalized_file=""
  local error_file=""
  local signing_form=""
  local status=0

  case "${role}" in payment|stake) ;; *) return 2 ;; esac
  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  if cntools_wallet_material_entry_exists "${verification_file}"; then
    cntools_wallet_material_existing_valid \
      "${verification_file}" cntools_wallet_key_validate "${role}" any
    return $?
  fi
  # Hardware signing descriptions are not cardano-cli private key envelopes.
  cntools_wallet_material_entry_exists "${hardware_file}" && return 0
  # Encrypted keys are only handled by the explicit wallet decrypt workflow.
  cntools_wallet_material_entry_exists "${signing_file}.gpg" && return 0
  if ! cntools_wallet_material_entry_exists "${signing_file}"; then
    return 0
  fi
  if ! cntools_wallet_key_signing_type \
      "${role}" "${signing_file}" signing_form; then
    cntools_wallet_material_log ERROR \
      "Unsafe or invalid signing key retained without deriving ${verification_filename} wallet=${wallet_directory##*/}"
    return 1
  fi

  cntools_wallet_material_temp_file \
    extended_file "${wallet_directory}" "${role}-verification-key" || return 1
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" "${role}-verification-error" || {
      cntools_wallet_material_remove_temp "${extended_file}" || true
      return 1
    }
  if cntools_wallet_material_run_cli "${error_file}" -- \
      "${CNTOOLS_CLI}" key verification-key \
      --signing-key-file "${signing_file}" \
      --verification-key-file "${extended_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_material_log_cli_failure \
      "Could not derive ${verification_filename}" "${status}" "${error_file}"
    cntools_wallet_material_remove_temp "${extended_file}" || true
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true

  if [[ "${signing_form}" == "normal" ]]; then
    cntools_wallet_material_publish \
      "${extended_file}" "${verification_file}" \
      cntools_wallet_key_validate "${role}" normal
    return $?
  fi
  if ! cntools_wallet_key_validate "${extended_file}" "${role}" extended; then
    cntools_wallet_material_log ERROR \
      "Derived extended verification key is invalid: ${verification_filename}"
    cntools_wallet_material_remove_temp "${extended_file}" || true
    return 1
  fi

  cntools_wallet_material_temp_file \
    normalized_file "${wallet_directory}" "${role}-verification-key" || {
      cntools_wallet_material_remove_temp "${extended_file}" || true
      return 1
    }
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" "${role}-verification-error" || {
      cntools_wallet_material_remove_temp "${extended_file}" || true
      cntools_wallet_material_remove_temp "${normalized_file}" || true
      return 1
    }
  if cntools_wallet_material_run_cli "${error_file}" -- \
      "${CNTOOLS_CLI}" key non-extended-key \
      --extended-verification-key-file "${extended_file}" \
      --verification-key-file "${normalized_file}"; then
    status=0
  else
    status=$?
  fi
  cntools_wallet_material_remove_temp "${extended_file}" || true
  if (( status != 0 )); then
    cntools_wallet_material_log_cli_failure \
      "Could not normalize ${verification_filename}" "${status}" "${error_file}"
    cntools_wallet_material_remove_temp "${normalized_file}" || true
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true
  cntools_wallet_material_publish \
    "${normalized_file}" "${verification_file}" \
    cntools_wallet_key_validate "${role}" normal
}

cntools_wallet_key_materialize() {
  local wallet_directory="${1:-}"
  local prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"
  local failures=0

  cntools_wallet_key_materialize_role \
    "${wallet_directory}" payment \
    "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
    "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_key_materialize_role \
    "${wallet_directory}" stake \
    "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
    "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_key_materialize_role \
    "${wallet_directory}" payment \
    "${prefix}${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" \
    "${prefix}${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
    "${prefix}${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" || failures=$((failures + 1))
  cntools_wallet_key_materialize_role \
    "${wallet_directory}" stake \
    "${prefix}${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" \
    "${prefix}${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
    "${prefix}${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" || failures=$((failures + 1))
  (( failures == 0 ))
}
