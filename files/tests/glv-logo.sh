#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${TEST_DIR}/../.." && pwd -P)"
export LC_ALL=C.UTF-8
unset COLORTERM NODE_NAME_DEFAULT GLV_TEXT_LINES

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library"

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"
for glv_function in glvLogoColor glvLogoInit glvLogoHeaderRows glvFrameHeaderDivider glvFrameHeader \
                    glvFrameFitsTerminal glvLegacyFrameFits; do
  glv_definition="$(sed -n "/^${glv_function}() {/,/^}/p" "${GLIVEVIEW}")"
  [[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines ${glv_function}"
  eval "${glv_definition}"
done
grep -q '^#SHOW_NODE_LOGO=true ' "${GLIVEVIEW}" || fail "SHOW_NODE_LOGO is not documented with the user variables"
grep -q '^glvLogoInit$' "${GLIVEVIEW}" || fail "gLiveView no longer prepares the logo at startup"
grep -q 'glvLegacyFrameFits || continue' "${GLIVEVIEW}" || fail "the older renderer no longer checks that the logo fits"

CLEARS=0
LEGACY_ENDED=N
clrScreen() { CLEARS=$((CLEARS + 1)); }
glvEndLegacyFrame() { LEGACY_ENDED=Y; }
node_metric_has() { return 0; }
timeLeft() { printf '00:00:01'; }

NC="" style_values_1="" style_values_2="" style_info="" style_title="" VL="|"
width=71 tlines=40 SHOW_NODE_LOGO=true LEGACY_MODE=false THEME=dark
NODE_NAME="Cardano Node" nodemode="Relay" NETWORK_NAME="Preview" running_node_version="10.6.2"
CNODE_PORT=3000 title="Koios gLiveView" uptimes=1 line=0 oldLine=0

# Strip the colour escapes so rows compare as plain text.
plain() {
  sed -E $'s/\e\\[[0-9;]*m//g' <<< "$1"
}

load_adapter() {
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/$1-helper-scripts/$1.adapter"
  NODE_IMPLEMENTATION_NAME="${NODE_IMPLEMENTATION_DISPLAY_NAME}"
}

# A dashboard of the header and $1 more rows: 3 logo rows or 1 text row, then 3 header rows.
draw_frame() {
  local rows
  glv_frame_reset
  glvFrameHeader
  for (( rows = 0; rows < $1; rows++ )); do glv_frame_add "row"; done
}

# --- every implementation has a logo that fits ----------------------------------
for implementation in cnode dingo amaru; do
  ( load_adapter "${implementation}"
    case "${implementation}" in
      cnode) name="cardano-node" ;;
      dingo) name="Dingo" ;;
      amaru) name="Amaru" running_node_version="10.11.20261029" ;;
    esac
    assert_eq "${NODE_IMPLEMENTATION_NAME}" "${name}" "${implementation} name"
    assert_eq "${#NODE_IMPLEMENTATION_LOGO[@]}" "3" "${implementation} logo rows"
    assert_eq "${#NODE_IMPLEMENTATION_LOGO_RGB[@]}" "3" "${implementation} one colour per row"
    assert_eq "${#NODE_IMPLEMENTATION_LOGO_RGB_LIGHT[@]}" "3" "${implementation} one light colour per row"
    for row in "${NODE_IMPLEMENTATION_LOGO[@]}"; do
      assert_eq "${#row}" "${#NODE_IMPLEMENTATION_LOGO[0]}" "${implementation} logo rows have the same width"
    done
    glvLogoInit

    # The default name is left out, and the implementation's name is shown.
    NODE_NAME_DEFAULT=Y
    draw_frame 0
    assert_eq "${#GLV_FRAME_NEXT[@]}" "6" "${implementation} header rows"
    assert_eq "${GLV_LOGO_ROWS}" "2" "${implementation} rows the logo adds"
    middle="$(plain "${GLV_FRAME_NEXT[1]}")"
    [[ "${middle}" == *"${NODE_IMPLEMENTATION_LOGO[1]}  > ${name} - Relay - Preview : ${running_node_version} <" ]] ||
      fail "${implementation} node info beside the middle logo row: got '${middle}'"
    [[ "${GLV_FRAME_NEXT[*]}" != *"Cardano Node"* ]] || fail "${implementation} still shows the default name"

    # A name the operator sets is shown too, even at the longest length the header keeps.
    unset NODE_NAME_DEFAULT
    NODE_NAME="sixteen-char-nam"
    draw_frame 0
    assert_eq "${GLV_LOGO_ROWS}" "2" "${implementation} logo with the longest name"
    middle="$(plain "${GLV_FRAME_NEXT[1]}")"
    [[ "${middle}" == *"  > ${NODE_NAME} - ${name} - Relay - Preview : ${running_node_version} <" ]] ||
      fail "${implementation} operator's name beside the logo: got '${middle}'"
    (( ${#middle} <= width )) || fail "${implementation} logo header is wider than the dashboard" )
done

load_adapter amaru
glvLogoInit

# --- colours follow the theme and the terminal ----------------------------------
[[ "${GLV_LOGO_ART[0]}" == $'\e[38;5;79m'* ]] || fail "without COLORTERM the logo uses the 256-colour palette"
( COLORTERM=truecolor
  glvLogoInit
  [[ "${GLV_LOGO_ART[0]}" == $'\e[38;2;48;228;161m'* ]] || fail "COLORTERM=truecolor uses 24-bit colour" )
( COLORTERM=24bit
  glvLogoInit
  [[ "${GLV_LOGO_ART[0]}" == $'\e[38;2;48;228;161m'* ]] || fail "COLORTERM=24bit uses 24-bit colour" )
( THEME=light COLORTERM=truecolor
  glvLogoInit
  [[ "${GLV_LOGO_ART[0]}" == $'\e[38;2;14;128;90m'* ]] || fail "THEME=light uses the light colours" )
( unset NODE_IMPLEMENTATION_LOGO_RGB_LIGHT
  THEME=light COLORTERM=truecolor
  glvLogoInit
  [[ "${GLV_LOGO_ART[0]}" == $'\e[38;2;48;228;161m'* ]] || fail "THEME=light without light colours keeps the colours" )
glvLogoColor "255;255;255"; assert_eq "${GLV_LOGO_SGR}" "38;5;231" "white in the 256-colour palette"
glvLogoColor "0;0;0"; assert_eq "${GLV_LOGO_SGR}" "38;5;16" "black in the 256-colour palette"
glvLogoColor "0;51;173"; assert_eq "${GLV_LOGO_SGR}" "38;5;25" "Cardano blue in the 256-colour palette"

# --- fallbacks to the text header -----------------------------------------------
text_header="> Cardano Node [Amaru] - Relay - Preview : 10.6.2 <"
for setting in "SHOW_NODE_LOGO=false" "LEGACY_MODE=true"; do
  ( eval "${setting}"
    glvLogoInit
    draw_frame 0
    assert_eq "${#GLV_FRAME_NEXT[@]}" "4" "${setting} adds no logo rows"
    [[ "${GLV_FRAME_NEXT[0]}" == *"${text_header}" ]] || fail "${setting} text header" )
done
( NODE_IMPLEMENTATION_LOGO_RGB=("1;2;3")
  glvLogoInit
  ! glvLogoHeaderRows "Name" "Amaru" "Relay" "Preview" "10.6.2" || fail "a logo without one colour per row is shown" )
( unset NODE_IMPLEMENTATION_LOGO NODE_IMPLEMENTATION_LOGO_RGB
  glvLogoInit
  ! glvLogoHeaderRows "Name" "Amaru" "Relay" "Preview" "10.6.2" || fail "an adapter without a logo shows one" )
! glvLogoHeaderRows "sixteen-char-nam" "cardano-node" "Relay" "Preview" "10.11.20261029" ||
  fail "node info too long to fit beside the logo is shown"

# --- a short terminal drops the logo, not the dashboard -------------------------
NODE_NAME_DEFAULT=Y
BODY=16                                   # 22 rows with the logo, 20 without: needs 24 lines or 22
PAGE=23                                   # 29 rows with the logo, 27 without: needs 31 lines or 29
tlines=24; draw_frame "${BODY}"
glvFrameFitsTerminal || fail "22 rows should fit 24 lines"
assert_eq "${GLV_LOGO_ROWS}" "2" "the logo fits 24 lines"

# First frame at this height, before the height without the logo is known.
unset GLV_TEXT_LINES
tlines=23; draw_frame "${BODY}"
! glvFrameFitsTerminal || fail "22 rows with the logo should not fit 23 lines"
assert_eq "${line}" "20" "dropping the logo must not ask for a taller terminal"
assert_eq "${oldLine}" "20" "dropping the logo must not redraw for a height change"
assert_eq "${CLEARS}" "0" "dropping the logo needs no clear"
draw_frame "${BODY}"
assert_eq "${GLV_LOGO_ROWS}" "0" "no logo once it is known not to fit"
glvFrameFitsTerminal || fail "20 rows should fit 23 lines"

# Too short with or without the logo: asks for what the frame needs without it.
unset GLV_TEXT_LINES
tlines=21; draw_frame "${BODY}"
assert_eq "${GLV_LOGO_ROWS}" "2" "the first frame tries the logo"
! glvFrameFitsTerminal || fail "a frame taller than the terminal should not fit"
assert_eq "${line}" "22" "the too-small screen asks for the height without the logo"
assert_eq "${CLEARS}" "1" "the too-small screen clears once"

# The dashboard appears at the height it needs, and the logo at the height it needs.
tlines=22; draw_frame "${BODY}"
assert_eq "${GLV_LOGO_ROWS}" "0" "no logo at 22 lines"
glvFrameFitsTerminal || fail "20 rows should fit 22 lines"
tlines=23; draw_frame "${BODY}"
assert_eq "${GLV_LOGO_ROWS}" "0" "no logo at 23 lines"
glvFrameFitsTerminal || fail "20 rows should fit 23 lines"
tlines=24; draw_frame "${BODY}"
assert_eq "${GLV_LOGO_ROWS}" "2" "the logo returns at 24 lines"
glvFrameFitsTerminal || fail "22 rows should fit 24 lines"

# A taller page drops the logo at this height, and it returns on the shorter page.
tlines=30; draw_frame "${BODY}"
glvFrameFitsTerminal || fail "the dashboard fits 30 lines"
draw_frame "${PAGE}"
! glvFrameFitsTerminal || fail "29 rows with the logo should not fit 30 lines"
draw_frame "${PAGE}"
assert_eq "${GLV_LOGO_ROWS}" "0" "no logo on the taller page"
glvFrameFitsTerminal || fail "27 rows should fit 30 lines"
draw_frame "${BODY}"
glvFrameFitsTerminal || fail "the shorter page fits 30 lines"
draw_frame "${BODY}"
assert_eq "${GLV_LOGO_ROWS}" "2" "the logo returns on the shorter page"

# --- the older renderer ---------------------------------------------------------
GLV_LEGACY_FRAME_FILE="buffered"
CLEARS=0 tlines=50

line=45 GLV_LOGO_ROWS=2
glvLegacyFrameFits || fail "45 rows should fit 50 lines"
assert_eq "${GLV_TEXT_LINES}" "43" "the older renderer's height without the logo"
assert_eq "${LEGACY_ENDED}" "N" "a frame that fits is kept"

line=49 GLV_LOGO_ROWS=2
! glvLegacyFrameFits || fail "49 rows with the logo should not fit 50 lines"
assert_eq "${line}" "47" "the frame's height without the logo"
assert_eq "${LEGACY_ENDED}" "Y" "the frame with the logo is discarded"
assert_eq "${CLEARS}" "0" "a buffered frame needs no clear"
! glvLogoHeaderRows "Name" "Amaru" "Relay" "Preview" "10.6.2" || fail "no logo in the next frame"

# Without a logo the frame's height is left to the main loop, as without this feature.
line=60 GLV_LOGO_ROWS=0
glvLegacyFrameFits || fail "a frame without a logo is always kept"
assert_eq "${line}" "60" "a frame without a logo keeps its height"

# Unbuffered frames were already drawn, so they have to be cleared.
GLV_LEGACY_FRAME_FILE=""
line=49 GLV_LOGO_ROWS=2
! glvLegacyFrameFits || fail "49 rows with the logo should not fit 50 lines, unbuffered"
assert_eq "${CLEARS}" "1" "an unbuffered frame is cleared"

printf 'gLiveView logo tests passed\n'
