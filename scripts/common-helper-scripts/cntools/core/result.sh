#!/usr/bin/env bash
# Status and structured-result contracts for CNTools actions.
# This file defines functions only.

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

# Purpose: validate a multi-field JSON result produced by an action helper.
# Parameters: result JSON file.
# Result: no output.
# Status: 0 valid, 1 unsafe/malformed, 2 jq unavailable.
# Runtime context/side effects: reads one file; no writes.
# External commands: jq. Callers must keep secrets out of result data.
cntools_result_validate() {
  local result_file="${1:-}"

  command -v jq >/dev/null 2>&1 || return 2
  [[ -f "${result_file}" && ! -L "${result_file}" ]] || return 1
  jq -e '
    type == "object" and
    keys == ["data", "schemaVersion"] and
    .schemaVersion == 1 and
    (.data | type == "object")
  ' "${result_file}" >/dev/null 2>&1
}
