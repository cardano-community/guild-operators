#!/usr/bin/env bash
# Focused Wallet -> New/Import -> Mnemonic acceptance tests.
# shellcheck disable=SC1090,SC2016,SC2034,SC2154,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools mnemonic wallet tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-mnemonic.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
WALLET_ROOT="${TEST_ROOT}/wallets"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
FAKE_CLI="${TEST_ROOT}/cardano-cli"
LOG_TRACE="${TEST_ROOT}/cntools.log"
CLI_TRACE="${TEST_ROOT}/cli.log"
TESTED_CARDANO_CLI_VERSION="11.0.0.0"

MNEMONIC_24="abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor actress actual"
MNEMONIC_12="abandon ability able about above absent absorb abstract absurd abuse access accident"
PAYMENT_SIGNING_CBOR="5880$(printf '11%.0s' {1..128})"
STAKE_SIGNING_CBOR="5880$(printf '22%.0s' {1..128})"
PAYMENT_EXTENDED_CBOR="5840$(printf 'aa%.0s' {1..64})"
STAKE_EXTENDED_CBOR="5840$(printf 'bb%.0s' {1..64})"
PAYMENT_NORMAL_CBOR="5820$(printf 'aa%.0s' {1..32})"
STAKE_NORMAL_CBOR="5820$(printf 'bb%.0s' {1..32})"
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

file_mode() {
  local path="$1"
  local mode=""
  if mode="$(stat -c '%a' -- "${path}" 2>/dev/null)"; then
    printf '%s\n' "${mode}"
  else
    stat -f '%Lp' "${path}"
  fi
}

assert_no_debris() {
  local debris=""
  debris="$(find "${WALLET_ROOT}" -name '.cntools-*' -print -quit)"
  [[ -z "${debris}" ]] || fail "wallet staging debris remained: ${debris}"
  debris="$(find "${CNTOOLS_TMP_DIR}" -name '.cntools-*' -print -quit)"
  [[ -z "${debris}" ]] || fail "temporary mnemonic debris remained: ${debris}"
}

for implementation in cnode dingo; do
  pinned_version="$(jq -er '.companions["cardano-cli"].version' \
    "${REPO_ROOT}/files/node-implementations/${implementation}/release.json")"
  assert_eq "${pinned_version}" "${TESTED_CARDANO_CLI_VERSION}" \
    "${implementation} cardano-cli compatibility pin"
done

mkdir -p "${WALLET_ROOT}" "${CNTOOLS_TMP_DIR}"
chmod 0700 "${TEST_ROOT}" "${WALLET_ROOT}" "${CNTOOLS_TMP_DIR}"
: > "${LOG_TRACE}"
: > "${CLI_TRACE}"
chmod 0600 "${LOG_TRACE}" "${CLI_TRACE}"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "${FAKE_CLI_TRACE}"' \
  'arguments=("$@")' \
  'command_pair="${arguments[0]:-} ${arguments[1]:-}"' \
  '[[ "${arguments[0]:-}" != "latest" ]] || command_pair="${arguments[0]:-} ${arguments[1]:-} ${arguments[2]:-}"' \
  'signing_file=""' \
  'verification_file=""' \
  'extended_file=""' \
  'output_file=""' \
  'account=""' \
  'key_index=""' \
  'selector=""' \
  'while (( $# > 0 )); do' \
  '  case "$1" in' \
  '    --signing-key-file) signing_file="$2"; shift 2 ;;' \
  '    --verification-key-file) verification_file="$2"; shift 2 ;;' \
  '    --extended-verification-key-file) extended_file="$2"; shift 2 ;;' \
  '    --out-file) output_file="$2"; shift 2 ;;' \
  '    --account-number) account="$2"; shift 2 ;;' \
  '    --payment-key-with-number|--stake-key-with-number) selector="$1"; key_index="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'case "${command_pair}" in' \
  '  "latest key generate-mnemonic")' \
  '    printf "%s\n" "${FAKE_MNEMONIC_24}"' \
  '    ;;' \
  '  "latest key derive-from-mnemonic")' \
  '    IFS= read -r phrase || true' \
  '    [[ "${FAKE_CLI_SCENARIO}" != "derive-fail" ]] || { printf "fixture derivation failure\n" >&2; exit 41; }' \
  '    case " $(wc -w <<< "${phrase}" | tr -d "[:space:]") " in " 12 "|" 15 "|" 18 "|" 21 "|" 24 ") ;; *) printf "invalid mnemonic\n" >&2; exit 42 ;; esac' \
  '    [[ "${account}" =~ ^[0-9]+$ && "${key_index}" =~ ^[0-9]+$ ]] || exit 43' \
  '    case "${selector}" in' \
  '      --payment-key-with-number) printf "{\"type\":\"PaymentExtendedSigningKeyShelley_ed25519_bip32\",\"description\":\"Payment Extended Signing Key\",\"cborHex\":\"%s\"}\n" "${FAKE_PAYMENT_SIGNING_CBOR}" > "${signing_file}" ;;' \
  '      --stake-key-with-number) printf "{\"type\":\"StakeExtendedSigningKeyShelley_ed25519_bip32\",\"description\":\"Stake Extended Signing Key\",\"cborHex\":\"%s\"}\n" "${FAKE_STAKE_SIGNING_CBOR}" > "${signing_file}" ;;' \
  '      *) exit 44 ;;' \
  '    esac' \
  '    ;;' \
  '  "key verification-key")' \
  '    key_type="$(jq -er .type "${signing_file}")"' \
  '    case "${key_type}" in' \
  '      PaymentExtendedSigningKeyShelley_ed25519_bip32) printf "{\"type\":\"PaymentExtendedVerificationKeyShelley_ed25519_bip32\",\"description\":\"Payment Extended Verification Key\",\"cborHex\":\"%s\"}\n" "${FAKE_PAYMENT_EXTENDED_CBOR}" > "${verification_file}" ;;' \
  '      StakeExtendedSigningKeyShelley_ed25519_bip32) printf "{\"type\":\"StakeExtendedVerificationKeyShelley_ed25519_bip32\",\"description\":\"Stake Extended Verification Key\",\"cborHex\":\"%s\"}\n" "${FAKE_STAKE_EXTENDED_CBOR}" > "${verification_file}" ;;' \
  '      *) exit 45 ;;' \
  '    esac' \
  '    ;;' \
  '  "key non-extended-key")' \
  '    key_type="$(jq -er .type "${extended_file}")"' \
  '    case "${key_type}" in' \
  '      PaymentExtendedVerificationKeyShelley_ed25519_bip32) printf "{\"type\":\"PaymentVerificationKeyShelley_ed25519\",\"description\":\"Payment Verification Key\",\"cborHex\":\"%s\"}\n" "${FAKE_PAYMENT_NORMAL_CBOR}" > "${verification_file}" ;;' \
  '      StakeExtendedVerificationKeyShelley_ed25519_bip32) printf "{\"type\":\"StakeVerificationKeyShelley_ed25519\",\"description\":\"Stake Verification Key\",\"cborHex\":\"%s\"}\n" "${FAKE_STAKE_NORMAL_CBOR}" > "${verification_file}" ;;' \
  '      *) exit 46 ;;' \
  '    esac' \
  '    ;;' \
  '  "address build")' \
  '    if [[ " ${arguments[*]} " == *" --stake-verification-key-file "* ]]; then printf "%s\n" "${FAKE_BASE_ADDRESS}" > "${output_file}"; else printf "%s\n" "${FAKE_PAYMENT_ADDRESS}" > "${output_file}"; fi' \
  '    ;;' \
  '  "latest stake-address build") printf "%s\n" "${FAKE_REWARD_ADDRESS}" > "${output_file}" ;;' \
  '  "address key-hash") printf "%s\n" "${FAKE_PAYMENT_CREDENTIAL}" > "${output_file}" ;;' \
  '  "latest stake-address key-hash") printf "%s\n" "${FAKE_STAKE_CREDENTIAL}" > "${output_file}" ;;' \
  '  *) printf "unexpected fake cardano-cli command: %s\n" "${arguments[*]}" >&2; exit 91 ;;' \
  'esac' > "${FAKE_CLI}"
chmod 0700 "${FAKE_CLI}"

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/theme.sh"
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
. "${CNTOOLS_ROOT}/lib/wallet-mnemonic.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-mnemonic-ui.sh"

CNTOOLS_WALLET_DIR="${WALLET_ROOT}"
CNTOOLS_CLI="${FAKE_CLI}"
CNTOOLS_CLI_TIMEOUT=3
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_NETWORK="preview"
CNTOOLS_MODE="offline"
CNTOOLS_LOG="${LOG_TRACE}"
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
FAKE_CLI_TRACE="${CLI_TRACE}"
FAKE_CLI_SCENARIO="success"
FAKE_MNEMONIC_24="${MNEMONIC_24}"
FAKE_PAYMENT_SIGNING_CBOR="${PAYMENT_SIGNING_CBOR}"
FAKE_STAKE_SIGNING_CBOR="${STAKE_SIGNING_CBOR}"
FAKE_PAYMENT_EXTENDED_CBOR="${PAYMENT_EXTENDED_CBOR}"
FAKE_STAKE_EXTENDED_CBOR="${STAKE_EXTENDED_CBOR}"
FAKE_PAYMENT_NORMAL_CBOR="${PAYMENT_NORMAL_CBOR}"
FAKE_STAKE_NORMAL_CBOR="${STAKE_NORMAL_CBOR}"
FAKE_PAYMENT_CREDENTIAL="${PAYMENT_CREDENTIAL}"
FAKE_STAKE_CREDENTIAL="${STAKE_CREDENTIAL}"
FAKE_BASE_ADDRESS="${BASE_ADDRESS}"
FAKE_PAYMENT_ADDRESS="${PAYMENT_ADDRESS}"
FAKE_REWARD_ADDRESS="${REWARD_ADDRESS}"
export CNTOOLS_WALLET_DIR CNTOOLS_CLI CNTOOLS_TMP_DIR CNTOOLS_NETWORK CNTOOLS_MODE
export FAKE_CLI_TRACE FAKE_CLI_SCENARIO FAKE_MNEMONIC_24
export FAKE_PAYMENT_SIGNING_CBOR FAKE_STAKE_SIGNING_CBOR
export FAKE_PAYMENT_EXTENDED_CBOR FAKE_STAKE_EXTENDED_CBOR
export FAKE_PAYMENT_NORMAL_CBOR FAKE_STAKE_NORMAL_CBOR
export FAKE_PAYMENT_CREDENTIAL FAKE_STAKE_CREDENTIAL
export FAKE_BASE_ADDRESS FAKE_PAYMENT_ADDRESS FAKE_REWARD_ADDRESS

cntools_log() {
  printf '%s\t%s\t%s\n' \
    "${1:-INFO}" "${CNTOOLS_ACTION_ID:-session}" "${2:-}" >> "${LOG_TRACE}"
}

# Match GNU mv/chmod semantics on the macOS development host without changing
# the Linux production contracts.
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

declare -a parsed_words=()
normalized_phrase=""
cntools_wallet_mnemonic_words_into parsed_words \
  $'  ABANDON\tability able about above absent absorb abstract absurd abuse access accident  ' 12 ||
  fail "trimmed/case-normalized mnemonic was rejected"
cntools_wallet_mnemonic_phrase_into normalized_phrase parsed_words ||
  fail "normalized mnemonic could not be joined"
assert_eq "${normalized_phrase}" "${MNEMONIC_12}" \
  "normalized imported mnemonic"
if cntools_wallet_mnemonic_words_into parsed_words \
    "abandon ability able about above absent absorb abstract absurd abuse access"; then
  fail "11-word mnemonic was accepted"
fi
cntools_wallet_mnemonic_index_into normalized_index " 0007 " ||
  fail "custom mnemonic account index was rejected"
assert_eq "${normalized_index}" "7" "normalized derivation index"
if cntools_wallet_mnemonic_index_into normalized_index "2147483648"; then
  fail "out-of-range derivation index was accepted"
fi
assert_eq "$(cntools_wallet_mnemonic_word_columns 120)" "6" \
  "wide mnemonic table columns"
assert_eq "$(cntools_wallet_mnemonic_word_columns 80)" "4" \
  "medium mnemonic table columns"
assert_eq "$(cntools_wallet_mnemonic_word_columns 60)" "3" \
  "narrow mnemonic table columns"
assert_eq "$(cntools_wallet_mnemonic_word_columns 40)" "2" \
  "small mnemonic table columns"
declare -a challenge_indices=()
cntools_wallet_mnemonic_challenge_indices_into challenge_indices 24 4 ||
  fail "mnemonic challenge positions could not be selected"
assert_eq "${#challenge_indices[@]}" "4" "mnemonic challenge count"
for ((index = 0; index < 4; index++)); do
  (( challenge_indices[index] >= 0 && challenge_indices[index] < 24 )) ||
    fail "mnemonic challenge index is out of range"
  (( index == 0 || challenge_indices[index - 1] < challenge_indices[index] )) ||
    fail "mnemonic challenge indexes are not unique and ordered"
done

generated_phrase=""
CNTOOLS_ACTION_ID="wallet/new/mnemonic"
cntools_wallet_mnemonic_generate_into generated_phrase ||
  fail "24-word phrase generation failed: ${CNTOOLS_WALLET_MNEMONIC_ERROR}"
assert_eq "${generated_phrase}" "${MNEMONIC_24}" "generated mnemonic phrase"

cntools_wallet_mnemonic_create \
  "Generated" 0 0 "${generated_phrase}" new ||
  fail "generated mnemonic wallet failed: ${CNTOOLS_WALLET_MNEMONIC_ERROR}"
generated_wallet="${WALLET_ROOT}/Generated"
[[ -d "${generated_wallet}" && ! -L "${generated_wallet}" ]] ||
  fail "generated mnemonic wallet directory is missing"
assert_eq "$(file_mode "${generated_wallet}")" "700" \
  "generated mnemonic wallet directory mode"
assert_eq "$(< "${generated_wallet}/derivation.path")" \
  "1852H/1815H/0H/x/0" "generated mnemonic derivation marker"
assert_eq "$(cntools_wallet_type "${generated_wallet}")" "Mnemonic" \
  "generated mnemonic wallet type"
assert_eq "$(find "${generated_wallet}" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" \
  "10" "generated mnemonic wallet file count"
for file in "${generated_wallet}"/*; do
  assert_eq "$(file_mode "${file}")" "600" \
    "generated mnemonic artifact mode: ${file##*/}"
done
cntools_wallet_key_extended_envelope_valid \
  "${generated_wallet}/payment.skey" payment signing ||
  fail "generated payment extended signing key is invalid"
cntools_wallet_key_extended_envelope_valid \
  "${generated_wallet}/stake.skey" stake signing ||
  fail "generated stake extended signing key is invalid"
assert_contains "$(< "${CLI_TRACE}")" \
  "latest key derive-from-mnemonic --key-output-text-envelope --payment-key-with-number 0 --account-number 0 --mnemonic-from-interactive-prompt" \
  "payment derivation command"
assert_contains "$(< "${CLI_TRACE}")" \
  "latest key derive-from-mnemonic --key-output-text-envelope --stake-key-with-number 0 --account-number 0 --mnemonic-from-interactive-prompt" \
  "stake derivation command"
if grep -F -- "${MNEMONIC_24}" "${LOG_TRACE}" >/dev/null ||
   grep -F -- "${MNEMONIC_12}" "${LOG_TRACE}" >/dev/null ||
   grep -F -- "${PAYMENT_SIGNING_CBOR}" "${LOG_TRACE}" >/dev/null; then
  fail "mnemonic or private derived key material entered the CNTools log"
fi

CNTOOLS_ACTION_ID="wallet/import/mnemonic"
cntools_wallet_mnemonic_create \
  "Imported" 7 9 "   ${MNEMONIC_12}   " import ||
  fail "12-word mnemonic import failed: ${CNTOOLS_WALLET_MNEMONIC_ERROR}"
assert_eq "$(cntools_wallet_type "${WALLET_ROOT}/Imported")" "Mnemonic" \
  "imported mnemonic wallet type"
assert_eq "$(< "${WALLET_ROOT}/Imported/derivation.path")" \
  "1852H/1815H/7H/x/9" "imported mnemonic derivation marker"

FAKE_CLI_SCENARIO="derive-fail"
export FAKE_CLI_SCENARIO
if cntools_wallet_mnemonic_create \
    "Failed" 0 0 "${MNEMONIC_24}" import; then
  fail "injected mnemonic derivation failure unexpectedly succeeded"
fi
[[ ! -e "${WALLET_ROOT}/Failed" && ! -L "${WALLET_ROOT}/Failed" ]] ||
  fail "failed mnemonic derivation published a wallet"
FAKE_CLI_SCENARIO="success"
export FAKE_CLI_SCENARIO
assert_no_debris

cntools_wallet_materialize_wallet() { return 1; }
if cntools_wallet_mnemonic_create \
    "ArtifactFailure" 0 0 "${MNEMONIC_24}" new; then
  fail "injected mnemonic artifact failure unexpectedly succeeded"
fi
assert_contains "${CNTOOLS_WALLET_MNEMONIC_ERROR}" \
  "public keys, addresses, or credentials" \
  "focused mnemonic artifact failure"
[[ ! -e "${WALLET_ROOT}/ArtifactFailure" ]] ||
  fail "failed mnemonic artifact derivation published a wallet"
assert_no_debris

jq -e '.libs == [
  "wallet.sh",
  "wallet-material.sh",
  "wallet-key.sh",
  "wallet-address.sh",
  "wallet-id.sh",
  "wallet-create.sh",
  "wallet-create-ui.sh",
  "wallet-mnemonic.sh",
  "wallet-mnemonic-ui.sh"
]' "${CNTOOLS_ROOT}/modules/root/wallet/new/mnemonic/module.json" >/dev/null ||
  fail "Wallet New Mnemonic metadata is not wired to the focused stack"
jq -e '.libs == [
  "wallet.sh",
  "wallet-material.sh",
  "wallet-key.sh",
  "wallet-address.sh",
  "wallet-id.sh",
  "wallet-create.sh",
  "wallet-create-ui.sh",
  "wallet-mnemonic.sh",
  "wallet-mnemonic-ui.sh"
]' "${CNTOOLS_ROOT}/modules/root/wallet/import/mnemonic/module.json" >/dev/null ||
  fail "Wallet Import Mnemonic metadata is not wired to the focused stack"

render_plan_fallback_fixture() (
  cntools_ui_content_width() { printf '160\n'; }
  cntools_ui_render_detail() { return 0; }
  cntools_ui_table() {
    while IFS= read -r _cntools_discarded; do :; done
    return 19
  }
  cntools_ui_render_status() { printf 'NOTICE\t%s\n' "${2:-}"; }
  cntools_wallet_mnemonic_render_plan "Fallback" 0 0 new
)
fallback_output="$(render_plan_fallback_fixture)" ||
  fail "failed Gum mnemonic plan did not use its compact fallback"
assert_contains "${fallback_output}" \
  "The table view is unavailable; showing the compact wallet plan." \
  "mnemonic plan fallback notice"
assert_contains "${fallback_output}" "Payment path       1852H/1815H/0H/0/0" \
  "mnemonic plan fallback payment path"
assert_contains "$(< "${LOG_TRACE}")" \
  "Gum mnemonic plan table failed status=19" \
  "mnemonic plan Gum failure diagnostics"

DEFAULT_PLACEHOLDER=""
cntools_wallet_mnemonic_screen_begin() { return 0; }
cntools_ui_render_status() { return 0; }
cntools_ui_input() {
  DEFAULT_PLACEHOLDER="${3:-}"
  printf -v "$1" '%s' ""
}
default_index=""
cntools_wallet_mnemonic_prompt_index_into \
  default_index "Account number" "Mnemonic" "/ Wallet / New / Mnemonic" ||
  fail "blank mnemonic derivation index did not select its default"
assert_eq "${default_index}" "0" "blank mnemonic derivation default"
assert_eq "${DEFAULT_PLACEHOLDER}" "0" "mnemonic derivation placeholder"

unset generated_phrase normalized_phrase MNEMONIC_24 MNEMONIC_12
printf 'CNTools mnemonic wallet tests passed\n'
