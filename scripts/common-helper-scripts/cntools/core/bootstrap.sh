#!/usr/bin/env bash
# shellcheck shell=bash
# Stage 3 CNTools shadow-generation bootstrap.
#
# The modular generation is deliberately shadow-only. This file validates its
# complete immutable payload and exposes diagnostics, but it does not dispatch
# the production menu or replace the legacy public scripts/cntools.sh.

_cntools_bootstrap_usage() {
  builtin printf '%s\n' \
'Usage: cntools.sh [--validate-generation | --validate-modules | --dump-menu | --version | --help]' \
'' \
'This modular CNTools generation is installed in shadow mode. The production' \
'entrypoint remains scripts/cntools.sh until the dispatcher cutover stage.'
}

# Purpose: validate and enter the Stage 3 modular CNTools generation.
# Parameters: absolute generation root followed by launcher arguments.
# Result: diagnostic version/validation output; no interactive workflow yet.
# Status: 0 successful diagnostic, 2 invalid/incomplete generation or request.
# Context/side effects: reads only this immutable generation.
# External commands/secrets: jq and a SHA-256 utility; reads no secret data.
cntools_bootstrap_main() {
  local runtime_root="${1:-}"
  local lifecycle="" generation_id="" command=""
  local registry="" modules_root="" library_manifest=""
  local menu_dump="" jq_path=""

  [[ -n "${runtime_root}" ]] || return 2
  shift
  if (( BASH_VERSINFO[0] < 4 ||
        (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    builtin printf 'CNTools requires GNU Bash 4.4 or newer.\n' >&2
    return 2
  fi
  [[ "${runtime_root}" == /* && -d "${runtime_root}" &&
     ! -L "${runtime_root}" ]] || return 2
  generation_id="${runtime_root##*/}"
  [[ "${generation_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  lifecycle="${runtime_root}/cntools/core/lifecycle.sh"
  [[ -f "${lifecycle}" && ! -L "${lifecycle}" ]] || return 2
  # shellcheck source=/dev/null
  builtin source "${lifecycle}" || return 2
  cntools_generation_validate "${runtime_root}" "${generation_id}" || return 2

  command="${1:---help}"
  shift || true
  [[ $# -eq 0 ]] || {
    _cntools_bootstrap_usage >&2
    return 2
  }
  case "${command}" in
    --validate-modules|--dump-menu)
      registry="${runtime_root}/cntools/core/registry.sh"
      modules_root="${runtime_root}/cntools/modules"
      library_manifest="${runtime_root}/cntools/libs/manifest.json"

      # The installed launcher owns provenance. This internal canary sources the
      # registry only after lifecycle validation of the complete generation.
      if [[ ! -f "${registry}" || -L "${registry}" ]] ||
         ! builtin source "${registry}" >/dev/null 2>&1 ||
         ! builtin declare -F cntools_registry_dump_menu >/dev/null 2>&1 ||
         ! menu_dump="$(cntools_registry_dump_menu \
              "${modules_root}" "${library_manifest}" 2>/dev/null)" ||
         ! _cntools_registry_tool_path jq jq_path ||
         ! "${jq_path}" -e '
             type == "object" and
             keys == ["counts", "menus", "moduleSchemaVersion", "schemaVersion"] and
             .schemaVersion == 1 and .moduleSchemaVersion == 2 and
             .counts == {
               actions: 54, controls: 22, menus: 15, modules: 69, options: 90
             } and (.menus | length) == 15
           ' <<< "${menu_dump}" >/dev/null 2>&1; then
        builtin printf '%s\n' 'CNTools module registry validation failed.' >&2
        return 2
      fi
      if [[ "${command}" == "--validate-modules" ]]; then
        builtin printf '%s\n' \
          'CNTools module registry is valid (69 modules: 15 menus, 54 actions; 22 controls; 90 options).'
      else
        builtin printf '%s\n' "${menu_dump}"
      fi
      ;;
    --validate-generation)
      builtin printf 'CNTools generation %s is valid (shadow).\n' "${generation_id}"
      ;;
    --version)
      builtin printf 'CNTools %s (shadow generation %s)\n' \
        "$(< "${runtime_root}/cntools/VERSION")" "${generation_id}"
      ;;
    --help|-h)
      _cntools_bootstrap_usage
      ;;
    *)
      builtin printf \
        'The modular CNTools generation is not the production dispatcher yet.\n' >&2
      _cntools_bootstrap_usage >&2
      return 2
      ;;
  esac
}
