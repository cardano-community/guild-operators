#!/usr/bin/env bash
# CNTools guarded wallet removal action. Functions only.

cntools_action_main() {
  cntools_wallet_action_remove
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
}
