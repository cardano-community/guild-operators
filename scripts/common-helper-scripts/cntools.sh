#!/usr/bin/env bash
# Stable public launcher for the modular CNTools application.

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf 'CNTools: cntools.sh must be executed, not sourced.\n' >&2
  return 1
fi

if [[ -L "${BASH_SOURCE[0]}" ]]; then
  printf 'CNTools: the launcher must not be a symbolic link.\n' >&2
  exit 1
fi

_cntools_launcher_dir="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P
)" || {
  printf 'CNTools: could not resolve the launcher directory.\n' >&2
  exit 1
}
_cntools_app_dir="${_cntools_launcher_dir}/cntools"
_cntools_main="${_cntools_app_dir}/cntools_main.sh"
_cntools_deployer="${_cntools_launcher_dir}/guild-deploy.sh"

_cntools_print_recovery() {
  printf 'CNTools: re-run %s to restore the managed application.\n' \
    "${_cntools_deployer}" >&2
}

if [[ ! -d "${_cntools_app_dir}" || -L "${_cntools_app_dir}" ]]; then
  printf 'CNTools: the managed application directory is missing or unsafe: %s\n' \
    "${_cntools_app_dir}" >&2
  _cntools_print_recovery
  exit 1
fi

_cntools_caller_dir="$(pwd -P 2>/dev/null)" || {
  printf 'CNTools: the current directory cannot be resolved. Change directories and try again.\n' >&2
  exit 1
}
if [[ "${_cntools_caller_dir}" == "${_cntools_app_dir}" ||
      "${_cntools_caller_dir}" == "${_cntools_app_dir}/"* ]]; then
  printf 'CNTools: do not start CNTools while this shell is inside the managed CNTools directory.\n' >&2
  printf 'CNTools: change to %s and run ./cntools.sh instead.\n' \
    "${_cntools_launcher_dir}" >&2
  exit 1
fi

if [[ ! -f "${_cntools_main}" || -L "${_cntools_main}" ||
      ! -s "${_cntools_main}" || ! -x "${_cntools_main}" ]]; then
  printf 'CNTools: the application entrypoint is missing or unsafe: %s\n' \
    "${_cntools_main}" >&2
  _cntools_print_recovery
  exit 1
fi

cd -- "${_cntools_launcher_dir}" || {
  printf 'CNTools: could not enter the stable scripts directory: %s\n' \
    "${_cntools_launcher_dir}" >&2
  exit 1
}

exec "${_cntools_main}" "$@"
