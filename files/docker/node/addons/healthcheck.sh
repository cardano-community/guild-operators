#!/bin/bash

source /opt/cardano/cnode/scripts/env

CCLI=$(which cardano-cli)

if [[ "$NETWORK" == "guildnet" ]]; then NETWORK=mainnet; fi

FIRST=$($CCLI query tip --shelley-mode --testnet-magic $(jq .networkMagic /opt/cardano/cnode/priv/files/$NETWORK-shelley-genesis.json) | jq .blockNo)

sleep 60;

SECOND=$($CCLI query tip --shelley-mode --testnet-magic $(jq .networkMagic /opt/cardano/cnode/priv/files/$NETWORK-shelley-genesis.json) | jq .blockNo)


if [[ "$FIRST" -ge "$SECOND" ]]; then
echo "there is a problem";
exit 1
else
echo "we're healthy - $FIRST -> $SECOND"
fi

if [[ `cardano-ping -h 127.0.0.1 -p 6000 -c 3  2>/dev/null` ]]; then echo "Ping alive"; else echo "there is a problem"; exit 1; fi
