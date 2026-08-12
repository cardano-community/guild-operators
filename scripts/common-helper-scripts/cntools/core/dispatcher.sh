#!/usr/bin/env bash
# Fail-closed Stage 3 shadow dispatcher boundary. It performs preflight only.
# Action execution remains disabled until the compatibility extraction stage.

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
  "${bash_path}" -n "${action_directory}/action.sh" >/dev/null 2>&1 || return 1
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

# Purpose: reserve the action-execution API while Stage 3 remains inactive.
# Parameters: action directory, context file, future action arguments.
# Result: explanatory diagnostic on stderr.
# Status: always 69 (service unavailable/inactive generation).
# Runtime context/side effects: none; action code is never loaded.
# External commands/secrets: none.
cntools_dispatcher_run_action() {
  builtin printf '%s\n' \
    'CNTools modular action execution is inactive during Stage 3 shadow mode.' >&2
  return 69
}
