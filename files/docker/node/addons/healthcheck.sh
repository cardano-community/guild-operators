#!/usr/bin/env bash

source /opt/cardano/cnode/scripts/env

CCLI=$(which cardano-cli)

if [[ "$NETWORK" == "guild-mainnet" ]]; then NETWORK=mainnet; fi

# For querying tip, the seperation of testnet-magic vs mainnet as argument is optional

FIRST=$($CCLI query tip --testnet-magic ${NWMAGIC} | jq .block)

sleep 60;

SECOND=$($CCLI query tip --testnet-magic ${NWMAGIC} | jq .block)


if [[ "$FIRST" -ge "$SECOND" ]]; then
echo "there is a problem";
exit 1
else
echo "we're healthy - $FIRST -> $SECOND"
fi

if [[ `cardano-ping -h 127.0.0.1 -p 6000 -c 3  2>/dev/null` ]]; then echo "Ping alive"; else echo "there is a problem"; exit 1; fi
