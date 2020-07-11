#!/bin/sh
# shellcheck disable=SC2086,SC1090
. "$(dirname $0)"/env

if  [ "$1" = "--help" ] || [ $# -ne 1 ]; then
    echo "usage: $0 <Name of Key File>"
    exit 1
fi

WNAME=$1
${CCLI} shelley address key-gen --verification-key-file $WNAME.vkey --signing-key-file $WNAME.skey
${CCLI} shelley address build --payment-verification-key-file $WNAME.vkey  --testnet-magic ${NWMAGIC} | tee $WNAME.addr
