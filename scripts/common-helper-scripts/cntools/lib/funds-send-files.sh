#!/usr/bin/env bash
# Send adapters for shared durable exports.
# shellcheck disable=SC2034

cntools_send_signed_path_into() {
  cntools_transaction_signed_path_into "$@"
}

cntools_send_save_into() {
  cntools_transaction_save_into "$@" send || return 1
  local -n send_saved_ref="$1"
  CNTOOLS_SEND_SAVED_PACKAGE="${send_saved_ref}"
}
