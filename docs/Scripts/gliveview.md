!!! info "Prerequisites"
    Complete the [Guild Operators prerequisites](../basics.md#pre-requisites)
    before using gLiveView.

**Koios gLiveView** is a local terminal dashboard for `cardano-node`, Dingo,
and Amaru. It complements durable remote monitoring such as
Prometheus/Grafana or Zabbix; it is not a replacement for alerting or
historical dashboards.

The same `gLiveView.sh` is installed for every node implementation. It reads
`${NODE_HOME}/.deployment.json`, loads the selected adapter, and displays the
implementation explicitly in the header as `[cardano-node]`, `[Dingo]`, or
`[Amaru]`. The adapter translates native telemetry into a common metric
contract and may add implementation-specific fields.

This guide deliberately uses field-reference tables instead of dashboard
screenshots. A screenshot becomes inaccurate whenever a field, upstream
metric, terminal width, or compact/verbose rule changes; the tables below
describe the current interface directly.

## Metric sources

| Implementation | Source read by gLiveView | Default endpoint |
| --- | --- | --- |
| `cnode` / cardano-node | Native Prometheus endpoint configured by cardano-node | Usually `http://127.0.0.1:12798/metrics` |
| Dingo | Native Prometheus endpoint, including Dingo's cardano-node-compatible metric names | `http://127.0.0.1:12798/metrics` |
| Amaru | Amaru OTLP telemetry exported through the locally managed OpenTelemetry Collector Prometheus bridge | OTLP/gRPC `127.0.0.1:4317`; Prometheus `http://127.0.0.1:8889/metrics` |

Amaru itself does not expose the Prometheus listener used by gLiveView.
`amaru.sh -d` installs both the node unit and the companion
`<service-name>-metrics.service`. The Guild collector configuration follows
Amaru's reference bridge metric-name contract, expires stale series, and
keeps its OTLP/gRPC receiver and Prometheus exporter on loopback.

## Start gLiveView

Run gLiveView after the node process and its metrics endpoint are available:

```bash
cd "${NODE_HOME}/scripts"
./gLiveView.sh
```

The adapter normally discovers the implementation, process, network, socket,
and metrics endpoint. For a customized cnode deployment, set `CNODE_PORT` or
the relevant endpoint override in `env`. Dingo and Amaru use their
implementation-specific deployment settings by default.

The startup options are:

```text
Usage: gLiveView.sh [-l] [-u] [-b <branch name>] [-v]

-l    Use standard ASCII instead of box-drawing characters
-u    Skip the script update check
-b    Persist a Guild Operators branch in .deployment.json
-v    Print the gLiveView version
```

## Dashboard controls

| Key | Action | Availability |
| --- | --- | --- |
| `v` | Toggle compact and verbose metrics | All implementations |
| `n` | Open static node, network, and deployment information | All implementations |
| `i` | Open the concise built-in field guide | All implementations |
| `p` | Run one-shot peer analysis | cnode only |
| `h` | Return to the main dashboard | Information, Network, and peer views |
| `q` or `Esc` | Exit | All views |

Compact mode contains the main operational signals. Verbose mode adds detailed
connection states, propagation history, runtime metrics, implementation-native
measurements, and additional producer counters. A field is shown only when its
adapter marks the current sample as available. An absent field therefore means
"not exported or not available in this scrape," not zero.

## Header and epoch

| Field | Meaning |
| --- | --- |
| Implementation | The active adapter and node implementation. This should agree with `.deployment.json`. |
| Role | `Relay` or `Core`. cnode and Dingo derive producer mode from the live forging metric; Amaru is currently relay-only. |
| Network | The configured Cardano network. |
| Version | Version reported by the running process or its build metric. The Network page can also show the source revision. |
| Uptime | Elapsed time for the current node process, not host uptime. The adapters use a trustworthy native start value or local process timing. |
| Port | The node-to-node listening port, not the metrics port. |
| Epoch and progress | Epoch number and the latest locally processed slot's position within that epoch. The bar is local ledger progress through the epoch, not network synchronization progress. |
| ALERT | Shown only while the node reports a condition that needs operator action, such as a halted or stuck ledger, the operator's own pool equivocating, or invalid forging keys. Several conditions are listed together, most severe first. |
| SYNC | Shown only while the node reports bootstrap or catch-up progress, such as Dingo's Mithril download or ledger import, or cardano-node's ledger replay after a restart, with its percentage, rate, and a progress bar. |

## Common live sections

The following labels form the shared dashboard vocabulary. Each
implementation can expose a different subset.

### Chain

| Label | Meaning | How to read it |
| --- | --- | --- |
| Block | Block height of the node's currently selected local chain. | It should increase while the node is following the chain. |
| Slot | Absolute Cardano slot at the local tip. | This is not the slot within the current epoch. |
| Tip gap | Slots between the expected wall-clock slot and the local tip. Dingo's native value is preferred; otherwise gLiveView derives it from network timing. | Lower is better. It naturally rises between blocks and is not a peer-observed reference tip or a complete sync percentage. |
| Epoch slot | Slot position within the current epoch. | Used with epoch length to draw the epoch progress bar. |
| Density | Recent chain density reported by the node, displayed as a percentage. | On networks with `activeSlotsCoeff=0.05`, a value around 5% is expected over a representative window; short windows fluctuate. |
| Forks | Fork events reported by the node. | A rising counter means the node has observed competing chain selections. The exact counter lifetime follows the node process. |
| Total tx | Transactions processed or moved out of the mempool, as defined by the implementation's compatibility metric. | Normally cumulative for the current process. It is not the transaction count of the whole blockchain. |
| Pending tx | Transactions currently held in the mempool. | A point-in-time count. |
| Mempool | Current serialized mempool size. | Displayed with a bounded binary byte unit such as KiB or MiB. |

When a node is still bootstrapping or replaying its database, chain fields can
lag far behind wall-clock time. cardano-node exports no tip while it replays
its ledger at startup, so gLiveView reads the replay progress from the node's
systemd journal instead. Relays show it as a `SYNC: Ledger replay` row with a
progress bar, and cnode block producers as `DB Replay` in place of the tip
gap. This needs the node to run as its systemd service and gLiveView to be able
to read that service's log. Running gLiveView as the node's own user is enough
when the journal is stored on disk (`/var/log/journal`). Any other user, or any
user on a host that keeps the journal only in memory, needs to be in the
`systemd-journal` or `adm` group. Without that access a producer shows
`Status: starting` until the replay ends.

### Connections

| Label | Mode | Meaning |
| --- | --- | --- |
| Incoming | Compact | Current inbound connections reported by the connection manager. |
| Total | Compact | Established node-to-node sessions owned by the node process, shown when an implementation exports no connection-manager counters (currently Amaru). Loopback telemetry sessions are excluded; inbound and outbound sessions cannot be told apart. |
| Outgoing | Compact | Current outbound connections reported by the connection manager. |
| Duplex | Compact | Connections actively used in both directions. |
| Known | Compact | Peers known to the peer-selection subsystem. |
| Established | Compact | Known peers with an established bearer. |
| Active | Compact | Established peers currently selected for active protocol use. |
| In hot | Compact and verbose | Inbound peers in the hot/active governor state. |
| Out hot | Compact and verbose | Outbound peers in the hot/active selection state. |
| Uni-dir | Verbose | Connections negotiated as unidirectional. |
| Bi-dir | Verbose | Connections negotiated as bidirectional and therefore capable of duplex use. |
| In warm | Verbose | Established inbound peers not currently hot. |
| Out cold | Verbose | Known outbound peers without an established connection. |
| Out warm | Verbose | Established outbound peers not currently hot. |

Connection counts and peer-set counts are related but not interchangeable. A
peer can own more than one protocol connection, and direction counters do not
grant gLiveView permission to inspect peer addresses. Detailed peer analysis
is a separate cnode-only capability.

### Block propagation

| Label | Mode | Meaning |
| --- | --- | --- |
| Last block | Compact | Latest block-fetch delay reported by the node, in seconds. |
| Served | Verbose | Blocks served to peers by the node during the metric's lifetime. |
| Late (>5s) | Verbose | Observed blocks whose reported fetch delay exceeded five seconds. |
| Within 1s | Verbose | Share of observed block delays at or below one second. |
| Within 3s | Verbose | Share of observed block delays at or below three seconds. |
| Within 5s | Verbose | Share of observed block delays at or below five seconds. |

The `Within` values are cumulative-distribution estimates, not three separate
block counts. A topology with consistently low delay and a high share within
three seconds is generally preferable, but block production randomness,
temporary network congestion, and a node that is still syncing can distort
short observations. Not every implementation currently exports every
propagation field. For Amaru, gLiveView derives these values itself from the
latest block timings; see [Amaru](#amaru).

### Node resource usage

| Label | Meaning |
| --- | --- |
| CPU (sys) | CPU utilization calculated from the local node process. It is intended as a host-level operational signal and can differ from a node's own runtime CPU gauge. |
| Mem (RSS) | Resident Set Size of the node process: memory currently mapped into physical RAM. It excludes swapped-out pages. |
| Disk util | Percentage of capacity used on the filesystem containing `NODE_HOME`. It is not disk I/O busy time. |

These three measurements are collected locally, so they remain useful when an
implementation does not publish equivalent runtime telemetry.

### Runtime

The Runtime section appears in verbose mode and only includes exported
fields.

| Label | Meaning |
| --- | --- |
| Live memory | Bytes classified by the implementation's compatibility metric as live runtime data. |
| Heap | Bytes allocated to the managed runtime heap. |
| GC minor | Minor or young-generation garbage collections since the runtime metric was initialized. |
| GC major | Major or full garbage collections since the runtime metric was initialized. |
| Open files | File descriptors currently open by the node process. |
| Max files | Process file-descriptor limit reported by the runtime. |

Live/heap and minor/major GC terminology originates with cardano-node's
Haskell RTS metrics. Dingo exports compatible fields but their implementation
still follows Dingo's Go runtime. Compare trends within one implementation;
do not assume the raw values have identical runtime semantics across languages.

## Node-specific metrics

### cardano-node / cnode

cnode supplies the original cardano-node compatibility metrics used by the
common sections. A cnode relay uses the availability-driven common layout. A
cnode producer retains an extended layout because it can combine live node
metrics with its operational certificate, Koios pool data, CNCLI blocklog,
and optional Mithril signer.

For cnode, `Live memory`, `Heap`, `GC minor`, and `GC major` come directly from
the Haskell RTS compatibility gauges. A widening live-versus-heap gap is not
automatically a fault, but sustained heap growth, frequent major collections,
or swapping should be investigated together with CPU and missed leadership
checks.

#### cnode producer: core information

| Label | Meaning |
| --- | --- |
| KES current / remaining / exp | Current KES period, remaining periods accepted by the operational certificate, and the calculated expiry time. Warning colors become stronger near expiry. |
| OP Cert disk / chain | Operational-certificate issue counter from the file on disk and the latest counter observed on chain. The disk counter is normally equal to the chain counter or one greater before the next block is adopted. |
| Missed slot leader checks | Leadership checks the node could not perform, plus their percentage of total scheduled checks. Shown in verbose mode. Sustained growth can indicate CPU, I/O, GC, or timekeeping pressure. |

When a pool ID and Koios are configured, the Core section can also show:

| Label | Meaning |
| --- | --- |
| Blocks | Pool blocks reported by Koios. |
| Act Stake | Stake active for the current epoch. |
| Pledge | Declared pool pledge. |
| Fixed Fee | Pool fixed cost. |
| Live Stake | Current live delegated stake. |
| Live Pledge | Current live stake supplied by the owners; highlighted when below declared pledge. |
| Margin Fee | Pool margin percentage. |
| Delegators | Current live delegator count. |
| Saturation | Current live saturation percentage. |

Koios pool values are cached and refreshed separately from the two-second node
scrape, so they should not be interpreted as instantaneous Prometheus gauges.

#### cnode producer: block production

Without a CNCLI blocklog, gLiveView shows the node's process-lifetime `Leader`,
`Adopted`, and non-adopted/`Invalid` counters.

With a CNCLI blocklog, the current epoch can show:

| Label | Mode | Meaning |
| --- | --- | --- |
| Leader | Compact | Total scheduled leader slots known to CNCLI for the epoch. |
| Ideal | Compact | Statistically expected leader slots from active stake. |
| Luck | Compact | Assigned leader slots relative to the ideal value. |
| Adopted | Compact | Blocks created by the node and retained by CNCLI's blocklog status calculation. |
| Confirmed | Compact | Created blocks confirmed on the canonical chain. |
| Lost | Compact | Combined invalid, missed, ghosted, and stolen outcomes. |
| Invalid | Verbose | The node attempted but failed to create a valid block. |
| Missed | Verbose | A scheduled slot has no local block record and no competing canonical block. |
| Ghosted | Verbose | A local block became orphaned without another pool owning the canonical block at that slot, often indicating a height battle or propagation issue. |
| Stolen | Verbose | Another pool has the canonical block for the same slot. |
| Next block | When available | Countdown to the next CNCLI leader slot. This is sensitive operational information; control who can view the terminal. |

See [CNCLI](cncli.md) for blocklog collection and validation details.

#### cnode optional Mithril signer

When `MITHRIL_SIGNER_ENABLED=Y` and the signer endpoint is available, gLiveView
can display:

| Label | Meaning |
| --- | --- |
| Status | systemd state of the signer service. |
| Registered Epoch | Successful signer registration in the latest epoch metric. |
| Cycles | Signer runtime cycles since startup. |
| Signing in Epoch | Successful signature registrations in the latest epoch. |
| Signatures / Total Signatures | Successful and total signature registration attempts since startup. |
| Registered / Registered Total | Successful and total signer registration attempts since startup; the additional row is shown in verbose mode. |

### Dingo

Dingo exposes the cardano-node-compatible family used by the common Chain,
Connections, Block Propagation, Runtime, and Block Production sections. It
also contributes native fields to the verbose `DINGO METRICS` section, the
ALERT and SYNC rows, and the Network page. Dingo has no terminal dashboard of
its own; these fields follow what its upstream Grafana dashboards and alert
rules treat as the primary operational signals.

Dingo's outbound peer-temperature gauges also count peers that connected
inbound. gLiveView subtracts those inbound peers so that `Out cold`, `Out
warm`, and `Out hot` describe only outbound selection; the inbound peers remain
visible as `In warm` and `In hot`.

`Live memory` is Go's `runtime.MemStats.HeapAlloc` and `Heap` is `HeapSys`.
Go's collector is not generational, so the Haskell `GC minor` and `GC major`
fields stay hidden and the total collection count appears as `GC cycles`
instead. Do not compare these values numerically with cnode's Haskell RTS
values as if the runtimes were identical.

| Label | Meaning |
| --- | --- |
| Goroutines | Current Go goroutine count. |
| GC cycles | Completed Go garbage collections since the process started. |
| DB size | Sum of Dingo's exported database-store size gauges, displayed with a binary byte unit. |
| UTxO hits | Cumulative hot UTxO CBOR-cache hits divided by hits plus misses. `n/a` means no cache observations exist yet. |
| Block hits | Cumulative block-LRU cache hits divided by hits plus misses. `n/a` means no cache observations exist yet. |
| Mempool | Current mempool size as a share of its configured capacity. |
| Adopt avg | Mean time from a block's slot to its adoption as the local tip, since the process started. Unlike `Last block`, it includes validation and commit. |
| Slot batls | Producer only. Competing blocks detected at the same slot. |
| Sync skips | Producer only. Leader slots skipped because an upstream tip was ahead of the local tip. |
| Tip skips | Producer only. Leader slots skipped because the local chain was stale or unsafe to extend. |
| Forge avg | Producer only. Mean time from slot start until a forged block was built. |
| Valid fail | Forged blocks dropped because self-validation failed. Hidden while zero. |
| Slot clock | Errors while reading the slot clock for forging. Hidden while zero. |
| Hot short | Hot peers missing below the configured minimum. Hidden while zero. |
| Pipe rstrt | Ledger pipeline restarts without tip progress, an early sign of a stuck ledger. Hidden while zero. |
| Snap fail | Failed stake-snapshot captures. Hidden while zero. |
| Gov decode | Stored governance proposals whose CBOR could not be decoded during ratifiability checks. Hidden while zero. |
| Rollback | Unrecoverable rollbacks. This can indicate local-chain divergence that requires investigation or a fresh bootstrap. Hidden while zero. |
| At-tip err | At-tip recovery attempts that did not converge. Hidden while zero. |
| Replay err | Replay recovery attempts that made no forward progress. Hidden while zero. |
| Mithril fb | Fallbacks from node-managed Mithril sync to Ouroboros sync. Hidden while zero. |

The ALERT row reports, most severe first: a halted ledger pipeline, the
operator's own pool equivocating, invalid forging credentials on a producer,
a stuck ledger pipeline, skipped epoch reward rounds, a stuck or waiting
Mithril restore, and Mithril sync errors.

While `dingo.sh bootstrap` runs, the bootstrap process serves only its Mithril
progress metrics on the same endpoint. gLiveView then shows a SYNC row with
the active phase (download, block copy, the ledger stage being imported, gap
blocks, or finalising), its percentage and rate, and takes the version from the
installed binary. A node started with `mithril.enabled` reports `Mithril
restore` or `Mithril catch-up` in the same row.

Dingo producer mode also uses the shared Block Production section:

| Label | Mode | Meaning |
| --- | --- | --- |
| KES current | Compact | Current network KES period. |
| KES remaining | Compact | Remaining usable KES periods for the loaded operational certificate. |
| KES expires | Compact | Expiry time calculated from KES and network timing. |
| Keys valid | Compact | `yes` while the loaded credentials can sign at the current slot; `NO` raises an alert. |
| Scheduled / Next sched | Compact | Leader slots in Dingo's latest computed schedule, for the current or the next epoch. |
| Leader slots | Compact | Slots in which Dingo was elected leader and passed its pre-forging checks. |
| Adopted | Compact | Forged blocks adopted onto the chain. |
| Not adopted | Compact | Forged blocks minus adopted blocks. |
| Lost slots | Compact | Leader slots that did not end with this pool's block adopted, whether refused, failed, or lost in a slot battle. |
| OpCert # | Verbose | Operational certificate counter loaded from disk and recorded on chain. It turns red unless the disk counter equals the chain counter or exceeds it by one. The chain value appears after the pool's first block. |
| Leader checks | Verbose | Slots that reached the "about to lead" forging check. |
| Not leader | Verbose | Checked slots where the pool was not elected. |
| Forge failed | Verbose | Slots where forging failed because of sync state, block construction, or another reported error. |
| OpCert starts / expires | Verbose | Operational certificate's starting and ending KES-period bounds. |

Dingo has no counter for missed leadership checks, so `Missed checks` stays
hidden.

Static Dingo values are kept off the live dashboard. Its Go runtime version
and processor count, native epoch length, Shelley start time, KES period
length, mempool implementation and capacity, and latest stake snapshot appear
on the Network page. Dingo is a rolling-release profile, so a newly published
build can temporarily omit an optional field; the adapter evaluates each field
on every scrape.

### Amaru

Amaru's reference bridge supplies a cardano-node-compatible subset for the
common chain, mempool, served-block, and build fields. Amaru is relay-only in
Guild Operators, so it has no Block Production section; its network-derived
KES period is listed on the Network page instead.

Amaru's own terminal dashboard runs inside the node process and is therefore
only available when `amaru.sh run` is started from an interactive terminal.
Under systemd, gLiveView shows the same node, chain, mempool, resource, and
block-timing data that Amaru exports as metrics. Its per-peer table, peer-set
sizes, round-trip times, protocol version, and stake and governance views are
produced from in-process traces and are not exported, so gLiveView cannot show
them.

Amaru exports no connection-manager counters. gLiveView counts the node
process's established TCP sessions as `Total` in the Connections section.

Block propagation is derived from Amaru's timing histograms. For each new
block, `Last block` is the time from the start of its slot until the block was
received: the header delay, the wait before fetching, and the fetch itself.
The `Within` shares cover the live blocks observed while gLiveView has been
running, up to the latest 100, so they start empty and are not node-lifetime
figures. Values disappear when no block has arrived for 10 minutes.

The verbose `AMARU METRICS` section contains:

| Label | Meaning |
| --- | --- |
| Proc CPU | Amaru's own current process CPU gauge. It can differ slightly from gLiveView's locally sampled `CPU (sys)`. |
| Disk rd/s | Bytes read by Amaru per second, displayed with a binary byte unit. |
| Disk wr/s | Bytes written by Amaru per second, displayed with a binary byte unit. |
| Tx accept | Transaction insertions accepted into the mempool, summed across local and remote origins. |
| Tx reject | Transaction insertions rejected as invalid, duplicate, or because the mempool was full. |
| Pool sync | Latest time in milliseconds to revalidate the mempool after block adoption. |
| Hdr delay | Latest time from slot start until a valid header arrived. Recorded only once Amaru follows the tip. |
| Fetch wait | Latest time from receiving a valid header until its block was requested. |
| Fetch time | Latest time from requesting a block until receiving it. |
| Forward | Latest time from receiving a valid header until its block was adopted. |
| Hdr reject | Invalid blocks plus headers that were invalid, undecodable, or failed to store. Duplicate and pruned headers are not included. |

The millisecond timings are the mean of the blocks received since the
previous refresh, which is normally one block, rather than an average since
the process started. `Forks` in the Chain section counts only fork switches
that changed the selected chain.

`Open files` and `Max files` appear in the shared Runtime section. Uptime is
calculated from the active Amaru service PID using Linux's monotonic process
start time, with a bounded `ps` fallback; collector runtime telemetry is not
presented as Amaru node telemetry. The Network page adds the build platform,
host memory, and the current KES period.

Amaru releases evolve quickly. The tables document the current adapter
contract, but gLiveView displays a native metric only when the running release
actually exports the required series.

## Network page

Press `n` to separate relatively static information from live operational
measurements.

| Section | Fields |
| --- | --- |
| Node | Implementation, version and revision, role, service name |
| Network | Network name, network magic, node port, epoch length, slot length, active-slots coefficient, Shelley start time |
| Node Runtime | Adapter-supplied static runtime metadata, such as Dingo's Go runtime and stake snapshot or Amaru's build platform and host memory |
| Deployment | Node home, implementation configuration, node socket when applicable, metrics provider, metrics endpoint |

Long values are clipped to the fixed terminal cell and end in `~`. Large
integer values are compacted where appropriate. These display limits do not
alter the underlying metric.

## Peer analysis: cnode only

Press `p` when using cnode to run a one-shot latency analysis. This view is not
live and is not available to Dingo or Amaru, even when their dashboards show
aggregate connection metrics.

Latency methods are attempted in `LATENCY_TOOLS` order:

1. `ss` reads the RTT the kernel measures on the established connection. It
   is instant, sends no traffic, and works for inbound and outbound peers.
2. `cncli` times a Cardano handshake on a new connection, or only its TCP
   connection phase when `CNCLI_CONNECT_ONLY=true`. It is slower, and an
   inbound peer's ephemeral port usually makes it wait for its timeout.
3. `tcptraceroute` probes the peer's Cardano TCP port.
4. `ping` falls back to ICMP.

`ss` measures the TCP round trip on the link the node already uses, so it is
usually a little lower than a handshake measured by `cncli`. Put `cncli` first
in `LATENCY_TOOLS` to measure handshakes instead.

Incoming connections often use an ephemeral remote port, so TCP methods that
need the peer's listening port may not apply. ICMP may also be blocked. An
undetermined peer therefore does not by itself mean the connection is broken.

The result groups round-trip times into 0-50, 50-100, 100-200, and over 200 ms.
An RTT below one millisecond, typical for a peer in the same data centre, shows
as `<1`. Left/Right changes pages.

With `ENABLE_IP_GEOLOCATION=Y`, every public peer address is looked up at
ip-api.com, 100 addresses per request, and the results are cached next to the
script in `gLiveView.sh.geodb`.

When [openBlockPerf](https://github.com/cardano-foundation/openblockperf)
runs with its local endpoint enabled and has seen peers, the peer list shows
two more columns:

- `CONN` says how the node uses the connection, as its connection manager
  counts it: `out` when the node fetches from the peer, `in` when the peer
  fetches from the node, and `dup` when both happen over the same duplex
  connection. The letter after it is the hot (`H`), warm (`W`) or cold (`C`)
  state; `dup` shows the node's side first, then the peer's. openBlockPerf
  records temporary remote ports as 0, so several inbound connections from one
  address share a value. The cell is empty for a connection openBlockPerf has
  not seen.
- `SCORE` says how useful the peer was for receiving blocks over the last 30
  minutes. A peer earns 10, 5 or 3 points for being the first, second or third
  to announce a block header, and 10 points for each block body it serves. The
  cell is empty when the peer delivered nothing first in that window, which is
  normal for most peers: only the node's hot upstream peers deliver blocks.

Both reset when openBlockPerf restarts.

A filter row at the top of the view then narrows the list, the RTT ranges and
the average:

| Key | Filter | Choices |
| --- | --- | --- |
| `d` | Direction | All, Out, In, Duplex. Out and In include duplex connections, as the node's connection counters do. |
| `s` | State | Any, Hot, Warm. The state on the chosen direction's side, or the hotter side for All and Duplex. |

Each key cycles through its choices, and the active ones are highlighted.

`guild-deploy.sh -s r` enables the endpoint by adding
`"local_metrics_enabled": true` to `/opt/cardano/openblockperf/config.json`,
unless that key is already set. It listens on `127.0.0.1:14041`; if you
change `local_metrics_bind` or `local_metrics_port`, set
`OPENBLOCKPERF_METRICS_URL` to match. `ENABLE_OPENBLOCKPERF=N` hides both
columns.

## Refresh behavior

At each `REFRESH_RATE`, gLiveView builds a complete logical frame but writes
only terminal rows whose content changed. Every `REPAINT_RATE`, it reconciles
all rows through the same row-update mechanism without clearing the terminal.
This reduces blinking while removing stale text when values shrink or sections
appear or disappear. Changing views or resizing the terminal can require a
complete layout redraw.

## Troubleshooting

gLiveView treats node-process discovery and metric collection separately. If
either fails, it reports which dependency is unavailable and retries according
to `RETRIES`; it does not intentionally continue rendering a stale scrape.

Check the implementation's endpoint directly:

```bash
# cnode or Dingo, with the default port
curl --fail http://127.0.0.1:12798/metrics

# Amaru's local bridge
curl --fail http://127.0.0.1:8889/metrics

# Amaru: inspect both node and collector units
"${NODE_HOME}/scripts/amaru.sh" status
```

For Amaru, a healthy node without port 8889 normally means the collector unit
or configuration needs attention. Dingo binds its metrics listener to
`metricsBindAddr`, loopback in the Guild profile. If you set
`DINGO_METRICS_AUTH_TOKEN` in `dingo.env`, gLiveView sends it automatically;
add `-H "Authorization: Bearer <token>"` to the `curl` check above.

If automatic discovery is wrong, review `env`, the implementation environment,
and the User Variables section of `gLiveView.sh`. Report reproducible adapter
or rendering problems through the [Guild Operators issue
tracker](https://github.com/cardano-community/guild-operators/issues).

## User variables

```bash
######################################
# User Variables - Change as desired #
######################################

#NODE_NAME="Cardano Node"                 # Prefix, at most 19 characters
#REFRESH_RATE=2                           # Seconds between metric refreshes
#REPAINT_RATE=10                          # Seconds between row reconciliations
#LEGACY_MODE=false                        # true uses ASCII borders
#RETRIES=3                                # Attempts; 0 retries continuously
#PEER_LIST_CNT=10                         # Peers per cnode analysis page
#THEME="dark"                             # dark | light
#ENABLE_IP_GEOLOCATION=Y                  # Geolocate peer addresses
#LATENCY_TOOLS="ss|cncli|tcptraceroute|ping"
#CNCLI_CONNECT_ONLY=false                 # false performs full handshake
#HIDE_DUPLICATE_IPS=N                     # Filter duplicate/local peer IPs
#ENABLE_OPENBLOCKPERF=Y                   # Show openBlockPerf peer columns
#OPENBLOCKPERF_METRICS_URL="http://127.0.0.1:14041"
#VERBOSE=N                                # Y starts in verbose mode
#GLV_LOG="${LOG_DIR}/gLiveView.log"       # Empty disables the error log
```

## Upstream metric references

- [cardano-node monitoring and metrics](https://developers.cardano.org/docs/operate-a-stake-pool/node-monitoring/)
- [Dingo forging metric definitions](https://github.com/blinklabs-io/dingo/blob/main/ledger/forging/metrics.go)
- [Dingo ledger metric definitions](https://github.com/blinklabs-io/dingo/blob/main/ledger/metrics.go)
- [Amaru consensus metric definitions](https://github.com/pragma-org/amaru/blob/main/crates/amaru-metrics/src/consensus.rs)
- [Amaru system metric definitions](https://github.com/pragma-org/amaru/blob/main/crates/amaru-metrics/src/system.rs)
- [Amaru mempool metric definitions](https://github.com/pragma-org/amaru/blob/main/crates/amaru-metrics/src/mempool.rs)
