
### Pre-Requisites

#### Dependencies and Folder Structure setup

The pre-requisites for Linux systems are automated to be executed as a single script. Follow the instructions below to deploy the same:

``` bash
mkdir "~/tmp";cd "~/tmp"
wget https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/prereqs.sh
chmod 755 https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/prereqs.sh
# Ensure you can run sudo commands with your user before execution
./prereqs.sh
## Follow the prompts for execution
```

#### Folder structure

Running the script above will create the folder structure as per below, for your reference.

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

