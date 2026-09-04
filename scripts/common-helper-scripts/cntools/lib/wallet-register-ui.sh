#!/usr/bin/env bash
# Gum workflow for stake registration and de-registration transactions.
# Loaded after wallet-register.sh and transaction-ui.sh.

cntools_wallet_register_table_widths_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_label_width="${2:-22}"
  local _cntools_table_width=""
  local _cntools_value_width=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_table_width="$(cntools_ui_content_width 220 58)" || return 1
  _cntools_value_width=$((_cntools_table_width - _cntools_label_width - 7))
  (( _cntools_value_width >= 18 )) || return 1
  _cntools_output_ref="${_cntools_label_width},${_cntools_value_width}"
}

cntools_wallet_register_styled_row() {
  local label="${1:-}"
  local value="${2:-}"
  local role="${3:-value}"
  local styled=""

  cntools_theme_style_value_into styled "${role}" "${value}" || return 1
  printf '%s\t%s\n' "${label}" "${styled}"
}

cntools_wallet_register_styled_policy_row() {
  local label="${1:-}"
  local configured="${2:-}"
  local applied="${3:-}"
  local configured_styled=""
  local applied_styled=""

  cntools_theme_style_value_into \
    configured_styled accent "${configured}" || return 1
  cntools_theme_style_value_into \
    applied_styled value "${applied}" || return 1
  printf '%s\t%s\t%s\n' \
    "${label}" "${configured_styled}" "${applied_styled}"
}

cntools_wallet_register_render_plan() {
  local widths=""
  local available_inputs=""
  local selected_inputs=""
  local assets=""
  local selection=""
  local selection_margin=""
  local selection_result=""
  local fragmentation="Disabled"
  local management="Disabled"
  local collateral="Disabled"
  local output_count=""
  local output_index=0
  local output_value=""
  local policy_table_width=""
  local policy_widths=""
  local payment_method="Portable package"
  local stake_method="Portable package"

  cntools_wallet_register_table_widths_into widths 22 || return 1
  cntools_wallet_format_number_into \
    available_inputs "${CNTOOLS_WALLET_REGISTER_AVAILABLE_INPUT_COUNT}" ||
    return 1
  cntools_wallet_format_number_into \
    selected_inputs "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}" || return 1
  cntools_wallet_format_number_into \
    assets "${CNTOOLS_WALLET_REGISTER_ASSET_COUNT}" || return 1
  cntools_wallet_format_number_into \
    output_count "${#CNTOOLS_CHANGE_OUTPUTS[@]}" || return 1
  selection="$(cntools_settings_strategy_name)" || return 1
  cntools_uint_subtract_into selection_margin \
    "${CNTOOLS_WALLET_REGISTER_LOVELACE}" \
    "${CNTOOLS_COIN_REQUIRED_LOVELACE}" || return 1
  selection_result="Selected ${selected_inputs} of ${available_inputs} UTxOs · ${assets} native assets touched · margin $(cntools_wallet_format_lovelace "${selection_margin}")"
  policy_table_width="$(cntools_ui_content_width 220 72)" || return 1
  policy_widths="20,28,$((policy_table_width - 58))"
  if [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION}" == "Y" ]]; then
    fragmentation="Enabled · maximum ${CNTOOLS_TX_TOKEN_MAX_ASSETS} assets per output"
  fi
  if [[ "${CNTOOLS_TX_UTXO_MANAGEMENT}" == "Y" ]]; then
    management="Enabled · target ${CNTOOLS_TX_UTXO_TARGET_COUNT} ADA-only UTxOs · ${CNTOOLS_TX_UTXO_PERCENTAGES//,/% · }%"
  fi
  if [[ "${CNTOOLS_TX_UTXO_MANAGEMENT}" == "Y" &&
        "${CNTOOLS_TX_COLLATERAL_MANAGEMENT}" == "Y" ]]; then
    collateral="Enabled · target ${CNTOOLS_TX_COLLATERAL_TARGET_COUNT} · $(cntools_wallet_format_lovelace "${CNTOOLS_TX_COLLATERAL_LOVELACE}")"
  fi
  [[ -z "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" ]] ||
    payment_method="$([[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == "Hardware" ]] && printf 'Hardware device' || printf 'Local signing key')"
  [[ -z "${CNTOOLS_WALLET_REGISTER_STAKE_SOURCE}" ]] ||
    stake_method="$([[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == "Hardware" ]] && printf 'Hardware device' || printf 'Local signing key')"

  cntools_ui_render_detail "Stake ${CNTOOLS_WALLET_REGISTER_NOUN}" || return 1
  {
    printf 'Transaction detail\tValue\n'
    cntools_wallet_register_styled_row \
      "Wallet" "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
    cntools_wallet_register_styled_row \
      "Wallet type" "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" accent
    cntools_wallet_register_styled_row \
      "Stake address" "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" address
    cntools_wallet_register_styled_row \
      "Change address" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" address
    cntools_wallet_register_styled_row \
      "Available UTxOs" "${available_inputs}" number
    cntools_wallet_register_styled_row \
      "Selected inputs" "${selected_inputs}" number
    cntools_wallet_register_styled_row \
      "Available balance" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE}")" \
      number
    cntools_wallet_register_styled_row \
      "Selected balance" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_LOVELACE}")" \
      number
    cntools_wallet_register_styled_row \
      "Fee safety ceiling" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_FEE_RESERVE}")" \
      number
    if (( CNTOOLS_WALLET_REGISTER_ASSET_COUNT > 0 )); then
      cntools_wallet_register_styled_row \
        "Native assets preserved" "${assets}" number
    fi
    cntools_wallet_register_styled_row \
      "${CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL}" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")" \
      number
    if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == "deregister" ]]; then
      cntools_wallet_register_styled_row \
        "Claimable rewards" \
        "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REWARD_LOVELACE}")" \
        number
      if [[ -n "${CNTOOLS_WALLET_POOL_DELEGATION:-}" ]]; then
        cntools_wallet_register_styled_row \
          "Stake pool delegation" \
          "${CNTOOLS_WALLET_POOL_DELEGATION}" identifier
      fi
      if [[ -n "${CNTOOLS_WALLET_DREP_DELEGATION:-}" ]]; then
        cntools_wallet_register_styled_row \
          "DRep delegation" "${CNTOOLS_WALLET_DREP_DELEGATION}" identifier
      fi
    fi
    cntools_wallet_register_styled_row \
      "Chain data" "${CNTOOLS_WALLET_REGISTER_SOURCE}" accent
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'

  cntools_ui_render_detail "Transaction policy" || return 1
  {
    printf 'Policy\tConfigured\tApplied\n'
    cntools_wallet_register_styled_policy_row \
      "Coin selection" "${selection}" \
      "${selection_result}"
    cntools_wallet_register_styled_policy_row \
      "Token fragmentation" "${fragmentation}" \
      "${CNTOOLS_CHANGE_TOKEN_STATUS}"
    cntools_wallet_register_styled_policy_row \
      "ADA-only management" "${management}" \
      "${CNTOOLS_CHANGE_UTXO_STATUS}"
    cntools_wallet_register_styled_policy_row \
      "Collateral candidate" "${collateral}" \
      "${CNTOOLS_CHANGE_COLLATERAL_STATUS}"
    cntools_wallet_register_styled_policy_row \
      "Change outputs" "Standard residual change retained" \
      "${output_count} explicit outputs planned"
  } | cntools_ui_table --separator $'\t' --widths "${policy_widths}" ||
    return 1
  printf '\n'

  if (( ${#CNTOOLS_CHANGE_OUTPUTS[@]} > 0 )); then
    cntools_ui_render_detail "Planned change outputs" || return 1
    {
      printf 'Output\tValue\n'
      for output_index in "${!CNTOOLS_CHANGE_OUTPUTS[@]}"; do
        output_value="$(cntools_wallet_format_lovelace \
          "${CNTOOLS_CHANGE_OUTPUT_LOVELACE[output_index]}")"
        if (( CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS[output_index] > 0 )); then
          output_value+=" · ${CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS[output_index]} native assets"
        fi
        cntools_wallet_register_styled_row \
          "${CNTOOLS_CHANGE_OUTPUT_TYPES[output_index]}" \
          "${output_value}" number
      done
    } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
    printf '\n'
  fi

  cntools_ui_render_detail "Required witnesses" || return 1
  {
    printf 'Witness\tSigning method\n'
    cntools_wallet_register_styled_row "Payment key" "${payment_method}" accent
    cntools_wallet_register_styled_row "Stake key" "${stake_method}" accent
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == "deregister" ]]; then
    cntools_ui_render_status warn \
      "De-registering ends stake-pool and DRep delegation. Lingering rewards earned but not yet credited or paid out will be forfeited."
    printf '\n'
    cntools_ui_render_status info \
      "The stake deposit is refunded by the ledger. Cardano CLI balances the selected inputs, refund, fee, planned outputs, and remaining change back to this wallet's base address."
  else
    cntools_ui_render_status info \
      "Only the selected base and payment UTxOs are used. Planned outputs and remaining change return to this wallet's base address."
  fi
}

cntools_wallet_register_workflow_choose_into() {
  local _cntools_output_name="${1:-}"
  local selected=""
  local status=0
  local -a options=(
    "Create unsigned package  ·  sign later or on an offline system"
  )

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if [[ "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" == "Y" ]]; then
    options+=(
      "Create and sign  ·  keep a complete package for later submission"
      "Create, sign, and submit  ·  complete the ${CNTOOLS_WALLET_REGISTER_NOUN} now"
    )
  fi
  if cntools_ui_choose selected \
      "Select ${CNTOOLS_WALLET_REGISTER_NOUN} workflow…" \
      "${options[@]}"; then
    status=0
  else
    status=$?
  fi
  (( status == 0 )) || return "${status}"
  case "${selected}" in
    "${options[0]}") _cntools_output_ref="package" ;;
    "${options[1]:-__missing__}") _cntools_output_ref="sign" ;;
    "${options[2]:-__missing__}") _cntools_output_ref="submit" ;;
    *) return 2 ;;
  esac
  cntools_wallet_register_log CHOICE \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} workflow selected wallet=${CNTOOLS_WALLET_REGISTER_WALLET} workflow=${_cntools_output_ref}"
}

cntools_wallet_register_default_output_into() {
  local _cntools_output_name="${1:-}"
  local suffix="${2:-stake-registration}"
  local stem="${CNTOOLS_WALLET_REGISTER_WALLET//[^A-Za-z0-9._-]/-}"
  local candidate=""
  local index=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${suffix}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ -n "${stem}" ]] || stem="wallet"
  candidate="${PWD%/}/${stem}.${suffix}.json"
  while [[ -e "${candidate}" || -L "${candidate}" ]]; do
    index=$((index + 1))
    (( index <= 999 )) || return 1
    candidate="${PWD%/}/${stem}.${suffix}.${index}.json"
  done
  _cntools_output_ref="${candidate}"
}

cntools_wallet_register_prompt_output_into() {
  local _cntools_output_name="${1:-}"
  local default_output="${2:-}"
  local kind="${3:-unsigned}"
  local entered=""
  local normalized=""
  local feedback=""
  local status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     -n "${default_output}" ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_ui_action_begin \
      "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
    cntools_ui_render_status info \
      "Choose a new ${kind} transaction-package filename. Existing files are never replaced."
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_input entered "Transaction package" "${default_output}"; then
      status=0
    else
      status=$?
    fi
    (( status == 0 )) || return "${status}"
    [[ -n "${entered}" ]] || entered="${default_output}"
    if ! cntools_transaction_ui_normalize_path_into normalized "${entered}" ||
       ! cntools_transaction_output_path_safe "${normalized}"; then
      cntools_wallet_register_log CHOICE \
        "unsafe stake ${CNTOOLS_WALLET_REGISTER_NOUN} output path rejected"
      feedback="Choose a new filename in an owned writable directory protected from group or public writes."
      continue
    fi
    _cntools_output_ref="${normalized}"
    cntools_transaction_ui_log_path \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} ${kind} output selected" \
      "${normalized}"
    return 0
  done
}

cntools_wallet_register_render_outputs() {
  local unsigned_file="${1:-}"
  local signed_file="${2:-}"
  local widths=""

  cntools_wallet_register_table_widths_into widths 22 || return 1
  cntools_ui_render_detail "Transaction artifacts" || return 1
  {
    printf 'Artifact\tPath\n'
    cntools_wallet_register_styled_row \
      "Unsigned package" "${unsigned_file}" identifier
    if [[ -n "${signed_file}" ]]; then
      cntools_wallet_register_styled_row \
        "Signed package" "${signed_file}" identifier
    fi
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'
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

cntools_wallet_register_publish_unsigned() {
  local staged_package="${1:-}"
  local output_file="${2:-}"

  cntools_transaction_publish "${staged_package}" "${output_file}" || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  }
  cntools_wallet_register_log TRANSACTION \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} unsigned package saved wallet=${CNTOOLS_WALLET_REGISTER_WALLET} file=${output_file}"
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

cntools_wallet_register_submit() {
  local signed_package="${1:-}"
  local backend=""
  local input_kind=""
  local transaction_id=""
  local signed_file=""
  local status=0

  cntools_transaction_submit_reset
  cntools_transaction_package_reset_loaded
  if ! cntools_transaction_submit_input_prepare "${signed_package}"; then
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  fi
  input_kind="${CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND}"
  transaction_id="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  signed_file="${CNTOOLS_TRANSACTION_SIGNED_FILE}"
  cntools_transaction_ui_submission_backend_into backend || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  }

  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  cntools_transaction_ui_render_submit_review \
    "${backend}" "${input_kind}" "${transaction_id}" "${signed_file}" || {
      cntools_wallet_register_set_error \
        "The final transaction review could not be displayed safely."
      return 1
    }
  if cntools_ui_confirm \
      "Submit stake ${CNTOOLS_WALLET_REGISTER_NOUN} ${transaction_id:0:16}… using ${backend}?"; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} submission declined id=${transaction_id} backend=${backend}"
    return 4
  elif (( status != 0 )); then
    return "${status}"
  fi
  cntools_wallet_register_log CHOICE \
    "stake ${CNTOOLS_WALLET_REGISTER_NOUN} submission confirmed id=${transaction_id} backend=${backend}"
  if cntools_ui_spin_function \
      "Submitting stake ${CNTOOLS_WALLET_REGISTER_NOUN}…" \
      cntools_transaction_ui_submit_selected \
      "${backend}" "${signed_file}" "${transaction_id}"; then
    return 0
  fi
  CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
  return 1
}

cntools_wallet_action_stake_lifecycle() {
  local selected_index=""
  local wallet_directory=""
  local wallet_name=""
  local workflow=""
  local staged_package=""
  local unsigned_default=""
  local unsigned_file=""
  local signed_default=""
  local signed_file=""
  local collect_status=0
  local status=0

  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  if ! cntools_transaction_require_cli; then
    cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if ! cntools_wallet_catalog_build; then
    cntools_ui_render_status error \
      "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  if (( ${#CNTOOLS_WALLET_NAMES[@]} == 0 )); then
    cntools_ui_render_status warn \
      "No wallets are available to ${CNTOOLS_WALLET_REGISTER_VERB}."
    cntools_ui_wait
    return 0
  fi
  if cntools_wallet_choose selected_index; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} wallet selection cancelled"
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  wallet_directory="${CNTOOLS_WALLET_PATHS[selected_index]}"
  wallet_name="${CNTOOLS_WALLET_NAMES[selected_index]}"
  if ! cntools_wallet_register_prepare_wallet \
      "${wallet_directory}" "${wallet_name}"; then
    cntools_ui_action_begin \
      "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
    cntools_ui_render_status error "${CNTOOLS_WALLET_REGISTER_ERROR}"
    cntools_ui_wait
    return 1
  fi

  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  if cntools_ui_spin_function \
      "Checking stake state, rewards, UTxOs, and protocol parameters…" \
      cntools_wallet_register_collect; then
    collect_status=0
  else
    collect_status=$?
  fi
  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  if (( collect_status != 0 )); then
    cntools_wallet_register_render_collect_error "${collect_status}"
    cntools_ui_wait
    [[ "${collect_status}" == "4" || "${collect_status}" == "7" ]] &&
      return 0
    return 1
  fi
  cntools_wallet_register_render_plan || return 1
  if cntools_wallet_register_workflow_choose_into workflow; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} workflow selection cancelled wallet=${wallet_name}"
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi

  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  cntools_wallet_register_render_plan || return 1
  if cntools_ui_confirm \
      "Build this stake ${CNTOOLS_WALLET_REGISTER_NOUN} transaction?"; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} build declined wallet=${wallet_name}"
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi

  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  if cntools_ui_spin_function \
      "Building stake ${CNTOOLS_WALLET_REGISTER_NOUN} transaction…" \
      cntools_wallet_register_build_package_into staged_package; then
    status=0
  else
    status=$?
  fi
  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_REGISTER_ERROR:-The transaction could not be built. See ${CNTOOLS_LOG}.}"
    cntools_ui_wait
    return "${status}"
  fi
  if ! cntools_transaction_ui_render_package_review "${staged_package}"; then
    cntools_ui_render_status error \
      "The generated transaction could not be reviewed safely. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  if cntools_ui_confirm "Keep this reviewed transaction package?"; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} package discarded after review wallet=${wallet_name}"
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi

  cntools_wallet_register_default_output_into \
    unsigned_default "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 1
  if cntools_wallet_register_prompt_output_into \
      unsigned_file "${unsigned_default}" unsigned; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} output selection cancelled wallet=${wallet_name}"
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  if ! cntools_wallet_register_publish_unsigned \
      "${staged_package}" "${unsigned_file}"; then
    cntools_ui_action_begin \
      "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
    cntools_ui_render_status error "${CNTOOLS_WALLET_REGISTER_ERROR}"
    cntools_ui_wait
    return 1
  fi

  if [[ "${workflow}" == "package" ]]; then
    cntools_ui_action_begin \
      "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
    cntools_ui_render_status success \
      "The unsigned stake ${CNTOOLS_WALLET_REGISTER_NOUN} package is ready. Use Transaction → Sign on each signing system, then Transaction → Submit from an online system."
    cntools_wallet_register_render_outputs "${unsigned_file}" ""
    cntools_ui_wait
    return 0
  fi

  cntools_transaction_default_output_into \
    signed_default "${unsigned_file}" signed || return 1
  if cntools_wallet_register_prompt_output_into \
      signed_file "${signed_default}" signed; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} signing cancelled wallet=${wallet_name}"
    cntools_ui_action_begin \
      "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
    cntools_ui_render_status success \
      "The unsigned package was kept and can be signed later."
    cntools_wallet_register_render_outputs "${unsigned_file}" ""
    cntools_ui_wait
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi

  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  cntools_transaction_ui_render_package_review "${unsigned_file}" || return 1
  cntools_wallet_register_render_outputs "${unsigned_file}" "${signed_file}" ||
    return 1
  if cntools_ui_confirm \
      "Sign this stake ${CNTOOLS_WALLET_REGISTER_NOUN} with the wallet's payment and stake keys?"; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_wallet_register_log CHOICE \
      "stake ${CNTOOLS_WALLET_REGISTER_NOUN} signing declined wallet=${wallet_name}"
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  if cntools_ui_spin_function \
      "Signing stake ${CNTOOLS_WALLET_REGISTER_NOUN}…" \
      cntools_wallet_register_sign "${unsigned_file}" "${signed_file}"; then
    status=0
  else
    status=$?
  fi
  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_REGISTER_ERROR:-Signing failed. See ${CNTOOLS_LOG}.}"
    cntools_wallet_register_render_outputs "${unsigned_file}" ""
    cntools_ui_wait
    return "${status}"
  fi
  if [[ "${workflow}" == "sign" ]]; then
    cntools_ui_render_status success \
      "The stake ${CNTOOLS_WALLET_REGISTER_NOUN} package is fully signed and ready for submission."
    cntools_wallet_register_render_outputs "${unsigned_file}" "${signed_file}"
    cntools_ui_wait
    return 0
  fi

  if cntools_wallet_register_submit "${signed_file}"; then
    status=0
  else
    status=$?
  fi
  cntools_ui_action_begin \
    "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
  if (( status == 4 )); then
    cntools_ui_render_status info \
      "Submission was cancelled. Both transaction packages were kept."
    cntools_wallet_register_render_outputs "${unsigned_file}" "${signed_file}"
    cntools_ui_wait
    return 0
  elif (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_REGISTER_ERROR:-Submission failed. See ${CNTOOLS_LOG}.}"
    cntools_wallet_register_render_outputs "${unsigned_file}" "${signed_file}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_ui_render_status success \
    "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE:-Stake ${CNTOOLS_WALLET_REGISTER_NOUN} accepted.}"
  cntools_ui_render_field \
    "Transaction ID" "${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_ui_render_field \
    "Backend" "${CNTOOLS_TRANSACTION_SUBMIT_BACKEND}"
  cntools_wallet_register_render_outputs "${unsigned_file}" "${signed_file}"
  cntools_ui_wait
}

cntools_wallet_action_register() {
  cntools_wallet_register_operation_set register || return 1
  cntools_wallet_action_stake_lifecycle
}

cntools_wallet_action_deregister() {
  cntools_wallet_register_operation_set deregister || return 1
  cntools_wallet_action_stake_lifecycle
}
