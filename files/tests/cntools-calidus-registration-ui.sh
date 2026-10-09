#!/usr/bin/env bash
# Interaction contracts only. No real keys, packages, node or submission.
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/pool-calidus-registration-ui.sh"
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/transaction-ui.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for operation in register revoke; do
for scenario in unsigned sign live decline failed stale-before-sign stale-before-submit cancel expiry offline no-index already-revoked decline-revoke; do
  [[ "${operation}" != register || ( "${scenario}" != no-index && "${scenario}" != already-revoked && "${scenario}" != decline-revoke ) ]] || continue
  (
    CNTOOLS_CALIDUS_OPERATION="${operation}"
    CNTOOLS_MODE=local CNTOOLS_LOG=/logs/cntools.log CNTOOLS_TRANSACTION_ERROR=''
    CNTOOLS_CALIDUS_REG_METADATA=/private/auth.json CNTOOLS_CALIDUS_REG_POOL=pool1example
    CNTOOLS_CALIDUS_REG_PUBLIC=public CNTOOLS_CALIDUS_REG_ID=calidus1example
    CNTOOLS_SEND_SOURCE=/wallet/payment.skey CNTOOLS_SEND_TYPE=CLI CNTOOLS_SEND_ADDRESS=address CNTOOLS_SEND_PAYMENT=address
    CNTOOLS_TRANSACTION_COMPLETE=Y CNTOOLS_TRANSACTION_ID=txid
    CNTOOLS_TRANSACTION_SUBMIT_MESSAGE='Accepted.' CNTOOLS_TRANSACTION_SIGNED_FILE=/private/signed.body CNTOOLS_TRANSACTION_SUBMIT_ID=txid
    signed_count=0 submitted_count=0 saved_count=0 builds=0 reviews=0 rechecks=0 monitored=0 authorizations=0 confirmations=0 result=''
    CNTOOLS_WALLET_PATHS=(/wallet)
    cntools_transaction_log() { :; }
    cntools_ui_action_begin() { :; }
    cntools_ui_render_detail() { :; }
    cntools_ui_render_status() { :; }
    cntools_ui_spin_function() { shift; "$@"; }
    cntools_calidus_registration_identity() { :; }
    cntools_calidus_signer_require() { [[ "${scenario}" != no-index && "${scenario}" != already-revoked ]] || fail 'no-op needs no metadata signer'; }
    cntools_calidus_registration_lookup() {
      CNTOOLS_CALIDUS_CHAIN_STATE='[]'; CNTOOLS_CALIDUS_CHAIN_STATUS='Not indexed'; CNTOOLS_CALIDUS_CHAIN_PUBLIC=''
      if [[ "${operation}" == revoke && "${scenario}" != no-index ]]; then
        CNTOOLS_CALIDUS_CHAIN_STATE=active; CNTOOLS_CALIDUS_CHAIN_STATUS='Registered (no local key)'; CNTOOLS_CALIDUS_CHAIN_PUBLIC=indexed-public
        [[ "${scenario}" != already-revoked ]] || CNTOOLS_CALIDUS_CHAIN_STATUS=Revoked
      fi
    }
    cntools_calidus_registration_render_identity() { :; }
    cntools_calidus_registration_prompt_authorization() { authorizations=$((authorizations+1)); [[ "${scenario}" != cancel ]]; }
    cntools_ui_confirm() {
      [[ "$1" == *Revoke* && "$2" == false ]] || fail 'revocation confirmation must default No'
      confirmations=$((confirmations+1)); [[ "${scenario}" != decline-revoke ]]
    }
    cntools_wallet_catalog_build() { :; }
    cntools_wallet_choose() { [[ "$*" == *send* ]] || fail 'funding selection context'; printf -v "$1" '%s' 0; }
    cntools_send_prepare_wallet() { :; }
    cntools_ui_choose() {
      [[ "$2" == Workflow && "$3" == 'Create, sign and submit' ]] || fail 'workflow order or missing common flow'
      case "${scenario}" in
        unsigned) printf -v "$1" '%s' 'Create unsigned package' ;;
        sign) printf -v "$1" '%s' 'Create and sign' ;;
        *) printf -v "$1" '%s' 'Create, sign and submit' ;;
      esac
    }
    cntools_transaction_ui_expiry_into() { printf -v "$1" '%s' 0; }
    cntools_calidus_registration_refresh_build_into() { [[ "$2" == 0 ]] || fail 'No expiry not passed to builder'; builds=$((builds+1)); printf -v "$1" '%s' /private/unsigned.json; }
    cntools_transaction_ui_review_into() {
      [[ "$4" == cntools_calidus_registration_begin && "$5" == cntools_calidus_registration_render_review && "$*" == *'Change expiry'* && "$*" == *'Change workflow'* ]] || fail 'missing shared review or options'
      reviews=$((reviews+1))
      if [[ "${scenario}" == expiry && "${reviews}" == 1 ]]; then printf -v "$1" '%s' 'Change expiry'; else printf -v "$1" '%s' "$3"; fi
    }
    cntools_transaction_signed_path_into() { printf -v "$1" '%s' /private/signed.json; }
    cntools_calidus_registration_recheck() {
      rechecks=$((rechecks+1))
      [[ "${scenario}" != stale-before-sign || "${rechecks}" != 1 ]] || return 1
      [[ "${scenario}" != stale-before-submit || "${rechecks}" != 2 ]] || return 1
    }
    cntools_transaction_sign_registered() { signed_count=$((signed_count+1)); }
    cntools_transaction_package_load() { :; }
    cntools_transaction_save_into() { [[ "$4" == "calidus-${operation}" ]] || fail 'wrong export label'; saved_count=$((saved_count+1)); printf -v "$1" '%s' "/saved/$3.json"; }
    cntools_transaction_submit_input_prepare() { :; }
    cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' local; }
    cntools_transaction_ui_confirm_submit() { [[ "${scenario}" != decline ]]; }
    cntools_transaction_ui_submit_selected() { submitted_count=$((submitted_count+1)); [[ "${scenario}" != failed ]]; }
    cntools_transaction_ui_render_result() { result="$1|$2|${4:-}"; }
    cntools_transaction_ui_offer_monitor() { monitored=$((monitored+1)); }
    cntools_calidus_registration_fail() { CNTOOLS_TRANSACTION_ERROR="$1"; return 1; }
    [[ "${scenario}" != offline ]] || CNTOOLS_MODE=offline
    status=0; cntools_calidus_registration_workflow 0 || status=$?
    case "${scenario}" in
      cancel) [[ "${status}" == 1 && "${builds}" == 0 && "${saved_count}" == 0 ]] || fail 'authorization cancellation continued' ;;
      no-index|already-revoked) [[ "${status}" == 0 && "${confirmations}" == 0 && "${authorizations}" == 0 && "${builds}" == 0 ]] || fail 'unnecessary revocation attempted' ;;
      decline-revoke) [[ "${status}" == 1 && "${confirmations}" == 1 && "${authorizations}" == 0 && "${builds}" == 0 ]] || fail 'declined revocation continued' ;;
      offline) [[ "${status}" == 2 && "${builds}" == 0 ]] || fail 'offline chain build attempted' ;;
      unsigned) [[ "${signed_count}" == 0 && "${submitted_count}" == 0 && "${result}" == *'/saved/unsigned.json'* ]] || fail 'unsigned export workflow' ;;
      sign|decline) [[ "${signed_count}" == 1 && "${submitted_count}" == 0 && "${result}" == *'/saved/signed.json'* ]] || fail 'signed package not retained' ;;
      stale-before-sign) [[ "${status}" == 2 && "${signed_count}" == 0 && "${submitted_count}" == 0 ]] || fail 'signed stale authorization' ;;
      stale-before-submit) [[ "${status}" == 2 && "${signed_count}" == 1 && "${submitted_count}" == 0 && "${result}" == *'/saved/signed.json'* ]] || fail 'submitted stale authorization or lost recovery package' ;;
      failed) [[ "${status}" == 2 && "${submitted_count}" == 1 && "${result}" == *'/saved/signed.json'* ]] || fail 'failed submission lost recovery package' ;;
      live|expiry) [[ "${status}" == 0 && "${signed_count}" == 1 && "${submitted_count}" == 1 && "${monitored}" == 1 ]] || fail 'live workflow' ;;
    esac
    [[ "${scenario}" != expiry || "${builds}" == 2 ]] || fail 'expiry change did not rebuild'
  )
done
done
for scenario in offline active decline already-revoked no-index; do
  (
    CNTOOLS_CALIDUS_OPERATION=revoke CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y
    CNTOOLS_CALIDUS_REG_METADATA=/private/revocation.json CNTOOLS_CALIDUS_CHAIN_NONCE=100
    CNTOOLS_CALIDUS_REG_POOL=pool1example CNTOOLS_CALIDUS_CHAIN_ID=calidus1example CNTOOLS_LOG=/logs/cntools.log
    authorizations=0 confirmations=0 exports=0
    [[ "${scenario}" != offline ]] || CNTOOLS_MODE=offline
    cntools_ui_action_begin() { :; }
    cntools_transaction_log() { :; }
    cntools_ui_render_status() { :; }
    cntools_calidus_registration_identity() { :; }
    cntools_calidus_registration_render_identity() { :; }
    cntools_ui_spin_function() { shift; "$@"; }
    cntools_calidus_registration_lookup() {
      CNTOOLS_CALIDUS_CHAIN_STATUS='Registered (no local key)'
      CNTOOLS_CALIDUS_CHAIN_PUBLIC=registered-public CNTOOLS_CALIDUS_REG_PUBLIC=zero-public
      [[ "${scenario}" != already-revoked ]] || CNTOOLS_CALIDUS_CHAIN_STATUS=Revoked
      [[ "${scenario}" != no-index ]] || CNTOOLS_CALIDUS_CHAIN_STATUS='Not indexed'
      return 0
    }
    cntools_ui_confirm() { [[ "$2" == false ]] || fail 'metadata revocation default'; confirmations=$((confirmations+1)); [[ "${scenario}" != decline ]]; }
    cntools_calidus_registration_prompt_authorization() { authorizations=$((authorizations+1)); }
    cntools_transaction_save_into() {
      [[ "$2" == /private/revocation.json && "$3" == metadata && "$4" == calidus-revocation ]] || fail 'wrong revocation metadata export'
      exports=$((exports+1)); printf -v "$1" '%s' /saved/metadata.json
    }
    cntools_table_pair() { :; }
    cntools_table_render() { :; }
    status=0; cntools_calidus_registration_prepare_metadata 0 || status=$?
    case "${scenario}" in
      offline|active) [[ "${status}" == 0 && "${confirmations}" == 1 && "${authorizations}" == 1 && "${exports}" == 1 ]] || fail 'revocation metadata flow' ;;
      decline) [[ "${status}" == 1 && "${authorizations}" == 0 && "${exports}" == 0 ]] || fail 'declined metadata authorization' ;;
      already-revoked|no-index) [[ "${status}" == 0 && "${confirmations}" == 0 && "${authorizations}" == 0 && "${exports}" == 0 ]] || fail 'no-op metadata exported' ;;
    esac
  )
done
for operation in register revoke; do
  (
    CNTOOLS_CALIDUS_OPERATION="${operation}" CNTOOLS_CALIDUS_REG_ID=calidus1local CNTOOLS_CALIDUS_REG_POOL=pool1example
    CNTOOLS_CALIDUS_CHAIN_ID=calidus1indexed CNTOOLS_CALIDUS_REG_NONCE=101 CNTOOLS_CALIDUS_REG_METADATA=/frozen/metadata.json
    CNTOOLS_SEND_ADDRESS=address CNTOOLS_SEND_PAYMENT=address CNTOOLS_FUNDING_SLOT=100
    cntools_calidus_registration_state_recheck() { :; }
    cntools_funding_collect() { :; }
    cntools_transaction_expiry_into() { printf -v "$1" '%s' ''; }
    cntools_metadata_transaction_build_into() {
      [[ "$5" == /frozen/metadata.json ]] || fail 'unfrozen authorization used'
      jq -e --arg action "calidus-${operation}" '.action==$action and .pool=="pool1example" and .nonce=="101"' <<< "$4" >/dev/null || fail 'wrong refresh intent'
      if [[ "${operation}" == revoke ]]; then
        [[ "$2" == 'Revoke Calidus key' ]] || fail 'revocation mislabeled registration'
        jq -e '.revokedCalidusId=="calidus1indexed" and (has("calidusId")|not)' <<< "$4" >/dev/null || fail 'revocation identity context'
      else
        [[ "$2" == 'Register Calidus key' ]] || fail 'registration intent changed'
        jq -e '.calidusId=="calidus1local" and (has("revokedCalidusId")|not)' <<< "$4" >/dev/null || fail 'registration identity context'
      fi
    }
    cntools_calidus_registration_refresh_build_into package 0 || fail 'shared refresh adapter'
  )
done
(
  # Dynamic operation scope must not leak a zero-key target into later actions.
  CNTOOLS_CALIDUS_OPERATION=register CNTOOLS_LOG=/logs/cntools.log
  cntools_transaction_clear_error() { :; }
  cntools_ui_action_begin() { :; }
  cntools_ui_wait() { :; }
  cntools_calidus_registration_prepare_metadata() { [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke ]] || fail 'metadata operation scope'; }
  cntools_calidus_registration_workflow() { [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke ]] || fail 'transaction operation scope'; }
  cntools_calidus_registration_action 0 revoke-metadata
  cntools_calidus_registration_action 0 revoke
  [[ "${CNTOOLS_CALIDUS_OPERATION}" == register ]] || fail 'revocation operation leaked'
)
(
  # Identity rechecks must not discard a native wallet's reviewed signer subset.
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/multisig-spend.sh"
  CNTOOLS_MULTISIG_SIGNER_IDS=(selected-id); CNTOOLS_MULTISIG_SIGNER_HASHES=(selected-hash)
  CNTOOLS_MULTISIG_SIGNER_SOURCES=(selected-source); CNTOOLS_MULTISIG_SIGNER_LABELS=(selected-label)
  CNTOOLS_MULTISIG_SPEND_SCRIPT=/frozen/script CNTOOLS_MULTISIG_CAN_SIGN=Y
  CNTOOLS_SEND_DIRECTORY=/wallet CNTOOLS_SEND_ADDRESS=address CNTOOLS_SEND_PAYMENT=address CNTOOLS_SEND_CREDENTIAL=credential CNTOOLS_SEND_EXPIRY=''
  CNTOOLS_COIN_SELECTED_REFS=(ref)
  declare -A CNTOOLS_UTXO_INDEX_BY_REF=([ref]=0)
  cntools_calidus_registration_state_recheck() { :; }
  cntools_payment_prepare_wallet() {
    CNTOOLS_MULTISIG_SIGNER_IDS=(); CNTOOLS_MULTISIG_SIGNER_HASHES=(); CNTOOLS_MULTISIG_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_SIGNER_LABELS=()
    CNTOOLS_MULTISIG_SPEND_SCRIPT=/new/script CNTOOLS_MULTISIG_CAN_SIGN=N
    CNTOOLS_PAYMENT_ADDRESS=address CNTOOLS_PAYMENT_CREDENTIAL=credential
  }
  cntools_funding_collect() { :; }
  cntools_calidus_registration_recheck || fail 'native identity recheck'
  [[ "${CNTOOLS_MULTISIG_SIGNER_IDS[*]}" == selected-id && "${CNTOOLS_MULTISIG_SIGNER_HASHES[*]}" == selected-hash &&
     "${CNTOOLS_MULTISIG_SIGNER_SOURCES[*]}" == selected-source && "${CNTOOLS_MULTISIG_SIGNER_LABELS[*]}" == selected-label &&
     "${CNTOOLS_MULTISIG_SPEND_SCRIPT}" == /frozen/script && "${CNTOOLS_MULTISIG_CAN_SIGN}" == Y ]] || fail 'native signer selection lost during recheck'
)
(
  # Bypassing lost/corrupt Calidus files must never bypass directory safety.
  CNTOOLS_TRANSACTION_ERROR='' CNTOOLS_MODE=offline CNTOOLS_KOIOS_ENABLED=N
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/transaction.sh"
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/calidus-registration.sh"
  safe_root="$(mktemp -d "${TMPDIR:-/tmp}/cntools-calidus-safety.XXXXXX")"
  safe_root="$(cd "${safe_root}" && pwd -P)"
  trap 'rm -rf -- "${safe_root}"' EXIT
  cntools_transaction_log() { :; }
  mkdir -m700 "${safe_root}/pool"
  CNTOOLS_CALIDUS_REG_DIRECTORY="${safe_root}/pool"
  cntools_calidus_registration_directory_safe || fail 'owned pool rejected'
  chmod 0777 "${safe_root}/pool"
  ! cntools_calidus_registration_directory_safe || fail 'public writable pool accepted'
  CNTOOLS_POOL_DIRECTORIES=("${safe_root}/pool") CNTOOLS_POOL_IDENTITIES=('Verified cold public key')
  for CNTOOLS_CALIDUS_OPERATION in register revoke; do
    ! cntools_calidus_registration_identity 0 || fail 'identity bypassed unsafe directory'
    [[ "${CNTOOLS_TRANSACTION_ERROR}" == *'pool directory is unsafe'* ]] || fail 'unsafe directory diagnosed incorrectly'
  done
  chmod 0750 "${safe_root}/pool"
  cntools_calidus_registration_directory_safe || fail 'readable owned pool rejected'
  ln -s "${safe_root}/pool" "${safe_root}/link"
  CNTOOLS_CALIDUS_REG_DIRECTORY="${safe_root}/link"
  ! cntools_calidus_registration_directory_safe || fail 'pool symlink accepted'
  mkdir -m777 "${safe_root}/shared"
  chmod 0777 "${safe_root}/shared"
  mkdir -m700 "${safe_root}/shared/pool"
  CNTOOLS_CALIDUS_REG_DIRECTORY="${safe_root}/shared/pool"
  ! cntools_calidus_registration_directory_safe || fail 'unsafe pool ancestor accepted'
  CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://test.invalid/api/v1
  CNTOOLS_CALIDUS_OPERATION=revoke CNTOOLS_CALIDUS_REG_POOL=pool1example
  printf -v CNTOOLS_CALIDUS_REG_PUBLIC '%064d' 0
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${safe_root}/response.json"; }
  cntools_funding_get() {
    jq -n '[{pool_id_bech32:"pool1example",calidus_nonce:"100",calidus_pub_key:("ab"*32),
      calidus_id_bech32:"calidus1example",tx_hash:("cd"*32),registered:true}]' > "$2"
  }
  cntools_uint_greater_equal() { [[ "$1" == 9007199254740991 && "$2" == 100 ]]; }
  cntools_calidus_registration_lookup || fail 'active revocation lookup'
  [[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == Registered ]] || fail 'revocation status implies a different local key'
)
printf 'PASS: Calidus registration/revocation workflows, no-op safeguards, expiry, cancellation and recovery exports\n'
