#!/bin/bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

[[ -z "${CNODE_HOME}" ]] && CNODE_HOME="/opt/cardano/cnode"

. "${CNODE_HOME}"/scripts/env offline

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#POOL_DIR="${CNODE_HOME}/priv/pool/TEST"                 # set pool dir to run node as a core node
#TOPOLOGY="${CNODE_HOME}/files/topology.json"            # override default topology.json path

######################################
# Do NOT modify code below           #
######################################

[[ -z "${CNODE_PORT}" ]] && CNODE_PORT=6000
[[ -z "${SOCKET}" ]] && SOCKET="${CNODE_HOME}/sockets/node0.socket"
[[ -z "${CONFIG}" ]] && CONFIG="${CNODE_HOME}/files/config.json"
[[ -z "${TOPOLOGY}" ]] && TOPOLOGY="${CNODE_HOME}/files/topology.json"
[[ -z "${POOL_DIR}" ]] && POOL_DIR="${CNODE_HOME}/priv/pool/TEST"

if [[ -S "${SOCKET}" ]]; then
  if pgrep -f "[c]ardano-node.*.${SOCKET}"; then
     echo "ERROR: A Cardano node is already running, please terminate this node before starting a new one with this script."
     exit 1
  else
    echo "WARN: A prior running Cardano node was not cleanly shutdown, socket file still exists. Cleaning up."
    unlink ${SOCKET}
  fi
fi

[[ ! -d "${CNODE_HOME}/logs/archive" ]] && mkdir -p "${CNODE_HOME}/logs/archive"

[[ $(find "${CNODE_HOME}"/logs/*.json 2>/dev/null | wc -l) -gt 0 ]] && mv ${CNODE_HOME}/logs/*.json ${CNODE_HOME}/logs/archive/

if [[ -f "${POOL_DIR}/op.cert" && -f "${POOL_DIR}/vrf.skey" && -f "${POOL_DIR}/hot.skey" ]]; then
  cardano-node run \
	--topology ${TOPOLOGY} \
	--config ${CONFIG} \
	--database-path ${CNODE_HOME}/db \
	--socket-path ${SOCKET} \
	--host-addr 0.0.0.0 \
        --shelley-kes-key ${POOL_DIR}/hot.skey \
        --shelley-vrf-key ${POOL_DIR}/vrf.skey \
        --shelley-operational-certificate ${POOL_DIR}/op.cert \
	--port ${CNODE_PORT}
else
  cardano-node run \
        --topology ${TOPOLOGY} \
        --config ${CONFIG} \
        --database-path ${CNODE_HOME}/db \
        --socket-path ${SOCKET} \
        --host-addr 0.0.0.0 \
        --port ${CNODE_PORT}
fi
