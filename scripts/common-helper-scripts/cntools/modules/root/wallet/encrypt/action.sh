#!/usr/bin/env bash
# Inert Stage 3 shadow action. Sourcing defines functions only.

cntools_action_main() {
  printf '%s\n' 'CNTools action execution is inactive in Stage 3 shadow mode.' >&2
  return 69
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
