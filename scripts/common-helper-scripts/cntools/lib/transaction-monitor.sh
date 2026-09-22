#!/usr/bin/env bash
# Optional, read-only Koios inclusion checks. Never resubmits a transaction.
# shellcheck disable=SC2034

CNTOOLS_TRANSACTION_MONITOR_STATE=""
CNTOOLS_TRANSACTION_MONITOR_CONFIRMATIONS=""

cntools_transaction_monitor_available() {
  [[ "${CNTOOLS_MODE:-offline}" != offline &&
     "${CNTOOLS_KOIOS_ENABLED:-N}" == Y &&
     "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]] &&
    command -v curl >/dev/null 2>&1
}

cntools_transaction_monitor_query() {
  local transaction_id="$1" response_file="$2" payload="" auth_file="" status=0 parsed=""
  local -a arguments=(--connect-timeout 3 --max-filesize 65536
    --header 'accept: application/json' --header 'content-type: application/json')
  CNTOOLS_TRANSACTION_MONITOR_CONFIRMATIONS=""
  [[ "${transaction_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  cntools_transaction_monitor_available || return 1
  payload="$(jq -cn --arg tx "${transaction_id}" '{_tx_hashes:[$tx]}')" || return 1
  arguments+=(--data "${payload}")
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    cntools_http_secret_file_create auth_file || return 1
    arguments+=(--header "@${auth_file}")
  fi
  cntools_api_request POST "${CNTOOLS_KOIOS_API%/}/tx_status" "${response_file}" \
    "${arguments[@]}" || status=$?
  [[ -z "${auth_file}" ]] || cntools_http_secret_file_remove "${auth_file}" || true
  (( status == 0 )) || return "${status}"
  # Koios 1.4.2: zero means inclusion in the latest indexed block. Null means
  # not indexed yet. An empty successful response is also pending, not failure.
  parsed="$(jq -er --arg tx "${transaction_id}" '
    if type != "array" then error("expected array")
    elif length == 0 then "pending"
    elif length != 1 then error("unexpected transaction count")
    elif (.[0] | type != "object" or .tx_hash != $tx or (has("num_confirmations") | not))
      then error("unexpected transaction identity/schema")
    elif .[0].num_confirmations == null then "pending"
    elif (.[0].num_confirmations | type == "number" and floor == . and . >= 0 and . <= 2147483647)
      then (.[0].num_confirmations | tostring)
    else error("invalid confirmations") end
  ' "${response_file}" 2>/dev/null)" || {
    cntools_transaction_log WARN "Koios tx_status returned invalid data id=${transaction_id}"
    return 1
  }
  [[ "${parsed}" == pending ]] || CNTOOLS_TRANSACTION_MONITOR_CONFIRMATIONS="${parsed}"
  cntools_transaction_log TX "Koios tx_status id=${transaction_id} confirmations=${parsed}"
}

# Only read keys after Gum's request spinner has relinquished the terminal.
# Other keys do not accelerate polling. Closing stdin also stops monitoring.
cntools_transaction_monitor_wait() {
  local key="" status=0 deadline=$((SECONDS + $1)) remaining=0
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS)); status=0
    IFS= read -r -s -n 1 -t "${remaining}" key || status=$?
    case "${key}" in q|Q) return 1 ;; esac
    (( status != 1 )) || return 1
  done
  return 0
}

cntools_transaction_monitor_run() {
  local transaction_id="$1" response_file="" attempt=0 failures=0 status=0
  local deadline=$((SECONDS + 180)) remaining=0 pause=0
  local CNTOOLS_CURL_TIMEOUT=10
  local CNTOOLS_TRANSACTION_ERROR="${CNTOOLS_TRANSACTION_ERROR:-}"
  CNTOOLS_TRANSACTION_MONITOR_STATE=pending
  CNTOOLS_TRANSACTION_MONITOR_CONFIRMATIONS=""
  if ! cntools_transaction_temp_file response_file monitor-response; then
    CNTOOLS_TRANSACTION_MONITOR_STATE=unavailable
    return 0
  fi
  for ((attempt = 1; attempt <= 36; attempt++)); do
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || break
    CNTOOLS_CURL_TIMEOUT=10
    (( remaining >= 10 )) || CNTOOLS_CURL_TIMEOUT="${remaining}"
    status=0
    cntools_ui_spin_function 'Checking block inclusion through Koios…' \
      cntools_transaction_monitor_query "${transaction_id}" "${response_file}" || status=$?
    if (( status == 130 )); then
      CNTOOLS_TRANSACTION_MONITOR_STATE=cancelled
      return 0
    elif (( status != 0 )); then
      failures=$((failures + 1))
      cntools_transaction_log WARN "Koios monitoring request failed id=${transaction_id} status=${status} consecutive=${failures}"
      if (( failures >= 3 )); then
        CNTOOLS_TRANSACTION_MONITOR_STATE=unavailable
        return 0
      fi
    else
      failures=0
      if [[ -n "${CNTOOLS_TRANSACTION_MONITOR_CONFIRMATIONS}" ]]; then
        CNTOOLS_TRANSACTION_MONITOR_STATE=included
        return 0
      fi
    fi
    remaining=$((deadline - SECONDS))
    (( remaining > 0 && attempt < 36 )) || break
    pause=5; (( remaining >= 5 )) || pause="${remaining}"
    if ! cntools_transaction_monitor_wait "${pause}"; then
      CNTOOLS_TRANSACTION_MONITOR_STATE=cancelled
      return 0
    fi
  done
  CNTOOLS_TRANSACTION_MONITOR_STATE=timeout
}
