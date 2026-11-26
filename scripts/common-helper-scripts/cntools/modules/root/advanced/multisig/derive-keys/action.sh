#!/usr/bin/env bash
# Multisig derive-keys action. Functions only.

cntools_action_main() {
  cntools_multisig_action_derive
}

cntools_action_cleanup() {
  cntools_multisig_key_publication_cleanup
  cntools_wallet_cleanup_material
  cntools_wallet_create_cleanup
  cntools_wallet_mnemonic_cleanup
  cntools_transaction_cleanup
}
