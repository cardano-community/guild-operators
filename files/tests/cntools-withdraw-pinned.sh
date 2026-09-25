#!/usr/bin/env bash
# Node-free integration: pass a checksum-verified deployment-pinned CLI binary.
# Invoked by cntools-transaction-pinned.sh in CI; no funds or device required.
# shellcheck disable=SC1090,SC2034,SC2154
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the verified pinned Cardano CLI binary}"
PINNED_HWCLI="${2:-}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-withdraw-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for lib in number wallet wallet-query utxo coin-selection change-plan transaction transaction-build transaction-sign transaction-files funds-withdraw; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
CNTOOLS_TMP_DIR="${TEST_ROOT}"
CNTOOLS_NODE_HOME="${TEST_ROOT}"
CNTOOLS_NETWORK=preview
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
CNTOOLS_STAKE_WALLET=pinned-withdraw
CNTOOLS_STAKE_WALLET_TYPE=CLI
CNTOOLS_STAKE_PAYMENT_VKEY="${TEST_ROOT}/payment.vkey"
CNTOOLS_STAKE_PAYMENT_SOURCE="${TEST_ROOT}/payment.skey"
CNTOOLS_STAKE_STAKE_VKEY="${TEST_ROOT}/stake.vkey"
CNTOOLS_STAKE_STAKE_SOURCE="${TEST_ROOT}/stake.skey"
CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_WITHDRAW_BACKEND=koios
CNTOOLS_WITHDRAW_EXPIRY=10000
CNTOOLS_TX_SELECTION_STRATEGY=balanced
CNTOOLS_TX_TOKEN_FRAGMENTATION=N
CNTOOLS_TX_UTXO_MANAGEMENT=N
CNTOOLS_TX_COLLATERAL_MANAGEMENT=N
version="$("${CNTOOLS_CLI}" version | head -1)"
version="${version#cardano-cli }"; version="${version%% *}"
found=N
for implementation in cnode dingo amaru; do
  pin="$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/${implementation}/release.json")"
  [[ "${version}" != "${pin}" ]] || found=Y
done
[[ "${found}" == Y ]] || fail "binary version ${version} is not a deployment pin"
"${CNTOOLS_CLI}" address key-gen --verification-key-file "${CNTOOLS_STAKE_PAYMENT_VKEY}" --signing-key-file "${CNTOOLS_STAKE_PAYMENT_SOURCE}"
"${CNTOOLS_CLI}" latest stake-address key-gen --verification-key-file "${CNTOOLS_STAKE_STAKE_VKEY}" --signing-key-file "${CNTOOLS_STAKE_STAKE_SOURCE}"
chmod 0600 "${TEST_ROOT}"/*.vkey "${TEST_ROOT}"/*.skey
CNTOOLS_STAKE_PAYMENT_CREDENTIAL="$("${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${CNTOOLS_STAKE_PAYMENT_VKEY}")"
CNTOOLS_STAKE_STAKE_CREDENTIAL="$("${CNTOOLS_CLI}" latest stake-address key-hash --stake-verification-key-file "${CNTOOLS_STAKE_STAKE_VKEY}")"
CNTOOLS_STAKE_BASE_ADDRESS="$("${CNTOOLS_CLI}" address build --payment-verification-key-file "${CNTOOLS_STAKE_PAYMENT_VKEY}" --stake-verification-key-file "${CNTOOLS_STAKE_STAKE_VKEY}" --testnet-magic 2)"
CNTOOLS_STAKE_REWARD_ADDRESS="$("${CNTOOLS_CLI}" latest stake-address build --stake-verification-key-file "${CNTOOLS_STAKE_STAKE_VKEY}" --testnet-magic 2)"
policy="$(printf 'ab%.0s' {1..28})"
reference="$(printf 'cd%.0s' {1..32})#0"
package=""; signed=""; saved=""
read -r -a scenarios <<< "${CNTOOLS_WITHDRAW_TEST_CASES:-ada tokens fragmented small-reward offline no-expiry}"
for scenario in "${scenarios[@]}"; do
  case "${scenario}" in ada|tokens|fragmented|small-reward|offline|no-expiry) ;; *) fail 'unknown scenario' ;; esac
  CNTOOLS_WITHDRAW_EXPIRY=10000
  [[ "${scenario}" != no-expiry ]] || CNTOOLS_WITHDRAW_EXPIRY=""
  cntools_utxo_reset
  cntools_utxo_add "${reference}" "${CNTOOLS_STAKE_BASE_ADDRESS}" 20000000
  CNTOOLS_WITHDRAW_REWARDS=10000000
  CNTOOLS_TX_TOKEN_FRAGMENTATION=N; CNTOOLS_TX_UTXO_MANAGEMENT=N
  if [[ "${scenario}" == tokens || "${scenario}" == fragmented ]]; then
    cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
    cntools_utxo_add_asset 0 "${policy}.02" 7
  fi
  if [[ "${scenario}" == fragmented ]]; then
    CNTOOLS_TX_TOKEN_FRAGMENTATION=Y; CNTOOLS_TX_TOKEN_MAX_ASSETS=1
    CNTOOLS_TX_UTXO_MANAGEMENT=Y; CNTOOLS_TX_COLLATERAL_MANAGEMENT=Y
    CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1; CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
    CNTOOLS_TX_UTXO_TARGET_COUNT=4; CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30
    CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3; CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000
  fi
  [[ "${scenario}" != small-reward ]] || CNTOOLS_WITHDRAW_REWARDS=1
  CNTOOLS_STAKE_PAYMENT_SOURCE="${TEST_ROOT}/payment.skey"
  CNTOOLS_STAKE_STAKE_SOURCE="${TEST_ROOT}/stake.skey"
  if [[ "${scenario}" == offline ]]; then
    CNTOOLS_STAKE_PAYMENT_SOURCE=''; CNTOOLS_STAKE_STAKE_SOURCE=''
  fi
  if ! cntools_withdraw_build_into package; then
    tail -30 "${TEST_ROOT}/test.log" >&2
    fail "${scenario}: ${CNTOOLS_TRANSACTION_ERROR}"
  fi
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 2 ]] || fail 'withdrawal needs payment and stake witnesses'
  jq -e 'any(.signing.required[]; .roles | index("withdrawal"))' "${package}" >/dev/null || fail 'withdrawal signer role'
  jq -e '(.certificates == null or .certificates == []) and (.withdrawals | length == 1)' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}" >/dev/null || fail 'withdrawal body or unexpected certificates'
  [[ "${CNTOOLS_TRANSACTION_UI_VIEW}" == *"${CNTOOLS_WITHDRAW_REWARDS} Lovelace"* ]] || fail 'withdrawal amount'
  if [[ "${scenario}" == tokens || "${scenario}" == fragmented ]]; then
    [[ "${CNTOOLS_TRANSACTION_UI_VIEW}" == *9007199254740993* ]] || fail 'rounded native asset quantity'
  fi
  if [[ -n "${PINNED_HWCLI}" ]]; then
    "${PINNED_HWCLI}" transaction transform --tx-file "${CNTOOLS_TRANSACTION_BODY_FILE}" --out-file "${TEST_ROOT}/${scenario}.hw"
    "${CNTOOLS_CLI}" debug transaction view --output-json --tx-file "${TEST_ROOT}/${scenario}.hw" > "${TEST_ROOT}/${scenario}.hw-view"
    cmp -s <(jq -Sc . <<< "${CNTOOLS_TRANSACTION_UI_VIEW}") <(jq -Sc . "${TEST_ROOT}/${scenario}.hw-view") || fail 'hardware transform changed withdrawal semantics'
  fi
  sum="$(jq '[.outputs[].amount.lovelace] | add' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}")"
  if [[ "${scenario}" == no-expiry ]]; then
    jq -e '.validity.invalidHereafter == null' "${package}" >/dev/null || fail 'No expiry package has an upper bound'
    jq -e '.["validity range"]["upper bound"] == null' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}" >/dev/null || fail 'No expiry body has an upper bound'
  fi
  (( sum + CNTOOLS_WITHDRAW_FEE == 20000000 + CNTOOLS_WITHDRAW_REWARDS )) || {
    printf '%s\n' "${CNTOOLS_TRANSACTION_UI_VIEW}" >&2
    tail -25 "${TEST_ROOT}/test.log" >&2
    fail "withdrawal ADA conservation / double-counted rewards sum=${sum} fee=${CNTOOLS_WITHDRAW_FEE}"
  }
  if [[ "${scenario}" == fragmented ]]; then
    (( $(jq '.outputs | length' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}") >= 4 )) || fail 'fragmentation and ADA management not applied'
  fi
  if [[ "${scenario}" == offline ]]; then
    unsigned_saved=''
    cntools_transaction_save_into unsigned_saved "${package}" unsigned withdraw-rewards
    cntools_transaction_package_load "${unsigned_saved}"
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == N ]] || fail 'unsigned package incorrectly complete'
    cntools_transaction_cleanup
    [[ -f "${unsigned_saved}" ]] || fail 'cleanup removed unsigned export'
    printf 'Passed pinned withdrawal scenario: %s (%s).\n' "${scenario}" "${version}"
    continue
  fi
  cntools_transaction_signed_path_into signed
  cntools_transaction_sign_registered "${package}" "${signed}" || fail "shared signing: ${CNTOOLS_TRANSACTION_ERROR}"
  cntools_transaction_package_load "${signed}"
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'incomplete signed withdrawal'
  cntools_transaction_save_into saved "${signed}" signed withdraw-rewards
  [[ -f "${saved}" && ! -e "${signed}" ]] || fail 'durable export publication'
  cntools_transaction_package_load "${saved}"
  cntools_transaction_cleanup
  [[ -f "${saved}" ]] || fail 'cleanup removed saved package'
  printf 'Passed pinned withdrawal scenario: %s (%s).\n' "${scenario}" "${version}"
done
printf 'Pinned withdrawal build/sign tests passed (cardano-cli %s).\n' "${version}"
