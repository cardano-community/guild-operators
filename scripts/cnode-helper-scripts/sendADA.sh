#!/usr/bin/env bash

. $(dirname $0)/env

function cleanupAndExit() {
	echo "Exiting after cleanup"
	rm -rf /tmp/balance.txt
	rm -rf /tmp/protparams.json
	rm -rf /tmp/tx.signed
	exit 1
}

case $# in
  4 ) tx="$1";
    outaddr="$2";
    lovelace="$(( $3 * 1000000 ))";
    from_key="$4";
    from_addr="");;
  * ) cat >&2 <<EOF
Usage:  $(basename $0) <Tx-File to Create for submission> <Output Address> <Amount in ADA> <Account Key file>
EOF
  exit 1;; esac

NWMAGIC=`cat ${GENESIS_JSON} | jq .networkMagic`
echo "NW Magic is $NWMAGIC"

echo "getting protocol params"
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} > /tmp/protparams.json

echo "calculating min fee"
MINFEE=`${CCLI} shelley transaction calculate-min-fee --tx-in-count 1 --tx-out-count 2 --ttl 100000 --testnet-magic ${NWMAGIC} --signing-key-file ${from_key} --protocol-params-file /tmp/protparams.json | awk '{ print $2 }'`
echo "min fee is $MINFEE"

from_addr=`${CCLI} shelley address build-enterprise --payment-verification-key-file "${from_key%.*}.vkey"`
echo "from_ddress is $from_addr"

echo "balance check.."
${CCLI} shelley query filtered-utxo --testnet-magic ${NWMAGIC} --address ${from_addr} > /tmp/balance.txt
cat /tmp/balance.txt


if [[ `cat /tmp/balance.txt | wc -l` -lt 3 ]]; then
	echo "Aborting as balance check yielded under 3 lines"
	cleanupAndExit
fi

inaddr=`tail -n 1 /tmp/balance.txt | awk '{ print $1 }'`
idx=`tail -n 1 /tmp/balance.txt | awk '{ print $2 }'`
origbalance=`tail -n 1 /tmp/balance.txt | awk '{ print $3 }'`

newbalance=$(($origbalance-$MINFEE-$lovelace))
echo "new balance would be $newbalance"

echo "Going to try sending $3 ada from $inaddr index $idx"


#TODO : Update fee and ttl dynamically
args=" shelley transaction build-raw 
  --tx-in               ${inaddr}#${idx}
  --tx-out              ${outaddr}+$lovelace
  --tx-out		${from_addr}+$newbalance
  --ttl                 100000
  --fee                 ${MINFEE}
  --tx-body-file        ${tx}
"

echo "Args value is: $args"

NETARGS=(
  shelley transaction submit
  --tx-filepath "/tmp/tx.signed"
  --testnet-magic ${NWMAGIC}
)

set -x

${CCLI} ${args}
if [ $? -ne 0 ]; then
	echo "1 Something went wrong with args ${args}"
	cleanupAndExit
fi

${CCLI} shelley transaction sign --tx-body-file ${tx} --signing-key-file ${from_key} --testnet-magic ${NWMAGIC} --tx-file /tmp/tx.signed
if [ $? -ne 0 ]; then
	echo "1.5 Something went wrong during signing"
	cleanupAndExit
fi

echo "Starting sending"

${CCLI} ${NETARGS[*]}
if [ $? -ne 0 ]; then
	echo "2 Something went wrong with ${NETARGS}"
	cleanupAndExit
fi

echo "Finished"
