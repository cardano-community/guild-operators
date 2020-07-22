Note that if you do not want your node to be publicly available, you can change `--host-addr` to `127.0.0.1`
### Run a passive node

This document helps you to set a basic Passive Node connecting to the network. This would also be a first step if you do not have a genesis (BFT) keys for TPraos network, to allow you to register your pool.
Ensure the [Pre-Requisites](Common.md#dependencies-and-folder-structure-setup) are in place before you proceed.

To start the node in passive mode, execute the steps as below:

#### Start Passive Node

To start the node in passive mode, execute the steps as below:

``` bash
cardano-node run \
          --config $CNODE_HOME/files/ptn0.json \
          --database-path $CNODE_HOME/db \
          --host-addr 0.0.0.0 \
          --port 5001 \
          --socket-path $CNODE_HOME/sockets/node0.socket \
          --topology $CNODE_HOME/files/topology.json
```

#### Start as Pool Operator

To start the node as a block producing pool, execute the steps as below:
``` bash
# TODO: Add reference to key creations.
# POOLNAME=POOL123
POOLKEYSPATH=$CNODE_HOME/priv/pool/$POOLNAME
cardano-node run \
          --config $CNODE_HOME/files/ptn0.json \
          --database-path $CNODE_HOME/db \
          --host-addr 0.0.0.0 \
          --port 5001 \
          --socket-path $CNODE_HOME/sockets/node0.socket \
          --topology $CNODE_HOME/files/topology.json \
          --shelley-kes-key $CNODE_HOME/priv/pool/$POOLNAME/hot.skey \
          --shelley-vrf-key $CNODE_HOME/priv/pool/$POOLNAME/vrf.skey \
          --shelley-operational-certificate $CNODE_HOME/priv/pool/$POOLNAME/op.cert
```

Note that if you do not want your node to be publicly available, you can change `--host-addr` to `127.0.0.1`
If this is your relay node, you can update topology.json to link to your core node.
