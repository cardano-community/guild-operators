#!/usr/bin/env bash
# Compact Send presentation. Transaction validation remains in the shared engine.
# shellcheck disable=SC2034

cntools_send_render_source() {
  local widths=""
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_ui_render_detail 'Source wallet' || return 1
  {
    printf 'Wallet detail\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${CNTOOLS_SEND_WALLET}" identifier
    cntools_transaction_ui_styled_row 'Spendable ADA' "$(cntools_wallet_format_lovelace "${CNTOOLS_FUNDING_TOTAL}")" number
    cntools_transaction_ui_styled_row 'Native assets' "$(cntools_number_format "${#CNTOOLS_FUNDING_ASSET_IDS[@]}")" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_send_render_recipient() {
  local widths=""
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  {
    printf 'Recipient detail\tValue\n'
    cntools_transaction_ui_styled_row Recipient "$1" identifier
    cntools_transaction_ui_styled_row Address "$2" address
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_send_render_assets() {
  local index="$1" asset="" asset_label="" available="" selected="" width="" role="" n=0
  width="$(cntools_ui_content_width 220 72)" || return 1
  cntools_ui_render_detail 'Native assets · smallest units' || return 1
  {
    printf 'Asset\tAvailable\tSelected\n'
    for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      n=$((n+1)); role=muted
      [[ "${CNTOOLS_FUNDING_ASSETS[${asset}]}" == 0 ]] || role=number
      cntools_theme_style_value_into available "${role}" "$(cntools_number_format "${CNTOOLS_FUNDING_ASSETS[${asset}]}")" || return 1
      role=muted
      [[ "${CNTOOLS_SEND_ASSETS[${index}|${asset}]:-0}" == 0 ]] || role=success
      cntools_theme_style_value_into selected "${role}" "$(cntools_number_format "${CNTOOLS_SEND_ASSETS[${index}|${asset}]:-0}")" || return 1
      cntools_asset_label_into asset_label "${asset}" "${n}" || return 1
      cntools_wallet_table_row_prepared "${n} · ${asset_label}" "${available}" "${selected}"
      cntools_wallet_table_row_prepared "${asset}" '' ''
    done
  } | cntools_ui_table --separator $'\t' --widths "$((width-57)),23,24"
}

cntools_send_render_information() {
  local widths="" selection="${CNTOOLS_TX_SELECTION_STRATEGY}" expiry_label="" change_total=0 amount=""
  for amount in "${CNTOOLS_CHANGE_OUTPUT_LOVELACE[@]}"; do
    cntools_uint_add_into change_total "${change_total}" "${amount}" || return 1
  done
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  [[ "${CNTOOLS_SEND_MODE}" == exact ]] || selection='All spendable inputs'
  cntools_slot_datetime_into expiry_label "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" || expiry_label='Date unavailable'
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Transaction detail\tValue\n'
    cntools_transaction_ui_styled_row Fee "$(cntools_wallet_format_lovelace "${CNTOOLS_SEND_FEE}")" number
    cntools_transaction_ui_styled_row 'Returned change' "$(cntools_wallet_format_lovelace "${change_total}") · $(cntools_number_format "${#CNTOOLS_CHANGE_OUTPUTS[@]}") outputs" number
    cntools_transaction_ui_styled_row 'Input selection' "${selection} · $(cntools_number_format "${#CNTOOLS_COIN_SELECTED_REFS[@]}") inputs" value
    cntools_transaction_ui_styled_row 'Token fragmentation' "${CNTOOLS_CHANGE_TOKEN_STATUS}" value
    cntools_transaction_ui_styled_row 'ADA-only management' "${CNTOOLS_CHANGE_UTXO_STATUS}" value
    cntools_transaction_ui_styled_row 'Collateral candidate' "${CNTOOLS_CHANGE_COLLATERAL_STATUS}" value
    cntools_transaction_ui_styled_row 'Expires' "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_send_render_result() {
  local state="$1" message="$2" txid="${3:-}" saved="${4:-}" widths="" safe_message=""
  cntools_wallet_sanitize_display_into safe_message "${message}" || return 1
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_ui_render_detail 'Transfer result' || return 1
  {
    printf 'Result\tValue\n'
    cntools_transaction_ui_styled_row Status "${safe_message}" "${state}"
    [[ -z "${txid}" ]] || cntools_transaction_ui_styled_row 'Transaction ID' "${txid}" identifier
    [[ -z "${saved}" ]] || cntools_transaction_ui_styled_row 'Saved package' "${saved}" identifier
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  CNTOOLS_SEND_RESULT_SHOWN=Y
}
