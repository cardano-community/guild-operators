#!/usr/bin/env bash
# shellcheck disable=SC1090
# Only source env if not done already, this script is sourced from other scripts
[ "$0" = "${BASH_SOURCE[*]}" ] && . "$(dirname "$0")"/env

usage() { echo "Usage: $(basename "$0") <address or path to address file>" 1>&2; exit 1; }

if [[ $# -eq 0 ]]; then
  usage
elif [[ $# -eq 1 && ! -f "${#1}" ]]; then
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

# The "testnet magic" is specific on the testnet and will not be needed for the mainnet.
${CCLI} shelley query filtered-utxo --testnet-magic "${NWMAGIC}" --address "${WALLET_ADDR}" > /tmp/fullUtxo.out
echo ""
head -n 2 /tmp/fullUtxo.out

grep -v TxHash < /tmp/fullUtxo.out | grep -v "\-" | sort -k3 -nr > /tmp/balance.txt
head -n 10 /tmp/balance.txt
if [ ! -s /tmp/balance.txt ]; then
  [ "$0" = "${BASH_SOURCE[*]}" ] && exit || return
fi

TOTALBALANCE=0
UTx0_COUNT=0
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
