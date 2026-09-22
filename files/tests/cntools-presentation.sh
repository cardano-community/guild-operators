#!/usr/bin/env bash
# Headerless property tables, preserved grids, and one content/menu gap.
# Set CNTOOLS_TEST_GUM to the deployed pinned Gum for a real renderer check.
# shellcheck disable=SC1090,SC2034,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
. "${CNTOOLS_ROOT}/core/theme.sh"
. "${CNTOOLS_ROOT}/core/gum.sh"
. "${CNTOOLS_ROOT}/lib/funds-send-ui.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_transaction_log() { :; }
cntools_ui_choose() { printf 'MENU\n'; printf -v "$1" One; }
if [[ -n "${CNTOOLS_TEST_GUM:-}" ]]; then
  version_output="$("${CNTOOLS_TEST_GUM}" --version)"
  [[ "${version_output}" =~ ^gum[[:space:]]version[[:space:]]v?([^[:space:]]+) &&
     "${BASH_REMATCH[1]}" == "${CNTOOLS_GUM_REQUIRED_VERSION}" ]] || fail 'Gum is not the deployment pin'
  cntools_gum() { "${CNTOOLS_TEST_GUM}" "$@"; }
else
  cntools_gum() {
    [[ "$1" == table ]] || return 2
    local header="" row=""
    IFS= read -r header || return 1
    printf 'TOP\n%s\nDIVIDER\n' "${header}"
    while IFS= read -r row; do printf '%s\n' "${row}"; done
    printf 'BOTTOM\n'
  }
fi
NO_COLOR=1
result="$(
  printf 'Property\tValue\nFirst key\tFirst value\nLast key\tLast value\n' | cntools_ui_table --separator $'\t'
  cntools_send_choose selected Test One Two
)"
[[ "${result}" != *Property* && "${result}" != *$'Value\n'* ]] || fail 'redundant headers retained'
[[ "${result}" == *'First key'* && "${result}" == *'First value'* && "${result}" == *'Last value'* ]] || fail 'data rows lost'
[[ "${result}" == *$'\n\nMENU' && "${result}" != *$'\n\n\nMENU' ]] || fail 'content / menu gap'
result="$(printf 'Asset\tAvailable\tSelected\nToken\t12\t1\n' | cntools_ui_table --separator $'\t')"
[[ "${result}" == *Available* && "${result}" == *Selected* && "${result}" == *Token* ]] || fail 'multi-column header lost'
result="$(printf 'Word\tWord\n01 alpha\t02 bravo\n03 charlie\t04 delta\n' | cntools_ui_table --keep-header --separator $'\t')"
[[ "${result}" == *Word* && "${result}" == *'01 alpha'* && "${result}" == *'04 delta'* ]] || fail 'two-column word grid lost'
cntools_gum() { return 23; }
status=0
printf 'Key\tValue\nName\tTest\n' | cntools_ui_table --separator $'\t' >/dev/null || status=$?
[[ "${status}" == 23 ]] || fail 'renderer failure swallowed'
printf 'CNTools presentation tests passed.\n'
