#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools framework tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-framework.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"

cleanup_test() {
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

assert_fails() {
  local context="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    fail "${context}"
  fi
}

for required_command in bash chmod cp grep jq ln mktemp mv rm stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for core_file in log ui menu action update; do
  [[ -f "${CNTOOLS_ROOT}/core/${core_file}.sh" ]] ||
    fail "missing Phase 3 core file: core/${core_file}.sh"
  # shellcheck source=/dev/null
  . "${CNTOOLS_ROOT}/core/${core_file}.sh" ||
    fail "unable to load Phase 3 core file: core/${core_file}.sh"
done

for required_function in \
  cntools_log_init cntools_log cntools_log_close \
  cntools_run_command cntools_http_request \
  cntools_ui_session_enter cntools_ui_suspend_for_job_control \
  cntools_ui_render_field cntools_ui_render_detail cntools_ui_read_key \
  cntools_ui_restore_terminal cntools_ui_cleanup \
  cntools_menu_validate_metadata cntools_menu_open cntools_menu_cache_build \
  cntools_menu_cache_open \
  cntools_menu_validate_tree cntools_action_run; do
  declare -F "${required_function}" >/dev/null 2>&1 ||
    fail "missing Phase 3 function: ${required_function}"
done

write_file() {
  local target="$1"
  local content="$2"

  printf '%s\n' "${content}" > "${target}"
}

make_root() {
  local tree="$1"

  mkdir -p "${tree}/root" "${tree}/lib"
  jq -n '{
    kind: "menu",
    label: "CNTools",
    description: "Synthetic framework test root"
  }' > "${tree}/root/module.json"
}

make_menu() {
  local directory="$1"
  local label="$2"
  local shortcut="$3"
  local order="$4"
  local advanced="${5:-N}"

  mkdir -p "${directory}"
  if [[ "${advanced}" == "Y" ]]; then
    jq -n \
      --arg label "${label}" \
      --arg shortcut "${shortcut}" \
      --argjson order "${order}" '{
        kind: "menu",
        label: $label,
        description: ($label + " test menu"),
        shortcut: $shortcut,
        order: $order,
        advanced: true
      }' > "${directory}/module.json"
  else
    jq -n \
      --arg label "${label}" \
      --arg shortcut "${shortcut}" \
      --argjson order "${order}" '{
        kind: "menu",
        label: $label,
        description: ($label + " test menu"),
        shortcut: $shortcut,
        order: $order
      }' > "${directory}/module.json"
  fi
}

make_action() {
  local directory="$1"
  local label="$2"
  local shortcut="$3"
  local order="$4"
  local modes="$5"
  local libs="${6:-[]}"

  mkdir -p "${directory}"
  jq -n \
    --arg label "${label}" \
    --arg shortcut "${shortcut}" \
    --argjson order "${order}" \
    --argjson modes "${modes}" \
    --argjson libs "${libs}" '{
      kind: "action",
      label: $label,
      description: ($label + " test action"),
      shortcut: $shortcut,
      order: $order,
      modes: $modes,
      libs: $libs
    }' > "${directory}/module.json"
  write_file "${directory}/action.sh" '#!/usr/bin/env bash
cntools_action_main() {
  return 0
}'
}

replace_json() {
  local target="$1"
  local filter="$2"
  local staged="${target}.tmp"

  jq "${filter}" "${target}" > "${staged}"
  mv -- "${staged}" "${target}"
}

file_mode() {
  local target="$1"
  local mode=""

  if mode="$(stat -f '%Lp' "${target}" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' -- "${target}")"
  fi
  printf '%s\n' "${mode#0}"
}

menu_index_for() {
  local basename_wanted="$1"
  local index

  MENU_INDEX=""
  for index in "${!CNTOOLS_MENU_PATHS[@]}"; do
    if [[ "${CNTOOLS_MENU_PATHS[index]##*/}" == "${basename_wanted}" ]]; then
      MENU_INDEX="${index}"
      return 0
    fi
  done
  return 1
}

assert_menu_order() {
  local expected="$1"
  local actual=""
  local entry

  for entry in "${CNTOOLS_MENU_PATHS[@]}"; do
    actual+="${entry##*/},"
  done
  actual="${actual%,}"
  assert_eq "${actual}" "${expected}" "menu ordering"
}

validate_tree() {
  local root="$1"

  CNTOOLS_MODULE_ROOT="${root}"
  CNTOOLS_LIB_DIR="${root%/root}/lib"
  cntools_menu_validate_tree
}

run_metadata_tests() (
  local tree="${TEST_ROOT}/metadata"
  local case_tree=""

  make_root "${tree}"
  cntools_menu_validate_metadata "${tree}/root" root ||
    fail "valid root metadata was rejected"
  validate_tree "${tree}/root" ||
    fail "valid empty root tree was rejected"

  make_menu "${tree}/root/tools" "Tools" t 10
  make_action "${tree}/root/tools/run" "Run" r 10 \
    '["local", "light", "offline"]'
  replace_json "${tree}/root/tools/run/module.json" 'del(.libs)'
  cntools_menu_validate_metadata "${tree}/root/tools" child ||
    fail "valid child menu metadata was rejected"
  cntools_menu_validate_metadata "${tree}/root/tools/run" child ||
    fail "valid action metadata was rejected"
  validate_tree "${tree}/root" ||
    fail "valid nested module tree was rejected"

  case_tree="${TEST_ROOT}/metadata-unknown"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 '["local"]'
  replace_json "${case_tree}/root/action/module.json" '.unknown = true'
  assert_fails "metadata with an unknown field was accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child

  case_tree="${TEST_ROOT}/metadata-control"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Bad\nLabel" a 10 '["local"]'
  replace_json "${case_tree}/root/action/module.json" \
    '.label = "first\nsecond"'
  assert_fails "multiline metadata text was accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child

  case_tree="${TEST_ROOT}/metadata-modes"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 \
    '["local", "local"]'
  assert_fails "duplicate action modes were accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child
  replace_json "${case_tree}/root/action/module.json" '.modes = ["hybrid"]'
  assert_fails "unknown action mode was accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child

  case_tree="${TEST_ROOT}/metadata-order"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 '["local"]'
  replace_json "${case_tree}/root/action/module.json" '.order = -1'
  assert_fails "negative display order was accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child
  replace_json "${case_tree}/root/action/module.json" '.order = 1e999'
  assert_fails "out-of-range display order was accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child

  case_tree="${TEST_ROOT}/metadata-libs"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 '["local"]' \
    '["../secret.sh"]'
  assert_fails "parent-traversing library path was accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child
  replace_json "${case_tree}/root/action/module.json" \
    '.libs = ["test/common.sh", "test/common.sh"]'
  assert_fails "duplicate library paths were accepted" \
    cntools_menu_validate_metadata "${case_tree}/root/action" child

  case_tree="${TEST_ROOT}/metadata-missing-lib"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 '["local"]' \
    '["missing/common.sh"]'
  cntools_menu_validate_metadata "${case_tree}/root/action" child ||
    fail "syntactically valid library metadata was rejected too early"
  assert_fails "full-tree validation ignored a missing declared library" \
    validate_tree "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-duplicate"
  make_root "${case_tree}"
  make_action "${case_tree}/root/first" "First" a 10 '["local"]'
  make_action "${case_tree}/root/second" "Second" a 20 '["local"]'
  CNTOOLS_MODULE_ROOT="${case_tree}/root"
  CNTOOLS_MODE="local"
  CNTOOLS_ADVANCED="N"
  assert_fails "duplicate sibling shortcuts were accepted" \
    cntools_menu_open "${case_tree}/root"

  for reserved in q r; do
    case_tree="${TEST_ROOT}/metadata-reserved-root-${reserved}"
    make_root "${case_tree}"
    make_action "${case_tree}/root/action" "Action" "${reserved}" 10 \
      '["local"]'
    CNTOOLS_MODULE_ROOT="${case_tree}/root"
    assert_fails "reserved root shortcut '${reserved}' was accepted" \
      cntools_menu_open "${case_tree}/root"
  done

  case_tree="${TEST_ROOT}/metadata-reserved-child"
  make_root "${case_tree}"
  make_menu "${case_tree}/root/tools" "Tools" t 10
  make_action "${case_tree}/root/tools/action" "Action" h 10 '["local"]'
  CNTOOLS_MODULE_ROOT="${case_tree}/root"
  assert_fails "reserved nested Home shortcut was accepted" \
    cntools_menu_open "${case_tree}/root/tools"

  case_tree="${TEST_ROOT}/metadata-literal-navigation-shortcuts"
  make_root "${case_tree}"
  make_menu "${case_tree}/root/tools" "Tools" t 10
  make_action "${case_tree}/root/tools/down-action" "J action" j 10 \
    '["local"]'
  make_action "${case_tree}/root/tools/up-action" "K action" k 20 \
    '["local"]'
  CNTOOLS_MODULE_ROOT="${case_tree}/root"
  cntools_menu_open "${case_tree}/root/tools" ||
    fail "literal j/k action shortcuts were rejected"
  assert_menu_order "down-action,up-action"

  case_tree="${TEST_ROOT}/metadata-shape-menu"
  make_root "${case_tree}"
  make_menu "${case_tree}/root/tools" "Tools" t 10
  write_file "${case_tree}/root/tools/action.sh" '#!/usr/bin/env bash
cntools_action_main() { return 0; }'
  assert_fails "menu containing action.sh was accepted" \
    validate_tree "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-shape-action"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 '["local"]'
  mkdir -p "${case_tree}/root/action/child"
  assert_fails "action containing a child module directory was accepted" \
    validate_tree "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-syntax"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 '["local"]'
  write_file "${case_tree}/root/action/action.sh" \
    'cntools_action_main() { this is not valid bash'
  assert_fails "syntax-invalid action was accepted" \
    validate_tree "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-symlink"
  make_root "${case_tree}"
  mkdir -p "${case_tree}/root/action"
  make_action "${case_tree}/real-action" "Action" a 10 '["local"]'
  ln -s "${case_tree}/real-action/module.json" \
    "${case_tree}/root/action/module.json"
  ln -s "${case_tree}/real-action/action.sh" \
    "${case_tree}/root/action/action.sh"
  assert_fails "symlinked module payload was accepted" \
    validate_tree "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-directory-name"
  make_root "${case_tree}"
  make_action "${case_tree}/root/Bad_Name" "Action" a 10 '["local"]'
  CNTOOLS_MODULE_ROOT="${case_tree}/root"
  assert_fails "unsafe module directory name was accepted" \
    cntools_menu_open "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-hidden-directory"
  make_root "${case_tree}"
  make_action "${case_tree}/root/.hidden" "Hidden" a 10 '["local"]'
  CNTOOLS_MODULE_ROOT="${case_tree}/root"
  assert_fails "hidden module directory was silently ignored" \
    cntools_menu_open "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-hidden-action-child"
  make_root "${case_tree}"
  make_action "${case_tree}/root/action" "Action" a 10 '["local"]'
  mkdir -p "${case_tree}/root/action/.hidden"
  assert_fails "hidden child directory in an action was silently ignored" \
    validate_tree "${case_tree}/root"

  case_tree="${TEST_ROOT}/metadata-shallow"
  make_root "${case_tree}"
  make_menu "${case_tree}/root/parent" "Parent" p 10
  mkdir -p "${case_tree}/root/parent/broken"
  jq -n '{
    kind: "action",
    label: "Broken",
    description: "Missing action entrypoint",
    shortcut: "b",
    order: 10,
    modes: ["local"]
  }' > "${case_tree}/root/parent/broken/module.json"
  CNTOOLS_MODULE_ROOT="${case_tree}/root"
  cntools_menu_open "${case_tree}/root" ||
    fail "opening root recursively validated an invalid grandchild"
  assert_fails "opening a menu ignored its invalid immediate child" \
    cntools_menu_open "${case_tree}/root/parent"
  assert_fails "full-tree validation ignored an invalid grandchild" \
    validate_tree "${case_tree}/root"
)

run_order_and_visibility_tests() (
  local tree="${TEST_ROOT}/ordering"

  make_root "${tree}"
  make_menu "${tree}/root/advanced-tools" "Advanced" a 5 Y
  make_menu "${tree}/root/tools" "Tools" t 10
  make_action "${tree}/root/alpha" "Alpha" x 20 '["local"]'
  make_action "${tree}/root/same-z" "Same Z" z 30 \
    '["local", "light", "offline"]'
  make_action "${tree}/root/same-a" "Same A" s 30 \
    '["local", "light", "offline"]'

  CNTOOLS_MODULE_ROOT="${tree}/root"
  CNTOOLS_LIB_DIR="${tree}/lib"
  CNTOOLS_MODE="light"
  CNTOOLS_ADVANCED="N"
  cntools_menu_open "${tree}/root" ||
    fail "valid ordered root menu could not be opened"
  assert_menu_order "tools,alpha,same-a,same-z"
  menu_index_for alpha || fail "mode-restricted action is not visible"
  assert_eq "${CNTOOLS_MENU_ENABLED[MENU_INDEX]}" "N" \
    "unsupported-mode action state"
  [[ -n "${CNTOOLS_MENU_DISABLED_REASONS[MENU_INDEX]}" ]] ||
    fail "unsupported-mode action has no visible reason"
  menu_index_for tools || fail "menu entry is missing"
  assert_eq "${CNTOOLS_MENU_ENABLED[MENU_INDEX]}" "Y" "menu enabled state"

  CNTOOLS_ADVANCED="Y"
  cntools_menu_open "${tree}/root" ||
    fail "advanced root menu could not be opened"
  assert_menu_order "advanced-tools,tools,alpha,same-a,same-z"

  CNTOOLS_MODE="local"
  CNTOOLS_ADVANCED="N"
  cntools_menu_open "${tree}/root" ||
    fail "local root menu could not be opened"
  menu_index_for alpha || fail "local action is missing"
  assert_eq "${CNTOOLS_MENU_ENABLED[MENU_INDEX]}" "Y" \
    "supported-mode action state"
)

run_action_tests() (
  local tree="${TEST_ROOT}/actions"
  local action_dir=""
  local trace="${TEST_ROOT}/action.trace"
  local status=0
  local prior_lines=0

  make_root "${tree}"
  make_menu "${tree}/root/tools" "Tools" t 10
  mkdir -p "${tree}/lib/test"
  write_file "${tree}/lib/test/declared.sh" '#!/usr/bin/env bash
cntools_fixture_declared() {
  printf "%s" "declared-library"
}'
  write_file "${tree}/lib/test/unlisted.sh" '#!/usr/bin/env bash
cntools_fixture_unlisted() {
  return 0
}'

  action_dir="${tree}/root/tools/run"
  make_action "${action_dir}" "Run" r 10 \
    '["local", "light", "offline"]' '["test/declared.sh"]'
  write_file "${action_dir}/action.sh" '#!/usr/bin/env bash
cntools_action_main() {
  [[ "$(cntools_fixture_declared)" == "declared-library" ]] || return 81
  ! declare -F cntools_fixture_unlisted >/dev/null 2>&1 || return 82
  [[ "${CNTOOLS_UI_USE_ALT_SCREEN:-}" == "N" ]] || return 83
  [[ "$(trap -p TSTP)" == *cntools_ui_suspend_for_job_control* ]] || return 84
  [[ "$(trap -p CONT)" == *cntools_ui_mark_resize* ]] || return 85
  printf "%s\n" "${CNTOOLS_ACTION_ID}" >> "${CNTOOLS_TEST_TRACE}"
  return "${CNTOOLS_TEST_ACTION_STATUS:-0}"
}'

  CNTOOLS_MODULE_ROOT="${tree}/root"
  CNTOOLS_LIB_DIR="${tree}/lib"
  CNTOOLS_MODE="local"
  CNTOOLS_ADVANCED="N"
  CNTOOLS_TEST_TRACE="${trace}"
  CNTOOLS_TEST_ACTION_STATUS=0
  CNTOOLS_LOG="${TEST_ROOT}/action-log/cntools.log"
  CNTOOLS_LOG_DIR="${TEST_ROOT}/action-log"
  cntools_log_init || fail "logger initialization failed for action tests"

  ! declare -F cntools_fixture_declared >/dev/null 2>&1 ||
    fail "declared action library was loaded before action selection"
  ! declare -F cntools_fixture_unlisted >/dev/null 2>&1 ||
    fail "unlisted action library was loaded before action selection"

  cntools_action_main() { return 99; }
  cntools_action_run "${action_dir}" || fail "valid action invocation failed"
  assert_eq "$(< "${trace}")" "tools/run" "action routing identity"
  grep -F '[ACTION] [tools/run] selected' "${CNTOOLS_LOG}" >/dev/null ||
    fail "action selection was not logged with the action identity"
  declare -F cntools_action_main >/dev/null 2>&1 ||
    fail "action loader removed the caller's inherited main function"
  if cntools_action_main; then
    fail "action loader replaced the caller's inherited main function"
  else
    status=$?
  fi
  assert_eq "${status}" "99" "inherited main function isolation"
  unset -f cntools_action_main
  ! declare -F cntools_fixture_declared >/dev/null 2>&1 ||
    fail "declared action library leaked out of its subshell"
  ! declare -F cntools_fixture_unlisted >/dev/null 2>&1 ||
    fail "unlisted action library was loaded"

  CNTOOLS_TEST_ACTION_STATUS=17
  if cntools_action_run "${action_dir}" >/dev/null 2>&1; then
    fail "non-zero action status was discarded"
  else
    status=$?
  fi
  assert_eq "${status}" "17" "action status propagation"

  action_dir="${tree}/root/tools/exit"
  make_action "${action_dir}" "Exit" e 20 '["local"]'
  write_file "${action_dir}/action.sh" '#!/usr/bin/env bash
cntools_action_main() {
  exit 23
}'
  if cntools_action_run "${action_dir}" >/dev/null 2>&1; then
    fail "action exit status was discarded"
  else
    status=$?
  fi
  assert_eq "${status}" "23" "isolated action exit status"
  cntools_log ACTION "outer shell survived action exit"

  action_dir="${tree}/root/tools/local-only"
  make_action "${action_dir}" "Local Only" l 30 '["local"]'
  CNTOOLS_MODE="light"
  assert_fails "direct action loading bypassed mode validation" \
    cntools_action_run "${action_dir}"
  CNTOOLS_MODE="local"

  write_file "${tree}/lib/test/reserved.sh" '#!/usr/bin/env bash
cntools_action_main() {
  return 0
}'
  action_dir="${tree}/root/tools/reserved"
  make_action "${action_dir}" "Reserved" v 40 '["local"]' \
    '["test/reserved.sh"]'
  prior_lines="$(wc -l < "${trace}" | tr -d ' ')"
  assert_fails "library-defined reserved action main was accepted" \
    cntools_action_run "${action_dir}"
  assert_eq "$(wc -l < "${trace}" | tr -d ' ')" "${prior_lines}" \
    "rejected library executed an action"

  write_file "${tree}/lib/test/real.sh" '#!/usr/bin/env bash
cntools_fixture_symlinked() { return 0; }'
  ln -s "${tree}/lib/test/real.sh" "${tree}/lib/test/link.sh"
  action_dir="${tree}/root/tools/symlink"
  make_action "${action_dir}" "Symlink" y 50 '["local"]' \
    '["test/link.sh"]'
  assert_fails "symlinked action library was loaded" \
    cntools_action_run "${action_dir}"

  action_dir="${tree}/root/tools/run"
  jq() {
    if [[ "${1:-}" == "-r" && "${2:-}" == ".libs[]?" ]]; then
      return 88
    fi
    command jq "$@"
  }
  assert_fails "action ignored a declared-library parser failure" \
    cntools_action_run "${action_dir}"
  grep -F 'Could not read declared action libraries' "${CNTOOLS_LOG}" >/dev/null ||
    fail "declared-library parser failure was not logged"
  assert_fails "tree validation ignored a declared-library parser failure" \
    validate_tree "${tree}/root"

  cntools_log_close || fail "logger close failed after action tests"
)

run_log_and_wrapper_tests() (
  local log_dir="${TEST_ROOT}/logging"
  local log_file="${log_dir}/cntools.log"
  local secret='CNTOOLS_TEST_SECRET_4b925'
  local stdout_marker='CNTOOLS_COMMAND_STDOUT_ONLY_62fa1'
  local output=""
  local status=0
  local lines_before=0
  local lines_after=0
  local command_stub="${TEST_ROOT}/command-output.sh"
  local failure_stub="${TEST_ROOT}/command-failure.sh"
  local invocation_trace="${TEST_ROOT}/invalid-mask.trace"

  CNTOOLS_LOG_DIR="${log_dir}"
  CNTOOLS_LOG="${log_file}"
  CNTOOLS_ACTION_ID="framework/test"
  cntools_log_init || fail "valid private logger target was rejected"
  assert_eq "$(file_mode "${log_dir}")" "700" "log directory mode"
  assert_eq "$(file_mode "${log_file}")" "600" "log file mode"

  lines_before="$(wc -l < "${log_file}" | tr -d ' ')"
  cntools_log ACTION $'first line\nsecond line'
  lines_after="$(wc -l < "${log_file}" | tr -d ' ')"
  assert_eq "${lines_after}" "$((lines_before + 1))" \
    "multiline log sanitization"
  grep -F 'first line' "${log_file}" >/dev/null ||
    fail "sanitized log record is missing"

  write_file "${command_stub}" "#!/usr/bin/env bash
printf '%s\\n' '${stdout_marker}'"
  chmod 0700 "${command_stub}"
  output="$(cntools_run_command "0" -- "${command_stub}")" ||
    fail "successful command wrapper invocation failed"
  assert_eq "${output}" "${stdout_marker}" "command stdout preservation"
  if grep -F "${stdout_marker}" "${log_file}" >/dev/null; then
    fail "command stdout was written to the log"
  fi

  output="$(cntools_run_command "001" -- \
    printf '%s\n' "${secret}")" ||
    fail "redacted command wrapper invocation failed"
  assert_eq "${output}" "${secret}" "redacted command execution arguments"
  if grep -F "${secret}" "${log_file}" >/dev/null; then
    fail "redacted command argument was written to the log"
  fi
  grep -F '<redacted>' "${log_file}" >/dev/null ||
    fail "redacted command argument was not identified in the log"

  write_file "${failure_stub}" '#!/usr/bin/env bash
exit 23'
  chmod 0700 "${failure_stub}"
  if cntools_run_command "0" -- "${failure_stub}" >/dev/null 2>&1; then
    fail "command wrapper discarded a failure"
  else
    status=$?
  fi
  assert_eq "${status}" "23" "command failure status"
  grep -E -- '-> 23$' "${log_file}" >/dev/null ||
    fail "command failure status was not logged"

  write_file "${TEST_ROOT}/must-not-run.sh" "#!/usr/bin/env bash
printf invoked > '${invocation_trace}'"
  chmod 0700 "${TEST_ROOT}/must-not-run.sh"
  assert_fails "invalid redaction-mask length was accepted" \
    cntools_run_command "00" -- "${TEST_ROOT}/must-not-run.sh"
  [[ ! -e "${invocation_trace}" ]] ||
    fail "invalid redaction mask invoked the command"

  cntools_log_close || fail "logger close failed"

  mkdir -p "${TEST_ROOT}/unsafe-log"
  : > "${TEST_ROOT}/unsafe-log/real.log"
  ln -s "${TEST_ROOT}/unsafe-log/real.log" \
    "${TEST_ROOT}/unsafe-log/link.log"
  CNTOOLS_LOG="${TEST_ROOT}/unsafe-log/link.log"
  assert_fails "symlink log target was accepted" cntools_log_init
  CNTOOLS_LOG="${TEST_ROOT}/unsafe-log/directory"
  mkdir -p "${CNTOOLS_LOG}"
  assert_fails "directory log target was accepted" cntools_log_init
)

run_http_tests() (
  local bin_dir="${TEST_ROOT}/http-bin"
  local curl_trace="${TEST_ROOT}/curl.trace"
  local response="${TEST_ROOT}/http.response"
  local log_file="${TEST_ROOT}/http-log/cntools.log"
  local secret='CNTOOLS_HTTP_SECRET_b2719'
  local original_path="${PATH}"
  local status=0

  mkdir -p "${bin_dir}"
  write_file "${bin_dir}/curl" '#!/usr/bin/env bash
output=""
format=""
printf "%s\n" "$@" > "${CNTOOLS_TEST_CURL_TRACE}"
while (( $# > 0 )); do
  case "$1" in
    --output|-o)
      output="${2:-}"
      shift 2
      ;;
    --output=*)
      output="${1#*=}"
      shift
      ;;
    --write-out|-w)
      format="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -z "${output}" ]] || printf "%s\n" "fixture response" > "${output}"
case "${format}" in
  *time_total*) printf "204\\t0.125" ;;
  *http_code*) printf "204" ;;
esac
exit 0'
  chmod 0700 "${bin_dir}/curl"

  PATH="${bin_dir}:${original_path}"
  export PATH
  CNTOOLS_TEST_CURL_TRACE="${curl_trace}"
  export CNTOOLS_TEST_CURL_TRACE
  CNTOOLS_LOG_DIR="${TEST_ROOT}/http-log"
  CNTOOLS_LOG="${log_file}"
  CNTOOLS_ACTION_ID="wallet/list"
  CNTOOLS_MODE="light"
  cntools_log_init || fail "logger initialization failed for HTTP tests"

  cntools_http_request POST \
    "https://user:${secret}@example.test/address_info?token=${secret}" \
    "${response}" \
    --header "Authorization: Bearer ${secret}" \
    --data "{\"token\":\"${secret}\"}" ||
    fail "HTTP wrapper rejected a successful request"
  [[ -s "${response}" ]] || fail "HTTP wrapper did not preserve its response"
  [[ -s "${curl_trace}" ]] || fail "HTTP wrapper did not invoke curl"
  grep -F 'POST' "${log_file}" >/dev/null ||
    fail "HTTP method was not logged"
  grep -F '/address_info' "${log_file}" >/dev/null ||
    fail "sanitized HTTP endpoint was not logged"
  grep -F '204' "${log_file}" >/dev/null ||
    fail "HTTP response status was not logged"
  if grep -F "${secret}" "${log_file}" >/dev/null ||
     grep -F 'Authorization:' "${log_file}" >/dev/null ||
     grep -F 'token=' "${log_file}" >/dev/null; then
    fail "HTTP credentials, query, headers, or body were logged"
  fi

  : > "${curl_trace}"
  rm -f -- "${response}"
  CNTOOLS_MODE="offline"
  if cntools_http_request GET \
    'https://example.test/network/status' "${response}" >/dev/null 2>&1; then
    fail "offline mode allowed an HTTP request"
  else
    status=$?
  fi
  [[ "${status}" -ne 0 ]] || fail "offline HTTP rejection returned success"
  [[ ! -s "${curl_trace}" ]] || fail "offline HTTP rejection invoked curl"
  [[ ! -e "${response}" ]] ||
    fail "offline HTTP rejection created a response file"

  cntools_log_close || fail "logger close failed after HTTP tests"
)

run_ui_tests() (
  local key=""
  local ignored_key=""
  local terminal_trace="${TEST_ROOT}/terminal.trace"
  local expected=""
  local output=""

  stty() {
    printf 'stty:%s\n' "$*" >> "${terminal_trace}"
  }
  tput() {
    printf 'tput:%s\n' "$*" >> "${terminal_trace}"
    case "${1:-}" in
      cols) printf '100' ;;
      lines) printf '30' ;;
    esac
  }

  CNTOOLS_UI_INTERACTIVE="N"
  cntools_ui_read_key key </dev/null || fail "UI rejected closed input"
  assert_eq "${key}" "quit" "closed-input key mapping"
  cntools_ui_read_key key <<< 'j' || fail "UI did not read the j shortcut"
  assert_eq "${key}" "j" "literal j shortcut mapping"
  cntools_ui_read_key key <<< 'k' || fail "UI did not read the k shortcut"
  assert_eq "${key}" "k" "literal k shortcut mapping"
  cntools_ui_read_key key <<< '' || fail "UI did not read Enter"
  assert_eq "${key}" "enter" "Enter key mapping"

  # Exercise terminal escape decoding without requiring the test runner itself
  # to allocate a pseudo-terminal.
  : > "${terminal_trace}"
  CNTOOLS_UI_INTERACTIVE="Y"
  CNTOOLS_UI_INPUT_ACTIVE="N"
  CNTOOLS_UI_RESIZE_PENDING="N"
  CNTOOLS_UI_STTY=""
  if cntools_ui_input_resume; then
    fail "UI enabled raw input without a saved terminal state"
  fi
  [[ ! -s "${terminal_trace}" ]] ||
    fail "UI changed terminal input without a saved state"
  CNTOOLS_UI_STTY="saved-terminal-state"
  cntools_ui_read_key key <<< $'\e[A' || fail "UI did not read Up arrow"
  assert_eq "${key}" "up" "Up arrow mapping"
  cntools_ui_read_key key <<< $'\e[B' || fail "UI did not read Down arrow"
  assert_eq "${key}" "down" "Down arrow mapping"
  cntools_ui_read_key key <<< $'\eOA' ||
    fail "UI did not read application-mode Up arrow"
  assert_eq "${key}" "up" "application-mode Up arrow mapping"
  cntools_ui_read_key key <<< $'\eOB' ||
    fail "UI did not read application-mode Down arrow"
  assert_eq "${key}" "down" "application-mode Down arrow mapping"
  cntools_ui_read_key key <<< $'\e' || fail "UI did not read Escape"
  assert_eq "${key}" "escape" "Escape key mapping"

  # Escape sequences can arrive back-to-back. A complete but unsupported
  # sequence must be consumed as one key so its parameter bytes do not become
  # later shortcuts. Parameterized arrows are emitted by terminals when a
  # modifier is held and should retain their navigation meaning.
  exec 3<<< $'\e[1;2A\e[1;2B\e[99~q'
  cntools_ui_read_key key <&3 || fail "UI did not read parameterized Up arrow"
  assert_eq "${key}" "up" "parameterized Up arrow mapping"
  cntools_ui_read_key key <&3 || fail "UI did not read parameterized Down arrow"
  assert_eq "${key}" "down" "parameterized Down arrow mapping"
  cntools_ui_read_key ignored_key <&3 ||
    fail "UI did not consume an unsupported escape sequence"
  cntools_ui_read_key key <&3 ||
    fail "UI leaked bytes after an unsupported escape sequence"
  assert_eq "${key}" "q" "escape sequence fragment draining"
  exec 3<&-
  assert_eq "$(< "${terminal_trace}")" \
    'stty:-echo -icanon min 1 time 0' \
    "raw input entered once and retained across key reads"

  CNTOOLS_UI_INTERACTIVE="N"
  cntools_ui_read_key key <<< 'q' || fail "UI did not preserve a shortcut"
  assert_eq "${key}" "q" "shortcut key mapping"

  # Cleanup must remain safe and idempotent in the plain-text fallback. The
  # entrypoint owns signal traps; these helpers own only terminal restoration.
  cntools_ui_restore_terminal || fail "plain terminal restoration failed"
  cntools_ui_restore_terminal || fail "terminal restoration was not idempotent"
  cntools_ui_cleanup || fail "plain terminal cleanup failed"
  cntools_ui_cleanup || fail "terminal cleanup was not idempotent"

  : > "${terminal_trace}"
  CNTOOLS_UI_CAPABLE="Y"
  CNTOOLS_UI_RESIZE_PENDING="Y"
  cntools_ui_dimensions || fail "initial terminal sizing failed"
  cntools_ui_dimensions || fail "cached terminal sizing failed"
  assert_eq "${CNTOOLS_UI_COLUMNS}" "100" "cached terminal columns"
  assert_eq "${CNTOOLS_UI_LINES}" "30" "cached terminal lines"
  assert_eq "${CNTOOLS_UI_DRAW_WIDTH}" "99" "safe terminal draw width"
  expected=$'tput:cols\ntput:lines'
  assert_eq "$(< "${terminal_trace}")" "${expected}" \
    "terminal dimension cache"
  cntools_ui_mark_resize
  cntools_ui_dimensions || fail "resized terminal sizing failed"
  expected+=$'\ntput:cols\ntput:lines'
  assert_eq "$(< "${terminal_trace}")" "${expected}" \
    "terminal resize invalidation"

  # The menu owns the alternate screen while actions use normal scrollback.
  # Entering and restoring a menu session must pair every terminal capability
  # and restore the original input mode in a predictable order.
  : > "${terminal_trace}"
  CNTOOLS_UI_CLEANED="N"
  CNTOOLS_UI_INTERACTIVE="Y"
  CNTOOLS_UI_CAPABLE="Y"
  CNTOOLS_UI_STTY="saved-terminal-state"
  CNTOOLS_UI_INPUT_ACTIVE="N"
  CNTOOLS_UI_SCREEN_ACTIVE="N"
  CNTOOLS_UI_USE_ALT_SCREEN="Y"
  CNTOOLS_UI_SCREEN_ENTER='<screen-enter>'
  CNTOOLS_UI_SCREEN_LEAVE='<screen-leave>'
  CNTOOLS_UI_CURSOR_HIDE='<cursor-hide>'
  CNTOOLS_UI_CURSOR_SHOW='<cursor-show>'
  CNTOOLS_UI_RESET='<reset>'
  output="$(cntools_ui_session_enter && cntools_ui_restore_terminal)" ||
    fail "capable terminal session lifecycle failed"
  assert_eq "${output}" \
    '<screen-enter><cursor-hide><reset><cursor-show><screen-leave>' \
    "alternate screen and cursor lifecycle"
  expected=$'stty:-echo -icanon min 1 time 0\nstty:saved-terminal-state'
  assert_eq "$(< "${terminal_trace}")" "${expected}" \
    "raw input session lifecycle"

  # A job-control suspension restores the terminal before stopping and marks
  # the UI for a complete redraw when execution continues.
  kill() {
    printf 'kill:%s\n' "$*" >> "${terminal_trace}"
  }
  : > "${terminal_trace}"
  CNTOOLS_UI_INTERACTIVE="Y"
  CNTOOLS_UI_CAPABLE="Y"
  CNTOOLS_UI_STTY="saved-terminal-state"
  CNTOOLS_UI_INPUT_ACTIVE="Y"
  CNTOOLS_UI_SCREEN_ACTIVE="Y"
  CNTOOLS_UI_SCREEN_LEAVE='<screen-leave>'
  CNTOOLS_UI_CURSOR_SHOW='<cursor-show>'
  CNTOOLS_UI_RESET='<reset>'
  CNTOOLS_UI_RESIZE_PENDING="N"
  output="$(cntools_ui_suspend_for_job_control)" ||
    fail "job-control suspension handler failed"
  assert_eq "${output}" '<reset><cursor-show><screen-leave>' \
    "job-control terminal restoration"
  expected="$(< "${terminal_trace}")"
  [[ "${expected}" == $'stty:saved-terminal-state\nkill:-s TSTP '* ]] ||
    fail "job-control suspension did not restore input before stopping"

  : > "${terminal_trace}"
  CNTOOLS_UI_CLEANED="N"
  CNTOOLS_UI_INTERACTIVE="Y"
  CNTOOLS_UI_CAPABLE="Y"
  CNTOOLS_UI_STTY="saved-terminal-state"
  CNTOOLS_UI_INPUT_ACTIVE="N"
  CNTOOLS_UI_SCREEN_ACTIVE="N"
  CNTOOLS_UI_CURSOR_SHOW=""
  CNTOOLS_UI_RESET=""
  cntools_ui_cleanup || fail "interactive terminal cleanup failed"
  cntools_ui_cleanup || fail "interactive cleanup was not idempotent"
  expected=$'stty:saved-terminal-state\ntput:sgr0\ntput:cnorm'
  assert_eq "$(< "${terminal_trace}")" "${expected}" \
    "interactive terminal restoration"
)

run_navigation_tests() (
  local tree="${TEST_ROOT}/navigation"
  local trace="${TEST_ROOT}/navigation.trace"
  local expected=""

  make_root "${tree}"
  make_action "${tree}/root/home-action" "Home action" h 10 \
    '["local", "light", "offline"]'
  make_menu "${tree}/root/tools" "Tools" t 20
  make_action "${tree}/root/tools/quit-action" "Nested Q action" q 10 \
    '["local", "light", "offline"]'
  make_action "${tree}/root/tools/refresh-action" "Nested R action" r 20 \
    '["local", "light", "offline"]'

  write_file "${tree}/root/home-action/action.sh" '#!/usr/bin/env bash
cntools_action_main() {
  printf '\''%s\n'\'' "${CNTOOLS_ACTION_ID}" >> "${CNTOOLS_TEST_TRACE}"
}'
  cp -- "${tree}/root/home-action/action.sh" \
    "${tree}/root/tools/quit-action/action.sh"
  cp -- "${tree}/root/home-action/action.sh" \
    "${tree}/root/tools/refresh-action/action.sh"

  CNTOOLS_MODULE_ROOT="${tree}/root"
  CNTOOLS_LIB_DIR="${tree}/lib"
  CNTOOLS_VALIDATION_BASH="bash"
  CNTOOLS_TEST_TRACE="${trace}"
  CNTOOLS_MODE="local"
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="mainnet"
  CNTOOLS_ADVANCED="N"
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="N"

  cntools_log() {
    return 0
  }

  # Cover selected-row navigation, submenu entry, q/r as valid nested action
  # shortcuts, Home, Back, root-level h action selection, refresh, and quit.
  cntools_menu_run <<< $'down\nenter\nr\nq\nh\nh\nup\nenter\nescape\nr\nq' \
    >/dev/null || fail "menu navigation sequence failed"
  expected=$'tools/refresh-action\ntools/quit-action\nhome-action'
  [[ -f "${trace}" ]] || fail "menu navigation did not invoke actions"
  assert_eq "$(< "${trace}")" "${expected}" \
    "menu navigation action sequence"

  # A non-interactive caller closing stdin must end the menu normally instead
  # of continuously redrawing it.
  cntools_menu_run </dev/null >/dev/null ||
    fail "menu did not exit cleanly when input closed"
)

run_navigation_cache_tests() (
  local tree="${TEST_ROOT}/navigation-cache"
  local load_trace="${TEST_ROOT}/navigation-cache.loads"
  local action_trace="${TEST_ROOT}/navigation-cache.actions"
  local navigation_output="${TEST_ROOT}/navigation-cache-navigation.out"
  local refresh_output="${TEST_ROOT}/navigation-cache-refresh.out"
  local failed_refresh_output="${TEST_ROOT}/navigation-cache-failed-refresh.out"
  local mutation_target="${tree}/root/tools/run/module.json"
  local original_definition=""
  local expected_loads=""
  local load_count=""
  local output=""

  make_root "${tree}"
  make_action "${tree}/root/alpha" "Alpha" a 10 \
    '["local", "light", "offline"]'
  make_menu "${tree}/root/tools" "Tools" t 20
  make_action "${tree}/root/tools/run" "Run Original" r 10 \
    '["local", "light", "offline"]'
  write_file "${tree}/root/tools/run/action.sh" '#!/usr/bin/env bash
cntools_action_main() {
  local staged="${CNTOOLS_TEST_MUTATION_TARGET}.tmp"

  printf '\''run\n'\'' >> "${CNTOOLS_TEST_ACTION_TRACE}" || return 1
  jq '\''.label = "Run Updated" |
    .description = "Run Updated test action"'\'' \
    "${CNTOOLS_TEST_MUTATION_TARGET}" > "${staged}" || return 1
  mv -- "${staged}" "${CNTOOLS_TEST_MUTATION_TARGET}"
}'

  CNTOOLS_MODULE_ROOT="${tree}/root"
  CNTOOLS_LIB_DIR="${tree}/lib"
  CNTOOLS_VALIDATION_BASH="bash"
  CNTOOLS_MODE="local"
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="mainnet"
  CNTOOLS_ADVANCED="N"
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="N"
  CNTOOLS_TEST_MUTATION_TARGET="${mutation_target}"
  CNTOOLS_TEST_ACTION_TRACE="${action_trace}"

  cntools_log() {
    return 0
  }

  # Trace the real loader without replacing its validation behavior. Selection
  # changes should render the catalog already in memory; only the initial
  # catalog build and an explicit root Refresh should load metadata.
  original_definition="$(declare -f cntools_menu_open)"
  original_definition="${original_definition/cntools_menu_open ()/cntools_test_menu_open_original ()}"
  [[ "${original_definition}" == cntools_test_menu_open_original* ]] ||
    fail "could not preserve the menu loader for cache testing"
  eval "${original_definition}"
  cntools_menu_open() {
    printf '%s\n' "$1" >> "${load_trace}"
    cntools_test_menu_open_original "$@"
  }

  # The first catalog build walks the visible tree once. Actions are validated
  # as children but only menu directories are opened recursively.
  cntools_menu_cache_build || fail "initial menu catalog build failed"
  expected_loads="${tree}/root"$'\n'"${tree}/root/tools"
  assert_eq "$(< "${load_trace}")" "${expected_loads}" \
    "initial recursive menu catalog loads"

  # Once the catalog exists, arrows, nested navigation, and returning from an
  # action must not touch menu metadata. The nested action edits its metadata
  # on disk; the already-rendered catalog must continue to show the old label.
  : > "${load_trace}"
  cntools_menu_run <<< $'down\nup\nt\ndown\nup\nr\ndown\nup\nescape\ndown\nup\nq' \
    > "${navigation_output}" || fail "cached navigation sequence failed"
  load_count="$(wc -l < "${load_trace}")"
  load_count="${load_count//[[:space:]]/}"
  assert_eq "${load_count}" "0" \
    "menu loads during arrows, nested navigation, and action return"
  assert_eq "$(< "${action_trace}")" "run" \
    "cached navigation action invocation"
  assert_eq "$(jq -r '.label' "${mutation_target}")" "Run Updated" \
    "action metadata edit on disk"
  output="$(< "${navigation_output}")"
  [[ "${output}" == *"Run Original"* ]] ||
    fail "cached navigation did not render the original action label"
  [[ "${output}" != *"Run Updated"* ]] ||
    fail "disk metadata edit leaked into the menu before Refresh"
  cntools_menu_cache_open "${tree}/root/tools" ||
    fail "could not reopen nested menu from the session catalog"
  menu_index_for run || fail "cached nested action is missing"
  assert_eq "${CNTOOLS_MENU_LABELS[MENU_INDEX]}" "Run Original" \
    "cached nested action label before Refresh"

  # A later menu session must reuse the same catalog. Only root r rebuilds it;
  # the disk edit is invisible before the success status and visible after it.
  : > "${load_trace}"
  cntools_menu_run <<< $'t\nescape\nr\nt\nescape\nq' \
    > "${refresh_output}" || fail "explicit menu refresh sequence failed"
  assert_eq "$(< "${load_trace}")" "${expected_loads}" \
    "explicit Refresh recursive menu catalog loads"
  output="$(< "${refresh_output}")"
  [[ "${output}" == *"Menu definitions reloaded"* ]] ||
    fail "successful Refresh status was not rendered"
  [[ "${output%%Menu definitions reloaded*}" == *"Run Original"* ]] ||
    fail "disk edit became visible before Refresh completed"
  [[ "${output%%Menu definitions reloaded*}" != *"Run Updated"* ]] ||
    fail "updated label was rendered before Refresh completed"
  [[ "${output#*Menu definitions reloaded}" == *"Run Updated"* ]] ||
    fail "updated label was not rendered after Refresh"

  # Reload is transactional. Invalid disk metadata must fail validation while
  # leaving the last valid catalog available for continued navigation.
  replace_json "${mutation_target}" '.unknown = true'
  : > "${load_trace}"
  cntools_menu_run <<< $'r\nt\nescape\nq' > "${failed_refresh_output}" ||
    fail "menu did not recover from a failed Refresh"
  assert_eq "$(< "${load_trace}")" "${expected_loads}" \
    "failed Refresh recursive menu catalog loads"
  output="$(< "${failed_refresh_output}")"
  [[ "${output}" == *"Reload failed; previous menus retained:"* ]] ||
    fail "failed Refresh status was not rendered"
  [[ "${output#*Reload failed; previous menus retained:}" == *"Run Updated"* ]] ||
    fail "failed Refresh did not retain the prior nested menu catalog"
  cntools_menu_cache_open "${tree}/root/tools" ||
    fail "failed Refresh discarded the prior nested menu catalog"
  menu_index_for run || fail "prior nested action is missing after failed Refresh"
  assert_eq "${CNTOOLS_MENU_LABELS[MENU_INDEX]}" "Run Updated" \
    "cached nested action label after failed Refresh"

  # Navigation is catalog-backed as well as metadata-backed. Removing the
  # directory after a failed reload must not destroy the last valid menu view;
  # action execution still performs its own filesystem checks.
  mv -- "${tree}/root/tools" "${tree}/root/tools.removed"
  cntools_menu_cache_open "${tree}/root/tools" ||
    fail "cached menu required its source directory after startup"
  menu_index_for run || fail "cached action disappeared with its source directory"
  assert_eq "${CNTOOLS_MENU_LABELS[MENU_INDEX]}" "Run Updated" \
    "cached menu after source directory removal"
  cntools_menu_run <<< $'t\nescape\nq' >/dev/null ||
    fail "runtime navigation required removed menu metadata after startup"

  while IFS= read -r loaded_menu; do
    [[ "${loaded_menu}" == "${tree}/root" ||
       "${loaded_menu}" == "${tree}/root/tools" ]] ||
      fail "Refresh loaded an unexpected menu: ${loaded_menu}"
  done < "${load_trace}"
)

run_cache_root_key_tests() (
  local tree="${TEST_ROOT}/cache-root-key"
  local output=""

  make_root "${tree}"
  make_menu "${tree}/root/root" "Nested Root" n 10
  make_action "${tree}/root/root/run" "Run" r 10 \
    '["local", "light", "offline"]'

  CNTOOLS_MODULE_ROOT="${tree}/root"
  CNTOOLS_LIB_DIR="${tree}/lib"
  CNTOOLS_VALIDATION_BASH="bash"
  CNTOOLS_MODE="local"
  CNTOOLS_ADVANCED="N"

  cntools_menu_cache_build ||
    fail "catalog rejected a valid top-level module named root"
  cntools_menu_cache_open "${tree}/root" ||
    fail "catalog lost the real root when a child is named root"
  assert_eq "${CNTOOLS_MENU_LABEL}" "CNTools" \
    "real root label with root-named child"
  assert_eq "${CNTOOLS_MENU_IDS[*]}" "root" \
    "real root contents with root-named child"

  cntools_menu_cache_open "${tree}/root/root" ||
    fail "catalog lost a top-level menu named root"
  assert_eq "${CNTOOLS_MENU_LABEL}" "Nested Root" \
    "root-named child label"
  assert_eq "${CNTOOLS_MENU_IDS[*]}" "root/run" \
    "root-named child contents"
  assert_eq "${CNTOOLS_MENU_BREADCRUMB}" "/ Nested Root" \
    "root-named child breadcrumb"

  # Root-only behavior follows navigation depth, not the public module ID.
  # A child named root must never acquire the real root's update banner.
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="mainnet"
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="N"
  CNTOOLS_UI_RESIZE_PENDING="Y"
  CNTOOLS_UPDATE_STATUS="available"
  CNTOOLS_UPDATE_REMOTE_VERSION="14.1.0"
  cntools_log() { return 0; }
  cntools_update_state_load() { return 0; }
  output="$(cntools_menu_run <<< 'n')" ||
    fail "navigation into a root-named child failed"
  assert_eq "$(grep -c 'Update available:' <<< "${output}")" "1" \
    "root-only update banner with root-named child"
  [[ "${output#*/ Nested Root}" != *"Update available:"* ]] ||
    fail "root-named child rendered the real root update banner"
)

run_selective_repaint_tests() (
  local tree="${TEST_ROOT}/selective-repaint"
  local full_renders=0
  local row_repaints=0
  local detail_repaints=0

  make_root "${tree}"
  make_action "${tree}/root/alpha" "Alpha" a 10 \
    '["local", "light", "offline"]'
  make_action "${tree}/root/bravo" "Bravo" b 20 \
    '["local", "light", "offline"]'

  CNTOOLS_MODULE_ROOT="${tree}/root"
  CNTOOLS_LIB_DIR="${tree}/lib"
  CNTOOLS_VALIDATION_BASH="bash"
  CNTOOLS_MODE="local"
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="mainnet"
  CNTOOLS_ADVANCED="N"
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="Y"
  CNTOOLS_UI_REPAINT_CAPABLE="Y"
  CNTOOLS_UI_TOO_SMALL="N"
  CNTOOLS_UPDATE_STATUS="current"

  cntools_log() { return 0; }
  cntools_update_state_load() { return 0; }
  cntools_update_render_banner() { return 0; }
  cntools_ui_render_begin() {
    full_renders=$((full_renders + 1))
    CNTOOLS_UI_CONTENT_ROW=4
    CNTOOLS_UI_TOO_SMALL="N"
  }
  cntools_ui_render_row() { return 0; }
  cntools_ui_render_detail() { return 0; }
  cntools_ui_render_status() { return 0; }
  cntools_ui_render_footer() { return 0; }
  cntools_ui_repaint_row() {
    row_repaints=$((row_repaints + 1))
  }
  cntools_ui_repaint_detail() {
    detail_repaints=$((detail_repaints + 1))
  }

  cntools_menu_cache_build || fail "selective repaint catalog build failed"
  cntools_menu_run <<< $'down\nup\nq' ||
    fail "selective repaint navigation failed"
  assert_eq "${full_renders}" "1" \
    "full renders during ordinary selection movement"
  assert_eq "${row_repaints}" "4" \
    "old and new row repaints during selection movement"
  assert_eq "${detail_repaints}" "2" \
    "detail repaints during selection movement"
  assert_eq "${CNTOOLS_MENU_ID}" "/" \
    "public root menu identity"

  # If the footer would fall outside the terminal, cursor-addressed row
  # updates are unsafe because the initial render may have scrolled.
  full_renders=0
  row_repaints=0
  detail_repaints=0
  CNTOOLS_UI_LINES=10
  cntools_menu_run <<< $'down\nq' ||
    fail "short-terminal navigation failed"
  assert_eq "${full_renders}" "2" \
    "short-terminal full-render fallback"
  assert_eq "${row_repaints}" "0" \
    "short-terminal row repaint suppression"
  assert_eq "${detail_repaints}" "0" \
    "short-terminal detail repaint suppression"
)

run_header_and_path_tests() (
  local tree="${TEST_ROOT}/header-path"
  local output=""
  local first_line=""
  local line=""

  make_root "${tree}"
  make_menu "${tree}/root/tools" "Tools" t 10
  make_action "${tree}/root/tools/run" "Run" r 10 \
    '["local", "light", "offline"]'

  CNTOOLS_MODULE_ROOT="${tree}/root"
  CNTOOLS_LIB_DIR="${tree}/lib"
  CNTOOLS_MODE="local"
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="mainnet"
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_UI_CAPABLE="N"

  assert_eq "$(cntools_menu_breadcrumb "${tree}/root")" "/" \
    "root display path"
  assert_eq "$(cntools_menu_breadcrumb "${tree}/root/tools")" "/ Tools" \
    "nested menu display path"
  assert_eq "$(cntools_menu_breadcrumb "${tree}/root/tools/run")" \
    "/ Tools / Run" "nested action display path"

  output="$(cntools_ui_render_begin "Wallet" "/ Wallet")"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    first_line="${line}"
    break
  done <<< "${output}"
  [[ "${first_line}" == "CNTools v14.0.0"* ]] ||
    fail "header is not anchored to the CNTools name and version: ${first_line}"
  [[ "${output}" == *$'\n/ Wallet\n'* ]] ||
    fail "header does not show the current path below the product name"
  [[ "${first_line}" != Wallet* ]] ||
    fail "current menu label replaced the static CNTools header"
)

run_update_render_width_tests() (
  local output_file="${TEST_ROOT}/update-render-width.out"
  local line=""

  CNTOOLS_UI_DRAW_WIDTH=39
  CNTOOLS_UI_BOLD=""
  CNTOOLS_UI_RESET=""
  CNTOOLS_UI_YELLOW=""
  CNTOOLS_VERSION="14.12345678901234567890.0"
  CNTOOLS_UPDATE_STATUS="available"
  CNTOOLS_UPDATE_REMOTE_VERSION="14.98765432109876543210.0"
  CNTOOLS_ACCOUNT="an-intentionally-long-account-name"
  CNTOOLS_BRANCH="an-intentionally-long-branch-name"

  {
    cntools_update_render_banner
    cntools_update_render_summary
  } > "${output_file}"
  while IFS= read -r line; do
    (( ${#line} <= CNTOOLS_UI_DRAW_WIDTH )) ||
      fail "update UI exceeded the safe draw width: ${line}"
  done < "${output_file}"
  assert_eq "$(wc -l < "${output_file}" | tr -d '[:space:]')" "7" \
    "fixed-height update rendering"
)

run_errexit_tests() (
  local tree="${TEST_ROOT}/errexit"
  local runner="${TEST_ROOT}/errexit-runner.sh"
  local failure_command="${TEST_ROOT}/errexit-command.sh"
  local curl_bin="${TEST_ROOT}/errexit-bin"
  local log_file=""
  local response="${TEST_ROOT}/errexit.response"
  local status=0

  make_root "${tree}"
  make_action "${tree}/root/fail" "Fail" a 10 \
    '["local", "light", "offline"]'
  write_file "${tree}/root/fail/action.sh" '#!/usr/bin/env bash
cntools_action_main() {
  return 17
}'
  write_file "${failure_command}" '#!/usr/bin/env bash
exit 23'
  chmod 0700 "${failure_command}"
  mkdir -p "${curl_bin}"
  write_file "${curl_bin}/curl" '#!/usr/bin/env bash
exit 7'
  chmod 0700 "${curl_bin}/curl"

  write_file "${runner}" '#!/usr/bin/env bash
set -e
case "$1" in
  command)
    . "$2/core/log.sh"
    CNTOOLS_LOG="$3"
    cntools_log_init
    cntools_run_command 0 -- "$4"
    ;;
  action|menu)
    . "$2/core/startup.sh"
    . "$2/core/log.sh"
    . "$2/core/ui.sh"
    . "$2/core/update.sh"
    . "$2/core/menu.sh"
    . "$2/core/action.sh"
    CNTOOLS_MODULE_ROOT="$3/root"
    CNTOOLS_LIB_DIR="$3/lib"
    CNTOOLS_VALIDATION_BASH="bash"
    CNTOOLS_MODE="local"
    CNTOOLS_BACKEND="cnode"
    CNTOOLS_NETWORK="preview"
    CNTOOLS_ADVANCED="N"
    CNTOOLS_VERSION="14.0.0"
    CNTOOLS_UI_INTERACTIVE="N"
    CNTOOLS_UI_CAPABLE="N"
    CNTOOLS_LOG="$4"
    cntools_log_init
    if [[ "$1" == "action" ]]; then
      cntools_action_run "$3/root/fail"
    else
      cntools_menu_run <<< $'\''a\nq\n'\'' >/dev/null
    fi
    ;;
  http)
    . "$2/core/log.sh"
    CNTOOLS_LOG="$3"
    CNTOOLS_MODE="light"
    CNTOOLS_CURL_TIMEOUT="1"
    cntools_log_init
    cntools_http_request GET "https://example.test/failure" "$4"
    ;;
  *) exit 99 ;;
esac'
  chmod 0700 "${runner}"

  log_file="${TEST_ROOT}/errexit-command.log"
  if bash "${runner}" command "${CNTOOLS_ROOT}" "${log_file}" \
    "${failure_command}" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "23" "strict command-wrapper status"
  grep -E -- '-> 23$' "${log_file}" >/dev/null ||
    fail "strict command failure was not logged after execution"

  log_file="${TEST_ROOT}/errexit-action.log"
  if bash "${runner}" action "${CNTOOLS_ROOT}" "${tree}" \
    "${log_file}" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "17" "strict action status"
  grep -F 'completed with status 17' "${log_file}" >/dev/null ||
    fail "strict action failure was not logged after execution"

  log_file="${TEST_ROOT}/errexit-menu.log"
  if bash "${runner}" menu "${CNTOOLS_ROOT}" "${tree}" \
    "${log_file}" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "0" "strict menu action-failure recovery"
  grep -F 'failed with status 17' "${log_file}" >/dev/null ||
    fail "strict menu action failure was not logged"

  log_file="${TEST_ROOT}/errexit-http.log"
  if PATH="${curl_bin}:${PATH}" bash "${runner}" http "${CNTOOLS_ROOT}" \
    "${log_file}" "${response}" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "7" "strict HTTP transport status"
  grep -F 'GET /failure -> curl:7' "${log_file}" >/dev/null ||
    fail "strict HTTP transport failure was not logged"
)

run_metadata_tests
run_order_and_visibility_tests
run_action_tests
run_log_and_wrapper_tests
run_http_tests
run_ui_tests
run_navigation_tests
run_navigation_cache_tests
run_cache_root_key_tests
run_selective_repaint_tests
run_header_and_path_tests
run_update_render_width_tests
run_errexit_tests

printf 'CNTools framework tests passed\n'
