### Cardano Wallet

Ensure the [Pre-Requisites](Common.md#dependencies-and-folder-structure-setup) are in place before you proceed.

#### Build Instructions

Follow instructions below for building the cardano-wallet binary:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-wallet
cd cardano-wallet
$CNODE_HOME/scripts/stack-build.sh
# TODO: Replace stack with cabal, once fixed
# 
```
The above would copy the binaries into ~/.cabal/bin folder.

#### Start the wallet server
```bash
cardano-wallet-byron serve --node-socket $CNODE_HOME/sockets/pbft_node.socket --testnet $CNODE_HOME/files/genesis.json --database $CNODE_HOME/priv/wallet
```

#### Verify the wallet is handling requests
```bash
cardano-wallet-byron network information
```
Expected output should be similar to the following
```json
Ok.
{
    "network_tip": {
        "epoch_number": 4,
        "slot_number": 730
    },
    "node_tip": {
        "height": {
            "quantity": 2390,
            "unit": "block"
        },
        "epoch_number": 4,
        "slot_number": 728
    },
    "sync_progress": {
        "status": "ready"
    },
    "next_epoch": {
        "epoch_start_time": "2020-04-27T09:48:35Z",
        "epoch_number": 5
    }
}
```
#### Create a new wallet
##### First generate a mnemonic phrase
```bash
cardano-wallet-byron mnemonic generate
# false brother typical saddle settle phrase foster sauce ask sunset firm gate service render burger
```
##### Generate a new byron wallet from your mnemonic phrase
```bash
cardano-wallet-byron wallet create from-mnemonic --wallet-style icarus "Guild Test Wallet"
```
##### Expected output:
```text
Please enter 15 mnemonic words : false brother typical saddle settle phrase foster sauce ask sunset firm gate service render burger
Please enter a passphrase: ******************
Enter the passphrase a second time: ******************
Ok.
{
    "passphrase": {
        "last_updated_at": "2020-04-27T06:35:19.48354187Z"
    },
    "state": {
        "status": "syncing",
        "progress": {
            "quantity": 0,
            "unit": "percent"
        }
    },
    "discovery": "sequential",
    "balance": {
        "total": {
            "quantity": 0,
            "unit": "lovelace"
        },
        "available": {
            "quantity": 0,
            "unit": "lovelace"
        }
    },
    "name": "Guild Test Wallet",
    "id": "0854da56dd00ae2099a499303681826506527ac7",
    "tip": {
        "height": {
            "quantity": 0,
            "unit": "block"
        },
        "epoch_number": 0,
        "slot_number": 0
    }
}
```
