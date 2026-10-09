#!/usr/bin/env bash
# KES UI contracts: default-No approvals, cancellable flows and offline isolation.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-kes-ui.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number pool pool-kes pool-kes-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$1 != $2"; }
cntools_transaction_log() { :; }
cntools_pool_write_error() { CNTOOLS_POOL_WRITE_ERROR="$1"; return 1; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_ui_render_status() { :; }
cntools_ui_wait() { :; }
cntools_kes_review() { :; }
cntools_kes_result() { :; }
cntools_ui_action_begin() { :; }
CNTOOLS_POOL_NAMES=(Test) CNTOOLS_POOL_IDS=(pool_fixture) CNTOOLS_POOL_CERT_CHAIN=('')
CNTOOLS_MODE=offline CNTOOLS_KES_INDEX=0 CNTOOLS_KES_STAGE="${TEST_ROOT}"
(
  CNTOOLS_POOL_NAMES=(First Second) CNTOOLS_POOL_PROTECTIONS=(Open Hardware)
  cntools_ui_choose() { printf -v "$1" '%s' '02  Second · Hardware'; }
  selected=''
  cntools_pool_choose_into selected
  eq "${selected}" 1
)
cntools_kes_environment() { :; }
cntools_pool_catalog_build() { :; }
cntools_pool_choose_into() { printf -v "$1" '%s' 0; }
cntools_kes_identity() { CNTOOLS_KES_DIRECTORY="${TEST_ROOT}/pool"; }
cntools_pool_inspect_catalog() { [[ "${CNTOOLS_MODE}" == offline ]] || fail 'unexpected mode'; }
cntools_pool_health_collect() { :; }
cntools_kes_prepare() { fail 'cancel generated keys'; }
cntools_ui_choose() { printf -v "$1" '%s' Cancel; }
cntools_pool_action_rotate

(
  cntools_ui_confirm() { eq "$2" no; return 1; }
  if cntools_kes_counter_approve; then fail 'counter approved without consent'; fi
  eq "${CNTOOLS_KES_COUNTER_APPROVED}" N
)
(
  cntools_ui_confirm() { eq "$2" no; return 0; }
  cntools_kes_counter_guard() { eq "${CNTOOLS_KES_COUNTER_APPROVED}" Y; }
  cntools_kes_counter_approve
)
(
  CNTOOLS_KES_STAGE="${TEST_ROOT}"
  printf 'issued\n' > "${TEST_ROOT}/phase"
  cntools_ui_choose() { printf -v "$1" '%s' 'Install on this node'; }
  cntools_ui_confirm() { eq "$2" no; return 1; }
  cntools_kes_publish() { fail 'node-stop confirmation ignored'; }
  cntools_kes_continue
)
(
  CNTOOLS_KES_STAGE="${TEST_ROOT}"
  printf 'awaiting\n' > "${TEST_ROOT}/phase"
  cntools_ui_choose() {
    [[ "$*" != *'Issue certificate now'* ]] || fail 'outstanding request offered re-issuance'
    printf -v "$1" '%s' 'Return without changing active keys'
  }
  cntools_kes_issue() { fail 'offline awaiting re-issued'; }
  cntools_kes_continue
)
(
  cntools_kes_period_collect() { CNTOOLS_KES_CURRENT=123; CNTOOLS_KES_PERIOD_SOURCE='Local node'; }
  cntools_ui_input() { fail 'known current period prompted'; }
  cntools_kes_choose_period
  eq "${CNTOOLS_KES_START}" 123
)
(
  cntools_kes_period_collect() { CNTOOLS_KES_CURRENT=''; }
  cntools_ui_input() { printf -v "$1" '%s' '1,234'; }
  cntools_ui_confirm() { eq "$2" no; return 0; }
  cntools_kes_choose_period
  eq "${CNTOOLS_KES_START}" 1234
)
printf 'CNTools KES UI contract tests passed.\n'
