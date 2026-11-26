#!/usr/bin/env bash
# Lazy-loaded asset action.
cntools_action_main() {
  cntools_registry_action
}

cntools_action_cleanup() {
  cntools_registry_cleanup
  cntools_policy_files_cleanup
  cntools_transaction_cleanup
  cntools_wallet_material_cleanup
  cntools_wallet_query_cleanup
}
