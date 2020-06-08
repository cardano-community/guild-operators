#!/bin/bash

USERNAME="nonroot" # replace nonroot with your username

CNODE_BIN="/home/${USERNAME}/.cabal/bin"
CNODE_HOME="/opt/cardano/cnode"
CNODE_LOG_DIR="${CNODE_HOME}/logs/"

CNODE_PORT=6000  # must match your relay node port as set in the startup command
CNODE_HOSTNAME="myrelays.mydomain.com"  # optional. must resolve to the IP you are requesting from
CNODE_VALENCY=1   # optional for multi-IP hostnames

TESTNET_MAGIC=42


export DISPLAY=":0"
export PATH="${CNODE_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SHELL="/bin/bash"
export CARDANO_NODE_SOCKET_PATH="${CNODE_HOME}/sockets/node0.socket"

blockNo=$(cardano-cli shelley query tip --testnet-magic $TESTNET_MAGIC | grep -oP 'unBlockNo = \K\d+')

curl -s "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&hostname=${CNODE_HOSTNAME}&valency=${CNODE_VALENCY}" | tee -a $CNODE_LOG_DIR/topologyUpdater_lastresult.json