#### Architecture

The architecture for various components are already described at [docs.cardano.org](https://docs.cardano.org/explore-cardano/cardano-architecture) by CF/IOHK. We will not reinvent the wheel :smile:

#### Manual Software Pre-Requirements


While we do not intend to hand out step-by-step instructions, the tools are often misused as a shortcut to avoid ensuring base skillsets mentioned on home page. Some of the common gotchas that we often find SPOs to miss out on:

- It is imperative that pools operate with highly accurate system time, in order to propogate blocks to network in a timely manner and avoid penalties to own (or at times other competing) blocks. Please refer to sample guidance [here ](https://ubuntu.com/server/docs/network-ntp) for details - the precise steps may depend on your OS.
- Ensure your Firewall rules at Network as well as OS level are updated according to the usage of your system, you'd want to whitelist the rules that you really need to open to world (eg: You might need node and SSH ports to be open to relays and perhaps home workstation on core, while open node to internet on relays, depending on your topology and configuration that you run).
- Update your SSH Configuration to prevent password-based logon.
- Ensure that you use offline workflow, you should never require to have your offline keys on online nodes. The tools provide you backup/restore functionality to only pass online keys to online nodes.

#### Pre-Requisites

!!! info "Reminder !!"
    You're expected to run the commands below from same session, using same working directories as indicated and using a `non-root user with sudo access`. You are expected to be familiar with this as part of pre-requisite skill sets for stake pool operators.

##### Set up OS packages, folder structure and fetch files from repo {: #os-prereqs}

The pre-requisites for Linux systems are automated to be executed as a single script. This script uses opt-in election of what you'd like the script to do. The defaults without any arguments will only update static part of script contents for you.
To download the pre-requisites scripts, execute the below:

```bash
mkdir "$HOME/tmp";cd "$HOME/tmp"
# Install curl
# CentOS / RedHat - sudo dnf -y install curl
# Ubuntu / Debian - sudo apt -y install curl
curl -sS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh
chmod 755 guild-deploy.sh
```

!!! info "Important !!"
    Please familiarise with the syntax of `guild-deploy.sh` before proceeding (using -h as below). The exact parameters you want to run with is dependent on your, below are only sample instructions

The usage syntax can be checked using `./guild-deploy.sh -h` , sample output below:

``` bash

Usage: guild-deploy.sh [-n <mainnet|guild|preprod|preview|sanchonet>] [-p path] [-t <name>] [-b <branch>] [-u] [-s [p][b][l][m][d][c][o][w][x][f][s]]
Set up dependencies for building/using common tools across cardano ecosystem.
The script will always update dynamic content from existing scripts retaining existing user variables

-n    Connect to specified network instead of mainnet network (Default: connect to cardano mainnet network) eg: -n guild
-p    Parent folder path underneath which the top-level folder will be created (Default: /opt/cardano)
-t    Alternate name for top level folder - only alpha-numeric chars allowed (Default: cnode)
-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
-u    Skip update check for script itself
-s    Selective Install, only deploy specific components as below:
  p   Install common pre-requisite OS-level Dependencies for most tools on this repo (Default: skip)
  b   Install OS level dependencies for tools required while building cardano-node/cardano-db-sync components (Default: skip)
  l   Build and Install libsodium fork from IO repositories (Default: skip)
  m   Download latest (released) binaries for mithril-signer, mithril-client (Default: skip)
  d   Download latest (released) binaries for bech32, cardano-address, cardano-node, cardano-cli, cardano-db-sync and cardano-submit-api (Default: skip)
  c   Download latest (released) binaries for CNCLI (Default: skip)
  o   Download latest (released) binaries for Ogmios (Default: skip)
  w   Download latest (released) binaries for Cardano Hardware CLI (Default: skip)
  x   Download latest (released) binaries for Cardano Signer binary (Default: skip)
  f   Force overwrite config files (backups of existing ones will be created) (Default: skip)
  s   Force overwrite entire content [including user variables] of scripts (Default: skip)

```

1. If you receive an error for `glibc`, it would likely be due to the build mismatch between pre-compiled binary and your OS, which is not uncommon. You may need to compile cncli manually on your OS as per instructions [here](https://github.com/cardano-community/cncli/blob/develop/INSTALL.md#compile-from-source) - make sure to copy the output binary to `"${HOME}/.local/bin"` folder.

A typical example install to install most components but not overwrite static part of existing files for preview network would be:

``` bash
./guild-deploy.sh -b master -n preview -t cnode -s pdlcowx
. "${HOME}/.bashrc"
```

If instead of download, you'd want to build the components yourself, you could use:

``` bash
./guild-deploy.sh -b master -n preview -t cnode -s pblcowx
. "${HOME}/.bashrc"
```

Lastly, if you'd want to update your scripts but not install any additional dependencies, you may simply run:

``` bash
./guild-deploy.sh -b master -n preview -t cnode
```

##### Folder structure

Running the script above will create the folder structure as per below, for your reference. You do NOT require `CNODE_HOME` to be set on shell level as scripts will derive the parent folder and assign it at runtime, the addition in `~/.bashrc` is only for your ease to switch to right folder:


    /opt/cardano/cnode            # Top-Level Folder
    ├── ...
    ├── files                     # Config, genesis and topology files
    │   ├── ...
    │   ├── byron-genesis.json    # Byron Genesis file referenced in config.json
    │   ├── shelley-genesis.json  # Genesis file referenced in config.json
    │   ├── alonzo-genesis.json    # Alonzo Genesis file referenced in config.json
    │   ├── config.json           # Config file used by cardano-node
    │   └── topology.json         # Map of chain for cardano-node to boot from
    ├── db                        # DB Store for cardano-node
    ├── guild-db                  # DB Store for guild-specific tools and additions (eg: cncli, cardano-db-sync's schema)
    ├── logs                      # Logs for cardano-node
    ├── priv                      # Folder to store your keys (permission: 600)
    ├── scripts                   # Scripts to start and interact with cardano-node
    └── sockets                   # Socket files created by cardano-node
