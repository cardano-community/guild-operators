#!/usr/bin/env bash
# Real disposable Catalyst signatures and fee-only packages; no live chain/device.
# shellcheck disable=SC1090,SC2034,SC2030,SC2031,SC2329,SC2154,SC2015
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the cnode deployment CLI pin}"
CNTOOLS_CARDANO_SIGNER="${2:?Pass Cardano Signer 1.35.0}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-catalyst-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
for lib in number wallet wallet-material wallet-key wallet-address wallet-id wallet-query transaction transaction-build transaction-sign \
  transaction-files transaction-funding utxo coin-selection change-plan recipient wallet-payment funds-send transaction-metadata metadata-transaction \
  drep-id catalyst-key catalyst-metadata catalyst-qr; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; tail -12 "${TEST_ROOT}/log" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() {
  local mask="$2" argument='' index=0
  shift 3
  for argument in "$@"; do
    if [[ "${mask:index:1}" == 1 ]]; then printf '<redacted> ' >> "${TEST_ROOT}/log"
    else printf '%q ' "${argument}" >> "${TEST_ROOT}/log"; fi
    index=$((index+1))
  done
  printf '\n' >> "${TEST_ROOT}/log"
  if [[ "$1" == fixture-hw ]]; then cp "${hardware_cbor}" "${@: -1}"; else "$@"; fi
}
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- ]] || args+=("${a}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong cnode pin'
[[ "$("${CNTOOLS_CARDANO_SIGNER}" --version)" == 'cardano-signer 1.35.0' ]] || fail 'wrong Signer pin'
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=offline
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-openssl}"
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"; mkdir -m700 "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_WALLET_DIR}/Example"
directory="${CNTOOLS_WALLET_DIR}/Example"
CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey
CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey
CNTOOLS_WALLET_PAY_ADDR_FILENAME=payment.addr CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr
CNTOOLS_WALLET_STAKE_ADDR_FILENAME=reward.addr CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME=payment.script.cred CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME=stake.script.cred
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path CNTOOLS_WALLET_MULTISIG_PREFIX=ms_
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${directory}/payment.skey" --verification-key-file "${directory}/payment.vkey"
"${CNTOOLS_CLI}" latest stake-address key-gen --signing-key-file "${directory}/stake.skey" --verification-key-file "${directory}/stake.vkey"
cntools_catalyst_keys_prepare "${directory}" create || fail "key generation: ${CNTOOLS_TRANSACTION_ERROR}"
cntools_catalyst_identity "${directory}" || fail "identity: ${CNTOOLS_TRANSACTION_ERROR}"
cntools_catalyst_authorize 12345 || fail "authorization: ${CNTOOLS_TRANSACTION_ERROR}"
original="${CNTOOLS_CATALYST_METADATA}"
cntools_transaction_save_into exported "${original}" metadata catalyst-authorization || fail 'authorization export'
original="${exported}"
for alteration in key stake reward nonce signature extra duplicate; do
  bad="${TEST_ROOT}/bad.json"
  case "${alteration}" in
    key) jq '."61284"."1"[0][0]="0x"+("ab"*32)' "${original}" > "${bad}" ;;
    stake) jq '."61284"."2"="0x"+("ab"*32)' "${original}" > "${bad}" ;;
    reward) jq '."61284"."3"="0x"+("ab"*29)' "${original}" > "${bad}" ;;
    nonce) jq '."61284"."4"=12346' "${original}" > "${bad}" ;;
    signature) jq '."61285"."1"="0x"+("00"*64)' "${original}" > "${bad}" ;;
    extra) jq '.+{"123":1}' "${original}" > "${bad}" ;;
    duplicate) printf '{"61284":{},"61284":%s,"61285":%s}' "$(jq -c '."61284"' "${original}")" "$(jq -c '."61285"' "${original}")" > "${bad}" ;;
  esac
  ! cntools_catalyst_verify_metadata "${bad}" || fail "accepted tampered ${alteration}"
done
cntools_catalyst_verify_metadata "${original}" || fail 'public verification restore'
# Exercise every CBOR unsigned-integer width with genuine signatures.
for nonce in 0 23 24 255 256 65535 65536 4294967295 4294967296 9007199254740991; do
  cntools_catalyst_authorize "${nonce}" || fail "nonce boundary ${nonce}"
  [[ "${CNTOOLS_CATALYST_NONCE}" == "${nonce}" ]] || fail 'nonce changed during verification'
done
! cntools_catalyst_cbor_uint_into encoded_nonce 9007199254740992 || fail 'inexact JSON nonce accepted'
cntools_catalyst_verify_metadata "${original}" || fail 'original nonce restore'
# Extended mnemonic keys use the same stake authorization and public binding.
(
  CNTOOLS_TRANSACTION_TEMP_FILES=(); CNTOOLS_TRANSACTION_TEMP_DIR=''; CNTOOLS_TRANSACTION_TEMP_BASE=''
  CNTOOLS_WALLET_MATERIAL_TEMP_FILES=()
  mnemonic_directory="${CNTOOLS_WALLET_DIR}/Mnemonic"; mkdir -m700 "${mnemonic_directory}"
  "${CNTOOLS_CLI}" key generate-mnemonic --size 24 --out-file "${TEST_ROOT}/mnemonic.txt"
  for role in payment stake; do
    "${CNTOOLS_CLI}" key derive-from-mnemonic "--${role}-key-with-number" 0 --account-number 0 \
      --mnemonic-from-file "${TEST_ROOT}/mnemonic.txt" --signing-key-file "${mnemonic_directory}/${role}.skey" >/dev/null
    "${CNTOOLS_CLI}" key verification-key --signing-key-file "${mnemonic_directory}/${role}.skey" \
      --verification-key-file "${TEST_ROOT}/${role}.extended.vkey"
    "${CNTOOLS_CLI}" key non-extended-key --extended-verification-key-file "${TEST_ROOT}/${role}.extended.vkey" \
      --verification-key-file "${mnemonic_directory}/${role}.vkey"
  done
  printf '1852H/1815H/0H/0/0\n1852H/1815H/0H/2/0\n' > "${mnemonic_directory}/derivation.path"
  cntools_catalyst_keys_prepare "${mnemonic_directory}" create && cntools_catalyst_identity "${mnemonic_directory}" &&
    cntools_catalyst_authorize 12345 || fail "extended stake authorization: ${CNTOOLS_TRANSACTION_ERROR}"
  cntools_catalyst_cleanup
)
# Reuse keys, refuse mixed clear/encrypted stake authorization and mismatched pairs.
before="$(jq -r .cborHex "${directory}/catalyst.skey")"
cntools_catalyst_keys_prepare "${directory}" create || fail 'existing key reuse'
[[ "$(jq -r .cborHex "${directory}/catalyst.skey")" == "${before}" ]] || fail 'existing key replaced'
public_before="${CNTOOLS_CATALYST_PUBLIC}"
mv "${directory}/catalyst.vkey" "${TEST_ROOT}/original-catalyst.vkey"
cntools_catalyst_keys_prepare "${directory}" || fail 'missing public key repair'
[[ "${CNTOOLS_CATALYST_PUBLIC}" == "${public_before}" && "$(jq -r .cborHex "${directory}/catalyst.skey")" == "${before}" ]] || fail 'repair changed voting identity'
(
  CNTOOLS_WALLET_CATALYST_SKEY_FILENAME=payment.hwsfile
  ! cntools_catalyst_keys_prepare "${directory}" create || fail 'hardware-reference filename collision accepted'
)
printf 'encrypted\n' > "${directory}/stake.skey.gpg"
! cntools_catalyst_authorize 12346 || fail 'mixed encrypted stake used'
rm -- "${directory}/stake.skey.gpg"
mv "${directory}/stake.skey" "${TEST_ROOT}/stake-offline.skey"
cntools_catalyst_verify_metadata "${original}" || fail 'import required stake signing key'
! cntools_catalyst_authorize 12346 || fail 'missing stake key accepted'
mv "${TEST_ROOT}/stake-offline.skey" "${directory}/stake.skey"
# Hardware wire format: real signer CBOR decoded by real CLI. No device used.
hardware_cbor="${TEST_ROOT}/hardware-metadata.cbor"
"${CNTOOLS_CARDANO_SIGNER}" sign --cip36 --testnet --vote-public-key "${CNTOOLS_CATALYST_PUBLIC}" \
  --payment-address "${CNTOOLS_CATALYST_REWARD}" --secret-key "${directory}/stake.skey" --nonce 12345 --out-cbor "${hardware_cbor}" >/dev/null
CNTOOLS_TRANSACTION_HWCLI=fixture-hw
printf 'hardware reference\n' > "${directory}/stake.hwsfile"; printf 'hardware reference\n' > "${directory}/payment.hwsfile"
cntools_transaction_temp_file decoded hardware-decoded
cntools_catalyst_authorize_hardware 12345 "${decoded}" && cntools_catalyst_verify_metadata "${decoded}" || fail "hardware CBOR decoding: ${CNTOOLS_TRANSACTION_ERROR}"
rm -- "${directory}/stake.hwsfile" "${directory}/payment.hwsfile"
# Exact fee, native-token conservation, offline package/signing round trip.
cntools_send_prepare_wallet "${directory}" || fail 'prepare funding'
CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_FUNDING_BACKEND=local CNTOOLS_FUNDING_SLOT=1000 CNTOOLS_SEND_EXPIRY=2800
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30 CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000 CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1 CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
reference="$(printf 'ab%.0s' {1..32})" policy="$(printf 'cd%.0s' {1..28})"
for variant in ada token no-expiry; do
  cntools_utxo_reset; CNTOOLS_FUNDING_ASSET_IDS=(); CNTOOLS_FUNDING_ASSETS=()
  cntools_utxo_add "${reference}#0" "${CNTOOLS_SEND_ADDRESS}" 100000000
  cntools_utxo_add "${reference}#1" "${CNTOOLS_SEND_ADDRESS}" 5000000 Y N
  [[ "${variant}" != token ]] || { cntools_utxo_add_asset 0 "${policy}.01" 100; CNTOOLS_FUNDING_ASSET_IDS=("${policy}.01"); CNTOOLS_FUNDING_ASSETS["${policy}.01"]=100; }
  CNTOOLS_SEND_EXPIRY=2800; [[ "${variant}" != no-expiry ]] || CNTOOLS_SEND_EXPIRY=''
  cntools_metadata_transaction_build_into staged 'Register for Catalyst' 'CIP-36 authorization' '{"action":"catalyst-register"}' "${original}" || fail "${variant} build: ${CNTOOLS_TRANSACTION_ERROR}"
  [[ ${#CNTOOLS_COIN_SELECTED_REFS[@]} == 1 ]] || fail 'datum input consumed'
  cntools_transaction_signed_path_into signed && cntools_transaction_sign_registered "${staged}" "${signed}" || fail 'funding signing'
  cntools_transaction_package_load "${signed}" && [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || fail 'package incomplete'
  cntools_transaction_temp_file fee minimum-fee; cntools_transaction_temp_file errors fee-errors
  cntools_transaction_run_cli "${fee}" "${errors}" -- "${CNTOOLS_CLI}" latest transaction calculate-min-fee \
    --tx-body-file "${CNTOOLS_TRANSACTION_SIGNED_FILE}" --protocol-params-file "${CNTOOLS_FUNDING_PROTOCOL}" \
    --witness-count 0 --byron-witness-count 0 --output-text || fail 'signed minimum fee'
  [[ "$(< "${fee}")" == "${CNTOOLS_SEND_FEE} Lovelace" ]] || fail "signed fee is not exact: built=${CNTOOLS_SEND_FEE} actual=$(< "${fee}")"
  size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
  ((CNTOOLS_SEND_FEE == 155381+44*(size-1))) || fail 'signed ledger size fee mismatch'
done
if [[ -n "${3:-}" ]]; then
  CNTOOLS_CATALYST_TOOLBOX="$3"
  cntools_catalyst_qr_create "${directory}" 0042 || fail "pinned Toolbox QR: ${CNTOOLS_TRANSACTION_ERROR}"
  [[ -s "${CNTOOLS_CATALYST_QR_OUTPUT}" && -s "${CNTOOLS_CATALYST_QR_TEXT}" ]] || fail 'pinned QR output empty'
  ! rg -F '0042' "${TEST_ROOT}/log" >/dev/null || fail 'QR PIN logged'
  ! rg 'ed25519e_sk1' "${TEST_ROOT}/log" >/dev/null || fail 'Bech32 voting secret logged'
fi
cntools_catalyst_cleanup
! rg -F "${before}" "${TEST_ROOT}/log" >/dev/null || fail 'voting secret logged'
printf 'CNTools Catalyst pinned tests passed (%s)\n' "${pin}"
