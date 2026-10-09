#!/usr/bin/env bash
# Guided mint/burn orchestration, cancellation and retained offline packages.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-asset-ui.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
while IFS= read -r lib; do . "${CNTOOLS_ROOT}/lib/${lib}"; done < <(jq -r '.libs[]' "${CNTOOLS_ROOT}/modules/root/advanced/asset/mint/module.json")
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_ui_action_begin() { printf 'CLEAR %s\n' "$1"; }
cntools_ui_render_status() { printf '%s\n' "$2"; }
cntools_ui_wait() { :; }
cntools_table_render() { printf '%s\n' "$1"; cat; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_ui_confirm() { return 1; }
cntools_ui_input() { printf -v "$1" '%s' 3; }
cntools_policy_selection_into() { printf -v "$1" '%s' 0; }
cntools_policy_prepare() { CNTOOLS_POLICY_SELECTED_SOURCE=policy.skey; }
cntools_policy_asset_catalog() { :; }
cntools_policy_asset_choose_into() { printf -v "$1" '%s' "${policy}.01"; }
cntools_wallet_catalog_build() { :; }
cntools_wallet_choose() { printf -v "$1" '%s' 0; }
cntools_send_prepare_wallet() { CNTOOLS_SEND_SOURCE=payment.skey; CNTOOLS_SEND_TYPE=CLI; }
cntools_funding_collect() { CNTOOLS_FUNDING_TOTAL=30000000; CNTOOLS_FUNDING_ASSET_IDS=("${policy}.01"); CNTOOLS_FUNDING_ASSETS["${policy}.01"]=10; }
cntools_asset_tx_eligible_inventory() { :; }
cntools_asset_tx_burn_choose() { CNTOOLS_ASSET_TX_ID="${policy}.01"; }
cntools_transaction_ui_workflow_into() { printf -v "$1" '%s' "${WORKFLOW}"; }
cntools_transaction_ui_expiry_into() { printf -v "$1" '%s' 0; }
cntools_asset_tx_refresh_build_into() { printf -v "$1" '%s' "${TEST_ROOT}/staged"; printf '{}\n' > "${TEST_ROOT}/staged"; }
cntools_transaction_ui_proceed_into() { printf -v "$1" '%s' Continue; }
cntools_transaction_ui_review_into() { printf -v "$1" '%s' "${REVIEW}"; }
cntools_transaction_signed_path_into() { printf -v "$1" '%s' "${TEST_ROOT}/signed"; }
cntools_asset_tx_recheck() { printf 'recheck\n' >> "${TEST_ROOT}/events"; }
cntools_transaction_sign_registered() { printf 'sign\n' >> "${TEST_ROOT}/events"; cp "$1" "$2"; }
cntools_transaction_package_load() { CNTOOLS_TRANSACTION_COMPLETE=Y; CNTOOLS_TRANSACTION_ID="${txid}"; }
cntools_transaction_save_into() { printf -v "$1" '%s' "${TEST_ROOT}/${CASE}-${3}.json"; cp "$2" "${TEST_ROOT}/${CASE}-${3}.json"; }
cntools_transaction_submit_input_prepare() { CNTOOLS_TRANSACTION_SIGNED_FILE="$1"; CNTOOLS_TRANSACTION_SUBMIT_ID="${txid}"; }
cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' local; }
cntools_transaction_ui_confirm_submit() { return 0; }
cntools_transaction_ui_submit_selected() { printf 'submit\n' >> "${TEST_ROOT}/events"; [[ "${CASE}" != failed-submit ]] || return 2; CNTOOLS_TRANSACTION_SUBMIT_MESSAGE='Accepted by local node'; }
cntools_transaction_ui_render_result() { printf 'RESULT %s\n' "$*"; }
cntools_transaction_ui_offer_monitor() { printf 'monitor\n' >> "${TEST_ROOT}/events"; }
cntools_policy_asset_remember() { printf 'record %s\n' "$6" >> "${TEST_ROOT}/events"; }
CNTOOLS_LOG="${TEST_ROOT}/log" CNTOOLS_NETWORK=preview
policy="$(printf 'ab%.0s' {1..28})" txid="$(printf 'cd%.0s' {1..32})"
CNTOOLS_POLICY_PATHS=("${TEST_ROOT}/Policy") CNTOOLS_WALLET_PATHS=("${TEST_ROOT}/Wallet")
CNTOOLS_SEND_WALLET=Wallet CNTOOLS_SEND_ADDRESS=address CNTOOLS_SEND_PAYMENT=payment
CNTOOLS_POLICY_ID="${policy}"
CNTOOLS_POLICY_SELECTED_BEFORE=''
for CASE in unsigned sign live failed-submit cancel; do
  : > "${TEST_ROOT}/events"; REVIEW=Continue; WORKFLOW='Create, sign and submit'
  [[ "${CASE}" != unsigned ]] || WORKFLOW='Create unsigned package'
  [[ "${CASE}" != sign ]] || WORKFLOW='Create and sign'
  if [[ "${CASE}" == cancel ]]; then
    cntools_policy_selection_into() { return 1; }
  fi
  status=0; cntools_asset_tx_action mint > "${TEST_ROOT}/result" || status=$?
  case "${CASE}" in
    unsigned)
      [[ -f "${TEST_ROOT}/${CASE}-unsigned.json" ]] || fail 'unsigned package not saved'
      ! grep -qE '^(sign|submit)$' "${TEST_ROOT}/events" || fail 'unsigned workflow signed/submitted' ;;
    sign)
      [[ -f "${TEST_ROOT}/${CASE}-signed.json" ]] || fail 'signed package not saved'
      ! grep -q '^submit$' "${TEST_ROOT}/events" || fail 'sign-only submitted' ;;
    live) { grep -q '^submit$' "${TEST_ROOT}/events" && grep -q '^monitor$' "${TEST_ROOT}/events"; } || fail 'live workflow' ;;
    failed-submit) [[ "${status}" == 1 && -f "${TEST_ROOT}/${CASE}-signed.json" ]] || fail 'failure lost signed package' ;;
    cancel) [[ "${status}" == 0 && ! -s "${TEST_ROOT}/events" ]] || fail 'cancellation mutated state' ;;
  esac
done
printf 'Asset transaction interaction tests passed\n'
