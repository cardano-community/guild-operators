### Config for pHTN - as a Passive node

#### Create signing and verifying keys

``` bash
$ cardano-cli keygen --real-pbft --secret $CNODE_HOME/priv/pbft0p.key --no-password
```

#### Create verification key

``` bash
# Create the verification key
cardano-cli to-verification --real-pbft --secret $CNODE_HOME/priv/pbft0p.key --to $CNODE_HOME/priv/pbft0p.vfk

# Check the verification/public key
cardano-cli signing-key-public --real-pbft --secret $CNODE_HOME/priv/pbft0p.key | awk '/base64/ { print $4}'
# HyZ+SQ3odbYPH...A==
cat $CNODE_HOME/priv/pbft0p.vfk
# HyZ+SQ3odbYPH...A==
```

#### Create certificates
``` bash
$ cardano-cli issue-delegation-certificate \
--config $CNODE_HOME/files/config.json \
--since-epoch <?> \
--secret <THE ISSUER SECRET/KEY FOR GENESIS> \
--delegate-key $CNODE_HOME/priv/pbft0p.key \
--certificate $CNODE_HOME/files/pbft0p.json
```
#### Start Passive Node

``` bash
CNODE_HOME=/opt/cardano/cnode
cardano-node run \
          --config $CNODE_HOME/files/ptn0.yaml \
          --database-path $CNODE_HOME/db \
          --host-addr $(curl ifconfig.me) \
          --port 9000 \
          --socket-path $CNODE_HOME/sockets/pbft_node.socket \
          --topology $CNODE_HOME/files/topology.json
```
