### Make Transactions

This script will create and submit a transaction to send ADA using your private key as source and an address specified on command line, it assumes the [pre-requisites](Common.md#dependencies-and-folder-structure-setup) are already in place

``` bash
# Send ADA script usage
cd $CNODE_HOME/scripts

./sendADA.sh
# Usage:  sendADA.sh <Tx-File to Create for submission> <Output Address> <Amount in ADA> <Signing Key file (script expects .vkey with same name in same folder)>
#
# Example:
# ./sendADA.sh tx.out 2cWKMJemoBa....ssL7fzhq 20 $CNODE_HOME/priv/node0.key
```
