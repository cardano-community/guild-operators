`mithril-signer.sh` is a bash script for managing the Mithril Signer Server. It provides
functionalities such as deploying the server as a systemd service and updating the
environment file to contain variables specific to the Mithril Signer.

## Usage

```bash
Usage: bash [-d] [-D] [-e] [-k] [-r] [-s] [-u] [-h]
A script to setup, run and verify Cardano Mithril Signer

-d    Deploy mithril-signer as a systemd service
-D    Run mithril-signer as a daemon
-e    Update mithril environment file
-k    Stop signer using SIGINT
-r    Verify signer registration
-s    Verify signer signature
-u    Skip update check
-h    Show this help text
```

# Description

This script is a bash script for managing the Mithril Signer Server. It provides
functionalities such as deploying the server as a systemd service, updating the
environment file, and running the server.

# Environment Variables

The script uses several environment variables, some of which are:

- `MITHRILBIN`: Path for mithril-signer binary, if not in `$PATH`.
- `HOSTADDR`: Default Listen IP/Hostname for Mithril Signer Server.
- `POOL_NAME`: The name of the pool.
- `NETWORK_NAME`: The name of the network.

# Execution

The script parses command line options, sources the environment file, sets default
values, and performs basic sanity checks. It then checks if the `-d` or `-u` options
were specified and performs the corresponding actions. If no options were specified, it
runs the Mithril Signer Server.
