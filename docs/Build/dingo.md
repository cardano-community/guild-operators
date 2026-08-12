# Dingo deployment profile

!!! danger "Experimental testnet support"
    Dingo describes itself as under heavy active development and not ready for
    production use. The Guild Operators profile is therefore restricted to
    `preprod` and `preview`. Relay and block-producer modes are available for
    testing, but must not be used on mainnet or with keys controlling real
    funds.

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
| `d` | Resolve and verify the newest Dingo binary, and install Dingo's independently pinned cardano-cli companion |
| `f` | Replace an existing Dingo configuration, retaining a backup |
| `s` | Force helper-script replacement; this replaces common `env` user-variable settings |

The cnode-specific flags `b`, `l`, `m`, `c`, `o`, `w`, `x`, and `r` are
rejected instead of silently installing incompatible components. With no
`-s` value, the profile refreshes scripts, common libraries, the release
manifest, and missing configuration while preserving existing Dingo config.

The profile installs the selected node in `~/.local/bin/dingo` and its CLI
companion in `~/.local/bin/cardano-cli-dingo`. Existing copies are retained in
`~/.local/bin/archive/` before replacement. The distinct CLI name prevents a
Dingo deployment from replacing cnode's `~/.local/bin/cardano-cli`. Both
`linux-x86_64` and `linux-aarch64` release artifacts are supported.

### Release contract

`files/node-implementations/dingo/release.json` is the single Dingo release
contract. Its node fields contain the schema and implementation identity,
`version: "latest"`, the official GitHub repository, and one
architecture-specific asset-name selector per supported Linux platform. The
node entry contains no release tag, download URL, or checksum that needs
updating for each upstream release. A small `companions.cardano-cli` entry is
deliberately pinned with explicit architecture URLs and checksums. It is owned
by the Dingo profile, independently of the cnode release manifest, so either
profile can change CLI versions without affecting the other.

When `-s d` is selected, deployment queries the official GitHub releases API
and chooses the most recently published non-draft release. Stable and
prerelease entries are both eligible. The configured selector must match
exactly one uploaded artifact for the current architecture, and that artifact
must publish a valid GitHub SHA-256 digest. Its repository, tag, filename,
download URL, size, and digest are validated together before download.

The initial Dingo CLI pin is 11.0.0.0, matching the version selected by Dingo's
upstream Dockerfile. Dingo does not provide a separate operator CLI: its Unix
socket implements Ouroboros node-to-client and is designed for `cardano-cli`
and other standard Cardano clients.

Resolution fails instead of falling back to an older node release if GitHub is
unavailable or the newest release has missing, ambiguous, or malformed asset
metadata. The archive is downloaded to a fixed private staging filename,
verified against the resolved digest, and checked for the expected executable
layout and version before installation succeeds.

## Layout and configuration

The default layout below assumes `/opt/cardano/dingo`:

```text
/opt/cardano/dingo/
├── .deployment.json
├── .guild-source-receipt.json
├── db/
├── files/
│   ├── dingo-release.json
│   └── dingo.yaml
├── logs/
├── priv/
│   └── pool/
│       └── <POOL_NAME>/
│           ├── hot.skey       # online KES signing key
│           ├── vrf.skey       # online VRF signing key
│           └── op.cert        # operational certificate
├── snapshots/
├── sockets/
│   └── dingo.socket       # created while Dingo is running
└── scripts/
    ├── .cntools/
    │   └── generations/
    │       └── <64-character-sha256>/
    ├── adapters/dingo.adapter
    ├── archive/
    ├── lib/
    ├── cntools/
    │   └── libs/legacy/
    │       └── <64-character-sha256>/   # ten read-only fragments
    ├── cntools.library
    ├── cntools.sh
    ├── dingo.env
    ├── dingo.sh
    ├── gLiveView.sh
    └── env
```

The content-addressed CNTools directory is an inactive candidate bound to the
deployment receipt. Deployment neither creates nor moves `.cntools/active` or
`.cntools/previous`; the top-level `cntools.sh` remains the authoritative
legacy-menu entrypoint during this refactor stage. `cntools.library` is now a
compatibility facade over the exact bundle beneath `scripts/cntools`. The
dispatcher publishes that complete bundle atomically before its facade and
retains preceding valid bundle IDs during the transition. The inactive Stage 3
candidate carries a validated 15-menu/54-action shadow registry, but its 54
action stubs cannot dispatch production workflows.

Dingo embeds the Cardano configuration, genesis files, and topology for known
networks in its executable. Guild Operators therefore self-hosts only the
Dingo runtime YAML/environment overlay and rolling release policy; it does
not duplicate the embedded Cardano JSON files.

The supplied YAML uses a conservative relay default:

- `storageMode: core`
- `runMode: serve`
- `blockProducer: false`
- optional Blockfrost, UTxO RPC, Mesh, Bark, pprof, and tracing endpoints off
- a 30-second graceful shutdown window

`dingo.sh` owns the effective runtime role. It resets inherited Dingo forging
variables, inspects the configured `POOL_DIR`, and exports Dingo's official
`CARDANO_BLOCK_PRODUCER` and `CARDANO_SHELLEY_*` variables only when the
complete operational credential set is present. Environment variables have
higher priority than the YAML relay default, matching Dingo's upstream
configuration precedence.

## Relay and block-producer modes

Role selection follows the established cnode behavior. Edit
`scripts/dingo.env` and set `POOL_NAME` to the pool subfolder below
`$NODE_HOME/priv/pool`, or set an absolute `POOL_DIR` directly:

```bash
POOL_NAME="my-pool"
# Equivalent advanced override:
# POOL_DIR="/secure/online-keys/my-pool"
```

The expected filenames deliberately match the Guild cnode convention:

| File | Purpose |
| --- | --- |
| `hot.skey` | KES signing key |
| `vrf.skey` | VRF signing key |
| `op.cert` | Operational certificate |

- If none of these files is present, `dingo.sh run` starts a relay.
- If all three are present and readable, it starts a block producer.
- A partial set is treated as an operator error and startup stops with the
  missing paths instead of silently falling back to a relay.

Dingo loads the standard `cardano-cli` text-envelope formats, so an existing
testnet pool's operational hot keys do not need conversion. Copy only the
three online files to the node. Keep the cold signing key and operational
certificate counter offline. The KES and VRF signing files must be owned by
the service user and have no group or other permissions; for example:

```bash
chmod 700 /opt/cardano/dingo/priv/pool/my-pool
chmod 600 /opt/cardano/dingo/priv/pool/my-pool/{hot.skey,vrf.skey}
chmod 644 /opt/cardano/dingo/priv/pool/my-pool/op.cert
```

At startup Dingo itself validates the credential formats, operational
certificate signature and counter, KES period, and the pool registration's
VRF key against ledger state. Guild does not duplicate those protocol checks.
The pool must already be registered and delegated on the selected testnet to
have a chance of being elected as slot leader. The profile deploys CNTools for
experimental wallet, operational-key, pool-registration, and pool-management
testing. Keep cold signing keys and the operational-certificate counter in a
reviewed offline workflow; Dingo support does not change that security model.

`dingo.sh bootstrap` always forces relay mode and does not require hot keys.
This permits state import before the operational credentials are copied. The
generated systemd unit remains role-neutral: every service start repeats the
same complete-key-set detection, so adding or removing the set changes the
runtime role without regenerating the unit.

For a hidden producer architecture, configure a Dingo topology containing only
the operator's relays and restrict the producer's node-to-node port at the
firewall. Dingo disables peer sharing by default for block producers, but the
Guild profile cannot infer the operator's relay addresses. Set
`CARDANO_TOPOLOGY` in `dingo.env` when supplying a custom topology.

## Bootstrap and service

Dingo contains its own Mithril client. Bootstrap the database before starting
the service:

```bash
/opt/cardano/dingo/scripts/dingo.sh bootstrap
/opt/cardano/dingo/scripts/dingo.sh -d
/opt/cardano/dingo/scripts/dingo.sh start
```

After `guild-deploy.sh` completes, it suggests bootstrap only while the Dingo
database is empty and suggests `-d` only while the systemd unit is absent. A
binary or script refresh of an existing deployment therefore prints neither
next step.

`-d` installs and enables the systemd unit but intentionally does not start it.
The other lifecycle commands are `start`, `status`, `stop`, `restart`, `logs`,
and `remove`. `remove` deletes only the unit; it leaves the database and config
intact. The launcher can recover the service identity from `.deployment.json`,
so `status` and `remove` still work if the Dingo binary or configuration files
have already been removed. The manifest and launcher location are authoritative:
if `dingo.env` declares a conflicting implementation, network, service, or
deployment root, run/bootstrap/install commands stop and require a corrected
deployment instead of managing the wrong target.

Upstream's current guidance estimates that bootstrap needs about
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

The common `env`, libraries, Dingo adapter, `gLiveView.sh`, and CNTools are
deployed.
Run the dashboard after the relay starts:

```bash
/opt/cardano/dingo/scripts/gLiveView.sh
```

The adapter reads Dingo's native Prometheus endpoint and accepts the
`network="<network>"` label that Dingo adds to its metric samples. Common
chain, epoch, density, mempool, connection, propagation, process, and runtime
measurements are mapped into the shared gLiveView interface. The header
explicitly identifies `[Dingo]`.

Dingo uses the same availability-driven dashboard as the other
implementations. Its native tip-gap measurement is normalized into the common
CHAIN section alongside the local block and slot; a separate reference-tip
field is not shown. Compact mode presents the primary operational metrics,
including aggregate known, established, and active peer sets when exported.
Verbose mode adds available connection, propagation, Go runtime, open-file,
database-size, and cache-efficiency detail. Selected internal error counters
are shown only when nonzero. Metrics absent from the current scrape are omitted
instead of displayed as zero.

Press `n` to open the Network page. Dingo's Go runtime version, epoch length,
and Shelley start time appear there with the common node, network, service,
deployment-path, and metrics-endpoint metadata rather than in the live
dashboard.

The common renderer bounds and formats values to preserve column alignment.
Normal refreshes update only changed rows, with a periodic whole-frame row
reconciliation that does not clear the terminal first. See the
[gLiveView guide](../Scripts/gliveview.md) for compact and verbose contents
and display controls.

When Dingo reports forging enabled, gLiveView identifies the role as `Core` and
adds an availability-driven block-production section. Current and remaining
KES periods, calculated KES expiry, leader slots, and forged/adopted outcomes
are shown when exported. Verbose mode adds leadership checks, non-leader and
failed-forge counters, operational-certificate KES bounds, and Dingo-specific
forge diagnostics. CNCLI blocklog, Koios pool data, Mithril signer, and
interactive peer analysis remain cnode-only.

CNTools local mode connects `cardano-cli-dingo` to
`$NODE_HOME/sockets/dingo.socket`. The Dingo adapter supplies both paths and
advertises local query and submission only for this profile. To use a reviewed
custom CLI instead, uncomment `CCLI` in `scripts/env`; an explicit value is
never replaced by the adapter. CNTools support is experimental and focused on
wallet and pool workflows. cnode-only integrations such as CNCLI block logs,
Catalyst's pinned cnode companion policy, hardware-wallet deployment flags,
and leader-log tooling are not implied by installing the shared CNTools files.

Ogmios, db-sync, and standalone Mithril helper scripts remain outside this
experimental profile. Dingo contains its own Mithril bootstrap client, which
is used through `dingo.sh bootstrap` rather than the cnode Mithril wrappers.

If gLiveView cannot connect, verify the process and endpoint independently:

```bash
/opt/cardano/dingo/scripts/dingo.sh status
curl --fail http://127.0.0.1:12798/metrics
```

The endpoint is consumed through loopback by gLiveView, but Dingo binds the
metrics listener with its shared public `bindAddr`; the firewall warning above
still applies.

## Upstream release contract and sources

- [Release and binary assets](https://github.com/blinklabs-io/dingo/releases)
- [Upstream README and testnet warning](https://github.com/blinklabs-io/dingo/blob/main/README.md)
- [Upstream Dockerfile and cardano-cli pin](https://github.com/blinklabs-io/dingo/blob/main/Dockerfile)
- [Complete upstream YAML example](https://github.com/blinklabs-io/dingo/blob/main/dingo.yaml.example)
- [Block-producer startup validation](https://github.com/blinklabs-io/dingo/blob/main/node_forging.go)
- [Forging and KES metrics](https://github.com/blinklabs-io/dingo/blob/main/ledger/forging/metrics.go)
- [Embedded Cardano configuration](https://github.com/blinklabs-io/dingo/tree/main/config/cardano)
- [Runtime configuration implementation](https://github.com/blinklabs-io/dingo/blob/main/config.go)
- [Release packaging workflow](https://github.com/blinklabs-io/dingo/blob/main/.github/workflows/publish.yml)

The rolling manifest matches Dingo's Linux `amd64` or `arm64` tar archive.
GitHub's digest for that exact release asset is enforced before extraction.
The release workflow packages one executable named `dingo` at the archive
root; the installer rejects an archive with a different layout. The separate
Intersect cardano-cli archive is verified against the explicit checksum in the
Dingo manifest, then its architecture-specific executable is installed under
the collision-free `cardano-cli-dingo` name.
