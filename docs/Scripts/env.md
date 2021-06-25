A common environment file called `env` is sourced by most scripts in the Guild Operators repository. This file holds common variables and functions needed by more than one script. There are several benefits to this, not having duplicate settings in several files being one of them decreasing the risk of misconfiguration.

#### Installation
`env` file is downloaded together with the rest of the scripts when [Pre-Requisites](basics.md#pre-requisites) if followed and located in the `$CNODE_HOME/scripts/` directory. The file is also automatically downloaded/updated by some of the individual scripts if missing, like `cntools.sh`, `gLiveView.sh` and `topologyUpdater.sh`. All custom changes in User Variables section are untouched on updates unless a forced overwrite is selected when running `prereqs.sh`.

#### Configuration
Most variables can be left commented to use the automatically detected or default value. But there are some that need to be set as explained below.

* `CNODE_PORT` - This is the most important variable and **needs** to be set. Used when launching the node through `cnode.sh` and to identify the correct process of the node.
* `CNODE_HOME` - The root directory of the Cardano node holding all the files needed. Can be left commented if `prereqs.sh` has been run as this variable is then exported and added as a system environment variable.
* `POOL_NAME` - If the node is to be started as a block producer by `cnode.sh` this variable needs to be uncommented and set. This is the name given to the pool in CNTools (not ticker), i.e. the pool directory name under `$CNODE_HOME/priv/pool/<POOL_NAME>`

Take your time and look through the different variables and their explanations and decide if you need/want to change the default setting. For a default deployment using `prereqs.sh`, the `CNODE_PORT` (all installs) and `POOL_NAME` (only block producer) should be the only variables needed to be set. A snippet of the `env` file shown below.

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
#TOPOLOGY="${CNODE_HOME}/files/topology.json"           # Override default topology.json path
#LOG_DIR="${CNODE_HOME}/logs"                           # Folder where your logs will be sent to (must pre-exist)
#DB_DIR="${CNODE_HOME}/db"                              # Folder to store the cardano-node blockchain db
#UPDATE_CHECK="Y"                                       # Check for updates to scripts, it will still be prompted before proceeding (Y|N).
#TMP_DIR="/tmp/cnode"                                   # Folder to hold temporary files in the various scripts, each script might create additional subfolders
#EKG_HOST=127.0.0.1                                     # Set node EKG host IP
#EKG_PORT=12788                                         # Override automatic detection of node EKG port
#PROM_HOST=127.0.0.1                                    # Set node Prometheus host IP
#PROM_PORT=12798                                        # Override automatic detection of node Prometheus port
#EKG_TIMEOUT=3                                          # Maximum time in seconds that you allow EKG request to take before aborting (node metrics)
#CURL_TIMEOUT=10                                        # Maximum time in seconds that you allow curl file download to take before aborting (GitHub update process)
#BLOCKLOG_DIR="${CNODE_HOME}/guild-db/blocklog"         # Override default directory used to store block data for core node
#BLOCKLOG_TZ="UTC"                                      # TimeZone to use when displaying blocklog - https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
#SHELLEY_TRANS_EPOCH=208                                # Override automatic detection of shelley epoch start, e.g 208 for mainnet
#TG_BOT_TOKEN=""                                        # Uncomment and set to enable telegramSend function. To create your own BOT-token and Chat-Id follow guide at:
#TG_CHAT_ID=""                                          # https://cardano-community.github.io/guild-operators/#/Scripts/sendalerts
#USE_EKG="N"                                            # Use EKG metrics from the node instead of Promethus. Promethus metrics(default) should yield slightly better performance
#TIMEOUT_LEDGER_STATE=300                               # Timeout in seconds for querying and dumping ledger-state
#IP_VERSION=4                                           # The IP version to use for push and fetch, valid options: 4 | 6 | mix (Default: 4)

#WALLET_FOLDER="${CNODE_HOME}/priv/wallet"              # Root folder for Wallets
#POOL_FOLDER="${CNODE_HOME}/priv/pool"                  # Root folder for Pools
                                                        # Each wallet and pool has a friendly name and subfolder containing all related keys, certificates, ...
#POOL_NAME=""                                           # Set the pool's name to run node as a core node (the name, NOT the ticker, ie folder name)

#WALLET_PAY_VK_FILENAME="payment.vkey"                  # Standardized names for all wallet related files
#WALLET_PAY_SK_FILENAME="payment.skey"
#WALLET_HW_PAY_SK_FILENAME="payment.hwsfile"
#WALLET_PAY_ADDR_FILENAME="payment.addr"
#WALLET_BASE_ADDR_FILENAME="base.addr"
#WALLET_STAKE_VK_FILENAME="stake.vkey"
#WALLET_STAKE_SK_FILENAME="stake.skey"
#WALLET_HW_STAKE_SK_FILENAME="stake.hwsfile"
#WALLET_STAKE_ADDR_FILENAME="reward.addr"
#WALLET_STAKE_CERT_FILENAME="stake.cert"
#WALLET_STAKE_DEREG_FILENAME="stake.dereg"
#WALLET_DELEGCERT_FILENAME="delegation.cert"

#POOL_ID_FILENAME="pool.id"                             # Standardized names for all pool related files
#POOL_HOTKEY_VK_FILENAME="hot.vkey"
#POOL_HOTKEY_SK_FILENAME="hot.skey"
#POOL_COLDKEY_VK_FILENAME="cold.vkey"
#POOL_COLDKEY_SK_FILENAME="cold.skey"
#POOL_OPCERT_COUNTER_FILENAME="cold.counter"
#POOL_OPCERT_FILENAME="op.cert"
#POOL_VRF_VK_FILENAME="vrf.vkey"
#POOL_VRF_SK_FILENAME="vrf.skey"
#POOL_CONFIG_FILENAME="pool.config"
#POOL_REGCERT_FILENAME="pool.cert"
#POOL_CURRENT_KES_START="kes.start"
#POOL_DEREGCERT_FILENAME="pool.dereg"

#ASSET_FOLDER="${CNODE_HOME}/priv/asset"                # Root folder for Multi-Assets containing minted assets and subfolders for Policy IDs
#ASSET_POLICY_VK_FILENAME="policy.vkey"                 # Standardized names for all multi-asset related files
#ASSET_POLICY_SK_FILENAME="policy.skey"
#ASSET_POLICY_SCRIPT_FILENAME="policy.script"           # File extension '.script' mandatory
#ASSET_POLICY_ID_FILENAME="policy.id"
```