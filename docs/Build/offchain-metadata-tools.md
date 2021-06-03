!> - An average pool operator may not require offline-metadata-tools at all. Please verify if it is required for your use as mentioned [here](build.md#components)

>Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

In the Cardano multi-asset era, this project helps you create and submit metadata describing your assets, storing them off-chain.

##### Download pre-built binaries

Go to [input-output-hk/offchain-metadata-tools](https://github.com/input-output-hk/offchain-metadata-tools#pre-built-binaries) to download the binaries and place in a directory specified by `PATH`, e.g. `$HOME/.cabal/bin/`. 

##### Build Instructions

An alternative to pre-built binaries - instructions describe how to build the `token-metadata-creator` tool but the offchain-metadata-tools repository contains other tools as well. Build the ones needed for your installation.

##### Clone the repository

Execute the below to clone the offchain-metadata-tools repository to $HOME/git folder on your system:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/offchain-metadata-tools.git
cd offchain-metadata-tools/token-metadata-creator
```

##### Build token-metadata-creator

You can use the instructions below to build `token-metadata-creator`, same steps can be executed in future to update the binaries (replacing appropriate tag) as well.

``` bash
git fetch --tags --all
git pull
# Replace master with appropriate tag if you'd like to avoid compiling against master
git checkout master
$CNODE_HOME/scripts/cabal-build-all.sh
```
The above would copy the binaries into `~/.cabal/bin` folder.

##### Verify that token-metadata-creator is installed

Verify that the tool is executable from anywhere by running:

``` bash
token-metadata-creator -h
```
