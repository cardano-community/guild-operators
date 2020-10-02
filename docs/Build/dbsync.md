!> - An average pool operator may not require cardano-db-sync at all. Please verify if it is required for your use as mentioned [here](build.md#components)

> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.
>- Cardano DB Sync tool relies on an existing PostgreSQL server. To keep the focus on building dbsync tool, and not how to setup postgres itself, you can refer to [Sample Local PostgreSQL Server Deployment instructions](Appendix/postgres.md) for setting up Postgres instance.
>- The instructions are not maintained daily, but will be with major releases (expect a bit of time post new release to get those updated)

#### Build Instructions {docsify-ignore}

##### Clone the repository

Execute the below to clone the cardano-rest repository to $HOME/git folder on your system:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-db-sync
cd cardano-db-sync
```

##### Build Cardano DB Sync

You can use the instructions below to build the cardano-db-sync, same steps can be executed in future to update the binaries (replacing appropriate tag) as well.

``` bash
git fetch --tags --all
git pull
# Include the cardano-crypto-praos and libsodium components for db-sync
# On CentOS 7 (GCC 4.8.5) we should also do
# echo -e "package cryptonite\n  flags: -use_target_attributes" >> cabal.project.local
echo -e "package cardano-crypto-praos\n flags: -external-libsodium-vrf" > cabal.project.local
# Replace master with appropriate tag if you'd like to avoid compiling against master
git checkout 5.0.1
$CNODE_HOME/scripts/cabal-build-all.sh
```
The above would copy the binaries into `~/.cabal/bin` folder.

##### Prepare DB for cardano-db-sync :
``` bash
cd ~/git/cardano-db-sync
# scripts/postgresql-setup.sh --dropdb #if exists already, will fail if it doesnt - thats OK
scripts/postgresql-setup.sh --createdb
# Password:
# Password:
# All good!
## Verify you can see "All good!" as above
```

##### Start cardano-db-sync-tool
``` bash
cd ~/git/cardano-db-sync
PGPASSFILE=$CNODE_HOME/priv/.pgpass cardano-db-sync-extended --config $CNODE_HOME/files/config.json --socket-path $CNODE_HOME/sockets/node0.socket --schema-dir schema/
```

You can use same instructions above to repeat and execute `cardano-db-sync` as well, but [cardano-graphql](Build/graphql.md) uses `cardano-db-sync-extended`, so we'll stick to it

##### Validation

To validate, connect to postgres instance and execute commands as per below:

``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
psql cexplorer_phtn
```

You should be at the psql prompt, you can check the tables and verify they're populated:

``` sql
\dt
#            List of relations
# Schema |      Name      | Type  | Owner
#--------+----------------+-------+-------
# public | block          | table | <username>
# public | epoch          | table | <username>
# public | meta           | table | <username>
# public | schema_version | table | <username>
# public | slot_leader    | table | <username>
# public | tx             | table | <username>
# public | tx_in          | table | <username>
# public | tx_out         | table | <username>
#(8 rows)

select * from meta;
# id | protocol_const | slot_duration |     start_time      | network_name
#----+----------------+---------------+---------------------+--------------
#  1 |          43200 |         20000 | 2020-04-12 13:55:37 | pHTN
#(1 row)

select * from tx;
# id |                                hash                                | block | fee |     out_sum      | size
#----+--------------------------------------------------------------------+-------+-----+------------------+------
#  1 | \x26b63ce785b16fc53ba3ab882ac0e5342a77b33f355ba82982e3e2d5e05500df |     1 |   0 |       1000000000 |    0
#  2 | \xbd8f661658dabbb557d4b5e23264d34fda2a2304daccdac283e337581a88c479 |     1 |   0 |   62499975000000 |    0
#  3 | \x17fbf571b7d091e9cfb6853cd5fb603031831ce7e5e3acbb4b842960e90ba419 |     1 |   0 |   62499975000000 |    0
#  4 | \x3e7e3c1105d3bd76a2b5ae897e1b79b86c7834e68409e533afc318112405ff69 |     1 |   0 |   62499975000000 |    0
# ...
# (36 rows)
```
