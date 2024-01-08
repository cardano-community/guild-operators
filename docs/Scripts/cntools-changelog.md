All notable changes to this tool will be documented in this file.

!!! info ""
    Whenever you're updating between versions where format/hash of keys have changed , or you're changing networks - it is recommended to Backup your Wallet and Pool folders before you proceed with launching cntools on a fresh network.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [11.0.2] - 2023-10-30
#### Fixed
- Fix additional Ada printing. Now omits trailing zeros from fraction part of Ada output.

## [11.0.1] - 2023-10-25
#### Fixed
- Fix display for Pool Cost and Pledge to accept integer as well as decimal format of ADA

## [11.0.0] - 2023-07-05
#### Changed
- CNTools now part of Koios brand

## [10.4.0] - 2023-06-19
#### Added
- Support for SRV records
- Support for cardano-node 8.1.1

## [10.3.1] - 2023-06-03
#### Fixed
- Backup didn't properly exclude private keys

## [10.3.0] - 2023-05-18
### Added
- Support for voting as per [CIP-0094](https://github.com/cardano-foundation/CIPs/blob/8fd78f984b6b6686b33932713890b16ee571081b/CIP-0094/README.md)

## [10.2.3] - 2023-04-28
#### Fixed
- Additional HW signing fixes

## [10.2.2] - 2023-04-24
#### Fixed
- Add special case handling for hardware wallets to use stake keys as witness for registering stake address

## [10.2.1] - 2023-04-04
#### Fixed
- Moved `test_koios` call from cntools.library to cntools.sh

## [10.2.0] - 2023-03-13
#### Fixed
- HW signing fix due to deprecated cardano-hw-cli sign call.
- The check whether to use Koios API or not (env config) wasn't properly handled.
#### Changed
- Disabled Koios for balance lookup to prefer local node check. In most circumstances this will be faster due to low latency. If needed, set WALLET_SELECTION_FILTER_LIMIT in cntools.sh to a lower limit to skip balance lookup on wallet selection if you have many wallets and delay is too long.

## [10.1.1] - 2023-02-07
#### Fixed
- Disable `dialog` by default, it is an optional component - and no longer installed by default.

## [10.1.0] - 2023-01-17
#### Added
- Hardware Wallets: Allow signing using cold keys for a pool, use it for rotating KES keys.

#### Changed
- Keep deployment consistent with guild-deploy.sh

#### Fixed
- Fix parsing space in the name of assets

## [10.0.5] - 2022-11-07
#### Changed
- Updated testnet token registry to be reused for each non-mainnet network
- Remove stale code for remote chain analysis

## [10.0.4] - 2022-08-26
#### Changed
- Allow pool cost to use fraction of ADA
- Starts using koios-1.0.7 endpoints to fetch information

#### Fixed
- Fixes an issue with reusage of variable name and updated param name for cardano-cli.
- Fix token minting and burn assets

## [10.0.3] - 2022-08-16
#### Fixed
- env file was sourced after calling cntools.library, overriding test_koios result

## [10.0.2] - 2022-08-13
#### Fixed
- Bump min cardano-hw-cli version to 1.10.0
- Requires cardano-hw-cli to be present on online node for pool registration/modification to be able to transform tx if needed
- Transform tx if needed before any witnessing/signing is done.
- Wrong arguments in call to cardano-hw-cli for cddl-formatted tx

## [10.0.1] - 2022-07-14
#### Changed
- Transactions now built using cddl-format to ensure that the formatting of transaction adheres the ledger specs.
- Default to mary era transaction building format for now.
#### Fixed
- Cold signing fix for pool registration / update. Last key was added twice when assemling witnesses.

## [10.0.0] - 2022-06-28
#### Added
- Support for Vasil Fork
- Preliminary support for Post HF updates (a short release will follow post fork in coming days)
- Minimum version for Node bumped to 1.35.0

#### Changed
- Pool > Rotate code now uses kes-periodinfo CLI query to get counter from node (fallback for Koios)
- Pool > Show Info updated to include current KES counter
- Update getEraIdentifier to include Babbage era

## [9.1.0] - 2022-05-11
#### Changed
- Harmonize flow for reusing old wallet configuration on pool modification vs setting new wallets.
- Remove the requirement for reward stake signing key in wallet registration/modification
- Reward wallet no longer auto-delegated on pool registration just like for multi-owners. 

## [9.0.10] - 2022-05-03
#### Fixed
- Detect if cardano-hw-cli has execution permission

## [9.0.9] - 2022-03-14
#### Changed
- Add version (-v) argument to cntools script to print current version

## [9.0.8] - 2022-03-07
#### Changed
- Remove HASH_IDENTIFIER variable references (Ddz issue which required this seperation was resolved a while ago)
- Replace NETWORKID check with NWMAGIC variable

## [9.0.7] - 2022-03-02
#### Fixed
- Call Test Koios function at start of CNTools, instead of calling by default every time env is sourced

## [9.0.6] - 2022-02-20
#### Fixed
- Fix for update check if not executed from default scripts folder.

## [9.0.5] - 2022-02-16
#### Fixed
- Script update code fixed to better handle in-app update. Would sometimes update but not source library correctly.

## [9.0.4] - 2022-02-14
#### Fixed
- Update request for pool_info endpoint from Koios

## [9.0.3] - 2022-02-01
#### Added
- Add a config variable TX_TTL to allow transaction to be valid (by default for 3600 slots) from the point of creation - previous default of 10 minutes on mainnet could be hit-and-miss with the state of network.

## [9.0.2] - 2022-01-22
#### Changed
- Add decimal param to token metadata creator and increase ticker max length to 9 chars according to spec changes.

## [9.0.1] - 2022-01-17
#### Changed
- Removing tool credits in offline metadata registry due to "out of protocol".

## [9.0.0] - 2022-01-10
#### Changed
- Due to changes in cardano-node 1.33.x -> for utxo ledger lookup and previous heavy pool-params query, Koios API is now the default option for these lookups.
  - You can update KOIOS_API env variable to connect to a local instance of koios (open source and incentivises all to build a decentralised query layer) if you'd not like to connect to remote instance.
  - Visit the https://www.koios.rest/ for more information about Koios or check out the API documentation at https://api.koios.rest.
  - If you'd like to revert to old behaviour (use CLI which could be slow to retrieve UTxOs), you can set ENABLE_KOIOS environment variable to N.

## [8.8.2] - 2021-12-28
#### Fixed
- Transform txBody using canonical order before signing/witnessing in case of HW wallet.
- Bump minimum HW wallet versions:
  - Ledger >= 3.0.0
  - Trezor >= 2.4.3
  - cardano-hw-cli >= 1.9.0

## [8.8.1] - 2021-12-18
#### Fixed
- Fallback to Mary era in build commands to keep ledger compatibility

## [8.8.0] - 2021-12-15
#### Fixed
- Asset handling after cardano-node 1.32.1 version bump. ascii -> hex change in cardano-cli.

## [8.7.3] - 2021-11-30
#### Fixed
- Remove stale cntools.config comments

## [8.7.2] - 2021-11-08
#### Changed
- Remove check if pool reward wallet is a hw wallet, enforce that its also a multi-owner to the pool

## [8.7.1] - 2021-11-04
#### Fixed
- Balance check of wrong wallet in certain circumstances for pool modify

## [8.7.0] - 2021-10-05
#### Changed
- CNTools configuration moved from cntools.config to cntools.sh

## [8.6.6] - 2021-09-26
#### Fixed
- Pool rotation date calculation fix, 8.6.4 didn't properly fix it

## [8.6.5] - 2021-09-15
#### Fixed
- Minimum utxo output calculation post Alonzo

## [8.6.4] - 2021-09-14
#### Fixed
- Pool rotation date calculation fix (display only)

## [8.6.3] - 2021-08-31
#### Fixed
- Pool retire fix

## [8.6.2] - 2021-08-30
#### Fixed
- Revert `--whole-utxo` flag, as it returns all address and will not accept `--address`

## [8.6.1] - 2021-08-27
##### Changed
- Alonzo related changes for era and minimum utxo.

## [8.6.0] - 2021-08-27
##### Changed
- Add `--whole-utxo` flag when query UTxO, as required by cardano-cli 1.28, to keep behaviour same as before.
- Baseline compatibility with 1.29

## [8.4.15] - 2021-07-15
##### Changed
- Switch default to 'No' adding a message when sending funds

## [8.4.14] - 2021-07-14
##### Fixed
- Fix for upcoming unreleased dbsync rest endpoint 

## [8.4.13] - 2021-07-08
##### Changed
- Documentation references updated to new site layout

## [8.4.12] - 2021-06-28
##### Fixed
- Pre-source env in offline/online mode for checkUpdate depending on argument provided to cntools.sh

## [8.4.11] - 2021-06-25
##### Changed
- KES calculation moved from CNTools & gLiveView into a common function in env file. For online mode node metrics is used for KES expiration instead of static pool KES start period.
- General message metadata support added to 'funds >> send' according to CIP-0020.

## [8.4.10] - 2021-06-15
##### Fixed
- Fix display issue for CLI that were upgraded to Alonzo-Blue networks

## [8.4.9] - 2021-06-15
##### Changed
- Handle Various updates to grest queries [disabled] to make them independent of instances.
Note: Version incremented thrice on PR branch itself

## [8.4.6] - 2021-06-04
##### Fixed
- Add balance check for main pool owner, that there is at least one utxo available
- Allow utxo without lovelace (for future when we might have tokens on utxo without Ada, like on Alonzo TestNet)
- pctToFraction helper function didn't properly handle 0 value

## [8.4.5] - 2021-05-31
##### Fixed
- Reset IFS at main loop, fixes invalid tip difference on home screen after going to Block > Summary

## [8.4.4] - 2021-05-19
##### Fixed
- Typo in Ledger ledger version requirement error and make it clearer that its the app version, not fw version.

## [8.4.3] - 2021-05-17
##### Fixed
- Token Mint/Burn script file signing not completely removed in all places (1.27.0 change)

## [8.4.2] - 2021-05-16
##### Fixed
- cardano-hw-cli version limited to 1.2.0 for current Trezor fw v2.3.6. Please manually downgrade version, available at https://github.com/vacuumlabs/cardano-hw-cli/releases , placing files in $HOME/bin/cardano-hw-cli

## [8.4.1] - 2021-05-16
##### Changed
- Wallet >> Show no longer require payment.vkey to be present, as long as either payment or base .addr file(s) exist

## [8.4.0] - 2021-05-16
##### Added
- Compatibility with cardano-address 3.4.0 (while retaining support for 2.1.0)

## [8.3.0] - 2021-05-15
##### Added
- New env variable called PGREST_API and if set and reachable, used instead of local node queries and for advanced modes
- New library function isPoolRegistered() for verifying if a pool is registered or not using either simple reg cert file detection (if REST API not set/reachable) or proper dbsync lookup using REST API. Used by Pool >> Show|List|Register|Modify
- Option to mint/burn assets in hybrid mode
- Transaction >> Sign now automatically tries to find the correct signing keys instead of having the user manually select the correct files
- ** ADVANCED FEATURE ** - Chain Queries
  - Menu is dynamically built based on queries(JSON files) in DBSYNC_QUERY_FOLDER (env variable, default files/dbsync/queries) three levels deep.
  - A download option lets the user download the latest uploaded queries on Guild Operators GitHub site.
  - Query files
    - Contains menu path, description, variables, and queries(multiple)
    - Executes a predefined DBSync RPC/function through PostgREST API
    - Variables used in RPC call can either be user input, CNTools variables like EKG metrics, or an item in the result from a previous query(in the same query file)
    - Result from RPC call can either be printed or silent(only to be used for later query)
    - Output is printed as JSON
##### Changed
- Minimum node version bumped to 1.27.0
- Menu has been re-designed with both back & home options. Instead of returning to home menu after the completed operation user is returned to the last menu.
- Pool >> Show now use PostgREST API(if set), or the new pool-params cli query as fallback method.

##### Fixed
- 1.27.0 introduced a few changes in CLI commands for assets minting/burning

## [8.2.2] - 2021-05-02
##### Fixed
- KES expiration date fix

## [8.2.1] - 2021-04-26
##### Changed
- Make use of UPDATE_CHECK environment variable to skip any checks to internet by default

## [8.2.0] - 2021-04-18
##### Added
- Ability to create & update a Cardano Token Registry submission JSON file
  - Requires 'token-metadata-creator' tool, instructions to download/build this tool added to Guild Operators documentation:
  - https://cardano-community.github.io/guild-operators/Build/offchainMetadataTools
- Token Registry lookup in Wallet >> Show
- Token asset fingerprint generation according to https://github.com/cardano-foundation/CIPs/pull/64

##### Changed
- Redesigned input handling to be more flexible and improve output

## [8.1.6] - 2021-04-14
##### Changed
- Metadata creation now offer the choice to add a metadata JSON scaffold to see the required structure

##### Fixed
- Fixed metadata creation entering JSON metadata through text editor

## [8.1.5] - 2021-04-09
##### Fixed
- Offline mode fix to ignore error when sourcing env

## [8.1.4] - 2021-04-05
##### Changed
- Enhanced minimum utxo calculation (credits to Martin providing this)
  - based on calculations from https://github.com/intersectmbo/cardano-ledger/blob/master/doc/explanations/min-utxo-mary.rst
- Validation of wallet address balance on transactions improved

## [8.1.3] - 2021-04-01
##### Fixed
- Alignment fix in blocks table

## [8.1.2] - 2021-03-31
##### Changed
- Manual CNTools update replaced with automatic by asking to update on startup like the rest of the scripts in the guild repository. 
- Changelog truncated up to v6.0.0. Minor and patch version changelog entries merged with next major release changelog.

## [8.1.1] - 2021-03-30
##### Fixed
- Relay registration condition
- Version number

## [8.1.0] - 2021-03-26

##### Added
- IPv6 support in pool registration/modification

##### Changed
- Wallet delegation now lets you specify Pool ID in addition to local CNTools pool instead of previous cold.vkey cbor string
- A couple of functions regarding number validation moved to common env file
- Code adapted for changes in ledger-state dump used by 'Pool >> Show'

##### Fixed
- Backup & restore now exclude gpg encrypted keys from online backup and suppression of false alarms

## [8.0.2] - 2021-03-15

##### Fixed
- Bump cardano-hw-cli minimum version to 1.2.0
- Add Ledger Cardano app version check with minimum enforced version of 2.2.0
- Add Trezor firmware check with minimum enforced version of 2.3.6

## [8.0.1] - 2021-03-05

##### Fixed
- Add BASH version check, version 4.4 or newer required

## [8.0.0] - 2021-02-28

##### Added
- Multi Asset Token compatibility added throughout all CNTools operations. 
  - Sending Ada and custom tokens is done through the normal 'Funds >> Send' operation

##### Changed
- Metadata moved to a new Advanced section used for devs/advanced operations not normally used by SPOs.
  - Accessed by enabling developer/advanced mode in cntools.config or by providing runtime flag '-a'
- Redesign of backup and restore.
  - Deletion of private keys moved from backup to new section under `Advanced`
  - Backup now only contain content of priv folder (files & scripts folders dropped)
  - Restore operation now restore directly to priv folder instead of a random user selected folder to make restore easier and better. Before restore, a new full backup of priv folder is made and stored encrypted in priv/archive
  
##### Fixed
- JQ limitation workaround for large numbers
- Dialog compatibility improvement by preventing dialog launching a subshell on some systems causing dialog not to run

## [7.1.6] - 2021-02-10
- Update curl commands when file isnt downloaded correctly (to give correct return code)

## [7.1.5] - 2021-02-03

##### Changed
- Guild Announcement/Support Telegram channel added to CNTools GUI

##### Fixed
- Fix for a special case using an incomplete wallet (missing stake keys) 

## [7.1.4] - 2021-02-01

##### Fixed
- Typo in function name after harmonization between scripts

## [7.1.3] - 2021-01-30

##### Fixed
- Vacuumlabs cardano-hw-cli 1.1.3 support, now the minimum supported version
- Improved error handling

## [7.1.1] - 2021-01-29

##### Changed
- Minor change to future update notification for common env file

## [7.1.0] - 2021-01-29

##### Changed
- Remove ChainDB metrics references to align with cardano-node 1.25.1
- Moved some functions to env for reusability between tools

## [7.0.2] - 2021-01-17

##### Changed
- Re-add the option in offline workflow to use wallet folder that only contains stake keys for multi-owner pools

##### Fixed
- Verification of signing key in offline mode for extended signing keys (mnemonics imported wallets)

## [7.0.1] - 2021-01-13

##### Changed
- Add prompt before updating common env file, instead of auto-update

## [7.0.0] - 2021-01-11
Though mostly unchanged in the user interface, this is a major update with most of the code re-written/touched in the back-end.  
Only the most noticeable changes added to changelog. 

##### Added
- HW Wallet support through Vacuumlabs cardano-hw-cli (Ledger Nano X/S & Trezor T)
  - Vacuumlabs cardano-hw-cli added as build option to prereqs.sh, option '-w' incl Ledger udev rules. Software from Vacuumlabs and Ledger app still early in development and may contain limitations that require workarounds. Users are recommended to familiarise their usage using test wallets first.
  - Because of HW wallet support, transaction signing has been re-designed. For CLI and HW wallet pool reg, raw tx is first witnessed by all signing keys separately and then assembled and signed instead of signing directly with all signing keys. But for all other HW wallet transactions, signing is done directly without first witnessing.
  - Requires updated Cardano app in Ledger/Trezor set to be released in January 2021 to use in pool registration/modification.
- Option added to disable Dialog for file/dir input in cntools.config

##### Changed
- Logging completely re-designed from the ground. Previous selective logging wasn't very useful. All output(almost) now outputted to both the screen and to a timestamped log file. One log file is created per CNTools session. Old log file archived in logs/archive subfolder and last 10 log files kept, rest is pruned on CNTools startup.
  - DEBUG    : Verbose output, most output printed on screen is logged as debug messages except explicitly disabled, like menu printing.
  - INFO     : Informational and the most important output.
  - ACTION   : e.g cardano-cli executions etc
  - ERROR    : error messages and stderr output
- Verbosity setting in cntools.config removed.
- Offline workflow now use a single JSON transaction file holding all data needed. This allows us to bake in additional data in the JSON file in addition to the tx body to make it much more clear what the offline transaction do. Like signing key verification, transaction data like fee, source wallet, pool name etc. It also lets the user know on offline computer what signing keys is needed to sign the transaction.
  - Sign Tx moved to Transaction >> Sign
  - Submit Tx moved to Transaction >> Submit

##### Fixed
- Remove intermediate prompt for showing changelog, so that it's directly visible.

## [6.3.1] - 2020-12-14

##### Fixed
- Array expansion not correctly handled for multi-owner signing keys
- KES rotation output fix in OFFLINE mode, op.cert should be copied, not cold.counter
- Output and file explorer workflow redesigned a bit for a better flow
- formatLovelace() thousand separator fix after forcing locale to C.UTF-8 in env
- formatAda() function added to pretty print pledge and cost w/o Lovelace

## [6.3.0] - 2020-12-03

##### Changed
- printTable function replaced with bash printf due to compatibility issues
- Improved workflow in pool registration/modification for relays and multi-owner.
- Standardized names for wallet and pool files/folders moved to env file from cntools.config
- Compatibility with 1.24.2 node (accomodate ledger schema and CLI changes), use 1.24.2 as baseline
- Move version check to env

##### Fixed
- Error output for prerequisite checks
 
## [6.2.1] - 2020-11-28

##### Changed
- Compatibility changes for cardano-node 1.23.0, now minimum version to run CNTools 6.2.1
- Cleanup of old code

## [6.2.0] - (alpha branch)

##### Added
- Ability to post metadata on-chain, e.g. (but not limited to) Adams https://vote.crypto2099.io/

##### Changed
- Blocks view updated to adapt to the added CNCLI integration and changes made to block collector(logMonitor)
  - [CNCLI](https://cardano-community.github.io/guild-operators/Scripts/cncli)
  - [Log Monitor](https://cardano-community.github.io/guild-operators/Scripts/logmonitor)
- chattr file locking now optional to use, a new setting in cntools.config added for it.

##### Fixed
- unnecessary bech32 conversion in wallet import (non-breaking) 

## [6.1.0] - 2020-10-22

##### Added
- Wallet de-registration with key deposit refund (new cntools.config parameter, WALLET_STAKE_DEREG_FILENAME)
- Default values loaded for all config variables if omitted/missing in cntools.config

##### Changed
- Prometheus node metrics replaced with EKG
- Allow and handle missing pool.config in pool >> modify and show
- Cancel and return added in several helper functions if cardano-cli execution fails
- Various tweaks to the output

##### Fixed
- Script execution permissions after internal update
- Handle redirect in curl metadata fetch

## [6.0.3] - 2020-10-16

#### Fixed
- Shelley epoch transition calculation used the wrong byron metric in the calculation

## [6.0.2] - 2020-10-16

#### Fixed
- Internal update had the wrong path to env file breaking automatic update, please use prereqs.sh to update
- Fix in 6.0.1 broke pool id retrieval, now compatible with both pre and post cardano-node 1.21.2 syntax.

## [6.0.1] - 2020-10-16

#### Fixed
- As per change to cardano-cli syntax, pool ID requires `--cold-verification-key-file` instead of `--verification-key-file`


## [6.0.0] - 2020-10-15

> This is a major release with a lot of changes. It is highly recommended that you familiarise yourself with the usage for Hybrid or Online v/s Offline mode on a testnet environment before doing it on production. Please visit https://cardano-community.github.io/guild-operators/upgrade for details.

##### Added
- Allow CNTools to operate in offline mode. Offline features include:
  - Simplified Walet Show/List menu
  - Wallet delete without balance check option
  - Pool KES Rotation
  - Sign a staging transaction.
- Allow creation of staging tx files using ttl as input in an online/offline-hybrid mode, that can be sent to offline server to sign.
  - To Transfer Funds
  - Withdraw Rewards
  - Delegate
  - Register/Modify/Retire pool
- Allow import of a signed transaction to submit in online mode
- Allow import of 15/24 words based wallets. Note that you'd need `cardano-address` and `bech32` in yout $PATH to use this feature (available if you rebuild `cardano-node` using updated `cabal-build-all.sh`), reusing [guide from @ilap](https://gist.github.com/ilap/3fd57e39520c90f084d25b0ef2b96894).
- Backup now offer the ability to create an online backup without wallet payment/stake and pool cold sign keys
- Regular(offline) backup now display a warning if wallet payment/stake and pool cold sign keys are missing due to being deleted manually or by previous backup
- Retire notification in pool >> show
- Sanity check before launching a second instance of cnode.sh
- Doc update to run cnode.sh as a systemd service
- Use secure remove (`srm`) when available when deleting files.
- Balance check notification added before wallet selection menus are shown to know that work is done in the background
- Ability to select a different pool owner and reward wallet
- Multi-owner support using stake vkey/skey files
- Added TIMEOUT_LEDGER_STATE(default 300s) in cntools.config to be used instead of static 60 seconds for querying shelley ledger-state.
- Option to delete private keys after successful backup
- itnRewards.sh script to claim ITN rewards incl docs update
- More explicit error messages at startup
- Basic sanity checks for socket file
- Backup & Restore of wallets, pools and configuration files
- External KES rotation script using CNTools library
- Add few flags to control prereqs to allow skipping overwriting files, deploying OS packages, etc
- cntools.sh: Drop an error if log not found, indicating config with no JSON being used

##### Changed
- Improved trap/exit handling
- Allow thousand separator(`,`) in user input for sending ADA and pledge/cost at pool registration to make it easier to count the zeros
- User input for files and directories now open a dialog gui to make it easier to find the correct path
- CNTools now uses and works with `cardano-node 1.19.0`, please upgrade if you're not using this version.
- Use manual calculation based on slot tip to get KES period
- Removed ledger dump dependency from Pool Register, Modify, Retire and List.
  - The cost of the ledger dump is too high, replaced with a simple check if pools registration certificate exist in pool folder
  - Pool >> Show|Delegators are now the only options dumping the ledger-state
- Wallet vkeys no longer encrypted as skeys are the only ones in need of protection
- Update command change (change applied after this release is active):
  - Minor/Patch release: it will warn, backup and replace CNTools script files including cntools.config
  - Major release: No change, prompt user to backup and run prereqs.sh according to instructions.
- Troubleshooting improvements:
  - Split 'config in json format' and 'hasPrometheus' checks
  - Output node sync stats if Shelley transition epoch is to be calculated
  - Protocol parameters output check to give an improved error message
- Pool >> Show view updated to show modified pool values if Pool >> Modify has been used to update pool parameters
  - The section has also been updated to make it a little bit easier to read
- Pool >> Delegators view also use updated pledge value if a pool modification has been registered to check if pledge is met
- Use mainnet as default, since other testnets are either retired or not being maintained :(
- Backup original files when doing upgrades, so that users do not lose their changes.
- Major update description updated
- env file update removed from minor update
- Prometheus metrics used for various functions and now required to run CNTools, enabled by default
- Changed references to ptn0 to generalize the usage
- Change CNTools changelog heading format - +1 sublevels for headings (used by newer documentation)
- Delegators previously displayed in `Pool >> Show` now moved to its own menu option
  This is to de-clutter and because it takes time to parse this data from ledger-state
- stake.cert no longer encrypted in wallet
- Meta description now has a limit of 255 chars to match smash server limit
- ledger-state timeout increased to 60s
- Update ptn0 config to align with hydra config as much as possible, while keeping trace options on
- moved update check to be one of the first things CNTools does after start to be able to show critical changes before anything else runs.
- Parse node logs to check the transition from Byron to shelley era, and save the epoch for transition in db folder. This is required for calculating KES keys.
  - Please make sure to use **config files created by the prereqs.sh, or enable JSON loggers for your config**.
- Update cnode.sh.templ to archive logs every time node is restart, this ensures that we're not searching for previous log history when network was changed. Network being changed would automatically deduce db folder was deleted.
- Update default network to MC3

##### Removed
- `Pool >> Delegators` removed.
  - If/when a better option than dumping and parsing ledger-state dump arise re-adding it will be considered. 
  - Utilize the community explorers listed at https://cardano-community.github.io/support-faq/explorers 
- POOL_PLEDGECERT_FILENAME removed from config, WALLET_DELEGCERT_FILENAME is used instead for delegation cert to pool, no need to keep a separate cert in pool folder for this, its the wallet that is delegated.
- Redundant sections in guide
- Stale delegate.counter

##### Fixed
- Check `pool >> show` stake distribution showing up as always 0.
- KES expiration calculation
- Slot interval calculation
- Custom vname replacement(when using `prereqs.sh -t`) fix for internal update
- Pool registration and de-registration certificates removed in case of retire/re-registration
- KES Expiry to use KES Period instead of Epoch duration
- Block Collector script adapted for cardano-node 1.19.0.
  - Block hash is now truncated in log, issue https://github.com/intersectmbo/cardano-node/issues/1738
- High cpu usage reported in a few cases when running Block Collector
  - Depending on log level, parsing and byte64 enc each entry with jq could potentially put high load on weaker systems. Replaced with grep to only parse entries containing specific traces.
- Docs for creating systemd block collector service file updated to include user env in run command
- cardano-node 1.19.0 introduced an issue that required us to use KES as current - 1 while rotating.
- A new getPoolID helper function added to extract both hex and bech32 pool ID
  - Added `--output-format hex` when extracting pool ID in hex format
  - A new pool.id-bech32 file gets created if cold.vkey is available and decrypted
- Added error check to see if cardano-cli is in $PATH before continuing.
- Backup & Restore paths were failing on machines due to alnum class availability on certain interpreters.
- Rewards were not counted in stake and pledge
- Removed +i file locking on .addr files when using `Wallet >> Encrypt` as these are re-generated from keys and need to be writable
- Balance check added to `Funds >> Withdraw` for base address as this is used to pay the withdraw transaction fee
- Resolve issue with Multi Owner causing an error with new pool registration (error was due to quotes)
- Mainnet uses dedicated condition for slot checks
- Timeout moved to a variable in cntools.library
- KES Calculation for current KES period and KES expiration date
  **Please re-check expiration date using Pool >> Show**
- calc_slots to be network independent
- prom_host should be calculated from config file, instead of having to update a config
- Minor typo in menu
- Parse Config for virtual forks, which adds supports for MC4
- CNTools block collector fix
- column application added as a prereq, bsdmainutils/util-linux
- cntoolsBlockCollector.sh get epoch using function
- KES count was not showing up in Katip
- Funds -> Delegation was broken as per recent changes in 1.17, corrected key type for delegation certificate
- `Pool >> Show` delegator rewards parsing from ledger-state
- Slot sync format improvement
- kesExpiration function to use 17 fixed byron transition epochs 


#### [5.0.0] - 2020-07-20

##### Added
- HASH_IDENTIFIER where applicable to differentiate between network modes for commands used, required due to legacy Byron considerations
- add ptn0-praos.json and ptn0-combinator.json to reduce confusion between formats, make prereqs default to combinator, and accept p argument to indicate praos mode.
- cardano-node 1.16.0 refers to txhash using quotes, sed them out
- show what's new at startup after update
- file size check for pool metadata file
- Add nonce in pool metadata JSON to keep registration attempts unique, avoiding one hash pointing to multiple URLs
- Change default network to `mainnet_candidate`, and add second argument (g) to run prereqs against guild network
- allow the use of pre-existing metadata from URL when registering or modifying pool
- minimum pool cost check against protocol
- Refresh option to home screen
- Ability to register multiple relay DNS A records as well as a mix of DNS A and IPv4
- Valid for pool registration and modification

##### Changed
- Default config switched to combinator instead of testnet
- Start maintaining seperate versions of praos and combinator config files.
- Add 10s timeout to wget commmands in case of issue
- timestamp added to pool metadata file to make every creation unique
- Cancel shortcut changed from `[c]` to `[Esc]`
- Default pool cost from 256 -> 400
- slotinterval calculation to include decentralisation parameter
- mainnet candidate compatible slot calculation, 17 fixed byron transition epochs (needs to be fixed for mainnet)
- Pool metadata information to copy file as-is as well as wait for keypress to make sure file is copied before proceeding with registration.
- Now use internal table builder to display previous relays
- Instead of giving relays from previous registration as default values it will now ask if you want to re-register relays exactly as before to minimize steps and complexity

##### Removed
- Delete cntools-updater script
- NODE_SOCKET_PATH config parameter(replaced by CARDANO_NODE_SOCKET_PATH)

##### Fixed
- Slots reference was mixing up for shelley testnet in absence of a combinator network
- numfmt dependency removed in favor of printf formatting
- Vkey delegation fix due to json format switch
- ADA not displayed in a couple of the wallet selection menus
- KES calculation support for both MC and Shelley Testnet
- Slot tip reference calculation for shelley testnet


#### [4.0.0] - 2020-07-13
##### Added
- Add PROTOCOL_IDENTIFIER and NETWORK_IDENTIFIER instead of harcoded entries for combinator v/s TPraos & testnet v/s magic differentiators respectively.
- Keep both ptn0.yaml and ptn0-combinator.yaml to keep validity with mainnet-combinator

##### Changed
- Revert back default for Public network to Shelley_Testnet as per https://t.me/CardanoStakePoolWorkgroup/282606


#### [3.0.0] - 2020-07-12
##### Added
- Basic health check data on main menu
  - Epoch, time until next epoch, node tip vs calculated reference tip and a warning if node is lagging behind.
- Address era and encoding to `Wallet >> Show`

##### Changed
- Release `2.1.1` included a change to env file and thus require a major version bump.
- Modified output on Update screen slightly.
- KES calculation, now take into account the byron era and the transition period until shelley start
  - Credit to Martin @ ATADA for inspiration on how to calculate this

##### Fixed
- Version fix to include patch version


#### [2.0.0] - 2020-07-12
##### Added
- Support for cardano-node 1.15.x  
  - calculate-min-fee update to reflect change in 1.15.  
    change was required to support byron witnesses.
  - gettip update as output is now json formatted
  - bech32 addressing in 1.15 required changes to delegator lookup in `Pool >> Show`
  - add --cardano-mode to query parameters
  - --mainnet flag for address generation
- Output verbosity  
  A new config parameter added for output verbosity using say function.  
  0 = Minimal - Show relevant information (default)  
  1 = Normal  - More information about whats going on behind the scene  
  2 = Maximal - Debug level for troubleshooting
- Improve delegators list in `Pool >> Show`
  - Identify owners delegations
  - Display owner stake in red if `(stake + reward)` is below pledge (single-owner only for now)
- Display all lovelace values in floating point ADA with 6 decimals (lovelaces) using locales
- Block Collector summary view
- KES rotation notification/warning on startup and in pool list/show views
- Live stake and delegators in `Pool >> Show`
- Changelog 

##### Changed
- op-cert creation moved from `Pool >> New` to `Pool >> Register`.
- Output changed in various places throughout.
- Include reward in delegators stake.
- Release now include patch version in addition to major and minor version.  
  In-app update modified to reflect this change.
- Block Collector table view
- Various minor code improvements
  
##### Removed
- Enterprise wallet upgrade option in `Wallet >> List` 
- `Not a registered wallet on chain` information from Wallet listing
- en_US.UTF-8 locale dependency

##### Fixed
- meta_json_url check
- Invalid tx_in when registering stake wallet
- Delegators rewards in `Pool >> Show`
- Work-around awk versions that only support 32-bit integers
- Sometimes cardano-node log contain duplicate traces for the same slot at log file rollover, now filtered
- Correct nwmagic - was hardcoded to 42
- Set script locale to fix format issue


#### [1.0.0] - 2020-07-07
- First official major release
