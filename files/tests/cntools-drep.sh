#!/usr/bin/env bash
# Deterministic DRep lifecycle/state/anchor and stale-state guards. No network.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-drep-state.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query transaction utxo coin-selection change-plan wallet-register wallet-register-ui drep-query governance-drep governance-drep-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_log() { :; }
printf '[[{"keyHash":"fixture"},{"expiry":42,"deposit":9007199254740993}]]' > "${TEST_ROOT}/large-deposit.json"
cntools_drep_parse_local "${TEST_ROOT}/large-deposit.json" key fixture
eq "$(jq -r .deposit <<< "${CNTOOLS_DREP_DETAILS}")" 9007199254740993 'lossless local deposit'
printf '[{"drep_id":"drep1fixture","hex":"fixture","has_script":false,"drep_status":"registered","active":true,"deposit":9007199254740993}]' > "${TEST_ROOT}/large-koios-deposit.json"
cntools_drep_parse_koios "${TEST_ROOT}/large-koios-deposit.json" drep1fixture key fixture
eq "$(jq -r .deposit <<< "${CNTOOLS_DREP_DETAILS}")" 9007199254740993 'lossless Koios deposit'
CNTOOLS_DREP_LIFECYCLE_ID=drep1fixture CNTOOLS_DREP_LIFECYCLE_HASH=fixture
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=addr_test1fixture CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=addr_test1fixture
CNTOOLS_TX_SELECTION_STRATEGY=balanced
cntools_wallet_register_select_inputs() { SELECTED_DEPOSIT="${CNTOOLS_WALLET_REGISTER_DEPOSIT}"; }
cntools_funding_collect() {
  CNTOOLS_FUNDING_BACKEND="${TEST_BACKEND}" CNTOOLS_FUNDING_SLOT="${TEST_SLOT}"
  CNTOOLS_FUNDING_PROTOCOL="${TEST_ROOT}/protocol.json"
  cntools_utxo_reset
  if [[ "${SPENT}" != Y ]]; then cntools_utxo_add "${TEST_REFERENCE}" addr_test1fixture 600000000; fi
}
cntools_drep_query() {
  [[ "$4" == "${CNTOOLS_WALLET_REGISTER_BACKEND}" ]] || fail 'DRep queried different backend'
  CNTOOLS_DREP_STATUS="${TEST_STATUS}" CNTOOLS_DREP_DETAILS="${TEST_DETAILS}"
  return "${QUERY_STATUS}"
}
TEST_REFERENCE="$(printf 'ab%.0s' {1..32})#0"
TEST_BACKEND=koios TEST_SLOT=1000 SPENT=N QUERY_STATUS=4 TEST_STATUS=not_registered TEST_DETAILS='{}'
cp "${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json" "${TEST_ROOT}/protocol.json"
cntools_wallet_register_operation_set drep-register
cntools_wallet_register_collect
eq "${CNTOOLS_WALLET_REGISTER_OPERATION}" drep-register
eq "${SELECTED_DEPOSIT}" 500000000 'current protocol registration deposit'
cntools_drep_lifecycle_recheck || fail 'stable registration'
QUERY_STATUS=1
if cntools_drep_lifecycle_recheck; then fail 'API failure treated as unregistered'; fi
QUERY_STATUS=0 TEST_STATUS=registered TEST_DETAILS='{"deposit":"450000000","meta_url":null,"meta_hash":null}'
if cntools_drep_lifecycle_recheck; then fail 'already registered transaction not blocked'; fi
cntools_wallet_register_operation_set drep-register
cntools_wallet_register_collect
eq "${CNTOOLS_WALLET_REGISTER_OPERATION}" drep-update 'automatic update'
eq "${SELECTED_DEPOSIT}" 0 'update must not charge deposit'
cntools_drep_lifecycle_recheck || fail 'stable update'
for details in '{"deposit":"449999999","meta_url":null,"meta_hash":null}' '{"deposit":"450000000","meta_url":"https://example.invalid/x","meta_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'; do
  TEST_DETAILS="${details}"
  if cntools_drep_lifecycle_recheck; then fail 'changed deposit/anchor not blocked'; fi
done
TEST_DETAILS='{"deposit":"450000000","meta_url":null,"meta_hash":null}'
cntools_wallet_register_operation_set drep-retire
cntools_wallet_register_collect
eq "${SELECTED_DEPOSIT}" 450000000 'retirement uses recorded deposit, not current protocol'
cntools_drep_lifecycle_recheck || fail 'stable retirement'
SPENT=Y
if cntools_drep_lifecycle_recheck; then fail 'spent input accepted'; fi
SPENT=N TEST_BACKEND=local
if cntools_drep_lifecycle_recheck; then fail 'backend switch accepted'; fi
TEST_BACKEND=koios CNTOOLS_WALLET_REGISTER_EXPIRY=1000
if cntools_drep_lifecycle_recheck; then fail 'expired transaction accepted'; fi
CNTOOLS_WALLET_REGISTER_EXPIRY=''
cntools_drep_lifecycle_recheck || fail 'No expiry rejected'
TEST_DETAILS='{"deposit":"0","meta_url":null,"meta_hash":null}'
cntools_wallet_register_collect
eq "${SELECTED_DEPOSIT}" 0 'zero historical refund'
for details in '{"deposit":null}' '{"deposit":"-1"}' '{"deposit":"1e9"}' '{"deposit":9007199254740992}' '{"deposit":"500000000","meta_url":"https://x","meta_hash":null}'; do
  CNTOOLS_DREP_STATUS=registered CNTOOLS_DREP_DETAILS="${details}"
  if cntools_drep_lifecycle_state_into state; then fail 'malformed state accepted'; fi
done
QUERY_STATUS=4 TEST_STATUS=not_registered TEST_DETAILS='{}'
status=0; cntools_wallet_register_collect || status=$?
eq "${status}" 7 'retire unregistered guard'

hash="$(printf 'aa%.0s' {1..32})"
TEST_METADATA_HASH="${hash}"
cntools_drep_lifecycle_anchor_valid '' '' || fail 'optional anchor'
cntools_drep_lifecycle_anchor_valid https://example.invalid/drep.json "${hash}" || fail 'valid anchor'
for url in 'file:///etc/passwd' 'https://x y' $'https://x\n' "https://$(printf '%0125d' 0)"; do
  if cntools_drep_lifecycle_anchor_valid "${url}" "${hash}"; then fail 'invalid URL accepted'; fi
done
if cntools_drep_lifecycle_anchor_valid https://example.invalid invalid; then fail 'invalid hash accepted'; fi

# Keep, remove, replace and cancellation never silently alter the anchor.
cntools_ui_action_begin() { :; }
cntools_transaction_ui_table_widths_into() { printf -v "$1" '%s' 24,120; }
cntools_transaction_ui_styled_row() { :; }
cntools_ui_table() { cat >/dev/null; }
cntools_ui_render_status() { :; }
cntools_ui_choose() { printf -v "$1" '%s' "${CHOICE}"; }
CNTOOLS_WALLET_REGISTER_WALLET=fixture
cntools_wallet_register_operation_set drep-update
CNTOOLS_DREP_LIFECYCLE_STATE="$(jq -cn --arg hash "${hash}" '{registered:true,deposit:"500000000",url:"https://example.invalid/drep.json",hash:$hash}')"
CHOICE='Keep current metadata'; cntools_drep_lifecycle_choose_metadata
eq "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" "${hash}"
CHOICE='Remove metadata'; cntools_drep_lifecycle_choose_metadata
eq "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ''
CHOICE=Cancel; status=0; cntools_drep_lifecycle_choose_metadata || status=$?
eq "${status}" 1 'metadata cancellation'

cntools_ui_choose() { if [[ "$2" == 'DRep metadata' ]]; then printf -v "$1" '%s' 'Add / replace metadata'; else printf -v "$1" '%s' 'Enter known hash'; fi; }
cntools_ui_input() { if [[ "$2" == 'Published metadata URL' ]]; then printf -v "$1" '%s' https://example.invalid/new.json; else printf -v "$1" '%s' "${TEST_METADATA_HASH}"; fi; }
cntools_drep_lifecycle_choose_metadata
eq "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" https://example.invalid/new.json 'replace anchor'

# Current protocol deposit changes must prevent exporting a stale registration.
QUERY_STATUS=4 TEST_STATUS=not_registered TEST_DETAILS='{}'
cntools_wallet_register_operation_set drep-register
cntools_wallet_register_collect
jq '.dRepDeposit = 600000000' "${TEST_ROOT}/protocol.json" > "${TEST_ROOT}/changed.json"
mv "${TEST_ROOT}/changed.json" "${TEST_ROOT}/protocol.json"
if cntools_drep_lifecycle_recheck; then fail 'changed protocol deposit accepted'; fi
cp "${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json" "${TEST_ROOT}/protocol.json"
cntools_drep_lifecycle_recheck || fail 'restored protocol deposit'

# Check decoded certificate fields for each operation, not just package intent.
CNTOOLS_DREP_LIFECYCLE_HASH="$(printf 'ab%.0s' {1..28})"
CNTOOLS_WALLET_REGISTER_FEE=180000
CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL=https://example.invalid/drep.json CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="${hash}"
cntools_transaction_view_into() { printf -v "$1" '%s' "${BODY_VIEW}"; }
for operation in drep-register drep-update drep-retire; do
  cntools_wallet_register_operation_set "${operation}"
  CNTOOLS_WALLET_REGISTER_DEPOSIT=500000000
  kind='Drep registration certificate' credential=certificate amount=deposit anchor=anchor
  if [[ "${operation}" == drep-update ]]; then kind='Drep certificate update'; credential='Drep credential'; amount=''; anchor='anchor '; CNTOOLS_WALLET_REGISTER_DEPOSIT=0; fi
  if [[ "${operation}" == drep-retire ]]; then kind='Drep unregistration certificate'; amount=refund; anchor=''; fi
  BODY_VIEW="$(jq -cn --arg kind "${kind}" --arg credential "${credential}" --arg hash "${CNTOOLS_DREP_LIFECYCLE_HASH}" \
    --arg amount "${amount}" --argjson deposit "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" --arg anchor "${anchor}" \
    --arg url "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" --arg metadataHash "${hash}" \
    --arg input "${TEST_REFERENCE}" \
    '{certificates:[{($kind):({($credential):{keyHash:$hash}} +
      (if $amount == "" then {} else {($amount):$deposit} end) +
      (if $anchor == "" then {} else {($anchor):{url:$url,dataHash:$metadataHash}} end))}],
      inputs:[$input],fee:"180000 Lovelace",outputs:[{address:"addr_test1fixture"}]}')"
  cntools_drep_lifecycle_validate_body fixture || fail 'valid certificate rejected'
  GOOD_VIEW="${BODY_VIEW}"
  BODY_VIEW="$(jq --arg kind "${kind}" --arg credential "${credential}" '.certificates[0][$kind][$credential].keyHash = "wrong"' <<< "${GOOD_VIEW}")"
  if cntools_drep_lifecycle_validate_body fixture; then fail 'wrong DRep credential accepted'; fi
  BODY_VIEW="$(jq '.certificates += .certificates' <<< "${GOOD_VIEW}")"
  if cntools_drep_lifecycle_validate_body fixture; then fail 'extra certificate accepted'; fi
  BODY_VIEW="$(jq '.outputs[0].address = "wrong"' <<< "${GOOD_VIEW}")"
  if cntools_drep_lifecycle_validate_body fixture; then fail 'wrong change address accepted'; fi
  if [[ -n "${amount}" ]]; then
    BODY_VIEW="$(jq --arg kind "${kind}" --arg amount "${amount}" '.certificates[0][$kind][$amount] += 1' <<< "${GOOD_VIEW}")"
    if cntools_drep_lifecycle_validate_body fixture; then fail 'wrong deposit/refund accepted'; fi
  else
    BODY_VIEW="$(jq --arg kind "${kind}" --arg anchor "${anchor}" '.certificates[0][$kind][$anchor] = null' <<< "${GOOD_VIEW}")"
    if cntools_drep_lifecycle_validate_body fixture; then fail 'wrong anchor accepted'; fi
  fi
done

# Hardware base-address change needs both address references, but stake must
# remain a change reference, not an extra transaction witness.
(
  CNTOOLS_WALLET_REGISTER_WALLET_TYPE=Hardware CNTOOLS_WALLET_REGISTER_DIRECTORY=/wallet
  CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=base CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=payment
  CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY=/wallet/payment.vkey CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=/wallet/payment.hwsfile
  CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL=payment CNTOOLS_DREP_LIFECYCLE_VKEY=/wallet/drep.vkey CNTOOLS_DREP_LIFECYCLE_SOURCE=/wallet/drep.hwsfile
  CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey
  CNTOOLS_WALLET_REGISTER_POLICY_JSON='{}'
  SIGNER_LABELS=() CHANGE_FILES=()
  cntools_transaction_plan_reset() { :; }
  cntools_transaction_plan_set_validity() { :; }
  cntools_transaction_source_kind_into() { printf -v "$1" '%s' hardware; }
  cntools_transaction_plan_add_signer() { SIGNER_LABELS+=("$1"); }
  cntools_transaction_plan_add_change_key() { CHANGE_FILES+=("$3"); eq "$4" wallet-drep 'atomic hardware group'; }
  cntools_transaction_plan_set_summary() { :; }
  cntools_drep_lifecycle_plan_create
  eq "${#SIGNER_LABELS[@]}" 2 'only payment and DRep witnesses'
  eq "${CHANGE_FILES[*]}" '/wallet/payment.hwsfile /wallet/stake.hwsfile' 'hardware change references'
)
printf 'CNTools DRep lifecycle safety tests passed.\n'
