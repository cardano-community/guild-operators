#!/usr/bin/env bash
# Real, node-free collection build/sign tests using deployment-pinned binaries.
# shellcheck disable=SC1090,SC2034,SC2154
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the verified pinned CLI binary}"
PINNED_HWCLI="${2:-}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-collect-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
fail() { tail -15 "${TEST_ROOT}/test.log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for lib in number wallet wallet-query utxo coin-selection change-plan transaction transaction-build transaction-sign transaction-files wallet-payment funds-send funds-collect; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
CNTOOLS_SEND_WALLET=pinned-collect CNTOOLS_SEND_TYPE=CLI CNTOOLS_SEND_DIRECTORY="${TEST_ROOT}"
CNTOOLS_SEND_VKEY="${TEST_ROOT}/payment.vkey" CNTOOLS_SEND_SOURCE="${TEST_ROOT}/payment.skey"
CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_COLLECT_BACKEND=koios
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "${version}" == "${pin}" ]] || fail 'CLI is not the cnode deployment pin'
"${CNTOOLS_CLI}" address key-gen --verification-key-file "${CNTOOLS_SEND_VKEY}" --signing-key-file "${CNTOOLS_SEND_SOURCE}"
chmod 0600 "${CNTOOLS_SEND_VKEY}" "${CNTOOLS_SEND_SOURCE}"
CNTOOLS_SEND_CREDENTIAL="$("${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${CNTOOLS_SEND_VKEY}")"
CNTOOLS_SEND_ADDRESS="$("${CNTOOLS_CLI}" address build --payment-verification-key-file "${CNTOOLS_SEND_VKEY}" --testnet-magic 2)"
CNTOOLS_SEND_PAYMENT="${CNTOOLS_SEND_ADDRESS}"
policy="$(printf 'ab%.0s' {1..28})" reference="$(printf 'cd%.0s' {1..32})"
package="" signed="" saved="" view=""
scenarios=(ada tokens shaped offline)
if (( $# > 2 )); then scenarios=("${@:3}"); fi
for scenario in "${scenarios[@]}"; do
  CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
  CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4
  CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30 CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000 CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
  CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1 CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
  CNTOOLS_COLLECT_SCOPE=ada CNTOOLS_SEND_EXPIRY=10000 CNTOOLS_SEND_SOURCE="${TEST_ROOT}/payment.skey"
  cntools_utxo_reset
  cntools_utxo_add "${reference}#0" "${CNTOOLS_SEND_ADDRESS}" 10000000
  cntools_utxo_add "${reference}#1" "${CNTOOLS_SEND_ADDRESS}" 20000000
  cntools_utxo_add "${reference}#2" "${CNTOOLS_SEND_ADDRESS}" 5000000 Y N
  cntools_utxo_add "${reference}#3" "${CNTOOLS_SEND_ADDRESS}" 5000000 N Y
  if [[ "${scenario}" == tokens || "${scenario}" == shaped ]]; then
    CNTOOLS_COLLECT_SCOPE=all CNTOOLS_SEND_EXPIRY=""
    cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
    cntools_utxo_add_asset 1 "${policy}.02" 7
  fi
  if [[ "${scenario}" == shaped ]]; then
    CNTOOLS_TX_TOKEN_FRAGMENTATION=Y CNTOOLS_TX_TOKEN_MAX_ASSETS=1
    CNTOOLS_TX_UTXO_MANAGEMENT=Y CNTOOLS_TX_COLLATERAL_MANAGEMENT=Y
  fi
  [[ "${scenario}" != offline ]] || CNTOOLS_SEND_SOURCE=""
  cntools_collect_build_into package || fail "${scenario}: ${CNTOOLS_TRANSACTION_ERROR}"
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 1 ]] || fail 'collection should need only the payment witness'
  [[ "${#CNTOOLS_COLLECT_INPUTS[@]}" == 2 && "${CNTOOLS_COLLECT_SKIPPED}" == 2 ]] || fail 'unsafe input exclusion'
  cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
  sum="$(jq '[.outputs[].amount.lovelace] | add' <<< "${view}")"
  (( sum + CNTOOLS_COLLECT_FEE == 30000000 )) || fail 'ADA conservation'
  jq -e --arg a "${reference}#0" --arg b "${reference}#1" '(.inputs | sort) == ([$a,$b]|sort)' <<< "${view}" >/dev/null || fail 'wrong spending inputs'
  if [[ "${scenario}" == tokens || "${scenario}" == shaped ]]; then
    [[ "${view}" == *9007199254740993* ]] || fail 'large token quantity rounded'
    jq -e --arg p "${policy}" '[.outputs[].amount["policy " + $p]["asset 02"] // 0] | add == 7' <<< "${view}" >/dev/null || fail 'token quantity lost'
    [[ -z "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" ]] || fail 'No expiry gained a bound'
  else
    [[ "${CNTOOLS_COLLECT_OUTPUT_COUNT}" == 1 ]] || fail 'ADA consolidation did not produce one output'
    [[ "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" == 10000 ]] || fail 'expiry lost'
  fi
  [[ "${scenario}" != shaped ]] || (( CNTOOLS_COLLECT_OUTPUT_COUNT >= 4 )) || fail 'change policies not applied'
  if [[ -n "${PINNED_HWCLI}" ]]; then
    "${PINNED_HWCLI}" transaction transform --tx-file "${CNTOOLS_TRANSACTION_BODY_FILE}" --out-file "${TEST_ROOT}/${scenario}.hw"
    cntools_collect_validate_body "${TEST_ROOT}/${scenario}.hw" || fail 'hardware transform changed semantics'
  fi
  if [[ "${scenario}" == offline ]]; then
    cntools_transaction_save_into saved "${package}" unsigned collect-utxos || fail 'offline export'
    cntools_transaction_cleanup
    [[ -f "${saved}" ]] || fail 'cleanup removed offline export'
  else
    signed="${TEST_ROOT}/${scenario}.signed.json"
    cntools_transaction_sign_registered "${package}" "${signed}" || fail "sign: ${CNTOOLS_TRANSACTION_ERROR}"
    cntools_transaction_package_load "${signed}" || fail 'signed package'
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'missing payment witness'
  fi
  printf 'Pinned collection passed: %s CLI=%s\n' "${scenario}" "${version}"
done
