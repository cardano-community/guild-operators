#!/usr/bin/env bash
# Status and structured-result contracts for CNTools actions.
# This file defines functions only.

_cntools_result_path_valid() {
  builtin local target="${1:-}"
  builtin local component=""
  builtin local -a components
  components=()

  [[ "${target}" == /* && "${target}" != "/" && "${target}" != */ &&
     "${target}" != *//* && "${target}" != *\\* &&
     ! "${target}" =~ [[:cntrl:]] ]] || builtin return 1
  IFS='/' builtin read -r -a components <<< "${target}"
  for component in "${components[@]}"; do
    [[ -z "${component}" ]] && continue
    [[ "${component}" != "." && "${component}" != ".." ]] || builtin return 1
  done
}

_cntools_result_stat() {
  builtin local target="${1:-}"
  builtin local metadata=""
  builtin local stat_path=""

  builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
    builtin return 2
  _cntools_registry_tool_path stat stat_path || builtin return 2
  if metadata="$(
    "${stat_path}" -f $'%u\t%Lp\t%l\t%z' "${target}" 2>/dev/null
  )"; then
    builtin printf '%s\n' "${metadata}"
    builtin return 0
  fi
  "${stat_path}" -c $'%u\t%a\t%h\t%s' -- "${target}" 2>/dev/null
}

_cntools_result_private_parent_validate() {
  builtin local parent="${1:-}"
  builtin local metadata="" owner="" mode="" links="" size=""

  builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
    builtin return 2
  _cntools_result_path_valid "${parent}" || builtin return 1
  [[ -d "${parent}" && ! -L "${parent}" ]] || builtin return 1
  _cntools_registry_path_has_no_symlinks "${parent}" || builtin return 1
  metadata="$(_cntools_result_stat "${parent}")" || builtin return $?
  IFS=$'\t' builtin read -r owner mode links size <<< "${metadata}" ||
    builtin return 1
  [[ "${owner}" == "${EUID}" &&
     ( "${mode}" == "700" || "${mode}" == "0700" ) ]] || builtin return 1
}

# Purpose: validate an absent action-result destination and its private parent.
# Parameters: absolute result JSON path.
# Result: no output.
# Status: 0 safe target, 1 unsafe target, 2 missing prerequisite API/tool.
# Runtime context/side effects: reads path metadata only.
_cntools_result_target_validate() {
  builtin local result_file="${1:-}"
  builtin local parent=""

  builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
    builtin return 2
  _cntools_result_path_valid "${result_file}" || builtin return 1
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || builtin return 1
  _cntools_registry_path_has_no_symlinks "${result_file}" || builtin return 1
  parent="${result_file%/*}"
  [[ -n "${parent}" ]] || parent="/"
  _cntools_result_private_parent_validate "${parent}"
}

# Purpose: translate an action status into its dispatcher-owned outcome.
# Parameters: numeric action status.
# Result: completed, home, refresh, exit, or failure on stdout.
# Status: 0 recognized reserved status, 1 action failure status, 2 invalid input.
# Runtime context/side effects/external commands/secrets: none.
cntools_result_outcome() {
  local status="${1:-}"

  [[ "${status}" =~ ^[0-9]+$ && "${status}" -le 255 ]] || return 2
  case "${status}" in
    0) printf 'completed\n' ;;
    20) printf 'home\n' ;;
    21) printf 'refresh\n' ;;
    22) printf 'exit\n' ;;
    *) printf 'failure\n'; return 1 ;;
  esac
}

# Purpose: validate a canonical private JSON result produced by an action.
# Parameters: result JSON file.
# Result: no output.
# Status: 0 valid, 1 unsafe/malformed, 2 prerequisite API/tool unavailable.
# Runtime context/side effects: reads one bounded file and parent metadata.
# External commands: resolved jq, cmp, and stat. Result data must not contain
# secrets; this channel is not a same-UID malicious-code boundary.
cntools_result_validate() {
  builtin local result_file="${1:-}"
  builtin local parent="" metadata="" owner="" mode="" links="" size=""
  builtin local cmp_path="" jq_path=""

  builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
    builtin return 2
  builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
    builtin return 2
  _cntools_registry_tool_path cmp cmp_path || builtin return 2
  _cntools_registry_tool_path jq jq_path || builtin return 2

  _cntools_result_path_valid "${result_file}" || builtin return 1
  [[ -f "${result_file}" && ! -L "${result_file}" ]] || builtin return 1
  _cntools_registry_path_has_no_symlinks "${result_file}" || builtin return 1
  parent="${result_file%/*}"
  [[ -n "${parent}" ]] || parent="/"
  _cntools_result_private_parent_validate "${parent}" || builtin return $?

  metadata="$(_cntools_result_stat "${result_file}")" || builtin return $?
  IFS=$'\t' builtin read -r owner mode links size <<< "${metadata}" ||
    builtin return 1
  [[ "${owner}" == "${EUID}" &&
     ( "${mode}" == "600" || "${mode}" == "0600" ) &&
     "${links}" == "1" && "${size}" =~ ^[0-9]+$ &&
     "${size}" -ge 1 && "${size}" -le 1048576 ]] || builtin return 1

  "${cmp_path}" -s -- "${result_file}" <(
    "${jq_path}" -S . "${result_file}" 2>/dev/null
  ) || builtin return 1
  "${jq_path}" -e '
    type == "object" and
    keys == ["data", "schemaVersion"] and
    .schemaVersion == 1 and
    (.data | type == "object")
  ' "${result_file}" >/dev/null 2>&1
}
