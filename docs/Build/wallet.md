!> - An average pool operator may not require cardano-wallet at all. Please verify if it is required for your use as mentioned [here](build.md#components)

> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

#### Build Instructions {docsify-ignore}

Follow instructions below for building the cardano-wallet binary:

##### Clone the repository

Execute the below to clone the cardano-wallet repository to $HOME/git folder on your system:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-wallet
cd cardano-wallet
```

##### Build Cardano Wallet

You can use the instructions below to build the cardano-node, same steps can be executed in future to update the node (replacing appropriate tag) as well.

> The cardano-wallet repo does not work yet with cabal, hence alternate for now is using stack to build

``` bash
git fetch --tags --all
git pull
# Replace master with appropriate tag if you'd like to avoid compiling against master
git checkout master
$CNODE_HOME/scripts/stack-build.sh
```

The above would copy the binaries into `~/.cabal/bin` folder.

##### Start the wallet

You can run the below to connect to a `cardano-node` instance that is expected to be already running
```bash
cardano-wallet-shelley serve --node-socket $CNODE_HOME/sockets/node0.socket --testnet $CNODE_HOME/files/genesis.json --database $CNODE_HOME/priv/wallet
```

##### Verify the wallet is handling requests
```bash
cardano-wallet-shelley network information
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
##### Creating/Restoring Wallet

If you're creating a new wallet, you'd first want to generate a mnemonic for use (see below):

```bash
cardano-wallet-shelley recovery-phrase generate
# false brother typical saddle settle phrase foster sauce ask sunset firm gate service render burger
```
You can use the above mnemonic to then restore a wallet as per below:
```bash
cardano-wallet-shelley.exe wallet create from-recovery-phrase
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
