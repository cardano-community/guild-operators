#!/usr/bin/env bash
# Quick/Detailed flow selector. The preference is owned by core/settings.sh.

cntools_action_cleanup() {
  cntools_settings_cleanup || true
}

cntools_action_main() {
  local style="" status=0

  cntools_ui_action_begin "Flow Style" "/ Settings / Flow Style"
  cntools_ui_render_status info "Current flow style: $(cntools_flow_style_name)." || return 1
  cntools_flow_style_choose_into style || status=$?
  if (( status == 1 )); then
    cntools_log CHOICE "flow style selection cancelled" || true
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  cntools_ui_action_begin "Flow Style" "/ Settings / Flow Style"
  if cntools_flow_style_save "${style}"; then
    cntools_ui_render_status success \
      "Saved: $(cntools_flow_style_name "${style}") is now used for guided actions."
  else
    cntools_ui_render_status error \
      "The flow style could not be saved and is unchanged. See ${CNTOOLS_LOG}."
  fi
  cntools_ui_wait
}
