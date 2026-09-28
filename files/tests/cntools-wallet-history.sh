#!/usr/bin/env bash
# Read-only wallet explorer contracts/workflows. No network or private keys.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-history.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
CNTOOLS_TMP_DIR="${TEST_ROOT}"
for core in health menu theme; do . "${CNTOOLS_ROOT}/core/${core}.sh"; done
for lib in number wallet wallet-query asset table wallet-history wallet-history-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_wallet_log() { printf '%s\n' "$*" >> "${TEST_ROOT}/log"; }
CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://preview.koios.rest/api/v1
CNTOOLS_NETWORK=preview CNTOOLS_TIMEZONE=UTC CNTOOLS_HISTORY_WALLET=Test
credential="$(printf 'ab%.0s' {1..28})"
fixture_credential="${credential}"
fixture_stake=stake_test1uzhq3jgkmym3dfd5ckzsxvhluxnagr2mqjct2mheqrj60eqk9wq3c
policy="$(printf 'cd%.0s' {1..28})"
hash1="$(printf '%064d' 1)"
calls=0 fault="" inventory_count=12
# Account history uses the same logged/authenticated helper but GET must not
# carry a POST body. Existing callers must retain their POST default.
(
  CNTOOLS_KOIOS_TOKEN=""
  cntools_api_request() {
    eq "$1" GET
    shift 3
    [[ "$*" != *--data* ]] || fail 'GET contains a request body'
  }
  cntools_wallet_query_http "${CNTOOLS_KOIOS_API}/account_txs?_stake_address=${fixture_stake}" '' "${TEST_ROOT}/get" 33554432 GET
  cntools_api_request() { eq "$1" POST; [[ "$*" == *'--data {}'* ]] || fail 'POST body missing'; }
  cntools_wallet_query_http "${CNTOOLS_KOIOS_API}/account_utxos" '{}' "${TEST_ROOT}/post"
)
cntools_wallet_query_http() {
  local endpoint="$1" payload="$2" output="$3"
  calls=$((calls + 1))
  eq "$4" 33554432 'extended inventory response bound'
  [[ "${fault}" != transport ]] || return 22
  case "${endpoint}" in
    */credential_txs|*/account_txs\?*)
      if [[ "${endpoint}" == */credential_txs ]]; then
        eq "${5:-POST}" POST
        jq -e --arg credential "${credential}" '. == {_payment_credentials:[$credential]}' <<< "${payload}" >/dev/null || fail 'credential_txs has a filter, limit or wrong credential'
      else
        eq "${5:-POST}" GET
        eq "${payload}" '' 'account_txs must not have a body'
        eq "${endpoint}" "${CNTOOLS_KOIOS_API}/account_txs?_stake_address=${fixture_stake}" 'account_txs without filters or limits'
      fi
      jq -n --argjson count "${inventory_count}" '[range(1;$count+1) |
        {tx_hash:(("0"*64 + tostring)[-64:]),block_height:(10000-.),block_time:1700000000,epoch_no:300}]' > "${output}"
      ;;
    */credential_utxos\?is_spent=eq.false|*/account_utxos\?is_spent=eq.false)
      eq "${5:-POST}" POST
      local response_stake="" response_payment="${fixture_credential}"
      if [[ "${endpoint}" == */account_utxos* ]]; then
        jq -e --arg stake "${fixture_stake}" '. == {_stake_addresses:[$stake],_extended:true}' <<< "${payload}" >/dev/null || fail 'wrong account_utxos request'
        response_stake="${fixture_stake}"
      else
        jq -e --arg credential "${credential}" '. == {_payment_credentials:[$credential],_extended:true}' <<< "${payload}" >/dev/null || fail 'wrong extended UTxO request'
      fi
      jq -n --arg credential "${response_payment}" --arg stake "${response_stake}" --arg policy "${policy}" --arg hash "${hash1}" '[range(0;12) |
        {tx_hash:$hash,tx_index:.,address:(if . < 4 then "payment-address" else "base-address" end),
         value:"1234567",payment_cred:$credential,stake_address:(if $stake == "" then null else $stake end),epoch_no:300,
         block_height:10000,block_time:1700000000,datum_hash:null,inline_datum:null,
         reference_script:null,is_spent:false,
         asset_list:[{policy_id:$policy,asset_name:"54455354",quantity:"9007199254740993",fingerprint:"asset1test",decimals:6}]}]' > "${output}"
      ;;
    */tx_info)
      jq -e 'keys == ["_assets","_bytecode","_certs","_governance","_inputs","_metadata","_scripts","_tx_hashes","_withdrawals"] and
        ([del(._tx_hashes)[]] | all(. == true)) and (._tx_hashes|length <= 10)' <<< "${payload}" >/dev/null || fail 'tx_info options/page bound'
      jq --arg policy "${policy}" '[._tx_hashes[] |
        {tx_hash:.,tx_timestamp:1700000000,block_height:10000,fee:"180000",total_output:"1234567",
         deposit:"0",invalid_before:null,invalid_after:"123000000",inputs:[],
         outputs:[{payment_addr:{bech32:"example",cred:"example"},value:"1234567",tx_index:0,
           asset_list:[{policy_id:$policy,asset_name:"54455354",quantity:"9007199254740993"}]}],
         metadata:{"674":{msg:["hello","world"],empty:[],nothing:null}},
         native_scripts:[],plutus_contracts:[{bytecode:"deadbeef"}],
         voting_procedures:[{vote:"Yes"}],proposal_procedures:[],
         collateral_output:{value:"5000000",asset_list:"[]"}}] | reverse' <<< "${payload}" > "${output}"
      ;;
    *) fail "unexpected API call: ${endpoint}" ;;
  esac
  if [[ -n "${fault}" ]]; then
    jq "${fault}" "${output}" > "${output}.altered"
    mv "${output}.altered" "${output}"
  fi
}

# Shared dates, DST and strict validation; no arithmetic injection or octal.
date_text=""
cntools_timestamp_datetime_into date_text 0
eq "${date_text}" '1970-01-01 00:00:00 UTC (+0000)'
CNTOOLS_TIMEZONE=Europe/Stockholm
cntools_timestamp_datetime_into date_text 1700000000
[[ "${date_text}" == *'CET (+0100)' ]] || fail 'winter timezone'
cntools_timestamp_datetime_into date_text 1719792000
[[ "${date_text}" == *'CEST (+0200)' ]] || fail 'summer timezone'
for invalid in 01 'x[0]'; do
  if cntools_timestamp_datetime_into date_text "${invalid}"; then fail 'invalid timestamp accepted'; fi
done
CNTOOLS_TIMEZONE=UTC
cntools_slot_datetime_into date_text 0
eq "${date_text}" '2022-10-25 00:00:00 UTC (+0000)'
for size in '' ' ' 5 10 1; do cntools_history_page_size "${size}" || fail 'valid page size'; done
cntools_history_page_size ''
eq "${CNTOOLS_HISTORY_SIZE}" 5 'blank default'
for size in 0 11 -1 2.5 01 anything '1 0'; do
  if cntools_history_page_size "${size}"; then fail 'invalid page size accepted'; fi
done
cntools_history_load transactions "${credential}"
eq "${CNTOOLS_HISTORY_TOTAL}" 12
eq "${calls}" 1 'only inventory fetched'
cntools_history_page_load 0
eq "${calls}" 2
eq "$(jq -r '.[0].tx_hash' "${CNTOOLS_HISTORY_PAGE_FILE}")" "${hash1}" 'restore inventory order'
eq "$(jq length "${CNTOOLS_HISTORY_PAGE_FILE}")" 5
cntools_history_page_load 2
eq "$(jq length "${CNTOOLS_HISTORY_PAGE_FILE}")" 2 'last page'
cntools_history_page_load 0
eq "${calls}" 3 'previous page cached'
for invalid in 3 -1; do
  if cntools_history_page_load "${invalid}"; then fail 'out of bounds page'; fi
done
cntools_history_detail_load 1
eq "$(jq -r .tx_hash "${CNTOOLS_HISTORY_DETAIL}")" "${hash1}"
eq "${calls}" 3 'detail uses cached page'
cntools_history_detail_load 6
eq "${calls}" 4 'off-page explicit lookup is one hash'
cntools_history_detail_load "$(printf '%064d' 999)"
eq "$(jq -r .tx_hash "${CNTOOLS_HISTORY_DETAIL}")" "$(printf '%064d' 999)" 'direct hash outside history'
for invalid in 0 13 abc '1;echo' '1 0'; do
  if cntools_history_detail_load "${invalid}"; then fail 'invalid detail input'; fi
done
old_file="${CNTOOLS_HISTORY_PAGE_FILE}"
for fault in '.[0:1]' '.[0].fee="bad"' '.[0].tx_hash="foreign"' '.,.' empty transport; do
  if cntools_history_page_load 1; then fail 'bad tx_info accepted'; fi
  eq "${CNTOOLS_HISTORY_PAGE_FILE}" "${old_file}" 'failed page preserves prior page'
done
fault="" inventory_count=0
cntools_history_load transactions "${credential}"
before="${calls}"
cntools_history_page_load 0
eq "$(jq length "${CNTOOLS_HISTORY_PAGE_FILE}")" 0
eq "${calls}" "${before}" 'empty wallet avoids tx_info'
inventory_count=1000
cntools_history_load transactions "${credential}"
eq "${CNTOOLS_HISTORY_TOTAL}" 1000
cntools_history_detail_load '1,000'
eq "$(jq -r .tx_hash "${CNTOOLS_HISTORY_DETAIL}")" "$(printf '%064d' 1000)" 'formatted item number'
inventory_count=1001
if cntools_history_load transactions "${credential}"; then fail 'oversized inventory'; fi
inventory_count=12
for fault in '.[1]=.[0]' '{}' '.,.' empty; do
  if cntools_history_load transactions "${credential}"; then fail 'bad inventory accepted'; fi
done
fault=""
cntools_history_load utxos "${credential}"
cntools_history_page_load 1
eq "$(jq '.[0].tx_index' "${CNTOOLS_HISTORY_PAGE_FILE}")" 5
before="${calls}"
cntools_history_detail_load 12
eq "$(jq .tx_index "${CNTOOLS_HISTORY_DETAIL}")" 11
eq "${calls}" "${before}" 'UTxO detail does not refetch'
if cntools_history_detail_load "${hash1}"; then fail 'UTxO accepts ambiguous tx hash'; fi
for fault in '.[0].is_spent=true' '.[0].payment_cred="foreign"'; do
  if cntools_history_load utxos "${credential}"; then fail 'spent/foreign UTxO accepted'; fi
done
fault=""
cntools_history_load utxos "${credential}"
cntools_history_page_load 0

# Account endpoints keep the same paging/details contracts, but accept UTxOs
# with other payment credentials as long as the requested stake address matches.
cntools_history_load transactions "${fixture_stake}" stake
eq "${CNTOOLS_HISTORY_LOOKUP}" stake
cntools_history_page_load 1
eq "$(jq length "${CNTOOLS_HISTORY_PAGE_FILE}")" 5
cntools_history_load utxos "${fixture_stake}" stake
cntools_history_page_load 2
eq "$(jq length "${CNTOOLS_HISTORY_PAGE_FILE}")" 2
cntools_history_detail_load 12
eq "$(jq .tx_index "${CNTOOLS_HISTORY_DETAIL}")" 11
for fault in '.[0].stake_address="foreign"' '.[0].stake_address=null' '.[0].is_spent=true'; do
  if cntools_history_load utxos "${fixture_stake}" stake; then fail 'foreign/spent account UTxO accepted'; fi
done
fault="" inventory_count=0
cntools_history_load transactions "${fixture_stake}" stake
eq "${CNTOOLS_HISTORY_TOTAL}" 0
before="${calls}"
if cntools_history_load transactions "${fixture_stake}bad" stake; then fail 'invalid stake address accepted'; fi
eq "${calls}" "${before}" 'invalid stake address sent to Koios'
inventory_count=12
cntools_history_load utxos "${credential}"
cntools_history_page_load 0

# Exercise real wrapping, sanitization and number helpers; only stub Gum.
cntools_ui_render_detail() { printf '%s\n' "$1"; }
cntools_ui_table() { cat; }
cntools_ui_render_status() { printf '%s\n' "$*"; }
cntools_ui_wait() { :; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_ui_action_begin() { :; }
cntools_ui_page_file() { [[ -s "$1" ]] || fail 'empty pager'; pagers=$((pagers+1)); }
CNTOOLS_UI_CAPABLE=N CNTOOLS_HISTORY_METADATA=N
output="$(cntools_history_summary_rows "$(jq -c '.[0]' "${CNTOOLS_HISTORY_PAGE_FILE}")")"
[[ "${output}" == *'1.234567 ADA'* && "${output}" != *'ADA ADA'* ]] || fail 'ADA rendering'
[[ "${output}" == *'9,007,199,254,740,993'* ]] || fail 'exact raw asset quantity'
output="$(cntools_history_overview_rows)"
[[ "${output}" == *payment-address* && "${output}" == *base-address* ]] || fail 'per-address counts'
cntools_history_detail_load 1
metadata_calls=0
cntools_asset_details_for_ids() {
  metadata_calls=$((metadata_calls+1))
  CNTOOLS_WALLET_ASSET_TICKERS["${policy}.54455354"]=TEST
  CNTOOLS_WALLET_ASSET_METADATA_DECIMALS["${policy}.54455354"]=6
}
cntools_history_metadata_offer "${CNTOOLS_HISTORY_DETAIL}"
eq "${metadata_calls}" 0 'metadata opt-out'
CNTOOLS_HISTORY_METADATA=Y
cntools_history_metadata_offer "${CNTOOLS_HISTORY_DETAIL}"
eq "${metadata_calls}" 1
output="$(cntools_history_detail_render "${CNTOOLS_HISTORY_DETAIL}")"
[[ "${output}" == *TEST* && "${output}" == *'9,007,199,254.740993'* ]] || fail 'shared label/decimal formatting'
[[ "${output}" == *$'\n  TEST\n'* && "${output}" != *'asset_list['* ]] || fail 'UTxO assets must have indented name-titled tables'
(
  CNTOOLS_WALLET_ASSET_TICKERS["${policy}.54455354"]='Enriched token'
  record="$(jq -c '.[0]' "${CNTOOLS_HISTORY_PAGE_FILE}")"
  output="$(cntools_history_assets_render "${record}")"
  [[ "${output}" == '  Enriched token'* && "${output}" == *'Amount'* && "${output}" == *'Raw quantity'* &&
     "${output}" == *'Policy ID'* && "${output}" == *'Asset name (hex)'* && "${output}" == *'Fingerprint'* ]] || fail 'asset table fields/title'
  rows="$(cntools_history_asset_rows "$(jq -c '.asset_list[0]' <<< "${record}")" "${policy}.54455354")"
  [[ "${rows}" == *$'Decimals\0376\037number'* ]] || fail 'metadata amount and decimals must agree'
  parent="$(cntools_history_tree_rows <(printf '%s\n' "${record}") Record)"
  [[ "${parent}" != *asset_list* && "${parent}" != *"${policy}"* ]] || fail 'assets duplicated in parent table'
  CNTOOLS_HISTORY_METADATA=N
  output="$(cntools_history_assets_render "${record}")"
  [[ "${output}" == '  TEST'* && "${output}" != *'Enriched token'* && "${output}" != *Amount* ]] || fail 'metadata opt-out used enrichment'
  record="$(jq '.asset_list += [.asset_list[0] | .asset_name="ff" | .quantity="2"]' <<< "${record}")"
  output="$(cntools_history_assets_render "${record}")"
  [[ "${output}" == *$'\n  Asset 02\n'* ]] || fail 'binary-name asset needs safe fallback title'
  eq "$(cntools_history_assets_render '{"asset_list":[]}')" '' 'empty asset list has no child table'
  eq "$(cntools_history_assets_render '{}')" '' 'missing asset list has no child table'
)
cntools_history_load transactions "${credential}"
cntools_history_page_load 0
cntools_history_detail_load 1
output="$(cntools_history_detail_render "${CNTOOLS_HISTORY_DETAIL}")"
for required in Overview 'plutus contracts' deadbeef 'voting procedures' Yes '1 · hello' '2 · world' null '[]' 'Collateral output'; do
  [[ "${output}" == *"${required}"* ]] || fail "missing detail field/section ${required}"
done
jq '.outputs[0].inline_datum={value:"123456789"}' "${CNTOOLS_HISTORY_DETAIL}" > "${TEST_ROOT}/datum.json"
output="$(cntools_history_detail_render "${TEST_ROOT}/datum.json")"
[[ "${output}" == *123456789* && "${output}" != *'123.456789 ADA'* ]] || fail 'datum content misinterpreted as ADA'
jq '.metadata["evil\u001b[31m"]="\u001b]52;c;attack\u0007"' "${CNTOOLS_HISTORY_DETAIL}" > "${TEST_ROOT}/untrusted.json"
output="$(cntools_history_detail_render "${TEST_ROOT}/untrusted.json")"
[[ "${output}" != *$'\033'* && "${output}" != *$'\007'* ]] || fail 'terminal escape leakage'

# Ledger-derived intent tags, including repeated certificates and mixed activity.
for pair in 'stake_registration:Stake registration' 'stake_deregistration:Stake de-registration' \
  'pool_delegation:Stake delegation' 'vote_delegation:DRep delegation' \
  'drep_registration:DRep registration' 'drep_update:DRep update' 'drep_retire:DRep retirement'; do
  tag="${pair#*:}"
  record="$(jq -nc --arg type "${pair%%:*}" '{certificates:[{type:$type},{type:$type}]}')"
  eq "$(cntools_history_transaction_tags "${record}")" "${tag}"
done
record='{"withdrawals":[{}],"voting_procedures":[{}],"proposal_procedures":[{}],"assets_minted":[{"quantity":"100"},{"quantity":"-1"}]}'
eq "$(cntools_history_transaction_tags "${record}")" 'Burn · Governance proposal · Governance vote · Mint · Withdrawal'
eq "$(cntools_history_transaction_tags '{"certificates":[{"type":"future"}]}')" Certificate
eq "$(cntools_history_transaction_tags '{"plutus_contracts":[{}]}')" 'Script execution'
record='{"inputs":[{"payment_addr":{"bech32":"same"}}],"outputs":[{"payment_addr":{"bech32":"same"}}]}'
eq "$(cntools_history_transaction_tags "${record}")" 'Internal transfer'
eq "$(cntools_history_transaction_tags "$(jq '.outputs[0].payment_addr.bech32="other"' <<< "${record}")")" Transfer
record="$(jq --arg cred "${fixture_credential}" '.inputs[0].payment_addr.cred=$cred |
  .outputs[0].payment_addr={cred:$cred,bech32:"other"}' <<< "${record}")"
eq "$(cntools_history_transaction_tags "${record}")" 'Internal transfer' 'base and enterprise share payment key'
CNTOOLS_HISTORY_PAYMENT="${fixture_credential}" CNTOOLS_HISTORY_STAKE="${fixture_stake}"
record="$(jq --arg stake "${fixture_stake}" '.outputs[0]={stake_addr:$stake}' <<< "${record}")"
eq "$(cntools_history_transaction_tags "${record}")" 'Internal transfer' 'selected wallet identities'
for record in '{"inputs":[],"outputs":[]}' '{"inputs":[{}],"outputs":[{}]}' \
  '{"inputs":[{"payment_addr":123}],"outputs":[{"payment_addr":false}]}' \
  '{"metadata":{"intent":"Stake registration"}}'; do
  eq "$(cntools_history_transaction_tags "${record}")" Transfer 'no speculative intent'
done

# Input/output sections and isolated, address-titled records; optional fields
# stay hidden but arbitrary custom metadata preserves nulls and empty arrays.
jq '.inputs=[.outputs[0]] | .outputs += [.outputs[0]] |
  .outputs[1].payment_addr.bech32="second-address" |
  .outputs[0].datum_hash=null | .collateral_inputs=[] | .reference_inputs=[] |
  .collateral_output=null | .metadata={"674":{msg:["CNTools","CIP-20","test"]},"99":{empty:[],nothing:null}}' \
  "${CNTOOLS_HISTORY_DETAIL}" > "${TEST_ROOT}/layout.json"
output="$(cntools_history_detail_render "${TEST_ROOT}/layout.json")"
for required in '━━ Inputs ━━' '━━ Outputs ━━' '1 · example' '2 · second-address' \
  '674 · CIP-20 message' '1 · CNTools' '2 · CIP-20' '3 · test' '99 · Custom metadata' '"nothing": null' '"empty": []'; do
  [[ "${output}" == *"${required}"* ]] || fail "missing detail layout: ${required}"
done
for hidden in payment_addr payment_cred datum_hash 'Collateral inputs' 'Collateral output' \
  'Reference inputs' 'native scripts' 'proposal procedures' '[1] / value' asset_list; do
  [[ "${output}" != *"${hidden}"* ]] || fail "redundant/empty detail: ${hidden}"
done
eq "$(printf '%s\n' "${output}" | jq -Rs 'split("\n") | map(select(. == "  TEST")) | length')" 3 'same asset rendered under its input and both outputs'
jq '.metadata={"674":{enc:"basic",msg:["ciphertext"]},"721":{"policy":{"asset":{"name":"NFT"}}}}' \
  "${TEST_ROOT}/layout.json" > "${TEST_ROOT}/encrypted.json"
output="$(cntools_history_detail_render "${TEST_ROOT}/encrypted.json")"
[[ "${output}" == *'674 · CIP-83 encrypted message'* && "${output}" == *'"ciphertext"'* &&
   "${output}" != *'1 · ciphertext'* && "${output}" == *'721 · CIP-25 asset metadata'* ]] || fail 'non-CIP20 metadata presentation'

# Table sizing: both columns remain unwrapped if they fit, grow beyond the
# compact menu width, and wrap only when the terminal runs out of space.
(
  unset COLUMNS
  CNTOOLS_UI_COLUMNS=160
  cntools_ui_table() { printf 'WIDTHS %s\n' "$*"; cat; }
  long_label='A longer nested field label than the previous fixed limit'
  long_value="$(printf 'a%.0s' {1..90})"
  output="$(cntools_table_pair "${long_label}" "${long_value}" | cntools_table_render Test)"
  [[ "${output}" == *"${long_label}"* && "${output}" == *"${long_value}"* ]] || fail 'unnecessary wide table wrapping'
  CNTOOLS_UI_COLUMNS=80
  output="$(cntools_table_pair "${long_label}" "${long_value}" | cntools_table_render Test)"
  [[ "${output}" != *"${long_value}"* ]] || fail 'narrow table did not wrap'
  CNTOOLS_UI_COLUMNS=240
  long_value="$(printf 'a%.0s' {1..200})"
  output="$(cntools_table_pair ID "${long_value}" | cntools_table_render Test)"
  [[ "${output}" == *"${long_value}"* ]] || fail 'wide terminal still capped at 180'
  CNTOOLS_TABLE_MARGIN=4
  eq "$(cntools_table_content_width)" 236 'pager frame allowance'
)

# Optional real-renderer contract, pinned to the deployed Gum version. CI can
# run the ordinary suite without installing Gum; local UI validation sets this.
if [[ -n "${CNTOOLS_TEST_GUM:-}" ]]; then
  (
    # shellcheck disable=SC1091
    . "${CNTOOLS_ROOT}/core/gum.sh"
    CNTOOLS_GUM_BIN="${CNTOOLS_TEST_GUM}" NO_COLOR=1 CNTOOLS_UI_INTERACTIVE=N
    [[ "$(cntools_gum --version)" == *'2.0.0'* ]] || fail 'UI tests require pinned Gum 2.0.0'
    CNTOOLS_UI_COLUMNS=100
    output="$(cntools_table_pair 'Transaction ID' "${hash1}" identifier | cntools_table_render '1 · Transfer')"
    [[ "${output}" == *"${hash1}"* ]] || fail 'Gum wrapped a fitting transaction ID'
    eq "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" 4 'no wrapped/visible table header'
    output="$(cntools_table_pair N 100 number | cntools_table_render Tiny)"
    [[ "${output}" == *'│ N │ 100 │'* ]] || fail 'short columns broke header removal'
    CNTOOLS_UI_COLUMNS=48
    output="$(cntools_table_pair 'Transaction ID' "${hash1}" identifier | cntools_table_render Test)"
    [[ "${output}" != *"${hash1}"* ]] || fail 'Gum failed to wrap narrow table'
    [[ "$(printf '%s\n' "${output}" | jq -Rs 'split("\n") | map(length) | max')" -le 48 ]] || fail 'table exceeded terminal width'
    CNTOOLS_UI_COLUMNS=160 CNTOOLS_HISTORY_METADATA=N
    output="$(cntools_history_detail_render "${TEST_ROOT}/layout.json")"
    [[ "${output}" == *"${hash1}"* && "${output}" == *'2 · second-address'* ]] || fail 'real Gum detail rendering'
    [[ "${output}" == *$'\n  TEST\n  ╭'* && "${output}" == *"${policy}"* && "${output}" != *asset_list* ]] || fail 'real Gum asset nesting/wide policy ID'
    CNTOOLS_UI_COLUMNS=48
    output="$(cntools_history_assets_render "$(jq -c '.outputs[0]' "${TEST_ROOT}/layout.json")")"
    [[ "$(printf '%s\n' "${output}" | jq -Rs 'split("\n") | map(length) | max')" -le 48 ]] || fail 'indented asset table exceeded terminal width'
  )
fi

# Workflow: first/last page controls, blank default, explicit details, q return.
cntools_wallet_catalog_build() { CNTOOLS_WALLET_NAMES=(Test); CNTOOLS_WALLET_PATHS=(/test); }
cntools_wallet_choose() { printf -v "$1" '%s' 0; }
cntools_wallet_prepare_selected_material() { :; }
cntools_wallet_type() { printf CLI; }
cntools_wallet_id_read_credential() { printf -v "$3" '%s' "${fixture_credential}"; }
cntools_wallet_read_address() { return 1; }
input_count=0 menu_count=0 pagers=0
cntools_ui_input() {
  input_count=$((input_count+1))
  if (( input_count == 1 )); then
    [[ "$2" == *'Enter uses 5'* && "$3" == *'5 (default)'* ]] || fail 'default not advertised'
    printf -v "$1" '%s' ''
  else printf -v "$1" '%s' 1; fi
}
cntools_ui_choose() {
  local destination="$1" prompt="$2"; shift 2
  if [[ "${prompt}" == Asset* ]]; then printf -v "${destination}" '%s' 'Keep raw asset identifiers and quantities'; return; fi
  menu_count=$((menu_count+1))
  case "${menu_count}" in
    1) [[ "$*" != *'Previous page'* ]] || fail 'previous on first page'; printf -v "${destination}" '%s' 'Next page' ;;
    2) printf -v "${destination}" '%s' 'Next page' ;;
    3) [[ "$*" != *'Next page'* ]] || fail 'next on last page'; printf -v "${destination}" '%s' 'Previous page' ;;
    4) printf -v "${destination}" '%s' 'Show details' ;;
    *) printf -v "${destination}" '%s' Back ;;
  esac
}
cntools_history_action transactions > "${TEST_ROOT}/workflow.txt"
eq "${CNTOOLS_HISTORY_SIZE}" 5
eq "${pagers}" 1
eq "${menu_count}" 5
inventory_count=1000 input_count=0
cntools_ui_choose() { printf -v "$1" '%s' Back; }
cntools_history_action transactions > "${TEST_ROOT}/capped.txt"
[[ "$(< "${TEST_ROOT}/capped.txt")" == *'only the last 1,000 matching transactions'* ]] || fail 'limit warning missing'
inventory_count=0 input_count=0
cntools_history_action transactions > "${TEST_ROOT}/empty.txt"
[[ "$(< "${TEST_ROOT}/empty.txt")" != *'only the last 1,000'* ]] || fail 'spurious limit warning'
inventory_count=12 input_count=0
cntools_wallet_type() { printf MultiSig; }
cntools_wallet_id_read_credential() { eq "$2" script-payment; printf -v "$3" '%s' "${fixture_credential}"; }
cntools_history_action utxos > "${TEST_ROOT}/multisig.txt"
input_count=0
before="${calls}"
cntools_wallet_id_read_credential() { return 1; }
cntools_history_action utxos > "${TEST_ROOT}/unusable.txt"
eq "${calls}" "${before}" 'wallet without either identity does not query Koios'
eq "${input_count}" 0 'unusable wallet does not prompt for page size'

# Stake-only wallets auto-select account lookup. With both identities, choose
# the scope before page size, for both actions. Escape cancels without a query.
cntools_wallet_read_address() { eq "$2" reward; printf -v "$3" '%s' "${fixture_stake}"; }
cntools_ui_choose() { [[ "$2" != 'Look up by' ]] || fail 'unexpected scope prompt'; printf -v "$1" '%s' Back; }
for kind in transactions utxos; do
  input_count=0
  cntools_history_action "${kind}" > "${TEST_ROOT}/stake-only.txt"
  eq "${CNTOOLS_HISTORY_LOOKUP}" stake
  eq "${input_count}" 1 'stake-only page-size prompt'
done
cntools_wallet_type() { printf CLI; }
cntools_wallet_id_read_credential() { printf -v "$3" '%s' "${fixture_credential}"; }
scope_prompts=0 requested_scope=payment
cntools_ui_choose() {
  if [[ "$2" == 'Look up by' ]]; then
    eq "${input_count}" 0 'scope choice must precede page size'
    scope_prompts=$((scope_prompts + 1))
    if [[ "${requested_scope}" == payment ]]; then printf -v "$1" '%s' "$3"; else printf -v "$1" '%s' "$4"; fi
  else printf -v "$1" '%s' Back; fi
}
for kind in transactions utxos; do
  for requested_scope in payment stake; do
    input_count=0
    cntools_history_action "${kind}" > "${TEST_ROOT}/scope-choice.txt"
    eq "${CNTOOLS_HISTORY_LOOKUP}" "${requested_scope}"
  done
done
eq "${scope_prompts}" 4
input_count=0 before="${calls}"
cntools_ui_choose() { eq "$2" 'Look up by'; return 1; }
cntools_history_action transactions
eq "${input_count}" 0 'cancelled scope choice'
eq "${calls}" "${before}" 'cancelled lookup must not query Koios'
CNTOOLS_KOIOS_ENABLED=N
if cntools_history_available; then fail 'Koios disabled guard'; fi
if cntools_menu_koios_available; then fail 'Koios disabled menu guard'; fi
CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_MODE=offline
if cntools_history_available; then fail 'offline guard'; fi
CNTOOLS_MODE=local
CNTOOLS_MODULE_ROOT="${CNTOOLS_ROOT}/modules/root" CNTOOLS_VALIDATION_BASH=bash
cntools_menu_open "${CNTOOLS_MODULE_ROOT}/wallet"
for ((index=0; index<${#CNTOOLS_MENU_IDS[@]}; index++)); do
  case "${CNTOOLS_MENU_IDS[index]}" in wallet/transactions|wallet/utxos) eq "${CNTOOLS_MENU_ENABLED[index]}" Y ;; esac
done
CNTOOLS_KOIOS_ENABLED=N
cntools_menu_open "${CNTOOLS_MODULE_ROOT}/wallet"
for ((index=0; index<${#CNTOOLS_MENU_IDS[@]}; index++)); do
  case "${CNTOOLS_MENU_IDS[index]}" in wallet/transactions|wallet/utxos) eq "${CNTOOLS_MENU_ENABLED[index]}" N ;; esac
done
cntools_menu_catalog_build
cntools_menu_catalog_open "${CNTOOLS_MODULE_ROOT}/wallet"
for ((index=0; index<${#CNTOOLS_MENU_IDS[@]}; index++)); do
  case "${CNTOOLS_MENU_IDS[index]}" in wallet/transactions|wallet/utxos) eq "${CNTOOLS_MENU_ENABLED[index]}" N ;; esac
done
cntools_wallet_query_cleanup
printf 'CNTools wallet history tests passed\n'
