#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools blocks-summary characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/blocks/summary"
ACTION_SOURCE="${ACTION_DIRECTORY}/action.sh"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-blocks-summary.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
SUMMARY_POOL_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

cleanup_test() {
  if [[ "${CNTOOLS_BLOCKS_SUMMARY_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'CNTools blocks-summary test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools blocks-summary characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep readlink sort stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND="shasum"
else
  fail 'sha256sum or shasum is required'
fi

write_blocked_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  for command_name in curl wget git ssh nc cardano-cli; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_BLOCKS_BLOCKED_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_BLOCKS_BLOCKED_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_BLOCKS_BLOCKED_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

write_outer_header() {
  local epoch="$1"

  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> BLOCKS' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    "Current epoch: ${epoch}" \
    '' \
    'Show a block summary for all epochs or a detailed view for a specific epoch?'
}

write_summary_header() {
  local epoch="$1"

  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> BLOCKS' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    "Current epoch: ${epoch}" \
    ''
}

write_summary_divider() {
  printf '|'
  printf '%95s' '' | tr ' ' '='
  printf '|\n'
}

write_summary_table() {
  local scenario="$1"
  local epoch=0

  write_summary_divider
  printf '| %-5s | %-6s | %-7s | %-6s | %-7s | %-9s | %-6s | %-7s | %-6s | %-7s |\n' \
    'Epoch' 'Leader' 'Ideal' 'Luck' 'Adopted' 'Confirmed' 'Missed' \
    'Ghosted' 'Stolen' 'Invalid'
  write_summary_divider
  case "${scenario}" in
    navigation)
      printf '| %-5s | %-6s | %-7s | %-6s | %-7s | %-9s | %-6s | %-7s | %-6s | %-7s |\n' \
        '6' '28' '1234567' '98.76%' '11' '5' '2' '3' '4' '1'
      printf '| %-5s | %-6s | %-7s | %-6s | %-7s | %-9s | %-6s | %-7s | %-6s | %-7s |\n' \
        '5' '0' '-' '-' '0' '0' '0' '0' '0' '0'
      ;;
    default-count)
      for ((epoch=12; epoch>2; epoch--)); do
        printf '| %-5s | %-6s | %-7s | %-6s | %-7s | %-9s | %-6s | %-7s | %-6s | %-7s |\n' \
          "${epoch}" '0' '-' '-' '0' '0' '0' '0' '0' '0'
      done
      ;;
    *) fail "unknown table scenario: ${scenario}" ;;
  esac
  write_summary_divider
}

write_summary_info() {
  printf '%s\n' \
    'Block Status:' \
    '' \
    'Leader    - Scheduled to make block at this slot' \
    'Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)' \
    'Luck      - Leader slots assigned vs Ideal slots for this epoch' \
    'Adopted   - Block created successfully' \
    'Confirmed - Block created validated to be on-chain with the certainty' \
    "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'" \
    'Missed    - Scheduled at slot but no record of it in cncli DB and no' \
    '            other pool has made a block for this slot' \
    'Ghosted   - Block created but marked as orphaned and no other pool has made' \
    '            a valid block for this slot, height battle or block propagation issue' \
    'Stolen    - Another pool has a valid block registered on-chain for the same slot' \
    'Invalid   - Pool failed to create block, base64 encoded error message' \
    "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
}

write_summary_footer() {
  printf '\n%s\n' '[h] Home | [b] Block View | [i] Info | [*] Refresh'
}

write_table_screen() {
  local epoch="$1"
  local scenario="$2"

  write_summary_header "${epoch}"
  write_summary_table "${scenario}"
  write_summary_footer
}

write_info_screen() {
  local epoch="$1"

  write_summary_header "${epoch}"
  write_summary_info
  write_summary_footer
}

write_expected_stdout() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    missing-sqlite)
      printf '%s\n' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        ' >> BLOCKS' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        'ERROR: sqlite3 not found!' \
        > "${output_file}"
      ;;
    invalid-count)
      write_outer_header 5 > "${output_file}"
      printf '\n%s\n' 'ERROR: not a number between 0 and 1000' \
        >> "${output_file}"
      ;;
    default-count)
      write_outer_header 12 > "${output_file}"
      write_table_screen 12 default-count >> "${output_file}"
      ;;
    navigation)
      write_outer_header 5 > "${output_file}"
      write_table_screen 5 navigation >> "${output_file}"
      write_info_screen 5 >> "${output_file}"
      write_info_screen 5 >> "${output_file}"
      write_table_screen 5 navigation >> "${output_file}"
      ;;
    *) fail "unknown expected stdout scenario: ${scenario}" ;;
  esac
}

write_query_cycle() {
  local current_epoch="$1"
  local first_epoch="$2"
  local exists_epoch="${3:-$((current_epoch + 1))}"
  local epoch=0 status=""

  printf '%s\t%s\n' '-readonly' \
    "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=${exists_epoch} LIMIT 1);"
  printf '%s\t%s\n' '-readonly' \
    "SELECT pool_id FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY epoch DESC, pool_id ASC LIMIT 1;"
  printf '%s\t%s\n' '-readonly' \
    "SELECT LENGTH(epoch_slots_ideal) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} AND pool_id='${SUMMARY_POOL_ID}' ORDER BY LENGTH(epoch_slots_ideal) DESC LIMIT 1;"
  printf '%s\t%s\n' '-readonly' \
    "SELECT LENGTH(max_performance) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} AND pool_id='${SUMMARY_POOL_ID}' ORDER BY LENGTH(max_performance) DESC LIMIT 1;"
  for ((epoch=current_epoch; epoch>first_epoch; epoch--)); do
    for status in invalid missed ghosted stolen confirmed adopted leader; do
      printf "%s\tSELECT COUNT(*) FROM blocklog WHERE epoch=%s AND status='%s';\n" \
        '-readonly' "${epoch}" "${status}"
    done
    printf "%s\tSELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=%s AND pool_id='%s' LIMIT 1;\n" \
      '-readonly' "${epoch}" "${SUMMARY_POOL_ID}"
  done
}

write_expected_vectors() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    missing-sqlite|invalid-count) ;;
    default-count) write_query_cycle 12 2 > "${output_file}" ;;
    navigation)
      write_query_cycle 6 4 6 > "${output_file}"
      write_query_cycle 6 4 6 >> "${output_file}"
      ;;
    *) fail "unknown expected-vector scenario: ${scenario}" ;;
  esac
}

write_expected_events() {
  local scenario="$1"
  local output_file="$2"

  case "${scenario}" in
    missing-sqlite)
      printf '%s\n' \
        'menu:main:b' \
        'action:waitToProceed' \
        'menu:main:q' \
        'exit:0:CNTools closed!' \
        > "${output_file}"
      ;;
    invalid-count)
      printf '%s\n' \
        'menu:main:b' \
        'action:getEpoch:5' \
        'menu:blocks:s' \
        'action:compatibility-dispatch' \
        'action:answer:epoch_enter:not-a-number' \
        'action:waitToProceed' \
        'menu:main:q' \
        'exit:0:CNTools closed!' \
        > "${output_file}"
      ;;
    default-count)
      printf '%s\n' \
        'menu:main:b' \
        'action:getEpoch:12' \
        'menu:blocks:s' \
        'action:compatibility-dispatch' \
        'action:answer:epoch_enter:' \
        'action:isNumber:10' \
        'action:getEpoch:12' \
        'action:key:h' \
        'menu:main:q' \
        'exit:0:CNTools closed!' \
        > "${output_file}"
      ;;
    navigation)
      printf '%s\n' \
        'menu:main:b' \
        'action:getEpoch:5' \
        'menu:blocks:s' \
        'action:compatibility-dispatch' \
        'action:answer:epoch_enter:2' \
        'action:isNumber:2' \
        'action:getEpoch:5' \
        'action:key:i' \
        'action:getEpoch:5' \
        'action:key:x' \
        'action:getEpoch:5' \
        'action:key:b' \
        'action:getEpoch:5' \
        'action:key:h' \
        'menu:main:q' \
        'exit:0:CNTools closed!' \
        > "${output_file}"
      ;;
    *) fail "unknown expected-event scenario: ${scenario}" ;;
  esac
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"
  local begin_count=0 end_count=0

  begin_count="$(grep -c '^__CNTOOLS_BLOCKS_SUMMARY_BEGIN__$' \
    "${full_output}" || true)"
  end_count="$(grep -c '^__CNTOOLS_BLOCKS_SUMMARY_END__$' \
    "${full_output}" || true)"
  [[ "${begin_count}" == "1" && "${end_count}" == "1" ]] ||
    fail 'blocks-summary output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_BLOCKS_SUMMARY_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_BLOCKS_SUMMARY_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source the public controller and compatibility framework as definition-only
# code. Public cases traverse the real Blocks selector into the extracted
# action through a bounded test authority adapter; direct cases use the same
# shipped dispatcher and action.
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

write_blocks_context() {
  local target="$1"
  local node_home="$2"

  jq -nS --arg node_home "${node_home}" '
    {
      advanced: false,
      apiVersion: 1,
      capabilities: [],
      features: ["blocklog"],
      generationVersion: "13.5.7",
      mode: "offline",
      nodeHome: $node_home,
      nodeImplementation: "cnode",
      nodeNetwork: "preview",
      schemaVersion: 1
    }
  ' > "${target}"
  chmod 0400 "${target}"
}

cntools_compatibility_dispatch_action() {
  local action_id="${1:-}"
  local private_root="" context_file="" result_file="" status=0

  [[ "${action_id}" == "blocks.summary" && $# -eq 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  umask 077
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/blocks-summary-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_blocks_context "${context_file}" "${NODE_HOME}"
  COMPAT_DISPATCH_ACTIVE="Y"
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  COMPAT_DISPATCH_ACTIVE="N"
  printf '__CNTOOLS_BLOCKS_SUMMARY_END__\n'
  CAPTURE_ACTIVE="N"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  rm -f -- "${result_file}" "${context_file}"
  rmdir -- "${private_root}" || status=70
  return "${status}"
}

println() {
  local log_level="${1:-}"
  shift || true
  case "${log_level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${log_level}" "$@" ;;
  esac
}

clear() {
  :
}

command() {
  if [[ "${1:-}" == "-v" && "${2:-}" == "sqlite3" &&
        "${SQLITE_AVAILABLE:-Y}" == "N" ]]; then
    return 1
  fi
  builtin command "$@"
}

getEpoch() {
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf 'action:getEpoch:%s\n' "${CASE_EPOCH:?}" >> "${EVENT_LOG:?}"
  fi
  printf '%s\n' "${CASE_EPOCH:?}"
}

timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf '00:00:00'; }
getSlotTipRef() { printf '0\n'; }
slotInterval() { printf '20\n'; }

getNodeMetrics() {
  printf 'getNodeMetrics\n' >> "${BLOCKED_EFFECT_LOG:?}"
  return 97
}

getPriceInfo() {
  printf 'getPriceInfo\n' >> "${BLOCKED_EFFECT_LOG:?}"
  return 97
}

updateProtocolParams() {
  printf 'updateProtocolParams\n' >> "${BLOCKED_EFFECT_LOG:?}"
  return 97
}

isNumber() {
  printf 'action:isNumber:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

getAnswerAnyCust() {
  local variable_name="${1:-}"
  shift || true

  [[ "${variable_name}" == "epoch_enter" &&
     "$*" == 'Enter number of epochs to show (enter for 10)' ]] ||
    fail "unexpected blocks-summary input request: ${variable_name}:$*"
  printf -v "${variable_name}" '%s' "${COUNT_INPUT}"
  printf 'action:answer:%s:%s\n' "${variable_name}" "${COUNT_INPUT}" \
    >> "${EVENT_LOG:?}"
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu="main" ;;
    '[s] Summary') menu="blocks" ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted scripted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  index=0
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == "main:b" ]]; then
        CAPTURE_ACTIVE="Y"
        printf '__CNTOOLS_BLOCKS_SUMMARY_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

read() {
  local input_value=""

  if [[ "$#" -eq 2 && "${1:-}" == "-rsn1" && "${2:-}" == "key" ]]; then
    input_value="${READ_KEYS[READ_KEY_CURSOR]:-}"
    [[ -n "${input_value}" ]] || fail 'blocks-summary key input was exhausted'
    READ_KEY_CURSOR=$((READ_KEY_CURSOR + 1))
    printf -v "${2}" '%s' "${input_value}"
    printf 'action:key:%s\n' "${input_value}" >> "${EVENT_LOG:?}"
    return 0
  fi
  builtin read "$@"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${COMPAT_DISPATCH_ACTIVE:-N}" != "Y" ]]; then
    printf '__CNTOOLS_BLOCKS_SUMMARY_END__\n'
    CAPTURE_ACTIVE="N"
  fi
  return 0
}

sqlite3() {
  local database="${1:-}"
  local query="${2:-}"
  local remainder="" epoch="" status=""
  local expected_exists=""

  [[ "$#" -eq 3 && "${database}" == "-readonly" &&
     "${query}" == "${BLOCKLOG_DB:?}" ]] || {
    printf 'unexpected sqlite3 argv\n' >&2
    return 96
  }
  query="${3}"
  printf '%s\t%s\n' "${database}" "${query}" >> "${SQL_VECTOR_LOG:?}"

  expected_exists="SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((CASE_EPOCH + 1)) LIMIT 1);"
  if [[ "${query}" == "${expected_exists}" ]]; then
    printf '%s\n' "${SQL_NEXT_EXISTS:?}"
    return 0
  fi
  if [[ "${query}" == \
      "SELECT pool_id FROM epochdata WHERE epoch BETWEEN ${EXPECTED_FIRST_EPOCH:?} and ${EXPECTED_TABLE_EPOCH:?} ORDER BY epoch DESC, pool_id ASC LIMIT 1;" ]]; then
    printf '%s\n' "${SUMMARY_POOL_ID}"
    return 0
  fi
  if [[ "${query}" == \
      "SELECT LENGTH(epoch_slots_ideal) FROM epochdata WHERE epoch BETWEEN ${EXPECTED_FIRST_EPOCH:?} and ${EXPECTED_TABLE_EPOCH:?} AND pool_id='${SUMMARY_POOL_ID}' ORDER BY LENGTH(epoch_slots_ideal) DESC LIMIT 1;" ]]; then
    printf '7\n'
    return 0
  fi
  if [[ "${query}" == \
      "SELECT LENGTH(max_performance) FROM epochdata WHERE epoch BETWEEN ${EXPECTED_FIRST_EPOCH:?} and ${EXPECTED_TABLE_EPOCH:?} AND pool_id='${SUMMARY_POOL_ID}' ORDER BY LENGTH(max_performance) DESC LIMIT 1;" ]]; then
    printf '5\n'
    return 0
  fi
  case "${query}" in
    "SELECT COUNT(*) FROM blocklog WHERE epoch="*" AND status='"*"';")
      remainder="${query#SELECT COUNT(*) FROM blocklog WHERE epoch=}"
      epoch="${remainder%% *}"
      status="${query#*status=\'}"
      status="${status%%\'*}"
      if [[ "${SQL_SCENARIO}" == "navigation" && "${epoch}" == "6" ]]; then
        case "${status}" in
          invalid) printf '1\n' ;;
          missed) printf '2\n' ;;
          ghosted) printf '3\n' ;;
          stolen) printf '4\n' ;;
          confirmed) printf '5\n' ;;
          adopted) printf '6\n' ;;
          leader) printf '7\n' ;;
          *) return 96 ;;
        esac
      else
        case "${status}" in
          invalid|missed|ghosted|stolen|confirmed|adopted|leader) printf '0\n' ;;
          *) return 96 ;;
        esac
      fi
      return 0
      ;;
    "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch="*" AND pool_id='${SUMMARY_POOL_ID}' LIMIT 1;")
      remainder="${query#SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=}"
      epoch="${remainder%% *}"
      if [[ "${SQL_SCENARIO}" == "navigation" && "${epoch}" == "6" ]]; then
        printf '1234567|98.76\n'
      fi
      return 0
      ;;
  esac
  printf 'unexpected sqlite3 query: %s\n' "${query}" >&2
  return 96
}

myExit() {
  local status="${1:-0}"
  local message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'legacy traversal did not consume every scripted menu choice'
  exit "${status}"
}

run_case() {
  local scenario="$1"
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_log="${capture_root}/sqlite-vectors"
  local expected_vectors="${capture_root}/expected.sqlite-vectors"
  local blocked_log="${capture_root}/blocked-commands"
  local blocked_effect_log="${capture_root}/blocked-effects"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local count_input="" case_epoch=0 sqlite_available="Y"
  local next_exists=0 table_epoch=0 first_epoch=0 status=0
  local choices=() keys=()

  case "${scenario}" in
    missing-sqlite)
      case_epoch=5
      sqlite_available="N"
      choices=(b q)
      ;;
    invalid-count)
      case_epoch=5
      count_input="not-a-number"
      choices=(b s q)
      ;;
    default-count)
      case_epoch=12
      count_input=""
      next_exists=0
      table_epoch=12
      first_epoch=2
      choices=(b s q)
      keys=(h)
      ;;
    navigation)
      case_epoch=5
      count_input="2"
      next_exists=1
      table_epoch=6
      first_epoch=4
      choices=(b s q)
      keys=(i x b h)
      ;;
    *) fail "unknown run scenario: ${scenario}" ;;
  esac

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${capture_root}"
  printf 'immutable blocklog fixture\n' > "${runtime_root}/blocklog.db"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"
  : > "${vector_log}"
  : > "${blocked_log}"
  : > "${blocked_effect_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    export TZ=UTC
    export CNTOOLS_BLOCKS_BLOCKED_LOG="${blocked_log}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    BLOCKLOG_DB="${runtime_root}/blocklog.db"
    CNTOOLS_MODE="OFFLINE"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION="characterized"
    NETWORK_NAME="Preview"
    ADVANCED_MODE="false"
    price_now=""
    slotnum=0
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    SQL_VECTOR_LOG="${vector_log}"
    BLOCKED_EFFECT_LOG="${blocked_effect_log}"
    SQL_SCENARIO="${scenario}"
    SQLITE_AVAILABLE="${sqlite_available}"
    SQL_NEXT_EXISTS="${next_exists}"
    CASE_EPOCH="${case_epoch}"
    EXPECTED_TABLE_EPOCH="${table_epoch}"
    EXPECTED_FIRST_EPOCH="${first_epoch}"
    COUNT_INPUT="${count_input}"
    CAPTURE_ACTIVE="N"
    COMPAT_DISPATCH_ACTIVE="N"
    CHOICES=("${choices[@]}")
    CHOICE_CURSOR=0
    READ_KEYS=("${keys[@]}")
    READ_KEY_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_stdout "${scenario}" "${expected_stdout}"
  : > "${expected_stderr}"
  write_expected_events "${scenario}" "${expected_events}"
  write_expected_vectors "${scenario}" "${expected_vectors}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "${scenario} normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${scenario} normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} navigation and wait events"
  assert_files_equal "${vector_log}" "${expected_vectors}" \
    "${scenario} sqlite argument vectors"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} attempted a blocked external command: $(< "${blocked_log}")"
  [[ ! -s "${blocked_effect_log}" ]] ||
    fail "${scenario} invoked an external-effect runtime seam: $(< "${blocked_effect_log}")"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after traversal"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "${scenario} persistent runtime and blocklog tree"
}

write_expected_direct_stdout() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    missing-sqlite)
      printf '%s\n' 'ERROR: sqlite3 not found!' > "${output_file}"
      ;;
    missing-database)
      printf '%s\n' 'ERROR: blocklog database not found!' > "${output_file}"
      ;;
    invalid-count|invalid-leading-zero|invalid-expression|invalid-over-limit)
      printf '\n%s\n' 'ERROR: not a number between 0 and 1000' \
        > "${output_file}"
      ;;
    zero-count)
      write_summary_header 12 > "${output_file}"
      write_summary_divider >> "${output_file}"
      printf '| %-5s | %-6s | %-7s | %-6s | %-7s | %-9s | %-6s | %-7s | %-6s | %-7s |\n' \
        'Epoch' 'Leader' 'Ideal' 'Luck' 'Adopted' 'Confirmed' 'Missed' \
        'Ghosted' 'Stolen' 'Invalid' >> "${output_file}"
      write_summary_divider >> "${output_file}"
      write_summary_divider >> "${output_file}"
      write_summary_footer >> "${output_file}"
      ;;
    default-count)
      write_table_screen 12 default-count > "${output_file}"
      ;;
    navigation)
      write_table_screen 5 navigation > "${output_file}"
      write_info_screen 5 >> "${output_file}"
      write_info_screen 5 >> "${output_file}"
      write_table_screen 5 navigation >> "${output_file}"
      ;;
    *) fail "unknown expected direct stdout scenario: ${scenario}" ;;
  esac
}

write_expected_direct_events() {
  local scenario="$1"
  local output_file="$2"
  local input=""

  : > "${output_file}"
  case "${scenario}" in
    missing-sqlite|missing-database)
      printf '%s\n' 'action:waitToProceed' > "${output_file}"
      ;;
    invalid-count|invalid-leading-zero|invalid-expression|invalid-over-limit)
      case "${scenario}" in
        invalid-count) input='not-a-number' ;;
        invalid-leading-zero) input='08' ;;
        invalid-expression) input='1 + 1' ;;
        invalid-over-limit) input='1001' ;;
      esac
      printf '%s\n' \
        "action:answer:epoch_enter:${input}" \
        'action:waitToProceed' \
        > "${output_file}"
      ;;
    zero-count)
      printf '%s\n' \
        'action:answer:epoch_enter:0' \
        'action:isNumber:0' \
        'action:getEpoch:12' \
        'action:key:h' \
        > "${output_file}"
      ;;
    default-count)
      printf '%s\n' \
        'action:answer:epoch_enter:' \
        'action:isNumber:10' \
        'action:getEpoch:12' \
        'action:key:h' \
        > "${output_file}"
      ;;
    navigation)
      printf '%s\n' \
        'action:answer:epoch_enter:2' \
        'action:isNumber:2' \
        'action:getEpoch:5' \
        'action:key:i' \
        'action:getEpoch:5' \
        'action:key:x' \
        'action:getEpoch:5' \
        'action:key:b' \
        'action:getEpoch:5' \
        'action:key:h' \
        > "${output_file}"
      ;;
    *) fail "unknown expected direct event scenario: ${scenario}" ;;
  esac
}

run_direct_case() {
  local scenario="$1"
  local case_root="${TEST_ROOT}/direct/${scenario}"
  local runtime_root="${case_root}/runtime"
  local private_root="${case_root}/private"
  local capture_root="${case_root}/capture"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_log="${capture_root}/sqlite-vectors"
  local expected_vectors="${capture_root}/expected.sqlite-vectors"
  local blocked_log="${capture_root}/blocked-commands"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local count_input="" case_epoch=12 sqlite_available="Y"
  local next_exists=0 table_epoch=12 first_epoch=2 status=0
  local create_database="Y" keys=()

  case "${scenario}" in
    missing-sqlite) sqlite_available="N" ;;
    missing-database) create_database="N" ;;
    invalid-count) count_input='not-a-number' ;;
    invalid-leading-zero) count_input='08' ;;
    invalid-expression) count_input='1 + 1' ;;
    invalid-over-limit) count_input='1001' ;;
    zero-count)
      count_input='0'
      first_epoch=12
      keys=(h)
      ;;
    default-count)
      count_input=''
      keys=(h)
      ;;
    navigation)
      count_input='2'
      case_epoch=5
      next_exists=1
      table_epoch=6
      first_epoch=4
      keys=(i x b h)
      ;;
    *) fail "unknown direct scenario: ${scenario}" ;;
  esac

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${private_root}" "${capture_root}"
  chmod 0700 "${private_root}"
  if [[ "${create_database}" == "Y" ]]; then
    printf 'immutable blocklog fixture\n' > "${runtime_root}/blocklog.db"
  fi
  write_blocks_context "${context_file}" "${runtime_root}/home"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot direct ${scenario} before dispatch"
  : > "${event_log}"
  : > "${vector_log}"
  : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    export TZ=UTC
    export CNTOOLS_BLOCKS_BLOCKED_LOG="${blocked_log}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    BLOCKLOG_DB="${runtime_root}/blocklog.db"
    CNTOOLS_MODE="OFFLINE"
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    SQL_VECTOR_LOG="${vector_log}"
    SQL_SCENARIO="${scenario}"
    SQLITE_AVAILABLE="${sqlite_available}"
    SQL_NEXT_EXISTS="${next_exists}"
    CASE_EPOCH="${case_epoch}"
    EXPECTED_TABLE_EPOCH="${table_epoch}"
    EXPECTED_FIRST_EPOCH="${first_epoch}"
    COUNT_INPUT="${count_input}"
    CAPTURE_ACTIVE="Y"
    COMPAT_DISPATCH_ACTIVE="Y"
    READ_KEYS=("${keys[@]}")
    READ_KEY_CURSOR=0
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "20" ]] ||
    fail "direct ${scenario} dispatch returned ${status}, expected Home status 20"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "direct ${scenario} unexpectedly produced a result"

  write_expected_direct_stdout "${scenario}" "${expected_stdout}"
  : > "${expected_stderr}"
  write_expected_direct_events "${scenario}" "${expected_events}"
  case "${scenario}" in
    default-count) write_query_cycle 12 2 > "${expected_vectors}" ;;
    navigation)
      write_query_cycle 6 4 6 > "${expected_vectors}"
      write_query_cycle 6 4 6 >> "${expected_vectors}"
      ;;
    zero-count) write_query_cycle 12 12 > "${expected_vectors}" ;;
    *) : > "${expected_vectors}" ;;
  esac
  assert_files_equal "${stdout_file}" "${expected_stdout}" \
    "direct ${scenario} normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "direct ${scenario} normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "direct ${scenario} action events"
  assert_files_equal "${vector_log}" "${expected_vectors}" \
    "direct ${scenario} sqlite argument vectors"
  [[ ! -s "${blocked_log}" ]] ||
    fail "direct ${scenario} attempted a blocked external command"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot direct ${scenario} after dispatch"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "direct ${scenario} persistent runtime and blocklog tree"
  if [[ "${scenario}" == "missing-database" ]]; then
    [[ ! -e "${runtime_root}/blocklog.db" &&
       ! -L "${runtime_root}/blocklog.db" ]] ||
      fail 'read-only direct action created a missing blocklog database'
  fi
}

write_blocked_commands
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH

run_case missing-sqlite
run_case invalid-count
run_case default-count
run_case navigation

run_direct_case missing-sqlite
run_direct_case missing-database
run_direct_case invalid-count
run_direct_case invalid-leading-zero
run_direct_case invalid-expression
run_direct_case invalid-over-limit
run_direct_case zero-count
run_direct_case default-count
run_direct_case navigation

# Freeze the Stage 4 extraction boundary: Summary and Epoch each have exactly
# one public compatibility call, and only their modular actions own the
# hardened query/render implementations.
[[ "$(grep -c '^[[:space:]]*blocks)' "${CNTOOLS_SCRIPT}" || true)" == "1" ]] ||
  fail 'legacy Blocks arm is missing or duplicated'
[[ "$(grep -Ec 'cntools_compatibility_dispatch_action[[:space:]]+blocks\.summary' \
  "${CNTOOLS_SCRIPT}" || true)" == "1" ]] ||
  fail 'public blocks-summary compatibility call is missing or duplicated'
summary_case="${TEST_ROOT}/summary-case"
awk '
  /^[[:space:]]+0\) cntools_compatibility_dispatch_action blocks\.summary$/ {
    capture = 1
  }
  capture { print }
  capture && /^[[:space:]]+;;$/ { exit }
' "${CNTOOLS_SCRIPT}" > "${summary_case}"
[[ "$(grep -Ec 'cntools_compatibility_dispatch_action[[:space:]]+blocks\.summary' \
  "${summary_case}" || true)" == "1" ]] ||
  fail 'public blocks-summary case does not contain exactly one dispatch call'
if grep -Eq 'sqlite3|epoch_enter=|epoch_slots_ideal|Block Status' \
    "${summary_case}"; then
  fail 'public blocks-summary case retained an inline implementation'
fi
[[ "$(grep -Ec 'cntools_compatibility_dispatch_action[[:space:]]+blocks\.epoch' \
  "${CNTOOLS_SCRIPT}" || true)" == "1" ]] ||
  fail 'public blocks-epoch compatibility call is missing or duplicated'
if grep -Fq 'SELECT status, block, slot, slot_in_epoch, at FROM blocklog' \
    "${CNTOOLS_SCRIPT}"; then
  fail 'legacy Blocks Epoch branch remains duplicated after extraction'
fi
[[ "$(grep -Ec '^cntools_action_main\(\)[[:space:]]*\{' \
  "${ACTION_SOURCE}" || true)" == "1" ]] ||
  fail 'blocks-summary modular action entrypoint is missing or duplicated'
[[ "$(grep -Ec '^cntools_[[:alnum:]_]+\(\)[[:space:]]*\{' \
  "${ACTION_SOURCE}" || true)" == "1" ]] ||
  fail 'blocks-summary modular action defines unexpected helper functions'
grep -Fq 'sqlite3 -readonly "${BLOCKLOG_DB}"' "${ACTION_SOURCE}" ||
  fail 'blocks-summary modular action lost read-only SQLite transport'
grep -Fq 'ORDER BY epoch DESC, pool_id ASC LIMIT 1;' "${ACTION_SOURCE}" ||
  fail 'blocks-summary modular action lost deterministic pool selection'
grep -Fq "[[ ! \"\${epoch_enter}\" =~ ^(0|[1-9][0-9]{0,2}|1000)\$ ]]" \
  "${ACTION_SOURCE}" || fail 'blocks-summary canonical count bound changed'

printf 'CNTools blocks-summary characterization and parity passed (13 cases)\n'
