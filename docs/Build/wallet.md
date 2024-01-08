!> - An average pool operator may not require `cardano-wallet` at all. Please verify if it is required for your use as mentioned [here](../build.md#components).

> Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

#### Build Instructions {docsify-ignore}

Follow instructions below for building the cardano-wallet binary:

##### Clone the repository

Execute the below to clone the `cardano-wallet` repository to `$HOME/git` folder on your system:

``` bash
cd ~/git
git clone https://github.com/cardano-foundation/cardano-wallet
cd cardano-wallet
```

##### Build Cardano Wallet

You can use the instructions below to build the latest release of [cardano-wallet](https://github.com/cardano-foundation/cardano-wallet).

!> - Note that the latest release of `cardano-wallet` may not work with the latest release of `cardano-node`. Please check the compatibility of each `cardano-wallet` release yourself in the official docs, e.g. https://github.com/cardano-foundation/cardano-wallet/releases/latest.

``` bash
git fetch --tags --all
git pull
# Replace tag against checkout if you do not want to build the latest released version
git checkout $(curl -s https://api.github.com/repos/cardano-foundation/cardano-wallet/releases/latest | jq -r .tag_name)
$CNODE_HOME/scripts/cabal-build-all.sh
```

The above would copy the binaries into `~/.local/bin` folder.

##### Start the wallet

You can run the below to connect to a `cardano-node` instance that is expected to be already running and the wallet will start syncing.
```bash
cardano-wallet serve /
    --node-socket $CNODE_HOME/sockets/node0.socket /
    --mainnet / # if using the testnet flag you also need to specify the testnet shelley-genesis.json file
    --database $CNODE_HOME/priv/wallet
```

##### Verify the wallet is handling requests
```bash
cardano-wallet network information
```
Expected output should be similar to the following
```json
Ok.
{
    "network_tip": {
        "time": "2021-06-01T17:31:05Z",
        "epoch_number": 269,
        "absolute_slot_number": 31002374,
        "slot_number": 157574
    },
    "node_era": "mary",
    "node_tip": {
        "height": {
            "quantity": 5795127,
            "unit": "block"
        },
        "time": "2021-06-01T17:31:00Z",
        "epoch_number": 269,
        "absolute_slot_number": 31002369,
        "slot_number": 157569
    },
    "sync_progress": {
        "status": "ready"
    },
    "next_epoch": {
        "epoch_start_time": "2021-06-04T21:44:51Z",
        "epoch_number": 270
    }
}

```
##### Creating/Restoring Wallet

If you're creating a new wallet, you'd first want to generate a mnemonic for use (see below):

```bash
cardano-wallet recovery-phrase generate
# false brother typical saddle settle phrase foster sauce ask sunset firm gate service render burger
```
You can use the above mnemonic to then restore a wallet as per below:
```bash
cardano-wallet wallet create from-recovery-phrase MyWalletName

```
##### Expected output:
```text
Please enter a 15–24 word recovery phrase: false brother typical saddle settle phrase foster sauce ask sunset firm gate service render burger
(Enter a blank line if you do not wish to use a second factor.)
Please enter a 9–12 word second factor:
Please enter a passphrase: **********
Enter the passphrase a second time: **********
Ok.
{
    ...
}
```
