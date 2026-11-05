#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${TEST_DIR}/../.." && pwd -P)"
export LC_ALL=C.UTF-8

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library"
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/amaru-helper-scripts/amaru.adapter"

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"
for glv_function in glvFrameLogoHeader glvFrameFitsTerminal; do
  glv_definition="$(sed -n "/^${glv_function}() {/,/^}/p" "${GLIVEVIEW}")"
  [[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines ${glv_function}"
  eval "${glv_definition}"
done
grep -q '^#SHOW_NODE_LOGO=true ' "${GLIVEVIEW}" || fail "SHOW_NODE_LOGO is not documented with the user variables"

clrScreen() { :; }
NC="" style_values_1="" style_values_2="" style_info=""
width=71 tlines=40 SHOW_NODE_LOGO=true LEGACY_MODE=false

# Strip the colour escapes so rows compare as plain text.
plain() {
  sed -E $'s/\e\\[[0-9;]*m//g' <<< "$1"
}

# --- the Amaru adapter's logo replaces the name -----------------------------
assert_eq "${#NODE_IMPLEMENTATION_LOGO[@]}" "${#NODE_IMPLEMENTATION_LOGO_RGB[@]}" "one colour per logo row"
for row in "${NODE_IMPLEMENTATION_LOGO[@]}"; do
  assert_eq "${#row}" "${#NODE_IMPLEMENTATION_LOGO[0]}" "logo rows have the same width"
done

glv_frame_reset
glvFrameLogoHeader "Cardano Node" "Relay" "Preview" "10.11.0" || fail "logo header not shown"
assert_eq "${#GLV_FRAME_NEXT[@]}" "3" "logo header rows"
assert_eq "${GLV_LOGO_ROWS}" "2" "rows the logo adds"
middle="$(plain "${GLV_FRAME_NEXT[1]}")"
[[ "${middle}" == *"${NODE_IMPLEMENTATION_LOGO[1]}  > Cardano Node - Relay - Preview : 10.11.0 <" ]] ||
  fail "node info beside the middle logo row: got '${middle}'"
[[ "${GLV_FRAME_NEXT[*]}" != *"[Amaru]"* ]] || fail "the logo header still shows the name"
[[ "${GLV_FRAME_NEXT[0]}" == *$'\e[38;2;48;228;161m'* ]] || fail "logo rows are not coloured"
(( ${#middle} <= width )) || fail "logo header is wider than the dashboard"

# --- fallbacks to the text header ---------------------------------------------
for setting in "SHOW_NODE_LOGO=false" "LEGACY_MODE=true" "width=40"; do
  ( eval "${setting}"
    glv_frame_reset
    ! glvFrameLogoHeader "Cardano Node" "Relay" "Preview" "10.11.0" || fail "${setting} should show the name"
    assert_eq "${#GLV_FRAME_NEXT[@]}" "0" "${setting} adds no logo rows" )
done
( NODE_IMPLEMENTATION_LOGO_RGB=("1;2;3")
  glv_frame_reset
  ! glvFrameLogoHeader "Cardano Node" "Relay" "Preview" "10.11.0" || fail "a logo without one colour per row is shown" )
( unset NODE_IMPLEMENTATION_LOGO NODE_IMPLEMENTATION_LOGO_RGB
  glv_frame_reset
  ! glvFrameLogoHeader "Cardano Node" "Relay" "Preview" "10.11.0" || fail "an adapter without a logo shows one" )

# --- a short terminal drops the logo, not the dashboard -----------------------
frame_with_logo() {
  glv_frame_reset
  glvFrameLogoHeader "Cardano Node" "Relay" "Preview" "10.11.0" || true
  for _ in $(seq 1 "$1"); do glv_frame_add "row"; done
}
tlines=24
frame_with_logo 20                  # 23 rows with the logo, 21 without
! glvFrameFitsTerminal || fail "a 23-row frame should not fit 24 lines"
assert_eq "${GLV_LOGO_SKIP_LINES:-}" "24" "terminal height without room for the logo"
(( line <= tlines )) || fail "dropping the logo must not ask for a taller terminal (line ${line})"
frame_with_logo 20
assert_eq "${GLV_LOGO_ROWS}" "0" "no logo while the terminal is this short"
glvFrameFitsTerminal || fail "the frame without the logo should fit"
tlines=30
frame_with_logo 20
assert_eq "${GLV_LOGO_ROWS}" "2" "logo returns once the terminal is taller"
glvFrameFitsTerminal || fail "the frame with the logo should fit 30 lines"

unset GLV_LOGO_SKIP_LINES
tlines=12
frame_with_logo 20                  # too tall even without the logo
! glvFrameFitsTerminal || fail "a frame taller than the terminal should not fit"
[[ -z "${GLV_LOGO_SKIP_LINES:-}" ]] || fail "the logo is not what makes this frame too tall"

printf 'gLiveView logo tests passed\n'
