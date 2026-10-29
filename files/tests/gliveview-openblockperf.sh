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
glv_definition="$(sed -n '/^getOpenBlockPerfPeers() {/,/^}/p' "${GLIVEVIEW}")"
[[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines getOpenBlockPerfPeers"
eval "${glv_definition}"

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
declare -A peerConn=()
declare -A peerScore=()

getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "true" "openBlockPerf peers available"
assert_eq "$(cat "${CURL_CALLS}")" "-s -f -m 2 http://127.0.0.1:14041/peers?all=1" \
  "openBlockPerf peers request"

assert_eq "${peerConn[203.0.113.10;3001]:-}" "bi H/W" "connection used both ways"
assert_eq "${peerConn[203.0.113.10;0]:-}" "in H" "inbound connection"
assert_eq "${peerConn[2001:db8::7;3001]:-}" "out W" "IPv6 outbound connection"
assert_eq "${peerConn[198.51.100.4;6000]:-}" "in C" "cold connection the peer opened"
assert_eq "${peerConn[198.51.100.9;0]:-}" "in H" "hottest of several inbound connections"
assert_eq "${#peerConn[@]}" "5" "one connection entry per address and port"

assert_eq "${peerScore[203.0.113.10]:-}" "60" "header and body points"
assert_eq "${peerScore[2001:db8::7]:-}" "10" "IPv6 peer points"
assert_eq "${peerScore[198.51.100.4]:-}" "0" "peer without points"
assert_eq "${peerScore[192.0.2.55]:-}" "10" "relevance orphan points"
assert_eq "${#peerScore[@]}" "5" "one score per peer address"

# Without the relevance window the endpoint carries no scores.
PEERS_FIXTURE='{"peers": [], "relevance_window_seconds": null}'
getOpenBlockPerfPeers
assert_eq "${openblockperf_peers_available}" "false" "endpoint without scores"
assert_eq "${#peerConn[@]}${#peerScore[@]}" "00" "peer data cleared"

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
