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

U_ID=$(id -u)
G_ID=$(id -g)

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d] [-u]
		
		Cardano Mithril signer wrapper script !!
		-d    Deploy mithril-signer as a systemd service
		-u    Update mithril environment file
		-h    Show this help text
		
		EOF
}

set_defaults() {
  [[ -z "${MITHRILBIN}" ]] && MITHRILBIN="${HOME}"/.local/bin/mithril-signer
  if [[ -z "${POOL_NAME}" ]] || [[ "${POOL_NAME}" == "CHANGE_ME" ]]; then
    echo "ERROR: The POOL_NAME must be set before deploying mithril-signer as a systemd service!!"
    exit 1
  else
    case "${NETWORK_NAME,,}" in
      mainnet|preprod|guild)
      RELEASE="release"
      ;;
      preview)
      RELEASE="pre-release"
      ;;
      *)
      echo "ERROR: The NETWORK_NAME must be set to Mainnet, PreProd, Preview, or Guild before mithril-signer can be deployed!!"
      exit 1
    esac
  fi
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
  read -r -p "Enter the IP address of the relay endpoint: " RELAY_ENDPOINT_IP
  read -r -p "Enter the port of the relay endpoint (press Enter to use default 3132): " RELAY_PORT
  RELAY_PORT=${RELAY_PORT:-3132}
  echo "Using RELAY_ENDPOINT=${RELAY_ENDPOINT_IP}:${RELAY_PORT} for the Mithril signer relay endpoint."
}

generate_environment_file() {
  if [[ ! -d "${CNODE_HOME}/mithril/data-stores" ]]; then
    sudo mkdir -p "${CNODE_HOME}"/mithril/data-stores
    sudo chown -R "$U_ID":"$G_ID" "${CNODE_HOME}"/mithril 2>/dev/null
  fi
  # Inquire about the relay endpoint
  read -r -p "Are you using a relay endpoint? (y/n, press Enter to use default y): " ENABLE_RELAY_ENDPOINT
  ENABLE_RELAY_ENDPOINT=${ENABLE_RELAY_ENDPOINT:-y}
  if [[ "${ENABLE_RELAY_ENDPOINT}" == "y" ]]; then
    get_relay_endpoint
  else
    echo "Using a naive Mithril configuration without a mithril relay."
  fi

  # Generate the full set of environment variables required by Mithril signer use case
  export ERA_READER_ADDRESS=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK_NAME,,}/era.addr
  export ERA_READER_VKEY=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK_NAME,,}/era.vkey
  sudo bash -c "cat <<-'EOF' > ${CNODE_HOME}/mithril/mithril.env
	KES_SECRET_KEY_PATH=${POOL_DIR}/${POOL_HOTKEY_SK_FILENAME}
	OPERATIONAL_CERTIFICATE_PATH=${POOL_DIR}/${POOL_OPCERT_FILENAME}
	NETWORK=${NETWORK_NAME,,}
	RELEASE=${RELEASE}
	AGGREGATOR_ENDPOINT=https://aggregator.${RELEASE}-${NETWORK_NAME,,}.api.mithril.network/aggregator
	RUN_INTERVAL=60000
	DB_DIRECTORY=${CNODE_HOME}/db
	CARDANO_NODE_SOCKET_PATH=${CARDANO_NODE_SOCKET_PATH}
	CARDANO_CLI_PATH=${HOME}/.local/bin/cardano-cli
	DATA_STORES_DIRECTORY=${CNODE_HOME}/mithril/data-stores
	STORE_RETENTION_LIMITS=5
	ERA_READER_ADAPTER_TYPE=cardano-chain
	ERA_READER_ADAPTER_PARAMS=$(jq -nc --arg address "$(wget -q -O - "${ERA_READER_ADDRESS}")" --arg verification_key "$(wget -q -O - "${ERA_READER_VKEY}")" '{"address": $address, "verification_key": $verification_key}')
	GENESIS_VERIFICATION_KEY=$(wget -q -O - https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK_NAME,,}/genesis.vkey)
	PARTY_ID=$(cat ${POOL_DIR}/${POOL_ID_FILENAME})
	SNAPSHOT_DIGEST=latest
	EOF" && sudo chown $USER:$USER "${CNODE_HOME}"/mithril/mithril.env
    
    if [[ "${ENABLE_RELAY_ENDPOINT}" == "y" ]]; then
      sudo bash -c "echo  RELAY_ENDPOINT=http://${RELAY_ENDPOINT_IP}:${RELAY_PORT} >> ${CNODE_HOME}/mithril/mithril.env"
    fi
}

deploy_systemd() {
  echo "Creating ${CNODE_VNAME}-mithril-signer systemd service environment file.."
  if [[ ! -f "${CNODE_HOME}"/mithril/mithril.env ]]; then
    generate_environment_file && echo "Mithril environment file created successfully!!"
  fi

  echo "Deploying ${CNODE_VNAME}-mithril-signer as systemd service.."
  sudo bash -c "cat <<-'EOF' > /etc/systemd/system/${CNODE_VNAME}-mithril-signer.service
	[Unit]
	Description=Cardano Mithril signer service
	StartLimitIntervalSec=0
	Wants=network-online.target
	After=network-online.target
	BindsTo=${CNODE_VNAME}.service
	After=${CNODE_VNAME}.service
	
	[Service]
	Type=simple
	Restart=always
	RestartSec=60
	User=${USER}
	EnvironmentFile=${CNODE_HOME}/mithril/mithril.env
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
while getopts :duh opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    u ) UPDATE_ENVIRONMENT="Y" ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      usage
      exit 1
      ;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      usage
      exit 1
      ;;
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
if [[ "${UPDATE_ENVIRONMENT}" == "Y" && "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  generate_environment_file && echo "Environment file updated successfully" && deploy_systemd && echo "Mithril signer service successfully deployed" && exit 0
  exit 2
elif [[ "${UPDATE_ENVIRONMENT}" == "Y" ]]; then
  generate_environment_file && echo "Environment file updated successfully" && exit 0
  exit 2
elif [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && echo "Mithril signer service successfully deployed" && exit 0
  exit 2
fi

pre_startup_sanity

# Run Mithril Signer Server
echo "Sourcing the Mithril Signer environment file.."
. "${CNODE_HOME}"/mithril/mithril.env
echo "Starting Mithril Signer Server.."
"${MITHRILBIN}" -vvv >> "${LOG_DIR}"/mithril-signer.log 2>&1
