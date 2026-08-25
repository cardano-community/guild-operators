#!/usr/bin/env bash
# Freeze the characterized safe legacy output and exercise the extracted,
# hardened blocks.epoch action through both public and direct routes.
# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if [[ "${1:-}" == --blocks-epoch-fake-sqlite ]]; then
  shift
  fake_vector_log="${CNTOOLS_BLOCKS_EPOCH_VECTOR_LOG:?}"
  fake_database="${CNTOOLS_BLOCKS_EPOCH_DATABASE:?}"
  fake_scenario="${CNTOOLS_BLOCKS_EPOCH_SCENARIO:?}"
  fake_next_exists="${CNTOOLS_BLOCKS_EPOCH_NEXT_EXISTS:-1}"
  fake_query="${!#}"
  printf 'sqlite3' >> "${fake_vector_log}"
  for fake_argument in "$@"; do
    [[ "${fake_argument}" == "${fake_database}" ]] && fake_argument='<db>'
    printf '\t%q' "${fake_argument}" >> "${fake_vector_log}"
  done
  printf '\n' >> "${fake_vector_log}"
  case "${fake_query}" in
    "SELECT CASE WHEN EXISTS(SELECT 1 FROM blocklog WHERE epoch="*" LIMIT 1) THEN 1 ELSE 0 END;")
      [[ "${fake_scenario}" == direct-malformed-next ]] &&
        printf 'unsafe\n' || printf '%s\n' "${fake_next_exists}"
      ;;
    "SELECT substr(status,1,17), length(status), block, typeof(block), slot, typeof(slot), slot_in_epoch, typeof(slot_in_epoch), CAST(strftime('%s', at) AS INTEGER), typeof(at), length(at), size, typeof(size), substr(hash,1,513), length(hash) FROM blocklog WHERE epoch="*" ORDER BY slot ASC, id ASC LIMIT 10001;")
      case "${fake_scenario}" in
        direct-no-blocks) : ;;
        direct-invalid-row)
          printf '%s\n' 'unsafe|6|1|integer|100|integer|10|integer|1767323045|text|20|1|integer||0'
          ;;
        direct-oversized-rows)
          fake_index=0
          while (( fake_index < 10001 )); do
            printf 'leader|6|0|integer|%s|integer|%s|integer|1767323045|text|20|0|integer||0\n' \
              "$((fake_index + 1))" "$((fake_index + 1))"
            fake_index=$((fake_index + 1))
          done
          ;;
        *)
          printf 'confirmed|9|123|integer|100|integer|10|integer|1767323045|text|20|2048|integer|%064d|64\n' 1
          printf '%s\n' 'leader|6|0|integer|200|integer|20|integer|1767323105|text|20|0|integer||0'
          ;;
      esac
      ;;
    "SELECT substr(pool_id,1,57), length(pool_id) FROM epochdata WHERE epoch="*" ORDER BY pool_id COLLATE BINARY ASC LIMIT 2;")
      printf '%056d|56\n' 1
      printf '%056d|56\n' 2
      ;;
    "SELECT epoch_slots_ideal, typeof(epoch_slots_ideal), printf('%.15g', max_performance), typeof(max_performance) FROM epochdata WHERE epoch="*" AND pool_id='"*"' ORDER BY id ASC LIMIT 2;")
      [[ "${fake_query}" == *"pool_id='$(printf '%056d' 1)'"* ]] || exit 96
      if [[ "${fake_scenario}" == direct-large-performance ]]; then
        printf '%s\n' '8|integer|1234.56789|real'
      else
        printf '%s\n' '8|integer|87.5|real'
      fi
      ;;
    *) printf 'unexpected hardened query: %s\n' "${fake_query}" >&2; exit 96 ;;
  esac
  exit 0
fi

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools blocks-epoch characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/blocks/epoch"
ACTION_SOURCE="${ACTION_DIRECTORY}/action.sh"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-blocks-epoch.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
TEST_BASH="${BASH}"
TEST_SCRIPT="${BASH_SOURCE[0]}"

cleanup_test() {
  if [[ "${CNTOOLS_BLOCKS_EPOCH_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools blocks-epoch test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools blocks-epoch characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep jq readlink sed sort stat wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND=shasum
else
  fail 'sha256sum or shasum is required'
fi

mkdir -p -- "${FAKE_BIN}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exec "${CNTOOLS_BLOCKS_EPOCH_TEST_BASH:?}" "${CNTOOLS_BLOCKS_EPOCH_TEST_SCRIPT:?}" --blocks-epoch-fake-sqlite "$@"' \
  > "${FAKE_BIN}/sqlite3"
chmod 0755 "${FAKE_BIN}/sqlite3"

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${level}" "$@" ;;
  esac
}

clear() { printf 'terminal:clear\n' >> "${EVENT_LOG:?}"; }
getEpoch() {
  [[ "${CAPTURE_ACTIVE:-N}" == Y || "${DIRECT_ACTIVE:-N}" == Y ]] &&
    printf 'action:getEpoch:5\n' >> "${EVENT_LOG:?}"
  printf '5\n'
}
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf '00:00:00'; }
getSlotTipRef() { printf '0\n'; }
slotInterval() { printf '20\n'; }
getNodeMetrics() { slotnum=0; }
getPriceInfo() { price_now=""; }
updateProtocolParams() { :; }

write_blocks_epoch_context() {
  local target="$1" mode="$2" node_home="$3"

  jq -nS --arg mode "${mode,,}" --arg node_home "${node_home}" '
    {
      advanced:false, apiVersion:1, capabilities:[], features:["blocklog"],
      generationVersion:"13.5.7", mode:$mode, nodeHome:$node_home,
      nodeImplementation:"cnode", nodeNetwork:"preview", schemaVersion:1
    }
  ' > "${target}"
  chmod 0400 "${target}"
}

# Public cases traverse the real Blocks selector and dispatch through the same
# shipped dispatcher/action as direct cases. This test-only adapter supplies
# the production bridge authority without depending on an installed payload.
cntools_compatibility_dispatch_action() (
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" action_status=0

  [[ "${action_id}" == blocks.epoch && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  export CNTOOLS_BLOCKS_EPOCH_TEST_BASH="${TEST_BASH}"
  export CNTOOLS_BLOCKS_EPOCH_TEST_SCRIPT="${TEST_SCRIPT}"
  export CNTOOLS_BLOCKS_EPOCH_SCENARIO=direct-default-offline
  [[ "${PUBLIC_ADAPTER_SCENARIO:-}" != public-no-blocks ]] ||
    export CNTOOLS_BLOCKS_EPOCH_SCENARIO=direct-no-blocks
  export CNTOOLS_BLOCKS_EPOCH_NEXT_EXISTS="${NEXT_EPOCH_EXISTS:-1}"
  export CNTOOLS_BLOCKS_EPOCH_VECTOR_LOG="${VECTOR_LOG:?}"
  export CNTOOLS_BLOCKS_EPOCH_DATABASE="${BLOCKLOG_DB:?}"
  PATH="${FAKE_BIN}:${BASE_PATH}"
  export PATH
  unset -f sqlite3
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/blocks-epoch-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_blocks_epoch_context \
    "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" || return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    action_status=70
  rm -f -- "${result_file}" "${context_file}" >/dev/null 2>&1 ||
    action_status=70
  rmdir -- "${private_root}" >/dev/null 2>&1 || action_status=70
  return "${action_status}"
)

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" option="" index=0 menu=""

  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[s] Summary') menu=blocks ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "${menu} menu exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  index=0
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == blocks:e ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_BLOCKS_EPOCH_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}

getAnswerAnyCust() {
  local output_variable="${1:-}"
  shift || true

  [[ ( "${output_variable}" == epoch_enter ||
       "${output_variable}" == blocks_epoch_selected_epoch ) &&
     "$*" == 'Enter epoch to list (enter for current)' ]] ||
    fail "unexpected epoch prompt: ${output_variable}:$*"
  printf -v "${output_variable}" '%s' "${EPOCH_INPUT}"
  printf 'action:answer:%s:%q\n' "${output_variable}" "${EPOCH_INPUT}" \
    >> "${EVENT_LOG:?}"
}

read() {
  local value=""

  if [[ "$#" == 2 && "${1:-}" == -rsn1 &&
        ( "${2:-}" == key || "${2:-}" == blocks_epoch_key ) ]]; then
    value="${READ_KEYS[READ_KEY_CURSOR]:-}"
    [[ -n "${value}" ]] || fail 'epoch-view key queue was exhausted'
    READ_KEY_CURSOR=$((READ_KEY_CURSOR + 1))
    printf -v "${2}" '%s' "${value}"
    printf 'action:key:%s\n' "${value}" >> "${EVENT_LOG:?}"
    if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${value}" == h ]]; then
      printf '__CNTOOLS_BLOCKS_EPOCH_END__\n'
      CAPTURE_ACTIVE=N
    fi
    return 0
  fi
  builtin read "$@"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_BLOCKS_EPOCH_END__\n'
    CAPTURE_ACTIVE=N
  fi
  return 0
}

date() {
  if [[ "$*" == '+%F %T %Z --date=2026-01-02T03:04:05Z' ||
        "$*" == '+%F %T %Z --date=2026-01-02T03:05:05Z' ]]; then
    printf 'date\t%q\t%q\n' "${1}" "${2}" >> "${VECTOR_LOG:?}"
    [[ "$*" == *03:04:05Z ]] &&
      printf '2026-01-02 03:04:05 UTC\n' ||
      printf '2026-01-02 03:05:05 UTC\n'
    return 0
  fi
  command date "$@"
}

sqlite3() {
  local database="${1:-}" query="${2:-}"

  [[ "$#" == 2 && "${database}" == "${BLOCKLOG_DB:?}" ]] || return 96
  printf 'sqlite3\t<db>\t%q\n' "${query}" >> "${VECTOR_LOG:?}"
  case "${query}" in
    'SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=6 LIMIT 1);')
      printf '%s\n' "${NEXT_EPOCH_EXISTS}"
      ;;
    'SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch='*' LIMIT 1);')
      [[ "${query}" == \
        'SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=5 LIMIT 1);' ]] &&
        printf '1\n' || printf '0\n'
      ;;
    "SELECT COUNT(*) FROM blocklog WHERE epoch=5 AND status='confirmed';"|\
    "SELECT COUNT(*) FROM blocklog WHERE epoch=5 AND status='leader';")
      printf '1\n'
      ;;
    "SELECT COUNT(*) FROM blocklog WHERE epoch=5 AND status='adopted';"|\
    "SELECT COUNT(*) FROM blocklog WHERE epoch=5 AND status='invalid';"|\
    "SELECT COUNT(*) FROM blocklog WHERE epoch=5 AND status='missed';"|\
    "SELECT COUNT(*) FROM blocklog WHERE epoch=5 AND status='ghosted';"|\
    "SELECT COUNT(*) FROM blocklog WHERE epoch=5 AND status='stolen';")
      printf '0\n'
      ;;
    'SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=5;')
      printf '8|87.5\n'
      ;;
    'SELECT LENGTH(status) FROM blocklog WHERE epoch=5 ORDER BY LENGTH(status) DESC LIMIT 1;') printf '9\n' ;;
    'SELECT LENGTH(block) FROM blocklog WHERE epoch=5 ORDER BY LENGTH(slot) DESC LIMIT 1;') printf '3\n' ;;
    'SELECT LENGTH(slot) FROM blocklog WHERE epoch=5 ORDER BY LENGTH(slot) DESC LIMIT 1;') printf '3\n' ;;
    'SELECT LENGTH(slot_in_epoch) FROM blocklog WHERE epoch=5 ORDER BY LENGTH(slot_in_epoch) DESC LIMIT 1;') printf '2\n' ;;
    'SELECT LENGTH(size) FROM blocklog WHERE epoch=5 ORDER BY LENGTH(size) DESC LIMIT 1;') printf '4\n' ;;
    'SELECT LENGTH(hash) FROM blocklog WHERE epoch=5 ORDER BY LENGTH(hash) DESC LIMIT 1;') printf '64\n' ;;
    'SELECT status, block, slot, slot_in_epoch, at FROM blocklog WHERE epoch=5 ORDER BY slot;')
      printf 'confirmed|123|100|10|2026-01-02T03:04:05Z\nleader|0|200|20|2026-01-02T03:05:05Z\n'
      ;;
    'SELECT status, slot, size, hash FROM blocklog WHERE epoch=5 ORDER BY slot;')
      printf 'confirmed|100|2048|%064d\nleader|200|0|\n' 1
      ;;
    'SELECT status, block, slot, slot_in_epoch, at, size, hash FROM blocklog WHERE epoch=5 ORDER BY slot;')
      printf 'confirmed|123|100|10|2026-01-02T03:04:05Z|2048|%064d\nleader|0|200|20|2026-01-02T03:05:05Z|0|\n' 1
      ;;
    *) return 96 ;;
  esac
}

myExit() {
  local status="${1:-0}" message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'public epoch traversal did not consume all choices'
  exit "${status}"
}

extract_public_action() {
  local full_stdout="$1" action_stdout="$2"

  [[ "$(grep -c '^__CNTOOLS_BLOCKS_EPOCH_BEGIN__$' "${full_stdout}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_BLOCKS_EPOCH_END__$' "${full_stdout}" || true)" == 1 ]] ||
    fail 'public epoch output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_BLOCKS_EPOCH_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_BLOCKS_EPOCH_END__" { exit }
    capture { print }
  ' "${full_stdout}" > "${action_stdout}"
}

normalize_vectors() {
  local target="$1" runtime_root="$2"

  sed "s#${runtime_root}#<runtime>#g" "${target}" > "${target}.normalized"
  mv -f -- "${target}.normalized" "${target}"
}

expected_public_hashes() {
  # Freeze normalized action stdout, terminal/navigation events, and external
  # argv in that order after the one-call extraction. Public stderr is required
  # to remain empty separately.
  case "$1" in
    public-default-offline|public-default-local|public-default-light)
      printf '%s\n' $'bdddb9e8870126014d63ced654ab2f366224bb2be9c886cd685e7688577a654a\ta9eef32cd80e96475cc65a9a856cdca21a89e6fb6f004f5943173f6e6179e052\tcc41e20bcc959b87500344bdfb2888ad25e605fe2964347fd86bc7d50b999a6f'
      ;;
    public-invalid-alpha)
      printf '%s\n' $'68777a31f7bdacbc8321caf789ea3acecd71f22e2f3a0ab8c43f08bd6317388c\ta222a9846b5f8f12e08ccc2485d97af6535fec04610fe720f0dbd0213934eab5\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    public-injection)
      printf '%s\n' $'68777a31f7bdacbc8321caf789ea3acecd71f22e2f3a0ab8c43f08bd6317388c\t88ec1895f2e8ecf1d34c08bb689474303931546b0c42e1a18148078aa4f6a529\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    public-no-blocks)
      printf '%s\n' $'5bc0eda9b454f6d24ccd33280465d005325f9c76332cb1e32bbc21e49abe9e0a\t8defb0d04d3cba21025d25e9670b7a2f0a9b56fab2f8f24a5e8f823962675d5e\t14d87f40c34d17de87108b4ef8640b4d4efc985da97112a3710f9f8ba5685dfd'
      ;;
    public-navigation)
      printf '%s\n' $'bb7d645ce947209ef7f3a06bb0e7998ec50f8bb40d2e7f40f40c4b17c35b8ffb\t9196c756cbe1bc980c7e8dc98abd496e15972bf040fc3eec0d9a66fb5581342f\t779d9872f68be1b1ab84ae5837283f7404299202253a91a94b3b18af54cfe61a'
      ;;
    *) return 1 ;;
  esac
}

expected_direct_hashes() {
  # Freeze direct stdout, stderr, action-owned navigation events, and the
  # normalized read-only sqlite argv in that order.
  case "$1" in
    direct-default-offline|direct-default-local|direct-default-light)
      printf '%s\n' $'bdddb9e8870126014d63ced654ab2f366224bb2be9c886cd685e7688577a654a\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tf83bef3708824adf143829789ced45fedf3f199b5a83485a1be22c222a589b63\tcc41e20bcc959b87500344bdfb2888ad25e605fe2964347fd86bc7d50b999a6f'
      ;;
    direct-navigation)
      printf '%s\n' $'bb7d645ce947209ef7f3a06bb0e7998ec50f8bb40d2e7f40f40c4b17c35b8ffb\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\t12adb55c48f63080a08d4fe46903d7fb768cd947b1029e16f2246de4b8069753\t779d9872f68be1b1ab84ae5837283f7404299202253a91a94b3b18af54cfe61a'
      ;;
    direct-large-performance)
      printf '%s\n' $'18c03a599d44f225a6fdfbc7d0268f7d081aa00b9bc9398864f9600bd87d0d13\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tcb759dd8e97ea18f7c0fc5d62c7a627a23cd6507a119b7d72505cc1ef3cd48e6\tcc41e20bcc959b87500344bdfb2888ad25e605fe2964347fd86bc7d50b999a6f'
      ;;
    direct-invalid-alpha)
      printf '%s\n' $'ee9e17089416f3d61a3ab090f648e62108cb4c1193be1cecff79ca0f077114db\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tf76863f383764c461484f2069169990fb1f8b043b33a69595ffb37d6632d28ba\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    direct-injection)
      printf '%s\n' $'ee9e17089416f3d61a3ab090f648e62108cb4c1193be1cecff79ca0f077114db\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tcf651c7347ac2d7fe92c3ed329180359f7b755298e37efd3c936b48e75a5e81e\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    direct-leading-zero)
      printf '%s\n' $'ee9e17089416f3d61a3ab090f648e62108cb4c1193be1cecff79ca0f077114db\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\t87b28dc8788323ff0503fafc89552d5a482e525176047372c253929e270e7fb3\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    direct-negative)
      printf '%s\n' $'ee9e17089416f3d61a3ab090f648e62108cb4c1193be1cecff79ca0f077114db\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tffbc37269d8d86ad8746e3b097ed8d741c270d5c5c0cf8980df6f004e86ae866\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    direct-over-limit)
      printf '%s\n' $'ee9e17089416f3d61a3ab090f648e62108cb4c1193be1cecff79ca0f077114db\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\t03002f404a8ee204a39f87ecf5638b205e72d7141a9305c4aec8050305d1543b\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    direct-no-blocks)
      printf '%s\n' $'3b414aea0ccb79a9cc64a8b7fb536b3cdfebffafeabdc3de899b652874185e22\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tc1aac15a671f2a52c0fa65190f6104b7c6e7c4812facb79b2b0e23be2969a1aa\t14d87f40c34d17de87108b4ef8640b4d4efc985da97112a3710f9f8ba5685dfd'
      ;;
    direct-missing-sqlite)
      printf '%s\n' $'feda679f331104908ef76045f1c76cbe2b7d7531cb9b33aa4549a4a74af0b5ad\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\t21edfbf30fc90f813e11010e11129724d87d015a025dc9e014e11cfaac708e3d\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      ;;
    direct-missing-database)
      printf '%s\n' $'9d81177d3f919c4bcd2fb5a377012b536c98929f2edc7a8b1a553b3058e926b5\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\t21edfbf30fc90f813e11010e11129724d87d015a025dc9e014e11cfaac708e3d\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      ;;
    direct-malformed-next)
      printf '%s\n' $'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\t95cba2a5c14c027870c75ff62a4ea75ccc4ab4c81e024dc95cecd99f585c0be7\t49ffe52ed98148739e52d78a63e36f7a41c5b8cddf6074b6fef356f12386633d\t85300d0c17635d7e25e3cd867edb92aaf812c5346e6d096b0c5afd30d6146bec'
      ;;
    direct-invalid-row|direct-oversized-rows)
      printf '%s\n' $'d7aedd6e99895f7e08363bf43625851545f158da58060710bf2071bcb6ad5f8d\t95cba2a5c14c027870c75ff62a4ea75ccc4ab4c81e024dc95cecd99f585c0be7\tbc30e3c7272a38c4ac9645219079ae6671181079d8096b7c23d834aa5b07d1f8\tef2129027efb091ebca7ed6c7d8a57a3891c2f65aceed471345797c8e621e69d'
      ;;
    direct-invalid-timezone)
      printf '%s\n' $'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\t95cba2a5c14c027870c75ff62a4ea75ccc4ab4c81e024dc95cecd99f585c0be7\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      ;;
    *) return 1 ;;
  esac
}

declare -A PUBLIC_STDOUT_HASH=()

run_public_case() {
  local scenario="$1" mode="$2" input="$3" next_exists="$4"
  shift 4
  local case_root="${TEST_ROOT}/public/${scenario}"
  local runtime_root="${case_root}/runtime" capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr" event_log="${capture_root}/events"
  local vector_log="${capture_root}/vectors"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree" status=0
  local expected_record="" expected_stdout_hash=""
  local expected_event_hash="" expected_vector_hash=""
  local actual_event_hash="" actual_vector_hash=""
  local -a keys=("$@")

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" "${capture_root}"
  printf 'immutable blocklog fixture\n' > "${runtime_root}/blocklog.db"
  tree_snapshot "${runtime_root}" "${before_snapshot}" || fail "${scenario} pre-snapshot failed"
  : > "${event_log}"; : > "${vector_log}"
  if (
    set +e; set +u; set +o pipefail
    export LC_ALL=C TZ=UTC
    HOME="${runtime_root}/home" NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp" BLOCKLOG_DB="${runtime_root}/blocklog.db"
    BLOCKLOG_TZ=UTC CNTOOLS_MODE="${mode}" CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized NETWORK_NAME=Preview ADVANCED_MODE=false
    BLOCKLOG_DB_FEATURE=Y price_now="" slotnum=0
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}" VECTOR_LOG="${vector_log}"
    EPOCH_INPUT="${input}" NEXT_EPOCH_EXISTS="${next_exists}"
    PUBLIC_ADAPTER_SCENARIO="${scenario}"
    CAPTURE_ACTIVE=N DIRECT_ACTIVE=N
    CHOICES=(b e q); CHOICE_CURSOR=0
    READ_KEYS=("${keys[@]}"); READ_KEY_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 && ! -s "${stderr_file}" ]] ||
    fail "${scenario} public traversal failed with ${status}"
  extract_public_action "${full_stdout}" "${action_stdout}"
  normalize_vectors "${vector_log}" "${runtime_root}"
  case "${scenario}" in
    public-invalid-alpha)
      grep -Fq 'epoch must be a canonical integer between 0 and 2147483647' \
        "${action_stdout}" || fail 'hardened public alpha diagnostic changed'
      [[ "$(grep -c 'not-a-number' "${vector_log}" || true)" == 0 ]] ||
        fail 'hardened public alpha input reached SQLite'
      ;;
    public-injection)
      grep -Fq 'epoch must be a canonical integer between 0 and 2147483647' \
        "${action_stdout}" || fail 'hardened public injection diagnostic changed'
      [[ "$(grep -c 'OR' "${vector_log}" || true)" == 0 ]] ||
        fail 'hardened public injection reached SQLite'
      ;;
    public-no-blocks) grep -Fq 'No blocks in epoch 6' "${action_stdout}" || fail 'legacy no-block output changed' ;;
    public-navigation)
      grep -Fq 'Scheduled At' "${action_stdout}" || fail 'view 1 missing'
      grep -Fq '| # | Status' "${action_stdout}" || fail 'block tables missing'
      grep -Fq 'Block Status:' "${action_stdout}" || fail 'info view missing'
      [[ "$(grep -c 'Selected epoch : 5' "${action_stdout}")" == 6 ]] || fail 'refresh/view render count changed'
      [[ "$(grep -c '^| Leader |' "${action_stdout}")" == 6 ]] ||
        fail 'legacy summary-before-info behavior changed'
      ;;
    public-default-*)
      grep -Fq 'Selected epoch : 5' "${action_stdout}" || fail 'default epoch selection changed'
      ;;
  esac
  grep -Fq 'exit:0:CNTools closed!' "${event_log}" || fail "${scenario} did not return home"
  tree_snapshot "${runtime_root}" "${after_snapshot}" || fail "${scenario} post-snapshot failed"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" "${scenario} zero DB/files mutation"
  PUBLIC_STDOUT_HASH["${scenario}"]="$(file_hash "${action_stdout}")"
  actual_event_hash="$(file_hash "${event_log}")"
  actual_vector_hash="$(file_hash "${vector_log}")"
  expected_record="$(expected_public_hashes "${scenario}")" ||
    fail "${scenario} public hash oracle is missing"
  IFS=$'\t' read -r expected_stdout_hash expected_event_hash \
    expected_vector_hash <<< "${expected_record}"
  [[ "${PUBLIC_STDOUT_HASH[${scenario}]}" == "${expected_stdout_hash}" ]] ||
    fail "${scenario} exact public stdout changed"
  [[ "${actual_event_hash}" == "${expected_event_hash}" ]] ||
    fail "${scenario} exact public navigation events changed"
  [[ "${actual_vector_hash}" == "${expected_vector_hash}" ]] ||
    fail "${scenario} exact public external argv changed"
}

run_direct_case() {
  local scenario="$1" mode="$2" input="$3" expected_status="$4"
  shift 4
  local case_root="${TEST_ROOT}/direct/${scenario}"
  local runtime_root="${case_root}/runtime" capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout" stderr_file="${capture_root}/stderr"
  local event_log="${capture_root}/events" vector_log="${capture_root}/vectors"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local private_root="${runtime_root}/tmp/private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json" status=0
  local expected_record="" expected_stdout_hash=""
  local expected_stderr_hash="" expected_event_hash=""
  local expected_vector_hash="" actual_stdout_hash=""
  local actual_stderr_hash="" actual_event_hash="" actual_vector_hash=""
  local -a keys=("$@")

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" "${capture_root}"
  if [[ "${scenario}" != direct-missing-database ]]; then
    printf 'immutable blocklog fixture\n' > "${runtime_root}/blocklog.db"
  fi
  tree_snapshot "${runtime_root}" "${before_snapshot}" || fail "${scenario} pre-snapshot failed"
  : > "${event_log}"; : > "${vector_log}"
  if (
    set +e; set +u; set +o pipefail
    export LC_ALL=C TZ=UTC
    export CNTOOLS_BLOCKS_EPOCH_TEST_BASH="${TEST_BASH}"
    export CNTOOLS_BLOCKS_EPOCH_TEST_SCRIPT="${TEST_SCRIPT}"
    export CNTOOLS_BLOCKS_EPOCH_SCENARIO="${scenario}"
    export CNTOOLS_BLOCKS_EPOCH_VECTOR_LOG="${vector_log}"
    export CNTOOLS_BLOCKS_EPOCH_DATABASE="${runtime_root}/blocklog.db"
    PATH="${FAKE_BIN}:${BASE_PATH}"; export PATH
    unset -f sqlite3
    [[ "${scenario}" != direct-missing-sqlite ]] || sqlite3() { :; }
    HOME="${runtime_root}/home" NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp" BLOCKLOG_DB="${runtime_root}/blocklog.db"
    BLOCKLOG_TZ=$([[ "${scenario}" == direct-invalid-timezone ]] && printf ':unsafe' || printf UTC)
    CNTOOLS_MODE="${mode}"
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}" VECTOR_LOG="${vector_log}"
    EPOCH_INPUT="${input}" NEXT_EPOCH_EXISTS=1
    CAPTURE_ACTIVE=N DIRECT_ACTIVE=Y
    READ_KEYS=("${keys[@]}"); READ_KEY_CURSOR=0
    mkdir -p -- "${private_root}"; chmod 0700 "${private_root}"
    write_blocks_epoch_context \
      "${context_file}" "${mode}" "${runtime_root}/home"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
    direct_status=$?
    rm -f -- "${result_file}" "${context_file}"
    rmdir -- "${private_root}"
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} direct status ${status}, expected ${expected_status}"
  normalize_vectors "${vector_log}" "${runtime_root}"
  case "${scenario}" in
    direct-default-offline|direct-default-local|direct-default-light)
      public_scenario="public-default-${scenario#direct-default-}"
      [[ "$(file_hash "${stdout_file}")" == "${PUBLIC_STDOUT_HASH[${public_scenario}]}" ]] ||
        fail "${scenario} safe stdout parity changed"
      [[ ! -s "${stderr_file}" ]] || fail "${scenario} wrote stderr"
      ;;
    direct-navigation)
      [[ "$(file_hash "${stdout_file}")" == "${PUBLIC_STDOUT_HASH[public-navigation]}" ]] ||
        fail 'direct navigation stdout parity changed'
      ;;
    direct-large-performance)
      grep -Fq '| 2      | 8     | 1234.56789% |' "${stdout_file}" ||
        fail 'direct large-performance display changed'
      [[ ! -s "${stderr_file}" ]] ||
        fail 'direct large-performance wrote stderr'
      ;;
    direct-invalid-*|direct-injection|direct-leading-zero|direct-negative|direct-over-limit)
      if [[ "${scenario}" == direct-invalid-row ||
            "${scenario}" == direct-invalid-timezone ]]; then
        grep -Fqx 'CNTools blocks-epoch action failed validation.' "${stderr_file}" || fail "${scenario} validation diagnostic changed"
      else
        grep -Fq 'epoch must be a canonical integer between 0 and 2147483647' "${stdout_file}" || fail "${scenario} canonical epoch diagnostic changed"
        [[ "$(grep -c 'FROM blocklog WHERE epoch=' "${vector_log}" || true)" == 0 ]] || fail "${scenario} interpolated invalid epoch"
      fi
      ;;
    direct-no-blocks)
      grep -Fq 'No blocks in epoch 6' "${stdout_file}" || fail 'direct no-block output changed'
      ;;
    direct-missing-sqlite) grep -Fq 'ERROR: sqlite3 not found!' "${stdout_file}" || fail 'missing sqlite diagnostic changed' ;;
    direct-missing-database) grep -Fq 'ERROR: blocklog database not found!' "${stdout_file}" || fail 'missing DB diagnostic changed' ;;
    direct-malformed-next|direct-oversized-rows)
      grep -Fqx 'CNTools blocks-epoch action failed validation.' "${stderr_file}" || fail "${scenario} validation diagnostic changed"
      ;;
  esac
  if [[ -s "${vector_log}" ]]; then
    awk -F '\t' '$1 == "sqlite3" && $2 != "-readonly" { exit 1 }' \
      "${vector_log}" || fail "${scenario} sqlite invocation was not read-only"
  fi
  tree_snapshot "${runtime_root}" "${after_snapshot}" || fail "${scenario} post-snapshot failed"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" "${scenario} zero DB/files mutation"
  actual_stdout_hash="$(file_hash "${stdout_file}")"
  actual_stderr_hash="$(file_hash "${stderr_file}")"
  actual_event_hash="$(file_hash "${event_log}")"
  actual_vector_hash="$(file_hash "${vector_log}")"
  expected_record="$(expected_direct_hashes "${scenario}")" ||
    fail "${scenario} direct hash oracle is missing"
  IFS=$'\t' read -r expected_stdout_hash expected_stderr_hash \
    expected_event_hash expected_vector_hash <<< "${expected_record}"
  [[ "${actual_stdout_hash}" == "${expected_stdout_hash}" ]] ||
    fail "${scenario} exact direct stdout changed"
  [[ "${actual_stderr_hash}" == "${expected_stderr_hash}" ]] ||
    fail "${scenario} exact direct stderr changed"
  [[ "${actual_event_hash}" == "${expected_event_hash}" ]] ||
    fail "${scenario} exact direct navigation events changed"
  [[ "${actual_vector_hash}" == "${expected_vector_hash}" ]] ||
    fail "${scenario} exact direct sqlite argv changed"
}

run_public_case public-default-offline OFFLINE '' 1 h
run_public_case public-default-local LOCAL '' 1 h
run_public_case public-default-light LIGHT '' 1 h
[[ "${PUBLIC_STDOUT_HASH[public-default-offline]}" == \
   "${PUBLIC_STDOUT_HASH[public-default-local]}" &&
   "${PUBLIC_STDOUT_HASH[public-default-offline]}" == \
   "${PUBLIC_STDOUT_HASH[public-default-light]}" ]] ||
  fail 'legacy mode-invariant output changed'
run_public_case public-invalid-alpha OFFLINE 'not-a-number' 0
run_public_case public-injection OFFLINE '5 OR 1=1' 0
run_public_case public-no-blocks OFFLINE 6 0
run_public_case public-navigation OFFLINE 5 1 2 3 i x 1 h

run_direct_case direct-default-offline OFFLINE '' 20 h
run_direct_case direct-default-local LOCAL '' 20 h
run_direct_case direct-default-light LIGHT '' 20 h
run_direct_case direct-navigation OFFLINE 5 20 2 3 i x 1 h
run_direct_case direct-large-performance OFFLINE 5 20 h
run_direct_case direct-invalid-alpha OFFLINE not-a-number 20
run_direct_case direct-injection OFFLINE '5 OR 1=1' 20
run_direct_case direct-leading-zero OFFLINE 05 20
run_direct_case direct-negative OFFLINE -1 20
run_direct_case direct-over-limit OFFLINE 2147483648 20
run_direct_case direct-no-blocks OFFLINE 6 20
run_direct_case direct-missing-sqlite OFFLINE 5 20
run_direct_case direct-missing-database OFFLINE 5 20
run_direct_case direct-malformed-next OFFLINE 5 70
run_direct_case direct-invalid-row OFFLINE 5 70
run_direct_case direct-oversized-rows OFFLINE 5 70
run_direct_case direct-invalid-timezone OFFLINE 5 70

# The production validator accepts bounded canonical nonnegative decimals and
# rejects spellings that could hide non-finite, signed, exponent, or padded
# values before they can influence formatting widths.
(
  # shellcheck source=../../scripts/common-helper-scripts/cntools/modules/root/blocks/epoch/action.sh
  . "${ACTION_SOURCE}"
  for performance in 0 0.5 999.999 1234.56789 1000000000; do
    _cntools_action_blocks_epoch_performance_valid "${performance}" ||
      fail "valid performance was rejected: ${performance}"
  done
  for performance in '' NaN nan Inf Infinity -1 +1 01 .5 1. 1e3 \
      1000000000.1 1000000001 1.1234567890123456; do
    if _cntools_action_blocks_epoch_performance_valid "${performance}"; then
      fail "unsafe performance was accepted: ${performance:-<empty>}"
    fi
  done
)

[[ "$(grep -Ec 'cntools_compatibility_dispatch_action[[:space:]]+blocks\.epoch' \
  "${CNTOOLS_SCRIPT}" || true)" == 1 ]] ||
  fail 'public blocks-epoch compatibility call is missing or duplicated'
epoch_case="${TEST_ROOT}/blocks-epoch.case"
awk '
  /^[[:space:]]+1\) cntools_compatibility_dispatch_action blocks\.epoch$/ {
    capture=1
  }
  capture { print }
  capture && /^[[:space:]]+;;$/ { exit }
' "${CNTOOLS_SCRIPT}" > "${epoch_case}"
[[ "$(grep -Ec 'cntools_compatibility_dispatch_action[[:space:]]+blocks\.epoch' \
  "${epoch_case}" || true)" == 1 ]] ||
  fail 'public blocks-epoch case does not contain exactly one dispatch call'
grep -Fq '0|20|21) continue ;;' "${epoch_case}" ||
  fail 'public blocks-epoch handled return mapping changed'
grep -Fq '22) myExit 0 "CNTools closed!" ;;' "${epoch_case}" ||
  fail 'public blocks-epoch exit mapping changed'
grep -Fq '*) waitToProceed; continue ;;' "${epoch_case}" ||
  fail 'public blocks-epoch unexpected-failure mapping changed'
if grep -Eq 'sqlite3|epoch_enter|epoch_stats|Block Status|SELECT[[:space:]]' \
    "${epoch_case}"; then
  fail 'public blocks-epoch case retained an inline implementation'
fi
if grep -Fq 'SELECT status, block, slot, slot_in_epoch, at FROM blocklog' \
    "${CNTOOLS_SCRIPT}"; then
  fail 'legacy blocks-epoch implementation remains duplicated'
fi
grep -Fq 'Stage 4 compatibility action' "${ACTION_SOURCE}" ||
  fail 'hardened blocks-epoch action marker is missing'

printf 'CNTools blocks-epoch characterization/parity passed (7 public + 17 direct cases)\n'
