# CNTools

CNTools is a Bash-based terminal tool for Cardano pool operations and wallet
management. Version 14 keeps the existing CNTools name and release history,
but replaces the former monolithic implementation with a modular framework and
a Charm Gum interface.

!!! warning "Version 14 implementation status"
    Wallet New → CLI, New → Mnemonic, Import → Mnemonic, Import → HW
    Wallet, List, Show, Register, De-Register, Remove, Encrypt, and Decrypt are
    functional in version 14.0.0. Transaction Sign and Submit are also
    functional. List and
    Show may cache missing public wallet artifacts; wallet creation and import
    publish keys only after explicit confirmation and complete validation.
    **Settings → Theme** and **Settings → Transaction Defaults** are also
    functional; remaining wallet and transaction actions and all pool,
    governance, backup, block, and operational advanced actions remain
    placeholders.

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
and loaded only when selected. Functional Wallet and Transaction actions load
their focused libraries on demand; remaining operational actions display a
not-implemented notice.

Start CNTools with `-a`, then open **Settings → Theme** to select the interface theme. Theme colors are defined
centrally by semantic purpose so headers, numbers, identifiers, and statuses
remain consistent. The selected theme is stored privately in
`${NODE_HOME}/.cntools/theme` and restored at startup. Only the Koios-inspired
**Default** theme is available in this release; the selector is in place for
future themes. Set `NO_COLOR` to a non-empty value to disable color output.

**Settings → Transaction Defaults** stores one reusable transaction policy in
`${NODE_HOME}/.cntools/transaction-settings.json`. It controls deterministic
coin selection, optional native-token fragmentation, and optional ADA-only
change management. The default `Balanced` selector prefers simple ADA-only
outputs, avoids native assets and outputs carrying datums or reference scripts,
and preserves a suitable collateral candidate when that policy is active.
`Fewest inputs` instead prioritizes a smaller transaction even when it has to
touch native assets. Every transaction review shows both the configured policy
and what it actually did; actions never ask for the same settings again.

Token fragmentation can limit the number of distinct assets placed in each
explicit change output. ADA-only management first maintains one 5 ADA
collateral candidate when needed, then creates only the missing number of
useful outputs from the configured percentage ladder. Percentages use one
frozen post-token, post-collateral change amount, and a standard residual change
output is always retained. Existing eligible outputs and outputs already
planned by the transaction count toward the target. These policies never add
inputs merely for wallet housekeeping; a future **Funds → Collect UTxOs**
action will remain a separate, explicit operation.

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

Account number and address key index both default to `0`; their prompts show
that default and pressing Enter without input selects it.

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

**Wallet → Register** creates the wallet stake-address registration
transaction for a complete CLI, mnemonic, or hardware wallet. It first confirms
that the stake credential is not registered, obtains the current protocol
parameters, and selects sufficient UTxOs from the wallet's base and enterprise
payment addresses. The review shows available versus selected inputs and
balances, the conservative fee margin, every active transaction policy, and
the applied change plan. Remaining ADA and native assets return to the wallet's
base address. The public signer plan requires exactly the payment key and stake
key and is embedded in the portable CNTools transaction package.

With a ready local node, registration queries, balancing, and submission use
that node. Light mode uses Koios, and a local session may use configured Koios
as a fallback when its local construction queries are unavailable. Both wallet
addresses are queried together through one bulk `address_utxos` request;
registration state and Cardano CLI-compatible protocol parameters use focused
Koios requests. The interface identifies the actual data source, preserves
exact UTxO and native-asset quantities, and stops safely when the wallet is
already registered, has no inputs, or cannot cover the deposit, conservative
fee margin, minimum output values, and valid change.

The final choice can create an unsigned package, create and sign it, or create,
sign, and submit it. If local signing keys are encrypted or unavailable, only
the unsigned choice is offered. An unsigned package can be signed through
**Transaction → Sign** in offline mode and later submitted through
**Transaction → Submit** online. Hardware wallets collect the payment and stake
witnesses in one device session and include the payment HWS change reference.
CNTools never places signing keys or HWS contents in the package, never
overwrites an existing artifact, and retains the unsigned and signed files for
audit and recovery.

**Wallet → De-Register** uses the same reviewed transaction flow to retire a
registered stake credential and return its recorded stake deposit. Before any
transaction is built, CNTools confirms from the selected backend that the
credential is registered and that its claimable reward balance is exactly
zero. A non-zero balance is a hard stop and must be withdrawn first. The final
review also warns that lingering rewards earned but not yet credited or paid
out will be forfeited by de-registration, even when the visible reward balance
is zero. Stake-pool and DRep delegations end with the credential.

De-registration uses the same deterministic selector for its fee and returns
the deposit, remaining ADA, and every touched native asset to the base address.
It supports the same unsigned offline package, local signing, direct
submission, and hardware-wallet paths as Register. The locally queried or
Koios-reported credential deposit is used for the refund certificate, while
current protocol parameters are retained for balancing. The package records
selected input references, the configured and applied transaction policy, and
planned explicit change outputs, and distinguishes the refunded deposit from
the deposit charged by registration.

## Transaction signing and submission

CNTools transaction packages are portable, public-only signing envelopes. They
carry the transaction body, network and validity contract, public signer plan,
native-script requirements, collected witnesses, and the signed transaction
when complete. They do not contain private signing keys or hardware signing
files. Required witnesses are deduplicated by distinct public key, even when a
key appears under several wallet labels or roles. Future transaction-producing
actions use the same plan → build → package APIs so Sign can verify what was
planned; **Transaction → Sign** does not accept an arbitrary unsigned body.

Sign first shows package context and then an authoritative Cardano CLI-decoded
review of the transaction body. It can add CLI and hardware witnesses over
multiple runs, including in offline mode, and writes a new validated package
for transfer to another signing system. Every collected or imported witness is
cryptographically verified against the transaction-body ID before CNTools
accepts the package. Witness-bearing operations require OpenSSL 3 or newer and
`xxd`; packages without witnesses do not load either prerequisite.
Native-script plans include the selected branch and validity bounds. Embedded
scripts can be checked exactly when the body has no reference inputs. Every
transaction containing a reference input requires clearly displayed manual
assurance because the referenced on-chain output cannot be proved from the
portable body alone. Declared native reference scripts are also bound to an
exact `transaction-id#output-index`; before confirmation, the review shows the
reference input, declared script and hash, purpose, and selected signer keys.

Hardware groups are completed atomically in one device session: every remaining
group signer and every planned group change reference must be selected together.
Change HWS files are supplied separately, do not add witnesses, and are limited
to standard CIP-1852 payment roles `0`/`1` and stake role `2`. General signing
supports non-Byron Cardano HWS sources. CNTools does not set
`--derivation-type`; its current `cardano-hw-cli` default is `ICARUS_TREZOR`,
which applies only to Trezor devices.

**Transaction → Submit** accepts either a complete validated CNTools package
or an external Cardano transaction envelope and presents the decoded
transaction as the authoritative final review. Package completeness is proven
from its signer plan. For an external envelope, CNTools authenticates supported
Shelley VKey witnesses that are present but cannot infer every required
witness; the screen marks completeness unverified and the chosen backend
performs final ledger validation. External Byron/bootstrap witness sets are not
supported. Submission prefers an available local node and otherwise falls back
to configured Koios access; Koios submission also requires the Guild Deploy
prerequisite `xxd`. Guild Deploy installs both `xxd`
and OpenSSL as runtime prerequisites; OpenSSL older than 3 cannot perform the
required Ed25519 witness verification. Deployment therefore verifies that the
preferred `openssl` executable, or the fallback `openssl3`, reports major
version 3 or newer. On Rocky/RHEL 8 the cnode prerequisite flow uses the EPEL
`openssl3` compatibility package because the system `openssl` remains on
version 1.1.1. Dingo and Amaru accept an existing `openssl3`; operators using
those experimental profiles on Rocky/RHEL 8 must enable EPEL and install that
package first. Incomplete packages, standalone transaction-body files, and all
offline submission attempts are rejected. Transaction
support is contracted to Cardano CLI `11.0.0.0`; Amaru deployments receive it
as the isolated `cardano-cli-amaru` companion while retaining Koios for query
and submission because Amaru has no node-to-client socket. Hardware signing
requires the exact tested `cardano-hw-cli` release `1.19.1`. Every node
implementation can install its reviewed x86_64 or aarch64 artifact with Guild
Deploy `-s w`. Package, signer-source,
hardware-change, output, review, and submission selections are recorded in the
normal CNTools audit log without recording private key content. CNTools checks
the exact Cardano CLI version lazily when the first transaction operation needs
it.

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
