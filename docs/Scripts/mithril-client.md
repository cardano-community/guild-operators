`mithril-client.sh` is a script to manage the Mithril client, a tool used to set up the Mithril client environment and manage downloading Mithril snapshots and stake distributions. The main features include:

- **environment** - Creates a new `mithril.env` file with all the necessary environment variables for the Mithril client.
- **snapshot** - Download, list all or show a specific available Mithril snapshot.
- **stake-distribution** - Download or list available Mithril stake distributions.

## Preparing a Relay or Block Producer Node

To prepare a relay or block producer node, you should follow these steps:

1. **Create the Mithril environment file:** Run the script with the `environment setup` command. This will create a new `mithril.env` file with all the necessary environment variables for the Mithril client.

    ```bash
    ./mithril-client.sh environment setup
    ```

2. **Download the latest Mithril snapshot:** Once the environment file is set up, you can download the latest Mithril snapshot by running the script with the `snapshot download` command. This snapshot contains the latest state of the Cardano blockchain db from a Mithril Aggregator.

    ```bash
    ./mithril-client.sh snapshot download
    ```

## Investigating Available Snapshots

You can investigate the available snapshots by using the `snapshot list` and `snapshot show` commands:

- **List all available Mithril snapshots:** You can list all available Mithril snapshots by running the script with the `snapshot list` command. Add `json` at the end to get the output in JSON format.

    ```bash
    ./mithril-client.sh snapshot list
    ./mithril-client.sh snapshot list json
    ```

- **Show details of a specific Mithril snapshot:** You can show details of a specific Mithril snapshot by running the script with the `snapshot show <DIGEST>` command, where `<DIGEST>` is the digest of the snapshot. Add `json` at the end to get the output in JSON format.

    ```bash
    ./mithril-client.sh snapshot show <DIGEST>
    ./mithril-client.sh snapshot show <DIGEST> json
    ./mithril-client.sh snapshot show json <DIGEST>
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
