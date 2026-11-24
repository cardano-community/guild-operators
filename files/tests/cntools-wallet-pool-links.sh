#!/usr/bin/env bash
# CNTools Wallet List/Show pool links: the pool each wallet delegates to and
# the wallets a pool registration names as owner or reward account, read from
# the local node (pool-state) with Koios tickers and fallback, or from Koios
# alone in light mode. Functions are loaded from the libraries; the CLI and
# Koios are stubs, and every key, address and pool ID is made up.
# shellcheck disable=SC2034 # Library state is set here and read by the libraries.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools wallet pool link tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools wallet pool link tests skipped: jq is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-pool-links.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

cntools_log() { :; }
# shellcheck source=/dev/null
for library in number bech32 pool-id wallet-query-transport wallet-list-query wallet-pool-link; do
  . "${LIB}/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
cntools_wallet_log() { :; }
CNTOOLS_TMP_DIR="${TEST_ROOT}"
CNTOOLS_NETWORK=preprod
CNTOOLS_CLI="${TEST_ROOT}/cardano-cli"
printf '#!/bin/sh\nexit 1\n' > "${CNTOOLS_CLI}" && chmod +x "${CNTOOLS_CLI}"
CNTOOLS_SOCKET="${TEST_ROOT}/node.socket"
CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
CNTOOLS_LOCAL_CLI_CAPABLE=true

fill() { printf "${1}%.0s" {1..28}; }
label='' mainnet=''
cntools_wallet_link_stake_address_into W1 "$(fill 11)" key
cntools_wallet_link_stake_address_into W2 "$(fill 22)" key
cntools_wallet_link_stake_address_into W3 "$(fill 33)" key
cntools_wallet_link_stake_address_into W4 "$(fill 44)" key
cntools_wallet_link_stake_address_into SCRIPT "$(fill 55)" script
cntools_pool_id_encode_into OWN "$(fill aa)"
cntools_pool_id_encode_into OTHER "$(fill bb)"
cntools_pool_id_encode_into GONE "$(fill cc)"
assert_eq "${W1:0:13}" stake_test1uq "a key credential is a testnet key stake address"
assert_eq "${SCRIPT:0:13}" stake_test17p "a script credential is a testnet script stake address"
CNTOOLS_NETWORK=mainnet cntools_wallet_link_stake_address_into mainnet "$(fill 11)" key
assert_eq "${mainnet:0:7}" stake1u "a mainnet key stake address"

# The own pool "alpha" names W1 and W2 as owners and W1 as reward account; a
# pending update makes W3 the reward account. OTHER names W4 for rewards.
# GONE is not registered.
jq -n --arg own "$(fill aa)" --arg other "$(fill bb)" --arg h1 "$(fill 11)" --arg h2 "$(fill 22)" \
  --arg h3 "$(fill 33)" --arg h4 "$(fill 44)" '{
  ($own): {poolParams:{spsOwners:[$h1,$h2],spsAccountId:{keyHash:$h1},spsPledge:1,spsCost:1,spsMargin:0,spsRelays:[]},
           futurePoolParams:{spsOwners:[$h1,$h2],spsAccountId:{keyHash:$h3},spsPledge:1,spsCost:1,spsMargin:0,spsRelays:[]},
           retiring:null},
  ($other): {poolParams:{spsOwners:[$h2],spsAccountId:{keyHash:$h4},spsPledge:1,spsCost:1,spsMargin:0,spsRelays:[]},
             futurePoolParams:null, retiring:400}}' > "${TEST_ROOT}/pool-state.json"
jq -n --arg own "${OWN}" --arg own_hex "$(fill aa)" --arg other "${OTHER}" --arg other_hex "$(fill bb)" \
  --arg w1 "${W1}" --arg w2 "${W2}" --arg w4 "${W4}" '[
  {pool_id_bech32:$own, pool_id_hex:$own_hex, pool_status:"registered", retiring_epoch:null,
   owners:[$w1,$w2], reward_addr:$w1, meta_json:{ticker:"ALP", name:"Alpha pool"}},
  {pool_id_bech32:$other, pool_id_hex:$other_hex, pool_status:"retiring", retiring_epoch:400,
   owners:[$w2], reward_addr:$w4, meta_json:{ticker:"OTH\u0007", name:"Other"}}]' > "${TEST_ROOT}/pool-info.json"

CLI_FAIL=N CLI_CALLS=0 KOIOS_CALLS=0 KOIOS_FILE="${TEST_ROOT}/pool-info.json"
cntools_pool_catalog_build() {
  CNTOOLS_POOL_NAMES=(alpha broken); CNTOOLS_POOL_IDS=("${OWN}" "${GONE}")
  CNTOOLS_POOL_IDENTITIES=('Verified cold public key' 'Identity needs attention')
}
cntools_wallet_query_local_socket_ready() { true; }
cntools_wallet_query_run_cli() {
  local output="$1" pool_id='' hex='' requested='[]'
  shift 2
  CLI_CALLS=$((CLI_CALLS + 1))
  [[ "${CLI_FAIL}" != Y ]] || { printf 'Error: socket\n' > /dev/null; return 1; }
  while (( $# > 0 )); do
    if [[ "$1" == --stake-pool-id ]]; then
      cntools_pool_id_into pool_id hex "$2"; requested="$(jq -c --arg hex "${hex}" '. + [$hex]' <<< "${requested}")"; shift
    fi
    shift
  done
  jq --argjson requested "${requested}" 'with_entries(select(.key as $key | $requested | index($key)))' \
    "${TEST_ROOT}/pool-state.json" > "${output}"
}
cntools_wallet_query_http() {
  KOIOS_CALLS=$((KOIOS_CALLS + 1))
  [[ "$1" == */pool_info ]] || return 1
  jq --argjson request "$2" '[.[] | select(.pool_id_bech32 as $id | $request._pool_bech32_ids | index($id))]' \
    "${KOIOS_FILE}" > "$3"
}

roles() { cntools_wallet_link_roles "$@" | tr '\037' '|'; }

# ── local mode, Koios disabled ───────────────────────────────────────────────
CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=N
cntools_wallet_link_collect "${OWN}" "${OTHER}" "${GONE}" ""
assert_eq "${CLI_CALLS}|${KOIOS_CALLS}" "1|0" "one pool-state query and no Koios request"
assert_eq "${CNTOOLS_WALLET_LINK_POOLS[*]}" "${OWN} ${OTHER} ${GONE}" "own pools first, each pool once, the conflicting one only as delegated"
assert_eq "${CNTOOLS_WALLET_LINK_STATES[${OWN}]}|${CNTOOLS_WALLET_LINK_STATES[${OTHER}]}|${CNTOOLS_WALLET_LINK_STATES[${GONE}]}" \
  "registered|retiring:400|not-registered" "pool states from the node"
assert_eq "${CNTOOLS_WALLET_LINK_UNCHECKED}" 0 "every pool checked"
assert_eq "${CNTOOLS_WALLET_LINK_SOURCES[${OWN}]}" 'Local node' "registration source"
cntools_wallet_link_pool_label_into label "${OWN}"; assert_eq "${label}" alpha "an own pool without Koios is named by its folder"
cntools_wallet_link_pool_label_into label "${OTHER}"; assert_eq "${label}" "${OTHER}" "a foreign pool without a ticker is its ID"
assert_eq "$(roles "${W1}" yes "${OWN}")" "${OWN}|Owner||value
${OWN}|Reward account|removed by a pending update|value" "owner and reward account of the own pool"
assert_eq "$(roles "${W2}" yes "${OTHER}")" "${OWN}|Owner|stake not delegated to this pool, so it does not count toward the pledge|warning
${OTHER}|Owner||value" "an owner delegated elsewhere does not count toward the pledge"
assert_eq "$(roles "${W3}" yes "${OWN}")" "${OWN}|Reward account|added by a pending update|value" "a reward account set by a pending update"
assert_eq "$(roles "${W4}" no "")" "${OTHER}|Reward account|stake address not registered, so the pool's rewards go to the treasury|danger" \
  "an unregistered reward account"
assert_eq "$(roles "${W2}" no "")" "${OWN}|Owner|stake address not registered, so it does not count toward the pledge|warning
${OTHER}|Owner|stake address not registered, so it does not count toward the pledge|warning" "an unregistered owner"
assert_eq "$(roles "${SCRIPT}" yes "")" "" "a wallet no checked pool names"
assert_eq "$(cntools_wallet_link_delegation_note "${GONE}" | tr '\037' '|')" \
  "pool not registered, so this stake earns no rewards|danger" "delegated to an unregistered pool"
assert_eq "$(cntools_wallet_link_delegation_note "${OTHER}" | tr '\037' '|')" "pool retiring in epoch 400|warning" "delegated to a retiring pool"
assert_eq "$(cntools_wallet_link_delegation_note "${OWN}")" "" "nothing to say about a registered pool"

# ── local mode with Koios: tickers, and Koios answers when the node cannot ───
CNTOOLS_KOIOS_ENABLED=Y CLI_CALLS=0 KOIOS_CALLS=0
cntools_wallet_link_collect "${OTHER}"
assert_eq "${CLI_CALLS}|${KOIOS_CALLS}" "1|1" "one node query and one Koios request"
cntools_wallet_link_pool_label_into label "${OWN}"; assert_eq "${label}" "ALP (alpha)" "an own pool's ticker and folder"
cntools_wallet_link_pool_label_into label "${OTHER}" Y; assert_eq "${label}" "OTH · ${OTHER}" "a ticker without control characters, with the ID"
assert_eq "${CNTOOLS_WALLET_LINK_SOURCES[${OWN}]}" 'Local node' "Koios never replaces the node's registration"
assert_eq "$(roles "${W3}" yes "${OWN}")" "${OWN}|Reward account|added by a pending update|value" "the node's pending update is kept"
assert_eq "$(jq -r .pool_id_bech32 <<< "${CNTOOLS_WALLET_LINK_KOIOS[${OTHER}]}")" "${OTHER}" "the Koios record is kept for Show"
CLI_FAIL=Y CLI_CALLS=0 KOIOS_CALLS=0
cntools_wallet_link_collect "${OTHER}"
assert_eq "${CNTOOLS_WALLET_LINK_SOURCES[${OWN}]}|${CNTOOLS_WALLET_LINK_UNCHECKED}" 'Koios API|0' "Koios answers when the node query fails"
assert_eq "$(roles "${W1}" yes "${OWN}")" "${OWN}|Owner||value
${OWN}|Reward account||value" "roles from Koios stake addresses"
CNTOOLS_KOIOS_ENABLED=N
cntools_wallet_link_collect "${OTHER}"
assert_eq "${CNTOOLS_WALLET_LINK_UNCHECKED}" 2 "pools neither backend answered"
assert_eq "$(roles "${W1}" yes "${OWN}")" "" "no roles from unchecked pools"
CLI_FAIL=N

# ── light mode ───────────────────────────────────────────────────────────────
CNTOOLS_MODE=light CLI_CALLS=0 KOIOS_CALLS=0
cntools_wallet_link_collect "${OTHER}"
assert_eq "${CLI_CALLS}|${KOIOS_CALLS}" "0|1" "light mode asks Koios only"
assert_eq "${CNTOOLS_WALLET_LINK_STATES[${OTHER}]}|${CNTOOLS_WALLET_LINK_SOURCES[${OTHER}]}" 'retiring:400|Koios API' "Koios pool state"
assert_eq "$(roles "${W4}" yes "${OTHER}")" "${OTHER}|Reward account||value" "a reward account from Koios"
cntools_wallet_link_collect "${GONE}"
assert_eq "${CNTOOLS_WALLET_LINK_STATES[${GONE}]}" not-indexed "a pool Koios never indexed"
jq --arg w "${W1:0:20}" '.[0].owners = [$w]' "${TEST_ROOT}/pool-info.json" > "${TEST_ROOT}/bad.json"
KOIOS_FILE="${TEST_ROOT}/bad.json"
cntools_wallet_link_collect "${OTHER}"
assert_eq "${CNTOOLS_WALLET_LINK_UNCHECKED}" 2 "an invalid Koios response is not used"
KOIOS_FILE="${TEST_ROOT}/pool-info.json"
CNTOOLS_MODE=offline
cntools_wallet_link_collect "${OTHER}"
assert_eq "${#CNTOOLS_WALLET_LINK_POOLS[@]}|${KOIOS_CALLS}" "0|3" "offline mode checks nothing"

# ── Wallet List: delegations from a Koios account batch ──────────────────────
CNTOOLS_MODE=light CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES=1024
CNTOOLS_WALLET_NAMES=(one two three) CNTOOLS_WALLET_PATHS=(/x/one /x/two /x/three)
cntools_wallet_list_query_reset
CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=("${W1}" "${W2}" "${W4}")
cntools_wallet_query_http() {
  jq -n --arg w1 "${W1}" --arg w2 "${W2}" --arg own "${OWN}" --argjson request "$2" '[
    {stake_address:$w1, status:"registered", delegated_pool:$own, delegated_drep:null, rewards_available:"5", deposit:"2000000"},
    {stake_address:$w2, status:"registered", delegated_pool:null, delegated_drep:null, rewards_available:"0", deposit:"2000000"}] |
    map(select(.stake_address as $address | $request._stake_addresses | index($address)))' > "$3"
}
cntools_wallet_list_query_koios_stakes || fail "Koios account batch"
cntools_wallet_list_project_koios_results
assert_eq "${CNTOOLS_WALLET_LIST_STAKE_REGISTERED[*]}" "yes yes no" "registration per wallet; an omitted account is not registered"
assert_eq "${CNTOOLS_WALLET_LIST_POOL_DELEGATIONS[0]}|${CNTOOLS_WALLET_LIST_POOL_DELEGATIONS[1]}|${CNTOOLS_WALLET_LIST_POOL_DELEGATIONS[2]}" \
  "${OWN}||" "delegated pool per wallet"
cntools_wallet_query_http() {
  jq -n --arg w1 "${W1}" '[{stake_address:$w1, status:"registered", delegated_pool:"pool1bad", rewards_available:"5"}]' > "$3"
}
cntools_wallet_list_query_reset
CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=("${W1}" "" "")
cntools_wallet_list_query_koios_stakes && fail "a malformed delegated pool is accepted"

# ── Wallet List rows and Show table ──────────────────────────────────────────
cntools_wallet_query_http() {
  KOIOS_CALLS=$((KOIOS_CALLS + 1))
  jq --argjson request "$2" '[.[] | select(.pool_id_bech32 as $id | $request._pool_bech32_ids | index($id))]' "${KOIOS_FILE}" > "$3"
}
CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y
cntools_wallet_link_collect "${GONE}" "${OTHER}"
cntools_table_wrapped_triple() { printf '%s|%s|%s\n' "$2" "$3" "$8"; }
CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=("${W2}" "${W4}" "")
CNTOOLS_WALLET_LIST_STAKE_REGISTERED=(yes no "")
CNTOOLS_WALLET_LIST_POOL_DELEGATIONS=("${GONE}" "" "")
assert_eq "$(cntools_wallet_link_catalog_rows 0)" "Pool delegation|${GONE} · pool not registered, so this stake earns no rewards|danger
Pool owner|ALP (alpha) · stake not delegated to this pool, so it does not count toward the pledge|warning
Pool owner|OTH · stake not delegated to this pool, so it does not count toward the pledge|warning" \
  "List rows of an owner delegated to an unregistered pool"
assert_eq "$(cntools_wallet_link_catalog_rows 1)" "Pool delegation|Not delegated · stake address not registered|muted
Pool reward account|OTH · stake address not registered, so the pool's rewards go to the treasury|danger" "List rows of an unregistered reward account"
assert_eq "$(cntools_wallet_link_catalog_rows 2)" "" "no rows without a queried stake address"
cntools_table_row() { :; }
cntools_table_wrapped_pair() { printf '%s|%s|%s\n' "$1" "$2" "$4"; }
cntools_wallet_render_rows_table() { local producer="$2"; printf '# %s\n' "$1"; shift 2; "${producer}" "$@"; }
assert_eq "$(cntools_wallet_link_render_roles "${W1}" yes "${OWN}")" "# Stake pool roles · local node
Owner|ALP (alpha) · ${OWN}|identifier
Reward account|ALP (alpha) · ${OWN} · removed by a pending update|identifier" "Show table of an owner and reward account"
assert_eq "$(cntools_wallet_link_render_roles "${SCRIPT}" yes "")" "" "Show draws no table without roles"

if (( failures > 0 )); then
  printf 'cntools wallet pool link tests: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'cntools wallet pool link tests passed\n'
