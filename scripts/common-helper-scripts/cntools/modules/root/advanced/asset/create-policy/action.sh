#!/usr/bin/env bash
# Guided native-asset policy creation. Functions only.

cntools_action_main() {
  cntools_policy_action_create
}

cntools_action_cleanup() {
  cntools_policy_files_cleanup
  cntools_transaction_cleanup
}
