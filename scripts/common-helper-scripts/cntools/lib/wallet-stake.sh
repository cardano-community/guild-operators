#!/usr/bin/env bash
# Shared payment/stake identity preparation for key-wallet transactions.
# shellcheck disable=SC2034

cntools_stake_source_if_valid_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_source="${2:-}"
  local _cntools_expected_kind="${3:-cli}"
  local _cntools_kind=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ -e "${_cntools_source}" || -L "${_cntools_source}" ]] || return 0
  if cntools_transaction_source_kind_into _cntools_kind "${_cntools_source}" &&
     [[ "${_cntools_kind}" == "${_cntools_expected_kind}" ]]; then
    _cntools_output_ref="${_cntools_source}"
    return 0
  fi
  cntools_transaction_log WARN \
    "Signing source is unavailable or unsafe; an unsigned package can still be created file=${_cntools_source##*/}"
}

cntools_stake_prepare_wallet() {
  local wallet_directory="${1:-}"
  local wallet_name="${2:-${wallet_directory##*/}}"
  local wallet_type=""
  local expected_kind="cli"

  cntools_transaction_clear_error
  cntools_wallet_directory_safe "${wallet_directory}" || {
    cntools_transaction_set_error \
      "The selected wallet directory is no longer safe or accessible."
    return 1
  }
  cntools_wallet_prepare_selected_material "${wallet_directory}" || {
    cntools_transaction_set_error \
      "The wallet's public keys and addresses could not be prepared safely."
    return 1
  }
  wallet_type="$(cntools_wallet_type "${wallet_directory}")" || return 1
  case "${wallet_type}" in
    CLI|Mnemonic|Hardware) ;;
    MultiSig)
      cntools_transaction_set_error \
        "Native-script stake operations will be added with the multisig wallet flow. Select a CLI, mnemonic, or hardware wallet for now."
      return 1
      ;;
    *)
      cntools_transaction_set_error \
        "This stake operation requires a complete payment-and-stake wallet."
      return 1
      ;;
  esac
  if ! cntools_wallet_read_address \
       "${wallet_directory}" base CNTOOLS_STAKE_BASE_ADDRESS ||
     ! cntools_wallet_read_address \
       "${wallet_directory}" payment CNTOOLS_STAKE_PAYMENT_ADDRESS ||
     ! cntools_wallet_read_address \
       "${wallet_directory}" reward CNTOOLS_STAKE_REWARD_ADDRESS; then
    cntools_transaction_set_error \
      "The wallet does not have a valid base, payment, and stake address."
    return 1
  fi
  CNTOOLS_STAKE_PAYMENT_VKEY="${wallet_directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
  CNTOOLS_STAKE_STAKE_VKEY="${wallet_directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
  if ! cntools_wallet_key_validate \
       "${CNTOOLS_STAKE_PAYMENT_VKEY}" payment any ||
     ! cntools_wallet_key_validate \
       "${CNTOOLS_STAKE_STAKE_VKEY}" stake any ||
     ! cntools_wallet_id_read_credential \
       "${wallet_directory}" payment CNTOOLS_STAKE_PAYMENT_CREDENTIAL ||
     ! cntools_wallet_id_read_credential \
       "${wallet_directory}" stake CNTOOLS_STAKE_STAKE_CREDENTIAL; then
    cntools_transaction_set_error \
      "The wallet's public signing identity is incomplete or invalid."
    return 1
  fi

  CNTOOLS_STAKE_PAYMENT_SOURCE=""
  CNTOOLS_STAKE_STAKE_SOURCE=""
  if [[ "${wallet_type}" == "Hardware" ]]; then
    expected_kind="hardware"
    cntools_stake_source_if_valid_into \
      CNTOOLS_STAKE_PAYMENT_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" \
      "${expected_kind}"
    cntools_stake_source_if_valid_into \
      CNTOOLS_STAKE_STAKE_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" \
      "${expected_kind}"
    if [[ -z "${CNTOOLS_STAKE_PAYMENT_SOURCE}" ||
          -z "${CNTOOLS_STAKE_STAKE_SOURCE}" ]]; then
      cntools_transaction_set_error \
        "A hardware wallet needs valid payment and stake HWS files to build a hardware-compatible transaction."
      return 1
    fi
  else
    cntools_stake_source_if_valid_into \
      CNTOOLS_STAKE_PAYMENT_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" cli
    cntools_stake_source_if_valid_into \
      CNTOOLS_STAKE_STAKE_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" cli
  fi
  CNTOOLS_STAKE_CAN_SIGN="N"
  if [[ -n "${CNTOOLS_STAKE_PAYMENT_SOURCE}" &&
        -n "${CNTOOLS_STAKE_STAKE_SOURCE}" ]]; then
    CNTOOLS_STAKE_CAN_SIGN="Y"
  fi
  CNTOOLS_STAKE_WALLET="${wallet_name}"
  CNTOOLS_STAKE_WALLET_TYPE="${wallet_type}"
  CNTOOLS_STAKE_DIRECTORY="${wallet_directory}"
  cntools_stake_verify_addresses || return 1
  cntools_transaction_log WALLET \
    "stake wallet prepared wallet=${wallet_name} type=${wallet_type} signing=${CNTOOLS_STAKE_CAN_SIGN}"
}

cntools_stake_verify_addresses() {
  local role="" output="" errors="" expected="" actual="" status=0
  local -a network=() command=()
  cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_temp_file output stake-address-check || return 1
  cntools_transaction_temp_file errors stake-address-errors || return 1
  for role in payment base reward; do
    case "${role}" in
      payment)
        expected="${CNTOOLS_STAKE_PAYMENT_ADDRESS}"
        command=("${CNTOOLS_CLI}" address build --payment-verification-key-file "${CNTOOLS_STAKE_PAYMENT_VKEY}") ;;
      base)
        expected="${CNTOOLS_STAKE_BASE_ADDRESS}"
        command=("${CNTOOLS_CLI}" address build --payment-verification-key-file "${CNTOOLS_STAKE_PAYMENT_VKEY}" --stake-verification-key-file "${CNTOOLS_STAKE_STAKE_VKEY}") ;;
      reward)
        expected="${CNTOOLS_STAKE_REWARD_ADDRESS}"
        command=("${CNTOOLS_CLI}" latest stake-address build --stake-verification-key-file "${CNTOOLS_STAKE_STAKE_VKEY}") ;;
    esac
    status=0
    cntools_transaction_run_cli "${output}" "${errors}" -- "${command[@]}" "${network[@]}" || status=$?
    if (( status != 0 )); then
      cntools_transaction_log_cli_failure 'Could not verify wallet stake/payment addresses' "${status}" "${errors}" "${output}"
      return 1
    fi
    actual="$(< "${output}")"
    [[ "${actual}" == "${expected}" ]] || {
      cntools_transaction_set_error "The cached ${role} address does not match this wallet's public keys and network. Review its public artifacts."
      return 1
    }
  done
}
