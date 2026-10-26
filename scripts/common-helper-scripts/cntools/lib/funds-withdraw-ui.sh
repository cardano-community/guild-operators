#!/usr/bin/env bash
# Guided reward withdrawal. Authoritative decode is available, not dumped by default.
# shellcheck disable=SC2034

cntools_withdraw_begin() { cntools_ui_action_begin 'Withdraw Rewards' '/ Funds / Withdraw Rewards'; }

cntools_withdraw_render() {
  local widths="" expiry_label="" net="" effect='Net rewards after fee'
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_transaction_ui_expiry_label_into expiry_label "${CNTOOLS_WITHDRAW_EXPIRY}"
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
    cntools_transaction_ui_styled_row Rewards "$(cntools_number_format_lovelace "${CNTOOLS_WITHDRAW_REWARDS}")" number
    cntools_transaction_ui_styled_row Fee "$(cntools_number_format_lovelace "${CNTOOLS_WITHDRAW_FEE}")" number
    cntools_transaction_ui_styled_row "${effect}" "$(cntools_number_format_lovelace "${net}")" number
    cntools_transaction_ui_render_policy_rows "${CNTOOLS_TX_SELECTION_STRATEGY}" "${#CNTOOLS_WITHDRAW_INPUTS[@]}"
    cntools_funding_render_untouched_row
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  cntools_ui_render_status info 'Registration and delegation stay unchanged.'
  if [[ "${effect}" == 'Fee paid from wallet' ]]; then
    cntools_ui_render_status warn 'The fee exceeds the rewards. Continuing reduces the wallet balance.'
  fi
}

cntools_withdraw_result() {
  cntools_transaction_ui_render_result "$@" || return 1
  CNTOOLS_WITHDRAW_RESULT_SHOWN=Y
}

# Rebuild after a review change. A failed rebuild restores the previous
# lifetime, rebuilds that and warns; the action continues.
cntools_withdraw_rebuild_into() {
  local wr_target="$1" wr_lifetime="$2" wr_previous="$3" wr_reason=''
  cntools_transaction_clear_error
  cntools_ui_spin_function 'Checking rewards and rebuilding the withdrawal…' \
    cntools_withdraw_refresh_build_into "${wr_target}" "${!wr_lifetime}" && return 0
  wr_reason="${CNTOOLS_TRANSACTION_ERROR:-The withdrawal could not be rebuilt.}"
  printf -v "${wr_lifetime}" '%s' "${wr_previous}"
  cntools_transaction_clear_error
  CNTOOLS_TRANSACTION_UI_NOTICE=''
  cntools_ui_spin_function 'Restoring the previous withdrawal…' \
    cntools_withdraw_refresh_build_into "${wr_target}" "${wr_previous}" || return 2
  cntools_transaction_log CHOICE "Withdrawal rebuild failed; previous expiry kept lifetime=${wr_previous}"
  cntools_ui_render_status warn "The new expiry could not be built, so the previous one is kept. ${wr_reason}"
}

# Rebuild after 'Change signers'; a failed rebuild restores the signers and
# the workflow, can-sign and lifetime values they changed.
# Usage: cntools_withdraw_signers_rebuild_into TARGET WORKFLOW CAN_SIGN LIFETIME
cntools_withdraw_signers_rebuild_into() {
  local wsr_target="$1" wsr_reason=''
  cntools_transaction_clear_error
  cntools_ui_spin_function 'Checking rewards and rebuilding the withdrawal…' \
    cntools_withdraw_refresh_build_into "${wsr_target}" "${!4}" && return 0
  wsr_reason="${CNTOOLS_TRANSACTION_ERROR:-The withdrawal could not be rebuilt.}"
  cntools_multisig_signers_restore_into "$2" "$3" "$4"
  cntools_transaction_clear_error
  cntools_ui_spin_function 'Restoring the previous withdrawal…' \
    cntools_withdraw_refresh_build_into "${wsr_target}" "${!4}" || return 2
  cntools_transaction_log CHOICE 'Withdrawal rebuild failed; previous signers kept'
  cntools_ui_render_status warn "The new signers could not be built, so the previous ones are kept. ${wsr_reason}"
}

# Says why only an unsigned package is offered when the wallet's keys are encrypted.
cntools_withdraw_unsigned_reason() {
  [[ "${CNTOOLS_STAKE_CAN_SIGN}" != Y && "${CNTOOLS_STAKE_WALLET_TYPE:-}" != MultiSig ]] || return 0
  cntools_transaction_ui_encrypted_reason_set 'Wallet → Decrypt' \
    "${CNTOOLS_STAKE_DIRECTORY}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" \
    "${CNTOOLS_STAKE_DIRECTORY}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" || true
}

cntools_withdraw_workflow() {
  local selected="" workflow="" staged="" signed="" saved="" proceed=""
  local backend="" signed_body="" txid="" lifetime=1800 status=0 previous="" asked=N
  local -a review_options=('Change expiry' 'Change workflow')
  CNTOOLS_WITHDRAW_RESULT_SHOWN=N; CNTOOLS_WITHDRAW_SAVED_PACKAGE=""
  cntools_withdraw_begin
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  cntools_wallet_choose selected Cancel withdraw || return $?
  cntools_stake_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" "${CNTOOLS_WALLET_NAMES[selected]}" || return 2
  [[ "${CNTOOLS_STAKE_WALLET_TYPE:-}" != Hardware ]] || cntools_transaction_require_hwcli || return 2
  # Check rewards first: a wallet with nothing to withdraw asks nothing more,
  # not even for its multisig signers.
  cntools_ui_spin_function 'Checking rewards and spendable funds…' cntools_withdraw_collect || status=$?
  if (( status == 4 || status == 5 )); then
    cntools_withdraw_begin
    if (( status == 4 )); then
      cntools_ui_render_status info "${CNTOOLS_TRANSACTION_ERROR}"
    else
      cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR}"
    fi
    CNTOOLS_WITHDRAW_RESULT_SHOWN=Y
    return 0
  fi
  (( status == 0 )) || return 2
  if [[ "${CNTOOLS_STAKE_WALLET_TYPE:-}" == MultiSig ]]; then
    cntools_multisig_stake_window_check "${CNTOOLS_FUNDING_SLOT}" || return 2
    cntools_multisig_stake_choose_signers cntools_withdraw_begin || return $?
    asked=Y
    ! cntools_multisig_signers_changeable || review_options+=('Change signers')
  fi
  cntools_withdraw_unsigned_reason
  cntools_transaction_ui_initial_workflow_into workflow "${CNTOOLS_STAKE_CAN_SIGN}" || return $?
  cntools_transaction_ui_initial_expiry_into lifetime || return $?
  # Quick builds from the checked rewards and funds unless a question was
  # asked since: time spent in the signer menus would leave them stale.
  if cntools_flow_quick && [[ "${asked}" == N ]]; then
    cntools_ui_spin_function 'Building the withdrawal…' cntools_withdraw_current_build_into staged "${lifetime}" || return 2
  else
    cntools_ui_spin_function 'Checking rewards and building the withdrawal…' \
      cntools_withdraw_refresh_build_into staged "${lifetime}" || return 2
  fi
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into selected "${staged}" "${proceed}" \
      cntools_withdraw_begin cntools_withdraw_render "${review_options[@]}" || return $?
    status=0
    case "${selected}" in
      "${proceed}") break ;;
      'Change workflow')
        # Esc keeps the current value and returns to the review. Quick gives
        # an unsigned package a day to be signed, so that rebuilds.
        previous="${lifetime}"
        cntools_transaction_ui_workflow_into workflow "${CNTOOLS_STAKE_CAN_SIGN}" || status=$?
        (( status <= 1 )) || return "${status}"
        (( status == 0 )) || continue
        cntools_transaction_ui_unsigned_lifetime_into lifetime "${workflow}" || continue
        cntools_withdraw_rebuild_into staged lifetime "${previous}" || return $? ;;
      'Change signers')
        cntools_multisig_signers_change_into workflow CNTOOLS_STAKE_CAN_SIGN lifetime stake cntools_withdraw_begin || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        cntools_withdraw_signers_rebuild_into staged workflow CNTOOLS_STAKE_CAN_SIGN lifetime || return $? ;;
      'Change expiry')
        previous="${lifetime}"
        cntools_transaction_ui_expiry_into lifetime || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        [[ "${lifetime}" != "${previous}" ]] || continue
        cntools_withdraw_rebuild_into staged lifetime "${previous}" || return $? ;;
      *) return 2 ;;
    esac
  done
  if [[ "${workflow}" != 'Create unsigned package' ]]; then
    cntools_transaction_signed_path_into signed || return 2
    cntools_ui_spin_function 'Rechecking rewards and selected inputs…' cntools_withdraw_recheck || return 2
    cntools_transaction_ui_recheck_mark
    # A device or key failure offers Retry, Save unsigned package or Cancel.
    status=0
    cntools_transaction_ui_sign_staged withdrawal "${staged}" "${signed}" || status=$?
    case "${status}" in
      0) ;;
      4) workflow='Create unsigned package' ;;
      1|130) return "${status}" ;;
      *) return 2 ;;
    esac
  fi
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned withdraw-rewards || return 2
    CNTOOLS_WITHDRAW_SAVED_PACKAGE="${saved}"
    cntools_withdraw_begin
    cntools_withdraw_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
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
  # Signing a moment ago needs no second recheck; a slow signer does.
  if cntools_transaction_ui_recheck_due; then
    cntools_ui_spin_function 'Rechecking rewards and selected inputs…' cntools_withdraw_recheck || status=$?
    (( status != 0 )) || cntools_transaction_ui_recheck_mark
  fi
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

# 1/130 cancel straight back to the menu (naming a saved package, if any);
# 3 means the reason was already shown and acknowledged.
cntools_funds_action_withdraw() {
  local status=0
  cntools_transaction_clear_error
  cntools_withdraw_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait ;;
    1|130)
      cntools_transaction_log CHOICE "Withdrawal cancelled status=${status} saved=${CNTOOLS_WITHDRAW_SAVED_PACKAGE:-none}"
      [[ -n "${CNTOOLS_WITHDRAW_SAVED_PACKAGE:-}" ]] || return 0
      cntools_ui_render_status info "Cancelled. The saved package remains available: ${CNTOOLS_WITHDRAW_SAVED_PACKAGE}"
      cntools_ui_wait ;;
    3) ;;
    *)
      cntools_withdraw_fail "${CNTOOLS_TRANSACTION_ERROR:-Reward withdrawal failed. See ${CNTOOLS_LOG} for details.}" || true
      if [[ "${CNTOOLS_WITHDRAW_RESULT_SHOWN:-N}" != Y ]]; then
        cntools_withdraw_result danger "${CNTOOLS_TRANSACTION_ERROR}" '' "${CNTOOLS_WITHDRAW_SAVED_PACKAGE:-}"
      fi
      cntools_ui_wait
      return 1 ;;
  esac
}
