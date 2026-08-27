#!/usr/bin/env bash
# CNTools startup and session normalization. Functions only; source from cntools.sh.
# Application globals are consumed by the entrypoint and other core files.
# shellcheck disable=SC2034

cntools_startup_error() {
  local message="${1:-startup failed}"

  if [[ "${CNTOOLS_LOG_READY:-N}" == "Y" ]] &&
     declare -F cntools_log >/dev/null 2>&1; then
    cntools_log ERROR "${message}" || true
  fi
  printf 'CNTools: %s\n' "${message}" >&2
  return 1
}

cntools_startup_require_bash() {
  if (( BASH_VERSINFO[0] < 4 ||
        (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    cntools_startup_error \
      "Bash 4.4 or newer is required (found ${BASH_VERSION:-unknown})."
    return 1
  fi
}

cntools_startup_load_version() {
  local version_file="${CNTOOLS_VERSION_FILE:-}"
  local -a version_lines=()

  [[ -n "${version_file}" && -f "${version_file}" &&
     ! -L "${version_file}" && -s "${version_file}" ]] || {
    cntools_startup_error "VERSION is missing or unsafe: ${version_file:-unset}"
    return 1
  }
  mapfile -t version_lines < "${version_file}" || return 1
  [[ ${#version_lines[@]} -eq 1 &&
     "${version_lines[0]}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    cntools_startup_error "VERSION must contain one MAJOR.MINOR.PATCH value."
    return 1
  }
  CNTOOLS_VERSION="${version_lines[0]}"
}

cntools_startup_usage() {
  cat <<EOF
Usage: cntools.sh [-n|-l|-o] [-a] [-u] [-b BRANCH] [-v] [-h]

CNTools - Cardano pool and wallet operations

  -n          Local node mode (default)
  -l          Light mode using Koios
  -o          Offline mode
  -a          Show advanced features
  -u          Skip the automatic update-availability check
  -b BRANCH   Redeploy from this Guild branch, then exit
  -v          Print the CNTools version
  -h          Show this help
EOF
}

cntools_startup_parse_args() {
  local option=""

  CNTOOLS_MODE="local"
  CNTOOLS_ADVANCED="N"
  CNTOOLS_UPDATE_CHECK_OVERRIDE=""
  CNTOOLS_BRANCH_REQUEST=""
  CNTOOLS_SHOW_VERSION="N"
  CNTOOLS_SHOW_HELP="N"
  OPTIND=1

  while getopts ':nloaub:vh' option; do
    case "${option}" in
      n) CNTOOLS_MODE="local" ;;
      l) CNTOOLS_MODE="light" ;;
      o) CNTOOLS_MODE="offline" ;;
      a) CNTOOLS_ADVANCED="Y" ;;
      u) CNTOOLS_UPDATE_CHECK_OVERRIDE="N" ;;
      b) CNTOOLS_BRANCH_REQUEST="${OPTARG}" ;;
      v) CNTOOLS_SHOW_VERSION="Y" ;;
      h) CNTOOLS_SHOW_HELP="Y" ;;
      :)
        cntools_startup_error "Option -${OPTARG} requires an argument."
        return 2
        ;;
      \?)
        cntools_startup_error "Unknown option -${OPTARG}."
        return 2
        ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ $# -eq 0 ]] || {
    cntools_startup_error "Unexpected positional arguments: $*"
    return 2
  }
}

cntools_startup_require_commands() {
  local command_name=""
  local -a missing=()

  for command_name in awk jq curl tput date env mktemp mkdir chmod mv rm stat stty wc; do
    command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
  done
  if (( ${#missing[@]} > 0 )); then
    cntools_startup_error \
      "Required command(s) missing: ${missing[*]}. Re-run guild-deploy.sh with -s p."
    return 1
  fi
}

cntools_startup_load_env() {
  local env_file="${CNTOOLS_ENV_FILE:-}"
  local env_status=0
  local errexit_was_enabled="N"
  local nounset_was_enabled="N"
  local posix_was_enabled="N"

  [[ "${CNTOOLS_ENV_SOURCED:-N}" != "Y" ]] || {
    cntools_startup_error "The common env bootstrap was requested more than once."
    return 1
  }
  [[ -n "${env_file}" && -f "${env_file}" &&
     ! -L "${env_file}" && -s "${env_file}" ]] || {
    cntools_startup_error "Common env is missing or unsafe: ${env_file:-unset}"
    return 1
  }

  [[ -o errexit ]] && errexit_was_enabled="Y"
  [[ -o nounset ]] && nounset_was_enabled="Y"
  [[ -o posix ]] && posix_was_enabled="Y"

  # The common env remains a legacy compatibility boundary and is not safe
  # under Bash's errexit or nounset modes. Restore the invoking shell options
  # immediately after its one definitions load.
  set +e
  set +u
  # shellcheck source=/dev/null
  . "${env_file}" definitions
  env_status=$?
  if [[ "${posix_was_enabled}" == "Y" ]]; then
    set -o posix
  else
    set +o posix
  fi
  if [[ "${nounset_was_enabled}" == "Y" ]]; then
    set -u
  else
    set +u
  fi
  if [[ "${errexit_was_enabled}" == "Y" ]]; then
    set -e
  else
    set +e
  fi

  if (( env_status != 0 )); then
    cntools_startup_error "Common env definitions failed to load."
    return 1
  fi
  CNTOOLS_ENV_SOURCED="Y"
}

cntools_startup_default_koios_api() {
  case "${1:-}" in
    mainnet) printf 'https://api.koios.rest/api/v1\n' ;;
    guild) printf 'https://guild.koios.rest/api/v1\n' ;;
    preprod) printf 'https://preprod.koios.rest/api/v1\n' ;;
    preview) printf 'https://preview.koios.rest/api/v1\n' ;;
    *) return 1 ;;
  esac
}

cntools_startup_normalize_session() {
  local node_home="${NODE_HOME:-${CNODE_HOME:-}}"
  local path_value=""

  [[ "${DEPLOYMENT_SCHEMA_VERSION:-}" == "1" ]] || {
    cntools_startup_error "A finalized Guild deployment manifest is required."
    return 1
  }
  [[ -n "${node_home}" && -d "${node_home}" && ! -L "${node_home}" ]] || {
    cntools_startup_error "The deployed node home is missing or unsafe: ${node_home:-unset}"
    return 1
  }
  CNTOOLS_NODE_HOME="$(cd -- "${node_home}" && pwd -P)" || return 1
  CNTOOLS_IMPLEMENTATION="${NODE_IMPLEMENTATION:-}"
  case "${CNTOOLS_IMPLEMENTATION}" in
    cnode|dingo|amaru) ;;
    *)
      cntools_startup_error \
        "Unsupported node implementation: ${CNTOOLS_IMPLEMENTATION:-unset}"
      return 1
      ;;
  esac

  CNTOOLS_IMPLEMENTATION_NAME="${NODE_IMPLEMENTATION_DISPLAY_NAME:-${CNTOOLS_IMPLEMENTATION}}"
  CNTOOLS_NETWORK="${NODE_NETWORK:-}"
  [[ -n "${CNTOOLS_NETWORK}" ]] || {
    cntools_startup_error "The deployment network is not defined."
    return 1
  }
  CNTOOLS_SERVICE="${NODE_SERVICE:-}"
  CNTOOLS_ACCOUNT="${G_ACCOUNT:-}"
  CNTOOLS_BRANCH="${BRANCH:-}"
  CNTOOLS_METRICS_PROVIDER="${NODE_METRICS_PROVIDER:-}"
  CNTOOLS_CAPABILITIES="${NODE_DEPLOYMENT_CAPABILITIES:-}"
  CNTOOLS_LOG_DIR="${LOG_DIR:-${CNTOOLS_NODE_HOME}/logs}"
  CNTOOLS_LOG="${CNTOOLS_LOG:-${CNTOOLS_LOG_DIR}/cntools.log}"
  CNTOOLS_TMP_DIR="${TMP_DIR:-/tmp/$(basename "${CNTOOLS_NODE_HOME}")}"
  CNTOOLS_WALLET_DIR="${WALLET_FOLDER:-${CNTOOLS_NODE_HOME}/priv/wallet}"
  CNTOOLS_POOL_DIR="${POOL_FOLDER:-${CNTOOLS_NODE_HOME}/priv/pool}"
  CNTOOLS_ASSET_DIR="${ASSET_FOLDER:-${CNTOOLS_NODE_HOME}/priv/asset}"
  CNTOOLS_DBSYNC_QUERY_DIR="${DBSYNC_QUERY_FOLDER:-${CNTOOLS_NODE_HOME}/files/dbsync/queries}"
  CNTOOLS_UPDATE_CHECK="${CNTOOLS_UPDATE_CHECK_OVERRIDE:-${UPDATE_CHECK:-Y}}"
  CNTOOLS_KOIOS_ENABLED="${ENABLE_KOIOS:-Y}"
  CNTOOLS_KOIOS_API="${KOIOS_API:-}"
  CNTOOLS_KOIOS_TOKEN="${KOIOS_API_TOKEN:-}"
  CNTOOLS_CURL_TIMEOUT="${CURL_TIMEOUT:-10}"

  [[ -n "${CNTOOLS_SERVICE}" &&
     "${CNTOOLS_SERVICE}" != *$'\n'* &&
     "${CNTOOLS_SERVICE}" != *$'\r'* ]] || {
    cntools_startup_error "The deployment service is not defined or is unsafe."
    return 1
  }
  [[ "${CNTOOLS_ACCOUNT}" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    cntools_startup_error "Invalid Guild repository account: ${CNTOOLS_ACCOUNT}"
    return 1
  }
  cntools_startup_branch_valid "${CNTOOLS_BRANCH}" || {
    cntools_startup_error "Invalid Guild branch: ${CNTOOLS_BRANCH}"
    return 1
  }
  [[ -n "${CNTOOLS_METRICS_PROVIDER}" &&
     "${CNTOOLS_METRICS_PROVIDER}" != *$'\n'* &&
     "${CNTOOLS_METRICS_PROVIDER}" != *$'\r'* ]] || {
    cntools_startup_error "The deployment metrics provider is not defined or is unsafe."
    return 1
  }
  jq -e '
    type == "object" and
    keys == ["forging", "localCli", "metrics", "n2c"] and
    all(.[]; type == "boolean")
  ' <<< "${CNTOOLS_CAPABILITIES}" >/dev/null 2>&1 || {
    cntools_startup_error "The deployment capabilities are not defined or are invalid."
    return 1
  }
  case "${CNTOOLS_UPDATE_CHECK}" in Y|N) ;; *)
    cntools_startup_error "UPDATE_CHECK must be Y or N."
    return 1
  esac
  case "${CNTOOLS_KOIOS_ENABLED}" in Y|N) ;; *)
    cntools_startup_error "ENABLE_KOIOS must be Y or N."
    return 1
  esac
  [[ "${CNTOOLS_CURL_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || {
    cntools_startup_error "CURL_TIMEOUT must be a positive integer."
    return 1
  }
  for path_value in \
    "${CNTOOLS_LOG_DIR}" "${CNTOOLS_LOG}" "${CNTOOLS_TMP_DIR}" \
    "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_POOL_DIR}" "${CNTOOLS_ASSET_DIR}" \
    "${CNTOOLS_DBSYNC_QUERY_DIR}"; do
    [[ "${path_value}" = /* && "${path_value}" != *$'\n'* &&
       "${path_value}" != *$'\r'* ]] || {
      cntools_startup_error "CNTools received an unsafe runtime path: ${path_value:-unset}"
      return 1
    }
  done

  if [[ -z "${CNTOOLS_KOIOS_API}" ]]; then
    CNTOOLS_KOIOS_API="$(cntools_startup_default_koios_api "${CNTOOLS_NETWORK}")" || {
      cntools_startup_error \
        "No default Koios endpoint is available for network ${CNTOOLS_NETWORK}."
      return 1
    }
  fi
  [[ "${CNTOOLS_KOIOS_API}" =~ ^https://[^[:space:]]+$ ]] || {
    cntools_startup_error "KOIOS_API must be an HTTPS URL."
    return 1
  }
  [[ "${CNTOOLS_KOIOS_TOKEN}" != *$'\n'* &&
     "${CNTOOLS_KOIOS_TOKEN}" != *$'\r'* ]] || {
    cntools_startup_error "KOIOS_API_TOKEN must not contain line breaks."
    return 1
  }

  case "${CNTOOLS_MODE}" in
    local) CNTOOLS_BACKEND="${CNTOOLS_IMPLEMENTATION}" ;;
    light)
      [[ "${CNTOOLS_KOIOS_ENABLED}" == "Y" ]] || {
        cntools_startup_error "Light mode requires ENABLE_KOIOS=Y."
        return 1
      }
      CNTOOLS_BACKEND="koios"
      ;;
    offline)
      CNTOOLS_BACKEND="none"
      CNTOOLS_UPDATE_CHECK="N"
      ;;
    *)
      cntools_startup_error "Unknown runtime mode: ${CNTOOLS_MODE:-unset}"
      return 1
      ;;
  esac

  CNTOOLS_SESSION_ID="$(command date '+%Y%m%dT%H%M%S')-$$"
  export CNTOOLS_NODE_HOME CNTOOLS_IMPLEMENTATION CNTOOLS_IMPLEMENTATION_NAME
  export CNTOOLS_NETWORK CNTOOLS_SERVICE CNTOOLS_ACCOUNT CNTOOLS_BRANCH
  export CNTOOLS_METRICS_PROVIDER CNTOOLS_CAPABILITIES CNTOOLS_LOG_DIR CNTOOLS_LOG
  export CNTOOLS_TMP_DIR CNTOOLS_WALLET_DIR CNTOOLS_POOL_DIR CNTOOLS_ASSET_DIR
  export CNTOOLS_DBSYNC_QUERY_DIR CNTOOLS_UPDATE_CHECK CNTOOLS_KOIOS_ENABLED
  export CNTOOLS_KOIOS_API CNTOOLS_CURL_TIMEOUT CNTOOLS_MODE CNTOOLS_BACKEND
  export CNTOOLS_ADVANCED CNTOOLS_SESSION_ID
}

cntools_startup_branch_valid() {
  local branch="${1:-}"
  local component=""
  local -a components=()

  [[ "${branch}" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ &&
     "${branch}" != */ && "${branch}" != *..* && "${branch}" != *//* &&
     "${branch}" != *@\{* && "${branch}" != "@" && "${branch}" != *. ]] ||
    return 1
  IFS='/' read -r -a components <<< "${branch}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != .* &&
       "${component}" != *.lock ]] || return 1
  done
}

cntools_startup_mark_deployment_started() {
  local state_file="${CNTOOLS_UPDATE_STATE_FILE:-}"
  local state_dir="${CNTOOLS_UPDATE_STATE_DIR:-}"
  local started_file="${CNTOOLS_DEPLOY_STARTED_FILE:-}"
  local previous_umask=""

  [[ -n "${state_dir}" && -n "${state_file}" && -n "${started_file}" &&
     "${started_file}" == "${state_file}.deploy-started" &&
     "${state_file}" = "${state_dir}/"* &&
     -f "${state_file}" && ! -L "${state_file}" && -O "${state_file}" &&
     ! -e "${started_file}" && ! -L "${started_file}" ]] || return 1
  previous_umask="$(umask)"
  umask 077
  if ( set -o noclobber; : > "${started_file}" ) 2>/dev/null; then
    umask "${previous_umask}"
  else
    umask "${previous_umask}"
    return 1
  fi
  [[ -f "${started_file}" && ! -L "${started_file}" &&
     -O "${started_file}" ]] || return 1
}

cntools_startup_deployment_was_started() {
  local state_file="${CNTOOLS_UPDATE_STATE_FILE:-}"
  local state_dir="${CNTOOLS_UPDATE_STATE_DIR:-}"
  local started_file="${CNTOOLS_DEPLOY_STARTED_FILE:-}"

  [[ -n "${state_dir}" && -n "${state_file}" && -n "${started_file}" &&
     "${started_file}" == "${state_file}.deploy-started" &&
     "${started_file}" = "${state_dir}/"* &&
     -f "${started_file}" && ! -L "${started_file}" &&
     -O "${started_file}" ]]
}

cntools_startup_deploy_branch() {
  local dispatcher="${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh"
  local parent=""
  local name=""
  local branch="${1:-}"
  local mask=""
  local -a command_args=()

  [[ -n "${branch}" ]] || return 2
  [[ "${CNTOOLS_MODE}" != "offline" ]] || {
    cntools_startup_error "Branch redeployment is unavailable in offline mode."
    return 1
  }
  cntools_startup_branch_valid "${branch}" || {
    cntools_startup_error "Invalid Guild branch: ${branch}"
    return 1
  }
  if [[ "${CNTOOLS_LOG_PARENT:-}" == "${CNTOOLS_ROOT}" ||
        "${CNTOOLS_LOG_PARENT:-}" == "${CNTOOLS_ROOT}/"* ]]; then
    cntools_startup_error \
      "Guild Deploy requires CNTOOLS_LOG to be outside the installed CNTools directory."
    return 1
  fi
  parent="$(dirname "${CNTOOLS_NODE_HOME}")"
  name="$(basename "${CNTOOLS_NODE_HOME}")"
  command_args=(
    env
    "G_ACCOUNT=${CNTOOLS_ACCOUNT}"
    "S_ARGS="
    "GUILD_DEPLOY_SNAPSHOT_STAGE=bootstrap"
    "GUILD_DEPLOY_STRICT_REF=Y"
    "${dispatcher}"
    -g "${CNTOOLS_ACCOUNT}"
    -i "${CNTOOLS_IMPLEMENTATION}"
    -n "${CNTOOLS_NETWORK}"
    -p "${parent}"
    -t "${name}"
    -b "${branch}"
    -s ""
  )
  [[ -f "${dispatcher}" && ! -L "${dispatcher}" && -s "${dispatcher}" &&
     -O "${dispatcher}" && -x "${dispatcher}" ]] || {
    cntools_startup_error "Guild Deploy is unavailable: ${dispatcher}"
    printf 'After restoring Guild Deploy, run:\n  ' >&2
    printf '%q ' "${command_args[@]}" >&2
    printf '\n' >&2
    return 1
  }

  printf -v mask '%*s' "${#command_args[@]}" ''
  mask="${mask// /0}"
  cntools_ui_restore_terminal || true
  if [[ -n "${CNTOOLS_DEPLOY_STARTED_FILE:-}" ]]; then
    cntools_startup_mark_deployment_started || {
      cntools_startup_error "Could not record the Guild Deploy lifecycle safely."
      return 1
    }
  fi
  cntools_run_command "${mask}" -- "${command_args[@]}"
}

cntools_startup_redeploy() {
  cntools_startup_deploy_branch "${CNTOOLS_BRANCH_REQUEST:-}"
}
