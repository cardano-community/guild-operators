#!/usr/bin/env bash
# Current protocol parameters and full UTxO inventories for key-wallet transfers.
# shellcheck disable=SC2034

CNTOOLS_FUNDING_PROTOCOL=""
CNTOOLS_FUNDING_BACKEND=""
CNTOOLS_FUNDING_SLOT=""
CNTOOLS_FUNDING_EPOCH=""
CNTOOLS_FUNDING_TOTAL="0"
CNTOOLS_FUNDING_REFERENCE_SKIPPED=0
CNTOOLS_FUNDING_EMPTY=N
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
  CNTOOLS_FUNDING_EPOCH=''
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
      tip_slot="$(jq -er '.slot | select(type == "number" and . >= 0 and floor == .) | tostring' "${tip_response}")" || return 1
      CNTOOLS_FUNDING_EPOCH="$(jq -r '.epoch // empty' "${tip_response}")" || return 1 ;;
    koios)
      [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]] || return 1
      cntools_funding_get "${CNTOOLS_KOIOS_API%/}/tip" "${tip_response}" || return 1
      tip_slot="$(jq -er 'if type == "array" and length == 1 then .[0].abs_slot else empty end | select(type == "number" and . >= 0 and floor == .) | tostring' "${tip_response}")" || return 1
      CNTOOLS_FUNDING_EPOCH="$(jq -r '.[0].epoch_no // empty' "${tip_response}")" || return 1 ;;
    *) return 2 ;;
  esac
  [[ -n "${tip_slot}" ]] && cntools_transaction_slot_value_valid "${tip_slot}" || return 1
  printf -v "${tip_output}" '%s' "${tip_slot}"
}

# Koios returns at most 1,000 rows per request: page through a wallet's UTxOs
# (up to CNTOOLS_UTXO_MAX_COUNT) and merge them into RESPONSE_FILE. Offset
# paging needs a stable order, or pages repeat and drop rows.
cntools_funding_koios_utxos() {
  local fku_response="$1" fku_payload='' fku_page='' fku_offset=0 fku_rows=0
  local -a fku_pages=()
  fku_payload="$(jq -cn --arg a "$2" --arg b "${3:-$2}" '{_addresses: ([$a,$b] | unique), _extended:true}')" || return 1
  while true; do
    cntools_transaction_temp_file fku_page funding-utxo-page || return 1
    cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/address_utxos?select=tx_hash%2Ctx_index%2Caddress%2Cvalue%3A%3Atext%2Casset_list%2Cdatum_hash%2Cinline_datum%2Creference_script&order=tx_hash.asc%2Ctx_index.asc&limit=1000&offset=${fku_offset}" \
      "${fku_payload}" "${fku_page}" 16777216 || return 1
    # The loader validates the response; a malformed page ends paging.
    fku_rows="$(jq -r 'if type == "array" then length else 0 end' "${fku_page}" 2>/dev/null)" || fku_rows=0
    fku_pages+=("${fku_page}")
    [[ "${fku_rows}" == 1000 ]] || break
    fku_offset=$((fku_offset + 1000))
    (( fku_offset <= ${CNTOOLS_UTXO_MAX_COUNT:-5000} )) || break
  done
  if (( ${#fku_pages[@]} == 1 )); then
    cat -- "${fku_pages[0]}" > "${fku_response}" || return 1
  else
    # A UTxO created while paging shifts later pages by one row: keep one copy.
    jq -cs 'if all(.[]; type == "array") then add | unique_by([.tx_hash, .tx_index]) else null end' \
      "${fku_pages[@]}" > "${fku_response}" || return 1
  fi
}

cntools_funding_collect() {
  local primary="${1:-}" payment="${2:-${1:-}}" response="" errors=""
  local status=0 index=0 reserve=""
  local -a network=() address_arguments=(--address "${primary}")
  CNTOOLS_FUNDING_TOTAL=0 CNTOOLS_FUNDING_REFERENCE_SKIPPED=0 CNTOOLS_FUNDING_EMPTY=N
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
    cntools_funding_koios_utxos "${response}" "${primary}" "${payment}" || return 1
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
  cntools_coin_initial_fee_into reserve "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    cntools_utxo_value_add_index "${index}" CNTOOLS_FUNDING_TOTAL \
      CNTOOLS_FUNDING_ASSET_IDS CNTOOLS_FUNDING_ASSETS || return 1
  done
  # EMPTY lets actions report an empty wallet as an outcome, not a failure.
  (( ${#CNTOOLS_UTXO_REFS[@]} > 0 )) || {
    CNTOOLS_FUNDING_EMPTY=Y
    cntools_transaction_set_error "This wallet has no spendable UTxOs."; return 1;
  }
  cntools_transaction_log TRANSACTION "Transaction funding inventory backend=${CNTOOLS_FUNDING_BACKEND} inputs=${#CNTOOLS_UTXO_REFS[@]} lovelace=${CNTOOLS_FUNDING_TOTAL} slot=${CNTOOLS_FUNDING_SLOT}"
}

# Spending a reference-script UTxO needs the script size in the fee and would
# destroy the script. Actions that do not price it leave such inputs untouched.
cntools_funding_exclude_reference_scripts() {
  local index=0 added=0 asset=''
  local -a refs=("${CNTOOLS_UTXO_REFS[@]}") addresses=("${CNTOOLS_UTXO_ADDRESSES[@]}") coins=("${CNTOOLS_UTXO_LOVELACE[@]}")
  local -a lists=("${CNTOOLS_UTXO_ASSET_LISTS[@]}") datums=("${CNTOOLS_UTXO_HAS_DATUM[@]}") scripts=("${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[@]}") names=()
  local -A quantities=()
  CNTOOLS_FUNDING_REFERENCE_SKIPPED=0
  for index in "${!refs[@]}"; do
    [[ "${scripts[index]}" == N ]] || CNTOOLS_FUNDING_REFERENCE_SKIPPED=$((CNTOOLS_FUNDING_REFERENCE_SKIPPED + 1))
  done
  (( CNTOOLS_FUNDING_REFERENCE_SKIPPED > 0 )) || return 0
  for asset in "${!CNTOOLS_UTXO_ASSET_QUANTITIES[@]}"; do quantities["${asset}"]="${CNTOOLS_UTXO_ASSET_QUANTITIES[${asset}]}"; done
  cntools_utxo_reset
  CNTOOLS_FUNDING_TOTAL=0; CNTOOLS_FUNDING_ASSET_IDS=(); CNTOOLS_FUNDING_ASSETS=()
  for index in "${!refs[@]}"; do
    [[ "${scripts[index]}" == N ]] || continue
    added="${#CNTOOLS_UTXO_REFS[@]}"
    cntools_utxo_add "${refs[index]}" "${addresses[index]}" "${coins[index]}" "${datums[index]}" N || return 1
    names=()
    [[ -z "${lists[index]}" ]] || read -r -a names <<< "${lists[index]}"
    for asset in "${names[@]}"; do
      cntools_utxo_add_asset "${added}" "${asset}" "${quantities[${index}|${asset}]}" || return 1
    done
    cntools_utxo_value_add_index "${added}" CNTOOLS_FUNDING_TOTAL CNTOOLS_FUNDING_ASSET_IDS CNTOOLS_FUNDING_ASSETS || return 1
  done
  cntools_transaction_log TRANSACTION "Reference-script UTxOs left untouched count=${CNTOOLS_FUNDING_REFERENCE_SKIPPED} remaining inputs=${#CNTOOLS_UTXO_REFS[@]} lovelace=${CNTOOLS_FUNDING_TOTAL}"
  (( ${#CNTOOLS_UTXO_REFS[@]} > 0 )) || {
    # Nothing is left to spend: an outcome for the action, like an empty wallet.
    CNTOOLS_FUNDING_EMPTY=Y
    cntools_transaction_set_error "This wallet's only UTxOs hold reference scripts, which this action leaves untouched."; return 1;
  }
}

# The UTxOs a build left alone: reference scripts (never spent here) and datum
# or script UTxOs it did not select (spent only as a last resort). Sets COUNT
# and a singular WHAT label ("reference-script UTxO", "datum UTxO", ...), for
# reviews that draw their own rows.
cntools_funding_untouched_into() {
  local -n fui_count="$1" fui_what="$2"
  local fui_scripts="${CNTOOLS_FUNDING_REFERENCE_SKIPPED:-0}" fui_datums=0 fui_index=0
  for fui_index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    [[ -z "${CNTOOLS_COIN_SELECTED_MAP[${fui_index}]+x}" ]] || continue
    if [[ "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[fui_index]:-N}" != N ]]; then fui_scripts=$((fui_scripts + 1))
    elif [[ "${CNTOOLS_UTXO_HAS_DATUM[fui_index]:-N}" != N ]]; then fui_datums=$((fui_datums + 1)); fi
  done
  fui_count=$((fui_scripts + fui_datums)); fui_what='reference-script UTxO'
  if (( fui_scripts > 0 && fui_datums > 0 )); then fui_what='script or datum UTxO'
  elif (( fui_datums > 0 )); then fui_what='datum UTxO'; fi
}

# Review row (cntools_transaction_ui_untouched_row) for the UTxOs a build left
# alone. An optional COUNT and WHAT add one more kind, e.g. Collect's token
# UTxOs, on a continuation row.
cntools_funding_render_untouched_row() {
  local fu_count=0 fu_what='' fu_extra="${1:-0}" fu_extra_what="${2:-token UTxO}" fu_label=''
  cntools_funding_untouched_into fu_count fu_what
  if (( fu_count > 0 )); then
    cntools_transaction_ui_untouched_row "${fu_count}" "${fu_what}"
    [[ "${fu_extra}" =~ ^[1-9][0-9]*$ ]] || return 0
    fu_label="$(cntools_number_format "${fu_extra}") ${fu_extra_what}"; (( fu_extra == 1 )) || fu_label+=s
    cntools_transaction_ui_styled_row '' "${fu_label}" value
  else
    cntools_transaction_ui_untouched_row "${fu_extra}" "${fu_extra_what}"
  fi
}
