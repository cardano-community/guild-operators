# Block Collector
For the core node(block producer) the `cntoolsBlockCollector.sh` script can be run to monitor the json log file created by cardano-node for traces related to leader slots and block creation. Data collected is stored in a json file, one for each epoch. To view the collected data the main CNTools script is used.  

This collector does not in any way replace a proper database like db-sync but can be a good lightweight way of keeping track of slots assigned and if blocks were successfully created. It currently does not verify that the block created makes it onto the chain. If possible this will be added at a later stage.

* [Prerequisites](#prerequisites)
* [Installation and Configuration](#installation-and-configuration)
* [View Collected Blocks](#view-collected-blocks)

### Prerequisites
It's assumed the [Pre-Requisites](../Common.md#dependencies-and-folder-structure-setup) have already been run.

As the block collector relies on the cardano-node log file for block traces the node configuration file has to be set up in a certain way for it to work. The file used comes from `CONFIG` parameter in `env` file.

* setupScribes configured with `scKind: FileSK` and `scFormat: ScJson` as well as a file extension of `.json`
* Blocks traces enabled. The script is looking for the following block traces in the log file, more block traces might be added in the future.  
`TraceNodeIsLeader TraceAdoptedBlock TraceForgedInvalidBlock`  

### Installation and Configuration
The script is best run as a background process. This can be accomplished in many ways but the preferred method is to run it as a  systemd service. A terminal multiplexer like tmux och screen could also be used but not covered here.

sudo/root access needed to configure systemd.

In this example normal output from the `cntoolsBlockCollector.sh` script is ignored. Error output is logged using syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. Other logging configurations are not covered here. 

**1. Create systemd service file**  
Replace `User` with the correct user for your system. Copy & paste all code below to create the service file.
```
sudo bash -c 'cat <<EOF > /etc/systemd/system/cntools-blockcollector.service
[Unit]
Description=CNTools - Block Collector
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=10
User=cardano
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

`sudo systemctl daemon-reload`

**3. Start block collector**  
Run below commands to enable automatic start of service on startup and start it.

```
sudo systemctl enable cntools-blockcollector.service
sudo systemctl start cntools-blockcollector.service
```

### View Collected Blocks
Start CNTools and choose **Blocks** [b] to open the block viewer.  
Enter the epoch you want to see or press `enter` to see the current epoch.

If the node was elected to create blocks in the selected epoch it could look something like this:

```
 >> BLOCKS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Current epoch: 92

Enter epoch to list (enter for current):

7 blocks created in epoch 92

Slot   At                       Size  Hash
82809  2020-06-26 12:15:18 UTC  3     bd86e0358fbc929daeb0a877052149bcb57e2b2d7da573ea025c78cc2ed6896b
82811  2020-06-26 12:15:22 UTC  3     fcd8e33f56b7a7d0c3a426570b8a1fba045266fd1a40ff63951c0f00fc7fbeb4
82829  2020-06-26 12:15:58 UTC  3     d0804a37eee8dfaaeb39a06e3373adef51459b1429b838288291014a69c37c04
82851  2020-06-26 12:16:42 UTC  3     d18c27edfdc2870d7922039d48764502f9b27b157b92b0dbe7171c35b1c94f5f
82859  2020-06-26 12:16:58 UTC  3     e9a1efdd3aef257ea07c55e102ad976c2259ee3cacc9a1d45f7c9dc55db189e9
82881  2020-06-26 12:17:42 UTC  3     d5bf67db9bcb6a26968b69dc9e65c540402bed985b46e98a925aa679adb51c88
82913  2020-06-26 12:18:46 UTC  3     1bf29f81d8087ded9f268a2b89aef2c7c6eeda077e5b84941aa4732bea1c3e0c
```