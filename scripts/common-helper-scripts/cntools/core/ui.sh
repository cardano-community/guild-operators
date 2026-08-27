#!/usr/bin/env bash
# CNTools terminal rendering and input. Functions only.

cntools_ui_init() {
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="N"
  CNTOOLS_UI_CLEANED="N"
  CNTOOLS_UI_STTY=""
  CNTOOLS_UI_RESET=""
  CNTOOLS_UI_BOLD=""
  CNTOOLS_UI_DIM=""
  CNTOOLS_UI_CYAN=""
  CNTOOLS_UI_GREEN=""
  CNTOOLS_UI_YELLOW=""
  CNTOOLS_UI_RED=""
  CNTOOLS_UI_REVERSE=""

  if [[ -t 0 && -t 1 ]]; then
    CNTOOLS_UI_INTERACTIVE="Y"
    CNTOOLS_UI_STTY="$(stty -g 2>/dev/null || true)"
  fi
  if [[ "${CNTOOLS_UI_INTERACTIVE}" == "Y" &&
        "${TERM:-dumb}" != "dumb" ]] &&
     tput clear >/dev/null 2>&1 &&
     tput civis >/dev/null 2>&1 &&
     tput cnorm >/dev/null 2>&1 &&
     tput sgr0 >/dev/null 2>&1; then
    CNTOOLS_UI_CAPABLE="Y"
    CNTOOLS_UI_RESET="$(tput sgr0 2>/dev/null || true)"
    CNTOOLS_UI_BOLD="$(tput bold 2>/dev/null || true)"
    CNTOOLS_UI_DIM="$(tput dim 2>/dev/null || true)"
    CNTOOLS_UI_CYAN="$(tput setaf 6 2>/dev/null || true)"
    CNTOOLS_UI_GREEN="$(tput setaf 2 2>/dev/null || true)"
    CNTOOLS_UI_YELLOW="$(tput setaf 3 2>/dev/null || true)"
    CNTOOLS_UI_RED="$(tput setaf 1 2>/dev/null || true)"
    CNTOOLS_UI_REVERSE="$(tput rev 2>/dev/null || true)"
    tput civis 2>/dev/null || true
  fi
}

cntools_ui_dimensions() {
  CNTOOLS_UI_COLUMNS=80
  CNTOOLS_UI_LINES=24
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    CNTOOLS_UI_COLUMNS="$(tput cols 2>/dev/null || printf '80')"
    CNTOOLS_UI_LINES="$(tput lines 2>/dev/null || printf '24')"
  fi
  [[ "${CNTOOLS_UI_COLUMNS}" =~ ^[0-9]+$ ]] || CNTOOLS_UI_COLUMNS=80
  [[ "${CNTOOLS_UI_LINES}" =~ ^[0-9]+$ ]] || CNTOOLS_UI_LINES=24
  (( CNTOOLS_UI_COLUMNS >= 40 )) || CNTOOLS_UI_COLUMNS=40
  (( CNTOOLS_UI_LINES >= 10 )) || CNTOOLS_UI_LINES=10
}

cntools_ui_fit() {
  local value="${1:-}"
  local width="${2:-80}"
  if (( ${#value} <= width )); then
    printf '%s' "${value}"
  elif (( width > 3 )); then
    printf '%s...' "${value:0:width-3}"
  fi
}

cntools_ui_render_begin() {
  local label="${1:-CNTools}"
  local breadcrumb="${2:-CNTools}"
  local session_line=""

  cntools_ui_dimensions
  session_line="Mode: ${CNTOOLS_MODE:-unknown}  Backend: ${CNTOOLS_BACKEND:-unknown}  Network: ${CNTOOLS_NETWORK:-unknown}"
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    tput civis 2>/dev/null || true
    tput clear 2>/dev/null || true
    printf '%s%s%s  %s%s%s\n' \
      "${CNTOOLS_UI_BOLD}" "${label}" "${CNTOOLS_UI_RESET}" \
      "${CNTOOLS_UI_DIM}" "v${CNTOOLS_VERSION:-?}" "${CNTOOLS_UI_RESET}"
    printf '%s%s%s\n' "${CNTOOLS_UI_CYAN}" \
      "$(cntools_ui_fit "${breadcrumb}" "${CNTOOLS_UI_COLUMNS}")" \
      "${CNTOOLS_UI_RESET}"
    printf '%s%s%s\n\n' "${CNTOOLS_UI_DIM}" \
      "$(cntools_ui_fit "${session_line}" "${CNTOOLS_UI_COLUMNS}")" \
      "${CNTOOLS_UI_RESET}"
  else
    printf '\n%s v%s\n%s\n%s\n\n' \
      "${label}" "${CNTOOLS_VERSION:-?}" "${breadcrumb}" "${session_line}"
  fi
}

cntools_ui_render_row() {
  local selected="${1:-N}"
  local enabled="${2:-Y}"
  local shortcut="${3:-?}"
  local label="${4:-Unnamed}"
  local description="${5:-}"
  local marker=" "
  local line=""

  [[ "${selected}" == "Y" ]] && marker=">"
  line="${marker} [${shortcut}] ${label}"
  [[ -n "${description}" ]] && line+=" — ${description}"
  if [[ "${enabled}" != "Y" ]]; then
    line+=" (unavailable in ${CNTOOLS_MODE:-this} mode)"
  fi
  line="$(cntools_ui_fit "${line}" "${CNTOOLS_UI_COLUMNS:-80}")"

  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    if [[ "${selected}" == "Y" ]]; then
      printf '%s%s%s\n' "${CNTOOLS_UI_REVERSE}" "${line}" "${CNTOOLS_UI_RESET}"
    elif [[ "${enabled}" != "Y" ]]; then
      printf '%s%s%s\n' "${CNTOOLS_UI_DIM}" "${line}" "${CNTOOLS_UI_RESET}"
    else
      printf '%s\n' "${line}"
    fi
  else
    printf '%s\n' "${line}"
  fi
}

cntools_ui_render_empty() {
  printf '%sNo actions are available in this menu.%s\n' \
    "${CNTOOLS_UI_DIM:-}" "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_render_status() {
  local level="${1:-info}"
  local message="${2:-}"
  local color="${CNTOOLS_UI_CYAN:-}"

  [[ -n "${message}" ]] || return 0
  case "${level}" in
    error) color="${CNTOOLS_UI_RED:-}" ;;
    warn) color="${CNTOOLS_UI_YELLOW:-}" ;;
    success) color="${CNTOOLS_UI_GREEN:-}" ;;
  esac
  printf '\n%s%s%s\n' "${color}" \
    "$(cntools_ui_fit "${message}" "${CNTOOLS_UI_COLUMNS:-80}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_render_footer() {
  local nested="${1:-N}"
  if [[ "${nested}" == "Y" ]]; then
    printf '\n%s↑/↓ Navigate  Enter Open  Esc Back  h Home%s\n' \
      "${CNTOOLS_UI_DIM:-}" "${CNTOOLS_UI_RESET:-}"
  else
    printf '\n%s↑/↓ Navigate  Enter Open  r Refresh  q Quit%s\n' \
      "${CNTOOLS_UI_DIM:-}" "${CNTOOLS_UI_RESET:-}"
  fi
}

cntools_ui_action_begin() {
  local label="${1:-Action}"
  local breadcrumb="${2:-CNTools}"

  cntools_ui_render_begin "${label}" "${breadcrumb}"
}

cntools_ui_confirm() {
  local prompt="${1:-Continue?}"
  local response=""

  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    tput cnorm 2>/dev/null || true
  fi
  printf '%s [y/N]: ' "${prompt}"
  IFS= read -r response || return 1
  case "${response,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

cntools_ui_wait() {
  [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" ]] || return 0
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    tput cnorm 2>/dev/null || true
  fi
  printf '\nPress Enter to return...'
  IFS= read -r _ || true
}

cntools_ui_read_key() {
  local output_variable="${1:-}"
  local raw_key=""
  local tail=""
  local mapped=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" ]]; then
    if ! IFS= read -rsn1 raw_key; then
      mapped="quit"
    elif [[ -z "${raw_key}" ]]; then
      mapped="enter"
    elif [[ "${raw_key}" == $'\033' ]]; then
      IFS= read -rsn2 -t 0.08 tail || true
      case "${tail}" in
        '[A') mapped="up" ;;
        '[B') mapped="down" ;;
        *) mapped="escape" ;;
      esac
    else
      mapped="${raw_key}"
    fi
  else
    if ! IFS= read -r raw_key; then
      mapped="quit"
    else
      case "${raw_key}" in
        ''|enter) mapped="enter" ;;
        up) mapped="up" ;;
        down) mapped="down" ;;
        esc|escape) mapped="escape" ;;
        *) mapped="${raw_key:0:1}" ;;
      esac
    fi
  fi
  printf -v "${output_variable}" '%s' "${mapped}"
}

cntools_ui_restore_terminal() {
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" &&
        -n "${CNTOOLS_UI_STTY:-}" ]]; then
    stty "${CNTOOLS_UI_STTY}" 2>/dev/null || true
  fi
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    tput sgr0 2>/dev/null || true
    tput cnorm 2>/dev/null || true
  fi
}

cntools_ui_cleanup() {
  [[ "${CNTOOLS_UI_CLEANED:-N}" != "Y" ]] || return 0
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" &&
        -n "${CNTOOLS_UI_STTY:-}" ]]; then
    stty "${CNTOOLS_UI_STTY}" 2>/dev/null || true
  fi
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    tput sgr0 2>/dev/null || true
    tput cnorm 2>/dev/null || true
  fi
  CNTOOLS_UI_CLEANED="Y"
}
