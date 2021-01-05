!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

**Guild LiveView - gLiveView** is a utility to display an equivalent subset of LiveView interface that cardano-node users have grown accustomed to. This is especially useful when moving to a systemd deployment - if you haven't done so already - while looking for a familiar UI to monitor the node status.

The tool is independent from other files and can run as a standalone utility that can be stopped/started without affecting the status of cardano-node.

##### Download

If you've used [prereqs.sh](basics.md#pre-requisites), you can skip this part , as this is already set up for you. The tool rely on the common env configuration file.  
To get current epoch blocks, [cntoolsBlockCollector.sh](Scripts/cntools-blocks.md) script is needed. This is optional and **Guild LiveView** will function without it.

?> For those who follow guild's [folder structure](basics.md#folder-structure) and do not wish to run prereqs.sh, you can run the below in `$CNODE_HOME/scripts` folder

To download the script:

```bash
curl -s -o gLiveView.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/gLiveView.sh
curl -s -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
chmod 755 gLiveView.sh
```

##### Configuration & Startup

For most setups, it's enough to set `CNODE_PORT` in the `env` file. The rest of the variables should automatically be detected. If required, modify User Variables in `env` and `gLiveView.sh` to suit your environment. 

For most standard deployments, this should lead you to a stage where you can now start running `./gLiveView.sh` in the folder you downloaded the script (default location would be `$CNODE_HOME/scripts`). Note that the script is smart enough to automatically detect when you're running as a Core or Relay and will show fields accordingly.

The tool can be run in legacy mode with only standard ASCII characters for terminals with trouble displaying the box-drawing characters. Run `./gLiveView.sh -h` to show available command-line parameters or permanently set it directly in script.

A sample output from both core and relay(with peer analysis):

![Core](https://raw.githubusercontent.com/cardano-community/guild-operators/images/gliveview-core.png)

![Relay](https://raw.githubusercontent.com/cardano-community/guild-operators/images/gliveview-relay.png)

##### Description

**Upper main section**  
Displays live metrics gathered from EKG. Epoch number and progress is live from node while date calculation until epoch boundary is based on offline genesis parameters. Reference tip is also an offline calculation based on genesis values used to compare against the node tip to see how far of the tip(diff value) the node is. With current parameters a slot diff up to 40 from reference tip is considered good but it ussually stay below 30. In/Out peers show how many connections the node have established in and out.

**Core section**  
If the node is run as a core, identified by the 'forge-about-to-lead' EKG parameter, a second core section is displayed. This section contain current and remaining KES periods as well as a calculated date for the expiration. When getting close to expire date the values will change color. Blocks created by the node since node start is another metric shown in this section. If [CNCLI](Scripts/cncli.md) is activated to store blocks created in a blocklog DB, data from this blocklog is displayed. If not, blocks created is taken from EKG metrics.

**Peer analysis**  
A manual peer analysis can be triggered by key press `p`. A latency test will be done on incoming and outgoing connections to the node.  

Outgoing connections(peers in topology file), ping type used is done in this order:
1. cncli - If available, this gives the most accurate measure as it checks the entire handshake process against the remote peer.
2. tcptraceroute - Sends a TCP SYN package to ping the remote peer on the cardano-node port. Should give ~100% success rate.
3. ping - fallback method using ICMP ping against IP. Will only work if firewall of remote peer accept ICMP traffic.

For incoming connections, only ICMP ping is used as remote peer port is unknown. It's not uncommon to see many unreachable peers for incoming connections as it's a good security practice to disable ICMP in firewall.

Once the analysis is finished, it will display the RTTs for the peers and group them in ranges 0-50, 50-100, 100-200, 200<. The analysis is **NOT** live. Press `[h] Home` to go back to default view or `[i] Info` to show in-script help text. `Up` and `Down` arrow keys is used to select incoming or outgoing detailed list of IPs and their RTT value. If more than 8 peer connections are established for either incoming or outgoing, `Left (<)` and `Right (>)` arrow keys can be used to navigate the selected list. 

##### Troubleshooting/Customisations

In case you run into trouble while running the script, you might want to edit `env` & `gLiveView.sh` and look at User Variables section. You can override the values if the automatic detection do not provide the right information, but we would appreciate if you could also notify us by raising an issue against github repo:

**gLiveView.sh**
```bash
######################################
# User Variables - Change as desired #
######################################

NODE_NAME="Cardano Node"                   # Change your node's name prefix here, keep at or below 19 characters!
REFRESH_RATE=2                             # How often (in seconds) to refresh the view (additional time for processing and output may slow it down)
LEGACY_MODE=false                          # (true|false) If enabled unicode box-drawing characters will be replaced by standard ASCII characters
RETRIES=3                                  # How many attempts to connect to running Cardano node before erroring out and quitting
THEME="dark"                               # dark  = suited for terminals with a dark background
                                           # light = suited for terminals with a bright background
```
