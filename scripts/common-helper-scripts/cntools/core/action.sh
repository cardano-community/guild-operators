#!/usr/bin/env bash
# CNTools lazy action and library loader. Functions only.
# shellcheck disable=SC2034

cntools_action_run() {
  local module_directory="${1:-}"
  local physical_root=""
  local physical_module=""
  local action_id=""
  local action_label=""

  cntools_menu_directory_within_root "${module_directory}" || {
    cntools_log ERROR "Action path is outside the module root or unsafe" || true
    return 2
  }
  physical_root="$(cd -- "${CNTOOLS_MODULE_ROOT}" && pwd -P)" || return 2
  physical_module="$(cd -- "${module_directory}" && pwd -P)" || return 2
  action_id="${physical_module#"${physical_root}"/}"

  (
    local relative_library=""
    local library_path=""
    local library_list=""
    local action_file="${physical_module}/action.sh"
    local status=0

    # The parent menu owns the alternate screen. Actions use the normal
    # terminal buffer so long output remains scrollable and child-local UI
    # state cannot leave the parent in an unmatched alternate screen.
    CNTOOLS_UI_USE_ALT_SCREEN="N"
    CNTOOLS_UI_SCREEN_ACTIVE="N"
    trap 'cntools_ui_suspend_for_job_control' TSTP
    trap 'cntools_ui_mark_resize' CONT

    CNTOOLS_ACTION_ID="${action_id}"
    export CNTOOLS_ACTION_ID
    cntools_log ACTION "selected" || return 1
    cntools_menu_validate_metadata "${physical_module}" child || {
      cntools_log ERROR "${CNTOOLS_MENU_ERROR}" || true
      return 2
    }
    [[ "$(jq -r '.kind' "${physical_module}/module.json")" == "action" ]] || {
      cntools_log ERROR "Selected module is not an action" || true
      return 2
    }
    action_label="$(jq -er '.label' "${physical_module}/module.json")" || {
      cntools_log ERROR "Selected action has no valid label: ${action_id}" || true
      return 2
    }
    CNTOOLS_ACTION_LABEL="${action_label}"
    export CNTOOLS_ACTION_LABEL
    jq -e --arg mode "${CNTOOLS_MODE:-local}" \
      '.modes | index($mode) != null' \
      "${physical_module}/module.json" >/dev/null || {
      cntools_log ACTION "blocked in ${CNTOOLS_MODE:-unknown} mode" || true
      return 3
    }

    unset -f cntools_action_main 2>/dev/null || true
    if ! library_list="$(jq -r '.libs[]?' \
      "${physical_module}/module.json")"; then
      cntools_log ERROR "Could not read declared action libraries: ${action_id}" || true
      return 2
    fi
    while IFS= read -r relative_library; do
      [[ -n "${relative_library}" ]] || continue
      library_path="$(cntools_menu_library_path "${relative_library}")" || {
        cntools_log ERROR "Declared library is missing or unsafe: ${relative_library}" || true
        return 2
      }
      "${CNTOOLS_VALIDATION_BASH:-bash}" -n "${library_path}" >/dev/null 2>&1 || {
        cntools_log ERROR "Declared library failed shell validation: ${relative_library}" || true
        return 2
      }
      # shellcheck source=/dev/null
      . "${library_path}" || {
        cntools_log ERROR "Declared library failed to load: ${relative_library}" || true
        return 2
      }
      if declare -F cntools_action_main >/dev/null 2>&1; then
        cntools_log ERROR "Library defines reserved cntools_action_main: ${relative_library}" || true
        return 2
      fi
    done <<< "${library_list}"

    unset -f cntools_action_main 2>/dev/null || true
    # shellcheck source=/dev/null
    . "${action_file}" || {
      cntools_log ERROR "Action failed to load: ${action_id}" || true
      return 2
    }
    declare -F cntools_action_main >/dev/null 2>&1 || {
      cntools_log ERROR "Action has no cntools_action_main entrypoint: ${action_id}" || true
      return 2
    }
    if cntools_action_main; then
      status=0
    else
      status=$?
    fi
    cntools_log ACTION "completed with status ${status}" || true
    return "${status}"
  )
}
