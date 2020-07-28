!> Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

For the core node (block producer) the `cntoolsBlockCollector.sh` script can be run to monitor the json log file created by cardano-node for traces related to leader slots and block creation. Data collected is stored in a json file, one for each epoch. To view the collected data the main CNTools script is used.  

This collector does not in any way replace a proper database like db-sync but can be a good lightweight way of keeping track of slots assigned and if blocks were successfully created. It currently does not verify that the block created makes it onto the chain. If possible this will be added at a later stage.

* [Installation and Configuration](#installation-and-configuration)
* [View Collected Blocks](#view-collected-blocks)

#### Installation and Configuration
The script is best run as a background process. This can be accomplished in many ways but the preferred method is to run it as a  systemd service. A terminal multiplexer like tmux or screen could also be used but not covered here.

sudo/root access needed to configure systemd.

In this example normal output from the `cntoolsBlockCollector.sh` script is ignored. Error output is logged using syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. Other logging configurations are not covered here. 

**1. Create systemd service file**  
Replace `$USER` with the correct user for your system. Copy & paste all code below to create the service file.
``` bash
sudo bash -c 'cat <<EOF > /etc/systemd/system/cntools-blockcollector.service
[Unit]
Description=CNTools - Block Collector
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=10
User=$USER
WorkingDirectory=/opt/cardano/cnode/scripts
ExecStart=/opt/cardano/cnode/scripts/cntoolsBlockCollector.sh
SuccessExitStatus=143
StandardOutput=null
StandardError=syslog
SyslogIdentifier=cntools-blockcollector

[Install]
WantedBy=multi-user.target
EOF'
```

**2. Reload systemd**  
```
sudo systemctl daemon-reload
```
**3. Start block collector**  
Run below commands to enable automatic start of service on startup and start it.
```
sudo systemctl enable cntools-blockcollector.service
sudo systemctl start cntools-blockcollector.service
```
#### View Collected Blocks
Start CNTools and choose `Blocks [b]` to open the block viewer.  
Either select `Epoch` and enter the epoch you want to see a detailed view for or choose `Summary` to display leader slots, adopted blocks and invalid blocks for last x epochs.

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

+---------+--------------------------+-------+-------------------------------------------------------------------+
| Slot    | At                       | Size  | Hash                                                              |
+---------+--------------------------+-------+-------------------------------------------------------------------+
| 165619  | 2020-07-11 00:21:19 UTC  | 3     | d1b86acb88e3255ec400354629aa65e5be24c6561a5cbc3f3a04cdc3b1e2a8d1  |
| 165683  | 2020-07-11 00:22:23 UTC  | 3     | 2ce005b1fed86a877aaa58a40f730fcfb3d4876d4218d5ee5e790d89fafd7610  |
| 165696  | 2020-07-11 00:22:36 UTC  | 3     | 0678cb8e04021183f221df6f0ff73f9f9dc39a000c6163bd134d4ae86e9364b5  |
| 165786  | 2020-07-11 00:24:06 UTC  | 3     | 51dfad492f5384230d7b21ec1fee212bd07d79121b2494200fb8f836354ee2f3  |
| 165846  | 2020-07-11 00:25:06 UTC  | 3     | 25e02a42441e83602cc0119c18a6c19f4631fcff22393a3380cbd58d677e3e83  |
+---------+--------------------------+-------+-------------------------------------------------------------------+
```
