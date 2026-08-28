#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
WALLET_LIBRARY="${CNTOOLS_ROOT}/lib/wallet.sh"
QUERY_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-query.sh"
STARTUP_LIBRARY="${CNTOOLS_ROOT}/core/startup.sh"
SHOW_ACTION="${CNTOOLS_ROOT}/modules/root/wallet/show"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
WALLET_ROOT="${TEST_ROOT}/wallets"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
LOG_TRACE="${TEST_ROOT}/wallet.log"
UI_TRACE="${TEST_ROOT}/ui.log"
CLI_TRACE="${TEST_ROOT}/cli.log"
HTTP_TRACE="${TEST_ROOT}/http.log"
HTTP_ARGV_TRACE="${TEST_ROOT}/http-argv.log"
HTTP_ENV_TRACE="${TEST_ROOT}/http-env.log"
HTTP_AUTH_TRACE="${TEST_ROOT}/http-auth.log"
HTTP_CAPTURE_DIR="${TEST_ROOT}/http-captures"

# Checksum-valid fixtures are from the official Koios OpenAPI examples. Testnet
# address headers cannot distinguish Preview from Preprod, but they can and must
# be distinguished from mainnet by their network tag and HRP.
TEST_BASE_ADDRESS="addr_test1vpfwv0ezc5g8a4mkku8hhy3y3vp92t7s3ul8g778g5yegsgalc6gc"
TEST_PAYMENT_ADDRESS="addr_test1vqneq3v0dqh3x3muv6ee3lt8e5729xymnxuavx6tndcjc2cv24ef9"
TEST_REWARD_ADDRESS="stake_test1urqntq4wexjylnrdnp97qq79qkxxvrsa9lcnwr7ckjd6w0cr04y4p"
MAIN_BASE_ADDRESS="addr1qy2jt0qpqz2z2z9zx5w4xemekkce7yderz53kjue53lpqv90lkfa9sgrfjuz6uvt4uqtrqhl2kj0a9lnr9ndzutx32gqleeckv"
MAIN_PAYMENT_ADDRESS="addr1q9xvgr4ehvu5k5tmaly7ugpnvekpqvnxj8xy50pa7kyetlnhel389pa4rnq6fmkzwsaynmw0mnldhlmchn2sfd589fgsz9dd0y"
MAIN_REWARD_ADDRESS="stake1uyrx65wjqjgeeksd8hptmcgl5jfyrqkfq0xe8xlp367kphsckq250"
BAD_ALPHABET_ADDRESS="${TEST_BASE_ADDRESS:0:20}b${TEST_BASE_ADDRESS:21}"
BAD_CHECKSUM_ADDRESS="${TEST_BASE_ADDRESS::-1}q"
TEST_KOIOS_TOKEN="fixture-secret-token-never-log"
TEST_DREP_ID="drep1y25j98kvqf7t3tj4pvxwrjr2728dsrfekptgg3kxqrr56qqcny8sn"

cleanup_test() {
  chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="${3:-values differ}"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_empty() {
  local actual="$1"
  local context="${2:-value should be empty}"

  [[ -z "${actual}" ]] || fail "${context}: got '${actual}'"
}

assert_contains() {
  local actual="$1"
  local expected="$2"
  local context="${3:-text is missing}"

  [[ "${actual}" == *"${expected}"* ]] ||
    fail "${context}: '${expected}' was not found"
}

assert_status() {
  local expected="$1"
  local context="$2"
  local actual=0
  shift 2

  if "$@"; then
    actual=0
  else
    actual=$?
  fi
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected status ${expected}, got ${actual}"
}

line_count() {
  local file="$1"

  if [[ -s "${file}" ]]; then
    wc -l < "${file}" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

for required_command in \
  bash chmod env find grep jq ln mktemp mkdir mv rm sed stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for required_file in \
  "${WALLET_LIBRARY}" "${QUERY_LIBRARY}" "${STARTUP_LIBRARY}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] ||
    fail "required CNTools source is missing or unsafe: ${required_file}"
done
bash -n "${WALLET_LIBRARY}" "${QUERY_LIBRARY}" ||
  fail "wallet libraries have invalid Bash syntax"

# A token available as a regular shell variable can be used to construct a
# private curl configuration, but must not be inherited by every child process.
if grep -Eq \
    '^[[:space:]]*export([[:space:]]+[^#]*)?CNTOOLS_KOIOS_TOKEN([[:space:]]|$)' \
    "${STARTUP_LIBRARY}"; then
  fail "startup exports the Koios token to child processes"
fi

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/menu.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/action.sh"
# shellcheck source=/dev/null
. "${WALLET_LIBRARY}"
# shellcheck source=/dev/null
. "${QUERY_LIBRARY}"

CNTOOLS_WALLET_DIR="${WALLET_ROOT}"
CNTOOLS_WALLET_PAY_VKEY_FILENAME="payment.vkey"
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME="payment.hwsfile"
CNTOOLS_WALLET_PAY_ADDR_FILENAME="payment.addr"
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME="payment.script"
CNTOOLS_WALLET_BASE_ADDR_FILENAME="base.addr"
CNTOOLS_WALLET_STAKE_VKEY_FILENAME="stake.vkey"
CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME="stake.hwsfile"
CNTOOLS_WALLET_STAKE_ADDR_FILENAME="reward.addr"
CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME="stake.script"
CNTOOLS_WALLET_MULTISIG_PREFIX="ms_"
CNTOOLS_LOG="${LOG_TRACE}"
CNTOOLS_BACKEND="cnode"
CNTOOLS_IMPLEMENTATION="cnode"
CNTOOLS_IMPLEMENTATION_NAME="Cardano Node"
CNTOOLS_NETWORK="preview"
CNTOOLS_SOCKET="${TEST_ROOT}/node.socket"
CNTOOLS_LOCAL_CLI_CAPABLE="true"
CNTOOLS_KOIOS_API="https://preview.koios.rest/api/v1"
CNTOOLS_KOIOS_TOKEN="${TEST_KOIOS_TOKEN}"
CNTOOLS_CURL_TIMEOUT="2"
CNTOOLS_MODULE_ROOT="${CNTOOLS_ROOT}/modules/root"
CNTOOLS_LIB_DIR="${CNTOOLS_ROOT}/lib"
CNTOOLS_VALIDATION_BASH="${BASH}"
mkdir -p \
  "${WALLET_ROOT}" "${CNTOOLS_TMP_DIR}" "${HTTP_CAPTURE_DIR}"
: > "${LOG_TRACE}"
: > "${UI_TRACE}"
: > "${CLI_TRACE}"
: > "${HTTP_TRACE}"
: > "${HTTP_ARGV_TRACE}"
: > "${HTTP_ENV_TRACE}"
: > "${HTTP_AUTH_TRACE}"
: > "${CNTOOLS_SOCKET}"

cntools_log() {
  printf '%s\t%s\t%s\n' \
    "${1:-INFO}" "${CNTOOLS_ACTION_ID:-session}" "${2:-}" >> "${LOG_TRACE}"
}

reset_wallet_root() {
  chmod -R u+rwx -- "${WALLET_ROOT}" 2>/dev/null || true
  rm -rf -- "${WALLET_ROOT}"
  mkdir -p "${WALLET_ROOT}"
  CNTOOLS_WALLET_DIR="${WALLET_ROOT}"
}

write_wallet_file() {
  local wallet="$1"
  local filename="$2"
  local content="$3"

  mkdir -p "${WALLET_ROOT}/${wallet}"
  printf '%s\n' "${content}" > "${WALLET_ROOT}/${wallet}/${filename}"
}

write_cli_wallet() {
  local wallet="$1"
  local base_address="${2:-}"
  local payment_address="${3:-}"
  local reward_address="${4:-}"

  write_wallet_file "${wallet}" payment.vkey \
    '{"type":"PaymentVerificationKeyShelley_ed25519","description":"Payment Verification Key"}'
  write_wallet_file "${wallet}" stake.vkey \
    '{"type":"StakeVerificationKeyShelley_ed25519","description":"Stake Verification Key"}'
  [[ -z "${base_address}" ]] ||
    write_wallet_file "${wallet}" base.addr "${base_address}"
  [[ -z "${payment_address}" ]] ||
    write_wallet_file "${wallet}" payment.addr "${payment_address}"
  [[ -z "${reward_address}" ]] ||
    write_wallet_file "${wallet}" reward.addr "${reward_address}"
}

reset_query_traces() {
  : > "${CLI_TRACE}"
  : > "${HTTP_TRACE}"
  : > "${HTTP_ARGV_TRACE}"
  : > "${HTTP_ENV_TRACE}"
  : > "${HTTP_AUTH_TRACE}"
  rm -f -- "${HTTP_CAPTURE_DIR}"/*.json
}

assert_no_funding_aggregate() {
  local context="$1"

  assert_empty "${CNTOOLS_WALLET_TOTAL_LOVELACE}" "${context} total"
  assert_empty "${CNTOOLS_WALLET_UTXO_COUNT}" "${context} UTxO count"
  assert_empty "${CNTOOLS_WALLET_ASSET_COUNT}" "${context} asset count"
}

# ---------------------------------------------------------------------------
# Wallet discovery, address validation, and output-variable contracts
# ---------------------------------------------------------------------------

reset_wallet_root
write_cli_wallet Alice \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
write_wallet_file Bob payment.vkey \
  '{"type":"PaymentExtendedVerificationKeyShelley_ed25519_bip32","description":"Hardware Payment Verification Key"}'
write_wallet_file Bob stake.vkey \
  '{"type":"StakeExtendedVerificationKeyShelley_ed25519_bip32","description":"Hardware Stake Verification Key"}'
write_wallet_file Bob payment.hwsfile '{}'
write_wallet_file Bob payment.skey.gpg protected
write_wallet_file Bob base.addr "${TEST_BASE_ADDRESS}"
write_wallet_file Multisig payment.script '{"type":"sig","keyHash":"00"}'
write_wallet_file Multisig payment.addr "${TEST_PAYMENT_ADDRESS}"
ln -s -- "${WALLET_ROOT}/Alice" "${WALLET_ROOT}/Linked"

cntools_wallet_catalog_build || fail "valid wallet catalog was rejected"
assert_eq "${#CNTOOLS_WALLET_NAMES[@]}" "3" "wallet count"
assert_eq "${CNTOOLS_WALLET_NAMES[*]}" "Alice Bob Multisig" "wallet ordering"
assert_eq "${CNTOOLS_WALLET_TYPES[*]}" "CLI Hardware MultiSig" "wallet types"
assert_eq "${CNTOOLS_WALLET_PROTECTIONS[*]}" "Open Protected Open" \
  "wallet protection states"
assert_eq "${CNTOOLS_WALLET_ADDRESS_STATES[0]}" "3 / 3" \
  "complete address state"
grep -F 'Skipped symbolic-link wallet entry: Linked' "${LOG_TRACE}" >/dev/null ||
  fail "symbolic-link wallet skip was not logged"

test_reader_output_collision() {
  local value="sentinel"

  cntools_wallet_read_address "${WALLET_ROOT}/Alice" base value ||
    fail "address reader failed with a caller variable named value"
  assert_eq "${value}" "${TEST_BASE_ADDRESS}" \
    "address reader output-variable collision"

  value="sentinel"
  CNTOOLS_WALLET_SELECTED_NAME="Alice"
  cntools_wallet_display_address "${WALLET_ROOT}/Alice" reward value ||
    fail "address display reader failed with a caller variable named value"
  assert_eq "${value}" "${TEST_REWARD_ADDRESS}" \
    "address display output-variable collision"
}
test_reader_output_collision

test_temp_file_output_collision() {
  local file="sentinel"

  cntools_wallet_query_temp_file file ||
    fail "query temp-file helper failed with a caller variable named file"
  [[ "${file}" == "${CNTOOLS_TMP_DIR}/.cntools-wallet."* && -f "${file}" ]] ||
    fail "query temp-file helper lost its output to local-variable shadowing"
  cntools_wallet_query_cleanup
}
test_temp_file_output_collision

SELECTOR_MODE="first"
SELECTOR_SWAP_PATH=""
SELECTOR_SWAP_DESTINATION=""
cntools_ui_choose() {
  local output_variable="$1"
  local candidate=""
  shift 2

  case "${SELECTOR_MODE}" in
    cancel) return 1 ;;
    fail) return 2 ;;
    swap)
      mv -- "${SELECTOR_SWAP_PATH}" "${SELECTOR_SWAP_DESTINATION}"
      ln -s -- "${SELECTOR_SWAP_DESTINATION}" "${SELECTOR_SWAP_PATH}"
      ;;
  esac
  candidate="${1:-}"
  [[ -n "${candidate}" ]] || return 1
  printf -v "${output_variable}" '%s' "${candidate}"
}

test_selector_output_collision() {
  local selected="sentinel"

  SELECTOR_MODE="first"
  cntools_wallet_choose selected || fail "wallet selector rejected its first row"
  assert_eq "${selected}" "0" "wallet selector output-variable collision"
}
test_selector_output_collision

write_wallet_file Bob reward.addr "${BAD_ALPHABET_ADDRESS}"
cntools_wallet_catalog_build || fail "catalog rejected a wallet with one bad member"
assert_eq "${CNTOOLS_WALLET_ADDRESS_STATES[1]}" "1 valid, 1 invalid" \
  "invalid address state"

write_wallet_file Alice base.addr "${BAD_ALPHABET_ADDRESS}"
assert_status 2 "bad Bech32 alphabet accepted" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" base address_output
write_wallet_file Alice base.addr "${BAD_CHECKSUM_ADDRESS}"
assert_status 2 "bad Bech32 checksum accepted" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" base address_output
write_wallet_file Alice base.addr "${MAIN_BASE_ADDRESS}"
assert_status 2 "mainnet address accepted for Preview" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" base address_output

CNTOOLS_NETWORK="mainnet"
write_wallet_file Alice base.addr "${MAIN_BASE_ADDRESS}"
write_wallet_file Alice payment.addr "${MAIN_PAYMENT_ADDRESS}"
write_wallet_file Alice reward.addr "${MAIN_REWARD_ADDRESS}"
cntools_wallet_read_address "${WALLET_ROOT}/Alice" base address_output ||
  fail "checksum-valid mainnet payment address was rejected"
assert_eq "${address_output}" "${MAIN_BASE_ADDRESS}" "mainnet address read"
cntools_wallet_read_address "${WALLET_ROOT}/Alice" reward address_output ||
  fail "checksum-valid mainnet reward address was rejected"
assert_eq "${address_output}" "${MAIN_REWARD_ADDRESS}" "mainnet reward read"
write_wallet_file Alice payment.addr "${TEST_PAYMENT_ADDRESS}"
assert_status 2 "testnet address accepted for mainnet" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" payment address_output

CNTOOLS_NETWORK="preview"
write_wallet_file Alice base.addr "${TEST_BASE_ADDRESS}"
write_wallet_file Alice payment.addr "${TEST_PAYMENT_ADDRESS}"
write_wallet_file Alice reward.addr "${TEST_REWARD_ADDRESS}"

# Permission checks are skipped only when the effective user can bypass mode
# bits (for example, a root-run container).
inaccessible_root="${TEST_ROOT}/inaccessible-root"
mkdir -p "${inaccessible_root}"
chmod 000 "${inaccessible_root}"
if [[ ! -r "${inaccessible_root}" || ! -x "${inaccessible_root}" ]]; then
  CNTOOLS_WALLET_DIR="${inaccessible_root}"
  assert_status 1 "inaccessible wallet root was accepted" cntools_wallet_catalog_build
fi
chmod 0700 "${inaccessible_root}"
CNTOOLS_WALLET_DIR="${WALLET_ROOT}"

mkdir -p "${WALLET_ROOT}/Locked"
printf '%s\n' "${TEST_BASE_ADDRESS}" > "${WALLET_ROOT}/Locked/base.addr"
chmod 000 "${WALLET_ROOT}/Locked"
if [[ ! -r "${WALLET_ROOT}/Locked" || ! -x "${WALLET_ROOT}/Locked" ]]; then
  assert_status 1 "inaccessible wallet was not reported" \
    cntools_wallet_catalog_build
fi
chmod 0700 "${WALLET_ROOT}/Locked"
rm -rf -- "${WALLET_ROOT}/Locked"

linked_root="${TEST_ROOT}/linked-wallet-root"
ln -s -- "${WALLET_ROOT}" "${linked_root}"
CNTOOLS_WALLET_DIR="${linked_root}"
assert_status 1 "symbolic-link wallet root was accepted" cntools_wallet_catalog_build
CNTOOLS_WALLET_DIR="${WALLET_ROOT}"

# ---------------------------------------------------------------------------
# UI and action-loader integration
# ---------------------------------------------------------------------------

cntools_ui_action_begin() {
  printf 'BEGIN\t%s\t%s\n' "$1" "$2" >> "${UI_TRACE}"
}
cntools_ui_render_status() {
  printf 'STATUS\t%s\t%s\n' "$1" "$2" >> "${UI_TRACE}"
}
cntools_ui_render_field() {
  printf 'FIELD\t%s\t%s\n' "$1" "$2" >> "${UI_TRACE}"
}
cntools_ui_render_detail() {
  printf 'DETAIL\t%s\n' "$1" >> "${UI_TRACE}"
}
cntools_ui_static_table() {
  printf 'TABLE\t%s\n' "$1" >> "${UI_TRACE}"
  shift
  printf 'ROW\t%s\n' "$@" >> "${UI_TRACE}"
}
cntools_ui_wait() { printf 'WAIT\n' >> "${UI_TRACE}"; }
cntools_gum_width() { printf '80\n'; }
cntools_gum_clear() { printf 'CLEAR\n' >> "${UI_TRACE}"; }
cntools_ui_suspend_for_job_control() { return 0; }
cntools_ui_mark_resize() { return 0; }

reset_wallet_root
write_cli_wallet Alice \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
CNTOOLS_MODE="offline"
CNTOOLS_BACKEND="none"
SELECTOR_MODE="first"
: > "${UI_TRACE}"
cntools_action_run "${SHOW_ACTION}" ||
  fail "Wallet Show failed through the production action loader"
grep -F $'ACTION\twallet/show\tselected' "${LOG_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show selection was not logged"
grep -F $'FIELD\tBase\t'"${TEST_BASE_ADDRESS}" "${UI_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show did not render the base address"
grep -F $'FIELD\tPayment\t'"${TEST_PAYMENT_ADDRESS}" "${UI_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show did not render the payment address"
grep -F $'FIELD\tReward\t'"${TEST_REWARD_ADDRESS}" "${UI_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show did not render the reward address"
assert_eq "$(grep -c '^WAIT$' "${UI_TRACE}")" "1" \
  "loader-level Show return prompt count"

: > "${UI_TRACE}"
SELECTOR_MODE="cancel"
( cntools_wallet_action_show ) || fail "selector cancellation failed Wallet Show"
grep -Fx 'CLEAR' "${UI_TRACE}" >/dev/null ||
  fail "selector cancellation did not return cleanly to the menu"
[[ "$(grep -c '^WAIT$' "${UI_TRACE}" || true)" == "0" ]] ||
  fail "selector cancellation rendered an unnecessary return prompt"

reset_wallet_root
write_cli_wallet Swap \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
SELECTOR_MODE="swap"
SELECTOR_SWAP_PATH="${WALLET_ROOT}/Swap"
SELECTOR_SWAP_DESTINATION="${TEST_ROOT}/swapped-wallet"
: > "${UI_TRACE}"
swap_status=0
if ( cntools_wallet_action_show ); then
  swap_status=0
else
  swap_status=$?
fi
(( swap_status != 0 )) ||
  fail "Wallet Show accepted a wallet replaced by a symlink after discovery"
if grep -F "${TEST_BASE_ADDRESS}" "${UI_TRACE}" >/dev/null; then
  fail "Wallet Show read an address through a post-discovery wallet symlink"
fi
rm -f -- "${WALLET_ROOT}/Swap"
rm -rf -- "${SELECTOR_SWAP_DESTINATION}"
SELECTOR_MODE="first"
SELECTOR_SWAP_PATH=""
SELECTOR_SWAP_DESTINATION=""

# ---------------------------------------------------------------------------
# Local query behavior
# ---------------------------------------------------------------------------

fake_cli="${TEST_ROOT}/cardano-cli"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "${FAKE_CLI_TRACE}"' \
  'if [[ "$*" == *"query utxo"* ]]; then' \
  '  if [[ "$*" != *"--output-json"* ]]; then' \
  '    printf "%s\n" "fixture requires --output-json" >&2' \
  '    exit 7' \
  '  fi' \
  '  address=""' \
  '  while (( $# > 0 )); do' \
  '    if [[ "$1" == "--address" ]]; then address="$2"; break; fi' \
  '    shift' \
  '  done' \
  '  if [[ "${FAKE_CLI_SCENARIO}" == "all-fail" ||' \
  '        ( "${FAKE_CLI_SCENARIO}" == "partial-payment" && "$address" == "${FAKE_PAYMENT_ADDRESS}" ) ]]; then' \
  '    printf "%s\n" "fixture query failure" >&2' \
  '    exit 9' \
  '  fi' \
  '  if [[ "$address" == "${FAKE_BASE_ADDRESS}" ]]; then' \
  '    printf "%s\n" '\''{"base#0":{"value":{"lovelace":1000000,"policy-shared":{"asset":1},"policy-base":{"asset":1}}}}'\''' \
  '  elif [[ "$address" == "${FAKE_PAYMENT_ADDRESS}" ]]; then' \
  '    printf "%s\n" '\''{"pay#0":{"value":{"lovelace":2000000,"policy-shared":{"asset":5},"policy-pay":{"asset":1}}},"pay#1":{"value":{"lovelace":500000}}}'\''' \
  '  else' \
  '    printf "%s\n" "unknown fixture address" >&2' \
  '    exit 8' \
  '  fi' \
  'elif [[ "$*" == *"query stake-address-info"* ]]; then' \
  '  if [[ "${FAKE_CLI_SCENARIO}" == "all-fail" || "${FAKE_CLI_SCENARIO}" == "stake-fail" ]]; then' \
  '    printf "%s\n" "fixture stake failure" >&2' \
  '    exit 9' \
  '  fi' \
  '  case "${FAKE_CLI_SCENARIO}" in' \
  '    stake-mismatch)' \
  '      printf "%s\n" '\''[{"address":"stake_test1unexpected","rewardAccountBalance":750000}]'\''' \
  '      ;;' \
  '    stake-multiple)' \
  '      printf "[{\"address\":\"%s\",\"rewardAccountBalance\":750000},{\"address\":\"%s\",\"rewardAccountBalance\":1}]\n" "${FAKE_REWARD_ADDRESS}" "${FAKE_REWARD_ADDRESS}"' \
  '      ;;' \
  '    stake-missing-balance)' \
  '      printf "[{\"address\":\"%s\"}]\n" "${FAKE_REWARD_ADDRESS}"' \
  '      ;;' \
  '    stake-invalid-delegation)' \
  '      printf "[{\"address\":\"%s\",\"rewardAccountBalance\":750000,\"stakeDelegation\":[]}]\n" "${FAKE_REWARD_ADDRESS}"' \
  '      ;;' \
  '    *)' \
  '      printf "[{\"address\":\"%s\",\"rewardAccountBalance\":750000,\"stakeDelegation\":{\"stakePoolBech32\":\"pool1fixture\"},\"voteDelegation\":{\"cip129Bech32\":\"%s\"}}]\n" "${FAKE_REWARD_ADDRESS}" "${FAKE_DREP_ID}"' \
  '      ;;' \
  '  esac' \
  'else' \
  '  exit 2' \
  'fi' > "${fake_cli}"
chmod 0755 "${fake_cli}"
export FAKE_CLI_TRACE="${CLI_TRACE}"
export FAKE_BASE_ADDRESS="${TEST_BASE_ADDRESS}"
export FAKE_PAYMENT_ADDRESS="${TEST_PAYMENT_ADDRESS}"
export FAKE_REWARD_ADDRESS="${TEST_REWARD_ADDRESS}"
export FAKE_DREP_ID="${TEST_DREP_ID}"
export FAKE_CLI_SCENARIO="full"
CNTOOLS_CLI="${fake_cli}"
CNTOOLS_MODE="local"
CNTOOLS_BACKEND="cnode"
CNTOOLS_IMPLEMENTATION="cnode"
CNTOOLS_IMPLEMENTATION_NAME="Cardano Node"
CNTOOLS_LOCAL_CLI_CAPABLE="true"
CNTOOLS_NETWORK="preview"

reset_query_traces
cntools_wallet_query "" "" ""
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unavailable" \
  "no-address local query status"
assert_no_funding_aggregate "no-address local query"
assert_eq "$(line_count "${CLI_TRACE}")" "0" "no-address local call count"

reset_query_traces
cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" \
  "reward-only local query status"
assert_eq "${CNTOOLS_WALLET_REWARD_LOVELACE}" "750000" \
  "reward-only local rewards"
assert_no_funding_aggregate "reward-only local query"
assert_eq "$(line_count "${CLI_TRACE}")" "1" \
  "reward-only local call count"

reset_query_traces
FAKE_CLI_SCENARIO="full"
export FAKE_CLI_SCENARIO
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" "local query status"
assert_eq "${CNTOOLS_WALLET_BASE_LOVELACE}" "1000000" "local base balance"
assert_eq "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" "2500000" \
  "local payment balance"
assert_eq "${CNTOOLS_WALLET_TOTAL_LOVELACE}" "3500000" "local total balance"
assert_eq "${CNTOOLS_WALLET_REWARD_LOVELACE}" "750000" "local rewards"
assert_eq "${CNTOOLS_WALLET_POOL_DELEGATION}" "pool1fixture" \
  "local pool delegation"
assert_eq "${CNTOOLS_WALLET_DREP_DELEGATION}" "${TEST_DREP_ID}" \
  "local CIP-129 DRep delegation"
assert_eq "${CNTOOLS_WALLET_UTXO_COUNT}" "3" "local UTxO count"
assert_eq "${CNTOOLS_WALLET_ASSET_COUNT}" "3" \
  "wallet-wide unique local asset count"
assert_eq "$(line_count "${CLI_TRACE}")" "3" "local CLI invocation count"
[[ "$(grep -c 'query utxo .*--output-json' "${CLI_TRACE}")" == "2" ]] ||
  fail "local UTxO queries did not explicitly request JSON output"
grep -F 'CARDANO_NODE_SOCKET_PATH=' "${LOG_TRACE}" >/dev/null ||
  fail "local CLI command was not logged"
cntools_wallet_query_cleanup
[[ -z "$(find "${CNTOOLS_TMP_DIR}" -type f -print)" ]] ||
  fail "local query left temporary files"

reset_query_traces
FAKE_CLI_SCENARIO="partial-payment"
export FAKE_CLI_SCENARIO
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "partial" \
  "partial local query status"
assert_eq "${CNTOOLS_WALLET_BASE_LOVELACE}" "1000000" \
  "partial local available base balance"
assert_empty "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" \
  "failed local payment balance should be unknown"
assert_no_funding_aggregate "partial local funding query"
: > "${UI_TRACE}"
cntools_wallet_render_query
grep -q $'^FIELD\tTotal\t' "${UI_TRACE}" &&
  fail "partial local subtotal was rendered as Total"
grep -Eq $'^FIELD\t(UTxOs|Native assets)\t0$' "${UI_TRACE}" &&
  fail "unknown partial local aggregate was rendered as zero"

reset_query_traces
FAKE_CLI_SCENARIO="full"
export FAKE_CLI_SCENARIO
cntools_wallet_query "${TEST_BASE_ADDRESS}" "${TEST_BASE_ADDRESS}" ""
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" \
  "duplicate local funding query status"
assert_eq "$(grep -c 'query utxo' "${CLI_TRACE}")" "1" \
  "duplicate local funding query count"
assert_eq "${CNTOOLS_WALLET_TOTAL_LOVELACE}" "1000000" \
  "duplicate local address was counted twice"
assert_eq "${CNTOOLS_WALLET_UTXO_COUNT}" "1" \
  "duplicate local address duplicated UTxOs"

for invalid_stake_scenario in \
  stake-mismatch stake-multiple stake-missing-balance \
  stake-invalid-delegation; do
  reset_query_traces
  FAKE_CLI_SCENARIO="${invalid_stake_scenario}"
  export FAKE_CLI_SCENARIO
  cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
  assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unavailable" \
    "${invalid_stake_scenario} local stake query status"
  assert_empty "${CNTOOLS_WALLET_REWARD_LOVELACE}" \
    "${invalid_stake_scenario} local rewards should be unknown"
  assert_eq "${CNTOOLS_WALLET_REGISTERED}" "unknown" \
    "${invalid_stake_scenario} registration should be unknown"
done

# ---------------------------------------------------------------------------
# Koios bulk, partial-result, and credential-boundary behavior
# ---------------------------------------------------------------------------

file_mode() {
  local file="$1"
  local mode=""

  mode="$(stat -c '%a' "${file}" 2>/dev/null || true)"
  [[ -n "${mode}" ]] || mode="$(stat -f '%Lp' "${file}" 2>/dev/null || true)"
  printf '%s\n' "${mode}"
}

HTTP_AUTH_PRESENT="N"
HTTP_AUTH_MODE=""
inspect_auth_file() {
  local file="$1"

  [[ -f "${file}" && ! -L "${file}" ]] || return 0
  if grep -F "Authorization: Bearer ${TEST_KOIOS_TOKEN}" "${file}" >/dev/null; then
    HTTP_AUTH_PRESENT="Y"
    HTTP_AUTH_MODE="$(file_mode "${file}")"
  fi
}

KOIOS_SCENARIO="full"
cntools_http_request() {
  local method="$1"
  local url="$2"
  local output_file="$3"
  local argument=""
  local previous=""
  local payload=""
  local file_argument=""
  local -a arguments=()
  shift 3
  arguments=("$@")

  HTTP_AUTH_PRESENT="N"
  HTTP_AUTH_MODE=""
  if env | grep -F 'CNTOOLS_KOIOS_TOKEN=' >/dev/null; then
    printf '%s\tTOKEN_EXPORTED\n' "${url}" >> "${HTTP_ENV_TRACE}"
  else
    printf '%s\tCLEAN\n' "${url}" >> "${HTTP_ENV_TRACE}"
  fi
  printf '%s\t%s\t' "${method}" "${url}" >> "${HTTP_ARGV_TRACE}"
  printf '%q ' "${arguments[@]}" >> "${HTTP_ARGV_TRACE}"
  printf '\n' >> "${HTTP_ARGV_TRACE}"

  for argument in "${arguments[@]}"; do
    if [[ "${previous}" == "--data" || "${previous}" == "--data-raw" ||
          "${previous}" == "--data-binary" ]]; then
      if [[ "${argument}" == @* && -f "${argument#@}" ]]; then
        payload="$(< "${argument#@}")"
      else
        payload="${argument}"
      fi
    fi
    if [[ "${previous}" == "--header" || "${previous}" == "--config" ]]; then
      file_argument="${argument#@}"
      inspect_auth_file "${file_argument}"
      if [[ "${argument}" == *"${TEST_KOIOS_TOKEN}"* ]]; then
        HTTP_AUTH_PRESENT="Y"
        HTTP_AUTH_MODE="argv"
      fi
    fi
    case "${argument}" in
      --header=@*|--config=*) inspect_auth_file "${argument#*=}" ;;
      @*) inspect_auth_file "${argument#@}" ;;
    esac
    previous="${argument}"
  done
  printf '%s\t%s\t%s\n' \
    "${url}" "${HTTP_AUTH_PRESENT}" "${HTTP_AUTH_MODE}" >> "${HTTP_AUTH_TRACE}"
  printf '%s\t%s\n' "${url}" "${payload}" >> "${HTTP_TRACE}"

  case "${url}" in
    */address_info)
      printf '%s\n' "${payload}" > "${HTTP_CAPTURE_DIR}/address_info.json"
      case "${KOIOS_SCENARIO}" in
        address-fail) return 22 ;;
        partial-missing)
          jq -cn --arg base "${TEST_BASE_ADDRESS}" \
            '[{address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]}]' \
            > "${output_file}"
          ;;
        duplicate)
          jq -cn --arg base "${TEST_BASE_ADDRESS}" \
            '[{address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]}]' \
            > "${output_file}"
          ;;
        *)
          jq -cn \
            --arg base "${TEST_BASE_ADDRESS}" \
            --arg payment "${TEST_PAYMENT_ADDRESS}" \
            '[
              {address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]},
              {address:$payment,balance:"2200000",utxo_set:[{asset_list:[
                {policy_id:"policy",asset_name:"asset",quantity:"5"}
              ]}]}
            ]' > "${output_file}"
          ;;
      esac
      ;;
    */account_info)
      printf '%s\n' "${payload}" > "${HTTP_CAPTURE_DIR}/account_info.json"
      [[ "${KOIOS_SCENARIO}" != "stake-fail" ]] || return 22
      jq -cn \
        --arg reward "${TEST_REWARD_ADDRESS}" \
        --arg drep "${TEST_DREP_ID}" \
        '[{
          stake_address:$reward,status:"registered",rewards_available:"880000",
          delegated_pool:"pool1koios",delegated_drep:$drep
        }]' > "${output_file}"
      ;;
    *) return 22 ;;
  esac
}

CNTOOLS_MODE="light"
CNTOOLS_BACKEND="koios"
CNTOOLS_KOIOS_TOKEN="${TEST_KOIOS_TOKEN}"
export -n CNTOOLS_KOIOS_TOKEN 2>/dev/null || true

reset_query_traces
cntools_wallet_query "" "" ""
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unavailable" \
  "no-address Koios query status"
assert_no_funding_aggregate "no-address Koios query"
assert_eq "$(line_count "${HTTP_TRACE}")" "0" "no-address Koios call count"

reset_query_traces
KOIOS_SCENARIO="full"
cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" \
  "reward-only Koios query status"
assert_eq "${CNTOOLS_WALLET_REWARD_LOVELACE}" "880000" \
  "reward-only Koios rewards"
assert_no_funding_aggregate "reward-only Koios query"
assert_eq "$(line_count "${HTTP_TRACE}")" "1" \
  "reward-only Koios call count"

reset_query_traces
KOIOS_SCENARIO="full"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" "Koios query status"
assert_eq "${CNTOOLS_WALLET_TOTAL_LOVELACE}" "3300000" "Koios total balance"
assert_eq "${CNTOOLS_WALLET_REWARD_LOVELACE}" "880000" "Koios rewards"
assert_eq "${CNTOOLS_WALLET_POOL_DELEGATION}" "pool1koios" \
  "Koios pool delegation"
assert_eq "${CNTOOLS_WALLET_DREP_DELEGATION}" "${TEST_DREP_ID}" \
  "Koios DRep delegation"
assert_eq "${CNTOOLS_WALLET_UTXO_COUNT}" "2" "Koios UTxO count"
assert_eq "${CNTOOLS_WALLET_ASSET_COUNT}" "1" "Koios asset count"
assert_eq "$(line_count "${HTTP_TRACE}")" "2" "Koios request count"
jq -e \
  --arg base "${TEST_BASE_ADDRESS}" \
  --arg payment "${TEST_PAYMENT_ADDRESS}" \
  '._addresses | length == 2 and
    (index($base) != null) and (index($payment) != null) and
    (unique | length == 2)' \
  "${HTTP_CAPTURE_DIR}/address_info.json" >/dev/null ||
  fail "Koios address_info did not bulk both distinct funding addresses"
jq -e --arg reward "${TEST_REWARD_ADDRESS}" \
  '._stake_addresses == [$reward]' \
  "${HTTP_CAPTURE_DIR}/account_info.json" >/dev/null ||
  fail "Koios account_info did not use its bulk-array contract"
[[ "$(grep -c '/address_info' "${HTTP_TRACE}")" == "1" &&
   "$(grep -c '/account_info' "${HTTP_TRACE}")" == "1" ]] ||
  fail "Koios full query did not use one request per bulk endpoint"
if grep -F "${TEST_KOIOS_TOKEN}" \
    "${HTTP_ARGV_TRACE}" "${HTTP_ENV_TRACE}" "${LOG_TRACE}" >/dev/null; then
  fail "Koios token leaked into argv, child environment, or logs"
fi
[[ "$(grep -c $'\tY\t600$' "${HTTP_AUTH_TRACE}")" == "2" ]] ||
  fail "Koios authorization did not reach both HTTP calls through mode-0600 files"
cntools_wallet_query_cleanup
[[ -z "$(find "${CNTOOLS_TMP_DIR}" -type f -print)" ]] ||
  fail "Koios query left credential or response temporary files"

reset_query_traces
KOIOS_SCENARIO="partial-missing"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" ""
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "partial" \
  "missing Koios address row query status"
assert_eq "${CNTOOLS_WALLET_BASE_LOVELACE}" "1100000" \
  "partial Koios available base balance"
assert_empty "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" \
  "missing Koios address row was represented as a real zero balance"
assert_no_funding_aggregate "partial Koios funding query"
: > "${UI_TRACE}"
cntools_wallet_render_query
grep -q $'^FIELD\tTotal\t' "${UI_TRACE}" &&
  fail "partial Koios subtotal was rendered as Total"
grep -Eq $'^FIELD\t(UTxOs|Native assets)\t0$' "${UI_TRACE}" &&
  fail "unknown partial Koios aggregate was rendered as zero"

reset_query_traces
KOIOS_SCENARIO="duplicate"
cntools_wallet_query "${TEST_BASE_ADDRESS}" "${TEST_BASE_ADDRESS}" ""
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" \
  "duplicate Koios funding query status"
jq -e --arg address "${TEST_BASE_ADDRESS}" \
  '._addresses == [$address]' \
  "${HTTP_CAPTURE_DIR}/address_info.json" >/dev/null ||
  fail "duplicate Koios funding address was not deduplicated"
assert_eq "${CNTOOLS_WALLET_TOTAL_LOVELACE}" "1100000" \
  "duplicate Koios address was counted twice"
assert_eq "${CNTOOLS_WALLET_UTXO_COUNT}" "1" \
  "duplicate Koios address duplicated UTxOs"

reset_query_traces
CNTOOLS_MODE="offline"
CNTOOLS_BACKEND="none"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "offline" "offline query status"
[[ ! -s "${HTTP_TRACE}" && ! -s "${CLI_TRACE}" ]] ||
  fail "offline wallet query contacted a backend"

CNTOOLS_MODE="local"
CNTOOLS_BACKEND="amaru"
CNTOOLS_IMPLEMENTATION="amaru"
CNTOOLS_IMPLEMENTATION_NAME="Amaru"
CNTOOLS_LOCAL_CLI_CAPABLE="false"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unsupported" \
  "Amaru local query status"
assert_contains "${CNTOOLS_WALLET_QUERY_MESSAGE}" \
  "does not provide local wallet queries" "Amaru capability explanation"

printf 'CNTools wallet tests passed\n'
