
export CNODE_HOME=/opt/cardano/cnode 
export CNODE_PORT=9000 
 
if [[ -d /configuration ]]; then
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port 8090 \
	--mainnet $@
elif [[ "$NETWORK" == "testnet" ]]; then
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port 8090 \
	--testnet $@
elif [[ "$NETWORK" == "mainnet" ]]; then
  exec cardano-wallet-byron serve \
	--node-socket /ipc/node.socket \
	--database /wallet-db \
	--listen-address 0.0.0.0 \
    	--port 8090 \
	--mainnet $@
else
  echo "Please set a NETWORK environment variable to one of: mainnet/testnet"
  echo "Or mount a /configuration volume containing: configuration.yaml, genesis.json, and topology.json + Pool.cert, Pool.key for active nodes"
fi
