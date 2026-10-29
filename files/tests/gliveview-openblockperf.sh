#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'gliveview-openblockperf skipped: Bash 4+ required\n'
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
for glv_function in getOpenBlockPerfPeers peerConnection peerMatchesFilter computePeerStats; do
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
granularity_small=10
declare -A peerConn=()
declare -A peerScore=()

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

# Without openBlockPerf data the filters fall back to every peer.
PEERS_FIXTURE='{"peers": [], "relevance_orphans": [], "relevance_window_seconds": 1800}'
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "false" "endpoint that has seen no peers"
assert_eq "${#peerConn[@]}${#peerScore[@]}" "00" "peer data cleared"
peer_filter_dir="out"
peer_filter_state="hot"
computePeerStats
assert_eq "${peer_filter_dir}/${peer_filter_state}/${peerCNT}" "all/any/5" "filters reset without data"

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

printf 'gliveview-openblockperf: ok\n'
