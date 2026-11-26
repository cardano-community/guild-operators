#!/usr/bin/env bash
# CNTools Pool List/Show Calidus registration: Koios pool_calidus_keys
# compared with each pool's local Calidus key. Functions are loaded from the
# libraries; Koios is a stub, and every key and pool ID is made up.
# shellcheck disable=SC2034 # Library state is set here and read by the libraries.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools pool calidus status tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools pool calidus status tests skipped: jq is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-calidus.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

cntools_log() { :; }
# shellcheck source=/dev/null
for library in number bech32 pool-id pool pool-inspect; do
  . "${LIB}/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
cntools_transaction_log() { :; }
cntools_pool_public_file_safe() { [[ -f "$1" && ! -L "$1" ]]; }
cntools_transaction_temp_file() { printf -v "$1" '%s' "$(mktemp "${TEST_ROOT}/tmp.XXXXXX")"; }
fill() { printf "${1}%.0s" {1..32}; }
vkey() { jq -n --arg type "$1" --arg cbor "$2" '{type:$type,description:"",cborHex:$cbor}' > "$3"; }

# Pools: match, other (a different local key), remote (no local key), signing
# (signing key only), new (local key, never registered), none (nothing),
# revoked (local key, revoked), extended (extended local key).
names=(match other remote signing new none revoked extended)
CNTOOLS_POOL_NAMES=() CNTOOLS_POOL_DIRECTORIES=() CNTOOLS_POOL_IDS=() CNTOOLS_POOL_IDENTITIES=() id=''
for index in "${!names[@]}"; do
  mkdir -p "${TEST_ROOT}/${names[index]}"
  cntools_pool_id_encode_into id "$(printf '%02x' $((index + 1)))$(printf '00%.0s' {1..27})"
  CNTOOLS_POOL_NAMES+=("${names[index]}"); CNTOOLS_POOL_DIRECTORIES+=("${TEST_ROOT}/${names[index]}")
  CNTOOLS_POOL_IDS+=("${id}"); CNTOOLS_POOL_IDENTITIES+=('Verified cold public key')
done
normal=PaymentVerificationKeyShelley_ed25519
vkey "${normal}" "5820$(fill aa)" "${TEST_ROOT}/match/calidus.vkey"; : > "${TEST_ROOT}/match/calidus.skey"
vkey "${normal}" "5820$(fill bb)" "${TEST_ROOT}/other/calidus.vkey"
: > "${TEST_ROOT}/signing/calidus.skey"
vkey "${normal}" "5820$(fill cc)" "${TEST_ROOT}/new/calidus.vkey"
: > "${TEST_ROOT}/revoked/calidus.skey.gpg"
vkey PaymentExtendedVerificationKeyShelley_ed25519 "5840$(fill ee)$(fill 99)" "${TEST_ROOT}/extended/calidus.vkey"

record() { # pool index, public key, registered, epoch
  jq -n --arg id "${CNTOOLS_POOL_IDS[$1]}" --arg key "$2" --argjson registered "$3" --argjson epoch "$4" '{
    pool_id_bech32:$id, calidus_nonce:"85764115", calidus_pub_key:$key, tx_hash:("ab" * 32), epoch_no:$epoch,
    registered:$registered, calidus_id_bech32:(if $registered then "calidus1" + ("q" * 58) else "calidus1zz" end)}'
}
jq -s . <(record 0 "$(fill aa)" true 992) <(record 1 "$(fill aa)" true 990) <(record 2 "$(fill dd)" true null) \
  <(record 3 "$(fill aa)" true 991) <(record 6 "$(fill 00)" false 926) <(record 7 "$(fill ee)" true 993) > "${TEST_ROOT}/koios.json"
KOIOS_FILE="${TEST_ROOT}/koios.json" KOIOS_CALLS=0 KOIOS_URL=''
cntools_wallet_query_http() {
  KOIOS_CALLS=$((KOIOS_CALLS + 1)); KOIOS_URL="$1"
  [[ "$1" == */pool_calidus_keys\?* && -z "$2" && "$5" == GET ]] || return 1
  local requested="${1#*in.%28}"; requested="${requested%%%29*}"
  jq --arg requested "${requested}" '($requested | split("%2C")) as $ids |
    map(select(.pool_id_bech32 as $id | $ids | index($id)))' "${KOIOS_FILE}" > "$3"
}
status() { printf '%s|%s|%s' "${CNTOOLS_POOL_CALIDUS_STATUS[$1]}" "${CNTOOLS_POOL_CALIDUS_ROLE[$1]}" "${CNTOOLS_POOL_CALIDUS_ID[$1]}"; }

CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
cntools_pool_inspect_reset
cntools_pool_inspect_calidus
assert_eq "${KOIOS_CALLS}" 1 "one Koios request for every pool"
[[ "${KOIOS_URL}" == *"pool_id_bech32=in.%28${CNTOOLS_POOL_IDS[0]}%2C${CNTOOLS_POOL_IDS[1]}%2C"* ]] || fail "pools filtered with in.(…): ${KOIOS_URL}"
calidus_id="calidus1$(printf 'q%.0s' {1..58})"
assert_eq "$(status 0)" "Registered · this key · epoch 992|success|${calidus_id}" "the local key is registered"
assert_eq "$(status 1)" "A different key is registered · epoch 990|warning|${calidus_id}" "another key is registered"
assert_eq "$(status 2)" "Registered · key not in this pool folder|value|${calidus_id}" "registered without a local key"
assert_eq "$(status 3)" "Registered · not compared, no Calidus verification key · epoch 991|value|${calidus_id}" "a signing key alone"
assert_eq "$(status 4)" "Not registered|warning|" "a local key never registered"
assert_eq "$(status 5)" "||" "no row for a pool without Calidus"
assert_eq "$(status 6)" "Revoked · epoch 926|warning|" "a revoked registration"
assert_eq "$(status 7)" "Registered · this key · epoch 993|success|${calidus_id}" "an extended verification key"

cntools_pool_inspect_reset
cntools_pool_inspect_calidus 1 4
assert_eq "$(status 1)|$(status 0)" "A different key is registered · epoch 990|warning|${calidus_id}|||" "only the given pools"

vkey StakeVerificationKeyShelley_ed25519 "5820$(fill aa)" "${TEST_ROOT}/match/calidus.vkey"
cntools_pool_inspect_reset; cntools_pool_inspect_calidus 0
assert_eq "$(status 0)" "Registered · local verification key is invalid · epoch 992|warning|${calidus_id}" "an invalid local key"
vkey "${normal}" "5820$(fill aa)" "${TEST_ROOT}/match/calidus.vkey"

jq '.[0].calidus_pub_key = ("0" * 64)' "${TEST_ROOT}/koios.json" > "${TEST_ROOT}/bad.json"
KOIOS_FILE="${TEST_ROOT}/bad.json"
cntools_pool_inspect_reset; cntools_pool_inspect_calidus
assert_eq "$(status 0)|$(status 2)" "Unavailable|muted||||" "an inconsistent response is unavailable, not unregistered"
KOIOS_FILE="${TEST_ROOT}/koios.json"

CNTOOLS_KOIOS_ENABLED=N KOIOS_CALLS=0
cntools_pool_inspect_reset; cntools_pool_inspect_calidus
assert_eq "${KOIOS_CALLS}|$(status 0)|$(status 2)" "0|Not checked · needs Koios|muted||||" "without Koios"
CNTOOLS_MODE=offline CNTOOLS_KOIOS_ENABLED=Y
cntools_pool_inspect_reset; cntools_pool_inspect_calidus
assert_eq "${KOIOS_CALLS}|$(status 0)" "0|||" "offline mode checks nothing"

CNTOOLS_MODE=light
CNTOOLS_POOL_IDENTITIES[0]='Identity needs attention'
cntools_pool_inspect_reset; cntools_pool_inspect_calidus
assert_eq "$(status 0)" "||" "a pool whose identity needs attention is not checked"

if (( failures > 0 )); then
  printf 'cntools pool calidus status tests: %d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'cntools pool calidus status tests passed\n'
