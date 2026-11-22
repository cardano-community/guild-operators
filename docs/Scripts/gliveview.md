!!! info "Prerequisites"
    Complete the [Guild Operators prerequisites](../basics.md#pre-requisites)
    before using gLiveView.

**Koios gLiveView** is a local terminal dashboard for `cardano-node`, Dingo,
and Amaru. It complements durable remote monitoring such as
Prometheus/Grafana or Zabbix; it is not a replacement for alerting or
historical dashboards.

The same `gLiveView.sh` is installed for every node implementation. It reads
`${NODE_HOME}/.deployment.json`, loads the selected adapter, and names the
implementation, its version, the network and the node's role at the top of the
left-hand rail. The adapter translates native telemetry into a common metric
contract and may add implementation-specific fields. A figure is shown only
when the adapter marks the current sample as available, so an absent figure
means "not exported or not available in this scrape", not zero.

gLiveView is written in bash. [gum](https://github.com/charmbracelet/gum), the
tool CNTools uses for its menus, draws the command list and the text prompts.
Without gum the dashboard still runs; the command list is then left out and
prompts are read on the last row.

This guide deliberately uses reference tables instead of dashboard
screenshots. A screenshot becomes inaccurate whenever a field, upstream
metric or terminal size changes. The dashboard also explains itself: press
`?` on any page.

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

Run gLiveView at any time. While the node is stopped, failed or still starting,
it says so, and follows the node until it reports its tip:

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
Usage: gLiveView.sh [-u] [-b <branch name>] [-t <theme>] [-c <colours>] [-d] [-v]

-u    Skip the script update check
-b    Persist a Guild Operators branch in .deployment.json
-t    Colour theme: default or hydra-after-dark
-c    Colour depth: truecolor, 256 or none
-d    Show frame and collection times in the footer
-v    Print the gLiveView version
```

`-l`, which selected ASCII borders in gLiveView 1, is still accepted and has no
effect.

Colours are 24-bit when `COLORTERM` announces that the terminal supports them,
and otherwise the closest colours of the 256-colour palette. `ssh` and `su` do
not pass `COLORTERM` on, so over a remote session you usually get 256 colours
unless you ask for `-c truecolor` or set `GLV_COLORS`. The theme follows the
one chosen in CNTools unless `-t` or `GLV_THEME` says otherwise.

## Pages and keys

The rail on the left lists the pages. The footer always shows the keys that
work where you are.

| Key | Page | What it shows |
| --- | --- | --- |
| `1` | Overview | Epoch, chain, propagation, peers, resources, block production on a producer, and the recent blocks |
| `2` | Chain | Tip figures, traffic, how block delays are spread, and the full block list |
| `3` | Peers | Peer and connection counts, round trips, and every connection of the node. See [Peer analysis](#peer-analysis) |
| `4` | Production | Keys, this epoch's results, the pool as Koios sees it, the leader schedule and the pool's epoch history. A relay shows a note instead |
| `5` | System | The host beside the node process, and the node's own metrics |
| `6` | Logs | The node's journal, with pause, find and a level filter |
| `n` | Node & network | What is running, how it was started, the network constants and the protocol parameters |
| `!` | Notices | What needs attention now, and every event since gLiveView started. See [Notices](#notices) |

| Key | Action |
| --- | --- |
| `↑` `↓` | Previous and next page |
| `1`-`6`, `n`, `!` | Jump to a page |
| `Tab` | Put the focus on the page's list, where `↑` `↓` then scroll it a line at a time. A page with two lists, such as Production, gets the focus on each in turn. `Tab` from the last list, or `Esc`, gives the arrows back to the pages |
| `PgUp` `PgDn`, `Space` | Scroll the page's list half a screen |
| `g` | Back to the top of a list |
| `?` | Help for the page, see [Help](#help) |
| `/` | Command list, with gum |
| `r` | Redraw the screen |
| `q` | Quit |

The Logs page adds `p` to pause and resume, `f` to find, `l` to cycle the
level, `←` `→` to move long lines sideways and `G` to jump to the oldest line.
The Notices page adds `x` to acknowledge its warnings and info.
The find pattern is matched against the time, the source and the message,
ignoring case; start it with `!` to hide the matching lines instead. The page
holds the newest 1,000 lines of the journal of the node's systemd service.

## Terminal sizes

The layout follows the size of the terminal, and follows it again when the
terminal is resized.

| Columns | Layout |
| --- | --- |
| 150 and more | Full rail, four tiles in a row, events beside the recent blocks |
| 110 to 149 | Full rail, tiles two by two |
| 80 to 109 | A narrow rail of page numbers and one stacked column |
| 34 to 79 | The rail's content alone: identity, epoch, vitals and the next block |
| Fewer than 34, or fewer than 16 rows | A request to enlarge the terminal |

On a short terminal the panels at the bottom of a page are left out first.

## Help

Press `?` on any page. The page stays as it is, one panel gets a double
border, and a drawer under the page says what that panel's figures mean and
what a good value looks like. Where gLiveView has a threshold, the drawer also
judges the current value as `good`, `watch` or `act`. `←` `→` or `Tab` move to
the next panel, `↑` `↓` scroll the text, and `?` or `Esc` close the help.

After the last panel the drawer explains the rail: each vital, with its
current value and verdict, and the next block countdown. Every panel's help
covers each figure it shows, including the metrics a node reports about
itself, such as Amaru's pipeline timings and Dingo's runtime and forging
counters, the rows of the Node & network page, and how to read the epoch
history together: the leader slots that did not end as a block on chain, and
the average luck over the epochs loaded so far.

On a terminal with fewer than 30 rows, or fewer than 110 columns, there is no
room for a drawer, and the help for the whole page is one scrollable text.

## Common live sections

The following labels form the shared dashboard vocabulary. Each
implementation can expose a different subset.

### Rail

| Label | Meaning |
| --- | --- |
| Logo | The node implementation's logo under the title, in the full rail of terminals 110 columns and wider. It is the first thing the rail leaves out on a short terminal, and `SHOW_NODE_LOGO=N` hides it. |
| Name | `NODE_NAME` when set, otherwise the name of the deployment folder. |
| Attention | Only while something needs attention: up to three errors (red, `✗`) and warnings not acknowledged (amber, `!`), errors first, and how many more the Notices page has. On a short terminal the warnings leave before the vitals and the errors after them. See [Notices](#notices). |
| Role | A badge under the name: `RELAY` on blue, or `BLOCK PRODUCER` on gold. The compact layout starts its top line with the same badge. cnode and Dingo derive producer mode from the live forging metric; Amaru from the operational-certificate gauges that only a block producer exports. Without colours the badge reads `[RELAY]` or `[BLOCK PRODUCER]`. |
| Implementation and version | The node implementation, and the version reported by the running process or its build metric. |
| Network and up | The configured network, and the elapsed time for the current node process, not host uptime. The seconds are left out when the line would not fit the rail. |
| Sync | The tip gap, or the sync phase while the node reports one. |
| Peers | Outgoing and incoming connections as the node counts them. |
| Blocks | How long the last block took to arrive. |
| KES, Op cert | On a producer: remaining KES periods, and the certificate counters on disk and on chain. |
| Pool | On a producer with pool data from Koios: the ticker and the pool's saturation. Red with `pledge not met` when the owners delegate less than the pledge, which costs the pool the epoch's rewards, and with `retired`; amber while the pool is retiring or over-saturated. Not shown without an answer from Koios. |
| Host, Node | Processor use of the host, and processor and memory use of the node process. |
| Next block | On a producer with a leader schedule: the countdown to the next leader slot. This is sensitive operational information; control who can view the terminal. |
| Notices count | Beside `Notices` in the page list: the notices not acknowledged, in the colour of the worst of them. The slim rail at 80 to 109 columns colours its `!` the same way. |

The terminal title, which a terminal tab or tmux window shows, names the node
and its role while gLiveView runs, for example `gLiveView - bp1 - block
producer`. While an error is open the title starts with `(!)`, so a tab shows
it without switching to it. gLiveView saves the previous title on the
terminal's title stack and restores it on exit, as xterm-compatible terminals
and tmux do. A terminal without a title stack keeps gLiveView's title until
the shell sets its own.

### Epoch

| Label | Meaning |
| --- | --- |
| Bar | The latest locally processed slot's position within the epoch. It is local ledger progress, not network synchronization progress. |
| Time left | Counted from the wall clock. |
| Marks | On a producer with a leader schedule, one mark per leader slot: adopted, still to come, passed without a result yet, or lost. While the block log holds no block results, a passed slot is grey. |
| Alert | Shown only while the node reports a condition that needs operator action, such as a halted or stuck ledger, the operator's own pool equivocating, or invalid forging keys. |
| Sync | Shown only while the node reports bootstrap or catch-up progress, such as Dingo's Mithril download or ledger import, with its percentage and rate. |
| Starting | While cardano-node starts, the panel is titled Starting and follows the node's log: opening the database, checking the immutable DB after an unclean stop, opening and replaying the ledger, selecting the chain, starting the network. A check or a replay has a bar, its percentage, and the time left at the pace so far. Once its socket is up, the node waits for the next block: cardano-node reports its tip only when it adds a block to its chain, and after a short stop that is the next block the network makes, so the wait can take a minute. The panel says how old the last block on its chain is, or, in Genesis pre-syncing, how many big ledger peers are active. The node is ready when it reports its tip. Other nodes show Starting until they report a tip. |
| Stopped, failed, restarting | With no node process, the node's systemd service says why: stopped, failed (systemd does not start it again), or stopped on its own and waiting to be restarted. The second line gives the last error in the node's log, or the command to start it. |

### Chain

| Label | Meaning |
| --- | --- |
| Block, Slot, Epoch slot | Height and slot of the node's tip, and that slot counted from the start of the epoch. |
| Tip gap | Slots between the tip and the slot the wall clock is in. A gap the node reports itself is used when there is one. Green up to 120 slots, amber up to 600, red above. |
| Density | Share of slots that hold a block, as the node measures it. |
| Forks | How often the node switched to another chain since it started. |
| Pending tx, Mempool | Transactions waiting in the node's mempool, as a count and as bytes. |
| Total tx | Transactions the node has processed since it started. |

### Propagation

| Label | Meaning |
| --- | --- |
| Last block | Time from the start of the block's slot until the node had the block. Green up to 1 s, amber up to 3 s, red above. |
| Slowest, bars | One bar per block since gLiveView started, and the slowest of them. |
| ≤1s ≤3s ≤5s | Share of blocks that arrived within 1, 3 and 5 seconds. |
| Late | Blocks that took longer than 5 s. |
| Served | Blocks the node handed to peers that asked for them. |

A node without propagation figures gives this tile to its own metrics.

### Peers

| Label | Meaning |
| --- | --- |
| Outgoing | Peers the node chose, as hot (in use), warm (connected, kept ready) and cold (known, not connected). |
| Big ledger | Relays of the largest pools, which cardano-node picks and counts apart from its other outgoing peers. |
| Incoming | Peers that connected to the node, hot when they fetch from it and warm when they only hold the connection. |
| Conns | The same peers counted as connections: out is outgoing plus big ledger, in is incoming, and both are the connections used in both directions. |

A node that reports other counters shows those instead: known, established
and active peers, or its connection counts.

### Resources

| Label | Meaning |
| --- | --- |
| CPU (sys) | Processor use of the whole host, all cores together. |
| CPU (node) | Processor use of the node process alone, in percent of one core. |
| Mem (RSS) | Memory the node process holds in RAM. |
| Live, heap | Runtime memory figures, where the node exports them. |
| Disk util | How full the filesystem with the deployment folder is. |
| Open files | Files and sockets the node has open, against its limit, where the node exports them. |

### Block production

Shown on a producer, in the overview and on the Production page.

| Label | Meaning |
| --- | --- |
| Leader, Ideal, Luck | With a leader schedule: slots the pool leads this epoch, the number its stake would give on average, and one against the other. |
| Passed, To come | With a leader schedule but no block results in the block log: leader slots of this epoch that have passed and that are still to come. |
| Adopted, Confirmed | Blocks the node made and put on its chain, and the adopted blocks later verified to be on the chain. |
| Missed, Ghosted, Stolen, Height battle, Invalid | The slot passed without a block; the block was built on a block that lost a fork, or lost for another reason; another pool led the same slot and won (slot battle); another pool's block in a nearby slot on the same parent won (height battle); the node failed to make the block. |
| Unknown | Shown only when there are any, in amber: passed slots where nothing could tell yet whether our block is on the chain. Amaru's validation sets it when the journal no longer has the slot and Koios is not there or did not answer. They are not counted as lost, and are checked again on every run. |
| KES | Remaining KES periods. Amber at 15, red at 5. |
| Op cert | The certificate counter on disk and the last one used on chain. It is marked wrong unless the disk counter equals the chain counter or exceeds it by one. |
| Missed chk | Leadership checks the node skipped. Sustained growth can indicate CPU, I/O, GC, or timekeeping pressure. |
| BLS key | On a cardano-node producer: `set` when the node runs with `--shelley-bls-key`, the key it votes with in the Leios committee. Amber `not set` when the protocol parameters show protocol 12 (Dijkstra) or later and the node has none. No row on earlier networks. |

Block results are written to the block log by the validate service:
`cncli.sh validate` on cardano-node, `amaru-leaderlog.sh validate` on Amaru.
Until the block log holds any result, gLiveView shows `Passed` and `To come`
in place of the adopted and lost counts, marks passed slots as `· passed` on
the Production page, and leaves the adopted column out of the epoch history,
so none of them reads 0 while the pool is making blocks.

On the Production page, each passed slot carries a note from the block
details the validation recorded:

```
✗ height battle  Tue 17 14:24:48   51,851        —  ABCD 2 s earlier, reached us 0.60 s into our slot · forged in 0.12 s
✗ height battle  Tue 17 16:03:10   57,633        —  EFGH 3 s later, same parent · forged in 0.15 s
✗ stolen         Tue 17 18:02:11   64,931        —  slot battle with IJKL, their VRF lower
✗ missed         Tue 17 20:41:07   74,467        —  node woke late
✓ confirmed      Tue 17 21:10:52   76,252  131,940  forged in 0.11 s
```

A winner in a later slot means the next leader had not received our block. A
winner in an earlier slot reached this node only after we forged. Times are as
this node saw them; how fast our own block reached other pools cannot be seen
locally. A shared measurement such as
[openblockperf](https://github.com/cardano-foundation/openblockperf) may add
that later. CNTools shows every detail, including the blocks before and after.

Without a leader schedule the panel shows the node's own counters since it
started.

gLiveView reads the block log at `BLOCKLOG_DB` when an adapter sets it, as the
cnode adapter does, otherwise at `blocklog.db` in `BLOCKLOG_DIR` from `env`,
and by default at `guild-db/blocklog/blocklog.db` in the deployment folder,
the same file CNTools reads.

### Pool and epoch history

On a producer the Production page also shows the pool as
[Koios](https://koios.rest) sees it, and the pool's history one epoch per row.
This works the same for cardano-node, Amaru and Dingo.

| Label | Meaning |
| --- | --- |
| Live stake, Active stake | Delegated to the pool now, and the stake this epoch's leader slots were drawn from. |
| Saturation | Live stake against the saturation point. Amber above 100 %. |
| Pledge, Live pledge | What the owners promised to delegate, and what they delegate now, with ✓ or a red ✗. |
| Margin, Fixed cost | What the operator takes from each epoch's rewards. |
| Delegators, Lifetime blocks | Accounts delegating now, and the blocks the pool has made since it was registered. |

The epoch history has these columns, newest epoch first:

| Column | Meaning |
| --- | --- |
| Epoch | The epoch, with `next` and `now` on the two newest rows. |
| Stake, Deleg | Active stake and delegators in the epoch. |
| Led | Leader slots the block log holds for the epoch, `—` where it has none. |
| Blocks, Ideal, Luck | Blocks the pool made, the number its share of the active stake gives on average, and one against the other. For the current epoch the block log's count is used when it is ahead of Koios. |
| Fees, Rewards, ROS | What the operator received, what the delegators received, and their yearly return on stake at that epoch's rate. |

An epoch's rewards are settled two epochs after it. Until then its row comes
from the stake snapshots Koios keeps, and the blocks and delegators Koios
counts for it: the next epoch has a stake and delegators but no blocks yet,
and the current and previous epochs show their rewards as `pending`. The narrowest columns, Deleg and Fees, leave first on a
terminal under 110 columns.

The history shows `POOL_HISTORY_EPOCHS` epochs at a time, 5 by default. `Tab`
puts the focus on the leader schedule and then on the history; there `↑` `↓`
move one epoch, `PgUp` `PgDn` as many as the list shows, `g` goes back to the
newest epoch and `G` to the pool's first. Epochs that are not loaded yet are
fetched from Koios as they come into view, ten at a time, and the history
asks for the next ones before you reach them. On a short terminal the
history gives up rows first, so that the leader schedule keeps room for three
slots, and leaves the page when even one epoch no longer fits.

The pool ID comes from `POOL_ID` at the top of `gLiveView.sh`, which takes a
bech32 or hex ID, or else from `pool.id-bech32`, `pool.id` or `cold.vkey` in
the pool folder (`POOL_FOLDER`/`POOL_NAME` in `env`). A producer that keeps
its cold keys elsewhere needs `POOL_ID`. gLiveView writes nothing to the pool
folder.

Koios is asked in the background: the pool data every 10 minutes and as an
epoch starts, the history as you scroll. The page never waits for it, and it
uses the Koios token in `env` when there is one. When Koios does not answer,
the panel keeps the last answer and says how old it is, or says that there is
none yet, and gLiveView asks again every minute; until there is an answer the
epoch history comes from the block log alone. With `ENABLE_KOIOS=N` in `env`,
or on a network without a Koios service, gLiveView sends no request and the
panel says why.

## Node-specific metrics

### cardano-node / cnode

cnode supplies the original cardano-node compatibility metrics used by the
common sections, and is the only node that reports big ledger peers, the
connection modes on the Peers page and the Haskell runtime figures.

`Live`, `Heap`, `GC minor`, and `GC major` come directly from the Haskell RTS
compatibility gauges. A widening live-versus-heap gap is not automatically a
fault, but sustained heap growth, frequent major collections, or swapping
should be investigated together with CPU and missed leadership checks.

On a producer, the operational-certificate counters are read once with
`cardano-cli query kes-period-info`, and the leader schedule, its results and
the epoch history come from the CNCLI blocklog. See [CNCLI](cncli.md) for
blocklog collection and validation details. Without a blocklog the Production
page shows the node's process-lifetime `Leader`, `Adopted` and `Invalid`
counters and no schedule.

gLiveView 2 does not show the Mithril signer section that gLiveView 1 had. The
Koios pool figures are on the Production page, see
[Pool and epoch history](#pool-and-epoch-history).

### Dingo

Dingo exposes the cardano-node-compatible family used by the common Chain,
Peers, Propagation, Resources and Block production panels. It also contributes
native fields to the `Dingo metrics` panel on the System page, to the alert
and sync lines, and to the Node & network page. Dingo has no terminal
dashboard of its own; these fields follow what its upstream Grafana dashboards
and alert rules treat as the primary operational signals.

Dingo's outbound peer-temperature gauges also count peers that connected
inbound. The adapter subtracts those inbound peers so that the `Outgoing` row
describes only outbound selection, as Dingo's own targets
do. Dingo keeps the peers that connected to it in a budget of their own, shown
as `Inb warm` and `Inb hot` among the Dingo metrics. Dingo does not export how its
peers hold it, so the Peers panel has no `Incoming` row for Dingo.

`Live` is Go's `runtime.MemStats.HeapAlloc` and `Heap` is `HeapSys`.
Go's collector is not generational, so the Haskell `GC minor` and `GC major`
fields are not shown and the total collection count appears as `GC cycles`
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
| Inb warm | Peers that connected to Dingo and that it holds warm, which it does once they connect, counted against its `InboundWarmTarget` after their first 3 seconds. Not how peers hold Dingo. |
| Inb hot | Peers that connected to Dingo and that it fetches from, against its `InboundHotQuota`. |
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

The alert line reports, most severe first: a halted ledger pipeline, the
operator's own pool equivocating, invalid forging credentials on a producer,
a stuck ledger pipeline, skipped epoch reward rounds, a stuck or waiting
Mithril restore, and Mithril sync errors.

While `dingo.sh bootstrap` runs, the bootstrap process serves only its Mithril
progress metrics on the same endpoint. gLiveView then shows a sync line with
the active phase (download, block copy, the ledger stage being imported, gap
blocks, or finalising), its percentage and rate, and takes the version from the
installed binary. A node started with `mithril.enabled` reports `Mithril
restore` or `Mithril catch-up` in the same line.

Dingo producer mode uses the shared Block production panel:

| Label | Meaning |
| --- | --- |
| Leader | Slots in which Dingo was elected leader and passed its pre-forging checks. |
| Adopted | Forged blocks adopted onto the chain. |
| Invalid | Forged blocks minus adopted blocks. |
| Scheduled | Leader slots in Dingo's latest computed schedule. |
| Lost | Leader slots that did not end with this pool's block adopted, whether refused, failed, or lost in a slot battle. |
| KES | Remaining usable KES periods for the loaded operational certificate. |
| Op cert | Operational certificate counter loaded from disk and recorded on chain. The chain value appears after the pool's first block. |
| Keys | `valid` while the loaded credentials can sign at the current slot; `invalid` also raises an alert. |

Dingo has no counter for missed leadership checks, so `Missed chk` is not
shown. Dingo has no topology file and its Guild profile names no peers, so the
Peers page offers no Static filter, and Dingo logs no per-peer state for the
Conn and Score columns.

Static Dingo values are kept off the live pages. Its Go runtime version and
processor count, native epoch length, Shelley start time, KES period length,
mempool implementation and capacity, and latest stake snapshot appear on the
Node & network page. Dingo is a rolling-release profile, so a newly published
build can temporarily omit an optional field; the adapter evaluates each field
on every scrape.

### Amaru

Amaru's reference bridge supplies a cardano-node-compatible subset for the
common chain, mempool, served-block, and build fields. Amaru exports no
forging flag. Its forge stage is the only source of the
operational-certificate gauges, so the adapter treats their presence as
producer mode. They first appear once the node adopts a new tip after a
start. An Amaru producer shows its remaining KES periods in the Block
production panel. Amaru exports no leader-schedule or forged-block counters,
so the Production figures come from the leader schedule that
`amaru-leaderlog.sh` stores in the block log, see
[Leader schedule](../Build/amaru.md#leader-schedule), with the results of its
[block validation](../Build/amaru.md#block-validation).

Amaru's own terminal dashboard runs inside the node process and is therefore
only available when `amaru.sh run` is started from an interactive terminal.
Under systemd, gLiveView shows the same node, chain, mempool, resource, and
block-timing data that Amaru exports as metrics. Its per-peer table, peer-set
sizes, round-trip times, protocol version, and stake and governance views are
produced from in-process traces and are not exported as metrics. gLiveView's
[peer analysis](#peer-analysis) rebuilds the connections and first deliveries
of the per-peer table from Amaru's log.

Amaru 10.11.20261105 and later export the connection-manager counters, which
gLiveView shows on the Peers page. With older releases, the adapter counts
the node process's established TCP sessions and gLiveView shows that one
figure as `Connections`.

Block propagation is derived from Amaru's timing histograms. For each new
block, `Last block` is the time from the start of its slot until the block was
received: the header delay, the wait before fetching, and the fetch itself.
The `Within` shares cover the live blocks observed while gLiveView has been
running, up to the latest 100, so they start empty and are not node-lifetime
figures. Values disappear when no block has arrived for 10 minutes.

The `Amaru metrics` panel on the System page contains:

| Label | Meaning |
| --- | --- |
| Proc CPU | Amaru's own current process CPU gauge. It can differ slightly from gLiveView's locally sampled `CPU (node)`. |
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
the process started. `Forks` in the Chain panel counts only fork switches
that changed the selected chain.

`Open files` appears in the Resources panel and on the System page, with its limit. Uptime is
calculated from the active Amaru service PID using Linux's monotonic process
start time, with a bounded `ps` fallback; collector runtime telemetry is not
presented as Amaru node telemetry. The Node & network page adds the build platform,
host memory, and, on a relay, the current KES period.

Amaru releases evolve quickly. The tables document the current adapter
contract, but gLiveView displays a native metric only when the running release
actually exports the required series.

## Node & network page

Press `n` for what is relatively static. The page is taller than most
terminals and scrolls as a whole.

| Panel | Rows |
| --- | --- |
| Node | Implementation, version and revision, role, service, process and its stage (starting, ready, stopped), uptime, the consensus mode the node started in with its Genesis state (pre-syncing, syncing, caught up) and the mode `config.json` sets when that differs, and how gLiveView is set up |
| Binary | The program file the node process runs, the version and build it reports, its size and date, and the release pin of the deployment. When the file was replaced after the node started, as after an upgrade, `On disk` turns amber and says to restart. `File` shows whether the node runs the deployment's own binary or a shared copy elsewhere |
| Start-up options | The options on the node's command line, and the settings in its environment that carry the node's own prefix (`AMARU_`, `DINGO_`, `CARDANO_`). A setting whose name suggests a key, token or password shows as `hidden` |
| Deployment | Node home, configuration, node socket and metrics endpoint where the start-up options do not already show them, and the block log and pool folder when they exist |
| Reported by the node | Adapter-supplied static metadata, such as Dingo's Go runtime and stake snapshot or Amaru's build platform and host memory |
| Network | Network name and magic, node port, epoch and slot length, active slot coefficient, KES constants |
| Protocol parameters | The parameters in force, grouped as Network, Economic and Governance, and on a Dijkstra-era network also Peras and Leios. The protocol version names its era. A Dijkstra parameter that is not set, such as `maxPledgeLeverage`, shows as none. A parameter gLiveView has no name for is listed under Other |

The protocol parameters are asked from the node through its local socket
where it has one (cnode and Dingo), and from Koios otherwise (Amaru). They are
read in the background when the page is opened and again when the epoch
changes.

## Notices

Press `!` for what needs attention. Each notice says what it means and what to
do, and has a level:

| Level | Where it shows | Example |
| --- | --- | --- |
| Error (red, `✗`) | The rail's Attention lines, the Notices page, and `(!)` in the terminal title. A new error pulses in the rail until the Notices page has been open; `GLV_PULSE=N` keeps it steady. It cannot be acknowledged and goes when its cause does | The node not running, KES key about to expire |
| Warning (amber, `!`) | The rail's Attention lines until acknowledged, and the Notices page | A configuration update pending, the disk 90 % full |
| Info (grey, `i`) | The Notices page only | A newer node release pinned by the deployment |

`x` on the Notices page acknowledges the warnings and info listed: they leave
the rail and the count, and stay on the page marked as acknowledged. One that
changes, such as a warning that turns into an error, comes back. The
acknowledgements are kept in `gLiveView.sh.notices` beside the script.

gLiveView checks:

| Notice | Level |
| --- | --- |
| The node stopped, failed, or restarting after it stopped on its own, with the last error in its log | Error |
| The node starting, with its phase and how far it is | Info |
| No metrics from the node, or its process not running | Error |
| Metrics port taken: the metrics on the node's port come from another node that started earlier, or the node logged that it could not open the port. Give each deployment its own `PrometheusSimple` port | Error |
| `config.json` sets a consensus mode the running node did not start in, such as `GenesisMode` after `guild-deploy.sh -s u`, or `config.json` changed after the node started. Both need a restart; a reload does not change them | Warning |
| `topology.json` or the peer snapshot changed after the node started, and its log shows no reload since: `cnode.sh systemd reload` | Warning |
| No node socket a minute after the node is ready, so CNTools and `cardano-cli` cannot reach it; names the node's own `--socket-path` when it differs from `SOCKET` in `env` | Warning |
| Genesis mode: five minutes in PreSyncing, with the big ledger peers active and needed | Warning |
| An alert the node raises | Error |
| No outgoing peers five minutes after the node started | Error |
| KES periods left, on a producer | Warning at 15 or fewer, error at 5 or fewer |
| Operational certificate counter on disk neither equal to the chain's nor one higher | Error |
| Pledge not met, or pool retired, from Koios | Error |
| Pool retiring or over-saturated, from Koios | Warning |
| Configuration update pending: files the last `guild-deploy.sh` refresh kept although this release changes them. `guild-deploy.sh -s u` updates them in place. A file changed since that refresh is not reported | Warning |
| Disk with the node's home | Warning at 90 %, error at 95 % |
| The node binary replaced while the node runs: restart to run it | Warning for a new version, info for the same version installed again |
| A release pin the binary on disk does not meet: `guild-deploy.sh -s d` installs it | Info |

When a notice comes up or clears, that is an event too, in the notice's
colour, or green when it clears. The node's own changes are events as well: its
service stopped, failed or restarting it, a new process starting, each phase of
a cardano-node start and when it was ready, the consensus mode it started in,
and the Genesis state machine moving between pre-syncing, syncing and caught
up. Below the notices the Notices page lists the last 200 events since
gLiveView started, newest first; `Tab` puts the focus on the list to scroll it.
The [Node & network page](#node-network-page) shows the consensus mode the node
started in and its Genesis state.

## Peer analysis

The Peers page lists every TCP connection of the node process, fastest first,
on every refresh. The round-trip time is the one the kernel measures on the
established connection, read with one `ss` call: nothing is sent to the peers.
This part works for every implementation.

The round trips are grouped into under 50, under 100, under 200, and 200 ms
and more, with their average.

Press `a` to add the node's own view of each connection, the static peers and
the locations. That analysis runs in the background: the page keeps updating,
the panel title shows what it is doing, and afterwards how old the node's view
is. It is never started by itself, because for cardano-node it signals the
node.

| Key | Filter | Choices |
| --- | --- | --- |
| `t` | Peers | All, Static. cnode and Amaru. |
| `f` | Find | Part of an IP address or port, such as `203.0.113` or `:6000`. An empty answer clears it. |
| `d` | Direction | With the node's data, see below. |
| `s` | State | With the node's data, see below. |

The filters narrow the list, the round-trip classes and the average.

For cnode, static peers are the `localRoots` access points of the topology
file the running node was started with (`--topology`), or of `TOPOLOGY`
otherwise. For Amaru they are the `--peer` options it was started with, on its
command line or in `AMARU_PEER`. DNS names are resolved, and connections match
by address, because a peer that connects to the node may use another port than
its entry. A static peer shows the entry's `description`, `pool`, `name` or
DNS name in place of its location. When several entries share an address, such
as two nodes behind one public IP, a connection on an entry's own port shows
that entry's name, and a connection on any other port shows all of their
names. With the Static filter, configured peers without a connection are
listed after the others as `Not connected`, or `DNS name did not resolve`;
they are not counted in the round-trip figures. On a shared address, only a
connection on the entry's own port counts as connected.

A node whose topology lists its own address connects to itself. That
connection stays in the list, labelled `this node itself`, as a sign that the
topology entry was meant for another node.

With `ENABLE_IP_GEOLOCATION=Y`, every public peer address is looked up at
ip-api.com, 100 addresses per request, and the results are cached next to the
script in `gLiveView.sh.geo`.

### Connection use, peer states and scores

On cnode and Amaru, peer analysis reads two more columns from the node itself:

- `Conn` says who uses the connection: `out` when the node fetches from the
  peer, `in` when the peer fetches from the node, `dup` when both happen over
  the same duplex connection, and `idle` when neither does. The letter after
  it is the hot (`H`) or warm (`W`) state: the node's view of the peer for
  `out`, the peer's view of the node for `in`, and both for `dup`, the node's
  side first, as in `dup H/W`. The cell is empty for a connection that was
  still being set up or closed, or one opened during the analysis.
- `Score` is the number of block headers the peer delivered first plus the
  number of blocks the node fetched from it first, among the last 180 headers
  and the last 180 blocks. cardano-node ranks its hot peers by these counts.
  Only peers the node fetches from can score, so most cells are empty.

Both come from the node's journal. The node logs only changes to its
connections, never their current state, so gLiveView needs every line since
the node started. The first analysis after the node starts reads the whole log
since then, which takes a few seconds for a day of a busy cardano-node relay's
log. gLiveView then saves what it found, with the position it read up to, in
`gLiveView.sh.peerstate` next to the script, and later analyses read only the
log written since. If the journal no longer holds the start of the node's run,
connections opened before that lack what their log lines said: the peer's
letter on cardano-node, the whole cell on Amaru.

`ENABLE_NODE_PEER_STATE=N` turns the columns off. Both need the node running
as a systemd service that logs to the journal, and gLiveView able to read the
node's journal.

#### cardano-node

- **Connections, the node's side and the score.** When you press `a`, gLiveView sends the node
  `SIGUSR1`, which makes it write its connection manager and peer selection
  state to its log. The node refreshes its hot and warm sets for this dump at
  most every 83 seconds, so a peer that changed state in that time can show
  its previous state, and a node started a minute or two ago shows none.
- **The peer's side.** The node logs a line each time a peer promotes or
  demotes it, which gLiveView follows in the log.

Connections are told apart by the ports on both ends, so two connections to
the same peer each show their own use. This needs cardano-node to log JSON
(`Stdout MachineFormat`), with `Net.ConnectionManager.Remote`,
`Net.InboundGovernor.Remote` and `Net.PeerSelection` traced at `Info`, as in
the Guild configuration, and gLiveView to run as the node's user, so that it
can signal the node.

Each analysis adds the dump to the node's log, about 100 KB for a relay with
400 connections. journald splits lines longer than 48 KiB, and gLiveView joins
them again. Other tools that read the node's log, such as openBlockPerf, may
log a parse warning for each part.

#### Amaru

Amaru logs, at `Info`, each connection's handshake, its own use of the
connection and the peer's: `none`, `maintenance` (warm) or `diffusion` (hot).
Once it follows the tip, it also logs which peer announced each header and
delivered each block first, so `Score` stays empty while it catches up.
gLiveView counts those first deliveries itself, in the same window
cardano-node keeps. Amaru is never signalled: it does not handle `SIGUSR1`.

Amaru knows a connection by the peer's address and, by default, dials out from
its listen port, so connections are matched by the peer's address and port.
Its connection to the local OpenTelemetry collector is left out of the list.

This needs Amaru's default text log, as the Guild profile sets it:
`AMARU_LOG` with `amaru=info` and `AMARU_LOG_JSON=false`.

#### Filters

With the node's data, the filter row adds:

| Key | Filter | Choices |
| --- | --- | --- |
| `d` | Direction | All, Out, In, Duplex. Out and In include duplex connections, as the node's connection counters do. |
| `s` | State | Any, Hot, Warm. The state on the chosen direction's side, or the hotter side for All and Duplex. |

## Refresh behavior

gLiveView collects the node's metrics every `REFRESH_RATE` seconds. Clocks,
countdowns and the tip gap move every second in between, without asking the
node again. What only one page needs, such as the connection list or the
journal, is read only while that page is on screen.

Each frame is built in full, but only the terminal rows whose content changed
are written, inside synchronized output (DEC mode 2026), so terminals that
support it, such as iTerm2, kitty, WezTerm, Windows Terminal and recent tmux,
show each update in one step. The terminal size is checked on every pass, so
a resize is followed even where no resize signal arrives, as under `su -c`.

Slow work never blocks the page: peer analysis and the protocol parameters are
read by background jobs whose results the page picks up when they are ready.

## Troubleshooting

gLiveView treats node-process discovery and metric collection separately. If
either fails, the rail and the epoch panel say whether the node is stopped,
failed, restarting, starting, or its metrics are not answering, and gLiveView
keeps trying every `REFRESH_RATE` seconds; it does not render a stale scrape,
and it does not exit. What a stopped or starting node is doing comes from its
systemd service and its journal, which the node's own user can read.

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

Two deployments on one host must not share a metrics port. gLiveView shows
nothing for a node whose process is not running, even when another node
answers on the port it expects.

If automatic discovery is wrong, review `env`, the implementation environment,
and the User Variables section of `gLiveView.sh`. Report reproducible adapter
or rendering problems through the [Guild Operators issue
tracker](https://github.com/cardano-community/guild-operators/issues).

## User variables

```bash
######################################
# User Variables - Change as desired #
######################################

#NODE_NAME=""                             # Name shown for this node
#REFRESH_RATE=2                           # Seconds between metric collections
#GLV_THEME=""                             # default | hydra-after-dark
#GLV_COLORS=""                            # truecolor | 256 | none
#SHOW_NODE_LOGO=Y                         # Show the node's logo in the full rail
#ENABLE_IP_GEOLOCATION=Y                  # Geolocate peer addresses
#POOL_ID=""                               # Pool ID for the pool data, bech32 or hex
#POOL_HISTORY_EPOCHS=5                    # Epochs shown at a time in the epoch history
#ENABLE_NODE_PEER_STATE=Y                 # Read peer data from the node's journal
#GLV_PULSE=Y                              # A new error pulses in the rail until the Notices page has been open
```

A script update keeps the variables you already have. `SHOW_NODE_LOGO` from
gLiveView 1 still works, and `false` hides the logo as `N` does. The ones
gLiveView 1 used and gLiveView 2 does not (`REPAINT_RATE`, `LEGACY_MODE`,
`RETRIES`, `PEER_LIST_CNT`, `THEME`, `LATENCY_TOOLS`, `CNCLI_CONNECT_ONLY`,
`HIDE_DUPLICATE_IPS`, `VERBOSE`, `GLV_LOG`) stay in the file and have no
effect.

## Upstream metric references

- [cardano-node monitoring and metrics](https://developers.cardano.org/docs/operate-a-stake-pool/node-monitoring/)
- [Dingo forging metric definitions](https://github.com/blinklabs-io/dingo/blob/main/ledger/forging/metrics.go)
- [Dingo ledger metric definitions](https://github.com/blinklabs-io/dingo/blob/main/ledger/metrics.go)
- [Amaru consensus metric definitions](https://github.com/pragma-org/amaru/blob/main/crates/amaru-metrics/src/consensus.rs)
- [Amaru system metric definitions](https://github.com/pragma-org/amaru/blob/main/crates/amaru-metrics/src/system.rs)
- [Amaru mempool metric definitions](https://github.com/pragma-org/amaru/blob/main/crates/amaru-metrics/src/mempool.rs)
