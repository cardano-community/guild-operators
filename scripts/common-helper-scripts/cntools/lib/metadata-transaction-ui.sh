#!/usr/bin/env bash
# Shared fee-only metadata workflow. Callbacks own authorization and rechecks.
# shellcheck disable=SC2034,SC2015

cntools_metadata_transaction_render_review() {
  local expiry='' total=0 coin=''
  "${mt_identity_render}" || return 1
  for coin in "${CNTOOLS_CHANGE_OUTPUT_LOVELACE[@]}"; do cntools_uint_add_into total "${total}" "${coin}" || return 1; done
  cntools_transaction_ui_expiry_label_into expiry "${CNTOOLS_SEND_EXPIRY}" || return 1
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
  cntools_ui_render_status info 'Only the transaction fee is spent. All selected funds and assets return as change.'
}

cntools_metadata_transaction_inputs_recheck() {
  local reference='' address="${CNTOOLS_SEND_ADDRESS}" credential="${CNTOOLS_SEND_CREDENTIAL}"
  local -a reviewed=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  "${mt_recheck}" "${mt_metadata}" && cntools_payment_prepare_wallet "${CNTOOLS_SEND_DIRECTORY}" &&
    [[ "${CNTOOLS_PAYMENT_ADDRESS}" == "${address}" && "${CNTOOLS_PAYMENT_CREDENTIAL}" == "${credential}" ]] &&
    cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  [[ -z "${CNTOOLS_SEND_EXPIRY}" ]] || ((CNTOOLS_FUNDING_SLOT < CNTOOLS_SEND_EXPIRY)) || {
    cntools_transaction_set_error 'The transaction expired. Rebuild and review it.'; return 1;
  }
  for reference in "${reviewed[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${reference}]+x}" ]] || {
      cntools_transaction_set_error 'A reviewed funding input is no longer available. Rebuild and review.'; return 1;
    }
  done
}

cntools_metadata_transaction_workflow() {
  local mt_action="$1" mt_intent="$2" mt_description="$3" mt_context="$4" mt_metadata="$5"
  local mt_begin="$6" mt_identity_render="$7" mt_recheck="$8"
  local choice='' workflow='' proceed='' lifetime=1800 staged='' signed='' saved='' backend='' txid='' body='' status=0 can_sign=N
  # All authorization checks and builds consume the same private snapshot,
  # never an exported public file that could be edited during the wizard.
  cntools_transaction_snapshot_into mt_metadata "${mt_metadata}" 65536 metadata-workflow || return 2
  [[ -z "${CNTOOLS_SEND_SOURCE}" ]] || can_sign=Y
  cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?
  while true; do
    cntools_transaction_ui_expiry_into lifetime || return $?
    "${mt_recheck}" "${mt_metadata}" && cntools_ui_spin_function 'Fetching current funding data…' cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" &&
      cntools_transaction_expiry_into CNTOOLS_SEND_EXPIRY "${CNTOOLS_FUNDING_SLOT}" "${lifetime}" || return 2
    cntools_ui_spin_function 'Balancing and verifying the metadata transaction…' cntools_metadata_transaction_build_into staged \
      "${mt_intent}" "${mt_description}" "${mt_context}" "${mt_metadata}" || return 2
    while true; do
      cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
      cntools_transaction_ui_review_into choice "${staged}" "${proceed}" "${mt_begin}" cntools_metadata_transaction_render_review \
        'Change expiry' 'Change workflow' || return $?
      case "${choice}" in
        "${proceed}"|'Change expiry') break ;;
        'Change workflow') cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $? ;;
        *) return 2 ;;
      esac
    done
    [[ "${choice}" != "${proceed}" ]] || break
  done
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned "${mt_action}" || return 2
    "${mt_begin}"
    cntools_transaction_ui_render_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function 'Rechecking authorization and funding inputs…' cntools_metadata_transaction_inputs_recheck || return 2
  cntools_ui_spin_function 'Signing the funding transaction…' cntools_transaction_sign_registered "${staged}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" && [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || return 2
  cntools_transaction_save_into saved "${signed}" signed "${mt_action}" || return 2
  if [[ "${workflow}" == 'Create and sign' ]]; then
    "${mt_begin}"
    cntools_transaction_ui_render_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  if ! cntools_transaction_ui_confirm_submit "${backend}"; then
    "${mt_begin}"
    cntools_transaction_ui_render_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    return $?
  fi
  cntools_ui_spin_function 'Rechecking authorization and funding inputs…' cntools_metadata_transaction_inputs_recheck || status=$?
  if ((status == 0)); then cntools_ui_spin_function 'Submitting the metadata transaction…' cntools_transaction_ui_submit_selected "${backend}" "${body}" "${txid}" || status=$?; fi
  "${mt_begin}"
  if ((status != 0)); then
    cntools_transaction_ui_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check inclusion before retrying.}" "${txid}" "${saved}"
    return 2
  fi
  cntools_transaction_ui_render_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE}" "${txid}" || return 2
  cntools_transaction_ui_offer_monitor "${txid}"
}
