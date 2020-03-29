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
    echo "usage: $0 <ACCOUNT_SK> [<TAX_RATIO> <TAX_VALUE> <TAX_LIMIT>]"
    echo "    <ACCOUNT_SK>  The Secret key of the Source address"
    echo "    <TAX_RATIO>   The ratio of the remaining value that will be taken from the total, eg: For a value of 10%, the value could be \"1/10\"."
    echo "    <TAX_VALUE>   The fixed cut (in lovelaces) the stake pool will take from the total reward."
    echo "    <TAX_LIMIT>   The value in lovelaces that will be used to limit the pool's tax."
    echo ""
    echo "examples:"
    echo "    Specifying all parameters: $0 ed25519e_sk1... \"1/10\" 10 100"
    echo "    Specifying only Tax Ratio: $0 ed25519e_sk1... \"1/10\" "
    echo ""
    exit 1
fi

ACCOUNT_SK=$1
[ ! -z "$2" ] && TAX_RATIO="--tax-ratio $2"
[ ! -z "$3" ] && TAX_VALUE="--tax-fixed $3"
[ ! -z "$4" ] && TAX_LIMIT="--tax-limit $4"

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

echo " ##1. Create VRF keys"
POOL_VRF_SK=$($CLI key generate --type=Curve25519_2HashDH)
POOL_VRF_PK=$(echo ${POOL_VRF_SK} | $CLI key to-public)

echo POOL_VRF_SK: ${POOL_VRF_SK}
echo POOL_VRF_PK: ${POOL_VRF_PK}

echo " ##2. Create KES keys"
POOL_KES_SK=$($CLI key generate --type=SumEd25519_12)
POOL_KES_PK=$(echo ${POOL_KES_SK} | $CLI key to-public)

echo POOL_KES_SK: ${POOL_KES_SK}
echo POOL_KES_PK: ${POOL_KES_PK}

echo " ##3. Create the Stake Pool certificate using above VRF and KEY public keys"
$CLI certificate new stake-pool-registration --kes-key ${POOL_KES_PK} --vrf-key ${POOL_VRF_PK} --owner ${ACCOUNT_PK} --start-validity 0 ${TAX_VALUE} ${TAX_RATIO} ${TAX_LIMIT} --management-threshold 1 >stake_pool.cert

echo " ##4. Sign the Stake Pool certificate with the Stake Pool Owner private key"
echo ${ACCOUNT_SK} > stake_key.sk

cat stake_pool.cert | $CLI certificate sign -k stake_key.sk >stake_pool.signcert

cat stake_pool.signcert

echo " ##5. Send the signed Stake Pool certificate to the blockchain"
${SCRIPTPATH}/register-pool-cert.sh ${ACCOUNT_SK} stake_pool.cert

echo " ##6. Retrieve your stake pool id"
cat stake_pool.cert | $CLI certificate get-stake-pool-id | tee stake_pool.id

POOL_ID=$(cat stake_pool.id)

echo "The Pool ID is: ${POOL_ID}"

echo " ##7. Creating the node_secret.yaml file"
#define the template.
cat > node_secret.yaml << EOF
genesis:
  sig_key: ${POOL_KES_SK}
  vrf_key: ${POOL_VRF_SK}
  node_id: ${POOL_ID}
EOF
