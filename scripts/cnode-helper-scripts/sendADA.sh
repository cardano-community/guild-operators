#!/usr/bin/env bash

function usage() {
  printf "\n%s\n\n" "Usage: $(basename $0) <Destination Address> <Amount> <Source Address> <Source Sign Key>"
  printf "  %-20s\t%s\n" \
    "Destination Address" "Address (72 or 140 chars) or path to Address file." \
    "Amount" "Amount in ADA, number(fraction of ADA valid) or the string 'all'." \
    "" "Amount sent is reduced with calculated transaction fee." \
    "Source Address" "Address (72 or 140 chars) or path to Address file." \
    "Source Sign Key" "Path to Signature (skey) file. For staking address payment skey is to be used."
  printf "\n"
  exit 1
}

if [[ $# -ne 4 ]]; then
  usage
fi

function myexit() {
  if [ ! -z "$1" ]; then
    echo "Exiting: $1"
  fi
  exit 1
}

function cleanup() {
  rm -rf /tmp/fullUtxo.out
  rm -rf /tmp/balance.txt
  rm -rf /tmp/protparams.json
  rm -rf /tmp/tx.signed
  rm -rf /tmp/tx.raw
}

# start with a clean slate
cleanup

# source env
. $(dirname $0)/env


# Handle script arguments
if [[ ${#1} -eq 72 || ${#1} -eq 140 ]]; then
  D_ADDR="$1"
elif [[ -f "$1" ]]; then
  D_ADDR="$(cat $1)"
else
  myexit "Not a valid destination address(72|140 chars) or a file on disk"
fi
re_number='^[0-9]+([.][0-9]+)?$'
if [[ $2 =~ ${re_number} ]]; then
  # /1 is to remove decimals from bc command
  LOVELACE=$(echo "$2 * 1000000 / 1" | bc)
elif [[ $2 = "all" ]]; then
  LOVELACE="all"
else
  myexit "'Amount in ADA' must be a valid number or the string 'all'"
fi
if [[ ${#3} -eq 72 || ${#3} -eq 140 ]]; then
  S_ADDR="$3"
elif [[ -f "$3" ]]; then
  S_ADDR="$(cat $3)"
else
  myexit "Not a valid source address(72|140 chars) or a file on disk"
fi
[[ -f "$4" ]] && S_SKEY="$4" || myexit "Source Sign file(skey) not found!"


echo ""
echo "## Protocol Parameters ##"
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} > /tmp/protparams.json
CURRSLOT=$(${CCLI} shelley query tip --testnet-magic ${NWMAGIC} | awk '{ print $5 }' | grep -Eo '[0-9]{1,}')
TTLVALUE=$((${CURRSLOT}+1000))
echo "TN Magic is ${NWMAGIC}"
echo "Current slot is ${CURRSLOT}, setting ttl to ${TTLVALUE}"

echo ""
echo "## Balance Check Destination Address ##"
. $(dirname $0)/balance.sh ${D_ADDR}
echo ""
echo "## Balance Check Source Address ##"
. $(dirname $0)/balance.sh ${S_ADDR}
if [ ! -s /tmp/balance.txt ]; then
	myexit "Failed to locate a UTxO, wallet empty?"
fi

if [[ ${LOVELACE} = "all" ]]; then
  LOVELACE=${TOTALBALANCE}
  echo "'Amount in ADA' set to 'all', lovelace to send set to total supply: ${TOTALBALANCE}"
fi

echo "Using UTxO's:"
BALANCE=0
UTx0_COUNT=0
TX_IN=""
while read UTxO; do
  INADDR=$(awk '{ print $1 }' <<< "${UTxO}")
  IDX=$(awk '{ print $2 }' <<< "${UTxO}")
  UTx0_BALANCE=$(awk '{ print $3 }' <<< "${UTxO}")
  echo "TxHash: ${INADDR}#${IDX}"
  echo "Lovelace: ${UTx0_BALANCE}"
  UTx0_COUNT=$((${UTx0_COUNT}+1))
  TX_IN="${TX_IN} --tx-in ${INADDR}#${IDX}"
  BALANCE=$((${BALANCE}+${UTx0_BALANCE}))
  [[ ${BALANCE} -ge ${LOVELACE} ]] && break
done </tmp/balance.txt

[[ ${BALANCE} -eq ${LOVELACE} ]] && OUT_COUNT=1 || OUT_COUNT=2

echo ""
echo "## Calculate fee, new amount and remaining balance ##"
MINFEE_ARGS=(
  shelley transaction calculate-min-fee
  --tx-in-count ${UTx0_COUNT}
  --tx-out-count ${OUT_COUNT}
  --ttl ${TTLVALUE}
  --testnet-magic ${NWMAGIC}
  --signing-key-file ${S_SKEY}
  --protocol-params-file /tmp/protparams.json
)
MINFEE=$(${CCLI} ${MINFEE_ARGS[*]} | awk '{ print $2 }')
echo "fee is ${MINFEE}"

if [ ${LOVELACE} -lt ${MINFEE} ]; then
	myexit "Fee deducted from ADA to send, can not be less than fee (${LOVELACE} < ${MINFEE})"
fi

NEWLOVELACE=$((${LOVELACE}-${MINFEE}))
echo "new amount to send in Lovelace after fee deduction is ${NEWLOVELACE} lovelaces (${LOVELACE} minus ${MINFEE})"

TX_OUT="--tx-out ${D_ADDR}+${NEWLOVELACE}"
if [[ ${OUT_COUNT} -eq 2 ]]; then
  NEWBALANCE=$((${BALANCE}-${LOVELACE}))
  TX_OUT="${TX_OUT} --tx-out ${S_ADDR}+${NEWBALANCE}"
  echo "balance left to be returned in used UTxO's is ${NEWBALANCE} lovelaces (${BALANCE} minus ${LOVELACE})"
fi

BUILD_ARGS=(
  shelley transaction build-raw
  ${TX_IN}
  ${TX_OUT}
  --ttl ${TTLVALUE}
  --fee ${MINFEE}
  --tx-body-file /tmp/tx.raw
)

SIGN_ARGS=(
  shelley transaction sign
  --tx-body-file /tmp/tx.raw
  --signing-key-file ${S_SKEY}
  --testnet-magic ${NWMAGIC}
  --tx-file /tmp/tx.signed
)

SUBMIT_ARGS=(
  shelley transaction submit
  --tx-filepath "/tmp/tx.signed"
  --testnet-magic ${NWMAGIC}
)

echo ""
echo "## Build, Sign & Send transaction ##"
echo "Build transaction"

output=$(${CCLI} ${BUILD_ARGS[*]})
if [[ -n $output ]]; then
	myexit "1. Problem during tx creation with args ${BUILD_ARGS[*]}"
fi

echo "Sign transaction"

output=$(${CCLI} ${SIGN_ARGS[*]})
if [[ -n $output ]]; then
	myexit "2. Problem during signing with args ${SIGN_ARGS[*]}"
fi

echo "Send transaction"

output=$(${CCLI} ${SUBMIT_ARGS[*]})
if [[ -n $output ]]; then
  echo "$output"
	myexit "3. Problem during tx submission with args ${SUBMIT_ARGS[*]}"
fi

waitNewBlockCreated

echo ""
echo "## Balance Check Destination Address ##"
. $(dirname $0)/balance.sh ${D_ADDR}
echo ""
echo "## Balance Check Source Address ##"
. $(dirname $0)/balance.sh ${S_ADDR}

echo "## Finished! ##"