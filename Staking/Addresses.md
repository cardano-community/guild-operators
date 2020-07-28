The addresses, as of now, are just a simple `blake2b-256` hash of the relevant veryifying/public keys contatenated with some metadata that are or can be stored on the `Cardano` blockchain. 

> Addresses in this context are only relevant to the ledger specification and not to any wallet addresses.
> So, the wallets `m/44'/1852'/0'/{0,1,2}` `bech32` addresses (e.g. `ca1hg9...`) are irrelevant here.

Currently there are three main type of addresses and a reserved _address space_ for future use:
1. __Payment addresses__: 
    - base addresses (can participate in staking, a.k.a goup addresses in ITN jorm terminology)
    - pointer addresses (need to check whether it can or cannot participate in staking)
    - enterprise addresses (cannot participate in staking a.k.a UtxO address)
2. __Reward addresses__: Reward/account addresses (can participate in staking)
3. __Byron addresses__: The legacy addresses, for backward compatibility (cannot participate in staking)
4. __Future addresses__: possible 5 main /w 16 subtypes or 80 additional address types)

Therefore addresses, in Cardano Shelley (only in Haskell code), are some serialised data specified in the ledger specification that are stored in the blockhain's blocks (e.g. an UtxO address).

The serialised data (address) contains two parts the __metadata__ and __payload__ (i.e. `address = metadata + payload`): 
- metadata: is for interpreting the
- payload: the raw or encoded bytes. For example the verifying/public keys or their hashes or even scripts (e.g. plutus smart contract) hashes.

_Therefore, in layman definition (by removing some complexity for easy understanding): 
**Addresses are serialised public/verifying keys**_ 

See,the [detailed address specification here](https://github.com/input-output-hk/cardano-ledger-specs/blob/master/shelley/chain-and-ledger/executable-spec/cddl-files/shelley.cddl#L66).

> Pls, keep in mind, that it does not mean that the specification is currently is used, implemented and/or finalised.

