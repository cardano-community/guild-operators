#!/usr/bin/env bash
# CNTools Go to and shortcuts: the saved store and its safety checks, the Go to
# screen, and the menu loop's jump to a menu or action over the real menu
# tree. Gum's prompts are replaced by scripted answers; no terminal is needed.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools shortcut tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools shortcut tests skipped: jq is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-shortcuts.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

# shellcheck source=/dev/null
for library in number filesystem; do
  . "${CNTOOLS_SOURCE}/lib/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
# shellcheck source=/dev/null
for core in startup log menu action theme settings gum shortcuts; do
  . "${CNTOOLS_SOURCE}/core/${core}.sh" || { printf 'FAIL: cannot load core %s\n' "${core}" >&2; exit 1; }
done
cntools_log() { :; }
cntools_gum_log() { :; }

CNTOOLS_ROOT="${TEST_ROOT}/cntools"
mkdir -m 700 "${CNTOOLS_ROOT}"
CNTOOLS_MODULE_ROOT="${CNTOOLS_SOURCE}/modules/root"
CNTOOLS_MODE=local
CNTOOLS_ADVANCED=N
CNTOOLS_KOIOS_ENABLED=Y
CNTOOLS_KOIOS_API=https://koios.example
cntools_settings_state_paths || CNTOOLS_SETTINGS_STATE_DIR="${CNTOOLS_ROOT}/.state"
SHORTCUTS="${CNTOOLS_ROOT}/.state/shortcuts.json"
rebuild_menus() {
  CNTOOLS_MENU_CACHE_READY=N
  cntools_menu_cache_build || { printf 'FAIL: menu cache: %s\n' "${CNTOOLS_MENU_ERROR}" >&2; exit 1; }
}
rebuild_menus
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# ── the store ────────────────────────────────────────────────────────────────
cntools_shortcuts_load
assert_eq "${CNTOOLS_SHORTCUTS_STATE}:${#CNTOOLS_SHORTCUTS_CODES[@]}" "none:0" "no file yet"
cntools_shortcuts_assign pr pool/register || fail "save pr for Pool / Register"
[[ -f "${SHORTCUTS}" ]] || fail "the shortcuts file is written"
assert_eq "$(mode_of "${SHORTCUTS}")" "600" "the shortcuts file is private"
assert_eq "$(mode_of "${CNTOOLS_ROOT}/.state")" "700" "the state folder is private"
assert_eq "$(jq -c . "${SHORTCUTS}")" '{"schemaVersion":1,"shortcuts":[{"code":"pr","target":"pool/register"}]}' "file format"
cntools_shortcuts_assign w wallet/new || fail "save w"
cntools_shortcuts_assign 1 funds/send || fail "save 1"
assert_eq "$(jq -r '[.shortcuts[].code] | join(",")' "${SHORTCUTS}")" "1,pr,w" "saved sorted by code"
assert_eq "${CNTOOLS_SHORTCUTS_STATE}:${CNTOOLS_SHORTCUTS_CODES[*]}" "ok:1 pr w" "loaded after a save"
cntools_shortcuts_assign wn wallet/new || fail "a new code for Wallet / New"
assert_eq "$(jq -r '[.shortcuts[] | select(.target == "wallet/new") | .code] | join(",")' "${SHORTCUTS}")" "wn" "an entry keeps one code"
cntools_shortcuts_assign pr pool/retire || fail "move pr to Pool / Retire"
assert_eq "$(jq -r '[.shortcuts[] | select(.code == "pr") | .target] | join(",")' "${SHORTCUTS}")" "pool/retire" "a code goes to one entry"
assert_eq "$(jq '.shortcuts | length' "${SHORTCUTS}")" "3" "moving a code leaves the old entry without one"
for bad in "" ABCDE a-b "p r" 12345; do
  cntools_shortcuts_assign "${bad}" pool/register && fail "code '${bad}' accepted"
done
cntools_shortcuts_assign AB pool/register; assert_eq "$?" "2" "upper case is lowered by the prompts, not the store"
for bad in "" ../x "pool/../wallet" "Pool/register" "/pool" "pool/" "pool//register"; do
  cntools_shortcuts_assign zz "${bad}" && fail "target '${bad}' accepted"
done
cntools_shortcuts_remove wn || fail "remove wn"
assert_eq "$(jq -r '[.shortcuts[].code] | join(",")' "${SHORTCUTS}")" "1,pr" "removed one"
cntools_shortcuts_remove_all || fail "remove all"
assert_eq "$(jq -c .shortcuts "${SHORTCUTS}")" "[]" "removed all"
for (( n = 0; n < CNTOOLS_SHORTCUTS_MAX; n++ )); do
  CNTOOLS_SHORTCUTS_CODES[n]="c${n}"; CNTOOLS_SHORTCUTS_TARGETS[n]="pool/t${n}"
done
cntools_shortcuts_save || fail "save ${CNTOOLS_SHORTCUTS_MAX} shortcuts"
cntools_shortcuts_assign pr pool/register; assert_eq "$?" "3" "the list is full"
cntools_shortcuts_assign c5 pool/register || fail "moving a code into a full list"
cntools_shortcuts_remove_all

# A file CNTools cannot read is left alone until Start again moves it aside.
printf '{"schemaVersion":1,"shortcuts":[{"code":"pr","target":"pool/register","x":1}]}\n' > "${SHORTCUTS}"
chmod 600 "${SHORTCUTS}"
before="$(cat "${SHORTCUTS}")"
cntools_shortcuts_load
assert_eq "${CNTOOLS_SHORTCUTS_STATE}" "invalid" "an unknown field"
cntools_shortcuts_assign w wallet/new && fail "an unreadable file is overwritten"
assert_eq "$(cat "${SHORTCUTS}")" "${before}" "the unreadable file is unchanged"
cntools_shortcuts_set_aside || fail "set the unreadable file aside"
[[ -f "${CNTOOLS_SHORTCUTS_ASIDE_FILE}" && "${CNTOOLS_SHORTCUTS_ASIDE_FILE}" == "${SHORTCUTS}.invalid-"* ]] ||
  fail "the old file is kept as shortcuts.json.invalid-<time>"
assert_eq "${CNTOOLS_SHORTCUTS_STATE}" "none" "after Start again"
for content in 'not json' '{"schemaVersion":2,"shortcuts":[]}' \
  '{"schemaVersion":1,"shortcuts":[{"code":"pr","target":"pool/register"},{"code":"pr","target":"pool/retire"}]}' \
  '{"schemaVersion":1,"shortcuts":[{"code":"pr","target":"pool/register"},{"code":"p2","target":"pool/register"}]}' \
  '{"schemaVersion":1,"shortcuts":[{"code":"PR","target":"pool/register"}]}' \
  '{"schemaVersion":1,"shortcuts":[{"code":"pr","target":"../pool"}]}'; do
  printf '%s\n' "${content}" > "${SHORTCUTS}"; chmod 600 "${SHORTCUTS}"
  cntools_shortcuts_load
  assert_eq "${CNTOOLS_SHORTCUTS_STATE}" "invalid" "rejects ${content}"
done
rm -f -- "${SHORTCUTS}"
cntools_shortcuts_load; cntools_shortcuts_assign pr pool/register || fail "save after removing the file"
chmod 644 "${SHORTCUTS}"; cntools_shortcuts_load
assert_eq "${CNTOOLS_SHORTCUTS_STATE}" "invalid" "a file others can read"
chmod 600 "${SHORTCUTS}"
mv "${SHORTCUTS}" "${TEST_ROOT}/real.json"; ln -s "${TEST_ROOT}/real.json" "${SHORTCUTS}"
cntools_shortcuts_load
assert_eq "${CNTOOLS_SHORTCUTS_STATE}" "invalid" "a symbolic link"
rm -f -- "${SHORTCUTS}"; mv "${TEST_ROOT}/real.json" "${SHORTCUTS}"
( failures=0; CNTOOLS_SETTINGS_STATE_DIR=""; cntools_shortcuts_load; assert_eq "${CNTOOLS_SHORTCUTS_STATE}" "unavailable" "no state folder"
  cntools_shortcuts_assign w wallet/new && fail "saved without a state folder"; exit "${failures}" ) || failures=$((failures + $?))
ls "${CNTOOLS_ROOT}/.state"/.shortcuts.* >/dev/null 2>&1 && fail "a staging file is left behind"

# ── targets ──────────────────────────────────────────────────────────────────
cntools_shortcuts_target_status pool/register; assert_eq "$?" "0" "Pool / Register is shown"
cntools_shortcuts_target_status advanced/multisig; assert_eq "$?" "3" "advanced entries are hidden without -a"
cntools_shortcuts_target_status settings/theme; assert_eq "$?" "3" "an advanced action is hidden without -a"
cntools_shortcuts_target_status pool/gone; assert_eq "$?" "4" "a removed entry"
cntools_shortcuts_target_name_into name pool/register; assert_eq "${name}" "Pool / Register" "name of a shown entry"
cntools_shortcuts_target_name_into name advanced/multisig; assert_eq "${name}" "Advanced / MultiSig" "name of a hidden entry"
cntools_shortcuts_target_name_into name pool/gone; assert_eq "${name}" "pool/gone" "a removed entry is shown by its id"
CNTOOLS_SHORTCUTS_CODES=(ms pr x); CNTOOLS_SHORTCUTS_TARGETS=(advanced/multisig pool/register pool/gone)
cntools_shortcuts_resolve_into target pr; assert_eq "$?:${target}" "0:pool/register" "resolve pr"
cntools_shortcuts_resolve_into target ms; assert_eq "$?:${target}" "3:advanced/multisig" "resolve a hidden target"
cntools_shortcuts_resolve_into target x; assert_eq "$?:${target}" "4:pool/gone" "resolve a removed target"
cntools_shortcuts_resolve_into target zz; assert_eq "$?:${target}" "1:" "no such code"
cntools_shortcuts_resolve_into target ""; assert_eq "$?" "1" "empty text is not a code"

# ── the list of every menu and action ────────────────────────────────────────
cntools_shortcuts_entries_collect || fail "collect entries"
expected=0
for menu_id in "${!CNTOOLS_MENU_CACHE_MENU_COUNTS[@]}"; do
  expected=$((expected + CNTOOLS_MENU_CACHE_MENU_COUNTS[${menu_id}]))
done
assert_eq "${#CNTOOLS_SHORTCUTS_ENTRY_IDS[@]}" "${expected}" "every cached entry is listed"
index_of() { local i; for i in "${!CNTOOLS_SHORTCUTS_ENTRY_IDS[@]}"; do [[ "${CNTOOLS_SHORTCUTS_ENTRY_IDS[i]}" == "$1" ]] && { printf '%s' "${i}"; return 0; }; done; printf -- '-1'; }
(( $(index_of pool) >= 0 && $(index_of pool) < $(index_of pool/register) )) || fail "a menu comes before its entries"
(( $(index_of wallet/new) < $(index_of wallet/new/cli) )) || fail "a nested menu comes before its entries"
assert_eq "$(index_of advanced)" "-1" "hidden advanced entries are not listed"
row="${CNTOOLS_SHORTCUTS_ENTRY_ROWS[$(index_of pool/register)]}"
[[ "${row}" == "• Pool / Register "*"  · shortcut pr" ]] || fail "a row shows its shortcut code: '${row}'"
[[ "${CNTOOLS_SHORTCUTS_ENTRY_ROWS[$(index_of pool)]}" == "› Pool "* ]] || fail "a menu row: '${CNTOOLS_SHORTCUTS_ENTRY_ROWS[$(index_of pool)]}'"
assert_eq "$(printf '%s\n' "${CNTOOLS_SHORTCUTS_ENTRY_ROWS[@]}" | sort | uniq -d)" "" "rows are unique"
# Gum trims its input, so a row with outer spaces would not match its choice.
for row in "${CNTOOLS_SHORTCUTS_ENTRY_ROWS[@]}"; do
  [[ "${row}" != [[:space:]]* && "${row}" != *[[:space:]] ]] || fail "a row starts or ends with a space: '${row}'"
done

# Typing 00 in any menu finds only the Go to row.
for advanced in N Y; do
  CNTOOLS_ADVANCED="${advanced}"; rebuild_menus
  for menu_id in "${!CNTOOLS_MENU_CACHE_MENU_DIRS[@]}"; do
    cntools_menu_cache_open "${CNTOOLS_MENU_CACHE_MENU_DIRS[${menu_id}]}" || fail "open ${menu_id}"
    for (( i = 0; i < ${#CNTOOLS_MENU_IDS[@]}; i++ )); do
      cntools_gum_menu_row_into row "${i}"
      [[ "${row}" != *00* ]] || fail "menu row contains 00: ${row}"
    done
  done
done
CNTOOLS_ADVANCED=N; rebuild_menus

# ── the Go to screen ─────────────────────────────────────────────────────────
cntools_ui_render_begin() { :; }
cntools_ui_render_detail() { :; }
cntools_ui_table() { cat >/dev/null; }
cntools_ui_content_width() { printf '100\n'; }
cntools_ui_render_status() { STATUS_SEEN+=("$1: $2"); }
cntools_ui_input() {
  local _ti_out="$1" _ti_answer="${INPUTS[0]-}"
  INPUTS=("${INPUTS[@]:1}")
  [[ "${_ti_answer}" != ESC ]] || return 1
  printf -v "${_ti_out}" '%s' "${_ti_answer}"
}
cntools_ui_choose_matching() {
  local _tc_out="$1" _tc_want="${PICKS[0]-}" _tc_row=""
  CHOOSE_CALLS+=("$3|$4")
  PICKS=("${PICKS[@]:1}")
  shift 4
  [[ "${_tc_want}" != ESC ]] || return 1
  for _tc_row in "$@"; do
    [[ "${_tc_row}" == *"${_tc_want}"* ]] || continue
    printf -v "${_tc_out}" '%s' "${_tc_row}"; return 0
  done
  return 9
}
goto() { # goto <inputs…> -- <picks…>
  INPUTS=() PICKS=() CHOOSE_CALLS=() STATUS_SEEN=()
  while [[ $# -gt 0 && "$1" != -- ]]; do INPUTS+=("$1"); shift; done
  shift
  PICKS=("$@")
  GOTO_STATUS=0
  cntools_shortcuts_goto_into GOTO_TARGET || GOTO_STATUS=$?
}
cntools_shortcuts_remove_all
cntools_shortcuts_assign pr pool/register
cntools_shortcuts_assign ms advanced/multisig
goto PR --
assert_eq "${GOTO_STATUS}:${GOTO_TARGET}:${#CHOOSE_CALLS[@]}" "0:pool/register:0" "a code, in any case, goes straight to its entry"
goto regis -- "Pool / Register"
assert_eq "${GOTO_STATUS}:${GOTO_TARGET}:${CHOOSE_CALLS[*]}" "0:pool/register:regis|Y" "text searches, and a single match is picked"
goto "" -- "› Vote / Governance "
assert_eq "${GOTO_STATUS}:${GOTO_TARGET}:${CHOOSE_CALLS[*]}" "0:vote/governance:|N" "Enter alone lists everything"
goto ESC --
assert_eq "${GOTO_STATUS}:${GOTO_TARGET}" "1:" "Escape leaves Go to"
goto nothing ESC -- ESC
assert_eq "${GOTO_STATUS}:${#CHOOSE_CALLS[@]}" "1:1" "Escape in the list returns to the Go to prompt"
goto ms ESC --
assert_eq "${GOTO_STATUS}" "1" "a hidden target is not opened"
[[ "${STATUS_SEEN[*]}" == *"Shortcut ms goes to Advanced / MultiSig, which is shown only when CNTools starts with -a."* ]] ||
  fail "a hidden target says why: ${STATUS_SEEN[*]}"

# ── the menu loop ────────────────────────────────────────────────────────────
cntools_gum_header() { :; }
cntools_gum_header_rows() { printf '6\n'; }
cntools_gum_filter_height() { printf '10\n'; }
cntools_gum_clear() { :; }
cntools_update_state_load() { :; }
cntools_ui_status_rows_into() { printf -v "$1" '%s' 4; }
cntools_action_run() { RAN+=("${1#"${CNTOOLS_MODULE_ROOT}/"}"); return "${ACTION_STATUS:-0}"; }
cntools_shortcuts_goto_into() {
  local _tg_answer="${GOTO_ANSWERS[0]-}"
  GOTO_ANSWERS=("${GOTO_ANSWERS[@]:1}")
  [[ "${_tg_answer}" != ESC ]] || return 1
  printf -v "$1" '%s' "${_tg_answer}"
}
cntools_gum_filter() {
  local _tf_out="$1" _tf_want="${FILTER_PICKS[0]-}" _tf_row=""
  SHOWN+=("${CNTOOLS_MENU_ID}")
  FILTER_PICKS=("${FILTER_PICKS[@]:1}")
  shift 2
  [[ -n "${_tf_want}" ]] || return 130
  for _tf_row in "$@"; do
    [[ "${_tf_row}" == *"${_tf_want}"* ]] || continue
    printf -v "${_tf_out}" '%s' "${_tf_row}"; return 0
  done
  return 130
}
menu() { # menu <go to answers…> -- <rows to pick…>
  GOTO_ANSWERS=() FILTER_PICKS=() SHOWN=() RAN=() STATUS_SEEN=()
  while [[ $# -gt 0 && "$1" != -- ]]; do GOTO_ANSWERS+=("$1"); shift; done
  shift
  FILTER_PICKS=("$@")
  MENU_STATUS=0
  cntools_gum_menu_run || MENU_STATUS=$?
}
menu pool/register -- "↗ Go to" "← Back" "✕ Quit"
assert_eq "${MENU_STATUS}" "0" "jump to an action"
assert_eq "${RAN[*]}" "pool/register" "the action runs"
assert_eq "${SHOWN[*]}" "/ pool /" "then its own menu is shown, and Back goes to its parent"
menu vote/governance -- "↗ Go to" "← Back" "⌂ Home" "✕ Quit"
assert_eq "${MENU_STATUS}:${RAN[*]}" "0:" "jump to a menu runs nothing"
assert_eq "${SHOWN[*]}" "/ vote/governance vote /" "a menu target opens with its parents behind it"
menu wallet/new/cli -- "› Pool " "↗ Go to" "⌂ Home" "✕ Quit"
assert_eq "${RAN[*]}" "wallet/new/cli" "jump from a submenu to a nested action"
assert_eq "${SHOWN[*]}" "/ pool wallet/new /" "the nested action's menu is shown after it"
menu ESC -- "› Pool " "↗ Go to" "✕ Quit"
assert_eq "${RAN[*]}:${SHOWN[*]}" ":/ pool pool" "cancelling Go to returns to the menu it was opened from"
menu -- "› Pool " "• Register " "✕ Quit"
assert_eq "${RAN[*]}:${SHOWN[*]}" "pool/register:/ pool pool" "Enter on a row still runs it"
ACTION_STATUS=5 menu pool/register -- "↗ Go to" "✕ Quit"
[[ "${STATUS_SEEN[*]}" == *"Register failed (status 5)"* ]] || fail "a failed action is reported after a jump: ${STATUS_SEEN[*]}"
CNTOOLS_MODE=offline; rebuild_menus
menu pool/register -- "↗ Go to" "✕ Quit"
assert_eq "${RAN[*]}:${SHOWN[*]}" ":/ pool" "an action that is unavailable here is not run"
[[ "${STATUS_SEEN[*]}" == *"Not available in offline mode"* ]] || fail "and its menu says why: ${STATUS_SEEN[*]}"
CNTOOLS_MODE=local; rebuild_menus

if (( failures > 0 )); then
  printf '%s cntools shortcut check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools shortcut tests passed\n'
