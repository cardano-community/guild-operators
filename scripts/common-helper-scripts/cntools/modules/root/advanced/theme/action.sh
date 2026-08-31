#!/usr/bin/env bash
# Advanced theme selector. Theme state is owned by core/theme.sh.

cntools_action_cleanup() {
  cntools_theme_cleanup || true
}

cntools_action_main() {
  local selected=""
  local selection_status=0
  local theme_id=""
  local theme_name=""
  local current_suffix=""
  local row=""
  local index=0
  local -a rows=()
  local -a row_ids=()

  cntools_ui_action_begin "Theme" "/ Advanced / Theme"
  for theme_id in "${CNTOOLS_THEME_IDS[@]}"; do
    theme_name="$(cntools_theme_display_name "${theme_id}")" || return 1
    current_suffix=""
    [[ "${theme_id}" != "${CNTOOLS_THEME_ID}" ]] ||
      current_suffix="  ·  Current"
    row="${theme_name}${current_suffix}"
    rows+=("${row}")
    row_ids+=("${theme_id}")
  done
  (( ${#rows[@]} > 0 )) || return 1

  if cntools_ui_choose selected "Filter themes…" "${rows[@]}"; then
    selection_status=0
  else
    selection_status=$?
  fi
  if (( selection_status == 1 )); then
    cntools_gum_clear
    cntools_log CHOICE "theme selection cancelled" || true
    return 0
  elif (( selection_status != 0 )); then
    return "${selection_status}"
  fi

  for index in "${!rows[@]}"; do
    [[ "${selected}" == "${rows[index]}" ]] || continue
    theme_id="${row_ids[index]}"
    cntools_theme_save "${theme_id}" || {
      cntools_log ERROR "Could not persist theme=${theme_id}" || true
      return 1
    }
    cntools_theme_apply "${theme_id}" || return 1
    cntools_theme_invalidate_ui_cache
    cntools_log CHOICE "selected theme=${theme_id}" || true
    cntools_ui_action_begin "Theme" "/ Advanced / Theme"
    cntools_ui_render_status success \
      "$(cntools_theme_display_name "${theme_id}") is now the active CNTools theme."
    cntools_ui_wait
    return 0
  done

  cntools_log ERROR "Theme selector returned an unknown row" || true
  return 2
}
