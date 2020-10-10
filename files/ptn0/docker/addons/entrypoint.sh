#!/bin/bash

echo "NETWORK: $NETWORK";
. ~/.bashrc

export CNODE_HOME=/opt/cardano/cnode 
export CNODE_PORT=6000
export POOL=$@ 

echo "NODE: $HOSTNAME - $POOL";
cardano-node --version;

sudo touch /etc/crontab /etc/cron.*/*
sudo cron  > /dev/null 2>&1
sudo /etc/init.d/promtail start > /dev/null 2>&1

if [[ $NETWORK = "master" ]] ; then
sudo bash /home/guild/.scripts/master-topology.sh > /dev/null 2>&1
fi

if [[ $NETWORK = "guild_relay" ]] ; then
sudo bash /home/guild/.scripts/guild-topology.sh > /dev/null 2>&1
fi


if [[ ! -d "/tmp/mainnet-combo-db" ]] && [[ $NETWORK != "master" ]] && [[ $NETWORK != "testnet" ]] ; then
cp -rf $CNODE_HOME/priv/mainnet-combo-db /tmp/mainnet-combo-db
else 
rm -rf /tmp/mainnet-combo-db
cp -rf $CNODE_HOME/priv/mainnet-combo-db /tmp/mainnet-combo-db
fi

# EKG Exposed
#socat -d tcp-listen:12782,reuseaddr,fork tcp:127.0.0.1:12781 

if [[ "$NETWORK" == "relay" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/priv/files/mainnet-config.json \
    --database-path /tmp/mainnet-combo-db \
    --host-addr 0.0.0.0 \
    --port $CNODE_PORT \
    --socket-path $CNODE_HOME/sockets/node0.socket \
    --topology $CNODE_HOME/priv/files/mainnet-topology.json
elif [[ "$NETWORK" == "testnet" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/priv/files/testnet-config.json \
    --database-path $CNODE_HOME/priv/testnet-combo-db \
    --host-addr 0.0.0.0 \
    --port $CNODE_PORT \
    --socket-path $CNODE_HOME/sockets/node0.socket \
    --topology $CNODE_HOME/priv/files/testnet-topology.json
elif [[ "$NETWORK" == "master" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/priv/files/mainnet-config.json \
    --database-path $CNODE_HOME/priv/mainnet-combo-db \
    --host-addr 0.0.0.0 \
    --port $CNODE_PORT \
    --socket-path $CNODE_HOME/sockets/node0.socket \
    --topology $CNODE_HOME/priv/files/mainnet-master.json
elif [[ "$NETWORK" == "pool" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/priv/files/mainnet-config.json \
    --database-path /tmp/mainnet-combo-db \
    --host-addr 0.0.0.0 \
    --port $CNODE_PORT \
    --socket-path $CNODE_HOME/sockets/node0.socket \
    --shelley-operational-certificate $CNODE_HOME/priv/pool/$POOL/op.cert \
    --shelley-kes-key $CNODE_HOME/priv/pool/$POOL/hot.skey \
    --shelley-vrf-key $CNODE_HOME/priv/pool/$POOL/vrf.skey \
    --topology $CNODE_HOME/priv/files/mainnet-topology.json
elif [[ "$NETWORK" == "guild_relay" ]]; then
  exec cardano-node run \
    --config $CNODE_HOME/priv/files/mainnet-config.json \
    --database-path /tmp/mainnet-combo-db \
    --host-addr 0.0.0.0 \
    --port $CNODE_PORT \
    --socket-path $CNODE_HOME/sockets/node0.socket \
    --topology $CNODE_HOME/priv/files/guild_topology.json
else
  echo "Please set a NETWORK environment variable to one of: relay/master/pool/testnet/guild_relay"
  echo "Or mount a '$CNODE_HOME/priv/files' volume containing: mainnet-config.json, mainnet-shelley-genesis.json, mainnet-byron-genesis.json, and mainnet-topology.json + $CNODE_HOME/priv/pool/$POOL/op.cert, $CNODE_HOME/priv/pool/$POOL/hot.skey and $CNODE_HOME/priv/pool/$POOL/vrf.skey for active nodes"
fi
