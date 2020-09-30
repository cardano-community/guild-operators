> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

#### Build Instructions {docsify-ignore}

##### Clone the repository

Execute the below to clone the cardano-node repository to $HOME/git folder on your system:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-node
cd cardano-node
```

##### Build Cardano Node

You can use the instructions below to build the cardano-node, same steps can be executed in future to update the binaries (replacing appropriate tag) as well.

``` bash
git fetch --tags --all
# Replace release 1.19.0 with the version/branch/tag you'd like to build
git pull
git checkout 1.19.0

# The "-o" flag against script below will download cabal.project.local to depend on system libSodium package, and include cardano-address and bech32 binaries to your build
$CNODE_HOME/scripts/cabal-build-all.sh -o
```

The above would copy the binaries built into `~/.cabal/bin` folder.

##### Verify

Execute cardano-cli and cardano-node to verify output as below:

```bash
cardano-cli version
# cardano-cli 1.19.0 - linux-x86_64 - ghc-8.6
# git rev 4814003f14340d5a1fc02f3ac15437387a7ada9f
cardano-node version
# cardano-node 1.19.0 - linux-x86_64 - ghc-8.6
# git rev 4814003f14340d5a1fc02f3ac15437387a7ada9f
```

##### Update port number or pool name for relative paths

Before you go ahead with starting your node, you may want to update values for CNODE_PORT in `$CNODE_HOME/scripts/cnode.sh`. Note that it is imperative for operational relays and pools to ensure that the port mentioned is opened via firewall to the destination your node is supposed to connect from. Update your network/firewall configuration accordingly. Future executions of prereqs.sh will preserve and not overwrite these values.

```bash
## Static (content that will not be overwritten by prereqs.sh)
## Begin

POOL_NAME="GUILD"
CNODE_PORT=6000
POOL_DIR="$CNODE_HOME/priv/pool/$POOL_NAME"
```

> POOL_NAME is the name of folder that you will use when registering pools and starting node in core mode. This folder would typically contain your `hot.skey`,`vrf.skey` and `op.cert` files required. If the mentioned files are absent, the node will automatically start in a passive mode.

##### Start the node

To test starting the node in interactive mode, you can use the pre-built script below (note that the config now uses `SimpleView` so you may not see much output):

```bash
cd $CNODE_HOME/scripts
./cnode.sh
```

##### Run as systemd service

The preferred way to run the node is through a service manager like systemd. This section explains how to setup a systemd service file.

**1. Deploy as a systemd service**  
Execute the below command to deploy your node as a systemd service (from the respective scripts folder):
```bash
cd $CNODE_HOME/scripts
./deploy-as-systemd.sh
```

**2. Start the node**  
Run below commands to enable automatic start of service on startup and start it.
``` bash
sudo systemctl start cnode.service
```

**3. Check status and stop/start commands** 
Replace `status` with `stop`/`start`/`restart` depending on what action to take.
``` bash
sudo systemctl status cnode.service
```

?> In case you see the node exit unsuccessfully upon checking status, please verify you've followed the transition process correctly as documented below, and that you do not have another instance of node already running. It would help to check your system logs (/var/log/syslog for debian-based and /var/log/messages for redhat/CentOS/Fedora systems) for any errors while starting node.

You can use [gLiveView](Scripts/gliveview.md) to monitor your pool that was started as systemd, if you miss the LiveView functionality.

##### Steps to transition from LiveView in tmux to systemd setup

If you've followed guide from this repo previously and would like to transfer to systemd usage, please checkout the steps below:

1. Stop previous instance of node if already running (eg: in tmux)
2. Run `prereqs.sh`, but remember to preserve your customisations to cnode.sh, topology.json, env files (you can also compare and update cnode.sh and env files from github repo).
3. Follow the instructions [above](#run-as-systemd-service) to setup your node as a service and start it using systemctl as directed.
4. If you need to monitor via interactive terminal as before, use [gLiveView](Scripts/gliveview.md).
