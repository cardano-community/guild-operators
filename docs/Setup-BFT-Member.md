### Config for pHTN - as a BFT Member

Use this guide only if you already have your key (referred to as pbft0.key below) that's already registered in genesis.

#### Create verification key

``` bash
# Create the verification key
cardano-cli to-verification --real-pbft --secret $CNODE_HOME/priv/pbft0.key --to $CNODE_HOME/priv/pbft0.vfk

# Check the verification/public key
cardano-cli signing-key-public --real-pbft --secret $CNODE_HOME/priv/pbft0.key | awk '/base64/ { print $4}'
# HyZ+SQ3odbYPH...A==
cat $CNODE_HOME/priv/pbft0.vfk
# HyZ+SQ3odbYPH...A==
```

#### Extract your cert from genesis using below
``` bash
# Extract cert from genesis.
grep `cat $CNODE_HOME/priv/pbft0.vfk` -B 4 -A 3 $CNODE_HOME/files/genesis.json | sed -e 's@^.*{@{@' -e 's@^.*},@}@' > $CNODE_HOME/priv/pbft0.json
```

#### Start Node
``` bash
# Run the node
cd $CNODE_HOME/scripts
./cnode.sh
```