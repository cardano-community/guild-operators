A common environment file called `env` is sourced by most scripts in the
Guild Operators repository. There is one canonical implementation under
`scripts/common-helper-scripts`; it is shared by cnode, Dingo, and Amaru
deployments rather than copied and maintained separately for every node.

The small `env` entrypoint combines three layers:

1. `.deployment.json` identifies the deployment implementation, network, Guild
   repository and branch or tag, exact source revision, source mode, payload
   receipt, service name, and declared capabilities;
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
installed together with the rest of the deployment when
[Pre-Requisites](../basics.md#pre-requisites) are followed. The deployed
entrypoint remains `${NODE_HOME}/scripts/env`; `${CNODE_HOME}` is retained as a
compatibility alias for cnode-era scripts. Custom values in the User Variables
section are preserved unless a forced script overwrite is selected.

The former cnode-specific source URLs are retired. Deployments receive the
canonical common file, and helper self-updates use the
`common-helper-scripts` source folder. Existing flat cnode installations
should be migrated with the current `guild-deploy.sh` before accepting
helper-initiated payload updates.

The old `${CNODE_HOME}/scripts/.env_branch` file is no longer used. Source
selection is stored in `${NODE_HOME}/.deployment.json`. Passing `-b` to
gLiveView, CNTools, Topology Updater, setup-grest, or the deployment dispatcher
requests a complete deployment transaction from that branch or tag; no helper
edits only the manifest field.

An existing manifest is authoritative and must be valid schema version 1 with
`deploymentStatus: "deployed"` and complete implementation, network,
repository, branch, service, source revision and mode, receipt digest,
transaction ID, node-version, metrics, and capability data. Its
`.guild-source-receipt.json` binds that source identity to the installed file
hashes and modes. The common environment stops on malformed, incomplete,
future-schema, mismatched, or interrupted metadata instead of silently loading
the cnode adapter. A missing manifest is accepted only for the documented
legacy/source-tree fallback.

An update check from any helper compares and, after confirmation where
applicable, refreshes the complete compatible Guild payload through the
installed dispatcher. All candidates are staged and validated before the
target-wide transaction starts. A failed activation restores the previous
generation, and the receipt and deployed manifest are committed last.

The manifest branch or tag is also the authoritative update source. If it is
missing or cannot be reached, a helper update fails without replacing files;
there is no silent `master` fallback. Change to a reachable channel with the
dispatcher or a compatible helper's `-b` option. A different public fork is a
separate repository migration and requires the dispatcher options
`-a <account> -R`.

Automatic helper refresh uses managed mode by default; `GUILD_SOURCE_MODE` may
be set to `cached` only for an intentional offline check against the existing
bare cache. A deployment installed from a local or dirty checkout cannot be
automatically refreshed because the checkout path is deliberately not stored
as a reusable trust decision. Re-run the installed dispatcher explicitly:

```bash
"${NODE_HOME}/scripts/guild-deploy.sh" \
  -i <cnode|dingo|amaru> -n <network> -b <branch> -a <account> \
  -p "$(dirname "${NODE_HOME}")" -t "$(basename "${NODE_HOME}")" \
  -S local -L /absolute/path/to/guild-operators
```

Add `-D` only when intentionally deploying uncommitted `scripts` or `files`
content. Public managed source uses HTTPS Git and needs no GitHub token or API
key.

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
