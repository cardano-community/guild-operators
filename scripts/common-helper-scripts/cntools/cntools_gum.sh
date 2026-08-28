#!/usr/bin/env bash
# Experimental Charm Gum entrypoint for CNTools.
# The regular cntools.sh entrypoint remains the Gum-free UI.
# shellcheck disable=SC2034

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools: Bash 4.4 or newer is required (found %s).\n' \
    "${BASH_VERSION:-unknown}" >&2
  exit 1
fi

if [[ -L "${BASH_SOURCE[0]}" ]]; then
  printf 'CNTools: the entrypoint must not be a symbolic link.\n' >&2
  exit 1
fi

CNTOOLS_GUM_BOOTSTRAP_ROOT="$(
  cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P
)" || exit 1
CNTOOLS_GUM_ENTRYPOINT="${CNTOOLS_GUM_BOOTSTRAP_ROOT}/$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${CNTOOLS_GUM_BOOTSTRAP_ROOT}/cntools.sh" ||
      -L "${CNTOOLS_GUM_BOOTSTRAP_ROOT}/cntools.sh" ||
      ! -s "${CNTOOLS_GUM_BOOTSTRAP_ROOT}/cntools.sh" ]]; then
  printf 'CNTools: the base entrypoint is missing or unsafe.\n' >&2
  exit 1
fi

# Load the existing startup, logging, update, catalog and action framework.
# cntools.sh only invokes its main function when executed directly.
# shellcheck source=cntools.sh
. "${CNTOOLS_GUM_BOOTSTRAP_ROOT}/cntools.sh" || exit 1

# cntools.sh identifies itself while it is loaded. Restore the real entrypoint
# so self-redeployment and diagnostics refer to this parallel interface.
CNTOOLS_ENTRYPOINT="${CNTOOLS_GUM_ENTRYPOINT}"
export CNTOOLS_ENTRYPOINT

if [[ ! -f "${CNTOOLS_CORE_DIR}/gum.sh" ||
      -L "${CNTOOLS_CORE_DIR}/gum.sh" ||
      ! -s "${CNTOOLS_CORE_DIR}/gum.sh" ]]; then
  printf 'CNTools: Gum UI support is missing or unsafe: %s\n' \
    "${CNTOOLS_CORE_DIR}/gum.sh" >&2
  exit 1
fi
# shellcheck source=core/gum.sh
. "${CNTOOLS_CORE_DIR}/gum.sh" || exit 1

if [[ ! -f "${CNTOOLS_CORE_DIR}/health.sh" ||
      -L "${CNTOOLS_CORE_DIR}/health.sh" ||
      ! -s "${CNTOOLS_CORE_DIR}/health.sh" ]]; then
  printf 'CNTools: health UI support is missing or unsafe: %s\n' \
    "${CNTOOLS_CORE_DIR}/health.sh" >&2
  exit 1
fi
# shellcheck source=core/health.sh
. "${CNTOOLS_CORE_DIR}/health.sh" || exit 1

cntools_gum_main() {
  local status=0

  cntools_startup_require_bash || return 1
  cntools_startup_parse_args "$@" || {
    cntools_gum_usage >&2
    return 2
  }
  if [[ "${CNTOOLS_SHOW_HELP}" == "Y" ]]; then
    cntools_gum_usage
    return 0
  fi
  if [[ -z "${CNTOOLS_BRANCH_REQUEST}" ]]; then
    cntools_startup_load_version || return 1
    if [[ "${CNTOOLS_SHOW_VERSION}" == "Y" ]]; then
      printf '%s\n' "${CNTOOLS_VERSION}"
      return 0
    fi
  fi

  cntools_startup_require_commands || return 1
  cntools_startup_load_env || return 1
  cntools_startup_normalize_session || return 1
  cntools_log_init || return 1
  CNTOOLS_SESSION_ENDED="N"
  cntools_entrypoint_install_traps
  cntools_log SESSION \
    "start ui=gum mode=${CNTOOLS_MODE} backend=${CNTOOLS_BACKEND} implementation=${CNTOOLS_IMPLEMENTATION} network=${CNTOOLS_NETWORK} account=${CNTOOLS_ACCOUNT} branch=${CNTOOLS_BRANCH}" ||
    return 1

  # Redeployment is deliberately available without Gum. This makes recovery
  # possible even when the optional interface prerequisite is unavailable.
  if [[ -n "${CNTOOLS_BRANCH_REQUEST}" ]]; then
    cntools_log SESSION "redeploy branch=${CNTOOLS_BRANCH_REQUEST}" || true
    if cntools_startup_redeploy; then
      status=0
    else
      status=$?
    fi
    return "${status}"
  fi

  cntools_gum_require || return 1
  cntools_gum_require_terminal || return 1
  cntools_update_init
  cntools_ui_init || return 1
  if ! cntools_menu_cache_build; then
    cntools_log ERROR "${CNTOOLS_MENU_ERROR}" || true
    printf 'CNTools: %s\n' "${CNTOOLS_MENU_ERROR}" >&2
    return 1
  fi
  cntools_gum_menu_run
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cntools_gum_main "$@"
fi
