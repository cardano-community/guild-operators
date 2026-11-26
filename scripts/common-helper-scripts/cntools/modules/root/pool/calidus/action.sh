#!/usr/bin/env bash
# CNTools Calidus identity, authorization and registration. Functions only.

cntools_action_main() {
  cntools_pool_action_calidus
}

cntools_action_cleanup() {
  cntools_calidus_publication_cleanup
  cntools_pool_files_cleanup
  cntools_transaction_cleanup
}
