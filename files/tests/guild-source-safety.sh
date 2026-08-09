#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2089,SC2090,SC2317,SC2329
set -euo pipefail

if ((BASH_VERSINFO[0] < 4 ||
     (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'Guild source safety tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DISPATCHER="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-source-safety.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
REAL_GIT="$(command -v git || true)"
SOURCE_REPOSITORY="fixture-account/guild-operators"
SOURCE_CHANNEL="main"
ORIGIN="${TEST_ROOT}/origin.git"
OTHER_ORIGIN="${TEST_ROOT}/other-origin.git"
WORK_REPOSITORY="${TEST_ROOT}/work"

# Build fixtures independently of any caller Git context. A deliberately
# hostile context is installed later around the provider call being tested.
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
unset GIT_CONFIG_SYSTEM GIT_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_PREFIX GIT_WORK_TREE
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_TERMINAL_PROMPT

cleanup() {
  chmod -R u+rwX "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  local context="$3"
  grep -Fqx -- "${expected}" "${file}" ||
    fail "${context}: '${expected}' was not found in ${file}"
}

file_mode() {
  local path="$1"
  local mode=""

  if mode="$(stat -c '%a' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -f '%Lp' "${path}"
  fi
}

assert_not_owner_writable() {
  local path="$1"
  local context="$2"
  local mode=""
  local numeric_mode=0

  mode="$(file_mode "${path}")"
  numeric_mode=$((8#${mode}))
  (( (numeric_mode & 0200) == 0 )) ||
    fail "${context}: mode ${mode} retains owner write permission"
}

assert_private_mode() {
  local path="$1"
  local context="$2"
  local mode=""
  local numeric_mode=0

  mode="$(file_mode "${path}")"
  numeric_mode=$((8#${mode}))
  (( (numeric_mode & 0077) == 0 )) ||
    fail "${context}: mode ${mode} grants group or other access"
}

expect_failure() {
  local context="$1"
  shift
  if "$@" >"${TEST_ROOT}/last.stdout" 2>"${TEST_ROOT}/last.stderr"; then
    fail "${context}: command unexpectedly succeeded"
  fi
}

expect_status() {
  local expected="$1"
  local context="$2"
  local status=0
  shift 2

  set +e
  "$@" >"${TEST_ROOT}/last.stdout" 2>"${TEST_ROOT}/last.stderr"
  status=$?
  set -e
  [[ ${status} -eq ${expected} ]] ||
    fail "${context}: expected status ${expected}, got ${status}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "required command is unavailable: $1"
}

for required_command in awk chmod cp find git grep mkdir mktemp mv rm sed stat; do
  require_command "${required_command}"
done
[[ -n "${REAL_GIT}" ]] || fail "required command is unavailable: git"
[[ -r "${DISPATCHER}" ]] || fail "dispatcher is unavailable: ${DISPATCHER}"

git_fixture() {
  "${REAL_GIT}" "$@"
}

git_in() {
  local repository="$1"
  shift
  "${REAL_GIT}" -C "${repository}" "$@"
}

create_repository_fixtures() {
  local safe_revision=""
  local control_path=""

  git_fixture init -q --bare "${ORIGIN}"
  git_fixture init -q --bare "${OTHER_ORIGIN}"
  git_fixture init -q "${WORK_REPOSITORY}"
  git_in "${WORK_REPOSITORY}" config user.name "Guild source safety fixture"
  git_in "${WORK_REPOSITORY}" config user.email "fixture@example.invalid"
  git_in "${WORK_REPOSITORY}" checkout -q -b main
  git_in "${WORK_REPOSITORY}" remote add origin "${ORIGIN}"

  mkdir -p \
    "${WORK_REPOSITORY}/scripts/common-helper-scripts" \
    "${WORK_REPOSITORY}/files/node-implementations/cnode" \
    "${WORK_REPOSITORY}/docs"
  printf '#!/usr/bin/env bash\nprintf "safe fixture\\n"\n' > \
    "${WORK_REPOSITORY}/scripts/common-helper-scripts/safe.sh"
  printf '{"fixture":true}\n' > \
    "${WORK_REPOSITORY}/files/node-implementations/cnode/config.json"
  printf 'outside deployment allowlist\n' > "${WORK_REPOSITORY}/docs/fixture.txt"
  chmod 0755 "${WORK_REPOSITORY}/scripts/common-helper-scripts/safe.sh"
  git_in "${WORK_REPOSITORY}" add -- scripts files docs
  git_in "${WORK_REPOSITORY}" commit -q -m "safe source fixture"
  safe_revision="$(git_in "${WORK_REPOSITORY}" rev-parse HEAD)"
  git_in "${WORK_REPOSITORY}" tag safe-tag
  git_in "${WORK_REPOSITORY}" push -q origin main safe-tag
  git_fixture --git-dir="${ORIGIN}" symbolic-ref HEAD refs/heads/main

  git_in "${WORK_REPOSITORY}" checkout -q -b unsafe-link "${safe_revision}"
  ln -s safe.sh \
    "${WORK_REPOSITORY}/scripts/common-helper-scripts/unsafe-link"
  git_in "${WORK_REPOSITORY}" add -- \
    scripts/common-helper-scripts/unsafe-link
  git_in "${WORK_REPOSITORY}" commit -q -m "unsafe source symlink"
  git_in "${WORK_REPOSITORY}" push -q origin unsafe-link

  git_in "${WORK_REPOSITORY}" checkout -q -b unsafe-gitlink "${safe_revision}"
  git_in "${WORK_REPOSITORY}" update-index --add --cacheinfo \
    "160000,${safe_revision},scripts/common-helper-scripts/unsafe-gitlink"
  git_in "${WORK_REPOSITORY}" commit -q -m "unsafe source gitlink"
  git_in "${WORK_REPOSITORY}" push -q origin unsafe-gitlink

  git_in "${WORK_REPOSITORY}" checkout -q -b unsafe-name "${safe_revision}"
  control_path="$(printf 'scripts/common-helper-scripts/unsafe\nname')"
  printf 'control name\n' > "${WORK_REPOSITORY}/${control_path}"
  git_in "${WORK_REPOSITORY}" add -- "${control_path}"
  git_in "${WORK_REPOSITORY}" commit -q -m "unsafe control filename"
  git_in "${WORK_REPOSITORY}" push -q origin unsafe-name

  git_in "${WORK_REPOSITORY}" checkout -q main
  printf '#!/usr/bin/env bash\nprintf "other fixture\\n"\n' > \
    "${WORK_REPOSITORY}/scripts/common-helper-scripts/safe.sh"
  git_in "${WORK_REPOSITORY}" add -- scripts/common-helper-scripts/safe.sh
  git_in "${WORK_REPOSITORY}" commit -q -m "advanced source fixture"
  git_in "${WORK_REPOSITORY}" push -q origin main

  git_fixture clone -q "${ORIGIN}" "${TEST_ROOT}/other-work"
  git_in "${TEST_ROOT}/other-work" config user.name "Other fixture"
  git_in "${TEST_ROOT}/other-work" config user.email "other@example.invalid"
  git_in "${TEST_ROOT}/other-work" remote set-url origin "${OTHER_ORIGIN}"
  printf 'different repository\n' > "${TEST_ROOT}/other-work/README.other"
  git_in "${TEST_ROOT}/other-work" add -- README.other
  git_in "${TEST_ROOT}/other-work" commit -q -m "other repository"
  git_in "${TEST_ROOT}/other-work" push -q origin main
  git_fixture --git-dir="${OTHER_ORIGIN}" symbolic-ref HEAD refs/heads/main
}

create_repository_fixtures

# Sourcing the dispatcher must leave deployment behavior dormant. The provider
# is exercised directly below; no deployment profile or target is invoked.
unset GUILD_SOURCE_ALLOW_DIRTY GUILD_SOURCE_CACHE_ROOT GUILD_SOURCE_GIT_BIN
unset GUILD_SOURCE_LOCK_TIMEOUT GUILD_SOURCE_TMP_ROOT
. "${DISPATCHER}"

# Tests replace only URL construction. All repository operations still use the
# real Git executable against local repositories.
SOURCE_REMOTE_OVERRIDE="${ORIGIN}"
guild_source_repository_url() {
  # Deliberately accept every argument here so invalid repository identifiers
  # must be rejected by provider validation, not by this test seam.
  : "$1"
  printf '%s\n' "${SOURCE_REMOTE_OVERRIDE}"
}

new_case_home() {
  local name="$1"
  HOME="${TEST_ROOT}/home-${name}"
  XDG_CACHE_HOME="${HOME}/.cache"
  GUILD_SOURCE_CACHE_ROOT="${XDG_CACHE_HOME}/guild-operators"
  GUILD_SOURCE_GIT_BIN="${REAL_GIT}"
  GUILD_SOURCE_LOCK_TIMEOUT=2
  GUILD_SOURCE_TMP_ROOT="${HOME}/source-snapshots"
  export HOME XDG_CACHE_HOME GUILD_SOURCE_CACHE_ROOT GUILD_SOURCE_GIT_BIN
  export GUILD_SOURCE_LOCK_TIMEOUT GUILD_SOURCE_TMP_ROOT
  mkdir -p "${HOME}" "${GUILD_SOURCE_TMP_ROOT}"
}

expected_cache_path() {
  printf '%s/guild-operators/%s/repository.git\n' \
    "${XDG_CACHE_HOME}" "${SOURCE_REPOSITORY%%/*}"
}

assert_provider_unprepared() {
  local context="$1"
  expect_failure "${context}: revision remained published" guild_source_revision
  expect_failure "${context}: ref remained published" guild_source_ref
  expect_failure "${context}: report remained published" guild_source_report
  expect_failure "${context}: path remained published" \
    guild_source_path scripts/common-helper-scripts/safe.sh
}

prepare_managed() {
  guild_source_prepare \
    "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" managed
}

prepare_cached() {
  guild_source_prepare \
    "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" cached
}

assert_safe_snapshot() {
  local context="$1"
  local source_path=""

  source_path="$(guild_source_path scripts/common-helper-scripts/safe.sh)" ||
    fail "${context}: safe source path was unavailable"
  [[ -f "${source_path}" && ! -L "${source_path}" ]] ||
    fail "${context}: safe source was not a regular file"
  assert_not_owner_writable "${source_path}" \
    "${context}: snapshot file"
  assert_file_contains "${source_path}" '#!/usr/bin/env bash' \
    "${context}: snapshot contents"
}

checkout_fingerprint() {
  local checkout="$1"
  {
    git_in "${checkout}" rev-parse HEAD
    git_in "${checkout}" symbolic-ref -q HEAD || printf 'DETACHED\n'
    git_in "${checkout}" remote get-url origin
    git_in "${checkout}" status --porcelain=v1 --untracked-files=all
    git_in "${checkout}" for-each-ref \
      --format='%(refname) %(objectname)' refs/heads refs/tags
    git_in "${checkout}" diff --binary HEAD
  } 2>&1
}

assert_local_failure_without_mutation() {
  local checkout="$1"
  local channel="$2"
  local context="$3"
  local before=""
  local after=""

  before="$(checkout_fingerprint "${checkout}")"
  expect_failure "${context}" guild_source_prepare \
    "${SOURCE_REPOSITORY}" "${channel}" local "${checkout}"
  after="$(checkout_fingerprint "${checkout}")"
  assert_eq "${after}" "${before}" "${context}: checkout mutation"
  assert_provider_unprepared "${context}"
  guild_source_release
}

run_repository_and_cache_path_cases() (
  local unsafe_repository=""
  local cache_path=""
  local account_path=""
  local original_origin=""

  new_case_home cache-paths
  printf 'target sentinel\n' > "${HOME}/target-sentinel"

  expect_status 2 "missing provider arguments" guild_source_prepare
  expect_status 2 "one provider argument" guild_source_prepare \
    "${SOURCE_REPOSITORY}"
  expect_status 2 "too many provider arguments" guild_source_prepare \
    "${SOURCE_REPOSITORY}" main managed '' extra
  expect_status 2 "unknown provider mode" guild_source_prepare \
    "${SOURCE_REPOSITORY}" main unknown
  expect_status 2 "managed mode with checkout" guild_source_prepare \
    "${SOURCE_REPOSITORY}" main managed "${WORK_REPOSITORY}"
  expect_status 2 "cached mode with checkout" guild_source_prepare \
    "${SOURCE_REPOSITORY}" main cached "${WORK_REPOSITORY}"
  expect_status 2 "local mode without checkout" guild_source_prepare \
    "${SOURCE_REPOSITORY}" main local

  for unsafe_channel in \
    '../main' \
    'main..other' \
    'main.lock' \
    '@' \
    $'main\nother'; do
    expect_status 2 "unsafe channel ${unsafe_channel}" guild_source_prepare \
      "${SOURCE_REPOSITORY}" "${unsafe_channel}" managed
  done

  for unsafe_repository in \
    '../guild-operators' \
    './guild-operators' \
    '/absolute/guild-operators' \
    'fixture-account/../guild-operators' \
    'fixture-account//guild-operators' \
    'fixture-account/guild-operators/extra' \
    'fixture-account/not-guild-operators' \
    '.git/guild-operators' \
    '-option/guild-operators'; do
    expect_status 2 "unsafe repository ${unsafe_repository}" \
      guild_source_prepare "${unsafe_repository}" main managed
    assert_provider_unprepared "unsafe repository ${unsafe_repository}"
  done

  cache_path="$(expected_cache_path)"
  account_path="$(dirname "${cache_path}")"

  mkdir -p "$(dirname "${account_path}")"
  ln -s "${ORIGIN}" "${account_path}"
  expect_status 2 "symlinked account cache path" prepare_managed
  [[ -L "${account_path}" ]] || fail "symlinked cache path was replaced"
  rm -- "${account_path}"

  printf 'not a directory\n' > "${account_path}"
  expect_status 2 "file at account cache path" prepare_managed
  assert_file_contains "${account_path}" 'not a directory' \
    "file cache boundary was modified"
  rm -- "${account_path}"

  mkdir -p "${account_path}"
  ln -s "${ORIGIN}" "${cache_path}"
  expect_status 2 "symlinked repository cache path" prepare_managed
  [[ -L "${cache_path}" ]] || fail "symlinked repository cache was replaced"
  rm -- "${cache_path}"

  printf 'not a repository\n' > "${cache_path}"
  expect_status 2 "file at repository cache path" prepare_managed
  assert_file_contains "${cache_path}" 'not a repository' \
    "file repository cache was modified"
  rm -- "${cache_path}"

  git_fixture init -q "${cache_path}"
  expect_status 2 "non-bare repository cache" prepare_managed
  [[ "$(git_fixture -C "${cache_path}" rev-parse --is-bare-repository)" == false ]] ||
    fail "non-bare cache was replaced"
  rm -rf -- "${cache_path}"

  git_fixture clone -q --mirror "${OTHER_ORIGIN}" "${cache_path}"
  original_origin="$(git_fixture --git-dir="${cache_path}" remote get-url origin)"
  expect_status 2 "wrong-origin repository cache" prepare_managed
  assert_eq \
    "$(git_fixture --git-dir="${cache_path}" remote get-url origin)" \
    "${original_origin}" "wrong-origin cache was repointed"
  rm -rf -- "${cache_path}"

  chmod 0777 "${account_path}"
  expect_status 2 "world-writable account cache" prepare_managed
  [[ "$(file_mode "${account_path}")" == 777 ]] ||
    fail "unsafe account cache permissions were silently rewritten"

  assert_file_contains "${HOME}/target-sentinel" 'target sentinel' \
    "source validation changed a target sentinel"
)

run_valid_cache_tamper_cases() (
  local cache_path=""
  local original_urls=""

  new_case_home cache-duplicate-origin
  prepare_managed || fail "could not initialize duplicate-origin fixture"
  guild_source_release
  cache_path="$(expected_cache_path)"
  git_fixture --git-dir="${cache_path}" config --unset-all remote.origin.url
  git_fixture --git-dir="${cache_path}" config --add remote.origin.url \
    "${OTHER_ORIGIN}"
  git_fixture --git-dir="${cache_path}" config --add remote.origin.url \
    "${ORIGIN}"
  original_urls="$(git_fixture --git-dir="${cache_path}" config --get-all \
    remote.origin.url)"
  expect_status 2 "duplicate cache origin URLs" prepare_managed
  assert_eq \
    "$(git_fixture --git-dir="${cache_path}" config --get-all remote.origin.url)" \
    "${original_urls}" "duplicate origin cache was silently repointed"

  new_case_home cache-duplicate-config
  prepare_managed || fail "could not initialize duplicate-config fixture"
  guild_source_release
  cache_path="$(expected_cache_path)"
  git_fixture --git-dir="${cache_path}" config --add core.bare true
  expect_status 2 "duplicate singleton cache config" prepare_cached

  new_case_home cache-extra-config
  prepare_managed || fail "could not initialize extra-config fixture"
  guild_source_release
  cache_path="$(expected_cache_path)"
  git_fixture --git-dir="${cache_path}" config include.path \
    "${TEST_ROOT}/hostile.gitconfig"
  expect_status 2 "extra cache config" prepare_cached

  new_case_home cache-alternates
  prepare_managed || fail "could not initialize alternates fixture"
  guild_source_release
  cache_path="$(expected_cache_path)"
  printf '%s/objects\n' "${OTHER_ORIGIN}" > \
    "${cache_path}/objects/info/alternates"
  expect_status 2 "cache object alternates" prepare_cached

  new_case_home cache-internal-symlink
  prepare_managed || fail "could not initialize internal-symlink fixture"
  guild_source_release
  cache_path="$(expected_cache_path)"
  mv -- "${cache_path}/HEAD" "${cache_path}/HEAD.real"
  ln -s HEAD.real "${cache_path}/HEAD"
  expect_status 2 "internal cache symlink" prepare_cached

  new_case_home cache-world-writable-file
  prepare_managed || fail "could not initialize cache-permission fixture"
  guild_source_release
  cache_path="$(expected_cache_path)"
  chmod 0666 "${cache_path}/guild-source-cache"
  expect_status 2 "world-writable cache member" prepare_cached
)

run_foreign_cache_owner_case() (
  local cache_path=""
  local foreign_uid=""
  local marker=""

  (( EUID == 0 )) || return 0
  command -v chown >/dev/null 2>&1 || return 0
  foreign_uid="$(id -u nobody 2>/dev/null || true)"
  [[ "${foreign_uid}" =~ ^[0-9]+$ && "${foreign_uid}" != "${EUID}" ]] ||
    return 0

  new_case_home cache-foreign-owner
  prepare_managed || fail "could not initialize foreign-owner fixture"
  guild_source_release
  cache_path="$(expected_cache_path)"
  marker="${cache_path}/guild-source-cache"
  chown "${foreign_uid}" "${marker}"
  expect_status 2 "foreign-owned cache member" prepare_cached
  find "${marker}" -prune -user "${foreign_uid}" -print -quit |
    grep -q . || fail "provider rewrote a foreign-owned cache member"
)

run_cache_root_input_cases() (
  local safe_root=""
  local symlink_parent=""
  local symlink_parent_target=""
  local real_root=""
  local unsafe_root=""
  local writable_parent=""

  new_case_home cache-root-inputs
  safe_root="${GUILD_SOURCE_CACHE_ROOT}"
  real_root="${HOME}/real-cache-root"
  mkdir -p "${real_root}"

  for unsafe_root in \
    'relative/cache-root' \
    "${HOME}/cache-root/../escaped-root"; do
    GUILD_SOURCE_CACHE_ROOT="${unsafe_root}"
    export GUILD_SOURCE_CACHE_ROOT
    expect_status 2 "unsafe cache root ${unsafe_root}" prepare_managed
    assert_provider_unprepared "unsafe cache root ${unsafe_root}"
  done

  GUILD_SOURCE_CACHE_ROOT="${HOME}/cache-root-link"
  ln -s "${real_root}" "${GUILD_SOURCE_CACHE_ROOT}"
  export GUILD_SOURCE_CACHE_ROOT
  expect_status 2 "symlinked configured cache root" prepare_managed
  [[ -L "${GUILD_SOURCE_CACHE_ROOT}" ]] ||
    fail "configured cache-root symlink was replaced"

  rm -- "${GUILD_SOURCE_CACHE_ROOT}"
  printf 'cache root file\n' > "${GUILD_SOURCE_CACHE_ROOT}"
  expect_status 2 "file configured as cache root" prepare_managed
  assert_file_contains "${GUILD_SOURCE_CACHE_ROOT}" 'cache root file' \
    "configured cache-root file was changed"

  rm -- "${GUILD_SOURCE_CACHE_ROOT}"
  symlink_parent_target="${HOME}/real-cache-parent"
  symlink_parent="${HOME}/cache-parent-link"
  mkdir -p "${symlink_parent_target}"
  ln -s "${symlink_parent_target}" "${symlink_parent}"
  GUILD_SOURCE_CACHE_ROOT="${symlink_parent}/guild-operators"
  export GUILD_SOURCE_CACHE_ROOT
  expect_status 2 "symlinked cache-root parent" prepare_managed
  [[ ! -e "${symlink_parent_target}/guild-operators" ]] ||
    fail "provider followed a symlinked cache-root parent"

  writable_parent="${HOME}/world-writable-cache-parent"
  mkdir -p "${writable_parent}"
  chmod 0777 "${writable_parent}"
  GUILD_SOURCE_CACHE_ROOT="${writable_parent}/guild-operators"
  export GUILD_SOURCE_CACHE_ROOT
  expect_status 2 "world-writable cache-root parent" prepare_managed
  [[ "$(file_mode "${writable_parent}")" == 777 ]] ||
    fail "provider rewrote unsafe cache-parent permissions"
  [[ ! -e "${writable_parent}/guild-operators" ]] ||
    fail "provider created a cache below an unsafe parent"

  GUILD_SOURCE_CACHE_ROOT="${safe_root}"
  export GUILD_SOURCE_CACHE_ROOT
)

run_snapshot_path_cases() (
  local unsafe_path=""

  new_case_home snapshot-paths
  prepare_managed || fail "managed preparation failed for snapshot path tests"
  assert_safe_snapshot "managed path validation"
  assert_private_mode "$(dirname "$(expected_cache_path)")" \
    "managed account cache directory"
  assert_private_mode "$(expected_cache_path)" \
    "managed bare cache"

  for unsafe_path in \
    '' \
    '/scripts/common-helper-scripts/safe.sh' \
    '../scripts/common-helper-scripts/safe.sh' \
    'scripts/../files/node-implementations/cnode/config.json' \
    './scripts/common-helper-scripts/safe.sh' \
    'scripts//common-helper-scripts/safe.sh' \
    'scripts-evil/common-helper-scripts/safe.sh' \
    'files-evil/node-implementations/cnode/config.json' \
    'docs/fixture.txt' \
    'scripts/common-helper-scripts' \
    'scripts/common-helper-scripts/missing.sh' \
    $'scripts/common-helper-scripts/control\nname' \
    $'scripts/common-helper-scripts/control\tname' \
    'scripts/common-helper-scripts/unsafe\name'; do
    expect_status 2 "unsafe or unavailable source path" \
      guild_source_path "${unsafe_path}"
  done

  guild_source_release
  assert_provider_unprepared "released provider"
  guild_source_release
)

run_unsafe_object_cases() (
  new_case_home unsafe-link
  expect_status 2 "symlink source object" guild_source_prepare \
    "${SOURCE_REPOSITORY}" unsafe-link managed
  assert_provider_unprepared "symlink source object materialization"
  guild_source_release

  new_case_home unsafe-gitlink
  expect_status 2 "gitlink source object" guild_source_prepare \
    "${SOURCE_REPOSITORY}" unsafe-gitlink managed
  assert_provider_unprepared "gitlink source object materialization"
  guild_source_release

  new_case_home unsafe-name
  expect_failure "control filename in selected source" guild_source_prepare \
    "${SOURCE_REPOSITORY}" unsafe-name managed
  assert_provider_unprepared "control filename materialization"
)

run_hostile_git_environment_case() (
  local poison="${TEST_ROOT}/poison.git"
  local hostile_config="${TEST_ROOT}/hostile.gitconfig"
  local snapshot_path=""

  new_case_home hostile-git
  prepare_managed || fail "initial managed preparation failed"
  guild_source_release
  git_fixture init -q --bare "${poison}"
  printf '[core]\n\tbare = false\n[protocol "file"]\n\tallow = never\n' > \
    "${hostile_config}"
  printf 'poison sentinel\n' > "${poison}/sentinel"

  GIT_DIR="${poison}"
  GIT_WORK_TREE="${TEST_ROOT}/nonexistent-work-tree"
  GIT_INDEX_FILE="${TEST_ROOT}/poison.index"
  GIT_OBJECT_DIRECTORY="${poison}/objects"
  GIT_ALTERNATE_OBJECT_DIRECTORIES="${OTHER_ORIGIN}/objects"
  GIT_CONFIG_GLOBAL="${hostile_config}"
  GIT_CONFIG_SYSTEM="${hostile_config}"
  GIT_CONFIG="${hostile_config}"
  GIT_CONFIG_NOSYSTEM=0
  GIT_COMMON_DIR="${poison}"
  GIT_PREFIX="../../"
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=core.bare
  GIT_CONFIG_VALUE_0=false
  GIT_CONFIG_PARAMETERS="'url.${OTHER_ORIGIN}.insteadof'='${ORIGIN}'"
  GIT_SSL_NO_VERIFY=true
  export GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  export GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
  export GIT_CONFIG GIT_CONFIG_NOSYSTEM GIT_COMMON_DIR GIT_PREFIX
  export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  export GIT_CONFIG_PARAMETERS GIT_SSL_NO_VERIFY

  prepare_managed || fail "sanitized managed preparation rejected hostile Git state"
  assert_eq "$(guild_source_revision)" \
    "$(git_fixture --git-dir="${ORIGIN}" rev-parse refs/heads/main)" \
    "hostile Git environment rewrote the managed origin"
  snapshot_path="$(guild_source_path scripts/common-helper-scripts/safe.sh)" ||
    fail "hostile Git state redirected snapshot lookup"
  assert_file_contains "${snapshot_path}" '#!/usr/bin/env bash' \
    "hostile Git state snapshot"
  assert_file_contains "${poison}/sentinel" 'poison sentinel' \
    "hostile Git environment reached the poison repository"
  [[ ! -e "${GIT_INDEX_FILE}" ]] ||
    fail "hostile Git environment created an inherited index"
  guild_source_release
)

run_refresh_and_initialization_failure_cases() (
  local cache_path=""
  local offline_origin="${ORIGIN}.offline"

  new_case_home cached-without-cache
  expect_status 1 "cached mode without a cache" prepare_cached
  assert_provider_unprepared "cached mode without a cache"

  new_case_home refresh-failure
  prepare_managed || fail "initial cache preparation failed"
  guild_source_release
  cache_path="$(expected_cache_path)"

  mv -- "${ORIGIN}" "${offline_origin}"
  expect_status 1 "managed refresh failure" prepare_managed
  assert_provider_unprepared "managed refresh failure"
  prepare_cached || fail "explicit cached mode failed with the origin offline"
  assert_safe_snapshot "explicit cached mode"
  guild_source_release
  mv -- "${offline_origin}" "${ORIGIN}"

  [[ -d "${cache_path}" ]] || fail "failed refresh destroyed a valid cache"

  new_case_home initialization-failure
  cache_path="$(expected_cache_path)"
  printf 'target sentinel\n' > "${HOME}/target-sentinel"
  mv -- "${ORIGIN}" "${offline_origin}"
  expect_status 1 "initial clone failure" prepare_managed
  mv -- "${offline_origin}" "${ORIGIN}"
  [[ ! -e "${cache_path}" ]] ||
    fail "failed initialization published a repository cache"
  assert_provider_unprepared "initial clone failure"
  assert_file_contains "${HOME}/target-sentinel" 'target sentinel' \
    "failed initialization changed target state"
)

run_cache_corruption_case() (
  local cache_path=""
  local revision=""
  local object_path=""
  local replacement=""

  new_case_home corrupt-cache
  prepare_managed || fail "cache preparation failed for corruption test"
  revision="$(guild_source_revision)"
  guild_source_release
  cache_path="$(expected_cache_path)"
  object_path="${cache_path}/objects/${revision:0:2}/${revision:2}"

  if [[ -f "${object_path}" ]]; then
    replacement="${TEST_ROOT}/corrupt-object"
    printf 'corrupt object\n' > "${replacement}"
    mv -f -- "${replacement}" "${object_path}"
  else
    printf 'this is not Git config\n' > "${cache_path}/config"
  fi

  expect_failure "corrupt cache" prepare_cached
  assert_provider_unprepared "corrupt cache"
)

run_local_checkout_cases() (
  local checkout=""
  local checkout_link=""
  local checkout_status=""
  local linked_checkout=""
  local worktree_source=""
  local fsmonitor_hook="${TEST_ROOT}/fsmonitor-hook.sh"
  local fsmonitor_sentinel="${TEST_ROOT}/fsmonitor-sentinel"
  local tracked_file="scripts/common-helper-scripts/safe.sh"

  new_case_home local-checkouts

  checkout="${TEST_ROOT}/checkout-wrong-origin"
  git_fixture clone -q "${OTHER_ORIGIN}" "${checkout}"
  assert_local_failure_without_mutation \
    "${checkout}" main "local checkout with wrong origin"

  checkout="${TEST_ROOT}/checkout-path-validation"
  checkout_link="${TEST_ROOT}/checkout-path-link"
  git_fixture clone -q "${ORIGIN}" "${checkout}"
  checkout_status="$(checkout_fingerprint "${checkout}")"
  ln -s "${checkout}" "${checkout_link}"
  expect_status 2 "symlinked local checkout" guild_source_prepare \
    "${SOURCE_REPOSITORY}" main local "${checkout_link}"
  (
    cd "${TEST_ROOT}"
    expect_status 2 "relative local checkout" guild_source_prepare \
      "${SOURCE_REPOSITORY}" main local checkout-path-validation
  )
  assert_eq "$(checkout_fingerprint "${checkout}")" "${checkout_status}" \
    "local checkout path validation mutated the checkout"

  checkout="${TEST_ROOT}/checkout-wrong-ref"
  git_fixture clone -q "${ORIGIN}" "${checkout}"
  assert_local_failure_without_mutation \
    "${checkout}" safe-tag "local checkout on the wrong ref"

  checkout="${TEST_ROOT}/checkout-detached"
  git_fixture clone -q "${ORIGIN}" "${checkout}"
  git_in "${checkout}" checkout -q --detach HEAD
  assert_local_failure_without_mutation \
    "${checkout}" main "detached local checkout"

  checkout="${TEST_ROOT}/checkout-deleted"
  git_fixture clone -q "${ORIGIN}" "${checkout}"
  rm -- "${checkout}/${tracked_file}"
  assert_local_failure_without_mutation \
    "${checkout}" main "local checkout with a deleted tracked path"
  [[ ! -e "${checkout}/${tracked_file}" ]] ||
    fail "provider restored a deleted local checkout path"

  checkout="${TEST_ROOT}/checkout-untracked"
  git_fixture clone -q "${ORIGIN}" "${checkout}"
  printf 'untracked allowed content\n' > \
    "${checkout}/scripts/common-helper-scripts/untracked.sh"
  assert_local_failure_without_mutation \
    "${checkout}" main "local checkout with an untracked allowed path"
  assert_file_contains \
    "${checkout}/scripts/common-helper-scripts/untracked.sh" \
    'untracked allowed content' \
    "provider changed an untracked local checkout path"

  checkout="${TEST_ROOT}/checkout-fsmonitor"
  git_fixture clone -q "${ORIGIN}" "${checkout}"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "${fsmonitor_sentinel}"
    printf '%s\n' 'exit 1'
  } > "${fsmonitor_hook}"
  chmod 0700 "${fsmonitor_hook}"
  git_in "${checkout}" config core.fsmonitor "${fsmonitor_hook}"
  rm -f -- "${fsmonitor_sentinel}"
  guild_source_prepare "${SOURCE_REPOSITORY}" main local "${checkout}" ||
    fail "local checkout with configured fsmonitor was rejected"
  guild_source_release
  [[ ! -e "${fsmonitor_sentinel}" ]] ||
    fail "local source preparation executed core.fsmonitor"

  worktree_source="${TEST_ROOT}/checkout-worktree-source"
  linked_checkout="${TEST_ROOT}/checkout-linked-worktree"
  git_fixture clone -q "${ORIGIN}" "${worktree_source}"
  git_in "${worktree_source}" checkout -q -b parking-worktree-test
  git_in "${worktree_source}" worktree add -q "${linked_checkout}" main
  checkout_status="$(checkout_fingerprint "${linked_checkout}")"
  guild_source_prepare "${SOURCE_REPOSITORY}" main local \
    "${linked_checkout}" || fail "clean linked worktree was rejected"
  assert_safe_snapshot "clean linked worktree"
  guild_source_release
  assert_eq "$(checkout_fingerprint "${linked_checkout}")" \
    "${checkout_status}" "linked worktree mutation"
)

run_github_origin_normalization_cases() {
  local expected='https://github.com/Fixture-Account/guild-operators.git'
  local actual=""

  for actual in \
    'https://github.com/fixture-account/guild-operators' \
    'https://github.com/fixture-account/guild-operators.git/' \
    'git@github.com:fixture-account/guild-operators.git' \
    'ssh://git@github.com/Fixture-Account/guild-operators.git'; do
    _guild_source_local_origin_matches "${actual}" "${expected}" ||
      fail "normalized GitHub origin was rejected: ${actual}"
  done
  if _guild_source_local_origin_matches \
    'https://github.com/other/guild-operators.git' "${expected}"; then
    fail "mismatched normalized GitHub origin was accepted"
  fi
}

run_inherited_snapshot_state_case() (
  local sentinel="${TEST_ROOT}/guild-source-transaction.forged"
  local snapshot="${sentinel}/snapshot"
  local child="${TEST_ROOT}/inherited-state-child.sh"

  mkdir -p "${snapshot}"
  printf 'forged-token\n' > "${snapshot}/guild-source-snapshot"
  printf 'do not delete\n' > "${snapshot}/sentinel"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '. "$1"' \
    'guild_source_release' > "${child}"
  chmod 0755 "${child}"

  _GUILD_SOURCE_PREPARED="Y" \
  _GUILD_SOURCE_SNAPSHOT="${snapshot}" \
  _GUILD_SOURCE_SNAPSHOT_CONTAINER="${sentinel}" \
  _GUILD_SOURCE_SNAPSHOT_PARENT="${TEST_ROOT}" \
  _GUILD_SOURCE_SNAPSHOT_TOKEN="forged-token" \
    "${BASH}" "${child}" "${DISPATCHER}"

  assert_file_contains "${snapshot}/sentinel" 'do not delete' \
    "forged inherited provider state deleted a sentinel"
)

run_missing_git_case() (
  local status=0

  new_case_home missing-git
  GUILD_SOURCE_GIT_BIN="${TEST_ROOT}/missing-git"
  export GUILD_SOURCE_GIT_BIN
  set +e
  prepare_managed >"${TEST_ROOT}/missing-git.stdout" \
    2>"${TEST_ROOT}/missing-git.stderr"
  status=$?
  set -e
  [[ ${status} -ne 0 ]] || fail "provider succeeded without Git"
)

run_repository_and_cache_path_cases
run_valid_cache_tamper_cases
run_foreign_cache_owner_case
run_cache_root_input_cases
run_snapshot_path_cases
run_unsafe_object_cases
run_hostile_git_environment_case
run_refresh_and_initialization_failure_cases
run_cache_corruption_case
run_local_checkout_cases
run_github_origin_normalization_cases
run_inherited_snapshot_state_case
run_missing_git_case

printf 'Guild source safety tests passed\n'
