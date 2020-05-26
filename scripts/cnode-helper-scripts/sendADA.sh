#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2206,SC2015
function usage() {
  printf "\n%s\n\n" "Usage: $(basename "$0") <Destination Address> <Amount> <Source Address> <Source Sign Key> [--include-fee]"
  printf "  %-20s\t%s\n" \
    "Destination Address" "Address or path to Address file." \
    "Amount" "Amount in ADA, number(fraction of ADA valid) or the string 'all'." \
    "Source Address" "Address or path to Address file." \
    "Source Sign Key" "Path to Signature (skey) file. For staking address payment skey is to be used." \
    "--include-fee" "Optional argument to specify that amount to send should be reduced by fee instead of payed by sender."
  printf "\n"
  exit 1
}

if [[ $# -lt 4 ]]; then
  usage
fi

function myexit() {
  if [ -n "$1" ]; then
    echo -e "\nError: $1\n"
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
. "$(dirname $0)"/env
. "$(dirname $0)"/cntools.library


# Handle script arguments
if [[ ! -f "$1" ]]; then
  D_ADDR="$1"
else
  D_ADDR="$(cat $1)"
fi

LOVELACE="$2"
re_number='^[0-9]+([.][0-9]+)?$'
if [[ ${LOVELACE} =~ ${re_number} ]]; then
  # /1 is to remove decimals from bc command
  LOVELACE=$(echo "${LOVELACE} * 1000000 / 1" | bc)
elif [[ ${LOVELACE} != "all" ]]; then
  myexit "'Amount in ADA' must be a valid number or the string 'all'"
fi

if [[ ! -f "$3" ]]; then
  S_ADDR="$3"
else
  S_ADDR="$(cat $3)"
fi

[[ -f "$4" ]] && S_SKEY="$4" || myexit "Source Sign file(skey) not found!"

if [[ $# -eq 5 ]]; then
  [[ $5 = "--include-fee" ]] && INCL_FEE="true" || usage
else
  INCL_FEE="false"
fi

echo ""
echo "## Protocol Parameters ##"
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} > /tmp/protparams.json
CURRSLOT=$(${CCLI} shelley query tip --testnet-magic ${NWMAGIC} | awk '{ print $5 }' | grep -Eo '[0-9]{1,}')
TTLVALUE=$(( CURRSLOT + 1000 ))
echo "TN Magic is ${NWMAGIC}"
echo "Current slot is ${CURRSLOT}, setting ttl to ${TTLVALUE}"

echo ""
echo "## Balance Check Destination Address ##"
. "$(dirname $0)"/balance.sh ${D_ADDR}
echo ""
echo "## Balance Check Source Address ##"
. "$(dirname $0)"/balance.sh ${S_ADDR}
if [ ! -s /tmp/balance.txt ]; then
  myexit "Failed to locate a UTxO, wallet empty?"
fi

if [[ ${LOVELACE} = "all" ]]; then
  INCL_FEE="true"
  LOVELACE=${TOTALBALANCE}
  echo "'Amount in ADA' set to 'all', lovelace to send set to total supply: ${TOTALBALANCE}"
fi

echo "Using UTxO's:"
BALANCE=0
UTx0_COUNT=0
TX_IN=""
while read -r UTxO; do
  INADDR=$(awk '{ print $1 }' <<< "${UTxO}")
  IDX=$(awk '{ print $2 }' <<< "${UTxO}")
  UTx0_BALANCE=$(awk '{ print $3 }' <<< "${UTxO}")
  echo "TxHash: ${INADDR}#${IDX}"
  echo "Lovelace: ${UTx0_BALANCE}"
  UTx0_COUNT=$(( UTx0_COUNT +1))
  TX_IN="${TX_IN} --tx-in ${INADDR}#${IDX}"
  BALANCE=$(( BALANCE + UTx0_BALANCE ))
  [[ ${INCL_FEE} = "true" && ${BALANCE} -ge ${LOVELACE} ]] && break
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

# Sanity checks
if [[ ${INCL_FEE} = "false" ]]; then
  if [[ ${BALANCE} -lt $(( LOVELACE + MINFEE )) ]]; then
    myexit "Not enough Lovelace in address (${BALANCE} < ${LOVELACE} + ${MINFEE})"
  fi
else
  if [[ ${LOVELACE} -lt ${MINFEE} ]]; then
    myexit "Fee deducted from ADA to send, amount can not be less than fee (${LOVELACE} < ${MINFEE})"
  elif [[ ${BALANCE} -lt ${LOVELACE} ]]; then
    myexit "Not enough Lovelace in address (${BALANCE} < ${LOVELACE})"
  fi
fi

if [[ ${INCL_FEE} = "false" ]]; then
  TX_OUT="--tx-out ${D_ADDR}+${LOVELACE}"
else
  TX_OUT="--tx-out ${D_ADDR}+$(( LOVELACE - MINFEE ))"
  echo "new amount to send in Lovelace after fee deduction is $(( LOVELACE - MINFEE )) lovelaces (${LOVELACE} - ${MINFEE})"
fi

NEWBALANCE=$(( TOTALBALANCE - LOVELACE ))
if [[ ${INCL_FEE} = "false" ]]; then
  NEWBALANCE=$(( BALANCE - LOVELACE - MINFEE ))
  TX_OUT="${TX_OUT} --tx-out ${S_ADDR}+${NEWBALANCE}"
  echo "balance left to be returned in used UTxO's is ${NEWBALANCE} lovelaces (${BALANCE} - ${LOVELACE} - ${MINFEE})"
elif [[ ${OUT_COUNT} -eq 2 ]]; then
  TX_OUT="${TX_OUT} --tx-out ${S_ADDR}+$(( BALANCE - LOVELACE ))"
  echo "balance left to be returned in used UTxO's is $(( BALANCE - LOVELACE )) lovelaces (${BALANCE} - ${LOVELACE})"
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
  --tx-file "/tmp/tx.signed"
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
echo "## Balance Check Source Address ##"
. "$(dirname $0)"/balance.sh ${S_ADDR}

while [[ ${TOTALBALANCE} -ne ${NEWBALANCE} ]]; do
  echo "Failure: Balance missmatch, transaction not included in latest block (${TOTALBALANCE} != ${NEWBALANCE})"
  waitNewBlockCreated
  echo ""
  echo "## Balance Check Source Address ##"
  . "$(dirname $0)"/balance.sh ${S_ADDR}
done

echo ""
echo "## Balance Check Destination Address ##"
. "$(dirname $0)"/balance.sh ${D_ADDR}

echo "## Finished! ##"
