#!/usr/bin/env bash
# Guided mint/burn with the shared transaction review/sign/export/submit UX.
# shellcheck disable=SC2034,SC2015
CNTOOLS_ASSET_TX_RESULT_SHOWN=N CNTOOLS_ASSET_TX_SAVED=''
cntools_asset_tx_begin() { cntools_policy_manage_begin "${CNTOOLS_ASSET_TX_OPERATION^} Asset"; }

cntools_asset_tx_render() {
  local label='' expiry=''
  cntools_asset_label_into label "${CNTOOLS_ASSET_TX_ID}" 1 || return 1
  cntools_transaction_ui_expiry_label_into expiry "${CNTOOLS_SEND_EXPIRY}" || return 1
  {
    cntools_table_pair Wallet "${CNTOOLS_SEND_WALLET}" identifier
    cntools_table_pair Policy "${CNTOOLS_ASSET_TX_DIRECTORY##*/}" identifier
    cntools_table_pair Asset "${label}" accent
    cntools_table_pair 'Policy.name (hex)' "${CNTOOLS_ASSET_TX_ID}" identifier
    cntools_table_pair "${CNTOOLS_ASSET_TX_OPERATION^} quantity (smallest units)" "${CNTOOLS_ASSET_TX_QUANTITY}" number
    cntools_table_pair 'Return address' "${CNTOOLS_SEND_ADDRESS}" identifier
    cntools_table_pair Fee "$(cntools_wallet_format_lovelace "${CNTOOLS_ASSET_TX_FEE}")" number
    cntools_table_pair Expires "${expiry}" value
    cntools_table_pair 'Input selection' "${CNTOOLS_TX_SELECTION_STRATEGY:-balanced} · ${#CNTOOLS_ASSET_TX_INPUTS[@]} inputs" value
    cntools_table_pair 'Token fragmentation' "${CNTOOLS_CHANGE_TOKEN_STATUS}" value
    cntools_table_pair 'ADA-only management' "${CNTOOLS_CHANGE_UTXO_STATUS}" value
    cntools_table_pair 'Collateral candidate' "${CNTOOLS_CHANGE_COLLATERAL_STATUS}" value
    [[ "${CNTOOLS_ASSET_TX_SKIPPED}" == 0 ]] || cntools_table_pair 'App UTxOs left untouched' "${CNTOOLS_ASSET_TX_SKIPPED}" number
  } | cntools_table_render 'Transaction information' || return 1
  cntools_send_metadata_render || return 1
  [[ -z "${CNTOOLS_POLICY_SELECTED_BEFORE}" ]] || cntools_ui_render_status info 'The policy deadline also limits transaction expiry; No expiry cannot override it.'
  if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]]; then
    cntools_ui_render_status warn 'Burning permanently destroys the selected quantity. Other tokens, rewards and deposits are not burned.'
  else cntools_ui_render_status info 'New tokens and all selected change return to this wallet. No stake registration, delegation or rewards are changed.'; fi
}

cntools_asset_tx_quantity_prompt() {
  local entered='' available="${CNTOOLS_FUNDING_ASSETS[${CNTOOLS_ASSET_TX_ID}]:-0}" quantity=''
  while true; do
    if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]]; then
      {
        cntools_table_pair 'Available (smallest units)' "${available}" number
      } | cntools_table_render 'Burn amount'
      cntools_ui_input entered 'Quantity to burn (or all)' all || return $?
      [[ "${entered,,}" != all ]] || entered="${available}"
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
  for index in "${!identities[@]}"; do
    cntools_asset_label_into label "${identities[index]}" "$((index+1))" || return 2
    choices+=("${label} · ${identities[index]} · $(cntools_number_format "${CNTOOLS_FUNDING_ASSETS[${identities[index]}]}") units")
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

cntools_asset_tx_workflow() {
  local CNTOOLS_METADATA_BEGIN_CALLBACK=cntools_asset_tx_begin CNTOOLS_METADATA_OVERVIEW_CALLBACK=cntools_asset_tx_metadata_overview
  local selected='' workflow='' staged='' signed='' saved='' proceed='' can_sign=N lifetime=1800 backend='' signed_body='' txid='' status=0
  cntools_asset_tx_begin
  cntools_policy_selection_into selected || return $?
  CNTOOLS_ASSET_TX_DIRECTORY="${CNTOOLS_POLICY_PATHS[selected]}"
  cntools_policy_prepare "${CNTOOLS_ASSET_TX_DIRECTORY}" || { cntools_asset_tx_fail "${CNTOOLS_POLICY_ERROR:-Policy authority could not be verified.}"; return 2; }
  cntools_wallet_catalog_build || return 2
  cntools_wallet_choose selected Cancel send || return $?
  cntools_send_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" || return 2
  cntools_ui_spin_function 'Fetching eligible wallet funds…' cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 2
  cntools_asset_tx_eligible_inventory || return 2
  {
    cntools_table_pair Wallet "${CNTOOLS_SEND_WALLET}" identifier
    cntools_table_pair 'Spendable ADA' "$(cntools_wallet_format_lovelace "${CNTOOLS_FUNDING_TOTAL}")" number
    cntools_table_pair 'Native assets' "${#CNTOOLS_FUNDING_ASSET_IDS[@]}" number
    cntools_table_pair Policy "${CNTOOLS_ASSET_TX_DIRECTORY##*/}" identifier
  } | cntools_table_render 'Source wallet' || return 2
  if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == mint ]]; then
    cntools_policy_asset_catalog "${CNTOOLS_ASSET_TX_DIRECTORY}" "${CNTOOLS_POLICY_ID}" || return 2
    cntools_policy_asset_choose_into CNTOOLS_ASSET_TX_ID "${CNTOOLS_POLICY_ID}" || return $?
  else cntools_asset_tx_burn_choose || return $?; fi
  cntools_asset_tx_quantity_prompt || return $?
  cntools_metadata_reset
  cntools_ui_confirm 'Attach optional transaction metadata?' false || status=$?
  if ((status == 0)); then cntools_send_metadata_edit || return $?; elif ((status != 1)); then return "${status}"; fi
  [[ -z "${CNTOOLS_SEND_SOURCE}" || -z "${CNTOOLS_POLICY_SELECTED_SOURCE}" ]] || can_sign=Y
  cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_expiry_into lifetime || return $?
  cntools_ui_spin_function 'Checking policy, funds and building the asset transaction…' cntools_asset_tx_refresh_build_into staged "${lifetime}" || return 2
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into selected "${staged}" "${proceed}" cntools_asset_tx_begin cntools_asset_tx_render \
      'Change quantity' 'Change metadata' 'Change expiry' 'Change workflow' || return $?
    case "${selected}" in
      "${proceed}") break ;;
      'Change workflow') cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?; continue ;;
      'Change quantity') cntools_asset_tx_quantity_prompt || return $? ;;
      'Change metadata') cntools_send_metadata_edit || return $? ;;
      'Change expiry') cntools_transaction_ui_expiry_into lifetime || return $? ;;
      *) return 2 ;;
    esac
    cntools_ui_spin_function 'Rebuilding the asset transaction…' cntools_asset_tx_refresh_build_into staged "${lifetime}" || return 2
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
  status=0; cntools_transaction_ui_confirm_submit "${backend}" || status=$?
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
    cntools_table_pair 'Quantity (smallest units)' "${CNTOOLS_ASSET_TX_QUANTITY}" number
  } | cntools_table_render 'Asset transaction'
}

cntools_asset_tx_action() {
  local status=0
  CNTOOLS_ASSET_TX_OPERATION="$1"; CNTOOLS_ASSET_TX_RESULT_SHOWN=N; CNTOOLS_ASSET_TX_SAVED=''
  cntools_transaction_clear_error
  cntools_asset_tx_workflow || status=$?
  if ((status == 1 || status == 130)); then
    cntools_transaction_log CHOICE 'Asset transaction cancelled; saved packages were retained'
    cntools_ui_render_status info 'Cancelled. Any packages already saved remain available.'
  elif ((status != 0)); then
    cntools_asset_tx_fail "${CNTOOLS_TRANSACTION_ERROR:-${CNTOOLS_POLICY_ERROR:-Asset transaction failed. See ${CNTOOLS_LOG} for details.}}" || true
    [[ "${CNTOOLS_ASSET_TX_RESULT_SHOWN}" == Y ]] || cntools_asset_tx_result danger "${CNTOOLS_TRANSACTION_ERROR}" '' "${CNTOOLS_ASSET_TX_SAVED}"
  fi
  cntools_ui_wait
  ((status == 0 || status == 1 || status == 130))
}
