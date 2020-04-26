### DBSync tool

Cardano DB Sync tool relies on an existing PostgreSQL server.

#### Sample Local PostgreSQL Server Deployment instructions

These are sample PostgreSQL server deployment instructions used for reference while building Cardano DB Sync tool. These do not go into Best practices for deploying a secured instance, we would recommend you to customise the same as per your needs.

``` bash
# TODO: Add debian/Ubuntu specific commands
sudo yum install -y postgresql-server postgresql-server-devel postgresql-contrib postgresql-devel
sudo postgresql-setup initdb
# TODO: For consistency on this page, edit /var/lib/pgsql/data/pg_hba.conf to replace ident with md5 for localhost and 127.0.0.1 (except lines with replication)
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

This page assumes you've already set up cardano-noe and have the OS level dependencies satisfied.

#### Build cardano-db-sync

To build instructions for cardano-db-sync tool will be similar to cardano-node:
``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-db-sync
cd cardano-db-sync
cabal build all | tee build.log | grep ^Linking
```
Similar to before, you can copy the cardano-db-sync and cardano-db-sync-extended binary to your ~/.local/bin folder.

#### Create User in Postgres
Login to Postgres instance as superuser:
``` bash
echo $(whoami)
sudo su postgres
psql
```
Execute the below in psql prompt. Replace **<username>** and **PasswordYouWant** with your OS user (output of `echo $(whoami)` command executed above) and a password you'd like to authenticate to Postgres with:
``` sql
CREATE ROLE <username> superuser;
CREATE USER <username>;
GRANT ROOT TO <username>;
ALTER USER <username> PASSWORD 'PasswordYouWant';
\q
```

Type `exit` to return to your original user

#### Verify Login to postgres instance

``` bash
export PGPASSFILE=/opt/cardano/cnode/priv/.pgpass
echo "localhost:5432:cexplorer_phtn:$(whoami):PasswordYouWant" > $PGPASSFILE
chmod 0600 /opt/cardano/cnode/priv/.pgpass
psql -U $(whoami)
## TODO: Sample output
```

#### Prepare DB for cardano-db-sync :
``` bash
cd ~/git/cardano-db-sync
# scripts/postgresql-setup.sh --dropdb #if exists already, will fail if it doesnt - thats OK
scripts/postgresql-setup.sh --createdb
# Password:
# Password:
# All good!
## Verify you can see "All good!" as above
```

#### Start cardano-db-sync-tool
``` bash
cd ~/git/cardano-db-sync
PGPASSFILE=/opt/cardano/cnode/priv/.pgpass cardano-db-sync --config /opt/cardano/cnode/files/ptn0.yaml --genesis-file /opt/cardano/cnode/files/genesis.json --socket-path /opt/cardano/cnode/sockets/pbft_node.socket --schema-dir schema/
```

You can use same instructions above to repeat and execute `cardano-db-sync` as well, but [cardano-graphql](./graphql.md) uses `cardano-db-sync-extended`, so we'll stick to it

#### Validation

To validate, connect to postgres instance and execute commands as per below:

``` bash
export PGPASSFILE=/opt/cardano/cnode/priv/.pgpass
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
