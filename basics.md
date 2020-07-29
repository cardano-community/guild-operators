#### Architecture

The architecture and description of various components are best described at [Adrestia Architecture](https://docs.cardano.org/projects/adrestia/en/latest/architecture.html) by CF/IOHK. We will not reinvent the wheel :smile:

#### Pre-Requisites

##### Set up OS packages, folder structure and fetch files from repo

The pre-requisites for Linux systems are automated to be executed as a single script. Note that the guide assumes you do *NOT* change working directory or mix multiple SSH sessions. Follow the instructions below to deploy the same:

``` bash
mkdir "$HOME/tmp";cd "$HOME/tmp"
# Install curl
# CentOS / RedHat - sudo dnf -y install curl
# Ubuntu / Debian - sudo apt -y install curl
curl -sS -o prereqs.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/prereqs.sh
chmod 755 prereqs.sh

# Ensure you can run sudo commands with your user before execution
# You can check the syntax for prereqs.sh using command below:
#
# ./prereqs.sh -h
# Usage: prereqs.sh [-o] [-s] [-i] [-g] [-p]
# Install pre-requisites for building cardano node and using cntools
# -o    Do *NOT* overwrite existing genesis, topology.json and topology-updater.sh files (Default: will overwrite)
# -s    Skip installing OS level dependencies (Default: will check and install any missing OS level prerequisites)
# -i    Interactive mode (Default: silent mode)
# -g    Connect to guild network instead of public network (Default: connect to public cardano network)
# -p    Copy Transitional Praos config as default instead of Combinator networks (Default: copies combinator network)

# You can use one of the options above, if you'd like to defer from defaults (below).
# Running without any parameters will run script in silent mode with OS Dependencies, and overwriting existing files.

./prereqs.sh

## Follow the prompts for execution. To make sure environment variables are available for session you're running, make sure to source bashrc
. "${HOME}/.bashrc"
```

##### Connecting to other Haskell Networks

The prereqs script above will connect you to `mainnet_candidate_4` network. If you would like to connect to one of the other networks instead (see [here](https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/index.html) for list), you can select the filename of the network and execute the below before you proceed (eg: to switch to `testnet`):

!> Note that you do **NOT** need to replace the config file, and doing so without proper consideration may result in issues

```bash
## For ***mainnet*** network (usable after fork):
curl -sL -o $CNODE_HOME/files/byron-genesis.json https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-byron-genesis.json
curl -sL -o $CNODE_HOME/files/genesis.json https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-shelley-genesis.json
curl -sL -o $CNODE_HOME/files/topology.json https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-topology.json
curl -sL -o $CNODE_HOME/files/config.json https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0-mainnet.json
```

##### Folder structure

Running the script above will create the folder structure as per below, for your reference. You can replace the top level folder `/opt/cardano/cnode` by editing the value of CNODE_HOME in `~/.bashrc` and `$CNODE_HOME/files/env` files:


    /opt/cardano/cnode          # Top-Level Folder
    ├── ...
    ├── files                   # Config, genesis and topology files
    │   ├── ...
    │   ├── genesis.json        # Genesis file referenced in config.json
    │   ├── byron-genesis.json  # Byron Genesis file referenced in config.json (if using combinator network)
    │   ├── config.json           # Config file used by cardano-node
    │   └── topology.json       # Map of chain for cardano-node to boot from
    ├── db                      # DB Store for cardano-node
    ├── logs                    # Logs for cardano-node
    ├── priv                    # Folder to store your keys (permission: 600)
    ├── scripts                 # Scripts to start and interact with cardano-node
    └── sockets                 # Socket files created by cardano-node
