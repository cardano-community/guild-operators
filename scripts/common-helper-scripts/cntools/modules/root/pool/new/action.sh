#!/usr/bin/env bash
# CNTools pool new action. Functions only.

cntools_action_main() {
  cntools_pool_action_new
}

cntools_action_cleanup() {
  cntools_pool_files_cleanup
  cntools_transaction_cleanup
}
