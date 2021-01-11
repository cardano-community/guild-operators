All notable changes to this tool will be documented in this file.

!> Whenever you're updating between versions where format/hash of keys have changed , or you're changing networks - it is recommended to Backup your Wallet and Pool folders before you proceed with launching cntools on a fresh network.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  - [CNCLI](https://cardano-community.github.io/guild-operators/#/Scripts/cncli)
  - [Log Monitor](https://cardano-community.github.io/guild-operators/#/Scripts/logmonitor)
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

> This is a major release with a lot of changes. It is highly recommended that you familiarise yourself with the usage for Hybrid or Online v/s Offline mode on a testnet environment before doing it on production. Please visit https://cardano-community.github.io/guild-operators/#/upgrade for details.

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

##### Changed
- Improved trap/exit handling
- Allow thousand separator(`,`) in user input for sending ADA and pledge/cost at pool registration to make it easier to count the zeros
- User input for files and directories now open a dialog gui to make it easier to find the correct path

##### Fixed
- Check `pool >> show` stake distribution showing up as always 0.
- KES expiration calculation
- Slot interval calculation
- Custom vname replacement(when using `prereqs.sh -t`) fix for internal update
- Pool registration and de-registration certificates removed in case of retire/re-registration


## [5.4.1] - 2020-09-10

##### Fixed
- KES Expiry to use KES Period instead of Epoch duration


## [5.4.0] - 2020-08-23

> A non-breaking change have been made to files outside of CNTools. Internal update function is not enough to update all files.  
> - Execute the below (by default it will set you up against mainnet network), do not overwrite config please:  
>    `cd "$CNODE_HOME"/scripts`  
>    `curl -sS -o prereqs.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/prereqs.sh`  
>    `chmod 755 prereqs.sh`  
>    `./prereqs.sh -s`  
> - Start using updated cnode.sh to run a passive node, or edit the cnode.sh to include your pool keys and run as pool owner.

=======

##### Added
- Sanity check before launching a second instance of cnode.sh
- Doc update to run cnode.sh as a systemd service

##### Removed
- `Pool >> Delegators` removed.
  - If/when a better option than dumping and parsing ledger-state dump arise re-adding it will be considered. 
  - Utilize the community explorers listed at https://cardano-community.github.io/support-faq/#/explorers 

##### Fixed
- Block Collector script adapted for cardano-node 1.19.0.
  - Block hash is now truncated in log, issue https://github.com/input-output-hk/cardano-node/issues/1738
- High cpu usage reported in a few cases when running Block Collector
  - Depending on log level, parsing and byte64 enc each entry with jq could potentially put high load on weaker systems. Replaced with grep to only parse entries containing specific traces.
- Docs for creating systemd block collector service file updated to include user env in run command


## [5.3.6] - 2020-08-22

##### Fixed
- cardano-node 1.19.0 introduced an issue that required us to use KES as current - 1 while rotating.


## [5.3.5] - 2020-08-20

##### Changed
- CNTools now uses and works with `cardano-node 1.19.0`, please upgrade if you're not using this version.

##### Fixed
- A new getPoolID helper function added to extract both hex and bech32 pool ID
  - Added `--output-format hex` when extracting pool ID in hex format
  - A new pool.id-bech32 file gets created if cold.vkey is available and decrypted
- Added error check to see if cardano-cli is in $PATH before continuing.


## [5.3.4] - 2020-08-18

##### Changed
- Use manual calculation based on slot tip to get KES period

## [5.3.3] - 2020-08-14

##### Added
- Use secure remove (`srm`) when available when deleting files.


## [5.3.2] - 2020-08-05

##### Fixed
- Backup & Restore paths were failing on machines due to alnum class availability on certain interpreters.
- Rewards were not counted in stake and pledge

## [5.3.1] - 2020-08-04
##### Added
- Balance check notification added before wallet selection menus are shown to know that work is done in the background 

##### Changed
- Removed ledger dump dependency from Pool Register, Modify, Retire and List.
  - The cost of the ledger dump is too high, replaced with a simple check if pools registration certificate exist in pool folder
  - Pool >> Show|Delegators are now the only options dumping the ledger-state

##### Fixed
- Removed +i file locking on .addr files when using `Wallet >> Encrypt` as these are re-generated from keys and need to be writable
- Balance check added to `Funds >> Withdraw` for base address as this is used to pay the withdraw transaction fee
- Resolve issue with Multi Owner causing an error with new pool registration (error was due to quotes)


## [5.3.0] - 2020-08-03
##### Added
- Ability to select a different pool owner and reward wallet
- Multi-owner support using stake vkey/skey files
- Added TIMEOUT_LEDGER_STATE(default 300s) in cntools.config to be used instead of static 60 seconds for querying shelley ledger-state.
- Option to delete private keys after successful backup
- itnRewards.sh script to claim ITN rewards incl docs update
- More explicit error messages at startup

##### Changed
- POOL_PLEDGECERT_FILENAME removed from config, WALLET_DELEGCERT_FILENAME is used instead for delegation cert to pool, no need to keep a separate cert in pool folder for this, its the wallet that is delegated.
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

##### Fixed
- Mainnet uses dedicated condition for slot checks
- Timeout moved to a variable in cntools.library
- KES Calculation for current KES period and KES expiration date
  **Please re-check expiration date using Pool >> Show**


## [5.2.1] - 2020-07-29
##### Added
- Basic sanity checks for socket file

##### Fixed
- calc_slots to be network independent
- prom_host should be calculated from config file, instead of having to update a config


## [5.2.0] - 2020-07-28

##### Changed
- Major update description updated
- env file update removed from minor update 


## [5.1.0] - 2020-07-28
##### Added
- Backup & Restore of wallets, pools and configuration files
- External KES rotation script using CNTools library
- Add few flags to control prereqs to allow skipping overwriting files, deploying OS packages, etc

##### Fixed
- Minor typo in menu

##### Changed
- Prometheus metrics used for various functions and now required to run CNTools, enabled by default
- Changed references to ptn0 to generalize the usage
- Change CNTools changelog heading format - +1 sublevels for headings (used by newer documentation)
- Delegators previously displayed in `Pool >> Show` now moved to its own menu option
  This is to de-clutter and because it takes time to parse this data from ledger-state
- stake.cert no longer encrypted in wallet

##### Removed
- Redundant sections in guide

#### [5.0.6] - 2020-07-26
##### Fixed
- Parse Config for virtual forks, which adds supports for MC4


#### [5.0.5] - 2020-07-25
##### Fixed
- CNTools block collector fix


#### [5.0.4] - 2020-07-25
##### Added
- cntools.sh: Drop an error if log not found, indicating config with no JSON being used

##### Fixed
- column application added as a prereq, bsdmainutils/util-linux
- cntoolsBlockCollector.sh get epoch using function
- KES count was not showing up in Katip
- Funds -> Delegation was broken as per recent changes in 1.17, corrected key type for delegation certificate

##### Changed
- Meta description now has a limit of 255 chars to match smash server limit
- ledger-state timeout increased to 60s
- Update ptn0 config to align with hydra config as much as possible, while keeping trace options on

##### Removed
- Stale delegate.counter


#### [5.0.3] - 2020-07-24

##### Changed
- moved update check to be one of the first things CNTools does after start to be able to show critical changes before anything else runs.


#### [5.0.2] - 2020-07-24

##### Changed
- Parse node logs to check the transition from Byron to shelley era, and save the epoch for transition in db folder. This is required for calculating KES keys.
  - Please make sure to use **config files created by the prereqs.sh, or enable JSON loggers for your config**.
- Update cnode.sh.templ to archive logs every time node is restart, this ensures that we're not searching for previous log history when network was changed. Network being changed would automatically deduce db folder was deleted.
- Update default network to MC3

##### Fixed
- `Pool >> Show` delegator rewards parsing from ledger-state


#### [5.0.1] - 2020-07-22
##### Fixed
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

##### Changed
- Default config switched to combinator instead of testnet
- Start maintaining seperate versions of praos and combinator config files.
- Add 10s timeout to wget commmands in case of issue
- timestamp added to pool metadata file to make every creation unique
- Cancel shortcut changed from `[c]` to `[Esc]`
- Default pool cost from 256 -> 400
- slotinterval calculation to include decentralisation parameter
- mainnet candidate compatible slot calculation, 17 fixed byron transition epochs (needs to be fixed for mainnet)

##### Removed
- Delete cntools-updater script

##### Fixed
- Slots reference was mixing up for shelley testnet in absence of a combinator network


#### [4.3.0] - 2020-07-16
##### Added
- allow the use of pre-existing metadata from URL when registering or modifying pool
- minimum pool cost check against protocol

##### Removed
- NODE_SOCKET_PATH config parameter(replaced by CARDANO_NODE_SOCKET_PATH)

##### Changed
- Pool metadata information to copy file as-is as well as wait for keypress to make sure file is copied before proceeding with registration.


#### [4.2.2] - 2020-07-15
##### Fixed
- numfmt dependency removed in favor of printf formatting


#### [4.2.1] - 2020-07-15
##### Fixed
- Vkey delegation fix due to json format switch


#### [4.2.0] - 2020-07-15
##### Added
- Refresh option to home screen

##### Fixed
- ADA not displayed in a couple of the wallet selection menus


#### [4.1.0] - 2020-07-14
##### Added
- Ability to register multiple relay DNS A records as well as a mix of DNS A and IPv4
- Valid for pool registration and modification

##### Changed
- Now use internal table builder to display previous relays
- Instead of giving relays from previous registration as default values it will now ask if you want to re-register relays exactly as before to minimize steps and complexity


#### [4.0.2] - 2020-07-13
##### Fixed
- KES calculation support for both MC and Shelley Testnet


#### [4.0.1] - 2020-07-13
##### Fixed
- Slot tip reference calculation for shelley testnet


#### [4.0.0] - 2020-07-13
##### Added
- Add PROTOCOL_IDENTIFIER and NETWORK_IDENTIFIER instead of harcoded entries for combinator v/s TPraos & testnet v/s magic differentiators respectively.
- Keep both ptn0.yaml and ptn0-combinator.yaml to keep validity with mainnet-combinator

##### Changed
- Revert back default for Public network to Shelley_Testnet as per https://t.me/CardanoStakePoolWorkgroup/282606


#### [3.0.0] - 2020-07-12
##### Changed
- Release `2.1.1` included a change to env file and thus require a major version bump.
- Modified output on Update screen slightly.


#### [2.1.1] - 2020-07-12
##### Added
- Basic health check data on main menu
  - Epoch, time until next epoch, node tip vs calculated reference tip and a warning if node is lagging behind.
- Address era and encoding to `Wallet >> Show`

##### Changed
- KES calculation, now take into account the byron era and the transition period until shelley start
  - Credit to Martin @ ATADA for inspiration on how to calculate this


#### [2.0.1] - 2020-07-12
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


#### [1.2.0] - 2020-07-07
##### Added
- Live stake and delegators in `Pool >> Show`

##### Fixed
- Correct nwmagic - was hardcoded to 42


#### [1.1.0] - 2020-07-07
##### Fixed
- Set script locale to fix format issue


#### [1.0.0] - 2020-07-07
##### Added
- Wallet upgrade option added for backwards compatibility.  
`Wallet >> LIST` now offer an upgrade option if it finds a wallet with payment address that has funds in it. Special note added in case a genesis address is found.
- Update message on startup

##### Changed
- Support for payment address(aka enterprise) minimised to default on base address support, as Everything that can be done with a payment address can also be done with the base address.
- Reduce a step to Update (register) wallet keys, and moved this step to delegate/register pool step based on a check to see if the registration is required.
- Changes for log output and variable names
- Docs and output update
- Replace pool JSON hosting instructions, from stout to copying file, to avoid user errors
- Do not give option or allow sending to same address as source. Base <-> Enterprise for same wallet ok.

##### Fixed
- Removed debug code in tx
- A bug fixed for wallet not showing in some cases because reward address file was not generated at wallet creation


#### [0.3.0] - 2020-07-01
##### Fixed
- In-app update bugfix

#### [0.2.0] - 2020-06-30
##### Added
- Default values for relay on pool modify and re-registration
- New pool config parameter for relay type called `type` containing either IPv4 or DNS_A currently.

##### Changed
- Old relays table on modify/registration redone to include type. Also put together a little different to handle null values and omit quotation marks.
- Pool show updated to show type for relay
- On pool re-registration or modification the old relay valus are now read from pool config. If selection of type match old values the default values are set to old config.

##### Fixed
- Minor alignment fix of main menu header


#### [0.1.0] - 2020-06-29
##### Added
- First versioned released  
  see github commit history for details before this release
- In-app update for cntools

##### Changed
- Update CNTools Doco to include Version on home screen

##### Fixed
- Align table for reading relays
