#!/usr/bin/env bash
# Gum interaction and presentation for standard CIP-1852 hardware wallets.
# Loaded after wallet-hardware.sh and wallet-create-ui.sh.

cntools_wallet_hardware_screen_begin() {
  cntools_gum_clear
  cntools_ui_action_begin "HW Wallet" "/ Wallet / Import / HW Wallet"
}

cntools_wallet_hardware_prompt_name_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_candidate=""
  local _cntools_feedback=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_wallet_hardware_screen_begin
    cntools_ui_render_status info \
      "Import standard CIP-1852 payment and stake keys from a hardware wallet."
    [[ -z "${_cntools_feedback}" ]] ||
      cntools_ui_render_status warn "${_cntools_feedback}"
    if cntools_ui_input _cntools_candidate "Wallet name"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    if ! cntools_wallet_create_name_valid "${_cntools_candidate}"; then
      _cntools_feedback="Use 1–64 letters, numbers, dots, underscores, or hyphens; start with a letter or number."
      cntools_wallet_hardware_log CHOICE \
        "invalid hardware wallet name rejected"
      continue
    fi
    if ! cntools_wallet_create_target_available "${_cntools_candidate}"; then
      _cntools_feedback="A wallet or filesystem entry named ${_cntools_candidate} already exists. Choose another name."
      cntools_wallet_hardware_log CHOICE \
        "duplicate hardware wallet name rejected wallet=${_cntools_candidate}"
      continue
    fi
    _cntools_output_ref="${_cntools_candidate}"
    cntools_wallet_hardware_log CHOICE \
      "hardware wallet name selected wallet=${_cntools_candidate}"
    return 0
  done
}

cntools_wallet_hardware_prompt_index_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_prompt="${2:-Index}"
  local _cntools_input=""
  local _cntools_value=""
  local _cntools_feedback=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_wallet_hardware_screen_begin
    cntools_ui_render_status info \
      "Leave blank for 0. Supported values are 0 through 2,147,483,647."
    [[ -z "${_cntools_feedback}" ]] ||
      cntools_ui_render_status warn "${_cntools_feedback}"
    if cntools_ui_input _cntools_input "${_cntools_prompt}" "0"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    if cntools_wallet_hardware_index_into \
        _cntools_value "${_cntools_input}"; then
      _cntools_output_ref="${_cntools_value}"
      return 0
    fi
    _cntools_feedback="Enter a whole number between 0 and 2,147,483,647."
    cntools_wallet_hardware_log CHOICE \
      "invalid hardware derivation index rejected field=${_cntools_prompt// /_}"
  done
}

cntools_wallet_hardware_collect_settings() {
  local _cntools_name_output="${1:-}"
  local _cntools_account_output="${2:-}"
  local _cntools_key_output="${3:-}"
  local _cntools_name=""
  local _cntools_account=""
  local _cntools_key_index=""
  local _cntools_status=0

  [[ "${_cntools_name_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_account_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_key_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_name_ref="${_cntools_name_output}"
  local -n _cntools_account_ref="${_cntools_account_output}"
  local -n _cntools_key_ref="${_cntools_key_output}"
  _cntools_name_ref=""
  _cntools_account_ref=""
  _cntools_key_ref=""
  if cntools_wallet_hardware_prompt_name_into _cntools_name; then
    :
  else
    _cntools_status=$?
    return "${_cntools_status}"
  fi
  if cntools_wallet_hardware_prompt_index_into \
      _cntools_account "Account number"; then
    :
  else
    _cntools_status=$?
    return "${_cntools_status}"
  fi
  if cntools_wallet_hardware_prompt_index_into \
      _cntools_key_index "Address key index"; then
    :
  else
    _cntools_status=$?
    return "${_cntools_status}"
  fi
  _cntools_name_ref="${_cntools_name}"
  _cntools_account_ref="${_cntools_account}"
  _cntools_key_ref="${_cntools_key_index}"
}

cntools_wallet_hardware_render_plan() {
  local name="${1:-}"
  local account="${2:-0}"
  local key_index="${3:-0}"
  local target=""
  local payment_path=""
  local stake_path=""
  local widths=""

  cntools_wallet_create_target_into target "${name}" || return 1
  cntools_wallet_hardware_path_into \
    payment_path 1852 "${account}" 0 "${key_index}" || return 1
  cntools_wallet_hardware_path_into \
    stake_path 1852 "${account}" 2 "${key_index}" || return 1
  cntools_wallet_create_table_widths_into widths 18 || return 1
  cntools_ui_render_detail "Hardware wallet" || return 1
  {
    printf 'Setting\tValue\n'
    cntools_wallet_create_styled_row "Name" "${name}" identifier
    cntools_wallet_create_styled_row "Type" "Hardware" accent
    cntools_wallet_create_styled_row \
      "Network" "${CNTOOLS_NETWORK:-Unavailable}" accent
    cntools_wallet_create_styled_row \
      "Hardware tool" "cardano-hw-cli ${CNTOOLS_WALLET_HARDWARE_VERSION}" value
    cntools_wallet_create_styled_row \
      "Payment path" "${payment_path}" identifier
    cntools_wallet_create_styled_row \
      "Stake path" "${stake_path}" identifier
    cntools_wallet_create_styled_row \
      "Wallet directory" "${target}" identifier
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'
}

cntools_wallet_hardware_render_result() {
  local directory="${1:-}"
  local name="${2:-}"
  local account="${3:-0}"
  local key_index="${4:-0}"
  local device="${5:-Connected hardware wallet}"
  local base_address=""
  local payment_address=""
  local reward_address=""
  local payment_credential=""
  local stake_credential=""
  local widths=""

  cntools_wallet_read_address "${directory}" base base_address &&
    cntools_wallet_read_address "${directory}" payment payment_address &&
    cntools_wallet_read_address "${directory}" reward reward_address &&
    cntools_wallet_id_read_credential \
      "${directory}" payment payment_credential &&
    cntools_wallet_id_read_credential \
      "${directory}" stake stake_credential || return 1
  cntools_wallet_create_table_widths_into widths 18 || return 1

  cntools_ui_render_detail "Wallet" || return 1
  {
    printf 'Wallet detail\tValue\n'
    cntools_wallet_create_styled_row "Name" "${name}" identifier
    cntools_wallet_create_styled_row "Type" "Hardware" accent
    cntools_wallet_create_styled_row "Device" "${device}" value
    cntools_wallet_create_styled_row \
      "Derivation" "1852H/1815H/${account}H/x/${key_index}" identifier
    cntools_wallet_create_styled_row \
      "Stake registration" "Not registered" warning
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'

  cntools_ui_render_detail "Addresses" || return 1
  {
    printf 'Address type\tAddress\n'
    cntools_wallet_create_styled_row "Base" "${base_address}" address
    cntools_wallet_create_styled_row "Payment" "${payment_address}" address
    cntools_wallet_create_styled_row \
      "Stake / reward" "${reward_address}" address
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'

  cntools_ui_render_detail "Credentials" || return 1
  {
    printf 'Credential type\tCredential\n'
    cntools_wallet_create_styled_row \
      "Payment" "${payment_credential}" credential
    cntools_wallet_create_styled_row \
      "Stake" "${stake_credential}" credential
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'
}

cntools_wallet_action_import_hardware() {
  local name=""
  local account=""
  local key_index=""
  local device=""
  local status=0

  cntools_wallet_hardware_reset_result
  cntools_wallet_hardware_screen_begin
  if ! cntools_wallet_create_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_CREATE_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if ! cntools_wallet_hardware_require; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_HARDWARE_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if cntools_wallet_hardware_collect_settings name account key_index; then
    :
  else
    status=$?
    if (( status == 1 )); then
      cntools_wallet_hardware_log CHOICE \
        "hardware wallet import cancelled during settings"
      cntools_gum_clear
      return 0
    fi
    cntools_wallet_hardware_log ERROR \
      "hardware wallet settings failed status=${status}"
    return "${status}"
  fi

  cntools_wallet_hardware_screen_begin
  if ! cntools_wallet_hardware_render_plan \
      "${name}" "${account}" "${key_index}"; then
    cntools_wallet_hardware_log ERROR \
      "hardware wallet plan rendering failed wallet=${name}"
    cntools_ui_render_status error \
      "The hardware wallet plan could not be displayed. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  cntools_ui_render_status info \
    "Only public keys and hardware signing references are stored. Private keys never leave the device."
  cntools_ui_render_status warn \
    "This imports standard CIP-1852 payment and stake keys only."
  if cntools_ui_confirm "Import this hardware wallet now?"; then
    :
  else
    status=$?
    if (( status == 1 )); then
      cntools_wallet_hardware_log CHOICE \
        "hardware wallet import declined wallet=${name}"
      cntools_gum_clear
      return 0
    fi
    return "${status}"
  fi

  cntools_wallet_hardware_screen_begin
  cntools_ui_render_status info \
    "Connect and unlock the hardware wallet. On Ledger, open the Cardano app; on Trezor, ensure its bridge is available."
  cntools_ui_render_status warn \
    "Verify the requested derivation paths on the device before approving them."
  if cntools_ui_confirm "The hardware wallet is ready"; then
    :
  else
    status=$?
    if (( status == 1 )); then
      cntools_wallet_hardware_log CHOICE \
        "hardware wallet import cancelled before device check wallet=${name}"
      cntools_gum_clear
      return 0
    fi
    return "${status}"
  fi

  if cntools_ui_spin_function \
      "Checking the connected hardware wallet…" \
      cntools_wallet_hardware_device_check; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )) &&
     [[ -n "${CNTOOLS_WALLET_HARDWARE_DEVICE}" ]]; then
    cntools_wallet_hardware_log WARN \
      "hardware device check completed but spinner failed status=${status}"
    status=0
  fi
  if (( status != 0 )); then
    [[ -n "${CNTOOLS_WALLET_HARDWARE_ERROR}" ]] ||
      cntools_wallet_hardware_log ERROR \
        "hardware device progress display failed status=${status}"
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_HARDWARE_ERROR:-The hardware wallet could not be reached.}"
    cntools_ui_wait
    return 1
  fi
  device="${CNTOOLS_WALLET_HARDWARE_DEVICE}"
  cntools_wallet_hardware_log CHOICE \
    "hardware wallet import confirmed wallet=${name} account=${account} key_index=${key_index}"
  if cntools_ui_spin_function \
      "Approve the payment and stake key export on the device…" \
      cntools_wallet_hardware_create \
      "${name}" "${account}" "${key_index}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )) &&
     [[ -n "${CNTOOLS_WALLET_CREATED_DIRECTORY}" &&
        -d "${CNTOOLS_WALLET_CREATED_DIRECTORY}" &&
        ! -L "${CNTOOLS_WALLET_CREATED_DIRECTORY}" ]]; then
    CNTOOLS_WALLET_CREATE_WARNING="The wallet was imported, but the progress display did not close cleanly."
    cntools_wallet_hardware_log WARN \
      "hardware wallet published but spinner failed status=${status} wallet=${name}"
    status=0
  fi
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_HARDWARE_ERROR:-Hardware wallet import failed. See ${CNTOOLS_LOG}.}"
    cntools_ui_wait
    return "${status}"
  fi

  cntools_wallet_hardware_screen_begin
  cntools_ui_render_status success \
    "Hardware wallet ${CNTOOLS_WALLET_CREATED_NAME} was imported successfully."
  cntools_wallet_hardware_render_result \
    "${CNTOOLS_WALLET_CREATED_DIRECTORY}" \
    "${CNTOOLS_WALLET_CREATED_NAME}" \
    "${CNTOOLS_WALLET_HARDWARE_ACCOUNT}" \
      "${CNTOOLS_WALLET_HARDWARE_KEY_INDEX}" "${device}" ||
    {
      cntools_wallet_hardware_log WARN \
        "hardware wallet result rendering failed wallet=${CNTOOLS_WALLET_CREATED_NAME}"
      cntools_ui_render_status warn \
        "The wallet was imported, but its result details could not be displayed."
    }
  [[ -z "${CNTOOLS_WALLET_CREATE_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_CREATE_WARNING}"
  cntools_ui_render_status warn \
    "Keep the hardware wallet recovery backup secure; CNTools cannot recover these keys."
  cntools_ui_wait
}
