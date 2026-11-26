#!/usr/bin/env bash
# Public-only threshold DRep identity setup. Functions only.

cntools_action_main() {
  cntools_drep_script_action_create
}

cntools_action_cleanup() {
  cntools_drep_script_publication_cleanup
  cntools_wallet_material_cleanup
  cntools_wallet_create_cleanup
  cntools_wallet_query_cleanup
  cntools_transaction_cleanup
}
