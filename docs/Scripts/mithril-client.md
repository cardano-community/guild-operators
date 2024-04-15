`mithril-client.sh` is a script to manage the Mithril client, a tool used to set up the Mithril client environment and manage downloading Mithril snapshots and stake distributions. The main features include:

- **environment** - Creates a new `mithril.env` file with all the necessary environment variables for the Mithril client.
- **cardano-db** - Download, list all or show a specific available Mithril snapshot.
- **stake-distribution** - Download or list available Mithril stake distributions.
- **-u** - Skip script update check.

## Usage

```bash
Usage: bash [-u] <command> <subcommand> [<sub arg>]
A script to run Cardano Mithril Client

-u          Skip script update check overriding UPDATE_CHECK value in env (must be first argument to script)
    
Commands:
environment           Manage mithril environment file
  setup               Setup mithril environment file
  override            Override default variable in the mithril environment file
  update              Update mithril environment file
cardano-db            Interact with Cardano DB
  download            Download Cardano DB from Mithril snapshot
  snapshot            Interact with Mithril snapshots
    list              List available Mithril snapshots
      json            List availble Mithril snapshots in JSON format
    show              Show details of a Mithril snapshot
      json            Show details of a Mithril snapshot in JSON format
stake-distribution    Interact with Mithril stake distributions
  download            Download latest stake distribution
  list                List available stake distributions
    json              Output latest Mithril snapshot in JSON format

```

## Preparing a Relay or Block Producer Node

To prepare a relay or block producer node, you should follow these steps:

1. **Create the Mithril environment file:** Run the script with the `environment setup` command. This will create a new `mithril.env` file with all the necessary environment variables for the Mithril client.

   ```bash
   ./mithril-client.sh environment setup
   ```

2. **Download the latest Mithril snapshot:** Once the environment file is set up, you can download the latest Mithril snapshot by running the script with the `snapshot download` command. This snapshot contains the latest state of the Cardano blockchain db from a Mithril Aggregator.

   ```bash
   ./mithril-client.sh cardano-db download
   ```

## Investigating Available Snapshots

You can investigate the available snapshots by using the `snapshot list` and `snapshot show` commands:

- **List all available Mithril snapshots:** You can list all available Mithril snapshots by running the script with the `snapshot list` command. Add `json` at the end to get the output in JSON format.

  ```bash
  ./mithril-client.sh cardano-dbsnapshot list
  ./mithril-client.sh cardano-dbsnapshot list json
  ```

- **Show details of a specific Mithril snapshot:** You can show details of a specific Mithril snapshot by running the script with the `snapshot show <DIGEST>` command, where `<DIGEST>` is the digest of the snapshot. Add `json` at the end to get the output in JSON format.

  ```bash
  ./mithril-client.sh cardano-dbsnapshot show <DIGEST>
  ./mithril-client.sh cardano-dbsnapshot show <DIGEST> json
  ./mithril-client.sh cardano-dbsnapshot show json <DIGEST>
  ```

## Managing Stake Distributions

You can manage stake distributions by using the `stake-distribution download` and `stake-distribution list` commands:

- **Download the latest Mithril stake distribution:** You can download the latest Mithril stake distribution by running the script with the `stake-distribution download` command.

  ```bash
  ./mithril-client.sh stake-distribution download
  ```

- **List all available Mithril stake distributions:** You can list all available Mithril stake distributions by running the script with the `stake-distribution list` command. Add `json` at the end to get the output in JSON format.

  ```bash
  ./mithril-client.sh stake-distribution list
  ./mithril-client.sh stake-distribution list json
  ```
