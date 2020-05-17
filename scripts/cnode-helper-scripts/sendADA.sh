#!/usr/bin/env bash

. $(dirname $0)/env

function cleanup() {
	rm -rf /tmp/balance.txt
	rm -rf /tmp/protparams.json
	rm -rf /tmp/tx.signed
}

function myexit() {
	if [ ! -z "$1" ]; then
		echo "Exiting: $1"
	fi
	exit 1
}

# start with a clean slate
cleanup

case $# in
  4 ) tx="$1";
    outaddr="$2";
    lovelace="$(( $3 * 1000000 ))";
    from_key="$4";
    from_addr="";;
  * ) cat >&2 <<EOF
Usage:  $(basename $0) <Tx-File to Create for submission> <Output Address> <Amount in ADA> <Signing Key file (script expects .vkey with same name in same folder)>
EOF
  exit 1;; esac

echo "NW Magic is $NWMAGIC"

echo "getting protocol params"
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} > /tmp/protparams.json
# cat /tmp/protparams.json

currSlot=`cardano-cli shelley query tip --testnet-magic ${NWMAGIC} | awk '{ print $5 }' | grep -Eo '[0-9]{1,}'`
ttlvalue=$(($currSlot+1000))
echo "current slot is $currSlot, setting ttl to $ttlvalue"

echo "calculating min fee"
MINFEE=`${CCLI} shelley transaction calculate-min-fee --tx-in-count 1 --tx-out-count 2 --ttl ${ttlvalue} --testnet-magic ${NWMAGIC} --signing-key-file ${from_key} --protocol-params-file /tmp/protparams.json | awk '{ print $2 }'`
echo "min fee is $MINFEE"

from_addr=`${CCLI} shelley address build --payment-verification-key-file "${from_key%.*}.vkey"`
echo "from_ddress is $from_addr"

echo "balance check.."
${CCLI} shelley query filtered-utxo --testnet-magic ${NWMAGIC} --address ${from_addr} > /tmp/fullUtxo.out
${CCLI} shelley query filtered-utxo --testnet-magic ${NWMAGIC} --address ${from_addr} | grep -v TxHash | grep -v "\-" | sort -k 3 -nr | head -n 1  > /tmp/balance.txt
cat /tmp/balance.txt

if [ ! -s /tmp/balance.txt ]; then
	myexit "Aborting, as failed to locate a UTXO"
fi

inaddr=`awk '{ print $1 }' /tmp/balance.txt`
idx=`awk '{ print $2 }' /tmp/balance.txt`
origbalance=`awk '{ print $3 }' /tmp/balance.txt`

echo "Using UTXO with highest value balance:"
cat /tmp/balance.txt

newbalance=$(($origbalance-$MINFEE-$lovelace))
echo "new balance would be $newbalance lovelaces ($origbalance minus $MINFEE minus $lovelace)"

if [ $newbalance -lt 0 ]; then
	myexit "New balance is $newbalance is negative - aborting"
fi

echo "Going to try sending $3 ADA from $inaddr index $idx"

#TODO : Update fee and ttl dynamically
args=" shelley transaction build-raw 
  --tx-in               ${inaddr}#${idx}
  --tx-out              ${outaddr}+$lovelace
  --tx-out		${from_addr}+$newbalance
  --ttl                 ${ttlvalue}
  --fee                 ${MINFEE}
  --tx-body-file        ${tx}
"

# echo "Args value is: $args"

NETARGS=(
  shelley transaction submit
  --tx-filepath "/tmp/tx.signed"
  --testnet-magic ${NWMAGIC}
)

set -x

${CCLI} ${args}
if [ $? -ne 0 ]; then
	myexit  "1. Problem during tx creation with args ${args}"
fi

${CCLI} shelley transaction sign --tx-body-file ${tx} --signing-key-file ${from_key} --testnet-magic ${NWMAGIC} --tx-file /tmp/tx.signed
if [ $? -ne 0 ]; then
	myexit "1.5 Problem during signing"
fi

echo "Starting sending"

${CCLI} ${NETARGS[*]}
if [ $? -ne 0 ]; then
	myexit "2. Problem during tx submission with args ${NETARGS}"
fi

echo "Finished"
