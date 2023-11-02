#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#MITHRILBIN="${HOME}"/.local/bin/mithril-client # Path for mithril-client binary, if not in $PATH

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d] [-u]
		
		Cardano Mithril client wrapper script !!
		-d    Download latest Mithril snapshot
		-u    Update mithril environment file
		-h    Show this help text
		
		EOF
}


generate_environment_file() {
  if [[ -n "${POOL_NAME}" ]] && [[ "${POOL_NAME}" != "CHANGE_ME" ]]; then
    export ERA_READER_ADDRESS=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK_NAME,,}/era.addr
    export ERA_READER_VKEY=https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK_NAME,,}/era.vkey
    bash -c "cat <<-'EOF' > ${CNODE_HOME}/mithril/mithril.env
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
		EOF"
  else
    bash -c "cat <<-'EOF' > ${CNODE_HOME}/mithril/mithril.env
		NETWORK=${NETWORK_NAME,,}
		RELEASE=${RELEASE}
		AGGREGATOR_ENDPOINT=https://aggregator.${RELEASE}-${NETWORK_NAME,,}.api.mithril.network/aggregator
		DB_DIRECTORY=${CNODE_HOME}/db
		GENESIS_VERIFICATION_KEY=$(wget -q -O - https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${RELEASE}-${NETWORK_NAME,,}/genesis.vkey)
		SNAPSHOT_DIGEST=latest
		EOF"
  fi
  chown $USER:$USER "${CNODE_HOME}"/mithril/mithril.env
}


pre_startup_sanity() {
  REQUIRED_PARAMETERS="Y"
  if [[ ! -f "${CNODE_HOME}"/mithril/mithril.env ]]; then
    echo "INFO: Mithril environment file not found, creating environment file.."
    generate_environment_file && echo "INFO: Mithril environment file created successfully!!"
  elif [[ "${UPDATE_ENVIRONMENT}" == "Y" ]]; then
    echo "INFO: Updating mithril environment file.."
    generate_environment_file && echo "INFO: Mithril environment file updated successfully!!"
  fi
  . "${CNODE_HOME}"/mithril/mithril.env
  [[ -z "${NETWORK}" ]] && echo "ERROR: The NETWORK must be set before calling mithril-client!!" && REQUIRED_PARAMETERS="N"
  [[ -z "${RELEASE}" ]] && echo "ERROR: Failed to set RELEASE variable, please check NETWORK variable in env file!!" && REQUIRED_PARAMETERS="N"
  [[ -z "${CNODE_HOME}" ]] && echo "ERROR: The CNODE_HOME must be set before calling mithril-client!!" && REQUIRED_PARAMETERS="N"
  [[ ! -d "${CNODE_HOME}" ]] && echo "ERROR: The CNODE_HOME directory does not exist, please check CNODE_HOME variable in env file!!" && REQUIRED_PARAMETERS="N"
  [[ -z "${AGGREGATOR_ENDPOINT}" ]] && echo "ERROR: The AGGREGATOR_ENDPOINT must be set before calling mithril-client!!" && REQUIRED_PARAMETERS="N"
  [[ -z "${GENESIS_VERIFICATION_KEY}" ]] && echo "ERROR: The GENESIS_VERIFICATION_KEY must be set before calling mithril-client!!" && REQUIRED_PARAMETERS="N"
  [[ ! -x "${MITHRILBIN}" ]] && echo "ERROR: The MITHRILBIN variable does not contain an executable file, please check MITHRILBIN variable in env file!!" && REQUIRED_PARAMETERS="N"
  [[ "${REQUIRED_PARAMETERS}" != "Y" ]] && exit 1
  export GENESIS_VERIFICATION_KEY
  DOWNLOAD_SNAPSHOT="N"
  REMOVE_DB_DIR="N"
}

set_defaults() {
  [[ -z "${MITHRILBIN}" ]] && MITHRILBIN="${HOME}"/.local/bin/mithril-client
  if [[ -z "${NETWORK_NAME}" ]]; then
    echo "ERROR: The NETWORK_NAME must be set before mithril-client can download snapshots!!"
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
      echo "ERROR: The NETWORK_NAME must be set to Mainnet, PreProd, Preview, Guild before mithril-client can download snapshots!!"
      exit 1
    esac
  fi
  pre_startup_sanity
}

check_db_dir() {
  # If the DB directory does not exist then set DOWNLOAD_SNAPSHOT to Y
  if [[ ! -d "${DB_DIRECTORY}" ]]; then
    echo "INFO: The db directory does not exist.."
    DOWNLOAD_SNAPSHOT="Y"
  # If the DB directory is empty then set DOWNLOAD_SNAPSHOT to Y and REMOVE_DB_DIR to Y
  elif [[ -d "${DB_DIRECTORY}" ]] && [[ -z "$(ls -A "${DB_DIRECTORY}")" ]] && [[ $(du -cs "${DB_DIRECTORY}"/* 2>/dev/null | awk '/total$/ {print $1}') -eq 0 ]]; then
    echo "INFO: The db directory is empty.."
    REMOVE_DB_DIR="Y"
    DOWNLOAD_SNAPSHOT="Y"
  else
    echo "INFO: The db directory is not empty.."
  fi
}

remove_db_dir() {
  # Mithril client errors if the db folder already exists, so remove it if it is empty
  if [[ "${REMOVE_DB_DIR}" == "Y" ]]; then
    echo "INFO: Removing empty db directory to prepare for snapshot download.."
    rmdir "${DB_DIRECTORY}"
  fi
}

download_snapshot() {
  if [[ "${DOWNLOAD_SNAPSHOT}" == "Y" ]]; then
    echo "INFO: Downloading latest mithril snapshot.."
    "${MITHRILBIN}" -v --aggregator-endpoint ${AGGREGATOR_ENDPOINT} snapshot download --download-dir ${CNODE_HOME} ${SNAPSHOT_DIGEST}
  else
    echo "INFO: Skipping snapshot download.."
  fi
}


#####################
# Execution         #
#####################

# Parse command line options
while getopts :duh opt; do
  case ${opt} in
    d ) MITHRIL_DOWNLOAD="Y" ;;
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

#Deploy systemd if -d argument was specified
if [[ "${UPDATE_ENVIRONMENT}" == "Y" ]] && [[ "${MITHRIL_DOWNLOAD}" != "Y" ]]; then
  set_defaults
elif [[ "${MITHRIL_DOWNLOAD}" == "Y" ]]; then
  set_defaults
  check_db_dir
  remove_db_dir
  download_snapshot
elif [[ "${UPDATE_ENVIRONMENT}" == "Y" ]] && [[ "${MITHRIL_DOWNLOAD}" == "Y" ]]; then
  set_defaults
  check_db_dir
  remove_db_dir
  download_snapshot
else
    usage
    exit 1
fi

exit 0
