#!/usr/bin/env bash
# Real CIP-151 authorization, metadata build and offline signing. No chain I/O.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329,SC2015
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the cnode deployment CLI pin}"
CNTOOLS_CARDANO_SIGNER="${2:?Pass Cardano Signer 1.35.0}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-calidus-registration.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
for lib in number wallet wallet-key wallet-query utxo coin-selection change-plan transaction transaction-build transaction-sign \
  transaction-files transaction-funding wallet-payment multisig-spend funds-send transaction-metadata metadata-transaction pool-id pool pool-files pool-key \
  drep-id calidus-id pool-calidus calidus-registration pool-calidus-registration-ui; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; tail -20 "${TEST_ROOT}/log" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- ]] || args+=("${a}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=offline
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong cnode pin'
[[ "$("${CNTOOLS_CARDANO_SIGNER}" --version)" == 'cardano-signer 1.35.0' ]] || fail 'wrong Signer test pin'
pool="${TEST_ROOT}/pool"; mkdir -m700 "${pool}"
"${CNTOOLS_CLI}" latest node key-gen --cold-signing-key-file "${pool}/cold.skey" --cold-verification-key-file "${pool}/cold.vkey" --operational-certificate-issue-counter-file "${pool}/cold.counter"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${pool}/calidus.skey" --verification-key-file "${pool}/calidus.vkey"
chmod 600 "${pool}"/*
CNTOOLS_POOL_DIRECTORIES=("${pool}"); CNTOOLS_POOL_IDENTITIES=('Verified cold public key')
CNTOOLS_POOL_IDS=("$("${CNTOOLS_CLI}" latest stake-pool id --cold-verification-key-file "${pool}/cold.vkey" --output-bech32)")
cntools_calidus_registration_identity 0 || fail "identity: ${CNTOOLS_TRANSACTION_ERROR}"
cntools_calidus_registration_authorize 0 || fail 'zero nonce authorization'
[[ "${CNTOOLS_CALIDUS_REG_NONCE}" == 0 ]] || fail 'zero nonce changed'
cntools_calidus_registration_authorize 12345 || fail "authorize: ${CNTOOLS_TRANSACTION_ERROR}"
original="${CNTOOLS_CALIDUS_REG_METADATA}"
[[ "${CNTOOLS_CALIDUS_REG_NONCE}" == 12345 ]] || fail 'nonce not retained'
cntools_transaction_save_into exported "${original}" metadata calidus-authorization || fail 'metadata export'
[[ -f "${exported}" && "${exported}" == */metadata.json ]] || fail 'missing public export'
original="${exported}"
CNTOOLS_CALIDUS_OPERATION=revoke
cntools_calidus_registration_identity 0 && cntools_calidus_registration_authorize 12346 || fail 'revocation authorization'
jq -e '."867"."1"."7"==("0x"+("0"*64))' "${CNTOOLS_CALIDUS_REG_METADATA}" >/dev/null || fail 'revocation target is not zero'
! cntools_calidus_registration_verify "${original}" || fail 'registration imported as revocation'
cntools_transaction_save_into revoked "${CNTOOLS_CALIDUS_REG_METADATA}" metadata calidus-revocation || fail 'revocation export'
CNTOOLS_CALIDUS_OPERATION=register
cntools_calidus_registration_identity 0 || fail 'registration identity restore'
! cntools_calidus_registration_verify "${revoked}" || fail 'revocation imported as registration'
cntools_calidus_registration_verify "${original}" || fail 'registration authorization restore'
# Metadata authorization must not read an encrypted or mixed hardware cold key.
printf 'encrypted fixture\n' > "${pool}/cold.skey.gpg"
! cntools_calidus_registration_authorize 12346 || fail 'mixed encrypted cold authorization'
rm -- "${pool}/cold.skey.gpg"
printf 'hardware fixture\n' > "${pool}/cold.hwsfile"
! cntools_calidus_registration_authorize 12346 || fail 'mixed hardware cold authorization'
rm -- "${pool}/cold.hwsfile"
# Imports need only cold and Calidus public keys, never their signing keys.
mv "${pool}/cold.skey" "${TEST_ROOT}/cold-offline.skey"
mv "${pool}/calidus.skey" "${TEST_ROOT}/calidus-offline.skey"
cntools_calidus_registration_identity 0 && cntools_calidus_registration_verify "${exported}" || fail 'public-only import'
for invalid in key pool nonce signature extra duplicate; do
  bad="${TEST_ROOT}/bad.json"
  case "${invalid}" in
    key) jq '."867"."1"."7"="0x"+("ab"*32)' "${original}" > "${bad}" ;;
    pool) jq '."867"."1"."1"[1]="0x"+("ab"*28)' "${original}" > "${bad}" ;;
    nonce) jq '."867"."1"."4"=12346' "${original}" > "${bad}" ;;
    signature) jq '."867"."2"[0]."2"[3]="0x"+("00"*64)' "${original}" > "${bad}" ;;
    extra) jq '.+{"123":{"msg":"unreviewed"}}' "${original}" > "${bad}" ;;
    duplicate) printf '{"867":{},"867":%s}' "$(jq -c '."867"' "${original}")" > "${bad}" ;;
  esac
  ! cntools_calidus_registration_verify "${bad}" || fail "accepted ${invalid} metadata"
done
CNTOOLS_CALIDUS_CHAIN_NONCE=12345
! cntools_calidus_registration_verify "${original}" || fail 'replay accepted'
CNTOOLS_CALIDUS_CHAIN_NONCE=''
cntools_calidus_registration_verify "${original}" || fail 'restore verified metadata'
# Strict, mocked API boundary: empty does not mean unavailable; revocation keeps
# its nonce; malformed responses and a changed indexed identity stop the flow.
CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://test.invalid/api/v1
api_response='[]'
cntools_funding_get() {
  [[ "$1" == *'/pool_calidus_keys?pool_id_bech32=eq.pool1'* && "$1" == *'calidus_nonce%3A%3Atext'* && "$1" != *'registered=eq'* ]] || return 1
  printf '%s\n' "${api_response}" > "$2"
}
cntools_calidus_registration_lookup || fail 'empty lookup'
[[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == 'Not indexed' ]] || fail 'empty response called failure'
api_response="$(jq -cn --arg p "${CNTOOLS_CALIDUS_REG_POOL}" '{pool_id_bech32:$p,calidus_nonce:"100",calidus_pub_key:("0"*64),tx_hash:("aa"*32),registered:false}|[.]')"
cntools_calidus_registration_lookup || fail 'revocation lookup'
[[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == Revoked && "${CNTOOLS_CALIDUS_CHAIN_NONCE}" == 100 ]] || fail 'revocation nonce lost'
! cntools_calidus_registration_nonce_valid 100 || fail 'revocation replay accepted'
api_response='{"error":"broken"}'
! cntools_calidus_registration_lookup || fail 'malformed API accepted'
[[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == Unavailable ]] || fail 'query failure reported unregistered'
api_response='[]'; cntools_calidus_registration_lookup
CNTOOLS_CALIDUS_REG_REVIEW_STATE="${CNTOOLS_CALIDUS_CHAIN_STATE}"
cntools_calidus_registration_state_recheck || fail 'unchanged authorization state'
api_response="$(jq -cn --arg p "${CNTOOLS_CALIDUS_REG_POOL}" '{pool_id_bech32:$p,calidus_nonce:"100",calidus_pub_key:("0"*64),tx_hash:("aa"*32),registered:false}|[.]')"
! cntools_calidus_registration_state_recheck || fail 'changed authorization accepted'
CNTOOLS_CALIDUS_CHAIN_NONCE=''
cntools_calidus_registration_verify "${original}" || fail 'restore authorization'
(
  # Revocation must work with missing or corrupt local Calidus files, without
  # repairing/deleting them. Only the frozen pool cold identity is relevant.
  CNTOOLS_CALIDUS_OPERATION=revoke
  mv "${pool}/calidus.vkey" "${TEST_ROOT}/calidus-offline.vkey"
  cntools_calidus_registration_identity 0 && cntools_calidus_registration_verify "${revoked}" || fail 'revocation without local key'
  cp "${pool}/cold.vkey" "${pool}/calidus.vkey"
  cntools_calidus_registration_identity 0 && cntools_calidus_registration_verify "${revoked}" || fail 'revocation with corrupt local key'
  api_response="$(jq -cn --arg p "${CNTOOLS_CALIDUS_REG_POOL}" --arg key "$(jq -r '."867"."1"."7"[2:]' "${original}")" \
    '{pool_id_bech32:$p,calidus_nonce:"100",calidus_pub_key:$key,calidus_id_bech32:"calidus1example",tx_hash:("aa"*32),registered:true}|[.]')"
  cntools_calidus_registration_lookup || fail 'active key for revocation'
  CNTOOLS_CALIDUS_REG_REVIEW_STATE="${CNTOOLS_CALIDUS_CHAIN_STATE}"
  cntools_calidus_registration_state_recheck || fail 'revocation recheck touched corrupt local key'
  cmp "${pool}/cold.vkey" "${pool}/calidus.vkey" || fail 'revocation modified local key'
  api_response="$(jq -c '.[0].calidus_pub_key=("ab"*32)|.[0].calidus_nonce="101"' <<< "${api_response}")"
  ! cntools_calidus_registration_state_recheck || fail 'revocation accepted replacement after review'
  api_response='[]'
  ! cntools_calidus_registration_state_recheck || fail 'revocation accepted disappearing indexed state'
  CNTOOLS_CALIDUS_CHAIN_NONCE=12346
  ! cntools_calidus_registration_verify "${revoked}" || fail 'revocation replay accepted'
  CNTOOLS_CALIDUS_CHAIN_NONCE=''
  bad="${TEST_ROOT}/bad-revoke.json"
  jq '."867"."2"[0]."2"[3]="0x"+("00"*64)' "${revoked}" > "${bad}"
  ! cntools_calidus_registration_verify "${bad}" || fail 'invalid revocation signature accepted'
  mv "${TEST_ROOT}/calidus-offline.vkey" "${pool}/calidus.vkey"
)
# Funding is the only ledger witness. No cold key, Calidus key, node, or API is
# involved in build/sign. Exercise unchanged token change and configured shaping.
CNTOOLS_SEND_WALLET=Funding CNTOOLS_SEND_TYPE=CLI CNTOOLS_SEND_DIRECTORY="${TEST_ROOT}"
CNTOOLS_SEND_VKEY="${TEST_ROOT}/payment.vkey" CNTOOLS_SEND_SOURCE="${TEST_ROOT}/payment.skey"
"${CNTOOLS_CLI}" address key-gen --verification-key-file "${CNTOOLS_SEND_VKEY}" --signing-key-file "${CNTOOLS_SEND_SOURCE}"
chmod 600 "${CNTOOLS_SEND_VKEY}" "${CNTOOLS_SEND_SOURCE}"
CNTOOLS_SEND_CREDENTIAL="$("${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${CNTOOLS_SEND_VKEY}")"
CNTOOLS_SEND_ADDRESS="$("${CNTOOLS_CLI}" address build --payment-verification-key-file "${CNTOOLS_SEND_VKEY}" --testnet-magic 2)"
CNTOOLS_SEND_PAYMENT="${CNTOOLS_SEND_ADDRESS}" CNTOOLS_SEND_CHANGE_ADDRESS="${CNTOOLS_SEND_ADDRESS}"
key_address="${CNTOOLS_SEND_ADDRESS}"
key_credential="${CNTOOLS_SEND_CREDENTIAL}"
cntools_transaction_key_id_from_verification_file_into signer_id "${CNTOOLS_SEND_VKEY}"
jq -n --arg h "${key_credential}" '{type:"atLeast",required:1,scripts:[{type:"sig",keyHash:$h}]}' > "${TEST_ROOT}/payment.script"
script_address="$("${CNTOOLS_CLI}" address build --payment-script-file "${TEST_ROOT}/payment.script" --testnet-magic 2)"
CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_FUNDING_BACKEND=local CNTOOLS_FUNDING_SLOT=1000
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30 CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000 CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1 CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
reference="$(printf 'cd%.0s' {1..32})" asset="$(printf 'ab%.0s' {1..28})"
scenarios=(ada tokens shaped offline no-expiry multisig revoke revoke-tokens revoke-shaped revoke-offline revoke-no-expiry revoke-multisig send-exact send-max send-sweep)
(( $# < 3 )) || scenarios=("${@:3}")
for scenario in "${scenarios[@]}"; do
  variant="${scenario#revoke-}" intent='Register Calidus key' action=calidus-register metadata="${original}"
  if [[ "${scenario}" == revoke* ]]; then
    intent='Revoke Calidus key' action=calidus-revoke metadata="${revoked}"
  fi
  CNTOOLS_SEND_SOURCE="${TEST_ROOT}/payment.skey" CNTOOLS_SEND_EXPIRY=2800
  CNTOOLS_SEND_TYPE=CLI CNTOOLS_SEND_ADDRESS="${key_address}" CNTOOLS_SEND_PAYMENT="${key_address}" CNTOOLS_SEND_CHANGE_ADDRESS="${key_address}" CNTOOLS_SEND_CREDENTIAL="${key_credential}"
  if [[ "${variant}" == multisig ]]; then
    CNTOOLS_SEND_TYPE=MultiSig CNTOOLS_SEND_SOURCE=''
    CNTOOLS_SEND_ADDRESS="${script_address}" CNTOOLS_SEND_PAYMENT="${script_address}" CNTOOLS_SEND_CHANGE_ADDRESS="${script_address}"
    CNTOOLS_MULTISIG_SPEND_SCRIPT="${TEST_ROOT}/payment.script" CNTOOLS_MULTISIG_SPEND_THRESHOLD=1
    CNTOOLS_MULTISIG_SIGNER_IDS=("${signer_id}"); CNTOOLS_MULTISIG_SIGNER_HASHES=("${key_credential}")
    CNTOOLS_MULTISIG_SIGNER_SOURCES=("${TEST_ROOT}/payment.skey"); CNTOOLS_MULTISIG_SIGNER_LABELS=('Funding participant')
  fi
  CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N
  cntools_utxo_reset; CNTOOLS_FUNDING_ASSET_IDS=(); CNTOOLS_FUNDING_ASSETS=()
  cntools_utxo_add "${reference}#0" "${CNTOOLS_SEND_ADDRESS}" 100000000
  cntools_utxo_add "${reference}#1" "${CNTOOLS_SEND_ADDRESS}" 5000000 Y N
  cntools_utxo_add "${reference}#2" "${CNTOOLS_SEND_ADDRESS}" 5000000 N Y
  if [[ "${variant}" == tokens || "${variant}" == shaped ]]; then
    cntools_utxo_add_asset 0 "${asset}.01" 9007199254740993
    cntools_utxo_add_asset 0 "${asset}.02" 200
    CNTOOLS_FUNDING_ASSET_IDS=("${asset}.01" "${asset}.02")
    CNTOOLS_FUNDING_ASSETS["${asset}.01"]=9007199254740993 CNTOOLS_FUNDING_ASSETS["${asset}.02"]=200
  fi
  [[ "${variant}" != shaped ]] || { CNTOOLS_TX_TOKEN_FRAGMENTATION=Y CNTOOLS_TX_TOKEN_MAX_ASSETS=1 CNTOOLS_TX_UTXO_MANAGEMENT=Y CNTOOLS_TX_COLLATERAL_MANAGEMENT=Y; }
  [[ "${variant}" != no-expiry ]] || CNTOOLS_SEND_EXPIRY=''
  [[ "${variant}" != offline ]] || CNTOOLS_SEND_SOURCE=''
  package='' signed="${TEST_ROOT}/${scenario}.signed.json"
  if [[ "${scenario}" == send-* ]]; then
    # Regression: adding the metadata-only adapter must not change Send modes.
    cntools_utxo_keep_simple_into skipped || fail 'ordinary Send fixture inventory'
    cntools_metadata_reset
    CNTOOLS_SEND_MODE="${scenario#send-}" CNTOOLS_SEND_ADDRESSES=("${CNTOOLS_SEND_ADDRESS}") CNTOOLS_SEND_AMOUNTS=(3000000)
    CNTOOLS_SEND_ASSETS=()
    cntools_send_build_into package || fail "${scenario} build: ${CNTOOLS_TRANSACTION_ERROR}"
  else
    context="$(jq -cn --arg action "${action}" '{action:$action}')"
    cntools_metadata_transaction_build_into package "${intent}" 'Publish Calidus authorization' "${context}" "${metadata}" || fail "${scenario} build: ${CNTOOLS_TRANSACTION_ERROR}"
  fi
  [[ "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" == 1 ]] || fail 'cold key added as funding witness'
  view=''; cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}"
  jq -e --arg ref "${reference}#0" '.inputs==[$ref]' <<< "${view}" >/dev/null || fail 'datum/reference-script consumed'
  returned="$(jq -r '[.outputs[].amount.lovelace]|add' <<< "${view}")"
  (( returned + CNTOOLS_SEND_FEE == 100000000 )) || fail 'ADA change conservation'
  if [[ "${variant}" == tokens || "${variant}" == shaped ]]; then
    [[ "${view}" == *9007199254740993* ]] || fail 'large asset quantity changed'
    jq -e --arg policy "policy ${asset}" '[.outputs[].amount[$policy]["asset 02"] // 0]|add==200' <<< "${view}" >/dev/null || fail 'asset change conservation'
  fi
  if [[ "${scenario}" == send-* ]]; then
    [[ "$(jq -r '.intent.kind' "${package}")" == 'Send funds' && "$(jq -r '.intent.summary.action' "${package}")" == send ]] || fail 'Send default intent changed'
  else
    [[ "$(jq -r '.intent.kind' "${package}")" == "${intent}" && "$(jq -r '.intent.summary.action' "${package}")" == "${action}" ]] || fail 'wrong package intent'
  fi
  [[ "${variant}" != no-expiry ]] || jq -e '."validity range"."upper bound"==null' <<< "${view}" >/dev/null || fail 'No expiry omitted'
  if [[ "${variant}" == offline ]]; then
    cntools_transaction_save_into saved "${package}" unsigned "${action}" || fail 'unsigned export'
    cntools_transaction_cleanup
    sources=("${TEST_ROOT}/payment.skey"); changes=()
    cntools_transaction_sign_package "${saved}" "${signed}" sources changes || fail 'offline funding signature'
  else
    cntools_transaction_sign_registered "${package}" "${signed}" || fail "${scenario} signing: ${CNTOOLS_TRANSACTION_ERROR}"
  fi
  cntools_transaction_package_load "${signed}" || fail 'signed package'
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'incomplete funding witness'
  size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
  ((CNTOOLS_SEND_FEE == 155381+44*(size-1))) || fail 'fee not exact for final signed transaction'
  printf 'PASS: Calidus %s (cnode CLI %s / Signer 1.35.0)\n' "${scenario}" "${pin}"
done
for secret in "${TEST_ROOT}/cold-offline.skey" "${TEST_ROOT}/calidus-offline.skey" "${TEST_ROOT}/payment.skey"; do
  ! rg -F "$(jq -r .cborHex "${secret}")" "${TEST_ROOT}/log" >/dev/null || fail 'private key leaked into log'
done
cntools_transaction_cleanup
[[ -f "${exported}" && -f "${revoked}" && ( -z "${saved:-}" || -f "${saved}" ) ]] || fail 'cleanup removed durable exports'
printf 'PASS: Calidus authorization, replay, binding, strict imports and indexed-state checks\n'
