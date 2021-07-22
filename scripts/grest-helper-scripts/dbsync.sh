#!/bin/bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

export PGPASSFILE=${CNODE_HOME}/priv/.pgpass
export PATH="${HOME}/.cabal/bin":$PATH

DBSYNC_STATE_DIR="${CNODE_HOME}/guild-db/ledger-state"
DBSYNC_SCHEMA_DIR="${CNODE_HOME}/guild-db/schema"
DBSYNC_CONFIG="${CNODE_HOME}/files/dbsync.json"

######################################
# Do NOT modify code below           #
######################################

# no Runtime RTS tweaks as dbsync does not benefit from multi core operation

# check if db-sync command is available
if ! command -v cardano-db-sync-extended &>/dev/null; then
  echo "ERROR: cardano-db-sync-extended seems not to be in path."
  exit 1
fi

# let's go relational ;)
cardano-db-sync-extended \
  --config ${DBSYNC_CONFIG} \
  --socket-path "${CARDANO_NODE_SOCKET_PATH}" \
  --schema-dir ${DBSYNC_SCHEMA_DIR} \
  --state-dir ${DBSYNC_STATE_DIR}
