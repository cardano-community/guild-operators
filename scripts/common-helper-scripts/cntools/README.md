# CNTools development contract

This directory is the source root for the new CNTools implementation. The
application is still named **CNTools**: generation markers such as `V2` must
not become part of the product name, runtime paths, source APIs, or library
names. Normal application release numbers remain supported as data.

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
portable protection baseline.

## Target source layout

```text
cntools/
├── VERSION
├── cntools_main.sh
├── core/
│   ├── action.sh
│   ├── gum.sh
│   ├── health.sh     # Best-effort Gum header snapshot
│   ├── log.sh
│   ├── menu.sh
│   ├── startup.sh
│   ├── theme.sh      # Semantic colors and persisted selection
│   └── update.sh     # Phase 5
├── lib/
│   ├── number.sh
│   ├── placeholder.sh
│   ├── wallet.sh
│   ├── wallet-material.sh
│   ├── wallet-key.sh
│   ├── wallet-address.sh
│   ├── wallet-id.sh
│   ├── wallet-create.sh
│   ├── wallet-create-ui.sh
│   ├── wallet-mnemonic.sh
│   ├── wallet-mnemonic-ui.sh
│   ├── wallet-protection.sh
│   ├── wallet-protection-ui.sh
│   ├── wallet-query.sh
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
mnemonic creation/import. The phase-0 menu inventory remains an implementation
checklist, not a generated runtime manifest.

## Runtime modes

Mode and node implementation are separate values:

| Mode | Blockchain backend | Network access |
| --- | --- | --- |
| `local` | The deployed cnode, Dingo, or Amaru implementation | Local implementation interfaces; optional Koios metadata enrichment |
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

The later Advanced **Theme** action is framework functionality rather than a
legacy operational workflow. It selects from the central semantic theme
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
node. Amaru remains a first-class local deployment: its wallet files are shown,
while live chain values are clearly marked unavailable when its deployment
manifest declares no local CLI capability.

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
paste of a complete phrase and hidden one-word-at-a-time input. Input whitespace
is normalized and standard 12, 15, 18, 21, and 24-word phrases are accepted.

Both actions expose the account number and payment/stake key index supported by
`cardano-cli latest key derive-from-mnemonic`. They derive standard CIP-1852
extended signing keys, record the generic path marker
`1852H/1815H/<account>H/x/<index>`, generate the focused public artifact set,
and reuse the private staging and atomic publication boundary from CLI wallet
creation. Every derived extended signing key is checked against an independently
derived normalized verification key before publication.

Recovery words are provided to Cardano CLI only over standard input. They are
not persisted or included in command arguments, child environments, or logs,
and every handled failure removes the tracked private stage. Arbitrary-purpose
and CIP-1854 derivation remain outside this slice because the pinned Cardano CLI
does not expose a custom purpose/path argument; the future multisignature action
can use `cardano-address` as a focused dependency only for those paths.

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

## Explicit non-goals

The new implementation does not use:

- copied or mechanically split legacy CNTools code;
- a CNTools-owned `bin/` directory or `.bash` filenames (the Gum prerequisite
  uses the standard user-private `~/.local/bin` location);
- versioned names, stable library IDs, or content hashes;
- library manifests or dependency graphs;
- generated menu catalogs or compiled registries;
- immutable generations, receipts, signatures, or package schemas; or
- a context/result serialization protocol between the menu and actions.

## Historical Phase 1 acceptance

Phase 1 was complete when this contract was introduced and:

- the then-existing `cntools.sh`, `cntools.library`, and `env` files were
  unchanged;
- naming, layout, metadata, loading, runtime, logging, and update ownership are
  were no longer open design questions;
- no functional action or new runtime behavior had been introduced; and
- repository whitespace and Markdown checks passed.
