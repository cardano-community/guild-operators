#!/usr/bin/env bash
# How menus answer typing. The choice is stored by core/settings.sh and the
# hotkey menus are drawn by core/fzf.sh.

cntools_action_cleanup() {
  cntools_settings_cleanup || true
  cntools_fzf_install_cleanup || true
}

cntools_navigation_choose_into() {
  local _cntools_output_name="${1:-}"
  local selected=""
  local hotkeys_label="Hotkeys · the highlighted letters open an item at once"
  local enter_label="Hotkeys with Enter · the same letters narrow the list"
  local filter_label="Filter · type any part of a row, then press Enter"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  case "${CNTOOLS_MENU_NAVIGATION:-}" in
    hotkeys|"") hotkeys_label+=" · current" ;;
    hotkeys-enter) enter_label+=" · current" ;;
    filter) filter_label+=" · current" ;;
  esac
  cntools_ui_render_status info $'Hotkeys highlight the start of each name that no other item shares;\ntyping it, or the item number, opens the item. Both hotkey styles need\nfzf '"${CNTOOLS_FZF_VERSION}"$' and use the Gum filter until it is installed.' || return 1
  cntools_ui_choose selected 'Navigation' \
    "${hotkeys_label}" "${enter_label}" "${filter_label}" Cancel || return $?
  case "${selected}" in
    "${hotkeys_label}") _cntools_output_ref=hotkeys ;;
    "${enter_label}") _cntools_output_ref=hotkeys-enter ;;
    "${filter_label}") _cntools_output_ref=filter ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
}

# Its messages go to the CNTools log; the spinner owns the screen meanwhile.
cntools_navigation_install_quietly() {
  cntools_fzf_install >/dev/null 2>&1
}

# 0 when fzf is ready (found or just installed), 1 when the menus will keep
# the Gum filter for now; either way the reason is shown.
cntools_navigation_fzf_ready() {
  local install_directory=""

  cntools_fzf_find && return 0
  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_ui_render_status warn \
      "fzf ${CNTOOLS_FZF_VERSION} is not installed and cannot be downloaded in offline mode."
    return 1
  fi
  install_directory="$(cntools_gum_install_directory 2>/dev/null)" || return 1
  if ! cntools_fzf_release_target >/dev/null 2>&1; then
    cntools_ui_render_status warn \
      "CNTools installs fzf on Linux x86_64 and arm64 only. Put fzf ${CNTOOLS_FZF_VERSION} in ${install_directory} or on PATH."
    return 1
  fi
  if ! cntools_ui_confirm "Install fzf ${CNTOOLS_FZF_VERSION} in ${install_directory}?" true; then
    cntools_log CHOICE "fzf installation declined from Navigation" || true
    return 1
  fi
  cntools_fzf_forget_decline
  if cntools_ui_spin_function "Installing fzf ${CNTOOLS_FZF_VERSION}…" \
      cntools_navigation_install_quietly; then
    cntools_ui_render_status success \
      "Installed fzf ${CNTOOLS_FZF_VERSION} at ${CNTOOLS_FZF_BIN}."
    return 0
  fi
  cntools_ui_render_status error \
    "fzf could not be installed. See ${CNTOOLS_LOG}."
  return 1
}

cntools_action_main() {
  local navigation="" status=0 ready=Y name="" effect=""

  cntools_ui_action_begin "Navigation" "/ Settings / Navigation"
  cntools_navigation_choose_into navigation || status=$?
  if (( status == 1 )); then
    cntools_log CHOICE "navigation selection cancelled" || true
    cntools_gum_clear
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  cntools_ui_action_begin "Navigation" "/ Settings / Navigation"
  if [[ "${navigation}" != filter ]]; then
    cntools_navigation_fzf_ready || ready=N
  fi
  name="$(cntools_navigation_name "${navigation}")" || return 2
  case "${navigation}" in
    hotkeys) effect="Type the highlighted letters or a number to open an item." ;;
    hotkeys-enter) effect="The highlighted letters or a number narrow the list; Enter opens." ;;
    filter) effect="Type any part of a row, then press Enter." ;;
  esac
  [[ "${ready}" == Y ]] ||
    effect="Menus use the Gum filter until fzf ${CNTOOLS_FZF_VERSION} is installed."
  if cntools_navigation_save "${navigation}"; then
    cntools_ui_render_status success "Saved: ${name}. ${effect}"
  else
    cntools_ui_render_status error \
      "Navigation could not be saved and is unchanged. See ${CNTOOLS_LOG}."
  fi
  cntools_ui_wait
}
