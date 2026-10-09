#!/usr/bin/env bash
# Fast path/script/UI contracts, without a node or private production material.
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-ms-contract.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet wallet-mnemonic transaction multisig-key multisig-wallet multisig-ui multisig-spend multisig-stake backup; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
. "${CNTOOLS_ROOT}/core/health.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_LOG="${TEST_ROOT}/log" CNTOOLS_NETWORK=preview
CNTOOLS_WALLET_MULTISIG_PREFIX=ms_ CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey
CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
epoch_start=''
cntools_epoch_start_slot_into epoch_start 2 && [[ "${epoch_start}" == 172800 ]] || fail 'preview epoch boundary'
CNTOOLS_NETWORK=mainnet
cntools_epoch_start_slot_into epoch_start 209 && [[ "${epoch_start}" == 4924800 ]] || fail 'mainnet transition boundary'
CNTOOLS_NETWORK=preprod
cntools_epoch_start_slot_into epoch_start 5 && [[ "${epoch_start}" == 518400 ]] || fail 'preprod transition boundary'
CNTOOLS_NETWORK=guild
cntools_epoch_start_slot_into epoch_start 3 && [[ "${epoch_start}" == 4320 ]] || fail 'guild transition boundary'
CNTOOLS_NETWORK=preview
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${CNTOOLS_LOG}"; }
hash1="$(printf 'ab%.0s' {1..28})" hash2="$(printf 'cd%.0s' {1..28})"
cntools_multisig_participants_reset
cntools_multisig_participant_add "${hash1}" "${hash1}" Alice
cntools_multisig_participant_add "${hash2}" "${hash2}" Bob
! cntools_multisig_participant_add "${hash1}" "${hash2}" Duplicate || fail 'duplicate threshold identity'
! cntools_multisig_script_write "${TEST_ROOT}/invalid" CNTOOLS_MULTISIG_PAYMENT_HASHES 0 '' '' || fail 'zero threshold'
! cntools_multisig_script_write "${TEST_ROOT}/invalid" CNTOOLS_MULTISIG_PAYMENT_HASHES 3 '' '' || fail 'impossible threshold'
cntools_multisig_script_write "${TEST_ROOT}/script" CNTOOLS_MULTISIG_PAYMENT_HASHES 2 100 200
cntools_transaction_native_script_valid "${TEST_ROOT}/script" || fail 'threshold validator'
printf '["%s","%s"]\n' "${hash1}" "${hash2}" > "${TEST_ROOT}/credentials"
cntools_transaction_native_script_satisfied "${TEST_ROOT}/script" "${TEST_ROOT}/credentials" 100 200 || fail 'satisfied threshold'
! cntools_transaction_native_script_satisfied "${TEST_ROOT}/script" "${TEST_ROOT}/credentials" 99 200 || fail 'lower bound bypass'
! cntools_transaction_native_script_satisfied "${TEST_ROOT}/script" "${TEST_ROOT}/credentials" 100 '' || fail 'upper bound bypass'
printf '["%s"]\n' "${hash1}" > "${TEST_ROOT}/credentials"
! cntools_transaction_native_script_satisfied "${TEST_ROOT}/script" "${TEST_ROOT}/credentials" 100 200 || fail 'missing signer accepted'
printf '{"type":"atLeast","required":3,"scripts":[{"type":"sig","keyHash":"%s"}]}\n' "${hash1}" > "${TEST_ROOT}/invalid"
! cntools_transaction_native_script_valid "${TEST_ROOT}/invalid" || fail 'impossible script validated'
cntools_backup_public_file wallets ms_derivation.json || fail 'public derivation backup missing'
cntools_backup_public_file wallets ms_payment.vkey || fail 'public participant backup missing'
! cntools_backup_public_file wallets ms_payment.skey || fail 'private participant in public backup'
! cntools_backup_public_file wallets ms_stake.skey.gpg || fail 'encrypted participant in public backup'
CNTOOLS_WALLET_PAY_SKEY_FILENAME=derivation.json
! cntools_backup_public_file wallets ms_derivation.json || fail 'custom-named private participant in public backup'
CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey

# Interrupted multi-file publication removes our links only; a concurrently
# replaced destination must survive rollback. Staging validation is isolated
# here; the real pinned tests exercise the production private-stage boundary.
mkdir "${TEST_ROOT}/stage" "${TEST_ROOT}/publish"
printf private > "${TEST_ROOT}/stage/ours"
printf private > "${TEST_ROOT}/stage/replaced"
ln "${TEST_ROOT}/stage/ours" "${TEST_ROOT}/publish/ours"
printf concurrent > "${TEST_ROOT}/publish/replaced"
cntools_wallet_create_stage_safe() { [[ "$1" == "${TEST_ROOT}/stage" ]]; }
CNTOOLS_MULTISIG_PUBLICATION_SOURCES=("${TEST_ROOT}/stage/ours" "${TEST_ROOT}/stage/replaced")
CNTOOLS_MULTISIG_PUBLICATION_TARGETS=("${TEST_ROOT}/publish/ours" "${TEST_ROOT}/publish/replaced")
cntools_multisig_key_publication_cleanup || fail 'interrupted publication rollback'
[[ ! -e "${TEST_ROOT}/publish/ours" && "$(< "${TEST_ROOT}/publish/replaced")" == concurrent ]] || fail 'rollback removed another inode'

# Script creation UI: one table per review, default threshold, entered bounds,
# cancellation before publication. Production backend is tested with real pins.
cntools_gum_clear() { :; }
cntools_ui_action_begin() { :; }
cntools_ui_render_status() { printf '%s\n' "$*" >> "${TEST_ROOT}/ui"; }
cntools_ui_wait() { :; }
cntools_table_pair() { printf '%s\t%s\n' "$1" "$2"; }
cntools_table_render() { cat >> "${TEST_ROOT}/ui"; }
cntools_slot_datetime_into() { printf -v "$1" '%s' "Slot $2"; }
cntools_wallet_create_environment_ready() { return 0; }
cntools_wallet_create_name_valid() { [[ "$1" == Shared ]]; }
cntools_wallet_create_target_available() { return 0; }
cntools_ui_input() { local -n result="$1"; result="${inputs[input_index]}"; input_index=$((input_index+1)); }
cntools_ui_choose() { local -n result="$1"; result="${choices[choice_index]}"; choice_index=$((choice_index+1)); }
cntools_ui_confirm() { [[ "${confirm}" == Y ]]; }
cntools_multisig_wallet_create() {
  printf '%s\n' "$*" >> "${TEST_ROOT}/published"
  CNTOOLS_WALLET_CREATED_DIRECTORY="${TEST_ROOT}/Shared"
}
cntools_wallet_address_primary_into() { printf -v "$2" addr_test1mock; printf -v "$3" 'Script address'; printf -v "$4" ''; }
inputs=(Shared "${hash1}" "${hash1}" "${hash2}" "${hash2}" '' 100 200)
choices=('Add external key hashes' 'Add external key hashes' Done 'Include threshold stake script' 'Absolute slot' 'Absolute slot')
input_index=0 choice_index=0 confirm=Y
cntools_multisig_create_workflow || fail 'creation wizard'
[[ "$(< "${TEST_ROOT}/published")" == 'Shared 2 Y 100 200' ]] || fail 'review/publication mismatch'
inputs=(Shared); choices=(Cancel); input_index=0 choice_index=0
! cntools_multisig_create_workflow || fail 'creation cancellation ignored'
[[ "$(wc -l < "${TEST_ROOT}/published" | tr -d ' ')" == 1 ]] || fail 'cancel published wallet'

# Signer choice keeps external participants public-only, and selects exactly
# the requested subset rather than every key appearing in the script.
cntools_multisig_candidates_load() {
  CNTOOLS_MULTISIG_CANDIDATE_IDS=("$(printf '11%.0s' {1..32})" "$(printf '22%.0s' {1..32})")
  CNTOOLS_MULTISIG_CANDIDATE_HASHES=("${hash1}" "${hash2}")
  CNTOOLS_MULTISIG_CANDIDATE_SOURCES=(/private/local.skey '') CNTOOLS_MULTISIG_CANDIDATE_LABELS=(Alice Bob)
}
choices=('1 · Alice · Local signer' '2 · Bob · Offline signer' 'Done selecting signers')
choice_index=0 CNTOOLS_MULTISIG_SPEND_THRESHOLD=2 CNTOOLS_MULTISIG_SIGNER_IDS=() CNTOOLS_MULTISIG_SIGNER_HASHES=() CNTOOLS_MULTISIG_SIGNER_SOURCES=() CNTOOLS_MULTISIG_SIGNER_LABELS=()
cntools_multisig_spend_choose_signers || fail 'signer choice'
[[ "${#CNTOOLS_MULTISIG_SIGNER_IDS[@]}" == 2 && "${CNTOOLS_MULTISIG_CAN_SIGN}" == N ]] || fail 'public-only signer silently enabled live workflow'

# Independent role selection must restore the payment subset even when the
# second (stake) selector is cancelled. Signability requires both roles.
cntools_multisig_candidates_load() {
  local key=11 source=/private/payment.skey
  [[ "${CNTOOLS_MULTISIG_SELECTION_ROLE}" != stake ]] || { key=33; source=''; }
  [[ "${stake_local:-N}" != Y || "${CNTOOLS_MULTISIG_SELECTION_ROLE}" != stake ]] || source=/private/stake.skey
  CNTOOLS_MULTISIG_CANDIDATE_IDS=("$(printf "${key}%.0s" {1..32})")
  CNTOOLS_MULTISIG_CANDIDATE_HASHES=("${hash1}")
  CNTOOLS_MULTISIG_CANDIDATE_SOURCES=("${source}") CNTOOLS_MULTISIG_CANDIDATE_LABELS=(Alice)
}
CNTOOLS_MULTISIG_SPEND_SCRIPT=payment-script CNTOOLS_MULTISIG_SPEND_THRESHOLD=1
CNTOOLS_MULTISIG_STAKE_SCRIPT=stake-script CNTOOLS_MULTISIG_STAKE_THRESHOLD=1
CNTOOLS_MULTISIG_SIGNER_IDS=() CNTOOLS_MULTISIG_SIGNER_HASHES=() CNTOOLS_MULTISIG_SIGNER_SOURCES=() CNTOOLS_MULTISIG_SIGNER_LABELS=()
choices=('1 · Alice · Local signer' 'Done selecting signers' '1 · Alice · Offline signer' 'Done selecting signers')
choice_index=0
cntools_multisig_stake_choose_signers cntools_gum_clear || fail 'separate stake signer selection'
[[ "${CNTOOLS_MULTISIG_SIGNER_IDS[0]}" == "$(printf '11%.0s' {1..32})" &&
   "${CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[0]}" == "$(printf '33%.0s' {1..32})" &&
   "${CNTOOLS_STAKE_CAN_SIGN}" == N && "${CNTOOLS_MULTISIG_CAN_SIGN}" == Y &&
   "${CNTOOLS_MULTISIG_SPEND_SCRIPT}" == payment-script && "${CNTOOLS_MULTISIG_SELECTION_ROLE}" == payment ]] || fail 'independent role selection leaked stake state'
choices=('Done selecting signers' Cancel); choice_index=0
! cntools_multisig_stake_choose_signers cntools_gum_clear || fail 'stake cancellation ignored'
[[ "${CNTOOLS_MULTISIG_SPEND_SCRIPT}" == payment-script && "${CNTOOLS_MULTISIG_SIGNER_SOURCES[0]}" == /private/payment.skey ]] || fail 'stake cancellation lost payment subset'
stake_local=Y
choices=('Done selecting signers' '1 · Alice · Local signer' 'Done selecting signers'); choice_index=0
cntools_multisig_stake_choose_signers cntools_gum_clear || fail 'local stake signer selection'
[[ "${CNTOOLS_STAKE_CAN_SIGN}" == Y ]] || fail 'complete local payment/stake subset cannot sign live'

# A reused key in the two scripts becomes one witness with both roles, not
# two fee estimates. Here only the cryptographic/native serialization is
# stubbed; production signing and script binding are tested against the pin.
cntools_transaction_plan_add_native_script() { printf '%s\n' "$2" >> "${TEST_ROOT}/purposes"; }
cntools_transaction_credential_from_key_id_into() { printf -v "$1" '%s' "${hash1}"; }
CNTOOLS_STAKE_WALLET=Shared CNTOOLS_MULTISIG_SIGNER_SOURCES=('') CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=('')
CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=("${CNTOOLS_MULTISIG_SIGNER_IDS[0]}")
CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS=('Alice stake')
cntools_transaction_credential_from_key_id_into signer_hash "${CNTOOLS_MULTISIG_SIGNER_IDS[0]}"
CNTOOLS_MULTISIG_SIGNER_HASHES=("${signer_hash}")
CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES=("${CNTOOLS_MULTISIG_SIGNER_HASHES[0]}")
CNTOOLS_MULTISIG_SPEND_AFTER=100 CNTOOLS_MULTISIG_SPEND_BEFORE=20000
CNTOOLS_MULTISIG_STAKE_AFTER=150 CNTOOLS_MULTISIG_STAKE_BEFORE=15000
expiry=''; cntools_transaction_plan_reset 'Stake fixture' '' exact
cntools_multisig_stake_plan expiry 1000 withdrawal || fail 'stake interval/signer plan'
[[ "${expiry}" == 15000 && "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" == 150 &&
   "$(cntools_transaction_plan_witness_count)" == 1 ]] || fail 'interval intersection / shared key deduplication'
jq -e 'length==1 and (.[0].roles|index("spending")!=null and index("withdrawal")!=null)' \
  <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" >/dev/null || fail 'shared key lost a required role'
[[ "$(< "${TEST_ROOT}/purposes")" == $'spend\nwithdrawal' ]] || fail 'native script purpose association'
expiry=1100; cntools_transaction_plan_reset 'Short user TTL' '' exact
cntools_multisig_stake_plan expiry 1000 certificate || fail 'user TTL intersect'
[[ "${expiry}" == 1100 ]] || fail 'script interval lengthened user TTL'
CNTOOLS_MULTISIG_STAKE_AFTER=20000; expiry=''
! cntools_multisig_stake_plan expiry 25000 certificate || fail 'disjoint script intervals accepted'
printf 'Multisig path/script/backup/UI contracts passed\n'
