#!/usr/bin/env bash
# Public asset metadata caching, shared names, and transaction dates.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-asset-cache.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
CNTOOLS_NODE_HOME="${TEST_ROOT}"
CNTOOLS_TMP_DIR="${TEST_ROOT}"
CNTOOLS_MODE=local
CNTOOLS_NETWORK=preview
CNTOOLS_KOIOS_ENABLED=Y
CNTOOLS_KOIOS_API=https://preview.koios.rest/api/v1
CNTOOLS_ASSET_CACHE_ENABLED=Y
. "${CNTOOLS_ROOT}/core/theme.sh"
. "${CNTOOLS_ROOT}/core/health.sh"
for lib in number wallet asset asset-cache wallet-query; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_wallet_query_http() {
  printf '%s\n' "$2" >> "${TEST_ROOT}/calls"
  [[ "${HTTP_FAIL:-N}" != Y ]] || return 1
  if [[ "${HTTP_INVALID:-N}" == Y ]]; then printf '[]' > "$3"; return 0; fi
  jq '[._asset_list[] | {policy_id: .[0], asset_name: .[1],
    asset_name_ascii: "AB", fingerprint: ("asset1" + ("q" * 38)),
    total_supply: "1000000", registry_metadata: {name: "Example token", ticker: "TOK", decimals: 6}}]' <<< "$2" > "$3"
}
count_calls() { wc -l < "${TEST_ROOT}/calls" | tr -d ' '; }
printf -v POLICY '%056d' 1
A="${POLICY}.4142" B="${POLICY}.4344"
cntools_asset_details_for_ids "${A}" "${B}" || fail 'initial bulk fetch'
[[ "$(count_calls)" == 1 ]] || fail 'initial requests not bulk'
cntools_asset_label_into label "${A}" 1
[[ "${label}" == TOK ]] || fail 'shared ticker preference'
cntools_wallet_asset_label_into wallet_label "${A}" 1
[[ "${wallet_label}" == "${label}" ]] || fail 'Wallet / Send names differ'
CACHE="${TEST_ROOT}/.cntools/asset-cache"
FILE="${CACHE}/preview-${A}.json"
BEFORE="$(< "${FILE}")"
HTTP_FAIL=Y
cntools_asset_details_for_ids "${A}" "${B}" || fail 'warm cache requires API'
[[ "$(count_calls)" == 1 && "$(< "${FILE}")" == "${BEFORE}" ]] || fail 'cache hit refreshed TTL / made request'
HTTP_FAIL=N
# Fetch only a missing asset, not the other cached member of the batch.
rm -- "${CACHE}/preview-${B}.json"
cntools_asset_details_for_ids "${A}" "${B}" || fail 'mixed cache / API fetch'
[[ "$(count_calls)" == 2 ]] || fail 'mixed fetch count'
tail -1 "${TEST_ROOT}/calls" | jq -e --arg policy "${POLICY}" '._asset_list == [[$policy,"4344"]]' >/dev/null || fail 'cached identity requested again'
# Boundary expires exactly at one day; future timestamps and malformed rows miss.
printf -v NOW '%(%s)T' -1
jq --argjson now "${NOW}" '.fetchedAt = ($now - 86400)' "${FILE}" > "${TEST_ROOT}/edit"
cp "${TEST_ROOT}/edit" "${FILE}"
cntools_asset_details_for_ids "${A}" || fail 'expired entry not refreshed'
[[ "$(count_calls)" == 3 ]] || fail 'TTL not enforced'
jq --argjson now "${NOW}" '.fetchedAt = ($now + 1000)' "${FILE}" > "${TEST_ROOT}/edit"
cp "${TEST_ROOT}/edit" "${FILE}"
cntools_asset_details_for_ids "${A}" || fail 'future timestamp not refreshed'
[[ "$(count_calls)" == 4 ]] || fail 'future timestamp accepted'
jq '.data.policy_id = "invalid"' "${FILE}" > "${TEST_ROOT}/edit"
cp "${TEST_ROOT}/edit" "${FILE}"
cntools_asset_details_for_ids "${A}" || fail 'corrupt cached identity not refreshed'
[[ "$(count_calls)" == 5 ]] || fail 'cache schema not validated'
CNTOOLS_NETWORK=preprod
cntools_asset_details_for_ids "${A}" || fail 'network isolation'
[[ "$(count_calls)" == 6 ]] || fail 'cross-network cache reused'
CNTOOLS_NETWORK=preview
CNTOOLS_KOIOS_API=https://another.koios.invalid/api/v1
cntools_asset_details_for_ids "${A}" || fail 'API isolation'
[[ "$(count_calls)" == 7 ]] || fail 'other API cache reused'
# Clear is narrowly scoped; unrelated files and links are left alone.
printf 'keep' > "${CACHE}/unrelated.json"
cntools_asset_cache_clear || fail 'clear cache'
[[ ! -e "${FILE}" && -f "${CACHE}/unrelated.json" ]] || fail 'clear scope'
HTTP_INVALID=Y
if cntools_asset_details_for_ids "${A}"; then fail 'invalid API accepted'; fi
[[ ! -e "${FILE}" ]] || fail 'invalid API response cached'
HTTP_INVALID=N
printf 'keep' > "${TEST_ROOT}/outside"
ln -s "${TEST_ROOT}/outside" "${FILE}"
cntools_asset_details_for_ids "${A}" || fail 'symlink prevents live fallback'
cntools_asset_cache_clear || fail 'clear with symlink'
[[ -L "${FILE}" && "$(< "${TEST_ROOT}/outside")" == keep ]] || fail 'cache followed symlink'
# Missing names fall back to safe printable asset bytes; NFT ignores ticker.
CNTOOLS_WALLET_ASSET_CLASSES["${A}"]=NFT
cntools_asset_label_into label "${A}" 1
[[ "${label}" == 'Example token' ]] || fail 'NFT ticker used'
CNTOOLS_WALLET_ASSET_METADATA_NAMES=(); CNTOOLS_WALLET_ASSET_TICKERS=(); CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
cntools_asset_label_into label "${A}" 1
[[ "${label}" == AB ]] || fail 'ASCII fallback'
cntools_asset_label_into label "${POLICY}.1b" 2
[[ "${label}" == 'Asset 02' ]] || fail 'control byte displayed'

for CNTOOLS_NETWORK in mainnet preprod preview guild; do
  slot="$(cntools_health_reference_slot "${CNTOOLS_NETWORK}" 1700000000)"
  CNTOOLS_TIMEZONE=UTC
  cntools_slot_datetime_into formatted "${slot}" || fail 'slot date conversion'
  [[ "${formatted}" == '2023-11-14 22:13:20 UTC (+0000)' ]] || fail "${CNTOOLS_NETWORK} clock mismatch: ${formatted}"
done
CNTOOLS_NETWORK=preview CNTOOLS_TIMEZONE=Europe/Stockholm
slot="$(cntools_health_reference_slot preview 1700000000)"
cntools_slot_datetime_into formatted "${slot}"
[[ "${formatted}" == '2023-11-14 23:13:20 CET (+0100)' ]] || fail 'configured timezone'
slot="$(cntools_health_reference_slot preview 1689379200)"
cntools_slot_datetime_into formatted "${slot}"
[[ "${formatted}" == *'CEST (+0200)' ]] || fail 'daylight saving time'
if cntools_slot_datetime_into formatted '1+1'; then fail 'unsafe slot accepted'; fi
printf 'CNTools asset cache and date tests passed.\n'
