#!/bin/bash

echo $NETWORK

. ~/.bashrc

export CNODE_HOME=/opt/cardano/cnode 
export CNODE_PORT=9000 

if [[ -d /configuration ]]; then
  exec cardano-node run \
    --config /configuration/configuration.yaml \
    --database-path /tmp/db \
    --host-addr 127.0.0.1 \
    --port $CNODE_PORT \
    --socket-path /ipc/node.socket \
    --topology /configuration/topology.json $@
elif [[ "$NETWORK" == "passive" ]]; then
  exec cardano-node run \
  --config $CNODE_HOME/files/ptn0.yaml \
  --database-path $CNODE_HOME/db \
  --host-addr `curl ifconfig.me` \
  --port $CNODE_PORT \
  --topology $CNODE_HOME/files/topology.json $@
elif [[ "$NETWORK" == "active" ]]; then
  exec cardano-node run \
    --config /configuration/configuration.yaml \
    --database-path /tmp/db \
    --signing-key /configuration/Pool.key \
    --delegation-certificate /configuration/Pool.cert \
    --host-addr `curl ifconfig.me` \
    --port $CNODE_PORT \
    --socket-path /ipc/node.socket \
    --topology /configuration/topology.json $@
else
  echo "Please set a NETWORK environment variable to one of: active/passive"
  echo "Or mount a /configuration volume containing: configuration.yaml, genesis.json, and topology.json + Pool.cert, Pool.key for active nodes"
fi
# EKG Exposed
socat -d tcp-listen:12781,reuseaddr,fork tcp:127.0.0.1:12781 &
