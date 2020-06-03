### Delegates

The delegates are the stake holders who have some funds deposited and want to participate in staking.
Therefore the steps for delegating stakes are the following:
  - Create `stake key(s)` for generating the __delegate__'s `reward address(es)` for collecting their `stake rewards`.
  - Create `payment key(s)` for generating the __delegate__'s `payment address(es)` for payments that will participate in stake delegation and also deposititing some funds.
  - Register `stake address` on the blockhain, __with__ key deposit, which is required for participatin in staking and 
  - Create and submit the __stake delegation certificate__ for the selected pool.

#### Create _delegate's_ staking keys and addresses

Stake address, derived from a `stake verification key`, is a simple `reward (account) address` which is not a `payment address` therefore it cannot be used as an output of a transaction.
In the `cardano-cli` they use a CBOR format for preventing it to be added as the input into a transaction.

> Keep in mind, that only the __reward__ addresses and the __base___, __pointer__ and some __script__ (not available yet) addresses can participate in the staking.

First, we need to create the relevant `payment` and `stake` keys and the related addresses for the delegate. The payment address for paying the transactions for sending the `registration certificate` (which is just simply the reward account address in some CBOR encoded format) to the chain.

``` bash
# Delegate's staking/acount key, then Staking/Account address
############################################################
mkdir delegate && pushd delegate
cardano-cli shelley stake-address key-gen --verification-key-file stake.vkey --signing-key-file stake.skey

cardano-cli shelley stake-address build --stake-verification-key-file stake.vkey --testnet-magic 42 > stake.addr
cat stake.addr
#-------v 32 bytes key starts from here
8200582032a8c3f17ae5dafc3e947f82b0b418483f0a8680def9418c87397f2bd3d35efb
# It's a CBOR representation of the vkey
#82                                      # array(2)
#   00                                   # unsigned(0)
#   58 20                                # bytes(32)
#      32A8C3F17AE5DAFC3E947F82B0B418483F0A8680DEF9418C87397F2BD3D35EFB # 
# "2\xA8\xC3\xF1z\xE5\xDA\xFC>\x94\x7F\x82\xB0\xB4\x18H?\n\x86\x80\xDE\xF9A\x8C\x879\x7F+\xD3\xD3^\xFB"


# Delegates payment key -> payment address (a.k.a legacy UtxO a.k.a enterprise address).
# Ur use some address that already has some fund on it.
############################################################
cardano-cli shelley address build --payment-verification-key-file pay.vkey --testnet-magic 42 > pay.addr
cat pay.addr
# As a single Shelley UtXO address and (no CBOR repr)
# header(1) | address(32), so no hash224
# 0x61 = 0110 0001 || 0x47eb...2907 therefore an UtXO enterprise address
6147ebc8bf8714dcf6700ac482a5d42624ffca6afb51ae23930ea6591119a12907

####################################################################
# Generate the delegate's base address (0x01...) from 
# 1. the `pay.vkey` (used for enterprise address `0x61...`)
# 2. and from the `stake.key`
# It's a combination of the payment and reward address, with
# the 0b0000 0b0001, as a base address prefix
####################################################################
cardano-cli shelley address build \
    --payment-verification-key-file pay.vkey \
    --stake-verification-key-file stake.vkey \
    --testnet-magic 42 > stake.base
```

#### Generating the Staking key certificate

``` bash
# First we need to generate the stake address registration
# certificate using the stake verification key
############################################################
cardano-cli shelley stake-address registration-certificate \
--stake-verification-key-file stake.vkey \
--out-file stake.cert

cat stake.cert
cbor-hex:
 18b482008200582032a8c3f17ae5dafc3e947f82b0b418483f0a8680def9418c87397f2bd3d35efb
# 18 B4 # unsigned(180)
# 
#82                                      # array(2)
#   00                                   # unsigned(0)
#   82                                   # array(2)
#      00                                # unsigned(0)
#      58 20                             # bytes(32)
#         32A8C3F17AE5DAFC3E947F82B0B418483F0A8680DEF9418C87397F2BD3D35EFB  
# "2\xA8\xC3\xF1z\xE5\xDA\xFC>\x94\x7F\x82\xB0\xB4\x18H?\n\x86\x80\xDE\xF9A\x8C\x879\x7F+\xD3\xD3^\xFB"
```

#### Registering the delegate's staking key on chain

The delegate's staking key needs to be registered in the blockchain, which just need a simple transaction using any payment address.

Keep, in mind that the any stake key registration certificates needs a deposit for the costs of tracking the key and the corresponding reward account. Also, it does not require any witness to register the certificate, but only the witness for the fees from the input of the transaction.


``` bash
# Get param files
export CARDANO_NODE_SOCKET_PATH=$CNODE_HOME/sockets/node0.socket
cardano-cli shelley query protocol-parameters \
--testnet-magic 42 \
--out-file params.json

# 3. Calc tx fee
# You need only one singing keys included in fee calculation:
# 1. the `payment` address signing key of the input
# as the stake key reg cert does not need witness
# One UtxO is enough for the change, but I will move some fund from genesis to the delegates address
FEE=$(cardano-cli shelley transaction calculate-min-fee \
--protocol-params-file params.json \
--certificate-file stake.cert \
--tx-in-count 1 \
--tx-out-count 2 \
--ttl 500000 \
--testnet-magic 42 \
--signing-key-file $CNODE_HOME/priv/genesis.skey \
| awk '{ print $2}')

# I will use the the genesis address as input for paying the fee.
#################################################################
FROM=$( cat $CNODE_HOME/priv/genesis.addr )
# i.e. FROM=617190446876aed298ee207c6b5a335e832e2169a060b8167ef3ba9caff6fa3393


TX=$(cardano-cli shelley query utxo --testnet-magic 42 --address "$FROM"  | grep "^[^- ]" | sort -k 2n | tail -1)
UTXO=$( echo "$TX" | awk '{ print $1 }')
ID=$( echo "$TX" | awk '{ print $2 }')
BALANCE=$( echo "$TX" | awk '{ print $3 }')
INPUT="${UTXO}#${ID}"

# This 500K ADA amount is going to the delegates UtxO style address for its delegated stakes
TO=$(cat pay.addr)
AMOUNT=500000000000

OUTPUT1="${FROM}+${CHANGE}"
OUTPUT2="${TO}+${AMOUNT}"
# It also needs a key deposit specified in the genesis e.g.
# grep keyD
#    "keyDeposit": 400000,
#    "keyDecayRate": 0, Means the key won't decay, i.e. all money will
# get back when  the key is de-registered from the chain
KEYDEP=400000

# This means that change will less by 400K Lovelace that will be 
# probably (need to check) taken by the treasury 
CHANGE=$(( $BALANCE -  $FEE - $AMOUNT - $KEYDEP ))

echo "Balance: $BALANCE, Amount: "$AMOUNT",  Change: $CHANGE, runTxCalculateMinFee: $FEE"
echo "Input  : $INPUT"
echo "Output1: $OUTPUT1"
echo "Output2: $OUTPUT2"

# Build
cardano-cli shelley transaction build-raw \
	--tx-in "$INPUT" \
	--tx-out "${FROM}+${CHANGE}" \
	--tx-out "${TO}+${AMOUNT}" \
	--ttl 500000 \
	--fee "$FEE" \
	--out-file stake-cert-tx
# Sign
cardano-cli shelley transaction sign \
    --tx-body-file stake-cert-tx \
    --signing-key-file $CNODE_HOME/priv/genesis.skey \
    --signing-key-file stake.skey \
    --out-file stake-cert-tx \
    --testnet-magic 42

# Submit
# Wait some minutes
# Get the stake address
# cut -c 9-  stake.addr 
# 32a8c3f17ae5dafc3e947f82b0b418483f0a8680def9418c87397f2bd3d35efb
STAKE_ADDR=$( cut -c 9-  stake.addr )

# Before 
export CARDANO_NODE_SOCKET_PATH=$CNODE_HOME/sockets/node0.socket 
cardano-cli shelley query ledger-state  --testnet-magic 42 | grep "$STAKE_ADDR"


cardano-cli shelley transaction submit \
    --tx-file signed-stake-key-registration.tx \
    --testnet-magic 42

# After 
cardano-cli shelley query ledger-state  --testnet-magic 42 | grep "$STAKE_ADDR"
#                        "contents": "32a8c3f17ae5dafc3e947f82b0b418483f0a8680def9418c87397f2bd3d35efb"
#                        "contents": "32a8c3f17ae5dafc3e947f82b0b418483f0a8680def9418c87397f2bd3d35efb"
#                        "contents": "32a8c3f17ae5dafc3e947f82b0b418483f0a8680def9418c87397f2bd3d35efb"

# Ready to delegate now.
```

#### Create a delegation certificate and submit to the network

``` bash
# You can use aither some pool from the google's spreadsheet 
echo "type: Node operator verification key
title: Stake pool operator key
cbor-hex:
 5820<the 32 bytes length of the pool's operational verification key from the google sheet without the 5820 CBOR tag.>
 " > pool.vkey

# or delegate to your own pool by getting its `operational verifycation key` (the cold key)
# !! BE AWARE!! that the `stake.key` must have been already registered on the chain.
cardano-cli shelley stake-address delegation-certificate \
    --stake-verification-key-file stake.vkey \
    --cold-verification-key-file ~/cold-keys/pool.vkey \
    --out-file pool-delegation.cert

####################################################################
####################################################################

# Calculate the minimum fee.
cardano-cli shelley transaction calculate-min-fee \
    --tx-in-count 1 \
    --tx-out-count 1 \
    --ttl 500000 \
    --testnet-magic 42 \
    --signing-key-file pay.skey \
    --signing-key-file stake.skey \
    --certificate-file pool-delegation.cert \
    --protocol-params-file params.json
# runTxCalculateMinFee: 172805
FEE=172805
# Get the intput and balance
cardano-cli shelley query utxo --testnet-magic 42 --address $(cat stake.base)
#                           TxHash                                 TxIx        Lovelace
#----------------------------------------------------------------------------------------
#1c089abfd6d56c73ac57aa94c403991041a383956f1f8fd4141a8e03a678a24c     0      499999260330

INPUT="1c089abfd6d56c73ac57aa94c403991041a383956f1f8fd4141a8e03a678a24c#0"
BAL=499999260330
CHANGE=$(( $BAL - $FEE))
# The new `base address`
OUTPUT="$( cat stake.base)+$CHANGE"

# Build
# Input: Your `base` payment address e.g. `stake.base` with "0x01...."
# Output: change back to the base address.
cardano-cli shelley transaction build-raw \
     --tx-in "$INPUT" \
     --tx-out "$OUTPUT" \
     --ttl 500000 \
     --fee "$FEE" \
     --out-file pool-delegation.tx \
     --certificate-file pool-delegation.cert

# Sign
# You need 2 signing keys
# 1. the `pay.skey` for wittness the input and
# 2. the `staking signing key` for signing the delegation certificate.
cardano-cli shelley transaction sign \
    --tx-body-file pool-delegation.tx \
    --signing-key-file stake.skey \
    --signing-key-file pay.skey \
    --testnet-magic 42 \
    --out-file signed-pool-delegation.tx

# Before

# Submit:
cardano-cli shelley transaction submit \
    --tx-file signed-pool-delegation.tx \
    --testnet-magic 42

# Done As less money is there.
# you need to wait two epochs to be receiving rewards
cardano-cli shelley query utxo --testnet-magic 42 --address $(cat stake.base)
#                           TxHash                                 TxIx        Lovelace
#----------------------------------------------------------------------------------------
#ba544d056f94e559076c0c7a0406f37ed7182a6d0fdc0cf2569498353f9dd797     0      499999087525

```
