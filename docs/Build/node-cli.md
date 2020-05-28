### Cardano Node and Cardano CLI

Ensure the [Pre-Requisites](../Common.md#dependencies-and-folder-structure-setup) are in place before you proceed.

#### Build Instructions

Run the commands below to clone the Cardano Node git repository and build the binaries:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-node
cd cardano-node
$CNODE_HOME/scripts/cabal-build-all.sh
```

The above would copy the binaries built into ~/.cabal/bin folder.

#### Verify

Execute cardano-cli and cardano-node to verify output as below:

```bash
cardano-cli version
# cardano-cli 1.11.0 - linux-x86_64 - ghc-8.6
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
