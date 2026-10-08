#!/usr/bin/env bash
# Node/device-free retirement interaction and shared pool finish regressions.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
for lib in transaction-ui pool-registration-ui pool-retirement-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$1 != $2"; }
cntools_transaction_log() { :; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_pool_registration_begin() { :; }
cntools_ui_render_status() { :; }
cntools_transaction_require_cli() { :; }
cntools_pool_catalog_build() { :; }
cntools_pool_registration_choose_eligible_into() { printf -v "$1" '%s' 1; }
cntools_pool_registration_prepare_identity() { eq "$1" 1; }
cntools_wallet_catalog_build() { :; }
cntools_wallet_choose() { printf -v "$1" '%s' 0; }
cntools_pool_registration_prepare_funding() { eq "$1" /funding; }
cntools_pool_registration_collect() { :; }
cntools_pool_registration_can_sign_into() { printf -v "$1" '%s' Y; }
cntools_transaction_ui_expiry_into() { printf -v "$1" '%s' 0; }
cntools_pool_registration_hardware_choice() { :; }
CNTOOLS_WALLET_NAMES=(Funding) CNTOOLS_WALLET_PATHS=(/funding)
# Editing an epoch or workflow returns to the same reviewed transaction flow.
(
  epoch_choices=0 builds=0 reviews=0 workflow_choices=0
  cntools_pool_retirement_select_epoch() { epoch_choices=$((epoch_choices+1)); }
  cntools_transaction_ui_workflow_into() { workflow_choices=$((workflow_choices+1)); printf -v "$1" '%s' 'Create and sign'; }
  cntools_pool_registration_build_into() { builds=$((builds+1)); printf -v "$1" '%s' /staged; }
  cntools_transaction_ui_review_into() {
    [[ "$*" == *'Change retirement epoch'* && "$*" == *'Change workflow'* ]] || fail 'missing review choices'
    reviews=$((reviews+1))
    case "${reviews}" in 1) printf -v "$1" '%s' 'Change retirement epoch' ;; 2) printf -v "$1" '%s' 'Change workflow' ;; *) printf -v "$1" '%s' "$3" ;; esac
  }
  cntools_pool_transaction_finish() { eq "$1" /staged; eq "$2" 'Create and sign'; }
  cntools_pool_retirement_workflow
  eq "${epoch_choices}" 2; eq "${builds}" 3; eq "${workflow_choices}" 2
)
(
  cntools_pool_retirement_select_epoch() { return 1; }
  cntools_pool_registration_build_into() { fail 'build after cancellation'; }
  status=0; cntools_pool_retirement_workflow || status=$?; eq "${status}" 1
)
# Common finish: exports, live, declined submit, failed submit and pre-sign recheck.
for test_case in unsigned sign live declined failed stale; do
  (
    rechecks=0 signatures=0 monitors=0 confirm_status=0 submit_status=0
    CNTOOLS_POOL_REG_RESULT_SHOWN=N CNTOOLS_WALLET_REGISTER_FILE_SUFFIX=pool-retire
    CNTOOLS_TRANSACTION_ID=txid CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=Accepted
    CNTOOLS_WALLET_REGISTER_ERROR='' CNTOOLS_TRANSACTION_ERROR=''
    cntools_pool_registration_recheck() { rechecks=$((rechecks+1)); [[ "${test_case}" != stale ]]; }
    cntools_transaction_signed_path_into() { printf -v "$1" '%s' /signed; }
    cntools_transaction_sign_registered() { signatures=$((signatures+1)); eq "$1" /staged; eq "$2" /signed; }
    cntools_transaction_package_load() { CNTOOLS_TRANSACTION_COMPLETE=Y; }
    cntools_transaction_save_into() { printf -v "$1" '%s' "/saved-$3"; }
    cntools_transaction_submit_input_prepare() { eq "$1" /saved-signed; CNTOOLS_TRANSACTION_SIGNED_FILE=/body; CNTOOLS_TRANSACTION_SUBMIT_ID=txid; }
    cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' local; }
    cntools_transaction_ui_confirm_submit() { return "${confirm_status}"; }
    cntools_transaction_ui_submit_selected() { eq "$1" local; eq "$2" /body; eq "$3" txid; return "${submit_status}"; }
    cntools_transaction_ui_render_result() { result_state="$1" result_message="$2" result_path="${4:-}"; }
    cntools_transaction_ui_offer_monitor() { monitors=$((monitors+1)); }
    workflow='Create, sign and submit'
    case "${test_case}" in unsigned) workflow='Create unsigned package' ;; sign) workflow='Create and sign' ;; declined) confirm_status=1 ;; failed) submit_status=2 ;; esac
    status=0; cntools_pool_transaction_finish /staged "${workflow}" || status=$?
    case "${test_case}" in
      unsigned) eq "${status}" 0; eq "${signatures}" 0; eq "${result_path}" /saved-unsigned ;;
      sign) eq "${status}" 0; eq "${signatures}" 1; eq "${result_path}" /saved-signed ;;
      live) eq "${status}" 0; eq "${rechecks}" 2; eq "${monitors}" 1 ;;
      declined) eq "${status}" 0; eq "${result_state}" warning; eq "${result_path}" /saved-signed; eq "${monitors}" 0 ;;
      failed) eq "${status}" 2; eq "${result_state}" danger; eq "${result_path}" /saved-signed; eq "${monitors}" 0 ;;
      stale) eq "${status}" 2; eq "${signatures}" 0 ;;
    esac
  )
done
printf 'CNTools pool retirement interaction tests passed.\n'
