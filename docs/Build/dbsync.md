!!! danger "Important"
    An average pool operator may not require cardano-db-sync at all. Please verify if it is required for your use as mentioned [here](../build.md#components).

    - Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.
    - The [Cardano DB Sync](https://github.com/intersectmbo/cardano-db-sync) relies on an existing PostgreSQL server. To keep the focus on building dbsync tool, and not how to setup postgres itself, you can refer to [Sample Local PostgreSQL Server Deployment instructions](../Appendix/postgres.md) for setting up a Postgres instance. Specifically, we expect the `PGPASSFILE` environment variable is set as per the instructions in the sample guide, for `db-sync` to be able to connect.
    - Before provisioning a host, satisfy the
      [system requirements](https://github.com/intersectmbo/cardano-db-sync#system-requirements)
      for the manifest-pinned release. Database size, memory, and I/O
      requirements grow over time.
    - Guild installs the selected network configuration as
      `$CNODE_HOME/files/dbsync.json`. Its `insert_options.ledger` and
      `ledger_backend` settings materially affect resource use and available
      data; review the
      [db-sync configuration documentation](https://github.com/IntersectMBO/cardano-db-sync/blob/master/doc/configuration.md)
      before changing them.


### Build Instructions

#### Clone the repository

Execute the below to clone the `cardano-db-sync` repository to `$HOME/git` folder on your system:

``` bash
cd ~/git
git clone https://github.com/intersectmbo/cardano-db-sync
cd cardano-db-sync
```

#### Build Cardano DB Sync

You can use the instructions below to build the cnode-supported
`cardano-db-sync` release. Its version is managed alongside the other cnode
deployment artifacts in
`files/node-implementations/cnode/release.json` and installed at
`$CNODE_HOME/files/cnode-release.json`.

``` bash
git fetch --tags --force --prune origin
# Use the exact version selected by the cnode deployment manifest
DBSYNC_VERSION="$(
  jq -er '.companions["cardano-db-sync"].version' \
    "$CNODE_HOME/files/cnode-release.json"
)"
git checkout --detach "$DBSYNC_VERSION"
"$CNODE_HOME/scripts/cabal-build-all.sh"
```

Pass `-l` to the helper only when the build is intentionally configured to use
the system libsodium instead of the Guild-installed Intersect fork.
The above would copy the `cardano-db-sync` binary into `~/.local/bin` folder.

#### Prepare DB for sync

Now that binaries are available, let's create our database (when going through breaking changes, you may need to use `--recreatedb` instead of `--createdb` used for the first time. Again, we expect that `PGPASSFILE` environment variable is already set (refer to the top of this guide for sample instructions):

``` bash
cd ~/git/cardano-db-sync
# scripts/postgresql-setup.sh --dropdb #if exists already, will fail if it doesnt - thats OK
scripts/postgresql-setup.sh --createdb
# All good!
```

Verify you can see "All good!" as above!

#### Create Symlink to schema folder

DBSync instance requires the schema files from the git repository to be present and available to the dbsync instance. You can either clone the `~/git/cardano-db-sync/schema` folder OR create a symlink to the folder and make it available to the startup command we will be using. We will use the latter in sample below:

``` bash
ln -s "$HOME/git/cardano-db-sync/schema" "$CNODE_HOME/guild-db/schema"
```

If the destination already exists, inspect it before replacing it; do not
silently point a running deployment at schema files from a different release.

#### Restore using Snapshot

If you're running a mainnet, preview, or preprod instance, consider using a
db-sync snapshot as described in the
[state-snapshot guide](https://github.com/intersectmbo/cardano-db-sync/blob/master/doc/state-snapshot.md).
Intersect publishes compatible snapshots in the
[cardano-db-sync release notes](https://github.com/intersectmbo/cardano-db-sync/releases).
Only restore a snapshot documented for the selected network, db-sync release,
and configuration.

At a high level, the restore involves the steps below. Choose a snapshot from
the selected db-sync release notes that matches the network and configuration;
do not treat a moving example URL as a compatibility guarantee.

!!! danger "Restore replaces the database"
    With its default `RESTORE_RECREATE_DB=Y`, the pinned
    `postgresql-setup.sh --restore-snapshot` command drops and recreates the
    database named by `PGPASSFILE`. Stop db-sync, verify those credentials and
    the snapshot, and take any required PostgreSQL backup before running it.

``` bash
DBSYNC_SNAPSHOT_URL='<compatible snapshot URL from the release notes>'
curl -fL "$DBSYNC_SNAPSHOT_URL" -o /tmp/dbsyncsnap.tgz

# Stop db-sync first. Preserve any old ledger state until the restore succeeds.
sudo systemctl stop cnode-dbsync
if [[ -d "$CNODE_HOME/guild-db/ledger-state" ]]; then
  mv "$CNODE_HOME/guild-db/ledger-state" \
    "$CNODE_HOME/guild-db/ledger-state.backup.$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$CNODE_HOME/guild-db/ledger-state"

cd "$HOME/git/cardano-db-sync"
export PGPASSFILE="$CNODE_HOME/priv/.pgpass"
scripts/postgresql-setup.sh --restore-snapshot \
  /tmp/dbsyncsnap.tgz "$CNODE_HOME/guild-db/ledger-state"
```

The restore can take a long time; do not interrupt it. After validating the
restored service, remove the downloaded archive and any no-longer-needed
ledger-state backup deliberately.

#### Test running dbsync manually at terminal

In order to verify that you can run dbsync, before making a start - you'd want to ensure that you can run it interactively once. To do so, try the commands below:

``` bash
cd $CNODE_HOME/scripts
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
./dbsync.sh
```

You can monitor logs if needed via parallel session using `sudo journalctl -xeu cnode-dbsync -f`. If there are no errors, press Ctrl-C to stop the dbsync.sh execution and deploy it as a systemd service. To do so, use the commands below (the unit file is created using `sudo` permissions, but you can always deploy it manually):

``` bash
cd $CNODE_HOME/scripts
./dbsync.sh -d
# Deploying cnode-dbsync as systemd service..
# cnode-dbsync.service deployed successfully!!
```

Now to start dbsync instance, you can run `sudo systemctl start cnode-dbsync`

!!! warning "Note"

    Note that dbsync while syncs, it might defer creation of indexes/constraints to speed up initial catch up. Once relatively closer to tip, this will initiate creation of indexes - which can take a while in background. Thus, you might notice the query timings right after reaching to tip might not be as good.

## Update DBSync

Updating dbsync can have different tasks depending on the versions involved. We attempt to briefly explain the tasks involved:

- Shutdown dbsync (eg: `sudo systemctl stop cnode-dbsync`)
- Update binaries (either download the manifest-selected pre-compiled binary
  via [guild-deploy.sh](../basics.md#pre-requisites) or use the build
  instructions above).
- Fetch the repository and check out the version selected in the
  installed cnode release manifest:

    ``` bash
    cd ~/git/cardano-db-sync
    git fetch --tags --force --prune origin
    git checkout --detach "$(
      jq -er '.companions["cardano-db-sync"].version' \
        "$CNODE_HOME/files/cnode-release.json"
    )"
    ```

- If going through major version update (eg: 13.x.x.x to 14.x.x.x), you might need to [rebuild and resync db from scratch](#prepare-db-for-sync), you may still follow the section to restore using snapshot to save some time (as long as you use a compatible snapshot).
- If the underlying `cardano-node` version changes the ledger-state schema,
  stop db-sync and move the existing ledger-state directory to a timestamped
  backup before starting the new version. Remove that backup only after the
  migration or resync is validated.
- Test that `dbsync.sh` starts up fine manually as described above. If it does, stop it and go ahead with startup of systemd service (i.e. `sudo systemctl start cnode-dbsync`)

### Validation

To validate, connect to your `postgres` instance and execute commands as per below:

``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
psql cexplorer
```

At the `psql` prompt, check that tables exist and the recorded network matches
the deployment:

``` sql
\dt
select network_name from meta;
```

The exact table list varies by db-sync release and configuration.
