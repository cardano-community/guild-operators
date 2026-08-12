#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [[ "$1" = "$2" ]] || fail "expected '$2', got '$1'"
}

run_defaults_case() (
  unset CNODE_NAME CNODE_PATH NODE_NAME NODE_PARENT NODE_PORT
  unset NETWORK BRANCH DOWNLOAD_TIMEOUT
  unset PACKAGE_MANAGER_OUTPUT
  unset CNODE_SKIP_DBSYNC_DOWNLOAD SKIP_DBSYNC_DOWNLOAD
  NODE_IMPLEMENTATION="$1"
  NODE_PARENT="/tmp/guild-dispatcher-test"
  [[ "${NODE_IMPLEMENTATION}" == "cnode" ]] || NETWORK="preprod"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  assert_eq "${NODE_NAME}" "$1"
  assert_eq "${NODE_HOME}" "/tmp/guild-dispatcher-test/$1"
  assert_eq "${DOWNLOAD_TIMEOUT}" "600"
  assert_eq "${PACKAGE_MANAGER_OUTPUT}" "compact"
  case "${NODE_IMPLEMENTATION}" in
    cnode)
      assert_eq "${NODE_PORT}" "6000"
      assert_eq "${CNODE_SKIP_DBSYNC_DOWNLOAD}" "N"
      ;;
    dingo) assert_eq "${NODE_PORT}" "3001" ;;
    amaru) assert_eq "${NODE_PORT}" "3000" ;;
  esac
)

run_defaults_case cnode
run_defaults_case dingo
run_defaults_case amaru

(
  unset CNODE_NAME CNODE_PATH NODE_NAME NETWORK BRANCH
  unset CNODE_SKIP_DBSYNC_DOWNLOAD
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="/tmp/guild-dispatcher-test"
  NODE_PORT="03001"
  DOWNLOAD_TIMEOUT="00600"
  SKIP_DBSYNC_DOWNLOAD="Y"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  assert_eq "${NODE_PORT}" "3001"
  assert_eq "${DOWNLOAD_TIMEOUT}" "600"
  assert_eq "${CNODE_SKIP_DBSYNC_DOWNLOAD}" "Y"
  [[ -z "${SKIP_DBSYNC_DOWNLOAD+x}" ]] ||
    fail "legacy db-sync skip input leaked into the cnode profile"
)

for invalid_input in port timeout dbsync package_output; do
  if (
    unset CNODE_NAME CNODE_PATH NODE_NAME NETWORK BRANCH
    unset NODE_PORT DOWNLOAD_TIMEOUT
    unset PACKAGE_MANAGER_OUTPUT
    unset CNODE_SKIP_DBSYNC_DOWNLOAD SKIP_DBSYNC_DOWNLOAD
    NODE_IMPLEMENTATION="cnode"
    NODE_PARENT="/tmp/guild-dispatcher-test"
    case "${invalid_input}" in
      port) NODE_PORT=70000 ;;
      timeout) DOWNLOAD_TIMEOUT=0 ;;
      dbsync) CNODE_SKIP_DBSYNC_DOWNLOAD="yes" ;;
      package_output) PACKAGE_MANAGER_OUTPUT="quiet-ish" ;;
    esac
    NETWORK_EXPLICIT="N"
    BRANCH_EXPLICIT="N"
    BRANCH_PRESET="N"
    SUDO="N"
    UPDATE_CHECK="N"
    dispatcher_set_defaults
  ) >/dev/null 2>&1; then
    fail "dispatcher accepted invalid ${invalid_input} input"
  fi
done

(
  unset CNODE_NAME CNODE_PATH NODE_NAME NETWORK BRANCH
  NODE_IMPLEMENTATION="dingo"
  NODE_PARENT="/tmp/guild-dispatcher-test"
  NETWORK="preprod"
  CNODE_SKIP_DBSYNC_DOWNLOAD="Y"
  NETWORK_EXPLICIT="Y"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  [[ -z "${CNODE_SKIP_DBSYNC_DOWNLOAD+x}" ]] ||
    fail "cnode-only db-sync input was exported to an alternate profile"
)

(
  unset CNODE_NAME CNODE_PATH NETWORK BRANCH
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="/tmp/guild-dispatcher-test///"
  NODE_NAME="nå-node"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  assert_eq "${NODE_PARENT}" "/tmp/guild-dispatcher-test"
  assert_eq "${CNODE_PATH}" "/tmp/guild-dispatcher-test"
  assert_eq "${NODE_HOME}" "/tmp/guild-dispatcher-test/n___node"
  [[ "${NODE_SERVICE}" =~ ^[a-z0-9_]+$ ]] ||
    fail "Unicode top-level name produced an unsafe service name"
)

inherited_tmp="${TEST_DIR:-${TMPDIR:-/tmp}}/guild-inherited-profile-test.$$"
mkdir -p "${inherited_tmp}"
printf 'keep\n' > "${inherited_tmp}/sentinel"
(
  PROFILE_TMP_DIR="${inherited_tmp}"
  guild_deploy_main -h >/dev/null
)
[[ -f "${inherited_tmp}/sentinel" ]] ||
  fail "dispatcher cleanup removed an inherited PROFILE_TMP_DIR"
rm -rf -- "${inherited_tmp}"

(
  unset NODE_NAME NETWORK BRANCH
  CNODE_NAME="legacy-cnode-name"
  NODE_IMPLEMENTATION="dingo"
  NODE_PARENT="/tmp/guild-dispatcher-test"
  NETWORK="preprod"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  assert_eq "${NODE_NAME}" "dingo"
  assert_eq "${NODE_HOME}" "/tmp/guild-dispatcher-test/dingo"
)

(
  unset CNODE_NAME CNODE_PATH NETWORK BRANCH
  NODE_IMPLEMENTATION="dingo"
  NODE_PARENT="/tmp/guild-dispatcher-test"
  NODE_NAME="relay one"
  NETWORK_EXPLICIT="Y"
  NETWORK="preprod"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  assert_eq "${NODE_NAME}" "relay_one"
  assert_eq "${NODE_HOME}" "/tmp/guild-dispatcher-test/relay_one"
)

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guild-dispatcher-test.XXXXXX")"
TEST_DIR="$(cd "${TEST_DIR}" && pwd -P)"
LOCK_TEST_HOLDER_PID=""
LOCK_TEST_USER_PATH=""
LOCK_TEST_TARGET_PATH=""
CLEANUP_TEST_CALLER_PID=""
CLEANUP_TEST_STOP=""
cleanup_dispatcher_test() {
  if [[ -n "${CLEANUP_TEST_CALLER_PID}" ]]; then
    [[ -z "${CLEANUP_TEST_STOP}" ]] || : > "${CLEANUP_TEST_STOP}"
    kill -KILL "${CLEANUP_TEST_CALLER_PID}" 2>/dev/null || true
    wait "${CLEANUP_TEST_CALLER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${LOCK_TEST_HOLDER_PID}" ]]; then
    kill -KILL "${LOCK_TEST_HOLDER_PID}" 2>/dev/null || true
    wait "${LOCK_TEST_HOLDER_PID}" 2>/dev/null || true
  fi
  for lock_path in "${LOCK_TEST_TARGET_PATH}" "${LOCK_TEST_USER_PATH}"; do
    [[ -n "${lock_path}" && -d "${lock_path}" && ! -L "${lock_path}" ]] ||
      continue
    rm -f -- "${lock_path}/owner" 2>/dev/null || true
    rmdir -- "${lock_path}" 2>/dev/null || true
  done
  rm -rf "${TEST_DIR}"
}
trap cleanup_dispatcher_test EXIT

package_apt_success_fixture() {
  printf '%s\n' \
    'Get:1 https://example.invalid stable InRelease [123 kB]' \
    'N: Repository metadata changed its Suite value' \
    'W: Fixture warning remains visible' \
    '2 upgraded, 1 newly installed, 0 to remove and 4 not upgraded.' \
    'Setting up alpha (1.0-1) ...' \
    'Setting up beta:amd64 (2.0-1) ...' \
    'Reading package lists... Done'
}

package_dnf_success_fixture() {
  printf '%s\n' \
    'Downloading Packages:' \
    'Transaction Summary' \
    'Install  2 Packages' \
    'Installed:' \
    '  gamma.x86_64 1.0-1 repo' \
    '  delta.noarch 2.0-1 repo' \
    'Complete!'
}

package_dnf5_success_fixture() {
  printf '%s\n' \
    'Updating and loading repositories:' \
    'Repositories loaded.' \
    'Package Arch Version Repository Size' \
    'Installing:' \
    ' gamma x86_64 1.0-1 repo 1 MiB' \
    'Installing dependencies:' \
    ' delta noarch 2.0-1 repo 2 MiB' \
    'Upgrading:' \
    ' epsilon x86_64 3.0-1 repo 3 MiB' \
    'Transaction Summary:' \
    ' Installing: 2 packages' \
    ' Upgrading: 1 package' \
    'After this operation 6 MiB will be used.'
}

package_notice_overflow_fixture() {
  local notice_number
  for notice_number in {1..14}; do
    printf 'W: Fixture notice %d\n' "${notice_number}"
  done
}

package_failure_fixture() {
  local diagnostic_number
  printf '%s\n' \
    'Get:1 https://example.invalid stable InRelease' \
    'E: Unable to fetch fixture package metadata' >&2
  for diagnostic_number in {1..13}; do
    printf 'Error: Additional fixture failure %d\n' \
      "${diagnostic_number}" >&2
  done
  return 42
}

package_argv_fixture() {
  [[ "$1" == "argument with spaces" && "$2" == "--literal" ]]
}

compact_package_output="$(
  PACKAGE_MANAGER_OUTPUT="compact"
  TMPDIR="${TEST_DIR}"
  dispatcher_run_package_command \
    "fixture apt installation" package_apt_success_fixture 2>&1
)"
grep -F "Package transaction: 2 upgraded, 1 newly installed" \
  <<< "${compact_package_output}" >/dev/null ||
  fail "compact package output omitted the apt transaction summary"
grep -F "Changed packages: alpha, beta:amd64" \
  <<< "${compact_package_output}" >/dev/null ||
  fail "compact package output omitted changed apt packages"
grep -F "N: Repository metadata changed" \
  <<< "${compact_package_output}" >/dev/null ||
  fail "compact package output omitted an apt notice"
grep -F "W: Fixture warning remains visible" \
  <<< "${compact_package_output}" >/dev/null ||
  fail "compact package output omitted an apt warning"
if grep -F "Get:1" <<< "${compact_package_output}" >/dev/null; then
  fail "compact package output leaked apt download progress"
fi

compact_dnf_output="$(
  PACKAGE_MANAGER_OUTPUT="compact"
  TMPDIR="${TEST_DIR}"
  dispatcher_run_package_command \
    "fixture dnf installation" package_dnf_success_fixture 2>&1
)"
grep -F "Package transaction: Install  2 Packages" \
  <<< "${compact_dnf_output}" >/dev/null ||
  fail "compact package output omitted the dnf transaction summary"
grep -F "Changed packages: gamma.x86_64, delta.noarch" \
  <<< "${compact_dnf_output}" >/dev/null ||
  fail "compact package output omitted changed dnf packages"
if grep -F "Downloading Packages" <<< "${compact_dnf_output}" >/dev/null; then
  fail "compact package output leaked dnf download progress"
fi

compact_dnf5_output="$(
  PACKAGE_MANAGER_OUTPUT="compact"
  TMPDIR="${TEST_DIR}"
  dispatcher_run_package_command \
    "fixture dnf5 installation" package_dnf5_success_fixture 2>&1
)"
grep -F "Package transaction: Installing: 2 packages" \
  <<< "${compact_dnf5_output}" >/dev/null ||
  fail "compact package output omitted the dnf5 install summary"
grep -F "Package transaction: Upgrading: 1 package" \
  <<< "${compact_dnf5_output}" >/dev/null ||
  fail "compact package output omitted the dnf5 upgrade summary"
grep -F "Changed packages: gamma, delta, epsilon" \
  <<< "${compact_dnf5_output}" >/dev/null ||
  fail "compact package output omitted changed dnf5 packages"
if grep -F "Updating and loading repositories" \
  <<< "${compact_dnf5_output}" >/dev/null; then
  fail "compact package output leaked dnf5 repository progress"
fi

notice_overflow_output="$(
  PACKAGE_MANAGER_OUTPUT="compact"
  TMPDIR="${TEST_DIR}"
  dispatcher_run_package_command \
    "fixture notice overflow" package_notice_overflow_fixture 2>&1
)"
grep -F "2 additional package-manager notices omitted" \
  <<< "${notice_overflow_output}" >/dev/null ||
  fail "compact package output omitted its bounded-notice summary"
if grep -F '\n' <<< "${notice_overflow_output}" >/dev/null; then
  fail "compact package output rendered a literal newline escape"
fi

verbose_package_output="$(
  PACKAGE_MANAGER_OUTPUT="verbose"
  dispatcher_run_package_command \
    "fixture verbose installation" package_apt_success_fixture 2>&1
)"
grep -F "Get:1 https://example.invalid" \
  <<< "${verbose_package_output}" >/dev/null ||
  fail "verbose package output did not stream raw command output"
if grep -F "Package transaction:" <<< "${verbose_package_output}" >/dev/null; then
  fail "verbose package output duplicated the compact summary"
fi

set +e
failed_package_output="$(
  PACKAGE_MANAGER_OUTPUT="compact"
  TMPDIR="${TEST_DIR}"
  dispatcher_run_package_command \
    "fixture failed installation" package_failure_fixture 2>&1
)"
failed_package_status=$?
set -e
assert_eq "${failed_package_status}" "42"
grep -F "fixture failed installation failed (exit 42)" \
  <<< "${failed_package_output}" >/dev/null ||
  fail "compact package failure omitted its label and exit status"
grep -F "E: Unable to fetch fixture package metadata" \
  <<< "${failed_package_output}" >/dev/null ||
  fail "compact package failure hid package-manager diagnostics"
grep -F "2 additional diagnostic lines omitted" \
  <<< "${failed_package_output}" >/dev/null ||
  fail "compact package failure omitted its bounded-diagnostic summary"
if grep -F '\n' <<< "${failed_package_output}" >/dev/null; then
  fail "compact package failure rendered a literal newline escape"
fi
failed_package_log="$(
  sed -n 's/^  Full output: //p' <<< "${failed_package_output}"
)"
[[ -f "${failed_package_log}" ]] ||
  fail "compact package failure did not retain its full output"
if find "${failed_package_log}" ! -perm 0600 -print -quit | grep -q .; then
  fail "retained package failure output is not private"
fi
rm -f -- "${failed_package_log}"

PACKAGE_MANAGER_OUTPUT="compact" \
  dispatcher_run_package_command \
    "fixture argv preservation" package_argv_fixture \
    "argument with spaces" "--literal" ||
  fail "package runner did not preserve command arguments"

if find "${TEST_DIR}" -name 'guild-package-output.*' -print -quit |
  grep -q .; then
  fail "package runner left a temporary output file"
fi

mkdir -p "${TEST_DIR}/existing"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "deploymentStatus": "deployed",' \
  '  "implementation": "cnode",' \
  '  "network": "preview",' \
  '  "branch": "alpha",' \
  '  "repository": "guild-test-fork/guild-operators",' \
  '  "serviceName": "existing",' \
  '  "nodeVersion": "",' \
  '  "targetNodeVersion": "",' \
  '  "metricsProvider": "prometheus",' \
  '  "capabilities": {' \
  '    "n2c": true,' \
  '    "localCli": true,' \
  '    "metrics": true,' \
  '    "forging": true' \
  '  }' \
  '}' > "${TEST_DIR}/existing/.deployment.json"

(
  unset CNODE_NAME CNODE_PATH NETWORK BRANCH G_ACCOUNT
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="${TEST_DIR}"
  NODE_NAME="existing"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  G_ACCOUNT_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  assert_eq "${NETWORK}" "preview"
  assert_eq "${BRANCH}" "alpha"
  assert_eq "${G_ACCOUNT}" "guild-test-fork"
)

mkdir -p "${TEST_DIR}/incomplete"
jq 'del(.network) | .serviceName = "incomplete"' \
  "${TEST_DIR}/existing/.deployment.json" \
  > "${TEST_DIR}/incomplete/.deployment.json"
if (
  unset CNODE_NAME CNODE_PATH NETWORK BRANCH G_ACCOUNT
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="${TEST_DIR}"
  NODE_NAME="incomplete"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  G_ACCOUNT_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
) >/dev/null 2>&1; then
  fail "dispatcher accepted incomplete authoritative deployment metadata"
fi

validate_branch_name "feature/node-adapters" || fail "valid branch was rejected"
validate_branch_name "_alpha" || fail "Git-valid underscore-prefixed branch was rejected"
if validate_branch_name "../unsafe"; then
  fail "unsafe branch was accepted"
fi
for invalid_branch in \
  "feature/.hidden" \
  "feature/component.lock/child" \
  "feature/end." \
  'feature/@{unsafe'; do
  if validate_branch_name "${invalid_branch}"; then
    fail "Git-invalid branch was accepted: ${invalid_branch}"
  fi
done
(
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  deployment_branch_valid "_alpha" ||
    fail "runtime branch grammar rejected dispatcher-valid _alpha"
  for invalid_branch in \
    "feature/.hidden" \
    "feature/component.lock/child" \
    "feature/end." \
    'feature/@{unsafe'; do
    if deployment_branch_valid "${invalid_branch}"; then
      fail "runtime branch grammar accepted Git-invalid branch: ${invalid_branch}"
    fi
  done
)
if validate_implementation "unknown"; then
  fail "unknown implementation was accepted"
fi

mkdir -p "${TEST_DIR}/physical-target"
ln -s "${TEST_DIR}/physical-target" "${TEST_DIR}/target-alias"
physical_lock_key="$(
  NODE_HOME="${TEST_DIR}/physical-target/node"
  dispatcher_lock_key
)"
alias_lock_key="$(
  NODE_HOME="${TEST_DIR}/target-alias/./redundant/../node"
  dispatcher_lock_key
)"
assert_eq "${alias_lock_key}" "${physical_lock_key}"
(
  NODE_HOME="${TEST_DIR}/target-alias/./node"
  canonical_target="$(dispatcher_canonical_target_path "${NODE_HOME}")"
  GUILD_DEPLOY_LOCK_HELD_FOR="${canonical_target}"
  export GUILD_DEPLOY_LOCK_HELD_FOR
  unset DISPATCHER_LOCK_KIND DISPATCHER_LOCK_PATH
  unset DISPATCHER_LOCK_CANONICAL_TARGET DISPATCHER_LOCK_OWNER_PID
  unset DEPLOYMENT_TARGET_LOCK_OWNED
  deployment_target_lock_acquire "${NODE_HOME}"
  assert_eq "${DEPLOYMENT_TARGET_LOCK_OWNED}" "Y"
  dispatcher_target_lock_is_owned "${TEST_DIR}/physical-target/node" ||
    fail "dispatcher did not own the canonical target lock after ignoring forged reentrancy metadata"
  deployment_target_lock_release
)

# Directory locks must not prevent transaction-journal recovery after an
# uncatchable process death. Kill a real lock holder, then prove the next
# dispatcher safely quarantines both stale owner-marked locks and proceeds.
if (( BASH_VERSINFO[0] > 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  NODE_HOME="${TEST_DIR}/physical-target/stale-node"
  lock_base="/tmp/guild-operators-deployment-locks-$(id -u)"
  lock_key="$(dispatcher_lock_key "${NODE_HOME}")"
  LOCK_TEST_USER_PATH="${lock_base}/user.lock.d"
  LOCK_TEST_TARGET_PATH="${lock_base}/${lock_key}.lock.d"
  ready="${TEST_DIR}/directory-lock.ready"
  export GUILD_DEPLOY_LOCK_BACKEND=directory

  (
    dispatcher_acquire_target_lock
    printf 'ready\n' > "${ready}"
    while :; do sleep 1; done
  ) &
  LOCK_TEST_HOLDER_PID=$!
  for _ in {1..50}; do
    [[ -s "${ready}" ]] && break
    sleep 0.1
  done
  [[ -s "${ready}" ]] || fail "directory-lock holder did not become ready"
  kill -KILL "${LOCK_TEST_HOLDER_PID}"
  wait "${LOCK_TEST_HOLDER_PID}" 2>/dev/null || true
  LOCK_TEST_HOLDER_PID=""
  [[ -d "${LOCK_TEST_USER_PATH}" && -d "${LOCK_TEST_TARGET_PATH}" ]] ||
    fail "killed directory-lock holder did not leave recoverable lock state"

  dispatcher_acquire_target_lock
  dispatcher_target_lock_is_owned "${NODE_HOME}" ||
    fail "dispatcher did not recover and own stale directory locks"
  dispatcher_release_target_lock
  [[ ! -e "${LOCK_TEST_USER_PATH}" && ! -e "${LOCK_TEST_TARGET_PATH}" ]] ||
    fail "recovered directory locks were not released"
fi

# Cleanup must synchronously release the dedicated generation-lock holder
# before it releases the ordinary target lock, even while a durable outer
# journal remains for authenticated recovery. Keep the old caller alive after
# cleanup and prove that a real second process can acquire both locks.
cleanup_lock_parent="${TEST_DIR}/cleanup-generation-lock"
mkdir -p -- "${cleanup_lock_parent}"
cleanup_lock_parent="$(cd -P -- "${cleanup_lock_parent}" && pwd -P)"
cleanup_lock_target="${cleanup_lock_parent}/node"
cleanup_lock_root="${cleanup_lock_target}/scripts/.cntools"
cleanup_lock_journal="${cleanup_lock_target}/.guild-deploy-transaction"
cleanup_lock_ready="${TEST_DIR}/cleanup-generation-lock.ready"
cleanup_lock_start="${TEST_DIR}/cleanup-generation-lock.start"
cleanup_lock_complete="${TEST_DIR}/cleanup-generation-lock.complete"
cleanup_lock_ordered="${TEST_DIR}/cleanup-generation-lock.ordered"
CLEANUP_TEST_STOP="${TEST_DIR}/cleanup-generation-lock.stop"
cleanup_lock_output="${TEST_DIR}/cleanup-generation-lock.output"
mkdir -p -- "${cleanup_lock_root}/generations" "${cleanup_lock_journal}"
chmod 0700 "${cleanup_lock_target}" \
  "${cleanup_lock_target}/scripts" "${cleanup_lock_root}" \
  "${cleanup_lock_root}/generations" "${cleanup_lock_journal}"

"${BASH}" --noprofile --norc -c '
  set -euo pipefail
  dispatcher=$1; lifecycle=$2; node_home=$3; root=$4; ready=$5
  start=$6; complete=$7; ordered=$8; stop=$9
  # shellcheck source=/dev/null
  . "${dispatcher}"
  # shellcheck source=/dev/null
  . "${lifecycle}"
  NODE_HOME="${node_home}"
  dispatcher_acquire_target_lock
  cntools_generation_deployment_lock_acquire "${root}" Y
  DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT="${root}"
  DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED=Y
  DISPATCHER_TX_ACTIVE=N
  DISPATCHER_TX_PREPARE_ROOT=""
  DISPATCHER_TX_STAGE_ROOT=""
  DISPATCHER_DOCKER_EXPORT_STAGE=""
  DISPATCHER_PROFILE_TMP_OWNED=N
  generation_holder="${CNTOOLS_GENERATION_LOCK_HOLDER_PID}"
  release_definition="$(declare -f dispatcher_release_target_lock)"
  release_definition="${release_definition/#dispatcher_release_target_lock /dispatcher_release_target_lock_real }"
  eval "${release_definition}"
  declare -F dispatcher_release_target_lock_real >/dev/null
  dispatcher_release_target_lock() {
    [[ "${DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED:-N}" == N ]]
    ! kill -0 "${generation_holder}" 2>/dev/null
    (umask 077 && printf "generation-before-target\n" > "${ordered}")
    dispatcher_release_target_lock_real
  }
  caller_pid="${BASHPID:-$$}"
  (umask 077 && printf "%s\t%s\n" \
    "${caller_pid}" "${generation_holder}" > "${ready}")
  while [[ ! -e "${start}" && ! -L "${start}" ]]; do sleep 0.1; done
  cleanup_dispatcher 0
  ! kill -0 "${generation_holder}" 2>/dev/null
  (umask 077 && printf "%s\t%s\n" \
    "${caller_pid}" "${generation_holder}" > "${complete}")
  while [[ ! -e "${stop}" && ! -L "${stop}" ]]; do sleep 0.1; done
' bash "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  "${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/lifecycle.sh" \
  "${cleanup_lock_target}" "${cleanup_lock_root}" "${cleanup_lock_ready}" \
  "${cleanup_lock_start}" "${cleanup_lock_complete}" \
  "${cleanup_lock_ordered}" "${CLEANUP_TEST_STOP}" \
  > "${cleanup_lock_output}" 2>&1 &
CLEANUP_TEST_CALLER_PID=$!
for _ in {1..100}; do
  [[ -s "${cleanup_lock_ready}" ]] && break
  kill -0 "${CLEANUP_TEST_CALLER_PID}" 2>/dev/null || break
  sleep 0.1
done
if [[ ! -s "${cleanup_lock_ready}" ]]; then
  sed -n '1,120p' "${cleanup_lock_output}" >&2 || true
  fail "cleanup generation-lock holder did not become ready"
fi
IFS=$'\t' read -r cleanup_caller cleanup_holder < "${cleanup_lock_ready}"
[[ "${cleanup_caller}" =~ ^[0-9]+$ && "${cleanup_holder}" =~ ^[0-9]+$ &&
   "${cleanup_caller}" != "${cleanup_holder}" ]] ||
  fail "cleanup fixture reported invalid caller/holder process IDs"
kill -0 "${cleanup_caller}" 2>/dev/null &&
  kill -0 "${cleanup_holder}" 2>/dev/null ||
  fail "cleanup fixture did not retain live caller and holder processes"
: > "${cleanup_lock_start}"
for _ in {1..100}; do
  [[ -s "${cleanup_lock_complete}" ]] && break
  kill -0 "${CLEANUP_TEST_CALLER_PID}" 2>/dev/null || break
  sleep 0.1
done
if [[ ! -s "${cleanup_lock_complete}" ]]; then
  sed -n '1,120p' "${cleanup_lock_output}" >&2 || true
  fail "dispatcher cleanup did not synchronously release its generation holder"
fi
[[ "$(< "${cleanup_lock_ordered}")" == generation-before-target ]] ||
  fail "dispatcher cleanup released the target lock before generation holder"
kill -0 "${cleanup_caller}" 2>/dev/null ||
  fail "old dispatcher caller exited before post-cleanup contention"
if kill -0 "${cleanup_holder}" 2>/dev/null; then
  fail "dispatcher cleanup returned before its generation holder exited"
fi
[[ -d "${cleanup_lock_journal}" && ! -L "${cleanup_lock_journal}" ]] ||
  fail "dispatcher cleanup removed the durable outer journal"

if ! "${BASH}" --noprofile --norc -c '
  set -euo pipefail
  dispatcher=$1; lifecycle=$2; node_home=$3; root=$4
  # shellcheck source=/dev/null
  . "${dispatcher}"
  # shellcheck source=/dev/null
  . "${lifecycle}"
  NODE_HOME="${node_home}"
  dispatcher_acquire_target_lock
  release_target() { dispatcher_release_target_lock || true; }
  trap release_target EXIT
  cntools_generation_deployment_lock_acquire "${root}" Y
  cntools_generation_lock_release "${root}"
  dispatcher_release_target_lock
  trap - EXIT
' bash "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  "${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/lifecycle.sh" \
  "${cleanup_lock_target}" "${cleanup_lock_root}"; then
  fail "real contender could not acquire locks after dispatcher cleanup"
fi
: > "${CLEANUP_TEST_STOP}"
if ! wait "${CLEANUP_TEST_CALLER_PID}"; then
  sed -n '1,120p' "${cleanup_lock_output}" >&2 || true
  fail "old dispatcher caller failed after cleanup contention"
fi
CLEANUP_TEST_CALLER_PID=""
CLEANUP_TEST_STOP=""
(
  NODE_HOME="${TEST_DIR}/target-alias/./node"
  canonical_target="$(dispatcher_canonical_target_path "${NODE_HOME}")"
  GUILD_DEPLOY_LOCK_HELD_FOR="${canonical_target}"
  export GUILD_DEPLOY_LOCK_HELD_FOR
  unset DISPATCHER_LOCK_KIND DISPATCHER_LOCK_PATH
  unset DISPATCHER_LOCK_CANONICAL_TARGET DISPATCHER_LOCK_OWNER_PID
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  deployment_target_lock_acquire "${NODE_HOME}"
  assert_eq "${DEPLOYMENT_TARGET_LOCK_OWNED}" "Y"
  deployment_local_lock_is_owned "${canonical_target}" ||
    fail "runtime library did not take a real lock after ignoring forged reentrancy metadata"
  deployment_target_lock_release
)

runtime_stale_target="${TEST_DIR}/physical-target/runtime-stale-node"
runtime_stale_key="$(dispatcher_lock_key "${runtime_stale_target}")"
LOCK_TEST_TARGET_PATH="/tmp/guild-operators-deployment-locks-$(id -u)/${runtime_stale_key}.lock.d"
dead_owner_pid=99999999
while kill -0 "${dead_owner_pid}" 2>/dev/null; do
  dead_owner_pid=$((dead_owner_pid + 1))
done
mkdir -- "${LOCK_TEST_TARGET_PATH}"
printf '%s\tpid-only\n' "${dead_owner_pid}" > "${LOCK_TEST_TARGET_PATH}/owner"
chmod 0600 "${LOCK_TEST_TARGET_PATH}/owner"
(
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  export GUILD_DEPLOY_LOCK_BACKEND=directory
  NODE_HOME="${runtime_stale_target}"
  deployment_target_lock_acquire "${NODE_HOME}"
  deployment_local_lock_is_owned "$(deployment_canonical_target_path "${NODE_HOME}")" ||
    fail "runtime library did not recover its stale directory lock"
  deployment_target_lock_release
)
[[ ! -e "${LOCK_TEST_TARGET_PATH}" ]] ||
  fail "runtime library stale directory lock was not released"
LOCK_TEST_TARGET_PATH=""

path_injection_marker="${TEST_DIR}/path-injection-ran"
if (
  unset CNODE_NAME CNODE_PATH NODE_NAME NETWORK BRANCH
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="${TEST_DIR}/unsafe\$(touch${IFS}${path_injection_marker})"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
) >/dev/null 2>&1; then
  fail "dispatcher accepted shell syntax in a deployment path"
fi
[[ ! -e "${path_injection_marker}" ]] ||
  fail "deployment path validation executed injected shell syntax"

if (
  unset CNODE_NAME CNODE_PATH NODE_NAME NETWORK BRANCH
  NODE_IMPLEMENTATION="amaru"
  NODE_PARENT="${TEST_DIR}"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
) >/dev/null 2>&1; then
  fail "alternate implementation accepted an implicit network"
fi

mkdir -p "${TEST_DIR}/future_schema"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 2,' \
  '  "deploymentStatus": "deployed",' \
  '  "implementation": "cnode",' \
  '  "network": "mainnet",' \
  '  "branch": "master",' \
  '  "serviceName": "future-schema"' \
  '}' > "${TEST_DIR}/future_schema/.deployment.json"
if (
  unset CNODE_NAME CNODE_PATH NETWORK BRANCH
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="${TEST_DIR}"
  NODE_NAME="future-schema"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
) >/dev/null 2>&1; then
  fail "dispatcher accepted a future deployment manifest schema"
fi

for invalid_manifest_case in zero-byte dangling-symlink; do
  invalid_manifest_dir="${invalid_manifest_case//-/_}"
  mkdir -p "${TEST_DIR}/${invalid_manifest_dir}"
  case "${invalid_manifest_case}" in
    zero-byte)
      : > "${TEST_DIR}/${invalid_manifest_dir}/.deployment.json"
      ;;
    dangling-symlink)
      ln -s "${TEST_DIR}/${invalid_manifest_dir}/missing.json" \
        "${TEST_DIR}/${invalid_manifest_dir}/.deployment.json"
      ;;
  esac
  if (
    unset CNODE_NAME CNODE_PATH NETWORK BRANCH G_ACCOUNT
    NODE_IMPLEMENTATION="cnode"
    NODE_PARENT="${TEST_DIR}"
    NODE_NAME="${invalid_manifest_case}"
    NETWORK_EXPLICIT="N"
    NETWORK_PRESET="N"
    BRANCH_EXPLICIT="N"
    BRANCH_PRESET="N"
    G_ACCOUNT_PRESET="N"
    SUDO="N"
    UPDATE_CHECK="N"
    dispatcher_set_defaults
  ) >/dev/null 2>&1; then
    fail "dispatcher accepted ${invalid_manifest_case} deployment metadata"
  fi
  if (
    NODE_HOME="${TEST_DIR}/${invalid_manifest_dir}"
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
    deployment_set_branch "_alpha"
  ) >/dev/null 2>&1; then
    fail "runtime branch update accepted ${invalid_manifest_case} deployment metadata"
  fi
done

for semantic_case in cnode-metrics dingo-capability amaru-capability extra-capability; do
  semantic_dir="${semantic_case//-/_}"
  mkdir -p "${TEST_DIR}/${semantic_dir}"
  case "${semantic_case}" in
    cnode-metrics)
      jq --arg service "${semantic_dir}" \
        '.serviceName = $service | .metricsProvider = "otel"' \
        "${TEST_DIR}/existing/.deployment.json" \
        > "${TEST_DIR}/${semantic_dir}/.deployment.json"
      semantic_implementation="cnode"
      ;;
    dingo-capability)
      jq --arg service "${semantic_dir}" '
        .serviceName = $service |
        .implementation = "dingo" |
        .network = "preprod" |
        .capabilities.localCli = false |
        .capabilities.forging = false
      ' "${TEST_DIR}/existing/.deployment.json" \
        > "${TEST_DIR}/${semantic_dir}/.deployment.json"
      semantic_implementation="dingo"
      ;;
    amaru-capability)
      jq --arg service "${semantic_dir}" '
        .serviceName = $service |
        .implementation = "amaru" |
        .network = "preview" |
        .metricsProvider = "otel" |
        .capabilities.n2c = false |
        .capabilities.localCli = false |
        .capabilities.metrics = false |
        .capabilities.forging = false
      ' "${TEST_DIR}/existing/.deployment.json" \
        > "${TEST_DIR}/${semantic_dir}/.deployment.json"
      semantic_implementation="amaru"
      ;;
    extra-capability)
      jq --arg service "${semantic_dir}" '
        .serviceName = $service |
        .capabilities.experimental = false
      ' "${TEST_DIR}/existing/.deployment.json" \
        > "${TEST_DIR}/${semantic_dir}/.deployment.json"
      semantic_implementation="cnode"
      ;;
  esac
  if (
    unset CNODE_NAME CNODE_PATH NETWORK BRANCH G_ACCOUNT
    NODE_IMPLEMENTATION="${semantic_implementation}"
    NODE_PARENT="${TEST_DIR}"
    NODE_NAME="${semantic_case}"
    NETWORK_EXPLICIT="N"
    NETWORK_PRESET="N"
    BRANCH_EXPLICIT="N"
    BRANCH_PRESET="N"
    G_ACCOUNT_PRESET="N"
    SUDO="N"
    UPDATE_CHECK="N"
    dispatcher_set_defaults
  ) >/dev/null 2>&1; then
    fail "dispatcher accepted inconsistent ${semantic_case} manifest semantics"
  fi
  if (
    NODE_HOME="${TEST_DIR}/${semantic_dir}"
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
    deployment_set_branch "_alpha"
  ) >/dev/null 2>&1; then
    fail "runtime branch update accepted inconsistent ${semantic_case} manifest semantics"
  fi
done

mkdir -p "${TEST_DIR}/partial_dingo/scripts/adapters"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'NODE_ADAPTER_IMPLEMENTATION="dingo"' \
  > "${TEST_DIR}/partial_dingo/scripts/adapters/dingo.adapter"
(
  unset CNODE_NAME CNODE_PATH NETWORK BRANCH
  NODE_IMPLEMENTATION="dingo"
  NODE_PARENT="${TEST_DIR}"
  NODE_NAME="partial-dingo"
  NETWORK="preprod"
  NETWORK_EXPLICIT="Y"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
  assert_eq "${NODE_HOME}" "${TEST_DIR}/partial_dingo"
)

mkdir -p "${TEST_DIR}/legacy_network_conflict/files"
printf '%s\n' '{}' > "${TEST_DIR}/legacy_network_conflict/files/config.json"
printf '%s\n' '{"networkMagic": 2}' \
  > "${TEST_DIR}/legacy_network_conflict/files/shelley-genesis.json"
if (
  unset CNODE_NAME CNODE_PATH BRANCH
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="${TEST_DIR}"
  NODE_NAME="legacy-network-conflict"
  NETWORK="mainnet"
  NETWORK_EXPLICIT="N"
  NETWORK_PRESET="Y"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
  UPDATE_CHECK="N"
  dispatcher_set_defaults
) >/dev/null 2>&1; then
  fail "legacy target accepted a preset network conflicting with genesis"
fi

transaction_target="${TEST_DIR}/transaction_progress"
mkdir -p "${transaction_target}/scripts"
jq '.serviceName = "transaction_progress"' \
  "${TEST_DIR}/existing/.deployment.json" \
  > "${transaction_target}/.deployment.json"
printf 'legacy-branch\n' > "${transaction_target}/scripts/.env_branch"
transaction_manifest_checksum="$(dispatcher_sha256 \
  "${transaction_target}/.deployment.json")"
(
  # This focused fixture exercises only the ordinary payload transaction. Use
  # the implementation whose contract deliberately has no CNTools generation.
  NODE_IMPLEMENTATION="amaru"
  NODE_HOME="${transaction_target}"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  DISPATCHER_TX_STAGE_ROOT="${TEST_DIR}/transaction-progress-stage"
  DISPATCHER_TX_CANDIDATE_ROOT="${DISPATCHER_TX_STAGE_ROOT}/candidates"
  DISPATCHER_TX_PLAN="${DISPATCHER_TX_STAGE_ROOT}/plan.tsv"
  DISPATCHER_TX_PREPARED="Y"
  DISPATCHER_TX_ACTIVE="N"
  DISPATCHER_TX_ACTIVATED="N"
  GUILD_DEPLOY_LOCK_BACKEND=directory
  dispatcher_acquire_target_lock
  trap 'dispatcher_release_target_lock' EXIT
  mkdir -p "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts"
  printf '#!/usr/bin/env bash\nprintf "transaction fixture\\n"\n' \
    > "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts/progress.sh"
  chmod 0755 "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts/progress.sh"
  transaction_source_hash="$(dispatcher_sha256 \
    "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts/progress.sh")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'scripts/fixture/progress.sh' 'scripts/progress.sh' '0755' \
    'exact' 'exact' 'shell' "${transaction_source_hash}" \
    > "${DISPATCHER_TX_PLAN}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    '-' 'scripts/.env_branch' '-' 'retire' 'retire' '-' '-' \
    >> "${DISPATCHER_TX_PLAN}"
  dispatcher_distribution_validate_candidates() { return 0; }

  dispatcher_distribution_activate
  assert_eq \
    "$(jq -r '.deploymentStatus' "${DEPLOYMENT_FILE}")" \
    "deployed"
  assert_eq \
    "$(dispatcher_sha256 "${DEPLOYMENT_FILE}")" \
    "${transaction_manifest_checksum}"
  assert_eq \
    "$(sed -n '3p' "${NODE_HOME}/.guild-deploy-transaction/journal")" \
    "state=activated"
  find "${NODE_HOME}/.guild-deploy-transaction/journal" \
    -prune -perm 0600 -print | grep -q . ||
    fail "transaction progress journal is not private"
  [[ ! -e "${NODE_HOME}/scripts/.env_branch" ]] ||
    fail "retired sidecar remained active inside the payload transaction"

  dispatcher_mark_in_progress
  dispatcher_write_manifest deploying
  assert_eq \
    "$(dispatcher_sha256 "${DEPLOYMENT_FILE}")" \
    "${transaction_manifest_checksum}"
  assert_eq \
    "$(sed -n '3p' "${NODE_HOME}/.guild-deploy-transaction/journal")" \
    "state=activated"

  dispatcher_distribution_rollback
  assert_eq \
    "$(dispatcher_sha256 "${DEPLOYMENT_FILE}")" \
    "${transaction_manifest_checksum}"
  [[ ! -e "${NODE_HOME}/.guild-deploy-transaction" ]] ||
    fail "rolled-back transaction left its private journal"
  [[ ! -e "${NODE_HOME}/scripts/progress.sh" ]] ||
    fail "rolled-back transaction left an activated payload"
  [[ -f "${NODE_HOME}/scripts/.env_branch" ]] ||
    fail "rollback did not restore a retired legacy sidecar"
  dispatcher_release_target_lock
  trap - EXIT
)

mkdir -p "${TEST_DIR}/manifest-outside-transaction"
if (
  NODE_HOME="${TEST_DIR}/manifest-outside-transaction"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  DISPATCHER_TX_ACTIVE="N"
  DISPATCHER_TX_ACTIVATED="N"
  dispatcher_write_manifest deployed
) >/dev/null 2>&1; then
  fail "dispatcher published canonical metadata outside a complete payload transaction"
fi
[[ ! -e "${TEST_DIR}/manifest-outside-transaction/.deployment.json" ]] ||
  fail "rejected metadata publication created a canonical manifest"

failed_profile_target="${TEST_DIR}/failed_profile"
mkdir -p "${failed_profile_target}"
jq '.serviceName = "failed_profile" | .network = "mainnet"' \
  "${TEST_DIR}/existing/.deployment.json" \
  > "${failed_profile_target}/.deployment.json"
failed_profile_checksum="$(dispatcher_sha256 \
  "${failed_profile_target}/.deployment.json")"
if (
  GUILD_SOURCE_HANDOFF_ACTIVE="Y"
  guild_source_adopt_handoff() {
    _GUILD_SOURCE_PREPARED="Y"
    return 0
  }
  dispatcher_set_defaults() {
    NODE_IMPLEMENTATION="cnode"
    NODE_PARENT="${TEST_DIR}"
    NODE_NAME="failed_profile"
    NODE_HOME="${failed_profile_target}"
    NODE_SERVICE="failed_profile"
    NETWORK="mainnet"
    BRANCH="alpha"
    G_ACCOUNT="cardano-community"
    DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  }
  dispatcher_verify_target_fingerprint() { return 0; }
  dispatcher_update_check() { return 0; }
  dispatcher_load_profile() { PROFILE_ENTRYPOINT="failing_profile"; }
  dispatcher_distribution_prepare() {
    DISPATCHER_TX_STAGE_ROOT="${TEST_DIR}/failed-profile-stage"
    DISPATCHER_TX_CANDIDATE_ROOT="${DISPATCHER_TX_STAGE_ROOT}/candidates"
    DISPATCHER_TX_PLAN="${DISPATCHER_TX_STAGE_ROOT}/plan.tsv"
    mkdir -p "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' \
      > "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts/failure.sh"
    chmod 0755 "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts/failure.sh"
    failure_source_hash="$(dispatcher_sha256 \
      "${DISPATCHER_TX_CANDIDATE_ROOT}/scripts/failure.sh")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      'scripts/fixture/failure.sh' 'scripts/failure.sh' '0755' \
      'exact' 'exact' 'shell' "${failure_source_hash}" \
      > "${DISPATCHER_TX_PLAN}"
    DISPATCHER_TX_PREPARED="Y"
  }
  dispatcher_distribution_validate_candidates() { return 0; }
  failing_profile() {
    dispatcher_distribution_activate
    return 1
  }
  dispatcher_release_target_lock() { return 0; }
  guild_source_release() { return 0; }
  unset NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NETWORK BRANCH
  SUDO="N"
  guild_deploy_main \
    -i cnode \
    -n mainnet \
    -p "${TEST_DIR}" \
    -t failed-profile \
    -u
) >/dev/null 2>&1; then
  fail "dispatcher reported success after an activated deployment profile failed"
fi
assert_eq \
  "$(dispatcher_sha256 "${failed_profile_target}/.deployment.json")" \
  "${failed_profile_checksum}"
assert_eq \
  "$(jq -r '.deploymentStatus' "${failed_profile_target}/.deployment.json")" \
  "deployed"
[[ ! -e "${failed_profile_target}/.guild-deploy-transaction" ]] ||
  fail "failed profile left its private transaction journal"
[[ ! -e "${failed_profile_target}/scripts/failure.sh" ]] ||
  fail "failed profile left an activated payload file"

# Source preparation and handoff integrity have dedicated suites. Keep this
# dispatcher routing test narrow: the first pass must delegate the original
# request to the source-preparation collaborator without touching the target.
source_route_args="${TEST_DIR}/source-route.args"
if ! (
  unset GUILD_SOURCE_HANDOFF_ACTIVE
  dispatcher_set_defaults() { return 0; }
  dispatcher_prepare_source_and_handoff() {
    printf '<%s>\n' "$@" > "${source_route_args}"
  }
  guild_source_release() { return 0; }
  unset NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NETWORK BRANCH
  SUDO="N"
  guild_deploy_main \
    -i dingo \
    -n preprod \
    -p "${TEST_DIR}" \
    -t source-route \
    -u
) >/dev/null 2>&1; then
  fail "dispatcher first pass did not delegate to source preparation"
fi
grep -Fx '<-i>' "${source_route_args}" >/dev/null ||
  fail "source preparation did not receive the original implementation option"
grep -Fx '<source-route>' "${source_route_args}" >/dev/null ||
  fail "source preparation did not receive the original target option"
[[ ! -e "${TEST_DIR}/source_route" ]] ||
  fail "source-routing pass unexpectedly mutated a deployment target"

branch_target="${TEST_DIR}/branch_delegation"
branch_dispatcher="${branch_target}/scripts/guild-deploy.sh"
branch_dispatch_log="${TEST_DIR}/branch-delegation.calls"
mkdir -p "${branch_target}/scripts"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'dispatcher_prepare_source_and_handoff() { :; }' \
  'dispatcher_distribution_prepare() { :; }' \
  ': "${GUILD_SOURCE_CHECK_ONLY:=N}"' \
  '{' \
  '  printf "%s" "${GUILD_SOURCE_CHECK_ONLY}"' \
  '  printf " <%s>" "$@"' \
  '  printf "\\n"' \
  '} >> "${BRANCH_DISPATCH_LOG:?}"' \
  'available_revision=2222222222222222222222222222222222222222' \
  'if [[ "${GUILD_SOURCE_CHECK_ONLY}" == "Y" ]]; then' \
  '  printf "%s\\n" "${available_revision}"' \
  '  exit 10' \
  'fi' \
  '[[ "${GUILD_SOURCE_EXPECT_REVISION:-}" == "${available_revision}" ]] || exit 66' \
  'exit 0' \
  > "${branch_dispatcher}"
chmod 0755 "${branch_dispatcher}"
branch_dispatcher_hash="$(dispatcher_sha256 "${branch_dispatcher}")"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "implementation": "cnode",' \
  '  "network": "mainnet",' \
  '  "source": {' \
  '    "repository": "cardano-community/guild-operators",' \
  '    "channel": "master",' \
  '    "ref": "refs/heads/master",' \
  '    "revision": "1111111111111111111111111111111111111111",' \
  '    "mode": "managed",' \
  '    "dirty": false' \
  '  },' \
  '  "files": [' \
  "    {\"path\":\"scripts/guild-deploy.sh\",\"source\":\"scripts/cnode-helper-scripts/guild-deploy.sh\",\"mode\":\"0755\",\"policy\":\"merge-header\",\"sourceSha256\":\"${branch_dispatcher_hash}\",\"installedSha256\":\"${branch_dispatcher_hash}\",\"managed\":true}" \
  '  ]' \
  '}' > "${branch_target}/.guild-source-receipt.json"
branch_receipt_hash="$(dispatcher_sha256 \
  "${branch_target}/.guild-source-receipt.json")"
branch_transaction_id="${branch_receipt_hash:0:24}"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "deploymentStatus": "deployed",' \
  '  "implementation": "cnode",' \
  '  "network": "mainnet",' \
  '  "branch": "master",' \
  '  "repository": "cardano-community/guild-operators",' \
  '  "sourceSchemaVersion": 1,' \
  '  "sourceMode": "managed",' \
  '  "sourceRef": "refs/heads/master",' \
  '  "sourceRevision": "1111111111111111111111111111111111111111",' \
  '  "sourceDirty": false,' \
  '  "payloadReceipt": ".guild-source-receipt.json",' \
  "  \"payloadReceiptSha256\": \"${branch_receipt_hash}\"," \
  "  \"transactionId\": \"${branch_transaction_id}\"," \
  '  "serviceName": "branch_delegation",' \
  '  "nodeVersion": "",' \
  '  "targetNodeVersion": "",' \
  '  "metricsProvider": "prometheus",' \
  '  "capabilities": {' \
  '    "n2c": true,' \
  '    "localCli": true,' \
  '    "metrics": true,' \
  '    "forging": true' \
  '  }' \
  '}' > "${branch_target}/.deployment.json"
branch_metadata_checksum="$(dispatcher_sha256 \
  "${branch_target}/.deployment.json")"
: > "${branch_dispatch_log}"
(
  NODE_HOME="${branch_target}"
  GUILD_SOURCE_MODE="managed"
  BRANCH_DISPATCH_LOG="${branch_dispatch_log}"
  export GUILD_SOURCE_MODE BRANCH_DISPATCH_LOG
  unset GUILD_PAYLOAD_REFRESH_STATE GUILD_PAYLOAD_REFRESH_SIGNATURE
  unset GUILD_PAYLOAD_REFRESH_RESULT
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  # This case verifies branch/delegation arguments only; its one-file receipt
  # is intentionally not a complete deployable payload. Exact cross-version
  # currentness is exercised by common-runtime.sh.
  deployment_payload_is_current() { return 0; }
  if ! deployment_set_branch "_alpha"; then
    fail "branch change did not delegate through the installed dispatcher"
  fi
)
assert_eq "$(wc -l < "${branch_dispatch_log}" | tr -d ' ')" "2"
assert_eq "$(sed -n '1s/ .*//p' "${branch_dispatch_log}")" "Y"
assert_eq "$(sed -n '2s/ .*//p' "${branch_dispatch_log}")" "N"
if [[ "$(sed -n '1p' "${branch_dispatch_log}")" != *' <-b> <_alpha>'* ||
      "$(sed -n '2p' "${branch_dispatch_log}")" != *' <-b> <_alpha>'* ]]; then
  fail "complete dispatcher did not receive the requested branch"
fi
if [[ "$(sed -n '2p' "${branch_dispatch_log}")" != *' <-a> <cardano-community>'* ||
      "$(sed -n '2p' "${branch_dispatch_log}")" != *' <-S> <managed>'* ]]; then
  fail "complete dispatcher did not receive authoritative source identity"
fi
assert_eq \
  "$(dispatcher_sha256 "${branch_target}/.deployment.json")" \
  "${branch_metadata_checksum}"
assert_eq "$(jq -r '.branch' "${branch_target}/.deployment.json")" "master"

atomic_bootstrap="${TEST_DIR}/atomic-bootstrap.sh"
awk '
  /^#CURL_TIMEOUT=60/ {
    print "CURL_TIMEOUT=17                     # operator customization"
    next
  }
  { print }
  END { print "# stale runtime fixture" }
' "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  > "${atomic_bootstrap}"
chmod 0755 "${atomic_bootstrap}"
atomic_bootstrap_checksum="$(dispatcher_sha256 "${atomic_bootstrap}")"
update_driver="${TEST_DIR}/update-driver.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '. "${DISPATCHER_SOURCE:?}"' \
  'UPDATE_CHECK="Y"' \
  'GUILD_SOURCE_LAUNCHER_LOCAL_REPO="N"' \
  'GUILD_SOURCE_LAUNCHER_MANAGED_TARGET="N"' \
  'GUILD_SOURCE_LAUNCHER_PATH="${BOOTSTRAP_UNDER_TEST:?}"' \
  'guild_source_path() {' \
  '  [[ "$1" == "scripts/cnode-helper-scripts/guild-deploy.sh" ]] || return 2' \
  '  printf "%s\\n" "${SNAPSHOT_DISPATCHER:?}"' \
  '}' \
  'guild_source_revision() {' \
  '  printf "%s\\n" "2222222222222222222222222222222222222222"' \
  '}' \
  'mv() { return 1; }' \
  'dispatcher_update_check' \
  > "${update_driver}"
chmod 0755 "${update_driver}"
if DISPATCHER_SOURCE="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  SNAPSHOT_DISPATCHER="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  BOOTSTRAP_UNDER_TEST="${atomic_bootstrap}" \
  "${BASH}" "${update_driver}" >/dev/null 2>&1; then
  fail "snapshot-based dispatcher update ignored an atomic replacement failure"
fi
assert_eq \
  "$(dispatcher_sha256 "${atomic_bootstrap}")" \
  "${atomic_bootstrap_checksum}"
if find "${TEST_DIR}" \
  \( -name '.atomic-bootstrap.sh.source.*' -o -name '.atomic-bootstrap.sh.merged.*' \) \
  -print -quit | grep -q .; then
  fail "failed snapshot-based dispatcher update left a staging file"
fi

custom_dispatcher="${TEST_DIR}/custom-dispatcher.sh"
awk '
  /^#CURL_TIMEOUT=60/ {
    print "CURL_TIMEOUT=17                     # operator customization"
    next
  }
  { print }
' "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" > "${custom_dispatcher}"
chmod 0755 "${custom_dispatcher}"
custom_dispatcher_checksum="$(dispatcher_sha256 "${custom_dispatcher}")"
update_output="$(
  DISPATCHER_SOURCE="${custom_dispatcher}" \
  SNAPSHOT_DISPATCHER="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  "${BASH}" -c '
    . "${DISPATCHER_SOURCE}"
    UPDATE_CHECK="Y"
    GUILD_SOURCE_LAUNCHER_LOCAL_REPO="N"
    GUILD_SOURCE_LAUNCHER_MANAGED_TARGET="N"
    GUILD_SOURCE_LAUNCHER_PATH="${DISPATCHER_SOURCE}"
    guild_source_path() {
      [[ "$1" == "scripts/cnode-helper-scripts/guild-deploy.sh" ]] || return 2
      printf "%s\n" "${SNAPSHOT_DISPATCHER}"
    }
    guild_source_revision() {
      printf "%s\n" "2222222222222222222222222222222222222222"
    }
    dispatcher_update_check
  '
)"
assert_eq \
  "$(dispatcher_sha256 "${custom_dispatcher}")" \
  "${custom_dispatcher_checksum}"
grep -F "guild-deploy.sh is current" <<< "${update_output}" >/dev/null ||
  fail "customized dispatcher did not recognize merged snapshot code as current"
if find "${TEST_DIR}" -name 'custom-dispatcher.sh_bkp*' -print -quit | grep -q .; then
  fail "current customized dispatcher created a needless backup/update loop"
fi

invalid_profile="${TEST_DIR}/invalid-profile.sh"
printf 'if then\n' > "${invalid_profile}"
if (
  NODE_IMPLEMENTATION="dingo"
  _GUILD_SOURCE_REVISION="2222222222222222222222222222222222222222"
  guild_source_path() {
    [[ "$1" == "scripts/dingo-helper-scripts/deploy-dingo.sh" ]] || return 2
    printf '%s\n' "${invalid_profile}"
  }
  dispatcher_load_profile
) >/dev/null 2>&1; then
  fail "dispatcher sourced a snapshot profile that failed shell validation"
fi

printf 'guild-deploy dispatcher tests passed\n'
