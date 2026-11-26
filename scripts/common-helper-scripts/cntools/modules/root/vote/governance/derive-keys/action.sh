#!/usr/bin/env bash
# Wallet-scoped governance action. Functions only.

cntools_action_main() {
  cntools_governance_action_keys
}

cntools_action_cleanup() {
  cntools_wallet_mnemonic_cleanup
  cntools_wallet_material_cleanup
  cntools_wallet_create_cleanup
  cntools_wallet_query_cleanup
  cntools_transaction_cleanup
}
