# CNTools

CNTools is a terminal application for managing Cardano wallets, stake pools,
transactions, governance and native assets. Searchable menus, guided questions
and responsive tables keep everyday actions consistent.

## Installation and startup

Use [Guild Deploy](../basics.md) to install CNTools and the companion tools for
your deployment. CNTools uses the `env` file in your deployment's scripts
directory for its network, paths, local node connection and Koios settings.

Start CNTools from that directory:

```bash
./cntools.sh
```

CNTools requires Bash 4.4 or newer, Charm Gum 2.0.0, a UTF-8 terminal and the
common Linux tools provided by Guild Deploy's prerequisite installation.
If Gum is missing or has a different version, interactive startup offers to
install it. Declining leaves CNTools closed. Install Gum before entering
offline mode, where no download is attempted. Individual actions check their
companion tools when needed and explain missing prerequisites.

Use the deployed companion versions supplied by Guild Deploy. Hardware actions
require `cardano-hw-cli`, which Guild Deploy can install with `-s w`.
Some specialist actions also need Cardano Signer, Catalyst Toolbox,
`cardano-address` or `token-metadata-creator`.

```text
Usage: cntools.sh [-n|-l|-o] [-a] [-u] [-b BRANCH] [-v] [-h]

  -n          Local node mode (default)
  -l          Light mode using Koios
  -o          Offline mode
  -a          Show advanced features
  -u          Skip the automatic update-availability check
  -b BRANCH   Redeploy from this Guild branch, then exit
  -v          Print the CNTools version
  -h          Show help
```

## Choosing a mode

| Mode | What it does |
| --- | --- |
| Local | Prefers the configured local node for supported queries, transaction construction and submission. Enabled Koios access supplies metadata and API-only features, and can provide a fallback where supported. |
| Light | Uses Koios for blockchain queries and submission. Key generation and transaction signing still happen locally. |
| Offline | Makes no node or network queries. Supports local key and file operations, inspection of saved artifacts and signing previously built transaction packages. |

cnode provides the full local-node workflow. Dingo's local operations depend on
its configured compatible CLI/socket. Amaru has no compatible local query
socket; use light mode for its online CNTools workflows. Availability of a
menu does not make an unavailable backend or companion tool optional.

Building a normal transaction requires current chain data, even when you plan
to sign it offline. An unavailable node does not stop CNTools from opening.
The root header shows best-effort epoch, tip and sync-gap information, refreshed
when returning to the root menu. Offline mode hides that health section.

## Navigation and display

The header shows CNTools version, current menu path, mode, backend and network.
Check the network before performing any transaction.

Type to filter menu choices, use the arrow keys to move, and press Enter to
select. Use the displayed Back, Home and Quit choices to navigate. Escape first
leaves the filter input; cancelling a submenu selection returns without running
an action. Prompts provide cancellation where applicable.

Tables expand to the available terminal width and wrap long addresses only
when needed. Numbers use US formatting: commas for thousands and a period for
decimals. Numeric prompts accept values with or without valid comma grouping.
Dates follow `BLOCKLOG_TZ` in `env`, defaulting to UTC.

## Available actions

| Menu | Main tasks |
| --- | --- |
| Wallet | Create CLI/mnemonic wallets, import mnemonic/hardware wallets, inspect balances and history, register or de-register stake addresses, protect keys and remove wallets. |
| Funds | Send ADA/assets, delegate stake, withdraw rewards and collect UTxOs. |
| Pool | Create/import pools, inspect state, register/modify/retire, rotate KES keys, protect keys and manage Calidus credentials. |
| Vote | Manage DRep keys, registration and delegation, browse proposals, cast DRep votes and manage Catalyst registration/QR/snapshot checks. |
| Transaction | Review and sign portable packages, or submit completed packages and supported external signed transactions. |
| Backup & Restore | Create full or public-only backups and restore without overwriting existing folders. |
| Blocks | Read block-production summaries and epoch details from the configured CNCLI blocklog. |
| Settings | Set transaction defaults and, with `-a`, choose a theme. |
| Update | Check availability, read changes and refresh the deployment through Guild Deploy. |
| Advanced (`-a`) | Manage native assets and policies, create multisig identities, clear asset metadata cache and explicitly delete private keys. |

See [Common Tasks](cntools-common.md) for practical workflows and safety notes.

## The shared transaction flow

Transaction actions show their important effects, recipients or certificates,
any metadata, and a compact transaction-information table. This includes the
fee, expiry and applied input/change policies. Required signers are available
from the review menu. Technical transaction data goes to the log rather than
a raw JSON dump on the normal screen.

Choose a workflow:

1. **Create, sign and submit** — complete the transaction online.
2. **Create and sign** — save a signed package without submitting.
3. **Create unsigned package** — save it for signing elsewhere.

If the required signing keys are unavailable or protected, unsigned export
remains available when the required public material exists. Multisig actions
ask which participants will sign; the selected witnesses must all be collected.

Every creating action offers an expiry, including **No expiry**. The standard
choices include 30 minutes, 2 hours and 24 hours for offline signing.
No expiry does not remove a native script's mandatory time bounds. Changing
expiry, recipients or transaction effects requires a new build and signatures.

Fees use the final transaction and required witnesses. The review also shows
deposits, refunds and minimum-ADA adjustments where applicable. CNTools rechecks
relevant chain state during live workflows; changes can require rebuilding.

Saved packages are reported under `${NODE_HOME}/transactions/`. Keep them
until the operation is resolved. Packages contain public transaction and signer
information, not private keys, but may still contain sensitive addresses,
messages or metadata.

Accepted submission does not prove block inclusion. When Koios is available,
CNTools offers to monitor inclusion every five seconds. The result shows the
transaction ID and elapsed time until Koios observes it in a block. Indexing
can lag: if submission or monitoring is uncertain, check the reported ID before
creating a replacement transaction.

## Settings

**Settings → Transaction Defaults** persists your preferences between sessions:

- **Coin selection:** Balanced prefers simpler ADA-only inputs and avoids
  unnecessary native assets; Fewest inputs prioritizes fewer inputs.
- **Token fragmentation:** optionally limits distinct assets per change output
  so future transfers need not consume one large token bundle.
- **ADA-only UTxO management:** optionally maintains useful ADA-only change
  outputs. It accounts for outputs already left in the wallet, can keep a
  5 ADA collateral candidate, and splits remaining change by configured
  percentages. Minimum-ADA and output-count limits still apply.
- **Send change address:** optionally asks whether change should use the base
  or payment-only address when the wallet supports both. Otherwise, the primary
  address is used.
- **Default expiry:** sets the starting expiry preference for creating actions.

Token fragmentation and ADA-only management are disabled by default.
These settings shape change from a transaction, not a background wallet
maintenance job. Use **Funds → Collect UTxOs** for explicit consolidation.
The transaction review shows what the settings actually produced.

Start with `-a` and open **Settings → Theme** to choose **Default**, inspired
by Koios, or **Hydra After Dark**, a navy/cyan Cardano-inspired theme.
The choice persists. A non-empty `NO_COLOR` environment variable disables
color output.

## Stored data and privacy

Wallet, pool and policy folders follow `WALLET_FOLDER`, `POOL_FOLDER` and
`ASSET_FOLDER` in `env`. Their defaults are beneath `${NODE_HOME}/priv/`.
Preferences live beneath `${NODE_HOME}/.cntools/`; backups, saved transactions
and asset-registry exports have their own reported locations.

CNTools can generate missing public keys, addresses and IDs from available
keys or scripts and reuse them later. It does not silently replace mismatched
files or decrypt protected keys during inspection.

Asset metadata comes from Koios, including in local mode, and is cached for
one day. **Advanced → Clear asset cache** requests fresh metadata on the next
lookup. Metadata failures do not remove known holdings.

The default log is `${NODE_HOME}/logs/cntools.log`, subject to your configured
log path. It records user choices, commands, API requests, technical transaction
details and errors. API entries include replayable requests without revealing
authentication tokens. Recovery phrases, passphrases and private key contents
must not be shared. Logs and public packages can reveal financial activity;
review them before sharing.

## Updates and troubleshooting

The update check does not prevent normal menu use. **Update → Check Again**
refreshes availability, **View Changes** shows newer changelog entries, and
**Install Update** runs Guild Deploy for the selected repository branch.
An explicit confirmation allows a forced refresh when versions match.

Guild Deploy refreshes the managed scripts and configuration snapshot, not just
CNTools. Review the target, network and branch first, and back up any locally
customized configuration. CNTools closes after deployment; restart with
`./cntools.sh` from the scripts directory.

If a query fails, check the network, `env` connection settings, node health and
Koios availability. Use `-o` for local/offline work. For a failed action, the
reported log path contains the diagnostic details. Do not replace keys or
retry an uncertain submission blindly.

Release changes are recorded in the [CNTools changelog](cntools-changelog.md).
