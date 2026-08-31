#!/usr/bin/env bash
# Semantic CNTools themes, value styling, and persistent theme selection.
# Functions only; sourced before the Gum presentation layer.
# shellcheck disable=SC2034

declare -ag CNTOOLS_THEME_IDS=(default)
declare -Ag CNTOOLS_THEME_NAMES=([default]="Default")

CNTOOLS_THEME_ID="default"
CNTOOLS_THEME_STATE_DIR=""
CNTOOLS_THEME_STATE_FILE=""
CNTOOLS_THEME_STAGE_FILE=""

cntools_theme_log() {
  if declare -F cntools_log >/dev/null 2>&1; then
    cntools_log "${1:-INFO}" "${2:-}" || true
  fi
}

cntools_theme_valid() {
  case "${1:-}" in
    default) return 0 ;;
    *) return 1 ;;
  esac
}

cntools_theme_apply() {
  local theme_id="${1:-default}"

  cntools_theme_valid "${theme_id}" || return 2
  case "${theme_id}" in
    default)
      CNTOOLS_THEME_COLOR_CANVAS="#1B1B1F"
      CNTOOLS_THEME_COLOR_DEEP="#161618"
      CNTOOLS_THEME_COLOR_SURFACE="#202127"
      CNTOOLS_THEME_COLOR_DIVIDER="#2E2E32"
      CNTOOLS_THEME_COLOR_TEXT="#DFDFD6"
      CNTOOLS_THEME_COLOR_MUTED="#98989F"
      CNTOOLS_THEME_COLOR_QUIET="#6A6A71"
      CNTOOLS_THEME_COLOR_ACCENT="#4FBC85"
      CNTOOLS_THEME_COLOR_ACCENT_DARK="#2D8A56"
      CNTOOLS_THEME_COLOR_SUCCESS="#3DD68C"
      CNTOOLS_THEME_COLOR_WARNING="#F9B44E"
      CNTOOLS_THEME_COLOR_DANGER="#F66F81"
      # Keep data accents restrained: one cool tone for identifiers and one
      # warm-neutral tone for numeric values.
      CNTOOLS_THEME_COLOR_IDENTIFIER="#78BFD0"
      CNTOOLS_THEME_COLOR_NUMBER="#D8BC7A"
      ;;
  esac

  CNTOOLS_THEME_ID="${theme_id}"

  # Compatibility aliases keep the Gum implementation decoupled from theme
  # definitions while the semantic roles remain available to action views.
  CNTOOLS_GUM_COLOR_CANVAS="${CNTOOLS_THEME_COLOR_CANVAS}"
  CNTOOLS_GUM_COLOR_DEEP="${CNTOOLS_THEME_COLOR_DEEP}"
  CNTOOLS_GUM_COLOR_SURFACE="${CNTOOLS_THEME_COLOR_SURFACE}"
  CNTOOLS_GUM_COLOR_DIVIDER="${CNTOOLS_THEME_COLOR_DIVIDER}"
  CNTOOLS_GUM_COLOR_TEXT="${CNTOOLS_THEME_COLOR_TEXT}"
  CNTOOLS_GUM_COLOR_MUTED="${CNTOOLS_THEME_COLOR_MUTED}"
  CNTOOLS_GUM_COLOR_QUIET="${CNTOOLS_THEME_COLOR_QUIET}"
  CNTOOLS_GUM_COLOR_BRAND="${CNTOOLS_THEME_COLOR_ACCENT}"
  CNTOOLS_GUM_COLOR_BRAND_DARK="${CNTOOLS_THEME_COLOR_ACCENT_DARK}"
  CNTOOLS_GUM_COLOR_SUCCESS="${CNTOOLS_THEME_COLOR_SUCCESS}"
  CNTOOLS_GUM_COLOR_WARNING="${CNTOOLS_THEME_COLOR_WARNING}"
  CNTOOLS_GUM_COLOR_DANGER="${CNTOOLS_THEME_COLOR_DANGER}"
}

cntools_theme_state_paths() {
  local node_home="${CNTOOLS_NODE_HOME:-}"

  CNTOOLS_THEME_STATE_DIR=""
  CNTOOLS_THEME_STATE_FILE=""
  [[ -n "${node_home}" && "${node_home}" = /* && "${node_home}" != "/" &&
     -d "${node_home}" && ! -L "${node_home}" && -O "${node_home}" &&
     -w "${node_home}" && "${node_home}" != *$'\n'* &&
     "${node_home}" != *$'\r'* ]] || return 1
  CNTOOLS_THEME_STATE_DIR="${node_home}/.cntools"
  CNTOOLS_THEME_STATE_FILE="${CNTOOLS_THEME_STATE_DIR}/theme"
}

cntools_theme_private_path() {
  local path="${1:-}"
  local mode=""
  local permissions=0

  [[ -n "${path}" && ! -L "${path}" ]] || return 1
  if mode="$(stat -c '%a' -- "${path}" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "${path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  while (( ${#mode} > 3 )) && [[ "${mode:0:1}" == "0" ]]; do
    mode="${mode:1}"
  done
  permissions=$((8#${mode}))
  (( (permissions & 077) == 0 ))
}

cntools_theme_state_directory_safe() {
  [[ -n "${CNTOOLS_THEME_STATE_DIR:-}" &&
     "${CNTOOLS_THEME_STATE_DIR}" == "${CNTOOLS_NODE_HOME}/.cntools" &&
     -d "${CNTOOLS_THEME_STATE_DIR}" &&
     ! -L "${CNTOOLS_THEME_STATE_DIR}" &&
     -O "${CNTOOLS_THEME_STATE_DIR}" ]] || return 1
  cntools_theme_private_path "${CNTOOLS_THEME_STATE_DIR}"
}

cntools_theme_state_directory_ready() {
  local previous_umask=""

  [[ -n "${CNTOOLS_THEME_STATE_DIR:-}" &&
     "${CNTOOLS_THEME_STATE_DIR}" == "${CNTOOLS_NODE_HOME}/.cntools" ]] ||
    return 1
  if [[ ! -e "${CNTOOLS_THEME_STATE_DIR}" &&
        ! -L "${CNTOOLS_THEME_STATE_DIR}" ]]; then
    previous_umask="$(umask)"
    umask 077
    if mkdir -- "${CNTOOLS_THEME_STATE_DIR}"; then
      umask "${previous_umask}"
    else
      umask "${previous_umask}"
      return 1
    fi
  fi
  [[ -d "${CNTOOLS_THEME_STATE_DIR}" &&
     ! -L "${CNTOOLS_THEME_STATE_DIR}" &&
     -O "${CNTOOLS_THEME_STATE_DIR}" ]] || return 1
  chmod 0700 "${CNTOOLS_THEME_STATE_DIR}" || return 1
  cntools_theme_state_directory_safe || return 1
  [[ -w "${CNTOOLS_THEME_STATE_DIR}" ]] || return 1
}

cntools_theme_read_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_theme_file="${CNTOOLS_THEME_STATE_FILE:-}"
  local _cntools_nul_probe=""
  local _cntools_size=""
  local -a _cntools_lines=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_theme_state_directory_safe || return 1
  [[ -n "${_cntools_theme_file}" &&
     "${_cntools_theme_file}" == "${CNTOOLS_THEME_STATE_DIR:-/invalid}/theme" &&
     -f "${_cntools_theme_file}" && ! -L "${_cntools_theme_file}" &&
     -O "${_cntools_theme_file}" ]] || return 1
  cntools_theme_private_path "${_cntools_theme_file}" || return 1
  _cntools_size="$(wc -c < "${_cntools_theme_file}" 2>/dev/null)" || return 2
  _cntools_size="${_cntools_size//[[:space:]]/}"
  [[ "${_cntools_size}" =~ ^[0-9]+$ && ${_cntools_size} -le 64 ]] || return 2
  if IFS= read -r -d '' _cntools_nul_probe < "${_cntools_theme_file}"; then
    return 2
  fi
  mapfile -t _cntools_lines < "${_cntools_theme_file}" || return 2
  [[ ${#_cntools_lines[@]} -eq 1 ]] || return 2
  cntools_theme_valid "${_cntools_lines[0]}" || return 2
  _cntools_output_ref="${_cntools_lines[0]}"
}

cntools_theme_cleanup() {
  local stage="${CNTOOLS_THEME_STAGE_FILE:-}"

  if [[ -n "${stage}" &&
        "${stage}" == "${CNTOOLS_THEME_STATE_DIR:-/invalid}/.theme."* &&
        -f "${stage}" && ! -L "${stage}" && -O "${stage}" ]]; then
    rm -f -- "${stage}" 2>/dev/null || true
  fi
  CNTOOLS_THEME_STAGE_FILE=""
}

cntools_theme_save() {
  local theme_id="${1:-}"
  local theme_file="${CNTOOLS_THEME_STATE_FILE:-}"

  cntools_theme_valid "${theme_id}" || return 2
  cntools_theme_state_directory_ready || return 1
  [[ -n "${theme_file}" &&
     "${theme_file}" == "${CNTOOLS_THEME_STATE_DIR}/theme" &&
     ! -L "${theme_file}" ]] || return 1
  if [[ -e "${theme_file}" ]]; then
    [[ -f "${theme_file}" && -O "${theme_file}" ]] || return 1
  fi
  cntools_theme_cleanup
  CNTOOLS_THEME_STAGE_FILE="$(mktemp \
    "${CNTOOLS_THEME_STATE_DIR}/.theme.XXXXXX")" || return 1
  [[ -f "${CNTOOLS_THEME_STAGE_FILE}" &&
     ! -L "${CNTOOLS_THEME_STAGE_FILE}" &&
     -O "${CNTOOLS_THEME_STAGE_FILE}" ]] || {
    cntools_theme_cleanup
    return 1
  }
  if ! chmod 0600 "${CNTOOLS_THEME_STAGE_FILE}" ||
     ! printf '%s\n' "${theme_id}" > "${CNTOOLS_THEME_STAGE_FILE}" ||
     ! mv -f -- "${CNTOOLS_THEME_STAGE_FILE}" "${theme_file}"; then
    cntools_theme_cleanup
    return 1
  fi
  CNTOOLS_THEME_STAGE_FILE=""
  [[ -f "${theme_file}" && ! -L "${theme_file}" &&
     -O "${theme_file}" ]] || return 1
  cntools_theme_log THEME "saved theme=${theme_id}"
}

cntools_theme_invalidate_ui_cache() {
  CNTOOLS_GUM_LAST_HEADER_ROWS=""
  CNTOOLS_GUM_LAST_HEADER_MODE=""
  CNTOOLS_GUM_STATIC_HEADER_KEY=""
  CNTOOLS_GUM_STATIC_HEADER_TITLE=""
  CNTOOLS_GUM_STATIC_HEADER_RUNTIME=""
  CNTOOLS_GUM_HEALTH_FRAGMENT_KEY=""
  CNTOOLS_GUM_HEALTH_FRAGMENT=""
  if declare -p CNTOOLS_GUM_BREADCRUMB_KEYS >/dev/null 2>&1; then
    CNTOOLS_GUM_BREADCRUMB_KEYS=()
    CNTOOLS_GUM_BREADCRUMB_FRAGMENTS=()
    CNTOOLS_GUM_HEADER_RENDER_KEYS=()
    CNTOOLS_GUM_HEADER_RENDERED=()
    CNTOOLS_GUM_HEADER_RENDER_ROWS=()
    CNTOOLS_GUM_MENU_ROW_KEYS=()
    CNTOOLS_GUM_MENU_ROWS=()
  fi
}

cntools_theme_init() {
  local saved_theme=""
  local status=0

  cntools_theme_apply default || return 1
  if ! cntools_theme_state_paths; then
    cntools_theme_log WARN \
      "Theme persistence is unavailable; using the default theme"
    return 0
  fi
  if [[ ! -e "${CNTOOLS_THEME_STATE_FILE}" &&
        ! -L "${CNTOOLS_THEME_STATE_FILE}" ]]; then
    cntools_theme_log THEME "using theme=default"
    return 0
  fi
  if cntools_theme_read_into saved_theme; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_theme_log WARN \
      "Saved theme selection is unsafe or invalid; using the default theme"
    return 0
  fi
  cntools_theme_apply "${saved_theme}" || return 1
  cntools_theme_log THEME "loaded theme=${saved_theme}"
}

cntools_theme_reload() {
  local saved_theme="default"

  if [[ -e "${CNTOOLS_THEME_STATE_FILE:-}" ||
        -L "${CNTOOLS_THEME_STATE_FILE:-}" ]]; then
    if ! cntools_theme_read_into saved_theme; then
      cntools_theme_log WARN \
        "Saved theme selection became unsafe or invalid; retaining ${CNTOOLS_THEME_ID}"
      return 1
    fi
  fi
  [[ "${saved_theme}" != "${CNTOOLS_THEME_ID:-default}" ]] || return 0
  cntools_theme_apply "${saved_theme}" || return 1
  cntools_theme_invalidate_ui_cache
  cntools_theme_log THEME "activated theme=${saved_theme}"
}

cntools_theme_display_name() {
  local theme_id="${1:-${CNTOOLS_THEME_ID:-default}}"

  cntools_theme_valid "${theme_id}" || return 2
  printf '%s\n' "${CNTOOLS_THEME_NAMES[${theme_id}]}"
}

cntools_theme_role_color_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_role="${2:-value}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  case "${_cntools_role}" in
    number) _cntools_output_ref="${CNTOOLS_THEME_COLOR_NUMBER}" ;;
    address|credential|identifier) \
      _cntools_output_ref="${CNTOOLS_THEME_COLOR_IDENTIFIER}" ;;
    accent|active) _cntools_output_ref="${CNTOOLS_THEME_COLOR_ACCENT}" ;;
    success) _cntools_output_ref="${CNTOOLS_THEME_COLOR_SUCCESS}" ;;
    warning) _cntools_output_ref="${CNTOOLS_THEME_COLOR_WARNING}" ;;
    danger) _cntools_output_ref="${CNTOOLS_THEME_COLOR_DANGER}" ;;
    muted|neutral) _cntools_output_ref="${CNTOOLS_THEME_COLOR_MUTED}" ;;
    value|text) _cntools_output_ref="${CNTOOLS_THEME_COLOR_TEXT}" ;;
    *) return 2 ;;
  esac
}

cntools_theme_style_value_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_role="${2:-value}"
  local _cntools_value="${3:-}"
  local _cntools_color=""
  local _cntools_hex=""
  local _cntools_red=0
  local _cntools_green=0
  local _cntools_blue=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_value}" != *$'\033'* &&
     "${_cntools_value}" != *$'\n'* &&
     "${_cntools_value}" != *$'\r'* ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref="${_cntools_value}"
  cntools_theme_role_color_into _cntools_color "${_cntools_role}" || return 2
  if [[ -n "${NO_COLOR:-}" || "${CNTOOLS_UI_INTERACTIVE:-N}" != "Y" ]]; then
    return 0
  fi
  [[ "${_cntools_color}" =~ ^#[0-9A-Fa-f]{6}$ ]] || return 1
  _cntools_hex="${_cntools_color#\#}"
  _cntools_red=$((16#${_cntools_hex:0:2}))
  _cntools_green=$((16#${_cntools_hex:2:2}))
  _cntools_blue=$((16#${_cntools_hex:4:2}))
  printf -v _cntools_output_ref '\033[38;2;%d;%d;%dm%s\033[0m' \
    "${_cntools_red}" "${_cntools_green}" "${_cntools_blue}" \
    "${_cntools_value}"
}

cntools_theme_style_value() {
  local styled=""

  cntools_theme_style_value_into styled "${1:-value}" "${2:-}" || return $?
  printf '%s' "${styled}"
}

# Source-time defaults keep all downstream UI functions fully defined before
# startup resolves a saved selection.
cntools_theme_apply default
