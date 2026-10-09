#!/usr/bin/env bash
# Real participant derivation, script wallets and spending against cnode pins.
# shellcheck disable=SC1090,SC2034,SC2153,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass pinned cardano-cli}"
CNTOOLS_MULTISIG_ADDRESS_TOOL="${2:-}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-multisig.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
fail() { tail -40 "${TEST_ROOT}/log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for lib in number wallet wallet-material wallet-key wallet-address wallet-id wallet-create wallet-mnemonic wallet-hardware \
  wallet-query utxo coin-selection change-plan transaction transaction-build transaction-sign transaction-files \
  transaction-funding recipient wallet-payment funds-send funds-collect transaction-metadata multisig-key multisig-wallet multisig-spend wallet-protection backup; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
cntools_run_command() { shift 2; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_MV="$(type -P mv)" REAL_LN="$(type -P ln)"
  chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  mv() {
    if [[ "$1" == --help ]]; then printf '%s\n' '--no-target-directory --no-clobber'; return 0; fi
    shift 3; [[ ! -e "$2" && ! -L "$2" ]] || return 0; "${REAL_MV}" -n "$1" "$2"
  }
  ln() {
    local -a args=(); local arg=''
    for arg in "$@"; do [[ "${arg}" == -- || "${arg}" == -T ]] || args+=("${arg}"); done
    [[ ! -e "${args[1]}" && ! -L "${args[1]}" ]] || return 1
    "${REAL_LN}" "${args[@]}"
  }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=offline
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"; mkdir -m700 "${CNTOOLS_WALLET_DIR}"
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey
CNTOOLS_WALLET_PAY_ADDR_FILENAME=payment.addr CNTOOLS_WALLET_STAKE_ADDR_FILENAME=reward.addr CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr
CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME=payment.script.cred CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME=stake.script.cred
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path CNTOOLS_WALLET_MULTISIG_PREFIX=ms_
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong cnode pin'
path=''
cntools_multisig_path_into path "m/1854'/1815h/00H/0/01" && [[ "${path}" == 1854H/1815H/0H/0/1 ]] || fail 'custom path normalization'
for bad in '1854H//0' '1854H/1815H/0H/' '1854H/1815H/2147483648H/0/0' '1/2/0;echo' '' '1/2/-1'; do
  ! cntools_multisig_path_into path "${bad}" || fail 'unsafe path accepted'
done
for participant in Alice Bob Carol; do
  cntools_wallet_create_cli "${participant}" || fail "participant wallet: ${CNTOOLS_WALLET_CREATE_ERROR}"
  before="$(cksum "${CNTOOLS_WALLET_DIR}/${participant}"/*)"
  cntools_multisig_key_generate "${CNTOOLS_WALLET_DIR}/${participant}" cli '' '' || fail "participant keys: ${CNTOOLS_MULTISIG_ERROR}"
  for original in payment.skey payment.vkey stake.skey stake.vkey; do
    [[ "${before}" == *"$(cksum "${CNTOOLS_WALLET_DIR}/${participant}/${original}")"* ]] || fail 'original keys replaced'
  done
  ! cntools_multisig_key_generate "${CNTOOLS_WALLET_DIR}/${participant}" cli '' '' || fail 'existing participant keys replaced'
done
if [[ -n "${CNTOOLS_MULTISIG_ADDRESS_TOOL}" ]]; then
  [[ "$("${CNTOOLS_MULTISIG_ADDRESS_TOOL}" --version)" == "$(jq -r '.companions["cardano-address"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json") "* ]] || fail 'wrong address companion pin'
  mkdir -m700 "${CNTOOLS_WALLET_DIR}/Mnemonic"
  phrase='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'
  cntools_multisig_key_generate "${CNTOOLS_WALLET_DIR}/Mnemonic" mnemonic 1854H/1815H/0H/0/0 1854H/1815H/0H/2/0 "${phrase}" || fail "real mnemonic derivation: ${CNTOOLS_MULTISIG_ERROR}"
  [[ "$(jq -r .paymentPath "${CNTOOLS_WALLET_DIR}/Mnemonic/ms_derivation.json")" == 1854H/1815H/0H/0/0 ]] || fail 'paths not recorded'
  grep -F "${phrase}" "${TEST_ROOT}/log" && fail 'mnemonic leaked to log'
  mkdir -m700 "${CNTOOLS_WALLET_DIR}/Custom"
  cntools_multisig_key_generate "${CNTOOLS_WALLET_DIR}/Custom" mnemonic 1852H/1815H/0H/0/0 1852H/1815H/0H/2/0 "${phrase}" || fail 'custom 1852 derivation'
  # Compare the same path against cardano-cli's own standard mnemonic derivation.
  "${CNTOOLS_CLI}" latest key derive-from-mnemonic --key-output-text-envelope --payment-key-with-number 0 \
    --account-number 0 --mnemonic-from-interactive-prompt --signing-key-file "${TEST_ROOT}/standard.skey" <<< "${phrase}" >/dev/null
  [[ "$(jq -r .cborHex "${TEST_ROOT}/standard.skey")" == "$(jq -r .cborHex "${CNTOOLS_WALLET_DIR}/Custom/ms_payment.skey")" ]] || fail 'custom derivation differs from CLI standard'
  mkdir -m700 "${CNTOOLS_WALLET_DIR}/BadPhrase"
  ! cntools_multisig_key_generate "${CNTOOLS_WALLET_DIR}/BadPhrase" mnemonic 1854H/1815H/0H/0/0 1854H/1815H/0H/2/0 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon' || fail 'invalid mnemonic checksum accepted'
  [[ -z "$(find "${CNTOOLS_WALLET_DIR}/BadPhrase" -type f -print)" ]] || fail 'failed derivation published keys'
fi
cntools_multisig_participants_reset
for participant in Alice Bob Carol; do
  payment="$(< "${CNTOOLS_WALLET_DIR}/${participant}/ms_payment.cred")" stake="$(< "${CNTOOLS_WALLET_DIR}/${participant}/ms_stake.cred")"
  cntools_multisig_participant_add "${payment}" "${stake}" "${participant}" || fail 'participant add'
done
! cntools_multisig_participant_add "${payment}" "${stake}" Carol || fail 'duplicate signer accepted'
cntools_multisig_wallet_create Shared 2 Y 100 20000 || fail "script wallet: ${CNTOOLS_MULTISIG_ERROR} ${CNTOOLS_WALLET_CREATE_ERROR}"
cntools_multisig_wallet_create PaymentOnly 2 N '' '' || fail 'payment only wallet'
[[ ! -e "${CNTOOLS_WALLET_DIR}/PaymentOnly/base.addr" && ! -e "${CNTOOLS_WALLET_DIR}/PaymentOnly/reward.addr" ]] || fail 'payment only added stake address'
! cntools_multisig_wallet_create Shared 1 N '' '' || fail 'existing script wallet replaced'
printf secret > "${CNTOOLS_WALLET_DIR}/PaymentOnly/unexpected.skey"
! cntools_wallet_multisig_required_entries_valid "${CNTOOLS_WALLET_DIR}/PaymentOnly" || fail 'unexpected private artifact accepted'
rm -- "${CNTOOLS_WALLET_DIR}/PaymentOnly/unexpected.skey"
cntools_multisig_script_write "${TEST_ROOT}/ordered.script" CNTOOLS_MULTISIG_PAYMENT_HASHES 2 100 20000
saved_hash="$("${CNTOOLS_CLI}" hash script --script-file "${TEST_ROOT}/ordered.script")"
CNTOOLS_MULTISIG_PAYMENT_HASHES=("${CNTOOLS_MULTISIG_PAYMENT_HASHES[2]}" "${CNTOOLS_MULTISIG_PAYMENT_HASHES[0]}" "${CNTOOLS_MULTISIG_PAYMENT_HASHES[1]}")
cntools_multisig_script_write "${TEST_ROOT}/reordered.script" CNTOOLS_MULTISIG_PAYMENT_HASHES 2 100 20000
[[ "$("${CNTOOLS_CLI}" hash script --script-file "${TEST_ROOT}/reordered.script")" == "${saved_hash}" ]] || fail 'participant ordering changes script'
CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30 CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000 CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1 CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
cntools_send_prepare_wallet "${CNTOOLS_WALLET_DIR}/PaymentOnly" multisig || fail 'payment-only script spending preparation'
[[ "${CNTOOLS_SEND_ADDRESS}" == "${CNTOOLS_SEND_PAYMENT}" && -n "${CNTOOLS_SEND_ADDRESS}" ]] || fail 'payment-only primary address lost'
cntools_send_prepare_wallet "${CNTOOLS_WALLET_DIR}/Shared" multisig || fail "prepare script wallet: ${CNTOOLS_TRANSACTION_ERROR}"
cntools_multisig_candidates_load || fail 'local candidates'
cntools_multisig_signer_select 0
CNTOOLS_FUNDING_SLOT=1000 CNTOOLS_FUNDING_BACKEND=local CNTOOLS_SEND_EXPIRY=''
! cntools_send_plan_signers Send 'Negative threshold check' || fail 'insufficient signers accepted'
cntools_multisig_signer_select 1
CNTOOLS_FUNDING_SLOT=99
! cntools_send_plan_signers Send 'Negative lower bound check' || fail 'not-yet-valid script accepted'
CNTOOLS_FUNDING_SLOT=20000
! cntools_send_plan_signers Send 'Negative upper bound check' || fail 'expired script accepted'
CNTOOLS_FUNDING_SLOT=1000
cntools_metadata_reset
cntools_utxo_reset
reference="$(printf 'cd%.0s' {1..32})" asset="$(printf 'ab%.0s' {1..28}).01"
cntools_utxo_add "${reference}#0" "${CNTOOLS_SEND_ADDRESS}" 30000000
cntools_utxo_add_asset 0 "${asset}" 9007199254740993
cntools_utxo_add "${reference}#1" "${CNTOOLS_SEND_PAYMENT}" 5000000
CNTOOLS_FUNDING_TOTAL=35000000 CNTOOLS_FUNDING_ASSET_IDS=("${asset}")
declare -A CNTOOLS_FUNDING_ASSETS=(["${asset}"]=9007199254740993)
CNTOOLS_SEND_ADDRESSES=("$(< "${CNTOOLS_WALLET_DIR}/Alice/base.addr")")
CNTOOLS_SEND_LABELS=(Alice) CNTOOLS_SEND_AMOUNTS=(4000000)
package='' signed='' exported='' view=''
cntools_send_build_into package || fail "multisig send: ${CNTOOLS_TRANSACTION_ERROR}"
[[ "${CNTOOLS_SEND_EXPIRY}" == 20000 && "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" == 100 && "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 2 ]] || fail 'script interval/signature plan'
cntools_transaction_sign_registered "${package}" "${TEST_ROOT}/signed.json" || fail "multisig signing: ${CNTOOLS_TRANSACTION_ERROR}"
cntools_transaction_package_load "${TEST_ROOT}/signed.json" || fail 'signed script package'
[[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'script witnesses incomplete'
size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
((CNTOOLS_SEND_FEE == 155381+44*(size-1))) || fail 'multisig fee differs from signed minimum'
cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_SIGNED_FILE}"
jq -e --arg q 9007199254740993 '[.outputs[].amount|to_entries[]|select(.key!="lovelace")|.value|to_entries[]|.value|tostring]|index($q)!=null' <<< "${view}" >/dev/null || fail 'change token quantity changed'
# Collect uses the same native-script signer plan, but consumes both eligible
# addresses and returns all assets to the primary address without a recipient.
CNTOOLS_COLLECT_SCOPE=all CNTOOLS_COLLECT_BACKEND=local
collection=''
cntools_collect_build_into collection || fail "multisig collect: ${CNTOOLS_TRANSACTION_ERROR}"
cntools_transaction_sign_registered "${collection}" "${TEST_ROOT}/collected.json" || fail 'multisig collect signing'
cntools_transaction_package_load "${TEST_ROOT}/collected.json" || fail 'signed collection package'
[[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y && "${#CNTOOLS_COLLECT_INPUTS[@]}" == 2 ]] || fail 'collection inputs/signers'
size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
((CNTOOLS_COLLECT_FEE == 155381+44*(size-1))) || fail 'collection fee differs from signed minimum'
cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_SIGNED_FILE}"
jq -e --arg address "${CNTOOLS_SEND_ADDRESS}" 'all(.outputs[]; .address==$address)' <<< "${view}" >/dev/null || fail 'collection returns outside wallet'
# Export a source-free package, discard session workspace, and collect witnesses
# on separate passes. Each signing pass must preserve previous valid witnesses.
CNTOOLS_MULTISIG_SIGNER_SOURCES=('' '')
cntools_send_build_into package || fail 'public only build'
cntools_transaction_save_into exported "${package}" unsigned multisig-send || fail 'offline export'
cntools_transaction_cleanup
sources=("${CNTOOLS_WALLET_DIR}/Alice/ms_payment.skey"); changes=()
cntools_transaction_sign_package "${exported}" "${TEST_ROOT}/partial.json" sources changes || fail 'first offline signer'
cntools_transaction_package_load "${TEST_ROOT}/partial.json"
[[ "${CNTOOLS_TRANSACTION_COMPLETE}" == N && "${CNTOOLS_TRANSACTION_WITNESS_COUNT}" == 1 ]] || fail 'partial package reported complete'
sources=("${CNTOOLS_WALLET_DIR}/Bob/ms_payment.skey")
cntools_transaction_sign_package "${TEST_ROOT}/partial.json" "${TEST_ROOT}/complete.json" sources changes || fail 'second offline signer'
cntools_transaction_package_load "${TEST_ROOT}/complete.json"
[[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'offline witnesses incomplete'
cntools_transaction_cleanup
[[ -z "$(find "${CNTOOLS_WALLET_DIR}" -name '.cntools-*' -print)" ]] || fail 'staging leftovers'
printf 'Pinned multisig derivation/creation/spending passed CLI=%s\n' "${pin}"
