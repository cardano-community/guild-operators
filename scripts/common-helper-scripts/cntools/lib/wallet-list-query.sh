#!/usr/bin/env bash
# Bulk wallet catalog queries and result projection.
# shellcheck disable=SC2034

declare -Ag CNTOOLS_WALLET_LIST_ADDRESS_BALANCES=()
declare -Ag CNTOOLS_WALLET_LIST_ADDRESS_ASSETS=()
declare -Ag CNTOOLS_WALLET_LIST_STAKE_REWARDS=()

declare -ag CNTOOLS_WALLET_LIST_BASE_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_UTXO_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_REWARD_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_TOTAL_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_TOKEN_COUNTS=()
declare -ag CNTOOLS_WALLET_LIST_QUERY_STATUSES=()

cntools_wallet_list_query_reset() {
  local index=0

  CNTOOLS_WALLET_LIST_BASE_ADDRESSES=()
  CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES=()
  CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=()
  CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE=()
  CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE=()
  CNTOOLS_WALLET_LIST_UTXO_LOVELACE=()
  CNTOOLS_WALLET_LIST_REWARD_LOVELACE=()
  CNTOOLS_WALLET_LIST_TOTAL_LOVELACE=()
  CNTOOLS_WALLET_LIST_TOKEN_COUNTS=()
  CNTOOLS_WALLET_LIST_QUERY_STATUSES=()
  CNTOOLS_WALLET_LIST_ADDRESS_BALANCES=()
  CNTOOLS_WALLET_LIST_ADDRESS_ASSETS=()
  CNTOOLS_WALLET_LIST_STAKE_REWARDS=()
  CNTOOLS_WALLET_LIST_QUERY_LEVEL=""
  CNTOOLS_WALLET_LIST_QUERY_SUMMARY=""
  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]=""
    CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]=""
    CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]=""
    CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]=""
    CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="unavailable"
  done
}


cntools_wallet_list_collect_addresses() {
  local index=0
  local kind=""
  local value=""
  local status=0

  for (( index = 0; index < ${#CNTOOLS_WALLET_PATHS[@]}; index++ )); do
    for kind in base payment reward; do
      value=""
      if cntools_wallet_read_address \
          "${CNTOOLS_WALLET_PATHS[index]}" "${kind}" value; then
        status=0
      else
        status=$?
      fi
      case "${status}" in
        0)
          case "${kind}" in
            base) CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]="${value}" ;;
            payment) CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]="${value}" ;;
            reward) CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]="${value}" ;;
          esac
          ;;
        1) ;;
        2) ;;
        *) return "${status}" ;;
      esac
    done
  done
}


cntools_wallet_list_koios_payload() {
  local _cntools_field="${1:-}"
  local _cntools_output_name="${2:-}"
  local _cntools_payload=""
  shift 2 || return 2

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $# -gt 0 ]] ||
    return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  case "${_cntools_field}" in
    _addresses)
      _cntools_payload="$(printf '%s\n' "$@" | jq -Rsc '
        split("\n") | map(select(length > 0)) | {_addresses: .}
      ')" || return 1
      ;;
    _stake_addresses)
      _cntools_payload="$(printf '%s\n' "$@" | jq -Rsc '
        split("\n") | map(select(length > 0)) | {_stake_addresses: .}
      ')" || return 1
      ;;
    *) return 2 ;;
  esac
  _cntools_output_ref="${_cntools_payload}"
}


cntools_wallet_list_query_koios_address_batch() {
  local response_file=""
  local payload=""
  local requested=""
  local address=""
  local balance=""
  local asset_id=""
  local balance_rows=""
  local asset_rows=""
  local -A batch_balances=()
  local -A batch_assets=()

  (( $# > 0 )) || return 2
  cntools_wallet_query_temp_file response_file || return 1
  cntools_wallet_list_koios_payload _addresses payload "$@" || return 1
  requested="$(jq -c '._addresses' <<< "${payload}")" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/address_info${CNTOOLS_WALLET_KOIOS_ADDRESS_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios address_info batch request failed"
    return 1
  fi
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
    def policy_id:
      type == "string" and test("^[0-9a-fA-F]{56}$");
    def asset_name:
      type == "null" or
      (type == "string" and test("^([0-9a-fA-F]{2}){0,32}$"));
    type == "array" and
    all(.[];
      (.address | type == "string") and
      (.address as $address | ($requested | index($address)) != null) and
      (.balance | uint) and
      (.utxo_set | type == "array") and
      all(.utxo_set[];
        (.asset_list | type == "array") and
        all(.asset_list[];
          (.policy_id | policy_id) and
          (.asset_name | asset_name)))) and
    ([.[].address] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios address_info batch returned invalid JSON"
    return 1
  }
  # A successful empty response means none of the requested addresses has
  # appeared on-chain. Treat the complete batch as known zero rather than as
  # missing data. A non-empty response that omits a requested row remains
  # partial so an unexpectedly incomplete response cannot create a false zero.
  if [[ "$(jq -r 'length' "${response_file}")" == "0" ]]; then
    for address in "$@"; do
      batch_balances["${address}"]=0
      batch_assets["${address}"]=""
    done
    cntools_wallet_log WALLET \
      "Koios address_info batch returned no rows; unused funding addresses have zero balances"
  fi
  balance_rows="$(jq -r \
    '.[] | [.address, .balance] | @tsv' "${response_file}")" || return 1
  while IFS=$'\t' read -r address balance; do
    [[ -n "${address}" || -n "${balance}" ]] || continue
    [[ -n "${address}" && "${balance}" =~ ^[0-9]+$ ]] || return 1
    batch_balances["${address}"]="${balance}"
  done <<< "${balance_rows}"
  asset_rows="$(jq -r '
    .[] as $row
    | $row.utxo_set[].asset_list[]?
    | [$row.address, (.policy_id + "." + (.asset_name // ""))]
    | @tsv
  ' "${response_file}")" || return 1
  while IFS=$'\t' read -r address asset_id; do
    [[ -n "${address}" && -n "${asset_id}" ]] || continue
    batch_assets["${address}"]+="${asset_id}"$'\037'
  done <<< "${asset_rows}"
  for address in "${!batch_balances[@]}"; do
    CNTOOLS_WALLET_LIST_ADDRESS_BALANCES["${address}"]="${batch_balances[${address}]}"
    CNTOOLS_WALLET_LIST_ADDRESS_ASSETS["${address}"]="${batch_assets[${address}]:-}"
  done
}


cntools_wallet_list_query_koios_stake_batch() {
  local response_file=""
  local payload=""
  local requested=""
  local reward_address=""
  local reward_lovelace=""
  local reward_rows=""
  local -A batch_rewards=()

  (( $# > 0 )) || return 2
  cntools_wallet_query_temp_file response_file || return 1
  cntools_wallet_list_koios_payload _stake_addresses payload "$@" || return 1
  requested="$(jq -c '._stake_addresses' <<< "${payload}")" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/account_info${CNTOOLS_WALLET_KOIOS_ACCOUNT_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios account_info batch request failed"
    return 1
  fi
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
    type == "array" and
    all(.[];
      (.stake_address | type == "string") and
      (.stake_address as $address | ($requested | index($address)) != null) and
      (.status == "registered" or .status == "not registered") and
      (.rewards_available | uint)) and
    ([.[].stake_address] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios account_info batch returned invalid JSON"
    return 1
  }
  # Build a complete batch locally before committing it. A successful Koios
  # response omits valid reward addresses that have never been registered;
  # those are known zero-reward accounts, not missing data.
  for reward_address in "$@"; do
    batch_rewards["${reward_address}"]=0
  done
  reward_rows="$(jq -r '
    .[] | [.stake_address, .rewards_available] | @tsv
  ' "${response_file}")" || return 1
  while IFS=$'\t' read -r reward_address reward_lovelace; do
    [[ -n "${reward_address}" || -n "${reward_lovelace}" ]] || continue
    [[ -n "${reward_address}" && "${reward_lovelace}" =~ ^[0-9]+$ ]] ||
      return 1
    batch_rewards["${reward_address}"]="${reward_lovelace}"
  done <<< "${reward_rows}"
  for reward_address in "${!batch_rewards[@]}"; do
    CNTOOLS_WALLET_LIST_STAKE_REWARDS["${reward_address}"]="${batch_rewards[${reward_address}]}"
  done
}


cntools_wallet_list_query_koios_funding() {
  local address=""
  local payload=""
  local status=0
  local -a addresses=()
  local -a batch=()
  local -a candidate=()
  local -A seen=()

  for address in \
    "${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[@]}" \
    "${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[@]}"; do
    [[ -n "${address}" && -z "${seen[${address}]+x}" ]] || continue
    seen["${address}"]=1
    addresses+=("${address}")
  done
  for address in "${addresses[@]}"; do
    candidate=("${batch[@]}" "${address}")
    cntools_wallet_list_koios_payload _addresses payload \
      "${candidate[@]}" || return 1
    if (( ${#payload} > CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES &&
          ${#batch[@]} > 0 )); then
      cntools_wallet_list_query_koios_address_batch "${batch[@]}" || status=1
      batch=("${address}")
    else
      batch=("${candidate[@]}")
    fi
  done
  (( ${#batch[@]} == 0 )) ||
    cntools_wallet_list_query_koios_address_batch "${batch[@]}" || status=1
  return "${status}"
}


cntools_wallet_list_query_koios_stakes() {
  local address=""
  local payload=""
  local status=0
  local -a addresses=()
  local -a batch=()
  local -a candidate=()
  local -A seen=()

  for address in "${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[@]}"; do
    [[ -n "${address}" && -z "${seen[${address}]+x}" ]] || continue
    seen["${address}"]=1
    addresses+=("${address}")
  done
  for address in "${addresses[@]}"; do
    candidate=("${batch[@]}" "${address}")
    cntools_wallet_list_koios_payload _stake_addresses payload \
      "${candidate[@]}" || return 1
    if (( ${#payload} > CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES &&
          ${#batch[@]} > 0 )); then
      cntools_wallet_list_query_koios_stake_batch "${batch[@]}" || status=1
      batch=("${address}")
    else
      batch=("${candidate[@]}")
    fi
  done
  (( ${#batch[@]} == 0 )) ||
    cntools_wallet_list_query_koios_stake_batch "${batch[@]}" || status=1
  return "${status}"
}


cntools_wallet_list_project_koios_results() {
  local index=0
  local base_address=""
  local payment_address=""
  local address=""
  local reward_address=""
  local asset_list=""
  local asset_id=""
  local expected=0
  local matched=0
  local utxo_lovelace=0
  local -a address_assets=()
  local -A wallet_addresses=()
  local -A wallet_assets=()

  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    expected=0
    matched=0
    utxo_lovelace=0
    wallet_addresses=()
    wallet_assets=()
    base_address="${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]}"
    payment_address="${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]}"
    for address in "${base_address}" "${payment_address}"; do
      [[ -n "${address}" && -z "${wallet_addresses[${address}]+x}" ]] ||
        continue
      wallet_addresses["${address}"]=1
      expected=$((expected + 1))
      if [[ -n "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${address}]+x}" ]]; then
        matched=$((matched + 1))
        cntools_uint_add_into utxo_lovelace \
          "${utxo_lovelace}" \
          "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${address}]}" || return 1
        asset_list="${CNTOOLS_WALLET_LIST_ADDRESS_ASSETS[${address}]:-}"
        address_assets=()
        IFS=$'\037' read -r -a address_assets <<< "${asset_list}"
        for asset_id in "${address_assets[@]}"; do
          [[ -n "${asset_id}" ]] || continue
          wallet_assets["${asset_id}"]=1
        done
      fi
    done
    if [[ -n "${base_address}" &&
          -n "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${base_address}]+x}" ]]; then
      CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${base_address}]}"
    fi
    if [[ -n "${payment_address}" &&
          -n "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${payment_address}]+x}" ]]; then
      CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${payment_address}]}"
    fi
    if (( expected > 0 && matched == expected )); then
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]="${utxo_lovelace}"
      CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]="${#wallet_assets[@]}"
    fi
    reward_address="${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]}"
    if [[ -n "${reward_address}" &&
          -n "${CNTOOLS_WALLET_LIST_STAKE_REWARDS[${reward_address}]+x}" ]]; then
      CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]="${CNTOOLS_WALLET_LIST_STAKE_REWARDS[${reward_address}]}"
    fi
  done
}


cntools_wallet_list_query_local() {
  local index=0

  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    cntools_wallet_query \
      "${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]}" \
      "${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]}" \
      "${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]}"
    [[ ! "${CNTOOLS_WALLET_BASE_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_BASE_LOVELACE}"
    [[ ! "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_PAYMENT_LOVELACE}"
    [[ ! "${CNTOOLS_WALLET_TOTAL_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_TOTAL_LOVELACE}"
    [[ ! "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]="${CNTOOLS_WALLET_REWARD_LOVELACE}"
    [[ ! "${CNTOOLS_WALLET_ASSET_COUNT}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]="${CNTOOLS_WALLET_ASSET_COUNT}"
    cntools_wallet_query_cleanup
    if [[ -n "${CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE}" ]]; then
      CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
      CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Local wallet queries stopped after a backend failure; remaining values are shown as —."
      cntools_wallet_log ERROR \
        "Local wallet catalog query stopped systemic=${CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE}"
      break
    fi
  done
}


cntools_wallet_list_local_preflight() {
  if [[ -z "${CNTOOLS_CLI:-}" || ! -x "${CNTOOLS_CLI}" ]]; then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="The deployment's Cardano CLI is unavailable."
    cntools_wallet_log ERROR "Local wallet catalog query has no executable Cardano CLI"
    return 1
  fi
  if ! cntools_wallet_query_local_socket_ready; then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="The local node socket is unavailable: ${CNTOOLS_SOCKET}."
    cntools_wallet_log ERROR \
      "Local wallet catalog query socket is unavailable: ${CNTOOLS_SOCKET}"
    return 1
  fi
  if ! cntools_wallet_query_network_arguments; then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="The selected network has no local CLI mapping."
    cntools_wallet_log ERROR \
      "Local wallet catalog query has unsupported network=${CNTOOLS_NETWORK}"
    return 1
  fi
}


cntools_wallet_list_finalize_results() {
  local index=0
  local available=0
  local partial=0
  local unavailable=0
  local base_address=""
  local payment_address=""
  local reward_address=""
  local base_utxo=""
  local payment_utxo=""
  local rewards=""
  local total="0"
  local funding_total="0"
  local expected=0
  local matched=0
  local funding_expected=0
  local funding_matched=0

  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    base_address="${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]}"
    payment_address="${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]}"
    reward_address="${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]}"
    base_utxo="${CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]}"
    payment_utxo="${CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]}"
    rewards="${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]}"
    total=0
    funding_total=0
    expected=0
    matched=0
    funding_expected=0
    funding_matched=0

    if [[ -n "${base_address}" ]]; then
      expected=$((expected + 1))
      funding_expected=$((funding_expected + 1))
      if [[ "${base_utxo}" =~ ^[0-9]+$ ]]; then
        cntools_uint_add_into total "${total}" "${base_utxo}" || return 1
        cntools_uint_add_into \
          funding_total "${funding_total}" "${base_utxo}" || return 1
        matched=$((matched + 1))
        funding_matched=$((funding_matched + 1))
      fi
    fi
    if [[ -n "${payment_address}" ]]; then
      expected=$((expected + 1))
      funding_expected=$((funding_expected + 1))
      if [[ "${payment_utxo}" =~ ^[0-9]+$ ]]; then
        cntools_uint_add_into \
          total "${total}" "${payment_utxo}" || return 1
        cntools_uint_add_into \
          funding_total "${funding_total}" "${payment_utxo}" || return 1
        matched=$((matched + 1))
        funding_matched=$((funding_matched + 1))
      fi
    fi
    if [[ -n "${reward_address}" ]]; then
      expected=$((expected + 1))
      if [[ "${rewards}" =~ ^[0-9]+$ ]]; then
        cntools_uint_add_into total "${total}" "${rewards}" || return 1
        matched=$((matched + 1))
      fi
    fi
    if (( funding_expected > 0 && funding_matched == funding_expected )); then
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]="${funding_total}"
    else
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]=""
    fi

    if (( expected > 0 && matched == expected )); then
      CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]="${total}"
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="available"
      available=$((available + 1))
    elif (( matched > 0 )); then
      CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]=""
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="partial"
      partial=$((partial + 1))
    else
      CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]=""
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="unavailable"
      unavailable=$((unavailable + 1))
    fi
  done

  case "${CNTOOLS_MODE:-offline}" in
    offline)
      CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
      CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Offline mode — live wallet balances are not queried."
      ;;
    local) if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" != "true" ]]; then
      CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
      CNTOOLS_WALLET_LIST_QUERY_SUMMARY="${CNTOOLS_IMPLEMENTATION_NAME} does not provide local wallet queries."
    fi ;;
  esac
  [[ -n "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" ]] && return 0
  if (( unavailable > 0 && available == 0 && partial == 0 )); then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Live wallet balances are unavailable. See ${CNTOOLS_LOG}."
  elif (( unavailable > 0 || partial > 0 )); then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Some wallet balances are unavailable; incomplete totals are shown as —."
  fi
}


cntools_wallet_list_query_catalog() {
  cntools_wallet_list_query_reset
  cntools_wallet_list_collect_addresses || return 1
  case "${CNTOOLS_MODE:-offline}" in
    offline) ;;
    local)
      if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" ]]; then
        cntools_wallet_list_local_preflight &&
          cntools_wallet_list_query_local
      fi
      ;;
    light)
      cntools_wallet_list_query_koios_funding || true
      cntools_wallet_list_query_koios_stakes || true
      cntools_wallet_list_project_koios_results
      cntools_wallet_query_cleanup
      ;;
    *) return 2 ;;
  esac
  cntools_wallet_list_finalize_results
  cntools_wallet_log WALLET \
    "wallet catalog query completed backend=${CNTOOLS_BACKEND} wallets=${#CNTOOLS_WALLET_NAMES[@]}"
}
