# Koios gRest Changelog

## [1.1.1] - For all networks.

This release primarily focuses on backend performance fixes and work with dbsync 13.2.0.2 - while also, we have started preparing compatibility with upcoming koios lite release, to make it a seamless swap for specific endpoints without any impact to consumers. There are no breaking (impact to existing columns or inputs) changes with this release, but we have retired 2 deprecated endpoints that were almost unused on mainnet. Due to the amount of backend changes in queries, there is a chance that we may have missed some data accuracy checks, and - hence - would like to test in non-mainnet networks first before marking final release. Accordingly, any testing/reports of data inconsistency would be welcome.

### New endpoints added:
- `/asset_policy_mints` - List of mint/burn count for all assets minted under a policy [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- `/block_tx_info` - Equivalent of tx_info but uses blocks as inputs to fetch tx_info against all tx in the block[s] requested, also contains additional flags to control performance and output [#255](https://github.com/cardano-community/koios-artifacts/pull/255)
- `/cli_protocol_params` - Return protocl-parameters as returned by `cardano-cli` from Koios servers [#269](https://github.com/cardano-community/koios-artifacts/pull/269)

### Data Input/Output Changes:
- Output - `/reserve_withdrawals` , `/treasury_withdrawals` - Add `earned_epoch` and `spendable_epoch` fields [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Output - `/block` - Add `parent_hash` field [#263](https://github.com/cardano-community/koios-artifacts/pull/263)
- Output - `/account_list` - Add `stake_address_hex` and `script_hash` fields [#263](https://github.com/cardano-community/koios-artifacts/pull/263)
- Output - `/asset_list` - Add `script_hash` field [#263](https://github.com/cardano-community/koios-artifacts/pull/263)
- Output - `/asset_summary` - Add `addresses` field [#263](https://github.com/cardano-community/koios-artifacts/pull/263)
- Output - `/asset_addresses` , `/asset_nft_address` and `/policy_asset_addresses` - Add `stake_address` field [#262](https://github.com/cardano-community/koios-artifacts/pull/262)
- Output - Fix `/script_utxos` as it was incorrectly returning object instead of array for asset_list [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Output - `/tx_info` - Add `plutus_contract` -> `spends_input` to `plutus_contracts` to point the input transaction being consumed by the script [#269](https://github.com/cardano-community/koios-artifacts/pull/269)

### Deprecations:
- None

### Retirements:
- `asset_address_list` and `asset_policy_info` endpoints are now retired, as they were marked as deprecated in Koios 1.0.10 , and we have seen it's usage to be negligible (only a single hit in 48 hours on mainnet while marking this release). [#269](https://github.com/cardano-community/koios-artifacts/pull/269)

### Chores:
- Retire `stake_distribution_new_accounts` and `stake_snapshot_cache` cache, as we directly perform lookup on live tables for newly registered accounts [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Active stake cache no longer reads the logs, but instead relies on newly added `epoch_sync_progress table` [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Reduce asset_info_cache rollback lookup from 1000 to 250 [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Replace `consumed_by_tx_in_id` references in SQL by `consumed_by_tx_id` [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- `pool_history_cache` now breaks into populating 500 epochs at a time (on guildnet, this query used to run for hours against ~20K epochs) [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Accomodate splitting of `reward` table into `instant_reward` [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Add a check in `stake_distribution_cache` to ensure that epoch info cache was run for current - 1 epoch. [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Change return type for internal function `grest.cip67_strip_label` from `text` to `bytea` [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Remove any references to `tx_in` as it is no longer required [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Remove references to `pool_offline_data` with `off_chain_pool_data` [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- Disable running `asset-txo-cache-update` as the endpoints leveraging asset-txo will be moved to koios-lite
- Convert `block`, `account_list`, `asset_list` `asset_token_registry` from view to function [#263](https://github.com/cardano-community/koios-artifacts/pull/263)
- `asset_info_cache` - ensure mint tx is only against a positive mint quantity [#262](https://github.com/cardano-community/koios-artifacts/pull/262)
- Include burnt asset transactions in asset_txs [#269](https://github.com/cardano-community/koios-artifacts/pull/269)
- `tx_info` - Fix spend_redeemers CTE Join condition [#269](https://github.com/cardano-community/koios-artifacts/pull/269)

## [1.1.0] - For all networks.

This will be first major [breaking] release for Koios consumers in a while, and will be rolled out under new base prefix (`/api/v1`).
The major work with this release was to start making use of newer flags in dbsync which help performance of queries under new endpoints. Please ensure to check out the release notes for `1.1.0rc` below. The list for this section is only a small addendum to `1.1.0rc`:

### Chores:
- Make use of asset-txo-cache for top assets on mainnet, and use this cache for `asset_addresses` and `policy_asset_addresses` [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Add v0 RPC redirectors to keep serve v0 endpoints from v1 [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Convert few simple RPC functions from PLPGSQL to SQL language to help with inline filtering [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Address linting results from SQLFluff [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Move db-scripts from guild-operators repository to koios-artifacts repository [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Drop stale db-scripts/genesis_table.sql file [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Add 3 additional indexes for collateral and reference inputs based on query times [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Add top 3 assets for preview/preprod to asset-txo-cache [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Bump schema version for koios-1.1.0 [#250](https://github.com/cardano-community/koios-artifacts/pull/250)
- Minor patch for output data type (`pool_registrations` and `pool_retirements`) [#249](https://github.com/cardano-community/koios-artifacts/pull/249)

## [1.1.0rc] - For all networks.

This will be first major [breaking] release for Koios consumers in a while, and will be rolled out under new base prefix (`/api/v1`).
The major work with this release was to start making use of newer flags in dbsync which help performance of queries under new endpoints. Also, you'd see quite a few new endpoint additions below, that'd be helping out with slightly lighter version of queries. To keep migration paths easier, we will ensure both v0 and v1 versions of the release is up for a month post release, before retiring v0.

### New endpoints added:
- `/pool_registrations` - List of all pool registrations initiated in the requested epoch [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/pool_retirements` - List of all pool retirements initiated in the requested epoch [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/treasury_withdrawals` - List of withdrawals made from treasury [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/reserve_withdrawals` - List of withdrawals made from reserves (MIRs) [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/account_txs` - Transactions associated with a given stake address [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/address_utxos` - Get UTxO details for requested addresses [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/asset_utxos` - Get UTxO details for requested assets [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/script_utxos` - Get UTxO details for requested script hashes [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/utxo_info` - Details for requested UTxO arrays [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/script_info` - Information about a given script FROM script hashes [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `/ogmios/` - Expose [stateless ogmios](https://ogmios.dev/api/) endpoints [#1690](https://github.com/cardano-community/guild-operators/pull/1690)

### Data Input/Output Changes:
- Input - `/account_utxos` , `/credential_utxos` - Accept `extended` as an additional flag - which enables `asset_list`, `reference_script` and `inline_datum` to the output [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/block_txs` - Flatten output with transaction details (`tx_hash`, `epoch_no`, `block_height`, `block_time`) instead of `tx_hashes` array [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/epoch_params` - Update `cost_models` to JSON (upstream change in node) [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/account_assets` , `/address_assets` - Flatten the output result (instead of `asset_list` array) making it easier to apply horizontal filtering based on any of the fields
- Output - Align output fields for `/account_utxos` , `/address_utxos`, `/asset_utxos` , `/script_utxos` and `/utxo_info` to return same schema giving complete details about UTxOs involved, with few fields toggled based on `extended` input flag [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/pool_list` - Add various details to the endpoint for each pool (`pool_id_hex`,`active_epoch_no`,`margin`,`fixed_cost`,`pledge`,`reward_addr`,`owners`,`relays`,`ticker`,`meta_url`,`meta_hash`,`pool_status`,`retiring_epoch`) - this should mean *some* of the requests to `pool_info` should no longer be required [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/pool_updates` - In v0, `pool_updates` only provided pool registration updates, while `pool_status` corresponded to current status of pool. With v1, we will have registration as well as deregistration transactions, and each transaction will have `update_type` (enum of either `registration` or `deregistration`) instead of `pool_status`. As a side-effect, since a registration transaction only has `retiring_epoch` as metadata, all the other fields will show up as `null` for such a transaction [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/pool_metadata` , `/pool_relays` - Add `pool_status` field to denote whether pool is retired [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/datum_info` - Rename `hash` to `datum_hash` and add `creation_tx_hash` [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/native_script_list` - Remove `script` column (as it has pretty large output better queried against `script_info`), add `size` and change `type` to text [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/plutus_script_list` - Add `type` and `size` to output [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Output - `/asset_info` - Add `cip68_metadata` JSONB field [#239](https://github.com/cardano-community/koios-artifacts/pull/227)
- Output - `/pool_history` - Add member_rewards [#225](https://github.com/cardano-community/koios-artifacts/pull/225)

### Deprecations:
- `/tx_utxos` - No longer required as replaced by `/utxo_info` [#239](https://github.com/cardano-community/koios-artifacts/pull/239)

### Chores:
- Update base version to `v1` from `v0` [#1690](https://github.com/cardano-community/guild-operators/pull/1690)
- Allow Bearer Authentication against endpoints [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Cron job to apply corrections to epoch info [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- `epoch_info_cache` Remove protocol parameters, as they can be queried from live table. Accordingly update dependent queries [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Make use of new `consumed_by_tx_in_id` column in `tx_out` from dbsync 13.1.1.3 across endpoints [#239](https://github.com/cardano-community/koios-artifacts/pull/239)
- Fix `_last_active_stake_validated_epoch` in active_stake_cache [#222](https://github.com/cardano-community/koios-artifacts/pull/222)
- Typo for pool_history_cache.sql as well as add a check to ensure epoch_info_cache has run at least once prior to pool_history_cache [#223](https://github.com/cardano-community/koios-artifacts/pull/223)
- Move control_table entry in cache tables to the end (instead of start) [#226](https://github.com/cardano-community/koios-artifacts/pull/226)
- Fix Asset Info Cache (include mint/burn tx rather than sum for meta consideration) [#226](https://github.com/cardano-community/koios-artifacts/pull/226)
- Update SQLs as per SQLFluff linting guidelines [#226](https://github.com/cardano-community/koios-artifacts/pull/226)
- Fix for tip check in cron jobs [#217](https://github.com/cardano-community/koios-artifacts/pull/217)
- Update cron jobs to exit if the database has not received block in 5 mins [#200](https://github.com/cardano-community/koios-artifacts/pull/200)
- Update active stake cache to use control table [#196](https://github.com/cardano-community/koios-artifacts/pull/196)
- Update Asset Info Cache entry whenever asset registry cache has an update [#194](https://github.com/cardano-community/koios-artifacts/pull/194)
- Bump up margin for tx rollback lookup for asset_info_cache to 1000 , as 100 is too small a margin for 2-3 blocks , which can contain more than 100 transactions (of which if oldest transaction contains a mint, it will not get into the cache) [#177](https://github.com/cardano-community/koios-artifacts/pull/177)
- Swap grestrpcs file to list exceptions and treat everything else as RPC [#1690](https://github.com/cardano-community/guild-operators/pull/1690)
- Update grest-poll.sh to have stricter spec validation and add health check for asset_registry [#1690](https://github.com/cardano-community/guild-operators/pull/1690)
- Update guild-deploy.sh to include latest pre-release for ogmios [#1690](https://github.com/cardano-community/guild-operators/pull/1690)

## [1.0.10] - For all networks.

The release is effectively same as `1.0.10rc` except with one minor modification below.

### Chores:
- Replace all RPC references for JSON endpoints with JSONB, this allows filtering child members of array elements using `cs.[{"key":"value"}]` in PostgREST [#172](https://github.com/cardano-community/koios-artifacts/pull/172)

## [1.0.10rc] - For non-mainnet networks

This release primarily focuses on ability to support better DeFi projects alongwith some value addition for existing clients by bringing in 10 new endpoints (paired with 2 deprecations), and few additional *optional* input parameters , and some additional output columns to existing endpoints. The only breaking change/fix is for output returned for `tx_info`.

Also, dbsync 13.1.x.x has been released and is recommended to be used for this release

### New endpoints added
- `/asset_addresses` -  Equivalent of deprecated `/asset_address_list` [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/asset_nft_address` - Returns address where the specified NFT sits on [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/account_utxos` - Returns brief details on non-empty UTxOs associated with a given stake address [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/asset_info_bulk` - Bulk version of `/asset_info` [#142](https://github.com/cardano-community/koios-artifacts/pull/142)
- `/asset_token_registry` - Returns assets registered via token registry on github [#145](https://github.com/cardano-community/koios-artifacts/pull/145)
- `/credential_utxos` - Returns UTxOs associated with a payment credential [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/param_updates` - Returns list of parameter update proposals applied to the network [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/policy_asset_addresses` - Returns addresses with quantity for each asset on a given policy [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/policy_asset_info` - Equivalent of deprecated `/asset_policy_info` but with more details in output [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/policy_asset_list` - Returns list of asset under the given policy (including supply) [#142](https://github.com/cardano-community/koios-artifacts/pull/142), [#149](https://github.com/cardano-community/koios-artifacts/pull/149)

### Data Input/Output Changes
- Input - `/account_addresses` - Add optional `_first_only` and `_empty` flags to show only first address with tx or to include empty addresses to output [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- Input - `/epoch_info` - Add optional `_include_next_epoch` field to show next epoch stats if available (eg: nonce, active stake) [#143](https://github.com/cardano-community/koios-artifacts/pull/143)
- Output (addition) - `/account_assets` , `/address_assets` , `/address_info`, `/tx_info`, `/tx_utxos` - Add `decimals` to output [#142](https://github.com/cardano-community/koios-artifacts/pull/142)
- Output (addition) - `/policy_asset_info` - Add `minting_tx_hash`, `total_supply`, `mint_cnt`, `burn_cnt` and `creation_time` fields to the output [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- Output (**breaking**) - `/tx_info` - Change `_invalid_before` and `_invalid_after` to text field [#141](https://github.com/cardano-community/koios-artifacts/pull/141)
- Output (**breaking**/removal) - `tx_info` - Remove the field `plutus_contracts` > [array] > `outputs` as there is no logic to connect it to inputs spending [#163](https://github.com/cardano-community/koios-artifacts/pull/163)

### Deprecations:
- `/asset_address_list` - Renamed to `asset_addresses` keeping naming line with other endpoints (old one still present, but will be deprecated in future release) [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/asset_policy_info` - Renamed to `policy_asset_info` keeping naming line with other endpoints (old one still present, but will be deprecated in future release) [#149](https://github.com/cardano-community/koios-artifacts/pull/149)

### Chores:
- `/epoch_info`, `/epoch_params` - Restrict output to current epoch [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- `/block_info` - Use `/previous_id` field to show previous/next blocks (previously was using block_id/height) [#145](https://github.com/cardano-community/koios-artifacts/pull/145)
- `/asset_info`/`asset_policy_info` - Fix mint tx data to be latest [#141](https://github.com/cardano-community/koios-artifacts/pull/141)
- Support new guild scripts revamp [#1572](https://github.com/cardano-community/guild-operators/pull/1572)
- Add asset token registry check [1606](https://github.com/cardano-community/guild-operators/pull/1606)
- New cache table `grest.asset_info_cache` to hold mint/burn counts alongwith first/last mint tx/keys [#142](https://github.com/cardano-community/koios-artifacts/pull/142)
- Bump to Koios 1.0.10rc [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- Fix typo in specs for `/pool_delegators` output column `latest_delegation_tx_hash` [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- Add indexes for ones missing after configuring cardano-db-sync 13.1.0.0 [#149](https://github.com/cardano-community/koios-artifacts/pull/149)
- Update PostgREST to be run as `authenticator` user, whose default `statement_timeout` is set to 65s and update configs accordingly [#1606](https://github.com/cardano-community/cardano-community/guild-operators/pull/1606)

## [1.0.9] - For all networks

This release is effectively same as `1.0.9rc` below (please check out the notes accordingly), just with minor bug fix on `setup-grest.sh` itself.

## [1.0.9rc] - For non-mainnet networks

This release candidate is non-breaking for existing methods and inputs, but breaking for output objects for endpoints.
The aim with release candidate version is to allow folks couple of weeks to test, adapt their libraries before applying to mainnet.

### New endpoints added
- `datum_info` - List of datum information for given datum hashes
- `account_info_cached` - Same as `account_info`, but serves cached information instead of live one

### Data Input/Output changes
- `address_info`, `address_assets`, `account_assets`, `tx_info`, `asset_list` `asset_summary` to align output `asset_list` object to return array of `policy_id`, `asset_name`, `fingerprint` (and `quantity`, `minting_txs` where applicable) [#120](https://github.com/cardano-community/koios-artifacts/pull/120)
- `asset_history` - Fix metadata to wrap in array to refer to right object [#122](https://github.com/cardano-community/koios-artifacts/pull/122)
- `asset_txs` - Add optional boolean parameter `_history` (default: `false`) to toggle between querying current UTxO set vs entire history for asset [#122](https://github.com/cardano-community/koios-artifacts/pull/122)
- `pool_history` - `fixed_cost`, `pool_fees`, `deleg_rewards`, `epoch_ros` will be returned as 0 when null [#122](https://github.com/cardano-community/koios-artifacts/pull/122)
- `tx_info` - `plutus_contracts->outputs` can be null [#122](https://github.com/cardano-community/koios-artifacts/pull/122)

### Changes for Instance Providers
- SQL queries have been moved from `guild-operators` repository to `koios-artifacts` repository. This is to ensure that the updates made to scripts and other tooling do not have a dependency on Koios query versioning [#122](https://github.com/cardano-community/koios-artifacts/pull/122)
- `block_info` - Use `block_no` instead of `id` to check for previous/next block hash [#122](https://github.com/cardano-community/koios-artifacts/pull/122)
- Add topology for preprod and preview networks [#122](https://github.com/cardano-community/koios-artifacts/pull/122)

## [1.0.8] - For all networks

This release is contains minor bug-fixes that were discovered in koios-1.0.7.
No major changes to output for this one.

### Changes for API

#### New endpoints added
- None

#### Data Input/Output changes
- `tx_info` and `tx_metadata` - Align metadata for JSON output format [#1542](https://github.com/cardano-community/guild-operators/pull/1542)
- `blocks` - Query Output aligned to specs (`epoch` => `epoch_no`)
- `epoch_block_protocols` - [ ** Specs only ** ] Fix Documentation schema , which was accidentally showing wrong output
- `pool_delegators_history` - List all epochs instead of current, if no `_epoch_no` is specified [#1545](https://github.com/cardano-community/guild-operators/issues/1545)

### Changes for Instance Providers
- `asset_info` - Fix metadata aggregaton for minting transactions with multiple metadata keys [#1543](https://github.com/cardano-community/guild-operators/pull/1543)
- `stake_distribution_new_accounts` - Leftover reference for `account_info` which now accepts array, resulted in error to populate stake distribution cache for new accounts [#1541](https://github.com/cardano-community/guild-operators/pull/1541)
- `grest-poll.sh` - Remove query view section from polling script, and remove grestrpcs re-creation per hour (it's already updated when `setup-grest.sh` is run) , in preparation for [#1545](https://github.com/cardano-community/guild-operators/issues/1545)

## [1.0.7] - For all networks

This release continues updates from koios-1.0.6 to further utilise stake-snapshot cache tables which would be useful for SPOs as well as reduce downtime post epoch transition. One largely requested feature to accept bulk inputs for many block/address/account endpoints is now complete.
Additionally, koios instance providers are now recommended to use cardano-node 1.35.3 with dbsync 13.0.5.

### Changes for API 

### New endpoints added
- `pool_delegators_history` - Provides historical record for pool's delegators [#1486](https://github.com/cardano-community/guild-operators/pull/1486)
- `pool_stake_snapshot` - Provides mark, set and go snapshot values for pool being queried. [#1489](https://github.com/cardano-community/guild-operators/pull/1489)

### Data Input/Output changes
- `pool_delegators` - No longer accepts `_epoch_no` as parameter, as it only returns live delegators. Additionally provides `latest_delegation_hash` in output. [#1486](https://github.com/cardano-community/guild-operators/pull/1486)
- `tx_info` - `epoch` => `epoch_no` [#1494](https://github.com/cardano-community/guild-operators/pull/1494)
- `tx_info` - Change `collateral_outputs` (array) to `collateral_output` (object) as collateral output is only singular in current implementation [#1496](https://github.com/cardano-community/guild-operators/pull/1496)
- `address_info` - Add `inline_datum` and `reference_script` to output [#1500](https://github.com/cardano-community/guild-operators/pull/1500)
- `pool_info` - Add `sigma` field to output [#1511](https://github.com/cardano-community/guild-operators/pull/1511)
- `pool_updates` - Add historical metadata information to output [#1503](https://github.com/cardano-community/guild-operators/pull/1503)
- Change block/address/account endpoints to accept bulk input where applicable. This resulted in GET requests changing to POST accepting payload of multiple blocks, addresses or accounts for respective endpoints as *input* (eg: `_stake_address text` becomes `_stake_addresses text[]`). The additional changes in output as below:
  - `block_txs` - Now returns `block_hash` and array of `tx_hashes`
  - `address_info` - Additional field `address` returned in output
  - `address_assets` - Now returns `address` and an array of `assets` JSON
  - `account_addresses` - Accepts `stake_addresses` array and outputs `stake_address` and array of `addresses`
  - `account_assets` - Accepts `stake_addresses` array and outputs `stake_address` and array of `assets` JSON
  - `account_history` - Accepts `stake_addresses` array alongwith `epoch_no` integer and outputs `stake_address` and array of `history` JSON
  - `account_info` - Accepts `stake_addresses` array and returns additional field `stake_address` to output
  - `account_rewards` - Now returns `stake_address` and an array of `rewards` JSON
  - `account_updates` - Now returns `stake_address` and an array of `updates` JSON
- `asset_info` - Change `minting_tx_metadata` from array to object [#1533](https://github.com/cardano-community/guild-operators/pull/1533)
- `account_addresses` - Sort results by oldest address first [#1538](https://github.com/cardano-community/guild-operators/pull/1538)

### Changes for Instance Providers
- `epoch_info_cache` - Only update last_tx_id of previous epoch on epoch transition [#1490](https://github.com/cardano-community/guild-operators/pull/1490) and [#1502](https://github.com/cardano-community/guild-operators/pull/1502)
- `epoch_info_cache` / `stake_snapshot_cache` - Store total snapshot stake to epoch stake cache, and active pool stake to stake snapshot cache [#1485](https://github.com/cardano-community/guild-operators/pull/1485)


## [1.0.6/1.0.6m] - Interim release for all networks to upgrade to dbsync v13

The backlog of items not being added to mainnet has been increasing due to delays with Vasil HFC event to Mainnet. As such we had to come up with a split update approach.
The mainnet nodes are still not qualified to be Vasil-ready (in our opinion) for 1.35.x , but dbsync 13 can be used against node 1.34.1 fine. In order to cater for this split, we have added an intermediate koios-1.0.6m tag that brings dbsync updates while maintaining node-1.34.1.

### Changes for API

#### Data Output Changes
- `pool_delegators` - `epoch_no` => `active_epoch_no` [#1454](https://github.com/cardano-community/guild-operators/pull/1454)
- `asset_history` - Add `block_time` and `metadata` fields for all previous mint transactions [#1468](https://github.com/cardano-community/guild-operators/pull/1468)
- `asset_info` - Retain latest mint transaction instead of first (in line with most CIPs as well as pool metadata - latest valid meta being live) [#1468](https://github.com/cardano-community/guild-operators/pull/1468)
- Ensure all output date formats is integer to keep in line with UNIX timestamps - to be revised in future if/when there are milliseconds [#1460](https://github.com/cardano-community/guild-operators/pull/1460)
  - `/tip` , `/blocks`, `/block_info` => `block_time`
  - `/genesis` => `systemStart`
  - `/epoch_info` => `start_time`, `first_block_time`, `last_block_time`, `end_time`
  - `/tx_info` => `tx_timestamp`
  - `/asset_info` => `creation_time`
- `tx_info` - Add Vasil data [#1464](https://github.com/cardano-community/guild-operators/pull/1464)
  - `collaterals` => `collateral_inputs`
  - Add `collateral_outputs`, `reference_inputs` to `tx_info`
  - Add `datum_hash`, `inline_datum`, `reference_script` to collateral input/outputs, reference inputs & inputs/outputs JSON.
  - Add complete `cost_model` instead of `cost_model_id` reference
- `epoch_params` - Update leftover lovelace references to text for consistency: [#1484](https://github.com/cardano-community/guild-operators/pull/1484)
  - `key_deposit`
  - `pool_deposit`
  - `min_utxo_value`
  - `min_pool_cost`
  - `coins_per_utxo_size`

### Changes for Instance Providers

- `get-metrics.sh` - Add active/idle connections to database [#1459](https://github.com/cardano-community/guild-operators/pull/1459)
- `grest-poll.sh`: Bump haproxy to 2.6.1 and set default value of API_STRUCT_DEFINITION to be dependent on network used. [#1450](https://github.com/cardano-community/guild-operators/pull/1450)
- Lighten `grest.account_active_stake_cache` - optimise code and delete historical view (beyond 4 epochs). [#1451(https://github.com/cardano-community/guild-operators/pull/1451)
- `tx_metalabels` - Move metalabels from view to RPC using lose indexscan (much better performance) [#1474](https://github.com/cardano-community/guild-operators/pull/1474)
- Major re-work to artificially add last epoch's active stake cache data (brings in latest snapshot information without depending on node), not used in endpoints for this release [#1452](https://github.com/cardano-community/guild-operators/pull/1452)
- `grest.stake_snapshot_cache` - Fix rewards for new accounts [#1476](https://github.com/cardano-community/guild-operators/pull/1476)


## [1.0.5] - alpha networks only

Since there have been a few deviations wrt Vasil for testnet and mainnet, this version only targets networks except Mainnet!

### Changes for API

#### Data Output Changes

- `/epoch_info` - Add `total_rewards` and `avg_block_reward` for a given epoch [#43](https://github.com/cardano-community/koios-artifacts/pull/43)
- Update all date output formats to return UNIX timestamp (as per poll held in discussions group): [#45](https://github.com/cardano-community/koios-artifacts/pull/45)
  - `/tip` , `/blocks`, `/block_info` => `block_time`
  - `/genesis` => `systemStart`
  - `/epoch_info` => `start_time`, `first_block_time`, `last_block_time`, `end_time`
  - `/tx_info` => `tx_timestamp`
  - `/asset_info` => `creation_time`
- `/blocks`, `/block_info` => Add `proto_major` and `proto_minor`  for a given block to output [#55](https://github.com/cardano-community/koios-artifacts/pull/55)

### Changes for Instance Providers

- For consistency between date formats, we highly recommend you to upgrade your instance to use Postgres 14 (prolly a good time, since you would already need to recreate DB for dbsync v13). You can find sample instructions to do so [here](https://www.paulox.net/2022/04/28/upgrading-postgresql-from-version-13-to-14-on-ubuntu-22-04-jammy-jellyfish/)
- Various changes to backend scripts and performance optimisations that can be found [here](https://github.com/cardano-community/guild-operators/compare/koios-1.0.1...koios-1.0.5)


## [1.0.1]
- Modify `asset_registry_update.sh` script to rely on commit hash instead of POSIX timestamps, and performance bump. [#1428](https://github.com/cardano-community/guild-operators/pull/1428)


## [1.0.0]
- First Production release for Koios gRest


## [1.0.0-rc1]

### Changes for API

#### Data Output Changes
- Improve: Add `epoch_no`, `block_no` to `/address_txs`, `/credential_txs` and `/asset_txs` endpoints. [#1409](https://github.com/cardano-community/guild-operators/pull/1403)
- Fix: Remove redundant policy_info for `/asset_txs`, returning transactions as an array - allows for leveraging native PostgREST filtering. [#1409](https://github.com/cardano-community/guild-operators/pull/1403)
- Fix: Pool Metadata sorting was incorrect for `/pool_info`. [#1414](https://github.com/cardano-community/guild-operators/pull/1414)

#### Input Parameter Changes
- None

### Changes for Instance Providers

#### Added
- Add setup-grest.sh versioning. When running setup-grest.sh against a branch/tag, it will now populate the version information on control table, the health checks will be able to use this versioning for downstream connections. [#1403](https://github.com/cardano-community/guild-operators/pull/1403)

#### Fixed
- Delete token token-registry folder when running `setup-grest.sh` with `-r` (reset flag), as the delta registry records to insert depends on file (POSIX) timestamps. [#1410](https://github.com/cardano-community/guild-operators/pull/1410)
- Remove duplicate tip check in `grest-poll.sh`. 

## [1.0.0-rc0] - 2022-04-29

- Initial Release Candidate for Koios gRest API layer with 43 endpoints to query the chain.
