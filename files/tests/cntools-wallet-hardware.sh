#!/usr/bin/env bash
# Focused Wallet -> Import -> HW Wallet acceptance tests.
# shellcheck disable=SC1090,SC2016,SC2034,SC2154,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools hardware wallet tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
HARDWARE_MODULE="${CNTOOLS_ROOT}/modules/root/wallet/import/hardware"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-hardware.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"
FAKE_CLI="${TEST_ROOT}/cardano-cli"
FAKE_HWCLI="${TEST_ROOT}/cardano-hw-cli"
CLI_TRACE="${TEST_ROOT}/cli.log"
HWCLI_TRACE="${TEST_ROOT}/hwcli.log"
LOG_TRACE="${TEST_ROOT}/cntools.log"

TESTED_HWCLI_VERSION="1.19.1"
TESTED_HWCLI_X64_URL="https://github.com/vacuumlabs/cardano-hw-cli/releases/download/v1.19.1/cardano-hw-cli-1.19.1_linux-x64.tar.gz"
TESTED_HWCLI_X64_SHA256="089349ebcfe2a465e301faaf077fa094f6db859e92aab56f256f325295b76474"
TESTED_HWCLI_ARM64_URL="https://github.com/vacuumlabs/cardano-hw-cli/releases/download/v1.19.1/cardano-hw-cli-1.19.1_linux-arm64.tar.gz"
TESTED_HWCLI_ARM64_SHA256="b980200f7c96c2c950ea6f0a79ed81280afd1c037ee3d71c4b8855a4ffad686b"
PAYMENT_PUBLIC="$(printf 'aa%.0s' {1..32})"
PAYMENT_CHAIN="$(printf 'cc%.0s' {1..32})"
STAKE_PUBLIC="$(printf 'bb%.0s' {1..32})"
STAKE_CHAIN="$(printf 'dd%.0s' {1..32})"
PAYMENT_CREDENTIAL="11111111111111111111111111111111111111111111111111111111"
STAKE_CREDENTIAL="22222222222222222222222222222222222222222222222222222222"
BASE_ADDRESS="addr_test1qpfepft9zs3y8ejcv84tq6tkp00wdm46fr6h3am02leunk8dc55q34v2ggxw9hea4rr3rry933a2zdh60v43h237s8ks7t2dja"
PAYMENT_ADDRESS="addr_test1vpfepft9zs3y8ejcv84tq6tkp00wdm46fr6h3am02leunkqtddwf6"
REWARD_ADDRESS="stake_test1urku22qg6k9yyr8zmu7633c33jzcc74pxma8k2cm4glgrmgrmu5lc"

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

assert_contains() {
  local actual="$1"
  local expected="$2"
  local context="${3:-text is missing}"
  [[ "${actual}" == *"${expected}"* ]] ||
    fail "${context}: '${expected}' was not found"
}

assert_no_debris() {
  local debris=""
  debris="$(find "${CNTOOLS_WALLET_DIR}" -name '.cntools-*' -print -quit)"
  [[ -z "${debris}" ]] || fail "hardware wallet staging debris remained: ${debris}"
}

reset_hardware_cache() {
  CNTOOLS_WALLET_HARDWARE_BIN=""
  CNTOOLS_WALLET_HARDWARE_VERSION=""
  CNTOOLS_WALLET_HARDWARE_DEVICE=""
  CNTOOLS_WALLET_HARDWARE_ERROR=""
  CNTOOLS_WALLET_CREATE_ERROR=""
}

for required_file in \
  "${CNTOOLS_ROOT}/lib/wallet-hardware.sh" \
  "${CNTOOLS_ROOT}/lib/wallet-hardware-ui.sh" \
  "${HARDWARE_MODULE}/module.json" \
  "${HARDWARE_MODULE}/action.sh"; do
  [[ -f "${required_file}" && ! -L "${required_file}" && -s "${required_file}" ]] ||
    fail "required hardware-wallet source is missing or unsafe: ${required_file}"
done

bash -n \
  "${CNTOOLS_ROOT}/lib/wallet-hardware.sh" \
  "${CNTOOLS_ROOT}/lib/wallet-hardware-ui.sh" \
  "${HARDWARE_MODULE}/action.sh" ||
  fail "hardware-wallet sources have invalid Bash syntax"

jq -e '.tools["cardano-hw-cli"] |
  . == {
    version: $version,
    artifacts: {
      "linux-x86_64": {url: $x64_url, sha256: $x64_sha256},
      "linux-aarch64": {url: $arm64_url, sha256: $arm64_sha256}
    }
  }' \
  --arg version "${TESTED_HWCLI_VERSION}" \
  --arg x64_url "${TESTED_HWCLI_X64_URL}" \
  --arg x64_sha256 "${TESTED_HWCLI_X64_SHA256}" \
  --arg arm64_url "${TESTED_HWCLI_ARM64_URL}" \
  --arg arm64_sha256 "${TESTED_HWCLI_ARM64_SHA256}" \
  "${REPO_ROOT}/files/node-implementations/common/release.json" >/dev/null ||
  fail "common hardware-wallet deployment contract changed; review command fixtures"

jq -e '.kind == "action" and .label == "HW Wallet" and
  .modes == ["local", "light", "offline"] and .libs == [
    "wallet.sh",
    "wallet-material.sh",
    "wallet-key.sh",
    "wallet-address.sh",
    "wallet-id.sh",
    "wallet-create.sh",
    "wallet-create-ui.sh",
    "wallet-hardware.sh",
    "wallet-hardware-ui.sh"
  ]' "${HARDWARE_MODULE}/module.json" >/dev/null ||
  fail "HW Wallet metadata does not declare the focused hardware stack"
grep -F 'cntools_wallet_action_import_hardware' \
  "${HARDWARE_MODULE}/action.sh" >/dev/null ||
  fail "HW Wallet action does not call its functional entrypoint"
grep -F 'cntools_wallet_create_cleanup' \
  "${HARDWARE_MODULE}/action.sh" >/dev/null ||
  fail "HW Wallet action does not clean private staging directories"

mkdir -p "${CNTOOLS_TMP_DIR}" "${CNTOOLS_WALLET_DIR}"
chmod 0700 "${TEST_ROOT}" "${CNTOOLS_TMP_DIR}" "${CNTOOLS_WALLET_DIR}"
: > "${CLI_TRACE}"
: > "${HWCLI_TRACE}"
: > "${LOG_TRACE}"
chmod 0600 "${CLI_TRACE}" "${HWCLI_TRACE}" "${LOG_TRACE}"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "${FAKE_HWCLI_TRACE}"' \
  'case "${1:-} ${2:-}" in' \
  '  "version ")' \
  '    [[ "${FAKE_HWCLI_SCENARIO:-success}" != "version-fail" ]] || exit 31' \
  '    case "${FAKE_HWCLI_SCENARIO:-success}" in' \
  '      old) printf "Cardano HW CLI Tool version 1.19.0\n" ;;' \
  '      newer) printf "Cardano HW CLI Tool version 1.20.0\n" ;;' \
  '      prerelease) printf "Cardano HW CLI Tool version 1.19.1-beta.1\n" ;;' \
  '      *) printf "Cardano HW CLI Tool version 1.19.1\n" ;;' \
  '    esac' \
  '    ;;' \
  '  "device version")' \
  '    [[ "${FAKE_HWCLI_SCENARIO:-success}" != "device-fail" ]] || { printf "device unavailable\n" >&2; exit 32; }' \
  '    printf "Ledger app version 7.2.0\n"' \
  '    ;;' \
  '  "address key-gen")' \
  '    [[ "${FAKE_HWCLI_SCENARIO:-success}" != "export-fail" ]] || { printf "export rejected\n" >&2; exit 33; }' \
  '    shift 2' \
  '    paths=(); vkeys=(); hwsfiles=()' \
  '    while (( $# > 0 )); do' \
  '      case "$1" in' \
  '        --path) paths+=("$2"); shift 2 ;;' \
  '        --verification-key-file) vkeys+=("$2"); shift 2 ;;' \
  '        --hw-signing-file) hwsfiles+=("$2"); shift 2 ;;' \
  '        *) exit 34 ;;' \
  '      esac' \
  '    done' \
  '    (( ${#paths[@]} == 2 && ${#vkeys[@]} == 2 && ${#hwsfiles[@]} == 2 )) || exit 35' \
  '    payment_public="${FAKE_PAYMENT_PUBLIC}"' \
  '    [[ "${FAKE_HWCLI_SCENARIO:-success}" != "mismatch" ]] || payment_public="$(printf "ee%.0s" {1..32})"' \
  '    printf "{\"type\":\"PaymentVerificationKeyShelley_ed25519\",\"description\":\"Payment Verification Key\",\"cborHex\":\"5820%s\"}\n" "${payment_public}" > "${vkeys[0]}"' \
  '    printf "{\"type\":\"StakeVerificationKeyShelley_ed25519\",\"description\":\"Stake Verification Key\",\"cborHex\":\"5820%s\"}\n" "${FAKE_STAKE_PUBLIC}" > "${vkeys[1]}"' \
  '    printf "{\"type\":\"PaymentHWSigningFileShelley_ed25519\",\"description\":\"Payment Hardware Signing File\",\"path\":\"%s\",\"cborXPubKeyHex\":\"5840%s%s\"}\n" "${paths[0]}" "${FAKE_PAYMENT_PUBLIC}" "${FAKE_PAYMENT_CHAIN}" > "${hwsfiles[0]}"' \
  '    printf "{\"type\":\"StakeHWSigningFileShelley_ed25519\",\"description\":\"Stake Hardware Signing File\",\"path\":\"%s\",\"cborXPubKeyHex\":\"5840%s%s\"}\n" "${paths[1]}" "${FAKE_STAKE_PUBLIC}" "${FAKE_STAKE_CHAIN}" > "${hwsfiles[1]}"' \
  '    ;;' \
  '  *) exit 36 ;;' \
  'esac' > "${FAKE_HWCLI}"
chmod 0700 "${FAKE_HWCLI}"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "${FAKE_CLI_TRACE}"' \
  'out=""; has_stake="N"' \
  'arguments=("$@")' \
  'command_pair="${arguments[0]:-} ${arguments[1]:-}"' \
  '[[ "${arguments[0]:-}" != "latest" ]] || command_pair="${arguments[0]:-} ${arguments[1]:-} ${arguments[2]:-}"' \
  'while (( $# > 0 )); do' \
  '  case "$1" in' \
  '    --out-file) out="$2"; shift 2 ;;' \
  '    --stake-verification-key-file) has_stake="Y"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  '[[ -n "${out}" ]] || exit 41' \
  'case "${command_pair}" in' \
  '  "address build")' \
  '    if [[ "${has_stake}" == "Y" ]]; then printf "%s\n" "${FAKE_BASE_ADDRESS}" > "${out}"; else printf "%s\n" "${FAKE_PAYMENT_ADDRESS}" > "${out}"; fi' \
  '    ;;' \
  '  "latest stake-address build") printf "%s\n" "${FAKE_REWARD_ADDRESS}" > "${out}" ;;' \
  '  "address key-hash") printf "%s\n" "${FAKE_PAYMENT_CREDENTIAL}" > "${out}" ;;' \
  '  "latest stake-address key-hash") printf "%s\n" "${FAKE_STAKE_CREDENTIAL}" > "${out}" ;;' \
  '  *) exit 42 ;;' \
  'esac' > "${FAKE_CLI}"
chmod 0700 "${FAKE_CLI}"

export FAKE_CLI_TRACE="${CLI_TRACE}"
export FAKE_HWCLI_TRACE="${HWCLI_TRACE}"
export FAKE_PAYMENT_PUBLIC="${PAYMENT_PUBLIC}"
export FAKE_PAYMENT_CHAIN="${PAYMENT_CHAIN}"
export FAKE_STAKE_PUBLIC="${STAKE_PUBLIC}"
export FAKE_STAKE_CHAIN="${STAKE_CHAIN}"
export FAKE_BASE_ADDRESS="${BASE_ADDRESS}"
export FAKE_PAYMENT_ADDRESS="${PAYMENT_ADDRESS}"
export FAKE_REWARD_ADDRESS="${REWARD_ADDRESS}"
export FAKE_PAYMENT_CREDENTIAL="${PAYMENT_CREDENTIAL}"
export FAKE_STAKE_CREDENTIAL="${STAKE_CREDENTIAL}"
export FAKE_HWCLI_SCENARIO="success"

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/startup.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-material.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-key.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-address.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-id.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-create.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-create-ui.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-hardware.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-hardware-ui.sh"

CNTOOLS_ACTION_ID="wallet/import/hardware"
CNTOOLS_CLI="${FAKE_CLI}"
CNTOOLS_HWCLI="${FAKE_HWCLI}"
CNTOOLS_CLI_TIMEOUT="3"
CNTOOLS_WALLET_HARDWARE_TIMEOUT="3"
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_NETWORK="preview"
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

# Match GNU chmod/mv semantics on the macOS development host without weakening
# the Linux production requirement for atomic no-clobber directory publication.
REAL_CHMOD="$(type -P chmod)"
chmod() {
  local argument=""
  local -a arguments=()
  for argument in "$@"; do
    [[ "${argument}" == "--" ]] || arguments+=("${argument}")
  done
  "${REAL_CHMOD}" "${arguments[@]}"
}
REAL_MV="$(type -P mv)"
mv() {
  if (( $# == 1 )) && [[ "$1" == "--help" ]]; then
    printf '%s\n' '  -n, --no-clobber' '  -T, --no-target-directory'
    return 0
  fi
  if (( $# == 5 )) && [[ "$1" == "-T" && "$2" == "-n" && "$3" == "--" ]]; then
    [[ ! -e "$5" && ! -L "$5" ]] || return 0
    "${REAL_MV}" -- "$4" "$5"
    return
  fi
  "${REAL_MV}" "$@"
}

path=""
cntools_wallet_hardware_path_into path 1852 0 0 0 ||
  fail "standard payment path construction failed"
assert_eq "${path}" "1852H/1815H/0H/0/0" "standard payment path"
cntools_wallet_hardware_path_into path 1854 7 2 9 ||
  fail "reusable CIP-1854 path construction failed"
assert_eq "${path}" "1854H/1815H/7H/2/9" "reusable CIP-1854 path"
if cntools_wallet_hardware_path_valid '1852H/1815H/0H/x/0'; then
  fail "generic hardware path accepted a non-numeric role"
fi
detail=""
cntools_wallet_hardware_output_detail_into \
  detail $'\033[31mLedger\tdevice' ||
  fail "hardware output detail could not be sanitized"
[[ "${detail}" != *$'\033'* && "${detail}" != *$'\t'* ]] ||
  fail "hardware output detail retained terminal control characters"

cntools_wallet_hardware_require ||
  fail "supported hardware CLI was rejected: ${CNTOOLS_WALLET_HARDWARE_ERROR}"
assert_eq "${CNTOOLS_WALLET_HARDWARE_VERSION}" "${TESTED_HWCLI_VERSION}" \
  "hardware CLI version parsing"
cntools_wallet_hardware_device_check ||
  fail "connected hardware device was rejected: ${CNTOOLS_WALLET_HARDWARE_ERROR}"
assert_contains "${CNTOOLS_WALLET_HARDWARE_DEVICE}" "Ledger app version" \
  "hardware device identity"

# Dingo and Amaru deployments use the same managed companion path as cnode.
# Prove CNTools can resolve it without relying on a refreshed login-shell PATH:
# Dingo may use its local adapter, while Amaru uses Koios for live queries.
for implementation_mode in dingo:local amaru:light; do
  implementation="${implementation_mode%%:*}"
  mode="${implementation_mode#*:}"
  managed_home="${TEST_ROOT}/${implementation}-home"
  mkdir -p "${managed_home}/.local/bin"
  cp -- "${FAKE_HWCLI}" "${managed_home}/.local/bin/cardano-hw-cli"
  chmod 0700 "${managed_home}/.local/bin/cardano-hw-cli"
  (
    HOME="${managed_home}"
    PATH="/usr/bin:/bin"
    CNTOOLS_IMPLEMENTATION="${implementation}"
    CNTOOLS_MODE="${mode}"
    if [[ "${implementation}" == "dingo" ]]; then
      CNTOOLS_BACKEND="dingo"
    else
      CNTOOLS_BACKEND="koios"
    fi
    CNTOOLS_HWCLI=""
    reset_hardware_cache
    cntools_wallet_hardware_require ||
      fail "${implementation} could not use managed cardano-hw-cli: ${CNTOOLS_WALLET_HARDWARE_ERROR}"
    assert_eq "${CNTOOLS_WALLET_HARDWARE_BIN}" \
      "${managed_home}/.local/bin/cardano-hw-cli" \
      "${implementation} managed hardware CLI path"
  )
done
unset implementation implementation_mode managed_home mode

cntools_wallet_hardware_create "LedgerOne" 7 9 ||
  fail "hardware wallet import failed: ${CNTOOLS_WALLET_HARDWARE_ERROR}"
wallet="${CNTOOLS_WALLET_DIR}/LedgerOne"
[[ -d "${wallet}" && ! -L "${wallet}" ]] ||
  fail "hardware wallet was not published"
assert_eq "$(cntools_wallet_type "${wallet}")" "Hardware" \
  "hardware wallet classification"
assert_eq "$(< "${wallet}/derivation.path")" \
  "1852H/1815H/7H/x/9" "hardware derivation marker"
[[ ! -e "${wallet}/payment.skey" && ! -e "${wallet}/stake.skey" ]] ||
  fail "hardware import stored ordinary private signing keys"
assert_eq "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" \
  "10" "hardware wallet artifact count"
cntools_wallet_hardware_required_entries_valid "${wallet}" ||
  fail "published hardware wallet failed its inventory validator"
assert_no_debris
assert_contains "$(< "${HWCLI_TRACE}")" \
  "--path 1852H/1815H/7H/0/9 --path 1852H/1815H/7H/2/9" \
  "bulk hardware derivation paths"
assert_contains "$(< "${LOG_TRACE}")" \
  "address key-gen --path 1852H/1815H/7H/0/9" \
  "replayable hardware command log"

if cntools_wallet_hardware_create "LedgerOne" 0 0; then
  fail "hardware import overwrote an existing wallet"
fi
assert_no_debris

for scenario in old newer prerelease; do
  FAKE_HWCLI_SCENARIO="${scenario}"
  export FAKE_HWCLI_SCENARIO
  reset_hardware_cache
  if cntools_wallet_hardware_require; then
    fail "unsupported ${scenario} hardware CLI version was accepted"
  fi
  assert_contains "${CNTOOLS_WALLET_HARDWARE_ERROR}" \
    "exactly ${TESTED_HWCLI_VERSION} is required" \
    "hardware CLI exact-version error (${scenario})"
done

FAKE_HWCLI_SCENARIO="device-fail"
export FAKE_HWCLI_SCENARIO
reset_hardware_cache
if cntools_wallet_hardware_device_check; then
  fail "unavailable hardware device was accepted"
fi
assert_contains "${CNTOOLS_WALLET_HARDWARE_ERROR}" "could not be reached" \
  "hardware device failure message"

for scenario in export-fail mismatch; do
  FAKE_HWCLI_SCENARIO="${scenario}"
  export FAKE_HWCLI_SCENARIO
  reset_hardware_cache
  if cntools_wallet_hardware_create "Failure-${scenario}" 0 0; then
    fail "injected ${scenario} unexpectedly published a wallet"
  fi
  [[ ! -e "${CNTOOLS_WALLET_DIR}/Failure-${scenario}" ]] ||
    fail "injected ${scenario} left a visible wallet"
  assert_no_debris
done

cntools_wallet_hardware_screen_begin() { :; }
cntools_ui_render_status() { :; }
cntools_ui_input() { printf -v "$1" '%s' ''; }
default_index=""
cntools_wallet_hardware_prompt_index_into \
  default_index "Account number" ||
  fail "blank hardware derivation input was rejected"
assert_eq "${default_index}" "0" "blank hardware derivation default"

UI_STATUS=""
cntools_ui_render_status() {
  UI_STATUS+="${1:-}\t${2:-}"$'\n'
}
cntools_ui_wait() { :; }
CNTOOLS_HWCLI="${TEST_ROOT}/missing-cardano-hw-cli"
reset_hardware_cache
if cntools_wallet_action_import_hardware; then
  fail "hardware action continued without cardano-hw-cli"
fi
assert_contains "${UI_STATUS}" \
  "cardano-hw-cli ${TESTED_HWCLI_VERSION} is required" \
  "on-demand hardware dependency error"

CNTOOLS_HWCLI="${FAKE_HWCLI}"
FAKE_HWCLI_SCENARIO="success"
export FAKE_HWCLI_SCENARIO
reset_hardware_cache
UI_INPUT_INDEX=0
UI_CONFIRM_COUNT=0
declare -a UI_INPUTS=("HardwareUI" "" "")
cntools_gum_clear() { :; }
cntools_ui_action_begin() { :; }
cntools_ui_render_status() { :; }
cntools_ui_render_detail() { :; }
cntools_ui_wait() { :; }
cntools_ui_content_width() { printf '140\n'; }
cntools_theme_style_value_into() { printf -v "$1" '%s' "$3"; }
cntools_ui_table() { while IFS= read -r _discarded; do :; done; }
cntools_ui_input() {
  printf -v "$1" '%s' "${UI_INPUTS[UI_INPUT_INDEX]}"
  UI_INPUT_INDEX=$((UI_INPUT_INDEX + 1))
}
cntools_ui_confirm() {
  UI_CONFIRM_COUNT=$((UI_CONFIRM_COUNT + 1))
  return 0
}
cntools_ui_spin_function() {
  shift
  "$@"
}
cntools_wallet_action_import_hardware ||
  fail "complete hardware UI flow failed: ${CNTOOLS_WALLET_HARDWARE_ERROR}"
assert_eq "${UI_CONFIRM_COUNT}" "2" "hardware UI confirmation count"
assert_eq "$(< "${CNTOOLS_WALLET_DIR}/HardwareUI/derivation.path")" \
  "1852H/1815H/0H/x/0" "hardware UI default derivation"
assert_no_debris

printf 'CNTools hardware wallet tests passed\n'
