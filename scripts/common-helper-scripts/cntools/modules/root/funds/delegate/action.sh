#!/usr/bin/env bash
# Stake pool delegation through the shared stake transaction workflow.

cntools_action_main() {
  cntools_funds_action_delegate
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
