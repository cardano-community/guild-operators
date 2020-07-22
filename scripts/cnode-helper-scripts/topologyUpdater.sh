#!/bin/bash
# shellcheck disable=SC2086,SC2034

USERNAME="${USERNAME}" # replace nonroot with your username
CNODE_PORT=6000  # must match your relay node port as set in the startup command
CNODE_HOSTNAME="CHANGE ME"  # optional. must resolve to the IP you are requesting from

CNODE_BIN="${HOME}/.cabal/bin"
CNODE_HOME="/opt/cardano/cnode"
CNODE_LOG_DIR="${CNODE_HOME}/logs/"
CONFIG="$CNODE_HOME/files/ptn0.json"
GENESIS_JSON="${CNODE_HOME}/files/genesis.json"
NETWORKID=$(jq -r .networkId $GENESIS_JSON)
PROTOCOL=$(grep -E '^.{0,1}Protocol.{0,1}:' "$CONFIG" | tr -d '"' | tr -d ',' | awk '{print $2}')
if [[ "${PROTOCOL}" = "Cardano" ]]; then
  PROTOCOL_IDENTIFIER="--cardano-mode"
fi
CNODE_VALENCY=1   # optional for multi-IP hostnames
NWMAGIC=$(jq -r .networkMagic < $GENESIS_JSON)
[[ "${NETWORKID}" = "Mainnet" ]] && HASH_IDENTIFIER="--mainnet" || HASH_IDENTIFIER="--testnet-magic ${NWMAGIC}"
[[ "${NWMAGIC}" = "764824073" ]] && NETWORK_IDENTIFIER="--mainnet" || NETWORK_IDENTIFIER="--testnet-magic ${NWMAGIC}"

export PATH="${CNODE_BIN}:${PATH}"
export CARDANO_NODE_SOCKET_PATH="${CNODE_HOME}/sockets/node0.socket"

blockNo=$(cardano-cli shelley query tip ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} | jq -r .blockNo )

# Note: 
# if you run your node in IPv4/IPv6 dual stack network configuration and want announced the 
# IPv4 address only please add the -4 parameter to the curl command below  (curl -4 -s ...)
if [ "${CNODE_HOSTNAME}" != "CHANGE ME" ]; then
  T_HOSTNAME="&hostname=${CNODE_HOSTNAME}"
else
  T_HOSTNAME=''
fi

curl -s "https://api.clio.one/htopology/v1/?port=${CNODE_PORT}&blockNo=${blockNo}&valency=${CNODE_VALENCY}&magic=${NWMAGIC}${T_HOSTNAME}" | tee -a $CNODE_LOG_DIR/topologyUpdater_lastresult.json
