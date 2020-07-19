
### Pre-Requisites

#### Dependencies and Folder Structure setup

The pre-requisites for Linux systems are automated to be executed as a single script. Note that the guide assumes you do *NOT* change working directory or mix multiple SSH sessions.
Please ensure to *READ* the output if you execute something and investigate/raise issue if you receive an error. Do not continue bypassing any errors.
Follow the instructions below to deploy the same:

``` bash
mkdir "$HOME/tmp";cd "$HOME/tmp"
# Install wget
# CentOS / RedHat - sudo dnf -y install wget
# Ubuntu / Debian - sudo apt -y install wget
wget -O prereqs.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/prereqs.sh
chmod 755 prereqs.sh
# Ensure you can run sudo commands with your user before execution
./prereqs.sh
## Follow the prompts for execution. To make sure environment variables are available for session you're running, make sure to source bashrc
. "${HOME}/.bashrc"
```

#### Connect to public Haskell Testnet Network (HTN)

The prereqs script above will connect you to guild network. If you would like to connect to public HTN instead, kindly execute the below before you proceed after you've executed the above:

``` bash
## For mainnet-candidate:
wget -O $CNODE_HOME/files/byron-genesis.json https://hydra.iohk.io/build/3519218/download/1/mainnet_candidate-byron-genesis.json
wget -O $CNODE_HOME/files/topology.json https://hydra.iohk.io/build/3519218/download/1/mainnet_candidate-topology.json
wget -O $CNODE_HOME/files/genesis.json https://hydra.iohk.io/build/3519218/download/1/mainnet_candidate-shelley-genesis.json
## For Shelley Testnet:
# wget -O $CNODE_HOME/files/genesis.json https://hydra.iohk.io/build/3519218/download/1/shelley_testnet-shelley-genesis.json
# wget -O $CNODE_HOME/files/topology.json https://hydra.iohk.io/build/3519218/download/1/shelley_testnet-topology.json
```

If you were already running a node on guild network and would like to *replace* by moving to HTN, but continue using scripts - follow instructions below:

- Stop your node (if running).
- Ensure you've run commands above which will place updated files at correct location.
- Delete your existing DB folder by executing `rm -rf $CNODE_HOME/db/*` (or alternately - you can rename the folder to switch back later).
- Start the node

Eventually, you should be able to maintain different versions by tweaking scripts as desired. But for simplicity and reducing manual interventions, we will keep the guide using uniform paths.

#### Folder structure

Running the script above will create the folder structure as per below, for your reference.

    /opt/cardano/cnode          # Top-Level Folder
    ├── ...
    ├── files                   # Config, genesis and topology files
    │   ├── ...
    │   ├── genesis.json        # Genesis file referenced in ptn0.yaml
    │   ├── ptn0.yaml           # Config file used by cardano-node
    │   └── topology.json       # Map of chain for cardano-node to boot from
    ├── db                      # DB Store for cardano-node
    ├── logs                    # Logs for cardano-node
    ├── priv                    # Folder to store your keys (permission: 600)
    ├── scripts                 # Scripts to start and interact with cardano-node
    ├── sockets                 # Socket files created by cardano-node
    └── ...

