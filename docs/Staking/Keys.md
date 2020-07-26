Keys are just simply asymmetric cryptography key pairs (private/public, signing/verifying) that are used for signing and validating payments and staking related certificates and identifying, defining addresses on the Cardano blockchain.

#### Key Types and their functions {docsify-ignore}

As it can be seen in the picture there are two main type of keys in Shelley:
- __Node keys__ and
- __Address keys__.

The node keys are relevant to the security of the blockchain while the address keys are relevant to the functions of the addresses derived from the keys for identifying funds on the blockchain.
See details below and above in the picture.

1. Node Keys
    - Operator/operational key: operator's offline key pair with cert counter for new certificates. 
    - Hot KES key: operator's hot KES key pair.
    - Block signing key: operational VRF key pair, it participates in the "lottery" i.e. right to create and sign the block for the specific slot.
2. Address (Payment, Staking etc.) keys
    - Payment key: single address key pair (usually for generating UtxO addresses)
    - Staking key: stake/reward address key pair (usually generating account/reward addresses)
