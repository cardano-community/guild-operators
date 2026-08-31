#!/usr/bin/env bash
# CNTools wallet inventory action. Functions only.

cntools_action_main() {
  cntools_wallet_action_list
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
}
