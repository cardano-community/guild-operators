#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools main tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
MAIN_ENTRYPOINT="${CNTOOLS_ROOT}/cntools_main.sh"
GUM_CORE="${CNTOOLS_ROOT}/core/gum.sh"
HEALTH_CORE="${CNTOOLS_ROOT}/core/health.sh"
THEME_CORE="${CNTOOLS_ROOT}/core/theme.sh"
SETTINGS_CORE="${CNTOOLS_ROOT}/core/settings.sh"
NUMBER_LIBRARY="${CNTOOLS_ROOT}/lib/number.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-main.XXXXXX")"
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

for required_command in bash chmod cp find grep mktemp mkdir rm tar wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

[[ -f "${MAIN_ENTRYPOINT}" && ! -L "${MAIN_ENTRYPOINT}" ]] ||
  fail "CNTools main entrypoint is missing or unsafe"
[[ -f "${GUM_CORE}" && ! -L "${GUM_CORE}" ]] ||
  fail "Gum UI core is missing or unsafe"
[[ -f "${HEALTH_CORE}" && ! -L "${HEALTH_CORE}" ]] ||
  fail "Gum health core is missing or unsafe"
[[ -f "${THEME_CORE}" && ! -L "${THEME_CORE}" ]] ||
  fail "CNTools theme core is missing or unsafe"
[[ -f "${SETTINGS_CORE}" && ! -L "${SETTINGS_CORE}" ]] ||
  fail "CNTools settings core is missing or unsafe"
[[ -f "${NUMBER_LIBRARY}" && ! -L "${NUMBER_LIBRARY}" ]] ||
  fail "CNTools number library is missing or unsafe"
bash -n "${MAIN_ENTRYPOINT}" "${GUM_CORE}" "${HEALTH_CORE}" \
  "${THEME_CORE}" "${SETTINGS_CORE}" "${NUMBER_LIBRARY}" ||
  fail "the CNTools main entrypoint or Gum-owned core has invalid Bash syntax"
for retired_path in \
  "${CNTOOLS_ROOT}/cntools.sh" \
  "${CNTOOLS_ROOT}/cntools_gum.sh" \
  "${CNTOOLS_ROOT}/core/ui.sh"; do
  [[ ! -e "${retired_path}" && ! -L "${retired_path}" ]] ||
    fail "retired CNTools UI file is still present: ${retired_path}"
done

# Loading the sole entrypoint must define the Gum driver without invoking its
# main function.
# shellcheck source=/dev/null
. "${MAIN_ENTRYPOINT}" || fail "unable to source the CNTools main entrypoint"
declare -F cntools_main >/dev/null 2>&1 ||
  fail "CNTools main function is missing"
assert_eq "${CNTOOLS_ENTRYPOINT}" "${MAIN_ENTRYPOINT}" \
  "CNTools main entrypoint identity"
for required_function in \
  cntools_gum_find cntools_gum_require cntools_gum_install \
  cntools_gum_archive_member cntools_gum_filter \
  cntools_gum_filter_height \
  cntools_gum_capture cntools_gum_header_rows cntools_gum_breadcrumb \
  cntools_gum_menu_run cntools_ui_choose cntools_ui_password cntools_ui_static_table \
  cntools_ui_spin_function cntools_ui_content_width \
  cntools_health_refresh cntools_theme_init cntools_theme_save \
  cntools_number_format_into; do
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

run_spin_function_test() (
  local case_root="${TEST_ROOT}/spin-function"
  local argument_log="${case_root}/gum-arguments"
  local callback_value="pending"
  local callback_status=0

  mkdir -p "${case_root}"
  CNTOOLS_TMP_DIR="${case_root}"
  cntools_gum() {
    local command_name="${1:-}"
    shift || true

    printf '%s\n' "${command_name}" "$@" >> "${argument_log}"
    [[ "${command_name}" == "spin" ]] || return 2
    while (( $# > 0 )); do
      if [[ "$1" == "--" ]]; then
        shift
        "$@"
        return $?
      fi
      shift
    done
    return 2
  }
  prepare_fixture_state() {
    callback_value="prepared"
  }
  fail_fixture_state() {
    callback_value="failed"
    return 7
  }

  : > "${argument_log}"
  cntools_ui_spin_function "Fetching fixture balances…" \
    prepare_fixture_state || fail "same-shell Gum spinner failed"
  assert_eq "${callback_value}" "prepared" \
    "same-shell spinner callback state"
  grep -Fx -- 'spin' "${argument_log}" >/dev/null ||
    fail "same-shell spinner did not invoke Gum spin"
  grep -Fx -- 'Fetching fixture balances…' "${argument_log}" >/dev/null ||
    fail "same-shell spinner lost its title"
  [[ -z "$(find "${case_root}" -name '.cntools-spin.*' -print)" ]] ||
    fail "same-shell spinner left its completion marker"

  if cntools_ui_spin_function "Failing fixture…" fail_fixture_state; then
    fail "same-shell spinner discarded a callback failure"
  else
    callback_status=$?
  fi
  assert_eq "${callback_status}" "7" \
    "same-shell spinner callback status"
  assert_eq "${callback_value}" "failed" \
    "failed same-shell spinner callback state"
  [[ -z "$(find "${case_root}" -name '.cntools-spin.*' -print)" ]] ||
    fail "failed same-shell spinner left its completion marker"

  callback_value="pending"
  CNTOOLS_TMP_DIR="${case_root}/missing"
  assert_fails "same-shell spinner accepted a missing temp directory" \
    cntools_ui_spin_function "Invalid fixture…" prepare_fixture_state
  assert_eq "${callback_value}" "pending" \
    "invalid same-shell spinner ran its callback"
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
    "01  • First" "02  • Second" ||
    fail "the Gum filter wrapper failed with a fake Gum command"
  assert_eq "${selected}" "01  • First" "filter result forwarding"
  for expected in \
    filter "0 2 1 2" "Filter actions…" "${CNTOOLS_GUM_COLOR_BRAND}" \
    "${CNTOOLS_GUM_COLOR_CANVAS}" "${CNTOOLS_GUM_COLOR_SUCCESS}"; do
    grep -Fx -- "${expected}" "${argument_log}" >/dev/null ||
      fail "Gum filter omitted its Koios-themed argument: ${expected}"
  done
  if grep -E '^--header([.]foreground)?$|type to filter' \
      "${argument_log}" >/dev/null; then
    fail "Gum filter retained its redundant menu heading"
  fi
)

run_action_choice_helper_test() (
  local argument_log="${TEST_ROOT}/choice-helper-arguments"
  local fake_terminal_lines=18
  local gum_status=0
  local selected_height=""
  local previous_argument=""
  local argument=""
  local value="sentinel"
  local status=0
  local -a choices=()

  for (( status = 1; status <= 13; status++ )); do
    choices+=("Choice ${status}")
  done
  cntools_gum_terminal_lines() {
    printf '%s\n' "${fake_terminal_lines}"
  }
  cntools_gum_header_rows() {
    printf '6\n'
  }
  cntools_gum() {
    : > "${argument_log}"
    printf '%s\n' "$@" > "${argument_log}"
    (( gum_status == 0 )) || return "${gum_status}"
    IFS= read -r argument
    printf '%s\n' "${argument}"
  }

  cntools_ui_choose value "Filter wallets…" "${choices[@]}" ||
    fail "the reusable action selector rejected a valid choice"
  assert_eq "${value}" "Choice 1" \
    "action selector output-variable collision"
  while IFS= read -r argument; do
    if [[ "${previous_argument}" == "--height" ]]; then
      selected_height="${argument}"
      break
    fi
    previous_argument="${argument}"
  done < "${argument_log}"
  assert_eq "${selected_height}" "13" \
    "action selector terminal-aware height"

  gum_status=1
  value="sentinel"
  if cntools_ui_choose value "Filter wallets…" "${choices[@]}"; then
    fail "the reusable action selector discarded Gum cancellation"
  else
    status=$?
  fi
  assert_eq "${status}" "1" "action selector cancellation status"
  assert_eq "${value}" "" "action selector cancellation output"
)

run_filter_layout_test() (
  local fake_terminal_lines=22
  local height=""

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
  assert_eq "${height}" "14" \
    "root menu height when every option fits"

  fake_terminal_lines=26
  height="$(cntools_gum_filter_height 13 6)" ||
    fail "submenu filter height calculation failed"
  assert_eq "${height}" "17" \
    "submenu height when every option fits"

  fake_terminal_lines=18
  height="$(cntools_gum_filter_height 13 6)" ||
    fail "constrained filter height calculation failed"
  assert_eq "${height}" "13" \
    "submenu height in a constrained terminal"

  fake_terminal_lines=24
  height="$(cntools_gum_filter_height 10 10)" ||
    fail "status-aware filter height calculation failed"
  assert_eq "${height}" "14" \
    "filter height below an additional status block"

  height="$(cntools_gum_filter_height 10 11)" ||
    fail "update-summary-aware filter height calculation failed"
  assert_eq "${height}" "14" \
    "filter height below the Update summary"

  fake_terminal_lines=8
  height="$(cntools_gum_filter_height 10 6)" ||
    fail "minimum filter height calculation failed"
  assert_eq "${height}" "5" \
    "minimum one-option filter height"
)

run_status_spacing_test() (
  local argument_log="${TEST_ROOT}/status-spacing-arguments"

  cntools_gum() {
    printf '%s\n' "$@" >> "${argument_log}"
  }
  : > "${argument_log}"
  cntools_ui_render_status warn "Spacing check" >/dev/null ||
    fail "Gum status rendering failed"
  grep -Fx -- '0 2 1 2' "${argument_log}" >/dev/null ||
    fail "Gum status retained a blank row above its content"
  assert_eq "${CNTOOLS_GUM_STATUS_ROWS}" "4" \
    "Gum compact status row accounting"
  assert_eq "${CNTOOLS_GUM_UPDATE_SUMMARY_ROWS}" "5" \
    "Gum Update summary row accounting"
)

run_static_table_style_test() (
  local argument_log="${TEST_ROOT}/static-table-style-arguments"
  local detail_log="${TEST_ROOT}/static-table-detail-arguments"
  local color_force_log="${TEST_ROOT}/static-table-color-force"

  unset CLICOLOR_FORCE NO_COLOR
  : > "${color_force_log}"

  cntools_gum() {
    local command_name="${1:-}"
    shift || true

    case "${command_name}" in
      table)
        printf '%s:%s\n' \
          "${CLICOLOR_FORCE-unset}" "${NO_COLOR-unset}" \
          >> "${color_force_log}"
        printf '%s\n' "${command_name}" "$@" > "${argument_log}"
        while IFS= read -r _; do :; done
        ;;
      style)
        printf '%s\n' "${command_name}" "$@" > "${detail_log}"
        ;;
      *) return 2 ;;
    esac
  }

  : > "${argument_log}"
  : > "${detail_log}"
  printf 'Property\tValue\nName\tFixture\n' | cntools_ui_table \
    --separator $'\t' >/dev/null ||
    fail "the static Gum table wrapper failed"
  for expected in \
    table --print --no-show-help \
    --header.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
    --header.background "${CNTOOLS_GUM_COLOR_CANVAS}" \
    --cell.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
    --cell.background "${CNTOOLS_GUM_COLOR_CANVAS}" \
    --selected.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
    --selected.background "${CNTOOLS_GUM_COLOR_CANVAS}"; do
    grep -Fx -- "${expected}" "${argument_log}" >/dev/null ||
      fail "static Gum table omitted its neutral style: ${expected}"
  done
  if grep -Fx -- "${CNTOOLS_GUM_COLOR_BRAND}" "${argument_log}" >/dev/null ||
     grep -Fx -- "${CNTOOLS_GUM_COLOR_SURFACE}" "${argument_log}" >/dev/null ||
     grep -Fx -- '--header.bold' "${argument_log}" >/dev/null; then
    fail "static Gum table can still apply brand color to its first data row"
  fi

  cntools_ui_render_detail "Wallet" >/dev/null ||
    fail "the Gum detail heading failed"
  grep -Fx -- "${CNTOOLS_GUM_COLOR_BRAND}" "${detail_log}" >/dev/null ||
    fail "the table section heading did not retain the Koios accent"
  grep -Fx -- '--bold' "${detail_log}" >/dev/null ||
    fail "the table section heading is not visually distinct"

  CLICOLOR_FORCE=1
  NO_COLOR=1
  printf 'Property\tValue\nName\tFixture\n' | cntools_ui_table \
    --separator $'\t' >/dev/null ||
    fail "the NO_COLOR static Gum table wrapper failed"
  assert_eq "$(< "${color_force_log}")" $'1:unset\n:1' \
    "static Gum table ANSI preservation"
)

run_menu_mapping_test() (
  local fake_root="/fixture/root"
  local fake_submenu="/fixture/root/tools"
  local -a filter_responses=(
    "item:2" "item:1" "item:3" "item:0" "cancel" "unknown" "cancel" "quit"
  )
  local filter_index=0
  local cache_build_calls=0
  local clear_calls=0
  local health_root_calls=0
  local health_submenu_calls=0
  local theme_reload_calls=0
  local settings_reload_calls=0
  local action_calls=""
  local status_log=""
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
      CNTOOLS_MENU_IDS=("tools" "settings/transaction-defaults" "settings/theme" "disabled")
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
    shift 2
    filter_index=$((filter_index + 1))

    case "${token}" in
      item:*)
        wanted="${token#item:}"
        wanted=$((wanted + 1))
        selected="${!wanted:-}"
        ;;
      cancel) return 1 ;;
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
  cntools_gum_clear() { clear_calls=$((clear_calls + 1)); }
  cntools_gum_terminal_lines() { printf '24\n'; }
  cntools_gum_log() { return 0; }
  cntools_health_refresh() {
    if [[ "${CNTOOLS_MENU_ID:-}" == "/" ]]; then
      health_root_calls=$((health_root_calls + 1))
    else
      health_submenu_calls=$((health_submenu_calls + 1))
    fi
  }
  cntools_update_state_load() { return 0; }
  cntools_update_render_summary() { return 0; }
  cntools_startup_deployment_was_started() { return 1; }
  cntools_theme_reload() { theme_reload_calls=$((theme_reload_calls + 1)); }
  cntools_settings_reload() {
    settings_reload_calls=$((settings_reload_calls + 1))
  }
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
  assert_eq "${action_calls}" \
    "${fake_root}/action-b"$'\n'"${fake_root}/action-a"$'\n' \
    "Gum menu action dispatch"
  assert_eq "${cache_build_calls}" "0" \
    "Gum menu cache rebuild count"
  assert_contains "${status_log}" "Not available in light mode" \
    "disabled action feedback"
  assert_contains "${status_log}" "selected row was not recognized" \
    "unknown Gum filter result feedback"
  assert_not_contains "${status_log}" "Returned from" \
    "successful Gum action return status"
  assert_eq "${filter_index}" "8" \
    "submenu and root Escape cancellation sequence"
  assert_eq "${clear_calls}" "2" \
    "transient Gum cancellation cleanup"
  assert_eq "${health_root_calls}" "7" \
    "root-only health refresh"
  assert_eq "${health_submenu_calls}" "0" \
    "submenu health refresh"
  assert_eq "${theme_reload_calls}" "1" \
    "Theme action parent-session reload"
  assert_eq "${settings_reload_calls}" "1" \
    "Transaction Defaults parent-session reload"
)

run_menu_filter_status_test() {
  local requested_status="$1"
  local expected_status="$2"
  local expected_log="$3"
  local case_output=""
  local case_status=0
  local log_trace=""
  local fake_root="/fixture/status-root"

  (
    CNTOOLS_MENU_CACHE_READY="Y"
    CNTOOLS_MENU_ROOT_ID="@root"
    CNTOOLS_MENU_CACHE_MENU_DIRS=()
    CNTOOLS_MENU_CACHE_MENU_DIRS["${CNTOOLS_MENU_ROOT_ID}"]="${fake_root}"
    CNTOOLS_UPDATE_STATUS="current"
    CNTOOLS_MODE="local"

    cntools_menu_cache_open() {
      CNTOOLS_MENU_LABEL="CNTools"
      CNTOOLS_MENU_BREADCRUMB="/"
      CNTOOLS_MENU_PATHS=("${fake_root}/action")
      CNTOOLS_MENU_IDS=("action")
      CNTOOLS_MENU_KINDS=("action")
      CNTOOLS_MENU_LABELS=("Action")
      CNTOOLS_MENU_DESCRIPTIONS=("Test action")
      CNTOOLS_MENU_ENABLED=("Y")
      CNTOOLS_MENU_DISABLED_REASONS=("")
    }
    cntools_menu_cache_id_for_directory() {
      printf '%s\n' "${CNTOOLS_MENU_ROOT_ID}"
    }
    cntools_gum_filter() { return "${requested_status}"; }
    cntools_gum_header() { return 0; }
    cntools_gum_header_rows() { printf '6\n'; }
    cntools_gum_terminal_lines() { printf '24\n'; }
    cntools_health_refresh() { return 0; }
    cntools_update_state_load() { return 0; }
    cntools_gum_log() { printf '%s:%s\n' "$1" "$2" >&3; }

    cntools_gum_menu_run
  ) 3> "${TEST_ROOT}/menu-status.log" \
      > "${TEST_ROOT}/menu-status.out" 2>&1 || case_status=$?
  case_output="$(< "${TEST_ROOT}/menu-status.out")"
  log_trace="$(< "${TEST_ROOT}/menu-status.log")"
  assert_eq "${case_status}" "${expected_status}" \
    "Gum filter status ${requested_status} routing"
  assert_contains "${log_trace}" "${expected_log}" \
    "Gum filter status ${requested_status} log"
  if (( requested_status == 130 )); then
    assert_not_contains "${case_output}" "selection failed" \
      "Ctrl+C Gum interruption diagnostic"
  else
    assert_contains "${case_output}" "selection failed (status 2)" \
      "unexpected Gum filter failure diagnostic"
  fi
}

run_header_test() (
  local argument_log="${TEST_ROOT}/header-arguments"
  local line=""
  local simulated_render_rows=0

  unset NO_COLOR

  cntools_gum_clear() { return 0; }
  cntools_gum() {
    local command_name="${1:-}"
    local foreground=""
    local background=""
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
      elif [[ "${previous}" == "--background" ]]; then
        background="${argument}"
      fi
      [[ "${argument}" != "--bold" ]] || bold="Y"
      [[ "${argument}" != "--no-strip-ansi" ]] || outer_style="Y"
      previous="${argument}"
    done
    if [[ "${command_name}" == "style" ]]; then
      printf 'style\t%s\t%s\t%s\t%s\n' \
        "${foreground}" "${background}" "${bold}" "${text_value}" \
        >> "${argument_log}"
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
  grep -F $'style\t#98989F\t#202127\tN\t/ Update / ' \
    "${argument_log}" >/dev/null ||
    fail "Gum breadcrumb parent was not muted"
  grep -F $'style\t#4FBC85\t#202127\tY\tView Changes' \
    "${argument_log}" >/dev/null ||
    fail "Gum breadcrumb leaf was not highlighted"
  grep -F $'style\t#98989F\t#202127\tN\tlocal · cnode · preprod' \
    "${argument_log}" >/dev/null ||
    fail "Gum runtime row was not compact"
  if grep -E $'\t(Mode|Backend|Network) ' "${argument_log}" >/dev/null; then
    fail "Gum runtime row retained redundant labels"
  fi
  if grep -F 'Epoch 230  ·  Tip #456  ·  Gap 2 slots' \
      "${argument_log}" >/dev/null; then
    fail "nested Gum header rendered root-only health data"
  fi
  grep -F $'style\t\t#202127\tN\t ' "${argument_log}" >/dev/null ||
    fail "Gum title separator did not inherit the info-header surface"

  : > "${argument_log}"
  CNTOOLS_MENU_ID="/"
  cntools_gum_header "/" >/dev/null ||
    fail "online root Gum header rendering failed"
  grep -F $'style\t#3DD68C\t#202127\tN\tEpoch 230  ·  Tip #456  ·  Gap 2 slots' \
    "${argument_log}" >/dev/null ||
    fail "root Gum health row was not rendered with its health color"

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
  grep -F $'style\t#4FBC85\t#202127\tY\t/' "${argument_log}" >/dev/null ||
    fail "root breadcrumb was not highlighted"
  grep -F $'style\t#98989F\t#202127\tN\tOffline' \
    "${argument_log}" >/dev/null ||
    fail "offline Gum runtime row was not compact"
  if grep -F 'node offline' "${argument_log}" >/dev/null; then
    fail "explicit offline mode rendered a duplicate health message"
  fi
)

run_color_capture_preference_test() (
  local capture_state=""

  cntools_gum() {
    printf '%s:%s\n' \
      "${CLICOLOR_FORCE-unset}" "${NO_COLOR-unset}"
  }
  unset CLICOLOR_FORCE NO_COLOR
  capture_state="$(cntools_gum_capture style leaf)" ||
    fail "forced-color Gum capture failed"
  assert_eq "${capture_state}" "1:unset" \
    "Gum composed-color capture"

  NO_COLOR=""
  capture_state="$(cntools_gum_capture style leaf)" ||
    fail "empty NO_COLOR Gum capture failed"
  assert_eq "${capture_state}" "1:" \
    "Gum empty NO_COLOR capture preference"

  NO_COLOR=1
  CLICOLOR_FORCE=1
  capture_state="$(cntools_gum_capture style leaf)" ||
    fail "NO_COLOR Gum capture failed"
  assert_eq "${capture_state}" ":1" \
    "Gum NO_COLOR capture preference"
)

run_wait_and_placeholder_test() (
  local argument_log="${TEST_ROOT}/wait-arguments"
  local wait_output="${TEST_ROOT}/wait-output"
  local output=""

  cntools_gum() {
    printf '%s\n' "$@" >> "${argument_log}"
  }
  CNTOOLS_UI_INTERACTIVE="Y"
  : > "${argument_log}"
  cntools_ui_wait > "${wait_output}"
  assert_eq "$(wc -c < "${wait_output}" | tr -d ' ')" "1" \
    "blank line before Gum return prompt"
  grep -Fx -- '--no-show-help' "${argument_log}" >/dev/null ||
    fail "Gum return prompt retained its redundant key help"
  grep -Fx -- 'Press Enter to return…' "${argument_log}" >/dev/null ||
    fail "Gum return prompt lost its concise instruction"

  # shellcheck source=/dev/null
  . "${CNTOOLS_ROOT}/lib/placeholder.sh"
  CNTOOLS_ACTION_ID="wallet/new"
  CNTOOLS_ACTION_LABEL="New"
  CNTOOLS_MODULE_ROOT="${CNTOOLS_ROOT}/modules/root"
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

  cntools_health_set_online 1403 4611829 1234 ||
    fail "grouped health snapshot could not be prepared"
  assert_eq "${CNTOOLS_HEALTH_TEXT}" \
    "Epoch 1,403  ·  Tip #4,611,829  ·  Gap 1,234 slots" \
    "grouped health snapshot"
  cntools_health_set_online 1403 4611829 1 ||
    fail "singular health snapshot could not be prepared"
  assert_eq "${CNTOOLS_HEALTH_TEXT}" \
    "Epoch 1,403  ·  Tip #4,611,829  ·  Gap 1 slot" \
    "singular grouped health snapshot"

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
  assert_eq "${CNTOOLS_HEALTH_TONE}" "success" \
    "healthy local health tone"

  assert_eq "$(cntools_health_tone_for_gap 0)" "success" \
    "zero-gap health tone"
  assert_eq "$(cntools_health_tone_for_gap 120)" "success" \
    "green health boundary"
  assert_eq "$(cntools_health_tone_for_gap 121)" "warning" \
    "warning health lower boundary"
  assert_eq "$(cntools_health_tone_for_gap 600)" "warning" \
    "warning health upper boundary"
  assert_eq "$(cntools_health_tone_for_gap 601)" "danger" \
    "danger health boundary"

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

run_content_width_test() (
  local test_terminal_columns=162

  CNTOOLS_UI_INTERACTIVE="Y"
  tput() {
    [[ "${1:-}" == "cols" ]] || return 1
    printf '%s\n' "${test_terminal_columns}"
  }
  assert_eq "$(cntools_ui_content_width)" "160" \
    "wide content terminal width"
  test_terminal_columns=240
  assert_eq "$(cntools_ui_content_width)" "180" \
    "content readable width cap"
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_COLUMNS=72
  assert_eq "$(cntools_ui_content_width)" "72" \
    "non-interactive content width"
  assert_fails "invalid content width bounds were accepted" \
    cntools_ui_content_width 40 42
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
      PATH="${case_root}/bin:${PATH}" "${BASH}" "${MAIN_ENTRYPOINT}" -h
  )" || fail "CNTools main help failed without Gum"
  assert_contains "${help_output}" "Usage: cntools.sh" \
    "CNTools main entrypoint help"
  [[ ! -e "${marker}" ]] || fail "help invoked Gum"

  version_output="$(
    CNTOOLS_TEST_GUM_MARKER="${marker}" \
      PATH="${case_root}/bin:${PATH}" "${BASH}" "${MAIN_ENTRYPOINT}" -v
  )" || fail "CNTools main version failed without Gum"
  [[ "${version_output}" =~ ^[0-9]+[.][0-9]+[.][0-9]+ ]] ||
    fail "CNTools main returned an invalid version: ${version_output}"
  [[ ! -e "${marker}" ]] || fail "version output invoked Gum"
)

run_discovery_tests
run_noninteractive_prerequisite_test
run_archive_member_tests
run_pinned_checksum_test
run_offline_installer_test
run_spin_function_test
run_filter_presentation_test
run_action_choice_helper_test
run_filter_layout_test
run_status_spacing_test
run_static_table_style_test
run_menu_mapping_test
run_menu_filter_status_test 130 130 "MENU:abort (filter interrupted)"
run_menu_filter_status_test 2 2 "ERROR:Gum filter failed with status 2"
run_header_test
run_color_capture_preference_test
run_wait_and_placeholder_test
run_health_test
run_content_width_test
run_early_option_tests

printf 'CNTools main tests passed\n'
