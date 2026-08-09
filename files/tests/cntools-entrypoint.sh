#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools entrypoint tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
CNTOOLS_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/cntools.library"
FUNCTION_FIXTURE="${REPO_ROOT}/files/tests/fixtures/cntools-library-functions.txt"
OFFLINE_JSON_FIXTURE="${REPO_ROOT}/files/tests/fixtures/cntools-offline-base.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-entrypoint.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
BASE_PATH="${PATH}"
BASH_BIN="${BASH}"
FAKE_BIN="${TEST_ROOT}/fake-bin"
NETWORK_LOG="${TEST_ROOT}/network.log"
SIDE_EFFECT_LOG="${TEST_ROOT}/side-effects.log"
CLI_LOG="${TEST_ROOT}/cardano-cli.log"
RUN_COUNTER=0
RUN_STATUS=0
RUN_OUTPUT_FILE=""

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
  local content="$1"
  local expected="$2"
  local context="$3"
  [[ "${content}" == *"${expected}"* ]] ||
    fail "${context}: missing '${expected}'"
}

assert_no_network() {
  local context="$1"
  [[ ! -s "${NETWORK_LOG}" ]] ||
    fail "${context}: network command attempted: $(< "${NETWORK_LOG}")"
}

assert_no_side_effects() {
  local context="$1"
  [[ ! -s "${SIDE_EFFECT_LOG}" ]] ||
    fail "${context}: terminal/process command attempted: $(< "${SIDE_EFFECT_LOG}")"
}

assert_no_stty_events() {
  local context="$1"
  local events
  events="$(awk '$1 == "stty" { print }' "${SIDE_EFFECT_LOG}")"
  [[ -z "${events}" ]] ||
    fail "${context}: unexpected headless stty call(s): ${events}"
}

for required_command in awk cksum diff find jq python3 sort; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

write_network_stub() {
  local command_name="$1"
  local destination="${FAKE_BIN}/${command_name}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s" "${0##*/}" >> "${CNTOOLS_NETWORK_LOG:?}"' \
    'printf " %q" "$@" >> "${CNTOOLS_NETWORK_LOG:?}"' \
    'printf "\n" >> "${CNTOOLS_NETWORK_LOG:?}"' \
    'exit 97' \
    > "${destination}"
  chmod 0755 "${destination}"
}

write_side_effect_stub() {
  local command_name="$1"
  local status="$2"
  local destination="${FAKE_BIN}/${command_name}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s" "${0##*/}" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'printf " %q" "$@" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'printf "\n" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    "exit ${status}" \
    > "${destination}"
  chmod 0755 "${destination}"
}

write_stty_stub() {
  local destination="${FAKE_BIN}/stty"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "stty" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'printf " %q" "$@" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'printf "\n" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'if [[ "${CNTOOLS_STTY_MODE:-fail}" == "success" ]]; then' \
    '  [[ "${1:-}" == "-g" ]] && printf "%s\n" "${CNTOOLS_STTY_STATE:-cntools-test-state}"' \
    '  exit 0' \
    'fi' \
    'exit 1' \
    > "${destination}"
  chmod 0755 "${destination}"
}

prepare_fake_bin() {
  local command_name
  mkdir -p "${FAKE_BIN}"
  for command_name in curl wget git ssh nc; do
    write_network_stub "${command_name}"
  done
  for command_name in clear less pkill tput; do
    write_side_effect_stub "${command_name}" 0
  done
  write_stty_stub
  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
}

prepare_dingo_fixture() {
  local node_root="$1"
  local cli_version

  mkdir -p \
    "${node_root}/files" \
    "${node_root}/scripts/adapters" \
    "${node_root}/scripts/lib" \
    "${node_root}/home/.local/bin" \
    "${node_root}/tmp"

  cp "${CNTOOLS_SCRIPT}" "${node_root}/scripts/cntools.sh"
  cp "${CNTOOLS_LIBRARY}" "${node_root}/scripts/cntools.library"
  cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
    "${node_root}/scripts/env"
  cp \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
    "${node_root}/scripts/lib/"
  cp "${REPO_ROOT}/scripts/dingo-helper-scripts/dingo.adapter" \
    "${node_root}/scripts/adapters/dingo.adapter"
  cp "${REPO_ROOT}/files/node-implementations/dingo/release.json" \
    "${node_root}/files/dingo-release.json"

  jq -n \
    --arg service_name "$(basename "${node_root}")" \
    '{
      schemaVersion: 1,
      deploymentStatus: "deployed",
      implementation: "dingo",
      network: "preview",
      branch: "master",
      repository: "cardano-community/guild-operators",
      serviceName: $service_name,
      nodeVersion: "",
      targetNodeVersion: "test-target",
      metricsProvider: "prometheus",
      capabilities: {
        n2c: true,
        localCli: true,
        metrics: true,
        forging: true
      }
    }' > "${node_root}/.deployment.json"

  cli_version="$(jq -er '.companions["cardano-cli"].version' \
    "${node_root}/files/dingo-release.json")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${CNTOOLS_CLI_LOG:?}"' \
    'if [[ "$#" -eq 1 && ( "$1" == "version" || "$1" == "--version" ) ]]; then' \
    "  printf '%s\\n' 'cardano-cli ${cli_version}'" \
    '  exit 0' \
    'fi' \
    'exit 98' \
    > "${node_root}/home/.local/bin/cardano-cli-dingo"
  chmod 0755 "${node_root}/home/.local/bin/cardano-cli-dingo"
}

snapshot_tree() {
  local root="$1"
  local output="$2"
  local path

  (
    cd "${root}"
    while IFS= read -r path; do
      if [[ -d "${path}" ]]; then
        printf 'directory %s\n' "${path}"
      elif [[ -f "${path}" ]]; then
        cksum "${path}"
      else
        printf 'other %s\n' "${path}"
      fi
    done < <(find . -mindepth 1 -print | LC_ALL=C sort)
  ) > "${output}"
}

source_library_for_test() {
  local runtime_root="$1"

  set +u
  mkdir -p "${runtime_root}/logs"
  TMP_DIR="${runtime_root}/tmp"
  WALLET_FOLDER="${runtime_root}/wallet"
  POOL_FOLDER="${runtime_root}/pool"
  ASSET_FOLDER="${runtime_root}/asset"
  LOG_DIR="${runtime_root}/logs"
  CNTOOLS_MODE="offline"
  NETWORK_NAME="Preview"
  ADVANCED_MODE="false"
  ENABLE_ADVANCED="false"
  ENABLE_CHATTR="false"
  FG_BLUE="blue"
  FG_GREEN="green"
  FG_GRAY="gray"
  FG_RED="red"
  NC="none"
  unset TIMEOUT_NO_OF_SLOTS TX_TTL WALLET_SELECTION_FILTER_LIMIT
  unset KES_ALERT_PERIOD KES_WARNING_PERIOD ENABLE_DIALOG CHECK_KES
  unset CATALYST_API EXPLORER_TX CNTOOLS_LOG CURRENCY CURRENCY_URL

  myExit() {
    fail "legacy cntools.library initialization unexpectedly failed: $*"
  }

  . "${CNTOOLS_LIBRARY}"
}

run_cntools() {
  local node_root="$1"
  shift

  RUN_COUNTER=$((RUN_COUNTER + 1))
  RUN_STATUS=0
  RUN_OUTPUT_FILE="${TEST_ROOT}/run-${RUN_COUNTER}.out"
  mkdir -p "${node_root}/home" "${node_root}/tmp/runtime"

  env -i \
    PATH="${FAKE_BIN}:${BASE_PATH}" \
    HOME="${node_root}/home" \
    TMPDIR="${node_root}/tmp" \
    TERM=dumb \
    LC_ALL=C \
    TZ=UTC \
    USESYSVARS=Y \
    NODE_HOME="${node_root}" \
    CNODE_HOME="${node_root}" \
    TMP_DIR="${node_root}/tmp/runtime" \
    UPDATE_CHECK=N \
    ENABLE_CHATTR=false \
    CHECK_KES=false \
    CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
    CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
    CNTOOLS_CLI_LOG="${CLI_LOG}" \
    CNTOOLS_STTY_MODE=fail \
    http_proxy=http://127.0.0.1:9 \
    https_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 \
    HTTPS_PROXY=http://127.0.0.1:9 \
    python3 -c '
import os
import signal
import subprocess
import sys

process = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    status = process.wait(timeout=20)
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    raise SystemExit(124)
raise SystemExit(status if status >= 0 else 128 - status)
' "${BASH_BIN}" --noprofile --norc \
      "${node_root}/scripts/cntools.sh" "$@" \
    > "${RUN_OUTPUT_FILE}" 2>&1 || RUN_STATUS=$?

  if [[ "${RUN_STATUS}" == 124 ]]; then
    fail "CNTools command timed out after 20 seconds: $*"
  fi
}

run_syntax_contract() {
  local shell_file
  for shell_file in \
    "${CNTOOLS_SCRIPT}" \
    "${CNTOOLS_LIBRARY}" \
    "${REPO_ROOT}/scripts/common-helper-scripts/env" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
    "${REPO_ROOT}/scripts/dingo-helper-scripts/dingo.adapter"; do
    "${BASH_BIN}" -n "${shell_file}" ||
      fail "shell syntax validation failed: ${shell_file}"
  done
}

run_entrypoint_source_contract() {
  local source_output
  local source_root="${TEST_ROOT}/entrypoint-source"
  local source_script="${source_root}/scripts/cntools.sh"
  local before_snapshot="${TEST_ROOT}/entrypoint-source.before"
  local after_snapshot="${TEST_ROOT}/entrypoint-source.after"

  mkdir -p \
    "${source_root}/scripts" \
    "${source_root}/home" \
    "${source_root}/tmp" \
    "${source_root}/wallet" \
    "${source_root}/pool" \
    "${source_root}/asset" \
    "${source_root}/logs"
  cp "${CNTOOLS_SCRIPT}" "${source_script}"
  snapshot_tree "${source_root}" "${before_snapshot}"

  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  source_output="$(
    env -i \
      PATH="${FAKE_BIN}:${BASE_PATH}" \
      HOME="${source_root}/home" \
      USESYSVARS=Y \
      NODE_HOME="${source_root}" \
      CNODE_HOME="${source_root}" \
      TMP_DIR="${source_root}/tmp" \
      WALLET_FOLDER="${source_root}/wallet" \
      POOL_FOLDER="${source_root}/pool" \
      ASSET_FOLDER="${source_root}/asset" \
      LOG_DIR="${source_root}/logs" \
      CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
      CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
      CNTOOLS_STTY_MODE=fail \
      "${BASH_BIN}" --noprofile --norc -c '
        set -euo pipefail
        script_path="$1"
        before_traps="$(trap -p HUP INT TERM EXIT)"
        set -- -o sentinel
        saved_args="$*"
        OPTIND=7
        PARENT="caller-parent"
        CNTOOLS_MODE="caller-mode"
        ADVANCED_MODE="caller-advanced"
        STTY_SETTINGS="caller-stty"
        . "${script_path}"
        after_traps="$(trap -p HUP INT TERM EXIT)"
        [[ "${before_traps}" == "${after_traps}" ]]
        [[ "$*" == "${saved_args}" ]]
        [[ "${OPTIND}" == 7 ]]
        [[ "${PARENT}" == "caller-parent" ]]
        [[ "${CNTOOLS_MODE}" == "caller-mode" ]]
        [[ "${ADVANCED_MODE}" == "caller-advanced" ]]
        [[ "${STTY_SETTINGS}" == "caller-stty" ]]
        declare -F cleanup >/dev/null
        declare -F myExit >/dev/null
        declare -F usage >/dev/null
        declare -F main >/dev/null
      ' cntools-source-test "${source_script}"
  )" || fail "sourcing cntools.sh changed caller state or executed startup"

  [[ -z "${source_output}" ]] ||
    fail "sourcing cntools.sh produced output: ${source_output}"
  snapshot_tree "${source_root}" "${after_snapshot}"
  diff -u "${before_snapshot}" "${after_snapshot}" ||
    fail "sourcing cntools.sh changed its isolated filesystem fixture"
  assert_no_network "sourcing cntools.sh"
  assert_no_side_effects "sourcing cntools.sh"
}

run_library_source_contract() {
  local actual_functions="${TEST_ROOT}/cntools-library-functions.txt"
  local library_root="${TEST_ROOT}/library-source"

  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  env -i \
    PATH="${FAKE_BIN}:${BASE_PATH}" \
    HOME="${TEST_ROOT}/library-home" \
    CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
    CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
    "${BASH_BIN}" --noprofile --norc -c '
      set -eo pipefail
      set +u
      library_path="$1"
      library_root="$2"
      TMP_DIR="${library_root}/tmp"
      WALLET_FOLDER="${library_root}/wallet"
      POOL_FOLDER="${library_root}/pool"
      ASSET_FOLDER="${library_root}/asset"
      LOG_DIR="${library_root}/logs"
      CNTOOLS_MODE="offline"
      NETWORK_NAME="Preview"
      ADVANCED_MODE="false"
      ENABLE_ADVANCED="false"
      ENABLE_CHATTR="false"
      FG_BLUE="blue"
      FG_GREEN="green"
      FG_GRAY="gray"
      FG_RED="red"
      NC="none"
      original_tmp="${TMP_DIR}"
      before_traps="$(trap -p HUP INT TERM EXIT)"
      . "${library_path}"
      after_traps="$(trap -p HUP INT TERM EXIT)"
      [[ "${before_traps}" == "${after_traps}" ]]
      [[ "${TMP_DIR}" == "${original_tmp}/cntools" ]]
      [[ -d "${TMP_DIR}" && -d "${WALLET_FOLDER}" ]]
      [[ -d "${POOL_FOLDER}" && -d "${ASSET_FOLDER}" ]]
      [[ "${CNTOOLS_MODE}" == "OFFLINE" ]]
      [[ "${CNTOOLS_MODE_COLOR}" == "gray" ]]
      [[ "${TIMEOUT_NO_OF_SLOTS}" == "600" ]]
      [[ "${TX_TTL}" == "3600" ]]
      [[ "${WALLET_SELECTION_FILTER_LIMIT}" == "10" ]]
      [[ "${KES_ALERT_PERIOD}" == "172800" ]]
      [[ "${KES_WARNING_PERIOD}" == "604800" ]]
      [[ "${ENABLE_DIALOG}" == "false" ]]
      [[ "${CHECK_KES}" == "true" ]]
      [[ "${CATALYST_API}" == "https://api.projectcatalyst.io/api/v1" ]]
      [[ "${EXPLORER_TX}" == "https://adastat.net/transactions/__tx_id__" ]]
      [[ "${CNTOOLS_LOG}" == "${LOG_DIR}/cntools-history.log" ]]
      [[ "${CURRENCY}" == "off" ]]
      [[ -z ${CURRENCY_URL+x} ]]
      [[ "${launch_modes_info}" == *"OFFLINE"* ]]
      declare -F | awk "{print \$3}" | LC_ALL=C sort
    ' cntools-library-source-test \
      "${CNTOOLS_LIBRARY}" \
      "${library_root}" \
      > "${actual_functions}" ||
    fail "legacy cntools.library source-time initialization contract failed"

  diff -u "${FUNCTION_FIXTURE}" "${actual_functions}" ||
    fail "CNTools library function inventory changed"
  assert_no_network "sourcing cntools.library"
  assert_no_side_effects "sourcing cntools.library"
}

run_library_asset_failure_contract() {
  local failure_root="${TEST_ROOT}/library-asset-failure"
  local output
  local status

  mkdir -p "${failure_root}/logs"
  : > "${failure_root}/asset"
  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  set +e
  output="$(
    env -i \
      PATH="${FAKE_BIN}:${BASE_PATH}" \
      HOME="${failure_root}/home" \
      CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
      CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
      "${BASH_BIN}" --noprofile --norc -c '
        set +u
        library_path="$1"
        failure_root="$2"
        TMP_DIR="${failure_root}/tmp"
        WALLET_FOLDER="${failure_root}/wallet"
        POOL_FOLDER="${failure_root}/pool"
        ASSET_FOLDER="${failure_root}/asset"
        LOG_DIR="${failure_root}/logs"
        FG_RED="red"
        NC="none"
        myExit() {
          printf "%s\n%s\n" "$1" "$2"
          exit "$1"
        }
        . "${library_path}"
      ' cntools-library-failure-test "${CNTOOLS_LIBRARY}" "${failure_root}"
  )"
  status=$?
  set -e

  assert_eq "${status}" "1" "asset directory initialization failure status"
  assert_contains "${output}" \
    "Failed to create asset directory: ${failure_root}/asset" \
    "asset directory initialization diagnostic"
  assert_no_network "asset directory initialization failure"
  assert_no_side_effects "asset directory initialization failure"
}

run_terminal_lifecycle_contract() {
  local terminal_root="${TEST_ROOT}/terminal-lifecycle"
  local output_file="${TEST_ROOT}/terminal-lifecycle.out"
  local status
  local stty_events

  mkdir -p "${terminal_root}/scripts" "${terminal_root}/home"
  cp "${CNTOOLS_SCRIPT}" "${terminal_root}/scripts/cntools.sh"
  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"

  set +e
  env -i \
    PATH="${FAKE_BIN}:${BASE_PATH}" \
    HOME="${terminal_root}/home" \
    TERM=dumb \
    LC_ALL=C \
    CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
    CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
    CNTOOLS_STTY_MODE=success \
    CNTOOLS_STTY_STATE=cntools-test-state \
    python3 - "${BASH_BIN}" "${terminal_root}/scripts/cntools.sh" \
    > "${output_file}" 2>&1 <<'PY'
import os
import errno
import pty
import select
import signal
import sys
import time

pid, master_fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "--noprofile", "--norc", sys.argv[2], "-x"])

deadline = time.monotonic() + 20
status = None
timed_out = False
while status is None:
    waited_pid, child_status = os.waitpid(pid, os.WNOHANG)
    if waited_pid == pid:
        status = child_status
        break
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        timed_out = True
        break
    readable, _, _ = select.select([master_fd], [], [], min(0.2, remaining))
    if readable:
        try:
            data = os.read(master_fd, 4096)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        if data:
            os.write(sys.stdout.fileno(), data)

if timed_out:
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    terminate_deadline = time.monotonic() + 1
    while time.monotonic() < terminate_deadline:
        waited_pid, child_status = os.waitpid(pid, os.WNOHANG)
        if waited_pid == pid:
            status = child_status
            break
        time.sleep(0.05)
    if status is None:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
    os.close(master_fd)
    raise SystemExit(124)

os.close(master_fd)
if os.WIFEXITED(status):
    raise SystemExit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    raise SystemExit(128 + os.WTERMSIG(status))
raise SystemExit(125)
PY
  status=$?
  set -e

  [[ "${status}" != 124 ]] ||
    fail "PTY terminal lifecycle timed out after 20 seconds"
  assert_eq "${status}" "1" "PTY invalid-option status"
  stty_events="$(awk '$1 == "stty" { print }' "${SIDE_EFFECT_LOG}")"
  assert_eq "${stty_events}" $'stty -g\nstty cntools-test-state' \
    "terminal state capture and restoration"
  assert_no_network "PTY terminal lifecycle"
}

run_menu_engine_contract() (
  local status
  source_library_for_test "${TEST_ROOT}/menu-engine"
  println() { :; }

  selectOption() {
    [[ "$#" == 2 ]]
    [[ "$1" == "[a] Alpha" ]]
    [[ "$2" == "[b] Beta" ]]
    return 1
  }
  selected_value="before-selection"
  set +e
  select_opt "" "[a] Alpha" "" "[b] Beta"
  status=$?
  set -e
  assert_eq "${status}" "1" "legacy menu selection status"
  assert_eq "${selected_value}" "[b] Beta" \
    "legacy selected_value output"

  # Preserve this known defect as characterization: cursor detection failure
  # returns the first index but leaves a previous selected_value untouched.
  selectOption() { return 255; }
  selected_value="stale-selection"
  set +e
  select_opt "[a] Alpha"
  status=$?
  set -e
  assert_eq "${status}" "0" "legacy cursor-failure fallback status"
  assert_eq "${selected_value}" "stale-selection" \
    "legacy cursor-failure selected_value behavior"
)

run_offline_json_contract() (
  local actual="${TEST_ROOT}/offline-base.actual.json"
  local expected="${TEST_ROOT}/offline-base.expected.json"
  source_library_for_test "${TEST_ROOT}/offline-json"

  date() {
    case "$*" in
      '+%s') printf '1700000000\n' ;;
      '--iso-8601=s') printf '2023-11-14T22:13:20+00:00\n' ;;
      '--iso-8601=s --date=@1700003600')
        printf '2023-11-14T23:13:20+00:00\n'
        ;;
      *) return 1 ;;
    esac
  }

  ttl_enter=3600
  ttl=1700003600
  buildOfflineJSON payment ||
    fail "buildOfflineJSON rejected the deterministic fixture"
  jq -S . <<< "${offlineJSON}" > "${actual}"
  jq -S . "${OFFLINE_JSON_FIXTURE}" > "${expected}"
  diff -u "${expected}" "${actual}" ||
    fail "base offline transaction JSON contract changed"
)

run_cli_contracts() {
  local missing_root="${TEST_ROOT}/missing-env"
  local dingo_root="${TEST_ROOT}/dingo"
  local output expected_version version_line_count option

  mkdir -p "${missing_root}/scripts"
  cp "${CNTOOLS_SCRIPT}" "${missing_root}/scripts/cntools.sh"
  prepare_dingo_fixture "${dingo_root}"

  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  run_cntools "${missing_root}" -x
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" "1" "invalid option status"
  assert_contains "${output}" "Usage:" "invalid option usage"
  for option in \
    '-n    Local mode' \
    '-l    Light mode' \
    '-o    Offline mode' \
    '-a    Enable advanced/developer features' \
    '-u    Skip script update check' \
    '-b    Persist an alternate Guild Operators branch' \
    '-v    Print CNTools version'; do
    assert_contains "${output}" "${option}" "usage option inventory"
  done
  assert_no_network "invalid option"
  assert_no_stty_events "invalid option"

  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  run_cntools "${missing_root}" -o -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" "1" "missing env status"
  assert_contains "${output}" "Common env file missing:" \
    "missing env diagnostic"
  assert_no_network "missing env"
  assert_no_stty_events "missing env"

  # Preserve the current silent-getopts behavior for a missing -b argument:
  # startup continues until the next prerequisite failure instead of showing
  # usage. This is recorded as a known defect in the Stage 0A report.
  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  run_cntools "${missing_root}" -b
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" "1" "missing branch argument status"
  assert_contains "${output}" "Common env file missing:" \
    "missing branch argument legacy behavior"
  assert_no_network "missing branch argument"
  assert_no_stty_events "missing branch argument"

  : > "${NETWORK_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  : > "${CLI_LOG}"
  run_cntools "${dingo_root}" -o -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" "0" "offline version status"
  expected_version="$(
    awk -F= '
      /^CNTOOLS_MAJOR_VERSION=/ { major=$2 }
      /^CNTOOLS_MINOR_VERSION=/ { minor=$2 }
      /^CNTOOLS_PATCH_VERSION=/ { patch=$2 }
      END {
        if (major != "" && minor != "" && patch != "") {
          printf "%s.%s.%s", major, minor, patch
        } else {
          exit 1
        }
      }
    ' "${CNTOOLS_LIBRARY}"
  )" || fail "failed to parse CNTools version constants"
  assert_contains "${output}" \
    "CNTools v${expected_version} (branch: master)" \
    "offline version output"
  version_line_count="$(
    grep -Ec "CNTools v${expected_version} [(]branch: master[)]" \
      "${RUN_OUTPUT_FILE}" || true
  )"
  assert_eq "${version_line_count}" "1" "offline version line count"
  [[ -d "${dingo_root}/tmp/runtime/cntools" ]] ||
    fail "production entrypoint did not initialize its CNTools temp directory"
  [[ -d "${dingo_root}/priv/wallet" &&
     -d "${dingo_root}/priv/pool" &&
     -d "${dingo_root}/priv/asset" ]] ||
    fail "production entrypoint did not initialize wallet/pool/asset paths"
  assert_eq "$(< "${CLI_LOG}")" "version" \
    "Dingo cardano-cli version probe"
  assert_no_network "offline version"
  assert_no_stty_events "offline version"
}

prepare_fake_bin
run_syntax_contract
run_entrypoint_source_contract
run_library_source_contract
run_library_asset_failure_contract
run_terminal_lifecycle_contract
run_menu_engine_contract
run_offline_json_contract
run_cli_contracts

printf 'CNTools entrypoint characterization tests passed\n'
