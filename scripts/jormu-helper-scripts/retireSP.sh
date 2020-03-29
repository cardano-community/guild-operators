#!/bin/sh

# Disclaimer:
#
#  The following use of shell script is for demonstration and understanding
#  only, it should *NOT* be used at scale or for any sort of serious
#  deployment, and is solely used for learning how the node and blockchain
#  works, and how to interact with everything.
#
# Scenario:
#   Configure 1 stake pool having as owner the provided account address (secret key)
#
#  Tutorials can be found here: https://github.com/input-output-hk/shelley-testnet/wiki

. $(dirname $0)/env

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

if [ "$1" = "--help" ] || [ $# -lt 1 ]; then
    echo ""
    echo "usage: $0 <ACCOUNT_SK> <POOL_ID> [<RETIRE_IN_EPOCH>]"
    echo "    <ACCOUNT_SK>       The Secret key of the Source address"
    echo "    <POOL_ID>          Stake Pool ID"
    echo "    <RETIRE_IN_EPOCH>  Number of epochs from execution after you would like to retire your pool (this is to avoid calculating/formatting while execution)"
    echo ""
    exit 1
fi

ACCOUNT_SK=$1
POOL_ID=$2
[ ! -z "$3" ] && RETIREMENT_TIME="--retirement-time $(( $3 * $SLOT_DURATION * $SLOTS_PER_EPOCH ))"

[ -f ${ACCOUNT_SK} ] && ACCOUNT_SK=$(cat ${ACCOUNT_SK})

ACCOUNT_PK=$(echo ${ACCOUNT_SK} | $CLI key to-public)
ACCOUNT_ADDR=$($CLI address account ${ADDRTYPE} ${ACCOUNT_PK})

echo "================Create Stake Pool================="
echo "REST_URL: ${JORMUNGANDR_RESTAPI_URL}"
echo "ACCOUNT_SK: ${ACCOUNT_SK}"
echo "BLOCK0_HASH: ${BLOCK0_HASH}"
echo "FEE_CONSTANT: ${FEE_CONSTANT}"
echo "FEE_COEFFICIENT: ${FEE_COEFFICIENT}"
echo "FEE_CERTIFICATE: ${FEE_CERTIFICATE}"
echo "=================================================="

echo " ##3. Create the Stake Pool Retirement certificate using private key and pool ID with retirement time"
$CLI certificate new stake-pool-retirement --pool-id ${POOL_ID} ${RETIREMENT_TIME} stake_pool_retirement.cert
echo " ##4. Send the signed Stake Pool certificate to the blockchain"

STAGING_FILE="tx$$.staging"

#CLI transaction
if [ -f "${STAGING_FILE}" ]; then
    echo "error: staging already exists. restart"
    exit 2
fi

set -e

ACCOUNT_PK=$(echo ${ACCOUNT_SK} | $CLI key to-public)
ACCOUNT_ADDR=$($CLI address account ${ADDRTYPE} ${ACCOUNT_PK})

# TODO we should do this in one call to increase the atomicity, but otherwise
ACCOUNT_COUNTER=$( $CLI rest v0 account get "${ACCOUNT_ADDR}" | grep '^counter:' | sed -e 's/counter: //' )

# the account is going to pay for the fee ... so calculate how much
ACCOUNT_AMOUNT=$((${FEE_CONSTANT} + ${FEE_COEFFICIENT} + ${FEE_CERTIFICATE}))

# Create the transaction
# FROM: ACCOUNT for FEES
echo " ##4.1 Create the offline transaction file"
$CLI transaction new --staging ${STAGING_FILE}

echo " ##4.2 Add the Account to the transaction"
$CLI transaction add-account "${ACCOUNT_ADDR}" "${ACCOUNT_AMOUNT}" --staging "${STAGING_FILE}"

echo " ##4.3 Add the certificate to the transaction"
$CLI transaction add-certificate --staging ${STAGING_FILE} $(cat stake_pool_retirement.cert)

echo " ##4.4 Finalize the transaction"
$CLI transaction finalize --staging ${STAGING_FILE}

TRANSACTION_ID=$($CLI transaction data-for-witness --staging ${STAGING_FILE})

# Create the witness for the 1 input (add-account) and add it
WITNESS_SECRET_FILE="witness.secret.$$.tmp"
WITNESS_OUTPUT_FILE="witness.out.$$.tmp"

printf "${ACCOUNT_SK}" > ${WITNESS_SECRET_FILE}

echo " ##4.5. Make the witness"
$CLI transaction make-witness ${TRANSACTION_ID} \
    --genesis-block-hash ${BLOCK0_HASH} \
    --type "account" --account-spending-counter "${ACCOUNT_COUNTER}" \
    ${WITNESS_OUTPUT_FILE} ${WITNESS_SECRET_FILE}

echo " ##4.6. Add the witness to the transaction"
$CLI transaction add-witness ${WITNESS_OUTPUT_FILE} --staging "${STAGING_FILE}"

echo " ##4.7. Show the transaction info"
$CLI transaction info --fee-constant ${FEE_CONSTANT} --fee-coefficient ${FEE_COEFFICIENT} --fee-certificate ${FEE_CERTIFICATE} --staging "${STAGING_FILE}"

echo " ##4.8. Finalize the transaction and send it to the blockchain"
$CLI transaction seal --staging "${STAGING_FILE}"
$CLI transaction auth -k ${WITNESS_SECRET_FILE} --staging "${STAGING_FILE}"
$CLI transaction to-message --staging "${STAGING_FILE}" | $CLI rest v0 message post

echo " ##4.9. Remove the temporary files"
rm ${STAGING_FILE} ${WITNESS_SECRET_FILE} ${WITNESS_OUTPUT_FILE}

waitNewBlockCreated

exit 0

