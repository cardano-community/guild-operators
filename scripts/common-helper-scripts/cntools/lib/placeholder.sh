#!/usr/bin/env bash
# Shared placeholder presentation for actions awaiting implementation. Functions only.

cntools_action_placeholder() {
  local action_label="${CNTOOLS_ACTION_LABEL:-${CNTOOLS_ACTION_ID:-Action}}"
  local action_breadcrumb="/ ${action_label}"
  local ignored_key=""

  if [[ -n "${CNTOOLS_ACTION_ID:-}" ]] &&
     action_breadcrumb="$(cntools_menu_breadcrumb \
       "${CNTOOLS_MODULE_ROOT}/${CNTOOLS_ACTION_ID}" 2>/dev/null)"; then
    :
  else
    action_breadcrumb="/ ${action_label}"
  fi

  cntools_log ACTION "not implemented yet" || true
  cntools_ui_render_begin "${action_label}" "${action_breadcrumb}"
  printf '%s%s%s\n' "${CNTOOLS_UI_BOLD:-}" "${action_label}" "${CNTOOLS_UI_RESET:-}"
  cntools_ui_render_status warn "Not implemented yet"
  printf '\nThis action will be added in a later implementation phase.\n'

  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" ]]; then
    printf '\n%sPress any key to return.%s' "${CNTOOLS_UI_DIM:-}" "${CNTOOLS_UI_RESET:-}"
    cntools_ui_read_key ignored_key || true
    : "${ignored_key}"
    printf '\n'
  fi
  return 0
}
