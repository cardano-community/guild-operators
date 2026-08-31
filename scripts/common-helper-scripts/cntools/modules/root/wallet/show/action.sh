#!/usr/bin/env bash
# CNTools wallet detail action. Functions only.

cntools_action_main() {
  cntools_wallet_action_show
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
}
