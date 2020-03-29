#!/bin/sh

. $(dirname $0)/env

if  [ "$1" = "--help" ] || [ $# -ne 1 ]; then
    echo "usage: $0 <Name of Key File>"
    exit 1
fi

WNAME=$1
$CCLI keygen --real-pbft --secret $WNAME
#$CCLI to-verification --real-pbft --secret $WNAME --to $WNAME.verify
#$CCLI signing-key-public --real-pbft --secret $WNAME >> $WNAME.pubinfo
$CCLI signing-key-address --real-pbft --testnet-magic 459045235 --secret $WNAME |head -1 >> $WNAME.addr
