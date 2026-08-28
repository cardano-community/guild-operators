#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2154,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
ENTRYPOINT_SOURCE="${CNTOOLS_SOURCE}/cntools_main.sh"
STARTUP_SOURCE="${CNTOOLS_SOURCE}/core/startup.sh"

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

# These checks deliberately run even on hosts whose system Bash is too old to
# execute CNTools. Live startup cases skip only after the installed payload has
# received a complete syntax and static boundary check.
for source_file in \
  "${ENTRYPOINT_SOURCE}" \
  "${CNTOOLS_SOURCE}/core/startup.sh" \
  "${CNTOOLS_SOURCE}/core/log.sh" \
  "${CNTOOLS_SOURCE}/core/gum.sh" \
  "${CNTOOLS_SOURCE}/core/health.sh" \
  "${CNTOOLS_SOURCE}/core/menu.sh" \
  "${CNTOOLS_SOURCE}/core/action.sh" \
  "${CNTOOLS_SOURCE}/core/update.sh"; do
  [[ -f "${source_file}" && ! -L "${source_file}" ]] ||
    fail "missing or unsafe Phase 3 source: ${source_file}"
  bash -n "${source_file}" ||
    fail "Phase 3 source failed syntax validation: ${source_file}"
done

assert_eq \
  "$(grep -Fc '. "${env_file}" definitions' "${STARTUP_SOURCE}")" \
  "1" "common env definitions source count"
if grep -F 'cntools.library' "${ENTRYPOINT_SOURCE}" \
  "${STARTUP_SOURCE}" >/dev/null; then
  fail "new CNTools startup references the legacy CNTools library"
fi
grep -F 'cntools_startup_parse_args "$@"' "${ENTRYPOINT_SOURCE}" >/dev/null ||
  fail "entrypoint does not parse arguments before runtime startup"
grep -F 'cntools_startup_load_env' "${ENTRYPOINT_SOURCE}" >/dev/null ||
  fail "entrypoint does not use the one-time environment loader"
grep -F 'cntools_entrypoint_install_traps' "${ENTRYPOINT_SOURCE}" >/dev/null ||
  fail "entrypoint does not install its cleanup traps"
grep -F 'update.sh' "${ENTRYPOINT_SOURCE}" >/dev/null ||
  fail "entrypoint does not load the Phase 5 update core"

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools startup live tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

for required_command in \
  bash chmod cp diff env grep jq mktemp mkdir mv rm stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

TEST_BASH="$(command -v bash)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-startup.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"

cleanup_test() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

write_file() {
  local target="$1"
  local content="$2"

  printf '%s\n' "${content}" > "${target}"
}

prepare_layout() {
  local name="$1"

  CASE_ROOT="${TEST_ROOT}/${name}"
  NODE_ROOT="${CASE_ROOT}/node"
  APP_ROOT="${NODE_ROOT}/scripts/cntools"
  ENV_FILE="${NODE_ROOT}/scripts/env"
  ENV_TRACE="${CASE_ROOT}/env.trace"
  PROBE_TRACE="${CASE_ROOT}/probe.trace"
  SESSION_TRACE="${CASE_ROOT}/session.trace"
  DISPATCH_TRACE="${CASE_ROOT}/dispatcher.trace"
  CURL_TRACE="${CASE_ROOT}/curl.trace"
  RUN_STDOUT="${CASE_ROOT}/stdout"
  RUN_STDERR="${CASE_ROOT}/stderr"
  TEST_DRIVER="${CASE_ROOT}/startup-driver.sh"
  CASE_BIN="${CASE_ROOT}/bin"
  CASE_PATH="${PATH}"
  CASE_DISPATCH_STATUS=0
  CASE_DEPENDENCY_TRACE=""

  mkdir -p "${NODE_ROOT}/scripts" "${CASE_BIN}"
  cp -R "${CNTOOLS_SOURCE}" "${APP_ROOT}"
  chmod 0755 "${APP_ROOT}/cntools_main.sh"
  write_file "${TEST_DRIVER}" '#!/usr/bin/env bash
main_entrypoint="$1"
shift
# Source the real entrypoint so the complete startup wiring is exercised, but
# replace only the interactive boundary. TTY/Gum behavior has dedicated tests.
. "${main_entrypoint}"
cntools_gum_require() { return 0; }
cntools_gum_require_terminal() { return 0; }
cntools_ui_init() {
  CNTOOLS_UI_INTERACTIVE="N"
  CNTOOLS_UI_CAPABLE="Y"
  CNTOOLS_UI_CLEANED="N"
}
cntools_gum_menu_run() {
  local inspection_action="${CNTOOLS_MODULE_ROOT}/inspect"

  [[ -d "${inspection_action}" ]] || return 0
  cntools_action_run "${inspection_action}"
}
cntools_main "$@"'
  chmod 0755 "${TEST_DRIVER}"
}

write_fake_env() {
  write_file "${ENV_FILE}" '#!/usr/bin/env bash
printf "%s\n" "source:${1:-}" >> "${CNTOOLS_TEST_ENV_TRACE}"
[[ "${1:-}" == "definitions" ]] || return 90

# The legacy bootstrap is intentionally allowed to change global compatibility
# state. The new startup layer must restore its caller and normalize only the
# values it owns.
set -o posix
LEGACY_UNSET_COPY="${LEGACY_VALUE_THAT_IS_NOT_SET}"
PARENT="/mutated/by/synthetic/env"
ENV_PROFILE="definitions"
OFFLINE_MODE="Y"

# This mirrors legacy user configuration: the socket override is evaluated
# before the common env body establishes CNODE_HOME. CNTools must seed the
# deployment root before sourcing the file so the path remains complete.
SOCKET="${CNODE_HOME}/sockets/node0.socket"
DEPLOYMENT_SCHEMA_VERSION="1"
NODE_HOME="${CNTOOLS_TEST_NODE_HOME}"
NODE_IMPLEMENTATION="${CNTOOLS_TEST_IMPLEMENTATION}"
NODE_NETWORK="${CNTOOLS_TEST_NETWORK}"
NODE_SERVICE="${CNTOOLS_TEST_SERVICE}"
G_ACCOUNT="${CNTOOLS_TEST_ACCOUNT}"
BRANCH="${CNTOOLS_TEST_STORED_BRANCH}"
case "${NODE_IMPLEMENTATION}" in
  cnode)
    NODE_IMPLEMENTATION_DISPLAY_NAME="Cardano Node"
    NODE_METRICS_PROVIDER="prometheus"
    NODE_DEPLOYMENT_CAPABILITIES="{\"forging\":true,\"localCli\":true,\"metrics\":true,\"n2c\":true}"
    ;;
  dingo)
    NODE_IMPLEMENTATION_DISPLAY_NAME="Dingo"
    NODE_METRICS_PROVIDER="prometheus"
    NODE_DEPLOYMENT_CAPABILITIES="{\"forging\":true,\"localCli\":true,\"metrics\":true,\"n2c\":true}"
    ;;
  amaru)
    NODE_IMPLEMENTATION_DISPLAY_NAME="Amaru"
    NODE_METRICS_PROVIDER="otel"
    NODE_DEPLOYMENT_CAPABILITIES="{\"forging\":false,\"localCli\":false,\"metrics\":true,\"n2c\":false}"
    ;;
  *) return 91 ;;
esac

LOG_DIR="${NODE_HOME}/runtime/logs"
CNTOOLS_LOG="${LOG_DIR}/cntools.log"
TMP_DIR="${NODE_HOME}/runtime/tmp"
WALLET_FOLDER="${NODE_HOME}/private/wallets"
POOL_FOLDER="${NODE_HOME}/private/pools"
ASSET_FOLDER="${NODE_HOME}/private/assets"
DBSYNC_QUERY_FOLDER="${NODE_HOME}/runtime/dbsync-queries"
CONFIG="${NODE_HOME}/custom/node-config.json"
CCLI="/usr/bin/false"
WALLET_PAY_SK_FILENAME="custom-payment.skey"
WALLET_PAY_ADDR_FILENAME="custom-payment.addr"
WALLET_STAKE_SK_FILENAME="custom-stake.skey"
WALLET_STAKE_ADDR_FILENAME="custom-reward.addr"
WALLET_DERIVATION_PATH_FILENAME="custom-derivation.path"
UPDATE_CHECK="Y"
ENABLE_KOIOS="Y"
KOIOS_API=""
KOIOS_API_TOKEN="fixture-token"
CURL_TIMEOUT="17"

cntools_synthetic_probe() {
  printf "%s\n" "$1" >> "${CNTOOLS_TEST_PROBE_TRACE}"
  return 97
}
test_koios() { cntools_synthetic_probe test_koios; }
node_ready() { cntools_synthetic_probe node_ready; }
node_status() { cntools_synthetic_probe node_status; }
node_query() { cntools_synthetic_probe node_query; }
node_submit() { cntools_synthetic_probe node_submit; }
getNodeMetrics() { cntools_synthetic_probe getNodeMetrics; }
curl() { cntools_synthetic_probe curl; }
'
  chmod 0644 "${ENV_FILE}"

  write_file "${CASE_BIN}/curl" '#!/usr/bin/env bash
output=""
write_out=""
url=""
while (( $# > 0 )); do
  case "$1" in
    --output|-o)
      output="${2:-}"
      shift 2
      ;;
    --write-out|-w)
      write_out="${2:-}"
      shift 2
      ;;
    --request|--max-time|--connect-timeout|--max-filesize|--header)
      shift 2
      ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf "%s\n" "${url}" >> "${CNTOOLS_TEST_CURL_TRACE}"
[[ -z "${output}" ]] || printf "%s\n" "${CNTOOLS_TEST_REMOTE_VERSION}" > "${output}"
[[ "${write_out}" != *http_code* ]] || printf "200"
'
  chmod 0755 "${CASE_BIN}/curl"
  CASE_PATH="${CASE_BIN}:${PATH}"
}

install_inspection_action() {
  local action_directory="${APP_ROOT}/modules/root/inspect"

  mkdir -p "${action_directory}"
  jq -n '{
    kind: "action",
    label: "Inspect",
    description: "Record the normalized startup session",
    shortcut: "i",
    order: 10,
    modes: ["local", "light", "offline"]
  }' > "${action_directory}/module.json"
  write_file "${action_directory}/action.sh" '#!/usr/bin/env bash
cntools_action_main() {
  local posix_state="N"
  [[ -o posix ]] && posix_state="Y"
  {
    printf "%s\n" "mode=${CNTOOLS_MODE}"
    printf "%s\n" "backend=${CNTOOLS_BACKEND}"
    printf "%s\n" "advanced=${CNTOOLS_ADVANCED}"
    printf "%s\n" "root=${CNTOOLS_ROOT}"
    printf "%s\n" "entrypoint=${CNTOOLS_ENTRYPOINT}"
    printf "%s\n" "node_home=${CNTOOLS_NODE_HOME}"
    printf "%s\n" "implementation=${CNTOOLS_IMPLEMENTATION}"
    printf "%s\n" "implementation_name=${CNTOOLS_IMPLEMENTATION_NAME}"
    printf "%s\n" "network=${CNTOOLS_NETWORK}"
    printf "%s\n" "service=${CNTOOLS_SERVICE}"
    printf "%s\n" "account=${CNTOOLS_ACCOUNT}"
    printf "%s\n" "branch=${CNTOOLS_BRANCH}"
    printf "%s\n" "metrics=${CNTOOLS_METRICS_PROVIDER}"
    printf "%s\n" "config=${CNTOOLS_CONFIG}"
    printf "%s\n" "capabilities=${CNTOOLS_CAPABILITIES}"
    printf "%s\n" "local_cli_capable=${CNTOOLS_LOCAL_CLI_CAPABLE}"
    printf "%s\n" "cli=${CNTOOLS_CLI}"
    printf "%s\n" "socket=${CNTOOLS_SOCKET}"
    printf "%s\n" "log_dir=${CNTOOLS_LOG_DIR}"
    printf "%s\n" "log=${CNTOOLS_LOG}"
    printf "%s\n" "tmp=${CNTOOLS_TMP_DIR}"
    printf "%s\n" "wallet=${CNTOOLS_WALLET_DIR}"
    printf "%s\n" "wallet_payment_signing_file=${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
    printf "%s\n" "wallet_payment_address_file=${CNTOOLS_WALLET_PAY_ADDR_FILENAME}"
    printf "%s\n" "wallet_stake_signing_file=${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
    printf "%s\n" "wallet_reward_address_file=${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}"
    printf "%s\n" "wallet_derivation_file=${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}"
    printf "%s\n" "pool=${CNTOOLS_POOL_DIR}"
    printf "%s\n" "asset=${CNTOOLS_ASSET_DIR}"
    printf "%s\n" "dbsync=${CNTOOLS_DBSYNC_QUERY_DIR}"
    printf "%s\n" "update=${CNTOOLS_UPDATE_CHECK}"
    printf "%s\n" "koios_enabled=${CNTOOLS_KOIOS_ENABLED}"
    printf "%s\n" "koios_api=${CNTOOLS_KOIOS_API}"
    printf "%s\n" "curl_timeout=${CNTOOLS_CURL_TIMEOUT}"
    if [[ "${CNTOOLS_KOIOS_TOKEN:-}" == "fixture-token" ]]; then
      printf "%s\n" "koios_token_available=Y"
    else
      printf "%s\n" "koios_token_available=N"
    fi
    if env | grep -Eq "^(CNTOOLS_KOIOS_TOKEN|KOIOS_API_TOKEN)="; then
      printf "%s\n" "koios_token_exported=Y"
    else
      printf "%s\n" "koios_token_exported=N"
    fi
    printf "%s\n" "posix=${posix_state}"
  } > "${CNTOOLS_TEST_SESSION_TRACE}"
}'
  chmod 0644 "${action_directory}/action.sh"
}

set_case_identity() {
  local implementation="$1"
  local network="$2"

  CASE_IMPLEMENTATION="${implementation}"
  CASE_NETWORK="${network}"
  CASE_SERVICE="${implementation}-fixture"
  CASE_ACCOUNT="fixture-account"
  CASE_STORED_BRANCH="alpha"
}

run_installed() {
  local input="$1"
  local remote_version=""
  shift

  if [[ -f "${APP_ROOT}/VERSION" ]]; then
    remote_version="$(< "${APP_ROOT}/VERSION")"
  fi

  rm -f -- \
    "${ENV_TRACE}" "${PROBE_TRACE}" "${SESSION_TRACE}" \
    "${DISPATCH_TRACE}" "${CURL_TRACE}" "${RUN_STDOUT}" "${RUN_STDERR}"
  if printf '%b' "${input}" | env -i \
    PATH="${CASE_PATH:-${PATH}}" \
    HOME="${HOME:-${TEST_ROOT}}" \
    LANG="C" \
    TERM="dumb" \
    TMPDIR="${TMPDIR:-/tmp}" \
    CNTOOLS_TEST_NODE_HOME="${NODE_ROOT}" \
    CNTOOLS_TEST_IMPLEMENTATION="${CASE_IMPLEMENTATION:-cnode}" \
    CNTOOLS_TEST_NETWORK="${CASE_NETWORK:-preview}" \
    CNTOOLS_TEST_SERVICE="${CASE_SERVICE:-cnode-fixture}" \
    CNTOOLS_TEST_ACCOUNT="${CASE_ACCOUNT:-fixture-account}" \
    CNTOOLS_TEST_STORED_BRANCH="${CASE_STORED_BRANCH:-alpha}" \
    CNTOOLS_TEST_ENV_TRACE="${ENV_TRACE}" \
    CNTOOLS_TEST_PROBE_TRACE="${PROBE_TRACE}" \
    CNTOOLS_TEST_SESSION_TRACE="${SESSION_TRACE}" \
    CNTOOLS_TEST_DISPATCH_TRACE="${DISPATCH_TRACE}" \
    CNTOOLS_TEST_DISPATCH_STATUS="${CASE_DISPATCH_STATUS:-0}" \
    CNTOOLS_TEST_CURL_TRACE="${CURL_TRACE}" \
    CNTOOLS_TEST_REMOTE_VERSION="${remote_version}" \
    CNTOOLS_TEST_DEPENDENCY_TRACE="${CASE_DEPENDENCY_TRACE:-}" \
    "${TEST_BASH}" "${TEST_DRIVER}" "${APP_ROOT}/cntools_main.sh" "$@" \
    > "${RUN_STDOUT}" 2> "${RUN_STDERR}"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

assert_trace_value() {
  local key="$1"
  local expected="$2"
  local trace="${3:-${SESSION_TRACE}}"

  grep -Fx "${key}=${expected}" "${trace}" >/dev/null ||
    fail "missing normalized value ${key}=${expected} in ${trace}"
}

assert_single_definitions_load() {
  [[ -f "${ENV_TRACE}" ]] || fail "common env was not sourced"
  assert_eq "$(wc -l < "${ENV_TRACE}" | tr -d ' ')" "1" \
    "common env source count"
  assert_eq "$(< "${ENV_TRACE}")" "source:definitions" \
    "common env source profile"
}

run_cli_parser_tests() (
  # shellcheck source=/dev/null
  . "${STARTUP_SOURCE}"

  cntools_startup_parse_args
  assert_eq "${CNTOOLS_MODE}" "local" "default mode"
  assert_eq "${CNTOOLS_ADVANCED}" "N" "default advanced visibility"
  assert_eq "${CNTOOLS_UPDATE_CHECK_OVERRIDE}" "" "default update override"

  cntools_startup_parse_args -l -o -n -a -u -v -b feature/startup
  assert_eq "${CNTOOLS_MODE}" "local" "last mode flag"
  assert_eq "${CNTOOLS_ADVANCED}" "Y" "advanced option"
  assert_eq "${CNTOOLS_UPDATE_CHECK_OVERRIDE}" "N" "update-check option"
  assert_eq "${CNTOOLS_SHOW_VERSION}" "Y" "version option"
  assert_eq "${CNTOOLS_BRANCH_REQUEST}" "feature/startup" "branch option"

  if cntools_startup_parse_args -x >/dev/null 2>&1; then
    fail "unknown CLI option was accepted"
  fi
  if cntools_startup_parse_args -b >/dev/null 2>&1; then
    fail "missing branch argument was accepted"
  fi
  if cntools_startup_parse_args unexpected >/dev/null 2>&1; then
    fail "positional CLI argument was accepted"
  fi
)

run_early_help_version_tests() (
  local poison_bin="${TEST_ROOT}/early-poison"
  local dependency_trace="${TEST_ROOT}/early-dependency.trace"
  local command_name=""

  mkdir -p "${poison_bin}"
  for command_name in jq curl tput; do
    write_file "${poison_bin}/${command_name}" "#!/usr/bin/env bash
printf '%s\\n' '${command_name}' >> \"\${CNTOOLS_TEST_DEPENDENCY_TRACE}\"
exit 97"
    chmod 0755 "${poison_bin}/${command_name}"
  done

  prepare_layout early-help
  rm -f -- "${APP_ROOT}/VERSION" "${ENV_FILE}" "${dependency_trace}"
  CASE_PATH="${poison_bin}:${PATH}"
  CASE_DEPENDENCY_TRACE="${dependency_trace}"
  set_case_identity cnode preview
  run_installed '' -h
  assert_eq "${RUN_STATUS}" "0" "help status without VERSION or env"
  grep -F 'Usage: cntools.sh' "${RUN_STDOUT}" >/dev/null ||
    fail "early help output is missing"
  [[ ! -e "${ENV_TRACE}" ]] || fail "help sourced the common env"
  [[ ! -e "${dependency_trace}" ]] || fail "help invoked a runtime dependency"

  prepare_layout early-version
  rm -f -- "${ENV_FILE}" "${dependency_trace}"
  CASE_PATH="${poison_bin}:${PATH}"
  CASE_DEPENDENCY_TRACE="${dependency_trace}"
  set_case_identity cnode preview
  run_installed '' -v
  assert_eq "${RUN_STATUS}" "0" "version status without env"
  assert_eq "$(< "${RUN_STDOUT}")" "$(< "${APP_ROOT}/VERSION")" \
    "early version output"
  [[ ! -e "${ENV_TRACE}" ]] || fail "version sourced the common env"
  [[ ! -e "${dependency_trace}" ]] || fail "version invoked a runtime dependency"
)

run_env_loading_tests() {
  local strict_trace=""
  local posix_trace=""

  prepare_layout env-options
  write_fake_env
  set_case_identity cnode preview
  strict_trace="${CASE_ROOT}/strict-env.trace"
  posix_trace="${CASE_ROOT}/posix-env.trace"

  (
    # shellcheck source=/dev/null
    . "${STARTUP_SOURCE}"
    CNTOOLS_ENV_FILE="${ENV_FILE}"
    CNTOOLS_ENV_SOURCED="N"
    CNTOOLS_TEST_ENV_TRACE="${strict_trace}"
    CNTOOLS_TEST_PROBE_TRACE="${PROBE_TRACE}"
    CNTOOLS_TEST_NODE_HOME="${NODE_ROOT}"
    CNTOOLS_TEST_IMPLEMENTATION="cnode"
    CNTOOLS_TEST_NETWORK="preview"
    CNTOOLS_TEST_SERVICE="cnode-fixture"
    CNTOOLS_TEST_ACCOUNT="fixture-account"
    CNTOOLS_TEST_STORED_BRANCH="alpha"
    set +o posix
    set -euo pipefail
    cntools_startup_load_env
    [[ -o errexit ]] || fail "env load did not restore errexit"
    [[ -o nounset ]] || fail "env load did not restore nounset"
    [[ -o pipefail ]] || fail "env load changed pipefail"
    [[ ! -o posix ]] || fail "env load did not restore disabled POSIX mode"
    if cntools_startup_load_env >/dev/null 2>&1; then
      fail "common env was sourced twice"
    fi
  )
  assert_eq "$(< "${strict_trace}")" "source:definitions" \
    "strict-shell definitions source"

  (
    # shellcheck source=/dev/null
    . "${STARTUP_SOURCE}"
    CNTOOLS_ENV_FILE="${ENV_FILE}"
    CNTOOLS_ENV_SOURCED="N"
    CNTOOLS_TEST_ENV_TRACE="${posix_trace}"
    CNTOOLS_TEST_PROBE_TRACE="${PROBE_TRACE}"
    CNTOOLS_TEST_NODE_HOME="${NODE_ROOT}"
    CNTOOLS_TEST_IMPLEMENTATION="cnode"
    CNTOOLS_TEST_NETWORK="preview"
    CNTOOLS_TEST_SERVICE="cnode-fixture"
    CNTOOLS_TEST_ACCOUNT="fixture-account"
    CNTOOLS_TEST_STORED_BRANCH="alpha"
    set -o posix
    cntools_startup_load_env
    [[ -o posix ]] || fail "env load did not restore enabled POSIX mode"
  )
  assert_eq "$(< "${posix_trace}")" "source:definitions" \
    "POSIX-shell definitions source"
}

run_session_matrix_tests() {
  local implementation=""
  local mode=""
  local network=""
  local mode_option=""
  local expected_backend=""
  local expected_name=""
  local expected_metrics=""
  local expected_capabilities=""
  local expected_koios=""
  local expected_update=""
  local expected_advanced=""
  local -a arguments=()

  for implementation in cnode dingo amaru; do
    case "${implementation}" in
      cnode)
        network="preview"
        expected_name="Cardano Node"
        expected_metrics="prometheus"
        expected_capabilities='{"forging":true,"localCli":true,"metrics":true,"n2c":true}'
        expected_koios="https://preview.koios.rest/api/v1"
        ;;
      dingo)
        network="preprod"
        expected_name="Dingo"
        expected_metrics="prometheus"
        expected_capabilities='{"forging":true,"localCli":true,"metrics":true,"n2c":true}'
        expected_koios="https://preprod.koios.rest/api/v1"
        ;;
      amaru)
        network="preview"
        expected_name="Amaru"
        expected_metrics="otel"
        expected_capabilities='{"forging":false,"localCli":false,"metrics":true,"n2c":false}'
        expected_koios="https://preview.koios.rest/api/v1"
        ;;
    esac

    for mode in local light offline; do
      prepare_layout "session-${implementation}-${mode}"
      write_fake_env
      install_inspection_action
      set_case_identity "${implementation}" "${network}"
      arguments=()
      expected_advanced="N"
      expected_update="Y"
      case "${mode}" in
        local)
          mode_option="-n"
          expected_backend="${implementation}"
          ;;
        light)
          mode_option="-l"
          expected_backend="koios"
          ;;
        offline)
          mode_option="-o"
          expected_backend="none"
          expected_update="N"
          ;;
      esac
      arguments+=("${mode_option}")
      if [[ "${implementation}:${mode}" == "cnode:local" ]]; then
        arguments+=(-a)
        expected_advanced="Y"
      elif [[ "${implementation}:${mode}" == "dingo:light" ]]; then
        arguments+=(-u)
        expected_update="N"
      fi

      run_installed $'i\nq\n' "${arguments[@]}"
      assert_eq "${RUN_STATUS}" "0" \
        "${implementation} ${mode} entrypoint status"
      assert_single_definitions_load
      [[ ! -s "${PROBE_TRACE}" ]] ||
        fail "${implementation} ${mode} startup performed a readiness/API probe"
      if [[ "${expected_update}" == "Y" ]]; then
        [[ -s "${CURL_TRACE}" ]] ||
          fail "${implementation} ${mode} startup skipped its automatic update check"
        assert_eq "$(wc -l < "${CURL_TRACE}" | tr -d ' ')" "1" \
          "${implementation} ${mode} automatic update request count"
        grep -F '/scripts/common-helper-scripts/cntools/VERSION' \
          "${CURL_TRACE}" >/dev/null ||
          fail "${implementation} ${mode} startup fetched the wrong update resource"
        if grep -F '/docs/Scripts/cntools-changelog.md' \
            "${CURL_TRACE}" >/dev/null; then
          fail "${implementation} ${mode} startup fetched the changelog eagerly"
        fi
      elif [[ -s "${CURL_TRACE}" ]]; then
        fail "${implementation} ${mode} startup ignored update-check suppression"
      fi
      [[ -s "${SESSION_TRACE}" ]] ||
        fail "${implementation} ${mode} did not enter the root menu"

      assert_trace_value mode "${mode}"
      assert_trace_value backend "${expected_backend}"
      assert_trace_value advanced "${expected_advanced}"
      assert_trace_value root "${APP_ROOT}"
      assert_trace_value entrypoint "${APP_ROOT}/cntools_main.sh"
      assert_trace_value node_home "${NODE_ROOT}"
      assert_trace_value implementation "${implementation}"
      assert_trace_value implementation_name "${expected_name}"
      assert_trace_value network "${network}"
      assert_trace_value service "${implementation}-fixture"
      assert_trace_value account "fixture-account"
      assert_trace_value branch "alpha"
      assert_trace_value metrics "${expected_metrics}"
      assert_trace_value config "${NODE_ROOT}/custom/node-config.json"
      assert_trace_value capabilities "${expected_capabilities}"
      if [[ "${implementation}" == "amaru" ]]; then
        assert_trace_value local_cli_capable "false"
      else
        assert_trace_value local_cli_capable "true"
      fi
      assert_trace_value cli "/usr/bin/false"
      assert_trace_value socket "${NODE_ROOT}/sockets/node0.socket"
      assert_trace_value log_dir "${NODE_ROOT}/runtime/logs"
      assert_trace_value log "${NODE_ROOT}/runtime/logs/cntools.log"
      assert_trace_value tmp "${NODE_ROOT}/runtime/tmp"
      assert_trace_value wallet "${NODE_ROOT}/private/wallets"
      assert_trace_value wallet_payment_signing_file "custom-payment.skey"
      assert_trace_value wallet_payment_address_file "custom-payment.addr"
      assert_trace_value wallet_stake_signing_file "custom-stake.skey"
      assert_trace_value wallet_reward_address_file "custom-reward.addr"
      assert_trace_value wallet_derivation_file "custom-derivation.path"
      assert_trace_value pool "${NODE_ROOT}/private/pools"
      assert_trace_value asset "${NODE_ROOT}/private/assets"
      assert_trace_value dbsync "${NODE_ROOT}/runtime/dbsync-queries"
      assert_trace_value update "${expected_update}"
      assert_trace_value koios_enabled "Y"
      assert_trace_value koios_api "${expected_koios}"
      assert_trace_value curl_timeout "17"
      assert_trace_value koios_token_available "Y"
      assert_trace_value koios_token_exported "N"
      assert_trace_value posix "N"
      grep -F \
        "start ui=gum mode=${mode} backend=${expected_backend} implementation=${implementation}" \
        "${NODE_ROOT}/runtime/logs/cntools.log" >/dev/null ||
        fail "${implementation} ${mode} session start was not logged"
    done
  done
}

write_dispatcher() {
  local dispatcher="${NODE_ROOT}/scripts/guild-deploy.sh"

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
exit "${CNTOOLS_TEST_DISPATCH_STATUS:-0}"
'
  chmod 0755 "${dispatcher}"
}

run_branch_tests() {
  local expected=""

  prepare_layout branch-status
  write_fake_env
  write_dispatcher
  set_case_identity dingo preprod
  CASE_DISPATCH_STATUS=37
  run_installed '' -v -b feature/startup
  assert_eq "${RUN_STATUS}" "37" "dispatcher status propagation"
  assert_single_definitions_load
  [[ ! -s "${CURL_TRACE}" ]] ||
    fail "branch redeployment performed an automatic update check first"
  [[ -s "${DISPATCH_TRACE}" ]] || fail "branch redeploy did not invoke dispatcher"
  expected="${CASE_ROOT}/dispatcher.expected"
  printf '%s\n' \
    'G_ACCOUNT=fixture-account' \
    'S_ARGS=' \
    'GUILD_DEPLOY_SNAPSHOT_STAGE=bootstrap' \
    'GUILD_DEPLOY_STRICT_REF=Y' \
    'arg=-g' 'arg=fixture-account' \
    'arg=-i' 'arg=dingo' \
    'arg=-n' 'arg=preprod' \
    'arg=-p' "arg=${CASE_ROOT}" \
    'arg=-t' 'arg=node' \
    'arg=-b' 'arg=feature/startup' \
    'arg=-s' 'arg=' > "${expected}"
  diff -u "${expected}" "${DISPATCH_TRACE}" ||
    fail "branch redeploy dispatcher arguments differ"
  if grep -Fx "$(< "${APP_ROOT}/VERSION")" "${RUN_STDOUT}" >/dev/null; then
    fail "-v bypassed a simultaneous -b redeployment request"
  fi

  prepare_layout branch-offline
  write_fake_env
  write_dispatcher
  set_case_identity amaru preview
  CASE_DISPATCH_STATUS=0
  run_installed '' -o -b feature/offline
  assert_eq "${RUN_STATUS}" "1" "offline branch rejection status"
  assert_single_definitions_load
  [[ ! -s "${CURL_TRACE}" ]] ||
    fail "offline branch rejection performed an update check"
  [[ ! -e "${DISPATCH_TRACE}" ]] ||
    fail "offline branch rejection invoked Guild Deploy"
  grep -F 'unavailable in offline mode' "${RUN_STDERR}" >/dev/null ||
    fail "offline branch rejection is not actionable"
}

run_signal_cleanup_tests() {
  local specification=""
  local signal=""
  local expected_status=""
  local trace=""
  local status=0
  local expected=""

  for specification in HUP:129 INT:130 QUIT:131 TERM:143; do
    signal="${specification%%:*}"
    expected_status="${specification##*:}"
    trace="${TEST_ROOT}/signal-${signal}.trace"
    if (
      # shellcheck source=/dev/null
      . "${ENTRYPOINT_SOURCE}"
      cntools_log() {
        printf 'log:%s\n' "${2:-}" >> "${trace}"
      }
      cntools_ui_cleanup() {
        printf 'ui-cleanup\n' >> "${trace}"
      }
      cntools_log_close() {
        printf 'log-close\n' >> "${trace}"
      }
      CNTOOLS_LOG_READY="Y"
      CNTOOLS_SESSION_ENDED="N"
      cntools_entrypoint_install_traps
      kill "-${signal}" "${BASHPID}"
      exit 99
    ); then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "${expected_status}" \
      "${signal} cleanup exit status"
    expected="log:end status=${expected_status}"$'\nui-cleanup\nlog-close'
    [[ -f "${trace}" ]] || fail "${signal} did not run cleanup"
    assert_eq "$(< "${trace}")" "${expected}" \
      "${signal} cleanup sequence"
  done
}

run_cli_parser_tests
run_early_help_version_tests
run_env_loading_tests
run_session_matrix_tests
run_branch_tests
run_signal_cleanup_tests

printf 'CNTools startup tests passed\n'
