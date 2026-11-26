#!/usr/bin/env bash
# CNTools mnemonic wallet import action. Functions only.

cntools_action_main() {
  cntools_wallet_action_import_mnemonic
}

cntools_action_cleanup() {
  cntools_wallet_cleanup_material
  cntools_wallet_create_cleanup
  cntools_wallet_mnemonic_cleanup
}
