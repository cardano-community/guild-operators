#!/usr/bin/env bash
# Guided self-collection using the common transaction review/sign/submit flow.
# shellcheck disable=SC2034
cntools_collect_begin() { cntools_ui_action_begin 'Collect UTxOs' '/ Funds / Collect UTxOs'; }

cntools_collect_render() {
  local widths="" expiry_label="" scope='ADA-only UTxOs'
  [[ "${CNTOOLS_COLLECT_SCOPE}" != all ]] || scope='ADA and native assets'
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_transaction_ui_expiry_label_into expiry_label "${CNTOOLS_SEND_EXPIRY}" || return 1
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Property\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${CNTOOLS_SEND_WALLET}" identifier
    cntools_transaction_ui_styled_row Scope "${scope}" status
    cntools_transaction_ui_styled_row 'Return address' "${CNTOOLS_SEND_ADDRESS}" address
    cntools_transaction_ui_styled_row 'Collected ADA' "$(cntools_wallet_format_lovelace "${CNTOOLS_COIN_SELECTED_LOVELACE}")" number
    cntools_transaction_ui_styled_row 'Native assets' "$(cntools_number_format "${CNTOOLS_COIN_SELECTED_ASSET_COUNT}")" number
    cntools_transaction_ui_styled_row Fee "$(cntools_wallet_format_lovelace "${CNTOOLS_COLLECT_FEE}")" number
    cntools_transaction_ui_styled_row 'Resulting outputs' "$(cntools_number_format "${CNTOOLS_COLLECT_OUTPUT_COUNT}")" number
    cntools_transaction_ui_styled_row 'Inputs left untouched' "$(cntools_number_format "${CNTOOLS_COLLECT_SKIPPED}")" number
    cntools_transaction_ui_render_policy_rows 'All eligible inputs' "${#CNTOOLS_COLLECT_INPUTS[@]}"
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  cntools_ui_render_status info 'Funds stay in this wallet, less the fee. Rewards, deposits and delegation are unchanged. Datum and reference-script outputs are left untouched.'
  if (( CNTOOLS_COLLECT_OUTPUT_COUNT >= ${#CNTOOLS_COLLECT_INPUTS[@]} )); then
    cntools_ui_render_status warn 'Your change settings produce as many or more outputs than the selected inputs. This reshapes funds rather than reducing the UTxO count.'
  fi
}

cntools_collect_result() {
  cntools_transaction_ui_render_result "$@" || return 1
  CNTOOLS_COLLECT_RESULT_SHOWN=Y
}

cntools_collect_workflow() {
  local selected="" workflow="" staged="" signed="" saved="" proceed="" scope="" can_sign=N
  local backend="" signed_body="" txid="" lifetime=1800 status=0
  CNTOOLS_COLLECT_RESULT_SHOWN=N; CNTOOLS_COLLECT_SAVED_PACKAGE=""
  cntools_collect_begin
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  (( ${#CNTOOLS_WALLET_NAMES[@]} > 0 )) || { cntools_collect_fail 'No wallets are available.'; return 2; }
  cntools_wallet_choose selected Cancel collect || return $?
  cntools_send_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" || return 2
  [[ -z "${CNTOOLS_SEND_SOURCE}" ]] || can_sign=Y
  cntools_ui_choose scope 'Collect which UTxOs?' 'ADA-only UTxOs' 'ADA and native assets' 'Cancel' || return $?
  case "${scope}" in
    'ADA-only UTxOs') CNTOOLS_COLLECT_SCOPE=ada ;;
    'ADA and native assets') CNTOOLS_COLLECT_SCOPE=all ;;
    *) return 1 ;;
  esac
  cntools_transaction_log CHOICE "Collection scope=${CNTOOLS_COLLECT_SCOPE}"
  cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_expiry_into lifetime || return $?
  cntools_ui_spin_function 'Checking funds and building the collection…' \
    cntools_collect_refresh_build_into staged "${lifetime}" || return 2
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into selected "${staged}" "${proceed}" \
      cntools_collect_begin cntools_collect_render 'Change workflow' || return $?
    case "${selected}" in
      "${proceed}") break ;;
      'Change workflow') cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $? ;;
      *) return 2 ;;
    esac
  done
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned collect-utxos || return 2
    CNTOOLS_COLLECT_SAVED_PACKAGE="${saved}"
    cntools_collect_begin
    cntools_collect_result success 'Ready for Transaction → Sign, then Submit. Rebuild if selected inputs are spent or the transaction expires.' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function 'Rechecking selected inputs…' cntools_collect_recheck || return 2
  cntools_ui_spin_function 'Signing collection…' cntools_transaction_sign_registered "${staged}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" || return 2
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || { cntools_collect_fail 'The package still needs witnesses.'; return 2; }
  cntools_transaction_save_into saved "${signed}" signed collect-utxos || return 2
  CNTOOLS_COLLECT_SAVED_PACKAGE="${saved}"
  if [[ "${workflow}" == 'Create and sign' ]]; then
    cntools_collect_begin
    cntools_collect_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  signed_body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  cntools_transaction_ui_confirm_submit "${backend}" || status=$?
  if (( status != 0 )); then
    cntools_collect_begin
    cntools_collect_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    return $?
  fi
  cntools_ui_spin_function 'Rechecking selected inputs…' cntools_collect_recheck || status=$?
  if (( status == 0 )); then
    cntools_ui_spin_function 'Submitting collection…' cntools_transaction_ui_submit_selected "${backend}" "${signed_body}" "${txid}" || status=$?
  fi
  cntools_collect_begin
  if (( status != 0 )); then
    cntools_collect_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check the chain before retrying.}" "${txid}" "${saved}" || return 2
    return 2
  fi
  cntools_collect_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not confirmation of inclusion." "${txid}" || return 2
  cntools_transaction_ui_offer_monitor "${txid}"
}

cntools_funds_action_collect() {
  local status=0
  cntools_transaction_clear_error
  cntools_collect_workflow || status=$?
  if (( status == 1 )); then
    cntools_transaction_log CHOICE 'Collection cancelled; any saved package was retained'
    cntools_ui_render_status info 'Cancelled. Any packages already saved remain available.'
  elif (( status != 0 )); then
    cntools_collect_fail "${CNTOOLS_TRANSACTION_ERROR:-UTxO collection failed. See ${CNTOOLS_LOG} for details.}" || true
    if [[ "${CNTOOLS_COLLECT_RESULT_SHOWN:-N}" != Y ]]; then
      cntools_collect_result danger "${CNTOOLS_TRANSACTION_ERROR}" '' "${CNTOOLS_COLLECT_SAVED_PACKAGE:-}"
    fi
  fi
  cntools_ui_wait
  (( status <= 1 ))
}
