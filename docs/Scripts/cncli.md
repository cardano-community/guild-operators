!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

`cncli.sh` is a script to download and deploy [CNCLI](https://github.com/AndrewWestberg/cncli) created and maintained by Andrew Westberg. It's a community-based CLI tool written in RUST for low-level cardano-node communication. Usage is **optional** and no script is dependent on it. The main features include:

**PING**      - Validates that the remote server is on the given network and returns its response time. Utilized by gLiveView for peer analysis if available. 
**SYNC**      - Connects to a node(local or remote) and synchronizes blocks to a local sqlite database. 
**VALIDATE**  - Validates that a block hash or partial block hash is on-chain.
**LEADERLOG** - Calculates a stakepool's expected slot list. On MainNet and the official TestNet, leader schedule is available 1.5 days before the end of the epoch (`firstSlotOfNextEpoch - (3 * k / f)`).
**SENDTIP**   - Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge.

##### Installation
`cncli.sh` script's main functions, sync, leaderlog, validate and ptsendtip are not meant to be run manually, but instead deploy as systemd services that run in the background to do the block scraping and validation automatically. Additional commands exist for manual execution to migrate old cntoolsBlockCollector JSON blocklog, re-validation of blocks and initially fill the blocklog DB with all blocks created by the pool known to the blockchain. See usage output below for a complete list of available commands.

The script work in tandem with [Log Monitor](Scripts/logmonitor.md) to provide faster adopted status but mainly to catch slots node is leader for but are unable to create a block for. These are marked as invalid. Blocklog will however work fine without logmonitor service and CNCLI is able to handle everything except catching invalid blocks.

1. Run the latest version of prereqs.sh with `prereqs.sh -c -l` to download and install RUST and CNCLI together with IOG fork of libsodium required by CNCLI. If a previous installation is found, RUST and CNCLI will be updated to the latest version.
2. Run `deploy-as-systemd.sh` to deploy the systemd services that handle all the work in the background. Six systemd services in total are deployed whereof four are related to CNCLI. See above for the different purposes they serve.
3. If you want to disable some of the deployed services, run `sudo systemctl disable <service>`

* cnode.service (main cardano-node launcher)
* cnode-cncli-sync.service
* cnode-cncli-leaderlog.service 
* cnode-cncli-validate.service
* cnode-cncli-ptsendtip.service
* cnode-logmonitor.service (see [Log Monitor](Scripts/logmonitor.md))

##### Configuration
You can override the values in the script at the User Variables section shown below. **POOL_ID**, **POOL_VRF_SKEY** and **POOL_VRF_VKEY**, **PT_API_KEY** and **POOL_TICKER** need to be set in the script before starting the services. For the rest of the commented values, if the default do not provide the right value, uncomment and make adjustments.

```
POOL_ID=""                                # Required for leaderlog calculation & pooltool sendtip, lower-case hex pool id
POOL_VRF_SKEY=""                          # Required for leaderlog calculation, path to pool's vrf.skey file
POOL_VRF_VKEY=""                          # Required for block validation, path to pool's vrf.vkey file
PT_API_KEY=""                             # POOLTOOL sendtip: set API key, e.g "a47811d3-0008-4ecd-9f3e-9c22bdb7c82d"
POOL_TICKER=""                            # POOLTOOL sendtip: set the pools ticker, e.g "TCKR"
#PT_HOST="127.0.0.1"                      # POOLTOOL sendtip: connect to a remote node, preferably block producer (default localhost)
#PT_PORT="${CNODE_PORT}"                  # POOLTOOL sendtip: port of node to connect to (default CNODE_PORT from env file)
#CNCLI_DIR="${CNODE_HOME}/guild-db/cncli" # path to folder for cncli sqlite db
#LIBSODIUM_FORK=/usr/local/lib            # path to folder for IOG fork of libsodium
#SLEEP_RATE=60                            # CNCLI leaderlog/validate: time to wait until next check (in seconds)
#CONFIRM_SLOT_CNT=300                     # CNCLI validate: require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=10                     # CNCLI validate: require at least these many blocks on top of minted before validating
#TIMEOUT_LEDGER_STATE=300                 # CNCLI leaderlog: timeout in seconds for ledger-state query
```

##### Run
Services are controlled by `sudo systemctl <status|start|stop|restart> <service name>`  
All services are configured as child services to cnode.service and as such, when an action is taken against this service it's replicated to all child services. E.g running `sudo systemctl start cnode.service` will also start all child services. 

> Make sure to set appropriate values according to [Configuration](#configuration) section before starting services.

Log output is handled by syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. `journalctl -f -u <service>` can be used to check service output(follow mode). Other logging configurations are not covered here. 

Recommended workflow to get started with CNCLI blocklog.

1. Install and deploy services according to [Installation](#installation) section.
2. Set required user variables according to [Configuration](#configuration) section.
3. (**optional**) If a previous blocklog db exist created by cntoolsBlockCollector, run this command to migrate json storage to new SQLite DB:
   * `$CNODE_HOME/scripts/cncli.sh migrate <path>` where <path> is the location for the directory containing all blocks_<epoch>.json files.
4. Run init command to fill the db with all blocks made by your pool known to the blockchain
   * `$CNODE_HOME/scripts/cncli.sh init`
5. Start deployed services with:
   * `sudo systemctl start cnode-cncli-sync.service`
   * `sudo systemctl start cnode-logmonitor.service`
   * `sudo systemctl start cnode-cncli-ptsendtip.service` (**optional but recommended**)
   * alternatively restart the main service that will trigger a start of all services with:
   * `sudo systemctl restart cnode.service`
6. Enjoy full blocklog automation and visit [View Blocklog](#view-blocklog) section for instructions on how to show blocks from the blocklog DB.

```
Usage: cncli.sh [sync] [leaderlog] [validate [all] [epoch]] [ptsendtip] [migrate <path>]
Keep a local blocklog run CNCLI to  
sync, leaderlog, validate best launched through systemd deployed by 'deploy-as-systemd.sh'

sync        Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB (deployed as service)
leaderlog   One-time leader schedule calculation for current epoch, 
            then continously monitors and calculates schedule for coming epochs, 1.5 days before epoch boundary on MainNet (deployed as service)
validate    Continously monitor and confirm that the blocks made actually was accepted and adopted by chain (deployed as service)
  all       One-time re-validation of all blocks in blocklog db
  epoch     One-time re-validation of blocks in blocklog db for the specified epoch 
ptsendtip   Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge (deployed as service)
init        One-time initialization adding all minted and confirmed blocks to blocklog
migrate     One-time migration from old blocklog(cntoolsBlockCollector) to new format (post cncli)
  path      Path to the old cntoolsBlockCollector blocklog folder holding json files with blocks created
```

##### View Blocklog
Best and easiest viewed in CNTools and gLiveView but the blocklog database is a SQLite DB so if you are comfortable with SQL, sqlite3 command can be used to query the DB. 

Open CNTools and select `[b] Blocks` to open the block viewer.  
Either select `Epoch` and enter the epoch you want to see a detailed view for or choose `Summary` to display blocks for last x epochs.

**Block status**
* leader    - scheduled to make block at this slot
* adopted   - block created successfully
* confirmed - block created validated to be on-chain with the certainty set in `cncli.sh` for `CONFIRM_BLOCK_CNT`
* missed    - scheduled at slot but no record of it in cncli DB and no other pool has made a block for this slot
* ghosted   - block created but marked as orphaned and no other pool has made a valid block for this slot, height battle or block propagation issue
* stolen    - another pool has a valid block registered on-chain for the same slot
* invalid   - pool failed to create block, base64 encoded error message can be decoded with `echo <base64 hash> | base64 -d | jq -r`

If the node was elected to create blocks in the selected epoch it could look something like this:

**Summary**
```
 >> BLOCKS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Current epoch: 95

+--------+---------+----------+------------+---------+----------+---------+----------+
| Epoch  | Leader  | Adopted  | Confirmed  | Missed  | Ghosted  | Stolen  | Invalid  |
+--------+---------+----------+------------+---------+----------+---------+----------+
| 96     | 34      | 0        | 0          | 0       | 0        | 0       | 0        |
| 95     | 32      | 32       | 32         | 0       | 0        | 0       | 0        |
| 94     | 20      | 20       | 20         | 0       | 0        | 0       | 0        |
| 93     | 32      | 32       | 32         | 0       | 0        | 0       | 0        |
| 92     | 36      | 36       | 36         | 0       | 0        | 0       | 0        |
+--------+---------+----------+------------+---------+----------+---------+----------+

[h] Home | [b] Block View | [i] Info | [*] Refresh
```
**Epoch**
```
 >> BLOCKS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Current epoch: 95

+---------+----------+------------+---------+----------+---------+----------+
| Leader  | Adopted  | Confirmed  | Missed  | Ghosted  | Stolen  | Invalid  |
+---------+----------+------------+---------+----------+---------+----------+
| 15      | 13       | 13         | 0       | 0        | 0       | 0        |
+---------+----------+------------+---------+----------+---------+----------+

+-----+------------+----------+---------------------+--------------------------+-------+-------------------------------------------------------------------+
| #   | Status     | Block    | Slot / SlotInEpoch  | Scheduled At             | Size  | Hash                                                              |
+-----+------------+----------+---------------------+--------------------------+-------+-------------------------------------------------------------------+
| 1   | confirmed  | 2025531  | 10694026 / 23626    | 2020-11-11 03:54:02 CET  | 3     | 1051a2853812eda14f73e313f1a34889f04bdf76be2bfe5c581b1380e2d10ca2  |
| 2   | confirmed  | 2025607  | 10695745 / 25345    | 2020-11-11 04:22:41 CET  | 3     | bb60030c1888d5ed8c86a0486cf9c7d19dc298e13b8be13ef0bda75cea856379  |
| 3   | confirmed  | 2025781  | 10700470 / 30070    | 2020-11-11 05:41:26 CET  | 3     | 3f74582609c39c8b6d965f76cf4e9a898b1d3a7b764504388e707198ae9cd530  |
| 4   | confirmed  | 2025833  | 10701931 / 31531    | 2020-11-11 06:05:47 CET  | 3     | fe77bb854526d13df6e061c34a54fe5522f6ed6cba4391d6651a5a899b478149  |
| 5   | confirmed  | 2026020  | 10707379 / 36979    | 2020-11-11 07:36:35 CET  | 3     | 54433d1640b90a08ed5fa8c7d925498552b44fda9c0b7908a99ba44cf343ce59  |
| 6   | confirmed  | 2026146  | 10710255 / 39855    | 2020-11-11 08:24:31 CET  | 3     | f062350f7795e407d32acbe910fbb856d55ee53db55ac6eb88a92314f5fdfc4f  |
| 7   | confirmed  | 2031225  | 10836135 / 165735   | 2020-11-12 19:22:31 CET  | 3     | 587a8d235a880d4e709173bad21eda2cecfecf5be04bdab2acfea4d9f457286c  |
| 8   | confirmed  | 2031389  | 10840079 / 169679   | 2020-11-12 20:28:15 CET  | 3     | dd1c95ba4596457412dccec84767ad4e8861b218803c8fbaf66bb2b1f5de327c  |
| 9   | confirmed  | 2033012  | 10881542 / 211142   | 2020-11-13 07:59:18 CET  | 3     | 26a17109c28a2afc11ad86c375d26a55fa3f7badf601f8dbf85bd851ab7f1121  |
| 10  | confirmed  | 2033511  | 10894371 / 223971   | 2020-11-13 11:33:07 CET  | 3     | dd77c1da50d8453a170cf9d9a779d6307d897e524bf11a6bfc196adbc079f1e9  |
| 11  | confirmed  | 2036190  | 10960153 / 289753   | 2020-11-14 05:49:29 CET  | 3     | 5c3049b7c6fed33830e7e4e9ccf75a13a8360717d2fd8ae726e0b81d0d30675d  |
| 12  | confirmed  | 2037280  | 10987522 / 317122   | 2020-11-14 13:25:38 CET  | 3     | 0a87c2e3a978125728ea707441ad53689eb2b44f6b4c11a83a0b8b368261579b  |
| 13  | confirmed  | 2040016  | 11057713 / 387313   | 2020-11-15 08:55:29 CET  | 3     | 710d72eaf5fa84ed90a3d3ab4544fcdcd58be163029ead66e46e91bef45dfc78  |
| 14  | leader     | -        | 11061678 / 391278   | 2020-11-15 10:01:34 CET  | -     | -                                                                 |
| 15  | leader     | -        | 11078122 / 407722   | 2020-11-15 19:35:38 CET  | -     | -                                                                 |
+-----+------------+----------+---------------------+--------------------------+-------+-------------------------------------------------------------------+

[h] Home | [1] View 1 | [2] View 2 | [3] View 3 | [i] Info | [*] Refresh
```
