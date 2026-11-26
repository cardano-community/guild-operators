#!/usr/bin/env bash
# CNTools hardware-wallet import action. Functions only.

cntools_action_main() {
  cntools_wallet_action_import_hardware
}

cntools_action_cleanup() {
  cntools_wallet_cleanup_material
  cntools_wallet_create_cleanup
}
