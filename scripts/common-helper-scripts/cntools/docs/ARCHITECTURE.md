# CNTools modular architecture

This directory contains the inactive Stage 3 shadow generation and the
transitional compatibility bundle. Production still enters through
`scripts/cntools.sh` and runs the characterized legacy menu. Its
`scripts/cntools.library` is now a small facade over mechanically extracted
legacy fragments. The generation launcher exposes authenticated diagnostics
only; modular action dispatch remains inactive until a later explicit gate.

## Generation boundary

A deployment publishes and records a complete immutable inactive generation;
it does not change `active` or `previous`. Canary and future
activation may change those references only after validation. `launcher.sh`
becomes the generation-root `cntools.sh`. It resolves that root once and hands
control to `core/bootstrap.sh`, keeping a running process pinned to one
generation.

The Stage 3 payload manifest uses schema 3 and has exactly 151 members; its
schema-3 generated receipt has exactly 152 files. Lifecycle validation remains
deliberately bounded: it accepts only the exact Stage 1 schema-1 19/20 shape,
the exact Stage 2 schema-2 29/30 shape, or the exact Stage 3 schema-3 151/152
shape. This permits a trusted current lifecycle to validate and roll back to a
preceding generation without weakening any inventory into an open-ended
file-count rule. For a retained generation with a compatibility bundle, that
lifecycle accepts a different valid bundle ID only after recomputing its
logical body and canonical ID, binding its confined
`cntools/libs/legacy/<id>` path, and proving the exact common members plus ten
fixed bundle members. Validation never sources code from the generation being
inspected. The deployment dispatcher is narrower: it emits and installs only
the schema-3 generation and bundle ID pinned by its current source manifest.

Historical Stage 1 and Stage 2 durable generation records have exactly six
tab-separated fields. A Stage 3 record has exactly ten, appending the
discriminator `3,151,3,152`. Recovery rejects truncated, extended, or hybrid
records before target mutation and continues to use data-only validation for
all three supported shapes.

The installed generation launcher derives one physical generation root and
authenticates its outer source receipt and deployment metadata before sourcing
generation code. It verifies the inactive generation binding, exact
implementation-specific outer inventory, version agreement, ownership,
non-symlink layout, immutable modes, complete schema-3 manifest and receipt,
and content-addressed ID. It then acquires the generation lock and repeats the
authority and complete-generation checks under lock before loading the trusted
lifecycle and bootstrap. Imported functions or aliases and an untrusted tool
path fail closed at this boundary.

The authenticated launcher accepts validation, version, help, and deterministic
menu-dump diagnostics only. `--validate-modules` proves the exact registry and
`--dump-menu` emits its static model; neither diagnostic dispatches an action.
The public legacy launcher is unchanged and remains the only production menu.

The payload manifest owns every generation file, mode, and digest. The
operator-owned `scripts/cntools.conf` lives outside generations, is never part
of that manifest, and must eventually be created transactionally with mode
`0600`. The current package ships only `cntools.conf.example` and inactive
parsing tools.

The nested `.generation.json` receipt is content-deterministic and deliberately
contains no repository, ref, revision, or dirty-source provenance. That source
identity belongs exclusively to the authenticated outer deployment receipt and
metadata. Byte-identical payloads from different source revisions therefore
reuse the same immutable generation without rewriting it.

## Legacy compatibility bundle

The compatibility library is split into ten fixed-order fragments below
`cntools/libs/legacy/<bundle-id>/`. The bundle ID is a SHA-256 digest over a
canonical, domain-separated record stream containing the logical legacy body
and every member's relative name, mode, size, and digest. Paths derived from
the ID are validated after the digest is calculated and are not inputs to
their own identifier.

The facade retains the legacy version constants, initialization, defaults, and
the interstitial terminal `ESC` initialization at their characterized logical
positions. The fragments contain the original function bodies without API or
state redesign. The facade resolves its sibling bundle from
`BASH_SOURCE[0]`, validates the exact tree and bundle identity before legacy
initialization, and sources the ten members in a literal order with explicit
failure propagation. It also refuses to start while an outer deployment
transaction journal exists.

The same relative layout works in the repository, in the installed public
runtime, and inside an immutable generation. A generation facade may load only
its own sibling bundle; it never falls back to the mutable public tree. The
public facade remains authoritative only for the existing legacy menu and is
not a shortcut around the future modular dispatcher.

Deployment treats the bundle as one object rather than ten ordinary files. It
stages and validates the complete directory privately, atomically publishes
or exactly reuses it, and installs the referring facade only after the bundle
is complete. Receipt and deployment metadata are committed last. Older valid
bundle IDs are retained during compatibility stages so a process that already
opened an older facade can finish safely. Historical direct profile install
paths cannot provide this transaction and therefore fail closed; use
`guild-deploy.sh` for cnode and Dingo installation or refresh.

The public facade is the first ordinary cnode/Dingo payload member installed
after the private generation and bundle publication legs. From that point it
refuses to load while the durable outer journal exists. Rollback restores the
facade last, after every other payload and private-object leg succeeds. A new
bundle or generation is retracted by moving its complete validated directory
back beneath the journal; only the directory root is temporarily writable.
Transaction-created parent directories are removed only when they remain
owned, real, mode-`0700`, and empty. Any interference leaves the journal and
fail-closed facade in place for recovery.

## Runtime layers

- `core/` validates configuration, context, metadata, navigation, and results.
- `libs/manifest.json` is the strict library ID and dependency registry.
- `modules/root/` is the root of deterministic discovery for exactly 69
  metadata documents: 15 menus and 54 inert action leaves;
- an action leaf contains exactly `module.json` and `action.sh` and exposes the
  fixed, currently inert `cntools_action_main` function;
- four dispatcher-owned control policies synthesize 22 navigation controls;
  the deterministic shadow dump contains exactly 90 options; and
- `templates/action/` is copied when adding an action and is not discoverable.

Metadata and configuration are always parsed as data. They are never sourced,
evaluated, or allowed to contain arbitrary predicates. Menu/action metadata
uses `schema/module.schema.json`; unknown fields and filesystem entries fail
validation. Module schema v2 also has normative byte-level registry adjuncts:
each `module.json` is exactly `jq -S .` canonical JSON with one terminal
newline, and `runtime.libraries` is in strict lexical order. These adjuncts
close duplicate-key and ordering ambiguity that JSON Schema cannot express.

## State boundaries

The target runtime distinguishes immutable application context, action-local
state, persistent operator/domain data, explicit caches, and function results.
The future launcher writes a versioned secret-free JSON context in a private
runtime directory. Actions obtain values through `core/context.sh`; no action
receives a mutable global environment as its data API.

Action status is control flow: `0` returns to the parent, `20` goes Home, `21`
refreshes Home, and `22` exits. Other non-zero statuses are failures. Scalar
results may use clean stdout; multi-field results use the JSON contract in
`core/result.sh`.

## Configuration boundary

`cntools.conf` uses unquoted literal `KEY=VALUE` records. The parser rejects
unknown or duplicate keys, shell syntax, expansions, control characters, and
invalid types. `cntools_config_parse` is data-only so it can validate the
managed read-only example. `cntools_config_load_runtime` adds the owner,
non-symlink, single-link, and mode-`0600` checks required for live use.

`cntools_config_migrate_legacy_header` only analyzes the installed launcher's
pre-boundary text and returns a map. It never evaluates or writes anything.
The only recognized legacy expansion is a textual `${LOG_DIR}/...` prefix for
`CNTOOLS_LOG`. Final migration, Docker defaults, and projection into legacy
globals remain deferred until the explicit state-contract stage.
