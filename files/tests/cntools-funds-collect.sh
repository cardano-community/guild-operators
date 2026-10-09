#!/usr/bin/env bash
# Collection eligibility, conservation guards and UI workflows; no real funds.
# shellcheck disable=SC1090,SC2034,SC2154,SC2218,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-collect.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in transaction-ui number utxo coin-selection change-plan wallet-payment funds-send funds-collect funds-collect-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_transaction_log() { :; }
cntools_transaction_set_error() { CNTOOLS_TRANSACTION_ERROR="$1"; }
cntools_transaction_clear_error() { CNTOOLS_TRANSACTION_ERROR=""; }
CNTOOLS_SEND_ADDRESS=base CNTOOLS_SEND_PAYMENT=payment CNTOOLS_SEND_WALLET=Test
CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_UTXO_MANAGEMENT=N
ref="$(printf 'ab%.0s' {1..32})"; policy="$(printf 'cd%.0s' {1..28})"
cntools_utxo_reset
if cntools_collect_select; then fail 'empty inventory accepted'; fi
cntools_utxo_add "${ref}#0" base 3000000
if cntools_collect_select; then fail 'no-op collection accepted'; fi
cntools_utxo_add "${ref}#1" payment 4000000
cntools_utxo_add "${ref}#2" base 5000000
cntools_utxo_add_asset 2 "${policy}.01" 9007199254740993
cntools_utxo_add "${ref}#3" base 6000000 Y N
cntools_utxo_add "${ref}#4" base 7000000 N Y
cntools_collect_select || fail 'ADA collection selection'
eq "${#CNTOOLS_COLLECT_INPUTS[@]}" 2 'ADA inputs'
eq "${CNTOOLS_COLLECT_SKIPPED}" 3 'tokens and unsafe outputs untouched'
eq "${CNTOOLS_COIN_SELECTED_LOVELACE}" 7000000 'only selected balance'
CNTOOLS_COLLECT_SCOPE=all
cntools_collect_select || fail 'all collection selection'
eq "${#CNTOOLS_COLLECT_INPUTS[@]}" 3 'all ordinary inputs'
eq "${CNTOOLS_COIN_SELECTED_ASSETS[${policy}.01]}" 9007199254740993 'exact token units'
(
  cntools_utxo_reset
  cntools_utxo_add "${ref}#0" base 100000
  cntools_utxo_add "${ref}#1" base 100000
  CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
  cntools_transaction_calculate_min_utxo_into() { printf -v "$1" '%s' 1000000; }
  package=""
  if cntools_collect_build_into package; then fail 'insufficient minimum ADA accepted'; fi
  eq "${package}" '' 'failed collection must not publish a package'
)
(
  cntools_utxo_reset
  for ((index=0; index<=1000; index++)); do cntools_utxo_add "${ref}#${index}" base 2000000; done
  if cntools_collect_select; then fail 'oversized input inventory silently batched'; fi
  [[ "${CNTOOLS_TRANSACTION_ERROR}" == *1,000* ]] || fail 'input limit not explained'
)
(
  cntools_utxo_add "${ref}#5" foreign 10000000
  if cntools_collect_select; then fail 'foreign input accepted'; fi
)
(
  CNTOOLS_COLLECT_SCOPE=bad
  if cntools_collect_select; then fail 'unknown scope accepted'; fi
)
(
  CNTOOLS_COLLECT_FEE=1000
  original='{"fee":"1000 Lovelace","outputs":[{"address":"base"}]}'
  decoded="${original}"
  cntools_transaction_view_into() { printf -v "$1" '%s' "${decoded}"; }
  cntools_collect_validate_body fixture || fail 'valid body rejected'
  for change in '.fee="2000 Lovelace"' '.outputs[0].address="foreign"' '.certificates=[{}]' '.withdrawals=[{}]' '.mint={}' '.metadata={}'; do
    decoded="$(jq "${change}" <<< "${original}")"
    if cntools_collect_validate_body fixture; then fail "body mutation accepted: ${change}"; fi
  done
)
(
  CNTOOLS_SEND_TYPE=Hardware CNTOOLS_SEND_VKEY=pay.vkey CNTOOLS_SEND_SOURCE=pay.hws
  CNTOOLS_SEND_CREDENTIAL=payment CNTOOLS_SEND_DIRECTORY=/wallet
  CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hws
  CNTOOLS_SEND_EXPIRY=200 CNTOOLS_COLLECT_BACKEND=koios CNTOOLS_COLLECT_FEE=1000
  roles=(); changes=0
  cntools_transaction_plan_reset() { eq "$1" 'Collect UTxOs'; eq "$3" exact; }
  cntools_transaction_plan_add_signer() { roles+=("$2"); eq "$6" send-wallet; }
  cntools_transaction_plan_add_change_key() { changes=$((changes+1)); eq "$4" send-wallet; }
  cntools_transaction_plan_set_validity() { eq "$2" 200; }
  cntools_transaction_plan_set_summary() {
    jq -e '.action=="collect-utxos" and .transactionPolicy.selection=="collect-all-eligible"' <<< "$1" >/dev/null || fail 'wrong intent/policy'
  }
  cntools_change_policy_json() { printf '{}'; }
  cntools_collect_plan || fail 'hardware signer plan'
  eq "${roles[*]}" spending 'only payment witness'
  eq "${changes}" 2 'hardware base change references'
)
CNTOOLS_COLLECT_BACKEND=local CNTOOLS_SEND_EXPIRY=200 CNTOOLS_COLLECT_INPUTS=(reference)
SLOT=100 SPENT=N BACKEND=local
cntools_funding_collect() {
  CNTOOLS_FUNDING_BACKEND="${BACKEND}"; CNTOOLS_FUNDING_SLOT="${SLOT}"
  CNTOOLS_UTXO_INDEX_BY_REF=()
  [[ "${SPENT}" == Y ]] || CNTOOLS_UTXO_INDEX_BY_REF[reference]=0
}
cntools_collect_recheck || fail 'unchanged state rejected'
for problem in spent expired backend; do
  (
    case "${problem}" in spent) SPENT=Y ;; expired) SLOT=200 ;; backend) BACKEND=koios ;; esac
    if cntools_collect_recheck; then fail "unsafe recheck: ${problem}"; fi
  )
done
CNTOOLS_SEND_EXPIRY=""
SLOT=500
cntools_collect_recheck || fail 'No expiry rejected'
SPENT=Y
if cntools_collect_recheck; then fail 'No expiry bypassed input check'; fi

# Stub only the transaction engine below, retaining the complete UI workflow.
cntools_ui_action_begin() { :; }
cntools_ui_render_status() { :; }
cntools_ui_wait() { :; }
cntools_transaction_require_cli() { :; }
cntools_wallet_catalog_build() { CNTOOLS_WALLET_NAMES=(Test); CNTOOLS_WALLET_PATHS=(/wallet); }
cntools_wallet_choose() { printf -v "$1" '%s' 0; }
cntools_send_prepare_wallet() { CNTOOLS_SEND_SOURCE=""; [[ "${SIGNABLE}" != Y ]] || CNTOOLS_SEND_SOURCE=/key; return 0; }
cntools_ui_spin_function() { shift; "$@"; }
printf '{"intent":{"summary":{}}}' > "${TEST_ROOT}/staged.json"
cntools_collect_refresh_build_into() { printf -v "$1" '%s' "${TEST_ROOT}/staged.json"; }
cntools_transaction_view_into() { printf -v "$1" '%s' '{}'; }
cntools_collect_render() { :; }
cntools_transaction_ui_render_json() { fail 'unexpected decoded transaction dump'; }
cntools_transaction_ui_render_signer_progress() { fail 'unexpected signer dump'; }
cntools_transaction_signed_path_into() { printf -v "$1" '%s' /signed; }
cntools_transaction_sign_registered() { SIGNED=Y; }
cntools_transaction_package_load() { CNTOOLS_TRANSACTION_COMPLETE=Y; CNTOOLS_TRANSACTION_ID=txid; CNTOOLS_TRANSACTION_BODY_FILE=/body; CNTOOLS_TRANSACTION_PACKAGE_FILE="$1"; }
cntools_transaction_save_into() { printf -v "$1" '%s' "/saved/$3.json"; SAVED="$3"; }
cntools_transaction_submit_input_prepare() { eq "$1" /saved/signed.json 'use retained path after publication'; CNTOOLS_TRANSACTION_SIGNED_FILE=/signed-body; CNTOOLS_TRANSACTION_SUBMIT_ID=txid; }
cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' local; }
cntools_ui_confirm() { eq "$2" true 'submission default'; [[ "${CONFIRM}" == Y ]]; }
cntools_transaction_ui_submit_selected() { SUBMITTED=Y; [[ "${SUBMIT_FAIL}" != Y ]]; }
cntools_transaction_ui_offer_monitor() { MONITORED=Y; }
cntools_collect_result() { RESULT="$2"; RESULT_PATH="${4:-}"; CNTOOLS_COLLECT_RESULT_SHOWN=Y; }
cntools_collect_recheck() { RECHECKS=$((RECHECKS+1)); [[ "${RECHECK_FAIL}" != Y ]]; }
cntools_ui_choose() {
  local name="$1" prompt="$2" first="$3" answer=""
  case "${prompt}" in
    'Collect which UTxOs?') answer='ADA-only UTxOs'; [[ "${CANCEL_SCOPE:-N}" != Y ]] || answer=Cancel ;;
    Workflow)
      if [[ "${SIGNABLE}" == N ]]; then eq "$#" 4 'unsigned-only plus cancellation choices'; fi
      answer="${WORKFLOW}" ;;
    'Transaction expiry') answer='30 minutes' ;;
    'Review transaction')
      if [[ "${CANCEL}" == Y ]]; then answer=Cancel; else answer="${first}"; fi ;;
    *) fail "unexpected prompt ${prompt}" ;;
  esac
  printf -v "${name}" '%s' "${answer}"
}
for scenario in unsigned encrypted signed live cancel cancel-scope decline recheck-failed submit-failed; do
  (
    CANCEL_SCOPE=N; SIGNABLE=Y; WORKFLOW='Create, sign and submit'; CANCEL=N; CONFIRM=Y
    RECHECK_FAIL=N; SUBMIT_FAIL=N; SIGNED=N; SUBMITTED=N; MONITORED=N; SAVED=''; RECHECKS=0; RESULT_PATH=''
    CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=Accepted; CNTOOLS_TRANSACTION_ID=txid; CNTOOLS_TRANSACTION_ERROR=''
    case "${scenario}" in
      unsigned) WORKFLOW='Create unsigned package' ;;
      encrypted) WORKFLOW='Create unsigned package'; SIGNABLE=N ;;
      signed) WORKFLOW='Create and sign' ;;
      cancel-scope) CANCEL_SCOPE=Y ;;
      cancel) CANCEL=Y ;; decline) CONFIRM=N ;; recheck-failed) RECHECK_FAIL=Y ;; submit-failed) SUBMIT_FAIL=Y ;;
    esac
    status=0; cntools_collect_workflow || status=$?
    case "${scenario}" in
      unsigned|encrypted) eq "${status}" 0; eq "${SAVED}" unsigned; eq "${SIGNED}" N; eq "${SUBMITTED}" N ;;
      signed) eq "${status}" 0; eq "${SAVED}" signed; eq "${SIGNED}" Y; eq "${SUBMITTED}" N ;;
      live) eq "${status}" 0; eq "${SUBMITTED}" Y; eq "${MONITORED}" Y; eq "${RECHECKS}" 2 ;;
      cancel|cancel-scope) eq "${status}" 1; eq "${SIGNED}" N; eq "${SAVED}" '' ;;
      decline) eq "${status}" 0; eq "${SUBMITTED}" N; eq "${RESULT_PATH}" /saved/signed.json ;;
      recheck-failed) eq "${status}" 2; eq "${SIGNED}" N; eq "${SUBMITTED}" N ;;
      submit-failed) eq "${status}" 2; eq "${MONITORED}" N; eq "${RESULT_PATH}" /saved/signed.json ;;
    esac
  )
done
printf 'CNTools collection guards and workflow tests passed.\n'
