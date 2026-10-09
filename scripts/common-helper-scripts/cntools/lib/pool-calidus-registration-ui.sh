#!/usr/bin/env bash
# Calidus authorization and publication through the common transaction UX.
# shellcheck disable=SC2034,SC2015
CNTOOLS_CALIDUS_REG_REVIEW_STATE=''

cntools_calidus_registration_begin() { cntools_ui_action_begin Calidus '/ Pool / Calidus'; }

cntools_calidus_registration_render_identity() {
  {
    cntools_table_pair Pool "${CNTOOLS_CALIDUS_REG_DIRECTORY##*/}" identifier
    cntools_table_pair 'Pool ID' "${CNTOOLS_CALIDUS_REG_POOL}" identifier
    [[ "${CNTOOLS_CALIDUS_OPERATION}" != revoke ]] || cntools_table_pair Operation 'Revoke Calidus authorization' warning
    [[ -z "${CNTOOLS_CALIDUS_REG_ID}" ]] || cntools_table_pair 'Calidus ID' "${CNTOOLS_CALIDUS_REG_ID}" identifier
    cntools_table_pair 'On-chain registration' "${CNTOOLS_CALIDUS_CHAIN_STATUS}" value
    [[ -z "${CNTOOLS_CALIDUS_CHAIN_ID}" ]] || cntools_table_pair 'Indexed Calidus ID' "${CNTOOLS_CALIDUS_CHAIN_ID}" identifier
    [[ -z "${CNTOOLS_CALIDUS_REG_NONCE}" ]] || cntools_table_pair 'Authorization nonce' "$(cntools_number_format "${CNTOOLS_CALIDUS_REG_NONCE}")" number
    [[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == 'Not checked' ]] || cntools_table_pair 'Registration source' 'Koios API · latest indexed authorization' muted
  } | cntools_table_render Calidus
}

cntools_calidus_revocation_active() {
  if [[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == Revoked ]]; then
    cntools_ui_render_status info 'The latest indexed Calidus authorization is already revoked. No transaction is needed.'
    return 1
  elif [[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == 'Not indexed' ]]; then
    cntools_ui_render_status info 'Koios has no indexed Calidus authorization to revoke. Check any pending registration before retrying.'
    return 1
  fi
  [[ -n "${CNTOOLS_CALIDUS_CHAIN_PUBLIC}" && "${CNTOOLS_CALIDUS_CHAIN_PUBLIC}" != "${CNTOOLS_CALIDUS_REG_PUBLIC}" ]]
}

cntools_calidus_revocation_confirm() {
  cntools_ui_render_status warn 'This revokes all previous Calidus authorizations for this pool without registering a replacement key. It does not retire the pool, stop the node or delete local keys.'
  cntools_ui_confirm "Revoke this pool's Calidus authorization?" false || return $?
  cntools_transaction_log CHOICE "Calidus revocation confirmed pool=${CNTOOLS_CALIDUS_REG_POOL} indexed=${CNTOOLS_CALIDUS_CHAIN_ID:-unchecked} nonce=${CNTOOLS_CALIDUS_CHAIN_NONCE:-unchecked}"
}

cntools_calidus_registration_prompt_authorization() {
  local choice='' nonce='' default_nonce='' source='' status=0
  [[ "${CNTOOLS_CALIDUS_CHAIN_NONCE}" != 9007199254740991 ]] || {
    cntools_calidus_registration_fail 'The indexed nonce is already at the supported Cardano Signer maximum; a newer authorization cannot be prepared with this tool.'; return 2;
  }
  cntools_ui_choose choice 'Pool cold-key authorization' 'Import signed metadata (offline cold key)' 'Authorize with local CLI cold key' Cancel || return $?
  [[ "${choice}" != Cancel ]] || return 1
  if [[ "${choice}" == 'Import signed metadata (offline cold key)' ]]; then
    cntools_ui_input source 'Signed CIP-151 metadata file' 'Absolute path · original file is retained' || return $?
    cntools_ui_spin_function 'Verifying the pool cold-key authorization…' cntools_calidus_registration_verify "${source}" || return 2
    return 0
  fi
  [[ "${choice}" == 'Authorize with local CLI cold key' ]] || return 2
  if [[ "${CNTOOLS_MODE:-}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y ]]; then
    cntools_ui_spin_function 'Fetching a current slot for the authorization nonce…' cntools_funding_tip_into default_nonce koios || return 2
    if [[ -n "${CNTOOLS_CALIDUS_CHAIN_NONCE}" ]] && ! cntools_uint_greater "${default_nonce}" "${CNTOOLS_CALIDUS_CHAIN_NONCE}"; then
      cntools_uint_add_into default_nonce "${CNTOOLS_CALIDUS_CHAIN_NONCE}" 1 || return 2
    fi
  fi
  while true; do
    cntools_ui_input nonce 'Authorization nonce' "${default_nonce:-A whole number higher than the last on-chain nonce}" || return $?
    nonce="${nonce:-${default_nonce}}"
    cntools_number_normalize_into nonce "${nonce}" || nonce=invalid
    cntools_calidus_registration_nonce_valid "${nonce}" && break
    cntools_ui_render_status warn 'Enter an exact whole nonce from 0 to 9,007,199,254,740,991, higher than the last indexed registration.'
  done
  if [[ "${CNTOOLS_MODE:-}" == offline || "${CNTOOLS_KOIOS_ENABLED:-N}" != Y ]]; then
    cntools_ui_render_status warn 'On-chain nonce has not been checked. Check it online before signing; stale metadata cannot replace a newer authorization.'
  fi
  if [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke ]]; then
    cntools_ui_render_status warn 'The pool cold key will sign revocation metadata. No Calidus signing key is needed and no transaction is submitted at this step.'
    cntools_ui_confirm 'Sign this Calidus revocation with the pool cold key?' false || return $?
  else
    cntools_ui_render_status warn 'This authorizes the displayed Calidus public key using the pool cold key. It does not need the Calidus signing key and does not submit a transaction.'
    cntools_ui_confirm 'Authorize this Calidus key for this pool?' false || return $?
  fi
  cntools_transaction_log CHOICE "Calidus authorization confirmed operation=${CNTOOLS_CALIDUS_OPERATION} pool=${CNTOOLS_CALIDUS_REG_POOL} nonce=${nonce}"
  cntools_ui_spin_function 'Signing and verifying Calidus authorization…' cntools_calidus_registration_authorize "${nonce}" || status=$?
  ((status == 0)) || return 2
}

cntools_calidus_registration_prepare_metadata() {
  local index="$1" saved='' action=calidus-authorization next='Register / replace on-chain'
  cntools_calidus_registration_identity "${index}" || return 2
  if [[ "${CNTOOLS_MODE:-}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y ]]; then
    cntools_ui_spin_function 'Checking Calidus registration through Koios…' cntools_calidus_registration_lookup || return 2
  fi
  cntools_calidus_registration_render_identity || return 2
  if [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke ]]; then
    if [[ "${CNTOOLS_MODE:-}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y ]]; then
      cntools_calidus_revocation_active || return 0
    else
      cntools_ui_render_status warn 'The active Calidus key and nonce have not been checked. Verify them online before using this revocation metadata.'
    fi
    cntools_calidus_revocation_confirm || return $?
    action=calidus-revocation next='Revoke on-chain'
  fi
  cntools_calidus_registration_prompt_authorization || return $?
  cntools_transaction_save_into saved "${CNTOOLS_CALIDUS_REG_METADATA}" metadata "${action}" || return 2
  cntools_calidus_registration_begin
  {
    cntools_table_pair Status 'Cold-key authorization verified · no transaction submitted' success
    cntools_table_pair 'Metadata file' "${saved}" identifier
  } | cntools_table_render 'Calidus authorization'
  cntools_ui_render_status info "Move only this public metadata to the online system. Choose ${next} → Import signed metadata. Keep the pool cold key offline."
}

cntools_calidus_registration_state_recheck() {
  local cold='' old_metadata="${CNTOOLS_CALIDUS_REG_METADATA}"
  cntools_calidus_registration_directory_safe && cntools_pool_file_name_into cold cold-vkey &&
    cntools_pool_key_validate "${CNTOOLS_CALIDUS_REG_DIRECTORY}/${cold}" cold verification &&
    jq -es 'length==2 and (.[0].cborHex|ascii_downcase)==(.[1].cborHex|ascii_downcase)' \
      "${CNTOOLS_CALIDUS_REG_COLD}" "${CNTOOLS_CALIDUS_REG_DIRECTORY}/${cold}" >/dev/null || {
    cntools_calidus_registration_fail 'The pool or Calidus identity changed. Reopen Calidus and review again.'; return 1;
  }
  if [[ "${CNTOOLS_CALIDUS_OPERATION}" == register ]]; then
    cntools_calidus_inspect "${CNTOOLS_CALIDUS_REG_DIRECTORY}" && [[ "${CNTOOLS_CALIDUS_PUBLIC}" == "${CNTOOLS_CALIDUS_REG_PUBLIC}" ]] || {
      cntools_calidus_registration_fail 'The local Calidus identity changed. Reopen Calidus and review again.'; return 1;
    }
  fi
  cntools_calidus_registration_lookup || return 1
  [[ "${CNTOOLS_CALIDUS_CHAIN_STATE}" == "${CNTOOLS_CALIDUS_REG_REVIEW_STATE}" ]] || {
    cntools_calidus_registration_fail 'The indexed Calidus authorization changed. Reopen Calidus and review the new state.'; return 1;
  }
  cntools_calidus_registration_verify "${old_metadata}"
}

cntools_calidus_registration_refresh_build_into() {
  local result="$1" lifetime="$2" context='' intent='Register Calidus key' description="Publish the pool cold-key authorization for ${CNTOOLS_CALIDUS_REG_ID}."
  cntools_calidus_registration_state_recheck && cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" &&
    cntools_transaction_expiry_into CNTOOLS_SEND_EXPIRY "${CNTOOLS_FUNDING_SLOT}" "${lifetime}" || return 1
  context="$(jq -cn --arg operation "${CNTOOLS_CALIDUS_OPERATION}" --arg pool "${CNTOOLS_CALIDUS_REG_POOL}" \
    --arg id "${CNTOOLS_CALIDUS_REG_ID}" --arg indexed "${CNTOOLS_CALIDUS_CHAIN_ID}" --arg nonce "${CNTOOLS_CALIDUS_REG_NONCE}" \
    '{action:("calidus-"+$operation),pool:$pool,nonce:$nonce,authorization:"CIP-151 / pool cold-key COSE signature"} +
      (if $operation=="revoke" then {revokedCalidusId:$indexed} else {calidusId:$id} end)')" || return 1
  if [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke ]]; then
    intent='Revoke Calidus key'; description='Revoke all previous Calidus authorizations without a replacement; pool registration and local keys stay unchanged.'
  fi
  cntools_metadata_transaction_build_into "${result}" "${intent}" "${description}" "${context}" "${CNTOOLS_CALIDUS_REG_METADATA}"
}

cntools_calidus_registration_recheck() {
  local reference='' identity='' credential=''
  local -a references=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  # Re-preparing a native wallet clears its selector state. Keep the reviewed
  # subset and script scoped here; the frozen transaction plan is unchanged.
  local -a CNTOOLS_MULTISIG_SIGNER_IDS=("${CNTOOLS_MULTISIG_SIGNER_IDS[@]}") CNTOOLS_MULTISIG_SIGNER_HASHES=("${CNTOOLS_MULTISIG_SIGNER_HASHES[@]}")
  local -a CNTOOLS_MULTISIG_SIGNER_SOURCES=("${CNTOOLS_MULTISIG_SIGNER_SOURCES[@]}") CNTOOLS_MULTISIG_SIGNER_LABELS=("${CNTOOLS_MULTISIG_SIGNER_LABELS[@]}")
  local CNTOOLS_MULTISIG_SPEND_SCRIPT="${CNTOOLS_MULTISIG_SPEND_SCRIPT}" CNTOOLS_MULTISIG_CAN_SIGN="${CNTOOLS_MULTISIG_CAN_SIGN}"
  local CNTOOLS_MULTISIG_SPEND_THRESHOLD="${CNTOOLS_MULTISIG_SPEND_THRESHOLD}"
  local CNTOOLS_MULTISIG_SPEND_AFTER="${CNTOOLS_MULTISIG_SPEND_AFTER}" CNTOOLS_MULTISIG_SPEND_BEFORE="${CNTOOLS_MULTISIG_SPEND_BEFORE}"
  cntools_calidus_registration_state_recheck || return 1
  cntools_payment_prepare_wallet "${CNTOOLS_SEND_DIRECTORY}" multisig || return 1
  identity="${CNTOOLS_PAYMENT_ADDRESS}"; credential="${CNTOOLS_PAYMENT_CREDENTIAL}"
  [[ "${identity}" == "${CNTOOLS_SEND_ADDRESS}" && "${credential}" == "${CNTOOLS_SEND_CREDENTIAL}" ]] || {
    cntools_calidus_registration_fail 'The funding wallet identity changed. Rebuild and review the transaction.'; return 1;
  }
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  [[ -z "${CNTOOLS_SEND_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_SEND_EXPIRY )) || {
    cntools_calidus_registration_fail 'The transaction expired. Build and review it again.'; return 1;
  }
  for reference in "${references[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${reference}]+x}" ]] || {
      cntools_calidus_registration_fail 'A selected funding input is no longer available. Rebuild and review.'; return 1;
    }
  done
}

cntools_calidus_registration_render_review() {
  local expiry='' total=0 value=''
  cntools_calidus_registration_render_identity || return 1
  for value in "${CNTOOLS_CHANGE_OUTPUT_LOVELACE[@]}"; do cntools_uint_add_into total "${total}" "${value}" || return 1; done
  cntools_transaction_ui_expiry_label_into expiry "${CNTOOLS_SEND_EXPIRY}"
  {
    cntools_table_pair 'Funding wallet' "${CNTOOLS_SEND_WALLET}" identifier
    cntools_table_pair Fee "$(cntools_number_format_lovelace "${CNTOOLS_SEND_FEE}")" number
    cntools_table_pair 'Returned change' "$(cntools_number_format_lovelace "${total}")" number
    cntools_table_pair 'Input selection' "${CNTOOLS_TX_SELECTION_STRATEGY} · $(cntools_number_format "${#CNTOOLS_COIN_SELECTED_REFS[@]}") inputs" value
    cntools_table_pair 'Token fragmentation' "${CNTOOLS_CHANGE_TOKEN_STATUS}" value
    cntools_table_pair 'ADA-only management' "${CNTOOLS_CHANGE_UTXO_STATUS}" value
    cntools_table_pair 'Collateral candidate' "${CNTOOLS_CHANGE_COLLATERAL_STATUS}" value
    cntools_table_pair Expires "${expiry}" number
  } | cntools_table_render 'Transaction information'
  cntools_ui_render_status info 'No deposit or refund. The funding wallet pays only the transaction fee; all selected funds and assets return as change.'
  [[ "${CNTOOLS_CALIDUS_OPERATION}" != revoke ]] || cntools_ui_render_status warn 'Only Calidus authorization is revoked. The pool remains registered and local keys are retained.'
}

cntools_calidus_registration_workflow() {
  local index="$1" selected='' workflow='' can_sign=N lifetime=1800 staged='' signed='' saved='' proceed='' backend='' txid='' body='' status=0
  [[ "${CNTOOLS_MODE:-}" != offline ]] || {
    cntools_calidus_registration_fail 'Prepare cold-key authorization offline, then build online with current chain data. The funding transaction can still be exported for offline signing.'; return 2;
  }
  cntools_calidus_registration_identity "${index}" || return 2
  cntools_ui_spin_function 'Checking the latest Calidus authorization through Koios…' cntools_calidus_registration_lookup || return 2
  CNTOOLS_CALIDUS_REG_REVIEW_STATE="${CNTOOLS_CALIDUS_CHAIN_STATE}"
  cntools_calidus_registration_render_identity || return 2
  if [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke ]]; then
    cntools_calidus_revocation_active || return 0
    cntools_calidus_revocation_confirm || return $?
  elif [[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == 'This key registered' ]]; then
    cntools_ui_confirm 'This Calidus key is already indexed. Publish a newer authorization anyway?' false || return $?
  elif [[ "${CNTOOLS_CALIDUS_CHAIN_STATUS}" == 'Different key registered' ]]; then
    cntools_ui_render_status warn 'This transaction replaces the indexed Calidus key. Review the local Calidus ID before proceeding.'
  fi
  cntools_calidus_signer_require || return 2
  cntools_calidus_registration_prompt_authorization || return $?
  cntools_wallet_catalog_build || return 2
  cntools_ui_render_detail 'Funding wallet'
  cntools_wallet_choose selected Cancel send || return $?
  cntools_send_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" multisig || return 2
  [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || cntools_multisig_spend_choose_signers cntools_calidus_registration_begin || return $?
  [[ -z "${CNTOOLS_SEND_SOURCE}" ]] || can_sign=Y
  [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || can_sign="${CNTOOLS_MULTISIG_CAN_SIGN}"
  cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?
  while true; do
    cntools_transaction_ui_expiry_into lifetime || return $?
    cntools_ui_spin_function 'Checking authorization and balancing the funding transaction…' cntools_calidus_registration_refresh_build_into staged "${lifetime}" || return 2
    while true; do
      cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
      cntools_transaction_ui_review_into selected "${staged}" "${proceed}" cntools_calidus_registration_begin \
        cntools_calidus_registration_render_review 'Change expiry' 'Change workflow' || return $?
      case "${selected}" in
        "${proceed}"|'Change expiry') break ;;
        'Change workflow') cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $? ;;
        *) return 2 ;;
      esac
    done
    [[ "${selected}" != "${proceed}" ]] || break
  done
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned "calidus-${CNTOOLS_CALIDUS_OPERATION}" || return 2
    cntools_calidus_registration_begin
    cntools_transaction_ui_render_result success 'Ready for offline funding-wallet signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function 'Rechecking authorization and funding inputs…' cntools_calidus_registration_recheck || return 2
  cntools_ui_spin_function 'Signing the funding transaction…' cntools_transaction_sign_registered "${staged}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" || return 2
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || { cntools_calidus_registration_fail 'The funding package still needs witnesses.'; return 2; }
  cntools_transaction_save_into saved "${signed}" signed "calidus-${CNTOOLS_CALIDUS_OPERATION}" || return 2
  if [[ "${workflow}" == 'Create and sign' ]]; then
    cntools_calidus_registration_begin
    cntools_transaction_ui_render_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  if ! cntools_transaction_ui_confirm_submit "${backend}"; then
    cntools_calidus_registration_begin
    cntools_transaction_ui_render_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    return $?
  fi
  cntools_ui_spin_function 'Rechecking authorization and funding inputs…' cntools_calidus_registration_recheck || status=$?
  if ((status == 0)); then cntools_ui_spin_function "Submitting Calidus ${CNTOOLS_CALIDUS_OPERATION} transaction…" cntools_transaction_ui_submit_selected "${backend}" "${body}" "${txid}" || status=$?; fi
  cntools_calidus_registration_begin
  if ((status != 0)); then
    cntools_transaction_ui_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check the chain before retrying.}" "${txid}" "${saved}"
    return 2
  fi
  cntools_transaction_ui_render_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Calidus indexing follows block inclusion." "${txid}" || return 2
  cntools_transaction_ui_offer_monitor "${txid}"
}

cntools_calidus_registration_action() {
  local index="$1" operation="$2" status=0
  local CNTOOLS_CALIDUS_OPERATION=register
  [[ "${operation}" != revoke && "${operation}" != revoke-metadata ]] || CNTOOLS_CALIDUS_OPERATION=revoke
  cntools_transaction_clear_error
  cntools_calidus_registration_begin
  case "${operation}" in
    status)
      cntools_calidus_registration_identity "${index}" allow-missing &&
        cntools_ui_spin_function 'Checking Calidus registration through Koios…' cntools_calidus_registration_lookup || status=2
      ((status != 0)) || cntools_calidus_registration_render_identity || status=2 ;;
    metadata|revoke-metadata) cntools_calidus_registration_prepare_metadata "${index}" || status=$? ;;
    register|revoke) cntools_calidus_registration_workflow "${index}" || status=$? ;;
    *) return 2 ;;
  esac
  if ((status == 1)); then
    cntools_ui_render_status info 'Cancelled. Any already saved metadata or transaction packages were retained.'
  elif ((status != 0)); then
    cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR:-Calidus authorization failed.} See ${CNTOOLS_LOG} for details."
  fi
  cntools_ui_wait
  ((status <= 1))
}
