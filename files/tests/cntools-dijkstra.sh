#!/usr/bin/env bash
# CNTools across cardano-cli 11.7 and the Dijkstra era: the certificate field
# names of 11.7 and of earlier releases, the per-transaction era, the review
# guard against Dijkstra-only fields, the minimum pool margin and the pool's
# BLS key in a registration. Functions are loaded from the libraries; no CLI
# or node is needed.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools dijkstra tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools dijkstra tests skipped: jq is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-dijkstra.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

cntools_log() { :; }
# shellcheck source=/dev/null
for library in number bech32 transaction pool pool-parameters pool-registration; do
  . "${LIB}/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
cntools_transaction_log() { :; }
cntools_wallet_register_set_error() { CNTOOLS_WALLET_REGISTER_ERROR="$1"; }

# ── margins ──────────────────────────────────────────────────────────────────
for case in "0|0/1" "1|1/1" "0.035|7/200" "0.05|1/20" "7500000/100000000|3/40" "12345678/100000000|6172839/50000000" \
            "100000000/100000000|1/1" "0/100000000|0/1"; do
  assert_eq "$(cntools_pool_margin_rational "${case%%|*}")" "${case#*|}" "margin ${case%%|*} as cardano-cli 11.7 shows it"
done
cntools_pool_margin_rational 2 >/dev/null && fail "a margin above 1 has a fraction"
cntools_pool_margin_meets_minimum 1500000/100000000 0.015 || fail "1.5 % meets a 1.5 % minimum"
cntools_pool_margin_meets_minimum 1499999/100000000 0.015 && fail "1.499999 % meets a 1.5 % minimum"
cntools_pool_margin_meets_minimum 0.02 0.015 || fail "a decimal margin above the minimum"
cntools_pool_margin_meets_minimum 0 0 || fail "no minimum below protocol 12"

# ── DRep certificate names ───────────────────────────────────────────────────
view='{"certificates":[{"Drep registration certificate":{"certificate":{"keyHash":"aa"},"deposit":5}},
  {"Drep certificate update":{"Drep credential":{"keyHash":"aa"},"anchor ":{"url":"u","dataHash":"h"}}},
  {"Drep unregistration certificate":{"certificate":{"keyHash":"aa"},"refund":5}},
  {"Stake address registration":{"certificate":{"keyHash":"bb"}}}]}'
cntools_transaction_view_drep_names view || fail "DRep names could not be mapped"
assert_eq "$(jq -c '[.certificates[] | keys[0]]' <<< "${view}")" \
  '["DRep registration certificate","DRep certificate update","DRep unregistration certificate","Stake address registration"]' "DRep certificate names"
assert_eq "$(jq -c '[.certificates[0][] | keys], [.certificates[1][] | keys], [.certificates[2][] | keys], [.certificates[3][] | keys]' <<< "${view}" | paste -sd' ' -)" \
  '[["DRep credential","deposit"]] [["DRep credential","anchor"]] [["DRep credential","refund"]] [["certificate"]]' "DRep fields, other certificates untouched"
renamed="${view}"
cntools_transaction_view_drep_names renamed && assert_eq "${renamed}" "$(jq -c . <<< "${view}")" "11.7 names stay as they are"

# ── Dijkstra-only fields ─────────────────────────────────────────────────────
for case in '{"era":"Conway","fee":"1 Lovelace"}|' \
            '{"direct deposits":null,"sub-transactions":null,"account balance intervals":null,"starting account balance intervals":null}|' \
            '{"direct deposits":{"stake_test1x":5},"sub-transactions":null}|direct deposits' \
            '{"direct deposits":null,"sub-transactions":[{"inputs":[]}],"account balance intervals":{"a":1}}|sub-transactions, account balance intervals'; do
  cntools_transaction_view_dijkstra_extras_into extras "${case%%|*}" || fail "extras of ${case%%|*}"
  assert_eq "${extras}" "${case#*|}" "Dijkstra-only fields in ${case%%|*}"
done

# ── era of a file and of the network ─────────────────────────────────────────
for case in "Tx DijkstraEra|dijkstra" "TxWitness DijkstraEra|dijkstra" "Unwitnessed Tx DijkstraEra|dijkstra" \
            "Tx ConwayEra|latest" "TxWitness ConwayEra|latest"; do
  printf '{"type":"%s","description":"","cborHex":"00"}\n' "${case%%|*}" > "${TEST_ROOT}/envelope.json"
  cntools_transaction_file_era_into era "${TEST_ROOT}/envelope.json"
  assert_eq "${era}" "${case#*|}" "era of a ${case%%|*} file"
done
printf '{"protocolVersion":{"major":12,"minor":0}}\n' > "${TEST_ROOT}/protocol-12.json"
printf '{"protocolVersion":{"major":10,"minor":2}}\n' > "${TEST_ROOT}/protocol-10.json"
cntools_protocol_major_into major "${TEST_ROOT}/protocol-12.json" && assert_eq "${major}" 12 "protocol major"
cntools_transaction_cli_supports_dijkstra() { return 0; }
cntools_transaction_era_dijkstra_available "${TEST_ROOT}/protocol-12.json" || fail "Dijkstra features at protocol 12"
cntools_transaction_era_dijkstra_available "${TEST_ROOT}/protocol-10.json" && fail "Dijkstra features at protocol 10"
assert_eq "${CNTOOLS_TRANSACTION_ERA}" latest "transactions are Conway-era by default"

# ── pool registration review ─────────────────────────────────────────────────
CNTOOLS_NETWORK=preprod
CNTOOLS_WALLET_REGISTER_OPERATION=pool-register
CNTOOLS_POOL_REG_HEX="$(printf 'a1%.0s' {1..28})"
CNTOOLS_POOL_REG_VRF_HASH="$(printf 'b2%.0s' {1..32})"
CNTOOLS_POOL_REG_PLEDGE=1000000000 CNTOOLS_POOL_REG_COST=170000000 CNTOOLS_POOL_REG_MIN_COST=170000000
CNTOOLS_POOL_REG_MARGIN=2000000/100000000 CNTOOLS_POOL_REG_MIN_MARGIN=0.015
CNTOOLS_POOL_REG_REWARD_HASH="$(printf 'c3%.0s' {1..28})" CNTOOLS_POOL_REG_REWARD_VKEY=/dev/null
CNTOOLS_POOL_REG_OWNERS="[{\"hash\":\"${CNTOOLS_POOL_REG_REWARD_HASH}\",\"vkey\":\"/dev/null\"}]"
CNTOOLS_POOL_REG_RELAYS='[]' CNTOOLS_POOL_REG_METADATA=null CNTOOLS_POOL_EXTRA_EXPECTED='[]'
CNTOOLS_WALLET_REGISTER_INPUTS=("$(printf '0%.0s' {1..64})#0")
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=addr_test1xyz CNTOOLS_WALLET_REGISTER_EXPIRY=99999 CNTOOLS_WALLET_REGISTER_FEE=200000
BLS_PUBLIC="$(printf 'd4%.0s' {1..96})" BLS_PROOF="$(printf 'e5%.0s' {1..48})"
pool_bech32=''; reward_bech32=''
cntools_bech32_encode_into pool_bech32 "${CNTOOLS_POOL_REG_HEX}" pool
cntools_bech32_encode_into reward_bech32 "e0${CNTOOLS_POOL_REG_REWARD_HASH}" stake_test
assert_eq "$(cntools_pool_parameters_view_json | jq -c '{"pool id", "vrf key hash", margin, "reward account"}')" \
  "{\"pool id\":\"${pool_bech32}\",\"vrf key hash\":\"${CNTOOLS_POOL_REG_VRF_HASH}\",\"margin\":\"1/50\",\"reward account\":\"${reward_bech32}\"}" \
  "pool parameters in the 11.7 names"
# A decoded body built from the expected parameters; $1 = 11.7 or earlier, $2 = BLS key JSON or null.
pool_view() {
  local params=''
  if [[ "$1" == 11.7 ]]; then
    params="$(cntools_pool_parameters_view_json | jq -c --argjson bls "$2" 'if $bls == null then . else . + {"bls key": $bls} end')"
  else
    params="$(cntools_pool_parameters_json | jq -c --argjson bls "$2" '. + {blsKey: $bls}')"
  fi
  jq -cn --argjson params "${params}" --arg input "${CNTOOLS_WALLET_REGISTER_INPUTS[0]}" --arg address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" '
    {certificates:[{"Pool registration":{"pool params":$params}}], inputs:[$input], fee:"200000 Lovelace",
     "validity range":{"upper bound":99999,"lower bound":null}, outputs:[{address:$address,datum:null,"reference script":null}],
     withdrawals:null, mint:null, metadata:null, "collateral inputs":[], "reference inputs":[], voters:{},
     "governance actions":[], treasuryDonation:0, currentTreasuryValue:null}'
}
cntools_transaction_view_into() { local -n _view="$1"; _view="${FIXTURE_VIEW}"; }
bls="{\"blsPubKey\":\"${BLS_PUBLIC}\",\"blsPossessionProof\":\"${BLS_PROOF}\"}"
for format in 11.7 11.5; do
  CNTOOLS_POOL_REG_BLS_EXPECTED=null
  FIXTURE_VIEW="$(pool_view "${format}" null)"
  cntools_pool_registration_validate_body body || fail "${format}: a Conway-era registration without a BLS key"
  FIXTURE_VIEW="$(pool_view "${format}" "${bls}")"
  cntools_pool_registration_validate_body body && fail "${format}: a BLS key CNTools did not put there"
  CNTOOLS_POOL_REG_BLS_EXPECTED="{\"blsPubKey\":\"${BLS_PUBLIC}\"}"
  cntools_pool_registration_validate_body body || fail "${format}: a Dijkstra-era registration with the pool's BLS key"
  FIXTURE_VIEW="$(pool_view "${format}" "{\"blsPubKey\":\"$(printf 'f6%.0s' {1..96})\",\"blsPossessionProof\":\"${BLS_PROOF}\"}")"
  cntools_pool_registration_validate_body body && fail "${format}: another BLS key"
  FIXTURE_VIEW="$(pool_view "${format}" null)"
  cntools_pool_registration_validate_body body && fail "${format}: a registration that drops the BLS key"
  CNTOOLS_POOL_REG_BLS_EXPECTED=null
  FIXTURE_VIEW="$(pool_view "${format}" null | jq -c '.certificates[0]["Pool registration"]["pool params"].pledge = 1')"
  cntools_pool_registration_validate_body body && fail "${format}: another pledge"
done
FIXTURE_VIEW="$(pool_view 11.7 null | jq -c '.certificates[0]["Pool registration"]["pool params"].margin = "1/49"')"
cntools_pool_registration_validate_body body && fail "11.7: another margin"
CNTOOLS_POOL_REG_MARGIN=1000000/100000000
cntools_pool_parameters_json >/dev/null && fail "a margin below the network minimum builds"
CNTOOLS_POOL_REG_MIN_MARGIN=0
cntools_pool_parameters_json >/dev/null || fail "the same margin below protocol 12"

if (( failures > 0 )); then
  printf '%s cntools dijkstra checks failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools dijkstra tests passed\n'
