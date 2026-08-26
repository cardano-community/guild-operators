#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if grep -q 'UPDATE_CHECK' \
  "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"; then
  fail "dispatcher still contains obsolete self-update compatibility state"
fi
if dispatcher_usage | grep -Eq '(^|[[:space:]])-u([[:space:]]|$)'; then
  fail "dispatcher usage still advertises the removed -u option"
fi

missing_git_error=""
if missing_git_error="$(
  command() {
    if [[ "${1:-}" = "-v" && "${2:-}" = "git" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  dispatcher_prepare_snapshot 2>&1
  )"; then
  fail "dispatcher continued without Git"
fi
case "${missing_git_error}" in
  *"Install Git and re-run guild-deploy.sh."*) ;;
  *) fail "missing-Git error does not explain how to continue" ;;
esac

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
  dispatcher_set_defaults
  assert_eq "${NODE_PARENT}" "/tmp/guild-dispatcher-test"
  assert_eq "${CNODE_PATH}" "/tmp/guild-dispatcher-test"
  assert_eq "${NODE_HOME}" "/tmp/guild-dispatcher-test/n___node"
  [[ "${NODE_SERVICE}" =~ ^[a-z0-9_]+$ ]] ||
    fail "Unicode top-level name produced an unsafe service name"
)

inherited_tmp="${TEST_DIR:-${TMPDIR:-/tmp}}/guild-inherited-source-test.$$"
mkdir -p "${inherited_tmp}"
printf 'keep\n' > "${inherited_tmp}/sentinel"
(
  GUILD_SOURCE_TMP_DIR="${inherited_tmp}"
  GIT_SOURCE_ROOT="${inherited_tmp}/repository"
  DISPATCHER_SOURCE_TMP_OWNED="Y"
  guild_deploy_main -h >/dev/null
)
[[ -f "${inherited_tmp}/sentinel" ]] ||
  fail "dispatcher cleanup removed an inherited source directory"
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
  dispatcher_set_defaults
  assert_eq "${NODE_NAME}" "relay_one"
  assert_eq "${NODE_HOME}" "/tmp/guild-dispatcher-test/relay_one"
)

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guild-dispatcher-test.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

obsolete_update_marker="${TEST_DIR}/obsolete-update-option-ran"
obsolete_update_target="${TEST_DIR}/obsolete_update"
if (
  dispatcher_prepare_snapshot() {
    touch "${obsolete_update_marker}"
  }
  unset NODE_IMPLEMENTATION NETWORK BRANCH G_ACCOUNT
  NODE_PARENT="${TEST_DIR}"
  NODE_NAME="obsolete-update"
  SUDO="N"
  guild_deploy_main -u
) >/dev/null 2>&1; then
  fail "dispatcher accepted the removed -u option"
fi
[[ ! -e "${obsolete_update_marker}" ]] ||
  fail "removed -u option reached source snapshot preparation"
[[ ! -e "${obsolete_update_target}" ]] ||
  fail "removed -u option changed the deployment target"

target_token_path="${TEST_DIR}/target-state.json"
assert_eq "$(dispatcher_target_state_token "${target_token_path}")" "absent"
printf 'first state\n' > "${target_token_path}"
first_target_token="$(dispatcher_target_state_token "${target_token_path}")"
assert_eq \
  "$(dispatcher_target_state_token "${target_token_path}")" \
  "${first_target_token}"
printf 'second state\n' > "${target_token_path}"
[[ "$(dispatcher_target_state_token "${target_token_path}")" != "${first_target_token}" ]] ||
  fail "target-state token did not change with deployment metadata"
ln -s "${target_token_path}" "${TEST_DIR}/target-state-link.json"
if dispatcher_target_state_token "${TEST_DIR}/target-state-link.json" >/dev/null 2>&1; then
  fail "target-state token accepted a symbolic-link manifest"
fi

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

path_injection_marker="${TEST_DIR}/path-injection-ran"
if (
  unset CNODE_NAME CNODE_PATH NODE_NAME NETWORK BRANCH
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="${TEST_DIR}/unsafe\$(touch${IFS}${path_injection_marker})"
  NETWORK_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  SUDO="N"
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
    dispatcher_set_defaults
  ) >/dev/null 2>&1; then
    fail "dispatcher accepted ${invalid_manifest_case} deployment metadata"
  fi
  if (
    NODE_HOME="${TEST_DIR}/${invalid_manifest_dir}"
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
    deployment_branch_exists() { return 0; }
    deployment_set_branch "_alpha"
  ) >/dev/null 2>&1; then
    fail "runtime branch update accepted ${invalid_manifest_case} deployment metadata"
  fi
done

mkdir -p "${TEST_DIR}/resume_deploying"
jq '.deploymentStatus = "deploying" | .serviceName = "resume_deploying"' \
  "${TEST_DIR}/existing/.deployment.json" \
  > "${TEST_DIR}/resume_deploying/.deployment.json"
(
  unset CNODE_NAME CNODE_PATH NETWORK BRANCH G_ACCOUNT
  NODE_IMPLEMENTATION="cnode"
  NODE_PARENT="${TEST_DIR}"
  NODE_NAME="resume-deploying"
  NETWORK_EXPLICIT="N"
  NETWORK_PRESET="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  G_ACCOUNT_PRESET="N"
  SUDO="N"
  dispatcher_set_defaults
  assert_eq "${NETWORK}" "preview"
  assert_eq "${BRANCH}" "alpha"
)

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
    dispatcher_set_defaults
  ) >/dev/null 2>&1; then
    fail "dispatcher accepted inconsistent ${semantic_case} manifest semantics"
  fi
  if (
    NODE_HOME="${TEST_DIR}/${semantic_dir}"
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
    deployment_branch_exists() { return 0; }
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
  dispatcher_set_defaults
) >/dev/null 2>&1; then
  fail "legacy target accepted a preset network conflicting with genesis"
fi

mkdir -p "${TEST_DIR}/interrupted/scripts"
printf 'legacy-branch\n' > "${TEST_DIR}/interrupted/scripts/.env_branch"
(
  unset PROFILE_METRICS_PROVIDER
  PROFILE_TARGET_NODE_VERSION='v-target'
  installed_version=$'version "quoted"\\path\nnext'
  dispatcher_detect_node_version() {
    printf '%s' "${installed_version}"
  }
  NODE_IMPLEMENTATION="amaru"
  NODE_HOME="${TEST_DIR}/interrupted"
  NODE_SERVICE="interrupted"
  NETWORK="preview"
  BRANCH="alpha"
  G_ACCOUNT="cardano-community"
  GUILD_SOURCE_REVISION="0123456789abcdef0123456789abcdef01234567"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  dispatcher_mark_in_progress
  assert_eq "$(jq -r '.deploymentStatus' "${DEPLOYMENT_FILE}")" "deploying"
  assert_eq "$(jq -r '.implementation' "${DEPLOYMENT_FILE}")" "amaru"
  assert_eq "$(jq -r '.nodeVersion' "${DEPLOYMENT_FILE}")" "${installed_version}"
  assert_eq "$(jq -r '.targetNodeVersion' "${DEPLOYMENT_FILE}")" "${PROFILE_TARGET_NODE_VERSION}"
  assert_eq "$(jq -r '.sourceRevision' "${DEPLOYMENT_FILE}")" "${GUILD_SOURCE_REVISION}"
  [[ -f "${NODE_HOME}/scripts/.env_branch" ]] ||
    fail "legacy branch sidecar was archived before deployment completed"
  dispatcher_write_manifest deployed
  assert_eq "$(jq -r '.deploymentStatus' "${DEPLOYMENT_FILE}")" "deployed"
  [[ ! -f "${NODE_HOME}/scripts/.env_branch" ]] ||
    fail "legacy branch sidecar was not archived after deployment"
  find "${NODE_HOME}/scripts/archive" -name '.env_branch_migrated_*' -print -quit |
    grep -q . || fail "archived legacy branch sidecar was not found"
)

mkdir -p "${TEST_DIR}/archive-failure/scripts"
printf 'legacy-branch\n' > "${TEST_DIR}/archive-failure/scripts/.env_branch"
(
  NODE_IMPLEMENTATION="cnode"
  NODE_HOME="${TEST_DIR}/archive-failure"
  NODE_SERVICE="archive_failure"
  NETWORK="mainnet"
  BRANCH="master"
  G_ACCOUNT="cardano-community"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  dispatcher_mark_in_progress
  if (
    mv() {
      if [[ "$*" == *"/scripts/.env_branch"* ]]; then
        return 1
      fi
      command mv "$@"
    }
    dispatcher_write_manifest deployed
  ) >/dev/null 2>&1; then
    fail "final manifest commit succeeded after legacy branch archival failed"
  fi
  assert_eq "$(jq -r '.deploymentStatus' "${DEPLOYMENT_FILE}")" "deploying"
  [[ -f "${NODE_HOME}/scripts/.env_branch" ]] ||
    fail "failed legacy branch archival removed the source sidecar"
  if find "${NODE_HOME}" -maxdepth 1 -name '.deployment.json.tmp.*' -print -quit |
    grep -q .; then
    fail "failed legacy branch archival left a staged manifest"
  fi
)

mkdir -p "${TEST_DIR}/existing-update"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "deploymentStatus": "deployed",' \
  '  "implementation": "cnode",' \
  '  "network": "mainnet",' \
  '  "branch": "master"' \
  '}' > "${TEST_DIR}/existing-update/.deployment.json"
(
  unset PROFILE_TARGET_NODE_VERSION PROFILE_METRICS_PROVIDER
  NODE_IMPLEMENTATION="cnode"
  NODE_HOME="${TEST_DIR}/existing-update"
  NODE_SERVICE="existing-update"
  NETWORK="mainnet"
  BRANCH="alpha"
  G_ACCOUNT="cardano-community"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  dispatcher_mark_in_progress
  assert_eq "$(jq -r '.deploymentStatus' "${DEPLOYMENT_FILE}")" "deploying"
  assert_eq "$(jq -r '.branch' "${DEPLOYMENT_FILE}")" "alpha"
)

mkdir -p "${TEST_DIR}/manifest-write-failure"
if (
  NODE_IMPLEMENTATION="cnode"
  NODE_HOME="${TEST_DIR}/manifest-write-failure"
  NODE_SERVICE="write-failure"
  NETWORK="mainnet"
  BRANCH="master"
  G_ACCOUNT="cardano-community"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  mv() { return 1; }
  dispatcher_write_manifest deployed
) >/dev/null 2>&1; then
  fail "manifest write reported success when atomic replacement failed"
fi
[[ ! -e "${TEST_DIR}/manifest-write-failure/.deployment.json" ]] ||
  fail "failed manifest replacement left a deployment manifest"
if find "${TEST_DIR}/manifest-write-failure" -name '.deployment.json.tmp.*' -print -quit |
  grep -q .; then
  fail "failed manifest replacement left a temporary file"
fi

if (
  failing_profile() {
    mkdir -p "${NODE_HOME}"
    dispatcher_mark_in_progress
    return 1
  }
  dispatcher_load_profile() {
    PROFILE_ENTRYPOINT="failing_profile"
  }
  dispatcher_adopt_snapshot() {
    GIT_SOURCE_ROOT="${REPO_ROOT}"
    GUILD_SOURCE_REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  }
  unset NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NETWORK BRANCH
  SUDO="N"
  GUILD_DEPLOY_SNAPSHOT_STAGE="ready"
  GUILD_DEPLOY_SOURCE_ACCOUNT="cardano-community"
  GUILD_DEPLOY_SOURCE_BRANCH="master"
  GUILD_DEPLOY_SOURCE_REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  GUILD_DEPLOY_TARGET_PATH="$(dispatcher_canonical_target_path "${TEST_DIR}/failed_profile")"
  GUILD_DEPLOY_TARGET_STATE_TOKEN="absent"
  guild_deploy_main \
    -i dingo \
    -n preprod \
    -p "${TEST_DIR}" \
    -t failed-profile
) >/dev/null 2>&1; then
  fail "dispatcher reported success after a deployment profile failed"
fi
assert_eq \
  "$(jq -r '.deploymentStatus' "${TEST_DIR}/failed_profile/.deployment.json")" \
  "deploying"

source_helper_root="${TEST_DIR}/source-helper"
mkdir -p "${source_helper_root}/safe"
printf 'snapshot payload\n' > "${source_helper_root}/safe/payload"
ln -s payload "${source_helper_root}/safe/payload-link"
ln -s safe "${source_helper_root}/safe-link"
(
  GIT_SOURCE_ROOT="${source_helper_root}"
  dispatcher_source_copy "safe/payload" "${TEST_DIR}/source-copy"
)
assert_eq "$(cat "${TEST_DIR}/source-copy")" "snapshot payload"
for unsafe_path in \
  "/etc/passwd" \
  "../source-helper/safe/payload" \
  "safe/../safe/payload" \
  "safe/payload-link" \
  "safe-link/payload" \
  "safe/missing"; do
  if (
    GIT_SOURCE_ROOT="${source_helper_root}"
    dispatcher_source_copy "${unsafe_path}" "${TEST_DIR}/unsafe-copy"
  ) >/dev/null 2>&1; then
    fail "snapshot source helper accepted unsafe path: ${unsafe_path}"
  fi
done

install_root="${TEST_DIR}/dispatcher-install"
mkdir -p "${install_root}/scripts/archive"
awk '
  /^#CURL_TIMEOUT=60/ {
    print "CURL_TIMEOUT=17                     # operator customization"
    next
  }
  { print }
  /^# Do NOT modify code below/ {
    print "# stale-runtime-marker"
  }
' "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  > "${install_root}/scripts/guild-deploy.sh"
chmod 0755 "${install_root}/scripts/guild-deploy.sh"
(
  NODE_HOME="${install_root}"
  GIT_SOURCE_ROOT="${REPO_ROOT}"
  dispatcher_install_self
) >/dev/null
grep -q '^CURL_TIMEOUT=17 .*operator customization$' \
  "${install_root}/scripts/guild-deploy.sh" ||
  fail "dispatcher install did not preserve the operator user-variable header"
if grep -q '^# stale-runtime-marker$' "${install_root}/scripts/guild-deploy.sh"; then
  fail "dispatcher install retained stale runtime code"
fi
assert_eq \
  "$(find "${install_root}/scripts/archive" -type f | wc -l | tr -d '[:space:]')" \
  "1"
(
  NODE_HOME="${install_root}"
  GIT_SOURCE_ROOT="${REPO_ROOT}"
  dispatcher_install_self
) >/dev/null
assert_eq \
  "$(find "${install_root}/scripts/archive" -type f | wc -l | tr -d '[:space:]')" \
  "1"

atomic_root="${TEST_DIR}/dispatcher-atomic-failure"
mkdir -p "${atomic_root}/scripts/archive"
cp "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  "${atomic_root}/scripts/guild-deploy.sh"
printf '\n# stale-runtime-marker\n' >> "${atomic_root}/scripts/guild-deploy.sh"
chmod 0755 "${atomic_root}/scripts/guild-deploy.sh"
atomic_checksum="$(sha256sum "${atomic_root}/scripts/guild-deploy.sh" | awk '{print $1}')"
if (
  NODE_HOME="${atomic_root}"
  GIT_SOURCE_ROOT="${REPO_ROOT}"
  mv() { return 1; }
  dispatcher_install_self
) >/dev/null 2>&1; then
  fail "dispatcher install ignored an atomic replacement failure"
fi
assert_eq \
  "$(sha256sum "${atomic_root}/scripts/guild-deploy.sh" | awk '{print $1}')" \
  "${atomic_checksum}"
if find "${atomic_root}/scripts" -name '.guild-deploy.sh.install.*' -print -quit |
  grep -q .; then
  fail "failed dispatcher install left a staging file"
fi

invalid_profile_root="${TEST_DIR}/invalid-profile-source"
mkdir -p "${invalid_profile_root}/scripts/dingo-helper-scripts"
printf 'if then\n' \
  > "${invalid_profile_root}/scripts/dingo-helper-scripts/deploy-dingo.sh"
if (
  GIT_SOURCE_ROOT="${invalid_profile_root}"
  NODE_IMPLEMENTATION="dingo"
  curl() { fail "profile loading attempted network access: $*"; }
  dispatcher_load_profile
) >/dev/null 2>&1; then
  fail "dispatcher sourced a deployment profile that failed shell validation"
fi

snapshot_remote="${TEST_DIR}/snapshot-remote"
mkdir -p \
  "${snapshot_remote}/scripts/cnode-helper-scripts" \
  "${snapshot_remote}/scripts/dingo-helper-scripts"
git -C "${snapshot_remote}" init -q
git -C "${snapshot_remote}" symbolic-ref HEAD refs/heads/master
git -C "${snapshot_remote}" config user.name "Guild Operators Test"
git -C "${snapshot_remote}" config user.email "guild-test@example.invalid"
printf 'fixture license\n' > "${snapshot_remote}/LICENSE"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'NODE_PARENT="/remote/header/must-not-win"' \
  'SUDO="Y"' \
  '# Do NOT modify code below' \
  'GUILD_DEPLOY_SNAPSHOT_CAPABLE="Y"' \
  '{' \
  '  printf "stage=%s\\n" "${GUILD_DEPLOY_SNAPSHOT_STAGE:-}"' \
  '  printf "account=%s\\n" "${GUILD_DEPLOY_SOURCE_ACCOUNT:-}"' \
  '  printf "branch=%s\\n" "${GUILD_DEPLOY_SOURCE_BRANCH:-}"' \
  '  printf "expected_revision=%s\\n" "${GUILD_DEPLOY_SOURCE_REVISION:-}"' \
  '  printf "revision=%s\\n" "${GUILD_SOURCE_REVISION:-}"' \
  '  printf "root=%s\\n" "${GIT_SOURCE_ROOT:-}"' \
  '  printf "node_parent=%s\\n" "${NODE_PARENT:-}"' \
  '  printf "sudo=%s\\n" "${SUDO:-}"' \
  '  printf "arg=%s\\n" "$@"' \
  '} > "${SNAPSHOT_CHILD_LOG:?}"' \
  'exit "${SNAPSHOT_CHILD_STATUS:-0}"' \
  > "${snapshot_remote}/scripts/cnode-helper-scripts/guild-deploy.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'deploy_dingo_profile() { :; }' \
  > "${snapshot_remote}/scripts/dingo-helper-scripts/deploy-dingo.sh"
git -C "${snapshot_remote}" add LICENSE scripts
git -C "${snapshot_remote}" commit -q -m "master snapshot"
master_revision="$(git -C "${snapshot_remote}" rev-parse HEAD)"
git -C "${snapshot_remote}" checkout -q -b feature/snapshot
printf 'feature snapshot\n' > "${snapshot_remote}/feature-marker"
git -C "${snapshot_remote}" add feature-marker
git -C "${snapshot_remote}" commit -q -m "feature snapshot"
feature_revision="$(git -C "${snapshot_remote}" rev-parse HEAD)"
git -C "${snapshot_remote}" checkout -q master
git -C "${snapshot_remote}" checkout -q -b historical-dispatcher
grep -v '^GUILD_DEPLOY_SNAPSHOT_CAPABLE="Y"$' \
  "${snapshot_remote}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  > "${snapshot_remote}/scripts/cnode-helper-scripts/guild-deploy.sh.tmp"
mv \
  "${snapshot_remote}/scripts/cnode-helper-scripts/guild-deploy.sh.tmp" \
  "${snapshot_remote}/scripts/cnode-helper-scripts/guild-deploy.sh"
git -C "${snapshot_remote}" add scripts/cnode-helper-scripts/guild-deploy.sh
git -C "${snapshot_remote}" commit -q -m "historical dispatcher"
git -C "${snapshot_remote}" checkout -q master

validation_checkout="${TEST_DIR}/snapshot-validation"
git clone -q --branch master "${snapshot_remote}" "${validation_checkout}"
(
  NODE_IMPLEMENTATION="dingo"
  GIT_SOURCE_ROOT="${validation_checkout}"
  dispatcher_validate_snapshot "${validation_checkout}"
) >/dev/null
printf 'untracked payload\n' > "${validation_checkout}/untracked-payload"
if (
  GIT_SOURCE_ROOT="${validation_checkout}"
  dispatcher_source_path untracked-payload
) >/dev/null 2>&1; then
  fail "snapshot source helper accepted an untracked payload"
fi
printf 'dirty tracked payload\n' >> "${validation_checkout}/LICENSE"
if (
  NODE_IMPLEMENTATION="dingo"
  GIT_SOURCE_ROOT="${validation_checkout}"
  dispatcher_validate_snapshot "${validation_checkout}"
) >/dev/null 2>&1; then
  fail "snapshot validation accepted modified tracked payloads"
fi

configure_local_git_remote() {
  local local_repository="$1"
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0="url.file://${local_repository}.insteadOf"
  GIT_CONFIG_VALUE_0="https://github.com/fixture-account/guild-operators.git"
  export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}

GUILD_DEPLOY_USER_HEADER="$(
  dispatcher_extract_user_header \
    "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"
)"

snapshot_child_log="${TEST_DIR}/snapshot-child.log"
(
  trap cleanup_dispatcher EXIT
  TMPDIR="${TEST_DIR}"
  G_ACCOUNT="fixture-account"
  BRANCH="feature/snapshot"
  REPO_RAW="https://raw.invalid/fixture-account/guild-operators"
  URL_RAW="${REPO_RAW}/${BRANCH}"
  NODE_IMPLEMENTATION="dingo"
  NODE_PARENT="${TEST_DIR}/expected-parent"
  SUDO="N"
  export NODE_PARENT SUDO
  configure_local_git_remote "${snapshot_remote}"
  SNAPSHOT_CHILD_LOG="${snapshot_child_log}"
  export SNAPSHOT_CHILD_LOG
  dispatcher_prepare_snapshot -i dingo -n preprod -b feature/snapshot
) >/dev/null
grep -q '^stage=ready$' "${snapshot_child_log}" ||
  fail "snapshot child did not receive the ready stage"
grep -q '^account=fixture-account$' "${snapshot_child_log}" ||
  fail "snapshot child did not receive the resolved repository account"
grep -q '^branch=feature/snapshot$' "${snapshot_child_log}" ||
  fail "snapshot child did not receive the selected branch"
grep -q "^revision=${feature_revision}$" "${snapshot_child_log}" ||
  fail "snapshot child did not receive the selected commit"
grep -q "^expected_revision=${feature_revision}$" "${snapshot_child_log}" ||
  fail "snapshot child did not receive the expected source revision"
grep -q "^node_parent=${TEST_DIR}/expected-parent$" "${snapshot_child_log}" ||
  fail "snapshot dispatcher allowed its remote user header to replace local settings"
grep -q '^sudo=N$' "${snapshot_child_log}" ||
  fail "snapshot dispatcher did not preserve the local sudo setting"
assert_eq "$(grep -c '^arg=' "${snapshot_child_log}")" "6"
snapshot_checkout="$(sed -n 's/^root=//p' "${snapshot_child_log}")"
[[ ! -e "${snapshot_checkout%/repository}" ]] ||
  fail "successful snapshot deployment left its temporary checkout"

fallback_child_log="${TEST_DIR}/snapshot-fallback.log"
(
  trap cleanup_dispatcher EXIT
  TMPDIR="${TEST_DIR}"
  G_ACCOUNT="fixture-account"
  BRANCH="missing-branch"
  REPO_RAW="https://raw.invalid/fixture-account/guild-operators"
  URL_RAW="${REPO_RAW}/${BRANCH}"
  NODE_IMPLEMENTATION="dingo"
  configure_local_git_remote "${snapshot_remote}"
  SNAPSHOT_CHILD_LOG="${fallback_child_log}"
  export SNAPSHOT_CHILD_LOG
  dispatcher_prepare_snapshot -i dingo -n preprod -b missing-branch
) >/dev/null 2>&1
grep -q '^branch=master$' "${fallback_child_log}" ||
  fail "missing snapshot branch did not fall back to master"
grep -q "^revision=${master_revision}$" "${fallback_child_log}" ||
  fail "fallback snapshot did not use the master commit"

historical_child_log="${TEST_DIR}/snapshot-historical.log"
historical_error_log="${TEST_DIR}/snapshot-historical.err"
if (
  trap cleanup_dispatcher EXIT
  TMPDIR="${TEST_DIR}"
  G_ACCOUNT="fixture-account"
  BRANCH="historical-dispatcher"
  NODE_IMPLEMENTATION="dingo"
  configure_local_git_remote "${snapshot_remote}"
  SNAPSHOT_CHILD_LOG="${historical_child_log}"
  export SNAPSHOT_CHILD_LOG
  dispatcher_prepare_snapshot -i dingo -n preprod -b historical-dispatcher
) >/dev/null 2>"${historical_error_log}"; then
  fail "snapshot bootstrap executed a historical raw-download dispatcher"
fi
grep -q 'predates snapshot deployment' "${historical_error_log}" ||
  fail "historical dispatcher failure did not explain the compatibility boundary"
[[ ! -e "${historical_child_log}" ]] ||
  fail "historical dispatcher was executed before compatibility validation"

transient_error_log="${TEST_DIR}/snapshot-transient.err"
if (
  trap cleanup_dispatcher EXIT
  TMPDIR="${TEST_DIR}"
  G_ACCOUNT="fixture-account"
  BRANCH="feature/snapshot"
  NODE_IMPLEMENTATION="dingo"
  configure_local_git_remote "${snapshot_remote}"
  dispatcher_clone_snapshot() { return 1; }
  dispatcher_prepare_snapshot -i dingo -n preprod -b feature/snapshot
) >/dev/null 2>"${transient_error_log}"; then
  fail "snapshot bootstrap fell back to master after an existing ref failed to clone"
fi
grep -q 'although the remote ref exists' "${transient_error_log}" ||
  fail "existing-ref clone failure was misclassified as a missing branch"

if (
  TMPDIR="${TEST_DIR}"
  G_ACCOUNT="fixture-account"
  configure_local_git_remote "${TEST_DIR}/missing-repository"
  SUDO="N"
  guild_deploy_main \
    -i dingo \
    -n preprod \
    -p "${TEST_DIR}" \
    -t clone-failure-target \
    -b master
) >/dev/null 2>&1; then
  fail "dispatcher accepted an unavailable master snapshot"
fi
[[ ! -e "${TEST_DIR}/clone_failure_target" ]] ||
  fail "source clone failure changed the deployment target"

stale_target_profile_called="${TEST_DIR}/stale-target-profile-called"
if (
  dispatcher_load_profile() {
    touch "${stale_target_profile_called}"
  }
  unset NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NETWORK BRANCH G_ACCOUNT
  SUDO="N"
  GUILD_DEPLOY_SNAPSHOT_STAGE="ready"
  GUILD_DEPLOY_SOURCE_ACCOUNT="cardano-community"
  GUILD_DEPLOY_SOURCE_BRANCH="master"
  GUILD_DEPLOY_SOURCE_REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  GUILD_DEPLOY_TARGET_PATH="$(dispatcher_canonical_target_path "${TEST_DIR}/different-target")"
  GUILD_DEPLOY_TARGET_STATE_TOKEN="absent"
  guild_deploy_main \
    -i dingo \
    -n preprod \
    -p "${TEST_DIR}" \
    -t stale-target
) >/dev/null 2>&1; then
  fail "snapshot child accepted a different target path than the bootstrap"
fi
[[ ! -e "${stale_target_profile_called}" ]] ||
  fail "snapshot child loaded a profile before checking its target path"

if (
  stale_target_profile() {
    touch "${stale_target_profile_called}"
  }
  dispatcher_load_profile() {
    PROFILE_ENTRYPOINT="stale_target_profile"
  }
  unset NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NETWORK BRANCH G_ACCOUNT
  SUDO="N"
  GUILD_DEPLOY_SNAPSHOT_STAGE="ready"
  GUILD_DEPLOY_SOURCE_ACCOUNT="cardano-community"
  GUILD_DEPLOY_SOURCE_BRANCH="master"
  GUILD_DEPLOY_SOURCE_REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  GUILD_DEPLOY_TARGET_PATH="$(dispatcher_canonical_target_path "${TEST_DIR}/stale_target")"
  GUILD_DEPLOY_TARGET_STATE_TOKEN="file:1-1"
  guild_deploy_main \
    -i dingo \
    -n preprod \
    -p "${TEST_DIR}" \
    -t stale-target
) >/dev/null 2>&1; then
  fail "snapshot child accepted a deployment target changed during checkout"
fi
[[ ! -e "${stale_target_profile_called}" ]] ||
  fail "snapshot child loaded a profile before checking target state"

full_snapshot_remote="${TEST_DIR}/full-snapshot-remote"
mkdir -p \
  "${full_snapshot_remote}/scripts/cnode-helper-scripts" \
  "${full_snapshot_remote}/scripts/dingo-helper-scripts"
git -C "${full_snapshot_remote}" init -q
git -C "${full_snapshot_remote}" symbolic-ref HEAD refs/heads/master
git -C "${full_snapshot_remote}" config user.name "Guild Operators Test"
git -C "${full_snapshot_remote}" config user.email "guild-test@example.invalid"
printf 'fixture license\n' > "${full_snapshot_remote}/LICENSE"
cp "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  "${full_snapshot_remote}/scripts/cnode-helper-scripts/guild-deploy.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'deploy_dingo_profile() {' \
  '  mkdir -p "${NODE_HOME}/scripts/archive"' \
  '  PROFILE_TARGET_NODE_VERSION="fixture"' \
  '  dispatcher_mark_in_progress' \
  '}' \
  > "${full_snapshot_remote}/scripts/dingo-helper-scripts/deploy-dingo.sh"
git -C "${full_snapshot_remote}" add LICENSE scripts
git -C "${full_snapshot_remote}" commit -q -m "full dispatcher snapshot"
full_snapshot_revision="$(git -C "${full_snapshot_remote}" rev-parse HEAD)"
(
  TMPDIR="${TEST_DIR}"
  G_ACCOUNT="fixture-account"
  configure_local_git_remote "${full_snapshot_remote}"
  SUDO="N"
  guild_deploy_main \
    -i dingo \
    -n preprod \
    -p "${TEST_DIR}" \
    -t snapshot-e2e \
    -b master
) >/dev/null
full_snapshot_target="${TEST_DIR}/snapshot_e2e"
[[ -x "${full_snapshot_target}/scripts/guild-deploy.sh" ]] ||
  fail "snapshot deployment did not install its dispatcher"
assert_eq \
  "$(jq -r '.deploymentStatus' "${full_snapshot_target}/.deployment.json")" \
  "deployed"
assert_eq \
  "$(jq -r '.sourceRevision' "${full_snapshot_target}/.deployment.json")" \
  "${full_snapshot_revision}"
if find "${TEST_DIR}" -maxdepth 1 -type d -name 'guild-operators-source.*' \
  -print -quit | grep -q .; then
  fail "end-to-end snapshot deployment left a temporary checkout"
fi

failure_child_log="${TEST_DIR}/snapshot-child-failure.log"
if (
  trap cleanup_dispatcher EXIT
  TMPDIR="${TEST_DIR}"
  G_ACCOUNT="fixture-account"
  BRANCH="feature/snapshot"
  REPO_RAW="https://raw.invalid/fixture-account/guild-operators"
  URL_RAW="${REPO_RAW}/${BRANCH}"
  NODE_IMPLEMENTATION="dingo"
  configure_local_git_remote "${snapshot_remote}"
  SNAPSHOT_CHILD_LOG="${failure_child_log}"
  SNAPSHOT_CHILD_STATUS=37
  export SNAPSHOT_CHILD_LOG SNAPSHOT_CHILD_STATUS
  dispatcher_prepare_snapshot -i dingo -n preprod
); then
  fail "snapshot dispatcher child failure was reported as success"
else
  child_status=$?
fi
assert_eq "${child_status}" "37"
failure_checkout="$(sed -n 's/^root=//p' "${failure_child_log}")"
[[ ! -e "${failure_checkout%/repository}" ]] ||
  fail "failed snapshot deployment left its temporary checkout"

printf 'guild-deploy dispatcher tests passed\n'
