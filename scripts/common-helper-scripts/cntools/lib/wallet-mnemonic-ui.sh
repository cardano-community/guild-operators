#!/usr/bin/env bash
# Gum interaction and responsive presentation for standard mnemonic wallets.
# Loaded after wallet-mnemonic.sh.
# shellcheck disable=SC2034,SC2178

cntools_wallet_mnemonic_screen_begin() {
  cntools_gum_clear
  cntools_ui_action_begin "${1:-Mnemonic}" "${2:-/ Wallet / Mnemonic}"
}

cntools_wallet_mnemonic_ui_cancelled() {
  cntools_wallet_mnemonic_log CHOICE "${1:-mnemonic wallet action cancelled}"
  cntools_gum_clear
  return 0
}

cntools_wallet_mnemonic_ui_failure() {
  local message="${1:-The mnemonic action could not continue.}"
  local breadcrumb="${2:-/ Wallet / Mnemonic}"

  cntools_wallet_mnemonic_log ERROR "${message}"
  cntools_wallet_mnemonic_screen_begin "Mnemonic" "${breadcrumb}" || true
  cntools_ui_render_status error \
    "${message} See ${CNTOOLS_LOG} for details." || true
  cntools_ui_wait || true
  return 1
}

cntools_wallet_mnemonic_prompt_name_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_title="${2:-Mnemonic}"
  local _cntools_breadcrumb="${3:-/ Wallet / Mnemonic}"
  local _cntools_name=""
  local _cntools_feedback=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "${_cntools_title}" "${_cntools_breadcrumb}"
    cntools_ui_render_status info \
      "Create a recoverable payment-and-stake wallet using Cardano CLI."
    [[ -z "${_cntools_feedback}" ]] ||
      cntools_ui_render_status warn "${_cntools_feedback}"
    if cntools_ui_input _cntools_name "Wallet name"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    if ! cntools_wallet_create_name_valid "${_cntools_name}"; then
      _cntools_feedback="Use 1–64 letters, numbers, dots, underscores, or hyphens; start with a letter or number."
      cntools_wallet_mnemonic_log CHOICE \
        "invalid mnemonic wallet name rejected"
      continue
    fi
    if ! cntools_wallet_create_target_available "${_cntools_name}"; then
      _cntools_feedback="A wallet or filesystem entry named ${_cntools_name} already exists. Choose another name."
      cntools_wallet_mnemonic_log CHOICE \
        "duplicate mnemonic wallet name rejected wallet=${_cntools_name}"
      continue
    fi
    _cntools_output_ref="${_cntools_name}"
    cntools_wallet_mnemonic_log CHOICE \
      "mnemonic wallet name selected wallet=${_cntools_name}"
    return 0
  done
}

cntools_wallet_mnemonic_prompt_index_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_prompt="${2:-Index}"
  local _cntools_title="${3:-Mnemonic}"
  local _cntools_breadcrumb="${4:-/ Wallet / Mnemonic}"
  local _cntools_input=""
  local _cntools_value=""
  local _cntools_feedback=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "${_cntools_title}" "${_cntools_breadcrumb}"
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
    if cntools_wallet_mnemonic_index_into \
        _cntools_value "${_cntools_input}"; then
      _cntools_output_ref="${_cntools_value}"
      return 0
    fi
    _cntools_feedback="Enter a whole number between 0 and 2,147,483,647."
    cntools_wallet_mnemonic_log CHOICE \
      "invalid mnemonic derivation index rejected field=${_cntools_prompt// /_}"
  done
}

cntools_wallet_mnemonic_collect_settings() {
  local _cntools_name_output="${1:-}"
  local _cntools_account_output="${2:-}"
  local _cntools_key_output="${3:-}"
  local _cntools_title="${4:-Mnemonic}"
  local _cntools_breadcrumb="${5:-/ Wallet / Mnemonic}"
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
  if cntools_wallet_mnemonic_prompt_name_into \
      _cntools_name "${_cntools_title}" "${_cntools_breadcrumb}"; then
    :
  else
    _cntools_status=$?
    return "${_cntools_status}"
  fi
  if cntools_wallet_mnemonic_prompt_index_into \
      _cntools_account "Account number" \
      "${_cntools_title}" "${_cntools_breadcrumb}"; then
    :
  else
    _cntools_status=$?
    return "${_cntools_status}"
  fi
  if cntools_wallet_mnemonic_prompt_index_into \
      _cntools_key_index "Address key index" \
      "${_cntools_title}" "${_cntools_breadcrumb}"; then
    :
  else
    _cntools_status=$?
    return "${_cntools_status}"
  fi
  _cntools_name_ref="${_cntools_name}"
  _cntools_account_ref="${_cntools_account}"
  _cntools_key_ref="${_cntools_key_index}"
}

cntools_wallet_mnemonic_plan_rows() {
  local name="${1:-}"
  local account="${2:-0}"
  local key_index="${3:-0}"
  local origin="${4:-new}"
  local target="${5:-}"
  local source_label="New 24-word recovery phrase"

  case "${origin}" in
    new) ;;
    import) source_label="Existing recovery phrase" ;;
    *) return 2 ;;
  esac
  [[ -n "${target}" ]] || return 2
  printf 'Setting\tValue\n' &&
    cntools_wallet_create_styled_row "Name" "${name}" identifier &&
    cntools_wallet_create_styled_row "Type" "Mnemonic" accent &&
    cntools_wallet_create_styled_row "Source" "${source_label}" value &&
    cntools_wallet_create_styled_row \
      "Network" "${CNTOOLS_NETWORK:-Unavailable}" accent &&
    cntools_wallet_create_styled_row \
      "Wallet directory" "${target}" identifier &&
    cntools_wallet_create_styled_row \
      "Payment path" "1852H/1815H/${account}H/0/${key_index}" identifier &&
    cntools_wallet_create_styled_row \
      "Stake path" "1852H/1815H/${account}H/2/${key_index}" identifier
}

cntools_wallet_mnemonic_render_plan_fallback() {
  local name="${1:-}"
  local account="${2:-0}"
  local key_index="${3:-0}"
  local origin="${4:-new}"
  local target="${5:-}"
  local source_label="New 24-word recovery phrase"

  [[ "${origin}" == "new" ]] || source_label="Existing recovery phrase"
  printf '  %-18s %s\n' \
    "Name" "${name}" \
    "Type" "Mnemonic" \
    "Source" "${source_label}" \
    "Network" "${CNTOOLS_NETWORK:-Unavailable}" \
    "Wallet directory" "${target}" \
    "Payment path" "1852H/1815H/${account}H/0/${key_index}" \
    "Stake path" "1852H/1815H/${account}H/2/${key_index}"
  printf '\n'
}

cntools_wallet_mnemonic_render_plan() {
  local name="${1:-}"
  local account="${2:-0}"
  local key_index="${3:-0}"
  local origin="${4:-new}"
  local target=""
  local widths=""
  local rows=""
  local status=0

  if cntools_wallet_create_target_into target "${name}"; then
    :
  else
    status=$?
    cntools_wallet_mnemonic_log ERROR \
      "Mnemonic plan target resolution failed status=${status} wallet=${name} wallet_root=${CNTOOLS_WALLET_DIR:-unset}"
    return 1
  fi
  if cntools_ui_render_detail "Mnemonic wallet"; then
    :
  else
    status=$?
    cntools_wallet_mnemonic_log WARN \
      "Gum mnemonic plan heading failed status=${status}; using plain heading"
    printf 'Mnemonic wallet\n\n'
  fi
  if cntools_wallet_create_table_widths_into widths 18; then
    :
  else
    status=$?
    cntools_wallet_mnemonic_log WARN \
      "Mnemonic plan table width calculation failed status=${status} columns=${CNTOOLS_UI_COLUMNS:-unknown}; using compact fallback"
    cntools_ui_render_status warn \
      "The table view is unavailable; showing the compact wallet plan." || true
    cntools_wallet_mnemonic_render_plan_fallback \
      "${name}" "${account}" "${key_index}" "${origin}" "${target}"
    return $?
  fi
  if rows="$(cntools_wallet_mnemonic_plan_rows \
      "${name}" "${account}" "${key_index}" "${origin}" "${target}")"; then
    :
  else
    status=$?
    cntools_wallet_mnemonic_log WARN \
      "Mnemonic plan row preparation failed status=${status}; using compact fallback"
    cntools_ui_render_status warn \
      "The table view is unavailable; showing the compact wallet plan." || true
    cntools_wallet_mnemonic_render_plan_fallback \
      "${name}" "${account}" "${key_index}" "${origin}" "${target}"
    return $?
  fi
  if printf '%s\n' "${rows}" |
      cntools_ui_table --separator $'\t' --widths "${widths}"; then
    printf '\n'
    return 0
  else
    status=$?
  fi
  cntools_wallet_mnemonic_log WARN \
    "Gum mnemonic plan table failed status=${status} widths=${widths}; using compact fallback"
  cntools_ui_render_status warn \
    "The table view is unavailable; showing the compact wallet plan." || true
  cntools_wallet_mnemonic_render_plan_fallback \
    "${name}" "${account}" "${key_index}" "${origin}" "${target}"
}

cntools_wallet_mnemonic_word_columns() {
  local width="${1:-}"

  [[ "${width}" =~ ^[1-9][0-9]*$ ]] || return 2
  if (( width >= 102 )); then
    printf '6\n'
  elif (( width >= 70 )); then
    printf '4\n'
  elif (( width >= 52 )); then
    printf '3\n'
  elif (( width >= 34 )); then
    printf '2\n'
  else
    printf '1\n'
  fi
}

cntools_wallet_mnemonic_render_phrase() {
  local words_name="${1:-}"
  local phrase=""
  local width=""
  local columns=1
  local rows=0
  local row=0
  local column=0
  local index=0
  local cell=""

  [[ "${words_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n words_ref="${words_name}"
  cntools_wallet_mnemonic_phrase_into phrase "${words_name}" || return 1
  width="$(cntools_ui_content_width 180 28)" || return 1
  columns="$(cntools_wallet_mnemonic_word_columns "${width}")" || return 1
  rows=$(( (${#words_ref[@]} + columns - 1) / columns ))

  cntools_ui_render_status warn \
    "Anyone with these words can control this wallet. Record them offline and never share them."
  cntools_ui_render_detail "Recovery phrase — copy as one line" || return 1
  cntools_gum style --margin "0 2 1 2" --padding "0 1" \
    --width "${width}" --border rounded \
    --border-foreground "${CNTOOLS_GUM_COLOR_WARNING}" \
    --foreground "${CNTOOLS_GUM_COLOR_TEXT}" "${phrase}" || return 1

  cntools_ui_render_detail "Recovery phrase — numbered" || return 1
  {
    for ((column = 0; column < columns; column++)); do
      (( column == 0 )) || printf '\t'
      printf 'Word'
    done
    printf '\n'
    for ((row = 0; row < rows; row++)); do
      for ((column = 0; column < columns; column++)); do
        (( column == 0 )) || printf '\t'
        index=$((row * columns + column))
        if (( index < ${#words_ref[@]} )); then
          printf -v cell '%02d  %s' "$((index + 1))" "${words_ref[index]}"
          printf '%s' "${cell}"
        fi
      done
      printf '\n'
    done
  } | cntools_ui_table --separator $'\t' || return 1
  printf '\n'
}

cntools_wallet_mnemonic_verify_backup() {
  local words_name="${1:-}"
  local name="${2:-}"
  local account="${3:-0}"
  local key_index="${4:-0}"
  local status=0
  local challenge_index=0
  local attempt=0
  local answer=""
  local normalized=""
  local feedback=""
  local -a indices=()

  [[ "${words_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n words_ref="${words_name}"
  if cntools_ui_confirm "I have safely recorded all recovery words"; then
    status=0
  else
    status=$?
  fi
  (( status == 0 )) || return "${status}"
  cntools_wallet_mnemonic_challenge_indices_into \
    indices "${#words_ref[@]}" 4 || return 1
  cntools_wallet_mnemonic_log CHOICE \
    "mnemonic backup challenge started positions=$((indices[0] + 1)),$((indices[1] + 1)),$((indices[2] + 1)),$((indices[3] + 1))"
  for challenge_index in "${indices[@]}"; do
    feedback=""
    for ((attempt = 1; attempt <= 3; attempt++)); do
      cntools_wallet_mnemonic_screen_begin \
        "Mnemonic" "/ Wallet / New / Mnemonic"
      cntools_ui_render_status success \
        "The recovery phrase has been cleared from the screen."
      cntools_wallet_mnemonic_render_plan \
        "${name}" "${account}" "${key_index}" new || return 1
      cntools_ui_render_status info \
        "Confirm four randomly selected words from your recorded backup."
      [[ -z "${feedback}" ]] ||
        cntools_ui_render_status warn "${feedback}"
      if cntools_ui_input answer "Word $((challenge_index + 1))"; then
        status=0
      else
        status=$?
      fi
      (( status == 0 )) || return "${status}"
      if cntools_wallet_mnemonic_word_into normalized "${answer}" &&
         [[ "${normalized}" == "${words_ref[challenge_index]}" ]]; then
        break
      fi
      feedback="That word does not match your recovery phrase."
      cntools_wallet_mnemonic_log CHOICE \
        "mnemonic backup challenge mismatch position=$((challenge_index + 1)) attempt=${attempt}"
      unset answer normalized
    done
    if (( attempt > 3 )); then
      cntools_wallet_mnemonic_log ERROR \
        "mnemonic backup challenge failed position=$((challenge_index + 1))"
      return 5
    fi
    unset answer normalized
  done
  cntools_wallet_mnemonic_log CHOICE "mnemonic backup challenge passed"
}

cntools_wallet_mnemonic_collect_pasted_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_phrase=""
  local _cntools_normalized=""
  local _cntools_feedback=""
  local _cntools_status=0
  local -a _cntools_words=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "Mnemonic" "/ Wallet / Import / Mnemonic"
    cntools_ui_render_status info \
      "Paste all recovery words separated by spaces. Leading and trailing whitespace is ignored."
    [[ -z "${_cntools_feedback}" ]] ||
      cntools_ui_render_status warn "${_cntools_feedback}"
    if cntools_ui_password _cntools_phrase "Recovery phrase"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    if cntools_wallet_mnemonic_words_into \
         _cntools_words "${_cntools_phrase}" &&
       cntools_wallet_mnemonic_phrase_into \
         _cntools_normalized _cntools_words; then
      _cntools_output_ref="${_cntools_normalized}"
      cntools_wallet_mnemonic_log CHOICE \
        "pasted recovery phrase accepted words=${#_cntools_words[@]}"
      unset _cntools_phrase _cntools_normalized _cntools_words
      return 0
    fi
    _cntools_feedback="Enter exactly 12, 15, 18, 21, or 24 alphabetic recovery words."
    cntools_wallet_mnemonic_log CHOICE \
      "pasted recovery phrase rejected by local shape validation"
    unset _cntools_phrase _cntools_normalized _cntools_words
  done
}

cntools_wallet_mnemonic_collect_interactive_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_count_choice=""
  local _cntools_count=0
  local _cntools_index=0
  local _cntools_input=""
  local _cntools_word=""
  local _cntools_phrase=""
  local _cntools_feedback=""
  local _cntools_status=0
  local -a _cntools_words=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / Import / Mnemonic"
  if cntools_ui_choose _cntools_count_choice "Recovery phrase length…" \
      "12 words" "15 words" "18 words" "21 words" "24 words"; then
    :
  else
    return $?
  fi
  _cntools_count="${_cntools_count_choice%% *}"
  cntools_wallet_mnemonic_word_count_valid "${_cntools_count}" || return 2
  for ((_cntools_index = 1;
       _cntools_index <= _cntools_count;
       _cntools_index++)); do
    _cntools_feedback=""
    while true; do
      cntools_wallet_mnemonic_screen_begin \
        "Mnemonic" "/ Wallet / Import / Mnemonic"
      cntools_ui_render_status info \
        "Enter recovery word ${_cntools_index} of ${_cntools_count}. Previous words are cleared as you continue."
      [[ -z "${_cntools_feedback}" ]] ||
        cntools_ui_render_status warn "${_cntools_feedback}"
      if cntools_ui_input _cntools_input "Word ${_cntools_index}"; then
        _cntools_status=0
      else
        _cntools_status=$?
      fi
      (( _cntools_status == 0 )) || return "${_cntools_status}"
      if cntools_wallet_mnemonic_word_into \
          _cntools_word "${_cntools_input}"; then
        _cntools_words+=("${_cntools_word}")
        break
      fi
      _cntools_feedback="Enter one alphabetic recovery word."
      cntools_wallet_mnemonic_log CHOICE \
        "invalid interactive recovery word rejected position=${_cntools_index}"
    done
    unset _cntools_input _cntools_word
  done
  cntools_wallet_mnemonic_phrase_into _cntools_phrase _cntools_words || return 1
  _cntools_output_ref="${_cntools_phrase}"
  cntools_wallet_mnemonic_log CHOICE \
    "interactive recovery phrase accepted words=${_cntools_count}"
  unset _cntools_phrase _cntools_words
}

cntools_wallet_mnemonic_collect_import_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_method=""
  local _cntools_phrase=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / Import / Mnemonic"
  cntools_ui_render_status info \
    "Choose how to enter the existing recovery phrase."
  if cntools_ui_choose _cntools_method "Mnemonic input method…" \
      "Paste complete phrase" "Enter one word at a time"; then
    :
  else
    return $?
  fi
  case "${_cntools_method}" in
    "Paste complete phrase")
      if cntools_wallet_mnemonic_collect_pasted_into _cntools_phrase; then
        :
      else
        _cntools_status=$?
        return "${_cntools_status}"
      fi
      ;;
    "Enter one word at a time")
      if cntools_wallet_mnemonic_collect_interactive_into _cntools_phrase; then
        :
      else
        _cntools_status=$?
        return "${_cntools_status}"
      fi
      ;;
    *) return 2 ;;
  esac
  _cntools_output_ref="${_cntools_phrase}"
  unset _cntools_phrase
  cntools_gum_clear
}

cntools_wallet_mnemonic_render_result() {
  local directory="${1:-}"
  local name="${2:-}"
  local account="${3:-0}"
  local key_index="${4:-0}"
  local base_address=""
  local payment_address=""
  local reward_address=""
  local payment_credential=""
  local stake_credential=""
  local widths=""

  if ! cntools_wallet_read_address "${directory}" base base_address ||
     ! cntools_wallet_read_address "${directory}" payment payment_address ||
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
    cntools_wallet_create_styled_row "Type" "Mnemonic" accent
    cntools_wallet_create_styled_row "Key protection" "Open" warning
    cntools_wallet_create_styled_row \
      "Stake registration" "Not registered" warning
    cntools_wallet_create_styled_row \
      "Payment path" "1852H/1815H/${account}H/0/${key_index}" identifier
    cntools_wallet_create_styled_row \
      "Stake path" "1852H/1815H/${account}H/2/${key_index}" identifier
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

cntools_wallet_action_new_mnemonic() {
  local name=""
  local account=""
  local key_index=""
  local phrase=""
  local status=0
  local -a words=()

  cntools_wallet_mnemonic_reset_result
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / New / Mnemonic"
  if ! cntools_wallet_create_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_CREATE_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if cntools_wallet_mnemonic_collect_settings \
      name account key_index "Mnemonic" "/ Wallet / New / Mnemonic"; then
    :
  else
    status=$?
    (( status != 1 )) || {
      cntools_wallet_mnemonic_ui_cancelled \
        "new mnemonic wallet cancelled during settings"
      return 0
    }
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic wallet settings could not be collected (status ${status})." \
      "/ Wallet / New / Mnemonic"
    return 1
  fi
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / New / Mnemonic"
  if ! cntools_wallet_mnemonic_render_plan \
      "${name}" "${account}" "${key_index}" new; then
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic wallet plan could not be displayed." \
      "/ Wallet / New / Mnemonic"
    return 1
  fi
  cntools_ui_render_status warn \
    "CNTools will display the recovery phrase once and then verify your backup."
  if cntools_ui_confirm "Generate this wallet's recovery phrase now?"; then
    :
  else
    status=$?
    (( status != 1 )) || {
      cntools_wallet_mnemonic_ui_cancelled \
        "new mnemonic wallet generation declined wallet=${name}"
      return 0
    }
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic generation confirmation failed (status ${status})." \
      "/ Wallet / New / Mnemonic"
    return 1
  fi
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / New / Mnemonic"
  if ! cntools_ui_spin_function \
      "Generating a 24-word recovery phrase…" \
      cntools_wallet_mnemonic_generate_into phrase; then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_MNEMONIC_ERROR:-Recovery phrase generation failed.}"
    cntools_ui_wait
    unset phrase
    return 1
  fi
  if ! cntools_wallet_mnemonic_words_into words "${phrase}" 24; then
    unset phrase words
    cntools_wallet_mnemonic_ui_failure \
      "Cardano CLI returned a recovery phrase that CNTools could not validate." \
      "/ Wallet / New / Mnemonic"
    return 1
  fi
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / New / Mnemonic"
  if ! cntools_wallet_mnemonic_render_plan \
      "${name}" "${account}" "${key_index}" new; then
    unset phrase words
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic backup plan could not be displayed." \
      "/ Wallet / New / Mnemonic"
    return 1
  fi
  if ! cntools_wallet_mnemonic_render_phrase words; then
    unset phrase words
    cntools_wallet_mnemonic_ui_failure \
      "The recovery phrase could not be displayed safely." \
      "/ Wallet / New / Mnemonic"
    return 1
  fi
  if cntools_wallet_mnemonic_verify_backup \
      words "${name}" "${account}" "${key_index}"; then
    status=0
  else
    status=$?
  fi
  # The next render clears the phrase and all challenge inputs before any
  # wallet files are derived.
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / New / Mnemonic"
  if (( status == 1 )); then
    cntools_wallet_mnemonic_ui_cancelled \
      "new mnemonic wallet cancelled during backup verification wallet=${name}"
    unset phrase words
    return 0
  elif (( status != 0 )); then
    cntools_ui_render_status error \
      "Recovery phrase verification failed. The wallet was not created."
    cntools_ui_wait
    unset phrase words
    return "${status}"
  fi
  cntools_ui_render_status success \
    "Recovery phrase backup verified. Deriving the wallet now."
  if cntools_ui_spin_function \
      "Deriving mnemonic wallet ${name}…" \
      cntools_wallet_mnemonic_create \
      "${name}" "${account}" "${key_index}" "${phrase}" new; then
    status=0
  else
    status=$?
  fi
  unset phrase words
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_MNEMONIC_ERROR:-Mnemonic wallet creation failed. See ${CNTOOLS_LOG}.}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / New / Mnemonic"
  cntools_ui_render_status success \
    "Mnemonic wallet ${CNTOOLS_WALLET_CREATED_NAME} was created successfully."
  cntools_wallet_mnemonic_render_result \
    "${CNTOOLS_WALLET_CREATED_DIRECTORY}" \
    "${CNTOOLS_WALLET_CREATED_NAME}" \
    "${CNTOOLS_WALLET_MNEMONIC_ACCOUNT}" \
    "${CNTOOLS_WALLET_MNEMONIC_KEY_INDEX}" ||
    cntools_ui_render_status warn \
      "The wallet was created, but its result details could not be displayed."
  [[ -z "${CNTOOLS_WALLET_CREATE_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_CREATE_WARNING}"
  cntools_ui_render_status warn \
    "Keep the recovery phrase offline and encrypt the local signing keys when they are not in use."
  cntools_ui_wait
}

cntools_wallet_action_import_mnemonic() {
  local name=""
  local account=""
  local key_index=""
  local phrase=""
  local status=0
  local word_count=0
  local -a words=()

  cntools_wallet_mnemonic_reset_result
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / Import / Mnemonic"
  if ! cntools_wallet_create_environment_ready; then
    cntools_ui_render_status error "${CNTOOLS_WALLET_CREATE_ERROR}"
    cntools_ui_wait
    return 1
  fi
  if cntools_wallet_mnemonic_collect_settings \
      name account key_index "Mnemonic" "/ Wallet / Import / Mnemonic"; then
    :
  else
    status=$?
    (( status != 1 )) || {
      cntools_wallet_mnemonic_ui_cancelled \
        "mnemonic import cancelled during settings"
      return 0
    }
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic import settings could not be collected (status ${status})." \
      "/ Wallet / Import / Mnemonic"
    return 1
  fi
  if cntools_wallet_mnemonic_collect_import_into phrase; then
    :
  else
    status=$?
    (( status != 1 )) || {
      cntools_wallet_mnemonic_ui_cancelled \
        "mnemonic import cancelled during phrase input wallet=${name}"
      unset phrase
      return 0
    }
    unset phrase
    cntools_wallet_mnemonic_ui_failure \
      "The recovery phrase input failed (status ${status})." \
      "/ Wallet / Import / Mnemonic"
    return 1
  fi
  if ! cntools_wallet_mnemonic_words_into words "${phrase}"; then
    unset phrase words
    cntools_wallet_mnemonic_ui_failure \
      "The imported recovery phrase could not be normalized safely." \
      "/ Wallet / Import / Mnemonic"
    return 1
  fi
  word_count="${#words[@]}"
  unset words
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / Import / Mnemonic"
  if ! cntools_wallet_mnemonic_render_plan \
      "${name}" "${account}" "${key_index}" import; then
    unset phrase
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic import plan could not be displayed." \
      "/ Wallet / Import / Mnemonic"
    return 1
  fi
  cntools_ui_render_status info \
    "Recovery phrase accepted locally: ${word_count} words. Cardano CLI will validate it during derivation."
  cntools_ui_render_status warn \
    "Only the selected payment and stake addresses are imported; this is a single-address CNTools wallet."
  if cntools_ui_confirm "Import this mnemonic wallet now?"; then
    :
  else
    status=$?
    unset phrase
    (( status != 1 )) || {
      cntools_wallet_mnemonic_ui_cancelled \
        "mnemonic wallet import declined wallet=${name}"
      return 0
    }
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic import confirmation failed (status ${status})." \
      "/ Wallet / Import / Mnemonic"
    return 1
  fi
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / Import / Mnemonic"
  if cntools_ui_spin_function \
      "Importing mnemonic wallet ${name}…" \
      cntools_wallet_mnemonic_create \
      "${name}" "${account}" "${key_index}" "${phrase}" import; then
    status=0
  else
    status=$?
  fi
  unset phrase
  if (( status != 0 )); then
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_MNEMONIC_ERROR:-Mnemonic wallet import failed. See ${CNTOOLS_LOG}.}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / Import / Mnemonic"
  cntools_ui_render_status success \
    "Mnemonic wallet ${CNTOOLS_WALLET_CREATED_NAME} was imported successfully."
  cntools_wallet_mnemonic_render_result \
    "${CNTOOLS_WALLET_CREATED_DIRECTORY}" \
    "${CNTOOLS_WALLET_CREATED_NAME}" \
    "${CNTOOLS_WALLET_MNEMONIC_ACCOUNT}" \
    "${CNTOOLS_WALLET_MNEMONIC_KEY_INDEX}" ||
    cntools_ui_render_status warn \
      "The wallet was imported, but its result details could not be displayed."
  [[ -z "${CNTOOLS_WALLET_CREATE_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_CREATE_WARNING}"
  cntools_ui_render_status warn \
    "Encrypt the imported signing keys when they are not in use."
  cntools_ui_wait
}
