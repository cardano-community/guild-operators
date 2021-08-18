!!! important
    An average pool operator may not require cardano-db-sync at all. Please verify if it is required for your use as mentioned [here](../build.md#components).  

    - Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.
    - The [Cardano DB Sync](https://github.com/input-output-hk/cardano-db-sync) relies on an existing PostgreSQL server. To keep the focus on building dbsync tool, and not how to setup postgres itself, you can refer to [Sample Local PostgreSQL Server Deployment instructions](../Appendix/postgres.md) for setting up a Postgres instance. Specifically, we expect the `PGPASSFILE` environment variable is set as per the instructions in the sample guide, for `db-sync` to be able to connect.


### Build Instructions

#### Clone the repository

Execute the below to clone the `cardano-db-sync` repository to `$HOME/git` folder on your system:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-db-sync
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
git checkout $(curl -s https://api.github.com/repos/input-output-hk/cardano-db-sync/releases/latest | jq -r .tag_name)
# Use `-l` argument if you'd like to use system libsodium instead of IOG fork of libsodium while compiling
$CNODE_HOME/scripts/cabal-build-all.sh
```
The above would copy the binaries into `~/.cabal/bin` folder.

#### Prepare DB for sync

Now that binaries are available, let's create our database (when going through breaking changes, you may need to use `--recreatedb` instead of `--createdb` used for the first time. Again, we expect that `PGPASSFILE` environment variable is already set (refer to the top of this guide for sample instructions):

``` bash
cd ~/git/cardano-db-sync
# scripts/postgresql-setup.sh --dropdb #if exists already, will fail if it doesnt - thats OK
scripts/postgresql-setup.sh --createdb
# Password:
# Password:
# All good!
## Verify you can see "All good!" as above
```

#### Start Synching
``` bash
cd ~/git/cardano-db-sync
cardano-db-sync-extended --config $CNODE_HOME/files/dbsync.json --socket-path $CNODE_HOME/sockets/node0.socket --state-dir $CNODE_HOME/guild-db/ledger-state --schema-dir schema/
```

You can use same instructions above to repeat and execute `cardano-db-sync` as well, but `cardano-db-sync-extended` provides additional views/useful data ready to be consumed by query layer. Note that synching entire blockchain from scratch could take a few hours.

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
