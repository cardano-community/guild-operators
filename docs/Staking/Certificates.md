
Shelley's PoS protocol requires different certificates posted to the blockhain; which will be publicly available for all participants. Those are valid until explicitly overwritten or revoked.

There are four main type of certificates in Shelley:
1. Operational key certificates (__off chain__),
2. Stake Key registration certificates (__on chain__),
3. Delegation certificates (__on chain__) and
4. Stake pool certificates (__on chain__).

### Operational key certificates

The `operational key certificate`'s is created from a `staking key`
used by stake pool operators for protecting their pool(s) and keys, signing bocke, participating in the lottery and not for delegating staking rights.
This certificate needs for operating a node as a stake pool. 

See [detailed example here](Staking/Operators.md#run-a-node-with-operational-key-certificate)


### Stake Key registration certificates

All participants, who want to participate in staking, need to register a __stake key__ on the blockchain by posting a __stake key registration certificate__. The registration requires a key deposit specified in the genesis (400K lovelace for FnF), but do not require any `signature` signed by the corresponding `stake signing key`.

The registration is revoked when a de-registration certificate signed by the account's `stake signing key` is posted to the blockchain, causing the account to be deleted (__Ask what is the impact of this__).

See [detailed example here](Staking/Operators.md#create-stake-key-registration-certificate)

### Delegation certificates

Delegation certificates uses a `staking key` to grant the right to sign blocks to another key. 

See [detailed example here](Staking/Operators.md#create-the-stake-owners-delegation-certificate)

### Stake pool certificates

A node for operating as a stake pool must post a `stake pool registration certificate` signed by all the owners' `staking signing key` and the pool operator's `operational signing key`. 

To revoke the certificate a `stake pool retirement certificate` must be posted to the chain signed by __only__ the pool's `operational signing key`.

No owner(s) is/are required to sign the retirement certificate.

See [detailed example here](Staking/Operators.md#run-a-node-with-operational-key-certificate)


