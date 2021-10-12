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
  [[ -z "${PGPASSFILE}" ]] && PGPASSFILE="${CNODE_HOME}/priv/.pgpass"
  [[ -z "${DBSYNCBIN}" ]] && DBSYNCBIN="${HOME}/.cabal/bin/cardano-db-sync-extended"
  [[ -z "${DBSYNC_STATE_DIR}" ]] && DBSYNC_STATE_DIR="${CNODE_HOME}/guild-db/ledger-state"
  [[ -z "${DBSYNC_SCHEMA_DIR}" ]] && DBSYNC_SCHEMA_DIR="${CNODE_HOME}/guild-db/schema"
  [[ -z "${DBSYNC_CONFIG}" ]] && DBSYNC_CONFIG="${CNODE_HOME}/files/dbsync.json"
}

check_defaults() {
  if [[ ! -f "${DBSYNCBIN}" ]] && [[ ! $(command -v cardano-db-sync-extended &>/dev/null) ]]; then
    echo "ERROR: cardano-db-sync-extended seems to be absent in PATH, please investigate \$PATH environment variable!"
    exit 1
  elif [[ ! -f "${PGPASSFILE}" ]]; then
    echo "ERROR: The PGPASSFILE (${PGPASSFILE}) not found, please ensure you've followed the instructions on guild-operators website!"
    exit 1
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
[[ ${0} != '-bash' ]] && PARENT=$(dirname $0) || PARENT="$(pwd)" # If sourcing at terminal, $0 would be "-bash" , which is invalid. Thus, fallback to present working directory

if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with prereqs.sh or manually download from GitHub\n"
  exit 1
fi
. "${PARENT}"/env
case $? in
  1) echo -e "ERROR: dbsync failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

set_defaults
check_defaults

if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  echo "Deploying systemd service.."
  sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_NAME}-dbsync.service
	[Unit]
	Description=Cardano DB Sync
	After=${CNODE_NAME}.service postgresql.service
	Requires=postgresql.service
	
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
