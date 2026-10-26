#!/usr/bin/env bash
# Gum interaction and responsive presentation for standard mnemonic wallets.
# Loaded after wallet-mnemonic.sh.
# shellcheck disable=SC2034,SC2178

# The BIP39 word list and its loader live in wallet-mnemonic.sh.
# Y when the last collected phrase passed the local BIP39 checksum check.
declare -g CNTOOLS_WALLET_MNEMONIC_CHECKSUM_VERIFIED="N"

# Every mnemonic screen also clears the terminal scrollback, so recovery
# words shown or chosen on an earlier screen cannot be scrolled back to.
cntools_wallet_mnemonic_screen_begin() {
  cntools_gum_clear
  [[ ! -t 1 ]] || printf '\033[3J'
  cntools_ui_action_begin "${1:-Mnemonic}" "${2:-/ Wallet / Mnemonic}"
}

cntools_wallet_mnemonic_ui_cancelled() {
  cntools_wallet_mnemonic_log CHOICE "${1:-mnemonic wallet action cancelled}"
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

cntools_wallet_mnemonic_select_word_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_position="${2:-}"
  local _cntools_total="${3:-}"
  local _cntools_selected_word=""
  local _cntools_width=""
  local _cntools_height=$((5 + ${CNTOOLS_GUM_FILTER_CHROME_ROWS:-4}))
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_position}" =~ ^[1-9][0-9]*$ &&
     "${_cntools_total}" =~ ^[1-9][0-9]*$ &&
     ${_cntools_position} -le ${_cntools_total} ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_mnemonic_wordlist_load || return 2
  _cntools_width="$(cntools_gum_width)" || return 2
  cntools_ui_seen # A raw gum prompt: what is on screen has been seen.
  if _cntools_selected_word="$(
      printf '%s\n' "${CNTOOLS_WALLET_MNEMONIC_WORDLIST[@]}" |
        cntools_gum filter --limit 1 --height "${_cntools_height}" \
          --width "${_cntools_width}" --padding "0 2 1 2" \
          --no-show-help --no-fuzzy --strict --select-if-one \
          --placeholder "Type to filter BIP39 words…" \
          --placeholder.foreground "${CNTOOLS_GUM_COLOR_MUTED}" \
          --prompt "Word ${_cntools_position}/${_cntools_total} › " \
          --prompt.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
          --indicator "▸ " \
          --indicator.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
          --match.foreground "${CNTOOLS_GUM_COLOR_SUCCESS}" \
          --text.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
          --text.background "${CNTOOLS_GUM_COLOR_CANVAS}" \
          --cursor-text.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
          --cursor-text.background "${CNTOOLS_GUM_COLOR_SURFACE}"
    )"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  (( _cntools_status == 0 )) || return "${_cntools_status}"
  if [[ -z "${_cntools_selected_word}" ||
        -z "${CNTOOLS_WALLET_MNEMONIC_WORDSET[${_cntools_selected_word}]+x}" ]]; then
    cntools_wallet_mnemonic_log ERROR \
      "Gum returned an invalid BIP39 recovery-word selection"
    return 2
  fi
  _cntools_output_ref="${_cntools_selected_word}"
}

cntools_wallet_mnemonic_prompt_name_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_title="${2:-Mnemonic}"
  local _cntools_breadcrumb="${3:-/ Wallet / Mnemonic}"
  local _cntools_prompt_candidate_name=""
  local _cntools_feedback=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "${_cntools_title}" "${_cntools_breadcrumb}"
    if [[ "${_cntools_breadcrumb}" == *Import* ]]; then
      cntools_ui_render_status info \
        "Import a payment-and-stake wallet from an existing recovery phrase."
    else
      cntools_ui_render_status info \
        "Create a recoverable payment-and-stake wallet using Cardano CLI."
    fi
    [[ -z "${_cntools_feedback}" ]] ||
      cntools_ui_render_status warn "${_cntools_feedback}"
    if cntools_ui_input _cntools_prompt_candidate_name "Wallet name"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    if ! cntools_wallet_create_name_valid \
        "${_cntools_prompt_candidate_name}"; then
      _cntools_feedback="Use 1–64 letters, numbers, dots, underscores, or hyphens; start with a letter or number."
      cntools_wallet_mnemonic_log CHOICE \
        "invalid mnemonic wallet name rejected"
      continue
    fi
    if ! cntools_wallet_create_target_available \
        "${_cntools_prompt_candidate_name}"; then
      _cntools_feedback="A wallet or filesystem entry named ${_cntools_prompt_candidate_name} already exists. Choose another name."
      cntools_wallet_mnemonic_log CHOICE \
        "duplicate mnemonic wallet name rejected wallet=${_cntools_prompt_candidate_name}"
      continue
    fi
    _cntools_output_ref="${_cntools_prompt_candidate_name}"
    cntools_wallet_mnemonic_log CHOICE \
      "mnemonic wallet name selected wallet=${_cntools_prompt_candidate_name}"
    return 0
  done
}

# Blank keeps the current value (0 on first entry).
cntools_wallet_mnemonic_prompt_index_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_prompt="${2:-Index}"
  local _cntools_title="${3:-Mnemonic}"
  local _cntools_breadcrumb="${4:-/ Wallet / Mnemonic}"
  local _cntools_current="${5:-0}"
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
      "Leave blank for ${_cntools_current}. Supported values are 0 through 2,147,483,647."
    [[ -z "${_cntools_feedback}" ]] ||
      cntools_ui_render_status warn "${_cntools_feedback}"
    if cntools_ui_input _cntools_input "${_cntools_prompt}" "${_cntools_current}"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    [[ "${_cntools_input//[[:space:]]/}" ]] || _cntools_input="${_cntools_current}"
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

cntools_wallet_mnemonic_prompt_derivation_into() {
  local _cntools_derivation_account_output="${1:-}"
  local _cntools_derivation_key_output="${2:-}"
  local _cntools_derivation_title="${3:-Mnemonic}"
  local _cntools_derivation_breadcrumb="${4:-/ Wallet / Mnemonic}"
  local _cntools_derivation_account=""
  local _cntools_derivation_key=""

  [[ "${_cntools_derivation_account_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_derivation_key_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  cntools_wallet_mnemonic_prompt_index_into \
    _cntools_derivation_account "Account number" \
    "${_cntools_derivation_title}" "${_cntools_derivation_breadcrumb}" \
    "${!_cntools_derivation_account_output:-0}" || return $?
  cntools_wallet_mnemonic_prompt_index_into \
    _cntools_derivation_key "Address key index" \
    "${_cntools_derivation_title}" "${_cntools_derivation_breadcrumb}" \
    "${!_cntools_derivation_key_output:-0}" || return $?
  printf -v "${_cntools_derivation_account_output}" '%s' "${_cntools_derivation_account}"
  printf -v "${_cntools_derivation_key_output}" '%s' "${_cntools_derivation_key}"
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
  if cntools_flow_quick; then
    # The plan step offers 'Change account and key index'.
    _cntools_account=0
    _cntools_key_index=0
    cntools_wallet_mnemonic_log CHOICE "mnemonic derivation default account=0 key_index=0 flow=quick"
  else
    cntools_wallet_mnemonic_prompt_derivation_into \
      _cntools_account _cntools_key_index \
      "${_cntools_title}" "${_cntools_breadcrumb}" || return $?
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
  local -
  set +x # Recovery words must never reach an xtrace log.
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
  # Over stdin, never argv: process arguments are visible to other users.
  printf '%s\n' "${phrase}" |
    cntools_gum style --margin "0 2 1 2" --padding "0 1" \
      --width "${width}" --border rounded \
      --border-foreground "${CNTOOLS_GUM_COLOR_WARNING}" \
      --foreground "${CNTOOLS_GUM_COLOR_TEXT}" || return 1
  unset phrase

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
  } | cntools_ui_table --keep-header --separator $'\t' || return 1
}

cntools_wallet_mnemonic_verify_backup() {
  local -
  set +x # Recovery words must never reach an xtrace log.
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
  local challenge_number=0
  for challenge_index in "${indices[@]}"; do
    feedback=""
    challenge_number=$((challenge_number + 1))
    for ((attempt = 1; attempt <= 3; attempt++)); do
      cntools_wallet_mnemonic_screen_begin \
        "Mnemonic" "/ Wallet / New / Mnemonic"
      # The plan was just reviewed; one line names the wallet and progress.
      (( challenge_number > 1 || attempt > 1 )) ||
        cntools_ui_render_status success \
          "The recovery phrase has been cleared from the screen."
      cntools_ui_render_status info \
        "Check ${challenge_number} of 4 for ${name}: enter the requested word from your recorded backup."
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

# Returns 1 and sets the 1-based position of the first word that is not in
# the loaded BIP39 word list; 0 when all are known or the list is unavailable.
cntools_wallet_mnemonic_unknown_word_into() {
  local _cntools_unknown_output="${1:-}" _cntools_unknown_words="${2:-}" _cntools_unknown_index=0
  [[ "${_cntools_unknown_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_unknown_words}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_unknown_ref="${_cntools_unknown_output}"
  local -n _cntools_unknown_list="${_cntools_unknown_words}"
  _cntools_unknown_ref=0
  [[ "${CNTOOLS_WALLET_MNEMONIC_WORDLIST_READY:-N}" == Y ]] || return 0
  for (( _cntools_unknown_index = 0;
         _cntools_unknown_index < ${#_cntools_unknown_list[@]};
         _cntools_unknown_index++ )); do
    [[ -z "${CNTOOLS_WALLET_MNEMONIC_WORDSET[${_cntools_unknown_list[_cntools_unknown_index]}]+x}" ]] || continue
    _cntools_unknown_ref=$((_cntools_unknown_index + 1))
    return 1
  done
}

cntools_wallet_mnemonic_collect_pasted_into() {
  local -
  set +x # Recovery words must never reach an xtrace log.
  local _cntools_output_name="${1:-}"
  local _cntools_pasted_secret=""
  local _cntools_pasted_normalized=""
  local _cntools_feedback=""
  local _cntools_status=0
  local _cntools_position=0
  local -a _cntools_words=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  # Without the word list Cardano CLI still validates during derivation.
  cntools_wallet_mnemonic_wordlist_load || true
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "Mnemonic" "${CNTOOLS_MNEMONIC_INPUT_PATH:-/ Wallet / Import / Mnemonic}"
    cntools_ui_render_status info \
      "Paste all recovery words separated by spaces. Leading and trailing whitespace is ignored."
    [[ -z "${_cntools_feedback}" ]] ||
      cntools_ui_render_status warn "${_cntools_feedback}"
    if cntools_ui_password _cntools_pasted_secret "Recovery phrase"; then
      _cntools_status=0
    else
      _cntools_status=$?
    fi
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    _cntools_position=0
    if cntools_wallet_mnemonic_words_into \
         _cntools_words "${_cntools_pasted_secret}" &&
       cntools_wallet_mnemonic_unknown_word_into \
         _cntools_position _cntools_words &&
       cntools_wallet_mnemonic_phrase_into \
         _cntools_pasted_normalized _cntools_words; then
      _cntools_output_ref="${_cntools_pasted_normalized}"
      cntools_wallet_mnemonic_log CHOICE \
        "pasted recovery phrase accepted words=${#_cntools_words[@]}"
      unset _cntools_pasted_secret _cntools_pasted_normalized _cntools_words
      return 0
    fi
    if (( _cntools_position > 0 )); then
      # Never the word itself: the phrase is secret.
      _cntools_feedback="Word ${_cntools_position} is not in the BIP39 English word list. Check its spelling and paste the phrase again."
      cntools_wallet_mnemonic_log CHOICE \
        "pasted recovery phrase rejected: unknown word position=${_cntools_position}"
    else
      _cntools_feedback="Enter exactly 12, 15, 18, 21, or 24 alphabetic recovery words."
      cntools_wallet_mnemonic_log CHOICE \
        "pasted recovery phrase rejected by local shape validation"
    fi
    unset _cntools_pasted_secret _cntools_pasted_normalized _cntools_words
  done
}

# Word-by-word entry into a word array. Esc returns to the previous word (at
# the first word, to the length choice); Esc at the length choice returns 1.
cntools_wallet_mnemonic_collect_interactive_into() {
  local -
  set +x
  local _cntools_output_name="${1:-}"
  local _cntools_count_choice=""
  local _cntools_count=0
  local _cntools_index=0
  local _cntools_word=""
  local _cntools_status=0
  local -a _cntools_words=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=()
  cntools_wallet_mnemonic_wordlist_load || return 2
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "Mnemonic" "${CNTOOLS_MNEMONIC_INPUT_PATH:-/ Wallet / Import / Mnemonic}"
    if cntools_ui_choose _cntools_count_choice "Recovery phrase length…" \
        "12 words" "15 words" "18 words" "21 words" "24 words"; then
      :
    else
      return $?
    fi
    _cntools_count="${_cntools_count_choice%% *}"
    cntools_wallet_mnemonic_word_count_valid "${_cntools_count}" || return 2
    _cntools_words=()
    _cntools_index=1
    while (( _cntools_index >= 1 && _cntools_index <= _cntools_count )); do
      cntools_wallet_mnemonic_screen_begin \
        "Mnemonic" "${CNTOOLS_MNEMONIC_INPUT_PATH:-/ Wallet / Import / Mnemonic}"
      cntools_ui_render_status info \
        "Choose recovery word ${_cntools_index} of ${_cntools_count}. Type to filter; Esc returns to the previous word. Previous words are cleared as you continue."
      if cntools_wallet_mnemonic_select_word_into \
          _cntools_word "${_cntools_index}" "${_cntools_count}"; then
        _cntools_status=0
      else
        _cntools_status=$?
      fi
      case "${_cntools_status}" in
        0)
          _cntools_words[_cntools_index - 1]="${_cntools_word}"
          cntools_wallet_mnemonic_log CHOICE \
            "interactive recovery word selected position=${_cntools_index}"
          _cntools_index=$((_cntools_index + 1))
          ;;
        1)
          _cntools_index=$((_cntools_index - 1))
          cntools_wallet_mnemonic_log CHOICE \
            "interactive recovery word entry stepped back position=${_cntools_index}"
          ;;
        *) unset _cntools_words _cntools_word; return "${_cntools_status}" ;;
      esac
      unset _cntools_word
    done
    (( _cntools_index > _cntools_count )) && break
    # Esc at the first word: back to the length choice.
  done
  _cntools_output_ref=("${_cntools_words[@]}")
  cntools_wallet_mnemonic_log CHOICE \
    "interactive recovery phrase entered words=${_cntools_count}"
  unset _cntools_words
}

# After a checksum mismatch: correct one word in place (the words are kept)
# or start again. Returns 0 to check again, 4 to re-enter every word, 1 to
# cancel and 130 on Ctrl+C.
cntools_wallet_mnemonic_correct_into() {
  local -
  set +x
  local _cntools_correct_name="${1:-}"
  local _cntools_correct_choice=""
  local _cntools_correct_word=""
  local _cntools_correct_position=0
  local _cntools_correct_status=0
  local _cntools_correct_count=0
  local _cntools_correct_index=0
  local -a _cntools_correct_rows=()

  [[ "${_cntools_correct_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_correct_ref="${_cntools_correct_name}"
  _cntools_correct_count="${#_cntools_correct_ref[@]}"
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "Mnemonic" "${CNTOOLS_MNEMONIC_INPUT_PATH:-/ Wallet / Import / Mnemonic}"
    cntools_ui_render_status warn \
      "The recovery phrase checksum does not match: at least one of the ${_cntools_correct_count} words is wrong, most often the last one. Your words are kept; correct one or enter them all again."
    _cntools_correct_status=0
    cntools_ui_choose _cntools_correct_choice "Recovery phrase…" \
      "Re-enter word ${_cntools_correct_count} (the last word)" \
      "Re-enter another word" "Re-enter all words" Cancel ||
      _cntools_correct_status=$?
    (( _cntools_correct_status == 0 )) || return "${_cntools_correct_status}"
    case "${_cntools_correct_choice}" in
      "Re-enter word ${_cntools_correct_count} (the last word)")
        _cntools_correct_position="${_cntools_correct_count}" ;;
      "Re-enter another word")
        _cntools_correct_rows=()
        for ((_cntools_correct_index = 1;
              _cntools_correct_index < _cntools_correct_count;
              _cntools_correct_index++)); do
          _cntools_correct_rows+=("Word ${_cntools_correct_index}")
        done
        _cntools_correct_status=0
        cntools_ui_choose _cntools_correct_choice "Word to re-enter…" \
          "${_cntools_correct_rows[@]}" || _cntools_correct_status=$?
        (( _cntools_correct_status != 130 )) || return 130
        (( _cntools_correct_status == 0 )) || continue
        _cntools_correct_position="${_cntools_correct_choice#Word }"
        [[ "${_cntools_correct_position}" =~ ^[1-9][0-9]*$ &&
           _cntools_correct_position -lt _cntools_correct_count ]] || return 2
        ;;
      "Re-enter all words") return 4 ;;
      *) return 1 ;;
    esac
    cntools_wallet_mnemonic_screen_begin \
      "Mnemonic" "${CNTOOLS_MNEMONIC_INPUT_PATH:-/ Wallet / Import / Mnemonic}"
    cntools_ui_render_status info \
      "Choose the correct word ${_cntools_correct_position} of ${_cntools_correct_count}. Esc keeps the current word."
    _cntools_correct_status=0
    cntools_wallet_mnemonic_select_word_into _cntools_correct_word \
      "${_cntools_correct_position}" "${_cntools_correct_count}" ||
      _cntools_correct_status=$?
    case "${_cntools_correct_status}" in
      0)
        _cntools_correct_ref[_cntools_correct_position - 1]="${_cntools_correct_word}"
        unset _cntools_correct_word
        cntools_wallet_mnemonic_log CHOICE \
          "recovery word re-entered after checksum mismatch position=${_cntools_correct_position}"
        return 0
        ;;
      1) continue ;;
      *) return "${_cntools_correct_status}" ;;
    esac
  done
}

# Collects an existing recovery phrase, then checks its BIP39 checksum at
# once, before any plan or derivation. Shared by Wallet Import, Governance
# Derive Keys and MultiSig participant keys. Sets
# CNTOOLS_WALLET_MNEMONIC_CHECKSUM_VERIFIED=Y when the check passed (N when
# it could not run here; Cardano CLI then validates during derivation).
cntools_wallet_mnemonic_collect_import_into() {
  local -
  set +x # The phrase must never reach an xtrace log.
  local _cntools_output_name="${1:-}"
  local _cntools_method=""
  local _cntools_collected_phrase=""
  local _cntools_status=0
  local -a _cntools_collected_words=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  CNTOOLS_WALLET_MNEMONIC_CHECKSUM_VERIFIED="N"
  while true; do
    cntools_wallet_mnemonic_screen_begin \
      "Mnemonic" "${CNTOOLS_MNEMONIC_INPUT_PATH:-/ Wallet / Import / Mnemonic}"
    cntools_ui_render_status info \
      "Choose how to enter the existing recovery phrase."
    if cntools_ui_choose _cntools_method "Mnemonic input method…" \
        "Paste complete phrase" "Enter one word at a time"; then
      :
    else
      return $?
    fi
    _cntools_status=0
    _cntools_collected_words=()
    case "${_cntools_method}" in
      "Paste complete phrase")
        cntools_wallet_mnemonic_collect_pasted_into \
          _cntools_collected_phrase || _cntools_status=$?
        (( _cntools_status != 0 )) ||
          cntools_wallet_mnemonic_words_into \
            _cntools_collected_words "${_cntools_collected_phrase}" ||
          _cntools_status=2
        unset _cntools_collected_phrase
        ;;
      "Enter one word at a time")
        cntools_wallet_mnemonic_collect_interactive_into \
          _cntools_collected_words || _cntools_status=$?
        ;;
      *) return 2 ;;
    esac
    # Esc inside an input method returns to the method choice.
    (( _cntools_status != 1 )) || continue
    (( _cntools_status == 0 )) || return "${_cntools_status}"
    # Checked right after entry; a mismatch keeps the words for a correction.
    while true; do
      _cntools_status=0
      cntools_wallet_mnemonic_checksum_valid _cntools_collected_words ||
        _cntools_status=$?
      case "${_cntools_status}" in
        0)
          CNTOOLS_WALLET_MNEMONIC_CHECKSUM_VERIFIED="Y"
          cntools_wallet_mnemonic_log CHOICE \
            "recovery phrase checksum verified locally words=${#_cntools_collected_words[@]}"
          break 2
          ;;
        1)
          cntools_wallet_mnemonic_log CHOICE \
            "recovery phrase checksum mismatch words=${#_cntools_collected_words[@]}"
          _cntools_status=0
          cntools_wallet_mnemonic_correct_into _cntools_collected_words ||
            _cntools_status=$?
          case "${_cntools_status}" in
            0) continue ;;
            4) continue 2 ;;
            *) unset _cntools_collected_words; return "${_cntools_status}" ;;
          esac
          ;;
        *)
          cntools_wallet_mnemonic_log WARN \
            "recovery phrase checksum could not be checked locally; Cardano CLI validates it"
          break 2
          ;;
      esac
    done
  done
  cntools_wallet_mnemonic_phrase_into \
    _cntools_collected_phrase _cntools_collected_words || return 1
  _cntools_output_ref="${_cntools_collected_phrase}"
  unset _cntools_collected_phrase _cntools_collected_words
  cntools_gum_clear
  [[ ! -t 1 ]] || printf '\033[3J'
}

cntools_wallet_mnemonic_render_result() {
  local directory="${1:-}"
  local name="${2:-}"
  local account="${3:-0}"
  local key_index="${4:-0}"
  local origin="${5:-new}"
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
    # Only a fresh phrase is known to be unregistered; an import is not queried.
    if [[ "${origin}" == new ]]; then
      cntools_wallet_create_styled_row \
        "Stake registration" "Not registered" warning
    fi
    cntools_wallet_create_styled_row \
      "Payment path" "1852H/1815H/${account}H/0/${key_index}" identifier
    cntools_wallet_create_styled_row \
      "Stake path" "1852H/1815H/${account}H/2/${key_index}" identifier
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  cntools_ui_render_detail "Addresses" || return 1
  {
    printf 'Address type\tAddress\n'
    cntools_wallet_create_styled_row "Base" "${base_address}" address
    cntools_wallet_create_styled_row "Payment" "${payment_address}" address
    cntools_wallet_create_styled_row \
      "Stake / reward" "${reward_address}" address
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  cntools_ui_render_detail "Credentials" || return 1
  {
    printf 'Credential type\tCredential\n'
    cntools_wallet_create_styled_row \
      "Payment" "${payment_credential}" credential
    cntools_wallet_create_styled_row \
      "Stake" "${stake_credential}" credential
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
}

cntools_wallet_action_new_mnemonic() {
  local -
  set +x # The recovery phrase must never reach an xtrace log.
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
    (( status != 1 && status != 130 )) || {
      cntools_wallet_mnemonic_ui_cancelled \
        "new mnemonic wallet cancelled during settings"
      return 0
    }
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic wallet settings could not be collected (status ${status})." \
      "/ Wallet / New / Mnemonic"
    return 1
  fi
  while true; do
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
    status=0
    cntools_wallet_derivation_confirm "Generate the recovery phrase for ${name} now?" \
      'Generate recovery phrase' || status=$?
    (( status == 4 )) || break
    # Esc while changing keeps the shown values; Ctrl+C cancels.
    status=0
    cntools_wallet_mnemonic_prompt_derivation_into account key_index \
      "Mnemonic" "/ Wallet / New / Mnemonic" || status=$?
    (( status != 130 )) || return 130
  done
  if (( status == 0 )); then
    :
  else
    (( status != 1 && status != 130 )) || {
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
  # The plan was just reviewed: one line names the wallet, not the table again.
  cntools_ui_render_status info \
    "Recovery phrase for ${name} · payment 1852H/1815H/${account}H/0/${key_index} · stake 1852H/1815H/${account}H/2/${key_index}"
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
  if (( status == 1 || status == 130 )); then
    cntools_wallet_mnemonic_ui_cancelled \
      "new mnemonic wallet cancelled during backup verification wallet=${name}"
    unset phrase words
    return 0
  elif (( status != 0 )); then
    cntools_ui_render_status error \
      "Recovery phrase verification failed. The wallet was not created."
    cntools_ui_wait
    unset phrase words
    return 1
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
    return 1
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
  local -
  set +x # The recovery phrase must never reach an xtrace log.
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
    (( status != 1 && status != 130 )) || {
      cntools_wallet_mnemonic_ui_cancelled \
        "mnemonic import cancelled during settings"
      return 0
    }
    cntools_wallet_mnemonic_ui_failure \
      "The mnemonic import settings could not be collected (status ${status})." \
      "/ Wallet / Import / Mnemonic"
    return 1
  fi
  # A phrase Cardano CLI rejects is asked for again; name and derivation stay.
  while true; do
    if cntools_wallet_mnemonic_collect_import_into phrase; then
      :
    else
      status=$?
      (( status != 1 && status != 130 )) || {
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
    while true; do
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
      if [[ "${CNTOOLS_WALLET_MNEMONIC_CHECKSUM_VERIFIED}" == Y ]]; then
        cntools_ui_render_status info \
          "Recovery phrase checksum verified: ${word_count} words."
      else
        cntools_ui_render_status info \
          "Recovery phrase accepted locally: ${word_count} words. Cardano CLI checks its checksum during derivation."
      fi
      cntools_ui_render_status warn \
        "Only the selected payment and stake addresses are imported; this is a single-address CNTools wallet."
      status=0
      cntools_wallet_derivation_confirm "Import mnemonic wallet ${name} now?" 'Import wallet' || status=$?
      (( status == 4 )) || break
      status=0
      cntools_wallet_mnemonic_prompt_derivation_into account key_index \
        "Mnemonic" "/ Wallet / Import / Mnemonic" || status=$?
      (( status != 130 )) || { unset phrase; return 130; }
    done
    if (( status == 0 )); then
      :
    else
      unset phrase
      (( status != 1 && status != 130 )) || {
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
    (( status != 0 )) || break
    cntools_ui_render_status error \
      "${CNTOOLS_WALLET_MNEMONIC_ERROR:-Mnemonic wallet import failed. See ${CNTOOLS_LOG}.}"
    if [[ "${CNTOOLS_WALLET_MNEMONIC_PHRASE_REJECTED}" == Y ]]; then
      cntools_ui_render_status info \
        "Enter the recovery phrase again; the wallet name and derivation are kept."
      cntools_ui_wait
      cntools_wallet_mnemonic_log CHOICE "mnemonic import phrase re-entry wallet=${name}"
      continue
    fi
    cntools_ui_wait
    return 1
  done
  cntools_wallet_mnemonic_screen_begin \
    "Mnemonic" "/ Wallet / Import / Mnemonic"
  cntools_ui_render_status success \
    "Mnemonic wallet ${CNTOOLS_WALLET_CREATED_NAME} was imported successfully."
  cntools_wallet_mnemonic_render_result \
    "${CNTOOLS_WALLET_CREATED_DIRECTORY}" \
    "${CNTOOLS_WALLET_CREATED_NAME}" \
    "${CNTOOLS_WALLET_MNEMONIC_ACCOUNT}" \
    "${CNTOOLS_WALLET_MNEMONIC_KEY_INDEX}" import ||
    cntools_ui_render_status warn \
      "The wallet was imported, but its result details could not be displayed."
  [[ -z "${CNTOOLS_WALLET_CREATE_WARNING}" ]] ||
    cntools_ui_render_status warn "${CNTOOLS_WALLET_CREATE_WARNING}"
  cntools_ui_render_status warn \
    "Encrypt the imported signing keys when they are not in use."
  cntools_ui_wait
}
