# Quickstart for using TOPOLOG-UPDATER
Since the test network has to get along without P2P network module for the time being, it needs static topology files. This, due to its centralization factor, far from being a perfect "TopologyUpdater" service is intended to be a temporary solution to allow everyone to activate their relay nodes without having to postpone and wait for manual topology completion requests.

The topologyupdater shell script must be executed on the relay node as a cronjob exactly every 60 minutes. After 4 consecutive requests (3 hours) the node is considered a new relay node in listed in the topology file. If the node is turned off, it's automatically delisted after 3 hours.

#### Download and Configure topologyupdater.sh

If you have run `prereqs.sh`, this should already be available in your scripts folder and make this step unnecessary. 

Before the updater can make a valid request to the central topology service, he must query the current tip/blockNo from the well synced local node. It connects to your node through the configuration in script (note: not the usual env file, as cronjobs don't run in the same environment). Customize this file for your needs.  


To download topologyupdater.sh manually you can execute the commands below:
``` bash
cd $CNODE_HOME/scripts
curl -s -o topologyupdater.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/topologyupdater.sh
chmod 750 topologyupdater.sh
```

#### Start
Then add the script to be executed once a hour at a minute of your choice (eg xx:25 o clock in the example below)

```
25 * * * * /opt/cardano/cnode/scripts/topologyUpdater.sh
```

you can check the last result in `logs/topologyUpdater_lastresult.json`


# Step by Step to have your relay node listed in the topology

*Note:* You don't need to execute this for your pool nodes. 

You need to execute it once for every relay node you run. (IP:PORT combination)

If one of the parameters is outside the allowed ranges, invlaid or missing the returned json will tell you what need to be fixed.

Don't try to execute the script more often than once a hour. It's completely useless and may lead to a temporary blacklisting.


# Where is the topology file

Work in progress. the topologyupdater is a quick interim solution. For now we propose it as a temporary solution and start collecting relay node registrations. 

We need to figure out how much entries a topology files should have and how we best share the registered nodes to ensure a smooth and solid testnet operation.

Stay tuned. 








 

