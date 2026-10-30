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
for glv_function in getOpenBlockPerfPeers peerConnection peerMatchesFilter computePeerStats \
  waitForKeyOrResize resolvePeerAddress getStaticPeers; do
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
# relevance orphan.
relevance() {
  printf '{"headers_count":%s,"headers_1st_count":%s,"headers_2nd_count":0,"headers_3rd_count":0,"header_points":%s,"bodies_count":%s,"body_points":%s}' \
    "$1" "$1" "$2" "$3" "$4"
}
session() {
  printf '{"remote_addr":"%s","remote_port":%s,"we_dialed":%s,"outbound_temperature":"%s","ig_temperature":"%s","relevance":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
PEERS_FIXTURE="$(cat <<EOF
{
  "at": "2026-10-29T22:00:00+00:00",
  "export": "open",
  "node_generation": 1,
  "relevance_window_seconds": 1800,
  "counts": {"open": 6, "useful": 4},
  "peers": [
    $(session 203.0.113.10 3001 true Hot Warm "$(relevance 4 40 2 20)"),
    $(session 203.0.113.10 0 false Unconnected Hot "$(relevance 4 40 2 20)"),
    $(session 2001:db8::7 3001 true Warm Unknown "$(relevance 1 10 0 0)"),
    $(session 198.51.100.4 6000 false Cold Cold "$(relevance 0 0 0 0)"),
    $(session 198.51.100.9 0 false Unconnected Warm "$(relevance 0 0 0 0)"),
    $(session 198.51.100.9 0 false Unconnected Hot "$(relevance 0 0 0 0)")
  ],
  "relevance_orphans": [
    {"remote_addr": "192.0.2.55", "seen_in_blocksample_only": true, "relevance": $(relevance 0 0 1 10)}
  ]
}
EOF
)"

ENABLE_OPENBLOCKPERF=Y
OPENBLOCKPERF_METRICS_URL="http://127.0.0.1:14041/"
peer_filter_dir="all"
peer_filter_state="any"
peer_search=""
peer_filter_static="all"
granularity_small=10
declare -A peerConn=()
declare -A peerScore=()
declare -A staticPeer=()
staticPeerList=()

getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "true" "openBlockPerf peers available"
assert_eq "$(cat "${CURL_CALLS}")" "-s -f -m 2 http://127.0.0.1:14041/peers?all=1" \
  "openBlockPerf peers request"

# Connection use, then the outbound and inbound side's state.
assert_eq "${peerConn[203.0.113.10;3001]:-}" "dup;H;W" "connection used both ways"
assert_eq "${peerConn[203.0.113.10;0]:-}" "in;-;H" "inbound connection"
assert_eq "${peerConn[2001:db8::7;3001]:-}" "out;W;-" "IPv6 outbound connection"
assert_eq "${peerConn[198.51.100.4;6000]:-}" "in;C;C" "cold connection the peer opened"
assert_eq "${peerConn[198.51.100.9;0]:-}" "in;-;H" "hottest of several inbound connections"
assert_eq "${#peerConn[@]}" "5" "one connection entry per address and port"

peerConnection 203.0.113.10 3001
assert_eq "${peerConnFmt}" "dup H/W" "duplex CONN cell"
peerConnection 203.0.113.10 43122
assert_eq "${peerConnFmt}" "in H" "ephemeral port falls back to the address"
peerConnection 2001:db8::7 3001
assert_eq "${peerConnFmt}" "out W" "outbound CONN cell"
peerConnection 192.0.2.99 6000
assert_eq "${peerConnUse}|${peerConnFmt}" "|" "connection openBlockPerf has not seen"

assert_eq "${peerScore[203.0.113.10]:-}" "60" "header and body points"
assert_eq "${peerScore[2001:db8::7]:-}" "10" "IPv6 peer points"
assert_eq "${peerScore[198.51.100.4]:-}" "0" "peer without points"
assert_eq "${peerScore[192.0.2.55]:-}" "10" "relevance orphan points"
assert_eq "${#peerScore[@]}" "5" "one score per peer address"

# Filters apply to the list and to the RTT summary.
rttResults=(
  "12;203.0.113.10;3001;i"
  "85;2001:db8::7;3001;i"
  "5;203.0.113.10;43122;i"
  "30;198.51.100.4;6000;i"
  "99999;192.0.2.99;6000;i"
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
        {"address": "192.0.2.200", "port": 3001, "pool": "ABC"}
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
  "missing.example.com;3001;missing.example.com;" \
  "dig-only.example.com;3001;dig-only.example.com;192.0.2.201")" \
  "localRoots access points with their labels and addresses"
assert_eq "${staticPeer[203.0.113.10]:-}|${staticPeer[198.51.100.4]:-}|${staticPeer[2001:db8::7]:-}" \
  "Relay 1|relay.example.com|relay.example.com" "static peer labels by address"
[[ -z ${staticPeer[192.0.2.250]+set} ]] || fail "a publicRoots entry was taken as a static peer"

# Connected static peers match by address; the others follow, x when not
# connected and u when the name did not resolve.
peer_filter_static="static"
computePeerStats
# relay.example.com also resolves to the IPv6 peer.
assert_eq "$(selected_peers)" \
  "203.0.113.10;43122 203.0.113.10;3001 198.51.100.4;6000 2001:db8::7;3001 192.0.2.200;3001 missing.example.com;3001 dig-only.example.com;3001" \
  "static peers"
assert_eq "$(printf '%s\n' "${rttResultsSorted}" | tail -n 3 | cut -d';' -f4 | paste -sd' ' -)" "x u x" \
  "static peers without a connection"
assert_eq "${peerCNT}/${peerListCNT}/${peerRTTAVG}" "4/7/33" \
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
assert_eq "${#peerConn[@]}${#peerScore[@]}" "00" "peer data cleared"
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
