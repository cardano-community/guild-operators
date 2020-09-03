!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

**Guild LiveView - gLiveView** is a utility to display an equivalent subset of LiveView interface that cardano-node users have grown accustomed to. This is especially useful when moving to a systemd deployment - if you haven't done so already - while looking for a familiar UI to monitor the node status.

The tool is independent from other files and can run as a standalone utility that can be stopped/started without affecting the status of cardano-node.

##### Download & Setup

The tool in itself should only require a single file. If you've used [prereqs.sh](basics.md#pre-requisites), you can skip this part , as this is already set up for you.  
To get current epoch blocks, [cntoolsBlockCollector.sh](Scripts/cntools-blocks.md) script is needed. This is optional and **Guild LiveView** will function without it.

?> For those who follow guild's [folder structure](basics.md#folder-structure) and do not wish to run prereqs.sh, you can run the below in `$CNODE_HOME/scripts` folder

To download the script:
```bash
curl -s -o gLiveView.sh curl -s -o gLiveView.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/gLiveView.sh
chmod 755 gLiveView.sh
```

##### Startup

For most standard deployments, this should lead you to a stage where you can now start running `./gLiveView.sh` in the folder you downloaded the script (default location for cntools users would be `$CNODE_HOME/scripts`). Note that the script is smart enough to automatically detect when you're running as a Core or Relay and will show fields accordingly.  
A sample output from both core and relay(with peer analysis run):

![Core](https://raw.githubusercontent.com/cardano-community/guild-operators/images/gliveview-core.png)

![Relay](https://raw.githubusercontent.com/cardano-community/guild-operators/images/gliveview-relay.png)

##### Troubleshooting/Customisations

In case you run into trouble while running the script, you might want to edit `gLiveView.sh` and look at User Variables section shown below. You can override the values if the automatic detection do not provide the right information, but we would appreciate if you could also notify us by raising an issue against github repo:

```bash
######################################
# User Variables - Change as desired #
######################################

#CNODE_HOME="/opt/cardano/cnode"          # Override default CNODE_HOME path
#CNODE_PORT=6000                          # Override automatic detection of node port
NODE_NAME="Cardano Node"                  # Change your node's name prefix here, keep at or below 19 characters for proper formatting
REFRESH_RATE=2                            # How often (in seconds) to refresh the view
#CONFIG="${CNODE_HOME}/files/config.json" # Override automatic detection of node config path
EKG_HOST=127.0.0.1                        # Set node EKG host
#EKG_PORT=12788                           # Override automatic detection of node EKG port
#BLOCK_LOG_DIR="${CNODE_HOME}/db/blocks"  # CNTools Block Collector block dir set in cntools.config, override path if enabled and using non standard path
```
