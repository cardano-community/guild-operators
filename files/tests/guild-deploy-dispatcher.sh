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

for invalid_input in port timeout dbsync; do
  if (
    unset CNODE_NAME CNODE_PATH NODE_NAME NETWORK BRANCH
    unset NODE_PORT DOWNLOAD_TIMEOUT
    unset CNODE_SKIP_DBSYNC_DOWNLOAD SKIP_DBSYNC_DOWNLOAD
    NODE_IMPLEMENTATION="cnode"
    NODE_PARENT="/tmp/guild-dispatcher-test"
    case "${invalid_input}" in
      port) NODE_PORT=70000 ;;
      timeout) DOWNLOAD_TIMEOUT=0 ;;
      dbsync) CNODE_SKIP_DBSYNC_DOWNLOAD="yes" ;;
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
trap 'rm -rf "${TEST_DIR}"' EXIT
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
  UPDATE_CHECK="N"
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
        .capabilities.forging = true
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
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  dispatcher_mark_in_progress
  assert_eq "$(jq -r '.deploymentStatus' "${DEPLOYMENT_FILE}")" "deploying"
  assert_eq "$(jq -r '.implementation' "${DEPLOYMENT_FILE}")" "amaru"
  assert_eq "$(jq -r '.nodeVersion' "${DEPLOYMENT_FILE}")" "${installed_version}"
  assert_eq "$(jq -r '.targetNodeVersion' "${DEPLOYMENT_FILE}")" "${PROFILE_TARGET_NODE_VERSION}"
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
  dispatcher_validate_branch() { return 0; }
  dispatcher_update_check() { return 0; }
  failing_profile() {
    mkdir -p "${NODE_HOME}"
    dispatcher_mark_in_progress
    return 1
  }
  dispatcher_load_profile() {
    PROFILE_ENTRYPOINT="failing_profile"
  }
  unset NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NETWORK BRANCH
  SUDO="N"
  guild_deploy_main \
    -i dingo \
    -n preprod \
    -p "${TEST_DIR}" \
    -t failed-profile \
    -u
) >/dev/null 2>&1; then
  fail "dispatcher reported success after a deployment profile failed"
fi
assert_eq \
  "$(jq -r '.deploymentStatus' "${TEST_DIR}/failed_profile/.deployment.json")" \
  "deploying"

update_driver="${TEST_DIR}/update-driver.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '#TEST_SETTING="preserved"' \
  '# Do NOT modify code below' \
  '. "${DISPATCHER_SOURCE:?}"' \
  'DISPATCHER_LOCAL_REPO="N"' \
  'UPDATE_CHECK="Y"' \
  'BRANCH="master"' \
  'CURL_TIMEOUT=10' \
  'URL_RAW="https://not-used.invalid/master"' \
  'curl() {' \
  '  local output=""' \
  '  while [[ $# -gt 0 ]]; do' \
  '    case "$1" in' \
  '      -o) output="$2"; shift 2 ;;' \
  '      *) shift ;;' \
  '    esac' \
  '  done' \
  '  command cp -- "${REMOTE_DISPATCHER:?}" "${output:?}"' \
  '}' \
  'mv() { return 1; }' \
  'dispatcher_update_check' \
  > "${update_driver}"
chmod 0755 "${update_driver}"
update_driver_checksum="$(sha256sum "${update_driver}" | awk '{print $1}')"
if DISPATCHER_SOURCE="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  REMOTE_DISPATCHER="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  bash "${update_driver}" >/dev/null 2>&1; then
  fail "dispatcher self-update ignored an atomic replacement failure"
fi
assert_eq \
  "$(sha256sum "${update_driver}" | awk '{print $1}')" \
  "${update_driver_checksum}"
if find "${TEST_DIR}" \
  \( -name '.update-driver.sh.download.*' -o -name '.update-driver.sh.merged.*' \) \
  -print -quit | grep -q .; then
  fail "failed dispatcher update left a staging file"
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
custom_dispatcher_checksum="$(sha256sum "${custom_dispatcher}" | awk '{print $1}')"
update_output="$(
  DISPATCHER_SOURCE="${custom_dispatcher}" \
  REMOTE_DISPATCHER="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  bash -c '
    . "${DISPATCHER_SOURCE}"
    DISPATCHER_LOCAL_REPO="N"
    UPDATE_CHECK="Y"
    BRANCH="master"
    CURL_TIMEOUT=10
    URL_RAW="https://not-used.invalid/master"
    curl() {
      local output=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -o) output="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      command cp -- "${REMOTE_DISPATCHER}" "${output}"
    }
    dispatcher_update_check
  ' "${TEST_DIR}//custom-dispatcher.sh"
)"
assert_eq \
  "$(sha256sum "${custom_dispatcher}" | awk '{print $1}')" \
  "${custom_dispatcher_checksum}"
grep -F "guild-deploy.sh is current" <<< "${update_output}" >/dev/null ||
  fail "customized dispatcher did not recognize its merged remote code as current"
if find "${TEST_DIR}" -name 'custom-dispatcher.sh_bkp*' -print -quit | grep -q .; then
  fail "current customized dispatcher created a needless backup/update loop"
fi

mkdir -p "${TEST_DIR}/invalid-profile-source"
if (
  DISPATCHER_LOCAL_REPO="N"
  DISPATCHER_DIR="${TEST_DIR}/invalid-profile-source"
  NODE_IMPLEMENTATION="dingo"
  URL_RAW="https://not-used.invalid/master"
  CURL_TIMEOUT=10
  PROFILE_TMP_DIR=""
  DISPATCHER_PROFILE_TMP_OWNED="N"
  TMPDIR="${TEST_DIR}"
  curl() {
    local output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'if then\n' > "${output}"
  }
  dispatcher_load_profile
) >/dev/null 2>&1; then
  fail "dispatcher sourced a deployment profile that failed shell validation"
fi

printf 'guild-deploy dispatcher tests passed\n'
