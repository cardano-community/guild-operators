#!/usr/bin/env bash
# Template for one CNTools action. Sourcing defines functions only.

# Purpose: implement one stable workflow declared by the adjacent module.json.
# Parameters: path to the validated, read-only CNTools context document.
# Result: workflow-specific output; structured data follows core/result.sh.
# Status: 0 return to parent; 20 Home; 21 refresh Home; 22 exit; other failure.
# Runtime context: use context-library getters; never source the JSON document.
# Persistent side effects: document every file, command, and network mutation.
# External commands: declare all requirements in metadata and documentation.
# Secret handling: never place keys, mnemonics, or passwords in context/results.
cntools_action_main() {
  local context_file="${1:-}"

  [[ -n "${context_file}" ]] || return 64
  printf '%s\n' 'Action template has no implementation.' >&2
  return 69
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
