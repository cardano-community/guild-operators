#!/bin/bash
# shellcheck disable=SC2086,SC2034

######################################
# User Variables - Change as desired #
######################################

CNODE_PORT=6000                                           # Must match your relay node port as set in the startup command
CNODE_HOSTNAME="CHANGE ME"                                # (Optional) Must resolve to the IP you are requesting from
CNODE_BIN="${HOME}/.cabal/bin"                            # Path where your cardano-cli and cardano-node binaries are
CNODE_HOME="/opt/cardano/cnode"                           # (Optional) Top-level folder to auto populate file locations under, useful if using guild repo instructions
CNODE_LOG_DIR="${CNODE_HOME}/logs/"                       # Folder where your logs will be sent to (must pre-exist)
CONFIG="$CNODE_HOME/files/config.json"                    # Filename with path for config used by node
GENESIS_JSON=$(jq -er '.ShelleyGenesisFile' "${CONFIG}")  # Filename with path for Shelley genesis file used by node (auto detected if your config is in JSON format)
SOCKET="${CNODE_HOME}/sockets/node0.socket"               # Path to socket file for your cardano node instance
CNODE_VALENCY=1                                           # (Optional) for multi-IP hostnames

######################################
# Do NOT modify code below           #
######################################

NETWORKID=$(jq -r .networkId $GENESIS_JSON 2>/dev/null)
PROTOCOL=$(grep -E '^.{0,1}Protocol.{0,1}:' "$CONFIG" | tr -d '"' | tr -d ',' | awk '{print $2}')
[[ "${PROTOCOL}" = "Cardano" ]] && PROTOCOL_IDENTIFIER="--cardano-mode"
CNODE_VALENCY=1   # optional for multi-IP hostnames
NWMAGIC=$(jq -r .networkMagic < $GENESIS_JSON)
[[ "${NETWORKID}" = "Mainnet" ]] && HASH_IDENTIFIER="--mainnet" || HASH_IDENTIFIER="--testnet-magic ${NWMAGIC}"
[[ "${NWMAGIC}" = "764824073" ]] && NETWORK_IDENTIFIER="--mainnet" || NETWORK_IDENTIFIER="--testnet-magic ${NWMAGIC}"

export PATH="${CNODE_BIN}:${PATH}"
export CARDANO_NODE_SOCKET_PATH="${SOCKET}"

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
