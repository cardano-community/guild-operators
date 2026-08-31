#!/usr/bin/env bash
# Missing-only generation and selection of wallet payment, base, and reward
# addresses from validated public keys or native scripts.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS=()

cntools_wallet_address_network_arguments() {
  case "${CNTOOLS_NETWORK:-}" in
    mainnet) CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS=(--mainnet) ;;
    guild) CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS=(--testnet-magic 141) ;;
    preprod) CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS=(--testnet-magic 1) ;;
    preview) CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS=(--testnet-magic 2) ;;
    *) return 1 ;;
  esac
}

cntools_wallet_address_stage_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_source_file="${2:-}"
  local _cntools_kind="${3:-}"
  local _cntools_expected_hrp=""
  local _cntools_address=""
  local _cntools_nul_probe=""
  local -a _cntools_lines=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_safe_regular_file "${_cntools_source_file}" 256 || return 1
  if IFS= read -r -d '' _cntools_nul_probe < "${_cntools_source_file}"; then
    return 1
  fi
  mapfile -t _cntools_lines < "${_cntools_source_file}" || return 1
  [[ ${#_cntools_lines[@]} -eq 1 ]] || return 1
  _cntools_address="${_cntools_lines[0]}"
  _cntools_expected_hrp="$(cntools_wallet_address_hrp "${_cntools_kind}")" ||
    return 1
  cntools_wallet_bech32_valid \
    "${_cntools_address}" "${_cntools_expected_hrp}" "${_cntools_kind}" ||
      return 1
  _cntools_output_ref="${_cntools_address}"
}

cntools_wallet_address_validate() {
  local address=""

  cntools_wallet_address_stage_into address "${1:-}" "${2:-}"
}

cntools_wallet_address_source_arguments() {
  local wallet_directory="${1:-}"
  local role="${2:-}"
  local output_name="${3:-}"
  local script_file=""
  local verification_file=""
  local script_argument=""
  local verification_argument=""

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=()
  case "${role}" in
    payment)
      script_file="${wallet_directory}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}"
      verification_file="${wallet_directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
      script_argument="--payment-script-file"
      verification_argument="--payment-verification-key-file"
      ;;
    stake)
      script_file="${wallet_directory}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}"
      verification_file="${wallet_directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
      script_argument="--stake-script-file"
      verification_argument="--stake-verification-key-file"
      ;;
    *) return 2 ;;
  esac
  if cntools_wallet_material_entry_exists "${script_file}"; then
    cntools_wallet_safe_regular_file "${script_file}" 65536 || return 2
    output_ref=("${script_argument}" "${script_file}")
    return 0
  fi
  if cntools_wallet_material_entry_exists "${verification_file}"; then
    cntools_wallet_safe_regular_file "${verification_file}" 65536 || return 2
    output_ref=("${verification_argument}" "${verification_file}")
    return 0
  fi
  return 1
}

cntools_wallet_address_generate() {
  local wallet_directory="${1:-}"
  local address_kind="${2:-}"
  local target_filename="${3:-}"
  local first_source_name="${4:-}"
  local second_source_name="${5:-}"
  local target_file="${wallet_directory}/${target_filename}"
  local staged_file=""
  local error_file=""
  local status=0
  local -a arguments=(address build)

  [[ "${first_source_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n first_source_ref="${first_source_name}"
  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  if cntools_wallet_material_entry_exists "${target_file}"; then
    cntools_wallet_material_existing_valid \
      "${target_file}" cntools_wallet_address_validate "${address_kind}"
    return $?
  fi
  (( ${#first_source_ref[@]} > 0 )) || return 2
  arguments+=("${first_source_ref[@]}")
  if [[ -n "${second_source_name}" ]]; then
    [[ "${second_source_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    local -n second_source_ref="${second_source_name}"
    (( ${#second_source_ref[@]} > 0 )) || return 2
    arguments+=("${second_source_ref[@]}")
  fi
  arguments+=("${CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS[@]}")

  cntools_wallet_material_temp_file \
    staged_file "${wallet_directory}" "${address_kind}-address" || return 1
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" "${address_kind}-address-error" || {
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
      "Could not generate ${target_filename}" "${status}" "${error_file}"
    cntools_wallet_material_remove_temp "${staged_file}" || true
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true
  cntools_wallet_material_publish \
    "${staged_file}" "${target_file}" \
    cntools_wallet_address_validate "${address_kind}"
}

cntools_wallet_reward_address_generate() {
  local wallet_directory="${1:-}"
  local target_file="${wallet_directory}/${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}"
  local staged_file=""
  local error_file=""
  local status=0
  local -a stake_source=()
  local -a arguments=(latest stake-address build)

  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  if cntools_wallet_material_entry_exists "${target_file}"; then
    cntools_wallet_material_existing_valid \
      "${target_file}" cntools_wallet_address_validate reward
    return $?
  fi
  if cntools_wallet_address_source_arguments \
      "${wallet_directory}" stake stake_source; then
    :
  else
    status=$?
    (( status == 1 )) && return 0
    return 1
  fi
  arguments+=("${stake_source[@]}" "${CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS[@]}")
  cntools_wallet_material_temp_file \
    staged_file "${wallet_directory}" "reward-address" || return 1
  cntools_wallet_material_temp_file \
    error_file "${wallet_directory}" "reward-address-error" || {
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
      "Could not generate ${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" \
      "${status}" "${error_file}"
    cntools_wallet_material_remove_temp "${staged_file}" || true
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true
  cntools_wallet_material_publish \
    "${staged_file}" "${target_file}" cntools_wallet_address_validate reward
}

cntools_wallet_address_materialize() {
  local wallet_directory="${1:-}"
  local status=0
  local failures=0
  local -a payment_source=()
  local -a stake_source=()

  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  if ! cntools_wallet_address_network_arguments; then
    cntools_wallet_material_log ERROR \
      "Wallet addresses cannot be generated for network=${CNTOOLS_NETWORK:-unset}"
    return 1
  fi
  if cntools_wallet_address_source_arguments \
      "${wallet_directory}" payment payment_source; then
    cntools_wallet_address_generate \
      "${wallet_directory}" payment "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}" \
      payment_source "" || failures=$((failures + 1))
  else
    status=$?
    (( status == 1 )) || failures=$((failures + 1))
  fi
  cntools_wallet_reward_address_generate "${wallet_directory}" ||
    failures=$((failures + 1))

  payment_source=()
  stake_source=()
  if cntools_wallet_address_source_arguments \
      "${wallet_directory}" payment payment_source; then
    status=0
  else
    status=$?
  fi
  if (( status == 0 )); then
    if cntools_wallet_address_source_arguments \
        "${wallet_directory}" stake stake_source; then
      cntools_wallet_address_generate \
        "${wallet_directory}" base "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" \
        payment_source stake_source || failures=$((failures + 1))
    else
      status=$?
      (( status == 1 )) || failures=$((failures + 1))
    fi
  elif (( status != 1 )); then
    failures=$((failures + 1))
  fi
  (( failures == 0 ))
}

cntools_wallet_address_primary_into() {
  local _cntools_wallet_directory="${1:-}"
  local _cntools_address_name="${2:-}"
  local _cntools_label_name="${3:-}"
  local _cntools_note_name="${4:-}"
  local _cntools_value=""
  local _cntools_multisig="N"

  [[ "${_cntools_address_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_note_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_address_ref="${_cntools_address_name}"
  local -n _cntools_label_ref="${_cntools_label_name}"
  local -n _cntools_note_ref="${_cntools_note_name}"
  _cntools_address_ref=""
  _cntools_label_ref=""
  _cntools_note_ref=""
  cntools_wallet_directory_safe "${_cntools_wallet_directory}" || return 1
  if cntools_wallet_file_present \
       "${_cntools_wallet_directory}" "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" ||
     cntools_wallet_file_present \
       "${_cntools_wallet_directory}" "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}"; then
    _cntools_multisig="Y"
  fi

  if [[ "${_cntools_multisig}" == "Y" ]]; then
    if cntools_wallet_read_address \
        "${_cntools_wallet_directory}" base _cntools_value; then
      _cntools_address_ref="${_cntools_value}"
      _cntools_label_ref="Script base address"
      return 0
    fi
    if cntools_wallet_read_address \
        "${_cntools_wallet_directory}" payment _cntools_value; then
      _cntools_address_ref="${_cntools_value}"
      _cntools_label_ref="Script address"
      return 0
    fi
    if cntools_wallet_read_address \
        "${_cntools_wallet_directory}" reward _cntools_value; then
      _cntools_address_ref="${_cntools_value}"
      _cntools_label_ref="Script stake address"
      _cntools_note_ref="Payment script is missing."
      return 0
    fi
    return 1
  fi
  if cntools_wallet_read_address \
      "${_cntools_wallet_directory}" base _cntools_value; then
    _cntools_address_ref="${_cntools_value}"
    _cntools_label_ref="Base address"
    return 0
  fi
  if cntools_wallet_read_address \
      "${_cntools_wallet_directory}" payment _cntools_value; then
    _cntools_address_ref="${_cntools_value}"
    _cntools_label_ref="Payment address"
    return 0
  fi
  if cntools_wallet_read_address \
      "${_cntools_wallet_directory}" reward _cntools_value; then
    _cntools_address_ref="${_cntools_value}"
    _cntools_label_ref="Stake address"
    _cntools_note_ref="Payment key is missing."
    return 0
  fi
  return 1
}
