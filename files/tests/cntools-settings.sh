#!/usr/bin/env bash
# CNTools persistent transaction-setting tests.
# shellcheck disable=SC1090,SC2034

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools settings tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-settings.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"

cleanup_test() {
  chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="${3:-values differ}"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

for required in bash chmod jq mktemp mv rm wc; do
  command -v "${required}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required}"
done

CNTOOLS_NODE_HOME="${TEST_ROOT}/node"
mkdir -p "${CNTOOLS_NODE_HOME}"
chmod 0700 "${CNTOOLS_NODE_HOME}"

cntools_theme_private_path() {
  [[ -e "${1:-}" && ! -L "${1:-}" && -O "${1:-}" ]]
}

cntools_log() { :; }

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/settings.sh"

cntools_settings_init
assert_eq "${CNTOOLS_TX_SELECTION_STRATEGY}" balanced \
  "default selection strategy"
assert_eq "${CNTOOLS_TX_TOKEN_FRAGMENTATION}" N \
  "default token fragmentation"
assert_eq "${CNTOOLS_TX_UTXO_MANAGEMENT}" N \
  "default UTxO management"

CNTOOLS_TX_SELECTION_STRATEGY="fewest-inputs"
CNTOOLS_TX_TOKEN_FRAGMENTATION="Y"
CNTOOLS_TX_TOKEN_MAX_ASSETS=12
CNTOOLS_TX_UTXO_MANAGEMENT="Y"
CNTOOLS_TX_UTXO_TARGET_COUNT=6
CNTOOLS_TX_UTXO_PERCENTAGES="5,15,25"
CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
cntools_settings_save || fail "valid transaction settings could not be saved"
[[ -f "${CNTOOLS_SETTINGS_FILE}" && ! -L "${CNTOOLS_SETTINGS_FILE}" ]] ||
  fail "transaction settings were not saved as a regular file"
jq -e '
  .coinSelection.strategy == "fewest-inputs" and
  .tokenFragmentation.enabled == true and
  .tokenFragmentation.maxAssetsPerOutput == 12 and
  .utxoManagement.enabled == true and
  .utxoManagement.targetCount == 6 and
  .utxoManagement.percentages == [5,15,25]
' "${CNTOOLS_SETTINGS_FILE}" >/dev/null ||
  fail "saved transaction settings have the wrong schema or values"

cntools_settings_defaults
cntools_settings_reload || fail "saved transaction settings could not reload"
assert_eq "${CNTOOLS_TX_SELECTION_STRATEGY}" fewest-inputs \
  "persisted selection strategy"
assert_eq "${CNTOOLS_TX_TOKEN_MAX_ASSETS}" 12 \
  "persisted fragmentation limit"
assert_eq "${CNTOOLS_TX_UTXO_PERCENTAGES}" 5,15,25 \
  "persisted percentage ladder"

saved_settings="$(< "${CNTOOLS_SETTINGS_FILE}")"
CNTOOLS_TX_UTXO_TARGET_COUNT=99
if cntools_settings_save; then
  fail "invalid in-memory transaction settings were saved"
fi
assert_eq "$(< "${CNTOOLS_SETTINGS_FILE}")" "${saved_settings}" \
  "invalid save preserved the prior settings file"

printf '{"schemaVersion":1}\n' > "${CNTOOLS_SETTINGS_FILE}"
chmod 0600 "${CNTOOLS_SETTINGS_FILE}"
cntools_settings_init
assert_eq "${CNTOOLS_TX_SELECTION_STRATEGY}" balanced \
  "invalid settings fallback"
assert_eq "${CNTOOLS_TX_UTXO_MANAGEMENT}" N \
  "invalid settings safe fallback"

printf 'CNTools persistent settings tests passed\n'
