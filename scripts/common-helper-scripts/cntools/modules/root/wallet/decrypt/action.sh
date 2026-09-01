#!/usr/bin/env bash
# CNTools wallet decryption action. Functions only.

cntools_action_main() {
  cntools_wallet_action_decrypt
}

cntools_action_cleanup() {
  cntools_wallet_protection_cleanup
}
