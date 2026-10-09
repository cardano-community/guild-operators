#!/usr/bin/env bash
# Deterministic governance status and key-setup UI contracts; no chain access.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-governance-wallet.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query drep-id drep-query public-metadata governance-wallet-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_transaction_ui_styled_row() { printf '%s: %s\n' "$1" "$2"; }
hash="$(printf 'ab%.0s' {1..28})"
cntools_drep_bech32_into id "22${hash}"
response="${TEST_ROOT}/response"
jq -n --arg hash "${hash}" '[[{keyHash:$hash},{deposit:500000000,expiry:42,anchor:{url:"https://example.invalid/drep.json",dataHash:"abc"}}]]' > "${response}"
cntools_drep_parse_local "${response}" key "${hash}"
CNTOOLS_DREP_SOURCE='Local node'
rows="$(cntools_governance_status_rows)"
[[ "${rows}" == *'Deposit: 500.000000 ADA'* && "${rows}" == *'Ledger expiry epoch: 42'* &&
   "${rows}" == *'Activity: Unavailable from local state'* && "${rows}" == *'Metadata URL: https://example.invalid/drep.json'* ]] || fail 'local status rows'
jq -n --arg id "${id}" --arg hash "${hash}" '[{drep_id:$id,hex:$hash,has_script:false,drep_status:"registered",active:true,
  deposit:"500000000",expires_epoch_no:1234,amount:"1000000000",live_delegator_count:1234,meta_url:null,meta_hash:null}]' > "${response}"
cntools_drep_parse_koios "${response}" "${id}" key "${hash}"
CNTOOLS_DREP_SOURCE='Koios API'
rows="$(cntools_governance_status_rows)"
[[ "${rows}" == *'Activity: Active'* && "${rows}" == *'Delegators: 1,234'* && "${rows}" != *'Metadata URL'* ]] || fail 'Koios status rows'

(
  calls=0 local_result=0 koios_result=0
  CNTOOLS_DREP_KEY_ID="${id}" CNTOOLS_DREP_KEY_KIND=key CNTOOLS_DREP_KEY_HASH="${hash}"
  cntools_drep_query() {
    calls=$((calls+1))
    CNTOOLS_DREP_SOURCE="$4" CNTOOLS_DREP_STATUS=registered CNTOOLS_DREP_ACTIVE=true CNTOOLS_DREP_DETAILS='{}'
    if [[ "$4" == local ]]; then return "${local_result}"; fi
    if ((koios_result == 4)); then CNTOOLS_DREP_STATUS=not_registered; fi
    return "${koios_result}"
  }
  CNTOOLS_MODE=offline CNTOOLS_LOCAL_CLI_CAPABLE=true CNTOOLS_KOIOS_ENABLED=Y
  cntools_governance_status_collect
  eq "${calls}" 0 'offline must not query'; eq "${CNTOOLS_DREP_STATUS}" unknown
  CNTOOLS_MODE=local
  cntools_governance_status_collect
  eq "${calls}" 1 'prefer local'; eq "${CNTOOLS_DREP_SOURCE}" local
  local_result=1
  cntools_governance_status_collect
  eq "${calls}" 3 'Koios fallback'; eq "${CNTOOLS_DREP_SOURCE}" koios
  CNTOOLS_MODE=light koios_result=4
  cntools_governance_status_collect
  eq "${CNTOOLS_DREP_STATUS}" not_registered
  koios_result=1
  cntools_governance_status_collect
  eq "${CNTOOLS_DREP_STATUS}" unknown 'query failure is not unregistered'
  eq "${CNTOOLS_DREP_SOURCE}" Unavailable
  CNTOOLS_KOIOS_ENABLED=N
  cntools_governance_status_collect
  eq "${calls}" 5 'disabled Koios must not query'
)

# Cancellation at each prompt must never create keys. Both modes use the
# same confirmation and mnemonic inputs keep the governance breadcrumb.
(
  created=0 input_calls=0 scenario=method-cancel
  cntools_governance_wallet_select_into() { printf -v "$1" '%s' /wallet/example; }
  cntools_drep_key_preflight() { :; }
  cntools_ui_render_status() { :; }
  cntools_ui_action_begin() { :; }
  cntools_ui_wait() { :; }
  cntools_ui_table() { cat >/dev/null; }
  cntools_transaction_ui_table_widths_into() { printf -v "$1" '%s' 20,80; }
  cntools_ui_choose() {
    if [[ "${scenario}" == method-cancel ]]; then printf -v "$1" '%s' Cancel
    else printf -v "$1" '%s' 'Derive from recovery phrase'; fi
  }
  cntools_wallet_mnemonic_prompt_index_into() { [[ "${scenario}" != account-cancel ]] || return 1; printf -v "$1" '%s' 0; }
  cntools_ui_confirm() { eq "$2" false 'default No'; [[ "${scenario}" != confirm-cancel ]]; }
  cntools_wallet_mnemonic_collect_import_into() {
    input_calls=$((input_calls+1))
    eq "${CNTOOLS_MNEMONIC_INPUT_PATH}" '/ Vote / Governance / Derive Keys'
    return 1
  }
  cntools_drep_key_create() { created=$((created+1)); }
  for scenario in method-cancel account-cancel confirm-cancel phrase-cancel; do
    status=0; cntools_governance_action_keys || status=$?
    eq "${status}" 1 "cancel ${scenario}"
  done
  eq "${created}" 0 'cancel created keys'; eq "${input_calls}" 1 'phrase requested before confirmation'
)
printf 'CNTools governance wallet UI/status tests passed.\n'
