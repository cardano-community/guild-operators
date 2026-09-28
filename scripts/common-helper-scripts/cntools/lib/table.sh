#!/usr/bin/env bash
# Content-sized property tables. Uses shared wallet text/TSV helpers and Gum.
# Producers emit sanitized label/value/theme-role records, not pre-wrapped text.

cntools_table_pair() {
  local label="$1" value="$2" role="${3:-value}"
  cntools_wallet_sanitize_display_into label "${label}" || return 1
  cntools_wallet_sanitize_display_into value "${value}" || return 1
  printf '%s\037%s\037%s\n' "${label}" "${value}" "${role}"
}

cntools_table_content_width() {
  local width=""
  if declare -F cntools_ui_content_width >/dev/null 2>&1; then
    width="$(cntools_ui_content_width 100000 20)" || return 1
  elif [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] && (( COLUMNS > 2 )); then
    width=$((COLUMNS - 2))
  else
    width="${CNTOOLS_UI_COLUMNS:-98}"
  fi
  [[ "${width}" =~ ^[0-9]+$ ]] || return 2
  width=$((width - ${CNTOOLS_TABLE_MARGIN:-0}))
  (( width >= 20 )) || width=20
  printf '%s\n' "${width}"
}

cntools_table_heading() {
  local text="$1" role="${2:-accent}" width="" chunk="" styled=""
  cntools_wallet_sanitize_display_into text "${text}" || return 1
  width="$(cntools_table_content_width)" || return 1
  while [[ -n "${text}" ]]; do
    cntools_wallet_display_chunk "${text}" "${width}" chunk text || return 1
    cntools_wallet_style_value_into styled "${role}" "${chunk}" || return 1
    printf '%s\n' "${styled}"
  done
}

cntools_table_render() {
  local title="$1" label="" value="" role="" width=0 size=0 index=0
  local label_width=1 value_width=8 available=0
  local -a labels=() values=() roles=()
  # Dynamically scoped width consumed by the shared wrapped-pair helper.
  local CNTOOLS_WALLET_RENDER_WIDTH=""
  width="$(cntools_table_content_width)" || return 1
  while IFS=$'\037' read -r label value role; do
    # Existing producers may emit their old TSV header. It is not a data row.
    [[ -n "${role}" ]] || continue
    labels+=("${label}"); values+=("${value}"); roles+=("${role}")
    size="$(cntools_wallet_text_width "${label}")" || return 1
    (( size <= label_width )) || label_width="${size}"
    size="$(cntools_wallet_text_width "${value}")" || return 1
    (( size <= value_width )) || value_width="${size}"
  done
  (( ${#labels[@]} > 0 )) || return 0
  available=$((width - 7)) # Two cell paddings and three table borders.
  if (( label_width + value_width > available )); then
    # Leave short labels alone; long nested paths share space with values.
    (( label_width <= available / 3 )) || label_width=$((available / 3))
    if (( value_width < available - label_width )); then
      label_width=$((available - value_width))
    else
      value_width=$((available - label_width))
    fi
  fi
  # shellcheck disable=SC2034
  CNTOOLS_WALLET_RENDER_WIDTH=$((label_width + value_width + 7))
  cntools_table_heading "${title}" "${CNTOOLS_TABLE_TITLE_ROLE:-accent}" || return 1
  {
    # Blank headers cannot wrap when a content-sized column is very narrow.
    cntools_wallet_table_row '' ''
    for ((index=0; index<${#labels[@]}; index++)); do
      cntools_wallet_table_wrapped_pair "${labels[index]}" "${values[index]}" "${label_width}" "${roles[index]}" || return 1
    done
  } | cntools_ui_table --separator $'\t' --widths "${label_width},${value_width}"
}
