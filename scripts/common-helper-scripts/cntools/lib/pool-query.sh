#!/usr/bin/env bash
# Exact target lookup; never download a pool's arbitrary metadata URL.
# shellcheck disable=SC2034
CNTOOLS_POOL_STATUS=""
CNTOOLS_POOL_RETIRING=""
CNTOOLS_POOL_NAME=""
CNTOOLS_POOL_TICKER=""
CNTOOLS_POOL_SOURCE=""

cntools_pool_parse_local() {
  local file="$1" bech="$2" hex="$3" record=""
  jq -e 'type == "object"' "${file}" >/dev/null || return 1
  [[ "$(jq 'length' "${file}")" != 0 ]] || return 4
  record="$(jq -er --arg hex "${hex}" --arg bech "${bech}" '
    if length != 1 then error("unexpected pools") else (.[$hex] // .[$bech]) end |
    select(type == "object" and has("poolParams") and has("retiring")) |
    select(.poolParams | type == "object" and length > 0) |
    if .retiring == null then "registered\u001f-"
    elif (.retiring | type == "number" and . >= 0 and floor == . and . <= 2147483647)
      then "retiring\u001f" + (.retiring | tostring)
    else error("invalid retirement") end
  ' "${file}")" || return 1
  IFS=$'\037' read -r CNTOOLS_POOL_STATUS CNTOOLS_POOL_RETIRING <<< "${record}"
  [[ "${CNTOOLS_POOL_RETIRING}" != - ]] || CNTOOLS_POOL_RETIRING=""
}

cntools_pool_parse_koios() {
  local file="$1" bech="$2" hex="$3" record=""
  jq -e 'type == "array"' "${file}" >/dev/null || return 1
  [[ "$(jq 'length' "${file}")" != 0 ]] || return 4
  record="$(jq -er --arg hex "${hex}" --arg bech "${bech}" '
    select(length == 1) | .[0] |
    select(.pool_id_bech32 == $bech and .pool_id_hex == $hex) |
    select(.pool_status == "registered" or .pool_status == "retiring" or .pool_status == "retired") |
    select(has("retiring_epoch")) |
    select(.retiring_epoch == null or (.retiring_epoch | type == "number" and . >= 0 and floor == . and . <= 2147483647)) |
    select(.pool_status != "retiring" or .retiring_epoch != null) |
    [.pool_status, (.retiring_epoch // "-" | tostring)] | join("\u001f")
  ' "${file}")" || return 1
  IFS=$'\037' read -r CNTOOLS_POOL_STATUS CNTOOLS_POOL_RETIRING <<< "${record}"
  [[ "${CNTOOLS_POOL_STATUS}" != retired ]] || return 4
  [[ "${CNTOOLS_POOL_RETIRING}" != - ]] || CNTOOLS_POOL_RETIRING=""
  CNTOOLS_POOL_NAME="$(jq -r '.[0].meta_json.name | if type == "string" then gsub("[[:cntrl:]]"; " ") | .[0:120] else "" end' "${file}")" || return 1
  CNTOOLS_POOL_TICKER="$(jq -r '.[0].meta_json.ticker | if type == "string" then gsub("[[:cntrl:]]"; " ") | .[0:20] else "" end' "${file}")" || return 1
}

cntools_pool_query() {
  local bech="$1" hex="$2" backend="$3" response="" errors="" payload="" status=0
  local -a network=()
  CNTOOLS_POOL_STATUS=""; CNTOOLS_POOL_RETIRING=""; CNTOOLS_POOL_NAME=""; CNTOOLS_POOL_TICKER=""; CNTOOLS_POOL_SOURCE=""
  cntools_transaction_temp_file response pool-state || return 1
  case "${backend}" in
    local)
      cntools_transaction_temp_file errors pool-state-errors || return 1
      cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
      cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest query pool-state \
        --stake-pool-id "${bech}" "${network[@]}" --socket-path "${CNTOOLS_SOCKET}" --output-json || status=$?
      if ((status != 0)); then
        cntools_transaction_log_cli_failure 'Pool state query failed' "${status}" "${errors}" "${response}"
        return 1
      fi
      cntools_pool_parse_local "${response}" "${bech}" "${hex}" || return $?
      CNTOOLS_POOL_SOURCE='Local node' ;;
    koios)
      [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]] || return 1
      payload="$(jq -cn --arg pool "${bech}" '{_pool_bech32_ids:[$pool]}')" || return 1
      cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/pool_info" "${payload}" "${response}" || return 1
      cntools_pool_parse_koios "${response}" "${bech}" "${hex}" || return $?
      CNTOOLS_POOL_SOURCE='Koios API' ;;
    *) return 2 ;;
  esac
  cntools_transaction_log POOL "Pool checked id=${bech} status=${CNTOOLS_POOL_STATUS} retiring=${CNTOOLS_POOL_RETIRING:-none} source=${backend}"
}
