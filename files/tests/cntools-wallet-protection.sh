#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-protection tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
WALLET_LIBRARY="${CNTOOLS_ROOT}/lib/wallet.sh"
MATERIAL_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-material.sh"
KEY_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-key.sh"
PROTECTION_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-protection.sh"
PROTECTION_UI_LIBRARY="${CNTOOLS_ROOT}/lib/wallet-protection-ui.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-protection.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
WALLET_ROOT="${TEST_ROOT}/wallets"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
FAKE_BIN="${TEST_ROOT}/bin"
LOG_TRACE="${TEST_ROOT}/wallet-protection.log"
PRIVATE_SENTINEL="private-payment-material-never-log"
STAKE_SENTINEL="private-stake-material-never-log"
LONG_PASSPHRASE="twelve-chars-plus"
SHORT_LEGACY_PASSPHRASE="oldpass"

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
    :
  else
    mode="$(stat -f '%Lp' "${path}")"
  fi
  printf '%s\n' "${mode}"
}

assert_no_transaction_files() {
  local wallet="$1"
  local debris=""

  debris="$(find "${wallet}" -mindepth 1 -maxdepth 1 \
    -name '.cntools-*' -print -quit)"
  [[ -z "${debris}" ]] || fail "wallet retained transaction file: ${debris}"
}

for required_file in \
  "${WALLET_LIBRARY}" "${MATERIAL_LIBRARY}" "${KEY_LIBRARY}" \
  "${PROTECTION_LIBRARY}" "${PROTECTION_UI_LIBRARY}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" ]] ||
    fail "required CNTools source is missing or unsafe: ${required_file}"
done

for required_command in bash cat chmod cp find jq ln mktemp rm stat tail wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required test command is unavailable: ${required_command}"
done

mkdir -p "${WALLET_ROOT}" "${CNTOOLS_TMP_DIR}" "${FAKE_BIN}"
chmod 0700 "${WALLET_ROOT}" "${CNTOOLS_TMP_DIR}" "${FAKE_BIN}"
: > "${LOG_TRACE}"

# A deterministic GPG double exercises CNTools' file transaction and secret
# transport contracts without touching a developer or CI account's keyring.
FAKE_GPG_SOURCE='#!/usr/bin/env bash
set -euo pipefail
mode=""
output=""
source_file=""
passphrase=""
while (( $# > 0 )); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --passphrase-fd|--pinentry-mode|--cipher-algo)
      shift 2
      ;;
    --symmetric)
      mode="encrypt"
      shift
      ;;
    --decrypt)
      mode="decrypt"
      shift
      ;;
    --*) shift ;;
    *) source_file="$1"; shift ;;
  esac
done
IFS= read -r passphrase <&3 || true
[[ -n "${mode}" && -n "${output}" && -f "${source_file}" ]] || exit 2
if [[ -n "${FAKE_GPG_FAIL_SOURCE:-}" &&
      "${source_file##*/}" == "${FAKE_GPG_FAIL_SOURCE}" ]]; then
  printf "injected GPG failure\n" >&2
  exit 9
fi
if [[ "${mode}" == "encrypt" ]]; then
  {
    printf "CNTOOLS-TEST-GPG\n"
    printf "%s\n" "${passphrase}"
    cat -- "${source_file}"
  } > "${output}"
  exit 0
fi
IFS= read -r marker < "${source_file}" || exit 3
IFS= read -r expected < <(tail -n +2 "${source_file}") || exit 3
if [[ "${marker}" != "CNTOOLS-TEST-GPG" ||
      "${passphrase}" != "${expected}" ]]; then
  printf "bad passphrase or corrupt data\n" >&2
  exit 4
fi
tail -n +3 "${source_file}" > "${output}"
'
printf '%s' "${FAKE_GPG_SOURCE}" > "${FAKE_BIN}/gpg"
chmod 0700 "${FAKE_BIN}/gpg"
unset FAKE_GPG_SOURCE
if [[ "${OSTYPE:-}" == darwin* ]]; then
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'arguments=()' \
    'for argument in "$@"; do' \
    '  [[ "${argument}" == "--" ]] || arguments+=("${argument}")' \
    'done' \
    'exec /bin/chmod "${arguments[@]}"' > "${FAKE_BIN}/chmod"
  chmod 0700 "${FAKE_BIN}/chmod"
fi
PATH="${FAKE_BIN}:${PATH}"
export PATH

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${WALLET_LIBRARY}"
# shellcheck source=/dev/null
. "${MATERIAL_LIBRARY}"
# shellcheck source=/dev/null
. "${KEY_LIBRARY}"
# shellcheck source=/dev/null
. "${PROTECTION_LIBRARY}"
# shellcheck source=/dev/null
. "${PROTECTION_UI_LIBRARY}"

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
CNTOOLS_ENABLE_CHATTR=false
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_LOG="${LOG_TRACE}"
CNTOOLS_ACTION_ID="wallet/encrypt"

cntools_log() {
  printf '%s\t%s\t%s\n' \
    "${1:-INFO}" "${CNTOOLS_ACTION_ID:-session}" "${2:-}" >> "${LOG_TRACE}"
}

write_key() {
  local wallet="$1"
  local role="$2"
  local filename=""
  local key_type=""
  local sentinel=""
  local cbor_byte=""
  local cbor="5820"
  local byte_index=0

  if [[ "${role}" == "payment" ]]; then
    filename="payment.skey"
    key_type="PaymentSigningKeyShelley_ed25519"
    sentinel="${PRIVATE_SENTINEL}"
    cbor_byte="11"
  else
    filename="stake.skey"
    key_type="StakeSigningKeyShelley_ed25519"
    sentinel="${STAKE_SENTINEL}"
    cbor_byte="22"
  fi
  for ((byte_index = 0; byte_index < 32; byte_index++)); do
    cbor+="${cbor_byte}"
  done
  jq -n --arg type "${key_type}" --arg description "${sentinel}" \
    --arg cbor "${cbor}" \
    '{type: $type, description: $description, cborHex: $cbor}' \
    > "${wallet}/${filename}"
  chmod 0600 "${wallet}/${filename}"
}

create_wallet() {
  local name="$1"
  local roles="${2:-payment,stake}"
  local wallet="${WALLET_ROOT}/${name}"

  mkdir "${wallet}"
  chmod 0700 "${wallet}"
  [[ ",${roles}," != *,payment,* ]] || write_key "${wallet}" payment
  [[ ",${roles}," != *,stake,* ]] || write_key "${wallet}" stake
  printf 'addr_test1fixture\n' > "${wallet}/payment.addr"
  chmod 0600 "${wallet}/payment.addr"
}

fake_legacy_encrypt() {
  local source_file="$1"
  local passphrase="$2"

  "${FAKE_BIN}/gpg" --batch --passphrase-fd 3 \
    --output "${source_file}.gpg" --symmetric "${source_file}" \
    3<<< "${passphrase}"
  rm -f -- "${source_file}"
  chmod 0400 "${source_file}.gpg"
}

cntools_wallet_protection_password_valid encrypt "123456789012" ||
  fail "12-character encryption passphrase was rejected"
if cntools_wallet_protection_password_valid encrypt "oldpass"; then
  fail "short new encryption passphrase was accepted"
fi
cntools_wallet_protection_password_valid decrypt "x" ||
  fail "short legacy decryption passphrase was rejected"

# Two valid keys are staged, round-trip checked, published, and only then are
# the clear originals removed. Address files remain writable.
create_wallet Standard
cntools_wallet_protection_encrypt \
  "${WALLET_ROOT}/Standard" "${LONG_PASSPHRASE}" ||
  fail "standard wallet encryption failed: ${CNTOOLS_WALLET_PROTECTION_ERROR}"
for role in payment stake; do
  [[ ! -e "${WALLET_ROOT}/Standard/${role}.skey" ]] ||
    fail "${role} clear key remained after encryption"
  [[ -f "${WALLET_ROOT}/Standard/${role}.skey.gpg" ]] ||
    fail "${role} encrypted key is missing"
  assert_eq "$(file_mode "${WALLET_ROOT}/Standard/${role}.skey.gpg")" \
    "400" "${role} encrypted-key mode"
done
assert_eq "$(file_mode "${WALLET_ROOT}/Standard/payment.addr")" \
  "600" "address mode after encryption"
assert_eq "$(cntools_wallet_protection "${WALLET_ROOT}/Standard")" \
  "Protected" "encrypted wallet protection state"
assert_no_transaction_files "${WALLET_ROOT}/Standard"

# A wrong passphrase must not unlock files, publish plaintext, or remove either
# encrypted key.
CNTOOLS_ACTION_ID="wallet/decrypt"
if cntools_wallet_protection_decrypt \
    "${WALLET_ROOT}/Standard" "wrong"; then
  fail "wrong wallet passphrase unexpectedly succeeded"
fi
for role in payment stake; do
  [[ ! -e "${WALLET_ROOT}/Standard/${role}.skey" ]] ||
    fail "wrong passphrase published the ${role} clear key"
  [[ -f "${WALLET_ROOT}/Standard/${role}.skey.gpg" ]] ||
    fail "wrong passphrase removed the ${role} encrypted key"
done
assert_no_transaction_files "${WALLET_ROOT}/Standard"

cntools_wallet_protection_decrypt \
  "${WALLET_ROOT}/Standard" "${LONG_PASSPHRASE}" ||
  fail "standard wallet decryption failed: ${CNTOOLS_WALLET_PROTECTION_ERROR}"
for role in payment stake; do
  [[ -f "${WALLET_ROOT}/Standard/${role}.skey" ]] ||
    fail "${role} clear key is missing after decryption"
  [[ ! -e "${WALLET_ROOT}/Standard/${role}.skey.gpg" ]] ||
    fail "${role} encrypted key remained after decryption"
  assert_eq "$(file_mode "${WALLET_ROOT}/Standard/${role}.skey")" \
    "600" "${role} decrypted-key mode"
done
assert_eq "$(cntools_wallet_protection "${WALLET_ROOT}/Standard")" \
  "Open" "decrypted wallet protection state"
assert_no_transaction_files "${WALLET_ROOT}/Standard"

# Legacy passphrases do not inherit the 12-character creation policy.
create_wallet Legacy payment
fake_legacy_encrypt "${WALLET_ROOT}/Legacy/payment.skey" \
  "${SHORT_LEGACY_PASSPHRASE}"
cntools_wallet_protection_decrypt \
  "${WALLET_ROOT}/Legacy" "${SHORT_LEGACY_PASSPHRASE}" ||
  fail "short legacy passphrase was not accepted"
[[ -f "${WALLET_ROOT}/Legacy/payment.skey" &&
   ! -e "${WALLET_ROOT}/Legacy/payment.skey.gpg" ]] ||
  fail "legacy wallet was not restored"
assert_no_transaction_files "${WALLET_ROOT}/Legacy"

# ENABLE_CHATTR is additive. Missing filesystem support or permission must
# retain successful encryption with the read-only baseline and a clear warning.
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "${FAKE_BIN}/chattr"
chmod 0700 "${FAKE_BIN}/chattr"
create_wallet ChattrFallback payment
CNTOOLS_ENABLE_CHATTR=true
CNTOOLS_ACTION_ID="wallet/encrypt"
cntools_wallet_protection_encrypt \
  "${WALLET_ROOT}/ChattrFallback" "${LONG_PASSPHRASE}" ||
  fail "chattr fallback aborted valid encryption"
assert_contains "${CNTOOLS_WALLET_PROTECTION_WARNING}" \
  "Immutable file locking was unavailable" "chattr fallback warning"
assert_eq "${CNTOOLS_WALLET_PROTECTION_LOCK_METHOD}" \
  "read-only permissions" "chattr fallback lock method"
assert_eq "$(file_mode "${WALLET_ROOT}/ChattrFallback/payment.skey.gpg")" \
  "400" "chattr fallback encrypted-key mode"
assert_no_transaction_files "${WALLET_ROOT}/ChattrFallback"
CNTOOLS_ENABLE_CHATTR=false
CNTOOLS_ACTION_ID="wallet/decrypt"
cntools_wallet_protection_decrypt \
  "${WALLET_ROOT}/ChattrFallback" "${LONG_PASSPHRASE}" ||
  fail "chattr fallback wallet could not be decrypted"
rm -f -- "${FAKE_BIN}/chattr"

# Failure while staging the second key leaves both original keys and publishes
# no encrypted counterpart.
create_wallet StageFailure
FAKE_GPG_FAIL_SOURCE="stake.skey"
export FAKE_GPG_FAIL_SOURCE
CNTOOLS_ACTION_ID="wallet/encrypt"
if cntools_wallet_protection_encrypt \
    "${WALLET_ROOT}/StageFailure" "${LONG_PASSPHRASE}"; then
  fail "injected GPG failure unexpectedly succeeded"
fi
unset FAKE_GPG_FAIL_SOURCE
for role in payment stake; do
  [[ -f "${WALLET_ROOT}/StageFailure/${role}.skey" ]] ||
    fail "staging failure removed the ${role} clear key"
  [[ ! -e "${WALLET_ROOT}/StageFailure/${role}.skey.gpg" ]] ||
    fail "staging failure published the ${role} encrypted key"
done
assert_no_transaction_files "${WALLET_ROOT}/StageFailure"

# Mixed and symbolic-link states fail closed without replacing either entry.
create_wallet Mixed payment
fake_legacy_encrypt "${WALLET_ROOT}/Mixed/payment.skey" \
  "${SHORT_LEGACY_PASSPHRASE}"
write_key "${WALLET_ROOT}/Mixed" payment
if cntools_wallet_protection_decrypt \
    "${WALLET_ROOT}/Mixed" "${SHORT_LEGACY_PASSPHRASE}"; then
  fail "mixed clear/encrypted wallet was accepted"
fi
[[ -f "${WALLET_ROOT}/Mixed/payment.skey" &&
   -f "${WALLET_ROOT}/Mixed/payment.skey.gpg" ]] ||
  fail "mixed wallet entries were changed"

create_wallet CrossRoleMixed
fake_legacy_encrypt "${WALLET_ROOT}/CrossRoleMixed/payment.skey" \
  "${SHORT_LEGACY_PASSPHRASE}"
if cntools_wallet_protection_decrypt \
    "${WALLET_ROOT}/CrossRoleMixed" "${SHORT_LEGACY_PASSPHRASE}"; then
  fail "cross-role clear/encrypted wallet was accepted"
fi
[[ -f "${WALLET_ROOT}/CrossRoleMixed/payment.skey.gpg" &&
   -f "${WALLET_ROOT}/CrossRoleMixed/stake.skey" ]] ||
  fail "cross-role mixed wallet entries were changed"

create_wallet Symlink stake
ln -s -- "${WALLET_ROOT}/Symlink/stake.skey" \
  "${WALLET_ROOT}/Symlink/payment.skey"
if cntools_wallet_protection_encrypt \
    "${WALLET_ROOT}/Symlink" "${LONG_PASSPHRASE}"; then
  fail "wallet containing a signing-key symlink was accepted"
fi
[[ -L "${WALLET_ROOT}/Symlink/payment.skey" &&
   -f "${WALLET_ROOT}/Symlink/stake.skey" ]] ||
  fail "unsafe symlink wallet was changed"

# Neither passphrase nor private key descriptions may enter the operational
# log, while the replayable GPG command and status remain visible.
if grep -F -- "${LONG_PASSPHRASE}" "${LOG_TRACE}" >/dev/null ||
   grep -F -- "${SHORT_LEGACY_PASSPHRASE}" "${LOG_TRACE}" >/dev/null ||
   grep -F -- "${PRIVATE_SENTINEL}" "${LOG_TRACE}" >/dev/null ||
   grep -F -- "${STAKE_SENTINEL}" "${LOG_TRACE}" >/dev/null; then
  fail "wallet protection logged secret material"
fi
assert_contains "$(< "${LOG_TRACE}")" "--passphrase-fd 3" \
  "GPG command log"
assert_contains "$(< "${LOG_TRACE}")" "cipher-algo AES256" \
  "GPG encryption algorithm log"

printf 'CNTools wallet-protection tests passed\n'
