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
elif [[ "$NETWORK" == "testnet" ]]; then
  exec ln -s /opt/cardano/cnode/files/testnet-topology.json /config/topology.json \
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-testnet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--testnet $@
elif [[ "$NETWORK" == "mainnet" ]]; then
  exec ln -s /opt/cardano/cnode/files/mainnet-topology.json /config/topology.json \
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-mainnet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--mainnet $@
elif [[ "$NETWORK" == "ptn0" ]]; then
  exec ln -s /opt/cardano/cnode/files/topology.json /config/topology.json \
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-ptn0-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--mainnet $@
else
  echo "Please set a NETWORK environment variable to one of: mainnet/testnet"
fi
