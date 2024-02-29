#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#OGMIOSBIN="${HOME}"/.local/bin/ogmios        # Path for ogmios binary, if not in $PATH
#HOSTADDR=127.0.0.1                           # Default Listen IP/Hostname for Ogmios Server
#HOSTPORT=1337                                # Default Listen port for Ogmios Server
#LOG_LEVEL=Notice                             # Debug | Info | Notice | Warning | Error | Off

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d]
		
		Cardano Ogmios wrapper script !!
		-d    Deploy ogmios server as a systemd service
		
		EOF
  exit 1
}

set_defaults() {
  [[ -z "${OGMIOSBIN}" ]] && OGMIOSBIN="${HOME}"/.local/bin/ogmios
  [[ -z "${HOSTADDR}" ]] && HOSTADDR=127.0.0.1
  [[ -z "${HOSTPORT}" ]] && HOSTPORT=1337
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

deploy_systemd() {
  echo "Deploying ${CNODE_VNAME}-ogmios as systemd service.."
  sudo bash -c "cat <<-'EOF' > /etc/systemd/system/${CNODE_VNAME}-ogmios.service
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
	ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/ogmios.sh \"
	KillSignal=SIGINT
	SuccessExitStatus=143
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=${CNODE_VNAME}-ogmios
	TimeoutStopSec=5
	KillMode=mixed
	
	[Install]
	WantedBy=multi-user.target
	EOF" && echo "${CNODE_VNAME}-ogmios.service deployed successfully!!" && sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-ogmios.service
}

###################
# Execution       #
###################

# Parse command line options
while getopts :d opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    \? ) usage ;;
  esac
done

# Check if env file is missing in current folder (no update checks as will mostly run as daemon), source env if present
[[ ! -f "$(dirname $0)"/env ]] && echo -e "\nCommon env file missing, please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
. "$(dirname $0)"/env
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

# Set defaults and do basic sanity checks
set_defaults
#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && exit 0
  exit 2
fi
pre_startup_sanity

# Run Ogmios Server
"${OGMIOSBIN}" --node-config "${CONFIG}" --node-socket "${CARDANO_NODE_SOCKET_PATH}" --host ${HOSTADDR} --port ${HOSTPORT} --log-level ${LOG_LEVEL} >> "${LOG_DIR}"/ogmios.log 2>&1
