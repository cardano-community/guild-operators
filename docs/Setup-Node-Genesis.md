### Config for pHTN - as a BFT Member

Use this guide only if you already have your key (referred to as pbft0.key below) that's already registered in genesis.

#### Create verification key

``` bash
# Create the Node operation keys
cardano-cli shelley node key-gen-VRF --verification-key-file $CNODE_HOME/priv/vrf.vkey --signing-key-file $CNODE_HOME/priv/vrf.skey
cardano-cli shelley node key-gen-KES --verification-key-file $CNODE_HOME/priv/kes.vkey --signing-key-file $CNODE_HOME/priv/kes.skey
# TODO: Process to propogate keys in genesis to members
cardano-cli shelley node issue-op-cert --hot-kes-verification-key-file $CNODE_HOME/priv/kes.vkey --cold-signing-key-file $CNODE_HOME/priv/delegate.skey --operational-certificate-issue-counter $CNODE_HOME/priv/delegate.counter --kes-period 0 --out-file $CNODE_HOME/priv/ops.cert 
```

#### Start Node
``` bash
# Run the node
cd $CNODE_HOME/scripts
./cnode.sh
```
