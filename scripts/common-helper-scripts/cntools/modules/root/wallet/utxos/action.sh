#!/usr/bin/env bash
# Read-only Koios wallet browser. Functions only.

cntools_action_main() {
  cntools_history_action utxos
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
}
