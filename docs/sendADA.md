### Check Balance

This script will check balance of address specified as command line argument

``` bash
cd $CNODE_HOME/scripts

./balance.sh 61WKMJemoBa....ssL7fzhq
                           TxHash                                 TxIx        Lovelace
----------------------------------------------------------------------------------------
WKMJemoBa4a9dc77d6d36cfbd90ae0e693e5e99ad59c09a8455169assL7fzhq     0        1000000000

Total balance in 1 UTxO is 1000000000 Lovelace or 1000 ADA
```

### Make Transactions

This script will create and submit a transaction to send ADA using your private key as source and an address specified on command line, it assumes the [pre-requisites](Common.md#dependencies-and-folder-structure-setup) are already in place

``` bash
# Send ADA script usage
cd $CNODE_HOME/scripts

./sendADA.sh
# Usage:  sendADA.sh <Tx-File to Create for submission> <Output Address> <Amount in ADA> <Signing Key file>
#
# Example:
# ./sendADA.sh tx.out 61WKMJemoBa....ssL7fzhq 20 $CNODE_HOME/priv/utxo2.skey
```
