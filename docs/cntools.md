### Cardano Node Tools

This is a multi-purpose script to operate various activities (like creating keys, transactions, registering stake pool , delegating to a pool or updating binaries) using cardano node.

The script assumes the [pre-requisites](Common.md#dependencies-and-folder-structure-setup) have already been run.

#### Download cntools.sh

If you have run `prereqs.sh`, this should already be available in your scripts folder. To download cntools.sh you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
wget https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.sh
chmod 750 cntools.sh
```

#### Check Usage

Execute cntools.sh without any arguments to check the usage syntax:

``` bash
./cntools.sh
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Usage:
#
#   ./cntools.sh update [optional:DESIRED_RELEASE_TAG]
#
#   ./cntools.sh wallet new [WALLET_NAME] [optional:WALLET_TYPE]
#   ./cntools.sh wallet list
#   ./cntools.sh wallet show [WALLET_NAME]
#   ./cntools.sh wallet remove [WALLET_NAME]
#
#   ./cntools.sh funds send [SOURCE_WALLET] [AMOUNT] [DESTINATION_ADDRESS|WALLET]
#           Note: Amount is an Integer value in Lovelaces
#
#   ./cntools.sh pool register [POOL_NAME] [WALLET_OWNER] [WALLET_REWARDS]
#                    [TAX_FIXED] [TAX_PERMILLE] [optional:TAX_LIMIT]
#           Note: you can use the same wallet for owner and rewards
#
#   ./cntools.sh stake delegate [WALLET_NAME] [POOL_NAME] [WALLET_TXFEE]
#
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

PS: Note that parts of the scripts are under construction, but you would see a message if a particular functionality is unavailable
