!!! important

    - An average pool operator may not require this component. Verify whether
      it is required for your use [here](../build.md#components).
    - The Guild gRest deployment is currently supported only by the `cnode`
      profile.
    - Set up [db-sync](dbsync.md), let it reach the chain tip, and use the
      version selected by the installed cnode release manifest before
      proceeding.

### What is gRest

gRest is an open source implementation of a `query layer built over dbsync using PostgREST and HAProxy`. The package is built as part of [Koios](https://www.koios.rest) team's efforts to unite community individual stream of work together and give back a more aligned structure to query dbsync and adopt standardisation to queries utilising open-source tooling as well as collaboration. In addition to these, there are also accessibility features to deploy rules for failover, do healthchecks, set up priorities, have ability to prevent DDoS attacks, provide timeouts, report tips for analysis over a longer period, etc - which can prove to be really useful when performing any analysis for instances.

!!! info "Note"
    Note that the scripts below do allow for provisioning ogmios integration too, but Ogmios - currently - is not designed to provide advanced session management for a server-client architecture in absence of a middleware. Thus, the availability for ogmios from monitoring instance is restricted to avoid ability to DDoS an instance.

### Components

1. [PostgREST](https://postgrest.org/en/latest):
    An RPC JSON interface for any PostgreSQL database (in our case, database served via `cardano-db-sync`) to provide a RESTful Web Service. The endpoints of PostgREST in itself are essentially the table/functions defined in elected schema via grest config file. You can read more about advanced query syntax using PostgREST API [here](https://postgrest.org/en/latest/api.html), but we will provide a simpler view using examples towards the end of the page. It is an easy alternative - with almost no overhead as it directly serves the underlying database as an API, as compared to `Cardano GraphQL` component (which may often have lags). Some of the other advantages of PostgREST over graphql based projects are also performance, being stateless, 0 overhead, support for JWT / native Postgres DB authentication against the Rest Interface as well.

2. [HAProxy](https://docs.haproxy.org/3.2/configuration.html):
    An easy gateway proxy that automatically provides failover/basic DDoS protection, specify rules management for load balancing, setup multiple frontend/backends, provide easy means to have TLS enabled for public facing instances, etc. You may alter the settings for proxy layer as per your SecOps preferences. This component is optional (eg: if you prefer to expose your PostgREST server itself, you can do so using similar steps below).

### Setup gRest services {: id="setup"}

To start with you'd want to ensure your current shell session has access to Postgres credentials, continuing from examples from the above mentioned [Sample Postgres deployment guide](../Appendix/postgres.md).

``` bash
cd $CNODE_HOME/priv
export PGPASSFILE=$CNODE_HOME/priv/.pgpass
psql cexplorer
```

Ensure that you can connect to PostgreSQL using the command above (quit with
`\q`). `guild-deploy.sh` installs `setup-grest.sh` in
`${CNODE_HOME}/scripts`. The setup script installs PostgREST and HAProxy and
deploys the Koios query bundle pinned in that script.

!!! note "Release selection"
    The current setup script pins Koios artifacts `v1.4.2`. Its `-b` option
    selects and persists a Guild Operators source branch in
    `${CNODE_HOME}/.deployment.json`; it does not select a Koios artifact
    release. PostgREST `v14.10`, HAProxy `3.2.21`, and `pg_cardano` `1.2.0`
    are also constants owned by `setup-grest.sh`; they are not entries in the
    cnode release manifest.

The implemented command syntax is:

```bash
cd "${CNODE_HOME}/scripts"
./setup-grest.sh [-i <component-letters>] [-u] [-r] [-q] [-b <branch>]
```

The `-i` component letters are:

| Letter | Action |
| --- | --- |
| `p` | Install or update PostgREST |
| `r` | Reinstall HAProxy and its monitoring layer |
| `m` | Install or update monitoring scripts |
| `g` | Install or update the `pg_cardano` extension |
| `c` | Overwrite HAProxy and PostgREST configuration |
| `d` | Overwrite systemd definitions |

Without `-i`, the current script repairs a missing HAProxy binary, monitoring
scripts, or managed configuration detected by its default checks. `-u` skips
the setup-script update check, `-r` resets the gRest schema, and `-q`
redeploys database queries, views, functions, triggers, and cron jobs.

To refresh all managed components and reset/redeploy the gRest schema:

``` bash
./setup-grest.sh -i prmgcd -r
```

To reinstall all components and overwrite managed config and systemd units
without resetting cache tables:

``` bash
./setup-grest.sh -i prmgcd -q
```

To preserve configuration and update only database queries:

``` bash
./setup-grest.sh -q
```

Use `-b <branch>` only for an existing Guild Operators development or release
branch. Because the choice becomes the deployment-wide helper source, change
it deliberately rather than using it as a gRest version selector.

Follow the on-screen instructions, including any required service restart or
configuration updates in `${CNODE_HOME}/priv/grest.conf` and
`${CNODE_HOME}/files/haproxy.cfg`.

The default ports used will make haproxy instance available at port 8053 or 8453 if TLS is enabled (you might want to enable firewall rule to open this port to services you would like to access). If you want to prevent unauthenticated access to grest schema, uncomment the jwt-secret and specify a custom `secret-token`.

!!! info "Reminder"

    Once you've successfully deployed the grest instance, it will deploy certain cron jobs that will ensure the relevant cache tables are updated periodically. Until these have finished (especially on first run, when it could take an hour or so on mainnet), your instance will likely not pass any tests from `grest-poll.sh`, but that's expected.

### Enable TLS on HAProxy {: id="tls"}

In order to enable SSL on your haproxy, all you need to do is edit the file `${CNODE_HOME}/files/haproxy.cfg` and update the *frontend app* section to uncomment ssl bind (and comment normal bind).

!!! info

    - server.pem referred below should be a chain containing server TLS certificate, signing certificates (intermediate/root) and private key.
    - Make sure to replace the hostname to the CNAME/SAN used to create your TLS certificate.

If you're not familiar with how to configure TLS OR would not like to buy one, you can find tips on how to create a TLS certificate for free via LetsEncrypt using tutorials [here](https://letsencrypt.org/getting-started/). Once you do have a TLS Certificate generated, you need to chain the private key and full chain cert together in a file - `/etc/ssl/server.pem` - which can be then referenced as below:

```
frontend app
  #bind 0.0.0.0:8053
  ## If using SSL, comment line above and uncomment line below
  bind :8453 ssl crt /etc/ssl/server.pem no-sslv3
  http-request set-log-level silent
  acl srv_down nbsrv(grest_postgrest) eq 0
  acl is_wss hdr(Upgrade) -i websocket
  ...
```
Restart haproxy service for changes to take effect.

### Validation

The installed `checkstatus.sh` opens a live terminal view of HAProxy backend
statistics from `${CNODE_HOME}/sockets/haproxy.socket`. It displays the gRest,
Ogmios, and submit-api backend states reported by HAProxy; it does not perform
a chain-tip freshness query.

!!! warning "Important"
    If you'd like to participate in joining to the elastic cluster via Koios, please raise a PR request by editing topology files in [this folder](https://github.com/cardano-community/koios-artifacts/tree/main/topology) to do so!!

After the query deployment completes, perform a network-independent sanity
check through HAProxy:

```bash
curl -fsS http://127.0.0.1:8053/rpc/tip | jq
```

Refer to the [Koios API documentation](https://api.koios.rest) for the
release's endpoint inputs and output schema before constructing further
queries.

### Participating in Koios Cluster as instance Provider

If you're interested to participate in decentralised infrastructure by providing an instance, there are a few additional steps you'd need:

1. Enable ports for your HAProxy instance (default: 8053), gRest Exporter service (default: 8059) and (optionally) submit API instance (default: 8090) against the monitoring instance (do not need to open these ports to internet) of corresponding network.

2. Ensure that each of the service above is listening on your public IP address (for instance, submitapi.sh might need to be edited to change HOSTADDR to `0.0.0.0` and restarted).

3. Create a PR specifying connectivity information to your HAProxy port [here](https://github.com/cardano-community/koios-artifacts/tree/main/topology).

4. Make sure to join the [telegram discussions group](https://t.me/CardanoKoios) to participate in any discussions, actions, polls for new-features, etc. Feel free to give a shout in the group in case you have trouble following any of the above
