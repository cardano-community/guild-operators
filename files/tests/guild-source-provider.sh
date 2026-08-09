#!/usr/bin/env bash
# Exercise the dormant Guild source-provider API exclusively against local Git
# repositories. No deployment target, manifest, or external service is used.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'Guild source-provider tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PROVIDER_SCRIPT="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"
REAL_GIT="$(command -v git || true)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-source-provider.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
TEST_HOME="${TEST_ROOT}/home"
TEST_TMP="${TEST_ROOT}/tmp"
ORIGIN_PATH="${TEST_ROOT}/origin.git"
OFFLINE_ORIGIN_PATH="${TEST_ROOT}/origin.offline.git"
AUTHOR_PATH="${TEST_ROOT}/author"
EXPECTED_BINARY="${TEST_ROOT}/expected.bin"
TARGET_PATH="${TEST_ROOT}/deployment-target"
TARGET_MANIFEST="${TARGET_PATH}/.deployment.json"
TARGET_PAYLOAD="${TARGET_PATH}/scripts/cntools.sh"
PRIMARY_REPOSITORY="Alpha/guild-operators"
SECONDARY_REPOSITORY="Beta/guild-operators"
PRIMARY_CACHE="${TEST_HOME}/.cache/guild-operators/alpha/repository.git"
SECONDARY_CACHE="${TEST_HOME}/.cache/guild-operators/beta/repository.git"
PLAIN_RELATIVE_PATH="scripts/provider-fixture.txt"
EXEC_RELATIVE_PATH="scripts/provider-fixture-tool.sh"
BINARY_RELATIVE_PATH="files/provider-fixture.bin"
ADDED_RELATIVE_PATH="scripts/provider-added.txt"

mkdir -p "${TEST_HOME}" "${TEST_TMP}" "$(dirname "${TARGET_PAYLOAD}")"
printf '{"preserve":"manifest"}\n' > "${TARGET_MANIFEST}"
printf 'preserve deployment payload\n' > "${TARGET_PAYLOAD}"
TARGET_MANIFEST_BYTES="$(git hash-object --no-filters "${TARGET_MANIFEST}")"
TARGET_PAYLOAD_BYTES="$(git hash-object --no-filters "${TARGET_PAYLOAD}")"

export HOME="${TEST_HOME}"
export TMPDIR="${TEST_TMP}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export NODE_HOME="${TARGET_PATH}"
unset XDG_CACHE_HOME GUILD_SOURCE_ALLOW_DIRTY

cleanup_test() {
  if declare -F guild_source_release >/dev/null 2>&1; then
    guild_source_release >/dev/null 2>&1 || true
  fi
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

assert_file_bytes() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  [[ -f "${actual}" && ! -L "${actual}" ]] ||
    fail "${context}: provider did not return a regular file"
  cmp -s -- "${expected}" "${actual}" ||
    fail "${context}: bytes differ"
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

assert_read_only_mode() {
  local path="$1"
  local executable="$2"
  local context="$3"
  local mode=""
  local numeric_mode=0

  mode="$(file_mode "${path}")"
  numeric_mode=$((8#${mode}))
  (( (numeric_mode & 0222) == 0 )) ||
    fail "${context}: snapshot mode ${mode} is writable"
  if [[ "${executable}" == "Y" ]]; then
    (( (numeric_mode & 0111) != 0 )) ||
      fail "${context}: executable bit was not retained"
  else
    (( (numeric_mode & 0111) == 0 )) ||
      fail "${context}: non-executable file gained an executable bit"
  fi
}

assert_report() {
  local repository="$1"
  local channel="$2"
  local mode="$3"
  local ref="$4"
  local revision="$5"
  local dirty="$6"
  local digest="${7:-}"
  local report=""

  report="$(guild_source_report)" || fail "source report was unavailable"
  [[ "${report}" != *$'\n'* ]] || fail "source report was not compact JSON"
  jq -e \
    --arg repository "${repository}" \
    --arg channel "${channel}" \
    --arg mode "${mode}" \
    --arg ref "${ref}" \
    --arg revision "${revision}" \
    --argjson dirty "${dirty}" \
    --arg digest "${digest}" '
      type == "object" and
      .repository == $repository and
      .channel == $channel and
      .mode == $mode and
      .ref == $ref and
      .revision == $revision and
      .dirty == $dirty and
      (if $dirty then .treeDigest == $digest
       else (.treeDigest == null or has("treeDigest") == false)
       end)
    ' <<< "${report}" >/dev/null ||
    fail "source report fields changed: ${report}"
}

expect_prepare_failure() {
  local output=""
  local output_file="${TEST_TMP}/prepare-failure.$$"
  local status=0

  set +e
  guild_source_prepare "$@" > "${output_file}" 2>&1
  status=$?
  set -e
  output="$(< "${output_file}")"
  rm -f -- "${output_file}"
  (( status != 0 )) ||
    fail "source prepare unexpectedly succeeded: $*; output: ${output}"
  (( status != 0 )) || fail "source prepare failure returned status zero: $*"
}

assert_no_active_source() {
  local accessor=""

  for accessor in \
    guild_source_revision guild_source_ref guild_source_report; do
    if "${accessor}" >/dev/null 2>&1; then
      fail "${accessor} retained state after a failed/released prepare"
    fi
  done
  if guild_source_path "${PLAIN_RELATIVE_PATH}" >/dev/null 2>&1; then
    fail "guild_source_path retained state after a failed/released prepare"
  fi
}

assert_target_unchanged() {
  assert_eq "$(git hash-object --no-filters "${TARGET_MANIFEST}")" \
    "${TARGET_MANIFEST_BYTES}" "deployment manifest bytes"
  assert_eq "$(git hash-object --no-filters "${TARGET_PAYLOAD}")" \
    "${TARGET_PAYLOAD_BYTES}" "deployment payload bytes"
  assert_eq "$(find "${TARGET_PATH}" -mindepth 1 -print | sort | wc -l | tr -d ' ')" \
    "3" "deployment target entry count"
}

git_commit() {
  local message="$1"

  git -C "${AUTHOR_PATH}" add -A
  git -C "${AUTHOR_PATH}" commit -q -m "${message}"
  git -C "${AUTHOR_PATH}" rev-parse HEAD
}

push_branch() {
  local branch="$1"
  git -C "${AUTHOR_PATH}" push -q --force origin \
    "refs/heads/${branch}:refs/heads/${branch}"
}

write_plain_fixture() {
  printf '%s\n' "$1" > "${AUTHOR_PATH}/${PLAIN_RELATIVE_PATH}"
}

snapshot_plain_path() {
  local path=""
  path="$(guild_source_path "${PLAIN_RELATIVE_PATH}")" ||
    fail "plain fixture path was unavailable"
  [[ "${path}" == /* ]] || fail "provider path was not absolute: ${path}"
  printf '%s\n' "${path}"
}

for required_command in cmp find git jq sort stat; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

# shellcheck source=/dev/null
. "${PROVIDER_SCRIPT}"

# Replace the public HTTPS locator with the same real local bare origin for all
# fixture accounts. This override is the test seam; Git itself is never faked.
guild_source_repository_url() {
  case "${1:-}" in
    "${PRIMARY_REPOSITORY}"|"${SECONDARY_REPOSITORY}")
      printf '%s\n' "${ORIGIN_PATH}"
      ;;
    *) return 2 ;;
  esac
}

# Build one reusable origin containing ordinary, executable, and binary blobs,
# two branches, exact lightweight/annotated tags, and an ambiguous branch/tag.
git init -q --bare "${ORIGIN_PATH}"
git init -q "${AUTHOR_PATH}"
git -C "${AUTHOR_PATH}" config user.name "Guild source fixture"
git -C "${AUTHOR_PATH}" config user.email "source-fixture@example.invalid"
git -C "${AUTHOR_PATH}" remote add origin "${ORIGIN_PATH}"
git -C "${AUTHOR_PATH}" checkout -q -b main
mkdir -p \
  "${AUTHOR_PATH}/$(dirname "${PLAIN_RELATIVE_PATH}")" \
  "${AUTHOR_PATH}/$(dirname "${BINARY_RELATIVE_PATH}")"
write_plain_fixture "initial source bytes"
printf '#!/usr/bin/env bash\nprintf "fixture executable\\n"\n' \
  > "${AUTHOR_PATH}/${EXEC_RELATIVE_PATH}"
chmod 0755 "${AUTHOR_PATH}/${EXEC_RELATIVE_PATH}"
printf '\000\001\002\003\177\200\376\377binary\r\n' > "${EXPECTED_BINARY}"
cp "${EXPECTED_BINARY}" "${AUTHOR_PATH}/${BINARY_RELATIVE_PATH}"
printf 'fixture license\n' > "${AUTHOR_PATH}/LICENSE"
INITIAL_REVISION="$(git_commit "initial provider fixture")"
push_branch main
git --git-dir="${ORIGIN_PATH}" symbolic-ref HEAD refs/heads/main

git -C "${AUTHOR_PATH}" checkout -q -b feature
write_plain_fixture "feature source bytes"
FEATURE_REVISION="$(git_commit "feature provider fixture")"
push_branch feature
git -C "${AUTHOR_PATH}" checkout -q main

git -C "${AUTHOR_PATH}" tag v-light "${INITIAL_REVISION}"
git -C "${AUTHOR_PATH}" tag -a v-annotated "${INITIAL_REVISION}" \
  -m "annotated provider fixture"
git -C "${AUTHOR_PATH}" branch collision "${INITIAL_REVISION}"
git -C "${AUTHOR_PATH}" branch transition "${INITIAL_REVISION}"
git -C "${AUTHOR_PATH}" branch race "${INITIAL_REVISION}"
git -C "${AUTHOR_PATH}" tag collision "${FEATURE_REVISION}"
git -C "${AUTHOR_PATH}" push -q origin \
  refs/tags/v-light refs/tags/v-annotated refs/tags/collision \
  refs/heads/collision refs/heads/transition refs/heads/race

EXPECTED_INITIAL_PLAIN="${TEST_ROOT}/initial-plain.expected"
printf 'initial source bytes\n' > "${EXPECTED_INITIAL_PLAIN}"
EXPECTED_FEATURE_PLAIN="${TEST_ROOT}/feature-plain.expected"
printf 'feature source bytes\n' > "${EXPECTED_FEATURE_PLAIN}"

# First managed prepare creates the account-specific default bare cache and an
# eager private snapshot with exact bytes and read-only file modes.
guild_source_prepare "${PRIMARY_REPOSITORY}" main
assert_eq "$(guild_source_revision)" "${INITIAL_REVISION}" \
  "first managed revision"
assert_eq "$(guild_source_ref)" "refs/heads/main" "first managed ref"
INITIAL_PLAIN_PATH="$(snapshot_plain_path)"
assert_file_bytes "${INITIAL_PLAIN_PATH}" "${EXPECTED_INITIAL_PLAIN}" \
  "first managed ordinary blob"
assert_read_only_mode "${INITIAL_PLAIN_PATH}" N \
  "first managed ordinary blob"
INITIAL_EXEC_PATH="$(guild_source_path "${EXEC_RELATIVE_PATH}")"
assert_read_only_mode "${INITIAL_EXEC_PATH}" Y \
  "first managed executable blob"
INITIAL_BINARY_PATH="$(guild_source_path "${BINARY_RELATIVE_PATH}")"
assert_file_bytes "${INITIAL_BINARY_PATH}" "${EXPECTED_BINARY}" \
  "first managed binary blob"
assert_read_only_mode "${INITIAL_BINARY_PATH}" N \
  "first managed binary blob"
assert_report "${PRIMARY_REPOSITORY}" main managed refs/heads/main \
  "${INITIAL_REVISION}" false
[[ -d "${PRIMARY_CACHE}" ]] || fail "default managed cache was not created"
[[ "$(git --git-dir="${PRIMARY_CACHE}" rev-parse --is-bare-repository)" == "true" ]] ||
  fail "default managed cache is not bare"
guild_source_release
guild_source_release
assert_no_active_source
[[ ! -e "${INITIAL_PLAIN_PATH}" ]] ||
  fail "release retained the private source snapshot"

# Reusing the cache must fetch a newly advanced branch rather than recloning.
printf 'cache reuse marker\n' > "${PRIMARY_CACHE}/provider-test.marker"
write_plain_fixture "second source bytes"
SECOND_REVISION="$(git_commit "advance main for fetch")"
push_branch main
EXPECTED_SECOND_PLAIN="${TEST_ROOT}/second-plain.expected"
printf 'second source bytes\n' > "${EXPECTED_SECOND_PLAIN}"
guild_source_prepare "${PRIMARY_REPOSITORY}" main managed
assert_eq "$(guild_source_revision)" "${SECOND_REVISION}" \
  "reused cache fetched revision"
[[ -f "${PRIMARY_CACHE}/provider-test.marker" ]] ||
  fail "existing correct cache was replaced instead of reused"
assert_file_bytes "$(snapshot_plain_path)" "${EXPECTED_SECOND_PLAIN}" \
  "reused cache snapshot"
guild_source_release

# Exact branch and tag namespaces are reported. Annotated tags peel to their
# commit while retaining the tag ref itself.
guild_source_prepare "${PRIMARY_REPOSITORY}" feature managed
assert_eq "$(guild_source_revision)" "${FEATURE_REVISION}" \
  "different branch revision"
assert_eq "$(guild_source_ref)" "refs/heads/feature" \
  "different branch ref"
assert_file_bytes "$(snapshot_plain_path)" "${EXPECTED_FEATURE_PLAIN}" \
  "different branch snapshot"
guild_source_release

guild_source_prepare "${PRIMARY_REPOSITORY}" v-light managed
assert_eq "$(guild_source_revision)" "${INITIAL_REVISION}" \
  "lightweight tag revision"
assert_eq "$(guild_source_ref)" "refs/tags/v-light" \
  "lightweight tag ref"
guild_source_release

guild_source_prepare "${PRIMARY_REPOSITORY}" v-annotated managed
assert_eq "$(guild_source_revision)" "${INITIAL_REVISION}" \
  "annotated tag peeled revision"
assert_eq "$(guild_source_ref)" "refs/tags/v-annotated" \
  "annotated tag ref"
guild_source_release

# If a channel moves from the branch namespace to the tag namespace, managed
# refresh removes the obsolete private cache ref. Explicit cached mode must
# then resolve the one currently valid namespace rather than report a stale
# branch/tag ambiguity.
guild_source_prepare "${PRIMARY_REPOSITORY}" transition managed
assert_eq "$(guild_source_ref)" "refs/heads/transition" \
  "transition branch ref"
guild_source_release
git -C "${AUTHOR_PATH}" push -q origin --delete transition
git -C "${AUTHOR_PATH}" tag transition "${FEATURE_REVISION}"
git -C "${AUTHOR_PATH}" push -q origin refs/tags/transition
guild_source_prepare "${PRIMARY_REPOSITORY}" transition managed
assert_eq "$(guild_source_ref)" "refs/tags/transition" \
  "transition tag ref"
assert_eq "$(guild_source_revision)" "${FEATURE_REVISION}" \
  "transition tag revision"
guild_source_release
guild_source_prepare "${PRIMARY_REPOSITORY}" transition cached
assert_eq "$(guild_source_ref)" "refs/tags/transition" \
  "cached transition tag ref"
guild_source_release
git -C "${AUTHOR_PATH}" push -q origin --delete refs/tags/transition
git -C "${AUTHOR_PATH}" push -q origin refs/heads/transition
guild_source_prepare "${PRIMARY_REPOSITORY}" transition managed
assert_eq "$(guild_source_ref)" "refs/heads/transition" \
  "reverse-transition branch ref"
assert_eq "$(guild_source_revision)" "${INITIAL_REVISION}" \
  "reverse-transition branch revision"
guild_source_release
guild_source_prepare "${PRIMARY_REPOSITORY}" transition cached
assert_eq "$(guild_source_ref)" "refs/heads/transition" \
  "cached reverse-transition branch ref"
guild_source_release

# A remote ref moving between ls-remote and fetch must fail without publishing
# the candidate as the durable cached identity. The Git wrapper changes only
# the fixture origin immediately before delegating the fetch to the real Git.
guild_source_prepare "${PRIMARY_REPOSITORY}" race managed
assert_eq "$(guild_source_revision)" "${INITIAL_REVISION}" \
  "initial race cache revision"
guild_source_release
git -C "${AUTHOR_PATH}" checkout -q race
write_plain_fixture "race advertised source bytes"
RACE_ADVERTISED_REVISION="$(git_commit "race advertised revision")"
write_plain_fixture "race fetched source bytes"
RACE_FETCHED_REVISION="$(git_commit "race fetched revision")"
push_branch race
git --git-dir="${ORIGIN_PATH}" update-ref refs/heads/race \
  "${RACE_ADVERTISED_REVISION}"
RACE_WRAPPER="${TEST_ROOT}/race-git-wrapper.sh"
RACE_MARKER="${TEST_ROOT}/race-moved"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'saw_fetch="N"'
  printf '%s\n' 'for argument in "$@"; do'
  printf '%s\n' '  [[ "${argument}" == fetch ]] && saw_fetch="Y"'
  printf '%s\n' 'done'
  printf '%s\n' 'if [[ "${saw_fetch}" == "Y" && ! -e "${GUILD_SOURCE_RACE_MARKER:?}" ]]; then'
  printf '%s\n' '  "${GUILD_SOURCE_RACE_REAL_GIT:?}" --git-dir="${GUILD_SOURCE_RACE_ORIGIN:?}" update-ref refs/heads/race "${GUILD_SOURCE_RACE_FETCHED:?}"'
  printf '%s\n' '  : > "${GUILD_SOURCE_RACE_MARKER}"'
  printf '%s\n' 'fi'
  printf '%s\n' 'exec "${GUILD_SOURCE_RACE_REAL_GIT:?}" "$@"'
} > "${RACE_WRAPPER}"
chmod 0700 "${RACE_WRAPPER}"
export GUILD_SOURCE_GIT_BIN="${RACE_WRAPPER}"
export GUILD_SOURCE_RACE_REAL_GIT="${REAL_GIT}"
export GUILD_SOURCE_RACE_ORIGIN="${ORIGIN_PATH}"
export GUILD_SOURCE_RACE_FETCHED="${RACE_FETCHED_REVISION}"
export GUILD_SOURCE_RACE_MARKER="${RACE_MARKER}"
expect_prepare_failure "${PRIMARY_REPOSITORY}" race managed
[[ -e "${RACE_MARKER}" ]] || fail "race fixture did not move the remote ref"
unset GUILD_SOURCE_GIT_BIN GUILD_SOURCE_RACE_REAL_GIT
unset GUILD_SOURCE_RACE_ORIGIN GUILD_SOURCE_RACE_FETCHED
unset GUILD_SOURCE_RACE_MARKER
guild_source_prepare "${PRIMARY_REPOSITORY}" race cached
assert_eq "$(guild_source_revision)" "${INITIAL_REVISION}" \
  "failed race refresh changed the durable cached revision"
guild_source_release
[[ -z "$(git --git-dir="${PRIMARY_CACHE}" for-each-ref \
  --format='%(refname)' refs/guild-source/candidates)" ]] ||
  fail "failed race refresh retained a candidate ref"
git -C "${AUTHOR_PATH}" checkout -q main

expect_prepare_failure "${PRIMARY_REPOSITORY}" missing-channel managed
assert_no_active_source
expect_prepare_failure "${PRIMARY_REPOSITORY}" collision managed
assert_no_active_source

# A force-updated branch must replace the cached channel ref exactly.
git -C "${AUTHOR_PATH}" reset -q --hard "${INITIAL_REVISION}"
write_plain_fixture "force-updated source bytes"
FORCED_REVISION="$(git_commit "force-update main")"
push_branch main
EXPECTED_FORCED_PLAIN="${TEST_ROOT}/forced-plain.expected"
printf 'force-updated source bytes\n' > "${EXPECTED_FORCED_PLAIN}"
guild_source_prepare "${PRIMARY_REPOSITORY}" main managed
assert_eq "$(guild_source_revision)" "${FORCED_REVISION}" \
  "force-updated managed revision"
assert_file_bytes "$(snapshot_plain_path)" "${EXPECTED_FORCED_PLAIN}" \
  "force-updated managed snapshot"
guild_source_release

# Cached mode is explicit and performs no fetch. Making the fixture origin
# unavailable proves that the already-resolved cached ref is sufficient.
write_plain_fixture "remote-only source bytes"
REMOTE_ONLY_REVISION="$(git_commit "advance origin beyond cache")"
push_branch main
mv "${ORIGIN_PATH}" "${OFFLINE_ORIGIN_PATH}"
guild_source_prepare "${PRIMARY_REPOSITORY}" main cached
assert_eq "$(guild_source_revision)" "${FORCED_REVISION}" \
  "cached mode revision"
assert_eq "$(guild_source_ref)" "refs/heads/main" "cached mode ref"
assert_file_bytes "$(snapshot_plain_path)" "${EXPECTED_FORCED_PLAIN}" \
  "cached mode snapshot"
assert_report "${PRIMARY_REPOSITORY}" main cached refs/heads/main \
  "${FORCED_REVISION}" false
guild_source_release
expect_prepare_failure "${PRIMARY_REPOSITORY}" main managed
assert_no_active_source
mv "${OFFLINE_ORIGIN_PATH}" "${ORIGIN_PATH}"

# A prepared snapshot remains immutable after the remote advances and the
# corresponding cache refs and unreachable objects are aggressively pruned.
guild_source_prepare "${PRIMARY_REPOSITORY}" main managed
assert_eq "$(guild_source_revision)" "${REMOTE_ONLY_REVISION}" \
  "pre-prune managed revision"
IMMUTABLE_PATH="$(snapshot_plain_path)"
EXPECTED_REMOTE_ONLY="${TEST_ROOT}/remote-only.expected"
printf 'remote-only source bytes\n' > "${EXPECTED_REMOTE_ONLY}"
assert_file_bytes "${IMMUTABLE_PATH}" "${EXPECTED_REMOTE_ONLY}" \
  "pre-prune immutable snapshot"

# Rewrite the remote from an older base so the prepared commit becomes truly
# unreachable once its cached refs and reflogs are removed. This proves the
# snapshot does not merely keep reading a still-reachable cache object.
git -C "${AUTHOR_PATH}" reset -q --hard "${INITIAL_REVISION}"
write_plain_fixture "post-prepare remote bytes"
POST_PREPARE_REVISION="$(git_commit "advance after provider prepare")"
push_branch main
git --git-dir="${PRIMARY_CACHE}" fetch -q --force --prune origin \
  '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
while IFS=' ' read -r ref object_id; do
  if [[ "${object_id}" == "${REMOTE_ONLY_REVISION}" ]]; then
    git --git-dir="${PRIMARY_CACHE}" update-ref -d "${ref}"
  fi
done < <(git --git-dir="${PRIMARY_CACHE}" for-each-ref \
  --format='%(refname) %(objectname)')
git --git-dir="${PRIMARY_CACHE}" reflog expire --expire=now --all
git --git-dir="${PRIMARY_CACHE}" gc -q --prune=now
if git --git-dir="${PRIMARY_CACHE}" cat-file -e \
  "${REMOTE_ONLY_REVISION}^{commit}" 2>/dev/null; then
  fail "snapshot-prune fixture left the prepared commit reachable"
fi
assert_eq "$(guild_source_revision)" "${REMOTE_ONLY_REVISION}" \
  "snapshot revision changed after cache pruning"
assert_file_bytes "${IMMUTABLE_PATH}" "${EXPECTED_REMOTE_ONLY}" \
  "snapshot bytes changed after cache pruning"
guild_source_release

# The default cache location is separated by normalized account name.
guild_source_prepare "${SECONDARY_REPOSITORY}" main managed
assert_eq "$(guild_source_revision)" "${POST_PREPARE_REVISION}" \
  "second account revision"
assert_report "${SECONDARY_REPOSITORY}" main managed refs/heads/main \
  "${POST_PREPARE_REVISION}" false
[[ -d "${SECONDARY_CACHE}" ]] ||
  fail "second account did not receive its own default cache"
[[ "${PRIMARY_CACHE}" != "${SECONDARY_CACHE}" ]] ||
  fail "account-specific caches resolved to the same path"
[[ -d "${PRIMARY_CACHE}" ]] || fail "first account cache disappeared"
guild_source_release

# A clean local checkout resolves the current branch but is copied to a private
# snapshot. Reads and release must not change its branch, HEAD, status, or data.
LOCAL_HEAD_BEFORE="$(git -C "${AUTHOR_PATH}" rev-parse HEAD)"
LOCAL_BRANCH_BEFORE="$(git -C "${AUTHOR_PATH}" symbolic-ref --short HEAD)"
LOCAL_STATUS_BEFORE="$(git -C "${AUTHOR_PATH}" status --porcelain=v1 --untracked-files=all)"
LOCAL_PLAIN_BEFORE="$(git hash-object --no-filters "${AUTHOR_PATH}/${PLAIN_RELATIVE_PATH}")"
guild_source_prepare "${PRIMARY_REPOSITORY}" main local "${AUTHOR_PATH}"
assert_eq "$(guild_source_revision)" "${LOCAL_HEAD_BEFORE}" \
  "clean local revision"
assert_eq "$(guild_source_ref)" "refs/heads/main" "clean local ref"
assert_report "${PRIMARY_REPOSITORY}" main local refs/heads/main \
  "${LOCAL_HEAD_BEFORE}" false
LOCAL_SNAPSHOT_PATH="$(snapshot_plain_path)"
[[ "${LOCAL_SNAPSHOT_PATH}" != "${AUTHOR_PATH}/${PLAIN_RELATIVE_PATH}" ]] ||
  fail "local source exposed the editable checkout instead of a snapshot"
assert_read_only_mode "${LOCAL_SNAPSHOT_PATH}" N "clean local snapshot"
guild_source_release
assert_eq "$(git -C "${AUTHOR_PATH}" rev-parse HEAD)" "${LOCAL_HEAD_BEFORE}" \
  "clean local HEAD mutation"
assert_eq "$(git -C "${AUTHOR_PATH}" symbolic-ref --short HEAD)" \
  "${LOCAL_BRANCH_BEFORE}" "clean local branch mutation"
assert_eq "$(git -C "${AUTHOR_PATH}" status --porcelain=v1 --untracked-files=all)" \
  "${LOCAL_STATUS_BEFORE}" "clean local status mutation"
assert_eq "$(git hash-object --no-filters "${AUTHOR_PATH}/${PLAIN_RELATIVE_PATH}")" \
  "${LOCAL_PLAIN_BEFORE}" "clean local byte mutation"

# Dirty local sources require an explicit opt-in and report a deterministic
# digest. Modified and newly added tracked source files belong to the eager
# snapshot, but the working checkout itself remains byte-for-byte untouched.
write_plain_fixture "dirty local source bytes"
printf 'added local source bytes\n' > "${AUTHOR_PATH}/${ADDED_RELATIVE_PATH}"
git -C "${AUTHOR_PATH}" add "${ADDED_RELATIVE_PATH}"
DIRTY_STATUS_BEFORE="$(git -C "${AUTHOR_PATH}" status --porcelain=v1 --untracked-files=all)"
DIRTY_HEAD_BEFORE="$(git -C "${AUTHOR_PATH}" rev-parse HEAD)"
expect_prepare_failure "${PRIMARY_REPOSITORY}" main local "${AUTHOR_PATH}"
assert_no_active_source
assert_eq "$(git -C "${AUTHOR_PATH}" status --porcelain=v1 --untracked-files=all)" \
  "${DIRTY_STATUS_BEFORE}" "rejected dirty local status mutation"

export GUILD_SOURCE_ALLOW_DIRTY=Y
guild_source_prepare "${PRIMARY_REPOSITORY}" main local "${AUTHOR_PATH}"
DIRTY_REPORT="$(guild_source_report)"
DIRTY_DIGEST="$(jq -er '.treeDigest' <<< "${DIRTY_REPORT}")" ||
  fail "dirty local report omitted its tree digest"
[[ "${DIRTY_DIGEST}" =~ ^[0-9a-f]{64}$ ]] ||
  fail "dirty local tree digest is not a SHA-256 value: ${DIRTY_DIGEST}"
assert_report "${PRIMARY_REPOSITORY}" main local refs/heads/main \
  "${DIRTY_HEAD_BEFORE}" true "${DIRTY_DIGEST}"
DIRTY_EXPECTED="${TEST_ROOT}/dirty.expected"
printf 'dirty local source bytes\n' > "${DIRTY_EXPECTED}"
assert_file_bytes "$(snapshot_plain_path)" "${DIRTY_EXPECTED}" \
  "dirty tracked local snapshot"
ADDED_EXPECTED="${TEST_ROOT}/added.expected"
printf 'added local source bytes\n' > "${ADDED_EXPECTED}"
assert_file_bytes "$(guild_source_path "${ADDED_RELATIVE_PATH}")" \
  "${ADDED_EXPECTED}" "dirty added local snapshot"
guild_source_release

guild_source_prepare "${PRIMARY_REPOSITORY}" main local "${AUTHOR_PATH}"
assert_eq "$(jq -er '.treeDigest' <<< "$(guild_source_report)")" \
  "${DIRTY_DIGEST}" "stable dirty local tree digest"
guild_source_release
printf 'changed added local source bytes\n' \
  > "${AUTHOR_PATH}/${ADDED_RELATIVE_PATH}"
guild_source_prepare "${PRIMARY_REPOSITORY}" main local "${AUTHOR_PATH}"
CHANGED_DIRTY_DIGEST="$(jq -er '.treeDigest' <<< "$(guild_source_report)")"
[[ "${CHANGED_DIRTY_DIGEST}" != "${DIRTY_DIGEST}" ]] ||
  fail "dirty local digest ignored a changed added source file"
guild_source_release
unset GUILD_SOURCE_ALLOW_DIRTY
assert_eq "$(git -C "${AUTHOR_PATH}" rev-parse HEAD)" "${DIRTY_HEAD_BEFORE}" \
  "dirty local HEAD mutation"
assert_eq "$(git -C "${AUTHOR_PATH}" symbolic-ref --short HEAD)" \
  "${LOCAL_BRANCH_BEFORE}" "dirty local branch mutation"
assert_eq "$(git -C "${AUTHOR_PATH}" status --porcelain=v1 --untracked-files=all)" \
  "$(printf 'AM %s\n M %s' "${ADDED_RELATIVE_PATH}" "${PLAIN_RELATIVE_PATH}")" \
  "dirty local status mutation"

# A second prepare failure must tear down the first transaction and clear every
# accessor. Release remains safe and idempotent in that state.
guild_source_prepare "${PRIMARY_REPOSITORY}" main managed
PRE_FAILURE_PATH="$(snapshot_plain_path)"
expect_prepare_failure "${PRIMARY_REPOSITORY}" missing-after-success managed
assert_no_active_source
[[ ! -e "${PRE_FAILURE_PATH}" ]] ||
  fail "failed second prepare retained the preceding private snapshot"
guild_source_release
guild_source_release
assert_no_active_source

assert_target_unchanged
printf 'Guild source-provider contract tests passed\n'
