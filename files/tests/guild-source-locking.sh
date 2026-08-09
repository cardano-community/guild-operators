#!/usr/bin/env bash
# Exercise source-cache serialization and catchable interruption cleanup with
# real local Git repositories. No deployment target is created or modified.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'Guild source locking tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DISPATCHER="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-source-locking.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
REAL_GIT="$(command -v git || true)"
ORIGIN="${TEST_ROOT}/origin.git"
AUTHOR="${TEST_ROOT}/author"
GIT_WRAPPER="${TEST_ROOT}/git-wrapper.sh"
SOURCE_REPOSITORY="locking-account/guild-operators"
SOURCE_CHANNEL="main"

cleanup() {
  guild_source_release >/dev/null 2>&1 || true
  if [[ "${GUILD_SOURCE_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'Preserved source-locking fixture: %s\n' "${TEST_ROOT}" >&2
    return
  fi
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

wait_for_file() {
  local path="$1"
  local description="$2"
  local attempt=0

  for (( attempt = 0; attempt < 100; attempt++ )); do
    [[ -e "${path}" ]] && return 0
    sleep 0.05
  done
  fail "timed out waiting for ${description}"
}

assert_directory_empty() {
  local path="$1"
  local description="$2"

  if [[ -d "${path}" ]] &&
     find "${path}" -mindepth 1 -print -quit | grep -q .; then
    fail "${description} retained temporary state"
  fi
}

[[ -n "${REAL_GIT}" ]] || fail 'git is unavailable'
for required_command in chmod find grep mkdir mktemp rm sed sleep; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

git_fixture() {
  "${REAL_GIT}" "$@"
}

git_fixture init -q --bare "${ORIGIN}"
git_fixture init -q "${AUTHOR}"
git_fixture -C "${AUTHOR}" config user.name 'Guild source lock fixture'
git_fixture -C "${AUTHOR}" config user.email fixture@example.invalid
git_fixture -C "${AUTHOR}" checkout -q -b "${SOURCE_CHANNEL}"
git_fixture -C "${AUTHOR}" remote add origin "${ORIGIN}"
mkdir -p "${AUTHOR}/scripts/common-helper-scripts" "${AUTHOR}/files"
printf '#!/usr/bin/env bash\nprintf "locking fixture\\n"\n' > \
  "${AUTHOR}/scripts/common-helper-scripts/fixture.sh"
printf 'locking fixture\n' > "${AUTHOR}/files/fixture.txt"
git_fixture -C "${AUTHOR}" add scripts files
git_fixture -C "${AUTHOR}" commit -q -m 'source locking fixture'
git_fixture -C "${AUTHOR}" push -q origin "${SOURCE_CHANNEL}"
git_fixture --git-dir="${ORIGIN}" symbolic-ref HEAD \
  "refs/heads/${SOURCE_CHANNEL}"

# This wrapper delegates every operation to the real Git binary. Selected
# commands can be paused after the provider owns its cache lock, giving the
# test deterministic observation and interruption points.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'matched_command="N"'
  printf '%s\n' 'matched_argument="N"'
  printf '%s\n' 'for argument in "$@"; do'
  printf '%s\n' '  [[ "${argument}" == "${GUILD_SOURCE_TEST_HOLD_COMMAND:-}" ]] && matched_command="Y"'
  printf '%s\n' '  [[ -z "${GUILD_SOURCE_TEST_HOLD_ARGUMENT:-}" || "${argument}" == "${GUILD_SOURCE_TEST_HOLD_ARGUMENT}" ]] && matched_argument="Y"'
  printf '%s\n' 'done'
  printf '%s\n' 'if [[ -n "${GUILD_SOURCE_TEST_HOLD_COMMAND:-}" && "${matched_command}" == "Y" && "${matched_argument}" == "Y" ]]; then'
  printf '%s\n' '  printf "%s\n" "$$" > "${GUILD_SOURCE_TEST_HOLD_MARKER:?}"'
  printf '%s\n' '  while [[ ! -e "${GUILD_SOURCE_TEST_HOLD_RELEASE:?}" ]]; do sleep 0.05; done'
  printf '%s\n' 'fi'
  printf '%s\n' 'exec "${GUILD_SOURCE_TEST_REAL_GIT:?}" "$@"'
} > "${GIT_WRAPPER}"
chmod 0700 "${GIT_WRAPPER}"

# shellcheck source=/dev/null
. "${DISPATCHER}"

guild_source_repository_url() {
  [[ "${1:-}" == "${SOURCE_REPOSITORY}" ]] || return 2
  printf '%s\n' "${ORIGIN}"
}

export GUILD_SOURCE_GIT_BIN="${GIT_WRAPPER}"
export GUILD_SOURCE_TEST_REAL_GIT="${REAL_GIT}"
export GUILD_SOURCE_LOCK_TIMEOUT=5

select_case_root() {
  local name="$1"

  HOME="${TEST_ROOT}/${name}/home"
  XDG_CACHE_HOME="${HOME}/.cache"
  GUILD_SOURCE_CACHE_ROOT="${XDG_CACHE_HOME}/guild-operators"
  GUILD_SOURCE_TMP_ROOT="${TEST_ROOT}/${name}/snapshots"
  export HOME XDG_CACHE_HOME GUILD_SOURCE_CACHE_ROOT GUILD_SOURCE_TMP_ROOT
  mkdir -p "${HOME}" "${GUILD_SOURCE_TMP_ROOT}"
}

clear_hold() {
  unset GUILD_SOURCE_TEST_HOLD_COMMAND GUILD_SOURCE_TEST_HOLD_ARGUMENT
  unset GUILD_SOURCE_TEST_HOLD_MARKER GUILD_SOURCE_TEST_HOLD_RELEASE
}

run_directory_lock_recovery_cases() {
  local lock_root=""
  local lock_path=""
  local malformed_path=""
  local symlink_target=""
  local status=0

  select_case_root directory-recovery
  export GUILD_SOURCE_LOCK_BACKEND=directory
  guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" managed ||
    fail 'could not initialize the directory-lock cache fixture'
  guild_source_release

  lock_root="${GUILD_SOURCE_CACHE_ROOT}/locks"
  lock_path="${lock_root}/locking-account.lock.d"
  mkdir -- "${lock_path}"
  chmod 0700 "${lock_path}"
  printf '%s\n' 2147483647 > "${lock_path}/owner"
  chmod 0600 "${lock_path}/owner"
  guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" cached ||
    fail 'a stale directory lock was not reclaimed'
  guild_source_release
  [[ ! -e "${lock_path}" ]] || fail 'stale directory lock remained published'

  mkdir -- "${lock_path}"
  chmod 0700 "${lock_path}"
  printf '%s\n' "${BASHPID}" > "${lock_path}/owner"
  chmod 0600 "${lock_path}/owner"
  GUILD_SOURCE_LOCK_TIMEOUT=1
  export GUILD_SOURCE_LOCK_TIMEOUT
  set +e
  guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" cached
  status=$?
  set -e
  [[ ${status} -eq 1 ]] ||
    fail "a live directory lock returned status ${status}, expected 1"
  [[ -d "${lock_path}" ]] || fail 'live directory lock was removed'
  rm -f -- "${lock_path}/owner"
  rmdir -- "${lock_path}"

  mkdir -- "${lock_path}"
  chmod 0700 "${lock_path}"
  printf 'not-a-pid\n' > "${lock_path}/owner"
  chmod 0600 "${lock_path}/owner"
  set +e
  guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" cached
  status=$?
  set -e
  [[ ${status} -eq 2 ]] ||
    fail "a malformed directory lock returned status ${status}, expected 2"
  malformed_path="${lock_path}/owner"
  [[ -f "${malformed_path}" ]] || fail 'malformed lock was silently replaced'
  rm -f -- "${malformed_path}"
  rmdir -- "${lock_path}"

  symlink_target="${TEST_ROOT}/directory-lock-symlink-target"
  mkdir -- "${symlink_target}"
  ln -s "${symlink_target}" "${lock_path}"
  set +e
  guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" cached
  status=$?
  set -e
  [[ ${status} -eq 2 ]] ||
    fail "a symlinked directory lock returned status ${status}, expected 2"
  [[ -L "${lock_path}" ]] || fail 'symlinked lock was silently replaced'
  rm -- "${lock_path}"
  GUILD_SOURCE_LOCK_TIMEOUT=5
  export GUILD_SOURCE_LOCK_TIMEOUT
}

run_noclobber_case() (
  select_case_root noclobber
  export GUILD_SOURCE_LOCK_BACKEND=directory
  set -o noclobber
  guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" managed ||
    fail 'provider failed with caller noclobber enabled'
  guild_source_release
)

run_serialization_case() {
  local backend="$1"
  local first_pid=0
  local second_pid=0
  local hold_marker="${TEST_ROOT}/serialization-${backend}.hold"
  local hold_release="${TEST_ROOT}/serialization-${backend}.release"
  local second_done="${TEST_ROOT}/serialization-${backend}.second-done"

  select_case_root "serialization-${backend}"
  export GUILD_SOURCE_LOCK_BACKEND="${backend}"
  export GUILD_SOURCE_TEST_HOLD_COMMAND=ls-remote
  export GUILD_SOURCE_TEST_HOLD_ARGUMENT=''
  export GUILD_SOURCE_TEST_HOLD_MARKER="${hold_marker}"
  export GUILD_SOURCE_TEST_HOLD_RELEASE="${hold_release}"
  (
    guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" managed
    guild_source_release
  ) > "${TEST_ROOT}/serialization-${backend}.first.out" \
    2> "${TEST_ROOT}/serialization-${backend}.first.err" &
  first_pid=$!
  wait_for_file "${hold_marker}" "${backend} holder"

  clear_hold
  (
    guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" cached
    guild_source_release
    : > "${second_done}"
  ) > "${TEST_ROOT}/serialization-${backend}.second.out" \
    2> "${TEST_ROOT}/serialization-${backend}.second.err" &
  second_pid=$!
  sleep 0.25
  [[ ! -e "${second_done}" ]] ||
    fail "${backend} source-cache users were not serialized"

  : > "${hold_release}"
  wait "${first_pid}" || fail "${backend} lock holder failed"
  wait "${second_pid}" || fail "${backend} lock waiter failed"
  [[ -e "${second_done}" ]] || fail "${backend} lock waiter never completed"
}

run_interruption_case() {
  local phase="$1"
  local hold_command="$2"
  local hold_argument="$3"
  local outer_pid=0
  local worker_pid=0
  local command_pid=0
  local status=0
  local hold_marker="${TEST_ROOT}/interrupt-${phase}.hold"
  local hold_release="${TEST_ROOT}/interrupt-${phase}.release"
  local lock_path=""
  local account_path=""

  select_case_root "interrupt-${phase}"
  export GUILD_SOURCE_LOCK_BACKEND=directory
  if [[ "${phase}" == export ]]; then
    clear_hold
    guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" managed ||
      fail 'could not initialize the interrupted-export cache fixture'
    guild_source_release
  fi

  export GUILD_SOURCE_TEST_HOLD_COMMAND="${hold_command}"
  export GUILD_SOURCE_TEST_HOLD_ARGUMENT="${hold_argument}"
  export GUILD_SOURCE_TEST_HOLD_MARKER="${hold_marker}"
  export GUILD_SOURCE_TEST_HOLD_RELEASE="${hold_release}"
  (
    if [[ "${phase}" == export ]]; then
      guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" cached
    else
      guild_source_prepare "${SOURCE_REPOSITORY}" "${SOURCE_CHANNEL}" managed
    fi
  ) > "${TEST_ROOT}/interrupt-${phase}.out" \
    2> "${TEST_ROOT}/interrupt-${phase}.err" &
  outer_pid=$!

  wait_for_file "${hold_marker}" "interrupted ${phase} operation"
  lock_path="${GUILD_SOURCE_CACHE_ROOT}/locks/locking-account.lock.d"
  wait_for_file "${lock_path}/owner" "interrupted ${phase} lock owner"
  worker_pid="$(sed -n '1p' "${lock_path}/owner")"
  [[ "${worker_pid}" =~ ^[0-9]+$ ]] ||
    fail "interrupted ${phase} lock recorded an invalid owner"
  if [[ "${phase}" == initialize ]]; then
    command_pid="$(sed -n '1p' "${hold_marker}")"
    [[ "${command_pid}" =~ ^[0-9]+$ ]] ||
      fail "interrupted fetch recorded an invalid command PID"
    kill -TERM "${command_pid}" 2>/dev/null ||
      fail "could not interrupt the provider's Git fetch"
  else
    kill -TERM "${worker_pid}" 2>/dev/null ||
      fail "could not signal interrupted ${phase} worker"
    : > "${hold_release}"
  fi
  set +e
  wait "${outer_pid}"
  status=$?
  set -e
  [[ ${status} -ne 0 ]] ||
    fail "interrupted ${phase} preparation unexpectedly succeeded"
  [[ ! -e "${lock_path}" ]] ||
    fail "interrupted ${phase} preparation retained its cache lock"
  assert_directory_empty "${GUILD_SOURCE_TMP_ROOT}" \
    "interrupted ${phase} preparation"

  account_path="${GUILD_SOURCE_CACHE_ROOT}/locking-account"
  if [[ "${phase}" == initialize ]]; then
    [[ ! -e "${account_path}/repository.git" ]] ||
      fail 'interrupted initialization published a trusted cache'
    if [[ -d "${account_path}" ]] &&
       find "${account_path}" -maxdepth 1 -name '.repository.git.init.*' \
         -print -quit | grep -q .; then
      fail 'interrupted initialization retained a partial cache'
    fi
  else
    [[ "$(_guild_source_git --git-dir="${account_path}/repository.git" \
      rev-parse --is-bare-repository)" == true ]] ||
      fail 'interrupted export damaged the existing cache'
  fi
  clear_hold
}

run_directory_lock_recovery_cases
run_noclobber_case
run_serialization_case directory
if command -v flock >/dev/null 2>&1; then
  run_serialization_case flock
fi
run_interruption_case initialize fetch ''
run_interruption_case export cat-file blob

unset GUILD_SOURCE_LOCK_BACKEND
clear_hold
printf 'Guild source locking and interruption tests passed\n'
