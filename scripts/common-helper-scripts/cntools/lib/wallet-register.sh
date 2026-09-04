#!/usr/bin/env bash
# Stake-address registration and de-registration construction. Functions only.
# Loaded after the wallet, query, and shared transaction libraries.
# shellcheck disable=SC2034

CNTOOLS_WALLET_REGISTER_MAX_INPUTS=1000
CNTOOLS_WALLET_REGISTER_ERROR=""
CNTOOLS_WALLET_REGISTER_BACKEND=""
CNTOOLS_WALLET_REGISTER_SOURCE=""
CNTOOLS_WALLET_REGISTER_WALLET=""
CNTOOLS_WALLET_REGISTER_WALLET_TYPE=""
CNTOOLS_WALLET_REGISTER_DIRECTORY=""
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=""
CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=""
CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS=""
CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY=""
CNTOOLS_WALLET_REGISTER_STAKE_VKEY=""
CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=""
CNTOOLS_WALLET_REGISTER_STAKE_SOURCE=""
CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL=""
CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL=""
CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE=""
CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE=""
CNTOOLS_WALLET_REGISTER_DEPOSIT=""
CNTOOLS_WALLET_REGISTER_LOVELACE="0"
CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE="0"
CNTOOLS_WALLET_REGISTER_AVAILABLE_INPUT_COUNT=0
CNTOOLS_WALLET_REGISTER_TOTAL_VALUE=""
CNTOOLS_WALLET_REGISTER_ASSET_COUNT=0
CNTOOLS_WALLET_REGISTER_FEE_RESERVE="0"
CNTOOLS_WALLET_REGISTER_SELECTION_REASON=""
CNTOOLS_WALLET_REGISTER_POLICY_JSON="{}"
CNTOOLS_WALLET_REGISTER_CAN_SIGN="N"
CNTOOLS_WALLET_REGISTER_OPERATION="register"
CNTOOLS_WALLET_REGISTER_TITLE="Register"
CNTOOLS_WALLET_REGISTER_PATH="/ Wallet / Register"
CNTOOLS_WALLET_REGISTER_NOUN="registration"
CNTOOLS_WALLET_REGISTER_VERB="register"
CNTOOLS_WALLET_REGISTER_PAST="registered"
CNTOOLS_WALLET_REGISTER_CERTIFICATE_COMMAND="registration-certificate"
CNTOOLS_WALLET_REGISTER_INTENT="Wallet stake registration"
CNTOOLS_WALLET_REGISTER_SUMMARY_ACTION="stake-address-registration"
CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT="charged"
CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL="Stake deposit"
CNTOOLS_WALLET_REGISTER_FILE_SUFFIX="stake-registration"
declare -ag CNTOOLS_WALLET_REGISTER_INPUTS=()
declare -ag CNTOOLS_WALLET_REGISTER_ASSET_IDS=()
declare -Ag CNTOOLS_WALLET_REGISTER_ASSETS=()

cntools_wallet_register_operation_set() {
  case "${1:-}" in
    register)
      CNTOOLS_WALLET_REGISTER_OPERATION="register"
      CNTOOLS_WALLET_REGISTER_TITLE="Register"
      CNTOOLS_WALLET_REGISTER_PATH="/ Wallet / Register"
      CNTOOLS_WALLET_REGISTER_NOUN="registration"
      CNTOOLS_WALLET_REGISTER_VERB="register"
      CNTOOLS_WALLET_REGISTER_PAST="registered"
      CNTOOLS_WALLET_REGISTER_CERTIFICATE_COMMAND="registration-certificate"
      CNTOOLS_WALLET_REGISTER_INTENT="Wallet stake registration"
      CNTOOLS_WALLET_REGISTER_SUMMARY_ACTION="stake-address-registration"
      CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT="charged"
      CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL="Stake deposit"
      CNTOOLS_WALLET_REGISTER_FILE_SUFFIX="stake-registration"
      ;;
    deregister)
      CNTOOLS_WALLET_REGISTER_OPERATION="deregister"
      CNTOOLS_WALLET_REGISTER_TITLE="De-Register"
      CNTOOLS_WALLET_REGISTER_PATH="/ Wallet / De-Register"
      CNTOOLS_WALLET_REGISTER_NOUN="de-registration"
      CNTOOLS_WALLET_REGISTER_VERB="de-register"
      CNTOOLS_WALLET_REGISTER_PAST="de-registered"
      CNTOOLS_WALLET_REGISTER_CERTIFICATE_COMMAND="deregistration-certificate"
      CNTOOLS_WALLET_REGISTER_INTENT="Wallet stake de-registration"
      CNTOOLS_WALLET_REGISTER_SUMMARY_ACTION="stake-address-deregistration"
      CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT="refunded"
      CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL="Stake deposit refund"
      CNTOOLS_WALLET_REGISTER_FILE_SUFFIX="stake-deregistration"
      ;;
    *) return 2 ;;
  esac
}

cntools_wallet_register_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_register_set_error() {
  CNTOOLS_WALLET_REGISTER_ERROR="${1:-Wallet stake operation failed.}"
  cntools_wallet_register_log ERROR "${CNTOOLS_WALLET_REGISTER_ERROR}"
}

cntools_wallet_register_reset_chain_state() {
  CNTOOLS_WALLET_REGISTER_ERROR=""
  CNTOOLS_WALLET_REGISTER_BACKEND=""
  CNTOOLS_WALLET_REGISTER_SOURCE=""
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE=""
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE=""
  CNTOOLS_WALLET_REGISTER_DEPOSIT=""
  CNTOOLS_WALLET_REGISTER_LOVELACE="0"
  CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE="0"
  CNTOOLS_WALLET_REGISTER_AVAILABLE_INPUT_COUNT=0
  CNTOOLS_WALLET_REGISTER_TOTAL_VALUE=""
  CNTOOLS_WALLET_REGISTER_ASSET_COUNT=0
  CNTOOLS_WALLET_REGISTER_FEE_RESERVE="0"
  CNTOOLS_WALLET_REGISTER_SELECTION_REASON=""
  CNTOOLS_WALLET_REGISTER_POLICY_JSON="{}"
  CNTOOLS_WALLET_REGISTER_INPUTS=()
  CNTOOLS_WALLET_REGISTER_ASSET_IDS=()
  CNTOOLS_WALLET_REGISTER_ASSETS=()
  cntools_utxo_reset
  cntools_coin_reset
  cntools_change_reset
  cntools_wallet_query_reset
}

cntools_wallet_register_uint_normalize_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_value}" =~ ^[0-9]+$ &&
     ${#_cntools_value} -le 80 ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  while [[ ${#_cntools_value} -gt 1 && "${_cntools_value:0:1}" == "0" ]]; do
    _cntools_value="${_cntools_value:1}"
  done
  _cntools_output_ref="${_cntools_value}"
}

cntools_wallet_register_uint_greater() {
  local LC_ALL=C
  local left=""
  local right=""

  cntools_wallet_register_uint_normalize_into left "${1:-}" || return 2
  cntools_wallet_register_uint_normalize_into right "${2:-}" || return 2
  (( ${#left} > ${#right} )) ||
    { (( ${#left} == ${#right} )) && [[ "${left}" > "${right}" ]]; }
}

cntools_wallet_register_asset_add() {
  local asset_id="${1:-}"
  local quantity="${2:-}"
  local current=""
  local total=""

  asset_id="${asset_id,,}"
  [[ "${asset_id}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ &&
     "${quantity}" =~ ^[0-9]+$ && ${#quantity} -le 80 ]] || return 2
  cntools_wallet_register_uint_normalize_into quantity "${quantity}" || return 1
  if [[ -z "${CNTOOLS_WALLET_REGISTER_ASSETS[${asset_id}]+x}" ]]; then
    CNTOOLS_WALLET_REGISTER_ASSET_IDS+=("${asset_id}")
    CNTOOLS_WALLET_REGISTER_ASSETS["${asset_id}"]="${quantity}"
  else
    current="${CNTOOLS_WALLET_REGISTER_ASSETS[${asset_id}]}"
    cntools_wallet_uint_add_into total "${current}" "${quantity}" || return 1
    CNTOOLS_WALLET_REGISTER_ASSETS["${asset_id}"]="${total}"
  fi
}

cntools_wallet_register_sort_assets() {
  local sorted=""
  local -a asset_ids=()

  (( ${#CNTOOLS_WALLET_REGISTER_ASSET_IDS[@]} > 1 )) || return 0
  sorted="$(
    printf '%s\n' "${CNTOOLS_WALLET_REGISTER_ASSET_IDS[@]}" | LC_ALL=C sort
  )" || return 1
  mapfile -t asset_ids <<< "${sorted}"
  (( ${#asset_ids[@]} == ${#CNTOOLS_WALLET_REGISTER_ASSET_IDS[@]} )) ||
    return 1
  CNTOOLS_WALLET_REGISTER_ASSET_IDS=("${asset_ids[@]}")
}

cntools_wallet_register_total_value_build() {
  local asset_id=""
  local cli_asset_id=""
  local value="${CNTOOLS_WALLET_REGISTER_LOVELACE}"

  [[ "${CNTOOLS_WALLET_REGISTER_LOVELACE}" =~ ^[0-9]+$ ]] || return 1
  cntools_wallet_register_sort_assets || return 1
  for asset_id in "${CNTOOLS_WALLET_REGISTER_ASSET_IDS[@]}"; do
    cli_asset_id="${asset_id}"
    [[ "${cli_asset_id}" != *. ]] || cli_asset_id="${cli_asset_id%.}"
    value+=" + ${CNTOOLS_WALLET_REGISTER_ASSETS[${asset_id}]} ${cli_asset_id}"
  done
  CNTOOLS_WALLET_REGISTER_ASSET_COUNT="${#CNTOOLS_WALLET_REGISTER_ASSET_IDS[@]}"
  CNTOOLS_WALLET_REGISTER_TOTAL_VALUE="${value}"
}

cntools_wallet_register_inventory_use_indices() {
  local index=""

  CNTOOLS_WALLET_REGISTER_LOVELACE="0"
  CNTOOLS_WALLET_REGISTER_INPUTS=()
  CNTOOLS_WALLET_REGISTER_ASSET_IDS=()
  CNTOOLS_WALLET_REGISTER_ASSETS=()
  for index in "$@"; do
    [[ "${index}" =~ ^[0-9]+$ &&
       -n "${CNTOOLS_UTXO_REFS[index]+x}" ]] || return 2
    CNTOOLS_WALLET_REGISTER_INPUTS+=("${CNTOOLS_UTXO_REFS[index]}")
    cntools_utxo_value_add_index "${index}" \
      CNTOOLS_WALLET_REGISTER_LOVELACE \
      CNTOOLS_WALLET_REGISTER_ASSET_IDS \
      CNTOOLS_WALLET_REGISTER_ASSETS || return 1
  done
  cntools_wallet_register_total_value_build
}

cntools_wallet_register_inventory_use_all() {
  local -a indices=()

  indices=("${!CNTOOLS_UTXO_REFS[@]}")
  cntools_wallet_register_inventory_use_indices "${indices[@]}" || return 1
  CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE="${CNTOOLS_WALLET_REGISTER_LOVELACE}"
  CNTOOLS_WALLET_REGISTER_AVAILABLE_INPUT_COUNT="${#CNTOOLS_UTXO_REFS[@]}"
}

cntools_wallet_register_source_if_valid_into() {
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
  cntools_wallet_register_log WARN \
    "Signing source is unavailable or unsafe; an unsigned package can still be created file=${_cntools_source##*/}"
}

cntools_wallet_register_prepare_wallet() {
  local wallet_directory="${1:-}"
  local wallet_name="${2:-${wallet_directory##*/}}"
  local wallet_type=""
  local expected_kind="cli"

  CNTOOLS_WALLET_REGISTER_ERROR=""
  cntools_wallet_directory_safe "${wallet_directory}" || {
    cntools_wallet_register_set_error \
      "The selected wallet directory is no longer safe or accessible."
    return 1
  }
  cntools_wallet_prepare_selected_material "${wallet_directory}" || {
    cntools_wallet_register_set_error \
      "The wallet's public keys and addresses could not be prepared safely."
    return 1
  }
  wallet_type="$(cntools_wallet_type "${wallet_directory}")" || return 1
  case "${wallet_type}" in
    CLI|Mnemonic|Hardware) ;;
    MultiSig)
      cntools_wallet_register_set_error \
        "Native-script stake operations will be added with the multisig wallet flow. Select a CLI, mnemonic, or hardware wallet for now."
      return 1
      ;;
    *)
      cntools_wallet_register_set_error \
        "This stake operation requires a complete payment-and-stake wallet."
      return 1
      ;;
  esac
  if ! cntools_wallet_read_address \
       "${wallet_directory}" base CNTOOLS_WALLET_REGISTER_BASE_ADDRESS ||
     ! cntools_wallet_read_address \
       "${wallet_directory}" payment CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS ||
     ! cntools_wallet_read_address \
       "${wallet_directory}" reward CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS; then
    cntools_wallet_register_set_error \
      "The wallet does not have a valid base, payment, and stake address."
    return 1
  fi
  CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY="${wallet_directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
  CNTOOLS_WALLET_REGISTER_STAKE_VKEY="${wallet_directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
  if ! cntools_wallet_key_validate \
       "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" payment any ||
     ! cntools_wallet_key_validate \
       "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" stake any ||
     ! cntools_wallet_id_read_credential \
       "${wallet_directory}" payment CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL ||
     ! cntools_wallet_id_read_credential \
       "${wallet_directory}" stake CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL; then
    cntools_wallet_register_set_error \
      "The wallet's public signing identity is incomplete or invalid."
    return 1
  fi

  CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=""
  CNTOOLS_WALLET_REGISTER_STAKE_SOURCE=""
  if [[ "${wallet_type}" == "Hardware" ]]; then
    expected_kind="hardware"
    cntools_wallet_register_source_if_valid_into \
      CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" \
      "${expected_kind}"
    cntools_wallet_register_source_if_valid_into \
      CNTOOLS_WALLET_REGISTER_STAKE_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" \
      "${expected_kind}"
    if [[ -z "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" ||
          -z "${CNTOOLS_WALLET_REGISTER_STAKE_SOURCE}" ]]; then
      cntools_wallet_register_set_error \
        "A hardware wallet needs valid payment and stake HWS files to build a hardware-compatible transaction."
      return 1
    fi
  else
    cntools_wallet_register_source_if_valid_into \
      CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" cli
    cntools_wallet_register_source_if_valid_into \
      CNTOOLS_WALLET_REGISTER_STAKE_SOURCE \
      "${wallet_directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" cli
  fi
  CNTOOLS_WALLET_REGISTER_CAN_SIGN="N"
  if [[ -n "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" &&
        -n "${CNTOOLS_WALLET_REGISTER_STAKE_SOURCE}" ]]; then
    CNTOOLS_WALLET_REGISTER_CAN_SIGN="Y"
  fi
  CNTOOLS_WALLET_REGISTER_WALLET="${wallet_name}"
  CNTOOLS_WALLET_REGISTER_WALLET_TYPE="${wallet_type}"
  CNTOOLS_WALLET_REGISTER_DIRECTORY="${wallet_directory}"
  cntools_wallet_register_log WALLET \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} wallet prepared wallet=${wallet_name} type=${wallet_type} signing=${CNTOOLS_WALLET_REGISTER_CAN_SIGN}"
}

cntools_wallet_register_protocol_validate() {
  local protocol_file="${1:-}"

  if ! cntools_transaction_file_safe "${protocol_file}" 4194304 ||
     ! jq -e 'type == "object"' "${protocol_file}" >/dev/null 2>&1 ||
     ! cntools_wallet_query_json_uint_field \
       CNTOOLS_WALLET_REGISTER_DEPOSIT "${protocol_file}" \
       stakeAddressDeposit; then
    cntools_wallet_register_set_error \
      "The protocol parameters are invalid or do not contain an exact stake-address deposit."
    return 1
  fi
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${protocol_file}"
}

cntools_wallet_register_protocol_local() {
  local protocol_file=""
  local error_file=""
  local status=0
  local -a network_arguments=()

  cntools_transaction_network_arguments_into \
    network_arguments "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_temp_file protocol_file register-protocol || return 1
  cntools_transaction_temp_file error_file register-protocol-error || return 1
  if cntools_transaction_run_cli "${protocol_file}" "${error_file}" -- \
      "${CNTOOLS_CLI}" latest query protocol-parameters \
      "${network_arguments[@]}" \
      --socket-path "${CNTOOLS_SOCKET}" --output-json; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Local protocol-parameter query failed" "${status}" \
      "${error_file}" "${protocol_file}"
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  fi
  cntools_wallet_register_protocol_validate "${protocol_file}"
}

cntools_wallet_register_http_get() {
  local endpoint="${1:-}"
  local output_file="${2:-}"
  local auth_header_file=""
  local status=0
  local -a arguments=(
    --connect-timeout 3
    --max-filesize 4194304
    --header "accept: application/json"
  )

  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    cntools_http_secret_file_create auth_header_file || return 1
    arguments+=(--header "@${auth_header_file}")
  fi
  if cntools_api_request GET "${endpoint}" "${output_file}" \
      "${arguments[@]}"; then
    status=0
  else
    status=$?
  fi
  [[ -z "${auth_header_file}" ]] ||
    cntools_http_secret_file_remove "${auth_header_file}" || true
  return "${status}"
}

cntools_wallet_register_protocol_koios() {
  local protocol_file=""

  cntools_transaction_temp_file protocol_file register-protocol || return 1
  if ! cntools_wallet_register_http_get \
      "${CNTOOLS_KOIOS_API%/}/cli_protocol_params" "${protocol_file}"; then
    cntools_wallet_register_set_error \
      "Koios could not return current protocol parameters."
    return 1
  fi
  cntools_wallet_register_protocol_validate "${protocol_file}"
}

cntools_wallet_register_parse_local_utxos() {
  local response_file="${1:-}"

  if ! cntools_utxo_load_local "${response_file}" \
      "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
      "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}"; then
    cntools_wallet_register_set_error \
      "${CNTOOLS_UTXO_ERROR:-The local node returned an invalid UTxO value.}"
    return 1
  fi
  (( ${#CNTOOLS_UTXO_REFS[@]} <= CNTOOLS_WALLET_REGISTER_MAX_INPUTS )) || {
    cntools_wallet_register_set_error \
      "The wallet contains more UTxOs than this transaction flow can inspect safely."
    return 1
  }
  cntools_wallet_register_inventory_use_all
}

cntools_wallet_register_utxos_local() {
  local response_file=""
  local error_file=""
  local status=0
  local -a network_arguments=()
  local -a command=()

  cntools_transaction_network_arguments_into \
    network_arguments "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_temp_file response_file register-utxos || return 1
  cntools_transaction_temp_file error_file register-utxos-error || return 1
  command=("${CNTOOLS_CLI}" latest query utxo
    --address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}")
  if [[ "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" != \
        "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" ]]; then
    command+=(--address "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}")
  fi
  command+=("${network_arguments[@]}" --socket-path "${CNTOOLS_SOCKET}"
    --output-json)
  if cntools_transaction_run_cli \
      "${response_file}" "${error_file}" -- "${command[@]}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Local wallet UTxO query failed" "${status}" \
      "${error_file}" "${response_file}"
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  fi
  cntools_wallet_register_parse_local_utxos "${response_file}"
}

cntools_wallet_register_parse_koios_utxos() {
  local response_file="${1:-}"

  if ! cntools_utxo_load_koios "${response_file}" \
      "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
      "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}"; then
    cntools_wallet_register_set_error \
      "${CNTOOLS_UTXO_ERROR:-Koios returned an invalid UTxO value.}"
    return 1
  fi
  (( ${#CNTOOLS_UTXO_REFS[@]} <= CNTOOLS_WALLET_REGISTER_MAX_INPUTS )) || {
    cntools_wallet_register_set_error \
      "The wallet contains more UTxOs than this transaction flow can inspect safely."
    return 1
  }
  cntools_wallet_register_inventory_use_all
}

cntools_wallet_register_utxos_koios() {
  local response_file=""
  local payload=""

  cntools_transaction_temp_file response_file register-utxos || return 1
  payload="$(jq -cn \
    --arg base "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
    --arg payment "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" '
      # Koios deliberately omits asset_list when _extended is false. The
      # transaction balancer must receive the complete input value or native
      # assets could not be returned safely as change.
      {_addresses: ([$base, $payment] | unique), _extended: true}
    ')" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/address_utxos?select=tx_hash%2Ctx_index%2Caddress%2Cvalue%3A%3Atext%2Casset_list%2Cdatum_hash%2Cinline_datum%2Creference_script" \
      "${payload}" "${response_file}"; then
    cntools_wallet_register_set_error \
      "Koios could not return the wallet's UTxOs."
    return 1
  fi
  cntools_wallet_register_parse_koios_utxos "${response_file}"
}

cntools_wallet_register_chain_state_validate() {
  local rewards=""

  case "${CNTOOLS_WALLET_REGISTER_OPERATION}" in
    register)
      [[ "${CNTOOLS_WALLET_REGISTERED}" != "yes" ]] || return 4
      ;;
    deregister)
      [[ "${CNTOOLS_WALLET_REGISTERED}" == "yes" ]] || return 7
      cntools_wallet_register_uint_normalize_into \
        rewards "${CNTOOLS_WALLET_REWARD_LOVELACE:-}" || {
          cntools_wallet_register_set_error \
            "The reward balance returned by the chain-data backend is invalid."
          return 1
      }
      [[ "${rewards}" == "0" ]] || return 8
      cntools_wallet_register_uint_normalize_into \
        CNTOOLS_WALLET_STAKE_DEPOSIT \
        "${CNTOOLS_WALLET_STAKE_DEPOSIT:-}" || {
          cntools_wallet_register_set_error \
            "The registered stake deposit could not be determined exactly."
          return 1
        }
      ;;
    *)
      cntools_wallet_register_set_error \
        "The requested stake operation is not supported."
      return 1
      ;;
  esac
}

cntools_wallet_register_funding_validate() {
  (( ${#CNTOOLS_WALLET_REGISTER_INPUTS[@]} > 0 )) || return 5
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == "register" ]]; then
    cntools_wallet_register_uint_greater \
      "${CNTOOLS_WALLET_REGISTER_LOVELACE}" \
      "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" || return 6
  fi
}

cntools_wallet_register_select_inputs() {
  local required=""
  local expanded=""
  local status=0
  local attempt=0
  local selected_refs=""

  cntools_coin_fee_reserve_into CNTOOLS_WALLET_REGISTER_FEE_RESERVE \
    "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}" || {
      cntools_wallet_register_set_error \
        "The protocol parameters could not provide a safe transaction-fee reserve."
      return 1
    }
  cntools_coin_required_for_stake_into required \
    "${CNTOOLS_WALLET_REGISTER_OPERATION}" \
    "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" \
    "${CNTOOLS_WALLET_REGISTER_FEE_RESERVE}" || return 1

  for (( attempt = 1; attempt <= 4; attempt++ )); do
    if ! cntools_coin_select_lovelace \
        "${required}" "${CNTOOLS_TX_SELECTION_STRATEGY}"; then
      cntools_wallet_register_set_error \
        "${CNTOOLS_COIN_ERROR:-Coin selection could not fund this transaction.}"
      return 9
    fi
    if cntools_change_plan_stake \
        "${CNTOOLS_WALLET_REGISTER_OPERATION}" \
        "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" \
        "${CNTOOLS_WALLET_REGISTER_FEE_RESERVE}" \
        "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}" \
        "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}"; then
      status=0
    else
      status=$?
    fi
    if (( status == 0 )); then
      break
    elif (( status != 3 )); then
      cntools_wallet_register_set_error \
        "${CNTOOLS_CHANGE_ERROR:-Transaction change could not be planned safely.}"
      return 1
    fi
    cntools_uint_add_into expanded \
      "${CNTOOLS_COIN_SELECTED_LOVELACE}" \
      "${CNTOOLS_CHANGE_REQUIRED_EXTRA}" || return 1
    [[ "${expanded}" != "${required}" ]] || break
    required="${expanded}"
  done
  if (( status != 0 )); then
    cntools_wallet_register_set_error \
      "${CNTOOLS_CHANGE_ERROR:-The wallet does not contain enough ADA for valid change outputs.}"
    return 9
  fi

  CNTOOLS_WALLET_REGISTER_SELECTION_REASON="${CNTOOLS_COIN_SELECTION_REASON}"
  cntools_wallet_register_inventory_use_indices \
    "${CNTOOLS_COIN_SELECTED_INDICES[@]}" || return 1
  CNTOOLS_WALLET_REGISTER_POLICY_JSON="$(cntools_change_policy_json)" ||
    return 1
  selected_refs="$(IFS=,; printf '%s' "${CNTOOLS_WALLET_REGISTER_INPUTS[*]}")"
  cntools_wallet_register_log TRANSACTION \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} policy selection=${CNTOOLS_TX_SELECTION_STRATEGY} token_fragmentation=${CNTOOLS_TX_TOKEN_FRAGMENTATION} max_assets=${CNTOOLS_TX_TOKEN_MAX_ASSETS} utxo_management=${CNTOOLS_TX_UTXO_MANAGEMENT} target=${CNTOOLS_TX_UTXO_TARGET_COUNT} percentages=${CNTOOLS_TX_UTXO_PERCENTAGES} collateral=${CNTOOLS_TX_COLLATERAL_MANAGEMENT}"
  cntools_wallet_register_log TRANSACTION \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} selection inputs=${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}/${CNTOOLS_WALLET_REGISTER_AVAILABLE_INPUT_COUNT} lovelace=${CNTOOLS_WALLET_REGISTER_LOVELACE}/${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE} assets=${CNTOOLS_WALLET_REGISTER_ASSET_COUNT} refs=${selected_refs}"
  cntools_wallet_register_log TRANSACTION \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} change outputs=${#CNTOOLS_CHANGE_OUTPUTS[@]} token_result=${CNTOOLS_CHANGE_TOKEN_STATUS} utxo_result=${CNTOOLS_CHANGE_UTXO_STATUS} collateral_result=${CNTOOLS_CHANGE_COLLATERAL_STATUS}"
}

cntools_wallet_register_collect_local() {
  cntools_wallet_query_network_arguments || return 1
  if ! cntools_wallet_query_local_stake \
      "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}"; then
    [[ -n "${CNTOOLS_WALLET_REGISTER_ERROR}" ]] ||
      cntools_wallet_register_set_error \
        "The local node could not return the stake credential state."
    return 1
  fi
  cntools_wallet_register_chain_state_validate || return $?
  cntools_wallet_register_protocol_local || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == "deregister" ]]; then
    CNTOOLS_WALLET_REGISTER_DEPOSIT="${CNTOOLS_WALLET_STAKE_DEPOSIT}"
  fi
  cntools_wallet_register_utxos_local || return 1
  cntools_wallet_register_funding_validate || return $?
  cntools_wallet_register_select_inputs || return $?
  CNTOOLS_WALLET_REGISTER_BACKEND="local"
  CNTOOLS_WALLET_REGISTER_SOURCE="Local node · ${CNTOOLS_IMPLEMENTATION_NAME:-${CNTOOLS_BACKEND:-node}}"
}

cntools_wallet_register_collect_koios() {
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" != "Y" ||
        ! "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]]; then
    cntools_wallet_register_set_error \
      "Koios is not configured with a valid HTTPS endpoint."
    return 1
  fi
  if ! cntools_wallet_query_koios_stake \
      "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}"; then
    [[ -n "${CNTOOLS_WALLET_REGISTER_ERROR}" ]] ||
      cntools_wallet_register_set_error \
        "Koios could not return the stake credential state."
    return 1
  fi
  cntools_wallet_register_chain_state_validate || return $?
  cntools_wallet_register_protocol_koios || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == "deregister" ]]; then
    CNTOOLS_WALLET_REGISTER_DEPOSIT="${CNTOOLS_WALLET_STAKE_DEPOSIT}"
  fi
  cntools_wallet_register_utxos_koios || return 1
  cntools_wallet_register_funding_validate || return $?
  cntools_wallet_register_select_inputs || return $?
  CNTOOLS_WALLET_REGISTER_BACKEND="koios"
  CNTOOLS_WALLET_REGISTER_SOURCE="Koios API · ${CNTOOLS_KOIOS_API}"
}

cntools_wallet_register_collect() {
  local status=1

  cntools_wallet_register_reset_chain_state
  if cntools_transaction_local_backend_ready; then
    if cntools_wallet_register_collect_local; then
      return 0
    else
      status=$?
    fi
    case "${status}" in
      4|5|6|7|8|9) return "${status}" ;;
    esac
    if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == "Y" ]]; then
      cntools_wallet_register_log WARN \
        "Local stake ${CNTOOLS_WALLET_REGISTER_NOUN} data failed; retrying from Koios"
      cntools_wallet_register_reset_chain_state
      if cntools_wallet_register_collect_koios; then
        return 0
      else
        return $?
      fi
    fi
    return "${status}"
  fi
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == "Y" ]]; then
    cntools_wallet_register_collect_koios
    return $?
  fi
  cntools_wallet_register_set_error \
    "No chain-data backend is available. Start the local node or enable Koios."
  return 1
}

cntools_wallet_register_certificate_create() {
  local certificate_file=""
  local output_file=""
  local error_file=""
  local status=0

  case "${CNTOOLS_WALLET_REGISTER_CERTIFICATE_COMMAND}" in
    registration-certificate|deregistration-certificate) ;;
    *)
      cntools_wallet_register_set_error \
        "The stake certificate operation is invalid."
      return 1
      ;;
  esac

  cntools_transaction_temp_file certificate_file register-certificate ||
    return 1
  cntools_transaction_temp_file output_file register-certificate-output ||
    return 1
  cntools_transaction_temp_file error_file register-certificate-error ||
    return 1
  if cntools_transaction_run_cli "${output_file}" "${error_file}" -- \
      "${CNTOOLS_CLI}" latest stake-address \
      "${CNTOOLS_WALLET_REGISTER_CERTIFICATE_COMMAND}" \
      --stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" \
      --key-reg-deposit-amt "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" \
      --out-file "${certificate_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Stake ${CNTOOLS_WALLET_REGISTER_NOUN} certificate creation failed" \
      "${status}" \
      "${error_file}" "${output_file}"
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  fi
  jq -e '
    type == "object" and
    (.type | type == "string" and length > 0 and length <= 120) and
    (.description | type == "string" and length <= 240) and
    (.cborHex | type == "string" and length > 0 and length <= 131072 and
      test("^([0-9a-fA-F]{2})+$"))
  ' "${certificate_file}" >/dev/null 2>&1 || {
    cntools_wallet_register_set_error \
      "Cardano CLI produced an invalid stake ${CNTOOLS_WALLET_REGISTER_NOUN} certificate."
    return 1
  }
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE="${certificate_file}"
}

cntools_wallet_register_plan_create() {
  local payment_group=""
  local stake_group=""
  local intent_description=""
  local summary=""
  local selected_inputs="[]"
  local planned_outputs="[]"
  local index=0

  [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" =~ ^(local|koios)$ ]] || return 2
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == "register" ]]; then
    intent_description="Register ${CNTOOLS_WALLET_REGISTER_WALLET}'s stake credential and return all change to its base address."
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == "deregister" ]]; then
    intent_description="De-register ${CNTOOLS_WALLET_REGISTER_WALLET}'s stake credential, refund its stake deposit, and return all change to its base address."
  else
    return 2
  fi
  cntools_transaction_plan_reset \
    "${CNTOOLS_WALLET_REGISTER_INTENT}" \
    "${intent_description}" \
    exact || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == "Hardware" ]]; then
    payment_group="wallet-stake"
    stake_group="wallet-stake"
  fi
  cntools_transaction_plan_add_signer \
    "${CNTOOLS_WALLET_REGISTER_WALLET} payment key" spending \
    "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" \
    "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" \
    "${CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL}" \
    "${payment_group}" || return 1
  cntools_transaction_plan_add_signer \
    "${CNTOOLS_WALLET_REGISTER_WALLET} stake key" certificate \
    "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" \
    "${CNTOOLS_WALLET_REGISTER_STAKE_SOURCE}" \
    "${CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL}" \
    "${stake_group}" || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == "Hardware" ]]; then
    cntools_transaction_plan_add_change_key \
      "${CNTOOLS_WALLET_REGISTER_WALLET} base-address payment key" \
      "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" \
      "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" \
      wallet-stake || return 1
  fi
  if (( ${#CNTOOLS_WALLET_REGISTER_INPUTS[@]} > 0 )); then
    selected_inputs="$(printf '%s\n' "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}" |
      jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  fi
  for index in "${!CNTOOLS_CHANGE_OUTPUTS[@]}"; do
    planned_outputs="$(jq -c \
      --arg type "${CNTOOLS_CHANGE_OUTPUT_TYPES[index]}" \
      --arg lovelace "${CNTOOLS_CHANGE_OUTPUT_LOVELACE[index]}" \
      --arg assetCount "${CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS[index]}" \
      '. + [{type: $type, lovelace: $lovelace,
             nativeAssetCount: $assetCount}]' <<< "${planned_outputs}")" ||
      return 1
  done
  summary="$(jq -cn \
    --arg wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" \
    --arg type "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" \
    --arg stakeAddress "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" \
    --arg changeAddress "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
    --arg baseAddress "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
    --arg paymentAddress "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" \
    --arg depositLovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" \
    --arg inputLovelace "${CNTOOLS_WALLET_REGISTER_LOVELACE}" \
    --arg inputCount "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}" \
    --arg availableLovelace "${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE}" \
    --arg availableInputCount "${CNTOOLS_WALLET_REGISTER_AVAILABLE_INPUT_COUNT}" \
    --arg feeReserveLovelace "${CNTOOLS_WALLET_REGISTER_FEE_RESERVE}" \
    --arg nativeAssetCount "${CNTOOLS_WALLET_REGISTER_ASSET_COUNT}" \
    --arg dataSource "${CNTOOLS_WALLET_REGISTER_SOURCE}" \
    --arg action "${CNTOOLS_WALLET_REGISTER_SUMMARY_ACTION}" \
    --arg depositEffect "${CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT}" \
    --argjson selectedInputs "${selected_inputs}" \
    --argjson transactionPolicy "${CNTOOLS_WALLET_REGISTER_POLICY_JSON}" \
    --argjson plannedOutputs "${planned_outputs}" '
      {
        action: $action,
        wallet: $wallet,
        walletType: $type,
        stakeAddress: $stakeAddress,
        changeAddress: $changeAddress,
        fundingAddresses: [$baseAddress, $paymentAddress] | unique,
        depositLovelace: $depositLovelace,
        depositEffect: $depositEffect,
        inputLovelace: $inputLovelace,
        inputCount: $inputCount,
        selectedInputs: $selectedInputs,
        availableLovelace: $availableLovelace,
        availableInputCount: $availableInputCount,
        nativeAssetCount: $nativeAssetCount,
        feeReserveLovelace: $feeReserveLovelace,
        transactionPolicy: $transactionPolicy,
        plannedChangeOutputs: $plannedOutputs,
        dataSource: $dataSource
      }
    ')" || return 1
  cntools_transaction_plan_set_summary "${summary}"
}

cntools_wallet_register_new_body_path_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_temp_file _cntools_path register-body-path || return 1
  cntools_transaction_temp_remove "${_cntools_path}" || return 1
  _cntools_output_ref="${_cntools_path}"
}

cntools_wallet_register_build_package_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_body_file=""
  local _cntools_package_file=""
  local input=""
  local output=""
  local output_index=0
  local planned_asset_count=0
  local -a arguments=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_require_cli || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  }
  for output_index in "${!CNTOOLS_CHANGE_OUTPUTS[@]}"; do
    planned_asset_count=$((planned_asset_count +
      CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS[output_index]))
  done
  if (( planned_asset_count != CNTOOLS_WALLET_REGISTER_ASSET_COUNT )); then
    cntools_wallet_register_set_error \
      "The applied change plan does not preserve every selected native asset."
    return 1
  fi
  cntools_wallet_register_certificate_create || return 1
  cntools_wallet_register_plan_create || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR:-The signer plan could not be created.}"
    return 1
  }
  cntools_wallet_register_new_body_path_into _cntools_body_file || return 1
  for input in "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}"; do
    arguments+=(--tx-in "${input}")
  done
  for output in "${CNTOOLS_CHANGE_OUTPUTS[@]}"; do
    arguments+=(--tx-out "${output}")
  done
  arguments+=(
    --change-address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}"
    --certificate-file "${CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE}"
  )
  if [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" == "local" ]]; then
    cntools_transaction_build_body \
      build "${_cntools_body_file}" -- "${arguments[@]}" || {
        CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
        return 1
      }
  else
    arguments+=(
      --protocol-params-file "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}"
      --total-utxo-value "${CNTOOLS_WALLET_REGISTER_TOTAL_VALUE}"
    )
    cntools_transaction_build_body \
      build-estimate "${_cntools_body_file}" -- "${arguments[@]}" || {
        CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
        return 1
      }
  fi
  CNTOOLS_TRANSACTION_TEMP_FILES+=("${_cntools_body_file}")
  cntools_transaction_package_create_staged_into \
    _cntools_package_file "${_cntools_body_file}" || {
      CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR:-The transaction package could not be created.}"
      return 1
    }
  _cntools_output_ref="${_cntools_package_file}"
  cntools_wallet_register_log TRANSACTION \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} package staged wallet=${CNTOOLS_WALLET_REGISTER_WALLET} backend=${CNTOOLS_WALLET_REGISTER_BACKEND} inputs=${#CNTOOLS_WALLET_REGISTER_INPUTS[@]} witnesses=$(cntools_transaction_plan_witness_count)"
}
