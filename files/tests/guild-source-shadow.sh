#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'guild source shadow parity tests skipped: Bash 4.4+ required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REAL_GIT="$(command -v git || true)"
[[ -n "${REAL_GIT}" ]] || {
  printf 'guild source shadow parity tests skipped: git is unavailable\n'
  exit 0
}

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"

fail() {
  printf 'guild source shadow parity test failed: %s\n' "$1" >&2
  exit 1
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

test_root="$(mktemp -d "${TMPDIR:-/tmp}/guild-source-shadow.XXXXXX")"
test_root="$(cd "${test_root}" && pwd -P)"
cleanup() {
  guild_source_release >/dev/null 2>&1 || true
  chmod -R u+w "${test_root}" >/dev/null 2>&1 || true
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG
unset GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR
unset GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX GIT_WORK_TREE

export HOME="${test_root}/home"
export XDG_CACHE_HOME="${test_root}/xdg-cache"
export XDG_CONFIG_HOME="${test_root}/xdg-config"
mkdir -p "${HOME}" "${XDG_CACHE_HOME}" "${XDG_CONFIG_HOME}"

seed_repo="${test_root}/seed"
bare_origin="${test_root}/origin.git"
mkdir -p "${seed_repo}"
"${REAL_GIT}" -C "${seed_repo}" init -q
"${REAL_GIT}" -C "${seed_repo}" checkout -q -b shadow
cp -R "${REPO_ROOT}/scripts" "${seed_repo}/scripts"
cp -R "${REPO_ROOT}/files" "${seed_repo}/files"
"${REAL_GIT}" -C "${seed_repo}" add scripts files
"${REAL_GIT}" -C "${seed_repo}" \
  -c user.name='Guild source test' \
  -c user.email='guild-source@example.invalid' \
  commit -q -m 'shadow source fixture'
"${REAL_GIT}" clone -q --bare "${seed_repo}" "${bare_origin}"
"${REAL_GIT}" -C "${seed_repo}" remote add origin "file://${bare_origin}"

guild_source_repository_url() {
  printf 'file://%s' "${bare_origin}"
}

export GUILD_SOURCE_CACHE_ROOT="${test_root}/cache root/guild-operators"
export GUILD_SOURCE_GIT_BIN="${REAL_GIT}"
export GUILD_SOURCE_LOCK_TIMEOUT=5
export GUILD_SOURCE_TMP_ROOT="${test_root}/snapshots"
mkdir -p "${GUILD_SOURCE_TMP_ROOT}"

guild_source_prepare 'Shadow-Account/guild-operators' shadow managed ||
  fail 'managed preparation failed'

resolved_revision="$(guild_source_revision)"
expected_revision="$("${REAL_GIT}" -C "${seed_repo}" rev-parse HEAD)"
[[ "${resolved_revision}" == "${expected_revision}" ]] ||
  fail 'provider revision differs from the shadow fixture commit'
[[ "$(guild_source_ref)" == 'refs/heads/shadow' ]] ||
  fail 'provider did not report the exact resolved head'

# Model the legacy raw.githubusercontent.com transport locally: the shim
# accepts only a URL pinned to the provider's resolved object ID, captures the
# requested repository-relative path, and obtains the corresponding raw blob
# from the fixture origin. No mutable channel is accepted as an oracle.
raw_prefix="https://raw.githubusercontent.com/Shadow-Account/guild-operators/${resolved_revision}/"
legacy_raw_fetch() {
  local raw_url="$1"
  local output_path="$2"
  local relative_path=""

  [[ "${raw_url}" == "${raw_prefix}"* ]] ||
    fail "legacy raw URL was not pinned to ${resolved_revision}: ${raw_url}"
  relative_path="${raw_url#"${raw_prefix}"}"
  [[ -n "${relative_path}" && "${relative_path}" != "${raw_url}" ]] ||
    fail "legacy raw URL omitted its repository path: ${raw_url}"
  "${REAL_GIT}" --git-dir="${bare_origin}" \
    cat-file blob "${resolved_revision}:${relative_path}" > "${output_path}" ||
    fail "legacy raw fixture could not fetch ${relative_path}"
}

tree_records="${test_root}/tree.records"
"${REAL_GIT}" -C "${seed_repo}" ls-tree -r -z --full-tree HEAD -- \
  scripts files > "${tree_records}"

expected_paths="${test_root}/expected.paths"
actual_paths="${test_root}/actual.paths"
: > "${expected_paths}"
entry_count=0
snapshot_root=""
while IFS= read -r -d '' tree_entry; do
  tree_metadata="${tree_entry%%$'\t'*}"
  relative_path="${tree_entry#*$'\t'}"
  file_mode="${tree_metadata%% *}"
  snapshot_path="$(guild_source_path "${relative_path}")" ||
    fail "provider omitted ${relative_path}"
  if [[ -z "${snapshot_root}" ]]; then
    snapshot_root="${snapshot_path%/"${relative_path}"}"
  fi
  printf '%s\n' "${relative_path}" >> "${expected_paths}"
  expected_path="${test_root}/expected.${entry_count}"
  raw_url="${raw_prefix}${relative_path}"
  [[ "${raw_url}" != *'/shadow/'* ]] ||
    fail "legacy raw comparison used the mutable channel: ${raw_url}"
  legacy_raw_fetch "${raw_url}" "${expected_path}"
  cmp -s "${snapshot_path}" "${expected_path}" ||
    fail "snapshot bytes differ for ${relative_path}"
  [[ -O "${snapshot_path}" ]] ||
    fail "snapshot file has an unexpected owner: ${relative_path}"
  case "${file_mode}" in
    100755)
      [[ "$(file_mode "${snapshot_path}")" == 500 ]] ||
        fail "snapshot executable mode is not 0500 for ${relative_path}"
      ;;
    100644)
      [[ "$(file_mode "${snapshot_path}")" == 400 ]] ||
        fail "snapshot regular mode is not 0400 for ${relative_path}"
      ;;
    *)
      fail "fixture unexpectedly contains mode ${file_mode}"
      ;;
  esac
  if find "${snapshot_path}" -prune -perm -0200 -print | grep -q .; then
    fail "published snapshot file remains owner-writable: ${relative_path}"
  fi
  entry_count=$((entry_count + 1))
done < "${tree_records}"

(( entry_count > 0 )) || fail 'shadow fixture contained no payload files'
[[ -n "${snapshot_root}" && -d "${snapshot_root}" ]] ||
  fail 'could not identify the private snapshot root'
while IFS= read -r snapshot_directory; do
  [[ -O "${snapshot_directory}" ]] ||
    fail "snapshot directory has an unexpected owner: ${snapshot_directory}"
  [[ "$(file_mode "${snapshot_directory}")" == 500 ]] ||
    fail "snapshot directory mode is not 0500: ${snapshot_directory}"
done < <(find "${snapshot_root}" -type d -print)
[[ "$(file_mode "$(dirname "${snapshot_root}")")" == 500 ]] ||
  fail 'published snapshot container mode is not 0500'
if find "${snapshot_root}" -type l -print -quit | grep -q .; then
  fail 'published snapshot contains a symlink'
fi
{
  find "${snapshot_root}/scripts" "${snapshot_root}/files" -type f -print |
    sed "s#^${snapshot_root}/##"
} | LC_ALL=C sort > "${actual_paths}"
LC_ALL=C sort -o "${expected_paths}" "${expected_paths}"
cmp -s "${expected_paths}" "${actual_paths}" ||
  fail 'snapshot path set differs from the complete pinned raw payload'

if guild_source_path 'docs/basics.md' >/dev/null 2>&1; then
  fail 'provider exposed a path outside scripts/ and files/'
fi
if guild_source_path 'scripts/../docs/basics.md' >/dev/null 2>&1; then
  fail 'provider accepted traversal during snapshot lookup'
fi

stable_path="$(guild_source_path scripts/common-helper-scripts/env)"
stable_checksum="$(sha256sum "${stable_path}" | awk '{print $1}')"
printf '\n# advanced after provider preparation\n' >> \
  "${seed_repo}/scripts/common-helper-scripts/env"
"${REAL_GIT}" -C "${seed_repo}" add scripts/common-helper-scripts/env
"${REAL_GIT}" -C "${seed_repo}" \
  -c user.name='Guild source test' \
  -c user.email='guild-source@example.invalid' \
  commit -q -m 'advance mutable channel'
"${REAL_GIT}" -C "${seed_repo}" push -q --force origin shadow

[[ "$(guild_source_revision)" == "${resolved_revision}" ]] ||
  fail 'published revision changed after the remote channel advanced'
[[ "$(sha256sum "${stable_path}" | awk '{print $1}')" == \
   "${stable_checksum}" ]] ||
  fail 'published snapshot content changed after the remote channel advanced'

guild_source_release || fail 'snapshot release failed'
if guild_source_path scripts/common-helper-scripts/env >/dev/null 2>&1; then
  fail 'released provider still returned a snapshot path'
fi
[[ ! -e "${stable_path}" ]] || fail 'release left the private snapshot behind'
guild_source_release || fail 'snapshot release is not idempotent'

printf 'guild source shadow parity tests passed (%d payload files)\n' \
  "${entry_count}"
