#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#SUBMITAPIBIN="${HOME}"/.local/bin/cardano-submit-api # Path for cardano-submit-api binary, if not in $PATH
#HOSTADDR=127.0.0.1                                 # Default Listen IP/Hostname for Submit API
#HOSTPORT=8090                                      # Default Listen port for Submit API

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d]
		
		Cardano Submit API wrapper script !!
		-d    Deploy cardano-submit-api as a systemd service
		
		EOF
  exit 1
}

set_defaults() {
  [[ -z "${SUBMITAPIBIN}" ]] && SUBMITAPIBIN="${HOME}"/.local/bin/cardano-submit-api
  [[ -z "${HOSTADDR}" ]] && HOSTADDR=127.0.0.1
  [[ -z "${HOSTPORT}" ]] && HOSTPORT=8090
}

pre_startup_sanity() {
  [[ ! -f "${SUBMITAPIBIN}" ]] && SUBMITAPIBIN=$(command -v cardano-submit-api)
  if [[ ! -S "${CARDANO_NODE_SOCKET_PATH}" ]]; then
    echo "ERROR: Could not locate socket file at ${CARDANO_NODE_SOCKET_PATH}, the node may not have completed startup !!"
    exit 1
  fi
}

deploy_systemd() {
  echo "Deploying ${CNODE_VNAME}-submit-api as systemd service.."
  sudo bash -c "cat <<-'EOF' > /etc/systemd/system/${CNODE_VNAME}-submit-api.service
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
	ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/submitapi.sh\"
	KillSignal=SIGINT
	SuccessExitStatus=143
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=${CNODE_VNAME}-submit-api
	TimeoutStopSec=5
	KillMode=mixed
	
	[Install]
	WantedBy=multi-user.target
	EOF" && echo "${CNODE_VNAME}-submit-api.service deployed successfully!!" && sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-submit-api.service
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

# Run Submit API
"${SUBMITAPIBIN}" --config "${CONFIG}" --testnet-magic ${NWMAGIC} --socket-path "${CARDANO_NODE_SOCKET_PATH}" --listen-address ${HOSTADDR} --port ${HOSTPORT}
