This page is for operators upgrading a deployment they already have. It starts
with the steps, in order, for a deployment made from `master` before this
release: CNTools 13, binaries in `~/.local/bin` and services set up by
`deploy-as-systemd.sh`. The sections after the steps explain each change in
more detail, and [Later upgrades](#later-upgrades) covers refreshes once you are
on the new layout.

!!! danger "Older scripts stop working until you upgrade"
    Older helper scripts check for updates when they start, and exit when they
    can't find the old file paths. Once this release is on `master`, on a
    deployment that hasn't been upgraded:

    - gLiveView, CNTools, the Mithril helper scripts and older copies of
      `blockPerf.sh` and `topologyUpdater.sh` exit at startup
    - CNCLI services fail at their next restart, because their units don't skip
      the check
    - the node, db-sync, the submit API and Ogmios keep running and restarting,
      as they have no update check

    Upgrade as below to fix this. To keep the old scripts working until you can,
    set this in the deployment's `scripts/env`:

    ``` bash
    UPDATE_CHECK="N"
    ```

### Upgrading from master {: #from-master}

The examples use a mainnet cnode deployment in `/opt/cardano/cnode`. Use your
own `-n`, `-t` and `-p` values and your own folder in the paths.

#### Before you start

- Upgrade one relay first, and check it before you move on to the other relays
  and the block producer.
- This release runs cardano-node 11.1.3 and cardano-cli 11.7.0.0. `master`
  installed 11.0.1 and 11.0.0.0, so the first run installs the new versions
  with `-s d`. The new node may replay the ledger when it restarts, which can
  take several hours.
- Run the commands as the OS user that owns the deployment, not as root. That
  user needs `sudo`.
- CNTools 14 needs Bash 4.4 or newer and a UTF-8 terminal.
- Back up `priv` (wallets, pools and keys), and note any changes you made by
  hand to `config.json`, `topology.json` or systemd units.

#### 1. Check what the upgrade would do

Run the new `guild-deploy.sh` straight from GitHub, because an older copy can't
do this upgrade. `-C` reports what the run would do and changes nothing:

``` bash
GUILD_DEPLOY=https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh
bash <(curl -sSfL "${GUILD_DEPLOY}") -C -s pd -n mainnet -t cnode -p /opt/cardano
```

It shows the versions it found, what will happen to your binaries, and anything
that would stop the run (see [When it stops](#when-it-stops)).

!!! note "Testing alpha before it reaches master"
    Until this release is on `master`, take `guild-deploy.sh` from `alpha` and
    add `-b alpha` to the commands in steps 1 and 2. The copy on `master`
    doesn't know the new layout.

    ``` bash
    GUILD_DEPLOY=https://raw.githubusercontent.com/cardano-community/guild-operators/alpha/scripts/cnode-helper-scripts/guild-deploy.sh
    ```

    The deployment then records `alpha`, so later refreshes stay on it. Pass
    `-b master` to move it back once the release is out.

#### 2. Deploy

``` bash
bash <(curl -sSfL "${GUILD_DEPLOY}") -s pd -n mainnet -t cnode -p /opt/cardano
```

`p` installs the OS packages this release needs, and `d` the pinned node and
CLI. Add the letters for anything else you run: `m` for the Mithril signer and
client, `c` for CNCLI, `o` for Ogmios and `w` for `cardano-hw-cli`. `l` is now
only needed to build from source. `guild-deploy.sh -h` lists every flag.

The run:

- installs the binaries in the deployment's own `/opt/cardano/cnode/bin` and
  leaves `~/.local/bin` as it is ([details](#per-deployment-binaries))
- refreshes the helper scripts, keeping the user variables you set in them, and
  moves the files this release no longer uses (`cntools.library`,
  `deploy-as-systemd.sh`, `topologyUpdater.sh`) into `scripts/archive`
- removes Topology Updater's systemd units, if you had them
- removes group and other write access under `priv`, which CNTools now requires
- writes `/opt/cardano/cnode/.deployment.json` with the network, folder and
  branch ([details](#branches-and-pins))
- keeps your `config.json` and `topology.json`; step 3 updates them

The running node isn't touched. From now on the deployment's own copy,
`/opt/cardano/cnode/scripts/guild-deploy.sh`, does every refresh, and it
remembers `-n`, `-t`, `-p` and `-b`.

#### 3. Move the configuration to Ouroboros Genesis

Mainnet, preprod and preview now run Ouroboros Genesis, because the public
bootstrap peers that nodes sync from are being shut down. Until the
configuration is updated, the deployer, `cnode.sh` and gLiveView warn about it.
Update it in place, with backups:

``` bash
/opt/cardano/cnode/scripts/guild-deploy.sh -s u
```

[Moving to Ouroboros Genesis](#genesis-mode) lists exactly what changes and how
to check the switch. The guild network stays in PraosMode.

#### 4. Restart the node

``` bash
sudo systemctl restart cnode
```

Watch it with `/opt/cardano/cnode/scripts/gLiveView.sh`, which shows ledger
replay progress. Your existing `cnode.service` keeps working, because it starts
`scripts/cnode.sh` as before.

#### 5. Check the other services

- The run lists units that still start binaries from `~/.local/bin`, with the
  command that moves each one, such as `mithril-signer.sh -d` for the Mithril
  signer.
- `deploy-as-systemd.sh` is gone. Each script now installs and manages its own
  unit; see [Services](#services).
- Restart the other services you run (db-sync, the submit API, Ogmios, CNCLI,
  the Mithril signer) when it suits you, so they pick up the new binaries and
  scripts.

#### 6. Commands you type yourself

Scripts and services find the deployment's binaries on their own. In a shell,
select the deployment first. This also sets the socket and network:

``` bash
source /opt/cardano/cnode/scripts/activate
cardano-cli version
```

The run lists the old copies in `~/.local/bin` that this deployment no longer
uses, and prints the command to remove them once no other deployment of the
same user needs them.

#### 7. CNTools and gLiveView

- **CNTools 14** is a new application under the same name. Start it with
  `./cntools.sh` in the scripts folder. The first start offers to install
  Charm Gum 2.0.2, which it needs, and fzf, which is optional, and asks whether
  you want Quick or Detailed flows. Wallets, pools and keys in `priv` are used
  as they are. Its settings and saved transactions are kept in
  `scripts/cntools/`, its work files in `/opt/cardano/cnode/.cntools/`. On an
  offline machine, install Gum before it goes offline. See the
  [CNTools guide](Scripts/cntools.md).
- **gLiveView 2.0** is one script for cardano-node, Dingo and Amaru. `?` shows
  the keys and help, and `!` opens the Notices page, which lists anything the
  deployment still needs. See the [gLiveView guide](Scripts/gliveview.md).

#### What is gone

| Before | Now |
| --- | --- |
| `deploy-as-systemd.sh` | each script's `-d` or `systemd install\|remove\|status`; see [Services](#services) |
| CNTools 13 and `cntools.library` | CNTools 14 in `scripts/cntools/`, started with `cntools.sh` |
| Topology Updater | removed, as P2P finds its own peers; the refresh archives the script and removes its units |
| `blockPerf.sh` and `logMonitor.sh` | still disabled under the current node tracing; openBlockPerf (`-s r`) instead |
| binaries shared in `~/.local/bin` | each deployment's own `bin` |
| `POOL_DIR` in `env` | the pool folder is always `${POOL_FOLDER}/${POOL_NAME}` |
| `scripts/.env_branch` | the branch is stored in `.deployment.json` |
| `guild-deploy.sh -u` | no longer needed, and ignored |

#### Going back {: #unintended}

This release keeps no copies of files at their old paths. To return to the old
layout, take `guild-deploy.sh` from the tag of the release you came from and
pass the same tag with `-b`. Don't mix scripts from the old and new layouts.
Available tags are listed
[on GitHub](https://github.com/cardano-community/guild-operators/tags). Check
the node release notes before you start an older node on a database a newer one
has used.

If a refresh replaced a file you wanted to keep, the previous copy is in
`/opt/cardano/cnode/scripts/archive`.

### Moving to Ouroboros Genesis {: #genesis-mode}

The public bootstrap peers that nodes in PraosMode sync from are being shut
down. Mainnet, preprod, preview, Dijkstra and Musashi therefore run Ouroboros
Genesis (`"ConsensusMode": "GenesisMode"`). A syncing node connects to many of
the largest pools listed in the network's peer snapshot and compares their
chains, instead of trusting a few bootstrap hosts. The Guild network stays in
PraosMode.

A refresh keeps an existing cnode deployment's `config.json` and
`topology.json` as they are and warns that they still need this release's
changes. gLiveView shows the same as a warning in its side rail and on its
Notices page (`!`), and `cnode.sh` logs it each time the node starts; the node
still starts, also under systemd. Refresh with `-s u` to move both over in
place, keeping everything else you set:

``` bash
/opt/cardano/cnode/scripts/guild-deploy.sh -s u
```

`-s u` makes these changes:

- `config.json`: GenesisMode; on mainnet and preview the network's
  `checkpoints.json`; the LedgerDB snapshot options moved into a
  `LedgerDB.Snapshots` block; on Dijkstra and Musashi the trust threshold the
  network's peer snapshot can meet.
- `topology.json`: `bootstrapPeers` removed. A relay layout gets
  `peerSnapshotFile` and the `useLedgerAfterSlot` that goes with the snapshot.
  A block producer layout (`useLedgerAfterSlot` -1) gets every local root
  marked `trustable`, because in GenesisMode it syncs only from trusted local
  roots. Peers are never added or removed.
- `peer-snapshot.json` and `checkpoints.json` are replaced on every refresh;
  they are network data, not settings.

The previous files stay next to them as `config.json_bkp<time>` and
`topology.json_bkp<time>`. `-s f` replaces both with the shipped files instead,
with the same backups, so your own settings have to be added back by hand.
If a block producer gets its pool keys or its relay-only topology later,
`cnode.sh` warns before the node starts when a local root is not trustable;
run `-s u` again to fix it.

Check the switch with `gLiveView.sh`, or with the node's metrics: the
`cardano_node_metrics_GSM_state_int` value is 0 while the node waits for
enough big ledger peers, 1 while it syncs and 2 once it has caught up.

An Amaru deployment gets the same peer snapshot in `files/peer-snapshot.json`
on every refresh. Its retired bootstrap peer is removed from `AMARU_PEER`, and
`AMARU_PEERS_SNAPSHOT` added, with `-s u`.

### Moving to per-deployment binaries {: #per-deployment-binaries}

Each deployment now keeps its binaries in its own `${NODE_HOME}/bin`, instead of
sharing `~/.local/bin` with every other deployment of the OS user. Deploying one
network can no longer change what another one runs, including `gum` and
`cardano-hw-cli`. The move happens in step 2 of
[Upgrading from master](#from-master).

#### What the deployment does for you

Tools you already have, such as `cncli`, are copied into `bin` unchanged. If
you leave out `-s d` and your versions are already new enough, all your
binaries are copied unchanged and no restart is needed. `~/.local/bin` is never
changed. The run lists any old copies this deployment no longer uses, and when
it's safe to remove them.

It also removes group and other write access from the folders and files under
`priv`, because CNTools now refuses to work with them otherwise. Read access is
left as it is.

#### When it stops {: #when-it-stops}

It checks first, and a stop leaves the deployment exactly as it was. It stops,
and says what to do, when:

- your node or CLI is older than the new scripts need and you left out `-s d`.
  New scripts on an old node would work until the next restart, and then the
  node wouldn't start
- `CNODEBIN` or `CCLI` in `env` points at a binary that's too old
- the deployment has a chain database, but this OS user has no `cardano-node`
- the target isn't writable, is low on disk, or can't run programs (a `noexec`
  mount)
- a Dingo or Amaru deployment still has its binaries in `~/.local/bin` and you
  left out `-s d`

#### Commands typed by hand

Guild scripts and services find their binaries without any change. For
commands you type yourself, select the deployment in that shell. This also sets
the socket and network, and sourcing another deployment's copy switches to it,
as [Several deployments under one user](basics.md#several-deployments)
describes:

``` bash
source /opt/cardano/cnode/scripts/activate
```

Without it, a migrated user's plain `cardano-cli` still runs the old copy in
`~/.local/bin` until you remove it. A new deployment has no copy there, so the
command isn't found.

#### Units that still use the old path

The run lists any that do. For example, an existing Mithril signer keeps
running from `~/.local/bin` until you regenerate its unit and environment with
`mithril-signer.sh -d`.

#### To undo a copy

Rename the folder and the deployment returns to the shared files. This doesn't
apply after `-s d`, because the old binaries would be below the new minimum:

``` bash
mv /opt/cardano/cnode/bin /opt/cardano/cnode/bin.disabled
```

### Services {: #services}

`deploy-as-systemd.sh` is gone. Each script installs and manages its own unit:

- `cnode.sh -d` (or `cnode.sh systemd install`) installs `cnode.service`, and
  `cnode.sh systemd remove|status|reload` manage it. `reload` sends SIGHUP to
  the running node.
- db-sync, the submit API, Ogmios and the Mithril signer have
  `<script> systemd install|remove|status`, and CNCLI has `cncli.sh -d [scope]`.

The [component-owned unit table](Build/node-implementations.md#component-owned-systemd-units)
lists them all. Installing a unit enables it but doesn't start the node.

Units made by the old script keep working. Running a script's `-d` replaces its
unit with one that carries an ownership marker, so one deployment's scripts
never remove another deployment's unit with the same name. Check a unit you
changed by hand before you replace it.

### Branches and pins {: #branches-and-pins}

`.deployment.json` in the deployment folder records the implementation,
network, folder, branch and service name. Later runs read it, so `-n`, `-t`,
`-p` and `-b` are only needed the first time, and a new `-b` is stored. The old
`scripts/.env_branch` is read once and archived.

Scripts never choose another branch on their own. `guild-deploy.sh` falls back
to `master` only when Git confirms that the recorded branch or tag no longer
exists; set `GUILD_DEPLOY_STRICT_REF=Y` to stop instead. Clone or verification
errors always stop the run.

Versions are pinned in `files/node-implementations/cnode/release.json`, and
every `-s d` download is checked against its SHA-256 checksum. Network
configurations come from `files/configs/cnode/<network>/`. The same deployer
installs Dingo and Amaru with `-i dingo` or `-i amaru`; see
[Node implementations](Build/node-implementations.md).

Older tags keep the old layout. To deploy one, take `guild-deploy.sh` from that
tag and pass the same tag with `-b`, for example `-b node-10.1.4`.

### Later upgrades {: #later-upgrades}

Once a deployment is on this layout, refresh it with its own copy. With no
flags it refreshes the scripts and keeps your binaries, configuration and user
variables:

``` bash
/opt/cardano/cnode/scripts/guild-deploy.sh
```

- Add `-s d` when a release changes the pinned node or CLI, then restart the
  node.
- Add `-s u` when a release changes the configuration; the run says so.
  `-s f` replaces `config.json` and `topology.json` with the shipped files
  instead (backups are kept), and you add your own changes back.
- `-s s` also overwrites the user variables in the helper scripts. Without it
  they are kept, and the previous copies go to `scripts/archive`.
- Add `-b <branch>` to move the deployment to another branch.

Check the upstream release notes before a node upgrade.

!!! warning "Beware"
    A cnode upgrade, especially across a major version, may revalidate or
    replay the ledger and take several hours. Test on a relay first and plan
    any database transfer while both source and target nodes are stopped. When
    a compatible snapshot is available, the
    [Mithril client](Scripts/mithril-client.md) can reduce replay time.

### Troubleshooting {: #troubleshooting}

- Binaries can be found in more than one place, for example in shell sessions
  and in systemd, especially if you downloaded some by hand before. Scripts use
  the deployment's `${CNODE_HOME}/bin`. To point them at a specific binary,
  uncomment and set these variables:

    - `env`: `CCLI`, `CNCLI`, `CNODEBIN`
    - `dbsync.sh`: `DBSYNCBIN` (if you use it)
    - `submitapi.sh`: `SUBMITAPIBIN` (if you use it)
    - `ogmios.sh`: `OGMIOSBIN` (if you use it)

- Old copies elsewhere in your `$PATH` can still run when you type a command.
  List them, and remove the ones nothing uses any more:

``` bash
whereis bech32 cardano-address cardano-cli cardano-db-sync cardano-hw-cli cardano-node cardano-submit-api cncli ogmios
```

- If gLiveView cannot connect after an upgrade, first distinguish a missing
  node process from an unavailable metrics endpoint. Set `DEPLOYMENT_HOME` to
  the affected cnode, Dingo, or Amaru root and inspect the implementation and
  service recorded in its manifest:

  ```bash
  DEPLOYMENT_HOME="${NODE_HOME:-${CNODE_HOME:?set NODE_HOME to the deployment root}}"
  NODE_IMPLEMENTATION="$(jq -er '.implementation' \
    "${DEPLOYMENT_HOME}/.deployment.json")"
  NODE_SERVICE="$(jq -er '.serviceName' \
    "${DEPLOYMENT_HOME}/.deployment.json")"

  case "${NODE_IMPLEMENTATION}" in
    cnode) "${DEPLOYMENT_HOME}/scripts/cnode.sh" systemd status ;;
    dingo|amaru) "${DEPLOYMENT_HOME}/scripts/${NODE_IMPLEMENTATION}.sh" status ;;
  esac
  sudo journalctl -fu "${NODE_SERVICE}.service"
  ```

  Dingo's default metrics endpoint is
  `http://127.0.0.1:12798/metrics`. Amaru's managed collector exposes
  `http://127.0.0.1:8889/metrics`; its launcher status includes the companion
  `${NODE_SERVICE}-metrics.service`, whose journal can be followed with:

  ```bash
  sudo journalctl -fu "${NODE_SERVICE}-metrics.service"
  ```

  cnode obtains its Prometheus address from its node configuration. A node
  that is replaying or revalidating the ledger may take time before all normal
  metrics are available. gLiveView hides individual unsupported metrics, but
  it requires a live process and a successful metrics scrape.

### Support/Improvements {: #support}

Hope the guide above helps you with the migration, but again - we could've missed some edge cases. If so, please report via chat in [Koios Discussions channel](https://t.me/CardanoKoios) or open an issue on github. Please DO NOT make edits to the script content based on forum/alternate guide/channels, while done with best intentions - there have been solutions put online that modify files unnecessarily instead of correcting configs and disabling updates, such actions will only cause trouble for future updates.
