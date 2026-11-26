#!/usr/bin/env bash
# Pool certificate action on the shared transaction foundation.

cntools_action_main() {
  cntools_pool_action_registration pool-register
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_pool_files_cleanup
  cntools_transaction_cleanup
}
