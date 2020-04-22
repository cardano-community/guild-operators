### Collection of Value-added scripts

A place to collect scripts that are supposed to help with usage of Cardano-node. The initial attempt below is with an aim to keep things similar to the current jormungandr scripts' usage.

##### Create Privat key and corresponding address file
``` bash
cd $CNODE_HOME/scripts
./createAddr.sh pbft1
# Sample output to enter passphrase (can be left empty, you will need this passphrase to access the key if filled):
# Enter password to encrypt 'pbft1':
# Repeat to validate:
```

##### Create and submit a transaction to send ADA
```
# Send ADA script usage
cd $CNODE_HOME/scripts
./sendADA.sh tx.out 2cWKMJemoBa....ssL7fzhq 20 $CNODE_HOME/priv/pbft0.key
```