#!/bin/bash
# shellcheck disable=SC2086,SC1090
. "$(dirname $0)"/env offline

if  [ "$1" = "--help" ] || [ $# -ne 1 ]; then
  echo "Usage: $0 <Path with name (prefix) for keys to be created>"
  exit 1
fi

GREEN="\x1B[1;32m"
NC="\x1B[0m"

WNAME="$1"
${CCLI} address key-gen --verification-key-file ${WNAME}_payment.vkey --signing-key-file ${WNAME}_payment.skey
${CCLI} stake-address key-gen --verification-key-file ${WNAME}_stake.vkey --signing-key-file ${WNAME}_stake.skey
echo -e "${GREEN}Payment/Enterprise address:${NC}"
${CCLI} address build --payment-verification-key-file ${WNAME}_payment.vkey  ${PROTOCOL_IDENTIFIER} | tee ${WNAME}_payment.addr
echo -e "${GREEN}Base address:${NC}"
${CCLI} address build --payment-verification-key-file ${WNAME}_payment.vkey --stake-verification-key-file ${WNAME}_stake.vkey ${PROTOCOL_IDENTIFIER} | tee ${WNAME}_base.addr
echo -e "${GREEN}Reward address:${NC}"
${CCLI} stake-address build --stake-verification-key-file ${WNAME}_stake.vkey ${PROTOCOL_IDENTIFIER} | tee ${WNAME}_reward.addr
