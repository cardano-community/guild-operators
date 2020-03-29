#!/bin/bash

# Disclaimer:
#
#  The following use of shell script is for demonstration and understanding
#  only, it should *NOT* be used at scale or for any sort of serious
#  deployment, and is solely used for learning how the node and blockchain
#  works, and how to interact with everything.
#
#  This script is sending a number of transactions from a source account (that needs to have enough funds) to 
#  a new account address. 

. $(dirname $0)/env

INITIAL_TIP=""
TX_COUNTER_SAME_SLOT=0
INITIAL_SRC_COUNTER=0

if [ "$1" == "--help" ]] || [ $# -ne 2 ]; then
  echo "usage: $0 <ACCOUNT_SK> <NO-OF-TRANSACTIONS>"
  echo "    <ACCOUNT_SK>         The Secret key of the Source Account address (for transactions)"
  echo "    <NO-OF-TRANSACTIONS> Number of transactions to be sent from Faucet to Account"
  exit 1
fi

ACCOUNT_SK=$1
NO_OF_TRANSACTIONS=$2

[ -f ${ACCOUNT_SK} ] && ACCOUNT_SK=$(cat ${ACCOUNT_SK})

### HELPERS

waitNewBlockCreated() {
  COUNTER=${TIMEOUT_NO_OF_BLOCKS}
  echo "  ##Waiting for new block to be created (timeout = $COUNTER blocks = $((${COUNTER}*${SLOT_DURATION}))s)"
  initialTip=$(getTip)
  actualTip=$(getTip)

  while [ "${actualTip}" = "${initialTip}" ]; do
    sleep ${SLOT_DURATION}
    actualTip=$(getTip)
    COUNTER=$((COUNTER - 1))
    if [ ${COUNTER} -lt 2 ]; then
      echo " !!!!! ERROR: Waited $(($COUNTER * $SLOT_DURATION))s secs ($COUNTER*$SLOT_DURATION) and no new block created"
      exit 1
    fi
  done
  echo "New block was created - $(getTip)"
}

getAccountValue() {
    echo $($CLI rest v0 account get $1 | grep 'value: ' | awk -F'value: ' '{print $2}')
}

getNoOfMinedTransactions() {
    echo $($CLI rest v0 message logs | tr ' ' '\n' | grep 'InABlock:' | wc -l)
}

getTotalNoOfMesageLogs() {
    echo $($CLI rest v0 message logs | tr ' ' '\n' | grep 'fragment_id:' | wc -l)
}

compareBalances() {
    if [[ $1 == $2 ]]; then
      echo "  ###OK; Correct Balance; $1 = $2"
    else
      echo " !!!!! ERROR: Actual Balance is different than expected; Actual: $1  vs  Expected: $2"
      exit 2
    fi
}

sendMoney() {
    if [[ $# -ne 2 ]]; then
        echo "usage: $0 <DST_ADDRESS> <AMOUNT>"
        echo "    <DST_ADDRESS>   Address to send amount of money to"
        echo "    <AMOUNT>        Amount in lovelace"
        exit 1
    fi


    SOURCE_ADDRESS=$($CLI address account ${ADDRTYPE} ${SOURCE_PK})
    DESTINATION_ADDRESS="$1"
    DESTINATION_AMOUNT="$2"

    # Account 1 pays for the transaction fee
    TX_AMOUNT=$((${DESTINATION_AMOUNT} + ${FEE_CONSTANT} + $((2 * ${FEE_COEFFICIENT}))))

    STAGING_FILE="acc_staging.$$.transaction"

    # increase the SOURCE_COUNTER with TX_COUNTER_SAME_SLOT if Account1 initiates more than 1 transaction in the same slot
    # TX_COUNTER_SAME_SLOT = the number of transactions initiated and sent by Account1 in the same slot (based on TIP)
    ACTUAL_TIP=$(getTip)
    SRC_COUNTER=$( $CLI rest v0 account get "${SOURCE_ADDRESS}" | grep '^counter:' | sed -e 's/counter: //' )
#    echo "  ===== SRC_COUNTER: ${SRC_COUNTER}"

    if [[ ${ACTUAL_TIP} == ${INITIAL_TIP} ]]; then
#        echo "ACTUAL_TIP == INITIAL_TIP"
        if [[ ${SRC_COUNTER} -ne ${INITIAL_SRC_COUNTER} ]]; then
            echo "  == New block created after getting ACTUAL_TIP but before getting SRC_COUNTER"
            TX_COUNTER_SAME_SLOT=0
        else
            let TX_COUNTER_SAME_SLOT=TX_COUNTER_SAME_SLOT+1
        fi
    else
#        echo "ACTUAL_TIP != INITIAL_TIP"
        if [[ (${SRC_COUNTER} -ne ${INITIAL_SOURCE_COUNTER}) || (${TX_COUNTER_SAME_SLOT} == "aa") ]]; then
            TX_COUNTER_SAME_SLOT=0
        else
            TX_COUNTER_SAME_SLOT=1
        fi
        INITIAL_TIP=${ACTUAL_TIP}
    fi

    SOURCE_COUNTER=$((${SRC_COUNTER} + ${TX_COUNTER_SAME_SLOT}))
#    echo "  ===== SOURCE_COUNTER        : ${SOURCE_COUNTER}"
#    echo "  ===== TX_COUNTER_SAME_SLOT  : ${TX_COUNTER_SAME_SLOT}"

    INITIAL_SRC_COUNTER=${SRC_COUNTER}
    INITIAL_SOURCE_COUNTER=${SOURCE_COUNTER}
#    echo "  ===== INITIAL_SRC_COUNTER   : ${INITIAL_SRC_COUNTER}"
#    echo "  ===== INITIAL_SOURCE_COUNTER: ${INITIAL_SOURCE_COUNTER}"

    # Create the transaction
    $CLI transaction new --staging ${STAGING_FILE}
    $CLI transaction add-account "${SOURCE_ADDRESS}" "${TX_AMOUNT}" --staging "${STAGING_FILE}"
    $CLI transaction add-output "${DESTINATION_ADDRESS}" "${DESTINATION_AMOUNT}" --staging "${STAGING_FILE}"
    $CLI transaction finalize --staging ${STAGING_FILE}

    TRANSACTION_ID=$($CLI transaction data-for-witness --staging ${STAGING_FILE})

    # Create the witness for the 1 input (add-account) and add it
    SRC_WITNESS_SECRET_FILE="witness.secret.$$"
    SRC_WITNESS_OUTPUT_FILE="witness.out.$$"

    printf "${ACCOUNT_SK}" > ${SRC_WITNESS_SECRET_FILE}

    $CLI transaction make-witness ${TRANSACTION_ID} \
        --genesis-block-hash ${BLOCK0_HASH} \
        --type "account" --account-spending-counter "${SOURCE_COUNTER}" \
        ${SRC_WITNESS_OUTPUT_FILE} ${SRC_WITNESS_SECRET_FILE}
    $CLI transaction add-witness ${SRC_WITNESS_OUTPUT_FILE} --staging "${STAGING_FILE}"

    # Finalize the transaction and send it
    $CLI transaction seal --staging "${STAGING_FILE}"
    $CLI transaction to-message --staging "${STAGING_FILE}" | $CLI rest v0 message post

    rm ${STAGING_FILE} ${SRC_WITNESS_SECRET_FILE} ${SRC_WITNESS_OUTPUT_FILE}
}

######################## START TEST ########################
SOURCE_PK=$(echo ${ACCOUNT_SK} | $CLI key to-public)
SRC_ADDR=$($CLI address account ${ADDRTYPE} ${SOURCE_PK})

SRC_BALANCE_INIT=$(getAccountValue ${SRC_ADDR})
SOURCE_COUNTER=$( $CLI rest v0 account get "${SRC_ADDR}" | grep '^counter:' | sed -e 's/counter: //' )
if [[ ${SOURCE_COUNTER} -gt 0 ]]; then
    SRC_BALANCE_INIT=$(getAccountValue ${SRC_ADDR})dd
fi
echo "ACCOUNT_SK         : ${ACCOUNT_SK}"
echo "SOURCE_PK         : ${SOURCE_PK}"
echo "SRC_ADDR          : ${SRC_ADDR}"
echo "SRC_BALANCE_INIT  : ${SRC_BALANCE_INIT}"
echo "SOURCE_COUNTER    : ${SOURCE_COUNTER}"

echo "Create a destination Account address (RECEIVER_ADDR)"
DST_SK=$($CLI key generate --type=ed25519extended)
DST_PK=$(echo ${DST_SK} | $CLI key to-public)
DST_ADDR=$($CLI address account ${ADDRTYPE} ${DST_PK})
echo "DST_SK  : ${DST_SK}"
echo "DST_PK  : ${DST_PK}"
echo "DST_ADDR: ${DST_ADDR}"
DST_BALANCE_INIT=0

echo "read actual state of the message logs"
noOfMinedTxs_init=$(getNoOfMinedTransactions)
noOfTotalMessages_init=$(getTotalNoOfMesageLogs)

echo "noOfMinedTxs_init     : ${noOfMinedTxs_init}"
echo "noOfTotalMessages_init: ${noOfTotalMessages_init}"

##
# 1. create multiple transactions from Source to Destination Account and check balances at the end
##

BALANCE_HISTORY="balance_history.txt"

if [ -e ${BALANCE_HISTORY} ]; then
  rm ${BALANCE_HISTORY}
  touch ${BALANCE_HISTORY}
fi

SRC_BALANCE_INIT=$(getAccountValue ${SRC_ADDR})

echo "SRC_BALANCE_INIT: ${SRC_BALANCE_INIT}" >> ${BALANCE_HISTORY}
echo "DST_BALANCE_INIT: ${DST_BALANCE_INIT}" >> ${BALANCE_HISTORY}

SENT_VALUE=0
START_TIME="`date +%Y%m%d%H%M%S`";
for i in `seq 1 ${NO_OF_TRANSACTIONS}`;
do
    TX_VALUE=100
    echo "##Transaction No: ${BLUE}$i${WHITE}; Value: $TX_VALUE"
    sendMoney ${DST_ADDR} ${TX_VALUE}
    SENT_VALUE=$((${SENT_VALUE} + ${TX_VALUE}))
done

END_TIME1="`date +%Y%m%d%H%M%S`";

waitNewBlockCreated

END_TIME2="`date +%Y%m%d%H%M%S`";

echo "=================Check the message logs (after 1 block)=================="
noOfMinedTxs_final=$(getNoOfMinedTransactions)
noOfTotalMessages_final=$(getTotalNoOfMesageLogs)

echo "total txs sent in current test            : ${NO_OF_TRANSACTIONS}"
echo "total txs mined in current test           : $((${noOfMinedTxs_final} - ${noOfMinedTxs_init}))"
echo "total fragments created in current test   : $((${noOfTotalMessages_final} - ${noOfTotalMessages_init}))"
echo "total time for sending transactions       : $((${END_TIME1} - ${START_TIME})) seconds"
echo "total test time (waiting 1 new block)     : $((${END_TIME2} - ${START_TIME})) seconds"

echo "=================Check the message logs (after 2 blocks)=================="
waitNewBlockCreated
END_TIME3="`date +%Y%m%d%H%M%S`";

echo "total txs sent in current test            : ${NO_OF_TRANSACTIONS}"
echo "total txs mined in current test           : $((${noOfMinedTxs_final} - ${noOfMinedTxs_init}))"
echo "total fragments created in current test   : $((${noOfTotalMessages_final} - ${noOfTotalMessages_init}))"
echo "total time for sending transactions       : $((${END_TIME1} - ${START_TIME})) seconds"
echo "total test time (waiting 2 new blocks)    : $((${END_TIME3} - ${START_TIME})) seconds"

echo "=================Check Destination Account's balance=================="
SRC_BALANCE_FINAL=$(getAccountValue ${SRC_ADDR})
DST_BALANCE_FINAL=$(getAccountValue ${DST_ADDR})

echo "SRC_BALANCE_FINAL: ${SRC_BALANCE_FINAL}" >> ${BALANCE_HISTORY}
echo "DST_BALANCE_FINAL: ${DST_BALANCE_FINAL}" >> ${BALANCE_HISTORY}
echo "SRC_BALANCE_DIFF: $((${SRC_BALANCE_INIT} - ${SRC_BALANCE_FINAL}))" >> ${BALANCE_HISTORY}
echo "DST_BALANCE_DIFF: $((${DST_BALANCE_FINAL} - ${DST_BALANCE_INIT}))" >> ${BALANCE_HISTORY}

ACTUAL_DST_VALUE=$(getAccountValue ${DST_ADDR})
EXPECTED_DST_VALUE=$((${DST_BALANCE_INIT} + ${SENT_VALUE}))
compareBalances ${ACTUAL_DST_VALUE} ${EXPECTED_DST_VALUE}
