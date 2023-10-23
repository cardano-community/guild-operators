#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#MITHRILBIN="${HOME}"/.local/bin/mithril-signer # Path for mithril-signer binary, if not in $PATH
#HOSTADDR=127.0.0.1                             # Default Listen IP/Hostname for Mithril Signer Server

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d] [-u]
		
		Cardano Mithril signer wrapper script !!
		-d    Deploy mithril-signer as a systemd service
		-u    Update mithril-signer environment file
		
		EOF
  exit 1
}

set_defaults() {
  [[ -z "${MITHRILBIN}" ]] && MITHRILBIN="${HOME}"/.local/bin/mithril-signer
  if [[ -z "${NETWORK}" ]] || [[ -z "${POOL_NAME}" ]] || [[ "${POOL_NAME}" == "CHANGE_ME" ]]; then
    echo "ERROR: The NETWORK and POOL_NAME must be set before deploying mithril-signer as a systemd service!!"
    exit 1
  else
    case "${NETWORK}" in
      mainnet|preprod)
      RELEASE="release"
      ;;
      *)
      RELEASE="pre-release"
      ;;
    esac
  fi
  [[ -z ${RELEASE} ]] && echo "ERROR: Failed to set RELEASE variable, please check NETWORK variable in env file!!" && exit 1
}

pre_startup_sanity() {
  [[ ! -f "${MITHRILBIN}" ]] && MITHRILBIN="$(command -v mithril-signer)"
  if [[ ! -S "${CARDANO_NODE_SOCKET_PATH}" ]]; then
    echo "ERROR: Could not locate socket file at ${CARDANO_NODE_SOCKET_PATH}, the node may not have completed startup !!"
    exit 1
  fi
  # Move logs to archive
  [[ -f "${LOG_DIR}"/mithril-signer.log ]] && mv "${LOG_DIR}"/mithril-signer.log "${LOG_DIR}"/archive/
}

get_relay_endpoint() {
  read -p "Enter the IP address of the relay endpoint: " RELAY_ENDPOINT_IP
  read -p "Enter the port of the relay endpoint: " RELAY_PORT
}

generate_environment_file() {
  # Inquire about the relay endpoint
  read -p "Are you using a relay endpoint? (y/n): " ENABLE_RELAY_ENDPOINT
    if [[ "${ENABLE_RELAY_ENDPOINT}" == "y" ]]; then
        get_relay_endpoint
    fi

  ERA_READER_ADDRESS=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK}/era.addr
  ERA_READER_VKEY=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK}/era.vkey
  sudo bash -c "cat <<-'EOF' > ${CNODE_HOME}/mithril-signer/service.env
	KES_SECRET_KEY_PATH=${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}
	OPERATIONAL_CERTIFICATE_PATH=${POOL_DIR}/${POOL_OPCERT_FILENAME}
	NETWORK=${NETWORK}
	AGGREGATOR_ENDPOINT=https://aggregator.${RELEASE}-${NETWORK}.api.mithril.network/aggregator
	RUN_INTERVAL=60000
	DB_DIRECTORY=${CNODE_HOME}/db
	CARDANO_NODE_SOCKET_PATH=${CARDANO_NODE_SOCKET_PATH}
	CARDANO_CLI_PATH=${HOME}/.local/bin/cardano-cli
	DATA_STORES_DIRECTORY=${CNODE_HOME}/mithril-signer/data-stores
	STORE_RETENTION_LIMITS=5
	ERA_READER_ADAPTER_TYPE=cardano-chain
	ERA_READER_ADDRESS=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK}/era.addr
	ERA_READER_VKEY=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK}/era.vkey
	ERA_READER_ADAPTER_PARAMS=$(jq -nc --arg address $(wget -q -O - "${ERA_READER_ADDRESS}") --arg verification_key $(wget -q -O - "${ERA_READER_VKEY}") '{"address": $address, "verification_key": $verification_key}')
	GENESIS_VERIFICATION_KEY=$(curl -s https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK}/genesis.vkey)
	PARTY_ID=$(cat ${POOL_DIR}/${POOL_ID_FILENAME})
	EOF" && sudo chown $USER:$USER "${CNODE_HOME}"/mithril-signer/service.env
    
    if [[ "${ENABLE_RELAY_ENDPOINT}" == "y" ]]; then
      sudo bash -c "echo  RELAY_ENDPOINT=http://${RELAY_ENDPOINT_IP}:${RELAY_PORT} >> ${CNODE_HOME}/mithril-signer/service.env"
    fi
}

deploy_systemd() {
  echo "Creating ${CNODE_VNAME}-mithril-signer systemd service environment file.."
  if [[ ! -f "${CNODE_HOME}"/mithril-signer/service.env ]]; then
    generate_environment_file && echo "Environment file created successfully!!"
  fi

  echo "Deploying ${CNODE_VNAME}-mithril-signer as systemd service.."
  sudo bash -c "cat <<-'EOF' > /etc/systemd/system/${CNODE_VNAME}-mithril-signer.service
	[Unit]
	Description=Cardano Mithril signer service
	StartLimitIntervalSec=0
	Wants=network-online.target
	After=network-online.target
	BindsTo=${vname}.service
	After=${vname}.service
	
	[Service]
	Type=simple
	Restart=always
	RestartSec=5
	User=${USER}
	EnvironmentFile=${CNODE_HOME}/mithril-signer/service.env
	ExecStart=/bin/bash -l -c \"exec ${HOME}/.local/bin/mithril-signer -vv\"
	KillSignal=SIGINT
	SuccessExitStatus=143
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=${CNODE_VNAME}-mithril-signer
	TimeoutStopSec=5
	KillMode=mixed
	
	[Install]
	WantedBy=multi-user.target
	EOF" && echo "${CNODE_VNAME}-mithril-signer.service deployed successfully!!" && sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-mithril-signer.service
}

###################
# Execution       #
###################

# Parse command line options
while getopts :du opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    u ) UPDATE_ENVIRONMENT="Y" ;;
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
elif [[ "${UPDATE_ENVIRONMENT}" == "Y" ]]; then
  generate_environment_file && echo "Environment file updated successfully!!" && exit 0
  exit 2
elif [[ "${UPDATE_ENVIRONMENT}" == "Y" ]] && [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  generate_environment_file && deploy_systemd && exit 0
  exit 2
fi

pre_startup_sanity

# Run Mithril Signer Server
echo "Sourcing the Mithril Signer environment file.."
. "${CNODE_HOME}"/mithril-signer/service.env
echo "Starting Mithril Signer Server.."
"${MITHRILBIN}" -vvv >> "${LOG_DIR}"/mithril-signer.log 2>&1
