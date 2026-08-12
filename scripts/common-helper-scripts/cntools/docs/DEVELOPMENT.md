# Developing CNTools modules

Stage 3 represents the characterized legacy menu in a deterministic shadow
registry without changing its APIs, state, menu, or workflow behavior. The
public legacy dispatcher remains authoritative. Do not move legacy menu code
into the modular tree or make an action stub operational until a later
extraction stage authorizes that specific action.

## Transitional legacy bundle

`cntools.library` is a compatibility facade, not a new library API. It loads
ten read-only fragments in this exact order:

1. `010-common-dialog.sh`
2. `020-terminal-selection-security.sh`
3. `030-governance-query.sh`
4. `040-address-wallet-query.sh`
5. `050-wallet-create-registration.sh`
6. `060-wallet-actions.sh`
7. `070-pool-actions.sh`
8. `080-metadata-assets.sh`
9. `090-governance-actions.sh`
10. `100-transaction-hardware-price.sh`

These files are mechanical contiguous extractions. Do not reformat, reorder,
rename, add new code to, or source a fragment directly. The facade retains all
legacy source-time initialization, including version/default globals and the
terminal escape initialization. Repeated facade sourcing, function
redefinition, return statuses, and existing global inputs and outputs are
compatibility contracts for this stage, including behaviors that later stages
intend to remove.

Each bundle lives below `libs/legacy/<bundle-id>/`. Its ID binds the logical
legacy body plus every member's exact relative name, mode, size, and digest.
Any legitimate byte or boundary change requires a new ID, updated manifests
and receipts, and the complete deployment transaction; never modify an
existing ID directory in place. Older IDs remain during compatibility stages
so an already-running facade remains safe.

The facade's logical-body sentinels, single `# Do NOT modify` marker, fixed
member list, and literal `bundle_id` declaration are part of the transitional
validation ABI. Update them only as one reviewed change with the ten-member
bundle metadata, payload manifest, lifecycle compatibility checks, deployment
source manifest, and extraction oracle. The trusted lifecycle must remain
generic across retained valid bundle IDs in schema-2 and schema-3 generations;
the current dispatcher and public facade remain pinned to the one ID shipped by
their source revision.

The installed facade and bundle must come from `guild-deploy.sh`. The historic
direct cnode/Dingo profile paths deliberately fail instead of attempting a
partial, nontransactional library installation.

## Shadow registry contract

The frozen Stage 3 tree contains exactly 69 canonical `module.json` documents:
15 menus and 54 action leaves. Every action leaf also contains one inert
`action.sh` stub. Four dispatcher-owned control policies synthesize 22
navigation controls, and the static dump contains exactly 90 options. The
generation launcher may validate or dump this model only after authenticating
the installed outer receipt and the complete immutable schema-3 generation;
it does not execute action entrypoints.

`--dump-menu` is a deterministic parity artifact, not a runtime-filtered menu.
Labels, shortcuts, ordering, requirements, control policies, ancestry, and the
library graph must remain data-only and byte-canonical. A legitimate registry
change therefore requires a reviewed update to the parity fixture, focused
registry tests, the 151-member payload manifest, the 152-file receipt, and the
resulting content-addressed generation ID. Never refresh one hash in isolation.

## Adding an action

1. Copy `templates/action/` beneath the appropriate menu directory.
2. Give the directory and metadata a stable ID independent of its label,
   shortcut, order, or directory name.
3. Declare visibility separately from execution requirements.
4. Declare only registered libraries in `runtime.libraries`.
5. Implement exactly one public entrypoint, `cntools_action_main`.
6. Document parameters, result form, statuses, context reads, persistent side
   effects, external commands, and secret handling.
7. Add focused fixtures and parity coverage before switching dispatch.

During Stage 3, a newly described action must remain inert and cannot be added
outside a separately approved contract change to the frozen registry counts.

Module schema v2 includes normative registry adjuncts beyond JSON Schema:
serialize every `module.json` as exact `jq -S .` pretty JSON with one terminal
newline, and keep `runtime.libraries` in strict lexical order. The canonical
byte check rejects duplicate object keys and noncanonical number spellings.

Menu directories contain `module.json` and child module directories only.
Action directories contain `module.json` and `action.sh` only. Symlinks,
unknown files, duplicate IDs, shortcuts or orders, undeclared libraries, and
reserved navigation conflicts are validation failures.

## Shell conventions

- Public functions use `cntools_<domain>_<verb>`.
- Module-private helpers use `_cntools_<module>_<verb>`.
- Locals use descriptive `snake_case`; arrays/maps use plural nouns.
- Functions return success/failure through status, not business data.
- Prefer stdout only for uncontaminated scalars and caller-provided namerefs or
  validated JSON for multiple fields.
- New modular source files define functions only. Sourcing must not create
  directories, install traps, change options or `IFS`, access the network, or
  initialize runtime globals. The compatibility facade's characterized legacy
  initialization is a temporary, explicitly tested exception; its ten
  fragments still contain definitions only.
- Keep Bash 4.4 compatibility and pass ShellCheck without broad undefined or
  unused-global suppressions.

Never source configuration, module metadata, context, or result JSON. Never put
keys, signing material, mnemonics, passwords, API tokens, or arbitrary shell
expressions in those files.
