#!/usr/bin/env bash
# Node-free script DRep certificates/votes with the cnode deployment CLI pin.
# Generated keys only; no API, node, device or submission.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the pinned cnode CLI}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-ms-drep.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
fail() { printf 'FAIL: %s (%s / %s)\n' "$*" "${CNTOOLS_WALLET_REGISTER_ERROR:-}" "${CNTOOLS_TRANSACTION_ERROR:-}" >&2; tail -20 "${TEST_ROOT}/log" >&2; exit 1; }
for lib in number wallet wallet-material wallet-key wallet-address wallet-id wallet-create wallet-mnemonic wallet-query utxo coin-selection change-plan \
  transaction transaction-build transaction-sign transaction-files transaction-funding recipient wallet-payment wallet-register \
  drep-id drep-key drep-query drep-script governance-drep governance-proposal governance-vote multisig-key multisig-wallet multisig-spend multisig-drep; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
cntools_run_command() { shift 2; "$@"; }
cntools_funding_tip_into() { printf -v "$1" '%s' 1000; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_MV="$(type -P mv)" REAL_LN="$(type -P ln)"
  chmod() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- ]] || args+=("${a}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  mv() { if [[ "$1" == --help ]]; then printf '%s\n' '--no-target-directory --no-clobber'; return 0; fi; shift 3; [[ ! -e "$2" && ! -L "$2" ]] || return 0; "${REAL_MV}" -n "$1" "$2"; }
  ln() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- || "${a}" == -T ]] || args+=("${a}"); done; [[ ! -e "${args[1]}" && ! -L "${args[1]}" ]] || return 1; "${REAL_LN}" "${args[@]}"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=offline
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"; mkdir -m700 "${CNTOOLS_WALLET_DIR}"
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey
CNTOOLS_WALLET_PAY_ADDR_FILENAME=payment.addr CNTOOLS_WALLET_STAKE_ADDR_FILENAME=reward.addr CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred
CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME=payment.script.cred CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME=stake.script.cred
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path
CNTOOLS_TX_SELECTION_STRATEGY=fewest-inputs CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4 CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong cnode pin'
declare -a participant_hashes=()
for name in Alice Bob Key; do cntools_wallet_create_cli "${name}" || fail 'funding key wallet'; done
for name in Alice Bob; do
  directory="${CNTOOLS_WALLET_DIR}/${name}"
  "${CNTOOLS_CLI}" latest governance drep key-gen --signing-key-file "${directory}/drep.skey" --verification-key-file "${directory}/drep.vkey"
  participant_hashes+=("$("${CNTOOLS_CLI}" latest governance drep id --drep-verification-key-file "${directory}/drep.vkey" --output-hex)")
  cntools_multisig_participant_add "$(< "${directory}/payment.cred")" "$(< "${directory}/stake.cred")" "${name}"
done
for name in Shared KeyDrepMS SharedKeys; do cntools_multisig_wallet_create "${name}" 2 Y 100 20000 || fail 'script funding wallet'; done
for name in Key Shared; do cntools_multisig_script_write "${CNTOOLS_WALLET_DIR}/${name}/drep.script" participant_hashes 2 150 15000; done
"${CNTOOLS_CLI}" latest governance drep key-gen --signing-key-file "${CNTOOLS_WALLET_DIR}/KeyDrepMS/drep.skey" --verification-key-file "${CNTOOLS_WALLET_DIR}/KeyDrepMS/drep.vkey"
# Independent roles can deliberately reuse one public key. The typed DRep
# envelopes here contain the exact generated payment key bytes, for dedup tests.
participant_hashes=()
for name in Alice Bob; do
  participant_hashes+=("$(< "${CNTOOLS_WALLET_DIR}/${name}/payment.cred")")
  jq '.type="DRepVerificationKey_ed25519"' "${CNTOOLS_WALLET_DIR}/${name}/payment.vkey" > "${TEST_ROOT}/${name}.drep.vkey"
done
cntools_multisig_script_write "${CNTOOLS_WALLET_DIR}/SharedKeys/drep.script" participant_hashes 2 150 15000
cntools_multisig_spend_choose_signers() {
  CNTOOLS_MULTISIG_SELECTION_ROLE="$2"
  cntools_multisig_candidates_load || return 1
  for i in "${!CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}"; do cntools_multisig_signer_select "${i}"; done
  if [[ "$2" == drep && "${current_wallet}" == SharedKeys ]]; then
    for name in Alice Bob; do
      cntools_multisig_candidate_add "${TEST_ROOT}/${name}.drep.vkey" "${CNTOOLS_WALLET_DIR}/${name}/payment.skey" "${name} shared key"
      cntools_multisig_signer_select "$((${#CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}-1))"
    done
  fi
  CNTOOLS_MULTISIG_CAN_SIGN=Y
}
reference="$(printf 'ab%.0s' {1..32})#0" policy="$(printf 'cd%.0s' {1..28})" proposal_tx="$(printf 'ef%.0s' {1..32})"
cntools_proposal_id_into proposal_id "${proposal_tx}" 1
CNTOOLS_PROPOSAL_EPOCH=42
read -r -a cases <<< "${CNTOOLS_MULTISIG_DREP_CASES:-register update retire vote shared-offline key-drep}"
for case_name in "${cases[@]}"; do
  operation="drep-${case_name}" current_wallet=Key expected_count=3
  case "${case_name}" in
    register) operation=drep-register ;;
    update) operation=drep-update; current_wallet=Shared; expected_count=4 ;;
    retire) operation=drep-retire; current_wallet=Shared; expected_count=4 ;;
    vote) operation=gov-vote; current_wallet=Shared; expected_count=4 ;;
    shared-offline) operation=gov-vote; current_wallet=SharedKeys; expected_count=2 ;;
    key-drep) operation=drep-register; current_wallet=KeyDrepMS; expected_count=3 ;;
    *) fail 'unknown case' ;;
  esac
  cntools_wallet_register_operation_set "${operation}"
  cntools_wallet_register_prepare_wallet "${CNTOOLS_WALLET_DIR}/${current_wallet}" "${current_wallet}" || fail 'prepare'
  cntools_multisig_drep_choose_signers || fail 'select payment and DRep subsets'
  [[ "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" == Y ]] || fail 'local signing incorrectly unavailable'
  cntools_wallet_register_reset_chain_state
  CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_SOURCE=Fixture
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0 CNTOOLS_WALLET_REGISTER_LIFETIME=0
  [[ "${operation}" != drep-register ]] || CNTOOLS_WALLET_REGISTER_DEPOSIT=500000000
  [[ "${operation}" != drep-retire ]] || CNTOOLS_WALLET_REGISTER_DEPOSIT=450000000
  CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL=https://example.invalid/drep.json CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="$(printf '11%.0s' {1..32})"
  [[ "${operation}" != drep-retire ]] || { CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL=''; CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''; }
  if [[ "${operation}" == gov-vote ]]; then
    CNTOOLS_GOV_VOTE_DECISION=Yes
    CNTOOLS_GOV_VOTE_PROPOSAL="$(jq -cn --arg id "${proposal_id}" --arg tx "${proposal_tx}" '{id:$id,tx:$tx,index:1,type:"InfoAction",expires:43,ratified:false}')"
  fi
  cntools_utxo_add "${reference}" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" 700000000
  cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
  cntools_wallet_register_inventory_use_all; cntools_wallet_register_select_inputs
  package=''; cntools_wallet_register_build_package_into package || fail "build ${case_name}"
  cntools_transaction_package_load "${package}" || fail 'load package'
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == "${expected_count}" ]] || fail 'wrong witness count/dedup'
  cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
  total="$(jq '[.outputs[].amount.lovelace]|add' <<< "${view}")" fee="${CNTOOLS_WALLET_REGISTER_FEE}"
  expected=700000000
  [[ "${operation}" != drep-register ]] || expected=$((expected-CNTOOLS_WALLET_REGISTER_DEPOSIT))
  [[ "${operation}" != drep-retire ]] || expected=$((expected+CNTOOLS_WALLET_REGISTER_DEPOSIT))
  ((total+fee==expected)) || fail 'deposit/fee conservation'
  [[ "${view}" == *9007199254740993* ]] || fail 'token precision lost'
  if [[ "${CNTOOLS_DREP_LIFECYCLE_KIND}" == script ]]; then
    [[ "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_BEFORE}:${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" == 150:15000 ]] || fail 'mandatory script bounds removed by No expiry'
  fi
  if [[ "${case_name}" == shared-offline ]]; then
    unsigned=''; cntools_transaction_save_into unsigned "${package}" unsigned multisig-drep
    ! grep -Eq '\.skey|/wallets/' "${unsigned}" || fail 'private paths leaked into export'
    cntools_transaction_cleanup
    sources=("${CNTOOLS_WALLET_DIR}/Alice/payment.skey"); changes=()
    cntools_transaction_sign_package "${unsigned}" "${TEST_ROOT}/partial.json" sources changes || fail 'first offline signer'
    cntools_transaction_package_load "${TEST_ROOT}/partial.json"
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}:${CNTOOLS_TRANSACTION_WITNESS_COUNT}" == N:1 ]] || fail 'partial package incorrectly complete'
    sources=("${CNTOOLS_WALLET_DIR}/Bob/payment.skey")
    cntools_transaction_sign_package "${TEST_ROOT}/partial.json" "${TEST_ROOT}/${case_name}.signed.json" sources changes || fail 'second offline signer'
  else
    cntools_transaction_sign_registered "${package}" "${TEST_ROOT}/${case_name}.signed.json" || fail 'sign'
  fi
  cntools_transaction_package_load "${TEST_ROOT}/${case_name}.signed.json" || fail 'validate witnesses'
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'missing signatures'
  size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
  ((fee==155381+44*(size-1))) || fail 'fee differs from exact signed minimum'
  printf 'Pinned multisig DRep passed: %s (CLI=%s)\n' "${case_name}" "${pin}"
done
cntools_wallet_material_cleanup; cntools_transaction_cleanup
