#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

# Stage 2 contract tests for the source-snapshot handoff and complete payload
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
RUN_IMPORTED_GENERATION_VALIDATOR_SENTINEL=""
RUN_RESTORE_MKTEMP_SYMLINK=""
RUN_RESTORE_MKTEMP_EXTERNAL=""
RUN_HANDOFF_MUTATION_MODE=""
RUN_HANDOFF_MUTATION_TARGET=""
RUN_HANDOFF_MUTATION_RECEIPT=""
RUN_HANDOFF_MUTATION_METADATA=""
RUN_HANDOFF_MUTATION_TRANSACTION_ID=""

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

wait_for_test_path() {
  local path="$1"
  local process_id="${2:-}"
  local attempt=0

  for ((attempt = 0; attempt < 600; attempt++)); do
    [[ -e "${path}" || -L "${path}" ]] && return 0
    if [[ -n "${process_id}" ]] && ! kill -0 "${process_id}" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

process_is_same_or_descendant() {
  local process_id="$1" ancestor_id="$2" parent_id="" attempt=0

  [[ "${process_id}" =~ ^[0-9]+$ && "${ancestor_id}" =~ ^[0-9]+$ ]] ||
    return 1
  while ((attempt < 32)) && [[ "${process_id}" != 0 && "${process_id}" != 1 ]]; do
    [[ "${process_id}" == "${ancestor_id}" ]] && return 0
    parent_id="$(ps -o ppid= -p "${process_id}" 2>/dev/null)" || return 1
    parent_id="${parent_id//[[:space:]]/}"
    [[ "${parent_id}" =~ ^[0-9]+$ ]] || return 1
    process_id="${parent_id}"
    attempt=$((attempt + 1))
  done
  return 1
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

# Record the complete namespace, including directory and symbolic-link state.
# File-only snapshots miss the immutable generation roots and activation
# pointers that Stage 1 deliberately keeps outside the ordinary receipt.
target_tree_state() {
  local target="$1"
  local output="$2"
  local include_identity="${3:-N}"
  local path=""
  local relative_path=""
  local kind=""
  local content=""
  local identity=""

  : > "${output}"
  while IFS= read -r path; do
    relative_path="${path#"${target}"/}"
    content=""
    identity=""
    if [[ -L "${path}" ]]; then
      kind="link"
      content="$(readlink "${path}")"
    elif [[ -d "${path}" ]]; then
      kind="dir"
    elif [[ -f "${path}" ]]; then
      kind="file"
      content="$(sha256_file "${path}")"
    else
      kind="other"
    fi
    if [[ "${include_identity}" == "Y" ]]; then
      identity="$(stat_inode "${path}")	$(stat_mtime "${path}")	"
    fi
    printf '%s\t%s\t%b%s\t%s\n' "${relative_path}" "${kind}" \
      "${identity}" "$(stat_mode "${path}")" "${content}" >> "${output}"
  done < <(find "${target}" -mindepth 1 -print | LC_ALL=C sort)
}

target_refresh_identity_state() {
  local target="$1"
  local output="$2"
  local root="${target}/scripts/.cntools"
  local path="" relative_path="" pointer=""

  target_file_state "${target}" "${output}"
  if [[ -d "${root}/generations" && ! -L "${root}/generations" ]]; then
    while IFS= read -r path; do
      relative_path="${path#"${target}"/}"
      printf '%s\t%s\t%s\t%s\t-\n' "${relative_path}" \
        "$(stat_inode "${path}")" "$(stat_mtime "${path}")" \
        "$(stat_mode "${path}")" >> "${output}"
    done < <(find "${root}/generations" -mindepth 1 -type d -print |
      LC_ALL=C sort)
  fi
  for pointer in active previous; do
    path="${root}/${pointer}"
    [[ -L "${path}" ]] || continue
    relative_path="${path#"${target}"/}"
    printf '%s\t%s\t%s\t%s\t%s\n' "${relative_path}" \
      "$(stat_inode "${path}")" "$(stat_mtime "${path}")" \
      "$(stat_mode "${path}")" "$(readlink "${path}")" >> "${output}"
  done
  LC_ALL=C sort -o "${output}" "${output}"
}

generation_identity_state() {
  local generation="$1"
  local output="$2"
  local descendants="${output}.descendants"

  [[ -d "${generation}" && ! -L "${generation}" ]] || return 1
  printf '.\tdir\t%s\t%s\t%s\t\n' \
    "$(stat_inode "${generation}")" "$(stat_mtime "${generation}")" \
    "$(stat_mode "${generation}")" > "${output}"
  target_tree_state "${generation}" "${descendants}" Y
  cat "${descendants}" >> "${output}"
  rm -f -- "${descendants}"
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

rewrite_receipt_legacy_inventory_order() {
  local receipt="$1"
  local implementation="$2"
  local anchor="" expected_count=""

  case "${implementation}" in
    cnode)
      anchor=scripts/cntools.sh
      expected_count=38
      ;;
    dingo)
      anchor=scripts/gLiveView.sh
      expected_count=15
      ;;
    amaru)
      expected_count=12
      ;;
    *) return 1 ;;
  esac
  atomic_jq_update "${receipt}" --arg implementation "${implementation}" \
    --arg anchor "${anchor}" '
      .files = (
        .files | map(select(.policy != "cntools-legacy-bundle")) as $ordinary |
        if $implementation == "cnode" or $implementation == "dingo" then
          ($ordinary |
            map(select(.path == "scripts/cntools.library"))) as $facades |
          ($ordinary |
            map(select(.path != "scripts/cntools.library"))) as $without |
          if ($facades | length) != 1 or
             ([$without[] | select(.path == $anchor)] | length) != 1
          then error("legacy receipt anchor/facade mismatch")
          else
            reduce $without[] as $record
              ([]; . + [$record] +
                (if $record.path == $anchor then [$facades[0]] else [] end))
          end
        else $ordinary end
      )
    ' || return 1
  jq -e --arg implementation "${implementation}" --arg anchor "${anchor}" \
    --argjson count "${expected_count}" '
      (.files | length) == $count and
      .files[0].path == "scripts/guild-deploy.sh" and
      (if $implementation == "cnode" or $implementation == "dingo" then
         ((.files | map(.path) | index("scripts/cntools.library")) ==
          ((.files | map(.path) | index($anchor)) + 1))
       else
         ([.files[] | select(.path == "scripts/cntools.library")] |
          length) == 0
       end)
    ' "${receipt}" >/dev/null
}

reconstruct_source_legacy_monolith() {
  local output="$1"
  local expected_sha="${2-92e800f58948a570da401bef431d6e2449f25b337138f242ab3eeb48b0cf162b}"
  local bundle_override="${3:-}"
  local facade="${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library"
  local manifest="${SOURCE_REPO}/scripts/common-helper-scripts/cntools/manifest.json"
  local bundle_relative="" bundle="" member=""

  bundle_relative="$(jq -er '.legacyBundle.path' "${manifest}")" || return 1
  bundle="${bundle_override:-${SOURCE_REPO}/scripts/common-helper-scripts/${bundle_relative}}"
  {
    sed -n '1,5p' "${facade}"
    awk '
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_BEGIN__" {
        print previous; inside=1; next
      }
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_PREFIX_END__" { inside=0; next }
      inside { print }
      { previous=$0 }
    ' "${facade}"
    awk '
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_BEGIN__" {
        inside=1; next
      }
      $0 == "# __CNTOOLS_LEGACY_LOGICAL_INITIALIZATION_END__" {
        inside=0; next
      }
      inside { print }
    ' "${facade}"
    while IFS= read -r member; do
      command cat "${bundle}/${member}" || return 1
      if [[ "${member}" == "010-common-dialog.sh" ]]; then
        awk '
          $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_BEGIN__" {
            inside=1; next
          }
          $0 == "# __CNTOOLS_LEGACY_LOGICAL_INTERSTITIAL_END__" {
            inside=0; next
          }
          inside { print }
        ' "${facade}"
      fi
    done < <(jq -er '.legacyBundle.members[].path' "${manifest}")
  } > "${output}" || return 1
  [[ -z "${expected_sha}" || "$(sha256_file "${output}")" == "${expected_sha}" ]]
}

assert_legacy_monolith_loads() {
  local facade="$1" label="$2"
  local probe_root="${TEST_ROOT}/${label}.legacy-probe"

  mkdir -p -- "${probe_root}/home" "${probe_root}/logs"
  env -i PATH="${PATH}" HOME="${probe_root}/home" \
    "${BASH_UNDER_TEST}" --noprofile --norc -c '
      set +u
      TMP_DIR="$1/tmp"
      WALLET_FOLDER="$1/wallet"
      POOL_FOLDER="$1/pool"
      ASSET_FOLDER="$1/asset"
      LOG_DIR="$1/logs"
      CNTOOLS_MODE=offline NETWORK_NAME=Preview
      ADVANCED_MODE=false ENABLE_ADVANCED=false ENABLE_CHATTR=false
      FG_BLUE=blue FG_GREEN=green FG_GRAY=gray FG_RED=red NC=none
      builtin source "$2"
      test "${CNTOOLS_VERSION:-}" = 13.5.7
    ' stage2-monolith-probe "${probe_root}" "${facade}" \
    > "${probe_root}/stdout" 2> "${probe_root}/stderr" ||
    fail "${label} legacy monolith did not load during the paused migration"
  [[ ! -s "${probe_root}/stdout" && ! -s "${probe_root}/stderr" ]] ||
    fail "${label} legacy monolith load produced output"
}

assert_facade_refuses_transaction() {
  local target="$1" label="$2"
  local output="${TEST_ROOT}/${label}.facade-refusal"
  local status=0 stderr=""

  set +e
  env -i PATH="${PATH}" HOME="${TEST_ROOT}" NODE_HOME="${target}" \
    "${BASH_UNDER_TEST}" --noprofile --norc -c \
      'builtin source "$NODE_HOME/scripts/cntools.library"' \
      > "${output}.stdout" 2> "${output}.stderr"
  status=$?
  set -e
  (( status != 0 )) ||
    fail "${label} facade loaded while the outer transaction existed"
  [[ ! -s "${output}.stdout" ]] ||
    fail "${label} facade transaction refusal produced stdout"
  stderr="$(< "${output}.stderr")"
  assert_eq "${stderr}" \
    "CNTools refuses to start with a deployment journal: ${target}/.guild-deploy-transaction" \
    "${label} facade transaction refusal diagnostic"
}

assert_facade_loads() {
  local target="$1" label="$2"
  local probe_root="${TEST_ROOT}/${label}.facade-load"

  mkdir -p -- "${probe_root}/home" "${probe_root}/logs"
  env -i PATH="${PATH}" HOME="${probe_root}/home" NODE_HOME="${target}" \
    "${BASH_UNDER_TEST}" --noprofile --norc -c '
      set +u
      TMP_DIR="$1/tmp"
      WALLET_FOLDER="$1/wallet"
      POOL_FOLDER="$1/pool"
      ASSET_FOLDER="$1/asset"
      LOG_DIR="$1/logs"
      CNTOOLS_MODE=offline NETWORK_NAME=Preview
      ADVANCED_MODE=false ENABLE_ADVANCED=false ENABLE_CHATTR=false
      FG_BLUE=blue FG_GREEN=green FG_GRAY=gray FG_RED=red NC=none
      builtin source "$NODE_HOME/scripts/cntools.library"
      test "${CNTOOLS_VERSION:-}" = 13.5.7
    ' stage2-facade-load "${probe_root}" \
    > "${probe_root}/stdout" 2> "${probe_root}/stderr" ||
    fail "${label} split facade did not load after transaction cleanup"
  [[ ! -s "${probe_root}/stdout" && ! -s "${probe_root}/stderr" ]] ||
    fail "${label} split facade load produced output"
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
if [[ -n "${GUILD_STAGE2_HANDOFF_MUTATION_MODE:-}" ]] &&
   mkdir "${GUILD_STAGE2_HANDOFF_MUTATION_MARKER:?}" 2>/dev/null; then
  target="${GUILD_STAGE2_HANDOFF_MUTATION_TARGET:?}"
  transaction="${target}/.guild-deploy-transaction"
  case "${GUILD_STAGE2_HANDOFF_MUTATION_MODE}" in
    no-journal)
      mkdir -m 0700 -- "${transaction}"
      ;;
    replace-journal)
      [[ -d "${transaction}" && ! -L "${transaction}" ]]
      ;;
    *) exit 92 ;;
  esac
  cp -- "${GUILD_STAGE2_HANDOFF_MUTATION_RECEIPT:?}" \
    "${target}/.guild-source-receipt.json"
  cp -- "${GUILD_STAGE2_HANDOFF_MUTATION_METADATA:?}" \
    "${target}/.deployment.json"
  cp -- "${GUILD_STAGE2_HANDOFF_MUTATION_RECEIPT}" \
    "${transaction}/receipt.candidate.json"
  cp -- "${GUILD_STAGE2_HANDOFF_MUTATION_METADATA}" \
    "${transaction}/deployment.candidate.json"
  chmod 0644 "${target}/.guild-source-receipt.json" \
    "${target}/.deployment.json" \
    "${transaction}/receipt.candidate.json" \
    "${transaction}/deployment.candidate.json"
  printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
    "${GUILD_STAGE2_HANDOFF_MUTATION_TRANSACTION_ID:?}" > \
    "${transaction}/journal.stage2"
  chmod 0600 "${transaction}/journal.stage2"
  mv -f -- "${transaction}/journal.stage2" "${transaction}/journal"
fi
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
  local handoff_mutation_marker="${run_root}/handoff-mutation.once"
  local real_uname=""
  local real_mktemp=""
  local command_name=""
  local status=0
  local -a export_args=()
  local -a selective_args=()
  local -a adversarial_env=()

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
  if [[ -n "${RUN_IMPORTED_GENERATION_VALIDATOR_SENTINEL}" ]]; then
    [[ "${RUN_IMPORTED_GENERATION_VALIDATOR_SENTINEL}" == "${TEST_ROOT}"/* ]] ||
      fail 'imported-validator sentinel escaped the test root'
    adversarial_env+=(
      "GUILD_STAGE2_IMPORTED_SENTINEL=${RUN_IMPORTED_GENERATION_VALIDATOR_SENTINEL}"
      'BASH_FUNC_cntools_generation_validate%%=() { printf imported-validator > "${GUILD_STAGE2_IMPORTED_SENTINEL:?}"; return 0; }'
    )
  fi
  if [[ -n "${RUN_HANDOFF_MUTATION_MODE}" ]]; then
    [[ "${RUN_HANDOFF_MUTATION_MODE}" == 'no-journal' ||
       "${RUN_HANDOFF_MUTATION_MODE}" == 'replace-journal' ]] ||
      fail 'invalid source-handoff mutation mode'
    [[ "${RUN_HANDOFF_MUTATION_TARGET}" == "${TARGET_PARENT}"/* &&
       "${RUN_HANDOFF_MUTATION_RECEIPT}" == "${TEST_ROOT}"/* &&
       "${RUN_HANDOFF_MUTATION_METADATA}" == "${TEST_ROOT}"/* &&
       -f "${RUN_HANDOFF_MUTATION_RECEIPT}" &&
       -f "${RUN_HANDOFF_MUTATION_METADATA}" &&
       "${RUN_HANDOFF_MUTATION_TRANSACTION_ID}" =~ ^[0-9a-f]{24}$ ]] ||
      fail 'source-handoff mutation fixture escaped the test root'
    adversarial_env+=(
      "GUILD_STAGE2_HANDOFF_MUTATION_MODE=${RUN_HANDOFF_MUTATION_MODE}"
      "GUILD_STAGE2_HANDOFF_MUTATION_MARKER=${handoff_mutation_marker}"
      "GUILD_STAGE2_HANDOFF_MUTATION_TARGET=${RUN_HANDOFF_MUTATION_TARGET}"
      "GUILD_STAGE2_HANDOFF_MUTATION_RECEIPT=${RUN_HANDOFF_MUTATION_RECEIPT}"
      "GUILD_STAGE2_HANDOFF_MUTATION_METADATA=${RUN_HANDOFF_MUTATION_METADATA}"
      "GUILD_STAGE2_HANDOFF_MUTATION_TRANSACTION_ID=${RUN_HANDOFF_MUTATION_TRANSACTION_ID}"
    )
  fi
  if [[ -n "${RUN_RESTORE_MKTEMP_SYMLINK}" ]]; then
    [[ "${RUN_RESTORE_MKTEMP_SYMLINK}" == "${TARGET_PARENT}"/* &&
       -n "${RUN_RESTORE_MKTEMP_EXTERNAL}" ]] ||
      fail 'restore-mktemp adversary escaped the transaction fixture'
    real_mktemp="$(command -v mktemp)"
    mkdir -p -- "${test_bin}"
    cat > "${test_bin}/mktemp" <<'RESTORE_MKTEMP'
#!/bin/sh
case "${1:-}" in
  *'/.guild-deploy-restore.XXXXXX')
    printf '%s\n' "${GUILD_STAGE2_RESTORE_MKTEMP_SYMLINK:?}"
    ;;
  *) exec "${GUILD_STAGE2_REAL_MKTEMP:?}" "$@" ;;
esac
RESTORE_MKTEMP
    chmod 0755 "${test_bin}/mktemp"
    run_path="${test_bin}:${run_path}"
    adversarial_env+=(
      "GUILD_STAGE2_RESTORE_MKTEMP_SYMLINK=${RUN_RESTORE_MKTEMP_SYMLINK}"
      "GUILD_STAGE2_REAL_MKTEMP=${real_mktemp}"
    )
  fi
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
    run_path="${test_bin}:${run_path}"
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
    "${adversarial_env[@]}" \
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

assert_recovery_rejection_reached() {
  local context="$1"

  ! grep -Fq 'Refusing to deploy into non-empty unrecognized target' \
    "${RUN_OUTPUT}" ||
    fail "${context} was rejected by target recognition before recovery"
  grep -Eq \
    'failed recovery preflight|failed authentication|Automatic rollback of .* failed|Unsafe interrupted deployment (transaction|journal)' \
    "${RUN_OUTPUT}" || {
      sed -n '1,120p' "${RUN_OUTPUT}" >&2 || true
      fail "${context} did not reach authenticated transaction recovery"
    }
}

assert_snapshot_cleanup() {
  local snapshot_root="${1:-${RUN_SNAPSHOT_ROOT}}"
  local leftovers=""
  leftovers="$(find "${snapshot_root}" -mindepth 1 -print -quit)"
  [[ -z "${leftovers}" ]] ||
    fail "source snapshot was not released: ${leftovers}"
}

assert_stage3_generation_record() {
  local record="$1"
  local context="$2"
  local line="" tabs="" id="" relative="" root_existed=""
  local generations_existed="" target_existed="" lifecycle_hash=""
  local manifest_schema="" manifest_count="" receipt_schema=""
  local receipt_count="" extra=""

  [[ -f "${record}" && ! -L "${record}" ]] ||
    fail "${context} generation record is missing or unsafe"
  IFS= read -r line < "${record}" ||
    fail "${context} generation record is unreadable"
  tabs="${line//[^$'\t']/}"
  [[ "${#tabs}" == 9 ]] ||
    fail "${context} generation record is not the exact ten-field shape"
  IFS=$'\t' read -r id relative root_existed generations_existed \
    target_existed lifecycle_hash manifest_schema manifest_count \
    receipt_schema receipt_count extra <<< "${line}"
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/.cntools/generations/${id}" &&
     "${lifecycle_hash}" =~ ^[0-9a-f]{64}$ &&
     "${manifest_schema}:${manifest_count}:${receipt_schema}:${receipt_count}" == \
       '3:151:3:152' ]] ||
    fail "${context} generation record discriminator is malformed"
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
    ($1 == "common" || $1 == implementation) &&
      $5 != "retire" && $5 != "cntools-generation" &&
      $5 != "cntools-legacy-bundle" {
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
  if [[ "${implementation}" == "cnode" ||
        "${implementation}" == "dingo" ]]; then
    jq -r '.legacyBundle as $bundle | $bundle.members[] |
      ["scripts/" + $bundle.path + "/" + .path,
       "scripts/common-helper-scripts/" + $bundle.path + "/" + .path,
       .mode] | @tsv
    ' "${SOURCE_REPO}/scripts/common-helper-scripts/cntools/manifest.json" >> \
      "${expected}"
    LC_ALL=C sort -o "${expected}" "${expected}"
  fi
  jq -r '.files[] | [.path, .source, .mode] | @tsv' "${receipt}" |
    LC_ALL=C sort > "${actual}"
  cmp -s "${expected}" "${actual}" || {
    diff -u "${expected}" "${actual}" >&2 || true
    fail "${implementation} receipt does not exactly cover its expanded source manifest"
  }
}

assert_cntools_generation_consistency() {
  local target="$1"
  local implementation="$2"
  local expect_inactive="${3:-Y}"
  local receipt="${target}/.guild-source-receipt.json"
  local cntools_root="${target}/scripts/.cntools"
  local id=""
  local relative_path=""
  local generation=""
  local generation_receipt=""
  local payload_manifest=""
  local lifecycle=""
  local canonical="${TEST_ROOT}/${target##*/}.cntools-canonical.tsv"
  local actual_id=""
  local path="" mode="" hash="" installed="" extra=""
  local directory=""
  local count=0

  if [[ "${implementation}" == "amaru" ]]; then
    jq -e '.schemaVersion == 2 and
      (has("cntoolsGeneration") | not) and
      all(.files[]; (.path | startswith("scripts/.cntools") | not))' \
      "${receipt}" >/dev/null ||
      fail 'Amaru receipt unexpectedly owns a CNTools generation'
    [[ ! -e "${cntools_root}" && ! -L "${cntools_root}" ]] ||
      fail 'Amaru deployment created a CNTools generation tree'
    return 0
  fi

  jq -e '
    .schemaVersion == 2 and
    (.implementation == "cnode" or .implementation == "dingo") and
    (.cntoolsGeneration | type == "object" and
      keys == ["active", "fileCount", "generationReceipt",
        "generationReceiptSha256", "id", "path", "payloadManifest",
        "payloadManifestSha256", "schemaVersion", "version"] and
      .schemaVersion == 1 and .version == "13.5.7" and
      .active == false and .fileCount == 152 and
      (.id | test("^[0-9a-f]{64}$")) and
      .path == ("scripts/.cntools/generations/" + .id) and
      .payloadManifest == (.path + "/cntools/manifest.json") and
      .generationReceipt == (.path + "/.generation.json") and
      (.payloadManifestSha256 | test("^[0-9a-f]{64}$")) and
      (.generationReceiptSha256 | test("^[0-9a-f]{64}$"))) and
    all(.files[]; (.path | startswith("scripts/.cntools") | not))
  ' "${receipt}" >/dev/null ||
    fail "fresh ${implementation} CNTools host receipt contract failed"

  id="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  relative_path="$(jq -er '.cntoolsGeneration.path' "${receipt}")"
  generation="${target}/${relative_path}"
  generation_receipt="${generation}/.generation.json"
  payload_manifest="${generation}/cntools/manifest.json"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  [[ -d "${cntools_root}" && ! -L "${cntools_root}" &&
     -d "${cntools_root}/generations" && ! -L "${cntools_root}/generations" &&
     -d "${generation}" && ! -L "${generation}" &&
     -f "${generation_receipt}" && ! -L "${generation_receipt}" &&
     -f "${payload_manifest}" && ! -L "${payload_manifest}" &&
     -f "${lifecycle}" && ! -L "${lifecycle}" ]] ||
    fail "${implementation} CNTools generation tree is missing or unsafe"
  assert_eq "$(stat_mode "${cntools_root}")" '700' \
    "${implementation} CNTools root mode"
  assert_eq "$(stat_mode "${cntools_root}/generations")" '700' \
    "${implementation} CNTools generations mode"
  while IFS= read -r directory; do
    assert_eq "$(stat_mode "${directory}")" '555' \
      "${implementation} immutable generation directory mode"
  done < <(find "${generation}" -type d -print | LC_ALL=C sort)

  [[ "$(sha256_file "${payload_manifest}")" == \
       "$(jq -er '.cntoolsGeneration.payloadManifestSha256' "${receipt}")" &&
     "$(sha256_file "${generation_receipt}")" == \
       "$(jq -er '.cntoolsGeneration.generationReceiptSha256' "${receipt}")" ]] ||
    fail "${implementation} host receipt hashes do not bind its generation"
  jq -e '
    .schemaVersion == 3 and .moduleApiVersion == 1 and
    .moduleSchemaVersion == 2 and (.files | length == 151)
  ' "${payload_manifest}" >/dev/null ||
    fail "${implementation} payload manifest is not exact Stage 3 shape"
  jq -e --arg id "${id}" '
    type == "object" and
    keys == ["files", "generationIdAlgorithm", "id", "payloadManifest",
      "payloadManifestSha256", "schemaVersion", "version"] and
    .schemaVersion == 3 and .id == $id and .version == "13.5.7" and
    .generationIdAlgorithm == "sha256-path-mode-content-v1" and
    .payloadManifest == "cntools/manifest.json" and
    (.payloadManifestSha256 | test("^[0-9a-f]{64}$")) and
    (.files | type == "array" and length == 152) and
    ([.files[].path] == ([.files[].path] | sort)) and
    (([.files[].path] | length) ==
      ([.files[].path] | unique | length)) and
    all(.files[];
      type == "object" and
      keys == ["mode", "path", "sha256", "source", "validator"] and
      (.mode == "0444" or .mode == "0555") and
      (.sha256 | test("^[0-9a-f]{64}$")))
  ' "${generation_receipt}" >/dev/null ||
    fail "${implementation} immutable generation receipt contract failed"

  jq -r '.files | sort_by(.path)[] | [.path, .mode, .sha256] | @tsv' \
    "${generation_receipt}" > "${canonical}"
  actual_id="$(sha256_file "${canonical}")"
  assert_eq "${actual_id}" "${id}" \
    "${implementation} content-addressed generation identifier"
  while IFS=$'\t' read -r path mode hash extra; do
    [[ -n "${path}" && -n "${mode}" && -n "${hash}" && -z "${extra}" ]] ||
      fail "${implementation} generation emitted an incomplete file record"
    installed="${generation}/${path}"
    [[ -f "${installed}" && ! -L "${installed}" ]] ||
      fail "${implementation} generation member is missing or unsafe: ${path}"
    assert_eq "$(stat_mode "${installed}")" "${mode#0}" \
      "${implementation} generation mode for ${path}"
    assert_eq "$(sha256_file "${installed}")" "${hash}" \
      "${implementation} generation hash for ${path}"
    count=$((count + 1))
  done < <(jq -r '.files[] | [.path, .mode, .sha256] | @tsv' \
    "${generation_receipt}")
  assert_eq "${count}" '152' "${implementation} generation file count"
  (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_validate "${generation}" "${id}"
  ) || fail "${implementation} installed generation failed lifecycle validation"

  if [[ "${expect_inactive}" == "Y" ]]; then
    [[ ! -e "${cntools_root}/active" && ! -L "${cntools_root}/active" &&
       ! -e "${cntools_root}/previous" && ! -L "${cntools_root}/previous" ]] ||
      fail "fresh ${implementation} deployment activated a shadow generation"
  fi
}

assert_cntools_legacy_bundle_consistency() {
  local target="$1" implementation="$2"
  local receipt="${target}/.guild-source-receipt.json"
  local generation_id="" manifest="" bundle_id="" bundle_relative=""
  local bundle="" member="" mode="" size="" hash="" member_path=""
  local actual_size="" count=0 directory=""

  if [[ "${implementation}" == "amaru" ]]; then
    [[ ! -e "${target}/scripts/cntools/libs/legacy" &&
       ! -L "${target}/scripts/cntools/libs/legacy" ]] ||
      fail 'Amaru deployment created a CNTools legacy bundle'
    return 0
  fi
  generation_id="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  manifest="${target}/scripts/.cntools/generations/${generation_id}/cntools/manifest.json"
  bundle_id="$(jq -er '.legacyBundle.id' "${manifest}")"
  bundle_relative="$(jq -er '.legacyBundle.path' "${manifest}")"
  bundle="${target}/scripts/${bundle_relative}"
  [[ "${bundle_relative}" == "cntools/libs/legacy/${bundle_id}" &&
     -d "${bundle}" && ! -L "${bundle}" ]] ||
    fail "${implementation} public legacy bundle is missing or unsafe"
  for directory in \
    "${target}/scripts/cntools" \
    "${target}/scripts/cntools/libs" \
    "${target}/scripts/cntools/libs/legacy"; do
    [[ -d "${directory}" && ! -L "${directory}" ]] ||
      fail "${implementation} legacy bundle parent is missing or unsafe"
    assert_eq "$(stat_mode "${directory}")" '700' \
      "${implementation} private legacy bundle parent mode"
  done
  [[ -d "${bundle}" && ! -L "${bundle}" ]] ||
    fail "${implementation} legacy bundle root is missing or unsafe"
  assert_eq "$(stat_mode "${bundle}")" '555' \
    "${implementation} public legacy bundle directory mode"
  while IFS=$'\t' read -r member mode size hash; do
    member_path="${bundle}/${member}"
    [[ -f "${member_path}" && ! -L "${member_path}" ]] ||
      fail "${implementation} legacy bundle member is missing: ${member}"
    actual_size="$(wc -c < "${member_path}")"
    actual_size="${actual_size//[[:space:]]/}"
    assert_eq "$(stat_mode "${member_path}")" "${mode#0}" \
      "${implementation} public legacy member mode: ${member}"
    assert_eq "${actual_size}" "${size}" \
      "${implementation} public legacy member size: ${member}"
    assert_eq "$(sha256_file "${member_path}")" "${hash}" \
      "${implementation} public legacy member hash: ${member}"
    count=$((count + 1))
  done < <(jq -er '.legacyBundle.members[] |
    [.path,.mode,(.size|tostring),.sha256] | @tsv' "${manifest}")
  assert_eq "${count}" '10' "${implementation} public legacy member count"
  assert_eq "$(find "${bundle}" -mindepth 1 -maxdepth 1 -type f | wc -l |
    tr -d '[:space:]')" '10' "${implementation} public bundle inventory"
  [[ -z "$(find "${bundle}" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] ||
    fail "${implementation} public legacy bundle contains an unsupported entry"
  jq -e --arg prefix "scripts/${bundle_relative}/" '
    ([.files[] | select(.policy == "cntools-legacy-bundle")] | length == 10) and
    all(.files[] | select(.policy == "cntools-legacy-bundle");
      (.path | startswith($prefix)) and .mode == "0444" and
      .managed == true)
  ' "${receipt}" >/dev/null ||
    fail "${implementation} host receipt does not expand the legacy bundle"
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
  local expected_file_count=""

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
      .sourceSchemaVersion == 2 and
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
      .schemaVersion == 2 and
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
  assert_cntools_generation_consistency "${target}" "${implementation}"
  assert_cntools_legacy_bundle_consistency "${target}" "${implementation}"

  case "${implementation}" in
    cnode) expected_file_count=48 ;;
    dingo) expected_file_count=25 ;;
    amaru) expected_file_count=12 ;;
  esac
  assert_eq "$(jq -er '.files | length' "${receipt}")" \
    "${expected_file_count}" "${implementation} host receipt file count"

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
  if [[ "${implementation}" == "cnode" || "${implementation}" == "dingo" ]]; then
    assert_eq "$(sha256_file "${target}/scripts/cntools.sh")" \
      "$(sha256_file "${SOURCE_REPO}/scripts/common-helper-scripts/cntools.sh")" \
      "${implementation} legacy public CNTools launcher bytes"
    assert_eq "$(sha256_file "${target}/scripts/cntools.library")" \
      "$(sha256_file "${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library")" \
      "${implementation} legacy public CNTools library bytes"
  else
    [[ ! -e "${target}/scripts/cntools.sh" &&
       ! -e "${target}/scripts/cntools.library" ]] ||
      fail 'Amaru unexpectedly installed legacy CNTools public files'
  fi
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

run_reader_isolation_pause_case() {
  local failpoint="$1" expected_facade="$2" label="$3"
  local target_name="reader_isolation_${label//-/_}"
  local case_id="reader-isolation-${label}"
  local target="${TARGET_PARENT}/${target_name}"
  local monolith="${target}/scripts/cntools.library"
  local run_root="${TEST_ROOT}/runs/${case_id}"
  local ready="${run_root}/guild-deploy-failure.ready"
  local release="${run_root}/guild-deploy-failure.release"
  local status_file="${run_root}/background.status"
  local source_facade="${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library"
  local deploy_pid="" deploy_status=""

  mkdir -p -- "${target}/files" "${target}/scripts"
  cp -- "${SOURCE_REPO}/scripts/cnode-helper-scripts/cnode.sh" \
    "${target}/scripts/cnode.sh"
  chmod 0755 "${target}/scripts/cnode.sh"
  reconstruct_source_legacy_monolith "${monolith}" ||
    fail "could not reconstruct the reader-isolation legacy monolith"
  chmod 0644 "${monolith}"

  (
    set +e
    run_deploy "${case_id}" "${target_name}" \
      "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
      "${failpoint}" pause stage0c-transaction-failure-injection-v1 \
      cnode preview Y
    deploy_status=$?
    printf '%s\n' "${deploy_status}" > "${status_file}"
    exit 0
  ) &
  deploy_pid=$!
  if ! wait_for_test_path "${ready}" "${deploy_pid}"; then
    if kill -0 "${deploy_pid}" 2>/dev/null; then
      kill -s TERM "${deploy_pid}" 2>/dev/null || true
    fi
    wait "${deploy_pid}" >/dev/null 2>&1 || true
    [[ -f "${run_root}/output" ]] &&
      sed -n '1,200p' "${run_root}/output" >&2 || true
    fail "${label} deployment did not reach the reader-isolation pause"
  fi
  [[ -d "${target}/.guild-deploy-transaction" &&
     ! -L "${target}/.guild-deploy-transaction" ]] ||
    fail "${label} reader-isolation pause omitted the durable journal"
  [[ ! -e "${target}/scripts/guild-deploy.sh" &&
     ! -e "${target}/scripts/env" ]] ||
    fail "${label} activated a common payload before the facade boundary"
  case "${expected_facade}" in
    monolith)
      assert_eq "$(sha256_file "${monolith}")" \
        '92e800f58948a570da401bef431d6e2449f25b337138f242ab3eeb48b0cf162b' \
        "${label} paused legacy facade"
      assert_legacy_monolith_loads "${monolith}" "${label}"
      ;;
    split)
      assert_eq "$(sha256_file "${monolith}")" \
        "$(sha256_file "${source_facade}")" "${label} paused split facade"
      assert_facade_refuses_transaction "${target}" "${label}"
      ;;
    *) fail "unsupported reader-isolation facade expectation: ${expected_facade}" ;;
  esac

  (umask 077 && : > "${release}")
  wait "${deploy_pid}" || fail "${label} background deployment wrapper failed"
  [[ -f "${status_file}" && ! -L "${status_file}" ]] ||
    fail "${label} background deployment omitted its status"
  deploy_status="$(< "${status_file}")"
  assert_eq "${deploy_status}" '0' "${label} paused deployment status"
  assert_snapshot_cleanup "${run_root}/snapshots"
  assert_no_transaction_artifacts "${target}"
  assert_fresh_payload_consistency "${target}"
}

test_cntools_reader_isolation() {
  run_reader_isolation_pause_case \
    after-cntools-legacy-bundle-publish monolith bundle-published
  run_reader_isolation_pause_case after-payload:1 split facade-activated
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

test_unsafe_preserved_config_modes() {
  local target_name=unsafe_preserved_mode
  local target="${TARGET_PARENT}/${target_name}"
  local metadata="${target}/.deployment.json"
  local config="${target}/files/config.json"
  local receipt="${target}/.guild-source-receipt.json"
  local before="" after="" unsafe_mode="" custom_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${metadata}" --arg service "${target_name}" \
    '.serviceName = $service'
  printf '{"operator":"unsafe-mode-must-not-be-silently-fixed"}\n' > \
    "${config}"
  custom_hash="$(sha256_file "${config}")"

  for unsafe_mode in 660 666; do
    chmod "${unsafe_mode}" "${config}"
    before="${TEST_ROOT}/unsafe-preserve-${unsafe_mode}.before"
    after="${TEST_ROOT}/unsafe-preserve-${unsafe_mode}.after"
    target_tree_state "${target}" "${before}"
    expect_deploy_failure "unsafe-preserve-${unsafe_mode}" "${target_name}"
    grep -Fq \
      "Cannot preserve ${config} with unsafe mode 0${unsafe_mode};" \
      "${RUN_OUTPUT}" || {
      sed -n '1,160p' "${RUN_OUTPUT}" >&2 || true
      fail "unsafe preserved mode 0${unsafe_mode} omitted its refusal"
    }
    grep -Fq 'or use -s f to replace it.' "${RUN_OUTPUT}" ||
      fail "unsafe preserved mode 0${unsafe_mode} omitted the force alternative"
    assert_snapshot_cleanup
    assert_no_transaction_artifacts "${target}"
    target_tree_state "${target}" "${after}"
    cmp -s "${before}" "${after}" || {
      diff -u "${before}" "${after}" >&2 || true
      fail "unsafe preserved mode 0${unsafe_mode} mutated the target"
    }
  done

  expect_deploy_success unsafe-preserve-force "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" f
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_eq "$(stat_mode "${config}")" '644' \
    'forced unsafe config replacement mode'
  [[ "$(sha256_file "${config}")" != "${custom_hash}" ]] ||
    fail 'forced unsafe config replacement retained operator bytes'
  jq -e --arg hash "$(sha256_file "${config}")" '
    .files[] | select(.path == "files/config.json") |
    .policy == "render-cnode" and .managed == false and .mode == "0644" and
    .installedSha256 == $hash
  ' "${receipt}" >/dev/null ||
    fail 'forced unsafe config replacement receipt is not safe and rendered'
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

  target_refresh_identity_state "${target}" "${before}"
  sleep 1
  expect_deploy_success fresh-identical fresh
  assert_snapshot_cleanup
  target_refresh_identity_state "${target}" "${after}"
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'identical refresh changed target inode, mtime, mode, or content'
  }
}

test_same_payload_new_revision_generation_reuse() {
  local target="${TARGET_PARENT}/fresh"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local root="${target}/scripts/.cntools"
  local old_revision="${SOURCE_REVISION}"
  local generation_id=""
  local generation=""
  local generation_receipt_hash=""
  local bundle_id="" bundle=""
  local before="${TEST_ROOT}/same-payload-new-revision.before"
  local after="${TEST_ROOT}/same-payload-new-revision.after"
  local bundle_before="${TEST_ROOT}/same-payload-new-revision.bundle-before"
  local bundle_after="${TEST_ROOT}/same-payload-new-revision.bundle-after"
  local stable_before="${TEST_ROOT}/same-payload-new-revision.stable-before"
  local stable_after="${TEST_ROOT}/same-payload-new-revision.stable-after"
  local launcher_identity="" library_identity=""
  local count=0 directory=""

  generation_id="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  generation="${root}/generations/${generation_id}"
  bundle_id="$(jq -er '.legacyBundle.id' \
    "${generation}/cntools/manifest.json")"
  bundle="${target}/scripts/cntools/libs/legacy/${bundle_id}"
  generation_receipt_hash="$(sha256_file "${generation}/.generation.json")"
  launcher_identity="$(stat_inode "${target}/scripts/cntools.sh"):$(
    stat_mtime "${target}/scripts/cntools.sh"):$(
    stat_mode "${target}/scripts/cntools.sh"):$(
    sha256_file "${target}/scripts/cntools.sh")"
  library_identity="$(stat_inode "${target}/scripts/cntools.library"):$(
    stat_mtime "${target}/scripts/cntools.library"):$(
    stat_mode "${target}/scripts/cntools.library"):$(
    sha256_file "${target}/scripts/cntools.library")"
  generation_identity_state "${generation}" "${before}" ||
    fail 'could not record generation before cross-revision reuse'
  generation_identity_state "${bundle}" "${bundle_before}" ||
    fail 'could not record legacy bundle before cross-revision reuse'

  printf 'same CNTools payload, new Git revision\n' > \
    "${SOURCE_REPO}/stage1-revision-marker"
  "${REAL_GIT}" -C "${SOURCE_REPO}" add -- stage1-revision-marker
  "${REAL_GIT}" -C "${SOURCE_REPO}" commit -qm \
    'Stage 1 same-payload revision fixture'
  SOURCE_REVISION="$("${REAL_GIT}" -C "${SOURCE_REPO}" rev-parse HEAD)"
  [[ "${SOURCE_REVISION}" =~ ^[0-9a-f]{40}$ &&
     "${SOURCE_REVISION}" != "${old_revision}" ]] ||
    fail 'same-payload fixture did not advance the Git revision'
  assert_eq \
    "$("${REAL_GIT}" -C "${SOURCE_REPO}" status --porcelain=v1 \
      --untracked-files=all -- scripts files)" \
    ' M files/node-implementations/source-manifest.tsv' \
    'same-payload revision retained deterministic source dirtiness'
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")"

  sleep 1
  expect_deploy_success same-payload-new-revision fresh
  assert_snapshot_cleanup
  assert_eq "$(jq -er '.cntoolsGeneration.id' "${receipt}")" \
    "${generation_id}" 'same-payload generation ID reuse'
  assert_eq "$(jq -er '.cntoolsGeneration.generationReceiptSha256' \
    "${receipt}")" "${generation_receipt_hash}" \
    'same-payload nested generation receipt hash'
  generation_identity_state "${generation}" "${after}" ||
    fail 'could not record generation after cross-revision reuse'
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'same-payload revision changed immutable generation identity or bytes'
  }
  generation_identity_state "${bundle}" "${bundle_after}" ||
    fail 'could not record legacy bundle after cross-revision reuse'
  cmp -s "${bundle_before}" "${bundle_after}" || {
    diff -u "${bundle_before}" "${bundle_after}" >&2 || true
    fail 'same-payload revision changed immutable legacy bundle identity or bytes'
  }
  while IFS= read -r directory; do count=$((count + 1)); done < <(
    find "${root}/generations" -mindepth 1 -maxdepth 1 -type d -print)
  assert_eq "${count}" '1' 'same-payload generation directory count'
  count=0
  while IFS= read -r directory; do count=$((count + 1)); done < <(
    find "${target}/scripts/cntools/libs/legacy" -mindepth 1 -maxdepth 1 \
      -type d -print)
  assert_eq "${count}" '1' 'same-payload legacy bundle directory count'
  jq -e --arg revision "${SOURCE_REVISION}" \
    --arg digest "${SOURCE_TREE_DIGEST}" '
      .schemaVersion == 2 and
      .source.revision == $revision and
      .source.treeDigest == $digest
    ' "${receipt}" >/dev/null ||
    fail 'same-payload outer receipt did not advance Git provenance'
  jq -e --arg revision "${SOURCE_REVISION}" \
    --arg digest "${SOURCE_TREE_DIGEST}" '
      .sourceRevision == $revision and .sourceTreeDigest == $digest
    ' "${metadata}" >/dev/null ||
    fail 'same-payload metadata did not advance Git provenance'
  jq -e 'has("source") | not' "${generation}/.generation.json" >/dev/null ||
    fail 'content-deterministic nested receipt retained Git provenance'
  assert_eq "$(stat_inode "${target}/scripts/cntools.sh"):$(
    stat_mtime "${target}/scripts/cntools.sh"):$(
    stat_mode "${target}/scripts/cntools.sh"):$(
    sha256_file "${target}/scripts/cntools.sh")" "${launcher_identity}" \
    'same-payload public CNTools launcher identity'
  assert_eq "$(stat_inode "${target}/scripts/cntools.library"):$(
    stat_mtime "${target}/scripts/cntools.library"):$(
    stat_mode "${target}/scripts/cntools.library"):$(
    sha256_file "${target}/scripts/cntools.library")" "${library_identity}" \
    'same-payload compatibility library identity'
  assert_receipt_metadata_coherent "${target}"
  assert_cntools_generation_consistency "${target}" cnode
  (
    export NODE_HOME="${target}"
    # shellcheck source=/dev/null
    . "${target}/scripts/lib/deployment.library"
    deployment_payload_is_current
  ) || fail 'same-payload revision reuse was not current'

  target_refresh_identity_state "${target}" "${stable_before}"
  sleep 1
  expect_deploy_success same-payload-new-revision-identical fresh
  assert_snapshot_cleanup
  target_refresh_identity_state "${target}" "${stable_after}"
  cmp -s "${stable_before}" "${stable_after}" || {
    diff -u "${stable_before}" "${stable_after}" >&2 || true
    fail 'same-payload revision idempotent refresh changed target identity'
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
      .sourceSchemaVersion == 2 and
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

test_stage0_schema1_receipt_migration() {
  local target="${TARGET_PARENT}/schema1_migration"
  local metadata="${target}/.deployment.json"
  local receipt="${target}/.guild-source-receipt.json"
  local old_generation="${TEST_ROOT}/schema1-migration-old-generation"
  local launcher_hash=""
  local library_hash=""
  local receipt_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  launcher_hash="$(sha256_file "${target}/scripts/cntools.sh")"
  library_hash="$(sha256_file "${target}/scripts/cntools.library")"
  mv -- "${target}/scripts/.cntools" "${old_generation}"
  atomic_jq_update "${receipt}" '
    .schemaVersion = 1 | del(.cntoolsGeneration)
  '
  rewrite_receipt_legacy_inventory_order "${receipt}" cnode ||
    fail 'schema 1 migration receipt did not retain historical order'
  receipt_hash="$(sha256_file "${receipt}")"
  atomic_jq_update "${metadata}" --arg hash "${receipt_hash}" \
    --arg service schema1_migration '
      .serviceName = $service |
      .sourceSchemaVersion = 1 |
      .payloadReceiptSha256 = $hash |
      .transactionId = $hash[0:24]
    '

  expect_deploy_success schema1-receipt-migration schema1_migration
  assert_snapshot_cleanup
  assert_eq "$(sha256_file "${target}/scripts/cntools.sh")" \
    "${launcher_hash}" 'schema 1 migration legacy launcher bytes'
  assert_eq "$(sha256_file "${target}/scripts/cntools.library")" \
    "${library_hash}" 'schema 1 migration legacy library bytes'
  assert_fresh_payload_consistency "${target}"
}

assert_unsafe_cntools_path_rejected() {
  local case_id="$1"
  local target_name="$2"
  local unsafe_kind="$3"
  local generation_id="$4"
  local target="${TARGET_PARENT}/${target_name}"
  local external="${TEST_ROOT}/${case_id}.external"
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"
  local sentinel_hash=""

  mkdir -p -- "${target}/files" "${target}/scripts" "${external}"
  printf 'do-not-touch\n' > "${external}/sentinel"
  sentinel_hash="$(sha256_file "${external}/sentinel")"
  case "${unsafe_kind}" in
    root)
      ln -s "${external}" "${target}/scripts/.cntools"
      ;;
    generations)
      mkdir -m 0700 -- "${target}/scripts/.cntools"
      ln -s "${external}" "${target}/scripts/.cntools/generations"
      ;;
    generation)
      mkdir -m 0700 -- "${target}/scripts/.cntools" \
        "${target}/scripts/.cntools/generations"
      ln -s "${external}" \
        "${target}/scripts/.cntools/generations/${generation_id}"
      ;;
    *) fail "unknown unsafe CNTools fixture: ${unsafe_kind}" ;;
  esac
  target_tree_state "${target}" "${before}" Y
  expect_deploy_failure "${case_id}" "${target_name}"
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail "rejected ${unsafe_kind} generation symlink mutated the target"
  }
  assert_eq "$(sha256_file "${external}/sentinel")" "${sentinel_hash}" \
    "${unsafe_kind} generation symlink external sentinel"
}

test_unsafe_cntools_generation_paths() {
  local generation_id=""
  generation_id="$(jq -er '.cntoolsGeneration.id' \
    "${TARGET_PARENT}/fresh/.guild-source-receipt.json")"
  assert_unsafe_cntools_path_rejected unsafe-cntools-root \
    unsafe_cntools_root root "${generation_id}"
  assert_unsafe_cntools_path_rejected unsafe-cntools-generations \
    unsafe_cntools_generations generations "${generation_id}"
  assert_unsafe_cntools_path_rejected unsafe-cntools-generation \
    unsafe_cntools_generation generation "${generation_id}"
}

test_tampered_installed_lifecycle_never_executes() {
  local target_name="${1:-tampered_generation_lifecycle}"
  local target="${TARGET_PARENT}/${target_name}"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local id=""
  local lifecycle=""
  local sentinel="${TEST_ROOT}/${target_name}.executed"
  local before="${TEST_ROOT}/${target_name}.before"
  local after="${TEST_ROOT}/${target_name}.after"
  local old_receipt="${TEST_ROOT}/${target_name}.receipt"
  local old_metadata="${TEST_ROOT}/${target_name}.metadata"
  local launcher_hash=""
  local library_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${metadata}" --arg service "${target_name}" \
    '.serviceName = $service'
  id="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  lifecycle="${target}/scripts/.cntools/generations/${id}/cntools/core/lifecycle.sh"
  launcher_hash="$(sha256_file "${target}/scripts/cntools.sh")"
  library_hash="$(sha256_file "${target}/scripts/cntools.library")"
  chmod 0644 "${lifecycle}"
  printf '#!/usr/bin/env bash\nprintf executed > %q\n' "${sentinel}" > \
    "${lifecycle}"
  printf '%s\n' \
    'cntools_generation_validate() { return 2; }' \
    'cntools_generation_prune() { return 2; }' >> "${lifecycle}"
  chmod 0444 "${lifecycle}"
  cp -- "${receipt}" "${old_receipt}"
  cp -- "${metadata}" "${old_metadata}"
  target_tree_state "${target}" "${before}" Y

  expect_deploy_failure "${target_name}" "${target_name}"
  [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
    fail 'dispatcher executed an unauthenticated installed lifecycle file'
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'rejected installed lifecycle tamper mutated canonical target state'
  }
  cmp -s "${old_receipt}" "${receipt}" ||
    fail 'installed lifecycle tamper changed authoritative receipt'
  cmp -s "${old_metadata}" "${metadata}" ||
    fail 'installed lifecycle tamper changed authoritative metadata'
  assert_eq "$(sha256_file "${target}/scripts/cntools.sh")" \
    "${launcher_hash}" 'lifecycle tamper legacy launcher bytes'
  assert_eq "$(sha256_file "${target}/scripts/cntools.library")" \
    "${library_hash}" 'lifecycle tamper legacy library bytes'
  assert_snapshot_cleanup
}

advance_cntools_payload() {
  local label="$1"
  local source='scripts/common-helper-scripts/cntools/docs/TESTING.md'
  local manifest="${SOURCE_REPO}/scripts/common-helper-scripts/cntools/manifest.json"
  local digest=""

  chmod u+w "${SOURCE_REPO}/${source}" "${manifest}"
  printf '\nStage 1 transaction fixture: %s.\n' "${label}" >> \
    "${SOURCE_REPO}/${source}"
  digest="$(sha256_file "${SOURCE_REPO}/${source}")"
  atomic_jq_update "${manifest}" --arg source "${source}" \
    --arg digest "${digest}" '
      (.files[] | select(.source == $source) | .sha256) = $digest
    '
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")"
}

forge_recovery_generation() {
  local generation="$1"
  local sentinel="$2"
  local manifest="${generation}/cntools/manifest.json"
  local receipt="${generation}/.generation.json"
  local lifecycle="${generation}/cntools/core/lifecycle.sh"
  local canonical="${TEST_ROOT}/forged-recovery-generation.canonical"
  local lifecycle_hash="" manifest_hash="" generation_id=""
  local path="" mode="" destination=""

  chmod -R u+rwX "${generation}"
  printf '#!/usr/bin/env bash\nprintf executed > %q\n' "${sentinel}" > \
    "${lifecycle}"
  printf '%s\n' \
    'cntools_generation_validate() { return 0; }' \
    'cntools_generation_deployment_lock_acquire() { return 0; }' \
    'cntools_generation_lock_is_owned() { return 0; }' \
    'cntools_generation_lock_release() { return 0; }' >> "${lifecycle}"
  lifecycle_hash="$(sha256_file "${lifecycle}")"
  atomic_jq_update "${manifest}" --arg hash "${lifecycle_hash}" '
    (.files[] | select(.path == "cntools/core/lifecycle.sh") | .sha256) = $hash
  '
  manifest_hash="$(sha256_file "${manifest}")"
  atomic_jq_update "${receipt}" \
    --arg lifecycle_hash "${lifecycle_hash}" \
    --arg manifest_hash "${manifest_hash}" '
      .payloadManifestSha256 = $manifest_hash |
      (.files[] | select(.path == "cntools/core/lifecycle.sh") | .sha256) =
        $lifecycle_hash |
      (.files[] | select(.path == "cntools/manifest.json") | .sha256) =
        $manifest_hash
    '
  jq -r '.files | sort_by(.path)[] | [.path,.mode,.sha256] | @tsv' \
    "${receipt}" > "${canonical}"
  generation_id="$(sha256_file "${canonical}")"
  atomic_jq_update "${receipt}" --arg id "${generation_id}" '.id = $id'
  while IFS=$'\t' read -r path mode; do
    chmod "${mode}" "${generation}/${path}"
  done < <(jq -r '.files[] | [.path,.mode] | @tsv' "${receipt}")
  chmod 0444 "${receipt}"
  find "${generation}" -depth -type d -exec chmod 0555 {} +
  destination="$(dirname -- "${generation}")/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 2
  chmod 0755 "${generation}"
  mv -- "${generation}" "${destination}"
  chmod 0555 "${destination}"
  printf '%s\t%s\n' "${generation_id}" "${lifecycle_hash}"
}

test_inactive_generation_upgrade_retains_active() {
  local target="${TARGET_PARENT}/active_generation_upgrade"
  local receipt="${target}/.guild-source-receipt.json"
  local root="${target}/scripts/.cntools"
  local generation_a=""
  local generation_b=""
  local active_before=""
  local launcher_hash=""
  local library_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${target}/.deployment.json" --arg service \
    active_generation_upgrade '.serviceName = $service'
  generation_a="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  # shellcheck source=/dev/null
  . "${root}/generations/${generation_a}/cntools/core/lifecycle.sh"
  cntools_generation_activate "${root}" "${generation_a}" ||
    fail 'could not activate generation A for the upgrade fixture'
  active_before="$(readlink "${root}/active")"
  launcher_hash="$(sha256_file "${target}/scripts/cntools.sh")"
  library_hash="$(sha256_file "${target}/scripts/cntools.library")"

  advance_cntools_payload inactive-upgrade-b
  expect_deploy_success inactive-generation-upgrade active_generation_upgrade
  assert_snapshot_cleanup
  generation_b="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  [[ "${generation_b}" != "${generation_a}" ]] ||
    fail 'changed CNTools payload did not produce a new generation ID'
  [[ -d "${root}/generations/${generation_a}" &&
     -d "${root}/generations/${generation_b}" ]] ||
    fail 'inactive generation install did not retain both A and B'
  [[ -L "${root}/active" &&
     "$(readlink "${root}/active")" == "${active_before}" &&
     ! -e "${root}/previous" && ! -L "${root}/previous" ]] ||
    fail 'installing generation B changed the A activation pointers'
  assert_cntools_generation_consistency "${target}" cnode N
  assert_eq "$(sha256_file "${target}/scripts/cntools.sh")" \
    "${launcher_hash}" 'inactive upgrade legacy launcher bytes'
  assert_eq "$(sha256_file "${target}/scripts/cntools.library")" \
    "${library_hash}" 'inactive upgrade legacy library bytes'
  (
    export NODE_HOME="${target}"
    # shellcheck source=/dev/null
    . "${target}/scripts/lib/deployment.library"
    deployment_payload_is_current
  ) || fail 'receipt candidate B was not current while generation A was active'
}

test_live_generation_lock_prejournal_refusal() {
  local target_name="live_generation_lock"
  local target="${TARGET_PARENT}/${target_name}"
  local root="${target}/scripts/.cntools"
  local receipt="${target}/.guild-source-receipt.json"
  local generation_id=""
  local active_id=""
  local lifecycle=""
  local ready="${TEST_ROOT}/${target_name}.ready"
  local release="${TEST_ROOT}/${target_name}.release"
  local holder_output="${TEST_ROOT}/${target_name}.holder-output"
  local before="${TEST_ROOT}/${target_name}.before"
  local after="${TEST_ROOT}/${target_name}.after"
  local holder_pid=""
  local recorded_holder_pid=""
  local main_pid="${BASHPID:-$$}"
  local holder_status=0
  local deploy_status=0
  local unchanged="Y"

  copy_target "${TARGET_PARENT}/active_generation_upgrade" "${target}"
  atomic_jq_update "${target}/.deployment.json" --arg service "${target_name}" \
    '.serviceName = $service'
  generation_id="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  active_id="$(readlink "${root}/active")"
  active_id="${active_id#generations/}"
  lifecycle="${root}/generations/${generation_id}/cntools/core/lifecycle.sh"

  "${BASH_UNDER_TEST}" -c '
    set -euo pipefail
    lifecycle=$1
    root=$2
    ready=$3
    release=$4
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_lock_acquire "${root}"
    release_lock() {
      if cntools_generation_lock_is_owned "${root}"; then
        cntools_generation_lock_release "${root}" || true
      fi
    }
    trap release_lock EXIT
    process_pid="${BASHPID:-$$}"
    (umask 077 && printf "%s\n" "${process_pid}" > "${ready}")
    for ((attempt = 0; attempt < 600; attempt++)); do
      [[ -e "${release}" || -L "${release}" ]] && exit 0
      sleep 0.1
    done
    exit 124
  ' bash "${lifecycle}" "${root}" "${ready}" "${release}" \
    > "${holder_output}" 2>&1 &
  holder_pid=$!
  if ! wait_for_test_path "${ready}" "${holder_pid}"; then
    : > "${release}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    sed -n '1,120p' "${holder_output}" >&2 || true
    fail 'lifecycle lock holder did not become ready'
  fi
  recorded_holder_pid="$(< "${ready}")"
  [[ "${recorded_holder_pid}" =~ ^[0-9]+$ &&
     "${recorded_holder_pid}" != "${main_pid}" ]] &&
    kill -0 "${recorded_holder_pid}" 2>/dev/null &&
    process_is_same_or_descendant "${recorded_holder_pid}" "${holder_pid}" || {
      : > "${release}"
      wait "${holder_pid}" >/dev/null 2>&1 || true
      fail 'lifecycle lock holder reported an unsafe process ID'
    }
  target_tree_state "${target}" "${before}" Y
  if (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_lock_acquire "${root}"
  ) >/dev/null 2>&1; then
    : > "${release}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail 'a second lifecycle contender acquired the live advisory lock'
  fi
  if (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_activate "${root}" "${generation_id}"
  ) >/dev/null 2>&1; then
    : > "${release}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail 'canary activation bypassed a live deployment-generation lock'
  fi
  if (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_prune "${root}" "${active_id}"
  ) >/dev/null 2>&1; then
    : > "${release}"
    wait "${holder_pid}" >/dev/null 2>&1 || true
    fail 'generation pruning bypassed a live deployment-generation lock'
  fi
  if run_deploy live-generation-lock-refusal "${target_name}"; then
    deploy_status=0
  else
    deploy_status=$?
  fi
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || unchanged="N"
  kill -s KILL "${recorded_holder_pid}" 2>/dev/null || true
  if wait "${holder_pid}"; then
    holder_status=0
  else
    holder_status=$?
  fi

  (( holder_status != 0 )) ||
    fail 'SIGKILL did not terminate the lifecycle lock holder'
  (( deploy_status != 0 )) ||
    fail 'deployment succeeded while a live lifecycle lock was held'
  [[ "${unchanged}" == "Y" ]] || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'live lifecycle-lock refusal changed the target pre-journal'
  }
  [[ ! -e "${target}/.guild-deploy-transaction" &&
     ! -L "${target}/.guild-deploy-transaction" ]] ||
    fail 'live lifecycle-lock refusal created a durable journal'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  expect_deploy_success generation-lock-sigkill-recovery "${target_name}"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_cntools_generation_consistency "${target}" cnode N
}

test_generation_prune_receipt_race() {
  local target_name="generation_prune_receipt_race"
  local case_id="generation-prune-receipt-race"
  local target="${TARGET_PARENT}/${target_name}"
  local root="${target}/scripts/.cntools"
  local receipt="${target}/.guild-source-receipt.json"
  local generation_a=""
  local generation_b=""
  local lifecycle=""
  local run_root="${TEST_ROOT}/runs/${case_id}"
  local ready="${run_root}/guild-deploy-failure.ready"
  local release="${run_root}/guild-deploy-failure.release"
  local status_file="${run_root}/background.status"
  local before="${TEST_ROOT}/${target_name}.before"
  local after="${TEST_ROOT}/${target_name}.after"
  local deploy_pid=""
  local deploy_status=""
  local prune_status=0

  # The source was advanced to B by the inactive-upgrade case. Keep this host
  # on receipt/active A so the paused deployment must publish a distinct B.
  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${target}/.deployment.json" --arg service "${target_name}" \
    '.serviceName = $service'
  generation_a="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  lifecycle="${root}/generations/${generation_a}/cntools/core/lifecycle.sh"
  (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_activate "${root}" "${generation_a}"
  ) || fail 'could not activate generation A for the prune-race fixture'

  (
    set +e
    run_deploy "${case_id}" "${target_name}" \
      "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
      before-receipt-publish pause
    deploy_status=$?
    printf '%s\n' "${deploy_status}" > "${status_file}"
    exit 0
  ) &
  deploy_pid=$!
  if ! wait_for_test_path "${ready}" "${deploy_pid}"; then
    if kill -0 "${deploy_pid}" 2>/dev/null; then
      kill -s TERM "${deploy_pid}" 2>/dev/null || true
    fi
    wait "${deploy_pid}" >/dev/null 2>&1 || true
    [[ -f "${run_root}/output" ]] && sed -n '1,160p' \
      "${run_root}/output" >&2 || true
    fail 'deployment did not pause before receipt publication'
  fi
  [[ "$(stat_mode "${ready}")" == '600' ]] || {
    (umask 077 && : > "${release}")
    wait "${deploy_pid}" >/dev/null 2>&1 || true
    fail 'deployment pause ready marker had an unsafe mode'
  }
  [[ -d "${target}/.guild-deploy-transaction" ]] || {
    (umask 077 && : > "${release}")
    wait "${deploy_pid}" >/dev/null 2>&1 || true
    fail 'paused receipt publication did not retain its durable transaction'
  }
  generation_b="$(find "${root}/generations" -mindepth 1 -maxdepth 1 \
    -type d ! -name "${generation_a}" -exec basename {} \; -quit)"
  [[ "${generation_b}" =~ ^[0-9a-f]{64}$ ]] || {
    (umask 077 && : > "${release}")
    wait "${deploy_pid}" >/dev/null 2>&1 || true
    fail 'paused deployment did not publish candidate generation B'
  }

  target_tree_state "${target}" "${before}" Y
  (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_prune "${root}" "${generation_a}"
  ) >/dev/null 2>&1 && prune_status=0 || prune_status=$?
  target_tree_state "${target}" "${after}" Y
  (( prune_status != 0 )) || {
    (umask 077 && : > "${release}")
    wait "${deploy_pid}" >/dev/null 2>&1 || true
    fail 'concurrent prune acquired the deployment-owned generation state'
  }
  if ! cmp -s "${before}" "${after}"; then
    (umask 077 && : > "${release}")
    wait "${deploy_pid}" >/dev/null 2>&1 || true
    diff -u "${before}" "${after}" >&2 || true
    fail 'rejected concurrent prune changed the paused deployment state'
  fi

  (umask 077 && : > "${release}")
  wait "${deploy_pid}" || fail 'background deployment wrapper failed'
  [[ -f "${status_file}" && ! -L "${status_file}" ]] ||
    fail 'background deployment did not record its exit status'
  deploy_status="$(< "${status_file}")"
  assert_eq "${deploy_status}" '0' 'paused deployment exit status'
  assert_eq "$(jq -er '.cntoolsGeneration.id' "${receipt}")" \
    "${generation_b}" 'receipt candidate after prune race'
  [[ -d "${root}/generations/${generation_b}" &&
     -L "${root}/active" &&
     "$(readlink "${root}/active")" == "generations/${generation_a}" ]] ||
    fail 'receipt B committed without its generation or changed active A'
  assert_cntools_generation_consistency "${target}" cnode N
  (
    export NODE_HOME="${target}"
    # shellcheck source=/dev/null
    . "${target}/scripts/lib/deployment.library"
    deployment_payload_is_current
  ) || fail 'post-race receipt B was not current'
  assert_snapshot_cleanup "${run_root}/snapshots"
  assert_no_transaction_artifacts "${target}"
  [[ ! -e "${ready}" && ! -L "${ready}" &&
     ! -e "${release}" && ! -L "${release}" ]] ||
    fail 'pause hook leaked synchronization artifacts'
}

test_generation_rename_crash_recovery_case() {
  local implementation="$1"
  local network="$2"
  local source_target="$3"
  local target_name="${implementation}_generation_rename_crash"
  local target="${TARGET_PARENT}/${target_name}"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local old_receipt="${TEST_ROOT}/${implementation}-rename-crash.receipt"
  local old_metadata="${TEST_ROOT}/${implementation}-rename-crash.metadata"
  local generation_a=""
  local candidate=""
  local fake_linux="N"

  [[ "${implementation}" == "dingo" ]] && fake_linux="Y"
  copy_target "${TARGET_PARENT}/${source_target}" "${target}"
  atomic_jq_update "${metadata}" --arg service "${target_name}" \
    '.serviceName = $service'
  generation_a="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  cp -- "${receipt}" "${old_receipt}"
  cp -- "${metadata}" "${old_metadata}"

  if run_deploy "${implementation}-generation-rename-crash" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-cntools-generation-rename crash \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" "${network}" "${fake_linux}"; then
    fail "${implementation} generation-rename crash unexpectedly succeeded"
  fi
  assert_eq "${RUN_STATUS}" '137' \
    "${implementation} generation-rename crash status"
  grep -Fq "transaction failpoint 'after-cntools-generation-rename'" \
    "${RUN_OUTPUT}" ||
    fail "${implementation} generation-rename crash hook was not reached"
  cmp -s "${old_receipt}" "${receipt}" ||
    fail "${implementation} generation-rename crash published a receipt"
  cmp -s "${old_metadata}" "${metadata}" ||
    fail "${implementation} generation-rename crash published metadata"
  candidate="$(find "${target}/scripts/.cntools/generations" \
    -mindepth 1 -maxdepth 1 -type d ! -name "${generation_a}" -print -quit)"
  [[ -n "${candidate}" && "$(stat_mode "${candidate}")" == "755" ]] ||
    fail "${implementation} crash did not stop after rename and before mode normalization"

  expect_deploy_success "${implementation}-generation-rename-recovery" \
    "${target_name}" "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' \
    "${DISPATCHER}" '' '' return \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" "${network}" "${fake_linux}"
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail "${implementation} did not report generation-rename crash recovery"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_receipt_metadata_coherent "${target}"
  assert_cntools_generation_consistency "${target}" "${implementation}"
}

test_generation_rename_crash_recovery() {
  test_generation_rename_crash_recovery_case cnode preview fresh
  test_generation_rename_crash_recovery_case dingo preview fresh_dingo
}

test_bundle_rename_crash_recovery_case() {
  local implementation="$1" network="$2"
  local target_name="${implementation}_bundle_rename_crash"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local record="${transaction}/cntools-legacy-bundle.tsv"
  local id="" relative="" cntools_existed="" libs_existed=""
  local legacy_existed="" target_existed="" manifest_sha="" extra=""
  local candidate="" fake_linux="N" expected_port="6000"

  if [[ "${implementation}" == "dingo" ]]; then
    fake_linux="Y"
    expected_port="3001"
  fi
  mkdir -p -- "${target}/files"
  if run_deploy "${implementation}-bundle-rename-crash" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-cntools-legacy-bundle-rename crash \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" "${network}" "${fake_linux}"; then
    fail "${implementation} bundle-rename crash unexpectedly succeeded"
  fi
  assert_eq "${RUN_STATUS}" '137' "${implementation} bundle-rename crash status"
  grep -Fq "transaction failpoint 'after-cntools-legacy-bundle-rename'" \
    "${RUN_OUTPUT}" ||
    fail "${implementation} bundle-rename crash hook was not reached"
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${record}" && ! -L "${record}" ]] ||
    fail "${implementation} bundle-rename crash omitted its durable record"
  IFS=$'\t' read -r id relative cntools_existed libs_existed \
    legacy_existed target_existed manifest_sha extra < "${record}"
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/cntools/libs/legacy/${id}" &&
     "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" == \
       'N:N:N:N' && "${manifest_sha}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "${implementation} bundle-rename durable record was malformed"
  candidate="${target}/${relative}"
  [[ -d "${candidate}" && ! -L "${candidate}" &&
     "$(stat_mode "${candidate}")" == '755' ]] ||
    fail "${implementation} crash did not stop before bundle mode normalization"
  [[ ! -e "${transaction}/cntools-legacy-bundle/${id}" &&
     ! -L "${transaction}/cntools-legacy-bundle/${id}" ]] ||
    fail "${implementation} bundle rename left both public and staged trees"

  expect_deploy_success "${implementation}-bundle-rename-recovery" \
    "${target_name}" "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' \
    "${DISPATCHER}" '' '' return \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" "${network}" "${fake_linux}"
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail "${implementation} did not report bundle-rename crash recovery"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_receipt_metadata_coherent "${target}"
  assert_fresh_payload_consistency \
    "${target}" "${implementation}" "${network}" "${expected_port}"
}

test_bundle_rename_crash_recovery() {
  test_bundle_rename_crash_recovery_case cnode preview
  test_bundle_rename_crash_recovery_case dingo preview
}

seed_cnode_profile_directory_skeleton() {
  local target="$1"

  # The dispatcher treats this exact directory-only shape as an empty target
  # while the profile uses files/ to suppress unrelated package installation.
  mkdir -p -- "${target}/files"
}

assert_first_install_rollback_skeleton() {
  local target="$1" context="$2" unexpected=""

  [[ -d "${target}/files" && ! -L "${target}/files" ]] ||
    fail "${context} removed the caller-provided files/ skeleton"
  unexpected="$(find "${target}" -mindepth 1 \
    \( -type f -o -type l \) -print -quit)"
  [[ -z "${unexpected}" ]] ||
    fail "${context} retained a transaction-managed path: ${unexpected}"
  [[ ! -e "${target}/scripts/.cntools" &&
     ! -L "${target}/scripts/.cntools" &&
     ! -e "${target}/scripts/cntools" &&
     ! -L "${target}/scripts/cntools" ]] ||
    fail "${context} retained CNTools generation or bundle state"
}

prepare_fresh_bundle_publish_crash() {
  local case_id="$1" target_name="$2"
  local implementation="${3:-cnode}"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local record="${transaction}/cntools-legacy-bundle.tsv"
  local id="" relative="" cntools_existed="" libs_existed=""
  local legacy_existed="" target_existed="" manifest_sha="" extra=""
  local fake_linux="N"

  [[ "${implementation}" == dingo ]] && fake_linux="Y"

  seed_cnode_profile_directory_skeleton "${target}"
  if run_deploy "${case_id}" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-cntools-legacy-bundle-publish crash \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" preview "${fake_linux}"; then
    fail "${case_id} bundle-publish crash unexpectedly succeeded"
  fi
  assert_eq "${RUN_STATUS}" '137' "${case_id} bundle-publish crash status"
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${record}" && ! -L "${record}" ]] ||
    fail "${case_id} bundle-publish crash omitted its durable record"
  IFS=$'\t' read -r id relative cntools_existed libs_existed \
    legacy_existed target_existed manifest_sha extra < "${record}"
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/cntools/libs/legacy/${id}" &&
     "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" == \
       'N:N:N:N' && "${manifest_sha}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "${case_id} bundle-publish record was malformed"
  BUNDLE_FIXTURE_TARGET="${target}/${relative}"
  BUNDLE_FIXTURE_STAGED="${transaction}/cntools-legacy-bundle/${id}"
  BUNDLE_FIXTURE_TRANSACTION="${transaction}"
  [[ -d "${BUNDLE_FIXTURE_TARGET}" &&
     ! -L "${BUNDLE_FIXTURE_TARGET}" &&
     "$(stat_mode "${BUNDLE_FIXTURE_TARGET}")" == '555' &&
     ! -e "${BUNDLE_FIXTURE_STAGED}" &&
     ! -L "${BUNDLE_FIXTURE_STAGED}" ]] ||
    fail "${case_id} did not stop after immutable public bundle publication"
}

assert_bundle_recovery_then_prejournal_stop() {
  local case_id="$1" target_name="$2"
  local implementation="${3:-cnode}"
  local target="${TARGET_PARENT}/${target_name}"
  local fake_linux="N"

  [[ "${implementation}" == dingo ]] && fake_linux="Y"

  if run_deploy "${case_id}-recovery" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" preview "${fake_linux}"; then
    fail "${case_id} post-recovery pre-journal stop unexpectedly succeeded"
  fi
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail "${case_id} did not report interrupted transaction recovery"
  grep -Fq "transaction failpoint 'before-durable-journal'" "${RUN_OUTPUT}" ||
    fail "${case_id} did not reach the fresh pre-journal boundary"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_first_install_rollback_skeleton "${target}" "${case_id} recovery"
}

test_bundle_rollback_state_table() {
  local case_id="" target_name="" target="" transaction=""
  local generation_record="" generation_id="" generation_relative=""
  local root_existed="" generations_existed="" target_existed=""
  local lifecycle_hash="" manifest_schema="" manifest_count=""
  local receipt_schema="" receipt_count="" extra=""
  local generation_target="" generation_staged="" before="" after=""

  case_id='stage3-paired-state-both-absent'
  target_name='stage3_paired_state_both_absent'
  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  target="${TARGET_PARENT}/${target_name}"
  transaction="${BUNDLE_FIXTURE_TRANSACTION}"
  generation_record="${transaction}/cntools-generation.tsv"
  assert_stage3_generation_record "${generation_record}" \
    'paired Stage 3 already-retracted recovery'
  IFS=$'\t' read -r generation_id generation_relative root_existed \
    generations_existed target_existed lifecycle_hash manifest_schema \
    manifest_count receipt_schema receipt_count extra < "${generation_record}"
  [[ -z "${extra}" &&
     "${manifest_schema}:${manifest_count}:${receipt_schema}:${receipt_count}" == \
       '3:151:3:152' ]] ||
    fail 'paired Stage 3 recovery record lost its exact discriminator'
  generation_target="${target}/${generation_relative}"
  generation_staged="${transaction}/cntools-generation/${generation_id}"
  [[ -d "${generation_target}" && ! -L "${generation_target}" &&
     ! -e "${generation_staged}" && ! -L "${generation_staged}" ]] ||
    fail 'paired Stage 3 fixture did not publish exactly one generation tree'
  chmod -R u+rwX "${generation_target}"
  rm -rf -- "${generation_target}"
  chmod -R u+rwX "${BUNDLE_FIXTURE_TARGET}"
  rm -rf -- "${BUNDLE_FIXTURE_TARGET}"
  [[ ! -e "${generation_target}" && ! -L "${generation_target}" &&
     ! -e "${generation_staged}" && ! -L "${generation_staged}" &&
     ! -e "${BUNDLE_FIXTURE_TARGET}" && ! -L "${BUNDLE_FIXTURE_TARGET}" &&
     ! -e "${BUNDLE_FIXTURE_STAGED}" && ! -L "${BUNDLE_FIXTURE_STAGED}" ]] ||
    fail 'could not prepare paired Stage 3 generation/bundle N:N rollback state'
  assert_bundle_recovery_then_prejournal_stop "${case_id}" "${target_name}"

  case_id='bundle-state-public-0755'
  target_name='bundle_state_public_0755'
  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  chmod 0755 "${BUNDLE_FIXTURE_TARGET}"
  assert_bundle_recovery_then_prejournal_stop "${case_id}" "${target_name}"

  case_id='bundle-state-staged-0755'
  target_name='bundle_state_staged_0755'
  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  chmod 0755 "${BUNDLE_FIXTURE_TARGET}"
  mv -- "${BUNDLE_FIXTURE_TARGET}" "${BUNDLE_FIXTURE_STAGED}"
  [[ -d "${BUNDLE_FIXTURE_STAGED}" &&
     "$(stat_mode "${BUNDLE_FIXTURE_STAGED}")" == '755' ]] ||
    fail 'could not prepare the bundle N:Y rollback move-back state'
  assert_bundle_recovery_then_prejournal_stop "${case_id}" "${target_name}"

  case_id='bundle-state-public-and-staged'
  target_name='bundle_state_public_and_staged'
  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  cp -R -- "${BUNDLE_FIXTURE_TARGET}" "${BUNDLE_FIXTURE_STAGED}"
  target_tree_state "${TARGET_PARENT}/${target_name}" \
    "${TEST_ROOT}/${case_id}.before-refusal" Y
  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  [[ -d "${BUNDLE_FIXTURE_TRANSACTION}" &&
     ! -L "${BUNDLE_FIXTURE_TRANSACTION}" ]] ||
    fail 'bundle Y:Y rollback refusal removed the durable journal'
  target_tree_state "${TARGET_PARENT}/${target_name}" \
    "${TEST_ROOT}/${case_id}.after-refusal" Y
  cmp -s "${TEST_ROOT}/${case_id}.before-refusal" \
    "${TEST_ROOT}/${case_id}.after-refusal" || {
    diff -u "${TEST_ROOT}/${case_id}.before-refusal" \
      "${TEST_ROOT}/${case_id}.after-refusal" >&2 || true
    fail 'bundle Y:Y rollback refusal mutated the interrupted target'
  }
  assert_snapshot_cleanup
}

test_stage2_six_field_paired_recovery() {
  local implementation="" case_id="" target_name=""
  local target="" transaction="" record="" current_generation=""
  local current_id="" current_relative="" root_existed=""
  local generations_existed="" target_existed="" current_lifecycle_hash=""
  local manifest_schema="" manifest_count="" receipt_schema=""
  local receipt_count="" extra="" stage2_result="" stage2_id=""
  local stage2_lifecycle_hash="" stage2_generation="" stage2_staged=""
  local validator="" field_count=""

  for implementation in cnode dingo; do
    case_id="stage2-${implementation}-paired-both-absent"
    target_name="stage2_${implementation}_paired_both_absent"
    prepare_fresh_bundle_publish_crash \
      "${case_id}-crash" "${target_name}" "${implementation}"
    target="${TARGET_PARENT}/${target_name}"
    transaction="${BUNDLE_FIXTURE_TRANSACTION}"
    record="${transaction}/cntools-generation.tsv"
    validator="${transaction}/cntools-generation-validator.sh"
    assert_stage3_generation_record "${record}" \
      "${implementation} Stage 2 conversion source"
    IFS=$'\t' read -r current_id current_relative root_existed \
      generations_existed target_existed current_lifecycle_hash \
      manifest_schema manifest_count receipt_schema receipt_count extra \
      < "${record}"
    [[ -z "${extra}" &&
       "${manifest_schema}:${manifest_count}:${receipt_schema}:${receipt_count}" == \
         '3:151:3:152' ]] ||
      fail "${implementation} Stage 2 fixture source discriminator changed"
    current_generation="${target}/${current_relative}"
    stage2_result="$(build_stage2_generation_fixture \
      "${current_generation}" "${target}/scripts/.cntools")" ||
      fail "could not build ${implementation} frozen Stage 2 generation"
    IFS=$'\t' read -r stage2_id stage2_lifecycle_hash extra <<< \
      "${stage2_result}"
    [[ -z "${extra}" && "${stage2_id}" =~ ^[0-9a-f]{64}$ &&
       "${stage2_lifecycle_hash}" =~ ^[0-9a-f]{64}$ ]] ||
      fail "${implementation} Stage 2 fixture identifiers were malformed"
    stage2_generation="${target}/scripts/.cntools/generations/${stage2_id}"
    stage2_staged="${transaction}/cntools-generation/${stage2_id}"
    jq -e '.schemaVersion == 2 and .moduleApiVersion == 1 and
      (has("moduleSchemaVersion") | not) and
      (.files | length == 29)' \
      "${stage2_generation}/cntools/manifest.json" >/dev/null ||
      fail "${implementation} Stage 2 manifest is not exact schema2/29"
    jq -e '.schemaVersion == 2 and (.files | length == 30)' \
      "${stage2_generation}/.generation.json" >/dev/null ||
      fail "${implementation} Stage 2 receipt is not exact schema2/30"
    "${BASH_UNDER_TEST}" -c '
      set -euo pipefail
      lifecycle=$1
      generation=$2
      id=$3
      # shellcheck source=/dev/null
      . "${lifecycle}"
      cntools_generation_validate "${generation}" "${id}"
    ' bash "${stage2_generation}/cntools/core/lifecycle.sh" \
      "${stage2_generation}" "${stage2_id}" ||
      fail "${implementation} Stage 2 generation is not lifecycle-exact"

    chmod 0600 "${validator}"
    cp -- "${stage2_generation}/cntools/core/lifecycle.sh" "${validator}"
    chmod 0400 "${validator}"
    assert_eq "$(sha256_file "${validator}")" "${stage2_lifecycle_hash}" \
      "${implementation} Stage 2 durable lifecycle hash"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${stage2_id}" "scripts/.cntools/generations/${stage2_id}" \
      "${root_existed}" "${generations_existed}" "${target_existed}" \
      "${stage2_lifecycle_hash}" > "${record}"
    chmod 0600 "${record}"
    field_count="$(awk -F '\t' 'NR == 1 { print NF }' "${record}")"
    [[ "${field_count}" == 6 ]] ||
      fail "${implementation} changed the frozen Stage 2 six-field record"

    chmod -R u+rwX "${current_generation}" "${stage2_generation}"
    rm -rf -- "${current_generation}" "${stage2_generation}"
    chmod -R u+rwX "${BUNDLE_FIXTURE_TARGET}"
    rm -rf -- "${BUNDLE_FIXTURE_TARGET}"
    [[ ! -e "${stage2_generation}" && ! -L "${stage2_generation}" &&
       ! -e "${stage2_staged}" && ! -L "${stage2_staged}" &&
       ! -e "${BUNDLE_FIXTURE_TARGET}" && ! -L "${BUNDLE_FIXTURE_TARGET}" &&
       ! -e "${BUNDLE_FIXTURE_STAGED}" && ! -L "${BUNDLE_FIXTURE_STAGED}" ]] ||
      fail "${implementation} could not prepare Stage 2 paired N:N state"
    assert_bundle_recovery_then_prejournal_stop \
      "${case_id}" "${target_name}" "${implementation}"
  done
}

test_stage3_generation_record_discriminator_rejections() {
  local variant="" manifest_schema="" manifest_count=""
  local receipt_schema="" receipt_count="" target_name="" target=""
  local transaction="" record="" before="" after=""
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" lifecycle_hash="" old_manifest_schema=""
  local old_manifest_count="" old_receipt_schema="" old_receipt_count=""
  local extra=""
  local -a cases=(
    'forged-count 3 150 3 152'
    'mixed-schema 3 151 2 30'
    'stripped-stage3 - - - -'
  )

  for variant in "${cases[@]}"; do
    read -r variant manifest_schema manifest_count receipt_schema \
      receipt_count <<< "${variant}"
    target_name="stage3_record_${variant//-/_}"
    prepare_fresh_bundle_publish_crash \
      "stage3-record-${variant}-crash" "${target_name}"
    target="${TARGET_PARENT}/${target_name}"
    transaction="${BUNDLE_FIXTURE_TRANSACTION}"
    record="${transaction}/cntools-generation.tsv"
    assert_stage3_generation_record "${record}" \
      "Stage 3 ${variant} source"
    IFS=$'\t' read -r id relative root_existed generations_existed \
      target_existed lifecycle_hash old_manifest_schema old_manifest_count \
      old_receipt_schema old_receipt_count extra < "${record}"
    [[ -z "${extra}" &&
       "${old_manifest_schema}:${old_manifest_count}:${old_receipt_schema}:${old_receipt_count}" == \
         '3:151:3:152' ]] ||
      fail "Stage 3 ${variant} fixture did not start from the exact record"
    if [[ "${variant}" == stripped-stage3 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${id}" "${relative}" "${root_existed}" "${generations_existed}" \
        "${target_existed}" "${lifecycle_hash}" > "${record}"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${id}" "${relative}" "${root_existed}" "${generations_existed}" \
        "${target_existed}" "${lifecycle_hash}" "${manifest_schema}" \
        "${manifest_count}" "${receipt_schema}" "${receipt_count}" > "${record}"
    fi
    chmod 0600 "${record}"
    before="${TEST_ROOT}/stage3-record-${variant}.before"
    after="${TEST_ROOT}/stage3-record-${variant}.after"
    target_tree_state "${target}" "${before}" Y
    expect_deploy_failure "stage3-record-${variant}-recovery" "${target_name}"
    assert_recovery_rejection_reached "Stage 3 ${variant} discriminator"
    target_tree_state "${target}" "${after}" Y
    cmp -s "${before}" "${after}" || {
      diff -u "${before}" "${after}" >&2 || true
      fail "Stage 3 ${variant} discriminator rejection mutated target state"
    }
    [[ -d "${transaction}" && ! -L "${transaction}" ]] ||
      fail "Stage 3 ${variant} rejection removed its durable transaction"
    assert_snapshot_cleanup
  done
}

find_single_transaction_quarantine() {
  local target="$1" cleanup_root=""
  local -a cleanup_roots=()

  while IFS= read -r cleanup_root; do
    cleanup_roots+=("${cleanup_root}")
  done < <(find "${target}" -mindepth 1 -maxdepth 1 \
    -name '.guild-deploy-transaction.cleanup.*' -print | LC_ALL=C sort)
  (( ${#cleanup_roots[@]} == 1 )) ||
    fail "expected one transaction quarantine under ${target}, found ${#cleanup_roots[@]}"
  printf '%s\n' "${cleanup_roots[0]}"
}

test_transaction_quarantine_committed_recovery() {
  local target_name='transaction_quarantine_committed'
  local target="${TARGET_PARENT}/${target_name}"
  local cleanup_root="" receipt_before="${TEST_ROOT}/quarantine-commit.receipt"
  local metadata_before="${TEST_ROOT}/quarantine-commit.metadata"
  local generation_id="" bundle_id="" generation="" bundle=""
  local primed_generation_id="" primed_bundle_id=""
  local staged_generation="" staged_bundle=""
  local generation_record="" bundle_record="" record_id="" relative=""
  local root_existed="" generations_existed="" cntools_existed=""
  local libs_existed="" legacy_existed="" target_existed=""
  local record_hash="" manifest_schema="" manifest_count=""
  local receipt_schema="" receipt_count="" extra=""
  local generation_before="${TEST_ROOT}/quarantine-commit.generation.before"
  local generation_after="${TEST_ROOT}/quarantine-commit.generation.after"
  local bundle_before="${TEST_ROOT}/quarantine-commit.bundle.before"
  local bundle_after="${TEST_ROOT}/quarantine-commit.bundle.after"
  local generation_link="${TEST_ROOT}/quarantine-commit.generation-hardlink"
  local bundle_link="${TEST_ROOT}/quarantine-commit.bundle-hardlink"
  local generation_link_before="" bundle_link_before=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${target}/.deployment.json" --arg service "${target_name}" \
    '.serviceName = $service'
  expect_deploy_success quarantine-committed-prime "${target_name}"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_receipt_metadata_coherent "${target}"
  primed_generation_id="$(jq -er '.cntoolsGeneration.id' \
    "${target}/.guild-source-receipt.json")"
  primed_bundle_id="$(jq -er '.legacyBundle.id' \
    "${target}/scripts/.cntools/generations/${primed_generation_id}/cntools/manifest.json")"
  if run_deploy quarantine-committed-crash "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-transaction-quarantine crash; then
    fail 'committed quarantine crash unexpectedly completed'
  fi
  assert_eq "${RUN_STATUS}" '137' 'committed quarantine crash status'
  [[ ! -e "${target}/.guild-deploy-transaction" &&
     ! -L "${target}/.guild-deploy-transaction" ]] ||
    fail 'committed quarantine crash retained the authoritative journal name'
  cleanup_root="$(find_single_transaction_quarantine "${target}")"
  generation_id="$(jq -er '.cntoolsGeneration.id' \
    "${target}/.guild-source-receipt.json")"
  assert_eq "${generation_id}" "${primed_generation_id}" \
    'same-ID committed quarantine generation identifier'
  generation="${target}/scripts/.cntools/generations/${generation_id}"
  bundle_id="$(jq -er '.legacyBundle.id' \
    "${generation}/cntools/manifest.json")"
  assert_eq "${bundle_id}" "${primed_bundle_id}" \
    'same-ID committed quarantine bundle identifier'
  bundle="${target}/scripts/cntools/libs/legacy/${bundle_id}"
  staged_generation="${cleanup_root}/cntools-generation/${generation_id}"
  staged_bundle="${cleanup_root}/cntools-legacy-bundle/${bundle_id}"
  generation_record="${cleanup_root}/cntools-generation.tsv"
  bundle_record="${cleanup_root}/cntools-legacy-bundle.tsv"
  assert_stage3_generation_record "${generation_record}" \
    'same-ID committed quarantine'
  IFS=$'\t' read -r record_id relative root_existed generations_existed \
    target_existed record_hash manifest_schema manifest_count receipt_schema \
    receipt_count extra < "${generation_record}"
  [[ -z "${extra}" && "${record_id}" == "${generation_id}" &&
     "${relative}" == "scripts/.cntools/generations/${generation_id}" &&
     "${root_existed}:${generations_existed}:${target_existed}" == 'Y:Y:Y' &&
     "${record_hash}" =~ ^[0-9a-f]{64}$ &&
     "${manifest_schema}:${manifest_count}:${receipt_schema}:${receipt_count}" == \
       '3:151:3:152' ]] ||
    fail 'same-ID committed quarantine generation record was inconsistent'
  IFS=$'\t' read -r record_id relative cntools_existed libs_existed \
    legacy_existed target_existed record_hash extra < "${bundle_record}"
  [[ -z "${extra}" && "${record_id}" == "${bundle_id}" &&
     "${relative}" == "scripts/cntools/libs/legacy/${bundle_id}" &&
     "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" == \
       'Y:Y:Y:Y' && "${record_hash}" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'same-ID committed quarantine bundle record was inconsistent'
  [[ -d "${staged_generation}" && ! -L "${staged_generation}" &&
     -d "${staged_bundle}" && ! -L "${staged_bundle}" ]] ||
    fail 'same-ID committed quarantine omitted immutable staged reuse trees'
  assert_eq "$(stat_mode "${staged_generation}")" '555' \
    'same-ID staged generation root mode'
  assert_eq "$(stat_mode "${staged_bundle}")" '555' \
    'same-ID staged bundle root mode'
  ln "${staged_generation}/cntools/core/lifecycle.sh" "${generation_link}"
  ln "${staged_bundle}/010-common-dialog.sh" "${bundle_link}"
  generation_link_before="$(stat_inode "${generation_link}"):$(
    stat_mtime "${generation_link}"):$(stat_mode "${generation_link}"):$(
    sha256_file "${generation_link}")"
  bundle_link_before="$(stat_inode "${bundle_link}"):$(
    stat_mtime "${bundle_link}"):$(stat_mode "${bundle_link}"):$(
    sha256_file "${bundle_link}")"
  generation_identity_state "${generation}" "${generation_before}"
  generation_identity_state "${bundle}" "${bundle_before}"
  cp -- "${target}/.guild-source-receipt.json" "${receipt_before}"
  cp -- "${target}/.deployment.json" "${metadata_before}"
  assert_receipt_metadata_coherent "${target}"
  assert_facade_loads "${target}" quarantine-committed

  # Completed quarantines are data-free cleanup work. Recovery must not parse
  # a record whose authority ended at the atomic rename.
  chmod 0600 "${cleanup_root}/journal"
  printf 'not-a-transaction-record\n' > "${cleanup_root}/journal"
  expect_deploy_success quarantine-committed-recovery "${target_name}"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  cmp -s "${receipt_before}" "${target}/.guild-source-receipt.json" ||
    fail 'committed quarantine recovery changed the authoritative receipt'
  cmp -s "${metadata_before}" "${target}/.deployment.json" ||
    fail 'committed quarantine recovery changed authoritative metadata'
  assert_eq "$(stat_inode "${generation_link}"):$(
      stat_mtime "${generation_link}"):$(stat_mode "${generation_link}"):$(
      sha256_file "${generation_link}")" "${generation_link_before}" \
    'same-ID generation hardlink identity/mode/bytes after cleanup'
  assert_eq "$(stat_inode "${bundle_link}"):$(
      stat_mtime "${bundle_link}"):$(stat_mode "${bundle_link}"):$(
      sha256_file "${bundle_link}")" "${bundle_link_before}" \
    'same-ID bundle hardlink identity/mode/bytes after cleanup'
  generation_identity_state "${generation}" "${generation_after}"
  generation_identity_state "${bundle}" "${bundle_after}"
  cmp -s "${generation_before}" "${generation_after}" ||
    fail 'same-ID quarantine cleanup changed public generation identity'
  cmp -s "${bundle_before}" "${bundle_after}" ||
    fail 'same-ID quarantine cleanup changed public bundle identity'
  assert_facade_loads "${target}" quarantine-committed-recovered
}

test_transaction_quarantine_rollback_recovery() {
  local target_name='transaction_quarantine_rollback'
  local target="${TARGET_PARENT}/${target_name}"
  local monolith="${target}/scripts/cntools.library"
  local legacy_cnode="${target}/scripts/cnode.sh"
  local source_facade="${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library"
  local transaction="${target}/.guild-deploy-transaction"
  local cleanup_root="" baseline="${TEST_ROOT}/quarantine-rollback.baseline"
  local after="${TEST_ROOT}/quarantine-rollback.after"

  mkdir -p -- "${target}/files" "${target}/db" "${target}/guild-db" \
    "${target}/logs" "${target}/scripts/adapters" \
    "${target}/scripts/archive" "${target}/scripts/lib" \
    "${target}/sockets" "${target}/priv" \
    "${target}/mithril/data-stores"
  chmod 0750 "${target}/priv"
  cp -- "${SOURCE_REPO}/scripts/cnode-helper-scripts/cnode.sh" \
    "${legacy_cnode}"
  chmod 0755 "${legacy_cnode}"
  reconstruct_source_legacy_monolith "${monolith}" ||
    fail 'could not prepare rollback-quarantine legacy facade'
  chmod 0644 "${monolith}"
  target_tree_state "${target}" "${baseline}"

  if run_deploy quarantine-rollback-interrupted "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-payload:1 crash; then
    fail 'rollback-quarantine interrupted activation unexpectedly completed'
  fi
  assert_eq "${RUN_STATUS}" '137' \
    'rollback quarantine interrupted activation status'
  [[ -d "${transaction}" && ! -L "${transaction}" ]] ||
    fail 'rollback-quarantine interrupted activation omitted its journal'
  assert_eq "$(sha256_file "${monolith}")" \
    "$(sha256_file "${source_facade}")" \
    'rollback quarantine interrupted split facade'
  assert_facade_refuses_transaction "${target}" quarantine-rollback-interrupted

  if run_deploy quarantine-rollback-crash "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-transaction-quarantine crash; then
    fail 'rollback-complete quarantine crash unexpectedly completed'
  fi
  assert_eq "${RUN_STATUS}" '137' 'rollback quarantine crash status'
  [[ ! -e "${target}/.guild-deploy-transaction" &&
     ! -L "${target}/.guild-deploy-transaction" ]] ||
    fail 'rollback quarantine crash retained the authoritative journal name'
  cleanup_root="$(find_single_transaction_quarantine "${target}")"
  assert_eq "$(sha256_file "${monolith}")" \
    '92e800f58948a570da401bef431d6e2449f25b337138f242ab3eeb48b0cf162b' \
    'rollback quarantine restored facade'
  assert_legacy_monolith_loads "${monolith}" quarantine-rollback
  chmod 0600 "${cleanup_root}/journal"
  printf 'mutated-after-rollback\n' > "${cleanup_root}/journal"

  if run_deploy quarantine-rollback-recovery "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return; then
    fail 'rollback quarantine recovery pre-journal stop unexpectedly succeeded'
  fi
  grep -Fq "transaction failpoint 'before-durable-journal'" "${RUN_OUTPUT}" ||
    fail 'rollback quarantine recovery did not reach the new transaction boundary'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  target_tree_state "${target}" "${after}"
  cmp -s "${baseline}" "${after}" || {
    diff -u "${baseline}" "${after}" >&2 || true
    fail 'rollback quarantine recovery did not preserve the restored baseline'
  }
  assert_legacy_monolith_loads "${monolith}" quarantine-rollback-recovered
}

test_transaction_quarantine_path_rejections() {
  local kind="" target_name="" target="" cleanup_root="" external=""
  local before="" after="" external_before="" external_after=""

  for kind in malformed symlink; do
    target_name="transaction_quarantine_${kind}"
    target="${TARGET_PARENT}/${target_name}"
    copy_target "${TARGET_PARENT}/fresh" "${target}"
    atomic_jq_update "${target}/.deployment.json" --arg service "${target_name}" \
      '.serviceName = $service'
    if [[ "${kind}" == 'malformed' ]]; then
      cleanup_root="${target}/.guild-deploy-transaction.cleanup.invalid"
      mkdir -- "${cleanup_root}"
      printf 'do-not-traverse\n' > "${cleanup_root}/sentinel"
    else
      external="${TEST_ROOT}/quarantine-symlink-external"
      mkdir -- "${external}"
      printf 'do-not-touch\n' > "${external}/sentinel"
      cleanup_root="${target}/.guild-deploy-transaction.cleanup.1.2.3"
      ln -s "${external}" "${cleanup_root}"
      target_tree_state "${external}" "${TEST_ROOT}/${kind}.external.before" Y
    fi
    before="${TEST_ROOT}/${kind}.quarantine.before"
    after="${TEST_ROOT}/${kind}.quarantine.after"
    target_tree_state "${target}" "${before}" Y
    expect_deploy_failure "quarantine-${kind}-refusal" "${target_name}"
    target_tree_state "${target}" "${after}" Y
    cmp -s "${before}" "${after}" || {
      diff -u "${before}" "${after}" >&2 || true
      fail "${kind} transaction quarantine refusal mutated the target"
    }
    if [[ "${kind}" == 'symlink' ]]; then
      external_before="${TEST_ROOT}/${kind}.external.before"
      external_after="${TEST_ROOT}/${kind}.external.after"
      target_tree_state "${external}" "${external_after}" Y
      cmp -s "${external_before}" "${external_after}" ||
        fail 'transaction quarantine symlink refusal touched the external tree'
    fi
    assert_snapshot_cleanup
  done
}

test_transaction_quarantine_recovery() {
  test_transaction_quarantine_committed_recovery
  test_transaction_quarantine_rollback_recovery
  test_transaction_quarantine_path_rejections
}

prepare_existing_bundle_publish_crash() {
  local case_id="$1" target_name="$2"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local record="${transaction}/cntools-legacy-bundle.tsv"
  local id="" relative="" cntools_existed="" libs_existed=""
  local legacy_existed="" target_existed="" manifest_sha="" extra=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${target}/.deployment.json" --arg service "${target_name}" \
    '.serviceName = $service'
  if run_deploy "${case_id}" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-cntools-legacy-bundle-publish crash; then
    fail "${case_id} existing-bundle crash unexpectedly succeeded"
  fi
  assert_eq "${RUN_STATUS}" '137' "${case_id} existing-bundle crash status"
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${record}" && ! -L "${record}" ]] ||
    fail "${case_id} existing-bundle crash omitted its durable record"
  IFS=$'\t' read -r id relative cntools_existed libs_existed \
    legacy_existed target_existed manifest_sha extra < "${record}"
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/cntools/libs/legacy/${id}" &&
     "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" == \
       'Y:Y:Y:Y' && "${manifest_sha}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "${case_id} did not record an authoritative existing bundle"
  BUNDLE_FIXTURE_TARGET="${target}/${relative}"
  BUNDLE_FIXTURE_TRANSACTION="${transaction}"
}

test_existing_bundle_recovery() {
  local target_name='existing_bundle_exact'
  local target="${TARGET_PARENT}/${target_name}"
  local member="" receipt_before="" metadata_before=""

  prepare_existing_bundle_publish_crash existing-bundle-exact-crash \
    "${target_name}"
  expect_deploy_success existing-bundle-exact-recovery "${target_name}"
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail 'exact existing bundle recovery was not reported'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_fresh_payload_consistency "${target}"

  target_name='existing_bundle_tampered'
  target="${TARGET_PARENT}/${target_name}"
  prepare_existing_bundle_publish_crash existing-bundle-tamper-crash \
    "${target_name}"
  receipt_before="${TEST_ROOT}/existing-bundle-tamper.receipt"
  metadata_before="${TEST_ROOT}/existing-bundle-tamper.metadata"
  cp -- "${target}/.guild-source-receipt.json" "${receipt_before}"
  cp -- "${target}/.deployment.json" "${metadata_before}"
  member="${BUNDLE_FIXTURE_TARGET}/010-common-dialog.sh"
  chmod 0644 "${member}"
  printf '\n# interrupted-target tamper\n' >> "${member}"
  expect_deploy_failure existing-bundle-tamper-recovery "${target_name}"
  [[ -d "${BUNDLE_FIXTURE_TRANSACTION}" &&
     ! -L "${BUNDLE_FIXTURE_TRANSACTION}" ]] ||
    fail 'tampered existing bundle recovery removed the durable journal'
  cmp -s "${receipt_before}" "${target}/.guild-source-receipt.json" ||
    fail 'tampered existing bundle recovery changed the authoritative receipt'
  cmp -s "${metadata_before}" "${target}/.deployment.json" ||
    fail 'tampered existing bundle recovery changed authoritative metadata'
  grep -Fq '# interrupted-target tamper' "${member}" ||
    fail 'tampered existing bundle recovery rewrote the suspect member'
  assert_snapshot_cleanup
}

test_forged_durable_bundle_manifest_rejection() {
  local case_id='forged-one-member-bundle'
  local target_name='forged_one_member_bundle'
  local target="${TARGET_PARENT}/${target_name}"
  local data_manifest="" record="" record_prefix="" manifest_hash=""
  local member="" before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"

  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  data_manifest="${BUNDLE_FIXTURE_TRANSACTION}/cntools-legacy-bundle-manifest.json"
  record="${BUNDLE_FIXTURE_TRANSACTION}/cntools-legacy-bundle.tsv"
  chmod 0600 "${data_manifest}"
  atomic_jq_update "${data_manifest}" \
    '.legacyBundle.members = [.legacyBundle.members[0]]'
  chmod 0400 "${data_manifest}"
  manifest_hash="$(sha256_file "${data_manifest}")"
  record_prefix="$(awk -F '\t' 'BEGIN { OFS="\t" }
    { print $1,$2,$3,$4,$5,$6 }' "${record}")"
  printf '%s\t%s\n' "${record_prefix}" "${manifest_hash}" > "${record}"
  chmod 0600 "${record}"
  chmod 0755 "${BUNDLE_FIXTURE_TARGET}"
  while IFS= read -r member; do
    [[ "${member}" == '010-common-dialog.sh' ]] ||
      rm -f -- "${BUNDLE_FIXTURE_TARGET}/${member}"
  done < <(find "${BUNDLE_FIXTURE_TARGET}" -mindepth 1 -maxdepth 1 \
    -type f -exec basename {} \; | LC_ALL=C sort)
  chmod 0555 "${BUNDLE_FIXTURE_TARGET}"
  target_tree_state "${target}" "${before}" Y
  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  assert_recovery_rejection_reached "forged one-member bundle"
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'forged one-member durable bundle was touched before rejection'
  }
  [[ -d "${BUNDLE_FIXTURE_TRANSACTION}" ]] ||
    fail 'forged one-member durable bundle rejection removed the journal'
  assert_snapshot_cleanup
}

corrupt_final_transaction_path() {
  local file="$1"
  local empty_row="$2"
  local staged="${file}.stage2.$$"

  if [[ -s "${file}" ]]; then
    awk -v replacement='../stage2-invalid-path' '
      BEGIN { FS=OFS="\t" }
      { row[NR]=$0 }
      END {
        if (NR == 0) exit 2
        $0=row[NR]
        $1=replacement
        row[NR]=$0
        for (i=1; i<=NR; i++) print row[i]
      }
    ' "${file}" > "${staged}" || {
      rm -f -- "${staged}"
      return 1
    }
  else
    printf '%s\n' "${empty_row}" > "${staged}" || return 1
  fi
  chmod 0600 "${staged}" && mv -f -- "${staged}" "${file}"
}

test_rollback_control_preflight_rejection_case() {
  local control="$1"
  local case_id="rollback-control-${control}"
  local target_name="rollback_control_${control}"
  local target="${TARGET_PARENT}/${target_name}"
  local control_file=""
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"

  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  control_file="${BUNDLE_FIXTURE_TRANSACTION}/${control}.tsv"
  [[ -f "${control_file}" && ! -L "${control_file}" ]] ||
    fail "${control} rollback control was not durable"
  case "${control}" in
    baseline)
      corrupt_final_transaction_path "${control_file}" \
        $'../stage2-invalid-path\tN\t-\t-' ||
        fail 'could not corrupt the final baseline control row'
      ;;
    activation)
      corrupt_final_transaction_path "${control_file}" \
        $'../stage2-invalid-path\t/tmp/.guild-deploy-invalid' ||
        fail 'could not corrupt the final activation control row'
      ;;
    *) fail "unsupported rollback control: ${control}" ;;
  esac

  [[ ! -e "${target}/.guild-source-receipt.json" &&
     ! -L "${target}/.guild-source-receipt.json" &&
     ! -e "${target}/.deployment.json" &&
     ! -L "${target}/.deployment.json" ]] ||
    fail "${control} preflight fixture unexpectedly had authoritative metadata"
  target_tree_state "${target}" "${before}" Y
  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  assert_recovery_rejection_reached "${control} rollback control"
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail "${control} rollback control rejection mutated the interrupted tree"
  }
  [[ -d "${BUNDLE_FIXTURE_TRANSACTION}" &&
     ! -L "${BUNDLE_FIXTURE_TRANSACTION}" &&
     -d "${BUNDLE_FIXTURE_TARGET}" &&
     ! -L "${BUNDLE_FIXTURE_TARGET}" ]] ||
    fail "${control} rollback control rejection removed durable recovery state"
  [[ ! -e "${target}/.guild-source-receipt.json" &&
     ! -e "${target}/.deployment.json" ]] ||
    fail "${control} rollback control rejection published authority"
  assert_snapshot_cleanup
}

test_rollback_control_preflight_rejections() {
  test_rollback_control_preflight_rejection_case baseline
  test_rollback_control_preflight_rejection_case activation
}

test_imported_generation_validator_never_executes() {
  local case_id='imported-generation-validator'
  local target_name='imported_generation_validator'
  local sentinel="${TEST_ROOT}/${case_id}.executed"

  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  RUN_IMPORTED_GENERATION_VALIDATOR_SENTINEL="${sentinel}"
  assert_bundle_recovery_then_prejournal_stop "${case_id}" "${target_name}"
  RUN_IMPORTED_GENERATION_VALIDATOR_SENTINEL=""
  [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
    fail 'interrupted recovery executed an imported generation validator'
}

test_damaged_modular_journal_cannot_masquerade_as_stage0() {
  local case_id='damaged-modular-special-controls'
  local target_name='damaged_modular_special_controls'
  local target="${TARGET_PARENT}/${target_name}"
  local transaction=""
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"

  prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
  transaction="${BUNDLE_FIXTURE_TRANSACTION}"
  chmod -R u+rwX "${transaction}/cntools-generation" \
    "${transaction}/cntools-legacy-bundle"
  rm -rf -- "${transaction}/cntools-generation" \
    "${transaction}/cntools-legacy-bundle"
  rm -f -- "${transaction}/cntools-generation.tsv" \
    "${transaction}/cntools-generation-validator.sh" \
    "${transaction}/cntools-legacy-bundle.tsv" \
    "${transaction}/cntools-legacy-bundle-manifest.json"
  target_tree_state "${target}" "${before}" Y
  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  assert_recovery_rejection_reached 'damaged modular journal'
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'damaged modular journal rejection mutated the interrupted target'
  }
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -d "${BUNDLE_FIXTURE_TARGET}" && ! -L "${BUNDLE_FIXTURE_TARGET}" ]] ||
    fail 'damaged modular journal rejection removed public recovery evidence'
  assert_snapshot_cleanup
}

test_ordinary_target_ancestor_symlink_rejection() {
  local case_id='ordinary-target-ancestor-symlink'
  local target_name='ordinary_target_ancestor_symlink'
  local target="${TARGET_PARENT}/${target_name}"
  local ancestor="${target}/files"
  local external="${TEST_ROOT}/${case_id}.external"
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"
  local external_before="${TEST_ROOT}/${case_id}.external.before"
  local external_after="${TEST_ROOT}/${case_id}.external.after"
  local link_target=""

  prepare_existing_bundle_publish_crash "${case_id}" "${target_name}"
  [[ -d "${ancestor}" && ! -L "${ancestor}" ]] ||
    fail 'ordinary target ancestor fixture omitted files/'
  mv -- "${ancestor}" "${external}"
  ln -s "${external}" "${ancestor}"
  link_target="$(readlink "${ancestor}")"
  target_tree_state "${external}" "${external_before}" Y
  target_tree_state "${target}" "${before}" Y

  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  assert_recovery_rejection_reached 'ordinary target ancestor symlink'
  [[ -L "${ancestor}" && "$(readlink "${ancestor}")" == "${link_target}" ]] ||
    fail 'ordinary target ancestor symlink changed during refusal'
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'ordinary target ancestor rejection mutated the interrupted tree'
  }
  target_tree_state "${external}" "${external_after}" Y
  cmp -s "${external_before}" "${external_after}" || {
    diff -u "${external_before}" "${external_after}" >&2 || true
    fail 'ordinary target ancestor rejection touched the external tree'
  }
  [[ -d "${BUNDLE_FIXTURE_TRANSACTION}" &&
     ! -L "${BUNDLE_FIXTURE_TRANSACTION}" ]] ||
    fail 'ordinary target ancestor rejection removed the durable journal'
  assert_facade_refuses_transaction "${target}" "${case_id}"
  assert_snapshot_cleanup
}

test_missing_existing_target_parent_rejection() {
  local case_id='missing-existing-target-parent'
  local target_name='missing_existing_target_parent'
  local target="${TARGET_PARENT}/${target_name}"
  local ancestor="${target}/files"
  local moved="${TEST_ROOT}/${case_id}.moved"
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"
  local moved_before="${TEST_ROOT}/${case_id}.moved.before"
  local moved_after="${TEST_ROOT}/${case_id}.moved.after"

  prepare_existing_bundle_publish_crash "${case_id}" "${target_name}"
  [[ -d "${ancestor}" && ! -L "${ancestor}" ]] ||
    fail 'missing-parent fixture omitted its existing files/ ancestor'
  mv -- "${ancestor}" "${moved}"
  target_tree_state "${moved}" "${moved_before}" Y
  target_tree_state "${target}" "${before}" Y
  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  assert_recovery_rejection_reached 'missing existing target parent'
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'missing existing target parent rejection mutated the target'
  }
  target_tree_state "${moved}" "${moved_after}" Y
  cmp -s "${moved_before}" "${moved_after}" || {
    diff -u "${moved_before}" "${moved_after}" >&2 || true
    fail 'missing existing target parent rejection touched the moved tree'
  }
  [[ ! -e "${ancestor}" && ! -L "${ancestor}" &&
     -d "${BUNDLE_FIXTURE_TRANSACTION}" &&
     ! -L "${BUNDLE_FIXTURE_TRANSACTION}" ]] ||
    fail 'missing existing target parent rejection changed recovery state'
  assert_facade_refuses_transaction "${target}" "${case_id}"
  assert_snapshot_cleanup
}

prepare_partial_payload_crash() {
  local case_id="$1" target_name="$2"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${target}/.deployment.json" --arg service "${target_name}" \
    '.serviceName = $service'
  if run_deploy "${case_id}" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-payload:1 crash; then
    fail "${case_id} partial-payload crash unexpectedly succeeded"
  fi
  assert_eq "${RUN_STATUS}" '137' "${case_id} partial-payload crash status"
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${transaction}/journal" && ! -L "${transaction}/journal" ]] ||
    fail "${case_id} partial-payload crash omitted its durable journal"
  PARTIAL_FIXTURE_TARGET="${target}"
  PARTIAL_FIXTURE_TRANSACTION="${transaction}"
}

advance_source_facade_payload() {
  local label="$1"
  local facade="${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library"
  local manifest="${SOURCE_REPO}/scripts/common-helper-scripts/cntools/manifest.json"
  local facade_sha=""

  printf '\n# Stage 2 committed-auth fixture: %s.\n' "${label}" >> "${facade}"
  "${BASH_UNDER_TEST}" -n "${facade}" || return 2
  facade_sha="$(sha256_file "${facade}")" || return 2
  atomic_jq_update "${manifest}" --arg hash "${facade_sha}" '
    (.files[] | select(.path == "cntools.library") | .sha256) = $hash
  ' || return 2
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")" || return 2
}

test_committed_journal_forgery_case() {
  local variant="$1"
  local case_id="committed-journal-forgery-${variant}"
  local target_name="committed_journal_forgery_${variant//-/_}"
  local journal="" transaction_id=""
  local receipt_before="${TEST_ROOT}/${case_id}.receipt"
  local metadata_before="${TEST_ROOT}/${case_id}.metadata"
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"

  if [[ "${variant}" == 'old-authority' ]]; then
    advance_source_facade_payload "${variant}" ||
      fail "${variant} could not advance the first ordinary payload"
  fi
  prepare_partial_payload_crash "${case_id}" "${target_name}"
  journal="${PARTIAL_FIXTURE_TRANSACTION}/journal"
  transaction_id="$(sed -n 's/^transactionId=//p' "${journal}")"
  case "${variant}" in
    exact)
      [[ "${transaction_id}" =~ ^[0-9]{1,20}\.[0-9]{1,20}\.[0-9]{1,5}$ ]] ||
        fail 'exact committed forgery lacked a strict prepared identifier'
      printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
        "${transaction_id}" > "${journal}"
      ;;
    appended)
      [[ "${transaction_id}" =~ ^[0-9]{1,20}\.[0-9]{1,20}\.[0-9]{1,5}$ ]] ||
        fail 'appended committed forgery lacked a strict prepared identifier'
      printf 'state=committed\n' >> "${journal}"
      ;;
    old-authority)
      transaction_id="$(jq -er '.transactionId' \
        "${PARTIAL_FIXTURE_TARGET}/.deployment.json")"
      [[ "${transaction_id}" =~ ^[0-9a-f]{24}$ ]] ||
        fail 'old-authority forgery lacked a strict authority identifier'
      cp -- "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json" \
        "${PARTIAL_FIXTURE_TRANSACTION}/receipt.candidate.json"
      cp -- "${PARTIAL_FIXTURE_TARGET}/.deployment.json" \
        "${PARTIAL_FIXTURE_TRANSACTION}/deployment.candidate.json"
      chmod 0644 \
        "${PARTIAL_FIXTURE_TRANSACTION}/receipt.candidate.json" \
        "${PARTIAL_FIXTURE_TRANSACTION}/deployment.candidate.json"
      printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
        "${transaction_id}" > "${journal}"
      ;;
    provenance)
      atomic_jq_update \
        "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json" \
        '.source.repository = "other-community/guild-operators"'
      transaction_id="$(sha256_file \
        "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json")"
      transaction_id="${transaction_id:0:24}"
      atomic_jq_update "${PARTIAL_FIXTURE_TARGET}/.deployment.json" \
        --arg receipt_hash "$(sha256_file \
          "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json")" \
        --arg transaction_id "${transaction_id}" '
          .payloadReceiptSha256 = $receipt_hash |
          .transactionId = $transaction_id
        '
      chmod 0644 \
        "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json" \
        "${PARTIAL_FIXTURE_TARGET}/.deployment.json"
      cp -- "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json" \
        "${PARTIAL_FIXTURE_TRANSACTION}/receipt.candidate.json"
      cp -- "${PARTIAL_FIXTURE_TARGET}/.deployment.json" \
        "${PARTIAL_FIXTURE_TRANSACTION}/deployment.candidate.json"
      chmod 0644 \
        "${PARTIAL_FIXTURE_TRANSACTION}/receipt.candidate.json" \
        "${PARTIAL_FIXTURE_TRANSACTION}/deployment.candidate.json"
      printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
        "${transaction_id}" > "${journal}"
      ;;
    *) fail "unsupported committed-journal forgery variant: ${variant}" ;;
  esac
  chmod 0600 "${journal}"
  cp -- "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json" \
    "${receipt_before}"
  cp -- "${PARTIAL_FIXTURE_TARGET}/.deployment.json" "${metadata_before}"
  assert_facade_refuses_transaction "${PARTIAL_FIXTURE_TARGET}" \
    "${case_id}-before"
  target_tree_state "${PARTIAL_FIXTURE_TARGET}" "${before}" Y

  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  assert_recovery_rejection_reached "${variant} committed-journal forgery"
  target_tree_state "${PARTIAL_FIXTURE_TARGET}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail "${variant} committed-journal forgery mutated the partial tree"
  }
  cmp -s "${receipt_before}" \
    "${PARTIAL_FIXTURE_TARGET}/.guild-source-receipt.json" ||
    fail "${variant} committed-journal forgery changed authoritative receipt"
  cmp -s "${metadata_before}" "${PARTIAL_FIXTURE_TARGET}/.deployment.json" ||
    fail "${variant} committed-journal forgery changed authoritative metadata"
  [[ -d "${PARTIAL_FIXTURE_TRANSACTION}" &&
     ! -L "${PARTIAL_FIXTURE_TRANSACTION}" ]] ||
    fail "${variant} committed-journal forgery removed the durable journal"
  assert_facade_refuses_transaction "${PARTIAL_FIXTURE_TARGET}" \
    "${case_id}-after"
  assert_snapshot_cleanup
}

test_committed_journal_forgery_rejections() {
  test_committed_journal_forgery_case exact
  test_committed_journal_forgery_case appended
  test_committed_journal_forgery_case old-authority
  test_committed_journal_forgery_case provenance
}

assert_metadata_publish_crash_recovery() {
  local shape="$1"
  local case_id="metadata-publish-${shape}"
  local target_name="metadata_publish_${shape//-/_}"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local baseline="${TEST_ROOT}/${case_id}.baseline"
  local after="${TEST_ROOT}/${case_id}.after"
  local old_receipt_hash='' old_metadata_hash=''

  case "${shape}" in
    first-install)
      seed_cnode_profile_directory_skeleton "${target}"
      ;;
    upgrade)
      copy_target "${TARGET_PARENT}/fresh" "${target}"
      atomic_jq_update "${target}/.deployment.json" \
        --arg service "${target_name}" '.serviceName = $service'
      old_receipt_hash="$(sha256_file \
        "${target}/.guild-source-receipt.json")"
      old_metadata_hash="$(sha256_file "${target}/.deployment.json")"
      advance_source_facade_payload "${case_id}" ||
        fail 'could not advance the metadata-publish upgrade payload'
      ;;
    *) fail "unsupported metadata-publish recovery shape: ${shape}" ;;
  esac
  target_tree_state "${target}" "${baseline}"

  if run_deploy "${case_id}-crash" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-metadata-publish crash; then
    fail "${shape} metadata-publish crash unexpectedly succeeded"
  fi
  assert_eq "${RUN_STATUS}" '137' \
    "${shape} metadata-publish crash status"
  grep -Fq "transaction failpoint 'after-metadata-publish'" "${RUN_OUTPUT}" ||
    fail "${shape} metadata-publish failpoint was not reached"
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${target}/.guild-source-receipt.json" &&
     -f "${target}/.deployment.json" ]] ||
    fail "${shape} metadata-publish crash omitted durable recovery state"
  if [[ "${shape}" == 'upgrade' ]]; then
    [[ "$(sha256_file "${target}/.guild-source-receipt.json")" != \
         "${old_receipt_hash}" &&
       "$(sha256_file "${target}/.deployment.json")" != \
         "${old_metadata_hash}" ]] ||
      fail 'upgrade metadata-publish crash did not publish new authority'
  fi

  if run_deploy "${case_id}-recovery" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return; then
    fail "${shape} metadata recovery pre-journal stop unexpectedly succeeded"
  fi
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail "${shape} metadata-publish recovery was not reported"
  grep -Fq "transaction failpoint 'before-durable-journal'" "${RUN_OUTPUT}" ||
    fail "${shape} metadata recovery did not refresh the source handoff"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  if [[ "${shape}" == 'first-install' ]]; then
    assert_first_install_rollback_skeleton "${target}" \
      'first-install metadata recovery'
    [[ ! -e "${target}/.guild-source-receipt.json" &&
       ! -e "${target}/.deployment.json" ]] ||
      fail 'first-install metadata recovery retained new authority'
  else
    target_tree_state "${target}" "${after}"
    cmp -s "${baseline}" "${after}" || {
      diff -u "${baseline}" "${after}" >&2 || true
      fail 'upgrade metadata recovery did not restore prior authority'
    }
    assert_eq "$(sha256_file "${target}/.guild-source-receipt.json")" \
      "${old_receipt_hash}" 'upgrade metadata recovery receipt'
    assert_eq "$(sha256_file "${target}/.deployment.json")" \
      "${old_metadata_hash}" 'upgrade metadata recovery metadata'
  fi
}

test_metadata_publish_crash_recovery_handoff() {
  assert_metadata_publish_crash_recovery first-install
  assert_metadata_publish_crash_recovery upgrade
}

prepare_handoff_mutation_authority() {
  local case_id="$1" target="$2" revision_digit="$3"
  local candidate_root="${TEST_ROOT}/${case_id}.authority-b"
  local receipt="${candidate_root}/receipt.json"
  local metadata="${candidate_root}/metadata.json"
  local revision="" receipt_hash="" transaction_id=""

  [[ "${revision_digit}" =~ ^[1-9]$ ]] || return 2
  printf -v revision '%*s' 40 ''
  revision="${revision// /${revision_digit}}"
  mkdir -p -- "${candidate_root}"
  cp -- "${target}/.guild-source-receipt.json" "${receipt}"
  cp -- "${target}/.deployment.json" "${metadata}"
  atomic_jq_update "${receipt}" --arg revision "${revision}" \
    '.source.revision = $revision'
  receipt_hash="$(sha256_file "${receipt}")"
  transaction_id="${receipt_hash:0:24}"
  atomic_jq_update "${metadata}" --arg revision "${revision}" \
    --arg receipt_hash "${receipt_hash}" \
    --arg transaction_id "${transaction_id}" '
      .sourceRevision = $revision |
      .payloadReceiptSha256 = $receipt_hash |
      .transactionId = $transaction_id
    '
  chmod 0644 "${receipt}" "${metadata}"
  RUN_HANDOFF_MUTATION_TARGET="${target}"
  RUN_HANDOFF_MUTATION_RECEIPT="${receipt}"
  RUN_HANDOFF_MUTATION_METADATA="${metadata}"
  RUN_HANDOFF_MUTATION_TRANSACTION_ID="${transaction_id}"
}

reset_handoff_mutation_fixture() {
  RUN_HANDOFF_MUTATION_MODE=""
  RUN_HANDOFF_MUTATION_TARGET=""
  RUN_HANDOFF_MUTATION_RECEIPT=""
  RUN_HANDOFF_MUTATION_METADATA=""
  RUN_HANDOFF_MUTATION_TRANSACTION_ID=""
}

assert_handoff_journal_identity_race() {
  local variant="$1" digit="$2"
  local case_id="handoff-journal-${variant}"
  local target_name="handoff_journal_${variant//-/_}"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local old_transaction_id=""
  local scripts_before="${TEST_ROOT}/${case_id}.scripts.before"
  local scripts_after="${TEST_ROOT}/${case_id}.scripts.after"
  local files_before="${TEST_ROOT}/${case_id}.files.before"
  local files_after="${TEST_ROOT}/${case_id}.files.after"
  local expected_journal="${TEST_ROOT}/${case_id}.journal.expected"
  local mutation_marker="${TEST_ROOT}/runs/${case_id}/handoff-mutation.once"

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${target}/.deployment.json" \
    --arg service "${target_name}" '.serviceName = $service'
  case "${variant}" in
    no-journal)
      RUN_HANDOFF_MUTATION_MODE='no-journal'
      ;;
    admitted-a-to-b)
      old_transaction_id="$(jq -er '.transactionId' \
        "${target}/.deployment.json")"
      [[ "${old_transaction_id}" =~ ^[0-9a-f]{24}$ ]] ||
        fail 'admitted journal A transaction identifier was malformed'
      mkdir -m 0700 -- "${transaction}"
      cp -- "${target}/.guild-source-receipt.json" \
        "${transaction}/receipt.candidate.json"
      cp -- "${target}/.deployment.json" \
        "${transaction}/deployment.candidate.json"
      chmod 0644 "${transaction}/receipt.candidate.json" \
        "${transaction}/deployment.candidate.json"
      printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
        "${old_transaction_id}" > "${transaction}/journal"
      chmod 0600 "${transaction}/journal"
      RUN_HANDOFF_MUTATION_MODE='replace-journal'
      ;;
    *) fail "unsupported handoff journal race: ${variant}" ;;
  esac
  prepare_handoff_mutation_authority "${case_id}" "${target}" "${digit}" ||
    fail "${variant} could not build authority B"
  [[ "${RUN_HANDOFF_MUTATION_TRANSACTION_ID}" != \
     "${old_transaction_id:-not-present}" ]] ||
    fail "${variant} authority B reused journal A's identifier"
  target_tree_state "${target}/scripts" "${scripts_before}" Y
  target_tree_state "${target}/files" "${files_before}" Y

  expect_deploy_failure "${case_id}" "${target_name}"
  reset_handoff_mutation_fixture
  grep -Fq \
    'interrupted deployment journal changed during source preparation' \
    "${RUN_OUTPUT}" || {
      sed -n '1,120p' "${RUN_OUTPUT}" >&2 || true
      fail "${variant} did not reject the changed handoff journal"
    }
  ! grep -Fq 'Interrupted Guild payload transaction recovered' \
    "${RUN_OUTPUT}" ||
    fail "${variant} recovered an unadmitted journal"
  [[ -d "${mutation_marker}" && ! -L "${mutation_marker}" ]] ||
    fail "${variant} did not run the deterministic handoff mutation"
  printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
    "$(jq -er '.transactionId' \
      "${target}/.deployment.json")" > "${expected_journal}"
  cmp -s "${expected_journal}" "${transaction}/journal" ||
    fail "${variant} changed journal B after rejecting its token"
  cmp -s "${target}/.guild-source-receipt.json" \
    "${transaction}/receipt.candidate.json" ||
    fail "${variant} changed authority B's receipt candidate"
  cmp -s "${target}/.deployment.json" \
    "${transaction}/deployment.candidate.json" ||
    fail "${variant} changed authority B's metadata candidate"
  target_tree_state "${target}/scripts" "${scripts_after}" Y
  target_tree_state "${target}/files" "${files_after}" Y
  cmp -s "${scripts_before}" "${scripts_after}" ||
    fail "${variant} changed installed scripts before token rejection"
  cmp -s "${files_before}" "${files_after}" ||
    fail "${variant} changed installed files before token rejection"
  assert_snapshot_cleanup
}

test_handoff_journal_identity_races() {
  assert_handoff_journal_identity_race no-journal 7
  assert_handoff_journal_identity_race admitted-a-to-b 8
}

test_bundle_symlink_ancestor_rejections() {
  local ancestor_kind="" case_id="" target_name="" target=""
  local ancestor="" external="" external_before="" external_after=""
  local link_target=""

  for ancestor_kind in cntools libs legacy; do
    case_id="bundle-symlink-${ancestor_kind}"
    target_name="bundle_symlink_${ancestor_kind}"
    target="${TARGET_PARENT}/${target_name}"
    prepare_fresh_bundle_publish_crash "${case_id}" "${target_name}"
    case "${ancestor_kind}" in
      cntools) ancestor="${target}/scripts/cntools" ;;
      libs) ancestor="${target}/scripts/cntools/libs" ;;
      legacy) ancestor="${target}/scripts/cntools/libs/legacy" ;;
    esac
    external="${TEST_ROOT}/${case_id}.external"
    mv -- "${ancestor}" "${external}"
    ln -s "${external}" "${ancestor}"
    link_target="$(readlink "${ancestor}")"
    external_before="${TEST_ROOT}/${case_id}.external.before"
    external_after="${TEST_ROOT}/${case_id}.external.after"
    target_tree_state "${external}" "${external_before}" Y

    expect_deploy_failure "${case_id}-recovery" "${target_name}"
    [[ -L "${ancestor}" && "$(readlink "${ancestor}")" == "${link_target}" ]] ||
      fail "${ancestor_kind} bundle ancestor symlink changed during rejection"
    target_tree_state "${external}" "${external_after}" Y
    cmp -s "${external_before}" "${external_after}" || {
      diff -u "${external_before}" "${external_after}" >&2 || true
      fail "${ancestor_kind} bundle ancestor rejection touched external data"
    }
    [[ -d "${BUNDLE_FIXTURE_TRANSACTION}" &&
       ! -L "${BUNDLE_FIXTURE_TRANSACTION}" ]] ||
      fail "${ancestor_kind} bundle ancestor rejection removed the journal"
    [[ ! -e "${target}/.guild-source-receipt.json" &&
       ! -e "${target}/.deployment.json" ]] ||
      fail "${ancestor_kind} bundle ancestor rejection published authority"
    assert_snapshot_cleanup
  done
}

test_bundle_parent_interference_case() {
  local parent_kind="$1"
  local case_id="bundle-parent-interference-${parent_kind}"
  local target_name="bundle_parent_interference_${parent_kind}"
  local target="${TARGET_PARENT}/${target_name}"
  local monolith="${target}/scripts/cntools.library"
  local legacy_cnode="${target}/scripts/cnode.sh"
  local transaction="${target}/.guild-deploy-transaction"
  local data_manifest="${transaction}/cntools-legacy-bundle-manifest.json"
  local bundle_id="" staged="" parent="" interference="" member=""
  local baseline="${TEST_ROOT}/${case_id}.baseline"
  local after="${TEST_ROOT}/${case_id}.after"

  mkdir -p -- "${target}/files" "${target}/db" "${target}/guild-db" \
    "${target}/logs" "${target}/scripts/adapters" \
    "${target}/scripts/archive" "${target}/scripts/lib" \
    "${target}/sockets" "${target}/priv" \
    "${target}/mithril/data-stores"
  chmod 0750 "${target}/priv"
  cp -- "${SOURCE_REPO}/scripts/cnode-helper-scripts/cnode.sh" \
    "${legacy_cnode}"
  chmod 0755 "${legacy_cnode}"
  reconstruct_source_legacy_monolith "${monolith}" ||
    fail "${parent_kind} parent fixture could not reconstruct the monolith"
  chmod 0644 "${monolith}"
  target_tree_state "${target}" "${baseline}"
  if run_deploy "${case_id}-crash" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-payload:1 crash; then
    fail "${parent_kind} parent-interference crash unexpectedly succeeded"
  fi
  assert_eq "${RUN_STATUS}" '137' \
    "${parent_kind} parent-interference crash status"
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${data_manifest}" && ! -L "${data_manifest}" ]] ||
    fail "${parent_kind} parent-interference crash omitted the journal"
  assert_eq "$(sha256_file "${monolith}")" \
    "$(sha256_file "${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library")" \
    "${parent_kind} journal-aware facade activation"
  assert_facade_refuses_transaction "${target}" \
    "${parent_kind}-parent-before-rollback"
  bundle_id="$(jq -er '.legacyBundle.id' "${data_manifest}")"
  staged="${transaction}/cntools-legacy-bundle/${bundle_id}"
  case "${parent_kind}" in
    cntools) parent="${target}/scripts/cntools" ;;
    libs) parent="${target}/scripts/cntools/libs" ;;
    legacy) parent="${target}/scripts/cntools/libs/legacy" ;;
    *) fail "unsupported bundle parent interference kind: ${parent_kind}" ;;
  esac
  interference="${parent}/stage2-interference"
  printf 'operator interference\n' > "${interference}"
  if [[ "${parent_kind}" == 'legacy' ]]; then
    chmod 0755 "${target}/scripts/cntools/libs/legacy/${bundle_id}"
  fi
  while IFS= read -r member; do
    assert_eq "$(stat_mode \
      "${target}/scripts/cntools/libs/legacy/${bundle_id}/${member}")" '444' \
      "${parent_kind} pre-rollback bundle member mode"
  done < <(jq -er '.legacyBundle.members[].path' "${data_manifest}")

  expect_deploy_failure "${case_id}-blocked-recovery" "${target_name}"
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${interference}" && -d "${staged}" ]] ||
    fail "${parent_kind} parent interference did not preserve retry state"
  assert_eq "$(sha256_file "${monolith}")" \
    "$(sha256_file "${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library")" \
    "${parent_kind} deferred facade rollback"
  assert_facade_refuses_transaction "${target}" \
    "${parent_kind}-parent-blocked-rollback"
  rm -f -- "${interference}"
  if [[ "${parent_kind}" == 'libs' ]]; then
    chmod 0755 "${staged}"
  fi
  while IFS= read -r member; do
    assert_eq "$(stat_mode "${staged}/${member}")" '444' \
      "${parent_kind} staged retry member mode"
  done < <(jq -er '.legacyBundle.members[].path' "${data_manifest}")

  if run_deploy "${case_id}-recovery" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return; then
    fail "${parent_kind} recovery pre-journal stop unexpectedly succeeded"
  fi
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail "${parent_kind} parent cleanup retry was not reported"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  target_tree_state "${target}" "${after}"
  cmp -s "${baseline}" "${after}" || {
    diff -u "${baseline}" "${after}" >&2 || true
    fail "${parent_kind} parent cleanup retry did not restore the baseline"
  }
  assert_legacy_monolith_loads "${monolith}" \
    "${parent_kind}-parent-recovered"
}

test_bundle_parent_interference_recovery() {
  test_bundle_parent_interference_case legacy
  test_bundle_parent_interference_case libs
  test_bundle_parent_interference_case cntools
}

assert_prejournal_generation_rejection() {
  local target_name="$1"
  local sentinel="$2"
  local target="${TARGET_PARENT}/${target_name}"
  local before="${TEST_ROOT}/${target_name}.prejournal.before"
  local after="${TEST_ROOT}/${target_name}.prejournal.after"
  local receipt_before="${TEST_ROOT}/${target_name}.prejournal.receipt"
  local metadata_before="${TEST_ROOT}/${target_name}.prejournal.metadata"

  cp -- "${target}/.guild-source-receipt.json" "${receipt_before}"
  cp -- "${target}/.deployment.json" "${metadata_before}"
  target_tree_state "${target}" "${before}" Y
  expect_deploy_failure "${target_name}" "${target_name}"
  [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
    fail "${target_name} executed an unauthenticated generation member"
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail "${target_name} changed the target before durable journal creation"
  }
  cmp -s "${receipt_before}" "${target}/.guild-source-receipt.json" ||
    fail "${target_name} changed the authoritative receipt"
  cmp -s "${metadata_before}" "${target}/.deployment.json" ||
    fail "${target_name} changed authoritative metadata"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
}

prepare_pointer_validation_target() {
  local target_name="$1"
  local activate_candidate="$2"
  local target="${TARGET_PARENT}/${target_name}"
  local root="${target}/scripts/.cntools"
  local candidate_id=""
  local lifecycle=""

  copy_target "${TARGET_PARENT}/active_generation_upgrade" "${target}"
  atomic_jq_update "${target}/.deployment.json" --arg service "${target_name}" \
    '.serviceName = $service'
  if [[ "${activate_candidate}" == "Y" ]]; then
    candidate_id="$(jq -er '.cntoolsGeneration.id' \
      "${target}/.guild-source-receipt.json")"
    lifecycle="${root}/generations/${candidate_id}/cntools/core/lifecycle.sh"
    (
      # shellcheck source=/dev/null
      . "${lifecycle}"
      cntools_generation_activate "${root}" "${candidate_id}"
    ) || fail "could not prepare active B/previous A pointer fixture"
  fi
}

prepare_schema1_pointer_migration_target() {
  local target_name="$1"
  local target="${TARGET_PARENT}/${target_name}"
  local root="${target}/scripts/.cntools"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local generation_id=""
  local receipt_hash=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  generation_id="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  (
    # shellcheck source=/dev/null
    . "${root}/generations/${generation_id}/cntools/core/lifecycle.sh"
    cntools_generation_activate "${root}" "${generation_id}"
  ) || fail "could not activate schema 1 migration pointer fixture"
  atomic_jq_update "${receipt}" '.schemaVersion = 1 | del(.cntoolsGeneration)'
  rewrite_receipt_legacy_inventory_order "${receipt}" cnode ||
    fail "${target_name} schema 1 receipt did not retain historical order"
  receipt_hash="$(sha256_file "${receipt}")"
  atomic_jq_update "${metadata}" --arg service "${target_name}" \
    --arg hash "${receipt_hash}" '
      .serviceName = $service |
      .sourceSchemaVersion = 1 |
      .payloadReceiptSha256 = $hash |
      .transactionId = $hash[0:24]
    '
}

test_prior_generation_pointer_rejections() {
  local target_name=""
  local target=""
  local root=""
  local pointer=""
  local id=""
  local member=""
  local external=""
  local external_hash=""
  local sentinel=""

  for pointer in active previous; do
    target_name="unsafe_${pointer}_pointer"
    prepare_pointer_validation_target "${target_name}" \
      "$([[ "${pointer}" == "previous" ]] && printf Y || printf N)"
    target="${TARGET_PARENT}/${target_name}"
    root="${target}/scripts/.cntools"
    external="${TEST_ROOT}/${target_name}.external"
    sentinel="${external}/sentinel"
    mkdir -p -- "${external}"
    printf 'external pointer sentinel\n' > "${sentinel}"
    rm -- "${root}/${pointer}"
    ln -s "${external}" "${root}/${pointer}"
    external_hash="$(sha256_file "${sentinel}")"
    assert_prejournal_generation_rejection "${target_name}" \
      "${TEST_ROOT}/${target_name}.executed"
    assert_eq "$(sha256_file "${sentinel}")" "${external_hash}" \
      "${pointer} pointer external sentinel"
  done

  for pointer in active previous; do
    target_name="tampered_${pointer}_generation"
    prepare_pointer_validation_target "${target_name}" \
      "$([[ "${pointer}" == "previous" ]] && printf Y || printf N)"
    target="${TARGET_PARENT}/${target_name}"
    root="${target}/scripts/.cntools"
    id="$(readlink "${root}/${pointer}")"
    id="${id#generations/}"
    member="${root}/generations/${id}/cntools/core/lifecycle.sh"
    sentinel="${TEST_ROOT}/${target_name}.executed"
    chmod 0644 "${member}"
    printf '#!/usr/bin/env bash\nprintf executed > %q\n' "${sentinel}" > \
      "${member}"
    printf '%s\n' 'cntools_generation_validate() { return 2; }' >> "${member}"
    chmod 0444 "${member}"
    assert_prejournal_generation_rejection "${target_name}" "${sentinel}"
  done

  target_name="schema1_unsafe_active_pointer"
  prepare_schema1_pointer_migration_target "${target_name}"
  target="${TARGET_PARENT}/${target_name}"
  root="${target}/scripts/.cntools"
  external="${TEST_ROOT}/${target_name}.external"
  mkdir -p -- "${external}"
  printf 'schema 1 external sentinel\n' > "${external}/sentinel"
  external_hash="$(sha256_file "${external}/sentinel")"
  rm -- "${root}/active"
  ln -s "${external}" "${root}/active"
  assert_prejournal_generation_rejection "${target_name}" \
    "${TEST_ROOT}/${target_name}.executed"
  assert_eq "$(sha256_file "${external}/sentinel")" "${external_hash}" \
    'schema 1 unsafe active-pointer sentinel'

  target_name="schema1_tampered_active_generation"
  prepare_schema1_pointer_migration_target "${target_name}"
  target="${TARGET_PARENT}/${target_name}"
  root="${target}/scripts/.cntools"
  id="$(readlink "${root}/active")"
  id="${id#generations/}"
  member="${root}/generations/${id}/cntools/core/lifecycle.sh"
  sentinel="${TEST_ROOT}/${target_name}.executed"
  chmod 0644 "${member}"
  printf '#!/usr/bin/env bash\nprintf executed > %q\n' "${sentinel}" > \
    "${member}"
  printf '%s\n' 'cntools_generation_validate() { return 2; }' >> "${member}"
  chmod 0444 "${member}"
  assert_prejournal_generation_rejection "${target_name}" "${sentinel}"
}

prepare_stage0_plain_transaction() {
  local case_id="$1" target_name="$2" journal_state="$3"
  local implementation="${4:-cnode}"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local transaction_id="1700000000.424242.123"
  local facade="${target}/scripts/cntools.library"
  local target_dispatcher="${target}/scripts/guild-deploy.sh"

  mkdir -p -- "${target}/files" "${target}/scripts"
  cp -- "${DISPATCHER}" "${target_dispatcher}"
  chmod 0755 "${target_dispatcher}"
  reconstruct_source_legacy_monolith "${facade}" ||
    fail "${case_id} could not reconstruct the Stage 0 CNTools monolith"
  chmod 0644 "${facade}"
  case "${implementation}" in
    cnode)
      mkdir -p -- "${target}/db" "${target}/guild-db" "${target}/logs" \
        "${target}/scripts/adapters" "${target}/scripts/archive" \
        "${target}/scripts/lib" "${target}/sockets" "${target}/priv" \
        "${target}/mithril/data-stores"
      chmod 0750 "${target}/priv"
      cp -- "${SOURCE_REPO}/scripts/cnode-helper-scripts/cnode.sh" \
        "${target}/scripts/cnode.sh"
      chmod 0755 "${target}/scripts/cnode.sh"
      ;;
    dingo)
      mkdir -p -- "${target}/db" "${target}/logs" \
        "${target}/priv/pool" "${target}/snapshots" \
        "${target}/sockets" "${target}/scripts/adapters" \
        "${target}/scripts/archive" "${target}/scripts/lib"
      chmod 0700 "${target}/priv" "${target}/priv/pool"
      cp -- "${SOURCE_REPO}/scripts/dingo-helper-scripts/dingo.sh" \
        "${target}/scripts/dingo.sh"
      cp -- "${SOURCE_REPO}/files/configs/dingo/preview/dingo.env" \
        "${target}/scripts/dingo.env"
      chmod 0755 "${target}/scripts/dingo.sh"
      chmod 0640 "${target}/scripts/dingo.env"
      ;;
    *) fail "unsupported Stage 0 recovery implementation: ${implementation}" ;;
  esac
  target_tree_state "${target}" "${TEST_ROOT}/${case_id}.baseline"

  mkdir -m 0700 -- "${transaction}"
  cp -p -- "${target_dispatcher}" "${transaction}/backup.1"
  cp -p -- "${facade}" "${transaction}/backup.2"
  printf '%s\n' \
    $'scripts/guild-deploy.sh\tY\t0755\tbackup.1' \
    $'scripts/cntools.library\tY\t0644\tbackup.2' \
    > "${transaction}/baseline.tsv"
  printf '%s\n' \
    'scripts/guild-deploy.sh' \
    'scripts/cntools.library' \
    > "${transaction}/targets.tsv"
  : > "${transaction}/activation.tsv"
  case "${journal_state}" in
    prepared) ;;
    activated)
      printf '#!/usr/bin/env bash\n# interrupted Stage 0 dispatcher\n' > \
        "${target_dispatcher}"
      chmod 0755 "${target_dispatcher}"
      cp -- "${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library" \
        "${facade}"
      chmod 0644 "${facade}"
      printf '%s\t%s\n' \
        'scripts/guild-deploy.sh' \
        "${target}/scripts/.guild-deploy-${transaction_id}.1" \
        >> "${transaction}/activation.tsv"
      printf '%s\t%s\n' \
        'scripts/cntools.library' \
        "${target}/scripts/.guild-deploy-${transaction_id}.2" \
        >> "${transaction}/activation.tsv"
      ;;
    *) fail "unsupported Stage 0 transaction state: ${journal_state}" ;;
  esac
  printf 'schemaVersion=1\ntransactionId=%s\nstate=%s\n' \
    "${transaction_id}" "${journal_state}" > "${transaction}/journal"
  chmod 0600 "${transaction}/baseline.tsv" "${transaction}/targets.tsv" \
    "${transaction}/activation.tsv" "${transaction}/journal"
}

assert_stage0_plain_recovery() {
  local implementation="$1" journal_state="$2"
  local case_id="stage0-${implementation}-${journal_state}"
  local target_name="stage0_${implementation}_${journal_state}"
  local target="${TARGET_PARENT}/${target_name}"
  local after="${TEST_ROOT}/${case_id}.after"
  local fake_linux="N"

  [[ "${implementation}" == 'dingo' ]] && fake_linux="Y"
  prepare_stage0_plain_transaction "${case_id}" "${target_name}" \
    "${journal_state}" "${implementation}"
  if run_deploy "${case_id}-recovery" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" preview "${fake_linux}"; then
    fail "${case_id} recovery pre-journal stop unexpectedly succeeded"
  fi
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail "${case_id} did not report Stage 0 transaction recovery"
  grep -Fq "transaction failpoint 'before-durable-journal'" "${RUN_OUTPUT}" ||
    fail "${case_id} did not reach the fresh Stage 2 transaction boundary"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  target_tree_state "${target}" "${after}"
  cmp -s "${TEST_ROOT}/${case_id}.baseline" "${after}" || {
    diff -u "${TEST_ROOT}/${case_id}.baseline" "${after}" >&2 || true
    fail "${case_id} did not restore the exact Stage 0 baseline"
  }
  [[ ! -e "${target}/scripts/.cntools" &&
     ! -L "${target}/scripts/.cntools" ]] ||
    fail "${case_id} created a CNTools generation or recovery lock"
  assert_legacy_monolith_loads "${target}/scripts/cntools.library" "${case_id}"
}

test_stage0_plain_transaction_recovery() {
  local implementation="" journal_state=""

  for implementation in cnode dingo; do
    for journal_state in prepared activated; do
      assert_stage0_plain_recovery "${implementation}" "${journal_state}"
    done
  done
}

build_stage2_generation_fixture() {
  local source_generation="$1"
  local cntools_root="$2"
  local stage="${TEST_ROOT}/stage2-generation.$RANDOM"
  local manifest="${stage}/cntools/manifest.json"
  local receipt="${stage}/.generation.json"
  local root_module="${stage}/cntools/modules/root/module.json"
  local inventory="${TEST_ROOT}/stage2-generation.inventory.$RANDOM.json"
  local canonical="${TEST_ROOT}/stage2-generation.canonical.$RANDOM.tsv"
  local manifest_sha="" root_module_sha="" generation_id="" lifecycle_sha=""
  local destination="" path="" mode="" remaining_root_member=""

  [[ -d "${source_generation}" && ! -L "${source_generation}" ]] || return 2
  cp -R -- "${source_generation}" "${stage}" || return 2
  chmod -R u+rwX "${stage}" || return 2
  find "${stage}/cntools/modules/root" -mindepth 1 -maxdepth 1 \
    ! -name module.json \
    -exec rm -rf -- {} + || return 2
  remaining_root_member="$(find "${stage}/cntools/modules/root" \
    -mindepth 1 -maxdepth 1 -print)" || return 2
  [[ "${remaining_root_member}" == "${root_module}" &&
     -f "${root_module}" && ! -L "${root_module}" ]] || return 2
  atomic_jq_update "${root_module}" '
    .schemaVersion = 1 |
    del(.controlPolicy)
  ' || return 2
  root_module_sha="$(sha256_file "${root_module}")" || return 2
  atomic_jq_update "${manifest}" --arg root_module_sha "${root_module_sha}" '
    .schemaVersion = 2 |
    .moduleApiVersion = 1 |
    del(.moduleSchemaVersion) |
    .files |= map(select(
      (.path | startswith("cntools/modules/root/") | not) or
      .path == "cntools/modules/root/module.json"
    )) |
    (.files[] | select(.path == "cntools/modules/root/module.json") |
      .sha256) = $root_module_sha
  ' || return 2
  [[ "$(jq -er '.files | length' "${manifest}")" == 29 ]] || return 2
  manifest_sha="$(sha256_file "${manifest}")" || return 2
  jq --arg hash "${manifest_sha}" '
    [{
      path:"cntools/manifest.json",
      source:"scripts/common-helper-scripts/cntools/manifest.json",
      mode:"0444", validator:"json", sha256:$hash
    }] + .files | sort_by(.path)
  ' "${manifest}" > "${inventory}" || return 2
  [[ "$(jq -er 'length' "${inventory}")" == 30 ]] || return 2
  jq -r '.[] | [.path,.mode,.sha256] | @tsv' "${inventory}" > \
    "${canonical}" || return 2
  generation_id="$(sha256_file "${canonical}")" || return 2
  lifecycle_sha="$(jq -er '
    .[] | select(.path == "cntools/core/lifecycle.sh") | .sha256
  ' "${inventory}")" || return 2
  jq -n --arg id "${generation_id}" --arg manifest_sha "${manifest_sha}" \
    --slurpfile files "${inventory}" '{
      schemaVersion:2,
      id:$id,
      version:"13.5.7",
      generationIdAlgorithm:"sha256-path-mode-content-v1",
      payloadManifest:"cntools/manifest.json",
      payloadManifestSha256:$manifest_sha,
      files:$files[0]
    }' > "${receipt}" || return 2
  while IFS=$'\t' read -r path mode; do
    chmod "${mode}" "${stage}/${path}" || return 2
  done < <(jq -er '.[] | [.path,.mode] | @tsv' "${inventory}")
  chmod 0444 "${receipt}" || return 2
  mkdir -p -- "${cntools_root}/generations" || return 2
  chmod 0700 "${cntools_root}" "${cntools_root}/generations" || return 2
  destination="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 2
  mv -- "${stage}" "${destination}" || return 2
  find "${destination}" -depth -type d -exec chmod 0555 {} + || return 2
  printf '%s\t%s\n' "${generation_id}" "${lifecycle_sha}"
}

build_stage1_generation_fixture() {
  local cntools_root="$1"
  local source_receipt="${TARGET_PARENT}/fresh/.guild-source-receipt.json"
  local source_id="" source_generation="" stage=""
  local manifest="" receipt="" inventory="" canonical=""
  local monolith="" monolith_sha="" manifest_sha="" generation_id=""
  local lifecycle_sha="" root_module="" root_module_sha=""
  local destination="" path="" mode="" remaining_root_member=""

  source_id="$(jq -er '.cntoolsGeneration.id' "${source_receipt}")" || return 2
  source_generation="${TARGET_PARENT}/fresh/scripts/.cntools/generations/${source_id}"
  stage="${TEST_ROOT}/stage1-generation.$RANDOM"
  manifest="${stage}/cntools/manifest.json"
  receipt="${stage}/.generation.json"
  root_module="${stage}/cntools/modules/root/module.json"
  inventory="${TEST_ROOT}/stage1-generation.inventory.$RANDOM.json"
  canonical="${TEST_ROOT}/stage1-generation.canonical.$RANDOM.tsv"
  monolith="${TEST_ROOT}/stage1-generation.monolith.$RANDOM"
  cp -R -- "${source_generation}" "${stage}" || return 2
  chmod -R u+rwX "${stage}" || return 2
  reconstruct_source_legacy_monolith "${monolith}" || return 2
  cp -- "${monolith}" "${stage}/cntools.library" || return 2
  chmod 0444 "${stage}/cntools.library" || return 2
  monolith_sha="$(sha256_file "${stage}/cntools.library")" || return 2
  rm -rf -- "${stage}/cntools/libs/legacy" || return 2
  find "${stage}/cntools/modules/root" -mindepth 1 -maxdepth 1 \
    ! -name module.json \
    -exec rm -rf -- {} + || return 2
  remaining_root_member="$(find "${stage}/cntools/modules/root" \
    -mindepth 1 -maxdepth 1 -print)" || return 2
  [[ "${remaining_root_member}" == "${root_module}" &&
     -f "${root_module}" && ! -L "${root_module}" ]] || return 2
  atomic_jq_update "${root_module}" '
    .schemaVersion = 1 |
    del(.controlPolicy)
  ' || return 2
  root_module_sha="$(sha256_file "${root_module}")" || return 2
  atomic_jq_update "${manifest}" --arg hash "${monolith_sha}" \
    --arg root_module_sha "${root_module_sha}" '
    .schemaVersion = 1 |
    .moduleApiVersion = 1 |
    del(.moduleSchemaVersion) |
    del(.legacyBundle) |
    .files |= map(select(
      (.path | startswith("cntools/libs/legacy/") | not) and
      ((.path | startswith("cntools/modules/root/") | not) or
       .path == "cntools/modules/root/module.json")
    )) |
    (.files[] | select(.path == "cntools.library") | .sha256) = $hash |
    (.files[] | select(.path == "cntools/modules/root/module.json") |
      .sha256) = $root_module_sha
  ' || return 2
  [[ "$(jq -er '.files | length' "${manifest}")" == '19' ]] || return 2
  manifest_sha="$(sha256_file "${manifest}")" || return 2
  jq --arg hash "${manifest_sha}" '
    [{
      path:"cntools/manifest.json",
      source:"scripts/common-helper-scripts/cntools/manifest.json",
      mode:"0444", validator:"json", sha256:$hash
    }] + .files | sort_by(.path)
  ' "${manifest}" > "${inventory}" || return 2
  [[ "$(jq -er 'length' "${inventory}")" == '20' ]] || return 2
  jq -r '.[] | [.path,.mode,.sha256] | @tsv' "${inventory}" > \
    "${canonical}" || return 2
  generation_id="$(sha256_file "${canonical}")" || return 2
  lifecycle_sha="$(jq -er '
    .[] | select(.path == "cntools/core/lifecycle.sh") | .sha256
  ' "${inventory}")" || return 2
  jq -n --arg id "${generation_id}" --arg manifest_sha "${manifest_sha}" \
    --slurpfile files "${inventory}" '{
      schemaVersion:1,
      id:$id,
      version:"13.5.7",
      generationIdAlgorithm:"sha256-path-mode-content-v1",
      payloadManifest:"cntools/manifest.json",
      payloadManifestSha256:$manifest_sha,
      files:$files[0]
    }' > "${receipt}" || return 2
  while IFS=$'\t' read -r path mode; do
    chmod "${mode}" "${stage}/${path}" || return 2
  done < <(jq -er '.[] | [.path,.mode] | @tsv' "${inventory}")
  chmod 0444 "${receipt}" || return 2
  mkdir -p -- "${cntools_root}/generations" || return 2
  chmod 0700 "${cntools_root}" "${cntools_root}/generations" || return 2
  destination="${cntools_root}/generations/${generation_id}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 2
  mv -- "${stage}" "${destination}" || return 2
  find "${destination}" -depth -type d -exec chmod 0555 {} + || return 2
  printf '%s\t%s\n' "${generation_id}" "${lifecycle_sha}"
}

prepare_stage1_generation_only_transaction() {
  local case_id="$1" target_name="$2" journal_state="$3"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local transaction_id="1700000001.424243.124"
  local facade="${target}/scripts/cntools.library"
  local generation_record="" generation_id="" lifecycle_sha="" extra=""

  mkdir -p -- "${target}/files" "${target}/scripts"
  reconstruct_source_legacy_monolith "${facade}" ||
    fail "${case_id} could not reconstruct the Stage 1 CNTools monolith"
  chmod 0644 "${facade}"
  target_tree_state "${target}" "${TEST_ROOT}/${case_id}.baseline"
  generation_record="$(build_stage1_generation_fixture \
    "${target}/scripts/.cntools")" ||
    fail "${case_id} could not build a schema 1 generation"
  IFS=$'\t' read -r generation_id lifecycle_sha extra <<< \
    "${generation_record}"
  [[ -z "${extra}" && "${generation_id}" =~ ^[0-9a-f]{64}$ &&
     "${lifecycle_sha}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "${case_id} schema 1 generation identifiers were malformed"

  mkdir -m 0700 -- "${transaction}"
  mkdir -m 0700 -- "${transaction}/cntools-generation"
  cp -p -- "${facade}" "${transaction}/backup.1"
  cp -- "${target}/scripts/.cntools/generations/${generation_id}/cntools/core/lifecycle.sh" \
    "${transaction}/cntools-generation-validator.sh"
  chmod 0400 "${transaction}/cntools-generation-validator.sh"
  printf '%s\t%s\tN\tN\tN\t%s\n' \
    "${generation_id}" \
    "scripts/.cntools/generations/${generation_id}" "${lifecycle_sha}" \
    > "${transaction}/cntools-generation.tsv"
  [[ "$(awk -F '\t' 'NR == 1 { print NF }' \
      "${transaction}/cntools-generation.tsv")" == 6 ]] ||
    fail "${case_id} changed the frozen Stage 1 six-field generation record"
  printf '%s\n' $'scripts/cntools.library\tY\t0644\tbackup.1' > \
    "${transaction}/baseline.tsv"
  printf '%s\n' 'scripts/cntools.library' > "${transaction}/targets.tsv"
  : > "${transaction}/activation.tsv"
  case "${journal_state}" in
    prepared) ;;
    activated)
      cp -- "${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library" \
        "${facade}"
      chmod 0644 "${facade}"
      printf '%s\t%s\n' 'scripts/cntools.library' \
        "${target}/scripts/.guild-deploy-${transaction_id}.1" > \
        "${transaction}/activation.tsv"
      ;;
    *) fail "unsupported Stage 1 transaction state: ${journal_state}" ;;
  esac
  printf 'schemaVersion=1\ntransactionId=%s\nstate=%s\n' \
    "${transaction_id}" "${journal_state}" > "${transaction}/journal"
  chmod 0600 "${transaction}/cntools-generation.tsv" \
    "${transaction}/baseline.tsv" "${transaction}/targets.tsv" \
    "${transaction}/activation.tsv" "${transaction}/journal"
}

assert_stage1_generation_only_recovery() {
  local implementation="$1" journal_state="$2"
  local case_id="stage1-${implementation}-${journal_state}"
  local target_name="stage1_${implementation}_${journal_state}"
  local target="${TARGET_PARENT}/${target_name}"
  local after="${TEST_ROOT}/${case_id}.after"
  local fake_linux="N"

  [[ "${implementation}" == 'dingo' ]] && fake_linux="Y"
  prepare_stage1_generation_only_transaction "${case_id}" "${target_name}" \
    "${journal_state}"
  if run_deploy "${case_id}-recovery" "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return \
    stage0c-transaction-failure-injection-v1 \
    "${implementation}" preview "${fake_linux}"; then
    fail "${case_id} recovery pre-journal stop unexpectedly succeeded"
  fi
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail "${case_id} did not report Stage 1 generation-only recovery"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  target_tree_state "${target}" "${after}"
  cmp -s "${TEST_ROOT}/${case_id}.baseline" "${after}" || {
    diff -u "${TEST_ROOT}/${case_id}.baseline" "${after}" >&2 || true
    fail "${case_id} did not restore the exact Stage 1 baseline"
  }
  [[ ! -e "${target}/scripts/.cntools" &&
     ! -L "${target}/scripts/.cntools" ]] ||
    fail "${case_id} retained a schema 1 generation or recovery lock"
  assert_legacy_monolith_loads "${target}/scripts/cntools.library" "${case_id}"
}

test_stage1_generation_only_recovery() {
  assert_stage1_generation_only_recovery cnode prepared
  assert_stage1_generation_only_recovery dingo activated
}

test_stage0_committed_transaction_cleanup() {
  local target_name='stage0_committed_cleanup'
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local receipt_sha="" transaction_id=""
  local generation_before="${TEST_ROOT}/stage0-committed.generation.before"
  local generation_after="${TEST_ROOT}/stage0-committed.generation.after"
  local receipt_identity="" metadata_identity=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  atomic_jq_update "${receipt}" '
    .schemaVersion = 1 |
    del(.cntoolsGeneration) |
    .files |= map(select(.policy != "cntools-legacy-bundle"))
  '
  rewrite_receipt_legacy_inventory_order "${receipt}" cnode ||
    fail 'Stage 0 committed receipt did not retain historical order'
  receipt_sha="$(sha256_file "${receipt}")"
  transaction_id="${receipt_sha:0:24}"
  atomic_jq_update "${metadata}" --arg service "${target_name}" \
    --arg hash "${receipt_sha}" --arg transaction_id "${transaction_id}" '
      .serviceName = $service |
      .sourceSchemaVersion = 1 |
      .payloadReceiptSha256 = $hash |
      .transactionId = $transaction_id
    '
  chmod 0644 "${receipt}" "${metadata}"
  mkdir -m 0700 -- "${transaction}"
  cp -- "${receipt}" "${transaction}/receipt.candidate.json"
  cp -- "${metadata}" "${transaction}/deployment.candidate.json"
  chmod 0644 "${transaction}/receipt.candidate.json" \
    "${transaction}/deployment.candidate.json"
  printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
    "${transaction_id}" > "${transaction}/journal"
  chmod 0600 "${transaction}/journal"
  generation_identity_state "${target}/scripts/.cntools" "${generation_before}"
  receipt_identity="$(stat_inode "${receipt}"):$(stat_mtime "${receipt}"):$(
    stat_mode "${receipt}"):$(sha256_file "${receipt}")"
  metadata_identity="$(stat_inode "${metadata}"):$(stat_mtime "${metadata}"):$(
    stat_mode "${metadata}"):$(sha256_file "${metadata}")"

  if run_deploy stage0-committed-recovery "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return; then
    fail 'Stage 0 committed cleanup pre-journal stop unexpectedly succeeded'
  fi
  grep -Fq "transaction failpoint 'before-durable-journal'" "${RUN_OUTPUT}" ||
    fail 'Stage 0 committed cleanup did not reach a fresh transaction'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_eq "$(stat_inode "${receipt}"):$(stat_mtime "${receipt}"):$(
      stat_mode "${receipt}"):$(sha256_file "${receipt}")" \
    "${receipt_identity}" 'Stage 0 committed receipt identity/mode/bytes'
  assert_eq "$(stat_inode "${metadata}"):$(stat_mtime "${metadata}"):$(
      stat_mode "${metadata}"):$(sha256_file "${metadata}")" \
    "${metadata_identity}" 'Stage 0 committed metadata identity/mode/bytes'
  generation_identity_state "${target}/scripts/.cntools" "${generation_after}"
  cmp -s "${generation_before}" "${generation_after}" || {
    diff -u "${generation_before}" "${generation_after}" >&2 || true
    fail 'Stage 0 committed cleanup changed generation or lock state'
  }
}

test_stage1_committed_transaction_cleanup() {
  local target_name='stage1_committed_cleanup'
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local generation_record="" generation_id="" lifecycle_sha="" extra=""
  local generation="" manifest_sha="" generation_receipt_sha=""
  local receipt_sha="" transaction_id=""
  local generation_before="${TEST_ROOT}/stage1-committed.generation.before"
  local generation_after="${TEST_ROOT}/stage1-committed.generation.after"
  local receipt_identity="" metadata_identity=""

  copy_target "${TARGET_PARENT}/fresh" "${target}"
  generation_record="$(build_stage1_generation_fixture \
    "${target}/scripts/.cntools")" ||
    fail 'could not build the committed Stage 1 generation fixture'
  IFS=$'\t' read -r generation_id lifecycle_sha extra <<< \
    "${generation_record}"
  [[ -z "${extra}" && "${generation_id}" =~ ^[0-9a-f]{64}$ &&
     "${lifecycle_sha}" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'committed Stage 1 generation identifiers were malformed'
  generation="${target}/scripts/.cntools/generations/${generation_id}"
  manifest_sha="$(sha256_file "${generation}/cntools/manifest.json")"
  generation_receipt_sha="$(sha256_file "${generation}/.generation.json")"
  atomic_jq_update "${receipt}" --arg id "${generation_id}" \
    --arg manifest_sha "${manifest_sha}" \
    --arg generation_receipt_sha "${generation_receipt_sha}" '
      .schemaVersion = 2 |
      .files |= map(select(.policy != "cntools-legacy-bundle")) |
      .cntoolsGeneration = {
        schemaVersion: 1,
        id: $id,
        version: "13.5.7",
        path: ("scripts/.cntools/generations/" + $id),
        payloadManifest:
          ("scripts/.cntools/generations/" + $id + "/cntools/manifest.json"),
        payloadManifestSha256: $manifest_sha,
        generationReceipt:
          ("scripts/.cntools/generations/" + $id + "/.generation.json"),
        generationReceiptSha256: $generation_receipt_sha,
        fileCount: 20,
        active: false
      }
    '
  rewrite_receipt_legacy_inventory_order "${receipt}" cnode ||
    fail 'Stage 1 committed receipt did not retain historical order'
  assert_eq "$(jq -er '.files | length' "${receipt}")" '38' \
    'Stage 1 committed cnode host receipt file count'
  receipt_sha="$(sha256_file "${receipt}")"
  transaction_id="${receipt_sha:0:24}"
  atomic_jq_update "${metadata}" --arg service "${target_name}" \
    --arg hash "${receipt_sha}" --arg transaction_id "${transaction_id}" '
      .serviceName = $service |
      .sourceSchemaVersion = 2 |
      .payloadReceiptSha256 = $hash |
      .transactionId = $transaction_id
    '
  chmod 0644 "${receipt}" "${metadata}"
  mkdir -m 0700 -- "${transaction}"
  cp -- "${receipt}" "${transaction}/receipt.candidate.json"
  cp -- "${metadata}" "${transaction}/deployment.candidate.json"
  chmod 0644 "${transaction}/receipt.candidate.json" \
    "${transaction}/deployment.candidate.json"
  printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
    "${transaction_id}" > "${transaction}/journal"
  chmod 0600 "${transaction}/journal"
  generation_identity_state "${target}/scripts/.cntools" \
    "${generation_before}"
  receipt_identity="$(stat_inode "${receipt}"):$(stat_mtime "${receipt}"):$(
    stat_mode "${receipt}"):$(sha256_file "${receipt}")"
  metadata_identity="$(stat_inode "${metadata}"):$(stat_mtime "${metadata}"):$(
    stat_mode "${metadata}"):$(sha256_file "${metadata}")"

  if run_deploy stage1-committed-recovery "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return; then
    fail 'Stage 1 committed cleanup pre-journal stop unexpectedly succeeded'
  fi
  grep -Fq "transaction failpoint 'before-durable-journal'" "${RUN_OUTPUT}" ||
    fail 'Stage 1 committed cleanup did not reach a fresh transaction'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_eq "$(stat_inode "${receipt}"):$(stat_mtime "${receipt}"):$(
      stat_mode "${receipt}"):$(sha256_file "${receipt}")" \
    "${receipt_identity}" 'Stage 1 committed receipt identity/mode/bytes'
  assert_eq "$(stat_inode "${metadata}"):$(stat_mtime "${metadata}"):$(
      stat_mode "${metadata}"):$(sha256_file "${metadata}")" \
    "${metadata_identity}" 'Stage 1 committed metadata identity/mode/bytes'
  generation_identity_state "${target}/scripts/.cntools" "${generation_after}"
  cmp -s "${generation_before}" "${generation_after}" || {
    diff -u "${generation_before}" "${generation_after}" >&2 || true
    fail 'Stage 1 committed cleanup changed generation or lock state'
  }
}

test_restore_temp_symlink_rejection() {
  local case_id='restore-temp-symlink'
  local target_name='restore_temp_symlink'
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local restore_link="${target}/scripts/.guild-deploy-restore.attack"
  local external="${TEST_ROOT}/${case_id}.external"
  local before="${TEST_ROOT}/${case_id}.before"
  local after="${TEST_ROOT}/${case_id}.after"
  local external_before="${TEST_ROOT}/${case_id}.external.before"
  local external_after="${TEST_ROOT}/${case_id}.external.after"

  prepare_stage0_plain_transaction "${case_id}" "${target_name}" activated
  printf 'external restore sentinel\n' > "${external}"
  ln -s "${external}" "${restore_link}"
  target_tree_state "${target}" "${before}" Y
  external_before="$(stat_inode "${external}"):$(stat_mtime "${external}"):$(
    stat_mode "${external}"):$(sha256_file "${external}")"
  RUN_RESTORE_MKTEMP_SYMLINK="${restore_link}"
  RUN_RESTORE_MKTEMP_EXTERNAL="${external}"
  expect_deploy_failure "${case_id}-recovery" "${target_name}"
  RUN_RESTORE_MKTEMP_SYMLINK=""
  RUN_RESTORE_MKTEMP_EXTERNAL=""
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'restore-temp symlink rejection mutated the interrupted target'
  }
  [[ -L "${restore_link}" && "$(readlink "${restore_link}")" == "${external}" &&
     -d "${transaction}" && ! -L "${transaction}" ]] ||
    fail 'restore-temp symlink rejection changed the recovery fixture'
  external_after="$(stat_inode "${external}"):$(stat_mtime "${external}"):$(
    stat_mode "${external}"):$(sha256_file "${external}")"
  assert_eq "${external_after}" "${external_before}" \
    'restore-temp external sentinel identity/mode/bytes'
  assert_facade_refuses_transaction "${target}" "${case_id}"
  assert_snapshot_cleanup
}

test_incomplete_journal_rejection() {
  local target="${TARGET_PARENT}/recovery"
  local metadata="${target}/.deployment.json"
  local transaction="${target}/.guild-deploy-transaction"
  local protected="${target}/scripts/cnode.sh"
  local before="${TEST_ROOT}/incomplete-journal.before"
  local after="${TEST_ROOT}/incomplete-journal.after"
  local expected_hash="" interrupted_hash=""
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
  interrupted_hash="$(sha256_file "${protected}")"
  target_tree_state "${target}" "${before}" Y

  expect_deploy_failure incomplete-journal-rejection recovery
  assert_snapshot_cleanup
  grep -Fq 'Unsafe interrupted deployment journal' "${RUN_OUTPUT}" ||
    fail 'incomplete transaction journal was not rejected during admission'
  ! grep -Fq 'Interrupted Guild payload transaction recovered' \
    "${RUN_OUTPUT}" ||
    fail 'incomplete transaction journal entered automatic recovery'
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'incomplete transaction rejection mutated the target'
  }
  assert_eq "$(sha256_file "${protected}")" "${interrupted_hash}" \
    'incomplete transaction protected bytes'
  assert_eq "$(sha256_file "${transaction}/backup.1")" "${expected_hash}" \
    'incomplete transaction backup bytes'
  [[ -d "${transaction}" && ! -L "${transaction}" ]] ||
    fail 'incomplete transaction rejection removed the journal'
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

  target_tree_state "${target}" "${before}"
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
  target_tree_state "${target}" "${after}"
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
  local generation_path="" generation_manifest="" bundle_paths=""
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
  advance_cntools_payload failure-boundaries
  SOURCE_TREE_DIGEST="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")"

  generation_path="$(jq -er '.cntoolsGeneration.path' "${receipt}")"
  generation_manifest="${target}/${generation_path}/cntools/manifest.json"
  bundle_paths="$(jq -cer '
    .legacyBundle as $bundle |
    [$bundle.members[].path |
      ("scripts/" + $bundle.path + "/" + .)]
  ' "${generation_manifest}")"
  jq -e --argjson bundle_paths "${bundle_paths}" '
    ($bundle_paths | length) == 10 and
    ([.files[] as $file |
      select(($bundle_paths | index($file.path)) != null) |
      $file] | length) == 10 and
    all(.files[] as $file |
      select(($bundle_paths | index($file.path)) != null) |
      $file; .policy == "cntools-legacy-bundle")
  ' "${receipt}" >/dev/null ||
    fail 'receipt legacy-bundle expansion disagrees with its generation manifest'
  payload_count="$(jq --argjson bundle_paths "${bundle_paths}" '[
    .files[] as $file |
    select($file.path != "scripts/stage0c-obsolete.sh" and
      ($bundle_paths | index($file.path)) == null) |
    $file
  ] | length' "${receipt}")"
  (( payload_count >= 3 )) || fail 'payload is too small for positional failures'
  payload_middle=$(((payload_count + 1) / 2))
  payload_last="${payload_count}"

  assert_failpoint_rollback fail-before-journal "${target_name}" \
    before-durable-journal enospc 1
  assert_failpoint_rollback fail-after-journal-hup "${target_name}" \
    after-durable-journal HUP 129
  assert_failpoint_rollback fail-after-cntools-rename "${target_name}" \
    after-cntools-generation-rename return 1
  assert_failpoint_rollback fail-after-cntools-publish "${target_name}" \
    after-cntools-generation-publish return 1
  assert_failpoint_rollback fail-after-bundle-publish "${target_name}" \
    after-cntools-legacy-bundle-publish return 1
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

test_generation_publish_crash_recovery() {
  local target_name="generation_publish_crash"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local old_receipt="${TEST_ROOT}/generation-crash.receipt"
  local old_metadata="${TEST_ROOT}/generation-crash.metadata"
  local generation_a=""
  local generation_b=""
  local lifecycle=""
  local before="${TEST_ROOT}/generation-publish-activation.before"
  local after="${TEST_ROOT}/generation-publish-activation.after"
  local published_count=""

  prepare_failure_injection_target "${target_name}"
  generation_a="$(jq -er '.cntoolsGeneration.id' \
    "${target}/.guild-source-receipt.json")"
  cp -- "${target}/.guild-source-receipt.json" "${old_receipt}"
  cp -- "${target}/.deployment.json" "${old_metadata}"

  if run_deploy fail-generation-publish-crash "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-cntools-generation-publish crash; then
    fail 'generation-publish hard-crash failpoint unexpectedly succeeded'
  fi
  assert_eq "${RUN_STATUS}" '137' \
    'generation-publish hard-crash injected exit status'
  grep -Fq "transaction failpoint 'after-cntools-generation-publish'" \
    "${RUN_OUTPUT}" || fail 'generation-publish crash failpoint was not reached'
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${transaction}/journal" ]] ||
    fail 'generation-publish crash did not retain a durable journal'
  cmp -s "${old_receipt}" "${target}/.guild-source-receipt.json" ||
    fail 'generation-publish crash changed the authoritative receipt'
  cmp -s "${old_metadata}" "${target}/.deployment.json" ||
    fail 'generation-publish crash changed authoritative metadata'
  published_count="$(find "${target}/scripts/.cntools/generations" \
    -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
  (( published_count >= 2 )) ||
    fail 'hard crash was not injected after publishing the candidate generation'
  [[ -d "${target}/scripts/.cntools/generations/${generation_a}" ]] ||
    fail 'generation-publish crash removed the authoritative old generation'

  generation_b="$(find "${target}/scripts/.cntools/generations" \
    -mindepth 1 -maxdepth 1 -type d ! -name "${generation_a}" \
    -exec basename {} \; -quit)"
  [[ "${generation_b}" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'generation-publish crash did not leave a content-addressed candidate'
  lifecycle="${target}/scripts/.cntools/generations/${generation_a}/cntools/core/lifecycle.sh"
  target_tree_state "${target}" "${before}" Y
  if (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_activate \
      "${target}/scripts/.cntools" "${generation_b}"
  ) >/dev/null 2>&1; then
    fail 'canary activation bypassed interrupted deployment recovery'
  fi
  target_tree_state "${target}" "${after}" Y
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'rejected pre-recovery canary activation changed deployment state'
  }

  expect_deploy_success fail-generation-publish-recovery "${target_name}"
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail 'next run did not report generation-publish crash recovery'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_receipt_metadata_coherent "${target}"
  assert_cntools_generation_consistency "${target}" cnode
}

test_generation_missing_target_rollback_recovery() {
  local target_name="generation_missing_target_rollback"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local record="${transaction}/cntools-generation.tsv"
  local before="${TEST_ROOT}/generation-missing-target.before"
  local after="${TEST_ROOT}/generation-missing-target.after"
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" lifecycle_hash="" manifest_schema=""
  local manifest_count="" receipt_schema="" receipt_count="" extra=""
  local published="" staged=""

  prepare_failure_injection_target "${target_name}"
  target_tree_state "${target}" "${before}"
  if run_deploy generation-missing-target-crash "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-cntools-generation-publish crash; then
    fail 'missing-target rollback fixture crash unexpectedly succeeded'
  fi
  assert_eq "${RUN_STATUS}" '137' 'missing-target rollback fixture crash status'
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${record}" && ! -L "${record}" ]] ||
    fail 'missing-target rollback crash omitted its generation record'
  assert_stage3_generation_record "${record}" 'missing-target rollback'
  IFS=$'\t' read -r id relative root_existed generations_existed \
    target_existed lifecycle_hash manifest_schema manifest_count \
    receipt_schema receipt_count extra < "${record}"
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/.cntools/generations/${id}" &&
     "${target_existed}" == N &&
     "${lifecycle_hash}" =~ ^[0-9a-f]{64}$ &&
     "${manifest_schema}:${manifest_count}:${receipt_schema}:${receipt_count}" == \
       '3:151:3:152' ]] ||
    fail 'missing-target rollback generation record was malformed'
  published="${target}/${relative}"
  staged="${transaction}/cntools-generation/${id}"
  [[ -d "${published}" && ! -L "${published}" &&
     ! -e "${staged}" && ! -L "${staged}" ]] ||
    fail 'missing-target rollback fixture was not paused after generation move'
  chmod -R u+rwX "${published}"
  rm -rf -- "${published}"
  [[ ! -e "${published}" && ! -L "${published}" &&
     ! -e "${staged}" && ! -L "${staged}" ]] ||
    fail 'could not prepare absent staged/published generation recovery state'

  if run_deploy generation-missing-target-recovery "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    before-durable-journal return; then
    fail 'post-recovery pre-journal failpoint unexpectedly succeeded'
  fi
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail 'missing generation target did not permit ordinary rollback recovery'
  grep -Fq "transaction failpoint 'before-durable-journal'" "${RUN_OUTPUT}" ||
    fail 'missing-target recovery did not reach the fresh pre-journal gate'
  target_tree_state "${target}" "${after}"
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail 'missing generation target recovery did not restore exact target state'
  }
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  assert_receipt_metadata_coherent "${target}"
  assert_cntools_generation_consistency "${target}" cnode
}

test_tampered_durable_validator_never_executes() {
  local target_name="tampered_durable_validator"
  local target="${TARGET_PARENT}/${target_name}"
  local transaction="${target}/.guild-deploy-transaction"
  local validator="${transaction}/cntools-generation-validator.sh"
  local record="${transaction}/cntools-generation.tsv"
  local sentinel="${TEST_ROOT}/tampered-durable-validator.executed"
  local receipt="${target}/.guild-source-receipt.json"
  local metadata="${target}/.deployment.json"
  local old_receipt="${TEST_ROOT}/tampered-durable-validator.receipt"
  local old_metadata="${TEST_ROOT}/tampered-durable-validator.metadata"
  local before="${TEST_ROOT}/tampered-durable-validator.before"
  local after="${TEST_ROOT}/tampered-durable-validator.after"
  local generation_a=""
  local candidate=""
  local lifecycle=""
  local forged=""
  local validator_hash=""
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" old_hash="" manifest_schema=""
  local manifest_count="" receipt_schema="" receipt_count="" extra=""
  local retry_status=0

  prepare_failure_injection_target "${target_name}"
  generation_a="$(jq -er '.cntoolsGeneration.id' "${receipt}")"
  cp -- "${receipt}" "${old_receipt}"
  cp -- "${metadata}" "${old_metadata}"

  if run_deploy tampered-durable-validator-crash "${target_name}" \
    "${SOURCE_BRANCH}" "${SOURCE_ACCOUNT}" '' '' "${DISPATCHER}" '' \
    after-cntools-generation-publish crash; then
    fail 'durable-validator fixture crash unexpectedly succeeded'
  fi
  assert_eq "${RUN_STATUS}" '137' 'durable-validator fixture crash status'
  [[ -d "${transaction}" && ! -L "${transaction}" &&
     -f "${validator}" && ! -L "${validator}" &&
     -f "${record}" && ! -L "${record}" ]] ||
    fail 'durable-validator crash did not retain its trusted recovery inputs'

  assert_stage3_generation_record "${record}" 'durable-validator crash'
  IFS=$'\t' read -r id relative root_existed generations_existed \
    target_existed old_hash manifest_schema manifest_count receipt_schema \
    receipt_count extra < "${record}"
  [[ -z "${extra}" && "${old_hash}" =~ ^[0-9a-f]{64}$ &&
     "${target_existed}" == N &&
     "${manifest_schema}:${manifest_count}:${receipt_schema}:${receipt_count}" == \
       '3:151:3:152' ]] ||
    fail 'durable generation record fixture was malformed'
  candidate="${target}/${relative}"
  forged="$(forge_recovery_generation "${candidate}" "${sentinel}")" ||
    fail 'could not build a self-consistent forged recovery generation'
  IFS=$'\t' read -r id validator_hash <<< "${forged}"
  [[ "${id}" =~ ^[0-9a-f]{64}$ &&
     "${validator_hash}" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'forged recovery generation did not return strict identifiers'
  relative="scripts/.cntools/generations/${id}"
  candidate="${target}/${relative}"
  lifecycle="${target}/scripts/.cntools/generations/${generation_a}/cntools/core/lifecycle.sh"
  (
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_validate "${candidate}" "${id}"
  ) || fail 'forged recovery generation was not otherwise self-consistent'
  [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
    fail 'trusted validation executed the forged target lifecycle'
  chmod 0600 "${validator}"
  cp -- "${candidate}/cntools/core/lifecycle.sh" "${validator}"
  chmod 0400 "${validator}"
  assert_eq "$(sha256_file "${validator}")" "${validator_hash}" \
    'forged durable validator hash'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${id}" "${relative}" "${root_existed}" "${generations_existed}" \
    "${target_existed}" "${validator_hash}" "${manifest_schema}" \
    "${manifest_count}" "${receipt_schema}" "${receipt_count}" > "${record}"
  chmod 0600 "${record}"
  target_tree_state "${target}" "${before}"

  if run_deploy tampered-durable-validator-retry "${target_name}"; then
    retry_status=0
  else
    retry_status=$?
  fi
  [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
    fail 'interrupted-transaction recovery sourced a forged durable validator'
  assert_snapshot_cleanup
  if (( retry_status == 0 )); then
    grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
      fail 'safe forged-validator retry did not report transaction recovery'
    [[ ! -e "${candidate}" && ! -L "${candidate}" ]] ||
      fail 'safe recovery retained the transaction-recorded forged candidate'
    assert_no_transaction_artifacts "${target}"
    assert_receipt_metadata_coherent "${target}"
    assert_cntools_generation_consistency "${target}" cnode
  else
    target_tree_state "${target}" "${after}"
    cmp -s "${before}" "${after}" || {
      diff -u "${before}" "${after}" >&2 || true
      fail 'forged durable-validator refusal changed canonical transaction state'
    }
    cmp -s "${old_receipt}" "${receipt}" ||
      fail 'forged durable-validator refusal changed authoritative receipt'
    cmp -s "${old_metadata}" "${metadata}" ||
      fail 'forged durable-validator refusal changed authoritative metadata'
    (
      # shellcheck source=/dev/null
      . "${lifecycle}"
      cntools_generation_validate "${candidate}" "${id}"
    ) || fail 'forged durable-validator refusal corrupted the published candidate'
    [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
      fail 'post-refusal validation executed the forged target lifecycle'
  fi
}

literal_replace_file() {
  local file="$1" old="$2" new="$3"
  local staged="${file}.stage2-replace.$$"
  local mode=""

  [[ -n "${old}" && "${old}" != "${new}" ]] || return 2
  mode="$(stat_mode "${file}")" || return 2
  awk -v old="${old}" -v new="${new}" '
    {
      remaining=$0
      output=""
      while ((position=index(remaining, old)) > 0) {
        output=output substr(remaining, 1, position - 1) new
        remaining=substr(remaining, position + length(old))
      }
      print output remaining
    }
  ' "${file}" > "${staged}" || {
    rm -f -- "${staged}"
    return 1
  }
  chmod "${mode}" "${staged}" && mv -f -- "${staged}" "${file}"
}

advance_legacy_bundle_revision() {
  local manifest="${SOURCE_REPO}/scripts/common-helper-scripts/cntools/manifest.json"
  local facade="${SOURCE_REPO}/scripts/common-helper-scripts/cntools.library"
  local dispatcher="${SOURCE_REPO}/scripts/cnode-helper-scripts/guild-deploy.sh"
  local legacy_root="${SOURCE_REPO}/scripts/common-helper-scripts/cntools/libs/legacy"
  local old_id="" old_prefix="" old_logical_sha="" old_logical_size=""
  local old_member_sha="" old_member_size="" new_id="" new_prefix=""
  local new_logical_sha="" new_logical_size="" new_member_sha=""
  local new_member_size="" new_facade_sha="" member="" file=""
  local new_tree_digest=""
  local work_bundle="${TEST_ROOT}/cross-revision-bundle.work"
  local full_body="${TEST_ROOT}/cross-revision-bundle.full"
  local logical_body="${TEST_ROOT}/cross-revision-bundle.logical"
  local canonical="${TEST_ROOT}/cross-revision-bundle.canonical"

  old_id="$(jq -er '.legacyBundle.id' "${manifest}")" || return 2
  old_logical_sha="$(jq -er '.legacyBundle.logicalBodySha256' "${manifest}")" ||
    return 2
  old_logical_size="$(jq -er '.legacyBundle.logicalBodySize' "${manifest}")" ||
    return 2
  old_member_sha="$(jq -er '.legacyBundle.members[0].sha256' "${manifest}")" ||
    return 2
  old_member_size="$(jq -er '.legacyBundle.members[0].size' "${manifest}")" ||
    return 2
  old_prefix="${old_id:0:8}"
  cp -R -- "${legacy_root}/${old_id}" "${work_bundle}" || return 2
  chmod -R u+rwX "${work_bundle}" || return 2
  printf '\n# Stage 2 cross-revision bundle B.\n' >> \
    "${work_bundle}/010-common-dialog.sh" || return 2
  "${BASH_UNDER_TEST}" -n "${work_bundle}/010-common-dialog.sh" || return 2
  reconstruct_source_legacy_monolith "${full_body}" '' "${work_bundle}" ||
    return 2
  tail -n +6 "${full_body}" > "${logical_body}" || return 2
  new_logical_sha="$(sha256_file "${logical_body}")" || return 2
  new_logical_size="$(wc -c < "${logical_body}" | tr -d '[:space:]')" ||
    return 2
  new_member_sha="$(sha256_file "${work_bundle}/010-common-dialog.sh")" ||
    return 2
  new_member_size="$(wc -c < "${work_bundle}/010-common-dialog.sh" |
    tr -d '[:space:]')" || return 2
  [[ "${new_logical_sha}" =~ ^[0-9a-f]{64}$ &&
     "${new_member_sha}" =~ ^[0-9a-f]{64}$ &&
     "${new_logical_sha}" != "${old_logical_sha}" &&
     "${new_member_sha}" != "${old_member_sha}" &&
     "${new_logical_size}" =~ ^[1-9][0-9]*$ &&
     "${new_member_size}" =~ ^[1-9][0-9]*$ ]] || return 2

  {
    printf 'cntools-legacy-bundle-v1\n'
    printf 'facade\tcntools.library\n'
    printf 'logical-body\t%s\t%s\n' \
      "${new_logical_size}" "${new_logical_sha}"
    while IFS= read -r member; do
      printf 'member\t%s\t0444\t%s\t%s\n' "${member}" \
        "$(wc -c < "${work_bundle}/${member}" | tr -d '[:space:]')" \
        "$(sha256_file "${work_bundle}/${member}")"
    done < <(jq -er '.legacyBundle.members[].path' "${manifest}")
  } > "${canonical}" || return 2
  new_id="$(sha256_file "${canonical}")" || return 2
  [[ "${new_id}" =~ ^[0-9a-f]{64}$ && "${new_id}" != "${old_id}" ]] ||
    return 2
  new_prefix="${new_id:0:8}"
  [[ ! -e "${legacy_root}/${new_id}" && ! -L "${legacy_root}/${new_id}" ]] ||
    return 2
  cp -R -- "${work_bundle}" "${legacy_root}/${new_id}" || return 2

  for file in "${facade}" "${manifest}" "${dispatcher}"; do
    literal_replace_file "${file}" "${old_id}" "${new_id}" || return 2
    literal_replace_file "${file}" "${old_logical_sha}" \
      "${new_logical_sha}" || return 2
    literal_replace_file "${file}" "${old_logical_size}" \
      "${new_logical_size}" || return 2
    literal_replace_file "${file}" "${old_member_sha}" \
      "${new_member_sha}" || return 2
    literal_replace_file "${file}" "${old_member_size}" \
      "${new_member_size}" || return 2
  done
  literal_replace_file "${facade}" "${old_prefix}" "${new_prefix}" || return 2
  new_facade_sha="$(sha256_file "${facade}")" || return 2
  atomic_jq_update "${manifest}" --arg hash "${new_facade_sha}" '
    (.files[] | select(.path == "cntools.library") | .sha256) = $hash
  ' || return 2

  "${BASH_UNDER_TEST}" -n "${facade}" || return 2
  "${BASH_UNDER_TEST}" -n "${dispatcher}" || return 2
  while IFS= read -r member; do
    "${BASH_UNDER_TEST}" -n "${legacy_root}/${new_id}/${member}" || return 2
  done < <(jq -er '.legacyBundle.members[].path' "${manifest}")
  [[ "$(jq -er '.legacyBundle.id' "${manifest}")" == "${new_id}" &&
     "$(jq -er '.legacyBundle.logicalBodySha256' "${manifest}")" == "${new_logical_sha}" &&
     "$(jq -er '.legacyBundle.logicalBodySize' "${manifest}")" == "${new_logical_size}" ]] ||
    return 2

  "${REAL_GIT}" -C "${SOURCE_REPO}" add -- \
    scripts/common-helper-scripts/cntools.library \
    scripts/common-helper-scripts/cntools/manifest.json \
    "scripts/common-helper-scripts/cntools/libs/legacy/${new_id}" \
    scripts/cnode-helper-scripts/guild-deploy.sh || return 2
  new_tree_digest="$(calculate_checkout_tree_digest \
    "${SOURCE_REPO}" "${SOURCE_REVISION}")" || return 2
  printf '%s\t%s\t%s\n' "${old_id}" "${new_id}" "${new_tree_digest}"
}

test_cross_revision_bundle_recovery_and_retention() {
  local case_id='cross-revision-bundle'
  local target_name='cross_revision_bundle'
  local completed_name='cross_revision_completed'
  local target="${TARGET_PARENT}/${target_name}"
  local completed="${TARGET_PARENT}/${completed_name}"
  local ids="" old_id="" returned_old_id="" new_id="" new_tree_digest=""
  local extra="" generation_id=""

  copy_target "${TARGET_PARENT}/fresh" "${completed}"
  atomic_jq_update "${completed}/.deployment.json" --arg service \
    "${completed_name}" '.serviceName = $service'
  prepare_fresh_bundle_publish_crash "${case_id}-a-crash" "${target_name}"
  old_id="${BUNDLE_FIXTURE_TARGET##*/}"
  ids="$(advance_legacy_bundle_revision)" ||
    fail 'could not construct the valid cross-revision bundle B fixture'
  IFS=$'\t' read -r returned_old_id new_id new_tree_digest extra <<< "${ids}"
  [[ -z "${extra}" && "${returned_old_id}" == "${old_id}" &&
     "${new_id}" =~ ^[0-9a-f]{64}$ && "${new_id}" != "${old_id}" &&
     "${new_tree_digest}" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'cross-revision bundle fixture returned inconsistent identifiers'
  SOURCE_TREE_DIGEST="${new_tree_digest}"

  expect_deploy_success "${case_id}-b-recovery" "${target_name}"
  grep -Fq 'Interrupted Guild payload transaction recovered' "${RUN_OUTPUT}" ||
    fail 'dispatcher B did not report recovery of interrupted bundle A'
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${target}"
  [[ ! -e "${target}/scripts/cntools/libs/legacy/${old_id}" &&
     ! -L "${target}/scripts/cntools/libs/legacy/${old_id}" &&
     -d "${target}/scripts/cntools/libs/legacy/${new_id}" ]] ||
    fail 'cross-revision recovery did not retract A before publishing B'
  generation_id="$(jq -er '.cntoolsGeneration.id' \
    "${target}/.guild-source-receipt.json")"
  assert_eq "$(jq -er '.legacyBundle.id' \
      "${target}/scripts/.cntools/generations/${generation_id}/cntools/manifest.json")" \
    "${new_id}" 'cross-revision recovered bundle identifier'
  assert_fresh_payload_consistency "${target}"
  assert_facade_loads "${target}" cross-revision-b-recovered

  expect_deploy_success "${case_id}-completed-upgrade" "${completed_name}"
  assert_snapshot_cleanup
  assert_no_transaction_artifacts "${completed}"
  [[ -d "${completed}/scripts/cntools/libs/legacy/${old_id}" &&
     -d "${completed}/scripts/cntools/libs/legacy/${new_id}" ]] ||
    fail 'completed A-to-B upgrade did not retain both content-addressed bundles'
  assert_fresh_payload_consistency "${completed}"
  assert_facade_loads "${completed}" cross-revision-completed-upgrade
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

for required in git jq awk sed grep find sort cmp diff stat cp mv chmod ps sha256sum; do
  require_command "${required}"
done
[[ -s "${DISPATCHER}" ]] || fail "dispatcher is missing: ${DISPATCHER}"

case "${GUILD_STAGE2_TRANSACTION_FOCUS:-}" in
  cross-revision)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_cross_revision_bundle_recovery_and_retention
    printf 'guild deploy Stage 2 cross-revision bundle tests passed\n'
    exit 0
    ;;
  failure-boundaries)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_failure_injection_rollback_boundaries
    printf 'guild deploy Stage 2 failure-boundary rollback tests passed\n'
    exit 0
    ;;
  parent-interference)
    create_source_fixture
    create_git_wrapper
    test_bundle_parent_interference_recovery
    printf 'guild deploy Stage 2 parent-interference recovery tests passed\n'
    exit 0
    ;;
  quarantine-rollback)
    create_source_fixture
    create_git_wrapper
    test_transaction_quarantine_rollback_recovery
    printf 'guild deploy Stage 2 rollback-quarantine recovery test passed\n'
    exit 0
    ;;
  quarantine-committed)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    advance_cntools_payload quarantine-order-independence
    test_transaction_quarantine_committed_recovery
    printf 'guild deploy Stage 2 committed-quarantine recovery test passed\n'
    exit 0
    ;;
  bundle-rename)
    create_source_fixture
    create_git_wrapper
    test_bundle_rename_crash_recovery
    printf 'guild deploy Stage 2 bundle-rename recovery tests passed\n'
    exit 0
    ;;
  incomplete-journal)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_incomplete_journal_rejection
    printf 'guild deploy Stage 2 incomplete-journal rejection test passed\n'
    exit 0
    ;;
  reader-isolation)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_cntools_reader_isolation
    printf 'guild deploy Stage 2 reader-isolation tests passed\n'
    exit 0
    ;;
  unsafe-preserve)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_unsafe_preserved_config_modes
    printf 'guild deploy unsafe preserved-mode tests passed\n'
    exit 0
    ;;
  recovery-adversarial)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_transaction_quarantine_committed_recovery
    test_stage2_six_field_paired_recovery
    test_stage3_generation_record_discriminator_rejections
    test_forged_durable_bundle_manifest_rejection
    test_rollback_control_preflight_rejections
    test_imported_generation_validator_never_executes
    test_damaged_modular_journal_cannot_masquerade_as_stage0
    test_ordinary_target_ancestor_symlink_rejection
    test_missing_existing_target_parent_rejection
    test_stage0_plain_transaction_recovery
    test_stage1_generation_only_recovery
    test_stage0_committed_transaction_cleanup
    test_stage1_committed_transaction_cleanup
    test_restore_temp_symlink_rejection
    test_committed_journal_forgery_rejections
    test_metadata_publish_crash_recovery_handoff
    test_handoff_journal_identity_races
    printf 'guild deploy Stage 2 focused recovery/adversarial tests passed\n'
    exit 0
    ;;
  imported-validator)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_imported_generation_validator_never_executes
    printf 'guild deploy Stage 2 imported-validator recovery test passed\n'
    exit 0
    ;;
  stage0-recovery)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_stage0_plain_transaction_recovery
    printf 'guild deploy Stage 0 cross-version recovery tests passed\n'
    exit 0
    ;;
  stage1-recovery)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_stage1_generation_only_recovery
    test_stage0_committed_transaction_cleanup
    test_stage1_committed_transaction_cleanup
    test_restore_temp_symlink_rejection
    printf 'guild deploy Stage 1 cross-version recovery tests passed\n'
    exit 0
    ;;
  metadata-handoff)
    create_source_fixture
    create_git_wrapper
    test_fresh_deployment_and_handoff
    test_metadata_publish_crash_recovery_handoff
    test_handoff_journal_identity_races
    printf 'guild deploy Stage 2 metadata-handoff recovery tests passed\n'
    exit 0
    ;;
esac

test_help_without_git
test_no_guild_raw_transport
create_source_fixture
create_git_wrapper
test_fresh_deployment_and_handoff
test_cntools_reader_isolation
test_fresh_alternate_dispatcher_transactions
test_custom_launcher_header_and_port
test_docker_supplement_export
test_preserved_inputs
test_malformed_metadata_no_mutation
test_legacy_metadata_migration
test_stage0_schema1_receipt_migration
test_incomplete_journal_rejection
test_identity_mismatch_rejection
test_unsafe_receipt_no_mutation
test_unsafe_cntools_generation_paths
test_tampered_installed_lifecycle_never_executes
test_identical_refresh
test_same_payload_new_revision_generation_reuse
test_inactive_generation_upgrade_retains_active
test_live_generation_lock_prejournal_refusal
test_generation_prune_receipt_race
test_tampered_installed_lifecycle_never_executes \
  tampered_generation_lifecycle_changed_source
test_prior_generation_pointer_rejections
test_generation_rename_crash_recovery
test_bundle_rename_crash_recovery
test_bundle_rollback_state_table
test_stage2_six_field_paired_recovery
test_stage3_generation_record_discriminator_rejections
test_transaction_quarantine_recovery
test_existing_bundle_recovery
test_forged_durable_bundle_manifest_rejection
test_rollback_control_preflight_rejections
test_imported_generation_validator_never_executes
test_damaged_modular_journal_cannot_masquerade_as_stage0
test_ordinary_target_ancestor_symlink_rejection
test_missing_existing_target_parent_rejection
test_committed_journal_forgery_rejections
test_bundle_symlink_ancestor_rejections
test_bundle_parent_interference_recovery
test_failure_injection_rollback_boundaries
test_failure_injection_crash_recovery
test_generation_publish_crash_recovery
test_generation_missing_target_rollback_recovery
test_tampered_durable_validator_never_executes
test_stage0_plain_transaction_recovery
test_stage1_generation_only_recovery
test_stage0_committed_transaction_cleanup
test_stage1_committed_transaction_cleanup
test_restore_temp_symlink_rejection
test_obsolete_path_hash_guard
test_forced_script_archive
test_unsafe_preserved_config_modes
test_config_evolution_and_forced_archive
test_metadata_publish_crash_recovery_handoff
test_handoff_journal_identity_races
test_cross_revision_bundle_recovery_and_retention

# Failure injection covers preparation before the durable journal, active
# journal rollback, first/middle/last payload positions, retire and history
# archives, hash-guarded obsolete removal, both sides of receipt/metadata
# publication, HUP/INT/TERM cleanup, simulated ENOSPC, and SIGKILL recovery on
# the immediately following run. The failpoint gate is also proven inert when
# its exact Stage 0C test mode is absent.
printf 'guild deploy Stage 2 transaction tests passed\n'
