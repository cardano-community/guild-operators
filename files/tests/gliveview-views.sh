#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2153,SC2154,SC2329
# gLiveView views: the node logo and the role badge in the rail, the terminal
# title, the Binary panel of the Node & network page, where gLiveView finds
# the block log, and how gLiveView and CNTools show a block log without block
# results, as Amaru's leader log writes it.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'gliveview-views skipped: Bash 4+ required\n'
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
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# The logo rows are block characters, one column each, so lengths need a
# UTF-8 locale.
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

glv_load "${GLIVEVIEW}" ui_colour_256 ui_colour ui_theme ui_put ui_gap ui_putw ui_endl ui_scale \
  ui_fmt_duration glv_is_int glv_logo_init glv_role_badge glv_identity_lines glv_rail glv_title_update \
  glv_data_init glv_data_blocklog glv_cell glv_schedule_split glv_production_cells \
  glv_status_label glv_ms_text glv_block_note \
  glv_binary_parse glv_binary_state glv_binary_pin
eval "$(grep -E '^(GLV_RAIL_W|VIEW_KEYS|VIEW_NAMES|GLV_VERSION|UI_RESET|UI_BOLD|UI_L|UI_LW|GLV_TITLE_SHOWN|GLV_TITLE_PUSHED)=' "${GLIVEVIEW}")"
printf -v UI_SPACES '%500s' ''

# Stand-ins for the live parts of the rail.
glv_vitals() {
  ui_put '' "Sync  in sync"; ui_endl "$1" "$2"
  ui_put '' "Peers 20 out · 5 in"; ui_endl "$1" "$2"
  ui_put '' "Host  12 %"; ui_endl "$1" "$2"
}
glv_next_block() { ui_put '' "Next block in 1h"; ui_endl "$1" "$2"; }
glv_strip() { sed $'s/\e\\[[0-9;]*m//g'; }

# ── the logo from each adapter ───────────────────────────────────────────────
GLV_COLORS=truecolor
ui_theme default
for adapter in cnode-helper-scripts/cnode.adapter dingo-helper-scripts/dingo.adapter amaru-helper-scripts/amaru.adapter; do
  unset NODE_IMPLEMENTATION_LOGO NODE_IMPLEMENTATION_LOGO_RGB
  eval "$(grep -E '^NODE_IMPLEMENTATION_LOGO(_RGB)?=' "${REPO_ROOT}/scripts/${adapter}")"
  SHOW_NODE_LOGO=''
  glv_logo_init
  assert_eq "${#GLV_LOGO[@]}" 3 "${adapter} logo rows in the rail"
  for row in "${GLV_LOGO[@]}"; do
    (( ${#row} <= GLV_RAIL_W - 2 )) || fail "${adapter} logo row is wider than the rail"
  done
done

# The Amaru logo, as each colour depth draws it.
assert_eq "${GLV_LOGO_SGR[0]}" $'\e[38;2;48;228;161m' "24-bit logo colour"
GLV_COLORS=256; ui_theme default; glv_logo_init
[[ "${GLV_LOGO_SGR[0]}" =~ ^$'\e'\[38\;5\;[0-9]+m$ ]] || fail "256-colour logo colour: ${GLV_LOGO_SGR[0]@Q}"
GLV_COLORS=none; ui_theme default; glv_logo_init
assert_eq "${GLV_LOGO_SGR[0]}" '' "logo colour without colours"
assert_eq "${GLV_LOGO[1]}" "${NODE_IMPLEMENTATION_LOGO[1]}" "logo row without colours"

GLV_COLORS=truecolor; ui_theme default
for hidden in N n no false FALSE; do
  SHOW_NODE_LOGO="${hidden}"
  glv_logo_init
  assert_eq "${#GLV_LOGO[@]}" 0 "SHOW_NODE_LOGO=${hidden} hides the logo"
done
SHOW_NODE_LOGO=Y
saved_rgb=("${NODE_IMPLEMENTATION_LOGO_RGB[@]}")
NODE_IMPLEMENTATION_LOGO_RGB[1]="300;0;0"
glv_logo_init
assert_eq "${#GLV_LOGO[@]}" 0 "an invalid logo colour leaves the logo out"
NODE_IMPLEMENTATION_LOGO_RGB=("${saved_rgb[@]}")
saved_logo=("${NODE_IMPLEMENTATION_LOGO[@]}")
NODE_IMPLEMENTATION_LOGO[0]="${UI_SPACES:0:GLV_RAIL_W}"
glv_logo_init
assert_eq "${#GLV_LOGO[@]}" 0 "a logo wider than the rail is left out"
NODE_IMPLEMENTATION_LOGO=("${saved_logo[@]}")
NODE_IMPLEMENTATION_LOGO_RGB=("${NODE_IMPLEMENTATION_LOGO_RGB[@]:0:2}")
glv_logo_init
assert_eq "${#GLV_LOGO[@]}" 0 "a logo without a colour for every row is left out"
NODE_IMPLEMENTATION_LOGO_RGB=("${saved_rgb[@]}")

# ── the logo in the full rail ────────────────────────────────────────────────
D_NAME=bp1; D_ROLE=Core; D_IMPL=Amaru; D_VERSION=10.11.20261112; D_NETWORK=preview
D_UPTIME=''; D_NEXT_IN=3600; VIEW=1; GLV_EXTRA_KEYS=('/ Command')

# rail_text <height>: the rail as plain text, one line per row.
rail_text() {
  glv_rail "$1"
  printf '%s\n' "${RAIL[@]}" | glv_strip
}

GLV_LOGO=(); GLV_LOGO_SGR=()
mapfile -t plain < <(rail_text 80)
full=0
for index in "${!plain[@]}"; do
  [[ "${plain[index]// /}" == '' ]] || full=$((index + 1))
done
(( full > 0 )) || fail "the rail drew nothing"
[[ "${plain[2]}" == " bp1 "* ]] || fail "without a logo the name follows the title: ${plain[2]}"

glv_logo_init
mapfile -t rail < <(rail_text $((full + 4)))
[[ "${rail[0]}" == " Koios gLiveView ${GLV_VERSION}"* ]] || fail "rail title: ${rail[0]}"
for index in 0 1 2; do
  assert_eq "${rail[index + 2]}" " ${NODE_IMPLEMENTATION_LOGO[index]}${UI_SPACES:0:GLV_RAIL_W - 1 - ${#NODE_IMPLEMENTATION_LOGO[index]}}" \
    "logo row ${index} under the title"
done
[[ "${rail[6]}" == " bp1 "* ]] || fail "the name follows the logo and a blank row: ${rail[6]}"
glv_rail $((full + 4))
[[ "${RAIL[2]}" == *$'\e[38;2;48;228;161m'"${NODE_IMPLEMENTATION_LOGO[0]}"* ]] ||
  fail "the first logo row is not drawn in its colour"
for row in "${RAIL[@]}"; do
  [[ "$(glv_strip <<< "${row}")" =~ ^.{${GLV_RAIL_W}}$ ]] || fail "a rail row with the logo is not ${GLV_RAIL_W} columns wide"
done

# The logo leaves first on a short terminal: the next block, the command key
# and the vitals stay.
mapfile -t rail < <(rail_text "${full}")
[[ "${rail[2]}" == " bp1 "* ]] || fail "the logo stays on a rail without room for it: ${rail[2]}"
printf '%s\n' "${rail[@]}" | grep -q 'VITALS' || fail "the vitals left before the logo"
printf '%s\n' "${rail[@]}" | grep -q 'Next block in 1h' || fail "the next block left before the logo"
printf '%s\n' "${rail[@]}" | grep -q 'Command' || fail "the command key left before the logo"

# ── the role badge ───────────────────────────────────────────────────────────
D_UPTIME=1000000
mapfile -t rail < <(rail_text "${full}")
# rail_row <text>: a rail row as text, the line padded to the rail's inner
# width with a space either side.
rail_row() { printf ' %s%s ' "$1" "${UI_SPACES:0:GLV_RAIL_W - 2 - ${#1}}"; }
assert_eq "${rail[3]}" "$(rail_row " BLOCK PRODUCER")" "block producer badge under the name"
assert_eq "${rail[4]}" "$(rail_row "Amaru 10.11.20261112")" "implementation and version under the badge"
# 11d 13:46:40 does not fit beside the network, so the seconds go.
assert_eq "${rail[5]}" "$(rail_row "preview · up 11d 13:46")" "network and uptime"
glv_rail "${full}"
[[ "${RAIL[3]}" == *"${CB_NUM}${C_SURFACE}${UI_BOLD} BLOCK PRODUCER"* ]] ||
  fail "the block producer badge is not drawn on the number gold"
D_ROLE=Relay
glv_rail "${full}"
[[ "${RAIL[3]}" == *"${CB_ID}${C_SURFACE}${UI_BOLD} RELAY "* ]] || fail "the relay badge is not drawn on the identifier blue"
UI_L=''; UI_LW=0
glv_role_badge
assert_eq "${UI_LW}" 7 "short relay badge width"
assert_eq "$(glv_strip <<< "${UI_L}")" " RELAY " "short relay badge"
GLV_COLORS=none; ui_theme default
UI_L=''; UI_LW=0
glv_role_badge 24
assert_eq "${UI_L}" "[RELAY]                 " "relay badge without colours"
GLV_COLORS=truecolor; ui_theme default
D_ROLE=Core; D_UPTIME=''

# ── the terminal title ───────────────────────────────────────────────────────
title="$(glv_title_update; printf '|%s' "${GLV_TITLE_PUSHED}")"
assert_eq "${title}" $'\e[22;0t\e]2;gLiveView - bp1 - block producer\a|Y' "title pushed and set"
glv_title_update >/dev/null
assert_eq "$(glv_title_update)" '' "an unchanged title is not sent again"
D_ROLE=Relay
assert_eq "$(glv_title_update)" $'\e]2;gLiveView - bp1 - relay\a' "a role change sets the title without a second push"
D_NAME=$'bp\e]0;x\a1'
[[ "$(glv_title_update)" != *$'\e]0;'* ]] || fail "control characters in the name reach the title"
D_ROLE=Core; D_NAME=bp1

# ── the Binary panel ─────────────────────────────────────────────────────────
glv_binary_parse cnode $'cardano-node 11.2.0 - linux-x86_64 - ghc-9.6\ngit rev dac0d7ab2dfdee1f9eda901589e3c6ac8eaa1899' version rev build
assert_eq "${version}|${rev}|${build}" "11.2.0|dac0d7ab|linux-x86_64 · ghc-9.6" "cardano-node --version"
glv_binary_parse amaru 'Amaru 10.11.20261029 (23031e0)' version rev build
assert_eq "${version}|${rev}|${build}" "10.11.20261029|23031e0|" "amaru --version"
glv_binary_parse dingo 'v0.90.5 (commit 62f1a84)' version rev build
assert_eq "${version}|${rev}|${build}" "0.90.5|62f1a84|" "dingo version"
glv_binary_parse cnode 'bash: line 1: cardano-node: Permission denied' version rev build
assert_eq "${version}|${rev}|${build}" "||" "unreadable version output"

D_VERSION=11.2.0; D_NOW=2000000; D_UPTIME=1000; D_BIN_DELETED=N; D_BIN_MTIME=1990000
D_BIN_VERSION=11.2.0; D_BIN_REV=dac0d7ab
glv_binary_state text colour
assert_eq "${text}|${colour}" "11.2.0 (dac0d7ab) · same as running|" "binary that runs"
D_BIN_DELETED=Y
glv_binary_state text colour
assert_eq "${text}|${colour}" "11.2.0 (dac0d7ab) · restart to run it|${C_WARN}" "binary replaced while running"
D_BIN_DELETED=N; D_BIN_MTIME=$((D_NOW - 10)); D_BIN_VERSION=11.2.1; D_BIN_REV=4f2c1e0a
glv_binary_state text colour
assert_eq "${text}|${colour}" "11.2.1 (4f2c1e0a) · restart to run it|${C_WARN}" "binary newer than the process"
D_BIN_MTIME=1990000
glv_binary_state text colour
assert_eq "${text}|${colour}" "11.2.1 (4f2c1e0a) · running 11.2.0|${C_WARN}" "binary of another version"
D_VERSION=v0.90.5; D_BIN_VERSION=0.90.5; D_BIN_REV=''
glv_binary_state text colour
assert_eq "${text}" "0.90.5 · same as running" "a leading v is not a difference"
D_BIN_VERSION=''
glv_binary_state text colour
assert_eq "${text}|${colour}" "version not readable|${C_MUTED}" "binary that does not answer"

D_VERSION=11.2.0; D_BIN_MANIFEST=cnode-release.json
D_BIN_PIN=11.2.0; D_BIN_TAG=''
glv_binary_pin text colour
assert_eq "${text}|${colour}" "11.2.0 · met|" "pin met"
D_BIN_PIN=11.2.1; D_BIN_TAG=11.2.1-rc-2026w46
glv_binary_pin text colour
assert_eq "${text}|${colour}" "11.2.1 (11.2.1-rc-2026w46) · running 11.2.0|${C_WARN}" "pin not met"
D_BIN_PIN=latest; D_BIN_MANIFEST=amaru-release.json
glv_binary_pin text colour
assert_eq "${text}|${colour}" "latest release, from amaru-release.json|${C_MUTED}" "latest pin"
D_BIN_PIN=''
glv_binary_pin text colour
assert_eq "${text}" "" "no release manifest"
D_NOW=0; D_UPTIME=''

# ── where gLiveView finds the block log ──────────────────────────────────────
NODE_HOME="${TEST_ROOT}/amaru"
unset BLOCKLOG_DB BLOCKLOG_DIR
glv_data_init
assert_eq "${D_BLOCKLOG_DB}" "${NODE_HOME}/guild-db/blocklog/blocklog.db" "default block log"
BLOCKLOG_DIR="${TEST_ROOT}/moved"
glv_data_init
assert_eq "${D_BLOCKLOG_DB}" "${TEST_ROOT}/moved/blocklog.db" "block log moved with BLOCKLOG_DIR"
BLOCKLOG_DB="${TEST_ROOT}/cnode/blocklog.db"
glv_data_init
assert_eq "${D_BLOCKLOG_DB}" "${TEST_ROOT}/cnode/blocklog.db" "block log set by an adapter"
unset BLOCKLOG_DB

# ── a block log without block results ────────────────────────────────────────
if command -v sqlite3 >/dev/null 2>&1; then
  mkdir -p "${BLOCKLOG_DIR}"
  db="${BLOCKLOG_DIR}/blocklog.db"
  # Slot times as amaru-leaderlog.sh stores them: ISO 8601 with a +HH:MM offset.
  export TZ=UTC
  printf -v now '%(%s)T' -1
  printf -v past '%(%FT%T)T+00:00' $((now - 3600))
  printf -v soon '%(%FT%T)T+00:00' $((now + 3600))
  printf -v later '%(%FT%T)T+00:00' $((now + 7200))
  sqlite3 "${db}" "
    CREATE TABLE blocklog (id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL UNIQUE, at TEXT NOT NULL UNIQUE, epoch INTEGER NOT NULL, block INTEGER NOT NULL DEFAULT 0, slot_in_epoch INTEGER NOT NULL DEFAULT 0, hash TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL);
    CREATE TABLE epochdata (id INTEGER PRIMARY KEY AUTOINCREMENT, epoch INTEGER NOT NULL, epoch_nonce TEXT NOT NULL, pool_id TEXT NOT NULL, sigma TEXT NOT NULL, d REAL NOT NULL, epoch_slots_ideal INTEGER NOT NULL, max_performance REAL NOT NULL, active_stake TEXT NOT NULL, total_active_stake TEXT NOT NULL, UNIQUE(epoch,pool_id));
    INSERT INTO blocklog (slot,at,epoch,slot_in_epoch,status) VALUES
      (1000,'${past}',100,10,'leader'), (2000,'${soon}',100,20,'leader'), (3000,'${later}',100,30,'leader');
    INSERT INTO epochdata (epoch,epoch_nonce,pool_id,sigma,d,epoch_slots_ideal,max_performance,active_stake,total_active_stake)
      VALUES (100,'','pool','0.001',0.0,2.5,120.0,'1','1000');"
  glv_data_init
  epochnum=100
  D_NOW="${now}"
  glv_data_blocklog
  assert_eq "${D_RESULTS}" N "a leader log without results"
  assert_eq "${D_STATUS[total]}" 3 "leader slots read"
  cells=()
  glv_production_cells cells results
  printf '%s\n' "${cells[@]}" | grep -qx 'Passed|1|' || fail "one leader slot has passed: ${cells[*]}"
  printf '%s\n' "${cells[@]}" | grep -qx 'To come|2|' || fail "two leader slots are to come: ${cells[*]}"
  if printf '%s\n' "${cells[@]}" | grep -Eq '^(Adopted|Confirmed|Missed)\|'; then
    fail "block results are shown without any in the block log: ${cells[*]}"
  fi

  sqlite3 "${db}" "UPDATE blocklog SET status='adopted', block=42 WHERE slot=1000;"
  glv_data_blocklog
  assert_eq "${D_RESULTS}" Y "a block log with a result"
  cells=()
  glv_production_cells cells results
  printf '%s\n' "${cells[@]}" | grep -qx 'Adopted|1|C_OK' || fail "the adopted block is counted: ${cells[*]}"
  if printf '%s\n' "${cells[@]}" | grep -Eq '^(Passed|To come)\|'; then
    fail "passed and upcoming counts are shown beside block results: ${cells[*]}"
  fi

  # Block details (schema 2) give each lost slot a note.
  eval "$(awk '/^blocklogDetailSchema\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library")"
  sqlite3 "${db}" "$(blocklogDetailSchema)
    UPDATE blocklog SET status='heightbattle', block=42 WHERE slot=1000;
    INSERT INTO blocklog (slot,at,epoch,slot_in_epoch,status) VALUES
      (900,'$(printf '%(%FT%T)T+00:00' $((now - 7200)))',100,9,'stolen'),
      (800,'$(printf '%(%FT%T)T+00:00' $((now - 9000)))',100,8,'missed'),
      (700,'$(printf '%(%FT%T)T+00:00' $((now - 9900)))',100,7,'confirmed');
    INSERT INTO blockdetail (slot,reason,forge_ms,vrf,winner_slot,winner_pool,winner_ticker,winner_ms,winner_vrf) VALUES
      (1000,'height_battle',120,'',998,'pool1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq','ABCD',2600,''),
      (900,'slot_battle',NULL,'ff',900,'pool1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq','',NULL,'0a'),
      (800,'woke_late',NULL,'',NULL,'','',NULL,''),
      (700,'',110,'',NULL,'','',NULL,'');"
  glv_data_blocklog
  glv_block_note text 1000 heightbattle
  assert_eq "${text}" "ABCD 2 s earlier, reached us 0.60 s into our slot · forged in 0.12 s" "height battle note"
  sqlite3 "${db}" "UPDATE blockdetail SET winner_slot=1003, winner_ticker='' WHERE slot=1000;"
  glv_data_blocklog
  glv_block_note text 1000 heightbattle
  assert_eq "${text}" "pool1qqqqqqq… 3 s later, same parent · forged in 0.12 s" "height battle note, winner later"
  glv_block_note text 900 stolen
  assert_eq "${text}" "slot battle with pool1qqqqqqq…, their VRF lower" "slot battle note"
  glv_block_note text 800 missed
  assert_eq "${text}" "node woke late" "missed note"
  glv_block_note text 700 confirmed
  assert_eq "${text}" "forged in 0.11 s" "confirmed note"
  glv_block_note text 600 missed
  assert_eq "${text}" "" "a slot without details has no note"
  cells=()
  glv_production_cells cells results
  printf '%s\n' "${cells[@]}" | grep -qx 'Height battle|1|C_DANGER' || fail "height battles are counted: ${cells[*]}"
  printf '%s\n' "${cells[@]}" | grep -qx 'Stolen|1|C_DANGER' || fail "slot battles are counted: ${cells[*]}"

  # A block log without the blockdetail table still reads.
  sqlite3 "${db}" "DROP TABLE blockdetail;"
  glv_data_blocklog
  assert_eq "${D_STATUS[total]}|${#D_DETAIL[@]}" "6|0" "schema 1 block log"
else
  printf 'gliveview-views: sqlite3 is not installed, block log reads skipped\n'
fi

# ── CNTools Blocks views ─────────────────────────────────────────────────────
cntools_table_pair() { printf '%s=%s\n' "$1" "$2"; }
cntools_number_format() { printf '%s' "$1"; }
cntools_number_format_into() { local -n _format_out="$1"; _format_out="$2"; }
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/blocklog-ui.sh"

record='{"epoch":100,"ideal":2.5,"luck":120,"scheduled":3,"adopted":1,"confirmed":0,"pending":2,"missed":0,"ghosted":0,"stolen":0,"invalid":0,"unknown":0}'
CNTOOLS_BLOCKLOG_HAS_RESULTS=Y
rows="$(cntools_blocks_summary_rows "${record}")"
grep -qx 'Adopted (incl. confirmed)=1' <<< "${rows}" || fail "CNTools summary hides adopted blocks: ${rows}"
grep -qx 'Pending validation=2' <<< "${rows}" || fail "CNTools summary hides pending slots: ${rows}"
assert_eq "$(cntools_blocks_results_note)" '' "results note with block results"

CNTOOLS_BLOCKLOG_HAS_RESULTS=N
record='{"epoch":100,"ideal":2.5,"luck":120,"scheduled":3,"adopted":0,"confirmed":0,"pending":3,"missed":0,"ghosted":0,"stolen":0,"invalid":0,"unknown":0}'
rows="$(cntools_blocks_summary_rows "${record}")"
grep -qx 'Scheduled slots=3' <<< "${rows}" || fail "CNTools summary without results: ${rows}"
if grep -Eq '^(Adopted \(incl\. confirmed\)|Confirmed|Pending validation)=' <<< "${rows}"; then
  fail "CNTools summary counts results that nothing records: ${rows}"
fi
[[ "$(cntools_blocks_results_note)" == 'Block results=Not recorded'* ]] || fail "CNTools does not say block results are not recorded"
snapshot='[{"status":"leader"},{"status":"leader"},{"status":"leader"}]'
rows="$(cntools_blocks_epoch_rows "${snapshot}" '{"ideal":2.5,"luck":120}')"
if grep -q '^Pending validation=' <<< "${rows}"; then
  fail "CNTools epoch view lists every slot as pending validation: ${rows}"
fi
grep -qx 'Ideal blocks=2.5' <<< "${rows}" || fail "CNTools epoch view lost the ideal blocks: ${rows}"
cntools_blocks_status_into status role leader
assert_eq "${status}" 'Leader · no block results recorded' "CNTools slot status without results"
CNTOOLS_BLOCKLOG_HAS_RESULTS=Y
rows="$(cntools_blocks_epoch_rows "${snapshot}" '{}')"
grep -qx 'Pending validation=3' <<< "${rows}" || fail "CNTools epoch view with results: ${rows}"
cntools_blocks_status_into status role leader
assert_eq "${status}" 'Leader · scheduled / not yet validated' "CNTools slot status with results"
cntools_blocks_status_into status role heightbattle
assert_eq "${status}|${role}" 'Height battle|danger' "CNTools height battle status"
record='{"epoch":100,"ideal":2.5,"luck":120,"scheduled":3,"adopted":1,"confirmed":1,"pending":0,"missed":0,"ghosted":0,"stolen":0,"heightbattle":1,"invalid":0,"unknown":0}'
rows="$(cntools_blocks_summary_rows "${record}")"
grep -qx 'Height battles=1' <<< "${rows}" || fail "CNTools summary hides height battles: ${rows}"
rows="$(cntools_blocks_epoch_rows '[{"status":"heightbattle"},{"status":"confirmed"}]' '{}')"
grep -qx 'Height battles=1' <<< "${rows}" || fail "CNTools epoch view hides height battles: ${rows}"
grep -q '^Unknown status=' <<< "${rows}" && fail "CNTools counts a height battle as an unknown status: ${rows}"
cntools_timestamp_datetime_into() { local -n _date_out="$1"; _date_out="$2"; }
record='{"slot":1070,"epoch":100,"status":"heightbattle","block":107,"timestamp":1,"slot_in_epoch":70,"size":0,"hash":"",
  "detail":{"reason":"height_battle","forge_ms":120,"winner_slot":1068,"winner_pool":"pool1xyz","winner_ticker":"ABC","winner_ms":2600,
  "vrf_lower":null,"prev_slot":1063,"prev_pool":"pool1p","prev_ticker":"","prev_ms":900,"next_slot":1077,"next_pool":"pool1n","next_ticker":"NXT","next_ms":null}}'
rows="$(cntools_blocks_record_rows "${record}" N)"
grep -qx 'Battle=Height battle: ABC won with slot 1068, 2 s earlier, on the same parent' <<< "${rows}" ||
  fail "CNTools block list has no battle row: ${rows}"
grep -q '^Previous block=' <<< "${rows}" && fail "CNTools block list shows details: ${rows}"
rows="$(cntools_blocks_record_rows "${record}" Y)"
for expected in 'Our block forged=0.12 s after the slot started' \
  'Their block arrived=2.6 s after its slot, 0.6 s into our slot' \
  'Previous block=Slot 1063, 7 s earlier · pool1p · reached us 0.9 s after its slot' \
  'Next block=Slot 1077, 7 s later · NXT'; do
  grep -qxF "${expected}" <<< "${rows}" || fail "CNTools block details lack '${expected}': ${rows}"
done

# CNTools reads the details with the block log's own query.
if command -v sqlite3 >/dev/null 2>&1; then
  cntools_log() { :; }
  cntools_log_private_directory_safe() { :; }
  cntools_run_command_timeout() { shift 3; "$@"; }
  cntools_number_normalize_into() { local -n _normalized="$1"; _normalized="$2"; }
  . "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/blocklog.sh"
  CNTOOLS_TMP_DIR="${TEST_ROOT}"
  CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/cntools-blocklog.db"
  sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "
    CREATE TABLE blocklog (id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL UNIQUE, at TEXT NOT NULL UNIQUE, epoch INTEGER NOT NULL, block INTEGER NOT NULL DEFAULT 0, slot_in_epoch INTEGER NOT NULL DEFAULT 0, hash TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL);
    INSERT INTO blocklog (slot,at,epoch,slot_in_epoch,status,block) VALUES
      (1070,'2026-11-17T10:00:00+00:00',100,70,'heightbattle',107), (1080,'2026-11-17T10:00:10+00:00',100,80,'confirmed',108);"
  cntools_blocklog_epoch 100 || fail "CNTools epoch read of a schema 1 block log: ${CNTOOLS_BLOCKLOG_ERROR}"
  assert_eq "${CNTOOLS_BLOCKLOG_HAS_DETAIL}|$(jq -c '[.[].detail]' <<< "${CNTOOLS_BLOCKLOG_DATA}")" 'N|[null,null]' "CNTools without block details"
  sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "$(blocklogDetailSchema)
    INSERT INTO blockdetail (slot,reason,forge_ms,vrf,winner_slot,winner_pool,winner_ticker,winner_ms,winner_vrf,prev_slot,prev_ms)
      VALUES (1070,'height_battle',120,'aa',1068,'pool1xyz','ABC',2600,'bb',1063,900);"
  cntools_blocklog_epoch 100 || fail "CNTools epoch read with block details: ${CNTOOLS_BLOCKLOG_ERROR}"
  assert_eq "$(jq -c '.[0].detail | [.reason, .forge_ms, .winner_slot, .winner_ticker, .winner_ms, .vrf_lower, .prev_slot, .next_slot]' <<< "${CNTOOLS_BLOCKLOG_DATA}")|$(jq -c '.[1].detail' <<< "${CNTOOLS_BLOCKLOG_DATA}")" \
    '["height_battle",120,1068,"ABC",2600,0,1063,null]|null' "CNTools block details"
  cntools_blocklog_summary 1 || fail "CNTools summary with height battles: ${CNTOOLS_BLOCKLOG_ERROR}"
  assert_eq "$(jq -c '.[0] | [.heightbattle, .unknown]' <<< "${CNTOOLS_BLOCKLOG_DATA}")" '[1,0]' "CNTools summary counts height battles"
fi

printf 'gliveview-views: all checks passed\n'
