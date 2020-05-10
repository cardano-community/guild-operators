#!/bin/sh

. $(dirname $0)/env

if  [ "$1" = "--help" ] || [ $# -ne 1 ]; then
    echo "usage: $0 <Name of Key File>"
    exit 1
fi

WNAME=$1
cardano-cli shelley address key-gen --verification-key-file $WNAME.vkey --signing-key-file $WNAME.skey
