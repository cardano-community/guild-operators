#!/usr/bin/env bash
# Transfers, optional metadata and Handle recipients using the shared foundation.

cntools_action_main() {
  cntools_funds_action_send
}

cntools_action_cleanup() {
  cntools_metadata_reset
  CNTOOLS_SEND_HANDLES=(); CNTOOLS_SEND_RESOLUTIONS=()
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
