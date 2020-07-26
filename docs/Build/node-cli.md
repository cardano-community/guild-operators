### Cardano Node and Cardano CLI

Ensure the [Pre-Requisites](../Common.md#dependencies-and-folder-structure-setup) are in place before you proceed.

#### Build Instructions

Run the commands below to clone the Cardano Node git repository and build the binaries:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-node
cd cardano-node

##### Temporary step for end-users, since master is often broken incompatible with new networks
git fetch --tags --all
git checkout 1.18.0
#####

### Please ensure you have run the *UPDATED* prereqs.sh (see link at top of this document) before continuing
echo -e "package cardano-crypto-praos\n  flags: -external-libsodium-vrf" > cabal.project.local
$CNODE_HOME/scripts/cabal-build-all.sh
```

The above would copy the binaries built into ~/.cabal/bin folder.

#### Verify

Execute cardano-cli and cardano-node to verify output as below:

```bash
cardano-cli version
# cardano-cli 1.17.0 - linux-x86_64 - ghc-8.6
cardano-node
#Usage: cardano-node (run | run-mock) [--help]
#  Start node of the Cardano blockchain.
#
#Available options:
#  --help                   Show this help text
#
#Execute node with a real protocol.
#  run                      Execute node with a real protocol.
#
#Execute node with a mock protocol.
#  run-mock                 Execute node with a mock protocol.
