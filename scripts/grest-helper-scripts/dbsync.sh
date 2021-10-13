#!/bin/bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null


######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#PGPASSFILE="${CNODE_HOME}/priv/.pgpass"                    # PGPass file containing connection information for the postgres instance
#DBSYNCBIN="${HOME}/.cabal/bin/cardano-db-sync-extended"    # Path for cardano-db-sync-extended binary, assumed to be available in $PATH
#DBSYNC_STATE_DIR="${CNODE_HOME}/guild-db/ledger-state"     # Folder where DBSync instance will dump ledger-state files
#DBSYNC_SCHEMA_DIR="${CNODE_HOME}/guild-db/schema"          # Path to DBSync repository's schema folder
#DBSYNC_CONFIG="${CNODE_HOME}/files/dbsync.json"            # Config file for dbsync instance
#SYSTEMD_PGNAME="postgresql"                                # Name for postgres instance, if changed from default

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d]
		
		Cardano DB Sync wrapper script !!
		-d    Deploy dbsync as a systemd service
		
		EOF
  exit 1
}

set_defaults() {
  [[ -z "${DBSYNCBIN}" ]] && DBSYNCBIN="${HOME}/.cabal/bin/cardano-db-sync-extended"
  [[ -z "${PGPASSFILE}" ]] && PGPASSFILE="${CNODE_HOME}/priv/.pgpass"
  [[ -z "${DBSYNC_CONFIG}" ]] && DBSYNC_CONFIG="${CNODE_HOME}/files/dbsync.json"
  [[ -z "${DBSYNC_SCHEMA_DIR}" ]] && DBSYNC_SCHEMA_DIR="${CNODE_HOME}/guild-db/schema"
  [[ -z "${DBSYNC_STATE_DIR}" ]] && DBSYNC_STATE_DIR="${CNODE_HOME}/guild-db/ledger-state"
  [[ -z "${SYSTEMD_PGNAME}" ]] && SYSTEMD_PGNAME="postgresql"
}

check_defaults() {
  if [[ ! -f "${DBSYNCBIN}" ]] && [[ ! $(command -v cardano-db-sync-extended &>/dev/null) ]]; then
    echo "ERROR: cardano-db-sync-extended seems to be absent in PATH, please investigate \$PATH environment variable!" && exit 1
  elif [[ ! -f "${PGPASSFILE}" ]]; then
    echo "ERROR: The PGPASSFILE (${PGPASSFILE}) not found, please ensure you've followed the instructions on guild-operators website!" && exit 1
    exit 1
  elif [[ ! -f "${DBSYNC_CONFIG}" ]]; then
    echo "ERROR: Could not find the dbsync config file: ${DBSYNC_CONFIG} . Please ensure you've run prereqs.sh and/or edit the DBSYNC_CONFIG variable if using a custom file." && exit 1
  elif [[ ! -d "${DBSYNC_SCHEMA_DIR}" ]]; then
    echo "ERROR: The schema directory (${DBSYNC_SCHEMA_DIR}) does not exist. Please ensure you've follow the instructions on guild-operators website" && exit 1
  fi
}

check_config_sanity() {
  genfiles=$(jq -r '[ .ByronGenesisFile, .ShelleyGenesisFile, .AlonzoGenesisFile] | @tsv' "${CONFIG}")
  [[ -z "${genfiles[1]}" ]] || [[ -z "${genfiles[2]}" ]] && err_exit "ERROR!! Could not find Shelley/Alonzo Genesis Files in ${CONFIG}! Please re-run prereqs.sh with right arguments!" && exit 1
  BYGENHASH=$(cardano-cli byron genesis print-genesis-hash --genesis-json "${genfiles[0]}" 2>/dev/null)
  BYGENHASHCFG=$(jq '.ByronGenesisHash' <"${CONFIG}" 2>/dev/null)
  SHGENHASH=$(cardano-cli genesis hash --genesis "${genfiles[1]}" 2>/dev/null)
  SHGENHASHCFG=$(jq '.ShelleyGenesisHash' <"${CONFIG}" 2>/dev/null)
  ALGENHASH=$(cardano-cli genesis hash --genesis "${genfiles[2]}" 2>/dev/null)
  ALGENHASHCFG=$(jq '.AlonzoGenesisHash' <"${CONFIG}" 2>/dev/null)
  # If hash are missing/do not match, add that to the end of config. We could have sorted it based on logic, but that would mess up sdiff comparison outputs
  if [[ "${BYGENHASH}" != "${BYGENHASHCFG}" ]] || [[ "${SHGENHASH}" != "${SHGENHASHCFG}" ]] || [[ "${ALGENHASH}" != "${ALGENHASHCFG}" ]]; then
    cp "${CONFIG}" "${CONFIG}".tmp
    jq --arg BYGENHASH ${BYGENHASH} --arg SHGENHASH ${SHGENHASH} --arg ALGENHASH ${ALGENHASH} '.ByronGenesisHash = $BYGENHASH | .ShelleyGenesisHash = $SHGENHASH | .AlonzoGenesisHash = $ALGENHASH' <"${CONFIG}" >"${CONFIG}".tmp
    mv -f "${CONFIG}".tmp "${CONFIG}"
  fi
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
[[ ! -f "./env" ]] && echo -e "\nCommon env file missing, please ensure latest prereqs.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
. "${PARENT}"/env
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

# Set defaults and do basic sanity tests
set_defaults
check_defaults
check_config_sanity

if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  echo "Deploying systemd service.."
  sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_NAME}-dbsync.service
	[Unit]
	Description=Cardano DB Sync
	After=${CNODE_NAME}.service ${SYSTEMD_PGNAME}.service
	Requires=${SYSTEMD_PGNAME}.service
	
	[Service]
	Type=simple
	Restart=always
	RestartSec=5
	User=${USER}
	LimitNOFILE=1048576
	WorkingDirectory=${CNODE_HOME}/scripts
	ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/dbsync.sh\"
	KillSignal=SIGINT
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=${CNODE_NAME}-dbsync
	TimeoutStopSec=5
	KillMode=mixed
	
	[Install]
	WantedBy=multi-user.target
	EOF" && echo "${CNODE_NAME}-dbsync.service deployed successfully!!" && systemctl daemon-reload && systemctl enable ${CNODE_NAME}-dbsync.service && exit 0
fi

export PGPASSFILE
cardano-db-sync-extended \
  --config ${DBSYNC_CONFIG} \
  --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
  --schema-dir ${DBSYNC_SCHEMA_DIR} \
  --state-dir ${DBSYNC_STATE_DIR}
