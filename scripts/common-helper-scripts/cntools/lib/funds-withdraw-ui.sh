#!/usr/bin/env bash
# Guided reward withdrawal. Authoritative decode is available, not dumped by default.
# shellcheck disable=SC2034

cntools_withdraw_begin() { cntools_ui_action_begin 'Withdraw Rewards' '/ Funds / Withdraw Rewards'; }

cntools_withdraw_choose() {
  local output_name="$1" prompt="$2" status=0
  shift 2
  cntools_ui_choose "${output_name}" "${prompt}" "$@" || status=$?
  if (( status == 0 )); then
    local -n choice_ref="${output_name}"
    cntools_transaction_log CHOICE "Withdrawal ${prompt} selected=${choice_ref}"
  fi
  return "${status}"
}

cntools_withdraw_render() {
  local widths="" expiry_label="" net="" effect='Net rewards after fee'
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_slot_datetime_into expiry_label "${CNTOOLS_WITHDRAW_EXPIRY}" || expiry_label='Date unavailable'
  if cntools_uint_greater_equal "${CNTOOLS_WITHDRAW_REWARDS}" "${CNTOOLS_WITHDRAW_FEE}"; then
    cntools_uint_subtract_into net "${CNTOOLS_WITHDRAW_REWARDS}" "${CNTOOLS_WITHDRAW_FEE}" || return 1
  else
    effect='Fee paid from wallet'
    cntools_uint_subtract_into net "${CNTOOLS_WITHDRAW_FEE}" "${CNTOOLS_WITHDRAW_REWARDS}" || return 1
  fi
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Property\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${CNTOOLS_STAKE_WALLET}" identifier
    cntools_transaction_ui_styled_row 'Reward account' "${CNTOOLS_STAKE_REWARD_ADDRESS}" address
    cntools_transaction_ui_styled_row 'Return address' "${CNTOOLS_STAKE_BASE_ADDRESS}" address
    cntools_transaction_ui_styled_row Rewards "$(cntools_wallet_format_lovelace "${CNTOOLS_WITHDRAW_REWARDS}")" number
    cntools_transaction_ui_styled_row Fee "$(cntools_wallet_format_lovelace "${CNTOOLS_WITHDRAW_FEE}")" number
    cntools_transaction_ui_styled_row "${effect}" "$(cntools_wallet_format_lovelace "${net}")" number
    cntools_transaction_ui_render_policy_rows "${CNTOOLS_TX_SELECTION_STRATEGY}" "${#CNTOOLS_WITHDRAW_INPUTS[@]}"
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  cntools_ui_render_status info 'Registration and delegation stay unchanged. Rewards and selected funds return to this wallet, less the fee.'
  if [[ "${effect}" == 'Fee paid from wallet' ]]; then
    cntools_ui_render_status warn 'The fee exceeds the rewards. Continuing reduces the wallet balance.'
  fi
}

cntools_withdraw_result() {
  cntools_transaction_ui_render_result "$@" || return 1
  CNTOOLS_WITHDRAW_RESULT_SHOWN=Y
}

cntools_withdraw_workflow() {
  local selected="" workflow="" expiry="" staged="" signed="" saved="" proceed=""
  local backend="" signed_body="" txid="" lifetime=1800 status=0
  CNTOOLS_WITHDRAW_RESULT_SHOWN=N; CNTOOLS_WITHDRAW_SAVED_PACKAGE=""
  cntools_withdraw_begin
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  (( ${#CNTOOLS_WALLET_NAMES[@]} > 0 )) || { cntools_withdraw_fail 'No wallets are available.'; return 2; }
  cntools_wallet_choose selected || return $?
  cntools_stake_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" "${CNTOOLS_WALLET_NAMES[selected]}" || return 2
  cntools_transaction_ui_workflow_into workflow "${CNTOOLS_STAKE_CAN_SIGN}" || return $?
  cntools_withdraw_choose expiry 'Transaction expiry' '30 minutes' '2 hours' '24 hours (offline signing)' || return $?
  case "${expiry}" in '30 minutes') lifetime=1800 ;; '2 hours') lifetime=7200 ;; *) lifetime=86400 ;; esac
  cntools_ui_spin_function 'Checking rewards and building the withdrawal…' \
    cntools_withdraw_refresh_build_into staged "${lifetime}" || return 2
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into selected "${staged}" "${proceed}" \
      cntools_withdraw_begin cntools_withdraw_render 'Change workflow' || return $?
    case "${selected}" in
      "${proceed}") break ;;
      'Change workflow') cntools_transaction_ui_workflow_into workflow "${CNTOOLS_STAKE_CAN_SIGN}" || return $? ;;
      *) return 2 ;;
    esac
  done
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned withdraw-rewards || return 2
    CNTOOLS_WITHDRAW_SAVED_PACKAGE="${saved}"
    cntools_withdraw_begin
    cntools_withdraw_result success 'Ready for Transaction → Sign, then Submit. Rebuild if the reward balance changes or the transaction expires.' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function 'Rechecking rewards and selected inputs…' cntools_withdraw_recheck || return 2
  cntools_ui_spin_function 'Signing withdrawal…' cntools_transaction_sign_registered "${staged}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" || return 2
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || { cntools_withdraw_fail 'The package still needs witnesses.'; return 2; }
  cntools_transaction_save_into saved "${signed}" signed withdraw-rewards || return 2
  CNTOOLS_WITHDRAW_SAVED_PACKAGE="${saved}"
  if [[ "${workflow}" == 'Create and sign' ]]; then
    cntools_withdraw_begin
    cntools_withdraw_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  signed_body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  cntools_transaction_ui_confirm_submit "${backend}" || status=$?
  if (( status != 0 )); then
    cntools_withdraw_begin
    cntools_withdraw_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    return $?
  fi
  cntools_ui_spin_function 'Rechecking rewards and selected inputs…' cntools_withdraw_recheck || status=$?
  if (( status == 0 )); then
    cntools_ui_spin_function 'Submitting withdrawal…' cntools_transaction_ui_submit_selected "${backend}" "${signed_body}" "${txid}" || status=$?
  fi
  cntools_withdraw_begin
  if (( status != 0 )); then
    cntools_withdraw_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check the chain before retrying.}" "${txid}" "${saved}" || return 2
    return 2
  fi
  cntools_withdraw_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not confirmation of inclusion." "${txid}" || return 2
  cntools_transaction_ui_offer_monitor "${txid}"
}

cntools_funds_action_withdraw() {
  local status=0
  cntools_transaction_clear_error
  cntools_withdraw_workflow || status=$?
  if (( status == 1 )); then
    cntools_transaction_log CHOICE 'Withdrawal cancelled; any saved package was retained'
    cntools_ui_render_status info 'Cancelled. Any packages already saved remain available.'
  elif (( status != 0 )); then
    cntools_withdraw_fail "${CNTOOLS_TRANSACTION_ERROR:-Reward withdrawal failed. See ${CNTOOLS_LOG} for details.}" || true
    if [[ "${CNTOOLS_WITHDRAW_RESULT_SHOWN:-N}" != Y ]]; then
      cntools_withdraw_result danger "${CNTOOLS_TRANSACTION_ERROR}" '' "${CNTOOLS_WITHDRAW_SAVED_PACKAGE:-}"
    fi
  fi
  cntools_ui_wait
  (( status <= 1 ))
}
