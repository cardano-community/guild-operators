#### Architecture

The architecture for the main Cardano components is described in the
[Cardano architecture documentation](https://docs.cardano.org/about-cardano/explore-more/cardano-architecture).

#### Choosing a node implementation {: #choosing-a-node-implementation}

Guild Operators is now structured as a **node-agnostic deployment framework**.
The same `guild-deploy.sh` entrypoint handles common arguments, target
validation, release metadata, `.deployment.json`, shared runtime libraries,
and the hand-off to an implementation-specific deployment profile. Each node
keeps its own launcher, configuration, bootstrap process, data layout, and
systemd service.

Node-agnostic architecture does not mean that every Guild helper already works
with every node. Compatibility is enabled only after a tool's commands,
interfaces, and metrics have been verified for that implementation. Today,
the complete Guild operator toolset remains available only with `cnode`.
Dingo and Amaru are deliberately small, experimental relay deployments, but
all three now include the common gLiveView dashboard through a normalized,
availability-driven metrics interface.

Multiple independent node implementations can improve client diversity and
let operators explore different languages, architectures, resource trade-offs,
and interfaces. They still implement the same Cardano protocol, but their
databases and configuration are not interchangeable. Always give each
implementation its own deployment target; do not point a new implementation
at another node's existing data directory.

| Guild selector | Node implementation | Project and team | Current Guild support |
| --- | --- | --- | --- |
| `cnode` | [cardano-node](https://github.com/IntersectMBO/cardano-node), written in Haskell | The established Cardano node originated under Input Output Global (IOG). Stewardship of the core repositories has moved to the member-based [Intersect MBO](https://www.intersectmbo.org/news/open-horizons-cardano-migrates-to-intersect). | Default and production option. Relays and block producers on mainnet and testnets, with the established Guild helper suite. |
| `dingo` | [Dingo](https://github.com/blinklabs-io/dingo), written in Go | Developed by [Blink Labs](https://blinklabs.io/about), a Cardano-focused open-source software team. Upstream describes Dingo as under heavy active development and not ready for production use. | Experimental relay only on `preprod` and `preview`, with gLiveView over native Prometheus. No mainnet, pool keys, or unverified cnode helper suite. |
| `amaru` | [Amaru](https://github.com/pragma-org/amaru), written in Rust | Hosted by the not-for-profit [PRAGMA](https://pragma.io/) open-source association and developed by [contributors from across the Cardano ecosystem](https://amaru.global/about/). Upstream describes Amaru as exploratory, with features still limited or incomplete. | Experimental rolling-release relay only on `preprod` and `preview`, with gLiveView through a managed, host-safe form of Amaru's reference OpenTelemetry-to-Prometheus bridge. No mainnet, block production, or socket-dependent cnode helpers. |

##### cnode / cardano-node

`cnode` is the Guild profile and launcher name for the `cardano-node`
executable. It is the mature choice for an existing stake-pool deployment,
mainnet, block production, or use of the broader Guild toolset such as CNTools,
CNCLI, Mithril helpers, db-sync, and Ogmios. It supports
`mainnet`, `preprod`, `preview`, and the Guild development network. Omitting
`-i` selects `cnode`, preserving the familiar deployment path and behavior.

##### Dingo

Dingo is an independent Go implementation from Blink Labs. Its upstream
project includes node-to-client connectivity, Prometheus metrics, several
storage and API options, and a built-in Mithril bootstrap client. The current
Guild profile intentionally exposes only a conservative relay configuration;
upstream block-production and application-interface capabilities are not an
indication that Guild has verified them. Choose Dingo when you specifically
want to test the Go implementation and its interoperability on a supported
testnet. The profile includes gLiveView, which identifies Dingo in its header
and displays only the native metrics available in each scrape.

##### Amaru

Amaru is an independent Rust implementation developed under PRAGMA. Its goals
include client diversity, a modular architecture, and exploring different
resource-usage trade-offs from the established Haskell node. The current Guild
profile bootstraps from Amaru snapshots, runs as a relay, and does not provide
a cardano-node-compatible local socket. The profile enables Amaru's
OpenTelemetry integration and deploys a loopback-only, minimal form of Amaru's
reference Prometheus bridge for gLiveView. Choose Amaru when you specifically
want to evaluate the Rust implementation on a supported testnet.

!!! tip "Which implementation should I choose?"
    - Choose **cnode** for mainnet, block production, an existing stake pool,
      or the full Guild Operators experience.
    - Choose **Dingo** to evaluate the Go node as an experimental testnet
      relay.
    - Choose **Amaru** to evaluate the Rust node as an experimental testnet
      relay.
    - If you are unsure, omit `-i`; the safe default is **cnode**.

For the precise deployment contract, layouts, and current compatibility
matrix, see the [node implementation architecture
guide](Build/node-implementations.md) and the implementation-specific
[cnode](Build/cnode.md), [Dingo](Build/dingo.md), and
[Amaru](Build/amaru.md) pages.

#### Manual Software Pre-Requirements


While we do not intend to hand out step-by-step instructions, the tools are often misused as a shortcut to avoid ensuring base skillsets mentioned on home page. Some of the common gotchas that we often find SPOs to miss out on:

- It is imperative that pools operate with highly accurate system time, in
  order to propagate blocks to the network promptly. See Ubuntu's
  [time-synchronization guidance](https://ubuntu.com/server/docs/network-ntp);
  the exact setup depends on your operating system.
- Ensure your Firewall rules at Network as well as OS level are updated according to the usage of your system, you'd want to whitelist the rules that you really need to open to world (eg: You might need node and SSH ports to be open to relays and perhaps home workstation on core, while open node to internet on relays, depending on your topology and configuration that you run).
- Update your SSH Configuration to prevent password-based logon.
- Ensure that you use offline workflow, you should never require to have your offline keys on online nodes. The tools provide you backup/restore functionality to only pass online keys to online nodes.

#### Pre-Requisites

!!! info "Reminder !!"
    You're expected to run the commands below from same session, using same working directories as indicated and using a `non-root user with sudo access`. You are expected to be familiar with this as part of pre-requisite skill sets for stake pool operators.

##### Set up OS packages, folder structure and fetch files from repo {: #os-prereqs}

The pre-requisites for Linux systems are automated to be executed as a single script. This script uses opt-in election of what you'd like the script to do. The defaults without any arguments will only update static part of script contents for you.
To download the pre-requisites scripts, execute the below:

```bash
mkdir -p "$HOME/tmp"
cd "$HOME/tmp"
# Install curl
# CentOS / RedHat - sudo dnf -y install curl
# Ubuntu / Debian - sudo apt -y install curl
curl -sS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh
chmod 755 guild-deploy.sh
```

!!! info "Important !!"
    Please familiarise yourself with `guild-deploy.sh -h` before proceeding.
    The commands below are examples; choose arguments appropriate for your
    implementation, network, and target.

The bootstrap URL intentionally remains under `scripts/cnode-helper-scripts`.
That stable path preserves the existing download and upgrade workflow, but the
downloaded dispatcher itself is node-agnostic.

The usage syntax can be checked using `./guild-deploy.sh -h`. The same
downloaded entrypoint dispatches to the selected node implementation:

``` bash
Usage: guild-deploy.sh [-i <cnode|dingo|amaru>] [-n <network>] \
                       [-p path] [-t name] [-b branch] [-u] [-s flags]

-i    Node implementation (default: cnode)
-n    Network. cnode defaults to mainnet; alternate profiles require an
      explicit supported network on initial deployment (an existing manifest
      restores it on later runs)
-p    Parent folder (default: /opt/cardano)
-t    Top-level folder and service name (default: selected implementation)
-b    Guild Operators branch (default: stored deployment branch, then master)
-u    Skip the dispatcher update check
-s    Selective install flags
        p  runtime prerequisites
        d  selected implementation binaries
        f  force implementation configuration overwrite
        s  force helper-script user-variable overwrite
```

The cnode profile additionally supports:

- `b`: install the Haskell build toolchain and source-build prerequisites
- `l`: build and install the cnode libsodium dependency
- `m`: install Mithril binaries
- `c`: install CNCLI
- `o`: install Ogmios
- `w`: install Cardano Hardware CLI
- `x`: install Cardano Signer
- `r`: install openBlockPerf

Dingo and Amaru reject those cnode-only choices instead of silently installing
incompatible software. See
[Node implementation deployment architecture](Build/node-implementations.md)
and the implementation-specific
[cnode](Build/cnode.md), [Dingo](Build/dingo.md), and
[Amaru](Build/amaru.md) guides.

Package-manager output is compact by default. The deployment shows transaction
totals, packages that were installed or updated, and any notices or warnings,
while hiding repository-download and unpacking progress. If a package command
fails, compact diagnostics and the last output lines are printed with the
original exit status; the full private log is retained at the reported path.
To see the package manager's unfiltered output during troubleshooting, set
`PACKAGE_MANAGER_OUTPUT=verbose` in the `guild-deploy.sh` user-variable block
or for one invocation:

```bash
PACKAGE_MANAGER_OUTPUT=verbose ./guild-deploy.sh -i amaru -n preprod -s p
```

!!! warning "Alternate implementations are experimental"
    The Dingo and Amaru profiles are relay-only and limited to `preprod` and
    `preview`. They are not supported for mainnet, block production, or pool
    keys.

- For cnode, a `glibc` error while installing CNCLI usually means that the
  precompiled binary is incompatible with the host OS. Compile CNCLI using its
  [upstream instructions](https://github.com/cardano-community/cncli/blob/develop/INSTALL.md#compile-from-source)
  and copy the resulting binary to `"${HOME}/.local/bin"`.

A typical example install to install most components but not overwrite static part of existing files for preview network would be:

``` bash
./guild-deploy.sh -b master -n preview -t cnode -s pdlcowx
. "${HOME}/.bashrc"
```

The cnode `b` flag prepares the build toolchain; it does not compile or install
cardano-node by itself. To build instead of using `-s d`, first deploy the
toolchain and scripts, then follow the
[cardano-node and cardano-cli build guide](Build/node-cli.md):

``` bash
./guild-deploy.sh -b master -n preview -t cnode -s pbl
. "${HOME}/.bashrc"
```

Lastly, if you'd want to update your scripts but not install any additional dependencies, you may simply run:

``` bash
./guild-deploy.sh -b master -n preview -t cnode
```

Experimental relay examples are:

```bash
./guild-deploy.sh -i dingo -n preview -s pd
./guild-deploy.sh -i amaru -n preprod -s pd
```

All three profiles reuse `$HOME/.local/bin`; their binary names do not
conflict. cnode keeps its reviewed static node release, while `-s d` resolves
the newest published non-draft Dingo or Amaru release, including
prereleases, and verifies its GitHub-published asset digest. Every successful
target also contains `.deployment.json`, which records the implementation,
network, Guild repository and branch, service name, installed and targeted
versions, and declared capabilities. Re-running the dispatcher restores those
values from the manifest. An explicit
`G_ACCOUNT` user-variable/environment override or `-b` branch selects a new
update source; an explicit network must match the existing deployment and
cannot convert the target.
For Dingo and Amaru, `-n` is therefore required only on the initial
deployment; it may be omitted when updating a target with a valid manifest.

Deployment paths are intentionally limited to shell- and systemd-safe
characters. A target is locked for the full deployment, so a simultaneous
deployment, helper runtime refresh, or `-b` branch change against the same
folder is rejected.

##### Folder structure

Running the cnode profile creates the structure below. You do not require
`CNODE_HOME` to be set at shell level because scripts derive their deployment
root. The entry in `~/.bashrc` is only a convenience.


    /opt/cardano/cnode            # Top-Level Folder
    ├── .deployment.json          # Guild deployment identity and branch
    ├── ...
    ├── files                     # Config, genesis and topology files
    │   ├── cnode-release.json    # cnode node, tool, and build manifest
    │   ├── ...
    │   ├── byron-genesis.json    # Byron Genesis file referenced in config.json
    │   ├── shelley-genesis.json  # Genesis file referenced in config.json
    │   ├── alonzo-genesis.json    # Alonzo Genesis file referenced in config.json
    │   ├── conway-genesis.json    # Conway Genesis file referenced in config.json
    │   ├── config.json           # Config file used by cardano-node
    │   └── topology.json         # Map of chain for cardano-node to boot from
    ├── db                        # DB Store for cardano-node
    ├── guild-db                  # DB Store for guild-specific tools and additions (eg: cncli, cardano-db-sync's schema)
    ├── logs                      # Logs for cardano-node
    ├── priv                      # Restricted folder for operational keys
    ├── scripts                   # Node launcher, common tools, libraries and cnode adapter
    └── sockets                   # Socket files created by cardano-node

Dingo and Amaru retain the same top-level concepts where they apply, while
using implementation-specific configuration and state directories. Their
complete layouts are documented in the [Dingo](Build/dingo.md) and
[Amaru](Build/amaru.md) guides.
