#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

PARENT="$(dirname "$0")"

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#SUBMITAPIBIN="${HOME}"/.local/bin/cardano-submit-api # Path for cardano-submit-api binary, if not in $PATH
#SUBMITAPI_CONFIG="$CNODE_HOME"/files/submitapi.json  # Default path to submitapi config
#HOSTADDR=127.0.0.1                                   # Default Listen IP/Hostname for Submit API
#HOSTPORT=8090                                        # Default Listen port for Submit API
#METRICS_PORT=8091                                    # Default Listen port for Prometheus metrics

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

		Cardano Submit API wrapper script !!
		-d    Deploy cardano-submit-api as a systemd service
		systemd
		      Install, remove, or show the status of the submit-api service
		
		EOF
  exit 1
}

set_defaults() {
  [[ -z "${SUBMITAPIBIN}" ]] && SUBMITAPIBIN="${HOME}"/.local/bin/cardano-submit-api
  [[ -z "${SUBMITAPI_CONFIG}" ]] && SUBMITAPI_CONFIG="$CNODE_HOME"/files/submitapi.json
  [[ -z "${HOSTADDR}" ]] && HOSTADDR=127.0.0.1
  [[ -z "${HOSTPORT}" ]] && HOSTPORT=8090
  [[ -z "${METRICS_PORT}" ]] && METRICS_PORT=8091
}

pre_startup_sanity() {
  [[ ! -f "${SUBMITAPIBIN}" ]] && SUBMITAPIBIN=$(command -v cardano-submit-api)
  if [[ ! -S "${CARDANO_NODE_SOCKET_PATH}" ]]; then
    echo "ERROR: Could not locate socket file at ${CARDANO_NODE_SOCKET_PATH}, the node may not have completed startup !!"
    exit 1
  fi
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
  local unit_name="${CNODE_VNAME}-submit-api.service"
  local unit_content

  load_systemd_library || return 1
  echo "Deploying ${CNODE_VNAME}-submit-api as systemd service.."
  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano Node Submit API
		Wants=network-online.target
		After=network-online.target

		[Service]
		Type=simple
		Restart=always
		RestartSec=5
		User=${USER}
		LimitNOFILE=1048576
		WorkingDirectory=${CNODE_HOME}/scripts
		ExecStart=/bin/bash -l -c "exec ${CNODE_HOME}/scripts/submitapi.sh"
		KillSignal=SIGINT
		SuccessExitStatus=143
		SyslogIdentifier=${CNODE_VNAME}-submit-api
		TimeoutStopSec=5
		KillMode=mixed

		[Install]
		WantedBy=multi-user.target
	EOF
  systemd_install_unit "${unit_name}" "${unit_content}" "${CNODE_HOME}/scripts/submitapi.sh" &&
    systemd_daemon_reload &&
    systemd_enable_units "${unit_name}" &&
    echo "${unit_name} deployed successfully!!"
}

manage_systemd() {
  local action="${1:-}"
  local unit_name="${CNODE_VNAME}-submit-api.service"

  case "${action}" in
    install) deploy_systemd ;;
    remove)
      load_systemd_library &&
        systemd_remove_units --owner-token "${CNODE_HOME}/scripts/submitapi.sh" "${unit_name}" &&
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

# Run Submit API
"${SUBMITAPIBIN}" --config "${SUBMITAPI_CONFIG}" --testnet-magic ${NWMAGIC} --socket-path "${CARDANO_NODE_SOCKET_PATH}" --listen-address ${HOSTADDR} --port ${HOSTPORT} --metrics-port ${METRICS_PORT}
