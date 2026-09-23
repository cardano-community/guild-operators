#!/usr/bin/env bash
# Koios v1.4.2 tx_status contract and best-effort post-submit orchestration.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-monitor.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
CNTOOLS_TMP_DIR="${TEST_ROOT}"
CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_UI_INTERACTIVE=Y
CNTOOLS_KOIOS_API=https://preview.koios.rest/api/v1
. "${CNTOOLS_ROOT}/core/log.sh"
for lib in number transaction transaction-monitor transaction-ui; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
printf -v TX '%064d' 1
QUERY_COUNT=0
CNTOOLS_TRANSACTION_ERROR=unchanged
cntools_http_request() {
  [[ "$1" == POST && "$2" == "${CNTOOLS_KOIOS_API}/tx_status" ]] || fail 'wrong endpoint'
  local output="$3" payload="" header=""
  shift 3
  while (( $# > 0 )); do
    case "$1" in
      --data) payload="$2"; shift ;;
      --header) [[ "$2" != @* ]] || header="${2#@}"; shift ;;
    esac
    shift
  done
  jq -e --arg tx "${TX}" '._tx_hashes == [$tx]' <<< "${payload}" >/dev/null || fail 'wrong body'
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    [[ -f "${header}" && "$(< "${header}")" == "Authorization: Bearer ${CNTOOLS_KOIOS_TOKEN}" ]] || fail 'protected authorization'
    LAST_AUTH_FILE="${header}"
  fi
  QUERY_COUNT=$((QUERY_COUNT+1))
  [[ "${HTTP_STATUS:-0}" == 0 ]] || return "${HTTP_STATUS}"
  if [[ "${AUTOINCLUDE:-N}" == Y && ${QUERY_COUNT} -ge 3 ]]; then
    jq -cn --arg tx "${TX}" '[{tx_hash:$tx,num_confirmations:0}]' > "${output}"
  else printf '%s' "${RESPONSE}" > "${output}"; fi
}
RESPONSE_FILE="${TEST_ROOT}/response"
for confirmations in null 0 1 1200; do
  RESPONSE="$(jq -cn --arg tx "${TX}" --argjson n "${confirmations}" '[{tx_hash:$tx,num_confirmations:$n}]')"
  cntools_transaction_monitor_query "${TX}" "${RESPONSE_FILE}" || fail 'valid response rejected'
  expected="${confirmations}"; [[ "${confirmations}" != null ]] || expected=""
  [[ "${CNTOOLS_TRANSACTION_MONITOR_CONFIRMATIONS}" == "${expected}" ]] || fail 'null / zero interpretation'
done
RESPONSE='[]'
cntools_transaction_monitor_query "${TX}" "${RESPONSE_FILE}" || fail 'empty not pending'
[[ -z "${CNTOOLS_TRANSACTION_MONITOR_CONFIRMATIONS}" ]] || fail 'stale inclusion survived empty response'
for RESPONSE in '{}' 'broken' '[{"tx_hash":"wrong","num_confirmations":1}]' \
    "[{\"tx_hash\":\"${TX}\"}]" \
    "[{\"tx_hash\":\"${TX}\",\"num_confirmations\":-1}]" \
    "[{\"tx_hash\":\"${TX}\",\"num_confirmations\":\"0\"}]" \
    "[{\"tx_hash\":\"${TX}\",\"num_confirmations\":0.5}]"; do
  if cntools_transaction_monitor_query "${TX}" "${RESPONSE_FILE}"; then fail 'invalid response accepted'; fi
done
CNTOOLS_KOIOS_TOKEN=secret-test-token
RESPONSE='[]'
cntools_transaction_monitor_query "${TX}" "${RESPONSE_FILE}" || fail 'authenticated query'
[[ ! -e "${LAST_AUTH_FILE}" ]] || fail 'auth file leaked'
grep -q 'Replay: curl.*tx_status' "${TEST_ROOT}/log" || fail 'copyable request not logged'
grep -q '_tx_hashes' "${TEST_ROOT}/log" || fail 'request body not logged'
if grep -q 'secret-test-token' "${TEST_ROOT}/log"; then fail 'token logged'; fi
HTTP_STATUS=22
if cntools_transaction_monitor_query "${TX}" "${RESPONSE_FILE}"; then fail 'HTTP failure accepted'; fi
[[ ! -e "${LAST_AUTH_FILE}" ]] || fail 'auth file leaked on failure'
HTTP_STATUS=0
CNTOOLS_KOIOS_TOKEN=""

# Exercise the sourced helper before replacing it with the no-delay test stub.
# shellcheck disable=SC2218
{
  if printf q | cntools_transaction_monitor_wait 5; then fail 'q did not stop waiting'; fi
  if cntools_transaction_monitor_wait 5 < /dev/null; then fail 'closed input did not stop waiting'; fi
  cntools_transaction_monitor_wait 0 || fail 'zero wait failed'
}

SPIN_COUNT=0 SPIN_ACTIVE=N WAIT_COUNT=0
cntools_ui_spin_function() {
  [[ "${SPIN_ACTIVE}" == N ]] || fail 'nested monitoring spinner'
  [[ "$1" == 'Waiting for block inclusion through Koios…' ]] || fail 'unexpected spinner title'
  SPIN_COUNT=$((SPIN_COUNT + 1))
  [[ "${SPIN_STATUS:-0}" == 0 ]] || return "${SPIN_STATUS}"
  SPIN_ACTIVE=Y
  shift
  "$@"
  SPIN_ACTIVE=N
}
cntools_transaction_monitor_wait() {
  [[ "${SPIN_ACTIVE}" == Y ]] || fail 'spinner disappeared between requests'
  [[ "$1" == 5 ]] || fail 'polling interval changed'
  WAIT_COUNT=$((WAIT_COUNT + 1))
  return "${STOP_WAIT:-0}"
}
cntools_ui_confirm() { printf 'prompt\n' >> "${TEST_ROOT}/ui"; return "${DECLINE:-0}"; }
cntools_ui_render_status() { printf '%s\n' "$2" >> "${TEST_ROOT}/ui"; }
cntools_ui_content_width() { printf 120; }
cntools_ui_table() { cat >> "${TEST_ROOT}/ui"; }
cntools_theme_style_value_into() { printf -v "$1" '%s' "$3"; }

QUERY_COUNT=0 AUTOINCLUDE=Y
cntools_transaction_ui_offer_monitor "${TX}" || fail 'monitor changed submission result'
[[ "${CNTOOLS_TRANSACTION_MONITOR_STATE}" == included && ${QUERY_COUNT} == 3 ]] || fail 'pending -> included polling'
[[ ${SPIN_COUNT} == 1 && ${WAIT_COUNT} == 2 && "${SPIN_ACTIVE}" == N ]] || fail 'monitor did not use one continuous spinner'
grep -q 'Included in a block' "${TEST_ROOT}/ui" || fail 'inclusion not displayed'
grep -q 'Blocks since inclusion.*0' "${TEST_ROOT}/ui" || fail 'zero block count not displayed'
[[ "${CNTOOLS_TRANSACTION_ERROR}" == unchanged ]] || fail 'monitor changed submit error state'

AUTOINCLUDE=N STOP_WAIT=1 QUERY_COUNT=0
cntools_transaction_ui_offer_monitor "${TX}" || fail 'cancel changed submission result'
[[ "${CNTOOLS_TRANSACTION_MONITOR_STATE}" == cancelled && ${QUERY_COUNT} == 1 ]] || fail 'cancel ignored'
STOP_WAIT=0 HTTP_STATUS=22 QUERY_COUNT=0
cntools_transaction_ui_offer_monitor "${TX}" || fail 'API failure changed submission result'
[[ "${CNTOOLS_TRANSACTION_MONITOR_STATE}" == unavailable && ${QUERY_COUNT} == 3 ]] || fail 'API retries not bounded'
HTTP_STATUS=0 QUERY_COUNT=0
cntools_transaction_ui_offer_monitor "${TX}" || fail 'timeout changed submission result'
[[ "${CNTOOLS_TRANSACTION_MONITOR_STATE}" == timeout && ${QUERY_COUNT} == 36 ]] || fail 'pending checks not bounded'
for SPIN_STATUS in 1 130; do
  QUERY_COUNT=0
  cntools_transaction_ui_offer_monitor "${TX}" || fail 'spinner failure changed submission result'
  expected=unavailable; (( SPIN_STATUS != 130 )) || expected=cancelled
  [[ "${CNTOOLS_TRANSACTION_MONITOR_STATE}" == "${expected}" && ${QUERY_COUNT} == 0 ]] || fail 'spinner failure not handled'
done
SPIN_STATUS=0
DECLINE=1 QUERY_COUNT=0
cntools_transaction_ui_offer_monitor "${TX}" || fail 'decline failed'
[[ ${QUERY_COUNT} == 0 ]] || fail 'request before consent'
DECLINE=0
for mode in disabled offline noninteractive; do
  : > "${TEST_ROOT}/ui"
  CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_MODE=local CNTOOLS_UI_INTERACTIVE=Y
  case "${mode}" in
    disabled) CNTOOLS_KOIOS_ENABLED=N ;;
    offline) CNTOOLS_MODE=offline ;;
    noninteractive) CNTOOLS_UI_INTERACTIVE=N ;;
  esac
  cntools_transaction_ui_offer_monitor "${TX}" || fail 'unavailable offer failed'
  [[ ! -s "${TEST_ROOT}/ui" && ${QUERY_COUNT} == 0 ]] || fail 'offer / HTTP when unavailable'
done
printf 'CNTools transaction monitor tests passed.\n'
