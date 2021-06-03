A common environment file called `env` is sourced by most scripts in the Guild Operators repository. This file holds common variables and functions needed by more than one script. There are several benefits to this, not having duplicate settings in several files being one of them decreasing the risk of misconfiguration.

#### Installation
`env` file is downloaded together with the rest of the scripts when [Pre-Requisites](basics.md#pre-requisites) if followed and located in the `$CNODE_HOME/scripts/` directory. The file is also automatically downloaded/updated by some of the individual scripts if missing, like `cntools.sh`, `gLiveView.sh` and `topologyUpdater.sh`. All custom changes in User Variables section are untouched on updates unless a forced overwrite is selected when running `prereqs.sh`.

#### Configuration
Most variables can be left commented to use the automatically detected or default value. But there are some that need to be set as explained below.

* `CNODE_PORT` - This is the most important variable and **needs** to be set. Used when launching the node through `cnode.sh` and to identify the correct process of the node.
* `CNODE_HOME` - The root directory of the cardano node holding all the files needed. Can be left commented if `prereqs.sh` has been run as this variable is then exported and added as a system environment variable.
* `POOL_NAME` - If the node is to be started as a block producer by `cnode.sh` this variable needs to be uncommented and set. This is the name given to the pool in CNTools (not ticker), i.e. the pool directory name under `$CNODE_HOME/priv/pool/<POOL_NAME>`

Take your time and look through the different variables and their explanations and decide if you need/want to change the default setting. For a default deployment using `prereqs.sh`, the `CNODE_PORT` (all installs) and `POOL_NAME` (only block producer) should be the only variables needed to be set. A snippet of `env` file shown below.
 
``` bash
######################################
# User Variables - Change as desired #
# Leave as is if unsure              #
######################################

#CCLI="${HOME}/.cabal/bin/cardano-cli"                  # Override automatic detection of path to cardano-cli executable
#CNCLI="${HOME}/.cargo/bin/cncli"                       # Override automatic detection of path to cncli executable (https://github.com/AndrewWestberg/cncli)
#CNODE_HOME="/opt/cardano/cnode"                        # Override default CNODE_HOME path (defaults to /opt/cardano/cnode)
CNODE_PORT=6000                                         # Set node port
#CONFIG="${CNODE_HOME}/files/config.json"               # Override automatic detection of node config path
#SOCKET="${CNODE_HOME}/sockets/node0.socket"            # Override automatic detection of path to socket
#...
```