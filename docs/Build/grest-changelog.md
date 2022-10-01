# Koios gRest Changelog

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
