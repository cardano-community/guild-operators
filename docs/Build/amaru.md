# Amaru deployment profile

!!! danger "Experimental rolling-release support"
    Amaru is under rapid development and ships a new public-beta build most
    weeks. Upstream now documents mainnet relays and testnet block production,
    but the Guild Operators profile remains restricted to `preprod` and
    `preview` and runs Amaru as a relay only. Do not use it as a mainnet or
    stake-pool deployment.

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

The executables are installed as `~/.local/bin/amaru`,
`~/.local/bin/cardano-cli-amaru`, and `~/.local/bin/otelcol-contrib`. Existing
binaries are copied to `~/.local/bin/archive/` first. The isolated Cardano CLI
lets CNTools build, inspect, and sign transactions without implying that Amaru
has a node-to-client socket. Both `linux-x86_64` and `linux-aarch64` release
artifacts are supported.

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
- `AMARU_WITH_OPEN_TELEMETRY=metrics`, because the local collector keeps only
  metrics;
- `AMARU_LOG`, matching Amaru's default log filter;
- `AMARU_PEER`, the network's public relay, because current releases no longer
  default to one.

The profile deliberately does not create `chain/` or `ledger/`. Upstream
bootstrap refuses to proceed if either already holds data, which prevents a
partial or existing database from being overwritten automatically. The
launcher treats a node as bootstrapped only when both directories contain
data.

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

The default relay listener is TCP 3000 on `0.0.0.0`. `AMARU_PEERS_MAX_DOWNSTREAM`
also caps accepted inbound connections, 10 by default; raise it for a busier
public relay. Outbound connections reuse the listen port as their source port
when the operating system allows it, so firewall rules that match on source
port should allow the relay port in both directions. Set
`AMARU_PEERS_EPHEMERAL_OUTBOUND_PORT=true` to use ephemeral ports instead.

Amaru provides no cardano-node-compatible node-to-client socket, and this
profile does not enable Amaru's testnet block production. Its optional HTTP
transaction submission endpoint, `AMARU_SUBMIT_API_LISTEN_ON`, is disabled
because it has no built-in authentication or TLS.

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
derived from local timing for the active node process. Amaru exports no
connection or peer-set metrics, so gLiveView counts the node process's
established TCP sessions instead. Press `p` for peer analysis: round-trip
times, and each connection's use and hot or warm state on both sides, with the
peers that delivered headers and blocks first, read from Amaru's log in the
journal. See the [gLiveView guide](../Scripts/gliveview.md#connection-use-peer-states-and-scores).

Epoch progress is calculated from Amaru's latest locally validated epoch and
epoch slot. While the node is catching up this is local-ledger epoch progress,
not a network synchronization percentage. The common CHAIN section displays
the local block and slot together with a timing-derived Tip gap; it does not
display a separate reference tip.

The adapter also handles scientific-notation values emitted through
OpenTelemetry. The header explicitly identifies `[Amaru]`.

Amaru uses the same availability-driven relay dashboard as the other
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

Metrics absent from the current scrape are omitted rather than displayed as
zero. This relay profile does not expose cnode block-production, KES,
operational-certificate, CNCLI blocklog, Koios, Mithril signer, or interactive
peer-analysis sections. Mithril helpers, db-sync, Ogmios, and other
socket-dependent cnode tools remain undeployed. CNTools 14 is available through
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
