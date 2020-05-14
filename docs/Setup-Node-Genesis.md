### Config for pHTN - as a genesis member node

Use this guide only if you already have your genesis keys (referred to as `delegate.skey` below). The step may not apply to most of the pool operators.
Ensure the [Pre-Requisites](Common.md#dependencies-and-folder-structure-setup) are in place before you proceed.

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
