#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools Gum tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
GUM_ENTRYPOINT="${CNTOOLS_ROOT}/cntools_gum.sh"
GUM_CORE="${CNTOOLS_ROOT}/core/gum.sh"
PURE_ENTRYPOINT="${CNTOOLS_ROOT}/cntools.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-gum.XXXXXX")"
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

assert_contains() {
  local actual="$1"
  local expected="$2"
  local context="${3:-text is missing}"

  [[ "${actual}" == *"${expected}"* ]] ||
    fail "${context}: '${expected}' was not found"
}

assert_fails() {
  local context="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    fail "${context}"
  fi
}

for required_command in bash chmod cp grep mktemp mkdir rm tar; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

[[ -f "${GUM_ENTRYPOINT}" && ! -L "${GUM_ENTRYPOINT}" ]] ||
  fail "Gum entrypoint is missing or unsafe"
[[ -f "${GUM_CORE}" && ! -L "${GUM_CORE}" ]] ||
  fail "Gum UI core is missing or unsafe"
[[ -f "${PURE_ENTRYPOINT}" && ! -L "${PURE_ENTRYPOINT}" ]] ||
  fail "pure-Bash entrypoint is missing or unsafe"

bash -n "${GUM_ENTRYPOINT}" "${GUM_CORE}" "${PURE_ENTRYPOINT}" ||
  fail "a CNTools entrypoint or Gum core file has invalid Bash syntax"
if grep -Eq 'cntools_gum|core/gum[.]sh' "${PURE_ENTRYPOINT}"; then
  fail "the pure-Bash entrypoint depends on the experimental Gum interface"
fi

# Loading the parallel entrypoint must define the Gum driver without invoking
# either entrypoint's main function.
# shellcheck source=/dev/null
. "${GUM_ENTRYPOINT}" || fail "unable to source the Gum entrypoint"
for required_function in \
  cntools_gum_find cntools_gum_require cntools_gum_install \
  cntools_gum_archive_member cntools_gum_filter cntools_gum_menu_run; do
  declare -F "${required_function}" >/dev/null 2>&1 ||
    fail "Gum interface function is missing: ${required_function}"
done

make_fake_gum() {
  local target="$1"
  local accepted_version="$2"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "version-check" && "${2:-}" == "= '"${accepted_version}"'" ]]; then' \
    '  exit 0' \
    'fi' \
    'exit 1' > "${target}"
  chmod 0755 "${target}"
}

run_discovery_tests() (
  local case_root="${TEST_ROOT}/discovery"
  local exact="${case_root}/gum-exact"
  local wrong="${case_root}/gum-wrong"

  mkdir -p "${case_root}/install"
  make_fake_gum "${exact}" "${CNTOOLS_GUM_REQUIRED_VERSION}"
  make_fake_gum "${wrong}" "0.0.0"
  CNTOOLS_GUM_INSTALL_DIR="${case_root}/install"

  CNTOOLS_GUM_BIN="${exact}"
  cntools_gum_find || fail "the exact pinned Gum version was rejected"
  assert_eq "${CNTOOLS_GUM_BIN}" "${exact}" \
    "exact Gum path discovery"

  CNTOOLS_GUM_BIN="${wrong}"
  assert_fails "a wrong Gum version was accepted" cntools_gum_find
)

run_noninteractive_prerequisite_test() (
  local output=""

  CNTOOLS_GUM_BIN=""
  CNTOOLS_GUM_INSTALL_DIR="${TEST_ROOT}/noninteractive-install"
  cntools_gum_find() { return 1; }
  cntools_gum_log() { return 0; }
  if output="$(cntools_gum_require 2>&1)"; then
    fail "a missing Gum prerequisite was accepted without a terminal"
  fi
  assert_contains "${output}" "automatic installation needs an interactive terminal" \
    "noninteractive prerequisite error"
)

run_archive_member_tests() (
  local case_root="${TEST_ROOT}/archives"
  local release_directory="gum_${CNTOOLS_GUM_REQUIRED_VERSION}_Linux_x86_64"
  local expected_member="${release_directory}/gum"
  local nested="${case_root}/nested.tar.gz"
  local duplicate="${case_root}/duplicate.tar.gz"
  local traversal="${case_root}/traversal.tar.gz"
  local member=""

  mkdir -p "${case_root}/source/${release_directory}" "${case_root}/bad"
  printf '#!/usr/bin/env bash\nexit 0\n' > \
    "${case_root}/source/${release_directory}/gum"
  printf 'not gum\n' > "${case_root}/bad/payload"

  tar -czf "${nested}" -C "${case_root}/source" "${release_directory}"
  member="$(cntools_gum_archive_member "${nested}" "${expected_member}")" ||
    fail "the official nested Gum archive layout was rejected"
  assert_eq "${member}" "${expected_member}" \
    "nested Gum archive member"

  tar -czf "${duplicate}" -C "${case_root}/source" \
    "${expected_member}" "${expected_member}"
  assert_fails "duplicate Gum executable members were accepted" \
    cntools_gum_archive_member "${duplicate}" "${expected_member}"

  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    tar -czf "${traversal}" --transform='s|^|../|' \
      -C "${case_root}/bad" payload
  else
    tar -czf "${traversal}" -s ',^,../,' \
      -C "${case_root}/bad" payload
  fi
  assert_fails "an archive containing a traversal member was accepted" \
    cntools_gum_archive_member "${traversal}" "../payload"
)

run_pinned_checksum_test() (
  local case_root="${TEST_ROOT}/checksum"
  local release_directory="gum_${CNTOOLS_GUM_REQUIRED_VERSION}_Linux_x86_64"
  local archive_name="gum_${CNTOOLS_GUM_REQUIRED_VERSION}_Linux_x86_64.tar.gz"
  local archive_fixture="${case_root}/${archive_name}"
  local checksums_fixture="${case_root}/checksums.txt"
  local actual_digest=""
  local output=""

  mkdir -p "${case_root}/source/${release_directory}" \
    "${case_root}/install" "${case_root}/tmp"
  make_fake_gum "${case_root}/source/${release_directory}/gum" \
    "${CNTOOLS_GUM_REQUIRED_VERSION}"
  tar -czf "${archive_fixture}" -C "${case_root}/source" \
    "${release_directory}"
  actual_digest="$(cntools_gum_sha256 "${archive_fixture}")" ||
    fail "unable to digest the installer fixture"
  printf '%s  %s\n' "${actual_digest}" "${archive_name}" > \
    "${checksums_fixture}"

  curl() {
    local output_path=""
    local url="${!#}"

    while (( $# > 0 )); do
      case "$1" in
        --output)
          output_path="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    [[ -n "${output_path}" ]] || return 2
    if [[ "${url}" == */checksums.txt ]]; then
      cp -- "${checksums_fixture}" "${output_path}"
    else
      cp -- "${archive_fixture}" "${output_path}"
    fi
  }
  uname() {
    case "${1:-}" in
      -s) printf 'Linux\n' ;;
      -m) printf 'x86_64\n' ;;
      *) return 2 ;;
    esac
  }
  cntools_gum_log() { return 0; }
  cntools_log_path_components_safe() { return 0; }

  CNTOOLS_MODE="local"
  CNTOOLS_GUM_BIN=""
  CNTOOLS_GUM_INSTALL_DIR="${case_root}/install"
  CNTOOLS_GUM_SHA256_X86_64="0000000000000000000000000000000000000000000000000000000000000000"
  TMPDIR="${case_root}/tmp"
  if output="$(cntools_gum_install 2>&1)"; then
    fail "an archive that disagrees with the pinned checksum was installed"
  fi
  [[ ! -e "${case_root}/install/gum" ]] ||
    fail "checksum failure activated a Gum executable"
  assert_contains "${output}" "failed checksum verification" \
    "pinned checksum failure"

  CNTOOLS_GUM_SHA256_X86_64="${actual_digest}"
  CNTOOLS_GUM_BIN=""
  cntools_gum_install >/dev/null ||
    fail "a valid pinned Gum archive was not installed"
  [[ -x "${case_root}/install/gum" ]] ||
    fail "a valid Gum archive did not activate its executable"
  cntools_gum_version_exact "${case_root}/install/gum" ||
    fail "the activated Gum executable failed exact-version validation"
  assert_eq "${CNTOOLS_GUM_BIN}" "${case_root}/install/gum" \
    "installed Gum path"
)

run_offline_installer_test() (
  local output=""

  CNTOOLS_MODE="offline"
  cntools_gum_log() { return 0; }
  if output="$(cntools_gum_install 2>&1)"; then
    fail "offline mode allowed Gum to be downloaded"
  fi
  assert_contains "${output}" "unavailable in offline mode" \
    "offline Gum installer boundary"
)

run_filter_presentation_test() (
  local argument_log="${TEST_ROOT}/filter-arguments"
  local selected=""

  cntools_gum() {
    local argument=""

    : > "${argument_log}"
    for argument in "$@"; do
      printf '%s\n' "${argument}" >> "${argument_log}"
    done
    IFS= read -r argument
    printf '%s\n' "${argument}"
  }
  COLUMNS=80
  cntools_gum_filter selected 8 "Wallet" \
    "01  • First" "02  • Second" ||
    fail "the Gum filter wrapper failed with a fake Gum command"
  assert_eq "${selected}" "01  • First" "filter result forwarding"
  for expected in \
    filter --header "Wallet  ·  type to filter" \
    "Filter actions…" "${CNTOOLS_GUM_COLOR_BRAND}" \
    "${CNTOOLS_GUM_COLOR_CANVAS}" "${CNTOOLS_GUM_COLOR_SUCCESS}"; do
    grep -Fx -- "${expected}" "${argument_log}" >/dev/null ||
      fail "Gum filter omitted its Koios-themed argument: ${expected}"
  done
)

run_menu_mapping_test() (
  local fake_root="/fixture/root"
  local fake_submenu="/fixture/root/tools"
  local -a filter_responses=(
    "item:2" "item:3" "item:0" "back" "reload" "unknown" "quit"
  )
  local filter_index=0
  local cache_build_calls=0
  local action_calls=""
  local status_log=""
  local first_duplicate=""
  local second_duplicate=""

  CNTOOLS_MENU_CACHE_READY="Y"
  CNTOOLS_MENU_ROOT_ID="@root"
  CNTOOLS_MENU_CACHE_MENU_DIRS=()
  CNTOOLS_MENU_CACHE_MENU_DIRS["${CNTOOLS_MENU_ROOT_ID}"]="${fake_root}"
  CNTOOLS_UPDATE_STATUS="current"

  cntools_menu_cache_open() {
    local directory="$1"

    CNTOOLS_MENU_NAMES=()
    CNTOOLS_MENU_SHORTCUTS=()
    CNTOOLS_MENU_ORDERS=()
    if [[ "${directory}" == "${fake_root}" ]]; then
      CNTOOLS_MENU_LABEL="CNTools"
      CNTOOLS_MENU_BREADCRUMB="/"
      CNTOOLS_MENU_PATHS=(
        "${fake_submenu}" "${fake_root}/action-a"
        "${fake_root}/action-b" "${fake_root}/disabled"
      )
      CNTOOLS_MENU_IDS=("tools" "action-a" "action-b" "disabled")
      CNTOOLS_MENU_KINDS=("menu" "action" "action" "action")
      CNTOOLS_MENU_LABELS=("Tools" "Run" "Run" "Unavailable")
      CNTOOLS_MENU_DESCRIPTIONS=(
        "Open tools" "Duplicate description" "Duplicate description" "Blocked"
      )
      CNTOOLS_MENU_ENABLED=("Y" "Y" "Y" "N")
      CNTOOLS_MENU_DISABLED_REASONS=("" "" "" "Not available in light mode")
    elif [[ "${directory}" == "${fake_submenu}" ]]; then
      CNTOOLS_MENU_LABEL="Tools"
      CNTOOLS_MENU_BREADCRUMB="/ Tools"
      CNTOOLS_MENU_PATHS=("${fake_submenu}/nested")
      CNTOOLS_MENU_IDS=("tools/nested")
      CNTOOLS_MENU_KINDS=("action")
      CNTOOLS_MENU_LABELS=("Nested")
      CNTOOLS_MENU_DESCRIPTIONS=("Nested action")
      CNTOOLS_MENU_ENABLED=("Y")
      CNTOOLS_MENU_DISABLED_REASONS=("")
    else
      return 1
    fi
  }
  cntools_menu_cache_id_for_directory() {
    if [[ "$1" == "${fake_root}" ]]; then
      printf '%s\n' "${CNTOOLS_MENU_ROOT_ID}"
    else
      printf 'tools\n'
    fi
  }
  cntools_menu_cache_build() {
    cache_build_calls=$((cache_build_calls + 1))
    CNTOOLS_MENU_CACHE_READY="Y"
    return 0
  }
  cntools_gum_filter() {
    local output_variable="$1"
    local token="${filter_responses[filter_index]:-quit}"
    local row=""
    local selected=""
    local wanted=""
    shift 3
    filter_index=$((filter_index + 1))

    case "${token}" in
      item:*)
        wanted="${token#item:}"
        wanted=$((wanted + 1))
        selected="${!wanted:-}"
        ;;
      back)
        for row in "$@"; do
          [[ "${row}" != "← Back" ]] || selected="${row}"
        done
        ;;
      reload)
        for row in "$@"; do
          [[ "${row}" != "↻ Reload menu definitions" ]] || selected="${row}"
        done
        ;;
      quit)
        for row in "$@"; do
          [[ "${row}" != "✕ Quit CNTools" ]] || selected="${row}"
        done
        ;;
      unknown) selected="forged row not offered by Gum" ;;
      *) return 2 ;;
    esac
    [[ -n "${selected}" ]] || return 2
    printf -v "${output_variable}" '%s' "${selected}"
  }
  cntools_action_run() {
    action_calls+="${1}"$'\n'
  }
  cntools_gum_header() { return 0; }
  cntools_gum_log() { return 0; }
  cntools_update_state_load() { return 0; }
  cntools_update_render_summary() { return 0; }
  cntools_startup_deployment_was_started() { return 1; }
  cntools_ui_render_status() {
    status_log+="${1}:${2}"$'\n'
  }

  # Two otherwise identical rows remain unambiguous because their stable
  # menu ordinals are part of the selected value returned by Gum.
  cntools_menu_cache_open "${fake_root}"
  first_duplicate="$(cntools_gum_menu_row 1)"
  second_duplicate="$(cntools_gum_menu_row 2)"
  [[ "${first_duplicate}" != "${second_duplicate}" ]] ||
    fail "duplicate labels produced indistinguishable Gum rows"
  [[ "${first_duplicate}" == 02* && "${second_duplicate}" == 03* ]] ||
    fail "Gum rows do not carry their unique menu ordinal"

  cntools_gum_menu_run || fail "scripted Gum menu navigation failed"
  assert_eq "${action_calls}" "${fake_root}/action-b"$'\n' \
    "Gum menu action dispatch"
  assert_eq "${cache_build_calls}" "1" \
    "manual Gum menu reload count"
  assert_contains "${status_log}" "Not available in light mode" \
    "disabled action feedback"
  assert_contains "${status_log}" "selected row was not recognized" \
    "unknown Gum filter result feedback"
  assert_eq "${filter_index}" "7" \
    "submenu back, reload and unknown-row navigation sequence"
)

run_early_option_tests() (
  local case_root="${TEST_ROOT}/early-options"
  local marker="${case_root}/gum-invoked"
  local help_output=""
  local version_output=""

  mkdir -p "${case_root}/bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf invoked > "${CNTOOLS_TEST_GUM_MARKER}"' \
    'exit 99' > "${case_root}/bin/gum"
  chmod 0755 "${case_root}/bin/gum"

  help_output="$(
    CNTOOLS_TEST_GUM_MARKER="${marker}" \
      PATH="${case_root}/bin:${PATH}" "${BASH}" "${GUM_ENTRYPOINT}" -h
  )" || fail "Gum entrypoint help failed without Gum"
  assert_contains "${help_output}" "Usage: cntools_gum.sh" \
    "Gum entrypoint help"
  [[ ! -e "${marker}" ]] || fail "help invoked Gum"

  version_output="$(
    CNTOOLS_TEST_GUM_MARKER="${marker}" \
      PATH="${case_root}/bin:${PATH}" "${BASH}" "${GUM_ENTRYPOINT}" -v
  )" || fail "Gum entrypoint version failed without Gum"
  [[ "${version_output}" =~ ^[0-9]+[.][0-9]+[.][0-9]+ ]] ||
    fail "Gum entrypoint returned an invalid CNTools version: ${version_output}"
  [[ ! -e "${marker}" ]] || fail "version output invoked Gum"
)

run_discovery_tests
run_noninteractive_prerequisite_test
run_archive_member_tests
run_pinned_checksum_test
run_offline_installer_test
run_filter_presentation_test
run_menu_mapping_test
run_early_option_tests

printf 'CNTools Gum tests passed\n'
