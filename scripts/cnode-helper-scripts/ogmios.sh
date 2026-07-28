#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

PARENT="$(dirname "$0")"

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#OGMIOSBIN="${HOME}"/.local/bin/ogmios        # Path for ogmios binary, if not in $PATH
#HOSTADDR=127.0.0.1                           # Default Listen IP/Hostname for Ogmios Server
#HOSTPORT=1337                                # Default Listen port for Ogmios Server
#LOG_LEVEL=Notice                             # Debug | Info | Notice | Warning | Error | Off
#CLI_ARGS="--include-cbor"                    # Additional CLI arguments to ogmios

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF

		Usage: $(basename "$0") [-d]
		       $(basename "$0") systemd <install|remove|status>

		Cardano Ogmios wrapper script !!
		-d    Deploy ogmios server as a systemd service
		systemd
		      Install, remove, or show the status of the ogmios service
		
		EOF
  exit 1
}

set_defaults() {
  [[ -z "${OGMIOSBIN}" ]] && OGMIOSBIN="${HOME}"/.local/bin/ogmios
  [[ -z "${HOSTADDR}" ]] && HOSTADDR=127.0.0.1
  [[ -z "${HOSTPORT}" ]] && HOSTPORT=1337
  [[ -z "${CLI_ARGS}" ]] && CLI_ARGS="--include-cbor"
  if [[ -z "${LOG_LEVEL}" ]]; then
    LOG_LEVEL=Notice
  else
    case ${LOG_LEVEL} in
      Debug)   : ;;
      Info)    : ;;
      Warning) : ;;
      Error)   : ;;
      Off)     : ;;
      *) LOG_LEVEL=Notice ;;
    esac
  fi
}

pre_startup_sanity() {
  [[ ! -f "${OGMIOSBIN}" ]] && OGMIOSBIN="$(command -v ogmios)"
  if [[ ! -S "${CARDANO_NODE_SOCKET_PATH}" ]]; then
    echo "ERROR: Could not locate socket file at ${CARDANO_NODE_SOCKET_PATH}, the node may not have completed startup !!"
    exit 1
  fi
  # Move logs to archive
  [[ -f "${LOG_DIR}"/ogmios.log ]] && mv "${LOG_DIR}"/ogmios.log "${LOG_DIR}"/archive/
}

load_systemd_library() {
  local systemd_library="${PARENT}/lib/systemd.library"
  [[ -f "${systemd_library}" ]] || systemd_library="${PARENT}/systemd.library"
  [[ -f "${systemd_library}" ]] || systemd_library="${PARENT}/../common-helper-scripts/lib/systemd.library"
  if [[ ! -f "${systemd_library}" ]]; then
    echo "ERROR: systemd.library is missing. Re-run the deployment script to install shared helpers."
    return 1
  fi
  # shellcheck disable=SC1091
  . "${systemd_library}"
}

deploy_systemd() {
  local unit_name="${CNODE_VNAME}-ogmios.service"
  local unit_content

  load_systemd_library || return 1
  echo "Deploying ${CNODE_VNAME}-ogmios as systemd service.."
  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Ogmios Server
		Wants=network-online.target
		After=network-online.target

		[Service]
		Type=simple
		Restart=always
		RestartSec=5
		User=${USER}
		LimitNOFILE=1048576
		WorkingDirectory=${CNODE_HOME}/scripts
		ExecStart=/bin/bash -l -c "exec ${CNODE_HOME}/scripts/ogmios.sh"
		KillSignal=SIGINT
		SuccessExitStatus=143
		SyslogIdentifier=${CNODE_VNAME}-ogmios
		TimeoutStopSec=5
		KillMode=mixed

		[Install]
		WantedBy=multi-user.target
	EOF
  systemd_install_unit "${unit_name}" "${unit_content}" "${CNODE_HOME}/scripts/ogmios.sh" &&
    systemd_daemon_reload &&
    systemd_enable_units "${unit_name}" &&
    echo "${unit_name} deployed successfully!!"
}

manage_systemd() {
  local action="${1:-}"
  local unit_name="${CNODE_VNAME}-ogmios.service"

  case "${action}" in
    install) deploy_systemd ;;
    remove)
      load_systemd_library &&
        systemd_remove_units --owner-token "${CNODE_HOME}/scripts/ogmios.sh" "${unit_name}" &&
        echo "${unit_name} removed successfully."
      ;;
    status)
      load_systemd_library && systemd_status_units "${unit_name}"
      ;;
    *) usage ;;
  esac
}

###################
# Execution       #
###################

# Parse command line options
SYSTEMD_ACTION=""
if [[ ${1:-} == "systemd" ]]; then
  [[ $# -eq 2 ]] || usage
  SYSTEMD_ACTION="${2}"
  shift 2
fi
while getopts :d opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    \? ) usage ;;
  esac
done

# Check if env file is missing in current folder (no update checks as will mostly run as daemon), source env if present
[[ ! -f "${PARENT}"/env ]] && echo -e "\nCommon env file missing, please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
if [[ "${SYSTEMD_ACTION}" == "remove" || "${SYSTEMD_ACTION}" == "status" ]]; then
  . "${PARENT}"/env definitions
elif [[ -n "${SYSTEMD_ACTION}" ]]; then
  . "${PARENT}"/env offline
else
  . "${PARENT}"/env
fi
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

# Set defaults and do basic sanity checks
set_defaults
if [[ -n "${SYSTEMD_ACTION}" ]]; then
  manage_systemd "${SYSTEMD_ACTION}"
  exit $?
fi
#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && exit 0
  exit 2
fi
pre_startup_sanity

# Run Ogmios Server
"${OGMIOSBIN}" --node-config "${CONFIG}" --node-socket "${CARDANO_NODE_SOCKET_PATH}" --host ${HOSTADDR} --port ${HOSTPORT} ${CLI_ARGS} --log-level ${LOG_LEVEL} >> "${LOG_DIR}"/ogmios.log 2>&1
