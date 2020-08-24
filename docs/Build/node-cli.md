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

To start the node in passive mode, you can use the pre-built script below:

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
WorkingDirectory=/opt/cardano/cnode/scripts
ExecStart=/bin/bash -l -c 'exec \"\$@\"' _ cnode.sh
KillSignal=SIGINT
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=cnode

[Install]
WantedBy=multi-user.target
EOF"
```

**2. Reload systemd and enable automatic start of service on startup**  
```
sudo systemctl daemon-reload
sudo systemctl enable cnode.service
```

**3. Modify configuration to run with view mode SimpleView**  
```
pushd $CNODE_HOME/files >/dev/null && \
tmpConfig=$(mktemp) && \
jq '.ViewMode = "SimpleView"' config.json > "${tmpConfig}" && mv -f "${tmpConfig}" config.json && \
popd >/dev/null
```

**4. Start the node**  
Run below commands to enable automatic start of service on startup and start it.
```
sudo systemctl start cnode.service
```

**5. Check status and stop/start commands** 
Replace `status` with `stop`/`start`/`restart` depending on what action to take.
```
sudo systemctl status cnode.service
```
