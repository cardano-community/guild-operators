!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

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

This script will create and submit a transaction to send ADA from source address to destination address.  
The script can also be used to defrag address by setting destination and source address to the same and amount to the string 'all'

``` bash
cd $CNODE_HOME/scripts

./sendADA.sh

Usage: sendADA.sh <Destination Address> <Amount> <Source Address> <Source Sign Key> [--include-fee]

  Destination Address   Address or path to Address file.
  Amount                Amount in ADA, number(fraction of ADA valid) or the string 'all'.
  Source Address        Address or path to Address file.
  Source Sign Key       Path to Signature (skey) file. For staking address payment skey is to be used.
  --include-fee         Optional argument to specify that amount to send should be reduced by fee instead of payed by sender.
```
