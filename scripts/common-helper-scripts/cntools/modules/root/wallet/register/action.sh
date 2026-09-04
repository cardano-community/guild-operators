#!/usr/bin/env bash
# CNTools wallet stake-registration action. Functions only.

cntools_action_main() {
  cntools_wallet_action_register
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
