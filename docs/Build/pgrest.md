!!! important

    - An average pool operator may not require this component at all. Please verify if it is required for your use as mentioned [here](../build.md#components)
    - Ensure that you have setup [DBSync](../Build/dbsync.md) and that it is in sync before you proceed..

[PostgREST](https://postgrest.org/en/latest) is a web server that serves any PostgreSQL database (in our case, useful for `cardano-db-sync`) as a RESTful Web Service. The endpoints of PostgREST in itself are essentially the table/functions exposed via the PostgREST config file. You can read more about exploring the API [here](https://postgrest.org/en/latest/api.html). Understandably, it would of course rely on an existing PostgreSQL server. At the moment of writing, this is being used as an easy alternative - which will remain up-to-date since it is directly serving the underlying database as an API, as compared to `Cardano GraphQL` component. Some of the other advantages are also performance, elasticity, low overhead, support for JWT / native Postgres DB authentication against the Rest Interface as well (see [here](https://postgrest.org/en/latest/tutorials/tut1.html) for adding this to your instance). We merge the deployment with HAProxy configuration that serves as an easy means to harden your gateway, but you may alter the settings for proxy layer as per your SecOps preferences.

### Setup PostgREST, HAProxy and add addendum to Postgres DB {: id="setup"}

To start with you'd want to ensure your current shell session has access to Postgres credentials, continuing from examples from the above mentioned [Sample Postgres deployment guide](../Appendix/postgres.md).

``` bash
cd $CNODE_HOME/priv
PGPASSFILE=$CNODE_HOME/priv/.pgpass
psql cexplorer
```

Ensure that you can connect to your Postgres DB fine using above (quit from psql once validated using `\q`).

Now, create your PostgREST config file using command below:

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

### Enable TLS on HAProxy {: id="tls"}

In order to enable SSL on your haproxy, all you need to do is edit the file `/etc/haproxy/haproxy.cfg` and update the *frontend app* section to disable normal bind and enable ssl bind. Note that the server.pem referred in example below should contain certificate chain as well as the private key.

```
#bind :8053
bind :8053 ssl crt /etc/ssl/server.pem no-sslv3
redirect scheme https code 301 if !{ ssl_fc }
```
Restart haproxy service for changes to take effect.

### Performance Tuning Considerations

While the defaults on your system should not cause you any trouble, note that haproxy relies on ephemeral ports available on your system to be able to redirect frontend requests to backend servers. The four important configuration settings in your `/etc/sysctl.conf` files would be:

```
net.ipv4.ip_local_port_range="1024 65534"
net.core.somaxconn=65534
net.ipv4.tcp_rmem=4096 16060 64060
net.ipv4.tcp_wmem=4096 16384 262144
```
Again, defaults should be fine for minimal usage, you do not need to tinker with above unless you expect a very high amount of load on your frontend.

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
