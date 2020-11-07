!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

`logMonitor.sh` is a general purpose json log monitoring script for traces created by cardano-node. Currently it will look for traces related to leader slots and block creation but other uses could be added in the future. 

##### Block traces
For the core node (block producer) the `logMonitor.sh` script can be run to monitor the json log file created by cardano-node for traces related to leader slots and block creation.   

For optimal coverage, it's best run together with [CNCLI](Scripts/cncli.md) scripts as they provide different functionality. Together they create a complete picture of blocks assigned, created, validated or invalid due to some issue. 

* [Installation](#installation)
* [View Collected Blocks](#view-collected-blocks)

##### Installation
The script is best run as a background process. This can be accomplished in many ways but the preferred method is to run it as a systemd service. A terminal multiplexer like tmux or screen could also be used but not covered here.

Use the `deploy-as-systemd.sh` script to create a systemd unit file.
Output is logged using syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. `journalctl -u <service>` can be used to check log. Other logging configurations are not covered here. 

##### View Collected Blocks
Best viewed in CNTools but as it's saved as regular JSON any text/JSON viewer could be used. Block data is saved to `BLOCK_DIR` variable set in env file, by default `${CNODE_HOME}/db/blocks`. One file is created for each epoch. 

Open CNTools and select `[b] Blocks` to open the block viewer.  
Either select `Epoch` and enter the epoch you want to see a detailed view for or choose `Summary` to display blocks for last x epochs.

**Block status**
* leader - pool scheduled to make block at this slot
* adopted - node created block successfully
* confirmed - block created validated to be on-chain with the certainty set in `cncli.sh` for `CONFIRM_BLOCK_CNT`
* missed - pool scheduled to make block at a slot that there is no record of it producing
* ghosted - pool created block but unable to find block hash on-chain, stolen in height/slot battle or block propagation issue
* invalid - pool failed to create block, base64 encoded error message can be decoded with `echo <base64 hash> | base64 -d | jq -r`

If the node was elected to create blocks in the selected epoch it could look something like this:

**Summary**
```
 >> BLOCKS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Current epoch: 94

+--------+---------+----------+------------+---------+----------+----------+
| Epoch  | Leader  | Adopted  | Confirmed  | Missed  | Ghosted  | Invalid  |
+--------+---------+----------+------------+---------+----------+----------+
| 94     | 20      | 10       | 10         | 0       | 0        | 0        |
| 93     | 4       | 4        | 4          | 0       | 0        | 0        |
+--------+---------+----------+------------+---------+----------+----------+
```
**Epoch**
```
 >> BLOCKS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Current epoch: 94

Leader : 20  |  Adopted / Confirmed : 10 / 10  |  Missed / Ghosted / Invalid : 0 / 0 / 0

+------------+----------+-----------+--------------+--------------------------+-------+-------------------------------------------------------------------+
| Status     | Block    | Slot      | SlotInEpoch  | At                       | Size  | Hash                                                              |
+------------+----------+-----------+--------------+--------------------------+-------+-------------------------------------------------------------------+
| confirmed  | 2007264  | 10246798  | 8398         | 2020-11-05 22:40:14 UTC  | 1388  | a4f2bbbc460213c97845b8bd3ebe6774cf8aa100202e595ce9c4c8cd7dcf94bd  |
| confirmed  | 2007322  | 10248270  | 9870         | 2020-11-05 23:04:46 UTC  | 1016  | 754af8761edc8b48d8bf277b9104dd921b3873cf1772d9e6213e5aa1d6348bff  |
| confirmed  | 2008752  | 10282751  | 44351        | 2020-11-06 08:39:27 UTC  | 1016  | 8537280589e8d5da713ec70554d7e40af908496b3dc0d0cc555f19a527e428c0  |
| confirmed  | 2009568  | 10302283  | 63883        | 2020-11-06 14:04:59 UTC  | 1016  | faccc61e2f947a2e3e8c00b270a755ded5872242b37b17ec2baf20d3865bf10b  |
| confirmed  | 2011042  | 10338139  | 99739        | 2020-11-07 00:02:35 UTC  | 1016  | ee7d6734b7505037a5cb3e983a9f6fdde05dd4837cd68b91e021192319e7d707  |
| confirmed  | 2011577  | 10350929  | 112529       | 2020-11-07 03:35:45 UTC  | 1016  | 007b8493b961b542e3f92e0bd5a465a3cf88ebfbe4a308dbe3e058d37fa7e93f  |
| confirmed  | 2011639  | 10352354  | 113954       | 2020-11-07 03:59:30 UTC  | 1016  | 55a97e105c22e98f72077d7a2850bf6742b8fae7032e9ef994015249f58740fd  |
| confirmed  | 2011968  | 10359685  | 121285       | 2020-11-07 06:01:41 UTC  | 1016  | 7924b2e7139686ed9c3fd34273583f386c2010a0fd4aa41328e02204c8491dda  |
| confirmed  | 2012592  | 10373759  | 135359       | 2020-11-07 09:56:15 UTC  | 1016  | 3d6204b337e2c749a7627839a87da9be7d42b2bf6bd24cd81174c7fb15a27fce  |
| confirmed  | 2012648  | 10375057  | 136657       | 2020-11-07 10:17:53 UTC  | 1016  | 788c58fc9b92e54289ed09cc2b004d03b5a5cb071224d26e88b587fe114b0d9d  |
| leader     | -        | 10422950  | 184550       | 2020-11-07 23:36:06 UTC  | -     | -                                                                 |
| leader     | -        | 10446589  | 208189       | 2020-11-08 06:10:05 UTC  | -     | -                                                                 |
| leader     | -        | 10481159  | 242759       | 2020-11-08 15:46:15 UTC  | -     | -                                                                 |
| leader     | -        | 10487667  | 249267       | 2020-11-08 17:34:43 UTC  | -     | -                                                                 |
| leader     | -        | 10507185  | 268785       | 2020-11-08 23:00:01 UTC  | -     | -                                                                 |
| leader     | -        | 10512090  | 273690       | 2020-11-09 00:21:46 UTC  | -     | -                                                                 |
| leader     | -        | 10567882  | 329482       | 2020-11-09 15:51:38 UTC  | -     | -                                                                 |
| leader     | -        | 10582037  | 343637       | 2020-11-09 19:47:33 UTC  | -     | -                                                                 |
| leader     | -        | 10630166  | 391766       | 2020-11-10 09:09:42 UTC  | -     | -                                                                 |
| leader     | -        | 10662327  | 423927       | 2020-11-10 18:05:43 UTC  | -     | -                                                                 |
+------------+----------+-----------+--------------+--------------------------+-------+-------------------------------------------------------------------+

[h] Home | [1] View 1 | [2] View 2 | [3] View 3 (full) | [*] Refresh current view
```
