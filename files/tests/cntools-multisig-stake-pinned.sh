#!/usr/bin/env bash
# Real script-stake certificates/withdrawals against the cnode deployment pin.
# Generated test keys only: no node, API, hardware device or submission.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass pinned cardano-cli}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-ms-stake.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
fail() { tail -30 "${TEST_ROOT}/log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for lib in number wallet wallet-material wallet-key wallet-address wallet-id wallet-create wallet-query utxo coin-selection change-plan \
  transaction transaction-build transaction-sign transaction-files transaction-funding wallet-payment wallet-stake wallet-register \
  pool-id funds-delegate drep-id governance-delegate funds-withdraw multisig-key multisig-wallet multisig-spend multisig-stake; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
cntools_run_command() { shift 2; "$@"; }
cntools_funding_tip_into() { printf -v "$1" '%s' 1000; }
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
for name in Alice Bob; do cntools_wallet_create_cli "${name}" || fail "participant creation: ${CNTOOLS_WALLET_CREATE_ERROR}"; done
cntools_multisig_participants_reset
for name in Alice Bob; do
  cntools_multisig_participant_add "$(< "${CNTOOLS_WALLET_DIR}/${name}/payment.cred")" "$(< "${CNTOOLS_WALLET_DIR}/${name}/stake.cred")" "${name}" || fail 'participant'
done
cntools_multisig_wallet_create Shared 2 Y 100 20000 || fail 'script wallet'
cntools_multisig_wallet_create PaymentOnly 2 N '' '' || fail 'payment-only script wallet'
! cntools_stake_prepare_wallet "${CNTOOLS_WALLET_DIR}/PaymentOnly" PaymentOnly || fail 'stake action accepted payment-only script wallet'
prepare_signers() {
  local wallet="$1" stake_role="$2" name='' id=''
  cntools_wallet_register_prepare_wallet "${CNTOOLS_WALLET_DIR}/${wallet}" "${wallet}" || fail "script preparation: ${CNTOOLS_TRANSACTION_ERROR}"
  for name in Alice Bob; do
    cntools_transaction_key_id_from_verification_file_into id "${CNTOOLS_WALLET_DIR}/${name}/payment.vkey"
    CNTOOLS_MULTISIG_SIGNER_IDS+=("${id}"); CNTOOLS_MULTISIG_SIGNER_HASHES+=("$(< "${CNTOOLS_WALLET_DIR}/${name}/payment.cred")")
    CNTOOLS_MULTISIG_SIGNER_SOURCES+=("${CNTOOLS_WALLET_DIR}/${name}/payment.skey"); CNTOOLS_MULTISIG_SIGNER_LABELS+=("${name} payment")
    cntools_transaction_key_id_from_verification_file_into id "${CNTOOLS_WALLET_DIR}/${name}/${stake_role}.vkey"
    CNTOOLS_MULTISIG_STAKE_SIGNER_IDS+=("${id}"); CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES+=("$(< "${CNTOOLS_WALLET_DIR}/${name}/${stake_role}.cred")")
    CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES+=("${CNTOOLS_WALLET_DIR}/${name}/${stake_role}.skey"); CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS+=("${name} stake")
  done
}
prepare_signers Shared stake
CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_TX_SELECTION_STRATEGY=fewest-inputs CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30 CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000 CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1 CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
expiry=''; cntools_transaction_plan_reset negative '' exact
saved_ids=("${CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[@]}"); CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=("${saved_ids[0]}")
! cntools_multisig_stake_plan expiry 1000 certificate || fail 'insufficient stake threshold accepted'
CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=("${saved_ids[@]}")
! cntools_multisig_stake_plan expiry 99 certificate || fail 'future script accepted'
! cntools_multisig_stake_plan expiry 20000 certificate || fail 'expired script accepted'
CNTOOLS_MULTISIG_STAKE_AFTER=150 CNTOOLS_MULTISIG_STAKE_BEFORE=15000
cntools_transaction_clear_error
reference="$(printf 'cd%.0s' {1..32})" policy="$(printf 'ab%.0s' {1..28})"
CNTOOLS_DELEGATE_POOL_HEX="$(printf '00%.0s' {1..28})"
cntools_pool_id_encode_into CNTOOLS_DELEGATE_POOL_ID "${CNTOOLS_DELEGATE_POOL_HEX}"
scenarios=(register deregister delegate delegate-register vote vote-register withdraw shared-offline)
(( $# < 2 )) || scenarios=("${@:2}")
for scenario in "${scenarios[@]}"; do
  expected_witnesses=4
  if [[ "${scenario}" == shared-offline ]]; then
    cntools_multisig_participants_reset
    for name in Alice Bob; do
      hash="$(< "${CNTOOLS_WALLET_DIR}/${name}/payment.cred")"
      cntools_multisig_participant_add "${hash}" "${hash}" "${name}"
    done
    cntools_multisig_wallet_create SharedKeys 2 Y 100 20000 || fail 'shared-key script wallet'
    prepare_signers SharedKeys payment
    CNTOOLS_MULTISIG_SIGNER_SOURCES=('' '') CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=('' '')
    expected_witnesses=2
  elif [[ "${CNTOOLS_STAKE_WALLET}" != Shared ]]; then prepare_signers Shared stake; fi
  CNTOOLS_MULTISIG_STAKE_AFTER=150 CNTOOLS_MULTISIG_STAKE_BEFORE=15000
  cntools_wallet_register_reset_chain_state
  CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_SOURCE=Fixture
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${CNTOOLS_FUNDING_PROTOCOL}"
  CNTOOLS_WALLET_REGISTER_LIFETIME=0 CNTOOLS_WALLET_REGISTER_DEPOSIT=0
  CNTOOLS_FUNDING_SLOT=1000 CNTOOLS_WITHDRAW_EXPIRY=''
  validator=cntools_wallet_register_validate_body
  case "${scenario}" in
    register|shared-offline) cntools_wallet_register_operation_set register; CNTOOLS_WALLET_REGISTERED=no; CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000 ;;
    deregister)
      cntools_wallet_register_operation_set deregister; CNTOOLS_WALLET_REGISTERED=yes
      CNTOOLS_WALLET_STAKE_DEPOSIT=2345678 CNTOOLS_WALLET_REWARD_LOVELACE=0
      cntools_wallet_register_chain_state_validate || fail 'historical refund rejected'
      CNTOOLS_WALLET_REGISTER_DEPOSIT="${CNTOOLS_WALLET_STAKE_DEPOSIT}" ;;
    delegate|delegate-register)
      cntools_wallet_register_operation_set delegate; CNTOOLS_WALLET_REGISTERED=yes
      [[ "${scenario}" != delegate-register ]] || CNTOOLS_WALLET_REGISTERED=no
      cntools_delegate_chain_state_validate; CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=Y
      [[ "${CNTOOLS_DELEGATE_REGISTER}" != Y ]] || CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000
      validator=cntools_delegate_validate_body ;;
    vote|vote-register)
      cntools_wallet_register_operation_set vote-delegate; CNTOOLS_WALLET_REGISTERED=yes
      [[ "${scenario}" != vote-register ]] || CNTOOLS_WALLET_REGISTERED=no
      cntools_vote_chain_state_validate; CNTOOLS_VOTE_REGISTRATION_CONFIRMED=Y
      [[ "${CNTOOLS_VOTE_REGISTER}" != Y ]] || CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000
      cntools_drep_id_into CNTOOLS_VOTE_TARGET CNTOOLS_VOTE_KIND CNTOOLS_VOTE_HASH drep_always_abstain
      validator=cntools_vote_validate_body ;;
    withdraw) CNTOOLS_WITHDRAW_BACKEND=koios CNTOOLS_WITHDRAW_REWARDS=1000000 ;;
    *) fail 'unknown scenario' ;;
  esac
  input_address="${CNTOOLS_STAKE_BASE_ADDRESS}"
  [[ "${scenario}" != withdraw ]] || input_address="${CNTOOLS_STAKE_PAYMENT_ADDRESS}"
  cntools_utxo_add "${reference}#0" "${input_address}" 30000000
  cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
  if [[ "${scenario}" == withdraw ]]; then
    cntools_withdraw_build_into package || fail "withdraw build: ${CNTOOLS_TRANSACTION_ERROR}"
    fee="${CNTOOLS_WITHDRAW_FEE}"; expected_total=$((CNTOOLS_COIN_SELECTED_LOVELACE+CNTOOLS_WITHDRAW_REWARDS))
  else
    cntools_wallet_register_inventory_use_all; cntools_wallet_register_select_inputs
    cntools_wallet_register_build_package_into package || fail "${scenario} build: ${CNTOOLS_WALLET_REGISTER_ERROR} ${CNTOOLS_TRANSACTION_ERROR}"
    cntools_transaction_package_load "${package}"; "${validator}" "${CNTOOLS_TRANSACTION_BODY_FILE}" || fail 'certificate body validation'
    fee="${CNTOOLS_WALLET_REGISTER_FEE}"; expected_total=$((CNTOOLS_COIN_SELECTED_LOVELACE-CNTOOLS_WALLET_REGISTER_DEPOSIT))
    [[ "${scenario}" != deregister ]] || expected_total=$((CNTOOLS_COIN_SELECTED_LOVELACE+CNTOOLS_WALLET_REGISTER_DEPOSIT))
  fi
  cntools_transaction_package_load "${package}"
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == "${expected_witnesses}" ]] || fail 'payment/stake witnesses not deduplicated correctly'
  jq -e '.signing.nativeScripts|length==2' "${package}" >/dev/null || fail 'two script purposes missing'
  [[ "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" == 15000 && "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_BEFORE}" == 150 ]] || fail 'script interval intersection'
  cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
  sum="$(jq '[.outputs[].amount.lovelace]|add' <<< "${view}")"
  ((sum+fee==expected_total)) || fail 'ADA/deposit/reward conservation'
  jq -e --arg p "policy ${policy}" '[.outputs[].amount[$p]["asset 01"]//0]|add|tostring=="9007199254740993"' <<< "${view}" >/dev/null || fail 'native asset conservation'
  if [[ "${scenario}" == shared-offline ]]; then
    unsigned=''; cntools_transaction_save_into unsigned "${package}" unsigned multisig-stake
    ! grep -Eq '\.skey|/wallets/' "${unsigned}" || fail 'private source paths in public package'
    cntools_transaction_cleanup
    sources=("${CNTOOLS_WALLET_DIR}/Alice/payment.skey"); changes=()
    cntools_transaction_sign_package "${unsigned}" "${TEST_ROOT}/partial.json" sources changes || fail 'first offline stake signer'
    cntools_transaction_package_load "${TEST_ROOT}/partial.json"
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == N && "${CNTOOLS_TRANSACTION_WITNESS_COUNT}" == 1 ]] || fail 'partial script stake package marked complete'
    sources=("${CNTOOLS_WALLET_DIR}/Bob/payment.skey")
    cntools_transaction_sign_package "${TEST_ROOT}/partial.json" "${TEST_ROOT}/${scenario}.signed.json" sources changes || fail 'second offline stake signer'
  else
    cntools_transaction_sign_registered "${package}" "${TEST_ROOT}/${scenario}.signed.json" || fail "${scenario} signing: ${CNTOOLS_TRANSACTION_ERROR}"
  fi
  cntools_transaction_package_load "${TEST_ROOT}/${scenario}.signed.json"
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'native script witnesses incomplete'
  size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
  ((fee==155381+44*(size-1))) || fail "${scenario} fee differs from exact signed minimum"
  printf 'Pinned multisig stake passed: %s (CLI=%s)\n' "${scenario}" "${pin}"
done
cntools_transaction_cleanup
