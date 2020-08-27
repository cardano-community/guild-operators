!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

**Simple LiveView - sLiveView** is a small utility to display an equivalent subset of LiveView interface that cardano-node users have grown accustomed to. This is useful when changing to `SimpleView` and moving to a systemd deployment - if you haven't done so already - while looking for a familiar UI to monitor the node status.

The tool is independent from other files and can run as a standalone utility that can be stopped/started without affecting the status of cardano-node.

##### Download & Setup

The tool in itself should only require a single file. If you've used [prereqs.sh](basics.md#pre-requisites), you can skip this part , as this is already set up for you.

?> For those who follow guild's [folder structure](basics.md#folder-structure) and do not wish to run prereqs.sh, you can run the below in `$CNODE_HOME/scripts` folder

To download the script:
```bash
curl -s -o sLiveView.sh curl -s -o sLiveView.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/sLiveView.sh
chmod 755 sLiveView.sh
```

##### Startup

For most standard deployments, this should lead you to a stage where you can now start running sLiveView.sh - it will automatically detect when you're running as a Core or Relay and show fields accordingly, a sample output below:

```bash
./sLiveView.sh
+----------------------------------------+
|            Simple Node Stats           |
+-----------------------+----------------+
| Name:                  TESTPOOL - Core |
+-----------------------+----------------+
| Version               |         1.19.0 |
+-----------------------+----------------+
| Revision              |       49536693 |
+-----------------------+----------------+
| Peers (Out / In)      |         8 / 16 |
+-----------------------+----------------+
| Epoch / Slot          |   213 / 296153 |
+-----------------------+----------------+
| Block                 |        4612464 |
+-----------------------+----------------+
| Density               |         4.99 % |
+-----------------------+----------------+
| Uptime (D:H:M:S)      |    13:07:01:04 |
+-----------------------+----------------+
| Transactions          |          72528 |
+-----------------------+----------------+
| KES PERIOD            |             53 |
+-----------------------+----------------+
| KES REMAINING         |             53 |
+-----------------------+----------------+
| SLOTS LED             |             62 |
+-----------------------+----------------+
| BLOCKS FORGED/ADOPTED |          62/62 |
+-----------------------+----------------+

Press [CTRL+C] to stop...
```

##### Troubleshooting/Customisations

In case you run into trouble while running the script, you might want to edit `sLiveView.sh` and look at initialisation parameters below. You can hardcode the values if the commands do not provide the right information, but we would appreciate if you could also notify us by raising an issue against github repo:

```bash
#####################################
# Change variables below as desired #
#####################################

# The commands below will try to detect the information assuming you run single node on a machine. Please override values if they dont match your system

cardanoport=$(ps -ef | grep "[c]ardano-node.*.port" | awk -F 'port ' '{print $2}' | awk '{print $1}') # example value: 6000
nodename="TESTPOOL" # Change your node's name prefix here, 24 character limit!!!
refreshrate=2 # How often (in seconds) to refresh the view
config=$(ps -ef | grep "[c]ardano-node.*.config" | awk -F 'config ' '{print $2}' | awk '{print $1}') # example: /opt/cardano/cnode/files/config.json
ekghost=127.0.0.1
if [[ -f "${config}" ]]; then
  ekgport=$(jq -r '.hasEKG //empty' "${config}" 2>/dev/null)
else
  ekgport=12788
fi
```
