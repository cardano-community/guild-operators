#!/usr/bin/env bash
# Gum interaction and presentation for wallet encryption and decryption.
# Loaded after wallet-protection.sh.

cntools_wallet_protection_candidate() {
  local operation="${1:-}"
  local index="${2:-}"
  local wallet_directory="${CNTOOLS_WALLET_PATHS[index]:-}"
  local wallet_type="${CNTOOLS_WALLET_TYPES[index]:-}"
  local protection="${CNTOOLS_WALLET_PROTECTIONS[index]:-}"
  local payment_clear="${wallet_directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
  local stake_clear="${wallet_directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
  local payment_gpg="${payment_clear}.gpg"
  local stake_gpg="${stake_clear}.gpg"

  [[ "${wallet_type}" == "CLI" || "${wallet_type}" == "Mnemonic" ]] || return 1
  case "${operation}" in
    encrypt)
      [[ "${protection}" == "Open" &&
         ! -e "${payment_gpg}" && ! -L "${payment_gpg}" &&
         ! -e "${stake_gpg}" && ! -L "${stake_gpg}" &&
         ( ( -f "${payment_clear}" && ! -L "${payment_clear}" ) ||
           ( -f "${stake_clear}" && ! -L "${stake_clear}" ) ) ]]
      ;;
    decrypt)
      [[ "${protection}" == "Protected" &&
         ! -e "${payment_clear}" && ! -L "${payment_clear}" &&
         ! -e "${stake_clear}" && ! -L "${stake_clear}" &&
         ( ( -f "${payment_gpg}" && ! -L "${payment_gpg}" ) ||
           ( -f "${stake_gpg}" && ! -L "${stake_gpg}" ) ) ]]
      ;;
    *) return 2 ;;
  esac
}

cntools_wallet_protection_choose() {
  local _cntools_output_name="${1:-}"
  local _cntools_operation="${2:-}"
  local _cntools_index=0
  local _cntools_selected=""
  local _cntools_row=""
  local _cntools_status=0
  local -a _cntools_rows=()
  local -a _cntools_indexes=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_catalog_build || return 3
  for ((_cntools_index = 0;
        _cntools_index < ${#CNTOOLS_WALLET_NAMES[@]};
        _cntools_index++)); do
    cntools_wallet_protection_candidate \
      "${_cntools_operation}" "${_cntools_index}" || continue
    printf -v _cntools_row '%02d  %-24s  %s · %s' \
      "$((${#_cntools_rows[@]} + 1))" \
      "$(cntools_wallet_truncate \
        "${CNTOOLS_WALLET_NAMES[_cntools_index]}" 24)" \
      "${CNTOOLS_WALLET_TYPES[_cntools_index]}" \
      "${CNTOOLS_WALLET_PROTECTIONS[_cntools_index]}"
    _cntools_rows+=("${_cntools_row}")
    _cntools_indexes+=("${_cntools_index}")
  done
  (( ${#_cntools_rows[@]} > 0 )) || return 4
  if cntools_ui_choose _cntools_selected \
      "Filter wallets…" "${_cntools_rows[@]}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  (( _cntools_status == 0 )) || return "${_cntools_status}"
  for ((_cntools_index = 0;
        _cntools_index < ${#_cntools_rows[@]};
        _cntools_index++)); do
    [[ "${_cntools_selected}" == "${_cntools_rows[_cntools_index]}" ]] || continue
    _cntools_output_ref="${CNTOOLS_WALLET_PATHS[${_cntools_indexes[_cntools_index]}]}"
    cntools_wallet_protection_log CHOICE \
      "selected wallet=${_cntools_output_ref##*/} operation=${_cntools_operation}"
    return 0
  done
  cntools_wallet_protection_log ERROR \
    "Wallet protection selector returned an unknown row"
  return 2
}

cntools_wallet_protection_key_names() {
  local operation="${1:-}"
  local wallet_directory="${2:-}"
  local suffix=""
  local names=""
  local filename=""

  [[ "${operation}" != "decrypt" ]] || suffix=".gpg"
  for filename in \
    "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"; do
    [[ -f "${wallet_directory}/${filename}${suffix}" &&
       ! -L "${wallet_directory}/${filename}${suffix}" ]] || continue
    [[ -z "${names}" ]] || names+=", "
    names+="${filename}${suffix}"
  done
  printf '%s' "${names:-None}"
}

cntools_wallet_protection_table_widths_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_table_width=""
  local _cntools_value_width=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_table_width="$(cntools_ui_content_width 160 44)" || return 1
  _cntools_value_width=$((_cntools_table_width - 25))
  (( _cntools_value_width >= 18 )) || return 1
  _cntools_output_ref="18,${_cntools_value_width}"
}

cntools_wallet_protection_styled_row() {
  local label="${1:-}"
  local value="${2:-}"
  local role="${3:-value}"
  local styled=""

  cntools_theme_style_value_into styled "${role}" "${value}" || return 1
  printf '%s\t%s\n' "${label}" "${styled}"
}

cntools_wallet_protection_render_plan() {
  local operation="${1:-}"
  local wallet_directory="${2:-}"
  local wallet_name="${wallet_directory##*/}"
  local wallet_type=""
  local source_keys=""
  local result=""
  local file_lock="Read-only permissions"
  local widths=""

  wallet_type="$(cntools_wallet_type "${wallet_directory}")" || return 1
  source_keys="$(cntools_wallet_protection_key_names \
    "${operation}" "${wallet_directory}")" || return 1
  if [[ "${CNTOOLS_ENABLE_CHATTR:-true}" == "true" ]]; then
    file_lock="Read-only permissions; immutable flag when available"
  fi
  if [[ "${operation}" == "encrypt" ]]; then
    result="Encrypted .gpg signing keys"
  else
    result="Open local signing keys"
    file_lock="Owner-only read/write permissions"
  fi
  cntools_wallet_protection_table_widths_into widths || return 1
  cntools_ui_render_detail "Wallet ${operation}" || return 1
  {
    printf 'Setting\tValue\n'
    cntools_wallet_protection_styled_row "Wallet" "${wallet_name}" identifier
    cntools_wallet_protection_styled_row "Type" "${wallet_type}" accent
    cntools_wallet_protection_styled_row "Signing keys" "${source_keys}" credential
    cntools_wallet_protection_styled_row "Result" "${result}" accent
    cntools_wallet_protection_styled_row "File protection" "${file_lock}" value
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
  printf '\n'
}

cntools_wallet_protection_render_result() {
  local operation="${1:-}"
  local wallet_directory="${2:-}"
  local protection="Open"
  local lock_value="Owner-only read/write permissions"
  local widths=""

  if [[ "${operation}" == "encrypt" ]]; then
    protection="Protected"
    lock_value="${CNTOOLS_WALLET_PROTECTION_LOCK_METHOD}"
  fi
  cntools_wallet_protection_table_widths_into widths || return 1
  cntools_ui_render_detail "Wallet" || return 1
  {
    printf 'Wallet detail\tValue\n'
    cntools_wallet_protection_styled_row \
      "Name" "${wallet_directory##*/}" identifier
    cntools_wallet_protection_styled_row "Key protection" \
      "${protection}" "$([[ "${operation}" == "encrypt" ]] && printf success || printf warning)"
    cntools_wallet_protection_styled_row "Signing keys" \
      "${CNTOOLS_WALLET_PROTECTION_KEYS}" number
    cntools_wallet_protection_styled_row "Wallet files" \
      "${CNTOOLS_WALLET_PROTECTION_FILES}" number
    cntools_wallet_protection_styled_row "File access" \
      "${lock_value}" value
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
  printf '\n'
}

cntools_wallet_protection_password_valid() {
  local operation="${1:-}"
  local passphrase="${2:-}"

  case "${operation}" in encrypt|decrypt) ;; *) return 2 ;; esac
  [[ -n "${passphrase}" && "${passphrase}" != *$'\n'* &&
     "${passphrase}" != *$'\r'* ]] || return 1
  [[ "${operation}" != "encrypt" || ${#passphrase} -ge 12 ]]
}

cntools_wallet_action_encrypt() {
  local wallet_directory=""
  local passphrase=""
  local confirmation=""
  local status=0
  local feedback=""

  cntools_wallet_protection_reset_result
  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  if ! cntools_wallet_protection_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if cntools_wallet_protection_choose wallet_directory encrypt; then
    status=0
  else
    status=$?
  fi
  case "${status}" in
    0) ;;
    1)
      cntools_wallet_protection_log CHOICE "wallet encryption selection cancelled"
      cntools_gum_clear
      return 0
      ;;
    4)
      cntools_ui_render_status warn \
        "No open CLI or mnemonic wallet has signing keys available to encrypt."
      cntools_ui_wait
      return 0
      ;;
    *)
      cntools_ui_render_status error \
        "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
      cntools_ui_wait
      return 1
      ;;
  esac

  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  cntools_wallet_protection_render_plan encrypt "${wallet_directory}" || return 1
  cntools_ui_render_status warn \
    "Keep this passphrase safe. CNTools cannot recover encrypted signing keys without it."
  if cntools_ui_confirm "Encrypt and lock this wallet?"; then
    status=0
  else
    status=$?
    if (( status == 1 )); then
      cntools_wallet_protection_log CHOICE \
        "wallet encryption declined wallet=${wallet_directory##*/}"
      cntools_gum_clear
      return 0
    fi
    return "${status}"
  fi

  while true; do
    cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
    cntools_ui_render_status info \
      "Use at least 12 characters. The passphrase is never written to the CNTools log."
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_password passphrase "New wallet passphrase"; then
      status=0
    else
      status=$?
      unset passphrase confirmation
      if (( status == 1 )); then
        cntools_wallet_protection_log CHOICE \
          "wallet encryption cancelled at passphrase"
        cntools_gum_clear
        return 0
      fi
      return "${status}"
    fi
    if ! cntools_wallet_protection_password_valid encrypt "${passphrase}"; then
      feedback="Use at least 12 characters and do not include a line break."
      cntools_wallet_protection_log CHOICE \
        "new wallet passphrase rejected by length or line-break policy"
      unset passphrase confirmation
      continue
    fi
    if cntools_ui_password confirmation "Confirm wallet passphrase"; then
      status=0
    else
      status=$?
      unset passphrase confirmation
      if (( status == 1 )); then
        cntools_wallet_protection_log CHOICE \
          "wallet encryption cancelled at passphrase confirmation"
        cntools_gum_clear
        return 0
      fi
      return "${status}"
    fi
    if [[ "${passphrase}" != "${confirmation}" ]]; then
      feedback="The passphrases did not match. Enter them again."
      cntools_wallet_protection_log CHOICE \
        "new wallet passphrase confirmation mismatch"
      unset passphrase confirmation
      continue
    fi
    unset confirmation
    break
  done

  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  if cntools_ui_spin_function \
      "Encrypting and verifying ${wallet_directory##*/}…" \
      cntools_wallet_protection_encrypt \
      "${wallet_directory}" "${passphrase}"; then
    status=0
  else
    status=$?
  fi
  unset passphrase confirmation
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_PROTECTION_ERROR:-Wallet encryption failed. See ${CNTOOLS_LOG}.}"
    [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
      cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
    cntools_ui_wait
    return "${status}"
  fi

  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  cntools_ui_render_status success \
    "Wallet ${wallet_directory##*/} was encrypted and verified successfully."
  cntools_wallet_protection_render_result encrypt "${wallet_directory}" || true
  [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
  cntools_ui_wait
}

cntools_wallet_action_decrypt() {
  local wallet_directory=""
  local passphrase=""
  local status=0
  local feedback=""

  cntools_wallet_protection_reset_result
  cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
  if ! cntools_wallet_protection_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if cntools_wallet_protection_choose wallet_directory decrypt; then
    status=0
  else
    status=$?
  fi
  case "${status}" in
    0) ;;
    1)
      cntools_wallet_protection_log CHOICE "wallet decryption selection cancelled"
      cntools_gum_clear
      return 0
      ;;
    4)
      cntools_ui_render_status warn \
        "No protected CLI or mnemonic wallet is available to decrypt."
      cntools_ui_wait
      return 0
      ;;
    *)
      cntools_ui_render_status error \
        "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
      cntools_ui_wait
      return 1
      ;;
  esac

  cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
  cntools_wallet_protection_render_plan decrypt "${wallet_directory}" || return 1
  cntools_ui_render_status warn \
    "Decrypting restores local plaintext signing keys. Protect the wallet directory before using them."
  if cntools_ui_confirm "Decrypt and unlock this wallet?"; then
    status=0
  else
    status=$?
    if (( status == 1 )); then
      cntools_wallet_protection_log CHOICE \
        "wallet decryption declined wallet=${wallet_directory##*/}"
      cntools_gum_clear
      return 0
    fi
    return "${status}"
  fi

  while true; do
    cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_password passphrase "Wallet passphrase"; then
      status=0
    else
      status=$?
      unset passphrase
      if (( status == 1 )); then
        cntools_wallet_protection_log CHOICE \
          "wallet decryption cancelled at passphrase"
        cntools_gum_clear
        return 0
      fi
      return "${status}"
    fi
    if cntools_wallet_protection_password_valid decrypt "${passphrase}"; then
      break
    fi
    feedback="Enter the wallet passphrase without a line break. Legacy passphrases may be shorter than 12 characters."
    cntools_wallet_protection_log CHOICE \
      "wallet decryption received an empty or multiline passphrase"
    unset passphrase
  done

  cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
  if cntools_ui_spin_function \
      "Decrypting and validating ${wallet_directory##*/}…" \
      cntools_wallet_protection_decrypt \
      "${wallet_directory}" "${passphrase}"; then
    status=0
  else
    status=$?
  fi
  unset passphrase
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_PROTECTION_ERROR:-Wallet decryption failed. See ${CNTOOLS_LOG}.}"
    [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
      cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
    cntools_ui_wait
    return "${status}"
  fi

  cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
  cntools_ui_render_status success \
    "Wallet ${wallet_directory##*/} was decrypted and validated successfully."
  cntools_wallet_protection_render_result decrypt "${wallet_directory}" || true
  [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
  cntools_ui_render_status warn \
    "The signing keys are now stored locally in plaintext."
  cntools_ui_wait
}
