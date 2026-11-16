# Amaru deployment profile

!!! danger "Experimental rolling-release support"
    Amaru is under rapid development and ships a new public-beta build most
    weeks. The Guild Operators profile runs Amaru as a relay or as a block
    producer on `preprod`, `preview` and `mainnet`. Try it on a testnet first;
    running Amaru on mainnet, and producing blocks with it there in
    particular, is at your own responsibility.

!!! warning "Coming from an earlier Amaru deployment"
    Current Amaru releases refuse chain databases created by older releases,
    and the environment template now uses Amaru's renamed settings. Start over
    fresh: stop both services, remove `chain/`, `ledger/`, and `snapshots/`,
    refresh with `guild-deploy.sh -i amaru -n <network> -s df`, reinstall the
    units with `amaru.sh -d`, and bootstrap again.

## Supported deployment

The common deployment entrypoint selects Amaru with `-i amaru`. For example:

```bash
./guild-deploy.sh -i amaru -n preview -s pd
```

A mainnet relay is deployed the same way with `-n mainnet`. The deployment
then prints a reminder that Amaru is still under heavy development and that
running it on mainnet is at your own responsibility, and its environment
template starts from `backbone.cardano.iog.io:3001` and accepts up
to 50 inbound connections instead of 10.

When `-t` is omitted the target directory and service name default to `amaru`.
The supported selective-install flags are:

| Flag | Amaru action |
| --- | --- |
| `p` | Install runtime packages needed by the deployment and verifier |
| `d` | Resolve and verify the newest Amaru binary plus its pinned CLI and metrics companions |
| `f` | Replace an existing Amaru environment config, retaining a backup |
| `s` | Force helper-script replacement; this replaces common `env` user-variable settings |
| `w` | Install the pinned Cardano Hardware CLI and host device rules |

The cnode-specific flags `b`, `l`, `m`, `c`, `o`, `x`, and `r` are
rejected. With no `-s` value, the profile refreshes scripts, common libraries,
the release manifest, and missing configuration while preserving an existing
Amaru environment file. Select `-s f` when the managed environment template
should replace that file; the current file is archived first.

The executables are installed as `${NODE_HOME}/bin/amaru`,
`${NODE_HOME}/bin/cardano-cli`, and `${NODE_HOME}/bin/otelcol-contrib`. Existing
binaries are copied to `${NODE_HOME}/bin/archive/` first. The Cardano CLI
lets CNTools build, inspect, and sign transactions without implying that Amaru
has a node-to-client socket. Both `linux-x86_64` and `linux-aarch64` release
artifacts are supported.

Amaru follows its newest release. Each night, `node-release-check.yml` deploys and
bootstraps it, starts it, and reads a rising slot through the same adapter gLiveView
uses. If that fails, the job opens an issue and a pull request pinning the newest
release that works. To pin by hand, or to follow the newest release again:

```bash
files/tools/pin-node-release.sh amaru v10.11.20261022
```

```bash
files/tools/pin-node-release.sh amaru latest
```

### Release contract

`files/node-implementations/amaru/release.json` is the single Amaru release
contract. It intentionally contains only the schema and implementation
identity, the official Amaru GitHub repository and Linux asset selectors, and
the independently pinned Cardano CLI and collector versions and artifacts.
Amaru uses `version: "latest"`; the node entry contains no release tag, URL, or
checksum that needs updating for every upstream build.

When `-s d` is selected, deployment chooses the most recently published
non-draft Amaru GitHub release, including prereleases. The architecture
selector must match exactly one uploaded tar archive with a valid
GitHub-published SHA-256 digest. Repository, tag, filename, URL, size, and
digest must agree. Resolution fails rather than selecting an older release if
the API or newest release metadata cannot satisfy that contract.

The Amaru, Cardano CLI, and collector archives use fixed private staging
filenames. All are checksum-verified before extraction, and their expected
binary layouts and reported versions are checked before deployment succeeds.

## Layout and configuration

The default layout below assumes `/opt/cardano/amaru`:

```text
/opt/cardano/amaru/
├── .deployment.json
├── chain/                 # created by bootstrap, not deployment
├── ledger/                # created by bootstrap, not deployment
├── files/
│   ├── amaru-release.json
│   └── otelcol.yaml
├── logs/
├── priv/
│   └── pool/
│       └── <POOL_NAME>/   # block producers only
│           ├── hot.skey       # online KES signing key
│           ├── vrf.skey       # online VRF signing key
│           └── op.cert        # operational certificate
├── runtime/
├── snapshots/             # downloaded bootstrap snapshots, reused on retry
└── scripts/
    ├── adapters/amaru.adapter
    ├── archive/
    ├── cntools.sh          # public launcher
    ├── cntools/            # modular CNTools tree
    ├── lib/
    ├── amaru.env
    ├── amaru.sh
    ├── gLiveView.sh
    └── env
```

Amaru embeds the global parameters and a peer snapshot for well-known networks
and downloads its bootstrap snapshot catalogue when bootstrapping. No
cardano-node-style config or genesis JSON bundle is needed for the supported
networks. Guild Operators self-hosts a small environment template for each
network, the rolling Amaru release policy, and pinned collector metadata.

The environment template uses Amaru's current setting names, such as
`AMARU_DB_CHAIN`, `AMARU_DB_LEDGER`, `AMARU_PEERS_LISTEN_ON`, and `AMARU_PEER`.
Amaru still accepts the older names but has deprecated them. The template also
sets:

- `AMARU_DB_CHAIN_AUTOMATIC_MIGRATION=true`, so a newer release can upgrade the
  chain database in place when upstream provides a migration;
- `AMARU_LOG_OTLP=metrics`, because the local collector keeps only
  metrics;
- `AMARU_LOG`, matching Amaru's default log filter;
- `AMARU_PEER`, the network's public relay, because current releases no longer
  default to one.

`AMARU_LOG_OTLP` and `AMARU_LOG_JSON` are the names Amaru uses since
10.11.20261112. An existing `amaru.env` that still sets
`AMARU_WITH_OPEN_TELEMETRY` and `AMARU_WITH_JSON_TRACES` keeps working. When
pinning an older release, use those two older names instead.

The profile deliberately does not create `chain/` or `ledger/`. Upstream
bootstrap refuses to proceed if either already holds data, which prevents a
partial or existing database from being overwritten automatically. The
launcher treats a node as bootstrapped only when both directories contain
data.

## Relay and block-producer modes

Role selection follows the established cnode behavior. Pool settings live in
the common `scripts/env`, the same file CNTools and the other Guild scripts
read, so they all see the same pool folder. The pool folder is
`${POOL_FOLDER}/${POOL_NAME}`. Edit the User Variables section of
`scripts/env` and set `POOL_NAME` to the pool subfolder below
`$NODE_HOME/priv/pool`. To keep the online keys elsewhere, also set
`POOL_FOLDER` to the folder that holds the pool subfolder:

```bash
POOL_NAME="my-pool"
# Keys outside $NODE_HOME/priv/pool, here in /secure/online-keys/my-pool:
# POOL_FOLDER="/secure/online-keys"
```

`amaru.sh` loads these values the same way `cnode.sh` does, so a value
exported by the calling shell or container is honored unless `scripts/env`
sets one. `amaru.env` holds no key settings.

The expected filenames match the Guild cnode convention:

| File | Purpose | Passed to Amaru as |
| --- | --- | --- |
| `hot.skey` | KES signing key | `AMARU_OPERATOR_KES` |
| `vrf.skey` | VRF signing key | `AMARU_OPERATOR_VRF` |
| `op.cert` | Operational certificate | `AMARU_OPERATOR_CERT` |

- If none of these files is present, `amaru.sh run` starts a relay.
- If all three are present and readable, it starts a block producer.
- A partial set is treated as an operator error and startup stops with the
  missing paths instead of silently falling back to a relay.

`amaru.sh` owns the effective runtime role. It exports the three
`AMARU_OPERATOR_*` variables only when the complete set is present. A value
for one of them that is inherited from the shell or set in `amaru.env` is
dropped with a warning, so the pool folder alone decides the role.

Amaru loads the standard `cardano-cli` text-envelope formats, so an existing
pool's operational hot keys do not need conversion. Copy only the three online
files to the node. Keep the cold signing key and operational certificate
counter offline; Amaru takes the cold verification key from the operational
certificate. The KES and VRF signing files must be owned by the service user
and have no group or other permissions; for example:

```bash
chmod 700 /opt/cardano/amaru/priv/pool/my-pool
chmod 600 /opt/cardano/amaru/priv/pool/my-pool/{hot.skey,vrf.skey}
chmod 644 /opt/cardano/amaru/priv/pool/my-pool/op.cert
```

At startup Amaru itself checks that the KES key is the hot key named in the
operational certificate, verifies the certificate's cold-key signature, and
compares the certificate counter with the chain it has adopted. It exits when
one of these checks fails. Guild does not duplicate those protocol checks.
The pool must already be registered and delegated on the selected network to
have a chance of being elected as slot leader.

Amaru reads the credential files only when it starts and does not re-read
them on a signal, so `amaru.sh` has no `reload` command. To rotate the KES key
or operational certificate, replace `hot.skey` and `op.cert` in place and
restart the service:

```bash
/opt/cardano/amaru/scripts/amaru.sh restart
```

The node does not produce blocks while it restarts, so pick a moment without
an upcoming leader slot. Use `restart` as well to change between relay and
producer mode.

`amaru.sh bootstrap` always forces relay mode and does not require hot keys.
This permits state import before the operational credentials are copied. The
generated systemd unit remains role-neutral: every service start repeats the
same complete-key-set detection, so adding or removing the set changes the
runtime role without regenerating the unit. `amaru.sh -d` reports the mode it
detects at install time.

A block producer normally connects only to the operator's own relays, so
restrict its node-to-node port at the firewall. The template's peer settings
are sized for a relay: Amaru's default peer mix also fills upstream slots with
peers it discovers. `AMARU_PEERS_MIX` lists the sources Amaru takes upstream
peers from, and a source that is left out is disabled. For a producer, list
only your own relays in `AMARU_PEER`, keep only the `static` source, and set
its floor and `AMARU_PEERS_MAX_UPSTREAM` to the number of relays. With two
relays:

```bash
AMARU_PEER="relay1.example.com:3000,relay2.example.com:3000"
AMARU_PEERS_MIX="static!2"
AMARU_PEERS_MAX_UPSTREAM="2"
```

## Bootstrap and service

Amaru needs three trusted consecutive epoch snapshots before it can run:

```bash
/opt/cardano/amaru/scripts/amaru.sh bootstrap
/opt/cardano/amaru/scripts/amaru.sh -d
/opt/cardano/amaru/scripts/amaru.sh start
```

After `guild-deploy.sh` completes, it suggests bootstrap only when neither
state directory exists and suggests `-d` only when one or both managed
systemd units are absent. Refreshing an existing deployment therefore does not
repeat completed next steps.

Bootstrap downloads compressed snapshots over HTTPS from Amaru's public
snapshot storage into `snapshots/<network>/`, so the host needs outbound HTTPS
access. A retried bootstrap reuses archives already downloaded there; delete
them after a successful bootstrap to reclaim the space.

The bootstrap command disables OpenTelemetry export only for that invocation.
Bootstrap telemetry is not used by gLiveView. Normal `run` and systemd
operation continue to use the telemetry settings from `amaru.env`.

If bootstrap fails after creating `chain/` or `ledger/`, inspect and move or
remove the partial state yourself before retrying; the Guild launcher will
never delete it.

For container volumes, the launcher accepts `AMARU_STATE_ROOT` as a parent
directory and derives `<root>/chain` and `<root>/ledger` from it. Host
deployments leave it unset and retain the paths in `amaru.env`.

`-d` installs and enables two systemd units but intentionally does not start
them: `<service-name>.service` for Amaru and
`<service-name>-metrics.service` for the local OpenTelemetry Collector. The
collector restarts on failure. The experimental Amaru node unit uses
`Restart=always` so unexpected node exits are restarted. An explicit
`systemctl stop` is still honored, and the unit allows 90 seconds for Amaru to
close its ledger cleanly before systemd kills it.

Running `amaru.sh run` yourself in an interactive terminal, with the service
stopped, opens Amaru's built-in terminal dashboard. It runs inside the node
process, so it cannot attach to the systemd service; use gLiveView for that.
Set `AMARU_TUI_OFF=true` to keep plain log output in a terminal.

The other lifecycle commands are `start`, `status`, `stop`, `restart`, `logs`,
and `remove`; they manage both units. `remove` deletes only those units and
preserves node state and monitoring configuration. The launcher can recover
the service identity from `.deployment.json`, so `status` and `remove` still
work after the Amaru binary or environment file is gone. The manifest and
launcher location are authoritative: if `amaru.env` declares a conflicting
implementation, network, service, or deployment root, run/bootstrap/install
commands stop and require a corrected deployment instead of managing the
wrong target.

The default node-to-node listener is TCP 3000 on `0.0.0.0`. `AMARU_PEERS_MAX_DOWNSTREAM`
also caps accepted inbound connections: 10 by default on the testnets, 50 on
mainnet; raise it for a busier public relay. Outbound connections reuse the listen port as their source port
when the operating system allows it, so firewall rules that match on source
port should allow the relay port in both directions. Set
`AMARU_PEERS_EPHEMERAL_OUTBOUND_PORT=true` to use ephemeral ports instead.

To keep your own relays or block producer connected, add them to `AMARU_PEER`
as a comma-separated `host:port` list. Amaru's default peer mix reserves two
upstream slots for these static peers, so discovered peers cannot displace
them. With more than two, uncomment `AMARU_PEERS_MIX`, raise the static floor,
and raise `AMARU_PEERS_MAX_UPSTREAM` by the same amount:

```bash
AMARU_PEER="preview-node.play.dev.cardano.org:3001,relay2.example.com:3000,10.0.0.5:3000"
AMARU_PEERS_MIX="static!3@15m, inbound~6, shared~6, snapshot~3@1h, ledger~3@24h"
AMARU_PEERS_MAX_UPSTREAM="4"
```

Restart the service afterwards. A deployment refresh keeps an existing
`amaru.env` unless `-s f` is used, which archives the old file under
`scripts/archive/` first.

Amaru provides no cardano-node-compatible node-to-client socket. Its optional
HTTP transaction submission endpoint, `AMARU_SUBMIT_API_LISTEN_ON`, is
disabled because it has no built-in authentication or TLS.

## Moving a cnode relay to Amaru

An existing cnode relay on `mainnet`, `preprod` or `preview` can move to Amaru
without changing its block producer, other relays, or firewall. Amaru is deployed in its
own top-level folder next to cnode, catches up while cnode keeps serving, and
then takes over cnode's port. cnode's folder and database stay untouched, so
going back only means swapping the services again. These steps cover relays
only.

If the relay still uses the standard layout that `guild-deploy.sh` created,
`migrate-from-cnode.sh` runs these steps for you. It reads the port, topology,
and socket from the running cardano-node. Once Amaru is deployed next to cnode,
as in the first step below, run:

```bash
/opt/cardano/amaru/scripts/migrate-from-cnode.sh prepare   # peers, bootstrap, catch up next to cnode
/opt/cardano/amaru/scripts/migrate-from-cnode.sh switch    # take over cnode's port, verify
/opt/cardano/amaru/scripts/migrate-from-cnode.sh rollback  # back to cnode
```

`prepare` sets the peer limits described below and raises
`AMARU_PEERS_MAX_DOWNSTREAM` to at least 50. `switch` rolls back on its own if
Amaru does not come up on cnode's port and follow the chain. Use `-c <path>` when
cnode is not in `/opt/cardano/cnode`. The script refuses block producers and
deployments without a Guild manifest. If you have customised the scripts or set
the relay up another way, follow the manual steps instead.

Deploy Amaru next to the running relay. It uses `/opt/cardano/amaru`, its own
services, and port 3000, so it does not clash with cnode:

```bash
./guild-deploy.sh -i amaru -n preview -s pd
```

Copy the relay's `localRoots`, such as its block producer and other relays,
into `AMARU_PEER` in `/opt/cardano/amaru/scripts/amaru.env`, which takes a
comma-separated `host:port` list. This prints them in that form; put IPv6
addresses in brackets:

```bash
jq -r '[.localRoots[].accessPoints[] | "\(.address):\(.port)"] | join(",")' /opt/cardano/cnode/files/topology.json
```

Count every peer in `AMARU_PEER`, the network's default peer included. Amaru's
default peer mix reserves two upstream slots for static peers. With more, set
`AMARU_PEERS_MIX` with a static floor of that count, such as `static!3` for three
peers, and set `AMARU_PEERS_MAX_UPSTREAM` one higher. Static peers also take
spare upstream slots first, so without that extra slot the relay would not keep
a discovered peer.

Then bootstrap and start Amaru, and follow it with
`/opt/cardano/amaru/scripts/gLiveView.sh` until it reaches the tip. Both nodes
run at the same time until the switch, so allow memory for both. On a preview
relay, Amaru reached the tip about 13 minutes after bootstrap. It used up to
0.6 GiB next to cardano-node's 3.7 GiB.

To switch, stop and disable cnode, give Amaru cnode's port (`CNODE_PORT` in
cnode's `env`, 6000 by default), and restart it. `AMARU_PEERS_MAX_DOWNSTREAM` also
caps accepted inbound connections, 10 by default on the testnets, which a public
relay quickly reaches, so raise it at the same time:

```bash
sudo systemctl disable --now cnode
sed -i -e 's|^AMARU_PEERS_LISTEN_ON=.*|AMARU_PEERS_LISTEN_ON="0.0.0.0:6000"|' \
  -e 's|^AMARU_PEERS_MAX_DOWNSTREAM=.*|AMARU_PEERS_MAX_DOWNSTREAM="50"|' /opt/cardano/amaru/scripts/amaru.env
/opt/cardano/amaru/scripts/amaru.sh restart
```

Peers that point at the relay reconnect on their own. Amaru listened on the port
again about 10 seconds after cnode stopped.

To go back, swap the services the other way and give Amaru its own port again,
so that it does not clash with cnode when it is started later. cnode starts from
its own database and catches up from where it stopped:

```bash
sudo systemctl disable --now amaru amaru-metrics
sed -i 's|^AMARU_PEERS_LISTEN_ON=.*|AMARU_PEERS_LISTEN_ON="0.0.0.0:3000"|' /opt/cardano/amaru/scripts/amaru.env
sudo systemctl enable --now cnode
```

Once you no longer need the rollback, remove cnode's database to free its disk
space.

## Monitoring and helper compatibility

The common `env`, libraries, Amaru adapter, and `gLiveView.sh` are deployed.
Amaru does not expose a native Prometheus listener. The supplied `amaru.env`
enables OpenTelemetry and sends:

| Signal | Local collector endpoint |
| --- | --- |
| OTLP metrics, traces, and logs | `127.0.0.1:4317` using gRPC |
| Prometheus output for gLiveView | `127.0.0.1:8889/metrics` |

Amaru does not embed a Prometheus server. The `:8889` endpoint in Amaru's
documentation is produced by the OpenTelemetry Collector configuration in the
upstream monitoring stack. Guild deploys that same bridge contract as a
minimal host profile: it preserves Amaru's cardano-node-compatible metric
names, resource-label filtering, batching, and stale-series expiry. The local
profile uses the equivalent current collector options for suffix and scope
handling.

Both endpoints bind only to loopback. Unlike Amaru's complete Docker
monitoring stack, the Guild profile does not require Loki or Tempo; traces and
logs are accepted into a no-op sink while metrics are converted to Prometheus.
The node service wants and starts after the companion metrics service.

Run the dashboard after both services are active:

```bash
/opt/cardano/amaru/scripts/amaru.sh status
/opt/cardano/amaru/scripts/gLiveView.sh
```

The shared adapter normalizes Amaru's common chain, epoch, density, fork,
mempool, served-block, version, uptime, and process measurements. Uptime is
derived from local timing for the active node process. Amaru 10.11.20261105
and later export the connection-manager gauges, shown as incoming, outgoing,
and unidirectional connections. Amaru exports no peer-set metrics. With older
releases, gLiveView counts the node process's established TCP sessions
instead. Press `p` for peer analysis: round-trip
times, and each connection's use and hot or warm state on both sides, with the
peers that delivered headers and blocks first, read from Amaru's log in the
journal. See the [gLiveView guide](../Scripts/gliveview.md#connection-use-peer-states-and-scores).

Epoch progress is calculated from Amaru's latest locally validated epoch and
epoch slot. While the node is catching up this is local-ledger epoch progress,
not a network synchronization percentage. The common CHAIN section displays
the local block and slot together with a timing-derived Tip gap; it does not
display a separate reference tip.

The adapter also handles scientific-notation values emitted through
OpenTelemetry. The header shows Amaru's logo and name, or `[Amaru]` when it
[falls back to text](../Scripts/gliveview.md).

Amaru uses the same availability-driven dashboard as the other
implementations. Compact mode presents the primary operational metrics,
including the latest block delay, which gLiveView derives from Amaru's header
and block-fetch timings. Verbose mode adds the share of recent blocks received
within 1, 3, and 5 seconds, runtime, and Amaru-specific samples, including:

- process CPU usage and disk read/write rates;
- open file descriptors and their limit;
- mempool synchronization time and accepted/rejected insertions;
- rejected consensus headers;
- the latest header delay, fetch wait, block fetch, and header-forwarding
  durations.

Each item is shown only if the installed Amaru release exports the underlying
sample. Amaru does not expose managed-runtime garbage-collection metrics; the
collector's own runtime telemetry is not treated as node telemetry.

Press `n` to open the common Network page for static node, network, service,
deployment-path, and metrics-endpoint metadata. Dashboard and metadata values
are bounded to preserve alignment. Normal refreshes update changed rows, with
a periodic whole-frame row reconciliation that does not clear the terminal
first. See the [gLiveView guide](../Scripts/gliveview.md) for display controls.

On a block producer, gLiveView identifies the role as `Core` and adds a
block-production section with the current KES period, the remaining KES
periods, and the calculated KES expiry. Verbose mode adds the first and last
KES period of the operational certificate. Amaru exports no forging flag, so
the adapter recognizes a producer by the operational-certificate gauges that
only Amaru's forge stage reports. They first appear once the node adopts a
new tip after a start; until then the dashboard shows `Relay`. Amaru exports
no leader-schedule or forged-block counters, so those rows are absent. On a
relay the network-derived KES period stays on the Network page.

Metrics absent from the current scrape are omitted rather than displayed as
zero. CNCLI blocklog, Koios pool data and Mithril signer remain cnode-only.
Mithril helpers, db-sync, Ogmios, and other socket-dependent cnode tools
remain undeployed. CNTools 14 is available through
the stable `scripts/cntools.sh` launcher. Use `cntools.sh -l` for Koios-backed
online actions or `cntools.sh -o` for offline key and signing workflows; Amaru
does not provide a compatible local query socket. See the
[CNTools guide](../Scripts/cntools.md) for available actions and requirements.

If the node is running but gLiveView reports that metrics are unavailable,
check the bridge and its loopback output:

```bash
/opt/cardano/amaru/scripts/amaru.sh status
curl --fail http://127.0.0.1:8889/metrics
```

## Upstream release contract and sources

- [Release and binary assets](https://github.com/pragma-org/amaru/releases)
- [Upstream install and run instructions](https://github.com/pragma-org/amaru/blob/main/README.md)
- [Bootstrap snapshot design](https://github.com/pragma-org/amaru/blob/main/docs/BOOTSTRAP.md)
- [Bootstrap command safeguards](https://github.com/pragma-org/amaru/blob/main/crates/amaru/src/bin/amaru/cmd/node/bootstrap.rs)
- [Node run options and environment bindings](https://github.com/pragma-org/amaru/blob/main/crates/amaru/src/bin/amaru/cmd/node/run.rs)
- [OpenTelemetry monitoring model](https://github.com/pragma-org/amaru/blob/main/monitoring/README.md)
- [Canonical OTLP-to-Prometheus collector configuration](https://github.com/pragma-org/amaru/blob/main/monitoring/otlp-collector.yml)
- [Upstream cardano-node metric compatibility contract](https://github.com/pragma-org/amaru/blob/main/scripts/compare-metrics.json)
- [Embedded defaults and network peers](https://github.com/pragma-org/amaru/blob/main/crates/amaru/src/lib.rs)
- [Distribution archive layout](https://github.com/pragma-org/amaru/blob/main/Makefile)

The rolling resolver enforces the GitHub digest published for the selected
Amaru tar archive. The collector remains independently pinned to its official
release URL and SHA-256 digest in `release.json`. Amaru's versioned archive
places the executable at `bin/amaru`; the installer accepts only that path
shape.
