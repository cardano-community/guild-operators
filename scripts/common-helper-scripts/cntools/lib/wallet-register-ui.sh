#!/usr/bin/env bash
# Stake lifecycle actions follow the shared transaction UI contract.
# shellcheck disable=SC2034

cntools_wallet_register_begin() {
  cntools_ui_action_begin "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
}

cntools_wallet_register_render_plan() {
  local widths="" fee="" expiry_label="No expiry"
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_transaction_ui_fee_into fee || return 1
  if [[ -n "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER:-}" ]]; then
    cntools_slot_datetime_into expiry_label "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" || expiry_label='Date unavailable'
  fi
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Transaction detail\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
    cntools_transaction_ui_styled_row Action "Stake ${CNTOOLS_WALLET_REGISTER_NOUN}" accent
    cntools_transaction_ui_styled_row 'Stake address' "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" address
    cntools_transaction_ui_styled_row "${CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL}" "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")" number
    cntools_transaction_ui_styled_row Fee "$(cntools_wallet_format_lovelace "${fee}")" number
    cntools_transaction_ui_render_policy_rows "${CNTOOLS_TX_SELECTION_STRATEGY}" "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}"
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == deregister ]]; then
    cntools_ui_render_status warn 'De-registering ends stake-pool and DRep delegation. Lingering rewards earned but not yet credited or paid out will be forfeited.'
  fi
}

cntools_wallet_register_render_collect_error() {
  local status="${1:-1}"
  local message="${CNTOOLS_WALLET_REGISTER_ERROR:-The stake ${CNTOOLS_WALLET_REGISTER_NOUN} data could not be collected. See ${CNTOOLS_LOG}.}"

  case "${status}" in
    4) message="This wallet's stake address is already registered." ;;
    5) message="This wallet has no spendable UTxOs at its base or payment address." ;;
    6)
      message="The wallet balance must be greater than the current stake deposit so it can also pay the transaction fee."
      ;;
    7) message="This wallet's stake address is not registered." ;;
    8)
      message="This wallet has unclaimed rewards. Withdraw all rewards before de-registering its stake address."
      ;;
    9)
      message="${CNTOOLS_WALLET_REGISTER_ERROR:-The wallet does not contain a safe set of UTxOs for this transaction.}"
      ;;
  esac
  if (( status == 4 || status == 7 )); then
    cntools_ui_render_status info "${message}"
  elif (( status == 8 )); then
    cntools_ui_render_status warn "${message}"
  else
    cntools_ui_render_status error "${message}"
  fi
}

cntools_wallet_register_sign() {
  local unsigned_file="${1:-}"
  local signed_file="${2:-}"

  cntools_transaction_sign_registered "${unsigned_file}" "${signed_file}" || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  }
  cntools_transaction_package_load "${signed_file}" || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  }
  if [[ "${CNTOOLS_TRANSACTION_COMPLETE}" != "Y" ]]; then
    cntools_wallet_register_set_error \
      "The selected local sources did not produce a complete stake ${CNTOOLS_WALLET_REGISTER_NOUN} package."
    return 1
  fi
}

cntools_wallet_register_result() {
  cntools_transaction_ui_render_result "$@" || return 1
  CNTOOLS_WALLET_REGISTER_RESULT_SHOWN=Y
}

cntools_wallet_register_workflow() {
  local selected_index="" wallet_directory="" wallet_name="" workflow="" proceed="" choice=""
  local staged="" signed="" saved="" backend="" signed_body="" txid="" status=0
  CNTOOLS_WALLET_REGISTER_RESULT_SHOWN=N
  CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE=""
  cntools_wallet_register_begin
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  if (( ${#CNTOOLS_WALLET_NAMES[@]} == 0 )); then
    cntools_wallet_register_set_error "No wallets are available to ${CNTOOLS_WALLET_REGISTER_VERB}."
    return 2
  fi
  cntools_wallet_choose selected_index || return $?
  wallet_directory="${CNTOOLS_WALLET_PATHS[selected_index]}"
  wallet_name="${CNTOOLS_WALLET_NAMES[selected_index]}"
  cntools_wallet_register_prepare_wallet "${wallet_directory}" "${wallet_name}" || return 2
  cntools_transaction_ui_workflow_into workflow "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" || return $?
  cntools_transaction_ui_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $?
  cntools_ui_spin_function 'Checking stake state, rewards and spendable funds…' cntools_wallet_register_collect || status=$?
  if (( status != 0 )); then
    cntools_wallet_register_begin
    cntools_wallet_register_render_collect_error "${status}"
    CNTOOLS_WALLET_REGISTER_RESULT_SHOWN=Y
    [[ "${status}" != 4 && "${status}" != 7 ]] || return 0
    return 2
  fi
  cntools_ui_spin_function "Building stake ${CNTOOLS_WALLET_REGISTER_NOUN}…" \
    cntools_wallet_register_build_package_into staged || return 2
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into choice "${staged}" "${proceed}" \
      cntools_wallet_register_begin cntools_wallet_register_render_plan 'Change workflow' || return $?
    case "${choice}" in
      "${proceed}") break ;;
      'Change workflow') cntools_transaction_ui_workflow_into workflow "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" || return $? ;;
      *) return 2 ;;
    esac
  done
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 2
    CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE="${saved}"
    cntools_wallet_register_begin
    cntools_wallet_register_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function "Signing stake ${CNTOOLS_WALLET_REGISTER_NOUN}…" \
    cntools_wallet_register_sign "${staged}" "${signed}" || return 2
  cntools_transaction_save_into saved "${signed}" signed "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 2
  CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE="${saved}"
  if [[ "${workflow}" == 'Create and sign' ]]; then
    cntools_wallet_register_begin
    cntools_wallet_register_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  signed_body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  cntools_transaction_ui_confirm_submit "${backend}" || status=$?
  if (( status != 0 )); then
    cntools_wallet_register_begin
    cntools_wallet_register_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    return $?
  fi
  cntools_ui_spin_function "Submitting stake ${CNTOOLS_WALLET_REGISTER_NOUN}…" \
    cntools_transaction_ui_submit_selected "${backend}" "${signed_body}" "${txid}" || status=$?
  cntools_wallet_register_begin
  if (( status != 0 )); then
    cntools_wallet_register_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check the chain before retrying.}" "${txid}" "${saved}" || return 2
    return 2
  fi
  cntools_wallet_register_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not confirmation of inclusion." "${txid}" || return 2
  cntools_transaction_ui_offer_monitor "${txid}"
}

cntools_wallet_action_stake_lifecycle() {
  local status=0
  cntools_transaction_clear_error
  cntools_wallet_register_workflow || status=$?
  if (( status == 1 )); then
    cntools_transaction_ui_cancel 'Stake transaction cancelled; saved packages retained'
  elif (( status != 0 )) && [[ "${CNTOOLS_WALLET_REGISTER_RESULT_SHOWN:-N}" != Y ]]; then
    cntools_wallet_register_result danger "${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Transaction failed. See ${CNTOOLS_LOG}.}}" '' "${CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE:-}"
  fi
  cntools_ui_wait
  (( status <= 1 ))
}

cntools_wallet_action_register() {
  cntools_wallet_register_operation_set register || return 1
  cntools_wallet_action_stake_lifecycle
}

cntools_wallet_action_deregister() {
  cntools_wallet_register_operation_set deregister || return 1
  cntools_wallet_action_stake_lifecycle
}
