!> - An average pool operator may not require this component at all. Please verify if it is required for your use as mentioned [here](build.md#components)

> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

[PostgREST](https://postgrest.org/en/latest) is a web server that serves any PostgreSQL database (in our case, useful for `cardano-db-sync` and `smash`) as a RESTful Web Service. The endpoints of PostgREST in itself are essentially the table itself. You can read more about exploring the API [here](https://postgrest.org/en/latest/api.html). As understandable, it would ofcourse rely on an existing PostgreSQL server. At the moment of writing, this is being used as an easy alternative - which will remain up-to-date since its directly serving the underlying database as API, as compared to Cardano-Graphql component. Some of the other advantages would also be that you can serve JWT authentication, or use native Postgres DB authentication against the Rest Interface as well (see [here](https://postgrest.org/en/latest/tutorials/tut1.html) for adding this to your instance), and the web server it uses can be hardened or served behind another nginx/httpd/.. reverse proxy as per your secops preferences.

Again, the focus of this guide (for now) is not to tell you how to secure your PostgREST instance , but to get you up and running quickly. You'd want to harden your instance as per instructions [here](https://postgrest.org/en/latest/admin.html?highlight=SSL) once you're happy with the usage. The guide below assumes PostgreSQL instance has already been set up (refer to [Sample Local PostgreSQL Server Deployment instructions](Appendix/postgres.md) ) alongwith [cardano-db-sync](build/dbsync.md).

#### Prepare Database {docsify-ignore}

For simplicity, the download of latest PostgREST instance is already available via executing the below:

``` bash
mkdir ~/tmp;cd ~/tmp
wget https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/prereqs.sh
./prereqs.sh -p
```

This would download and make postgrest binary available in `${HOME}/.cabal/bin` which is also where your DBSync binaries would be, assuming you've followed [this guide](build/dbsync.md).

To start with you'd want to ensure your current shell session has access to Postgres credentials, continuing from examples from above mentioned Sample Postgres deployment guide.

``` bash
cd $CNODE_HOME/priv
PGPASSFILE=$CNODE_HOME/priv/.pgpass
```

Now you'd want to start `psql cexplorer` to connect to your Postgres Instance, and create a basic user and give it usage/select access to the schema and tables respectively. Refer to commands below for the same:

``` sql
create role web_anon nologin;
grant usage on schema public to web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO web_anon;
```

You can now quit your psql session using `\q`.

##### Create Config and Start PostgREST

Now that your user is created in database, you can create the postgrest config. A basic sample is below:

!> Replace ${USER} and ${PASSWORD} to match the Username password you can authenticate with for psql (defined in $CNODE_HOME/priv/.pgpass file in our example)

``` bash
cat << 'EOF' > $CNODE_HOME/priv/pgrest.conf
db-uri = "postgres://${USER}:${PASSWORD}@localhost/cexplorer"
db-schema = "public"
db-anon-role = "web_anon"
server-host = "127.0.0.1"
server-port = 8050
#jwt-secret = "secret-token"
#db-pool = 10
#db-pool-timeout = 10
#db-extra-search-path = "public"
#max-rows = 1000
```

If you'd like to connect to your PostgREST remotely (again, it is recommended you harden your instance before this is done), uncomment and replace the `server-host` parameter with "0.0.0.0"). Make sure to change the file permissions so that it's only visible to user that will run postgrest instance using `chmod 600 $CNODE_HOME/priv/pgrest.conf`. If you want to prevent unauthenticated access, uncomment the jwt-secret and specify a custom `secret-token`.

You're now all set! To start the instance , you can use the below to start your postgrest instance.

``` bash
postgrest $CNODE_HOME/priv/pgrest.conf
## Attempting to connect to the database...
## Listening on port 8050
## Connection successful
```

##### Test queries

While you can query PostgREST a browser from a browser if listening on `0.0.0.0` , we'd stick to querying your instance via `curl` on terminal, so that we're not troubleshooting any firewall/network configuration issues. Now, the nomen clature we used should have connected you to the `cardano-db-sync` instance. Assuming it is already populated, you can try explore tables as REST endpoints.

1. To query the network your DBSync instance has connected to
``` bash
curl -s http://127.0.0.1:8050/meta?select=network_name
## [{"network_name":"mainnet"}]
curl -s http://127.0.0.1:8050/meta?network_name | jq -r '.[].network_name'
## mainnet
```
Note that here meta is the table name , while network_name is the column name.

2. Let's now look at another table `epoch` and add a where filter to query ID equals 2
``` bash
curl -s http://127.0.0.1:8050/epoch?id=eq.2 | jq .
## [
##   {
##     "id": 2,
##     "out_sum": 101402912214214220,
##     "fees": 1033002678,
##     "tx_count": 12870,
##     "blk_count": 21590,
##     "no": 1,
##     "start_time": "2017-09-28T21:44:51",
##     "end_time": "2017-10-03T21:44:31"
##   }
## ]
```

Refer to [API documentation](https://postgrest.org/en/latest/api.html) for more details about querying (joins, functions, custom queries, stored procedures, etc).