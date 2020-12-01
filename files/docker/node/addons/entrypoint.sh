#!/bin/bash

echo "NETWORK: $NETWORK";
. ~/.bashrc

export CNODE_HOME=/opt/cardano/cnode
export CNODE_PORT=6000

echo "NODE: $HOSTNAME - Port:$CNODE_PORT - $POOL_NAME";
cardano-node --version;

sudo touch /etc/crontab /etc/cron.*/*
sudo cron  > /dev/null 2>&1
#sudo /etc/init.d/promtail start > /dev/null 2>&1

if [[ ! -d "/tmp/mainnet-combo-db" ]] && [[ $NETWORK != "master" ]] && [[ $NETWORK != "testnet" ]] ; then
cp -rf $CNODE_HOME/priv/mainnet-combo-db /tmp/mainnet-combo-db 2>/dev/null
else 
rm -rf /tmp/mainnet-combo-db 2>/dev/null
cp -rf $CNODE_HOME/priv/mainnet-combo-db /tmp/mainnet-combo-db 2>/dev/null
fi

if [[ ! -d "/tmp/testnet-combo-db" ]] && [[ $NETWORK = "testnet" ]] ; then
cp -rf $CNODE_HOME/priv/testnet-combo-db /tmp/testnet-combo-db 2>/dev/null
else 
rm -rf /tmp/testnet-combo-db 2>/dev/null
cp -rf $CNODE_HOME/priv/testnet-combo-db /tmp/testnet-combo-db 2>/dev/null
fi

if [[ "${POOL_NAME}" ]] ; then 
export POOL_DIR="$CNODE_HOME/priv/pool/$POOL_NAME"
echo "POOL_DIR set to: $POOL_DIR" ;
fi

# EKG Exposed
#socat -d tcp-listen:12782,reuseaddr,fork tcp:127.0.0.1:12781 

if [[ "$NETWORK" == "relay" ]]; then
  export TOPOLOGY="$CNODE_HOME/priv/files/mainnet-topology.json" \
  && export CONFIG="$CNODE_HOME/priv/files/mainnet-config.json" \
  && exec $CNODE_HOME/scripts/cnode.sh
elif [[ "$NETWORK" == "testnet" ]]; then
  export TOPOLOGY="$CNODE_HOME/priv/files/testnet-topology.json" \
  && export CONFIG="$CNODE_HOME/priv/files/testnet-config.json" \
  && exec $CNODE_HOME/scripts/cnode.sh
elif [[ "$NETWORK" == "master" ]]; then
  export TOPOLOGY=$CNODE_HOME/priv/files/mainnet-topology.json \
  && export CONFIG="$CNODE_HOME/priv/files/mainnet-config.json" \
  && sudo bash /home/guild/.scripts/master-topology.sh > /dev/null 2>&1 \
  && exec $CNODE_HOME/scripts/cnode.sh
elif [[ "$NETWORK" == "pool" ]] && [[ "${POOL_NAME}" ]] ; then
  export TOPOLOGY=$CNODE_HOME/priv/files/mainnet-topology.json \
  && export CONFIG="${CNODE_HOME}/files/config.json" \
  && exec $CNODE_HOME/scripts/cnode.sh
elif [[ "$NETWORK" == "guild_relay" ]]; then
  export TOPOLOGY="$CNODE_HOME/priv/files/guild_topology.json" \
  && export CONFIG="${CNODE_HOME}/files/config.json" \
  && sudo bash /home/guild/.scripts/guild-topology.sh > /dev/null 2>&1 \
  && exec $CNODE_HOME/scripts/cnode.sh
else
  echo "Please set a NETWORK environment variable to one of: relay / pool / testnet / guild_relay"
  echo "mount a '$CNODE_HOME/priv/files' volume containing: mainnet-config.json, mainnet-shelley-genesis.json, mainnet-byron-genesis.json, and mainnet-topology.json "
  echo "for active nodes set POOL_DIR where op.cert, hot.skey and vrf.skey files reside. (usually under '${CNODE_HOME}/priv/pool/$POOL_NAME' ) or just set POOL_NAME (for default path)"
fi