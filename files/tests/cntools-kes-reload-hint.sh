#!/usr/bin/env bash
# After a KES rotation CNTools offers to reload the node. Only cardano-node re-reads its KES key on
# SIGHUP: Dingo reloads through dingo.sh, and Amaru reads the key at startup only and stops on
# SIGHUP. Check the hint each implementation gets when CNTools does not signal the node itself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/pool-kes-ui.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The UI and the unit lookup are stubbed: the hint is what is checked.
cntools_kes_systemd_pid_into() { return 1; }
cntools_ui_render_status() { printf 'STATUS %s %s\n' "$1" "$2"; }
cntools_kes_installed_summary() { printf 'SUMMARY %s\n' "$1"; }

hint_for() {
  CNTOOLS_IMPLEMENTATION="$1" CNTOOLS_SERVICE="$2" CNTOOLS_NODE_HOME=/opt/cardano/node cntools_kes_reload_offer
}

out="$(hint_for amaru amaru.service)"
[[ "${out}" == *"/opt/cardano/node/scripts/amaru.sh restart"* ]] || fail "amaru: no restart command: ${out}"
[[ "${out}" == *"Do not send SIGHUP"* ]] || fail "amaru: no SIGHUP warning: ${out}"
[[ "${out}" != *"cardano-node process"* ]] || fail "amaru: cardano-node advice: ${out}"
[[ "$(grep -c '^SUMMARY' <<< "${out}")" == 1 && "${out}" == *"SUMMARY Still using the previous key · restart it"* ]] ||
  fail "amaru: summary: ${out}"

out="$(hint_for dingo dingo.service)"
[[ "${out}" == *"/opt/cardano/node/scripts/dingo.sh reload"* ]] || fail "dingo: no dingo.sh reload: ${out}"
[[ "${out}" != *"cardano-node process"* ]] || fail "dingo: cardano-node advice: ${out}"

out="$(hint_for cnode cnode.service)"
[[ "${out}" == *"sending SIGHUP to the cardano-node process"* ]] || fail "cnode: hint changed: ${out}"

# The closing note of the installed summary names the same action.
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/pool-kes-ui.sh"
cntools_pool_file_name_into() { printf -v "$1" '%s' "$2"; }
cntools_table_pair() { :; }
cntools_table_render() { cat >/dev/null; }
cntools_number_format() { printf '%s' "$1"; }
cntools_ui_wait() { :; }
cntools_ui_render_status() { printf 'STATUS %s %s\n' "$1" "$2"; }
CNTOOLS_POOL_NAMES=(LABPOOL) CNTOOLS_KES_INDEX=0 CNTOOLS_KES_NEXT=3 CNTOOLS_KES_START=990 CNTOOLS_KES_STAGE=''
note_for() { CNTOOLS_IMPLEMENTATION="$1" cntools_kes_installed_summary 'state' warning; }
[[ "$(note_for amaru)" == *"op.cert there and restart it."* ]] || fail "amaru: summary note: $(note_for amaru)"
[[ "$(note_for cnode)" == *"op.cert there and reload it."* ]] || fail "cnode: summary note: $(note_for cnode)"

printf 'cntools kes reload hint tests passed\n'
