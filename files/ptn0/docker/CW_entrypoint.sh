#!/bin/sh

echo $NETWORK

export CNODE_HOME=/opt/cardano/cnode 
export CNODE_PORT=9000 
export CWALLET_PORT=8090 

if [[ -d /configuration ]]; then
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--mainnet $@
elif [[ "$NETWORK" == "testnet" ]]; then
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--testnet $@
elif [[ "$NETWORK" == "mainnet" ]]; then
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port $CWALLET_PORT \
	--mainnet $@
else
  echo "Please set a NETWORK environment variable to one of: mainnet/testnet"
fi
