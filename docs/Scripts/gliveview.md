!!! info "Reminder !!"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

**Koios gLiveView** is a local terminal dashboard that complements remote
monitoring systems such as Prometheus/Grafana or Zabbix. It provides an
interactive view of a node that is especially useful when the node itself runs
as a background systemd service.

gLiveView is installed by the `cnode`, Dingo, and Amaru deployment profiles.
The common dashboard loads the adapter selected by
`${NODE_HOME}/.deployment.json`, normalizes that implementation's metrics, and
prints the implementation name in the header. A typical heading therefore
contains `[cardano-node]`, `[Dingo]`, or `[Amaru]` as well as the node name,
relay/core role, network, and version.

Each implementation exposes a different set of measurements. gLiveView
discovers availability on every scrape and displays only fields and sections
that the selected node actually supplied. An unavailable metric is not treated
as zero. This is particularly important for alternate relays, which do not
expose cnode block-production, KES, or peer-inspection interfaces and may
publish a different runtime metric set.

##### Metrics interface

| Implementation | Source used by gLiveView | Default local endpoint |
| --- | --- | --- |
| `cnode` / cardano-node | Native Prometheus endpoint configured in `config.json` | Usually `127.0.0.1:12798` |
| Dingo | Native Prometheus endpoint; network-labelled samples are normalized by the Dingo adapter | `http://127.0.0.1:12798/metrics` |
| Amaru | OTLP is received by the Guild-managed OpenTelemetry Collector and re-exported as Prometheus | OTLP `127.0.0.1:4317`/`4318`; Prometheus `http://127.0.0.1:8889/metrics` |

The Amaru `-s d` deployment installs both the pinned Amaru executable and the
pinned `otelcol-contrib` executable. `amaru.sh -d` installs the node unit and a
companion `<service-name>-metrics.service`; starting or stopping the launcher
controls both. OTLP traces and logs are accepted and discarded locally, while
metrics are exposed only on the loopback Prometheus endpoint. The shared
parser also normalizes Prometheus scientific notation, including the format
reported in [issue #1912](https://github.com/cardano-community/guild-operators/issues/1912).

##### Configuration & Startup

The adapter detects the selected implementation, process, endpoint, and
network settings. For cnode, set `CNODE_PORT` in `env` only when the node does
not use its configured default. Run the dashboard from
`${NODE_HOME}/scripts` after the node and its metrics endpoint are running:

```bash
cd "${NODE_HOME}/scripts"
./gLiveView.sh
```

For cnode, the script detects whether the node is a block producer or relay.
The current Guild Dingo and Amaru profiles are relay-only.

The `-b <branch>` option updates `${NODE_HOME}/.deployment.json`. The removed
`scripts/.env_branch` sidecar is no longer read or written.

The accepted startup options are:

```text
Usage: gLiveView.sh [-l] [-u] [-b <branch name>] [-v]

-l    Use standard ASCII instead of box-drawing characters
-u    Skip the script update check
-b    Persist an alternate Guild Operators branch in .deployment.json
-v    Print the gLiveView version
```

Legacy display mode can also be made persistent with `LEGACY_MODE=true` in
the script's User Variables section.

!!! info "Note !!"
    gLiveView is a compact local dashboard, not a full monitoring platform.
    Press `v` to show or hide additional available fields. The key is not a
    request to synthesize measurements the node does not export.

The screenshots below show the established cnode core, relay, and peer-analysis
views. Dingo and Amaru use the same outer dashboard but contain a compact,
availability-driven metric grid.

=== "Core"

    ![Core](https://raw.githubusercontent.com/cardano-community/guild-operators/images/glv-core.png ':size=35%')

=== "Relay"

    ![Relay](https://raw.githubusercontent.com/cardano-community/guild-operators/images/glv-relay.png ':size=35%')

=== "Peer Analysis"

    ![Peer-Analysis](https://raw.githubusercontent.com/cardano-community/guild-operators/images/glv-peers.png ':size=35%')

###### Upper main section

The dashboard can display epoch progress, chain, mempool, connection, block
propagation, and local process-resource measurements. cnode retains its
established full view. In the availability-driven Dingo and Amaru view, a
whole section is hidden when none of its metrics are available and unavailable
cells are omitted rather than printed empty or as zero.

- **Epoch Progress** - Epoch number and progress are live from the node. The
  progress bar is displayed only when epoch, epoch-slot, and epoch-length data
  are available.
- **Block** - The node's current block height since genesis.
- **Slot** - The node's current absolute slot.
- **Density** - With the current chain parameters(MainNet), a block is created roughly every 20 seconds(`activeSlotsCoeff`). A slot on MainNet happens every 1 second(`slotLength`), thus the max chain density can be calculated as `slotLength/activeSlotsCoeff = 5%`. Normally, the value should fluctuate around this value.  
- **Total Tx** - The total number of transactions processed since node start.  
- **Pending Tx** - The number of transactions and the bytes(total, in kb) currently in mempool to be included in upcoming blocks.  
- **Tip (ref)** - In the full cnode view, reference tip is an offline
  calculation based on genesis values. Dingo instead exports its native tip
  gap as an implementation metric.
- **Tip (diff) / Status** - Will either show node status as `starting|sync xx.x%` or if close to reference tip, the tip difference `Tip (ref) - Tip (node)` to see how far of the tip (diff value) the node is. With current parameters a slot diff up to 40 from reference tip is considered good but it should usually stay below 30. It's perfectly normal to see big differences in slots between blocks. It's the built in randomness at play. To see if a node is really healthy and staying on tip you would need to compare the tip between multiple nodes.  
- **Forks** - The number of forks since node start. Each fork means the blockchain evolved in a different direction, thereby discarding blocks. A high number of forks means there is a higher chance of orphaned blocks.  
- **Peers In / Out** - Shows the connection counters exported by the selected
  implementation. This does not imply that interactive peer inspection is
  available.
- **P2P Mode** 
  - `Cold` peers indicate the number of inactive but known peers to the node.
  - `Warm` peers tell how many established connections the node has.
  - `Hot` peers how many established connections are actually active.
  - `Bi-Dir`(bidirectional) and `Uni-Dir`(unidirectional) indicate how the handshake protocol negotiated the connection. The connection between p2p nodes will always be bidirectional, but it will be unidirectional between p2p nodes and non-p2p nodes. 
  - `Duplex` shows the connections that are actually used in both directions, only bidirectional connections have this potential.
- **Mem (RSS)** - RSS is the Resident Set Size for the selected node process.
  It is collected locally and does not include memory that has been swapped
  out.
- **Mem (Live) / (Heap)** - Runtime memory values are displayed only when the
  implementation exports compatible samples.
- **GC Minor / Major** - Collecting garbage from "Young space" is called a Minor GC. Major (Full) GC is done more rarily and is a more expensive operation. Explaining garbage collection is a topic outside the scope of this documentation and google is your friend for this.  
- **Block propagation** - Last Block measures the duration between when the last block was scheduled to be produced and when the node learned about it. Late blocks are blocks whose delay is larger than 5s. If the node is not synching, the number of late blocks needs to stay low. Within 1/3/5s estimates the chance of observing a delay of 1/3/5s (based on the delays observed for previous blocks). A healthy node needs to stay above 95% of blocks within 3s. Finally, served blocks counts how many blocks were fetched by "in" peers. If this does not increase for a long time, it means the "in" peers are learning about new blocks from somewhere else (and therefore this node is not contributing towards accelerating the propagation). Overall, these metrics are helpful in tweaking the topology and/or performance of the network links.  

###### Implementation metrics

Adapters may register useful measurements that have no common equivalent.
They are placed in a section named after the implementation and disappear
individually when not present in the latest scrape.

- Dingo currently reports its Go runtime version, native tip gap, epoch
  length, and Shelley start time.
- Amaru currently reports process CPU, resident and virtual memory, open file
  descriptors, and accepted/rejected mempool insertions.

###### Core section

The core section is cnode-only in the current deployment set. It is displayed
when the cnode adapter reports that forging is enabled. Dingo and Amaru are
deployed as relays and never receive this section.

- **KES period / expiration** - This section contain the current and remaining KES periods as well as a calculated date for the expiration. When getting close to expire date the values will change color.  
- **Missed slot checks** - A value that show if the node have missed slots for attempting leadership checks (as absolute value and percentage since node startup).  
  !!! info "Missed Slot Leadership Check"  
      
      Note that while this counter should ideally be close to zero, you would often see a higher value if the node is busy (e.g. paused for garbage collection or busy with reward calculations). A consistently high percentage of missed slots would need further investigation (assistance for troubleshooting can be seeked [here](https://t.me/CardanoStakePoolWorkgroup) ), as in extremely remote cases - it can overlap with a slot that your node could be a leader for.

- **Blocks** - If [CNCLI](cncli.md) is activated to store blocks created in a blocklog DB, data from this blocklog is displayed. See linked CNCLI documentation for details regarding the different block metrics. If CNCLI is not deployed, block metrics displayed are taken from node metrics and show blocks created by the node since node start.

###### Peer analysis

A manual peer analysis can be triggered with `p` only when the adapter exposes
the `peer_inspection` capability. That capability is currently cnode-only, so
the key and footer entry are hidden for Dingo and Amaru. Prometheus connection
counters may still be visible for those implementations.

!!! warning "Note"
    Note that with P2P enabled, an incoming/outgoing connection can be reused for bi-directional traffic. There isnt a way to distinctly identify the P2P peer's direction yet for a given IP.

For each peer, the configured latency methods are attempted in
`LATENCY_TOOLS` order:

1. `cncli` measures the Cardano handshake, or only its TCP connect phase when
   `CNCLI_CONNECT_ONLY=true`.
2. `ss` reads the RTT reported for an already-established socket.
3. `tcptraceroute` probes the peer's TCP port.
4. `ping` falls back to ICMP.

Methods that need the remote node's listening port may not work for an
incoming connection whose observed remote port is ephemeral. ICMP may also be
blocked by the peer's firewall, so an undetermined latency does not by itself
mean the connection is unhealthy.

Once the analysis is finished, it will display the RTTs (return-trip times) for the peers and group them in ranges 0-50, 50-100, 100-200, 200<. The analysis is **NOT** live. Press `[h] Home` to go back to default view or `[i] Info` to show in-script help text. `Up` and `Down` arrow keys is used to select incoming or outgoing detailed list of IPs and their RTT value. `Left (<)` and `Right (>)` arrow keys can be used to navigate the pages in the selected list.

##### Troubleshooting/Customisations

gLiveView treats node-process discovery and metric collection separately. If
either fails, it reports which one is unavailable and retries according to
`RETRIES`; it does not continue rendering stale samples.

Check the selected implementation's local endpoint:

```bash
# Dingo
curl --fail http://127.0.0.1:12798/metrics

# Amaru's managed Prometheus bridge
curl --fail http://127.0.0.1:8889/metrics

# Amaru host deployment: inspect both units
"${NODE_HOME}/scripts/amaru.sh" status
```

For Amaru, a healthy node without port 8889 normally means the companion
metrics unit or collector configuration needs attention. The OTLP receiver and
Prometheus bridge bind only to loopback. For Dingo, the upstream metrics
listener shares Dingo's public bind address; protect TCP 12798 with the host or
network firewall even though gLiveView connects through loopback.

If automatic detection is incorrect, review `env` and the User Variables
section of `gLiveView.sh`. Please also report reproducible adapter or display
problems through the [Guild Operators issue
tracker](https://github.com/cardano-community/guild-operators/issues).

**gLiveView.sh**
```bash
######################################
# User Variables - Change as desired #
######################################

#NODE_NAME="Cardano Node"                 # Prefix, at most 19 characters
#REFRESH_RATE=2                           # Seconds between data refreshes
#REPAINT_RATE=10                          # Full repaint after this many refreshes
#LEGACY_MODE=false                        # true uses ASCII instead of box drawing
#RETRIES=3                                # Connection attempts; 0 retries continuously
#PEER_LIST_CNT=10                         # Peers shown per in/out analysis page
#THEME="dark"                             # dark | light
#ENABLE_IP_GEOLOCATION=Y                  # Query geolocation for peer IPs
#LATENCY_TOOLS="cncli|ss|tcptraceroute|ping"
#CNCLI_CONNECT_ONLY=false                 # true measures connect only; false measures the full handshake
#HIDE_DUPLICATE_IPS=N                     # Y filters duplicate and local IPs
#VERBOSE=N                                # Y starts with additional metrics visible
#GLV_LOG="${LOG_DIR}/gLiveView.log"       # Empty disables the error log
```
