#!/usr/bin/env bash
# CNTools staged KES rotation and offline operational-certificate issuance.

cntools_action_main() {
  cntools_pool_action_rotate
}

cntools_action_cleanup() {
  cntools_kes_cleanup
}
