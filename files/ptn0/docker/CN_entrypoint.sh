#!/bin/bash

echo $NETWORK

. ~/.bashrc

export CNODE_HOME=/opt/cardano/cnode 
export CNODE_PORT=9000 

if [[ -d /configuration ]]; then
  exec cardano-node run \
  --topology /configuration/topology.json \
  --shelley-kes-key /configuration/Pool.skey \
  --shelley-operational-certificate /configuration/Pool.cert \
  --shelley-vrf-key /configuration/vrf.skey \
  --config /configuration/configuration.yaml \
  --database-path $CNODE_HOME/files/db \
  --port $CNODE_PORT \
  --socket-path /ipc/node.socket \
  --host-addr `curl ifconfig.me` $@ 
elif [[ "$NETWORK" == "mainnet" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/files/mainnet.yaml \
    --database-path /tmp/mainnet-db \
    --host-addr `curl ifconfig.me` \
    --port $CNODE_PORT \
    --socket-path /ipc/node.socket \
    --topology $CNODE_HOME/files/mainnet-topology.yaml $@
elif [[ "$NETWORK" == "ptn0" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/files/ptn0.yaml \
    --database-path $CNODE_HOME/mainnet-ptn0-db \
    --host-addr `curl ifconfig.me` \
    --port $CNODE_PORT \
    --socket-path /ipc/node.socket \
    --topology $CNODE_HOME/files/topology.json $@
else
  echo "Please set a NETWORK environment variable to one of: mainnet/ptn0"
  echo "Or mount a /configuration volume containing: configuration.yaml, genesis.json, and topology.json + Pool.cert, Pool.key for active nodes"
fi
# EKG Exposed
socat -d tcp-listen:12781,reuseaddr,fork tcp:127.0.0.1:12781 &
