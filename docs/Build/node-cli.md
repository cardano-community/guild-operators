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

echo -e "package cardano-crypto-praos\n  flags: -external-libsodium-vrf" > cabal.project.local
# On CentOS 7 (GCC 4.8.5) we should also do
# echo -e "package cryptonite\n  flags: -use_target_attributes" >> cabal.project.local

$CNODE_HOME/scripts/cabal-build-all.sh
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

##### Start a passive node

To test starting the node in interactive mode, you can use the pre-built script below (note that the config now uses `SimpleView` so you may not see much output):

```bash
cd $CNODE_HOME/scripts
./cnode.sh
```

##### Run as systemd service

The preferred way to run the node is through a service manager like systemd. This section explains how to setup a systemd service file.

**1. Create systemd service file** 
Replace `$USER` with the correct user for your system. Copy & paste all code below to create the service file.
``` bash
sudo bash -c "cat << 'EOF' > /etc/systemd/system/cnode.service
[Unit]
Description=Cardano Node
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=$USER
LimitNOFILE=1048576
WorkingDirectory=$CNODE_HOME/scripts
ExecStart=/bin/bash -l -c \"exec $CNODE_HOME/scripts/cnode.sh\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ardano-node.*.node0.socket | tr -s ' ' | cut -d ' ' -f2)\"
KillSignal=SIGINT
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=cnode
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
```

**2. Reload systemd and enable automatic start of service on startup**  
``` bash
sudo systemctl daemon-reload
sudo systemctl enable cnode.service
```

**3. Start the node**  
Run below commands to enable automatic start of service on startup and start it.
``` bash
sudo systemctl start cnode.service
```

**4. Check status and stop/start commands** 
Replace `status` with `stop`/`start`/`restart` depending on what action to take.
``` bash
sudo systemctl status cnode.service
```

You can use [sLiveView](Scripts/sliveview.md) to monitor your pool that was started as systemd, if you miss the LiveView functionality.
