Since the test network has to get along without the P2P network module for the time being, it needs static topology files. This "TopologyUpdater" service, which is far from being perfect due to its centralization factor, is intended to be a **temporary** solution to allow everyone to activate their relay nodes without having to postpone and wait for manual topology completion requests.

The topologyupdater shell script must be executed on the relay node as a cronjob **exactly every 60 minutes**. After **4 consecutive requests (3 hours)** the node is considered a new relay node in listed in the topology file. If the node is turned off, it's automatically delisted after 3 hours.

#### Download and Configure topologyUpdater.sh

If you have run [prereqs.sh](basics.md#pre-requisites), this should already be available in your scripts folder and make this step unnecessary. 

Before the updater can make a valid request to the central topology service, he must query the current tip/blockNo from the well synced local node. It connects to your node through the configuration in the script as well as the common env configuration file. Customize these files for your needs.  

To download topologyupdater.sh manually you can execute the commands below and test executing topology Updater once (it's OK if first execution gives back an error):
``` bash
cd $CNODE_HOME/scripts
curl -s -o topologyUpdater.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/topologyUpdater.sh
curl -s -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
chmod 750 topologyUpdater.sh
./topologyUpdater.sh
```

#### Examine and modify the variables within topologyUpdater.sh script

Out of the box, the scripts might come with some assumptions, that may or may not be valid for your environment. One of the common changes as a SPO would be to **complete CUSTOM_PEERS section** as below to include your local relays/BP nodes, and any additional peers you'd like to be always available at minimum. Please do take time to update the variables in User Variables section in  `env` & `topologyUpdater.sh`:

``` bash
### topologyUpdater.sh

######################################
# User Variables - Change as desired #
######################################

CNODE_HOSTNAME="CHANGE ME"                                # (Optional) Must resolve to the IP you are requesting from
CNODE_VALENCY=1                                           # (Optional) for multi-IP hostnames
MAX_PEERS=15                                              # Maximum number of peers to return on successful fetch
#CUSTOM_PEERS="None"                                      # Additional custom peers to (IP:port[:valency]) to add to your target topology.json
                                                          # eg: "10.0.0.1:3001|10.0.0.2:3002|relays.mydomain.com:3003:3"
```

Upon first run,

!> Any customisations you add above, will be saved across future prereqs.sh executions , unless you specify `-f` flag to overwrite completely.

#### Deploy the script

**systemd service**  
The script can be deployed as a background service in different ways but the recommended and easiest way if [prereqs.sh](basics.md#pre-requisites) was used, is to utilize the `deploy-as-systemd.sh` script to setup and schedule the execution. This will deploy both push & fetch service files as well as timers for a scheduled 60 min node alive message and cnode restart at the user set interval when running the deploy script.

- cnode-tu-push.service    : pushes a node alive message to Topology Updater API
- cnode-tu-push.timer      : schedules the push service to execute once every hour
- cnode-tu-fetch.service   : fetches a fresh topology file before cnode.service file is started/restarted
- cnode-tu-restart.service : handles the restart of cardano-node(cnode.sh)
- cnode-tu-restart.timer   : schedules the cardano-node restart service, default every 24h

`systemctl list-timers` can be used to to check the push and restart service schedule.

**crontab job**  
Another way to deploy topologyUpdater.sh script is as a `crontab` job. Add the script to be executed once per hour at a minute of your choice (eg xx:25 o'clock in the example below). The example below will handle both the fetch and push in a single call to the script once an hour. In addition to the below crontab job for topologyUpdater, it's expected that you also add a scheduled restart of the relay node to pick up a fresh topology file fetched by topologyUpdater script with relays that are alive and well.

``` bash
25 * * * * /opt/cardano/cnode/scripts/topologyUpdater.sh
```


#### Logs
You can check the last result of push message in `logs/topologyUpdater_lastresult.json`.  
If deployed as systemd service, use `sudo journalctl -u <service>` to check output from service.


#### Step by Step to have your relay node listed in the topology

*Note:* You don't need to execute this for your pool nodes. 

You need to execute it once for every relay node you run. (IP:PORT combination)

If one of the parameters is outside the allowed ranges, invalid or missing the returned json will tell you what needs to be fixed.

Don't try to execute the script more often than once per hour. It's completely useless and may lead to a temporary blacklisting.


#### Why does my topology file only contain IOG peers?

Each subscribed node (4 consecutive requests) is allowed to fetch a subset of other nodes to prove loyalty/stability of the relay. Until reaching this point, your fetch calls will only return IOG peers combined with any custom peers added in *USER VARIABLES* section of `topologyUpdater.sh` script

Engineers of cardano-node network stack suggested to use around 20 peers. More peers create unnecessary and unwanted system load and delays.

In it's default setting it returns a list of 15 remote peers. 

Note that the change in topology is only effective upon restart of your node. Be sure, to do account for some scheduled restarts on your relays, to help onboard newer relays onto the network.

#### How do I add my own relays/static nodes in addition to dynamic list generated by topologyUpdater?

Most of the Stake Pool Operators may have few preferences (own relays, close friends, etc) that they would like to add to their topology by default. This is where CUSTOM_PEERS (in `topologyUpdater.sh`) comes in. You can add a list of `hostname/IPs`:`port`[:`valency`] here and the output topology.json formed will already include the custom peers that you supplied.  Every custom peer is defined in the form [address]:[port] and optional :[valency]. Multiple custom peers are separated by `|`

#### How are the peers for my topology file selected?

We calculate the distance on the earth's surface from your nodes IP to all subscribed peers. We then order by distance (closest first) and start selecting one peer. Then skip some, pick the next, skip, pick, skip, pick ... until we reach the end of the list (furthest away). The number of skipped records is calculated in a way to have the desired number of peers at the end.

Every requesting node has his personal distances to all other nodes. 

We assume this should result in a well distributed and interconnected peering network.
