Since the test network has to get along without the P2P network module for the time being, it needs static topology files. This "TopologyUpdater" service, which is far from being perfect due to its centralization factor, is intended to be a temporary solution to allow everyone to activate their relay nodes without having to postpone and wait for manual topology completion requests.

The topologyupdater shell script must be executed on the relay node as a cronjob exactly every 60 minutes. After 4 consecutive requests (3 hours) the node is considered a new relay node in listed in the topology file. If the node is turned off, it's automatically delisted after 3 hours.

#### Download and Configure topologyUpdater.sh

If you have run [prereqs.sh](basics.md#pre-requisites), this should already be available in your scripts folder and make this step unnecessary. 

Before the updater can make a valid request to the central topology service, he must query the current tip/blockNo from the well synced local node. It connects to your node through the configuration in the script (note: not the usual env file, as cronjobs don't run in the same environment). Customize this file for your needs.  


To download topologyupdater.sh manually you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
curl -s -o topologyUpdater.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/topologyUpdater.sh
chmod 750 topologyUpdater.sh
```

#### Examine and modify the variables within topologyUpdater.sh script

Out of the box, the scripts might come with some assumptions, that may or may not be valid for your environment. It is best for you to check and update section below in the file:

``` bash
######################################
# User Variables - Change as desired #
######################################

CNODE_PORT=6000                                           # Must match your relay node port as set in the startup command
CNODE_HOSTNAME="CHANGE ME"                                # (Optional) Must resolve to the IP you are requesting from
CNODE_BIN="${HOME}/.cabal/bin"                            # Path where your cardano-cli and cardano-node binaries are
CNODE_HOME="/opt/cardano/cnode"                           # (Optional) Top-level folder to auto populate file locations under, useful if using guild repo instructions
CNODE_LOG_DIR="${CNODE_HOME}/logs/"                       # Folder where your logs will be sent to (must pre-exist)
CONFIG="$CNODE_HOME/files/config.json"                    # Filename with path for config used by node
GENESIS_JSON=$(jq -er '.ShelleyGenesisFile' "${CONFIG}")  # Filename with path for Shelley genesis file used by node (auto detected if your config is in JSON format)
SOCKET="${CNODE_HOME}/sockets/node0.socket"               # Path to socket file for your cardano node instance
CNODE_VALENCY=1                                           # (Optional) for multi-IP hostnames

```

!> Any customisations you add above, will be saved across future prereqs.sh executions , unless you specify `-f` flag to overwrite completely.

#### Start the script

Then add the script to be executed once per hour at a minute of your choice (eg xx:25 o'clock in the example below)

``` bash
25 * * * * /opt/cardano/cnode/scripts/topologyUpdater.sh
```

you can check the last result in `logs/topologyUpdater_lastresult.json`


#### Step by Step to have your relay node listed in the topology

*Note:* You don't need to execute this for your pool nodes. 

You need to execute it once for every relay node you run. (IP:PORT combination)

If one of the parameters is outside the allowed ranges, invalid or missing the returned json will tell you what needs to be fixed.

Don't try to execute the script more often than once per hour. It's completely useless and may lead to a temporary blacklisting.


#### Where is the topology file?

Each subscribed node (4 consecutive requests) is allowed to fetch a subset of other nodes. 

Engineers of cardano-node network stack suggested to use around 20 peers. More peers create unnecessary and unwanted system load and delays.

The URL to fetch the peer list is [https://api.clio.one/htopology/v1/fetch/](https://api.clio.one/htopology/v1/fetch/)

In it's default setting it returns a list of 15 remote peers. 

The **max** parameter allows to define a number between 1 and 20 remote peers.

The **magic** parameter is optional and useful if you run a testnet node on the same IP. (not recommended)
If not specified, the endpoint assumes you want to fetch mainnet's networkMagic 764824073.

you can request the file from you node by using the curl command

``` bash
curl -s -o path/to/topology.json "https://api.clio.one/htopology/v1/fetch/?max=14&magic=1234"
```

Don't forget to restart your node to load the new topology. 

#### Can I add custom peers (internal pools) ?

There is also a **customPeers** parameter, to include also some custom peers you want included in the topology json file.  Every custom peer is defined in the form [address]:[port] and optional :[valancy]. Multiple custom peers are separated by | 

A complete example looks like

``` bash
curl -s -o topology.json "https://api.clio.one/htopology/v1/fetch/?max=12&customPeers=10.0.0.1:3001|10.0.0.2:3002|relays.mydomain.com:3003:3"
```

Might think about including the curl command in your startup script before cardano-node.

#### How are the peers for my topology file selected?

We calculate the distance on the earth's surface from your nodes IP to all subscribed peers. We then order by distance (closest first) and start selecting one peer. Then skip some, pick the next, skip, pick, skip, pick ... until we reach the end of the list (furthest away). The number of skipped records is calculated in a way to have the desired number of peers at the end.

Every requesting node has his personal distances to all other nodes. 

We assume this should result in a well distributed and interconnected peering network.


