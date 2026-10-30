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
for glv_function in getOpenBlockPerfPeers getNodePeerState peerConnection peerConnAvailable \
  peerScoreFor peerMatchesFilter computePeerStats waitForKeyOrResize resolvePeerAddress \
  getStaticPeers staticPeerLabelFor; do
  glv_definition="$(sed -n "/^${glv_function}() {/,/^}/p" "${GLIVEVIEW}")"
  [[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines ${glv_function}"
  eval "${glv_definition}"
done

CURL_CALLS="${TEST_ROOT}/curl.calls"
CURL_STATUS=0
curl() {
  printf '%s\n' "$*" >> "${CURL_CALLS}"
  [[ "${CURL_STATUS}" -eq 0 ]] || return "${CURL_STATUS}"
  printf '%s\n' "${PEERS_FIXTURE}"
}

# Shape of openBlockPerf 0.0.42 /peers?all=1. Ephemeral remote ports are
# recorded as 0, and a peer seen only in block samples is listed as a
# relevance orphan. The node listens on 6000 and binds its outbound
# connections to it, except for 188.66.62.55:2131, where the peer's own
# connection already uses that pair and the node dialed from 57376.
relevance() {
  printf '{"headers_count":%s,"headers_1st_count":%s,"headers_2nd_count":0,"headers_3rd_count":0,"header_points":%s,"bodies_count":%s,"body_points":%s}' \
    "$1" "$1" "$2" "$3" "$4"
}
session() {
  printf '{"remote_addr":"%s","remote_port":%s,"local_port":%s,"we_dialed":%s,"outbound_temperature":"%s","ig_temperature":"%s","relevance":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
PEERS_FIXTURE="$(cat <<EOF
{
  "at": "2026-10-29T22:00:00+00:00",
  "export": "open",
  "node_generation": 1,
  "relevance_window_seconds": 1800,
  "counts": {"open": 6, "useful": 4},
  "peers": [
    $(session 203.0.113.10 3001 6000 true Hot Warm "$(relevance 4 40 2 20)"),
    $(session 203.0.113.10 0 6000 false Unconnected Hot "$(relevance 4 40 2 20)"),
    $(session 2001:db8::7 3001 6000 true Warm Unknown "$(relevance 1 10 0 0)"),
    $(session 198.51.100.4 6000 6000 false Cold Cold "$(relevance 0 0 0 0)"),
    $(session 198.51.100.9 0 6000 false Unconnected Warm "$(relevance 0 0 0 0)"),
    $(session 198.51.100.9 0 6000 false Unconnected Hot "$(relevance 0 0 0 0)"),
    $(session 188.66.62.55 2131 6000 false Unconnected Hot "$(relevance 0 0 0 0)"),
    $(session 188.66.62.55 2131 57376 true Hot Unconnected "$(relevance 0 0 0 0)"),
    $(session ::ffff:192.0.2.80 3001 null true Warm Unconnected "$(relevance 0 0 0 0)")
  ],
  "relevance_orphans": [
    {"remote_addr": "192.0.2.55", "seen_in_blocksample_only": true, "relevance": $(relevance 0 0 1 10)}
  ]
}
EOF
)"

PEERS_FIXTURE_FULL="${PEERS_FIXTURE}"
ENABLE_OPENBLOCKPERF=Y
OPENBLOCKPERF_METRICS_URL="http://127.0.0.1:14041/"
peer_filter_dir="all"
peer_filter_state="any"
peer_search=""
peer_filter_static="all"
granularity_small=10
declare -A openBlockPerfConn=()
declare -A openBlockPerfScore=()
declare -A nodeConnUse=()
declare -A nodePeerTemp=()
declare -A nodePeerScore=()
node_peer_state_available=false
declare -A staticPeer=()
declare -A staticPeerPort=()
declare -A staticPeerEntries=()
staticPeerList=()

getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "true" "openBlockPerf peers available"
assert_eq "$(cat "${CURL_CALLS}")" "-s -f -m 2 http://127.0.0.1:14041/peers?all=1" \
  "openBlockPerf peers request"

# Connection use, then the outbound and inbound side's state, keyed by
# address, remote port and local port.
assert_eq "${openBlockPerfConn[203.0.113.10;3001;6000]:-}" "dup;H;W" "connection used both ways"
assert_eq "${openBlockPerfConn[203.0.113.10;0;6000]:-}" "in;-;H" "inbound connection"
assert_eq "${openBlockPerfConn[2001:db8::7;3001;6000]:-}" "out;W;-" "IPv6 outbound connection"
assert_eq "${openBlockPerfConn[198.51.100.4;6000;6000]:-}" "in;C;C" "cold connection the peer opened"
assert_eq "${openBlockPerfConn[198.51.100.9;0;6000]:-}" "in;-;H" "hottest of several inbound connections"
assert_eq "${openBlockPerfConn[188.66.62.55;2131;6000]:-}|${openBlockPerfConn[188.66.62.55;2131;57376]:-}" \
  "in;-;H|out;H;-" "two connections to one peer port are kept apart"
assert_eq "${openBlockPerfConn[192.0.2.80;3001;-]:-}" "out;W;-" "IPv4-mapped address without a local port"
assert_eq "${#openBlockPerfConn[@]}" "8" "one connection entry per address and ports"

peerConnection 203.0.113.10 3001 6000
assert_eq "${peerConnFmt}" "dup H/W" "duplex CONN cell"
peerConnection 203.0.113.10 43122 6000
assert_eq "${peerConnFmt}" "in H" "ephemeral port falls back to 0"
peerConnection 2001:db8::7 3001 6000
assert_eq "${peerConnFmt}" "out W" "outbound CONN cell"
peerConnection 188.66.62.55 2131 6000
assert_eq "${peerConnFmt}" "in H" "the peer's connection to the node"
peerConnection 188.66.62.55 2131 57376
assert_eq "${peerConnFmt}" "out H" "the node's own connection to the same peer port"
peerConnection ::ffff:192.0.2.80 3001 6000
assert_eq "${peerConnFmt}" "out W" "connection whose local port was not recorded"
peerConnection 192.0.2.99 6000 6000
assert_eq "${peerConnUse}|${peerConnFmt}" "|" "connection openBlockPerf has not seen"

assert_eq "${openBlockPerfScore[203.0.113.10]:-}" "60" "header and body points"
assert_eq "${openBlockPerfScore[2001:db8::7]:-}" "10" "IPv6 peer points"
assert_eq "${openBlockPerfScore[198.51.100.4]:-}" "0" "peer without points"
assert_eq "${openBlockPerfScore[192.0.2.55]:-}" "10" "relevance orphan points"
assert_eq "${openBlockPerfScore[192.0.2.80]:-}" "0" "score of an IPv4-mapped address"
assert_eq "${#openBlockPerfScore[@]}" "7" "one score per peer address"

# Filters apply to the list and to the RTT summary.
rttResults=(
  "12;203.0.113.10;3001;i;6000"
  "85;2001:db8::7;3001;i;6000"
  "5;203.0.113.10;43122;i;6000"
  "30;198.51.100.4;6000;i;6000"
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

assert_filter all any "203.0.113.10;43122 203.0.113.10;3001 198.51.100.4;6000 2001:db8::7;3001 192.0.2.99;6000"
assert_eq "${peerCNT}/${peerCNT0}/${peerCNT1}/${peerCNT2}" "5/1/3/1" "all peers by RTT range"
assert_eq "${peerRTTAVG}" "33" "average RTT of reachable peers"
assert_filter out any "203.0.113.10;3001 2001:db8::7;3001"
assert_filter in any "203.0.113.10;43122 203.0.113.10;3001 198.51.100.4;6000"
assert_filter dup any "203.0.113.10;3001"
assert_filter all hot "203.0.113.10;43122 203.0.113.10;3001"
assert_filter all warm "2001:db8::7;3001"
assert_filter out hot "203.0.113.10;3001"
assert_filter in warm "203.0.113.10;3001"
assert_filter in hot "203.0.113.10;43122"
assert_filter dup warm ""
assert_eq "${peerCNT}/${peerRTTAVG}" "0/0" "empty filter result"

# Two connections to the same peer port differ only in their local port: the
# peer's own connection to the node, and the one the node dialed.
saved_results=("${rttResults[@]}")
rttResults=("40;188.66.62.55;2131;i;6000" "41;188.66.62.55;2131;o;57376")
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

# Without openBlockPerf data the filters fall back to every peer.
PEERS_FIXTURE='{"peers": [], "relevance_orphans": [], "relevance_window_seconds": 1800}'
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "false" "endpoint that has seen no peers"
assert_eq "${#openBlockPerfConn[@]}${#openBlockPerfScore[@]}" "00" "peer data cleared"
peer_filter_dir="out"
peer_filter_state="hot"
computePeerStats
assert_eq "${peer_filter_dir}/${peer_filter_state}/${peerCNT}" "all/any/5" "filters reset without data"
peer_search="198.51"
computePeerStats
assert_eq "$(selected_peers)" "198.51.100.4;6000" "search without openBlockPerf data"
peer_search=""

# Without the relevance window the endpoint carries no scores.
PEERS_FIXTURE='{"peers": [{"remote_addr": "203.0.113.10"}], "relevance_window_seconds": null}'
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "false" "endpoint without scores"

PEERS_FIXTURE='not json'
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "false" "invalid endpoint response"

CURL_STATUS=7
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "false" "unreachable endpoint"
CURL_STATUS=0

: > "${CURL_CALLS}"
ENABLE_OPENBLOCKPERF=N
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "false" "disabled openBlockPerf peers"
[[ ! -s "${CURL_CALLS}" ]] || fail "disabled openBlockPerf peers still queried the endpoint"

# The node's own state: SIGUSR1 makes cardano-node log its connection manager
# and peer selection state, read back from its journal. The process cannot
# exist, so no unit is found and its entries are matched by PID.
NODE_IMPLEMENTATION="cnode"
ENABLE_NODE_STATE_DUMP=Y
CNODE_PID=99999999
PS_COMM="cardano-node"
KILL_CALLS="${TEST_ROOT}/kill.calls"
JOURNAL_CALLS="${TEST_ROOT}/journalctl.calls"
JOURNAL_READABLE=Y
JOURNAL_FIXTURE=""
ps() {
  printf '%s\n' "${PS_COMM}"
}
kill() {
  printf '%s\n' "$*" >> "${KILL_CALLS}"
}
sleep() {
  :
}
journalctl() {
  printf '%s\n' "$*" >> "${JOURNAL_CALLS}"
  if [[ " $* " = *" -n 1 "* ]]; then
    [[ ${JOURNAL_READABLE} = Y ]] && printf '{"at":"2026-10-30T10:00:00.00Z","ns":"Resources","data":{}}\n'
    return 0
  fi
  [[ -z ${JOURNAL_FIXTURE} ]] || printf '%s\n' "${JOURNAL_FIXTURE}"
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
CM_STALE="$(cm_state "$(conn 203.0.113.10 3001 6000 InboundIdleSt Duplex)")"
CM_RECORD="$(cm_state \
  "$(conn 203.0.113.10 3001 6000 DuplexSt)" \
  "$(conn 203.0.113.10 43122 6000 InboundSt Duplex)" \
  "$(conn 2001:db8::7 3001 6000 OutboundDupSt)" \
  "$(conn 198.51.100.4 6000 6000 InboundIdleSt Duplex)" \
  "$(conn 188.66.62.55 2131 6000 DuplexSt)" \
  "$(conn 188.66.62.55 6000 6000 InboundSt Unidirectional)" \
  "$(conn ::ffff:192.0.2.80 3001 6000 OutboundUniSt)" \
  "$(conn 192.0.2.99 6000 6000 UnnegotiatedSt)")"
SELECTION_RECORD="$(printf '{"at":"2026-10-30T10:00:01.01Z","ns":"Net.PeerSelection.Selection.DebugState","data":{"activePeers":[%s,%s],"establishedPeers":[%s,%s,%s,%s],"upstreamyness":[[%s,6],[%s,2]],"fetchynessBlocks":[[%s,2],[%s,0]],"targets":{"active":20}},"sev":"Info"}' \
  "$(addr 203.0.113.10 3001)" "$(addr 188.66.62.55 2131)" \
  "$(addr 203.0.113.10 3001)" "$(addr 2001:db8::7 3001)" "$(addr 188.66.62.55 2131)" "$(addr ::ffff:192.0.2.80 3001)" \
  "$(addr 203.0.113.10 3001)" "$(addr 2001:db8::7 3001)" \
  "$(addr 203.0.113.10 3001)" "$(addr 188.66.62.55 2131)")"
MUX_RECORD='{"at":"2026-10-30T10:00:01.00Z","ns":"Net.Mux.Remote.State","data":{"kind":"MuxTraceState"}}'
# journald splits the long connection manager line into two entries.
JOURNAL_FIXTURE="$(printf '%s\n' "${CM_STALE}" "${MUX_RECORD}" "${CM_RECORD:0:300}" "${CM_RECORD:300}" "${SELECTION_RECORD}")"

node_state_skipped() {
  : > "${KILL_CALLS}"
  getNodePeerState
  assert_eq "${node_peer_state_available}" "false" "$1: no node state"
  [[ ! -s "${KILL_CALLS}" ]] || fail "$1: the node was signalled"
}
ENABLE_NODE_STATE_DUMP=N
node_state_skipped "node state disabled"
ENABLE_NODE_STATE_DUMP=Y
NODE_IMPLEMENTATION="dingo"
node_state_skipped "another implementation"
NODE_IMPLEMENTATION="cnode"
PS_COMM="dingo"
node_state_skipped "another process on the node's PID"
PS_COMM="cardano-node"
JOURNAL_READABLE=N
node_state_skipped "unreadable journal"
JOURNAL_READABLE=Y

: > "${KILL_CALLS}"
: > "${JOURNAL_CALLS}"
getNodePeerState
assert_eq "${node_peer_state_available}" "true" "node state available"
assert_eq "$(cat "${KILL_CALLS}")" "-USR1 99999999" "state dump signal"
grep -q -- "_PID=99999999 --since @" "${JOURNAL_CALLS}" ||
  fail "the journal was not read by PID since the signal: $(cat "${JOURNAL_CALLS}")"
assert_eq "${nodeConnUse[203.0.113.10;3001;6000]:-}" "dup" "duplex connection, newest dump"
assert_eq "${nodeConnUse[203.0.113.10;43122;6000]:-}" "in" "connection only the peer uses"
assert_eq "${nodeConnUse[2001:db8::7;3001;6000]:-}" "out" "IPv6 connection only the node uses"
assert_eq "${nodeConnUse[198.51.100.4;6000;6000]:-}" "idle" "idle connection"
assert_eq "${nodeConnUse[188.66.62.55;2131;6000]:-}|${nodeConnUse[188.66.62.55;6000;6000]:-}" \
  "dup|in" "connections from two nodes on one address"
assert_eq "${nodeConnUse[192.0.2.80;3001;6000]:-}" "out" "IPv4-mapped address"
assert_eq "${#nodeConnUse[@]}" "7" "negotiating connection left out"
assert_eq "${nodePeerTemp[203.0.113.10;3001]:-}|${nodePeerTemp[2001:db8::7;3001]:-}|${nodePeerTemp[192.0.2.80;3001]:-}" \
  "H|W|W" "the node's hot and warm peers"
assert_eq "${nodePeerScore[203.0.113.10;3001]:-}|${nodePeerScore[2001:db8::7;3001]:-}|${nodePeerScore[188.66.62.55;2131]:-}" \
  "8|2|0" "headers first plus blocks fetched first"

conn_cell() {
  peerConnection "$1" "$2" "$3"
  printf '%s' "${peerConnFmt}"
}
score_cell() {
  peerScoreFor "$1" "$2"
  printf '%s' "${peerScoreFmt}"
}
# Without openBlockPerf the node's side is known, the peer's is not.
assert_eq "$(conn_cell 203.0.113.10 3001 6000)" "dup H" "duplex cell from the node"
assert_eq "$(conn_cell 203.0.113.10 43122 6000)" "in" "inbound cell from the node"
assert_eq "$(conn_cell 2001:db8::7 3001 6000)" "out W" "outbound cell from the node"
assert_eq "$(conn_cell 198.51.100.4 6000 6000)" "idle" "idle cell"
assert_eq "$(conn_cell 188.66.62.55 2131 6000)|$(conn_cell 188.66.62.55 6000 6000)" "dup H|in" \
  "cells of two nodes on one address"
assert_eq "$(conn_cell ::ffff:192.0.2.80 3001 6000)" "out W" "IPv4-mapped cell"
assert_eq "$(conn_cell 192.0.2.99 6000 6000)" "" "negotiating connection cell"
assert_eq "$(score_cell 203.0.113.10 3001)|$(score_cell 203.0.113.10 43122)|$(score_cell 188.66.62.55 2131)" \
  "8||" "node scores by address and port"
stale_key="203.0.113.10;3001;6000"
openBlockPerfConn[${stale_key}]="dup;H;W"
assert_eq "$(conn_cell 203.0.113.10 3001 6000)" "dup H" "peer side only while openBlockPerf has data"
openBlockPerfConn=()

rttResults=(
  "12;203.0.113.10;3001;i;6000"
  "5;203.0.113.10;43122;i;6000"
  "85;2001:db8::7;3001;i;6000"
  "30;198.51.100.4;6000;i;6000"
  "40;188.66.62.55;2131;i;6000"
  "41;188.66.62.55;6000;i;6000"
)
assert_filter out any "203.0.113.10;3001 188.66.62.55;2131 2001:db8::7;3001"
assert_filter in any "203.0.113.10;43122 203.0.113.10;3001 188.66.62.55;2131 188.66.62.55;6000"
assert_filter dup any "203.0.113.10;3001 188.66.62.55;2131"
assert_filter all warm "2001:db8::7;3001"
assert_filter in hot ""
assert_filter all any "203.0.113.10;43122 203.0.113.10;3001 198.51.100.4;6000 188.66.62.55;2131 188.66.62.55;6000 2001:db8::7;3001"

# openBlockPerf adds the peer's side and replaces the node's scores.
ENABLE_OPENBLOCKPERF=Y
PEERS_FIXTURE="${PEERS_FIXTURE_FULL}"
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "true" "openBlockPerf next to the node state"
assert_eq "$(conn_cell 203.0.113.10 3001 6000)" "dup H/W" "duplex cell with the peer's side"
assert_eq "$(conn_cell 203.0.113.10 43122 6000)" "in H" "inbound cell with the peer's side"
assert_eq "$(conn_cell 188.66.62.55 2131 6000)" "dup H/H" "duplex cell openBlockPerf saw one way"
assert_eq "$(conn_cell 198.51.100.4 6000 6000)" "idle" "the node's idle state wins"
assert_eq "$(conn_cell ::ffff:192.0.2.80 3001 6000)" "out W" "outbound cell keeps the node's state"
assert_eq "$(score_cell 203.0.113.10 3001)|$(score_cell 203.0.113.10 43122)|$(score_cell 2001:db8::7 3001)" \
  "60|60|10" "openBlockPerf scores by address"
assert_filter in hot "203.0.113.10;43122 188.66.62.55;2131"
assert_filter in warm "203.0.113.10;3001"
peer_filter_dir="all"
peer_filter_state="any"
PEERS_FIXTURE='not json'
getOpenBlockPerfPeers

# A dump that does not arrive, or one without the peer selection state.
JOURNAL_FIXTURE="${MUX_RECORD}"
getNodePeerState
assert_eq "${node_peer_state_available}/${#nodeConnUse[@]}" "false/0" "dump that never arrived"
JOURNAL_FIXTURE="${CM_RECORD}"
getNodePeerState
assert_eq "${node_peer_state_available}/${#nodeConnUse[@]}/${#nodePeerTemp[@]}" "true/7/0" \
  "connection manager state alone"
assert_eq "$(conn_cell 203.0.113.10 3001 6000)" "dup" "duplex cell without the peer selection state"
JOURNAL_FIXTURE=""
getNodePeerState
unset -f sleep

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
