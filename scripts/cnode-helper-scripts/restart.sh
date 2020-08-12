#!/bin/bash
# shellcheck disable=SC2086,SC2034

##
# August 12 2020 - sk
##

CNODE_PORT=6000  # must match your relay node port as set in the startup command
CNODE_BIN="${HOME}/.cabal/bin"
CNODE_HOME="/opt/cardano/cnode"
CNODE_LOG_DIR="${CNODE_HOME}/logs/"
LOGFILE="$CNODE_LOG_DIR/restart.log"

export PATH="${CNODE_BIN}:${PATH}"

####
# Functions
###
start_node() {

echo "$(date) cardano node is NOT running" >> $LOGFILE;
echo "$(date) starting cardano node" >> $LOGFILE;


[[ ! -d "$CNODE_HOME/logs/archive" ]] && mkdir -p "$CNODE_HOME/logs/archive"
mv $CNODE_HOME/logs/*.json $CNODE_HOME/logs/archive/

tmux new-session -d -s cardano-node \
        "cardano-node run \
        --topology $CNODE_HOME/files/topology.json \
        --config $CNODE_HOME/files/config.json \
        --database-path $CNODE_HOME/db \
        --socket-path $CNODE_HOME/sockets/node0.socket \
        --host-addr 0.0.0.0 \
        --port 6000"
        # --shelley-kes-key /opt/cardano/cnode/priv/pool/<POOLNAME>/hot.skey \
        # --shelley-vrf-key /opt/cardano/cnode/priv/pool/<POOLNAME>/vrf.skey \
        # --shelley-operational-certificate /opt/cardano/cnode/priv/pool/<POOLNAME>/op.cert'

}



if pidof cardano-node > /dev/null;
then
    echo "$(date) cardano-node is running" >> $LOGFILE
else
    start_node &
fi
