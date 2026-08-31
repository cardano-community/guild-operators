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
NUMBER_LIBRARY="${CNTOOLS_ROOT}/lib/number.sh"
WALLET_LIBRARY="${CNTOOLS_ROOT}/lib/wallet.sh"
MATERIAL_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-material.sh"
KEY_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-key.sh"
ADDRESS_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-address.sh"
ID_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-id.sh"
QUERY_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-query.sh"
STARTUP_LIBRARY="${CNTOOLS_ROOT}/core/startup.sh"
SHOW_ACTION="${CNTOOLS_ROOT}/modules/root/wallet/show"
LIST_ACTION="${CNTOOLS_ROOT}/modules/root/wallet/list"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
WALLET_ROOT="${TEST_ROOT}/wallets"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
LOG_TRACE="${TEST_ROOT}/wallet.log"
UI_TRACE="${TEST_ROOT}/ui.log"
PAGER_TRACE="${TEST_ROOT}/pager.log"
CLI_TRACE="${TEST_ROOT}/cli.log"
HTTP_TRACE="${TEST_ROOT}/http.log"
HTTP_ARGV_TRACE="${TEST_ROOT}/http-argv.log"
HTTP_ENV_TRACE="${TEST_ROOT}/http-env.log"
HTTP_AUTH_TRACE="${TEST_ROOT}/http-auth.log"
HTTP_CAPTURE_DIR="${TEST_ROOT}/http-captures"

# Checksum-valid fixtures are from the official Koios OpenAPI examples. Testnet
# address headers cannot distinguish Preview from Preprod, but they can and must
# be distinguished from mainnet by their network tag and HRP.
TEST_BASE_ADDRESS="addr_test1qpfepft9zs3y8ejcv84tq6tkp00wdm46fr6h3am02leunk8dc55q34v2ggxw9hea4rr3rry933a2zdh60v43h237s8ks7t2dja"
TEST_PAYMENT_ADDRESS="addr_test1vpfepft9zs3y8ejcv84tq6tkp00wdm46fr6h3am02leunkqtddwf6"
TEST_REWARD_ADDRESS="stake_test1urku22qg6k9yyr8zmu7633c33jzcc74pxma8k2cm4glgrmgrmu5lc"
MAIN_BASE_ADDRESS="addr1qy2jt0qpqz2z2z9zx5w4xemekkce7yderz53kjue53lpqv90lkfa9sgrfjuz6uvt4uqtrqhl2kj0a9lnr9ndzutx32gqleeckv"
MAIN_PAYMENT_ADDRESS="addr1vy2jt0qpqz2z2z9zx5w4xemekkce7yderz53kjue53lpqvqmw5nzn"
MAIN_REWARD_ADDRESS="stake1uyrx65wjqjgeeksd8hptmcgl5jfyrqkfq0xe8xlp367kphsckq250"
BAD_ALPHABET_ADDRESS="${TEST_BASE_ADDRESS:0:20}b${TEST_BASE_ADDRESS:21}"
BAD_CHECKSUM_ADDRESS="${TEST_BASE_ADDRESS::-1}q"
TEST_KOIOS_TOKEN="fixture-secret-token-never-log"
TEST_DREP_ID="drep1y25j98kvqf7t3tj4pvxwrjr2728dsrfekptgg3kxqrr56qqcny8sn"
TEST_POOL_ID="pool1ynfnjspgckgxjf2zeye8s33jz3e3ndk9pcwp0qzaupzvvd8ukwt"
TEST_POLICY_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TEST_BASE_POLICY_ID="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TEST_PAYMENT_POLICY_ID="cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
TEST_ASSET_NAME="746f6b656e"
TEST_BASE_ASSET_NAME="62617365"
TEST_PAYMENT_ASSET_NAME="706179"
TEST_ASSET_ID="${TEST_POLICY_ID}.${TEST_ASSET_NAME}"
TEST_BASE_ASSET_ID="${TEST_BASE_POLICY_ID}.${TEST_BASE_ASSET_NAME}"
TEST_PAYMENT_ASSET_ID="${TEST_PAYMENT_POLICY_ID}.${TEST_PAYMENT_ASSET_NAME}"
TEST_ASSET_FINGERPRINT="asset1ua6pz3yd5mdka946z8jw2fld3f8d0mmxt75gv9"
TEST_LOCAL_ASSET_HASH="b1bd6b1772d9d055e72f9e6c04d00ba855b023d1"
TEST_LOCAL_ASSET_FINGERPRINT="asset1kx7kk9mjm8g9tee0nekqf5qt4p2mqg73h4fxr8"

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
  awk bash chmod cut env find grep jq ln mktemp mkdir mv od rm sed sort stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for required_file in \
  "${NUMBER_LIBRARY}" "${WALLET_LIBRARY}" \
  "${MATERIAL_LIBRARY}" "${KEY_LIBRARY}" \
  "${ADDRESS_LIBRARY}" "${ID_LIBRARY}" "${QUERY_LIBRARY}" \
  "${STARTUP_LIBRARY}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] ||
    fail "required CNTools source is missing or unsafe: ${required_file}"
done
bash -n \
  "${NUMBER_LIBRARY}" "${WALLET_LIBRARY}" \
  "${MATERIAL_LIBRARY}" "${KEY_LIBRARY}" \
  "${ADDRESS_LIBRARY}" "${ID_LIBRARY}" "${QUERY_LIBRARY}" ||
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
. "${NUMBER_LIBRARY}"
# shellcheck source=/dev/null
. "${WALLET_LIBRARY}"
# shellcheck source=/dev/null
. "${MATERIAL_LIBRARY}"
# shellcheck source=/dev/null
. "${KEY_LIBRARY}"
# shellcheck source=/dev/null
. "${ADDRESS_LIBRARY}"
# shellcheck source=/dev/null
. "${ID_LIBRARY}"
# shellcheck source=/dev/null
. "${QUERY_LIBRARY}"

CNTOOLS_WALLET_DIR="${WALLET_ROOT}"
CNTOOLS_WALLET_PAY_VKEY_FILENAME="payment.vkey"
CNTOOLS_WALLET_PAY_SKEY_FILENAME="payment.skey"
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME="payment.hwsfile"
CNTOOLS_WALLET_PAY_ADDR_FILENAME="payment.addr"
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME="payment.script"
CNTOOLS_WALLET_PAY_CRED_FILENAME="payment.cred"
CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME="payment.script.cred"
CNTOOLS_WALLET_BASE_ADDR_FILENAME="base.addr"
CNTOOLS_WALLET_STAKE_VKEY_FILENAME="stake.vkey"
CNTOOLS_WALLET_STAKE_SKEY_FILENAME="stake.skey"
CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME="stake.hwsfile"
CNTOOLS_WALLET_STAKE_ADDR_FILENAME="reward.addr"
CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME="stake.script"
CNTOOLS_WALLET_STAKE_CRED_FILENAME="stake.cred"
CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME="stake.script.cred"
CNTOOLS_WALLET_DERIVATION_PATH_FILENAME="derivation.path"
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
: > "${PAGER_TRACE}"
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
    '{"type":"PaymentVerificationKeyShelley_ed25519","description":"Payment Verification Key","cborHex":"00"}'
  write_wallet_file "${wallet}" stake.vkey \
    '{"type":"StakeVerificationKeyShelley_ed25519","description":"Stake Verification Key","cborHex":"00"}'
  write_wallet_file "${wallet}" payment.cred \
    '11111111111111111111111111111111111111111111111111111111'
  write_wallet_file "${wallet}" stake.cred \
    '22222222222222222222222222222222222222222222222222222222'
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

test_component_aware_list_totals() (
  CNTOOLS_MODE="local"
  CNTOOLS_LOCAL_CLI_CAPABLE="true"
  CNTOOLS_WALLET_NAMES=(PaymentOnly StakeOnly Empty)
  cntools_wallet_list_query_reset

  CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[0]="${TEST_PAYMENT_ADDRESS}"
  CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[0]="3000000"
  CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[1]="${TEST_REWARD_ADDRESS}"
  CNTOOLS_WALLET_LIST_REWARD_LOVELACE[1]="400000"
  cntools_wallet_list_finalize_results ||
    fail "component-aware List totals could not be finalized"

  assert_eq "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[0]}" "3000000" \
    "payment-only List funding total"
  assert_eq "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[0]}" "3000000" \
    "payment-only List inclusive total"
  assert_eq "${CNTOOLS_WALLET_LIST_QUERY_STATUSES[0]}" "available" \
    "payment-only List status"
  assert_empty "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[1]}" \
    "stake-only wallet gained a funding total"
  assert_eq "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[1]}" "400000" \
    "stake-only List total"
  assert_eq "${CNTOOLS_WALLET_LIST_QUERY_STATUSES[1]}" "available" \
    "stake-only List status"
  assert_eq "${CNTOOLS_WALLET_LIST_QUERY_STATUSES[2]}" "unavailable" \
    "address-less List status"
)
test_component_aware_list_totals

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
write_wallet_file Bob derivation.path '1852H/1815H/0H/x/0'
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

write_cli_wallet Mnemonic
write_wallet_file Mnemonic payment.skey \
  '{"type":"PaymentExtendedSigningKeyShelley_ed25519_bip32"}'
assert_eq "$(cntools_wallet_type "${WALLET_ROOT}/Mnemonic")" "CLI" \
  "extended signing key without derivation metadata changed wallet type"
write_wallet_file Mnemonic derivation.path '1852H/1815H/0H/x/0'
assert_eq "$(cntools_wallet_type "${WALLET_ROOT}/Mnemonic")" "Mnemonic" \
  "valid derivation metadata did not identify mnemonic wallet type"

write_cli_wallet WrongExtended
write_wallet_file WrongExtended payment.skey \
  '{"type":"StakeExtendedSigningKeyShelley_ed25519_bip32"}'
assert_eq "$(cntools_wallet_type "${WALLET_ROOT}/WrongExtended")" "CLI" \
  "mismatched extended signing key changed CLI wallet type"

write_cli_wallet ProtectedMnemonic
write_wallet_file ProtectedMnemonic payment.skey.gpg protected
write_wallet_file ProtectedMnemonic stake.skey.gpg protected
write_wallet_file ProtectedMnemonic derivation.path '1852H/1815H/9H/x/0'
assert_eq "$(cntools_wallet_type "${WALLET_ROOT}/ProtectedMnemonic")" "Mnemonic" \
  "protected mnemonic wallet type"
assert_eq "$(cntools_wallet_protection "${WALLET_ROOT}/ProtectedMnemonic")" \
  "Protected" "protected mnemonic key state"

write_wallet_file Alice derivation.path 'not/a/derivation/path'
assert_eq "$(cntools_wallet_type "${WALLET_ROOT}/Alice")" "CLI" \
  "malformed derivation path changed CLI wallet type"
assert_eq "$(cntools_wallet_type "${WALLET_ROOT}/Bob")" "Hardware" \
  "hardware wallet lost precedence over derivation metadata"
rm -rf -- \
  "${WALLET_ROOT}/Mnemonic" "${WALLET_ROOT}/ProtectedMnemonic" \
  "${WALLET_ROOT}/WrongExtended"

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
grep -F 'Wallet Bob has an invalid reward address file' "${LOG_TRACE}" \
  >/dev/null || fail "invalid wallet address file was not logged"

write_wallet_file Alice base.addr "${BAD_ALPHABET_ADDRESS}"
assert_status 2 "bad Bech32 alphabet accepted" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" base address_output
write_wallet_file Alice base.addr "${BAD_CHECKSUM_ADDRESS}"
assert_status 2 "bad Bech32 checksum accepted" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" base address_output
write_wallet_file Alice base.addr "${TEST_PAYMENT_ADDRESS}"
assert_status 2 "enterprise payment address accepted as a base address" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" base address_output
write_wallet_file Alice payment.addr "${TEST_BASE_ADDRESS}"
assert_status 2 "base address accepted as an enterprise payment address" \
  cntools_wallet_read_address "${WALLET_ROOT}/Alice" payment address_output
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
cntools_ui_table() {
  local line=""
  local first="Y"

  printf 'DATA_TABLE_ARGS'
  printf '\t%s' "$@"
  printf '\n'
  while IFS= read -r line; do
    if [[ "${first}" == "Y" ]]; then
      printf 'DATA_TABLE\t%s\n' "${line}"
      first="N"
    else
      printf 'DATA_ROW\t%s\n' "${line}"
    fi
  done
} >> "${UI_TRACE}"
cntools_ui_pager() {
  local line=""

  printf 'PAGER_ARGS'
  printf '\t%s' "$@"
  printf '\n'
  while IFS= read -r line; do
    printf 'PAGER_ROW\t%s\n' "${line}"
  done
} >> "${PAGER_TRACE}"
cntools_wallet_test_failure_rows() {
  cntools_wallet_table_row "Partial" "row"
  return 47
}
: > "${UI_TRACE}"
set +o pipefail
assert_status 47 "table row producer failure was hidden" \
  cntools_wallet_render_rows_table \
    "Must not render" cntools_wallet_test_failure_rows
set -o pipefail
if grep -F $'DETAIL\tMust not render' "${UI_TRACE}" >/dev/null; then
  fail "a partial table rendered after its row producer failed"
fi
unset -f cntools_wallet_test_failure_rows
assert_eq "$(cntools_wallet_table_row 'Fixture "Token"' plain)" \
  $'"Fixture ""Token"""\tplain' \
  "Gum table TSV quoting"
assert_eq \
  "$(cntools_wallet_sanitize_display $'pool1safe\aINJECT\u202e')" \
  "pool1safe INJECT " \
  "terminal control and bidirectional display sanitization"
assert_eq "$(cntools_wallet_uint_add 999999999999999999999999 1)" \
  "1000000000000000000000000" "arbitrary-precision asset carry"
assert_eq "$(cntools_wallet_uint_add 000000000000000009 0001)" \
  "10" "arbitrary-precision leading zeros"
assert_eq "$(cntools_wallet_format_token_amount 5000000 6)" \
  "5.000000" "token display amount"
assert_eq "$(cntools_wallet_format_token_amount 5 6)" \
  "0.000005" "small token display amount"
assert_eq "$(cntools_wallet_format_token_amount 5000000000 6)" \
  "5,000.000000" "grouped token display amount"
assert_eq "$(cntools_wallet_format_token_amount 5000000 '')" \
  "5,000,000" "grouped raw token display amount"
assert_eq "$(cntools_wallet_format_lovelace 9223372036854775809)" \
  "9,223,372,036,854.775809 ADA" "large exact ADA display amount"
assert_eq "$(cntools_wallet_format_lovelace_compact 9223372036854775809)" \
  "9,223.372B" "large compact ADA display amount"
test_grouped_balance_count() (
  local rows=""

  CNTOOLS_WALLET_BASE_LOVELACE=1000000
  CNTOOLS_WALLET_PAYMENT_LOVELACE=0
  CNTOOLS_WALLET_TOTAL_LOVELACE=1000000
  CNTOOLS_WALLET_REWARD_LOVELACE=0
  CNTOOLS_WALLET_UTXO_COUNT=1234
  CNTOOLS_UI_COLUMNS=98
  rows="$(cntools_wallet_balance_rows Y N N)" ||
    fail "grouped balance rows could not be rendered"
  assert_contains "${rows}" $'UTxO count\t1,234' \
    "grouped UTxO count"
)
test_grouped_balance_count
cntools_wallet_query_reset
cntools_wallet_asset_add "${TEST_ASSET_ID}" \
  "999999999999999999999999" || fail "large asset quantity was rejected"
cntools_wallet_asset_add "${TEST_ASSET_ID}" 1 ||
  fail "duplicate asset quantity was rejected"
assert_eq "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_ASSET_ID}]}" \
  "1000000000000000000000000" "aggregated large asset quantity"
cntools_wallet_query_reset

test_multiline_wallet_catalog() (
  local index=0
  local rows=""

  reset_wallet_root
  write_cli_wallet BaseWallet \
    "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
  write_wallet_file PaymentOnly payment.vkey \
    '{"type":"PaymentVerificationKeyShelley_ed25519","cborHex":"00"}'
  write_wallet_file PaymentOnly payment.addr "${TEST_PAYMENT_ADDRESS}"
  write_wallet_file StakeOnly stake.vkey \
    '{"type":"StakeVerificationKeyShelley_ed25519","cborHex":"00"}'
  write_wallet_file StakeOnly reward.addr "${TEST_REWARD_ADDRESS}"
  write_wallet_file MultiSig payment.script \
    '{"type":"sig","keyHash":"11111111111111111111111111111111111111111111111111111111"}'
  write_wallet_file MultiSig stake.script \
    '{"type":"sig","keyHash":"22222222222222222222222222222222222222222222222222222222"}'
  write_wallet_file MultiSig base.addr "${TEST_BASE_ADDRESS}"
  write_wallet_file MultiSig payment.addr "${TEST_PAYMENT_ADDRESS}"
  write_wallet_file MultiSig reward.addr "${TEST_REWARD_ADDRESS}"

  cntools_wallet_catalog_build || fail "multiline List catalog build failed"
  cntools_wallet_list_query_reset
  cntools_wallet_list_collect_addresses ||
    fail "multiline List addresses could not be collected"
  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    case "${CNTOOLS_WALLET_NAMES[index]}" in
      BaseWallet)
        CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]="1000000"
        CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]="0"
        CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]="200000"
        CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]="0"
        CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]="1200000"
        ;;
      PaymentOnly)
        CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]="3000000"
        CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]="1234"
        CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]="3000000"
        ;;
      StakeOnly)
        CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]="400000"
        CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]="400000"
        ;;
    esac
  done
  CNTOOLS_UI_COLUMNS=98
  rows="$(cntools_wallet_catalog_rows)" ||
    fail "multiline List rows could not be rendered"

  assert_contains "${rows}" $'BaseWallet\tType\tCLI' \
    "base wallet List identity"
  assert_contains "${rows}" $'\tBase address\t'"${TEST_BASE_ADDRESS:0:32}" \
    "combined base primary address"
  assert_contains "${rows}" $'\tBase UTxO\t1.000000 ADA' \
    "base wallet split balance"
  assert_contains "${rows}" $'\tRewards\t0.200000 ADA' \
    "base wallet reward balance"
  assert_contains "${rows}" $'\tTotal\t1.200000 ADA' \
    "base wallet total"
  assert_contains "${rows}" $'PaymentOnly\tType\tCLI' \
    "payment-only CLI type"
  assert_contains "${rows}" $'\tPayment address\t'"${TEST_PAYMENT_ADDRESS:0:32}" \
    "payment-only primary address"
  assert_contains "${rows}" $'\tPayment UTxO\t3.000000 ADA' \
    "payment-only balance"
  assert_contains "${rows}" $'\tNative assets\t1,234' \
    "non-empty native asset count"
  assert_contains "${rows}" $'StakeOnly\tType\tCLI' \
    "stake-only CLI type"
  assert_contains "${rows}" $'\tStake address\t'"${TEST_REWARD_ADDRESS:0:32}" \
    "stake-only primary address"
  assert_contains "${rows}" "Payment key is missing." \
    "stake-only payment-key note"
  assert_contains "${rows}" $'MultiSig\tType\tMultiSig' \
    "MultiSig List type"
  assert_contains "${rows}" $'\tScript base address\t'"${TEST_BASE_ADDRESS:0:32}" \
    "MultiSig base primary address"
  if [[ "${rows}" == *$'\tBase UTxO\t0.000000 ADA'* ||
        "${rows}" == *$'\tPayment UTxO\t0.000000 ADA'* ||
        "${rows}" == *$'\tRewards\t0.000000 ADA'* ||
        "${rows}" == *$'\tNative assets\t0'* ]]; then
    fail "multiline List rendered an empty balance or native-asset row"
  fi
  assert_eq "$(grep -c $'^BaseWallet\t' <<< "${rows}")" "1" \
    "wallet name should identify one multiline group"

  CNTOOLS_UI_COLUMNS=180
  rows="$(cntools_wallet_catalog_rows)" ||
    fail "wide multiline List rows could not be rendered"
  assert_contains "${rows}" $'\tBase address\t'"${TEST_BASE_ADDRESS}" \
    "wide List should keep a base address on one row"
  assert_contains "${rows}" $'\tScript base address\t'"${TEST_BASE_ADDRESS}" \
    "wide List should keep a script base address on one row"
)
test_multiline_wallet_catalog

test_missing_only_wallet_materialization() (
  local fake_cli="${TEST_ROOT}/material-cardano-cli"
  local material_trace="${TEST_ROOT}/material-cli.log"
  local wallet=""
  local generated_file=""
  local first_call_count=""
  local derivation_path=""
  local generated_address=""
  local generated_credential=""
  local primary_address=""
  local primary_label=""
  local primary_note=""

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$*" >> "${MATERIAL_TRACE}"' \
    'arguments=("$@")' \
    'output=""' \
    'signing=""' \
    'extended=""' \
    'while (( $# > 0 )); do' \
    '  case "$1" in' \
    '    --verification-key-file|--out-file) output="$2"; shift 2 ;;' \
    '    --signing-key-file) signing="$2"; shift 2 ;;' \
    '    --extended-verification-key-file) extended="$2"; shift 2 ;;' \
    '    *) shift ;;' \
    '  esac' \
    'done' \
    'command_line="${arguments[*]}"' \
    'if [[ "${arguments[0]} ${arguments[1]:-}" == "key verification-key" ]]; then' \
    '  role="Payment"' \
    '  [[ "${signing##*/}" != *stake* ]] || role="Stake"' \
    '  if grep -F ExtendedSigningKey "${signing}" >/dev/null; then' \
    '    type="${role}ExtendedVerificationKeyShelley_ed25519_bip32"' \
    '  else' \
    '    type="${role}VerificationKeyShelley_ed25519"' \
    '  fi' \
    '  printf "{\"type\":\"%s\",\"cborHex\":\"00\"}\n" "${type}" > "${output}"' \
    'elif [[ "${arguments[0]} ${arguments[1]:-}" == "key non-extended-key" ]]; then' \
    '  role="Payment"' \
    '  [[ "${extended##*/}" != *stake* ]] || role="Stake"' \
    '  printf "{\"type\":\"%sVerificationKeyShelley_ed25519\",\"cborHex\":\"00\"}\n" "${role}" > "${output}"' \
    'elif [[ "${arguments[0]} ${arguments[1]:-}" == "address build" ]]; then' \
    '  if [[ "${command_line}" == *"--stake-verification-key-file"* || "${command_line}" == *"--stake-script-file"* ]]; then' \
    '    printf "%s\n" "${MATERIAL_BASE_ADDRESS}" > "${output}"' \
    '  else' \
    '    printf "%s\n" "${MATERIAL_PAYMENT_ADDRESS}" > "${output}"' \
    '  fi' \
    'elif [[ "${arguments[0]} ${arguments[1]:-}" == "stake-address build" ]]; then' \
    '  printf "%s\n" "${MATERIAL_REWARD_ADDRESS}" > "${output}"' \
    'elif [[ "${arguments[0]} ${arguments[1]:-}" == "address key-hash" ]]; then' \
    '  printf "%s\n" "${MATERIAL_PAYMENT_CREDENTIAL}" > "${output}"' \
    'elif [[ "${arguments[0]} ${arguments[1]:-}" == "stake-address key-hash" ]]; then' \
    '  printf "%s\n" "${MATERIAL_STAKE_CREDENTIAL}" > "${output}"' \
    'elif [[ "${arguments[0]} ${arguments[1]:-}" == "hash script" ]]; then' \
    '  printf "%s\n" "${MATERIAL_SCRIPT_CREDENTIAL}" > "${output}"' \
    'else' \
    '  exit 91' \
    'fi' > "${fake_cli}"
  chmod 0700 "${fake_cli}"
  : > "${material_trace}"
  export MATERIAL_TRACE="${material_trace}"
  export MATERIAL_BASE_ADDRESS="${TEST_BASE_ADDRESS}"
  export MATERIAL_PAYMENT_ADDRESS="${TEST_PAYMENT_ADDRESS}"
  export MATERIAL_REWARD_ADDRESS="${TEST_REWARD_ADDRESS}"
  export MATERIAL_PAYMENT_CREDENTIAL="11111111111111111111111111111111111111111111111111111111"
  export MATERIAL_STAKE_CREDENTIAL="22222222222222222222222222222222222222222222222222222222"
  export MATERIAL_SCRIPT_CREDENTIAL="33333333333333333333333333333333333333333333333333333333"
  CNTOOLS_CLI="${fake_cli}"
  CNTOOLS_CLI_TIMEOUT="2"

  reset_wallet_root
  wallet="${WALLET_ROOT}/Derived"
  write_wallet_file Derived payment.skey \
    '{"type":"PaymentSigningKeyShelley_ed25519","cborHex":"aa"}'
  write_wallet_file Derived stake.skey \
    '{"type":"StakeExtendedSigningKeyShelley_ed25519_bip32","cborHex":"bb"}'
  write_wallet_file Derived ms_payment.skey \
    '{"type":"PaymentSigningKeyShelley_ed25519","cborHex":"cc"}'
  write_wallet_file Derived ms_stake.skey \
    '{"type":"StakeSigningKeyShelley_ed25519","cborHex":"dd"}'
  write_wallet_file Derived derivation.path '1852H/1815H/7H/x/0'

  cntools_wallet_materialize_wallet "${wallet}" ||
    fail "signing-key-only wallet materialization failed"
  for generated_file in \
    payment.vkey stake.vkey ms_payment.vkey ms_stake.vkey \
    payment.addr base.addr reward.addr \
    payment.cred stake.cred ms_payment.cred ms_stake.cred; do
    [[ -f "${wallet}/${generated_file}" && ! -L "${wallet}/${generated_file}" ]] ||
      fail "wallet materialization omitted ${generated_file}"
    find "${wallet}/${generated_file}" -prune -perm 0600 -print | grep -q . ||
      fail "generated wallet artifact is not mode 0600: ${generated_file}"
  done
  assert_eq "$(cntools_wallet_type "${wallet}")" "Mnemonic" \
    "generated mnemonic wallet type"
  cntools_wallet_read_derivation_path "${wallet}" derivation_path ||
    fail "generated wallet derivation path could not be read"
  assert_eq "${derivation_path}" "1852H/1815H/7H/x/0" \
    "saved mnemonic derivation path"
  cntools_wallet_read_address "${wallet}" base generated_address ||
    fail "generated base address was invalid"
  assert_eq "${generated_address}" "${TEST_BASE_ADDRESS}" \
    "generated base address"
  cntools_wallet_id_read_credential "${wallet}" ms-payment generated_credential ||
    fail "generated MultiSig payment credential was invalid"
  assert_eq "${generated_credential}" "${MATERIAL_PAYMENT_CREDENTIAL}" \
    "generated MultiSig payment credential"
  first_call_count="$(line_count "${material_trace}")"
  assert_eq "${first_call_count}" "12" \
    "initial wallet artifact CLI call count"
  cntools_wallet_materialize_wallet "${wallet}" ||
    fail "cached wallet material was rejected"
  assert_eq "$(line_count "${material_trace}")" "${first_call_count}" \
    "cached wallet artifacts were regenerated"
  if find "${wallet}" -maxdepth 1 -name '.cntools-*' -print -quit | grep -q .; then
    fail "wallet materialization retained a staging file"
  fi
  if grep -F '"cborHex":"aa"' "${LOG_TRACE}" >/dev/null; then
    fail "wallet materialization logged private key contents"
  fi

  wallet="${WALLET_ROOT}/Scripts"
  write_wallet_file Scripts payment.script \
    '{"type":"sig","keyHash":"11111111111111111111111111111111111111111111111111111111"}'
  write_wallet_file Scripts stake.script \
    '{"type":"sig","keyHash":"22222222222222222222222222222222222222222222222222222222"}'
  cntools_wallet_materialize_wallet "${wallet}" ||
    fail "script wallet materialization failed"
  for generated_file in \
    payment.addr base.addr reward.addr payment.script.cred stake.script.cred; do
    [[ -f "${wallet}/${generated_file}" && ! -L "${wallet}/${generated_file}" ]] ||
      fail "script wallet materialization omitted ${generated_file}"
  done
  assert_eq "$(cntools_wallet_type "${wallet}")" "MultiSig" \
    "script wallet type"
  cntools_wallet_address_primary_into \
    "${wallet}" primary_address primary_label primary_note ||
    fail "script wallet primary address could not be selected"
  assert_eq "${primary_address}" "${TEST_BASE_ADDRESS}" \
    "script wallet primary address"
  assert_eq "${primary_label}" "Script base address" \
    "script wallet primary label"
  assert_empty "${primary_note}" "complete script wallet primary note"

  wallet="${WALLET_ROOT}/MixedScript"
  write_wallet_file MixedScript payment.script \
    '{"type":"sig","keyHash":"11111111111111111111111111111111111111111111111111111111"}'
  write_wallet_file MixedScript stake.skey \
    '{"type":"StakeSigningKeyShelley_ed25519","cborHex":"aa"}'
  cntools_wallet_materialize_wallet "${wallet}" ||
    fail "mixed script/key wallet materialization failed"
  for generated_file in \
    stake.vkey payment.addr base.addr reward.addr \
    payment.script.cred stake.cred; do
    [[ -f "${wallet}/${generated_file}" && ! -L "${wallet}/${generated_file}" ]] ||
      fail "mixed script/key wallet materialization omitted ${generated_file}"
  done
  assert_eq "$(cntools_wallet_type "${wallet}")" "MultiSig" \
    "mixed script/key wallet type"
  cntools_wallet_address_primary_into \
    "${wallet}" primary_address primary_label primary_note ||
    fail "mixed script/key primary address could not be selected"
  assert_eq "${primary_address}" "${TEST_BASE_ADDRESS}" \
    "mixed script/key primary address"
  assert_eq "${primary_label}" "Script base address" \
    "mixed script/key primary label"
  assert_empty "${primary_note}" "complete mixed script/key primary note"

  write_wallet_file Retain payment.skey \
    '{"type":"PaymentSigningKeyShelley_ed25519","cborHex":"ee"}'
  write_wallet_file Retain payment.vkey 'do-not-replace'
  first_call_count="$(line_count "${material_trace}")"
  assert_status 2 "invalid existing verification key was accepted" \
    cntools_wallet_key_materialize_role \
      "${WALLET_ROOT}/Retain" payment payment.skey payment.vkey payment.hwsfile
  assert_eq "$(< "${WALLET_ROOT}/Retain/payment.vkey")" "do-not-replace" \
    "invalid existing verification key was replaced"
  assert_eq "$(line_count "${material_trace}")" "${first_call_count}" \
    "invalid existing target triggered a derivation command"

  write_wallet_file SymlinkTarget external.vkey 'do-not-replace-link-target'
  mkdir -p "${WALLET_ROOT}/LinkedTarget"
  ln -s -- "${WALLET_ROOT}/SymlinkTarget/external.vkey" \
    "${WALLET_ROOT}/LinkedTarget/payment.vkey"
  write_wallet_file LinkedTarget payment.skey \
    '{"type":"PaymentSigningKeyShelley_ed25519","cborHex":"ff"}'
  assert_status 2 "symbolic-link verification key was accepted" \
    cntools_wallet_key_materialize_role \
      "${WALLET_ROOT}/LinkedTarget" payment \
      payment.skey payment.vkey payment.hwsfile
  [[ -L "${WALLET_ROOT}/LinkedTarget/payment.vkey" ]] ||
    fail "symbolic-link verification key was replaced"
  assert_eq "$(< "${WALLET_ROOT}/SymlinkTarget/external.vkey")" \
    "do-not-replace-link-target" "symbolic-link target was changed"

  write_wallet_file Protected payment.skey.gpg 'encrypted-private-key'
  first_call_count="$(line_count "${material_trace}")"
  cntools_wallet_key_materialize_role \
    "${WALLET_ROOT}/Protected" payment \
    payment.skey payment.vkey payment.hwsfile ||
    fail "encrypted payment key was not skipped"
  assert_eq "$(line_count "${material_trace}")" "${first_call_count}" \
    "encrypted payment key triggered derivation"

  write_wallet_file Hardware payment.hwsfile 'hardware-wallet-description'
  write_wallet_file Hardware payment.skey \
    '{"type":"PaymentSigningKeyShelley_ed25519","cborHex":"aa"}'
  first_call_count="$(line_count "${material_trace}")"
  cntools_wallet_key_materialize_role \
    "${WALLET_ROOT}/Hardware" payment \
    payment.skey payment.vkey payment.hwsfile ||
    fail "hardware payment key was not skipped"
  assert_eq "$(line_count "${material_trace}")" "${first_call_count}" \
    "hardware payment key triggered private-key derivation"
  cntools_wallet_material_cleanup
)
test_missing_only_wallet_materialization

test_local_asset_fingerprint() (
  local fingerprint_bin="${TEST_ROOT}/fingerprint-bin"
  local fingerprint_trace="${TEST_ROOT}/fingerprint.log"
  local fingerprint=""
  local rows=""

  mkdir -p "${fingerprint_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "$#" == "4" && "$1" == "-l" && "$2" == "160" && "$3" == "-b" ]] || exit 80' \
    'hex="$(od -An -tx1 -v "$4" | tr -d "[:space:]")"' \
    '[[ "${hex}" == "${CIP14_INPUT_HEX}" ]] || exit 81' \
    'printf "b2sum\n" >> "${CIP14_TRACE}"' \
    'printf "%s  %s\n" "${CIP14_HASH}" "$4"' \
    > "${fingerprint_bin}/b2sum"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "$#" == "1" && "$1" == "asset" ]] || exit 82' \
    'IFS= read -r hash' \
    '[[ "${hash}" == "${CIP14_HASH}" ]] || exit 83' \
    'printf "bech32\n" >> "${CIP14_TRACE}"' \
    'printf "%s\n" "${CIP14_FINGERPRINT}"' \
    > "${fingerprint_bin}/bech32"
  chmod 0700 "${fingerprint_bin}/b2sum" "${fingerprint_bin}/bech32"
  : > "${fingerprint_trace}"
  export CIP14_INPUT_HEX="${TEST_POLICY_ID}${TEST_ASSET_NAME}"
  export CIP14_HASH="${TEST_LOCAL_ASSET_HASH}"
  export CIP14_FINGERPRINT="${TEST_LOCAL_ASSET_FINGERPRINT}"
  export CIP14_TRACE="${fingerprint_trace}"
  PATH="${fingerprint_bin}:${PATH}"

  cntools_wallet_asset_fingerprint_into \
    fingerprint "${TEST_POLICY_ID}" "${TEST_ASSET_NAME}" ||
    fail "local CIP-14 fingerprint generation failed"
  assert_eq "${fingerprint}" "${TEST_LOCAL_ASSET_FINGERPRINT}" \
    "local CIP-14 fingerprint"
  assert_eq "$(line_count "${fingerprint_trace}")" "2" \
    "local CIP-14 tool call count"

  : > "${fingerprint_trace}"
  cntools_wallet_query_reset
  cntools_wallet_asset_add "${TEST_ASSET_ID}" 6 ||
    fail "could not prepare local fingerprint holding"
  cntools_wallet_asset_fill_fingerprints ||
    fail "local holding fingerprints could not be filled"
  assert_eq "${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${TEST_ASSET_ID}]}" \
    "${TEST_LOCAL_ASSET_FINGERPRINT}" "local holding fingerprint"
  CNTOOLS_MODE="local"
  CNTOOLS_UI_COLUMNS=98
  rows="$(cntools_wallet_asset_details_rows)" ||
    fail "local fingerprint details could not be rendered"
  assert_contains "${rows}" $'\tFingerprint\t'"${TEST_LOCAL_ASSET_FINGERPRINT}" \
    "local fingerprint detail row"
  assert_status 2 "invalid policy ID was accepted for CIP-14" \
    cntools_wallet_asset_fingerprint_into fingerprint invalid "${TEST_ASSET_NAME}"
  if find "${CNTOOLS_TMP_DIR}" -maxdepth 1 -name '.cntools-cip14-*' \
      -print -quit | grep -q .; then
    fail "local fingerprint generation retained a temporary file"
  fi
  cntools_wallet_material_cleanup
)
test_local_asset_fingerprint

saved_ui_columns="${CNTOOLS_UI_COLUMNS-}"
had_ui_columns="${CNTOOLS_UI_COLUMNS+x}"
CNTOOLS_UI_COLUMNS=60
wrapped_pair="$(cntools_wallet_table_wrapped_pair \
  "Base" "${TEST_BASE_ADDRESS}" 15)"
[[ "${wrapped_pair}" == *$'\n'* ]] ||
  fail "narrow two-column table did not wrap a base address"
reassembled_value=""
while IFS= read -r wrapped_line; do
  wrapped_label="${wrapped_line%%$'\t'*}"
  wrapped_value="${wrapped_line#*$'\t'}"
  wrapped_width=$((
    $(cntools_wallet_text_width "${wrapped_label}") +
    $(cntools_wallet_text_width "${wrapped_value}") + 7
  ))
  (( wrapped_width <= CNTOOLS_UI_COLUMNS )) ||
    fail "responsive two-column table exceeded the terminal width"
  reassembled_value+="${wrapped_value}"
done <<< "${wrapped_pair}"
assert_eq "${reassembled_value}" "${TEST_BASE_ADDRESS}" \
  "responsive address wrapping"
wrapped_triple="$(cntools_wallet_table_wrapped_triple \
  "01 · token" "Policy ID" "${TEST_POLICY_ID}" 22 20)"
[[ "${wrapped_triple}" == *$'\n'* ]] ||
  fail "narrow three-column table did not wrap a policy ID"
reassembled_value=""
while IFS= read -r wrapped_line; do
  wrapped_asset="${wrapped_line%%$'\t'*}"
  wrapped_remainder="${wrapped_line#*$'\t'}"
  wrapped_property="${wrapped_remainder%%$'\t'*}"
  wrapped_value="${wrapped_remainder#*$'\t'}"
  wrapped_width=$((
    $(cntools_wallet_text_width "${wrapped_asset}") +
    $(cntools_wallet_text_width "${wrapped_property}") +
    $(cntools_wallet_text_width "${wrapped_value}") + 10
  ))
  (( wrapped_width <= CNTOOLS_UI_COLUMNS )) ||
    fail "responsive three-column table exceeded the terminal width"
  reassembled_value+="${wrapped_value}"
done <<< "${wrapped_triple}"
assert_eq "${reassembled_value}" "${TEST_POLICY_ID}" \
  "responsive native-asset wrapping"
unicode_value='代币😀Koios代币😀Koios代币😀Koios'
wrapped_pair="$(cntools_wallet_table_wrapped_pair \
  "Token metadata" "${unicode_value}" 15)"
reassembled_value=""
while IFS= read -r wrapped_line; do
  wrapped_label="${wrapped_line%%$'\t'*}"
  wrapped_value="${wrapped_line#*$'\t'}"
  wrapped_width=$((
    $(cntools_wallet_text_width "${wrapped_label}") +
    $(cntools_wallet_text_width "${wrapped_value}") + 7
  ))
  (( wrapped_width <= CNTOOLS_UI_COLUMNS )) ||
    fail "Unicode metadata exceeded the responsive table width"
  reassembled_value+="${wrapped_value}"
done <<< "${wrapped_pair}"
assert_eq "${reassembled_value}" "${unicode_value}" \
  "responsive Unicode metadata wrapping"

test_semantic_wallet_value_roles() (
  local row=""

  CNTOOLS_UI_COLUMNS=180
  cntools_theme_style_value_into() {
    printf -v "$1" '<%s>%s</%s>' "$2" "$3" "$2"
  }
  row="$(cntools_wallet_table_wrapped_pair \
    Base "${TEST_BASE_ADDRESS}" 15 address)" ||
    fail "semantic address row could not be rendered"
  assert_eq "${row}" \
    $'Base\t<address>'"${TEST_BASE_ADDRESS}"'</address>' \
    "semantic address role"
  row="$(cntools_wallet_table_wrapped_triple \
    Wallet Type CLI 20 22 '' identifier accent)" ||
    fail "semantic wallet identity row could not be rendered"
  assert_eq "${row}" \
    $'<identifier>Wallet</identifier>\tType\t<accent>CLI</accent>' \
    "semantic wallet identity roles"
)
test_semantic_wallet_value_roles

CNTOOLS_UI_COLUMNS=180
wrapped_pair="$(cntools_wallet_table_wrapped_pair \
  "Base" "${TEST_BASE_ADDRESS}" 15)"
assert_eq "${wrapped_pair}" $'Base\t'"${TEST_BASE_ADDRESS}" \
  "wide Wallet Show address row"
wrapped_pair="$(cntools_wallet_table_wrapped_pair \
  "MultiSig payment" \
  "11111111111111111111111111111111111111111111111111111111" 20)"
assert_eq "${wrapped_pair}" \
  $'MultiSig payment\t11111111111111111111111111111111111111111111111111111111' \
  "wide Wallet Show credential row"
wrapped_triple="$(cntools_wallet_table_wrapped_triple \
  "01 · token" "Policy ID" "${TEST_POLICY_ID}" 22 20)"
assert_eq "${wrapped_triple}" \
  $'01 · token\tPolicy ID\t'"${TEST_POLICY_ID}" \
  "wide native-asset policy row"

test_live_wallet_table_width() (
  local test_terminal_columns=162

  CNTOOLS_UI_INTERACTIVE="Y"
  cntools_gum_width() { printf '98\n'; }
  tput() {
    [[ "${1:-}" == "cols" ]] || return 1
    printf '%s\n' "${test_terminal_columns}"
  }

  assert_eq "$(cntools_wallet_table_width)" "160" \
    "live Wallet table terminal width"
  test_terminal_columns=240
  assert_eq "$(cntools_wallet_table_width)" "180" \
    "Wallet table readable width cap"
)
test_live_wallet_table_width

test_wallet_table_width_snapshot() (
  local rows_file=""
  local test_terminal_columns=162
  local width_trace="${TEST_ROOT}/wallet-width.trace"

  CNTOOLS_UI_INTERACTIVE="Y"
  : > "${width_trace}"
  tput() {
    [[ "${1:-}" == "cols" ]] || return 1
    printf 'cols\n' >> "${width_trace}"
    printf '%s\n' "${test_terminal_columns}"
  }

  cntools_wallet_write_rows_file rows_file cntools_wallet_address_rows \
    "${TEST_BASE_ADDRESS}" "Not available" "Not available" ||
    fail "wide responsive table snapshot failed"
  assert_eq "$(line_count "${width_trace}")" "1" \
    "one terminal-width query per table"
  assert_eq "$(line_count "${rows_file}")" "2" \
    "wide address table row count"

  test_terminal_columns=62
  cntools_wallet_write_rows_file rows_file cntools_wallet_address_rows \
    "${TEST_BASE_ADDRESS}" "Not available" "Not available" ||
    fail "resized responsive table snapshot failed"
  assert_eq "$(line_count "${width_trace}")" "2" \
    "fresh terminal-width query for next table"
  (( $(line_count "${rows_file}") > 2 )) ||
    fail "resized address table did not use the new narrow width"
  cntools_wallet_query_cleanup
)
test_wallet_table_width_snapshot

CNTOOLS_UI_COLUMNS=98
cntools_gum_width() { printf '52\n'; }
assert_eq "$(cntools_wallet_table_width)" "52" \
  "Wallet Show render-time terminal resize"
unset -f cntools_gum_width
cntools_wallet_query_reset
cntools_wallet_asset_add "${TEST_ASSET_ID}" 1234567890 ||
  fail "could not prepare paged native asset"
cntools_wallet_asset_sort_ids || fail "could not sort paged native assets"
CNTOOLS_WALLET_ASSET_COUNT="${#CNTOOLS_WALLET_ASSET_IDS[@]}"
CNTOOLS_WALLET_ASSET_REGISTRY_NAMES["${TEST_ASSET_ID}"]="Fixture Token"
CNTOOLS_WALLET_ASSET_TICKERS["${TEST_ASSET_ID}"]="FIX"
CNTOOLS_WALLET_ASSET_METADATA_DECIMALS["${TEST_ASSET_ID}"]=0
CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES["${TEST_ASSET_ID}"]=9876543210
printf -v long_description '%0240d' 0
CNTOOLS_WALLET_ASSET_DESCRIPTIONS["${TEST_ASSET_ID}"]="${long_description}"
CNTOOLS_WALLET_ASSET_URLS["${TEST_ASSET_ID}"]="https://example.invalid/${long_description}"
CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE["${TEST_ASSET_ID}"]=1
CNTOOLS_WALLET_ASSET_METADATA_STATUS="available"
CNTOOLS_MODE="light"
formatted_details="$(cntools_wallet_asset_details_rows)" ||
  fail "formatted native-asset details could not be rendered"
assert_contains "${formatted_details}" \
  $'\tRaw quantity\t1,234,567,890' "grouped raw asset quantity"
assert_contains "${formatted_details}" \
  $'\tRaw total supply\t9,876,543,210' "grouped raw total supply"
unset "CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${TEST_ASSET_ID}]"
unset "CNTOOLS_WALLET_ASSET_DECIMALS[${TEST_ASSET_ID}]"
formatted_details="$(cntools_wallet_asset_details_rows)" ||
  fail "ticker-only native-asset details could not be rendered"
assert_contains "${formatted_details}" \
  $'\tAmount\t1,234,567,890 FIX' \
  "grouped ticker-only asset amount"
CNTOOLS_WALLET_ASSET_METADATA_DECIMALS["${TEST_ASSET_ID}"]=0
unset formatted_details
printf -v oversized_metadata '%050000d' 0
CNTOOLS_WALLET_ASSET_REGISTRY_NAMES["${TEST_ASSET_ID}"]="${oversized_metadata}"
CNTOOLS_WALLET_ASSET_TICKERS["${TEST_ASSET_ID}"]="${oversized_metadata}"
oversized_details="$(cntools_wallet_asset_details_rows)" ||
  fail "oversized metadata could not be rendered safely"
(( ${#oversized_details} < 3000 )) ||
  fail "oversized metadata was not bounded before table wrapping"
CNTOOLS_WALLET_ASSET_REGISTRY_NAMES["${TEST_ASSET_ID}"]="Fixture Token"
CNTOOLS_WALLET_ASSET_TICKERS["${TEST_ASSET_ID}"]="FIX"
unset oversized_metadata oversized_details
CNTOOLS_UI_INTERACTIVE="Y"
CNTOOLS_UI_COLUMNS=50
cntools_gum_terminal_lines() { printf '24\n'; }
: > "${UI_TRACE}"
: > "${PAGER_TRACE}"
cntools_wallet_render_asset_details_table ||
  fail "scrollable native-asset details failed"
grep -F $'PAGER_ARGS\t--soft-wrap' "${PAGER_TRACE}" >/dev/null ||
  fail "long native-asset tables did not use one Gum pager"
grep -F $'DETAIL\tNative assets (1)' "${UI_TRACE}" >/dev/null ||
  fail "the paged native-asset details were omitted"
[[ "$(grep -c $'DETAIL\tNative assets (1)' "${UI_TRACE}")" == "1" ]] ||
  fail "Wallet Show rendered more than one native-assets table"
cntools_wallet_query_cleanup
unset -f cntools_gum_terminal_lines
unset CNTOOLS_UI_INTERACTIVE
if [[ -n "${had_ui_columns}" ]]; then
  CNTOOLS_UI_COLUMNS="${saved_ui_columns}"
else
  unset CNTOOLS_UI_COLUMNS
fi
CONFIRM_STATUS=1
SPIN_INTERRUPT="N"
SPIN_HTTP_INTERRUPT="N"
cntools_ui_confirm() {
  printf 'CONFIRM\t%s\n' "$1" >> "${UI_TRACE}"
  return "${CONFIRM_STATUS}"
}
cntools_ui_spin_function() {
  local title="$1"
  shift

  printf 'SPIN\t%s\n' "${title}" >> "${UI_TRACE}"
  if [[ "${SPIN_INTERRUPT}" == "Y" ]]; then
    local interrupt_file=""
    cntools_wallet_query_temp_file interrupt_file || return 91
    kill -TERM "${BASHPID}"
  fi
  if [[ "${SPIN_HTTP_INTERRUPT}" == "Y" ]]; then
    CNTOOLS_TEST_ACTION_PID="${BASHPID}"
    export CNTOOLS_TEST_ACTION_PID
  fi
  "$@"
}
cntools_ui_wait() { printf 'WAIT\n' >> "${UI_TRACE}"; }
cntools_gum_width() { printf '96\n'; }
cntools_gum_clear() { printf 'CLEAR\n' >> "${UI_TRACE}"; }
cntools_ui_suspend_for_job_control() { return 0; }
cntools_ui_mark_resize() { return 0; }

reset_wallet_root
write_cli_wallet Alice \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
write_wallet_file LongType payment.vkey \
  '{"type":"PaymentVerificationKeyShelley_ed25519"}'
write_wallet_file LongType payment.skey.gpg protected
CNTOOLS_MODE="offline"
CNTOOLS_BACKEND="none"
SELECTOR_MODE="first"
: > "${UI_TRACE}"
saved_exit_trap="$(trap -p EXIT)"
cntools_action_run "${SHOW_ACTION}" ||
  fail "Wallet Show failed through the production action loader"
assert_eq "$(trap -p EXIT)" "${saved_exit_trap}" \
  "Wallet Show replaced the process EXIT trap"
if find "${CNTOOLS_TMP_DIR}" -maxdepth 1 -type f \
    -name '.cntools-wallet.*' -print -quit | grep -q .; then
  fail "Wallet Show retained query or table temporary files"
fi
grep -F $'ACTION\twallet/show\tselected' "${LOG_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show selection was not logged"
grep -F $'DATA_ROW\tBase\t'"${TEST_BASE_ADDRESS:0:40}" "${UI_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show did not render the base address"
grep -F $'DATA_ROW\tPayment\t'"${TEST_PAYMENT_ADDRESS}" "${UI_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show did not render the payment address"
grep -F $'DATA_ROW\tStake / reward\t'"${TEST_REWARD_ADDRESS}" "${UI_TRACE}" >/dev/null ||
  fail "loader-level Wallet Show did not render the reward address"
grep -F $'DATA_ROW\tStake registration\tUnavailable' \
  "${UI_TRACE}" >/dev/null ||
  fail "Wallet Show did not move stake registration into wallet detail"
assert_eq "$(grep -c $'DATA_ROW\tStake registration\t' "${UI_TRACE}")" "1" \
  "Wallet Show stake-registration row count"
grep -F $'DETAIL\tCredentials' "${UI_TRACE}" >/dev/null ||
  fail "Wallet Show did not render the credentials section"
grep -F $'DATA_ROW\tPayment\t11111111111111111111111111111111111111111111111111111111' \
  "${UI_TRACE}" >/dev/null ||
  fail "Wallet Show omitted the payment credential"
grep -F $'DATA_ROW\tStake\t22222222222222222222222222222222222222222222222222222222' \
  "${UI_TRACE}" >/dev/null ||
  fail "Wallet Show omitted the stake credential"
registration_line="$(grep -n -m1 $'DATA_ROW\tStake registration\t' \
  "${UI_TRACE}" | cut -d: -f1)"
address_section_line="$(grep -n -m1 $'DETAIL\tAddresses' \
  "${UI_TRACE}" | cut -d: -f1)"
credential_section_line="$(grep -n -m1 $'DETAIL\tCredentials' \
  "${UI_TRACE}" | cut -d: -f1)"
[[ "${registration_line}" =~ ^[0-9]+$ &&
   "${address_section_line}" =~ ^[0-9]+$ &&
   "${credential_section_line}" =~ ^[0-9]+$ &&
   ${registration_line} -lt ${address_section_line} &&
   ${address_section_line} -lt ${credential_section_line} ]] ||
  fail "Wallet Show top detail, address, and credential sections are out of order"
grep -F $'DATA_ROW\tStake pool delegation\tUnavailable' \
  "${UI_TRACE}" >/dev/null ||
  fail "Wallet Show did not label stake pool delegation clearly"
grep -F $'DATA_ROW\tDRep delegation\tUnavailable' \
  "${UI_TRACE}" >/dev/null ||
  fail "Wallet Show did not label DRep delegation clearly"
assert_eq "$(grep -c '^WAIT$' "${UI_TRACE}")" "1" \
  "loader-level Show return prompt count"

: > "${UI_TRACE}"
cntools_action_run "${LIST_ACTION}" ||
  fail "Wallet List failed through the production action loader"
assert_eq "$(trap -p EXIT)" "${saved_exit_trap}" \
  "Wallet List replaced the process EXIT trap"
if find "${CNTOOLS_TMP_DIR}" -maxdepth 1 -type f \
    -name '.cntools-wallet.*' -print -quit | grep -q .; then
  fail "Wallet List retained query temporary files"
fi
grep -F $'ACTION\twallet/list\tselected' "${LOG_TRACE}" >/dev/null ||
  fail "loader-level Wallet List selection was not logged"
grep -F $'DETAIL\tWallets' "${UI_TRACE}" >/dev/null ||
  fail "loader-level Wallet List did not render its wallet table"
grep -F $'DATA_TABLE\tWallet\tProperty\tValue' "${UI_TRACE}" >/dev/null ||
  fail "Wallet List did not use the multiline table layout"
grep -F $'DATA_ROW\tLongType\tType\tCLI' "${UI_TRACE}" >/dev/null ||
  fail "Wallet List did not render the partial CLI wallet type"
grep -F $'DATA_ROW\t\tKey protection\tProtected' "${UI_TRACE}" >/dev/null ||
  fail "Wallet List did not render key protection separately"
[[ "$(grep -Ec '^(CONFIRM|SPIN)' "${UI_TRACE}" || true)" == "0" ]] ||
  fail "offline Wallet List prompted for or fetched live balances"

: > "${UI_TRACE}"
SELECTOR_MODE="cancel"
( cntools_wallet_action_show ) || fail "selector cancellation failed Wallet Show"
grep -Fx 'CLEAR' "${UI_TRACE}" >/dev/null ||
  fail "selector cancellation did not return cleanly to the menu"
[[ "$(grep -c '^WAIT$' "${UI_TRACE}" || true)" == "0" ]] ||
  fail "selector cancellation rendered an unnecessary return prompt"

SELECTOR_MODE="first"
SPIN_INTERRUPT="Y"
CNTOOLS_MODE="light"
CNTOOLS_BACKEND="koios"
if cntools_action_run "${SHOW_ACTION}" >/dev/null 2>&1; then
  fail "interrupted Wallet Show unexpectedly succeeded"
else
  interrupted_status=$?
fi
assert_eq "${interrupted_status}" "143" "interrupted Wallet Show status"
if find "${CNTOOLS_TMP_DIR}" -maxdepth 1 -type f \
    -name '.cntools-wallet.*' -print -quit | grep -q .; then
  fail "interrupted Wallet Show retained a private temporary file"
fi
SPIN_INTERRUPT="N"
CNTOOLS_MODE="offline"
CNTOOLS_BACKEND="none"

interrupt_bin="${TEST_ROOT}/interrupt-bin"
mkdir -p "${interrupt_bin}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'kill -TERM "${CNTOOLS_TEST_ACTION_PID:?}"' \
  'exit 143' > "${interrupt_bin}/curl"
chmod 0700 "${interrupt_bin}/curl"
saved_path="${PATH}"
PATH="${interrupt_bin}:${PATH}"
CNTOOLS_MODE="light"
CNTOOLS_BACKEND="koios"
SPIN_HTTP_INTERRUPT="Y"
if cntools_action_run "${SHOW_ACTION}" >/dev/null 2>&1; then
  fail "Wallet Show interrupted during HTTP unexpectedly succeeded"
else
  interrupted_status=$?
fi
assert_eq "${interrupted_status}" "143" \
  "Wallet Show in-flight HTTP interruption status"
if find "${CNTOOLS_TMP_DIR}" -maxdepth 1 -type f \
    \( -name '.cntools-wallet.*' -o -name '.cntools-http-auth.*' \) \
    -print -quit | grep -q .; then
  fail "in-flight HTTP interruption retained a private temporary file"
fi
PATH="${saved_path}"
SPIN_HTTP_INTERRUPT="N"
CNTOOLS_MODE="offline"
CNTOOLS_BACKEND="none"

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
  'if [[ "$*" == query\ * && "$*" != *"--socket-path ${FAKE_SOCKET_PATH}"* ]]; then' \
  '  printf "%s\n" "fixture requires an explicit socket path" >&2' \
  '  exit 6' \
  'fi' \
  'if [[ "${FAKE_CLI_SCENARIO}" == "timeout-all" ]]; then exit 124; fi' \
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
  '  if [[ "${FAKE_CLI_SCENARIO}" == "large-numbers" ]]; then' \
  '    printf "%s\n" '\''{"large#0":{"value":{"lovelace":9223372036854775808,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"746f6b656e":9223372036854775808}}},"large#1":{"value":{"lovelace":1,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"746f6b656e":1}}}}'\''' \
  '    exit 0' \
  '  fi' \
  '  if [[ "$address" == "${FAKE_BASE_ADDRESS}" ]]; then' \
  '    printf "%s\n" '\''{"base#0":{"value":{"lovelace":1000000,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"746f6b656e":1},"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb":{"62617365":1}}}}'\''' \
  '  elif [[ "$address" == "${FAKE_PAYMENT_ADDRESS}" ]]; then' \
  '    printf "%s\n" '\''{"pay#0":{"value":{"lovelace":2000000,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"746f6b656e":5},"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc":{"706179":1}}},"pay#1":{"value":{"lovelace":500000}}}'\''' \
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
  '    diagnostic-blank)' \
  '      printf "\ncardano-cli: Network.Socket.connect: fixture socket failure\n" >&2' \
  '      exit 1' \
  '      ;;' \
  '    diagnostic-stdout)' \
  '      printf "\ncardano-cli: fixture stdout socket failure\n"' \
  '      exit 1' \
  '      ;;' \
  '    diagnostic-multiline)' \
  '      printf "%s\n" "Command failed: query stake-address-info" "Error: fixture handshake failure" >&2' \
  '      exit 1' \
  '      ;;' \
  '    diagnostic-timeout)' \
  '      exit 124' \
  '      ;;' \
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
  '    large-reward)' \
  '      printf "[{\"address\":\"%s\",\"rewardAccountBalance\":9007199254740993}]\n" "${FAKE_REWARD_ADDRESS}"' \
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
export FAKE_SOCKET_PATH="${CNTOOLS_SOCKET}"
export FAKE_CLI_SCENARIO="full"
FAKE_SOCKET_READY="Y"
cntools_wallet_query_local_socket_ready() {
  [[ "${FAKE_SOCKET_READY}" == "Y" ]]
}
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
assert_eq "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_ASSET_ID}]}" "6" \
  "shared local asset quantity"
assert_eq "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_BASE_ASSET_ID}]}" "1" \
  "base-only local asset quantity"
assert_eq "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_PAYMENT_ASSET_ID}]}" "1" \
  "payment-only local asset quantity"
assert_eq "$(line_count "${CLI_TRACE}")" "3" "local CLI invocation count"

reset_query_traces
FAKE_CLI_SCENARIO="large-numbers"
export FAKE_CLI_SCENARIO
cntools_wallet_query "${TEST_BASE_ADDRESS}" "" ""
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" \
  "large local quantity query status"
assert_eq "${CNTOOLS_WALLET_TOTAL_LOVELACE}" "9223372036854775809" \
  "lossless local lovelace aggregation"
assert_eq "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_ASSET_ID}]}" \
  "9223372036854775809" "lossless local native-asset aggregation"
: > "${UI_TRACE}"
cntools_wallet_render_balance_table
grep -F $'DATA_ROW\tTotal UTxO\t9,223,372,036,854.775809 ADA' \
  "${UI_TRACE}" >/dev/null ||
  fail "large local UTxO was corrupted in Wallet Show"
reset_query_traces
FAKE_CLI_SCENARIO="large-reward"
export FAKE_CLI_SCENARIO
cntools_wallet_query "${TEST_BASE_ADDRESS}" "" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" \
  "large local reward query status"
assert_eq "${CNTOOLS_WALLET_REWARD_LOVELACE}" "9007199254740993" \
  "lossless local reward balance"
: > "${UI_TRACE}"
cntools_wallet_render_balance_table
grep -F $'DATA_ROW\tTotal incl. rewards\t9,007,199,255.740993 ADA' \
  "${UI_TRACE}" >/dev/null ||
  fail "large reward was rounded in the inclusive wallet total"
FAKE_CLI_SCENARIO="full"
export FAKE_CLI_SCENARIO
reset_query_traces
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"

: > "${UI_TRACE}"
cntools_wallet_render_query
grep -F $'DATA_ROW\t01 · token\tRaw quantity\t6' \
  "${UI_TRACE}" >/dev/null ||
  fail "local native-assets table omitted the aggregated token holding"
grep -F $'DATA_ROW\tStake pool delegation\tDelegated · pool1fixture' \
  "${UI_TRACE}" >/dev/null ||
  fail "local delegation table omitted the stake pool target"
grep -F $'DATA_ROW\tDRep delegation\tDelegated · '"${TEST_DREP_ID:0:30}" \
  "${UI_TRACE}" >/dev/null ||
  fail "local delegation table omitted the DRep target"

CNTOOLS_WALLET_REGISTERED="yes"
CNTOOLS_WALLET_POOL_DELEGATION=""
CNTOOLS_WALLET_DREP_DELEGATION="alwaysAbstain"
: > "${UI_TRACE}"
cntools_wallet_render_delegation_table
grep -F $'DATA_ROW\tStake pool delegation\tNot delegated' \
  "${UI_TRACE}" >/dev/null ||
  fail "empty stake pool delegation was not explicit"
grep -F $'DATA_ROW\tDRep delegation\tDelegated · Always abstain' \
  "${UI_TRACE}" >/dev/null ||
  fail "special DRep delegation was not humanized"
[[ "$(grep -c 'query utxo .*--output-json' "${CLI_TRACE}")" == "2" ]] ||
  fail "local UTxO queries did not explicitly request JSON output"
[[ "$(grep -c -- "--socket-path ${CNTOOLS_SOCKET}" "${CLI_TRACE}")" == "3" ]] ||
  fail "local CLI queries did not explicitly select the normalized socket"
if grep -F 'CARDANO_NODE_SOCKET_PATH=' "${LOG_TRACE}" >/dev/null; then
  fail "local CLI query retained an inherited socket environment wrapper"
fi
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
grep -F $'DATA_ROW\tBase UTxO\t1.000000 ADA' \
  "${UI_TRACE}" >/dev/null ||
  fail "partial local balance table promoted a subtotal to Total UTxO"
grep -F $'DATA_ROW\tTotal UTxO\tUnavailable' "${UI_TRACE}" >/dev/null ||
  fail "partial local subtotal was rendered as Total UTxO"
if grep -F $'DETAIL\tNative assets' "${UI_TRACE}" >/dev/null; then
  fail "partial local native assets were rendered as a real zero"
fi

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

for diagnostic_scenario in \
  diagnostic-blank diagnostic-stdout diagnostic-multiline diagnostic-timeout; do
  reset_query_traces
  : > "${LOG_TRACE}"
  FAKE_CLI_SCENARIO="${diagnostic_scenario}"
  export FAKE_CLI_SCENARIO
  cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
  assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unavailable" \
    "${diagnostic_scenario} local query status"
done
grep -F 'status=124: timed out after' "${LOG_TRACE}" >/dev/null ||
  fail "local CLI timeout did not produce a useful diagnostic"

: > "${LOG_TRACE}"
FAKE_CLI_SCENARIO="diagnostic-blank"
export FAKE_CLI_SCENARIO
cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
grep -F 'status=1: cardano-cli: Network.Socket.connect: fixture socket failure' \
  "${LOG_TRACE}" >/dev/null ||
  fail "blank-prefixed cardano-cli stderr diagnostic was lost"

: > "${LOG_TRACE}"
FAKE_CLI_SCENARIO="diagnostic-stdout"
export FAKE_CLI_SCENARIO
cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
grep -F 'status=1: cardano-cli: fixture stdout socket failure' \
  "${LOG_TRACE}" >/dev/null ||
  fail "stdout-only cardano-cli diagnostic was lost"

: > "${LOG_TRACE}"
FAKE_CLI_SCENARIO="diagnostic-multiline"
export FAKE_CLI_SCENARIO
cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
grep -F 'status=1: Error: fixture handshake failure' \
  "${LOG_TRACE}" >/dev/null ||
  fail "the useful line of a multi-line cardano-cli diagnostic was lost"

reset_query_traces
FAKE_CLI_SCENARIO="full"
export FAKE_CLI_SCENARIO
FAKE_SOCKET_READY="N"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unavailable" \
  "missing local socket query status"
assert_contains "${CNTOOLS_WALLET_QUERY_MESSAGE}" "${CNTOOLS_SOCKET}" \
  "missing local socket explanation"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "missing local socket CLI call count"
FAKE_SOCKET_READY="Y"

# Wallet List uses the same bounded local query path per wallet and includes
# rewards in its Total column.
reset_wallet_root
write_cli_wallet Alice \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
write_cli_wallet Clone \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
cntools_wallet_catalog_build || fail "local List catalog build failed"

reset_query_traces
FAKE_CLI_SCENARIO="full"
export FAKE_CLI_SCENARIO
cntools_wallet_list_query_catalog || fail "local Wallet List query failed"
assert_eq "$(line_count "${CLI_TRACE}")" "6" \
  "local multi-wallet List CLI call count"
for wallet_index in 0 1; do
  assert_eq "${CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[wallet_index]}" \
    "1000000" "local List wallet ${wallet_index} base UTxO balance"
  assert_eq "${CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[wallet_index]}" \
    "2500000" "local List wallet ${wallet_index} payment UTxO balance"
  assert_eq "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[wallet_index]}" "3500000" \
    "local List wallet ${wallet_index} UTxO balance"
  assert_eq "${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[wallet_index]}" "750000" \
    "local List wallet ${wallet_index} rewards"
  assert_eq "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[wallet_index]}" "4250000" \
    "local List wallet ${wallet_index} inclusive total"
  assert_eq "${CNTOOLS_WALLET_LIST_TOKEN_COUNTS[wallet_index]}" "3" \
    "local List wallet ${wallet_index} native-token count"
  assert_eq "${CNTOOLS_WALLET_LIST_QUERY_STATUSES[wallet_index]}" "available" \
    "local List wallet ${wallet_index} status"
done
assert_empty "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" \
  "complete local List summary"

# The List action asks before doing any live work. Declining leaves the catalog
# available immediately; accepting performs the query under the shared spinner.
reset_query_traces
: > "${UI_TRACE}"
CONFIRM_STATUS=1
( cntools_wallet_action_list ) || fail "declined local List action failed"
grep -Fx $'CONFIRM\tFetch balances and rewards for all wallets now?' \
  "${UI_TRACE}" >/dev/null || fail "local List did not request confirmation"
[[ "$(grep -c '^SPIN' "${UI_TRACE}" || true)" == "0" ]] ||
  fail "declined local List started the balance spinner"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "declined local List CLI call count"
grep -F $'STATUS\tinfo\tLive wallet balances were not requested.' \
  "${UI_TRACE}" >/dev/null ||
  fail "declined local List did not explain its empty live columns"
grep -F 'wallet catalog live balances skipped' "${LOG_TRACE}" >/dev/null ||
  fail "declined local List choice was not logged"

reset_query_traces
: > "${UI_TRACE}"
CONFIRM_STATUS=2
confirmation_status=0
if ( cntools_wallet_action_list ); then
  fail "local List accepted a failed confirmation"
else
  confirmation_status=$?
fi
assert_eq "${confirmation_status}" "2" \
  "local List confirmation failure status"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "failed-confirmation local List CLI call count"
[[ "$(grep -c '^SPIN' "${UI_TRACE}" || true)" == "0" ]] ||
  fail "failed local List confirmation started the balance spinner"

reset_query_traces
: > "${UI_TRACE}"
CONFIRM_STATUS=0
( cntools_wallet_action_list ) || fail "accepted local List action failed"
grep -Fx $'SPIN\tFetching wallet balances and rewards from Cardano Node…' \
  "${UI_TRACE}" >/dev/null || fail "local List did not use the Gum spinner"
assert_eq "$(line_count "${CLI_TRACE}")" "6" \
  "accepted local List CLI call count"
grep -F 'wallet catalog live balances requested' "${LOG_TRACE}" >/dev/null ||
  fail "accepted local List choice was not logged"

reset_query_traces
FAKE_CLI_SCENARIO="partial-payment"
export FAKE_CLI_SCENARIO
cntools_wallet_list_query_catalog || fail "partial local Wallet List query failed"
for wallet_index in 0 1; do
  assert_eq "${CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[wallet_index]}" \
    "1000000" "partial local List base balance"
  assert_empty \
    "${CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[wallet_index]}" \
    "partial local List payment balance"
  assert_empty "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[wallet_index]}" \
    "partial local List UTxO aggregate"
  assert_eq "${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[wallet_index]}" "750000" \
    "partial local List rewards"
  assert_empty "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[wallet_index]}" \
    "partial local List total"
  assert_empty "${CNTOOLS_WALLET_LIST_TOKEN_COUNTS[wallet_index]}" \
    "partial local List token count"
  assert_eq "${CNTOOLS_WALLET_LIST_QUERY_STATUSES[wallet_index]}" "partial" \
    "partial local List status"
done

reset_query_traces
FAKE_CLI_SCENARIO="full"
export FAKE_CLI_SCENARIO
FAKE_SOCKET_READY="N"
cntools_wallet_list_query_catalog || fail "missing-socket local List failed"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "local List preflight CLI call count"
assert_contains "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" "${CNTOOLS_SOCKET}" \
  "local List missing-socket summary"
FAKE_SOCKET_READY="Y"

reset_query_traces
FAKE_CLI_SCENARIO="timeout-all"
export FAKE_CLI_SCENARIO
cntools_wallet_list_query_catalog || fail "timed-out local List failed"
assert_eq "$(line_count "${CLI_TRACE}")" "1" \
  "local List timeout circuit-breaker call count"
assert_contains "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" "stopped" \
  "local List timeout circuit-breaker summary"
FAKE_CLI_SCENARIO="full"
export FAKE_CLI_SCENARIO

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
  local requested="[]"
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
  {
    printf '%s\t%s\t' "${method}" "${url}"
    printf '%q ' "${arguments[@]}"
    printf '\n'
  } >> "${HTTP_ARGV_TRACE}"

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
    */address_info\?select=*)
      printf '%s\n' "${payload}" > "${HTTP_CAPTURE_DIR}/address_info.json"
      requested="$(jq -c '._addresses // []' <<< "${payload}")"
      case "${KOIOS_SCENARIO}" in
        address-fail) return 22 ;;
        partial-missing)
          jq -cn --argjson requested "${requested}" \
            --arg base "${TEST_BASE_ADDRESS}" '
              [{address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]}]
              | [.[] as $row
                 | select($requested | index($row.address)) | $row]
            ' \
            > "${output_file}"
          ;;
        duplicate)
          jq -cn --arg base "${TEST_BASE_ADDRESS}" \
            '[{address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]}]' \
            > "${output_file}"
          ;;
        null-asset-name)
          jq -cn --argjson requested "${requested}" \
            --arg base "${TEST_BASE_ADDRESS}" \
            --arg payment "${TEST_PAYMENT_ADDRESS}" \
            --arg policy "${TEST_POLICY_ID}" \
            --arg fingerprint "${TEST_ASSET_FINGERPRINT}" '
              [
                {address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]},
                {address:$payment,balance:"2200000",utxo_set:[{asset_list:[
                  {
                    policy_id:$policy,asset_name:null,quantity:"5",
                    fingerprint:$fingerprint,decimals:0
                  }
                ]}]}
              ]
              | [.[] as $row
                 | select($requested | index($row.address)) | $row]
            ' > "${output_file}"
          ;;
        invalid-asset)
          jq -cn --argjson requested "${requested}" \
            --arg base "${TEST_BASE_ADDRESS}" \
            --arg payment "${TEST_PAYMENT_ADDRESS}" '
              [
                {address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]},
                {address:$payment,balance:"2200000",utxo_set:[{asset_list:[
                  {policy_id:"not-hex",asset_name:"00",quantity:"5"}
                ]}]}
              ]
              | [.[] as $row
                 | select($requested | index($row.address)) | $row]
            ' > "${output_file}"
          ;;
        oversized-quantity)
          jq -cn --argjson requested "${requested}" \
            --arg base "${TEST_BASE_ADDRESS}" \
            --arg payment "${TEST_PAYMENT_ADDRESS}" \
            --arg policy "${TEST_POLICY_ID}" \
            --arg asset "${TEST_ASSET_NAME}" '
              [
                {address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]},
                {address:$payment,balance:"2200000",utxo_set:[{asset_list:[
                  {
                    policy_id:$policy,asset_name:$asset,
                    quantity:("0" * 50000)
                  }
                ]}]}
              ]
              | [.[] as $row
                 | select($requested | index($row.address)) | $row]
            ' > "${output_file}"
          ;;
        *)
          jq -cn --argjson requested "${requested}" \
            --arg base "${TEST_BASE_ADDRESS}" \
            --arg payment "${TEST_PAYMENT_ADDRESS}" \
            --arg policy "${TEST_POLICY_ID}" \
            --arg asset "${TEST_ASSET_NAME}" \
            --arg fingerprint "${TEST_ASSET_FINGERPRINT}" '
              [
                {address:$base,balance:"1100000",utxo_set:[{asset_list:[]}]},
                {address:$payment,balance:"2200000",utxo_set:[{asset_list:[
                  {
                    policy_id:$policy,asset_name:$asset,quantity:"5",
                    fingerprint:$fingerprint,decimals:6
                  }
                ]}]}
              ]
              | [.[] as $row
                 | select($requested | index($row.address)) | $row]
            ' > "${output_file}"
          ;;
      esac
      ;;
    */account_info\?select=*)
      printf '%s\n' "${payload}" > "${HTTP_CAPTURE_DIR}/account_info.json"
      [[ "${KOIOS_SCENARIO}" != "stake-fail" ]] || return 22
      requested="$(jq -c '._stake_addresses // []' <<< "${payload}")"
      if [[ "${KOIOS_SCENARIO}" == "stake-number" ]]; then
        jq -cn --argjson requested "${requested}" \
          --arg reward "${TEST_REWARD_ADDRESS}" '
            [{stake_address:$reward,status:"registered",rewards_available:1e20}]
            | [.[] as $row
               | select($requested | index($row.stake_address)) | $row]
          ' > "${output_file}"
      elif [[ "${KOIOS_SCENARIO}" == "stake-special-drep" ]]; then
        jq -cn --argjson requested "${requested}" \
          --arg reward "${TEST_REWARD_ADDRESS}" '
            [{
              stake_address:$reward,status:"registered",
              rewards_available:"880000",delegated_pool:null,
              delegated_drep:"drep_always_abstain"
            }]
            | [.[] as $row
               | select($requested | index($row.stake_address)) | $row]
          ' > "${output_file}"
      elif [[ "${KOIOS_SCENARIO}" == "stake-malformed-delegation" ]]; then
        jq -cn --argjson requested "${requested}" \
          --arg reward "${TEST_REWARD_ADDRESS}" '
            [{
              stake_address:$reward,status:"registered",
              rewards_available:"880000",delegated_pool:("p" * 50000),
              delegated_drep:"not-a-drep"
            }]
            | [.[] as $row
               | select($requested | index($row.stake_address)) | $row]
          ' > "${output_file}"
      else
        jq -cn --argjson requested "${requested}" \
          --arg reward "${TEST_REWARD_ADDRESS}" \
          --arg pool "${TEST_POOL_ID}" \
          --arg drep "${TEST_DREP_ID}" '
            [{
              stake_address:$reward,status:"registered",rewards_available:"880000",
              delegated_pool:$pool,delegated_drep:$drep
            }]
            | [.[] as $row
               | select($requested | index($row.stake_address)) | $row]
          ' > "${output_file}"
      fi
      ;;
    */asset_info\?select=*)
      printf '%s\n' "${payload}" > "${HTTP_CAPTURE_DIR}/asset_info.json"
      requested="$(jq -c '._asset_list // []' <<< "${payload}")"
      case "${KOIOS_METADATA_SCENARIO:-full}" in
        fail) return 22 ;;
        missing) printf '[]\n' > "${output_file}" ;;
        hostile)
          jq -cn \
            --arg policy "${TEST_POLICY_ID}" \
            --arg asset "${TEST_ASSET_NAME}" \
            --arg fingerprint "${TEST_ASSET_FINGERPRINT}" '
              [{
                policy_id:$policy,asset_name:$asset,
                asset_name_ascii:"token",fingerprint:$fingerprint,
                total_supply:"9000000",
                metadata_name:"Fixture\u202eToken\u0085",
                metadata_ticker:"F\u2066IX",metadata_decimals:"6",
                metadata_description:("Safe\u202d " + ("x" * 1000)),
                metadata_url:null
              }]
            ' > "${output_file}"
          ;;
        malformed)
          jq -cn \
            --arg policy "${TEST_POLICY_ID}" \
            --arg asset "${TEST_ASSET_NAME}" '
              [{
                policy_id:$policy,asset_name:$asset,
                asset_name_ascii:"token",fingerprint:"not-a-fingerprint",
                total_supply:"9000000",metadata_name:"Fixture Token",
                metadata_ticker:"FIX",metadata_decimals:"999",
                metadata_description:"Fixture metadata",metadata_url:null
              }]
            ' > "${output_file}"
          ;;
        duplicate)
          jq -cn \
            --arg policy "${TEST_POLICY_ID}" \
            --arg asset "${TEST_ASSET_NAME}" \
            --arg fingerprint "${TEST_ASSET_FINGERPRINT}" '
              [{
                policy_id:$policy,asset_name:$asset,
                asset_name_ascii:"token",fingerprint:$fingerprint,
                total_supply:"9000000",metadata_name:"Fixture Token",
                metadata_ticker:"FIX",metadata_decimals:"6",
                metadata_description:null,metadata_url:null
              }] | . + .
            ' > "${output_file}"
          ;;
        extra)
          jq -cn \
            --arg policy "${TEST_POLICY_ID}" \
            --arg asset "${TEST_ASSET_NAME}" \
            --arg extra_policy "${TEST_BASE_POLICY_ID}" \
            --arg extra_asset "${TEST_BASE_ASSET_NAME}" \
            --arg fingerprint "${TEST_ASSET_FINGERPRINT}" '
              [
                {
                  policy_id:$policy,asset_name:$asset,
                  asset_name_ascii:"token",fingerprint:$fingerprint,
                  total_supply:"9000000",metadata_name:"Fixture Token",
                  metadata_ticker:"FIX",metadata_decimals:"6",
                  metadata_description:null,metadata_url:null
                },
                {
                  policy_id:$extra_policy,asset_name:$extra_asset,
                  asset_name_ascii:"base",fingerprint:$fingerprint,
                  total_supply:"1",metadata_name:null,
                  metadata_ticker:null,metadata_decimals:null,
                  metadata_description:null,metadata_url:null
                }
              ]
            ' > "${output_file}"
          ;;
        *)
          jq -cn \
            --argjson requested "${requested}" \
            --arg policy "${TEST_POLICY_ID}" \
            --arg asset "${TEST_ASSET_NAME}" \
            --arg fingerprint "${TEST_ASSET_FINGERPRINT}" '
              $requested | map(. as $identity | {
                policy_id:$identity[0],asset_name:$identity[1],
                asset_name_ascii:
                  (if $identity == [$policy,$asset] then "token" else null end),
                fingerprint:$fingerprint,
                total_supply:
                  (if $identity == [$policy,$asset] then "9000000" else "1" end),
                metadata_name:
                  (if $identity == [$policy,$asset] then "Fixture Token" else null end),
                metadata_ticker:
                  (if $identity == [$policy,$asset] then "FIX" else null end),
                metadata_decimals:
                  (if $identity == [$policy,$asset] then "6" else null end),
                metadata_description:
                  (if $identity == [$policy,$asset]
                   then "Fixture token metadata" else null end),
                metadata_url:
                  (if $identity == [$policy,$asset]
                   then "https://example.test/token" else null end)
              })
            ' > "${output_file}"
          ;;
      esac
      ;;
    *) return 22 ;;
  esac
}

CNTOOLS_MODE="light"
CNTOOLS_BACKEND="koios"
CNTOOLS_KOIOS_TOKEN="${TEST_KOIOS_TOKEN}"
KOIOS_METADATA_SCENARIO="full"
export -n CNTOOLS_KOIOS_TOKEN 2>/dev/null || true
assert_eq "$(cntools_wallet_query_koios_asset_payload_limit)" "5120" \
  "authenticated Koios metadata payload limit"
saved_koios_token="${CNTOOLS_KOIOS_TOKEN}"
CNTOOLS_KOIOS_TOKEN=""
assert_eq "$(cntools_wallet_query_koios_asset_payload_limit)" "1024" \
  "public Koios metadata payload limit"
CNTOOLS_KOIOS_TOKEN="${saved_koios_token}"
saved_rate_batches="${CNTOOLS_WALLET_KOIOS_RATE_BATCHES}"
saved_rate_pause="${CNTOOLS_WALLET_KOIOS_RATE_PAUSE_SECONDS}"
CNTOOLS_WALLET_KOIOS_RATE_BATCHES=2
CNTOOLS_WALLET_KOIOS_RATE_PAUSE_SECONDS=0
rate_log_before="$(grep -c 'Koios asset_info rate window reached' \
  "${LOG_TRACE}" || true)"
cntools_wallet_query_koios_asset_pace 0 || fail "Koios initial batch pacing failed"
cntools_wallet_query_koios_asset_pace 1 || fail "Koios pre-limit pacing failed"
cntools_wallet_query_koios_asset_pace 2 || fail "Koios limit pacing failed"
rate_log_after="$(grep -c 'Koios asset_info rate window reached' \
  "${LOG_TRACE}" || true)"
assert_eq "$((rate_log_after - rate_log_before))" "1" \
  "Koios metadata rate-limit boundary"
CNTOOLS_WALLET_KOIOS_RATE_BATCHES="${saved_rate_batches}"
CNTOOLS_WALLET_KOIOS_RATE_PAUSE_SECONDS="${saved_rate_pause}"

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
assert_eq "${CNTOOLS_WALLET_POOL_DELEGATION}" "${TEST_POOL_ID}" \
  "Koios pool delegation"
assert_eq "${CNTOOLS_WALLET_DREP_DELEGATION}" "${TEST_DREP_ID}" \
  "Koios DRep delegation"
assert_eq "${CNTOOLS_WALLET_UTXO_COUNT}" "2" "Koios UTxO count"
assert_eq "${CNTOOLS_WALLET_ASSET_COUNT}" "1" "Koios asset count"
assert_eq "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_ASSET_ID}]}" "5" \
  "Koios native asset quantity"
assert_eq "${CNTOOLS_WALLET_ASSET_METADATA_STATUS}" "available" \
  "Koios asset metadata status"
assert_eq "${CNTOOLS_WALLET_ASSET_REGISTRY_NAMES[${TEST_ASSET_ID}]}" \
  "Fixture Token" "Koios registry name"
assert_eq "${CNTOOLS_WALLET_ASSET_TICKERS[${TEST_ASSET_ID}]}" "FIX" \
  "Koios registry ticker"
assert_eq "${CNTOOLS_WALLET_ASSET_DECIMALS[${TEST_ASSET_ID}]}" "6" \
  "Koios holding decimals"
assert_eq "${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${TEST_ASSET_ID}]}" "6" \
  "Koios registry decimals"
assert_eq "${CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE[${TEST_ASSET_ID}]}" "1" \
  "Koios per-asset metadata availability"
assert_eq "$(line_count "${HTTP_TRACE}")" "3" "Koios request count"
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
jq -e \
  --arg policy "${TEST_POLICY_ID}" \
  --arg asset "${TEST_ASSET_NAME}" \
  '._asset_list == [[$policy, $asset]]' \
  "${HTTP_CAPTURE_DIR}/asset_info.json" >/dev/null ||
  fail "Koios asset_info did not receive one deduplicated bulk asset list"
[[ "$(grep -c '/address_info' "${HTTP_TRACE}")" == "1" &&
   "$(grep -c '/account_info' "${HTTP_TRACE}")" == "1" &&
   "$(grep -c '/asset_info' "${HTTP_TRACE}")" == "1" ]] ||
  fail "Koios full query did not use one request per bulk endpoint"
grep -F "/address_info${CNTOOLS_WALLET_KOIOS_ADDRESS_SELECT}" \
  "${HTTP_TRACE}" >/dev/null ||
  fail "Koios funding query did not preserve balance as text"
grep -F "/account_info${CNTOOLS_WALLET_KOIOS_ACCOUNT_SELECT}" \
  "${HTTP_TRACE}" >/dev/null ||
  fail "Koios stake query did not preserve rewards as text"
if grep -F "${TEST_KOIOS_TOKEN}" \
    "${HTTP_ARGV_TRACE}" "${HTTP_ENV_TRACE}" "${LOG_TRACE}" >/dev/null; then
  fail "Koios token leaked into argv, child environment, or logs"
fi
[[ "$(grep -c $'\tY\t600$' "${HTTP_AUTH_TRACE}")" == "3" ]] ||
  fail "Koios authorization did not reach all HTTP calls through mode-0600 files"

: > "${UI_TRACE}"
cntools_wallet_render_query
grep -F $'DATA_ROW\t01 · Fixture Token\tAmount\t0.000005 FIX' \
  "${UI_TRACE}" >/dev/null ||
  fail "Koios native-assets table omitted the token holding"
grep -F $'DATA_ROW\t\tFingerprint\t'"${TEST_ASSET_FINGERPRINT}" \
  "${UI_TRACE}" >/dev/null ||
  fail "Koios native-assets table omitted the asset fingerprint"
grep -F $'DATA_ROW\t\tTicker\tFIX' \
  "${UI_TRACE}" >/dev/null ||
  fail "Koios token metadata table omitted the ticker"
grep -F $'DATA_ROW\t\tDescription\tFixture token metadata' \
  "${UI_TRACE}" >/dev/null ||
  fail "Koios token metadata table omitted the description"
cntools_wallet_query_cleanup
[[ -z "$(find "${CNTOOLS_TMP_DIR}" -type f -print)" ]] ||
  fail "Koios query left credential or response temporary files"

# Metadata lookup must stay bulk and split only at the shared public Koios
# payload ceiling. This also proves that every held identity survives batching.
reset_query_traces
cntools_wallet_query_reset
saved_koios_token="${CNTOOLS_KOIOS_TOKEN}"
CNTOOLS_KOIOS_TOKEN=""
bulk_asset_total=24
for (( bulk_index = 1; bulk_index <= bulk_asset_total; bulk_index++ )); do
  printf -v bulk_policy '%056x' "${bulk_index}"
  printf -v bulk_name '%02x' "${bulk_index}"
  cntools_wallet_asset_add "${bulk_policy}.${bulk_name}" "${bulk_index}" ||
    fail "could not prepare bulk metadata fixture asset ${bulk_index}"
done
cntools_wallet_query_koios_asset_metadata ||
  fail "valid size-bounded Koios metadata batches were rejected"
assert_eq "${CNTOOLS_WALLET_ASSET_METADATA_STATUS}" "available" \
  "bulk Koios metadata status"
bulk_requests=0
bulk_assets=0
while IFS=$'\t' read -r bulk_url bulk_payload; do
  [[ "${bulk_url}" == */asset_info\?select=* ]] || continue
  bulk_requests=$((bulk_requests + 1))
  (( ${#bulk_payload} <= CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES )) ||
    fail "Koios metadata batch exceeded the configured payload ceiling"
  bulk_batch_count="$(jq -er '._asset_list | length' <<< "${bulk_payload}")" ||
    fail "Koios metadata batch payload was malformed"
  bulk_assets=$((bulk_assets + bulk_batch_count))
done < "${HTTP_TRACE}"
(( bulk_requests > 1 )) ||
  fail "large Koios metadata lookup was not divided into bulk batches"
assert_eq "${bulk_assets}" "${bulk_asset_total}" \
  "Koios metadata assets across batches"
cntools_wallet_query_cleanup
CNTOOLS_KOIOS_TOKEN="${saved_koios_token}"

for metadata_scenario in fail missing duplicate extra malformed; do
  reset_query_traces
  KOIOS_SCENARIO="full"
  KOIOS_METADATA_SCENARIO="${metadata_scenario}"
  cntools_wallet_query \
    "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" ""
  assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "available" \
    "${metadata_scenario} metadata changed funding query status"
  assert_eq "${CNTOOLS_WALLET_TOTAL_LOVELACE}" "3300000" \
    "${metadata_scenario} metadata erased the funding total"
  assert_eq "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_ASSET_ID}]}" "5" \
    "${metadata_scenario} metadata erased the native asset quantity"
  assert_eq "${CNTOOLS_WALLET_ASSET_METADATA_STATUS}" "unavailable" \
    "${metadata_scenario} metadata status"
  assert_empty "${CNTOOLS_WALLET_ASSET_REGISTRY_NAMES[${TEST_ASSET_ID}]:-}" \
    "${metadata_scenario} metadata committed an invalid registry name"
  assert_eq "$(line_count "${HTTP_TRACE}")" "2" \
    "${metadata_scenario} metadata request count"
done

: > "${UI_TRACE}"
cntools_wallet_render_query
grep -F $'\tRaw quantity\t5' \
  "${UI_TRACE}" >/dev/null ||
  fail "metadata failure hid a valid Koios native asset holding"
grep -F $'STATUS\twarn\tKoios token metadata is unavailable; holdings remain complete.' \
  "${UI_TRACE}" >/dev/null ||
  fail "metadata failure was not explained without invalidating holdings"
KOIOS_METADATA_SCENARIO="full"

reset_query_traces
KOIOS_SCENARIO="full"
KOIOS_METADATA_SCENARIO="hostile"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" ""
assert_eq "${CNTOOLS_WALLET_ASSET_METADATA_STATUS}" "available" \
  "sanitized Koios metadata status"
assert_eq "${CNTOOLS_WALLET_ASSET_REGISTRY_NAMES[${TEST_ASSET_ID}]}" \
  "Fixture Token " "Koios metadata bidi and C1 sanitization"
assert_eq "${CNTOOLS_WALLET_ASSET_TICKERS[${TEST_ASSET_ID}]}" \
  "F IX" "Koios metadata isolate sanitization"
assert_eq "${#CNTOOLS_WALLET_ASSET_DESCRIPTIONS[${TEST_ASSET_ID}]}" \
  "160" "Koios metadata description bound"
[[ "${CNTOOLS_WALLET_ASSET_DESCRIPTIONS[${TEST_ASSET_ID}]}" == *… ]] ||
  fail "truncated Koios metadata description omitted its ellipsis"
hostile_registry_name="${CNTOOLS_WALLET_ASSET_REGISTRY_NAMES[${TEST_ASSET_ID}]}"
if [[ "${hostile_registry_name}" == *$'\u202e'* ||
      "${hostile_registry_name}" == *$'\u0085'* ]]; then
  fail "hostile Koios metadata retained terminal control characters"
fi
KOIOS_METADATA_SCENARIO="full"

reset_query_traces
KOIOS_SCENARIO="stake-special-drep"
cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_DREP_DELEGATION}" "drep_always_abstain" \
  "Koios predefined DRep value"
: > "${UI_TRACE}"
cntools_wallet_render_delegation_table
grep -F $'DATA_ROW\tDRep delegation\tDelegated · Always abstain' \
  "${UI_TRACE}" >/dev/null ||
  fail "Koios predefined DRep value was not humanized"

reset_query_traces
KOIOS_SCENARIO="stake-malformed-delegation"
cntools_wallet_query "" "" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unavailable" \
  "malformed Koios delegation query status"
assert_empty "${CNTOOLS_WALLET_POOL_DELEGATION}" \
  "malformed Koios pool delegation was accepted"
assert_empty "${CNTOOLS_WALLET_DREP_DELEGATION}" \
  "malformed Koios DRep delegation was accepted"

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
grep -F $'DATA_ROW\tBase UTxO\t1.100000 ADA' \
  "${UI_TRACE}" >/dev/null ||
  fail "partial Koios balance table promoted a subtotal to Total UTxO"
grep -F $'DATA_ROW\tTotal UTxO\tUnavailable' "${UI_TRACE}" >/dev/null ||
  fail "partial Koios subtotal was rendered as Total UTxO"
if grep -F $'DETAIL\tNative assets' "${UI_TRACE}" >/dev/null; then
  fail "partial Koios native assets were rendered as a real zero"
fi

reset_query_traces
KOIOS_SCENARIO="oversized-quantity"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" ""
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "unavailable" \
  "oversized Koios quantity query status"
assert_no_funding_aggregate "oversized Koios quantity query"
assert_empty "${CNTOOLS_WALLET_ASSET_QUANTITIES[${TEST_ASSET_ID}]:-}" \
  "oversized Koios quantity changed native-asset holdings"

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

# Wallet List sends one deduplicated catalog request per Koios endpoint, then
# projects the shared response back to every wallet.
cntools_wallet_catalog_build || fail "Koios List catalog build failed"
reset_query_traces
KOIOS_SCENARIO="full"
cntools_wallet_list_query_catalog || fail "Koios Wallet List query failed"
assert_eq "$(line_count "${HTTP_TRACE}")" "2" \
  "Koios multi-wallet List bulk request count"
jq -e --arg base "${TEST_BASE_ADDRESS}" \
  --arg payment "${TEST_PAYMENT_ADDRESS}" '
    ._addresses | length == 2 and
    (index($base) != null) and (index($payment) != null) and
    (unique | length == 2)
  ' "${HTTP_CAPTURE_DIR}/address_info.json" >/dev/null ||
  fail "Koios List did not globally deduplicate funding addresses"
for wallet_index in 0 1; do
  assert_eq "${CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[wallet_index]}" \
    "1100000" "Koios List wallet ${wallet_index} base UTxO balance"
  assert_eq "${CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[wallet_index]}" \
    "2200000" "Koios List wallet ${wallet_index} payment UTxO balance"
  assert_eq "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[wallet_index]}" "3300000" \
    "Koios List wallet ${wallet_index} UTxO balance"
  assert_eq "${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[wallet_index]}" "880000" \
    "Koios List wallet ${wallet_index} rewards"
  assert_eq "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[wallet_index]}" "4180000" \
    "Koios List wallet ${wallet_index} inclusive total"
  assert_eq "${CNTOOLS_WALLET_LIST_TOKEN_COUNTS[wallet_index]}" "1" \
    "Koios List wallet ${wallet_index} token union"
  assert_eq "${CNTOOLS_WALLET_LIST_QUERY_STATUSES[wallet_index]}" "available" \
    "Koios List wallet ${wallet_index} status"
done

reset_query_traces
: > "${UI_TRACE}"
CONFIRM_STATUS=0
( cntools_wallet_action_list ) || fail "accepted Koios List action failed"
grep -Fx $'SPIN\tFetching wallet balances and rewards from Koios…' \
  "${UI_TRACE}" >/dev/null || fail "Koios List did not use the Gum spinner"
assert_eq "$(line_count "${HTTP_TRACE}")" "2" \
  "accepted Koios List bulk request count"

reset_query_traces
: > "${UI_TRACE}"
CONFIRM_STATUS=1
( cntools_wallet_action_list ) || fail "declined Koios List action failed"
assert_eq "$(line_count "${HTTP_TRACE}")" "0" \
  "declined Koios List request count"
[[ "$(grep -c '^SPIN' "${UI_TRACE}" || true)" == "0" ]] ||
  fail "declined Koios List started the balance spinner"

reset_query_traces
KOIOS_SCENARIO="partial-missing"
cntools_wallet_list_query_catalog || fail "partial Koios Wallet List failed"
for wallet_index in 0 1; do
  assert_eq "${CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[wallet_index]}" \
    "1100000" "partial Koios List base balance"
  assert_empty \
    "${CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[wallet_index]}" \
    "partial Koios List payment balance"
  assert_empty "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[wallet_index]}" \
    "partial Koios List UTxO aggregate"
  assert_eq "${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[wallet_index]}" "880000" \
    "partial Koios List rewards"
  assert_empty "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[wallet_index]}" \
    "partial Koios List total"
  assert_empty "${CNTOOLS_WALLET_LIST_TOKEN_COUNTS[wallet_index]}" \
    "partial Koios List token count"
  assert_eq "${CNTOOLS_WALLET_LIST_QUERY_STATUSES[wallet_index]}" "partial" \
    "partial Koios List status"
done

reset_query_traces
KOIOS_SCENARIO="stake-number"
cntools_wallet_list_query_catalog || fail "numeric Koios rewards List failed"
assert_eq "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[0]}" "3300000" \
  "numeric Koios rewards damaged funding result"
assert_empty "${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[0]}" \
  "invalid numeric Koios rewards became a false zero"
assert_empty "${CNTOOLS_WALLET_LIST_STAKE_REWARDS[${TEST_REWARD_ADDRESS}]:-}" \
  "failed Koios stake batch committed partial state"

reset_query_traces
KOIOS_SCENARIO="invalid-asset"
cntools_wallet_list_query_catalog || fail "invalid Koios asset List failed"
assert_empty "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[0]}" \
  "invalid Koios asset batch committed a funding balance"
assert_empty "${CNTOOLS_WALLET_LIST_TOKEN_COUNTS[0]}" \
  "invalid Koios asset identity affected the token count"

reset_query_traces
KOIOS_SCENARIO="null-asset-name"
cntools_wallet_list_query_catalog || fail "null-name Koios asset List failed"
assert_eq "${CNTOOLS_WALLET_LIST_TOKEN_COUNTS[0]}" "1" \
  "valid empty-name Koios asset was not counted"
assert_eq "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[0]}" "4180000" \
  "valid empty-name Koios asset invalidated the wallet total"

reset_query_traces
KOIOS_SCENARIO="full"
cntools_wallet_list_koios_payload _addresses one_address_payload \
  "${TEST_BASE_ADDRESS}" || fail "could not size a one-address Koios payload"
CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES="${#one_address_payload}"
cntools_wallet_list_query_catalog || fail "split Koios Wallet List query failed"
assert_eq "$(grep -c '/address_info' "${HTTP_TRACE}")" "2" \
  "Koios List funding payload was not split at its size bound"
assert_eq "$(grep -c '/account_info' "${HTTP_TRACE}")" "1" \
  "Koios List split duplicated its reward request"
assert_eq "${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[0]}" "4180000" \
  "split Koios List changed the projected total"
CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES=1024

reset_query_traces
CNTOOLS_MODE="offline"
CNTOOLS_BACKEND="none"
cntools_wallet_query \
  "${TEST_BASE_ADDRESS}" "${TEST_PAYMENT_ADDRESS}" "${TEST_REWARD_ADDRESS}"
assert_eq "${CNTOOLS_WALLET_QUERY_STATUS}" "offline" "offline query status"
[[ ! -s "${HTTP_TRACE}" && ! -s "${CLI_TRACE}" ]] ||
  fail "offline wallet query contacted a backend"
cntools_wallet_list_query_catalog || fail "offline Wallet List query failed"
[[ ! -s "${HTTP_TRACE}" && ! -s "${CLI_TRACE}" ]] ||
  fail "offline Wallet List contacted a backend"
assert_contains "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" "Offline mode" \
  "offline Wallet List summary"

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
reset_query_traces
cntools_wallet_list_query_catalog || fail "Amaru Wallet List query failed"
[[ ! -s "${HTTP_TRACE}" && ! -s "${CLI_TRACE}" ]] ||
  fail "Amaru Wallet List contacted an unsupported backend"
assert_contains "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" \
  "does not provide local wallet queries" "Amaru Wallet List explanation"

: > "${UI_TRACE}"
CONFIRM_STATUS=0
( cntools_wallet_action_list ) || fail "Amaru List action failed"
[[ "$(grep -Ec '^(CONFIRM|SPIN)' "${UI_TRACE}" || true)" == "0" ]] ||
  fail "Amaru List action prompted for or fetched unsupported balances"
[[ ! -s "${HTTP_TRACE}" && ! -s "${CLI_TRACE}" ]] ||
  fail "Amaru List action contacted an unsupported backend"

printf 'CNTools wallet tests passed\n'
