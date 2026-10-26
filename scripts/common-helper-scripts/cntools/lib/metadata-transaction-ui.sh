#!/usr/bin/env bash
# Shared fee-only metadata workflow. Callbacks own authorization and rechecks.
# shellcheck disable=SC2034,SC2015

cntools_metadata_transaction_render_review() {
  local expiry='' total=0 coin='' widths='' untouched=0
  "${mt_identity_render}" || return 1
  for coin in "${CNTOOLS_CHANGE_OUTPUT_LOVELACE[@]}"; do cntools_uint_add_into total "${total}" "${coin}" || return 1; done
  cntools_transaction_ui_expiry_label_into expiry "${CNTOOLS_SEND_EXPIRY}" || return 1
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  # Reference-script UTxOs (funding) and datum UTxOs (this build) stay put.
  untouched=$(( ${CNTOOLS_FUNDING_REFERENCE_SKIPPED:-0} + ${CNTOOLS_METADATA_TRANSACTION_SKIPPED:-0} ))
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Transaction detail\tValue\n'
    # The identity table already names the wallet when it also funds.
    [[ -n "${mt_identity_directory}" && "${mt_identity_directory}" == "${CNTOOLS_SEND_DIRECTORY}" ]] ||
      cntools_transaction_ui_styled_row 'Funding wallet' "${CNTOOLS_SEND_WALLET}" identifier
    cntools_transaction_ui_styled_row Fee "$(cntools_number_format_lovelace "${CNTOOLS_SEND_FEE}")" number
    cntools_transaction_ui_styled_row 'Returned change' "$(cntools_number_format_lovelace "${total}")" number
    # Readable strategy; rows for disabled change features are left out.
    cntools_transaction_ui_render_policy_rows "${CNTOOLS_TX_SELECTION_STRATEGY}" "${#CNTOOLS_COIN_SELECTED_REFS[@]}"
    cntools_transaction_ui_untouched_row "${untouched}"
    cntools_transaction_ui_styled_row Expires "${expiry}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
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

# Saves the reviewed staged package for signing elsewhere and shows where.
cntools_metadata_transaction_save_unsigned() {
  local su_saved=''
  cntools_transaction_save_into su_saved "$1" unsigned "${mt_action}" || return 2
  "${mt_begin}"
  cntools_transaction_ui_render_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${su_saved}"
}

cntools_metadata_transaction_workflow() {
  local mt_action="$1" mt_intent="$2" mt_description="$3" mt_context="$4" mt_metadata="$5"
  local mt_begin="$6" mt_identity_render="$7" mt_recheck="$8" mt_identity_directory="${9:-}"
  local choice='' workflow='' proceed='' lifetime=1800 staged='' signed='' saved='' backend='' txid='' body='' status=0 can_sign=N change_status=0 previous=''
  # Y once a failure result is on screen, so the caller adds no error banner.
  CNTOOLS_METADATA_TRANSACTION_RESULT_SHOWN=N
  # All authorization checks and builds consume the same private snapshot,
  # never an exported public file that could be edited during the wizard.
  cntools_transaction_snapshot_into mt_metadata "${mt_metadata}" 65536 metadata-workflow || return 2
  [[ -z "${CNTOOLS_SEND_SOURCE}" ]] || can_sign=Y
  # A payment key present only encrypted: the review says how to sign here.
  [[ "${can_sign}" == Y ]] || cntools_transaction_ui_encrypted_reason_set 'Wallet → Decrypt' \
    "${CNTOOLS_SEND_DIRECTORY}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME:-payment.skey}" || true
  cntools_transaction_ui_initial_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_initial_expiry_into lifetime || return $?
  while true; do
    status=0
    "${mt_recheck}" "${mt_metadata}" && cntools_ui_spin_function 'Fetching current funding data…' cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" &&
      cntools_transaction_expiry_into CNTOOLS_SEND_EXPIRY "${CNTOOLS_FUNDING_SLOT}" "${lifetime}" &&
      cntools_ui_spin_function 'Balancing and verifying the metadata transaction…' cntools_metadata_transaction_build_into staged \
        "${mt_intent}" "${mt_description}" "${mt_context}" "${mt_metadata}" || status=$?
    if ((status != 0)); then
      # A failed rebuild after a Change step restores the reviewed values.
      [[ -n "${previous}" ]] || return 2
      cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR:-The transaction could not be rebuilt.} The previous expiry and workflow are kept."
      CNTOOLS_TRANSACTION_ERROR=''; CNTOOLS_TRANSACTION_UI_NOTICE=''
      lifetime="${previous%%|*}" workflow="${previous#*|}" previous=''
      continue
    fi
    previous="${lifetime}|${workflow}"
    while true; do
      cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
      cntools_transaction_ui_review_into choice "${staged}" "${proceed}" "${mt_begin}" cntools_metadata_transaction_render_review \
        'Change expiry' 'Change workflow' || return $?
      # Esc in a Change step keeps the current value and returns to the review.
      change_status=0
      case "${choice}" in
        "${proceed}") break ;;
        'Change expiry')
          cntools_transaction_ui_expiry_into lifetime || change_status=$?
          ((change_status == 0)) && break ;;
        'Change workflow')
          cntools_transaction_ui_workflow_into workflow "${can_sign}" || change_status=$?
          if ((change_status == 0)); then
            # Quick gives a new unsigned package a day: rebuild with it.
            ! cntools_transaction_ui_unsigned_lifetime_into lifetime "${workflow}" || break
            # Accepted without a rebuild: a later failed rebuild keeps it.
            previous="${lifetime}|${workflow}"
          fi ;;
        *) return 2 ;;
      esac
      ((change_status <= 1)) || return "${change_status}"
    done
    [[ "${choice}" != "${proceed}" ]] || break
  done
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_metadata_transaction_save_unsigned "${staged}"
    return $?
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function 'Rechecking authorization and funding inputs…' cntools_metadata_transaction_inputs_recheck || return 2
  cntools_transaction_ui_recheck_mark
  # A device or key failure offers Retry, Save unsigned package or Cancel.
  status=0
  cntools_transaction_ui_sign_staged 'the funding transaction' "${staged}" "${signed}" || status=$?
  if ((status == 4)); then
    cntools_metadata_transaction_save_unsigned "${staged}"
    return $?
  fi
  ((status == 0)) || return "${status}"
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
  # Local keys signed seconds ago: the pre-sign recheck still holds.
  if cntools_transaction_ui_recheck_due; then
    cntools_ui_spin_function 'Rechecking authorization and funding inputs…' cntools_metadata_transaction_inputs_recheck || status=$?
    ((status != 0)) || cntools_transaction_ui_recheck_mark
  fi
  if ((status == 0)); then cntools_ui_spin_function 'Submitting the metadata transaction…' cntools_transaction_ui_submit_selected "${backend}" "${body}" "${txid}" || status=$?; fi
  "${mt_begin}"
  if ((status != 0)); then
    cntools_transaction_ui_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check inclusion before retrying.}" "${txid}" "${saved}"
    CNTOOLS_METADATA_TRANSACTION_RESULT_SHOWN=Y
    return 2
  fi
  cntools_transaction_ui_render_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE}" "${txid}" || return 2
  cntools_transaction_ui_offer_monitor "${txid}"
}
