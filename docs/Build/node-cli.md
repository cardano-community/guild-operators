> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

#### Build Instructions {docsify-ignore}

##### Clone the repository

Execute the below to clone the cardano-node repository to $HOME/git folder on your system:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-node
cd cardano-node
```

##### Build Cardano Node

You can use the instructions below to build the cardano-node, same steps can be executed in future to update the binaries (replacing appropriate tag) as well.

``` bash
git fetch --tags --all
# Replace release 1.19.0 with the version/branch/tag you'd like to build
git pull
git checkout 1.19.0

echo -e "package cardano-crypto-praos\n  flags: -external-libsodium-vrf" > cabal.project.local
$CNODE_HOME/scripts/cabal-build-all.sh
```

The above would copy the binaries built into `~/.cabal/bin` folder.

##### Verify

Execute cardano-cli and cardano-node to verify output as below:

```bash
cardano-cli version
# cardano-cli 1.19.0 - linux-x86_64 - ghc-8.6
# git rev 4814003f14340d5a1fc02f3ac15437387a7ada9f
cardano-node version
# cardano-node 1.19.0 - linux-x86_64 - ghc-8.6
# git rev 4814003f14340d5a1fc02f3ac15437387a7ada9f
```

##### Start a passive node

To start the node in passive mode, you can use the pre-built script below:

```bash
cd $CNODE_HOME/scripts
./cnode.sh
```

