These deployment instructions used for reference while building [cardano-db-sync](Build/dbsync.md) tool. These are just for reference and ease of set up and consistency for those who are new to Postgres DB.
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
  echo "deb http://apt.postgresql.org/pub/repos/apt/ ${RELEASE}"-pgdg main | sudo tee  /etc/apt/sources.list.d/pgdg.list
  sudo apt-get update
  sudo apt-get -y install postgresql-11 postgresql-server-dev-11 postgresql-contrib libghc-hdbc-postgresql-dev
  sudo sed -i "s#  ident#  md5#g" /etc/postgresql/11/main/pg_hba.conf
  sudo systemctl restart postgresql
  sudo systemctl enable postgresql
elif [ -z "${OS_ID##*rhel*}" ]; then
  #CentOS/RHEL/Fedora
  sudo yum install -y postgresql-server postgresql-server-devel postgresql-contrib postgresql-devel libpq-devel
  sudo postgresql-setup initdb
  sudo sed -i "s#  ident#  md5#g" /var/lib/pgsql/data/pg_hba.conf
  sudo systemctl start postgresql
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
echo "localhost:5432:cexplorer_phtn:$(whoami):PasswordYouWant" > $PGPASSFILE
chmod 0600 $PGPASSFILE
psql postgres
# psql (10.6)
# Type "help" for help.
# 
# postgres=#
```
