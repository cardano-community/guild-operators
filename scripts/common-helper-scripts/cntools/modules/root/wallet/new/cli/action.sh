#!/usr/bin/env bash
# CNTools standard cardano-cli wallet creation action. Functions only.

cntools_action_main() {
  cntools_wallet_action_new_cli
}

cntools_action_cleanup() {
  cntools_wallet_cleanup_material
  cntools_wallet_create_cleanup
}
