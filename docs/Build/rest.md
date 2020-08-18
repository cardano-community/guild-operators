!> - An average pool operator may not require cardano-wallet at all. Please verify if it is required for your use as mentioned [here](build.md#components)

>Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

##### Build Instructions

##### Clone the repository

Execute the below to clone the cardano-rest repository to $HOME/git folder on your system:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-rest
cd cardano-rest
```

##### Build Cardano Rest

You can use the instructions below to build the cardano-rest, same steps can be executed in future to update the binaries (replacing appropriate tag) as well.

``` bash
git fetch --tags --all
git pull
# Replace master with appropriate tag if you'd like to avoid compiling against master
git checkout master
$CNODE_HOME/scripts/cabal-build-all.sh
```
The above would copy the binaries into `~/.cabal/bin` folder.

##### Start the REST server

Execute the below to start the Cardano Explorer API Server:

``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
cardano-explorer-api
# Running full server on http://localhost:8100/
```

##### Verify the REST server is functioning

Verify that you can query the API Server using instruction below:

``` bash
curl http://localhost:8100/api/blocks/pages
```

Expected output should be similar to the following:

```json
{"Right":[261,[{"cbeEpoch":4,"cbeSlot":9345,"cbeBlkHeight":2605,"cbeBlkHash":"9026612cfa53b7f8a84ff62c4e897830db9ab6ce24b19e0059f4b4db7a14c0f9","cbeTimeIssued":1587974365,"cbeTxNum":0,"cbeTotalSent":{"getCoin":"0"},"cbeSize":631,"cbeBlockLead":"464835a0904109be93d7996b9b4acc486f6c8f75a595b2c4392f9521","cbeBlockLead":"a18aa0130f67053ed1cb346813054e160687a8ee7602a549f8ae165b","cbeFees":{"getCoin":"0"}}]]}
```

