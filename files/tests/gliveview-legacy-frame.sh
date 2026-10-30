#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'gliveview-legacy-frame skipped: Bash 4+ required\n'
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
    fail "${description}: expected '${expected//$'\033'/<ESC>}', got '${actual//$'\033'/<ESC>}'"
}

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"
for glv_function in clrScreen glvBeginLegacyFrame glvEndLegacyFrame glvFlushLegacyFrame; do
  glv_definition="$(sed -n "/^${glv_function} *() {/,/^}/p" "${GLIVEVIEW}")"
  [[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines ${glv_function}"
  eval "${glv_definition}"
done

clear() {
  printf 'CLEAR'
}

ESC=$'\033'
SYNC_ON="${ESC}[?2026h"
SYNC_OFF="${ESC}[?2026l"
GLV_LEGACY_FRAME_FILE="${TEST_ROOT}/frame"
REPAINT_RATE=10
glv_legacy_buffered=N
GLV_LEGACY_PREV=()

# The terminal output expected for a rewritten row.
row() {
  printf '%s[%d;1H%s[2K%s' "${ESC}" "$1" "${ESC}" "$2"
}

# Draw a frame of rows, the last one without a newline like the footer. What
# reached the terminal is left in ${TEST_ROOT}/terminal.
draw() {
  local last="${*: -1}"
  {
    glvBeginLegacyFrame
    (( $# > 1 )) && printf '%s\n' "${@:1:$#-1}"
    printf '%s' "${last}"
    glvFlushLegacyFrame
  } > "${TEST_ROOT}/terminal"
}

terminal() {
  cat "${TEST_ROOT}/terminal"
}

# Rows keep their own styling and cursor moves, and may contain printf
# directives.
STATS_ROW="| Peers : 50% ${ESC}[71D${ESC}[70C|"

draw "header" "${STATS_ROW}" "footer"
assert_eq "$(terminal)" \
  "${SYNC_ON}$(row 1 header)$(row 2 "${STATS_ROW}")$(row 3 footer)${ESC}[J${SYNC_OFF}" \
  "first frame writes every row"
[[ "${glv_legacy_buffered}" = N ]] || fail "flushing left the output buffered"

draw "header" "${STATS_ROW}" "footer"
assert_eq "$(terminal)" \
  "${SYNC_ON}${ESC}[3;1H${SYNC_OFF}" \
  "an unchanged frame only moves to the footer"

draw "header" "stats 2" "footer"
assert_eq "$(terminal)" \
  "${SYNC_ON}$(row 2 "stats 2")${ESC}[3;1H${SYNC_OFF}" \
  "only the changed row is rewritten"

draw "header" "footer"
assert_eq "$(terminal)" \
  "${SYNC_ON}$(row 2 footer)${ESC}[J${SYNC_OFF}" \
  "a shorter frame clears the rows below it"

GLV_LEGACY_LAST_FULL=$(( SECONDS - REPAINT_RATE ))
draw "header" "footer"
assert_eq "$(terminal)" \
  "${SYNC_ON}$(row 1 header)$(row 2 footer)${ESC}[J${SYNC_OFF}" \
  "every REPAINT_RATE all rows are rewritten"

# A clear while buffering reaches the terminal, and the next frame is drawn
# in full.
{
  glvBeginLegacyFrame
  printf 'header\n'
  clrScreen
  printf 'footer'
  glvFlushLegacyFrame
} > "${TEST_ROOT}/terminal"
assert_eq "$(cat "${TEST_ROOT}/terminal")" \
  "CLEAR${SYNC_ON}$(row 1 header)$(row 2 footer)${ESC}[J${SYNC_OFF}" \
  "clearing the screen while buffering"

assert_eq "$(glvFlushLegacyFrame)" "" "flushing without a buffered frame"

# Without a frame file the rows go straight to the terminal.
GLV_LEGACY_FRAME_FILE=""
assert_eq "$({ glvBeginLegacyFrame; printf 'direct'; glvFlushLegacyFrame; })" "direct" \
  "drawing without a frame buffer"

printf 'gliveview-legacy-frame: ok\n'
