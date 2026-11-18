#!/usr/bin/env bash
# Canonical implementation-neutral gLiveView entrypoint.
# shellcheck disable=SC1090,SC1091,SC2015,SC2034,SC2086,SC2154,SC2162,SC2178
#
# Koios gLiveView: a live dashboard for cardano-node, Amaru and Dingo. Bash
# draws every frame; gum is only used for the command list and for the text
# prompts, and the dashboard runs without it.

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#NODE_NAME=""                             # Name shown for this node (default: the deployment folder's name)
#REFRESH_RATE=2                           # Seconds between metric collections; clocks and countdowns move every second
#GLV_THEME=""                             # default or hydra-after-dark (default: the theme chosen in CNTools)
#GLV_COLORS=""                            # truecolor, 256 or none (default: truecolor when COLORTERM announces it, else 256)
#SHOW_NODE_LOGO=Y                         # Show the node's logo under the title in the full side rail (N to hide)
#ENABLE_IP_GEOLOCATION=Y                  # Peer analysis asks ip-api.com for the city and country of peer addresses (N to disable)
#POOL_ID=""                               # Pool ID, bech32 or hex, for the pool data on a block producer (default: from the pool folder)
#POOL_HISTORY_EPOCHS=5                    # Epochs shown at a time in the epoch history on the Production page (1-20)
#ENABLE_NODE_PEER_STATE=Y                 # Peer analysis reads the node's own view of its peers from its journal: cardano-node's log and state dump (SIGUSR1), or Amaru's log (N to disable)

######################################
# Do NOT modify code below           #
######################################

GLV_VERSION=v2.0.0

PARENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

usage() {
  cat <<-EOF
		Usage: $(basename "$0") [-u] [-b <branch name>] [-t <theme>] [-c <colours>] [-d] [-v]
		Koios gLiveView - A local Cardano node monitoring tool

		-u    Skip script update check overriding UPDATE_CHECK value in env
		-b    Persist an alternate Guild Operators branch for this deployment
		-t    Colour theme: default or hydra-after-dark
		-c    Colour depth: truecolor, 256 or none (default: detected)
		-d    Show frame and collection times in the footer
		-v    Print Koios gLiveView version

		Guide: https://cardano-community.github.io/guild-operators/Scripts/gliveview
		EOF
  exit 1
}

SKIP_UPDATE=N
BRANCH_EXPLICIT=N
PRINT_VERSION=N
REQUESTED_BRANCH=""
GLV_DEBUG=N
GLIVE_ARG_COPY=("$@")

# -l selected ASCII borders in gLiveView 1. It is still accepted, so that an
# old alias keeps working, and has no effect.
while getopts :lub:t:c:dv opt; do
  case ${opt} in
    l ) : ;;
    u ) SKIP_UPDATE=Y ;;
    b ) REQUESTED_BRANCH="${OPTARG}"; GUILD_BRANCH_OVERRIDE="${OPTARG}"; BRANCH_EXPLICIT=Y ;;
    t ) GLV_THEME="${OPTARG}" ;;
    c ) GLV_COLORS="${OPTARG}" ;;
    d ) GLV_DEBUG=Y ;;
    v ) PRINT_VERSION=Y ;;
    \? ) usage ;;
  esac
done
shift $((OPTIND -1))

glv_die() { printf 'gLiveView: %b\n' "$1" >&2; exit "${2:-1}"; }

cnodeToolTargetVersion() {
  local tool_key="$1"
  local manifest="${NODE_HOME:-${CNODE_HOME:-}}/files/cnode-release.json"
  local mode channel repository resolver_data api_url release_json version

  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required to validate cnode tool release metadata.\n' >&2
    return 1
  }
  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] || {
    printf 'Cnode release metadata is missing or unsafe: %s\n' "${manifest}" >&2
    return 1
  }
  version="$(
    jq -er --arg tool "${tool_key}" '
      select(
        .schemaVersion == 1 and
        .implementation == "cnode" and
        (.tools[$tool] | type == "object") and
        (.tools[$tool].version | type == "string" and length > 0)
      ) |
      .tools[$tool].version
    ' "${manifest}"
  )" || return 1
  [[ "${version}" == "latest" ]] && mode="latest" || mode="pinned"

  if [[ "${mode}" == "pinned" ]]; then
    printf '%s\t%s\n' "${mode}" "${version}"
    return 0
  fi

  resolver_data="$(
    jq -er --arg tool "${tool_key}" '
      select(
        ((.tools[$tool].channel // "stable") == "stable" or
          (.tools[$tool].channel // "stable") == "any") and
        (.tools[$tool].github |
          type == "string" and
          test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
      ) |
      [
        (.tools[$tool].channel // "stable"),
        .tools[$tool].github
      ] | @tsv
    ' "${manifest}"
  )" || return 1
  IFS=$'\t' read -r channel repository <<< "${resolver_data}"

  if [[ "${channel}" == "stable" ]]; then
    api_url="https://api.github.com/repos/${repository}/releases/latest"
    release_json="$(curl -sSfL -m "${CURL_TIMEOUT:-10}" "${api_url}")" ||
      return 1
    version="$(
      jq -er '
        select(.draft == false and .prerelease == false) |
        .tag_name |
        select(type == "string" and length > 0)
      ' <<< "${release_json}"
    )" || return 1
  else
    api_url="https://api.github.com/repos/${repository}/releases?per_page=20"
    release_json="$(curl -sSfL -m "${CURL_TIMEOUT:-10}" "${api_url}")" ||
      return 1
    version="$(
      jq -er '
        [.[] | select(.draft == false)][0].tag_name |
        select(type == "string" and length > 0)
      ' <<< "${release_json}"
    )" || return 1
  fi

  printf '%s\t%s\n' "${mode}" "${version#v}"
}

#######################################################
# Version Check                                       #
#######################################################

[[ -f "${PARENT}/env" ]] ||
  glv_die "common env file missing: ${PARENT}/env\nThis is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub"

. "${PARENT}"/env definitions || glv_die "failed to load common env definitions"

if [[ "${BRANCH_EXPLICIT}" == "Y" ]]; then
  deployment_set_branch "${REQUESTED_BRANCH}" ||
    glv_die "Invalid branch '${REQUESTED_BRANCH}' or unable to update ${NODE_HOME}/.deployment.json"
  unset GUILD_BRANCH_OVERRIDE
fi

if [[ "${PRINT_VERSION}" == "Y" ]]; then
  printf '\nKoios gLiveView %s (branch: %s)\n\n' "${GLV_VERSION}" "${BRANCH}"
  exit 0
fi

# The update check asks its question on the controlling terminal. Where there
# is none, as under "su -c", the question could never be answered, so the
# check is skipped. The probe runs in a subshell: a redirection that fails on
# ":" itself can end the shell it runs in.
if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]] && ! (: < /dev/tty) 2>/dev/null; then
  printf 'Skipping the script update check: no controlling terminal to ask on.\n'
  SKIP_UPDATE=Y
fi

if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then
  if [[ "${NODE_IMPLEMENTATION}" == "cnode" ]] &&
     command -v cncli >/dev/null &&
     command -v systemctl >/dev/null &&
     systemctl is-active --quiet "${CNODE_VNAME}-cncli-sync.service" 2>/dev/null; then
    if ! cncli_release_policy="$(cnodeToolTargetVersion "cncli")"; then
      glv_die "unable to resolve CNCLI release policy from ${NODE_HOME}/files/cnode-release.json"
    fi
    IFS=$'\t' read -r cncli_release_mode vrem <<< "${cncli_release_policy}"
    vcur=$(cncli -V | awk '{print $2}')
    [[ "${vcur#v}" != "${vrem#v}" ]] &&
      printf "${FG_MAGENTA}CNCLI current version (${vcur}) differs from the configured ${cncli_release_mode} release (${vrem}); consider upgrading.${NC}" &&
      waitToProceed
  fi

  echo "Checking for script updates..."
  if ! declare -F checkCommonRuntimeUpdates >/dev/null; then
    glv_die "Common runtime bundle updater is unavailable; re-run guild-deploy.sh"
  fi

  BUNDLE_UPDATED=N
  if checkCommonRuntimeUpdates N; then
    common_update_status=0
  else
    common_update_status=$?
  fi
  case "${common_update_status}" in
    0) ;;
    1) BUNDLE_UPDATED=Y ;;
    2) glv_die "Failed to update the common runtime bundle" ;;
  esac

  checkUpdate "${PARENT}/gLiveView.sh" "${BUNDLE_UPDATED}" N N "common-helper-scripts" N
  case $? in
    1) BUNDLE_UPDATED=Y ;;
    2) glv_die "Failed to update gLiveView.sh" ;;
  esac

  if [[ "${BUNDLE_UPDATED}" == "Y" ]]; then
    exec "$0" -u "${GLIVE_ARG_COPY[@]}"
  fi
fi


##############################################################################
# Drawing: colours, the line builder, boxes and the row-diff writer
##############################################################################
# Drawing primitives: colours, a line builder that tracks visible width, boxes
# with titles in the border, and a row-diff writer. Nothing in this section
# knows about a node.
#
# Bash draws every frame. A gum process costs about 55 ms to start, so gum is
# kept for dialogs that stop the page anyway.

# ── locale ───────────────────────────────────────────────────────────────────
# Widths are counted in characters, so the shell must read UTF-8.
ui_utf8() { local probe='─'; (( ${#probe} == 1 )); }

ui_locale_init() {
  local candidate
  ui_utf8 && return 0
  for candidate in C.UTF-8 C.utf8 en_US.UTF-8; do
    { LC_ALL="${candidate}"; } 2>/dev/null
    if ui_utf8; then export LC_ALL; return 0; fi
  done
  return 1
}

# ── colours ──────────────────────────────────────────────────────────────────
UI_RESET=$'\e[0m'
UI_BOLD=$'\e[1m'
UI_COLOUR_DEPTH=256

# ui_colour_256 <variable> <r> <g> <b>: nearest xterm-256 colour index.
# The locals carry a prefix because the result is written through a nameref:
# a caller's variable with the same name as a local here would be shadowed.
ui_colour_256() {
  local -n _c256_out="$1"
  local _c256_r="$2" _c256_g="$3" _c256_b="$4" _c256_channel _c256_level _c256_value
  local _c256_cube=16 _c256_cube_distance=0 _c256_grey_distance _c256_step=36
  for _c256_channel in "${_c256_r}" "${_c256_g}" "${_c256_b}"; do
    if (( _c256_channel < 48 )); then _c256_level=0
    elif (( _c256_channel < 115 )); then _c256_level=1
    else _c256_level=$(((_c256_channel - 35) / 40)); fi
    _c256_value=$(( _c256_level == 0 ? 0 : 55 + 40 * _c256_level ))
    _c256_cube=$((_c256_cube + _c256_level * _c256_step))
    _c256_cube_distance=$((_c256_cube_distance + (_c256_channel - _c256_value) * (_c256_channel - _c256_value)))
    _c256_step=$((_c256_step / 6))
  done
  _c256_level=$(((_c256_r + _c256_g + _c256_b) / 3))
  _c256_level=$(( _c256_level < 8 ? 0 : (_c256_level - 8) / 10 ))
  (( _c256_level <= 23 )) || _c256_level=23
  _c256_value=$((8 + 10 * _c256_level))
  _c256_grey_distance=$(( (_c256_r - _c256_value) * (_c256_r - _c256_value) +
    (_c256_g - _c256_value) * (_c256_g - _c256_value) +
    (_c256_b - _c256_value) * (_c256_b - _c256_value) ))
  if (( _c256_grey_distance < _c256_cube_distance )); then
    _c256_out=$((232 + _c256_level))
  else
    _c256_out="${_c256_cube}"
  fi
}

# ui_colour <NAME> <hex>: sets C_<NAME> (foreground) and CB_<NAME> (background)
# for the depth the terminal supports, and HEX_<NAME> for gum.
ui_colour() {
  local name="$1" hex="${2#\#}" r g b palette
  r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
  printf -v "HEX_${name}" '#%s' "${hex}"
  case "${UI_COLOUR_DEPTH}" in
    rgb)
      printf -v "C_${name}" '\e[38;2;%d;%d;%dm' "${r}" "${g}" "${b}"
      printf -v "CB_${name}" '\e[48;2;%d;%d;%dm' "${r}" "${g}" "${b}"
      ;;
    none)
      printf -v "C_${name}" '%s' ''
      printf -v "CB_${name}" '%s' ''
      ;;
    *)
      ui_colour_256 palette "${r}" "${g}" "${b}"
      printf -v "C_${name}" '\e[38;5;%dm' "${palette}"
      printf -v "CB_${name}" '\e[48;5;%dm' "${palette}"
      ;;
  esac
}

# The palettes are the CNTools themes, so both tools look like one product.
ui_theme() {
  # GLV_COLORS overrides the detection: ssh and su do not pass COLORTERM on,
  # so a terminal that can show 24-bit colour is often not announced as one.
  case "${GLV_COLORS:-auto}" in
    truecolor|24bit|rgb) UI_COLOUR_DEPTH=rgb ;;
    256) UI_COLOUR_DEPTH=256 ;;
    none) UI_COLOUR_DEPTH=none ;;
    *)
      if [[ -n "${NO_COLOR:-}" ]]; then UI_COLOUR_DEPTH=none
      elif [[ "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit ]]; then UI_COLOUR_DEPTH=rgb
      else UI_COLOUR_DEPTH=256; fi
      ;;
  esac
  case "${1:-default}" in
    hydra-after-dark)
      ui_colour TEXT E6F0FA; ui_colour MUTED 9AABC1; ui_colour TRACK 1D3048
      ui_colour BORDER 27415F; ui_colour ACCENT 59D8F5; ui_colour OK 61D6A3
      ui_colour WARN F3C875; ui_colour DANGER FF7C91; ui_colour ID 83B6FF
      ui_colour NUM E9CF8A; ui_colour SURFACE 111E31; ui_colour SELECT 1D3048
      ;;
    *)
      ui_colour TEXT DFDFD6; ui_colour MUTED 98989F; ui_colour TRACK 34343A
      ui_colour BORDER 45454D; ui_colour ACCENT 4FBC85; ui_colour OK 3DD68C
      ui_colour WARN F9B44E; ui_colour DANGER F66F81; ui_colour ID 78BFD0
      ui_colour NUM D8BC7A; ui_colour SURFACE 202127; ui_colour SELECT 2E3038
      ;;
  esac
  if [[ "${UI_COLOUR_DEPTH}" == none ]]; then UI_RESET=''; UI_BOLD=''; fi
  UI_BASE_MAIN="${UI_RESET}${C_TEXT}"
  UI_BASE_RAIL="${UI_RESET}${CB_SURFACE}${C_TEXT}"
  UI_BASE_SELECT="${UI_RESET}${CB_SELECT}${C_TEXT}"
  UI_BASE="${UI_BASE_MAIN}"
  UI_KEY="${UI_BOLD}${C_ACCENT}"
}

printf -v UI_SPACES '%500s' ''
UI_DASHES="${UI_SPACES// /─}"
UI_BLOCKS="${UI_SPACES// /█}"
UI_HEAVY="${UI_SPACES// /━}"
UI_BARS="${UI_SPACES// /▇}"
UI_SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# ── line builder ─────────────────────────────────────────────────────────────
# A line is built left to right in UI_L while UI_LW tracks its visible width,
# so no code ever has to measure a string that contains colour codes.
UI_L=''
UI_LW=0

ui_put() { UI_L+="$1$2${UI_BASE}"; UI_LW=$((UI_LW + ${#2})); }

ui_gap() { (( $1 > 0 )) || return 0; UI_L+="${UI_SPACES:0:$1}"; UI_LW=$((UI_LW + $1)); }

# ui_putw <colour> <width> <text> [r]: text cut or padded to exactly <width>.
ui_putw() {
  local text="$3" width="$2" pad
  (( width > 0 )) || return 0
  (( ${#text} <= width )) || text="${text:0:width}"
  pad="${UI_SPACES:0:width-${#text}}"
  if [[ "${4:-}" == r ]]; then text="${pad}${text}"; else text="${text}${pad}"; fi
  UI_L+="$1${text}${UI_BASE}"
  UI_LW=$((UI_LW + width))
}

# ui_kv <width> <label> <colour> <value>: label left, value right, one cell.
ui_kv() {
  local width="$1" label="$2" value="$4" room
  (( ${#value} <= width )) || value="${value:0:width}"
  room=$((width - 1 - ${#value}))
  (( room >= 0 )) || room=0
  (( ${#label} <= room )) || label="${label:0:room}"
  ui_put "${C_MUTED}" "${label}"
  ui_gap $((width - ${#label} - ${#value}))
  ui_put "$3" "${value}"
}

# ui_endl <array> <width>: pad the line to <width>, append it, start anew.
ui_endl() {
  local -n _endl_lines="$1"
  (( UI_LW >= $2 )) || UI_L+="${UI_SPACES:0:$2-UI_LW}"
  _endl_lines+=("${UI_BASE}${UI_L}")
  UI_L=''
  UI_LW=0
}

# ui_spark <array> <width> <colour> <max>: the last <width> samples as bars.
ui_spark() {
  local -n _spark_values="$1"
  local width="$2" max="$4" count=${#_spark_values[@]} start i level text=''
  (( max > 0 )) || max=1
  start=$(( count > width ? count - width : 0 ))
  for ((i = start; i < count; i++)); do
    level=$(( _spark_values[i] * 7 / max ))
    (( level <= 7 )) || level=7
    (( level >= 0 )) || level=0
    text+="${UI_SPARK[level]}"
  done
  ui_put "$3" "${text}"
}

# ui_bar <width> <filled> <glyphs> <colour>: a filled bar on a dim track.
ui_bar() {
  local width="$1" filled="$2"
  local -n _bar_glyphs="$3"
  (( filled >= 0 )) || filled=0
  (( filled <= width )) || filled="${width}"
  ui_put "$4" "${_bar_glyphs:0:filled}"
  ui_put "${C_TRACK}" "${_bar_glyphs:0:width-filled}"
}

# ui_grid <cells> <columns> <rows> <inner width> <output array>
# Lays "label|value|colour variable" cells out column by column, each cell a
# label on the left and its value on the right. Cells that do not fit are
# left out, so callers list them in order of importance.
ui_grid() {
  local -n _grid_cells="$1"
  local columns="$2" rows="$3" inner="$4" output="$5"
  local cell row column index entry label value colour
  cell=$(((inner - 2 * (columns - 1)) / columns))
  for ((row = 0; row < rows; row++)); do
    for ((column = 0; column < columns; column++)); do
      index=$((column * rows + row))
      (( column == 0 )) || ui_gap 2
      entry="${_grid_cells[index]:-}"
      if [[ -z "${entry}" ]]; then ui_gap "${cell}"; continue; fi
      label="${entry%%|*}"; entry="${entry#*|}"
      value="${entry%%|*}"; colour="${entry#*|}"
      if [[ -n "${colour}" ]]; then local -n _grid_colour="${colour}"; colour="${_grid_colour}"; fi
      ui_kv "${cell}" "${label}" "${colour}" "${value}"
    done
    ui_endl "${output}" "${inner}"
  done
}

# ui_wrap <array> <width> <text>: the text as lines of at most <width>
# columns, broken between words.
ui_wrap() {
  local -n _wrap_out="$1"
  local width="$2" word line=''
  local -a words=()
  _wrap_out=()
  read -r -a words <<< "$3"
  for word in "${words[@]}"; do
    (( ${#word} <= width )) || word="${word:0:width}"
    if [[ -z "${line}" ]]; then
      line="${word}"
    elif (( ${#line} + 1 + ${#word} <= width )); then
      line+=" ${word}"
    else
      _wrap_out+=("${line}")
      line="${word}"
    fi
  done
  [[ -z "${line}" ]] || _wrap_out+=("${line}")
}

# ── number formats (no subshells) ────────────────────────────────────────────
ui_fmt_int() {
  local -n _fmt_out="$1"
  local number="$2" rest=''
  [[ "${number}" =~ ^[0-9]+$ ]] || { _fmt_out="${number}"; return 0; }
  while (( ${#number} > 3 )); do
    rest=",${number: -3}${rest}"
    number="${number:0:${#number}-3}"
  done
  _fmt_out="${number}${rest}"
}

# ui_scale <variable> <decimal text> <digits>: the value times 10^digits as an
# integer, so decimals from the metrics can be used in shell arithmetic.
ui_scale() {
  local -n _scale_out="$1"
  local text="${2:-}" digits="$3" sign=1 whole fraction
  _scale_out=0
  if [[ "${text}" == -* ]]; then sign=-1; text="${text#-}"; fi
  [[ "${text}" =~ ^([0-9]*)[.]?([0-9]*)$ ]] || return 1
  whole="${BASH_REMATCH[1]:-0}"
  fraction="${BASH_REMATCH[2]}000000000"
  fraction="${fraction:0:digits}"
  _scale_out=$(( sign * (10#${whole} * 10 ** digits + 10#${fraction:-0}) ))
}

ui_fmt_tenths() { printf -v "$1" '%d.%d' "$(($2 / 10))" "$(($2 % 10))"; }

ui_fmt_delay() { printf -v "$1" '%d.%02d s' "$(($2 / 1000))" "$((($2 % 1000) / 10))"; }

ui_fmt_duration() {
  local seconds="$2" days
  (( seconds >= 0 )) || seconds=0
  days=$((seconds / 86400))
  if (( days > 0 )); then
    printf -v "$1" '%dd %02d:%02d:%02d' "${days}" \
      "$((seconds % 86400 / 3600))" "$((seconds % 3600 / 60))" "$((seconds % 60))"
  else
    printf -v "$1" '%02d:%02d:%02d' \
      "$((seconds / 3600))" "$((seconds % 3600 / 60))" "$((seconds % 60))"
  fi
}

# ui_fmt_bytes <variable> <bytes>: 1,536 -> "1.5 KiB".
ui_fmt_bytes() {
  local -n _bytes_out="$1"
  local bytes="$2" unit tenths
  [[ "${bytes}" =~ ^[0-9]+$ ]] || { _bytes_out="${bytes}"; return 0; }
  if (( bytes < 1024 )); then _bytes_out="${bytes} B"; return 0; fi
  for unit in KiB MiB GiB TiB; do
    tenths=$((bytes * 10 / 1024))
    bytes=$((bytes / 1024))
    (( bytes >= 1024 )) || break
  done
  _bytes_out="$((tenths / 10)).$((tenths % 10)) ${unit}"
}

# ui_fmt_compact <variable> <number>: 1,234,567 -> "1.23 M".
ui_fmt_compact() {
  local -n _compact_out="$1"
  local number="$2"
  [[ "${number}" =~ ^[0-9]+$ ]] || { _compact_out="${number}"; return 0; }
  if (( number >= 1000000000 )); then
    printf -v _compact_out '%d.%02d B' "$((number / 1000000000))" "$((number % 1000000000 / 10000000))"
  elif (( number >= 1000000 )); then
    printf -v _compact_out '%d.%02d M' "$((number / 1000000))" "$((number % 1000000 / 10000))"
  else
    ui_fmt_int _compact_out "${number}"
  fi
}

ui_delay_colour() {
  local -n _delay_out="$1"
  if (( $2 <= 1000 )); then _delay_out="${C_OK}"
  elif (( $2 <= 3000 )); then _delay_out="${C_WARN}"
  else _delay_out="${C_DANGER}"; fi
}

# ── boxes ────────────────────────────────────────────────────────────────────
# A caller that sets UI_HELP before a panel is drawn gives that panel a help
# key: the panel is then known by that key (UI_PANEL_KEY, by output array) and
# by its title (UI_PANEL_TITLE), and it is drawn with a double accent border
# when the key is the one in UI_FOCUS.
UI_HELP=''
UI_FOCUS=''
UI_DOUBLE="${UI_SPACES// /═}"
declare -gA UI_PANEL_KEY=()
declare -gA UI_PANEL_TITLE=()

# ui_box_top <variable> <width> <title> <right title> <colour> [double]
ui_box_top() {
  local -n _top_out="$1"
  local width="$2" title="$3" right="$4" colour="$5"
  local left='╭' end='╮' rule="${UI_DASHES}" bar='─'
  if [[ "${6:-}" == double ]]; then left='╔'; end='╗'; rule="${UI_DOUBLE}"; bar='═'; fi
  local line="${colour}${left}${bar}${UI_RESET}" used=2 tail="${colour}${end}${UI_RESET}" tail_width=1 fill
  if [[ -n "${title}" ]]; then
    (( ${#title} + 6 <= width )) || title="${title:0:$(( width > 6 ? width - 6 : 0 ))}"
    line+=" ${UI_BOLD}${C_ACCENT}${title}${UI_RESET} "
    used=$((used + ${#title} + 2))
  fi
  if [[ -n "${right}" ]] && (( used + ${#right} + 5 <= width )); then
    tail=" ${C_MUTED}${right}${UI_RESET} ${colour}${bar}${end}${UI_RESET}"
    tail_width=$((${#right} + 4))
  fi
  fill=$((width - used - tail_width))
  (( fill >= 0 )) || fill=0
  _top_out="${line}${colour}${rule:0:fill}${UI_RESET}${tail}"
}

# ui_panel <output array> <width> <height> <title> <right title> [colour name]
# Wraps the lines in UI_BODY (each width-4 columns) in a rounded box of
# exactly <height> lines and <width> columns.
ui_panel() {
  local -n _panel_out="$1"
  local width="$2" height="$3" title="$4" right="$5" colour_name="${6:-BORDER}"
  local key="${UI_HELP}" top='' i side='│' style=''
  UI_HELP=''
  if [[ -n "${key}" ]]; then
    UI_PANEL_KEY["$1"]="${key}"
    UI_PANEL_TITLE["${key}"]="${title}"
    if [[ "${key}" == "${UI_FOCUS}" ]]; then colour_name=ACCENT; side='║'; style=double; fi
  else
    unset "UI_PANEL_KEY[$1]"
  fi
  local -n _panel_colour="C_${colour_name}"
  ui_box_top top "${width}" "${title}" "${right}" "${_panel_colour}" "${style}"
  _panel_out=("${top}")
  for ((i = 0; i < height - 2; i++)); do
    _panel_out+=("${_panel_colour}${side}${UI_RESET} ${UI_BODY[i]:-${UI_SPACES:0:width-4}} ${_panel_colour}${side}${UI_RESET}")
  done
  if [[ "${style}" == double ]]; then
    _panel_out+=("${_panel_colour}╚${UI_DOUBLE:0:width-2}╝${UI_RESET}")
  else
    _panel_out+=("${_panel_colour}╰${UI_DASHES:0:width-2}╯${UI_RESET}")
  fi
}

# ── output ───────────────────────────────────────────────────────────────────
UI_FRAME=()
UI_PREV=()
UI_OUT_ROWS=0

ui_invalidate() { UI_PREV=(); }

# Only rows that differ from the previous frame are written, inside one
# synchronised update so the terminal never shows a half-drawn frame.
ui_flush() {
  local out='' row changed=0
  for ((row = 0; row < ${#UI_FRAME[@]}; row++)); do
    [[ "${UI_FRAME[row]}" != "${UI_PREV[row]:-}" ]] || continue
    out+=$'\e['"$((row + 1))"';1H'"${UI_FRAME[row]}"
    changed=$((changed + 1))
  done
  UI_PREV=("${UI_FRAME[@]}")
  UI_OUT_ROWS="${changed}"
  [[ -z "${out}" ]] || printf '\e[?2026h%s\e[?2026l' "${out}"
}

##############################################################################
# Data: metrics through the node adapters, history and per-page collectors
##############################################################################
# Collects the node's metrics through the common adapter interface and keeps
# what the views need between collections (history for the sparklines, the
# recent block list, the leader schedule). Used after env has loaded the node
# adapter.
#
# glv_data_collect runs every REFRESH_RATE seconds and may fork (curl, the
# adapter's parser). glv_data_clock runs every second and never forks: it only
# moves the clock-driven values (countdowns, tip gap, uptime).

GLV_HISTORY_MAX=120
GLV_ROWS_MAX=60

glv_is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# glv_push <array> <value> <max>: append, keeping the newest <max> entries.
glv_push() {
  local -n _push_array="$1"
  _push_array+=("$2")
  (( ${#_push_array[@]} <= $3 )) || _push_array=("${_push_array[@]:${#_push_array[@]}-$3}")
}

glv_data_init() {
  D_IMPL="${NODE_IMPLEMENTATION_DISPLAY_NAME:-${NODE_IMPLEMENTATION:-node}}"
  # A name the operator set wins; otherwise the deployment folder says more
  # than the stock "Cardano Node".
  if [[ -n "${NODE_NAME:-}" && "${NODE_NAME}" != "Cardano Node" ]]; then
    D_NAME="${NODE_NAME}"
  else
    D_NAME="${NODE_HOME##*/}"
  fi
  D_NETWORK="${NETWORK_NAME:-${NODE_NETWORK:-unknown}}"
  D_ROLE=Relay
  D_OK=N
  D_DOWN=''
  D_FAILS=0
  D_VERSION='?'
  D_PID=''
  D_NOW=0
  D_COLLECTED_AT=0
  D_COLLECT_MS=0
  D_SLOW_AT=0
  D_KES_AT=0
  D_CPU=0
  D_CPU_BUSY=''
  D_CPU_TOTAL=''
  D_MEM=''
  D_DISK=''
  D_PCPU=''
  D_PCPU_TICKS=''
  D_PCPU_AT=0
  D_PCPU_PID=''
  D_LAST_EPOCH=''
  D_LAST_UPTIME=''
  D_LAST_HOT=''
  D_LAST_ADOPTED=''
  D_LAST_PHASE=''
  D_BLOCK_EVERY=''
  D_BIG_HOT=''
  D_BIG_WARM=''
  D_BIG_COLD=''
  D_THREADS=''
  D_LOAD=''
  D_HOST_MEM_TOTAL=''
  D_HOST_MEM_FREE=''
  D_CORES=0
  D_METRICS_URL=''
  D_PEERS=()
  D_STARTUP=()
  D_STARTUP_PID=''
  D_BIN_PID=''
  D_BIN_AT=0
  D_BIN_KEY=''
  D_BIN_SOURCE=''
  D_BIN_FILE=''
  D_BIN_DELETED=N
  D_BIN_SIZE=''
  D_BIN_MTIME=''
  D_BIN_VERSION=''
  D_BIN_REV=''
  D_BIN_BUILD=''
  D_BIN_PIN=''
  D_BIN_TAG=''
  D_BIN_MANIFEST=''
  D_PARAMS=()
  D_PARAMS_SOURCE=''
  D_PARAMS_NOTE=''
  D_PARAMS_EPOCH=''
  PARAMS_JOB_PID=''
  D_LOG=()
  D_LOG_NOTE=''
  D_NEXT_EPOCH_SLOTS=0
  D_EPOCHS=()
  declare -gA D_RAW=()
  local stat_line
  if [[ -r /proc/stat ]]; then
    while read -r stat_line; do
      [[ "${stat_line}" != cpu[0-9]* ]] || D_CORES=$((D_CORES + 1))
    done < /proc/stat
  fi
  if declare -F node_adapter_metrics_url >/dev/null; then
    D_METRICS_URL="$(node_adapter_metrics_url 2>/dev/null)" || D_METRICS_URL=''
  fi
  GLV_CLK_TCK="$(getconf CLK_TCK 2>/dev/null)" || GLV_CLK_TCK=100
  [[ "${GLV_CLK_TCK}" =~ ^[1-9][0-9]*$ ]] || GLV_CLK_TCK=100
  D_UPTIME=''
  D_TIP_GAP=''
  D_EPOCH_LEFT=''
  D_NEXT_AT=''
  D_NEXT_IN=''
  D_LAST_BLOCK=''
  D_LAST_FORKS=''
  D_LAST_ALERT=''
  D_LAST_EVENT=''
  D_KES_EXPIRES=''
  D_KES_SECONDS=''
  D_OPCERT_DISK=''
  D_OPCERT_CHAIN=''
  D_IDEAL=''
  D_LUCK=''
  D_SCHEDULE_EPOCH=''
  # The cnode adapter sets BLOCKLOG_DB; the others leave BLOCKLOG_DIR from
  # env as it is, so fall back to it the way CNTools does.
  D_BLOCKLOG_DB="${BLOCKLOG_DB:-${BLOCKLOG_DIR:-${NODE_HOME}/guild-db/blocklog}/blocklog.db}"
  D_RESULTS=N
  # Average seconds between blocks: slot length over the active slot coefficient.
  local coefficient=0
  if ui_scale coefficient "${ACTIVE_SLOTS_COEFF:-}" 4 && (( coefficient > 0 )) && glv_is_int "${SLOT_LENGTH:-}"; then
    D_BLOCK_EVERY=$((SLOT_LENGTH * 10000 / coefficient))
  fi
  H_DELAY=()
  H_CPU=()
  H_PCPU=()
  H_MEM=()
  D_ROWS=()
  D_SCHEDULE=()
  declare -gA D_STATUS=()
  declare -gA D_DETAIL=()
}

glv_data_stamp() { printf -v "$1" '%(%H:%M:%S)T' -1; }

# glv_data_event <headline> <detail>: a row for the block list and the footer.
glv_data_event() {
  local stamp
  glv_data_stamp stamp
  D_ROWS=("E|${stamp}|$1|${2:-}" "${D_ROWS[@]:0:GLV_ROWS_MAX-1}")
  D_LAST_EVENT="${stamp} $1${2:+ · $2}"
}

glv_data_cpu() {
  local label user nice system idle rest busy total
  [[ -r /proc/stat ]] || return 0
  read -r label user nice system idle rest < /proc/stat
  glv_is_int "${user}" && glv_is_int "${system}" && glv_is_int "${idle}" || return 0
  # Same figure as gLiveView 1: user and system time across the whole host.
  busy=$((user + system))
  total=$((user + system + idle))
  if [[ -n "${D_CPU_TOTAL}" ]] && (( total > D_CPU_TOTAL )); then
    D_CPU=$(((busy - D_CPU_BUSY) * 1000 / (total - D_CPU_TOTAL)))
  fi
  D_CPU_BUSY="${busy}"
  D_CPU_TOTAL="${total}"
  glv_push H_CPU "${D_CPU}" "${GLV_HISTORY_MAX}"
}

# Processor time of the node process alone, in tenths of a percent of one
# core, so a busy node on several cores can pass 100 %.
glv_data_process_cpu() {
  local line now ticks
  local -a field=()
  D_PCPU=''
  if [[ -z "${D_PID}" || ! -r "/proc/${D_PID}/stat" ]]; then D_PCPU_TICKS=''; return 0; fi
  read -r line < "/proc/${D_PID}/stat" 2>/dev/null || { D_PCPU_TICKS=''; return 0; }
  # The process name may hold spaces, so count fields after its closing bracket.
  read -r -a field <<< "${line##*) }"
  glv_is_int "${field[11]:-}" && glv_is_int "${field[12]:-}" || return 0
  ticks=$((field[11] + field[12]))
  now="${EPOCHREALTIME/[.,]/}"
  if [[ -n "${D_PCPU_TICKS}" && "${D_PCPU_PID}" == "${D_PID}" ]] && (( now > D_PCPU_AT && ticks >= D_PCPU_TICKS )); then
    D_PCPU=$(( (ticks - D_PCPU_TICKS) * 1000000000 / (GLV_CLK_TCK * (now - D_PCPU_AT)) ))
    glv_push H_PCPU "${D_PCPU}" "${GLV_HISTORY_MAX}"
  fi
  D_PCPU_TICKS="${ticks}"
  D_PCPU_AT="${now}"
  D_PCPU_PID="${D_PID}"
}

# Changes worth a line in the event list. Each keeps the last value it saw
# and reports only when that value moves.
glv_data_watch() {
  local phase=''
  if node_metric_has epochnum && glv_is_int "${epochnum:-}"; then
    if [[ -n "${D_LAST_EPOCH}" ]] && (( epochnum > D_LAST_EPOCH )); then
      glv_data_event "epoch ${epochnum}" "started"
    fi
    D_LAST_EPOCH="${epochnum}"
  fi
  if node_metric_has uptimes && glv_is_int "${uptimes:-}"; then
    if [[ -n "${D_LAST_UPTIME}" ]] && (( uptimes + 5 < D_LAST_UPTIME )); then
      glv_data_event "node restarted" "${D_IMPL}"
    fi
    D_LAST_UPTIME="${uptimes}"
  fi
  if node_metric_has peer_selection_hot && glv_is_int "${peer_selection_hot:-}"; then
    if [[ -n "${D_LAST_HOT}" ]]; then
      if (( peer_selection_hot == 0 && D_LAST_HOT > 0 )); then
        glv_data_event "no hot peers" "the node has no peer in use"
      elif (( peer_selection_hot > 0 && D_LAST_HOT == 0 )); then
        glv_data_event "peers back" "${peer_selection_hot} hot"
      fi
    fi
    D_LAST_HOT="${peer_selection_hot}"
  fi
  if [[ "${D_ROLE}" == Core ]] && node_metric_has adopted && glv_is_int "${adopted:-}"; then
    if [[ -n "${D_LAST_ADOPTED}" ]] && (( adopted > D_LAST_ADOPTED )); then
      glv_data_event "block adopted" "block ${blocknum:-?}"
    fi
    D_LAST_ADOPTED="${adopted}"
  fi
  if node_metric_has sync_phase; then phase="${sync_phase:-}"; fi
  if [[ "${phase}" != "${D_LAST_PHASE}" ]]; then
    if [[ -n "${phase}" ]]; then glv_data_event "sync" "${phase}"
    else glv_data_event "sync done" "${D_LAST_PHASE}"; fi
    D_LAST_PHASE="${phase}"
  fi
}

# cardano-node counts big ledger peers apart from its other outgoing peers.
# The shared parser does not carry them yet, so they are read from the scrape
# it indexed. They belong in common_parse_cardano_metrics once this tool ships.
glv_data_big_ledger() {
  local value='' name
  D_BIG_HOT=''; D_BIG_WARM=''; D_BIG_COLD=''
  D_RAW=()
  declare -F prometheus_first_metric_value >/dev/null || return 0
  for name in Hot Warm Cold; do
    if prometheus_first_metric_value value "cardano_node_metrics_peerSelection_${name}BigLedgerPeers_int" 2>/dev/null &&
       glv_is_int "${value}"; then
      printf -v "D_BIG_${name^^}" '%s' "${value}"
    fi
  done
  # Counters only the Peers page shows, kept under the node's own names.
  for name in peerSelection_KnownLocalRootPeers peerSelection_EstablishedLocalRootPeers \
      peerSelection_ActiveLocalRootPeers peerSelection_RootPeers peerSelection_KnownPeers \
      inboundGovernor_cold inboundGovernor_idle; do
    if prometheus_first_metric_value value "cardano_node_metrics_${name}_int" 2>/dev/null &&
       glv_is_int "${value}"; then
      D_RAW["${name}"]="${value}"
    fi
  done
}

glv_data_memory() {
  local key value rest
  D_MEM=''
  [[ -n "${D_PID}" && -r "/proc/${D_PID}/status" ]] || return 0
  D_THREADS=''
  while read -r key value rest; do
    case "${key}" in
      VmRSS:) glv_is_int "${value}" && D_MEM=$((value * 10 / 1048576)) ;;
      Threads:) D_THREADS="${value}"; break ;;
    esac
  done < "/proc/${D_PID}/status"
  [[ -z "${D_MEM}" ]] || glv_push H_MEM "${D_MEM}" "${GLV_HISTORY_MAX}"
}

glv_data_disk() {
  D_DISK=''
  [[ "$(df -P "${NODE_HOME}" 2>/dev/null)" =~ ([0-9]+)% ]] && D_DISK="${BASH_REMATCH[1]}"
}

# The operational certificate counters. Dingo reports them as metrics;
# cardano-node needs one CLI query, so this runs when the role is detected and
# not on every collection.
glv_data_opcert() {
  local file adapter_file answer
  D_OPCERT_DISK=''
  D_OPCERT_CHAIN=''
  node_has opcert || return 0
  file="${POOL_FOLDER:-}/${POOL_NAME:-}/${POOL_OPCERT_FILENAME:-op.cert}"
  if [[ ! -f "${file}" ]]; then
    adapter_file="$(node_operational_certificate 2>/dev/null || true)"
    [[ -z "${adapter_file}" ]] || file="${adapter_file}"
  fi
  [[ -f "${file}" && -n "${CCLI:-}" && -n "${CARDANO_NODE_SOCKET_PATH:-}" ]] || return 0
  # shellcheck disable=SC2086
  answer="$("${CCLI}" query kes-period-info ${NETWORK_IDENTIFIER} --op-cert-file "${file}" 2>/dev/null)" || return 0
  [[ "${answer}" =~ qKesNodeStateOperationalCertificateNumber.:[[:space:]]([0-9]+) ]] &&
    D_OPCERT_CHAIN="${BASH_REMATCH[1]}"
  [[ "${answer}" =~ qKesOnDiskOperationalCertificateNumber.:[[:space:]]([0-9]+) ]] &&
    D_OPCERT_DISK="${BASH_REMATCH[1]}"
}

# The leader schedule and its results for the current epoch. CNCLI writes
# these rows for cardano-node and amaru-leaderlog.sh for Amaru, so nothing
# here asks which node produced them. Results come from their validate
# services: D_RESULTS is Y once any slot has a status other than leader, and
# until then the views show passed slots instead of results. D_DETAIL holds,
# per slot, what blockdetail says about the battle a block was in.
glv_data_blocklog() {
  local kind first second third fourth fifth total=0
  D_SCHEDULE=()
  D_STATUS=()
  D_DETAIL=()
  D_EPOCHS=()
  D_LED=()
  D_RESULTS=N
  D_IDEAL=''
  D_LUCK=''
  D_NEXT_AT=''
  D_SCHEDULE_EPOCH=''
  D_NEXT_EPOCH_SLOTS=0
  [[ -f "${D_BLOCKLOG_DB}" ]] && glv_is_int "${epochnum:-}" || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  # One sqlite3 process for everything: S rows are this epoch's leader slots
  # (slot in epoch, status, time, block, slot), X counts the next epoch's, N is
  # the next slot's time, I the ideal count, H one row per recent epoch, L the
  # leader slots of every epoch for the epoch history.
  while IFS='|' read -r kind first second third fourth fifth; do
    case "${kind}" in
      S) D_SCHEDULE+=("${first}|${second}|${third}|${fourth}|${fifth}")
         D_STATUS["${second}"]=$(( ${D_STATUS[${second}]:-0} + 1 ))
         total=$((total + 1)) ;;
      X) glv_is_int "${first}" && D_NEXT_EPOCH_SLOTS="${first}" ;;
      N) glv_is_int "${first}" && D_NEXT_AT="${first}" ;;
      I) D_IDEAL="${first}" ;;
      H) D_EPOCHS+=("${first}|${second}|${third}|${fourth}") ;;
      L) glv_is_int "${first}" && D_LED["${first}"]="${second}" ;;
      V) [[ "${first}" != 1 ]] || D_RESULTS=Y ;;
      D) glv_is_int "${first}" && D_DETAIL["${first}"]="${second}|${third}|${fourth}|${fifth}" ;;
    esac
  done < <(sqlite3 "${D_BLOCKLOG_DB}" "
    SELECT 'S', slot_in_epoch, status, CAST(strftime('%s', at) AS INTEGER), block, slot
      FROM blocklog WHERE epoch=${epochnum} ORDER BY slot;
    SELECT 'X', COUNT(*) FROM blocklog WHERE epoch=${epochnum}+1;
    SELECT 'N', CAST(strftime('%s', at) AS INTEGER) FROM blocklog
      WHERE datetime(at) > datetime('now') ORDER BY slot LIMIT 1;
    SELECT 'I', epoch_slots_ideal FROM epochdata WHERE epoch=${epochnum} LIMIT 1;
    SELECT 'H', b.epoch, COUNT(*),
           SUM(CASE WHEN b.status IN ('adopted','confirmed') THEN 1 ELSE 0 END),
           IFNULL((SELECT e.epoch_slots_ideal FROM epochdata e WHERE e.epoch=b.epoch LIMIT 1), '')
      FROM blocklog b GROUP BY b.epoch ORDER BY b.epoch DESC LIMIT 6;
    SELECT 'L', epoch, COUNT(*) FROM blocklog GROUP BY epoch;
    SELECT 'V', EXISTS(SELECT 1 FROM blocklog WHERE status <> 'leader');
    SELECT 'D', d.slot, d.reason, IFNULL(d.forge_ms, ''), IFNULL(d.winner_slot, ''),
           CASE WHEN d.winner_ticker <> '' THEN d.winner_ticker ELSE d.winner_pool END, IFNULL(d.winner_ms, ''),
           CASE WHEN d.winner_vrf <> '' AND d.vrf <> '' THEN d.winner_vrf < d.vrf ELSE '' END
      FROM blockdetail d JOIN blocklog b ON b.slot = d.slot WHERE b.epoch=${epochnum};" 2>/dev/null)
  D_SCHEDULE_EPOCH="${epochnum}"
  D_STATUS[total]="${total}"
  if [[ "${D_IDEAL}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    local ideal_hundredths
    ui_scale ideal_hundredths "${D_IDEAL}" 2
    (( ideal_hundredths <= 0 )) || D_LUCK=$((total * 100000 / ideal_hundredths))
  fi
}

glv_data_kes() {
  D_KES_EXPIRES=''
  D_KES_SECONDS=''
  node_metric_has remaining_kes_periods && declare -F kesExpiration >/dev/null || return 0
  kesExpiration >/dev/null 2>&1 || return 0
  D_KES_EXPIRES="${kes_expiration:-}"
  D_KES_SECONDS="${expiration_time_sec_diff:-}"
}

# A new tip since the last collection becomes a row in the block list and a
# sample in the propagation history.
glv_data_blocks() {
  local delay=-1 note='' stamp
  node_metric_has blocknum && glv_is_int "${blocknum:-}" || return 0
  if [[ -n "${D_LAST_BLOCK}" ]] && (( blocknum > D_LAST_BLOCK )); then
    if node_metric_has block_delay; then
      ui_scale delay "${block_delay}" 3 || delay=-1
    fi
    (( blocknum - D_LAST_BLOCK <= 1 )) || note="+$((blocknum - D_LAST_BLOCK - 1)) more"
    if glv_is_int "${forks:-}" && glv_is_int "${D_LAST_FORKS}" && (( forks > D_LAST_FORKS )); then
      note="fork switch"
    fi
    (( delay <= 5000 )) || note="late"
    glv_data_stamp stamp
    D_ROWS=("B|${stamp}|${blocknum}|${slotnum:-}|${delay}|${note}" "${D_ROWS[@]:0:GLV_ROWS_MAX-1}")
    (( delay < 0 )) || glv_push H_DELAY "${delay}" "${GLV_HISTORY_MAX}"
  fi
  D_LAST_BLOCK="${blocknum}"
  glv_is_int "${forks:-}" && D_LAST_FORKS="${forks}"
}

# The node's TCP connections with the kernel's round-trip time for each, from
# one ss call. Rows are "rtt in tenths of ms|in or out|address|port|local
# port", fastest first. Nothing is probed and the node is not asked anything.
# "in" means the connection uses the node's listening port; cardano-node and
# Amaru also dial out from that port, so only the node itself knows who opened
# such a connection (see peers.sh).
glv_data_peers() {
  local line entry='' mine=N rtt local_port remote address port
  local -a raw=() field=()
  D_PEERS=()
  [[ -n "${D_PID}" ]] && command -v ss >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    if [[ "${line}" == [[:space:]]* ]]; then
      # The detail line of the socket above; ss may name the process on either.
      [[ "${line}" != *"pid=${D_PID},"* ]] || mine=Y
      if [[ -n "${entry}" && "${mine}" == Y ]]; then
        rtt=999999
        if [[ "${line}" =~ rtt:([0-9]+)([.]([0-9]))? ]]; then
          rtt=$((BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0}))
        fi
        raw+=("${rtt}|${entry}")
      fi
      entry=''
      continue
    fi
    entry=''
    mine=N
    [[ "${line}" != *"pid=${D_PID},"* ]] || mine=Y
    set -f
    # shellcheck disable=SC2206
    field=(${line})
    set +f
    local_port="${field[2]:-}"
    local_port="${local_port##*:}"
    remote="${field[3]:-}"
    [[ -n "${remote}" ]] || continue
    port="${remote##*:}"
    address="${remote%:*}"
    address="${address#[}"; address="${address%]}"; address="${address#::ffff:}"
    # Scrapes of the node's metrics and its own telemetry export are not peers.
    [[ "${local_port}" != "${PROM_PORT:-}" ]] || continue
    if [[ "${port}" == "${NODE_TELEMETRY_PORT:-}" && "${address}" =~ ^(127\.|::1$) ]]; then continue; fi
    if [[ "${local_port}" == "${CNODE_PORT:-}" ]]; then
      entry="in|${address}|${port}|${local_port}"
    else
      entry="out|${address}|${port}|${local_port}"
    fi
  done < <(ss -tinpH state established 2>/dev/null)
  (( ${#raw[@]} > 0 )) || return 0
  mapfile -t D_PEERS < <(printf '%s\n' "${raw[@]}" | sort -t'|' -k1,1n)
}

# Host figures for the System page, all read from /proc without a fork.
glv_data_system() {
  local key value rest one five fifteen
  D_LOAD=''
  D_HOST_MEM_TOTAL=''
  D_HOST_MEM_FREE=''
  if [[ -r /proc/loadavg ]]; then
    read -r one five fifteen rest < /proc/loadavg
    D_LOAD="${one} · ${five} · ${fifteen}"
  fi
  [[ -r /proc/meminfo ]] || return 0
  while read -r key value rest; do
    case "${key}" in
      MemTotal:) D_HOST_MEM_TOTAL="${value}" ;;
      MemAvailable:) D_HOST_MEM_FREE="${value}"; break ;;
    esac
  done < /proc/meminfo
}

# The newest lines of the node's journal for the Logs page.
glv_data_logs() {
  # Paused, the page keeps the lines it has.
  [[ "${LOG_PAUSED:-N}" != Y || ${#D_LOG[@]} -eq 0 ]] || return 0
  D_LOG=()
  D_LOG_NOTE=''
  if [[ -z "${NODE_SERVICE:-}" ]] || ! command -v journalctl >/dev/null 2>&1; then
    D_LOG_NOTE="No systemd service is known for this node, so there is no journal to read."
    return 0
  fi
  mapfile -t D_LOG < <(journalctl -q -o cat --no-pager -n 1000 -u "${NODE_SERVICE}" 2>/dev/null)
  glv_log_index
  (( ${#D_LOG[@]} > 0 )) ||
    D_LOG_NOTE="journalctl -u ${NODE_SERVICE} returned nothing. The node may log elsewhere, or this user may not read its journal."
}

# How the node process was started, as "name|value" rows: the options on its
# command line, then the settings in its environment that carry the node's
# own prefix. Read once for each process.
glv_data_startup() {
  local word name='' prefix command='' runtime='' runtime_options=''
  local -a arguments=()
  [[ "${D_STARTUP_PID}" != "${D_PID}" ]] || return 0
  D_STARTUP=()
  D_STARTUP_PID="${D_PID}"
  [[ -n "${D_PID}" && -r "/proc/${D_PID}/cmdline" ]] || return 0
  mapfile -d '' -t arguments < "/proc/${D_PID}/cmdline"
  for word in "${arguments[@]:1}"; do
    # Options for the Haskell runtime sit between +RTS and -RTS.
    if [[ "${word}" == +RTS ]]; then runtime=open; continue; fi
    if [[ "${word}" == -RTS ]]; then runtime=closed; continue; fi
    if [[ "${runtime}" == open ]]; then runtime_options+="${runtime_options:+ }${word}"; continue; fi
    case "${word}" in
      --*=*) [[ -z "${name}" ]] || D_STARTUP+=("${name}|set"); D_STARTUP+=("${word%%=*}|${word#*=}"); name='' ;;
      -*) [[ -z "${name}" ]] || D_STARTUP+=("${name}|set"); name="${word}" ;;
      *) if [[ -n "${name}" ]]; then D_STARTUP+=("${name}|${word}"); name=''; else command+="${command:+ }${word}"; fi ;;
    esac
  done
  [[ -z "${name}" ]] || D_STARTUP+=("${name}|set")
  [[ -z "${runtime_options}" ]] || D_STARTUP=("Runtime options|${runtime_options}" "${D_STARTUP[@]}")
  [[ -z "${command}" ]] || D_STARTUP=("Command|${command}" "${D_STARTUP[@]}")
  case "${NODE_IMPLEMENTATION:-}" in
    amaru) prefix=AMARU_ ;;
    dingo) prefix=DINGO_ ;;
    *) prefix=CARDANO_ ;;
  esac
  [[ -r "/proc/${D_PID}/environ" ]] || return 0
  while IFS= read -r -d '' word; do
    [[ "${word}" == "${prefix}"* ]] || continue
    name="${word%%=*}"
    # Nothing that looks like a secret is put on screen.
    if [[ "${name}" =~ (KEY|TOKEN|SECRET|PASS) ]]; then D_STARTUP+=("${name}|hidden")
    else D_STARTUP+=("${name}|${word#*=}"); fi
  done < "/proc/${D_PID}/environ"
}

# glv_binary_parse <implementation> <version output> <version var> <revision
# var> <build var>: the version, the short revision and the build platform
# from what the node binary prints about itself:
#   cardano-node 11.2.0 - linux-x86_64 - ghc-9.6 / git rev dac0d7ab...
#   Amaru 10.11.20261029 (23031e0)
#   v0.90.5 (commit 62f1a84)                         (dingo version)
# The locals carry a prefix because the results are written through namerefs.
glv_binary_parse() {
  local -n _bp_version="$3" _bp_rev="$4" _bp_build="$5"
  local _bp_text="$2" _bp_re
  _bp_version=''
  _bp_rev=''
  _bp_build=''
  case "$1" in
    cnode)
      _bp_re='cardano-node ([^ ]+) - ([^ ]+) - ([^[:space:]]+)'
      if [[ "${_bp_text}" =~ ${_bp_re} ]]; then
        _bp_version="${BASH_REMATCH[1]}"
        _bp_build="${BASH_REMATCH[2]} · ${BASH_REMATCH[3]}"
      fi
      _bp_re='git rev ([0-9a-f]{7,40})'
      [[ ! "${_bp_text}" =~ ${_bp_re} ]] || _bp_rev="${BASH_REMATCH[1]:0:8}"
      ;;
    amaru)
      _bp_re='[Aa]maru v?([0-9][^[:space:]]*)( \(([0-9a-f]{7,40})\))?'
      if [[ "${_bp_text}" =~ ${_bp_re} ]]; then
        _bp_version="${BASH_REMATCH[1]}"
        _bp_rev="${BASH_REMATCH[3]:0:8}"
      fi
      ;;
    dingo)
      _bp_re='^v?([0-9][^[:space:]]*)( \(commit ([0-9a-f]{7,40})\))?'
      if [[ "${_bp_text}" =~ ${_bp_re} ]]; then
        _bp_version="${BASH_REMATCH[1]}"
        _bp_rev="${BASH_REMATCH[3]:0:8}"
      fi
      ;;
  esac
}

# The program file the node process runs, for the Binary panel: its path, size
# and date, the version it reports, and the release pin of the deployment.
# The file is looked at every 10 s while the page is open, and the binary is
# only run again when the file or the process changes.
glv_data_binary() {
  local file='' deleted=N stat_line key output name manifest
  [[ -n "${D_PID}" ]] || return 0
  (( D_COLLECTED_AT - D_BIN_AT >= 10 )) || [[ "${D_BIN_PID}" != "${D_PID}" ]] || return 0
  D_BIN_AT="${D_COLLECTED_AT}"
  D_BIN_PID="${D_PID}"
  if file="$(readlink "/proc/${D_PID}/exe" 2>/dev/null)" && [[ -n "${file}" ]]; then
    # A binary replaced while the process runs is shown with this suffix.
    if [[ "${file}" == *' (deleted)' ]]; then deleted=Y; file="${file% (deleted)}"; fi
    D_BIN_SOURCE=process
  else
    case "${NODE_IMPLEMENTATION:-}" in
      amaru) name=amaru ;;
      dingo) name=dingo ;;
      *) name=cardano-node ;;
    esac
    file="${NODE_BINARY:-${NODE_HOME}/bin/${name}}"
    D_BIN_SOURCE=configured
  fi
  D_BIN_FILE="${file}"
  D_BIN_DELETED="${deleted}"
  stat_line="$(stat -L -c '%s %Y' -- "${file}" 2>/dev/null)" || stat_line=''
  read -r D_BIN_SIZE D_BIN_MTIME <<< "${stat_line}"
  key="${D_PID}|${file}|${stat_line}"
  [[ "${key}" != "${D_BIN_KEY}" ]] || return 0
  D_BIN_KEY="${key}"
  output=''
  if [[ -n "${stat_line}" && -x "${file}" ]]; then
    case "${NODE_IMPLEMENTATION:-}" in
      dingo) output="$(timeout 5 "${file}" version 2>/dev/null | head -n 3)" ;;
      *) output="$(timeout 5 "${file}" --version 2>/dev/null | head -n 3)" ;;
    esac
  fi
  glv_binary_parse "${NODE_IMPLEMENTATION:-cnode}" "${output}" D_BIN_VERSION D_BIN_REV D_BIN_BUILD
  D_BIN_PIN=''
  D_BIN_TAG=''
  manifest="${NODE_HOME}/files/${NODE_IMPLEMENTATION:-cnode}-release.json"
  if [[ -r "${manifest}" ]] && command -v jq >/dev/null 2>&1; then
    { IFS= read -r D_BIN_PIN; IFS= read -r D_BIN_TAG; } < <(jq -r '(.version // ""), (.releaseTag // "")' "${manifest}" 2>/dev/null)
    D_BIN_MANIFEST="${manifest##*/}"
  fi
}

# glv_binary_state <text var> <colour var>: the binary on disk against the
# running process. A file replaced after the process started means the node
# runs the old one until it restarts.
glv_binary_state() {
  local -n _bs_text="$1" _bs_colour="$2"
  local _bs_start='' _bs_running="${D_VERSION#v}"
  _bs_colour=''
  if [[ -z "${D_BIN_VERSION}" ]]; then
    _bs_text='version not readable'
    _bs_colour="${C_MUTED}"
    return 0
  fi
  _bs_text="${D_BIN_VERSION}${D_BIN_REV:+ (${D_BIN_REV})}"
  glv_is_int "${D_UPTIME}" && _bs_start=$((D_NOW - D_UPTIME))
  if [[ "${D_BIN_DELETED}" == Y ]] ||
     { glv_is_int "${D_BIN_MTIME}" && glv_is_int "${_bs_start}" && (( D_BIN_MTIME > _bs_start + 2 )); }; then
    _bs_text+=' · restart to run it'
    _bs_colour="${C_WARN}"
  elif [[ -n "${_bs_running}" && "${_bs_running}" != '?' && "${D_BIN_VERSION#v}" != "${_bs_running}" ]]; then
    _bs_text+=" · running ${D_VERSION}"
    _bs_colour="${C_WARN}"
  else
    _bs_text+=' · same as running'
  fi
}

# glv_binary_pin <text var> <colour var>: the version the deployment's release
# manifest pins, against the running version.
glv_binary_pin() {
  local -n _pin_text="$1" _pin_colour="$2"
  local _pin_running="${D_VERSION#v}"
  _pin_text=''
  _pin_colour=''
  [[ -n "${D_BIN_PIN}" ]] || return 0
  if [[ "${D_BIN_PIN}" == latest ]]; then
    _pin_text="latest release, from ${D_BIN_MANIFEST}"
    _pin_colour="${C_MUTED}"
    return 0
  fi
  _pin_text="${D_BIN_PIN}"
  [[ -z "${D_BIN_TAG}" || "${D_BIN_TAG}" == "${D_BIN_PIN}" ]] || _pin_text+=" (${D_BIN_TAG})"
  if [[ -z "${_pin_running}" || "${_pin_running}" == '?' ]]; then
    _pin_text+=" from ${D_BIN_MANIFEST}"
  elif [[ "${D_BIN_PIN#v}" == "${_pin_running}" ]]; then
    _pin_text+=' · met'
  else
    _pin_text+=" · running ${D_VERSION}"
    _pin_colour="${C_WARN}"
  fi
}

# The protocol parameters, as "group|label|value" rows on standard output:
# from the node through its socket where it has one, else from Koios. Runs
# as a background job because either can take a moment.
glv_params_job_run() {
  local json='' source=''
  if [[ -n "${CCLI:-}" && -S "${CARDANO_NODE_SOCKET_PATH:-}" ]]; then
    # shellcheck disable=SC2086
    json="$("${CCLI}" query protocol-parameters ${NETWORK_IDENTIFIER} 2>/dev/null)" && source="the node"
    [[ "${json}" == '{'* ]] || { json=''; source=''; }
  fi
  if [[ -z "${json}" && -n "${KOIOS_API:-}" ]]; then
    json="$(curl -sSL -f -m 10 "${KOIOS_API_HEADERS[@]}" "${KOIOS_API}/cli_protocol_params" 2>/dev/null)" && source="Koios"
    [[ "${json}" == '{'* ]] || { json=''; source=''; }
  fi
  if [[ -z "${json}" ]]; then printf 'none\n'; return 0; fi
  printf 'source\t%s\n' "${source}"
  jq -r '
    def short: {"memory": "mem", "steps": "cpu", "priceMemory": "mem", "priceSteps": "cpu"}[.] // .;
    def era: if . >= 12 then " · Dijkstra" elif . >= 9 then " · Conway" elif . >= 7 then " · Babbage" else "" end;
    def show:
      if type == "object" and has("major") then "\(.major).\(.minor)\(.major | era)"
      elif type == "object" then (to_entries | map("\(.key | short)=\(.value)") | join(", "))
      elif . == null then "none"
      else tostring end;
    [["Network","protocolVersion","Protocol version"],
     ["Network","maxBlockBodySize","Max block body size"],
     ["Network","maxTxSize","Max transaction size"],
     ["Network","maxBlockHeaderSize","Max block header size"],
     ["Network","maxTxExecutionUnits","Max tx execution units"],
     ["Network","maxBlockExecutionUnits","Max block execution units"],
     ["Network","maxValueSize","Max value size"],
     ["Network","maxCollateralInputs","Max collateral inputs"],
     ["Network","maxRefScriptSizePerTx","Max ref script size per tx"],
     ["Network","maxRefScriptSizePerBlock","Max ref script size per block"],
     ["Economic","txFeePerByte","Min fee per byte"],
     ["Economic","txFeeFixed","Min fee fixed"],
     ["Economic","stakeAddressDeposit","Stake key deposit"],
     ["Economic","stakePoolDeposit","Stake pool deposit"],
     ["Economic","monetaryExpansion","Monetary expansion"],
     ["Economic","treasuryCut","Treasury expansion"],
     ["Economic","minPoolCost","Min pool cost"],
     ["Economic","utxoCostPerByte","Lovelace per UTxO byte"],
     ["Economic","executionUnitPrices","Execution unit prices"],
     ["Economic","collateralPercentage","Collateral percentage"],
     ["Economic","minFeeRefScriptCostPerByte","Ref script fee per byte"],
     ["Economic","refScriptCostMultiplier","Ref script cost multiplier"],
     ["Economic","refScriptCostStride","Ref script cost stride"],
     ["Economic","refInputsCostPerDatumByte","Ref input cost per datum byte"],
     ["Economic","refInputsCostPerMultiAssetPolicy","Ref input cost per policy"],
     ["Economic","minPoolMargin","Min pool margin"],
     ["Economic","maxPledgeLeverage","Max pledge leverage"],
     ["Governance","poolRetireMaxEpoch","Pool max retirement epoch"],
     ["Governance","stakePoolTargetNum","Optimal stake pools"],
     ["Governance","poolPledgeInfluence","Pledge influence"],
     ["Governance","committeeMinSize","Min committee size"],
     ["Governance","committeeMaxTermLength","Max committee term length"],
     ["Governance","govActionLifetime","Gov action lifetime"],
     ["Governance","govActionDeposit","Gov action deposit"],
     ["Governance","dRepDeposit","DRep deposit"],
     ["Governance","dRepActivity","DRep expiry"],
     ["Peras","perasTargetCommitteeSize","Target committee size"],
     ["Peras","perasQuorumThresholdSafetyMargin","Quorum safety margin"],
     ["Peras","perasCertBoost","Certificate boost"],
     ["Peras","perasMinCandidateBlockAge","Min candidate block age"],
     ["Peras","perasHealingFactor","Healing factor"],
     ["Peras","perasBootstrapRound","Bootstrap round"],
     ["Leios","leiosCommitteeSize","Committee size"],
     ["Leios","leiosQuorumStakeThreshold","Quorum stake threshold"],
     ["Leios","leiosAnnouncementPeriodLength","Announcement period"],
     ["Leios","leiosVotePeriodLength","Vote period"],
     ["Leios","leiosDiffusionPeriodLength","Diffusion period"],
     ["Leios","maxEndorserBlockTxsSize","Max EB transactions size"],
     ["Leios","maxEndorserBlockReferencesSize","Max EB references size"],
     ["Leios","maxEndorserBlockExecutionUnits","Max EB execution units"],
     ["Leios","maxRefScriptSizePerEndorserBlock","Max EB ref script size"]] as $known |
    . as $p |
    # Dijkstra-era parameters can be null, which means not set: maxPledgeLeverage
    # null is no limit. A Conway-era node does not have them at all.
    ($known[] | .[1] as $key | select($p | has($key)) | select($p[$key] != null or .[0] == "Economic" or .[0] == "Peras") |
      ["row", .[0], .[2], ($p[.[1]] | show)]),
    (($p | keys) - ($known | map(.[1])) | .[] |
      select(($p[.] | type) == "number" or ($p[.] | type) == "string" or ($p[.] | type) == "boolean") |
      ["row", "Other", ., ($p[.] | tostring)])
    | @tsv' <<< "${json}" 2>/dev/null
}

# Starts reading the protocol parameters unless that is running, or was done
# for this epoch already.
glv_params_job_start() {
  [[ -z "${PARAMS_JOB_PID}" ]] || return 0
  [[ -z "${D_PARAMS_EPOCH}" || "${D_PARAMS_EPOCH}" != "${epochnum:-}" ]] || return 0
  rm -f -- "${PARAMS_JOB_FILE}" "${PARAMS_JOB_FILE}.part"
  (
    glv_params_job_run > "${PARAMS_JOB_FILE}.part" 2>/dev/null
    mv -f -- "${PARAMS_JOB_FILE}.part" "${PARAMS_JOB_FILE}"
  ) < /dev/null > /dev/null 2>&1 &
  PARAMS_JOB_PID=$!
}

glv_params_job_poll() {
  local kind first second third
  [[ -n "${PARAMS_JOB_PID}" ]] || return 0
  if [[ ! -f "${PARAMS_JOB_FILE}" ]]; then
    ! kill -0 "${PARAMS_JOB_PID}" 2>/dev/null || return 0
    [[ -f "${PARAMS_JOB_FILE}" ]] || { PARAMS_JOB_PID=''; D_PARAMS_NOTE="The protocol parameters could not be read."; return 0; }
  fi
  D_PARAMS=()
  D_PARAMS_NOTE=''
  while IFS=$'\t' read -r kind first second third; do
    case "${kind}" in
      source) D_PARAMS_SOURCE="${first}" ;;
      row) D_PARAMS+=("${first}|${second}|${third}") ;;
      none) D_PARAMS_NOTE="No protocol parameters: the node has no local socket to ask, and no Koios address is set for this network." ;;
    esac
  done < "${PARAMS_JOB_FILE}"
  rm -f -- "${PARAMS_JOB_FILE}"
  PARAMS_JOB_PID=''
  D_PARAMS_EPOCH="${epochnum:-}"
}

# ── Pool data from Koios ─────────────────────────────────────────────────────
# On a block producer the Production page shows the pool as Koios sees it and
# its epoch history, and the rail flags a pledge that is not met. Every Koios
# request runs in a background job, so a slow or absent Koios never holds the
# page up: until an answer comes the panels say what they wait for, and after
# a failure they keep the last answer and ask again a minute later.

POOL_JOB_PID=''
POOL_STATE=off        # off, waiting, ok, stale, failed, none, unknown, nokoios
POOL_NOTE=''
POOL_ID_B32=''
POOL_FETCHED_AT=0
POOL_FAILED_AT=0
POOL_EPOCH=''
declare -gA POOL_INFO=()    # field -> value, from pool_info
declare -gA POOL_SNAP=()    # epoch -> "pool stake|ideal blocks in hundredths"
declare -gA POOL_BLOCKS=()  # epoch -> blocks made, for the current and the previous epoch
HIST_JOB_PID=''
HIST_JOB_OFFSET=''
HIST_CHUNK=10
HIST_TOTAL=-1         # settled epochs Koios has for the pool, -1 while unknown
HIST_KNOWN=0          # rows loaded, counted from the newest
HIST_EPOCH=''         # the epoch the loaded rows belong to
HIST_SCROLL=0
HIST_VIRTUAL=0
HIST_ROWS_TOTAL=0
declare -gA HIST_ROW=()     # Koios offset -> "epoch|stake|ideal hundredths|delegators|blocks|fees|rewards|ROS hundredths"
declare -gA HIST_LOADED=()  # chunk offset -> 1
declare -gA HIST_FAILED=()  # chunk offset -> time of the failure
HIST_VIEW=()
HIST_SHOWN=0
declare -gA D_LED=()        # epoch -> leader slots in the block log

# Koios is used unless env turned it off or the network has no Koios service.
glv_koios_usable() {
  [[ "${ENABLE_KOIOS:-Y}" == Y && -n "${KOIOS_API:-}" ]] &&
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

# glv_koios <path> [JSON body] [file for the response headers]: one Koios
# request, with the deployment's token when it has one. Prints the answer.
# Fails on a refused connection, an HTTP error, 10 seconds without an answer,
# and on anything that is not a JSON array, such as a proxy's error page.
glv_koios() {
  local path="$1" body="${2:-}" headers="${3:-/dev/null}" answer
  local -a arguments=(-sS -f -m 10 -D "${headers}" "${KOIOS_API_HEADERS[@]}")
  [[ -z "${body}" ]] || arguments+=(-X POST -H 'Content-Type: application/json' -d "${body}")
  [[ "${headers}" == /dev/null ]] || arguments+=(-H 'Prefer: count=exact')
  answer="$(curl "${arguments[@]}" "${KOIOS_API}/${path}" 2>/dev/null)" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<< "${answer}" || return 1
  printf '%s\n' "${answer}"
}

# glv_pool_id_find: prints the pool's ID in bech32, from POOL_ID in this
# script, the pool folder's pool.id files, or its cold verification key.
# Nothing is written to the pool folder. Returns 1 when there is no ID, and 2
# when a hex ID could not be turned into bech32 because Koios did not answer.
glv_pool_id_find() {
  local folder="${POOL_FOLDER:-}/${POOL_NAME:-}" id="${POOL_ID:-}" file answer
  local name="${POOL_ID_FILENAME:-pool.id}" vkey="${POOL_COLDKEY_VK_FILENAME:-cold.vkey}"
  if [[ -z "${id}" && -n "${POOL_NAME:-}" && "${POOL_NAME}" != CHANGE_ME ]]; then
    for file in "${folder}/${name}-bech32" "${folder}/${name}"; do
      [[ -r "${file}" ]] || continue
      read -r id < "${file}" || id=''
      [[ -z "${id}" ]] || break
    done
    if [[ -z "${id}" && -r "${folder}/${vkey}" && -n "${CCLI:-}" ]]; then
      id="$("${CCLI}" latest stake-pool id --cold-verification-key-file "${folder}/${vkey}" 2>/dev/null)" || id=''
    fi
  fi
  id="${id//[[:space:]]/}"
  if [[ "${id}" =~ ^[0-9a-fA-F]{56}$ ]]; then
    # Koios turns a hex ID into bech32, so no extra tool is needed.
    answer="$(glv_koios "pool_list?pool_id_hex=eq.${id,,}&select=pool_id_bech32")" || return 2
    id="$(jq -r '.[0].pool_id_bech32 // empty' <<< "${answer}" 2>/dev/null)"
  fi
  [[ "${id}" =~ ^pool1[02-9ac-hj-np-z]{51}$ ]] || return 1
  printf '%s\n' "${id}"
}

# glv_blocks_per_epoch <variable>: blocks an epoch holds on average, the epoch
# length times the active slot coefficient. Empty when either is unknown.
glv_blocks_per_epoch() {
  local -n _bpe_out="$1"
  local coefficient=0
  _bpe_out=''
  if ui_scale coefficient "${ACTIVE_SLOTS_COEFF:-}" 4 && (( coefficient > 0 )) && glv_is_int "${EPOCH_LENGTH:-}"; then
    _bpe_out=$((EPOCH_LENGTH * coefficient / 10000))
  fi
}

# glv_pool_job_run <epoch> <blocks per epoch>: the pool as Koios sees it, as
# "|"-separated records: id, info, a snap for each stake snapshot (next,
# current and previous epoch), blocks for the current and previous epoch,
# and ok last. A failure prints none (no pool ID), unknown (Koios does not
# know the pool) or fail, and nothing after it.
glv_pool_job_run() {
  local epoch="$1" bpe="${2:-0}" id status answer e
  [[ "${bpe}" =~ ^[0-9]+$ ]] || bpe=0
  status=0
  id="$(glv_pool_id_find)" || status=$?
  case "${status}" in
    0) ;;
    2) printf 'fail|Koios did not answer\n'; return 0 ;;
    *) printf 'none\n'; return 0 ;;
  esac
  printf 'id|%s\n' "${id}"
  answer="$(glv_koios pool_info "{\"_pool_bech32_ids\":[\"${id}\"]}")" || { printf 'fail|Koios did not answer\n'; return 0; }
  # Pool metadata is written by anyone: control characters, which could steer
  # the terminal, are blanked, and the field separator is replaced.
  jq -r '
    def clean: tostring | explode | map(if . == 124 then 47 elif . < 32 or (. >= 127 and . < 160) then 32 else . end) | implode;
    def n: if . == null then "" else tostring end;
    if length == 0 then "unknown" else .[0] |
      ["info",
       ((.meta_json.ticker? // "") | tostring | gsub("[^A-Za-z0-9]"; "") | .[0:9]),
       ((.meta_json.name? // "") | clean | .[0:60]),
       ((.pool_status // "") | clean),
       (.retiring_epoch | n),
       (.live_stake | n), (.active_stake | n), (.live_saturation | n),
       (.live_delegators | n), (.pledge | n), (.live_pledge | n),
       (.margin | n), (.fixed_cost | n), (.block_count | n)] | join("|")
    end' <<< "${answer}" 2>/dev/null || { printf 'fail|Koios gave an answer gLiveView could not read\n'; return 0; }
  # The rest is optional: without it the history starts at the settled epochs.
  if answer="$(glv_koios "pool_stake_snapshot?_pool_bech32=${id}")"; then
    jq -r --argjson bpe "${bpe}" '
      .[]? | select(.epoch_no != null) |
      ((.pool_stake // "0" | tostring | tonumber?) // 0) as $pool |
      ((.active_stake // "0" | tostring | tonumber?) // 0) as $all |
      ["snap", (.epoch_no | tostring), (.pool_stake // "" | tostring),
       (if $all > 0 and $bpe > 0 then ($pool / $all * $bpe * 100 | round | tostring) else "" end)] | join("|")
    ' <<< "${answer}" 2>/dev/null
  fi
  for e in "${epoch}" $((epoch - 1)); do
    if answer="$(glv_koios "pool_blocks?_pool_bech32=${id}&_epoch_no=${e}&select=block_height")"; then
      printf 'blocks|%s|%s\n' "${e}" "$(jq -r 'length' <<< "${answer}" 2>/dev/null)"
    fi
  done
  printf 'ok|%(%s)T|%s\n' -1 "${epoch}"
}

glv_pool_job_start() {
  local bpe
  glv_blocks_per_epoch bpe
  rm -f -- "${POOL_JOB_FILE}" "${POOL_JOB_FILE}.part"
  [[ "${POOL_STATE}" == ok || "${POOL_STATE}" == stale ]] || POOL_STATE=waiting
  (
    glv_pool_job_run "${epochnum}" "${bpe}" > "${POOL_JOB_FILE}.part" 2>/dev/null
    mv -f -- "${POOL_JOB_FILE}.part" "${POOL_JOB_FILE}"
  ) < /dev/null > /dev/null 2>&1 &
  POOL_JOB_PID=$!
}

glv_pool_job_poll() {
  [[ -n "${POOL_JOB_PID}" ]] || return 0
  if [[ ! -f "${POOL_JOB_FILE}" ]]; then
    ! kill -0 "${POOL_JOB_PID}" 2>/dev/null || return 0
    if [[ ! -f "${POOL_JOB_FILE}" ]]; then
      POOL_JOB_PID=''
      glv_pool_failed "The pool data could not be read"
      return 0
    fi
  fi
  glv_pool_load "${POOL_JOB_FILE}"
  rm -f -- "${POOL_JOB_FILE}"
  POOL_JOB_PID=''
}

# A failed request keeps the last answer, if there is one, and is retried a
# minute later.
glv_pool_failed() {
  POOL_FAILED_AT="${D_NOW:-0}"
  POOL_NOTE="$1"
  if [[ "${POOL_STATE}" == ok || "${POOL_STATE}" == stale ]]; then POOL_STATE=stale; else POOL_STATE=failed; fi
}

# glv_pool_load <file>: takes in what a pool job printed. The pool data is
# replaced only by a complete answer.
glv_pool_load() {
  local line kind id='' fetched='' epoch='' key
  local -a field=()
  local -A got_info=() got_snap=() got_blocks=()
  while IFS= read -r line; do
    IFS='|' read -r -a field <<< "${line}|"
    kind="${field[0]}"
    case "${kind}" in
      id) id="${field[1]}" ;;
      none)
        POOL_STATE=none; POOL_ID_B32=''; POOL_FETCHED_AT="${D_NOW:-0}"; POOL_EPOCH="${epochnum:-}"
        return 0 ;;
      unknown)
        POOL_STATE=unknown; POOL_ID_B32="${id}"; POOL_FETCHED_AT="${D_NOW:-0}"; POOL_EPOCH="${epochnum:-}"
        return 0 ;;
      fail)
        [[ -z "${id}" ]] || POOL_ID_B32="${id}"
        glv_pool_failed "${field[1]:-Koios did not answer}"
        return 0 ;;
      info)
        got_info=([ticker]="${field[1]}" [name]="${field[2]}" [status]="${field[3]}" [retiring]="${field[4]}"
              [live_stake]="${field[5]}" [active_stake]="${field[6]}" [saturation]="${field[7]}"
              [delegators]="${field[8]}" [pledge]="${field[9]}" [live_pledge]="${field[10]}"
              [margin]="${field[11]}" [fixed_cost]="${field[12]}" [blocks]="${field[13]}") ;;
      snap) glv_is_int "${field[1]}" && got_snap["${field[1]}"]="${field[2]}|${field[3]}" ;;
      blocks) glv_is_int "${field[1]}" && glv_is_int "${field[2]}" && got_blocks["${field[1]}"]="${field[2]}" ;;
      ok) fetched="${field[1]}"; epoch="${field[2]}" ;;
    esac
  done < "$1"
  if [[ -z "${fetched}" || ${#got_info[@]} -eq 0 ]]; then
    glv_pool_failed "The answer from Koios was incomplete"
    return 0
  fi
  POOL_ID_B32="${id}"
  POOL_INFO=(); for key in "${!got_info[@]}"; do POOL_INFO["${key}"]="${got_info[${key}]}"; done
  POOL_SNAP=(); for key in "${!got_snap[@]}"; do POOL_SNAP["${key}"]="${got_snap[${key}]}"; done
  POOL_BLOCKS=(); for key in "${!got_blocks[@]}"; do POOL_BLOCKS["${key}"]="${got_blocks[${key}]}"; done
  POOL_STATE=ok
  POOL_NOTE=''
  POOL_FETCHED_AT="${fetched}"
  POOL_FAILED_AT=0
  POOL_EPOCH="${epoch}"
}

# glv_history_job_run <pool ID> <epoch> <offset> <blocks per epoch>: one
# chunk of the pool's settled epochs, newest first: records total and row,
# then ok, or fail. Settled means the rewards are known, which Koios has from
# two epochs back; the newer ones come from the pool job.
glv_history_job_run() {
  local id="$1" epoch="$2" offset="$3" bpe="${4:-0}" headers answer total
  [[ "${bpe}" =~ ^[0-9]+$ ]] || bpe=0
  headers="${HIST_JOB_FILE}.head"
  if ! answer="$(glv_koios "pool_history?_pool_bech32=${id}&epoch_no=lt.$((epoch - 1))&order=epoch_no.desc&limit=${HIST_CHUNK}&offset=${offset}&select=epoch_no,active_stake,active_stake_pct,delegator_cnt,block_cnt,pool_fees,deleg_rewards,epoch_ros" '' "${headers}")"; then
    rm -f -- "${headers}"
    printf 'fail\n'
    return 0
  fi
  # Content-Range: 0-9/327 says how many there are in all.
  total="$(tr -d '\r' < "${headers}" 2>/dev/null | sed -n 's|^[Cc]ontent-[Rr]ange: *[^/]*/\([0-9][0-9]*\)$|\1|p')"
  rm -f -- "${headers}"
  [[ -z "${total}" ]] || printf 'total|%s\n' "${total}"
  jq -r --argjson bpe "${bpe}" --argjson offset "${offset}" '
    def n: if . == null then "" else tostring end;
    def number: (tostring | tonumber?) // null;
    to_entries[] | .key as $i | .value |
    ["row", ($offset + $i | tostring), (.epoch_no | n), (.active_stake | n),
     (if $bpe > 0 and ((.active_stake_pct | number) != null) then ((.active_stake_pct | number) * $bpe | round | tostring) else "" end),
     (.delegator_cnt | n), (.block_cnt | n), (.pool_fees | n), (.deleg_rewards | n),
     (if (.epoch_ros | number) != null then ((.epoch_ros | number) * 100 | round | tostring) else "" end)] | join("|")
  ' <<< "${answer}" 2>/dev/null || { printf 'fail\n'; return 0; }
  printf 'ok\n'
}

glv_history_job_start() {
  local bpe
  glv_blocks_per_epoch bpe
  rm -f -- "${HIST_JOB_FILE}" "${HIST_JOB_FILE}.part"
  HIST_JOB_OFFSET="$1"
  (
    glv_history_job_run "${POOL_ID_B32}" "${HIST_EPOCH}" "$1" "${bpe}" > "${HIST_JOB_FILE}.part" 2>/dev/null
    mv -f -- "${HIST_JOB_FILE}.part" "${HIST_JOB_FILE}"
  ) < /dev/null > /dev/null 2>&1 &
  HIST_JOB_PID=$!
}

glv_history_job_poll() {
  [[ -n "${HIST_JOB_PID}" ]] || return 0
  if [[ ! -f "${HIST_JOB_FILE}" ]]; then
    ! kill -0 "${HIST_JOB_PID}" 2>/dev/null || return 0
    if [[ ! -f "${HIST_JOB_FILE}" ]]; then
      HIST_JOB_PID=''
      HIST_FAILED["${HIST_JOB_OFFSET}"]="${D_NOW:-0}"
      return 0
    fi
  fi
  glv_history_load "${HIST_JOB_FILE}" "${HIST_JOB_OFFSET}"
  rm -f -- "${HIST_JOB_FILE}"
  HIST_JOB_PID=''
}

# glv_history_load <file> <chunk offset>: takes in one chunk of settled epochs.
glv_history_load() {
  local line rows=0 ok=N total=''
  local -a field=()
  while IFS= read -r line; do
    IFS='|' read -r -a field <<< "${line}|"
    case "${field[0]}" in
      total) glv_is_int "${field[1]}" && total="${field[1]}" ;;
      row)
        glv_is_int "${field[1]}" && glv_is_int "${field[2]}" || continue
        HIST_ROW["${field[1]}"]="${field[2]}|${field[3]}|${field[4]}|${field[5]}|${field[6]}|${field[7]}|${field[8]}|${field[9]}"
        (( field[1] + 1 <= HIST_KNOWN )) || HIST_KNOWN=$((field[1] + 1))
        rows=$((rows + 1)) ;;
      ok) ok=Y ;;
    esac
  done < "$1"
  if [[ "${ok}" != Y ]]; then
    HIST_FAILED["$2"]="${D_NOW:-0}"
    return 0
  fi
  HIST_LOADED["$2"]=1
  unset "HIST_FAILED[$2]"
  if [[ -n "${total}" ]]; then HIST_TOTAL="${total}"
  elif (( rows < HIST_CHUNK )); then HIST_TOTAL=$(($2 + rows)); fi
}

# Every second: takes in finished jobs, and starts the pool job when its data
# is due, every 10 minutes and as an epoch starts.
glv_pool_tick() {
  [[ -z "${POOL_JOB_PID}" ]] || glv_pool_job_poll
  [[ -z "${HIST_JOB_PID}" ]] || glv_history_job_poll
  [[ "${D_ROLE:-}" == Core ]] || return 0
  if ! glv_koios_usable; then POOL_STATE=nokoios; return 0; fi
  [[ "${POOL_STATE}" != nokoios ]] || POOL_STATE=off
  glv_is_int "${epochnum:-}" || return 0
  if [[ -z "${POOL_JOB_PID}" ]] && (( D_NOW - POOL_FAILED_AT >= 60 )); then
    if (( POOL_FETCHED_AT == 0 )) || [[ "${POOL_EPOCH}" != "${epochnum}" ]] || (( D_NOW - POOL_FETCHED_AT >= 600 )); then
      glv_pool_job_start
    fi
  fi
  (( VIEW != 4 )) || glv_history_tick
}

# Starts fetching the chunk of settled epochs the history panel shows next:
# the rows on screen and one screenful beyond them.
glv_history_tick() {
  local first last offset
  [[ -n "${POOL_ID_B32}" && ( "${POOL_STATE}" == ok || "${POOL_STATE}" == stale ) ]] || return 0
  glv_is_int "${epochnum:-}" || return 0
  # A new epoch moves every settled epoch one row down: start again.
  if [[ "${HIST_EPOCH}" != "${epochnum}" ]]; then
    HIST_ROW=(); HIST_LOADED=(); HIST_FAILED=()
    HIST_TOTAL=-1; HIST_KNOWN=0; HIST_SCROLL=0; HIST_EPOCH="${epochnum}"
  fi
  [[ -z "${HIST_JOB_PID}" ]] || return 0
  (( HIST_TOTAL != 0 )) || return 0
  first=$((HIST_SCROLL - HIST_VIRTUAL))
  (( first >= 0 )) || first=0
  last=$((first + 2 * ${POOL_HISTORY_EPOCHS:-5}))
  (( HIST_TOTAL < 0 || last < HIST_TOTAL )) || last=$((HIST_TOTAL - 1))
  for ((offset = first - first % HIST_CHUNK; offset <= last; offset += HIST_CHUNK)); do
    [[ -z "${HIST_LOADED[${offset}]+set}" ]] || continue
    (( D_NOW - ${HIST_FAILED[${offset}]:-0} >= 60 )) || continue
    glv_history_job_start "${offset}"
    return 0
  done
}

# glv_history_rows <rows>: the epochs the history panel shows, from
# HIST_SCROLL, in HIST_VIEW as "kind|epoch|stake|delegators|led|blocks|ideal
# hundredths|fees|rewards|ROS hundredths". Kind is next, now or previous for
# the newest epochs, which come from the pool job, settled for Koios's pool
# history, and loading or failed for a row that is not there yet.
glv_history_rows() {
  local count="$1" index offset e kind stake ideal deleg blocks fees rewards ros mine limit
  local -a virtual=()
  HIST_VIEW=()
  HIST_SHOWN="${count}"
  glv_is_int "${epochnum:-}" || return 0
  for e in $((epochnum + 1)) "${epochnum}" $((epochnum - 1)); do
    [[ -z "${POOL_SNAP[${e}]+set}${POOL_BLOCKS[${e}]+set}" ]] || virtual+=("${e}")
  done
  HIST_VIRTUAL=${#virtual[@]}
  if (( HIST_TOTAL >= 0 )); then HIST_ROWS_TOTAL=$((HIST_VIRTUAL + HIST_TOTAL))
  else HIST_ROWS_TOTAL=$((HIST_VIRTUAL + HIST_KNOWN + 1)); fi
  limit=$((HIST_ROWS_TOTAL - count))
  (( limit >= 0 )) || limit=0
  (( HIST_SCROLL <= limit )) || HIST_SCROLL="${limit}"
  (( HIST_SCROLL >= 0 )) || HIST_SCROLL=0
  for ((index = HIST_SCROLL; index < HIST_SCROLL + count && index < HIST_ROWS_TOTAL; index++)); do
    if (( index < HIST_VIRTUAL )); then
      e="${virtual[index]}"
      if (( e > epochnum )); then kind=next; elif (( e == epochnum )); then kind=now; else kind=previous; fi
      stake="${POOL_SNAP[${e}]:-|}"
      ideal="${stake#*|}"; stake="${stake%%|*}"
      blocks="${POOL_BLOCKS[${e}]:-}"
      # The block log knows this epoch's blocks before Koios does.
      if [[ "${kind}" == now && "${D_SCHEDULE_EPOCH:-}" == "${epochnum}" ]]; then
        mine=$(( ${D_STATUS[adopted]:-0} + ${D_STATUS[confirmed]:-0} ))
        if ! glv_is_int "${blocks}" || (( mine > blocks )); then blocks="${mine}"; fi
      fi
      HIST_VIEW+=("${kind}|${e}|${stake}||${D_LED[${e}]:-}|${blocks}|${ideal}|||")
    else
      offset=$((index - HIST_VIRTUAL))
      if [[ -n "${HIST_ROW[${offset}]+set}" ]]; then
        IFS='|' read -r e stake ideal deleg blocks fees rewards ros <<< "${HIST_ROW[${offset}]}"
        HIST_VIEW+=("settled|${e}|${stake}|${deleg}|${D_LED[${e}]:-}|${blocks}|${ideal}|${fees}|${rewards}|${ros}")
      elif (( ${D_NOW:-0} - ${HIST_FAILED[$((offset - offset % HIST_CHUNK))]:-0} < 60 )); then
        HIST_VIEW+=("failed|")
      else
        HIST_VIEW+=("loading|")
      fi
    fi
  done
}

# glv_ada_short <variable> <lovelace>: 22412345678901 -> "22.41 M".
glv_ada_short() {
  local -n _ada_short="$1"
  local lovelace="$2" whole
  if ! [[ "${lovelace}" =~ ^[0-9]+$ ]]; then _ada_short='—'; return 0; fi
  if (( lovelace >= 1000000000000000 )); then
    printf -v _ada_short '%d.%02d B' $((lovelace / 1000000000000000)) $((lovelace % 1000000000000000 / 10000000000000))
  elif (( lovelace >= 1000000000000 )); then
    printf -v _ada_short '%d.%02d M' $((lovelace / 1000000000000)) $((lovelace % 1000000000000 / 10000000000))
  elif (( lovelace >= 10000000000 )); then
    printf -v _ada_short '%d k' $((lovelace / 1000000000))
  elif (( lovelace >= 1000000000 )); then
    printf -v _ada_short '%d.%d k' $((lovelace / 1000000000)) $((lovelace % 1000000000 / 100000000))
  else
    ui_fmt_int whole $((lovelace / 1000000))
    _ada_short="${whole}"
  fi
}

# glv_ada_int <variable> <lovelace>: 10184123456 -> "10,184 ₳".
glv_ada_int() {
  local -n _ada_int="$1"
  local whole
  if ! [[ "$2" =~ ^[0-9]+$ ]]; then _ada_int='—'; return 0; fi
  ui_fmt_int whole $(($2 / 1000000))
  _ada_int="${whole} ₳"
}

# glv_pool_vital <text> <colour>: the rail's Pool line. Red when the live
# pledge is below the pledge, which costs the epoch's rewards, or the pool
# has retired; amber while it is retiring or over-saturated. Empty without
# pool data.
glv_pool_vital() {
  local -n _pool_text="$1" _pool_colour="$2"
  local saturation=0 value
  _pool_text=''
  _pool_colour="${C_OK}"
  [[ "${POOL_STATE}" == ok || "${POOL_STATE}" == stale ]] || return 0
  ui_scale saturation "${POOL_INFO[saturation]:-}" 1 || saturation=0
  ui_fmt_tenths value "${saturation}"
  _pool_text="${POOL_INFO[ticker]:-pool} · ${value} %"
  if glv_is_int "${POOL_INFO[pledge]:-}" && glv_is_int "${POOL_INFO[live_pledge]:-}" &&
     (( ${POOL_INFO[live_pledge]} < ${POOL_INFO[pledge]} )); then
    _pool_text="pledge not met"; _pool_colour="${C_DANGER}"
  elif [[ "${POOL_INFO[status]:-}" == retired ]]; then
    _pool_text="retired"; _pool_colour="${C_DANGER}"
  elif glv_is_int "${POOL_INFO[retiring]:-}"; then
    _pool_text="retiring ${POOL_INFO[retiring]}"; _pool_colour="${C_WARN}"
  elif (( saturation >= 1000 )); then
    _pool_colour="${C_WARN}"
  fi
}

# What only the page on screen needs.
glv_data_view() {
  case "${VIEW:-1}" in
    7) glv_data_startup; glv_data_binary; glv_params_job_start; glv_params_job_poll ;;
    # The Keys panel's BLS row needs the protocol version on a cnode producer.
    4) if [[ "${D_ROLE:-}" == Core && "${NODE_IMPLEMENTATION:-cnode}" == cnode ]]; then glv_params_job_start; glv_params_job_poll; fi ;;
    3) glv_data_peers; glv_peers_job_poll ;;
    5) glv_data_system ;;
    6) glv_data_logs ;;
  esac
}

glv_data_collect() {
  local start="${EPOCHREALTIME/[.,]/}" was_ok="${D_OK}" role=Relay alert=''
  printf -v D_COLLECTED_AT '%(%s)T' -1

  if getNodeMetrics 2>/dev/null; then
    D_OK=Y
    D_FAILS=0
  else
    # The failed collector has already reset availability; this only gives the
    # arithmetic-facing variables safe defaults.
    common_parse_cardano_metrics "" 2>/dev/null
    D_OK=N
    D_FAILS=$((D_FAILS + 1))
  fi
  node_refresh_process >/dev/null 2>&1 || true
  D_PID="${NODE_PID:-}"
  D_DOWN=''
  if [[ -z "${D_PID}" ]]; then
    # Without a process, whatever answered on the metrics port is not this
    # node (another deployment may share the port), so nothing is shown.
    if [[ "${D_OK}" == Y ]]; then
      node_metric_reset_availability
      common_parse_cardano_metrics "" 2>/dev/null
    fi
    D_OK=N
    D_DOWN="not running"
  elif [[ "${D_OK}" != Y ]]; then
    D_DOWN="no metrics"
  fi

  if [[ "${D_OK}" != "${was_ok}" ]]; then
    if [[ "${D_OK}" == Y ]]; then
      (( D_SLOW_AT == 0 )) || glv_data_event "node back" "${D_IMPL}"
    else
      glv_data_event "node lost" "${D_IMPL} ${D_DOWN}"
    fi
  fi

  if [[ "${D_OK}" == Y ]]; then
    node_metric_has running_node_version && D_VERSION="${running_node_version}"
    if [[ "${NODE_IMPLEMENTATION:-}" == cnode ]] && ! glv_is_int "${SHELLEY_TRANS_EPOCH:-}"; then
      getShelleyTransitionEpoch >/dev/null 2>&1 || true
    fi
    if node_has forge && node_metric_has forging_enabled && [[ "${forging_enabled}" == 1 ]]; then
      role=Core
    fi
    if [[ "${role}" != "${D_ROLE}" ]]; then
      D_ROLE="${role}"
      D_SLOW_AT=0
      D_KES_AT=0
      [[ "${role}" != Core ]] || glv_data_opcert
    fi
    if node_metric_has opcert_counter_disk; then D_OPCERT_DISK="${opcert_counter_disk}"; fi
    if node_metric_has opcert_counter_chain; then D_OPCERT_CHAIN="${opcert_counter_chain}"; fi
    if node_metric_has node_alert; then alert="${node_alert}"; fi
    if [[ "${alert}" != "${D_LAST_ALERT}" ]]; then
      [[ -z "${alert}" ]] || glv_data_event "alert" "${alert}"
      D_LAST_ALERT="${alert}"
    fi
    glv_data_blocks
    glv_data_big_ledger
    glv_data_watch
  fi

  glv_data_cpu
  glv_data_process_cpu
  glv_data_memory
  # Slower sources: the disk, the leader schedule and the KES expiry date.
  if (( D_COLLECTED_AT - D_SLOW_AT >= 30 )); then
    D_SLOW_AT="${D_COLLECTED_AT}"
    glv_data_disk
    if [[ "${D_ROLE}" == Core ]]; then glv_data_blocklog; fi
  fi
  if [[ "${D_ROLE}" == Core ]] && (( D_COLLECTED_AT - D_KES_AT >= 60 )); then
    D_KES_AT="${D_COLLECTED_AT}"
    glv_data_kes
  fi

  glv_data_view
  D_COLLECT_MS=$(( (${EPOCHREALTIME/[.,]/} - start) / 1000 ))
  glv_data_clock
}

# The wall-clock slot, as env's getSlotTipRef works it out, without a subshell.
glv_data_reference_slot() {
  local -n _reference_out="$1"
  local byron_slots byron_end name
  _reference_out=''
  for name in SHELLEY_TRANS_EPOCH BYRON_EPOCH_LENGTH BYRON_SLOT_LENGTH \
      BYRON_GENESIS_START_SEC SLOT_LENGTH; do
    glv_is_int "${!name:-}" || return 1
  done
  (( SLOT_LENGTH > 0 && BYRON_SLOT_LENGTH > 0 )) || return 1
  byron_slots=$((SHELLEY_TRANS_EPOCH * BYRON_EPOCH_LENGTH))
  byron_end=$((BYRON_GENESIS_START_SEC + byron_slots * BYRON_SLOT_LENGTH / 1000))
  if (( D_NOW < byron_end )); then
    _reference_out=$(((D_NOW - BYRON_GENESIS_START_SEC) * 1000 / BYRON_SLOT_LENGTH))
  else
    _reference_out=$((byron_slots + (D_NOW - byron_end) / SLOT_LENGTH))
  fi
}

glv_data_clock() {
  local reference='' native byron_end epoch_now
  printf -v D_NOW '%(%s)T' -1
  # A finished peer analysis shows up within a second, not at the next collection.
  [[ -z "${PEER_JOB_PID:-}" ]] || glv_peers_job_poll
  [[ -z "${PARAMS_JOB_PID:-}" ]] || glv_params_job_poll
  glv_pool_tick

  D_UPTIME=''
  if node_metric_has uptimes && glv_is_int "${uptimes:-}"; then
    D_UPTIME=$((uptimes + D_NOW - D_COLLECTED_AT))
  fi

  # A gap the node reports itself wins; otherwise compare with the wall clock.
  D_TIP_GAP=''
  glv_data_reference_slot reference || reference=''
  if node_metric_has tip_gap && ui_scale native "${tip_gap:-}" 0; then
    (( native >= 0 )) || native=0
    D_TIP_GAP="${native}"
  elif [[ -n "${reference}" ]] && node_metric_has slotnum && glv_is_int "${slotnum:-}"; then
    D_TIP_GAP=$((reference - slotnum))
    (( D_TIP_GAP >= 0 )) || D_TIP_GAP=0
  fi

  D_EPOCH_LEFT=''
  if [[ -n "${reference}" ]] && glv_is_int "${EPOCH_LENGTH:-}" && (( EPOCH_LENGTH > 0 )); then
    byron_end=$((BYRON_GENESIS_START_SEC + SHELLEY_TRANS_EPOCH * BYRON_EPOCH_LENGTH * BYRON_SLOT_LENGTH / 1000))
    if (( D_NOW >= byron_end )); then
      epoch_now=$(((D_NOW - byron_end) / SLOT_LENGTH / EPOCH_LENGTH))
      D_EPOCH_LEFT=$((byron_end + (epoch_now + 1) * SLOT_LENGTH * EPOCH_LENGTH - D_NOW))
    fi
  fi
  if [[ -z "${D_EPOCH_LEFT}" ]] && node_metric_has slot_in_epoch &&
     glv_is_int "${slot_in_epoch:-}" && glv_is_int "${EPOCH_LENGTH:-}" &&
     glv_is_int "${SLOT_LENGTH:-}"; then
    D_EPOCH_LEFT=$(((EPOCH_LENGTH - slot_in_epoch) * SLOT_LENGTH))
  fi

  D_NEXT_IN=''
  if glv_is_int "${D_NEXT_AT}"; then
    D_NEXT_IN=$((D_NEXT_AT - D_NOW))
    # The slot has passed: ask the schedule again on the next collection.
    (( D_NEXT_IN >= 0 )) || { D_NEXT_IN=''; D_NEXT_AT=''; D_SLOW_AT=0; }
  fi
}

##############################################################################
# Views: the rail, the overview panels and the layouts for each terminal size
##############################################################################
# The rail, the panels and the page layouts for each terminal size. Everything is
# availability driven: a panel shows what the node's adapter reported and
# leaves out what it did not, so one layout serves cardano-node, Amaru and
# Dingo.
#
# Layouts by terminal width (rows shorter than a layout needs drop panels from
# the bottom of the page first):
#   wide      150+     full rail, four tiles in a row, events beside blocks
#   standard  110-149  full rail, tiles two by two
#   compact   80-109   rail of view numbers, one stacked column
#   mini      34-79    the rail alone
#   small     below 34 x 16: a request to enlarge the terminal

GLV_MIN_COLS=34
GLV_MIN_ROWS=16
GLV_RAIL_W=26
GLV_SLIM_W=5

VIEW=1
VIEW_KEYS=('' 1 2 3 4 5 6 n)
VIEW_NAMES=('' Overview Chain Peers Production System Logs "Node & network")

glv_layout_class() {
  if (( COLS < GLV_MIN_COLS || ROWS < GLV_MIN_ROWS )); then LAYOUT=small
  elif (( COLS < 80 )); then LAYOUT=mini
  elif (( COLS < 110 )); then LAYOUT=compact
  elif (( COLS < 150 )); then LAYOUT=standard
  else LAYOUT=wide; fi
}

# ── cells ────────────────────────────────────────────────────────────────────
# glv_cell <array> <label> <value> [colour variable]
glv_cell() {
  local -n _cell_list="$1"
  [[ -n "${3:-}" ]] || return 0
  _cell_list+=("$2|$3|${4:-}")
}

# glv_metric_cell <array> <metric> <label> [int|compact|bytes|percent|raw] [colour variable]
# Adds the cell only when the adapter reported the metric.
glv_metric_cell() {
  local metric="$2" format="${4:-int}" value text scaled
  node_metric_has "${metric}" || return 0
  value="${!metric:-}"
  case "${format}" in
    int) ui_scale scaled "${value}" 0 && ui_fmt_int text "${scaled}" || text="${value}" ;;
    compact) ui_scale scaled "${value}" 0 && ui_fmt_compact text "${scaled}" || text="${value}" ;;
    bytes) ui_scale scaled "${value}" 0 && ui_fmt_bytes text "${scaled}" || text="${value}" ;;
    percent) ui_scale scaled "${value}" 2 && text="$((scaled / 100)).$((scaled % 100 / 10))$((scaled % 10)) %" || text="${value}" ;;
    *) text="${value}" ;;
  esac
  glv_cell "$1" "$3" "${text}" "${5:-}"
}

# glv_slots <variable> <count>: "1 slot", "1,204 slots".
glv_slots() {
  local -n _slots_out="$1"
  ui_fmt_int _slots_out "$2"
  if [[ "$2" == 1 ]]; then _slots_out+=" slot"; else _slots_out+=" slots"; fi
}

# The one-line verdict used by the compact header and the mini layout.
glv_status() {
  local -n _status_text="$1" _status_colour="$2"
  local gap
  if [[ "${D_OK}" != Y ]]; then
    _status_text="${D_DOWN:-No metrics}"; _status_colour="${C_DANGER}"
  elif node_metric_has node_alert && [[ -n "${node_alert:-}" ]]; then
    _status_text="Alert"; _status_colour="${C_DANGER}"
  elif node_metric_has sync_phase && [[ -n "${sync_phase:-}" ]]; then
    _status_text="Syncing"; _status_colour="${C_WARN}"
  elif [[ -n "${D_TIP_GAP}" ]] && (( D_TIP_GAP > 120 )); then
    glv_slots gap "${D_TIP_GAP}"
    _status_text="${gap} behind"; _status_colour="${C_WARN}"
  else
    _status_text="In sync"; _status_colour="${C_OK}"
  fi
}

glv_gap_colour() {
  local -n _gap_out="$1"
  if [[ -z "${D_TIP_GAP}" ]]; then _gap_out=C_MUTED
  elif (( D_TIP_GAP <= 120 )); then _gap_out=C_OK
  elif (( D_TIP_GAP <= 600 )); then _gap_out=C_WARN
  else _gap_out=C_DANGER; fi
}

glv_kes_colour() {
  local -n _kes_out="$1"
  local remaining
  _kes_out=C_OK
  ui_scale remaining "${remaining_kes_periods:-0}" 0 || return 0
  if (( remaining <= 5 )); then _kes_out=C_DANGER
  elif (( remaining <= 15 )); then _kes_out=C_WARN; fi
}

# The BLS key a cardano-node producer votes with in the Dijkstra era (Leios
# committee). "set" when the node runs with --shelley-bls-key; "not set" only
# when the protocol parameters show protocol 12 or later; empty otherwise, so
# Conway-era networks and other nodes show no row.
glv_bls_text() {
  local -n _bls_text="$1" _bls_colour="$2"
  local _bls_args='' _bls_row=''
  _bls_text=''
  _bls_colour=''
  [[ "${NODE_IMPLEMENTATION:-cnode}" == cnode && -n "${D_PID:-}" && -r "/proc/${D_PID}/cmdline" ]] || return 0
  _bls_args="$(tr '\0' ' ' < "/proc/${D_PID}/cmdline" 2>/dev/null)" || return 0
  if [[ " ${_bls_args} " == *" --shelley-bls-key "* ]]; then
    _bls_text='set · Leios votes'
    _bls_colour=C_OK
    return 0
  fi
  for _bls_row in "${D_PARAMS[@]}"; do
    [[ "${_bls_row}" == "Network|Protocol version|"* ]] || continue
    _bls_row="${_bls_row##*|}"; _bls_row="${_bls_row%%.*}"
    if glv_is_int "${_bls_row}" && (( _bls_row >= 12 )); then
      _bls_text='not set · no Leios votes'
      _bls_colour=C_WARN
    fi
  done
}

# "7 · 7 ✓": the certificate on disk must match the chain or be one ahead.
glv_opcert_text() {
  local -n _opcert_text="$1" _opcert_colour="$2"
  _opcert_text=''
  _opcert_colour=''
  [[ -n "${D_OPCERT_DISK}${D_OPCERT_CHAIN}" ]] || return 0
  _opcert_text="${D_OPCERT_DISK:-?} · ${D_OPCERT_CHAIN:-?}"
  if glv_is_int "${D_OPCERT_DISK}" && glv_is_int "${D_OPCERT_CHAIN}"; then
    if (( D_OPCERT_DISK == D_OPCERT_CHAIN || D_OPCERT_DISK == D_OPCERT_CHAIN + 1 )); then
      _opcert_text+=" ✓"; _opcert_colour=C_OK
    else
      _opcert_text+=" ✗"; _opcert_colour=C_DANGER
    fi
  fi
}

# ── panels ───────────────────────────────────────────────────────────────────
# Each builder leaves a finished box in P_<NAME>.

# glv_panel_epoch <width> [title prefix]. Three rows without a second line,
# four with one (sync status, or the leader slots of this epoch).
glv_panel_epoch() {
  local width="$1" prefix="${2:-}" inner=$(($1 - 4)) title right='' filled=0
  local slot length left tenths text entry position status colour i
  local -a glyph=() tint=()
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  title="${prefix}Epoch"
  if node_metric_has epochnum && node_metric_has slot_in_epoch &&
     glv_is_int "${slot_in_epoch:-}" && glv_is_int "${EPOCH_LENGTH:-}" && (( EPOCH_LENGTH > 0 )); then
    title="${prefix}Epoch ${epochnum}"
    filled=$((inner * slot_in_epoch / EPOCH_LENGTH))
    tenths=$((slot_in_epoch * 1000 / EPOCH_LENGTH))
    ui_fmt_int slot "${slot_in_epoch}"
    ui_fmt_int length "${EPOCH_LENGTH}"
    right="$((tenths / 10)).$((tenths % 10)) %"
    left=''
    if [[ -n "${D_EPOCH_LEFT}" ]]; then
      ui_fmt_duration left "${D_EPOCH_LEFT}"
      left=" · ${left} left"
    fi
    # The slot count is the first thing to go when the border is short.
    if (( ${#title} + ${#right} + ${#slot} + ${#length} + ${#left} + 15 <= width )); then
      right+=" · ${slot} / ${length}"
    fi
    right+="${left}"
    ui_bar "${inner}" "${filled}" UI_BLOCKS "${C_ACCENT}"
  elif [[ "${D_OK}" == Y ]]; then
    ui_putw "${C_MUTED}" "${inner}" "${D_IMPL} has not reported an epoch yet."
  else
    ui_putw "${C_DANGER}" "${inner}" "${D_IMPL}: ${D_DOWN:-no metrics}. Trying again every ${REFRESH_RATE} s."
  fi
  ui_endl UI_BODY "${inner}"

  if node_metric_has node_alert && [[ -n "${node_alert:-}" ]]; then
    ui_putw "${C_DANGER}" "${inner}" "Alert: ${node_alert}"
    ui_endl UI_BODY "${inner}"
  elif node_metric_has sync_phase && [[ -n "${sync_phase:-}" ]]; then
    text="Sync: ${sync_phase}"
    if node_metric_has sync_progress; then text+=" · ${sync_progress} %"; fi
    if node_metric_has sync_rate && [[ -n "${sync_rate:-}" ]]; then text+=" · ${sync_rate}"; fi
    ui_putw "${C_WARN}" "${inner}" "${text}"
    ui_endl UI_BODY "${inner}"
  elif (( ${#D_SCHEDULE[@]} > 0 )) && [[ "${D_SCHEDULE_EPOCH}" == "${epochnum:-}" ]] &&
       glv_is_int "${slot_in_epoch:-}" && glv_is_int "${EPOCH_LENGTH:-}" && (( EPOCH_LENGTH > 0 )); then
    # One mark per leader slot, placed where the slot falls on the bar.
    for entry in "${D_SCHEDULE[@]}"; do
      status="${entry#*|}"
      status="${status%%|*}"
      glv_is_int "${entry%%|*}" || continue
      position=$((inner * ${entry%%|*} / EPOCH_LENGTH))
      (( position < inner )) || position=$((inner - 1))
      case "${status}" in
        adopted|confirmed) colour="${C_OK}" ;;
        leader)
          if (( ${entry%%|*} >= slot_in_epoch )); then colour="${C_ACCENT}"
          elif [[ "${D_RESULTS}" == Y ]]; then colour="${C_WARN}"
          else colour="${C_MUTED}"; fi ;;
        *) colour="${C_DANGER}" ;;
      esac
      glyph[position]='▲'
      tint[position]="${colour}"
    done
    for ((i = 0; i < inner; i++)); do
      if [[ -n "${glyph[i]:-}" ]]; then UI_L+="${tint[i]}▲${UI_BASE}"; else UI_L+=' '; fi
    done
    UI_LW="${inner}"
    ui_endl UI_BODY "${inner}"
  fi
  UI_HELP=epoch
  ui_panel P_EPOCH "${width}" $((${#UI_BODY[@]} + 2)) "${title}" "${right}"
}

glv_chain_cells() {
  local colour value
  glv_metric_cell "$1" blocknum "Block" int UI_BOLD
  glv_metric_cell "$1" slotnum "Slot"
  if [[ -n "${D_TIP_GAP}" ]]; then
    glv_gap_colour colour
    glv_slots value "${D_TIP_GAP}"
    glv_cell "$1" "Tip gap" "${value}" "${colour}"
  fi
  glv_metric_cell "$1" slot_in_epoch "Epoch slot"
  if node_metric_has density; then glv_cell "$1" "Density" "${density} %"; fi
  glv_metric_cell "$1" forks "Forks"
  glv_metric_cell "$1" mempool_tx "Pending tx"
  glv_metric_cell "$1" mempool_bytes "Mempool" bytes
  glv_metric_cell "$1" tx_processed "Total tx" compact
}

# glv_panel_chain <width> <columns> <rows>
glv_panel_chain() {
  local width="$1" inner=$(($1 - 4))
  local -a cells=()
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  glv_chain_cells cells
  if (( ${#cells[@]} == 0 )); then
    ui_put "${C_MUTED}" "No chain metrics yet."
    ui_endl UI_BODY "${inner}"
  else
    ui_grid cells "$2" "$3" "${inner}" UI_BODY
  fi
  UI_HELP=chain
  ui_panel P_CHAIN "${width}" $(($3 + 2)) "Chain" ""
}

# The implementation's own metrics (Amaru's pipeline timings, Dingo's sync
# figures), as many as fit in <rows>.
glv_custom_rows() {
  local inner="$1" rows="$2" name value
  local -a cells=()
  for name in "${NODE_CUSTOM_METRICS[@]}"; do
    node_metric_has "${name}" || continue
    value="${!name:-}"
    [[ -z "${NODE_METRIC_UNIT[${name}]:-}" ]] || value+=" ${NODE_METRIC_UNIT[${name}]}"
    glv_cell cells "${NODE_METRIC_LABEL[${name}]:-${name}}" "${value}"
  done
  (( ${#cells[@]} > 0 && rows > 0 )) || return 0
  ui_grid cells 2 "${rows}" "${inner}" UI_BODY
}

glv_panel_propagation() {
  local width="$1" inner=$(($1 - 4)) cell third count=${#H_DELAY[@]}
  local delay last slowest=0 colour value i scaled right='' title="Propagation"
  local -a cells=()
  cell=$(((inner - 2) / 2))
  third=$((inner / 3))
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()

  if node_metric_has block_delay && ui_scale last "${block_delay}" 3; then
    ui_delay_colour colour "${last}"
    ui_fmt_delay value "${last}"
    # A narrow tile gives each figure its own row.
    (( inner >= 38 )) || cell="${inner}"
    ui_kv "${cell}" "Last block" "${UI_BOLD}${colour}" "${value}"
    if (( count > 0 )); then
      for delay in "${H_DELAY[@]}"; do (( delay <= slowest )) || slowest="${delay}"; done
      ui_delay_colour colour "${slowest}"
      ui_fmt_delay value "${slowest}"
      if (( inner >= 38 )); then ui_gap 2; else ui_endl UI_BODY "${inner}"; fi
      ui_kv "${cell}" "Slowest" "${colour}" "${value}"
      right="${count} blocks"
      (( count != 1 )) || right="1 block"
    fi
    ui_endl UI_BODY "${inner}"
    # One colour per sample, so the slow blocks stand out in the row.
    for ((i = (count > inner ? count - inner : 0); i < count; i++)); do
      delay="${H_DELAY[i]}"
      ui_delay_colour colour "${delay}"
      (( delay > 1000 )) || colour="${C_ACCENT}"
      delay=$((delay / 700))
      (( delay <= 7 )) || delay=7
      UI_L+="${colour}${UI_SPARK[delay]}"
      UI_LW=$((UI_LW + 1))
    done
    if (( count == 0 )); then ui_putw "${C_MUTED}" "${inner}" "History builds with new blocks."; else UI_L+="${UI_BASE}"; fi
    ui_endl UI_BODY "${inner}"
  fi

  if node_metric_has blocks_w1s; then
    for i in 1 3 5; do
      case "${i}" in
        1) value="${blocks_w1s:-}" ;;
        3) value="${blocks_w3s:-}" ;;
        *) value="${blocks_w5s:-}" ;;
      esac
      ui_scale scaled "${value}" 3 || scaled=0
      ui_put "${C_MUTED}" "≤${i}s"
      if (( third >= 12 )); then
        ui_putw '' $((third - 3)) " $((scaled / 10)).$((scaled % 10)) %"
      else
        ui_putw '' $((third - 3)) " $((scaled / 10))%"
      fi
    done
    ui_endl UI_BODY "${inner}"
  fi
  glv_metric_cell cells blocks_late "Late"
  glv_metric_cell cells blocks_served "Served"
  if (( ${#cells[@]} > 0 )); then ui_grid cells 2 1 "${inner}" UI_BODY; fi

  # A node without propagation figures gives the tile to its own metrics.
  if (( ${#UI_BODY[@]} == 0 )); then title="${D_IMPL} metrics"; fi
  glv_custom_rows "${inner}" $((5 - ${#UI_BODY[@]}))
  if (( ${#UI_BODY[@]} == 0 )); then
    title="Propagation"
    ui_putw "${C_MUTED}" "${inner}" "No propagation figures from ${D_IMPL}."
    ui_endl UI_BODY "${inner}"
  fi
  UI_HELP=propagation
  ui_panel P_PROP "${width}" 7 "${title}" "${right}"
}

glv_panel_peers() {
  local width="$1" inner=$(($1 - 4)) column text
  local -a cells=()
  column=$(((inner - 10) / 3))
  (( column <= 10 )) || column=10
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  if node_metric_has peer_selection_hot; then
    # Peers by how they are used. Outgoing plus big ledger are the peers this
    # node chose; incoming are the peers that chose it.
    ui_gap 10
    ui_putw "${C_MUTED}" "${column}" "hot" r
    ui_putw "${C_MUTED}" "${column}" "warm" r
    ui_putw "${C_MUTED}" "${column}" "cold" r; ui_endl UI_BODY "${inner}"
    ui_putw "${C_MUTED}" 10 "Outgoing"
    ui_putw '' "${column}" "${peer_selection_hot}" r
    ui_putw '' "${column}" "${peer_selection_warm:-—}" r
    ui_putw '' "${column}" "${peer_selection_cold:-—}" r; ui_endl UI_BODY "${inner}"
    if [[ -n "${D_BIG_HOT}" ]]; then
      ui_putw "${C_MUTED}" 10 "Big ledger"
      ui_putw '' "${column}" "${D_BIG_HOT}" r
      ui_putw '' "${column}" "${D_BIG_WARM:-—}" r
      ui_putw '' "${column}" "${D_BIG_COLD:-—}" r; ui_endl UI_BODY "${inner}"
    fi
    if node_metric_has inbound_governor_hot; then
      ui_putw "${C_MUTED}" 10 "Incoming"
      ui_putw '' "${column}" "${inbound_governor_hot}" r
      ui_putw '' "${column}" "${inbound_governor_warm:-—}" r
      ui_putw "${C_MUTED}" "${column}" "—" r; ui_endl UI_BODY "${inner}"
    fi
    if node_metric_has conn_outgoing && node_metric_has conn_incoming; then
      # The same peers counted as connections, in the longest form that fits.
      text="${conn_outgoing} out · ${conn_incoming} in"
      if node_metric_has conn_duplex && (( ${#text} + ${#conn_duplex} + 8 <= inner - 10 )); then
        text+=" · ${conn_duplex} both"
      fi
      ui_putw "${C_MUTED}" 10 "Conns"
      ui_putw '' $((inner - 10)) "${text}"; ui_endl UI_BODY "${inner}"
    fi
  else
    glv_metric_cell cells peer_active "Active"
    glv_metric_cell cells peer_established "Established"
    glv_metric_cell cells peer_known "Known"
    glv_metric_cell cells conn_outgoing "Outgoing"
    glv_metric_cell cells conn_incoming "Incoming"
    glv_metric_cell cells conn_total "Connections"
    if (( ${#cells[@]} > 0 )); then
      ui_grid cells 2 3 "${inner}" UI_BODY
    else
      ui_putw "${C_MUTED}" "${inner}" "No peer counters from ${D_IMPL}."
      ui_endl UI_BODY "${inner}"
    fi
  fi
  UI_HELP=peers
  ui_panel P_PEERS "${width}" 7 "Peers" ""
}

glv_panel_resources() {
  local width="$1" inner=$(($1 - 4)) spark value text peak sample
  spark=$((inner - 21))
  (( spark <= 30 )) || spark=30
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  ui_fmt_tenths value "${D_CPU}"
  ui_putw "${C_MUTED}" 10 "CPU (sys)"; ui_putw '' 9 "${value} %" r; ui_gap 2
  ui_spark H_CPU "${spark}" "${C_ACCENT}" 1000; ui_endl UI_BODY "${inner}"
  if [[ -n "${D_PCPU}" ]]; then
    # One core is the full bar; a node using more just stays at the top.
    ui_fmt_tenths value "${D_PCPU}"
    ui_putw "${C_MUTED}" 10 "CPU (node)"; ui_putw '' 9 "${value} %" r; ui_gap 2
    ui_spark H_PCPU "${spark}" "${C_ACCENT}" 1000; ui_endl UI_BODY "${inner}"
  fi
  if [[ -n "${D_MEM}" ]]; then
    ui_fmt_tenths value "${D_MEM}"
    peak=1
    for sample in "${H_MEM[@]}"; do (( sample <= peak )) || peak="${sample}"; done
    ui_putw "${C_MUTED}" 10 "Mem (RSS)"; ui_putw '' 9 "${value} GiB" r; ui_gap 2
    ui_spark H_MEM "${spark}" "${C_ACCENT}" "${peak}"; ui_endl UI_BODY "${inner}"
  fi
  if node_metric_has mem_live && ui_scale sample "${mem_live}" 0; then
    ui_fmt_bytes text "${sample}"
    ui_putw "${C_MUTED}" 10 "Live"; ui_putw '' 9 "${text}" r
    if (( spark >= 14 )) && node_metric_has mem_heap && ui_scale sample "${mem_heap}" 0; then
      ui_fmt_bytes text "${sample}"
      ui_gap 2
      ui_put "${C_MUTED}" "heap "; ui_put '' "${text}"
    fi
    ui_endl UI_BODY "${inner}"
  fi
  if [[ -n "${D_DISK}" ]]; then
    ui_putw "${C_MUTED}" 10 "Disk util"; ui_putw '' 9 "${D_DISK} %" r; ui_gap 2
    ui_bar "${spark}" $((spark * D_DISK / 100)) UI_HEAVY "${C_ACCENT}"
    ui_endl UI_BODY "${inner}"
  fi
  if node_metric_has open_files; then
    ui_putw "${C_MUTED}" 10 "Open files"; ui_putw '' 9 "${open_files}" r
    if node_metric_has max_files && ui_scale sample "${max_files}" 0; then
      ui_fmt_int text "${sample}"
      ui_gap 2
      ui_putw "${C_MUTED}" $((inner - 21)) "of ${text}"
    fi
    ui_endl UI_BODY "${inner}"
  fi
  UI_HELP=resources
  ui_panel P_RES "${width}" 7 "Resources" ""
}

# glv_schedule_split <passed variable> <to come variable>: this epoch's leader
# slots that have passed and that are still to come, by the wall clock. The
# locals carry a prefix because the results are written through namerefs.
glv_schedule_split() {
  local -n _split_passed="$1" _split_coming="$2"
  local _split_entry _split_at
  _split_passed=0
  _split_coming=0
  for _split_entry in "${D_SCHEDULE[@]}"; do
    _split_at="${_split_entry#*|}"; _split_at="${_split_at#*|}"; _split_at="${_split_at%%|*}"
    if glv_is_int "${_split_at}" && (( _split_at > D_NOW )); then
      _split_coming=$((_split_coming + 1))
    else
      _split_passed=$((_split_passed + 1))
    fi
  done
}

glv_production_cells() {
  local colour text total lost passed coming value
  if [[ -n "${D_SCHEDULE_EPOCH}" ]]; then
    total="${D_STATUS[total]:-0}"
    glv_cell "$1" "Leader" "${total}"
    glv_cell "$1" "Ideal" "${D_IDEAL}"
    [[ -z "${D_LUCK}" ]] || glv_cell "$1" "Luck" "$((D_LUCK / 10)).$((D_LUCK % 10)) %"
  fi
  if [[ -n "${D_SCHEDULE_EPOCH}" && "${D_RESULTS}" != Y ]]; then
    # Nothing records block results in the block log yet, so a count of
    # adopted blocks would always read 0.
    glv_schedule_split passed coming
    glv_cell "$1" "Passed" "${passed}"
    glv_cell "$1" "To come" "${coming}"
  elif [[ -n "${D_SCHEDULE_EPOCH}" ]]; then
    glv_cell "$1" "Adopted" "$(( ${D_STATUS[adopted]:-0} + ${D_STATUS[confirmed]:-0} ))" C_OK
    glv_cell "$1" "Confirmed" "${D_STATUS[confirmed]:-0}" C_OK
    for text in missed ghosted stolen heightbattle invalid; do
      colour=''
      (( ${D_STATUS[${text}]:-0} == 0 )) || colour=C_DANGER
      glv_status_label value "${text}"
      glv_cell "$1" "${value^}" "${D_STATUS[${text}]:-0}" "${colour}"
    done
  else
    glv_metric_cell "$1" isleader "Leader"
    glv_metric_cell "$1" adopted "Adopted" int C_OK
    glv_metric_cell "$1" didntadopt "Invalid"
    glv_metric_cell "$1" leader_sched_slots "Scheduled"
    glv_metric_cell "$1" leader_lost "Lost"
  fi
  # "results" asks for the slot results only, without the key figures.
  [[ "${2:-}" != results ]] || return 0
  if node_metric_has remaining_kes_periods; then
    glv_kes_colour colour
    glv_cell "$1" "KES" "${remaining_kes_periods} periods" "${colour}"
  fi
  glv_opcert_text text colour
  glv_cell "$1" "Op cert" "${text}" "${colour}"
  glv_metric_cell "$1" missed_slots "Missed chk"
  if node_metric_has forge_keys_valid; then
    if [[ "${forge_keys_valid}" == 1 ]]; then glv_cell "$1" "Keys" "valid" C_OK
    else glv_cell "$1" "Keys" "invalid" C_DANGER; fi
  fi
}

# The Resources figures as cells, for the compact layout: host, then the
# node process, then the disk.
glv_resource_cells() {
  local text sample
  ui_fmt_tenths text "${D_CPU}"
  glv_cell "$1" "CPU (sys)" "${text} %"
  if [[ -n "${D_PCPU}" ]]; then
    ui_fmt_tenths text "${D_PCPU}"
    glv_cell "$1" "CPU (node)" "${text} %"
  fi
  if [[ -n "${D_MEM}" ]]; then
    ui_fmt_tenths text "${D_MEM}"
    glv_cell "$1" "Mem (RSS)" "${text} GiB"
  fi
  if node_metric_has mem_live && ui_scale sample "${mem_live}" 0; then
    ui_fmt_bytes text "${sample}"
    glv_cell "$1" "Live" "${text}"
  fi
  [[ -z "${D_DISK}" ]] || glv_cell "$1" "Disk util" "${D_DISK} %"
  glv_metric_cell "$1" open_files "Open files"
}

# glv_panel_production <width> <columns>
glv_panel_production() {
  local width="$1" columns="$2" inner=$(($1 - 4)) rows title="Block production" source
  local -a cells=()
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  glv_production_cells cells
  rows=$(( (${#cells[@]} + columns - 1) / columns ))
  (( rows >= 1 )) || rows=1
  if (( ${#cells[@]} == 0 )); then
    ui_putw "${C_MUTED}" "${inner}" "${D_IMPL} reports no forging figures yet."
    ui_endl UI_BODY "${inner}"
  else
    ui_grid cells "${columns}" "${rows}" "${inner}" UI_BODY
  fi
  if node_metric_has epochnum; then title+=" · epoch ${epochnum}"; fi
  source="node counters"
  [[ -z "${D_SCHEDULE_EPOCH}" ]] || source="leader schedule"
  UI_HELP=production
  ui_panel P_PROD "${width}" $((rows + 2)) "${title}" "${source}"
}

# glv_panel_recent <width> <height> <all|blocks> [rows to skip]
glv_panel_recent() {
  local width="$1" height="$2" filter="${3:-all}" skip="${4:-0}" inner=$(($1 - 4)) rows=$(($2 - 3))
  local record kind stamp block slot delay note colour value bar room shown=0
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  room=$((inner - 43))
  ui_putw "${C_MUTED}" 8 "Time"; ui_putw "${C_MUTED}" 12 "Block" r
  ui_putw "${C_MUTED}" 13 "Slot" r; ui_putw "${C_MUTED}" 8 "Delay" r
  ui_endl UI_BODY "${inner}"
  for record in "${D_ROWS[@]:skip}"; do
    (( shown < rows )) || break
    kind="${record%%|*}"; record="${record#*|}"
    [[ "${filter}" == all || "${kind}" == B ]] || continue
    stamp="${record%%|*}"; record="${record#*|}"
    ui_putw "${C_MUTED}" 8 "${stamp}"
    if [[ "${kind}" == E ]]; then
      ui_putw "${C_MUTED}" 12 "—" r; ui_putw "${C_MUTED}" 13 "—" r
      ui_putw "${C_MUTED}" 8 "—" r; ui_gap 2
      record="${record/|/ · }"
      ui_putw "${C_WARN}" $(( room < ${#record} ? room : ${#record} )) "${record}"
    else
      block="${record%%|*}"; record="${record#*|}"
      slot="${record%%|*}"; record="${record#*|}"
      delay="${record%%|*}"; note="${record#*|}"
      ui_fmt_int value "${block}"; ui_putw '' 12 "${value}" r
      ui_fmt_int value "${slot}"; ui_putw '' 13 "${value}" r
      if (( delay < 0 )); then
        ui_putw "${C_MUTED}" 8 "—" r
        ui_gap 2
      else
        ui_delay_colour colour "${delay}"
        ui_fmt_delay value "${delay}"; ui_putw "${colour}" 8 "${value}" r
        ui_gap 2
        bar=$((delay / 250))
        (( bar >= 1 )) || bar=1
        (( bar <= room )) || bar="${room}"
        (( delay > 1000 )) || colour="${C_ACCENT}"
        ui_put "${colour}" "${UI_BARS:0:bar}"
      fi
      if [[ -n "${note}" ]] && (( UI_LW + 1 + ${#note} <= inner )); then
        ui_gap 1
        ui_put "${C_MUTED}" "${note}"
      fi
    fi
    ui_endl UI_BODY "${inner}"
    shown=$((shown + 1))
  done
  if (( shown == 0 )); then
    ui_putw "${C_MUTED}" "${inner}" "Blocks are listed here as the node adopts them."
    ui_endl UI_BODY "${inner}"
  fi
  UI_HELP=recent
  ui_panel P_RECENT "${width}" "${height}" "Recent blocks" "newest first"
}

# Events, plus the blocks that came with a fork switch or arrived late.
glv_panel_events() {
  local width="$1" height="$2" inner=$(($1 - 4)) rows=$(($2 - 2)) record shown=0
  local stamp block delay note colour text
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  for record in "${D_ROWS[@]}"; do
    (( shown < rows )) || break
    if [[ "${record}" == E\|* ]]; then
      record="${record#E|}"
      stamp="${record%%|*}"; record="${record#*|}"
      text="${record/|/ · }"
      colour="${C_WARN}"
    else
      note="${record##*|}"
      [[ "${note}" == "fork switch" || "${note}" == late ]] || continue
      record="${record#B|}"
      stamp="${record%%|*}"; record="${record#*|}"
      block="${record%%|*}"
      ui_fmt_int block "${block}"
      text="${note} · block ${block}"
      colour="${C_WARN}"
      [[ "${note}" != late ]] || colour="${C_DANGER}"
    fi
    ui_putw "${C_MUTED}" 9 "${stamp}"
    ui_putw "${colour}" $((inner - 9)) "${text}"
    ui_endl UI_BODY "${inner}"
    shown=$((shown + 1))
  done
  if (( shown == 0 )); then
    ui_putw "${C_MUTED}" "${inner}" "Nothing to report."
    ui_endl UI_BODY "${inner}"
  fi
  UI_HELP=events
  ui_panel P_EVENTS "${width}" "${height}" "Events" ""
}

# ── rail ─────────────────────────────────────────────────────────────────────
glv_vital() {
  ui_put "$2" "●"; ui_gap 1
  ui_putw "${C_MUTED}" 8 "$3"
  ui_putw '' $((GLV_VITAL_W - 10)) "$4"
  ui_endl "$1" "${GLV_VITAL_W}"
}

# glv_vitals <array> <inner width>: the health list of the rail.
glv_vitals() {
  local list="$1" colour text value last
  GLV_VITAL_W="$2"
  if [[ "${D_OK}" != Y ]]; then
    glv_vital "${list}" "${C_DANGER}" "Node" "${D_DOWN:-no metrics}"
  fi
  if node_metric_has sync_phase && [[ -n "${sync_phase:-}" ]]; then
    text="${sync_phase}"
    if node_metric_has sync_progress; then text="${sync_progress} %"; fi
    glv_vital "${list}" "${C_WARN}" "Sync" "${text}"
  elif [[ -n "${D_TIP_GAP}" ]]; then
    glv_gap_colour colour
    local -n _vital_colour="${colour}"
    glv_slots value "${D_TIP_GAP}"
    glv_vital "${list}" "${_vital_colour}" "Sync" "${value}"
  fi
  if node_metric_has conn_outgoing && node_metric_has conn_incoming; then
    colour="${C_OK}"
    [[ "${conn_outgoing}" != 0 ]] || colour="${C_DANGER}"
    glv_vital "${list}" "${colour}" "Peers" "${conn_outgoing} out · ${conn_incoming} in"
  elif node_metric_has peer_selection_hot; then
    glv_vital "${list}" "${C_OK}" "Peers" "${peer_selection_hot} hot"
  elif node_metric_has peer_active; then
    glv_vital "${list}" "${C_OK}" "Peers" "${peer_active} active"
  fi
  if node_metric_has block_delay && ui_scale last "${block_delay}" 3; then
    ui_delay_colour colour "${last}"
    ui_fmt_delay value "${last}"
    glv_vital "${list}" "${colour}" "Blocks" "${value}"
  fi
  if [[ "${D_ROLE}" == Core ]]; then
    if node_metric_has remaining_kes_periods; then
      glv_kes_colour colour
      local -n _kes_colour="${colour}"
      glv_vital "${list}" "${_kes_colour}" "KES" "${remaining_kes_periods} periods"
    fi
    glv_opcert_text text colour
    if [[ -n "${text}" ]]; then
      if [[ "${colour}" == C_DANGER ]]; then colour="${C_DANGER}"; else colour="${C_OK}"; fi
      glv_vital "${list}" "${colour}" "Op cert" "${text}"
    fi
    glv_pool_vital text colour
    [[ -z "${text}" ]] || glv_vital "${list}" "${colour}" "Pool" "${text}"
  fi
  # The host as a whole, then the node process on its own.
  colour="${C_OK}"
  (( D_CPU < 900 )) || colour="${C_WARN}"
  glv_vital "${list}" "${colour}" "Host" "$((D_CPU / 10)) % cpu"
  text=''
  [[ -z "${D_PCPU}" ]] || text="$((D_PCPU / 10)) % cpu"
  if [[ -n "${D_MEM}" ]]; then
    ui_fmt_tenths value "${D_MEM}"
    text+="${text:+ · }${value}G"
  fi
  [[ -z "${text}" ]] || glv_vital "${list}" "${C_OK}" "Node" "${text}"
}

glv_next_block() {
  local list="$1" inner="$2" value filled
  ui_put "${C_MUTED}" "NEXT BLOCK"; ui_endl "${list}" "${inner}"
  ui_fmt_duration value "${D_NEXT_IN}"
  ui_put "${UI_BOLD}${C_ACCENT}" "${value}"; ui_endl "${list}" "${inner}"
  # The bar fills over the last day before the slot.
  filled=$(( D_NEXT_IN >= 86400 ? 0 : inner * (86400 - D_NEXT_IN) / 86400 ))
  ui_bar "${inner}" "${filled}" UI_HEAVY "${C_ACCENT}"; ui_endl "${list}" "${inner}"
  printf -v value '%(%a %d %b %H:%M)T' "${D_NEXT_AT}"
  ui_put "${C_MUTED}" "${value}"; ui_endl "${list}" "${inner}"
}

# glv_logo_init: the node's logo for the full rail, from its adapter: one
# string per row and an "r;g;b" colour per row, as gLiveView 1 drew them in
# its header. GLV_LOGO stays empty when SHOW_NODE_LOGO is N (false in
# gLiveView 1), the adapter has no logo, or a row does not fit the rail.
GLV_LOGO=()
GLV_LOGO_SGR=()
glv_logo_init() {
  local index r g b palette sgr
  GLV_LOGO=()
  GLV_LOGO_SGR=()
  case "${SHOW_NODE_LOGO:-Y}" in
    [Nn]|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]) return 0 ;;
  esac
  declare -p NODE_IMPLEMENTATION_LOGO NODE_IMPLEMENTATION_LOGO_RGB >/dev/null 2>&1 || return 0
  (( ${#NODE_IMPLEMENTATION_LOGO[@]} > 0 &&
     ${#NODE_IMPLEMENTATION_LOGO[@]} == ${#NODE_IMPLEMENTATION_LOGO_RGB[@]} )) || return 0
  for index in "${!NODE_IMPLEMENTATION_LOGO[@]}"; do
    IFS=';' read -r r g b <<< "${NODE_IMPLEMENTATION_LOGO_RGB[index]}"
    if [[ ! "${r}" =~ ^[0-9]{1,3}$ || ! "${g}" =~ ^[0-9]{1,3}$ || ! "${b}" =~ ^[0-9]{1,3}$ ]] ||
       (( r > 255 || g > 255 || b > 255 || ${#NODE_IMPLEMENTATION_LOGO[index]} > GLV_RAIL_W - 2 )); then
      GLV_LOGO=()
      GLV_LOGO_SGR=()
      return 0
    fi
    case "${UI_COLOUR_DEPTH}" in
      rgb) printf -v sgr '\e[38;2;%d;%d;%dm' "$((10#${r}))" "$((10#${g}))" "$((10#${b}))" ;;
      none) sgr='' ;;
      *)
        ui_colour_256 palette "$((10#${r}))" "$((10#${g}))" "$((10#${b}))"
        printf -v sgr '\e[38;5;%dm' "${palette}"
        ;;
    esac
    GLV_LOGO+=("${NODE_IMPLEMENTATION_LOGO[index]}")
    GLV_LOGO_SGR+=("${sgr}")
  done
}

# glv_role_badge [width]: the node's role as a badge on the line being built,
# RELAY on the identifier blue and BLOCK PRODUCER on the number gold, so the
# two never look alike. Without a width it is the label with a space either
# side. Without colours the label stands in brackets.
glv_role_badge() {
  local label='RELAY' background="${CB_ID}" width
  if [[ "${D_ROLE}" == Core ]]; then label='BLOCK PRODUCER'; background="${CB_NUM}"; fi
  width="${1:-$(( ${#label} + 2 ))}"
  if [[ "${UI_COLOUR_DEPTH}" == none ]]; then
    ui_putw '' "${width}" "[${label}]"
  else
    ui_putw "${background}${C_SURFACE}${UI_BOLD}" "${width}" " ${label}"
  fi
}

# glv_identity_lines <array> <width>: the node's name, its role badge, the
# implementation with its version, and the network with the uptime, which
# drops its seconds when the line would not fit otherwise.
glv_identity_lines() {
  local width="$2" value uptime badge="$2"
  (( badge <= GLV_RAIL_W - 2 )) || badge=$((GLV_RAIL_W - 2))
  ui_putw "${UI_BOLD}" "${width}" "${D_NAME}"; ui_endl "$1" "${width}"
  glv_role_badge "${badge}"; ui_endl "$1" "${width}"
  ui_putw "${C_MUTED}" "${width}" "${D_IMPL} ${D_VERSION}"; ui_endl "$1" "${width}"
  value="${D_NETWORK}"
  if [[ -n "${D_UPTIME}" ]]; then
    ui_fmt_duration uptime "${D_UPTIME}"
    (( ${#value} + 6 + ${#uptime} <= width )) || uptime="${uptime%:*}"
    value+=" · up ${uptime}"
  fi
  ui_putw "${C_MUTED}" "${width}" "${value}"; ui_endl "$1" "${width}"
}

# glv_rail <height>: the full rail, RAIL lines of GLV_RAIL_W columns. Sections
# leave in this order when the terminal is short: logo, next block, more,
# vitals.
glv_rail() {
  local height="$1" inner=$((GLV_RAIL_W - 2)) value i line needed
  local show_logo=N show_vitals=N show_more=N show_next=N
  local -a title=() logo=() head=() vitals=() views=() more=() next=() body=()
  UI_BASE="${UI_BASE_RAIL}"

  ui_put "${UI_BOLD}${C_ACCENT}" "Koios gLiveView"; ui_put "${C_MUTED}" " ${GLV_VERSION}"; ui_endl title "${inner}"
  ui_endl title "${inner}"
  if (( ${#GLV_LOGO[@]} > 0 )); then
    for i in "${!GLV_LOGO[@]}"; do
      ui_put "${GLV_LOGO_SGR[i]}" "${GLV_LOGO[i]}"; ui_endl logo "${inner}"
    done
    ui_endl logo "${inner}"
  fi
  glv_identity_lines head "${inner}"

  ui_endl vitals "${inner}"
  ui_put "${C_MUTED}" "VITALS"; ui_endl vitals "${inner}"
  glv_vitals vitals "${inner}"

  ui_endl views "${inner}"
  ui_put "${C_MUTED}" "VIEWS"; ui_endl views "${inner}"
  for i in 1 2 3 4 5 6 7; do
    if (( i == VIEW )); then
      UI_BASE="${UI_BASE_SELECT}"
      ui_put "${UI_KEY}" "▸"; ui_gap 1
      ui_put "${UI_KEY}" "${VIEW_KEYS[i]}"; ui_gap 1
      ui_put "${UI_BOLD}" "${VIEW_NAMES[i]}"
    else
      ui_gap 2
      ui_put "${UI_KEY}" "${VIEW_KEYS[i]}"; ui_gap 1
      # Production has nothing to show on a relay.
      if (( i == 4 )) && [[ "${D_ROLE}" != Core ]]; then
        ui_put "${C_MUTED}" "${VIEW_NAMES[i]}"
      else
        ui_put '' "${VIEW_NAMES[i]}"
      fi
    fi
    ui_endl views "${inner}"
    UI_BASE="${UI_BASE_RAIL}"
  done

  if [[ -n "${GLV_EXTRA_KEYS[0]:-}" ]]; then
    ui_endl more "${inner}"
    ui_put "${C_MUTED}" "MORE"; ui_endl more "${inner}"
    ui_gap 2; ui_put "${UI_KEY}" "/"; ui_gap 1; ui_put '' "Command"; ui_endl more "${inner}"
  fi

  if [[ -n "${D_NEXT_IN}" ]]; then
    ui_endl next "${inner}"
    glv_next_block next "${inner}"
  fi

  # Decide by importance what fits, then stack the sections in rail order.
  needed=$((${#title[@]} + ${#head[@]} + ${#views[@]}))
  if (( needed + ${#vitals[@]} <= height )); then
    show_vitals=Y
    needed=$((needed + ${#vitals[@]}))
  fi
  if (( needed + ${#more[@]} <= height )); then
    show_more=Y
    needed=$((needed + ${#more[@]}))
  fi
  if (( needed + ${#next[@]} <= height )); then
    show_next=Y
    needed=$((needed + ${#next[@]}))
  fi
  if (( ${#logo[@]} > 0 && needed + ${#logo[@]} <= height )); then show_logo=Y; fi
  body=("${title[@]}")
  [[ "${show_logo}" == N ]] || body+=("${logo[@]}")
  body+=("${head[@]}")
  [[ "${show_vitals}" == N ]] || body+=("${vitals[@]}")
  body+=("${views[@]}")
  [[ "${show_more}" == N ]] || body+=("${more[@]}")
  [[ "${show_next}" == N ]] || body+=("${next[@]}")
  while (( ${#body[@]} < height )); do ui_endl body "${inner}"; done
  UI_BASE="${UI_BASE_MAIN}"

  RAIL=()
  for line in "${body[@]:0:height}"; do
    RAIL+=("${CB_SURFACE} ${line}${UI_RESET}${CB_SURFACE} ${UI_RESET}")
  done
}

# glv_rail_slim <height>: view numbers only, for 80 to 109 columns.
glv_rail_slim() {
  local height="$1" i line
  local -a body=()
  UI_BASE="${UI_BASE_RAIL}"
  for i in 1 2 3 4 5 6 7; do
    if (( i == VIEW )); then
      UI_BASE="${UI_BASE_SELECT}"
      ui_put "${UI_KEY}" "▸"
    else
      ui_gap 1
    fi
    ui_put "${UI_KEY}" "${VIEW_KEYS[i]}"
    ui_endl body 3
    UI_BASE="${UI_BASE_RAIL}"
  done
  if [[ -n "${GLV_EXTRA_KEYS[0]:-}" ]]; then
    ui_endl body 3
    ui_gap 1; ui_put "${UI_KEY}" "/"; ui_endl body 3
  fi
  while (( ${#body[@]} < height )); do ui_endl body 3; done
  UI_BASE="${UI_BASE_MAIN}"
  RAIL=()
  for line in "${body[@]:0:height}"; do
    RAIL+=("${CB_SURFACE} ${line}${UI_RESET}${CB_SURFACE} ${UI_RESET}")
  done
}

# ── page assembly ────────────────────────────────────────────────────────────
# Bands are added top to bottom. The first band that does not fit closes the
# page, so panels leave from the bottom when the terminal is short.
MAIN=()
MAIN_LIMIT=0
MAIN_CLOSED=N

# UI_PANELS lists the help keys of the panels that made it onto the page, in
# reading order; help mode moves its focus through that list.
UI_PANELS=()

glv_main_begin() { MAIN=(); MAIN_LIMIT="$1"; MAIN_CLOSED=N; UI_PANELS=(); }

glv_main_room() { GLV_ROOM=$((MAIN_LIMIT - ${#MAIN[@]})); [[ "${MAIN_CLOSED}" == N ]] || GLV_ROOM=0; }

# glv_main_add <array> [array …]: one band of boxes side by side.
glv_main_add() {
  local -n _band_first="$1"
  local name i line
  [[ "${MAIN_CLOSED}" == N ]] || return 0
  if (( ${#MAIN[@]} + ${#_band_first[@]} > MAIN_LIMIT )); then MAIN_CLOSED=Y; return 0; fi
  for name in "$@"; do
    [[ -z "${UI_PANEL_KEY[${name}]:-}" ]] || UI_PANELS+=("${UI_PANEL_KEY[${name}]}")
  done
  for i in "${!_band_first[@]}"; do
    line=''
    for name in "$@"; do
      local -n _band_part="${name}"
      line+="${_band_part[i]:-}"
    done
    MAIN+=("${line}")
  done
}

glv_footer() {
  local -n _footer_out="$1"
  local item right room
  local -a line=()
  shift
  UI_BASE="${UI_BASE_MAIN}"
  # The right side (position in a list, the clock) is placed first, and the
  # keys get the room that is left. A row wider than the terminal would make
  # it scroll, so a key that does not fit is left out; callers list the keys
  # that matter most first.
  printf -v right '%(%H:%M:%S)T' -1
  [[ -z "${GLV_FOOTER_NOTE:-}" ]] || right="${GLV_FOOTER_NOTE} · ${right}"
  if [[ "${GLV_DEBUG:-N}" == Y ]]; then
    right="frame ${GLV_FRAME_MS:-0} ms · collect ${D_COLLECT_MS} ms · ${right}"
  fi
  (( ${#right} + 12 <= COLS )) || right=''
  room=$((COLS - ${#right} - 2))
  ui_gap 1
  for item in "$@"; do
    (( UI_LW + ${#item} + 1 <= room )) || continue
    ui_put "${UI_KEY}" "${item%% *}"
    ui_put "${C_MUTED}" " ${item#* }"
    ui_gap 2
  done
  if [[ -n "${right}" ]]; then
    ui_gap $((COLS - UI_LW - ${#right} - 1))
    ui_put "${C_MUTED}" "${right}"
  fi
  ui_endl line "${COLS}"
  _footer_out="${line[0]}${UI_RESET}"
}

# Wide and standard: the full rail beside the page.
# The overview at wide and standard widths.
glv_view_overview() {
  local width="$1" quarter=$(($1 / 4)) half=$(($1 / 2)) third
  glv_panel_epoch "${width}"
  glv_main_add P_EPOCH
  if [[ "${LAYOUT}" == wide ]]; then
    glv_panel_chain "${quarter}" 1 5
    glv_panel_propagation "${quarter}"
    glv_panel_peers "${quarter}"
    glv_panel_resources $((width - 3 * quarter))
    glv_main_add P_CHAIN P_PROP P_PEERS P_RES
  else
    glv_panel_chain "${half}" 2 5
    glv_panel_propagation $((width - half))
    glv_main_add P_CHAIN P_PROP
    glv_panel_peers "${half}"
    glv_panel_resources $((width - half))
    glv_main_add P_PEERS P_RES
  fi
  if [[ "${D_ROLE}" == Core ]]; then
    glv_panel_production "${width}" 4
    glv_main_add P_PROD
  fi
  glv_main_room
  (( GLV_ROOM >= 5 )) || return 0
  if [[ "${LAYOUT}" == wide ]]; then
    third=$((width / 3))
    glv_panel_recent $((width - third)) "${GLV_ROOM}" blocks
    glv_panel_events "${third}" "${GLV_ROOM}"
    glv_main_add P_RECENT P_EVENTS
  else
    glv_panel_recent "${width}" "${GLV_ROOM}" all
    glv_main_add P_RECENT
  fi
}

# glv_footer_page <variable> <page navigation keys…>: the footer of a page
# other than the overview. With the focus on the page's list the arrows
# scroll it; otherwise they move between pages and Tab offers the list.
glv_footer_page() {
  local name="$1" tab_hint="Tab Pages"
  shift
  if [[ "${PAGE_FOCUS}" == Y ]]; then
    glv_focus_key
    ! glv_focus_after || tab_hint="Tab Next list"
    if [[ "${GLV_FOCUS_KEY}" == history ]]; then
      glv_footer "${name}" "↑↓ Epoch" "PgUp/PgDn ${HIST_SHOWN} epochs" "g Newest" "G Oldest" "${tab_hint}" "? Help" "q Quit"
    else
      glv_footer "${name}" "↑↓ Line" "${tab_hint}" "${GLV_PAGE_KEYS[@]}" "? Help" "q Quit" "${GLV_EXTRA_KEYS[@]}"
    fi
  elif glv_focus_available; then
    glv_footer "${name}" "Tab List" "${GLV_PAGE_KEYS[@]}" "? Help" "q Quit" "$@" "${GLV_EXTRA_KEYS[@]}"
  else
    glv_footer "${name}" "${GLV_PAGE_KEYS[@]}" "? Help" "q Quit" "$@" "${GLV_EXTRA_KEYS[@]}"
  fi
}

# glv_page_body <width> <rows>: the main area beside the full rail. In help
# mode the page gives its lower rows to a drawer that explains the focused
# panel, or, where there is no room for that, becomes the help text itself.
glv_page_body() {
  local width="$1" rows="$2" drawer=0 pass key found blank="${UI_SPACES:0:$1}"
  glv_help_mode "${rows}"
  if [[ "${HELP_MODE}" == page ]]; then
    glv_main_begin "${rows}"
    glv_help_fullpage "${width}" "${rows}"
    return 0
  fi
  if [[ "${HELP_MODE}" == drawer ]]; then
    drawer=$((rows * 2 / 5))
    (( drawer >= 9 )) || drawer=9
    (( drawer <= 16 )) || drawer=16
  fi
  for pass in 1 2; do
    UI_FOCUS=''
    if [[ "${HELP_MODE}" == drawer ]]; then UI_FOCUS="${HELP_FOCUS}"
    elif [[ "${PAGE_FOCUS}" == Y ]]; then glv_focus_key; UI_FOCUS="${GLV_FOCUS_KEY}"; fi
    glv_main_begin $((rows - drawer))
    GLV_PAGE_KEYS=()
    GLV_FOOTER_NOTE=''
    if (( VIEW == 1 )); then glv_view_overview "${width}"; else glv_view_build "${width}"; fi
    [[ "${HELP_MODE}" == drawer ]] || break
    # The focus must be on a panel that is on screen; if it is not, take the
    # first one and draw the page once more.
    found=N
    for key in "${UI_PANELS[@]}"; do [[ "${key}" != "${HELP_FOCUS}" ]] || found=Y; done
    [[ "${found}" == N ]] || break
    HELP_FOCUS="${UI_PANELS[0]:-}"
    HELP_SCROLL=0
  done
  UI_FOCUS=''
  [[ "${HELP_MODE}" == drawer ]] || return 0
  while (( ${#MAIN[@]} < rows - drawer )); do MAIN+=("${blank}"); done
  glv_help_drawer "${width}" "${drawer}"
  MAIN+=("${P_DRAWER[@]}")
}

# Wide and standard: the full rail beside the page.
glv_page_full() {
  local page=$((ROWS - 1)) width=$((COLS - GLV_RAIL_W)) i footer='' blank
  glv_rail "${page}"
  GLV_FOOTER_NOTE=''
  GLV_PAGE_KEYS=()
  glv_page_body "${width}" "${page}"
  case "${HELP_MODE}" in
    drawer) glv_footer footer "←→ Panel" "↑↓ Scroll text" "? Close help" "1-6 Jump" "q Quit" ;;
    page) glv_footer footer "↑↓ Scroll" "? Close help" "1-6 Jump" "q Quit" ;;
    *)
      if (( VIEW == 1 )); then
        glv_footer footer "↑↓ View" "1-6 Jump" "? Help" "${GLV_EXTRA_KEYS[@]}" "r Redraw" "q Quit"
      else
        glv_footer_page footer "↑↓ View" "1-6 Jump"
      fi ;;
  esac
  blank="${UI_SPACES:0:width}"
  UI_FRAME=()
  for ((i = 0; i < page; i++)); do UI_FRAME+=("${RAIL[i]}${MAIN[i]:-${blank}}"); done
  UI_FRAME+=("${footer}")
}

# Compact: a rail of view numbers and one stacked column, as today's
# gLiveView does it.
glv_page_compact() {
  local page=$((ROWS - 1)) width=$((COLS - GLV_SLIM_W)) inner=$((COLS - GLV_SLIM_W - 4))
  local i footer='' blank status colour text value
  local -a head=() cells=() tail=()
  glv_rail_slim "${page}"
  glv_main_begin "${page}"

  UI_BASE="${UI_BASE_MAIN}"
  glv_status status colour
  text="· ${D_IMPL} ${D_VERSION} · ${D_NETWORK}"
  ui_gap 2
  glv_role_badge; ui_gap 1
  ui_put "${UI_BOLD}" "${D_NAME}"; ui_gap 1
  ui_putw "${C_MUTED}" $(( width - UI_LW - ${#status} - 6 )) "${text}"
  ui_gap $((width - UI_LW - ${#status} - 4))
  ui_put "${colour}" "● ${status}"
  ui_endl head "${width}"
  glv_main_add head

  GLV_FOOTER_NOTE=''
  GLV_PAGE_KEYS=()
  UI_FOCUS=''
  if [[ "${PAGE_FOCUS}" == Y && "${HELP}" != Y ]]; then glv_focus_key; UI_FOCUS="${GLV_FOCUS_KEY}"; fi
  # There is no room for a help drawer here, so help is a page of its own.
  HELP_MODE=off
  [[ "${HELP}" != Y ]] || HELP_MODE=page
  if [[ "${HELP_MODE}" == page ]]; then
    glv_help_fullpage "${width}" $((page - 1))
  elif (( VIEW != 1 )); then
    glv_view_build "${width}"
  else
    glv_panel_epoch "${width}" "1 Overview · "
    glv_main_add P_EPOCH
    glv_panel_chain "${width}" 3 3
    glv_main_add P_CHAIN

    # Peers in use and kept ready (big ledger peers included), then the
    # peers that connected to this node, then how blocks arrive.
    UI_BODY=()
    if node_metric_has peer_selection_hot && glv_is_int "${peer_selection_hot:-}"; then
      glv_cell cells "Hot peers" "$((peer_selection_hot + ${D_BIG_HOT:-0}))"
      if glv_is_int "${peer_selection_warm:-}"; then
        glv_cell cells "Warm peers" "$((peer_selection_warm + ${D_BIG_WARM:-0}))"
      fi
    else
      glv_metric_cell cells peer_active "Active"
      glv_metric_cell cells conn_outgoing "Outgoing"
    fi
    glv_metric_cell cells conn_incoming "Incoming"
    if node_metric_has blocks_w1s && ui_scale value "${blocks_w1s}" 3; then
      glv_cell cells "Within 1 s" "$((value / 10)).$((value % 10)) %"
    else
      glv_metric_cell cells conn_total "Connections"
    fi
    if node_metric_has block_delay && ui_scale value "${block_delay}" 3; then
      ui_fmt_delay text "${value}"
      colour=C_OK
      (( value <= 1000 )) || colour=C_WARN
      glv_cell cells "Last block" "${text}" "${colour}"
    fi
    glv_metric_cell cells blocks_late "Late"
    if (( ${#cells[@]} > 0 )); then
      ui_grid cells 3 2 "${inner}" UI_BODY
      UI_HELP=peers
      ui_panel P_PEERS "${width}" 4 "Peers · propagation" ""
      glv_main_add P_PEERS
    fi

    if [[ "${D_ROLE}" == Core ]]; then
      # Six cells: what must not be missed comes first.
      cells=()
      UI_BODY=()
      if [[ -n "${D_NEXT_IN}" ]]; then
        ui_fmt_duration text "${D_NEXT_IN}"
        glv_cell cells "Next block" "${text}" C_ACCENT
      fi
      if node_metric_has remaining_kes_periods; then
        glv_kes_colour colour
        glv_cell cells "KES" "${remaining_kes_periods} periods" "${colour}"
      fi
      glv_opcert_text text colour
      glv_cell cells "Op cert" "${text}" "${colour}"
      if [[ -n "${D_SCHEDULE_EPOCH}" && "${D_RESULTS}" != Y ]]; then
        glv_schedule_split value text
        glv_cell cells "Leader" "${D_STATUS[total]:-0}"
        glv_cell cells "Passed" "${value}"
        glv_cell cells "To come" "${text}"
      elif [[ -n "${D_SCHEDULE_EPOCH}" ]]; then
        glv_cell cells "Leader" "${D_STATUS[total]:-0}"
        glv_cell cells "Adopted" "$(( ${D_STATUS[adopted]:-0} + ${D_STATUS[confirmed]:-0} ))" C_OK
        value=$(( ${D_STATUS[missed]:-0} + ${D_STATUS[ghosted]:-0} + ${D_STATUS[stolen]:-0} + ${D_STATUS[heightbattle]:-0} + ${D_STATUS[invalid]:-0} ))
        colour=''
        (( value == 0 )) || colour=C_DANGER
        glv_cell cells "Lost" "${value}" "${colour}"
      else
        glv_metric_cell cells isleader "Leader"
        glv_metric_cell cells adopted "Adopted" int C_OK
        glv_metric_cell cells leader_sched_slots "Scheduled"
      fi
      ui_grid cells 3 2 "${inner}" UI_BODY
      UI_HELP=production
      ui_panel P_PROD "${width}" 4 "Production" ""
      glv_main_add P_PROD
    fi

    cells=()
    UI_BODY=()
    glv_resource_cells cells
    ui_grid cells 3 2 "${inner}" UI_BODY
    UI_HELP=resources
    ui_panel P_RES "${width}" 4 "Resources" ""
    glv_main_add P_RES

    # Whatever height is left goes to the block list, which also carries
    # the events.
    glv_main_room
    if (( GLV_ROOM >= 5 )); then
      glv_panel_recent "${width}" "${GLV_ROOM}" all
      glv_main_add P_RECENT
    elif [[ -n "${D_LAST_EVENT}" ]]; then
      ui_gap 2
      ui_putw '' $((width - 14)) "${D_LAST_EVENT}"
      ui_put "${C_MUTED}" "last event"
      ui_endl tail "${width}"
      glv_main_add tail
    fi
  fi
  if [[ "${HELP_MODE}" == page ]]; then
    glv_footer footer "↑↓ Scroll" "? Close help" "1-6 View" "q Quit"
  elif (( VIEW != 1 )); then
    glv_footer_page footer "1-6 View"
  else
    glv_footer footer "1-6 View" "? Help" "${GLV_EXTRA_KEYS[@]}" "r Redraw" "q Quit"
  fi
  blank="${UI_SPACES:0:width}"
  UI_FRAME=()
  for ((i = 0; i < page; i++)); do UI_FRAME+=("${RAIL[i]}${MAIN[i]:-${blank}}"); done
  UI_FRAME+=("${footer}")
}

# Mini: no room for pages, so the rail's content fills the terminal.
glv_page_mini() {
  local page=$((ROWS - 1)) inner=$((COLS - 2)) status colour value filled tenths line
  local -a lines=() next=() foot=()
  UI_BASE="${UI_BASE_RAIL}"
  glv_status status colour
  ui_put "${UI_BOLD}${C_ACCENT}" "Koios gLiveView"; ui_put "${C_MUTED}" " ${GLV_VERSION}"; ui_endl lines "${inner}"
  ui_putw "${colour}" "${inner}" "● ${status}"; ui_endl lines "${inner}"
  ui_endl lines "${inner}"
  glv_identity_lines lines "${inner}"

  if node_metric_has epochnum && node_metric_has slot_in_epoch &&
     glv_is_int "${slot_in_epoch:-}" && glv_is_int "${EPOCH_LENGTH:-}" && (( EPOCH_LENGTH > 0 )); then
    tenths=$((slot_in_epoch * 1000 / EPOCH_LENGTH))
    value="$((tenths / 10)).$((tenths % 10)) %"
    ui_endl lines "${inner}"
    ui_put "${C_MUTED}" "EPOCH ${epochnum}"
    ui_gap $((inner - UI_LW - ${#value}))
    ui_put "${C_MUTED}" "${value}"; ui_endl lines "${inner}"
    ui_bar "${inner}" $((inner * slot_in_epoch / EPOCH_LENGTH)) UI_BLOCKS "${C_ACCENT}"
    ui_endl lines "${inner}"
    if [[ -n "${D_EPOCH_LEFT}" ]]; then
      ui_fmt_duration value "${D_EPOCH_LEFT}"
      ui_put "${C_MUTED}" "${value} left"; ui_endl lines "${inner}"
    fi
  fi

  ui_endl lines "${inner}"
  ui_put "${C_MUTED}" "VITALS"; ui_endl lines "${inner}"
  glv_vitals lines "${inner}"

  if [[ -n "${D_NEXT_IN}" ]]; then
    ui_endl next "${inner}"
    glv_next_block next "${inner}"
    (( ${#lines[@]} + ${#next[@]} > page )) || lines+=("${next[@]}")
  fi
  if (( ${#lines[@]} + 2 <= page )); then
    ui_endl lines "${inner}"
    ui_put "${C_MUTED}" "Pages need 80 columns."; ui_endl lines "${inner}"
  fi
  while (( ${#lines[@]} < page )); do ui_endl lines "${inner}"; done

  ui_put "${UI_KEY}" "q"; ui_put "${C_MUTED}" " Quit"
  ui_endl foot "${inner}"
  UI_FRAME=()
  for line in "${lines[@]:0:page}" "${foot[0]}"; do
    UI_FRAME+=("${CB_SURFACE} ${line}${UI_RESET}${CB_SURFACE} ${UI_RESET}")
  done
  UI_BASE="${UI_BASE_MAIN}"
}

# Below the smallest layout: ask for a bigger terminal instead of drawing a
# broken page.
glv_page_small() {
  local headline="Terminal too small" width inner top left i line text height
  local -a lines=()
  UI_BASE="${UI_BASE_MAIN}"
  UI_FRAME=()
  for ((i = 0; i < ROWS; i++)); do UI_FRAME+=("${UI_SPACES:0:COLS}"); done
  if (( COLS >= 46 )); then
    lines=("${headline}" "${COLS} × ${ROWS} now · ${GLV_MIN_COLS} × ${GLV_MIN_ROWS} needed"
           "Enlarge the window, or press q to quit.")
  else
    lines=("${headline}" "${COLS} × ${ROWS} now" "${GLV_MIN_COLS} × ${GLV_MIN_ROWS} needed" "q quits")
  fi
  height=$((${#lines[@]} + 2))
  if (( COLS >= 24 && ROWS >= height )); then
    width=$(( COLS - 2 < 46 ? COLS - 2 : 46 ))
    inner=$((width - 4))
    UI_BODY=()
    for text in "${lines[@]}"; do
      ui_gap $(((inner - ${#text}) / 2))
      if [[ "${text}" == "${headline}" ]]; then ui_put "${UI_BOLD}${C_WARN}" "${text}"
      elif [[ "${text}" == *q* ]]; then ui_put "${C_MUTED}" "${text}"
      else ui_put '' "${text}"; fi
      ui_endl UI_BODY "${inner}"
    done
    ui_panel P_SMALL "${width}" "${height}" "" "" WARN
    top=$(((ROWS - height) / 2))
    left=$(((COLS - width) / 2))
    for i in "${!P_SMALL[@]}"; do
      UI_FRAME[top+i]="${UI_SPACES:0:left}${P_SMALL[i]}${UI_SPACES:0:COLS-left-width}"
    done
    return 0
  fi
  # Too small even for a box: plain lines, cut to what fits.
  i=0
  for line in "${headline}" "${COLS} × ${ROWS} now" "${GLV_MIN_COLS} × ${GLV_MIN_ROWS} needed" "q quits"; do
    (( i < ROWS )) || break
    line="${line:0:COLS}"
    UI_FRAME[i]="${C_WARN}${line}${UI_RESET}${UI_SPACES:0:COLS-${#line}}"
    i=$((i + 1))
  done
}

glv_render() {
  local start="${EPOCHREALTIME/[.,]/}"
  glv_layout_class
  case "${LAYOUT}" in
    small) glv_page_small ;;
    mini) glv_page_mini ;;
    compact) glv_page_compact ;;
    *) glv_page_full ;;
  esac
  ui_flush
  GLV_FRAME_MS=$(( (${EPOCHREALTIME/[.,]/} - start) / 1000 ))
}

##############################################################################
# Peer analysis: what each connection of the node is used for
##############################################################################
# What each connection of the node is used for.
#
# The connection list itself (address, port, round-trip time) comes from one
# ss call on every collection, see glv_data_peers. This file adds the node's
# own view of those connections:
#
#   cardano-node  its state dump, written to the log on SIGUSR1, and its log of
#                 peers promoting or demoting it
#   Amaru         its log of connections and of the peers that delivered
#                 headers and blocks first
#
# plus the static peers of the topology file and a location for each address.
# Reading the log can take a while, so that work runs as a background job that
# prints records to a file; the page keeps updating and loads the records when
# the job is done. The job starts on a key, never by itself, because for
# cardano-node it sends the node a signal.

declare -gA nodeConnUse=()    # "ip;remote port;local port" -> dup, out, in or idle
declare -gA nodePeerTemp=()   # "ip;port" -> H or W on the node's outbound side
declare -gA nodePeerScore=()  # "ip;port" -> headers first plus blocks fetched first
declare -gA nodeRemoteTemp=() # "ip;remote port;local port" -> H, W or C on the peer's side
declare -gA staticPeer=()     # resolved IP of a localRoots access point -> its label(s)
declare -gA staticPeerPort=() # "ip;port" of a localRoots access point -> its label
declare -gA staticPeerEntries=() # resolved IP -> number of access points using it
declare -gA geoIP=()          # IP -> "City, CC"
staticPeerList=()             # "address;port;label;ip,ip" per localRoots access point
node_peer_state_available=false

PEER_FILTER_DIR=all      # all | out | in | dup
PEER_FILTER_STATE=any    # any | hot | warm
PEER_FILTER_STATIC=all   # all | static
PEER_SEARCH=''           # part of an address or port
PEER_JOB_PID=''
PEER_JOB_NOTE=''
PEER_STATE_AT=''
PEER_SELECTED=()
PEER_COUNT=(0 0 0 0 0)   # round trips under 50, 100, 200 ms, above, unknown
PEER_AVERAGE=''

# ── the background job ───────────────────────────────────────────────────────
# The functions down to glv_peers_static_capable are the log readers of
# gLiveView 1, unchanged, and keep its variable names; glv_peers_job_run sets
# those up. files/tests/gliveview-peer-analysis.sh loads them by name.

resolvePeerAddress() {
  local address="$1" resolved=""
  local -a time_limit=()
  if [[ ${address} =~ ^[0-9.]+$ || ${address} == *:* ]]; then
    printf '%s' "${address}"
    return
  fi
  command -v timeout >/dev/null && time_limit=(timeout 3)
  if command -v getent >/dev/null; then
    resolved="$("${time_limit[@]}" getent ahosts "${address}" 2>/dev/null |
      awk '{print $1}' | sort -u | paste -sd, -)"
  fi
  if [[ -z ${resolved} ]] && command -v dig >/dev/null; then
    resolved="$({
        dig +short +time=2 +tries=1 A "${address}"
        dig +short +time=2 +tries=1 AAAA "${address}"
      } 2>/dev/null | grep -E '^[0-9.]+$|^[0-9a-fA-F:]+:[0-9a-fA-F:.]*$' | sort -u | paste -sd, -)"
  fi
  printf '%s' "${resolved}"
}

getStaticPeers() {
  local topology_file="${TOPOLOGY}" prev_arg="" cmdline_arg address port label ips ip port_key
  local -a cmdline_args=()
  staticPeer=()
  staticPeerPort=()
  staticPeerEntries=()
  staticPeerList=()
  if [[ -n ${CNODE_PID} && -r /proc/${CNODE_PID}/cmdline ]]; then
    mapfile -d '' -t cmdline_args < "/proc/${CNODE_PID}/cmdline"
    for cmdline_arg in "${cmdline_args[@]}"; do
      [[ ${prev_arg} = "--topology" ]] && topology_file="${cmdline_arg}"
      prev_arg="${cmdline_arg}"
    done
    [[ ${topology_file} = /* ]] || topology_file="/proc/${CNODE_PID}/cwd/${topology_file}"
  fi
  [[ -r ${topology_file} ]] || return 0
  while IFS=$'\t' read -r address port label; do
    [[ -n ${address} && -n ${port} ]] || continue
    # A DNS name is a useful label when the entry has no description.
    [[ -z ${label} && ! ${address} =~ ^[0-9.]+$ && ${address} != *:* ]] && label="${address}"
    label="${label//;/,}"
    ips="$(resolvePeerAddress "${address}")"
    staticPeerList+=("${address};${port};${label};${ips}")
    for ip in ${ips//,/ }; do
      port_key="${ip};${port}"
      staticPeerPort[${port_key}]="${label}"
      staticPeerEntries[${ip}]=$(( ${staticPeerEntries[${ip}]:-0} + 1 ))
      if [[ -z ${staticPeer[${ip}]:-} ]]; then
        staticPeer[${ip}]="${label}"
      elif [[ -n ${label} && " / ${staticPeer[${ip}]} / " != *" / ${label} / "* ]]; then
        staticPeer[${ip}]+=" / ${label}"
      fi
    done
  done < <(jq -r '
      .localRoots[]?.accessPoints[]? | select(.address != null and .port != null) |
      [.address, (.port | tostring), (.description // .pool // .name // "")] | @tsv
    ' "${topology_file}" 2>/dev/null)
}

getNodePeerState() {
  local cgroup_path unit
  local -a journal_match=()
  nodeConnUse=()
  nodePeerTemp=()
  nodePeerScore=()
  nodeRemoteTemp=()
  node_peer_state_available=false
  [[ ${ENABLE_NODE_PEER_STATE} = 'Y' ]] || return 0
  [[ ${CNODE_PID} =~ ^[1-9][0-9]*$ ]] && command -v journalctl >/dev/null || return 0
  case "${NODE_IMPLEMENTATION}:$(ps -o comm= -p "${CNODE_PID}" 2>/dev/null)" in
    cnode:cardano-node*|amaru:amaru) ;;
    *) return 0 ;;
  esac
  # A system service's journal by its unit, else the process's own entries.
  cgroup_path="$(awk -F: '$1 == "0" || $2 == "name=systemd" {print $3; exit}' "/proc/${CNODE_PID}/cgroup" 2>/dev/null)" ||
    cgroup_path=""
  unit="${cgroup_path##*/}"
  if [[ ${unit} = *.service && ${cgroup_path} != *"/user@"* ]]; then
    journal_match=(-u "${unit}")
  else
    journal_match=("_PID=${CNODE_PID}")
  fi
  [[ -n $(journalctl -q -n 1 -o cat --no-pager "${journal_match[@]}" 2>/dev/null) ]] || return 0
  case ${NODE_IMPLEMENTATION} in
    cnode) getCnodePeerState "${journal_match[@]}" ;;
    amaru) getAmaruPeerState "${journal_match[@]}" ;;
  esac
}

getCnodePeerState() {
  local since attempt dump="" record_type peer_key peer_value record key
  local -a kept=()
  readNodePeerLog '
      def addr: .address | tostring | sub("^::ffff:"; "");
      def log_init: {};
      def log_restore($f): if $f[0] == "peer" and ($f | length) == 3 then .[$f[1]] = $f[2] else . end;
      def log_step($line):
        (($line | fromjson?) // null) as $record |
        if ($record | type) == "object" and ($record.data | type) == "object" and
           ($record.data.connectionId | type) == "object" then
          ({"PromotedToHotRemote": "H", "PromotedToWarmRemote": "W",
            "DemotedToWarmRemote": "W", "DemotedToColdRemote": "C"}[$record.ns | tostring | split(".") | last]) as $temp |
          $record.data.connectionId as $conn |
          if $temp == null then .
          else .["\($conn.remoteAddress | addr);\($conn.remoteAddress.port);\($conn.localAddress.port)"] = $temp
          end
        else . end;
      def log_records: to_entries[] | ["peer", .key, .value];
    ' '"ns":"Net.InboundGovernor.Remote.PromotedTo
"ns":"Net.InboundGovernor.Remote.DemotedTo' "$@"
  for record in "${node_log_records[@]}"; do
    IFS=$'\t' read -r record_type peer_key peer_value <<< "${record}"
    [[ ${record_type} = peer ]] && nodeRemoteTemp[${peer_key}]=${peer_value}
  done
  printf -v since '%(%s)T' -1
  kill -USR1 "${CNODE_PID}" 2>/dev/null || return 0
  for attempt in 1 2 3 4 5 6; do
    sleep 0.5
    dump="$(journalctl -q -o cat --no-pager "$@" --since "@$((since - 1))" 2>/dev/null |
      awk '/^\{"at":/ {if (record != "") print record; record = $0; next} {record = record $0} END {if (record != "") print record}' |
      grep -F -e '"ns":"Net.ConnectionManager.Remote.State"' -e '"ns":"Net.PeerSelection.Selection.DebugState"')" ||
      dump=""
    [[ ${dump} = *'"ns":"Net.ConnectionManager.Remote.State"'* &&
       ${dump} = *'"ns":"Net.PeerSelection.Selection.DebugState"'* ]] && break
  done
  [[ ${dump} = *'"ns":"Net.ConnectionManager.Remote.State"'* ]] || return 0
  while IFS=$'\t' read -r record_type peer_key peer_value; do
    case ${record_type} in
      c) nodeConnUse[${peer_key}]=${peer_value} ;;
      t) nodePeerTemp[${peer_key}]=${peer_value} ;;
      s) nodePeerScore[${peer_key}]=$(( ${nodePeerScore[${peer_key}]:-0} + peer_value )) ;;
    esac
  done < <(jq -Rrn '
      def addr: .address | tostring | sub("^::ffff:"; "");
      def peer: "\(addr);\(.port)";
      def use:
        if type == "string" then
          {"DuplexSt": "dup", "OutboundDupSt": "out", "OutboundUniSt": "out",
           "InboundSt": "in", "InboundIdleSt": "idle", "OutboundIdleSt": "idle"}[.]
        else null end;
      [inputs | fromjson? | select(type == "object")] as $records |
      ($records | map(select(.ns == "Net.ConnectionManager.Remote.State")) | last | .data.state // []) as $connections |
      ($records | map(select(.ns == "Net.PeerSelection.Selection.DebugState")) | last | .data // {}) as $selection |
      (
        $connections[] | select(type == "object" and (.remoteAddress | type) == "object") |
        "\(.remoteAddress | addr);\(.remoteAddress.port)" as $remote |
        .connections[]? | ((.state | if type == "object" then .kind else . end) | use) as $use |
        select($use != null) | ["c", "\($remote);\(.localAddress.port)", $use]
      ),
      (($selection.establishedPeers // [])[] | select(type == "object") | ["t", peer, "W"]),
      (($selection.activePeers // [])[] | select(type == "object") | ["t", peer, "H"]),
      ((($selection.upstreamyness // []) + ($selection.fetchynessBlocks // []))[] |
        select(type == "array" and (.[0] | type) == "object" and (.[1] | type) == "number") |
        ["s", (.[0] | peer), .[1]])
      | @tsv
    ' <<< "${dump}" 2>/dev/null)
  node_peer_state_available=true
  # Only connections the node still has are kept for the next analysis.
  for key in "${!nodeRemoteTemp[@]}"; do
    [[ -n ${nodeConnUse[${key}]+set} ]] || continue
    kept+=("peer"$'\t'"${key}"$'\t'"${nodeRemoteTemp[${key}]}")
  done
  saveNodePeerLog "${kept[@]}"
}

getAmaruPeerState() {
  local record conn remote_addr ip port local_port peer_key local_temp remote_temp
  local -a fields=() kept=()
  local -A conn_local=() conn_remote=() conn_record=() live=()
  readNodePeerLog '
      def peer_key:
        capture("^\\[?(?<ip>.*?)\\]?:(?<port>[0-9]+)$") | "\(.ip | sub("^::ffff:"; ""));\(.port)";
      def first_delivery($list; $hash; $peer):
        if any(.[$list][]; .[0] == $hash) then . else .[$list] = (.[$list] + [[$hash, $peer]])[-180:] end;
      def log_init: {conns: {}, headers: [], blocks: []};
      def log_restore($f):
        if $f[0] == "conn" and ($f | length) == 5 then .conns[$f[1]] = {id: $f[2], local: $f[3], remote: $f[4]}
        elif $f[0] == "first" and ($f | length) == 4 and ($f[1] == "header" or $f[1] == "block") then
          .["\($f[1])s"] += [[$f[2], $f[3]]]
        else . end;
      def log_step($line):
        (($line | capture(" amaru::[a-z_]+: (?<event>[a-z_.]+) (?<fields>.*)$")) // null) as $m |
        if $m == null then .
        else
          ([$m.fields | match("([a-z_]+)=(?:\"([^\"]*)\"|([^ ]*))"; "g") |
            {(.captures[0].string): (.captures[1].string // .captures[2].string)}] | add // {}) as $v |
          (((($v.peer // "") | peer_key)) // null) as $peer |
          if $peer == null then .
          elif $m.event == "manager.peer.handshake_completed" then
            .conns[$peer] = {id: $v.conn_id, local: "none", remote: "none"}
          elif $m.event == "manager.peer.local_use_applied" and (.conns[$peer].id // $v.conn_id) == $v.conn_id then
            .conns[$peer] = (.conns[$peer] // {id: $v.conn_id, remote: "none"}) + {local: $v.local_use}
          elif $m.event == "peer_selection.peer.remote_use" and (.conns[$peer].id // $v.conn_id) == $v.conn_id then
            .conns[$peer] = (.conns[$peer] // {id: $v.conn_id, local: "none"}) + {remote: $v.remote_use}
          elif $m.event == "header.announced" and $v.rank == "1" then first_delivery("headers"; $v.header_hash; $peer)
          elif $m.event == "block.received" and $v.rank == "1" then first_delivery("blocks"; $v.header_hash; $peer)
          else . end
        end;
      def log_records:
        (.conns | to_entries[] |
          ["conn", .key, (.value.id // "-" | tostring), (.value.local // "none"), (.value.remote // "none")]),
        (.headers[] | ["first", "header", (.[0] // "-"), .[1]]),
        (.blocks[] | ["first", "block", (.[0] // "-"), .[1]]);
    ' ' manager.peer.handshake_completed
 manager.peer.local_use_applied
 peer_selection.peer.remote_use
 amaru::blockperf: header.announced
 amaru::blockperf: block.received ' "$@"
  [[ -n ${node_log_cursor} ]] || return 0
  for record in "${node_log_records[@]}"; do
    IFS=$'\t' read -r -a fields <<< "${record}"
    case ${fields[0]} in
      conn) # peer, connection id, the node's use, the peer's use
        conn_local[${fields[1]}]=${fields[3]}
        conn_remote[${fields[1]}]=${fields[4]}
        conn_record[${fields[1]}]=${record} ;;
      first) # header or block, its hash, the peer that delivered it first
        nodePeerScore[${fields[3]}]=$(( ${nodePeerScore[${fields[3]}]:-0} + 1 ))
        kept+=("${record}") ;;
    esac
  done
  for conn in ${peers_in} ${peers_out}; do
    remote_addr="${conn%%|*}"
    local_port="${conn##*:}"
    port="${remote_addr##*:}"
    ip="${remote_addr%:*}"
    ip="${ip#[}"
    ip="${ip%]}"
    peer_key="${ip#::ffff:};${port}"
    [[ -n ${conn_record[${peer_key}]+set} ]] || continue
    case ${conn_local[${peer_key}]} in diffusion) local_temp=H ;; maintenance) local_temp=W ;; *) local_temp="" ;; esac
    case ${conn_remote[${peer_key}]} in diffusion) remote_temp=H ;; maintenance) remote_temp=W ;; *) remote_temp="" ;; esac
    if [[ -n ${local_temp} && -n ${remote_temp} ]]; then nodeConnUse["${peer_key};${local_port}"]=dup
    elif [[ -n ${local_temp} ]]; then nodeConnUse["${peer_key};${local_port}"]=out
    elif [[ -n ${remote_temp} ]]; then nodeConnUse["${peer_key};${local_port}"]=in
    else nodeConnUse["${peer_key};${local_port}"]=idle; fi
    [[ -n ${local_temp} ]] && nodePeerTemp[${peer_key}]=${local_temp}
    [[ -n ${remote_temp} ]] && nodeRemoteTemp["${peer_key};${local_port}"]=${remote_temp}
    live[${peer_key}]=1
  done
  # Only connections the node still has are kept for the next analysis.
  for peer_key in "${!live[@]}"; do
    kept+=("${conn_record[${peer_key}]}")
  done
  node_peer_state_available=true
  saveNodePeerLog "${kept[@]}"
}

readNodePeerLog() {
  local definitions="$1" patterns="$2" kind rest state_run="" cursor="" saved="" new_cursor status now elapsed pass line
  local -a read_from=() records=()
  shift 2
  node_log_run="${CNODE_PID}:$(ps -o lstart= -p "${CNODE_PID}" 2>/dev/null)"
  node_log_cursor=""
  node_log_records=()
  if [[ -r ${PEER_STATE_FILE} ]]; then
    while IFS=$'\t' read -r kind rest; do
      case ${kind} in
        run)       state_run=${rest} ;;
        cursor)    cursor=${rest} ;;
        ''|'#'*)   ;;
        *)         saved+="-- saved: ${kind}"$'\t'"${rest}"$'\n' ;;
      esac
    done < "${PEER_STATE_FILE}"
  fi
  [[ ${state_run} = "${node_log_run}" && -n ${cursor} ]] && read_from=(--after-cursor "${cursor}")
  for pass in 1 2; do
    if [[ ${#read_from[@]} -eq 0 ]]; then
      saved=""
      printf -v now '%(%s)T' -1
      elapsed="$(ps -o etimes= -p "${CNODE_PID}" 2>/dev/null)"
      elapsed="${elapsed//[^0-9]/}"
      read_from=(--since "@$(( now - ${elapsed:-0} - 1 ))")
      peerAnalysisStatus "Reading the node's log since it started..."
    fi
    records=()
    new_cursor=""
    status=""
    # The saved records come first, and the cursor and journalctl's exit
    # status pass through as the last lines.
    while IFS= read -r line; do
      case ${line} in
        cursor$'\t'*) new_cursor=${line#*$'\t'} ;;
        status$'\t'*) status=${line#*$'\t'} ;;
        *)            records+=("${line}") ;;
      esac
    done < <(
      { printf '%s' "${saved}"
        journalctl -q -o cat --no-pager --show-cursor "$@" "${read_from[@]}" 2>/dev/null
        printf -- '-- status: %s\n' "$?"
      } |
        grep -F -e "${patterns}" -e '-- saved: ' -e '-- cursor: ' -e '-- status: ' |
        jq -Rrn "${definitions}"'
          def last_line($prefix): map(select(startswith($prefix)) | ltrimstr($prefix)) | last // "";
          [inputs] as $lines |
          reduce ($lines[] | select(startswith("-- saved: ")) | ltrimstr("-- saved: ") | split("\t")) as $fields
            (log_init; log_restore($fields)) |
          reduce ($lines[] | select(startswith("-- ") | not)) as $line (.; log_step($line)) |
          (log_records | @tsv),
          (["cursor", ($lines | last_line("-- cursor: "))] | @tsv),
          (["status", ($lines | last_line("-- status: "))] | @tsv)
        ' 2>/dev/null
    )
    # A saved cursor that fails gets a second pass, from the start.
    [[ ${status} = 0 || ${read_from[0]} = --since ]] && break
    read_from=()
  done
  [[ ${read_from[0]} = --since ]] && peerAnalysisStatus "Peer analysis started... please wait!"
  [[ ${status} = 0 ]] || return 0
  # Without new lines, journalctl may print no cursor.
  node_log_cursor="${new_cursor:-${cursor}}"
  node_log_records=("${records[@]}")
}

saveNodePeerLog() {
  local state_tmp
  [[ -n ${node_log_cursor} ]] || return 0
  state_tmp="$(mktemp "${PEER_STATE_FILE}.XXXXXX" 2>/dev/null)" || return 0
  {
    printf '%s\n' "# gLiveView peer analysis: the node's connections, from its log"
    printf 'run\t%s\n' "${node_log_run}"
    printf 'cursor\t%s\n' "${node_log_cursor}"
    [[ $# -eq 0 ]] || printf '%s\n' "$@"
  } > "${state_tmp}" && mv -f -- "${state_tmp}" "${PEER_STATE_FILE}" || rm -f -- "${state_tmp}"
}


# glv_peers_static_capable: whether this node has peers it was told to use.
# cardano-node lists them in its topology file, Amaru gets them at start-up.
glv_peers_static_capable() {
  node_has topology_file || [[ "${NODE_IMPLEMENTATION:-}" == amaru ]]
}

# glv_peers_static_amaru: Amaru's static peers are the --peer options it was
# started with, on the command line or in AMARU_PEER. Fills staticPeerList the
# way getStaticPeers does for a topology file; the host name is the label.
glv_peers_static_amaru() {
  local word previous='' value host port label ips
  local -a arguments=() given=()
  staticPeerList=()
  [[ -n "${D_PID}" ]] || return 0
  if [[ -r "/proc/${D_PID}/cmdline" ]]; then
    mapfile -d '' -t arguments < "/proc/${D_PID}/cmdline"
    for word in "${arguments[@]}"; do
      case "${word}" in
        --peer=*) given+=("${word#--peer=}"); previous='' ;;
        --*) previous="${word}" ;;
        *) [[ "${previous}" != --peer ]] || given+=("${word}") ;;
      esac
    done
  fi
  if (( ${#given[@]} == 0 )) && [[ -r "/proc/${D_PID}/environ" ]]; then
    while IFS= read -r -d '' word; do
      [[ "${word}" != AMARU_PEER=* ]] || value="${word#AMARU_PEER=}"
    done < "/proc/${D_PID}/environ"
    # Several peers are separated by commas or spaces.
    read -r -a given <<< "${value//,/ }"
  fi
  for word in "${given[@]}"; do
    [[ -n "${word}" ]] || continue
    if [[ "${word}" == \[*\]:* ]]; then host="${word%%]:*}"; host="${host#[}"; port="${word##*]:}"
    elif [[ "${word}" == *:* && "${word}" != *:*:* ]]; then host="${word%:*}"; port="${word##*:}"
    else host="${word}"; port=''; fi
    label=''
    [[ "${host}" =~ ^[0-9.]+$ || "${host}" == *:* ]] || label="${host}"
    ips="$(resolvePeerAddress "${host}")"
    staticPeerList+=("${host};${port};${label};${ips}")
  done
}

# What the log readers print as progress goes to the page's status line.
peerAnalysisStatus() { printf '%s\n' "$1" > "${PEER_JOB_FILE}.status" 2>/dev/null || true; }

# Asks ip-api.com for the city and country of addresses not looked up before,
# 100 per request as the service allows. Prints one "g" record for each answer.
glv_peers_geo_lookup() {
  local start batch answer
  local -a queue=("$@")
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  for ((start = 0; start < ${#queue[@]} && start < 1500; start += 100)); do
    batch="$(printf '%s\n' "${queue[@]:start:100}" |
      jq -Rnc '[inputs | {query: ., fields: "status,city,countryCode,query"}]')" || continue
    answer="$(curl -s -f -m 10 http://ip-api.com/batch --data "${batch}")" || continue
    jq -r '.[] | select(.status == "success" and (.query | type) == "string") |
        ["g", .query, "\(.city // "?"), \(.countryCode // "?")"] | @tsv' <<< "${answer}" 2>/dev/null
  done
}

# glv_peers_job_run: the whole analysis, run in a background subshell. Prints
# records, one per line and tab separated: c, t, r and s for the four state
# maps, S for a static peer, g for a location, and "ok" last.
glv_peers_job_run() {
  local entry rest address port local_port key now
  local -a lookup=()
  local -A queued=()
  CNODE_PID="${D_PID}"
  PEER_STATE_FILE="${GLV_PEER_STATE_FILE}"
  ENABLE_NODE_PEER_STATE="${ENABLE_NODE_PEER_STATE:-Y}"
  peers_in=''
  peers_out=''
  peerAnalysisStatus "Reading the node's connections…"
  glv_data_peers
  for entry in "${D_PEERS[@]}"; do
    rest="${entry#*|}"; rest="${rest#*|}"
    address="${rest%%|*}"; rest="${rest#*|}"
    port="${rest%%|*}"; local_port="${rest#*|}"
    if [[ "${address}" == *:* ]]; then key="[${address}]:${port}|:${local_port}"; else key="${address}:${port}|:${local_port}"; fi
    peers_in+="${key} "
    if [[ "${ENABLE_IP_GEOLOCATION:-Y}" == Y && -z "${geoIP[${address}]+known}" &&
          -z "${queued[${address}]+queued}" ]] && ! isPrivateIP "${address}"; then
      queued["${address}"]=1
      lookup+=("${address}")
    fi
  done

  getNodePeerState
  for key in "${!nodeConnUse[@]}"; do printf 'c\t%s\t%s\n' "${key}" "${nodeConnUse[${key}]}"; done
  for key in "${!nodePeerTemp[@]}"; do printf 't\t%s\t%s\n' "${key}" "${nodePeerTemp[${key}]}"; done
  for key in "${!nodeRemoteTemp[@]}"; do printf 'r\t%s\t%s\n' "${key}" "${nodeRemoteTemp[${key}]}"; done
  for key in "${!nodePeerScore[@]}"; do printf 's\t%s\t%s\n' "${key}" "${nodePeerScore[${key}]}"; done

  if glv_peers_static_capable; then
    peerAnalysisStatus "Resolving the node's static peers…"
    if node_has topology_file; then getStaticPeers; else glv_peers_static_amaru; fi
    for entry in "${staticPeerList[@]}"; do printf 'S\t%s\n' "${entry}"; done
  fi
  if (( ${#lookup[@]} > 0 )); then
    peerAnalysisStatus "Looking up ${#lookup[@]} locations…"
    glv_peers_geo_lookup "${lookup[@]}"
  fi
  printf -v now '%(%s)T' -1
  printf 'ok\t%s\t%s\n' "${now}" "${node_peer_state_available}"
}

# glv_peers_job_start: starts the analysis unless one is running.
glv_peers_job_start() {
  [[ -z "${PEER_JOB_PID}" ]] || return 0
  [[ -n "${D_PID}" ]] || { PEER_JOB_NOTE="The node is not running."; return 0; }
  rm -f -- "${PEER_JOB_FILE}" "${PEER_JOB_FILE}.part" "${PEER_JOB_FILE}.status"
  PEER_JOB_NOTE="Starting…"
  (
    glv_peers_job_run > "${PEER_JOB_FILE}.part" 2>/dev/null
    mv -f -- "${PEER_JOB_FILE}.part" "${PEER_JOB_FILE}"
  ) < /dev/null > /dev/null 2>&1 &
  PEER_JOB_PID=$!
}

# glv_peers_job_poll: shows the job's progress, and loads its records once it
# is done. Never waits.
glv_peers_job_poll() {
  local kind first second ok=N
  [[ -n "${PEER_JOB_PID}" ]] || return 0
  if [[ ! -f "${PEER_JOB_FILE}" ]]; then
    if kill -0 "${PEER_JOB_PID}" 2>/dev/null; then
      [[ ! -r "${PEER_JOB_FILE}.status" ]] || read -r PEER_JOB_NOTE < "${PEER_JOB_FILE}.status" || true
      return 0
    fi
    [[ -f "${PEER_JOB_FILE}" ]] || { PEER_JOB_PID=''; PEER_JOB_NOTE="The analysis stopped before it finished."; return 0; }
  fi
  nodeConnUse=(); nodePeerTemp=(); nodeRemoteTemp=(); nodePeerScore=()
  staticPeer=(); staticPeerPort=(); staticPeerEntries=(); staticPeerList=()
  while IFS=$'\t' read -r kind first second; do
    case "${kind}" in
      c) nodeConnUse["${first}"]="${second}" ;;
      t) nodePeerTemp["${first}"]="${second}" ;;
      r) nodeRemoteTemp["${first}"]="${second}" ;;
      s) nodePeerScore["${first}"]="${second}" ;;
      g) geoIP["${first}"]="${second}" ;;
      S) staticPeerList+=("${first}")
         # address;port;label;ip,ip
         glv_peers_static_index "${first}" ;;
      ok) ok=Y; PEER_STATE_AT="${first}"; node_peer_state_available="${second}" ;;
    esac
  done < "${PEER_JOB_FILE}"
  rm -f -- "${PEER_JOB_FILE}" "${PEER_JOB_FILE}.status"
  PEER_JOB_PID=''
  PEER_JOB_NOTE=''
  [[ "${ok}" == Y ]] || PEER_JOB_NOTE="The analysis did not finish."
  glv_peers_geo_save
}

# glv_peers_static_index <address;port;label;ip,ip>: files one static peer
# under each of its addresses, as getStaticPeers does.
glv_peers_static_index() {
  local entry="$1" port label ips ip port_key
  entry="${entry#*;}"
  port="${entry%%;*}"; entry="${entry#*;}"
  label="${entry%%;*}"; ips="${entry#*;}"
  for ip in ${ips//,/ }; do
    port_key="${ip};${port}"
    staticPeerPort["${port_key}"]="${label}"
    staticPeerEntries["${ip}"]=$(( ${staticPeerEntries[${ip}]:-0} + 1 ))
    if [[ -z "${staticPeer[${ip}]:-}" ]]; then
      staticPeer["${ip}"]="${label}"
    elif [[ -n "${label}" && " / ${staticPeer[${ip}]} / " != *" / ${label} / "* ]]; then
      staticPeer["${ip}"]+=" / ${label}"
    fi
  done
}

# Locations are kept between runs, so each address is asked for once.
glv_peers_geo_load() {
  local ip place
  [[ -r "${GLV_PEER_GEO_FILE}" ]] || return 0
  while IFS=$'\t' read -r ip place; do
    [[ -z "${ip}" ]] || geoIP["${ip}"]="${place}"
  done < "${GLV_PEER_GEO_FILE}"
}

glv_peers_geo_save() {
  local ip
  (( ${#geoIP[@]} > 0 )) || return 0
  for ip in "${!geoIP[@]}"; do printf '%s\t%s\n' "${ip}" "${geoIP[${ip}]}"; done > "${GLV_PEER_GEO_FILE}" 2>/dev/null || true
}

glv_peers_cleanup() {
  [[ -z "${PEER_JOB_PID}" ]] || kill "${PEER_JOB_PID}" 2>/dev/null || true
  rm -f -- "${PEER_JOB_FILE:-/nonexistent}" "${PEER_JOB_FILE:-/nonexistent}.part" "${PEER_JOB_FILE:-/nonexistent}.status"
}

# ── per frame, without a fork ────────────────────────────────────────────────
# glv_peer_connection <ip> <remote port> <local port>: how the node says a
# connection is used. Sets PC_USE (out, in, dup, idle or empty when unknown),
# PC_OUT and PC_IN (H, W or empty) for the node's and the peer's side, and
# PC_TEXT for the Conn column. Only a side that uses the connection has a state.
glv_peer_connection() {
  local ip="${1#::ffff:}" key
  key="${ip};$2;${3:--}"
  PC_USE="${nodeConnUse[${key}]:-}"
  PC_IN=''
  case "${PC_USE}" in
    in|dup) PC_IN="${nodeRemoteTemp[${key}]:-}"
            [[ "${PC_IN}" == [HW] ]] || PC_IN='' ;;
  esac
  key="${ip};$2"
  PC_OUT=''
  case "${PC_USE}" in
    out|dup) PC_OUT="${nodePeerTemp[${key}]:-}" ;;
  esac
  case "${PC_USE}" in
    dup) if [[ -n "${PC_IN}" ]]; then PC_TEXT="dup ${PC_OUT:--}/${PC_IN}"; else PC_TEXT="dup ${PC_OUT}"; fi ;;
    out) PC_TEXT="out ${PC_OUT}" ;;
    in)  PC_TEXT="in ${PC_IN}" ;;
    *)   PC_TEXT="${PC_USE}" ;;
  esac
  PC_TEXT="${PC_TEXT% }"
}

# glv_peer_score <ip> <remote port>: sets PC_SCORE to the node's count for the
# peer's address and port, empty when the peer has none.
glv_peer_score() {
  PC_SCORE="${nodePeerScore[${1#::ffff:};$2]:-0}"
  [[ "${PC_SCORE}" != 0 ]] || PC_SCORE=''
}

# glv_peer_matches <ip> <remote port> <local port>: whether a connection passes
# the direction and state filters. Out and in include duplex connections, as
# the node's counters do. The state is the one on the chosen side, or the
# hotter side for All and Duplex.
glv_peer_matches() {
  local state=''
  [[ "${PEER_FILTER_DIR}" != all || "${PEER_FILTER_STATE}" != any ]] || return 0
  glv_peer_connection "$1" "$2" "${3:-}"
  case "${PEER_FILTER_DIR}" in
    out) [[ "${PC_USE}" == out || "${PC_USE}" == dup ]] || return 1
         state="${PC_OUT:--}" ;;
    in)  [[ "${PC_USE}" == in || "${PC_USE}" == dup ]] || return 1
         state="${PC_IN:--}" ;;
    dup) [[ "${PC_USE}" == dup ]] || return 1 ;;
  esac
  if [[ -z "${state}" ]]; then
    if [[ "${PC_OUT}" == H || "${PC_IN}" == H ]]; then state=H
    elif [[ "${PC_OUT}" == W || "${PC_IN}" == W ]]; then state=W
    else state=-; fi
  fi
  case "${PEER_FILTER_STATE}" in
    hot)  [[ "${state}" == H ]] ;;
    warm) [[ "${state}" == W ]] ;;
    *)    return 0 ;;
  esac
}

# glv_peers_select: the connections that pass the search and the filters, in
# PEER_SELECTED as "rtt|ip|port|local port|note", with the round-trip classes
# and the average over them. The note of a connection is the side its socket
# suggests (in or out). With the Static filter, static peers without a
# connection follow, noted x (not connected) or u (name did not resolve); they
# are not part of the round-trip figures.
glv_peers_select() {
  local entry rest rtt side address port local_port key search="${PEER_SEARCH,,}" sum=0 reachable
  local static_entry static_address static_port static_ips ip connected note
  local -A seen=()
  PEER_SELECTED=()
  PEER_COUNT=(0 0 0 0 0)
  PEER_AVERAGE=''
  if [[ "${node_peer_state_available}" != true ]]; then
    PEER_FILTER_DIR=all
    PEER_FILTER_STATE=any
  fi
  for entry in "${D_PEERS[@]}"; do
    rtt="${entry%%|*}"; rest="${entry#*|}"
    side="${rest%%|*}"; rest="${rest#*|}"
    address="${rest%%|*}"; rest="${rest#*|}"
    port="${rest%%|*}"; local_port="${rest#*|}"
    key="${address#::ffff:}"
    seen["${key}"]=1
    seen["${key};${port}"]=1
    if [[ -n "${search}" ]]; then
      [[ "${address,,}:${port}" == *"${search}"* ]] || continue
    fi
    # Static peers match by address: a peer that connects to the node can use
    # another port than the one in the topology.
    if [[ "${PEER_FILTER_STATIC}" == static ]]; then
      [[ -n "${staticPeer[${key}]+set}" ]] || continue
    fi
    glv_peer_matches "${address}" "${port}" "${local_port}" || continue
    PEER_SELECTED+=("${rtt}|${address}|${port}|${local_port}|${side}")
    if (( rtt >= 999999 )); then PEER_COUNT[4]=$((PEER_COUNT[4] + 1))
    else
      sum=$((sum + rtt))
      if (( rtt < 500 )); then PEER_COUNT[0]=$((PEER_COUNT[0] + 1))
      elif (( rtt < 1000 )); then PEER_COUNT[1]=$((PEER_COUNT[1] + 1))
      elif (( rtt < 2000 )); then PEER_COUNT[2]=$((PEER_COUNT[2] + 1))
      else PEER_COUNT[3]=$((PEER_COUNT[3] + 1)); fi
    fi
  done
  reachable=$((${#PEER_SELECTED[@]} - PEER_COUNT[4]))
  (( reachable == 0 )) || PEER_AVERAGE=$((sum / reachable / 10))

  # Static peers without a connection have no direction or state to filter on.
  [[ "${PEER_FILTER_STATIC}" == static && "${PEER_FILTER_DIR}" == all &&
     "${PEER_FILTER_STATE}" == any ]] || return 0
  for static_entry in "${staticPeerList[@]}"; do
    static_address="${static_entry%%;*}"; rest="${static_entry#*;}"
    static_port="${rest%%;*}"; rest="${rest#*;}"
    static_ips="${rest#*;}"
    connected=N
    for ip in ${static_ips//,/ }; do
      # On an address that several access points share, only a connection on
      # the entry's own port counts; otherwise any port does.
      if [[ -n "${seen[${ip};${static_port}]+set}" ]] ||
         { (( ${staticPeerEntries[${ip}]:-0} <= 1 )) && [[ -n "${seen[${ip}]+set}" ]]; }; then
        connected=Y
      fi
    done
    [[ "${connected}" == N ]] || continue
    if [[ -n "${search}" ]]; then
      [[ "${static_address,,}:${static_port} ${static_ips,,}" == *"${search}"* ]] || continue
    fi
    note=x
    [[ -n "${static_ips}" ]] || note=u
    PEER_SELECTED+=("999999|${static_address}|${static_port}||${note}")
  done
}

# glv_peer_label <ip> <port>: sets PEER_LABEL to the static peer's label, or
# the location of the address, and PEER_LABEL_KIND to static, private, place
# or none.
glv_peer_label() {
  local ip="${1#::ffff:}"
  PEER_LABEL=''
  PEER_LABEL_KIND=none
  if [[ -n "${staticPeerPort[${ip};$2]+set}" ]]; then PEER_LABEL="${staticPeerPort[${ip};$2]}"
  else PEER_LABEL="${staticPeer[${ip}]:-}"; fi
  if [[ -n "${PEER_LABEL}" ]]; then PEER_LABEL_KIND=static; return 0; fi
  if [[ -n "${staticPeer[${ip}]+set}" ]]; then PEER_LABEL="static peer"; PEER_LABEL_KIND=static; return 0; fi
  if [[ "${ip}" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|f[cd][0-9a-f]{2}:|fe80:|::1$) ]]; then
    PEER_LABEL="private address"; PEER_LABEL_KIND=private; return 0
  fi
  if [[ -n "${geoIP[${ip}]:-}" ]]; then PEER_LABEL="${geoIP[${ip}]}"; PEER_LABEL_KIND=place; fi
}

##############################################################################
# Pages beside the overview
##############################################################################
# The pages beside the overview: Chain, Peers, Production, System, Logs and
# Node & network. Each page is given the width of the main area and fills it band by band; the last
# panel takes what height is left and scrolls with PgUp and PgDn.

PAGE_SCROLL=0
PAGE_TOTAL=0
# Tab moves the focus from the list of pages to the lists on the page, one
# after the other, and back. While a list has it, up and down scroll that
# list. PAGE_LISTS names the panels that hold each page's lists, in the order
# Tab visits them (the Node & network page scrolls as a whole, so it has none
# to mark), and PAGE_FOCUS_AT which of them has the focus.
PAGE_FOCUS=N
PAGE_FOCUS_AT=0
PAGE_FOCUSABLE=('' N Y Y Y N Y Y)
PAGE_LISTS=('' '' recent peerlist "schedule history" '' log '')

# glv_focus_key: GLV_FOCUS_KEY names the list that has the focus, or is empty.
glv_focus_key() {
  local -a lists=()
  GLV_FOCUS_KEY=''
  [[ "${PAGE_FOCUS}" == Y ]] || return 0
  read -r -a lists <<< "${PAGE_LISTS[VIEW]}"
  GLV_FOCUS_KEY="${lists[PAGE_FOCUS_AT]:-${lists[0]:-}}"
}

# glv_focus_on_screen <key>: whether that list was drawn in the last frame.
glv_focus_on_screen() {
  local key
  for key in "${UI_PANELS[@]}"; do [[ "${key}" != "$1" ]] || return 0; done
  return 1
}

# glv_focus_after: whether a list after the focused one is on screen, so that
# Tab moves to it rather than back to the pages.
glv_focus_after() {
  local -a lists=()
  local i
  read -r -a lists <<< "${PAGE_LISTS[VIEW]}"
  for ((i = PAGE_FOCUS_AT + 1; i < ${#lists[@]}; i++)); do
    ! glv_focus_on_screen "${lists[i]}" || return 0
  done
  return 1
}

# glv_focus_available: whether Tab has a list to go to on this page. The Node
# & network page scrolls as a whole, so it always has.
glv_focus_available() {
  local -a lists=()
  local key
  [[ "${PAGE_FOCUSABLE[VIEW]}" == Y ]] || return 1
  read -r -a lists <<< "${PAGE_LISTS[VIEW]}"
  (( ${#lists[@]} > 0 )) || return 0
  for key in "${lists[@]}"; do ! glv_focus_on_screen "${key}" || return 0; done
  return 1
}

# glv_focus_next: Tab. The focus goes to the next list on screen, and from the
# last one back to the pages.
glv_focus_next() {
  local -a lists=()
  local i=0
  read -r -a lists <<< "${PAGE_LISTS[VIEW]}"
  if (( ${#lists[@]} == 0 )); then
    if [[ "${PAGE_FOCUS}" == Y ]]; then PAGE_FOCUS=N; else PAGE_FOCUS=Y; fi
    return 0
  fi
  [[ "${PAGE_FOCUS}" != Y ]] || i=$((PAGE_FOCUS_AT + 1))
  for ((; i < ${#lists[@]}; i++)); do
    if glv_focus_on_screen "${lists[i]}"; then PAGE_FOCUS=Y; PAGE_FOCUS_AT="${i}"; return 0; fi
  done
  PAGE_FOCUS=N
  PAGE_FOCUS_AT=0
}

# glv_focus_scroll <lines> [page]: scrolls the list that has the focus, or
# the page's first list when none has. The epoch history moves by epochs, a
# page at a time by as many as it shows, and asks Koios at once for what
# comes into view.
glv_focus_scroll() {
  local limit
  glv_focus_key
  if [[ "${GLV_FOCUS_KEY}" != history ]]; then
    PAGE_SCROLL=$((PAGE_SCROLL + $1))
    return 0
  fi
  if [[ "${2:-}" != page ]]; then HIST_SCROLL=$((HIST_SCROLL + $1))
  elif (( $1 < 0 )); then HIST_SCROLL=$((HIST_SCROLL - HIST_SHOWN))
  else HIST_SCROLL=$((HIST_SCROLL + HIST_SHOWN)); fi
  limit=$((HIST_ROWS_TOTAL - HIST_SHOWN))
  (( limit >= 0 )) || limit=0
  (( HIST_SCROLL <= limit )) || HIST_SCROLL="${limit}"
  (( HIST_SCROLL >= 0 )) || HIST_SCROLL=0
  glv_history_tick
}
LOG_LEVEL=0
LOG_PAUSED=N       # Y keeps the lines that are loaded and reads no new ones
LOG_PAUSED_AT=''
LOG_FIND=''        # pattern for the time, the source and the message
LOG_SHIFT=0        # columns a long line is moved to the left
LOG_I_TIME=()
LOG_I_LEVEL=()
LOG_I_TAG=()
LOG_I_TEXT=()
LOG_LEVEL_NAMES=("all" "notices and up" "warnings and up" "errors")
LOG_LEVEL_FLOOR=(0 2 3 4)

# glv_page_window <rows on screen>: keeps PAGE_SCROLL inside the list and puts
# the position in the footer when the list is longer than its panel.
glv_page_window() {
  local rows="$1" limit last
  limit=$((PAGE_TOTAL - rows))
  (( limit >= 0 )) || limit=0
  (( PAGE_SCROLL <= limit )) || PAGE_SCROLL="${limit}"
  (( PAGE_SCROLL >= 0 )) || PAGE_SCROLL=0
  if (( PAGE_TOTAL > rows )); then
    last=$((PAGE_SCROLL + rows))
    GLV_FOOTER_NOTE="rows $((PAGE_SCROLL + 1))-${last} of ${PAGE_TOTAL}"
    GLV_PAGE_KEYS=("${GLV_PAGE_KEYS[@]}" "PgUp/PgDn Page")
  fi
}

# glv_cells_panel <output> <width> <title> <right> <cells> <columns> [rows]
glv_cells_panel() {
  local _cp_width="$2" _cp_columns="$6" _cp_rows="${7:-0}" _cp_inner=$(($2 - 4))
  local -n _cp_cells="$5"
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  (( _cp_rows > 0 )) || _cp_rows=$(( (${#_cp_cells[@]} + _cp_columns - 1) / _cp_columns ))
  (( _cp_rows >= 1 )) || _cp_rows=1
  ui_grid "$5" "${_cp_columns}" "${_cp_rows}" "${_cp_inner}" UI_BODY
  ui_panel "$1" "${_cp_width}" $((_cp_rows + 2)) "$3" "$4"
}

# glv_rows_panel <output> <width> <height or 0> <title> <rows> [right title]
# [colours]: <colours> names an array with a colour for the value of the row
# with the same index; an empty entry keeps the default.
# Rows are "label|value". The label column is as wide as its longest label.
# A value too long for the panel is cut: a path keeps its end, which is the
# part that tells files apart, and anything else keeps its start.
glv_rows_panel() {
  local _rp_width="$2" _rp_height="$3" _rp_inner=$(($2 - 4)) _rp_label=0 _rp_row _rp_value _rp_room _rp_index=0
  local -a _rp_none=()
  local -n _rp_rows="$5" _rp_colours="${7:-_rp_none}"
  for _rp_row in "${_rp_rows[@]}"; do
    _rp_value="${_rp_row%%|*}"
    (( ${#_rp_value} <= _rp_label )) || _rp_label=${#_rp_value}
  done
  _rp_label=$((_rp_label + 2))
  (( _rp_label <= _rp_inner * 3 / 5 )) || _rp_label=$((_rp_inner * 3 / 5))
  _rp_room=$((_rp_inner - _rp_label))
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  for _rp_row in "${_rp_rows[@]}"; do
    _rp_value="${_rp_row#*|}"
    if (( ${#_rp_value} > _rp_room && _rp_room > 1 )); then
      # A path keeps its end, anything else its start.
      if [[ "${_rp_value}" == /* ]]; then _rp_value="…${_rp_value: -$((_rp_room - 1))}"
      else _rp_value="${_rp_value:0:_rp_room-1}…"; fi
    fi
    ui_putw "${C_MUTED}" $((_rp_label - 1)) "${_rp_row%%|*}"
    ui_gap 1
    ui_putw "${_rp_colours[_rp_index]:-}" "${_rp_room}" "${_rp_value}"
    ui_endl UI_BODY "${_rp_inner}"
    _rp_index=$((_rp_index + 1))
  done
  (( _rp_height > 0 )) || _rp_height=$((${#UI_BODY[@]} + 2))
  ui_panel "$1" "${_rp_width}" "${_rp_height}" "$4" "${6:-}"
}

# glv_note_panel <output> <width> <height> <title> <text>: a panel of wrapped text.
glv_note_panel() {
  local _np_inner=$(($2 - 4)) _np_line
  local -a _np_lines=()
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  ui_wrap _np_lines "${_np_inner}" "$5"
  for _np_line in "${_np_lines[@]}"; do
    ui_putw "${C_MUTED}" "${_np_inner}" "${_np_line}"
    ui_endl UI_BODY "${_np_inner}"
  done
  ui_panel "$1" "$2" "$3" "$4" ""
}

# ── 2 Chain ──────────────────────────────────────────────────────────────────
# How the arrival times of the blocks seen so far are spread.
glv_panel_spread() {
  local width="$2" height="$3" inner=$(($2 - 4)) total=${#H_DELAY[@]} delay i bar room
  local -a limit=(500 1000 2000 3000 5000 0) label=("≤ 0.5 s" "≤ 1 s" "≤ 2 s" "≤ 3 s" "≤ 5 s" "> 5 s")
  local -a count=(0 0 0 0 0 0) colour=("${C_OK}" "${C_OK}" "${C_WARN}" "${C_WARN}" "${C_DANGER}" "${C_DANGER}")
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  for delay in "${H_DELAY[@]}"; do
    for i in 0 1 2 3 4 5; do
      if (( limit[i] == 0 || delay <= limit[i] )); then count[i]=$((count[i] + 1)); break; fi
    done
  done
  room=$((inner - 15))
  for i in 0 1 2 3 4 5; do
    ui_putw "${C_MUTED}" 8 "${label[i]}"
    ui_putw '' 5 "${count[i]}" r
    ui_gap 2
    bar=0
    (( total == 0 )) || bar=$((room * count[i] / total))
    (( count[i] == 0 || bar >= 1 )) || bar=1
    ui_put "${colour[i]}" "${UI_BARS:0:bar}"
    ui_endl UI_BODY "${inner}"
  done
  UI_HELP=spread
  ui_panel "$1" "${width}" "${height}" "Block delay spread" "${total} since start"
}

glv_view_chain() {
  local width="$1" third=$(($1 / 3)) half=$(($1 / 2)) seen=0 record
  local -a tip=() traffic=()
  glv_panel_epoch "${width}"
  glv_main_add P_EPOCH

  glv_chain_cells tip
  for record in "${D_ROWS[@]}"; do [[ "${record}" != B\|* ]] || seen=$((seen + 1)); done
  glv_metric_cell traffic mempool_tx "Pending tx"
  glv_metric_cell traffic mempool_bytes "Mempool" bytes
  glv_metric_cell traffic tx_processed "Total tx" int
  glv_metric_cell traffic blocks_served "Blocks served"
  glv_metric_cell traffic blocks_late "Late blocks"
  glv_cell traffic "Blocks seen" "${seen}"
  # The chain cells end with the mempool figures, which have their own tile here.
  tip=("${tip[@]:0:6}")
  if (( width >= 105 )); then
    UI_HELP=chain
    glv_cells_panel P_A "${third}" "Tip" "" tip 1 6
    UI_HELP=traffic
    glv_cells_panel P_B "${third}" "Traffic" "" traffic 1 6
    glv_panel_spread P_C $((width - 2 * third)) 8
    glv_main_add P_A P_B P_C
  else
    UI_HELP=chain
    glv_cells_panel P_A "${half}" "Tip" "" tip 1 6
    glv_panel_spread P_C $((width - half)) 8
    glv_main_add P_A P_C
    UI_HELP=traffic
    glv_cells_panel P_B "${width}" "Traffic" "" traffic 3 2
    glv_main_add P_B
  fi

  glv_main_room
  if (( GLV_ROOM >= 5 )); then
    PAGE_TOTAL=${#D_ROWS[@]}
    glv_page_window $((GLV_ROOM - 3))
    glv_panel_recent "${width}" "${GLV_ROOM}" all "${PAGE_SCROLL}"
    glv_main_add P_RECENT
  fi
}

# ── 3 Peers ──────────────────────────────────────────────────────────────────
# glv_filter_group <label> <key> <current> <value:Text>…: one filter with all
# its choices, the active one highlighted.
glv_filter_group() {
  local current="$3" option
  ui_put "${C_MUTED}" "$1 "
  ui_put "${UI_KEY}" "$2"
  shift 3
  for option in "$@"; do
    ui_gap 1
    if [[ "${option%%:*}" == "${current}" ]]; then
      UI_L+="${CB_SELECT}${UI_BOLD}${C_TEXT} ${option#*:} ${UI_BASE}"
      UI_LW=$((UI_LW + ${#option} - ${#current} + 1))
    else
      ui_put '' "${option#*:}"
    fi
  done
}

glv_view_peers() {
  local width="$1" third=$(($1 / 3)) half=$(($1 / 2)) inner rows entry rest rtt address port local_port note
  local bar room i colour text shown=0 arrangement reachable total state=N sides=N peer number label_width
  local -a cells=() label=("< 50 ms" "< 100 ms" "< 200 ms" "200 ms +")
  local -a tint=("${C_OK}" "${C_OK}" "${C_WARN}" "${C_DANGER}") part=()

  [[ "${node_peer_state_available}" != true ]] || state=Y
  glv_peers_select
  total=${#PEER_SELECTED[@]}
  reachable=$((PEER_COUNT[0] + PEER_COUNT[1] + PEER_COUNT[2] + PEER_COUNT[3]))

  glv_metric_cell cells conn_outgoing "Out"
  glv_metric_cell cells conn_incoming "In"
  glv_metric_cell cells conn_duplex "Used both ways"
  glv_metric_cell cells conn_bi_dir "Can go both ways"
  glv_metric_cell cells conn_uni_dir "One way only"
  glv_metric_cell cells conn_total "Connections"
  glv_cell cells "Root peers" "${D_RAW[peerSelection_RootPeers]:-}"
  if [[ -n "${D_RAW[peerSelection_KnownLocalRootPeers]:-}" ]]; then
    glv_cell cells "Local roots" "${D_RAW[peerSelection_ActiveLocalRootPeers]:-?} of ${D_RAW[peerSelection_KnownLocalRootPeers]} active"
  fi
  glv_cell cells "Incoming idle" "${D_RAW[inboundGovernor_idle]:-}"
  glv_cell cells "Incoming cold" "${D_RAW[inboundGovernor_cold]:-}"

  # A node that reports one connection count has nothing for a tile of its
  # own, so the round-trip tile sits beside the peers tile instead.
  if (( ${#cells[@]} <= 1 )); then
    arrangement=pair
    glv_panel_peers "${half}"
    inner=$((width - half - 4))
  elif (( width >= 105 )); then
    arrangement=three
    glv_panel_peers "${third}"
    UI_HELP=connections
    glv_cells_panel P_B "${third}" "Connections" "" cells 1 5
    inner=$((width - 2 * third - 4))
  else
    arrangement=stack
    glv_panel_peers "${half}"
    UI_HELP=connections
    glv_cells_panel P_B $((width - half)) "Connections" "" cells 1 5
    glv_main_add P_PEERS P_B
    inner=$((width - 4))
  fi
  # Round trips of the connections listed below, so the filters apply here too.
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  room=$((inner - 17))
  for i in 0 1 2 3; do
    ui_putw "${C_MUTED}" 10 "${label[i]}"
    ui_putw '' 5 "${PEER_COUNT[i]}" r
    ui_gap 2
    bar=0
    (( reachable == 0 )) || bar=$((room * PEER_COUNT[i] / reachable))
    (( PEER_COUNT[i] == 0 || bar >= 1 )) || bar=1
    ui_put "${tint[i]}" "${UI_BARS:0:bar}"
    ui_endl UI_BODY "${inner}"
  done
  if [[ "${arrangement}" != stack ]]; then
    ui_putw "${C_MUTED}" 10 "No figure"; ui_putw '' 5 "${PEER_COUNT[4]}" r
    ui_endl UI_BODY "${inner}"
  fi
  text=''
  [[ -z "${PEER_AVERAGE}" ]] || text="average ${PEER_AVERAGE} ms"
  UI_HELP=roundtrip
  case "${arrangement}" in
    pair) ui_panel P_C $((inner + 4)) 7 "Round trip" "${text}"; glv_main_add P_PEERS P_C ;;
    three) ui_panel P_C $((inner + 4)) 7 "Round trip" "${text}"; glv_main_add P_PEERS P_B P_C ;;
    *) ui_panel P_C $((inner + 4)) 6 "Round trip" "${text}"; glv_main_add P_C ;;
  esac

  glv_main_room
  (( GLV_ROOM >= 7 )) || return 0
  inner=$((width - 4))
  GLV_PAGE_KEYS=("a Analyse" "f Find")
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()

  # The filters, on one line when it fits and on two when it does not.
  if glv_peers_static_capable; then
    glv_filter_group "Peers" t "${PEER_FILTER_STATIC}" all:All static:Static
    ui_gap 3
  fi
  if [[ "${state}" == Y ]]; then
    if (( inner < 100 )); then
      ui_put "${C_MUTED}" "Find "; ui_put "${UI_KEY}" "f"; ui_gap 1
      ui_putw "${UI_BOLD}" $((inner - UI_LW)) "${PEER_SEARCH}"
      ui_endl UI_BODY "${inner}"
    fi
    glv_filter_group "Direction" d "${PEER_FILTER_DIR}" all:All out:Out in:In dup:Duplex
    ui_gap 3
    glv_filter_group "State" s "${PEER_FILTER_STATE}" any:Any hot:Hot warm:Warm
    if (( inner >= 100 )); then
      ui_gap 3
      ui_put "${C_MUTED}" "Find "; ui_put "${UI_KEY}" "f"; ui_gap 1
      ui_putw "${UI_BOLD}" $((inner - UI_LW)) "${PEER_SEARCH}"
    fi
  else
    ui_put "${C_MUTED}" "Find "; ui_put "${UI_KEY}" "f"; ui_gap 1
    ui_putw "${UI_BOLD}" $(( inner - UI_LW > 30 ? 30 : inner - UI_LW )) "${PEER_SEARCH}"
  fi
  ui_endl UI_BODY "${inner}"

  for entry in "${D_PEERS[@]}"; do [[ "${entry}" != *"|out|"* ]] || sides=Y; done
  ui_putw "${C_MUTED}" 4 "#" r; ui_gap 1
  ui_putw "${C_MUTED}" 27 "Remote peer"; ui_putw "${C_MUTED}" 9 "RTT" r; ui_gap 2
  if [[ "${state}" == Y ]]; then
    ui_putw "${C_MUTED}" 8 "Conn"; ui_putw "${C_MUTED}" 5 "Score" r; ui_gap 2
  elif [[ "${sides}" == Y ]]; then
    ui_putw "${C_MUTED}" 5 "Dir"
  fi
  label_width=$((inner - UI_LW))
  ui_putw "${C_MUTED}" "${label_width}" "Location or static peer"
  ui_endl UI_BODY "${inner}"

  rows=$((GLV_ROOM - 2 - ${#UI_BODY[@]}))
  PAGE_TOTAL="${total}"
  glv_page_window "${rows}"
  number="${PAGE_SCROLL}"
  for entry in "${PEER_SELECTED[@]:PAGE_SCROLL:rows}"; do
    number=$((number + 1))
    rtt="${entry%%|*}"; rest="${entry#*|}"
    address="${rest%%|*}"; rest="${rest#*|}"
    port="${rest%%|*}"; rest="${rest#*|}"
    local_port="${rest%%|*}"; note="${rest#*|}"
    # A long IPv6 address keeps its ends, which tell hosts apart.
    peer="${address}"
    if [[ "${address}" == *:* ]]; then
      IFS=: read -r -a part <<< "${address}"
      if (( ${#part[@]} > 3 )); then peer="[${part[0]}…${part[-2]}:${part[-1]}]"; else peer="[${address}]"; fi
    fi
    peer+=":${port}"
    (( ${#peer} <= 26 )) || peer="${peer:0:25}…"
    ui_putw "${C_MUTED}" 4 "${number}" r; ui_gap 1
    ui_putw '' 27 "${peer}"
    if (( rtt >= 999999 )); then
      ui_putw "${C_MUTED}" 9 "—" r
    else
      colour="${C_OK}"
      if (( rtt >= 2000 )); then colour="${C_DANGER}"; elif (( rtt >= 1000 )); then colour="${C_WARN}"; fi
      ui_putw "${colour}" 9 "$((rtt / 10)).$((rtt % 10)) ms" r
    fi
    ui_gap 2
    if [[ "${state}" == Y ]]; then
      if [[ "${note}" == [xu] ]]; then
        ui_gap 15
      else
        glv_peer_connection "${address}" "${port}" "${local_port}"
        colour=''
        if [[ "${PC_TEXT}" == *H* ]]; then colour="${C_OK}"; elif [[ "${PC_USE}" == idle || -z "${PC_USE}" ]]; then colour="${C_MUTED}"; fi
        ui_putw "${colour}" 8 "${PC_TEXT:-—}"
        glv_peer_score "${address}" "${port}"
        ui_putw "${C_NUM}" 5 "${PC_SCORE}" r
        ui_gap 2
      fi
    elif [[ "${sides}" == Y ]]; then
      colour="${C_ID}"
      [[ "${note}" == out ]] || colour="${C_NUM}"
      [[ "${note}" == [xu] ]] && ui_gap 5 || ui_putw "${colour}" 5 "${note}"
    fi
    case "${note}" in
      x) ui_putw "${C_DANGER}" "${label_width}" "Not connected" ;;
      u) ui_putw "${C_DANGER}" "${label_width}" "DNS name did not resolve" ;;
      *)
        glv_peer_label "${address}" "${port}"
        if [[ "${port}" == "${local_port}" && "${port}" == "${CNODE_PORT:-}" &&
              "${address}" =~ ^(127[.]|::1$) ]]; then
          # Both ends are the node's own port on this host: the node has
          # dialled itself, through a topology entry left pointing at it. It
          # stays in the list on purpose, as a sign that the topology needs
          # attention.
          [[ "${PEER_LABEL_KIND}" == static ]] || PEER_LABEL=''
          ui_putw "${C_WARN}" "${label_width}" "${PEER_LABEL:+${PEER_LABEL} · }this node itself"
        else
          case "${PEER_LABEL_KIND}" in
            static) ui_putw "${C_ID}" "${label_width}" "${PEER_LABEL}" ;;
            none) [[ -z "${PEER_STATE_AT}" ]] || ui_putw "${C_MUTED}" "${label_width}" "unknown location" ;;
            *) ui_putw "${C_MUTED}" "${label_width}" "${PEER_LABEL}" ;;
          esac
        fi ;;
    esac
    ui_endl UI_BODY "${inner}"
    shown=$((shown + 1))
  done
  if (( shown == 0 )); then
    if ! command -v ss >/dev/null 2>&1; then text="The connection list needs the ss command, which is not installed."
    elif [[ "${PEER_FILTER_STATIC}" == static ]] && (( ${#staticPeerList[@]} == 0 )); then
      text="No static peers known for this node. Press a to read them."
    elif (( ${#D_PEERS[@]} == 0 )); then text="The node has no connections."
    else text="No peers match the filters or the search."; fi
    ui_putw "${C_MUTED}" "${inner}" "${text}"
    ui_endl UI_BODY "${inner}"
  fi

  # What the node itself says about each connection, and how old that is.
  if [[ -n "${PEER_JOB_PID}" ]]; then
    text="${PEER_JOB_NOTE:-working…}"
  elif [[ -n "${PEER_JOB_NOTE}" ]]; then
    text="${PEER_JOB_NOTE}"
  elif [[ -z "${PEER_STATE_AT}" ]]; then
    text="a reads the node's own view of each peer"
  else
    printf -v text '%(%H:%M:%S)T' "${PEER_STATE_AT}"
    if [[ "${state}" == Y ]]; then text="node state from ${text}"
    else text="read ${text} · ${D_IMPL} gave no per-peer state"; fi
  fi
  if [[ -n "${PEER_SEARCH}" || "${PEER_FILTER_STATIC}${PEER_FILTER_DIR}${PEER_FILTER_STATE}" != allallany ]]; then
    text="${total} of ${#D_PEERS[@]} · ${text}"
  else
    text="${total} · ${text}"
  fi
  [[ "${state}" != Y ]] || GLV_PAGE_KEYS+=("d Direction" "s State")
  ! glv_peers_static_capable || GLV_PAGE_KEYS+=("t Static")
  UI_HELP=peerlist
  ui_panel P_LIST "${width}" "${GLV_ROOM}" "Connections · fastest first" "${text}"
  glv_main_add P_LIST
}

# ── 4 Production ─────────────────────────────────────────────────────────────
# glv_status_label <variable> <status>: a block log status as people say it.
glv_status_label() {
  case "$2" in
    heightbattle) printf -v "$1" '%s' "height battle" ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}

# glv_ms_text <variable> <milliseconds>: "0.12 s", "2.60 s", "14 s"
glv_ms_text() {
  if (( $2 < 10000 )); then
    printf -v "$1" '%d.%02d s' $(( $2 / 1000 )) $(( ($2 % 1000) / 10 ))
  else
    printf -v "$1" '%d s' $(( $2 / 1000 ))
  fi
}

# glv_block_note <variable> <slot> <status>: one line on what happened to a
# leader slot, from the block details the validation recorded. Times are as
# this node saw them.
glv_block_note() {
  local -n _bn_note="$1"
  # The locals carry a prefix because the note is written through a nameref.
  local _bn_slot="$2" _bn_status="$3" _bn_reason _bn_forge _bn_win_slot _bn_who _bn_win_ms _bn_lower _bn_gap _bn_into _bn_text=''
  _bn_note=''
  [[ -n "${D_DETAIL[${_bn_slot}]+set}" ]] || return 0
  IFS='|' read -r _bn_reason _bn_forge _bn_win_slot _bn_who _bn_win_ms _bn_lower <<< "${D_DETAIL[${_bn_slot}]}"
  if [[ "${_bn_who}" =~ ^pool1 ]]; then _bn_who="${_bn_who:0:12}…"
  elif [[ "${_bn_who}" =~ ^[0-9a-f]{56}$ ]]; then _bn_who="${_bn_who:0:8}…"
  elif [[ -z "${_bn_who}" ]]; then _bn_who="another pool"; fi
  case "${_bn_status}" in
    heightbattle)
      glv_is_int "${_bn_win_slot}" || return 0
      _bn_gap=$((_bn_win_slot - _bn_slot))
      if (( _bn_gap > 0 )); then
        _bn_note="${_bn_who} ${_bn_gap} s later, same parent"
      else
        _bn_note="${_bn_who} $((-_bn_gap)) s earlier"
        if glv_is_int "${_bn_win_ms}"; then
          _bn_into=$((_bn_win_ms + _bn_gap * 1000))
          glv_ms_text _bn_text "${_bn_into#-}"
          if (( _bn_into > 0 )); then _bn_note+=", reached us ${_bn_text} into our slot"
          else _bn_note+=", reached us ${_bn_text} before our slot"; fi
        else
          _bn_note+=", same parent"
        fi
      fi ;;
    stolen)
      _bn_note="slot battle with ${_bn_who}"
      case "${_bn_lower}" in
        1) _bn_note+=", their VRF lower" ;;
        0) _bn_note+=", our VRF lower" ;;
      esac ;;
    ghosted) [[ "${_bn_reason}" != fork ]] || _bn_note="built on a block that lost a fork" ;;
    missed|invalid)
      case "${_bn_reason}" in
        '') ;;
        woke_late) _bn_note="node woke late" ;;
        tip_ahead) _bn_note="chain tip already past the slot" ;;
        ocert_expired) _bn_note="op cert expired" ;;
        ocert_not_yet_valid) _bn_note="op cert not yet valid" ;;
        parent_not_stored) _bn_note="parent block not stored" ;;
        ledger_tip_changed) _bn_note="ledger tip changed while forging" ;;
        not_led) _bn_note="node found it was not leader" ;;
        NodeCannotForge) _bn_note="node could not forge" ;;
        BlockFromFuture) _bn_note="block from the future, check the clock" ;;
        SlotIsImmutable) _bn_note="slot already immutable" ;;
        NoLedgerState|NoLedgerView) _bn_note="no ledger state for the slot" ;;
        ForgedInvalidBlock) _bn_note="node forged an invalid block" ;;
        *) _bn_note="${_bn_reason//_/ }" ;;
      esac ;;
  esac
  if glv_is_int "${_bn_forge}"; then
    glv_ms_text _bn_text "${_bn_forge}"
    _bn_note+="${_bn_note:+ · }forged in ${_bn_text}"
  fi
}

glv_schedule_time() {
  if [[ -n "${BLOCKLOG_TZ:-}" ]]; then
    TZ="${BLOCKLOG_TZ}" printf -v "$1" '%(%a %d %H:%M:%S)T' "$2"
  else
    printf -v "$1" '%(%a %d %H:%M:%S)T' "$2"
  fi
}

# glv_pool_age <variable>: how old the last answer from Koios is.
glv_pool_age() {
  local -n _age_out="$1"
  local _age_seconds=$(( ${D_NOW:-0} - POOL_FETCHED_AT ))
  if (( _age_seconds < 60 )); then _age_out="just now"
  elif (( _age_seconds < 3600 )); then _age_out="$((_age_seconds / 60)) min ago"
  else _age_out="$((_age_seconds / 3600)) h ago"; fi
}

# glv_panel_pool <width>: the pool as Koios sees it, in P_POOL, or a note on
# why there is nothing to show.
glv_panel_pool() {
  local width="$1" inner=$(($1 - 4)) pool_title="Pool" right='' text value colour age saturation=0 margin=0
  local -a cells=() note=()
  if [[ "${POOL_STATE}" == ok || "${POOL_STATE}" == stale ]]; then
    [[ -z "${POOL_INFO[ticker]}" ]] || pool_title+=" · ${POOL_INFO[ticker]}"
    [[ -z "${POOL_INFO[name]}" ]] || pool_title+=" · ${POOL_INFO[name]}"
    [[ -n "${POOL_INFO[ticker]}${POOL_INFO[name]}" ]] || pool_title+=" · ${POOL_ID_B32:0:20}…"
    # Three columns, filled one column at a time.
    glv_ada_short value "${POOL_INFO[live_stake]}"; glv_cell cells "Live stake" "${value} ₳"
    glv_ada_short value "${POOL_INFO[active_stake]}"; glv_cell cells "Active stake" "${value} ₳"
    ui_scale margin "${POOL_INFO[margin]}" 3 || margin=0
    ui_fmt_tenths value "${margin}"; glv_cell cells "Margin" "${value} %"
    ui_scale saturation "${POOL_INFO[saturation]}" 1 || saturation=0
    colour=''
    (( saturation < 1000 )) || colour=C_WARN
    ui_fmt_tenths value "${saturation}"; glv_cell cells "Saturation" "${value} %" "${colour}"
    glv_ada_short value "${POOL_INFO[pledge]}"; glv_cell cells "Pledge" "${value} ₳"
    glv_ada_int value "${POOL_INFO[fixed_cost]}"; glv_cell cells "Fixed cost" "${value}"
    ui_fmt_int value "${POOL_INFO[delegators]}"; glv_cell cells "Delegators" "${value:-—}"
    glv_ada_short text "${POOL_INFO[live_pledge]}"
    if glv_is_int "${POOL_INFO[pledge]}" && glv_is_int "${POOL_INFO[live_pledge]}" &&
       (( ${POOL_INFO[live_pledge]} < ${POOL_INFO[pledge]} )); then
      glv_cell cells "Live pledge" "${text} ₳ ✗" C_DANGER
    else
      glv_cell cells "Live pledge" "${text} ₳ ✓" C_OK
    fi
    ui_fmt_int value "${POOL_INFO[blocks]}"; glv_cell cells "Lifetime blocks" "${value:-—}"
    if [[ "${POOL_STATE}" == stale ]]; then
      printf -v text '%(%H:%M)T' "${POOL_FETCHED_AT}"
      right="Koios not answering · data from ${text}"
    else
      glv_pool_age age
      text="${POOL_INFO[status]:-}"
      ! glv_is_int "${POOL_INFO[retiring]}" || text="retiring after epoch ${POOL_INFO[retiring]}"
      right="${text:+${text} · }Koios ${age}"
    fi
    UI_HELP=pool
    glv_cells_panel P_POOL "${width}" "${pool_title}" "${right}" cells 3 3
    return 0
  fi
  case "${POOL_STATE}" in
    nokoios)
      if [[ "${ENABLE_KOIOS:-Y}" != Y ]]; then
        text="Koios is turned off in env (ENABLE_KOIOS=N), so there is no pool data."
      else
        text="There is no Koios service for this network, so there is no pool data."
      fi ;;
    none)
      text="No pool ID: set POOL_ID at the top of gLiveView.sh, or keep ${POOL_ID_FILENAME:-pool.id}-bech32 in the pool folder ${POOL_FOLDER:-}/${POOL_NAME:-}." ;;
    unknown) text="Koios does not know pool ${POOL_ID_B32}. It may not be registered yet, or be on another network." ;;
    failed)
      printf -v value '%(%H:%M)T' "${POOL_FAILED_AT}"
      text="${POOL_NOTE:-Koios did not answer} at ${value}. gLiveView asks again every minute." ;;
    *) text="Asking Koios for the pool's data…" ;;
  esac
  ui_wrap note "${inner}" "${text}"
  UI_HELP=pool
  glv_note_panel P_POOL "${width}" $((${#note[@]} + 2)) "Pool" "${text}"
}

# glv_panel_history <width> <height>: the pool's epochs, newest first, in
# P_HISTORY. The columns that matter least leave first on a narrow terminal.
glv_panel_history() {
  local width="$1" height="$2" inner=$(($1 - 4)) rows=$(($2 - 3)) wide=N entry kind e stake deleg led
  local blocks ideal fees rewards ros value colour first='' last='' luck right
  (( inner >= 84 )) && wide=Y
  glv_history_rows "${rows}"
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  ui_putw "${C_MUTED}" 10 "Epoch"; ui_putw "${C_MUTED}" 9 "Stake" r
  [[ "${wide}" == N ]] || ui_putw "${C_MUTED}" 7 "Deleg" r
  ui_putw "${C_MUTED}" 5 "Led" r; ui_putw "${C_MUTED}" 8 "Blocks" r
  ui_putw "${C_MUTED}" 7 "Ideal" r; ui_putw "${C_MUTED}" 9 "Luck" r
  [[ "${wide}" == N ]] || ui_putw "${C_MUTED}" 9 "Fees" r
  ui_putw "${C_MUTED}" 11 "Rewards" r; ui_putw "${C_MUTED}" 8 "ROS" r
  ui_endl UI_BODY "${inner}"
  for entry in "${HIST_VIEW[@]}"; do
    IFS='|' read -r kind e stake deleg led blocks ideal fees rewards ros <<< "${entry}"
    case "${kind}" in
      loading|failed)
        ui_putw "${C_MUTED}" 10 "…"
        if [[ "${kind}" == loading ]]; then ui_putw "${C_MUTED}" $((inner - 10)) "fetching from Koios…"
        else ui_putw "${C_WARN}" $((inner - 10)) "Koios did not answer; asking again in a minute"; fi
        ui_endl UI_BODY "${inner}"
        continue ;;
    esac
    [[ -n "${first}" ]] || first="${e}"
    last="${e}"
    colour=''
    case "${kind}" in
      next) value="${e} next" ;;
      now) value="${e} now"; colour="${UI_BOLD}" ;;
      *) value="${e}" ;;
    esac
    ui_putw "${colour}" 10 "${value}"
    glv_ada_short value "${stake}"; ui_putw '' 9 "${value}" r
    if [[ "${wide}" == Y ]]; then
      if glv_is_int "${deleg}"; then ui_fmt_int value "${deleg}"; else value='—'; fi
      ui_putw '' 7 "${value}" r
    fi
    ui_putw '' 5 "${led:-—}" r
    if [[ "${kind}" == next ]] || ! glv_is_int "${blocks}"; then ui_putw "${C_MUTED}" 8 "—" r
    else ui_putw '' 8 "${blocks}" r; fi
    if glv_is_int "${ideal}"; then value="$((ideal / 100)).$((ideal % 100 / 10))"; else value='—'; fi
    ui_putw '' 7 "${value}" r
    # Luck is blocks made against the ideal, so only for a finished epoch.
    luck='—'; colour="${C_MUTED}"
    if [[ "${kind}" == now ]]; then luck="so far"
    elif [[ "${kind}" != next ]] && glv_is_int "${blocks}" && glv_is_int "${ideal}" && (( ideal > 0 )); then
      value=$((blocks * 100000 / ideal))
      luck="$((value / 10)).$((value % 10)) %"; colour=''
    fi
    ui_putw "${colour}" 9 "${luck}" r
    case "${kind}" in
      next)
        [[ "${wide}" == N ]] || ui_putw "${C_MUTED}" 9 "—" r
        ui_putw "${C_MUTED}" 11 "—" r; ui_putw "${C_MUTED}" 8 "—" r ;;
      now|previous)
        # Rewards are settled two epochs after the epoch they are for.
        [[ "${wide}" == N ]] || ui_putw "${C_MUTED}" 9 "pending" r
        ui_putw "${C_MUTED}" 11 "pending" r; ui_putw "${C_MUTED}" 8 "—" r ;;
      *)
        if [[ "${wide}" == Y ]]; then glv_ada_int value "${fees}"; ui_putw '' 9 "${value}" r; fi
        glv_ada_int value "${rewards}"; ui_putw '' 11 "${value}" r
        # Koios has a few epochs without their rewards, and then a ROS of 0.
        if glv_is_int "${ros}" && [[ -n "${rewards}" ]]; then printf -v value '%d.%02d %%' $((ros / 100)) $((ros % 100)); else value='—'; fi
        ui_putw '' 8 "${value}" r ;;
    esac
    ui_endl UI_BODY "${inner}"
  done
  if [[ -n "${first}" ]]; then
    right="${first}–${last}"
    (( HIST_TOTAL < 0 )) || right+=" · ${HIST_ROWS_TOTAL} epochs"
    right+=" · newest first"
  else
    right="newest first"
  fi
  UI_HELP=history
  ui_panel P_HISTORY "${width}" "${height}" "Epoch history" "${right}"
}

glv_view_production() {
  local width="$1" half=$(($1 / 2)) inner=$(($1 - 4)) text colour value days rows entry history=N
  local slot status at block epoch_height=0 schedule_height first=Y luck ideal key_rows=6
  local -a keys=() epoch=() upcoming=() past=() ordered=()

  if [[ "${D_ROLE}" != Core ]]; then
    glv_main_room
    UI_HELP=production
    glv_note_panel P_A "${width}" "${GLV_ROOM}" "Production" \
      "This node runs as a relay, so there is no block production to show. The page fills in when ${D_IMPL} runs with forging keys and reports that forging is enabled."
    glv_main_add P_A
    return 0
  fi

  glv_metric_cell keys kesperiod "KES period"
  if node_metric_has remaining_kes_periods; then
    glv_kes_colour colour
    text="${remaining_kes_periods} periods"
    if glv_is_int "${D_KES_SECONDS}"; then text+=" · $((D_KES_SECONDS / 86400)) days"; fi
    glv_cell keys "KES left" "${text}" "${colour}"
  fi
  glv_cell keys "Expires" "${D_KES_EXPIRES}"
  glv_opcert_text text colour
  glv_cell keys "Op cert" "${text}" "${colour}"
  glv_metric_cell keys opcert_start_kes "Cert from period"
  glv_metric_cell keys missed_slots "Missed chk"
  glv_bls_text text colour
  key_rows=6
  if [[ -n "${text}" ]]; then glv_cell keys "BLS key" "${text}" "${colour}"; key_rows=7; fi
  glv_production_cells epoch results
  UI_HELP=keys
  glv_cells_panel P_A "${half}" "Keys" "" keys 1 "${key_rows}"
  UI_HELP=results
  glv_cells_panel P_B $((width - half)) "Epoch ${epochnum:-} so far" "" epoch 2 "${key_rows}"
  glv_main_add P_A P_B

  # The pool as Koios sees it, and its epochs. Without an answer from Koios
  # the epochs come from the block log alone.
  glv_panel_pool "${width}"
  glv_main_add P_POOL
  [[ "${POOL_STATE}" != ok && "${POOL_STATE}" != stale ]] || history=Y
  glv_main_room
  if [[ "${history}" == Y ]]; then
    # The schedule keeps room for three slots; the history gives up rows first.
    epoch_height=$((POOL_HISTORY_EPOCHS + 3))
    (( GLV_ROOM - epoch_height >= 6 )) || epoch_height=$((GLV_ROOM - 6))
    (( epoch_height >= 4 )) || epoch_height=0
    schedule_height=$((GLV_ROOM - epoch_height))
  else
    if (( ${#D_EPOCHS[@]} > 0 )); then epoch_height=$((${#D_EPOCHS[@]} + 3)); fi
    schedule_height=$((GLV_ROOM - epoch_height))
    if (( schedule_height < 6 )); then schedule_height="${GLV_ROOM}"; epoch_height=0; fi
  fi
  (( schedule_height >= 5 )) || return 0

  # Slots to come first, soonest on top, then the ones that have passed.
  for entry in "${D_SCHEDULE[@]}"; do
    at="${entry#*|}"; at="${at#*|}"; at="${at%%|*}"
    if glv_is_int "${at}" && (( at > D_NOW )); then upcoming+=("${entry}"); else past=("${entry}" "${past[@]}"); fi
  done
  ordered=("${upcoming[@]}" "${past[@]}")
  rows=$((schedule_height - 3))
  PAGE_TOTAL=${#ordered[@]}
  glv_page_window "${rows}"
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  ui_putw "${C_MUTED}" 16 "Status"; ui_putw "${C_MUTED}" 16 "When"
  ui_putw "${C_MUTED}" 9 "Slot" r; ui_putw "${C_MUTED}" 12 "Block" r
  ui_endl UI_BODY "${inner}"
  for entry in "${ordered[@]:PAGE_SCROLL:rows}"; do
    slot="${entry%%|*}"; entry="${entry#*|}"
    status="${entry%%|*}"; entry="${entry#*|}"
    at="${entry%%|*}"; entry="${entry#*|}"
    block="${entry%%|*}"
    text=''
    if glv_is_int "${at}" && (( at > D_NOW )); then
      ui_fmt_duration text $((at - D_NOW))
      text="in ${text}"
      if [[ "${first}" == Y ]]; then
        UI_BASE="${UI_BASE_SELECT}"
        ui_putw "${UI_KEY}" 16 "▸ next"
      else
        ui_putw "${C_MUTED}" 16 "· scheduled"
      fi
      first=N
      colour="${C_ACCENT}"
    else
      glv_block_note text "${entry##*|}" "${status}"
      case "${status}" in
        adopted|confirmed) ui_putw "${C_OK}" 16 "✓ ${status}"; colour="${C_MUTED}" ;;
        leader)
          if [[ "${D_RESULTS}" == Y ]]; then
            ui_putw "${C_WARN}" 16 "? no result"; colour="${C_WARN}"; text="not checked yet"
          else
            ui_putw "${C_MUTED}" 16 "· passed"; colour="${C_MUTED}"; text="no block results recorded"
          fi ;;
        *) glv_status_label value "${status}"; ui_putw "${C_DANGER}" 16 "✗ ${value}"; colour='' ;;
      esac
    fi
    value='—'
    glv_is_int "${at}" && glv_schedule_time value "${at}"
    ui_putw '' 16 "${value}"
    ui_fmt_int value "${slot}"; ui_putw '' 9 "${value}" r
    if glv_is_int "${block}" && (( block > 0 )); then
      ui_fmt_int value "${block}"; ui_putw '' 12 "${value}" r
    else
      ui_putw "${C_MUTED}" 12 "—" r
    fi
    ui_gap 2
    ui_putw "${colour}" $(( inner - 55 > 0 ? inner - 55 : 0 )) "${text}"
    ui_endl UI_BODY "${inner}"
    UI_BASE="${UI_BASE_MAIN}"
  done
  if (( ${#ordered[@]} == 0 )); then
    if [[ -n "${D_SCHEDULE_EPOCH}" ]]; then
      ui_putw "${C_MUTED}" "${inner}" "No leader slots for this pool in epoch ${epochnum:-}."
    else
      ui_putw "${C_MUTED}" "${inner}" "No leader schedule found in ${D_BLOCKLOG_DB}."
    fi
    ui_endl UI_BODY "${inner}"
  fi
  text="times in ${BLOCKLOG_TZ:-local time}"
  (( D_NEXT_EPOCH_SLOTS == 0 )) || text="next epoch: ${D_NEXT_EPOCH_SLOTS} slots ready · ${text}"
  UI_HELP=schedule
  ui_panel P_C "${width}" "${schedule_height}" "Leader schedule" "${text}"
  glv_main_add P_C

  (( epoch_height > 0 )) || return 0
  if [[ "${history}" == Y ]]; then
    glv_panel_history "${width}" "${epoch_height}"
    glv_main_add P_HISTORY
    return 0
  fi
  UI_BODY=()
  ui_putw "${C_MUTED}" 10 "Epoch"; ui_putw "${C_MUTED}" 9 "Leader" r
  # Without block results every epoch would show 0 adopted.
  [[ "${D_RESULTS}" != Y ]] || ui_putw "${C_MUTED}" 10 "Adopted" r
  ui_putw "${C_MUTED}" 9 "Ideal" r
  ui_putw "${C_MUTED}" 10 "Luck" r
  ui_endl UI_BODY "${inner}"
  for entry in "${D_EPOCHS[@]}"; do
    slot="${entry%%|*}"; entry="${entry#*|}"
    status="${entry%%|*}"; entry="${entry#*|}"
    block="${entry%%|*}"; ideal="${entry#*|}"
    luck='—'
    if ui_scale value "${ideal}" 2 && (( value > 0 )); then
      value=$((status * 100000 / value))
      luck="$((value / 10)).$((value % 10)) %"
    fi
    colour=''
    [[ "${slot}" != "${epochnum:-}" ]] || colour="${UI_BOLD}"
    ui_putw "${colour}" 10 "${slot}"; ui_putw '' 9 "${status}" r
    [[ "${D_RESULTS}" != Y ]] || ui_putw "${C_OK}" 10 "${block}" r
    ui_putw '' 9 "${ideal:-—}" r
    ui_putw '' 10 "${luck}" r
    ui_endl UI_BODY "${inner}"
  done
  UI_HELP=epochs
  ui_panel P_D "${width}" "${epoch_height}" "Epochs" "from the block log"
  glv_main_add P_D
}

# ── 5 System ─────────────────────────────────────────────────────────────────
glv_view_system() {
  local width="$1" half=$(($1 / 2)) inner spark value text used name
  local -a cells=() custom=()

  # Host.
  if (( width >= 90 )); then inner=$((half - 4)); else inner=$((width - 4)); fi
  spark=$((inner - 23))
  (( spark <= 40 )) || spark=40
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  ui_fmt_tenths value "${D_CPU}"
  ui_putw "${C_MUTED}" 12 "CPU (sys)"; ui_putw '' 9 "${value} %" r; ui_gap 2
  ui_spark H_CPU "${spark}" "${C_ACCENT}" 1000; ui_endl UI_BODY "${inner}"
  if glv_is_int "${D_HOST_MEM_TOTAL}" && glv_is_int "${D_HOST_MEM_FREE}" && (( D_HOST_MEM_TOTAL > 0 )); then
    used=$(( (D_HOST_MEM_TOTAL - D_HOST_MEM_FREE) * 100 / D_HOST_MEM_TOTAL ))
    ui_putw "${C_MUTED}" 12 "Memory used"; ui_putw '' 9 "${used} %" r; ui_gap 2
    ui_bar "${spark}" $((spark * used / 100)) UI_HEAVY "${C_ACCENT}"; ui_endl UI_BODY "${inner}"
    ui_fmt_bytes text $((D_HOST_MEM_TOTAL * 1024))
    glv_cell cells "Memory" "${text}"
    ui_fmt_bytes text $((D_HOST_MEM_FREE * 1024))
    glv_cell cells "Available" "${text}"
  fi
  if [[ -n "${D_DISK}" ]]; then
    ui_putw "${C_MUTED}" 12 "Disk util"; ui_putw '' 9 "${D_DISK} %" r; ui_gap 2
    ui_bar "${spark}" $((spark * D_DISK / 100)) UI_HEAVY "${C_ACCENT}"; ui_endl UI_BODY "${inner}"
  fi
  (( D_CORES == 0 )) || glv_cell cells "Cores" "${D_CORES}"
  glv_cell cells "Load 1 · 5 · 15 m" "${D_LOAD}"
  while (( ${#UI_BODY[@]} < 3 )); do ui_endl UI_BODY "${inner}"; done
  ui_grid cells 1 4 "${inner}" UI_BODY
  UI_HELP=host
  ui_panel P_A $((inner + 4)) 9 "Host" ""

  # Node process.
  cells=()
  if (( width >= 90 )); then inner=$((width - half - 4)); fi
  spark=$((inner - 23))
  (( spark <= 40 )) || spark=40
  UI_BODY=()
  if [[ -n "${D_PCPU}" ]]; then
    ui_fmt_tenths value "${D_PCPU}"
    ui_putw "${C_MUTED}" 12 "CPU (node)"; ui_putw '' 9 "${value} %" r; ui_gap 2
    ui_spark H_PCPU "${spark}" "${C_ACCENT}" 1000; ui_endl UI_BODY "${inner}"
  fi
  if [[ -n "${D_MEM}" ]]; then
    ui_fmt_tenths value "${D_MEM}"
    used=1
    for name in "${H_MEM[@]}"; do (( name <= used )) || used="${name}"; done
    ui_putw "${C_MUTED}" 12 "Mem (RSS)"; ui_putw '' 9 "${value} GiB" r; ui_gap 2
    ui_spark H_MEM "${spark}" "${C_ACCENT}" "${used}"; ui_endl UI_BODY "${inner}"
  fi
  while (( ${#UI_BODY[@]} < 3 )); do ui_endl UI_BODY "${inner}"; done
  glv_cell cells "PID" "${D_PID}"
  if [[ -n "${D_UPTIME}" ]]; then
    ui_fmt_duration text "${D_UPTIME}"
    glv_cell cells "Uptime" "${text}"
  fi
  glv_cell cells "Threads" "${D_THREADS}"
  glv_metric_cell cells mem_live "Live" bytes
  glv_metric_cell cells mem_heap "Heap" bytes
  glv_metric_cell cells gc_minor "GC minor"
  glv_metric_cell cells gc_major "GC major"
  if node_metric_has open_files; then
    text="${open_files}"
    if node_metric_has max_files; then text+=" of ${max_files}"; fi
    glv_cell cells "Open files" "${text}"
  fi
  ui_grid cells 2 4 "${inner}" UI_BODY
  UI_HELP=process
  ui_panel P_B $((inner + 4)) 9 "${D_IMPL} process" ""
  if (( width >= 90 )); then glv_main_add P_A P_B; else glv_main_add P_A; glv_main_add P_B; fi

  # Whatever else the implementation reports about itself.
  for name in "${NODE_CUSTOM_METRICS[@]}"; do
    node_metric_has "${name}" || continue
    value="${!name:-}"
    [[ -z "${NODE_METRIC_UNIT[${name}]:-}" ]] || value+=" ${NODE_METRIC_UNIT[${name}]}"
    glv_cell custom "${NODE_METRIC_LABEL[${name}]:-${name}}" "${value}"
  done
  glv_main_room
  if (( ${#custom[@]} > 0 && GLV_ROOM >= 3 )); then
    used=$(( width >= 110 ? 3 : 2 ))
    spark=$(( (${#custom[@]} + used - 1) / used ))
    (( spark + 2 <= GLV_ROOM )) || spark=$((GLV_ROOM - 2))
    UI_HELP=custom
    glv_cells_panel P_C "${width}" "${D_IMPL} metrics" "as its adapter reports them" custom "${used}" "${spark}"
    glv_main_add P_C
  fi
}

# ── 6 Logs ───────────────────────────────────────────────────────────────────
# glv_log_parse <line>: sets LOG_TIME, LOG_SEVERITY (0 debug, 1 info, 2 notice,
# 3 warning, 4 error), LOG_TAG
# and LOG_TEXT for a JSON line (cardano-node) or a plain line (Amaru, Dingo).
glv_log_parse() {
  local line="$1" word
  LOG_TIME=''; LOG_SEVERITY=1; LOG_TAG=''; LOG_TEXT="${line}"
  if [[ "${line}" == '{"at":"'* ]]; then
    [[ "${line}" =~ \"at\":\"[^T\"]*T([0-9:]{8}) ]] && LOG_TIME="${BASH_REMATCH[1]}"
    [[ "${line}" =~ \"ns\":\"([^\"]*)\" ]] && LOG_TAG="${BASH_REMATCH[1]}"
    word=''
    [[ "${line}" =~ \"sev\":\"([^\"]*)\" ]] && word="${BASH_REMATCH[1]}"
    LOG_TEXT="${line#*\"data\":}"
    LOG_TEXT="${LOG_TEXT%%,\"sev\":*}"
  elif [[ "${line}" =~ ^[0-9-]+T([0-9:]{8})[^[:space:]]*[[:space:]]+([A-Za-z]+)[[:space:]]+([^[:space:]]+):[[:space:]](.*)$ ]]; then
    LOG_TIME="${BASH_REMATCH[1]}"
    word="${BASH_REMATCH[2]}"
    LOG_TAG="${BASH_REMATCH[3]}"
    LOG_TEXT="${BASH_REMATCH[4]}"
  else
    word=''
    [[ "${line}" =~ (ERROR|Error|error|WARN|Warning|warning) ]] && word="${BASH_REMATCH[1]}"
  fi
  case "${word,,}" in
    debug|trace) LOG_SEVERITY=0 ;;
    notice) LOG_SEVERITY=2 ;;
    warn|warning) LOG_SEVERITY=3 ;;
    error|critical|alert|emergency|fatal) LOG_SEVERITY=4 ;;
    *) LOG_SEVERITY=1 ;;
  esac
}

# glv_log_index: parses every loaded line once, so the page can filter and
# draw from the parts on each frame without parsing again.
glv_log_index() {
  local index
  LOG_I_TIME=(); LOG_I_LEVEL=(); LOG_I_TAG=(); LOG_I_TEXT=()
  for index in "${!D_LOG[@]}"; do
    glv_log_parse "${D_LOG[index]}"
    LOG_I_TIME[index]="${LOG_TIME}"
    LOG_I_LEVEL[index]="${LOG_SEVERITY}"
    LOG_I_TAG[index]="${LOG_TAG}"
    LOG_I_TEXT[index]="${LOG_TEXT}"
  done
}

glv_view_logs() {
  local width="$1" inner=$(($1 - 4)) rows index colour tag_width shown=0 tag text target
  local pattern="${LOG_FIND}" hide=N literal=N matched title right=''
  local -a kept=() note=()
  glv_main_room
  (( GLV_ROOM >= 4 )) || return 0
  rows=$((GLV_ROOM - 2))
  if [[ "${LOG_PAUSED}" == Y ]]; then GLV_PAGE_KEYS=("p Resume"); else GLV_PAGE_KEYS=("p Pause"); fi
  GLV_PAGE_KEYS+=("f Find" "l Level" "←→ Sideways")

  # A pattern that starts with ! hides what it matches. One that is not a
  # valid expression is looked for as plain text.
  if [[ "${pattern}" == '!'* ]]; then hide=Y; pattern="${pattern:1}"; fi
  if [[ -n "${pattern}" ]]; then
    { [[ '' =~ ${pattern} ]]; matched=$?; } 2>/dev/null
    (( matched != 2 )) || literal=Y
  fi
  shopt -s nocasematch
  # Newest first: walk back from the end, keeping what passes level and pattern.
  for ((index = ${#D_LOG[@]} - 1; index >= 0; index--)); do
    (( LOG_LEVEL == 0 || ${LOG_I_LEVEL[index]:-1} >= LOG_LEVEL_FLOOR[LOG_LEVEL] )) || continue
    if [[ -n "${pattern}" ]]; then
      target="${LOG_I_TIME[index]:-} ${LOG_I_TAG[index]:-} ${LOG_I_TEXT[index]:-}"
      matched=N
      if [[ "${literal}" == Y ]]; then
        [[ "${target}" != *"${pattern}"* ]] || matched=Y
      elif [[ "${target}" =~ ${pattern} ]]; then
        matched=Y
      fi
      [[ "${matched}" != "${hide}" ]] || continue
    fi
    kept+=("${index}")
  done
  shopt -u nocasematch

  PAGE_TOTAL=${#kept[@]}
  glv_page_window "${rows}"
  tag_width=$((inner / 4))
  (( tag_width <= 36 )) || tag_width=36
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  for index in "${kept[@]:PAGE_SCROLL:rows}"; do
    case "${LOG_I_LEVEL[index]:-1}" in
      0) colour="${C_MUTED}" ;;
      3) colour="${C_WARN}" ;;
      4) colour="${C_DANGER}" ;;
      *) colour='' ;;
    esac
    tag="${LOG_I_TAG[index]:-}"
    text="${LOG_I_TEXT[index]:-}"
    if [[ -z "${LOG_I_TIME[index]:-}" ]]; then
      ui_putw "${colour}" "${inner}" "${text:LOG_SHIFT}"
    elif (( LOG_SHIFT > 0 )); then
      # Moved sideways, the source and the message run on as one line.
      text="${tag} ${text}"
      ui_putw "${C_MUTED}" 9 "${LOG_I_TIME[index]}"
      ui_putw "${colour}" $((inner - 9)) "${text:LOG_SHIFT}"
    else
      # The end of a long source name says more than its start.
      (( ${#tag} <= tag_width )) || tag="…${tag: -$((tag_width - 1))}"
      ui_putw "${C_MUTED}" 9 "${LOG_I_TIME[index]}"
      ui_putw "${C_ID}" "${tag_width}" "${tag}"
      ui_gap 1
      ui_putw "${colour}" $((inner - 10 - tag_width)) "${text}"
    fi
    ui_endl UI_BODY "${inner}"
    shown=$((shown + 1))
  done
  if (( shown == 0 )); then
    if [[ -n "${D_LOG_NOTE}" ]]; then text="${D_LOG_NOTE}"
    elif [[ -n "${LOG_FIND}" ]]; then text="No line among the last ${#D_LOG[@]} matches. Press f and answer with nothing to clear the pattern."
    else text="No lines at this level among the last ${#D_LOG[@]}."; fi
    ui_wrap note "${inner}" "${text}"
    for text in "${note[@]}"; do
      ui_putw "${C_MUTED}" "${inner}" "${text}"
      ui_endl UI_BODY "${inner}"
    done
  fi

  title="Log · ${NODE_SERVICE:-node}"
  if [[ "${LOG_PAUSED}" == Y ]]; then
    printf -v text '%(%H:%M:%S)T' "${LOG_PAUSED_AT:-0}"
    title+=" · paused at ${text}"
  fi
  [[ -z "${LOG_FIND}" ]] || right="find ${LOG_FIND} · "
  (( LOG_SHIFT == 0 )) || right+="moved ${LOG_SHIFT} columns · "
  right+="${LOG_LEVEL_NAMES[LOG_LEVEL]} · newest first"
  UI_HELP=log
  ui_panel P_A "${width}" "${GLV_ROOM}" "${title}" "${right}"
  glv_main_add P_A
}

# ── n Node & network ─────────────────────────────────────────────────────────
# glv_column_add <column> <panel>: stacks a panel in a column of the page and
# makes it known to help mode.
glv_column_add() {
  local -n _column="$1" _column_panel="$2"
  [[ -z "${UI_PANEL_KEY[$2]:-}" ]] || UI_PANELS+=("${UI_PANEL_KEY[$2]}")
  _column+=("${_column_panel[@]}")
}

# What is running and how it was started on the left, the network it is on
# and that network's protocol parameters on the right. The page is taller
# than most terminals, so the whole of it scrolls.
glv_view_details() {
  local width="$1" left_width right_width text name value group row i visible blank_left blank_right colour
  local -a node=() network=() paths=() info=() rows=() left=() right=() binary=() binary_colours=() started=()

  if (( width >= 110 )); then left_width=$((width / 2)); right_width=$((width - left_width))
  else left_width="${width}"; right_width="${width}"; fi

  text="${D_VERSION}"
  if node_metric_has running_node_rev && [[ "${running_node_rev:-?}" != '?' ]]; then text+=" (${running_node_rev})"; fi
  node+=("Implementation|${D_IMPL}" "Version|${text}" "Role|${D_ROLE}" "Service|${NODE_SERVICE:-unknown}"
         "Process|${D_PID:-not running}")
  if [[ -n "${D_UPTIME}" ]]; then
    ui_fmt_duration text "${D_UPTIME}"
    node+=("Uptime|${text}")
  fi
  node+=("gLiveView|${GLV_VERSION} · ${GLV_THEME:-default} theme · ${UI_COLOUR_DEPTH} colours"
         "Refresh|every ${REFRESH_RATE} s")
  UI_HELP=node
  glv_rows_panel P_A "${left_width}" 0 "Node" node
  glv_column_add left P_A

  if [[ -n "${D_BIN_FILE}" ]]; then
    text="${D_BIN_FILE}"
    [[ "${D_BIN_SOURCE}" != configured ]] || text+=" (configured)"
    binary+=("File|${text}"); binary_colours+=('')
    glv_binary_state text colour
    binary+=("On disk|${text}"); binary_colours+=("${colour}")
    if [[ -n "${D_BIN_BUILD}" ]]; then binary+=("Build|${D_BIN_BUILD}"); binary_colours+=(''); fi
    if glv_is_int "${D_BIN_SIZE}" && glv_is_int "${D_BIN_MTIME}"; then
      ui_fmt_bytes text "${D_BIN_SIZE}"
      printf -v value '%(%F %H:%M)T' "${D_BIN_MTIME}"
      binary+=("Size, date|${text} · ${value}"); binary_colours+=('')
    fi
    glv_binary_pin text colour
    if [[ -n "${text}" ]]; then binary+=("Release pin|${text}"); binary_colours+=("${colour}"); fi
    UI_HELP=binary
    glv_rows_panel P_A "${left_width}" 0 "Binary" binary "" binary_colours
    glv_column_add left P_A
  fi

  if (( ${#D_STARTUP[@]} > 0 )); then
    UI_HELP=startup
    glv_rows_panel P_A "${left_width}" 0 "Start-up options" D_STARTUP "command line and environment"
    glv_column_add left P_A
  fi

  # Where the deployment keeps its files, leaving out what the start-up
  # options already show, such as cardano-node's --config and --socket-path.
  for row in "${D_STARTUP[@]}"; do started+=("${row#*|}"); done
  for row in "Node home|${NODE_HOME}" "Configuration|${NODE_CONFIG:-}" "Node socket|${NODE_SOCKET:-}" \
             "Metrics endpoint|${D_METRICS_URL}"; do
    value="${row#*|}"
    [[ -n "${value}" ]] || continue
    for text in "${started[@]}"; do [[ "${text}" != "${value}" ]] || continue 2; done
    paths+=("${row}")
  done
  [[ ! -f "${D_BLOCKLOG_DB}" ]] || paths+=("Block log|${D_BLOCKLOG_DB}")
  if [[ -n "${POOL_NAME:-}" && "${POOL_NAME}" != CHANGE_ME ]]; then
    paths+=("Pool folder|${POOL_FOLDER:-}/${POOL_NAME}")
  fi
  UI_HELP=deployment
  glv_rows_panel P_A "${left_width}" 0 "Deployment" paths
  glv_column_add left P_A

  for name in "${NODE_INFO_METRICS[@]}"; do
    node_metric_has "${name}" || continue
    value="${!name:-}"
    [[ -z "${NODE_METRIC_UNIT[${name}]:-}" ]] || value+=" ${NODE_METRIC_UNIT[${name}]}"
    info+=("${NODE_METRIC_LABEL[${name}]:-${name}}|${value}")
  done
  if (( ${#info[@]} > 0 )); then
    UI_HELP=nodeinfo
    glv_rows_panel P_A "${left_width}" 0 "Reported by ${D_IMPL}" info
    glv_column_add left P_A
  fi

  network+=("Network|${D_NETWORK}" "Network magic|${NWMAGIC:-unknown}" "Node port|${CNODE_PORT:-unknown}")
  if glv_is_int "${EPOCH_LENGTH:-}"; then
    ui_fmt_int text "${EPOCH_LENGTH}"
    network+=("Epoch length|${text} slots")
  fi
  network+=("Slot length|${SLOT_LENGTH:-unknown} s" "Active slot coefficient|${ACTIVE_SLOTS_COEFF:-unknown}")
  if glv_is_int "${SLOTS_PER_KES_PERIOD:-}"; then
    ui_fmt_int text "${SLOTS_PER_KES_PERIOD}"
    network+=("Slots per KES period|${text}" "Max KES evolutions|${MAX_KES_EVOLUTIONS:-unknown}")
  fi
  network+=("Shelley from epoch|${SHELLEY_TRANS_EPOCH:-unknown}")
  UI_HELP=network
  glv_rows_panel P_A "${right_width}" 0 "Network" network
  glv_column_add right P_A

  # Protocol parameters, one panel for each group, in the order they came.
  if (( ${#D_PARAMS[@]} == 0 )); then
    UI_HELP=params
    glv_note_panel P_A "${right_width}" 3 "Protocol parameters" "${D_PARAMS_NOTE:-Reading the protocol parameters…}"
    glv_column_add right P_A
  else
    group=''
    for row in "${D_PARAMS[@]}" "|"; do
      if [[ "${row%%|*}" != "${group}" ]]; then
        if (( ${#rows[@]} > 0 )); then
          UI_HELP=params
          glv_rows_panel P_A "${right_width}" 0 "Protocol parameters · ${group}" rows "from ${D_PARAMS_SOURCE}"
          glv_column_add right P_A
        fi
        group="${row%%|*}"
        rows=()
      fi
      [[ -z "${group}" ]] || rows+=("${row#*|}")
    done
  fi

  # One column on a narrow terminal, two side by side otherwise.
  rows=()
  if (( width >= 110 )); then
    blank_left="${UI_SPACES:0:left_width}"
    blank_right="${UI_SPACES:0:right_width}"
    for ((i = 0; i < ${#left[@]} || i < ${#right[@]}; i++)); do
      rows+=("${left[i]:-${blank_left}}${right[i]:-${blank_right}}")
    done
  else
    rows=("${left[@]}" "${right[@]}")
  fi
  glv_main_room
  visible="${GLV_ROOM}"
  PAGE_TOTAL=${#rows[@]}
  glv_page_window "${visible}"
  MAIN+=("${rows[@]:PAGE_SCROLL:visible}")
}

# glv_view_build <width>: fills the main area for the selected page.
glv_view_build() {
  PAGE_TOTAL=0
  GLV_PAGE_KEYS=()
  case "${VIEW}" in
    2) glv_view_chain "$1" ;;
    3) glv_view_peers "$1" ;;
    4) glv_view_production "$1" ;;
    5) glv_view_system "$1" ;;
    6) glv_view_logs "$1" ;;
    *) glv_view_details "$1" ;;
  esac
}

##############################################################################
# Help mode
##############################################################################
# "?" keeps the page that is on screen, puts the focus
# on one of its panels and opens a drawer under the page that says what that
# panel's figures mean, what a good value looks like and, where the tool has a
# threshold, how the current value does. The arrow keys move the focus. Where
# a drawer does not fit (80 columns, short terminals) the help for the whole
# page is one scrollable text instead.
#
# The texts only mention figures the node in front of the operator reports,
# so the same help serves cardano-node, Amaru and Dingo.

HELP=N
HELP_MODE=off      # off, drawer or page; decided on every frame
HELP_FOCUS=''      # help key of the focused panel
HELP_SCROLL=0
HELP_ENTRIES=()
HELP_LINES=()
HELP_PAGE_NAMES=('' Overview Chain Peers Production System Logs "Node & network")
# The panels of each page, for the help that is one text for the whole page.
HELP_PAGE_KEYS=('' "epoch chain propagation peers resources production recent"
  "epoch chain traffic spread recent" "peers connections roundtrip peerlist"
  "production keys results pool schedule history epochs" "host process custom" "log"
  "node binary startup deployment nodeinfo network params")
declare -A HELP_TITLE=(
  [epoch]="Epoch" [chain]="Chain" [propagation]="Propagation" [peers]="Peers"
  [resources]="Resources" [production]="Block production" [recent]="Recent blocks"
  [events]="Events" [traffic]="Traffic" [spread]="Block delay spread"
  [connections]="Connections" [roundtrip]="Round trip" [peerlist]="Connection list"
  [keys]="Keys" [results]="Epoch so far" [schedule]="Leader schedule" [epochs]="Epochs"
  [host]="Host" [process]="Node process" [custom]="Node's own metrics" [log]="Log"
  [node]="Node" [binary]="Binary" [network]="Network" [deployment]="Deployment" [nodeinfo]="Reported by the node"
  [startup]="Start-up options" [params]="Protocol parameters"
  [pool]="Pool" [history]="Epoch history"
)

# glv_help_mode <rows of the main area>: a drawer needs room above it.
glv_help_mode() {
  HELP_MODE=off
  [[ "${HELP}" == Y ]] || return 0
  if (( $1 < 30 )); then HELP_MODE=page; else HELP_MODE=drawer; fi
}

# glv_help_add <term> <text> [good] [current value] [ok|warn|bad]
glv_help_add() { HELP_ENTRIES+=("$1|$2|${3:-}|${4:-}|${5:-}"); }

# glv_help_entries <panel> [page]: fills HELP_ENTRIES for one panel. With
# "page" the text is part of the help for a whole page, where the production
# panel of the overview would repeat the Production page's own panels.
glv_help_entries() {
  local every='' value='' level='' scaled
  HELP_ENTRIES=()
  case "$1" in
    epoch)
      glv_help_add "Bar" \
        "How far the node's ledger is into the epoch: its slot in the epoch against the epoch length."
      glv_help_add "Time left" \
        "Counted from the wall clock, so it is right even when the node is behind."
      if [[ "${D_ROLE}" == Core && "${D_RESULTS}" == Y ]]; then
        glv_help_add "Marks" \
          "One ▲ for each leader slot of your pool, placed where the slot falls on the bar. Green was adopted, the accent colour is still to come, amber has passed without a result yet, red was lost."
      elif [[ "${D_ROLE}" == Core ]]; then
        glv_help_add "Marks" \
          "One ▲ for each leader slot of your pool, placed where the slot falls on the bar. The accent colour is still to come, grey has passed. The block log holds no block results for this node, so the marks do not say whether a block was made."
      fi
      glv_help_add "Sync or alert" \
        "While the node reports a sync phase or an alert, that line takes the place of the marks."
      ;;
    chain)
      glv_help_add "Block · Slot" \
        "Height and slot of the node's tip, the newest block it has adopted."
      [[ -z "${D_BLOCK_EVERY}" ]] || every=" On this network a block comes about every ${D_BLOCK_EVERY} s on average, so the gap moves all the time."
      if [[ -n "${D_TIP_GAP}" ]]; then
        glv_slots value "${D_TIP_GAP}"
        if (( D_TIP_GAP <= 120 )); then level=ok; elif (( D_TIP_GAP <= 600 )); then level=warn; else level=bad; fi
      fi
      glv_help_add "Tip gap" \
        "Slots between the tip and the slot the wall clock is in now. It climbs with the clock and drops when a block arrives.${every}" \
        "Under 120 slots. A gap that keeps growing means the node is falling behind." "${value}" "${level}"
      glv_help_add "Epoch slot" "Slot of the tip, counted from the start of the epoch."
      if node_metric_has density; then
        glv_help_add "Density" \
          "Share of slots that hold a block, as the node measures it on its chain." \
          "Close to the network's active slot coefficient, 5 % on mainnet." "${density} %"
      fi
      if node_metric_has forks; then
        glv_help_add "Forks" \
          "How often the node switched to another chain since it started. Short forks are normal: two pools sometimes make a block at almost the same time." \
          "No fixed number. Watch for a rate far above what you usually see." "${forks}"
      fi
      if [[ "${VIEW}" == 1 ]]; then
        glv_help_add "Pending tx · Mempool · Total tx" \
          "Transactions waiting in this node's mempool, as a count and as bytes, and the transactions it has processed since it started."
      fi
      ;;
    traffic)
      glv_help_add "Pending tx · Mempool" \
        "Transactions waiting in this node's mempool, as a count and as bytes."
      if node_metric_has tx_processed; then
        glv_help_add "Total tx" "Transactions this node has processed since it started."
      fi
      if node_metric_has blocks_served; then
        glv_help_add "Blocks served" "Blocks this node handed to peers that asked for them."
      fi
      if node_metric_has blocks_late; then
        glv_help_add "Late blocks" "Blocks that took longer than 5 s to arrive, since the node started." \
          "Few. A count that grows steadily points at slow peers or a slow link." "${blocks_late}"
      fi
      glv_help_add "Blocks seen" \
        "New tips gLiveView has seen since it was started. The list below and the delay spread are built from these."
      ;;
    spread)
      glv_help_add "Rows" \
        "The blocks seen since gLiveView started, sorted by how long each took to arrive: up to half a second, up to 1, 2, 3 and 5 seconds, and longer." \
        "Nearly all in the first two rows. A filling last row means blocks arrive late."
      ;;
    propagation)
      if node_metric_has block_delay; then
        if ui_scale scaled "${block_delay}" 3; then
          ui_fmt_delay value "${scaled}"
          if (( scaled <= 1000 )); then level=ok; elif (( scaled <= 3000 )); then level=warn; else level=bad; fi
        fi
        glv_help_add "Last block" \
          "Time from the start of the block's slot until this node had the block." \
          "Under 1 s. Between 1 and 3 s now and then is fine. Over 5 s counts as late." "${value}" "${level}"
        glv_help_add "Slowest · bars" \
          "One bar for each block since gLiveView started, newest on the right: green up to 1 s, amber up to 3 s, red above. Slowest is the tallest of them."
      fi
      if node_metric_has blocks_w1s; then
        value=''; level=''
        if ui_scale scaled "${blocks_w1s}" 3; then
          value="$((scaled / 10)).$((scaled % 10)) % within 1 s"
          if (( scaled >= 900 )); then level=ok; else level=warn; fi
        fi
        glv_help_add "≤1s ≤3s ≤5s" \
          "Share of all blocks since the node started that arrived within 1, 3 and 5 seconds." \
          "As a rule of thumb, over 90 % within 1 s and over 99 % within 3 s." "${value}" "${level}"
      fi
      if node_metric_has blocks_late; then
        glv_help_add "Late" "Blocks that took longer than 5 s." \
          "Few. A count that grows steadily points at slow peers or a slow link." "${blocks_late}"
      fi
      if node_metric_has blocks_served; then
        glv_help_add "Served" "Blocks this node handed to peers that asked for them."
      fi
      if (( ${#NODE_CUSTOM_METRICS[@]} > 0 )); then
        glv_help_add "Other rows" \
          "Figures ${D_IMPL} reports about itself, under the names its adapter gives them."
      fi
      if (( ${#HELP_ENTRIES[@]} == 0 )); then
        glv_help_add "Propagation" "${D_IMPL} does not report how long blocks take to arrive."
      fi
      ;;
    peers)
      if node_metric_has peer_selection_hot; then
        value="${peer_selection_hot} hot"; level=ok
        [[ "${peer_selection_hot}" != 0 ]] || level=bad
        glv_help_add "Outgoing" \
          "Peers this node chose. Cold: known, not connected. Warm: connected and kept ready. Hot: connected and in use for headers and blocks." \
          "Hot at the target in your node config: 20 in the stock relay config, your own relays on a core node." "${value}" "${level}"
        if [[ -n "${D_BIG_HOT}" ]]; then
          glv_help_add "Big ledger" \
            "Relays of the largest pools, the ones that together hold most of the stake. The node picks them from the ledger and counts them apart from its other outgoing peers, with their own targets in the node config. They make it very likely that at least one peer is on the honest chain, which matters most while syncing."
        fi
        if node_metric_has inbound_governor_hot; then
          glv_help_add "Incoming" \
            "Peers that connected to this node. Hot: they fetch from it. Warm: they only hold the connection." \
            "On a public relay, more than zero. Zero for a long time usually means the port cannot be reached."
        fi
        if node_metric_has conn_outgoing; then
          glv_help_add "Conns" \
            "The same peers counted as connections. Out is outgoing plus big ledger, hot and warm together. In is incoming, hot and warm together. Both are the connections used in both directions, so they are part of out and of in."
        fi
      else
        if node_metric_has peer_active || node_metric_has peer_known; then
          glv_help_add "Known · Established · Active" \
            "Known: peers the node has heard of. Established: connected. Active: connected and in use." \
            "Active above zero."
        fi
        if node_metric_has conn_outgoing || node_metric_has conn_incoming; then
          glv_help_add "Outgoing · Incoming" \
            "Connections this node opened, and connections other nodes opened to it."
        fi
        if node_metric_has conn_total; then
          glv_help_add "Connections" "All connections ${D_IMPL} holds right now." "Above zero." "${conn_total}"
        fi
        if (( ${#HELP_ENTRIES[@]} == 0 )); then
          glv_help_add "Peers" "${D_IMPL} does not report peer counters."
        fi
      fi
      ;;
    connections)
      glv_help_add "Out · In" \
        "Connections as the node counts them: the ones it uses to fetch from a peer, and the ones a peer uses to fetch from it."
      if node_metric_has conn_duplex; then
        glv_help_add "Used both ways" \
          "Connections in use in both directions at once. They are part of Out and of In."
        glv_help_add "Can go both ways · One way only" \
          "What was agreed when the connection was made: either side may use it, or only the side that opened it."
      fi
      if [[ -n "${D_RAW[peerSelection_RootPeers]:-}" ]]; then
        glv_help_add "Root peers · Local roots" \
          "Root peers are the starting points the node knows from its topology and the ledger. Local roots are the peers you listed yourself in the topology file; the page shows how many of them are in use."
      fi
      if [[ -n "${D_RAW[inboundGovernor_cold]:-}" ]]; then
        glv_help_add "Incoming idle · cold" \
          "Peers that are connected to this node but do not use the connection right now."
      fi
      ;;
    roundtrip)
      glv_help_add "Classes" \
        "Round-trip time of each connection in the list below, as the kernel measures it on the open connection. Nothing is sent to the peers. The filters of the list apply here too." \
        "Most peers under 200 ms. A few far-away peers are useful; many slow ones delay blocks."
      glv_help_add "No figure" "Connections the kernel has no measurement for yet."
      ;;
    peerlist)
      glv_help_add "Tab" \
        "Tab puts the focus on this list, so that up and down scroll it a line at a time. Tab or Esc gives the arrows back to the list of pages."
      glv_help_add "Remote peer · RTT" \
        "Every TCP connection of the node process, fastest first, with the kernel's round-trip time."
      glv_help_add "a Analyse" \
        "Reads the node's own view of each connection from its log, in the background. For cardano-node this sends the node a signal that makes it write its state to the log. The panel title shows how old that view is."
      glv_help_add "Conn" \
        "out: the node fetches from the peer. in: the peer fetches from the node. dup: both. idle: neither. H and W are hot and warm; dup shows the node's side, then the peer's."
      glv_help_add "Score" \
        "Headers the peer delivered first plus blocks fetched from it first, of the last 180 headers and 180 blocks." \
        "Higher means the peer is more useful to this node."
      glv_help_add "Location or static peer" \
        "The label of a static peer from the topology file, else the city and country of the address from ip-api.com."
      glv_help_add "This node itself" \
        "A connection whose two ends are the node's own port on this host. The node has dialled itself, which happens when a static peer in its topology points at its own address. It is listed on purpose: it does no harm, but it takes the place of a real peer and shows that the topology was not finished." \
        "None. Point the topology entry at the node it was meant for."
      glv_help_add "Filters" \
        "t shows only static peers, with the ones that are not connected listed last. d picks a direction, s a state. f finds part of an address or port; an empty answer clears it."
      ;;
    resources)
      glv_help_cpu_host
      if [[ -n "${D_PCPU}" ]]; then
        glv_help_add "CPU (node)" \
          "Processor use of the node process alone, in percent of one core, so it can pass 100 % on a host with several cores."
      fi
      glv_help_add "Mem (RSS)" \
        "Memory the node process holds in RAM right now." \
        "Well below the host's RAM, so the node never swaps."
      if node_metric_has mem_live; then
        glv_help_add "Live · heap" \
          "From the Haskell runtime: data still in use after the last major collection, and the heap the runtime has reserved."
      fi
      glv_help_disk
      if node_metric_has open_files; then
        glv_help_add "Open files" "Files and sockets the node has open, against its limit."
      fi
      glv_help_add "Bars" "History since gLiveView started, newest on the right."
      ;;
    host)
      glv_help_cpu_host
      glv_help_add "Memory used · Memory · Available" \
        "RAM of the host: the share in use, the total, and what programs could still get without swapping." \
        "Available well above what the node may still grow by."
      glv_help_disk
      glv_help_add "Cores · Load" \
        "Processor cores of the host, and the average number of processes wanting a core over the last 1, 5 and 15 minutes." \
        "Load below the number of cores."
      ;;
    process)
      glv_help_add "CPU (node)" \
        "Processor use of the node process alone, in percent of one core, so it can pass 100 % on a host with several cores."
      glv_help_add "Mem (RSS)" "Memory the node process holds in RAM right now."
      glv_help_add "PID · Uptime · Threads" "The process number, how long it has run, and its threads."
      if node_metric_has mem_live; then
        glv_help_add "Live · Heap" \
          "From the Haskell runtime: data still in use after the last major collection, and the heap the runtime has reserved."
        glv_help_add "GC minor · major" \
          "Memory collections since the node started. A major collection pauses the node briefly."
      fi
      if node_metric_has open_files; then
        glv_help_add "Open files" "Files and sockets the node has open, against its limit."
      fi
      ;;
    custom)
      if (( ${#NODE_CUSTOM_METRICS[@]} > 0 )); then
        glv_help_add "Rows" \
          "Figures ${D_IMPL} reports about itself, under the names its adapter gives them. gLiveView shows them as they come and does not judge them."
      fi
      ;;
    production)
      if [[ "${D_ROLE}" != Core ]]; then
        # The overview has no production panel on a relay; the page has a note.
        [[ "${VIEW}" != 4 ]] ||
          glv_help_add "Relay" "This node does not forge blocks, so there is nothing to explain here."
      elif [[ "${2:-}" != page || "${VIEW}" == 1 ]]; then
        glv_help_results
        glv_help_keys
      fi
      ;;
    results) [[ "${D_ROLE}" != Core ]] || glv_help_results ;;
    keys) [[ "${D_ROLE}" != Core ]] || glv_help_keys ;;
    schedule)
      [[ "${D_ROLE}" == Core ]] || return 0
      glv_help_add "Rows" \
        "The leader slots of your pool this epoch, from the block log: the ones to come first, soonest on top, then the ones that have passed."
      if [[ "${D_RESULTS}" == Y ]]; then
        glv_help_add "Status" \
          "next and scheduled are still to come. ✓ adopted or confirmed: the block is on the chain. ? no result: the slot has passed and the block log has not been updated for it yet. ✗ with missed, ghosted, stolen, height battle or invalid: the block was lost."
        glv_help_add "Battles" \
          "stolen: another pool led the same slot and its block won, a slot battle. height battle: another pool's block in a nearby slot was built on the same parent and won, so one of the two blocks did not reach the other pool in time. Winner later: the next leader had not received our block. Winner earlier: its block reached us after we forged. ghosted: our block was built on a block that lost a fork, or lost for another reason."
        glv_help_add "Note" \
          "What the validation recorded: the pool that won, how many seconds apart the slots were, when its header reached this node, why a slot was missed, and how long after its slot started our block was forged. All times are as this node saw them. How fast our own block reached other pools can't be seen from here; a shared measurement such as openblockperf could add that later."
      else
        glv_help_add "Status" \
          "next and scheduled are still to come. · passed: the slot has passed. Nothing records block results in the block log for this node yet, so gLiveView cannot tell whether the block was made. The validate service records them: cncli.sh on cardano-node, amaru-leaderlog.sh on Amaru."
      fi
      glv_help_add "Next epoch" \
        "When the schedule of the next epoch has been calculated, the title says how many slots it holds."
      ;;
    epochs)
      [[ "${D_ROLE}" == Core ]] || return 0
      if [[ "${D_RESULTS}" == Y ]]; then
        glv_help_add "Rows" \
          "One row for each recent epoch in the block log: slots led, blocks adopted, the ideal number for the pool's stake, and leader against ideal as luck."
      else
        glv_help_add "Rows" \
          "One row for each recent epoch in the block log: slots led, the ideal number for the pool's stake, and leader against ideal as luck. The block log holds no block results for this node, so there is no column of adopted blocks."
      fi
      ;;
    pool)
      [[ "${D_ROLE}" == Core ]] || return 0
      glv_help_add "Source" \
        "The pool as Koios sees it, asked every 10 minutes and as an epoch starts. The title says how old the answer is. When Koios does not answer, the panel keeps the last answer and says so, and gLiveView asks again every minute; nothing else on the page waits for it."
      glv_help_add "Live stake · Active stake" \
        "Live: delegated to the pool now. Active: the stake this epoch's leader slots were drawn from, taken in a snapshot two epochs ago."
      local saturation=0 level=ok value=''
      if ui_scale saturation "${POOL_INFO[saturation]:-}" 1; then
        ui_fmt_tenths value "${saturation}"; value+=" %"
        (( saturation < 1000 )) || level=warn
      fi
      glv_help_add "Saturation" \
        "Live stake against the saturation point. Above 100 % the pool's rewards stop growing with its stake, so delegators earn less." \
        "Under 100 %." "${value}" "${value:+${level}}"
      value=''; level=''
      if glv_is_int "${POOL_INFO[pledge]:-}" && glv_is_int "${POOL_INFO[live_pledge]:-}"; then
        if (( ${POOL_INFO[live_pledge]} < ${POOL_INFO[pledge]} )); then value="not met"; level=bad; else value="met"; level=ok; fi
      fi
      glv_help_add "Pledge · Live pledge" \
        "What the owners promised to keep delegated to the pool, and what they delegate now." \
        "Live pledge at least the pledge. Below it the pool earns no rewards for the epoch, and the Pool line in the rail turns red." "${value}" "${level}"
      glv_help_add "Margin · Fixed cost" \
        "What the operator takes from each epoch's rewards before the delegators get the rest."
      glv_help_add "Delegators · Lifetime blocks" \
        "Accounts delegating to the pool now, and the blocks it has made since it was registered."
      glv_help_add "Pool ID" \
        "From POOL_ID at the top of gLiveView.sh, or else the pool.id files or cold.vkey in the pool folder. A producer that keeps its cold keys elsewhere needs POOL_ID."
      ;;
    history)
      [[ "${D_ROLE}" == Core ]] || return 0
      glv_help_add "Rows" \
        "One row for each epoch, newest first. An epoch's rewards are settled two epochs after it; until then its row comes from the stake snapshots and block counts Koios keeps, so the next epoch has a stake but no blocks yet, and the current and previous epochs show their rewards as pending."
      glv_help_add "Stake · Deleg" "Active stake and delegators in the epoch."
      glv_help_add "Led" "Leader slots the block log holds for the epoch, — where it has none."
      glv_help_add "Blocks · Ideal · Luck" \
        "Blocks the pool made, the number its share of the active stake gives on average, and one against the other. For the current epoch the block log's count is used when it is ahead of Koios." \
        "Around 100 % over many epochs. One epoch on its own varies a lot by chance."
      glv_help_add "Fees · Rewards · ROS" \
        "Fees: what the operator received, fixed cost plus margin. Rewards: what the delegators received. ROS: their return on stake for a year at that epoch's rate, from Koios."
      glv_help_add "Scrolling" \
        "Tab puts the focus on this list. Up and down move one epoch, PgUp and PgDn as many as the list shows, g back to the newest and G to the pool's first. Epochs that are not loaded yet are fetched from Koios as they come into view, ten at a time; a row says when it is waiting for them."
      glv_help_add "Rows shown" "POOL_HISTORY_EPOCHS at the top of gLiveView.sh, 5 unless you change it."
      ;;
    recent)
      glv_help_add "Rows" \
        "One row each time gLiveView sees a new tip. It looks every ${REFRESH_RATE} s, so two blocks in one look show as \"+1 more\"."
      glv_help_add "Delay" "How long that block took to arrive, as in the Propagation panel."
      glv_help_add "Notes" \
        "fork switch: the node changed chain with this block. late: the block took over 5 s."
      glv_help_events
      ;;
    events) glv_help_events ;;
    log)
      glv_help_add "Rows" \
        "The newest 1,000 lines of the node's journal, newest first: time, where in the node the line comes from, and the message. Warnings are amber and errors red."
      glv_help_add "p Pause" \
        "Stops reading new lines, so the list holds still while you read. Press p again to follow the log."
      glv_help_add "f Find" \
        "Shows only the lines that match a pattern, in the time, the source or the message. Upper and lower case count the same. Start the pattern with ! to hide the matching lines instead. An empty answer clears it."
      glv_help_add "l Level" "Cycles through all lines, notices and up, warnings and up, and errors."
      glv_help_add "Tab · arrows" \
        "Tab puts the focus on the log: its border turns double, and up and down then move through the lines one at a time. Tab or Esc gives the arrows back to the list of pages. PgUp and PgDn move half a screen either way, g goes to the newest line and G to the oldest. Left and right move a long line sideways so its end can be read."
      ;;
    node)
      glv_help_add "Rows" \
        "What is running: the implementation and its version, whether it forges blocks, its systemd service and process, and how gLiveView itself is set up."
      ;;
    network)
      glv_help_add "Rows" \
        "The constants of the network the node is on. Epoch and slot length give the length of an epoch in time; the KES rows say how long a KES key lasts before the operational certificate has to be renewed."
      ;;
    binary)
      glv_help_add "File" \
        "The program file the node process runs, as the process sees it. A deployment keeps its own binaries in its bin folder; a path elsewhere, such as ~/.local/bin, means the node runs a shared copy."
      glv_help_add "On disk" \
        "The version that file reports, against the version the node reports while it runs. After an upgrade the new binary is on disk while the old one keeps running: the row then says to restart." \
        "same as running."
      glv_help_add "Release pin" \
        "The version the deployment's release manifest asks for. latest means each deployment takes the newest release."
      ;;
    deployment)
      glv_help_add "Rows" \
        "Where the deployment keeps its files, and the address gLiveView reads the node's metrics from. A path the start-up options already show is not repeated here."
      ;;
    startup)
      glv_help_add "Rows" \
        "How the node process was started: the options on its command line, and the settings in its environment that carry the node's own prefix. Values whose name suggests a key, token or password are hidden."
      ;;
    params)
      glv_help_add "Rows" \
        "The protocol parameters in force, grouped as network limits, economic values and governance values. Parameters this tool has no name for are listed under Other, so a new era shows up without an update."
      glv_help_add "Source" \
        "Asked from the node through its local socket where it has one, else from Koios. They are read when the page is opened and again when the epoch changes."
      ;;
    nodeinfo)
      if (( ${#NODE_INFO_METRICS[@]} > 0 )); then
        glv_help_add "Rows" "Facts ${D_IMPL} reports about itself through its adapter."
      fi
      ;;
  esac
}

glv_help_cpu_host() {
  local value level=ok
  ui_fmt_tenths value "${D_CPU}"
  (( D_CPU < 900 )) || level=warn
  glv_help_add "CPU (sys)" \
    "Processor use of the whole host, all cores together." \
    "Room to spare. A host near 100 % delays block validation and forging." "${value} %" "${level}"
}

glv_help_disk() {
  local level=ok
  [[ -n "${D_DISK}" ]] || return 0
  if (( D_DISK >= 95 )); then level=bad; elif (( D_DISK >= 85 )); then level=warn; fi
  glv_help_add "Disk util" \
    "How full the filesystem with the deployment folder is." "Under about 85 %." "${D_DISK} %" "${level}"
}

glv_help_results() {
  if [[ -n "${D_SCHEDULE_EPOCH}" && "${D_RESULTS}" != Y ]]; then
    glv_help_add "Leader · Ideal · Luck" \
      "Leader: slots your pool leads this epoch, from the leader schedule. Ideal: what its stake would give on average. Luck: leader against ideal."
    glv_help_add "Passed · To come" \
      "Leader slots of this epoch that have passed and that are still to come. Nothing records block results in the block log for this node yet, so there are no adopted or lost counts. The validate service records them: cncli.sh on cardano-node, amaru-leaderlog.sh on Amaru."
  elif [[ -n "${D_SCHEDULE_EPOCH}" ]]; then
    glv_help_add "Leader · Ideal · Luck" \
      "Leader: slots your pool leads this epoch, from the leader schedule. Ideal: what its stake would give on average. Luck: leader against ideal."
    glv_help_add "Adopted · Confirmed" \
      "Adopted: blocks your node made and put on its chain. Confirmed: adopted blocks later verified to be on the chain."
    glv_help_add "Missed · Ghosted · Stolen · Height battle · Invalid" \
      "Missed: the slot passed without a block from your node. Stolen: another pool led the same slot and won, a slot battle. Height battle: another pool's block in a nearby slot on the same parent won, so one of the two did not reach the other in time. Ghosted: the block was built on a block that lost a fork, or lost for another reason. Invalid: the node failed to make the block. The schedule list below says more about each." \
      "Missed, ghosted and invalid at 0. Stolen is chance; height battles that repeat point at slow block propagation."
  else
    glv_help_add "Leader · Adopted" \
      "Counted by the node since it started: slots it led, and blocks it made and adopted. There is no leader schedule for this epoch yet, so nothing is known about slots to come."
  fi
}

glv_help_keys() {
  local value='' level='' remaining text colour
  if node_metric_has remaining_kes_periods; then
    value="${remaining_kes_periods} periods"; level=ok
    if ui_scale remaining "${remaining_kes_periods}" 0; then
      if (( remaining <= 5 )); then level=bad; elif (( remaining <= 15 )); then level=warn; fi
    fi
    glv_help_add "KES" \
      "Periods left before the KES key expires and the operational certificate has to be renewed. A period is 36 hours on mainnet." \
      "Renew well before it reaches 0. It turns amber at 15 periods and red at 5." "${value}" "${level}"
  fi
  glv_opcert_text text colour
  level=''
  if [[ "${colour}" == C_OK ]]; then level=ok; elif [[ "${colour}" == C_DANGER ]]; then level=bad; fi
  glv_help_add "Op cert" \
    "The counter of the certificate on disk and the last counter used on chain." \
    "Equal, or disk one ahead after a renewal that has not made a block yet." "${text}" "${level}"
  if node_metric_has missed_slots; then
    glv_help_add "Missed chk" \
      "Slot leader checks the node skipped, often during a pause for memory collection or a ledger snapshot." \
      "A few are normal. Many in a row can cost a block." "${missed_slots}"
  fi
  glv_bls_text text colour
  if [[ -n "${text}" ]]; then
    level=ok
    [[ "${colour}" != C_WARN ]] || level=warn
    glv_help_add "BLS key" \
      "From protocol 12 (Dijkstra) the Leios voting committee is drawn from pools that registered a BLS key. The node votes with it when started with --shelley-bls-key, which cnode.sh adds when the pool folder has bls.skey. CNTools registers no BLS keys for now, until a cardano-cli release fixes their key files and proofs." \
      "set, with the same key registered on chain." "${text}" "${level}"
  fi
}

glv_help_events() {
  glv_help_add "Events" \
    "Things that happened to the node while gLiveView was running: it went away or came back, restarted, an epoch started, it lost all hot peers, a sync phase changed, a block of yours was adopted, or it raised an alert. Fork switches and late blocks are listed too."
}

# glv_help_lines <panel> <width> [page]: the panel's help as typed lines in
# HELP_LINES. The first character says what a line is: T a term (with the
# current value and its verdict after tabs), X text, G the "Good:" text.
glv_help_lines() {
  local key="$1" width="$2" entry term text good value level line
  local -a wrapped=()
  HELP_LINES=()
  glv_help_entries "${key}" "${3:-}"
  for entry in "${HELP_ENTRIES[@]}"; do
    term="${entry%%|*}"; entry="${entry#*|}"
    text="${entry%%|*}"; entry="${entry#*|}"
    good="${entry%%|*}"; entry="${entry#*|}"
    value="${entry%%|*}"; level="${entry#*|}"
    HELP_LINES+=("T${term}"$'\t'"${value}"$'\t'"${level}")
    ui_wrap wrapped $((width - 2)) "${text}"
    for line in "${wrapped[@]}"; do HELP_LINES+=("X${line}"); done
    if [[ -n "${good}" ]]; then
      ui_wrap wrapped $((width - 2)) "Good: ${good}"
      for line in "${wrapped[@]}"; do HELP_LINES+=("G${line}"); done
    fi
  done
}

# glv_help_put <typed line> <width>: draws one help line into UI_BODY.
glv_help_put() {
  local line="$1" inner="$2" term value level colour word
  case "${line:0:1}" in
    H) ui_putw "${UI_BOLD}${C_ACCENT}" "${inner}" "${line:1}" ;;
    T)
      line="${line:1}"
      term="${line%%$'\t'*}"; line="${line#*$'\t'}"
      value="${line%%$'\t'*}"; level="${line#*$'\t'}"
      ui_putw "${UI_BOLD}${C_ID}" $(( ${#term} < inner ? ${#term} : inner )) "${term}"
      if [[ -n "${value}" ]] && (( UI_LW + ${#value} + 12 <= inner )); then
        ui_gap 3
        ui_put '' "${value}"
        case "${level}" in
          ok) colour="${C_OK}"; word="good" ;;
          warn) colour="${C_WARN}"; word="watch" ;;
          bad) colour="${C_DANGER}"; word="act" ;;
          *) word='' ;;
        esac
        [[ -z "${word}" ]] || { ui_gap 2; ui_put "${colour}" "● ${word}"; }
      fi ;;
    G) ui_gap 2; ui_putw "${C_OK}" $((inner - 2)) "${line:1}" ;;
    X) ui_gap 2; ui_putw '' $((inner - 2)) "${line:1}" ;;
  esac
  ui_endl UI_BODY "${inner}"
}

# glv_help_focus_move <1 or -1>: the next or the previous panel on the page.
glv_help_focus_move() {
  local count=${#UI_PANELS[@]} index=0 i
  (( count > 0 )) || return 0
  for i in "${!UI_PANELS[@]}"; do [[ "${UI_PANELS[i]}" != "${HELP_FOCUS}" ]] || index="${i}"; done
  index=$(( (index + $1 + count) % count ))
  HELP_FOCUS="${UI_PANELS[index]}"
  HELP_SCROLL=0
}

# glv_help_drawer <width> <height>: the help for the focused panel, in P_DRAWER.
glv_help_drawer() {
  local width="$1" height="$2" inner=$(($1 - 4)) rows=$(($2 - 2)) limit line index=0 i right
  glv_help_lines "${HELP_FOCUS}" "${inner}"
  limit=$((${#HELP_LINES[@]} - rows))
  (( limit >= 0 )) || limit=0
  (( HELP_SCROLL <= limit )) || HELP_SCROLL="${limit}"
  (( HELP_SCROLL >= 0 )) || HELP_SCROLL=0
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  for line in "${HELP_LINES[@]:HELP_SCROLL:rows}"; do glv_help_put "${line}" "${inner}"; done
  if (( ${#HELP_LINES[@]} == 0 )); then
    ui_putw "${C_MUTED}" "${inner}" "There is nothing to explain about this panel on this node."
    ui_endl UI_BODY "${inner}"
  fi
  for i in "${!UI_PANELS[@]}"; do [[ "${UI_PANELS[i]}" != "${HELP_FOCUS}" ]] || index=$((i + 1)); done
  right="panel ${index} of ${#UI_PANELS[@]}"
  (( HELP_SCROLL >= limit )) || right+=" · more below"
  ui_panel P_DRAWER "${width}" "${height}" \
    "? ${UI_PANEL_TITLE[${HELP_FOCUS}]:-${HELP_TITLE[${HELP_FOCUS}]:-Help}}" "${right}" ID
}

# glv_help_fullpage <width> <rows>: the help for every panel of the current
# page as one scrollable text, appended to MAIN.
glv_help_fullpage() {
  local width="$1" height="$2" inner=$(($1 - 4)) visible=$(($2 - 2)) key limit line last
  local -a all=()
  for key in ${HELP_PAGE_KEYS[VIEW]}; do
    glv_help_lines "${key}" "${inner}" page
    (( ${#HELP_LINES[@]} > 0 )) || continue
    (( ${#all[@]} == 0 )) || all+=("B")
    all+=("H${HELP_TITLE[${key}]^^}" "${HELP_LINES[@]}")
  done
  limit=$((${#all[@]} - visible))
  (( limit >= 0 )) || limit=0
  (( HELP_SCROLL <= limit )) || HELP_SCROLL="${limit}"
  (( HELP_SCROLL >= 0 )) || HELP_SCROLL=0
  UI_BASE="${UI_BASE_MAIN}"
  UI_BODY=()
  for line in "${all[@]:HELP_SCROLL:visible}"; do glv_help_put "${line}" "${inner}"; done
  last=$((HELP_SCROLL + visible))
  (( last <= ${#all[@]} )) || last=${#all[@]}
  ui_panel P_HELP "${width}" "${height}" "? ${HELP_PAGE_NAMES[VIEW]} page" \
    "lines $((HELP_SCROLL + 1))-${last} of ${#all[@]}" ID
  MAIN+=("${P_HELP[@]}")
}

##############################################################################
# Start-up
##############################################################################

ui_locale_init || glv_die "no UTF-8 locale is available on this system."

. "${PARENT}/env" monitor
case $? in
  1) glv_die "failed to initialise the node adapter. Check .deployment.json and env." ;;
  3) glv_die "${NODE_IMPLEMENTATION} does not provide the metrics gLiveView needs." 3 ;;
esac
node_require metrics \
  "${NODE_IMPLEMENTATION} does not expose a metrics interface supported by gLiveView." || exit $?

[[ "${REFRESH_RATE:-}" =~ ^[1-9][0-9]*$ ]] || REFRESH_RATE=2
[[ "${POOL_HISTORY_EPOCHS:-}" =~ ^[1-9][0-9]?$ ]] && (( POOL_HISTORY_EPOCHS <= 20 )) || POOL_HISTORY_EPOCHS=5

if [[ -z "${GLV_THEME:-}" && -r "${PARENT}/cntools/.state/theme" ]]; then
  read -r GLV_THEME < "${PARENT}/cntools/.state/theme" || GLV_THEME=''
fi
ui_theme "${GLV_THEME:-default}"
glv_logo_init

# gum draws the command list. Without it the dashboard still runs.
GUM=''
for glv_candidate in "${NODE_HOME:-}/bin/gum" "${HOME:-}/.local/bin/gum" "$(type -P gum || true)"; do
  if [[ -n "${glv_candidate}" && -x "${glv_candidate}" && ! -d "${glv_candidate}" ]]; then
    GUM="${glv_candidate}"
    break
  fi
done
GLV_EXTRA_KEYS=()
[[ -z "${GUM}" ]] || GLV_EXTRA_KEYS=("/ Command")

# Peer analysis keeps the journal position it read up to, and the locations it
# looked up, beside the script. The position file has the name and the format
# gLiveView 1 used, so an existing one is carried on.
GLV_PEER_STATE_FILE="${PARENT}/gLiveView.sh.peerstate"
GLV_PEER_GEO_FILE="${PARENT}/gLiveView.sh.geo"
PEER_JOB_FILE="${TMPDIR:-/tmp}/gLiveView.$$.peers"
PARAMS_JOB_FILE="${TMPDIR:-/tmp}/gLiveView.$$.params"
POOL_JOB_FILE="${TMPDIR:-/tmp}/gLiveView.$$.pool"
HIST_JOB_FILE="${TMPDIR:-/tmp}/gLiveView.$$.history"
glv_peers_geo_load

# ── terminal ─────────────────────────────────────────────────────────────────
STTY_SAVED=''
COLS=0
ROWS=0

# Reads the terminal size from standard input, which is the terminal. Asking
# /dev/tty fails where there is no controlling terminal (under "su -c"), and
# no resize signal arrives there either, so the main loop calls this on every
# pass. A changed size redraws the whole screen.
glv_size_check() {
  local size='' rows cols
  size="$(stty size 2>/dev/null)" || size="$(stty size 2>/dev/null < /dev/tty)" || size=''
  rows="${size%% *}"
  cols="${size##* }"
  if [[ ! "${rows}" =~ ^[1-9][0-9]*$ || ! "${cols}" =~ ^[1-9][0-9]*$ ]]; then
    rows="$(tput lines 2>/dev/null)" || rows=''
    cols="$(tput cols 2>/dev/null)" || cols=''
    [[ "${rows}" =~ ^[1-9][0-9]*$ && "${cols}" =~ ^[1-9][0-9]*$ ]] || { rows=24; cols=80; }
  fi
  [[ "${rows}" != "${ROWS}" || "${cols}" != "${COLS}" ]] || return 0
  ROWS="${rows}"
  COLS="${cols}"
  ui_invalidate
  printf '\e[2J'
}

# The terminal or tmux window title names the node and its role, so a tab
# shows it without switching to it. The title in use goes on the terminal's
# title stack first and comes back on exit; a terminal without a title stack
# keeps gLiveView's title until the shell sets its own.
GLV_TITLE_SHOWN=''
GLV_TITLE_PUSHED=N
glv_title_update() {
  local role=relay title
  [[ "${D_ROLE}" != Core ]] || role='block producer'
  # ASCII only: a terminal or tmux without a UTF-8 locale, as under su,
  # shows other characters as "_".
  title="gLiveView - ${D_NAME} - ${role}"
  title="${title//[[:cntrl:]]/}"
  [[ "${title}" != "${GLV_TITLE_SHOWN}" ]] || return 0
  if [[ "${GLV_TITLE_PUSHED}" == N ]]; then
    printf '\e[22;0t'
    GLV_TITLE_PUSHED=Y
  fi
  printf '\e]2;%s\a' "${title}"
  GLV_TITLE_SHOWN="${title}"
}

glv_cleanup() {
  glv_peers_cleanup
  [[ -z "${PARAMS_JOB_PID:-}" ]] || kill "${PARAMS_JOB_PID}" 2>/dev/null || true
  rm -f -- "${PARAMS_JOB_FILE:-/nonexistent}" "${PARAMS_JOB_FILE:-/nonexistent}.part"
  [[ -z "${POOL_JOB_PID:-}" ]] || kill "${POOL_JOB_PID}" 2>/dev/null || true
  [[ -z "${HIST_JOB_PID:-}" ]] || kill "${HIST_JOB_PID}" 2>/dev/null || true
  rm -f -- "${POOL_JOB_FILE:-/nonexistent}" "${POOL_JOB_FILE:-/nonexistent}.part" \
    "${HIST_JOB_FILE:-/nonexistent}" "${HIST_JOB_FILE:-/nonexistent}.part" "${HIST_JOB_FILE:-/nonexistent}.head"
  [[ "${GLV_TITLE_PUSHED}" == N ]] || printf '\e[23;0t'
  printf '\e[?25h\e[?1049l'
  [[ -z "${STTY_SAVED}" ]] || stty "${STTY_SAVED}" 2>/dev/null
}

# The command list is a gum filter. gum owns the terminal while it is open, so
# the page pauses and is redrawn in full afterwards.
glv_command_palette() {
  local choice='' i
  local -a rows=()
  [[ -n "${GUM}" ]] || return 0
  for i in 1 2 3 4 5 6 7; do
    printf -v choice '%02d  ›  %s' "${i}" "${VIEW_NAMES[i]}"
    rows+=("${choice}")
  done
  rows+=("08  •  Help: what the figures mean" "09  •  Redraw" "10  ✕  Quit")
  printf '\e[2J\e[H\e[?25h'
  stty "${STTY_SAVED}" 2>/dev/null
  # The rows go in as arguments, so gum keeps the terminal as its input.
  choice="$("${GUM}" filter --limit 1 --height 14 \
    --width "$(( COLS < 64 ? COLS - 2 : 62 ))" --padding "1 2" --no-fuzzy \
    --placeholder "Type to filter, Enter to run, Esc twice to close" \
    --placeholder.foreground "${HEX_MUTED}" \
    --prompt "› " --prompt.foreground "${HEX_ACCENT}" \
    --indicator "▸ " --indicator.foreground "${HEX_ACCENT}" \
    --match.foreground "${HEX_OK}" --text.foreground "${HEX_TEXT}" \
    --cursor-text.foreground "${HEX_TEXT}" \
    --cursor-text.background "${HEX_SURFACE}" -- "${rows[@]}")" || choice=''
  stty -echo 2>/dev/null
  printf '\e[?25l\e[2J'
  ui_invalidate
  case "${choice:0:2}" in
    0[1-7]) glv_view_set "${choice:1:1}" ;;
    08) HELP=Y; HELP_SCROLL=0 ;;
    10) exit 0 ;;
  esac
}

# glv_prompt <label> <current value>: asks for a line of text on the last row
# and leaves it in GLV_INPUT. Returns 1 when the question was cancelled.
glv_prompt() {
  local status=0
  GLV_INPUT="$2"
  printf '\e[%d;1H\e[2K\e[?25h' "${ROWS}"
  stty "${STTY_SAVED}" 2>/dev/null
  if [[ -n "${GUM}" ]]; then
    GLV_INPUT="$("${GUM}" input --prompt "$1 › " --value "$2" --width "$((COLS - ${#1} - 6))" \
      --placeholder "empty clears it" --prompt.foreground "${HEX_ACCENT}" \
      --cursor.foreground "${HEX_ACCENT}")" || status=1
  else
    IFS= read -r -p "$1 (empty clears it): " GLV_INPUT || status=1
  fi
  stty -echo 2>/dev/null
  printf '\e[?25l\e[2J'
  ui_invalidate
  return "${status}"
}

# The keys of the Peers page: the analysis and its filters.
glv_key_peers() {
  case "$1" in
    a) glv_peers_job_start ;;
    f) if glv_prompt "Find address or port" "${PEER_SEARCH}"; then PEER_SEARCH="${GLV_INPUT}"; fi ;;
    t) glv_peers_static_capable || return 1
       if [[ "${PEER_FILTER_STATIC}" == all ]]; then PEER_FILTER_STATIC=static; else PEER_FILTER_STATIC=all; fi ;;
    d) [[ "${node_peer_state_available}" == true ]] || return 1
       case "${PEER_FILTER_DIR}" in all) PEER_FILTER_DIR=out ;; out) PEER_FILTER_DIR=in ;; in) PEER_FILTER_DIR=dup ;; *) PEER_FILTER_DIR=all ;; esac ;;
    s) [[ "${node_peer_state_available}" == true ]] || return 1
       case "${PEER_FILTER_STATE}" in any) PEER_FILTER_STATE=hot ;; hot) PEER_FILTER_STATE=warm ;; *) PEER_FILTER_STATE=any ;; esac ;;
    *) return 1 ;;
  esac
  PAGE_SCROLL=0
}

# The keys of the Logs page: pause, find, level and moving a line sideways.
glv_key_logs() {
  case "$1" in
    p) if [[ "${LOG_PAUSED}" == Y ]]; then
         LOG_PAUSED=N
         glv_data_logs
       else
         LOG_PAUSED=Y
         printf -v LOG_PAUSED_AT '%(%s)T' -1
       fi ;;
    f) if glv_prompt "Find in log (start with ! to hide matches)" "${LOG_FIND}"; then LOG_FIND="${GLV_INPUT}"; PAGE_SCROLL=0; fi ;;
    l) LOG_LEVEL=$(( (LOG_LEVEL + 1) % 4 )); PAGE_SCROLL=0 ;;
    $'\e[C') LOG_SHIFT=$((LOG_SHIFT + 20)) ;;
    $'\e[D') LOG_SHIFT=$(( LOG_SHIFT >= 20 ? LOG_SHIFT - 20 : 0 )) ;;
    G|$'\e[F') PAGE_SCROLL=1000000 ;;
    *) return 1 ;;
  esac
}

# The keys of help mode: the focus moves from panel to panel, and the text
# scrolls. Anything else falls through to the keys of every page.
glv_key_help() {
  local step=$((ROWS / 2))
  case "$1" in
    '?'|h|$'\e') HELP=N ;;
    $'\e[C'|$'\t') [[ "${HELP_MODE}" != drawer ]] || glv_help_focus_move 1 ;;
    $'\e[D'|$'\e[Z') [[ "${HELP_MODE}" != drawer ]] || glv_help_focus_move -1 ;;
    $'\e[A'|k) HELP_SCROLL=$((HELP_SCROLL - 2)) ;;
    $'\e[B'|j) HELP_SCROLL=$((HELP_SCROLL + 2)) ;;
    $'\e[5~') HELP_SCROLL=$((HELP_SCROLL - step)) ;;
    $'\e[6~'|' ') HELP_SCROLL=$((HELP_SCROLL + step)) ;;
    $'\e[H'|g) HELP_SCROLL=0 ;;
    *) return 1 ;;
  esac
}

# glv_view_set <number>: switches page and fetches what only that page shows.
# Help stays open and starts at the first panel of the new page.
glv_view_set() {
  (( $1 >= 1 && $1 <= 7 )) || return 0
  VIEW="$1"
  PAGE_SCROLL=0
  PAGE_FOCUS=N
  PAGE_FOCUS_AT=0
  HELP_SCROLL=0
  HELP_FOCUS=''
  glv_data_view
}

glv_key() {
  local step=$((ROWS / 2))
  if [[ "${HELP}" == Y ]]; then
    ! glv_key_help "$1" || return 0
  elif (( VIEW == 3 )); then
    ! glv_key_peers "$1" || return 0
  elif (( VIEW == 6 )); then
    ! glv_key_logs "$1" || return 0
  fi
  case "$1" in
    q|Q) exit 0 ;;
    [1-6]) glv_view_set "$1" ;;
    n) glv_view_set 7 ;;
    '?'|h) HELP=Y; HELP_SCROLL=0 ;;
    # Tab gives the arrows to the list on the page, Tab or Esc gives them back.
    $'\t')
      [[ "${PAGE_FOCUSABLE[VIEW]}" == Y ]] || return 1
      glv_focus_next ;;
    $'\e') [[ "${PAGE_FOCUS}" == Y ]] || return 1; PAGE_FOCUS=N; PAGE_FOCUS_AT=0 ;;
    $'\e[A'|k) if [[ "${PAGE_FOCUS}" == Y ]]; then glv_focus_scroll -1; else glv_view_set $((VIEW - 1)); fi ;;
    $'\e[B'|j) if [[ "${PAGE_FOCUS}" == Y ]]; then glv_focus_scroll 1; else glv_view_set $((VIEW + 1)); fi ;;
    $'\e[5~') glv_focus_scroll $((-step)) page ;;
    $'\e[6~'|' ') glv_focus_scroll "${step}" page ;;
    $'\e[H'|g)
      glv_focus_key
      if [[ "${GLV_FOCUS_KEY}" == history ]]; then HIST_SCROLL=0; else PAGE_SCROLL=0; LOG_SHIFT=0; fi ;;
    G|$'\e[F')
      glv_focus_key
      [[ "${GLV_FOCUS_KEY}" == history ]] || return 1
      glv_focus_scroll 1000000 ;;
    /) glv_command_palette ;;
    r) ui_invalidate; printf '\e[2J' ;;
    *) return 1 ;;
  esac
}

# ── main loop ────────────────────────────────────────────────────────────────
[[ -t 0 && -t 1 ]] || glv_die "gLiveView needs an interactive terminal."

STTY_SAVED="$(stty -g)"
trap glv_cleanup EXIT
trap 'exit 130' INT TERM
trap ':' WINCH
stty -echo
printf '\e[?1049h\e[?25l'
glv_data_init

glv_next_collect=0
glv_next_tick=0
while :; do
  glv_size_check
  glv_now="${EPOCHREALTIME/[.,]/}"
  if (( glv_now >= glv_next_collect )); then
    glv_data_collect
    glv_title_update
    glv_next_collect=$((${EPOCHREALTIME/[.,]/} + REFRESH_RATE * 1000000))
  else
    glv_data_clock
  fi
  glv_render
  glv_next_tick=$((${EPOCHREALTIME/[.,]/} + 1000000))
  (( glv_next_tick <= glv_next_collect )) || glv_next_tick="${glv_next_collect}"

  # Short waits, so a resize is picked up without waiting for the tick.
  while :; do
    glv_now="${EPOCHREALTIME/[.,]/}"
    (( glv_now < glv_next_tick )) || break
    glv_slice=$((glv_next_tick - glv_now))
    (( glv_slice <= 200000 )) || glv_slice=200000
    printf -v glv_timeout '%d.%06d' "$((glv_slice / 1000000))" "$((glv_slice % 1000000))"
    if IFS= read -rsn1 -t "${glv_timeout}" glv_pressed; then
      if [[ "${glv_pressed}" == $'\e' ]]; then
        IFS= read -rsn2 -t 0.02 glv_rest || glv_rest=''
        glv_pressed+="${glv_rest}"
        # Page keys send one more character after the number.
        if [[ "${glv_rest}" == '['[0-9] ]]; then
          IFS= read -rsn1 -t 0.02 glv_rest || glv_rest=''
          glv_pressed+="${glv_rest}"
        fi
      fi
      ! glv_key "${glv_pressed}" || break
    fi
  done
done
