`mithril-signer.sh` is a bash script for managing the Mithril Signer Server. It provides
functionalities such as deploying the server as a systemd service and updating the
environment file to contain variables specific to the Mithril Signer.

!!! warning "cnode-only deployment"
    The standalone Mithril helpers are currently installed only by the cnode
    profile. Dingo and Amaru profiles do not install or support them.

Install or refresh the Mithril signer and client binaries with
`guild-deploy.sh -s m`. Their `latest` or pinned release policy is read from
`${NODE_HOME}/files/cnode-release.json`, and the executables are installed in
`$HOME/.local/bin`.

## Usage

```bash
Usage: mithril-signer.sh [-d] [-D] [-e] [-k] [-r] [-s] [-u] [-h]
       mithril-signer.sh systemd <install|remove|status>
A script to setup, run and verify Cardano Mithril Signer

-d    Deploy mithril-signer as a systemd service
-D    Run mithril-signer as a daemon
-e    Update mithril environment file
-k    Stop signer using SIGINT
-r    Verify signer registration
-s    Verify signer signature
-u    Skip update check
-h    Show this help text
systemd
      Install, remove, or show the status of the mithril-signer service
```

## Description

This script is a bash script for managing the Mithril Signer Server. It provides
functionalities such as deploying the server as a systemd service, updating the
environment file, and running the server.

## Environment Variables

The script uses several environment variables, some of which are:

- `MITHRILBIN`: Path for mithril-signer binary, if not in `$PATH`.
- `HOSTADDR`: Default Listen IP/Hostname for Mithril Signer Server.
- `POOL_NAME`: The name of the pool.
- `NETWORK_NAME`: The name of the network.
- `MITHRIL_HOME`: The Mithril data and environment directory, normally
  `${NODE_HOME}/mithril`.

## Execution

`-d` is the compatibility alias for `systemd install`. The signer owns
`${CNODE_VNAME}-mithril-signer.service`, which defaults to
`cnode-mithril-signer.service`. Manage that unit without the removed central
systemd orchestrator:

```bash
./mithril-signer.sh systemd install
./mithril-signer.sh systemd status
./mithril-signer.sh systemd remove
```

Installation generates or validates the Mithril environment, checks that the
selected Mithril release supports the installed cnode version, and enables the
unit. It does not start the service immediately. Use `-D` to run the signer
interactively as a daemon process.
