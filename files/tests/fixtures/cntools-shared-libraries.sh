#!/usr/bin/env bash
# Test-only bootstrap for independently sourced libraries. Runtime dependencies
# are explicit in module.json; this is not sourced by the application.
for cntools_test_library in number filesystem bech32 presentation table json transaction-balance; do
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/${cntools_test_library}.sh"
done
unset cntools_test_library
