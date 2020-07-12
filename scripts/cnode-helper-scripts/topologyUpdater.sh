#!/bin/bash

USERNAME="${USERNAME}" # replace nonroot with your username

CNODE_BIN="${HOME}/.cabal/bin"
CNODE_HOME="/opt/cardano/cnode"
CNODE_LOG_DIR="${CNODE_HOME}/logs/"

CNODE_PORT=6000  # must match your relay node port as set in the startup command
CNODE_HOSTNAME="CHANGE ME"  # optional. must resolve to the IP you are requesting from
CNODE_VALENCY=1   # optional for multi-IP hostnames

TESTNET_MAGIC=42

export PATH="${CNODE_BIN}:${PATH}"
export CARDANO_NODE_SOCKET_PATH="${CNODE_HOME}/sockets/node0.socket"

blockNo=$(cardano-cli shelley query tip --cardano-mode --testnet-magic $TESTNET_MAGIC | jq -r .blockNo )

# Note: 
# if you run your node in IPv4/IPv6 dual stack network configuration and want announced the 
# IPv4 address only please add the -4 parameter to the curl command below  (curl -4 -s ...)
if [ "${CNODE_HOSTNAME}" != "CHANGE ME" ]; then
  T_HOSTNAME="&hostname=${CNODE_HOSTNAME}"
else
  T_HOSTNAME=''
fi

curl -s "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&valency=${CNODE_VALENCY}&magic=${TESTNET_MAGIC}${T_HOSTNAME}" | tee -a $CNODE_LOG_DIR/topologyUpdater_lastresult.json
