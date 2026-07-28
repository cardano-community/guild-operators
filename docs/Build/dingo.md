# Dingo deployment profile

!!! danger "Experimental testnet support"
    Dingo describes itself as under heavy active development and not ready for
    production use. The Guild Operators profile is therefore restricted to
    `preprod` and `preview`, runs in relay mode, and must not be used with
    mainnet funds or block-production keys.

## Supported deployment

The common deployment entrypoint selects Dingo with `-i dingo`. For example:

```bash
./guild-deploy.sh -i dingo -n preview -s pd
```

When `-t` is omitted the target directory and service name default to `dingo`.
The supported selective-install flags are:

| Flag | Dingo action |
| --- | --- |
| `p` | Install runtime packages needed by the deployment and verifier |
| `d` | Download and checksum-verify the pinned Dingo binary |
| `f` | Replace an existing Dingo configuration, retaining a backup |
| `s` | Force helper-script replacement; this replaces common `env` user-variable settings |

The cnode-specific flags `b`, `l`, `m`, `c`, `o`, `w`, `x`, and `r` are
rejected instead of silently installing incompatible components. With no
`-s` value, the profile refreshes scripts, common libraries, the release
manifest, and missing configuration while preserving existing Dingo config.

The profile installs the selected, pinned binary in `~/.local/bin/dingo` and
keeps the preceding binary in `~/.local/bin/archive/` when one exists.
Both `linux-x86_64` and `linux-aarch64` release artifacts are supported.

### Release contract

`files/node-implementations/dingo/release.json` is the single Dingo release
contract. It intentionally contains only the schema and implementation
identity, the pinned version, and an HTTPS URL plus SHA-256 digest for each
supported architecture. The experimental Dingo profile does not resolve a
moving `latest` release.

Deployment requires both architecture records and validates the compact
manifest again before a binary download. The archive is written to a fixed
private staging filename, so no path or filename from release metadata reaches
the local filesystem. Its digest and the installed binary version are both
verified before deployment succeeds.

## Layout and configuration

The default layout below assumes `/opt/cardano/dingo`:

```text
/opt/cardano/dingo/
├── .deployment.json
├── db/
├── files/
│   ├── dingo-release.json
│   └── dingo.yaml
├── logs/
├── snapshots/
├── sockets/
│   └── dingo.socket       # created while Dingo is running
└── scripts/
    ├── adapters/dingo.adapter
    ├── archive/
    ├── lib/
    ├── dingo.env
    ├── dingo.sh
    ├── gLiveView.sh
    └── env
```

Dingo embeds the Cardano configuration, genesis files, and topology for known
networks in its executable. Guild Operators therefore self-hosts only the
Dingo runtime YAML/environment overlay and pinned release metadata; it does
not duplicate the embedded Cardano JSON files.

The supplied YAML deliberately enforces:

- `storageMode: core`
- `runMode: serve`
- `blockProducer: false`
- optional Blockfrost, UTxO RPC, Mesh, Bark, pprof, and tracing endpoints off
- a 30-second graceful shutdown window

The launcher re-exports the relay-only settings before every run so an inherited
shell variable cannot accidentally turn this profile into a block producer.

## Bootstrap and service

Dingo contains its own Mithril client. Bootstrap the database before starting
the service:

```bash
/opt/cardano/dingo/scripts/dingo.sh bootstrap
/opt/cardano/dingo/scripts/dingo.sh -d
/opt/cardano/dingo/scripts/dingo.sh start
```

`-d` installs and enables the systemd unit but intentionally does not start it.
The other lifecycle commands are `start`, `status`, `stop`, `restart`, `logs`,
and `remove`. `remove` deletes only the unit; it leaves the database and config
intact. The launcher can recover the service identity from `.deployment.json`,
so `status` and `remove` still work if the Dingo binary or configuration files
have already been removed. The manifest and launcher location are authoritative:
if `dingo.env` declares a conflicting implementation, network, service, or
deployment root, run/bootstrap/install commands stop and require a corrected
deployment instead of managing the wrong target.

Upstream's figures at the pinned release estimate that bootstrap needs about
150 GB free for preprod or 50 GB for preview because the snapshot and database
coexist during import. These figures grow over time, so check upstream before
provisioning a host.

## Network exposure

| Endpoint | Default | Binding |
| --- | ---: | --- |
| Ouroboros node-to-node | TCP 3001 | `0.0.0.0` |
| Ouroboros node-to-client | TCP 3002 | `127.0.0.1` |
| Ouroboros node-to-client | Unix socket | `$NODE_HOME/sockets/dingo.socket` |
| Prometheus | TCP 12798 | Dingo's shared public bind address |

Because the metrics listener uses Dingo's `bindAddr`, the supplied
`0.0.0.0` public relay bind also exposes TCP 12798. Restrict that port with the
host or network firewall.

## Monitoring and helper compatibility

The common `env`, libraries, Dingo adapter, and `gLiveView.sh` are deployed.
Run the dashboard after the relay starts:

```bash
/opt/cardano/dingo/scripts/gLiveView.sh
```

The adapter reads Dingo's native Prometheus endpoint and accepts the
`network="<network>"` label that Dingo adds to its metric samples. Common
chain, epoch, density, mempool, connection, propagation, process, and runtime
measurements are mapped into the shared gLiveView interface. The header
explicitly identifies `[Dingo]`.

Dingo uses the same availability-driven relay dashboard as the other
implementations. Its native tip-gap measurement is normalized into the common
CHAIN section alongside the local block and slot; a separate reference-tip
field is not shown. Compact mode presents the primary operational metrics,
while verbose mode adds available connection, propagation, and runtime detail.
Metrics absent from the current scrape are omitted instead of displayed as
zero.

Press `n` to open the Network page. Dingo's Go runtime version, epoch length,
and Shelley start time appear there with the common node, network, service,
deployment-path, and metrics-endpoint metadata rather than in the live
dashboard.

The common renderer bounds and formats values to preserve column alignment.
Normal refreshes update only changed rows, with a periodic whole-frame row
reconciliation that does not clear the terminal first. See the
[gLiveView guide](../Scripts/gliveview.md) for compact and verbose contents
and display controls.

This relay profile does not expose the cnode block-producer, KES,
operational-certificate, CNCLI blocklog, Koios, Mithril signer, or interactive
peer-analysis sections.

CNTools, Ogmios, db-sync, and standalone Mithril helper scripts remain outside
this experimental profile. Dingo contains its own Mithril bootstrap client,
which is used through `dingo.sh bootstrap` rather than the cnode Mithril
wrappers.

If gLiveView cannot connect, verify the process and endpoint independently:

```bash
/opt/cardano/dingo/scripts/dingo.sh status
curl --fail http://127.0.0.1:12798/metrics
```

The endpoint is consumed through loopback by gLiveView, but Dingo binds the
metrics listener with its shared public `bindAddr`; the firewall warning above
still applies.

## Research and pinned sources

The profile was implemented against Dingo `v0.67.1`:

- [Release and binary assets](https://github.com/blinklabs-io/dingo/releases/tag/v0.67.1)
- [Upstream README and testnet warning](https://github.com/blinklabs-io/dingo/blob/v0.67.1/README.md)
- [Complete upstream YAML example](https://github.com/blinklabs-io/dingo/blob/v0.67.1/dingo.yaml.example)
- [Embedded Cardano configuration](https://github.com/blinklabs-io/dingo/tree/v0.67.1/config/cardano)
- [Runtime configuration implementation](https://github.com/blinklabs-io/dingo/blob/v0.67.1/config.go)
- [Release packaging workflow](https://github.com/blinklabs-io/dingo/blob/v0.67.1/.github/workflows/publish.yml)

The exact artifact URLs and SHA-256 digests are recorded in
`files/node-implementations/dingo/release.json`. Dingo did not publish a
separate checksum manifest for this release, so the pinned digests were taken
from the GitHub release asset digests and are enforced before extraction. The
release workflow packages one executable named `dingo` at the archive root;
the installer rejects an archive with any other expected binary layout.
