# CNTools

CNTools is a Bash-based terminal tool for Cardano pool operations and wallet
management. Version 14 keeps the existing CNTools name and release history,
but replaces the former monolithic implementation with a modular framework and
a Charm Gum interface.

!!! warning "Version 14 implementation status"
    Wallet List and Show are functional in version 14.1.0. They may cache
    missing public wallet artifacts, but do not change private keys or submit
    transactions. Other wallet actions and all pool, transaction, governance,
    backup, block, and advanced actions remain placeholders.

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
never downloads Gum. The interface also requires a UTF-8 locale; CNTools keeps
an active UTF-8 locale or selects a common installed UTF-8 locale automatically.

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
best-effort root-menu detail, not a startup requirement. It refreshes on
natural root-menu draws and uses the existing short cache between draws.
Submenus do not show or request health data, and an unavailable node does not
prevent the menu from opening.

## Interface and updates

CNTools validates all modular menu metadata in one multi-file JSON pass at
startup and keeps the resulting catalog in memory. Gum provides filtering and
keyboard navigation, while action code and its focused libraries are checked
and loaded only when selected. Wallet List and Show load their wallet libraries
on demand; remaining operational actions display a not-implemented notice.

Wallet List reads direct subdirectories beneath the configured `WALLET_FOLDER`
and renders a compact multi-line entry for each wallet. An entry contains only
the fields that apply to that wallet: detected type and key protection, its
primary address, separate base and payment UTxO balances, stake rewards, an
inclusive total, and a native-asset count when it is non-zero. A wallet with
payment and stake credentials uses its combined base address as primary; a
payment-only wallet uses its enterprise address; a stake-only wallet shows its
reward address and notes the missing payment credential; and a multisignature
wallet shows its script address. A valid recorded `derivation.path` is the
marker that distinguishes a mnemonic-derived wallet from a CLI wallet.

Wallet Show presents registration with the wallet identity, shows the recorded
derivation path for mnemonic wallets, and keeps stake-pool and DRep delegation
in a separate delegation table. Address and credential tables show only the
payment, stake, multisignature, and script fields relevant to the selected
wallet. Credentials are the hexadecimal key or script hashes without Cardano
address header bits. Native assets use one detail table containing quantity,
policy ID, asset-name hex, and the CIP-14 asset fingerprint. Light mode adds
available Koios Token Registry metadata to that same table. Local cnode and
Dingo sessions use the deployed Cardano CLI, light mode uses Koios, offline
mode never contacts a blockchain backend, and local Amaru sessions clearly
mark live values unavailable while still showing wallet files.

For Wallet List, live balances and rewards are opt-in on each visit. Declining
the confirmation renders the filesystem catalog immediately without empty
balance rows and makes no node-query or Koios request. Accepting it displays a
Gum spinner while CNTools fetches the catalog values. Offline mode and local
implementations without wallet-query capability skip this confirmation.

Local Cardano CLI calls are bounded by a timeout. Wallet List performs one
local preflight and stops the remaining catalog queries after a backend
timeout. In light mode, Wallet List deduplicates addresses across all wallets
and divides them into bounded Koios bulk requests. Wallet Show sends the
selected wallet's distinct funding addresses together, uses one separate
stake-account request, and enriches native assets through size-bounded Koios
`asset_info` bulk requests. Token Registry name, ticker, decimals,
description, URL, and total supply are shown when Koios provides them.
Oversized native-asset details use a Gum scroll view. Metadata failure
never removes validated on-chain holdings. Partial balance responses remain
visibly partial and are never promoted to a complete wallet total.

List and Show load focused wallet-generation helpers only when selected. When
a safe wallet contains a usable signing key or multisignature script, CNTools
derives a missing public verification key, address, credential, or applicable
identifier and caches it under the existing configured CNTools filename. An
already present artifact is never overwritten, and a protected signing key is
never decrypted implicitly. This deterministic local work does not require a
node and can run in local, light, or offline mode when the deployed Cardano CLI
is available. Unsafe symbolic links and malformed existing artifacts are
reported and recorded in the CNTools log instead of being replaced. Koios
tokens are kept out of logged commands, process arguments, and child
environments.

The Update menu can check again, show changelog entries newer than the running
version, or invoke Guild Deploy. Updates replace the complete managed CNTools
tree from one repository snapshot; CNTools exits after starting that process
and should be launched again through `scripts/cntools.sh`.

Session events, selections, external commands, API requests, and errors use the
new redacting logger. Sensitive input, keys, credentials, request bodies, and
command output are not logged by default.

See the [CNTools changelog](cntools-changelog.md) for release progress.
