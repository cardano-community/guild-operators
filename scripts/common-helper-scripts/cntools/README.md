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
│   └── update.sh     # Phase 5
├── lib/
│   ├── placeholder.sh
│   ├── wallet.sh
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
loaded during startup.

`VERSION` contains exactly one numeric `MAJOR.MINOR.PATCH` application release
number, without a `v` prefix. It is used by the entrypoint, the UI, and the
availability checker, but is never included in the CNTools name or source path.
The rewritten implementation continues the existing CNTools release lineage
at version 14; it is not a separately versioned product.

The filesystem is the menu tree and remains its source of truth. At startup,
CNTools validates the complete visible tree and builds a small in-memory
session catalog. Navigation reads only that catalog; it does not rescan JSON or
action files when the selection moves, a submenu opens, or an action returns.
Restarting CNTools rebuilds the catalog after definitions change on disk. No
catalog file is generated or deployed.

The Phase 4 framework mirrors the current CNTools menu hierarchy. It initially
gave every operational leaf an inert `action.sh` with a consistent
not-implemented message. Functional phases replace those placeholders in
small vertical slices; Phase 7 activates Wallet List and Show. The existing
phase-0 menu inventory remains an implementation checklist, not a generated
runtime manifest.

## Runtime modes

Mode and node implementation are separate values:

| Mode | Blockchain backend | Network access |
| --- | --- | --- |
| `local` | The deployed cnode, Dingo, or Amaru implementation | Local implementation interfaces only |
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
```

Selecting an action runs a Bash subshell which:

1. validates each declared library path and sources those libraries in order;
2. clears any inherited `cntools_action_main` definition;
3. sources the adjacent `action.sh`;
4. verifies that `cntools_action_main` exists; and
5. calls it without a context or result protocol.

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
`cntools_action_main` name. During `cntools_action_main`, an action may install
subshell-local cleanup traps for its own temporary or sensitive files. An
action lists every library it needs in dependency order; there is no library
registry or dependency resolver.

Runtime menu validation occurs once while the startup catalog is built.
Restarting CNTools validates and rebuilds it after definitions change on disk.
Actions and their declared libraries are still checked immediately before
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
for the version, current path, runtime values, and node health. The current
path leaf uses the green accent so its location is immediately visible. Local
and light sessions show a cached epoch, chain tip, and tip gap snapshot. A
failed optional probe keeps the selected runtime values and shows `node
offline` in the health row without blocking CNTools. Explicit offline mode
instead shows only `Offline`, omits the health row, and makes no probe. Health
refreshes only on natural menu redraws, never while Gum owns keyboard input.
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
the action contract.

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
2026-08-26T12:34:58+0200 [API] [wallet/show] POST /address_info -> 200
```

Core wrappers log:

- session start/end, mode, backend, network, account, and branch;
- menu and action selections, cancellations, and non-secret answers;
- operational external commands, safely rendered argument by argument;
- API method, sanitized endpoint, response status, and duration; and
- validation failures, command failures, API failures, and unexpected errors.

Actions must use the core command wrapper for operational external tools and
the core HTTP wrapper for every API request. Rendering and metadata-parsing
utilities are excluded from operational command logging. The command wrapper
accepts a redaction mask so an action can mark sensitive argument positions;
the execution arguments remain unchanged while those log values become
`<redacted>`. The HTTP wrapper enforces the offline network boundary as well as
logging and header/token redaction.

The logger refuses symlinks and non-regular log targets before opening the file.
Secret input values, stdin, environment dumps, HTTP authorization headers or
bodies, signing-key contents, passwords, passphrases, PINs, mnemonics, seed
phrases, and API tokens are never logged. Command stdout is not logged by
default; on failure, a bounded and sanitized stderr/error summary may be
recorded. Sensitive prompts record only that input was accepted or cancelled.
New CNTools code never enables shell tracing with `set -x`.

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
silently fall back to `master`. Selecting arbitrary historical versions is not
part of this phase: it requires a repository release-tag and rollback policy
before it can be offered safely.

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

## Phase 7 read-only wallet slice

Phase 7 activates Wallet List and Show without copying legacy implementation
code or changing existing wallet data. `lib/wallet.sh` discovers direct wallet
directories, rejects symbolic-link traversal, reads the configured legacy
address filenames, and classifies CLI, hardware, multisignature, protected,
and incomplete wallets. It never generates a missing address or rewrites a
wallet file.

`lib/wallet-query.sh` loads only for List and Show. Local cnode and Dingo
sessions use the deployment-selected Cardano CLI and explicit node socket with
bounded execution. List shows distinct non-ADA token count, rewards, UTxO
balance, and a total that includes both UTxO and rewards. Light List sessions
deduplicate the complete wallet catalog into size-bounded Koios `address_info`
and `account_info` bulk requests; Show uses the same contracts for one wallet.
List asks before running either live backend. A decline renders the catalog
with unavailable live columns and zero backend calls; acceptance runs the
same-shell query beneath a Gum spinner so its prepared arrays remain available
for rendering. Offline sessions perform no command or HTTP query and do not
show this confirmation. Amaru remains a first-class local deployment: its
wallet files are shown, while live chain values are clearly marked unavailable
because its deployment manifest declares no local CLI capability.

Backend failures are non-destructive and do not prevent filesystem wallet
details from being shown. Complete aggregates are shown only when every
distinct funding-address query succeeds. External commands, API endpoints and
status codes, wallet selections, validation failures, and backend errors use
the CNTools logger. Authorization headers are passed through private temporary
files and, together with request bodies, remain outside the log.

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
