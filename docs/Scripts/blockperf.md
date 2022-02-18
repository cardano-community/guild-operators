!!! info "Reminder !!"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

`blockPerf.sh` is a script to monitor the network propagation of new blocks as seen by the local cardano-node.  

##### Block propagation traces
Although blockPerf can also run on the block producer, it makes the most sense to run it on the upstream relays. There it waits for each new block announced to the relay over the network by its remote peers. 

It looks for the delay times that result

- from the theoretical slot time of the block generator
- until the block *header* was offered to the local node
- the node *requested* the block 
- the node *downloaded* the block
- the node has *verified and adopted* the block

You can view this data locally as a console stream, or run it as a systemd service in background. 

BlockPerf also sends this data to the TopologyUpdater server, so that there is a possibility to compare this data (similar to sendtip to pooltool). As a contributing operator you get the possibility to see how your own relays compare to other nodes regarding receive quality, delay times and thus performance. 

There is no connection or constraint between the TopologyUpdater Relay subscription and the BlockPerf analysis. BlockPerf is even designed to work outside the cnTools suite. 

The results of these data are a good basis to make optimizations and to evaluate which changes was useful or might by required to improve the performance compared to other relay nodes.

##### Installation
The script is best run as a background process. This can be accomplished in many ways but the preferred method is to run it as a systemd service. A terminal multiplexer like tmux or screen could also be used but not covered here.

##### Run as service

Use the `deploy-as-systemd.sh` script to create a systemd unit file.
In this setup the script is started in "service" mode. Error/Warn level log output is handled by syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. `journalctl -f -u cnode-blockperf.service` can be used to check service output (follow mode). 

##### Console view
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



##### Collaborative web view

(todo: preview of common comparison and visual timeline)