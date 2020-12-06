#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086
# Only source env if not done already, this script is sourced from other scripts
[ "$0" = "${BASH_SOURCE[*]}" ] && . "$(dirname "$0")"/env

usage() { echo "Usage: $(basename "$0") <address or path to address file>" 1>&2; exit 1; }

if [[ $# -eq 0 ]]; then
  usage
elif [[ $# -eq 1 && ! -f "$1" ]]; then
  WALLET_ADDR=$1
elif [[ $# -eq 1 ]]; then
  WALLET_ADDR="$(cat "$1")"
else
  usage
fi

function cleanup() {
  rm -rf /tmp/fullUtxo.out
  rm -rf /tmp/balance.txt
}

# start with a clean slate
cleanup

${CCLI} query utxo ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --address "${WALLET_ADDR}" > /tmp/fullUtxo.out
tail -n +3 /tmp/fullUtxo.out | sort -k3 -nr > /tmp/balance.txt

TOTALBALANCE=0
UTx0_COUNT=0

if [ -s /tmp/balance.txt ]; then
  echo ""
  head -n 2 /tmp/fullUtxo.out
  head -n 10 /tmp/balance.txt
fi

while read -r UTxO; do
  INADDR=$(awk '{ print $1 }' <<< "$UTxO")
  IDX=$(awk '{ print $2 }' <<< "$UTxO")
  BALANCE=$(awk '{ print $3 }' <<< "$UTxO")

  UTx0_COUNT=$(( UTx0_COUNT + 1 ))
  TX_IN="${TX_IN} --tx-in ${INADDR}#${IDX}"
  TOTALBALANCE=$(( TOTALBALANCE + BALANCE ))
done </tmp/balance.txt

[[ ${UTx0_COUNT} -gt 10 ]] && echo "... (top 10 UTx0 with most lovelace)"

# ADA pretty print explanation for sed
# remove trailing 0 IF there is a decimal separator
# remove the separator if there are only 0 after separator also (assuming there is at least a digit before like BC does)

TOTALBALANCE_ADA=$(echo "${TOTALBALANCE}/1000000" | bc -l | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
echo ""
echo "Total balance in ${UTx0_COUNT} UTxO is ${TOTALBALANCE} Lovelace or ${TOTALBALANCE_ADA} ADA"
echo ""
