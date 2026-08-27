#!/usr/bin/env bash
# CNTools terminal rendering and input. Functions only.
# Application globals are consumed by the menu renderer.
# shellcheck disable=SC2034

cntools_ui_init() {
  local locale_name="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"

  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="N"
  CNTOOLS_UI_CLEANED="N"
  CNTOOLS_UI_INPUT_ACTIVE="N"
  CNTOOLS_UI_SCREEN_ACTIVE="N"
  CNTOOLS_UI_USE_ALT_SCREEN="Y"
  CNTOOLS_UI_REPAINT_CAPABLE="N"
  CNTOOLS_UI_STTY=""
  CNTOOLS_UI_COLUMNS=80
  CNTOOLS_UI_DRAW_WIDTH=79
  CNTOOLS_UI_LINES=24
  CNTOOLS_UI_RESIZE_PENDING="Y"
  CNTOOLS_UI_TOO_SMALL="N"
  CNTOOLS_UI_CONTENT_ROW=4
  CNTOOLS_UI_UTF8="N"
  CNTOOLS_UI_RESET=""
  CNTOOLS_UI_BOLD=""
  CNTOOLS_UI_DIM=""
  CNTOOLS_UI_CYAN=""
  CNTOOLS_UI_GREEN=""
  CNTOOLS_UI_YELLOW=""
  CNTOOLS_UI_RED=""
  CNTOOLS_UI_CLEAR=""
  CNTOOLS_UI_HOME=""
  CNTOOLS_UI_ERASE_LINE=""
  CNTOOLS_UI_ERASE_DOWN=""
  CNTOOLS_UI_CURSOR_HIDE=""
  CNTOOLS_UI_CURSOR_SHOW=""
  CNTOOLS_UI_SCREEN_ENTER=""
  CNTOOLS_UI_SCREEN_LEAVE=""

  case "${locale_name}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) CNTOOLS_UI_UTF8="Y" ;;
  esac

  if [[ -t 0 && -t 1 ]]; then
    CNTOOLS_UI_STTY="$(stty -g 2>/dev/null || true)"
    [[ -z "${CNTOOLS_UI_STTY}" ]] || CNTOOLS_UI_INTERACTIVE="Y"
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
    CNTOOLS_UI_CLEAR="$(tput clear 2>/dev/null || true)"
    CNTOOLS_UI_HOME="$(tput home 2>/dev/null || true)"
    CNTOOLS_UI_ERASE_LINE="$(tput el 2>/dev/null || true)"
    CNTOOLS_UI_ERASE_DOWN="$(tput ed 2>/dev/null || true)"
    CNTOOLS_UI_CURSOR_HIDE="$(tput civis 2>/dev/null || true)"
    CNTOOLS_UI_CURSOR_SHOW="$(tput cnorm 2>/dev/null || true)"
    CNTOOLS_UI_SCREEN_ENTER="$(tput smcup 2>/dev/null || true)"
    CNTOOLS_UI_SCREEN_LEAVE="$(tput rmcup 2>/dev/null || true)"
    if [[ -z "${CNTOOLS_UI_SCREEN_ENTER}" ||
          -z "${CNTOOLS_UI_SCREEN_LEAVE}" ]]; then
      CNTOOLS_UI_SCREEN_ENTER=""
      CNTOOLS_UI_SCREEN_LEAVE=""
    fi
    if [[ -n "${CNTOOLS_UI_ERASE_LINE}" ]] &&
       tput cup 0 0 >/dev/null 2>&1; then
      CNTOOLS_UI_REPAINT_CAPABLE="Y"
    fi
  fi
  cntools_ui_dimensions
}

cntools_ui_dimensions() {
  [[ "${CNTOOLS_UI_RESIZE_PENDING:-Y}" == "Y" ]] || return 0
  CNTOOLS_UI_COLUMNS=80
  CNTOOLS_UI_LINES=24
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    CNTOOLS_UI_COLUMNS="$(tput cols 2>/dev/null || printf '80')"
    CNTOOLS_UI_LINES="$(tput lines 2>/dev/null || printf '24')"
  fi
  [[ "${CNTOOLS_UI_COLUMNS}" =~ ^[0-9]+$ ]] || CNTOOLS_UI_COLUMNS=80
  [[ "${CNTOOLS_UI_LINES}" =~ ^[0-9]+$ ]] || CNTOOLS_UI_LINES=24
  (( CNTOOLS_UI_COLUMNS > 0 )) || CNTOOLS_UI_COLUMNS=80
  (( CNTOOLS_UI_LINES > 0 )) || CNTOOLS_UI_LINES=24
  CNTOOLS_UI_TOO_SMALL="N"
  if (( CNTOOLS_UI_COLUMNS < 40 || CNTOOLS_UI_LINES < 10 )); then
    CNTOOLS_UI_TOO_SMALL="Y"
  fi
  if (( CNTOOLS_UI_COLUMNS > 1 )); then
    CNTOOLS_UI_DRAW_WIDTH=$((CNTOOLS_UI_COLUMNS - 1))
  else
    CNTOOLS_UI_DRAW_WIDTH=1
  fi
  CNTOOLS_UI_RESIZE_PENDING="N"
}

cntools_ui_mark_resize() {
  CNTOOLS_UI_RESIZE_PENDING="Y"
}

cntools_ui_fit() {
  local value="${1:-}"
  local width="${2:-80}"

  [[ "${width}" =~ ^[0-9]+$ ]] || width=80
  if (( ${#value} <= width )); then
    printf '%s' "${value}"
  elif (( width > 3 )); then
    printf '%s...' "${value:0:width-3}"
  fi
}

cntools_ui_repeat() {
  local character="${1:--}"
  local count="${2:-0}"
  local output=""

  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  (( count > 0 )) || return 0
  printf -v output '%*s' "${count}" ''
  printf '%s' "${output// /${character}}"
}

cntools_ui_path() {
  local value="${1:-/}"

  case "${value}" in
    CNTools) value="/" ;;
    'CNTools / '*) value="/ ${value#CNTools / }" ;;
    /*) ;;
    *) value="/ ${value}" ;;
  esac
  printf '%s' "${value}"
}

cntools_ui_runtime_context() {
  local separator=" | "

  [[ "${CNTOOLS_UI_UTF8:-N}" != "Y" ]] || separator=" · "
  printf '%s%s%s%s%s' \
    "${CNTOOLS_MODE:-unknown}" "${separator}" \
    "${CNTOOLS_BACKEND:-unknown}" "${separator}" \
    "${CNTOOLS_NETWORK:-unknown}"
}

cntools_ui_input_resume() {
  [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" ]] || return 0
  [[ "${CNTOOLS_UI_INPUT_ACTIVE:-N}" != "Y" ]] || return 0
  [[ -n "${CNTOOLS_UI_STTY:-}" ]] || return 1

  stty -echo -icanon min 1 time 0 2>/dev/null || return 1
  CNTOOLS_UI_INPUT_ACTIVE="Y"
}

cntools_ui_input_suspend() {
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" &&
        -n "${CNTOOLS_UI_STTY:-}" ]]; then
    stty "${CNTOOLS_UI_STTY}" 2>/dev/null || true
  fi
  CNTOOLS_UI_INPUT_ACTIVE="N"
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    if [[ -n "${CNTOOLS_UI_RESET:-}" ]]; then
      printf '%s' "${CNTOOLS_UI_RESET}"
    else
      tput sgr0 2>/dev/null || true
    fi
    if [[ -n "${CNTOOLS_UI_CURSOR_SHOW:-}" ]]; then
      printf '%s' "${CNTOOLS_UI_CURSOR_SHOW}"
    else
      tput cnorm 2>/dev/null || true
    fi
  fi
}

cntools_ui_session_enter() {
  [[ "${CNTOOLS_UI_CLEANED:-N}" != "Y" ]] || return 1
  cntools_ui_input_resume || return 1

  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    if [[ "${CNTOOLS_UI_SCREEN_ACTIVE:-N}" != "Y" &&
          "${CNTOOLS_UI_USE_ALT_SCREEN:-Y}" == "Y" &&
          -n "${CNTOOLS_UI_SCREEN_ENTER:-}" ]]; then
      printf '%s' "${CNTOOLS_UI_SCREEN_ENTER}"
      CNTOOLS_UI_SCREEN_ACTIVE="Y"
    fi
    if [[ -n "${CNTOOLS_UI_CURSOR_HIDE:-}" ]]; then
      printf '%s' "${CNTOOLS_UI_CURSOR_HIDE}"
    else
      tput civis 2>/dev/null || true
    fi
  fi
}

cntools_ui_suspend_for_job_control() {
  local process_id="${BASHPID:-$$}"

  # SIGTSTP must never return control to the invoking shell while CNTools owns
  # raw input, a hidden cursor, or the alternate screen. Restore first, stop
  # with the default disposition, then prepare a complete redraw on resume.
  cntools_ui_restore_terminal
  trap - TSTP
  if ! kill -s TSTP "${process_id}" 2>/dev/null; then
    trap 'cntools_ui_suspend_for_job_control' TSTP
    return 1
  fi
  trap 'cntools_ui_suspend_for_job_control' TSTP
  cntools_ui_mark_resize
}

cntools_ui_screen_begin() {
  cntools_ui_session_enter || return 1
  cntools_ui_dimensions

  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    printf '%s' "${CNTOOLS_UI_RESET:-}"
    if [[ -n "${CNTOOLS_UI_HOME:-}" &&
          -n "${CNTOOLS_UI_ERASE_DOWN:-}" ]]; then
      printf '%s%s' "${CNTOOLS_UI_HOME}" "${CNTOOLS_UI_ERASE_DOWN}"
    else
      printf '%s' "${CNTOOLS_UI_CLEAR:-}"
    fi
  else
    printf '\n'
  fi
}

cntools_ui_cursor_to() {
  local row="${1:-0}"
  local column="${2:-0}"

  [[ "${row}" =~ ^[0-9]+$ && "${column}" =~ ^[0-9]+$ ]] || return 2
  [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]] || return 1
  tput cup "${row}" "${column}" 2>/dev/null
}

cntools_ui_erase_line() {
  [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]] || return 0
  if [[ -n "${CNTOOLS_UI_ERASE_LINE:-}" ]]; then
    printf '%s' "${CNTOOLS_UI_ERASE_LINE}"
  fi
}

cntools_ui_render_divider() {
  local character="-"

  [[ "${CNTOOLS_UI_UTF8:-N}" != "Y" ]] || character="─"
  printf '%s%s%s\n' "${CNTOOLS_UI_DIM:-}" \
    "$(cntools_ui_repeat "${character}" "${CNTOOLS_UI_DRAW_WIDTH:-79}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_render_begin() {
  local _label="${1:-CNTools}"
  local breadcrumb="${2:-/}"
  local title="CNTools v${CNTOOLS_VERSION:-?}"
  local path=""
  local runtime_context=""
  local size_notice=""
  local padding=0

  : "${_label}"
  cntools_ui_screen_begin || return 1
  path="$(cntools_ui_path "${breadcrumb}")"
  runtime_context="$(cntools_ui_runtime_context)"

  if [[ "${CNTOOLS_UI_TOO_SMALL:-N}" == "Y" ]]; then
    size_notice="Terminal too small: ${CNTOOLS_UI_COLUMNS}x${CNTOOLS_UI_LINES}; minimum 40x10"
    printf '%s%s%s\n' "${CNTOOLS_UI_BOLD:-}" \
      "$(cntools_ui_fit "${title}" "${CNTOOLS_UI_DRAW_WIDTH}")" \
      "${CNTOOLS_UI_RESET:-}"
    printf '%s%s%s\n' "${CNTOOLS_UI_YELLOW:-}" \
      "$(cntools_ui_fit "${size_notice}" "${CNTOOLS_UI_DRAW_WIDTH}")" \
      "${CNTOOLS_UI_RESET:-}"
    CNTOOLS_UI_CONTENT_ROW=2
    return 0
  fi

  if (( ${#title} + ${#runtime_context} + 4 <= CNTOOLS_UI_DRAW_WIDTH )); then
    padding=$((CNTOOLS_UI_DRAW_WIDTH - ${#title} - ${#runtime_context}))
    printf '%s%s%s%*s%s%s%s\n' \
      "${CNTOOLS_UI_BOLD:-}" "${title}" "${CNTOOLS_UI_RESET:-}" \
      "${padding}" '' "${CNTOOLS_UI_DIM:-}" "${runtime_context}" \
      "${CNTOOLS_UI_RESET:-}"
    printf '%s%s%s\n' "${CNTOOLS_UI_CYAN:-}" \
      "$(cntools_ui_fit "${path}" "${CNTOOLS_UI_DRAW_WIDTH}")" \
      "${CNTOOLS_UI_RESET:-}"
    CNTOOLS_UI_CONTENT_ROW=4
  else
    printf '%s%s%s\n' "${CNTOOLS_UI_BOLD:-}" "${title}" \
      "${CNTOOLS_UI_RESET:-}"
    printf '%s%s%s\n' "${CNTOOLS_UI_CYAN:-}" \
      "$(cntools_ui_fit "${path}" "${CNTOOLS_UI_DRAW_WIDTH}")" \
      "${CNTOOLS_UI_RESET:-}"
    printf '%s%s%s\n' "${CNTOOLS_UI_DIM:-}" \
      "$(cntools_ui_fit "${runtime_context}" "${CNTOOLS_UI_DRAW_WIDTH}")" \
      "${CNTOOLS_UI_RESET:-}"
    CNTOOLS_UI_CONTENT_ROW=5
  fi
  cntools_ui_render_divider
  printf '\n'
}

cntools_ui_render_row() {
  local selected="${1:-N}"
  local enabled="${2:-Y}"
  local shortcut="${3:-?}"
  local label="${4:-Unnamed}"
  local description="${5:-}"
  local marker=" "
  local line=""

  if [[ "${selected}" == "Y" ]]; then
    if [[ "${CNTOOLS_UI_UTF8:-N}" == "Y" ]]; then
      marker="›"
    else
      marker=">"
    fi
  fi
  line="${marker} [${shortcut}] ${label}"
  [[ -z "${description}" ]] || line+="  ${description}"
  [[ "${enabled}" == "Y" ]] || line+="  (unavailable)"
  line="$(cntools_ui_fit "${line}" "${CNTOOLS_UI_DRAW_WIDTH:-79}")"

  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    if [[ "${selected}" == "Y" && "${enabled}" == "Y" ]]; then
      printf '%s%s%s%s\n' "${CNTOOLS_UI_CYAN}" "${CNTOOLS_UI_BOLD}" \
        "${line}" "${CNTOOLS_UI_RESET}"
    elif [[ "${selected}" == "Y" ]]; then
      printf '%s%s%s\n' "${CNTOOLS_UI_YELLOW}" "${line}" \
        "${CNTOOLS_UI_RESET}"
    elif [[ "${enabled}" != "Y" ]]; then
      printf '%s%s%s\n' "${CNTOOLS_UI_DIM}" "${line}" \
        "${CNTOOLS_UI_RESET}"
    else
      printf '%s\n' "${line}"
    fi
  else
    printf '%s\n' "${line}"
  fi
}

cntools_ui_repaint_row() {
  local row="${1:-}"

  [[ "${row}" =~ ^[0-9]+$ ]] || return 2
  shift
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" != "Y" ]]; then
    cntools_ui_render_row "$@"
    return
  fi
  cntools_ui_cursor_to "${row}" 0 || return 1
  cntools_ui_erase_line
  cntools_ui_render_row "$@"
}

cntools_ui_render_empty() {
  printf '%sNo actions are available in this menu.%s\n' \
    "${CNTOOLS_UI_DIM:-}" "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_render_field() {
  local label="${1:-}"
  local value="${2:-}"
  local label_width="${3:-10}"
  local label_text=""
  local value_width=0

  [[ "${label_width}" =~ ^[0-9]+$ ]] || label_width=10
  (( label_width > 0 )) || label_width=1
  label_text="$(cntools_ui_fit "${label}:" "${label_width}")"
  printf -v label_text '%-*s' "${label_width}" "${label_text}"
  value_width=$((${CNTOOLS_UI_DRAW_WIDTH:-79} - label_width - 2))
  if (( value_width < 1 )); then
    printf '%s\n' "$(cntools_ui_fit "${label}: ${value}" \
      "${CNTOOLS_UI_DRAW_WIDTH:-79}")"
    return 0
  fi
  printf '%s%s%s  %s\n' \
    "${CNTOOLS_UI_BOLD:-}" "${label_text}" "${CNTOOLS_UI_RESET:-}" \
    "$(cntools_ui_fit "${value}" "${value_width}")"
}

cntools_ui_render_detail() {
  local description="${1:-}"
  local line="  ${description}"

  printf '%s%s%s\n' "${CNTOOLS_UI_DIM:-}" \
    "$(cntools_ui_fit "${line}" "${CNTOOLS_UI_DRAW_WIDTH:-79}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_repaint_detail() {
  local row="${1:-}"
  local description="${2:-}"

  [[ "${row}" =~ ^[0-9]+$ ]] || return 2
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" != "Y" ]]; then
    cntools_ui_render_detail "${description}"
    return
  fi
  cntools_ui_cursor_to "${row}" 0 || return 1
  cntools_ui_erase_line
  cntools_ui_render_detail "${description}"
}

cntools_ui_status_color() {
  case "${1:-info}" in
    error) printf '%s' "${CNTOOLS_UI_RED:-}" ;;
    warn) printf '%s' "${CNTOOLS_UI_YELLOW:-}" ;;
    success) printf '%s' "${CNTOOLS_UI_GREEN:-}" ;;
    *) printf '%s' "${CNTOOLS_UI_CYAN:-}" ;;
  esac
}

cntools_ui_render_status() {
  local level="${1:-info}"
  local message="${2:-}"
  local color=""

  [[ -n "${message}" ]] || return 0
  color="$(cntools_ui_status_color "${level}")"
  printf '\n%s%s%s\n' "${color}" \
    "$(cntools_ui_fit "${message}" "${CNTOOLS_UI_DRAW_WIDTH:-79}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_repaint_status() {
  local row="${1:-}"
  local level="${2:-info}"
  local message="${3:-}"
  local color=""

  [[ "${row}" =~ ^[0-9]+$ ]] || return 2
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" != "Y" ]]; then
    cntools_ui_render_status "${level}" "${message}"
    return
  fi
  cntools_ui_cursor_to "${row}" 0 || return 1
  cntools_ui_erase_line
  [[ -n "${message}" ]] || return 0
  color="$(cntools_ui_status_color "${level}")"
  printf '%s%s%s' "${color}" \
    "$(cntools_ui_fit "${message}" "${CNTOOLS_UI_DRAW_WIDTH:-79}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_footer_text() {
  local nested="${1:-N}"

  if [[ "${CNTOOLS_UI_UTF8:-N}" == "Y" ]]; then
    if [[ "${nested}" == "Y" ]]; then
      printf '↑↓ Move  Enter Open  Esc Back  h Root'
    else
      printf '↑↓ Move  Enter Open  r Reload  q Quit'
    fi
  elif [[ "${nested}" == "Y" ]]; then
    printf 'Up/Down Move  Enter Open  Esc Back  h Root'
  else
    printf 'Up/Down Move  Enter Open  r Reload  q Quit'
  fi
}

cntools_ui_render_footer() {
  local nested="${1:-N}"

  printf '\n%s%s%s\n' "${CNTOOLS_UI_DIM:-}" \
    "$(cntools_ui_fit "$(cntools_ui_footer_text "${nested}")" \
      "${CNTOOLS_UI_DRAW_WIDTH:-79}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_repaint_footer() {
  local nested="${1:-N}"
  local row="${2:-}"

  if [[ -z "${row}" ]]; then
    cntools_ui_dimensions
    row=$((CNTOOLS_UI_LINES - 1))
  fi
  [[ "${row}" =~ ^[0-9]+$ ]] || return 2
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" != "Y" ]]; then
    cntools_ui_render_footer "${nested}"
    return
  fi
  cntools_ui_cursor_to "${row}" 0 || return 1
  cntools_ui_erase_line
  printf '%s%s%s' "${CNTOOLS_UI_DIM:-}" \
    "$(cntools_ui_fit "$(cntools_ui_footer_text "${nested}")" \
      "${CNTOOLS_UI_DRAW_WIDTH:-79}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_ui_action_begin() {
  local label="${1:-Action}"
  local breadcrumb="${2:-/}"

  cntools_ui_render_begin "${label}" "${breadcrumb}"
}

cntools_ui_confirm() {
  local prompt="${1:-Continue?}"
  local response=""

  cntools_ui_input_suspend
  printf '%s [y/N]: ' "${prompt}"
  IFS= read -r response || return 1
  case "${response,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

cntools_ui_wait() {
  [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" ]] || return 0
  cntools_ui_input_suspend
  printf '\nPress Enter to return...'
  IFS= read -r _ || true
}

cntools_ui_read_escape() {
  local output_variable="${1:-}"
  local next=""
  local sequence=""
  local decoded="escape"
  local index=0

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  if ! IFS= read -rsn1 -t 0.06 next || [[ -z "${next}" ]]; then
    printf -v "${output_variable}" '%s' "${decoded}"
    return 0
  fi

  case "${next}" in
    '['|'O')
      sequence="${next}"
      for (( index = 0; index < 15; index++ )); do
        if ! IFS= read -rsn1 -t 0.06 next || [[ -z "${next}" ]]; then
          decoded="ignore"
          break
        fi
        sequence+="${next}"
        case "${next}" in
          [A-Za-z~]) break ;;
        esac
      done
      case "${sequence}" in
        \[*A|O*A) decoded="up" ;;
        \[*B|O*B) decoded="down" ;;
        \[*C|O*C) decoded="right" ;;
        \[*D|O*D) decoded="left" ;;
        '[H'|'[1~'|'[7~'|'OH') decoded="home" ;;
        '[F'|'[4~'|'[8~'|'OF') decoded="end" ;;
        '[5~') decoded="page_up" ;;
        '[6~') decoded="page_down" ;;
        *) decoded="ignore" ;;
      esac
      ;;
    *) decoded="ignore" ;;
  esac
  printf -v "${output_variable}" '%s' "${decoded}"
}

cntools_ui_read_key() {
  local output_variable="${1:-}"
  local raw_key=""
  local mapped=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" ]]; then
    if [[ "${CNTOOLS_UI_RESIZE_PENDING:-N}" == "Y" ]]; then
      printf -v "${output_variable}" '%s' resize
      return 0
    fi
    cntools_ui_input_resume || return 1
    if ! IFS= read -rsn1 raw_key; then
      if [[ "${CNTOOLS_UI_RESIZE_PENDING:-N}" == "Y" && -t 0 ]]; then
        mapped="resize"
      else
        mapped="quit"
      fi
    elif [[ -z "${raw_key}" || "${raw_key}" == $'\r' ]]; then
      mapped="enter"
    elif [[ "${raw_key}" == $'\033' ]]; then
      cntools_ui_read_escape mapped || return 1
    elif [[ "${raw_key}" == $'\177' || "${raw_key}" == $'\b' ]]; then
      mapped="backspace"
    else
      mapped="${raw_key}"
    fi
  else
    if ! IFS= read -r raw_key; then
      mapped="quit"
    else
      case "${raw_key}" in
        ''|enter) mapped="enter" ;;
        up|down|left|right|home|end|page_up|page_down|backspace)
          mapped="${raw_key}"
          ;;
        esc|escape) mapped="escape" ;;
        *) mapped="${raw_key:0:1}" ;;
      esac
    fi
  fi
  printf -v "${output_variable}" '%s' "${mapped}"
}

cntools_ui_restore_terminal() {
  cntools_ui_input_suspend
  if [[ "${CNTOOLS_UI_CAPABLE:-N}" == "Y" ]]; then
    if [[ "${CNTOOLS_UI_SCREEN_ACTIVE:-N}" == "Y" &&
          -n "${CNTOOLS_UI_SCREEN_LEAVE:-}" ]]; then
      printf '%s' "${CNTOOLS_UI_SCREEN_LEAVE}"
    fi
  fi
  CNTOOLS_UI_SCREEN_ACTIVE="N"
}

cntools_ui_cleanup() {
  [[ "${CNTOOLS_UI_CLEANED:-N}" != "Y" ]] || return 0
  cntools_ui_restore_terminal
  CNTOOLS_UI_CLEANED="Y"
}
