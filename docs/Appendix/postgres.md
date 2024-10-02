These deployment instructions used for reference while building [cardano-db-sync](../Build/dbsync.md) tool, with the scope being ease of set up, and some tuning baselines for those who are new to Postgres DB.
It is recommended to customise these as per your needs for Production builds.

!!! important
    You'd find it pretty useful to set up ZFS on your system prior to setting up Postgres, to help with your IOPs throughput requirements. You can find sample install instructions [here](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html). You can set up your entire root mount to be on ZFS, or you can opt to mount a file as ZFS on "${CNODE_HOME}"

#### Install PostgreSQL Server

Execute commands below to set up Postgres Server

``` bash
# Determine OS platform
OS_ID=$( (grep -i ^ID_LIKE= /etc/os-release || grep -i ^ID= /etc/os-release) | cut -d= -f 2)
DISTRO=$(grep -i ^NAME= /etc/os-release | cut -d= -f 2)

if [ -z "${OS_ID##*debian*}" ]; then
  #Debian/Ubuntu
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
  RELEASE=$(lsb_release -cs)
  echo "deb [arch=amd64] http://apt.postgresql.org/pub/repos/apt/ ${RELEASE}"-pgdg main | sudo tee  /etc/apt/sources.list.d/pgdg.list
  sudo apt-get update
  sudo apt-get -y install postgresql-17 postgresql-server-dev-17 postgresql-contrib libghc-hdbc-postgresql-dev
  sudo systemctl enable postgresql
else
  echo "We have no automated procedures for this ${DISTRO} system"
fi
```

#### Tuning your instance

Before you start populating your DB instance using dbsync data, now might be a good time to put some thought on to baseline configuration of your postgres instance by editing `/etc/postgresql/17/main/postgresql.conf`.
Typically, you might find a lot of common standard practices parameters available in tuning guides. For our consideration, it would be nice to start with some baselines - for which we will use inputs from example [here](https://pgtune.leopard.in.ua/#/), which would need to be customised further to your environment and resources.

In a typical Koios [gRest] setup, we use below for *minimum* viable specs (i.e. 64GB RAM, > 8 CPUs, >16K IOPs for `ioping -q -S512M -L -c 10 -s8k .` output when postgres data directory is on ZFS configured with max arc of 4GB), we find the below configuration to be the best common setup:

| Parameter                        | Value                                 | Comment                                                                                                |
|----------------------------------|---------------------------------------|--------------------------------------------------------------------------------------------------------|
| data_directory                   | '/opt/cardano/cnode/guild-db/pgdb/17' | Move postgres data directory to ZFS mount at /opt/cardano/cnode, ensure it's writable by postgres user |
| effective_cache_size             | 8GB                                   | Be conservative as Node and DBSync by themselves will need ~32-40GB of RAM if ledger-state is enabled  |
| effective_io_concurrency         | 4                                     | Can go higher if you have substantially higher IOPs/IO throughputs                                     |
| lc_time                          | 'en_US.UTF-8'                         | Just to use standard server-side time formatting between instances, can adapt to your preferences      |
| log_timezone                     | 'UTC'                                 | For consistency, to avoid timezone confusions                                                          |
| maintenance_work_mem             | 512MB                                 | Helps with vacuum/index/foreign key maintainance (with 4 workers, it's set to max 2GB)                 |
| max_connections                  | 200                                   | Allow maximum of 200 connections, the koios connections are still controlled via postgrest db-pool     |
| max_parallel_maintenance_workers | 4                                     | Max workers postgres will use for maintainance                                                         |
| max_parallel_workers             | 4                                     | Max workers postgres will use across the system                                                        |
| max_parallel_workers_per_gather  | 2                                     | Parallel threads per query, do not increase to higher values as it will multiply memory usage          |
| max_wal_size                     | 4GB                                   | Used for WAL automatic checkpoints (disabled later)                                                    |
| max_worker_processes             | 4                                     | Maximum number of background processes system can support                                              |
| min_wal_size                     | 1GB                                   | Used for WAL automatic checkpoints (disabled later)                                                    |
| random_page_cost                 | 1.1                                   | Use higher value if IOPs has trouble catching up (you can use 4 instead of 1.1)                        |
| shared_buffers                   | 4GB                                   | Conservative limit to allow for node/dbsync/zfs memory usage                                           |
| timezone                         | 'UTC'                                 | For consistency, to avoid timezone confusions                                                          |
| wal_buffers                      | 16MB                                  | WAL consumption in shared buffer (disabled later)                                                      |
| work_mem                         | 16MB                                  | Base memory size before writing to temporary disk files                                                |

In addition to above, due to the nature of usage by dbsync (synching from node and restart traversing back to last saved ledger-state snapshot), we leverage data retention on blockchain - as we're not affected by loss of volatile information upon a restart of instance. Thus, we can relax some of the data retention and protection against corruption related settings, as those are IOPs/CPU Load Average impacts that the instance does not need to spend. We'd recommend setting 3 of those below in your `/etc/postgresql/17/main/postgresql.conf`:

| Parameter          | Value   |
|--------------------|---------|
| wal_level          | minimal |
| max_wal_senders    | 0       |
| synchronous_commit | off     |

Once your changes are done, ensure to restart postgres service using `sudo systemctl restart postgresql`.

#### Create User in Postgres

Login to Postgres instance as superuser:

``` bash
echo $(whoami)
# <user>
sudo su postgres
psql
```

Note the <user> returned as the output of `echo $(whoami)` command. Replace all instance of <user> in the documentation below.
Execute the below in psql prompt. Replace **<username>** and **PasswordYouWant** with your OS user (output of `echo $(whoami)` command executed above) and a password you'd like to authenticate to Postgres with:

``` sql
CREATE ROLE <user> SUPERUSER LOGIN;
\q
```
Type `exit` at shell to return to your user from postgres

#### Verify Login to postgres instance

``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
echo "/var/run/postgresql:5432:cexplorer:*:*" > $PGPASSFILE
chmod 0600 $PGPASSFILE
psql postgres
# psql (17.0)
# Type "help" for help.
# 
# postgres=#
```