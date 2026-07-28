# Mithril overview

[Mithril](https://mithril.network/doc/) provides certified Cardano database snapshots
that can substantially reduce the time needed to bootstrap a new node. The Guild
Operators wrappers help install and manage:

- [Mithril Client](https://mithril.network/doc/manual/develop/nodes/mithril-client/) to
download a snapshot for the network the node is attached to via the
[mithril-client.sh](../Scripts/mithril-client.md) script.
- [Mithril Signer](https://mithril.network/doc/manual/operate/run-signer-node/) to
participate in the creation of stake-based signatures via the
[mithril-signer.sh](../Scripts/mithril-signer.md) script.
- Squid-based Mithril relay to forward signer traffic to a Mithril aggregator, as
described in the upstream [signer deployment
guide](https://mithril.network/doc/manual/operate/run-signer-node/),
via the [mithril-relay.sh](../Scripts/mithril-relay.md) script.

!!! note "Node implementation support"
    The Guild Mithril integration currently supports `cnode` only. The alternative-node
    deployment profiles reject the cnode-specific `-s m` component flag.

When `MITHRIL_DOWNLOAD="Y"` is set in the deployed `scripts/env` file, `cnode.sh`
automatically invokes `mithril-client.sh` if the local database directory is empty.
The downloaded snapshot is certified by the Mithril network.

## Architecture

The upstream [Mithril network
architecture](https://mithril.network/doc/mithril/mithril-network/architecture)
describes the protocol components. The Guild tooling additionally supports Squid-based
relays and an optional Nginx load balancer local to the signer. The Nginx sidecar can
distribute requests over multiple Squid relays running on the SPO's Cardano relay nodes.

### Single Relay Architecture

For SPOs with a single Cardano relay node, a Squid-based Mithril relay can run on that
node. The signer uses it to submit signatures to the Mithril aggregator.

![Single Cardano Relay](https://raw.githubusercontent.com/cardano-community/guild-operators/images/mithril_single_relay.png)

### Multi Relay Architecture

For SPOs with multiple Cardano relay nodes, an Nginx sidecar can run on the block
producer and load balance requests over those nodes, each of which runs a Squid Mithril
relay. This removes an individual Cardano relay as a single point of failure.

![Multi Cardano Relay](https://raw.githubusercontent.com/cardano-community/guild-operators/images/mithril_multi_relay.png)

## Installation

The installation of the Mithril tools is automated by `guild-deploy.sh`. For a cnode
deployment, include the `-s m` component flag. It installs the Mithril Client and Signer
binaries in `"${HOME}"/.local/bin` and installs the Guild wrapper scripts in the
selected node's `scripts` directory.

```bash
./guild-deploy.sh -i cnode -n mainnet -s m
```


### Bootstrapping a node using Mithril Client

The Mithril client is used to download a snapshot of the Cardano blockchain from a
Mithril Aggregator. The snapshot is then used to bootstrap a new Cardano node. The
Mithril client can be used to download the latest snapshot, list all available
snapshots, or show details of a specific snapshot.

To bootstrap a Cardano node using the Mithril client, follow these steps:

1. **Set up the Cardano node:** Use the Guild tools to set up the Cardano node, either by
building the binaries or using pre-compiled binaries. Follow the instructions in the
[cnode build documentation](../Build/cnode.md).

2. **Create the Mithril environment file:** Run the script with the `environment setup`
command. This will create a new `mithril.env` file with all the necessary environment
variables for the Mithril client.

   ```bash
   ./mithril-client.sh environment setup
   ```

   To override a value later, use:

   ```bash
   ./mithril-client.sh environment override <VARIABLE> <VALUE>
   ```

3. **Download the latest Mithril snapshot:** Once the environment file is set up, you
can download the latest Mithril snapshot by running the `cardano-db download` command.
This snapshot contains the latest certified state of the Cardano blockchain database
from a Mithril Aggregator.

   ```bash
   ./mithril-client.sh cardano-db download
   ```

4. **Download the Mithril snapshot without the ledger state (skip-ancillary):** This option downloads only the immutable db files. The ledger state will be computed from the genesis block when the Cardano node starts, which results in a longer bootstrap time.

   ```bash
   ./mithril-client.sh cardano-db download skip-ancillary
   ```

### Participating in the Mithril network

In the upstream production deployment model, the signer runs on the block
producer and sends traffic through a relay on a Cardano relay host. Consult the
upstream [signer deployment
guide](https://mithril.network/doc/manual/operate/run-signer-node/) before
deploying keys or services.

#### Deploy Squid Mithril relays

Run the relay installer on each Cardano relay host:

```bash
./mithril-relay.sh -d
```

The installer prompts for one or more permitted block-producer addresses,
optional additional permitted addresses, and a listening port (default
`3132`). It installs and restarts Squid. Restrict that port to the expected
block-producer address at the host or network firewall, then enable Squid at
boot:

```bash
sudo systemctl enable --now squid
```

#### Optional multi-relay load balancer

For multiple Squid relays, run the Nginx sidecar installer on the block
producer:

```bash
./mithril-relay.sh -l
```

Enter each relay address, the sidecar listen address (default `127.0.0.1`), and
the common relay port (default `3132`). The installer restarts Nginx; enable it
at boot:

```bash
sudo systemctl enable --now nginx
```

#### Configure and deploy the signer

On the block producer, generate or update `mithril.env`:

```bash
./mithril-signer.sh -e
```

For a single relay, provide that relay's address. For a multi-relay deployment,
provide the Nginx sidecar address, normally `127.0.0.1`. The command also asks
whether to expose signer metrics. On an upstream-supported testnet naive
deployment, answer `n` when asked whether a relay endpoint is used.

Install the component-owned systemd unit, then start it:

```bash
./mithril-signer.sh systemd install
sudo systemctl start cnode-mithril-signer
```

The installer enables the unit for boot but does not start it. The legacy
`./mithril-signer.sh -d` form remains an alias for `systemd install`.

Inspect or remove the Guild-owned unit with:

```bash
./mithril-signer.sh systemd status
./mithril-signer.sh systemd remove
```
