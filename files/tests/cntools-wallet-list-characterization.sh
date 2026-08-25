#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-list characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
GOVERNANCE_QUERY_SOURCE="${LEGACY_ROOT}/030-governance-query.sh"
WALLET_QUERY_SOURCE="${LEGACY_ROOT}/040-address-wallet-query.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/list/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/list"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-list.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
KOIOS_API_FIXTURE="https://koios.invalid/api/v1"
ADDR_A_BASE='addr_test1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
ADDR_A_PAY='addr_test1apppppppppppppppppppppppppppppppppppppp'
ADDR_M_BASE='addr_test1mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm'
ADDR_M_PAY='addr_test1mppppppppppppppppppppppppppppppppppppp'
ADDR_Z_BASE='addr_test1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
ADDR_Z_PAY='addr_test1zppppppppppppppppppppppppppppppppppppppp'
ADDR_LOCAL_BASE='addr_test1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr'
ADDR_LOCAL_PAY='addr_test1rppppppppppppppppppppppppppppppppppppp'
REWARD_LOCAL='stake_test1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr'
ADDR_ALPHA_BASE='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
ADDR_ALPHA_PAY='addr_test1pppppppppppppppppppppppppppppppppppppppp'
REWARD_ALPHA='stake_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
ADDR_ERROR_BASE='addr_test1eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
ADDR_ERROR_PAY='addr_test1eppppppppppppppppppppppppppppppppppppp'
REWARD_ERROR='stake_test1eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
POOL_ID_FIXTURE='pool1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_LIST_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'CNTools wallet-list test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-list characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep head jq readlink sed sort stat tail wc; do
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
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'url="" output="" previous="" endpoint="" argument="" data="" expected_data="" data_count=0' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" == --url ]] && url="${argument}"' \
    '  [[ "${previous}" == --output ]] && output="${argument}"' \
    '  if [[ "${previous}" == --data ]]; then data="${argument}"; data_count=$((data_count + 1)); fi' \
    '  previous="${argument}"' \
    'done' \
    'case "${url}" in' \
    '  "${CNTOOLS_WALLET_KOIOS_API:?}/address_utxos?select=address,tx_hash,tx_index,value,asset_list") endpoint=address; expected_data="${CNTOOLS_WALLET_EXPECT_ADDRESS_PAYLOAD:?}" ;;' \
    '  "${CNTOOLS_WALLET_KOIOS_API:?}/account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit") endpoint=reward; expected_data="${CNTOOLS_WALLET_EXPECT_REWARD_PAYLOAD:?}" ;;' \
    '  *) printf '\''unexpected curl URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    'esac' \
    '[[ "${data_count}" == 1 ]] || { printf '\''expected exactly one --data argument, got %s\n'\'' "${data_count}" >&2; exit 96; }' \
    '[[ "${data}" == "${expected_data}" ]] || { printf '\''unexpected curl payload for %s\n'\'' "${endpoint}" >&2; exit 96; }' \
    'printf '\''curl'\'' >> "${CNTOOLS_WALLET_CURL_LOG:?}"' \
    'for argument in "$@"; do' \
    '  [[ "${argument}" == "${output}" ]] && argument="<${endpoint}-response>"' \
    '  printf '\''\t%s'\'' "${argument}" >> "${CNTOOLS_WALLET_CURL_LOG:?}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_CURL_LOG:?}"' \
    '[[ -n "${output}" ]] || exit 96' \
    'case "${CNTOOLS_WALLET_SCENARIO:?}:${endpoint}" in' \
    '  light-success:address)' \
    '    printf '\''%s\n'\'' '\''address,tx_hash,tx_index,value,asset_list'\'' "${CNTOOLS_WALLET_ADDR_ALPHA_BASE},aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,0,2500000,\"[{\"\"policy_id\"\":\"\"11111111111111111111111111111111111111111111111111111111\"\",\"\"asset_name\"\":\"\"546f6b656e\"\",\"\"quantity\"\":42}]\"" "${CNTOOLS_WALLET_ADDR_ALPHA_PAY},bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,1,500000,\"[]\"" > "${output}"' \
    '    ;;' \
    '  light-success:reward)' \
    '    printf '\''%s\n'\'' '\''stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit'\'' "${CNTOOLS_WALLET_REWARD_ALPHA},registered,${CNTOOLS_WALLET_POOL_ID},drep_always_abstain,1234567,2000000" > "${output}"' \
    '    ;;' \
    '  light-error:address|local-fallback:address)' \
    '    printf '\''simulated Koios timeout\n'\'' >&2' \
    '    exit 28' \
    '    ;;' \
    '  light-malformed:address)' \
    '    printf '\''unexpected_header\nunsafe,data\n'\'' > "${output}"' \
    '    ;;' \
    '  *) printf '\''unexpected curl scenario: %s:%s\n'\'' "${CNTOOLS_WALLET_SCENARIO}" "${endpoint}" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/curl"
  chmod 0755 "${FAKE_BIN}/curl"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'out_file="" previous="" kind=payment argument=""' \
    'for argument in "$@"; do' \
    '  if [[ "${previous}" == "--out-file" ]]; then out_file="${argument}"; break; fi' \
    '  previous="${argument}"' \
    'done' \
    '[[ -n "${out_file}" ]] || exit 96' \
    '[[ " $* " == *" stake-address "* ]] && kind=reward' \
    '[[ "${kind}" != reward && " $* " == *" --stake-verification-key-file "* ]] && kind=base' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_WALLET_CLI_LOG:?}"' \
    'for argument in "$@"; do' \
    '  [[ "${argument}" == "${out_file}" ]] && argument="<${kind}-cache-temp>"' \
    '  printf '\''\t%s'\'' "${argument}" >> "${CNTOOLS_WALLET_CLI_LOG:?}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_CLI_LOG:?}"' \
    'case "${kind}" in' \
    '  base) printf '\''%s\n'\'' "${CNTOOLS_WALLET_ADDR_ALPHA_BASE}" > "${out_file}" ;;' \
    '  payment) printf '\''%s\n'\'' "${CNTOOLS_WALLET_ADDR_ALPHA_PAY}" > "${out_file}" ;;' \
    '  reward) printf '\''%s\n'\'' "${CNTOOLS_WALLET_REWARD_ALPHA}" > "${out_file}" ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  for command_name in wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_WALLET_BLOCKED_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_WALLET_BLOCKED_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_WALLET_BLOCKED_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

write_wallet_keys() {
  local wallet_root="$1"
  local description="$2"

  printf '{"description":"%s Payment Verification Key"}\n' "${description}" \
    > "${wallet_root}/payment.vkey"
  printf '{"description":"%s Stake Verification Key"}\n' "${description}" \
    > "${wallet_root}/stake.vkey"
  chmod 0600 "${wallet_root}/payment.vkey" "${wallet_root}/stake.vkey"
}

write_cached_addresses() {
  local wallet_root="$1"
  local base_address="$2"
  local payment_address="$3"
  local reward_address="$4"

  printf '%s\n' "${base_address}" > "${wallet_root}/base.addr"
  printf '%s\n' "${payment_address}" > "${wallet_root}/payment.addr"
  printf '%s\n' "${reward_address}" > "${wallet_root}/reward.addr"
  chmod 0600 "${wallet_root}/base.addr" "${wallet_root}/payment.addr" \
    "${wallet_root}/reward.addr"
}

prepare_fixture() {
  local scenario="$1"
  local wallet_root="$2"

  case "${scenario}" in
    empty) ;;
    offline)
      mkdir -p -- "${wallet_root}/z-encrypted" \
        "${wallet_root}/m-multisig" "${wallet_root}/a-hardware"
      write_wallet_keys "${wallet_root}/z-encrypted" CLI
      write_cached_addresses "${wallet_root}/z-encrypted" \
        "${ADDR_Z_BASE}" "${ADDR_Z_PAY}" \
        'stake_test1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
      printf 'encrypted fixture\n' > "${wallet_root}/z-encrypted/payment.skey.gpg"
      printf '{}\n' > "${wallet_root}/m-multisig/payment.script"
      printf '{}\n' > "${wallet_root}/m-multisig/stake.script"
      write_cached_addresses "${wallet_root}/m-multisig" \
        "${ADDR_M_BASE}" "${ADDR_M_PAY}" \
        'stake_test1mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm'
      write_wallet_keys "${wallet_root}/a-hardware" Hardware
      write_cached_addresses "${wallet_root}/a-hardware" \
        "${ADDR_A_BASE}" "${ADDR_A_PAY}" \
        'stake_test1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      ;;
    local)
      mkdir -p -- "${wallet_root}/local-wallet"
      write_wallet_keys "${wallet_root}/local-wallet" CLI
      write_cached_addresses "${wallet_root}/local-wallet" \
        "${ADDR_LOCAL_BASE}" "${ADDR_LOCAL_PAY}" "${REWARD_LOCAL}"
      ;;
    light-success)
      mkdir -p -- "${wallet_root}/alpha"
      write_wallet_keys "${wallet_root}/alpha" CLI
      ;;
    light-error|light-malformed)
      mkdir -p -- "${wallet_root}/error-wallet"
      write_wallet_keys "${wallet_root}/error-wallet" CLI
      write_cached_addresses "${wallet_root}/error-wallet" \
        "${ADDR_ERROR_BASE}" "${ADDR_ERROR_PAY}" "${REWARD_ERROR}"
      ;;
    local-fallback)
      mkdir -p -- "${wallet_root}/local-wallet"
      write_wallet_keys "${wallet_root}/local-wallet" CLI
      write_cached_addresses "${wallet_root}/local-wallet" \
        "${ADDR_LOCAL_BASE}" "${ADDR_LOCAL_PAY}" "${REWARD_LOCAL}"
      ;;
    unsafe-cache)
      mkdir -p -- "${wallet_root}/unsafe-wallet"
      write_wallet_keys "${wallet_root}/unsafe-wallet" CLI
      printf 'external sentinel\n' > "${wallet_root%/*}/sentinel.addr"
      ln -s ../../sentinel.addr "${wallet_root}/unsafe-wallet/base.addr"
      printf '%s\n' "${ADDR_ERROR_PAY}" \
        > "${wallet_root}/unsafe-wallet/payment.addr"
      printf '%s\n' "${REWARD_ERROR}" \
        > "${wallet_root}/unsafe-wallet/reward.addr"
      chmod 0600 "${wallet_root}/unsafe-wallet/payment.addr" \
        "${wallet_root}/unsafe-wallet/reward.addr"
      ;;
    *) fail "unknown wallet fixture scenario: ${scenario}" ;;
  esac
}

write_header() {
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> WALLET >> LIST' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
}

write_expected_stdout() {
  local scenario="$1"
  local output_file="$2"

  write_header > "${output_file}"
  case "${scenario}" in
    empty)
      printf '\n%s\n' 'No wallets available!' >> "${output_file}"
      ;;
    offline)
      printf '%s\n' \
        'OFFLINE MODE: CNTools started in offline mode, wallet balance not shown!' \
        '' \
        'a-hardware' \
        'Type            : Hardware' \
        "Address         : ${ADDR_A_BASE}" \
        "Payment Addr    : ${ADDR_A_PAY}" \
        '' \
        'm-multisig' \
        'Type            : MultiSig' \
        "Address         : ${ADDR_M_BASE}" \
        "Payment Addr    : ${ADDR_M_PAY}" \
        '' \
        'z-encrypted (encrypted)' \
        'Type            : CLI' \
        "Address         : ${ADDR_Z_BASE}" \
        "Payment Addr    : ${ADDR_Z_PAY}" \
        >> "${output_file}"
      ;;
    unsafe-cache)
      printf '%s\n' \
        'OFFLINE MODE: CNTools started in offline mode, wallet balance not shown!' \
        '' \
        'unsafe-wallet' \
        'Type            : CLI' \
        "Payment Addr    : ${ADDR_ERROR_PAY}" \
        >> "${output_file}"
      ;;
    local|local-fallback)
      [[ "${scenario}" == local-fallback ]] && printf '%s\n' \
        '' \
        '> Querying Koios API for wallet information' \
        '' \
        'WARN: Koios wallet query failed; using local node data.' \
        >> "${output_file}"
      printf '%s\n' \
        '' \
        'local-wallet - REGISTERED' \
        'Type            : CLI' \
        "Address         : ${ADDR_LOCAL_BASE}" \
        'Base Funds      : 3 ADA (6 USD) - 1 additional asset(s) on address! [WALLET >> SHOW for details]' \
        'Rewards         : 1.5 ADA (3 USD)' \
        "Delegated to pool-alpha (${POOL_ID_FIXTURE})" \
        >> "${output_file}"
      ;;
    light-success)
      printf '%s\n' \
        '' \
        '> Querying Koios API for wallet information' \
        '' \
        'alpha - REGISTERED' \
        'Type            : CLI' \
        "Address         : ${ADDR_ALPHA_BASE}" \
        'Base Funds      : 2.5 ADA (5 USD) - 1 additional asset(s) on address! [WALLET >> SHOW for details]' \
        "Payment Addr    : ${ADDR_ALPHA_PAY}" \
        'Payment Funds   : 0.5 ADA (1 USD)' \
        'Rewards         : 1.234567 ADA (2.47 USD)' \
        "Delegated to pool-alpha (${POOL_ID_FIXTURE})" \
        >> "${output_file}"
      ;;
    light-error|light-malformed)
      printf '%s\n' \
        '' \
        '> Querying Koios API for wallet information' \
        '' \
        'ERROR: Koios wallet query failed; wallet balances are unavailable.' \
        >> "${output_file}"
      ;;
    *) fail "unknown expected stdout scenario: ${scenario}" ;;
  esac
}

write_expected_events() {
  local scenario="$1"
  local output_file="$2"
  local route="${3:-public}"

  : > "${output_file}"
  if [[ "${route}" == public ]]; then
    printf '%s\n' 'menu:main:w' 'menu:wallet:l' \
      'action:compatibility-dispatch' > "${output_file}"
  fi
  case "${scenario}" in
    empty) ;;
    offline)
      printf '%s\n' \
        'type:a-hardware:0' \
        'type:m-multisig:5' \
        'type:z-encrypted:2' \
        >> "${output_file}"
      ;;
    unsafe-cache)
      printf '%s\n' 'type:unsafe-wallet:1' >> "${output_file}"
      ;;
    local|local-fallback)
      printf '%s\n' \
        'runtime:getPriceInfo' \
        >> "${output_file}"
      [[ "${scenario}" == local-fallback ]] && printf '%s\n' \
        'terminal:sc' 'terminal:rc' 'terminal:ed' \
        >> "${output_file}"
      printf '%s\n' \
        'query:local-reward:local-wallet' \
        'type:local-wallet:1' \
        "query:local-balance:${ADDR_LOCAL_BASE}" \
        'price:3000000' \
        "query:local-balance:${ADDR_LOCAL_PAY}" \
        'price:0' \
        'price:1500000' \
        'pool-id:pool-alpha' \
        >> "${output_file}"
      ;;
    light-success)
      printf '%s\n' \
        'runtime:getPriceInfo' \
        'terminal:sc' 'terminal:rc' 'terminal:ed' \
        'type:alpha:1' \
        'price:2500000' 'price:500000' 'price:1234567' \
        'pool-id:pool-alpha' \
        >> "${output_file}"
      ;;
    light-error|light-malformed)
      printf '%s\n' \
        'runtime:getPriceInfo' \
        'terminal:sc' 'terminal:rc' 'terminal:ed' \
        >> "${output_file}"
      ;;
    *) fail "unknown expected event scenario: ${scenario}" ;;
  esac
  printf '%s\n' \
    'action:waitToProceed' \
    >> "${output_file}"
  if [[ "${route}" == public ]]; then
    printf '%s\n' \
      'menu:wallet:h' \
      'menu:main:q' \
      'exit:0:CNTools closed!' \
      >> "${output_file}"
  fi
}

write_expected_curl() {
  local scenario="$1"
  local output_file="$2"
  local address_payload="" reward_payload=""

  : > "${output_file}"
  case "${scenario}" in
    light-success)
      address_payload='{"_addresses":["'"${ADDR_ALPHA_BASE}"'","'"${ADDR_ALPHA_PAY}"'"],"_extended":true}'
      reward_payload='{"_stake_addresses":["'"${REWARD_ALPHA}"'"]}'
      ;;
    light-error|light-malformed)
      address_payload='{"_addresses":["'"${ADDR_ERROR_BASE}"'","'"${ADDR_ERROR_PAY}"'"],"_extended":true}'
      ;;
    local-fallback)
      address_payload='{"_addresses":["'"${ADDR_LOCAL_BASE}"'","'"${ADDR_LOCAL_PAY}"'"],"_extended":true}'
      ;;
    empty|offline|local|unsafe-cache) return 0 ;;
    *) fail "unknown expected curl scenario: ${scenario}" ;;
  esac
  printf 'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--connect-timeout\t10\t--max-time\t10\t--fail\t--max-filesize\t8388608\t--header\tContent-Type: application/json\t--header\taccept: text/csv\t--data\t%s\t--output\t<address-response>\t--url\t%s/address_utxos?select=address,tx_hash,tx_index,value,asset_list\n' \
    "${address_payload}" "${KOIOS_API_FIXTURE}" > "${output_file}"
  if [[ -n "${reward_payload}" ]]; then
    printf 'curl\t--disable\t--silent\t--show-error\t--location\t--max-redirs\t3\t--proto\t=https\t--proto-redir\t=https\t--connect-timeout\t10\t--max-time\t10\t--fail\t--max-filesize\t1048576\t--header\tContent-Type: application/json\t--header\taccept: text/csv\t--data\t%s\t--output\t<reward-response>\t--url\t%s/account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit\n' \
      "${reward_payload}" "${KOIOS_API_FIXTURE}" >> "${output_file}"
  fi
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"

  [[ "$(grep -c '^__CNTOOLS_WALLET_LIST_BEGIN__$' "${full_output}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_LIST_END__$' "${full_output}" || true)" == 1 ]] ||
    fail 'wallet-list output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_WALLET_LIST_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_WALLET_LIST_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source only the public controller and the two legacy query modules used by
# this focused action. All are definition-only in this test process.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${GOVERNANCE_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_QUERY_SOURCE}"
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

  [[ "${1:-}" == wallet.list && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/wallet-list-test-dispatch.XXXXXXXX")" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" || return 70
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

tput() {
  if [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]]; then
    printf 'terminal:%s\n' "$*" >> "${EVENT_LOG:?}"
  fi
}

getEpoch() { printf '0\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf '00:00:00'; }
getSlotTipRef() { printf '0\n'; }
slotInterval() { printf '20\n'; }
getNodeMetrics() { :; }
updateProtocolParams() { :; }

getPriceInfo() {
  if [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]]; then
    printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
    price_now=2
  else
    price_now=""
  fi
}

getPriceString() {
  local value="${1:-0}"
  printf 'price:%s\n' "${value}" >> "${EVENT_LOG:?}"
  case "${value}" in
    3000000) price_str=' (6 USD)' ;;
    2500000) price_str=' (5 USD)' ;;
    1500000) price_str=' (3 USD)' ;;
    1234567) price_str=' (2.47 USD)' ;;
    500000) price_str=' (1 USD)' ;;
    0) price_str='' ;;
    *) fail "unexpected wallet-list price input: ${value}" ;;
  esac
}

formatLovelace() {
  case "${1:-}" in
    0) printf '0' ;;
    500000) printf '0.5' ;;
    1234567) printf '1.234567' ;;
    1500000) printf '1.5' ;;
    2500000) printf '2.5' ;;
    3000000) printf '3' ;;
    *) fail "unexpected wallet-list lovelace input: ${1:-<empty>}" ;;
  esac
}

formatAsset() { printf '%s\n' "${1:-}"; }
hexToAscii() { printf 'Token'; }
bech32() { printf '22fixture'; }

getWalletType() {
  local wallet_name="${1:-}"
  local status=4

  case "${wallet_name}" in
    a-hardware) status=0 ;;
    m-multisig) status=5 ;;
    z-encrypted) status=2 ;;
    local-wallet|alpha|error-wallet|unsafe-wallet) status=1 ;;
    *) fail "unexpected wallet type lookup: ${wallet_name}" ;;
  esac
  printf 'type:%s:%s\n' "${wallet_name}" "${status}" >> "${EVENT_LOG:?}"
  return "${status}"
}

getBalance() {
  local address="${1:-}"

  printf 'query:local-balance:%s\n' "${address}" >> "${EVENT_LOG:?}"
  declare -gA assets=()
  case "${address}" in
    "${ADDR_LOCAL_BASE}")
      assets[lovelace]=3000000
      assets['policy.token']=42
      ;;
    "${ADDR_LOCAL_PAY}") assets[lovelace]=0 ;;
    *) fail "unexpected local balance address: ${address}" ;;
  esac
}

getRewardsFromAddr() {
  local reward_address="${1:-}"

  [[ "${reward_address}" == "${REWARD_LOCAL}" ]] ||
    fail "unexpected local reward address: ${reward_address}"
  printf 'query:local-reward:local-wallet\n' >> "${EVENT_LOG:?}"
  stake_address="${reward_address}"
  reward_lovelace=1500000
  pool_delegation="${POOL_ID_FIXTURE}"
}

getPoolID() {
  local pool_name="${1:-}"

  printf 'pool-id:%s\n' "${pool_name}" >> "${EVENT_LOG:?}"
  [[ "${pool_name}" == 'pool-alpha' ]] || return 1
  pool_id_bech32="${POOL_ID_FIXTURE}"
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[n] New') menu=wallet ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  index=0
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == 'wallet:l' ]]; then
        : > "${CAPTURE_FLAG:?}"
        printf '__CNTOOLS_WALLET_LIST_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  printf '__CNTOOLS_WALLET_LIST_END__\n'
  rm -f -- "${CAPTURE_FLAG:?}"
  return 0
}

myExit() {
  local status="${1:-0}"
  local message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'wallet-list traversal did not consume all choices'
  exit "${status}"
}

run_case() {
  local scenario="$1"
  local mode="$2"
  local route="${3:-public}"
  local case_root="${TEST_ROOT}/cases/${route}-${scenario}"
  local runtime_root="${case_root}/runtime"
  local wallet_root="${runtime_root}/wallet"
  local pool_root="${runtime_root}/pool"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local curl_log="${capture_root}/curl"
  local expected_curl="${capture_root}/expected.curl"
  local cli_log="${capture_root}/cli"
  local expected_cli="${capture_root}/expected.cli"
  local blocked_log="${capture_root}/blocked"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local filtered_after="${capture_root}/after.filtered.tree"
  local status=0

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${wallet_root}" "${pool_root}/pool-alpha" "${capture_root}"
  prepare_fixture "${scenario}" "${wallet_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"
  : > "${curl_log}"
  : > "${cli_log}"
  : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    export TZ=UTC
    export CNTOOLS_WALLET_SCENARIO="${scenario}"
    export CNTOOLS_WALLET_CURL_LOG="${curl_log}"
    export CNTOOLS_WALLET_CLI_LOG="${cli_log}"
    export CNTOOLS_WALLET_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_KOIOS_API="${KOIOS_API_FIXTURE}"
    case "${scenario}" in
      light-success)
        export CNTOOLS_WALLET_EXPECT_ADDRESS_PAYLOAD='{"_addresses":["'"${ADDR_ALPHA_BASE}"'","'"${ADDR_ALPHA_PAY}"'"],"_extended":true}'
        export CNTOOLS_WALLET_EXPECT_REWARD_PAYLOAD='{"_stake_addresses":["'"${REWARD_ALPHA}"'"]}'
        ;;
      light-error|light-malformed)
        export CNTOOLS_WALLET_EXPECT_ADDRESS_PAYLOAD='{"_addresses":["'"${ADDR_ERROR_BASE}"'","'"${ADDR_ERROR_PAY}"'"],"_extended":true}'
        ;;
      local-fallback)
        export CNTOOLS_WALLET_EXPECT_ADDRESS_PAYLOAD='{"_addresses":["'"${ADDR_LOCAL_BASE}"'","'"${ADDR_LOCAL_PAY}"'"],"_extended":true}'
        ;;
    esac
    export CNTOOLS_WALLET_ADDR_ALPHA_BASE="${ADDR_ALPHA_BASE}"
    export CNTOOLS_WALLET_ADDR_ALPHA_PAY="${ADDR_ALPHA_PAY}"
    export CNTOOLS_WALLET_REWARD_ALPHA="${REWARD_ALPHA}"
    export CNTOOLS_WALLET_POOL_ID="${POOL_ID_FIXTURE}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${pool_root}"
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_PAY_SCRIPT_FILENAME=payment.script
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_HW_PAY_SK_FILENAME=payment.hw
    WALLET_HW_STAKE_SK_FILENAME=stake.hw
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    POOL_ID_FILENAME=pool.id
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 42'
    KOIOS_API=$([[ "${mode}" == LIGHT || "${scenario}" == local-fallback ]] && \
      printf '%s' "${KOIOS_API_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CURL_TIMEOUT=10
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    ADVANCED_MODE=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    price_now=""
    slotnum=0
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_FLAG="${capture_root}/active"
    CHOICES=(w l h q)
    CHOICE_CURSOR=0
    unset assets rewards_available reward_status pool_delegations
    if [[ "${route}" == public ]]; then
      main
      exit 99
    fi
    direct_private="${runtime_root}/tmp/direct-private"
    mkdir -p -- "${direct_private}"
    chmod 0700 "${direct_private}"
    write_context "${direct_private}/context.json" "${mode}" \
      "${runtime_root}/home"
    : > "${CAPTURE_FLAG}"
    printf '__CNTOOLS_WALLET_LIST_BEGIN__\n'
    direct_status=0
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${direct_private}/context.json" "${direct_private}/result.json" ||
      direct_status=$?
    rm -f -- "${direct_private}/result.json" \
      "${direct_private}/context.json"
    rmdir -- "${direct_private}"
    exit "${direct_status}"
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_stdout "${scenario}" "${expected_stdout}"
  : > "${expected_stderr}"
  write_expected_events "${scenario}" "${expected_events}" "${route}"
  write_expected_curl "${scenario}" "${expected_curl}"
  : > "${expected_cli}"
  if [[ "${scenario}" == light-success ]]; then
    printf 'cardano-cli\taddress\tbuild\t--payment-verification-key-file\t%s/alpha/payment.vkey\t--stake-verification-key-file\t%s/alpha/stake.vkey\t--out-file\t<base-cache-temp>\t--testnet-magic\t42\n' \
      "${wallet_root}" "${wallet_root}" > "${expected_cli}"
    printf 'cardano-cli\taddress\tbuild\t--payment-verification-key-file\t%s/alpha/payment.vkey\t--out-file\t<payment-cache-temp>\t--testnet-magic\t42\n' \
      "${wallet_root}" >> "${expected_cli}"
    printf 'cardano-cli\tlatest\tstake-address\tbuild\t--stake-verification-key-file\t%s/alpha/stake.vkey\t--out-file\t<reward-cache-temp>\t--testnet-magic\t42\n' \
      "${wallet_root}" >> "${expected_cli}"
  fi
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "${scenario} normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${scenario} normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} menu, wait, query, and formatting events"
  assert_files_equal "${curl_log}" "${expected_curl}" \
    "${scenario} Koios command vectors"
  assert_files_equal "${cli_log}" "${expected_cli}" \
    "${scenario} address-cache command vectors"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} attempted an unsafe external command: $(< "${blocked_log}")"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after traversal"
  if [[ "${scenario}" == light-success ]]; then
    for cache_file in base.addr payment.addr reward.addr; do
      [[ -f "${wallet_root}/alpha/${cache_file}" &&
         ! -L "${wallet_root}/alpha/${cache_file}" ]] ||
        fail "light-success did not create allowed ${cache_file} cache"
    done
    [[ "$(< "${wallet_root}/alpha/base.addr")" == "${ADDR_ALPHA_BASE}" &&
       "$(< "${wallet_root}/alpha/payment.addr")" == "${ADDR_ALPHA_PAY}" &&
       "$(< "${wallet_root}/alpha/reward.addr")" == "${REWARD_ALPHA}" ]] ||
      fail 'generated address-cache content changed'
    [[ "$(file_mode "${wallet_root}/alpha/base.addr")" == 600 &&
       "$(file_mode "${wallet_root}/alpha/payment.addr")" == 600 &&
       "$(file_mode "${wallet_root}/alpha/reward.addr")" == 600 ]] ||
      fail 'generated address-cache mode changed'
    grep -Ev $'^f\twallet/alpha/(base|payment|reward)\\.addr\t' \
      "${after_snapshot}" > "${filtered_after}"
    assert_files_equal "${filtered_after}" "${before_snapshot}" \
      'light-success mutation outside allowed address caches'
  else
    assert_files_equal "${after_snapshot}" "${before_snapshot}" \
      "${scenario} persistent runtime tree"
    [[ ! -s "${cli_log}" ]] ||
      fail "${scenario} unexpectedly invoked cardano-cli"
  fi
}

write_fake_commands
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH
export http_proxy=http://127.0.0.1:9
export https_proxy=http://127.0.0.1:9
export HTTP_PROXY=http://127.0.0.1:9
export HTTPS_PROXY=http://127.0.0.1:9

run_case empty OFFLINE
run_case offline OFFLINE
run_case local LOCAL
run_case light-success LIGHT
run_case light-error LIGHT
run_case light-malformed LIGHT
run_case local-fallback LOCAL
run_case unsafe-cache OFFLINE
run_case offline OFFLINE direct
run_case light-success LIGHT direct
run_case light-malformed LIGHT direct

[[ "$(grep -c 'cntools_compatibility_dispatch_action wallet.list' \
  "${CNTOOLS_SCRIPT}" || true)" == 1 ]] ||
  fail 'legacy wallet-list route does not contain exactly one compatibility call'
[[ "$(grep -c ' >> WALLET >> LIST' "${CNTOOLS_SCRIPT}" || true)" == 0 ]] ||
  fail 'legacy wallet-list body remains duplicated'
grep -Fq 'Stage 4 compatibility action' "${ACTION_SOURCE}" ||
  fail 'wallet-list action is not active'
[[ "$(grep -Fc -- '    --data "${payload}"' "${ACTION_SOURCE}" || true)" == 1 ]] ||
  fail 'wallet-list action does not pass exactly one request payload to curl'

printf 'CNTools wallet-list characterization and parity passed (8 public + 3 direct cases)\n'
