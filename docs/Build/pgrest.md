!!! important

    - An average pool operator may not require this component at all. Please verify if it is required for your use as mentioned [here](../build.md#components)
    - Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

[PostgREST](https://postgrest.org/en/latest) is a web server that serves any PostgreSQL database (in our case, useful for `cardano-db-sync` and `smash`) as a RESTful Web Service. The endpoints of PostgREST in itself are essentially the table itself. You can read more about exploring the API [here](https://postgrest.org/en/latest/api.html). Understandably, it would of course rely on an existing PostgreSQL server. At the moment of writing, this is being used as an easy alternative - which will remain up-to-date since it is directly serving the underlying database as an API, as compared to `Cardano GraphQL` component. Some of the other advantages would also be that you can serve JWT authentication, or use native Postgres DB authentication against the Rest Interface as well (see [here](https://postgrest.org/en/latest/tutorials/tut1.html) for adding this to your instance), and the web server it uses can be hardened or served behind another nginx/httpd/.. reverse proxy as per your SecOps preferences.

Again, the focus of this guide (for now) is not to tell you how to secure your PostgREST instance, but to get you up and running quickly. You'd want to harden your instance as per instructions [here](https://postgrest.org/en/latest/admin.html?highlight=SSL) once you're happy with the usage. The guide below assumes PostgreSQL instance has already been set up (refer to [Sample Local PostgreSQL Server Deployment instructions](../Appendix/postgres.md) ) along with [cardano-db-sync](../Build/dbsync.md).

### Enable permissions in Database {: id="perms"}

For simplicity, the download of latest PostgREST instance is already available via executing the below:

``` bash
mkdir ~/tmp;cd ~/tmp
wget https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/prereqs.sh
./prereqs.sh -p
```

This would download and make `postgrest` binary available in `${HOME}/.cabal/bin` which is also where your DB Sync binaries would be, assuming you've followed [this guide](../Build/dbsync.md).

To start with you'd want to ensure your current shell session has access to Postgres credentials, continuing from examples from the above mentioned [Sample Postgres deployment guide](../Appendix/postgres.md).

``` bash
cd $CNODE_HOME/priv
PGPASSFILE=$CNODE_HOME/priv/.pgpass
```

Ensure that you can connect to your Postgres DB instance using `psql cexplorer` before you proceed (quit from psql once validated using `\q`). Create your PostgREST config file using command below:

!!! info "Reminder !!"
    Verify and update db-uri if required, the given value configures it for user running the command below (and relies on socket connection to postgres sever.

``` bash
cat << 'EOF' > $CNODE_HOME/priv/grest.conf
db-uri = "postgres://${USER}@/cexplorer"
db-schema = "grest, public"
db-anon-role = "web_anon"
server-host = "127.0.0.1"
server-port = 8050
#jwt-secret = "secret-token"
#db-pool = 10
#db-pool-timeout = 10
db-extra-search-path = "public"
max-rows = 1000

EOF

```

You're all set to set up your PostgREST instance, and while doing so, also configure haproxy service, set up roles/schemas/default permissions, and create systemd services for these:

``` bash
cd $CNODE_HOME/scripts
# To-Do: Update branch when merged to master
wget -o setup-grest.sh https://raw.githubusercontent.com/cardano-community/guild-operators/alpha/scripts/grest-helper-scripts/setup-grest.sh
chmod 755 setup-grest.sh
./setup-grest.sh -t cnode
# cnode is top level folder here
```

Follow the prompts to start-up deployed services. The default ports used will make haproxy instance available at port 8053 (you might want to enable firewall rule to open this port to services you would like to access). Make sure to change the file permissions so that it's only visible to user that will run postgrest instance using `chmod 600 $CNODE_HOME/priv/pgrest.conf`. If you want to prevent unauthenticated access to grest schema, uncomment the jwt-secret and specify a custom `secret-token`.

### Validation

While you can query PostgREST a browser from a browser if listening on `0.0.0.0` , we'd stick to querying your instance via `curl` on terminal, so that we're not troubleshooting any firewall/network configuration issues. Now, the nomenclature we used should have connected you to the `cardano-db-sync` instance. Assuming it is already populated (even partially), you can try explore deployed functions as REST endpoints.

!!! info "Note"
    The values used in queries below are from guild network, replace them to valid values that can be used on network that your dbsync instance if filled with


1. To query active stake for pool `pool1z2ry6kxywgvdxv26g06mdywynvs7jj3uemnxv273mr5esukljsr` in epoch `122`, we can execute the below:
``` bash
curl -d _pool_bech32=pool1z2ry6kxywgvdxv26g06mdywynvs7jj3uemnxv273mr5esukljsr -d _epoch_no=122 -s http://localhost:8053/rpc/pool_active_stake
## {"active_stake_sum" : 19409732875}
```

2. To check latest owner key(s) for a given pool `pool1z2ry6kxywgvdxv26g06mdywynvs7jj3uemnxv273mr5esukljsr`, you can execute the below:
``` bash
curl -d _pool_bech32=pool1z2ry6kxywgvdxv26g06mdywynvs7jj3uemnxv273mr5esukljsr -s http://localhost:8050/rpc/pool_owners
## [{"owner" : "stake_test1upx5p04dn3t6dvhfh27744su35vvasgaaq565jdxwlxfq5sdjwksw"}, {"owner" : "stake_test1uqak99cgtrtpean8wqwp7d9taaqkt9gkkxga05m5azcg27chnzfry"}]
```

Refer to [API documentation](https://cardano-community.github.io/guild-operators/Build/pgrestspecs) for Swagger documentation.
