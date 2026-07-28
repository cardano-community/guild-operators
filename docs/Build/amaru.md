# Amaru deployment profile

!!! danger "Experimental prerelease support"
    The pinned Amaru build is a prerelease. The Guild Operators profile is
    restricted to `preprod` and `preview`, runs as a relay, and does not support
    block production. Do not use it as a mainnet or stake-pool deployment.

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
| `d` | Download and checksum-verify the pinned Amaru and OpenTelemetry Collector binaries |
| `f` | Replace an existing Amaru environment config, retaining a backup |
| `s` | Force helper-script replacement; this replaces common `env` user-variable settings |

The cnode-specific flags `b`, `l`, `m`, `c`, `o`, `w`, `x`, and `r` are
rejected. With no `-s` value, the profile refreshes scripts, common libraries,
the release manifest, and missing configuration while preserving an existing
Amaru environment file. Before preserving it, the deployment verifies that it
contains the managed OpenTelemetry settings required by gLiveView. An older
environment with telemetry disabled or without the managed bridge contract is
rejected with an instruction to re-run using `-s f`; the forced replacement
archives the old file before installing the current template.

The pinned executables are installed as `~/.local/bin/amaru` and
`~/.local/bin/otelcol-contrib`. Existing binaries are copied to
`~/.local/bin/archive/` first. Both `linux-x86_64` and `linux-aarch64` release
artifacts are supported.

### Release contract

`files/node-implementations/amaru/release.json` is the single Amaru release
contract. It intentionally contains only the schema and implementation
identity, the pinned Amaru version and artifacts, and the pinned collector
version and artifacts. Each supported architecture has an HTTPS URL and
SHA-256 digest. The experimental Amaru profile does not resolve moving
`latest` releases.

Deployment requires both architecture records and validates the compact
manifest again before a binary download. The archive is written to a fixed
private staging filename, so no path or filename from release metadata reaches
the local filesystem. Its digest and the installed binary version are both
verified before deployment succeeds.

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
├── snapshots/
└── scripts/
    ├── adapters/amaru.adapter
    ├── archive/
    ├── lib/
    ├── amaru.env
    ├── amaru.sh
    ├── gLiveView.sh
    └── env
```

Amaru embeds the global parameters, bootstrap snapshot catalogue, and default
peer information for well-known networks. No cardano-node-style config or
genesis JSON bundle is needed for the supported networks. Guild Operators
self-hosts a small environment template for each network and its pinned
release metadata. Automatic chain-database migration is disabled so an upgrade
cannot transform persistent state without an explicit operator decision.

The profile deliberately does not create `chain/` or `ledger/`. Upstream
bootstrap refuses to proceed if either target already exists, which prevents a
partial or existing database from being overwritten automatically.

## Bootstrap and service

Amaru needs three trusted consecutive epoch snapshots before it can run:

```bash
/opt/cardano/amaru/scripts/amaru.sh bootstrap
/opt/cardano/amaru/scripts/amaru.sh -d
/opt/cardano/amaru/scripts/amaru.sh start
```

The bootstrap command disables OpenTelemetry export only for that invocation.
Bootstrap telemetry is not used by gLiveView. Normal `run` and systemd
operation continue to use the telemetry settings from `amaru.env`.

If bootstrap fails after creating `chain/` or `ledger/`, inspect and move or
remove the partial state yourself before retrying; the Guild launcher will
never delete it.

For container volumes, the launcher accepts `AMARU_STATE_ROOT` as a parent
directory and derives `<root>/chain` and `<root>/ledger` without pre-creating
either child. Host deployments leave it unset and retain the paths in
`amaru.env`.

`-d` installs and enables two systemd units but intentionally does not start
them: `<service-name>.service` for Amaru and
`<service-name>-metrics.service` for the local OpenTelemetry Collector. The
collector restarts on failure. The experimental Amaru node unit uses
`Restart=always` so unexpected node exits are restarted. An explicit
`systemctl stop` is still honored.

The other lifecycle commands are `start`, `status`, `stop`, `restart`, `logs`,
and `remove`; they manage both units. `remove` deletes only those units and
preserves node state and monitoring configuration. The launcher can recover
the service identity from `.deployment.json`, so `status` and `remove` still
work after the Amaru binary or environment file is gone. The manifest and
launcher location are authoritative: if `amaru.env` declares a conflicting
implementation, network, service, or deployment root, run/bootstrap/install
commands stop and require a corrected deployment instead of managing the
wrong target.

The default relay listener is TCP 3000 on `0.0.0.0`. Amaru currently provides
no cardano-node-compatible node-to-client socket in this profile and block
production is unsupported. Its optional HTTP transaction submission endpoint
is disabled because it has no built-in authentication or TLS.

## Monitoring and helper compatibility

The common `env`, libraries, Amaru adapter, and `gLiveView.sh` are deployed.
Amaru does not expose a native Prometheus listener. The supplied `amaru.env`
enables OpenTelemetry and sends:

| Signal | Local collector endpoint |
| --- | --- |
| OTLP traces and logs | `127.0.0.1:4317` using gRPC |
| OTLP metrics | `127.0.0.1:4318/v1/metrics` using HTTP |
| Prometheus output for gLiveView | `127.0.0.1:8889/metrics` |

All three endpoints bind only to loopback. The Guild-managed collector accepts
traces and logs into a no-op sink and converts metrics to Prometheus without
renaming Amaru's metric family. The node service wants and starts after the
companion metrics service.

Run the dashboard after both services are active:

```bash
/opt/cardano/amaru/scripts/amaru.sh status
/opt/cardano/amaru/scripts/gLiveView.sh
```

The shared adapter normalizes Amaru's common chain, epoch, density, mempool,
connection, served-block, version, uptime, and process measurements. Uptime is
derived from local timing for the active node process.

Epoch progress is calculated from Amaru's latest locally validated epoch and
epoch slot. While the node is catching up this is local-ledger epoch progress,
not a network synchronization percentage. The common CHAIN section displays
the local block and slot together with a timing-derived Tip gap; it does not
display a separate reference tip.

The adapter also handles scientific-notation values emitted through
OpenTelemetry. The header explicitly identifies `[Amaru]`.

Amaru uses the same availability-driven relay dashboard as the other
implementations. Compact mode presents the primary operational metrics.
Verbose mode adds any available connection, propagation, runtime, and
Amaru-specific samples, including:

- process CPU usage;
- resident and virtual memory;
- open file descriptors;
- accepted and rejected mempool insertions.

Press `n` to open the common Network page for static node, network, service,
deployment-path, and metrics-endpoint metadata. Dashboard and metadata values
are bounded to preserve alignment. Normal refreshes update changed rows, with
a periodic whole-frame row reconciliation that does not clear the terminal
first. See the [gLiveView guide](../Scripts/gliveview.md) for display controls.

Metrics absent from the current scrape are omitted rather than displayed as
zero. This relay profile does not expose cnode block-production, KES,
operational-certificate, CNCLI blocklog, Koios, Mithril signer, or interactive
peer-analysis sections. CNTools, Mithril helpers, db-sync, Ogmios, and other
socket-dependent cnode tools remain undeployed.

If the node is running but gLiveView reports that metrics are unavailable,
check the bridge and its loopback output:

```bash
/opt/cardano/amaru/scripts/amaru.sh status
curl --fail http://127.0.0.1:8889/metrics
```

## Research and pinned sources

The profile was implemented against prerelease `v10.11.20260723`:

- [Release and binary assets](https://github.com/pragma-org/amaru/releases/tag/v10.11.20260723)
- [Upstream install and run instructions](https://github.com/pragma-org/amaru/blob/v10.11.20260723/README.md)
- [Bootstrap snapshot design](https://github.com/pragma-org/amaru/blob/v10.11.20260723/docs/BOOTSTRAP.md)
- [Bootstrap command safeguards](https://github.com/pragma-org/amaru/blob/v10.11.20260723/crates/amaru/src/bin/amaru/cmd/node/bootstrap.rs)
- [Node run options and environment bindings](https://github.com/pragma-org/amaru/blob/v10.11.20260723/crates/amaru/src/bin/amaru/cmd/node/run.rs)
- [OpenTelemetry monitoring model](https://github.com/pragma-org/amaru/blob/v10.11.20260723/monitoring/README.md)
- [Embedded defaults and network peers](https://github.com/pragma-org/amaru/blob/v10.11.20260723/crates/amaru/src/lib.rs)
- [Distribution archive layout](https://github.com/pragma-org/amaru/blob/v10.11.20260723/Makefile)

The exact Amaru and collector artifact URLs and SHA-256 digests are recorded
in `files/node-implementations/amaru/release.json` and enforced before
extraction. The Amaru digest matches the checksum manifest published with its
release; the collector is independently pinned to its official release
artifact. The versioned Amaru archive places the executable at `bin/amaru`;
the installer searches only for that path shape and rejects a mismatched
archive.
