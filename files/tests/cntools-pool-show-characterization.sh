#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools pool-show characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ENV_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
LEGACY_SELECTION_SOURCE="${LEGACY_ROOT}/020-terminal-selection-security.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/pool/show/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/pool/show"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-pool-show.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
KOIOS_API_FIXTURE='https://koios.example.test/api/v1'
POOL_HEX='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
POOL_BECH32='pool1qqqqqqqqqqqqqqqqqqqqqqqq'
META_HASH_URL='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
META_HASH_OLD='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
META_HASH_NEW='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
META_HASH_LIGHT='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
META_HASH_OFFLINE='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'

cleanup_test() {
  if [[ "${CNTOOLS_POOL_SHOW_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools pool-show test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools pool-show characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp cut find grep head jq readlink sed sort stat wc; do
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

write_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_POOL_SHOW_CLI_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  case "${argument}" in */pool-show-*.????????) normalized="<private-response>" ;; esac' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_POOL_SHOW_CLI_LOG:?}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_POOL_SHOW_CLI_LOG:?}"' \
    'case "$*" in' \
    '  "latest stake-pool id --cold-verification-key-file "*" --output-format hex")' \
    '    [[ "${CNTOOLS_POOL_SHOW_SCENARIO:?}" == direct-invalid-id ]] && printf '\''not-a-pool-id\n'\'' || printf '\''%s\n'\'' "${CNTOOLS_POOL_SHOW_HEX:?}"' \
    '    ;;' \
    '  "latest stake-pool id --cold-verification-key-file "*)' \
    '    [[ "${CNTOOLS_POOL_SHOW_SCENARIO:?}" == direct-invalid-id ]] && printf '\''pool1bad\n'\'' || printf '\''%s\n'\'' "${CNTOOLS_POOL_SHOW_BECH32:?}"' \
    '    ;;' \
    '  "latest stake-pool metadata-hash --pool-metadata-file "*)' \
    '    case "$*" in */alpha/poolmeta.json) printf '\''%s\n'\'' "${CNTOOLS_POOL_SHOW_HASH_OFFLINE:?}" ;; *) printf '\''%s\n'\'' "${CNTOOLS_POOL_SHOW_HASH_URL:?}" ;; esac' \
    '    ;;' \
    '  "query pool-state --stake-pool-id "*)' \
    '    if [[ "${CNTOOLS_POOL_SHOW_SCENARIO:?}" == local-query-error ]]; then' \
    '      printf '\''fixture pool-state failure\n'\'' >&2; exit 7' \
    '    fi' \
    '    if [[ "${CNTOOLS_POOL_SHOW_SCENARIO:?}" == direct-local-malformed ]]; then printf '\''{attacker raw node text\n'\''; exit 0; fi' \
    '    printf '\''{"%s":{"poolParams":{"spsPledge":1000000,"spsMargin":0.025,"spsCost":340000000,"spsRelays":[{"single host name":{"dnsName":"old.relay.test","port":3001}}],"spsOwners":["ownerhash"],"spsAccountId":{"keyHash":"rewardhash"},"spsMetadata":{"url":"https://metadata.example.test/pool.json","hash":"%s"}},"futurePoolParams":{"spsPledge":2000000,"spsMargin":0.03,"spsCost":350000000,"spsRelays":[{"single host address":{"IPv4":"192.0.2.10","port":3002}}],"spsOwners":["ownerhash","newownerhash"],"spsAccountId":{"keyHash":"rewardhash"},"spsMetadata":{"url":"https://metadata.example.test/pool.json","hash":"%s"}},"retiring":77}}\n'\'' "${CNTOOLS_POOL_SHOW_BECH32:?}" "${CNTOOLS_POOL_SHOW_HASH_OLD:?}" "${CNTOOLS_POOL_SHOW_HASH_NEW:?}"' \
    '    ;;' \
    '  "latest query stake-pool-default-vote --spo-verification-key-file "*)' \
    '    if [[ "${CNTOOLS_POOL_SHOW_SCENARIO:?}" == local-vote-fallback ]]; then' \
    '      printf '\''fixture default-vote failure\n'\'' >&2; exit 8' \
    '    fi' \
    '    printf '\''"DefaultNoConfidence"\n'\''' \
    '    ;;' \
    '  "query stake-distribution "*) printf '\''{"%s":{"numerator":1,"denominator":4}}\n'\'' "${CNTOOLS_POOL_SHOW_BECH32:?}" ;;' \
    '  "query kes-period-info --op-cert-file "*) printf '\''node response\n{"qKesNodeStateOperationalCertificateNumber":4}\n'\'' ;;' \
    '  *) printf '\''unexpected cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''curl'\'' >> "${CNTOOLS_POOL_SHOW_CURL_LOG:?}"' \
    'output="" previous="" url="" payload=""' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  if [[ "${previous}" == "-o" ]]; then output="${argument}"; normalized="<metadata-cache>"; fi' \
    '  if [[ "${previous}" == "--output" ]]; then output="${argument}"; normalized="<private-response>"; fi' \
    '  if [[ "${previous}" == "--url" ]]; then url="${argument}"; fi' \
    '  if [[ "${previous}" == "--data" || "${previous}" == "-d" ]]; then payload="${argument}"; fi' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_POOL_SHOW_CURL_LOG:?}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_POOL_SHOW_CURL_LOG:?}"' \
    '[[ -n "${url}" ]] || url="${previous}"' \
    'emit() { if [[ -n "${output}" ]]; then printf '\''%s\n'\'' "$1" > "${output}"; else printf '\''%s\n'\'' "$1"; fi; }' \
    'case "${url}" in' \
    '  "${CNTOOLS_POOL_SHOW_KOIOS_API:?}/pool_info")' \
    '    case "${CNTOOLS_POOL_SHOW_SCENARIO:?}" in' \
    '      light-error) printf '\''fixture Koios timeout\n'\'' >&2; exit 28 ;;' \
    '      direct-light-malformed) emit '\''{attacker raw Koios text'\'' ;;' \
    '      direct-light-oversized)' \
    '        [[ -n "${output}" ]] || exit 96' \
    '        awk '\''BEGIN { printf "[\\\""; for (i=0;i<300000;i++) printf "x"; print "\\\"]" }'\'' > "${output}"' \
    '        ;;' \
    '      direct-light-wrong-id)' \
    '        emit '\''[{"pool_id_bech32":"pool1qqqqqqqqqqqqqqqqqqqqqqqx","active_epoch_no":80,"vrf_key_hash":"vrfhash","margin":0.04,"fixed_cost":340000000,"pledge":3000000,"reward_addr":"rewardhash","owners":[],"relays":[],"meta_url":null,"meta_hash":null,"pool_status":"registered","retiring_epoch":null,"op_cert":null,"op_cert_counter":null,"active_stake":0,"block_count":0,"live_pledge":0,"live_stake":0,"live_delegators":0,"live_saturation":0}]'\''' \
    '        ;;' \
    '      light-empty) emit '\''[]'\'' ;;' \
    '      light-success)' \
    '        printf -v body '\''[{"pool_id_bech32":"%s","active_epoch_no":80,"vrf_key_hash":"vrfhash","margin":0.04,"fixed_cost":340000000,"pledge":3000000,"reward_addr":"rewardhash","owners":["ownerhash"],"relays":[{"dns":"relay.koios.test","port":3001}],"meta_url":"https://metadata.example.test/pool.json","meta_hash":"%s","meta_json":{},"pool_status":"registered","retiring_epoch":null,"op_cert":"opcert","op_cert_counter":5,"active_stake":4000000,"block_count":12,"live_pledge":2500000,"live_stake":5000000,"live_delegators":9,"live_saturation":42.5}]'\'' "${CNTOOLS_POOL_SHOW_BECH32:?}" "${CNTOOLS_POOL_SHOW_HASH_LIGHT:?}"' \
    '        emit "${body}"' \
    '        ;;' \
    '      *) printf '\''unexpected Koios scenario\n'\'' >&2; exit 96 ;;' \
    '    esac' \
    '    ;;' \
    '  "${CNTOOLS_POOL_SHOW_KOIOS_API:?}/pool_calidus_keys?pool_id_bech32=eq.${CNTOOLS_POOL_SHOW_BECH32:?}")' \
    '    emit '\''[{"pool_status":"registered","calidus_id_bech32":"calidus1fixture","epoch_no":74,"block_time":1704164645}]'\''' \
    '    ;;' \
    '  https://metadata.example.test/pool.json)' \
    '    [[ -n "${output}" ]] || exit 96' \
    '    printf '\''%s\n'\'' '\''{"name":"Remote Name","ticker":"REM","homepage":"https://remote.example.test","description":"Remote metadata"}'\'' > "${output}"' \
    '    ;;' \
    '  *) printf '\''unexpected curl URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/curl"
  chmod 0755 "${FAKE_BIN}/curl"

  for command_name in wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_POOL_SHOW_BLOCKED_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_POOL_SHOW_BLOCKED_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_POOL_SHOW_BLOCKED_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

prepare_fixture() {
  local scenario="$1"
  local pool_root="$2"
  local wallet_root="$3"

  [[ "${scenario}" == empty ]] && return 0
  mkdir -p -- "${pool_root}/alpha" \
    "${wallet_root}/owner-wallet" "${wallet_root}/reward-wallet"
  printf '{"type":"StakePoolVerificationKey_ed25519"}\n' > "${pool_root}/alpha/cold.vkey"
  printf '{}\n' > "${pool_root}/alpha/pool.cert"
  printf '{}\n' > "${pool_root}/alpha/op.cert"
  printf '123\n' > "${pool_root}/alpha/kes.start"
  printf 'ownerhash\n' > "${wallet_root}/owner-wallet/reward.addr"
  printf 'rewardhash\n' > "${wallet_root}/reward-wallet/reward.addr"
  printf '%s\n' \
    '{"name":"Offline Name","ticker":"OFF","homepage":"https://offline.example.test","description":"Offline metadata"}' \
    > "${pool_root}/alpha/poolmeta.json"
  jq -nS '
    {
      json_url:"https://metadata.example.test/pool.json",
      pledgeADA:123.456789,
      margin:3.5,
      costADA:340,
      pledgeWallet:"owner-wallet",
      rewardWallet:"reward-wallet",
      relays:[
        {type:"DNS_A",address:"relay.offline.test",port:3001},
        {type:"OTHER",address:"ignored",port:0}
      ]
    }
  ' > "${pool_root}/alpha/pool.config"
}

write_header() {
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> POOL >> SHOW' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
}

write_metadata() {
  printf '%s\n' \
    'Metadata' \
    '  Name                : Remote Name' \
    '  Ticker              : REM' \
    '  Homepage            : https://remote.example.test' \
    '  Description         : Remote metadata' \
    '  URL                 : https://metadata.example.test/pool.json' \
    "  Hash URL            : ${META_HASH_URL}"
}

write_expected_stdout() {
  local scenario="$1"
  local output_file="$2"

  write_header > "${output_file}"
  case "${scenario}" in
    empty)
      printf '\n%s\n' 'No pools available!' >> "${output_file}"
      ;;
    selection-fail|selection-cancel)
      printf '%s\n' \
        'OFFLINE MODE: CNTools started in offline mode, locally saved info shown!' \
        >> "${output_file}"
      ;;
    offline-success)
      printf '%s\n' \
        'OFFLINE MODE: CNTools started in offline mode, locally saved info shown!' \
        '' \
        'Pool Name             : alpha' \
        "ID (hex)              : ${POOL_HEX}" \
        "ID (bech32)           : ${POOL_BECH32}" \
        'Registered            : status unavailable in offline mode' \
        'Metadata' \
        '  Name                : Offline Name' \
        '  Ticker              : OFF' \
        '  Homepage            : https://offline.example.test' \
        '  Description         : Offline metadata' \
        '  URL                 : https://metadata.example.test/pool.json' \
        "  Hash                : ${META_HASH_OFFLINE}" \
        'Pledge                : 123.456789 ADA' \
        'Margin                : 3.5 %' \
        'Cost                  : 340 ADA' \
        'Owner Wallet          : owner-wallet (primary only, use online mode for multi-owner)' \
        'Reward Wallet         : reward-wallet' \
        'Relay(s)              : relay.offline.test:3001' \
        '                      : unknown type (only IPv4/v6/DNS supported in CNTools)' \
        >> "${output_file}"
      ;;
    local-query-error)
      printf '%s\n' \
        'Querying pool parameters from node, can take a while...' \
        '' \
        'ERROR: pool-state query failed: fixture pool-state failure' \
        >> "${output_file}"
      ;;
    local-success|local-vote-fallback)
      printf '%s\n' \
        'Querying pool parameters from node, can take a while...' \
        '' \
        '' \
        'Pool Name             : alpha' \
        >> "${output_file}"
      printf '%s\n' \
        "ID (hex)              : ${POOL_HEX}" \
        "ID (bech32)           : ${POOL_BECH32}" \
        'Registered            : Yes - Retiring in epoch 77' \
        >> "${output_file}"
      if [[ "${scenario}" == local-success ]]; then
        printf '%s\n' 'Default vote          : NoConfidence' >> "${output_file}"
      fi
      write_metadata >> "${output_file}"
      printf '%s\n' \
        "  Hash Ledger   (old) : ${META_HASH_OLD}" \
        "  Hash Ledger   (new) : ${META_HASH_NEW}" \
        'Pledge          (new) : 2 ADA (4 USD)' \
        'Margin          (new) : 3 %' \
        'Cost            (new) : 350 ADA' \
        '                        Relay(s) updated, showing latest registered' \
        'Relay(s)              : 192.0.2.10:3002' \
        '                        Owner(s) updated, showing latest registered' \
        'Owner(s)              : owner-wallet' \
        '                      : newownerhash' \
        'Reward wallet         : reward-wallet' \
        'Stake distribution    : 25 %' \
        'KES counter           : 4 - use counter 5 for rotation in offline mode.' \
        'KES expiration date   : 2030-01-02 03:04:05 UTC - ALERT! 00:01:40 until expiration' \
        >> "${output_file}"
      ;;
    light-error)
      printf '%s\n' \
        '' \
        '> Querying Koios API for pool information (some data can have a small delay)' \
        '' \
        'KOIOS_API ERROR: fixture Koios timeout' \
        >> "${output_file}"
      ;;
    light-empty)
      printf '%s\n' \
        '' \
        '> Querying Koios API for pool information (some data can have a small delay)' \
        '' \
        'Pool Name             : alpha' \
        "ID (hex)              : ${POOL_HEX}" \
        "ID (bech32)           : ${POOL_BECH32}" \
        'Registered            : No' \
        >> "${output_file}"
      ;;
    light-success)
      printf '%s\n' \
        '' \
        '> Querying Koios API for pool information (some data can have a small delay)' \
        '' \
        'Pool modified recently, displaying latest registration update.' \
        '' \
        'Pool Name             : alpha' \
        "ID (hex)              : ${POOL_HEX}" \
        "ID (bech32)           : ${POOL_BECH32}" \
        'Registered            : Yes' \
        >> "${output_file}"
      write_metadata >> "${output_file}"
      printf '%s\n' \
        "  Hash Ledger         : ${META_HASH_LIGHT}" \
        'Pledge                : 3 ADA (6 USD)' \
        'Live Pledge           : 2.5 ADA (5 USD)' \
        'Margin                : 4 %' \
        'Cost                  : 340 ADA' \
        'Relay(s)              : relay.koios.test:3001' \
        'Owner(s)              : owner-wallet' \
        'Reward wallet         : reward-wallet' \
        'Active Stake          : 4 ADA' \
        'Lifetime Blocks       : 12' \
        'Live Stake            : 5 ADA' \
        'Delegators            : 9 (incl owners)' \
        'Saturation            : 42.5 %' \
        'KES counter           : 5 - use counter 6 for rotation in offline mode.' \
        'KES expiration date   : 2030-01-02 03:04:05 UTC - WARNING! 00:08:20 until expiration' \
        'Calidus Key' \
        '  Status              : Registered epoch 74 (2024-01-02 03:04:05 UTC)' \
        '  Id                  : calidus1fixture' \
        >> "${output_file}"
      ;;
    *) fail "unknown expected stdout scenario: ${scenario}" ;;
  esac
}

write_expected_events() {
  local scenario="$1"
  local output_file="$2"

  printf '%s\n' 'menu:main:p' 'menu:pool:s' \
    'action:compatibility-dispatch' > "${output_file}"
  case "${scenario}" in
    empty) ;;
    selection-fail)
      printf '%s\n' 'terminal:sc' 'selection:1' 'terminal:rc' 'terminal:ed' ;;
    selection-cancel)
      printf '%s\n' 'terminal:sc' 'selection:2' 'terminal:rc' 'terminal:ed' ;;
    offline-success)
      printf '%s\n' \
        'terminal:sc' 'selection:0' 'terminal:rc' 'terminal:ed' ;;
    local-query-error)
      printf '%s\n' \
        'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' 'terminal:sc' \
        'terminal:rc' 'terminal:ed' ;;
    local-success|local-vote-fallback)
      printf '%s\n' \
        'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' 'terminal:sc' \
        'terminal:rc' 'terminal:ed' \
        'price:2000000' 'runtime:getNodeMetrics' 'kes:123' ;;
    light-error|light-empty)
      printf '%s\n' \
        'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' ;;
    light-success)
      printf '%s\n' \
        'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' \
        'price:3000000' 'price:2500000' 'kes:123' ;;
    *) fail "unknown event scenario: ${scenario}" ;;
  esac >> "${output_file}"
  [[ "${scenario}" == selection-cancel ]] ||
    printf '%s\n' 'action:waitToProceed' >> "${output_file}"
  printf '%s\n' \
    'menu:pool:h' 'menu:main:q' 'exit:0:CNTools closed!' \
    >> "${output_file}"
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"

  [[ "$(grep -c '^__CNTOOLS_POOL_SHOW_BEGIN__$' "${full_output}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_POOL_SHOW_END__$' "${full_output}" || true)" == 1 ]] ||
    fail 'pool-show output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_POOL_SHOW_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_POOL_SHOW_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source only definition-oriented legacy units needed by this focused path.
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

  [[ "${1:-}" == pool.show && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/pool-show-test-dispatch.XXXXXXXX")" || return 70
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
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_POOL_SHOW_END__\n'
    CAPTURE_ACTIVE=N
    : > "${CAPTURE_DONE_FILE:?}"
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

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${END_ON_CLEAR:-N}" == Y ]]; then
    printf '__CNTOOLS_POOL_SHOW_END__\n'
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
  fi
}

tput() {
  [[ "${DIRECT_ACTIVE:-N}" == Y ||
     ( "${CAPTURE_ACTIVE:-N}" == Y &&
       ! -f "${CAPTURE_DONE_FILE:-/nonexistent}" ) ]] &&
    printf 'terminal:%s\n' "$*" >> "${EVENT_LOG:?}"
}

getEpoch() { printf '75\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() {
  case "${1:-}" in
    100) printf '00:01:40' ;;
    500) printf '00:08:20' ;;
    *) printf '00:00:00' ;;
  esac
}
getSlotTipRef() { printf '0\n'; }
slotInterval() { printf '20\n'; }
updateProtocolParams() { :; }

getPriceInfo() {
  if [[ "${DIRECT_ACTIVE:-N}" == Y ||
        ( "${CAPTURE_ACTIVE:-N}" == Y &&
          ! -f "${CAPTURE_DONE_FILE:-/nonexistent}" ) ]]; then
    printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
  fi
  price_now=""
}

getNodeMetrics() {
  if [[ "${DIRECT_ACTIVE:-N}" == Y ||
        ( "${CAPTURE_ACTIVE:-N}" == Y &&
          ! -f "${CAPTURE_DONE_FILE:-/nonexistent}" ) ]]; then
    printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"
  fi
}

getPriceString() {
  local value="${1:-0}"

  printf 'price:%s\n' "${value}" >> "${EVENT_LOG:?}"
  case "${value}" in
    2000000) price_str=' (4 USD)' ;;
    2500000) price_str=' (5 USD)' ;;
    3000000) price_str=' (6 USD)' ;;
    *) fail "unexpected pool-show price input: ${value}" ;;
  esac
}

formatLovelace() {
  case "${1:-}" in
    1000000) printf '1' ;;
    2000000) printf '2' ;;
    2500000) printf '2.5' ;;
    3000000) printf '3' ;;
    4000000) printf '4' ;;
    5000000) printf '5' ;;
    123456789) printf '123.456789' ;;
    340000000) printf '340' ;;
    350000000) printf '350' ;;
    *) fail "unexpected pool-show lovelace input: ${1:-<empty>}" ;;
  esac
}

ADAToLovelace() {
  case "${1:-}" in
    123.456789) printf '123456789\n' ;;
    340) printf '340000000\n' ;;
    *) fail "unexpected pool-show ADA input: ${1:-<empty>}" ;;
  esac
}

fractionToPCT() {
  case "${1:-}" in
    0.0300) printf '3\n' ;;
    0.0400) printf '4\n' ;;
    *) fail "unexpected pool-show fraction: ${1:-<empty>}" ;;
  esac
}

validateDecimalNbr() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

kesExpiration() {
  printf 'kes:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  kes_expiration='2030-01-02 03:04:05 UTC'
  if [[ "${CNTOOLS_MODE}" == LOCAL ]]; then
    expiration_time_sec_diff=100
  else
    expiration_time_sec_diff=500
  fi
  return 0
}

poolCalidusInfo() {
  printf 'calidus:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  pc_epoch_no=74
  pc_block_time=1704164645
  pc_id=calidus1fixture
  return 2
}

selectPool() {
  [[ "${1:-}" == all && "${2:-}" == pool.id ]] ||
    fail 'pool-show selection arguments changed'
  case "${CNTOOLS_POOL_SHOW_SCENARIO:?}" in
    selection-fail)
      printf 'selection:1\n' >> "${EVENT_LOG:?}"
      return 1
      ;;
    selection-cancel)
      printf 'selection:2\n' >> "${EVENT_LOG:?}"
      END_ON_CLEAR=Y
      return 2
      ;;
    *)
      printf 'selection:0\n' >> "${EVENT_LOG:?}"
      pool_name=alpha
      return 0
      ;;
  esac
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
      if [[ "${menu}:${choice}" == pool:s ]]; then
        CAPTURE_ACTIVE=Y
        rm -f -- "${CAPTURE_DONE_FILE:-/nonexistent}"
        printf '__CNTOOLS_POOL_SHOW_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${DIRECT_ACTIVE:-N}" != Y &&
        "${COMPATIBILITY_CAPTURE:-N}" != Y &&
        "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_POOL_SHOW_END__\n'
    CAPTURE_ACTIVE=N
  fi
  return 0
}

myExit() {
  local status="${1:-0}"
  local message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'pool-show traversal did not consume all choices'
  exit "${status}"
}

write_expected_cli() {
  local scenario="$1"
  local pool_root="$2"
  local output_file="$3"
  local cold="${pool_root}/alpha/cold.vkey"
  local metadata_cache="${pool_root%/pool}/tmp/url_poolmeta.json"

  : > "${output_file}"
  case "${scenario}" in
    empty|selection-fail|selection-cancel) return 0 ;;
  esac
  printf 'cardano-cli\tlatest\tstake-pool\tid\t--cold-verification-key-file\t%s\t--output-format\thex\n' \
    "${cold}" >> "${output_file}"
  printf 'cardano-cli\tlatest\tstake-pool\tid\t--cold-verification-key-file\t%s\n' \
    "${cold}" >> "${output_file}"
  case "${scenario}" in
    offline-success)
      printf 'cardano-cli\tlatest\tstake-pool\tmetadata-hash\t--pool-metadata-file\t%s/alpha/poolmeta.json\n' \
        "${pool_root}" >> "${output_file}"
      ;;
    local-query-error)
      printf 'cardano-cli\tquery\tpool-state\t--stake-pool-id\t%s\t--testnet-magic\t42\n' \
        "${POOL_BECH32}" >> "${output_file}"
      ;;
    local-success|local-vote-fallback)
      printf 'cardano-cli\tquery\tpool-state\t--stake-pool-id\t%s\t--testnet-magic\t42\n' \
        "${POOL_BECH32}" >> "${output_file}"
      printf 'cardano-cli\tlatest\tquery\tstake-pool-default-vote\t--spo-verification-key-file\t%s\t--testnet-magic\t42\n' \
        "${cold}" >> "${output_file}"
      printf 'cardano-cli\tlatest\tstake-pool\tmetadata-hash\t--pool-metadata-file\t%s\n' \
        '<private-response>' >> "${output_file}"
      printf 'cardano-cli\tquery\tstake-distribution\t--testnet-magic\t42\n' \
        >> "${output_file}"
      printf 'cardano-cli\tquery\tkes-period-info\t--op-cert-file\t%s/alpha/op.cert\t--testnet-magic\t42\n' \
        "${pool_root}" >> "${output_file}"
      ;;
    light-success)
      printf 'cardano-cli\tlatest\tstake-pool\tmetadata-hash\t--pool-metadata-file\t%s\n' \
        '<private-response>' >> "${output_file}"
      ;;
    light-error|light-empty) ;;
    *) fail "unknown CLI scenario: ${scenario}" ;;
  esac
}

write_expected_curl() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    local-success|local-vote-fallback)
      printf 'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--connect-timeout\t5\t--max-time\t5\t--fail\t--max-filesize\t16384\t--header\tAccept: application/json\t--output\t<private-response>\t--url\thttps://metadata.example.test/pool.json\n' \
        >> "${output_file}"
      ;;
    light-error|light-empty|light-success)
      printf 'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--connect-timeout\t5\t--max-time\t5\t--fail\t--max-filesize\t262144\t--header\tAccept: application/json\t--header\tContent-Type: application/json\t--data\t%s\t--output\t<private-response>\t--url\t%s/pool_info\n' \
        "{\"_pool_bech32_ids\":[\"${POOL_BECH32}\"]}" "${KOIOS_API_FIXTURE}" \
        >> "${output_file}"
      if [[ "${scenario}" == light-success ]]; then
        printf 'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--connect-timeout\t5\t--max-time\t5\t--fail\t--max-filesize\t16384\t--header\tAccept: application/json\t--output\t<private-response>\t--url\thttps://metadata.example.test/pool.json\n' \
          >> "${output_file}"
        printf 'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--connect-timeout\t5\t--max-time\t5\t--fail\t--max-filesize\t65536\t--header\tAccept: application/json\t--request\tPOST\t--output\t<private-response>\t--url\t%s/pool_calidus_keys?pool_id_bech32=eq.%s\n' \
          "${KOIOS_API_FIXTURE}" "${POOL_BECH32}" \
          >> "${output_file}"
      fi
      ;;
    empty|selection-fail|selection-cancel|offline-success|local-query-error) ;;
    *) fail "unknown curl scenario: ${scenario}" ;;
  esac
}

run_case() {
  local scenario="$1"
  local mode="$2"
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local pool_root="${runtime_root}/pool"
  local wallet_root="${runtime_root}/wallet"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local cli_log="${capture_root}/cli"
  local expected_cli="${capture_root}/expected.cli"
  local curl_log="${capture_root}/curl"
  local expected_curl="${capture_root}/expected.curl"
  local capture_done_file="${capture_root}/done"
  local blocked_log="${capture_root}/blocked"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local filtered_after="${capture_root}/after.filtered.tree"
  local status=0 cache_file=""

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${pool_root}" "${wallet_root}" "${capture_root}"
  prepare_fixture "${scenario}" "${pool_root}" "${wallet_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"
  : > "${cli_log}"
  : > "${curl_log}"
  : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    export CNTOOLS_POOL_SHOW_SCENARIO="${scenario}"
    export CNTOOLS_POOL_SHOW_CLI_LOG="${cli_log}"
    export CNTOOLS_POOL_SHOW_CURL_LOG="${curl_log}"
    export CNTOOLS_POOL_SHOW_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_POOL_SHOW_KOIOS_API="${KOIOS_API_FIXTURE}"
    export CNTOOLS_POOL_SHOW_HEX="${POOL_HEX}"
    export CNTOOLS_POOL_SHOW_BECH32="${POOL_BECH32}"
    export CNTOOLS_POOL_SHOW_HASH_URL="${META_HASH_URL}"
    export CNTOOLS_POOL_SHOW_HASH_OLD="${META_HASH_OLD}"
    export CNTOOLS_POOL_SHOW_HASH_NEW="${META_HASH_NEW}"
    export CNTOOLS_POOL_SHOW_HASH_LIGHT="${META_HASH_LIGHT}"
    export CNTOOLS_POOL_SHOW_HASH_OFFLINE="${META_HASH_OFFLINE}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    POOL_FOLDER="${pool_root}"
    WALLET_FOLDER="${wallet_root}"
    POOL_ID_FILENAME=pool.id
    POOL_COLDKEY_VK_FILENAME=cold.vkey
    POOL_REGCERT_FILENAME=pool.cert
    POOL_CURRENT_KES_START=kes.start
    POOL_CONFIG_FILENAME=pool.config
    POOL_OPCERT_FILENAME=op.cert
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 42'
    KOIOS_API=$([[ "${mode}" == LIGHT ]] && printf '%s' "${KOIOS_API_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CURL_TIMEOUT=5
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    ADVANCED_MODE=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    CURRENCY=usd
    KES_ALERT_PERIOD=200
    KES_WARNING_PERIOD=1000
    MAX_KES_EVOLUTIONS=129600
    price_now=""
    slotnum=0
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_DONE_FILE="${capture_done_file}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    COMPATIBILITY_CAPTURE=Y
    CHOICES=(p s h q)
    CHOICE_CURSOR=0
    unset pool_default_vote p_active_epoch_no remaining_kes_periods
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_direct_stdout "${scenario}" "${expected_stdout}"
  : > "${expected_stderr}"
  write_expected_events "${scenario}" "${expected_events}"
  write_expected_cli "${scenario}" "${pool_root}" "${expected_cli}"
  write_expected_curl "${scenario}" "${expected_curl}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "${scenario} normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${scenario} normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} terminal, selection, wait, formatting, and navigation events"
  assert_files_equal "${cli_log}" "${expected_cli}" \
    "${scenario} cardano-cli vectors"
  assert_files_equal "${curl_log}" "${expected_curl}" \
    "${scenario} Koios and metadata vectors"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} attempted blocked network/tool execution: $(< "${blocked_log}")"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after traversal"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "${scenario} persistent runtime tree"
  if [[ "${scenario}" == empty ]]; then
    [[ ! -e "${wallet_root}/owner-wallet/reward.addr" &&
       ! -e "${wallet_root}/reward-wallet/reward.addr" ]] ||
      fail 'empty scenario created a wallet address cache'
  else
    [[ "$(< "${wallet_root}/owner-wallet/reward.addr")" == ownerhash &&
       "$(< "${wallet_root}/reward-wallet/reward.addr")" == rewardhash ]] ||
      fail "${scenario} wallet address cache changed"
  fi
}

write_expected_direct_stdout() {
  local scenario="$1" output_file="$2"

  case "${scenario}" in
    local-query-error|direct-local-malformed)
      write_header > "${output_file}"
      printf '%s\n' \
        'Querying pool parameters from node, can take a while...' \
        '' \
        'ERROR: local pool information is unavailable or invalid.' \
        >> "${output_file}"
      ;;
    light-error|direct-light-malformed|direct-light-oversized|direct-light-wrong-id)
      write_header > "${output_file}"
      printf '%s\n' \
        '' \
        '> Querying Koios API for pool information (some data can have a small delay)' \
        '' \
        'KOIOS_API ERROR: pool information is unavailable or invalid.' \
        >> "${output_file}"
      ;;
    direct-invalid-id)
      write_header > "${output_file}"
      printf '%s\n' \
        'OFFLINE MODE: CNTools started in offline mode, locally saved info shown!' \
        'ERROR: pool identity is unavailable or invalid.' \
        >> "${output_file}"
      ;;
    direct-offline-unsafe-url)
      write_header > "${output_file}"
      printf '%s\n' \
        'OFFLINE MODE: CNTools started in offline mode, locally saved info shown!' \
        '' \
        'Pool Name             : alpha' \
        "ID (hex)              : ${POOL_HEX}" \
        "ID (bech32)           : ${POOL_BECH32}" \
        'Registered            : status unavailable in offline mode' \
        'ERROR: local pool configuration is unavailable or invalid.' \
        >> "${output_file}"
      ;;
    *) write_expected_stdout "${scenario}" "${output_file}" ;;
  esac
}

write_expected_direct_events() {
  local scenario="$1" output_file="$2"

  : > "${output_file}"
  case "${scenario}" in
    empty) printf '%s\n' 'action:waitToProceed' ;;
    selection-fail)
      printf '%s\n' 'terminal:sc' 'selection:1' 'terminal:rc' \
        'terminal:ed' 'action:waitToProceed'
      ;;
    selection-cancel)
      printf '%s\n' 'terminal:sc' 'selection:2' 'terminal:rc' 'terminal:ed'
      ;;
    offline-success|direct-offline-unsafe-url)
      printf '%s\n' 'terminal:sc' 'selection:0' 'terminal:rc' \
        'terminal:ed' 'action:waitToProceed'
      ;;
    local-query-error|direct-local-malformed)
      printf '%s\n' 'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' 'terminal:sc' 'terminal:rc' \
        'terminal:ed' 'action:waitToProceed'
      ;;
    local-success|local-vote-fallback)
      printf '%s\n' 'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' 'terminal:sc' 'terminal:rc' \
        'terminal:ed' 'price:2000000' 'runtime:getNodeMetrics' 'kes:123' \
        'action:waitToProceed'
      ;;
    light-error|light-empty|direct-light-malformed|direct-light-oversized|direct-light-wrong-id)
      printf '%s\n' 'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' 'action:waitToProceed'
      ;;
    light-success)
      printf '%s\n' 'runtime:getPriceInfo' 'terminal:sc' 'selection:0' \
        'terminal:rc' 'terminal:ed' 'price:3000000' 'price:2500000' \
        'kes:123' 'action:waitToProceed'
      ;;
    direct-invalid-id)
      printf '%s\n' 'terminal:sc' 'selection:0' 'terminal:rc' \
        'terminal:ed' 'action:waitToProceed'
      ;;
    *) fail "unknown direct event scenario: ${scenario}" ;;
  esac > "${output_file}"
}

assert_direct_command_security() {
  local scenario="$1" cli_log="$2" curl_log="$3"

  if [[ "${scenario}" != empty && "${scenario}" != selection-fail &&
        "${scenario}" != selection-cancel &&
        "${scenario}" != direct-unsafe-root ]]; then
    grep -Fq $'cardano-cli\tlatest\tstake-pool\tid\t--cold-verification-key-file' \
      "${cli_log}" || fail "${scenario} direct ID argv was not preserved"
  fi
  if [[ "${scenario}" == light-* || "${scenario}" == direct-light-* ]]; then
    grep -Fq $'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https' \
      "${curl_log}" || fail "${scenario} direct curl hardening changed"
    grep -Fq $'\t--max-filesize\t262144\t' "${curl_log}" ||
      fail "${scenario} direct Koios bound changed"
    grep -Fq $'\t--output\t<private-response>\t--url\thttps://koios.example.test/' \
      "${curl_log}" || fail "${scenario} direct private response vector changed"
  fi
  if [[ "${scenario}" == offline-success ]]; then
    [[ ! -s "${curl_log}" ]] || fail 'offline direct case attempted network access'
  fi
}

run_direct_case() {
  local scenario="$1" mode="$2" fixture_scenario="${3:-$1}"
  local case_root="${TEST_ROOT}/cases/direct-${scenario}"
  local runtime_root="${case_root}/runtime"
  local pool_root="${runtime_root}/pool" wallet_root="${runtime_root}/wallet"
  local capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout" stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local cli_log="${capture_root}/cli" curl_log="${capture_root}/curl"
  local blocked_log="${capture_root}/blocked"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local private_root="${runtime_root}/tmp/direct-private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local status=0 expected_status=0 configured_pool_root="${pool_root}"

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${pool_root}" "${wallet_root}" "${capture_root}"
  prepare_fixture "${fixture_scenario}" "${pool_root}" "${wallet_root}"
  if [[ "${scenario}" == direct-offline-unsafe-url ]]; then
    jq --arg url 'https://safe.example/\033[31mOWNED' \
      '.json_url = $url' "${pool_root}/alpha/pool.config" \
      > "${pool_root}/alpha/pool.config.new" ||
      fail 'could not build unsafe offline URL fixture'
    mv -- "${pool_root}/alpha/pool.config.new" \
      "${pool_root}/alpha/pool.config"
  fi
  if [[ "${scenario}" == direct-unsafe-root ]]; then
    ln -s -- "${pool_root}" "${runtime_root}/pool-link"
    configured_pool_root="${runtime_root}/pool-link"
    expected_status=70
  fi
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot direct ${scenario} before dispatch"
  : > "${event_log}"; : > "${cli_log}"; : > "${curl_log}"; : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C TZ=UTC
    export CNTOOLS_POOL_SHOW_SCENARIO="${scenario}"
    export CNTOOLS_POOL_SHOW_CLI_LOG="${cli_log}"
    export CNTOOLS_POOL_SHOW_CURL_LOG="${curl_log}"
    export CNTOOLS_POOL_SHOW_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_POOL_SHOW_KOIOS_API="${KOIOS_API_FIXTURE}"
    export CNTOOLS_POOL_SHOW_HEX="${POOL_HEX}"
    export CNTOOLS_POOL_SHOW_BECH32="${POOL_BECH32}"
    export CNTOOLS_POOL_SHOW_HASH_URL="${META_HASH_URL}"
    export CNTOOLS_POOL_SHOW_HASH_OLD="${META_HASH_OLD}"
    export CNTOOLS_POOL_SHOW_HASH_NEW="${META_HASH_NEW}"
    export CNTOOLS_POOL_SHOW_HASH_LIGHT="${META_HASH_LIGHT}"
    export CNTOOLS_POOL_SHOW_HASH_OFFLINE="${META_HASH_OFFLINE}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    POOL_FOLDER="${configured_pool_root}"
    WALLET_FOLDER="${wallet_root}"
    POOL_ID_FILENAME=pool.id
    POOL_COLDKEY_VK_FILENAME=cold.vkey
    POOL_REGCERT_FILENAME=pool.cert
    POOL_CURRENT_KES_START=kes.start
    POOL_CONFIG_FILENAME=pool.config
    POOL_OPCERT_FILENAME=op.cert
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 42'
    KOIOS_API=$([[ "${mode}" == LIGHT ]] && \
      printf '%s' "${KOIOS_API_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CURL_TIMEOUT=5
    CNTOOLS_MODE="${mode}"
    CURRENCY=usd
    KES_ALERT_PERIOD=200
    KES_WARNING_PERIOD=1000
    MAX_KES_EVOLUTIONS=129600
    price_now=""
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE=N
    DIRECT_ACTIVE=Y
    END_ON_CLEAR=N
    unset pool_default_vote p_active_epoch_no remaining_kes_periods
    mkdir -p -- "${private_root}"
    chmod 0700 "${private_root}"
    write_context "${context_file}" "${mode}" "${runtime_root}/home"
    cntools_dispatcher_run_action \
      "${ACTION_DIRECTORY}" "${context_file}" "${result_file}"
    direct_status=$?
    [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || exit 98
    rm -f -- "${context_file}"
    rmdir -- "${private_root}"
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} direct dispatch returned ${status}, expected ${expected_status}"

  if [[ "${scenario}" == direct-unsafe-root ]]; then
    : > "${expected_stdout}"
    printf '%s\n' 'CNTools pool-show action failed validation.' > "${expected_stderr}"
    : > "${expected_events}"
  else
    write_expected_direct_stdout "${scenario}" "${expected_stdout}"
    : > "${expected_stderr}"
    write_expected_direct_events "${scenario}" "${expected_events}"
  fi
  assert_files_equal "${stdout_file}" "${expected_stdout}" \
    "${scenario} direct normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${scenario} direct normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} direct terminal, wait, and formatting events"
  assert_direct_command_security "${scenario}" "${cli_log}" "${curl_log}"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} direct case attempted blocked execution"
  if [[ "${scenario}" == *malformed* || "${scenario}" == *wrong-id* ||
        "${scenario}" == direct-offline-unsafe-url ]]; then
    ! grep -Eq 'attacker raw|fixture Koios timeout|fixture pool-state failure' \
      "${stdout_file}" "${stderr_file}" ||
      fail "${scenario} reflected an untrusted response"
    ! grep -Fq 'OWNED' "${stdout_file}" "${stderr_file}" ||
      fail "${scenario} reflected an unsafe local value"
  fi
  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot direct ${scenario} after dispatch"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "${scenario} direct observational runtime tree"
}

write_fake_commands
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9

run_case empty OFFLINE
run_case selection-fail OFFLINE
run_case selection-cancel OFFLINE
run_case offline-success OFFLINE
run_case local-query-error LOCAL
run_case local-success LOCAL
run_case local-vote-fallback LOCAL
run_case light-error LIGHT
run_case light-empty LIGHT
run_case light-success LIGHT

run_direct_case empty OFFLINE
run_direct_case selection-fail OFFLINE
run_direct_case selection-cancel OFFLINE
run_direct_case offline-success OFFLINE
run_direct_case local-query-error LOCAL
run_direct_case local-success LOCAL
run_direct_case local-vote-fallback LOCAL
run_direct_case light-error LIGHT
run_direct_case light-empty LIGHT
run_direct_case light-success LIGHT
run_direct_case direct-invalid-id OFFLINE offline-success
run_direct_case direct-offline-unsafe-url OFFLINE offline-success
run_direct_case direct-local-malformed LOCAL local-success
run_direct_case direct-light-malformed LIGHT light-success
run_direct_case direct-light-oversized LIGHT light-success
run_direct_case direct-light-wrong-id LIGHT light-success
run_direct_case direct-unsafe-root OFFLINE offline-success

# Freeze the installed one-call route and quarantine legacy shared helpers.
[[ "$(grep -Ec 'cntools_compatibility_dispatch_action[[:space:]]+pool\.show' \
  "${CNTOOLS_SCRIPT}" || true)" == 1 ]] ||
  fail 'public pool-show route does not contain exactly one compatibility call'
[[ "$(grep -Fc 'println " >> POOL >> SHOW"' "${CNTOOLS_SCRIPT}" || true)" == 0 ]] ||
  fail 'legacy pool-show body remains duplicated in the public controller'
[[ "$(grep -Fc '<<< ${pool_params}' "${CNTOOLS_SCRIPT}" || true)" == 0 ]] ||
  fail 'legacy pool-show unquoted response parsing remains reachable'
[[ "$(grep -Fc 'curl -sL -f -m ${CURL_TIMEOUT} -o "${TMP_DIR}/url_poolmeta.json" ${meta_json_url}' \
  "${CNTOOLS_SCRIPT}" || true)" == 0 ]] ||
  fail 'legacy pool-show metadata fetch remains reachable'
[[ "$(grep -Fc 'Pool modified recently, displaying latest registration update.' \
  "${CNTOOLS_SCRIPT}" || true)" == 0 ]] ||
  fail 'legacy pool-show rendering body remains reachable'
grep -Fq 'read -ra pool_info_arr <<< ${pool_info_tsv}' \
  "${LEGACY_SELECTION_SOURCE}" ||
  fail 'legacy unquoted Koios response split changed before hardening design'
grep -Fq 'echo ${pool_id} > "${pool_id_file}"' "${ENV_LIBRARY}" ||
  fail 'legacy non-atomic pool-ID cache write changed before hardening design'
grep -Fq 'Stage 4 compatibility action for the characterized pool detail view.' \
  "${ACTION_SOURCE}" || fail 'pool-show dedicated compatibility action is missing'
grep -Fq 'this read-only action never materializes cache files.' \
  "${ACTION_SOURCE}" || fail 'pool-show observational contract marker is missing'

printf 'CNTools pool-show characterization/parity passed (10 legacy + 17 direct cases)\n'
