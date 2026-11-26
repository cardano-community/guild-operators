#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2153,SC2154,SC2329
# gLiveView follows the node through its life: the systemd service says
# whether a node without a process is stopped, failed or restarting; while
# cardano-node starts, its log says which phase it is in and how far a check
# or a replay is; with its socket up it waits for the next block, and with
# that block it is ready. Each change is an event, and the node's
# notice says what to do. It also notices files changed after the start
# (config.json, the consensus mode, the topology and the peer snapshot), a
# Genesis node that stays in PreSyncing, and a missing node socket.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'gliveview-lifecycle skipped: Bash 4.4+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'gliveview-lifecycle skipped: jq required\n'; exit 0; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

assert_has() {
  [[ "$1" == *"$2"* ]] || fail "$3: '$2' not in '$1'"
}

for test_locale in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if LC_ALL="${test_locale}" "${BASH}" -c '[[ ${#1} -eq 1 ]]' _ '█' 2>/dev/null; then
    export LC_ALL="${test_locale}"
    break
  fi
done
[[ "${LC_ALL:-}" == *[Uu][Tt][Ff]* ]] || fail "no UTF-8 locale is available for the test"

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"

# glv_load <file> <function>...: define functions copied from a script, both
# one-line and multi-line ones, without running the script.
glv_load() {
  local file="$1" name definition
  shift
  for name in "$@"; do
    definition="$(awk -v name="${name}" '
      !found && index($0, name "() {") == 1 {
        found = 1
        print
        if ($0 ~ /}[[:space:]]*$/) exit
        next
      }
      found { print; if ($0 == "}") exit }' "${file}")"
    [[ -n "${definition}" ]] || fail "${file##*/} no longer defines ${name}"
    eval "${definition}"
  done
}

glv_load "${GLIVEVIEW}" ui_colour_256 ui_colour ui_theme ui_put ui_gap ui_putw ui_endl ui_scale ui_fmt_int \
  ui_fmt_tenths ui_fmt_duration ui_bar ui_box_top ui_panel glv_is_int glv_data_init glv_data_stamp glv_data_event \
  glv_notice glv_notices_sweep glv_notices_tally glv_notices_seen glv_notices_load glv_notices_check \
  glv_notices_node glv_launch_text glv_fmt_span glv_kes_colour glv_opcert_text glv_pool_vital \
  glv_binary_state glv_binary_pin glv_event_colour glv_process_start glv_data_service glv_data_last_error \
  glv_launch_summary glv_launch_reset glv_launch_phase glv_launch_progress glv_launch_chunk glv_launch_line \
  glv_launch_read glv_launch_event glv_launch_events glv_data_launch glv_launch_shown glv_launch_has_tip glv_data_stage glv_data_stage_events \
  glv_data_running_config glv_data_metrics_owner glv_reload_job_start glv_reload_job_poll glv_status glv_slots glv_panel_epoch glv_panel_epoch_start glv_panel_epoch_down \
  glv_launch_wait glv_launch_tip_age glv_data_reference_slot glv_data_watch
eval "$(grep -E '^(UI_RESET|UI_BOLD|UI_L|UI_LW|GLV_ROWS_MAX|GLV_EVENTS_MAX|GLV_NOTICE_NEEDS_NODE|GLV_NOTICE_QUIET)=' "${GLIVEVIEW}")"
printf -v UI_SPACES '%500s' ''
UI_DASHES="${UI_SPACES// /─}"
UI_BLOCKS="${UI_SPACES// /█}"
UI_HELP=''
UI_FOCUS=''
declare -gA UI_PANEL_KEY=() UI_PANEL_TITLE=()
UI_PANELS=()
GLV_COLORS=none
ui_theme default
glv_strip() { sed $'s/\e\\[[0-9;]*m//g'; }

declare -A METRIC=()
node_metric_has() { [[ -n "${METRIC[$1]+set}" ]]; }
NODE_CAPABILITIES="process metrics n2c topology_file block_replay_log"
node_has() { [[ " ${NODE_CAPABILITIES} " == *" $1 "* ]]; }
POOL_STATE=off
declare -gA POOL_INFO=()
REFRESH_RATE=2
EPOCH_LENGTH=432000

# The process start comes from /proc; here it is set by the test.
FAKE_START=1000
glv_process_start() { printf -v "$1" '%s' "${FAKE_START}"; }

# systemctl show prints SYSTEMCTL_SHOW.
SYSTEMCTL_SHOW=''
systemctl() { [[ "$1" == show ]] && printf '%s\n' "${SYSTEMCTL_SHOW}"; }

# journalctl prints the lines of JOURNAL from the line after a cursor (a line
# number), or all of them; -n keeps the last ones, --show-cursor adds a cursor.
JOURNAL=()
journalctl() {
  local from=0 last='' show=N
  while (( $# )); do
    case "$1" in
      --after-cursor) from=$(($2 + 1)); shift ;;
      -n) last="$2"; shift ;;
      --show-cursor) show=Y ;;
    esac
    shift
  done
  local -a lines=("${JOURNAL[@]:from}")
  [[ -z "${last}" ]] || (( ${#lines[@]} <= last )) || lines=("${lines[@]: -last}")
  (( ${#lines[@]} == 0 )) || printf '%s\n' "${lines[@]}"
  [[ "${show}" == N || ${#JOURNAL[@]} -eq 0 ]] || printf -- '-- cursor: %s\n' "$((${#JOURNAL[@]} - 1))"
}

NODE_HOME="${TEST_ROOT}/node"
mkdir -p "${NODE_HOME}/files" "${NODE_HOME}/db/immutable"
NODE_SERVICE=preprod
GLV_NOTICE_STATE_FILE="${TEST_ROOT}/gLiveView.sh.notices"
RELOAD_JOB_FILE="${TEST_ROOT}/reload"
RELOAD_JOB_PID=''
GLV_CLK_TCK=100

# reload_search: lets the background search for a reload finish.
reload_search() {
  glv_data_running_config
  [[ -z "${RELOAD_JOB_PID}" ]] || wait "${RELOAD_JOB_PID}" || true
  glv_reload_job_poll
}

fresh_state() {
  glv_data_init
  D_IMPL=cardano-node; D_NAME=relay1; D_ROLE=Relay; D_VERSION=11.1.3
  D_COLLECTED_AT=1000; D_NOW=1000; D_OK=N; D_PID=''; D_FAILS=0
  VIEW=1
  METRIC=()
  JOURNAL=()
}

# event <index>: an event row without its time stamp.
event() {
  local record="${D_EVENTS[$1]:-}"
  record="${record#E|}"
  printf '%s' "${record#*|}"
}

# collect: what one collection does with the node's state, the way
# glv_data_collect runs it.
collect() {
  [[ -n "${D_PID}" && "${D_STAGE}" == ready ]] || glv_data_service
  glv_data_launch
  glv_data_stage
  glv_data_stage_events
  glv_launch_events
  glv_notices_check
}

# epoch_panel: the Epoch panel as text.
epoch_panel() {
  glv_panel_epoch 80
  printf '%s\n' "${P_EPOCH[@]}" | glv_strip
}

# ── the service of a node without a process ─────────────────────────────────
fresh_state
SYSTEMCTL_SHOW=$'LoadState=loaded\nActiveState=inactive\nSubState=dead\nResult=success\nExecMainCode=1\nExecMainStatus=0\nNRestarts=0\nRestartUSec=1min\nStateChangeTimestamp=Sat 2026-11-21 23:44:36 UTC'
collect
assert_eq "${D_STAGE}" stopped "an inactive service"
if since="$(date -d 'Sat 2026-11-21 23:44:36 UTC' +%s 2>/dev/null)"; then
  assert_eq "${D_SVC_SINCE}" "${since}" "when the service stopped"
  printf -v since ' since %(%H:%M)T' "${since}"
  assert_has "${N_TEXT[node]}" "is stopped${since}," "the notice says since when"
fi
assert_eq "${D_DOWN}" stopped "the reason shown for a stopped node"
assert_eq "$(event 0)" "stopped|service preprod is inactive" "stopping is an event"
assert_eq "${N_LEVEL[node]}" error "a stopped node is an error"
assert_eq "${N_TITLE[node]}" "Node stopped" "stopped title"
assert_has "${N_TEXT[node]}" "sudo systemctl start preprod" "the notice says how to start it"
panel="$(epoch_panel)"
assert_has "${panel}" "cardano-node is stopped: the service preprod is inactive" "the Epoch panel names the stop"
assert_has "${panel}" "Start it with: sudo systemctl start preprod" "the Epoch panel says how to start it"
glv_status text colour
assert_eq "${text}" Stopped "the one-line status"
events_before=${#D_EVENTS[@]}
collect
assert_eq "${#D_EVENTS[@]}" "${events_before}" "the same stage is no new event"

# What cardano-node 11.1.3 prints when it cannot read its topology.
JOURNAL=('{"at":"2026-11-21T10:00:00Z","ns":"ChainDB.OpenEvent.StartedOpeningDB","data":{"kind":"StartedOpeningDB"},"sev":"Info"}'
  'cardano-node: Cardano.Node.Configuration.TopologyP2P.readTopologyFile: Is your topology file formatted correctly? Expecting P2P Topology file format.'
  'CallStack (from HasCallStack):'
  '  error, called at src/Cardano/Node/Configuration/TopologyP2P.hs:149:23 in cardano-node-11.1.3:Cardano.Node.Configuration.TopologyP2P'
  '{"at":"2026-11-21T10:00:01Z","ns":"Net.ErrorPolicy.Remote","data":{"kind":"ErrorPolicyTrace"},"sev":"Info"}'
  "preprod.service: Main process exited, code=exited, status=1/FAILURE"
  "preprod.service: Failed with result 'exit-code'.")
SYSTEMCTL_SHOW=$'LoadState=loaded\nActiveState=activating\nSubState=auto-restart\nResult=exit-code\nExecMainCode=1\nExecMainStatus=1\nNRestarts=3\nRestartUSec=1min\nStateChangeTimestamp='
collect
assert_eq "${D_STAGE}" restarting "a service waiting to be restarted"
assert_eq "${D_SVC_EXIT}" "exit status 1" "the exit status"
assert_eq "$(event 0)" "restarting|exit status 1 · systemd starts it again in 1min" "a restart is an event"
assert_eq "${D_SVC_ERROR}" 'cardano-node: Cardano.Node.Configuration.TopologyP2P.readTopologyFile: Is your topology file formatted correctly? Expecting P2P Topology file format.' \
  "the node's last words, not its call stack, a trace that only names an error policy, or systemd's own lines"
assert_eq "${N_TITLE[node]}" "Node restarting" "restarting title"
assert_has "${N_TEXT[node]}" "it has restarted 3 times" "the notice counts the restarts"
assert_has "${N_TEXT[node]}" 'The last error in its log: cardano-node:' "the notice gives the last error"
assert_has "$(epoch_panel)" 'Last error: cardano-node:' "the Epoch panel gives the last error"

JOURNAL=('{"at":"2026-11-21T10:00:00Z","ns":"Startup.DiffusionInit.DiffusionErrored","data":{"error":"Network.Socket.bind: resource busy (Address already in use)","kind":"DiffusionErrored"},"sev":"Critical"}')
SYSTEMCTL_SHOW=$'LoadState=loaded\nActiveState=failed\nSubState=failed\nResult=signal\nExecMainCode=2\nExecMainStatus=9\nNRestarts=5\nRestartUSec=1min\nStateChangeTimestamp='
collect
assert_eq "${D_STAGE}" failed "a failed service"
assert_eq "${D_SVC_EXIT}" "signal SIGKILL" "a signal"
assert_eq "$(event 0)" "failed|signal SIGKILL" "failing is an event"
assert_eq "${D_SVC_ERROR}" "Startup.DiffusionInit.DiffusionErrored: Network.Socket.bind: resource busy (Address already in use)" \
  "a critical trace, with its namespace and its error"
assert_eq "${N_TITLE[node]}" "Node failed" "failed title"
assert_has "${N_TEXT[node]}" "systemd does not start it again" "a failed service stays down"

# A simple service is active from cnode.sh on, before it becomes the node.
if changed="$(date -d '@990' 2>/dev/null)"; then
  SYSTEMCTL_SHOW="LoadState=loaded"$'\n'"ActiveState=active"$'\n'"SubState=running"$'\n'"StateChangeTimestamp=${changed}"
  D_COLLECTED_AT=1000
  collect
  assert_eq "${D_STAGE}" starting "an active service whose node is not up yet"
  D_COLLECTED_AT=1200
  collect
  assert_eq "${D_STAGE}" "not running" "an active service without a node for minutes"
  D_COLLECTED_AT=1000
fi

# Without systemd, or without a service, it is just not running.
SYSTEMCTL_SHOW=$'LoadState=not-found\nActiveState=inactive'
collect
assert_eq "${D_STAGE}" "not running" "no service to ask"
assert_eq "${N_TITLE[node]}" "Node not running" "not running title"
assert_eq "$(event 0)" "node lost|cardano-node not running" "losing the node is an event"

# ── a start, phase by phase ──────────────────────────────────────────────────
# The lines are what cardano-node 11.1.3 logs through systemd, shortened.
fresh_state
SYSTEMCTL_SHOW=$'LoadState=loaded\nActiveState=active\nSubState=running\nResult=success'
D_PID=4242
JOURNAL=('INFO: Cleaned-up stale socket file'
  'Node configuration: NodeConfiguration {ncSocketConfig = SocketConfig {ncNodePortNumber = Last {getLast = Just 2101}}, ncConsensusMode = PraosMode, ncPeerSharing = PeerSharingEnabled}'
  '{"at":"2026-11-21T23:07:18.10Z","ns":"Startup.Common","data":{"configPath":"/opt/cardano/preprod/files/config.json","kind":"BasicInfoCommon","version":"11.1.3"},"sev":"Info","thread":"7"}'
  '{"at":"2026-11-21T23:07:18.10Z","ns":"ChainDB.OpenEvent.StartedOpeningDB","data":{"kind":"StartedOpeningDB"},"sev":"Info","thread":"7"}'
  '{"at":"2026-11-21T23:07:18.10Z","ns":"ChainDB.OpenEvent.StartedOpeningImmutableDB","data":{"kind":"StartedOpeningImmutableDB"},"sev":"Info","thread":"7"}')
collect
assert_eq "${D_STAGE}" starting "a process that does not report a tip yet"
assert_eq "${D_RUN_MODE}" PraosMode "the consensus mode from the node's configuration line"
assert_eq "${D_START_TEXT}" "Opening the database" "the first phase"
assert_eq "$(event 0)" "startup|opening the database" "a phase is an event"
assert_eq "$(event 1)" "consensus|Praos mode" "the consensus mode is an event"
assert_eq "$(event 2)" "starting|cardano-node, process 4242" "a new process is the first event"
assert_eq "${N_LEVEL[node]}" info "a start is only info"
assert_eq "${N_TITLE[node]}" "Node starting" "starting title"
assert_has "${N_TEXT[node]}" "cardano-node: opening the database. It started 0 s ago." "the start as a sentence"
assert_eq "${N_RAIL[*]:-}" "" "a start is not in the rail"
panel="$(epoch_panel)"
assert_has "${panel}" "Starting" "the panel title while it starts"
assert_has "${panel}" "Opening the database · started 0 s ago" "the phase on the first line"
assert_has "${panel}" "It reports its tip once its database is open and its socket is up." "what it waits for"

# After an unclean stop every chunk is checked; the chunk files give the total.
D_START_DB="${NODE_HOME}/db"
for chunk in 00000 00001 00039 00040; do : > "${NODE_HOME}/db/immutable/${chunk}.chunk"; done
JOURNAL+=('{"at":"2026-11-21T23:07:20Z","ns":"ChainDB.ImmDbEvent.ChunkValidation.ValidatedChunk","data":{"chunkNo":"10","kind":"TraceImmutableDBEvent.ValidatedChunk"},"sev":"Info"}'
  '{"at":"2026-11-21T23:07:21Z","ns":"ChainDB.ImmDbEvent.ChunkValidation.ValidatedChunk","data":{"chunkNo":"20","kind":"TraceImmutableDBEvent.ValidatedChunk"},"sev":"Info"}')
D_COLLECTED_AT=1010
collect
assert_eq "${D_START_LAST_CHUNK}" 40 "the last chunk on disk"
assert_eq "${D_START_TEXT}" "Checking the immutable DB" "checking the chunks"
assert_eq "${D_START_PROGRESS}" 500 "chunk 20 of 40"
assert_eq "$(event 0)" "startup|checking the immutable DB" "the check is an event"
glv_status text colour
assert_eq "${text}" "Starting 50.0 %" "the one-line status while it starts"

JOURNAL+=('{"at":"2026-11-21T23:07:22Z","ns":"ChainDB.OpenEvent.OpenedImmutableDB","data":{"epoch":"6461","kind":"OpenedImmutableDB"},"sev":"Info"}'
  '{"at":"2026-11-21T23:07:22Z","ns":"ChainDB.OpenEvent.StartedOpeningLgrDB","data":{"kind":"StartedOpeningLgrDB"},"sev":"Info"}'
  '{"at":"2026-11-21T23:07:33Z","ns":"ChainDB.LedgerEvent.Replay.ReplayStart.ReplayFromSnapshot","data":{"kind":"ReplayFromSnapshot"},"sev":"Info"}'
  '{"at":"2026-11-21T23:07:33Z","ns":"ChainDB.ReplayBlock.LedgerReplay","data":{"kind":"ReplayBlockStats","progress":"12.53"},"sev":"Info"}')
D_COLLECTED_AT=1020
collect
assert_eq "${D_START_TEXT}" "Replaying the ledger from a snapshot" "the replay"
assert_eq "${D_START_PROGRESS}" 125 "the replay's progress in tenths of a percent"
assert_eq "$(event 0)" "startup|replaying the ledger from a snapshot" "the newest phase of a batch"
assert_eq "$(event 1)" "startup|opening the ledger" "a phase a read passed is an event too"
assert_eq "$(event 2)" "startup|checking the immutable DB" "the phase before"
assert_eq "${D_START_LEFT}" "" "no time left from one figure"
JOURNAL+=('{"at":"2026-11-21T23:08:03Z","ns":"Resources","data":{"kind":"ResourceStats"},"sev":"Info"}'
  '{"at":"2026-11-21T23:08:03Z","ns":"ChainDB.ReplayBlock.LedgerReplay","data":{"kind":"ReplayBlockStats","progress":"42.5"},"sev":"Info"}')
D_COLLECTED_AT=1050
collect
assert_eq "${D_START_PROGRESS}" 425 "a later replay figure"
assert_eq "${D_START_LEFT}" 57 "the time left at the pace so far"
panel="$(epoch_panel)"
assert_has "${panel}" "42.5 % · about 57 s left" "the panel's border gives the progress and the time left"
assert_has "${panel}" "██" "a bar while it replays"
assert_has "${panel}" "Replaying the ledger from a snapshot · started 50 s ago" "the phase under the bar"
assert_has "${N_TEXT[node]}" "cardano-node: replaying the ledger from a snapshot, 42.5 %, about 57 s left." "the notice says how far"

# The metrics answer during the replay, without a tip; the sync line stays out.
D_OK=Y
METRIC=([sync_phase]=1 [sync_progress]=1)
sync_phase="Ledger replay"; sync_progress=42.50
glv_launch_shown || fail "the start is shown while its log says how far it is"
assert_eq "$(epoch_panel | grep -c 'Sync:' || true)" 0 "no sync line while the start is shown"
glv_status text colour
assert_eq "${text}" "Starting 42.5 %" "starting wins over the metrics"

JOURNAL+=('{"at":"2026-11-21T23:08:04Z","ns":"ChainDB.OpenEvent.OpenedLgrDB","data":{"kind":"OpenedLgrDB"},"sev":"Info"}'
  '{"at":"2026-11-21T23:08:04Z","ns":"ChainDB.InitChainSelEvent.StartedInitChainSelection","data":{"kind":"Follower.StartedInitChainSelection"},"sev":"Info"}')
D_COLLECTED_AT=1052
collect
assert_eq "${D_START_TEXT}" "Selecting the chain" "the chain selection"
assert_eq "${D_START_PROGRESS}" "" "a phase without a figure"
JOURNAL+=('{"at":"2026-11-21T23:08:06Z","ns":"ChainDB.OpenEvent.OpenedDB","data":{"immtip":{"headerHash":"99cd","kind":"BlockPoint","slot":900},"kind":"OpenedDB","tip":{"headerHash":"d15d","kind":"BlockPoint","slot":1022}},"sev":"Info"}'
  '{"at":"2026-11-21T23:08:06Z","ns":"Consensus.GSM.InitializedInCaughtUp","data":{"kind":"GsmEventInitializedInCaughtUp"},"sev":"Notice"}'
  '{"at":"2026-11-21T23:08:06Z","ns":"Startup.DiffusionInit.LocalSocketUp","data":{"kind":"LocalSocketUp"},"sev":"Info"}')
# Slot n starts n seconds after genesis, so the wall clock is slot 1074.
SHELLEY_TRANS_EPOCH=0; BYRON_EPOCH_LENGTH=21600; BYRON_SLOT_LENGTH=20000; BYRON_GENESIS_START_SEC=0; SLOT_LENGTH=1
D_BLOCK_EVERY=20
D_COLLECTED_AT=1074; D_NOW=1074
METRIC=()
collect
# cardano-node reports its tip only when it adds a block to its chain: after a
# short stop, that is the next block the network makes.
assert_eq "${D_STAGE}" starting "the socket is up, but the node reports no tip yet"
assert_eq "${D_START_TIP_SLOT}" 1022 "the last block on its chain, not the immutable tip"
assert_eq "$(event 0)" "startup|socket up after 1 min, waiting for the next block" "the socket is an event"
assert_eq "$(event 1)" "startup|starting the network" "the network phase the same read passed"
assert_eq "${N_LEVEL[node]}" info "still starting"
assert_has "${N_TEXT[node]}" "cardano-node: waiting for the next block. It started 1 min ago. Its socket is up." "the notice says what it waits for"
panel="$(epoch_panel)"
assert_has "${panel}" "Waiting for the next block · last block 52 s ago · started 1 min ago" "the wait and the age of the chain"
assert_has "${panel}" "Socket up. The tip shows with the next block; one every 20 s on average." "what it waits for"
assert_has "${N_TEXT[node]}" "its last block is 52 s old, and a new one comes every 20 s on average." "the notice says how old its chain is"
D_GSM=2
glv_data_watch
assert_eq "$(event 0)" "caught up|the node follows the tip" "the first Genesis state of a new process is an event"
D_GSM=0; D_BIG_HOT=3; D_CONF_MIN_BIG=5
glv_launch_wait text
assert_eq "${text}" "Its socket is up. In Genesis mode it fetches blocks once enough big ledger peers are active (3 of 5)." \
  "a pre-syncing node waits for big ledger peers"
glv_launch_wait text short
assert_eq "${text}" "Socket up. Genesis pre-syncing: blocks come once enough big ledger peers are active (3 of 5)." \
  "the same on the Epoch panel's line"
D_GSM=2
D_COLLECTED_AT=1109; D_NOW=1109
METRIC=([slotnum]=1 [blocknum]=1); slotnum=1100; blocknum=4882008
collect
assert_eq "${D_STAGE}" ready "the first block"
assert_eq "$(event 0)" "ready|started in 1 min, at block 4,882,008" "ready is an event with the time the start took and the block"
assert_eq "${N_LEVEL[node]:-}" "" "the node's notice clears"
METRIC=()
reads=${#JOURNAL[@]}
JOURNAL+=('{"at":"2026-11-21T23:09:00Z","ns":"ChainDB.ReplayBlock.LedgerReplay","data":{"progress":"1.0"},"sev":"Info"}')
D_OK=Y
collect
assert_eq "${D_START_TEXT}" "" "the log is not read once the node is ready"
glv_event_colour colour ready
assert_eq "${colour}" "${C_OK}" "ready is good news"
glv_event_colour colour startup
assert_eq "${colour}" "${C_MUTED}" "a phase is plain information"

# A node that reports a tip when gLiveView first sees it is ready at once.
fresh_state
D_PID=77; D_OK=Y
METRIC=([slotnum]=1); slotnum=139619225
JOURNAL=('Node configuration: NodeConfiguration {ncConsensusMode = GenesisMode}' '{"ns":"ChainDB.OpenEvent.StartedOpeningDB","sev":"Info"}')
collect
assert_eq "${D_STAGE}" ready "a node that runs already"
assert_eq "${D_START_TEXT}" "" "its start is not replayed"
assert_eq "${D_RUN_MODE}" GenesisMode "its consensus mode is still read"
assert_eq "${#D_EVENTS[@]}" 1 "only the consensus mode is an event"
assert_eq "$(event 0)" "consensus|Genesis mode" "the consensus mode event"
D_GSM=2
glv_data_watch
assert_eq "${#D_EVENTS[@]}" 1 "the Genesis state of a node that runs already is no event"

# Metrics that stop answering end the wait for the next block.
fresh_state
D_PID=55; D_OK=Y; FAKE_START=1000; D_COLLECTED_AT=1020
JOURNAL=('{"ns":"Startup.DiffusionInit.LocalSocketUp","sev":"Info"}')
collect
assert_eq "${D_START_PHASE}" tip "waiting for the next block"
D_OK=N; D_FAILS=1
collect
assert_eq "${D_STAGE}" starting "one failed read keeps the wait"
D_FAILS=2
collect
assert_eq "${D_STAGE}" "no metrics" "two failed reads end it"
D_FAILS=0

# A start whose first tip comes in the read that sees its socket, as after a
# long replay: the Genesis state of the new process still follows ready.
fresh_state
D_PID=66; D_OK=Y; FAKE_START=1000; D_COLLECTED_AT=1010
JOURNAL=('{"ns":"ChainDB.OpenEvent.StartedOpeningDB","sev":"Info"}')
collect
assert_eq "${D_STAGE}" starting "opening its database"
JOURNAL+=('{"ns":"Startup.DiffusionInit.LocalSocketUp","sev":"Info"}')
METRIC=([slotnum]=1 [blocknum]=1); slotnum=1100; blocknum=4882008
D_COLLECTED_AT=1090
collect
assert_eq "${D_STAGE}" ready "the socket and the tip in one read"
D_GSM=2
glv_data_watch
assert_eq "$(event 0)" "caught up|the node follows the tip" "its first Genesis state is still an event"
assert_has "$(event 1)" "ready|started in 1 min, at block 4,882,008" "right after the ready event"

# With no log to read, a node that has run for three minutes counts as started.
fresh_state
NODE_CAPABILITIES="process metrics"
D_PID=88; FAKE_START=1000; D_COLLECTED_AT=1100
collect
assert_eq "${D_STAGE}" starting "a minute and a half without a tip"
D_COLLECTED_AT=1181
collect
assert_eq "${D_STAGE}" "no metrics" "three minutes without a log or metrics"
assert_eq "${N_TITLE[node]}" "No metrics from node" "the old notice comes back"
NODE_CAPABILITIES="process metrics n2c topology_file block_replay_log"

# A socket the process created says it is up, also when the log line is buried.
if stat -c %Y / >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  fresh_state
  D_PID=66; FAKE_START=$(( $(date +%s) - 60 )); D_COLLECTED_AT=$(date +%s)
  CARDANO_NODE_SOCKET_PATH="${TEST_ROOT}/fresh.socket"
  JOURNAL=('{"ns":"ChainDB.OpenEvent.OpenedDB","sev":"Info"}')
  collect
  assert_eq "${D_STAGE}" starting "no socket yet"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${CARDANO_NODE_SOCKET_PATH}"
  collect
  assert_eq "${D_STAGE}" "no metrics" "a socket newer than the process: started, but no metrics"
  # A socket left from the last process does not count.
  fresh_state
  D_PID=67; FAKE_START=$(( $(date +%s) + 60 )); D_COLLECTED_AT=$(( $(date +%s) + 61 ))
  collect
  assert_eq "${D_STAGE}" starting "a socket older than the process"
  rm -f -- "${CARDANO_NODE_SOCKET_PATH}"
  unset CARDANO_NODE_SOCKET_PATH
fi

# The text log format (HumanFormat) gives the replay's progress too.
fresh_state
D_PID=99
JOURNAL=('[relay1:cardano.node.ChainDB:Info:5] [2026-11-21 10:00:00.00 UTC] Replayed block: slot 120000 out of 139619225. Progress: 64.25%')
collect
assert_eq "${D_START_TEXT}" "Replaying the ledger" "the replay from a text log"
assert_eq "${D_START_PROGRESS}" 642 "the progress from a text log"

# ── files changed after the start ────────────────────────────────────────────
# gLiveView reads file times with GNU stat, as on the Linux hosts it runs on.
if stat -c %Y / >/dev/null 2>&1; then
# set_mtime <epoch> <file>...: GNU touch, else perl.
set_mtime() {
  local when="$1"
  shift
  touch -d "@${when}" "$@" 2>/dev/null || perl -e 'utime $ARGV[0], $ARGV[0], @ARGV[1..$#ARGV]' "${when}" "$@"
}
fresh_state
D_PID=4242; D_OK=Y; FAKE_START=1000
METRIC=([slotnum]=1); slotnum=5
NODE_CONFIG="${NODE_HOME}/files/config.json"
jq -n '{ConsensusMode: "GenesisMode", MinBigLedgerPeersForTrustedState: 3}' > "${NODE_CONFIG}"
jq -n '{peerSnapshotFile: "peer-snapshot.json", useLedgerAfterSlot: 1}' > "${NODE_HOME}/files/topology.json"
printf '{}\n' > "${NODE_HOME}/files/peer-snapshot.json"
set_mtime 900 "${NODE_CONFIG}" "${NODE_HOME}/files/topology.json" "${NODE_HOME}/files/peer-snapshot.json"
JOURNAL=('Node configuration: NodeConfiguration {ncConsensusMode = PraosMode}')
collect
glv_data_running_config
assert_eq "${D_CONF_MODE}" GenesisMode "the mode config.json sets"
assert_eq "${D_CONF_MIN_BIG}" 3 "the big ledger peers Genesis needs"
assert_eq "${D_RECONF_FILES}${D_TOPO_FILES}" "" "files older than the start"
glv_notices_check
assert_eq "${N_LEVEL[reconfig]}" warning "a consensus mode the node did not start in"
assert_eq "${N_TITLE[reconfig]}" "Restart for Genesis" "the title names the mode"
assert_has "${N_TEXT[reconfig]}" "config.json sets GenesisMode, but the running node started in PraosMode" "the text names both modes"
assert_has "${N_TEXT[reconfig]}" "a reload does not change it: restart it with: sudo systemctl restart preprod" "a restart, not a reload"

D_RUN_MODE=GenesisMode
glv_notices_check
assert_eq "${N_LEVEL[reconfig]:-}" "" "the node runs the mode config.json sets"
set_mtime 1100 "${NODE_CONFIG}"
glv_data_running_config
assert_eq "${D_RECONF_FILES}" config.json "config.json changed after the start"
glv_notices_check
assert_eq "${N_TITLE[reconfig]}" "Restart for new config" "a changed config.json"
assert_has "${N_TEXT[reconfig]}" "config.json changed at " "the text names the file"
set_mtime 1002 "${NODE_CONFIG}"
glv_data_running_config
assert_eq "${D_RECONF_FILES}" "" "a file written while the process came up was read by it"

set_mtime 1100 "${NODE_HOME}/files/topology.json" "${NODE_HOME}/files/peer-snapshot.json"
glv_data_running_config
assert_eq "${D_TOPO_FILES}" "topology.json peer-snapshot.json" "the topology and the peer snapshot it names"
[[ -n "${RELOAD_JOB_PID}" ]] || fail "a background search for a reload"
glv_notices_check
assert_eq "${N_LEVEL[topology]:-}" "" "no notice before the search has an answer"
wait "${RELOAD_JOB_PID}" || true
glv_reload_job_poll
assert_eq "${D_TOPO_KNOWN}${D_TOPO_RELOADED}" YN "the search found no reload"
glv_notices_check
assert_eq "${N_TITLE[topology]}" "Topology not reloaded" "a topology the node has not read yet"
assert_has "${N_TEXT[topology]}" "topology.json and peer-snapshot.json changed at " "the text names both files"
assert_has "${N_TEXT[topology]}" "cnode.sh systemd reload" "the text says how to reload"
JOURNAL+=('{"ns":"Startup.NetworkConfigUpdate","data":{"kind":"NetworkConfigUpdate","message":"network configuration update"},"sev":"Info"}')
reload_search
assert_eq "${D_TOPO_RELOADED}" Y "a reload after the change"
glv_notices_check
assert_eq "${N_LEVEL[topology]:-}" "" "the reload clears the notice"
set_mtime 1200 "${NODE_HOME}/files/topology.json"
JOURNAL=()
reload_search
assert_eq "${D_TOPO_RELOADED}" N "a newer change needs a newer reload"
# A search started for an older change does not count for a newer one.
JOURNAL=('{"ns":"Startup.NetworkConfigUpdate","sev":"Info"}')
glv_data_running_config
[[ -z "${RELOAD_JOB_PID}" ]] || wait "${RELOAD_JOB_PID}" || true
D_TOPO_SEEN=1300
glv_reload_job_poll
assert_eq "${D_TOPO_RELOADED}" N "a stale answer is dropped"
JOURNAL=()

# A restart reads them all again.
FAKE_START=1300; D_PID=4343
collect
glv_data_running_config
assert_eq "${D_RECONF_FILES}${D_TOPO_FILES}" "" "nothing changed since the new start"
else
  printf 'gliveview-lifecycle: files changed after the start skipped, no GNU stat\n'
fi

# ── Genesis, the socket ──────────────────────────────────────────────────────
fresh_state
D_PID=4242; D_OK=Y; FAKE_START=1000
METRIC=([slotnum]=1); slotnum=5
CARDANO_NODE_SOCKET_PATH="${TEST_ROOT}/node.socket"
collect
D_CONF_MIN_BIG=3; D_BIG_HOT=1
D_GSM=0; D_GSM_SINCE=1000; D_COLLECTED_AT=1200
glv_notices_check
assert_eq "${N_LEVEL[genesis]:-}" "" "a few minutes in PreSyncing are normal"
D_COLLECTED_AT=1301
glv_notices_check
assert_eq "${N_TITLE[genesis]}" "Genesis pre-syncing" "five minutes in PreSyncing"
assert_has "${N_TEXT[genesis]}" "It has 1; MinBigLedgerPeersForTrustedState asks for 3." "the peers it has and needs"
assert_eq "${N_TITLE[socket]}" "No node socket" "no socket a minute after the start"
assert_has "${N_TEXT[socket]}" "no socket at ${TEST_ROOT}/node.socket" "the socket path"
D_START_SOCKET_PATH=/other/node.socket
glv_notices_check
assert_has "${N_TEXT[socket]}" "started with --socket-path /other/node.socket: set SOCKET in scripts/env" "a socket elsewhere"
D_GSM=2
glv_notices_check
assert_eq "${N_LEVEL[genesis]:-}" "" "caught up"

# ── another node on this node's metrics port ─────────────────────────────────
declare -A LABEL=()
prometheus_metric_label() { [[ -n "${LABEL[$1|$2]+set}" ]] && printf '%s\n' "${LABEL[$1|$2]}"; }
node_metric_reset_availability() { METRIC=(); }
common_parse_cardano_metrics() { :; }
D_METRICS_URL=http://127.0.0.1:12798/metrics
if mine="$(date -d '2026-11-21 23:45:50 UTC' +%s 2>/dev/null)"; then
  fresh_state
  FAKE_START="${mine}"; D_COLLECTED_AT=$((mine + 10)); D_PID=5151; D_OK=Y
  METRIC=([slotnum]=1); slotnum=5
  LABEL=([cardano_node_metrics_basicInfo|nodeStartTime]="2026-11-21 23:22:05.982768126 UTC")
  JOURNAL=('{"at":"2026-11-21T23:45:54.40Z","ns":"NodeState.PrometheusSimple.Stop","data":{"kind":"TracePrometheusSimpleStop","message":"Network.Socket.bind: resource busy (Address in use)"},"sev":"Warning"}')
  glv_launch_reset
  glv_data_metrics_owner
  assert_eq "${D_METRICS_FOREIGN}" Y "metrics of a node that started before this process"
  assert_eq "${D_OK}" N "they are not this node's"
  collect
  assert_eq "${D_START_PROM}" "NodeState.PrometheusSimple.Stop: Network.Socket.bind: resource busy (Address in use)" \
    "the node's own report that it could not open the port"
  assert_eq "${N_TITLE[metrics]}" "Metrics port taken" "the metrics notice"
  assert_has "${N_TEXT[metrics]}" "the metrics there come from another node, started at 2026-11-21" "another node's start"
  assert_has "${N_TEXT[metrics]}" "its own PrometheusSimple port in config.json" "what to change"
  [[ "${N_LEVEL[node]:-}" != error ]] || fail "no second error for the same cause"
  LABEL=([cardano_node_metrics_basicInfo|nodeStartTime]="2026-11-21 23:45:51.1 UTC")
  D_OK=Y
  glv_data_metrics_owner
  assert_eq "${D_METRICS_FOREIGN}${D_OK}" NY "the node's own metrics"
fi

printf 'gliveview-lifecycle: ok\n'
