#!/usr/bin/env bash
# Multisig create action. Functions only.

cntools_action_main() {
  cntools_multisig_action_create
}

cntools_action_cleanup() {
  cntools_wallet_cleanup_material
  cntools_wallet_create_cleanup
  cntools_wallet_mnemonic_cleanup
  cntools_transaction_cleanup
}
