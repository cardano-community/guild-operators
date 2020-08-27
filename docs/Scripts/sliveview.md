!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

**Simple LiveView - sLiveView** is a small utility to display an equivalent of LiveView interface that cardano-node users have accustomed to. This is useful when changing to `SimpleView` and moving to a systemd deployment - if you havnt so already - while looking out for a familiar UI to monitor node status of the node.

The tool is independent from other files and can run as a standalone utility that can be stopped/started without affecting the status of cardano-node.

##### Download & Setup

The tool in itself should only require a single file. If you've used [pre-reqs.sh](basics.md#pre-requisites), you can skip this part , as this is already set up for you.

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
+--------------------------------------+
|           Simple Node Stats          |
+---------------------+----------------+
| Name:                TESTPOOL - Core |
+---------------------+----------------+
| Version             |         1.19.0 |
+---------------------+----------------+
| Revision            |       49536693 |
+---------------------+----------------+
| Peers (Out / In)    |         8 / 16 |
+---------------------+----------------+
| Epoch / Block       |  213 / 4611703 |
+---------------------+----------------+
| Slot                |        6933466 |
+---------------------+----------------+
| Density             |            5 % |
+---------------------+----------------+
| Uptime (D:H:M:S)    |    13:02:43:16 |
+---------------------+----------------+
| Transactions        |          71814 |
+---------------------+----------------+
|  RUNNING IN BLOCK PRODUCER MODE! :)  |
+---------------------+----------------+
| KES PERIOD          |             53 |
+---------------------+----------------+
| KES REMAINING       |             53 |
+---------------------+----------------+
| SLOTS LED           |             61 |
+---------------------+----------------+
| BLOCKS FORGED       |             61 |
+---------------------+----------------+

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
nodename="TESTPOOL" # Change your node's name prefix here, 22 character limit!!!
refreshrate=2 # How often (in seconds) to refresh the view
config=$(ps -ef | grep "[c]ardano-node.*.config" | awk -F 'config ' '{print $2}' | awk '{print $1}') # example: /opt/cardano/cnode/files/config.json
if [[ -f "$config" ]]; then
  promport=$(jq -r '.hasPrometheus[1] //empty' "$config" 2>/dev/null)
else
  promport=12798
fi
```
