# CNTools development contract

This directory is the source root for the new CNTools implementation. The
application is still named **CNTools**: generation markers such as `V2` must
not become part of the product name, runtime paths, source APIs, or library
names. Normal application release numbers remain supported as data.

Funds → Send is described in [the Send implementation plan](SEND-PLAN.md),
including direct-address/Koios Handle recipients, optional CIP-20 messages,
CIP-83 encryption, custom metadata, and the remaining implementation boundaries.

This document fixes the small set of conventions needed before implementation
starts. It is deliberately not a package format or plugin system.

## Scope and runtime boundary

- The framework and entrypoint are written in Bash and target Bash 4.4 or
  newer. Charm Gum provides the terminal presentation and interaction layer.
- Shell entrypoints, libraries, and actions use the `.sh` extension.
- The sibling `cntools.sh` is the stable public launcher. It validates and
  executes `cntools/cntools_main.sh` without containing application logic.
- The former monolithic `cntools.sh` implementation and `cntools.library` are
  retired. They are not compatibility APIs for version 14.
- The common sibling `env` remains unchanged and outside the CNTools source
  tree transaction.
- The common `env` file is sourced exactly once using its `definitions`
  profile. The entrypoint records its own paths before sourcing `env`, because
  common environment loading may change generic variables such as `PARENT`.
- `env definitions` is treated as an opaque configuration bootstrap. New
  CNTools code consumes normalized values from it but does not call functions
  it leaves behind, including deployment, update, generic environment,
  `node_*`, or adapter functions.
- CNTools code must not recreate or source `cntools.library`, copy its
  functions, or call the legacy CNTools helper API.
- New functions use the `cntools_` prefix. New application globals use the
  `CNTOOLS_` prefix.

The entrypoint dependencies are Bash 4.4 or newer, exactly Charm Gum `2.0.0`,
`jq`, `curl`, `tput`, and standard Linux tools including `awk`, `date`, `env`,
`mktemp`, `mkdir`, `chmod`, `mv`, `rm`, `stat`, and `wc`. Git is a Guild Deploy
dependency rather than a CNTools runtime dependency. No additional scripting
language is required.
Wallet Encrypt and Decrypt resolve GnuPG only when selected. Linux `chattr` and
`lsattr` are optional defense-in-depth tools; read-only permissions remain the
portable protection baseline. Koios transaction submission resolves `xxd` only
when selected. Transaction signing and package validation resolve OpenSSL 3 or
newer plus `xxd` only when witnesses are present; every detached Ed25519
signature is checked against the transaction-body ID before it is trusted.
Guild Deploy includes these tools in implementation prerequisites and verifies
OpenSSL at deployment time. It prefers a compatible executable named `openssl`
and falls back to `openssl3`. On Rocky/RHEL 8, where the system package remains
on OpenSSL 1.1.1, the cnode prerequisite flow installs EPEL's coexisting
`openssl3` package. Dingo and Amaru accept that executable when already
available but do not bootstrap an additional package repository.

## Target source layout

```text
cntools/
├── VERSION
├── cntools_main.sh
├── data/
│   ├── README.md
│   └── bip39-english.txt  # Vendored canonical English recovery words
├── core/
│   ├── action.sh
│   ├── gum.sh
│   ├── health.sh     # Best-effort Gum header snapshot
│   ├── log.sh
│   ├── menu.sh
│   ├── settings.sh   # Persistent transaction defaults
│   ├── startup.sh
│   ├── theme.sh      # Semantic colors and persisted selection
│   └── update.sh     # Phase 5
├── lib/
│   ├── number.sh
│   ├── placeholder.sh
│   ├── utxo.sh
│   ├── coin-selection.sh
│   ├── change-plan.sh
│   ├── transaction.sh
│   ├── transaction-build.sh
│   ├── transaction-sign.sh
│   ├── transaction-submit.sh
│   ├── transaction-ui.sh
│   ├── wallet.sh
│   ├── wallet-material.sh
│   ├── wallet-key.sh
│   ├── wallet-address.sh
│   ├── wallet-id.sh
│   ├── wallet-create.sh
│   ├── wallet-create-ui.sh
│   ├── wallet-mnemonic.sh
│   ├── wallet-mnemonic-ui.sh
│   ├── wallet-hardware.sh
│   ├── wallet-hardware-ui.sh
│   ├── wallet-protection.sh
│   ├── wallet-protection-ui.sh
│   ├── wallet-query.sh
│   ├── wallet-remove.sh
│   ├── wallet-remove-ui.sh
│   ├── wallet-register.sh
│   ├── wallet-register-ui.sh
│   └── ...
└── modules/
    └── root/
        ├── module.json
        └── ...
```

The public sibling `../cntools.sh` resolves this tree from its own physical
location and uses `exec` to start `cntools_main.sh`. The internal entrypoint
loads the small `core/` layer and uses Charm Gum for its terminal interface.
Domain libraries beneath `lib/` and action files beneath `modules/` are not
loaded during startup. The small dependency-free `number.sh` utility is the
exception because the root health header also uses its display formatting;
Wallet actions still declare it explicitly as part of their focused stack.

`VERSION` contains exactly one numeric `MAJOR.MINOR.PATCH` application release
number, without a `v` prefix. It is used by the entrypoint, the UI, and the
availability checker, but is never included in the CNTools name or source path.
The rewritten implementation continues the existing CNTools release lineage
at version 14; it is not a separately versioned product.

The filesystem is the menu tree and remains its source of truth. At startup,
CNTools validates the module definitions in one multi-file JSON pass and builds
a small in-memory session catalog. Navigation reads only that catalog; it does
not rescan JSON or action files when the selection moves, a submenu opens, or
an action returns. Restarting CNTools rebuilds the catalog after definitions
change on disk. No combined catalog file is generated or deployed.

The Phase 4 framework mirrors the current CNTools menu hierarchy. It initially
gave every operational leaf an inert `action.sh` with a consistent
not-implemented message. Functional phases replace those placeholders in
small vertical slices; Phase 7 activates Wallet List and Show, Phase 8 activates
Wallet New → CLI, and later slices activate wallet protection and standard
mnemonic creation/import, followed by standard hardware-wallet import and
guarded wallet removal. Wallet Register and De-Register are the first
transaction-producing wallet actions; Transaction Sign and Submit are also
functional. The phase-0
menu inventory remains an implementation checklist, not a generated runtime
manifest.

Pool List and Show are functional read-only browsers for existing pool
directories. Pool New, Import, Encrypt, Decrypt, Register and Modify are also
implemented. Retirement, KES rotation and Calidus remain separate slices.

## Runtime modes

Mode and node implementation are separate values:

| Mode | Blockchain backend | Network access |
| --- | --- | --- |
| `local` | The deployed cnode, Dingo, or Amaru implementation | Local interfaces; Koios enrichment, history/UTxO browsing and optional inclusion monitoring |
| `light` | Koios | Koios query and submission endpoints |
| `offline` | None | Prohibited |

Local is the default. Advanced visibility is a feature flag, not a runtime
mode. Hybrid transaction creation is action behavior within an online mode,
not another startup mode.

Startup sources `../env definitions`, then copies the resolved node home,
implementation, network, service, account, branch, log/temp/domain paths,
update setting, and Koios configuration into `CNTOOLS_` names. New code uses
those normalized names rather than generic environment state such as `PARENT`,
`ENV_PROFILE`, or `OFFLINE_MODE`.

Before sourcing the definitions profile, startup clears socket aliases that
may have been inherited from a shell using another deployment. A `SOCKET`
override declared in the current `env` file is then evaluated normally;
otherwise CNTools derives the socket from the current implementation and node
home.

Startup does not source `env` again with the selected mode and does not perform
blockchain queries. This is important for Amaru: the common Amaru adapter does
not provide the legacy `local`, `light`, or `offline` initialization profiles.
The framework accepts its deployment identity after `definitions`; future new
action libraries perform Amaru readiness checks and query/submission work.

The local backend must treat cnode, Dingo, and Amaru as first-class
implementations. It must not assume every implementation has a Cardano
node-to-client socket or uses the same command-line interface. Light mode is
Koios-backed regardless of which node implementation is installed. Offline
mode must reject HTTP, update checks, queries, and submissions before invoking
an external network command.

The command-line interface retains the familiar mode and feature options:

```text
-n          local mode (default)
-l          light mode
-o          offline mode
-a          show advanced features
-u          skip the automatic update-availability check
-b BRANCH   redeploy from this Guild branch, then exit
-v          print the CNTools version
-h          print help
```

`-b` delegates immediately to guild-deploy and does not start the menu. Branch
persistence occurs only after that deployment succeeds. CNTools does not edit
`env` or deployment metadata directly.

## Menu metadata

Every immediate child directory below a menu is another module and contains
`module.json`. A `menu` module has child module directories and no `action.sh`.
An `action` module has the adjacent `action.sh` entrypoint and no child module
directories.

The root metadata needs only `kind`, `label`, and `description`:

```json
{
  "kind": "menu",
  "label": "CNTools",
  "description": "Cardano pool and wallet operations"
}
```

A non-root menu adds its shortcut and display order:

```json
{
  "kind": "menu",
  "label": "Wallet",
  "description": "Create and manage wallets",
  "shortcut": "w",
  "order": 10
}
```

An action also declares its supported modes and any libraries it needs:

```json
{
  "kind": "action",
  "label": "List",
  "description": "List available wallets",
  "shortcut": "l",
  "order": 10,
  "modes": ["local", "light", "offline"],
  "libs": ["wallet/common.sh", "chain/query.sh"]
}
```

The complete metadata vocabulary is:

- `kind`: required; `menu` or `action`.
- `label`: required; one-line display label.
- `description`: required; one-line help text.
- `shortcut`: required except for the root; one lowercase letter or digit.
- `order`: required except for the root; integer display order from `0` through
  `2147483647` among siblings.
- `modes`: required for actions; a non-empty subset of `local`, `light`, and
  `offline`.
- `libs`: optional for actions and defaults to an empty list. Entries are
  relative `.sh` paths beneath `lib/` and are loaded in declaration order.
- `requiresKoios`: optional boolean for actions, default `false`; disables the
  action when Koios is disabled/unconfigured or CNTools is offline.
- `advanced`: optional on menus only and defaults to `false`. When `true`, the
  visibility restriction is inherited by every descendant.

No other fields are accepted. JSON does not need canonical formatting and no
separate JSON Schema is required. Basic validation is performed directly with
`jq`.

Directory names use lowercase kebab-case. A module's path relative to
`modules/root`, such as `wallet/list`, is its routing and logging identity.
There are no separate stable IDs, library versions, hashes, or library
manifest. Duplicate sibling shortcuts are errors. Shortcuts remain compact
metadata for discoverability and future command-oriented use; Gum navigation
selects the displayed item rather than reserving control keys. Entries are
sorted by `order`, then by directory name so equal order values remain
deterministic.

An action that does not support the current mode remains visible but disabled,
with the reason shown in the UI. Back, Home, and Quit are explicit Gum choices
added by the menu renderer rather than action metadata. Update is a normal
filesystem-backed submenu.

## Action and library loading

Every `action.sh` defines this entrypoint:

```bash
cntools_action_main() {
  # Action implementation.
}

# Optional: remove action-owned temporary or sensitive files.
cntools_action_cleanup() {
  # Cleanup implementation.
}
```

Selecting an action runs a Bash subshell which:

1. validates each declared library path and sources those libraries in order;
2. clears inherited action entrypoint and cleanup definitions;
3. sources the adjacent `action.sh`;
4. verifies that `cntools_action_main` exists;
5. calls it without a context or result protocol; and
6. invokes `cntools_action_cleanup`, when defined, on normal or interrupted
   subshell exit.

The subshell inherits a snapshot of the `CNTOOLS_` session values and core
UI/logging functions. The loader sets `CNTOOLS_ACTION_ID` to the module path
and `CNTOOLS_ACTION_LABEL` to its display label.
Subshell variables and loaded functions disappear when it returns. A zero
status returns normally to the menu, and handled user cancellation also
returns zero. A non-zero status is logged and shown as an action error before
returning to the menu.

Libraries and action files define functions only when sourced. They must not
perform network access, change terminal state, install traps, or create files
at source time, and libraries must not define the reserved
`cntools_action_main` or `cntools_action_cleanup` names. During
`cntools_action_main`, an action may install other subshell-local traps; action
temporary and sensitive files should use the cleanup hook. An
action lists every library it needs in dependency order; there is no library
registry or dependency resolver.

Runtime metadata validation occurs once while the startup catalog is built.
Restarting CNTools validates and rebuilds it after definitions change on disk.
Action scripts and their declared libraries are checked immediately before
invocation and remain lazily loaded.
Deployment and CI validate the entire module tree and run `bash -n` over every
`.sh` file. Invalid metadata, unsafe paths, and loading failures produce a
visible and logged error rather than being silently skipped.

## Terminal UI

`cntools_main.sh` uses Charm Gum for presentation and interaction while the
surrounding framework remains Bash. It shares the same startup normalization,
in-memory menu catalog, lazy action loader, logging, runtime modes, update
state, and Guild Deploy update flow. Moving between menus does not rescan the
filesystem; reopening CNTools builds a fresh catalog when definitions have
changed on disk.

The Gum interface takes its visual direction from Koios: a near-black canvas,
green accent, muted secondary text, restrained borders, and one compact header
for the version, current path, runtime values, and root-menu node health. The
current path leaf uses the green accent so its location is immediately visible.
Local and light sessions show the cached epoch, chain tip, and tip gap snapshot
on the root menu. Health refreshes only on natural root-menu redraws, never
while Gum owns keyboard input. A failed optional probe keeps the selected
runtime values and shows `node offline`; submenus omit the health row. Explicit
offline mode instead shows only `Offline` and never starts a probe.
Menu labels and descriptions come from the existing module metadata. `gum
filter` presents the choices,
allows fuzzy filtering by typing, and invokes the single selected menu or
action when Enter is pressed. Its choice area is recalculated on every menu
draw: all options are shown when the current terminal has room, while smaller
terminals use a scrolling list. Escape first leaves the filter field; pressing
it again goes back from a submenu or redraws the root menu. CNTools exits only
through the Quit choice, while Ctrl+C remains an interruption.
Other Gum controls provide consistent prompts,
confirmation, tables, status messages, and long-text viewing without changing
the action contract. Before Gum starts, CNTools verifies that Bash is operating
under UTF-8 and selects `C.UTF-8`, `C.utf8`, or `en_US.UTF-8` when the caller's
locale is not UTF-8. Startup fails clearly if none is installed, preventing
multibyte labels or metadata from being split into unsafe terminal bytes.

Before starting the interface, the entrypoint requires an exact Gum `2.0.0`
match. If Gum is missing or another version is found, CNTools shows the found
and required versions and asks whether it may install the prerequisite. An
accepted install downloads the official release archive, verifies it against
the official release checksums, and installs only the Gum executable to the
current account's private `~/.local/bin`. Declining the prompt, a failed
checksum, or a failed install exits with a clear prerequisite error. The
preflight does not use a system package manager, request root access, or modify
the CNTools source tree. Offline mode never downloads the prerequisite; Gum
must already be available at the exact version before CNTools can open an
offline session.

## Logging and redaction

CNTools owns a new logger and does not reuse the legacy CNTools logging
functions. The default file is
`${CNTOOLS_LOG:-${CNTOOLS_LOG_DIR}/cntools.log}`, opened for append with mode
`0600`. If its parent directory does not exist, CNTools creates it with mode
`0700`. Startup stops with a clear terminal error if the directory or log file
cannot be opened safely.

Log records are human-readable single lines:

```text
2026-08-26T12:34:56+0200 [ACTION] [wallet/list] selected
2026-08-26T12:34:57+0200 [CMD] [wallet/show] cardano-cli query ... -> 0
2026-08-26T12:34:58+0200 [API] [wallet/show] Replay: curl ...
2026-08-26T12:34:58+0200 [API] [wallet/show] POST /address_info -> 200
```

Core wrappers log:

- session start/end, mode, backend, network, account, and branch;
- menu and action selections, cancellations, and non-secret answers;
- operational external commands, safely rendered argument by argument;
- shell-safe API replay commands with the full URL and non-sensitive payload;
- API method, sanitized endpoint, response status, and duration; and
- validation failures, command failures, API failures, and unexpected errors.

Actions must use the core command wrapper for operational external tools and
the core API wrapper for every API request. Rendering and metadata-parsing
utilities are excluded from operational command logging. The command wrapper
accepts a redaction mask so an action can mark sensitive argument positions;
the execution arguments remain unchanged while those log values become
`<redacted>`. The API wrapper records a copyable `curl` request before using the
lower-level HTTP wrapper, which enforces the offline network boundary and logs
the sanitized result. Authenticated replay commands refer to
`KOIOS_API_TOKEN`; they never embed its value or the private header-file path.

The logger refuses symlinks and non-regular log targets before opening the file.
Secret input values, stdin, environment dumps, HTTP authorization values,
sensitive request fields, signing-key contents, passwords, passphrases, PINs,
mnemonics, seed phrases, and API tokens are never logged. Command stdout is not
logged by default; on failure, a bounded and sanitized stderr/error summary may
be recorded. Sensitive prompts record only that input was accepted or
cancelled. New CNTools code never enables shell tracing with `set -x`.

## Deployment and updates

Guild-deploy is the only component allowed to install or update CNTools. It
stages and validates the complete `cntools/` directory from one resolved Guild
source snapshot before changing the installed tree. A failed stage leaves the
installed tree unchanged; a successful install replaces the complete directory
as one transaction, with rollback if the new tree cannot be installed or
validated. Guild Deploy manages the stable sibling launcher separately from
that replacement boundary and retires any installed `cntools.library` only
after the new tree and launcher are ready.

Guild Deploy installs the complete tree and public launcher but does not
install, package, or update Gum. The internal entrypoint owns its launch-time,
opt-in, checksum-verified private prerequisite install described above. This
does not change Guild Deploy's ownership of CNTools source deployment and
updates.

CNTools does not download or replace individual source files. Guild-deploy
installs its runnable dispatcher at
`${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh`. Install Update restores the
terminal, delegates to that dispatcher using the recorded deployment account,
branch, implementation, network, and target, then exits after every dispatcher
attempt, including a failed one. A running process never resumes after its
installed source tree may have been replaced. If the
dispatcher is unavailable, CNTools prints the exact command the operator
should run instead of falling back to raw-file downloads.

The full-tree transaction replaces the installed `cntools/` directory as one
generation. CNTools exits after Guild Deploy returns and does not resume from
the retired source tree.

When enabled, `core/update.sh` makes one HTTP request through the logged HTTP
wrapper for the selected account and branch's remote
`scripts/common-helper-scripts/cntools/VERSION` file. It compares only that
validated version value and never installs or sources the response. A failed
availability check is a non-fatal warning.

`-u` and `UPDATE_CHECK=N` suppress only this automatic check; a manually
selected Update remains available. Offline mode disables both checking and
update application because guild-deploy requires network access. Applying an
update always remains a guild-deploy operation.

The Update submenu contains Check Again, View Changes, and Install Update.
Only an `available` result places an update notice on the root menu. View
Changes downloads the existing `docs/Scripts/cntools-changelog.md` file on
demand and displays only numeric release sections newer than the installed
version and no newer than the detected version. Downloaded version and
changelog content is size-bounded, treated only as data, and never sourced.

Install Update refreshes scripts and configuration from the configured Guild
branch without requesting OS packages or node binaries. It passes the account
explicitly and requires the requested ref to exist, so the update path cannot
silently fall back to `master`. When the installed and selected branch versions
match, the action shows that equality and offers a default-No confirmation to
force deployment of the same version. Declining returns without invoking Guild
Deploy. Selecting arbitrary historical versions is not part of this phase: it
requires a repository release-tag and rollback policy before it can be offered
safely.

## Phase 2 deployment foundation

Guild-deploy now prepares one temporary shallow Git checkout for the selected
account and branch, then loads the dispatcher, implementation profile, and all
Guild-owned deployment payloads from that checkout. The selected commit is
written to `.deployment.json` as `sourceRevision`, the runnable dispatcher is
installed at `${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh`, and the temporary
checkout is removed after success or failure. The existing raw URL remains the
single-file bootstrap path; external release discovery and checksum-verified
third-party downloads keep their existing flows.

Tracked checkout files must match the recorded commit. Each implementation
profile keeps a direct list of its required single-file shell, JSON, and
template payloads and validates that list before changing the node target. The
recursively managed CNTools directory is the one exception: its complete
tracked tree is discovered and validated together so future modules do not
need to be repeated in three profile lists. Container-only Guild assets are
copied from a checkout whose commit must equal `sourceRevision`; the container
does not perform later per-file Guild downloads.

The deployment CLI, fork and branch selection, confirmed-missing-ref fallback
to `master`, implementation profiles, selective flags, and user-variable header behavior
remain otherwise intact. Historical refs without snapshot support require
their matching historical dispatcher and cannot re-enter raw per-file
deployment. This phase does not add the new CNTools runtime or any functional
action.

## Phase 3 framework

Phase 3 added the first runnable framework beside the legacy tool.
Guild-deploy installed the new source tree at `${NODE_HOME}/scripts/cntools`
for cnode, Dingo, and Amaru while the three legacy sibling files remained
unchanged. Phase 6 later replaced that temporary compatibility boundary.

The framework now provides:

- the `cntools/cntools_main.sh` entrypoint and normalized `env definitions`
  startup;
- local, light, and offline session selection for every implementation;
- Gum-based terminal rendering, filtering, navigation, and reliable cleanup;
- private session logging plus redacted command and HTTP wrappers;
- validated in-memory menu discovery and lazy, subshell-isolated action loading;
- full-tree deployment validation and transactional replacement; and
- branch redeployment delegated to the installed Guild Deploy dispatcher.

Only the root menu metadata is shipped in this phase, so there are no
operational actions yet. The complete inert menu/action inventory is Phase 4,
and the automatic availability check and Update action are Phase 5.

Phase 3 was complete when focused framework, startup, and deployment tests
passed, all repository deployment checks remained green, and the three legacy
files remained byte-for-byte untouched. The development-only native Bash UI
was subsequently retired in favor of the single Gum-based
`cntools/cntools_main.sh` entrypoint.

## Phase 4 menu skeleton

Phase 4 adds the complete current CNTools navigation tree as filesystem
metadata: 15 menus including the root and 54 operational actions. Each action
is deliberately inert, loads only `lib/placeholder.sh`, and presents a shared
"Not implemented yet" notice. No wallet, pool, transaction, query, submission,
or governance implementation is copied from the legacy tool in this phase.

Actions remain visible when the current runtime mode cannot support them, but
the menu disables them before invocation. The declarations cover local
cnode/Dingo/Amaru sessions, Koios-backed light sessions, and genuinely offline
workflows. Governance proposal listing is intentionally online-only because
the current implementation performs a live chain query despite lacking an
early offline guard.

Advanced and its descendants remain hidden unless `-a` is selected. Blocks is
always visible in this inert skeleton; its future functional phase will decide
availability from the new block-history implementation instead of importing
the legacy `BLOCKLOG_DB` visibility check. Quit, Back, and Home remain
framework controls rather than metadata modules. Update remains Phase 5.

The later **Settings → Theme** action is advanced framework functionality,
shown when CNTools starts with `-a`, rather than a legacy operational workflow.
It selects from the central semantic theme
registry and stores the choice in `${NODE_HOME}/.cntools/theme`. The initial
registry intentionally contains only the Koios-inspired Default theme, while
the selector and persistence contract are ready for additional themes. A
non-empty `NO_COLOR` value disables both Gum and semantic value colors.

## Phase 5 update experience

Phase 5 adds one small filesystem-backed Update submenu and three actions. The
eager core layer owns only bounded availability checking and session state;
changelog parsing, confirmation, and installation behavior live in
`lib/update.sh` and load only when an Update action is selected.

The automatic VERSION request occurs after logging is ready and before the
first menu render. Transport errors, HTTP errors, and invalid version data are
logged but do not prevent CNTools from opening. `-u` skips this one automatic
request without removing the manual Update menu. Offline sessions issue no
update HTTP or deployment commands.

An update is installed exclusively through the complete Guild Deploy source
snapshot. CNTools closes after Guild Deploy starts regardless of its result,
because even a later deployment failure may occur after the running CNTools
tree changed. The exact dispatcher status becomes the CNTools process status.
An installed version equal to the selected branch may be force-deployed after
an explicit default-No confirmation; this reuses the same guarded full-snapshot
path rather than introducing a separate updater.
The update is blocked if the configured log lives inside the replaceable
CNTools source tree, ensuring that both this lifecycle decision and its audit
records survive the replacement. Its canonical parent must also be owned by
the current user and not writable by group or other users, so another local
account cannot remove the deployment lifecycle marker.

## Phase 6 public cutover

Phase 6 makes `${NODE_HOME}/scripts/cntools.sh` the public launcher for the Gum
implementation on cnode, Dingo, and Amaru. The launcher contains no CNTools
application framework: it validates the managed directory and entrypoint, then
replaces itself with `cntools/cntools_main.sh`, forwarding arguments, signals,
and exit status.

Guild Deploy installs the modular tree before switching the public launcher.
It no longer deploys the legacy monolith or `cntools.library`, and archives an
installed legacy library only after the new entrypoint is usable. The common
`env` contract remains unchanged. Existing 13.x installations must use the
current Guild Deploy snapshot for this migration; the retired per-file CNTools
self-updater cannot perform the layout transition.

This phase changed the public entrypoint and deployment boundary only. Its
operational menu entries remained placeholders until later functional phases.

## Phase 7 wallet inspection slice

Phase 7 activates Wallet List and Show without copying legacy implementation
code. `lib/wallet.sh` discovers direct wallet directories, rejects symbolic-link
traversal, uses the configured legacy filenames, and classifies CLI, mnemonic,
hardware, multisignature, protected, and incomplete wallets. Focused generation
helpers are loaded only with these actions. They can derive a missing public
verification key, address, credential, or applicable identifier from an
available signing key or multisignature script and cache it in the existing
wallet layout. Existing artifacts are never overwritten, unsafe paths are
rejected, and protected signing keys are not decrypted implicitly.

List renders one responsive multi-line Gum entry per wallet. Wallet tables
snapshot the live terminal width once per table, use the available space up to
a readable maximum, and wrap long identifiers only when the terminal requires
it. It selects the combined base address for a payment-and-stake wallet, the
enterprise address for a payment-only wallet, the reward address plus a
missing-payment note for a stake-only wallet, and the script address for a
multisignature wallet. Live
rows are structural rather than fixed: base UTxO, payment UTxO, rewards, the
inclusive total, and a non-zero native-asset count appear only when they apply
and are known. List asks before running either live backend. A decline renders
the filesystem details with no balance rows and zero backend calls; acceptance
runs the same-shell query beneath a Gum spinner so its prepared arrays remain
available for rendering.

Show renders identity, relevant addresses and hexadecimal credentials,
balances, stake-pool delegation, DRep delegation, and exact native-asset
quantities as Gum tables. Stake registration is part of wallet identity, while
a mnemonic wallet also shows its validated `derivation.path`. Balances include
the distinct native-asset count. After the other wallet tables are printed, a
wallet with native assets gets `Simple`, `Detailed`, and `Skip` choices. Assets
with current total supply exactly one are `NFT`; every other case is `FT`.
NFT rows omit amount, total supply, ticker, and decimals. Simple shows the
remaining relevant identifiers and holding values. Detailed prints the
selected metadata document inline as a bounded tree of real fields, with
standard and Plutus transport wrappers removed, missing fields omitted, and
safety-limit omissions explicitly marked.
Both local and light Wallet Show sessions enrich the table through Koios
`asset_info` bulk requests bounded to 1 KiB
publicly or 5 KiB with an API token, with request pacing below the documented
rate ceiling. Local enrichment runs only when `ENABLE_KOIOS=Y`. Local holdings
remain sourced from the deployed Cardano CLI; Koios is identified separately
as the metadata source and enrichment failure does not invalidate local
results.

Wallet Show and Send share the same token-name selection (ticker for FTs,
then metadata name, safe asset-name text, and a neutral fallback). Send keeps
the full `policy.name` identity alongside the label. Public asset details are
cached for 24 hours under `<node-home>/.cntools/asset-cache`, scoped to network
and Koios endpoint. Only cache misses are requested, still in bulk. Invalid
or expired entries are refetched; cache failure never blocks a transfer.
This cache is only for display metadata, including supply, not wallet balances,
spendable UTxOs, or Handle destinations. With advanced mode enabled, use
**Advanced → Clear asset cache** to discard these disposable cached details
across this deployment's networks. The next lookup fetches them again.

Two-column property/value tables omit redundant column headings. Content
blocks supply one trailing blank line; menus do not add a second one. Send's
transaction information displays expiry as a date with timezone and UTC offset,
using `BLOCKLOG_TZ` from the unchanged common `env`, or UTC when unset.

After successful Send, stake registration/de-registration, or Transaction →
Submit, an interactive session with Koios enabled offers to monitor block
inclusion. This works after local-node submission as well as Koios submission.
The shared monitor makes logged `POST /tx_status` requests for that transaction
ID, with a five-second pause between checks, for at most three minutes. Press
`q` between requests to stop. Three consecutive request/schema errors also stop
monitoring. API authentication uses the same protected, redacted logging as
other Koios calls. Nothing is queried until the operator accepts the offer.
After inclusion is observed, **Time to inclusion** shows elapsed seconds from
successful local-node or Koios submission acceptance, including any delay before
accepting monitoring. It includes polling and indexer delays, not just mempool
residence time. Confirmation counts remain in debug logs, not the result table.

As defined by [Koios's pinned tx_status implementation](https://github.com/cardano-community/koios-artifacts/blob/v1.4.2/files/grest/rpc/transactions/tx_status.sql),
`num_confirmations: null` (or an empty successful response) means inclusion has
not yet been observed; any valid non-null count, including `0`, means the
transaction is in an indexed block. This is an observation, not finality.
Cancellation, timeout, and unavailable/lagging Koios data never turn an accepted
submission into a reported failure, trigger a resubmission, or modify the saved
transaction. Offline and Koios-disabled sessions do not offer monitoring.

Metadata precedence selects one complete document by standard label. CIP-67
label `222` resolves CIP-68 before exact CIP-25 label `721`; label `333`
resolves CIP-68, transaction metadata label `20`, then Token Registry; and
label `444` resolves CIP-68 then Token Registry. Unlabelled assets retain label
`20`, Token Registry, and exact label `721` fallbacks. Complete Registry
documents and exact mint and CIP-68 branches are decoded defensively into
bounded inline display trees.

All numeric Wallet values use lossless US display formatting with comma
thousands separators and a period decimal separator. The shared number library
also validates and normalizes either grouped or ungrouped input for later
transactional action phases. Semantic value colors are applied only after
wrapping: identifiers use one restrained cool accent, numbers one warm-neutral
accent, and statuses the existing success, warning, danger, or muted roles.

Local cnode and Dingo sessions use the deployment-selected Cardano CLI and
explicit node socket with bounded execution. Light List sessions deduplicate
the complete wallet catalog into size-bounded Koios `address_info` and
`account_info` bulk requests; Show uses the same contracts for one wallet.
Funding and reward projections keep lovelace values as decimal strings so
`jq` never rounds them. A successful empty Koios funding response means every
address in that request is unused and is committed as a known zero balance,
zero UTxO count, and zero native-asset count. A non-empty response that omits a
requested address remains partial. Offline sessions perform no blockchain or
HTTP query and do not show the live-balance confirmation. Deterministic
public-artifact generation is local and can still use Cardano CLI without a
node. Amaru's isolated `cardano-cli-amaru` companion supports those key and
transaction operations, while its deployment still declares no local query or
submission capability; live chain data and submission therefore use Koios when
enabled.

Backend failures are non-destructive and do not prevent filesystem wallet
details from being shown. Complete aggregates are shown only when every
structurally relevant funding and reward query succeeds. External commands,
API endpoints and status codes, wallet selections, validation failures, and
backend errors use the CNTools logger. Authorization headers are passed through
private temporary files. Replayable Koios requests include their non-secret
JSON payload, while the token is represented by a `KOIOS_API_TOKEN`
shell-variable reference. Gum v2.0.0 static tables use neutral foreground and
background colors because its print renderer misapplies header styling to the
first data row; the section label above each table carries the Koios accent
instead.

## Wallet transaction and UTxO browsers

**Wallet → Transaction List** and **Wallet → UTxO List** are read-only Koios
views, available in local and light mode when Koios is enabled and configured.
They do not require a reachable local node. Select a wallet and lookup scope, then choose 1–10
items per page; pressing Enter uses the displayed default of **5**.

Both views offer payment-credential or stake-address lookup when the wallet has
both. Payment lookup uses the payment script credential for MultiSig wallets and
covers base and enterprise addresses sharing that credential. Stake lookup covers
all addresses linked to the stake address, including different payment keys, but
not enterprise/payment-only addresses. The available scope is selected automatically
for payment-only or stake-only wallets. No private key or stake registration is
required if valid public lookup material exists; missing public artifacts are
prepared using the existing wallet helpers. The overview identifies the scope.

- Transactions: fetch `credential_txs` (POST) or `account_txs?_stake_address=…`
  (GET) once, without filters or limits, preserving
  its descending block order. Fetch `tx_info` only for the current page or an
  explicit detail lookup, with all eight optional flags enabled. Previously
  visited pages are cached for the visit. Summary amounts are **total transaction
  outputs**, not wallet net balance changes. Numbered headings describe observed
  operations (withdrawals, certificates, governance, mint/burn, script execution).
  Otherwise, `Internal transfer` requires every input and output to share an
  address/payment credential or match the selected wallet's known credentials;
  other transactions use `Transfer`. Metadata never determines these tags.
- UTxOs: fetch `credential_utxos?is_spent=eq.false` or
  `account_utxos?is_spent=eq.false` once with `_extended: true`.
  Show the returned count and counts by address; summarize each output with its
  ADA, native-asset count, comma-separated asset names, creation date, and
  datum/script indicators. Only unspent outputs are listed, as noted when
  opening the action; the redundant `is_spent` field is hidden in Details.
  Full asset identifiers, quantities and metadata belong in Details.
- At exactly 1,000 matches, display the Koios limit warning. Counts describe the
  returned snapshot, not a guarantee of complete wallet history. Reopen the
  action to refresh; outputs can be spent after the snapshot was collected.
- Next/Previous appear only where applicable. Details accepts the global item
  number; transaction details also accept a direct transaction ID. Details use
  an overview and separate Inputs/Outputs sections, with one address-titled table
  per record. Empty optional sections and null fields are omitted. Tables size
  their label/value columns from the content and available terminal width,
  wrapping only when necessary. UTxO summaries/details use the same layout.
  Each asset in an input/output or UTxO detail has its own name-titled table,
  indented beneath its parent record. Asset identifiers and raw quantities remain
  visible; optional metadata adds formatted amounts and names without extra calls.
  CIP-20 metadata shows its label/type and numbered message lines; other metadata
  is pretty-printed JSON, preserving its nested content. Encrypted CIP-83 messages
  are identified, not decoded. The separate viewer returns with **q**.
- Asset names and decimal amounts are opt-in and reuse the shared one-day Koios
  metadata cache. Raw identities and smallest-unit quantities remain visible.
  Declining metadata does not make enrichment calls. Metadata is display-only.

Requests use the existing authenticated, replayable API logging. Responses and
rendered detail files use protected temporary files, removed on action cleanup.
Transport/schema errors are not mistaken for empty wallets. Page responses must
contain exactly the requested transaction IDs, and are reordered to match the
inventory before numbering. API response size is bounded at 32 MiB.

Human timestamp displays use `cntools_timestamp_datetime_into`; slot expiry and
virtual Handle lease displays share this date path and the `BLOCKLOG_TZ` setting
from `env` (`CNTOOLS_TIMEZONE`, default UTC). Machine timestamps in logs and
transaction packages retain their existing formats.

The optional boolean `requiresKoios` action metadata disables these entries when
Koios is disabled/unconfigured or CNTools is offline. A request-time availability
error still handles an unreachable service without preventing CNTools startup.

## Phase 8 CLI wallet creation slice

Phase 8 activates **Wallet → New → CLI**. The action creates a deliberately
small standard wallet: payment and stake signing keys, their verification keys,
payment, reward, and base addresses, and raw hexadecimal payment and stake
credential hashes. Governance, committee, and multisignature material is left
to its dedicated future actions. No `derivation.path` is written, preserving
the existing CLI-versus-mnemonic classification contract.

The Gum flow validates the wallet name without silently changing it, shows the
target and exact artifact plan, and requires a default-No confirmation before
generating keys. Confirmed work runs beneath the shared spinner. Success shows
responsive address and credential tables plus one clear private-key backup
warning.

Creation is a node-independent local operation in local, light, and offline
modes. It requires the configured Cardano CLI and network identity but no node
socket, node health, Koios request, or query library. Commands and failures use
the standard redacting logger; private key contents and generated command
output are not logged.

All artifacts are built with private modes in a uniquely tracked hidden
directory beneath the configured wallet root. Each verification key is
independently re-derived from its signing key. The completed shape and every
matching key pair, address, credential, filename, and mode are validated before
one atomic GNU `mv` no-clobber publication. Existing files, directories, and
symbolic links are never replaced. Handled failure, cancellation, interruption,
or a concurrent target collision removes only the tracked staging directory and
cannot expose a partial wallet. The rename is the commit point, so later display
or revalidation problems produce a committed-wallet warning rather than a false
creation failure. An uncatchable kill or power loss can leave a private hidden
stage; internal staging names are excluded from wallet discovery and logged so
a confirmed stale directory can be removed securely.

## Mnemonic wallet creation and import slice

Wallet New → Mnemonic generates exactly 24 words with the deployed, pinned
Cardano CLI. The phrase is shown as one copyable line and a responsive numbered
table using six columns when the terminal permits, then cleared before four
random word positions are verified. Wallet Import → Mnemonic supports hidden
paste of a complete phrase and filter-assisted one-word-at-a-time input. The
interactive selector uses the vendored canonical BIP39 English list, shows at
most five prefix matches, and selects a word automatically when only one match
remains. Input whitespace is normalized and standard 12, 15, 18, 21, and
24-word phrases are accepted.

Both actions expose the account number and payment/stake key index supported by
`cardano-cli latest key derive-from-mnemonic`. They derive standard CIP-1852
extended signing keys, record the generic path marker
`1852H/1815H/<account>H/x/<index>`, generate the focused public artifact set,
and reuse the private staging and atomic publication boundary from CLI wallet
creation. Every derived extended signing key is checked against an independently
derived normalized verification key before publication.

Both derivation prompts show `0` as their default and accept an empty response
as zero. Each preparation and validation stage records a focused error so the
interface does not fall through with only a generic action status.

Recovery words are provided to Cardano CLI only over standard input. They are
not persisted or included in command arguments, child environments, or logs,
and every handled failure removes the tracked private stage. Arbitrary-purpose
and CIP-1854 derivation remain outside this slice because the pinned Cardano CLI
does not expose a custom purpose/path argument; the future multisignature action
can use `cardano-address` as a focused dependency only for those paths.

## Hardware wallet import slice

Wallet Import → HW Wallet imports one standard CIP-1852 payment key and one
stake key through `cardano-hw-cli`. Account number and address key index both
default to `0`; the resulting paths are
`1852H/1815H/<account>H/0/<index>` and
`1852H/1815H/<account>H/2/<index>`. Multisignature and governance derivation
remain in their dedicated future actions rather than expanding this flow.

The hardware dependency is resolved and checked only when this action is
opened, so it does not affect CNTools startup or non-hardware actions. The
interface shows the exact paths and target before a default-No confirmation,
then guides the operator to connect and unlock the device. Device detection and
the public-key export use bounded commands and the shared progress display.
Every command and failure is logged without private material. Every node
implementation can install the pinned `cardano-hw-cli` `1.19.1` dependency
with Guild Deploy `-s w`.
Address and credential generation also requires the deployment's configured
Cardano CLI, but neither executable needs a running node for this action.

Both keys are requested in one hardware CLI operation. CNTools validates each
hardware signing-file type, exact requested path, and extended public key, then
proves that its first public-key component matches the corresponding Cardano
verification key. Addresses and credential hashes are generated through the
existing focused libraries. The exact ten-file wallet shape, owner-only modes,
and absence of ordinary private signing keys are checked before atomic
no-clobber publication. The action works in local, light, and offline modes
because importing public material does not require a node or Koios.

## Wallet protection slice

Wallet Encrypt and Decrypt keep the established GnuPG symmetric `.skey.gpg`
format so wallets protected by CNTools 13 remain usable. Encryption requires a
new passphrase of at least 12 characters plus confirmation. Decryption accepts
any non-empty passphrase without line breaks because existing wallets may use
shorter legacy values. The passphrase is sent to GnuPG through an inherited
file descriptor with loopback pinentry and symmetric-key caching disabled; it
never appears in the command arguments, environment, temporary files, or log.

Encryption stages every AES-256 output, round-trip decrypts it, validates the
Cardano signing-key envelope, and compares the restored JSON with its source
before publishing any `.gpg` file. Decryption stages and validates all clear
keys before publishing any of them. Wrong passwords, cancellation, invalid
keys, symbolic links, mixed clear/encrypted state, and staging failures fail
closed without overwriting an existing path. The actions are local filesystem
work and remain available in local, light, and offline modes; Wallet List and
Show never unlock protected keys implicitly. An owned, writable legacy wallet
directory with group/public write bits is normalized before key material is
changed; ownership and access failures remain hard errors with specific logs.

Every protected non-address file receives mode `0400`; an open wallet uses mode
`0600`. With normalized `ENABLE_CHATTR=true`, CNTools tests immutable-flag
support on the wallet filesystem and tries direct access followed by an
existing non-interactive sudo policy. Unsupported filesystems, missing tools,
or denied permission produce a visible logged warning and retain the read-only
baseline instead of aborting otherwise valid encryption. Decryption removes
an existing immutable flag when needed even if the current setting is disabled.

## Shared transaction foundation and Sign/Submit slice

Transaction work uses focused lazy libraries: `transaction.sh`,
`transaction-build.sh`, `transaction-sign.sh`, `transaction-submit.sh`, and
`transaction-ui.sh`, plus shared file-export and monitoring helpers. They are
loaded only by actions that need them. The shared
foundation owns the signer plan, guarded body construction, package validation,
signing, submission, and the operator review flow. Future transaction-producing
actions must use its plan → build → package APIs instead of assembling an
unverified body beside the framework.

The finalized signer plan deduplicates witnesses by distinct public key, not by
wallet, label, role, or signing-file path. Its portable CNTools transaction
package contains only public material: the transaction body, network and
validity contract, public signer identities, native-script requirements,
detached witnesses, and the completed signed envelope when available. Private
keys and hardware signing files remain runtime sources. Package intent and
summary fields provide context; the Cardano CLI-decoded transaction is the
authoritative review, available through **Show decoded transaction**. Decoding
and validation still happen before review, even when that option is not opened.

Native-script plans record the selected `all`, `any`, or `atLeast` branch, its
required signers, and compatible `before`/`after` validity bounds. Embedded
scripts receive exact assurance only when the body has no reference inputs.
Every transaction containing a reference input retains manual assurance because
the referenced on-chain output cannot be proved from the portable body alone.
A declared native reference script is bound to an exact
`transaction-id#output-index`; debug logs record that input
together with the declared script, hash, purpose, and selected keys. The compact
review retains the warning when reference-script verification is required.

Transaction Sign accepts a CNTools package, never an arbitrary unsigned body,
because the latter has no verifiable signer plan. It can add CLI and hardware
witnesses incrementally, including offline, and publishes another validated
package until every distinct public-key witness is present. Hardware session
groups are atomic: every still-missing signer and every planned change reference
in a selected group is supplied in one hardware operation. Change HWS files are
passed separately, create no witness, and are limited to standard CIP-1852
payment roles `0`/`1` or stake role `2`. General signing sources accept supported
non-Byron Cardano HWS types and paths; CNTools does not override
`--derivation-type`, so `cardano-hw-cli` currently uses its Trezor-only default,
`ICARUS_TREZOR`.

Transaction Submit accepts either a complete, validated CNTools package or an
external Cardano transaction envelope. It rejects incomplete packages and
standalone transaction-body files. CNTools can prove package completeness. For
an external envelope it authenticates supported Shelley VKey witnesses that
are present, but explicitly marks completeness unverified and delegates final
ledger validation to the chosen backend; external Byron/bootstrap witnesses
are not supported. A ready local node is preferred; otherwise an enabled Koios
backend is used. Submission is prohibited in offline mode. These contracts are
tested against the cnode deployment's pinned Cardano CLI `11.2.3.1` only.
Amaru/Dingo-specific CLI coverage is outside this rebuild work. Hardware signing requires the exact tested
`cardano-hw-cli` release `1.19.1`. Transaction package, signer-source,
hardware-change, output, review, and submission selections are audit logged.
CNTools validates the exact Cardano CLI version lazily when the first
transaction operation needs it.

### Transaction UI contract — required for every new action

Use the shared helpers in `transaction-ui.sh` and `transaction-files.sh` rather
than copying a workflow from an individual action. This contract applies to
Send, Withdraw Rewards, Register, De-Register, delegation, DRep lifecycle and standalone Sign/Submit:

- Show action-specific essentials (recipients, metadata, rewards or deposit)
  and a compact **Transaction information** table with the actual fee, applicable
  input/change policies and human-readable expiry. Two-column property/value
  tables have no redundant header. Keep safety warnings visible, including
  forfeited pending rewards, fees exceeding rewards and manual script assurance.
- Offer workflows in this order: **Create, sign and submit**, **Create and sign**,
  **Create unsigned package**, then **Cancel**. If local signing sources are
  unavailable, offer only unsigned export and cancellation. Construction still
  needs chain data; offline signing is a separate step.
- Every transaction-creating action uses the shared expiry choice: **30 minutes**,
  **2 hours**, **24 hours (offline signing)**, or **No expiry**, plus cancellation.
  Bounded choices use the current chain slot; No expiry omits the upper validity
  bound entirely (it is not slot zero). This does not bypass input, reward or
  other state checks. Standalone Sign/Submit preserve the existing body and its
  validity bounds; changing expiry requires rebuilding and signing again.
- Use `cntools_transaction_ui_review_into`: the primary continue/save choice
  comes first, followed by **Show decoded transaction**, **Show required signers**,
  applicable change/edit options, and **Cancel**. Raw package/intent JSON is
  logged for debugging only; there is no package-details dump option.
  Inspection does not rebuild or sign anything. Changed recipients require a
  fresh build and another review. A workflow change alone does not change the body.
- Keep intent JSON, witness identifiers, fee reserves, input references and full
  decode out of the normal screen. Log the technical review and expose details
  on demand. Imported packages show effects from the authoritative decode, not
  untrusted intent text; unusually large decoded numeric literals are explicitly
  referred to the exact decode instead of risking rounded display values.
- Keep intermediate artifacts in the private, cleanup-tracked temporary area.
  Do not ask for output paths. Publish validated final unsigned, partially signed
  or signed packages without overwrite under `${NODE_HOME}/transactions/`, and
  report the saved path for offline/sign-only outcomes, declined submission and
  failures. Retain signed packages before attempting submission.
- Do not dump the transaction again after signing. Confirm submission with the
  shared yes-default prompt, naming **local node** or **Koios**. Never silently
  switch backends after confirmation. Render status, transaction ID and any
  relevant saved path in one **Transaction result** table; failures use the same
  structure. Offer the shared optional Koios monitor only after accepted submission.
- Preserve all package, network, witness, hardware and action-specific safety
  checks regardless of how much detail is visible. Hardware-prepared bodies are
  validated and reviewed again before signing. Add cancellation/no-side-effect
  and optional-review tests when introducing another action.

`cntools-transaction-flow.sh` exercises this common contract for both stake
lifecycle operations; the Send, withdrawal and Sign/Submit suites cover their
respective orchestration. No workflow test submits a real transaction.

## Governance keys and wallet status

**Vote → Governance → Derive Keys** adds a DRep identity to an existing CLI or
mnemonic wallet. Choose a fresh random CLI key pair or derive from a recovery
phrase with the deployment-pinned Cardano CLI. Account defaults to zero; DRep
derivation uses `1852H/1815H/<account>H/3/0` as supported by the CLI, following
[CIP-105](https://cips.cardano.org/cip/CIP-0105). This slice does not support
custom paths, hardware key derivation, multisig DReps or committee keys.

The recovery phrase uses the existing masked paste or word-by-word controls.
It is supplied to the CLI through standard input, never command arguments or
logs, and is not saved. A DRep phrase/account may differ from the payment wallet:
the review explicitly warns that those recovery details need their own backup.
Random CLI DRep keys must be backed up as files, not recovered from a mnemonic.
No registration, delegation or other transaction is performed by key setup.

`drep-key.sh` reuses wallet staging, strict key-envelope validation, pair checks
and public-key normalization. It publishes the private key, public key, CIP-129
ID and, for mnemonic derivation, `drep.derivation.path` using no-overwrite links.
Existing DRep keys, IDs, hardware references, scripts and certificate artifacts
block creation. Partial publication rolls back only this operation's own links.
The recorded DRep path does not change the payment/stake `derivation.path` file.

Protected wallets must be decrypted explicitly before adding a DRep key. Wallet
Encrypt/Decrypt now includes normal and extended DRep signing keys alongside
payment/stake keys, with the same GPG format, password rules and file locking.

**Info & Status** selects a wallet and displays its DRep identity, credential,
key availability and recorded derivation path. Missing public keys/IDs can be
regenerated from available keys; existing mismatches are reported, not replaced.
Cached IDs remain inspectable without a CLI, labelled as checksum-only checks.
Local mode prefers node DRep state, with explicit Koios fallback when enabled;
light mode uses Koios. Offline mode performs no network calls. Failed queries
show status unavailable, never falsely claim that the DRep is unregistered.
Available deposit, activity, expiry epoch, delegated stake/delegator count and
metadata URL/hash are displayed with their data source. Metadata references are
shown without fetching arbitrary external URLs. Local raw expiry is not used to
infer activity because governance dormancy affects that calculation.

Tests use the cnode deployment CLI pin and cover missing-only recovery,
no-overwrite and partial-publication handling, GPG round trips, invalid phrases,
secret-free logs, cancellation and offline/API-failure behavior.

## Active governance proposals and DRep votes

**Vote → Governance → List Proposals** browses active proposals in pages of 1–10
(Enter uses 5), with identifiers, action type, proposed/expiry epochs and local
vote counts. Details show on-chain action fields, deposit/return information and
metadata anchors. Local mode reads the full governance state, so proposals from
the current epoch are included; `query proposals` would exclude them. Light mode
uses Koios `proposal_list`, including indexed titles and descriptive metadata.
Refresh, next/previous pages and lookup by list number, CIP-129 `gov_action1…` or
`transaction-hash#index` are available. Koios requests are paginated below its row
cap; an oversized/malformed catalog fails instead of silently losing proposals.
The last voting epoch is inclusive. Removed, enacted and expired actions are not
offered for voting. Indexed metadata is untrusted and not independently checked
against its anchor hash; arbitrary metadata URLs are never fetched automatically.
Vote counts are counts of recorded decisions, not stake-weighted ratification
thresholds or a prediction that the proposal will pass.

**Cast vote** selects a wallet with verified payment and registered key-DRep
identities, then an open proposal and **Yes**, **No** or **Abstain**. The proposal
details and exact ID are shown before confirmation. An existing vote triggers
an explicit default-No replacement confirmation. Query failure is not treated
as no previous vote. Voting costs only the fee, not another DRep/stake deposit;
it does not renew DRep activity. Conway bootstrap protocol version 9 permits
DRep votes only on informational actions. Ratified Koios proposals remain
browsable but cannot be selected for a new vote.

A rationale anchor is optional: supply a published HTTP(S)/IPFS URL of at most
128 bytes and a Blake2b-256 hash, or hash the exact bytes of a local JSON document
using the pinned CLI. Prepare/publish [CIP-100](https://cips.cardano.org/cip/CIP-0100)
metadata separately; CNTools neither uploads it nor validates its complete schema.
Rationale anchors belong to the vote, not CIP-20 transaction metadata.

The shared compact review, expiry including **No expiry**, transaction defaults,
required-signers view, CLI/extended/protected and existing hardware sources,
sign-only, unsigned/offline packages, durable exports and submission/Koios
monitoring all apply. The payment and DRep witnesses are deduplicated; a stake
witness is not needed. Hardware change references use the same safety checks as
DRep registration. Committee, pool and script-DRep votes are not supported by
this key-DRep action. Offline creation still requires an online build followed
by transport of the unsigned package; signing itself needs no node or API.

Before export/signing and again before live submission, CNTools rechecks the
funding source, selected inputs, transaction expiry, DRep registration, proposal
identity/content/expiry and this DRep's previous vote. Other voters' changes do
not invalidate the review. Decoded vote fields must match the reviewed DRep,
proposal, decision and rationale with no extra votes/certificates/actions, even
after hardware normalization. Fee calculation uses the exact CLI body and
deduplicated witness count, without an additional fee budget. Saved packages
remain available if a late state change prevents submission.

`cntools-governance-vote.sh` covers local/Koios normalization, CIP-129 identity
binding, expiry/bootstrap eligibility, failure handling, decoded vote validation
and stale-state checks. Shared flow tests cover live, signed and unsigned paths,
cancellation and pre-sign/pre-submit rechecks. `cntools-governance-vote-pinned.sh`
uses only the cnode deployment CLI pin for real Yes/No/Abstain artifacts, normal
and extended signatures, rationale hashing, token conservation, No expiry and
offline packages, asserting exact equality with the signed ledger fee size.
CI also checks transformation with the pinned hardware companion.

Query schemas: [Koios proposal list](https://github.com/cardano-community/koios-artifacts/blob/v1.4.2/files/grest/rpc/governance/proposal_list.sql),
[Koios proposal votes](https://github.com/cardano-community/koios-artifacts/blob/v1.4.2/files/grest/rpc/governance/proposal_votes.sql).

## DRep registration, update and retirement

**Vote → Governance → DRep Registration / Update** selects a wallet with verified
DRep keys and a payment identity. A payment-only wallet is sufficient; its stake
key need not exist or be registered. Unregistered DReps use the current protocol
`dRepDeposit`. Registered DReps automatically use an update certificate, charging
only the fee and renewing DRep activity, even if the metadata is unchanged.

Registration offers optional metadata. Updates offer **Keep current metadata**,
**Add / replace metadata** and **Remove metadata**. Supply a published HTTP(S) or
IPFS URL (at most 128 bytes) with its Blake2b-256 hash, or hash the exact local JSON
file using the pinned CLI. CNTools does not upload the document or validate the
full [CIP-119 schema](https://cips.cardano.org/cip/CIP-0119). Confirm that the
published bytes match the local file; anchors are certificate fields, not
transaction-message metadata. Neither keeping an anchor nor entering a known
hash fetches its external URL.

**DRep Retire** requires a registered DRep and a default-No confirmation. It
refunds the actual deposit recorded on-chain, not today's protocol deposit.
Zero recorded deposits are supported. Retirement ends the DRep registration;
delegators should choose another representative. It does not remove wallet keys.

The compact shared transaction review, expiry (including No expiry), coin
selection/change settings, CLI or available hardware signing sources,
sign-only and unsigned/offline package workflows are reused. The funding wallet
and DRep each provide a witness; a stake witness is not needed. Protected or
public-only keys can produce an unsigned package for later signing. New hardware
DRep key derivation and script-DRep registration remain separate slices.

Current chain data comes from the local node or enabled Koios backend. Query
failure or malformed state is never treated as an unregistered DRep. Before
export/signing and again before live submission, recheck selected inputs,
expiry, backend, registration, recorded deposit and anchor. Registration also
rechecks the current protocol deposit. A change requires rebuilding and reviewing
the transaction. CLI-decoded certificates must match the reviewed credential,
deposit/refund and anchor, including after hardware transformation.
Fee balancing uses the pinned CLI's `calculate-min-fee` with the exact built
body, protocol parameters and deduplicated witness count. Fee and change are
rebuilt until sufficient, then checked again after any hardware normalization.
No extra fee budget is added. Signed-size regression checks use the ledger's
fee-size definition, which excludes the serialized one-byte `IsValid` flag.

Node-free tests use only the CLI version pinned by the cnode release metadata.
They cover normal/extended DRep witnesses, payment-only funding, ADA and token
change, recorded/zero refunds, anchors, expiry/no-expiry, unsigned packages and
exact conservation. Deterministic tests cover API failures, state changes,
cancellation and all three transaction workflows. These tests do not submit
transactions or exercise a physical hardware device.

## Governance voting delegation

**Vote → Governance → Delegate** changes voting delegation for an already
registered CLI, mnemonic, public/watch-only or hardware key wallet. Select a
specific DRep, **Always Abstain**, or **Always No Confidence**. There is no new
deposit, reward withdrawal, DRep registration, or change to pool delegation.
Unregistered stake addresses must use **Wallet → Register** first. Multisig
stake credentials remain a separate implementation slice.

The focused `drep-id.sh` helper validates Bech32 checksums, payload length,
padding and credential type, normalizing legacy CIP-105 key/script identifiers
to CIP-129. Bare hashes are rejected because they do not identify key versus
script credentials. A script-based *target DRep* does not require that DRep's
script or keys to delegate to it. The wallet supplies its own payment and stake
witnesses through the existing signer plan.

`drep-query.sh` verifies the exact target through the selected chain-data
backend: local `query drep-state` or Koios `drep_info`. Retired/unregistered or
unverifiable targets cannot proceed. Koios-reported inactive DReps require an
explicit, default-No confirmation. Local state verifies registration only:
raw expiry alone is not treated as proof of inactivity because dormant
governance epochs affect expiry. Predefined options require no DRep lookup.
Selecting the current delegation produces no transaction.

The shared stake transaction UI, input/change settings, expiry choices and
live/sign-only/unsigned workflows are reused. Before export/signing and again
before live submission, recheck stake registration, current voting/pool
delegation, selected inputs, expiry, target registration and any newly reported
inactivity. A change requires a rebuild/review; no target or body is silently
replaced. The CLI-decoded certificate must exactly match the reviewed stake
credential and target, with no deposit, extra certificates, withdrawal or pool
delegation. Signed/exported packages follow the common recovery workflow.

Regression coverage includes identity/schema failures, cancellation, all three
workflows, stale state, and node-free build/sign/package validation for all four
target forms using the deployment-pinned CLI. Physical hardware and live preview
submission still require operator acceptance testing. References:
[CIP-129](https://cips.cardano.org/cip/CIP-0129) and
[Koios DRep info](https://github.com/cardano-community/koios-artifacts/blob/v1.4.2/files/grest/rpc/governance/drep_info.sql).

## Funds UTxO collection

**Funds → Collect UTxOs** consolidates a key wallet's base and payment UTxOs back
to its verified base address (or payment address for a payment-only wallet).
Choose **ADA-only UTxOs** or **ADA and native assets**. Datum-bearing and
reference-script outputs are always excluded and their count is shown. Rewards,
stake deposits, registration and delegation are unchanged. Multisig/script
spending is not supported.

Collection uses current local/Koios funding data, exact integer quantities, the
shared payment/hardware signer plan, and explicit fee convergence. The selected
inputs are rechecked before live signing and submission. Only the payment witness
is required; base-address hardware change still carries both public derivation
references. Encrypted/public-only wallets can export unsigned packages for
**Transaction → Sign → Submit**. Transaction creation needs current chain data;
offline signing does not.

Saved token-fragmentation, percentage-based ADA management and collateral
settings apply without asking for them again. The review shows selected funds,
excluded inputs, resulting outputs, fee, expiry (including No expiry) and all
applied policies. A warning explains when change settings create as many or more
outputs than were selected. With shaping disabled, an already-consolidated
single output is rejected as a no-op.
Ordinary ADA-only collateral candidates are eligible inputs too; enable
collateral management in Settings to recreate one when needed.

Collection is one reviewed transaction, not an unattended series of batches.
More than 1,000 eligible inputs, an oversized transaction/value or insufficient
ADA fail safely without silently dropping inputs or assets. Try ADA-only scope
or adjust fragmentation where appropriate. Submission uses the shared confirmation,
retained signed package and optional Koios inclusion monitor.

Tests cover selection exclusions, no-ops, state changes, cancellation, offline,
sign-only and live workflow orchestration. The node-free pinned CLI tests cover
ADA-only consolidation, exact large native-asset quantities, change shaping and
durable unsigned exports; no test submits real funds.

## Funds reward withdrawal slice

**Funds → Withdraw Rewards** withdraws the full, exact claimable reward balance
to the same wallet's base address. It leaves stake registration, the deposit,
pool delegation, and voting delegation unchanged. Complete CLI, mnemonic, and
standard hardware wallets are supported; multisig and stake-only wallets are
outside this slice. Selected inputs carrying reference scripts are rejected;
use ordinary funding UTxOs rather than consume a stored script without pricing
its additional fee. Cached payment, base, and reward addresses are checked
against the public keys before constructing a stake transaction.

Local mode queries the local node when available; light mode uses Koios. The
action requires fresh rewards, protocol parameters, a current slot, and at least
one eligible spending UTxO. Empty/unregistered reward accounts, unavailable
chain data, and zero rewards stop construction with an explanation. Conway
protocol versions 10 and 11 require an existing voting delegation, including
Always Abstain or Always No Confidence; this action never adds one implicitly.

The shared selector reserves fees and minimum change ADA, then explicit
`build-raw` balancing converges using Cardano CLI's minimum-fee calculation.
This avoids the withdrawal-credit discrepancy found in the pinned CLI's
`build-estimate` path. Rewards are counted exactly once, every selected native
asset returns to the wallet, and configured token fragmentation and ADA-only
management apply to the returned funds. The final body is checked after any
hardware normalization for fee, size, reward account, amount, and destination.
Payment and stake witnesses are required, with the stake signer marked for
withdrawal; hardware witnesses and change references share one device session.

The compact review shows rewards, fee, net benefit (or extra fee paid from the
wallet), return address, active input/change policies, and expiry. Decoded
transaction and signer details are available on request. Choose live signing
and submission, signing without submission, or an unsigned package for offline
signing. Missing/encrypted local signing keys allow only unsigned export.
Building needs chain access even when the package will be signed offline.

Live signing and submission recheck rewards, selected inputs, and expiry;
changed rewards require a new reviewed transaction. Offline packages may also
become stale across an epoch or another withdrawal: rebuild if their exact
reward balance changes. The ledger remains authoritative at submission.
Final packages are saved privately under
`${NODE_HOME}/transactions/withdraw-rewards-<timestamp>.<suffix>/` and survive
action cleanup, including cancellation or ambiguous submission failures.
Successful submission offers the existing optional Koios inclusion monitor.

`cntools-funds-withdraw.sh` tests guard conditions and workflow choices.
`cntools-withdraw-pinned.sh` constructs and signs synthetic, node-free withdrawals
with verified deployment-pinned CLI binaries and tests ADA/token conservation,
small rewards, change management, and durable package publication. CI invokes
it from the existing pinned-binary suite. No test submits a transaction.

## Pool inventory and detail browsers

**Pool → List** and **Pool → Show** use the same responsive, themed,
headerless property tables as Wallet List/Show. List renders one compact table
per directory, with public identity, cold-key material, registration status and,
when requested, pledge/cost/margin. Show adds local KES/VRF key-material and
operational-certificate presence, local configuration, owners, relays, metadata,
and available on-chain settings. Presence is not a check that a KES key or
operational certificate is current or usable; those checks belong to the KES
management slice. Private-key contents are never read or displayed.

This slice does not create, repair, encrypt, or overwrite any existing pool
artifact. A cold verification key is checked with the **cnode deployment-pinned
CLI** to derive the pool ID in memory. Existing `pool.id` and
`pool.id-bech32` must agree with it and each other. A stored ID can be used for
read-only inspection when no cold public key exists; a conflicting or invalid
identity is shown with a warning and excluded from live lookup. Incomplete
directories remain visible. Symlinked directories/files and staging directories
are excluded; configured filenames cannot escape the pool directory.

List asks before fetching chain information and uses a Gum spinner. Show
fetches only the selected pool. Offline mode makes no node/API requests, and
missing, malformed, or unavailable data never prevents browsing local details.
Local mode prefers the configured node's `latest query pool-state`, showing
current settings and any pending next-epoch update separately. If a local query
fails, available Koios is used as an explicitly labeled fallback. Light mode
uses `pool_info`, batching up to 100 unique pool IDs per request without a
response-side limit. Duplicate/unexpected identities or malformed responses
are errors, not evidence of an unregistered pool. Empty node results mean
**Not registered**; empty Koios results mean **Not indexed** (indexer lag is
possible). Retired Koios records remain visible as historical registrations.

Koios shows its latest indexed registration and effective epoch, not a claim
that every latest parameter is already active. Metadata is clearly descriptive:
only existing `poolmeta.json` or Koios-indexed metadata is displayed, never
downloaded from an arbitrary pool URL. Local `pool.config` values are labeled
as local configuration, not proof of registration. Public configuration and
metadata fields are whitelisted and terminal-control characters sanitized.
Local Show can also enrich descriptive metadata through Koios without replacing
the local node's registration parameters or pending updates. Failure to obtain
optional metadata does not fail the pool view.
Every external CLI/API invocation uses the shared logged request wrappers.

Tests cover offline isolation, safe discovery, conflicting IDs, new/retired
pools, pending parameters, bulk Koios requests, malformed responses, optional
local JSON, cancellation, and presentation. The node-free pinned cnode test
generates real cold/KES/VRF keys and an operational certificate, compares
identity with CLI output, and verifies existing artifacts remain unchanged.
Live node/API behavior should additionally be checked on a test deployment.

## Funds stake pool delegation slice

**Funds → Delegate** delegates or re-delegates a complete CLI, mnemonic or
standard hardware wallet to a stake pool. Choose **Enter pool ID** (checksummed
`pool1…` or 28-byte hexadecimal hash) or **Local pool**. Local selection derives
the ID from the pool cold verification key, falling back to the stored pool ID
when no public key is available; it never reads the pool signing key. Existing
`POOL_COLDKEY_VK_FILENAME` and `POOL_ID_FILENAME` overrides are respected.

The current stake pool and selected target are shown separately. Pool IDs do not
encode a network: the target must exist in a successful query against the selected
network. Local mode uses `latest query pool-state`; the Koios path uses a focused
`pool_info` request, with optional name/ticker metadata clearly labeled. Metadata
URLs are never fetched. Missing/retired pools, mismatched identities, duplicate
results and malformed responses are rejected. A scheduled retirement is shown
and needs explicit confirmation. Selecting the current pool does not create a
redundant transaction.

If the stake address is not registered, the operator must approve the current
protocol deposit before CNTools constructs one registration-and-stake-delegation
certificate. Already-registered wallets pay only the transaction fee. Reward
balances and DRep delegation are not changed. The result screen reminds users
that, under current Conway rules, reward withdrawal requires DRep voting
delegation, including Abstain/No Confidence; ordinary transfers are unaffected.
See [CIP-1694](https://cips.cardano.org/cip/cip-1694). No voting choice is made
automatically by this action.

The existing shared stake workflow supplies expiry (including No expiry), compact
review, signer inspection, CLI/hardware signing, unsigned or signed portable
packages, submission and optional Koios inclusion monitoring. The existing coin
selection and change policies apply. Delegation explicitly balances outputs,
deposit and fee using exact integer helpers plus the pinned CLI's minimum-output
and minimum-fee checks; it does not use `build-estimate` for balancing. This avoids
the double-counted registration deposit and empty-output balancing discrepancies
reproduced with the cnode deployment-pinned CLI. Standalone Register and
De-Register share this balancing path, with pinned regression tests for ADA-only
and token-bearing inputs, expiry/no-expiry, deposit/refund conservation and signing.
De-Register refunds the recorded stake deposit, even when it differs from the
current protocol deposit. No transaction is submitted by these tests.

The target certificate, stake credential, deposit, change destination, fee and
absence of voting/withdrawal changes are checked against the decoded body before
signing, including after hardware normalization. Reference-script inputs are
not supported by this slice. Before live signing and submission, selected inputs,
expiry, registration/delegation state, any required registration deposit and the
pool's retirement schedule are rechecked. A changed or unavailable state stops
the flow without silently rebuilding; an already-saved signed package is retained.
Offline signing uses the reviewed frozen body; the submission backend ultimately
validates current ledger state.

Focused tests: `cntools-funds-delegate.sh`, the shared transaction-flow suite, and
`cntools-delegate-pinned.sh` (invoked by the pinned-binary CI suite). The latter
builds/signs registered and unregistered cases with token change and checks deposit
conservation and validity bounds. Hardware normalization runs when the pinned
hardware tool is supplied; physical device approval and live inclusion remain
manual acceptance checks.

Pool response contracts were checked against
[Koios v1.4.2 pool_info](https://github.com/cardano-community/koios-artifacts/blob/v1.4.2/files/grest/rpc/pool/pool_info.sql)
and the [pinned CLI pool-state schema](https://github.com/IntersectMBO/cardano-cli/blob/cardano-cli-11.2.3.1/cardano-cli/src/Cardano/CLI/Type/Common.hs).

## Pool creation, import and protection

**Pool → New** prepares cold, KES and VRF key pairs, a new zero issue counter,
and both pool-ID formats. It does not register the pool, issue an operational
certificate or invent a KES start period. Keys are validated in a private staging
directory before the complete directory is published without overwriting an
existing pool. Creation and import require the deployed Cardano CLI but no node
connection, and are available in local, light and offline sessions.

**Pool → Import** copies an existing directory without modifying its source.
Only bounded, regular top-level files are accepted; links and nested directories
are rejected. Missing public keys can be derived from supported private keys in
the destination. Existing public keys and cached IDs must match. Counters and
certificates are preserved and structurally checked against their keys, not reset
or regenerated. These checks do not verify certificate signatures or compare the
issue counter with the live chain. Missing operational artifacts remain missing.

Hardware import exports a cold public key and signing reference through the
pinned hardware companion using [CIP-1853](https://cips.cardano.org/cip/CIP-1853),
with cold index defaulting to zero. Its cold private key remains on the device.
It prepares fresh KES/VRF keys and a zero counter, not an operational certificate.
For an already registered hardware pool, recover its original VRF and correct
counter before subsequent registration or certificate issuance. Physical device
approval remains a manual acceptance check.

**Pool → Encrypt / Decrypt** follows the legacy protection model: GnuPG protects
only the cold signing key. KES and VRF keys stay readable for node operation.
New encryption requires at least 12 password characters; decryption accepts
shorter legacy passwords. Passwords are supplied through a private descriptor,
never command arguments or logs. Encryption is round-trip verified, and decrypted
keys must match any existing cold public key, before the original is retired.
Failed operations retain the original key; cleanup never deletes the last copy.

Encryption sets owner-only read permissions on pool files and uses immutable
flags when `ENABLE_CHATTR` permits and the filesystem/permissions support them.
Otherwise read-only permissions are the fallback. Decryption removes locks and
restores owner read/write permissions. Hardware and watch-only pools can also
lock/unlock their local files without a password. Keep independent offline
backups: neither permissions nor encryption protects against password loss.

Focused safety tests run in `cntools-pool-manage.sh`; the pinned suite also runs
them against the cnode deployment's Cardano CLI version. Tests cover no-clobber
publication, missing-key derivation, source preservation, invalid imports, GPG
round trips, legacy short passwords and failure rollback.

## Pool registration and modification

**Pool → Register / Modify** use the shared transaction review, exact CLI fee
calculation, configured coin selection/change policies and automatic package
storage. Both offer live signing/submission, sign-only and an unsigned package
for later **Transaction → Sign / Submit**. Building needs current chain data;
offline systems can sign an exported package without node/API access.

Choose a verified local pool and a separate funding wallet, then review pledge,
fixed cost, margin, reward account, owner stake keys, DNS/IP/SRV relays and
optional metadata URL/hash. Pledge is a commitment, not a payment from the
funding wallet. Fixed cost must meet the live protocol minimum. Amounts accept
US thousands separators. For exact decoded-JSON validation, this slice limits
pledge/cost to 9,007,199,254.740991 ADA and supports up to 20 owners/relays.
An uploaded metadata file is not managed here: select a local JSON file to hash
(at most 512 bytes), or supply an existing published URL and hash. CNTools
does not upload or download arbitrary pool metadata URLs.

Register checks that the pool is unregistered and charges the current protocol
pool deposit. Modify requires registration and charges **no new deposit**.
Current settings are preserved; local pending next-epoch settings take precedence
so editing one field does not undo a previous update. Changing a retiring pool
cancels its retirement. A local VRF key conflicting with the registered identity
is rejected. Koios returns its latest indexed registration; an absent result is
explicitly flagged for indexer lag, not treated as proof of immediate chain state.

The funding payment key, pool cold key and **every owner stake key** witness the
certificate, deduplicated by public key. The reward key does not need a witness
unless it is also an owner. Owners/reward accounts may use known wallets or
external stake public keys. Unresolved existing owners remain visible until
their public key is supplied or they are explicitly removed. Missing/encrypted
signing keys select the unsigned route; no private key belongs in a portable
package. Hardware cold/owner keys use the shared hardware sessions. With the
[pinned hardware companion's pool-signing rules](https://github.com/vacuumlabs/cardano-hw-cli/blob/v1.19.1/docs/pool-registration.md),
hardware funding requires a hardware cold key on the **same Ledger**, explicitly
confirmed and witnessed together. Choose CLI/mnemonic funding for a CLI cold key.
Every hardware owner signs separately, even on the operator's device; owners
are never batched with payment/cold keys. Change-key references are preserved.

The decoded certificate is verified against **every reviewed pool parameter**,
input, expiry and change destination before export or signing. The chain source,
protocol parameters, pool registration/pending/retirement state and unspent inputs
are rechecked before signing/export and again before submission in the originating
online action. An offline signer verifies the exported transaction, not current
chain state. Advancing pool
statistics are excluded from this comparison. A changed state requires rebuilding,
not silently charging a different deposit. Native assets are preserved as change.
Registering owner/reward stake accounts, delegating pledge, creating operational
certificates and starting the node are separate actions.

`cntools-pool-registration.sh` covers state/defaults/UI contracts and optionally
real certificates, exact deposits, native assets, no expiry, offline signing and
multiple owners using only the cnode deployment CLI pin. Linux pinned CI also
checks hardware transaction normalization. Live submission and physical device
approval remain deployment acceptance tests.

## Wallet stake lifecycle slice

Wallet Register and De-Register are the first actions built on the shared
transaction foundation. They support complete CLI, mnemonic, and standard
hardware wallets in local and light sessions. Register verifies that the stake
credential is not already registered; De-Register requires it to be registered
and its exact claimable reward balance to be zero. Register loads the current
protocol stake deposit, while De-Register uses the deposit recorded for that
credential by the local ledger query or Koios. Both build a lossless per-output
inventory for the wallet's base and enterprise payment addresses, then use the
shared deterministic selector. Cardano CLI returns remaining ADA and every
touched native asset to the base address and the signer plan requires exactly
the payment key for spending and the stake key for the certificate.

A ready local node supplies stake state, UTxOs, protocol parameters and
submission. When the local backend cannot supply the construction data,
CNTools may fall back to enabled Koios access. Light mode uses one bulk
`address_utxos` request for both funding addresses, plus focused
`account_info` and `cli_protocol_params` requests. Register and De-Register use explicit
`build-raw` balancing in both modes: the deposit is charged or refunded exactly once,
all change outputs meet minimum ADA, and fees converge using the pinned CLI,
including a check after hardware normalization. Reference-script inputs are
rejected because their extra fees are not supported by this builder.
De-Register checks that outputs plus fees equal selected inputs plus the recorded
stake deposit refund; any remaining rewards must be withdrawn first.
UTxO quantities remain decimal strings while CNTools
selects and aggregates them, including native assets, so large values are not
converted through floating point. The exact external commands and replayable
Koios calls are recorded by the normal audit logger.

Transaction defaults live under the root **Settings** menu rather than in each
action. `Balanced` selection ranks simple ADA-only outputs first, followed by
more complex ADA, a protected collateral candidate, token-bearing outputs, and
finally token-bearing outputs with datums or reference scripts. Within those
constraints it chooses a smallest sufficient output or a deterministic
largest-first combination. `Fewest inputs` is available when minimizing
transaction size matters more than avoiding tokens. Both stop at a bounded
input count and use a conservative protocol-derived fee margin plus current
minimum-output requirements.

Optional token fragmentation creates deterministic asset bundles with a
configured maximum asset count and obtains the minimum ADA for every bundle
from the pinned Cardano CLI. Optional ADA-only management creates only the
deficit relative to existing eligible outputs: first a 5 ADA collateral
candidate when missing, then useful percentage-based outputs calculated from
one frozen remaining-change amount. Neither policy selects extra inputs only
to improve wallet shape. The standard residual change remains with the wallet;
**Funds → Collect UTxOs** is the explicit exception: it selects all eligible
inputs in the chosen scope instead of selecting only enough to fund an action.
The transaction review and portable package record both the configured policy
and its applied selection/change result.

The operator can keep an unsigned portable package, sign it immediately, or
sign and submit it. Encrypted or otherwise unavailable local signing keys
restrict the action to package creation; that package can be moved to offline
Transaction Sign sessions and returned to an online Transaction Submit session.
The package never contains signing-key or HWS contents. Hardware payment and
stake witnesses are grouped into one device session and the payment HWS file is
also declared as the change-address reference. The compact shared review shows
the stake address, deposit/refund, actual fee and active policies. Signer and
decoded-transaction details are menu options. Unsigned export and signed results
use automatic no-overwrite filenames under `${NODE_HOME}/transactions/`; signed
packages are retained before any submission attempt. Intermediate unsigned
artifacts remain private and are cleaned up when no longer needed.

De-Register uses the pinned `stake-address deregistration-certificate` command
and marks the current deposit as refunded in its package intent. A non-zero
claimable reward balance stops construction and directs the operator to
withdraw first. Its confirmation also warns that lingering rewards which have
not yet been credited or paid out will be forfeited and that stake-pool and DRep
delegations end when the credential is removed.

## Explicit non-goals

The new implementation does not use:

- copied or mechanically split legacy CNTools code;
- a CNTools-owned `bin/` directory or `.bash` filenames (the Gum prerequisite
  uses the standard user-private `~/.local/bin` location);
- versioned names, stable library IDs, or content hashes;
- library manifests or dependency graphs;
- generated menu catalogs or compiled registries;
- immutable deployment generations, receipts, framework signatures, or a
  general package/plugin schema; or
- a context/result serialization protocol between the menu and actions.

## Historical Phase 1 acceptance

Phase 1 was complete when this contract was introduced and:

- the then-existing `cntools.sh`, `cntools.library`, and `env` files were
  unchanged;
- naming, layout, metadata, loading, runtime, logging, and update ownership are
  were no longer open design questions;
- no functional action or new runtime behavior had been introduced; and
- repository whitespace and Markdown checks passed.
