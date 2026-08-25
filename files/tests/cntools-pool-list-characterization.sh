#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools pool-list characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ENV_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
LEGACY_SELECTION_SOURCE="${LEGACY_ROOT}/020-terminal-selection-security.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/pool/list/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/pool/list"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-pool-list.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
KOIOS_API_FIXTURE='https://koios.example.test/api/v1'

cleanup_test() {
  if [[ "${CNTOOLS_POOL_LIST_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools pool-list test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools pool-list characterization failed: %s\n' "$1" >&2
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

pool_bech32_for() {
  case "$1" in
    a-no-cert) printf 'pool1qqqqqqqqqqqqqqqqqqqqa' ;;
    a-missing-kes) printf 'pool1qqqqqqqqqqqqqqqqqqqqc' ;;
    a-registered) printf 'pool1qqqqqqqqqqqqqqqqqqqqd' ;;
    a-error) printf 'pool1qqqqqqqqqqqqqqqqqqqqe' ;;
    a-empty) printf 'pool1qqqqqqqqqqqqqqqqqqqqf' ;;
    b-normal) printf 'pool1qqqqqqqqqqqqqqqqqqqqg' ;;
    b-retiring) printf 'pool1qqqqqqqqqqqqqqqqqqqqh' ;;
    b-ok) printf 'pool1qqqqqqqqqqqqqqqqqqqqj' ;;
    c-retired) printf 'pool1qqqqqqqqqqqqqqqqqqqqk' ;;
    d-empty) printf 'pool1qqqqqqqqqqqqqqqqqqqql' ;;
    m-alert) printf 'pool1qqqqqqqqqqqqqqqqqqqqm' ;;
    z-encrypted) printf 'pool1qqqqqqqqqqqqqqqqqqqqn' ;;
    *) fail "unknown pool name: $1" ;;
  esac
}

pool_hex_for() {
  local suffix=""

  case "$1" in
    a-no-cert) suffix=1 ;; a-missing-kes) suffix=2 ;;
    a-registered) suffix=3 ;; a-error) suffix=4 ;; a-empty) suffix=5 ;;
    b-normal) suffix=6 ;; b-retiring) suffix=7 ;; b-ok) suffix=8 ;;
    c-retired) suffix=9 ;; d-empty) suffix=a ;; m-alert) suffix=b ;;
    z-encrypted) suffix=c ;; *) fail "unknown pool name: $1" ;;
  esac
  printf '%055d%s' 0 "${suffix}"
}

write_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_POOL_LIST_CLI_LOG:?}"' \
    'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_POOL_LIST_CLI_LOG:?}"' \
    'printf '\''\n'\'' >> "${CNTOOLS_POOL_LIST_CLI_LOG:?}"' \
    'cold="" previous=""' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" == "--cold-verification-key-file" ]] && cold="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    '[[ -n "${cold}" ]] || exit 96' \
    'pool_name="${cold%/*}"; pool_name="${pool_name##*/}"' \
    'case "${pool_name}" in' \
    '  a-no-cert) suffix=1; bech=pool1qqqqqqqqqqqqqqqqqqqqa ;;' \
    '  a-missing-kes) suffix=2; bech=pool1qqqqqqqqqqqqqqqqqqqqc ;;' \
    '  a-registered) suffix=3; bech=pool1qqqqqqqqqqqqqqqqqqqqd ;;' \
    '  a-error) suffix=4; bech=pool1qqqqqqqqqqqqqqqqqqqqe ;;' \
    '  a-empty) suffix=5; bech=pool1qqqqqqqqqqqqqqqqqqqqf ;;' \
    '  b-normal) suffix=6; bech=pool1qqqqqqqqqqqqqqqqqqqqg ;;' \
    '  b-retiring) suffix=7; bech=pool1qqqqqqqqqqqqqqqqqqqqh ;;' \
    '  b-ok) suffix=8; bech=pool1qqqqqqqqqqqqqqqqqqqqj ;;' \
    '  c-retired) suffix=9; bech=pool1qqqqqqqqqqqqqqqqqqqqk ;;' \
    '  d-empty) suffix=a; bech=pool1qqqqqqqqqqqqqqqqqqqql ;;' \
    '  m-alert) suffix=b; bech=pool1qqqqqqqqqqqqqqqqqqqqm ;;' \
    '  z-encrypted) suffix=c; bech=pool1qqqqqqqqqqqqqqqqqqqqn ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    'if [[ "${CNTOOLS_POOL_LIST_SCENARIO:?}" == direct-invalid-id ]]; then' \
    '  printf '\''invalid-pool-id\n'\''; exit 0' \
    'fi' \
    'case "$*" in' \
    '  *" --output-format hex") printf '\''%055d%s\n'\'' 0 "${suffix}" ;;' \
    '  *) printf '\''%s\n'\'' "${bech}" ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''curl'\'' >> "${CNTOOLS_POOL_LIST_CURL_LOG:?}"' \
    'payload="" output="" previous=""' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${previous}" == "-d" || "${previous}" == "--data" ]] && payload="${argument}"' \
    '  if [[ "${previous}" == "--output" ]]; then output="${argument}"; normalized="<pool-response>"; fi' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_POOL_LIST_CURL_LOG:?}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_POOL_LIST_CURL_LOG:?}"' \
    'response=""' \
    'case "${payload}" in' \
    '  *pool1qqqqqqqqqqqqqqqqqqqqd*) returned_id=pool1qqqqqqqqqqqqqqqqqqqqd; status=registered; retiring=null ;;' \
    '  *pool1qqqqqqqqqqqqqqqqqqqqh*) returned_id=pool1qqqqqqqqqqqqqqqqqqqqh; status=retiring; retiring=77 ;;' \
    '  *pool1qqqqqqqqqqqqqqqqqqqqk*) returned_id=pool1qqqqqqqqqqqqqqqqqqqqk; status=retired; retiring=70 ;;' \
    '  *pool1qqqqqqqqqqqqqqqqqqqql*|*pool1qqqqqqqqqqqqqqqqqqqqf*) response='\''[]'\'' ;;' \
    '  *pool1qqqqqqqqqqqqqqqqqqqqe*) printf '\''fixture Koios timeout\n'\'' >&2; exit 28 ;;' \
    '  *pool1qqqqqqqqqqqqqqqqqqqqj*) returned_id=pool1qqqqqqqqqqqqqqqqqqqqj; status=registered; retiring=null ;;' \
    '  *) printf '\''unexpected Koios payload: %s\n'\'' "${payload}" >&2; exit 96 ;;' \
    'esac' \
    'case "${CNTOOLS_POOL_LIST_SCENARIO:?}" in' \
    '  direct-malformed) response='\''{ malformed'\'' ;;' \
    '  direct-schema-invalid) response='\''[{"pool_status":"unsafe","retiring_epoch":null}]'\'' ;;' \
    '  direct-oversized) response="$(printf '\''%0262145d'\'' 0)" ;;' \
    'esac' \
    '[[ -n "${response}" ]] || response="$(printf '\''[{\"pool_id_bech32\":\"%s\",\"active_epoch_no\":1,\"vrf_key_hash\":\"-\",\"margin\":0,\"fixed_cost\":0,\"pledge\":0,\"reward_addr\":\"-\",\"owners\":[],\"relays\":[],\"meta_url\":\"-\",\"meta_hash\":\"-\",\"meta_json\":{},\"pool_status\":\"%s\",\"retiring_epoch\":%s,\"op_cert\":\"-\",\"op_cert_counter\":null,\"active_stake\":0,\"block_count\":0,\"live_pledge\":0,\"live_stake\":0,\"live_delegators\":0,\"live_saturation\":0}]'\'' "${returned_id}" "${status}" "${retiring}")"' \
    'if [[ -n "${output}" ]]; then printf '\''%s\n'\'' "${response}" > "${output}"; else printf '\''%s\n'\'' "${response}"; fi' \
    > "${FAKE_BIN}/curl"
  chmod 0755 "${FAKE_BIN}/curl"

  for command_name in wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_POOL_LIST_BLOCKED_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_POOL_LIST_BLOCKED_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_POOL_LIST_BLOCKED_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

create_pool() {
  local pool_root="$1" name="$2" kes_start="${3:-}"

  mkdir -p -- "${pool_root}/${name}"
  printf '{"type":"StakePoolVerificationKey_ed25519"}\n' \
    > "${pool_root}/${name}/cold.vkey"
  [[ -n "${kes_start}" ]] &&
    printf '%s\n' "${kes_start}" > "${pool_root}/${name}/kes.start"
  return 0
}

prepare_fixture() {
  local scenario="$1" pool_root="$2"

  case "${scenario}" in
    empty) ;;
    offline-order)
      create_pool "${pool_root}" z-encrypted 102
      create_pool "${pool_root}" a-no-cert 999
      create_pool "${pool_root}" m-alert 101
      printf '{}\n' > "${pool_root}/z-encrypted/pool.cert"
      printf '{}\n' > "${pool_root}/m-alert/pool.cert"
      printf 'encrypted\n' > "${pool_root}/z-encrypted/cold.skey.gpg"
      ;;
    local-order)
      create_pool "${pool_root}" b-normal 104
      create_pool "${pool_root}" a-missing-kes
      printf '{}\n' > "${pool_root}/b-normal/pool.cert"
      printf '{}\n' > "${pool_root}/a-missing-kes/pool.cert"
      ;;
    local-delete)
      create_pool "${pool_root}" a-no-cert 999
      ;;
    light-statuses)
      create_pool "${pool_root}" d-empty 204
      create_pool "${pool_root}" b-retiring 202
      create_pool "${pool_root}" c-retired 203
      create_pool "${pool_root}" a-registered 201
      ;;
    light-error)
      create_pool "${pool_root}" b-ok 202
      create_pool "${pool_root}" a-error 201
      ;;
    light-empty)
      create_pool "${pool_root}" a-empty 999
      ;;
    *) fail "unknown fixture scenario: ${scenario}" ;;
  esac
}

write_header() {
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> POOL >> LIST' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
}

write_pool_identity() {
  local name="$1" registered="$2" encrypted="${3:-N}"

  printf '\n%s%s\n' "${name}" \
    "$([[ "${encrypted}" == Y ]] && printf ' (encrypted)')"
  printf '%-21s : %s\n' 'ID (hex)' "$(pool_hex_for "${name}")"
  printf '%-21s : %s\n' 'ID (bech32)' "$(pool_bech32_for "${name}")"
  printf '%-21s : %s\n' 'Registered' "${registered}"
}

write_kes_line() {
  local kind="$1" name="${2:-}"

  case "${kind}" in
    error) printf '%-21s : ERROR - : failure during KES calculation for %s\n' 'KES expiration date' "${name}" ;;
    alert) printf '%-21s : 2030-01-02 03:04:05 UTC - ALERT! 00:01:40 until expiration\n' 'KES expiration date' ;;
    expired) printf '%-21s : 2030-01-02 03:04:05 UTC - EXPIRED! 00:00:50 ago\n' 'KES expiration date' ;;
    warning) printf '%-21s : 2030-01-02 03:04:05 UTC - WARNING! 00:08:20 until expiration\n' 'KES expiration date' ;;
    normal) printf '%-21s : 2030-01-02 03:04:05 UTC\n' 'KES expiration date' ;;
    *) fail "unknown KES kind: ${kind}" ;;
  esac
}

write_expected_stdout() {
  local scenario="$1" output_file="$2"

  write_header > "${output_file}"
  case "${scenario}" in
    empty)
      printf '\n%s\n' 'No pools available!' >> "${output_file}"
      ;;
    offline-order)
      write_pool_identity a-no-cert No >> "${output_file}"
      write_pool_identity m-alert Yes >> "${output_file}"
      write_kes_line alert >> "${output_file}"
      write_pool_identity z-encrypted Yes Y >> "${output_file}"
      write_kes_line expired >> "${output_file}"
      printf '\n' >> "${output_file}"
      ;;
    local-order)
      write_pool_identity a-missing-kes Yes >> "${output_file}"
      write_kes_line error a-missing-kes >> "${output_file}"
      write_pool_identity b-normal Yes >> "${output_file}"
      write_kes_line normal >> "${output_file}"
      printf '\n' >> "${output_file}"
      ;;
    local-delete)
      write_pool_identity a-no-cert No >> "${output_file}"
      printf '\n' >> "${output_file}"
      ;;
    light-statuses)
      write_pool_identity a-registered Yes >> "${output_file}"
      write_kes_line warning >> "${output_file}"
      write_pool_identity b-retiring 'Yes - Retiring in epoch 77' >> "${output_file}"
      write_kes_line normal >> "${output_file}"
      write_pool_identity c-retired 'No - Retired in epoch 70' >> "${output_file}"
      write_pool_identity d-empty No >> "${output_file}"
      printf '\n' >> "${output_file}"
      ;;
    light-error)
      printf '\n%s\n' \
        'KOIOS_API ERROR: pool information is unavailable or invalid.' \
        >> "${output_file}"
      write_pool_identity b-ok Yes >> "${output_file}"
      write_kes_line normal >> "${output_file}"
      printf '\n' >> "${output_file}"
      ;;
    light-empty)
      write_pool_identity a-empty No >> "${output_file}"
      printf '\n' >> "${output_file}"
      ;;
    *) fail "unknown stdout scenario: ${scenario}" ;;
  esac
}

write_expected_events() {
  local scenario="$1" output_file="$2"

  printf '%s\n' 'menu:main:p' 'menu:pool:l' \
    'action:compatibility-dispatch' > "${output_file}"
  case "${scenario}" in
    empty) ;;
    offline-order)
      printf '%s\n' 'kes:101' 'kes:102' ;;
    local-order)
      printf '%s\n' 'kes:104' ;;
    local-delete|light-empty) ;;
    light-statuses)
      printf '%s\n' 'kes:201' 'kes:202' ;;
    light-error)
      printf '%s\n' 'action:waitToProceed' 'kes:202' ;;
    *) fail "unknown event scenario: ${scenario}" ;;
  esac >> "${output_file}"
  printf '%s\n' \
    'action:waitToProceed' 'menu:pool:h' 'menu:main:q' \
    'exit:0:CNTools closed!' >> "${output_file}"
}

extract_action_output() {
  local full_output="$1" action_output="$2"

  [[ "$(grep -c '^__CNTOOLS_POOL_LIST_BEGIN__$' "${full_output}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_POOL_LIST_END__$' "${full_output}" || true)" == 1 ]] ||
    fail 'pool-list output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_POOL_LIST_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_POOL_LIST_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source the controller and the two definition-oriented legacy helper units
# whose current cache and registration behavior this test freezes.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=../../scripts/common-helper-scripts/lib/env.library
. "${ENV_LIBRARY}"
# shellcheck source=/dev/null
. "${LEGACY_SELECTION_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

cntools_compatibility_dispatch_action() (
  local private_root="" context_file="" result_file="" action_status=0

  [[ "${1:-}" == pool.list && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/pool-list-test-dispatch.XXXXXXXX")" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" ||
    return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  rm -f -- "${result_file}" "${context_file}" >/dev/null 2>&1 ||
    action_status=70
  rmdir -- "${private_root}" >/dev/null 2>&1 || action_status=70
  return "${action_status}"
)

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${level}" "$@" ;;
  esac
}

clear() { :; }
tput() { :; }
getEpoch() { printf '75\n'; }
timeUntilNextEpoch() { printf '0\n'; }
getSlotTipRef() { printf '0\n'; }
slotInterval() { printf '20\n'; }
getPriceInfo() { price_now=""; }
getNodeMetrics() { :; }
updateProtocolParams() { :; }
timeLeft() {
  case "${1:-}" in
    50) printf '00:00:50' ;;
    100) printf '00:01:40' ;;
    500) printf '00:08:20' ;;
    *) printf '00:00:00' ;;
  esac
}

kesExpiration() {
  local start="${1:-<missing>}"

  printf 'kes:%s\n' "${start}" >> "${EVENT_LOG:?}"
  kes_expiration='2030-01-02 03:04:05 UTC'
  case "${start}" in
    '<missing>') return 1 ;;
    101) expiration_time_sec_diff=100 ;;
    102) expiration_time_sec_diff=-50 ;;
    201) expiration_time_sec_diff=500 ;;
    104|202) expiration_time_sec_diff=2000 ;;
    *) fail "unexpected KES start period: ${start}" ;;
  esac
  return 0
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[n] New') menu=pool ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  index=0
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == pool:l ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_POOL_LIST_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

waitToProceed() {
  WAIT_COUNT=$((WAIT_COUNT + 1))
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${WAIT_COUNT}" == "${EXPECTED_WAITS}" ]]; then
    printf '__CNTOOLS_POOL_LIST_END__\n'
    CAPTURE_ACTIVE=N
  fi
  return 0
}

myExit() {
  local status="${1:-0}" message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'pool-list traversal did not consume all choices'
  exit "${status}"
}

write_expected_cli() {
  local scenario="$1" pool_root="$2" output_file="$3"
  local name="" cold=""
  local -a names=()

  : > "${output_file}"
  case "${scenario}" in
    empty) return 0 ;;
    offline-order) names=(a-no-cert m-alert z-encrypted) ;;
    local-order) names=(a-missing-kes b-normal) ;;
    local-delete) names=(a-no-cert) ;;
    light-statuses) names=(a-registered b-retiring c-retired d-empty) ;;
    light-error) names=(a-error b-ok) ;;
    light-empty) names=(a-empty) ;;
    *) fail "unknown CLI scenario: ${scenario}" ;;
  esac
  for name in "${names[@]}"; do
    cold="${pool_root}/${name}/cold.vkey"
    printf 'cardano-cli\tlatest\tstake-pool\tid\t--cold-verification-key-file\t%s\t--output-format\thex\n' \
      "${cold}" >> "${output_file}"
    printf 'cardano-cli\tlatest\tstake-pool\tid\t--cold-verification-key-file\t%s\n' \
      "${cold}" >> "${output_file}"
  done
}

write_expected_curl() {
  local scenario="$1" output_file="$2"

  write_expected_direct_curl public "${scenario}" "${output_file}"
}

run_case() {
  local scenario="$1" mode="$2"
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local pool_root="${runtime_root}/pool"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local cli_log="${capture_root}/cli"
  local expected_cli="${capture_root}/expected.cli"
  local curl_log="${capture_root}/curl"
  local expected_curl="${capture_root}/expected.curl"
  local blocked_log="${capture_root}/blocked"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${runtime_root}/wallet" "${pool_root}" "${capture_root}"
  prepare_fixture "${scenario}" "${pool_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"; : > "${cli_log}"; : > "${curl_log}"; : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    export CNTOOLS_POOL_LIST_SCENARIO="${scenario}"
    export CNTOOLS_POOL_LIST_CLI_LOG="${cli_log}"
    export CNTOOLS_POOL_LIST_CURL_LOG="${curl_log}"
    export CNTOOLS_POOL_LIST_BLOCKED_LOG="${blocked_log}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    POOL_FOLDER="${pool_root}"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_ID_FILENAME=pool.id
    POOL_COLDKEY_VK_FILENAME=cold.vkey
    POOL_REGCERT_FILENAME=pool.cert
    POOL_CURRENT_KES_START=kes.start
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 42'
    KOIOS_API=$([[ "${mode}" == LIGHT ]] && printf '%s' "${KOIOS_API_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    ADVANCED_MODE=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    KES_ALERT_PERIOD=200
    KES_WARNING_PERIOD=1000
    price_now=""
    slotnum=0
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE=N
    WAIT_COUNT=0
    EXPECTED_WAITS=$([[ "${scenario}" == light-error ]] && printf 2 || printf 1)
    CHOICES=(p l h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_stdout "${scenario}" "${expected_stdout}"
  write_expected_events "${scenario}" "${expected_events}"
  write_expected_cli "${scenario}" "${pool_root}" "${expected_cli}"
  write_expected_curl "${scenario}" "${expected_curl}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" "${scenario} normalized stdout"
  [[ ! -s "${stderr_file}" ]] || fail "${scenario} normalized stderr changed"
  assert_files_equal "${event_log}" "${expected_events}" "${scenario} wait and menu events"
  assert_files_equal "${cli_log}" "${expected_cli}" "${scenario} pool-ID command vectors"
  assert_files_equal "${curl_log}" "${expected_curl}" "${scenario} Koios command vectors"
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} attempted a blocked external command"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after traversal"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "${scenario} public observational runtime tree"
  if [[ "${scenario}" == offline-order || "${scenario}" == local-delete ]]; then
    [[ -f "${pool_root}/a-no-cert/kes.start" &&
       "$(< "${pool_root}/a-no-cert/kes.start")" == 999 ]] ||
      fail "${scenario} public listing mutated the KES-start cache"
  fi
}

write_expected_direct_stdout() {
  local scenario="$1" fixture_scenario="$2" output_file="$3"

  case "${scenario}" in
    direct-invalid-id|direct-malformed|direct-schema-invalid|direct-oversized)
      write_header > "${output_file}"
      printf '\n%s\n\n' \
        "$([[ "${scenario}" == direct-invalid-id ]] && \
          printf 'ERROR: pool identity is unavailable or invalid.' || \
          printf 'KOIOS_API ERROR: pool information is unavailable or invalid.')" \
        >> "${output_file}"
      ;;
    *) write_expected_stdout "${fixture_scenario}" "${output_file}" ;;
  esac
}

write_expected_direct_events() {
  local scenario="$1" fixture_scenario="$2" output_file="$3"

  : > "${output_file}"
  case "${scenario}" in
    direct-invalid-id|direct-malformed|direct-schema-invalid|direct-oversized)
      printf '%s\n' 'action:waitToProceed' ;;
    *)
      case "${fixture_scenario}" in
        empty|local-delete) ;;
        offline-order) printf '%s\n' 'kes:101' 'kes:102' ;;
        local-order) printf '%s\n' 'kes:104' ;;
        light-statuses) printf '%s\n' 'kes:201' 'kes:202' ;;
        light-error) printf '%s\n' 'action:waitToProceed' 'kes:202' ;;
        light-empty) ;;
        *) fail "unknown direct event fixture: ${fixture_scenario}" ;;
      esac
      ;;
  esac >> "${output_file}"
  printf '%s\n' 'action:waitToProceed' >> "${output_file}"
}

write_expected_direct_curl() {
  local scenario="$1" fixture_scenario="$2" output_file="$3" name=""
  local -a names=()

  : > "${output_file}"
  case "${scenario}" in
    direct-malformed|direct-schema-invalid|direct-oversized) names=(a-empty) ;;
    *)
      case "${fixture_scenario}" in
        light-statuses) names=(a-registered b-retiring c-retired d-empty) ;;
        light-error) names=(a-error b-ok) ;;
        light-empty) names=(a-empty) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  for name in "${names[@]}"; do
    printf 'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--connect-timeout\t10\t--max-time\t10\t--fail\t--max-filesize\t262144\t--header\tContent-Type: application/json\t--data\t%s\t--output\t<pool-response>\t--url\t%s/pool_info\n' \
      "{\"_pool_bech32_ids\":[\"$(pool_bech32_for "${name}")\"]}" \
      "${KOIOS_API_FIXTURE}" >> "${output_file}"
  done
}

run_direct_case() {
  local scenario="$1" fixture_scenario="$2" mode="$3"
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local pool_root="${runtime_root}/pool"
  local capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local cli_log="${capture_root}/cli"
  local expected_cli="${capture_root}/expected.cli"
  local curl_log="${capture_root}/curl"
  local expected_curl="${capture_root}/expected.curl"
  local blocked_log="${capture_root}/blocked"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local private_root="${runtime_root}/tmp/direct-private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local status=0 name=""
  local -a names=()

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${runtime_root}/wallet" "${pool_root}" "${capture_root}"
  prepare_fixture "${fixture_scenario}" "${pool_root}"
  case "${fixture_scenario}" in
    empty) names=() ;;
    offline-order) names=(a-no-cert m-alert z-encrypted) ;;
    local-order) names=(a-missing-kes b-normal) ;;
    local-delete) names=(a-no-cert) ;;
    light-statuses) names=(a-registered b-retiring c-retired d-empty) ;;
    light-error) names=(a-error b-ok) ;;
    light-empty) names=(a-empty) ;;
  esac
  if [[ "${scenario}" == direct-cached-0644 ]]; then
    for name in "${names[@]}"; do
      printf '%s\n' "$(pool_hex_for "${name}")" > "${pool_root}/${name}/pool.id"
      printf '%s\n' "$(pool_bech32_for "${name}")" \
        > "${pool_root}/${name}/pool.id-bech32"
      chmod 0644 "${pool_root}/${name}/pool.id" \
        "${pool_root}/${name}/pool.id-bech32"
    done
  elif [[ "${scenario}" == direct-unsafe-cache ]]; then
    printf '%s\n' "$(pool_hex_for a-no-cert)" > "${runtime_root}/outside.id"
    ln -s -- "${runtime_root}/outside.id" "${pool_root}/a-no-cert/pool.id"
  fi
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before direct dispatch"
  : > "${event_log}"; : > "${cli_log}"; : > "${curl_log}"; : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    export CNTOOLS_POOL_LIST_SCENARIO="${scenario}"
    export CNTOOLS_POOL_LIST_CLI_LOG="${cli_log}"
    export CNTOOLS_POOL_LIST_CURL_LOG="${curl_log}"
    export CNTOOLS_POOL_LIST_BLOCKED_LOG="${blocked_log}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    POOL_FOLDER="${pool_root}"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_ID_FILENAME=pool.id
    POOL_COLDKEY_VK_FILENAME=cold.vkey
    POOL_REGCERT_FILENAME=pool.cert
    POOL_CURRENT_KES_START=kes.start
    CCLI=$([[ "${scenario}" == direct-cached-0644 ]] && \
      printf cardano-cli-unavailable || printf cardano-cli)
    NETWORK_IDENTIFIER='--testnet-magic 42'
    KOIOS_API=$([[ "${mode}" == LIGHT ]] && printf '%s' "${KOIOS_API_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CURL_TIMEOUT=10
    CNTOOLS_MODE="${mode}"
    KES_ALERT_PERIOD=200
    KES_WARNING_PERIOD=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE=N
    WAIT_COUNT=0
    EXPECTED_WAITS=99
    if [[ "${mode}" == OFFLINE ]]; then
      curl() {
        printf 'curl-shadowed\n' >> "${blocked_log}"
        return 97
      }
    fi
    mkdir -p -- "${private_root}"
    chmod 0700 "${private_root}"
    write_context "${context_file}" "${mode}" "${runtime_root}/home"
    cntools_dispatcher_run_action \
      "${ACTION_DIRECTORY}" "${context_file}" "${result_file}"
    direct_status=$?
    rm -f -- "${result_file}" "${context_file}"
    rmdir -- "${private_root}"
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} direct dispatch returned ${status}"

  write_expected_direct_stdout \
    "${scenario}" "${fixture_scenario}" "${expected_stdout}"
  : > "${expected_stderr}"
  write_expected_direct_events \
    "${scenario}" "${fixture_scenario}" "${expected_events}"
  if [[ "${scenario}" == direct-cached-0644 ]]; then
    : > "${expected_cli}"
  else
    write_expected_cli "${fixture_scenario}" "${pool_root}" "${expected_cli}"
  fi
  write_expected_direct_curl \
    "${scenario}" "${fixture_scenario}" "${expected_curl}"
  assert_files_equal "${stdout_file}" "${expected_stdout}" \
    "${scenario} direct normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${scenario} direct normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} direct wait and formatting events"
  assert_files_equal "${cli_log}" "${expected_cli}" \
    "${scenario} direct in-memory pool-ID vectors"
  assert_files_equal "${curl_log}" "${expected_curl}" \
    "${scenario} direct bounded Koios vectors"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} used an unavailable/blocked tool"
  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after direct dispatch"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "${scenario} direct observational runtime tree"
}

write_fake_commands
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9

run_case empty OFFLINE
run_case offline-order OFFLINE
run_case local-order LOCAL
run_case local-delete LOCAL
run_case light-statuses LIGHT
run_case light-error LIGHT
run_case light-empty LIGHT

run_direct_case direct-empty empty OFFLINE
run_direct_case direct-offline-observational offline-order OFFLINE
run_direct_case direct-cached-0644 local-delete OFFLINE
run_direct_case direct-unsafe-cache local-delete OFFLINE
run_direct_case direct-local-order local-order LOCAL
run_direct_case direct-light-statuses light-statuses LIGHT
run_direct_case direct-light-error light-error LIGHT
run_direct_case direct-invalid-id local-delete OFFLINE
run_direct_case direct-malformed light-empty LIGHT
run_direct_case direct-schema-invalid light-empty LIGHT
run_direct_case direct-oversized light-empty LIGHT

# Extracted public boundary and explicit legacy-helper quarantine.
[[ "$(grep -c 'cntools_compatibility_dispatch_action pool.list' \
  "${CNTOOLS_SCRIPT}" || true)" == 1 ]] ||
  fail 'public pool-list route does not contain exactly one compatibility call'
[[ "$(grep -c ' >> POOL >> LIST' "${CNTOOLS_SCRIPT}" || true)" == 0 ]] ||
  fail 'legacy pool-list body remains duplicated in the public controller'
grep -Fq '[[ -f "${POOL_FOLDER}/${1}/${POOL_REGCERT_FILENAME}" ]] && return 2 || (rm -f "${POOL_FOLDER}/${1}/${POOL_CURRENT_KES_START}" && return 1)' \
  "${LEGACY_SELECTION_SOURCE}" ||
  fail 'quarantined legacy KES-start deletion helper changed unexpectedly'
grep -Fq 'read -ra pool_info_arr <<< ${pool_info_tsv}' \
  "${LEGACY_SELECTION_SOURCE}" ||
  fail 'quarantined legacy Koios response helper changed unexpectedly'
grep -Fq 'echo ${pool_id} > "${pool_id_file}"' "${ENV_LIBRARY}" ||
  fail 'quarantined legacy pool-ID cache helper changed unexpectedly'
grep -Fq 'Stage 4 compatibility action' "${ACTION_SOURCE}" ||
  fail 'pool-list compatibility action is not active'
grep -Fq 'The action is observational' "${ACTION_SOURCE}" ||
  fail 'pool-list observational contract marker is missing'

printf 'CNTools pool-list characterization/parity passed (7 public + 11 direct hardened cases)\n'
