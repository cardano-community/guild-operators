#!/usr/bin/env bash
# Settings / Shortcuts: add, change and remove the codes that Go to (00 in
# every menu) jumps with. The store is owned by core/shortcuts.sh.

CNTOOLS_SHORTCUTS_ACTION_PATH="/ Settings / Shortcuts"

cntools_action_cleanup() {
  cntools_shortcuts_cleanup || true
}

# Asks for a code for the entry <name>. Returns 0 with a valid lowercase code,
# 1 when cancelled, left empty or unchanged, or the prompt's status.
cntools_shortcuts_action_code_into() {
  local _csac_output="${1:-}"
  local _csac_name="${2:-}"
  local _csac_current="${3:-}"
  local _csac_entered=""
  local _csac_owner=""
  local _csac_owner_name=""
  local _csac_hint="1 to 4 letters or digits"
  local _csac_status=0

  [[ "${_csac_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  printf -v "${_csac_output}" '%s' ''
  [[ -z "${_csac_current}" ]] || _csac_hint+=" · now ${_csac_current}"
  while true; do
    cntools_ui_input _csac_entered "Shortcut for ${_csac_name}" "${_csac_hint}" ||
      return $?
    _csac_entered="${_csac_entered,,}"
    [[ -n "${_csac_entered}" && "${_csac_entered}" != "${_csac_current}" ]] ||
      return 1
    if [[ ! "${_csac_entered}" =~ ${CNTOOLS_SHORTCUTS_CODE_PATTERN} ]]; then
      cntools_ui_render_status warn \
        "Use 1 to 4 letters or digits, such as pr or w1."
      continue
    fi
    # A code that already goes elsewhere moves only with a yes.
    cntools_shortcuts_resolve_into _csac_owner "${_csac_entered}" || true
    if [[ -n "${_csac_owner}" ]]; then
      cntools_shortcuts_target_name_into _csac_owner_name "${_csac_owner}" || return 2
      _csac_status=0
      cntools_ui_confirm \
        "Shortcut ${_csac_entered} goes to ${_csac_owner_name}. Move it to ${_csac_name}?" \
        false || _csac_status=$?
      (( _csac_status != 130 )) || return 130
      (( _csac_status == 0 )) || continue
    fi
    printf -v "${_csac_output}" '%s' "${_csac_entered}"
    return 0
  done
}

# Picks one of the saved shortcuts; returns 0 with its code.
cntools_shortcuts_action_pick_into() {
  local _csap_output="${1:-}"
  local _csap_placeholder="${2:-Shortcut…}"
  local _csap_row=""
  local _csap_name=""
  local _csap_index=0
  local -a _csap_rows=()

  [[ "${_csap_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  printf -v "${_csap_output}" '%s' ''
  for (( _csap_index = 0; _csap_index < ${#CNTOOLS_SHORTCUTS_CODES[@]}; _csap_index++ )); do
    cntools_shortcuts_target_name_into _csap_name \
      "${CNTOOLS_SHORTCUTS_TARGETS[_csap_index]}" || return 2
    printf -v "_csap_rows[_csap_index]" '%-4s  %s' \
      "${CNTOOLS_SHORTCUTS_CODES[_csap_index]}" "${_csap_name}"
  done
  (( ${#_csap_rows[@]} > 0 )) || return 2
  cntools_ui_choose _csap_row "${_csap_placeholder}" "${_csap_rows[@]}" "Cancel" ||
    return $?
  [[ "${_csap_row}" != "Cancel" ]] || return 1
  for (( _csap_index = 0; _csap_index < ${#_csap_rows[@]}; _csap_index++ )); do
    if [[ "${_csap_rows[_csap_index]}" == "${_csap_row}" ]]; then
      printf -v "${_csap_output}" '%s' "${CNTOOLS_SHORTCUTS_CODES[_csap_index]}"
      return 0
    fi
  done
  return 2
}

# Saves <code> for <target> and sets the overview's status <level> and
# <message> variables to say how it went.
cntools_shortcuts_action_assign_into() {
  local _csaa_level="${1:-}"
  local _csaa_message="${2:-}"
  local _csaa_code="${3:-}"
  local _csaa_target="${4:-}"
  local _csaa_name="${5:-}"
  local _csaa_status=0

  [[ "${_csaa_level}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_csaa_message}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  cntools_shortcuts_assign "${_csaa_code}" "${_csaa_target}" || _csaa_status=$?
  case "${_csaa_status}" in
    0)
      printf -v "${_csaa_level}" '%s' success
      printf -v "${_csaa_message}" '%s' \
        "Saved: ${_csaa_code} goes to ${_csaa_name}. In any menu, type 00 for Go to, then ${_csaa_code}."
      ;;
    3)
      printf -v "${_csaa_level}" '%s' warn
      printf -v "${_csaa_message}" '%s' \
        "There are already ${CNTOOLS_SHORTCUTS_MAX} shortcuts. Remove one before adding another."
      ;;
    *)
      printf -v "${_csaa_level}" '%s' error
      printf -v "${_csaa_message}" '%s' \
        "The shortcut could not be saved and nothing changed. See ${CNTOOLS_LOG:-the CNTools log}."
      ;;
  esac
}

cntools_action_main() {
  local selected=""
  local status=0
  local level=""
  local message=""
  local target=""
  local name=""
  local code=""
  local current=""
  local -a choices=()

  while true; do
    cntools_shortcuts_load
    cntools_ui_action_begin "Shortcuts" "${CNTOOLS_SHORTCUTS_ACTION_PATH}"
    if [[ -n "${message}" ]]; then
      cntools_ui_render_status "${level}" "${message}"
      message=""
    fi
    case "${CNTOOLS_SHORTCUTS_STATE}" in
      unavailable)
        cntools_ui_render_status error \
          "Shortcuts can't be saved: CNTools has no private state folder. See ${CNTOOLS_LOG:-the CNTools log}."
        choices=("Done")
        ;;
      invalid)
        cntools_ui_render_status warn \
          "The saved shortcuts in ${CNTOOLS_SHORTCUTS_FILE} could not be read and are left as they are. Start again to move that file aside and save new ones."
        choices=("Start again with no shortcuts" "Done")
        ;;
      *)
        if (( ${#CNTOOLS_SHORTCUTS_CODES[@]} > 0 )); then
          # A failed render is not shown yet: 2 gives the menu banner.
          cntools_shortcuts_render_table || return 2
          choices=("Add a shortcut" "Change a code" "Remove a shortcut"
            "Remove all shortcuts" "Done")
        else
          cntools_ui_render_status info \
            $'No shortcuts yet. A shortcut is a code of 1 to 4 letters or digits.\nIn any menu, type 00 for Go to, then the code, to jump to its menu or action.'
          choices=("Add a shortcut" "Done")
        fi
        ;;
    esac

    status=0
    cntools_ui_choose selected "Choose…" "${choices[@]}" || status=$?
    if (( status == 1 )); then
      cntools_gum_clear
      return 0
    elif (( status != 0 )); then
      return "${status}"
    fi

    # Escape (1) in a step returns to the overview; Ctrl+C (130) leaves.
    status=0
    case "${selected}" in
      "Add a shortcut")
        cntools_shortcuts_entries_collect || return 2
        cntools_ui_action_begin "Shortcuts" "${CNTOOLS_SHORTCUTS_ACTION_PATH} / Add"
        cntools_shortcuts_pick_entry_into target \
          "Menu or action for the shortcut…" || status=$?
        if (( status == 0 )); then
          cntools_shortcuts_target_name_into name "${target}" || return 2
          current=""
          cntools_shortcuts_code_for_into current "${target}" || true
          cntools_shortcuts_action_code_into code "${name}" "${current}" || status=$?
        fi
        if (( status == 0 )); then
          cntools_shortcuts_action_assign_into level message \
            "${code}" "${target}" "${name}" || return 2
        fi
        ;;
      "Change a code")
        cntools_ui_action_begin "Shortcuts" "${CNTOOLS_SHORTCUTS_ACTION_PATH} / Change"
        cntools_shortcuts_action_pick_into current "Shortcut to change…" || status=$?
        if (( status == 0 )); then
          cntools_shortcuts_resolve_into target "${current}" || true
          [[ -n "${target}" ]] || return 2
          cntools_shortcuts_target_name_into name "${target}" || return 2
          cntools_shortcuts_action_code_into code "${name}" "${current}" || status=$?
        fi
        if (( status == 0 )); then
          cntools_shortcuts_action_assign_into level message \
            "${code}" "${target}" "${name}" || return 2
        fi
        ;;
      "Remove a shortcut")
        cntools_ui_action_begin "Shortcuts" "${CNTOOLS_SHORTCUTS_ACTION_PATH} / Remove"
        cntools_shortcuts_action_pick_into code "Shortcut to remove…" || status=$?
        if (( status == 0 )); then
          cntools_shortcuts_resolve_into target "${code}" || true
          cntools_shortcuts_target_name_into name "${target}" || return 2
          if cntools_shortcuts_remove "${code}"; then
            level="success"
            message="Removed shortcut ${code} (${name})."
          else
            level="error"
            message="The shortcut could not be removed. See ${CNTOOLS_LOG:-the CNTools log}."
          fi
        fi
        ;;
      "Remove all shortcuts")
        cntools_ui_confirm "Remove all ${#CNTOOLS_SHORTCUTS_CODES[@]} shortcuts?" false ||
          status=$?
        if (( status == 0 )); then
          if cntools_shortcuts_remove_all; then
            level="success"
            message="All shortcuts were removed."
          else
            level="error"
            message="The shortcuts could not be removed. See ${CNTOOLS_LOG:-the CNTools log}."
          fi
        fi
        ;;
      "Start again with no shortcuts")
        if cntools_shortcuts_set_aside; then
          level="success"
          message="The unreadable file was moved to ${CNTOOLS_SHORTCUTS_ASIDE_FILE}. No shortcuts are saved now."
        else
          level="error"
          message="The unreadable file could not be moved aside. Fix or remove ${CNTOOLS_SHORTCUTS_FILE}."
        fi
        ;;
      "Done")
        return 0
        ;;
      *)
        return 2
        ;;
    esac
    (( status == 0 || status == 1 )) || return "${status}"
  done
}
