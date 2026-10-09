#!/usr/bin/env bash
# Node-free DRep lifecycle integration using only the cnode deployment CLI pin.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the checksum-verified cnode CLI binary}"
PINNED_HWCLI="${2:-}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-drep-lifecycle.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'chmod -R u+rwX "${TEST_ROOT}"; rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
fail() { printf 'FAIL: %s (%s / %s)\n' "$*" "${CNTOOLS_WALLET_REGISTER_ERROR:-}" "${CNTOOLS_TRANSACTION_ERROR:-}" >&2; tail -15 "${TEST_ROOT}/test.log" >&2; exit 1; }
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "${version}" == "${pin}" ]] || fail 'CLI is not the cnode deployment pin'
for lib in number wallet wallet-material wallet-key wallet-mnemonic wallet-address wallet-id wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query utxo coin-selection change-plan recipient wallet-payment transaction transaction-build transaction-sign transaction-files wallet-register drep-id drep-query drep-key governance-drep; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_log_sanitize_line() { printf '%s' "${1//[[:cntrl:]]/ }"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
cntools_funding_tip_into() { printf -v "$1" '%s' 1000; }
# GNU option compatibility on macOS; production targets remain Linux.
REAL_CHMOD="$(type -P chmod)" REAL_LN="$(type -P ln)"
chmod() { local arg=""; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
ln() { if [[ "${1:-}" == -T ]]; then shift; [[ ! -d "${3}" ]] || return 1; fi; "${REAL_LN}" "$@"; }
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview
CNTOOLS_WALLET_DIR="${TEST_ROOT}"
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey
CNTOOLS_WALLET_PAY_ADDR_FILENAME=payment.addr CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey
CNTOOLS_WALLET_STAKE_ADDR_FILENAME=stake.addr CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path
CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME=payment-script.cred CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME=stake-script.cred
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_DREP_VKEY_FILENAME=drep.vkey CNTOOLS_WALLET_DREP_SKEY_FILENAME=drep.skey
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4 CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30
CNTOOLS_WALLET_REGISTER_LIFETIME=1800
wallet="${TEST_ROOT}/wallet"; mkdir "${wallet}"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${wallet}/payment.skey" --verification-key-file "${wallet}/payment.vkey"
"${CNTOOLS_CLI}" latest governance drep key-gen --signing-key-file "${wallet}/drep.skey" --verification-key-file "${wallet}/drep.vkey"
chmod 600 "${wallet}"/*
cntools_wallet_register_operation_set drep-register
cntools_wallet_register_prepare_wallet "${wallet}" test-drep || fail 'prepare payment-only wallet'
[[ "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" == "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" &&
   "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" == Y ]] || fail 'payment-only funding or signing'
reference="$(printf 'ab%.0s' {1..32})#0" policy="$(printf 'cd%.0s' {1..28})"
package="" signed="" view="" hash="" sum="" fee="" expected=""
printf '{"body":{"givenName":"Test DRep"}}\n' > "${TEST_ROOT}/metadata.json"
cntools_drep_lifecycle_hash_file_into hash "${TEST_ROOT}/metadata.json" || fail 'hash metadata'
expected="$("${CNTOOLS_CLI}" latest governance drep metadata-hash --drep-metadata-file "${TEST_ROOT}/metadata.json")"
[[ "${hash}" == "${expected}" ]] || fail 'anchor hash'
read -r -a scenarios <<< "${CNTOOLS_DREP_TEST_SCENARIOS:-ada tokens no-anchor offline zero-deposit extended}"
for scenario in "${scenarios[@]}"; do
  case "${scenario}" in ada|tokens|no-anchor|offline|zero-deposit|extended) ;; *) fail 'unknown DRep test scenario' ;; esac
done
for operation in drep-register drep-update drep-retire; do
  for scenario in "${scenarios[@]}"; do
    # A registration deposit cannot be assumed zero, but zero historical refunds
    # and a zero future protocol deposit are both handled exactly.
    cntools_wallet_register_operation_set "${operation}"
    cntools_wallet_register_reset_chain_state
    CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_SOURCE=Fixture
    CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
    CNTOOLS_WALLET_REGISTER_DEPOSIT=0
    case "${operation}" in drep-register) CNTOOLS_WALLET_REGISTER_DEPOSIT=500000000 ;; drep-retire) CNTOOLS_WALLET_REGISTER_DEPOSIT=450000000 ;; esac
    [[ "${scenario}" != zero-deposit ]] || CNTOOLS_WALLET_REGISTER_DEPOSIT=0
    CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='https://example.invalid/drep.json' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="${hash}"
    if [[ "${scenario}" == no-anchor || "${operation}" == drep-retire ]]; then
      CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''
    fi
    CNTOOLS_DREP_LIFECYCLE_SOURCE="${wallet}/drep.skey" CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${wallet}/payment.skey"
    if [[ "${scenario}" == extended ]]; then
      phrase="$("${CNTOOLS_CLI}" key generate-mnemonic --size 24)"
      "${CNTOOLS_CLI}" key derive-from-mnemonic --drep-key --account-number 0 --mnemonic-from-interactive-prompt --signing-key-file "${wallet}/extended.skey" <<< "${phrase}" >/dev/null
      "${CNTOOLS_CLI}" key verification-key --signing-key-file "${wallet}/extended.skey" --verification-key-file "${wallet}/extended.vkey"
      "${CNTOOLS_CLI}" key non-extended-key --extended-verification-key-file "${wallet}/extended.vkey" --verification-key-file "${wallet}/extended-normal.vkey"
      CNTOOLS_DREP_LIFECYCLE_SOURCE="${wallet}/extended.skey" CNTOOLS_DREP_LIFECYCLE_VKEY="${wallet}/extended-normal.vkey"
    else
      CNTOOLS_DREP_LIFECYCLE_VKEY="${wallet}/drep.vkey"
    fi
    CNTOOLS_DREP_LIFECYCLE_ID="$("${CNTOOLS_CLI}" latest governance drep id --drep-verification-key-file "${CNTOOLS_DREP_LIFECYCLE_VKEY}" --output-cip129)"
    cntools_drep_id_into normalized kind CNTOOLS_DREP_LIFECYCLE_HASH "${CNTOOLS_DREP_LIFECYCLE_ID}"
    if [[ "${scenario}" == offline ]]; then CNTOOLS_DREP_LIFECYCLE_SOURCE=''; CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=''; fi
    CNTOOLS_WALLET_REGISTER_LIFETIME=1800
    [[ "${scenario}" != no-anchor ]] || CNTOOLS_WALLET_REGISTER_LIFETIME=0
    cntools_utxo_add "${reference}" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" 600000000
    [[ "${scenario}" != tokens ]] || cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
    cntools_wallet_register_inventory_use_all
    cntools_wallet_register_select_inputs || fail 'select inputs'
    cntools_wallet_register_build_package_into package || fail "build ${operation}/${scenario}"
    cntools_transaction_package_load "${package}" || fail 'load package'
    cntools_drep_lifecycle_validate_body "${CNTOOLS_TRANSACTION_BODY_FILE}" || fail 'validate certificate'
    [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 2 ]] || fail 'payment and DRep witnesses required'
    if [[ -n "${PINNED_HWCLI}" ]]; then
      "${PINNED_HWCLI}" transaction transform --tx-file "${CNTOOLS_TRANSACTION_BODY_FILE}" --out-file "${TEST_ROOT}/hw.body"
      cntools_drep_lifecycle_validate_body "${TEST_ROOT}/hw.body" || fail 'hardware transformation changed certificate'
    fi
    cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
    sum="$(jq '[.outputs[].amount.lovelace] | add' <<< "${view}")"
    fee="$(jq -r '.fee | split(" ")[0]' <<< "${view}")"
    if [[ "${operation}" == drep-retire ]]; then
      (( sum + fee == 600000000 + CNTOOLS_WALLET_REGISTER_DEPOSIT )) || fail 'refund conservation'
    else
      (( sum + fee + CNTOOLS_WALLET_REGISTER_DEPOSIT == 600000000 )) || fail 'deposit conservation'
    fi
    [[ "${scenario}" != tokens || "${view}" == *9007199254740993* ]] || fail 'token precision/conservation'
    if [[ "${scenario}" == offline ]]; then
      [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == N ]] || fail 'unsigned unexpectedly complete'
      printf 'Pinned DRep passed: %s/%s\n' "${operation}" "${scenario}"
      continue
    fi
    signed="${TEST_ROOT}/signed.json"
    cntools_transaction_sign_registered "${package}" "${signed}" || fail 'sign payment + DRep'
    cntools_transaction_package_load "${signed}" || fail 'validate signatures'
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'missing signatures'
    size="$(jq -er '.cborHex | length / 2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")" || fail 'signed size'
    # Conway's ledger fee size excludes the serialized one-byte IsValid flag.
    # Check equality so an unnecessary fee budget cannot silently return.
    (( fee == 155381 + 44 * (size - 1) )) || fail "fee differs from signed ledger size operation=${operation} scenario=${scenario} fee=${fee} serialized_size=${size}"
    rm "${signed}"
    printf 'Pinned DRep passed: %s/%s\n' "${operation}" "${scenario}"
  done
done
cntools_wallet_material_cleanup
cntools_transaction_cleanup
printf 'CNTools DRep lifecycle pinned tests passed (cnode CLI %s).\n' "${version}"
