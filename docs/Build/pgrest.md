!!! important

    - An average pool operator may not require this component at all. Please verify if it is required for your use as mentioned [here](../build.md#components)
    - Ensure that you have setup [DBSync](../Build/dbsync.md) and that it is in sync atleast to Mary fork before you proceed. *IF* you're participating in Koios services, ensure that you're using [latest dbsync release](https://github.com/input-output-hk/cardano-db-sync/releases/latest)

[PostgREST](https://postgrest.org/en/latest) is a web server that serves any PostgreSQL database (in our case, useful for `cardano-db-sync`) as a RESTful Web Service. The endpoints of PostgREST in itself are essentially the table/functions exposed via the PostgREST config file. You can read more about exploring the API [here](https://postgrest.org/en/latest/api.html). Understandably, it would of course rely on an existing PostgreSQL server. It is an easy alternative - which will remain up-to-date since it is directly serving the underlying database as an API, as compared to `Cardano GraphQL` component. Some of the other advantages are also performance, elasticity, low overhead, support for JWT / native Postgres DB authentication against the Rest Interface as well.

As part of setup process below (which is also used for setting up [Koios](https://www.koios.rest) instances), we install an instance of PostgREST along with [HAProxy](http://cbonte.github.io/haproxy-dconv/2.4/configuration.html) configuration that serves as an easy to gateway proxy that automatically provides failover/basic DDoS protection, but you may alter the settings for proxy layer as per your SecOps preferences.

### Setup PostgREST, HAProxy and add addendum to Postgres DB {: id="setup"}

To start with you'd want to ensure your current shell session has access to Postgres credentials, continuing from examples from the above mentioned [Sample Postgres deployment guide](../Appendix/postgres.md).

``` bash
cd $CNODE_HOME/priv
PGPASSFILE=$CNODE_HOME/priv/.pgpass
psql cexplorer
```

Ensure that you can connect to your Postgres DB fine using above (quit from psql once validated using `\q`).

Now, below will allow you to download setup script that automates installation of PostgREST, HAProxy as well as brings in latest queries/functions provided via Koios to your instances.

``` bash
cd "${CNODE_HOME}"/scripts
curl -o setup-koios.sh https://raw.githubusercontent.com/cardano-community/guild-operators/alpha/scripts/koios-helper-scripts/setup-koios.sh && chmod 750 setup-koios.sh
```

Familiarise with the usage options for the setup script , the syntax can be viewed as below:

``` bash
./setup-koios.sh -h
#
# Usage: setup-koios.sh [-f] [-i [p][r][m][c][d]] [-u] [-b <branch>]
# 
# Install and setup haproxy, PostgREST, polling services and create systemd services for haproxy, postgREST and dbsync
# 
# -f    Force overwrite of all files including normally saved user config sections
# -i    Set-up Components individually. If this option is not specified, components will only be installed if found missing (eg: -i prcd)
#     p    Install/Update PostgREST binaries by downloading latest release from github.
#     r    (Re-)Install Reverse Proxy Monitoring Layer (haproxy) binaries and config
#     m    Install/Update Monitoring agent scripts
#     c    Overwrite haproxy, postgREST configs
#     d    Overwrite systemd definitions
# -u    Skip update check for setup script itself
# -q    Run all DB Queries to update on postgres (includes creating koios schema, and re-creating views/genesis table/functions/triggers and setting up cron jobs)
# -b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
#
```

To run the setup with typical options, you may want to use:
```
./setup-koios.sh -f -q
```

Similarly - if instead, you'd like to re-install all components as well as force overwrite all configs and queries, you may run:
```
./setup-koios.sh -f -i prmcd -q
```

Please ensure to follow the on-screen instructions, if any (for example restarting deployed services, or updating configs to enable TLS or add peers to your HAProxy instances).

Note that the setup will create a PostgREST config as `${CNODE_HOME}/priv/pgrest.conf`. Please check and ensure that the parameters are as expected.

The default ports used will make haproxy instance available at port 8053 (you might want to enable firewall rule to open this port to services you would like to access). Make sure to change the file permissions so that it's only visible to user that will run postgREST instance using `chmod 600 ${CNODE_HOME}/priv/pgrest.conf`. If you want to prevent unauthenticated access to koios schema, uncomment the jwt-secret and specify a custom `secret-token`.

### Enable TLS on HAProxy {: id="tls"}

In order to enable SSL on your haproxy, all you need to do is edit the file `${CNODE_HOME}/files/haproxy.cfg` and update the *frontend app* section to disable normal bind and enable ssl bind. Note that the server.pem referred in example below should contain certificate chain as well as the private key.

```
frontend app
  bind 0.0.0.0:8053
  http-request replace-value Host (.*):8053 :8453
  redirect scheme https code 301 if !{ ssl_fc }
  
frontend app-secured
  bind :8453 ssl crt /etc/ssl/server.pem no-sslv3
  http-request track-sc0 src table flood_lmt_rate
  http-request deny deny_status 429 if { sc_http_req_rate(0) gt 100 }
  default_backend koios_core
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

With the setup, you also have a `checkstatus.sh` script, which will query the Postgres DB instance via haproxy (coming through postgREST), and only show an instance up if the latest block in your DB instance is within 180 seconds.

!!! info "Note"
    While currently the HAProxy config only checks for tip, there will be test cases added for validating each endpoint in future.

If you were using `guild` network, you could do a couple of very basic sanity checks as per below:

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

You may want to explore what all endpoints come out of the box, and test them out, to do so - refer to [API documentation](https://api.koios.rest) for OpenAPI3 documentation. Each endpoint has a pre-filled example on mainnet, and will allow you to do some basic queries against one of the trusted instances and grab the `curl` commands to start testing yourself against the instances.
