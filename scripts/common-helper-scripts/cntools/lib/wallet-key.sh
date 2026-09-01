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

# Newly generated non-extended keys have one exact 32-byte CBOR byte-string
# representation. Keep this stricter contract separate from the tolerant
# legacy-wallet readers above so existing inspection remains backwards
# compatible while new wallets cannot publish malformed key envelopes.
cntools_wallet_key_normal_envelope_valid() {
  local key_file="${1:-}"
  local role="${2:-}"
  local kind="${3:-}"
  local expected_type=""

  case "${role}:${kind}" in
    payment:signing)
      expected_type="PaymentSigningKeyShelley_ed25519"
      ;;
    payment:verification)
      expected_type="PaymentVerificationKeyShelley_ed25519"
      ;;
    stake:signing)
      expected_type="StakeSigningKeyShelley_ed25519"
      ;;
    stake:verification)
      expected_type="StakeVerificationKeyShelley_ed25519"
      ;;
    *) return 2 ;;
  esac
  cntools_wallet_safe_regular_file "${key_file}" 65536 || return 1
  jq -ers --arg expected "${expected_type}" '
    length == 1 and
    (.[0] | type == "object") and
    (.[0].type == $expected) and
    (.[0].cborHex | type == "string" and
      test("^5820[0-9a-fA-F]{64}$"))
  ' "${key_file}" >/dev/null 2>&1
}

# Mnemonic derivation produces BIP32 extended signing keys. Keep their strict
# creation-time shape separate from the tolerant legacy readers, just as for
# newly generated non-extended CLI keys above.
cntools_wallet_key_extended_envelope_valid() {
  local key_file="${1:-}"
  local role="${2:-}"
  local kind="${3:-}"
  local expected_type=""
  local expected_cbor=""

  case "${role}:${kind}" in
    payment:signing)
      expected_type="PaymentExtendedSigningKeyShelley_ed25519_bip32"
      expected_cbor='^5880[0-9a-fA-F]{256}$'
      ;;
    payment:verification)
      expected_type="PaymentExtendedVerificationKeyShelley_ed25519_bip32"
      expected_cbor='^5840[0-9a-fA-F]{128}$'
      ;;
    stake:signing)
      expected_type="StakeExtendedSigningKeyShelley_ed25519_bip32"
      expected_cbor='^5880[0-9a-fA-F]{256}$'
      ;;
    stake:verification)
      expected_type="StakeExtendedVerificationKeyShelley_ed25519_bip32"
      expected_cbor='^5840[0-9a-fA-F]{128}$'
      ;;
    *) return 2 ;;
  esac
  cntools_wallet_safe_regular_file "${key_file}" 65536 || return 1
  jq -ers --arg expected_type "${expected_type}" \
    --arg expected_cbor "${expected_cbor}" '
      length == 1 and
      (.[0] | type == "object") and
      (.[0].type == $expected_type) and
      (.[0].cborHex | type == "string" and test($expected_cbor))
    ' "${key_file}" >/dev/null 2>&1
}

# Verification keys are public, so returning a canonical comparison value does
# not expose private signing-key material to the shell or logger.
cntools_wallet_key_normal_verification_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_key_file="${2:-}"
  local _cntools_role="${3:-}"
  local _cntools_expected_type=""
  local _cntools_value=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  case "${_cntools_role}" in
    payment) _cntools_expected_type="PaymentVerificationKeyShelley_ed25519" ;;
    stake) _cntools_expected_type="StakeVerificationKeyShelley_ed25519" ;;
    *) return 2 ;;
  esac
  cntools_wallet_safe_regular_file "${_cntools_key_file}" 65536 || return 1
  _cntools_value="$(jq -ers --arg expected "${_cntools_expected_type}" '
    if length == 1 and
       (.[0] | type == "object") and
       (.[0].type == $expected) and
       (.[0].cborHex | type == "string" and
         test("^5820[0-9a-fA-F]{64}$"))
    then .[0].type + "\t" + (.[0].cborHex | ascii_downcase)
    else empty
    end
  ' "${_cntools_key_file}" 2>/dev/null)" || return 1
  [[ -n "${_cntools_value}" &&
     "${_cntools_value}" != *$'\n'* &&
     "${_cntools_value}" != *$'\r'* ]] || return 1
  _cntools_output_ref="${_cntools_value}"
}

cntools_wallet_key_normal_pair_matches() {
  local wallet_directory="${1:-}"
  local role="${2:-}"
  local signing_file="${3:-}"
  local verification_file="${4:-}"
  local derived_file=""
  local error_file=""
  local verification_value=""
  local derived_value=""
  local status=0

  case "${role}" in payment|stake) ;; *) return 2 ;; esac
  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  cntools_wallet_key_normal_envelope_valid \
    "${signing_file}" "${role}" signing || return 1
  cntools_wallet_key_normal_verification_into \
    verification_value "${verification_file}" "${role}" ||
    return 1
  cntools_wallet_material_temp_file \
    derived_file "${wallet_directory}" "${role}-pair-verification-key" ||
    return 1
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" "${role}-pair-verification-error" || {
      cntools_wallet_material_remove_temp "${derived_file}" || true
      return 1
    }
  if cntools_wallet_material_run_cli "${error_file}" -- \
      "${CNTOOLS_CLI}" key verification-key \
      --signing-key-file "${signing_file}" \
      --verification-key-file "${derived_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_material_log_cli_failure \
      "Could not verify the ${role} signing-key pair" \
      "${status}" "${error_file}"
    cntools_wallet_material_remove_temp "${derived_file}" || true
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true
  if ! cntools_wallet_key_normal_verification_into \
      derived_value "${derived_file}" "${role}"; then
    cntools_wallet_material_log ERROR \
      "Cardano CLI returned an invalid derived ${role} verification key"
    cntools_wallet_material_remove_temp "${derived_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${derived_file}" || true
  if [[ "${derived_value}" != "${verification_value}" ]]; then
    cntools_wallet_material_log ERROR \
      "Generated ${role} signing and verification keys do not match"
    return 1
  fi
  return 0
}

cntools_wallet_key_extended_pair_matches() {
  local wallet_directory="${1:-}"
  local role="${2:-}"
  local signing_file="${3:-}"
  local verification_file="${4:-}"
  local extended_file=""
  local normalized_file=""
  local error_file=""
  local verification_value=""
  local derived_value=""
  local status=0

  case "${role}" in payment|stake) ;; *) return 2 ;; esac
  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  cntools_wallet_key_extended_envelope_valid \
    "${signing_file}" "${role}" signing || return 1
  cntools_wallet_key_normal_verification_into \
    verification_value "${verification_file}" "${role}" || return 1
  cntools_wallet_material_temp_file \
    extended_file "${wallet_directory}" \
    "${role}-extended-pair-verification-key" || return 1
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" \
    "${role}-extended-pair-verification-error" || {
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
  cntools_wallet_material_remove_temp "${error_file}" || true
  if (( status != 0 )) ||
     ! cntools_wallet_key_extended_envelope_valid \
       "${extended_file}" "${role}" verification; then
    cntools_wallet_material_log ERROR \
      "Could not verify the extended ${role} signing-key pair"
    cntools_wallet_material_remove_temp "${extended_file}" || true
    return 1
  fi

  cntools_wallet_material_temp_file \
    normalized_file "${wallet_directory}" \
    "${role}-extended-pair-normalized-key" || {
      cntools_wallet_material_remove_temp "${extended_file}" || true
      return 1
    }
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" \
    "${role}-extended-pair-normalize-error" || {
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
  cntools_wallet_material_remove_temp "${error_file}" || true
  if (( status != 0 )) ||
     ! cntools_wallet_key_normal_verification_into \
       derived_value "${normalized_file}" "${role}"; then
    cntools_wallet_material_log ERROR \
      "Could not normalize the derived extended ${role} verification key"
    cntools_wallet_material_remove_temp "${normalized_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${normalized_file}" || true
  if [[ "${derived_value}" != "${verification_value}" ]]; then
    cntools_wallet_material_log ERROR \
      "Derived extended ${role} signing and verification keys do not match"
    return 1
  fi
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
