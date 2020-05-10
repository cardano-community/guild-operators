#!/bin/bash

echo $NETWORK

. ~/.bashrc

export CNODE_HOME=/opt/cardano/cnode 
export CNODE_PORT=9000 
export CWALLET_PORT=8090 

if [[ -d /config ]]; then
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /config/wallet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--mainnet $@
elif [[ "$NETWORK" == "mainnet" ]]; then
  exec ln -s /opt/cardano/cnode/files/mainnet-topology.yaml /config/topology.yaml \
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--mainnet $@
elif [[ "$NETWORK" == "ptn0" ]]; then
  exec ln -s /opt/cardano/cnode/files/topology.json /config/topology.json \
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--mainnet $@
else
  echo "Please set a NETWORK environment variable to one of: mainnet/ptn0"
fi
