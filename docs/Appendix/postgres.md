These deployment instructions used for reference while building [cardano-db-sync](../Build/dbsync.md) tool. These are just for reference and ease of set up and consistency for those who are new to Postgres DB.
It is recommended to customise these as per your needs for Production builds.

#### Install PostgreSQL Server

Execute commands below to set up Postgres Server

``` bash
# Determine OS platform
OS_ID=$(grep -i ^id_like= /etc/os-release | cut -d= -f 2)
DISTRO=$(grep -i ^NAME= /etc/os-release | cut -d= -f 2)

if [ -z "${OS_ID##*debian*}" ]; then
  #Debian/Ubuntu
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
  RELEASE=$(lsb_release -cs)
  echo "deb [arch=amd64] http://apt.postgresql.org/pub/repos/apt/ ${RELEASE}"-pgdg main | sudo tee  /etc/apt/sources.list.d/pgdg.list
  sudo apt-get update
  sudo apt-get -y install postgresql-14 postgresql-server-dev-14 postgresql-contrib libghc-hdbc-postgresql-dev
  sudo systemctl restart postgresql
  sudo systemctl enable postgresql
elif [ -z "${OS_ID##*rhel*}" ]; then
  #CentOS/RHEL/Fedora
  sudo yum install -y postgresql-server postgresql-server-devel postgresql-contrib postgresql-devel libpq-devel
  sudo postgresql-setup initdb
  sudo systemctl restart postgresql
  sudo systemctl enable postgresql
else
  echo "We have no automated procedures for this ${DISTRO} system"
fi
```

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
ALTER USER <user> PASSWORD 'PasswordYouWant';
\q
```
Type `exit` at shell to return to your user from postgres

#### Verify Login to postgres instance

``` bash
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
echo "/var/run/postgresql:5432:cexplorer:*:*" > $PGPASSFILE
chmod 0600 $PGPASSFILE
psql postgres
# psql (13.4)
# Type "help" for help.
# 
# postgres=#
```

#### Tuning your instance

Before you start populating your DB instance using dbsync data, now might be a good time to put some thought on to baseline configuration of your postgres instance by editing `/etc/postgresql/13/main/postgresql.conf`.
Typically, you might find a lot of common standard practices parameters available in tuning guides. For our consideration, it would be nice to start with some baselines - for which we will use inputs from example [here](https://pgtune.leopard.in.ua/#/).
You might want to fill in some sample information as per below to fill in the form:

| Option         | Value |
|----------------|-------|
| DB Version     | 13    |
| OS Type        | Linux |
| DB Type        | Online Transaction Processing System|
| Total RAM      | 32 (or as per your server) |
| Number of CPUs | 8 (or as per your server)  |
| Number of Connections | 200 |
| Data Storage   | HDD Storage |

In addition to above, due to the nature of usage by dbsync (restart of instance does a rollback to start of epoch), and data retention on blockchain - we're not affected by loss of volatile information upon a restart of instance. Thus, we can relax some of the data retention and protection against corruption related settings, as those are IOPs/CPU Load Average impacts that the instance does not need to spend. We'd recommend setting 3 of those below in your `/etc/postgresql/13/main/postgresql.conf`:

| Parameter          | Value   |
|--------------------|---------|
| wal_level          | minimal |
| max_wal_senders    | 0       |
| synchronous_commit | off     |

Once your changes are done, ensure to restart postgres service using `sudo systemctl restart postgresql`.