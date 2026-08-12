# cnode deployment profile

The `cnode` profile deploys Intersect's `cardano-node` implementation and
remains the default when `guild-deploy.sh -i` is omitted:

```bash
./guild-deploy.sh -n mainnet -s pd
./guild-deploy.sh -i cnode -n preview -s pd
```

It supports `mainnet`, `preprod`, `preview`, and the Guild development network.
When `-t` is omitted, the deployment root and service name default to `cnode`.

## Profile contract

`guild-deploy.sh` owns all common deployment inputs, including repository,
branch, implementation, network, target path, service name, node port, download
timeouts, and selective flags. `deploy-cnode.sh` is an internal source-only
profile; it has no editable user-variable section and must not be run directly.

The common flags `p`, `d`, `f`, and `s` have the same meaning for every
implementation:

| Flag | Common action |
| --- | --- |
| `p` | Install runtime packages |
| `d` | Download and verify the selected implementation binaries |
| `f` | Force replacement of cnode network files; topology, node, and db-sync configs are backed up |
| `s` | Force helper-script replacement, including every script and common `env` user-variable section |

cnode additionally supports:

| Flag | cnode action |
| --- | --- |
| `b` | Install the Haskell build toolchain |
| `l` | Build the required libsodium fork |
| `m` | Install Mithril signer and client |
| `c` | Install CNCLI |
| `o` | Install Ogmios |
| `w` | Install Cardano Hardware CLI |
| `x` | Install Cardano Signer |
| `r` | Install openBlockPerf |

The profile refreshes `submitapi.json` on every deployment run. Without `f`,
it preserves existing node, topology, db-sync, and genesis files when the
required base configuration is already present.

The cnode-only `CNODE_SKIP_DBSYNC_DOWNLOAD=Y` dispatcher setting lets controlled
container builds omit the optional db-sync binary from `-s d`. The historical
`SKIP_DBSYNC_DOWNLOAD` name is accepted temporarily during migration.

## Release metadata

All versioned software components and their primary download or installation
artifacts selected by the cnode deployment profile are recorded in one compact
manifest:

```text
files/node-implementations/cnode/release.json
```

The manifest intentionally contains only fields consumed by deployment or
source builds. The primary `cardano-node` entry uses a concrete
`version`/`artifacts` structure. Dingo and Amaru use separate rolling GitHub
release contracts described in their own deployment guides. Independently
released cnode software is grouped by how the deployment consumes it:

| Section | Components | Manifest shape |
| --- | --- | --- |
| Primary entry | cardano-node, cardano-submit-api, bech32 archive | Concrete `version` and architecture-keyed `artifacts` |
| `companions` | cardano-cli, cardano-address, cardano-db-sync | Concrete `version` and architecture-keyed `artifacts` |
| `tools` | CNCLI, Cardano Hardware CLI, Ogmios, Cardano Signer, Mithril, Catalyst Toolbox, GHCup | Concrete artifacts or a `latest` GitHub selector |
| `managedInstallers` | openBlockPerf package and installer | Latest or concrete package version; concrete installer |
| `supportArtifacts` | Ledger and Trezor udev rules | Concrete URL and SHA-256 digest |
| `build` | GHC, Cabal, libsodium, secp256k1, BLST | Toolchain version strings and immutable source commits |

### Concrete and latest versions

The primary entry, every companion, and every pinned tool declares a concrete
`version` plus an `artifacts` map. Each architecture entry contains only its
download `url` and `sha256`.
Artifact filenames are derived from the URL or the GitHub API response.
Release-page links, timestamps, checksum provenance, and other upstream
metadata are not duplicated because deployment does not consume them.

A rolling direct-binary tool instead declares `version: "latest"`, its
`github` owner/repository, and architecture-specific `assets` regular
expressions. Its optional `channel` defaults to `stable`; `channel: "any"`
also permits prereleases. An optional `minimumVersion` prevents resolution
below the audited floor. When requested, deployment must select exactly one
matching release asset and verify the SHA-256 digest published by GitHub.
Failure at any step stops installation.

Latest entries do not retain concrete fallback artifacts. To pin one later,
replace `version: "latest"` with the exact version, remove `github`, `assets`
and `channel`, and add an architecture-keyed `artifacts` map:

```json
{
  "tools": {
    "cncli": {
      "version": "6.7.0",
      "minimumVersion": "6.5.1",
      "artifacts": {
        "linux-x86_64": {
          "url": "https://example.invalid/cncli-6.7.0.tar.gz",
          "sha256": "<reviewed-sha256>"
        }
      }
    }
  }
}
```

The example URL and digest are placeholders and intentionally fail manifest
validation until replaced with the reviewed artifact values.

The `minimumVersion` field may remain on a pinned tool. Pinned tools replace
`github`, `assets`, and `channel` with their reviewed artifact map.

The currently tracked tools are:

| Tool | Channel | Architectures | Audited minimum |
| --- | --- | --- | --- |
| CNCLI | Stable | x86_64 | 6.5.1 |
| Cardano Hardware CLI | Any | x86_64, aarch64 | 1.17.0 |
| Ogmios | Any | x86_64, aarch64 | — |
| Cardano Signer | Stable | x86_64, aarch64 | 1.24.0 |
| Mithril | Stable | x86_64, aarch64 | — |
| openBlockPerf | Stable PyPI package | Python/Linux | — |

Catalyst Toolbox is a pinned x86_64 tool consumed on demand by CNTools. Its
previous unversioned Koios download is now represented by a concrete version,
URL, and verified SHA-256 digest in the same manifest.

GHCup is also pinned, architecture-selected, and checksum-verified. The source
build no longer executes the mutable `get-ghcup` bootstrap or upgrades GHCup
outside the manifest. GHC and Cabal retain their own pinned versions, while all
three C-library source dependencies use immutable 40-character commits.
Hardware CLI deployment likewise verifies the pinned Ledger installer and
Trezor rules before writing either file under `/etc/udev/rules.d`.

openBlockPerf remains responsible for constructing its virtual environment and
installing Python dependencies. Guild Operators downloads only the concrete,
checksum-verified installer recorded in `managedInstallers`. With package
`version: "latest"`, deployment lets that installer request the latest stable
`openblockperf` package from PyPI. Replacing it with a concrete package version
passes that version to the same verified installer. Its immutable URL and
SHA-256 pin the installer in both cases; the verified script reports its own
version, so that value is not duplicated in the manifest.

`schemaVersion: 1` is the current compact, exact contract. Legacy metadata and
unrecognized fields are rejected rather than treated as an additive schema.

The profile installs a validated copy as:

```text
${NODE_HOME}/files/cnode-release.json
```

The installed file is an atomically replaced, validated copy of the repository
manifest. It is not an inventory or history of dynamically installed
versions. Concrete artifacts are read directly from it.
For a selected latest direct-binary tool, the profile reads its resolver and
architecture selector, queries GitHub once, and keeps the resolved tag, URL,
and digest only for that installation run. A later invocation resolves latest
again. The openBlockPerf package is the explicit exception: its verified
installer delegates the latest stable package lookup and package transport to
PyPI/pip.

`-s d` selects node, CLI, address, and optional db-sync artifacts from this
file. The other cnode-specific selective flags consume their corresponding
`tools` entries, `-s r` consumes `managedInstallers.openblockperf`, and CNTools
consumes the pinned Catalyst Toolbox entry when that feature is first used.
Direct downloads performed by Guild Operators are SHA-256 verified before
installation. The manifest therefore replaces scattered constants and
separate version text files as the cnode deployment source of truth.

The `build.toolchain` values for GHC and Cabal are plain version strings.
`build.sourceDependencies` records repository URLs, display versions, and
immutable commit refs. These build fields are consumed only by source-build
flags and do not change a binary-only deployment. Node and CLI compatibility
thresholds are not part of this compact manifest.

Version constants owned by a helper script itself, common monitoring or gREST
packages, operating-system packages, and transitive dependencies selected
inside an upstream package manager remain outside this cnode manifest. They
should move into an appropriate manifest section if centralized later rather
than being mislabeled as node companions.

## Configuration layout

The canonical repository configuration is implementation-scoped:

```text
files/configs/cnode/
├── guild/
├── mainnet/
├── preprod/
└── preview/
```

Installed filenames remain unchanged under `${NODE_HOME}/files`, so existing
cnode launchers and helper scripts continue to work. Repository branches and
tags created before this restructuring retain their former
`files/configs/<network>` paths; the current code uses only the
implementation-scoped path.

To deploy one of those historical layouts, download `guild-deploy.sh` from the
same tag and pass that tag with `-b`, for example:

```bash
curl -sfS -o guild-deploy.sh \
  https://raw.githubusercontent.com/cardano-community/guild-operators/node-10.1.4/scripts/cnode-helper-scripts/guild-deploy.sh
chmod 700 guild-deploy.sh
./guild-deploy.sh -b node-10.1.4 -n mainnet -t cnode -p /opt/cardano
```

The tag is the complete compatibility boundary; current releases do not retain
duplicate copies of historical repository paths.

## Installed layout

The default target remains `/opt/cardano/cnode`:

```text
/opt/cardano/cnode/
├── .deployment.json
├── .guild-source-receipt.json
├── db/
├── files/
│   ├── cnode-release.json
│   ├── config.json
│   ├── topology.json
│   ├── dbsync.json
│   ├── submitapi.json
│   └── *-genesis.json
├── guild-db/
├── logs/
├── mithril/
├── priv/
├── scripts/
│   ├── .cntools/
│   │   └── generations/
│   │       └── <64-character-sha256>/
│   ├── adapters/cnode.adapter
│   ├── lib/
│   ├── cntools/
│   │   └── libs/legacy/
│   │       └── <64-character-sha256>/   # ten read-only fragments
│   ├── cntools.library
│   ├── cntools.sh
│   ├── cnode.sh
│   ├── env
│   └── compatible helper scripts
└── sockets/
    └── node.socket
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

The initial `NODE_PORT` value is written to the newly installed common `env`.
Later deployments preserve the operator's existing `CNODE_PORT` setting unless
the common environment is explicitly replaced with `-s s`.

The current manifest was verified against the official
[cardano-node 11.0.1 release](https://github.com/IntersectMBO/cardano-node/releases/tag/11.0.1)
and
[cardano-cli 11.0.0.0 release](https://github.com/IntersectMBO/cardano-cli/releases/tag/cardano-cli-11.0.0.0),
including their published checksum manifests and GitHub release-asset digests.
The companion Koios bundles, pinned Catalyst Toolbox and GHCup binaries,
openBlockPerf installer, and hardware-wallet support files were fully
downloaded and hashed. Every latest direct-tool installation requires the
digest published with its selected GitHub release asset.

For building node binaries from source and operating the launcher, see
[cardano-node and cardano-cli](node-cli.md).
