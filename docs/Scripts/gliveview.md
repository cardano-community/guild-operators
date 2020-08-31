!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

**Guild LiveView - gLiveView** is a utility to display an equivalent subset of LiveView interface that cardano-node users have grown accustomed to. This is useful when changing to `SimpleView` and moving to a systemd deployment - if you haven't done so already - while looking for a familiar UI to monitor the node status.

The tool is independent from other files and can run as a standalone utility that can be stopped/started without affecting the status of cardano-node.

##### Download & Setup

The tool in itself should only require a single file. If you've used [prereqs.sh](basics.md#pre-requisites), you can skip this part , as this is already set up for you.

?> For those who follow guild's [folder structure](basics.md#folder-structure) and do not wish to run prereqs.sh, you can run the below in `$CNODE_HOME/scripts` folder

To download the script:
```bash
curl -s -o gLiveView.sh curl -s -o gLiveView.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/gLiveView.sh
chmod 755 gLiveView.sh
```

##### Startup

For most standard deployments, this should lead you to a stage where you can now start running gLiveView.sh - it will automatically detect when you're running as a Core or Relay and show fields accordingly, a sample output below from both core and relay (colors stripped from demo):

```bash
    >> Cardano Node - Core : 1.19.0 [4814003f] <<
┌────────────────────────────────────────────────────┐
│ Uptime: 7 days 01:06:54                            │
├----------------------------------------------------┤
│ Epoch 214 [55.8%] (node)                           │
│ 2 days 05:02:47 until epoch boundary (chain)       │
│ ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖ │
│                                                    │
│ Block   : 4631181           Tip (ref)  : 7325833   │
│ Slot    : 241026            Tip (node) : 7325826   │
│ Density : 4.945             Tip (diff) : -7 :)     │
├----------------------------------------------------┤
│ Processed TX     : 40219                 In / Out  │
│ Mempool TX/Bytes : 1 / 429       Peers : 4 / 6     │
├────────────────────────────────────────────────────┤
│ KES current/remaining   : 56 / 51                  │
│ KES expiration date     : 2020-11-13 09:44:53 Z    │
├----------------------------------------------------┤
│                           IsLeader/Adopted/Missed  │
│ Blocks since node start : 53 / 52 / 1              │
│ Blocks this epoch       : 21 / 21 / 0              │
└────────────────────────────────────────────────────┘
 [esc/q] Quit | [p] Peer Analysis      Guild LiveView
```
```bash
    >> Cardano Node - Relay : 1.19.0 [4814003f] <<
┌────────────────────────────────────────────────────┐
│ Uptime: 06:46:13                                   │
├----------------------------------------------------┤
│ Epoch 214 [55.8%] (node)                           │
│ 2 days 04:58:32 until epoch boundary (chain)       │
│ ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖ │
│                                                    │
│ Block   : 4631191           Tip (ref)  : 7326088   │
│ Slot    : 241263            Tip (node) : 7326063   │
│ Density : 4.942             Tip (diff) : -25 :)    │
├----------------------------------------------------┤
│ Processed TX     : 2349                  In / Out  │
│ Mempool TX/Bytes : 1 / 4323      Peers : 79 / 19   │
├────────────────────────────────────────────────────┤
│ OUT   RTT : Peers / Percent - 2020-08-31 16:44:23 Z│
│    0-50ms :    11 / 65%   ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▖▖▖▖▖▖▖▖▖│
│  50-100ms :     3 / 18%   ▌▌▌▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖│
│ 100-200ms :     2 / 12%   ▌▌▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖│
│   200ms < :     1 / 6%    ▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖│
│   Average : 61 ms                                  │
├----------------------------------------------------┤
│ Peers Total / Unreachable / Skipped : 17 / 0 / 0   │
├----------------------------------------------------┤
│ In    RTT : Peers / Percent                        │
│    0-50ms :    30 / 71%   ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▖▖▖▖▖▖▖│
│  50-100ms :     1 / 2%    ▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖│
│ 100-200ms :     9 / 21%   ▌▌▌▌▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖│
│   200ms < :     2 / 5%    ▌▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖▖│
│   Average : 62 ms                                  │
├----------------------------------------------------┤
│ Peers Total / Unreachable / Skipped : 71 / 29 / 0  │
└────────────────────────────────────────────────────┘
 [esc/q] Quit | [p] Peer Analysis      Guild LiveView
              | [h] Hide Peer Analysis

```


##### Troubleshooting/Customisations

In case you run into trouble while running the script, you might want to edit `gLiveView.sh` and look at user variables below. You can override the values if the automatic detection do not provide the right information, but we would appreciate if you could also notify us by raising an issue against github repo:

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
