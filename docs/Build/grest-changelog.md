# Koios gRest Changelog

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
