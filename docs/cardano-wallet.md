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
For example the for cardano-wallet 2020.4.7 (git revision: ce8a9fd68ec08fac6f66e23b13f5477183e58141) the build output is in
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
