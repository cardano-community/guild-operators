#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools asset-list characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
PAYLOAD_MANIFEST="${REPO_ROOT}/scripts/common-helper-scripts/cntools/manifest.json"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/asset/list"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-asset-list.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
NETWORK_LOG="${TEST_ROOT}/network.log"
BASE_PATH="${PATH}"
REAL_JQ="$(command -v jq 2>/dev/null || true)"

cleanup_test() {
  if [[ "${CNTOOLS_ASSET_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'CNTools asset-list test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools asset-list characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep jq readlink sort stat wc; do
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

write_fake_commands() {
  local command_name

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target=""' \
    'for argument in "$@"; do target="${argument}"; done' \
    'case "${target}" in' \
    '  */malformed-policy/policy.script)' \
    '    printf '\''jq: parse error: malformed policy fixture\n'\'' >&2' \
    '    exit 4' \
    '    ;;' \
    '  */malformed-policy/broken.asset)' \
    '    printf '\''jq: parse error: malformed asset fixture\n'\'' >&2' \
    '    exit 4' \
    '    ;;' \
    'esac' \
    'exec "${CNTOOLS_ASSET_REAL_JQ:?}" "$@"' \
    > "${FAKE_BIN}/jq"
  chmod 0755 "${FAKE_BIN}/jq"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\t'\'' "${0##*/}" >> "${CNTOOLS_ASSET_NETWORK_LOG:?}"' \
      'printf '\''%s\t'\'' "$@" >> "${CNTOOLS_ASSET_NETWORK_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_ASSET_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

write_policy() {
  local asset_root="$1"
  local policy_name="$2"
  local policy_id="$3"
  local policy_script="$4"
  local policy_root="${asset_root}/${policy_name}"

  mkdir -p -- "${policy_root}"
  printf '%s\n' "${policy_id}" > "${policy_root}/policy.id"
  printf '%s\n' "${policy_script}" > "${policy_root}/policy.script"
}

prepare_populated_fixture() {
  local asset_root="$1"

  # Reverse creation order. The oracle must follow lexical path order instead.
  write_policy "${asset_root}" z-unlimited policy-unlimited \
    '{"keyHash":"fixture","type":"sig"}'
  write_policy "${asset_root}" m-future policy-future \
    '{"type":"all","scripts":[{"slot":140,"type":"before"}]}'
  write_policy "${asset_root}" a-expired policy-expired \
    '{"type":"all","scripts":[{"slot":70,"type":"before"}]}'

  # Filenames deliberately sort in the opposite order to the JSON names.
  printf '%s\n' '{"name":"Alpha","minted":42}' \
    > "${asset_root}/m-future/20-alpha.asset"
  printf '%s\n' '{"name":"Zulu","minted":1234567}' \
    > "${asset_root}/m-future/10-zulu.asset"
}

prepare_malformed_fixture() {
  local asset_root="$1"
  local policy_root="${asset_root}/malformed-policy"

  mkdir -p -- "${policy_root}"
  printf 'policy-broken\n' > "${policy_root}/policy.id"
  printf '{ malformed policy json\n' > "${policy_root}/policy.script"
  printf '{ malformed asset json\n' > "${policy_root}/broken.asset"
  if "${REAL_JQ}" -e . "${policy_root}/policy.script" >/dev/null 2>&1; then
    fail 'malformed policy fixture unexpectedly parsed as JSON'
  fi
  if "${REAL_JQ}" -e . "${policy_root}/broken.asset" >/dev/null 2>&1; then
    fail 'malformed asset fixture unexpectedly parsed as JSON'
  fi
}

write_expected_action() {
  local scenario="$1"
  local output_file="$2"

  case "${scenario}" in
    empty)
      printf '%s\n' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        ' >> ADVANCED >> ASSET >> LIST ASSETS' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        '' \
        'No policies or assets found!' \
        > "${output_file}"
      ;;
    populated)
      printf '%s\n' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        ' >> ADVANCED >> ASSET >> LIST ASSETS' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        '' \
        'Policy Name   : a-expired' \
        'Policy ID     : policy-expired' \
        'Policy Expire : slot-70, expired delta-30 ago !!' \
        'Asset         : No assets minted for this policy!' \
        '' \
        'Policy Name   : m-future' \
        'Policy ID     : policy-future' \
        'Policy Expire : slot-140, delta-40 remaining' \
        'Asset         : Name: Zulu (5a756c75) - Minted: 1,234,567' \
        'Asset         : Name: Alpha (416c706861) - Minted: 42' \
        '' \
        'Policy Name   : z-unlimited' \
        'Policy ID     : policy-unlimited' \
        'Policy Expire : unlimited' \
        'Asset         : No assets minted for this policy!' \
        > "${output_file}"
      ;;
    malformed)
      printf '%s\n' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        ' >> ADVANCED >> ASSET >> LIST ASSETS' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        '' \
        'Policy Name   : malformed-policy' \
        'Policy ID     : policy-broken' \
        'Policy Expire : unlimited' \
        'Asset         : Name:  () - Minted: ' \
        > "${output_file}"
      ;;
    *) fail "unknown expected-action scenario: ${scenario}" ;;
  esac
}

write_expected_stderr() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  if [[ "${scenario}" == "malformed" ]]; then
    printf '%s\n' \
      'jq: parse error: malformed policy fixture' \
      'jq: parse error: malformed asset fixture' \
      'jq: parse error: malformed asset fixture' \
      > "${output_file}"
    printf '%s' 'ERROR: must be a valid integer number' >> "${output_file}"
  fi
}

write_expected_events() {
  local scenario="$1"
  local mode="$2"
  local output_file="$3"
  local slot_count=0 index=0

  : > "${output_file}"
  case "${mode}" in
    LOCAL)
      printf '%s\n' \
        'runtime:getNodeMetrics' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' \
        >> "${output_file}"
      ;;
    LIGHT)
      printf '%s\n' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' \
        >> "${output_file}"
      ;;
    OFFLINE) ;;
    *) fail "unknown mode for expected events: ${mode}" ;;
  esac
  printf '%s\n' \
    'menu:main:a' \
    'menu:advanced:a' \
    'menu:asset:l' \
    'action:compatibility-dispatch' \
    >> "${output_file}"
  case "${scenario}" in
    empty) slot_count=0 ;;
    populated) slot_count=3 ;;
    malformed) slot_count=1 ;;
    *) fail "unknown scenario for expected events: ${scenario}" ;;
  esac
  for ((index=0; index<slot_count; index++)); do
    printf 'action:getSlotTipRef\n' >> "${output_file}"
  done
  printf '%s\n' \
    'action:waitToProceed' \
    'menu:asset:h' \
    >> "${output_file}"
  case "${mode}" in
    LOCAL)
      printf '%s\n' \
        'runtime:getNodeMetrics' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' \
        >> "${output_file}"
      ;;
    LIGHT)
      printf '%s\n' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' \
        >> "${output_file}"
      ;;
    OFFLINE) ;;
  esac
  printf '%s\n' \
    'menu:main:q' \
    'exit:0:CNTools closed!' \
    >> "${output_file}"
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"
  local begin_count=0 end_count=0

  begin_count="$(grep -c '^__CNTOOLS_ASSET_LIST_BEGIN__$' "${full_output}" || true)"
  end_count="$(grep -c '^__CNTOOLS_ASSET_LIST_END__$' "${full_output}" || true)"
  [[ "${begin_count}" == "1" && "${end_count}" == "1" ]] ||
    fail 'action output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_ASSET_LIST_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_ASSET_LIST_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source the public legacy controller and the compatibility framework as
# definition-only code. The public cases below route through a test authority
# adapter into the real extracted action; direct cases call the same runner.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION="$(
  declare -f cntools_compatibility_dispatch_action
)" || fail 'could not preserve the production compatibility bridge'
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

build_installed_generation_fixture() {
  local fixture_root="$1"
  local inventory="${fixture_root}/inventory.ndjson"
  local canonical="${fixture_root}/canonical.tsv"
  local node="${fixture_root}/node"
  local state_root="${node}/scripts/.cntools"
  local generations="${state_root}/generations"
  local manifest_hash="" generation_id="" generation=""
  local generation_receipt_hash="" path="" source="" mode=""
  local validator="" expected_hash="" extra="" target=""

  mkdir -p -- "${fixture_root}" "${node}/tmp" "${node}/assets" \
    "${node}/wallet" "${node}/pool" "${node}/home" "${generations}"
  chmod 0755 "${node}" "${node}/scripts"
  chmod 0700 "${node}/tmp" "${state_root}" "${generations}"
  manifest_hash="$(file_hash "${PAYLOAD_MANIFEST}")" || return 1
  jq -cn --arg path 'cntools/manifest.json' \
    --arg source 'scripts/common-helper-scripts/cntools/manifest.json' \
    --arg mode '0444' --arg validator 'json' \
    --arg sha256 "${manifest_hash}" '
      {path:$path, source:$source, mode:$mode,
       validator:$validator, sha256:$sha256}
    ' > "${inventory}" || return 1
  jq -c '.files[]' "${PAYLOAD_MANIFEST}" >> "${inventory}" || return 1
  jq -r -s 'sort_by(.path)[] | [.path,.mode,.sha256] | @tsv' \
    "${inventory}" > "${canonical}" || return 1
  generation_id="$(file_hash "${canonical}")" || return 1
  generation="${generations}/${generation_id}"
  mkdir -p -- "${generation}/cntools"
  cp -- "${PAYLOAD_MANIFEST}" "${generation}/cntools/manifest.json" ||
    return 1
  chmod 0444 "${generation}/cntools/manifest.json" || return 1
  while IFS=$'\t' read -r path source mode validator expected_hash extra; do
    [[ -n "${path}" && -n "${source}" && -n "${mode}" &&
       -n "${validator}" && -n "${expected_hash}" && -z "${extra}" ]] ||
      return 1
    target="${generation}/${path}"
    mkdir -p -- "$(dirname -- "${target}")" || return 1
    cp -- "${REPO_ROOT}/${source}" "${target}" || return 1
    chmod "${mode}" "${target}" || return 1
    [[ "$(file_hash "${target}")" == "${expected_hash}" ]] || return 1
  done < <(jq -r '.files[] |
    [.path,.source,.mode,.validator,.sha256] | @tsv' "${PAYLOAD_MANIFEST}")
  jq -s --arg id "${generation_id}" \
    --arg manifest_hash "${manifest_hash}" \
    --arg version "$(jq -er '.version' "${PAYLOAD_MANIFEST}")" '
      {
        schemaVersion:3,
        id:$id,
        version:$version,
        generationIdAlgorithm:"sha256-path-mode-content-v1",
        payloadManifest:"cntools/manifest.json",
        payloadManifestSha256:$manifest_hash,
        files:sort_by(.path)
      }
    ' "${inventory}" > "${generation}/.generation.json" || return 1
  chmod 0444 "${generation}/.generation.json" || return 1
  find "${generation}" -depth -type d -exec chmod 0555 {} + || return 1

  generation_receipt_hash="$(file_hash \
    "${generation}/.generation.json")" || return 1
  jq -n --arg id "${generation_id}" \
    --arg manifest_hash "${manifest_hash}" \
    --arg generation_receipt_hash "${generation_receipt_hash}" '
      {
        schemaVersion:2,
        implementation:"cnode",
        network:"preview",
        cntoolsGeneration:{
          schemaVersion:1,
          id:$id,
          version:"13.5.7",
          path:("scripts/.cntools/generations/"+$id),
          payloadManifest:("scripts/.cntools/generations/"+$id+
            "/cntools/manifest.json"),
          payloadManifestSha256:$manifest_hash,
          generationReceipt:("scripts/.cntools/generations/"+$id+
            "/.generation.json"),
          generationReceiptSha256:$generation_receipt_hash,
          fileCount:152,
          active:false
        }
      }
    ' > "${node}/.guild-source-receipt.json" || return 1
  jq -n '
      {
        implementation:"cnode",
        network:"preview",
        capabilities:{forging:true,localCli:true,metrics:true,n2c:true}
      }
    ' > "${node}/.deployment.json" || return 1
  chmod 0644 "${node}/.guild-source-receipt.json" \
    "${node}/.deployment.json" || return 1
  printf '%s\t%s\t%s\n' "${node}" "${generation}" "${generation_id}"
}

# The production bridge authenticates the installed generation. These focused
# behavior tests substitute only that authority setup, then invoke the real
# dispatcher and extracted action through the exact public leaf function.
cntools_compatibility_dispatch_action() (
  local action_id="${1:-}"
  local private_root="" context_file="" result_file="" status=0

  [[ "${action_id}" == "advanced.asset.list" && $# -eq 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  umask 077
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/asset-list-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}"
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  rm -f -- "${result_file}" "${context_file}"
  rmdir -- "${private_root}" || status=70
  return "${status}"
)

# Output-only implementation of the historical println semantics used by this
# branch. Logging is omitted so the characterization observes action behavior,
# not the global history-log side effect of the surrounding legacy runtime.
println() {
  local log_level="${1:-}"
  shift || true
  case "${log_level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${log_level}" "$@" ;;
  esac
}

clear() { :; }
getEpoch() { printf '0\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf 'delta-%s' "${1:-}"; }
slotInterval() { printf '20\n'; }
getDateFromSlot() { printf 'slot-%s\n' "${1:-}"; }

asciiToHex() {
  local value="${1:-}"
  local index=0
  for ((index=0; index<${#value}; index++)); do
    printf '%02x' "'${value:index:1}"
  done
}

formatAsset() {
  local value="${1:-}"
  case "${value}" in
    1234567) printf '1,234,567' ;;
    42) printf '42' ;;
    *)
      printf 'ERROR: must be a valid integer number' >&2
      return 1
      ;;
  esac
}

getNodeMetrics() {
  printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"
  slotnum=100
}

getPriceInfo() {
  printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
  price_now=""
}

updateProtocolParams() {
  printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"
}

getSlotTipRef() {
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf 'action:getSlotTipRef\n' >> "${EVENT_LOG:?}"
  fi
  printf '100\n'
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu="main" ;;
    '[m] Metadata') menu="advanced" ;;
    '[c] Create Policy') menu="asset" ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted scripted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  index=0
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == "asset:l" ]]; then
        CAPTURE_ACTIVE="Y"
        printf '__CNTOOLS_ASSET_LIST_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

waitToProceed() {
  if [[ "${INSTALLED_ROUTE_ACTIVE:-N}" == "Y" ]]; then
    if [[ "${CNTOOLS_ASSET_LIST_LOCK_PROBE:-real}" == "event" ]]; then
      [[ -f "${INSTALLED_LOCK_RELEASED_FILE:?}" ]] ||
        fail 'installed compatibility action reached wait before unlock'
    else
      (
        # shellcheck source=/dev/null
        builtin source "${INSTALLED_LIFECYCLE:?}" >/dev/null 2>&1
        cntools_generation_lock_acquire "${INSTALLED_STATE_ROOT:?}"
        cntools_generation_lock_release "${INSTALLED_STATE_ROOT}"
      ) >/dev/null 2>&1 ||
        fail 'installed compatibility action retained its generation lock at wait'
    fi
    printf 'action:generation-lock-released\n' >> "${EVENT_LOG:?}"
  fi
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  printf '__CNTOOLS_ASSET_LIST_END__\n'
  CAPTURE_ACTIVE="N"
  return 0
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
  local case_name="$1"
  local scenario="$2"
  local mode="$3"
  local case_root="${TEST_ROOT}/cases/${case_name}"
  local runtime_root="${case_root}/runtime"
  local asset_root="${runtime_root}/asset"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mkdir -p -- \
    "${runtime_root}/tmp" \
    "${runtime_root}/wallet" \
    "${runtime_root}/pool" \
    "${asset_root}" \
    "${runtime_root}/home" \
    "${capture_root}"
  case "${scenario}" in
    empty) ;;
    populated) prepare_populated_fixture "${asset_root}" ;;
    malformed) prepare_malformed_fixture "${asset_root}" ;;
    *) fail "unknown run scenario: ${scenario}" ;;
  esac

  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${case_name} before traversal"
  : > "${event_log}"
  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_ID_FILENAME="policy.id"
    ASSET_POLICY_SCRIPT_FILENAME="policy.script"
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION="characterized"
    NETWORK_NAME="Preview"
    ADVANCED_MODE="true"
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    price_now=""
    slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE="N"
    CHOICES=(a a l h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] || fail "${case_name} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_action "${scenario}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_events "${scenario}" "${mode}" "${expected_events}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "${case_name} action stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${case_name} action stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${case_name} wait and return events"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${case_name} after traversal"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "${case_name} persistent tree"
}

write_expected_direct_events() {
  local scenario="$1"
  local output_file="$2"
  local slot_count=0 index=0

  : > "${output_file}"
  case "${scenario}" in
    empty) slot_count=0 ;;
    populated) slot_count=3 ;;
    malformed) slot_count=1 ;;
    *) fail "unknown direct-event scenario: ${scenario}" ;;
  esac
  for ((index=0; index<slot_count; index++)); do
    printf 'action:getSlotTipRef\n' >> "${output_file}"
  done
}

run_direct_case() {
  local case_name="$1"
  local scenario="$2"
  local mode="$3"
  local case_root="${TEST_ROOT}/direct/${case_name}"
  local runtime_root="${case_root}/runtime"
  local asset_root="${runtime_root}/asset"
  local capture_root="${case_root}/capture"
  local private_root="${case_root}/private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mkdir -p -- \
    "${runtime_root}/tmp" \
    "${runtime_root}/wallet" \
    "${runtime_root}/pool" \
    "${asset_root}" \
    "${runtime_root}/home" \
    "${capture_root}" \
    "${private_root}"
  chmod 0700 "${private_root}"
  case "${scenario}" in
    empty) ;;
    populated) prepare_populated_fixture "${asset_root}" ;;
    malformed) prepare_malformed_fixture "${asset_root}" ;;
    *) fail "unknown direct scenario: ${scenario}" ;;
  esac
  write_context "${context_file}" "${mode}" "${runtime_root}/home"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot direct ${case_name} before dispatch"
  : > "${event_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_ID_FILENAME="policy.id"
    ASSET_POLICY_SCRIPT_FILENAME="policy.script"
    CNTOOLS_MODE="${mode}"
    ADVANCED_MODE="true"
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE="Y"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] ||
    fail "direct ${case_name} dispatch returned ${status}"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "direct ${case_name} unexpectedly produced a result"

  write_expected_action "${scenario}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_direct_events "${scenario}" "${expected_events}"
  assert_files_equal "${stdout_file}" "${expected_stdout}" \
    "direct ${case_name} stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "direct ${case_name} stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "direct ${case_name} events"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot direct ${case_name} after dispatch"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "direct ${case_name} persistent tree"
}

write_expected_installed_events() {
  local output_file="$1"

  printf '%s\n' \
    'menu:main:a' \
    'menu:advanced:a' \
    'menu:asset:l' \
    'authority:current' \
    'authority:current' \
    'action:generation-lock-released' \
    'action:waitToProceed' \
    'menu:asset:h' \
    'menu:main:q' \
    'exit:0:CNTools closed!' \
    > "${output_file}"
}

run_installed_public_route_case() {
  local case_root="${TEST_ROOT}/installed-public-route"
  local fixture_root="${case_root}/fixture"
  local capture_root="${case_root}/capture"
  local node="" generation="" generation_id="" state_root=""
  local lifecycle="" asset_root="" full_stdout="" action_stdout=""
  local stderr_file="" expected_stdout="" expected_stderr=""
  local event_log="" expected_events="" before_snapshot=""
  local after_snapshot="" status=0

  mkdir -p -- "${capture_root}"
  IFS=$'\t' read -r node generation generation_id < <(
    build_installed_generation_fixture "${fixture_root}"
  ) || fail 'could not build the installed asset-list generation fixture'
  [[ "${generation_id}" =~ ^[0-9a-f]{64}$ &&
     "${generation}" == \
       "${node}/scripts/.cntools/generations/${generation_id}" ]] ||
    fail 'installed asset-list generation fixture has an invalid identity'
  state_root="${node}/scripts/.cntools"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  asset_root="${node}/assets"
  full_stdout="${capture_root}/full.stdout"
  action_stdout="${capture_root}/action.stdout"
  stderr_file="${capture_root}/stderr"
  expected_stdout="${capture_root}/expected.stdout"
  expected_stderr="${capture_root}/expected.stderr"
  event_log="${capture_root}/events"
  expected_events="${capture_root}/expected.events"
  before_snapshot="${capture_root}/before.tree"
  after_snapshot="${capture_root}/after.tree"
  tree_snapshot "${asset_root}" "${before_snapshot}" ||
    fail 'could not snapshot installed public-route assets before traversal'
  : > "${event_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    # Restore the exact shipped bridge after the behavior matrix's controlled
    # authority adapter replaced it in the parent test shell.
    eval "${PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION}"
    AUTHORITY_CALL_COUNT=0
    deployment_payload_is_current() {
      printf 'authority:current\n' >> "${EVENT_LOG:?}"
      AUTHORITY_CALL_COUNT=$((AUTHORITY_CALL_COUNT + 1))
      if [[ "${AUTHORITY_CALL_COUNT}" == "2" ]]; then
        cntools_generation_lock_acquire() {
          rm -f -- "${INSTALLED_LOCK_RELEASED_FILE:?}"
          return 0
        }
        cntools_generation_lock_release() {
          : > "${INSTALLED_LOCK_RELEASED_FILE:?}"
          return 0
        }
        cntools_generation_pointers_validate() {
          _cntools_generation_root_validate "$1" &&
            _cntools_generation_state_is_settled "$1" &&
            _cntools_generation_pointers_validate_unlocked "$1"
        }
      fi
      return 0
    }
    deployment_payload_sha256() { file_hash "$1"; }
    HOME="${node}/home"
    NODE_HOME="${node}"
    TMP_DIR="${node}/tmp"
    WALLET_FOLDER="${node}/wallet"
    POOL_FOLDER="${node}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_ID_FILENAME="policy.id"
    ASSET_POLICY_SCRIPT_FILENAME="policy.script"
    CNTOOLS_MODE="OFFLINE"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION="characterized"
    NETWORK_NAME="Preview"
    ADVANCED_MODE="true"
    BLOCKLOG_DB="${node}/absent-blocklog.db"
    price_now=""
    slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE="N"
    INSTALLED_ROUTE_ACTIVE="Y"
    INSTALLED_LIFECYCLE="${lifecycle}"
    INSTALLED_STATE_ROOT="${state_root}"
    INSTALLED_LOCK_RELEASED_FILE="${node}/lock-released"
    CNTOOLS_ASSET_LIST_LOCK_PROBE="event"
    CHOICES=(a a l h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] ||
    fail "installed public-route traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_action empty "${expected_stdout}"
  write_expected_stderr empty "${expected_stderr}"
  write_expected_installed_events "${expected_events}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    'installed public-route action stdout'
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    'installed public-route action stderr'
  assert_files_equal "${event_log}" "${expected_events}" \
    'installed public-route authority, lock, wait, and return events'

  tree_snapshot "${asset_root}" "${after_snapshot}" ||
    fail 'could not snapshot installed public-route assets after traversal'
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    'installed public-route persistent asset tree'
  [[ -z "$(find "${node}/tmp" -mindepth 1 -print -quit)" ]] ||
    fail 'installed public route retained private context or result state'
  [[ ! -e "${node}/.guild-deploy-transaction" &&
     ! -L "${node}/.guild-deploy-transaction" ]] ||
    fail 'installed public route created a deployment transaction journal'
  rm -f -- "${node}/lock-released"
}

write_fake_commands
: > "${NETWORK_LOG}"
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH
export CNTOOLS_ASSET_REAL_JQ="${REAL_JQ}"
export CNTOOLS_ASSET_NETWORK_LOG="${NETWORK_LOG}"

run_case empty-offline empty OFFLINE
run_case populated-offline populated OFFLINE
run_case populated-local populated LOCAL
run_case populated-light populated LIGHT
run_case malformed-offline malformed OFFLINE

run_direct_case empty-offline empty OFFLINE
run_direct_case populated-offline populated OFFLINE
run_direct_case populated-local populated LOCAL
run_direct_case populated-light populated LIGHT
run_direct_case malformed-offline malformed OFFLINE

run_installed_public_route_case

[[ ! -s "${NETWORK_LOG}" ]] ||
  fail "legacy asset listing attempted a network command: $(< "${NETWORK_LOG}")"

# The general modular bootstrap remains shadow-only. Exactly one legacy leaf
# routes to compatibility execution, and the old listing body is not duplicated
# in the public controller.
if grep -Fq 'cntools_dispatcher_run_action' \
    "${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/bootstrap.sh"; then
  fail 'public modular bootstrap can reach compatibility action execution'
fi
legacy_list_arm="${TEST_ROOT}/legacy-list-arm"
awk '
  /^[[:space:]]+list-assets\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${legacy_list_arm}"
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.list' \
      "${legacy_list_arm}" || true)" == "1" ]] ||
  fail 'legacy list-assets route does not contain exactly one compatibility call'
if grep -Eq 'Policy Name|Policy Expire|find .*ASSET_FOLDER|\.scripts\[0\]\.slot' \
    "${legacy_list_arm}"; then
  fail 'legacy list-assets implementation body was not fully extracted'
fi
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.list' \
      "${CNTOOLS_SCRIPT}" || true)" == "1" ]] ||
  fail 'advanced.asset.list generic bridge call count changed'
if grep -Fq 'CNTools action execution is inactive in Stage 3 shadow mode.' \
    "${ACTION_DIRECTORY}/action.sh"; then
  fail 'advanced.asset.list still contains the inert Stage 3 implementation'
fi

printf 'CNTools advanced.asset.list characterization and parity tests passed\n'
