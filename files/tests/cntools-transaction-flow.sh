#!/usr/bin/env bash
# Shared review contract and stake registration/de-registration orchestration.
# No real keys, network requests, signing or submission.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-tx-flow.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number transaction-ui wallet-register wallet-register-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: $1 != $2"; }
printf '{"intent":{"summary":{"technicalFixture":true}}}' > "${TEST_ROOT}/package.json"
TRACE="${TEST_ROOT}/trace" TABLE="${TEST_ROOT}/table" LOG="${TEST_ROOT}/log"
cntools_transaction_log() { printf '%s %s\n' "$1" "$2" >> "${LOG}"; }
cntools_ui_action_begin() { :; }
cntools_ui_render_detail() { printf 'heading:%s\n' "$1" >> "${TABLE}"; }
cntools_ui_render_status() { printf 'status:%s:%s\n' "$1" "$2" >> "${TABLE}"; }
cntools_ui_content_width() { printf 140; }
cntools_theme_style_value_into() { printf -v "$1" '%s' "$3"; }
cntools_ui_table() { cat >> "${TABLE}"; }
cntools_ui_wait() { :; }
cntools_gum_clear() { :; }
cntools_ui_input() { fail 'unnecessary path / detail input'; }
cntools_transaction_clear_error() { CNTOOLS_TRANSACTION_ERROR=''; }
cntools_transaction_require_cli() { :; }
cntools_wallet_catalog_build() { CNTOOLS_WALLET_NAMES=(Test); CNTOOLS_WALLET_PATHS=(/wallet); }
cntools_wallet_choose() { printf -v "$1" '%s' 0; }
cntools_wallet_register_prepare_wallet() {
  CNTOOLS_WALLET_REGISTER_WALLET=Test
  CNTOOLS_WALLET_REGISTER_CAN_SIGN="${SIGNABLE}"
  CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS=stake_test1fixture
}
cntools_wallet_register_collect() { printf 'collect\n' >> "${TRACE}"; return "${COLLECT_STATUS}"; }
cntools_wallet_register_build_package_into() { printf 'build\n' >> "${TRACE}"; printf -v "$1" '%s' "${TEST_ROOT}/package.json"; }
cntools_wallet_format_lovelace() { printf '%s ADA' "$(cntools_number_format_units "$1" 6)"; }
cntools_transaction_package_load() {
  CNTOOLS_TRANSACTION_PACKAGE_FILE="$1"
  CNTOOLS_TRANSACTION_BODY_FILE=/body
  CNTOOLS_TRANSACTION_ID=fixture-id
  CNTOOLS_TRANSACTION_COMPLETE=Y
  CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER=''
}
cntools_transaction_view_into() { printf -v "$1" '%s' '{"fee":"185081 Lovelace","outputs":[]}'; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_transaction_ui_render_json() { printf 'decoded\n' >> "${TRACE}"; }
cntools_transaction_ui_render_signer_progress() { printf 'signers\n' >> "${TRACE}"; }
cntools_transaction_ui_render_native_scripts() { printf 'scripts\n' >> "${TRACE}"; }
cntools_transaction_ui_render_change_plan() { printf 'changes\n' >> "${TRACE}"; }
cntools_transaction_signed_path_into() { printf -v "$1" '%s' /temporary-signed; }
cntools_transaction_sign_registered() { printf 'sign\n' >> "${TRACE}"; return "${SIGN_STATUS}"; }
cntools_transaction_save_into() { printf 'save:%s\n' "$3" >> "${TRACE}"; printf -v "$1" '%s' "/saved/$3.json"; }
cntools_transaction_submit_input_prepare() {
  eq "$1" /saved/signed.json 'submission uses durable package'
  CNTOOLS_TRANSACTION_SIGNED_FILE=/body
  CNTOOLS_TRANSACTION_SUBMIT_ID=fixture-id
}
cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' local; }
cntools_ui_confirm() {
  eq "$1" 'Submit this signed transaction using local node?' 'common submission question'
  eq "$2" true 'yes default'
  printf 'confirm\n' >> "${TRACE}"
  return "${CONFIRM_STATUS}"
}
cntools_transaction_ui_submit_selected() { printf 'submit\n' >> "${TRACE}"; return "${SUBMIT_STATUS}"; }
cntools_transaction_ui_offer_monitor() { printf 'monitor\n' >> "${TRACE}"; }
cntools_ui_choose() {
  local answer="$3"
  if [[ "$2" == Workflow ]]; then
    if [[ "${SIGNABLE}" == Y ]]; then eq "$3" 'Create, sign and submit' 'live first'
    else eq "$3" 'Create unsigned package' 'unsigned only'; fi
    eq "${*: -1}" Cancel 'cancellation available'
    answer="${WORKFLOW}"
  else
    eq "$2" 'Review transaction' 'shared review title'
    case "${SCENARIO}:${STEP}" in
      details:0) answer='Show decoded transaction' ;;
      details:1) answer='Show required signers' ;;
      details:2) answer='Show transaction details' ;;
      switch:0) answer='Change workflow'; WORKFLOW='Create unsigned package' ;;
      cancel:*) answer=Cancel ;;
    esac
    STEP=$((STEP+1))
  fi
  printf -v "$1" '%s' "${answer}"
}
for operation in register deregister; do
  for scenario in live unsigned protected signed cancel decline sign-failure submit-failure details switch rewards; do
    (
      : > "${TRACE}"; : > "${TABLE}"; : > "${LOG}"
      SIGNABLE=Y WORKFLOW='Create, sign and submit' SCENARIO="${scenario}" STEP=0
      COLLECT_STATUS=0 SIGN_STATUS=0 CONFIRM_STATUS=0 SUBMIT_STATUS=0
      CNTOOLS_LOG="${LOG}" CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=Accepted
      CNTOOLS_TRANSACTION_ERROR=''
      CNTOOLS_TX_SELECTION_STRATEGY=balanced
      CNTOOLS_CHANGE_TOKEN_STATUS=Disabled CNTOOLS_CHANGE_UTXO_STATUS=Disabled CNTOOLS_CHANGE_COLLATERAL_STATUS=Disabled
      CNTOOLS_WALLET_REGISTER_INPUTS=(input)
      cntools_wallet_register_operation_set "${operation}"
      CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000
      case "${scenario}" in
        unsigned) WORKFLOW='Create unsigned package' ;;
        protected) WORKFLOW='Create unsigned package'; SIGNABLE=N ;;
        signed) WORKFLOW='Create and sign' ;;
        decline) CONFIRM_STATUS=1 ;;
        sign-failure) SIGN_STATUS=1 ;;
        submit-failure) SUBMIT_STATUS=1; CNTOOLS_TRANSACTION_ERROR='Rejected fixture' ;;
        rewards) COLLECT_STATUS=8 ;;
      esac
      status=0; cntools_wallet_register_workflow || status=$?
      if [[ "${scenario}" != details ]] && grep -Eq '^(decoded|signers|scripts|changes)$' "${TRACE}"; then fail 'technical details dumped'; fi
      if grep -Eq 'technicalFixture|Fee safety ceiling|Required witnesses|Chain data' "${TABLE}"; then fail 'technical clutter in compact view'; fi
      if [[ "${scenario}" == rewards ]]; then
        eq "${status}" 2 'rewards rejected'
        if grep -q build "${TRACE}"; then fail 'built despite guard'; fi
        exit 0
      fi
      grep -q 'Fee.*0.185081 ADA' "${TABLE}" || fail 'actual fee absent'
      grep -q 'Input selection.*balanced' "${TABLE}" || fail 'active policy absent'
      [[ "${operation}" != deregister ]] || grep -q 'will be forfeited' "${TABLE}" || fail 'forfeiture warning hidden'
      case "${scenario}" in
        unsigned|protected|switch)
          eq "${status}" 0 'unsigned success'; grep -qx save:unsigned "${TRACE}" || fail 'unsigned not saved'
          if grep -qx sign "${TRACE}"; then fail 'unsigned flow signed'; fi ;;
        cancel) eq "${status}" 1 'cancel'; if grep -Eq '^(sign|submit|save:)' "${TRACE}"; then fail 'cancel had side effect'; fi ;;
        sign-failure) eq "${status}" 2 'sign failure'; if grep -qx submit "${TRACE}"; then fail 'submitted without signatures'; fi ;;
        *)
          grep -qx sign "${TRACE}" || fail 'signing missing'
          grep -qx save:signed "${TRACE}" || fail 'signed package not kept'
          if [[ "${scenario}" == signed || "${scenario}" == decline ]]; then
            eq "${status}" 0 'retained signed package'
            grep -q /saved/signed.json "${TABLE}" || fail 'saved path not shown'
            if grep -qx submit "${TRACE}"; then fail 'unexpected submission'; fi
          elif [[ "${scenario}" == submit-failure ]]; then
            eq "${status}" 2 'submit failure'; grep -q /saved/signed.json "${TABLE}" || fail 'failed-submit path missing'
            if grep -qx monitor "${TRACE}"; then fail 'monitored rejected submission'; fi
          else
            eq "${status}" 0 'live success'; grep -qx monitor "${TRACE}" || fail 'monitor missing'
          fi ;;
      esac
      if [[ "${scenario}" == details ]]; then
        for event in decoded signers scripts changes; do grep -qx "${event}" "${TRACE}" || fail "missing ${event} option"; done
        eq "$(grep -c '^build$' "${TRACE}")" 1 'inspection rebuilt transaction'
      fi
      grep -q 'technicalFixture' "${LOG}" || fail 'technical intent not logged'
    )
  done
done
eq "$(cntools_number_format_units 9007199254740993 6)" '9,007,199,254.740993' 'exact ADA formatting'
printf 'CNTools shared transaction flow tests passed.\n'
