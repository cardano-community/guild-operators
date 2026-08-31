#!/usr/bin/env bash
# Focused Wallet -> New -> CLI acceptance tests.
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2129,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet creation tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
WALLET_LIBRARY="${CNTOOLS_ROOT}/lib/wallet.sh"
MATERIAL_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-material.sh"
KEY_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-key.sh"
ADDRESS_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-address.sh"
ID_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-id.sh"
CREATE_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-create.sh"
CREATE_UI_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-create-ui.sh"
NEW_CLI_ACTION="${CNTOOLS_ROOT}/modules/root/wallet/new/cli"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-new.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_CLI="${TEST_ROOT}/cardano-cli"

# Keep command fixtures tied to the exact CLI deployed by Guild Deploy. A pin
# change must deliberately update this compatibility target and its fake CLI.
TESTED_CARDANO_CLI_VERSION="11.0.0.0"

TEST_BASE_ADDRESS="addr_test1qpfepft9zs3y8ejcv84tq6tkp00wdm46fr6h3am02leunk8dc55q34v2ggxw9hea4rr3rry933a2zdh60v43h237s8ks7t2dja"
TEST_PAYMENT_ADDRESS="addr_test1vpfepft9zs3y8ejcv84tq6tkp00wdm46fr6h3am02leunkqtddwf6"
TEST_REWARD_ADDRESS="stake_test1urku22qg6k9yyr8zmu7633c33jzcc74pxma8k2cm4glgrmgrmu5lc"
MAIN_BASE_ADDRESS="addr1qy2jt0qpqz2z2z9zx5w4xemekkce7yderz53kjue53lpqv90lkfa9sgrfjuz6uvt4uqtrqhl2kj0a9lnr9ndzutx32gqleeckv"
MAIN_PAYMENT_ADDRESS="addr1vy2jt0qpqz2z2z9zx5w4xemekkce7yderz53kjue53lpqvqmw5nzn"
MAIN_REWARD_ADDRESS="stake1uyrx65wjqjgeeksd8hptmcgl5jfyrqkfq0xe8xlp367kphsckq250"
PAYMENT_CREDENTIAL="11111111111111111111111111111111111111111111111111111111"
STAKE_CREDENTIAL="22222222222222222222222222222222222222222222222222222222"
PRIVATE_KEY_SENTINEL="5820feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"
STAKE_PRIVATE_KEY_SENTINEL="5820$(printf 'cd%.0s' {1..32})"
PAYMENT_VERIFICATION_CBOR="5820$(printf 'ab%.0s' {1..32})"
STAKE_VERIFICATION_CBOR="5820$(printf 'bc%.0s' {1..32})"
MISMATCHED_VERIFICATION_CBOR="5820$(printf 'de%.0s' {1..32})"

CASE_ROOT=""
WALLET_ROOT=""
CNTOOLS_TMP_DIR=""
LOG_TRACE=""
UI_TRACE=""
CLI_TRACE=""
ACTION_STATUS=0
UI_INPUT_INDEX=0
UI_CONFIRM_STATUS=0
declare -ag UI_INPUT_VALUES=()
declare -ag UI_INPUT_STATUSES=()

cleanup_test() {
  chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_pinned_cardano_cli_versions() {
  local implementation=""
  local manifest=""
  local pinned_version=""

  for implementation in cnode dingo; do
    manifest="${REPO_ROOT}/files/node-implementations/${implementation}/release.json"
    pinned_version="$(
      jq -er '.companions["cardano-cli"].version' "${manifest}"
    )" || fail "${implementation} does not declare a pinned cardano-cli version"
    [[ "${pinned_version}" == "${TESTED_CARDANO_CLI_VERSION}" ]] ||
      fail "${implementation} pins cardano-cli ${pinned_version}; review the wallet command fixtures tested against ${TESTED_CARDANO_CLI_VERSION}"
  done
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="${3:-values differ}"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_contains() {
  local actual="$1"
  local expected="$2"
  local context="${3:-text is missing}"

  [[ "${actual}" == *"${expected}"* ]] ||
    fail "${context}: '${expected}' was not found"
}

assert_pinned_cardano_cli_versions

assert_file_contains() {
  local file="$1"
  local expected="$2"
  local context="${3:-file text is missing}"

  grep -F -- "${expected}" "${file}" >/dev/null ||
    fail "${context}: '${expected}' was not found in ${file}"
}

assert_file_not_contains() {
  local file="$1"
  local unexpected="$2"
  local context="${3:-unexpected file text}"

  if grep -F -- "${unexpected}" "${file}" >/dev/null; then
    fail "${context}: '${unexpected}' was found in ${file}"
  fi
}

line_count() {
  local file="$1"

  if [[ -s "${file}" ]]; then
    wc -l < "${file}" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

file_mode() {
  local path="$1"
  local mode=""

  if mode="$(stat -c '%a' -- "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -f '%Lp' "${path}"
  fi
}

for required_command in \
  bash chmod find grep jq ln mktemp mkdir mv rm sed sort stat tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

for required_file in \
  "${WALLET_LIBRARY}" "${MATERIAL_LIBRARY}" "${KEY_LIBRARY}" \
  "${ADDRESS_LIBRARY}" "${ID_LIBRARY}" "${CREATE_LIBRARY}" \
  "${CREATE_UI_LIBRARY}" \
  "${NEW_CLI_ACTION}/module.json" "${NEW_CLI_ACTION}/action.sh"; do
  [[ -f "${required_file}" && ! -L "${required_file}" && -s "${required_file}" ]] ||
    fail "required CNTools source is missing or unsafe: ${required_file}"
done

bash -n \
  "${WALLET_LIBRARY}" "${MATERIAL_LIBRARY}" "${KEY_LIBRARY}" \
  "${ADDRESS_LIBRARY}" "${ID_LIBRARY}" "${CREATE_LIBRARY}" \
  "${CREATE_UI_LIBRARY}" \
  "${NEW_CLI_ACTION}/action.sh" ||
  fail "wallet creation sources have invalid Bash syntax"

jq -e '
  .kind == "action" and .label == "CLI" and
  .modes == ["local", "light", "offline"] and
  .libs == [
    "wallet.sh",
    "wallet-material.sh",
    "wallet-key.sh",
    "wallet-address.sh",
    "wallet-id.sh",
    "wallet-create.sh",
    "wallet-create-ui.sh"
  ]
' "${NEW_CLI_ACTION}/module.json" >/dev/null ||
  fail "Wallet New CLI metadata does not declare the focused creation stack"

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/menu.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/action.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/theme.sh"
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
. "${CREATE_LIBRARY}"
# shellcheck source=/dev/null
. "${CREATE_UI_LIBRARY}"

CNTOOLS_MODULE_ROOT="${CNTOOLS_ROOT}/modules/root"
CNTOOLS_LIB_DIR="${CNTOOLS_ROOT}/lib"
CNTOOLS_VALIDATION_BASH="${BASH}"
CNTOOLS_CLI_TIMEOUT="3"
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_UI_INTERACTIVE="Y"
CNTOOLS_UI_COLUMNS="140"
NO_COLOR=1

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

cntools_log() {
  printf '%s\t%s\t%s\n' \
    "${1:-INFO}" "${CNTOOLS_ACTION_ID:-session}" "${2:-}" >> "${LOG_TRACE}"
}

cntools_ui_action_begin() {
  printf 'BEGIN\t%s\t%s\n' "${1:-}" "${2:-}" >> "${UI_TRACE}"
}

cntools_ui_render_begin() {
  cntools_ui_action_begin "$@"
}

cntools_ui_render_status() {
  printf 'STATUS\t%s\t%s\n' "${1:-}" "${2:-}" >> "${UI_TRACE}"
}

cntools_ui_render_field() {
  printf 'FIELD\t%s\t%s\n' "${1:-}" "${2:-}" >> "${UI_TRACE}"
}

cntools_ui_render_detail() {
  printf 'DETAIL\t%s\n' "${1:-}" >> "${UI_TRACE}"
}

cntools_ui_table() {
  local line=""

  printf 'TABLE_ARGS' >> "${UI_TRACE}"
  printf '\t%s' "$@" >> "${UI_TRACE}"
  printf '\n' >> "${UI_TRACE}"
  while IFS= read -r line; do
    printf 'TABLE_ROW\t%s\n' "${line}" >> "${UI_TRACE}"
  done
}

cntools_ui_input() {
  local output_name="${1:-}"
  local prompt="${2:-}"
  local status=1
  local value=""

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  printf 'INPUT\t%s\n' "${prompt}" >> "${UI_TRACE}"
  if (( UI_INPUT_INDEX < ${#UI_INPUT_STATUSES[@]} )); then
    status="${UI_INPUT_STATUSES[UI_INPUT_INDEX]}"
  fi
  if (( UI_INPUT_INDEX < ${#UI_INPUT_VALUES[@]} )); then
    value="${UI_INPUT_VALUES[UI_INPUT_INDEX]}"
  fi
  UI_INPUT_INDEX=$((UI_INPUT_INDEX + 1))
  (( status == 0 )) || return "${status}"
  printf -v "${output_name}" '%s' "${value}"
}

cntools_ui_confirm() {
  printf 'CONFIRM\t%s\n' "${1:-}" >> "${UI_TRACE}"
  return "${UI_CONFIRM_STATUS}"
}

cntools_ui_spin_function() {
  local title="${1:-Working}"
  shift || return 2

  printf 'SPIN\t%s\n' "${title}" >> "${UI_TRACE}"
  FAKE_ACTION_PID="${BASHPID}"
  export FAKE_ACTION_PID
  "$@"
}

cntools_ui_wait() {
  printf 'WAIT\n' >> "${UI_TRACE}"
}

cntools_gum_clear() {
  printf 'CLEAR\n' >> "${UI_TRACE}"
}

cntools_ui_content_width() {
  printf '138\n'
}

# macOS chmod does not accept the GNU/POSIX operand separator used by the
# Linux-targeted implementation. Strip only that separator in this test double
# so the same creation paths can be exercised on development Macs.
CNTOOLS_TEST_CHMOD_BIN="$(type -P chmod)"
chmod() {
  local argument=""
  local -a arguments=()

  for argument in "$@"; do
    [[ "${argument}" == "--" ]] && continue
    arguments+=("${argument}")
  done
  "${CNTOOLS_TEST_CHMOD_BIN}" "${arguments[@]}"
}

# Wallet publication intentionally depends on GNU mv's atomic no-clobber
# directory semantics. Exercise that contract on non-GNU development hosts as
# well as Linux CI without weakening the production preflight.
CNTOOLS_TEST_MV_BIN="$(type -P mv)"
mv() {
  if (( $# == 1 )) && [[ "$1" == "--help" ]]; then
    printf '%s\n' '  -n, --no-clobber' '  -T, --no-target-directory'
    return 0
  fi
  if (( $# == 5 )) && [[ "$1" == "-T" && "$2" == "-n" && "$3" == "--" ]]; then
    [[ ! -e "$5" && ! -L "$5" ]] || return 0
    "${CNTOOLS_TEST_MV_BIN}" -- "$4" "$5" || return
    if [[ "${FAKE_CLI_SCENARIO:-}" == "post-publish-invalid" ]]; then
      printf 'invalid-after-commit\n' > "$5/base.addr"
    fi
    return
  fi
  "${CNTOOLS_TEST_MV_BIN}" "$@"
}

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "${FAKE_CLI_TRACE}"' \
  'arguments=("$@")' \
  'command_pair="${arguments[0]:-} ${arguments[1]:-}"' \
  'if [[ "${arguments[0]:-}" == "latest" ]]; then' \
  '  command_pair="${arguments[0]:-} ${arguments[1]:-} ${arguments[2]:-}"' \
  'fi' \
  'verification_file=""' \
  'signing_file=""' \
  'output_file=""' \
  'while (( $# > 0 )); do' \
  '  case "$1" in' \
  '    --verification-key-file) verification_file="$2"; shift 2 ;;' \
  '    --signing-key-file) signing_file="$2"; shift 2 ;;' \
  '    --out-file) output_file="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'case "${command_pair}" in' \
  '  "address key-gen")' \
  '    if [[ "${FAKE_CLI_SCENARIO}" == "interrupt-payment" ]]; then' \
  '      kill -TERM "${FAKE_ACTION_PID:?}"' \
  '      sleep 0.2' \
  '      exit 143' \
  '    fi' \
  '    if [[ "${FAKE_CLI_SCENARIO}" == "payment-fail" ]]; then' \
  '      printf "%s\n" "fixture payment key generation failed" >&2' \
  '      exit 41' \
  '    fi' \
  '    payment_verification_cbor="${FAKE_PAYMENT_VERIFICATION_CBOR^^}"' \
  '    [[ "${FAKE_CLI_SCENARIO}" != "payment-pair-mismatch" ]] || payment_verification_cbor="${FAKE_MISMATCHED_VERIFICATION_CBOR}"' \
  '    [[ "${FAKE_CLI_SCENARIO}" != "payment-key-invalid" ]] || payment_verification_cbor="00"' \
  '    printf "{\"type\":\"PaymentVerificationKeyShelley_ed25519\",\"description\":\"Payment Verification Key\",\"cborHex\":\"%s\"}\n" "${payment_verification_cbor}" > "${verification_file}"' \
  '    printf "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"Payment Signing Key\",\"cborHex\":\"%s\"}\n" "${FAKE_PAYMENT_SIGNING_CBOR}" > "${signing_file}"' \
  '    ;;' \
  '  "latest stake-address key-gen")' \
  '    if [[ "${FAKE_CLI_SCENARIO}" == "stake-fail" ]]; then' \
  '      printf "%s\n" "fixture stake key generation failed" >&2' \
  '      exit 42' \
  '    fi' \
  '    stake_verification_cbor="${FAKE_STAKE_VERIFICATION_CBOR}"' \
  '    [[ "${FAKE_CLI_SCENARIO}" != "stake-pair-mismatch" ]] || stake_verification_cbor="${FAKE_MISMATCHED_VERIFICATION_CBOR}"' \
  '    printf "{\"type\":\"StakeVerificationKeyShelley_ed25519\",\"description\":\"Stake Verification Key\",\"cborHex\":\"%s\"}\n" "${stake_verification_cbor}" > "${verification_file}"' \
  '    printf "{\"type\":\"StakeSigningKeyShelley_ed25519\",\"description\":\"Stake Signing Key\",\"cborHex\":\"%s\"}\n" "${FAKE_STAKE_SIGNING_CBOR}" > "${signing_file}"' \
  '    ;;' \
  '  "key verification-key")' \
  '    signing_type="$(jq -er .type "${signing_file}")"' \
  '    signing_cbor="$(jq -er .cborHex "${signing_file}")"' \
  '    case "${signing_type}:${signing_cbor}" in' \
  '      "PaymentSigningKeyShelley_ed25519:${FAKE_PAYMENT_SIGNING_CBOR}")' \
  '        verification_type="PaymentVerificationKeyShelley_ed25519"' \
  '        verification_cbor="${FAKE_PAYMENT_VERIFICATION_CBOR}"' \
  '        ;;' \
  '      "StakeSigningKeyShelley_ed25519:${FAKE_STAKE_SIGNING_CBOR}")' \
  '        verification_type="StakeVerificationKeyShelley_ed25519"' \
  '        verification_cbor="${FAKE_STAKE_VERIFICATION_CBOR}"' \
  '        ;;' \
  '      *) printf "unexpected signing key envelope\n" >&2; exit 92 ;;' \
  '    esac' \
  '    if [[ "${FAKE_CLI_SCENARIO}" == "payment-pair-command-fail" && "${verification_type}" == Payment* ]]; then' \
  '      printf "fixture payment pair derivation failed\n" >&2' \
  '      exit 43' \
  '    fi' \
  '    [[ "${FAKE_CLI_SCENARIO}" != "payment-derived-invalid" || "${verification_type}" != Payment* ]] || verification_cbor="00"' \
  '    printf "{\"type\":\"%s\",\"description\":\"Derived Verification Key\",\"cborHex\":\"%s\"}\n" "${verification_type}" "${verification_cbor}" > "${verification_file}"' \
  '    ;;' \
  '  "address build")' \
  '    if [[ " ${arguments[*]} " == *" --stake-verification-key-file "* ]]; then' \
  '      printf "%s\n" "${FAKE_BASE_ADDRESS}" > "${output_file}"' \
  '    else' \
  '      printf "%s\n" "${FAKE_PAYMENT_ADDRESS}" > "${output_file}"' \
  '    fi' \
  '    ;;' \
  '  "latest stake-address build")' \
  '    printf "%s\n" "${FAKE_REWARD_ADDRESS}" > "${output_file}"' \
  '    ;;' \
  '  "address key-hash")' \
  '    printf "%s\n" "${FAKE_PAYMENT_CREDENTIAL}" > "${output_file}"' \
  '    ;;' \
  '  "latest stake-address key-hash")' \
  '    printf "%s\n" "${FAKE_STAKE_CREDENTIAL}" > "${output_file}"' \
  '    if [[ "${FAKE_CLI_SCENARIO}" == "publish-collision" ]]; then' \
  '      mkdir -- "${FAKE_COLLISION_TARGET:?}"' \
  '      printf "%s\n" "preserve-collision" > "${FAKE_COLLISION_TARGET}/marker"' \
  '    fi' \
  '    ;;' \
  '  *)' \
  '    printf "unexpected fake cardano-cli command: %s\n" "${arguments[*]}" >&2' \
  '    exit 91' \
  '    ;;' \
  'esac' > "${FAKE_CLI}"
chmod 0700 "${FAKE_CLI}"

reset_case() {
  local case_name="$1"
  local mode="${2:-offline}"
  local network="${3:-preview}"

  CASE_ROOT="${TEST_ROOT}/${case_name}"
  rm -rf -- "${CASE_ROOT}"
  mkdir -p "${CASE_ROOT}/wallets" "${CASE_ROOT}/tmp"
  chmod 0700 "${CASE_ROOT}" "${CASE_ROOT}/wallets" "${CASE_ROOT}/tmp"
  WALLET_ROOT="${CASE_ROOT}/wallets"
  CNTOOLS_WALLET_DIR="${WALLET_ROOT}"
  CNTOOLS_TMP_DIR="${CASE_ROOT}/tmp"
  LOG_TRACE="${CASE_ROOT}/wallet-new.log"
  UI_TRACE="${CASE_ROOT}/ui.log"
  CLI_TRACE="${CASE_ROOT}/cli.log"
  : > "${LOG_TRACE}"
  : > "${UI_TRACE}"
  : > "${CLI_TRACE}"
  chmod 0600 "${LOG_TRACE}" "${UI_TRACE}" "${CLI_TRACE}"

  CNTOOLS_MODE="${mode}"
  CNTOOLS_NETWORK="${network}"
  CNTOOLS_BACKEND="none"
  case "${mode}" in
    local) CNTOOLS_BACKEND="cnode" ;;
    light) CNTOOLS_BACKEND="koios" ;;
  esac
  CNTOOLS_CLI="${FAKE_CLI}"
  CNTOOLS_LOG="${LOG_TRACE}"
  CNTOOLS_ACTION_ID=""
  CNTOOLS_ACTION_LABEL=""
  CNTOOLS_WALLET_MATERIAL_TEMP_FILES=()
  UI_INPUT_VALUES=()
  UI_INPUT_STATUSES=()
  UI_INPUT_INDEX=0
  UI_CONFIRM_STATUS=0
  ACTION_STATUS=0

  FAKE_CLI_TRACE="${CLI_TRACE}"
  FAKE_CLI_SCENARIO="success"
  FAKE_COLLISION_TARGET=""
  FAKE_PAYMENT_SIGNING_CBOR="${PRIVATE_KEY_SENTINEL}"
  FAKE_STAKE_SIGNING_CBOR="${STAKE_PRIVATE_KEY_SENTINEL}"
  FAKE_PAYMENT_VERIFICATION_CBOR="${PAYMENT_VERIFICATION_CBOR}"
  FAKE_STAKE_VERIFICATION_CBOR="${STAKE_VERIFICATION_CBOR}"
  FAKE_MISMATCHED_VERIFICATION_CBOR="${MISMATCHED_VERIFICATION_CBOR}"
  FAKE_PAYMENT_CREDENTIAL="${PAYMENT_CREDENTIAL}"
  FAKE_STAKE_CREDENTIAL="${STAKE_CREDENTIAL}"
  if [[ "${network}" == "mainnet" ]]; then
    FAKE_BASE_ADDRESS="${MAIN_BASE_ADDRESS}"
    FAKE_PAYMENT_ADDRESS="${MAIN_PAYMENT_ADDRESS}"
    FAKE_REWARD_ADDRESS="${MAIN_REWARD_ADDRESS}"
  else
    FAKE_BASE_ADDRESS="${TEST_BASE_ADDRESS}"
    FAKE_PAYMENT_ADDRESS="${TEST_PAYMENT_ADDRESS}"
    FAKE_REWARD_ADDRESS="${TEST_REWARD_ADDRESS}"
  fi
  export CNTOOLS_MODE CNTOOLS_NETWORK CNTOOLS_BACKEND
  export CNTOOLS_CLI CNTOOLS_LOG CNTOOLS_TMP_DIR CNTOOLS_WALLET_DIR
  export FAKE_CLI_TRACE FAKE_CLI_SCENARIO FAKE_COLLISION_TARGET
  export FAKE_PAYMENT_SIGNING_CBOR FAKE_STAKE_SIGNING_CBOR
  export FAKE_PAYMENT_VERIFICATION_CBOR FAKE_STAKE_VERIFICATION_CBOR
  export FAKE_MISMATCHED_VERIFICATION_CBOR FAKE_PAYMENT_CREDENTIAL
  export FAKE_STAKE_CREDENTIAL FAKE_BASE_ADDRESS FAKE_PAYMENT_ADDRESS
  export FAKE_REWARD_ADDRESS
}

set_single_input() {
  UI_INPUT_VALUES=("$1")
  UI_INPUT_STATUSES=(0)
  UI_INPUT_INDEX=0
}

run_action() {
  ACTION_STATUS=0
  if cntools_action_run "${NEW_CLI_ACTION}"; then
    ACTION_STATUS=0
  else
    ACTION_STATUS=$?
  fi
}

assert_no_creation_debris() {
  local context="$1"
  local debris=""

  debris="$(find "${WALLET_ROOT}" -mindepth 1 -maxdepth 1 \
    -name '.cntools-*' -print -quit)"
  [[ -z "${debris}" ]] ||
    fail "${context}: retained wallet staging path ${debris}"
  debris="$(find "${CNTOOLS_TMP_DIR}" -mindepth 1 -print -quit)"
  [[ -z "${debris}" ]] ||
    fail "${context}: retained temporary path ${debris}"
}

assert_log_secrecy() {
  local context="$1"

  assert_file_not_contains "${LOG_TRACE}" "${PRIVATE_KEY_SENTINEL}" \
    "${context} logged private key material"
  assert_file_not_contains "${UI_TRACE}" "${PRIVATE_KEY_SENTINEL}" \
    "${context} displayed private key material"
  assert_file_not_contains "${LOG_TRACE}" "${STAKE_PRIVATE_KEY_SENTINEL}" \
    "${context} logged stake private key material"
  assert_file_not_contains "${UI_TRACE}" "${STAKE_PRIVATE_KEY_SENTINEL}" \
    "${context} displayed stake private key material"
}

assert_wallet_shape() {
  local wallet_name="$1"
  local wallet="${WALLET_ROOT}/${wallet_name}"
  local actual_files=""
  local expected_files=""
  local unexpected=""
  local generated_file=""
  local address=""
  local credential=""

  [[ -d "${wallet}" && ! -L "${wallet}" ]] ||
    fail "created wallet directory is missing or unsafe: ${wallet_name}"
  assert_eq "$(file_mode "${wallet}")" "700" \
    "created wallet directory permissions"

  actual_files="$(
    cd "${wallet}"
    find . -mindepth 1 -maxdepth 1 -type f -print | LC_ALL=C sort
  )"
  expected_files="$({
    printf './%s\n' \
      base.addr payment.addr payment.cred payment.skey payment.vkey \
      reward.addr stake.cred stake.skey stake.vkey
  } | LC_ALL=C sort)"
  assert_eq "${actual_files}" "${expected_files}" \
    "created wallet file inventory"
  unexpected="$(find "${wallet}" -mindepth 1 -maxdepth 1 ! -type f -print -quit)"
  [[ -z "${unexpected}" ]] ||
    fail "created wallet contains a non-regular entry: ${unexpected}"

  for generated_file in \
    base.addr payment.addr payment.cred payment.skey payment.vkey \
    reward.addr stake.cred stake.skey stake.vkey; do
    assert_eq "$(file_mode "${wallet}/${generated_file}")" "600" \
      "${generated_file} permissions"
  done

  cntools_wallet_key_signing_type \
    payment "${wallet}/payment.skey" credential ||
    fail "created payment signing key is invalid"
  assert_eq "${credential}" "normal" "payment signing-key form"
  cntools_wallet_key_signing_type stake "${wallet}/stake.skey" credential ||
    fail "created stake signing key is invalid"
  assert_eq "${credential}" "normal" "stake signing-key form"
  cntools_wallet_key_validate "${wallet}/payment.vkey" payment normal ||
    fail "created payment verification key is invalid"
  cntools_wallet_key_validate "${wallet}/stake.vkey" stake normal ||
    fail "created stake verification key is invalid"
  cntools_wallet_key_normal_envelope_valid \
    "${wallet}/payment.skey" payment signing ||
    fail "created payment signing key does not use the strict normal shape"
  cntools_wallet_key_normal_envelope_valid \
    "${wallet}/stake.skey" stake signing ||
    fail "created stake signing key does not use the strict normal shape"
  cntools_wallet_key_normal_envelope_valid \
    "${wallet}/payment.vkey" payment verification ||
    fail "created payment verification key does not use the strict normal shape"
  cntools_wallet_key_normal_envelope_valid \
    "${wallet}/stake.vkey" stake verification ||
    fail "created stake verification key does not use the strict normal shape"
  cntools_wallet_read_address "${wallet}" base address ||
    fail "created base address is invalid"
  assert_eq "${address}" "${FAKE_BASE_ADDRESS}" "created base address"
  cntools_wallet_read_address "${wallet}" payment address ||
    fail "created payment address is invalid"
  assert_eq "${address}" "${FAKE_PAYMENT_ADDRESS}" "created payment address"
  cntools_wallet_read_address "${wallet}" reward address ||
    fail "created reward address is invalid"
  assert_eq "${address}" "${FAKE_REWARD_ADDRESS}" "created reward address"
  cntools_wallet_id_read_credential "${wallet}" payment credential ||
    fail "created payment credential is invalid"
  assert_eq "${credential}" "${PAYMENT_CREDENTIAL}" \
    "created payment credential"
  cntools_wallet_id_read_credential "${wallet}" stake credential ||
    fail "created stake credential is invalid"
  assert_eq "${credential}" "${STAKE_CREDENTIAL}" \
    "created stake credential"
  assert_eq "$(cntools_wallet_type "${wallet}")" "CLI" \
    "created wallet type"
  [[ ! -e "${wallet}/derivation.path" && ! -L "${wallet}/derivation.path" ]] ||
    fail "CLI wallet unexpectedly contains a mnemonic derivation path"
}

assert_successful_case() {
  local case_name="$1"
  local mode="$2"
  local network="$3"
  local wallet_name="$4"
  local expected_network_arguments="$5"

  reset_case "${case_name}" "${mode}" "${network}"
  set_single_input "${wallet_name}"
  UI_CONFIRM_STATUS=0
  run_action
  assert_eq "${ACTION_STATUS}" "0" \
    "${mode}/${network} wallet creation status"
  assert_wallet_shape "${wallet_name}"
  assert_eq "$(line_count "${CLI_TRACE}")" "9" \
    "${mode}/${network} Cardano CLI call count"
  assert_file_contains "${CLI_TRACE}" \
    "address key-gen" "payment key-generation command"
  assert_file_contains "${CLI_TRACE}" \
    "latest stake-address key-gen" "stake key-generation command"
  assert_file_contains "${CLI_TRACE}" \
    "latest stake-address build" "reward-address build command"
  assert_file_contains "${CLI_TRACE}" \
    "latest stake-address key-hash" "stake credential command"
  if grep -Eq '^stake-address (key-gen|build|key-hash)( |$)' "${CLI_TRACE}"; then
    fail "${mode}/${network} used an obsolete top-level stake command"
  fi
  assert_eq "$(grep -c -- 'key verification-key' "${CLI_TRACE}")" "2" \
    "${mode}/${network} signing-key pair checks"
  assert_eq "$(grep -c -- "${expected_network_arguments}" "${CLI_TRACE}")" "3" \
    "${mode}/${network} address network argument count"
  if grep -Eq '(^| )(query|latest query)( |$)|--socket-path|CARDANO_NODE_SOCKET_PATH' \
      "${CLI_TRACE}"; then
    fail "${mode}/${network} wallet creation performed a node query"
  fi
  assert_file_contains "${UI_TRACE}" $'BEGIN\tCLI\t/ Wallet / New / CLI' \
    "wallet creation breadcrumb"
  assert_file_contains "${UI_TRACE}" \
    $'CONFIRM\tCreate this CLI wallet now?' \
    "wallet creation confirmation"
  assert_file_contains "${UI_TRACE}" \
    "${WALLET_ROOT}/${wallet_name}" \
    "wallet creation planned target"
  assert_file_contains "${UI_TRACE}" \
    "payment.skey, stake.skey" \
    "wallet creation planned signing keys"
  assert_file_contains "${UI_TRACE}" \
    "payment.addr, reward.addr, base.addr" \
    "wallet creation planned addresses"
  assert_file_contains "${UI_TRACE}" \
    $'SPIN\tCreating CLI wallet '"${wallet_name}" \
    "wallet creation progress spinner"
  assert_file_contains "${UI_TRACE}" $'STATUS\tsuccess\t' \
    "wallet creation success status"
  assert_file_contains "${UI_TRACE}" "${wallet_name}" \
    "wallet creation success name"
  assert_file_contains "${UI_TRACE}" "${FAKE_BASE_ADDRESS}" \
    "wallet creation success base address"
  assert_eq "$(grep -c '^WAIT$' "${UI_TRACE}" || true)" "1" \
    "wallet creation return prompt count"
  assert_file_contains "${LOG_TRACE}" $'ACTION\twallet/new/cli\tselected' \
    "loader wallet creation selection log"
  assert_file_contains "${LOG_TRACE}" $'CMD\twallet/new/cli\t' \
    "wallet creation command log"
  assert_no_creation_debris "${mode}/${network} success"
  assert_log_secrecy "${mode}/${network} success"
}

# The same local workflow is valid in every runtime mode. Exercise all
# supported network selectors without ever requiring a node socket or Koios.
assert_successful_case \
  success-local-preview local preview LocalWallet '--testnet-magic 2'
assert_successful_case \
  success-light-preprod light preprod LightWallet '--testnet-magic 1'
assert_successful_case \
  success-offline-guild offline guild GuildWallet '--testnet-magic 141'
assert_successful_case \
  success-offline-mainnet offline mainnet MainnetWallet '--mainnet'

# Startup permits executable command paths that resolve through a symlink, as
# used by alternatives, profiles, and version managers. Creation follows that
# same runtime contract.
reset_case symlinked-cli offline preview
ln -s -- "${FAKE_CLI}" "${CASE_ROOT}/cardano-cli-current"
CNTOOLS_CLI="${CASE_ROOT}/cardano-cli-current"
export CNTOOLS_CLI
set_single_input SymlinkCliWallet
run_action
assert_eq "${ACTION_STATUS}" "0" "symlinked Cardano CLI creation status"
assert_wallet_shape SymlinkCliWallet
assert_eq "$(line_count "${CLI_TRACE}")" "9" \
  "symlinked Cardano CLI call count"
assert_no_creation_debris "symlinked Cardano CLI"
assert_log_secrecy "symlinked Cardano CLI"

# The wallet root may be initialized on first use, while an existing safe root
# keeps its administrator-selected non-writable group/public permissions.
reset_case create-missing-wallet-root offline preview
rmdir "${WALLET_ROOT}"
set_single_input FirstWallet
run_action
assert_eq "${ACTION_STATUS}" "0" "missing wallet root creation status"
assert_eq "$(file_mode "${WALLET_ROOT}")" "700" \
  "new wallet root mode"
assert_wallet_shape FirstWallet
assert_no_creation_debris "missing wallet root creation"

reset_case preserve-wallet-root-mode offline preview
chmod 0750 "${WALLET_ROOT}"
set_single_input PreservedRootWallet
run_action
assert_eq "${ACTION_STATUS}" "0" "existing wallet root creation status"
assert_eq "$(file_mode "${WALLET_ROOT}")" "750" \
  "existing wallet root mode"
assert_wallet_shape PreservedRootWallet
assert_no_creation_debris "existing wallet root mode"

# Escape from the name prompt is a handled cancellation, not an action error.
reset_case cancel-name offline preview
UI_INPUT_VALUES=("")
UI_INPUT_STATUSES=(1)
run_action
assert_eq "${ACTION_STATUS}" "0" "wallet-name cancellation status"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "wallet-name cancellation CLI call count"
assert_file_contains "${UI_TRACE}" "CLEAR" \
  "wallet-name cancellation screen cleanup"
[[ -z "$(find "${WALLET_ROOT}" -mindepth 1 -print -quit)" ]] ||
  fail "wallet-name cancellation created a wallet entry"
assert_no_creation_debris "wallet-name cancellation"

# Declining the explicit warning/confirmation also leaves the wallet root
# untouched and returns normally to the menu.
reset_case cancel-confirm offline preview
set_single_input DeclinedWallet
UI_CONFIRM_STATUS=1
run_action
assert_eq "${ACTION_STATUS}" "0" "wallet confirmation decline status"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "wallet confirmation decline CLI call count"
[[ ! -e "${WALLET_ROOT}/DeclinedWallet" ]] ||
  fail "declined wallet creation created its target"
assert_no_creation_debris "wallet confirmation decline"

assert_invalid_name() {
  local case_name="$1"
  local invalid_name="$2"

  reset_case "invalid-${case_name}" offline preview
  UI_INPUT_VALUES=("${invalid_name}" "")
  UI_INPUT_STATUSES=(0 1)
  run_action
  assert_eq "${ACTION_STATUS}" "0" \
    "invalid ${case_name} then cancellation status"
  assert_eq "$(line_count "${CLI_TRACE}")" "0" \
    "invalid ${case_name} CLI call count"
  if [[ "${invalid_name}" == */* ]]; then
    [[ ! -e "${WALLET_ROOT}/${invalid_name}" ]] ||
      fail "invalid ${case_name} escaped the wallet root"
  fi
  assert_file_contains "${UI_TRACE}" $'STATUS\twarn\t' \
    "invalid ${case_name} validation warning"
  assert_no_creation_debris "invalid ${case_name}"
}

assert_invalid_name empty ''
assert_invalid_name traversal '../escape'
assert_invalid_name separator 'bad/name'
assert_invalid_name reserved '.cntools-wallet-new.fixture'
assert_invalid_name control $'bad\nname'

# Internal transaction directories never appear as wallets, and a reserved
# symbolic-link entry is skipped without traversing its target.
reset_case internal-staging-catalog offline preview
mkdir "${WALLET_ROOT}/.cntools-wallet-new.fixture"
chmod 0700 "${WALLET_ROOT}/.cntools-wallet-new.fixture"
mkdir "${CASE_ROOT}/external-staging-target"
ln -s -- "${CASE_ROOT}/external-staging-target" \
  "${WALLET_ROOT}/.cntools-wallet-new.link"
cntools_wallet_catalog_build || fail "catalog rejected internal staging entries"
assert_eq "${#CNTOOLS_WALLET_PATHS[@]}" "0" \
  "internal staging catalog count"
assert_file_contains "${LOG_TRACE}" \
  "Skipped internal wallet staging directory (active or interrupted; may contain private key material): .cntools-wallet-new.fixture" \
  "internal staging directory log"
assert_file_contains "${LOG_TRACE}" \
  "Skipped unsafe reserved wallet staging entry: .cntools-wallet-new.link" \
  "unsafe reserved staging entry log"
rm -rf -- "${WALLET_ROOT}/.cntools-wallet-new.fixture"
rm -f -- "${WALLET_ROOT}/.cntools-wallet-new.link"
assert_no_creation_debris "internal staging catalog"

# A pre-existing wallet, regular file, or symbolic link is never reused or
# replaced. A second prompt cancellation ends the handled duplicate flow.
reset_case duplicate-directory offline preview
mkdir "${WALLET_ROOT}/Existing"
printf 'preserve-existing\n' > "${WALLET_ROOT}/Existing/marker"
UI_INPUT_VALUES=(Existing "")
UI_INPUT_STATUSES=(0 1)
run_action
assert_eq "${ACTION_STATUS}" "0" "duplicate wallet cancellation status"
assert_eq "$(< "${WALLET_ROOT}/Existing/marker")" "preserve-existing" \
  "duplicate wallet marker"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "duplicate wallet CLI call count"

reset_case duplicate-file offline preview
printf 'preserve-file\n' > "${WALLET_ROOT}/ExistingFile"
UI_INPUT_VALUES=(ExistingFile "")
UI_INPUT_STATUSES=(0 1)
run_action
assert_eq "${ACTION_STATUS}" "0" "duplicate file cancellation status"
assert_eq "$(< "${WALLET_ROOT}/ExistingFile")" "preserve-file" \
  "duplicate file contents"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "duplicate file CLI call count"

reset_case duplicate-symlink offline preview
mkdir "${CASE_ROOT}/external-wallet"
printf 'preserve-link-target\n' > "${CASE_ROOT}/external-wallet/marker"
ln -s -- "${CASE_ROOT}/external-wallet" "${WALLET_ROOT}/Linked"
UI_INPUT_VALUES=(Linked "")
UI_INPUT_STATUSES=(0 1)
run_action
assert_eq "${ACTION_STATUS}" "0" "symbolic-link wallet cancellation status"
[[ -L "${WALLET_ROOT}/Linked" ]] ||
  fail "symbolic-link wallet target was replaced"
assert_eq "$(< "${CASE_ROOT}/external-wallet/marker")" \
  "preserve-link-target" "symbolic-link target marker"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "symbolic-link wallet CLI call count"

# Cardano CLI is an action prerequisite, not a startup-wide requirement.
reset_case missing-cli offline preview
CNTOOLS_CLI=""
export CNTOOLS_CLI
set_single_input MissingCliWallet
run_action
(( ACTION_STATUS != 0 )) ||
  fail "wallet creation succeeded without Cardano CLI"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "missing CLI invocation count"
assert_file_contains "${UI_TRACE}" $'STATUS\terror\t' \
  "missing CLI status"
[[ ! -e "${WALLET_ROOT}/MissingCliWallet" ]] ||
  fail "missing CLI preflight created a wallet"
assert_no_creation_debris "missing CLI preflight"

# The configured wallet root must remain a physical, owned creation boundary.
reset_case unsafe-root offline preview
physical_wallet_root="${CASE_ROOT}/physical-wallets"
mv -- "${WALLET_ROOT}" "${physical_wallet_root}"
ln -s -- "${physical_wallet_root}" "${WALLET_ROOT}"
set_single_input UnsafeRootWallet
run_action
(( ACTION_STATUS != 0 )) ||
  fail "wallet creation accepted a symbolic-link wallet root"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "unsafe wallet root CLI call count"
[[ ! -e "${physical_wallet_root}/UnsafeRootWallet" ]] ||
  fail "unsafe wallet root received a wallet"
rm -f -- "${WALLET_ROOT}"
mv -- "${physical_wallet_root}" "${WALLET_ROOT}"
assert_no_creation_debris "unsafe wallet root preflight"

reset_case writable-root offline preview
chmod 0777 "${WALLET_ROOT}"
set_single_input WritableRootWallet
run_action
(( ACTION_STATUS != 0 )) ||
  fail "wallet creation accepted a group/public-writable root"
assert_eq "$(line_count "${CLI_TRACE}")" "0" \
  "writable wallet root CLI call count"
[[ ! -e "${WALLET_ROOT}/WritableRootWallet" ]] ||
  fail "writable wallet root received a wallet"
chmod 0700 "${WALLET_ROOT}"
assert_no_creation_debris "writable wallet root preflight"

assert_keygen_failure() {
  local scenario="$1"
  local wallet_name="$2"
  local expected_calls="$3"
  local diagnostic="$4"
  local visible_error="${5:-}"

  reset_case "failure-${scenario}" offline preview
  set_single_input "${wallet_name}"
  FAKE_CLI_SCENARIO="${scenario}"
  export FAKE_CLI_SCENARIO
  run_action
  (( ACTION_STATUS != 0 )) ||
    fail "${scenario} wallet creation unexpectedly succeeded"
  assert_eq "$(line_count "${CLI_TRACE}")" "${expected_calls}" \
    "${scenario} CLI call count"
  if grep -Eq '^(address build|latest stake-address build|address key-hash|latest stake-address key-hash)( |$)' \
      "${CLI_TRACE}"; then
    fail "${scenario} derived wallet artifacts after a key-pair failure"
  fi
  [[ ! -e "${WALLET_ROOT}/${wallet_name}" ]] ||
    fail "${scenario} retained a partial final wallet"
  assert_file_contains "${LOG_TRACE}" "${diagnostic}" \
    "${scenario} diagnostic log"
  assert_file_contains "${UI_TRACE}" $'STATUS\terror\t' \
    "${scenario} visible failure"
  if [[ -n "${visible_error}" ]]; then
    assert_file_contains "${UI_TRACE}" "${visible_error}" \
      "${scenario} specific visible failure"
  fi
  assert_no_creation_debris "${scenario} failure"
  assert_log_secrecy "${scenario} failure"
}

assert_keygen_failure \
  payment-fail PaymentFailure 1 'fixture payment key generation failed' \
  'Cardano CLI could not create the payment wallet keys.'
assert_keygen_failure \
  stake-fail StakeFailure 3 'fixture stake key generation failed' \
  'Cardano CLI could not create the stake wallet keys.'

assert_keygen_failure \
  payment-key-invalid InvalidPaymentKey 1 \
  'Cardano CLI returned invalid payment wallet keys'
assert_keygen_failure \
  payment-pair-command-fail PaymentPairCommandFailure 2 \
  'fixture payment pair derivation failed'
assert_keygen_failure \
  payment-derived-invalid InvalidDerivedPaymentKey 2 \
  'Cardano CLI returned an invalid derived payment verification key'
assert_keygen_failure \
  payment-pair-mismatch MismatchedPaymentPair 2 \
  'Generated payment signing and verification keys do not match'
assert_keygen_failure \
  stake-pair-mismatch MismatchedStakePair 4 \
  'Generated stake signing and verification keys do not match'

# Simulate another process claiming the validated name after key generation
# but before final publication. Its data must win and remain byte-for-byte.
reset_case publish-collision offline preview
set_single_input RacedWallet
FAKE_CLI_SCENARIO="publish-collision"
FAKE_COLLISION_TARGET="${WALLET_ROOT}/RacedWallet"
export FAKE_CLI_SCENARIO FAKE_COLLISION_TARGET
run_action
(( ACTION_STATUS != 0 )) ||
  fail "wallet creation overwrote a target that appeared before publication"
assert_eq "$(line_count "${CLI_TRACE}")" "9" \
  "publish collision CLI call count"
[[ -d "${FAKE_COLLISION_TARGET}" && ! -L "${FAKE_COLLISION_TARGET}" ]] ||
  fail "publish collision target is missing"
assert_eq "$(< "${FAKE_COLLISION_TARGET}/marker")" "preserve-collision" \
  "publish collision marker"
assert_eq "$({
  cd "${FAKE_COLLISION_TARGET}"
  find . -mindepth 1 -maxdepth 1 -type f -print | LC_ALL=C sort
})" "./marker" "publish collision file inventory"
assert_no_creation_debris "publish collision"
assert_log_secrecy "publish collision"

# The atomic rename is the commit point. A problem discovered afterward is a
# committed-wallet warning, never an ordinary action failure that could invite
# the user to repeat creation under the same name.
reset_case post-publish-validation offline preview
set_single_input CommittedWallet
FAKE_CLI_SCENARIO="post-publish-invalid"
export FAKE_CLI_SCENARIO
run_action
assert_eq "${ACTION_STATUS}" "0" "post-publication action status"
[[ -d "${WALLET_ROOT}/CommittedWallet" ]] ||
  fail "post-publication warning lost the committed wallet"
assert_eq "$(line_count "${CLI_TRACE}")" "9" \
  "post-publication warning CLI call count"
assert_file_contains "${LOG_TRACE}" \
  "post-publication validation could not be repeated" \
  "post-publication validation log"
assert_file_contains "${UI_TRACE}" $'STATUS\tsuccess\t' \
  "post-publication success status"
assert_file_contains "${UI_TRACE}" \
  "post-publication validation could not be repeated" \
  "post-publication visible warning"
assert_file_contains "${UI_TRACE}" \
  "result details could not be displayed" \
  "post-publication result fallback"
assert_no_creation_debris "post-publication warning"
assert_log_secrecy "post-publication warning"

# Interruption while the spinner owns the key-generation job must still run
# the action cleanup hook and preserve the signal-derived status.
reset_case interrupt-keygen offline preview
set_single_input InterruptedWallet
FAKE_CLI_SCENARIO="interrupt-payment"
export FAKE_CLI_SCENARIO
run_action
assert_eq "${ACTION_STATUS}" "143" "interrupted creation status"
[[ ! -e "${WALLET_ROOT}/InterruptedWallet" ]] ||
  fail "interrupted creation retained a partial final wallet"
assert_no_creation_debris "interrupted key generation"
assert_log_secrecy "interrupted key generation"

printf 'CNTools Wallet New CLI tests passed\n'
