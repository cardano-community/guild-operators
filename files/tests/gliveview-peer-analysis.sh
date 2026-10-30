#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'gliveview-peer-analysis skipped: Bash 4+ required\n'
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

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"
for glv_function in getNodePeerState getCnodePeerState getAmaruPeerState readNodePeerLog saveNodePeerLog peerConnection \
  peerConnAvailable peerScoreFor peerMatchesFilter computePeerStats waitForKeyOrResize \
  resolvePeerAddress getStaticPeers staticPeerLabelFor; do
  glv_definition="$(sed -n "/^${glv_function}() {/,/^}/p" "${GLIVEVIEW}")"
  [[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines ${glv_function}"
  eval "${glv_definition}"
done

peer_filter_dir="all"
peer_filter_state="any"
peer_search=""
peer_filter_static="all"
granularity_small=10
declare -A nodeConnUse=()
declare -A nodePeerTemp=()
declare -A nodePeerScore=()
declare -A nodeRemoteTemp=()
declare -A staticPeer=()
declare -A staticPeerPort=()
declare -A staticPeerEntries=()
staticPeerList=()
node_peer_state_available=false

# The node's own state. On SIGUSR1 cardano-node logs its connection manager
# and peer selection state, read back from its journal. The peer side's state
# comes from the inbound governor's promotion and demotion lines in the same
# log. The process cannot exist, so no unit is found and the journal is
# matched by PID.
NODE_IMPLEMENTATION="cnode"
ENABLE_NODE_PEER_STATE=Y
CNODE_PID=99999999
PS_COMM="cardano-node"
PS_LSTART="Thu Oct 29 23:28:17 2026"
PS_ETIMES=75000
KILL_CALLS="${TEST_ROOT}/kill.calls"
JOURNAL_CALLS="${TEST_ROOT}/journalctl.calls"
STATUS_CALLS="${TEST_ROOT}/status.calls"
PEER_STATE_FILE="${TEST_ROOT}/gLiveView.sh.peerstate"
JOURNAL_READABLE=Y
NO_CURSOR_WHEN_EMPTY=N
DUMP_FIXTURE=""
LOG_LINES=()
ps() {
  case "$*" in
    *comm=*)   printf '%s\n' "${PS_COMM}" ;;
    *lstart=*) printf '%s\n' "${PS_LSTART}" ;;
    *etimes=*) printf '%8s\n' "${PS_ETIMES}" ;;
  esac
}
kill() {
  printf '%s\n' "$*" >> "${KILL_CALLS}"
}
sleep() {
  :
}
peerAnalysisStatus() {
  printf '%s\n' "$1" >> "${STATUS_CALLS}"
}
# LOG_LINES is the node's log; cursor cN points after its Nth line. Reads with
# --show-cursor follow the log, the others return the state dump.
journalctl() {
  local i first=0 after="" show_cursor=N
  local -a args=("$@")
  printf '%s\n' "$*" >> "${JOURNAL_CALLS}"
  for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      -n)
        [[ ${JOURNAL_READABLE} = Y ]] && printf '{"at":"2026-10-30T10:00:00.00Z","ns":"Resources","data":{}}\n'
        return 0 ;;
      --show-cursor) show_cursor=Y ;;
      --after-cursor) after=${args[i + 1]} ;;
    esac
  done
  if [[ ${show_cursor} = N ]]; then
    [[ -z ${DUMP_FIXTURE} ]] || printf '%s\n' "${DUMP_FIXTURE}"
    return 0
  fi
  if [[ -n ${after} ]]; then
    if [[ ! ${after} =~ ^c([0-9]+)$ ]]; then
      printf 'Failed to seek to cursor: Invalid argument\n' >&2
      return 1
    fi
    first=${BASH_REMATCH[1]}
  fi
  for ((i = first; i < ${#LOG_LINES[@]}; i++)); do
    printf '%s\n' "${LOG_LINES[i]}"
  done
  if [[ ${first} -lt ${#LOG_LINES[@]} || ${NO_CURSOR_WHEN_EMPTY} != Y ]]; then
    printf -- '-- cursor: c%s\n' "${#LOG_LINES[@]}"
  fi
}
conn() {
  printf '{"connections":[{"localAddress":{"address":"192.0.2.1","port":"%s"},"state":{%s"kind":"%s"}}],"remoteAddress":{"address":"%s","port":"%s"}}' \
    "$3" "${5:+\"dataFlow\":\"$5\",}" "$4" "$1" "$2"
}
addr() {
  printf '{"address":"%s","port":"%s"}' "$1" "$2"
}
cm_state() {
  local IFS=,
  printf '{"at":"2026-10-30T10:00:01.00Z","ns":"Net.ConnectionManager.Remote.State","data":{"state":[%s]},"sev":"Info","thread":"5","host":"relay"}' "$*"
}
inbound() {
  printf '{"at":"2026-10-30T09:00:00.00Z","ns":"Net.InboundGovernor.Remote.%s","data":{"connectionId":{"localAddress":{"address":"192.0.2.1","port":"%s"},"remoteAddress":{"address":"%s","port":"%s"}},"kind":"%s"},"sev":"Info"}' \
    "$1" "$4" "$2" "$3" "$1"
}
# The node listens on 6000. 188.66.62.55 runs two nodes: the one on 2131 has
# a connection of its own to the node, and the node dialed it from 57376.
CM_STALE="$(cm_state "$(conn 203.0.113.10 3001 6000 InboundIdleSt Duplex)")"
CM_RECORD="$(cm_state \
  "$(conn 203.0.113.10 3001 6000 DuplexSt)" \
  "$(conn 203.0.113.10 43122 6000 InboundSt Duplex)" \
  "$(conn 2001:db8::7 3001 6000 OutboundDupSt)" \
  "$(conn 198.51.100.4 6000 6000 InboundIdleSt Duplex)" \
  "$(conn 188.66.62.55 2111 6000 DuplexSt)" \
  "$(conn 188.66.62.55 2131 6000 InboundSt Duplex)" \
  "$(conn 188.66.62.55 2131 57376 OutboundUniSt)" \
  "$(conn ::ffff:192.0.2.80 3001 6000 OutboundUniSt)" \
  "$(conn 192.0.2.99 6000 6000 UnnegotiatedSt)")"
SELECTION_RECORD="$(printf '{"at":"2026-10-30T10:00:01.01Z","ns":"Net.PeerSelection.Selection.DebugState","data":{"activePeers":[%s,%s,%s],"establishedPeers":[%s,%s,%s,%s,%s],"upstreamyness":[[%s,6],[%s,2]],"fetchynessBlocks":[[%s,2],[%s,0]],"targets":{"active":20}},"sev":"Info"}' \
  "$(addr 203.0.113.10 3001)" "$(addr 188.66.62.55 2111)" "$(addr 188.66.62.55 2131)" \
  "$(addr 203.0.113.10 3001)" "$(addr 2001:db8::7 3001)" "$(addr 188.66.62.55 2111)" \
  "$(addr 188.66.62.55 2131)" "$(addr ::ffff:192.0.2.80 3001)" \
  "$(addr 203.0.113.10 3001)" "$(addr 2001:db8::7 3001)" \
  "$(addr 203.0.113.10 3001)" "$(addr 188.66.62.55 2111)")"
MUX_RECORD='{"at":"2026-10-30T10:00:01.00Z","ns":"Net.Mux.Remote.State","data":{"kind":"MuxTraceState"}}'
# journald splits the long connection manager line into two entries.
DUMP_FIXTURE="$(printf '%s\n' "${CM_STALE}" "${MUX_RECORD}" "${CM_RECORD:0:300}" "${CM_RECORD:300}" "${SELECTION_RECORD}")"
LOG_LINES=(
  "$(inbound PromotedToWarmRemote 203.0.113.10 3001 6000)"
  "$(inbound PromotedToHotRemote 203.0.113.10 43122 6000)"
  "${MUX_RECORD}"
  "$(inbound PromotedToWarmRemote 188.66.62.55 2111 6000)"
  "$(inbound PromotedToHotRemote 188.66.62.55 2111 6000)"
  "$(inbound PromotedToWarmRemote 188.66.62.55 2131 6000)"
  '{"at":"2026-10-30T09:30:00.00Z","ns":"Net.InboundGovernor.Remote.InboundGovernorCounters","data":{"hotPeers":3}}'
  "$(inbound PromotedToHotRemote 198.51.100.4 6000 6000)"
  "$(inbound DemotedToColdRemote 198.51.100.4 6000 6000)"
  "$(inbound PromotedToHotRemote ::ffff:192.0.2.150 3001 6000)"
  '{"at":"2026-10-30T09:40:00.00Z","ns":"Net.InboundGovernor.Remote.PromotedToHotRemote","data":{"connectionId'
)

node_state_skipped() {
  : > "${KILL_CALLS}"
  getNodePeerState
  assert_eq "${node_peer_state_available}" "false" "$1: no node state"
  [[ ! -s "${KILL_CALLS}" ]] || fail "$1: the node was signalled"
}
ENABLE_NODE_PEER_STATE=N
node_state_skipped "node state disabled"
ENABLE_NODE_PEER_STATE=Y
NODE_IMPLEMENTATION="dingo"
node_state_skipped "another implementation"
NODE_IMPLEMENTATION="cnode"
PS_COMM="dingo"
node_state_skipped "another process on the node's PID"
PS_COMM="cardano-node"
JOURNAL_READABLE=N
node_state_skipped "unreadable journal"
JOURNAL_READABLE=Y
[[ ! -e "${PEER_STATE_FILE}" ]] || fail "a skipped analysis wrote the peer state file"

# The first analysis reads the node's whole log since it started.
: > "${KILL_CALLS}"
: > "${JOURNAL_CALLS}"
: > "${STATUS_CALLS}"
getNodePeerState
assert_eq "${node_peer_state_available}" "true" "node state available"
assert_eq "$(cat "${KILL_CALLS}")" "-USR1 99999999" "state dump signal"
grep -q -- "--show-cursor _PID=99999999 --since @" "${JOURNAL_CALLS}" ||
  fail "the node's log was not read since the node started: $(cat "${JOURNAL_CALLS}")"
grep -q -- "--no-pager _PID=99999999 --since @" "${JOURNAL_CALLS}" ||
  fail "the state dump was not read by PID since the signal: $(cat "${JOURNAL_CALLS}")"
assert_eq "$(paste -sd'|' - < "${STATUS_CALLS}")" \
  "Reading the node's log since it started...|Peer analysis started... please wait!" \
  "status while the whole log is read"
assert_eq "${nodeConnUse[203.0.113.10;3001;6000]:-}" "dup" "duplex connection, newest dump"
assert_eq "${nodeConnUse[203.0.113.10;43122;6000]:-}" "in" "connection only the peer uses"
assert_eq "${nodeConnUse[2001:db8::7;3001;6000]:-}" "out" "IPv6 connection only the node uses"
assert_eq "${nodeConnUse[198.51.100.4;6000;6000]:-}" "idle" "idle connection"
assert_eq "${nodeConnUse[188.66.62.55;2131;6000]:-}|${nodeConnUse[188.66.62.55;2131;57376]:-}" \
  "in|out" "two connections to one peer port"
assert_eq "${nodeConnUse[192.0.2.80;3001;6000]:-}" "out" "IPv4-mapped address"
assert_eq "${#nodeConnUse[@]}" "8" "negotiating connection left out"
assert_eq "${nodePeerTemp[203.0.113.10;3001]:-}|${nodePeerTemp[2001:db8::7;3001]:-}|${nodePeerTemp[192.0.2.80;3001]:-}" \
  "H|W|W" "the node's hot and warm peers"
assert_eq "${nodePeerScore[203.0.113.10;3001]:-}|${nodePeerScore[2001:db8::7;3001]:-}|${nodePeerScore[188.66.62.55;2111]:-}" \
  "8|2|0" "headers first plus blocks fetched first"
assert_eq "${nodeRemoteTemp[203.0.113.10;3001;6000]:-}|${nodeRemoteTemp[203.0.113.10;43122;6000]:-}|${nodeRemoteTemp[198.51.100.4;6000;6000]:-}|${nodeRemoteTemp[192.0.2.150;3001;6000]:-}" \
  "W|H|C|H" "the peer side's latest state"

# The state file keeps the connections the node still has, and where the log
# was read up to.
assert_eq "$(grep -v '^#' "${PEER_STATE_FILE}" | LC_ALL=C sort)" "$(printf '%s\n' \
  "cursor	c11" \
  "peer	188.66.62.55;2111;6000	H" \
  "peer	188.66.62.55;2131;6000	W" \
  "peer	198.51.100.4;6000;6000	C" \
  "peer	203.0.113.10;3001;6000	W" \
  "peer	203.0.113.10;43122;6000	H" \
  "run	99999999:Thu Oct 29 23:28:17 2026")" "peer state file"

conn_cell() {
  peerConnection "$1" "$2" "$3"
  printf '%s' "${peerConnFmt}"
}
score_cell() {
  peerScoreFor "$1" "$2"
  printf '%s' "${peerScoreFmt}"
}
assert_eq "$(conn_cell 203.0.113.10 3001 6000)" "dup H/W" "duplex cell: the node's side, then the peer's"
assert_eq "$(conn_cell 188.66.62.55 2111 6000)" "dup H/H" "duplex cell hot on both sides"
assert_eq "$(conn_cell 203.0.113.10 43122 6000)" "in H" "inbound cell"
assert_eq "$(conn_cell 188.66.62.55 2131 6000)|$(conn_cell 188.66.62.55 2131 57376)" "in W|out H" \
  "cells of two connections to one peer port"
assert_eq "$(conn_cell 2001:db8::7 3001 6000)" "out W" "outbound cell"
assert_eq "$(conn_cell 198.51.100.4 6000 6000)" "idle" "idle cell"
assert_eq "$(conn_cell ::ffff:192.0.2.80 3001 6000)" "out W" "IPv4-mapped cell"
assert_eq "$(conn_cell 192.0.2.99 6000 6000)" "" "negotiating connection cell"
assert_eq "$(score_cell 203.0.113.10 3001)|$(score_cell 203.0.113.10 43122)|$(score_cell 188.66.62.55 2111)" \
  "8||" "node scores by address and port"

# The next analysis reads on from the saved cursor.
LOG_LINES+=("$(inbound DemotedToWarmRemote 203.0.113.10 43122 6000)")
: > "${JOURNAL_CALLS}"
: > "${STATUS_CALLS}"
getNodePeerState
grep -q -- "--after-cursor c11" "${JOURNAL_CALLS}" ||
  fail "the node's log was not read on from the saved cursor: $(cat "${JOURNAL_CALLS}")"
[[ ! -s "${STATUS_CALLS}" ]] || fail "reading on from the cursor showed a status"
assert_eq "$(conn_cell 203.0.113.10 43122 6000)|$(conn_cell 203.0.113.10 3001 6000)" "in W|dup H/W" \
  "new lines update saved states"
assert_eq "$(grep '^cursor' "${PEER_STATE_FILE}")" "cursor	c12" "cursor after new lines"

# Without new lines journalctl may print no cursor; the saved one is kept.
NO_CURSOR_WHEN_EMPTY=Y
getNodePeerState
assert_eq "$(grep '^cursor' "${PEER_STATE_FILE}")|$(conn_cell 203.0.113.10 43122 6000)" "cursor	c12|in W" \
  "no new lines"
NO_CURSOR_WHEN_EMPTY=N

# A cursor that no longer works, and a restarted node, read the whole log.
sed -i.bak 's/^cursor	.*/cursor	broken/' "${PEER_STATE_FILE}"
: > "${JOURNAL_CALLS}"
getNodePeerState
assert_eq "$(grep -c -- '--show-cursor' "${JOURNAL_CALLS}")" "2" "broken cursor: one failed read, one full read"
grep -q -- "--show-cursor _PID=99999999 --since @" "${JOURNAL_CALLS}" || fail "broken cursor: no full read"
assert_eq "$(conn_cell 203.0.113.10 43122 6000)|$(grep '^cursor' "${PEER_STATE_FILE}")" "in W|cursor	c12" \
  "states after a broken cursor"
PS_LSTART="Fri Oct 30 11:00:00 2026"
: > "${JOURNAL_CALLS}"
getNodePeerState
grep -q -- "--show-cursor _PID=99999999 --since @" "${JOURNAL_CALLS}" || fail "restarted node: no full read"
grep -q "^run	99999999:Fri Oct 30 11:00:00 2026$" "${PEER_STATE_FILE}" || fail "restarted node: state file not renewed"

# A state file that cannot be written only costs a full read next time.
saved_state_file="${PEER_STATE_FILE}"
PEER_STATE_FILE="${TEST_ROOT}/missing/gLiveView.sh.peerstate"
getNodePeerState
assert_eq "${node_peer_state_available}/$(conn_cell 203.0.113.10 3001 6000)" "true/dup H/W" "unwritable state file"
PEER_STATE_FILE="${saved_state_file}"

# A dump that does not arrive, or one without the peer selection state.
saved_dump="${DUMP_FIXTURE}"
DUMP_FIXTURE="${MUX_RECORD}"
getNodePeerState
assert_eq "${node_peer_state_available}/${#nodeConnUse[@]}" "false/0" "dump that never arrived"
DUMP_FIXTURE="${CM_RECORD}"
getNodePeerState
assert_eq "${node_peer_state_available}/${#nodeConnUse[@]}/${#nodePeerTemp[@]}" "true/8/0" \
  "connection manager state alone"
assert_eq "$(conn_cell 203.0.113.10 3001 6000)" "dup -/W" "duplex cell without the node's side"
DUMP_FIXTURE="${saved_dump}"
getNodePeerState
unset -f sleep

# Filters apply to the list and to the RTT summary. 203.0.113.10:43122 is now
# warm on the peer's side.
rttResults=(
  "12;203.0.113.10;3001;i;6000"
  "5;203.0.113.10;43122;i;6000"
  "85;2001:db8::7;3001;i;6000"
  "30;198.51.100.4;6000;i;6000"
  "40;188.66.62.55;2111;i;6000"
  "41;188.66.62.55;2131;i;6000"
  "99999;192.0.2.99;6000;i;6000"
)
selected_peers() {
  printf '%s' "${rttResultsSorted}" | cut -d';' -f2,3 | paste -sd' ' -
}
assert_filter() {
  peer_filter_dir="$1"
  peer_filter_state="$2"
  computePeerStats
  assert_eq "$(selected_peers)" "$3" "filter $1/$2"
}

assert_filter all any "203.0.113.10;43122 203.0.113.10;3001 198.51.100.4;6000 188.66.62.55;2111 188.66.62.55;2131 2001:db8::7;3001 192.0.2.99;6000"
assert_eq "${peerCNT}/${peerCNT0}/${peerCNT1}/${peerCNT2}" "7/1/5/1" "all peers by RTT range"
assert_eq "${peerRTTAVG}" "35" "average RTT of reachable peers"
assert_filter out any "203.0.113.10;3001 188.66.62.55;2111 2001:db8::7;3001"
assert_filter in any "203.0.113.10;43122 203.0.113.10;3001 188.66.62.55;2111 188.66.62.55;2131"
assert_filter dup any "203.0.113.10;3001 188.66.62.55;2111"
assert_filter all hot "203.0.113.10;3001 188.66.62.55;2111"
assert_filter all warm "203.0.113.10;43122 188.66.62.55;2131 2001:db8::7;3001"
assert_filter out hot "203.0.113.10;3001 188.66.62.55;2111"
assert_filter out warm "2001:db8::7;3001"
assert_filter in hot "188.66.62.55;2111"
assert_filter in warm "203.0.113.10;43122 203.0.113.10;3001 188.66.62.55;2131"
assert_filter dup warm ""
assert_eq "${peerCNT}/${peerRTTAVG}" "0/0" "empty filter result"

# Two connections to the same peer port differ only in their local port: the
# peer's own connection to the node, and the one the node dialed.
saved_results=("${rttResults[@]}")
rttResults=("41;188.66.62.55;2131;i;6000" "42;188.66.62.55;2131;o;57376")
peer_filter_state="any"
selected_local_ports() {
  peer_filter_dir="$1"
  computePeerStats
  printf '%s' "${rttResultsSorted}" | cut -d';' -f5 | paste -sd' ' -
}
assert_eq "$(selected_local_ports out)" "57376" "outgoing of two connections to one peer port"
assert_eq "$(selected_local_ports in)" "6000" "incoming of two connections to one peer port"
assert_eq "$(selected_local_ports dup)" "" "neither of two one-way connections is duplex"
rttResults=("${saved_results[@]}")
peer_filter_dir="all"

# The IP search matches part of address:port, ignores case and combines with
# the filters.
peer_search="203.0.113"
assert_filter all any "203.0.113.10;43122 203.0.113.10;3001"
peer_search=":6000"
assert_filter all any "198.51.100.4;6000 192.0.2.99;6000"
peer_search="2001:DB8"
assert_filter all any "2001:db8::7;3001"
peer_search="203.0.113"
assert_filter out any "203.0.113.10;3001"
peer_search="no-such-peer"
assert_filter all any ""
peer_search=""

# Static peers are the localRoots access points in the topology. Names are
# resolved without the network: getent first, dig when getent finds nothing.
timeout() {
  shift
  "$@"
}
getent() {
  [[ $1 = "ahosts" ]] || return 2
  case $2 in
    relay.example.com)
      printf '198.51.100.4    STREAM relay.example.com\n198.51.100.4    DGRAM\n2001:db8::7     STREAM\n' ;;
    *) return 2 ;;
  esac
}
dig() {
  [[ "${*: -1}" = "dig-only.example.com" ]] || return 0
  case "${*: -2:1}" in
    A) printf 'alias.example.com.\n192.0.2.201\n' ;;
  esac
}
CNODE_PID=""
TOPOLOGY="${TEST_ROOT}/topology.json"
cat > "${TOPOLOGY}" <<'EOF'
{
  "localRoots": [
    {
      "accessPoints": [
        {"address": "203.0.113.10", "port": 3001, "description": "Relay 1"},
        {"address": "relay.example.com", "port": 6000},
        {"address": "192.0.2.200", "port": 3001, "pool": "ABC"},
        {"address": "203.0.113.10", "port": 3002, "name": "Relay 2"}
      ],
      "advertise": false,
      "trustable": true,
      "hotValency": 3
    },
    {
      "accessPoints": [
        {"address": "missing.example.com", "port": 3001},
        {"address": "dig-only.example.com", "port": 3001}
      ]
    }
  ],
  "publicRoots": [{"accessPoints": [{"address": "192.0.2.250", "port": 3001}]}]
}
EOF
getStaticPeers
assert_eq "$(printf '%s\n' "${staticPeerList[@]}")" "$(printf '%s\n' \
  "203.0.113.10;3001;Relay 1;203.0.113.10" \
  "relay.example.com;6000;relay.example.com;198.51.100.4,2001:db8::7" \
  "192.0.2.200;3001;ABC;192.0.2.200" \
  "203.0.113.10;3002;Relay 2;203.0.113.10" \
  "missing.example.com;3001;missing.example.com;" \
  "dig-only.example.com;3001;dig-only.example.com;192.0.2.201")" \
  "localRoots access points with their labels and addresses"
assert_eq "${staticPeer[203.0.113.10]:-}|${staticPeer[198.51.100.4]:-}|${staticPeer[2001:db8::7]:-}" \
  "Relay 1 / Relay 2|relay.example.com|relay.example.com" "static peer labels by address"

# Access points that share an address are told apart by port; a connection on
# another port shows them all.
static_label() {
  staticPeerLabelFor "$1" "$2"
  printf '%s' "${peerStaticLabel}"
}
assert_eq "$(static_label 203.0.113.10 3001)" "Relay 1" "label by address and port"
assert_eq "$(static_label 203.0.113.10 3002)" "Relay 2" "label of the second access point"
assert_eq "$(static_label 203.0.113.10 43122)" "Relay 1 / Relay 2" "label on another port"
assert_eq "$(static_label 198.51.100.4 41000)" "relay.example.com" "single access point on another port"
assert_eq "$(static_label ::ffff:198.51.100.4 6000)" "relay.example.com" "IPv4-mapped address"
assert_eq "$(static_label 192.0.2.77 3001)" "" "peer that is not static"
[[ -z ${staticPeer[192.0.2.250]+set} ]] || fail "a publicRoots entry was taken as a static peer"

# Connected static peers match by address; the others follow, x when not
# connected and u when the name did not resolve. 203.0.113.10:3002 shares its
# address, so only a connection on its own port would count.
peer_filter_static="static"
computePeerStats
# relay.example.com also resolves to the IPv6 peer.
assert_eq "$(selected_peers)" \
  "203.0.113.10;43122 203.0.113.10;3001 198.51.100.4;6000 2001:db8::7;3001 192.0.2.200;3001 203.0.113.10;3002 missing.example.com;3001 dig-only.example.com;3001" \
  "static peers"
assert_eq "$(printf '%s\n' "${rttResultsSorted}" | tail -n 4 | cut -d';' -f4 | paste -sd' ' -)" "x x u x" \
  "static peers without a connection"
assert_eq "${peerCNT}/${peerListCNT}/${peerRTTAVG}" "4/8/33" \
  "unconnected static peers are listed but not counted"
peer_filter_dir="out"
computePeerStats
assert_eq "$(selected_peers)" "203.0.113.10;3001 2001:db8::7;3001" "static peers with a direction filter"
peer_filter_dir="all"
peer_search="192.0.2.20"
computePeerStats
assert_eq "$(selected_peers)" "192.0.2.200;3001 dig-only.example.com;3001" \
  "search on unconnected static peers"
peer_search=""
TOPOLOGY="${TEST_ROOT}/missing-topology.json"
getStaticPeers
computePeerStats
assert_eq "${#staticPeerList[@]}/${peerListCNT}" "0/0" "no topology file"
peer_filter_static="all"

# Without the node's data only the search and the Static filter apply.
ENABLE_NODE_PEER_STATE=N
getNodePeerState
assert_eq "${node_peer_state_available}/${#nodeConnUse[@]}/${#nodeRemoteTemp[@]}" "false/0/0" "node data cleared"
peer_filter_dir="out"
peer_filter_state="hot"
computePeerStats
assert_eq "${peer_filter_dir}/${peer_filter_state}/${peerCNT}" "all/any/7" "filters reset without data"
peer_search="198.51"
computePeerStats
assert_eq "$(selected_peers)" "198.51.100.4;6000" "search without the node's data"
peer_search=""

# Amaru logs its connections and the peers that delivered headers and blocks
# first as text at INFO. It dials from its listen port, 3000, unless told to
# use ephemeral ports, so connections are matched by the peer's address. It
# handles no SIGUSR1, so it is never signalled.
amaru_line() {
  printf '2026-10-31T08:%02d:00.000000Z  INFO amaru::%s: %s %s' "$(( ${#LOG_LINES[@]} % 60 ))" "$1" "$2" "$3"
}
handshake() {
  amaru_line protocols manager.peer.handshake_completed "peer=\"$1\" conn_id=$2 role=\"$3\" full_duplex=true advertisable=false"
}
local_use() {
  amaru_line protocols manager.peer.local_use_applied "peer=\"$1\" conn_id=$2 local_use=\"$3\""
}
remote_use() {
  amaru_line protocols peer_selection.peer.remote_use "peer=\"$1\" conn_id=$2 remote_use=\"$3\""
}
announced() {
  amaru_line blockperf header.announced "peer=\"$1\" header_hash=\"$2\" rank=$3 slot_latency_ms=300"
}
received() {
  amaru_line blockperf block.received "peer=\"$1\" header_hash=\"$2\" rank=$3 slot_latency_ms=302 fetch_latency_ms=63"
}
NODE_IMPLEMENTATION="amaru"
ENABLE_NODE_PEER_STATE=Y
CNODE_PID=99999999
PS_COMM="cardano-node"
node_state_skipped "Amaru adapter on a cardano-node process"
PS_COMM="amaru"
PS_LSTART="Sat Oct 31 08:00:00 2026"
PEER_STATE_FILE="${TEST_ROOT}/amaru.peerstate"
# 54.194.143.142 reconnected, and a late line of its old connection follows.
# 192.0.2.99 has disconnected since.
LOG_LINES=()
LOG_LINES+=("$(handshake 3.126.235.206:30000 0 initiator)")
LOG_LINES+=("$(local_use 3.126.235.206:30000 0 diffusion)")
LOG_LINES+=("$(handshake 3.248.56.78:3001 1 initiator)")
LOG_LINES+=("$(local_use 3.248.56.78:3001 1 diffusion)")
LOG_LINES+=("$(remote_use 3.248.56.78:3001 1 maintenance)")
LOG_LINES+=("$(handshake 54.194.143.142:30000 2 initiator)")
LOG_LINES+=("$(local_use 54.194.143.142:30000 2 diffusion)")
LOG_LINES+=("$(handshake 54.194.143.142:30000 7 initiator)")
LOG_LINES+=("$(remote_use 54.194.143.142:30000 2 diffusion)")
LOG_LINES+=("$(local_use 54.194.143.142:30000 7 maintenance)")
LOG_LINES+=("$(handshake 198.51.100.4:41000 3 responder)")
LOG_LINES+=("$(remote_use 198.51.100.4:41000 3 maintenance)")
LOG_LINES+=("$(remote_use 198.51.100.4:41000 3 diffusion)")
LOG_LINES+=("$(handshake 198.51.100.5:41001 4 responder)")
LOG_LINES+=("$(handshake '[2001:db8::7]:3001' 5 initiator)")
LOG_LINES+=("$(local_use '[2001:db8::7]:3001' 5 maintenance)")
LOG_LINES+=("$(handshake '[::ffff:192.0.2.80]:43000' 6 responder)")
LOG_LINES+=("$(remote_use '[::ffff:192.0.2.80]:43000' 6 diffusion)")
LOG_LINES+=("$(handshake 203.0.113.20:3001 8 initiator)")
LOG_LINES+=("$(local_use 203.0.113.20:3001 8 diffusion)")
LOG_LINES+=("$(handshake 192.0.2.99:3001 9 initiator)")
LOG_LINES+=("$(local_use 192.0.2.99:3001 9 diffusion)")
LOG_LINES+=("$(announced 3.126.235.206:30000 aa01 1)")
LOG_LINES+=("$(announced 3.248.56.78:3001 aa01 2)")
LOG_LINES+=("$(announced 54.194.143.142:30000 aa01 1)")
LOG_LINES+=("$(received 3.126.235.206:30000 aa01 1)")
LOG_LINES+=("$(announced 3.248.56.78:3001 aa02 1)")
LOG_LINES+=("$(received 3.248.56.78:3001 aa02 1)")
LOG_LINES+=("$(announced 3.248.56.78:3001 aa03 1)")
LOG_LINES+=("$(received 3.126.235.206:30000 aa03 1)")
LOG_LINES+=("$(announced 192.0.2.99:3001 aa04 1)")
LOG_LINES+=("$(received 3.126.235.206:30000 aa04 1)")
LOG_LINES+=("$(amaru_line consensus tip.adopt 'slot=137717247 header_hash="aa04" block_height=5354836')")
# The node's TCP connections as checkPeers lists them, "remote|local". The
# loopback one is Amaru's OTLP export, which its log does not know.
peers_in="3.126.235.206:30000|192.168.0.201:3000
3.248.56.78:3001|192.168.0.201:3000
54.194.143.142:30000|192.168.0.201:3000
198.51.100.4:41000|192.168.0.201:3000
198.51.100.5:41001|192.168.0.201:3000
[2001:db8::7]:3001|[2001:db8::1]:3000
[::ffff:192.0.2.80]:43000|[::ffff:192.168.0.201]:3000"
peers_out="203.0.113.20:3001|192.168.0.201:45678
127.0.0.1:4317|127.0.0.1:58612"
: > "${KILL_CALLS}"
: > "${JOURNAL_CALLS}"
: > "${STATUS_CALLS}"
getNodePeerState
assert_eq "${node_peer_state_available}" "true" "Amaru state available"
[[ ! -s "${KILL_CALLS}" ]] || fail "Amaru was signalled: $(cat "${KILL_CALLS}")"
grep -q -- "--show-cursor _PID=99999999 --since @" "${JOURNAL_CALLS}" ||
  fail "Amaru's log was not read since it started: $(cat "${JOURNAL_CALLS}")"
assert_eq "$(paste -sd'|' - < "${STATUS_CALLS}")" \
  "Reading the node's log since it started...|Peer analysis started... please wait!" \
  "Amaru status while the whole log is read"
assert_eq "$(conn_cell 3.126.235.206 30000 3000)" "out H" "Amaru outbound hot"
assert_eq "$(conn_cell 3.248.56.78 3001 3000)" "dup H/W" "Amaru duplex: the node's side, then the peer's"
assert_eq "$(conn_cell 54.194.143.142 30000 3000)" "out W" "Amaru reconnection ignores the old connection's lines"
assert_eq "$(conn_cell 198.51.100.4 41000 3000)" "in H" "Amaru inbound hot"
assert_eq "$(conn_cell 198.51.100.5 41001 3000)" "idle" "Amaru connection neither side uses"
assert_eq "$(conn_cell 2001:db8::7 3001 3000)" "out W" "Amaru IPv6 connection"
assert_eq "$(conn_cell ::ffff:192.0.2.80 43000 3000)" "in H" "Amaru IPv4-mapped address"
assert_eq "$(conn_cell 203.0.113.20 3001 45678)" "out H" "Amaru outbound connection from an ephemeral port"
assert_eq "$(conn_cell 127.0.0.1 4317 58612)" "" "connection Amaru's log does not know"
assert_eq "${#nodeConnUse[@]}" "8" "Amaru connections"
assert_eq "$(score_cell 3.126.235.206 30000)|$(score_cell 3.248.56.78 3001)|$(score_cell 54.194.143.142 30000)|$(score_cell 203.0.113.20 3001)" \
  "4|3||" "Amaru first headers plus first blocks"
assert_eq "$(grep -v '^#' "${PEER_STATE_FILE}" | LC_ALL=C sort)" "$(printf '%s\n' \
  "conn	192.0.2.80;43000	6	none	diffusion" \
  "conn	198.51.100.4;41000	3	none	diffusion" \
  "conn	198.51.100.5;41001	4	none	none" \
  "conn	2001:db8::7;3001	5	maintenance	none" \
  "conn	203.0.113.20;3001	8	diffusion	none" \
  "conn	3.126.235.206;30000	0	diffusion	none" \
  "conn	3.248.56.78;3001	1	diffusion	maintenance" \
  "conn	54.194.143.142;30000	7	maintenance	none" \
  "cursor	c33" \
  "first	block	aa01	3.126.235.206;30000" \
  "first	block	aa02	3.248.56.78;3001" \
  "first	block	aa03	3.126.235.206;30000" \
  "first	block	aa04	3.126.235.206;30000" \
  "first	header	aa01	3.126.235.206;30000" \
  "first	header	aa02	3.248.56.78;3001" \
  "first	header	aa03	3.248.56.78;3001" \
  "first	header	aa04	192.0.2.99;3001" \
  "run	99999999:Sat Oct 31 08:00:00 2026")" "Amaru peer state file"

# The next analysis reads on from the cursor. SCORE counts the last 180
# headers and the last 180 blocks.
LOG_LINES+=("$(remote_use 3.126.235.206:30000 0 maintenance)")
LOG_LINES+=("$(local_use 3.248.56.78:3001 1 none)")
for header in $(seq 1 185); do
  LOG_LINES+=("$(announced 203.0.113.20:3001 "bb${header}" 1)")
done
: > "${JOURNAL_CALLS}"
: > "${STATUS_CALLS}"
getNodePeerState
grep -q -- "--after-cursor c33" "${JOURNAL_CALLS}" ||
  fail "Amaru's log was not read on from the saved cursor: $(cat "${JOURNAL_CALLS}")"
[[ ! -s "${STATUS_CALLS}" ]] || fail "reading Amaru's log on from the cursor showed a status"
assert_eq "$(conn_cell 3.126.235.206 30000 3000)|$(conn_cell 3.248.56.78 3001 3000)|$(conn_cell 198.51.100.4 41000 3000)" \
  "dup H/W|in W|in H" "new Amaru lines update saved states"
assert_eq "$(score_cell 203.0.113.20 3001)|$(score_cell 3.126.235.206 30000)|$(score_cell 3.248.56.78 3001)" \
  "180|3|1" "Amaru scores over the last 180 headers and blocks"
assert_eq "$(grep -c '^first	header	' "${PEER_STATE_FILE}")|$(grep '^first	header	' "${PEER_STATE_FILE}" | head -n 1 | cut -f3)" \
  "180|bb6" "Amaru keeps the last 180 headers, oldest first"

# A restarted Amaru reads its whole log again.
PS_LSTART="Sat Oct 31 09:00:00 2026"
LOG_LINES=("$(handshake 3.126.235.206:30000 0 initiator)")
: > "${JOURNAL_CALLS}"
getNodePeerState
grep -q -- "--show-cursor _PID=99999999 --since @" "${JOURNAL_CALLS}" || fail "restarted Amaru: no full read"
assert_eq "$(conn_cell 3.126.235.206 30000 3000)|$(conn_cell 3.248.56.78 3001 3000)|${#nodePeerScore[@]}" \
  "idle||0" "restarted Amaru drops the saved state"
NODE_IMPLEMENTATION="cnode"
PS_COMM="cardano-node"

# Static views wait for a key, and redraw only when the terminal is resized.
TERM_SIZE_CALLS="${TEST_ROOT}/tput.calls"
CLEARED="${TEST_ROOT}/cleared"
tput() {
  printf '%s\n' "$1" >> "${TERM_SIZE_CALLS}"
  # The size reported changes after the first lookup of each dimension.
  if [[ $(grep -c "^$1\$" "${TERM_SIZE_CALLS}") -le 1 ]]; then printf '40\n'; else printf '41\n'; fi
}
clrScreen() {
  : > "${CLEARED}"
}
key1=""
{ waitForKeyOrResize; printf '%s|%s' "$?" "${key1}" > "${TEST_ROOT}/key"; } <<< "d"
assert_eq "$(cat "${TEST_ROOT}/key")" "0|d" "key pressed on a static view"
[[ ! -e "${CLEARED}" ]] || fail "a key press cleared the screen"

: > "${TERM_SIZE_CALLS}"
if sleep 2 | waitForKeyOrResize; then
  fail "a resized terminal did not ask for a redraw"
fi
[[ -e "${CLEARED}" ]] || fail "a resized terminal was not cleared before redrawing"

printf 'gliveview-peer-analysis: ok\n'
