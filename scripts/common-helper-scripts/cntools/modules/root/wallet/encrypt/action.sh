#!/usr/bin/env bash
# CNTools wallet encryption action. Functions only.

cntools_action_main() {
  cntools_wallet_action_encrypt
}

cntools_action_cleanup() {
  cntools_wallet_protection_cleanup
}
