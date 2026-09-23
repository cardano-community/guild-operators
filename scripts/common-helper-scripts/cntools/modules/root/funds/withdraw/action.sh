#!/usr/bin/env bash
# Full reward withdrawal using the shared transaction foundation.

cntools_action_main() {
  cntools_funds_action_withdraw
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
