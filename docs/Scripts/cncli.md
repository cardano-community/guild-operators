!> Ensure the [Pre-Requisites](basics.md#pre-requisites) are in place before you proceed.

`cncli.sh` is a script to download and deploy [CNCLI](https://github.com/AndrewWestberg/cncli) created and maintained by Andrew Westberg. It's a community-based CLI tool written in RUST for low-level cardano-node communication. Usage is **optional** and no script is dependent on it. The main features include:

**PING**      - Validates that the remote server is on the given network and returns its response time. Utilized by gLiveView for peer analysis if available. 
**SYNC**      - Connects to a node(local or remote) and synchronizes blocks to a local sqlite database. 
**VALIDATE**  - Validates that a block hash or partial block hash is on-chain.
**LEADERLOG** - Calculates a stakepool's expected slot list. On MainNet and the official TestNet, leader schedule is available 1.5 days before the end of the epoch (`firstSlotOfNextEpoch - (3 * k / f)`).

##### Installation
`cncli.sh` script is not meant to be run manually, but instead used to deploy systemd services that run in the background to do the block scraping and validation automatically.  
The script rely on [Log Monitor](Scripts/logmonitor.md) to get the block hash of an adopted block. Required to be able to do the block validation.

Run `cncli.sh install` to download and install RUST and CNCLI. If a previous installation is found, RUST and CNCLI will be updated to the latest version.
In addition three systemd services are created. See above for the different purposes they serve. The validate and leaderlog commands require a synchronized database.

* cnode-cncli-sync.service
* cnode-cncli-leaderlog.service 
* cnode-cncli-validate.service

As usual, controlled by `sudo systemctl <status|start|stop|restart> <service name>`  
Make sure to set appropriate values according to [Configuration](#configuration) section before starting services.

Log output is handled by syslog and end up in the systems standard syslog file, normally `/var/log/syslog`. `journalctl -u <service>` can be used to check log. Other logging configurations are not covered here. 

##### View Collected Blocks
Best viewed in CNTools but as it's saved as regular JSON any text/JSON viewer could be used. Block data is saved to `BLOCKLOG_DIR` variable set in env file, by default `${CNODE_HOME}/guild-db/blocklog/`. One file is created for each epoch. 

See [Log Monitor](Scripts/logmonitor.md) for example output.

##### Configuration
You can override the values in the script at the User Variables section shown below. **POOL_ID** & **POOL_VRF_SKEY** need to be set in the script before starting the validation service. For the rest of the commented values, if the automatic detection do not provide the right information, uncomment and make adjustments. We would appreciate if you could also notify us by raising an issue against github repo.

```
POOL_ID=""                                # Required for leaderlog calculation, lower-case hex pool id
POOL_VRF_SKEY=""                          # Required for leaderlog calculation, path to pool's vrf.skey file
#CNCLI_DB="${CNODE_HOME}/guild-db/cncli"  # path to folder to hold sqlite db for cncli
#LIBSODIUM_FORK=/usr/local/lib            # path to IOG fork of libsodium
#SLEEP_RATE=20                            # time to wait until next check, used in leaderlog and validate (in seconds)
#CONFIRM_SLOT_CNT=300                     # require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=10                     # require at least these many blocks on top of minted before validating
#TIMEOUT_LEDGER_STATE=300                 # timeout in seconds for ledger-state query
```