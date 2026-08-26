# Node implementation deployment architecture

Guild Operators can deploy one of three Cardano node implementations through
the same `guild-deploy.sh` entrypoint:

| Implementation | Selector | Default folder | Networks | Deployment status |
| --- | --- | --- | --- | --- |
| cardano-node | `cnode` | `/opt/cardano/cnode` | mainnet, preprod, preview, guild | Default, supported deployment |
| Dingo | `dingo` | `/opt/cardano/dingo` | preprod, preview | Experimental relay and block-producer deployment |
| Amaru | `amaru` | `/opt/cardano/amaru` | preprod, preview | Experimental rolling-release, relay-only deployment |

Omitting `-i` selects `cnode`, preserving the existing install path and
behavior:

```bash
./guild-deploy.sh -n mainnet -s pd
./guild-deploy.sh -i dingo -n preview -s pd
./guild-deploy.sh -i amaru -n preprod -s pd
```

Alternate implementations require an explicit network on their initial
deployment. A later run against an existing, valid `.deployment.json` may omit
`-n`; the dispatcher restores and validates the recorded network. Alternate
profiles are deliberately restricted to testnets and reject cnode-only
selective-install flags. Dingo can select relay or block-producer mode and
installs the shared CNTools wallet/pool interface; Amaru remains relay-only.

## Dispatcher and implementation profiles

The downloaded `guild-deploy.sh` is the common dispatcher. It:

1. parses and validates common arguments;
2. chooses the implementation-specific default for `-t`;
3. protects an existing target from implementation or network collisions;
4. restores the stored repository, branch, network, and service identity from
   `.deployment.json` (an explicitly configured network must match);
5. makes one shallow checkout of that exact repository branch and records its
   commit revision;
6. loads the selected profile and all Guild-owned payloads from that checkout;
7. runs the profile with the manifest marked `deploying`, installs the current
   dispatcher in the target `scripts` directory, and finalizes the manifest as
   `deployed` only after success.

The bootstrap file does not download profiles or payload files one by one.
Every Guild-owned file comes from the same temporary checkout, while external
release APIs and checksum-verified binary downloads retain their existing
flows. The checkout must have no modified tracked files, and each profile
preflights its required shell, JSON, and template payloads before changing the
node target. Deployment, branch changes, and common-runtime refreshes also take
the same target-wide lock; concurrent writers fail without partially
interleaving files or metadata. Guild-deploy reads the stored source selection
under that lock, releases it while cloning, then verifies under a new lock that
the target did not change before the checkout is applied.

The checkout dispatcher carries a small snapshot-capability marker. A branch
or tag from before snapshot deployment fails with an instruction to use its
matching historical `guild-deploy.sh`; it never falls back to that dispatcher's
former per-file download flow. A failed clone falls back to `master` only when
Git can confirm that the requested remote branch or tag does not exist.

Implementation-specific work remains separate:

- `scripts/cnode-helper-scripts/deploy-cnode.sh` retains the established
  cardano-node deployment behavior and selective flags;
- `scripts/dingo-helper-scripts/deploy-dingo.sh` installs Dingo's node
  layout, rolling release, independently pinned CLI companion, configuration,
  launcher, adapter, common gLiveView dashboard, and CNTools;
- `scripts/amaru-helper-scripts/deploy-amaru.sh` installs Amaru's relay
  layout, rolling release, environment, launcher, adapter, managed
  OpenTelemetry bridge, and common gLiveView dashboard.

This split keeps each node's bootstrap, configuration, and command-line
semantics in its own profile. It intentionally does not introduce a generic
`node.sh`.

The dispatcher is also the only deployment script with an editable
user-variable section. It owns common inputs such as implementation, network,
repository, branch, target, port, and download timeouts. Implementation
profiles are internal, source-only modules: they validate the dispatcher
contract, derive their action state from `-s`, and contain only
implementation-specific deployment logic. cnode's optional db-sync omission
for controlled container builds is exposed as a clearly cnode-specific
dispatcher setting rather than a hidden profile variable.

The dispatcher also gives every implementation the same package-manager
experience. `PACKAGE_MANAGER_OUTPUT=compact` is the default: successful
`apt-get`, `dnf`, and `yum` calls report transaction totals, changed packages,
and notices or warnings without streaming download and unpacking progress.
Failures show bounded diagnostics and a short output tail, retain the full
private log at a reported path, and preserve the package manager's exit status.
Set `PACKAGE_MANAGER_OUTPUT=verbose` to stream the raw output when
troubleshooting.

When binary installation is selected with `-s d`, all implementations use
`$HOME/.local/bin`. Node binary names are distinct (`cardano-node`, `dingo`,
and `amaru`), so they can coexist. Dingo installs its standard Cardano CLI as
`cardano-cli-dingo`, independently of cnode's `cardano-cli`. Amaru additionally
installs the pinned `otelcol-contrib` executable used by its local metrics
bridge. Every
implementation has reviewed release metadata under
`files/node-implementations/<implementation>/release.json`. The profiles
select Linux architecture artifacts from that metadata and verify SHA-256
digests before extraction. cnode uses reviewed, concrete node artifacts;
Dingo and Amaru resolve their newest published non-draft GitHub release,
including prereleases, and require the selected asset's GitHub-published
digest. cardano-cli is represented as a separately owned companion entry in
both the cnode and Dingo manifests because it is released independently. The
two explicit versions may diverge without overwriting each other's binaries.
Amaru's OpenTelemetry Collector also remains independently pinned.

Network templates follow the same implementation namespace:

```text
files/configs/<implementation>/<network>/
```

The current cnode profile uses only `files/configs/cnode/<network>`. Historical
release tags retain the former `files/configs/<network>` layout for operators
who intentionally deploy an older tagged version.

## Deployment manifest

Every successful deployment owns one manifest at
`${NODE_HOME}/.deployment.json`. It is deployment metadata, not node
configuration:

```json
{
  "schemaVersion": 1,
  "deploymentStatus": "deployed",
  "implementation": "dingo",
  "network": "preview",
  "branch": "master",
  "repository": "cardano-community/guild-operators",
  "sourceRevision": "0123456789abcdef0123456789abcdef01234567",
  "serviceName": "dingo",
  "nodeVersion": "vX.Y.Z (commit REVISION)",
  "targetNodeVersion": "latest",
  "metricsProvider": "prometheus",
  "capabilities": {
    "n2c": true,
    "localCli": true,
    "metrics": true,
    "forging": true
  }
}
```

`nodeVersion` is the first version line reported by the executable actually
installed in `$HOME/.local/bin` (or, if absent there, the selected executable
on `PATH`). It is empty if no executable is installed. `targetNodeVersion` is
the release policy selected by the deployment profile, even when `-s d` was
not requested. It is a concrete cnode version and `latest` for Dingo or Amaru.
This distinction prevents rolling release metadata from being mistaken for
the binary currently on the host.

`sourceRevision` is the exact Git commit used for the dispatcher runtime,
profile, and Guild-owned payload files in that deployment. The invoking
dispatcher's editable user-variable header is preserved separately. Older
manifests without this field remain readable during migration; every new
successful deployment records it.

The dispatcher validates the complete version-1 manifest and refuses to reuse
a manifest-owned folder with malformed or incomplete metadata, a different
implementation or network, or a service name that does not match the target
folder. Common helpers and alternate launchers apply the same fail-closed
rule. Configuration and chain data are never automatically converted between
implementations.

On both first installs and updates, the dispatcher records
`deploymentStatus: "deploying"` after ensuring the target layout exists and
before the profile changes scripts or configuration. This makes an
interrupted operation visible and safely resumable. Helpers refuse to consume
an unfinished manifest; the status changes to `"deployed"` only after the
profile completes.

The manifest replaces `scripts/.env_branch`. On the first successful update of
a legacy cnode deployment, the old branch value is imported and the sidecar is
moved into `scripts/archive`. Supplying `-b` to the dispatcher or a compatible
updating helper writes the new branch to `.deployment.json` atomically while
preserving the other fields.

That recorded branch remains the source of truth for helper self-updates. If
it disappears upstream or cannot be verified, those updates stop without
replacing files; they do not silently fetch `master`. The dispatcher is the
explicit recovery path: `guild-deploy.sh -b <branch>` selects a replacement
branch, while a dispatcher invocation whose selected or stored branch is
unavailable warns, falls back to `master`, and records `master` if deployment
continues successfully.

## Shared helpers and node adapters

There is one canonical copy of implementation-neutral tools under
`scripts/common-helper-scripts`:

```text
common-helper-scripts/
├── env
├── gLiveView.sh
├── cntools.sh
├── cntools.library
└── lib/
    ├── deployment.library
    ├── env.library
    ├── node-api.library
    └── systemd.library
```

The common `env` reads `.deployment.json`, loads shared functions, and then
loads the selected adapter from `scripts/adapters/<implementation>.adapter`.
Adapters declare capabilities and translate implementation-specific paths,
process discovery, metrics, and local interfaces into the shared API.
The common `env`, four common libraries, and selected adapter are staged and
shell-validated as one bundle. Replacement is atomic as a bundle: a failed
download, validation, move, or catchable termination restores the complete
preceding runtime rather than leaving mixed generations.

The former cnode-specific source URLs for `env`, gLiveView, and CNTools are
retired rather than publishing duplicate copies or forwarders that cannot run
inside an older flat deployment. An old helper checking one of those URLs gets
an update failure and keeps its existing local file. Running the current
`guild-deploy.sh` installs the complete canonical runtime before any helper is
replaced.

Deploying a common runtime does not imply that every common tool is supported.
Capability checks fail closed when an adapter cannot provide the required node
interface. cnode and Dingo install the same canonical CNTools files; the Dingo
adapter supplies `cardano-cli-dingo` and its node-to-client socket. Amaru does
not install CNTools.

### Common monitoring contract

All three profiles install the same canonical `gLiveView.sh`. The selected
adapter translates its native metric names into a normalized availability
registry. gLiveView then renders only the metrics observed in the latest
successful scrape; it does not turn an unsupported or missing sample into a
zero. All relay profiles use one common availability-driven layout. Its CHAIN
section places local Block and Slot beside a normalized Tip gap and does not
show the calculated reference slot as a separate value.

Compact mode presents the primary common operational signals. Verbose mode
adds available connection, propagation, runtime, and live
implementation-specific measurements. Static node, network, deployment, and
runtime metadata is available from the `[n] Network` page instead of occupying
the live dashboard.

Compatible aggregate peer-set and process measurements use common fields.
Dingo additionally contributes availability-gated Go runtime, database, cache,
and nonzero diagnostic counters. Amaru contributes availability-gated process,
mempool, and consensus measurements. Metrics from the OpenTelemetry
Collector's own runtime are not presented as Amaru node metrics.

Metric cells and metadata fields use bounded formatting to preserve the fixed
terminal layout. Each refresh updates only rows whose content changed. A
periodic whole-frame reconciliation redraws rows without clearing the terminal
first, so stale content is corrected without an avoidable blank-screen repaint.

The dashboard header always identifies the connected implementation:
`cardano-node`, `Dingo`, or `Amaru`. cnode and Dingo expose native Prometheus
endpoints. Amaru emits OTLP; its documented `:8889` endpoint is supplied by
Amaru's reference OpenTelemetry Collector configuration rather than the node
binary. The Guild deployment installs a minimal, host-safe form of that
upstream bridge. It receives metrics, traces, and logs over OTLP/gRPC on
`127.0.0.1:4317` and exposes Prometheus-formatted metrics on
`127.0.0.1:8889`. Both Amaru monitoring endpoints are loopback-only.

For Dingo, `capabilities.forging: true` records that the implementation profile
can forge; it does not claim that every deployed process is a producer. The
launcher selects the live role from the complete operational hot-key set and
gLiveView confirms it from Dingo's `forging_enabled` metric. A Dingo producer
uses the common KES and block-production display. CNCLI blocklog, Koios pool,
Mithril signer, and interactive peer-analysis sections remain cnode-only. See the
[gLiveView guide](../Scripts/gliveview.md) for the displayed metric groups.

## Current helper compatibility

| Tool or interface | cnode | Dingo | Amaru |
| --- | --- | --- | --- |
| Node launcher and systemd unit | Yes | Yes | Yes |
| Shared environment and adapter | Yes | Yes | Yes |
| gLiveView | Yes, native Prometheus | Yes, native Prometheus | Yes, managed OTLP-to-Prometheus bridge |
| CNTools | Yes | Not deployed | Not deployed |
| cardano-cli local queries | Yes | Not exposed through the profile | No compatible node-to-client socket |
| db-sync, Ogmios, standalone Mithril helpers | Existing support | Not deployed | Not deployed |
| Block production | Yes | Experimental on preprod/preview | Not supported by this profile |

Dingo samples carry an upstream `network` label; the shared parser accepts
labelled and unlabelled Prometheus samples. Amaru samples pass through
OpenTelemetry and may use scientific notation. The normalization requested in
[issue #1912](https://github.com/cardano-community/guild-operators/issues/1912)
is part of the common parser. In both cases, metric availability—not the node
selector—drives whether a dashboard cell is shown.

See the implementation guides for exact bootstrap, firewall, and storage
details:

- [cnode deployment profile](cnode.md)
- [Dingo deployment profile](dingo.md)
- [Amaru deployment profile](amaru.md)
- [Building cardano-node and cardano-cli](node-cli.md)

## Component-owned systemd units

The legacy `deploy-as-systemd.sh` orchestrator has been removed. Each script
now installs and manages the units it owns, using the common
`systemd.library`. Existing `-d` install aliases remain where they already
existed.

New units contain both a Guild Operators marker and the exact owning launcher
path. Install and remove operations refuse to touch an unrelated same-name
unit, including a unit owned by another Guild deployment on the same host. If
the expected unit file is absent, removal is a no-op rather than disabling an
unverified same-name transient or vendor unit. Recognized units from the old
orchestrator are migrated through a component-specific legacy signature, so
existing operators can still replace or remove them safely.

| Component | Command |
| --- | --- |
| cnode, db-sync, submit-api, Ogmios, Mithril signer | `<script> systemd install\|remove\|status` |
| Dingo | `dingo.sh -d` or `dingo.sh install`; also `remove` and `status` |
| Amaru node and metrics bridge | `amaru.sh -d` or `amaru.sh install`; lifecycle commands manage both units |
| CNCLI operational units | `cncli.sh -d [scope]` or `cncli.sh systemd install\|remove\|status [scope]` |
| Topology Updater units | `topologyUpdater.sh -d` or `topologyUpdater.sh systemd install [restart-seconds]`; lifecycle via `topologyUpdater.sh systemd remove\|status` |

Installation enables units but does not start the node. Bootstrap and inspect
an alternate implementation before starting it explicitly.

Topology Updater predates Cardano P2P and is deprecated. Its service ownership
was moved for consistency and cleanup only; new P2P deployments should not
install it. Disabled BlockPerf and Log Monitor scripts can remove or inspect
stale units, but refuse to install a service that cannot run with current
tracing.

## Release policy maintenance

The primary cnode release remains pinned. Updating its supported node version
requires a reviewed manifest change with concrete artifact URLs and SHA-256
digests, plus validation of affected configuration, launcher behavior, dry
deployment, systemd lifecycle, tests, and documentation.

Dingo and Amaru instead use a compact rolling policy: `version: "latest"`,
their official GitHub repository, and architecture-specific asset-name
selectors. `-s d` queries up to 100 releases, excludes drafts, and selects the
non-draft entry with the newest publication timestamp. Stable releases and
prereleases have equal eligibility. The matching uploaded asset must be
unique, non-empty, hosted under the selected repository and tag, and carry a
valid GitHub SHA-256 digest. Any API, selection, URL, or digest problem stops
deployment without falling back to an older release.

The rolling policy removes routine manifest edits for each Dingo or Amaru
tag, but upstream changes to asset naming, archive layout, commands, config,
or compatibility still require review and corresponding selector, installer,
test, or documentation updates. The Amaru OpenTelemetry Collector remains a
concrete, checksummed artifact because it has an independent release cycle.

The cnode manifest additionally centralizes binaries installed by its selective
deployment flags, its pinned GHCup bootstrap, immutable source dependency
commits, the on-demand Catalyst Toolbox dependency, and the verified
openBlockPerf installer and hardware-wallet rules in
`files/node-implementations/cnode/release.json`. The root node entry,
companions, and pinned tools use a concrete `version` and checksummed
`artifacts`. Direct-binary tools with `version: "latest"` resolve their
declared `github`, `channel`, and architecture `assets` only when requested.
The channel defaults to `stable`, and resolution requires the selected GitHub
asset's SHA-256 digest.

To freeze a rolling tool, replace `version: "latest"`, `github`, `assets`, and
any `channel` with a concrete `version` and architecture-keyed `artifacts`.
OpenBlockPerf is installer-managed: replace its package version with a
concrete value while retaining the pinned installer. Latest resolutions are
ephemeral and are not written back to the installed
`${NODE_HOME}/files/cnode-release.json` manifest.

This distinction keeps cnode upgrades reproducible while making fast-moving
alternate-node and selected cnode-tool update policies explicit and
reviewable.
