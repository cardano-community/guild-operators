#!/usr/bin/env bash
# CNTools mnemonic wallet generation action. Functions only.

cntools_action_main() {
  cntools_wallet_action_new_mnemonic
}

cntools_action_cleanup() {
  cntools_wallet_cleanup_material
  cntools_wallet_create_cleanup
  cntools_wallet_mnemonic_cleanup
}
