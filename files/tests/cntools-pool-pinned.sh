#!/usr/bin/env bash
# Node-free, real pool artifacts using only the cnode deployment's pinned CLI.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the verified pinned CLI binary}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-pool-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
fail() { tail -10 "${TEST_ROOT}/test.log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
. "${CNTOOLS_ROOT}/core/health.sh"
for lib in number wallet wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query transaction pool-id table pool pool-inspect pool-health pool-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
# macOS chmod does not accept the GNU option terminator used by runtime code.
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local arg=""; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "${version}" == "${pin}" ]] || fail 'CLI is not the cnode deployment pin'
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_POOL_DIR="${TEST_ROOT}/pools" CNTOOLS_MODE=offline CNTOOLS_NETWORK=preview
directory="${CNTOOLS_POOL_DIR}/Pinned pool"
mkdir -p "${directory}"
"${CNTOOLS_CLI}" latest node key-gen --cold-verification-key-file "${directory}/cold.vkey" \
  --cold-signing-key-file "${directory}/cold.skey" --operational-certificate-issue-counter-file "${directory}/cold.counter"
"${CNTOOLS_CLI}" latest node key-gen-KES --verification-key-file "${directory}/hot.vkey" --signing-key-file "${directory}/hot.skey"
"${CNTOOLS_CLI}" latest node key-gen-VRF --verification-key-file "${directory}/vrf.vkey" --signing-key-file "${directory}/vrf.skey"
"${CNTOOLS_CLI}" latest node issue-op-cert --kes-verification-key-file "${directory}/hot.vkey" \
  --cold-signing-key-file "${directory}/cold.skey" --operational-certificate-issue-counter-file "${directory}/cold.counter" \
  --kes-period 0 --out-file "${directory}/op.cert"
expected="$("${CNTOOLS_CLI}" latest stake-pool id --cold-verification-key-file "${directory}/cold.vkey" --output-bech32)"
hex="$("${CNTOOLS_CLI}" latest stake-pool id --cold-verification-key-file "${directory}/cold.vkey" --output-hex)"
chmod 0400 "${directory}"/*
before="$(cksum "${directory}"/*)"
cntools_pool_catalog_build || fail 'real inventory'
[[ "${CNTOOLS_POOL_IDS[0]}" == "${expected}" && "${CNTOOLS_POOL_HEX_IDS[0]}" == "${hex}" ]] || fail 'real cold key identity'
[[ "${CNTOOLS_POOL_IDENTITIES[0]}" == 'Verified cold public key' ]] || fail 'not verified'
cntools_pool_inspect_catalog
CNTOOLS_SLOTS_PER_KES_PERIOD=129600 CNTOOLS_TIMEZONE=UTC
jq -n '{maxKESEvolutions:62,slotsPerKESPeriod:129600}' > "${TEST_ROOT}/genesis.json"
CNTOOLS_SHELLEY_GENESIS="${TEST_ROOT}/genesis.json"
cntools_health_reference_slot() { printf '%s\n' 129600; }
cntools_pool_health_collect 0 || fail 'real KES certificate diagnostics'
[[ "${CNTOOLS_POOL_CERT_DISK[0]}" == 0 && "${CNTOOLS_POOL_CERT_NEXT[0]}" == 1 &&
   "${CNTOOLS_POOL_KES_STATUS[0]}" == Healthy && "${CNTOOLS_POOL_KES_REMAINING[0]}" == 61 &&
   -n "${CNTOOLS_POOL_KES_EXPIRY[0]}" ]] || fail 'KES fields do not match pinned certificate'
cntools_health_reference_slot() { printf '%s\n' 8035200; }
cntools_pool_health_collect 0 || fail 'expired KES certificate diagnostics'
[[ "${CNTOOLS_POOL_KES_STATUS[0]}" == Expired && "${CNTOOLS_POOL_KES_REMAINING[0]}" == 0 ]] || fail 'KES expiry boundary'
cntools_pool_identity_rows 0 Y > "${TEST_ROOT}/rows"
[[ "$(cksum "${directory}"/*)" == "${before}" ]] || fail 'read-only pool artifacts changed'
[[ ! -e "${directory}/pool.id" && ! -e "${directory}/pool.id-bech32" ]] || fail 'inventory wrote identity files'
printf '%s\n' "${hex}" > "${directory}/pool.id"
printf '%s\n' "${expected}" > "${directory}/pool.id-bech32"
cntools_pool_catalog_build || fail 'matched cached identity'
[[ "${CNTOOLS_POOL_IDENTITIES[0]}" == 'Verified cold public key' ]] || fail 'matched stored ID rejected'
wrong="$(printf 'ab%.0s' {1..28})"
printf '%s\n' "${wrong}" > "${directory}/pool.id"
cntools_pool_catalog_build || fail 'conflicting identity browse'
[[ "${CNTOOLS_POOL_IDENTITIES[0]}" == 'Identity needs attention' ]] || fail 'wrong stored identity not flagged'
[[ "$(< "${directory}/pool.id")" == "${wrong}" ]] || fail 'wrong stored ID overwritten'
if cntools_pool_inspect_eligible 0; then fail 'conflicting pool chain lookup allowed'; fi
cntools_transaction_cleanup
[[ -f "${directory}/cold.skey" && -f "${directory}/op.cert" ]] || fail 'cleanup removed existing artifacts'
printf 'CNTools pinned pool inventory tests passed (cardano-cli %s).\n' "${version}"
