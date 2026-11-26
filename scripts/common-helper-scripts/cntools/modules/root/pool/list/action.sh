#!/usr/bin/env bash
# CNTools read-only pool list action. Functions only.

cntools_action_main() {
  cntools_pool_action_list
}

cntools_action_cleanup() {
  cntools_transaction_cleanup
}
