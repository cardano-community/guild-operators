#!/usr/bin/env bash
# Key-DRep voting through the common transaction workflow. Functions only.

cntools_action_main() {
  local status=0
  cntools_governance_action_cast || status=$?
  # 3: no suitable wallet; the picker already showed why.
  ((status != 3)) || status=0
  return "${status}"
}

cntools_action_cleanup() {
  cntools_wallet_query_cleanup
  cntools_wallet_cleanup_material
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}
