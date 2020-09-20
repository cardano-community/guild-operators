The delegates are the stake holders who have some funds deposited and want to participate in staking.
Therefore the steps for delegating stakes are the following:

- Create `stake key(s)` for generating the **delegate**'s `reward address(es)` for collecting their `stake rewards`.
- Create `payment key(s)` for generating the **delegate**'s `payment address(es)` for payments that will participate in stake delegation and also deposititing some funds.
- Register `stake address` on the blockhain, **with** key deposit, which is required for participation in staking, and
- Create and submit the **stake delegation certificate** for the selected pool.

#### Create _delegate's_ staking keys and addresses

A **stake address**, derived from a `stake verification key`, is a simple `reward (account) address` which is not a `payment address` therefore it cannot be used as an output of a transaction.
In the `cardano-cli` they use a CBOR format for preventing it to be added as the input into a transaction.

> Keep in mind, that only the **reward** addresses and the **base\_**, **pointer** and some **script** (not available yet) addresses can participate in the staking.

First, we need to create the relevant `payment` and `stake` keys and the related addresses for the delegate. The payment address will be used for paying the transactions for sending the `registration certificate` (which is just simply the reward account address in some CBOR encoded format) to the chain.

```bash
# Delegate's staking/acount key, then Staking/Account address
############################################################
mkdir delegate && pushd delegate

# Generate the stake address key-pair
cardano-cli shelley stake-address key-gen \
--verification-key-file stake.vkey \
--signing-key-file stake.skey

# Generate the actual stake address with the stake key-pair
cardano-cli shelley stake-address build \
--stake-verification-key-file stake.vkey \
--out-file stake.addr \
--mainnet

cat stake.addr
# stake1u9a3t4rgddm4expj0ucyxhxg3ft9ugk2ry6r9w69h04ea6cfj887f

# Generate the payment address key-pair
cardano-cli shelley address key-gen \
--verification-key-file payment.vkey \
--signing-key-file payment.skey
```

> **NOTE**: The following command use `--mainnet`. For testnet usage, use `--testnet-magic 1097911063` instead!

```bash
# Generate the Shelley address with both payment and stake keys

cardano-cli shelley address build \
--payment-verification-key-file payment.vkey \
--stake-verification-key-file stake.vkey \
--out-file payment.addr \
--mainnet # for testnet use, replace this with `--testnet-magic 1097911063`

cat payment.addr

# addr1q8mhchxehfs42erc33wdxrwvjalpc262tw4lus8dz30ts5tmzh2xs6mhtjvrylesgdwv3zjktc3v5xf5x2a5twltnm4s28w6nf

# Query the newly created address (need to export CARDANO_NODE_SOCKET_PATH first)

export CARDANO_NODE_SOCKET_PATH=path/to/your/node.socket (e.g. $CNODE_HOME/sockets/node0.socket)
cardano-cli shelley query utxo \
--address $(cat payment.addr) \
--mainnet

# TxHash TxIx Lovelace

#----------------------------------------------------------------------------------------

```

Now that we have our stake and Shelley addresses, we need to register our stake address on the blockchain.

> **NOTE**: to continue, you will need to have some ADA funds on the address to cover transaction costs!

#### Generating the Staking key certificate

```bash
# First we need to generate the stake address registration
# certificate using the stake verification key
############################################################
cardano-cli shelley stake-address registration-certificate \
    --stake-verification-key-file stake.vkey \
    --out-file stake.cert

cat stake.cert
# {
#     "type": "CertificateShelley",
#     "description": "Stake Address Registration Certificate",
#     "cborHex": "82008200581c7b15d4686b775c98327f30435cc88a565e22ca193432bb45bbeb9eeb"
# }

```

#### Registering the delegate's staking key on chain

The delegate's staking key needs to be registered in the blockchain. To register it we need to make a simple transaction including our `stake.cert` using any payment address.

Keep in mind that any stake key registration certificate needs a deposit for the costs of tracking the key and the corresponding reward account. Also, it does not require any witness to register the certificate, but only the witness for the fees from the input of the transaction.

```bash
# Get param files
export CARDANO_NODE_SOCKET_PATH=$CNODE_HOME/sockets/node0.socket
cardano-cli shelley query protocol-parameters \
--mainnet \
--out-file params.json

# CALCULATE TRANSACTION FEES + REGISTRATION KEY DEPOSIT
# You need only one signing key included in fee calculation:
# the `payment` address signing key of the input
# as the stake key reg cert does not need a witness

# Setup variables for building transactions:
FROM=$( cat payment.addr ) # the address we will pay the fees from
TX=$(cardano-cli shelley query utxo --mainnet --address "$FROM"  | grep "^[^- ]" | sort -k 2n | tail -1)
UTXO=$( echo "$TX" | awk '{ print $1 }')
ID=$( echo "$TX" | awk '{ print $2 }')
BALANCE=$( echo "$TX" | awk '{ print $3 }')
INPUT="${UTXO}#${ID}"

echo "$INPUT"
# 55be4bb91c6469ba419b102e703a5f20d1c022351e64cf75033f7d83c6aebbdc#0

# First, we need to build a draft transaction in order to calculate minimum fees
cardano-cli shelley transaction build-raw \
--tx-in "$INPUT" \
--tx-out $(cat payment.addr)+0 \
--ttl 0 \
--fee 0 \
--out-file tx.raw \
--certificate-file stake.cert


FEE=$(cardano-cli shelley transaction calculate-min-fee \
--tx-body-file tx.raw \
--tx-in-count 1 \
--tx-out-count 1 \
--witness-count 1 \
--byron-witness-count 0 \
--mainnet \
--protocol-params-file params.json \
| awk '{ print $1}')

echo "$FEE"

# 172453 - transaction fee in Lovelace

# Now, we need to get the registration fee - the "keyDeposit" specified in the protocol params.json
# This is the amount we can get back when we de-register the stake key

cat params.json | grep keyDeposit

# "keyDeposit": 2000000

KEYDEP=2000000

# Now we have everything needed to calculate the change:

CHANGE=$(( $BALANCE - $FEE - $KEYDEP ))

echo "$CHANGE"

# 2827547 <- 5000000 - 172453 - 2000000

OUTPUT="${FROM}+${CHANGE}"

# You can run the following to confirm all the variables are right
echo "Balance: $BALANCE, Change: $CHANGE, runTxCalculateMinFee: $FEE"
# Balance: 5000000, Change: 2827547, runTxCalculateMinFee: 172453
echo "Input: $INPUT"
# Input: 55be4bb91c6469ba419b102e703a5f20d1c022351e64cf75033f7d83c6aebbdc#0
echo "Output: $OUTPUT"
# Output: addr1q8mhchxehfs42erc33wdxrwvjalpc262tw4lus8dz30ts5tmzh2xs6mhtjvrylesgdwv3zjktc3v5xf5x2a5twltnm4s28w6nf+2827547


# Now, we need to determine the --ttl (time to Live) for the transaction. We query the blockchain tip and look for the 'slotNo':
cardano-cli shelley query tip --mainnet
# {
#     "blockNo": 4711506,
#     "headerHash": "1e95d9ebe29db6db8f8ae5ccf15351f41eddc8505716310c7471ff31b025878b",
#     "slotNo": 8967182 <- this is the tip we are looking for
# }

# Set TTL to be current tip + 500 (that gives us 500 seconds, ~ 8 minutes to complete the transaction)
TTL=$((8967182+500)) # **replace this accordingly with the current tip**

# Finally, build the transaction
cardano-cli shelley transaction build-raw \
    --tx-in "$INPUT" \
    --tx-out "${FROM}+${CHANGE}" \
    --ttl "$TTL" \
    --fee "$FEE" \
    --out-file tx.raw \
    --certificate-file stake.cert
# Sign it
cardano-cli shelley transaction sign \
    --tx-body-file tx.raw \
    --signing-key-file payment.skey \
    --signing-key-file stake.skey \
    --mainnet \
    --out-file tx.signed
# And submit it
cardano-cli shelley transaction submit \
    --tx-file tx.signed \
    --mainnet

# Your stake key will now be registered on the blockchain once the transaction goes through.
# Now, we are ready to delegate.
```

#### Create a delegation certificate and submit to the network

To delegate to a pool, we need to create a delegation certificate using our `stake.vkey` and the stake pool's details. We will then submit this certificate to the network in a transaction much like we registered our staking address.

```bash
# You will need either a stake pool's cold.vkey or a stake pool's ID
POOL_ID=5271fc86fd9c25613c138c4aef6f8593b2952c95897b079facebbc9e

# !! BE AWARE!! that the `stake.key` must be already registered on the chain at this point.
cardano-cli shelley stake-address delegation-certificate \
    --stake-verification-key-file stake.vkey \
    --stake-pool-id "$POOL_ID" \
    --out-file delegation.cert

####################################################################
####################################################################

# Calculate the minimum fee. Again, we build a draft transaction, but we need to update our variables beforehand.
TX=$(cardano-cli shelley query utxo --mainnet --address "$FROM"  | grep "^[^- ]" | sort -k 2n | tail -1)
UTXO=$( echo "$TX" | awk '{ print $1 }')
ID=$( echo "$TX" | awk '{ print $2 }')
BALANCE=$( echo "$TX" | awk '{ print $3 }')
INPUT="${UTXO}#${ID}"

echo "$INPUT"
# 21190c4dd72173e5b78c0c766379e97339fa2f5fa96a47fc1c2db45605fb7e5e#0

cardano-cli shelley transaction build-raw \
--tx-in "$INPUT" \
--tx-out $(cat payment.addr)+0 \
--ttl 0 \
--fee 0 \
--out-file tx.raw \
--certificate-file delegation.cert


FEE=$(cardano-cli shelley transaction calculate-min-fee \
--tx-body-file tx.raw \
--tx-in-count 1 \
--tx-out-count 1 \
--witness-count 1 \
--byron-witness-count 0 \
--mainnet \
--protocol-params-file params.json \
| awk '{ print $1}')

echo "$FEE"

# 172453 - transaction fee in Lovelace

CHANGE=$(( $BALANCE - $FEE))
OUTPUT="${FROM}+${CHANGE}"

# Determine TTL:
cardano-cli shelley query tip --mainnet
# {
#     "blockNo": 4711631,
#     "headerHash": "253570b12db0f6810d2a9f62ef79f7d5101a8f5de3743b26a0257b0e2c0290a7",
#     "slotNo": 8969917
# }


# Set TTL to be current tip + 500 (that gives us 500 seconds, ~ 8 minutes to complete the transaction)
TTL=$((8969917+500)) # **replace this accordingly with the current tip**

# Build the transaction
cardano-cli shelley transaction build-raw \
     --tx-in "$INPUT" \
     --tx-out "$OUTPUT" \
     --ttl "$TTL" \
     --fee "$FEE" \
     --out-file delegation.raw \
     --certificate-file delegation.cert

# Sign
# You need 2 signing keys
# 1. the `payment.skey` for wittness the input and
# 2. the `stake.skey` for signing the delegation certificate.
cardano-cli shelley transaction sign \
    --tx-body-file delegation.raw \
    --signing-key-file stake.skey \
    --signing-key-file payment.skey \
    --mainnet \
    --out-file delegation.signed

# Before

# Submit:
cardano-cli shelley transaction submit \
    --tx-file delegation.signed \
    --mainnet

# Delegation done, you need to wait two epochs before your delegation becomes active and 4 epochs to start receiving rewards.
# To confirm, you can query your address to make sure the transaction went through.

cardano-cli shelley query utxo --mainnet --address $(cat payment.addr)
#                           TxHash                                 TxIx        Lovelace
# ----------------------------------------------------------------------------------------
# 0bcdf4f6378b2183d738b17c8a2daa6a94f0ddf78133b73fccea0eece3ab1b56     0           2653774 <- change from the last transaction

```
