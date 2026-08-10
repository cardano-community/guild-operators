#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

# Stage 0C contract tests for the source-snapshot handoff and complete payload
# transaction. The production checkout can contain intentional untracked work,
# while local source mode correctly rejects untracked scripts/files. Therefore
# this test commits the current scripts/files into a disposable repository and
# dirties one tracked, non-executable manifest line before invoking the real
# dispatcher.

find_bash_44() {
  local candidate=""
  local -a candidates=()

  [[ -n "${BASH_UNDER_TEST:-}" ]] && candidates+=("${BASH_UNDER_TEST}")
  candidates+=(
    "${BASH:-}"
    /opt/homebrew/bin/bash
    /usr/local/bin/bash
    /usr/bin/bash
    /bin/bash
    /private/tmp/guild-bash-5.2.37-test/bash-5.2.37/bash
  )
  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" && -x "${candidate}" ]] || continue
    if "${candidate}" -c \
      '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))' \
      >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

BASH_UNDER_TEST="$(find_bash_44)" || {
  printf 'SKIP: GNU Bash 4.4 or newer is required\n' >&2
  exit 77
}
if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  export BASH_UNDER_TEST
  exec "${BASH_UNDER_TEST}" "${BASH_SOURCE[0]}" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DISPATCHER="${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"
CNODE_PROFILE="${REPO_ROOT}/scripts/cnode-helper-scripts/deploy-cnode.sh"
DINGO_PROFILE="${REPO_ROOT}/scripts/dingo-helper-scripts/deploy-dingo.sh"
AMARU_PROFILE="${REPO_ROOT}/scripts/amaru-helper-scripts/deploy-amaru.sh"
REAL_GIT="$(command -v git)"
ENV_BIN="$(command -v env)"
SOURCE_BRANCH="stage0c-fixture"
SOURCE_ACCOUNT="cardano-community"

TEST_TMP_BASE="$(cd -P "${TMPDIR:-/tmp}" && pwd -P)"
TEST_ROOT="$(mktemp -d "${TEST_TMP_BASE}/guild-stage0c-contract.XXXXXX")"
SOURCE_REPO="${TEST_ROOT}/source"
TARGET_PARENT="${TEST_ROOT}/targets"
GIT_WRAPPER="${TEST_ROOT}/git-wrapper"
SOURCE_REVISION=""
SOURCE_TREE_DIGEST=""
RUN_OUTPUT=""
RUN_GIT_LOG=""
RUN_SNAPSHOT_ROOT=""
RUN_HOME=""
RUN_FORBIDDEN_COMMAND_LOG=""
RUN_STATUS=0

cleanup() {
  if [[ "${GUILD_STAGE0C_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'Preserved Stage 0C test root: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  if [[ -n "${TEST_ROOT:-}" &&
        "${TEST_ROOT}" == "${TEST_TMP_BASE}"/guild-stage0c-contract.* &&
        -d "${TEST_ROOT}" && ! -L "${TEST_ROOT}" ]]; then
    # SIGKILL intentionally bypasses source-provider cleanup. Its immutable
    # snapshot is read-only, so restore owner write/search bits before removing
    # the disposable test root.
    chmod -R u+rwX "${TEST_ROOT}" 2>/dev/null || true
    rm -rf -- "${TEST_ROOT}"
  fi
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

sha256_file() {
  local digest=""
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$1")" || return 1
  else
    digest="$(shasum -a 256 "$1")" || return 1
  fi
  printf '%s\n' "${digest%% *}"
}

stat_inode() {
  stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"
}

stat_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1"
}

stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

target_file_state() {
  local target="$1"
  local output="$2"
  local path=""
  local relative_path=""

  : > "${output}"
  while IFS= read -r path; do
    relative_path="${path#"${target}"/}"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${relative_path}" "$(stat_inode "${path}")" \
      "$(stat_mtime "${path}")" "$(stat_mode "${path}")" \
      "$(sha256_file "${path}")" >> "${output}"
  done < <(find "${target}" -type f -print | LC_ALL=C sort)
}

assert_target_unchanged() {
  local target="$1"
  local before="$2"
  local after="$3"
  target_file_state "${target}" "${after}"
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail "target changed despite a rejected deployment: ${target}"
  }
}

target_content_state() {
  local target="$1"
  local output="$2"
  local path=""
  local relative_path=""

  : > "${output}"
  while IFS= read -r path; do
    relative_path="${path#"${target}"/}"
    printf '%s\t%s\t%s\n' "${relative_path}" \
      "$(stat_mode "${path}")" "$(sha256_file "${path}")" >> "${output}"
  done < <(find "${target}" -type f -print | LC_ALL=C sort)
}

assert_no_transaction_artifacts() {
  local target="$1"
  local leaked=""

  leaked="$(find "${target}" \
    \( -name '.guild-deploy-*' -o \
       -name '.guild-source-receipt.commit.*' -o \
       -name '.deployment.commit.*' \) -print -quit 2>/dev/null)"
  [[ -z "${leaked}" ]] ||
    fail "deployment transaction artifact leaked: ${leaked}"
}

assert_receipt_metadata_coherent() {
  local target="$1"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local receipt_hash=""

  [[ -f "${receipt}" && ! -L "${receipt}" &&
     -f "${metadata}" && ! -L "${metadata}" ]] ||
    fail "receipt/metadata pair is missing for ${target}"
  receipt_hash="$(sha256_file "${receipt}")"
  assert_eq "$(jq -r '.payloadReceiptSha256' "${metadata}")" \
    "${receipt_hash}" 'authoritative payload receipt digest'
  assert_eq "$(jq -r '.transactionId' "${metadata}")" \
    "${receipt_hash:0:24}" 'authoritative transaction identifier'
}

atomic_jq_update() {
  local file="$1"
  shift
  local staged="${file}.stage0c.$$"
  jq "$@" "${file}" > "${staged}" || {
    rm -f -- "${staged}"
    return 1
  }
  mv -f -- "${staged}" "${file}"
}

copy_target() {
  local source="$1"
  local destination="$2"
  mkdir -p -- "${destination}"
  cp -R "${source}/." "${destination}/"
}

calculate_checkout_tree_digest() {
  local checkout="$1"
  local revision="$2"
  local records="${TEST_ROOT}/tree.index"
  local digests="${TEST_ROOT}/tree.digests"
  local index_entry=""
  local relative_path=""
  local mode=""
  local file_hash=""

  git -C "${checkout}" ls-files --stage -z -- scripts files > "${records}"
  printf 'revision %s\n' "${revision}" > "${digests}"
  while IFS= read -r -d '' index_entry; do
    relative_path="${index_entry#*$'\t'}"
    if [[ -x "${checkout}/${relative_path}" ]]; then
      mode="100755"
    else
      mode="100644"
    fi
    file_hash="$(sha256_file "${checkout}/${relative_path}")"
    printf '%s %s %s\n' "${mode}" "${file_hash}" \
      "${relative_path}" >> "${digests}"
  done < "${records}"
  sha256_file "${digests}"
}

create_source_fixture() {
  mkdir -p -- "${SOURCE_REPO}" "${TARGET_PARENT}"
  cp -R "${REPO_ROOT}/scripts" "${SOURCE_REPO}/scripts"
  cp -R "${REPO_ROOT}/files" "${SOURCE_REPO}/files"

  "${REAL_GIT}" -C "${SOURCE_REPO}" init -q
  "${REAL_GIT}" -C "${SOURCE_REPO}" config user.name 'Stage 0C Test'
  "${REAL_GIT}" -C "${SOURCE_REPO}" config user.email \
    'stage0c-test@example.invalid'
  "${REAL_GIT}" -C "${SOURCE_REPO}" checkout -q -b "${SOURCE_BRANCH}"
  "${REAL_GIT}" -C "${SOURCE_REPO}" remote add origin \
    "git@github.com:${SOURCE_ACCOUNT}/guild-operators.git"
  "${REAL_GIT}" -C "${SOURCE_REPO}" add -- scripts files
  "${REAL_GIT}" -C "${SOURCE_REPO}" commit -qm 'Stage 0C source fixture'
  SOURCE_REVISION="$("${REAL_GIT}" -C "${SOURCE_REPO}" rev-parse HEAD)"

  # Make local mode observably dirty without changing an executable payload.
  printf '\n# Stage 0C deterministic dirty-tree fixture.\n' >> \
    "${SOURCE_REPO}/files/node-implementations/source-manifest.tsv"
  assert_eq \
    "$("${REAL_GIT}" -C "${SOURCE_REPO}" status --porcelain=v1 --untracked-files=all -- scripts files)" \
    ' M files/node-implementations/source-manifest.tsv' \
    'disposable source dirtiness'
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")"
}

create_git_wrapper() {
  cat > "${GIT_WRAPPER}" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'git'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${GIT_CALL_LOG:?}"
exec "${REAL_GIT:?}" "$@"
WRAPPER
  chmod 0755 "${GIT_WRAPPER}"
}

run_deploy() {
  local case_id="$1"
  local target_name="$2"
  local branch="${3:-${SOURCE_BRANCH}}"
  local account="${4:-${SOURCE_ACCOUNT}}"
  local export_root="${5:-}"
  local expected_revision="${6:-}"
  local launcher="${7:-${DISPATCHER}}"
  local selective_flags="${8:-}"
  local failpoint="${9:-}"
  local failure_action="${10:-return}"
  local test_mode="${11:-stage0c-transaction-failure-injection-v1}"
  local implementation="${12:-cnode}"
  local network="${13:-preview}"
  local fake_linux="${14:-N}"
  local run_root="${TEST_ROOT}/runs/${case_id}"
  local home="${run_root}/home"
  local tmp="${run_root}/tmp"
  local test_bin="${run_root}/test-bin"
  local run_path="${PATH}"
  local failure_context="${run_root}/guild-deploy-failure.context"
  local forbidden_command_log="${run_root}/forbidden-commands.log"
  local real_uname=""
  local command_name=""
  local status=0
  local -a export_args=()
  local -a selective_args=()

  case "${implementation}:${network}" in
    cnode:mainnet|cnode:guild|cnode:preprod|cnode:preview|\
    dingo:preprod|dingo:preview|amaru:preprod|amaru:preview) ;;
    *) fail "invalid Stage 0C deployment case: ${implementation}/${network}" ;;
  esac
  case "${fake_linux}" in Y|N) ;; *) fail "invalid fake-Linux selector" ;; esac
  [[ -z "${export_root}" ]] || export_args=(-E "${export_root}")
  [[ -z "${selective_flags}" ]] || selective_args=(-s "${selective_flags}")

  RUN_OUTPUT="${run_root}/output"
  RUN_GIT_LOG="${run_root}/git.calls"
  RUN_SNAPSHOT_ROOT="${run_root}/snapshots"
  RUN_HOME="${home}"
  RUN_FORBIDDEN_COMMAND_LOG=""
  mkdir -p -- "${home}" "${tmp}" "${RUN_SNAPSHOT_ROOT}"
  chmod 0700 "${run_root}" "${home}" "${tmp}" "${RUN_SNAPSHOT_ROOT}"
  : > "${home}/.bashrc"
  : > "${RUN_GIT_LOG}"
  if [[ "${fake_linux}" == "Y" ]]; then
    real_uname="$(command -v uname)"
    mkdir -p -- "${test_bin}"
    cat > "${test_bin}/uname" <<'FAKE_UNAME'
#!/bin/sh
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) exec "${GUILD_STAGE0C_REAL_UNAME:?}" "$@" ;;
esac
FAKE_UNAME
    cat > "${test_bin}/forbidden-command" <<'FORBIDDEN_COMMAND'
#!/bin/sh
printf '%s\n' "${0##*/}" >> "${GUILD_STAGE0C_FORBIDDEN_COMMAND_LOG:?}"
printf 'Stage 0C alternate transaction invoked forbidden command: %s\n' \
  "${0##*/}" >&2
exit 97
FORBIDDEN_COMMAND
    chmod 0755 "${test_bin}/uname" "${test_bin}/forbidden-command"
    for command_name in curl apt-get dnf yum; do
      ln -s forbidden-command "${test_bin}/${command_name}"
    done
    : > "${forbidden_command_log}"
    RUN_FORBIDDEN_COMMAND_LOG="${forbidden_command_log}"
    run_path="${test_bin}:${PATH}"
  fi
  if [[ -n "${failpoint}" ]]; then
    (umask 077 && {
      printf 'guild-deploy-stage0c-transaction-context-v1\n'
      printf 'target=%s\n' "${TARGET_PARENT}/${target_name}"
      printf 'source=%s\n' "${SOURCE_REPO}"
    } > "${failure_context}")
    chmod 0600 "${failure_context}"
  fi

  "${ENV_BIN}" -i \
    HOME="${home}" \
    PATH="${run_path}" \
    TMPDIR="${tmp}" \
    BASH_ENV=/dev/null \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SUDO=N \
    UPDATE_CHECK=N \
    PACKAGE_MANAGER_OUTPUT=compact \
    S_ARGS= \
    GUILD_SOURCE_HANDOFF_ACTIVE=N \
    GUILD_SOURCE_CHECK_ONLY=N \
    GUILD_SOURCE_EXPECT_REVISION="${expected_revision}" \
    GUILD_SOURCE_GIT_BIN="${GIT_WRAPPER}" \
    GUILD_SOURCE_TMP_ROOT="${RUN_SNAPSHOT_ROOT}" \
    GUILD_SOURCE_CACHE_ROOT="${run_root}/cache" \
    GUILD_SOURCE_LOCK_BACKEND=directory \
    GUILD_SOURCE_LOCK_TIMEOUT=5 \
    GUILD_DEPLOY_TEST_MODE="${test_mode}" \
    GUILD_DEPLOY_TEST_FAILPOINT="${failpoint}" \
    GUILD_DEPLOY_TEST_ACTION="${failure_action}" \
    GUILD_DEPLOY_TEST_CONTEXT="${failure_context}" \
    GIT_CALL_LOG="${RUN_GIT_LOG}" \
    REAL_GIT="${REAL_GIT}" \
    GUILD_STAGE0C_REAL_UNAME="${real_uname}" \
    GUILD_STAGE0C_FORBIDDEN_COMMAND_LOG="${forbidden_command_log}" \
    "${BASH_UNDER_TEST}" "${launcher}" \
      -i "${implementation}" -n "${network}" \
      -p "${TARGET_PARENT}" -t "${target_name}" \
      -b "${branch}" -a "${account}" -S local -L "${SOURCE_REPO}" \
      -D -u "${selective_args[@]}" "${export_args[@]}" \
      > "${RUN_OUTPUT}" 2>&1 || status=$?
  RUN_STATUS="${status}"
  return "${status}"
}

test_custom_launcher_header_and_port() {
  local target="${TARGET_PARENT}/custom_port"
  local launcher="${TEST_ROOT}/custom-guild-deploy.sh"
  local staged="${launcher}.staged"

  awk '
    /^#NODE_PORT=/ {
      print "NODE_PORT=4312                       # Stage 0C custom bootstrap port"
      next
    }
    /^# Do NOT modify/ && !inserted {
      print "STAGE0C_CUSTOM_LAUNCHER=kept"
      inserted = 1
    }
    { print }
  ' "${DISPATCHER}" > "${staged}"
  mv -- "${staged}" "${launcher}"
  chmod 0755 "${launcher}"

  mkdir -p -- "${target}/files"
  expect_deploy_success custom-port-initial custom_port \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${launcher}"
  assert_snapshot_cleanup
  grep -Fqx 'STAGE0C_CUSTOM_LAUNCHER=kept' \
    "${target}/scripts/guild-deploy.sh" ||
    fail 'fresh install did not preserve the bootstrap dispatcher header'
  grep -Eq '^NODE_PORT=4312([[:space:]]|$)' \
    "${target}/scripts/guild-deploy.sh" ||
    fail 'fresh install lost the bootstrap NODE_PORT setting'
  grep -Fqx 'CNODE_PORT=4312' "${target}/scripts/env" ||
    fail 'fresh install did not seed the custom cnode port'
  assert_eq "$(jq -r '.nodePort' "${target}/.deployment.json")" '4312' \
    'durable deployment node port'

  # A helper-triggered refresh starts from the installed launcher rather than
  # the original bootstrap. The recorded/header value must remain authoritative
  # and must not fall back to the implementation default.
  expect_deploy_success custom-port-refresh custom_port \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' \
    "${target}/scripts/guild-deploy.sh"
  assert_snapshot_cleanup
  grep -Fqx 'CNODE_PORT=4312' "${target}/scripts/env" ||
    fail 'installed-dispatcher refresh reset the custom cnode port'
  assert_eq "$(jq -r '.nodePort' "${target}/.deployment.json")" '4312' \
    'refreshed deployment node port'
}

expect_deploy_success() {
  if ! run_deploy "$@"; then
    sed -n '1,240p' "${RUN_OUTPUT}" >&2 || true
    fail "deployment case '$1' failed"
  fi
}

expect_deploy_failure() {
  if run_deploy "$@"; then
    fail "deployment case '$1' unexpectedly succeeded"
  fi
}

assert_snapshot_cleanup() {
  local leftovers=""
  leftovers="$(find "${RUN_SNAPSHOT_ROOT}" -mindepth 1 -print -quit)"
  [[ -z "${leftovers}" ]] ||
    fail "source snapshot was not released: ${leftovers}"
}

test_help_without_git() {
  local no_git_bin="${TEST_ROOT}/no-git-bin"
  local tool=""
  local output="${TEST_ROOT}/help.output"

  mkdir -p -- "${no_git_bin}"
  for tool in dirname basename cat; do
    ln -s "$(command -v "${tool}")" "${no_git_bin}/${tool}"
  done
  if ! PATH="${no_git_bin}" GUILD_SOURCE_GIT_BIN="${TEST_ROOT}/missing-git" \
    "${BASH_UNDER_TEST}" "${DISPATCHER}" -h > "${output}" 2>&1; then
    sed -n '1,120p' "${output}" >&2 || true
    fail 'dispatcher help requires Git'
  fi
  grep -Fq 'Usage:' "${output}" || fail 'dispatcher help omitted usage text'
}

test_no_guild_raw_transport() {
  local findings="${TEST_ROOT}/guild-raw.findings"
  if grep -nE \
    'raw\.githubusercontent\.com|(^|[^A-Za-z0-9_])URL_RAW([^A-Za-z0-9_]|$)' \
    "${DISPATCHER}" "${CNODE_PROFILE}" "${DINGO_PROFILE}" \
    "${AMARU_PROFILE}" > "${findings}"; then
    sed -n '1,120p' "${findings}" >&2
    fail 'dispatcher/profile Guild raw transport returned'
  fi
}

assert_manifest_receipt_coverage() {
  local target="$1"
  local implementation="$2"
  local network="$3"
  local receipt="${target}/.guild-source-receipt.json"
  local assertion_id="${target##*/}"
  local expected="${TEST_ROOT}/${assertion_id}.manifest-records"
  local actual="${TEST_ROOT}/${assertion_id}.receipt-records"

  awk -F '\t' -v implementation="${implementation}" -v network="${network}" '
    ($1 == "common" || $1 == implementation) && $5 != "retire" {
      source_path = $2
      target_path = $3
      gsub(/\{implementation\}/, implementation, source_path)
      gsub(/\{implementation\}/, implementation, target_path)
      gsub(/\{network\}/, network, source_path)
      gsub(/\{network\}/, network, target_path)
      printf "%s\t%s\t%s\n", target_path, source_path, $4
    }
  ' "${SOURCE_REPO}/files/node-implementations/source-manifest.tsv" |
    LC_ALL=C sort > "${expected}"
  jq -r '.files[] | [.path, .source, .mode] | @tsv' "${receipt}" |
    LC_ALL=C sort > "${actual}"
  cmp -s "${expected}" "${actual}" || {
    diff -u "${expected}" "${actual}" >&2 || true
    fail "${implementation} receipt does not exactly cover its expanded source manifest"
  }
}

assert_fresh_payload_consistency() {
  local target="$1"
  local implementation="${2:-cnode}"
  local network="${3:-preview}"
  local expected_port="${4:-6000}"
  local expected_metrics_provider="${5:-prometheus}"
  local expected_n2c="${6:-true}"
  local expected_local_cli="${7:-true}"
  local expected_metrics="${8:-true}"
  local expected_forging="${9:-true}"
  local metadata="${target}/.deployment.json"
  local receipt="${target}/.guild-source-receipt.json"
  local expected_service="${target##*/}"
  local expected_target_version=""
  local rendered_policy="render-${implementation}"
  local target_path=""
  local source_path=""
  local mode=""
  local policy=""
  local source_hash=""
  local installed_hash=""
  local managed=""
  local actual_mode=""
  local count=0

  expected_service="$(printf '%s' "${expected_service}" | tr '[:upper:]' '[:lower:]')"
  expected_target_version="$(jq -er '.version' \
    "${SOURCE_REPO}/files/node-implementations/${implementation}/release.json")"
  [[ -f "${metadata}" && -f "${receipt}" ]] ||
    fail 'fresh deployment omitted metadata or payload receipt'
  jq -e --arg revision "${SOURCE_REVISION}" \
    --arg digest "${SOURCE_TREE_DIGEST}" \
    --arg branch "${SOURCE_BRANCH}" \
    --arg implementation "${implementation}" \
    --arg network "${network}" \
    --arg service "${expected_service}" \
    --arg target_version "${expected_target_version}" \
    --arg metrics_provider "${expected_metrics_provider}" \
    --argjson port "${expected_port}" \
    --argjson n2c "${expected_n2c}" \
    --argjson local_cli "${expected_local_cli}" \
    --argjson metrics "${expected_metrics}" \
    --argjson forging "${expected_forging}" '
      .schemaVersion == 1 and
      .deploymentStatus == "deployed" and
      .implementation == $implementation and
      .network == $network and
      .branch == $branch and
      .repository == "cardano-community/guild-operators" and
      .sourceSchemaVersion == 1 and
      .sourceMode == "local" and
      .sourceRef == ("refs/heads/" + $branch) and
      .sourceRevision == $revision and
      .sourceDirty == true and
      .sourceTreeDigest == $digest and
      .payloadReceipt == ".guild-source-receipt.json" and
      (.payloadReceiptSha256 | test("^[0-9a-f]{64}$")) and
      (.transactionId | test("^[0-9a-f]{24}$")) and
      .serviceName == $service and
      .nodePort == $port and
      .targetNodeVersion == $target_version and
      .metricsProvider == $metrics_provider and
      .capabilities == {
        n2c: $n2c,
        localCli: $local_cli,
        metrics: $metrics,
        forging: $forging
      }
    ' "${metadata}" >/dev/null ||
    fail "fresh ${implementation} metadata source/profile contract failed"

  assert_receipt_metadata_coherent "${target}"
  jq -e --arg revision "${SOURCE_REVISION}" \
    --arg digest "${SOURCE_TREE_DIGEST}" \
    --arg branch "${SOURCE_BRANCH}" \
    --arg implementation "${implementation}" \
    --arg network "${network}" \
    --arg rendered_policy "${rendered_policy}" '
      .schemaVersion == 1 and
      .implementation == $implementation and
      .network == $network and
      .source.repository == "cardano-community/guild-operators" and
      .source.channel == $branch and
      .source.ref == ("refs/heads/" + $branch) and
      .source.revision == $revision and
      .source.mode == "local" and
      .source.dirty == true and
      .source.treeDigest == $digest and
      (.files | type == "array" and length > 0) and
      (.files | length) == (.files | map(.path) | unique | length) and
      all(.files[];
        if (.policy == $rendered_policy or
            .policy == "operator-preserved") then
          .managed == false
        else
          .managed == true
        end)
    ' "${receipt}" >/dev/null ||
    fail "fresh ${implementation} payload receipt contract failed"

  assert_manifest_receipt_coverage "${target}" "${implementation}" "${network}"

  while IFS=$'\t' read -r target_path source_path mode policy source_hash installed_hash managed; do
    count=$((count + 1))
    [[ -f "${target}/${target_path}" && ! -L "${target}/${target_path}" ]] ||
      fail "receipt target is missing or unsafe: ${target_path}"
    assert_eq "$(sha256_file "${target}/${target_path}")" \
      "${installed_hash}" "installed hash for ${target_path}"
    assert_eq "$(sha256_file "${SOURCE_REPO}/${source_path}")" \
      "${source_hash}" "source hash for ${target_path}"
    actual_mode="$(stat_mode "${target}/${target_path}")"
    assert_eq "${actual_mode#0}" "${mode#0}" "installed mode for ${target_path}"
    if [[ "${policy}" == "${rendered_policy}" ||
          "${policy}" == "operator-preserved" ]]; then
      [[ "${managed}" == "false" ]] ||
        fail "fresh operator-owned config remained managed: ${target_path}"
    else
      [[ "${managed}" == "true" ]] ||
        fail "fresh managed payload was misclassified: ${target_path}"
    fi
    if [[ "${policy}" == "exact" ]]; then
      assert_eq "${installed_hash}" "${source_hash}" \
        "exact payload bytes for ${target_path}"
    fi
  done < <(jq -r '.files[] | [
      .path, .source, .mode, .policy, .sourceSha256,
      .installedSha256, (.managed | tostring)
    ] | @tsv' "${receipt}")
  (( count > 0 )) || fail 'fresh payload receipt was empty'
  assert_no_transaction_artifacts "${target}"
}

test_fresh_deployment_and_handoff() {
  local target="${TARGET_PARENT}/fresh"
  local snapshot_ready_count=""
  local status_count=""
  local staged_index_count=""
  local untracked_count=""

  # An empty files skeleton suppresses unrelated package installation while
  # remaining a fresh, recognizable deployment target.
  mkdir -p -- "${target}/files"
  expect_deploy_success fresh-initial fresh
  assert_snapshot_cleanup
  assert_fresh_payload_consistency "${target}"
  assert_eq "$(stat_mode "${target}/priv")" '750' \
    'fresh cnode private-directory mode'

  snapshot_ready_count="$(grep -c 'Guild source snapshot ready' "${RUN_OUTPUT}")"
  assert_eq "${snapshot_ready_count}" '1' 'source snapshot handoff count'
  status_count="$(grep -c ' <status>' "${RUN_GIT_LOG}")"
  staged_index_count="$(grep -c ' <ls-files> <--stage>' "${RUN_GIT_LOG}")"
  untracked_count="$(grep -c ' <ls-files> <--others>' "${RUN_GIT_LOG}")"
  assert_eq "${status_count}" '2' 'dirty checkout stability probes'
  assert_eq "${staged_index_count}" '2' 'single snapshot index probes'
  assert_eq "${untracked_count}" '1' 'single snapshot untracked probe'
}

test_fresh_alternate_dispatcher_transaction() {
  local implementation="$1"
  local network="$2"
  local expected_port="$3"
  local expected_metrics_provider="$4"
  local expected_n2c="$5"
  local expected_local_cli="$6"
  local expected_metrics="$7"
  local expected_forging="$8"
  local case_id="fresh-${implementation}"
  local target_name="fresh_${implementation}"
  local target="${TARGET_PARENT}/${target_name}"
  local snapshot_ready_count=""
  local forbidden_output_pattern=""
  local -a expected_binaries=()
  local -a rendered_files=("${target}/scripts/${implementation}.env")
  local -a cross_profile_paths=(
    "${target}/scripts/cnode.sh"
    "${target}/files/cnode-release.json"
  )
  local binary_path=""
  local cross_profile_path=""

  # The profile subprocess sees Linux only for its explicit platform gate.
  # curl and all supported package managers are command guards: their use
  # records an error and fails the deployment, proving this scripts-only run
  # neither installs dependencies nor resolves/downloads node binaries.
  mkdir -p -- "${target}/files"
  expect_deploy_success "${case_id}" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' '' \
    return stage0c-transaction-failure-injection-v1 \
    "${implementation}" "${network}" Y
  assert_snapshot_cleanup
  assert_fresh_payload_consistency \
    "${target}" "${implementation}" "${network}" "${expected_port}" \
    "${expected_metrics_provider}" "${expected_n2c}" \
    "${expected_local_cli}" "${expected_metrics}" "${expected_forging}"

  snapshot_ready_count="$(grep -c 'Guild source snapshot ready' "${RUN_OUTPUT}")"
  assert_eq "${snapshot_ready_count}" '1' \
    "${implementation} source snapshot handoff count"
  [[ -n "${RUN_FORBIDDEN_COMMAND_LOG}" &&
     ! -s "${RUN_FORBIDDEN_COMMAND_LOG}" ]] || {
    [[ ! -s "${RUN_FORBIDDEN_COMMAND_LOG:-/dev/null}" ]] ||
      sed -n '1,40p' "${RUN_FORBIDDEN_COMMAND_LOG}" >&2
    fail "${implementation} invoked a network or package-manager command"
  }

  case "${implementation}" in
    dingo)
      expected_binaries=(
        "${RUN_HOME}/.local/bin/dingo"
        "${RUN_HOME}/.local/bin/cardano-cli-dingo"
      )
      rendered_files+=("${target}/files/dingo.yaml")
      cross_profile_paths+=(
        "${target}/scripts/amaru.sh"
        "${target}/scripts/amaru.env"
        "${target}/files/amaru-release.json"
        "${target}/files/otelcol.yaml"
      )
      [[ -x "${target}/scripts/dingo.sh" &&
         -x "${target}/scripts/gLiveView.sh" &&
         -x "${target}/scripts/cntools.sh" &&
         -f "${target}/scripts/cntools.library" &&
         -f "${target}/scripts/dingo.env" &&
         -f "${target}/files/dingo.yaml" &&
         -f "${target}/files/dingo-release.json" ]] ||
        fail 'fresh Dingo transaction omitted an implementation payload'
      grep -Fqx "GUILD_NODE_HOME=\"${target}\"" \
        "${target}/scripts/dingo.env" ||
        fail 'fresh Dingo environment has the wrong node home'
      grep -Fqx 'CARDANO_NETWORK="preview"' \
        "${target}/scripts/dingo.env" ||
        fail 'fresh Dingo environment has the wrong network'
      grep -Fqx 'relayPort: 3001' "${target}/files/dingo.yaml" ||
        fail 'fresh Dingo configuration has the wrong port'
      assert_eq "$(stat_mode "${target}/priv")" '700' \
        'fresh Dingo private-directory mode'
      grep -Fq 'Dingo binary is not installed; re-run with -s d.' \
        "${RUN_OUTPUT}" || fail 'fresh Dingo run omitted its binary warning'
      grep -Fq 'Dingo cardano-cli companion is not installed; re-run with -s d.' \
        "${RUN_OUTPUT}" || fail 'fresh Dingo run omitted its CLI warning'
      forbidden_output_pattern='Installing Dingo runtime prerequisites|Resolving newest published Dingo release|Downloading Dingo |Downloading cardano-cli for Dingo|Installed verified Dingo'
      ;;
    amaru)
      expected_binaries=(
        "${RUN_HOME}/.local/bin/amaru"
        "${RUN_HOME}/.local/bin/otelcol-contrib"
      )
      cross_profile_paths+=(
        "${target}/scripts/dingo.sh"
        "${target}/scripts/dingo.env"
        "${target}/scripts/cntools.sh"
        "${target}/scripts/cntools.library"
        "${target}/files/dingo.yaml"
        "${target}/files/dingo-release.json"
      )
      [[ -x "${target}/scripts/amaru.sh" &&
         -x "${target}/scripts/gLiveView.sh" &&
         -f "${target}/scripts/amaru.env" &&
         -f "${target}/files/otelcol.yaml" &&
         -f "${target}/files/amaru-release.json" ]] ||
        fail 'fresh Amaru transaction omitted an implementation payload'
      grep -Fqx "GUILD_NODE_HOME=\"${target}\"" \
        "${target}/scripts/amaru.env" ||
        fail 'fresh Amaru environment has the wrong node home'
      grep -Fqx 'AMARU_NETWORK="preprod"' \
        "${target}/scripts/amaru.env" ||
        fail 'fresh Amaru environment has the wrong network'
      grep -Fqx 'AMARU_LISTEN_ADDRESS="0.0.0.0:3000"' \
        "${target}/scripts/amaru.env" ||
        fail 'fresh Amaru environment has the wrong port'
      [[ ! -e "${target}/chain" && ! -e "${target}/ledger" ]] ||
        fail 'fresh Amaru transaction pre-created bootstrap state'
      grep -Fq 'Amaru binary is not installed; re-run with -s d.' \
        "${RUN_OUTPUT}" || fail 'fresh Amaru run omitted its binary warning'
      grep -Fq 'OpenTelemetry Collector is not installed; re-run with -s d' \
        "${RUN_OUTPUT}" || fail 'fresh Amaru run omitted its collector warning'
      forbidden_output_pattern='Installing Amaru runtime prerequisites|Resolving newest published Amaru release|Downloading Amaru |Downloading pinned OpenTelemetry Collector|Installed verified Amaru|Installed verified OpenTelemetry Collector'
      ;;
  esac

  if grep -Eq "${forbidden_output_pattern}" "${RUN_OUTPUT}"; then
    fail "${implementation} performed a dependency or binary-install step"
  fi
  if grep -Eq '@(NODE_HOME|NODE_SERVICE|BINARY_PATH|NODE_PORT)@' \
    "${rendered_files[@]}"; then
    fail "${implementation} transaction left an unrendered profile token"
  fi
  for binary_path in "${expected_binaries[@]}"; do
    [[ ! -e "${binary_path}" ]] ||
      fail "${implementation} unexpectedly installed ${binary_path}"
  done
  for cross_profile_path in "${cross_profile_paths[@]}"; do
    [[ ! -e "${cross_profile_path}" ]] ||
      fail "${implementation} installed cross-profile path ${cross_profile_path}"
  done
}

test_fresh_alternate_dispatcher_transactions() {
  test_fresh_alternate_dispatcher_transaction \
    dingo preview 3001 prometheus true true true true
  test_fresh_alternate_dispatcher_transaction \
    amaru preprod 3000 otel false false true false
}

test_preserved_inputs() {
  local target="${TARGET_PARENT}/preserved"
  local custom_config='{"operatorSetting":"preserve-me"}'
  local installed_env="${target}/scripts/env"
  local staged_env="${TEST_ROOT}/preserved.env"
  local source_runtime="${TEST_ROOT}/source.env.runtime"
  local installed_runtime="${TEST_ROOT}/installed.env.runtime"
  local receipt="${target}/.guild-source-receipt.json"

  mkdir -p -- "${target}/files" "${target}/scripts"
  printf '%s\n' "${custom_config}" > "${target}/files/config.json"
  chmod 0600 "${target}/files/config.json"
  awk '
    /^# Do NOT modify/ && !inserted {
      print "STAGE0C_CUSTOM_HEADER=kept"
      inserted = 1
    }
    { print }
  ' "${SOURCE_REPO}/scripts/common-helper-scripts/env" > "${staged_env}"
  mv -- "${staged_env}" "${installed_env}"
  chmod 0644 "${installed_env}"

  expect_deploy_success preserved-inputs preserved
  assert_snapshot_cleanup
  assert_eq "$(jq -cS . "${target}/files/config.json")" \
    "$(printf '%s\n' "${custom_config}" | jq -cS .)" \
    'operator configuration preservation'
  assert_eq "$(stat_mode "${target}/files/config.json")" '600' \
    'operator configuration mode preservation'
  grep -Fqx 'STAGE0C_CUSTOM_HEADER=kept' "${installed_env}" ||
    fail 'custom env header was not preserved'
  awk 'seen { print } /^# Do NOT modify/ { seen = 1; print }' \
    "${SOURCE_REPO}/scripts/common-helper-scripts/env" > "${source_runtime}"
  awk 'seen { print } /^# Do NOT modify/ { seen = 1; print }' \
    "${installed_env}" > "${installed_runtime}"
  cmp -s "${source_runtime}" "${installed_runtime}" ||
    fail 'preserved env header did not receive the current runtime body'

  jq -e --arg hash "$(sha256_file "${target}/files/config.json")" '
      any(.files[];
        .path == "files/config.json" and
        .policy == "operator-preserved" and
        .mode == "0600" and
        .managed == false and
        .installedSha256 == $hash and
        .sourceSha256 != .installedSha256) and
      any(.files[];
        .path == "scripts/env" and
        .policy == "merge-header" and
        .managed == true)
    ' "${receipt}" >/dev/null ||
    fail 'receipt did not distinguish preserved config from managed env merge'
}

test_config_evolution_and_forced_archive() {
  local target="${TARGET_PARENT}/config_evolution"
  local metadata="${target}/.deployment.json"
  local config="${target}/files/config.json"
  local archive_dir="${target}/scripts/archive"
  local custom_hash=""
  local archive=""
  local archive_count_before=""
  local archive_count_after=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${metadata}" --arg service config_evolution \
    '.serviceName = $service'
  printf '{"operator":"must-survive-template-change"}\n' > "${config}"
  chmod 0600 "${config}"
  custom_hash="$(sha256_file "${config}")"
  archive_count_before="$(find "${archive_dir}" -type f | wc -l | tr -d ' ')"

  # Change the upstream template without changing the Git commit. Dirty local
  # mode snapshots and records this exact tree, making the no-force behavior
  # observable while retaining a deterministic source identity.
  printf '\n' >> "${SOURCE_REPO}/files/configs/cnode/preview/config.json"
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")"
  expect_deploy_success config-no-force config_evolution
  assert_eq "$(sha256_file "${config}")" "${custom_hash}" \
    'no-force config bytes'
  assert_eq "$(stat_mode "${config}")" '600' 'no-force config mode'
  archive_count_after="$(find "${archive_dir}" -type f | wc -l | tr -d ' ')"
  assert_eq "${archive_count_after}" "${archive_count_before}" \
    'no-force config archive count'

  expect_deploy_success config-force config_evolution \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" f
  [[ "$(sha256_file "${config}")" != "${custom_hash}" ]] ||
    fail 'forced configuration refresh did not replace operator bytes'
  assert_eq "$(stat_mode "${config}")" '644' 'forced config mode'
  archive="$(find "${archive_dir}" -type f \
    -name 'files_config.json_bkp*' -print -quit)"
  [[ -n "${archive}" ]] || fail 'forced configuration refresh omitted archive'
  assert_eq "$(sha256_file "${archive}")" "${custom_hash}" \
    'forced configuration archive bytes'
  assert_eq "$(stat_mode "${archive}")" '600' \
    'forced configuration archive mode'
  jq -e '.files[] | select(.path == "files/config.json") |
      .policy == "render-cnode" and .managed == false and .mode == "0644"' \
    "${target}/.guild-source-receipt.json" >/dev/null ||
    fail 'forced configuration receipt ownership is incorrect'

  archive_count_before="$(find "${archive_dir}" -type f | wc -l | tr -d ' ')"
  expect_deploy_success config-force-identical config_evolution \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" f
  archive_count_after="$(find "${archive_dir}" -type f | wc -l | tr -d ' ')"
  assert_eq "${archive_count_after}" "${archive_count_before}" \
    'identical forced config archive count'
}

test_forced_script_archive() {
  local target="${TARGET_PARENT}/script_evolution"
  local metadata="${target}/.deployment.json"
  local script="${target}/scripts/cnode.sh"
  local source_script="${SOURCE_REPO}/scripts/cnode-helper-scripts/cnode.sh"
  local archive_dir="${target}/scripts/archive"
  local old_hash=""
  local archive=""
  local archive_count_before=""
  local archive_count_after=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${metadata}" --arg service script_evolution \
    '.serviceName = $service'
  old_hash="$(sha256_file "${script}")"
  printf '\n# Stage 0C forced script archive fixture.\n' >> "${source_script}"
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")"

  expect_deploy_success script-force script_evolution \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" s
  [[ "$(sha256_file "${script}")" != "${old_hash}" ]] ||
    fail 'forced script refresh did not install changed runtime'
  archive="$(find "${archive_dir}" -type f \
    -name 'scripts_cnode.sh_bkp*' -print -quit)"
  [[ -n "${archive}" ]] || fail 'forced script refresh omitted archive'
  assert_eq "$(sha256_file "${archive}")" "${old_hash}" \
    'forced script archive bytes'

  archive_count_before="$(find "${archive_dir}" -type f | wc -l | tr -d ' ')"
  expect_deploy_success script-force-identical script_evolution \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" s
  archive_count_after="$(find "${archive_dir}" -type f | wc -l | tr -d ' ')"
  assert_eq "${archive_count_after}" "${archive_count_before}" \
    'identical forced script archive count'
}

test_obsolete_path_hash_guard() {
  local target="${TARGET_PARENT}/obsolete_guard"
  local metadata="${target}/.deployment.json"
  local receipt="${target}/.guild-source-receipt.json"
  local unchanged="${target}/scripts/obsolete-unchanged.sh"
  local customized="${target}/scripts/obsolete-customized.sh"
  local unchanged_hash="" customized_recorded_hash=""
  local source_hash="" receipt_hash="" customized_live_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${metadata}" --arg service obsolete_guard \
    '.serviceName = $service'
  printf '#!/usr/bin/env bash\n# unchanged obsolete payload\n' > "${unchanged}"
  printf '#!/usr/bin/env bash\n# original obsolete payload\n' > "${customized}"
  chmod 0755 "${unchanged}" "${customized}"
  unchanged_hash="$(sha256_file "${unchanged}")"
  customized_recorded_hash="$(sha256_file "${customized}")"
  source_hash="$(sha256_file \
    "${SOURCE_REPO}/scripts/cnode-helper-scripts/cnode.sh")"
  atomic_jq_update "${receipt}" \
    --arg unchanged_hash "${unchanged_hash}" \
    --arg customized_hash "${customized_recorded_hash}" \
    --arg source_hash "${source_hash}" '
      .files += [
        {
          "path":"scripts/obsolete-unchanged.sh",
          "source":"scripts/cnode-helper-scripts/cnode.sh",
          "mode":"0755",
          "policy":"merge-header",
          "sourceSha256":$source_hash,
          "installedSha256":$unchanged_hash,
          "managed":true
        },
        {
          "path":"scripts/obsolete-customized.sh",
          "source":"scripts/cnode-helper-scripts/cnode.sh",
          "mode":"0755",
          "policy":"merge-header",
          "sourceSha256":$source_hash,
          "installedSha256":$customized_hash,
          "managed":true
        }
      ]'
  receipt_hash="$(sha256_file "${receipt}")"
  atomic_jq_update "${metadata}" --arg hash "${receipt_hash}" \
    '.payloadReceiptSha256 = $hash'

  printf '# operator customization\n' >> "${customized}"
  customized_live_hash="$(sha256_file "${customized}")"
  expect_deploy_success obsolete-hash-guard obsolete_guard
  [[ ! -e "${unchanged}" && ! -L "${unchanged}" ]] ||
    fail 'unchanged obsolete managed path was not removed'
  [[ -f "${customized}" && ! -L "${customized}" ]] ||
    fail 'customized obsolete path was removed'
  assert_eq "$(sha256_file "${customized}")" "${customized_live_hash}" \
    'customized obsolete path bytes'
  grep -Fq 'Preserving customized obsolete Guild payload path' "${RUN_OUTPUT}" ||
    fail 'customized obsolete path preservation was not reported'
  jq -e 'all(.files[];
      .path != "scripts/obsolete-unchanged.sh" and
      .path != "scripts/obsolete-customized.sh")' "${receipt}" >/dev/null ||
    fail 'obsolete paths remained in the new payload receipt'
}

test_identical_refresh() {
  local target="${TARGET_PARENT}/fresh"
  local before="${TEST_ROOT}/fresh.before"
  local after="${TEST_ROOT}/fresh.after"

  target_file_state "${target}" "${before}"
  sleep 1
  expect_deploy_success fresh-identical fresh
  assert_snapshot_cleanup
  target_file_state "${target}" "${after}"
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'identical refresh changed target inode, mtime, mode, or content'
  }
}

test_docker_supplement_export() {
  local target="${TARGET_PARENT}/docker_export"
  local export_root="${TEST_ROOT}/docker-export"
  local receipt="${export_root}/docker-source-receipt.json"
  local host_receipt="${target}/.guild-source-receipt.json"
  local exported_path="" final_path="" mode="" source_path=""
  local source_hash="" exported_hash="" count=0

  mkdir -p -- "${target}/files"
  expect_deploy_success docker-export docker_export "${SOURCE_BRANCH}" \
    "${SOURCE_ACCOUNT}" "${export_root}" "${SOURCE_REVISION}"
  assert_snapshot_cleanup
  [[ -f "${receipt}" && ! -L "${receipt}" ]] ||
    fail 'Docker supplement receipt is missing or unsafe'
  (
    cd "${export_root}"
    sha256sum -c docker-source-receipt.sha256 >/dev/null
  ) || fail 'Docker supplement receipt sidecar failed validation'
  jq -e --arg revision "${SOURCE_REVISION}" \
    --arg host_hash "$(sha256_file "${host_receipt}")" '
      .schemaVersion == 1 and
      .implementation == "cnode" and
      .network == "preview" and
      .source.revision == $revision and
      .hostPayloadReceiptSha256 == $host_hash and
      (.files | length == 32) and
      (.files | length) == (.files | map(.path) | unique | length)
    ' "${receipt}" >/dev/null || fail 'Docker supplement receipt contract failed'
  jq -e '
    all(.files[];
      .path != "scripts/healthcheck.sh" and
      (.path | startswith("files/docker-cache/") | not))
  ' "${host_receipt}" >/dev/null ||
    fail 'host payload receipt incorrectly owns Docker supplement files'
  while IFS=$'\t' read -r source_path final_path mode source_hash exported_hash; do
    count=$((count + 1))
    exported_path="${export_root}/rootfs${final_path}"
    [[ -f "${exported_path}" && ! -L "${exported_path}" ]] ||
      fail "Docker supplement file is missing or unsafe: ${final_path}"
    assert_eq "$(sha256_file "${SOURCE_REPO}/${source_path}")" \
      "${source_hash}" "Docker source hash for ${final_path}"
    assert_eq "$(sha256_file "${exported_path}")" \
      "${exported_hash}" "Docker export hash for ${final_path}"
    assert_eq "${source_hash}" "${exported_hash}" \
      "Docker exact bytes for ${final_path}"
    assert_eq "$(stat_mode "${exported_path}")" "${mode#0}" \
      "Docker export mode for ${final_path}"
  done < <(jq -r '.files[] | [
      .source, .path, .mode, .sourceSha256, .exportedSha256
    ] | @tsv' "${receipt}")
  assert_eq "${count}" '32' 'Docker supplement file count'

  target_file_state "${target}" "${TEST_ROOT}/docker-export.before"
  expect_deploy_failure docker-pin-mismatch docker_export "${SOURCE_BRANCH}" \
    "${SOURCE_ACCOUNT}" "" '0000000000000000000000000000000000000000'
  grep -Fq 'does not match required revision' "${RUN_OUTPUT}" ||
    fail 'Docker expected-revision mismatch was not explicit'
  assert_target_unchanged "${target}" "${TEST_ROOT}/docker-export.before" \
    "${TEST_ROOT}/docker-export.after"
}

test_malformed_metadata_no_mutation() {
  local target="${TARGET_PARENT}/malformed"
  local before="${TEST_ROOT}/malformed.before"
  local after="${TEST_ROOT}/malformed.after"

  mkdir -p -- "${target}/files"
  printf 'sentinel\n' > "${target}/files/sentinel"
  printf '{ malformed metadata\n' > "${target}/.deployment.json"
  target_file_state "${target}" "${before}"
  expect_deploy_failure malformed-metadata malformed
  grep -Fq 'Deployment metadata is malformed' "${RUN_OUTPUT}" ||
    fail 'malformed metadata rejection was not explicit'
  assert_target_unchanged "${target}" "${before}" "${after}"
}

test_unsafe_receipt_no_mutation() {
  local target="${TARGET_PARENT}/unsafe_receipt"
  local metadata="${target}/.deployment.json"
  local receipt="${target}/.guild-source-receipt.json"
  local before="${TEST_ROOT}/unsafe-receipt.before"
  local after="${TEST_ROOT}/unsafe-receipt.after"
  local receipt_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${metadata}" --arg service unsafe_receipt \
    '.serviceName = $service'
  atomic_jq_update "${receipt}" '
    .files += [{
      "path":"../outside-target",
      "source":"scripts/invalid",
      "mode":"0644",
      "policy":"exact",
      "sourceSha256":"0000000000000000000000000000000000000000000000000000000000000000",
      "installedSha256":"0000000000000000000000000000000000000000000000000000000000000000",
      "managed":true
    }]'
  receipt_hash="$(sha256_file "${receipt}")"
  atomic_jq_update "${metadata}" --arg hash "${receipt_hash}" \
    '.payloadReceiptSha256 = $hash'
  target_file_state "${target}" "${before}"

  expect_deploy_failure unsafe-prior-receipt unsafe_receipt
  grep -Eq 'payload failed|staged|receipt|activation' "${RUN_OUTPUT}" ||
    fail 'unsafe prior receipt rejection was not explicit'
  assert_target_unchanged "${target}" "${before}" "${after}"
}

test_legacy_metadata_migration() {
  local target="${TARGET_PARENT}/legacy"
  local metadata="${target}/.deployment.json"
  local receipt="${target}/.guild-source-receipt.json"
  local retired_orchestrator="${target}/scripts/deploy-as-systemd.sh"
  local legacy_branch="${target}/scripts/.env_branch"
  local archived_orchestrator=""
  local archived_branch=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  rm -f -- "${receipt}"
  atomic_jq_update "${metadata}" --arg service legacy '
    .serviceName = $service |
    del(
      .sourceSchemaVersion,
      .sourceMode,
      .sourceRef,
      .sourceRevision,
      .sourceDirty,
      .sourceTreeDigest,
      .payloadReceipt,
      .payloadReceiptSha256,
      .transactionId
    )'
  printf '#!/usr/bin/env bash\n# legacy orchestrator\n' > "${retired_orchestrator}"
  printf '%s\n' "${SOURCE_BRANCH}" > "${legacy_branch}"
  chmod 0755 "${retired_orchestrator}"
  chmod 0644 "${legacy_branch}"

  expect_deploy_success legacy-migration legacy
  assert_snapshot_cleanup
  jq -e --arg revision "${SOURCE_REVISION}" \
    --arg digest "${SOURCE_TREE_DIGEST}" '
      .schemaVersion == 1 and
      .deploymentStatus == "deployed" and
      .sourceSchemaVersion == 1 and
      .sourceMode == "local" and
      .sourceRevision == $revision and
      .sourceDirty == true and
      .sourceTreeDigest == $digest and
      .payloadReceipt == ".guild-source-receipt.json"
    ' "${metadata}" >/dev/null || fail 'legacy metadata was not migrated'
  [[ -s "${receipt}" ]] || fail 'legacy migration omitted payload receipt'
  assert_eq "$(sha256_file "${receipt}")" \
    "$(jq -r '.payloadReceiptSha256' "${metadata}")" \
    'migrated receipt digest'
  [[ ! -e "${retired_orchestrator}" && ! -L "${retired_orchestrator}" &&
     ! -e "${legacy_branch}" && ! -L "${legacy_branch}" ]] ||
    fail 'legacy sidecars remained active after migration'
  archived_orchestrator="$(find "${target}/scripts/archive" -type f \
    -name 'deploy-as-systemd.sh_deprecated_*' -print -quit)"
  archived_branch="$(find "${target}/scripts/archive" -type f \
    -name '.env_branch_migrated_*' -print -quit)"
  [[ -n "${archived_orchestrator}" && -n "${archived_branch}" ]] ||
    fail 'legacy sidecars were not archived by the payload transaction'
  grep -Fqx '# legacy orchestrator' "${archived_orchestrator}" ||
    fail 'archived legacy orchestrator content changed'
  grep -Fqx "${SOURCE_BRANCH}" "${archived_branch}" ||
    fail 'archived legacy branch content changed'
  jq -e 'all(.files[];
      .path != "scripts/deploy-as-systemd.sh" and
      .path != "scripts/.env_branch" and
      (.path | startswith("scripts/archive/") | not))' \
    "${receipt}" >/dev/null ||
    fail 'retired legacy sidecars became managed receipt payloads'
}

test_incomplete_journal_recovery() {
  local target="${TARGET_PARENT}/recovery"
  local metadata="${target}/.deployment.json"
  local transaction="${target}/.guild-deploy-transaction"
  local protected="${target}/scripts/cnode.sh"
  local expected_hash=""
  local protected_mode=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${metadata}" --arg service recovery \
    '.serviceName = $service'
  expected_hash="$(sha256_file "${protected}")"
  protected_mode="$(stat_mode "${protected}")"
  mkdir -m 0700 -- "${transaction}"
  cp -p -- "${protected}" "${transaction}/backup.1"
  printf 'scripts/cnode.sh\tY\t%s\tbackup.1\n' "${protected_mode}" > \
    "${transaction}/baseline.tsv"
  : > "${transaction}/activation.tsv"
  printf 'schemaVersion=1\ntransactionId=fixture\nstate=activated\n' > \
    "${transaction}/journal"
  chmod 0600 "${transaction}/baseline.tsv" \
    "${transaction}/activation.tsv" "${transaction}/journal"
  printf 'interrupted payload\n' > "${protected}"

  expect_deploy_success interrupted-recovery recovery
  assert_snapshot_cleanup
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail 'incomplete transaction recovery was not reported'
  assert_eq "$(sha256_file "${protected}")" "${expected_hash}" \
    'interrupted payload rollback'
  [[ ! -e "${transaction}" ]] ||
    fail 'recovered transaction journal was not removed'
}

prepare_failure_injection_target() {
  local target_name="$1"
  local target="${TARGET_PARENT}/${target_name}"
  local metadata="${target}/.deployment.json"
  local receipt="${target}/.guild-source-receipt.json"
  local obsolete="${target}/scripts/stage0c-obsolete.sh"
  local obsolete_hash=""
  local source_hash=""
  local receipt_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  printf '%s\n' "${SOURCE_BRANCH}" > "${target}/scripts/.env_branch"
  printf '#!/usr/bin/env bash\n# Stage 0C obsolete failure fixture.\n' > \
    "${obsolete}"
  chmod 0644 "${target}/scripts/.env_branch"
  chmod 0755 "${obsolete}"
  obsolete_hash="$(sha256_file "${obsolete}")"
  source_hash="$(sha256_file \
    "${SOURCE_REPO}/scripts/cnode-helper-scripts/cnode.sh")"
  atomic_jq_update "${receipt}" \
    --arg obsolete_hash "${obsolete_hash}" \
    --arg source_hash "${source_hash}" '
      .files += [{
        "path":"scripts/stage0c-obsolete.sh",
        "source":"scripts/cnode-helper-scripts/cnode.sh",
        "mode":"0755",
        "policy":"merge-header",
        "sourceSha256":$source_hash,
        "installedSha256":$obsolete_hash,
        "managed":true
      }]'
  receipt_hash="$(sha256_file "${receipt}")"
  atomic_jq_update "${metadata}" --arg service "${target_name}" \
    --arg receipt_hash "${receipt_hash}" '
      .serviceName = $service |
      .payloadReceiptSha256 = $receipt_hash |
      .transactionId = ($receipt_hash[0:24])'
}

assert_failpoint_rollback() {
  local case_id="$1"
  local target_name="$2"
  local failpoint="$3"
  local action="$4"
  local expected_status="$5"
  local selective_flags="${6:-}"
  local target="${TARGET_PARENT}/${target_name}"
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"
  local old_receipt="${TEST_ROOT}/${case_id}.receipt"
  local old_metadata="${TEST_ROOT}/${case_id}.metadata"

  target_content_state "${target}" "${before}"
  cp -- "${target}/.guild-source-receipt.json" "${old_receipt}"
  cp -- "${target}/.deployment.json" "${old_metadata}"
  if run_deploy "${case_id}" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" \
    "${selective_flags}" "${failpoint}" "${action}"; then
    fail "failpoint '${failpoint}' unexpectedly completed deployment"
  fi
  assert_eq "${RUN_STATUS}" "${expected_status}" \
    "${failpoint} injected exit status"
  grep -Fq "transaction failpoint '${failpoint}'" "${RUN_OUTPUT}" ||
    fail "failpoint '${failpoint}' was not observably reached"
  [[ "${action}" != "enospc" ]] ||
    grep -Fq 'No space left on device (ENOSPC)' "${RUN_OUTPUT}" ||
    fail 'deterministic ENOSPC failure was not reported'
  assert_snapshot_cleanup
  target_content_state "${target}" "${after}"
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail "canonical target changed after failpoint '${failpoint}'"
  }
  cmp -s "${old_receipt}" "${target}/.guild-source-receipt.json" ||
    fail "old receipt lost authority after failpoint '${failpoint}'"
  cmp -s "${old_metadata}" "${target}/.deployment.json" ||
    fail "old metadata lost authority after failpoint '${failpoint}'"
  assert_receipt_metadata_coherent "${target}"
  assert_no_transaction_artifacts "${target}"
}

test_failure_injection_rollback_boundaries() {
  local target_name="failure_boundaries"
  local target="${TARGET_PARENT}/${target_name}"
  local receipt="${target}/.guild-source-receipt.json"
  local payload_count=0
  local payload_middle=0
  local payload_last=0

  prepare_failure_injection_target "${target_name}"

  # Change the first installed payload while retaining a valid dispatcher.
  # Every injected run now has real canonical work to roll back, even when the
  # selected boundary itself precedes that first replacement.
  printf '\n# Stage 0C failure-injection payload revision.\n' >> \
    "${SOURCE_REPO}/scripts/cnode-helper-scripts/guild-deploy.sh"
  "${BASH_UNDER_TEST}" -n \
    "${SOURCE_REPO}/scripts/cnode-helper-scripts/guild-deploy.sh" ||
    fail 'failure-injection source dispatcher became invalid'
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")"

  payload_count="$(jq '[.files[] |
    select(.path != "scripts/stage0c-obsolete.sh")] | length' "${receipt}")"
  (( payload_count >= 3 )) || fail 'payload is too small for positional failures'
  payload_middle=$(((payload_count + 1) / 2))
  payload_last="${payload_count}"

  assert_failpoint_rollback fail-before-journal "${target_name}" \
    before-durable-journal enospc 1
  assert_failpoint_rollback fail-after-journal-hup "${target_name}" \
    after-durable-journal HUP 129
  assert_failpoint_rollback fail-payload-first "${target_name}" \
    after-payload:1 return 1
  assert_failpoint_rollback fail-payload-last-int "${target_name}" \
    "after-payload:${payload_last}" INT 130
  assert_failpoint_rollback fail-retire-archive "${target_name}" \
    after-retire-archive return 1
  assert_failpoint_rollback fail-history-archive "${target_name}" \
    after-history-archive return 1 s
  assert_failpoint_rollback fail-obsolete-remove "${target_name}" \
    after-obsolete-remove return 1
  assert_failpoint_rollback fail-before-receipt "${target_name}" \
    before-receipt-publish return 1
  assert_failpoint_rollback fail-after-receipt-term "${target_name}" \
    after-receipt-publish TERM 143
  assert_failpoint_rollback fail-before-metadata "${target_name}" \
    before-metadata-publish return 1
  assert_failpoint_rollback fail-after-metadata "${target_name}" \
    after-metadata-publish return 1

  # A failpoint value without the exact test mode must be inert. Use the crash
  # action here so accidental activation would be unmistakable.
  expect_deploy_success failpoint-gate-inert "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal crash disabled
  ! grep -Fq 'TEST ONLY: injecting' "${RUN_OUTPUT}" ||
    fail 'failpoint activated without the exact Stage 0C test mode'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_receipt_metadata_coherent "${target}"
  [[ ! -e "${target}/scripts/.env_branch" &&
     ! -e "${target}/scripts/stage0c-obsolete.sh" ]] ||
    fail 'successful retry did not complete retire/obsolete activation'

  # Preserve the positional midpoint for the hard-crash recovery test.
  printf '%s\n' "${payload_middle}" > "${TEST_ROOT}/payload-middle"
}

test_failure_injection_crash_recovery() {
  local target_name="failure_crash"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local payload_middle=""
  local old_receipt="${TEST_ROOT}/crash.receipt"
  local old_metadata="${TEST_ROOT}/crash.metadata"

  prepare_failure_injection_target "${target_name}"
  payload_middle="$(sed -n '1p' "${TEST_ROOT}/payload-middle")"
  [[ "${payload_middle}" =~ ^[1-9][0-9]*$ ]] ||
    fail 'payload midpoint was not recorded'
  cp -- "${target}/.guild-source-receipt.json" "${old_receipt}"
  cp -- "${target}/.deployment.json" "${old_metadata}"

  if run_deploy fail-payload-crash "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    "after-payload:${payload_middle}" crash; then
    fail 'hard-crash failpoint unexpectedly completed deployment'
  fi
  assert_eq "${RUN_STATUS}" '137' 'hard-crash injected exit status'
  grep -Fq "transaction failpoint 'after-payload:${payload_middle}'" \
    "${RUN_OUTPUT}" || fail 'hard-crash payload failpoint was not reached'
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${transaction}/journal" ]] ||
    fail 'hard crash did not retain a recoverable durable journal'
  cmp -s "${old_receipt}" "${target}/.guild-source-receipt.json" ||
    fail 'hard crash published a partial receipt'
  cmp -s "${old_metadata}" "${target}/.deployment.json" ||
    fail 'hard crash published partial metadata'
  assert_receipt_metadata_coherent "${target}"

  expect_deploy_success fail-payload-crash-recovery "${target_name}"
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail 'next run did not report hard-crash transaction recovery'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_receipt_metadata_coherent "${target}"
  [[ ! -e "${target}/scripts/.env_branch" &&
     ! -e "${target}/scripts/stage0c-obsolete.sh" ]] ||
    fail 'post-crash retry left retired or obsolete canonical payloads'
}

test_identity_mismatch_rejection() {
  local target="${TARGET_PARENT}/fresh"
  local before="${TEST_ROOT}/identity.before"
  local after="${TEST_ROOT}/identity.after"

  target_file_state "${target}" "${before}"
  expect_deploy_failure branch-mismatch fresh stage0c-other "${SOURCE_ACCOUNT}"
  grep -Fq "Could not prepare exact Guild source" "${RUN_OUTPUT}" ||
    fail 'branch/checkout mismatch rejection was not explicit'
  assert_target_unchanged "${target}" "${before}" "${after}"

  expect_deploy_failure repository-mismatch fresh "${SOURCE_BRANCH}" other-fork
  grep -Fq "belongs to 'cardano-community/guild-operators'" "${RUN_OUTPUT}" ||
    fail 'repository mismatch rejection was not explicit'
  assert_target_unchanged "${target}" "${before}" "${after}"
}

for required in git jq awk sed grep find sort cmp diff stat cp mv chmod sha256sum; do
  require_command "${required}"
done
[[ -s "${DISPATCHER}" ]] || fail "dispatcher is missing: ${DISPATCHER}"

test_help_without_git
test_no_guild_raw_transport
create_source_fixture
create_git_wrapper
test_fresh_deployment_and_handoff
test_fresh_alternate_dispatcher_transactions
test_custom_launcher_header_and_port
test_docker_supplement_export
test_preserved_inputs
test_malformed_metadata_no_mutation
test_legacy_metadata_migration
test_incomplete_journal_recovery
test_identity_mismatch_rejection
test_unsafe_receipt_no_mutation
test_identical_refresh
test_failure_injection_rollback_boundaries
test_failure_injection_crash_recovery
test_obsolete_path_hash_guard
test_forced_script_archive
test_config_evolution_and_forced_archive

# Failure injection covers preparation before the durable journal, active
# journal rollback, first/middle/last payload positions, retire and history
# archives, hash-guarded obsolete removal, both sides of receipt/metadata
# publication, HUP/INT/TERM cleanup, simulated ENOSPC, and SIGKILL recovery on
# the immediately following run. The failpoint gate is also proven inert when
# its exact Stage 0C test mode is absent.
printf 'guild deploy Stage 0C transaction tests passed\n'
