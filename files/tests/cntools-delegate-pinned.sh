#!/usr/bin/env bash
# Node-free delegation and stake lifecycle builds using a verified deployment pin.
# shellcheck disable=SC1090,SC2034,SC2154
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the verified pinned CLI binary}"
PINNED_HWCLI="${2:-}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-delegate-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
fail() { tail -15 "${TEST_ROOT}/test.log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for lib in number wallet wallet-query utxo coin-selection change-plan transaction transaction-build transaction-sign transaction-files wallet-register pool-id funds-delegate drep-id governance-delegate; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
cntools_funding_tip_into() { printf -v "$1" '%s' 1000; }
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
CNTOOLS_WALLET_REGISTER_WALLET=pinned-delegate CNTOOLS_WALLET_REGISTER_WALLET_TYPE=CLI
CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY="${TEST_ROOT}/payment.vkey"
CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${TEST_ROOT}/payment.skey"
CNTOOLS_WALLET_REGISTER_STAKE_VKEY="${TEST_ROOT}/stake.vkey"
CNTOOLS_WALLET_REGISTER_STAKE_SOURCE="${TEST_ROOT}/stake.skey"
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4 CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
found=N
for implementation in cnode dingo amaru; do
  pin="$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/${implementation}/release.json")"
  [[ "${version}" != "${pin}" ]] || found=Y
done
[[ "${found}" == Y ]] || fail 'CLI is not a deployment pin'
"${CNTOOLS_CLI}" address key-gen --verification-key-file "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" --signing-key-file "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}"
"${CNTOOLS_CLI}" latest stake-address key-gen --verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" --signing-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_SOURCE}"
chmod 0600 "${TEST_ROOT}"/*.vkey "${TEST_ROOT}"/*.skey
CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL="$("${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}")"
CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL="$("${CNTOOLS_CLI}" latest stake-address key-hash --stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}")"
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS="$("${CNTOOLS_CLI}" address build --payment-verification-key-file "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" --stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" --testnet-magic 2)"
CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS="${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}"
CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS="$("${CNTOOLS_CLI}" latest stake-address build --stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" --testnet-magic 2)"
public="$(printf '00%.0s' {1..32})"
pool="$("${CNTOOLS_CLI}" latest stake-pool id --stake-pool-verification-key "${public}" --output-bech32)"
pool_hex="$("${CNTOOLS_CLI}" latest stake-pool id --stake-pool-verification-key "${public}" --output-hex)"
cntools_pool_id_into CNTOOLS_DELEGATE_POOL_ID CNTOOLS_DELEGATE_POOL_HEX "${pool}"
[[ "${CNTOOLS_DELEGATE_POOL_HEX}" == "${pool_hex}" ]] || fail 'pool hash conversion disagrees with CLI'
policy="$(printf 'ab%.0s' {1..28})" reference="$(printf 'cd%.0s' {1..32})#0"
package="" signed="" sum="" fee=""
scenarios=(yes no register-ada register-token deregister-ada deregister-token vote-key vote-script vote-abstain vote-no-confidence)
if (( $# > 2 )); then scenarios=("${@:3}"); fi
for registered in "${scenarios[@]}"; do
  cntools_wallet_register_operation_set delegate
  cntools_wallet_register_reset_chain_state
  CNTOOLS_WALLET_REGISTERED="${registered}"
  [[ "${registered}" != register-* ]] || CNTOOLS_WALLET_REGISTERED=no
  [[ "${registered}" != deregister-* ]] || CNTOOLS_WALLET_REGISTERED=yes
  [[ "${registered}" != vote-* ]] || CNTOOLS_WALLET_REGISTERED=yes
  cntools_delegate_chain_state_validate
  CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=Y
  CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_SOURCE='Fixture'
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0 CNTOOLS_WALLET_REGISTER_LIFETIME=1800
  if [[ "${registered}" == no ]]; then
    CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000 CNTOOLS_WALLET_REGISTER_LIFETIME=0
  fi
  if [[ "${registered}" == register-* ]]; then
    cntools_wallet_register_operation_set register
    CNTOOLS_WALLET_REGISTERED=no CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000
    [[ "${registered}" != register-token ]] || CNTOOLS_WALLET_REGISTER_LIFETIME=0
  fi
  if [[ "${registered}" == deregister-* ]]; then
    cntools_wallet_register_operation_set deregister
    # Historical deposit intentionally differs from the protocol's current 2 ADA.
    CNTOOLS_WALLET_STAKE_DEPOSIT=2345678 CNTOOLS_WALLET_REWARD_LOVELACE=0
    cntools_wallet_register_chain_state_validate || fail 'deregistration state rejected'
    CNTOOLS_WALLET_REGISTER_DEPOSIT="${CNTOOLS_WALLET_STAKE_DEPOSIT}"
    [[ "${registered}" != deregister-token ]] || CNTOOLS_WALLET_REGISTER_LIFETIME=0
  fi
  if [[ "${registered}" == vote-* ]]; then
    cntools_wallet_register_operation_set vote-delegate
    cntools_vote_chain_state_validate || fail 'voting stake state rejected'
    target="drep_always_${registered#vote-}"
    case "${registered}" in
      vote-key)
        target="$("${CNTOOLS_CLI}" latest governance drep id --drep-key-hash "${pool_hex}" --output-cip129)"
        cntools_drep_bech32_into encoded "22${pool_hex}"
        [[ "${encoded}" == "${target}" ]] || fail 'CIP129 encoding disagrees with pinned CLI'
        legacy="$("${CNTOOLS_CLI}" latest governance drep id --drep-key-hash "${pool_hex}" --output-bech32)"
        cntools_drep_id_into normalized kind hash "${legacy}"
        [[ "${normalized}" == "${target}" && "${kind}" == key && "${hash}" == "${pool_hex}" ]] || fail 'legacy CLI ID normalization'
        ;;
      vote-script) cntools_drep_bech32_into target "23${pool_hex}" ;;
      vote-no-confidence) target=drep_always_no_confidence; CNTOOLS_WALLET_REGISTER_LIFETIME=0 ;;
    esac
    cntools_drep_id_into CNTOOLS_VOTE_TARGET CNTOOLS_VOTE_KIND CNTOOLS_VOTE_HASH "${target}" || fail 'voting target ID'
  fi
  cntools_utxo_add "${reference}" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" 20000000
  if [[ "${registered}" != *-ada ]]; then cntools_utxo_add_asset 0 "${policy}.01" 5; fi
  cntools_wallet_register_inventory_use_all
  cntools_wallet_register_select_inputs || fail 'selection failed'
  cntools_wallet_register_build_package_into package || fail "build: ${CNTOOLS_WALLET_REGISTER_ERROR} ${CNTOOLS_TRANSACTION_ERROR}"
  cntools_transaction_package_load "${package}" || fail 'package validation failed'
  validator=cntools_delegate_validate_body
  [[ "${registered}" != register-* && "${registered}" != deregister-* ]] || validator=cntools_wallet_register_validate_body
  [[ "${registered}" != vote-* ]] || validator=cntools_vote_validate_body
  "${validator}" "${CNTOOLS_TRANSACTION_BODY_FILE}" || fail 'body check failed'
  cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
  sum="$(jq '[.outputs[].amount.lovelace] | add' <<< "${view}")"
  fee="$(jq -r '.fee | split(" ")[0]' <<< "${view}")"
  if [[ "${registered}" == deregister-* ]]; then
    (( sum + fee == 20000000 + CNTOOLS_WALLET_REGISTER_DEPOSIT )) || fail "refund conservation: outputs=${sum} fee=${fee} refund=${CNTOOLS_WALLET_REGISTER_DEPOSIT}"
  else
    (( sum + fee + CNTOOLS_WALLET_REGISTER_DEPOSIT == 20000000 )) || fail "deposit/fee conservation: outputs=${sum} fee=${fee} deposit=${CNTOOLS_WALLET_REGISTER_DEPOSIT}"
  fi
  expected_tokens=5
  [[ "${registered}" != *-ada ]] || expected_tokens=0
  jq -e --arg policy "${policy}" --argjson expected "${expected_tokens}" '[.outputs[].amount["policy " + $policy]["asset 01"] // 0] | add == $expected' <<< "${view}" >/dev/null || fail 'token quantity not preserved'
  if [[ "${CNTOOLS_WALLET_REGISTER_LIFETIME}" == 0 ]]; then
    [[ -z "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" ]] || fail 'No expiry gained an upper bound'
  else
    [[ "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" == 2800 ]] || fail 'wrong upper bound'
  fi
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 2 ]] || fail 'expected payment and stake witnesses'
  if [[ -n "${PINNED_HWCLI}" ]]; then
    "${PINNED_HWCLI}" transaction transform --tx-file "${CNTOOLS_TRANSACTION_BODY_FILE}" --out-file "${TEST_ROOT}/${registered}.hw"
    "${validator}" "${TEST_ROOT}/${registered}.hw" || fail 'hardware transform changed certificate'
  fi
  signed="${TEST_ROOT}/${registered}.signed.json"
  cntools_transaction_sign_registered "${package}" "${signed}" || fail "sign: ${CNTOOLS_TRANSACTION_ERROR}"
  cntools_transaction_package_load "${signed}" || fail 'signed package validation failed'
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'missing delegation witnesses'
  printf 'Pinned stake transaction passed: scenario=%s CLI=%s\n' "${registered}" "${version}"
done
