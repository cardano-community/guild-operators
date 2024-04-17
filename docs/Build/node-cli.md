!!! info "Reminder !!"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

### Build Instructions

#### Clone the repository

Execute the below to clone the cardano-node repository to `$HOME/git` folder on your system:

``` bash
cd ~/git
git clone https://github.com/intersectmbo/cardano-node
cd cardano-node
```

#### Build Cardano Node

You can use the instructions below to build the latest release of [cardano-node](https://github.com/intersectmbo/cardano-node). 

``` bash
git fetch --tags --recurse-submodules --all
git pull
# Replace tag against checkout if you do not want to build the latest released version, we recommend using battle tested node versions - which may not always be latest
git checkout $(curl -sLf https://api.github.com/repos/intersectmbo/cardano-node/releases/latest | jq -r .tag_name)

# Use `-l` argument if you'd like to use system libsodium instead of IOG fork of libsodium while compiling
$CNODE_HOME/scripts/cabal-build-all.sh
```

The above would copy the binaries built into `~/.local/bin` folder.

#### Download pre-compiled Binary from Node release

While certain folks might want to build the node themselves (could be due to OS/arch compatibility, trust factor or customisations), for most it might not make sense to build the node locally.
Instead, you can download the binaries using [cardano-node release notes](https://github.com/intersectmbo/cardano-node/releases), where-in you can find the download links for every version. This is already taken care of by `guild-deploy.sh` if you used the option to download binaries (you can always re-run with specific arguments if unsure).

### Verify

Execute `cardano-cli` and `cardano-node` to verify output as below (the exact version and git rev should depend on your checkout tag on github repository):

```bash
cardano-cli version
# cardano-cli 8.x.x - linux-x86_64 - ghc-8.10
# git rev <...>
cardano-node version
# cardano-node 8.x.x - linux-x86_64 - ghc-8.10
# git rev <...>
```

#### Update port number or pool name for relative paths

Before you go ahead with starting your node, you may want to update values for `CNODE_PORT` in `$CNODE_HOME/scripts/env`. Note that it is imperative for operational relays and pools to ensure that the port mentioned is opened via firewall to the destination your node is supposed to connect from. Update your network/firewall configuration accordingly. Future executions of `guild-deploy.sh` will preserve and not overwrite these values (or atleast back up if forced to overwrite).

```bash
CNODEBIN="${HOME}/.local/bin/cardano-node"
CCLI="${HOME}/.local/bin/cardano-cli"
CNODE_PORT=6000
POOL_NAME="GUILD"
```

!!! important
    POOL_NAME is the name of folder that you will use when registering pools and starting node in core mode. This folder would typically contain your `hot.skey`,`vrf.skey` and `op.cert` files required. If the mentioned files are absent (expected if this is a fresh install), the node will automatically start in a relay mode.

#### Start the node

To test starting the node in interactive mode, we will make use of pre-built script `cnode.sh`. This script automatically determines whether to start the node as a relay or block producer (if the required pool keys are present in the `$CNODE_HOME/priv/pool/<POOL_NAME>` as mentioned above). If the `<MITHRIL_DOWNLOAD>` variable is set to 'Y' it will download the latest snapshot from a Mithril aggregator to speed up the blockchain synchronization. The script contains a user-defined variable `CPU_CORES` which determines the number of CPU cores the node will use upon start-up:

```bash
######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CPU_CORES=4            # Number of CPU cores cardano-node process has access to (please don't set higher than physical core count, 4 recommended)
```

Now let's test starting the node in interactive mode.

!!! note
    At this stage, upon executing `cnode.sh`, you are expected to see the live config and a line ending with `Listening on http://127.0.0.1:12798` - this is expected, as your logs are being written to `$CNODE_HOME/logs/node.json` . If so, you should be alright to return to your console by pressing Ctrl-C. The node will be started later using instructions below using systemd (Linux's service management). In case you receive any errors, please troubleshoot and fix those before proceeding.

```bash
cd "${CNODE_HOME}"/scripts
./cnode.sh
```

Press Ctrl-C to exit node and return to console.

#### Modify the node's config files

Now that you've tested the basic node operation, you might want to customise your config files (assuming you are in top-level folder , i.e. `cd "${CNODE_HOME}"`) :

1. files/config.json :
This file contains the logging configurations (tracers of to tune logging, paths for other genesis config files, address/ports on which the prometheus/EKG monitoring will listen, etc). Unless running more than one node on same machine (not recommended), you should be alright to use most of this file as-is. You might - however - want to double-check `PeerSharing` in this file, if using a relay node where you'd like connecting peers (marked as `"advertise": "true"` in topology.json) to be shared , you may turn this setting to `true`.

2. files/topology.json :
This file tells your node how to connect to other nodes (especially initially to start synching). You would want to update this file as below:

    * Update the `localRoots` > `accessPoints` section to include your local nodes that you want persistent connection against (eg: this could be your BP and own relay nodes) against definition where `trustable` is set to `true`.
    * If you want specific peers to be advertised on the network for discovery, you may set `advertise` to `true` for that peer group. You do NOT want to do that on BP
    * You'd want to update `localRoots` > `valency` (`valency` is the same as `hotValency`, not yet replaced since the example in cardano-node-wiki repo still suggests `valency`) to number of connections from your localRoots that you always want to keep active connection to for that node.
    * [Optional] - you can add/remove nodes from `publicRoots` section as well as `localRoots` > `accessPoints` as desired, tho defaults populated should work fine. On mainnet, we did add a few additional nodes to help add more redundancy for initial sync.
    * `useLedgerAfterSlot` tells the node to establish networking with nodes from defined peers to sync the node initially until reaching an absolute slot number, after which - it can start attempting to connect to peers registered as pool relays on the network. You may want this number to be relatively recent (eg: not have it 50 epochs old).
    * You can read further about topology file configuration [here](https://github.com/input-output-hk/cardano-node-wiki/blob/main/docs/getting-started/understanding-config-files.md#the-p2p-topologyjson-file)

!!! important
    On BP, You'd want to set `useLedgerAfterSlot` to `-1` for your Block Producing (Core) node - thereby, telling your Core node to remain in non-P2P mode, and ensure `PeerSharing` is to `false`.

The resultant topology file could look something like below:

``` json
{
  "bootstrapPeers": [
    {
      "address": "backbone.cardano.iog.io",
      "port": 3001
    },
    {
      "address": "backbone.mainnet.emurgornd.com",
      "port": 3001
    }
  ],
  "localRoots": [
    {
      "accessPoints": [
        {"address": "xx.xx.xx.xx", "port": 6000 },
        {"address": "xx.xx.xx.yy", "port": 6000 }
      ],
      "advertise": false,
      "trustable": true,
      "valency": 2
    },
    {
      "accessPoints": [
        {"address": "node-dus.poolunder.com",           "port": 6900, "pool": "UNDR",   "location": "EU/DE/Dusseldorf" },
        {"address": "node-syd.poolunder.com",           "port": 6900, "pool": "UNDR",   "location": "OC/AU/Sydney" },
        {"address": "194.36.145.157",                   "port": 6000, "pool": "RDLRT",  "location": "EU/DE/Baden" },
        {"address": "152.53.18.60",                     "port": 6000, "pool": "RDLRT",  "location": "NA/US/StLouis" },
        {"address": "148.72.153.168",                   "port": 16000, "pool": "AAA",   "location": "US/StLouis" },
        {"address": "78.47.99.41",                      "port": 6000, "pool": "AAA",    "location": "EU/DE/Nuremberg" },
        {"address": "relay1-pub.ahlnet.nu",             "port": 2111, "pool": "AHL",    "location": "EU/SE/Malmo" },
        {"address": "relay2-pub.ahlnet.nu",             "port": 2111, "pool": "AHL",    "location": "EU/SE/Malmo" },
        {"address": "relay1.clio.one",                  "port": 6010, "pool": "CLIO",   "location": "EU/IT/Milan" },
        {"address": "relay2.clio.one",                  "port": 6010, "pool": "CLIO",   "location": "EU/IT/Bozlano" },
        {"address": "relay3.clio.one",                  "port": 6010, "pool": "CLIO",   "location": "EU/IT/Bozlano" }
      ],
      "advertise": false,
      "trustable": false,
      "valency": 5,
      "warmValency": 10
    }
  ],
  "publicRoots": [
    {
      "accessPoints": [],
      "advertise": false
    }
  ],
  "useLedgerAfterSlot": 119160667
}
```

Once above two files are updated, since you modified the file manually - there is always a chance of human errors (eg: missing comma/quotes). Thus, we would recommend you to start the node interactively once again before proceeding.

```bash
cd "${CNODE_HOME}"/scripts
./cnode.sh
```

As before, ensure you do not have any errors in the console. To stop the node, hit Ctrl-C - we will start the node as systemd later in the document.

#### Start the submit-api

!!! note
    An average pool operator may not require `cardano-submit-api` at all. Please verify if it is required for your use as mentioned [here](../build.md#components). If - however - you do run submit-api for accepting sizeable transaction load, you would want to override the default MEMPOOL_BYTES by uncommenting it in cnode.sh.

`cardano-submit-api` is one of the binaries built as part of `cardano-node` repository and allows you to submit transactions over a Web API. To run this service interactively, you can use the pre-built script below (`submitapi.sh`). Make sure to update `submitapi.sh` script to change listen IP or Port that you'd want to make this service available on.

```bash
cd $CNODE_HOME/scripts
./submitapi.sh
```

To stop the process, hit Ctrl-C

#### Run as systemd service {: id="systemd"}

The preferred way to run the node (and submit-api) is through a service manager like systemd. This section explains how to setup a systemd service file.

**1. Deploy as a systemd service**  
Execute the below command to deploy your node as a systemd service (from the respective scripts folder):
```bash
cd $CNODE_HOME/scripts
./cnode.sh -d
# Deploying cnode.service as systemd service..
# cnode.service deployed successfully!!

./submitapi.sh -d
# Deploying cnode-submit-api.service as systemd service..
# cnode-submit-api deployed successfully!!

```

**2. Start the service**  
Run below commands to enable automatic start of service on startup and start it.
``` bash
sudo systemctl start cnode.service
sudo systemctl start cnode-submit-api.service
```

**3. Check status and stop/start commands** 
Replace `status` with `stop`/`start`/`restart` depending on what action to take.
``` bash
sudo systemctl status cnode.service
sudo systemctl status cnode-submit-api.service
```

!!! important
    In case you see the node exit unsuccessfully upon checking status, please verify you've followed the transition process correctly as documented below, and that you do not have another instance of node already running. It would help to check your system logs (`/var/log/syslog` for debian-based and `/var/log/messages` for Red Hat/CentOS/Fedora systems, you can also check `journalctl -f -u <service>` to examine startup attempt for services) for any errors while starting node.

You can use [gLiveView](../Scripts/gliveview.md) to monitor your node that was started as a systemd service.

```bash
cd $CNODE_HOME/scripts
./gLiveView.sh
```
