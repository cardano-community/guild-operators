#!/usr/bin/env bash
# Read-only active governance proposal browser. Functions only.

cntools_action_main() {
  cntools_governance_action_proposals
}

cntools_action_cleanup() {
  # Metadata downloads use wallet-query temporary files.
  cntools_wallet_query_cleanup
  cntools_transaction_cleanup
}
