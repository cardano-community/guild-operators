#!/usr/bin/env bash
# Shared fee-only metadata interaction contracts; no real keys or submissions.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/metadata-transaction-ui.sh"
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/transaction-ui.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for scenario in unsigned sign live decline failed stale-before-sign stale-before-submit cancel expiry workflow; do
  (
    CNTOOLS_SEND_SOURCE=/wallet/payment.skey CNTOOLS_SEND_DIRECTORY=/wallet CNTOOLS_SEND_WALLET=Example
    CNTOOLS_SEND_ADDRESS=base CNTOOLS_SEND_PAYMENT=payment CNTOOLS_SEND_CREDENTIAL=credential
    CNTOOLS_TRANSACTION_COMPLETE=Y CNTOOLS_TRANSACTION_ID=txid CNTOOLS_TRANSACTION_SUBMIT_ID=txid
    CNTOOLS_TRANSACTION_SIGNED_FILE=/private/signed.body CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=Accepted
    CNTOOLS_TRANSACTION_ERROR='' CNTOOLS_SEND_EXPIRY=''
    CNTOOLS_PAYMENT_ADDRESS=base CNTOOLS_PAYMENT_CREDENTIAL=credential CNTOOLS_FUNDING_SLOT=123
    CNTOOLS_COIN_SELECTED_REFS=(input); declare -A CNTOOLS_UTXO_INDEX_BY_REF=([input]=0)
    builds=0 reviews=0 rechecks=0 signs=0 saves=0 submits=0 monitors=0 workflows=0 result=''
    cntools_ui_spin_function() { shift; "$@"; }
    cntools_transaction_log() { :; }
    begin() { :; }
    identity() { :; }
    cntools_transaction_snapshot_into() { [[ "$2" == /public/metadata.json ]] || fail 'wrong metadata source'; printf -v "$1" '%s' /private/frozen-metadata.json; }
    recheck() {
      [[ "$1" == /private/frozen-metadata.json ]] || fail 'authorization and body must share a frozen metadata source'
      rechecks=$((rechecks+1))
      [[ "${scenario}" != stale-before-sign || "${rechecks}" != 2 ]] || return 1
      [[ "${scenario}" != stale-before-submit || "${rechecks}" != 3 ]] || return 1
    }
    cntools_ui_choose() {
      [[ "$2" == Workflow && "$3" == 'Create, sign and submit' ]] || fail 'live workflow not first'
      workflows=$((workflows+1))
      [[ "${scenario}" != cancel ]] || return 1
      case "${scenario}" in
        unsigned) printf -v "$1" '%s' 'Create unsigned package' ;;
        sign) printf -v "$1" '%s' 'Create and sign' ;;
        *) printf -v "$1" '%s' 'Create, sign and submit' ;;
      esac
    }
    cntools_transaction_ui_expiry_into() { printf -v "$1" '%s' 0; }
    cntools_transaction_expiry_into() { [[ "$3" == 0 ]] || fail 'No expiry lost'; printf -v "$1" '%s' ''; }
    cntools_funding_collect() { [[ "$1" == base && "$2" == payment ]] || fail 'wrong funding addresses'; }
    cntools_payment_prepare_wallet() { [[ "$1" == /wallet ]] || fail 'wrong funding wallet'; }
    cntools_metadata_transaction_build_into() {
      [[ "$2" == 'Register for Catalyst' && "$5" == /private/frozen-metadata.json ]] || fail 'wrong metadata intent'
      builds=$((builds+1)); printf -v "$1" '%s' /private/unsigned.json
    }
    cntools_transaction_ui_review_into() {
      [[ "$4" == begin && "$5" == cntools_metadata_transaction_render_review && "$*" == *'Change expiry'* && "$*" == *'Change workflow'* ]] || fail 'review contract'
      reviews=$((reviews+1))
      if [[ "${scenario}" == expiry && "${reviews}" == 1 ]]; then printf -v "$1" '%s' 'Change expiry'
      elif [[ "${scenario}" == workflow && "${reviews}" == 1 ]]; then printf -v "$1" '%s' 'Change workflow'
      else printf -v "$1" '%s' "$3"; fi
    }
    cntools_transaction_signed_path_into() { printf -v "$1" '%s' /private/signed.json; }
    cntools_transaction_sign_registered() { signs=$((signs+1)); }
    cntools_transaction_package_load() { :; }
    cntools_transaction_save_into() { [[ "$4" == catalyst-register ]] || fail 'wrong export label'; saves=$((saves+1)); printf -v "$1" '%s' "/saved/$3.json"; }
    cntools_transaction_submit_input_prepare() { :; }
    cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' local; }
    cntools_transaction_ui_confirm_submit() { [[ "${scenario}" != decline ]]; }
    cntools_transaction_ui_submit_selected() { submits=$((submits+1)); [[ "${scenario}" != failed ]]; }
    cntools_transaction_ui_render_result() { result="$1|$2|${4:-}"; }
    cntools_transaction_ui_offer_monitor() { monitors=$((monitors+1)); }
    status=0
    cntools_metadata_transaction_workflow catalyst-register 'Register for Catalyst' description '{}' /public/metadata.json begin identity recheck || status=$?
    case "${scenario}" in
      cancel) [[ "${status}" == 1 && "${builds}" == 0 && "${saves}" == 0 ]] || fail 'cancel continued' ;;
      unsigned) [[ "${status}" == 0 && "${signs}" == 0 && "${submits}" == 0 && "${result}" == *'/saved/unsigned.json'* ]] || fail 'unsigned flow' ;;
      sign|decline) [[ "${status}" == 0 && "${signs}" == 1 && "${submits}" == 0 && "${result}" == *'/saved/signed.json'* ]] || fail 'signed package not retained' ;;
      stale-before-sign) [[ "${status}" == 2 && "${signs}" == 0 && "${submits}" == 0 ]] || fail 'signed stale authorization' ;;
      stale-before-submit) [[ "${status}" == 2 && "${signs}" == 1 && "${submits}" == 0 && "${result}" == *'/saved/signed.json'* ]] || fail 'stale submission or lost package' ;;
      failed) [[ "${status}" == 2 && "${submits}" == 1 && "${result}" == *'/saved/signed.json'* ]] || fail 'failed submission lost package' ;;
      *) [[ "${status}" == 0 && "${signs}" == 1 && "${submits}" == 1 && "${monitors}" == 1 ]] || fail 'live flow' ;;
    esac
    [[ "${scenario}" != expiry || "${builds}" == 2 ]] || fail 'expiry change did not rebuild'
    [[ "${scenario}" != workflow || "${workflows}" == 2 ]] || fail 'workflow change ignored'
  )
done
printf 'CNTools shared metadata transaction interaction tests passed\n'
