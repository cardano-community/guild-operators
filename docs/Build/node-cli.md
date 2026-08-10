!!! info "Reminder !!"
    Unless there is a very particular reason you want to compile (eg: running on non-popular OS flavor), you DO NOT "need" to build node binaries - `guild-deploy.sh` already provides an option to download pre-compiled binaries.
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

!!! note "cnode implementation"
    This page describes the `cnode` profile: Intersect's `cardano-node` and
    `cardano-cli`. It remains the default when `guild-deploy.sh -i` is omitted.
    See the [cnode deployment profile](cnode.md) for its repository layout,
    release metadata, and deployment contract. Dingo and Amaru use separate
    deployment, bootstrap, and launcher instructions in the
    [node implementation guide](node-implementations.md).

### Build Instructions

#### Prepare the build environment

The cnode `b` and `l` deployment flags install the manifest-selected Haskell
toolchain, C build dependencies, and libsodium source dependency:

```bash
./guild-deploy.sh -i cnode -n mainnet -s bl
```

Use the network and deployment arguments that match your existing cnode
installation. Source builds still require the upstream project prerequisites;
review the selected release notes before building.

#### Clone the cardano-node repository

Clone the cardano-node repository into `$HOME/git`:

``` bash
cd ~/git
git clone https://github.com/intersectmbo/cardano-node
cd cardano-node
```

#### Build Cardano Node

You can use the instructions below to build [cardano-node](https://github.com/intersectmbo/cardano-node).
Use the version pinned in the
[cnode release manifest](https://github.com/cardano-community/guild-operators/blob/master/files/node-implementations/cnode/release.json),
as this is what the deployment scripts verify and test.

``` bash
git fetch --tags --force --prune origin
git checkout --detach "$(
  jq -er '.version' "${CNODE_HOME}/files/cnode-release.json"
)"

cabal update
cabal build exe:cardano-node exe:cardano-submit-api \
  --disable-tests --disable-profiling
mkdir -p "$HOME/.local/bin"
install -m 0755 "$(cabal list-bin exe:cardano-node)" \
  "$HOME/.local/bin/cardano-node"
install -m 0755 "$(cabal list-bin exe:cardano-submit-api)" \
  "$HOME/.local/bin/cardano-submit-api"
```

#### Build Cardano CLI

cardano-cli is now released and built from its own repository; it is not a
package in the pinned cardano-node source tree. Clone
[cardano-cli](https://github.com/intersectmbo/cardano-cli), then use the
companion version pinned in the
[cnode release manifest](https://github.com/cardano-community/guild-operators/blob/master/files/node-implementations/cnode/release.json).

``` bash
cd ~/git
git clone https://github.com/intersectmbo/cardano-cli
cd cardano-cli
git fetch --tags --force --prune origin
git checkout --detach "$(
  jq -er '.companions["cardano-cli"].version | "cardano-cli-\(.)"' \
    "${CNODE_HOME}/files/cnode-release.json"
)"

cabal update
cabal build exe:cardano-cli --disable-tests --disable-profiling
mkdir -p "$HOME/.local/bin"
install -m 0755 "$(cabal list-bin exe:cardano-cli)" \
  "$HOME/.local/bin/cardano-cli"
```

The historical `cabal-build-all.sh` helper assumes the former combined source
layout and must not be used to build these separately pinned repositories.

#### Download pre-compiled Binary from Node release

Most operators should use `guild-deploy.sh -i cnode -s d`, which selects,
downloads, and verifies the release-manifest artifacts. The
[cardano-node release notes](https://github.com/intersectmbo/cardano-node/releases)
also publish upstream binaries for manual review.

### Verify

Execute `cardano-cli` and `cardano-node` to verify output as below (the exact version and git rev should depend on your checkout tag on github repository):

```bash
cardano-cli version
# cardano-cli 11.x.x - linux-x86_64 - ghc-9.6
# git rev <...>
cardano-node version
# cardano-node 11.x.x - linux-x86_64 - ghc-9.6
# git rev <...>
```

#### Update port number or pool name for relative paths

Before starting the node, review `CNODE_PORT` and `POOL_NAME` in
`$CNODE_HOME/scripts/env`. Allow the node-to-node port only from the networks
that should reach it. Normal deployments preserve script user variables;
`-s s` archives and replaces the scripts and their user-variable sections.

```bash
CNODEBIN="${HOME}/.local/bin/cardano-node"
CCLI="${HOME}/.local/bin/cardano-cli"
CNODE_PORT=6000
POOL_NAME="GUILD"
```

!!! important
    POOL_NAME is the name of folder that you will use when registering pools and starting node in core mode. This folder would typically contain your `hot.skey`,`vrf.skey` and `op.cert` files required. If the mentioned files are absent (expected if this is a fresh install), the node will automatically start in a relay mode.

#### Start the node

To test starting the node in interactive mode, we will make use of pre-built script `cnode.sh`. This script automatically determines whether to start the node as a relay or block producer (if the required pool keys are present in the `$CNODE_HOME/priv/pool/<POOL_NAME>` as mentioned above). If the `MITHRIL_DOWNLOAD` variable is set to 'Y' it will download the latest snapshot from a Mithril aggregator to speed up the blockchain synchronization. The script contains a user-defined variable `CPU_CORES` which determines the number of CPU cores the node will use upon start-up:

```bash
######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#CPU_CORES=4            # Number of CPU cores cardano-node process has access to (please don't set higher than physical core count, 4 recommended)
```

Now let's test starting the node in interactive mode.

```bash
cd "${CNODE_HOME}"/scripts
./cnode.sh
```

To install the node's systemd unit, use `./cnode.sh -d` or the explicit
`./cnode.sh systemd install` form. The same script owns
`systemd remove` and `systemd status`; the former central
`deploy-as-systemd.sh` script has been removed.

You should see logs flooding your screen (dont worry, that is expected) - and perhaps also include warn/errors to connect to some peers depending on your topology and remote peer status. If the node is running for few mins (i.e. you do not get returned to prompt), Press Ctrl-C to exit node and return to console.

#### Modify the node's config files

The deployed `${CNODE_HOME}/files/config.json` contains the network-specific
genesis paths, tracing, logging, mempool, and Prometheus settings. Start with
the template installed for the selected network; do not copy a mainnet config
onto preprod, preview, or Guild. The current templates do not define a
`PeerSharing` config key.

`${CNODE_HOME}/files/topology.json` defines P2P peer selection:

- `localRoots[].accessPoints` lists peers for persistent connections, such as
  the operator's block producer and relays.
- `hotValency` is the target number of active connections from that local-root
  group. `warmValency`, when present, is the target number of warm peers.
- `bootstrapPeers` provide initial peers before ledger peer selection starts.
- `publicRoots` contains additional manually managed public peers.
- `advertise` controls whether peers in that group may be shared. Keep it
  `false` on a block producer.
- `useLedgerAfterSlot` is the absolute slot after which ledger peers may be
  used. `-1` disables ledger peers; it does not disable P2P networking.

For a relay, retain the installed network's bootstrap/public peers and replace
the placeholder trusted `localRoots` with the operator's own nodes. Keep each
group's `hotValency` no greater than its number of access points.

For a block producer, a minimal topology containing only its relays can look
like this:

``` json
{
  "bootstrapPeers": [],
  "localRoots": [
    {
      "accessPoints": [
        {"address": "yy.yy.yy.yy", "port": 6000, "description": "Relay1"},
        {"address": "zz.zz.zz.zz", "port": 6000, "description": "Relay2"}
      ],
      "advertise": false,
      "trustable": true,
      "hotValency": 2
    }
  ],
  "publicRoots": [
    {
      "accessPoints": [],
      "advertise": false
    }
  ],
  "useLedgerAfterSlot": -1
}
```

This keeps the block producer on trusted relay connections while disabling
bootstrap, public, and ledger peers. It remains a P2P topology.

For the complete schema and operational guidance, see the
[official P2P networking documentation](https://docs.cardano.org/about-cardano/explore-more/cardano-network/p2p-networking).

After editing either JSON file, validate its syntax and start the node
interactively before installing or restarting the service:

```bash
jq empty "${CNODE_HOME}/files/config.json" \
  "${CNODE_HOME}/files/topology.json"
cd "${CNODE_HOME}"/scripts
./cnode.sh
```

As before, ensure you do not have any critical errors in the console. To stop the node, hit Ctrl-C - we will start the node as systemd later in the document.

#### Start the submit-api

!!! note
    An average pool operator may not require `cardano-submit-api` at all.
    Verify whether it is required for your use as described
    [here](../build.md#components). Node mempool capacity is configured by
    `MempoolCapacityBytesOverride` in `${CNODE_HOME}/files/config.json`, not in
    `cnode.sh`; test any change against the pinned node release.

`cardano-submit-api` is built from the cardano-node repository and allows
transactions to be submitted over an HTTP API. To run it interactively, use
`submitapi.sh`. Its user variables control the listen address, API port, and
metrics port.

```bash
cd $CNODE_HOME/scripts
./submitapi.sh
```

To stop the process, hit Ctrl-C

#### Run as systemd service {: id="systemd"}

The preferred way to run the node (and submit-api) is through a service manager like systemd. This section explains how to setup a systemd service file.

**1. Deploy as a systemd service**

Execute the below command to deploy your node as a systemd service (from the respective scripts folder):
```bash
cd $CNODE_HOME/scripts
./cnode.sh -d
# Deploying cnode as systemd service..
# cnode.service deployed successfully!!

./submitapi.sh -d
# Deploying cnode-submit-api as systemd service..
# cnode-submit-api.service deployed successfully!!

```

**2. Start the service**

Installation already enables the units for startup. Start them explicitly
after validating configuration:
``` bash
sudo systemctl start cnode.service
sudo systemctl start cnode-submit-api.service
```

**3. Check status and stop/start commands**
Replace `status` with `stop`/`start`/`restart` depending on what action to take.
``` bash
sudo systemctl status cnode.service
sudo systemctl status cnode-submit-api.service
```

!!! important
    In case you see the node exit unsuccessfully upon checking status, please verify you've followed the transition process correctly as documented below, and that you do not have another instance of node already running. It would help to check your system logs, you can also check `sudo journalctl -f -xeu cnode` to examine startup attempt for services, and scroll up until you see output for node startup attempt) for any errors while starting node.

You can use [gLiveView](../Scripts/gliveview.md) to monitor your node that was started as a systemd service.

```bash
cd $CNODE_HOME/scripts
./gLiveView.sh
```
