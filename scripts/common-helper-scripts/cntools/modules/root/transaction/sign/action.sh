#!/usr/bin/env bash
# CNTools transaction-package signing action. Functions only.

cntools_action_main() {
  cntools_transaction_action_sign
}

cntools_action_cleanup() {
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
