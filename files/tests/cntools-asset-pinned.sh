#!/usr/bin/env bash
# Real, node-free native mint/burn build/sign tests against the cnode pin.
# shellcheck disable=SC1090,SC2034,SC2154
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass pinned cardano-cli}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-asset-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
fail() { tail -100 "${TEST_ROOT}/log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for lib in number wallet wallet-key wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query utxo coin-selection change-plan transaction transaction-build transaction-sign transaction-files transaction-funding wallet-payment funds-send transaction-metadata policy-files policy policy-catalog asset-transaction; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong cnode pin'
CNTOOLS_ASSET_DIR="${TEST_ROOT}/assets"; mkdir -m700 "${CNTOOLS_ASSET_DIR}" "${CNTOOLS_ASSET_DIR}/Policy"
CNTOOLS_ASSET_TX_DIRECTORY="${CNTOOLS_ASSET_DIR}/Policy"
CNTOOLS_SEND_WALLET=AssetTest CNTOOLS_SEND_TYPE=CLI CNTOOLS_SEND_DIRECTORY="${TEST_ROOT}"
CNTOOLS_SEND_VKEY="${TEST_ROOT}/payment.vkey" CNTOOLS_SEND_SOURCE="${TEST_ROOT}/payment.skey"
"${CNTOOLS_CLI}" address key-gen --verification-key-file "${CNTOOLS_SEND_VKEY}" --signing-key-file "${CNTOOLS_SEND_SOURCE}"
"${CNTOOLS_CLI}" address key-gen --verification-key-file "${CNTOOLS_ASSET_TX_DIRECTORY}/policy.vkey" --signing-key-file "${CNTOOLS_ASSET_TX_DIRECTORY}/policy.skey"
chmod 600 "${CNTOOLS_SEND_VKEY}" "${CNTOOLS_SEND_SOURCE}" "${CNTOOLS_ASSET_TX_DIRECTORY}"/*
CNTOOLS_SEND_CREDENTIAL="$("${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${CNTOOLS_SEND_VKEY}")"
CNTOOLS_SEND_ADDRESS="$("${CNTOOLS_CLI}" address build --payment-verification-key-file "${CNTOOLS_SEND_VKEY}" --testnet-magic 2)"
CNTOOLS_SEND_PAYMENT="${CNTOOLS_SEND_ADDRESS}"
hash="$("${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${CNTOOLS_ASSET_TX_DIRECTORY}/policy.vkey")"
jq -n --arg h "${hash}" '{type:"all",scripts:[{type:"sig",keyHash:$h},{type:"before",slot:20000}]}' > "${CNTOOLS_ASSET_TX_DIRECTORY}/policy.script"
"${CNTOOLS_CLI}" hash script --script-file "${CNTOOLS_ASSET_TX_DIRECTORY}/policy.script" > "${CNTOOLS_ASSET_TX_DIRECTORY}/policy.id"
cntools_policy_prepare "${CNTOOLS_ASSET_TX_DIRECTORY}" || fail "prepare: ${CNTOOLS_POLICY_ERROR}"
CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30 CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000 CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1 CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
reference="$(printf 'cd%.0s' {1..32})" other="$(printf 'ab%.0s' {1..28})"
package='' signed='' saved='' hex='' lifetime=1800
cntools_policy_asset_name_into hex text 'Token' || fail 'text name'
[[ "${hex}" == 546f6b656e ]] || fail 'text encoding'
scenarios=(mint burn burn-all empty-name shaped offline)
(( $# < 2 )) || scenarios=("${@:2}")
for scenario in "${scenarios[@]}"; do
  cntools_metadata_reset
  cntools_policy_prepare "${CNTOOLS_ASSET_TX_DIRECTORY}" || fail 'fresh policy snapshot'
  CNTOOLS_FUNDING_SLOT=1000 CNTOOLS_FUNDING_BACKEND=local CNTOOLS_SEND_SOURCE="${TEST_ROOT}/payment.skey"
  CNTOOLS_ASSET_TX_OPERATION=mint CNTOOLS_ASSET_TX_ID="${CNTOOLS_POLICY_ID}.${hex}" CNTOOLS_ASSET_TX_QUANTITY=3
  CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N
  [[ "${scenario}" != empty-name ]] || CNTOOLS_ASSET_TX_ID="${CNTOOLS_POLICY_ID}."
  cntools_utxo_reset
  cntools_utxo_add "${reference}#0" "${CNTOOLS_SEND_ADDRESS}" 30000000
  cntools_utxo_add_asset 0 "${other}.01" 9007199254740993
  cntools_utxo_add "${reference}#1" "${CNTOOLS_SEND_ADDRESS}" 5000000 Y N
  if [[ "${scenario}" == burn* ]]; then
    CNTOOLS_ASSET_TX_OPERATION=burn
    cntools_utxo_add_asset 0 "${CNTOOLS_ASSET_TX_ID}" 10
    [[ "${scenario}" != burn-all ]] || CNTOOLS_ASSET_TX_QUANTITY=10
  fi
  if [[ "${scenario}" == shaped ]]; then
    CNTOOLS_TX_TOKEN_FRAGMENTATION=Y CNTOOLS_TX_TOKEN_MAX_ASSETS=1 CNTOOLS_TX_UTXO_MANAGEMENT=Y CNTOOLS_TX_COLLATERAL_MANAGEMENT=Y
    cntools_transaction_temp_file CNTOOLS_METADATA_MESSAGE asset-message
    printf '%s\n' '{"msg":["Minted in pinned test"]}' > "${CNTOOLS_METADATA_MESSAGE}"
  fi
  [[ "${scenario}" != offline ]] || { CNTOOLS_SEND_SOURCE=''; CNTOOLS_POLICY_SELECTED_SOURCE=''; }
  cntools_asset_tx_eligible_inventory || fail 'eligible inventory'
  [[ "${CNTOOLS_ASSET_TX_SKIPPED}" == 1 ]] || fail 'datum exclusion'
  cntools_asset_tx_validity 0 || fail 'policy TTL'
  [[ "${CNTOOLS_SEND_EXPIRY}" == 20000 ]] || fail 'No expiry ignored policy bound'
  cntools_asset_tx_build_into package || fail "${scenario}: ${CNTOOLS_TRANSACTION_ERROR}"
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 2 ]] || fail 'payment and policy witness count'
  if [[ "${scenario}" == shaped ]]; then
    view=''; cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
    [[ "${view}" == *'Minted in pinned test'* ]] || fail 'mint metadata not attached'
  fi
  if [[ "${scenario}" == offline ]]; then
    cntools_transaction_save_into saved "${package}" unsigned mint-asset || fail 'offline export'
    [[ -f "${saved}" ]] || fail 'offline package missing'
    cntools_transaction_cleanup
    sources=("${TEST_ROOT}/payment.skey" "${CNTOOLS_ASSET_TX_DIRECTORY}/policy.skey"); changes=()
    signed="${TEST_ROOT}/offline.complete.json"
    cntools_transaction_sign_package "${saved}" "${signed}" sources changes || fail 'portable offline policy/wallet signing'
    cntools_transaction_package_load "${signed}" || fail 'offline signed package'
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'offline import missing witness'
  else
    signed="${TEST_ROOT}/${scenario}.signed.json"
    cntools_transaction_sign_registered "${package}" "${signed}" || fail "sign: ${CNTOOLS_TRANSACTION_ERROR}"
    cntools_transaction_package_load "${signed}" || fail 'signed package'
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'missing witness'
    size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
    ((CNTOOLS_ASSET_TX_FEE == 155381+44*(size-1))) || fail 'fee does not equal the actual signed minimum'
  fi
  printf 'Pinned asset transaction passed: %s CLI=%s\n' "${scenario}" "${pin}"
done
CNTOOLS_FUNDING_SLOT=20000
! cntools_asset_tx_validity 1800 || fail 'expired policy accepted'
cntools_transaction_cleanup
[[ -z "${saved}" || -f "${saved}" ]] || fail 'cleanup removed offline export'
