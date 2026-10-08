#!/usr/bin/env bash
# CNTools pool encrypt action. Functions only.

cntools_action_main() {
  cntools_pool_action_protection encrypt
}

cntools_action_cleanup() {
  cntools_pool_protection_cleanup
  cntools_transaction_cleanup
}
