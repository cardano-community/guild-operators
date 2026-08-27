#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2030,SC2031,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-deployment.XXXXXX")"
SOURCE_ROOT="${TEST_ROOT}/source"
SOURCE_TREE="${SOURCE_ROOT}/scripts/common-helper-scripts/cntools"
NODE_HOME="${TEST_ROOT}/node"
TARGET_TREE="${NODE_HOME}/scripts/cntools"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_rejected() {
  local context="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "${context} was accepted"
  fi
}

file_mode() {
  local mode=""

  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -f '%Lp' "$1"
  fi
}

restore_file() {
  local saved_file="$1"
  local destination="$2"

  mv -f -- "${saved_file}" "${destination}"
}

for required_command in bash cp find git jq mkfifo mktemp mv stat; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

mkdir -p "${SOURCE_TREE}" "${NODE_HOME}/scripts"
cp -R -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools/." "${SOURCE_TREE}/"
git -C "${SOURCE_ROOT}" init -q
git -C "${SOURCE_ROOT}" config user.name "CNTools deployment test"
git -C "${SOURCE_ROOT}" config user.email "cntools-deployment@example.invalid"
git -C "${SOURCE_ROOT}" config commit.gpgSign false
git -C "${SOURCE_ROOT}" add scripts/common-helper-scripts/cntools
git -C "${SOURCE_ROOT}" commit -qm "Add tracked CNTools fixture"

# shellcheck source=../../scripts/cnode-helper-scripts/guild-deploy.sh
. "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"

GIT_SOURCE_ROOT="${SOURCE_ROOT}"
if (( BASH_VERSINFO[0] > 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  GUILD_DEPLOY_PREFLIGHT_BASH_BIN="bash"
else
  # macOS' Bash 3 can syntax-check the files but cannot execute the Bash 4.4
  # menu validator. Linux CI and deployments exercise the real validator.
  cntools_test_validation_bash() {
    case "${1:-}" in
      -n) command bash "$@" ;;
      -c) return 0 ;;
      *) return 2 ;;
    esac
  }
  GUILD_DEPLOY_PREFLIGHT_BASH_BIN="cntools_test_validation_bash"
fi
export GIT_SOURCE_ROOT GUILD_DEPLOY_PREFLIGHT_BASH_BIN NODE_HOME

dispatcher_preflight_cntools_tree ||
  fail "valid tracked CNTools source tree failed preflight"

mkdir -p "${TARGET_TREE}/obsolete"
printf 'remove me\n' > "${TARGET_TREE}/obsolete/stale.txt"
dispatcher_install_cntools_tree ||
  fail "valid CNTools tree failed installation"

[[ ! -e "${TARGET_TREE}/obsolete/stale.txt" ]] ||
  fail "whole-tree replacement retained a stale installed file"

source_files="$(cd "${SOURCE_TREE}" && find . -type f -print | LC_ALL=C sort)"
target_files="$(cd "${TARGET_TREE}" && find . -type f -print | LC_ALL=C sort)"
[[ "${source_files}" = "${target_files}" ]] ||
  fail "installed CNTools file set does not match the source tree"
while IFS= read -r relative_path; do
  [[ -n "${relative_path}" ]] || continue
  cmp -s "${SOURCE_TREE}/${relative_path#./}" "${TARGET_TREE}/${relative_path#./}" ||
    fail "installed CNTools file differs from source: ${relative_path#./}"
done <<< "${source_files}"

while IFS= read -r -d '' directory; do
  [[ "$(file_mode "${directory}")" = "755" ]] ||
    fail "CNTools directory does not have mode 0755: ${directory#"${TARGET_TREE}"/}"
done < <(find "${TARGET_TREE}" -type d -print0)
while IFS= read -r -d '' installed_file; do
  expected_mode="644"
  [[ "${installed_file}" = "${TARGET_TREE}/cntools.sh" ]] && expected_mode="755"
  [[ "$(file_mode "${installed_file}")" = "${expected_mode}" ]] ||
    fail "unexpected CNTools file mode for ${installed_file#"${TARGET_TREE}"/}"
done < <(find "${TARGET_TREE}" -type f -print0)

assert_rejected \
  "missing CNTools source tree" \
  dispatcher_validate_cntools_tree "${TEST_ROOT}/missing-tree" Y

saved_file="${TEST_ROOT}/VERSION.saved"
cp -- "${SOURCE_TREE}/VERSION" "${saved_file}"
installed_version="$(< "${TARGET_TREE}/VERSION")"
printf 'not-a-version\n' > "${SOURCE_TREE}/VERSION"
assert_rejected "invalid CNTools VERSION" \
  dispatcher_validate_cntools_tree "${SOURCE_TREE}" N
assert_rejected "installation from an invalid CNTools tree" dispatcher_install_cntools_tree
[[ "$(< "${TARGET_TREE}/VERSION")" = "${installed_version}" ]] ||
  fail "source validation failure changed the installed CNTools tree"
if find "${NODE_HOME}/scripts" -mindepth 1 -maxdepth 1 \
  -type d -name '.cntools-install.*' -print -quit | grep -q .; then
  fail "source validation failure left a CNTools staging directory"
fi
restore_file "${saved_file}" "${SOURCE_TREE}/VERSION"

saved_file="${TEST_ROOT}/ui.sh.saved"
cp -- "${SOURCE_TREE}/core/ui.sh" "${saved_file}"
printf 'if\n' > "${SOURCE_TREE}/core/ui.sh"
assert_rejected "invalid CNTools shell file" \
  dispatcher_validate_cntools_tree "${SOURCE_TREE}" N
restore_file "${saved_file}" "${SOURCE_TREE}/core/ui.sh"

saved_file="${TEST_ROOT}/module.json.saved"
cp -- "${SOURCE_TREE}/modules/root/module.json" "${saved_file}"
printf '{invalid json}\n' > "${SOURCE_TREE}/modules/root/module.json"
assert_rejected "invalid CNTools module metadata" \
  dispatcher_validate_cntools_tree "${SOURCE_TREE}" N
restore_file "${saved_file}" "${SOURCE_TREE}/modules/root/module.json"

saved_file="${TEST_ROOT}/action.sh.saved"
mv -- "${SOURCE_TREE}/core/action.sh" "${saved_file}"
assert_rejected "missing required CNTools file" \
  dispatcher_validate_cntools_tree "${SOURCE_TREE}" N
restore_file "${saved_file}" "${SOURCE_TREE}/core/action.sh"

saved_file="${TEST_ROOT}/update.sh.saved"
mv -- "${SOURCE_TREE}/core/update.sh" "${saved_file}"
assert_rejected "missing required CNTools update core" \
  dispatcher_validate_cntools_tree "${SOURCE_TREE}" N
restore_file "${saved_file}" "${SOURCE_TREE}/core/update.sh"

if (( BASH_VERSINFO[0] > 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  saved_file="${TEST_ROOT}/update-library.sh.saved"
  mv -- "${SOURCE_TREE}/lib/update.sh" "${saved_file}"
  assert_rejected "missing declared CNTools update library" \
    dispatcher_validate_cntools_tree "${SOURCE_TREE}" N
  restore_file "${saved_file}" "${SOURCE_TREE}/lib/update.sh"
fi

ln -s -- "${SOURCE_TREE}/VERSION" "${SOURCE_TREE}/modules/root/unsafe-link"
assert_rejected "symbolic link in CNTools source" dispatcher_preflight_cntools_tree
rm -f -- "${SOURCE_TREE}/modules/root/unsafe-link"

printf '#!/usr/bin/env bash\n' > "${SOURCE_TREE}/modules/root/untracked.sh"
assert_rejected "untracked CNTools source file" dispatcher_preflight_cntools_tree
rm -f -- "${SOURCE_TREE}/modules/root/untracked.sh"

mkfifo "${SOURCE_TREE}/modules/root/unsafe.pipe"
assert_rejected "special file in CNTools source" dispatcher_preflight_cntools_tree
rm -f -- "${SOURCE_TREE}/modules/root/unsafe.pipe"

symlink_node="${TEST_ROOT}/symlink-node"
mkdir -p "${symlink_node}/scripts" "${symlink_node}/real-cntools"
printf 'preserve me\n' > "${symlink_node}/real-cntools/marker"
ln -s -- "${symlink_node}/real-cntools" "${symlink_node}/scripts/cntools"
reject_symlink_target() (
  NODE_HOME="${symlink_node}"
  export NODE_HOME
  dispatcher_install_cntools_tree
)
assert_rejected "symbolic-link CNTools target" reject_symlink_target
[[ "$(< "${symlink_node}/real-cntools/marker")" = "preserve me" ]] ||
  fail "symbolic-link target rejection changed its destination"

race_node="${TEST_ROOT}/lock-order-node"
mkdir -p "${race_node}/scripts"
if ! (
  NODE_HOME="${race_node}"
  export NODE_HOME
  deployment_target_lock_acquire() {
    mkdir -p "${NODE_HOME}/scripts/cntools"
    printf 'completed by another installer\n' > \
      "${NODE_HOME}/scripts/cntools/concurrent-marker"
    return 0
  }
  deployment_target_lock_release() {
    return 0
  }
  dispatcher_install_cntools_tree
); then
  fail "CNTools inspected its target before acquiring the transaction lock"
fi
[[ "$(< "${race_node}/scripts/cntools/VERSION")" = "${installed_version}" ]] ||
  fail "lock-order installation did not replace the complete prior tree"
[[ ! -e "${race_node}/scripts/cntools/candidate" ]] ||
  fail "lock-order installation nested the candidate inside the target"

printf 'keep this installation\n' > "${TARGET_TREE}/local-state"
printf '9.9.9\n' > "${TARGET_TREE}/VERSION"
before_entrypoint="$(cksum < "${TARGET_TREE}/cntools.sh")"
if (
  dispatcher_cntools_move_tree() {
    if [[ "$1" = "${TARGET_TREE}" && "$(basename "$2")" = "previous" ]]; then
      command mv -- "$@" || return 1
      return 1
    fi
    command mv -- "$@"
  }
  dispatcher_install_cntools_tree
) >/dev/null 2>&1; then
  fail "CNTools installation ignored a post-rename previous-tree failure"
fi
[[ -f "${TARGET_TREE}/local-state" ]] ||
  fail "post-rename previous-tree failure did not restore the installation"
[[ "$(< "${TARGET_TREE}/VERSION")" = "9.9.9" ]] ||
  fail "post-rename previous-tree failure replaced the installed version"
if find "${NODE_HOME}/scripts" -mindepth 1 -maxdepth 1 \
  -type d -name '.cntools-install.*' -print -quit | grep -q .; then
  fail "post-rename previous-tree rollback left a CNTools staging directory"
fi

if (
  dispatcher_cntools_move_tree() {
    if [[ "$(basename "$1")" = "candidate" &&
          "$2" = "${TARGET_TREE}" ]]; then
      return 1
    fi
    command mv -- "$@"
  }
  dispatcher_install_cntools_tree
) >/dev/null 2>&1; then
  fail "CNTools installation ignored an injected candidate move failure"
fi
[[ -f "${TARGET_TREE}/local-state" ]] ||
  fail "candidate move failure did not restore the previous CNTools tree"
[[ "$(< "${TARGET_TREE}/VERSION")" = "9.9.9" ]] ||
  fail "candidate move failure replaced the previous CNTools version"
[[ "$(cksum < "${TARGET_TREE}/cntools.sh")" = "${before_entrypoint}" ]] ||
  fail "candidate move failure changed the previous CNTools entrypoint"
if find "${NODE_HOME}/scripts" -mindepth 1 -maxdepth 1 \
  -type d -name '.cntools-install.*' -print -quit | grep -q .; then
  fail "candidate move rollback left a CNTools staging directory"
fi

if (
  dispatcher_cntools_move_tree() {
    if [[ "$(basename "$1")" = "candidate" &&
          "$2" = "${TARGET_TREE}" ]]; then
      command mv -- "$@" || return 1
      return 1
    fi
    command mv -- "$@"
  }
  dispatcher_install_cntools_tree
) >/dev/null 2>&1; then
  fail "CNTools installation ignored a post-rename candidate failure"
fi
[[ -f "${TARGET_TREE}/local-state" ]] ||
  fail "post-rename failure did not restore the previous CNTools tree"
[[ "$(< "${TARGET_TREE}/VERSION")" = "9.9.9" ]] ||
  fail "post-rename failure replaced the previous CNTools version"
[[ "$(cksum < "${TARGET_TREE}/cntools.sh")" = "${before_entrypoint}" ]] ||
  fail "post-rename failure changed the previous CNTools entrypoint"
if find "${NODE_HOME}/scripts" -mindepth 1 -maxdepth 1 \
  -type d -name '.cntools-install.*' -print -quit | grep -q .; then
  fail "post-rename rollback left a CNTools staging directory"
fi

printf 'CNTools deployment tests passed\n'
