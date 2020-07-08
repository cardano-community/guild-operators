#!/bin/bash

echo $NETWORK
. ~/.bashrc

export CNODE_HOME=/opt/cardano/cnode 
export CNODE_PORT=19000 

# Create the Node operation keys
#cardano-cli shelley node key-gen-VRF --verification-key-file $CNODE_HOME/priv/vrf.vkey --signing-key-file $CNODE_HOME/priv/vrf.skey
#cardano-cli shelley node key-gen-KES --verification-key-file $CNODE_HOME/priv/kes.vkey --signing-key-file $CNODE_HOME/priv/kes.skey
# TODO: Process to propogate keys in genesis to members
#cardano-cli shelley node issue-op-cert --hot-kes-verification-key-file $CNODE_HOME/priv/kes.vkey --cold-signing-key-file $CNODE_HOME/priv/delegate.skey --operational-certificate-issue-counter $CNODE_HOME/priv/delegate.counter --kes-period 0 --out-file $CNODE_HOME/priv/ops.cert 

# EKG Exposed
# socat -d tcp-listen:12782,reuseaddr,fork tcp:127.0.0.1:12781 &

if [[ -d /configuration ]]; then
  exec cardano-node run \
  --topology /configuration/topology.json \
  --shelley-kes-key /configuration/kes.skey \
  --shelley-operational-certificate /configuration/ops.cert \
  --shelley-vrf-key /configuration/vrf.skey \
  --config /configuration/configuration.yaml \
  --database-path /tmp/mainnet-ptn0-db \
  --port $CNODE_PORT \
  --socket-path /ipc/node.socket \
  --host-addr `curl ifconfig.me` $@ 
elif [[ "$NETWORK" == "mainnet" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/files/mainnet.yaml \
    --database-path /tmp/mainnet-db \
    --host-addr 0.0.0.0 \
    --port $CNODE_PORT \
    --socket-path /ipc/node.socket \
    --topology $CNODE_HOME/files/mainnet-topology.yaml $@
elif [[ "$NETWORK" == "relay-htn" ]]; then
  curl -so $CNODE_HOME/files/genesis.json https://hydra.iohk.io/build/3246637/download/1/shelley_testnet-genesis.json
  curl -so $CNODE_HOME/files/ptn0.yaml https://hydra.iohk.io/build/3246637/download/1/shelley_testnet-config.json
  curl -so $CNODE_HOME/files/topology.json https://hydra.iohk.io/build/3246637/download/1/shelley_testnet-topology.json
  export GENESIS_JSON=$CNODE_HOME/files/genesis.json;
   . /opt/cardano/cnode/scripts/env;
  exec cardano-node run \
   --config $CONFIG \
   --database-path /tmp/mainnet-shelley_testnet-db \
   --host-addr 0.0.0.0 \
   --port $CNODE_PORT \
   --socket-path $NODE_SOCKET_PATH \
   --topology $CNODE_HOME/files/shelley_testnet-topology.json $@ 
elif [[ "$NETWORK" == "htn" ]]; then
  curl -so $CNODE_HOME/files/genesis.json https://hydra.iohk.io/build/3246637/download/1/shelley_testnet-genesis.json
  curl -so $CNODE_HOME/files/ptn0.yaml https://hydra.iohk.io/build/3246637/download/1/shelley_testnet-config.json
  curl -so $CNODE_HOME/files/topology.json https://hydra.iohk.io/build/3246637/download/1/shelley_testnet-topology.json
  export GENESIS_JSON=$CNODE_HOME/files/genesis.json;
  exec cardano-node run \
   --shelley-operational-certificate /keys/shelley_testnet/opcert \
   --shelley-kes-key /keys/ff/kes.skey \
   --shelley-vrf-key /keys/ff/vrf.skey \
   --config $CNODE_HOME/files/shelley_testnet-config.json \
   --database-path /tmp/mainnet-shelley_testnet-pool-db \
   --host-addr 127.0.0.1 \
   --port 4240 \
   --socket-path /ipc/node.socket \
   --topology $CNODE_HOME/files/shelley_testnet-topology.json $@
elif [[ "$NETWORK" == "relay-ptn0" ]]; then
   . /opt/cardano/cnode/scripts/env;
   exec cardano-node run --config $CONFIG \
   --database-path /tmp/mainnet-ptn0-db \
   --host-addr 0.0.0.0 \
   --port $CNODE_PORT \
   --socket-path $NODE_SOCKET_PATH \
   --topology $CNODE_HOME/files/topology.json $@
elif [[ "$NETWORK" == "ptn0" ]]; then
   . /opt/cardano/cnode/scripts/env;
  exec cardano-node run \
   --config $CNODE_HOME/files/ptn0.yaml \
   --database-path /tmp/mainnet-ptn0p-db \
   --host-addr 0.0.0.0 \
   --port $CNODE_PORT \
   --socket-path /ipc/node.socket \
   --shelley-operational-certificate /$CNODE_HOME/priv/ops.cert \
   --shelley-kes-key $CNODE_HOME/priv/kes.skey \
   --shelley-vrf-key $CNODE_HOME/priv/vrf.skey \
   --topology $CNODE_HOME/files/topology.json $@
else
  echo "Please set a NETWORK environment variable to one of: mainnet/ff/ptn0"
  echo "Or mount a /configuration volume containing: configuration.yaml, genesis.json, and topology.json + Pool.cert, Pool.key for active nodes"
fi
