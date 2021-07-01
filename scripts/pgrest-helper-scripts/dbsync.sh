#!/bin/bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

[[ -z "${CNODE_HOME}" ]] && CNODE_HOME="/opt/cardano/cnode"

. "${CNODE_HOME}"/scripts/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

export PGPASSFILE=${CNODE_HOME}/priv/.pgpass
export PATH="${HOME}/.cabal/bin":$PATH

DBSYNC_STATE_DIR="state"
DBSYNC_SCHEMA_DIR="schema"
DBSYNC_CONFIG="files/dbsync.yaml"

######################################
# Do NOT modify code below           #
######################################

# no Runtime RTS tweaks as dbsync does not benefit from multi core operation

now=$(date +"%Y-%m-%d_%H-%M-%S")

# check if db-sync command is available
if $(! command -v cardano-db-sync-extended); then
  echo "${now} ERROR: cardano-db-sync-extended seems not to be in path." | tee -a ${LOG_DIR}/dbsync.log
  exit 1
else
  # archive logfile from previous run 
  [[ ! -d "${LOG_DIR}/archive" ]] && mkdir -p "${LOG_DIR}/archive"
  [[ $(find "${LOG_DIR}"/dbsync.log 2>/dev/null | wc -l) -gt 0 ]] && mv "${LOG_DIR}"/dbsync.log "${LOG_DIR}"/archive/dbsync_${now}.log
fi

# let's go relational ;)
cardano-db-sync-extended \
	--config ${DBSYNC_CONFIG} \
	--socket-path "${CARDANO_NODE_SOCKET_PATH}" \
	--schema-dir ${DBSYNC_SCHEMA_DIR} \
	--state-dir ${DBSYNC_STATE_DIR} \
	>> ${LOG_DIR}/dbsync.log 2>&1
