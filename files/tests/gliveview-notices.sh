#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2153,SC2154,SC2329
# gLiveView's notices: what raises and clears them, the pending configuration
# a guild-deploy.sh refresh records in the manifest, acknowledgements kept
# beside the script, the Attention lines and the Notices count in the side
# rail, the pulse of a new error, the terminal title, and the Notices page.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'gliveview-notices skipped: Bash 4.4+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'gliveview-notices skipped: jq required\n'; exit 0; }

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

glv_load "${GLIVEVIEW}" ui_colour_256 ui_colour ui_theme ui_put ui_gap ui_putw ui_endl ui_wrap ui_scale \
  ui_fmt_int ui_fmt_duration ui_box_top ui_panel glv_is_int glv_role_badge glv_identity_lines glv_rail \
  glv_rail_slim glv_title_update glv_data_init glv_data_stamp glv_data_event glv_notice glv_notices_sweep \
  glv_notices_tally glv_notices_seen glv_notices_ackable glv_notices_acknowledge glv_notices_save \
  glv_notices_load glv_data_pending glv_notices_check glv_notices_node glv_launch_text glv_fmt_span \
  glv_notice_colour glv_pulse_now glv_event_colour \
  glv_attention glv_kes_colour glv_opcert_text glv_pool_vital glv_binary_state glv_binary_pin \
  glv_main_begin glv_main_room glv_main_add glv_page_window glv_view_notices glv_key_notices
eval "$(grep -E '^(GLV_RAIL_W|GLV_SLIM_W|VIEW_KEYS|VIEW_NAMES|GLV_VERSION|UI_RESET|UI_BOLD|UI_REVERSE|UI_L|UI_LW|GLV_TITLE_SHOWN|GLV_TITLE_PUSHED|GLV_ROWS_MAX|GLV_EVENTS_MAX|GLV_NOTICE_NEEDS_NODE|GLV_NOTICE_QUIET|PAGE_LISTS)=' "${GLIVEVIEW}")"
printf -v UI_SPACES '%500s' ''
UI_DASHES="${UI_SPACES// /─}"
UI_DOUBLE="${UI_SPACES// /═}"
UI_HELP=''
UI_FOCUS=''
declare -gA UI_PANEL_KEY=() UI_PANEL_TITLE=()
UI_PANELS=()
GLV_LOGO=()
GLV_LOGO_SGR=()
GLV_EXTRA_KEYS=()
GLV_PAGE_KEYS=()
GLV_FOOTER_NOTE=''
PAGE_SCROLL=0
PAGE_TOTAL=0
POOL_STATE=off
declare -gA POOL_INFO=()

# Stand-ins for the live parts of the rail and the node's metrics.
glv_vitals() {
  ui_put '' "Sync  in sync"; ui_endl "$1" "$2"
  ui_put '' "Peers 20 out · 5 in"; ui_endl "$1" "$2"
  ui_put '' "Host  12 %"; ui_endl "$1" "$2"
}
glv_next_block() { :; }
declare -A METRIC=()
node_metric_has() { [[ -n "${METRIC[$1]+set}" ]]; }
NODE_CAPABILITIES="metrics n2c topology_file"
node_has() { [[ " ${NODE_CAPABILITIES} " == *" $1 "* ]]; }
glv_strip() { sed $'s/\e\\[[0-9;]*m//g'; }

GLV_COLORS=truecolor
ui_theme default

NODE_HOME="${TEST_ROOT}/node"
mkdir -p "${NODE_HOME}/files"
GLV_NOTICE_STATE_FILE="${TEST_ROOT}/gLiveView.sh.notices"
NODE_SERVICE=cnode

# fresh_state: gLiveView as it starts, with a relay that reports metrics.
fresh_state() {
  glv_data_init
  D_OK=Y; D_DOWN=''; D_FAILS=0; D_ROLE=Relay; D_IMPL=cardano-node; D_NAME=relay1
  D_VERSION=11.1.3; D_NETWORK=preprod; D_UPTIME=1000; D_COLLECTED_AT=1000; D_NOW=1000; D_PID=''
  VIEW=1
  METRIC=()
}

# event <index>: an event row without its time stamp.
event() {
  local record="${D_EVENTS[$1]:-}"
  record="${record#E|}"
  printf '%s' "${record#*|}"
}

# ── the configuration a refresh kept ─────────────────────────────────────────
fresh_state
printf '{}\n' > "${NODE_HOME}/files/config.json"
printf '{}\n' > "${NODE_HOME}/files/topology.json"
touch -t 202001010000 "${NODE_HOME}/files/config.json" "${NODE_HOME}/files/topology.json"
jq -n '{schemaVersion: 1, pendingConfigUpdate: {
  reason: "GenesisMode: the public bootstrap peers are being shut down",
  files: ["files/config.json", "files/topology.json"]}}' > "${NODE_HOME}/.deployment.json"
touch -t 202101010000 "${NODE_HOME}/.deployment.json"
glv_data_pending
assert_eq "${D_PENDING_FILES}" "files/config.json files/topology.json" "pending files from the manifest"
glv_notices_check
assert_eq "${N_LEVEL[config]:-}" warning "a pending update is a warning"
assert_eq "${N_TITLE[config]}" "Config update pending" "pending update title"
[[ "${N_TEXT[config]}" == *"kept config.json and topology.json as they were"* ]] || fail "the text names the files: ${N_TEXT[config]}"
[[ "${N_TEXT[config]}" == *"(GenesisMode: the public bootstrap peers are being shut down)"* ]] || fail "the text gives the reason"
[[ "${N_TEXT[config]}" == *"guild-deploy.sh -s u"* ]] || fail "the text says how to update"
assert_eq "$(event 0)" "warning|Config update pending" "raising a notice is an event"
assert_eq "${N_RAIL[*]}" config "the warning is in the rail"
assert_eq "${N_WORST}" warning "worst level"

# A file changed after the refresh may have been fixed by hand.
touch "${NODE_HOME}/files/config.json"
glv_data_pending
assert_eq "${D_PENDING_FILES}" "" "a file newer than the manifest is not reported"
glv_notices_check
assert_eq "${N_LEVEL[config]:-}" "" "the pending notice clears"
assert_eq "$(event 0)" "cleared|Config update pending" "clearing is an event"
touch -t 202001010000 "${NODE_HOME}/files/config.json"
jq 'del(.pendingConfigUpdate)' "${NODE_HOME}/.deployment.json" > "${TEST_ROOT}/m" && mv "${TEST_ROOT}/m" "${NODE_HOME}/.deployment.json"
glv_data_pending
assert_eq "${D_PENDING_FILES}" "" "a manifest without the key reports nothing"

# ── levels, the node going away, and the order in the rail ──────────────────
fresh_state
D_DISK=91
glv_notices_check
assert_eq "${N_LEVEL[disk]:-}" warning "disk at 91 % is a warning"
D_DISK=96
glv_notices_check
assert_eq "${N_LEVEL[disk]}" error "disk at 96 % is an error"
assert_eq "$(event 0)" "error|Disk 96 % full" "a change of level is an event"
assert_eq "${N_NEW}" 1 "a new error is unseen"
D_DISK=50
glv_notices_check
assert_eq "${N_LEVEL[disk]:-}" "" "the disk notice clears"

D_ROLE=Core
METRIC=([remaining_kes_periods]=1)
remaining_kes_periods=12
glv_notices_check
assert_eq "${N_LEVEL[kes]:-}" warning "12 KES periods left is a warning"
remaining_kes_periods=4
glv_notices_check
assert_eq "${N_LEVEL[kes]}" error "4 KES periods left is an error"
events_before=${#D_EVENTS[@]}
D_OK=N; D_DOWN="no metrics"; D_FAILS=1
glv_notices_check
assert_eq "${N_LEVEL[node]:-}" "" "one failed read raises nothing"
assert_eq "${N_LEVEL[kes]:-}" error "a notice that needs the node stays while it is away"
D_FAILS=2
glv_notices_check
assert_eq "${N_LEVEL[node]:-}" error "the node without metrics is an error"
[[ "${N_TEXT[node]}" == *"sudo systemctl status cnode"* ]] || fail "the node notice names its service"
assert_eq "${#D_EVENTS[@]}" "${events_before}" "the node's own notice adds no event"
D_OK=Y; D_DOWN=''; D_FAILS=0; remaining_kes_periods=40
D_DISK=92
glv_notices_check
assert_eq "${N_LEVEL[node]:-}${N_LEVEL[kes]:-}" "" "the node and KES notices clear"
assert_eq "${#D_EVENTS[@]}" "$((events_before + 2))" "only the KES clearing and the disk warning are events"
D_DISK=97
D_OPCERT_DISK=3; D_OPCERT_CHAIN=5
glv_notices_check
assert_eq "${N_RAIL[*]}" "disk opcert" "errors in the order they came"
D_DISK=91
glv_notices_check
assert_eq "${N_RAIL[*]}" "opcert disk" "errors before warnings"

# ── acknowledging ────────────────────────────────────────────────────────────
D_PENDING_FILES="files/config.json"; D_PENDING_REASON="test"
glv_notices_check
glv_notices_ackable || fail "warnings can be acknowledged"
glv_key_notices x || fail "x acknowledges"
assert_eq "${N_RAIL[*]}" opcert "acknowledged warnings leave the rail, errors stay"
assert_eq "${N_OPEN}" 1 "only the error is open"
glv_notices_ackable && fail "nothing is left to acknowledge"
glv_key_notices x && fail "x with nothing to acknowledge falls through"
assert_eq "$(sort "${GLV_NOTICE_STATE_FILE}" | paste -sd, -)" "config|files/config.json|test,disk|warning" "acknowledgements are saved"
# The next start remembers them, and a change of level brings one back.
fresh_state
D_ROLE=Core; D_OPCERT_DISK=3; D_OPCERT_CHAIN=5
D_PENDING_FILES="files/config.json"; D_PENDING_REASON="test"; D_DISK=91
glv_notices_check
assert_eq "${N_RAIL[*]}" opcert "acknowledgements survive a restart"
D_DISK=96
glv_notices_check
assert_eq "${N_RAIL[*]}" "opcert disk" "an acknowledged warning that turns into an error is back"
D_DISK=91
glv_notices_check
assert_eq "${N_RAIL[*]}" "opcert" "back to the acknowledged warning"

# ── the pulse of a new error ─────────────────────────────────────────────────
D_NOW=1000
errors=(); warnings=()
glv_attention errors warnings 24
[[ "${errors[0]}" == *"${UI_REVERSE}"* ]] || fail "a new error is lit on even seconds"
D_NOW=1001
glv_attention errors warnings 24
[[ "${errors[0]}" != *"${UI_REVERSE}"* ]] || fail "a new error is not lit on odd seconds"
D_NOW=1000; GLV_PULSE=N
glv_attention errors warnings 24
[[ "${errors[0]}" != *"${UI_REVERSE}"* ]] || fail "GLV_PULSE=N keeps errors steady"
unset GLV_PULSE
glv_notices_seen
assert_eq "${N_NEW}" 0 "the Notices page has shown the errors"
glv_attention errors warnings 24
[[ "${errors[0]}" != *"${UI_REVERSE}"* ]] || fail "a seen error does not pulse"
assert_eq "$(glv_strip <<< "${errors[0]}" | sed 's/ *$//')" "✗ Op cert counter wrong" "error line in the rail"

# ── a binary replaced under the running node ─────────────────────────────────
fresh_state
D_PID=4242; D_VERSION=11.2.0; D_BIN_VERSION=11.2.0; D_BIN_REV=dac0d7ab; D_BIN_DELETED=Y; D_BIN_MTIME=900; D_BIN_PIN=''
glv_notices_check
assert_eq "${N_LEVEL[restart]:-}|${N_TITLE[restart]:-}" "info|Binary reinstalled" "the same version installed again is info"
[[ "${N_RAIL[*]:-}" != *restart* ]] || fail "info is in the rail"
D_BIN_VERSION=11.2.1; D_BIN_MTIME=950
glv_notices_check
assert_eq "${N_LEVEL[restart]}|${N_TITLE[restart]}" "warning|Restart for new binary" "a new version waiting for a restart is a warning"
D_BIN_DELETED=N; D_BIN_VERSION=11.2.0; D_BIN_MTIME=10; D_UPTIME=100
glv_notices_check
assert_eq "${N_LEVEL[restart]:-}" "" "the notice clears once the node runs the binary on disk"
D_BIN_PIN=11.2.1; D_BIN_TAG=''; D_BIN_MANIFEST=cnode-release.json
glv_notices_check
assert_eq "${N_LEVEL[release]:-}|${N_TITLE[release]:-}" "info|cardano-node 11.2.1 is pinned" "a pin the binary does not meet is info"
[[ "${N_TEXT[release]}" == *"guild-deploy.sh -s d"* ]] || fail "the pin notice says how to install"

# ── the side rail ────────────────────────────────────────────────────────────
rm -f -- "${GLV_NOTICE_STATE_FILE}"
fresh_state
D_DISK=96; D_PENDING_FILES="files/config.json"; D_PENDING_REASON="test"
glv_notices_check
rail_text() { glv_rail "$1"; printf '%s\n' "${RAIL[@]}" | glv_strip; }
mapfile -t rail < <(rail_text 80)
full=0
for index in "${!rail[@]}"; do [[ "${rail[index]// /}" == '' ]] || full=$((index + 1)); done
rail_order="$(printf '%s\n' "${rail[@]}" | grep -n -E 'ATTENTION|✗ Disk|! Config|VITALS|VIEWS' | cut -d: -f2- | sed 's/ *$//' | paste -sd'|' -)"
assert_eq "${rail_order}" " ATTENTION| ✗ Disk 96 % full| ! Config update pending| VITALS| VIEWS" "rail order"
printf '%s\n' "${rail[@]}" | grep -q -E '^   ! Notices +2 $' || fail "the Notices entry counts the open notices"
glv_rail 80
[[ "$(printf '%s\n' "${RAIL[@]}" | grep 'Notices')" == *"${C_DANGER}2"* ]] || fail "the count takes the colour of the worst notice"
# On a shorter terminal the warning leaves before the vitals, the error after.
mapfile -t rail < <(rail_text $((full - 1)))
printf '%s\n' "${rail[@]}" | grep -q '! Config' && fail "the warning stays on a rail without room for it"
printf '%s\n' "${rail[@]}" | grep -q 'VITALS' || fail "the vitals left before the warning"
mapfile -t rail < <(rail_text $((full - 6)))
printf '%s\n' "${rail[@]}" | grep -q 'VITALS' && fail "the vitals stay on a rail without room for them"
printf '%s\n' "${rail[@]}" | grep -q '✗ Disk' || fail "the error left before the vitals"
# More than three notices: the rest are counted.
D_OPCERT_DISK=3; D_OPCERT_CHAIN=5; D_ROLE=Core
METRIC=([remaining_kes_periods]=1); remaining_kes_periods=12
glv_notices_check
mapfile -t rail < <(rail_text 80)
printf '%s\n' "${rail[@]}" | grep -q '+1 more · ! Notices' || fail "notices beyond three are counted"
# The slim rail colours the Notices key.
glv_rail_slim 20
[[ "${RAIL[7]}" == *"${C_DANGER}"* && "$(glv_strip <<< "${RAIL[7]}")" == *'!'* ]] || fail "the slim rail's Notices key is red"
# Nothing to report: no Attention block and no count.
fresh_state
glv_notices_check
mapfile -t rail < <(rail_text 80)
printf '%s\n' "${rail[@]}" | grep -q 'ATTENTION' && fail "an empty Attention block is drawn"
printf '%s\n' "${rail[@]}" | grep -q -E '^   ! Notices +$' || fail "the Notices entry without a count"

# ── the terminal title ───────────────────────────────────────────────────────
fresh_state
D_DISK=96
glv_notices_check
assert_eq "$(glv_title_update)" $'\e[22;0t\e]2;(!) gLiveView - relay1 - relay\a' "an error marks the title"
D_DISK=50
glv_notices_check
GLV_TITLE_PUSHED=Y
assert_eq "$(glv_title_update)" $'\e]2;gLiveView - relay1 - relay\a' "the mark goes with the error"

# ── the Notices page ─────────────────────────────────────────────────────────
fresh_state
D_DISK=96; D_PENDING_FILES="files/config.json"; D_PENDING_REASON="test"
glv_notices_check
glv_data_event "node back" "cardano-node"
VIEW=8
glv_main_begin 30
glv_view_notices 80
page="$(printf '%s\n' "${MAIN[@]}" | glv_strip)"
[[ "${page}" == *"Notices"*"1 error · 1 warning"* ]] || fail "the page title counts the notices"
[[ "${page}" == *"✗ Disk 96 % full"*"since "* ]] || fail "the error is listed with its time"
[[ "${page}" == *"│   The disk with"* ]] || fail "the error's text is listed under it"
[[ "${N_TEXT[config]}" == "The last refresh kept config.json as it was, although this release changes it (test). Run guild-deploy.sh -s u to update it in place,"* ]] ||
  fail "one pending file: ${N_TEXT[config]}"
[[ "${page}" == *"! Config update pending"* ]] || fail "the warning is listed"
[[ "${page}" == *"node back · cardano-node"* ]] || fail "the events are listed"
[[ "${page}" == *"error · Disk 96 % full"* ]] || fail "the notice's own event is listed"
assert_eq "${GLV_PAGE_KEYS[*]}" "x Acknowledge" "the page offers to acknowledge"
assert_eq "${N_NEW}" 0 "opening the page sees the errors"
assert_eq "${#MAIN[@]}" 30 "the page fills its rows"
glv_key_notices x
glv_main_begin 30
GLV_PAGE_KEYS=()
glv_view_notices 80
page="$(printf '%s\n' "${MAIN[@]}" | glv_strip)"
[[ "${page}" == *"! Config update pending"*"acknowledged · since"* ]] || fail "an acknowledged warning stays on the page"
assert_eq "${GLV_PAGE_KEYS[*]:-}" "" "nothing left to acknowledge"
fresh_state
glv_notices_check
glv_main_begin 20
glv_view_notices 80
page="$(printf '%s\n' "${MAIN[@]}" | glv_strip)"
[[ "${page}" == *"Nothing needs attention."* ]] || fail "an empty page says so"
[[ "${page}" == *"Nothing has happened since gLiveView started."* ]] || fail "an empty event list says so"

# Help and the page list know the page.
assert_eq "${VIEW_KEYS[8]}${VIEW_NAMES[8]}" '!Notices' "the Notices page is page 8, key !"
assert_eq "${PAGE_LISTS[8]}" eventlist "the event list takes the focus on Tab"
grep -q '^    notices) glv_help_notices ;;$' "${GLIVEVIEW}" || fail "the Notices panel has no help"
grep -q '^    eventlist) glv_help_events ;;$' "${GLIVEVIEW}" || fail "the event list has no help"

printf 'gliveview-notices: ok\n'
