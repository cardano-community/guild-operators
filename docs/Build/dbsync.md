!!! danger "Important"
    An average pool operator may not require cardano-db-sync at all. Please verify if it is required for your use as mentioned [here](../build.md#components).  

    - Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.
    - The [Cardano DB Sync](https://github.com/intersectmbo/cardano-db-sync) relies on an existing PostgreSQL server. To keep the focus on building dbsync tool, and not how to setup postgres itself, you can refer to [Sample Local PostgreSQL Server Deployment instructions](../Appendix/postgres.md) for setting up a Postgres instance. Specifically, we expect the `PGPASSFILE` environment variable is set as per the instructions in the sample guide, for `db-sync` to be able to connect.
    - One of the biggest obstacles for user experience when running dbsync is ensuring you satisfy EACH of the points mentioned in System Requirements [here](https://github.com/intersectmbo/cardano-db-sync#system-requirements). Also, note that we do not advise running dbsync on mainnet if your RAM is below 48GB.


### Build Instructions

#### Clone the repository

Execute the below to clone the `cardano-db-sync` repository to `$HOME/git` folder on your system:

``` bash
cd ~/git
git clone https://github.com/intersectmbo/cardano-db-sync
cd cardano-db-sync
```

#### Build Cardano DB Sync

You can use the instructions below to build the latest release of `cardano-db-sync`.

``` bash
git fetch --tags --all
git pull
# Include the cardano-crypto-praos and libsodium components for db-sync
# On CentOS 7 (GCC 4.8.5) we should also do
# echo -e "package cryptonite\n  flags: -use_target_attributes" >> cabal.project.local
# Replace tag against checkout if you do not want to build the latest released version
git checkout $(curl -sLf https://api.github.com/repos/intersectmbo/cardano-db-sync/releases/latest | jq -r .tag_name)
# Use `-l` argument if you'd like to use system libsodium instead of IOG fork of libsodium while compiling
$CNODE_HOME/scripts/cabal-build-all.sh
```
The above would copy the `cardano-db-sync` binary into `~/.local/bin` folder.

#### Prepare DB for sync

Now that binaries are available, let's create our database (when going through breaking changes, you may need to use `--recreatedb` instead of `--createdb` used for the first time. Again, we expect that `PGPASSFILE` environment variable is already set (refer to the top of this guide for sample instructions):

``` bash
cd ~/git/cardano-db-sync
# scripts/postgresql-setup.sh --dropdb #if exists already, will fail if it doesnt - thats OK
scripts/postgresql-setup.sh --createdb
# Password:
# Password:
# All good!
```

Verify you can see "All good!" as above!

#### Create Symlink to schema folder

DBSync instance requires the schema files from the git repository to be present and available to the dbsync instance. You can either clone the `~/git/cardano-db-sync/schema` folder OR create a symlink to the folder and make it available to the startup command we will be using. We will use the latter in sample below:

``` bash
ln -s ~/git/cardano-db-sync/schema $CNODE_HOME/guild-db/schema
```

#### Restore using Snapshot

If you're running a mainnet/preview/preprod instance of dbsync, you might want to consider use of dbsync snapshots as documented [here](https://github.com/intersectmbo/cardano-db-sync/blob/master/doc/state-snapshot.md). The snapshot files as of recent epoch are available via links in [release notes](https://github.com/intersectmbo/cardano-db-sync/releases).

At high-level, this would involve steps as below (read and update paths as per your environment):

``` bash

# Replace the actual link below with the latest one from release notes
wget https://update-cardano-mainnet.iohk.io/cardano-db-sync/13/db-sync-snapshot-schema-13-block-7622755-x86_64.tgz
rm -rf ${CNODE_HOME}/guild-db/ledger-state ; mkdir -p ${CNODE_HOME}/guild-db/ledger-state
cd -; cd ~/git/cardano-db-sync
scripts/postgresql-setup.sh --restore-snapshot /tmp/dbsyncsnap.tgz ${CNODE_HOME}/guild-db/ledger-state
# The restore may take a while, please be patient and do not interrupt the restore process. Once restore is successful, you may delete the downloaded snapshot as below:
#   rm -f /tmp/dbsyncsnap.tgz

```

#### Test running dbsync manually at terminal

In order to verify that you can run dbsync, before making a start - you'd want to ensure that you can run it interactively once. To do so, try the commands below:

``` bash
cd $CNODE_HOME/scripts
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
./dbsync.sh
```

You can monitor logs if needed via parallel session using `tail -10f $CNODE_HOME/logs/dbsync.json`. If there are no error, you would want to press Ctrl-C to stop the dbsync.sh execution and deploy it as a systemd service. To do so, use the commands below (the creation of file is done using `sudo` permissions, but you can always deploy it manually):

``` bash
cd $CNODE_HOME/scripts
./dbsync.sh -d
# Deploying cnode-dbsync.service as systemd service..
# cnode-dbsync.service deployed successfully!!
```

Now to start dbsync instance, you can run `sudo systemctl start cnode-dbsync`

!!! warning "Note"

    Note that dbsync while syncs, it might defer creation of indexes/constraints to speed up initial catch up. Once relatively closer to tip, this will initiate creation of indexes - which can take a while in background. Thus, you might notice the query timings right after reaching to tip might not be as good.

## Update DBSync

Updating dbsync can have different tasks depending on the versions involved. We attempt to briefly explain the tasks involved:

- Shutdown dbsync (eg: `sudo systemctl stop cnode-dbsync`)
- Update binaries (either download pre-compiled binaries via [guild-deploy.sh](../basics.md#pre-requisites) or using build instructions above)
- Go to your git folder, pull and checkout to latest version as in example below (if you were to switch to `13.1.1.3`):

    ``` bash
    cd ~/git/cardano-db-sync
    git pull
    git checkout 13.1.1.3
    ```

- If going through major version update (eg: 13.x.x.x to 14.x.x.x), you might need to [rebuild and resync db from scratch](#prepare-db-for-sync), you may still follow the section to restore using snapshot to save some time (as long as you use a compatible snapshot).
- If the underlying `cardano-node` version has changed (specifically if it's `ledger-state` schema is different), you'd also need to clear the ledger-state directory (eg: `rm -rf $CNODE_HOME/guild-db/ledger-state`)
- Test that `dbsync.sh` starts up fine manually as described above. If it does, stop it and go ahead with startup of systemd service (i.e. `sudo systemctl start cnode-dbsync`)

### Validation

To validate, connect to your `postgres` instance and execute commands as per below:

``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
psql cexplorer
```

You should be at the `psql` prompt, you can check the tables and verify they're populated:

``` sql
\dt
select * from meta;
```

A sample output of the above two commands may look like below (the number of tables and names may vary between versions):

```
cexplorer=# \dt
List of relations
 Schema |           Name            | Type  | Owner
--------+---------------------------+-------+-------
 public | ada_pots                  | table | centos
 public | admin_user                | table | centos
 public | block                     | table | centos
 public | delegation                | table | centos
 public | delisted_pool             | table | centos
 public | epoch                     | table | centos
 public | epoch_param               | table | centos
 public | epoch_stake               | table | centos
 public | ma_tx_mint                | table | centos
 public | ma_tx_out                 | table | centos
 public | meta                      | table | centos
 public | orphaned_reward           | table | centos
 public | param_proposal            | table | centos
 public | pool_hash                 | table | centos
 public | pool_meta_data            | table | centos
 public | pool_metadata             | table | centos
 public | pool_metadata_fetch_error | table | centos
 public | pool_metadata_ref         | table | centos
 public | pool_owner                | table | centos
 public | pool_relay                | table | centos
 public | pool_retire               | table | centos
 public | pool_update               | table | centos
 public | pot_transfer              | table | centos
 public | reserve                   | table | centos
 public | reserved_ticker           | table | centos
 public | reward                    | table | centos
 public | schema_version            | table | centos
 public | slot_leader               | table | centos
 public | stake_address             | table | centos
 public | stake_deregistration      | table | centos
 public | stake_registration        | table | centos
 public | treasury                  | table | centos
 public | tx                        | table | centos
 public | tx_in                     | table | centos
 public | tx_metadata               | table | centos
 public | tx_out                    | table | centos
 public | withdrawal                | table | centos
(37 rows)



select * from meta;
 id |     start_time      | network_name
----+---------------------+--------------
  1 | 2017-09-23 21:44:51 | mainnet
(1 row)
```
