#!/usr/bin/env bash
# Read-only pool inventory, bulk lookups, and wallet-style List/Show contracts.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-pool.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet wallet-query transaction pool-id table pool pool-inspect pool-health public-metadata pool-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
CNTOOLS_POOL_DIR="${TEST_ROOT}/pools" CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_LOG="${TEST_ROOT}/log"
CNTOOLS_MODE=offline CNTOOLS_NETWORK=preview CNTOOLS_CLI=''
hex=f9dca21a6c826ec8acb4cf395cbc24351937bfe6560b2683ab8b415f
pool=pool1l8w2yxnvsfhv3t95euu4e0pyx5vn00lx2c9jdqat3dq47avj9qx
other_hex="$(printf 'ab%.0s' {1..28})"; cntools_pool_id_into other_pool other_hex "${other_hex}"
mkdir -p "${CNTOOLS_POOL_DIR}/Alpha" "${CNTOOLS_POOL_DIR}/Beta" "${CNTOOLS_POOL_DIR}/Incomplete" "${CNTOOLS_POOL_DIR}/.staging"
printf '%s\n' "${hex}" > "${CNTOOLS_POOL_DIR}/Alpha/pool.id"
printf '%s\n' "${pool}" > "${CNTOOLS_POOL_DIR}/Alpha/pool.id-bech32"
printf '%s\n' "${hex}" > "${CNTOOLS_POOL_DIR}/Beta/pool.id"
printf '%s\n' "${other_pool}" > "${CNTOOLS_POOL_DIR}/Beta/pool.id-bech32"
printf 'PRIVATE MUST NEVER APPEAR' > "${CNTOOLS_POOL_DIR}/Alpha/cold.skey.gpg"
ln -s "${CNTOOLS_POOL_DIR}/Alpha" "${CNTOOLS_POOL_DIR}/Linked"
ln -s "${CNTOOLS_POOL_DIR}/Alpha/cold.skey.gpg" "${CNTOOLS_POOL_DIR}/Incomplete/cold.skey"
cntools_pool_catalog_build || fail 'inventory'
eq "${CNTOOLS_POOL_NAMES[*]}" 'Alpha Beta Incomplete' 'safe sorted inventory including incomplete pools'
eq "${CNTOOLS_POOL_PROTECTIONS[0]}" Encrypted 'encrypted cold key'
eq "${CNTOOLS_POOL_IDENTITIES[0]}" 'Stored ID only' 'legacy cached ID'
eq "${CNTOOLS_POOL_IDENTITIES[1]}" 'Identity needs attention' 'conflicting cached IDs'
eq "${CNTOOLS_POOL_IDENTITIES[2]}" 'Missing public identity' 'missing identity visible'
[[ "${CNTOOLS_POOL_WARNINGS[2]}" == *'linked cold.skey'* ]] || fail 'linked private material not flagged'
cntools_pool_inspect_reset
cntools_pool_inspect_eligible 0 || fail 'stored ID cannot be inspected'
if cntools_pool_inspect_eligible 1; then fail 'conflicting identity eligible'; fi
if cntools_pool_inspect_eligible 2; then fail 'missing identity eligible'; fi
(
  CNTOOLS_POOL_DIR="${TEST_ROOT}/LinkedRoot"
  ln -s "${TEST_ROOT}/pools" "${CNTOOLS_POOL_DIR}"
  if cntools_pool_catalog_build; then fail 'linked root accepted'; fi
)
(
  CNTOOLS_POOL_COLD_VKEY_FILENAME=../cold.vkey
  if cntools_pool_catalog_build; then fail 'unsafe configured filename'; fi
)

response="${TEST_ROOT}/response.json"
jq -n --arg hex "${hex}" '{($hex):{poolParams:{spsPledge:50000000000,spsCost:170000000,spsMargin:0.025,
  spsAccountId:{keyHash:$hex},spsOwners:[$hex],spsRelays:[{"single host name":{dnsName:"relay.example",port:3001}}],spsMetadata:null},
  futurePoolParams:{spsPledge:60000000000,spsCost:170000000,spsMargin:0.03,spsOwners:[$hex],spsRelays:[]},retiring:42}}' > "${response}"
local_json="$(< "${response}")"
cntools_pool_inspect_local_parse 0 "${response}" || fail 'local response'
eq "${CNTOOLS_POOL_CHAIN_STATUS[0]}" Retiring 'retirement state'
eq "$(jq -r '.spsPledge' <<< "${CNTOOLS_POOL_FUTURE[0]}")" 60000000000 'pending settings'
eq "${CNTOOLS_POOL_RETIREMENT[0]}" 42 'retirement epoch'
for mutation in '. + {wrong:{}}' 'to_entries | .[0].key="wrong" | from_entries' '.[].poolParams.spsMargin=2' '.[].retiring=-1' '.[].futurePoolParams=[]'; do
  jq "${mutation}" <<< "${local_json}" > "${response}"
  if cntools_pool_inspect_local_parse 0 "${response}"; then fail "bad local response accepted: ${mutation}"; fi
done
printf '{}' > "${response}"; cntools_pool_inspect_reset
cntools_pool_inspect_local_parse 0 "${response}"
eq "${CNTOOLS_POOL_CHAIN_STATUS[0]}" 'Not registered' 'new pool without ledger record'

koios="$(jq -cn --arg hex "${hex}" --arg pool "${pool}" '[{pool_id_hex:$hex,pool_id_bech32:$pool,
  pool_status:"registered",retiring_epoch:null,pledge:"50000000000",fixed_cost:"170000000",margin:0.025,
  reward_addr:"stake_test1example",owners:["stake_test1owner"],relays:[{dns:"relay.example",port:3001}],
  active_epoch_no:42,meta_json:{name:"Example",ticker:"EX",description:"Description",homepage:"https://example.com"}}]')"
printf '%s' "${koios}" > "${response}"
cntools_pool_inspect_koios_parse "${response}" 0 || fail 'Koios response'
eq "${CNTOOLS_POOL_CHAIN_SOURCE[0]}" 'Koios API' 'Koios provenance'
eq "$(jq -r '.name' <<< "${CNTOOLS_POOL_CHAIN_METADATA[0]}")" Example 'metadata'
for mutation in '. + .' '.[0].pool_id_hex="wrong"' '.[0].pool_id_bech32="wrong"' '.[0].pool_status="wrong"' '.[0].margin=null' '.[0].pool_status="retiring"'; do
  jq "${mutation}" <<< "${koios}" > "${response}"
  if cntools_pool_inspect_koios_parse "${response}" 0; then fail "bad Koios response accepted: ${mutation}"; fi
done
jq '.[0].pool_status="retired" | .[0].retiring_epoch=42' <<< "${koios}" > "${response}"
cntools_pool_inspect_koios_parse "${response}" 0; eq "${CNTOOLS_POOL_CHAIN_STATUS[0]}" Retired 'retired historical record'
cntools_pool_settings_rows "$(jq -c '.[0] | .active_stake=null | .live_stake=null | .meta_json=null' "${response}")" koios |
  grep -F '50,000.000000 ADA' >/dev/null || fail 'null optional Koios fields hide historical registration'
printf '[]' > "${response}"; cntools_pool_inspect_reset
cntools_pool_inspect_koios_parse "${response}" 0
eq "${CNTOOLS_POOL_CHAIN_STATUS[0]}" 'Not indexed' 'successful empty API response'

# No API calls offline; light is batched; local success is preferred, failure
# falls back explicitly and transport/schema errors never look unregistered.
(
  calls=0 local_calls=0 fault=''
  CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
  CNTOOLS_LOCAL_CLI_CAPABLE=true CNTOOLS_SOCKET=/fixture.socket CNTOOLS_CLI=fixture
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_wallet_query_http() {
    calls=$((calls+1)); [[ "${fault}" != http ]] || return 22
    eq "$1" https://koios.invalid/api/v1/pool_info 'endpoint'
    eq "$(jq -r '._pool_bech32_ids|join(",")' <<< "$2")" "${pool}" 'bound bulk pool request'
    [[ "$2" != *limit* ]] || fail 'response limited'
    printf '%s' "${koios}" > "$3"
    [[ "${fault}" != schema ]] || printf 'null' > "$3"
  }
  cntools_transaction_run_cli() {
    local_calls=$((local_calls+1)); [[ "${fault}" != local ]] || return 1
    [[ "$*" == *"latest query pool-state --stake-pool-id ${pool} --testnet-magic 2 --socket-path /fixture.socket --output-json"* ]] || fail 'local query arguments'
    printf '%s' "${local_json}" > "$1"
  }
  cntools_transaction_log_cli_failure() { :; }
  cntools_pool_inspect_catalog; eq "${calls}:${local_calls}" 0:0 'offline isolation'
  CNTOOLS_MODE=light
  cntools_pool_inspect_catalog; eq "${calls}:${local_calls}" 1:0 'one light request'
  CNTOOLS_MODE=local
  cntools_pool_inspect_catalog; eq "${calls}:${local_calls}" 1:1 'local preferred'
  original_current="${CNTOOLS_POOL_CURRENT[0]}"; original_future="${CNTOOLS_POOL_FUTURE[0]}"
  cntools_pool_inspect_metadata 0
  eq "${calls}:${local_calls}" 2:1 'local metadata enrichment'
  eq "${CNTOOLS_POOL_CHAIN_SOURCE[0]}" 'Local node' 'metadata does not replace source'
  eq "${CNTOOLS_POOL_CURRENT[0]}" "${original_current}" 'metadata does not replace current'
  eq "${CNTOOLS_POOL_FUTURE[0]}" "${original_future}" 'metadata does not replace pending'
  eq "$(jq -r '.ticker' <<< "${CNTOOLS_POOL_CHAIN_METADATA[0]}")" EX 'local enrichment metadata'
  fault=local; cntools_pool_inspect_catalog; eq "${calls}:${local_calls}" 3:2 'fallback'
  eq "${CNTOOLS_POOL_CHAIN_SOURCE[0]}" 'Koios API' 'fallback provenance'
  CNTOOLS_MODE=light fault=http
  cntools_pool_inspect_catalog; eq "${CNTOOLS_POOL_CHAIN_STATUS[0]}" Unavailable 'transport failure not empty'
  fault=schema; cntools_pool_inspect_catalog; eq "${CNTOOLS_POOL_CHAIN_STATUS[0]}" Unavailable 'schema failure not empty'
)
(
  # Two distinct IDs use a single request, with exact response binding per pool.
  CNTOOLS_POOL_IDS[1]="${other_pool}" CNTOOLS_POOL_HEX_IDS[1]="${other_hex}" CNTOOLS_POOL_IDENTITIES[1]='Stored ID only'
  CNTOOLS_MODE=light CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
  calls=0
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_wallet_query_http() {
    calls=$((calls+1)); eq "$(jq '._pool_bech32_ids|length' <<< "$2")" 2 'bulk IDs'
    jq --arg id "${other_pool}" --arg hex "${other_hex}" '. + [.[0] | .pool_id_bech32=$id | .pool_id_hex=$hex]' <<< "${koios}" > "$3"
  }
  cntools_pool_inspect_catalog
  eq "${calls}" 1 'batched lookup'; eq "${CNTOOLS_POOL_CHAIN_STATUS[1]}" Registered 'second pool identity'
)
(
  # A large catalog is chunked, without losing the successful empty-result state.
  CNTOOLS_POOL_NAMES=(); CNTOOLS_POOL_IDS=(); CNTOOLS_POOL_HEX_IDS=(); CNTOOLS_POOL_IDENTITIES=()
  for ((i=0;i<101;i++)); do
    printf -v generated_hex '%056x' "$((i+1))"
    cntools_pool_id_into generated_pool generated_hex "${generated_hex}"
    CNTOOLS_POOL_NAMES+=("Pool ${i}"); CNTOOLS_POOL_IDS+=("${generated_pool}")
    CNTOOLS_POOL_HEX_IDS+=("${generated_hex}"); CNTOOLS_POOL_IDENTITIES+=('Stored ID only')
  done
  CNTOOLS_MODE=light CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
  calls=0
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_wallet_query_http() {
    calls=$((calls+1)); size="$(jq '._pool_bech32_ids|length' <<< "$2")"
    if ((calls == 1)); then eq "${size}" 100 'first chunk'; else eq "${size}" 1 'last chunk'; fi
    printf '[]' > "$3"
  }
  cntools_pool_inspect_catalog
  eq "${calls}" 2 'bounded batching'; eq "${CNTOOLS_POOL_CHAIN_STATUS[100]}" 'Not indexed' 'last chunk result'
)

# Real shared table sizing/text helpers, with a plain-text Gum adapter.
cntools_ui_table() { printf 'TABLE %s\n' "$*"; while IFS= read -r row; do printf '%s\n' "${row}"; done; }
CNTOOLS_UI_COLUMNS=180 NO_COLOR=1
cntools_pool_inspect_reset
printf '%s' "${local_json}" > "${response}"; cntools_pool_inspect_local_parse 0 "${response}"
rendered="$(cntools_pool_identity_rows 0 Y | cntools_table_render Pool)"
[[ "${rendered}" == *"${pool}"* && "${rendered}" != *PRIVATE* ]] || fail 'identity table'
long_url="https://example.com/$(printf 'x%.0s' {1..90})"
rendered="$(cntools_table_pair 'Metadata URL' "${long_url}" identifier | cntools_table_render Metadata)"
[[ "${rendered}" == *"${long_url}"* ]] || fail 'wide table wraps an identifier unnecessarily'
CNTOOLS_UI_COLUMNS=50
rendered="$(cntools_table_pair 'Metadata URL' "${long_url}" identifier | cntools_table_render Metadata)"
[[ "${rendered}" != *"${long_url}"* && "${rendered}" == *'https://example.com/'* ]] || fail 'narrow table does not wrap'
CNTOOLS_UI_COLUMNS=180
rows="$(cntools_pool_settings_rows "${CNTOOLS_POOL_CURRENT[0]}" local)"
[[ "${rows}" == *'50,000.000000 ADA'* && "${rows}" == *'2.5 %'* && "${rows}" == *'Reward credential'* ]] || fail 'local settings formatting'
rows="$(cntools_pool_relays_rows "${CNTOOLS_POOL_CURRENT[0]}" local)"
[[ "${rows}" == *'relay.example · port 3001'* ]] || fail 'local relay'
rows="$(cntools_pool_render_settings Config '{"margin":"3.5","pledgeADA":"50000","owners":[{"wallet_name":"Owner"}],"relays":[{"type":"DNS_A","address":"relay.example","port":"3001"}],"private":"PRIVATE"}' config)"
[[ "${rows}" == *'50,000 ADA'* && "${rows}" == *Owner* && "${rows}" != *PRIVATE* ]] || fail 'legacy local config'
cntools_pool_render_settings Config '{"owners":"broken","relays":5}' config >/dev/null || fail 'malformed optional config fields abort view'
printf '{broken' > "${CNTOOLS_POOL_DIR}/Alpha/pool.config"
cntools_pool_local_json_into config 0 config
eq "${config}" '{}' 'bad local JSON ignored'
[[ "${CNTOOLS_POOL_WARNINGS[0]}" == *'pool.config ignored'* ]] || fail 'invalid config warning'

cntools_ui_action_begin() { printf 'BEGIN %s\n' "$*"; }
cntools_ui_wait() { :; }
cntools_ui_render_status() { printf '%s\n' "$*"; }
cntools_ui_confirm() { return 1; }
cntools_ui_choose() { [[ "${choice:-Cancel}" != Cancel ]] || { printf -v "$1" Cancel; return 0; }; printf -v "$1" '%s' "$3"; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_pool_inspect_local() { fail 'unexpected local call in offline/declined view'; }
cntools_pool_inspect_koios() { fail 'unexpected API call in offline/declined view'; }
CNTOOLS_MODE=offline choice=first
rendered="$(cntools_pool_action_list)"; [[ "${rendered}" == *Alpha* && "${rendered}" == *Incomplete* ]] || fail 'List action'
rendered="$(cntools_pool_action_show)"; [[ "${rendered}" == *'Operational certificate'* && "${rendered}" != *PRIVATE* ]] || fail 'Show action'
CNTOOLS_MODE=light
cntools_pool_action_list >/dev/null || fail 'declined chain check'
CNTOOLS_MODE=offline choice=Cancel
cntools_pool_action_show >/dev/null || fail 'cancel selection'
for action in list show; do
  jq -e '.libs | index("pool-ui.sh") != null and index("placeholder.sh") == null' "${CNTOOLS_ROOT}/modules/root/pool/${action}/module.json" >/dev/null || fail "${action} dependencies"
done
printf 'CNTools pool inventory and views tests passed.\n'
