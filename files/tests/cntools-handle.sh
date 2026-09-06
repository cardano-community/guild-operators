#!/usr/bin/env bash
# Deterministic Koios fixtures; no public-network resolution in CI.
# shellcheck disable=SC1090,SC2034,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-handle.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet recipient handle handle-virtual; do
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/${lib}.sh"
done
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/health.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_transaction_log() { :; }
cntools_transaction_temp_file() { local p; p="$(mktemp "${TEST_ROOT}/handle.XXXXXX")"; printf -v "$1" '%s' "${p}"; }
CNTOOLS_MODE=local; CNTOOLS_KOIOS_ENABLED=Y
CNTOOLS_KOIOS_API=https://preview.koios.rest/api/v1; CNTOOLS_NETWORK=preview
ADDRESS=addr_test1vqvka8gw9kj2xytkveja3mgn79lpung854wz7jma5szac3sqr8fl8
TX="$(printf '11%.0s' {1..32})"
POLICY="${CNTOOLS_HANDLE_ROOT_POLICY}"
SECOND=6c32db33a422e0bc2cb535bb850b5a6e9a9572222056d6ddc9cbc26e
PREFIX=000de140
NAME_HEX=616c696365
DATUM=null; DATUM_HASH="${TX}"; HOLDING_ADDRESS="${ADDRESS}"
SUPPLY=1; OWNER_COUNT=1; HTTP_FAIL=N; STALE=N; NO_REGISTRY=N; BAD_REGISTRY=N; WINDOW=N
CALLS=0
cntools_funding_get() {
  local now=0
  printf -v now '%(%s)T' -1
  [[ "${HTTP_FAIL}" != Y ]] || return 1
  if [[ "$1" == */tip ]]; then
    [[ "${STALE}" != Y ]] || now=$((now-1000))
    jq -n --argjson now "${now}" '[{abs_slot:120000000,block_time:$now}]' > "$2"
  else
    jq -n --arg p "${POLICY}" --arg a "${PREFIX}${NAME_HEX}" --argjson now "${now}" \
      '[{policy_id:$p,asset_name:$a,minting_txs:[{quantity:"1",block_time:$now}]}]' > "$2"
  fi
}
cntools_wallet_query_http() {
  local endpoint="$1" payload="$2" out="$3" first=0 last=0
  CALLS=$((CALLS+1))
  [[ "${HTTP_FAIL}" != Y ]] || return 1
  if [[ "${endpoint}" == */asset_info ]]; then
    jq --arg supply "${SUPPLY}" --arg a "${PREFIX}${NAME_HEX}" --arg p "${POLICY}" --arg registry "${CNTOOLS_HANDLE_REGISTRY_ASSET}" \
      '._asset_list | map(select(.[0] == $p and (.[1] == $a or .[1] == $registry)) |
        {policy_id:.[0],asset_name:.[1],total_supply:$supply})' <<< "${payload}" > "${out}"
  elif [[ "$(jq '._asset_list | length' <<< "${payload}")" == 1 ]]; then
    if [[ "${NO_REGISTRY}" == Y ]]; then printf '[]' > "${out}"; return; fi
    [[ "${WINDOW}" != Y ]] || { first=1; last=2; }
    # Datum shape and IDs from the live preview registry observed 2026-09-05.
    jq -n --arg p "${POLICY}" --arg a "${CNTOOLS_HANDLE_REGISTRY_ASSET}" --arg tx "${TX}" --arg other "${SECOND}" \
      --argjson first "${first}" --argjson last "${last}" \
      '[{tx_hash:$tx,tx_index:0,is_spent:false,asset_list:[{policy_id:$p,asset_name:$a,quantity:"1"}],
        inline_datum:{value:{list:[{map:[
          {k:{bytes:$p},v:{list:[{int:$first},{int:$last},{int:0}]}},
          {k:{bytes:$other},v:{list:[{int:87341978},{int:0},{int:0}]}}
        ]}]}}}]' > "${out}"
    [[ "${BAD_REGISTRY}" != Y ]] || printf '[{}]' > "${out}"
  else
    local expected=5
    [[ "${NAME_HEX}" == 616c696365 ]] || expected=4
    [[ "$(jq '._asset_list | length' <<< "${payload}")" == "${expected}" ]] || fail 'not batching candidate policies'
    jq -n --arg p "${POLICY}" --arg a "${PREFIX}${NAME_HEX}" --arg tx "${TX}" --arg address "${HOLDING_ADDRESS}" --argjson count "${OWNER_COUNT}" \
      --argjson datum "${DATUM}" --arg hash "${DATUM_HASH}" \
      '[range($count) | {tx_hash:$tx,tx_index:.,is_spent:false,address:$address,
        inline_datum:{value:$datum},datum_hash:$hash,
        asset_list:[{policy_id:$p,asset_name:$a,quantity:"1"}]}]' > "${out}"
  fi
}
address=""; evidence=""
cntools_handle_resolve_into address evidence '$alice' || fail "root handle: ${CNTOOLS_HANDLE_ERROR}"
[[ "${address}" == "${ADDRESS}" ]] || fail 'resolved address'
jq -e '.type == "cip68-root" and .handle == "$alice" and .network == "preview" and .registry != ""' <<< "${evidence}" >/dev/null || fail 'provenance'
(( CALLS == 3 )) || fail 'expected registry, bulk candidates, and bulk supply calls'
NAME_HEX=616c69636540626f62
cntools_handle_resolve_into address evidence 'alice@bob' || fail 'NFT subhandle'
jq -e '.type == "nft-subhandle"' <<< "${evidence}" >/dev/null || fail 'subhandle type'
NAME_HEX=616c696365
PREFIX=""
cntools_handle_resolve_into address evidence alice || fail 'classic handle'
jq -e '.type == "classic"' <<< "${evidence}" >/dev/null || fail 'classic type'
PREFIX=000de140
for problem in SUPPLY OWNER_COUNT HTTP_FAIL STALE NO_REGISTRY BAD_REGISTRY WINDOW; do
  previous="${!problem}"
  case "${problem}" in SUPPLY|OWNER_COUNT) printf -v "${problem}" 2 ;; *) printf -v "${problem}" Y ;; esac
  if cntools_handle_resolve_into address evidence alice; then fail "accepted ${problem}"; fi
  [[ -z "${address}" && -z "${evidence}" ]] || fail 'failure retained destination'
  printf -v "${problem}" '%s' "${previous}"
done

# Full public-network response fixtures, cross-checked with the official API.
# The holding script differs from both resolved addresses; expiry never falls
# back to it or to a parent. Tests themselves make no network requests.
FIXTURE="${REPO_ROOT}/files/tests/fixtures/handle-virtual-preview.json"
PREFIX=00000000
for sample in 0 1 2 3; do
  name="$(jq -r --argjson i "${sample}" '.expected[$i].name' "${FIXTURE}")"
  NAME_HEX="$(printf '%s' "${name}" | od -An -v -tx1 | tr -d ' \n')"
  DATUM="$(jq -c --argjson i "${sample}" '.utxos[$i].inline_datum.value' "${FIXTURE}")"
  DATUM_HASH="$(jq -r --argjson i "${sample}" '.utxos[$i].datum_hash' "${FIXTURE}")"
  HOLDING_ADDRESS="$(jq -r --argjson i "${sample}" '.utxos[$i].address' "${FIXTURE}")"
  cntools_handle_resolve_into address evidence "${name}" || fail "live fixture: ${CNTOOLS_HANDLE_ERROR}"
  expected="$(jq -r --argjson i "${sample}" '.expected[$i].address' "${FIXTURE}")"
  [[ "${address}" == "${expected}" && "${address}" != "${HOLDING_ADDRESS}" ]] || fail 'virtual datum address'
  jq -e --argjson i "${sample}" --argjson evidence "${evidence}" '
    .expected[$i] as $e | $e.expiresTimeMs == $evidence.virtual.expiresTimeMs and
      $e.publicMint == $evidence.virtual.publicMint and $evidence.type == "virtual-subhandle"' "${FIXTURE}" >/dev/null || fail 'virtual evidence'
done
valid_datum="${DATUM}"
# Exact key lookup survives reordering and unrelated profile metadata.
DATUM="$(jq -c '.fields[2].map |= reverse' <<< "${valid_datum}")"
cntools_handle_resolve_into address evidence "${name}" || fail 'reordered datum'
# Public/private and expired/unexpired are distinct, explicit lease states.
for public in 0 1; do
  for expiry in 0 9007199254740991; do
    DATUM="$(jq -c --argjson p "${public}" --argjson e "${expiry}" '
      .fields[2].map[0].v.map[0].v.int=$e | .fields[2].map[0].v.map[1].v.int=$p' <<< "${valid_datum}")"
    cntools_handle_resolve_into address evidence "${name}" || fail 'virtual lease state'
    status=unexpired; [[ "${expiry}" != 0 ]] || status=expired
    jq -e --arg s "${status}" --argjson p "${public}" '.virtual.leaseStatus == $s and .virtual.publicMint == ($p == 1)' <<< "${evidence}" >/dev/null || fail 'lease status'
  done
done
for mutation in \
  'null' \
  '.constructor=1' \
  '.fields[1].int=2' \
  '.fields[2].map += [.fields[2].map[0]]' \
  '.fields[2].map[0].v.map += [.fields[2].map[0].v.map[0]]' \
  '.fields[2].map[0].v.map[0].v.int=-1' \
  '.fields[2].map[0].v.map[0].v.int=9007199254740992' \
  '.fields[2].map[0].v.map[0].v.int=1.5' \
  '.fields[2].map[0].v.map[1].v.int=true' \
  '.fields[2].map[0].v.map[1].v.int=2' \
  'del(.fields[2].map[1])' \
  '.fields[2].map[1].v.map += [.fields[2].map[1].v.map[0]]' \
  '.fields[2].map[1].v.map[0].v.bytes=""' \
  '.fields[2].map[1].v.map[0].v.bytes |= ("01" + .[2:])' \
  '.fields[2].map[1].v.map[0].v.bytes |= ("10" + .[2:])'; do
  DATUM="$(jq -c "${mutation}" <<< "${valid_datum}")"
  if cntools_handle_resolve_into address evidence "${name}"; then fail "accepted virtual mutation ${mutation}"; fi
  [[ -z "${address}" && -z "${evidence}" ]] || fail 'virtual failure retained destination'
done
DATUM="${valid_datum}"
for problem in SUPPLY OWNER_COUNT DATUM_HASH; do
  previous="${!problem}"
  case "${problem}" in SUPPLY|OWNER_COUNT) printf -v "${problem}" 0 ;; *) printf -v "${problem}" '' ;; esac
  if cntools_handle_resolve_into address evidence "${name}"; then fail "accepted virtual ${problem}"; fi
  printf -v "${problem}" '%s' "${previous}"
done
# Label-000 roots are not subhandles; malformed virtuals never downgrade.
NAME_HEX=616c696365
if cntools_handle_resolve_into address evidence alice; then fail 'virtual root accepted'; fi

# A short payment-only datum address, independently known from wallet tests.
cntools_recipient_from_hex_into address '60196e9d0e2da4a311766665d8ed13f17e1e4d07a55c2f4b7da405dc46' || fail 'enterprise encoding'
[[ "${address}" == "${ADDRESS}" ]] || fail 'enterprise Bech32 vector'
CNTOOLS_NETWORK=mainnet
cntools_recipient_from_hex_into address '61196e9d0e2da4a311766665d8ed13f17e1e4d07a55c2f4b7da405dc46' || fail 'mainnet address bytes'
[[ "${address}" == addr1* ]] || fail 'mainnet HRP'
if cntools_recipient_from_hex_into address '60196e9d0e2da4a311766665d8ed13f17e1e4d07a55c2f4b7da405dc46'; then fail 'testnet bytes on mainnet'; fi
CNTOOLS_NETWORK=preprod
cntools_recipient_from_hex_into address '60196e9d0e2da4a311766665d8ed13f17e1e4d07a55c2f4b7da405dc46' || fail 'preprod address bytes'
[[ "${address}" == "${ADDRESS}" ]] || fail 'preprod testnet encoding'
CNTOOLS_NETWORK=preview
for invalid_hex in '00' 'gg' '001' "e0196e9d0e2da4a311766665d8ed13f17e1e4d07a55c2f4b7da405dc46"; do
  if cntools_recipient_from_hex_into address "${invalid_hex}"; then fail 'invalid address bytes accepted'; fi
done
CNTOOLS_MODE=offline
before=$CALLS
if cntools_handle_resolve_into address evidence alice; then fail 'offline lookup'; fi
(( CALLS == before )) || fail 'offline network access'
CNTOOLS_MODE=light
for invalid in 'Alice' 'alice@' 'https://handle.me/alice' 'alice b' 'abcdefghijklmnopqrstuvwxyz123'; do
  if cntools_handle_resolve_into address evidence "${invalid}"; then fail 'bad syntax'; fi
done
printf 'CNTools Handle resolver tests passed.\n'
