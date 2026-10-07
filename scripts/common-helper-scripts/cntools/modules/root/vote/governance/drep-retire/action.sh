#!/usr/bin/env bash
# DRep lifecycle through the shared transaction workflow. Functions only.

cntools_action_main() {
  cntools_governance_action_drep_retire
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
