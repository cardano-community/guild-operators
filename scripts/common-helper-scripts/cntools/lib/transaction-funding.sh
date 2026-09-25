#!/usr/bin/env bash
# Current protocol parameters and full UTxO inventories for key-wallet transfers.
# shellcheck disable=SC2034

CNTOOLS_FUNDING_PROTOCOL=""
CNTOOLS_FUNDING_BACKEND=""
CNTOOLS_FUNDING_SLOT=""
CNTOOLS_FUNDING_TOTAL="0"
declare -ag CNTOOLS_FUNDING_ASSET_IDS=()
declare -Ag CNTOOLS_FUNDING_ASSETS=()

cntools_funding_get() {
  local endpoint="${1:-}" destination="${2:-}" auth="" status=0
  local -a arguments=(--connect-timeout 3 --max-filesize 4194304 --header 'accept: application/json')
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    cntools_http_secret_file_create auth || return 1
    arguments+=(--header "@${auth}")
  fi
  cntools_api_request GET "${endpoint}" "${destination}" "${arguments[@]}" || status=$?
  [[ -z "${auth}" ]] || cntools_http_secret_file_remove "${auth}" || true
  return "${status}"
}

cntools_funding_tip_into() {
  local tip_output="$1" tip_backend="$2" tip_response="" tip_errors="" tip_slot="" tip_status=0
  local -a tip_network=()
  cntools_transaction_temp_file tip_response transaction-tip || return 1
  case "${tip_backend}" in
    local)
      cntools_transaction_temp_file tip_errors transaction-tip-errors || return 1
      cntools_transaction_network_arguments_into tip_network "${CNTOOLS_NETWORK}" || return 1
      cntools_transaction_run_cli "${tip_response}" "${tip_errors}" -- \
        "${CNTOOLS_CLI}" latest query tip "${tip_network[@]}" \
        --socket-path "${CNTOOLS_SOCKET}" || tip_status=$?
      if (( tip_status != 0 )); then
        cntools_transaction_log_cli_failure 'Transaction tip query failed' "${tip_status}" "${tip_errors}" "${tip_response}"
        return 1
      fi
      tip_slot="$(jq -er '.slot | select(type == "number" and . >= 0 and floor == .) | tostring' "${tip_response}")" || return 1 ;;
    koios)
      [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]] || return 1
      cntools_funding_get "${CNTOOLS_KOIOS_API%/}/tip" "${tip_response}" || return 1
      tip_slot="$(jq -er 'if type == "array" and length == 1 then .[0].abs_slot else empty end | select(type == "number" and . >= 0 and floor == .) | tostring' "${tip_response}")" || return 1 ;;
    *) return 2 ;;
  esac
  [[ -n "${tip_slot}" ]] && cntools_transaction_slot_value_valid "${tip_slot}" || return 1
  printf -v "${tip_output}" '%s' "${tip_slot}"
}

cntools_funding_collect() {
  local primary="${1:-}" payment="${2:-${1:-}}" response="" errors=""
  local payload="" status=0 index=0 reserve=""
  local -a network=() address_arguments=(--address "${primary}")
  CNTOOLS_FUNDING_TOTAL=0
  CNTOOLS_FUNDING_ASSET_IDS=(); CNTOOLS_FUNDING_ASSETS=()
  CNTOOLS_FUNDING_SLOT=""; CNTOOLS_FUNDING_BACKEND=""
  [[ "${CNTOOLS_MODE:-}" != offline ]] || {
    cntools_transaction_set_error "Transaction building needs current chain data. Build online, then move the unsigned package to the offline signing system."
    return 1
  }
  cntools_transaction_temp_file CNTOOLS_FUNDING_PROTOCOL send-protocol || return 1
  cntools_transaction_temp_file response send-utxos || return 1
  cntools_transaction_temp_file errors send-query-errors || return 1
  if cntools_transaction_local_backend_ready; then
    CNTOOLS_FUNDING_BACKEND=local
    cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
    [[ "${primary}" == "${payment}" ]] || address_arguments+=(--address "${payment}")
    cntools_transaction_run_cli "${CNTOOLS_FUNDING_PROTOCOL}" "${errors}" -- \
      "${CNTOOLS_CLI}" latest query protocol-parameters "${network[@]}" \
      --socket-path "${CNTOOLS_SOCKET}" --output-json || status=$?
    if (( status == 0 )); then
      cntools_transaction_run_cli "${response}" "${errors}" -- \
        "${CNTOOLS_CLI}" latest query utxo "${address_arguments[@]}" "${network[@]}" \
        --socket-path "${CNTOOLS_SOCKET}" --output-json || status=$?
    fi
    if (( status == 0 )); then
      cntools_funding_tip_into CNTOOLS_FUNDING_SLOT local || status=$?
    fi
    if (( status != 0 )); then
      cntools_transaction_log_cli_failure "Transaction funding query failed" "${status}" "${errors}" "${response}"
      return 1
    fi
    cntools_utxo_load_local "${response}" "${primary}" "${payment}" || {
      cntools_transaction_set_error "${CNTOOLS_UTXO_ERROR}"; return 1;
    }
  elif [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" == https://* ]]; then
    CNTOOLS_FUNDING_BACKEND=koios
    cntools_funding_get "${CNTOOLS_KOIOS_API%/}/cli_protocol_params" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
    payload="$(jq -cn --arg a "${primary}" --arg b "${payment}" \
      '{_addresses: ([$a,$b] | unique), _extended:true}')" || return 1
    cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/address_utxos?select=tx_hash%2Ctx_index%2Caddress%2Cvalue%3A%3Atext%2Casset_list%2Cdatum_hash%2Cinline_datum%2Creference_script" \
      "${payload}" "${response}" || return 1
    cntools_utxo_load_koios "${response}" "${primary}" "${payment}" || {
      cntools_transaction_set_error "${CNTOOLS_UTXO_ERROR}"; return 1;
    }
    cntools_funding_tip_into CNTOOLS_FUNDING_SLOT koios || return 1
  else
    cntools_transaction_set_error "No current chain-data source is available for transaction building."
    return 1
  fi
  cntools_transaction_slot_value_valid "${CNTOOLS_FUNDING_SLOT}" || return 1
  [[ -n "${CNTOOLS_FUNDING_SLOT}" ]] || return 1
  cntools_coin_fee_reserve_into reserve "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    cntools_utxo_value_add_index "${index}" CNTOOLS_FUNDING_TOTAL \
      CNTOOLS_FUNDING_ASSET_IDS CNTOOLS_FUNDING_ASSETS || return 1
  done
  (( ${#CNTOOLS_UTXO_REFS[@]} > 0 )) || {
    cntools_transaction_set_error "This wallet has no spendable UTxOs."; return 1;
  }
  cntools_transaction_log TRANSACTION "Transaction funding inventory backend=${CNTOOLS_FUNDING_BACKEND} inputs=${#CNTOOLS_UTXO_REFS[@]} lovelace=${CNTOOLS_FUNDING_TOTAL} slot=${CNTOOLS_FUNDING_SLOT}"
}
