#!/usr/bin/env bash
# Reward/account guards and live/offline UI orchestration. No network or signing.
# shellcheck disable=SC1090,SC2034,SC2154,SC2218,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-withdraw.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in transaction-ui number utxo coin-selection change-plan wallet-stake funds-withdraw funds-withdraw-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_transaction_log() { :; }
cntools_transaction_set_error() { CNTOOLS_TRANSACTION_ERROR="$1"; }
cntools_transaction_clear_error() { CNTOOLS_TRANSACTION_ERROR=""; }
CNTOOLS_STAKE_BASE_ADDRESS=base
CNTOOLS_STAKE_PAYMENT_ADDRESS=payment
CNTOOLS_STAKE_REWARD_ADDRESS=stake
CNTOOLS_WITHDRAW_BACKEND=local
CNTOOLS_FUNDING_PROTOCOL="${TEST_ROOT}/protocol.json"
jq -n '{protocolVersion:{major:10}}' > "${CNTOOLS_FUNDING_PROTOCOL}"
REGISTERED=yes; REWARDS=12000000; DELEGATION=alwaysAbstain; QUERY_FAIL=N
cntools_wallet_query_reset() { CNTOOLS_WALLET_REGISTERED=''; CNTOOLS_WALLET_DREP_DELEGATION=''; CNTOOLS_WALLET_REWARD_LOVELACE=''; }
cntools_wallet_query_network_arguments() { :; }
cntools_wallet_query_local_stake() {
  [[ "${QUERY_FAIL}" != Y ]] || return 1
  CNTOOLS_WALLET_REGISTERED="${REGISTERED}"
  CNTOOLS_WALLET_DREP_DELEGATION="${DELEGATION}"
  CNTOOLS_WALLET_REWARD_LOVELACE="${REWARDS}"
}
cntools_wallet_query_koios_stake() { cntools_wallet_query_local_stake "$@"; }
for backend in local koios; do
  CNTOOLS_WITHDRAW_BACKEND="${backend}"
  cntools_withdraw_query_stake || fail "valid ${backend} rewards"
  for problem in unregistered empty malformed failed delegation; do
    (
      case "${problem}" in
        unregistered) REGISTERED=no ;; empty) REWARDS=0 ;; malformed) REWARDS=1e6 ;;
        failed) QUERY_FAIL=Y ;; delegation) DELEGATION='' ;;
      esac
      if cntools_withdraw_query_stake; then fail "accepted ${backend}/${problem}"; fi
      [[ -n "${CNTOOLS_TRANSACTION_ERROR}" ]] || fail 'guard error not recorded'
    )
  done
done
DELEGATION=''
jq -n '{protocolVersion:{major:9}}' > "${CNTOOLS_FUNDING_PROTOCOL}"
cntools_withdraw_query_stake || fail 'bootstrap wrongly requires delegation'
jq -n '{protocolVersion:{major:10}}' > "${CNTOOLS_FUNDING_PROTOCOL}"
DELEGATION=alwaysAbstain
cntools_coin_required_for_stake_into required withdraw 12000000 1000000
eq "${required}" 1 'rewards cover fee but still select an input'
cntools_coin_required_for_stake_into required withdraw 1 1000000
eq "${required}" 999999 'small rewards need wallet ADA'

(
  CNTOOLS_CLI=/cli; CNTOOLS_NETWORK=preview
  CNTOOLS_STAKE_PAYMENT_VKEY=pay.vkey; CNTOOLS_STAKE_STAKE_VKEY=stake.vkey
  cntools_transaction_network_arguments_into() { local -n target="$1"; target=(--testnet-magic 2); }
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_transaction_run_cli() {
    local destination="$1"
    if [[ "$*" == *'latest stake-address build'* ]]; then printf stake > "${destination}"
    elif [[ "$*" == *'--stake-verification-key-file'* ]]; then printf base > "${destination}"
    else printf payment > "${destination}"; fi
  }
  cntools_stake_verify_addresses || fail 'matching cached addresses rejected'
  for variable in CNTOOLS_STAKE_PAYMENT_ADDRESS CNTOOLS_STAKE_BASE_ADDRESS CNTOOLS_STAKE_REWARD_ADDRESS; do
    (
      printf -v "${variable}" '%s' foreign
      if cntools_stake_verify_addresses; then fail "stale address accepted: ${variable}"; fi
      eq "${!variable}" foreign 'verification must not rewrite cached addresses'
    )
  done
)

(
  CNTOOLS_WITHDRAW_REWARDS=1; CNTOOLS_TX_SELECTION_STRATEGY=balanced
  CNTOOLS_TX_TOKEN_FRAGMENTATION=N; CNTOOLS_TX_UTXO_MANAGEMENT=N
  CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
  cntools_transaction_calculate_min_utxo_into() { printf -v "$1" '%s' 1000000; }
  cntools_utxo_reset
  if cntools_withdraw_select; then fail 'empty inventory accepted'; fi
  cntools_utxo_add "$(printf 'aa%.0s' {1..32})#0" base 1000000
  if cntools_withdraw_select; then fail 'insufficient minimum ADA accepted'; fi
  cntools_utxo_add "$(printf 'bb%.0s' {1..32})#0" base 10000000
  cntools_withdraw_select || fail 'funded withdrawal rejected'
  eq "${#CNTOOLS_COIN_SELECTED_REFS[@]}" 1 'do not sweep every input'
  CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[1]=Y
  if cntools_withdraw_select; then fail 'reference-script input accepted without fee accounting'; fi
)

(
  CNTOOLS_STAKE_WALLET=Test; CNTOOLS_STAKE_WALLET_TYPE=Hardware
  CNTOOLS_STAKE_PAYMENT_VKEY=pay.vkey; CNTOOLS_STAKE_STAKE_VKEY=stake.vkey
  CNTOOLS_STAKE_PAYMENT_SOURCE=pay.hws; CNTOOLS_STAKE_STAKE_SOURCE=stake.hws
  CNTOOLS_STAKE_PAYMENT_CREDENTIAL=payment; CNTOOLS_STAKE_STAKE_CREDENTIAL=stake
  CNTOOLS_WITHDRAW_EXPIRY=200
  roles=(); changes=0
  cntools_transaction_plan_reset() { eq "$3" exact 'signing assurance'; }
  cntools_transaction_plan_add_signer() { roles+=("$2"); eq "$6" withdraw-wallet 'atomic hardware group'; }
  cntools_transaction_plan_add_change_key() { changes=$((changes+1)); eq "$4" withdraw-wallet 'hardware change group'; }
  cntools_transaction_plan_set_validity() { eq "$2" 200 'expiry binding'; }
  cntools_transaction_plan_set_summary() { :; }
  cntools_change_policy_json() { printf '{}'; }
  cntools_withdraw_plan
  eq "${roles[*]}" 'spending withdrawal' 'two distinct witness purposes'
  eq "${changes}" 2 'both base-address change references'
)

CNTOOLS_WITHDRAW_REWARDS=12000000; CNTOOLS_WITHDRAW_EXPIRY=200
CNTOOLS_WITHDRAW_INPUTS=(reference)
declare -A CNTOOLS_UTXO_INDEX_BY_REF=([reference]=0)
SLOT=100; SPENT=N
cntools_funding_collect() {
  CNTOOLS_FUNDING_BACKEND=local; CNTOOLS_FUNDING_SLOT="${SLOT}"
  CNTOOLS_UTXO_INDEX_BY_REF=()
  [[ "${SPENT}" == Y ]] || CNTOOLS_UTXO_INDEX_BY_REF[reference]=0
}
cntools_withdraw_recheck || fail 'unchanged chain state rejected'
for problem in new-rewards spent expired missing-account failed-query; do
  (
    case "${problem}" in
      new-rewards) REWARDS=13000000 ;; spent) SPENT=Y ;; expired) SLOT=200 ;;
      missing-account) REGISTERED=no ;; failed-query) QUERY_FAIL=Y ;;
    esac
    if cntools_withdraw_recheck; then fail "unsafe recheck ${problem}"; fi
  )
done

# Stub only the transaction engine below, retaining the complete UI workflow.
cntools_ui_action_begin() { :; }
cntools_ui_render_status() { :; }
cntools_ui_wait() { :; }
cntools_transaction_require_cli() { :; }
cntools_wallet_catalog_build() { CNTOOLS_WALLET_NAMES=(Test); CNTOOLS_WALLET_PATHS=(/wallet); }
cntools_wallet_choose() { printf -v "$1" '%s' 0; }
cntools_stake_prepare_wallet() { CNTOOLS_STAKE_CAN_SIGN="${SIGNABLE}"; }
cntools_ui_spin_function() { shift; "$@"; }
printf '{"intent":{"summary":{}}}' > "${TEST_ROOT}/staged.json"
cntools_withdraw_refresh_build_into() { printf -v "$1" '%s' "${TEST_ROOT}/staged.json"; }
cntools_transaction_view_into() { printf -v "$1" '%s' '{}'; }
cntools_withdraw_render() { :; }
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
cntools_withdraw_result() { RESULT="$2"; RESULT_PATH="${4:-}"; CNTOOLS_WITHDRAW_RESULT_SHOWN=Y; }
cntools_withdraw_recheck() { RECHECKS=$((RECHECKS+1)); [[ "${RECHECK_FAIL}" != Y ]]; }
cntools_ui_choose() {
  local name="$1" prompt="$2" first="$3" answer=""
  case "${prompt}" in
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
for scenario in unsigned encrypted signed live cancel decline recheck-failed submit-failed; do
  (
    SIGNABLE=Y; WORKFLOW='Create, sign and submit'; CANCEL=N; CONFIRM=Y
    RECHECK_FAIL=N; SUBMIT_FAIL=N; SIGNED=N; SUBMITTED=N; MONITORED=N; SAVED=''; RECHECKS=0; RESULT_PATH=''
    CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=Accepted; CNTOOLS_TRANSACTION_ID=txid; CNTOOLS_TRANSACTION_ERROR=''
    case "${scenario}" in
      unsigned) WORKFLOW='Create unsigned package' ;;
      encrypted) WORKFLOW='Create unsigned package'; SIGNABLE=N ;;
      signed) WORKFLOW='Create and sign' ;;
      cancel) CANCEL=Y ;; decline) CONFIRM=N ;; recheck-failed) RECHECK_FAIL=Y ;; submit-failed) SUBMIT_FAIL=Y ;;
    esac
    status=0; cntools_withdraw_workflow || status=$?
    case "${scenario}" in
      unsigned|encrypted) eq "${status}" 0; eq "${SAVED}" unsigned; eq "${SIGNED}" N; eq "${SUBMITTED}" N ;;
      signed) eq "${status}" 0; eq "${SAVED}" signed; eq "${SIGNED}" Y; eq "${SUBMITTED}" N ;;
      live) eq "${status}" 0; eq "${SUBMITTED}" Y; eq "${MONITORED}" Y; eq "${RECHECKS}" 2 ;;
      cancel) eq "${status}" 1; eq "${SIGNED}" N; eq "${SAVED}" '' ;;
      decline) eq "${status}" 0; eq "${SUBMITTED}" N; eq "${RESULT_PATH}" /saved/signed.json ;;
      recheck-failed) eq "${status}" 2; eq "${SIGNED}" N; eq "${SUBMITTED}" N ;;
      submit-failed) eq "${status}" 2; eq "${MONITORED}" N; eq "${RESULT_PATH}" /saved/signed.json ;;
    esac
  )
done
printf 'CNTools reward withdrawal guards and workflow tests passed.\n'
