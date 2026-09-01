# CNTools

CNTools is a Bash-based terminal tool for Cardano pool operations and wallet
management. Version 14 keeps the existing CNTools name and release history,
but replaces the former monolithic implementation with a modular framework and
a Charm Gum interface.

!!! warning "Version 14 implementation status"
    Wallet New → CLI, New → Mnemonic, Import → Mnemonic, List, Show, Encrypt,
    and Decrypt are functional in version 14.0.0. List and Show may cache
    missing public wallet artifacts; wallet creation and import publish keys
    only after explicit confirmation and complete validation. Encrypt and
    Decrypt are local file operations and never contact a node or API. None of
    these actions submit transactions. Advanced **Theme** is also functional;
    other wallet actions and all pool, transaction, governance, backup, block,
    and operational advanced actions remain placeholders.

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

Numeric display values use commas as thousands separators and a period as the
decimal separator. Future numeric inputs can use either canonical separators
or no separators. Tables use the live terminal width up to a readable maximum,
so full addresses and identifiers stay on one line when space allows and wrap
cleanly on narrower terminals.

## Interface and updates

CNTools validates all modular menu metadata in one multi-file JSON pass at
startup and keeps the resulting catalog in memory. Gum provides filtering and
keyboard navigation, while action code and its focused libraries are checked
and loaded only when selected. Functional Wallet actions load their focused
libraries on demand; remaining operational actions display a not-implemented
notice.

Start CNTools with `-a` to open **Advanced → Theme**. Theme colors are defined
centrally by semantic purpose so headers, numbers, identifiers, and statuses
remain consistent. The selected theme is stored privately in
`${NODE_HOME}/.cntools/theme` and restored at startup. Only the Koios-inspired
**Default** theme is available in this release; the selector is in place for
future themes. Set `NO_COLOR` to a non-empty value to disable color output.

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
address header bits. The Balances table includes the number of distinct native
assets. After the other wallet details are printed, wallets with native assets
offer `Simple`, `Detailed`, and `Skip`. Type is `NFT` when current total supply
is exactly one and `FT` otherwise. NFT rows omit amount, total supply, ticker,
and decimals. Detailed output is printed inline as a compact, bounded tree of
the selected metadata document while removing standard transport wrappers and
omitting absent fields. Explicit markers identify safety-limit omissions.
Local and light Wallet Show sessions identify Koios as the metadata source.
Local cnode and Dingo sessions still use the deployed
Cardano CLI for wallet state; when `ENABLE_KOIOS=Y`, the Koios request only
enriches token metadata and cannot invalidate local holdings. Light mode uses
Koios for both roles, offline mode never contacts a blockchain backend, and
local Amaru sessions clearly mark live values unavailable while still showing
wallet files.

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
`asset_info` bulk requests. Metadata name, ticker, decimals, description, URL,
custom nested fields, and total supply are shown when relevant and available.
Native-asset details remain inline even when long. Metadata failure
never removes validated on-chain holdings. A valid empty Koios funding response
represents unused addresses and produces complete zero balances and counts.
Non-empty responses that omit a requested address remain visibly partial and
are never promoted to a complete wallet total.

Metadata precedence selects one complete document by standard label. CIP-67
label `222` uses CIP-68 before exact CIP-25 label `721`; label `333` uses
CIP-68, transaction metadata label `20`, then the Token Registry; and label
`444` uses CIP-68 then the Token Registry. Unlabelled assets retain label `20`,
Token Registry, and exact label `721` fallback coverage. CIP-25 policy/asset
nesting and CIP-68 datum wrappers are removed before the Detailed tree is built.

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

**Wallet → New → CLI** creates a standard wallet from newly generated Cardano
CLI payment and stake key pairs. Key generation and derivation are local and
available in local, light, and offline modes when Cardano CLI and the selected
network are configured; they do not require a running node or Koios. Wallet
names must begin with a letter or number and may contain only letters, numbers,
periods, underscores, and hyphens, up to 64 characters. CNTools shows the
planned location and artifacts, defaults the final confirmation to **No**, and
runs the confirmed operation beneath a Gum spinner.

Creation takes place in a private hidden staging directory beneath the wallet
root. CNTools independently derives each verification key from its signing key,
then validates the exact expected wallet shape, file modes, matching key pairs,
addresses, and credentials before atomically publishing the complete wallet
without replacing any existing path. A handled failure or interruption removes
only the tracked staging directory and never exposes a partial wallet. The result
contains payment and stake signing and verification keys, payment, reward, and
base addresses, and raw hexadecimal payment and stake credential files. It
does not create governance, committee, or multisignature material; those belong
to their dedicated future actions. The absence of `derivation.path` identifies
the result as a CLI wallet rather than a mnemonic-derived wallet.

The atomic rename is the creation commit point. A problem displaying or
revalidating the already committed result is reported as a warning with its
final path, not as a failed creation. An uncatchable process kill or host power
loss can leave a hidden `.cntools-wallet-new.*` directory containing private
staging material. Wallet discovery excludes and logs such directories; inspect
and remove a confirmed stale one securely before reusing its space.

**Wallet → New → Mnemonic** creates a 24-word recovery phrase with the pinned
Cardano CLI. CNTools presents both one copyable line and a responsive numbered
table with up to six columns. After the user confirms the backup is recorded,
the phrase is cleared from the terminal and four randomly selected words must
be entered correctly before any wallet is created.

**Wallet → Import → Mnemonic** accepts either a pasted space-separated phrase
or one word at a time. Leading, trailing, and repeated whitespace is normalized;
12, 15, 18, 21, and 24-word phrases are accepted. Phrase input is hidden and
neither generated nor imported words are written to command arguments, files,
environments, or logs. The phrase is passed to Cardano CLI only through standard
input and is discarded after derivation.

Both mnemonic actions derive standard CIP-1852 payment and stake keys with a
user-selected account number and address key index. The generated wallet stores
extended signing keys plus the same validated public artifacts as a CLI wallet,
and records `1852H/1815H/<account>H/x/<index>` in `derivation.path`. Arbitrary
purpose paths, including CIP-1854 multisignature derivation, are intentionally
reserved for the later multisignature implementation where `cardano-address`
can be loaded only when it is actually required.

**Wallet → Encrypt** protects the configured payment and stake signing keys
using GnuPG symmetric AES-256 encryption and the existing `.skey.gpg` format.
New passphrases must contain at least 12 characters and are entered twice.
CNTools stages every encrypted key, decrypts it again, validates the restored
Cardano key envelope, and compares it with the original before publishing any
encrypted result or removing plaintext keys. A staging failure leaves the open
wallet unchanged. When an owned, writable wallet migrated from an older CNTools
release still has group/public write permission on its directory, the action
removes those write bits and records the normalization in the log.

**Wallet → Decrypt** accepts existing CNTools `.skey.gpg` wallets. It deliberately
does not apply the new 12-character policy: any non-empty legacy passphrase
without a line break is accepted. Every plaintext key is staged and validated
before publication, so cancellation, a wrong passphrase, or a corrupt file
leaves the protected wallet unchanged. List and Show never decrypt keys
implicitly. Both actions work in local, light, and offline modes and load GnuPG
only when selected.

Protected non-address files always receive owner-read-only mode `0400`; restored
files receive owner-only mode `0600`. When `ENABLE_CHATTR=true`, CNTools also
tests and applies the Linux immutable flag directly or through an existing
non-interactive sudo policy. If `chattr`, filesystem support, or permission is
unavailable during encryption, CNTools logs and displays a warning while
retaining the read-only protection. Decryption detects and removes an existing
immutable flag even when the current setting is disabled. Passphrases and key
contents are never included in command arguments or logs.

The Update menu can check again, show changelog entries newer than the running
version, or invoke Guild Deploy. Updates replace the complete managed CNTools
tree from one repository snapshot; CNTools exits after starting that process
and should be launched again through `scripts/cntools.sh`. If the installed and
selected branch versions match, Install Update offers an explicit default-No
confirmation to force deployment of the same snapshot.

Session events, selections, external commands, API requests, and errors use the
new redacting logger. API records include a copyable `curl` request with its
non-secret payload; authentication is represented by a `KOIOS_API_TOKEN`
variable reference rather than the token value. Sensitive input, keys,
credentials, sensitive request fields, and command output are not logged.

See the [CNTools changelog](cntools-changelog.md) for release progress.
