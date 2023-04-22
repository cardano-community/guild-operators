#!/usr/bin/env bash

source /opt/cardano/cnode/scripts/env

CCLI=$(which cardano-cli)

if [[ "$NETWORK" == "guild-mainnet" ]]; then NETWORK=mainnet; fi

# For querying tip, the seperation of testnet-magic vs mainnet as argument is optional

FIRST=$($CCLI query tip --testnet-magic ${NWMAGIC} | jq .block)

if [[ "${ENABLE_KOIOS}" == "N" ]] || [[ -z "${KOIOS_API}" ]]; then
    # when KOIOS is not enabled or KOIOS_API is unset, use default behavior
    sleep 60;
    SECOND=$($CCLI query tip --testnet-magic ${NWMAGIC} | jq .block)
    if [[ "$FIRST" -ge "$SECOND" ]]; then
        echo "there is a problem"
        exit 1
    else
        echo "we're healthy - node: $FIRST -> node: $SECOND"
    fi
else
    # else leverage koios and only require the node is on tip
    CURL=$(which curl)
    JQ=$(which jq)
    URL="${KOIOS_API}/tip"
    SECOND=$($CURL -s "${URL}" | $JQ '.[0].block_no')
    for (( CHECK=1; CHECK<=20; CHECK++ )); do
        if [[ "$FIRST" -eq "$SECOND" ]]; then
            echo "we're healthy - node: $FIRST == koios: $SECOND"
            exit 0
        elif [[ "$FIRST" -lt "$SECOND" ]]; then
            sleep 3
            FIRST=$($CCLI query tip --testnet-magic ${NWMAGIC} | jq .block)
        elif [[ "$FIRST" -gt "$SECOND" ]]; then
            sleep 3
            SECOND=$($CURL "${KOIOS_URL}" | $JQ '.[0].block_no')
        fi
    done
    echo "there is a problem"
    exit 1
fi
