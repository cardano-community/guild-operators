#!/usr/bin/env bash
# Gum interaction and presentation for standard CLI wallet creation.
# Loaded after wallet-create.sh.

cntools_wallet_create_table_widths_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_label_width="${2:-18}"
  local _cntools_table_width=""
  local _cntools_value_width=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_table_width="$(cntools_ui_content_width 180 42)" || return 1
  _cntools_value_width=$((_cntools_table_width - _cntools_label_width - 7))
  (( _cntools_value_width >= 12 )) || return 1
  _cntools_output_ref="${_cntools_label_width},${_cntools_value_width}"
}

cntools_wallet_create_styled_row() {
  local label="${1:-}"
  local value="${2:-}"
  local role="${3:-value}"
  local styled=""

  cntools_theme_style_value_into styled "${role}" "${value}" || return 1
  printf '%s\t%s\n' "${label}" "${styled}"
}

cntools_wallet_create_render_plan() {
  local name="${1:-}"
  local target=""
  local widths=""

  cntools_wallet_create_target_into target "${name}" || return 1
  cntools_wallet_create_table_widths_into widths 18 || return 1
  cntools_ui_render_detail "New CLI wallet" || return 1
  {
    printf 'Setting\tValue\n'
    cntools_wallet_create_styled_row "Name" "${name}" identifier
    cntools_wallet_create_styled_row "Type" "CLI" accent
    cntools_wallet_create_styled_row \
      "Network" "${CNTOOLS_NETWORK:-Unavailable}" accent
    cntools_wallet_create_styled_row "Wallet directory" "${target}" identifier
    cntools_wallet_create_styled_row "Signing keys" \
      "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}, ${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" value
    cntools_wallet_create_styled_row "Verification keys" \
      "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}, ${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" value
    cntools_wallet_create_styled_row "Addresses" \
      "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}, ${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}, ${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" value
    cntools_wallet_create_styled_row "Credentials" \
      "${CNTOOLS_WALLET_PAY_CRED_FILENAME}, ${CNTOOLS_WALLET_STAKE_CRED_FILENAME}" value
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'
}

cntools_wallet_create_render_result() {
  local directory="${1:-}"
  local name="${2:-}"
  local base_address=""
  local payment_address=""
  local reward_address=""
  local payment_credential=""
  local stake_credential=""
  local widths=""

  if ! cntools_wallet_read_address "${directory}" base base_address ||
     ! cntools_wallet_read_address \
       "${directory}" payment payment_address ||
     ! cntools_wallet_read_address "${directory}" reward reward_address ||
     ! cntools_wallet_id_read_credential \
       "${directory}" payment payment_credential ||
     ! cntools_wallet_id_read_credential \
       "${directory}" stake stake_credential; then
    return 1
  fi
  cntools_wallet_create_table_widths_into widths 18 || return 1

  cntools_ui_render_detail "Wallet" || return 1
  {
    printf 'Wallet detail\tValue\n'
    cntools_wallet_create_styled_row "Name" "${name}" identifier
    cntools_wallet_create_styled_row "Type" "CLI" accent
    cntools_wallet_create_styled_row "Key protection" "Open" warning
    cntools_wallet_create_styled_row \
      "Stake registration" "Not registered" warning
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  printf '\n'

  cntools_ui_render_detail "Addresses" || return 1
  {
    printf 'Address type\tAddress\n'
    cntools_wallet_create_styled_row "Base" "${base_address}" address
    cntools_wallet_create_styled_row \
      "Payment" "${payment_address}" address
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

cntools_wallet_action_new_cli() {
  local name=""
  local input_status=0
  local confirm_status=0
  local create_status=0
  local feedback=""

  cntools_ui_action_begin "CLI" "/ Wallet / New / CLI"
  if ! cntools_wallet_create_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_CREATE_ERROR}"
    cntools_ui_wait
    return 1
  fi

  while true; do
    cntools_ui_action_begin "CLI" "/ Wallet / New / CLI"
    cntools_ui_render_status info \
      "Create a standard payment-and-stake wallet using Cardano CLI."
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_input name "Wallet name"; then
      input_status=0
    else
      input_status=$?
    fi
    if (( input_status == 1 )); then
      cntools_wallet_create_log CHOICE "CLI wallet creation cancelled at name"
      cntools_gum_clear
      return 0
    elif (( input_status != 0 )); then
      return "${input_status}"
    fi
    if ! cntools_wallet_create_name_valid "${name}"; then
      feedback="Use 1–64 letters, numbers, dots, underscores, or hyphens; start with a letter or number."
      cntools_wallet_create_log CHOICE "invalid CLI wallet name rejected"
      continue
    fi
    if ! cntools_wallet_create_target_available "${name}"; then
      feedback="A wallet or filesystem entry named ${name} already exists. Choose another name."
      cntools_wallet_create_log CHOICE \
        "duplicate CLI wallet name rejected wallet=${name}"
      continue
    fi
    break
  done

  cntools_wallet_create_log CHOICE "CLI wallet name selected wallet=${name}"
  cntools_ui_action_begin "CLI" "/ Wallet / New / CLI"
  cntools_wallet_create_render_plan "${name}" || return 1
  cntools_ui_render_status warn \
    "This wallet has no recovery phrase. Its signing keys will initially be stored locally and unencrypted."
  if cntools_ui_confirm "Create this CLI wallet now?"; then
    confirm_status=0
  else
    confirm_status=$?
  fi
  if (( confirm_status == 1 )); then
    cntools_wallet_create_log CHOICE \
      "CLI wallet creation declined wallet=${name}"
    cntools_gum_clear
    return 0
  elif (( confirm_status != 0 )); then
    return "${confirm_status}"
  fi
  cntools_wallet_create_log CHOICE \
    "CLI wallet creation confirmed wallet=${name}"

  cntools_ui_action_begin "CLI" "/ Wallet / New / CLI"
  if cntools_ui_spin_function \
      "Creating CLI wallet ${name}…" cntools_wallet_create_cli "${name}"; then
    create_status=0
  else
    create_status=$?
  fi
  if (( create_status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_CREATE_ERROR:-Wallet creation failed. See ${CNTOOLS_LOG}.}"
    cntools_ui_wait
    return "${create_status}"
  fi

  cntools_ui_action_begin "CLI" "/ Wallet / New / CLI"
  cntools_ui_render_status success \
    "CLI wallet ${CNTOOLS_WALLET_CREATED_NAME} was created successfully."
  if ! cntools_wallet_create_render_result \
      "${CNTOOLS_WALLET_CREATED_DIRECTORY}" \
      "${CNTOOLS_WALLET_CREATED_NAME}"; then
    cntools_wallet_create_log ERROR \
      "Wallet was created but its result tables could not be rendered wallet=${CNTOOLS_WALLET_CREATED_NAME}"
    cntools_ui_render_status warn \
      "The wallet was created at ${CNTOOLS_WALLET_CREATED_DIRECTORY}, but its result details could not be displayed."
  fi
  if [[ -n "${CNTOOLS_WALLET_CREATE_WARNING}" ]]; then
    cntools_ui_render_status warn "${CNTOOLS_WALLET_CREATE_WARNING}"
  fi
  cntools_ui_render_status warn \
    "Back up and protect the wallet directory before sending funds to it."
  cntools_ui_wait
  return 0
}
