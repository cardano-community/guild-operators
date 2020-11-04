!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

`logMonitor.sh` is a general purpose json log monitoring script for traces created by cardano-node. Currently it will look for traces related to leader slots and block creation but other uses could be added in the future. 

##### Block traces


For the core node (block producer) the `log.sh` script can be run to monitor the json log file created by cardano-node for traces related to leader slots and block creation. Data collected is stored in a json file, one for each epoch. To view the collected data the main CNTools script is used.  

This collector does not in any way replace a proper database like db-sync but can be a good lightweight way of keeping track of slots assigned and if blocks were successfully created.

* [Installation](#installation)
* [View Collected Blocks](#view-collected-blocks)

##### Installation
The script is best run as a background process. This can be accomplished in many ways but the preferred method is to run it as a systemd service. A terminal multiplexer like tmux or screen could also be used but not covered here.

Use the `deploy-as-systemd.sh` script to create a systemd unit file.
Output is logged using syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. Other logging configurations are not covered here. 

##### View Collected Blocks
Best viewed in CNTools but as it's saved as regular json any text/json viewer could be used.

Open CNTools and select `[b] Blocks` to open the block viewer.  
Either select `Epoch` and enter the epoch you want to see a detailed view for or choose `Summary` to display blocks for last x epochs.

If the node was elected to create blocks in the selected epoch it could look something like this:

**Summary**
```
+--------+---------------+-----------------+-----------------+
| Epoch  | Leader Slots  | Adopted Blocks  | Invalid Blocks  |
+--------+---------------+-----------------+-----------------+
| 92     | 21            | 21              | 0               |
| 91     | 30            | 30              | 0               |
| 90     | 36            | 36              | 0               |
| 89     | 37            | 37              | 0               |
| 88     | 26            | 26              | 0               |
| 87     | 25            | 25              | 0               |
| 86     | 25            | 25              | 0               |
| 85     | 37            | 37              | 0               |
| 84     | 30            | 30              | 0               |
| 83     | 26            | 26              | 0               |
+--------+---------------+-----------------+-----------------+
```
**Epoch**
```
Leader: 5  -  Adopted: 5  -  Invalid: 0

+----------+---------+--------------------------+-------+-------------------------------------------------------------------+
| Status   | Slot    | At                       | Size  | Hash                                                              |
+----------+---------+--------------------------+-------+-------------------------------------------------------------------+
| adopted  | 165619  | 2020-07-11 00:21:19 UTC  | 3     | d1b86acb88e3255ec400354629aa65e5be24c6561a5cbc3f3a04cdc3b1e2a8d1  |
| adopted  | 165683  | 2020-07-11 00:22:23 UTC  | 3     | 2ce005b1fed86a877aaa58a40f730fcfb3d4876d4218d5ee5e790d89fafd7610  |
| adopted  | 165696  | 2020-07-11 00:22:36 UTC  | 3     | 0678cb8e04021183f221df6f0ff73f9f9dc39a000c6163bd134d4ae86e9364b5  |
| adopted  | 165786  | 2020-07-11 00:24:06 UTC  | 3     | 51dfad492f5384230d7b21ec1fee212bd07d79121b2494200fb8f836354ee2f3  |
| adopted  | 165846  | 2020-07-11 00:25:06 UTC  | 3     | 25e02a42441e83602cc0119c18a6c19f4631fcff22393a3380cbd58d677e3e83  |
+----------+---------+--------------------------+-------+-------------------------------------------------------------------+
```
