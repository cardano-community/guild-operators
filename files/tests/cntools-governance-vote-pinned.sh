#!/usr/bin/env bash
# Real, node-free Conway votes with the cnode deployment's exact CLI pin.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the checksum-verified cnode CLI binary}"
PINNED_HWCLI="${2:-}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-governance-vote.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'chmod -R u+rwX "${TEST_ROOT}"; rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
fail() { printf 'FAIL: %s (%s / %s)\n' "$*" "${CNTOOLS_WALLET_REGISTER_ERROR:-}" "${CNTOOLS_TRANSACTION_ERROR:-}" >&2; tail -15 "${TEST_ROOT}/test.log" >&2; exit 1; }
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
[[ "${version}" == "$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")" ]] || fail 'CLI is not the cnode deployment pin'
for lib in number wallet wallet-material wallet-key wallet-mnemonic wallet-address wallet-id wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query utxo coin-selection change-plan recipient wallet-payment transaction transaction-build transaction-sign transaction-files wallet-register drep-id drep-query drep-key governance-drep governance-proposal governance-vote governance-vote-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_log_sanitize_line() { printf '%s' "${1//[[:cntrl:]]/ }"; }
cntools_run_command_timeout() { shift 3; "$@"; }
cntools_funding_tip_into() { printf -v "$1" '%s' 1000; }
REAL_CHMOD="$(type -P chmod)" REAL_LN="$(type -P ln)"
chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
ln() { if [[ "${1:-}" == -T ]]; then shift; [[ ! -d "${3}" ]] || return 1; fi; "${REAL_LN}" "$@"; }
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_WALLET_DIR="${TEST_ROOT}"
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
wallet="${TEST_ROOT}/wallet"; mkdir "${wallet}"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${wallet}/payment.skey" --verification-key-file "${wallet}/payment.vkey"
"${CNTOOLS_CLI}" latest governance drep key-gen --signing-key-file "${wallet}/drep.skey" --verification-key-file "${wallet}/drep.vkey"
chmod 600 "${wallet}"/*
cntools_wallet_register_operation_set gov-vote
cntools_wallet_register_prepare_wallet "${wallet}" vote-test || fail 'prepare DRep funding wallet'
reference="$(printf 'ab%.0s' {1..32})#0" policy="$(printf 'cd%.0s' {1..28})" tx="$(printf 'ef%.0s' {1..32})"
id='' package='' signed='' view='' hash=''
cntools_proposal_id_into id "${tx}" 1
CNTOOLS_PROPOSAL_EPOCH=42
printf '{"body":{"comment":"Test rationale"}}\n' > "${TEST_ROOT}/rationale.json"
cntools_gov_vote_hash_into hash "${TEST_ROOT}/rationale.json" || fail 'hash rationale'
[[ "${hash}" == "$("${CNTOOLS_CLI}" hash anchor-data --file-binary "${TEST_ROOT}/rationale.json")" ]] || fail 'rationale exact byte hash'
for decision in Yes No Abstain Unsigned; do
  cntools_wallet_register_reset_chain_state
  CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_SOURCE=Fixture
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0 CNTOOLS_WALLET_REGISTER_LIFETIME=1800
  CNTOOLS_GOV_VOTE_DECISION="${decision}"; [[ "${decision}" != Unsigned ]] || CNTOOLS_GOV_VOTE_DECISION=Yes
  CNTOOLS_GOV_VOTE_PROPOSAL="$(jq -cn --arg tx "${tx}" --arg id "${id}" '{id:$id,tx:$tx,index:1,type:"InfoAction",expires:43,ratified:false}')"
  CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''
  CNTOOLS_DREP_LIFECYCLE_SOURCE="${wallet}/drep.skey" CNTOOLS_DREP_LIFECYCLE_VKEY="${wallet}/drep.vkey"
  if [[ "${decision}" == No ]]; then CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL=https://example.invalid/vote.json; CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="${hash}"; fi
  if [[ "${decision}" == Abstain ]]; then
    phrase="$("${CNTOOLS_CLI}" key generate-mnemonic --size 24)"
    "${CNTOOLS_CLI}" key derive-from-mnemonic --drep-key --account-number 0 --mnemonic-from-interactive-prompt --signing-key-file "${wallet}/extended.skey" <<< "${phrase}" >/dev/null
    "${CNTOOLS_CLI}" key verification-key --signing-key-file "${wallet}/extended.skey" --verification-key-file "${wallet}/extended.vkey"
    "${CNTOOLS_CLI}" key non-extended-key --extended-verification-key-file "${wallet}/extended.vkey" --verification-key-file "${wallet}/extended-normal.vkey"
    CNTOOLS_DREP_LIFECYCLE_SOURCE="${wallet}/extended.skey" CNTOOLS_DREP_LIFECYCLE_VKEY="${wallet}/extended-normal.vkey"
    CNTOOLS_WALLET_REGISTER_LIFETIME=0
  fi
  CNTOOLS_DREP_LIFECYCLE_ID="$("${CNTOOLS_CLI}" latest governance drep id --drep-verification-key-file "${CNTOOLS_DREP_LIFECYCLE_VKEY}" --output-cip129)"
  cntools_drep_id_into normalized kind CNTOOLS_DREP_LIFECYCLE_HASH "${CNTOOLS_DREP_LIFECYCLE_ID}"
  [[ "${decision}" != Unsigned ]] || { CNTOOLS_DREP_LIFECYCLE_SOURCE=''; CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=''; }
  cntools_utxo_add "${reference}" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" 600000000
  [[ "${decision}" != No ]] || cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
  cntools_wallet_register_inventory_use_all
  cntools_wallet_register_select_inputs || fail 'select inputs'
  cntools_wallet_register_build_package_into package || fail "build ${decision} vote"
  cntools_transaction_package_load "${package}" || fail 'load package'
  cntools_gov_vote_validate_body "${CNTOOLS_TRANSACTION_BODY_FILE}" || fail 'validate vote'
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 2 ]] || fail 'payment and DRep witnesses required'
  jq -e '.[] | select(.roles | index("vote"))' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" >/dev/null || fail 'DRep vote role'
  if [[ -n "${PINNED_HWCLI}" ]]; then
    "${PINNED_HWCLI}" transaction transform --tx-file "${CNTOOLS_TRANSACTION_BODY_FILE}" --out-file "${TEST_ROOT}/hw.body"
    cntools_gov_vote_validate_body "${TEST_ROOT}/hw.body" || fail 'hardware transformation changed vote'
  fi
  cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
  fee="$(jq -r '.fee | split(" ")[0]' <<< "${view}")"
  sum="$(jq '[.outputs[].amount.lovelace] | add' <<< "${view}")"
  ((fee+sum == 600000000)) || fail 'fee and ADA conservation without deposit'
  [[ "${decision}" != No || "${view}" == *9007199254740993* ]] || fail 'token conservation/precision'
  if [[ "${decision}" != Unsigned ]]; then
    signed="${TEST_ROOT}/${decision}.signed.json"
    cntools_transaction_sign_registered "${package}" "${signed}" || fail 'sign payment + DRep vote'
    cntools_transaction_package_load "${signed}" || fail 'validate signatures'
    [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'missing signatures'
    size="$(jq -er '.cborHex | length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
    ((fee == 155381 + 44*(size-1))) || fail 'CLI fee differs from exact signed ledger size'
  else [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == N ]] || fail 'unsigned package unexpectedly complete'; fi
  printf 'Pinned governance vote passed: %s\n' "${decision}"
done
cntools_wallet_material_cleanup
cntools_transaction_cleanup
printf 'CNTools governance vote pinned tests passed (cnode CLI %s).\n' "${version}"
