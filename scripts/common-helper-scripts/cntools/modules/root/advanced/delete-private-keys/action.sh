#!/usr/bin/env bash
# Guarded removal of reviewed private keys, retaining public/operational data.

cntools_action_main() {
  cntools_private_keys_action
}

cntools_action_cleanup() {
  cntools_private_keys_restore_locks
  cntools_wallet_material_cleanup
  cntools_transaction_cleanup
}
