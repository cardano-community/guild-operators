#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2153,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools theme tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
THEME_CORE="${CNTOOLS_ROOT}/core/theme.sh"
THEME_ACTION="${CNTOOLS_ROOT}/modules/root/advanced/theme/action.sh"
THEME_METADATA="${CNTOOLS_ROOT}/modules/root/advanced/theme/module.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-theme.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
CNTOOLS_NODE_HOME="${TEST_ROOT}/node"

cleanup_test() {
  chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="${3:-values differ}"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_status() {
  local expected="$1"
  local context="$2"
  local actual=0
  shift 2

  if "$@"; then
    actual=0
  else
    actual=$?
  fi
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected status ${expected}, got ${actual}"
}

file_mode() {
  local target="$1"
  local mode=""

  if mode="$(stat -c '%a' -- "${target}" 2>/dev/null)"; then
    :
  else
    mode="$(stat -f '%Lp' "${target}")"
  fi
  printf '%s\n' "${mode#0}"
}

for required_command in \
  bash chmod find jq ln mktemp mkdir mv rm stat wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
for required_file in "${THEME_CORE}" "${THEME_ACTION}" "${THEME_METADATA}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" &&
     -s "${required_file}" ]] ||
    fail "theme source is missing or unsafe: ${required_file}"
  bash -n "${required_file}" ||
    fail "theme source has invalid Bash syntax: ${required_file}"
done
jq -e '
  .kind == "action" and .label == "Theme" and .shortcut == "t" and
  .order == 50 and .modes == ["local", "light", "offline"] and
  ((has("libs") | not) or .libs == [])
' "${THEME_METADATA}" >/dev/null || fail "Theme metadata is invalid"

# shellcheck source=/dev/null
. "${THEME_CORE}"

assert_eq "${#CNTOOLS_THEME_IDS[@]}" "1" "initial theme count"
assert_eq "${CNTOOLS_THEME_IDS[0]}" "default" "initial theme ID"
assert_eq "$(cntools_theme_display_name default)" "Default" \
  "default theme name"
assert_eq "${CNTOOLS_GUM_COLOR_BRAND}" "#4FBC85" \
  "default Koios accent"
assert_status 2 "unknown theme was accepted" cntools_theme_apply unknown

mkdir -m 0700 -- "${CNTOOLS_NODE_HOME}"
cntools_theme_init || fail "default theme initialization failed"
assert_eq "${CNTOOLS_THEME_ID}" "default" "initialized theme"
assert_eq "${CNTOOLS_THEME_STATE_FILE}" \
  "${CNTOOLS_NODE_HOME}/.cntools/theme" "theme state path"
cntools_theme_save default || fail "default theme could not be persisted"
assert_eq "$(< "${CNTOOLS_THEME_STATE_FILE}")" "default" \
  "persisted theme ID"
assert_eq "$(file_mode "${CNTOOLS_THEME_STATE_DIR}")" "700" \
  "theme state directory mode"
assert_eq "$(file_mode "${CNTOOLS_THEME_STATE_FILE}")" "600" \
  "theme state file mode"
[[ -z "$(find "${CNTOOLS_THEME_STATE_DIR}" -maxdepth 1 \
  -name '.theme.*' -print -quit)" ]] ||
  fail "atomic theme save retained a staging file"

saved_theme=""
cntools_theme_read_into saved_theme || fail "saved theme could not be read"
assert_eq "${saved_theme}" "default" "saved theme read"

CNTOOLS_GUM_STATIC_HEADER_KEY="cached"
CNTOOLS_THEME_ID="synthetic"
cntools_theme_reload || fail "saved theme could not be activated"
assert_eq "${CNTOOLS_THEME_ID}" "default" "reloaded theme"
assert_eq "${CNTOOLS_GUM_STATIC_HEADER_KEY}" "" \
  "theme reload cache invalidation"

CNTOOLS_UI_INTERACTIVE="N"
styled=""
cntools_theme_style_value_into styled number "1,234.500000" ||
  fail "non-interactive number styling failed"
assert_eq "${styled}" "1,234.500000" "non-interactive styling"
CNTOOLS_UI_INTERACTIVE="Y"
unset NO_COLOR
cntools_theme_style_value_into styled number "1,234.500000" ||
  fail "interactive number styling failed"
assert_eq "${styled}" \
  $'\033[38;2;216;188;122m1,234.500000\033[0m' \
  "semantic number color"
NO_COLOR=1
cntools_theme_style_value_into styled address "addr_test1safe" ||
  fail "NO_COLOR address styling failed"
assert_eq "${styled}" "addr_test1safe" "NO_COLOR styling"
unset NO_COLOR
assert_status 2 "terminal escape injection was accepted" \
  cntools_theme_style_value_into styled number $'1\033[31m'

# A private final file is insufficient when its containing directory can be
# replaced by another user. Unsafe directory and file modes must be ignored.
chmod 0770 "${CNTOOLS_THEME_STATE_DIR}"
assert_status 1 "group-writable theme directory was accepted" \
  cntools_theme_read_into saved_theme
chmod 0700 "${CNTOOLS_THEME_STATE_DIR}"
chmod 0660 "${CNTOOLS_THEME_STATE_FILE}"
assert_status 1 "group-writable theme file was accepted" \
  cntools_theme_read_into saved_theme
chmod 0600 "${CNTOOLS_THEME_STATE_FILE}"

printf '%065d\n' 0 > "${CNTOOLS_THEME_STATE_FILE}"
chmod 0600 "${CNTOOLS_THEME_STATE_FILE}"
assert_status 2 "oversized theme state was accepted" \
  cntools_theme_read_into saved_theme
printf 'default\nextra\n' > "${CNTOOLS_THEME_STATE_FILE}"
assert_status 2 "multi-line theme state was accepted" \
  cntools_theme_read_into saved_theme
printf 'unknown\n' > "${CNTOOLS_THEME_STATE_FILE}"
assert_status 2 "unknown saved theme was accepted" \
  cntools_theme_read_into saved_theme
printf 'default\n' > "${CNTOOLS_THEME_STATE_FILE}"

mv -- "${CNTOOLS_THEME_STATE_FILE}" "${TEST_ROOT}/real-theme"
ln -s "${TEST_ROOT}/real-theme" "${CNTOOLS_THEME_STATE_FILE}"
assert_status 1 "symbolic-link theme file was accepted" \
  cntools_theme_read_into saved_theme
rm -- "${CNTOOLS_THEME_STATE_FILE}"
mv -- "${TEST_ROOT}/real-theme" "${CNTOOLS_THEME_STATE_FILE}"

mv -- "${CNTOOLS_THEME_STATE_DIR}" "${TEST_ROOT}/real-state"
ln -s "${TEST_ROOT}/real-state" "${CNTOOLS_THEME_STATE_DIR}"
assert_status 1 "symbolic-link theme directory was accepted for reading" \
  cntools_theme_read_into saved_theme
assert_status 1 "symbolic-link theme directory was accepted for saving" \
  cntools_theme_save default
rm -- "${CNTOOLS_THEME_STATE_DIR}"
mv -- "${TEST_ROOT}/real-state" "${CNTOOLS_THEME_STATE_DIR}"

# The Theme action owns save staging created in its action subshell.
# shellcheck source=/dev/null
. "${THEME_ACTION}"
CNTOOLS_THEME_STAGE_FILE="$(mktemp \
  "${CNTOOLS_THEME_STATE_DIR}/.theme.XXXXXX")"
cntools_action_cleanup
[[ ! -e "${CNTOOLS_THEME_STAGE_FILE:-/invalid}" ]] ||
  fail "Theme action cleanup retained a staging file"

(
  local_status="${TEST_ROOT}/theme-action-status"
  cntools_ui_action_begin() { return 0; }
  cntools_ui_choose() {
    printf -v "$1" '%s' "Default  ·  Current"
  }
  cntools_ui_render_status() {
    printf '%s\t%s\n' "$1" "$2" > "${local_status}"
  }
  cntools_ui_wait() { return 0; }
  cntools_gum_clear() { return 0; }
  cntools_log() { return 0; }

  cntools_action_main || fail "Theme action could not select Default"
  assert_eq "$(< "${CNTOOLS_THEME_STATE_FILE}")" "default" \
    "Theme action persisted selection"
  grep -F $'success\tDefault is now the active CNTools theme.' \
    "${local_status}" >/dev/null ||
    fail "Theme action did not render selection feedback"
)

(
  clear_marker="${TEST_ROOT}/theme-action-cancelled"
  cntools_ui_action_begin() { return 0; }
  cntools_ui_choose() { return 1; }
  cntools_gum_clear() { : > "${clear_marker}"; }
  cntools_log() { return 0; }

  cntools_action_main || fail "Theme action treated cancellation as failure"
  [[ -f "${clear_marker}" ]] ||
    fail "Theme action did not clear a cancelled selector"
)

(
  cntools_ui_action_begin() { return 0; }
  cntools_ui_choose() { printf -v "$1" '%s' "forged theme row"; }
  cntools_log() { return 0; }

  assert_status 2 "Theme action accepted an unknown selector row" \
    cntools_action_main
)

printf 'CNTools theme tests passed\n'
