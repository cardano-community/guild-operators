# CNTools

CNTools is a Bash-based terminal tool for Cardano pool operations and wallet
management. Version 14 keeps the existing CNTools name and release history,
but replaces the former monolithic implementation with a modular framework and
a Charm Gum interface.

!!! warning "Version 14 implementation status"
    The complete navigation tree is available for interface testing, but its
    operational actions are placeholders. Do not expect wallet, pool,
    transaction, governance, or chain operations to work yet.

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
its focused libraries are loaded only when selected. In version 14.0.0 those
actions display a not-implemented notice.

The Update menu can check again, show changelog entries newer than the running
version, or invoke Guild Deploy. Updates replace the complete managed CNTools
tree from one repository snapshot; CNTools exits after starting that process
and should be launched again through `scripts/cntools.sh`.

Session events, selections, external commands, API requests, and errors use the
new redacting logger. Sensitive input, keys, credentials, request bodies, and
command output are not logged by default.

See the [CNTools changelog](cntools-changelog.md) for release progress.
