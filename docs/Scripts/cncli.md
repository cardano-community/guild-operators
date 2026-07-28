!!! info "Reminder !!"
    Ensure the [Pre-Requisites](../basics.md#pre-requisites) are in place before you proceed.

!!! warning "cnode-only helper"
    `cncli.sh` and its operational services are installed only by the cnode
    profile. Dingo and Amaru deployments do not install them.

`cncli.sh` manages [CNCLI](https://github.com/cardano-community/cncli)
operations and services. CNCLI is a community CLI written in Rust for
low-level `cardano-node` communication. Its use is optional. The main features
include:

- **PING** - Validates that the remote server is on the given network and returns its response time. Utilized by `gLiveView` for peer analysis if available. 
- **SYNC** - Connects to a node (local or remote) and synchronizes blocks to a local `sqlite` database. 
- **VALIDATE** - Validates that a block hash or partial block hash is on-chain.
- **LEADERLOG** - Calculates a stake pool's expected slot list. On five-day
  networks such as mainnet, the next epoch's leader schedule is available
  about 1.5 days before the epoch boundary
  (`firstSlotOfNextEpoch - (3 * k / f)`).
- **SENDTIP** - Send node tip to [PoolTool](https://pooltool.io/) for network analysis and to show that your node is alive and well with a green badge.
- **SENDSLOTS** - Securely sends PoolTool the number of slots you have assigned for an epoch and validates the correctness of your past epochs.

#### Installation
`cncli.sh` script's main functions, `sync`, `leaderlog`, `validate` and PoolTool `sendslots`/`sendtip` are not meant to be run manually, but instead deployed as systemd services that run in the background to do the block scraping and validation automatically. Additional commands exist for manual execution to initiate the `sqlite` db, filling the blocklog DB with all blocks created by the pool known to the blockchain, migration of old cntoolsBlockCollector JSON blocklog, and re-validation of blocks and leaderlogs. See usage output below for a complete list of available commands.

CNCLI blocklog works without [Log Monitor](logmonitor.md). Log Monitor
historically provided faster adopted status and detected some invalid blocks,
but it is currently disabled because its parser has not been updated for the
current node tracing format.

1. Run `guild-deploy.sh -s c` to install the prebuilt CNCLI executable in
   `$HOME/.local/bin/cncli`. The selected release comes from
   `${NODE_HOME}/files/cnode-release.json`; that policy can resolve a rolling
   `latest` release or a pinned artifact without changing this command.
2. Let `cncli.sh` install the operational systemd units it owns:

   ``` bash
   # Install only sync, leaderlog, and validate (safe default)
   $CNODE_HOME/scripts/cncli.sh -d

   # Install sync, leaderlog, validate, sendslots, and sendtip
   $CNODE_HOME/scripts/cncli.sh systemd install all
   ```

   If PoolTool integration is not configured, install only the core units and add either PoolTool unit later:

   ``` bash
   $CNODE_HOME/scripts/cncli.sh systemd install core
   $CNODE_HOME/scripts/cncli.sh systemd install ptsendslots
   $CNODE_HOME/scripts/cncli.sh systemd install ptsendtip
   ```

3. Inspect or remove the same scopes with `systemd status` or `systemd remove`. For example:

   ``` bash
   $CNODE_HOME/scripts/cncli.sh systemd status core
   $CNODE_HOME/scripts/cncli.sh systemd remove all
   ```

- `cnode-cncli-sync.service`
- `cnode-cncli-leaderlog.service`
- `cnode-cncli-validate.service`
- `cnode-cncli-ptsendtip.service`
- `cnode-cncli-ptsendslots.service`

The prefix comes from `CNODE_VNAME` and defaults to `cnode`. The CNCLI metrics exporter is intentionally separate from these five operational units; continue to manage it with `cncli.sh metrics deploy`.

#### Configuration
You can override the values in the script at the User Variables section shown below. **POOL_ID**, **POOL_VRF_SKEY** and **POOL_VRF_VKEY** should automatically be detected if `POOL_NAME` is set in the common `env` file and can be left commented. **PT_API_KEY** and **POOL_TICKER** need to be set in the script if PoolTool `sendtip`/`sendslots` are to be used before starting the services. For the rest of the commented values, if the defaults do not provide the right values, uncomment and make adjustments.

```
#POOL_ID=""                               # Automatically detected if POOL_NAME is set in env. Required for leaderlog calculation & pooltool sendtip, lower-case hex pool id
#POOL_ID_BECH32=""                        # Automatically detected if POOL_NAME is set in env. Required for Koios leaderlog queries, lower-case bech32 pool id
#POOL_VRF_SKEY=""                         # Automatically detected if POOL_NAME is set in env. Required for leaderlog calculation, path to pool's vrf.skey file
#POOL_VRF_VKEY=""                         # Automatically detected if POOL_NAME is set in env. Required for block validation, path to pool's vrf.vkey file
#PT_API_KEY=""                            # POOLTOOL: set API key, e.g "a47811d3-0008-4ecd-9f3e-9c22bdb7c82d"
#POOL_TICKER=""                           # POOLTOOL: set the pool ticker, e.g. "TCKR"
#PT_HOST="127.0.0.1"                      # POOLTOOL: connect to a remote node, preferably block producer (default localhost)
#PT_PORT="${CNODE_PORT}"                  # POOLTOOL: port of node to connect to (default CNODE_PORT from env)
#PT_SENDSLOTS_START=30                    # POOLTOOL sendslots: delay after epoch boundary before sending slots (minutes)
#PT_SENDSLOTS_STOP=60                     # POOLTOOL sendslots: stop sending after this many minutes
#CNCLI_DIR="${CNODE_HOME}/guild-db/cncli" # Path to the CNCLI SQLite database directory
#CNODE_HOST="127.0.0.1"                   # Node IP address; remote use can have a severe performance impact
#SLEEP_RATE=60                            # CNCLI leaderlog/validate: time to wait until next check (in seconds)
#CONFIRM_SLOT_CNT=600                     # CNCLI validate: require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=15                     # CNCLI validate: require at least these many blocks on top of minted before validating
#BATCH_AUTO_UPDATE=N                      # Set to Y to automatically update the script if a new version is available without user interaction
#CNCLI_PROM_PORT=12799                    # Prometheus port used by the metrics operation
```

#### Run
Services are controlled by `sudo systemctl <status|start|stop|restart> <service name>`.
The core units and `ptsendslots` follow the sync service, while `sync` and `ptsendtip` follow `cnode.service`. Starting or stopping the relevant parent therefore applies the same lifecycle to its installed child units.

Log output is handled by journald. `journalctl -f -u <service>` can be used to check service output (follow mode). Other logging configurations are not covered here. 

Recommended workflow to get started with CNCLI blocklog.

1. Install and deploy services according to [Installation](#installation) section.
2. Set required user variables according to [Configuration](#configuration) section.
3. (**optional**) If a previous blocklog db exist created by cntoolsBlockCollector, run this command to migrate json storage to new SQLite DB:
   * `$CNODE_HOME/scripts/cncli.sh migrate <path>` where `<path>` is the
     directory containing all `blocks_<epoch>.json` files.
4. Start deployed services with:
   * `sudo systemctl start cnode-cncli-sync.service` (starts `leaderlog`, `validate` & `ptsendslots` automatically)
   * `sudo systemctl start cnode-cncli-ptsendtip.service` (**optional but recommended**)
   * alternatively restart the main service that will trigger a start of all services with:
   * `sudo systemctl restart cnode.service`
5. Run init command to fill the db with all blocks made by your pool known to the blockchain
   * `$CNODE_HOME/scripts/cncli.sh init`
6. Enjoy full blocklog automation and visit [View Blocklog](#view-blocklog) section for instructions on how to show blocks from the blocklog DB.

```
Usage: cncli.sh [operation <sub arg>]
       cncli.sh -d [core|all|ptsendtip|ptsendslots]
       cncli.sh systemd <install|remove|status> [all|core|ptsendtip|ptsendslots]
Script to run CNCLI. Operational systemd units are owned by this script.

-u          Skip the script update check (must be the first argument)
-d          Install operational CNCLI units (scope defaults to core)
systemd     Install, remove, or show operational CNCLI unit status (scope defaults to core)
sync        Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB (deployed as service)
leaderlog   One-time leader schedule calculation for current epoch, then continuously monitors and calculates schedule for coming epochs, 1.5 days before epoch boundary on the mainnet (deployed as service)
  force     Manually force leaderlog calculation and overwrite even if already done, exits after leaderlog is calculated
validate    Continuously monitor and confirm that the blocks made actually was accepted and adopted by chain (deployed as service)
  all       One-time re-validation of all blocks in blocklog db
  epoch     One-time re-validation of blocks in blocklog db for the specified epoch
epochdata   Recalculate leaderlogs to populate blocklog epoch history after sync and validation
  all       Recalculate all epochs
  epoch     Recalculate the specified epoch
ptsendtip   Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge (deployed as service)
ptsendslots Securely sends PoolTool the number of slots you have assigned for an epoch and validates the correctness of your past epochs (deployed as service)
  force     Submit PoolTool sendslots outside the configured time window
init        One-time initialization adding all minted and confirmed blocks to blocklog
migrate     One-time migration from old blocklog (cntoolsBlockCollector) to new format (post cncli)
  path      Path to the old cntoolsBlockCollector blocklog folder holding json files with blocks created
metrics     Print CNCLI block metrics in Prometheus format
  deploy    Install the separately managed CNCLI metrics exporter
  serve     Run the exporter process used by that service
```

#### View Blocklog
Best and easiest viewed in CNTools and `gLiveView` but the blocklog database is a SQLite DB so if you are comfortable with SQL, the `sqlite3` command can be used to query the DB. 

**Block status**

    - Leader    : Scheduled to make block at this slot
    - Ideal     : Expected/Ideal number of blocks assigned based on active stake (sigma)
    - Luck      : Leader slots assigned vs ideal slots for this epoch
    - Adopted   : Block created successfully
    - Confirmed : Block created validated to be on-chain with the certainty set in `cncli.sh` for `CONFIRM_BLOCK_CNT`
    - Missed    : Scheduled at slot but no record of it in CNCLI DB and no other pool has made a block for this slot
    - Ghosted   : Block created but marked as orphaned and no other pool has made a valid block for this slot -> height battle or block propagation issue
    - Stolen    : Another pool has a valid block registered on-chain for the same slot
    - Invalid   : Pool failed to create block, base64 encoded error message can be decoded with `echo <base64 hash> | base64 -d | jq -r`

=== "CNTools"
    Open CNTools and select `[b] Blocks` to open the block viewer.  
    Either select `Epoch` and enter the epoch you want to see a detailed view for or choose `Summary` to display blocks for last x epochs.

    If the node was elected to create blocks in the selected epoch it could look something like this:
    
    === "Summary"
      
        ```
         >> BLOCKS
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        Current epoch: 96
        
        +--------+---------------------------+----------------------+--------------------------------------+
        | Epoch  | Leader | Ideal | Luck     | Adopted | Confirmed  | Missed | Ghosted | Stolen | Invalid  |
        +--------+---------------------------+----------------------+--------------------------------------+
        | 96     | 34     | 31.66 | 107.39%  | 18      | 18         | 0      | 0       | 0      | 0        |
        | 95     | 32     | 30.57 | 104.68%  | 32      | 32         | 0      | 0       | 0      | 0        |
        +--------+---------------------------+----------------------+--------------------------------------+
        
        [h] Home | [b] Block View | [i] Info | [*] Refresh
        ```
      
    === "Epoch"
      
        ```
         >> BLOCKS
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        Current epoch: 96
        
        +---------------------------+----------------------+--------------------------------------+
        | Leader | Ideal | Luck     | Adopted | Confirmed  | Missed | Ghosted | Stolen | Invalid  |
        +---------------------------+----------------------+--------------------------------------+
        | 34     | 31.66 | 107.39%  | 18      | 18         | 0      | 0       | 0      | 0        |
        +---------------------------+----------------------+--------------------------------------+
        
        +-----+------------+----------+---------------------+--------------------------+-------+-------------------------------------------------------------------+
        | #   | Status     | Block    | Slot | SlotInEpoch  | Scheduled At             | Size  | Hash                                                              |
        +-----+------------+----------+---------------------+--------------------------+-------+-------------------------------------------------------------------+
        | 1   | confirmed  | 2043444  | 11142827 | 40427    | 2020-11-16 08:34:03 CET  | 3     | ec216d3fb01e4a3cc3e85305145a31875d9561fa3bbcc6d0ee8297236dbb4115  |
        | 2   | confirmed  | 2044321  | 11165082 | 62682    | 2020-11-16 14:44:58 CET  | 3     | b75c33a5bbe49a74e4b4cc5df4474398bfb10ed39531fc65ec2acc51f89ddce5  |
        | 3   | confirmed  | 2044397  | 11166970 | 64570    | 2020-11-16 15:16:26 CET  | 3     | c1ea37fd72543779b6dab46e3e29e0e422784b5fd6188f828ace9eabcc87088f  |
        | 4   | confirmed  | 2044879  | 11178909 | 76509    | 2020-11-16 18:35:25 CET  | 3     | 35a116cec80c5dc295415e4fc8e6435c562b14a5d6833027006c988706c60307  |
        | 5   | confirmed  | 2046965  | 11232557 | 130157   | 2020-11-17 09:29:33 CET  | 3     | d566e5a1f6a3d78811acab4ae3bdcee6aa42717364f9afecd6cac5093559f466  |
        | 6   | confirmed  | 2047101  | 11235675 | 133275   | 2020-11-17 10:21:31 CET  | 3     | 3a638e01f70ea1c4a660fe4e6333272e6c61b11cf84dc8a5a107b414d1e057eb  |
        | 7   | confirmed  | 2047221  | 11238453 | 136053   | 2020-11-17 11:07:49 CET  | 3     | 843336f132961b94276603707751cdb9a1c2528b97100819ce47bc317af0a2d6  |
        | 8   | confirmed  | 2048692  | 11273507 | 171107   | 2020-11-17 20:52:03 CET  | 3     | 9b3eb79fe07e8ebae163870c21ba30460e689b23768d2e5f8e7118c572c4df36  |
        | 9   | confirmed  | 2049058  | 11282619 | 180219   | 2020-11-17 23:23:55 CET  | 3     | 643396ea9a1a2b6c66bb83bdc589fa19c8ae728d1f1181aab82e8dfe508d430a  |
        | 10  | confirmed  | 2049321  | 11289237 | 186837   | 2020-11-18 01:14:13 CET  | 3     | d93d305a955f40b2298247d44e4bc27fe9e3d1486ef3ef3e73b235b25247ccd7  |
        | 11  | confirmed  | 2049747  | 11299205 | 196805   | 2020-11-18 04:00:21 CET  | 3     | 19a43deb5014b14760c3e564b41027c5ee50e0a252abddbfcac90c8f56dc0245  |
        | 12  | confirmed  | 2050415  | 11316075 | 213675   | 2020-11-18 08:41:31 CET  | 3     | dd2cb47653f3bfb3ccc8ffe76906e07d96f1384bafd57a872ddbab3b352403e3  |
        | 13  | confirmed  | 2050505  | 11318274 | 215874   | 2020-11-18 09:18:10 CET  | 3     | deb834bc42360f8d39eefc5856bb6d7cabb6b04170c842dcbe7e9efdf9dbd2e1  |
        | 14  | confirmed  | 2050613  | 11320754 | 218354   | 2020-11-18 09:59:30 CET  | 3     | bf094f6fde8e8c29f568a253201e4b92b078e9a1cad60706285e236a91ec95ff  |
        | 15  | confirmed  | 2050807  | 11325239 | 222839   | 2020-11-18 11:14:15 CET  | 3     | 21f904346ba0fd2bb41afaae7d35977cb929d1d9727887f541782576fc6a62c9  |
        | 16  | confirmed  | 2050997  | 11330062 | 227662   | 2020-11-18 12:34:38 CET  | 3     | 109799d686fe3cad13b156a2d446a544fde2bf5d0e8f157f688f1dc30f35e912  |
        | 17  | confirmed  | 2051286  | 11336791 | 234391   | 2020-11-18 14:26:47 CET  | 3     | bb1beca7a1d849059110e3d7dc49ecf07b47970af2294fe73555ddfefb9561a8  |
        | 18  | confirmed  | 2051734  | 11348498 | 246098   | 2020-11-18 17:41:54 CET  | 3     | 87940b53c2342999c1ba4e185038cda3d8382891a16878a865f5114f540683de  |
        | 19  | leader     | -        | 11382001 | 279601   | 2020-11-19 03:00:17 CET  | -     | -                                                                 |
        | 20  | leader     | -        | 11419959 | 317559   | 2020-11-19 13:32:55 CET  | -     | -                                                                 |
        | 21  | leader     | -        | 11433174 | 330774   | 2020-11-19 17:13:10 CET  | -     | -                                                                 |
        | 22  | leader     | -        | 11434241 | 331841   | 2020-11-19 17:30:57 CET  | -     | -                                                                 |
        | 23  | leader     | -        | 11435289 | 332889   | 2020-11-19 17:48:25 CET  | -     | -                                                                 |
        | 24  | leader     | -        | 11440314 | 337914   | 2020-11-19 19:12:10 CET  | -     | -                                                                 |
        | 25  | leader     | -        | 11442361 | 339961   | 2020-11-19 19:46:17 CET  | -     | -                                                                 |
        | 26  | leader     | -        | 11443861 | 341461   | 2020-11-19 20:11:17 CET  | -     | -                                                                 |
        | 27  | leader     | -        | 11446997 | 344597   | 2020-11-19 21:03:33 CET  | -     | -                                                                 |
        | 28  | leader     | -        | 11453110 | 350710   | 2020-11-19 22:45:26 CET  | -     | -                                                                 |
        | 29  | leader     | -        | 11455323 | 352923   | 2020-11-19 23:22:19 CET  | -     | -                                                                 |
        | 30  | leader     | -        | 11505987 | 403587   | 2020-11-20 13:26:43 CET  | -     | -                                                                 |
        | 31  | leader     | -        | 11514983 | 412583   | 2020-11-20 15:56:39 CET  | -     | -                                                                 |
        | 32  | leader     | -        | 11516010 | 413610   | 2020-11-20 16:13:46 CET  | -     | -                                                                 |
        | 33  | leader     | -        | 11518958 | 416558   | 2020-11-20 17:02:54 CET  | -     | -                                                                 |
        | 34  | leader     | -        | 11533254 | 430854   | 2020-11-20 21:01:10 CET  | -     | -                                                                 |
        +-----+------------+----------+---------------------+--------------------------+-------+-------------------------------------------------------------------+
        ```

=== "gLiveView"

    Currently shows a block summary for current epoch. For full block details use CNTools for now. Invalid, missing, ghosted and stolen blocks only shown in case of a non-zero value.

      ```
      │--------------------------------------------------------------│
      │ BLOCKS   Leader  | Ideal  | Luck    | Adopted | Confirmed    │
      │          24        27.42    87.53%    1         1            │
      │          08:07:57 until leader XXXXXXXXX.....................│
      └────────────────────────────────────────────────────────────────────┘
      ```
