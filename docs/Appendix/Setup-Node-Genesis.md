### Starting as a BFT member node defined in Genesis of TPraos

Use this guide only if you already have your genesis keys (referred to as `delegate.skey` below). The step may not apply to most of the pool operators.
Ensure the [Pre-Requisites](../Common.md#dependencies-and-folder-structure-setup) are in place before you proceed.

#### Create verification key

``` bash
# Create the Node operation keys
cardano-cli shelley node key-gen-VRF --verification-key-file $CNODE_HOME/priv/vrf.vkey --signing-key-file $CNODE_HOME/priv/vrf.skey
cardano-cli shelley node key-gen-KES --verification-key-file $CNODE_HOME/priv/kes.vkey --signing-key-file $CNODE_HOME/priv/kes.skey
cardano-cli shelley node issue-op-cert --kes-verification-key-file $CNODE_HOME/priv/kes.vkey --cold-signing-key-file $CNODE_HOME/priv/delegate.skey --operational-certificate-issue-counter $CNODE_HOME/priv/delegate.counter --kes-period 0 --out-file $CNODE_HOME/priv/ops.cert 
```

#### Start Node
``` bash
# Run the node
cd $CNODE_HOME/scripts
./cnode.sh
```
