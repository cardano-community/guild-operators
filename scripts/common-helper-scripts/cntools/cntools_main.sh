#!/usr/bin/env bash
# CNTools modular entrypoint using the Charm Gum interface.
# Application globals are consumed by separately sourced core files.
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

CNTOOLS_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
CNTOOLS_ENTRYPOINT="${CNTOOLS_ROOT}/cntools_main.sh"
CNTOOLS_CORE_DIR="${CNTOOLS_ROOT}/core"
CNTOOLS_LIB_DIR="${CNTOOLS_ROOT}/lib"
CNTOOLS_MODULE_ROOT="${CNTOOLS_ROOT}/modules/root"
CNTOOLS_VERSION_FILE="${CNTOOLS_ROOT}/VERSION"
CNTOOLS_ENV_FILE="$(cd -- "${CNTOOLS_ROOT}/.." && pwd -P)/env"
CNTOOLS_ENV_SOURCED="N"
export CNTOOLS_ROOT CNTOOLS_ENTRYPOINT CNTOOLS_CORE_DIR CNTOOLS_LIB_DIR
export CNTOOLS_MODULE_ROOT CNTOOLS_VERSION_FILE CNTOOLS_ENV_FILE

CNTOOLS_NUMBER_LIBRARY="${CNTOOLS_LIB_DIR}/number.sh"
if [[ ! -f "${CNTOOLS_NUMBER_LIBRARY}" ||
      -L "${CNTOOLS_NUMBER_LIBRARY}" ||
      ! -s "${CNTOOLS_NUMBER_LIBRARY}" ]]; then
  printf 'CNTools: shared library is missing or unsafe: %s\n' \
    "${CNTOOLS_NUMBER_LIBRARY}" >&2
  exit 1
fi
# Number formatting is also used by the always-visible health header. Actions
# continue to declare this library explicitly so their dependencies remain
# complete and independently testable.
# shellcheck source=/dev/null
. "${CNTOOLS_NUMBER_LIBRARY}" || exit 1

for CNTOOLS_CORE_FILE in \
  startup.sh log.sh update.sh menu.sh action.sh theme.sh settings.sh gum.sh health.sh; do
  if [[ ! -f "${CNTOOLS_CORE_DIR}/${CNTOOLS_CORE_FILE}" ||
        -L "${CNTOOLS_CORE_DIR}/${CNTOOLS_CORE_FILE}" ||
        ! -s "${CNTOOLS_CORE_DIR}/${CNTOOLS_CORE_FILE}" ]]; then
    printf 'CNTools: core file is missing or unsafe: %s\n' \
      "${CNTOOLS_CORE_DIR}/${CNTOOLS_CORE_FILE}" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "${CNTOOLS_CORE_DIR}/${CNTOOLS_CORE_FILE}" || exit 1
done
unset CNTOOLS_CORE_FILE

cntools_entrypoint_cleanup() {
  local status="${1:-0}"

  trap - EXIT HUP INT QUIT TERM WINCH TSTP CONT
  if [[ "${CNTOOLS_LOG_READY:-N}" == "Y" &&
        "${CNTOOLS_SESSION_ENDED:-N}" != "Y" ]]; then
    cntools_log SESSION "end status=${status}" || true
    CNTOOLS_SESSION_ENDED="Y"
  fi
  cntools_ui_cleanup || true
  if declare -F cntools_wallet_query_cleanup >/dev/null 2>&1; then
    cntools_wallet_query_cleanup || true
  fi
  cntools_theme_cleanup || true
  cntools_settings_cleanup || true
  cntools_update_cleanup || true
  cntools_log_close || true
  exit "${status}"
}

cntools_entrypoint_install_traps() {
  trap 'cntools_entrypoint_cleanup $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM
  trap 'cntools_ui_mark_resize' WINCH
  trap 'cntools_ui_suspend_for_job_control' TSTP
  trap 'cntools_ui_mark_resize' CONT
}

cntools_main() {
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
  cntools_theme_init || return 1
  cntools_settings_init || return 1
  CNTOOLS_SESSION_ENDED="N"
  cntools_entrypoint_install_traps
  cntools_log SESSION \
    "start ui=gum theme=${CNTOOLS_THEME_ID} selection=${CNTOOLS_TX_SELECTION_STRATEGY} token_fragmentation=${CNTOOLS_TX_TOKEN_FRAGMENTATION} utxo_management=${CNTOOLS_TX_UTXO_MANAGEMENT} mode=${CNTOOLS_MODE} backend=${CNTOOLS_BACKEND} implementation=${CNTOOLS_IMPLEMENTATION} network=${CNTOOLS_NETWORK} socket=${CNTOOLS_SOCKET:-none} account=${CNTOOLS_ACCOUNT} branch=${CNTOOLS_BRANCH}" ||
    return 1

  # Branch redeployment remains available without Gum so a missing UI
  # prerequisite cannot prevent recovery from another Guild branch.
  if [[ -n "${CNTOOLS_BRANCH_REQUEST}" ]]; then
    cntools_log SESSION "redeploy branch=${CNTOOLS_BRANCH_REQUEST}" || true
    if cntools_startup_redeploy; then
      status=0
    else
      status=$?
    fi
    return "${status}"
  fi

  cntools_startup_use_utf8_locale || return 1
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
  cntools_main "$@"
fi
