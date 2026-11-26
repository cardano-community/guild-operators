#!/usr/bin/env bash
# CNTools read-only pool detail action. Functions only.

cntools_action_main() {
  cntools_pool_action_show
}

cntools_action_cleanup() {
  cntools_transaction_cleanup
}
