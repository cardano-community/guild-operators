#!/usr/bin/env bash
# Gum interaction and presentation for guarded wallet removal.
# Loaded after wallet-remove.sh.
# shellcheck disable=SC2034

cntools_wallet_remove_table_widths_into() {
  local output_name="${1:-}"
  local table_width=""
  local value_width=0

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=""
  table_width="$(cntools_ui_content_width 160 48)" || return 1
  value_width=$((table_width - 29))
  (( value_width >= 18 )) || return 1
  output_ref="22,${value_width}"
}

cntools_wallet_remove_styled_row() {
  local label="${1:-}"
  local value="${2:-}"
  local role="${3:-value}"
  local styled=""

  cntools_theme_style_value_into styled "${role}" "${value}" || return 1
  printf '%s\t%s\n' "${label}" "${styled}"
}

cntools_wallet_remove_funding_value() {
  local status="${1:-unknown}"
  local value="${2:-}"

  case "${status}" in
    empty|funded) cntools_wallet_format_lovelace "${value}" ;;
    not-present) printf 'Not present\n' ;;
    *) printf 'Unavailable\n' ;;
  esac
}

cntools_wallet_remove_registration_value() {
  case "${1:-unknown}" in
    registered) printf 'Registered\n' ;;
    not-registered) printf 'Not registered\n' ;;
    not-present) printf 'Credential not present\n' ;;
    *) printf 'Unavailable\n' ;;
  esac
}

cntools_wallet_remove_value_role() {
  case "${1:-}" in
    Registered|*funded*) printf 'danger\n' ;;
    "Not registered"|"No funds or active registrations found")
      printf 'success\n'
      ;;
    "Not present"|"Credential not present") printf 'muted\n' ;;
    Unavailable|Incomplete|*offline*) printf 'warning\n' ;;
    *) printf 'value\n' ;;
  esac
}

cntools_wallet_remove_render_review() {
  local wallet_directory="${1:-}"
  local wallet_type="${2:-Unknown}"
  local protection="${3:-Unknown}"
  local utxo_value=""
  local reward_value=""
  local asset_value="Unavailable"
  local stake_value=""
  local drep_value=""
  local result=""
  local result_role="success"
  local role=""
  local widths=""

  utxo_value="$(cntools_wallet_remove_funding_value \
    "${CNTOOLS_WALLET_REMOVE_UTXO_STATUS}" \
    "${CNTOOLS_WALLET_TOTAL_LOVELACE:-}")" || return 1
  reward_value="$(cntools_wallet_remove_funding_value \
    "${CNTOOLS_WALLET_REMOVE_REWARD_STATUS}" \
    "${CNTOOLS_WALLET_REWARD_LOVELACE:-}")" || return 1
  case "${CNTOOLS_WALLET_REMOVE_UTXO_STATUS}" in
    empty|funded)
      if [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[0-9]+$ ]]; then
        cntools_wallet_format_number_into \
          asset_value "${CNTOOLS_WALLET_ASSET_COUNT}" || return 1
      fi
      ;;
    not-present) asset_value="Not present" ;;
  esac
  stake_value="$(cntools_wallet_remove_registration_value \
    "${CNTOOLS_WALLET_REMOVE_STAKE_STATUS}")" || return 1
  drep_value="$(cntools_wallet_remove_registration_value \
    "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}")" || return 1
  if (( CNTOOLS_WALLET_REMOVE_WARNING_COUNT == 0 )); then
    result="No funds or active registrations found"
  else
    result="${CNTOOLS_WALLET_REMOVE_WARNING_COUNT} warning(s) require review"
    result_role="danger"
  fi

  cntools_wallet_remove_table_widths_into widths || return 1
  cntools_ui_render_detail "Removal review" || return 1
  {
    printf 'Check\tResult\n'
    cntools_wallet_remove_styled_row \
      "Wallet" "${wallet_directory##*/}" identifier
    cntools_wallet_remove_styled_row "Type" "${wallet_type}" accent
    role="$(cntools_wallet_status_role "${protection}")" || return 1
    cntools_wallet_remove_styled_row "Key protection" "${protection}" "${role}"
    if [[ "${CNTOOLS_WALLET_REMOVE_UTXO_STATUS}" == "funded" ]]; then
      role="danger"
    elif [[ "${CNTOOLS_WALLET_REMOVE_UTXO_STATUS}" == "empty" ]]; then
      role="number"
    else
      role="$(cntools_wallet_remove_value_role "${utxo_value}")" || return 1
    fi
    cntools_wallet_remove_styled_row "UTxO balance" "${utxo_value}" "${role}"
    if [[ "${CNTOOLS_WALLET_REMOVE_REWARD_STATUS}" == "funded" ]]; then
      role="danger"
    elif [[ "${CNTOOLS_WALLET_REMOVE_REWARD_STATUS}" == "empty" ]]; then
      role="number"
    else
      role="$(cntools_wallet_remove_value_role "${reward_value}")" || return 1
    fi
    cntools_wallet_remove_styled_row "Rewards" "${reward_value}" "${role}"
    if [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
      role="danger"
    elif [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" == "0" ]]; then
      role="number"
    else
      role="$(cntools_wallet_remove_value_role "${asset_value}")" || return 1
    fi
    cntools_wallet_remove_styled_row "Native assets" "${asset_value}" "${role}"
    role="$(cntools_wallet_remove_value_role "${stake_value}")" || return 1
    cntools_wallet_remove_styled_row \
      "Stake registration" "${stake_value}" "${role}"
    role="$(cntools_wallet_remove_value_role "${drep_value}")" || return 1
    cntools_wallet_remove_styled_row \
      "DRep registration" "${drep_value}" "${role}"
    cntools_wallet_remove_styled_row \
      "Wallet data source" "${CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE}" value
    if [[ "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}" != "not-present" ]]; then
      cntools_wallet_remove_styled_row \
        "DRep data source" "${CNTOOLS_WALLET_REMOVE_DREP_SOURCE}" value
    fi
    cntools_wallet_remove_styled_row "Safety result" "${result}" "${result_role}"
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
  printf '\n'
}

cntools_wallet_remove_render_warnings() {
  if [[ "${CNTOOLS_WALLET_REMOVE_HAS_FUNDS}" == "Y" ]]; then
    cntools_ui_render_status error \
      "This wallet still contains funds. Removing its signing keys may make those funds permanently inaccessible."
  fi
  if [[ "${CNTOOLS_WALLET_REMOVE_STAKE_REGISTERED}" == "Y" ]]; then
    cntools_ui_render_status error \
      "The stake credential is still registered. Removing the wallet will not deregister it, withdraw rewards, or reclaim its deposit."
  fi
  if [[ "${CNTOOLS_WALLET_REMOVE_DREP_REGISTERED}" == "Y" ]]; then
    cntools_ui_render_status error \
      "The DRep credential is still registered. Removing the wallet will not retire it or reclaim its deposit."
  fi
  if [[ "${CNTOOLS_WALLET_REMOVE_UNKNOWN}" == "Y" ]]; then
    cntools_ui_render_status warn \
      "CNTools could not verify every balance and registration. Treat this wallet as potentially funded or registered."
  fi
  cntools_ui_render_status warn \
    "Removal permanently deletes every file in this wallet directory, including signing keys. Confirm that a usable backup exists if the wallet may be needed again."
}

cntools_wallet_remove_render_result() {
  local wallet_name="${1:-}"
  local widths=""

  cntools_wallet_remove_table_widths_into widths || return 1
  cntools_ui_render_detail "Wallet removed" || return 1
  {
    printf 'Result\tValue\n'
    cntools_wallet_remove_styled_row "Wallet" "${wallet_name}" identifier
    cntools_wallet_remove_styled_row \
      "Files deleted" "${CNTOOLS_WALLET_REMOVE_FILE_COUNT}" number
    cntools_wallet_remove_styled_row "Status" "Removed permanently" success
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
  printf '\n'
}

cntools_wallet_action_remove() {
  local selected_index=""
  local wallet_directory=""
  local wallet_name=""
  local wallet_type=""
  local protection=""
  local status=0

  cntools_ui_action_begin "Remove" "/ Wallet / Remove"
  if ! cntools_wallet_catalog_build; then
    cntools_ui_render_status error \
      "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  if (( ${#CNTOOLS_WALLET_NAMES[@]} == 0 )); then
    cntools_ui_render_status warn "No wallets are available to remove."
    cntools_ui_wait
    return 0
  fi
  if cntools_wallet_choose selected_index; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_remove_log CHOICE "wallet removal selection cancelled"
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    cntools_ui_render_status error \
      "The wallet selection failed. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return "${status}"
  fi

  wallet_directory="${CNTOOLS_WALLET_PATHS[selected_index]}"
  wallet_name="${CNTOOLS_WALLET_NAMES[selected_index]}"
  wallet_type="${CNTOOLS_WALLET_TYPES[selected_index]}"
  protection="${CNTOOLS_WALLET_PROTECTIONS[selected_index]}"
  cntools_ui_action_begin "Remove" "/ Wallet / Remove"
  if ! cntools_wallet_prepare_selected_material "${wallet_directory}"; then
    cntools_wallet_remove_log WARN \
      "Some public wallet material could not be prepared before removal wallet=${wallet_name}"
  fi
  if cntools_ui_spin_function \
      "Checking ${wallet_name} balances and registrations…" \
      cntools_wallet_remove_inspect "${wallet_directory}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_REMOVE_ERROR:-The wallet safety check failed. See ${CNTOOLS_LOG}.}"
    cntools_ui_wait
    return "${status}"
  fi

  cntools_ui_action_begin "Remove" "/ Wallet / Remove"
  cntools_wallet_remove_render_review \
    "${wallet_directory}" "${wallet_type}" "${protection}" || return 1
  cntools_wallet_remove_render_warnings
  if cntools_ui_confirm "Permanently remove ${wallet_name}?"; then
    status=0
  else
    status=$?
    if (( status == 1 )); then
      cntools_wallet_remove_log CHOICE \
        "wallet removal declined wallet=${wallet_name} warnings=${CNTOOLS_WALLET_REMOVE_WARNING_COUNT}"
      cntools_gum_clear
      return 0
    fi
    return "${status}"
  fi
  cntools_wallet_remove_log CHOICE \
    "wallet removal confirmed wallet=${wallet_name} warnings=${CNTOOLS_WALLET_REMOVE_WARNING_COUNT}"

  if cntools_ui_spin_function \
      "Removing ${wallet_name}…" \
      cntools_wallet_remove_delete "${wallet_directory}"; then
    status=0
  else
    status=$?
  fi
  cntools_ui_action_begin "Remove" "/ Wallet / Remove"
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_REMOVE_ERROR:-Wallet removal failed. See ${CNTOOLS_LOG}.}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_ui_render_status success \
    "Wallet ${wallet_name} was removed successfully."
  cntools_wallet_remove_render_result "${wallet_name}" || true
  cntools_ui_wait
}
