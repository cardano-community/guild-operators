A common environment file called `env` is sourced by most scripts in the
Guild Operators repository. There is one canonical implementation under
`scripts/common-helper-scripts`; it is shared by cnode, Dingo, and Amaru
deployments rather than copied and maintained separately for every node.

The small `env` entrypoint combines three layers:

1. `.deployment.json` identifies the deployment implementation, network, Guild
   repository and branch, service name, and declared capabilities;
2. common libraries provide implementation-neutral validation, update,
   metadata, metrics, and systemd helpers;
3. `scripts/adapters/<implementation>.adapter` supplies node-specific paths,
   process discovery, interfaces, and metric collection.

This allows a shared script to request a capability and fail cleanly when the
selected node cannot provide it. Loading the shared environment does not mean
that every helper supports every implementation; see the
[compatibility table](../Build/node-implementations.md#current-helper-compatibility).

#### Installation

The common `env`, its `scripts/lib` runtime, and the selected adapter are
downloaded together with the rest of the deployment when
[Pre-Requisites](../basics.md#pre-requisites) are followed. The deployed
entrypoint remains `${NODE_HOME}/scripts/env`; `${CNODE_HOME}` is retained as a
compatibility alias for cnode-era scripts. Custom values in the User Variables
section are preserved unless a forced script overwrite is selected.

The former cnode-specific source URLs are retired. Deployments receive the
canonical common file, and helper self-updates use the
`common-helper-scripts` source folder. Existing flat cnode installations
should be migrated with the current `guild-deploy.sh` before accepting
individual helper updates.

The old `${CNODE_HOME}/scripts/.env_branch` file is no longer used. Branch
selection is stored in `${NODE_HOME}/.deployment.json`. Passing `-b` to
gLiveView, CNTools, Topology Updater, setup-grest, or the deployment dispatcher
updates that manifest while preserving its other fields.

An existing manifest is authoritative and must be valid schema version 1 with
`deploymentStatus: "deployed"` and complete implementation, network,
repository, branch, service, node-version, metrics, and capability data. The
common environment stops on malformed, incomplete, future-schema, or
interrupted metadata instead of silently loading the cnode adapter. A missing
manifest is accepted for the legacy/source-tree fallback.

The six runtime members (`env`, four common libraries, and the selected
adapter) update as one locked transaction. They are all downloaded and
shell-validated before the first replacement; a failed commit restores every
previous member.

The manifest branch is also the authoritative update source. If that branch
is missing or cannot be reached, a manifest-backed helper or common-runtime
update fails without replacing files instead of silently downloading
`master`. Change to a reachable branch with the dispatcher or a compatible
helper's `-b` option. The historical fallback to `master` remains only for
legacy installations that have no `.deployment.json`.

#### Configuration

Leave a value commented to use deployment metadata, the selected adapter, or
the runtime default. In particular, `.deployment.json` supplies the
implementation, network, repository, branch, and service identity, while the
entrypoint derives `NODE_HOME` from its installed location. Do not duplicate
those values in `env`.

For cnode, `CNODE_PORT` defaults to `6000`; override it only if the node uses a
different port. Set `POOL_NAME` to the CNTools pool directory name, not the
ticker, when `cnode.sh` should launch a block producer. A `NODE_HOME` or
`CNODE_HOME` override is honored only when `USESYSVARS=Y`.

Dingo and Amaru keep launcher-specific values in `dingo.env` and `amaru.env`.
The common cnode-era aliases remain available for compatibility, but setting
one does not add a capability that an alternate adapter has not declared.

The current common User Variables section is:

```bash
######################################
# User Variables - Change as desired #
# Leave as is if unsure              #
######################################

#NODE_IMPLEMENTATION="cnode"                            # Normally read from .deployment.json
#USESYSVARS="N"                                         # Set Y to honor root overrides
#NODE_HOME="/opt/cardano/cnode"                         # Effective only when USESYSVARS=Y
#CNODE_HOME="${NODE_HOME}"                              # Legacy alias; effective only when USESYSVARS=Y
#CNODEBIN="${HOME}/.local/bin/cardano-node"             # Legacy cnode binary override
#CCLI="${HOME}/.local/bin/cardano-cli"                  # Override adapter-selected cardano-cli executable
#CNCLI="${HOME}/.local/bin/cncli"                       # Optional CNCLI executable
#CNODE_PORT=6000                                        # Legacy node-to-node port alias
#CONFIG="${NODE_HOME}/files/config.json"                # Implementation configuration override
#SOCKET="${NODE_HOME}/sockets/node.socket"              # Node-to-client socket override
#TOPOLOGY="${NODE_HOME}/files/topology.json"            # Topology override
#LOG_DIR="${NODE_HOME}/logs"
#DB_DIR="${NODE_HOME}/db"
#UPDATE_CHECK="Y"
#TMP_DIR="/tmp/cnode"
#PROM_HOST=127.0.0.1
#PROM_PORT=12798
#PROM_TIMEOUT=3
#CURL_TIMEOUT=10
#BLOCKLOG_DIR="${NODE_HOME}/guild-db/blocklog"
#BLOCKLOG_TZ="UTC"
#SHELLEY_TRANS_EPOCH=208
#NETWORK_NAME=
#TG_BOT_TOKEN=""
#TG_CHAT_ID=""
#TIMEOUT_LEDGER_STATE=300
#IP_VERSION=4
#ENABLE_KOIOS=Y
#KOIOS_API="https://api.koios.rest/api/v1"
#KOIOS_API_TOKEN=""
#DBSYNC_QUERY_FOLDER="${NODE_HOME}/files/dbsync/queries"
#G_ACCOUNT="cardano-community"
#WALLET_FOLDER="${NODE_HOME}/priv/wallet"
#POOL_FOLDER="${NODE_HOME}/priv/pool"
#POOL_NAME=""
#ASSET_FOLDER="${NODE_HOME}/priv/asset"
#MITHRIL_DOWNLOAD="N"
#MITHRIL_HOME="${NODE_HOME}/mithril"
#MITHRIL_SIGNER_ENABLED="N"
#STRICT_VERSION_CHECK="Y"
```

Leave `CCLI` commented to use the selected adapter's default. cnode resolves
`cardano-cli`; Dingo selects the independently installed
`$HOME/.local/bin/cardano-cli-dingo`. Uncommenting `CCLI` is an explicit
operator override and is preserved by both adapters.

The longer wallet, pool, and asset filename-convention list formerly shown on
this page is still initialized by the cnode-compatible runtime, but is no
longer part of the editable common `env` header.
