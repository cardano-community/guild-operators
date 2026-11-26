#!/usr/bin/env bash
# Explicit self-collection; transaction packages use the shared lifecycle.
cntools_action_main() { cntools_funds_action_collect; }
cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
