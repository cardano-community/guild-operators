#!/usr/bin/env bash
# Fail-closed modular dispatcher boundary. The public Stage 3 menu remains
# inactive, while Stage 4 synthetic actions qualify the compatibility runner.

# Purpose: validate an action directory and its fixed entrypoint contract.
# Parameters: action module directory.
# Result: no output.
# Status: 0 valid action, 1 invalid, 2 registry API unavailable.
# Runtime context/side effects: reads files; never sources or executes an action.
# External commands: Bash syntax checker and grep through the registry API.
cntools_dispatcher_validate_action() {
  local action_directory="${1:-}"
  local metadata="${action_directory}/module.json"
  local bash_path="" grep_path="" jq_path="" kind=""

  builtin declare -F cntools_registry_validate_metadata >/dev/null 2>&1 || return 2
  builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 || return 2
  _cntools_registry_tool_path jq jq_path || return 2
  _cntools_registry_tool_path bash bash_path || return 2
  _cntools_registry_tool_path grep grep_path || return 2
  cntools_registry_validate_metadata "${metadata}" || return $?
  kind="$("${jq_path}" -er '.kind' "${metadata}" 2>/dev/null)" || return 1
  [[ "${kind}" == "action" &&
     -f "${action_directory}/action.sh" &&
     ! -L "${action_directory}/action.sh" ]] || return 1
  BASH_ENV=/dev/null ENV=/dev/null \
    "${bash_path}" --noprofile --norc -n \
      "${action_directory}/action.sh" >/dev/null 2>&1 || return 1
  "${grep_path}" -Eq \
    '^[[:space:]]*cntools_action_main[[:space:]]*\(\)[[:space:]]*\{' \
    "${action_directory}/action.sh"
}

# Purpose: check action execution requirements against a validated context.
# Parameters: action module.json, context JSON.
# Result: no output.
# Status: 0 requirements met, 1 unmet/invalid, 2 prerequisite API unavailable.
# Runtime context/side effects: reads metadata and context only.
# External commands: jq. No action or metadata is evaluated as shell code.
cntools_dispatcher_preflight() {
  local metadata_file="${1:-}"
  local context_file="${2:-}"
  local jq_path=""

  builtin declare -F cntools_registry_validate_metadata >/dev/null 2>&1 || return 2
  builtin declare -F cntools_context_validate >/dev/null 2>&1 || return 2
  builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 || return 2
  _cntools_registry_tool_path jq jq_path || return 2
  cntools_registry_validate_metadata "${metadata_file}" || return $?
  cntools_context_validate "${context_file}" || return $?
  "${jq_path}" -e -s '
    .[0] as $module | .[1] as $context |
    $module.kind == "action" and
    ($module.executionRequirements.modes | index($context.mode) != null) and
    all($module.executionRequirements.features[];
      . as $feature | $context.features | index($feature) != null) and
    all($module.executionRequirements.nodeCapabilities[];
      . as $capability | $context.capabilities | index($capability) != null)
  ' "${metadata_file}" "${context_file}" >/dev/null 2>&1
}

# Purpose: invoke one validated action through the Stage 4 compatibility
# subshell. This API is not reachable from the public menu during Stage 4.
# Parameters: action directory, context file, result file, action arguments.
# Result: preserves the action's stdout and stderr byte streams.
# Status: exact action status, or 70 when validation/loading fails.
# Runtime context/side effects: isolates shell-state changes from the caller;
# authenticated project action code may still perform external side effects.
# External commands/secrets: validation uses the registry/context toolchain;
# action arguments are transported positionally and are never diagnosed.
cntools_dispatcher_run_action() (
  builtin local action_directory="${1:-}"
  builtin local context_file="${2:-}"
  builtin local result_file="${3:-}"
  builtin local action_status=0 rm_path=""

  if (( $# < 3 )); then
    builtin printf '%s\n' \
      'CNTools compatibility action failed validation.' >&2
    builtin return 70
  fi
  builtin shift 3

  # The syntax validator starts a child Bash. Do not let caller-controlled
  # startup hooks execute in that child; inherited compatibility state remains
  # available in this subshell by design during Stage 4.
  builtin unset BASH_ENV ENV

  if ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_target_validate >/dev/null 2>&1 ||
     ! builtin declare -F cntools_result_validate >/dev/null 2>&1 ||
     ! _cntools_registry_tool_path rm rm_path ||
     ! _cntools_result_path_valid "${action_directory}" ||
     ! _cntools_result_path_valid "${context_file}" ||
     ! _cntools_registry_path_has_no_symlinks "${context_file}" ||
     ! _cntools_result_target_validate "${result_file}" ||
     ! cntools_dispatcher_validate_action "${action_directory}" ||
     ! cntools_dispatcher_preflight \
       "${action_directory}/module.json" "${context_file}"; then
    builtin printf '%s\n' \
      'CNTools compatibility action failed validation.' >&2
    builtin return 70
  fi

  # A nested action subshell keeps source/main shell state away from the outer
  # runner's trusted result validation. An action may exit or replace functions,
  # traps, options, descriptors, and locals without bypassing post-processing.
  if (
    # An inherited legacy function must not replace the authenticated action's
    # entrypoint. The source builtin bypasses a caller function or alias named
    # source while preserving inherited compatibility helpers and globals.
    builtin unset -f cntools_action_main 2>/dev/null || builtin true
    if ! builtin source "${action_directory}/action.sh" >/dev/null 2>&1 ||
       ! builtin declare -F cntools_action_main >/dev/null 2>&1; then
      builtin printf '%s\n' \
        'CNTools compatibility action could not be loaded.' >&2
      builtin exit 70
    fi
    cntools_action_main "${context_file}" "${result_file}" "$@"
  ); then
    action_status=0
  else
    action_status=$?
  fi

  if [[ -e "${result_file}" || -L "${result_file}" ]]; then
    if ! cntools_result_validate "${result_file}" >/dev/null 2>&1; then
      if [[ ! -d "${result_file}" || -L "${result_file}" ]]; then
        "${rm_path}" -f -- "${result_file}" >/dev/null 2>&1 || builtin true
      fi
      builtin printf '%s\n' \
        'CNTools compatibility action produced an unsafe result.' >&2
      builtin return 70
    fi
  fi

  builtin return "${action_status}"
)
