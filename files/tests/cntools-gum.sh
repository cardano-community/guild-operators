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
HEALTH_CORE="${CNTOOLS_ROOT}/core/health.sh"
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

assert_not_contains() {
  local actual="$1"
  local rejected="$2"
  local context="${3:-unexpected text is present}"

  [[ "${actual}" != *"${rejected}"* ]] ||
    fail "${context}: '${rejected}' was found"
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
[[ -f "${HEALTH_CORE}" && ! -L "${HEALTH_CORE}" ]] ||
  fail "Gum health core is missing or unsafe"
[[ -f "${PURE_ENTRYPOINT}" && ! -L "${PURE_ENTRYPOINT}" ]] ||
  fail "pure-Bash entrypoint is missing or unsafe"

bash -n "${GUM_ENTRYPOINT}" "${GUM_CORE}" "${HEALTH_CORE}" \
  "${PURE_ENTRYPOINT}" ||
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
  cntools_gum_archive_member cntools_gum_filter \
  cntools_gum_filter_height cntools_gum_filter_header \
  cntools_gum_capture cntools_gum_header_rows cntools_gum_breadcrumb \
  cntools_gum_menu_run \
  cntools_health_refresh; do
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
  cntools_gum_filter selected 8 \
    "$(cntools_gum_filter_header Wallet 2 N)" \
    "01  • First" "02  • Second" ||
    fail "the Gum filter wrapper failed with a fake Gum command"
  assert_eq "${selected}" "01  • First" "filter result forwarding"
  for expected in \
    filter --header "Wallet  ·  2 options  ·  type to filter" \
    "Filter actions…" "${CNTOOLS_GUM_COLOR_BRAND}" \
    "${CNTOOLS_GUM_COLOR_CANVAS}" "${CNTOOLS_GUM_COLOR_SUCCESS}"; do
    grep -Fx -- "${expected}" "${argument_log}" >/dev/null ||
      fail "Gum filter omitted its Koios-themed argument: ${expected}"
  done
)

run_filter_layout_test() (
  local fake_terminal_lines=22
  local height=""
  local header=""

  cntools_gum_terminal_lines() {
    printf '%s\n' "${fake_terminal_lines}"
  }

  CNTOOLS_MODE="local"
  assert_eq "$(cntools_gum_header_rows)" "6" "online Gum header rows"
  CNTOOLS_MODE="offline"
  assert_eq "$(cntools_gum_header_rows)" "5" "offline Gum header rows"
  CNTOOLS_MODE="local"

  height="$(cntools_gum_filter_height 10 6)" ||
    fail "root menu filter height calculation failed"
  assert_eq "${height}" "15" \
    "root menu height when every option fits"

  fake_terminal_lines=26
  height="$(cntools_gum_filter_height 13 6)" ||
    fail "submenu filter height calculation failed"
  assert_eq "${height}" "19" \
    "submenu height when every option fits"

  fake_terminal_lines=18
  height="$(cntools_gum_filter_height 13 6)" ||
    fail "constrained filter height calculation failed"
  assert_eq "${height}" "11" \
    "submenu height in a constrained terminal"

  fake_terminal_lines=24
  height="$(cntools_gum_filter_height 10 11)" ||
    fail "status-aware filter height calculation failed"
  assert_eq "${height}" "12" \
    "filter height below an additional status block"

  fake_terminal_lines=8
  height="$(cntools_gum_filter_height 10 6)" ||
    fail "minimum filter height calculation failed"
  assert_eq "${height}" "7" \
    "minimum one-option filter height"

  header="$(cntools_gum_filter_header Wallet 13 Y)" ||
    fail "clipped filter header calculation failed"
  assert_eq "${header}" \
    "Wallet  ·  13 options  ·  more below" \
    "clipped filter header"
  assert_eq "$(cntools_gum_filter_header Update 1 N)" \
    "Update  ·  1 option" \
    "single-option filter header"
)

run_menu_mapping_test() (
  local fake_root="/fixture/root"
  local fake_submenu="/fixture/root/tools"
  local -a filter_responses=(
    "item:2" "item:3" "item:0" "back" "unknown" "quit"
  )
  local filter_index=0
  local cache_build_calls=0
  local action_calls=""
  local status_log=""
  local filter_header_log=""
  local first_duplicate=""
  local second_duplicate=""

  CNTOOLS_MENU_CACHE_READY="Y"
  CNTOOLS_MENU_ROOT_ID="@root"
  CNTOOLS_MENU_CACHE_MENU_DIRS=()
  CNTOOLS_MENU_CACHE_MENU_DIRS["${CNTOOLS_MENU_ROOT_ID}"]="${fake_root}"
  CNTOOLS_UPDATE_STATUS="current"
  CNTOOLS_MODE="local"

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
    filter_header_log+="$3"$'\n'
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
  cntools_gum_terminal_lines() { printf '24\n'; }
  cntools_gum_log() { return 0; }
  cntools_health_refresh() { return 0; }
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
  assert_eq "${cache_build_calls}" "0" \
    "Gum menu cache rebuild count"
  assert_contains "${status_log}" "Not available in light mode" \
    "disabled action feedback"
  assert_contains "${status_log}" "selected row was not recognized" \
    "unknown Gum filter result feedback"
  assert_contains "${filter_header_log}" \
    "CNTools  ·  5 options" \
    "root Gum menu option count"
  assert_contains "${filter_header_log}" \
    "Tools  ·  4 options" \
    "submenu Gum menu option count"
  assert_not_contains "${status_log}" "Returned from" \
    "successful Gum action return status"
  assert_eq "${filter_index}" "6" \
    "submenu back and unknown-row navigation sequence"
)

run_header_test() (
  local argument_log="${TEST_ROOT}/header-arguments"
  local line=""
  local simulated_render_rows=0

  unset NO_COLOR

  cntools_gum_clear() { return 0; }
  cntools_gum() {
    local command_name="${1:-}"
    local foreground=""
    local bold="N"
    local text_value="${!#}"
    local argument=""
    local previous=""
    local outer_style="N"

    if [[ "${command_name}" == "style" || "${command_name}" == "join" ]]; then
      [[ "${CLICOLOR_FORCE:-}" == "1" ]] || return 98
    fi

    for argument in "$@"; do
      if [[ "${previous}" == "--foreground" ]]; then
        foreground="${argument}"
      fi
      [[ "${argument}" != "--bold" ]] || bold="Y"
      [[ "${argument}" != "--no-strip-ansi" ]] || outer_style="Y"
      previous="${argument}"
    done
    if [[ "${command_name}" == "style" ]]; then
      printf 'style\t%s\t%s\t%s\n' \
        "${foreground}" "${bold}" "${text_value}" >> "${argument_log}"
      if [[ "${outer_style}" == "Y" && ${simulated_render_rows} -gt 0 ]]; then
        for ((line = 1; line <= simulated_render_rows; line++)); do
          printf 'rendered row %s\n' "${line}"
        done
      else
        printf '%s' "${text_value}"
      fi
    elif [[ "${command_name}" == "join" ]]; then
      shift 2
      printf '%s' "$@"
    else
      return 2
    fi
  }

  COLUMNS=100
  CNTOOLS_VERSION="14.0.0"
  CNTOOLS_MODE="local"
  CNTOOLS_BACKEND="cnode"
  CNTOOLS_NETWORK="preprod"
  CNTOOLS_UI_UTF8="Y"
  CNTOOLS_HEALTH_TEXT="Epoch 230  ·  Tip #456  ·  Gap 2 slots"
  CNTOOLS_HEALTH_TONE="success"
  : > "${argument_log}"
  cntools_gum_header "/ Update / View Changes" >/dev/null ||
    fail "nested Gum header rendering failed"
  grep -F $'style\t#98989F\tN\t/ Update / ' \
    "${argument_log}" >/dev/null ||
    fail "Gum breadcrumb parent was not muted"
  grep -F $'style\t#4FBC85\tY\tView Changes' \
    "${argument_log}" >/dev/null ||
    fail "Gum breadcrumb leaf was not highlighted"
  grep -F $'style\t#98989F\tN\tlocal · cnode · preprod' \
    "${argument_log}" >/dev/null ||
    fail "Gum runtime row was not compact"
  if grep -E $'\t(Mode|Backend|Network) ' "${argument_log}" >/dev/null; then
    fail "Gum runtime row retained redundant labels"
  fi
  grep -F $'style\t#3DD68C\tN\tEpoch 230  ·  Tip #456  ·  Gap 2 slots' \
    "${argument_log}" >/dev/null ||
    fail "Gum health row was not rendered with its health color"

  simulated_render_rows=7
  cntools_gum_header "/ Wallet / Register" >/dev/null ||
    fail "wrapped Gum header rendering failed"
  assert_eq "$(cntools_gum_header_rows)" "7" \
    "wrapped Gum header row count"
  simulated_render_rows=0

  CNTOOLS_MODE="offline"
  CNTOOLS_BACKEND="none"
  CNTOOLS_HEALTH_TEXT=""
  : > "${argument_log}"
  cntools_gum_header "/" >/dev/null ||
    fail "offline Gum header rendering failed"
  grep -F $'style\t#4FBC85\tY\t/' "${argument_log}" >/dev/null ||
    fail "root breadcrumb was not highlighted"
  grep -F $'style\t#98989F\tN\toffline · none · preprod' \
    "${argument_log}" >/dev/null ||
    fail "offline Gum runtime row was not compact"
  if grep -F 'node offline' "${argument_log}" >/dev/null; then
    fail "explicit offline mode rendered a duplicate health message"
  fi
)

run_color_capture_preference_test() (
  local capture_state=""

  cntools_gum() {
    printf '%s\n' "${CLICOLOR_FORCE-unset}"
  }
  unset CLICOLOR_FORCE NO_COLOR
  capture_state="$(cntools_gum_capture style leaf)" ||
    fail "forced-color Gum capture failed"
  assert_eq "${capture_state}" "1" \
    "Gum composed-color capture"

  NO_COLOR=""
  capture_state="$(cntools_gum_capture style leaf)" ||
    fail "empty NO_COLOR Gum capture failed"
  assert_eq "${capture_state}" "1" \
    "Gum empty NO_COLOR capture preference"

  NO_COLOR=1
  capture_state="$(cntools_gum_capture style leaf)" ||
    fail "NO_COLOR Gum capture failed"
  assert_eq "${capture_state}" "unset" \
    "Gum NO_COLOR capture preference"
)

run_wait_and_placeholder_test() (
  local argument_log="${TEST_ROOT}/wait-arguments"
  local output=""

  cntools_gum() {
    printf '%s\n' "$@" >> "${argument_log}"
  }
  CNTOOLS_UI_INTERACTIVE="Y"
  : > "${argument_log}"
  cntools_ui_wait
  grep -Fx -- '--no-show-help' "${argument_log}" >/dev/null ||
    fail "Gum return prompt retained its redundant key help"
  grep -Fx -- 'Press Enter to return…' "${argument_log}" >/dev/null ||
    fail "Gum return prompt lost its concise instruction"

  # shellcheck source=/dev/null
  . "${CNTOOLS_ROOT}/lib/placeholder.sh"
  CNTOOLS_ACTION_ID="wallet/new"
  CNTOOLS_ACTION_LABEL="New"
  CNTOOLS_MODULE_ROOT="${CNTOOLS_ROOT}/modules/root"
  CNTOOLS_UI_DRIVER="gum"
  CNTOOLS_UI_INTERACTIVE="Y"
  cntools_menu_breadcrumb() { printf '/ Wallet / New\n'; }
  cntools_log() { return 0; }
  cntools_ui_render_begin() { return 0; }
  cntools_ui_render_status() { printf '%s\n' "$2"; }
  cntools_ui_read_key() { printf -v "$1" '%s' enter; }
  output="$(cntools_action_placeholder)" ||
    fail "Gum placeholder action failed"
  assert_contains "${output}" "Not implemented yet" \
    "Gum placeholder content"
  assert_not_contains "${output}" $'\nNew\n' \
    "duplicate Gum leaf title"
  assert_not_contains "${output}" "Press any key to return" \
    "duplicate Gum return instruction"
)

run_health_test() (
  local request_marker="${TEST_ROOT}/offline-health-requested"
  local fetch_trace="${TEST_ROOT}/health-fetch.trace"
  local cache_error="${TEST_ROOT}/health-cache.error"
  local custom_config="${TEST_ROOT}/custom-cnode-config.json"

  cntools_log() { return 0; }
  CNTOOLS_HEALTH_CACHE_SECONDS=5
  CNTOOLS_MODE="offline"
  cntools_health_fetch_local() { : > "${request_marker}"; return 1; }
  cntools_health_fetch_koios() { : > "${request_marker}"; return 1; }
  cntools_health_refresh Y
  assert_eq "${CNTOOLS_HEALTH_TEXT}" "" "offline health text"
  assert_eq "${CNTOOLS_HEALTH_TONE}" "quiet" "offline health tone"
  [[ ! -e "${request_marker}" ]] ||
    fail "offline mode attempted a health request"

  CNTOOLS_MODE="local"
  CNTOOLS_NETWORK="preprod"
  CNTOOLS_IMPLEMENTATION="cnode"
  printf '%s\n' \
    '{"TraceOptions":{"":{"backends":["PrometheusSimple suffix 127.0.0.9 19090"]}}}' \
    > "${custom_config}"
  CNTOOLS_CONFIG="${custom_config}"
  assert_eq "$(cntools_health_cnode_metrics_url)" \
    "http://127.0.0.9:19090/metrics" \
    "custom cnode configuration metrics URL"
  assert_eq "$(cntools_health_prometheus_value \
    'cardano_node_metrics_blockNum_int{network="preprod"} 456 # {trace_id="abc"} 999' \
    cardano_node_metrics_blockNum_int)" "456" \
    "OpenMetrics exemplar sample parsing"
  assert_eq "$(cntools_health_prometheus_value \
    'cardano_node_metrics_blockNum_int 457 # {trace_id="def"} 998' \
    cardano_node_metrics_blockNum_int)" "457" \
    "unlabelled OpenMetrics exemplar sample parsing"
  cntools_health_local_metrics_url() { printf 'http://127.0.0.1:12798/metrics\n'; }
  cntools_health_reference_slot() { printf '1000\n'; }
  cntools_health_fetch_local() {
    printf '%s\n' \
      'cardano_node_metrics_epoch_int 230' \
      'cardano_node_metrics_blockNum_int 456' \
      'cardano_node_metrics_slotNum_int 9.90e+02'
  }
  cntools_health_refresh Y
  assert_eq "${CNTOOLS_HEALTH_TEXT}" \
    "Epoch 230  ·  Tip #456  ·  Gap 10 slots" \
    "local health snapshot"
  assert_eq "${CNTOOLS_HEALTH_TONE}" "success" \
    "local healthy tone"

  cntools_health_fetch_local() {
    printf '%s\n' \
      'cardano_node_metrics_epoch_int 230' \
      'cardano_node_metrics_blockNum_int 457' \
      'cardano_node_metrics_slotNum_int 999' \
      'dingo_tip_gap_slots 42'
  }
  cntools_health_refresh Y
  assert_contains "${CNTOOLS_HEALTH_TEXT}" "Gap 42 slots" \
    "native local tip gap"
  assert_eq "${CNTOOLS_HEALTH_TONE}" "warning" \
    "lagging local health tone"

  cntools_health_fetch_local() { return 7; }
  cntools_health_refresh Y
  assert_eq "${CNTOOLS_HEALTH_TEXT}" "node offline" \
    "unreachable local health text"
  assert_eq "${CNTOOLS_HEALTH_TONE}" "danger" \
    "unreachable local health tone"

  CNTOOLS_MODE="light"
  cntools_health_fetch_koios() {
    printf '%s\n' \
      '[{"epoch_no":230,"abs_slot":995,"block_height":800,"block_time":999}]'
  }
  cntools_health_refresh Y
  assert_eq "${CNTOOLS_HEALTH_TEXT}" \
    "Epoch 230  ·  Tip #800  ·  Gap 5 slots" \
    "Koios health snapshot"

  cntools_health_fetch_koios() {
    printf '%s\n' \
      '[{"epoch_no":230,"abs_slot":999,"block_no":799,"block_time":999}]'
  }
  cntools_health_refresh Y
  assert_contains "${CNTOOLS_HEALTH_TEXT}" "Tip #799" \
    "legacy Koios block number fallback"

  cntools_health_fetch_koios() { printf '%s\n' '[{"epoch_no":"bad"}]'; }
  cntools_health_refresh Y
  assert_eq "${CNTOOLS_HEALTH_TEXT}" "node offline" \
    "malformed Koios health text"

  CNTOOLS_MODE="local"
  FAKE_HEALTH_NOW=100
  : > "${fetch_trace}"
  cntools_health_now() { printf '%s\n' "${FAKE_HEALTH_NOW}"; }
  cntools_health_fetch_local() {
    printf 'fetch\n' >> "${fetch_trace}"
    printf '%s\n' \
      'cardano_node_metrics_epoch_int 230' \
      'cardano_node_metrics_blockNum_int 456' \
      'cardano_node_metrics_slotNum_int 990'
  }
  cntools_health_refresh Y
  cntools_health_refresh
  FAKE_HEALTH_NOW=106
  cntools_health_refresh
  assert_eq "$(wc -l < "${fetch_trace}" | tr -d ' ')" "2" \
    "health cache request count"

  : > "${fetch_trace}"
  CNTOOLS_HEALTH_CACHE_SECONDS=08
  CNTOOLS_HEALTH_LAST_REFRESH=007
  FAKE_HEALTH_NOW=008
  cntools_health_refresh 2> "${cache_error}"
  [[ ! -s "${cache_error}" ]] ||
    fail "leading-zero health cache values produced an arithmetic error"
  [[ ! -s "${fetch_trace}" ]] ||
    fail "leading-zero health cache values bypassed the cache"
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
run_filter_layout_test
run_menu_mapping_test
run_header_test
run_color_capture_preference_test
run_wait_and_placeholder_test
run_health_test
run_early_option_tests

printf 'CNTools Gum tests passed\n'
