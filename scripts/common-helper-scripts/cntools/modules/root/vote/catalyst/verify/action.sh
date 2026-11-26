#!/usr/bin/env bash
# Official Catalyst fund snapshot lookup.

cntools_action_main() {
  cntools_catalyst_action_verify
}

cntools_action_cleanup() { cntools_transaction_cleanup; }
