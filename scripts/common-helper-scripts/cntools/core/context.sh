#!/usr/bin/env bash
# Read-only accessors for the future clean-child CNTools context ABI.
# This Stage 1 file defines functions only and is not used by legacy CNTools.

# Purpose: validate the complete version-1, secret-free context document.
# Parameters: context JSON file.
# Result: no output.
# Status: 0 valid; 1 unsafe/malformed; 2 jq unavailable.
# Runtime context/side effects: reads the supplied file; no persistent writes.
# External commands: jq. Secrets are rejected by the closed schema.
cntools_context_validate() {
  local context_file="${1:-}"

  command -v jq >/dev/null 2>&1 || return 2
  [[ -f "${context_file}" && ! -L "${context_file}" ]] || return 1
  jq -e '
    def identifiers:
      type == "array" and
      (length == (unique | length)) and
      all(.[]; type == "string" and test("^[a-z][a-z0-9.-]{0,127}$"));
    type == "object" and
    keys == [
      "advanced",
      "apiVersion",
      "capabilities",
      "features",
      "generationVersion",
      "mode",
      "nodeHome",
      "nodeImplementation",
      "nodeNetwork",
      "schemaVersion"
    ] and
    .schemaVersion == 1 and
    .apiVersion == 1 and
    (.generationVersion | type == "string" and
      test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.mode == "local" or .mode == "light" or .mode == "offline") and
    (.advanced | type == "boolean") and
    (.nodeImplementation == "cnode" or .nodeImplementation == "dingo") and
    (.nodeNetwork | type == "string" and
      test("^(mainnet|guild|preprod|preview)$")) and
    (
      .nodeImplementation == "cnode" or
      (.nodeNetwork == "preprod" or .nodeNetwork == "preview")
    ) and
    (.nodeHome | type == "string" and
      test("^/[A-Za-z0-9._/+@:-]+$") and
      (contains("//") | not) and
      (split("/") | all(. != "." and . != ".."))) and
    (.features | identifiers) and
    (.capabilities | identifiers)
  ' "${context_file}" >/dev/null 2>&1
}

# Purpose: return one allowlisted scalar from a validated context.
# Parameters: context JSON file, field name.
# Result: literal scalar on stdout.
# Status: 0 success, 1 invalid context/field, 2 jq unavailable.
# Runtime context/side effects: reads context only; no writes.
# External commands: jq. Secret-bearing fields are not part of the allowlist.
cntools_context_get() {
  local context_file="${1:-}"
  local field="${2:-}"

  case "${field}" in
    schemaVersion|apiVersion|generationVersion|mode|advanced|nodeHome|\
      nodeImplementation|nodeNetwork)
      ;;
    *) return 1 ;;
  esac
  cntools_context_validate "${context_file}" || return $?
  jq -er --arg field "${field}" '.[$field]' "${context_file}" 2>/dev/null
}

# Purpose: test membership in the context feature or capability set.
# Parameters: context JSON file, features|capabilities, stable identifier.
# Result: no output.
# Status: 0 present, 1 absent/invalid, 2 jq unavailable.
# Runtime context/side effects: reads context only; no writes.
# External commands: jq. No secrets are accepted.
cntools_context_has() {
  local context_file="${1:-}"
  local collection="${2:-}"
  local identifier="${3:-}"

  [[ "${collection}" == "features" || "${collection}" == "capabilities" ]] || return 1
  [[ "${identifier}" =~ ^[a-z][a-z0-9.-]{0,127}$ ]] || return 1
  cntools_context_validate "${context_file}" || return $?
  jq -e --arg collection "${collection}" --arg identifier "${identifier}" \
    '.[$collection] | index($identifier) != null' "${context_file}" \
    >/dev/null 2>&1
}
