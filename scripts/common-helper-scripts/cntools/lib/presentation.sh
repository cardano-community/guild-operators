#!/usr/bin/env bash
# Sanitized terminal text, theme roles and wrapped TSV cells. No wallet/query dependency.
# shellcheck disable=SC2034

cntools_text_sanitize_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"
  local _cntools_character=""
  local _cntools_sanitized=""
  local _cntools_index=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_value="${_cntools_value//$'\r'/ }"
  _cntools_value="${_cntools_value//$'\n'/ }"
  _cntools_value="${_cntools_value//$'\t'/ }"
  _cntools_value="${_cntools_value//$'\033'/}"
  case "${_cntools_value}" in
    *[[:cntrl:]]*|*$'\u061c'*|*$'\u200e'*|*$'\u200f'*|\
    *$'\u202a'*|*$'\u202b'*|*$'\u202c'*|*$'\u202d'*|*$'\u202e'*|\
    *$'\u2066'*|*$'\u2067'*|*$'\u2068'*|*$'\u2069'*) ;;
    *)
      _cntools_output_ref="${_cntools_value}"
      return 0
      ;;
  esac
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_value};
         _cntools_index++ )); do
    _cntools_character="${_cntools_value:_cntools_index:1}"
    if [[ "${_cntools_character}" == [[:cntrl:]] ]]; then
      _cntools_sanitized+=" "
      continue
    fi
    case "${_cntools_character}" in
      $'\u061c'|$'\u200e'|$'\u200f'|\
      $'\u202a'|$'\u202b'|$'\u202c'|$'\u202d'|$'\u202e'|\
      $'\u2066'|$'\u2067'|$'\u2068'|$'\u2069')
        _cntools_sanitized+=" "
        ;;
      *) _cntools_sanitized+="${_cntools_character}" ;;
    esac
  done
  _cntools_output_ref="${_cntools_sanitized}"
}


cntools_text_sanitize() {
  local sanitized=""

  cntools_text_sanitize_into sanitized "${1:-}" || return $?
  printf '%s' "${sanitized}"
}


cntools_table_row() {
  local cell=""
  local separator=""

  (( $# > 0 )) || return 2
  for cell in "$@"; do
    cntools_text_sanitize_into cell "${cell}" || return 1
    if [[ "${cell}" == *'"'* ]]; then
      cell="${cell//\"/\"\"}"
      cell="\"${cell}\""
    fi
    printf '%s%s' "${separator}" "${cell}"
    separator=$'\t'
  done
  printf '\n'
}


cntools_table_row_prepared() {
  local cell=""
  local separator=""

  (( $# > 0 )) || return 2
  for cell in "$@"; do
    if [[ "${cell}" == *'"'* ]]; then
      cell="${cell//\"/\"\"}"
      cell="\"${cell}\""
    fi
    printf '%s%s' "${separator}" "${cell}"
    separator=$'\t'
  done
  printf '\n'
}


cntools_table_width() {
  local width=""
  local terminal_columns=""

  if [[ "${CNTOOLS_TABLE_RENDER_WIDTH:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${CNTOOLS_TABLE_RENDER_WIDTH}"
    return 0
  fi

  if declare -F cntools_ui_content_width >/dev/null 2>&1; then
    cntools_ui_content_width 180 42
    return $?
  fi

  # The general menu frame intentionally stays compact, but Wallet List and
  # Show often contain full Cardano addresses and credential hashes. Read the
  # live terminal width for these tables so a wider terminal is actually used
  # after a resize. Keep two columns clear to avoid right-edge autowrapping and
  # cap exceptionally wide tables at a readable size.
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" || -t 1 ]]; then
    terminal_columns="$(tput cols 2>/dev/null || true)"
    if [[ "${terminal_columns}" =~ ^[0-9]+$ &&
          ${terminal_columns} -gt 2 ]]; then
      width="$((terminal_columns - 2))"
    fi
  fi
  if [[ -z "${width}" ]] &&
     declare -F cntools_gum_width >/dev/null 2>&1; then
    width="$(COLUMNS='' cntools_gum_width 2>/dev/null || true)"
  fi
  [[ -n "${width}" ]] || width="${CNTOOLS_UI_COLUMNS:-${COLUMNS:-98}}"
  [[ "${width}" =~ ^[0-9]+$ ]] || width=98
  (( width >= 42 )) || width=42
  (( width <= 180 )) || width=180
  printf '%s\n' "${width}"
}


cntools_text_style_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_role="${2:-value}"
  local _cntools_value="${3:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref="${_cntools_value}"
  [[ -n "${_cntools_value}" ]] || return 0
  if declare -F cntools_theme_style_value_into >/dev/null 2>&1; then
    cntools_theme_style_value_into \
      "${_cntools_output_name}" "${_cntools_role}" "${_cntools_value}"
  fi
}


cntools_text_format_number_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"
  local _cntools_formatted=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref="${_cntools_value}"
  [[ "${_cntools_value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  if declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into \
      _cntools_formatted "${_cntools_value}" || return 1
    _cntools_output_ref="${_cntools_formatted}"
  fi
}


cntools_text_status_role() {
  local value="${1:-}"

  case "${value,,}" in
    *invalid*|*failed*|*error*) printf 'danger\n' ;;
    registered|delegated|protected|encrypted|yes|ready|available)
      printf 'success\n'
      ;;
    open|unprotected|*not\ registered*|*not\ delegated*|*missing*)
      printf 'warning\n'
      ;;
    unavailable|unknown|none|no|offline|—) printf 'muted\n' ;;
    *) printf 'value\n' ;;
  esac
}


cntools_text_number_role() {
  if [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'number\n'
  else
    printf 'muted\n'
  fi
}


cntools_text_width() {
  local value="${1:-}"
  local character=""
  local index=0
  local width=0

  for (( index = 0; index < ${#value}; index++ )); do
    character="${value:index:1}"
    if [[ "${character}" == [[:ascii:]] ]]; then
      width=$((width + 1))
    else
      width=$((width + 2))
    fi
  done
  printf '%s\n' "${width}"
}


cntools_text_chunk() {
  local _cntools_value="${1:-}"
  local _cntools_maximum="${2:-}"
  local _cntools_chunk_name="${3:-}"
  local _cntools_rest_name="${4:-}"
  local _cntools_character=""
  local _cntools_character_width=0
  local _cntools_display_width=0
  local _cntools_index=0
  local _cntools_chunk=""

  [[ "${_cntools_maximum}" =~ ^[1-9][0-9]*$ &&
     "${_cntools_chunk_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_rest_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_chunk_ref="${_cntools_chunk_name}"
  local -n _cntools_rest_ref="${_cntools_rest_name}"
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_value};
         _cntools_index++ )); do
    _cntools_character="${_cntools_value:_cntools_index:1}"
    _cntools_character_width=2
    [[ "${_cntools_character}" != [[:ascii:]] ]] ||
      _cntools_character_width=1
    if (( _cntools_display_width + _cntools_character_width >
          _cntools_maximum )); then
      break
    fi
    _cntools_chunk+="${_cntools_character}"
    _cntools_display_width=$((
      _cntools_display_width + _cntools_character_width
    ))
  done
  _cntools_chunk_ref="${_cntools_chunk}"
  _cntools_rest_ref="${_cntools_value:_cntools_index}"
}


cntools_table_wrapped_pair() {
  local label="${1:-}"
  local value="${2:-—}"
  local label_width="${3:-20}"
  local value_role="${4:-value}"
  local table_width=""
  local value_width=0
  local label_chunk=""
  local value_chunk=""
  local styled_value_chunk=""

  [[ "${label_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  table_width="$(cntools_table_width)" || return 1
  value_width=$((table_width - label_width - 7))
  while (( value_width < 8 && label_width > 10 )); do
    label_width=$((label_width - 1))
    value_width=$((value_width + 1))
  done
  (( value_width >= 8 )) || return 1
  cntools_text_sanitize_into label "${label}" || return 1
  cntools_text_sanitize_into value "${value}" || return 1
  [[ -n "${value}" ]] || value="—"
  while [[ -n "${label}" || -n "${value}" ]]; do
    cntools_text_chunk \
      "${label}" "${label_width}" label_chunk label || return 1
    cntools_text_chunk \
      "${value}" "${value_width}" value_chunk value || return 1
    cntools_text_style_into \
      styled_value_chunk "${value_role}" "${value_chunk}" || return 1
    cntools_table_row_prepared \
      "${label_chunk}" "${styled_value_chunk}" || return 1
  done
}


cntools_table_wrapped_triple() {
  local first="${1:-}"
  local second="${2:-}"
  local third="${3:-—}"
  local first_width="${4:-22}"
  local second_width="${5:-20}"
  local table_width="${6:-}"
  local first_role="${7:-value}"
  local third_role="${8:-value}"
  local third_width=0
  local first_chunk=""
  local second_chunk=""
  local third_chunk=""
  local styled_first_chunk=""
  local styled_third_chunk=""

  [[ "${first_width}" =~ ^[1-9][0-9]*$ &&
     "${second_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  if [[ -z "${table_width}" ]]; then
    table_width="$(cntools_table_width)" || return 1
  fi
  [[ "${table_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  third_width=$((table_width - first_width - second_width - 10))
  while (( third_width < 8 && first_width > 10 )); do
    first_width=$((first_width - 1))
    third_width=$((third_width + 1))
  done
  while (( third_width < 8 && second_width > 10 )); do
    second_width=$((second_width - 1))
    third_width=$((third_width + 1))
  done
  (( third_width >= 8 )) || return 1
  cntools_text_sanitize_into first "${first}" || return 1
  cntools_text_sanitize_into second "${second}" || return 1
  cntools_text_sanitize_into third "${third}" || return 1
  [[ -n "${third}" ]] || third="—"
  while [[ -n "${first}" || -n "${second}" || -n "${third}" ]]; do
    cntools_text_chunk \
      "${first}" "${first_width}" first_chunk first || return 1
    cntools_text_chunk \
      "${second}" "${second_width}" second_chunk second || return 1
    cntools_text_chunk \
      "${third}" "${third_width}" third_chunk third || return 1
    cntools_text_style_into \
      styled_first_chunk "${first_role}" "${first_chunk}" || return 1
    cntools_text_style_into \
      styled_third_chunk "${third_role}" "${third_chunk}" || return 1
    cntools_table_row_prepared \
      "${styled_first_chunk}" "${second_chunk}" \
      "${styled_third_chunk}" || return 1
  done
}
