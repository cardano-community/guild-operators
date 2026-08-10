#!/usr/bin/env bash
# Guild Operators launcher for an experimental Dingo node.
set -euo pipefail

DINGO_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DINGO_ENV_FILE="${DINGO_ENV_FILE:-${DINGO_SCRIPT_DIR}/dingo.env}"
command_name="${1:-run}"
[[ $# -gt 0 ]] && shift

GUILD_NODE_HOME="$(cd -- "${DINGO_SCRIPT_DIR}/.." && pwd -P)"
_launcher_node_home="${GUILD_NODE_HOME}"
_launcher_default_service="$(basename "${GUILD_NODE_HOME}" | tr '[:upper:]' '[:lower:]')"
GUILD_NODE_SERVICE="${_launcher_default_service}"
GUILD_NODE_IMPLEMENTATION="dingo"
_manifest_file="${GUILD_NODE_HOME}/.deployment.json"

dingo_manifest_value() {
  local key="$1"
  jq -er --arg key "${key}" '.[$key] // empty' "${_manifest_file}" 2>/dev/null
}

_manifest_implementation=""
_manifest_service=""
_manifest_network=""
_manifest_required="Y"
case "${command_name}" in
  -h|--help|help) _manifest_required="N" ;;
esac

if [[ "${_manifest_required}" == "Y" && ! -f "${_manifest_file}" ]]; then
  printf 'ERROR: a finalized deployment manifest is required: %s\n' \
    "${_manifest_file}" >&2
  exit 1
fi

if [[ "${_manifest_required}" == "Y" ]]; then
  command -v jq >/dev/null 2>&1 || {
    printf 'ERROR: jq is required to validate %s\n' "${_manifest_file}" >&2
    exit 1
  }
  if ! jq -e '
    type == "object" and
    .schemaVersion == 1 and
    .deploymentStatus == "deployed" and
    .implementation == "dingo" and
    (.network == "preprod" or .network == "preview") and
    (.branch | type == "string" and length > 0) and
    (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/guild-operators$")) and
    (.serviceName | type == "string" and length > 0) and
    (.nodeVersion | type == "string") and
    (.targetNodeVersion | type == "string") and
    .metricsProvider == "prometheus" and
    (.capabilities | type == "object") and
    (.capabilities | keys == ["forging", "localCli", "metrics", "n2c"]) and
    (.capabilities.n2c == true) and
    (.capabilities.localCli == true) and
    (.capabilities.metrics == true) and
    (.capabilities.forging == true)
  ' "${_manifest_file}" >/dev/null 2>&1; then
    printf 'ERROR: deployment manifest is malformed, incomplete, unsupported, or not finalized: %s\n' \
      "${_manifest_file}" >&2
    exit 1
  fi
  _manifest_implementation="$(dingo_manifest_value implementation)"
  _manifest_service="$(dingo_manifest_value serviceName)"
  _manifest_network="$(dingo_manifest_value network)"
  if [[ "${_manifest_service}" != "${_launcher_default_service}" ]]; then
    printf 'ERROR: deployment manifest serviceName %s does not match launcher target %s\n' \
      "${_manifest_service}" "${_launcher_default_service}" >&2
    exit 1
  fi
fi
[[ -n "${_manifest_implementation}" ]] && GUILD_NODE_IMPLEMENTATION="${_manifest_implementation}"
[[ -n "${_manifest_service}" ]] && GUILD_NODE_SERVICE="${_manifest_service}"
[[ -n "${_manifest_network}" ]] && CARDANO_NETWORK="${_manifest_network}"

if [[ -r "${DINGO_ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${DINGO_ENV_FILE}"
  set +a
else
  case "${command_name}" in
    remove|status|start|stop|restart|logs|-h|--help|help) ;;
    *)
      printf 'ERROR: Dingo environment file is missing: %s\n' "${DINGO_ENV_FILE}" >&2
      exit 1
      ;;
  esac
fi

_env_node_home="${GUILD_NODE_HOME:-}"
_env_node_home_resolved="${_env_node_home}"
if [[ -n "${_env_node_home}" && -d "${_env_node_home}" ]]; then
  _env_node_home_resolved="$(cd -- "${_env_node_home}" && pwd -P)"
fi
_env_node_service="${GUILD_NODE_SERVICE:-}"
_env_node_implementation="${GUILD_NODE_IMPLEMENTATION:-}"
_env_node_network="${CARDANO_NETWORK:-}"

# The launcher location and deployment manifest own service identity. The
# implementation environment may configure runtime details, but it cannot
# redirect lifecycle commands to another deployment or unit.
GUILD_NODE_HOME="${_launcher_node_home}"
GUILD_NODE_SERVICE="${_manifest_service:-${_env_node_service:-${_launcher_default_service}}}"
GUILD_NODE_IMPLEMENTATION="${_manifest_implementation:-${_env_node_implementation:-dingo}}"
CARDANO_NETWORK="${_manifest_network:-${_env_node_network:-}}"

case "${command_name}" in
  run|bootstrap|-d|install|version)
    if [[ -n "${_env_node_home_resolved}" &&
          "${_env_node_home_resolved}" != "${GUILD_NODE_HOME}" ]] ||
       [[ -n "${_manifest_service}" && -n "${_env_node_service}" &&
          "${_env_node_service}" != "${_manifest_service}" ]] ||
       [[ -n "${_manifest_implementation}" && -n "${_env_node_implementation}" &&
          "${_env_node_implementation}" != "${_manifest_implementation}" ]] ||
       [[ -n "${_manifest_network}" && -n "${_env_node_network}" &&
          "${_env_node_network}" != "${_manifest_network}" ]]; then
      printf 'ERROR: Dingo environment identity conflicts with .deployment.json; re-run guild-deploy.sh with -s f\n' >&2
      exit 1
    fi
    ;;
esac

DINGO_SYSTEMD_LIBRARY="${DINGO_SCRIPT_DIR}/lib/systemd.library"
if [[ ! -r "${DINGO_SYSTEMD_LIBRARY}" ]]; then
  printf 'ERROR: common systemd library is missing\n' >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${DINGO_SYSTEMD_LIBRARY}"

: "${DINGO_BIN:=${HOME}/.local/bin/dingo}"
: "${DINGO_CONFIG:=${GUILD_NODE_HOME}/files/dingo.yaml}"
: "${POOL_FOLDER:=${GUILD_NODE_HOME}/priv/pool}"
: "${POOL_NAME:=CHANGE_ME}"
: "${POOL_DIR:=${POOL_FOLDER}/${POOL_NAME}}"
: "${POOL_HOTKEY_SK_FILENAME:=hot.skey}"
: "${POOL_VRF_SK_FILENAME:=vrf.skey}"
: "${POOL_OPCERT_FILENAME:=op.cert}"

export DINGO_STORAGE_MODE=core
export DINGO_RUN_MODE=serve
DINGO_RUNTIME_ROLE="relay"

dingo_usage() {
  cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  run                 Run in the foreground (default)
  bootstrap           Import a certified Mithril snapshot
  -d, install         Install and enable (but do not start) the systemd service
  remove              Stop, disable, and remove the systemd service
  status              Show systemd service status
  start|stop|restart  Control the installed systemd service
  logs                Follow service logs
  version             Print the installed Dingo version
  -h, --help          Show this help

Dingo support, including block production, is experimental. Only preprod and
preview are accepted by this launcher. A complete operational hot-key set in
POOL_DIR enables block production; otherwise Dingo runs as a relay.
EOF
}

dingo_require_identity() {
  if [[ "${GUILD_NODE_IMPLEMENTATION:-}" != "dingo" ]]; then
    printf 'ERROR: environment selects %s, expected dingo\n' "${GUILD_NODE_IMPLEMENTATION:-unset}" >&2
    return 1
  fi
  if [[ ! "${GUILD_NODE_SERVICE}" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
    printf 'ERROR: invalid Dingo service name: %s\n' "${GUILD_NODE_SERVICE}" >&2
    return 1
  fi
  if [[ ! "${GUILD_NODE_HOME}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]; then
    printf 'ERROR: deployment path contains characters unsafe for generated configuration\n' >&2
    return 1
  fi
}

dingo_require_environment() {
  dingo_require_identity || return 1
  case "${CARDANO_NETWORK:-}" in
    preprod|preview) ;;
    *)
      printf 'ERROR: this experimental profile supports only preprod or preview, got %s\n' "${CARDANO_NETWORK:-unset}" >&2
      return 1
      ;;
  esac
  if [[ ! "${DINGO_BIN}" =~ ^/[A-Za-z0-9._/+@:-]+$ ||
        ! "${DINGO_CONFIG}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]; then
    printf 'ERROR: deployment paths contain characters unsafe for generated configuration\n' >&2
    return 1
  fi
}

dingo_require_supported_profile() {
  dingo_require_environment || return 1
  if [[ ! -x "${DINGO_BIN}" ]]; then
    printf 'ERROR: Dingo binary is missing or not executable: %s\n' "${DINGO_BIN}" >&2
    return 1
  fi
  if [[ ! -r "${DINGO_CONFIG}" ]]; then
    printf 'ERROR: Dingo config is missing: %s\n' "${DINGO_CONFIG}" >&2
    return 1
  fi
  if ! grep -Eq '^[[:space:]]*blockProducer:[[:space:]]*false([[:space:]]|$)' "${DINGO_CONFIG}"; then
    printf 'ERROR: the Guild Dingo base config must keep blockProducer false; dingo.sh enables it from POOL_DIR\n' >&2
    return 1
  fi
}

dingo_secret_file_is_private() {
  local file="$1"
  local permissions owner
  permissions="$(
    stat -Lc '%a' "${file}" 2>/dev/null ||
      stat -f '%Lp' "${file}" 2>/dev/null
  )" || return 1
  owner="$(
    stat -Lc '%u' "${file}" 2>/dev/null ||
      stat -f '%u' "${file}" 2>/dev/null
  )" || return 1
  [[ "${permissions}" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "${owner}" == "$(id -u)" ]] || return 1
  (( (8#${permissions} & 077) == 0 ))
}

dingo_configure_runtime_role() {
  local mode="${1:-run}"
  local kes_file="${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}"
  local vrf_file="${POOL_DIR}/${POOL_VRF_SK_FILENAME}"
  local opcert_file="${POOL_DIR}/${POOL_OPCERT_FILENAME}"
  local present=0
  local file
  local -a missing=()

  export CARDANO_BLOCK_PRODUCER=false
  unset CARDANO_SHELLEY_KES_KEY CARDANO_SHELLEY_VRF_KEY
  unset CARDANO_SHELLEY_OPERATIONAL_CERTIFICATE
  DINGO_RUNTIME_ROLE="relay"

  # Snapshot import never forges and should not require online hot keys.
  [[ "${mode}" == "bootstrap" ]] && return 0

  if [[ ! "${POOL_DIR}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]; then
    printf 'ERROR: POOL_DIR must be an absolute deployment-safe path: %s\n' \
      "${POOL_DIR}" >&2
    return 1
  fi

  for file in "${kes_file}" "${vrf_file}" "${opcert_file}"; do
    [[ -e "${file}" ]] && ((present += 1))
  done
  (( present == 0 )) && return 0

  for file in "${kes_file}" "${vrf_file}" "${opcert_file}"; do
    [[ -f "${file}" && -r "${file}" ]] || missing+=("${file}")
  done
  if (( ${#missing[@]} > 0 )); then
    printf 'ERROR: POOL_DIR contains an incomplete Dingo block-producer credential set. Missing or unreadable:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi

  if ! dingo_secret_file_is_private "${kes_file}"; then
    printf 'ERROR: KES signing key must be owned by uid %s with no group/other permissions: %s\n' \
      "$(id -u)" "${kes_file}" >&2
    return 1
  fi
  if ! dingo_secret_file_is_private "${vrf_file}"; then
    printf 'ERROR: VRF signing key must be owned by uid %s with no group/other permissions: %s\n' \
      "$(id -u)" "${vrf_file}" >&2
    return 1
  fi

  export CARDANO_BLOCK_PRODUCER=true
  export CARDANO_SHELLEY_KES_KEY="${kes_file}"
  export CARDANO_SHELLEY_VRF_KEY="${vrf_file}"
  export CARDANO_SHELLEY_OPERATIONAL_CERTIFICATE="${opcert_file}"
  DINGO_RUNTIME_ROLE="producer"
}

dingo_install_service() {
  command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1 || {
    printf 'ERROR: systemd is required to install the service\n' >&2
    return 1
  }

  local service_user service_group unit_name unit_content
  service_user="$(id -un)"
  service_group="$(id -gn)"
  unit_name="${GUILD_NODE_SERVICE}.service"
  unit_content="$(cat <<EOF
[Unit]
Description=Guild Operators Dingo experimental node (${CARDANO_NETWORK})
Documentation=https://github.com/blinklabs-io/dingo
Wants=network-online.target time-sync.target
After=network-online.target time-sync.target
ConditionPathExists=${DINGO_BIN}

[Service]
Type=simple
User=${service_user}
Group=${service_group}
WorkingDirectory=${GUILD_NODE_HOME}
ExecStart=${DINGO_SCRIPT_DIR}/dingo.sh run
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
LimitNOFILE=65536
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${GUILD_NODE_HOME}
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
)"

  systemd_install_unit "${unit_name}" "${unit_content}" "${DINGO_SCRIPT_DIR}/dingo.sh" || return 1
  systemd_daemon_reload || return 1
  systemd_enable_units "${unit_name}" || return 1
  printf 'Installed %s for Dingo %s mode.\n' "${unit_name}" "${DINGO_RUNTIME_ROLE}"
}

dingo_remove_service() {
  command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1 || {
    printf 'ERROR: systemd is required to remove the service\n' >&2
    return 1
  }
  systemd_remove_units --owner-token "${DINGO_SCRIPT_DIR}/dingo.sh" \
    "${GUILD_NODE_SERVICE}.service" || return 1
  printf 'Removed %s.service; node data was left intact in %s.\n' "${GUILD_NODE_SERVICE}" "${GUILD_NODE_HOME}"
}

case "${command_name}" in
  run)
    dingo_require_supported_profile
    dingo_configure_runtime_role run
    cd -- "${GUILD_NODE_HOME}"
    exec "${DINGO_BIN}" --config "${DINGO_CONFIG}" serve "$@"
    ;;
  bootstrap)
    dingo_require_supported_profile
    dingo_configure_runtime_role bootstrap
    cd -- "${GUILD_NODE_HOME}"
    exec "${DINGO_BIN}" --config "${DINGO_CONFIG}" sync --mithril "$@"
    ;;
  -d|install)
    dingo_require_supported_profile
    dingo_configure_runtime_role run
    dingo_install_service
    ;;
  remove)
    dingo_require_identity
    dingo_remove_service
    ;;
  status)
    dingo_require_identity
    systemd_status_units "${GUILD_NODE_SERVICE}.service"
    ;;
  start|stop|restart)
    dingo_require_identity
    systemd_control "${command_name}" "${GUILD_NODE_SERVICE}.service"
    ;;
  logs)
    dingo_require_identity
    systemd_as_root journalctl -fu "${GUILD_NODE_SERVICE}.service"
    ;;
  version)
    dingo_require_supported_profile
    exec "${DINGO_BIN}" version
    ;;
  -h|--help|help)
    dingo_usage
    ;;
  *)
    printf 'ERROR: unknown command: %s\n\n' "${command_name}" >&2
    dingo_usage >&2
    exit 2
    ;;
esac
