#!/usr/bin/env bash
# Koios address and stake data collection.
# shellcheck disable=SC2034

cntools_wallet_query_koios_addresses() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local response_file=""
  local payload=""
  local balance=""
  local asset_output=""
  local asset_policy=""
  local asset_name=""
  local asset_quantity=""
  local asset_fingerprint=""
  local asset_decimals=""
  local asset_id=""
  local asset_parse_failed=0
  local expected_count=0
  local matched_count=0
  local -a addresses=()

  [[ -z "${base_address}" ]] || addresses+=("${base_address}")
  [[ -z "${payment_address}" ]] || addresses+=("${payment_address}")
  (( ${#addresses[@]} > 0 )) || return 2
  expected_count="${#addresses[@]}"
  cntools_wallet_query_temp_file response_file || return 1
  payload="$(printf '%s\n' "${addresses[@]}" | jq -Rsc '
    split("\n") | map(select(length > 0)) | {_addresses: .}
  ')" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/address_info${CNTOOLS_WALLET_KOIOS_ADDRESS_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios address_info request failed"
    return 1
  fi
  jq -e --arg base "${base_address}" --arg payment "${payment_address}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
    def policy_id:
      type == "string" and test("^[0-9a-fA-F]{56}$");
    def asset_name:
      type == "null" or
      (type == "string" and test("^([0-9a-fA-F]{2}){0,32}$"));
    def fingerprint:
      type == "null" or
      (type == "string" and
        test("^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$"));
    def decimals:
      type == "null" or
      (type == "number" and . >= 0 and . <= 255 and floor == .);
    type == "array" and
    all(.[];
      (.address | type == "string") and
      (.balance | uint) and
      (.utxo_set | type == "array") and
      all(.utxo_set[];
        ((.asset_list == null) or (.asset_list | type == "array")) and
        all((.asset_list // [])[];
          (.policy_id | policy_id) and
          (.asset_name | asset_name) and
          (.quantity | uint) and
          ((.fingerprint // null) | fingerprint) and
          ((.decimals // null) | decimals))) and
      (.address == $base or .address == $payment)
    ) and
    ([.[].address] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios address_info returned invalid JSON"
    return 1
  }
  if [[ "$(jq -r 'length' "${response_file}")" == "0" ]]; then
    [[ -z "${base_address}" ]] || CNTOOLS_WALLET_BASE_LOVELACE="0"
    [[ -z "${payment_address}" ]] || CNTOOLS_WALLET_PAYMENT_LOVELACE="0"
    CNTOOLS_WALLET_FUNDING_SUCCEEDED="${expected_count}"
    CNTOOLS_WALLET_UTXO_COUNT="0"
    CNTOOLS_WALLET_ASSET_COUNT="0"
    cntools_wallet_log WALLET \
      "Koios address_info returned no rows; unused funding addresses have zero balances"
    return 0
  fi
  if [[ -n "${base_address}" ]]; then
    if balance="$(jq -er --arg address "${base_address}" '
        ([.[] | select(.address == $address)][0].balance // empty) | tostring
      ' "${response_file}" 2>/dev/null)" &&
       [[ "${balance}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_BASE_LOVELACE="${balance}"
      matched_count=$((matched_count + 1))
    fi
  fi
  if [[ -n "${payment_address}" ]]; then
    if balance="$(jq -er --arg address "${payment_address}" '
        ([.[] | select(.address == $address)][0].balance // empty) | tostring
      ' "${response_file}" 2>/dev/null)" &&
       [[ "${balance}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_PAYMENT_LOVELACE="${balance}"
      matched_count=$((matched_count + 1))
    fi
  fi
  CNTOOLS_WALLET_FUNDING_SUCCEEDED="${matched_count}"
  if (( matched_count != expected_count )); then
    cntools_wallet_log ERROR \
      "Koios address_info omitted a requested funding address"
    return 1
  fi
  CNTOOLS_WALLET_UTXO_COUNT="$(jq -er '
    [.[].utxo_set[]?] | length | tostring
  ' "${response_file}" 2>/dev/null)" || return 1
  asset_output="$(jq -r '
    .[].utxo_set[]? | (.asset_list // [])[]
    | [
        .policy_id,
        (.asset_name // ""),
        .quantity,
        (.fingerprint // ""),
        (if .decimals == null then "" else (.decimals | tostring) end)
      ] | join("\u001f")
  ' "${response_file}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r \
      asset_policy asset_name asset_quantity \
      asset_fingerprint asset_decimals; do
    [[ -n "${asset_policy}" || -n "${asset_name}" ||
       -n "${asset_quantity}" || -n "${asset_fingerprint}" ||
       -n "${asset_decimals}" ]] || continue
    asset_id="${asset_policy}.${asset_name}"
    if ! cntools_wallet_asset_add \
        "${asset_id}" "${asset_quantity}" \
        "${asset_fingerprint}" "${asset_decimals}"; then
      asset_parse_failed=1
      break
    fi
  done <<< "${asset_output}"
  if (( asset_parse_failed != 0 )); then
    cntools_wallet_log ERROR "Koios address_info returned an invalid asset row"
    return 1
  fi
  cntools_wallet_asset_sort_ids || return 1
  CNTOOLS_WALLET_ASSET_COUNT="${#CNTOOLS_WALLET_ASSET_IDS[@]}"
}


cntools_wallet_query_koios_stake() {
  local reward_address="${1:-}"
  local response_file=""
  local payload=""
  local record=""

  [[ -n "${reward_address}" ]] || return 2
  cntools_wallet_query_temp_file response_file || return 1
  payload="$(jq -cn --arg address "${reward_address}" \
    '{_stake_addresses: [$address]}')" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/account_info${CNTOOLS_WALLET_KOIOS_ACCOUNT_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios account_info request failed"
    return 1
  fi
  jq -e --arg reward "${reward_address}" '
    def pool_id:
      type == "string" and
      test("^pool1[023456789acdefghjklmnpqrstuvwxyz]{51}$");
    def drep_id:
      type == "string" and
      ((. == "drep_always_abstain") or
       (. == "drep_always_no_confidence") or
       (. == "alwaysAbstain") or
       (. == "alwaysNoConfidence") or
       test("^drep1[023456789acdefghjklmnpqrstuvwxyz]{51}([023456789acdefghjklmnpqrstuvwxyz]{2})?$"));
    type == "array" and length <= 1 and
    all(.[];
      (.stake_address == $reward) and
      (.stake_address | type == "string") and
      (.status == "registered" or .status == "not registered") and
      (.rewards_available | type == "string" and length <= 80 and
        test("^[0-9]+$")) and
      ((.deposit == null) or
        (.deposit | type == "string" and length <= 80 and
          test("^[0-9]+$"))) and
      ((.delegated_pool == null) or (.delegated_pool | pool_id)) and
      ((.delegated_drep == null) or (.delegated_drep | drep_id))
    )
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios account_info returned invalid JSON"
    return 1
  }
  if [[ "$(jq -r 'length' "${response_file}")" == "0" ]]; then
    CNTOOLS_WALLET_REGISTERED="no"
    CNTOOLS_WALLET_REWARD_LOVELACE="0"
    CNTOOLS_WALLET_STAKE_DEPOSIT=""
    return 0
  fi
  record="$(jq -er '
    [
      (if .[0].status == "registered" then "yes" else "no" end),
      (.[0].rewards_available // "0"),
      (.[0].delegated_pool // ""),
      (.[0].delegated_drep // ""),
      (.[0].deposit // "")
    ] | map(tostring) | join("\u001f")
  ' "${response_file}" 2>/dev/null)" || return 1
  IFS=$'\037' read -r \
    CNTOOLS_WALLET_REGISTERED \
    CNTOOLS_WALLET_REWARD_LOVELACE \
    CNTOOLS_WALLET_POOL_DELEGATION \
    CNTOOLS_WALLET_DREP_DELEGATION \
    CNTOOLS_WALLET_STAKE_DEPOSIT <<< "${record}"
  [[ "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ &&
     ( -z "${CNTOOLS_WALLET_STAKE_DEPOSIT}" ||
       "${CNTOOLS_WALLET_STAKE_DEPOSIT}" =~ ^[0-9]+$ ) ]] || return 1
}


cntools_wallet_query_koios() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local reward_address="${3:-}"
  local attempted=0
  local succeeded=0
  local partial=0

  if [[ -n "${base_address}" || -n "${payment_address}" ]]; then
    attempted=$((attempted + 1))
    if cntools_wallet_query_koios_addresses \
        "${base_address}" "${payment_address}"; then
      succeeded=$((succeeded + 1))
      if ! cntools_wallet_query_koios_asset_metadata; then
        cntools_wallet_log WALLET \
          "Koios token metadata is incomplete; preserving on-chain holdings"
      fi
    elif (( CNTOOLS_WALLET_FUNDING_SUCCEEDED > 0 )); then
      partial=1
    fi
  fi
  if [[ -n "${reward_address}" ]]; then
    attempted=$((attempted + 1))
    cntools_wallet_query_koios_stake "${reward_address}" &&
      succeeded=$((succeeded + 1))
  fi
  if (( attempted == 0 )); then
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="This wallet has no valid address files to query."
  elif (( succeeded == attempted )); then
    CNTOOLS_WALLET_QUERY_STATUS="available"
    CNTOOLS_WALLET_QUERY_MESSAGE="Live data from Koios."
  elif (( succeeded > 0 || partial > 0 )); then
    CNTOOLS_WALLET_QUERY_STATUS="partial"
    CNTOOLS_WALLET_QUERY_MESSAGE="Some Koios wallet queries failed; available results are shown."
  else
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="Koios could not return wallet data."
  fi
}
