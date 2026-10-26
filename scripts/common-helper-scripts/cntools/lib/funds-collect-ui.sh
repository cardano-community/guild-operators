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
    cntools_transaction_ui_styled_row 'Collected ADA' "$(cntools_number_format_lovelace "${CNTOOLS_COIN_SELECTED_LOVELACE}")" number
    (( CNTOOLS_COIN_SELECTED_ASSET_COUNT == 0 )) ||
      cntools_transaction_ui_styled_row 'Native assets' "$(cntools_number_format "${CNTOOLS_COIN_SELECTED_ASSET_COUNT}")" number
    cntools_transaction_ui_styled_row Fee "$(cntools_number_format_lovelace "${CNTOOLS_COLLECT_FEE}")" number
    cntools_transaction_ui_styled_row 'Resulting outputs' "$(cntools_number_format "${CNTOOLS_COLLECT_OUTPUT_COUNT}")" number
    (( CNTOOLS_COLLECT_SKIPPED_TOKENS == 0 )) ||
      cntools_transaction_ui_styled_row 'Token UTxOs left' "$(cntools_number_format "${CNTOOLS_COLLECT_SKIPPED_TOKENS}")" number
    (( CNTOOLS_COLLECT_SKIPPED_SCRIPTS == 0 )) ||
      cntools_transaction_ui_styled_row 'Datum / script UTxOs left' "$(cntools_number_format "${CNTOOLS_COLLECT_SKIPPED_SCRIPTS}")" number
    cntools_transaction_ui_render_policy_rows 'All eligible inputs' "${#CNTOOLS_COLLECT_INPUTS[@]}"
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  cntools_ui_render_status info 'Rewards, deposits and delegation are unchanged.'
  if (( CNTOOLS_COLLECT_OUTPUT_COUNT >= ${#CNTOOLS_COLLECT_INPUTS[@]} )); then
    cntools_ui_render_status warn 'Your change settings produce as many or more outputs than the selected inputs. This reshapes funds rather than reducing the UTxO count.'
  fi
}

cntools_collect_result() {
  cntools_transaction_ui_render_result "$@" || return 1
  CNTOOLS_COLLECT_RESULT_SHOWN=Y
}

cntools_collect_scope_label_into() {
  local -n collect_label_ref="$1"
  collect_label_ref='ADA-only UTxOs'
  [[ "$2" != all ]] || collect_label_ref='ADA and native assets'
}

# Only scopes with something to collect are offered; one needs no question.
# shellcheck disable=SC2153 # CNTOOLS_COLLECT_SCOPES is set by funds-collect.sh
cntools_collect_choose_scope() {
  local scope="" label="" option=""
  local -a options=()
  if (( ${#CNTOOLS_COLLECT_SCOPES[@]} == 1 )); then
    CNTOOLS_COLLECT_SCOPE="${CNTOOLS_COLLECT_SCOPES[0]}"
    cntools_transaction_log CHOICE "Collection scope=${CNTOOLS_COLLECT_SCOPE} (only scope with eligible UTxOs)"
    return 0
  fi
  for option in "${CNTOOLS_COLLECT_SCOPES[@]}"; do
    cntools_collect_scope_label_into label "${option}"; options+=("${label}")
  done
  cntools_ui_choose scope 'Collect which UTxOs?' "${options[@]}" 'Cancel' || return $?
  case "${scope}" in
    'ADA-only UTxOs') CNTOOLS_COLLECT_SCOPE=ada ;;
    'ADA and native assets') CNTOOLS_COLLECT_SCOPE=all ;;
    *) return 1 ;;
  esac
  cntools_transaction_log CHOICE "Collection scope=${CNTOOLS_COLLECT_SCOPE}"
}

cntools_collect_workflow() {
  local selected="" workflow="" staged="" signed="" saved="" proceed="" can_sign=N
  local backend="" signed_body="" txid="" lifetime=1800 status=0 previous="" reason=""
  local -a review_options=('Change expiry' 'Change workflow')
  CNTOOLS_COLLECT_RESULT_SHOWN=N; CNTOOLS_COLLECT_SAVED_PACKAGE=""
  cntools_collect_begin
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  cntools_wallet_choose selected Cancel collect || return $?
  cntools_send_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" multisig || return 2
  [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || cntools_multisig_spend_choose_signers cntools_collect_begin || return $?
  [[ -z "${CNTOOLS_SEND_SOURCE}" ]] || can_sign=Y
  [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || can_sign="${CNTOOLS_MULTISIG_CAN_SIGN}"
  # Check first: a wallet with nothing to collect asks nothing more.
  cntools_ui_spin_function 'Checking funds…' cntools_collect_check || return 2
  if (( ${#CNTOOLS_COLLECT_SCOPES[@]} == 0 )); then
    cntools_collect_begin
    cntools_ui_render_status info "${CNTOOLS_COLLECT_NOTHING_REASON:-Nothing to collect in ${CNTOOLS_SEND_WALLET}.}"
    CNTOOLS_COLLECT_RESULT_SHOWN=Y
    return 0
  fi
  if cntools_flow_quick; then
    # ADA-only when it has something to collect; the review offers 'Change scope'.
    CNTOOLS_COLLECT_SCOPE="${CNTOOLS_COLLECT_SCOPES[0]}"
    cntools_transaction_log CHOICE "Collection scope default=${CNTOOLS_COLLECT_SCOPE} flow=quick"
  else
    cntools_collect_choose_scope || return $?
  fi
  (( ${#CNTOOLS_COLLECT_SCOPES[@]} < 2 )) || review_options=('Change scope' "${review_options[@]}")
  cntools_transaction_ui_initial_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_initial_expiry_into lifetime || return $?
  if cntools_flow_quick; then
    cntools_ui_spin_function 'Building the collection…' cntools_collect_current_build_into staged "${lifetime}" || return 2
  else
    cntools_ui_spin_function 'Checking funds and building the collection…' \
      cntools_collect_refresh_build_into staged "${lifetime}" || return 2
  fi
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into selected "${staged}" "${proceed}" \
      cntools_collect_begin cntools_collect_render "${review_options[@]}" || return $?
    status=0
    case "${selected}" in
      "${proceed}") break ;;
      'Change workflow')
        # Esc keeps the current value and returns to the review.
        cntools_transaction_ui_workflow_into workflow "${can_sign}" || status=$?
        (( status <= 1 )) || return "${status}" ;;
      'Change scope')
        previous="${CNTOOLS_COLLECT_SCOPE}"
        cntools_collect_choose_scope || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        [[ "${CNTOOLS_COLLECT_SCOPE}" != "${previous}" ]] || continue
        cntools_transaction_clear_error
        cntools_ui_spin_function 'Checking funds and rebuilding the collection…' \
          cntools_collect_refresh_build_into staged "${lifetime}" || status=$?
        if (( status != 0 )); then
          # Keep the reviewed scope rather than losing a valid collection.
          reason="${CNTOOLS_TRANSACTION_ERROR:-The collection could not be rebuilt.}"
          CNTOOLS_COLLECT_SCOPE="${previous}"
          cntools_ui_spin_function 'Restoring the previous collection…' \
            cntools_collect_refresh_build_into staged "${lifetime}" || return 2
          cntools_ui_render_status warn "The other scope could not be built, so the previous one is kept. ${reason}"
        fi ;;
      'Change expiry')
        cntools_transaction_ui_expiry_into lifetime || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        cntools_ui_spin_function 'Checking funds and rebuilding the collection…' \
          cntools_collect_refresh_build_into staged "${lifetime}" || return 2 ;;
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
  status=0
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

# 1/130 cancel straight back to the menu (naming a saved package, if any);
# 3 means the reason was already shown and acknowledged.
cntools_funds_action_collect() {
  local status=0
  cntools_transaction_clear_error
  cntools_collect_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait ;;
    1|130)
      cntools_transaction_log CHOICE "Collection cancelled status=${status} saved=${CNTOOLS_COLLECT_SAVED_PACKAGE:-none}"
      [[ -n "${CNTOOLS_COLLECT_SAVED_PACKAGE:-}" ]] || return 0
      cntools_ui_render_status info "Cancelled. The saved package remains available: ${CNTOOLS_COLLECT_SAVED_PACKAGE}"
      cntools_ui_wait ;;
    3) ;;
    *)
      cntools_collect_fail "${CNTOOLS_TRANSACTION_ERROR:-UTxO collection failed. See ${CNTOOLS_LOG} for details.}" || true
      if [[ "${CNTOOLS_COLLECT_RESULT_SHOWN:-N}" != Y ]]; then
        cntools_collect_result danger "${CNTOOLS_TRANSACTION_ERROR}" '' "${CNTOOLS_COLLECT_SAVED_PACKAGE:-}"
      fi
      cntools_ui_wait
      return 1 ;;
  esac
}
