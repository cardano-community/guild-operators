# CNTools Changelog

All notable changes to this tool will be documented in this file.

**Note: Whenever you're updating between versions where format/hash of keys have changed , or you're changing networks - it is recommended to archive $CNODE_HOME/priv/wallet and $CNODE_HOME/priv/pool folders before you proceed with launching cntools on a fresh network.**

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [5.0.3] - 2020-07-24

**Due to recent changes, following is required:**
1. prereqs.sh (default it will set you up against MC3)
2. Clear db folder
3. clear logs folder
4. start using updated cnode.sh

### Changed
- moved update check to be one of the first things CNTools does after start to be able to show critical changes before anything else runs.


## [5.0.2] - 2020-07-24

### Changed
- Parse node logs to check the transition from Byron to shelley era, and save the epoch for transition in db folder. This is required for calculating KES keys.
  - Please make sure to use **config files created by the prereqs.sh, or enable JSON loggers for your config**.
- Update cnode.sh.templ to archive logs every time node is restart, this ensures that we're not searching for previous log history when network was changed. Network being changed would automatically deduce db folder was deleted.
- Update default network to MC3

### Fixed
- `Pool >> Show` delegator rewards parsing from ledger-state

## [5.0.1] - 2020-07-22
### Fixed
- Slot sync format improvement
- kesExpiration function to use 17 fixed byron transition epochs 


## [5.0.0] - 2020-07-20

**Note: Please re-run prereqs.sh, archive/delete old keys and pool folders if you're upgrading, the config files (+ crypto hash if upgrading to 1.16.*) have changed.**

### Added
- HASH_IDENTIFIER where applicable to differentiate between network modes for commands used, required due to legacy Byron considerations
- add ptn0-praos.json and ptn0-combinator.json to reduce confusion between formats, make prereqs default to combinator, and accept p argument to indicate praos mode.
- cardano-node 1.16.0 refers to txhash using quotes, sed them out
- show what's new at startup after update
- file size check for pool metadata file
- Add nonce in pool metadata JSON to keep registration attempts unique, avoiding one hash pointing to multiple URLs
- Change default network to `mainnet_candidate`, and add second argument (g) to run prereqs against guild network

### Changed
- Default config switched to combinator instead of testnet
- Start maintaining seperate versions of praos and combinator config files.
- Add 10s timeout to wget commmands in case of issue
- timestamp added to pool metadata file to make every creation unique
- Cancel shortcut changed from `[c]` to `[Esc]`
- Default pool cost from 256 -> 400
- slotinterval calculation to include decentralisation parameter
- mainnet candidate compatible slot calculation, 17 fixed byron transition epochs (needs to be fixed for mainnet)

### Removed
- Delete cntools-updater script

### Fixed
- Slots reference was mixing up for shelley testnet in absence of a combinator network

## [4.3.0] - 2020-07-16
### Added
- allow the use of pre-existing metadata from URL when registering or modifying pool
- minimum pool cost check against protocol

### Removed
- NODE_SOCKET_PATH config parameter(replaced by CARDANO_NODE_SOCKET_PATH)

### Changed
- Pool metadata information to copy file as-is as well as wait for keypress to make sure file is copied before proceeding with registration.


## [4.2.2] - 2020-07-15
### Fixed
- numfmt dependency removed in favor of printf formatting


## [4.2.1] - 2020-07-15
### Fixed
- Vkey delegation fix due to json format switch


## [4.2.0] - 2020-07-15
### Added
- Refresh option to home screen

### Fixed
- ADA not displayed in a couple of the wallet selection menus


## [4.1.0] - 2020-07-14
### Added
- Ability to register multiple relay DNS A records as well as a mix of DNS A and IPv4
  - Valid for pool registration and modification

### Changed
- Now use internal table builder to display previous relays
- Instead of giving relays from previous registration as default values it will now ask if you want to re-register relays exactly as before to minimize steps and complexity


## [4.0.2] - 2020-07-13
### Fixed
- KES calculation support for both MC and Shelley Testnet


## [4.0.1] - 2020-07-13
### Fixed
- Slot tip reference calculation for shelley testnet


## [4.0.0] - 2020-07-13
### Added
- Add PROTOCOL_IDENTIFIER and NETWORK_IDENTIFIER instead of harcoded entries for combinator v/s TPraos & testnet v/s magic differentiators respectively.
- Keep both ptn0.yaml and ptn0-combinator.yaml to keep validity with mainnet-combinator

### Changed
- Revert back default for Public network to Shelley_Testnet as per https://t.me/CardanoStakePoolWorkgroup/282606


## [3.0.0] - 2020-07-12
### Changed
- Release `2.1.1` included a change to env file and thus require a major version bump.
- Modified output on Update screen slightly.


## [2.1.1] - 2020-07-12
### Added
- Basic health check data on main menu
  - Epoch, time until next epoch, node tip vs calculated reference tip and a warning if node is lagging behind.
- Address era and encoding to `Wallet >> Show`

### Changed
- KES calculation, now take into account the byron era and the transition period until shelley start
  - Credit to Martin @ ATADA for inspiration on how to calculate this


## [2.0.1] - 2020-07-12
### Fixed
- Version fix to include patch version


## [2.0.0] - 2020-07-12
### Added
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

### Changed
- op-cert creation moved from `Pool >> New` to `Pool >> Register`.
- Output changed in various places throughout.
- Include reward in delegators stake.
- Release now include patch version in addition to major and minor version.  
  In-app update modified to reflect this change.
- Block Collector table view
- Various minor code improvements
  
### Removed
- Enterprise wallet upgrade option in `Wallet >> List` 
- `Not a registered wallet on chain` information from Wallet listing
- en_US.UTF-8 locale dependency

### Fixed
- meta_json_url check
- Invalid tx_in when registering stake wallet
- Delegators rewards in `Pool >> Show`
- Work-around awk versions that only support 32-bit integers
- Sometimes cardano-node log contain duplicate traces for the same slot at log file rollover, now filtered


## [1.2.0] - 2020-07-07
### Added
- Live stake and delegators in `Pool >> Show`

### Fixed
- Correct nwmagic - was hardcoded to 42


## [1.1.0] - 2020-07-07
### Fixed
- Set script locale to fix format issue


## [1.0.0] - 2020-07-07
### Added
- Wallet upgrade option added for backwards compatibility.  
`Wallet >> LIST` now offer an upgrade option if it finds a wallet with payment address that has funds in it. Special note added in case a genesis address is found.
- Update message on startup

### Changed
- Support for payment address(aka enterprise) minimised to default on base address support, as Everything that can be done with a payment address can also be done with the base address.
- Reduce a step to Update (register) wallet keys, and moved this step to delegate/register pool step based on a check to see if the registration is required.
- Changes for log output and variable names
- Docs and output update
- Replace pool JSON hosting instructions, from stout to copying file, to avoid user errors
- Do not give option or allow sending to same address as source. Base <-> Enterprise for same wallet ok.

### Fixed
- Removed debug code in tx
- A bug fixed for wallet not showing in some cases because reward address file was not generated at wallet creation


## [0.3.0] - 2020-07-01
### Fixed
- In-app update bugfix

## [0.2.0] - 2020-06-30
### Added
- Default values for relay on pool modify and re-registration
- New pool config parameter for relay type called `type` containing either IPv4 or DNS_A currently.

### Changed
- Old relays table on modify/registration redone to include type. Also put together a little different to handle null values and omit quotation marks.
- Pool show updated to show type for relay
- On pool re-registration or modification the old relay valus are now read from pool config. If selection of type match old values the default values are set to old config.

### Fixed
- Minor alignment fix of main menu header


## [0.1.0] - 2020-06-29
### Added
- First versioned released  
  see github commit history for details before this release
- In-app update for cntools

### Changed
- Update CNTools Doco to include Version on home screen

### Fixed
- Align table for reading relays
