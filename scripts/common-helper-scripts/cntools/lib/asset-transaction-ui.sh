#!/usr/bin/env bash
# Guided mint/burn with the shared transaction review/sign/export/submit UX.
# shellcheck disable=SC2034,SC2015
CNTOOLS_ASSET_TX_RESULT_SHOWN=N CNTOOLS_ASSET_TX_SAVED=''
cntools_asset_tx_begin() { cntools_policy_manage_begin "${CNTOOLS_ASSET_TX_OPERATION^} Asset"; }

# Smallest units, plus the decimal amount when Koios metadata gives decimals.
cntools_asset_tx_amount_into() {
  local _amount_output="$1" _amount_units="$2" _amount_decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${CNTOOLS_ASSET_TX_ID}]:-0}" _amount_scaled=''
  printf -v "${_amount_output}" '%s units' "$(cntools_number_format "${_amount_units}")"
  [[ "${_amount_decimals}" =~ ^[1-9][0-9]?$ ]] && cntools_wallet_format_token_amount_into _amount_scaled "${_amount_units}" "${_amount_decimals}" || return 0
  printf -v "${_amount_output}" '%s (%s units)' "${_amount_scaled}" "$(cntools_number_format "${_amount_units}")"
}

cntools_asset_tx_render() {
  local label='' expiry='' fingerprint='' date='' amount='' held="${CNTOOLS_FUNDING_ASSETS[${CNTOOLS_ASSET_TX_ID}]:-0}" after='' selection=''
  cntools_asset_label_into label "${CNTOOLS_ASSET_TX_ID}" 1 || return 1
  cntools_transaction_ui_expiry_label_into expiry "${CNTOOLS_SEND_EXPIRY}" || return 1
  cntools_wallet_asset_fingerprint_into fingerprint "${CNTOOLS_ASSET_TX_ID%%.*}" "${CNTOOLS_ASSET_TX_ID#*.}" || fingerprint=Unavailable
  cntools_asset_tx_amount_into amount "${CNTOOLS_ASSET_TX_QUANTITY}"
  {
    cntools_table_pair Wallet "${CNTOOLS_SEND_WALLET}" identifier
    cntools_table_pair Policy "${CNTOOLS_ASSET_TX_DIRECTORY##*/}" identifier
    cntools_table_pair Asset "${label}" accent
    cntools_table_pair 'Policy.name (hex)' "${CNTOOLS_ASSET_TX_ID}" identifier
    cntools_table_pair Fingerprint "${fingerprint}" identifier
    cntools_table_pair "${CNTOOLS_ASSET_TX_OPERATION^} quantity" "${amount}" number
    if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]] && cntools_uint_subtract_into after "${held}" "${CNTOOLS_ASSET_TX_QUANTITY}"; then
      cntools_table_pair 'Held → after burn' "$(cntools_number_format "${held}") → $(cntools_number_format "${after}")" number
    fi
    if [[ -n "${CNTOOLS_POLICY_SELECTED_BEFORE}" ]]; then
      cntools_slot_datetime_into date "${CNTOOLS_POLICY_SELECTED_BEFORE}" || date="Slot ${CNTOOLS_POLICY_SELECTED_BEFORE}"
      cntools_table_pair 'Policy expires' "${date} · also caps the expiry" warning
    fi
    cntools_table_pair 'Return address' "${CNTOOLS_SEND_ADDRESS}" identifier
    cntools_table_pair Fee "$(cntools_number_format_lovelace "${CNTOOLS_ASSET_TX_FEE}")" number
    cntools_table_pair Expires "${expiry}" value
    # As cntools_transaction_ui_render_policy_rows: readable strategy, rows
    # only for change features that are switched on.
    selection="$(cntools_settings_strategy_name "${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}" 2>/dev/null)" || selection="${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}"
    selection+=" · ${#CNTOOLS_ASSET_TX_INPUTS[@]} input"; (( ${#CNTOOLS_ASSET_TX_INPUTS[@]} == 1 )) || selection+=s
    cntools_table_pair 'Input selection' "${selection}" value
    [[ -z "${CNTOOLS_CHANGE_TOKEN_STATUS:-}" || "${CNTOOLS_CHANGE_TOKEN_STATUS}" == Disabled* ]] || cntools_table_pair 'Token fragmentation' "${CNTOOLS_CHANGE_TOKEN_STATUS}" value
    [[ -z "${CNTOOLS_CHANGE_UTXO_STATUS:-}" || "${CNTOOLS_CHANGE_UTXO_STATUS}" == Disabled* ]] || cntools_table_pair 'ADA-only management' "${CNTOOLS_CHANGE_UTXO_STATUS}" value
    [[ -z "${CNTOOLS_CHANGE_COLLATERAL_STATUS:-}" || "${CNTOOLS_CHANGE_COLLATERAL_STATUS}" == Disabled* ]] || cntools_table_pair 'Collateral candidate' "${CNTOOLS_CHANGE_COLLATERAL_STATUS}" value
    [[ "${CNTOOLS_ASSET_TX_SKIPPED}" == 0 ]] || cntools_table_pair 'App UTxOs left untouched' "${CNTOOLS_ASSET_TX_SKIPPED}" number
  } | cntools_table_render 'Transaction information' || return 1
  cntools_send_metadata_render || return 1
  if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]]; then
    cntools_ui_render_status warn 'Burning permanently destroys the selected quantity. Other tokens, rewards and deposits are not burned.'
  else cntools_ui_render_status info 'New tokens and all selected change return to this wallet. No stake registration, delegation or rewards are changed.'; fi
}

cntools_asset_tx_quantity_prompt() {
  local entered='' available="${CNTOOLS_FUNDING_ASSETS[${CNTOOLS_ASSET_TX_ID}]:-0}" quantity='' label=''
  if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]]; then
    # Drawn once: a rejected entry adds only its warning below.
    cntools_asset_label_into label "${CNTOOLS_ASSET_TX_ID}" 1 || return 2
    {
      cntools_table_pair Asset "${label}" accent
      cntools_table_pair 'Available (smallest units)' "$(cntools_number_format "${available}")" number
    } | cntools_table_render 'Burn amount'
  fi
  while true; do
    if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]]; then
      cntools_ui_input entered 'Quantity to burn (Enter = all)' all || return $?
      [[ -n "${entered}" && "${entered,,}" != all ]] || entered="${available}"
    else cntools_ui_input entered 'Quantity to mint (smallest units)' 'Whole number; commas are allowed' || return $?; fi
    if cntools_asset_tx_quantity_into quantity "${entered}" &&
      { [[ "${CNTOOLS_ASSET_TX_OPERATION}" != burn ]] || cntools_uint_greater_equal "${available}" "${quantity}"; }; then
      CNTOOLS_ASSET_TX_QUANTITY="${quantity}"
      cntools_transaction_log CHOICE "Asset ${CNTOOLS_ASSET_TX_OPERATION} quantity=${quantity} asset=${CNTOOLS_ASSET_TX_ID}"
      return 0
    fi
    cntools_ui_render_status warn 'Use a positive whole smallest-unit quantity, at most 9,223,372,036,854,775,807 and no more than available when burning.'
  done
}

cntools_asset_tx_burn_choose() {
  local identity='' chosen='' label='' index=0
  local -a identities=() choices=()
  for identity in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
    [[ "${identity%%.*}" == "${CNTOOLS_POLICY_ID}" && "${CNTOOLS_FUNDING_ASSETS[${identity}]}" != 0 ]] || continue
    identities+=("${identity}")
  done
  (( ${#identities[@]} > 0 )) || { cntools_asset_tx_fail 'This wallet has no eligible assets for the selected policy.'; return 2; }
  cntools_policy_asset_enrich "${identities[@]}"
  # A lone asset needs no picker; the Burn amount table names it.
  if (( ${#identities[@]} == 1 )); then
    CNTOOLS_ASSET_TX_ID="${identities[0]}"
    cntools_transaction_log CHOICE "Asset to burn auto-selected=${CNTOOLS_ASSET_TX_ID}"
    return 0
  fi
  # The policy is fixed, so rows show the asset name only.
  for index in "${!identities[@]}"; do
    cntools_asset_label_into label "${identities[index]}" "$((index+1))" || return 2
    choices+=("$((index+1)) · ${label} · ${identities[index]#*.} · $(cntools_number_format "${CNTOOLS_FUNDING_ASSETS[${identities[index]}]}") units")
  done
  cntools_ui_choose chosen 'Asset to burn' "${choices[@]}" Cancel || return $?
  [[ "${chosen}" != Cancel ]] || return 1
  for index in "${!choices[@]}"; do
    [[ "${choices[index]}" != "${chosen}" ]] || { CNTOOLS_ASSET_TX_ID="${identities[index]}"; return 0; }
  done
  return 2
}

cntools_asset_tx_result() { cntools_transaction_ui_render_result "$@"; CNTOOLS_ASSET_TX_RESULT_SHOWN=Y; }

cntools_asset_tx_remember() {
  cntools_policy_asset_remember "${CNTOOLS_ASSET_TX_DIRECTORY}" "${CNTOOLS_ASSET_TX_ID}" "${CNTOOLS_ASSET_TX_OPERATION}" \
    "${CNTOOLS_ASSET_TX_QUANTITY}" "$1" "$2" || {
      cntools_transaction_log WARN 'Asset transaction retained, but its advisory local asset record could not be updated (possibly locked).'
      cntools_ui_render_status warn 'The transaction/package is retained; its advisory local asset record could not be updated. This does not affect the transaction.'
    }
}

# Rejects a policy outside its time window before any wallet or asset prompt.
cntools_asset_tx_policy_window() {
  local window='' date=''
  cntools_policy_window_state_into window "${CNTOOLS_POLICY_SELECTED_BEFORE}" "${CNTOOLS_POLICY_SELECTED_AFTER}"
  case "${window}" in
    expired)
      cntools_slot_datetime_into date "${CNTOOLS_POLICY_SELECTED_BEFORE}" || date="slot ${CNTOOLS_POLICY_SELECTED_BEFORE}"
      cntools_asset_tx_fail "This policy expired on ${date}; neither minting nor burning is possible." ;;
    pending)
      cntools_slot_datetime_into date "${CNTOOLS_POLICY_SELECTED_AFTER}" || date="slot ${CNTOOLS_POLICY_SELECTED_AFTER}"
      cntools_asset_tx_fail "This policy is not valid until ${date}." ;;
    *) return 0 ;;
  esac
}

# Why this action can only save an unsigned package; empty when it can sign.
cntools_asset_tx_sign_note_into() {
  local _note_output="$1" _note_reason=''
  if [[ -z "${CNTOOLS_POLICY_SELECTED_SOURCE}" ]]; then
    if [[ -e "${CNTOOLS_ASSET_TX_DIRECTORY}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}.gpg" ]]; then
      _note_reason='the policy key is encrypted (Decrypt / Unlock Policy to sign here)'
    else _note_reason='the policy signing key is not on this system'; fi
  fi
  if [[ -z "${CNTOOLS_SEND_SOURCE}" ]]; then
    if [[ -e "${CNTOOLS_SEND_DIRECTORY}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}.gpg" ]]; then
      _note_reason+="${_note_reason:+; }the wallet key is encrypted (Wallet → Decrypt to sign here)"
    else _note_reason+="${_note_reason:+; }the wallet signing key is not on this system"; fi
  fi
  [[ -z "${_note_reason}" ]] || _note_reason="Unsigned package only: ${_note_reason}. Sign it with Transaction → Sign where the keys are."
  printf -v "${_note_output}" '%s' "${_note_reason}"
}

cntools_asset_tx_workflow() {
  local CNTOOLS_METADATA_BEGIN_CALLBACK=cntools_asset_tx_begin CNTOOLS_METADATA_OVERVIEW_CALLBACK=cntools_asset_tx_metadata_overview
  # The shared review states why only an unsigned package is offered.
  local CNTOOLS_TRANSACTION_UI_UNSIGNED_REASON=''
  local selected='' workflow='' staged='' signed='' saved='' proceed='' can_sign=N lifetime=1800 backend='' signed_body='' txid='' status=0 draft=''
  local previous_quantity='' previous_lifetime=''
  local -a changes=('Change quantity' 'Change metadata' 'Change expiry') previous_metadata=()
  cntools_asset_tx_begin
  # 3 = no usable policy (reason shown and acknowledged); 1 stays a plain Cancel.
  cntools_policy_selection_into selected transact || return $?
  CNTOOLS_ASSET_TX_DIRECTORY="${CNTOOLS_POLICY_PATHS[selected]}"
  cntools_policy_prepare "${CNTOOLS_ASSET_TX_DIRECTORY}" || { cntools_asset_tx_fail "${CNTOOLS_POLICY_ERROR:-Policy authority could not be verified.}"; return 2; }
  cntools_asset_tx_policy_window || return 2
  cntools_wallet_catalog_build || return 2
  cntools_wallet_choose selected Cancel funding || return $?
  cntools_send_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" || return 2
  cntools_ui_spin_function 'Fetching eligible wallet funds…' cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 2
  cntools_asset_tx_eligible_inventory || return 2
  {
    cntools_table_pair Wallet "${CNTOOLS_SEND_WALLET}" identifier
    cntools_table_pair 'Spendable ADA' "$(cntools_number_format_lovelace "${CNTOOLS_FUNDING_TOTAL}")" number
    cntools_table_pair 'Native assets' "${#CNTOOLS_FUNDING_ASSET_IDS[@]}" number
    cntools_table_pair Policy "${CNTOOLS_ASSET_TX_DIRECTORY##*/}" identifier
  } | cntools_table_render 'Source wallet' || return 2
  if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == mint ]]; then
    cntools_policy_asset_catalog "${CNTOOLS_ASSET_TX_DIRECTORY}" "${CNTOOLS_POLICY_ID}" || return 2
    cntools_policy_asset_choose_into CNTOOLS_ASSET_TX_ID "${CNTOOLS_POLICY_ID}" || return $?
  else cntools_asset_tx_burn_choose || return $?; fi
  cntools_asset_tx_quantity_prompt || return $?
  cntools_metadata_reset
  # Quick leaves metadata to the review's 'Change metadata'.
  if cntools_flow_quick; then status=1
  else cntools_ui_confirm 'Attach optional transaction metadata?' false || status=$?; fi
  if ((status == 0)); then
    # Esc leaves the metadata menu with what it holds; the review shows it.
    status=0; cntools_send_metadata_edit || status=$?
    ((status == 0 || status == 1)) || return "${status}"
  elif ((status != 1)); then return "${status}"; fi
  [[ -z "${CNTOOLS_SEND_SOURCE}" || -z "${CNTOOLS_POLICY_SELECTED_SOURCE}" ]] || can_sign=Y
  # Without both keys the unsigned package is the only workflow: say why on
  # the review and offer no 'Change workflow'.
  cntools_asset_tx_sign_note_into CNTOOLS_TRANSACTION_UI_UNSIGNED_REASON
  [[ "${can_sign}" != Y ]] || changes+=('Change workflow')
  cntools_transaction_ui_initial_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_initial_expiry_into lifetime || return $?
  cntools_ui_spin_function 'Checking policy, funds and building the asset transaction…' cntools_asset_tx_refresh_build_into staged "${lifetime}" || return 2
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into selected "${staged}" "${proceed}" cntools_asset_tx_begin cntools_asset_tx_render \
      "${changes[@]}" || return $?
    status=0; previous_quantity="${CNTOOLS_ASSET_TX_QUANTITY}"; previous_lifetime="${lifetime}"
    previous_metadata=("${CNTOOLS_METADATA_MODE}" "${CNTOOLS_METADATA_SCHEMA}" "${CNTOOLS_METADATA_MESSAGE}" "${CNTOOLS_METADATA_CUSTOM}")
    case "${selected}" in
      "${proceed}") break ;;
      'Change workflow') cntools_transaction_ui_workflow_into workflow "${can_sign}" || status=$? ;;
      'Change quantity') cntools_asset_tx_quantity_prompt || status=$? ;;
      'Change metadata')
        draft="${CNTOOLS_METADATA_MODE}|${CNTOOLS_METADATA_SCHEMA}|${CNTOOLS_METADATA_MESSAGE}|${CNTOOLS_METADATA_CUSTOM}"
        cntools_send_metadata_edit || status=$?
        # Edits made before Esc still apply, so they are rebuilt and reviewed.
        [[ "${status}" != 1 || "${draft}" == "${CNTOOLS_METADATA_MODE}|${CNTOOLS_METADATA_SCHEMA}|${CNTOOLS_METADATA_MESSAGE}|${CNTOOLS_METADATA_CUSTOM}" ]] || status=0 ;;
      'Change expiry') cntools_transaction_ui_expiry_into lifetime || status=$? ;;
      *) return 2 ;;
    esac
    # Esc keeps the current value and returns to the review; Ctrl+C cancels.
    ((status != 1)) || continue
    ((status == 0)) || return "${status}"
    # A workflow change rebuilds only when Quick raised an unsigned package's expiry.
    [[ "${selected}" != 'Change workflow' ]] || cntools_transaction_ui_unsigned_lifetime_into lifetime "${workflow}" || continue
    cntools_ui_spin_function 'Rebuilding the asset transaction…' cntools_asset_tx_refresh_build_into staged "${lifetime}" && continue
    # A change that cannot be built is undone and the previous one rebuilt.
    cntools_transaction_log WARN "Asset transaction change could not be built; previous values restored change=${selected}"
    CNTOOLS_ASSET_TX_QUANTITY="${previous_quantity}"; lifetime="${previous_lifetime}"
    CNTOOLS_METADATA_MODE="${previous_metadata[0]}"; CNTOOLS_METADATA_SCHEMA="${previous_metadata[1]}"
    CNTOOLS_METADATA_MESSAGE="${previous_metadata[2]}"; CNTOOLS_METADATA_CUSTOM="${previous_metadata[3]}"
    cntools_ui_spin_function 'Rebuilding the asset transaction…' cntools_asset_tx_refresh_build_into staged "${lifetime}" || return 2
    cntools_ui_render_status warn "That change could not be built, so it was undone: ${CNTOOLS_TRANSACTION_ERROR:-see ${CNTOOLS_LOG} for details.}"
    cntools_transaction_clear_error
  done
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned "asset-${CNTOOLS_ASSET_TX_OPERATION}" || return 2
    CNTOOLS_ASSET_TX_SAVED="${saved}"; cntools_asset_tx_begin
    cntools_asset_tx_result success 'Ready for Transaction → Sign, then Submit. The policy witness is required in addition to wallet spending.' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    cntools_asset_tx_remember "${CNTOOLS_TRANSACTION_ID}" Unsigned
    return 0
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function 'Rechecking policy validity and selected inputs…' cntools_asset_tx_recheck || return 2
  cntools_ui_spin_function 'Signing wallet and policy witnesses…' cntools_transaction_sign_registered "${staged}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" && [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || return 2
  cntools_transaction_save_into saved "${signed}" signed "asset-${CNTOOLS_ASSET_TX_OPERATION}" || return 2
  CNTOOLS_ASSET_TX_SAVED="${saved}"; txid="${CNTOOLS_TRANSACTION_ID}"
  if [[ "${workflow}" == 'Create and sign' ]]; then
    cntools_asset_tx_begin; cntools_asset_tx_result success 'Signed · ready for Transaction → Submit' "${txid}" "${saved}"
    cntools_asset_tx_remember "${txid}" Signed; return 0
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  signed_body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  # A burn cannot be undone, so it is asked again in both flow styles; the
  # reviewed choice is a mint's confirmation.
  status=0
  if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]]; then cntools_transaction_ui_confirm_submit "${backend}" always burn || status=$?
  else cntools_transaction_ui_confirm_submit "${backend}" || status=$?; fi
  if ((status != 0)); then
    cntools_asset_tx_begin; cntools_asset_tx_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    cntools_asset_tx_remember "${txid}" Signed; return 0
  fi
  cntools_ui_spin_function 'Rechecking policy validity and selected inputs…' cntools_asset_tx_recheck || status=$?
  if ((status == 0)); then cntools_ui_spin_function 'Submitting asset transaction…' cntools_transaction_ui_submit_selected "${backend}" "${signed_body}" "${txid}" || status=$?; fi
  cntools_asset_tx_begin
  if ((status != 0)); then
    cntools_asset_tx_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check the chain before retrying.}" "${txid}" "${saved}"
    cntools_asset_tx_remember "${txid}" 'Submission unconfirmed'; return 2
  fi
  cntools_asset_tx_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not confirmation of inclusion." "${txid}"
  cntools_asset_tx_remember "${txid}" Submitted
  cntools_transaction_ui_offer_monitor "${txid}"
}

cntools_asset_tx_metadata_overview() {
  { cntools_table_pair Wallet "${CNTOOLS_SEND_WALLET}" identifier
    cntools_table_pair Asset "${CNTOOLS_ASSET_TX_ID}" identifier
    cntools_table_pair Action "${CNTOOLS_ASSET_TX_OPERATION^}" value
    cntools_table_pair 'Quantity (smallest units)' "$(cntools_number_format "${CNTOOLS_ASSET_TX_QUANTITY}")" number
  } | cntools_table_render 'Asset transaction'
}

cntools_asset_tx_action() {
  local status=0
  CNTOOLS_ASSET_TX_OPERATION="$1"; CNTOOLS_ASSET_TX_RESULT_SHOWN=N; CNTOOLS_ASSET_TX_SAVED=''
  cntools_transaction_clear_error
  cntools_asset_tx_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait; return 0 ;;
    3) return 0 ;; # Nothing to choose; the reason was shown and acknowledged.
    1|130)
      cntools_transaction_log CHOICE "Asset transaction cancelled saved=${CNTOOLS_ASSET_TX_SAVED:-none}"
      # Straight back to the menu unless a package was already saved.
      [[ -n "${CNTOOLS_ASSET_TX_SAVED}" ]] || return "${status}"
      cntools_ui_render_status info "Cancelled. The saved package remains available: ${CNTOOLS_ASSET_TX_SAVED}"
      cntools_ui_wait
      return "${status}" ;;
  esac
  cntools_asset_tx_fail "${CNTOOLS_TRANSACTION_ERROR:-${CNTOOLS_POLICY_ERROR:-Asset transaction failed. See ${CNTOOLS_LOG} for details.}}" || true
  [[ "${CNTOOLS_ASSET_TX_RESULT_SHOWN}" == Y ]] || cntools_asset_tx_result danger "${CNTOOLS_TRANSACTION_ERROR}" '' "${CNTOOLS_ASSET_TX_SAVED}"
  cntools_ui_wait
  return 1 # Shown and acknowledged above; no second failure banner.
}
