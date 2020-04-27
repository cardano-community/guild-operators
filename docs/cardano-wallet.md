### Setup Cardano Wallet

This guide assumes you are using the common directory structure.

#### Install Instructions

``` bash
# Install ghcup and dependencies

sudo apt update
sudo apt install libghc-hsopenssl-dev gmp sqlite systemd
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# Clone the cardano-wallet repository from github

cd; cd git
git clone https://github.com/input-output-hk/cardano-wallet.git
cd cardano-wallet
stack build --test --no-run-tests
```

Now you can copy the binaries build (using location above) into ~/.local/bin folder (when part of the PATH variable).
```bash
cardano-wallet-byron
cardano-wallet-jormungandr
```
For example for cardano-wallet 2020.4.7 (git revision: ce8a9fd68ec08fac6f66e23b13f5477183e58141) the build output is in
`../cardano-wallet/.stack-work/install/x86_64-linux/ee58348a9d8cc4d7d8564fb6f136266b08b58bb18601bef486b392d8321af87c/8.6.5/`

#### Start the wallet server
```bash
cardano-wallet-byron serve --node-socket /opt/cardano/cnode/sockets/pbft_node.socket --testnet /opt/cardano/cnode/files/genesis.json --database /opt/cardano/cnode/priv/wallet
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
