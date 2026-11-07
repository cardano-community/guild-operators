#!/usr/bin/env bash
# Moving a deployment from the shared ~/.local/bin to its own bin folder: when
# the preflight stops, what it copies, and that it leaves everything else alone.
# shellcheck disable=SC2034  # read by the sourced dispatcher
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-binary-layout.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
ORIGINAL_PATH="${PATH}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../../scripts/cnode-helper-scripts/guild-deploy.sh
. "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh"
set +e
set -uo pipefail

GIT_SOURCE_ROOT="${ROOT_DIR}"
BASE_RELEASE="${ROOT_DIR}/files/node-implementations/cnode/release.json"
MIN_NODE="$(jq -er '.version' "${BASE_RELEASE}")"
MIN_CLI="$(jq -er '.companions["cardano-cli"].version' "${BASE_RELEASE}")"
OLD_NODE="1.0.0"
OLD_CLI="1.0.0.0"

fake_tool() { # $1 = path, $2 = version
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\nprintf "%%s %%s - linux-x86_64\\n" "%s" "%s"\n' \
    "$(basename "$1")" "$2" > "$1"
  chmod 0755 "$1"
}

new_target() { # $1 = case name; a cnode deployment made by the old master flow
  HOME="${TEST_ROOT}/$1/home"
  NODE_PARENT="${TEST_ROOT}/$1/deployments"
  NODE_NAME="node"
  NODE_HOME="${NODE_PARENT}/${NODE_NAME}"
  NODE_SERVICE="${NODE_NAME}"
  NODE_IMPLEMENTATION="cnode"
  NETWORK="preview"
  BRANCH="master"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  LEGACY_CNODE_TARGET="Y"
  S_ARGS=""
  BINARY_LAYOUT_COPIED="N"
  PATH="${ORIGINAL_PATH}"
  unset GUILD_ACTIVE_HOME
  mkdir -p "${HOME}/.local/bin" "${NODE_HOME}/scripts" "${NODE_HOME}/db" "${NODE_HOME}/files"
  : > "${NODE_HOME}/scripts/env"
  : > "${HOME}/.bashrc"
}

shared_binaries() { # $1 = node version, $2 = cli version
  fake_tool "${HOME}/.local/bin/cardano-node" "$1"
  fake_tool "${HOME}/.local/bin/cardano-cli" "$2"
  fake_tool "${HOME}/.local/bin/bech32" "1.1.0"
  fake_tool "${HOME}/.local/bin/cncli" "v6.8.3"
  fake_tool "${HOME}/.local/bin/cardano-db-sync" "13.7.2.1"
  chmod 0555 "${HOME}/.local/bin/cardano-db-sync"
}

tree_hash() {
  (cd "$1" && find . -type f -exec sha256sum {} + | sort | sha256sum)
}

expect_stop() { # $1 = text the instructions must contain
  local before output
  before="$(tree_hash "${TEST_ROOT}")"
  if output="$(dispatcher_binary_layout_preflight 2>&1)"; then
    fail "expected a stop mentioning '$1', got: ${output}"
  fi
  grep -qF -- "$1" <<< "${output}" || fail "stop did not mention '$1': ${output}"
  grep -qF -- "Stopped before changing anything" <<< "${output}" ||
    fail "stop did not say nothing changed: ${output}"
  [[ "$(tree_hash "${TEST_ROOT}")" == "${before}" ]] || fail "a stop changed files: $1"
}

in_copy_list() {
  local tool
  for tool in "${BINARY_LAYOUT_COPY[@]}"; do
    [[ "${tool}" == "$1" ]] && return 0
  done
  return 1
}

# A brand new target has nothing to move.
(
  new_target fresh
  rm -f "${NODE_HOME}/scripts/env"
  LEGACY_CNODE_TARGET="N"
  dispatcher_binary_layout_preflight || fail "a new target stopped"
  [[ "${BINARY_LAYOUT_ACTION}" == New\ deployment* ]] || fail "new target not reported: ${BINARY_LAYOUT_ACTION}"
  [[ ${#BINARY_LAYOUT_COPY[@]} -eq 0 ]] || fail "a new target copied something"
) || exit 1

# Scripts alone would stop the node at its next restart.
(
  new_target below_minimum
  shared_binaries "${OLD_NODE}" "${OLD_CLI}"
  expect_stop "cardano-node ${MIN_NODE}"
  expect_stop "next restart"
  expect_stop "./guild-deploy.sh -s d -n preview -t node -p ${NODE_PARENT}"
  STRICT_LINE='STRICT_VERSION_CHECK="N"'
  printf '%s\n' "${STRICT_LINE}" > "${NODE_HOME}/scripts/env"
  dispatcher_binary_layout_preflight || fail "STRICT_VERSION_CHECK=N did not skip the check"
) || exit 1

# Other flags stay in the command the operator is told to run.
(
  new_target keeps_flags
  shared_binaries "${OLD_NODE}" "${OLD_CLI}"
  S_ARGS="m"
  BRANCH="alpha"
  expect_stop "./guild-deploy.sh -s dm -n preview -t node -p ${NODE_PARENT} -b alpha"
) || exit 1

# At the minimum the current versions are copied and nothing else changes.
(
  new_target at_minimum
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  fake_tool "${HOME}/.local/bin/cardano-hw-cli" "1.0.0"
  printf 'module\n' > "${HOME}/.local/bin/HID.node"
  chmod 0755 "${HOME}/.local/bin/HID.node"
  before="$(tree_hash "${HOME}/.local/bin")"
  dispatcher_binary_layout_preflight || fail "at the minimum it should proceed"
  for tool in cardano-node cardano-cli bech32 cncli cardano-db-sync cardano-hw-cli HID.node; do
    in_copy_list "${tool}" || fail "${tool} was not selected for copying"
  done
  dispatcher_copy_shared_binaries >/dev/null || fail "copy failed"
  [[ -d "${NODE_HOME}/bin" ]] || fail "no bin folder after the copy"
  for tool in cardano-node cardano-cli bech32 cncli cardano-db-sync cardano-hw-cli HID.node; do
    cmp -s "${HOME}/.local/bin/${tool}" "${NODE_HOME}/bin/${tool}" || fail "${tool} copy differs"
  done
  [[ -z "$(find "${NODE_HOME}/bin" -prune ! -perm 0755)" ]] || fail "bin folder has the wrong mode"
  [[ -z "$(find "${NODE_HOME}" -mindepth 1 -maxdepth 1 -name '.bin-*')" ]] || fail "left a stage folder"
  [[ "$(tree_hash "${HOME}/.local/bin")" == "${before}" ]] || fail "the shared folder changed"
  [[ "${BINARY_LAYOUT_COPIED}" == "Y" ]] || fail "copy not recorded"

  # Running again finds nothing left to do.
  BINARY_LAYOUT_COPIED="N"
  dispatcher_binary_layout_preflight || fail "second run stopped"
  [[ ${#BINARY_LAYOUT_COPY[@]} -eq 0 ]] || fail "second run copied again"
  [[ "${BINARY_LAYOUT_ACTION}" == Binaries\ are\ already* ]] || fail "second run: ${BINARY_LAYOUT_ACTION}"
) || exit 1

# -s d installs the pinned set itself, so only the other tools are copied.
(
  new_target with_download
  shared_binaries "${OLD_NODE}" "${OLD_CLI}"
  S_ARGS="d"
  dispatcher_binary_layout_preflight || fail "-s d should proceed below the minimum"
  in_copy_list cncli || fail "cncli was not selected"
  in_copy_list cardano-node && fail "cardano-node should come from the download"
  in_copy_list cardano-db-sync && fail "cardano-db-sync should come from the download"
  [[ "${BINARY_LAYOUT_ACTION}" == *"take effect when the service restarts"* ]] ||
    fail "download action: ${BINARY_LAYOUT_ACTION}"
  exit 0
) || exit 1

# A stage left by a killed run is removed, and a bin folder that already has
# something in it keeps it.
(
  new_target existing_bin
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  mkdir -p "${NODE_HOME}/.bin-migrate.killed" "${NODE_HOME}/bin"
  printf 'partial\n' > "${NODE_HOME}/.bin-migrate.killed/cardano-node"
  printf 'kept\n' > "${NODE_HOME}/bin/gum"
  fake_tool "${HOME}/.local/bin/gum" "0.14"
  dispatcher_binary_layout_preflight || fail "existing bin stopped"
  in_copy_list gum && fail "a tool already in bin was selected"
  dispatcher_copy_shared_binaries >/dev/null || fail "copy into existing bin failed"
  [[ ! -e "${NODE_HOME}/.bin-migrate.killed" ]] || fail "stale stage was not removed"
  grep -qx kept "${NODE_HOME}/bin/gum" || fail "the tool in bin was overwritten"
  [[ -x "${NODE_HOME}/bin/cardano-node" ]] || fail "cardano-node was not added to existing bin"
  [[ -z "$(find "${NODE_HOME}" -mindepth 1 -maxdepth 1 -name '.bin-*')" ]] || fail "left a stage folder"
) || exit 1

# What runs today wins: a binary earlier on PATH is neither copied nor shadowed.
(
  new_target earlier_on_path
  shared_binaries "${OLD_NODE}" "${MIN_CLI}"
  fake_tool "${TEST_ROOT}/earlier_on_path/custom/cardano-node" "${MIN_NODE}"
  PATH="${TEST_ROOT}/earlier_on_path/custom:${PATH}"
  dispatcher_binary_layout_preflight || fail "the custom node meets the minimum"
  in_copy_list cardano-node && fail "the shared cardano-node would shadow the custom one"
  in_copy_list cardano-cli || fail "the shared cardano-cli was not selected"
  exit 0
) || exit 1

# A shell activated for another deployment does not change the answer.
(
  new_target other_active
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  fake_tool "${TEST_ROOT}/other_active/other/bin/cardano-node" "99.0.0"
  GUILD_ACTIVE_HOME="${TEST_ROOT}/other_active/other"
  PATH="${GUILD_ACTIVE_HOME}/bin:${PATH}"
  dispatcher_binary_layout_preflight || fail "activated shell stopped"
  in_copy_list cardano-node || fail "another deployment's activate hid the shared cardano-node"
) || exit 1

# Overrides in env keep winning after a download, so -s d cannot rescue them.
(
  new_target override_old
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  fake_tool "${TEST_ROOT}/override_old/custom/cardano-node" "${OLD_NODE}"
  printf 'CNODEBIN="%s"\n' "${TEST_ROOT}/override_old/custom/cardano-node" > "${NODE_HOME}/scripts/env"
  S_ARGS="d"
  expect_stop "CNODEBIN in ${NODE_HOME}/scripts/env"
) || exit 1
(
  new_target override_cli_old
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  printf 'CCLI="%s"\n' "\${HOME}/.local/old-cli" > "${NODE_HOME}/scripts/env"
  fake_tool "${HOME}/.local/old-cli" "${OLD_CLI}"
  expect_stop "CCLI in ${NODE_HOME}/scripts/env"
) || exit 1
(
  new_target override_fine
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  fake_tool "${TEST_ROOT}/override_fine/custom/cardano-node" "${MIN_NODE}"
  printf 'CNODEBIN="%s"\n' "${TEST_ROOT}/override_fine/custom/cardano-node" > "${NODE_HOME}/scripts/env"
  dispatcher_binary_layout_preflight || fail "a good override stopped"
  [[ "${BINARY_LAYOUT_NOTES[*]}" == *"CNODEBIN in scripts/env is respected"* ]] ||
    fail "good override not reported: ${BINARY_LAYOUT_NOTES[*]}"
) || exit 1

# A database with no binaries usually means the wrong OS user.
(
  new_target wrong_user
  touch "${NODE_HOME}/db/immutable"
  expect_stop "has no cardano-node"
  S_ARGS="d"
  dispatcher_binary_layout_preflight || fail "-s d should install the missing binaries"
) || exit 1
(
  new_target never_installed
  dispatcher_binary_layout_preflight || fail "an empty target with no binaries should proceed"
) || exit 1

# Too little room stops before anything is copied.
(
  new_target no_room
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfake 1000 900 100 90%% /\n'; }
  expect_stop "MB free for binaries"
) || exit 1

# Permission checks mean nothing to root.
if [[ "$(id -u)" -ne 0 ]]; then
  (
    new_target read_only
    shared_binaries "${MIN_NODE}" "${MIN_CLI}"
    chmod 0555 "${NODE_HOME}"
    expect_stop "is not writable by"
    chmod 0755 "${NODE_HOME}"
  ) || exit 1
fi

# Dingo and Amaru are not on master yet: a fresh download replaces the old
# layout and the old suffixed CLI names, and cnode's binaries are left alone.
for implementation in dingo amaru; do
  (
    new_target "old_${implementation}"
    NODE_IMPLEMENTATION="${implementation}"
    LEGACY_CNODE_TARGET="N"
    NETWORK="preprod"
    printf '{}\n' > "${DEPLOYMENT_FILE}"
    shared_binaries "${MIN_NODE}" "${MIN_CLI}"
    fake_tool "${HOME}/.local/bin/${implementation}" "1.0.0"
    fake_tool "${HOME}/.local/bin/cardano-cli-${implementation}" "${MIN_CLI}"
    fake_tool "${HOME}/.local/bin/gum" "0.14"
    expect_stop "./guild-deploy.sh -i ${implementation} -s d -n preprod"
    S_ARGS="d"
    dispatcher_binary_layout_preflight || fail "${implementation} -s d should proceed"
    in_copy_list gum || fail "${implementation} did not get its own gum"
    in_copy_list cardano-node && fail "${implementation} would copy cnode's binaries"
    in_copy_list cncli && fail "${implementation} would copy cnode's cncli"
    in_copy_list cardano-cli && fail "${implementation} would copy cnode's cardano-cli"
    exit 0
  ) || exit 1
done

# Folders the old CNTools left writable by the group are tightened on the old
# layout only, and a stop never reaches them.
(
  new_target private_folders
  mkdir -p "${NODE_HOME}/priv/wallet/w1" "${NODE_HOME}/priv/pool"
  printf 'key\n' > "${NODE_HOME}/priv/wallet/w1/payment.skey"
  chmod 0775 "${NODE_HOME}/priv/wallet" "${NODE_HOME}/priv/wallet/w1" "${NODE_HOME}/priv/pool"
  chmod 0664 "${NODE_HOME}/priv/wallet/w1/payment.skey"
  [[ "$(dispatcher_layout_private_items | wc -l)" -eq 4 ]] || fail "writable private items not found"
  LEGACY_CNODE_TARGET="N"
  [[ -z "$(dispatcher_layout_private_items)" ]] || fail "a current target should be left alone"
  LEGACY_CNODE_TARGET="Y"
  dispatcher_layout_protect_private_folders >/dev/null || fail "could not protect private folders"
  [[ -z "$(dispatcher_layout_private_items)" ]] || fail "writable private items remain"
  [[ "$(stat -c '%a' "${NODE_HOME}/priv/wallet")" == "755" ]] || fail "group read access was changed"
  [[ "$(stat -c '%a' "${NODE_HOME}/priv/wallet/w1/payment.skey")" == "644" ]] || fail "file read access was changed"
) || exit 1

# The closing report says what is safe to remove, and never removes it.
(
  new_target report_alone
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  dispatcher_binary_layout_preflight || fail "report setup"
  dispatcher_copy_shared_binaries >/dev/null || fail "report setup copy"
  fake_tool "${NODE_HOME}/bin/cardano-cli" "99.0.0.0"
  before="$(tree_hash "${HOME}/.local/bin")"
  report="$(dispatcher_binary_layout_report 2>&1)"
  grep -qF "mv ${NODE_HOME}/bin ${NODE_HOME}/bin.disabled" <<< "${report}" || fail "no undo step: ${report}"
  grep -qF "these now differ: cardano-cli" <<< "${report}" || fail "no version warning: ${report}"
  grep -qF "you can remove them" <<< "${report}" || fail "no removal note: ${report}"
  [[ "$(tree_hash "${HOME}/.local/bin")" == "${before}" ]] || fail "the report changed the shared folder"
) || exit 1
(
  new_target report_shared
  shared_binaries "${MIN_NODE}" "${MIN_CLI}"
  mkdir -p "${NODE_PARENT}/other/scripts"
  : > "${NODE_PARENT}/other/scripts/env"
  dispatcher_binary_layout_preflight || fail "report setup"
  dispatcher_copy_shared_binaries >/dev/null || fail "report setup copy"
  report="$(dispatcher_binary_layout_report 2>&1)"
  grep -qF "These deployments still use them" <<< "${report}" || fail "other deployment not named: ${report}"
  grep -qF "${NODE_PARENT}/other" <<< "${report}" || fail "other deployment not listed: ${report}"
  grep -qF "you can remove them" <<< "${report}" && fail "offered to remove files still in use"
  exit 0
) || exit 1

# Units still on the old path are named, with the command for that implementation.
for spec in cnode:mithril-signer.sh\ -d dingo:dingo.sh\ install amaru:amaru.sh\ install; do
  (
    implementation="${spec%%:*}"
    command_text="${spec#*:}"
    new_target "report_units_${implementation}"
    NODE_IMPLEMENTATION="${implementation}"
    mkdir -p "${NODE_HOME}/bin"
    SYSTEMD_UNIT_DIR="${TEST_ROOT}/report_units_${implementation}/units"
    mkdir -p "${SYSTEMD_UNIT_DIR}"
    printf 'ExecStart=%s/.local/bin/tool\n' "${HOME}" > "${SYSTEMD_UNIT_DIR}/${NODE_SERVICE}.service"
    printf 'ExecStart=/opt/other/tool\n' > "${SYSTEMD_UNIT_DIR}/${NODE_SERVICE}-clean.service"
    report="$(dispatcher_binary_layout_report 2>&1)"
    grep -qF "${NODE_SERVICE}.service" <<< "${report}" || fail "unit on the old path not named: ${report}"
    grep -qF "${NODE_SERVICE}-clean.service" <<< "${report}" && fail "named a unit that is not on the old path"
    grep -qF "${NODE_HOME}/scripts/${command_text}" <<< "${report}" ||
      fail "${implementation} was not told '${command_text}': ${report}"
    exit 0
  ) || exit 1
done

# activate switches a shell between deployments.
(
  HOME="${TEST_ROOT}/activate/home"
  mkdir -p "${HOME}"
  PATH="${ORIGINAL_PATH}"
  for name in first second; do
    home="${TEST_ROOT}/activate/${name}"
    mkdir -p "${home}/bin" "${home}/scripts" "${home}/files" "${home}/sockets"
    cp "${ROOT_DIR}/scripts/common-helper-scripts/activate" "${home}/scripts/activate"
    fake_tool "${home}/bin/cardano-cli" "1.${name/first/1}${name/second/2}"
    : > "${home}/scripts/env"
  done
  first="${TEST_ROOT}/activate/first"
  second="${TEST_ROOT}/activate/second"
  printf '{"implementation":"cnode","network":"mainnet"}\n' > "${first}/.deployment.json"
  printf '{"implementation":"dingo","network":"preview"}\n' > "${second}/.deployment.json"
  printf 'SOCKET="${CNODE_HOME}/sockets/custom.socket"\n' > "${first}/scripts/env"

  # shellcheck source=/dev/null
  . "${first}/scripts/activate" >/dev/null || fail "activate failed"
  [[ "$(command -v cardano-cli)" == "${first}/bin/cardano-cli" ]] || fail "first deployment not on PATH"
  [[ "${CARDANO_NODE_SOCKET_PATH}" == "${first}/sockets/custom.socket" ]] ||
    fail "SOCKET from env ignored: ${CARDANO_NODE_SOCKET_PATH}"
  [[ "${CARDANO_NODE_NETWORK_ID}" == "mainnet" ]] || fail "mainnet not set"
  # shellcheck source=/dev/null
  . "${second}/scripts/activate" >/dev/null || fail "switching failed"
  [[ "$(command -v cardano-cli)" == "${second}/bin/cardano-cli" ]] || fail "second deployment not on PATH"
  [[ ":${PATH}:" != *":${first}/bin:"* ]] || fail "first deployment stayed on PATH"
  [[ "${CARDANO_NODE_SOCKET_PATH}" == "${second}/sockets/dingo.socket" ]] ||
    fail "dingo socket: ${CARDANO_NODE_SOCKET_PATH}"
  [[ "${CARDANO_NODE_NETWORK_ID}" == "2" ]] || fail "network magic: ${CARDANO_NODE_NETWORK_ID}"
  if bash "${second}/scripts/activate" >/dev/null 2>&1; then
    fail "running activate instead of sourcing it should fail"
  fi
) || exit 1

printf 'binary-layout-migration: PASS\n'
