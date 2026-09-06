#!/usr/bin/env bash
# Send arithmetic/orchestration acceptance tests; real CLI contracts also run
# in cntools-transaction-pinned.sh using deployment-pinned binaries.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'SKIP: Send tests need Bash 4.4+.\n'; exit 0
fi
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-send.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet utxo coin-selection change-plan recipient handle-virtual transaction-funding transaction-metadata message-crypto send-metadata-ui funds-send funds-send-ui; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: '$1' != '$2'"; }
cntools_transaction_log() { :; }
cntools_transaction_set_error() { CNTOOLS_TRANSACTION_ERROR="$1"; }
cntools_transaction_clear_error() { CNTOOLS_TRANSACTION_ERROR=""; }
CNTOOLS_TRANSACTION_ERROR=""
CNTOOLS_NETWORK=preview
CNTOOLS_TX_SELECTION_STRATEGY=balanced
CNTOOLS_TX_TOKEN_FRAGMENTATION=Y
CNTOOLS_TX_TOKEN_MAX_ASSETS=1
CNTOOLS_TX_UTXO_MANAGEMENT=Y
CNTOOLS_TX_COLLATERAL_MANAGEMENT=Y
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1
CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30
CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000
POLICY="$(printf 'aa%.0s' {1..28})"
ASSET="${POLICY}.01"
SECOND="${POLICY}.02"
REF_A="$(printf '11%.0s' {1..32})#0"
REF_B="$(printf '22%.0s' {1..32})#0"
ADDRESS='addr_test1vqvka8gw9kj2xytkveja3mgn79lpung854wz7jma5szac3sqr8fl8'
BASE='addr_test1qqvka8gw9kj2xytkveja3mgn79lpung854wz7jma5szac34wpry3dkfhz6jmf3v9qve0lcd86sx4kp9sk4h0jq895ljqmdru3n'
STAKE='stake_test1uzhq3jgkmym3dfd5ckzsxvhluxnagr2mqjct2mheqrj60eqk9wq3c'

for impl in cnode dingo amaru; do
  eq "$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/${impl}/release.json")" 11.0.0.0 'pinned CLI contract'
done
for network in mainnet preprod preview guild; do
  eq "$(jq -r '.slotLength' "${REPO_ROOT}/files/configs/cnode/${network}/shelley-genesis.json")" 1 'Send expiry seconds-to-slots contract'
done
value=""
cntools_number_units_into value '1,234.000001' 6; eq "${value}" 1234000001
cntools_number_units_into value '9,007,199,254,740,993' 0; eq "${value}" 9007199254740993
for bad in -1 0.0000001 1,00 1e6 NaN; do
  if cntools_number_units_into value "${bad}" 6; then fail "accepted invalid amount ${bad}"; fi
done
cntools_recipient_validate "${ADDRESS}" || fail 'valid payment recipient'
cntools_recipient_validate "${BASE}" || fail 'valid base recipient'
if cntools_recipient_validate "${STAKE}"; then fail 'reward address recipient'; fi
if cntools_recipient_validate "${ADDRESS}x"; then fail 'invalid checksum'; fi
CNTOOLS_NETWORK=mainnet
if cntools_recipient_validate "${ADDRESS}"; then fail 'wrong network'; fi
CNTOOLS_NETWORK=preview
cntools_recipient_trim_into value " ${ADDRESS} "
eq "${value}" "${ADDRESS}"

(
  CNTOOLS_SEND_ADDRESS=source; CNTOOLS_SEND_PAYMENT=source
  CNTOOLS_WALLET_PATHS=(/wallet); CNTOOLS_WALLET_NAMES=(recipient)
  cntools_ui_choose() { printf -v "$1" '%s' "${RECIPIENT_CHOICE}"; }
  cntools_ui_input() { printf -v "$1" '%s' " ${ADDRESS} "; }
  cntools_ui_render_field() { :; }
  cntools_ui_render_status() { :; }
  cntools_wallet_choose() { printf -v "$1" '%s' 0; }
  cntools_wallet_prepare_selected_material() { return 0; }
  cntools_wallet_address_primary_into() {
    printf -v "$2" '%s' "${LOCAL_RECIPIENT}"
    printf -v "$3" '%s' 'Base address'
    printf -v "$4" '%s' ''
  }
  cntools_wallet_type() { printf 'CLI'; }
  RECIPIENT_CHOICE='External address'
  cntools_send_prompt_recipient 0 || fail 'external recipient choice'
  eq "${CNTOOLS_SEND_ADDRESSES[0]}" "${ADDRESS}" 'trimmed external address'
  RECIPIENT_CHOICE='CNTools wallet'; LOCAL_RECIPIENT="${BASE}"
  cntools_send_prompt_recipient 0 || fail 'wallet recipient choice'
  eq "${CNTOOLS_SEND_ADDRESSES[0]}" "${BASE}" 'primary wallet address'
  LOCAL_RECIPIENT="${STAKE}"
  if cntools_send_prompt_recipient 0; then fail 'stake-only wallet accepted'; fi
)

cntools_utxo_reset
cntools_utxo_add "${REF_A}" "${BASE}" 10000000
cntools_utxo_add "${REF_B}" "${ADDRESS}" 50000000
cntools_utxo_add_asset 1 "${ASSET}" 9007199254740993
cntools_utxo_add_asset 1 "${SECOND}" 7
CNTOOLS_FUNDING_ASSET_IDS=("${ASSET}" "${SECOND}")
CNTOOLS_FUNDING_ASSETS["${ASSET}"]=9007199254740993
CNTOOLS_FUNDING_ASSETS["${SECOND}"]=7
CNTOOLS_FUNDING_TOTAL=60000000
declare -A demand=(["${ASSET}"]=9007199254740992)
cntools_coin_select_value 3000000 demand balanced
eq "${CNTOOLS_COIN_SELECTED_REFS[*]}" "${REF_B}" 'asset-bearing input chosen'
eq "${CNTOOLS_COIN_SELECTED_ASSETS[${ASSET}]}" 9007199254740993 'lossless quantity'
demand["${ASSET}"]=9007199254740994
if cntools_coin_select_value 3000000 demand balanced; then fail 'asset deficit accepted'; fi
demand=()
cntools_coin_select_value 3000000 demand balanced
eq "${CNTOOLS_COIN_SELECTED_REFS[*]}" "${REF_A}" 'ADA avoids tokens'

# Test the real Send balancer with deterministic boundary fakes. The pinned
# smoke test exercises the actual CLI fee/output contracts without a node.
CNTOOLS_FUNDING_PROTOCOL="${TEST_ROOT}/protocol.json"
jq -n '{maxTxSize:16384,maxValueSize:5000}' > "${CNTOOLS_FUNDING_PROTOCOL}"
declare -ag CNTOOLS_TRANSACTION_TEMP_FILES=()
COUNTER=0
BUILD_COUNT=0
cntools_transaction_temp_file() {
  COUNTER=$((COUNTER+1))
  printf -v "$1" '%s' "${TEST_ROOT}/$2-${COUNTER}"
  touch "${!1}"
}
cntools_transaction_temp_remove() { rm -- "$1"; }
cntools_transaction_plan_reset() { :; }
cntools_transaction_plan_add_signer() { SIGNER_ROLE="$2"; }
cntools_transaction_plan_add_change_key() { CHANGE_KEYS+=("$1"); }
cntools_transaction_plan_set_validity() { eq "$2" 10000 'expiry bound'; }
cntools_transaction_plan_witness_count() { printf '1'; }
cntools_transaction_calculate_min_utxo_into() {
  # Exercise nonzero coin minimum recalculation, not just a constant stub.
  local _min=1000000
  [[ "$3" != *' + '* ]] || _min=1500000
  printf -v "$1" '%s' "${_min}"
}
cntools_transaction_build_body() {
  eq "$1" build-raw 'raw deterministic builder'
  BUILD_COUNT=$((BUILD_COUNT+1))
  jq -n '{type:"TxBody ConwayEra",cborHex:"00"}' > "$2"
}
cntools_transaction_calculate_min_fee_into() { printf -v "$1" '%s' 200000; }
cntools_transaction_plan_set_summary() { jq -e '.action == "send"' <<< "$1" >/dev/null; }
cntools_transaction_package_create_staged_into() { printf -v "$1" '%s' "$2"; }
CNTOOLS_SEND_WALLET="test"
CNTOOLS_SEND_ADDRESS="${BASE}"
CNTOOLS_SEND_PAYMENT="${ADDRESS}"
CNTOOLS_SEND_VKEY=payment.vkey
CNTOOLS_SEND_SOURCE=payment.skey
CNTOOLS_SEND_CREDENTIAL="${POLICY}"
CNTOOLS_SEND_TYPE=CLI
CNTOOLS_SEND_DIRECTORY="${TEST_ROOT}"
CNTOOLS_SEND_EXPIRY=10000
CNTOOLS_FUNDING_BACKEND=koios
CNTOOLS_SEND_ADDRESSES=("${ADDRESS}")
CNTOOLS_SEND_LABELS=(external)
CNTOOLS_SEND_AMOUNTS=(3000000)
CNTOOLS_SEND_ASSETS=(["0|${ASSET}"]=9007199254740992)
CNTOOLS_SEND_MODE=exact
staged=""
cntools_send_build_into staged || fail "Send balance: ${CNTOOLS_TRANSACTION_ERROR}"
eq "${SIGNER_ROLE}" spending 'only payment witness'
eq "${CNTOOLS_SEND_FEE}" 200000
eq "${CNTOOLS_SEND_CHANGE_ASSETS[${ASSET}]}" 1 'only unspent asset quantity returned'
eq "${CNTOOLS_SEND_CHANGE_ASSETS[${SECOND}]}" 7 'unrequested assets preserved'
(( BUILD_COUNT >= 2 )) || fail 'fee did not iterate'

assert_conservation() {
  local total_ada="${CNTOOLS_SEND_FEE}" output="" tail="" coin="" qty="" asset="" sum=""
  local -a pieces=()
  local -A amounts=()
  for output in "${CNTOOLS_SEND_OUTPUTS[@]}"; do
    tail="${output#*+}"; coin="${tail%% *}"
    cntools_uint_add_into total_ada "${total_ada}" "${coin}"
    read -r -a pieces <<< "${tail}"
    for (( j=1; j<${#pieces[@]}; j+=3 )); do
      qty="${pieces[j+1]}"; asset="${pieces[j+2]}"
      [[ "${asset}" == *.* ]] || asset+="."
      cntools_uint_add_into sum "${amounts[${asset}]:-0}" "${qty}"
      amounts["${asset}"]="${sum}"
    done
  done
  eq "${total_ada}" "${CNTOOLS_COIN_SELECTED_LOVELACE}" 'ADA conservation including fee'
  for asset in "${CNTOOLS_COIN_SELECTED_ASSET_IDS[@]}"; do
    eq "${amounts[${asset}]:-0}" "${CNTOOLS_COIN_SELECTED_ASSETS[${asset}]}" 'native asset conservation'
  done
}
assert_conservation
CNTOOLS_SEND_ADDRESSES+=("${BASE}"); CNTOOLS_SEND_LABELS+=(second); CNTOOLS_SEND_AMOUNTS+=(2000000)
CNTOOLS_SEND_ASSETS["1|${SECOND}"]=3
cntools_send_build_into staged || fail 'multiple recipients'
assert_conservation
cntools_send_remove_recipient 0
eq "${#CNTOOLS_SEND_ADDRESSES[@]}" 1 'removal reindexes recipients'
eq "${CNTOOLS_SEND_ASSETS[0|${SECOND}]}" 3 'removal reindexes assets'
eq "${CNTOOLS_SEND_ASSETS[0|${ASSET}]:-0}" 0 'removed assets not retained'

CNTOOLS_SEND_MODE=max
cntools_send_build_into staged || fail 'Max ADA build'
eq "${CNTOOLS_SEND_AMOUNTS[0]}" 56800000 'Max retains only required token change and fee'
eq "${#CNTOOLS_CHANGE_OUTPUTS[@]}" 2 'no optional ADA housekeeping for Max'
assert_conservation
CNTOOLS_SEND_MODE=sweep
cntools_send_build_into staged || fail 'sweep build'
eq "${CNTOOLS_SEND_AMOUNTS[0]}" 59800000 'sweep less actual fee'
eq "${#CNTOOLS_CHANGE_OUTPUTS[@]}" 0 'sweep has no change'
assert_conservation
CNTOOLS_SEND_TYPE=Hardware
CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey
CHANGE_KEYS=()
cntools_send_plan_signers
eq "${CHANGE_KEYS[*]}" 'Payment change Stake change' 'hardware base change uses both public paths'
eq "${SIGNER_ROLE}" spending 'stake change is not a witness'
CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED=N
cntools_transaction_package_create_staged_into() {
  printf -v "$1" '%s' "$2"
  CNTOOLS_TRANSACTION_BODY_FILE="$2"
  CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED=Y
}
cntools_transaction_calculate_min_fee_into() {
  if [[ "${CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED}" == Y ]]; then
    printf -v "$1" '%s' 250000
  else
    printf -v "$1" '%s' 200000
  fi
}
cntools_send_build_into staged || fail 'hardware fee rebalancing'
eq "${CNTOOLS_SEND_FEE}" 250000 'hardware-prepared fee is covered'
assert_conservation

# Excess quantities and unsafe size limits fail closed.
CNTOOLS_SEND_MODE=exact; CNTOOLS_SEND_AMOUNTS=(3000000)
CNTOOLS_SEND_ASSETS["0|${SECOND}"]=8
if cntools_send_build_into staged; then fail 'overcommitted assets accepted'; fi
CNTOOLS_SEND_ASSETS=()
CNTOOLS_SEND_ASSETS["0|${POLICY}.03"]=1
if cntools_send_build_into staged; then fail 'requested asset disappeared silently'; fi
[[ "${CNTOOLS_TRANSACTION_ERROR}" == *'no longer available'* ]] || fail 'missing asset diagnostic'
CNTOOLS_SEND_ASSETS=()
jq -n '{maxTxSize:10,maxValueSize:5000}' > "${CNTOOLS_FUNDING_PROTOCOL}"
if cntools_send_build_into staged; then fail 'oversized signed transaction accepted'; fi
CNTOOLS_SEND_ASSETS["0|${ASSET}"]=1
jq -n '{maxTxSize:16384,maxValueSize:1}' > "${CNTOOLS_FUNDING_PROTOCOL}"
if cntools_send_build_into staged; then fail 'oversized value accepted'; fi

# Direct API/CLI collection is not entered in offline mode.
CNTOOLS_MODE=offline
if cntools_funding_collect "${BASE}" "${ADDRESS}"; then fail 'offline collection accepted'; fi
[[ "${CNTOOLS_TRANSACTION_ERROR}" == *'Build online'* ]] || fail 'offline explanation'

# Both backends feed the same exact inventory, and Koios requests both addresses
# in one extended request. HTTP/CLI errors and malformed data are not empty funds.
(
  . "${CNTOOLS_ROOT}/lib/wallet-query.sh"
  CNTOOLS_MODE=local; CNTOOLS_SOCKET=/socket; CNTOOLS_CLI=/cli
  CNTOOLS_KOIOS_ENABLED=Y; CNTOOLS_KOIOS_API=https://preview.koios.rest/api/v1
  FIXTURE_MODE=valid; POST_COUNT=0
  cntools_transaction_slot_value_valid() { [[ "$1" =~ ^[0-9]+$ ]]; }
  cntools_transaction_local_backend_ready() { [[ "${CNTOOLS_MODE}" == local ]]; }
  cntools_transaction_network_arguments_into() { local -n net_ref="$1"; net_ref=(--testnet-magic 2); }
  cntools_transaction_run_cli() {
    case " $* " in
      *' protocol-parameters '*) cp "${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json" "$1" ;;
      *' utxo '*) jq -n --arg ref "${REF_A}" --arg address "${BASE}" \
        '{($ref):{address:$address,value:{lovelace:10000000}}}' > "$1" ;;
      *' tip '*) jq -n '{slot:1000}' > "$1" ;;
      *) return 1 ;;
    esac
  }
  cntools_funding_get() {
    case "$1" in
      */tip) jq -n '[{abs_slot:1000}]' > "$2" ;;
      */cli_protocol_params) cp "${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json" "$2" ;;
      *) return 1 ;;
    esac
  }
  cntools_wallet_query_http() {
    POST_COUNT=$((POST_COUNT+1))
    jq -e --arg a "${BASE}" --arg b "${ADDRESS}" \
      '._extended == true and (._addresses | sort) == ([$a,$b]|sort)' <<< "$2" >/dev/null || fail 'Koios not bulk extended'
    [[ "${FIXTURE_MODE}" != failure ]] || return 1
    if [[ "${FIXTURE_MODE}" == empty ]]; then printf '[]' > "$3"
    elif [[ "${FIXTURE_MODE}" == malformed ]]; then printf '{}' > "$3"
    else
      jq -n --arg tx "${REF_A%#*}" --arg address "${BASE}" \
        '[{tx_hash:$tx,tx_index:0,address:$address,value:"10000000",asset_list:[]}]' > "$3"
    fi
  }
  cntools_funding_collect "${BASE}" "${ADDRESS}" || fail 'local funding collection'
  eq "${CNTOOLS_FUNDING_TOTAL}" 10000000 'local exact balance'
  eq "${CNTOOLS_FUNDING_BACKEND}" local
  CNTOOLS_MODE=light
  cntools_funding_collect "${BASE}" "${ADDRESS}" || fail 'Koios funding collection'
  eq "${CNTOOLS_FUNDING_TOTAL}" 10000000 'Koios exact balance'
  eq "${CNTOOLS_FUNDING_BACKEND}" koios
  eq "${POST_COUNT}" 1 'one bulk funding request'
  for FIXTURE_MODE in empty malformed failure; do
    if cntools_funding_collect "${BASE}" "${ADDRESS}"; then fail "accepted ${FIXTURE_MODE} funding"; fi
  done
)

# UI orchestration: unsigned export never signs; sign-only never submits;
# submission and signing have distinct confirmation gates.
for workflow in 'Create unsigned package' 'Create and sign' 'Create, sign and submit'; do
  (
    . "${CNTOOLS_ROOT}/lib/funds-send-ui.sh"
    trace="${TEST_ROOT}/workflow-${workflow// /-}"
    : > "${trace}"
    cntools_ui_action_begin() { :; }
    cntools_ui_render_detail() { :; }
    cntools_ui_render_field() { :; }
    cntools_ui_render_status() { :; }
    cntools_transaction_require_cli() { return 0; }
    cntools_wallet_catalog_build() { CNTOOLS_WALLET_NAMES=(test); CNTOOLS_WALLET_PATHS=(/test); }
    cntools_wallet_choose() { printf -v "$1" '%s' 0; }
    cntools_send_prepare_wallet() { CNTOOLS_SEND_SOURCE=payment.skey; }
    cntools_ui_spin_function() { shift; "$@"; }
    cntools_funding_collect() { return 0; }
    cntools_send_edit_recipients() { return 0; }
    cntools_send_render_recipients() { return 0; }
    cntools_wallet_format_lovelace() { printf '%s ADA' "$1"; }
    cntools_ui_choose() {
      case "$2" in
        Workflow) printf -v "$1" '%s' "${workflow}" ;;
        'Transaction expiry') printf -v "$1" '%s' '30 minutes' ;;
        'Review transfer'*) printf -v "$1" '%s' 'Keep reviewed transaction' ;;
        *) fail "unexpected prompt $2" ;;
      esac
    }
    cntools_send_refresh_build_into() { printf -v "$1" '%s' /staged.json; }
    cntools_transaction_ui_render_package_review() { return 0; }
    cntools_send_prompt_output() { printf -v "$1" '%s' "$2"; }
    cntools_transaction_publish() { printf 'publish\n' >> "${trace}"; }
    cntools_transaction_default_output_into() { printf -v "$1" '%s' /signed.json; }
    cntools_ui_confirm() { printf 'confirm %s\n' "$1" >> "${trace}"; return 0; }
    cntools_send_recheck() { printf 'recheck\n' >> "${trace}"; }
    cntools_transaction_sign_registered() { printf 'sign\n' >> "${trace}"; }
    cntools_transaction_package_load() { CNTOOLS_TRANSACTION_COMPLETE=Y; }
    cntools_transaction_submit_input_prepare() { CNTOOLS_TRANSACTION_SIGNED_FILE=/signed; CNTOOLS_TRANSACTION_SUBMIT_ID=abc; }
    cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' koios; }
    cntools_transaction_ui_render_submit_review() { return 0; }
    cntools_transaction_ui_submit_selected() { printf 'submit\n' >> "${trace}"; CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=accepted; }
    cntools_send_workflow || fail 'Send UI workflow failed'
    grep -qx publish "${trace}" || fail 'unsigned not kept'
    if [[ "${workflow}" == 'Create unsigned package' ]]; then
      if grep -qx sign "${trace}"; then fail 'unsigned flow signed'; fi
    else
      grep -qx sign "${trace}" || fail 'sign flow did not sign'
      grep -q '^confirm Sign' "${trace}" || fail 'missing signing confirmation'
    fi
    if [[ "${workflow}" == 'Create, sign and submit' ]]; then
      grep -qx submit "${trace}" || fail 'submit flow did not submit'
      grep -q '^confirm Submit' "${trace}" || fail 'missing submission confirmation'
    elif grep -qx submit "${trace}"; then fail 'unexpected submission'; fi
    cntools_ui_confirm() { return 1; }
    : > "${trace}"
    if [[ "${workflow}" != 'Create unsigned package' ]]; then
      status=0
      cntools_send_workflow || status=$?
      eq "${status}" 1 'declined signing cancels'
      if grep -qx sign "${trace}"; then fail 'signed after decline'; fi
    fi
  )
done

# A moved Handle must stop the live flow, never rewrite an approved address.
(
  CNTOOLS_SEND_ADDRESSES=("${ADDRESS}")
  CNTOOLS_SEND_HANDLES=('\$alice')
  CNTOOLS_SEND_RESOLUTIONS=('{}')
  cntools_handle_resolve_into() { printf -v "$1" '%s' "${BASE}"; printf -v "$2" '%s' '{}'; }
  if cntools_send_recheck_handles; then fail 'moved Handle accepted'; fi
  eq "${CNTOOLS_SEND_ADDRESSES[0]}" "${ADDRESS}" 'moved Handle did not redirect'
  cntools_handle_resolve_into() { printf -v "$1" '%s' "${ADDRESS}"; printf -v "$2" '%s' '{"rechecked":true}'; }
  cntools_send_recheck_handles || fail 'unchanged Handle rejected'
  eq "${CNTOOLS_SEND_RESOLUTIONS[0]}" '{"rechecked":true}' 'fresh resolution evidence'
  original='{"type":"virtual-subhandle","policy":"policy","asset":"asset","virtual":{"publicMint":true,"expiresTimeMs":"2000000000000","leaseStatus":"unexpired","datumHash":"old"}}'
  CNTOOLS_SEND_RESOLUTIONS=("${original}")
  fresh="$(jq -c '.virtual.datumHash="new"' <<< "${original}")"
  cntools_handle_resolve_into() { printf -v "$1" '%s' "${ADDRESS}"; printf -v "$2" '%s' "${fresh}"; }
  cntools_send_recheck_handles || fail 'personalization-only update rejected'
  for change in '.virtual.publicMint=false' '.virtual.leaseStatus="expired"' '.virtual.expiresTimeMs="3000000000000"' '.type="nft-subhandle" | del(.virtual)' '.policy="changed"'; do
    CNTOOLS_SEND_RESOLUTIONS=("${original}")
    fresh="$(jq -c "${change}" <<< "${original}")"
    if cntools_send_recheck_handles; then fail "unreviewed virtual change ${change}"; fi
    eq "${CNTOOLS_SEND_RESOLUTIONS[0]}" "${original}" 'unreviewed evidence not saved'
  done
  cntools_ui_render_field() { printf '%s: %s\n' "$1" "$2"; }
  cntools_ui_render_status() { printf '%s: %s\n' "$1" "$2"; }
  cntools_send_confirm() { return 1; }
  if cntools_send_review_virtual "${original}" > "${TEST_ROOT}/virtual-review"; then fail 'virtual confirmation cancellation ignored'; fi
  grep -q 'Public · unexpired' "${TEST_ROOT}/virtual-review" || fail 'virtual lease review missing'
  cntools_send_confirm() { return 0; }
  fresh="$(jq -c '.virtual.publicMint=false | .virtual.leaseStatus="expired"' <<< "${original}")"
  cntools_send_review_virtual "${fresh}" > "${TEST_ROOT}/virtual-review" || fail 'confirmed private virtual'
  grep -q 'parent Handle owner can revoke' "${TEST_ROOT}/virtual-review" || fail 'private revocation warning'
  grep -q 'does not redirect to its parent' "${TEST_ROOT}/virtual-review" || fail 'expiry explanation'
)

printf 'CNTools Send tests passed.\n'
