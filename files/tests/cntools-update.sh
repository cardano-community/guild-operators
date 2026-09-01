#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
MODULE_ROOT="${CNTOOLS_ROOT}/modules/root"
CHANGELOG_FIXTURE="${REPO_ROOT}/files/tests/fixtures/cntools-update-changelog.md"

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

assert_contains() {
  local content="$1"
  local expected="$2"
  local context="$3"

  [[ "${content}" == *"${expected}"* ]] ||
    fail "${context}: missing '${expected}'"
}

assert_not_contains() {
  local content="$1"
  local rejected="$2"
  local context="$3"

  [[ "${content}" != *"${rejected}"* ]] ||
    fail "${context}: unexpectedly contains '${rejected}'"
}

assert_fails() {
  local context="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    fail "${context}"
  fi
}

for required_command in \
  awk bash chmod cp env find grep jq ln mktemp mkdir mv rm rmdir stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for source_file in \
  "${CNTOOLS_ROOT}/core/theme.sh" \
  "${CNTOOLS_ROOT}/core/gum.sh" \
  "${CNTOOLS_ROOT}/core/update.sh" \
  "${CNTOOLS_ROOT}/lib/update.sh" \
  "${MODULE_ROOT}/update/check/action.sh" \
  "${MODULE_ROOT}/update/view-changes/action.sh" \
  "${MODULE_ROOT}/update/install/action.sh"; do
  [[ -f "${source_file}" && ! -L "${source_file}" && -s "${source_file}" ]] ||
    fail "missing or unsafe Phase 5 source: ${source_file}"
  bash -n "${source_file}" ||
    fail "Phase 5 source failed syntax validation: ${source_file}"
done

[[ -f "${CHANGELOG_FIXTURE}" && ! -L "${CHANGELOG_FIXTURE}" ]] ||
  fail "update changelog fixture is missing or unsafe"
grep -F 'cntools_api_request GET' "${CNTOOLS_ROOT}/core/update.sh" >/dev/null ||
  fail "automatic update checking bypasses the core API wrapper"
grep -F 'cntools_api_request GET' "${CNTOOLS_ROOT}/lib/update.sh" >/dev/null ||
  fail "changelog retrieval bypasses the core API wrapper"
if grep -F 'cntools.library' \
  "${CNTOOLS_ROOT}/core/update.sh" \
  "${CNTOOLS_ROOT}/lib/update.sh" \
  "${MODULE_ROOT}/update/check/action.sh" \
  "${MODULE_ROOT}/update/view-changes/action.sh" \
  "${MODULE_ROOT}/update/install/action.sh" >/dev/null; then
  fail "Phase 5 update code references the legacy CNTools library"
fi

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools update live tests skipped: Bash 4.4+ is required\n'
  printf 'CNTools update static tests passed\n'
  exit 0
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-update.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"

cleanup_test() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/startup.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/update.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/menu.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/action.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/theme.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/gum.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/update.sh"

# Update behavior is tested without invoking the external Gum process. The
# Gum interaction itself is covered by cntools-main.sh; these stubs preserve
# its shared UI contract while keeping update tests deterministic.
cntools_ui_action_begin() { return 0; }
cntools_ui_render_field() { printf '%s: %s\n' "$1" "$2"; }
cntools_ui_render_status() {
  [[ -z "${2:-}" ]] || printf '%s\n' "$2"
}
cntools_ui_wait() { return 0; }
cntools_ui_page_file() {
  local page_line=""

  while IFS= read -r page_line || [[ -n "${page_line}" ]]; do
    printf '%s\n' "${page_line}"
  done < "$1"
}
cntools_ui_confirm() { return 1; }
cntools_ui_restore_terminal() { return 0; }

for required_function in \
  cntools_update_version_valid cntools_update_version_compare \
  cntools_update_url cntools_update_init cntools_update_check \
  cntools_update_state_save cntools_update_state_load \
  cntools_update_set_state cntools_update_cleanup \
  cntools_update_extract_changelog; do
  declare -F "${required_function}" >/dev/null 2>&1 ||
    fail "missing Phase 5 function: ${required_function}"
done

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

write_file() {
  local target="$1"
  local content="$2"

  printf '%s\n' "${content}" > "${target}"
}

setup_update_context() {
  local name="$1"

  CASE_ROOT="${TEST_ROOT}/${name}"
  mkdir -p "${CASE_ROOT}/logs"
  CNTOOLS_LOG_DIR="${CASE_ROOT}/logs"
  CNTOOLS_LOG="${CNTOOLS_LOG_DIR}/cntools.log"
  CNTOOLS_MODE="local"
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="preview"
  CNTOOLS_ACCOUNT="fixture-account"
  CNTOOLS_BRANCH="feature/update"
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_UPDATE_CHECK="N"
  CNTOOLS_CURL_TIMEOUT="3"
  CNTOOLS_MODULE_ROOT="${MODULE_ROOT}"
  CNTOOLS_LIB_DIR="${CNTOOLS_ROOT}/lib"
  CNTOOLS_VALIDATION_BASH="bash"
  CNTOOLS_ADVANCED="N"
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="N"
  cntools_log_init || fail "could not initialize update-test logger"
}

close_update_context() {
  cntools_update_cleanup || true
  cntools_log_close || true
}

run_version_tests() (
  local version=""
  local comparison=""

  for version in 0.0.0 14.0.0 14.10.123 99999999999999999999.1.0; do
    cntools_update_version_valid "${version}" ||
      fail "valid update version was rejected: ${version}"
  done
  for version in '' v14.0.0 14 14.0 14.0.0.1 014.0.0 14.01.0 \
    14.0.01 14.0.0-rc1 '14.0.0 ' $'14.0.0\n15.0.0' '$(false)'; do
    assert_fails "invalid update version was accepted: ${version}" \
      cntools_update_version_valid "${version}"
  done

  cntools_update_version_compare 14.0.0 14.0.0 comparison
  assert_eq "${comparison}" "0" "equal version comparison"
  cntools_update_version_compare 14.0.1 14.0.0 comparison
  assert_eq "${comparison}" "1" "patch version comparison"
  cntools_update_version_compare 14.100.0 14.99.99 comparison
  assert_eq "${comparison}" "1" "minor version comparison"
  cntools_update_version_compare 15.0.0 14.99.99 comparison
  assert_eq "${comparison}" "1" "major version comparison"
  cntools_update_version_compare 14.10.0 14.9.99 comparison
  assert_eq "${comparison}" "1" "multi-digit component comparison"
  cntools_update_version_compare 14.0.0 14.0.1 comparison
  assert_eq "${comparison}" "-1" "older version comparison"
  cntools_update_version_compare \
    99999999999999999999.0.0 9999999999999999999.999.999 comparison
  assert_eq "${comparison}" "1" "overflow-safe version comparison"
  assert_fails "version comparison accepted an invalid operand" \
    cntools_update_version_compare v14.0.0 14.0.0 comparison
  assert_fails "version comparison accepted an unsafe output name" \
    cntools_update_version_compare 14.0.0 14.0.0 'unsafe[name]'
)

run_url_tests() (
  local url=""

  CNTOOLS_ACCOUNT="fixture-account"
  CNTOOLS_BRANCH="feature/update"
  url="$(cntools_update_url version)" || fail "VERSION URL construction failed"
  assert_eq "${url}" \
    'https://raw.githubusercontent.com/fixture-account/guild-operators/feature/update/scripts/common-helper-scripts/cntools/VERSION' \
    "VERSION URL"
  url="$(cntools_update_url changelog)" || fail "changelog URL construction failed"
  assert_eq "${url}" \
    'https://raw.githubusercontent.com/fixture-account/guild-operators/feature/update/docs/Scripts/cntools-changelog.md' \
    "changelog URL"
  assert_fails "unknown update resource was accepted" cntools_update_url unknown
  CNTOOLS_ACCOUNT='unsafe/account'
  assert_fails "unsafe update account was accepted" cntools_update_url version
  CNTOOLS_ACCOUNT='fixture-account'
  CNTOOLS_BRANCH='../unsafe'
  assert_fails "unsafe update branch was accepted" cntools_update_url version
)

run_state_tests() (
  local state_file=""
  local started_file=""
  local save_status=0
  local staged_files=""

  setup_update_context state
  cntools_update_init
  assert_eq "${CNTOOLS_UPDATE_STATUS}" "skipped" "initial skipped state"
  assert_eq "${CNTOOLS_UPDATE_REMOTE_VERSION}" "" "initial remote version"
  state_file="${CNTOOLS_UPDATE_STATE_FILE}"
  started_file="${CNTOOLS_DEPLOY_STARTED_FILE}"
  [[ -f "${state_file}" && ! -L "${state_file}" ]] ||
    fail "update state file is missing or unsafe"
  assert_eq "$(file_mode "${state_file}")" "600" "update state file mode"

  cntools_update_set_state available 14.2.0 ||
    fail "valid available state could not be saved"
  CNTOOLS_UPDATE_STATUS="unchecked"
  CNTOOLS_UPDATE_REMOTE_VERSION=""
  cntools_update_state_load || fail "valid update state could not be loaded"
  assert_eq "${CNTOOLS_UPDATE_STATUS}" "available" "loaded update state"
  assert_eq "${CNTOOLS_UPDATE_REMOTE_VERSION}" "14.2.0" \
    "loaded remote version"

  # A failed atomic replace must not strand its private staging file or
  # damage the last valid state record.
  mv() {
    return 37
  }
  if cntools_update_set_state current 14.0.0 >/dev/null 2>&1; then
    save_status=0
  else
    save_status=$?
  fi
  unset -f mv
  assert_eq "${save_status}" "1" "failed state replacement status"
  staged_files="$(find "${CNTOOLS_UPDATE_STATE_DIR}" \
    -type f -name '.cntools-update-state.*' ! -path "${state_file}" -print)"
  assert_eq "${staged_files}" "" "failed state replacement cleanup"
  cntools_update_state_load ||
    fail "failed state replacement damaged the previous state"
  assert_eq "${CNTOOLS_UPDATE_STATUS}" "available" \
    "state after failed replacement"
  assert_eq "${CNTOOLS_UPDATE_REMOTE_VERSION}" "14.2.0" \
    "remote version after failed replacement"

  assert_fails "invalid current state without a version was accepted" \
    cntools_update_set_state current ''
  assert_fails "unknown update state was accepted" \
    cntools_update_set_state mystery ''
  printf '%s\n' 'available' 'not-a-version' > "${state_file}"
  assert_fails "malformed persisted update state was accepted" \
    cntools_update_state_load

  : > "${started_file}"
  cntools_update_cleanup
  [[ ! -e "${state_file}" && ! -e "${started_file}" ]] ||
    fail "update state cleanup left runtime files"
  assert_eq "${CNTOOLS_UPDATE_STATE_FILE}" "" "cleared update state path"
  assert_eq "${CNTOOLS_UPDATE_STATE_DIR}" "" "cleared update state directory"
  assert_eq "${CNTOOLS_DEPLOY_STARTED_FILE}" "" "cleared deploy marker path"
  assert_eq "${CNTOOLS_UPDATE_STATE_STAGING_FILE}" "" \
    "cleared state staging path"
  cntools_log_close
)

run_checker_case() (
  local name="$1"
  local response="$2"
  local request_status="$3"
  local expected_status="$4"
  local expected_remote="$5"
  local trace=""

  setup_update_context "checker-${name}"
  trace="${CASE_ROOT}/http.trace"
  CNTOOLS_UPDATE_CHECK="Y"
  cntools_http_request() {
    local method="$1"
    local url="$2"
    local output_file="$3"
    shift 3
    printf '%s\t%s\t%s\n' "${method}" "${url}" "$*" >> "${trace}"
    if (( request_status != 0 )); then
      return "${request_status}"
    fi
    printf '%s' "${response}" > "${output_file}"
  }

  cntools_update_init
  assert_eq "${CNTOOLS_UPDATE_STATUS}" "${expected_status}" \
    "${name} checker state"
  assert_eq "${CNTOOLS_UPDATE_REMOTE_VERSION}" "${expected_remote}" \
    "${name} checker remote version"
  assert_eq "$(wc -l < "${trace}" | tr -d ' ')" "1" \
    "${name} automatic request count"
  grep -F $'GET\thttps://raw.githubusercontent.com/fixture-account/guild-operators/feature/update/scripts/common-helper-scripts/cntools/VERSION\t' \
    "${trace}" >/dev/null || fail "${name} checker used the wrong request"
  [[ -z "$(find "${CNTOOLS_LOG_DIR}" -name '.cntools-update-version.*' -print -quit)" ]] ||
    fail "${name} checker left a VERSION response file"
  close_update_context
)

run_checker_tests() {
  run_checker_case available $'14.2.0\n' 0 available 14.2.0
  run_checker_case current $'14.0.0\n' 0 current 14.0.0
  run_checker_case ahead $'13.5.7\n' 0 ahead 13.5.7
  run_checker_case invalid $'14.2.0\n14.3.0\n' 0 error ''
  run_checker_case whitespace $' 14.2.0\n' 0 error ''
  run_checker_case transport '' 7 error ''
  run_checker_case oversized \
    $'99999999999999999999999999999999999999999999999999999999999999999.0.0\n' \
    0 error ''

  (
    local trace=""
    local status=0

    setup_update_context manual
    trace="${CASE_ROOT}/http.trace"
    cntools_http_request() {
      printf '%s\n' "$2" >> "${trace}"
      printf '%s\n' '14.1.0' > "$3"
    }
    cntools_update_init
    assert_eq "${CNTOOLS_UPDATE_STATUS}" "skipped" \
      "suppressed automatic state"
    [[ ! -e "${trace}" ]] || fail "suppressed automatic check invoked HTTP"
    cntools_update_check manual || fail "manual recheck failed after suppression"
    assert_eq "${CNTOOLS_UPDATE_STATUS}" "available" "manual recheck state"
    assert_eq "${CNTOOLS_UPDATE_REMOTE_VERSION}" "14.1.0" \
      "manual recheck version"
    assert_eq "$(wc -l < "${trace}" | tr -d ' ')" "1" \
      "manual recheck request count"
    if cntools_update_check invalid >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "invalid check-kind status"
    assert_eq "$(wc -l < "${trace}" | tr -d ' ')" "1" \
      "invalid check-kind request count"
    close_update_context
  )

  (
    local trace=""
    local status=0

    setup_update_context offline
    trace="${CASE_ROOT}/http.trace"
    CNTOOLS_MODE="offline"
    CNTOOLS_UPDATE_CHECK="Y"
    cntools_http_request() {
      printf 'invoked\n' >> "${trace}"
      return 99
    }
    cntools_update_init
    assert_eq "${CNTOOLS_UPDATE_STATUS}" "offline" "offline update state"
    [[ ! -e "${trace}" ]] || fail "offline initialization invoked HTTP"
    if cntools_update_check manual >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "offline manual-check status"
    [[ ! -e "${trace}" ]] || fail "offline manual check invoked HTTP"
    close_update_context
  )

  (
    local malicious='14.2.0$(printf REMOTE_CONTENT_MUST_NOT_RUN)'

    setup_update_context malformed-log
    CNTOOLS_UPDATE_CHECK="Y"
    cntools_http_request() {
      printf '%s\n' "${malicious}" > "$3"
    }
    cntools_update_init
    assert_eq "${CNTOOLS_UPDATE_STATUS}" "error" "malicious response state"
    if grep -F "${malicious}" "${CNTOOLS_LOG}" >/dev/null; then
      fail "invalid remote VERSION content was copied into the log"
    fi
    close_update_context
  )

  (
    local status=0
    local trace=""

    setup_update_context malformed-state-recheck
    trace="${CASE_ROOT}/http.trace"
    cntools_update_init
    printf '%s\n' 'available' 'not-a-version' > "${CNTOOLS_UPDATE_STATE_FILE}"
    cntools_http_request() {
      printf '%s\n' "$2" >> "${trace}"
      printf '%s\n' '14.1.0' > "$3"
    }
    if cntools_update_check auto >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "1" "automatic malformed-state status"
    [[ ! -e "${trace}" ]] ||
      fail "automatic check continued with malformed persisted state"
    cntools_update_check manual ||
      fail "manual check did not recover malformed persisted state"
    assert_eq "${CNTOOLS_UPDATE_STATUS}" "available" \
      "manual malformed-state recovery status"
    assert_eq "${CNTOOLS_UPDATE_REMOTE_VERSION}" "14.1.0" \
      "manual malformed-state recovery version"
    cntools_update_state_load ||
      fail "manual malformed-state recovery was not persisted"
    assert_eq "$(wc -l < "${trace}" | tr -d ' ')" "1" \
      "manual malformed-state recovery request count"
    grep -F 'reinitialized invalid update availability state' \
      "${CNTOOLS_LOG}" >/dev/null ||
      fail "manual malformed-state recovery was not logged"
    close_update_context
  )

  (
    local status=0

    setup_update_context interrupted-check
    cntools_update_init
    cntools_http_request() {
      exit 143
    }
    if (
      cntools_update_check manual
    ) >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    [[ "${status}" -ne 0 ]] ||
      fail "interrupted availability check returned success"
    [[ -z "$(find "${CNTOOLS_UPDATE_STATE_DIR}" \
        -name '.cntools-update-version.*' -print -quit)" ]] ||
      fail "interrupted availability check left a VERSION response file"
    close_update_context
  )

  (
    local status=0
    local staged_files=""

    setup_update_context interrupted-state-save
    cntools_update_init
    cntools_http_request() {
      printf '%s\n' '14.1.0' > "$3"
    }
    if (
      mv() {
        exit 143
      }
      cntools_update_action_check >/dev/null 2>&1
    ); then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "143" "interrupted state replacement status"
    staged_files="$(find "${CNTOOLS_UPDATE_STATE_DIR}" \
      -type f -name '.cntools-update-state.*' \
      ! -path "${CNTOOLS_UPDATE_STATE_FILE}" -print)"
    assert_eq "${staged_files}" "" \
      "interrupted state replacement cleanup"
    close_update_context
  )
}

run_changelog_tests() (
  local notes_file="${TEST_ROOT}/range-notes.md"
  local unsafe_file="${TEST_ROOT}/unsafe-changelog.md"
  local unsafe_notes="${TEST_ROOT}/unsafe-notes.md"
  local notes=""
  local execution_marker="${TEST_ROOT}/remote-content-executed"

  : > "${notes_file}"
  cntools_update_extract_changelog \
    "${CHANGELOG_FIXTURE}" "${notes_file}" 14.0.0 14.2.0 ||
    fail "valid changelog range extraction failed"
  notes="$(< "${notes_file}")"
  assert_contains "${notes}" '## [14.2.0]' "changelog upper range"
  assert_contains "${notes}" 'RANGE_VERSION_14_2' "changelog 14.2 body"
  assert_contains "${notes}" '## [14.1.0]' "changelog intermediate range"
  assert_contains "${notes}" 'RANGE_VERSION_14_1' "changelog 14.1 body"
  assert_contains "${notes}" '$(printf SHOULD_NOT_EXECUTE)' \
    "literal changelog shell text"
  assert_not_contains "${notes}" 'OUTSIDE_UPPER_BOUND' \
    "changelog upper-bound filtering"
  assert_not_contains "${notes}" 'INSTALLED_LOWER_BOUND' \
    "changelog installed-bound filtering"
  assert_not_contains "${notes}" 'OUTSIDE_OLDER_BOUND' \
    "changelog older-bound filtering"
  assert_not_contains "${notes}" 'Synthetic CNTools changelog preamble' \
    "changelog preamble filtering"
  [[ ! -e "${execution_marker}" ]] ||
    fail "changelog content was evaluated as shell code"

  : > "${notes_file}"
  cntools_update_extract_changelog \
    "${CHANGELOG_FIXTURE}" "${notes_file}" 14.1.0 14.2.0 ||
    fail "single-release changelog extraction failed"
  notes="$(< "${notes_file}")"
  assert_contains "${notes}" 'RANGE_VERSION_14_2' \
    "single-release changelog content"
  assert_not_contains "${notes}" 'RANGE_VERSION_14_1' \
    "single-release lower-bound filtering"

  : > "${notes_file}"
  assert_fails "changelog extraction accepted a missing available section" \
    cntools_update_extract_changelog \
      "${CHANGELOG_FIXTURE}" "${notes_file}" 14.2.0 14.9.0
  assert_fails "changelog extraction accepted an invalid installed version" \
    cntools_update_extract_changelog \
      "${CHANGELOG_FIXTURE}" "${notes_file}" v14.0.0 14.2.0

  printf '%s\n' \
    '## [14.1.0] - Unreleased' \
    $'- text containing an escape \033 sequence' > "${unsafe_file}"
  : > "${unsafe_notes}"
  assert_fails "terminal-control changelog content was accepted" \
    cntools_update_extract_changelog \
      "${unsafe_file}" "${unsafe_notes}" 14.0.0 14.1.0

  ln -s "${CHANGELOG_FIXTURE}" "${TEST_ROOT}/linked-changelog.md"
  assert_fails "symlinked changelog input was accepted" \
    cntools_update_extract_changelog \
      "${TEST_ROOT}/linked-changelog.md" "${notes_file}" 14.0.0 14.2.0
)

run_update_action_tests() (
  local output=""
  local trace=""
  local ui_trace=""
  local index=0
  local status=0

  setup_update_context update-actions
  trace="${CASE_ROOT}/http.trace"
  ui_trace="${CASE_ROOT}/ui.trace"
  cntools_update_init
  cntools_update_set_state available 14.2.0 ||
    fail "could not prepare available state for update actions"
  cntools_http_request() {
    printf '%s\t%s\n' "$1" "$2" >> "${trace}"
    cp -- "${CHANGELOG_FIXTURE}" "$3"
  }
  cntools_ui_wait() {
    printf 'wait\n' >> "${ui_trace}"
  }
  cntools_ui_page_file() {
    local page_line=""

    printf 'page\n' >> "${ui_trace}"
    while IFS= read -r page_line || [[ -n "${page_line}" ]]; do
      printf '%s\n' "${page_line}"
    done < "$1"
  }

  : > "${ui_trace}"
  output="$(cntools_update_action_view_changes)" ||
    fail "View Changes action failed"
  assert_contains "${output}" 'Changes in v14.2.0 since v14.0.0' \
    "View Changes heading"
  assert_contains "${output}" 'RANGE_VERSION_14_2' \
    "View Changes latest section"
  assert_contains "${output}" 'RANGE_VERSION_14_1' \
    "View Changes intermediate section"
  assert_not_contains "${output}" 'INSTALLED_LOWER_BOUND' \
    "View Changes lower bound"
  assert_eq "$(wc -l < "${trace}" | tr -d ' ')" "1" \
    "View Changes request count"
  grep -F $'GET\thttps://raw.githubusercontent.com/fixture-account/guild-operators/feature/update/docs/Scripts/cntools-changelog.md' \
    "${trace}" >/dev/null || fail "View Changes used the wrong changelog URL"
  [[ -z "$(find "${CNTOOLS_LOG_DIR}" \
      \( -name '.cntools-changelog.*' -o -name '.cntools-release-notes.*' \) \
      -print -quit)" ]] || fail "View Changes left a response or notes file"
  if grep -F 'RANGE_VERSION_' "${CNTOOLS_LOG}" >/dev/null; then
    fail "View Changes copied changelog body content into the log"
  fi
  assert_eq "$(< "${ui_trace}")" "page" \
    "Gum View Changes pager return flow"

  cntools_update_set_state available 14.2.0
  cntools_http_request() {
    printf '%s\n' 'partial response' > "$3"
    return 7
  }
  : > "${ui_trace}"
  output="$(cntools_update_action_view_changes)" ||
    fail "failed-download View Changes action did not recover"
  assert_contains "${output}" 'Release notes are unavailable' \
    "failed-download View Changes message"
  [[ -z "$(find "${CNTOOLS_LOG_DIR}" \
      \( -name '.cntools-changelog.*' -o -name '.cntools-release-notes.*' \) \
      -print -quit)" ]] ||
    fail "failed-download View Changes left a response or notes file"
  assert_eq "$(< "${ui_trace}")" "wait" \
    "failed View Changes return flow"

  # The action normally runs in the loader's subshell. An unexpected exit or
  # interruption inside its HTTP layer must still remove both private files.
  if (
    cntools_http_request() {
      exit 143
    }
    cntools_update_action_view_changes >/dev/null 2>&1
  ); then
    fail "interrupted View Changes action unexpectedly returned success"
  else
    assert_eq "$?" "143" "interrupted View Changes status"
  fi
  [[ -z "$(find "${CNTOOLS_LOG_DIR}" \
      \( -name '.cntools-changelog.*' -o -name '.cntools-release-notes.*' \) \
      -print -quit)" ]] ||
    fail "interrupted View Changes left a response or notes file"

  cntools_update_set_state current 14.0.0
  : > "${trace}"
  output="$(cntools_update_action_view_changes)" ||
    fail "no-update View Changes action failed"
  assert_contains "${output}" 'No newer version is currently known' \
    "no-update View Changes message"
  [[ ! -s "${trace}" ]] || fail "no-update View Changes fetched the changelog"

  # Manual checking is a normal lazy action. Its state file lets the Gum menu
  # observe the new result after the action subshell exits.
  cntools_update_set_state skipped ''
  cntools_http_request() {
    printf '%s\n' "$2" >> "${trace}"
    printf '%s\n' '14.1.0' > "$3"
  }
  : > "${trace}"
  output="$(cntools_action_run "${MODULE_ROOT}/update/check")" ||
    fail "Check Again action failed"
  cntools_update_state_load || fail "Check Again did not persist its result"
  assert_eq "${CNTOOLS_UPDATE_STATUS}" "available" \
    "Check Again persisted state"
  assert_eq "${CNTOOLS_UPDATE_REMOTE_VERSION}" "14.1.0" \
    "Check Again persisted version"
  assert_contains "${output}" 'A newer CNTools version is available' \
    "Check Again available message"
  assert_eq "$(wc -l < "${trace}" | tr -d ' ')" "1" \
    "Check Again request count"

  # View and Install must fail closed if the private persisted state can no
  # longer be trusted, even if the in-memory values still say available.
  printf '%s\n' 'available' 'not-a-version' > "${CNTOOLS_UPDATE_STATE_FILE}"
  : > "${trace}"
  if output="$(cntools_update_action_view_changes 2>&1)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "1" "malformed-state View Changes status"
  assert_contains "${output}" 'Update state is unavailable' \
    "malformed-state View Changes message"
  [[ ! -s "${trace}" ]] ||
    fail "malformed-state View Changes invoked the changelog API"
  if output="$(cntools_update_action_install 2>&1)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "1" "malformed-state Install status"
  assert_contains "${output}" 'Update state is unavailable' \
    "malformed-state Install message"

  CNTOOLS_MODE="offline"
  cntools_menu_open "${MODULE_ROOT}/update" ||
    fail "Update submenu could not be opened offline"
  assert_eq "${#CNTOOLS_MENU_IDS[@]}" "3" "offline Update action count"
  for (( index = 0; index < ${#CNTOOLS_MENU_IDS[@]}; index++ )); do
    assert_eq "${CNTOOLS_MENU_ENABLED[index]}" "N" \
      "${CNTOOLS_MENU_IDS[index]} offline state"
  done
  if cntools_action_run "${MODULE_ROOT}/update/check" >/dev/null 2>&1; then
    fail "direct loading bypassed the offline Update action restriction"
  else
    assert_eq "$?" "3" "offline Update action status"
  fi

  close_update_context
)

prepare_dispatcher() {
  local dispatcher="$1"

  write_file "${dispatcher}" '#!/usr/bin/env bash
{
  printf "%s\n" "G_ACCOUNT=${G_ACCOUNT:-}"
  printf "%s\n" "S_ARGS=${S_ARGS-unset}"
  printf "%s\n" "GUILD_DEPLOY_SNAPSHOT_STAGE=${GUILD_DEPLOY_SNAPSHOT_STAGE:-}"
  printf "%s\n" "GUILD_DEPLOY_STRICT_REF=${GUILD_DEPLOY_STRICT_REF:-}"
  for argument in "$@"; do
    printf "%s\n" "arg=${argument}"
  done
} > "${CNTOOLS_TEST_DISPATCH_TRACE}"
printf "%s\n" dispatch >> "${CNTOOLS_TEST_SEQUENCE_TRACE}"
exit "${CNTOOLS_TEST_DISPATCH_STATUS:-0}"
'
  chmod 0755 "${dispatcher}"
}

run_install_case() (
  local name="$1"
  local dispatcher_status="$2"
  local expected_status="$3"
  local remote_version="${4:-14.2.0}"
  local update_status="${5:-available}"
  local output=""
  local status=0
  local expected_trace=""
  local dispatch_trace=""
  local sequence_trace=""
  local confirmation_trace=""

  setup_update_context "install-${name}"
  CNTOOLS_NODE_HOME="${CASE_ROOT}/node"
  CNTOOLS_IMPLEMENTATION="dingo"
  CNTOOLS_IMPLEMENTATION_NAME="Dingo"
  mkdir -p "${CNTOOLS_NODE_HOME}/scripts"
  dispatch_trace="${CASE_ROOT}/dispatcher.trace"
  sequence_trace="${CASE_ROOT}/sequence.trace"
  confirmation_trace="${CASE_ROOT}/confirmation.trace"
  CNTOOLS_TEST_DISPATCH_TRACE="${dispatch_trace}"
  CNTOOLS_TEST_SEQUENCE_TRACE="${sequence_trace}"
  CNTOOLS_TEST_DISPATCH_STATUS="${dispatcher_status}"
  export CNTOOLS_TEST_DISPATCH_TRACE CNTOOLS_TEST_SEQUENCE_TRACE
  export CNTOOLS_TEST_DISPATCH_STATUS
  prepare_dispatcher "${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh"
  cntools_update_init
  cntools_update_set_state "${update_status}" "${remote_version}"

  cntools_ui_restore_terminal() {
    printf '%s\n' restore >> "${sequence_trace}"
  }
  cntools_ui_confirm() {
    printf '%s\n' "$1" > "${confirmation_trace}"
    return 0
  }
  if output="$(cntools_update_action_install 2>&1)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "${expected_status}" \
    "${name} dispatcher status propagation"
  assert_contains "${output}" \
    "CNTools          : v14.0.0 -> v${remote_version}" \
    "${name} explicit version transition"
  if [[ "${update_status}" == "current" ]]; then
    assert_contains "${output}" \
      "installed and selected versions are both v${remote_version}" \
      "${name} matching-version explanation"
    assert_eq "$(< "${confirmation_trace}")" \
      "Force deploy this version anyway?" \
      "${name} force-deployment confirmation"
    grep -F \
      "force deployment confirmed version=${remote_version}" \
      "${CNTOOLS_LOG}" >/dev/null ||
      fail "${name} force deployment was not logged"
  else
    assert_eq "$(< "${confirmation_trace}")" \
      "Install this update now?" "${name} update confirmation"
  fi
  [[ -s "${dispatch_trace}" ]] || fail "${name} did not invoke Guild Deploy"
  expected_trace=$'G_ACCOUNT=fixture-account\nS_ARGS=\nGUILD_DEPLOY_SNAPSHOT_STAGE=bootstrap\nGUILD_DEPLOY_STRICT_REF=Y\narg=-g\narg=fixture-account\narg=-i\narg=dingo\narg=-n\narg=preview\narg=-p\narg='"${CASE_ROOT}"$'\narg=-t\narg=node\narg=-b\narg=feature/update\narg=-s\narg='
  assert_eq "$(< "${dispatch_trace}")" "${expected_trace}" \
    "${name} dispatcher environment and arguments"
  cntools_startup_deployment_was_started ||
    fail "${name} did not persist the deployment-started lifecycle marker"
  assert_not_contains "${output}" 'CNTools was replaced.' \
    "${name} obsolete replacement message"
  assert_not_contains "${output}" 'Refresh this shell' \
    "${name} obsolete shell-refresh guidance"
  assert_not_contains "${output}" "cd -- ${CNTOOLS_ROOT}" \
    "${name} obsolete re-entry command"
  grep -F 'GUILD_DEPLOY_STRICT_REF=Y' "${CNTOOLS_LOG}" >/dev/null ||
    fail "${name} dispatcher command was not logged"
  awk '
    previous == "restore" && $0 == "dispatch" { ordered = 1 }
    { previous = $0 }
    END { exit ordered ? 0 : 1 }
  ' "${sequence_trace}" ||
    fail "${name} did not restore the terminal immediately before Guild Deploy"
  close_update_context
)

run_install_guard_tests() (
  local dispatch_trace=""
  local dispatcher=""
  local real_dispatcher=""
  local confirmation_trace=""
  local output=""
  local output_file=""
  local error_file=""
  local status=0

  setup_update_context install-guards
  CNTOOLS_NODE_HOME="${CASE_ROOT}/node"
  CNTOOLS_IMPLEMENTATION="cnode"
  CNTOOLS_IMPLEMENTATION_NAME="Cardano Node"
  mkdir -p "${CNTOOLS_NODE_HOME}/scripts"
  dispatch_trace="${CASE_ROOT}/dispatcher.trace"
  confirmation_trace="${CASE_ROOT}/confirmation.trace"
  CNTOOLS_TEST_DISPATCH_TRACE="${dispatch_trace}"
  CNTOOLS_TEST_SEQUENCE_TRACE="${CASE_ROOT}/sequence.trace"
  CNTOOLS_TEST_DISPATCH_STATUS=0
  export CNTOOLS_TEST_DISPATCH_TRACE CNTOOLS_TEST_SEQUENCE_TRACE
  export CNTOOLS_TEST_DISPATCH_STATUS
  prepare_dispatcher "${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh"
  dispatcher="${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh"
  cntools_update_init
  cntools_update_set_state available 14.2.0

  cntools_ui_confirm() {
    printf '%s\n' "$1" > "${confirmation_trace}"
    return 1
  }
  cntools_update_action_install >/dev/null ||
    fail "cancelled update action failed"
  [[ ! -e "${dispatch_trace}" ]] || fail "cancelled update invoked Guild Deploy"
  ! cntools_startup_deployment_was_started ||
    fail "cancelled update created a deployment-started marker"

  cntools_update_set_state current 14.0.0
  : > "${confirmation_trace}"
  output="$(cntools_update_action_install)" ||
    fail "cancelled force-deployment action failed"
  assert_contains "${output}" \
    'installed and selected versions are both v14.0.0' \
    "matching-version force-deployment message"
  assert_contains "${output}" 'Force deployment cancelled' \
    "cancelled force-deployment result"
  assert_eq "$(< "${confirmation_trace}")" \
    "Force deploy this version anyway?" \
    "matching-version force-deployment confirmation"
  [[ ! -e "${dispatch_trace}" ]] ||
    fail "cancelled force deployment invoked Guild Deploy"
  ! cntools_startup_deployment_was_started ||
    fail "cancelled force deployment created a deployment-started marker"
  grep -F 'force deployment cancelled version=14.0.0' \
    "${CNTOOLS_LOG}" >/dev/null ||
    fail "cancelled force deployment was not logged"

  cntools_update_set_state current 14.1.0
  : > "${confirmation_trace}"
  if output="$(cntools_update_action_install)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "1" "inconsistent current-version state status"
  assert_contains "${output}" 'Update state is inconsistent' \
    "inconsistent current-version state message"
  [[ ! -s "${confirmation_trace}" ]] ||
    fail "inconsistent current-version state requested confirmation"
  [[ ! -e "${dispatch_trace}" ]] ||
    fail "inconsistent current-version state invoked Guild Deploy"

  cntools_update_set_state available 14.2.0
  rm -f -- "${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh"
  output_file="${CASE_ROOT}/missing-dispatcher.stdout"
  error_file="${CASE_ROOT}/missing-dispatcher.stderr"
  cntools_ui_confirm() { return 0; }
  if cntools_update_action_install \
      > "${output_file}" 2> "${error_file}"; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "1" "missing-dispatcher action status"
  grep -F 'Guild Deploy is unavailable' "${error_file}" >/dev/null ||
    fail "missing dispatcher error is not actionable"
  grep -F 'GUILD_DEPLOY_STRICT_REF=Y' "${error_file}" >/dev/null ||
    fail "missing dispatcher recovery command omitted strict-ref handling"
  grep -F -- '-g fixture-account' "${error_file}" >/dev/null ||
    fail "missing dispatcher recovery command omitted the account"
  [[ ! -e "${dispatch_trace}" ]] || fail "missing dispatcher was invoked"
  ! cntools_startup_deployment_was_started ||
    fail "missing dispatcher created a deployment-started marker"

  assert_unsafe_dispatcher_rejected() {
    local context="$1"
    local rejected_status=0

    if cntools_startup_deploy_branch "${CNTOOLS_BRANCH}" \
        >/dev/null 2>&1; then
      rejected_status=0
    else
      rejected_status=$?
    fi
    assert_eq "${rejected_status}" "1" "${context} dispatcher rejection"
    [[ ! -e "${dispatch_trace}" ]] ||
      fail "${context} dispatcher was invoked"
    ! cntools_startup_deployment_was_started ||
      fail "${context} dispatcher created a deployment-started marker"
  }

  write_file "${dispatcher}" '#!/usr/bin/env bash
exit 0'
  chmod 0644 "${dispatcher}"
  assert_unsafe_dispatcher_rejected "non-executable"

  : > "${dispatcher}"
  chmod 0755 "${dispatcher}"
  assert_unsafe_dispatcher_rejected "empty"

  real_dispatcher="${CASE_ROOT}/real-guild-deploy.sh"
  prepare_dispatcher "${real_dispatcher}"
  rm -f -- "${dispatcher}"
  ln -s "${real_dispatcher}" "${dispatcher}"
  assert_unsafe_dispatcher_rejected "symlinked"

  rm -f -- "${dispatcher}"
  mkdir "${dispatcher}"
  assert_unsafe_dispatcher_rejected "non-regular"
  rmdir "${dispatcher}"

  close_update_context
)

run_replacement_boundary_test() (
  local output=""
  local status=0
  local dispatch_trace="${TEST_ROOT}/replacement-boundary.dispatch"
  local http_trace="${TEST_ROOT}/replacement-boundary.http"

  CASE_ROOT="${TEST_ROOT}/replacement-boundary"
  CNTOOLS_ROOT="${CASE_ROOT}/installed/cntools"
  CNTOOLS_LOG_DIR="${CNTOOLS_ROOT}/runtime/logs"
  CNTOOLS_LOG="${CNTOOLS_LOG_DIR}/cntools.log"
  CNTOOLS_NODE_HOME="${CASE_ROOT}/installed"
  CNTOOLS_MODE="local"
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="preview"
  CNTOOLS_ACCOUNT="fixture-account"
  CNTOOLS_BRANCH="feature/update"
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_UPDATE_CHECK="Y"
  CNTOOLS_IMPLEMENTATION="cnode"
  CNTOOLS_IMPLEMENTATION_NAME="Cardano Node"
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="N"
  mkdir -p "${CNTOOLS_LOG_DIR}" "${CNTOOLS_NODE_HOME}/scripts"
  cntools_log_init || fail "replacement-boundary logger initialization failed"
  cntools_http_request() {
    printf 'invoked\n' > "${http_trace}"
    printf '%s\n' '14.2.0' > "$3"
  }
  CNTOOLS_TEST_DISPATCH_TRACE="${dispatch_trace}"
  CNTOOLS_TEST_SEQUENCE_TRACE="${CASE_ROOT}/sequence.trace"
  CNTOOLS_TEST_DISPATCH_STATUS=0
  export CNTOOLS_TEST_DISPATCH_TRACE CNTOOLS_TEST_SEQUENCE_TRACE
  export CNTOOLS_TEST_DISPATCH_STATUS
  prepare_dispatcher "${CNTOOLS_NODE_HOME}/scripts/guild-deploy.sh"

  cntools_update_init
  assert_eq "${CNTOOLS_UPDATE_STATUS}" "error" \
    "replacement-boundary update state"
  assert_eq "${CNTOOLS_UPDATE_STATE_DIR}" "" \
    "replacement-boundary state directory"
  assert_eq "${CNTOOLS_UPDATE_STATE_FILE}" "" \
    "replacement-boundary state file"
  [[ ! -e "${http_trace}" ]] ||
    fail "unsafe replacement-boundary state invoked the update API"

  if output="$(cntools_update_action_install)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "1" \
    "replacement-boundary Install action status"
  assert_contains "${output}" 'Update state is unavailable' \
    "replacement-boundary Install message"
  [[ ! -e "${dispatch_trace}" ]] ||
    fail "unsafe replacement-boundary state invoked Guild Deploy"
  ! cntools_startup_deployment_was_started ||
    fail "unsafe replacement-boundary state recorded deployment start"

  if cntools_startup_deploy_branch "${CNTOOLS_BRANCH}" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "1" \
    "replacement-boundary direct deployment rejection"
  [[ ! -e "${dispatch_trace}" ]] ||
    fail "replacement-boundary direct deployment invoked Guild Deploy"

  cntools_update_cleanup
  cntools_log_close
)

run_unprotected_state_parent_test() (
  local http_trace=""

  setup_update_context unprotected-state-parent
  http_trace="${CASE_ROOT}/http.trace"
  chmod 0777 "${CNTOOLS_LOG_PARENT}"
  CNTOOLS_UPDATE_CHECK="Y"
  cntools_http_request() {
    printf 'invoked\n' > "${http_trace}"
  }

  cntools_update_init
  assert_eq "${CNTOOLS_UPDATE_STATUS}" "error" \
    "unprotected state-parent status"
  assert_eq "${CNTOOLS_UPDATE_STATE_DIR}" "" \
    "unprotected state-parent directory"
  assert_eq "${CNTOOLS_UPDATE_STATE_FILE}" "" \
    "unprotected state-parent file"
  [[ ! -e "${http_trace}" ]] ||
    fail "unprotected state parent invoked the update API"

  chmod 0700 "${CNTOOLS_LOG_PARENT}"
  close_update_context
)

run_version_tests
run_url_tests
run_state_tests
run_checker_tests
run_changelog_tests
run_update_action_tests
run_install_case success 0 0
run_install_case failure 37 37
run_install_case force 0 0 14.0.0 current
run_install_guard_tests
run_replacement_boundary_test
run_unprotected_state_parent_test

printf 'CNTools update tests passed\n'
