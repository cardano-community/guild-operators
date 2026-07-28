#!/bin/bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null


######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#PGPASSFILE="${CNODE_HOME}/priv/.pgpass"                    # PGPass file containing connection information for the postgres instance
#DBSYNCBIN="${HOME}/.local/bin/cardano-db-sync"             # Path for cardano-db-sync binary, assumed to be available in $PATH
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
		       $(basename "$0") systemd <install|remove|status>

		Cardano DB Sync wrapper script !!
		-d    Deploy dbsync as a systemd service
		systemd
		      Install, remove, or show the status of the dbsync service
		
		EOF
  exit 1
}

set_defaults() {
  if [[ -z "${DBSYNCBIN}" ]]; then
    [[ -f "${HOME}/.local/bin/cardano-db-sync" ]] && DBSYNCBIN="${HOME}/.local/bin/cardano-db-sync" || DBSYNCBIN="$(command -v cardano-db-sync)"
  fi
  [[ -z "${PGPASSFILE}" ]] && PGPASSFILE="${CNODE_HOME}/priv/.pgpass"
  [[ -z "${DBSYNC_CONFIG}" ]] && DBSYNC_CONFIG="${CNODE_HOME}/files/dbsync.json"
  [[ -z "${DBSYNC_SCHEMA_DIR}" ]] && DBSYNC_SCHEMA_DIR="${CNODE_HOME}/guild-db/schema"
  [[ -z "${DBSYNC_STATE_DIR}" ]] && DBSYNC_STATE_DIR="${CNODE_HOME}/guild-db/ledger-state"
  [[ -z "${SYSTEMD_PGNAME}" ]] && SYSTEMD_PGNAME="postgresql"
}

check_defaults() {
  if [[ -z "${DBSYNCBIN}" ]]; then
    echo "ERROR: DBSYNCBIN variable is not set, please set full path to cardano-db-sync binary!" && exit 1
  elif [[ ! -f "${PGPASSFILE}" ]]; then
    echo "ERROR: The PGPASSFILE (${PGPASSFILE}) not found, please ensure you've followed the instructions on guild-operators website!" && exit 1
    exit 1
  elif [[ ! -f "${DBSYNC_CONFIG}" ]]; then
    echo "ERROR: Could not find the dbsync config file: ${DBSYNC_CONFIG} . Please ensure you've run guild-deploy.sh and/or edit the DBSYNC_CONFIG variable if using a custom file." && exit 1
  elif [[ ! -d "${DBSYNC_SCHEMA_DIR}" ]]; then
    echo "ERROR: The schema directory (${DBSYNC_SCHEMA_DIR}) does not exist. Please ensure you've follow the instructions on guild-operators website" && exit 1
  fi
}

check_config_sanity() {
  BYGENHASH=$("${CCLI}" byron genesis print-genesis-hash --genesis-json "${BYRON_GENESIS_JSON}" 2>/dev/null)
  BYGENHASHCFG=$(jq '.ByronGenesisHash' <"${CONFIG}" 2>/dev/null)
  SHGENHASH=$("${CCLI}" hash genesis-file --genesis "${GENESIS_JSON}" 2>/dev/null)
  SHGENHASHCFG=$(jq '.ShelleyGenesisHash' <"${CONFIG}" 2>/dev/null)
  ALGENHASH=$("${CCLI}" hash genesis-file --genesis "${ALONZO_GENESIS_JSON}" 2>/dev/null)
  ALGENHASHCFG=$(jq '.AlonzoGenesisHash' <"${CONFIG}" 2>/dev/null)
  CWGENHASH=$("${CCLI}" hash genesis-file --genesis "${CONWAY_GENESIS_JSON}" 2>/dev/null)
  CWGENHASHCFG=$(jq '.ConwayGenesisHash' <"${CONFIG}" 2>/dev/null)
  # If hash are missing/do not match, add that to the end of config. We could have sorted it based on logic, but that would mess up sdiff comparison outputs
  if [[ "${BYGENHASH}" != "${BYGENHASHCFG}" ]] || [[ "${SHGENHASH}" != "${SHGENHASHCFG}" ]] || [[ "${ALGENHASH}" != "${ALGENHASHCFG}" ]] || [[ "${CWGENHASH}" != "${CWGENHASHCFG}" ]]; then
    cp "${CONFIG}" "${CONFIG}".tmp
    jq --arg BYGENHASH ${BYGENHASH} --arg SHGENHASH ${SHGENHASH} --arg ALGENHASH ${ALGENHASH} --arg CWGENHASH ${CWGENHASH} '.ByronGenesisHash = $BYGENHASH | .ShelleyGenesisHash = $SHGENHASH | .AlonzoGenesisHash = $ALGENHASH | .ConwayGenesisHash = $CWGENHASH' <"${CONFIG}" >"${CONFIG}".tmp
    [[ -s "${CONFIG}".tmp ]] && mv -f "${CONFIG}".tmp "${CONFIG}"
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
  local unit_name="${CNODE_VNAME}-dbsync.service"
  local unit_content

  load_systemd_library || return 1
  echo "Deploying ${CNODE_VNAME}-dbsync as systemd service.."
  read -r -d '' unit_content <<-EOF || true
		[Unit]
		Description=Cardano DB Sync
		After=${CNODE_VNAME}.service ${SYSTEMD_PGNAME}.service
		Requires=${SYSTEMD_PGNAME}.service

		[Service]
		Type=simple
		Restart=always
		RestartSec=5
		User=${USER}
		LimitNOFILE=1048576
		WorkingDirectory=${CNODE_HOME}/scripts
		ExecStart=/bin/bash -l -c "exec ${CNODE_HOME}/scripts/dbsync.sh"
		KillSignal=SIGINT
		SyslogIdentifier=${CNODE_VNAME}-dbsync
		TimeoutStopSec=5
		KillMode=mixed

		[Install]
		WantedBy=multi-user.target
	EOF
  systemd_install_unit "${unit_name}" "${unit_content}" "${CNODE_HOME}/scripts/dbsync.sh" &&
    systemd_daemon_reload &&
    systemd_enable_units "${unit_name}" &&
    echo "${unit_name} deployed successfully!!"
}

manage_systemd() {
  local action="${1:-}"
  local unit_name="${CNODE_VNAME}-dbsync.service"

  case "${action}" in
    install)
      check_defaults
      check_config_sanity
      deploy_systemd
      ;;
    remove)
      load_systemd_library &&
        systemd_remove_units --owner-token "${CNODE_HOME}/scripts/dbsync.sh" "${unit_name}" &&
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
PARENT="$(dirname "$0")"
[[ ! -f "${PARENT}"/env ]] && echo -e "\nCommon env file missing, please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
if [[ "${SYSTEMD_ACTION}" == "remove" || "${SYSTEMD_ACTION}" == "status" ]]; then
  . "${PARENT}"/env definitions
else
  . "${PARENT}"/env
fi
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

# Set defaults and do basic sanity tests
set_defaults
if [[ -n "${SYSTEMD_ACTION}" ]]; then
  manage_systemd "${SYSTEMD_ACTION}"
  exit $?
fi
check_defaults
check_config_sanity
#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && exit 0
  exit 2
fi

export PGPASSFILE
"${DBSYNCBIN}" \
  --config "${DBSYNC_CONFIG}" \
  --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
  --schema-dir "${DBSYNC_SCHEMA_DIR}" \
  ${DBSYNC_ARGS} \
  --state-dir "${DBSYNC_STATE_DIR}"
