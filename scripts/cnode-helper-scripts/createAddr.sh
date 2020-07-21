#!/bin/bash
# shellcheck disable=SC2086,SC1090
. "$(dirname $0)"/env

if  [ "$1" = "--help" ] || [ $# -ne 1 ]; then
  echo "Usage: $0 <Path with name (prefix) for keys to be created>"
  exit 1
fi

WNAME="$1"
${CCLI} shelley address key-gen --verification-key-file ${WNAME}_pay.vkey --signing-key-file ${WNAME}_pay.skey
${CCLI} shelley stake-address key-gen --verification-key-file ${WNAME}_stake.vkey --signing-key-file ${WNAME}_stake.skey
${CCLI} shelley address build --payment-verification-key-file ${WNAME}_pay.vkey  ${HASH_IDENTIFIER} | tee ${WNAME}_pay.addr
${CCLI} shelley address build --payment-verification-key-file ${WNAME}_pay.vkey --stake-verification-key-file ${WNAME}_stake.vkey ${HASH_IDENTIFIER} | tee ${WNAME}_stake.addr
