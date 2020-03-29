#!/bin/sh

# Disclaimer:
#
#  The following use of shell script is for demonstration and understanding
#  only, it should *NOT* be used at scale or for any sort of serious
#  deployment, and is solely used for learning how the node and blockchain
#  works, and how to interact with everything.
#
#  Tutorials can be found here: https://github.com/input-output-hk/shelley-testnet/wiki

. $(dirname $0)/env

if [ "$1" = "--help" ] || [ $# -ne 2 ]; then
    echo "usage: $0 <ACCOUNT-SOURCE-SK> <CERTIFICATE-PATH>"
    echo "    <ACCOUNT-SOURCE-SK>   The Secret key of the Source address"
    echo "    <CERT-PATH>   Path to a readable certificate file"
    exit 1
fi

ACCOUNT_SK="$1"
CERTIFICATE_PATH="$2"
[ -f ${ACCOUNT_SK} ] && ACCOUNT_SK=$(cat ${ACCOUNT_SK})

FEE_CERTIFICATE=$($CLI rest v0 settings get | grep 'certificate_pool_registration:' | sed -e 's/^[[:space:]]*//' | sed -e 's/certificate_pool_registration: //')

echo "===============Send Certificate================="
echo "CERTIFICATE_PATH: ${CERTIFICATE_PATH}"
echo "REST_URL: ${JORMUNGANDR_RESTAPI_URL}"
echo "ACCOUNT_SK: ${ACCOUNT_SK}"
echo "BLOCK0_HASH: ${BLOCK0_HASH}"
echo "FEE_CONSTANT: ${FEE_CONSTANT}"
echo "FEE_COEFFICIENT: ${FEE_COEFFICIENT}"
echo "FEE_CERTIFICATE: ${FEE_CERTIFICATE}"
echo "=================================================="

STAGING_FILE="staging.$$.transaction"

if [ ! -r ${CERTIFICATE_PATH} ]; then
    echo "certificate file does not exist or is not readable"
    usage ${0}
    exit 1
fi

#CLI transaction
if [ -f "${STAGING_FILE}" ]; then
    echo "error: staging already exist. restart"
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
echo " ##1. Create the offline transaction file"
$CLI transaction new --staging ${STAGING_FILE}

echo " ##2. Add the Account to the transaction"
$CLI transaction add-account "${ACCOUNT_ADDR}" "${ACCOUNT_AMOUNT}" --staging "${STAGING_FILE}"

echo " ##3. Add the certificate to the transaction"
$CLI transaction add-certificate --staging ${STAGING_FILE} $(cat ${CERTIFICATE_PATH})

echo " ##4. Finalize the transaction"
$CLI transaction finalize --staging ${STAGING_FILE}

TRANSACTION_ID=$($CLI transaction data-for-witness --staging ${STAGING_FILE})

# Create the witness for the 1 input (add-account) and add it
WITNESS_SECRET_FILE="witness.secret.$$"
WITNESS_OUTPUT_FILE="witness.out.$$"

printf "${ACCOUNT_SK}" > ${WITNESS_SECRET_FILE}

echo " ##5. Make the witness"
$CLI transaction make-witness ${TRANSACTION_ID} \
    --genesis-block-hash ${BLOCK0_HASH} \
    --type "account" --account-spending-counter "${ACCOUNT_COUNTER}" \
    ${WITNESS_OUTPUT_FILE} ${WITNESS_SECRET_FILE}

echo " ##6. Add the witness to the transaction"
$CLI transaction add-witness ${WITNESS_OUTPUT_FILE} --staging "${STAGING_FILE}"

echo " ##7. Show the transaction info"
$CLI transaction info --fee-constant ${FEE_CONSTANT} --fee-coefficient ${FEE_COEFFICIENT} --fee-certificate ${FEE_CERTIFICATE} --staging "${STAGING_FILE}"

echo " ##8. Finalize the transaction and send it to the blockchain"
$CLI transaction seal --staging "${STAGING_FILE}"
$CLI transaction auth -k ${WITNESS_SECRET_FILE} --staging "${STAGING_FILE}" 
$CLI transaction to-message --staging "${STAGING_FILE}" | $CLI rest v0 message post

echo " ##9. Remove the temporary files"
rm ${STAGING_FILE} ${WITNESS_SECRET_FILE} ${WITNESS_OUTPUT_FILE}

waitNewBlockCreated

exit 0
