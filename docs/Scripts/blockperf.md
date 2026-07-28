!!! info "Reminder !!"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

!!! warning "Currently disabled and cnode-only"
    `blockPerf.sh` has not been updated for the current `cardano-node` tracing
    format. It exits without collecting data, and both `blockPerf.sh -d` and
    `blockPerf.sh systemd install` deliberately refuse to install a service
    that cannot run. Dingo and Amaru deployments do not install this helper.

`blockPerf.sh` is a script to monitor the network propagation of new blocks as seen by the local cardano-node.  

#### Block propagation traces
Although blockPerf can also run on the block producer, it makes the most sense to run it on the upstream relays. There it waits for each new block announced to the relay over the network by its remote peers. 

It looks for the delay times that result

- from the theoretical slot time of the block generator
- until the block *header* was offered to the local node
- the node *requested* the block 
- the node *downloaded* the block
- the node has *verified and adopted* the block

When tracing support is restored, this data can be viewed locally as a console stream or collected by a systemd service in the background.

The historical implementation also sent this data to the TopologyUpdater
server so contributing relays could compare propagation performance. No data
is collected or sent while BlockPerf is disabled.

There is no connection or constraint between the TopologyUpdater Relay subscription and the BlockPerf analysis. BlockPerf is even designed to work outside the cnTools suite. 

The results of these data are a good basis to make optimizations and to evaluate which changes were useful or might by required to improve the performance compared to other relay nodes.

#### Installation

New installation is disabled until the tracing parser is updated. The script still owns the old unit name so stale installations can be inspected and safely removed:

``` bash
$CNODE_HOME/scripts/blockPerf.sh systemd status
$CNODE_HOME/scripts/blockPerf.sh systemd remove
```

The owned unit is `${CNODE_VNAME}-tu-blockperf.service` (`cnode-tu-blockperf.service` with the default prefix). No central systemd deployment script is required.

#### Historical console view
If you run blockPerf local in the console (`scripts/blockPerf.sh`) , immediately after the appearance of a new block it shows where it came from, how many slots away from the previous block it was, and how many milliseconds the individual steps took.

```
Block:.... 6860534
 Slot..... 52833850 (+59s)
 ......... 2022-02-09 09:49:01
 Header... 2022-02-09 09:49:02,780 (+1780 ms)
 Request.. 2022-02-09 09:49:02,780 (+0 ms)
 Block.... 2022-02-09 09:49:02,830 (+50 ms)
 Adopted.. 2022-02-09 09:49:02,900 (+70 ms)
 Size..... 79976 bytes
 delay.... 1.819971868 sec
 From..... 104.xxx.xxx.61:3001

Block:.... 6860535
 Slot..... 52833857 (+7s)
 ......... 2022-02-09 09:49:08
 Header... 2022-02-09 09:49:08,960 (+960 ms)
 Request.. 2022-02-09 09:49:08,970 (+10 ms)
 Block.... 2022-02-09 09:49:09,020 (+50 ms)
 Adopted.. 2022-02-09 09:49:09,090 (+70 ms)
 Size..... 64950 bytes
 delay.... 1.028341023 sec
 From..... 34.xxx.xxx.15:4001

```



#### Historical collaborative web view

The historical BlockPerf project also aimed to aggregate contributing relays'
data through the central TopologyUpdater service and compare propagation
performance. That workflow is not active while BlockPerf is disabled; the
image below is retained only as an example of the former design.

![Core](https://raw.githubusercontent.com/cardano-community/guild-operators/images/blockperf_commonview.png 'Gantt diagramm: different Nodes block propagation times')
