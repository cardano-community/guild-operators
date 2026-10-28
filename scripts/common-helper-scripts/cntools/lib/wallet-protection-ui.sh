#!/usr/bin/env bash
# Gum interaction and presentation for wallet encryption and decryption.
# Loaded after wallet-protection.sh.

# What Encrypt or Decrypt would do with a wallet: keys (encrypt or decrypt
# its signing keys), complete (encrypt the clear keys of a partly protected
# wallet with its existing passphrase), relock (an encrypted wallet's files
# lost their locks), lock (no local private keys: file locks only). Returns 1
# when nothing.
cntools_wallet_protection_mode_into() {
  local _cntools_mode_output="${1:-}" _cntools_mode_operation="${2:-}" _cntools_mode_index="${3:-}"
  local _cntools_mode_directory="${CNTOOLS_WALLET_PATHS[_cntools_mode_index]:-}"
  local _cntools_mode_type="${CNTOOLS_WALLET_TYPES[_cntools_mode_index]:-}"
  local _cntools_mode_protection="${CNTOOLS_WALLET_PROTECTIONS[_cntools_mode_index]:-}"
  local -a _cntools_mode_clear=() _cntools_mode_encrypted=()

  [[ "${_cntools_mode_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_mode_ref="${_cntools_mode_output}"
  _cntools_mode_ref=""
  [[ "${_cntools_mode_operation}" == encrypt || "${_cntools_mode_operation}" == decrypt ]] || return 2
  if cntools_wallet_protection_lock_only "${_cntools_mode_directory}"; then
    cntools_wallet_protection_lock_would_change "${_cntools_mode_directory}" "${_cntools_mode_operation}" || return 1
    _cntools_mode_ref=lock
    return 0
  fi
  # A hardware wallet's only file key is a Catalyst voting key (Catalyst
  # Registration saves one there); key roles limit what is encrypted.
  [[ "${_cntools_mode_type}" == "CLI" || "${_cntools_mode_type}" == "Mnemonic" || "${_cntools_mode_type}" == "Hardware" ]] || return 1
  cntools_wallet_protection_present_into _cntools_mode_clear encrypt "${_cntools_mode_directory}" || return 1
  cntools_wallet_protection_present_into _cntools_mode_encrypted decrypt "${_cntools_mode_directory}" || return 1
  case "${_cntools_mode_operation}" in
    encrypt)
      if [[ "${_cntools_mode_protection}" == "Open" ]] && (( ${#_cntools_mode_clear[@]} > 0 )); then
        _cntools_mode_ref=keys
      elif [[ "${_cntools_mode_protection}" == "Partly protected" ]] &&
           (( ${#_cntools_mode_clear[@]} > 0 && ${#_cntools_mode_encrypted[@]} > 0 )); then
        # v13 encrypted only the payment and stake keys of its wallets.
        _cntools_mode_ref=complete
      elif cntools_wallet_protection_relock_candidate "${_cntools_mode_directory}"; then
        _cntools_mode_ref=relock
      else
        return 1
      fi
      ;;
    decrypt)
      # A partly protected wallet (encrypted keys next to a plaintext one)
      # is decrypted completely, then encrypted again with every key.
      if [[ "${_cntools_mode_protection}" == "Protected" || "${_cntools_mode_protection}" == "Partly protected" ]] &&
         (( ${#_cntools_mode_encrypted[@]} > 0 )); then
        _cntools_mode_ref=keys
      elif cntools_wallet_protection_unlock_candidate "${_cntools_mode_directory}"; then
        # Plaintext keys in locked files (a locked hardware wallet that later
        # got a Catalyst voting key): only the files are unlocked.
        _cntools_mode_ref=unlock
      else
        return 1
      fi
      ;;
  esac
}

cntools_wallet_protection_choose() {
  local _cntools_output_name="${1:-}"
  local _cntools_operation="${2:-}"
  local _cntools_index=0
  local _cntools_selected=""
  local _cntools_row=""
  local _cntools_status=0
  local _cntools_mode=""
  local -a _cntools_rows=()
  local -a _cntools_indexes=()
  local -a _cntools_clear=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_catalog_build || return 2
  for ((_cntools_index = 0;
        _cntools_index < ${#CNTOOLS_WALLET_NAMES[@]};
        _cntools_index++)); do
    cntools_wallet_protection_mode_into _cntools_mode \
      "${_cntools_operation}" "${_cntools_index}" || continue
    printf -v _cntools_row '%02d  %-24s  %s · %s' \
      "$((${#_cntools_rows[@]} + 1))" \
      "$(cntools_wallet_truncate \
        "${CNTOOLS_WALLET_NAMES[_cntools_index]}" 24)" \
      "${CNTOOLS_WALLET_TYPES[_cntools_index]}" \
      "${CNTOOLS_WALLET_PROTECTIONS[_cntools_index]}"
    # Lock-only and relock rows say what changes: only the file locks.
    case "${_cntools_mode}:${_cntools_operation}" in
      lock:encrypt|relock:encrypt) _cntools_row+=" · files unlocked" ;;
      lock:decrypt|unlock:decrypt) _cntools_row+=" · files locked" ;;
      complete:encrypt)
        cntools_wallet_protection_present_into _cntools_clear encrypt \
          "${CNTOOLS_WALLET_PATHS[_cntools_index]}" || _cntools_clear=()
        _cntools_row+=" · ${#_cntools_clear[@]} plaintext key$( (( ${#_cntools_clear[@]} == 1 )) || printf s)" ;;
    esac
    _cntools_rows+=("${_cntools_row}")
    _cntools_indexes+=("${_cntools_index}")
  done
  # 3 = nothing to choose: the reason is shown here, once.
  if (( ${#_cntools_rows[@]} == 0 )); then
    if (( ${#CNTOOLS_WALLET_NAMES[@]} == 0 )); then
      cntools_ui_render_status info 'No wallets are available. Create or import a wallet first.'
    elif [[ "${_cntools_operation}" == encrypt ]]; then
      cntools_ui_render_status info 'No wallet has open signing keys to encrypt or unlocked files to lock.'
    else
      cntools_ui_render_status info 'No wallet has encrypted signing keys to decrypt or locked files to unlock.'
    fi
    cntools_ui_wait
    return 3
  fi
  if (( ${#_cntools_rows[@]} == 1 )); then
    _cntools_output_ref="${CNTOOLS_WALLET_PATHS[${_cntools_indexes[0]}]}"
    # No info line: the plan on the next screen names the wallet.
    cntools_wallet_protection_log CHOICE \
      "auto-selected only wallet=${_cntools_output_ref##*/} operation=${_cntools_operation}"
    return 0
  fi
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
  local names=""
  local name=""
  local -a present=()

  cntools_wallet_protection_present_into present "${operation}" "${wallet_directory}" || return 1
  for name in "${present[@]}"; do
    [[ -z "${names}" ]] || names+=", "
    names+="${name}"
  done
  printf '%s' "${names:-None}"
}

# Lock or unlock files only: a wallet without local private keys (lock), an
# encrypted wallet whose files lost their locks (relock), or plaintext keys in
# locked files (unlock).
cntools_wallet_protection_lock_only_action() {
  local directory="$1" operation="$2" mode="${3:-lock}" verb=Lock status=0
  [[ "${operation}" != decrypt ]] || verb=Unlock
  if [[ "${operation}" == decrypt ]] && ! cntools_wallet_protection_unlock_ready "${directory}"; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if [[ "${mode}" == relock ]]; then
    cntools_ui_render_status info "${directory##*/} is encrypted, but its files are writable again (as after Restore). Only its file permissions and immutable flags change; no key is decrypted or encrypted again."
  elif [[ "${mode}" == unlock ]]; then
    cntools_ui_render_status info "${directory##*/} has plaintext signing keys in locked files. Only its file permissions and immutable flags change; no key is decrypted or encrypted."
  else
    cntools_ui_render_status info "${directory##*/} has no local private signing keys. Only its local file permissions and immutable flags change; nothing is encrypted or decrypted."
  fi
  # Asked in both styles: a lone lock-only wallet is auto-selected.
  cntools_ui_confirm "${verb} the files of ${directory##*/}?" false || status=$?
  if (( status != 0 )); then
    (( status == 1 || status == 130 )) || return "${status}"
    cntools_wallet_protection_log CHOICE "wallet file ${verb,,} declined wallet=${directory##*/}"
    return 0
  fi
  if [[ "${mode}" == relock ]]; then
    cntools_ui_spin_function "Locking the files of ${directory##*/}…" cntools_wallet_protection_relock "${directory}" || status=$?
  elif [[ "${mode}" == unlock ]]; then
    cntools_ui_spin_function "Unlocking the files of ${directory##*/}…" cntools_wallet_protection_unlock_files "${directory}" || status=$?
  else
    cntools_ui_spin_function "${verb}ing the files of ${directory##*/}…" cntools_wallet_protection_lock_files "${directory}" "${operation}" || status=$?
  fi
  # The info line above already said that no key changes.
  if (( status == 0 )); then
    cntools_ui_render_status success "The files of ${directory##*/} were ${verb,,}ed."
  else cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR:-Wallet file protection failed.}"; fi
  [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] || cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
  cntools_wallet_protection_render_result "${operation}" "${directory}" || true
  cntools_ui_wait
  (( status == 0 )) || return 1
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
  local unknown_keys=""
  local -a unknown=()

  wallet_type="$(cntools_wallet_type "${wallet_directory}")" || return 1
  source_keys="$(cntools_wallet_protection_key_names \
    "${operation}" "${wallet_directory}")" || return 1
  if [[ "${operation}" == encrypt ]]; then
    cntools_wallet_protection_unknown_keys_into unknown "${wallet_directory}" || return 1
    unknown_keys="${unknown[*]}"
    unknown_keys="${unknown_keys// /, }"
  fi
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
    [[ -z "${unknown_keys}" ]] ||
      cntools_wallet_protection_styled_row "Stays plaintext" "${unknown_keys} · not a recognized wallet key" warning
    cntools_wallet_protection_styled_row "Result" "${result}" accent
    cntools_wallet_protection_styled_row "File protection" "${file_lock}" value
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_wallet_protection_render_result() {
  local operation="${1:-}"
  local wallet_directory="${2:-}"
  local protection="Open"
  local lock_only=N
  local lock_value="Owner-only read/write permissions"
  local widths=""

  if [[ "${operation}" == "encrypt" ]]; then
    protection="$(cntools_wallet_protection "${wallet_directory}")" || protection="Protected"
    lock_value="${CNTOOLS_WALLET_PROTECTION_LOCK_METHOD}"
  fi
  if cntools_wallet_protection_lock_only "${wallet_directory}"; then
    lock_only=Y
    [[ "${operation}" == encrypt ]] && protection='Locked · public files only' || protection='Unlocked · public files only'
  fi
  cntools_wallet_protection_table_widths_into widths || return 1
  cntools_ui_render_detail "Wallet" || return 1
  {
    printf 'Wallet detail\tValue\n'
    cntools_wallet_protection_styled_row \
      "Name" "${wallet_directory##*/}" identifier
    cntools_wallet_protection_styled_row "Key protection" \
      "${protection}" "$([[ "${operation}" == "encrypt" && "${protection}" != 'Partly protected' ]] && printf success || printf warning)"
    # Lock-only and relock change files only: no signing-key count.
    if [[ "${lock_only}" != Y && "${CNTOOLS_WALLET_PROTECTION_KEYS}" != 0 ]]; then
      cntools_wallet_protection_styled_row "Signing keys" "${CNTOOLS_WALLET_PROTECTION_KEYS}" number
    fi
    cntools_wallet_protection_styled_row "Wallet files" \
      "${CNTOOLS_WALLET_PROTECTION_FILES}" number
    cntools_wallet_protection_styled_row "File access" \
      "${lock_value}" value
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_wallet_protection_password_valid() {
  local operation="${1:-}"
  local passphrase="${2:-}"

  case "${operation}" in encrypt|decrypt) ;; *) return 2 ;; esac
  [[ -n "${passphrase}" && "${passphrase}" != *$'\n'* &&
     "${passphrase}" != *$'\r'* ]] || return 1
  [[ "${operation}" != "encrypt" || ${#passphrase} -ge 12 ]]
}

# Encrypt: the passphrase entry is the commitment, so no separate "Encrypt?"
# question comes first (Esc at the passphrase cancels). The plan stays on the
# passphrase screen: a table in Detailed, one line in Quick.
cntools_wallet_action_encrypt() {
  local -
  set +x # The passphrase must never reach an xtrace log.
  local wallet_directory=""
  local wallet_name=""
  local passphrase=""
  local confirmation=""
  local status=0
  local feedback=""
  local mode=""
  local index=0
  local name=""
  local -a unknown=() clear_names=() clear_files=()

  cntools_wallet_protection_reset_result
  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  if ! cntools_wallet_protection_environment_ready optional; then
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
    1|130)
      cntools_wallet_protection_log CHOICE "wallet encryption selection cancelled"
      return 0
      ;;
    3) return 0 ;;
    *)
      cntools_ui_render_status error \
        "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
      cntools_ui_wait
      return 1
      ;;
  esac
  wallet_name="${wallet_directory##*/}"
  for ((index = 0; index < ${#CNTOOLS_WALLET_PATHS[@]}; index++)); do
    [[ "${CNTOOLS_WALLET_PATHS[index]}" == "${wallet_directory}" ]] || continue
    cntools_wallet_protection_mode_into mode encrypt "${index}" || mode=""
    break
  done

  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  if [[ "${mode}" == lock || "${mode}" == relock ]]; then
    cntools_wallet_protection_lock_only_action "${wallet_directory}" encrypt "${mode}"; return $?
  fi
  if [[ "${mode}" == complete ]]; then
    cntools_wallet_protection_complete_action "${wallet_directory}"; return $?
  fi
  # GnuPG is checked before the plan and the passphrase (X-FAILEARLY).
  if ! cntools_wallet_protection_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR} Install GnuPG, then encrypt ${wallet_name}."
    cntools_ui_wait
    return 1
  fi
  # An immutable key is unlocked when it is retired; one that needs a sudo
  # password is named before the passphrase (a v13 hardware wallet's
  # Catalyst key).
  cntools_wallet_protection_present_into clear_names encrypt "${wallet_directory}" || clear_names=()
  for name in "${clear_names[@]}"; do clear_files+=("${wallet_directory}/${name}"); done
  if (( ${#clear_files[@]} > 0 )) && ! cntools_wallet_protection_unlock_ready "${wallet_directory}" "${clear_files[@]}"; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR}"
    cntools_ui_wait
    return 1
  fi

  while true; do
    cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
    if cntools_flow_quick; then
      cntools_ui_render_status info \
        "Encrypting ${wallet_name}: $(cntools_wallet_protection_key_names encrypt "${wallet_directory}")."
      cntools_wallet_protection_unknown_keys_into unknown "${wallet_directory}" || unknown=()
      (( ${#unknown[@]} == 0 )) ||
        cntools_ui_render_status warn "Not a recognized wallet key, stays plaintext: ${unknown[*]}"
    else
      cntools_wallet_protection_render_plan encrypt "${wallet_directory}" || return 1
    fi
    cntools_ui_render_status warn \
      "Keep this passphrase safe: CNTools cannot recover encrypted signing keys without it. Use at least 12 characters; it is never written to the CNTools log. Esc cancels."
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_password passphrase "New passphrase for ${wallet_name}"; then
      status=0
    else
      status=$?
      unset passphrase confirmation
      if (( status == 1 || status == 130 )); then
        cntools_wallet_protection_log CHOICE \
          "wallet encryption cancelled at passphrase wallet=${wallet_name}"
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
      if (( status == 1 || status == 130 )); then
        cntools_wallet_protection_log CHOICE \
          "wallet encryption cancelled at passphrase confirmation wallet=${wallet_name}"
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
      "Encrypting and verifying ${wallet_name}…" \
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
    return 1
  fi

  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  if (( ${#CNTOOLS_WALLET_PROTECTION_UNKNOWN_KEYS[@]} > 0 )); then
    cntools_ui_render_status success \
      "${CNTOOLS_WALLET_PROTECTION_KEYS} signing key(s) of ${wallet_name} were encrypted and verified."
    cntools_ui_render_status warn \
      "Still plaintext: ${CNTOOLS_WALLET_PROTECTION_UNKNOWN_KEYS[*]}. CNTools does not recognize it as a wallet key; move it out of the wallet folder or protect it separately."
  else
    cntools_ui_render_status success \
      "Wallet ${wallet_name} was encrypted and verified successfully."
  fi
  cntools_wallet_protection_render_result encrypt "${wallet_directory}" || true
  [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
  cntools_ui_wait
}

# A partly protected wallet (v13 encrypted only its payment and stake keys):
# encrypt its remaining clear keys with the passphrase of the encrypted ones.
# The passphrase entry is the commitment (Esc cancels); a wrong one asks
# again.
cntools_wallet_protection_complete_action() {
  local -
  set +x # The passphrase must never reach an xtrace log.
  local wallet_directory="${1:-}"
  local wallet_name="${1##*/}"
  local passphrase=""
  local status=0
  local feedback=""
  local encrypted_names=""
  local -a unknown=()

  if ! cntools_wallet_protection_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR} Install GnuPG, then encrypt ${wallet_name}."
    cntools_ui_wait
    return 1
  fi
  if ! cntools_wallet_protection_unlock_ready "${wallet_directory}"; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR}"
    cntools_ui_wait
    return 1
  fi
  encrypted_names="$(cntools_wallet_protection_key_names decrypt "${wallet_directory}")" || return 1
  while true; do
    cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
    if cntools_flow_quick; then
      cntools_ui_render_status info \
        "Encrypting the plaintext keys of ${wallet_name}: $(cntools_wallet_protection_key_names encrypt "${wallet_directory}")."
      cntools_wallet_protection_unknown_keys_into unknown "${wallet_directory}" || unknown=()
      (( ${#unknown[@]} == 0 )) ||
        cntools_ui_render_status warn "Not a recognized wallet key, stays plaintext: ${unknown[*]}"
    else
      cntools_wallet_protection_render_plan encrypt "${wallet_directory}" || return 1
    fi
    cntools_ui_render_status info \
      "${wallet_name} already has encrypted keys (${encrypted_names}). Enter their passphrase: the plaintext keys are encrypted with it too. Esc cancels."
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_password passphrase "Passphrase for ${wallet_name}"; then
      status=0
    else
      status=$?
      unset passphrase
      if (( status == 1 || status == 130 )); then
        cntools_wallet_protection_log CHOICE \
          "wallet encryption cancelled at passphrase wallet=${wallet_name} mode=complete"
        return 0
      fi
      return "${status}"
    fi
    if ! cntools_wallet_protection_password_valid decrypt "${passphrase}"; then
      feedback="Enter the wallet passphrase without a line break."
      unset passphrase
      continue
    fi
    cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
    if cntools_ui_spin_function \
        "Encrypting and verifying ${wallet_name}…" \
        cntools_wallet_protection_encrypt \
        "${wallet_directory}" "${passphrase}" complete; then
      status=0
    else
      status=$?
    fi
    unset passphrase
    (( status != 0 )) || break
    if [[ "${CNTOOLS_WALLET_PROTECTION_BAD_PASSPHRASE}" == Y ]]; then
      feedback="That passphrase does not open the encrypted keys of ${wallet_name}. Nothing was changed; enter it again or press Esc to cancel."
      cntools_wallet_protection_log CHOICE "wallet passphrase rejected wallet=${wallet_name} mode=complete"
      continue
    fi
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_PROTECTION_ERROR:-Wallet encryption failed. See ${CNTOOLS_LOG}.}"
    [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
      cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
    cntools_ui_wait
    return 1
  done

  cntools_ui_action_begin "Encrypt" "/ Wallet / Encrypt"
  cntools_ui_render_status success \
    "The remaining ${CNTOOLS_WALLET_PROTECTION_KEYS} signing key(s) of ${wallet_name} were encrypted and verified."
  (( ${#CNTOOLS_WALLET_PROTECTION_UNKNOWN_KEYS[@]} == 0 )) ||
    cntools_ui_render_status warn \
      "Still plaintext: ${CNTOOLS_WALLET_PROTECTION_UNKNOWN_KEYS[*]}. CNTools does not recognize it as a wallet key; move it out of the wallet folder or protect it separately."
  cntools_wallet_protection_render_result encrypt "${wallet_directory}" || true
  [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
  cntools_ui_wait
}

cntools_wallet_action_decrypt() {
  local -
  set +x # The passphrase must never reach an xtrace log.
  local wallet_directory=""
  local wallet_name=""
  local passphrase=""
  local status=0
  local feedback=""

  cntools_wallet_protection_reset_result
  cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
  if ! cntools_wallet_protection_environment_ready optional; then
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
    1|130)
      cntools_wallet_protection_log CHOICE "wallet decryption selection cancelled"
      return 0
      ;;
    3) return 0 ;;
    *)
      cntools_ui_render_status error \
        "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
      cntools_ui_wait
      return 1
      ;;
  esac
  wallet_name="${wallet_directory##*/}"

  cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
  if cntools_wallet_protection_lock_only "${wallet_directory}"; then
    cntools_wallet_protection_lock_only_action "${wallet_directory}" decrypt; return $?
  fi
  if cntools_wallet_protection_unlock_candidate "${wallet_directory}"; then
    cntools_wallet_protection_lock_only_action "${wallet_directory}" decrypt unlock; return $?
  fi
  # GnuPG is checked before the plan and the passphrase (X-FAILEARLY).
  if ! cntools_wallet_protection_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR} Install GnuPG, then decrypt ${wallet_name}."
    cntools_ui_wait
    return 1
  fi
  if ! cntools_wallet_protection_unlock_ready "${wallet_directory}"; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_PROTECTION_ERROR}"
    cntools_ui_wait
    return 1
  fi
  cntools_wallet_protection_render_plan decrypt "${wallet_directory}" || return 1
  cntools_ui_render_status warn \
    "Decrypting restores local plaintext signing keys. Protect the wallet directory before using them."
  if cntools_ui_confirm "Decrypt and unlock ${wallet_name}?"; then
    status=0
  else
    status=$?
    if (( status == 1 || status == 130 )); then
      cntools_wallet_protection_log CHOICE \
        "wallet decryption declined wallet=${wallet_name}"
      return 0
    fi
    return "${status}"
  fi

  # A wrong passphrase asks again; any other failure ends the action.
  while true; do
    while true; do
      cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
      [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
      if cntools_ui_password passphrase "Passphrase for ${wallet_name}"; then
        status=0
      else
        status=$?
        unset passphrase
        if (( status == 1 || status == 130 )); then
          cntools_wallet_protection_log CHOICE \
            "wallet decryption cancelled at passphrase wallet=${wallet_name}"
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
        "Decrypting and validating ${wallet_name}…" \
        cntools_wallet_protection_decrypt \
        "${wallet_directory}" "${passphrase}"; then
      status=0
    else
      status=$?
    fi
    unset passphrase
    (( status != 0 )) || break
    if [[ "${CNTOOLS_WALLET_PROTECTION_BAD_PASSPHRASE}" == Y ]]; then
      feedback="That passphrase does not open ${wallet_name}. Nothing was changed; enter it again or press Esc to cancel."
      cntools_wallet_protection_log CHOICE "wallet decryption passphrase rejected wallet=${wallet_name}"
      continue
    fi
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_PROTECTION_ERROR:-Wallet decryption failed. See ${CNTOOLS_LOG}.}"
    [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
      cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
    cntools_ui_wait
    return 1
  done

  cntools_ui_action_begin "Decrypt" "/ Wallet / Decrypt"
  cntools_ui_render_status success \
    "Wallet ${wallet_name} was decrypted and validated successfully."
  cntools_wallet_protection_render_result decrypt "${wallet_directory}" || true
  [[ -z "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_PROTECTION_WARNING}"
  cntools_ui_render_status warn \
    "The signing keys are now stored locally in plaintext."
  cntools_ui_wait
}
