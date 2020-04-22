This document is built using [IOHK build instructions](https://github.com/input-output-hk/cardano-node/blob/master/doc/building-running.md) as base with additional info, which we can propose to add if it makes sense.

### Using Cabal

#### Cardano Node

The code in the Haskell node also requires that the development packages for a couple of Linux system libraries be installed:

The instructions for **Debian and Ubuntu** are identical.
``` bash
sudo apt-get update
sudo apt-get -y install curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux
```

If you're using **CentOS**, the corresponding packages will be:
``` bash
sudo yum update
sudo yum -y install curl pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs systemd-devel zlib-devel tmux
# You might need to create a symlink to /usr/lib64/libtinfo.so as per below if one does not already exist
# sudo ln -s $(ls -1 /usr/lib64/libtinfo.so* | tail -1) /usr/lib64/libtinfo.so
# sudo ln -s $(ls -1 /usr/lib64/libtinfo.so* | tail -1) /usr/lib64/libtinfo.so.5
```

The required versions are [GHC 8.6.5][ghc865] and [Cabal-3.0][cabal30].
You best get them with the Haskell installer tool [ghcup][ghcup].
``` bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
```
confirm 2x ENTER and type YES at the end to add ghcup to your PATH variable
Then restart your terminal session or execute 
``` bash
source ~/.ghcup/env
``` 
to use the ghcup command for the next steps

Now install and activate the required GHC version
``` bash
ghcup install 8.6.5
ghcup set 8.6.5
ghc --version
```

Finally the Cardano Node git repo can be cloned and the code built:
``` bash
git clone https://github.com/input-output-hk/cardano-node
cd cardano-node
cabal build all
```

Now you can copy the binaries into your ~/.local/bin folder (when part of the PATH variable).

```
cardano-node
cardano-cli
chairman
```

You can see the build location path from the last few output lines (starting with Linking) of `cabal build all` command.
For example, for cardano-cli 1.10.1 it is 
```
~/cardano-node/dist-newstyle/build/x86_64-linux/ghc-8.6.5/cardano-node-1.10.1/x/cardano-cli/build/cardano-cli/
```
#### Cardano DB Sync tool

Instructions below are for creating a local working postgresql instance. For now, we leave the best practices for postgres database to the user and focus on minimal relevant config for `cardano-db-sync` tool.

##### Set up a local Postgres Server:
``` bash
sudo yum install -y postgresql-server postgresql-server-devel postgresql-contrib postgresql-devel
sudo postgresql-setup initdb
# TODO: For consistency on this page, edit /var/lib/pgsql/data/pg_hba.conf to replace ident with md5 for localhost and 127.0.0.1 (except lines with replication)
sudo systemctl start postgresql
sudo systemctl enable postgresql
```
##### Build cardano-db-sync
To build instructions for cardano-db-sync tool will be similar to cardano-node:
``` bash
git clone https://github.com/input-output-hk/cardano-db-sync
cd cardano-db-sync
cabal build all
```
Now you can copy the cardano-db-sync binary to your ~/.local/bin folder as before using the output (scan for line starting with *Linking..*).

##### Create User in Postgres
Login to Postgres instance as superuser:
``` bash
echo $(whoami)
sudo su postgres
psql
```
Execute the below in psql prompt. Replace the username to be your OS user (output of `echo $(whoami)` command executed above) :
``` sql
CREATE ROLE <username> superuser;
CREATE USER <username>;
GRANT ROOT TO <username>;
ALTER USER <username> PASSWORD 'Password';
\q
```
Type `exit` at shell to return to your original user.

##### Verify Login to postgres instance
``` bash
export PGPASSFILE=/opt/cardano/cnode/priv/files/.pgpass
echo "localhost:5432:cexplorer_phtn:$(whoami):password" > $PGPASSFILE
chmod 0600 /opt/cardano/cnode/priv/.pgpass
psql -U $(whoami)
## TODO: Sample output
```

##### Prepare DB for db-sync-tool :
``` bash
# scripts/postgresql-setup.sh --dropdb #if exists already, will fail if it doesnt - thats OK
scripts/postgresql-setup.sh --createdb
# Password:
# Password:
# All good!
## Verify you can see "All good!" as above
```

Start cardano-db-sync tool:
``` bash
PGPASSFILE=/opt/cardano/cnode/priv/files/.pgpass cardano-db-sync --config /opt/cardano/cnode/files/ptn0.yaml --genesis-file /opt/cardano/cnode/files/genesis.json --socket-path /opt/cardano/cnode/sockets/pbft_node.socket --schema-dir schema/
```

You can use same instructions above to repeat and execute `cardano-db-sync-extended` as well.

To test, connect to postgres instance and execute commands as per below:
``` bash
export PGPASSFILE=/opt/cardano/cnode/priv/files/.pgpass
psql cexplorer_phtn
```
```postgres
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