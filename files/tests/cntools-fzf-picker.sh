#!/usr/bin/env bash
# CNTools hotkey menus (core/fzf.sh): every shipped menu keeps a single-key
# hotkey per row, the highlighted start of each name, the filter rule fzf runs
# on each keystroke, the options and keys given to fzf, the pinned version,
# the Navigation setting, and the menu loop's use of fzf with its Gum fallback.
# A fake fzf records what it was given; no terminal is needed.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools fzf picker tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools fzf picker tests skipped: jq is not installed\n'; exit 0; }
command -v awk >/dev/null 2>&1 || { printf 'cntools fzf picker tests skipped: awk is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-fzf.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf "${TEST_ROOT}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
has_line() { grep -qxF -- "$2" "$1" || fail "$3: '$2' not in $(tr '\n' ' ' < "$1")"; }
lacks_line() { ! grep -qxF -- "$2" "$1" || fail "$3: '$2' should not be given"; }

# shellcheck source=/dev/null
for library in number filesystem; do
  . "${CNTOOLS_SOURCE}/lib/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
# shellcheck source=/dev/null
for core in startup log menu action theme settings gum fzf shortcuts; do
  . "${CNTOOLS_SOURCE}/core/${core}.sh" || { printf 'FAIL: cannot load core %s\n' "${core}" >&2; exit 1; }
done
cntools_log() { :; }
cntools_gum_log() { :; }
cntools_ui_seen() { :; }

CNTOOLS_ROOT="${TEST_ROOT}/cntools"
mkdir -m 700 "${CNTOOLS_ROOT}"
CNTOOLS_MODULE_ROOT="${CNTOOLS_SOURCE}/modules/root"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
mkdir -m 700 "${CNTOOLS_TMP_DIR}"
CNTOOLS_MODE=local
CNTOOLS_KOIOS_ENABLED=Y
CNTOOLS_KOIOS_API=https://koios.example
CNTOOLS_GUM_INSTALL_DIR="${TEST_ROOT}/bin"
mkdir -p "${CNTOOLS_GUM_INSTALL_DIR}"
cntools_theme_apply default >/dev/null 2>&1 || cntools_theme_init >/dev/null 2>&1 || true
CNTOOLS_GUM_COLOR_BRAND="#4FBC85"
cntools_settings_state_paths || CNTOOLS_SETTINGS_STATE_DIR="${CNTOOLS_ROOT}/.state"
rebuild_menus() {
  CNTOOLS_MENU_CACHE_READY=N
  cntools_menu_cache_build || { printf 'FAIL: menu cache: %s\n' "${CNTOOLS_MENU_ERROR}" >&2; exit 1; }
}

# ── every menu keeps one key per row ─────────────────────────────────────────
# Back, Home, Go to and Quit share each menu, so their first letters count too.
CNTOOLS_ADVANCED=Y
rebuild_menus
for menu_id in "${!CNTOOLS_MENU_CACHE_MENU_DIRS[@]}"; do
  cntools_menu_cache_open "${CNTOOLS_MENU_CACHE_MENU_DIRS[${menu_id}]}" ||
    { fail "open ${menu_id}: ${CNTOOLS_MENU_ERROR}"; continue; }
  names=("${CNTOOLS_MENU_LABELS[@]}" "Go to")
  [[ "${menu_id}" == "${CNTOOLS_MENU_ROOT_ID}" ]] || names+=(Back Home)
  names+=("Quit CNTools")
  cntools_fzf_hotkey_lengths_into lengths names
  for index in "${!names[@]}"; do
    (( lengths[index] == 1 )) ||
      fail "menu ${menu_id/#@root//}: '${names[index]}' needs ${lengths[index]} keys (labels: ${names[*]})"
  done
done
CNTOOLS_ADVANCED=N
rebuild_menus

# ── the highlighted start of each name ───────────────────────────────────────
names=(Register Retire Rotate "Go to")
cntools_fzf_hotkey_lengths_into lengths names
assert_eq "${lengths[*]}" "3 3 2 1" "shared first letters need more keys"
names=(List "List all" Show)
cntools_fzf_hotkey_lengths_into lengths names
assert_eq "${lengths[*]}" "0 5 1" "a name that starts another has no hotkey"
names=(Wallet withdraw)
cntools_fzf_hotkey_lengths_into lengths names
assert_eq "${lengths[*]}" "2 2" "case is ignored"

keys=($'01\tWallet' $'02\tRetire' $'03\tRotate' $'00\tGo to' $'\tBack')
rows=("01  › Wallet                  Manage wallets" "02  • Retire                  Retire a pool"
      "03  • Rotate                  Rotate KES keys" "00  ↗ Go to                   Jump"
      "← Back")
on=$'\033[1;38;2;79;188;133m' off=$'\033[0m'
unset NO_COLOR
cntools_fzf_menu_lines_into lines menu-a keys rows || fail "lines are built"
assert_eq "${lines[0]}" $'0\t01\tWallet\t01  › '"${on}W${off}"'allet                  Manage wallets' "the first letter is highlighted"
assert_eq "${lines[1]}" $'1\t02\tRetire\t02  • '"${on}Re${off}"'tire                  Retire a pool' "a shared letter highlights the unique start"
assert_eq "${lines[2]}" $'2\t03\tRotate\t03  • '"${on}Ro${off}"'tate                  Rotate KES keys' "and its neighbour's"
assert_eq "${lines[4]}" $'4\t\tBack\t← '"${on}B${off}"'ack' "rows without a number keep an empty number field"
cntools_fzf_menu_lines_into again menu-a keys rows
assert_eq "${again[*]}" "${lines[*]}" "cached lines are the same"
NO_COLOR=1 cntools_fzf_menu_lines_into plain menu-a keys rows
assert_eq "${plain[0]}" $'0\t01\tWallet\t01  › \033[4mW\033[0mallet                  Manage wallets' "NO_COLOR underlines instead"
bad_keys=($'01\tWallet')
cntools_fzf_menu_lines_into bad_lines "" bad_keys rows && fail "keys and rows must have the same length"

# ── the filter fzf runs on each keystroke ────────────────────────────────────
cntools_fzf_filter_program > "${TEST_ROOT}/filter.awk"
printf '%s\n' "${lines[@]}" > "${TEST_ROOT}/rows"
pick() { Q="$1" awk -f "${TEST_ROOT}/filter.awk" "${TEST_ROOT}/rows" | cut -f3 | paste -sd, -; }
assert_eq "$(pick '')" "Wallet,Retire,Rotate,Go to,Back" "an empty query lists every row"
assert_eq "$(pick r)" "Retire,Rotate" "a letter keeps names that start with it"
assert_eq "$(pick RO)" "Rotate" "ignoring case"
assert_eq "$(pick ' w ')" "Wallet" "surrounding spaces are ignored"
assert_eq "$(pick t)" "" "letters inside a name or description never match"
assert_eq "$(pick 0)" "Wallet,Retire,Rotate,Go to" "a digit matches numbers"
assert_eq "$(pick 03)" "Rotate" "two digits pick one row"
assert_eq "$(pick 00)" "Go to" "00 is Go to"
assert_eq "$(pick b)" "Back" "Back has no number but its name"

# ── what fzf is given ────────────────────────────────────────────────────────
FAKE="${CNTOOLS_GUM_INSTALL_DIR}/fzf"
cat > "${FAKE}" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf '%s (fake)\n' "${FAKE_FZF_VERSION:-0.75.0}"; exit 0; fi
log="${FAKE_FZF_LOG:?}"
printf '%s\n' "$@" > "${log}.args"
printf '%s\n' "${FZF_DEFAULT_OPTS-unset}" "${FZF_DEFAULT_OPTS_FILE-unset}" "${FZF_DEFAULT_COMMAND-unset}" > "${log}.env"
cat > "${log}.stdin"
mode="${FAKE_FZF_MODE:-}"
if [[ -z "${mode}" && -s "${FAKE_FZF_QUEUE:-/nonexistent}" ]]; then
  mode="$(head -n 1 "${FAKE_FZF_QUEUE}")"
  tail -n +2 "${FAKE_FZF_QUEUE}" > "${FAKE_FZF_QUEUE}.next" && mv "${FAKE_FZF_QUEUE}.next" "${FAKE_FZF_QUEUE}"
fi
case "${mode:-abort}" in
  accept:*) printf '\n%s\n' "${mode#accept:}"; exit 0 ;;
  esc) printf 'esc\n'; exit 0 ;;
  left) printf 'left\n'; exit 0 ;;
  none) exit 1 ;;
  error) exit 2 ;;
  *) exit 130 ;;
esac
SH
chmod 755 "${FAKE}"
export FAKE_FZF_LOG="${TEST_ROOT}/fzf"
export FZF_DEFAULT_OPTS="--border --preview='echo {}'" FZF_DEFAULT_OPTS_FILE=/dev/null FZF_DEFAULT_COMMAND=ls

CNTOOLS_FZF_BIN=""
CNTOOLS_MENU_NAVIGATION=""
cntools_fzf_find || fail "the pinned fzf in the install folder is found"
assert_eq "${CNTOOLS_FZF_BIN}" "${FAKE}" "and used"
cntools_fzf_available || fail "fzf is used for menus once found"

COLUMNS=120
FAKE_FZF_MODE=accept:2 cntools_fzf_filter chosen 14 keys rows menu-b
assert_eq "$?:${chosen}" "0:${rows[2]}" "the accepted index maps back to its row"
args="${FAKE_FZF_LOG}.args"
for option in --ansi --disabled --no-multi --layout=reverse --accept-nth=1 --with-nth=4 \
    "--with-shell=sh -c" '--bind=enter:transform:[ "$FZF_MATCH_COUNT" -gt 0 ] && echo accept || true' \
    --bind=ctrl-g:ignore,ctrl-q:ignore \
    --expect=esc,left --height=14 --margin=0,22,1,2 --info=hidden --no-separator \
    --no-scrollbar "--gutter= " "--prompt=› " "--pointer=▸ " --footer-border=none --bind=one:accept; do
  has_line "${args}" "${option}" "fzf option"
done
grep -q '^--color=.*prompt:#4FBC85:regular' "${args}" || fail "the theme's colours are passed"
grep -q '^--ghost=Type the highlighted letters' "${args}" || fail "the placeholder says what to type"
grep -q '^--footer=↓↑ navigate • letters open • esc back • enter submit$' "${args}" || fail "the footer lists the keys"
assert_eq "$(paste -sd, - < "${FAKE_FZF_LOG}.env")" "unset,unset,unset" "the user's own fzf defaults are left out"
assert_eq "$(head -n 1 "${FAKE_FZF_LOG}.stdin")" "${lines[0]}" "fzf reads the highlighted lines"
[[ -z "$(find "${CNTOOLS_TMP_DIR}" -mindepth 1 -print -quit)" ]] || fail "the scratch folder is removed"

# What fzf runs on each keystroke works as given: a key that leaves no row is
# dropped, otherwise the list reloads with the rows that match.
step="$(sed -n "s/^--bind=change:transform:sh '\(.*\)' {q}$/\1/p" "${args}")"
[[ -n "${step}" ]] || fail "a change handler is bound"
work="$(cd "${TEST_ROOT}" && mkdir -p "replay dir" && cd "replay dir" && pwd -P)"
cntools_fzf_filter_program > "${work}/filter.awk"
cntools_fzf_step_program > "${work}/step"
printf '%s\n' "${lines[@]}" > "${work}/rows"
assert_eq "$(sh "${work}/step" z)" "backward-delete-char" "a key that leaves no row is dropped"
action="$(sh "${work}/step" r)"
assert_eq "${action}" "reload:env Q={q} awk -f '${work}/filter.awk' '${work}/rows'" "a key that matches reloads"
reload="${action#reload:}"
assert_eq "$(sh -c "${reload//\{q\}/\'r\'}" | cut -f3 | paste -sd, -)" "Retire,Rotate" "and filters by the query"

FAKE_FZF_MODE=esc cntools_fzf_filter chosen 14 keys rows; assert_eq "$?:${chosen}" "1:" "Escape goes back"
FAKE_FZF_MODE=left cntools_fzf_filter chosen 14 keys rows; assert_eq "$?" "1" "Left goes back"
FAKE_FZF_MODE=none cntools_fzf_filter chosen 14 keys rows; assert_eq "$?" "1" "no row goes back"
FAKE_FZF_MODE=abort cntools_fzf_filter chosen 14 keys rows; assert_eq "$?" "130" "Ctrl+C interrupts"
FAKE_FZF_MODE=error cntools_fzf_filter chosen 14 keys rows; assert_eq "$?" "2" "an fzf failure is reported"
FAKE_FZF_MODE=accept:9 cntools_fzf_filter chosen 14 keys rows; assert_eq "$?:${chosen}" "1:" "an unknown index is not a choice"

CNTOOLS_MENU_NAVIGATION=hotkeys-enter
FAKE_FZF_MODE=accept:0 cntools_fzf_filter chosen 14 keys rows
lacks_line "${args}" --bind=one:accept "Hotkeys with Enter does not open on one match"
grep -q '^--footer=.*letters narrow' "${args}" || fail "and its footer says the letters narrow the list"
CNTOOLS_MENU_NAVIGATION=""
NO_COLOR=1 FAKE_FZF_MODE=accept:0 cntools_fzf_filter chosen 14 keys rows
has_line "${args}" --no-color "NO_COLOR turns fzf colours off"
grep -q '^--color=' "${args}" && fail "and no colours are passed"

CNTOOLS_MENU_NAVIGATION=filter
cntools_fzf_available && fail "Filter uses the Gum filter"
CNTOOLS_MENU_NAVIGATION=""

# ── only the pinned version ──────────────────────────────────────────────────
FAKE_FZF_VERSION=0.74.0 cntools_fzf_find && fail "another version is not used"
cntools_fzf_available && fail "and menus fall back to Gum"
CNTOOLS_FZF_BIN="${FAKE}"
FAKE_FZF_VERSION=0.75.1 cntools_fzf_find && fail "a preset path with another version is not used"
assert_eq "${CNTOOLS_FZF_BIN}" "" "and is cleared"
cntools_fzf_find || fail "the pinned version is found again"

# ── the startup offer ────────────────────────────────────────────────────────
CNTOOLS_FZF_BIN="" CNTOOLS_MENU_NAVIGATION=filter
out="$(cntools_fzf_require </dev/null 2>&1)"; assert_eq "$?:${out}" "0:" "Filter is never offered fzf"
CNTOOLS_MENU_NAVIGATION=""
mv "${FAKE}" "${FAKE}.off"
out="$(cntools_fzf_require </dev/null 2>&1)"; assert_eq "$?:${out}" "0:" "no offer without a terminal"
mv "${FAKE}.off" "${FAKE}"
cntools_fzf_declined && fail "nothing is declined yet"
cntools_fzf_remember_decline
cntools_fzf_declined || fail "a no is remembered"
CNTOOLS_FZF_VERSION=0.76.0 cntools_fzf_declined && fail "a newer pin is offered again"
cntools_fzf_forget_decline
cntools_fzf_declined && fail "Navigation forgets the no"

# ── the Navigation setting ───────────────────────────────────────────────────
SETTINGS="${CNTOOLS_ROOT}/.state/transaction-settings.json"
cntools_settings_defaults
CNTOOLS_FLOW_STYLE="" CNTOOLS_MENU_NAVIGATION=""
cntools_settings_snapshot
cntools_navigation_save hotkeys-enter || fail "navigation is saved"
assert_eq "$(jq -r .interaction.navigation "${SETTINGS}")" "hotkeys-enter" "and stored"
CNTOOLS_MENU_NAVIGATION=""
cntools_settings_reload || fail "settings reload"
assert_eq "${CNTOOLS_MENU_NAVIGATION}" "hotkeys-enter" "the saved choice is read back"
cntools_navigation_save bogus 2>/dev/null; assert_eq "$?" "2" "an unknown choice is refused"
jq '.interaction.navigation = "bogus"' "${SETTINGS}" > "${SETTINGS}.edit" && cat "${SETTINGS}.edit" > "${SETTINGS}"
cntools_settings_file_valid "${SETTINGS}" && fail "a file with an unknown navigation is invalid"
jq 'del(.interaction.navigation)' "${SETTINGS}" > "${SETTINGS}.edit" && cat "${SETTINGS}.edit" > "${SETTINGS}"
cntools_settings_file_valid "${SETTINGS}" || fail "a file without navigation stays valid"
assert_eq "$(cntools_navigation_name hotkeys)/$(cntools_navigation_name)/$(cntools_navigation_name filter)" \
  "Hotkeys/Hotkeys with Enter/Filter" "names"
CNTOOLS_MENU_NAVIGATION=""

# ── the menu loop ────────────────────────────────────────────────────────────
cntools_gum_header() { :; }
cntools_gum_header_rows() { printf '6\n'; }
cntools_gum_filter_height() { printf '12\n'; }
cntools_gum_clear() { :; }
cntools_update_state_load() { :; }
cntools_ui_render_status() { STATUS_SEEN+=("$1: $2"); }
cntools_ui_status_rows_into() { printf -v "$1" '%s' 4; }
cntools_action_run() { RAN+=("${1#"${CNTOOLS_MODULE_ROOT}/"}"); return 0; }
cntools_gum_filter() {
  GUM_USED+=("${CNTOOLS_MENU_ID}")
  local _tf_out="$1"; shift 2
  local _tf_row=""
  for _tf_row in "$@"; do
    [[ "${_tf_row}" == "✕ Quit CNTools" ]] || continue
    printf -v "${_tf_out}" '%s' "${_tf_row}"; return 0
  done
  return 130
}
# Index of a row in a menu as the loop lists it: items, Go to, Back, Home, Quit.
row_of() {
  local menu_id="$1" label="$2" index=0
  cntools_menu_cache_open "${CNTOOLS_MENU_CACHE_MENU_DIRS[${menu_id}]}" || return 1
  case "${label}" in
    "Go to") printf '%s\n' "${#CNTOOLS_MENU_LABELS[@]}"; return 0 ;;
    Back) printf '%s\n' "$(( ${#CNTOOLS_MENU_LABELS[@]} + 1 ))"; return 0 ;;
    Quit) if [[ "${menu_id}" == "${CNTOOLS_MENU_ROOT_ID}" ]]; then
            printf '%s\n' "$(( ${#CNTOOLS_MENU_LABELS[@]} + 1 ))"
          else printf '%s\n' "$(( ${#CNTOOLS_MENU_LABELS[@]} + 3 ))"; fi
          return 0 ;;
  esac
  for index in "${!CNTOOLS_MENU_LABELS[@]}"; do
    [[ "${CNTOOLS_MENU_LABELS[index]}" != "${label}" ]] || { printf '%s\n' "${index}"; return 0; }
  done
  return 1
}
run_menu() { # run_menu <fzf answers…>
  RAN=() STATUS_SEEN=() GUM_USED=()
  printf '%s\n' "$@" > "${TEST_ROOT}/queue"
  MENU_STATUS=0
  FAKE_FZF_QUEUE="${TEST_ROOT}/queue" cntools_gum_menu_run || MENU_STATUS=$?
}
export FAKE_FZF_QUEUE=""
cntools_fzf_find || fail "fzf for the menu loop"
pool="$(row_of "${CNTOOLS_MENU_ROOT_ID}" Pool)" rotate="$(row_of pool "KES Rotate")"
pool_quit="$(row_of pool Quit)" pool_back="$(row_of pool Back)" root_quit="$(row_of "${CNTOOLS_MENU_ROOT_ID}" Quit)"
run_menu "accept:${pool}" "accept:${rotate}" "accept:${pool_quit}"
assert_eq "${MENU_STATUS}:${RAN[*]}:${GUM_USED[*]}" "0:pool/rotate:" "fzf opens a menu, runs an action and quits"
grep -q $'\tKES Rotate\t' "${FAKE_FZF_LOG}.stdin" || fail "the pool menu was shown through fzf"
run_menu "accept:${pool}" esc "accept:${root_quit}"
assert_eq "${MENU_STATUS}:${RAN[*]}" "0:" "Escape returns to the parent menu"
run_menu "accept:${pool}" "accept:${pool_back}" "accept:${root_quit}"
assert_eq "${MENU_STATUS}" "0" "the Back row works"
run_menu error
assert_eq "${MENU_STATUS}:${GUM_USED[*]}" "0:/" "a failing fzf hands the menu to the Gum filter"
[[ "${STATUS_SEEN[*]}" == *"fzf stopped working (status 2)"* ]] || fail "and says so: ${STATUS_SEEN[*]}"
cntools_fzf_available && fail "fzf stays off for the session after a failure"

if (( failures > 0 )); then
  printf '%s cntools fzf picker check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools fzf picker tests passed\n'
