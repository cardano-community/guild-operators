#!/usr/bin/env bash
# Guild Operators launcher for an experimental Amaru relay.
set -euo pipefail

AMARU_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AMARU_ENV_FILE="${AMARU_ENV_FILE:-${AMARU_SCRIPT_DIR}/amaru.env}"
command_name="${1:-run}"
[[ $# -gt 0 ]] && shift

GUILD_NODE_HOME="$(cd -- "${AMARU_SCRIPT_DIR}/.." && pwd -P)"
_launcher_node_home="${GUILD_NODE_HOME}"
_launcher_default_service="$(basename "${GUILD_NODE_HOME}" | tr '[:upper:]' '[:lower:]')"
GUILD_NODE_SERVICE="${_launcher_default_service}"
GUILD_NODE_IMPLEMENTATION="amaru"
_manifest_file="${GUILD_NODE_HOME}/.deployment.json"

amaru_manifest_value() {
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
    .implementation == "amaru" and
    (.network == "preprod" or .network == "preview") and
    (.branch | type == "string" and length > 0) and
    (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/guild-operators$")) and
    (.serviceName | type == "string" and length > 0) and
    (.nodeVersion | type == "string") and
    (.targetNodeVersion | type == "string") and
    .metricsProvider == "otel" and
    (.capabilities | type == "object") and
    (.capabilities | keys == ["forging", "localCli", "metrics", "n2c"]) and
    (.capabilities.n2c == false) and
    (.capabilities.localCli == false) and
    (.capabilities.metrics == true) and
    (.capabilities.forging == false)
  ' "${_manifest_file}" >/dev/null 2>&1; then
    printf 'ERROR: deployment manifest is malformed, incomplete, unsupported, or not finalized: %s\n' \
      "${_manifest_file}" >&2
    exit 1
  fi
  _manifest_implementation="$(amaru_manifest_value implementation)"
  _manifest_service="$(amaru_manifest_value serviceName)"
  _manifest_network="$(amaru_manifest_value network)"
  if [[ "${_manifest_service}" != "${_launcher_default_service}" ]]; then
    printf 'ERROR: deployment manifest serviceName %s does not match launcher target %s\n' \
      "${_manifest_service}" "${_launcher_default_service}" >&2
    exit 1
  fi
fi
[[ -n "${_manifest_implementation}" ]] && GUILD_NODE_IMPLEMENTATION="${_manifest_implementation}"
[[ -n "${_manifest_service}" ]] && GUILD_NODE_SERVICE="${_manifest_service}"
[[ -n "${_manifest_network}" ]] && AMARU_NETWORK="${_manifest_network}"

if [[ -r "${AMARU_ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${AMARU_ENV_FILE}"
  set +a
else
  case "${command_name}" in
    remove|status|start|stop|restart|logs|-h|--help|help) ;;
    *)
      printf 'ERROR: Amaru environment file is missing: %s\n' "${AMARU_ENV_FILE}" >&2
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
_env_node_network="${AMARU_NETWORK:-}"

# The launcher location and deployment manifest own service identity. The
# implementation environment may configure runtime details, but it cannot
# redirect lifecycle commands to another deployment or unit.
GUILD_NODE_HOME="${_launcher_node_home}"
GUILD_NODE_SERVICE="${_manifest_service:-${_env_node_service:-${_launcher_default_service}}}"
GUILD_NODE_IMPLEMENTATION="${_manifest_implementation:-${_env_node_implementation:-amaru}}"
AMARU_NETWORK="${_manifest_network:-${_env_node_network:-}}"

case "${command_name}" in
  run|metrics|bootstrap|-d|install|version)
    if [[ -n "${_env_node_home_resolved}" &&
          "${_env_node_home_resolved}" != "${GUILD_NODE_HOME}" ]] ||
       [[ -n "${_manifest_service}" && -n "${_env_node_service}" &&
          "${_env_node_service}" != "${_manifest_service}" ]] ||
       [[ -n "${_manifest_implementation}" && -n "${_env_node_implementation}" &&
          "${_env_node_implementation}" != "${_manifest_implementation}" ]] ||
       [[ -n "${_manifest_network}" && -n "${_env_node_network}" &&
          "${_env_node_network}" != "${_manifest_network}" ]]; then
      printf 'ERROR: Amaru environment identity conflicts with .deployment.json; re-run guild-deploy.sh with -s f\n' >&2
      exit 1
    fi
    ;;
esac

# A container volume must mount a parent directory: Docker creates the mount
# point itself, while Amaru bootstrap deliberately refuses pre-existing chain
# and ledger directories. AMARU_STATE_ROOT relocates only those two children
# without changing deployment or service identity.
if [[ -n "${AMARU_STATE_ROOT:-}" ]]; then
  if [[ "${AMARU_STATE_ROOT}" == "/" ||
        ! "${AMARU_STATE_ROOT}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]; then
    printf 'ERROR: AMARU_STATE_ROOT must be a safe absolute directory other than /\n' >&2
    exit 1
  fi
  if [[ -L "${AMARU_STATE_ROOT}" ||
        ( -e "${AMARU_STATE_ROOT}" && ! -d "${AMARU_STATE_ROOT}" ) ]]; then
    printf 'ERROR: AMARU_STATE_ROOT is not a safe directory: %s\n' \
      "${AMARU_STATE_ROOT}" >&2
    exit 1
  fi
  mkdir -p -- "${AMARU_STATE_ROOT}"
  AMARU_CHAIN_DIR="${AMARU_STATE_ROOT%/}/chain"
  AMARU_LEDGER_DIR="${AMARU_STATE_ROOT%/}/ledger"
  export AMARU_CHAIN_DIR AMARU_LEDGER_DIR
fi

AMARU_SYSTEMD_LIBRARY="${AMARU_SCRIPT_DIR}/lib/systemd.library"
if [[ ! -r "${AMARU_SYSTEMD_LIBRARY}" ]]; then
  printf 'ERROR: common systemd library is missing\n' >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${AMARU_SYSTEMD_LIBRARY}"

: "${AMARU_BIN:=${HOME}/.local/bin/amaru}"
: "${AMARU_OTELCOL_BIN:=${HOME}/.local/bin/otelcol-contrib}"
: "${AMARU_OTELCOL_CONFIG:=${GUILD_NODE_HOME}/files/otelcol.yaml}"

amaru_usage() {
  cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  run                 Run the relay in the foreground (default)
  metrics             Run the Amaru OTLP-to-Prometheus bridge in the foreground
  bootstrap           Download and import the three trusted bootstrap snapshots
  -d, install         Install and enable (but do not start) the systemd service
  remove              Stop, disable, and remove the systemd service
  status              Show systemd service status
  start|stop|restart  Control the installed systemd service
  logs                Follow service logs
  version             Print the installed Amaru version
  -h, --help          Show this help

Amaru support is experimental and relay-only. Bootstrap must complete before
the service can start.
EOF
}

amaru_require_identity() {
  if [[ "${GUILD_NODE_IMPLEMENTATION:-}" != "amaru" ]]; then
    printf 'ERROR: environment selects %s, expected amaru\n' "${GUILD_NODE_IMPLEMENTATION:-unset}" >&2
    return 1
  fi
  if [[ ! "${GUILD_NODE_SERVICE}" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
    printf 'ERROR: invalid Amaru service name: %s\n' "${GUILD_NODE_SERVICE}" >&2
    return 1
  fi
  if [[ ! "${GUILD_NODE_HOME}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]; then
    printf 'ERROR: deployment path contains characters unsafe for generated configuration\n' >&2
    return 1
  fi
}

amaru_require_environment() {
  amaru_require_identity || return 1
  case "${AMARU_NETWORK:-}" in
    preprod|preview) ;;
    *)
      printf 'ERROR: this experimental profile supports only preprod or preview, got %s\n' "${AMARU_NETWORK:-unset}" >&2
      return 1
      ;;
  esac
  if [[ "${AMARU_BIN}" == *[[:space:]]* ||
        "${AMARU_BIN}" == *'|'* ||
        "${AMARU_BIN}" == *'%'* ||
        "${AMARU_BIN}" == *'"'* ||
        "${AMARU_BIN}" == *"\\"* ]]; then
    printf 'ERROR: deployment paths contain unsupported systemd characters\n' >&2
    return 1
  fi
}

amaru_require_supported_profile() {
  amaru_require_environment || return 1
  if [[ ! -x "${AMARU_BIN}" ]]; then
    printf 'ERROR: Amaru binary is missing or not executable: %s\n' "${AMARU_BIN}" >&2
    return 1
  fi
}

amaru_require_metrics_bridge() {
  amaru_require_environment || return 1
  if [[ ! "${AMARU_OTELCOL_BIN}" =~ ^/[A-Za-z0-9._/+@:-]+$ ||
        ! "${AMARU_OTELCOL_CONFIG}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]; then
    printf 'ERROR: metrics bridge paths contain unsupported systemd characters\n' >&2
    return 1
  fi
  if [[ ! -x "${AMARU_OTELCOL_BIN}" ]]; then
    printf 'ERROR: OpenTelemetry Collector is missing or not executable: %s\n' \
      "${AMARU_OTELCOL_BIN}" >&2
    return 1
  fi
  if [[ ! -f "${AMARU_OTELCOL_CONFIG}" ||
        -L "${AMARU_OTELCOL_CONFIG}" ||
        ! -r "${AMARU_OTELCOL_CONFIG}" ]]; then
    printf 'ERROR: OpenTelemetry Collector configuration is missing or unsafe: %s\n' \
      "${AMARU_OTELCOL_CONFIG}" >&2
    return 1
  fi
}

amaru_install_service() {
  command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1 || {
    printf 'ERROR: systemd is required to install the service\n' >&2
    return 1
  }

  amaru_require_metrics_bridge || return 1
  "${AMARU_OTELCOL_BIN}" validate \
    --config="${AMARU_OTELCOL_CONFIG}" >/dev/null || {
    printf 'ERROR: OpenTelemetry Collector rejected %s\n' \
      "${AMARU_OTELCOL_CONFIG}" >&2
    return 1
  }

  local service_user service_group unit_name unit_content
  local metrics_unit_name metrics_unit_content
  service_user="$(id -un)"
  service_group="$(id -gn)"
  unit_name="${GUILD_NODE_SERVICE}.service"
  metrics_unit_name="${GUILD_NODE_SERVICE}-metrics.service"
  metrics_unit_content="$(cat <<EOF
[Unit]
Description=Amaru reference Prometheus bridge (Guild host profile)
Documentation=https://github.com/pragma-org/amaru/tree/main/monitoring https://opentelemetry.io/docs/collector/
Wants=network-online.target
After=network-online.target
Before=${unit_name}
ConditionPathExists=${AMARU_OTELCOL_BIN}
ConditionPathExists=${AMARU_OTELCOL_CONFIG}

[Service]
Type=simple
User=${service_user}
Group=${service_group}
WorkingDirectory=${GUILD_NODE_HOME}
ExecStart=${AMARU_OTELCOL_BIN} --config=${AMARU_OTELCOL_CONFIG}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadOnlyPaths=${AMARU_OTELCOL_CONFIG}
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
)"
  unit_content="$(cat <<EOF
[Unit]
Description=Guild Operators Amaru experimental relay (${AMARU_NETWORK})
Documentation=https://github.com/pragma-org/amaru
Wants=network-online.target time-sync.target ${metrics_unit_name}
After=network-online.target time-sync.target ${metrics_unit_name}
ConditionPathExists=${AMARU_BIN}

[Service]
Type=simple
User=${service_user}
Group=${service_group}
WorkingDirectory=${GUILD_NODE_HOME}
ExecStart=${AMARU_SCRIPT_DIR}/amaru.sh run
Restart=always
RestartSec=5
TimeoutStopSec=45
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

  systemd_install_unit \
    "${metrics_unit_name}" "${metrics_unit_content}" \
    "${AMARU_SCRIPT_DIR}/amaru.sh" || return 1
  systemd_install_unit \
    "${unit_name}" "${unit_content}" \
    "${AMARU_SCRIPT_DIR}/amaru.sh" || return 1
  systemd_daemon_reload || return 1
  systemd_enable_units "${metrics_unit_name}" "${unit_name}" || return 1
  printf 'Installed %s and %s. Run bootstrap before starting the node.\n' \
    "${metrics_unit_name}" "${unit_name}"
}

amaru_remove_service() {
  command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1 || {
    printf 'ERROR: systemd is required to remove the service\n' >&2
    return 1
  }
  systemd_remove_units --owner-token "${AMARU_SCRIPT_DIR}/amaru.sh" \
    "${GUILD_NODE_SERVICE}.service" \
    "${GUILD_NODE_SERVICE}-metrics.service" || return 1
  printf 'Removed %s node and metrics services; node data was left intact in %s.\n' \
    "${GUILD_NODE_SERVICE}" "${GUILD_NODE_HOME}"
}

case "${command_name}" in
  run)
    amaru_require_supported_profile
    if [[ ! -d "${AMARU_CHAIN_DIR}" || ! -d "${AMARU_LEDGER_DIR}" ]]; then
      printf 'ERROR: Amaru is not bootstrapped. Run %s bootstrap first.\n' "$0" >&2
      exit 1
    fi
    cd -- "${GUILD_NODE_HOME}"
    exec "${AMARU_BIN}" node run "$@"
    ;;
  metrics)
    amaru_require_metrics_bridge
    exec "${AMARU_OTELCOL_BIN}" --config="${AMARU_OTELCOL_CONFIG}" "$@"
    ;;
  bootstrap)
    amaru_require_supported_profile
    cd -- "${GUILD_NODE_HOME}"
    # Bootstrap telemetry is not consumed by gLiveView and the managed
    # collector is intentionally not running yet. Keep console logging, but do
    # not make Amaru repeatedly export to an absent OTLP endpoint.
    export AMARU_WITH_OPEN_TELEMETRY=false
    exec "${AMARU_BIN}" node bootstrap "$@"
    ;;
  -d|install)
    amaru_require_supported_profile
    amaru_install_service
    ;;
  remove)
    amaru_require_identity
    amaru_remove_service
    ;;
  status)
    amaru_require_identity
    systemd_status_units \
      "${GUILD_NODE_SERVICE}.service" \
      "${GUILD_NODE_SERVICE}-metrics.service"
    ;;
  start|stop|restart)
    amaru_require_identity
    systemd_control "${command_name}" \
      "${GUILD_NODE_SERVICE}-metrics.service" \
      "${GUILD_NODE_SERVICE}.service"
    ;;
  logs)
    amaru_require_identity
    systemd_as_root journalctl -f \
      -u "${GUILD_NODE_SERVICE}.service" \
      -u "${GUILD_NODE_SERVICE}-metrics.service"
    ;;
  version)
    amaru_require_supported_profile
    exec "${AMARU_BIN}" --version
    ;;
  -h|--help|help)
    amaru_usage
    ;;
  *)
    printf 'ERROR: unknown command: %s\n\n' "${command_name}" >&2
    amaru_usage >&2
    exit 2
    ;;
esac
