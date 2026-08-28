# CNTools

CNTools is a Bash-based terminal tool for Cardano pool operations and wallet
management. Version 14 keeps the existing CNTools name and release history,
but replaces the former monolithic implementation with a modular framework and
a Charm Gum interface.

!!! warning "Version 14 implementation status"
    Wallet List and Show are functional and read-only in version 14.1.0. Other
    wallet actions and all pool, transaction, governance, backup, block, and
    advanced actions remain placeholders.

## Installation and migration

Guild Deploy installs CNTools for cnode, Dingo, and Amaru. The installed layout
has one stable public launcher and one transactionally replaced application
tree:

```text
${NODE_HOME}/scripts/
├── cntools.sh
├── cntools/
│   ├── VERSION
│   ├── cntools_main.sh
│   ├── core/
│   ├── lib/
│   └── modules/
└── env
```

The public `cntools.sh` launcher starts `cntools/cntools_main.sh`. The former
CNTools monolith and `cntools.library` are no longer installed. The shared
`env` remains the deployment configuration source and is not part of the
CNTools rewrite.

Moving from CNTools 13.x to 14.x requires the current `guild-deploy.sh`.
The legacy in-application updater cannot perform this layout change. Run Guild
Deploy from the intended 14.x branch using the same node implementation,
network, and target as the existing deployment.

## Starting CNTools

Use the stable launcher from the node's `scripts` directory:

```bash
./cntools.sh
```

CNTools requires Bash 4.4 or newer, common Linux tools, and exactly Charm Gum
2.0.0. If Gum is missing or has another version, interactive startup offers to
install the verified official executable in `~/.local/bin`. Declining or a
failed prerequisite check exits without starting the interface. Offline mode
never downloads Gum.

The available options are:

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

Local mode uses the selected deployment identity; light mode is intended for
Koios-backed actions; offline mode prohibits network access. Node health is a
best-effort interface detail, not a startup requirement. An unavailable node
does not prevent the menu from opening.

## Interface and updates

CNTools validates the menu metadata once at startup and keeps the catalog in
memory. Gum provides filtering and keyboard navigation, while action code and
its focused libraries are loaded only when selected. Wallet List and Show load
their wallet libraries on demand; remaining operational actions display a
not-implemented notice.

Wallet List reads existing direct subdirectories beneath the configured
`WALLET_FOLDER` and shows wallet type, key protection, non-ADA token count,
rewards, UTxO balance, and the inclusive UTxO-plus-rewards total. It
distinguishes ordinary CLI wallets from mnemonic-derived wallets using the
existing key and derivation metadata. Wallet Show adds addresses, UTxO and
native asset counts, registration, and delegation. Local cnode and Dingo
sessions use the deployed Cardano CLI, light mode uses Koios, offline mode
never contacts a backend, and local Amaru sessions clearly mark live values
unavailable while still showing wallet files.

For Wallet List, live balances and rewards are opt-in on each visit. Declining
the confirmation renders the filesystem catalog immediately with unavailable
live columns and makes no Cardano CLI or Koios request. Accepting it displays a
Gum spinner while CNTools fetches the catalog values. Offline mode and local
implementations without wallet-query capability skip this confirmation.

Local Cardano CLI calls are bounded by a timeout. Wallet List performs one
local preflight and stops the remaining catalog queries after a backend
timeout. In light mode, Wallet List deduplicates addresses across all wallets
and divides them into bounded Koios bulk requests; Wallet Show sends the
selected wallet's distinct funding addresses together and uses one separate
stake-account request. Partial responses remain visibly partial and are never
promoted to a complete wallet total.

These actions do not create missing addresses, update keys, or change the
existing CNTools wallet layout. Unsafe symbolic links and malformed address
files are skipped or reported and recorded in the CNTools log. Koios tokens are
kept out of logged commands, process arguments, and child environments.

The Update menu can check again, show changelog entries newer than the running
version, or invoke Guild Deploy. Updates replace the complete managed CNTools
tree from one repository snapshot; CNTools exits after starting that process
and should be launched again through `scripts/cntools.sh`.

Session events, selections, external commands, API requests, and errors use the
new redacting logger. Sensitive input, keys, credentials, request bodies, and
command output are not logged by default.

See the [CNTools changelog](cntools-changelog.md) for release progress.
