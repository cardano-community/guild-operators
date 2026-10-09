#!/usr/bin/env bash
# Compatibility of existing wallet acceptance cases with separated libraries.
for cntools_test_library in wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view; do
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/${cntools_test_library}.sh"
done
unset cntools_test_library
