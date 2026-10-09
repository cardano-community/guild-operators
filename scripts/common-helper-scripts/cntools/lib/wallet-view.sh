#!/usr/bin/env bash
# Wallet List/Show presentation and Show workflow.
# shellcheck disable=SC2034

cntools_wallet_identity_rows() {
  local wallet_name="${1:-Unavailable}"
  local wallet_type="${2:-Unavailable}"
  local key_protection="${3:-Unavailable}"
  local stake_registration="${4:-}"
  local derivation_path="${5:-}"
  local protection_role=""
  local registration_role=""

  protection_role="$(cntools_text_status_role "${key_protection}")" || return 1

  cntools_table_row "Wallet detail" "Value" || return 1
  cntools_table_wrapped_pair \
    "Name" "${wallet_name}" 16 identifier || return 1
  cntools_table_wrapped_pair \
    "Type" "${wallet_type}" 16 accent || return 1
  cntools_table_wrapped_pair \
    "Key protection" "${key_protection}" 16 "${protection_role}" || return 1
  if [[ -n "${stake_registration}" ]]; then
    registration_role="$(cntools_text_status_role \
      "${stake_registration}")" || return 1
    cntools_table_wrapped_pair \
      "Stake registration" "${stake_registration}" 20 \
      "${registration_role}" || return 1
  fi
  if [[ -n "${derivation_path}" ]]; then
    cntools_table_wrapped_pair \
      "Derivation path" "${derivation_path}" 20 identifier || return 1
  fi
}


cntools_wallet_render_identity_table() {
  cntools_wallet_render_rows_table \
    "Wallet" cntools_wallet_identity_rows "$@"
}


cntools_wallet_address_rows() {
  local base_address="${1:-Not available}"
  local payment_address="${2:-Not available}"
  local reward_address="${3:-Not available}"

  cntools_table_row "Address type" "Address" || return 1
  if [[ "${base_address}" != "Not available" ]]; then
    cntools_table_wrapped_pair \
      "Base" "${base_address}" 15 address || return 1
  fi
  if [[ "${payment_address}" != "Not available" ]]; then
    cntools_table_wrapped_pair \
      "Payment" "${payment_address}" 15 address || return 1
  fi
  if [[ "${reward_address}" != "Not available" ]]; then
    cntools_table_wrapped_pair \
      "Stake / reward" "${reward_address}" 15 address || return 1
  fi
  if [[ "${base_address}" == "Not available" &&
        "${payment_address}" == "Not available" &&
        "${reward_address}" == "Not available" ]]; then
    cntools_table_wrapped_pair \
      "Available" "None" 15 muted || return 1
  fi
}


cntools_wallet_render_address_table() {
  cntools_wallet_render_rows_table \
    "Addresses" cntools_wallet_address_rows "$@"
}


cntools_wallet_credential_rows() {
  local wallet_directory="${1:-}"
  local kind=""
  local label=""
  local value=""
  local status=0
  local count=0
  local -a labels=()
  local -a values=()

  declare -F cntools_wallet_id_read_credential >/dev/null 2>&1 || return 0
  for kind in \
    payment stake ms-payment ms-stake script-payment script-stake; do
    value=""
    if cntools_wallet_id_read_credential \
        "${wallet_directory}" "${kind}" value; then
      status=0
    else
      status=$?
    fi
    case "${kind}" in
      payment) label="Payment" ;;
      stake) label="Stake" ;;
      ms-payment) label="MultiSig payment" ;;
      ms-stake) label="MultiSig stake" ;;
      script-payment) label="Payment script" ;;
      script-stake) label="Stake script" ;;
    esac
    case "${status}" in
      0)
        [[ "${value}" =~ ^[0-9a-fA-F]{56}$ ]] || return 1
        labels+=("${label}")
        values+=("${value,,}")
        ;;
      1) ;;
      2)
        labels+=("${label}")
        values+=("Invalid credential file")
        ;;
      *) return "${status}" ;;
    esac
  done
  (( ${#labels[@]} > 0 )) || return 0
  cntools_table_row "Credential" "Hash (hex)" || return 1
  for (( count = 0; count < ${#labels[@]}; count++ )); do
    local credential_role="credential"
    [[ "${values[count]}" != "Invalid credential file" ]] ||
      credential_role="danger"
    cntools_table_wrapped_pair \
      "${labels[count]}" "${values[count]}" 20 \
      "${credential_role}" || return 1
  done
}


cntools_wallet_render_credential_table() {
  local wallet_directory="${1:-}"
  local rows_file=""
  local row_count=0

  cntools_wallet_write_rows_file \
    rows_file cntools_wallet_credential_rows "${wallet_directory}" || return $?
  cntools_wallet_file_row_count_into row_count "${rows_file}" || return 1
  (( row_count > 0 )) || return 0
  cntools_wallet_render_table_file "Credentials" "${rows_file}"
}


cntools_wallet_balance_rows() {
  local has_base="${1:-Y}"
  local has_payment="${2:-Y}"
  local has_reward="${3:-Y}"
  local inclusive_total=""
  local utxo_count="Unavailable"
  local formatted_count="Unavailable"
  local token_count="Unavailable"
  local formatted_token_count="Unavailable"

  if [[ "${CNTOOLS_WALLET_TOTAL_LOVELACE}" =~ ^[0-9]+$ &&
        "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]]; then
    inclusive_total="$(cntools_uint_add \
      "${CNTOOLS_WALLET_TOTAL_LOVELACE}" \
      "${CNTOOLS_WALLET_REWARD_LOVELACE}")" || return 1
  fi
  [[ ! "${CNTOOLS_WALLET_UTXO_COUNT}" =~ ^[0-9]+$ ]] ||
    utxo_count="${CNTOOLS_WALLET_UTXO_COUNT}"
  if [[ "${utxo_count}" =~ ^[0-9]+$ ]] &&
     declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into formatted_count "${utxo_count}" || return 1
  else
    formatted_count="${utxo_count}"
  fi
  [[ ! "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[0-9]+$ ]] ||
    token_count="${CNTOOLS_WALLET_ASSET_COUNT}"
  if [[ "${token_count}" =~ ^[0-9]+$ ]] &&
     declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into \
      formatted_token_count "${token_count}" || return 1
  else
    formatted_token_count="${token_count}"
  fi
  cntools_table_row "Balance" "Value" || return 1
  if [[ "${has_base}" == "Y" ]]; then
    cntools_table_wrapped_pair "Base UTxO" \
      "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_BASE_LOVELACE}")" \
      22 "$(cntools_text_number_role \
        "${CNTOOLS_WALLET_BASE_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_payment}" == "Y" ]]; then
    cntools_table_wrapped_pair "Payment UTxO" \
      "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_PAYMENT_LOVELACE}")" \
      22 "$(cntools_text_number_role \
        "${CNTOOLS_WALLET_PAYMENT_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_base}" == "Y" || "${has_payment}" == "Y" ]]; then
    cntools_table_wrapped_pair "Total UTxO" \
      "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_TOTAL_LOVELACE}")" \
      22 "$(cntools_text_number_role \
        "${CNTOOLS_WALLET_TOTAL_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_reward}" == "Y" ]]; then
    cntools_table_wrapped_pair "Rewards" \
      "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_REWARD_LOVELACE}")" \
      22 "$(cntools_text_number_role \
        "${CNTOOLS_WALLET_REWARD_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_reward}" == "Y" &&
        ( "${has_base}" == "Y" || "${has_payment}" == "Y" ) ]]; then
    cntools_table_wrapped_pair "Total incl. rewards" \
      "$(cntools_number_format_lovelace "${inclusive_total}")" \
      22 "$(cntools_text_number_role "${inclusive_total}")" || return 1
  fi
  if [[ "${has_base}" == "Y" || "${has_payment}" == "Y" ]]; then
    cntools_table_wrapped_pair \
      "UTxO count" "${formatted_count}" 22 \
      "$(cntools_text_number_role "${utxo_count}")" ||
      return 1
    cntools_table_wrapped_pair \
      "Native assets" "${formatted_token_count}" 22 \
      "$(cntools_text_number_role "${token_count}")" ||
      return 1
  fi
}


cntools_wallet_render_balance_table() {
  cntools_wallet_render_rows_table \
    "Balances" cntools_wallet_balance_rows "$@"
}


cntools_wallet_drep_target() {
  case "${1:-}" in
    alwaysAbstain|drep_always_abstain) printf 'Always abstain\n' ;;
    alwaysNoConfidence|drep_always_no_confidence)
      printf 'Always no confidence\n'
      ;;
    *) printf '%s\n' "${1:-—}" ;;
  esac
}


cntools_wallet_delegation_rows() {
  local pool_status="Unavailable"
  local pool_target="—"
  local drep_status="Unavailable"
  local drep_target="—"
  local pool_role="muted"
  local drep_role="muted"

  if [[ "${CNTOOLS_WALLET_REGISTERED:-unknown}" != "unknown" ]]; then
    if [[ -n "${CNTOOLS_WALLET_POOL_DELEGATION:-}" ]]; then
      pool_status="Delegated"
      pool_target="${CNTOOLS_WALLET_POOL_DELEGATION}"
    else
      pool_status="Not delegated"
    fi
    if [[ -n "${CNTOOLS_WALLET_DREP_DELEGATION:-}" ]]; then
      drep_status="Delegated"
      drep_target="$(cntools_wallet_drep_target \
        "${CNTOOLS_WALLET_DREP_DELEGATION}")"
    else
      drep_status="Not delegated"
    fi
  fi
  cntools_table_row "Delegation" "Status / target" || return 1
  if [[ "${pool_status}" == "Delegated" ]]; then
    pool_role="success"
    cntools_table_wrapped_pair \
      "Stake pool delegation" "Delegated · ${pool_target}" 24 \
      "${pool_role}" || return 1
  else
    pool_role="$(cntools_text_status_role "${pool_status}")" || return 1
    cntools_table_wrapped_pair \
      "Stake pool delegation" "${pool_status}" 24 "${pool_role}" || return 1
  fi
  if [[ "${drep_status}" == "Delegated" ]]; then
    drep_role="success"
    cntools_table_wrapped_pair \
      "DRep delegation" "Delegated · ${drep_target}" 24 "${drep_role}"
  else
    drep_role="$(cntools_text_status_role "${drep_status}")" || return 1
    cntools_table_wrapped_pair \
      "DRep delegation" "${drep_status}" 24 "${drep_role}"
  fi
}


cntools_wallet_render_delegation_table() {
  cntools_wallet_render_rows_table \
    "Delegation" cntools_wallet_delegation_rows
}


cntools_wallet_render_query() {
  local has_base="${1:-Y}"
  local has_payment="${2:-Y}"
  local has_reward="${3:-Y}"
  local asset_view="${4:-detailed}"
  local level="info"

  [[ "${asset_view}" == "simple" ||
     "${asset_view}" == "detailed" ||
     "${asset_view}" == "skip" ]] || return 2
  case "${CNTOOLS_WALLET_QUERY_STATUS}" in
    available) level="success" ;;
    partial) level="warn" ;;
    unavailable) level="error" ;;
    offline|unsupported) level="warn" ;;
  esac
  cntools_ui_render_status "${level}" "${CNTOOLS_WALLET_QUERY_MESSAGE}"
  if [[ "${has_base}" == "Y" || "${has_payment}" == "Y" ||
        "${has_reward}" == "Y" ]]; then
    cntools_wallet_render_balance_table \
      "${has_base}" "${has_payment}" "${has_reward}" || return 1
  fi
  if [[ "${has_reward}" == "Y" ]]; then
    cntools_wallet_render_delegation_table || return 1
  fi
  if [[ "${asset_view}" != "skip" &&
        ( "${has_base}" == "Y" || "${has_payment}" == "Y" ) ]]; then
    cntools_wallet_render_asset_details_table "${asset_view}" || return 1
  fi
}


cntools_wallet_choose_asset_view() {
  local _cntools_output_name="${1:-}"
  local _cntools_selected=""
  local _cntools_status=0
  local _cntools_index=0
  local -a _cntools_rows=(
    "Simple    · Essential holdings and identifiers"
    "Detailed  · All available token metadata"
    "Skip      · Do not print native-asset details"
  )
  local -a _cntools_ids=(simple detailed skip)

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if cntools_ui_choose _cntools_selected \
      "Select native-asset view…" "${_cntools_rows[@]}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  (( _cntools_status == 0 )) || return "${_cntools_status}"
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_rows[@]};
         _cntools_index++ )); do
    if [[ "${_cntools_selected}" == "${_cntools_rows[_cntools_index]}" ]]; then
      _cntools_output_ref="${_cntools_ids[_cntools_index]}"
      cntools_wallet_log CHOICE \
        "native-asset view selected view=${_cntools_output_ref}"
      return 0
    fi
  done
  cntools_wallet_log ERROR "Native-asset view selector returned an unknown row"
  return 2
}


cntools_wallet_action_show_impl() {
  local selected_index=""
  local selector_status=0
  local asset_selector_status=0
  local asset_view="simple"
  local wallet_directory=""
  local wallet_type=""
  local wallet_protection=""
  local base_address=""
  local payment_address=""
  local reward_address=""
  local query_base=""
  local query_payment=""
  local query_reward=""
  local spinner_title=""
  local derivation_path=""
  local registration=""
  local has_base="N"
  local has_payment="N"
  local has_reward="N"

  cntools_ui_action_begin "Show" "/ Wallet / Show"
  if ! cntools_wallet_catalog_build; then
    cntools_ui_render_status error \
      "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  if (( ${#CNTOOLS_WALLET_NAMES[@]} == 0 )); then
    cntools_ui_render_status warn "No wallets are available."
    cntools_ui_wait
    return 0
  fi
  if cntools_wallet_choose selected_index; then
    selector_status=0
  else
    selector_status=$?
  fi
  if (( selector_status == 1 )); then
    cntools_wallet_log CHOICE "wallet selection cancelled"
    cntools_gum_clear
    return 0
  elif (( selector_status != 0 )); then
    cntools_wallet_log ERROR \
      "wallet selection failed status=${selector_status}"
    return "${selector_status}"
  fi

  wallet_directory="${CNTOOLS_WALLET_PATHS[selected_index]}"
  CNTOOLS_WALLET_SELECTED_NAME="${CNTOOLS_WALLET_NAMES[selected_index]}"
  if ! cntools_wallet_prepare_selected_material "${wallet_directory}"; then
    cntools_wallet_log WARN \
      "Some public wallet material could not be prepared wallet=${CNTOOLS_WALLET_SELECTED_NAME}"
  fi
  wallet_type="$(cntools_wallet_type "${wallet_directory}")" || return 1
  wallet_protection="$(cntools_wallet_protection "${wallet_directory}")" ||
    return 1
  CNTOOLS_WALLET_TYPES[selected_index]="${wallet_type}"
  CNTOOLS_WALLET_PROTECTIONS[selected_index]="${wallet_protection}"
  if [[ "${wallet_type}" == "Mnemonic" ]]; then
    cntools_wallet_read_derivation_path \
      "${wallet_directory}" derivation_path || derivation_path=""
  fi
  cntools_wallet_display_address "${wallet_directory}" base base_address || return 1
  cntools_wallet_display_address "${wallet_directory}" payment payment_address || return 1
  cntools_wallet_display_address "${wallet_directory}" reward reward_address || return 1
  [[ "${base_address}" == addr* ]] && query_base="${base_address}"
  [[ "${payment_address}" == addr* ]] && query_payment="${payment_address}"
  [[ "${reward_address}" == stake* ]] && query_reward="${reward_address}"
  [[ -z "${query_base}" ]] || has_base="Y"
  [[ -z "${query_payment}" ]] || has_payment="Y"
  [[ -z "${query_reward}" ]] || has_reward="Y"

  case "${CNTOOLS_MODE:-offline}" in
    light) spinner_title="Fetching wallet details from Koios…" ;;
    local)
      if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" ]]; then
        spinner_title="Fetching wallet details from ${CNTOOLS_IMPLEMENTATION_NAME:-the local node}"
        if [[ "${CNTOOLS_KOIOS_ENABLED:-Y}" == "Y" ]]; then
          spinner_title+=" and token metadata from Koios…"
        else
          spinner_title+="…"
        fi
      fi
      ;;
  esac
  cntools_ui_action_begin "Show" "/ Wallet / Show"
  if [[ -n "${spinner_title}" ]]; then
    if ! cntools_ui_spin_function "${spinner_title}" cntools_wallet_query_details \
        "${query_base}" "${query_payment}" "${query_reward}"; then
      cntools_ui_render_status error \
        "Wallet details could not be prepared safely. See ${CNTOOLS_LOG}."
      cntools_ui_wait
      return 1
    fi
  else
    cntools_wallet_query_details \
      "${query_base}" "${query_payment}" "${query_reward}"
  fi

  if [[ "${has_reward}" == "Y" ]]; then
    case "${CNTOOLS_WALLET_REGISTERED:-unknown}" in
      yes) registration="Registered" ;;
      no) registration="Not registered" ;;
      *) registration="Unavailable" ;;
    esac
  fi

  cntools_ui_spin_function 'Checking optional delegation information from Koios…' cntools_wallet_delegation_info_collect || true
  cntools_ui_action_begin "Show" "/ Wallet / Show"
  cntools_wallet_render_identity_table \
    "${CNTOOLS_WALLET_SELECTED_NAME}" \
    "${wallet_type}" "${wallet_protection}" \
    "${registration}" "${derivation_path}" || return 1
  cntools_wallet_render_address_table \
    "${base_address}" "${payment_address}" "${reward_address}" || return 1
  cntools_wallet_render_credential_table "${wallet_directory}" || return 1
  cntools_wallet_render_query \
    "${has_base}" "${has_payment}" "${has_reward}" skip || return 1
  cntools_wallet_delegation_info_render || return 1
  if [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
    if cntools_wallet_choose_asset_view asset_view; then
      asset_selector_status=0
    else
      asset_selector_status=$?
    fi
    if (( asset_selector_status == 1 )); then
      cntools_wallet_log CHOICE "native-asset view selection cancelled"
      cntools_gum_clear
      return 0
    elif (( asset_selector_status != 0 )); then
      cntools_wallet_log ERROR \
        "native-asset view selection failed status=${asset_selector_status}"
      return "${asset_selector_status}"
    fi
    if [[ "${asset_view}" != "skip" ]]; then
      cntools_wallet_render_asset_details_table "${asset_view}" || return 1
    fi
  fi
  cntools_ui_wait
}


cntools_wallet_action_show() {
  local status=0

  if cntools_wallet_action_show_impl; then
    status=0
  else
    status=$?
  fi
  cntools_wallet_query_cleanup || true
  cntools_wallet_cleanup_material || true
  return "${status}"
}


cntools_wallet_display_address() {
  local _cntools_wallet_directory="${1:-}"
  local _cntools_kind="${2:-}"
  local _cntools_output_name="${3:-}"
  local _cntools_display_address_value=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if cntools_wallet_read_address \
      "${_cntools_wallet_directory}" "${_cntools_kind}" \
      _cntools_display_address_value; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  case "${_cntools_status}" in
    0) _cntools_output_ref="${_cntools_display_address_value}" ;;
    1) _cntools_output_ref="Not available" ;;
    2)
      _cntools_output_ref="Invalid address file"
      cntools_wallet_log ERROR \
        "Invalid ${_cntools_kind} address file in wallet=${CNTOOLS_WALLET_SELECTED_NAME}"
      ;;
    *) return "${_cntools_status}" ;;
  esac
}


cntools_wallet_render_table() {
  local title="${1:-Details}"

  cntools_ui_render_detail "${title}" || return 1
  cntools_ui_table --separator $'\t' || return 1
}


cntools_wallet_render_table_file() {
  local title="${1:-Details}"
  local source_file="${2:-}"

  [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 2
  cntools_ui_render_detail "${title}" || return 1
  cntools_ui_table --separator $'\t' < "${source_file}" || return 1
}


cntools_wallet_write_rows_file() {
  local _cntools_output_name="${1:-}"
  local _cntools_producer="${2:-}"
  local _cntools_rows_file=""
  local _cntools_status=0
  local CNTOOLS_TABLE_RENDER_WIDTH=""

  shift 2 || return 2
  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_producer}" =~ ^cntools_wallet_[A-Za-z0-9_]+_rows$ ]] ||
    return 2
  declare -F "${_cntools_producer}" >/dev/null 2>&1 || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_query_temp_file _cntools_rows_file || return 1
  CNTOOLS_TABLE_RENDER_WIDTH="$(cntools_table_width)" || return 1
  if "${_cntools_producer}" "$@" > "${_cntools_rows_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  (( _cntools_status == 0 )) || return "${_cntools_status}"
  _cntools_output_ref="${_cntools_rows_file}"
}


cntools_wallet_render_rows_table() {
  local title="${1:-Details}"
  local producer="${2:-}"
  local rows_file=""

  shift 2 || return 2
  cntools_wallet_write_rows_file rows_file "${producer}" "$@" || return $?
  cntools_wallet_render_table_file "${title}" "${rows_file}"
}
