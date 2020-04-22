
#### Getting started with Haskell Node

Use the sidebar to navigate through the topics. Note that the instructions assume the folder structure as below, you're expected to update the folder reference as per your environment.
Note that currently the network is on real-pbft consensus. This is not shelley codebase , and its best to set your expectation accordingly. This is currently only useful to get familiar with modular architecture and usage.

##### Folder structure
The documentation will use the below as a reference folder.

    /opt/cardano/cnode          # Top-Level Folder
    ├── ...
    ├── files                   # Config, genesis and topology files
    │   ├── ...
    │   ├── genesis.json        # Genesis file referenced in ptn0.yaml
    │   ├── ptn0.yaml           # Config file used by cardano-node
    │   └── inventory.json      # Map of Real-PBFT chain for cardano-node
    ├── db                      # DB Store for cardano-node
    ├── logs                    # Logs for cardano-node
    ├── priv                    # Folder to store your keys (permission: 600)
    ├── scripts                 # Scripts to start and interact with cardano-node
    ├── sockets                 # Socket files created by cardano-node
    └── ...

You can create the above using sample commands below:
``` bash
export CNODE_HOME=/opt/cardano/cnode
sudo mkdir -p ${CNODE_HOME}/{files,db,logs,scripts,sockets,priv}
sudo chown -R $USER:$USER $CNODE_HOME
chmod -R 755 $CNODE_HOME

cd $CNODE_HOME/files

curl -o ptn0.yaml https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/ptn0.yaml
curl https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/genesis.json | jq '.' > genesis.json
curl https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/topology.json | jq '.' > topology.json

# If using a different CNODE_HOME than in this example, execute the below:
# sed -i -e "s#/opt/cardano/cnode#${CNODE_HOME}#" $CNODE_HOME/files/ptn0.yaml
## For future use:
## It generates random NodeID:
## -e "s#NodeId:.*#NodeId:`od -A n -t u8 -N 8 /dev/urandom`#" \

cd -
cd $CNODE_HOME/scripts
curl -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
curl -o sendADA.sh https://github.com/cardano-community/guild-operators/blob/master/scripts/cnode-helper-scripts/sendADA.sh
curl -o cnode.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/cnode.sh.templ
# If you opt for an alternate CNODE_HOME, please run the below:
# sed -i -e "s#/opt/cardano/cnode#${CNODE_HOME}#" *.sh
cd -
```