#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'cnode-metrics skipped: Bash 4+ required\n'
  exit 0
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${description}: expected '${expected}', got '${actual}'"
}

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library"
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter"

node_has block_replay_log ||
  fail "cnode adapter does not advertise ledger replay progress"

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"
for glv_function in getBlockReplayStatus glvFrameStatus glvFrameProgressBar; do
  glv_definition="$(sed -n "/^${glv_function}() {/,/^}/p" "${GLIVEVIEW}")"
  [[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines ${glv_function}"
  eval "${glv_definition}"
done

CNODEBIN="cardano-node"
CNODE_PORT=3001
CNODE_VNAME="preprod"
NODE_HOME="/opt/cardano/preprod"
PROM_HOST="127.0.0.1"
PROM_PORT="12798"
JOURNAL_CALLS="${TEST_ROOT}/journal.calls"
SERVICE_ACTIVE=0

pgrep() {
  return 1
}
systemctl() {
  [[ "$*" == "is-active --quiet preprod.service" ]] ||
    fail "unexpected systemctl call: $*"
  return "${SERVICE_ACTIVE}"
}
journalctl() {
  printf '%s\n' "$*" >> "${JOURNAL_CALLS}"
  [[ "$*" == "-q -n 10 -o cat -u preprod.service" ]] ||
    fail "unexpected journalctl call: $*"
  printf '%s\n' "${JOURNAL_FIXTURE}"
}
curl() {
  printf '%s\n' "${METRICS_FIXTURE}"
}

replay_json() {
  printf '{"at":"2026-10-29T16:01:%s.330053034Z","ns":"ChainDB.ReplayBlock.LedgerReplay","data":{"kind":"ReplayBlockStats","progress":"%s"},"sev":"Info","thread":"7","host":"cnode-test-c1"}' \
    "$1" "$2"
}
RESOURCES_JSON='{"at":"2026-10-29T16:01:14.000000000Z","ns":"Resources","data":{"kind":"ResourceStats","Alloc":123,"CentiCpu":45},"sev":"Info","thread":"5","host":"cnode-test-c1"}'
STARTUP_JSON='{"at":"2026-10-29T16:00:00.000000000Z","ns":"Startup.Info","data":{"kind":"StartupInfo"},"sev":"Notice","thread":"5","host":"cnode-test-c1"}'
REPLAY_METRICS='
cardano_node_metrics_RTS_gcLiveBytes_int 2791728640
cardano_node_metrics_Mem_resident_int 2791728640'
SYNCED_METRICS='
cardano_node_metrics_RTS_gcLiveBytes_int 2791728640
cardano_node_metrics_slotNum_int 108571234
cardano_node_metrics_blockNum_int 4123456'

# JSON tracing, as written by cardano-node 10 and later.
JOURNAL_FIXTURE="$(printf '%s\n%s' "$(replay_json 12 98.78500051573775)" "$(replay_json 13 98.80500193722425)")"
assert_eq "$(node_adapter_replay_progress)" "98.81" "JSON ledger replay progress"

# The periodic Resources trace can be the newest line between replay lines.
JOURNAL_FIXTURE="$(printf '%s\n%s' "$(replay_json 13 98.80500193722425)" "${RESOURCES_JSON}")"
assert_eq "$(node_adapter_replay_progress)" "98.81" \
  "replay progress behind a later Resources trace"

# Legacy text tracing.
JOURNAL_FIXTURE='[cnode-te:ChainDB.ReplayBlock.LedgerReplay:Info:7] [2023-05-01 10:00:00.00 UTC] Replayed block: slot 41234 out of 90312. Progress: 45.67%'
assert_eq "$(node_adapter_replay_progress)" "45.67" "legacy text ledger replay progress"

JOURNAL_FIXTURE="${STARTUP_JSON}"
if node_adapter_replay_progress >/dev/null; then
  fail "replay progress reported without a replay log line"
fi

SERVICE_ACTIVE=3
JOURNAL_FIXTURE="$(replay_json 13 98.80500193722425)"
if node_adapter_replay_progress >/dev/null; then
  fail "replay progress reported for an inactive service"
fi
SERVICE_ACTIVE=0

# During replay the node exports no tip; collection reports the replay as a
# sync phase and both gLiveView layouts show it.
METRICS_FIXTURE="${REPLAY_METRICS}"
JOURNAL_FIXTURE="$(replay_json 26 98.94500316417778)"
node_metric_reset_availability
node_adapter_collect_metrics || fail "metric collection failed during replay"
node_metric_has sync_phase || fail "replay did not set a sync phase"
assert_eq "${sync_phase}" "Ledger replay" "replay sync phase"
assert_eq "${sync_progress}" "98.95" "replay sync progress"

getBlockReplayStatus
assert_eq "${block_replay_pct:-}" "98.95" "core layout DB Replay value"

width=60
VL="|"
NC=""
style_status_2=""
style_status_3=""
style_values_1=""
granularity=10
char_marked="#"
char_unmarked="."
glv_frame_reset
glvFrameStatus
assert_eq "${#GLV_FRAME_NEXT[@]}" "2" "relay layout replay rows"
[[ "${GLV_FRAME_NEXT[0]}" == "| SYNC: Ledger replay [98.95%] "* ]] ||
  fail "relay layout replay row: got '${GLV_FRAME_NEXT[0]}'"
assert_eq "${GLV_FRAME_NEXT[1]}" "| #########. |" "relay layout replay bar"

# Once the node has a tip, the journal is not read.
: > "${JOURNAL_CALLS}"
METRICS_FIXTURE="${SYNCED_METRICS}"
node_metric_reset_availability
node_adapter_collect_metrics || fail "metric collection failed after replay"
if node_metric_has sync_phase || node_metric_has sync_progress; then
  fail "a synced node reported a ledger replay"
fi
[[ ! -s "${JOURNAL_CALLS}" ]] || fail "the journal was read for a node with a tip"
getBlockReplayStatus
assert_eq "${block_replay_pct:-}" "" "core layout DB Replay value after replay"

printf 'cnode-metrics: ok\n'
