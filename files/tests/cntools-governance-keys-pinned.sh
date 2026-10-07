#!/usr/bin/env bash
# No node/network/real wallet: exercise DRep creation with deployment-pinned CLI.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the deployment-pinned CLI binary}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-drep-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
cleanup() {
  if [[ "${GNUPGHOME:-}" == "${TEST_ROOT}/gnupg" ]]; then
    gpgconf --homedir "${GNUPGHOME}" --kill gpg-agent >/dev/null 2>&1 || true
  fi
  chmod -R u+rwX "${TEST_ROOT}"
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT
umask 077
# Match GNU chmod option placement on macOS, as in the wallet creation tests.
REAL_CHMOD="$(type -P chmod)"
REAL_LN="$(type -P ln)"
ln() {
  if [[ "${1:-}" == -T ]]; then
    shift
    [[ ! -d "${3}" ]] || return 1
  fi
  "${REAL_LN}" "$@"
}
chmod() {
  local arg=""
  local -a args=()
  for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done
  "${REAL_CHMOD}" "${args[@]}"
}
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"
mkdir "${CNTOOLS_WALLET_DIR}"
export GNUPGHOME="${TEST_ROOT}/gnupg"
mkdir "${GNUPGHOME}"
CNTOOLS_ENABLE_CHATTR=false
fail() { printf 'FAIL: %s (%s)\n' "$*" "${CNTOOLS_WALLET_PROTECTION_ERROR:-}" >&2; tail -8 "${TEST_ROOT}/test.log" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_log_sanitize_line() { printf '%s' "${1//[[:cntrl:]]/ }"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
cntools_run_command() { shift 2; "$@"; }
for lib in number wallet wallet-material wallet-key wallet-create wallet-mnemonic wallet-protection wallet-protection-ui drep-id drep-key; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
for role in PAY STAKE; do
  prefix=payment; [[ "${role}" != STAKE ]] || prefix=stake
  for pair in VKEY:vkey SKEY:skey SCRIPT:script ADDR:addr; do
    printf -v "CNTOOLS_WALLET_${role}_${pair%%:*}_FILENAME" '%s' "${prefix}.${pair#*:}"
  done
  printf -v "CNTOOLS_WALLET_HW_${role}_SKEY_FILENAME" '%s' "${prefix}.hwsfile"
done
CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "${version}" == "${pin}" ]] || fail 'CLI is not the cnode deployment pin'
phrase="$("${CNTOOLS_CLI}" key generate-mnemonic --size 24)"
for method in cli mnemonic; do
  directory="${CNTOOLS_WALLET_DIR}/${method}"
  mkdir "${directory}"
  "${CNTOOLS_CLI}" address key-gen --signing-key-file "${directory}/payment.skey" --verification-key-file "${directory}/payment.vkey"
  payment_before="$(cksum "${directory}/payment.skey")"
  cntools_drep_key_create "${directory}" "${method}" 7 "${phrase}" || fail "create ${method}"
  [[ "$(cksum "${directory}/payment.skey")" == "${payment_before}" ]] || fail 'payment key changed'
  cntools_drep_key_inspect "${directory}" || fail "inspect ${method}"
  id="${CNTOOLS_DREP_KEY_ID}"
  [[ "${id}" == "$("${CNTOOLS_CLI}" latest governance drep id --drep-verification-key-file "${directory}/drep.vkey" --output-cip129)" ]] || fail 'ID mismatch'
  if [[ "${method}" == mnemonic ]]; then
    [[ "${CNTOOLS_DREP_KEY_PATH}" == '1852H/1815H/7H/3/0' ]] || fail 'path missing'
    "${CNTOOLS_CLI}" key derive-from-mnemonic --drep-key --account-number 7 --mnemonic-from-interactive-prompt \
      --signing-key-file "${TEST_ROOT}/expected.skey" <<< "${phrase}" >/dev/null
    cmp "${directory}/drep.skey" "${TEST_ROOT}/expected.skey" || fail 'derivation mismatch'
  fi
  before="$(cksum "${directory}/drep.skey")"
  if cntools_drep_key_create "${directory}" cli; then fail 'overwrote existing DRep'; fi
  [[ "${before}" == "$(cksum "${directory}/drep.skey")" ]] || fail 'existing key modified'
  rm "${directory}/drep.vkey" "${directory}/drep.id"
  cntools_drep_key_inspect "${directory}" || fail 'missing-only repair'
  [[ "${CNTOOLS_DREP_KEY_ID}" == "${id}" ]] || fail 'repair changed ID'
  cntools_wallet_protection_keys_into keys roles encrypt "${directory}" || fail 'protection discovery'
  [[ "${roles[*]}" == 'payment drep' ]] || fail 'DRep key excluded from protection'
  CNTOOLS_WALLET_PATHS=("${directory}") CNTOOLS_WALLET_TYPES=(CLI) CNTOOLS_WALLET_PROTECTIONS=(Open)
  cntools_wallet_protection_candidate encrypt 0 || fail 'protection UI excludes DRep'
  for artifact in drep.skey drep.vkey drep.id; do
    cntools_wallet_create_mode_into mode "${directory}/${artifact}"
    [[ "${mode}" == 600 ]] || fail "unsafe mode ${mode}"
  done
  cntools_wallet_material_cleanup
  cntools_wallet_protection_encrypt "${directory}" 'test-passphrase-only' || fail 'DRep encryption'
  [[ ! -e "${directory}/drep.skey" && -f "${directory}/drep.skey.gpg" ]] || fail 'DRep plaintext remained'
  cntools_drep_key_inspect "${directory}" || fail 'encrypted wallet inspection'
  [[ "${CNTOOLS_DREP_KEY_ID}" == "${id}" ]] || fail 'encrypted identity changed'
  cntools_wallet_material_cleanup
  CNTOOLS_WALLET_PROTECTIONS=(Protected)
  cntools_wallet_protection_candidate decrypt 0 || fail 'encrypted DRep missing from selector'
  if cntools_wallet_protection_decrypt "${directory}" wrong; then fail 'wrong password accepted'; fi
  [[ ! -e "${directory}/drep.skey" ]] || fail 'failed decrypt published plaintext'
  cntools_wallet_protection_decrypt "${directory}" 'test-passphrase-only' || fail 'DRep decryption'
  [[ "${before}" == "$(cksum "${directory}/drep.skey")" ]] || fail 'DRep key changed after protection roundtrip'
done

# Reject invalid phrases without publishing or logging the phrase.
directory="${CNTOOLS_WALLET_DIR}/invalid"
mkdir "${directory}"; cp "${CNTOOLS_WALLET_DIR}/cli/payment.vkey" "${directory}/payment.vkey"
bad_phrase='secretword secretword secretword secretword secretword secretword secretword secretword secretword secretword secretword secretword'
if cntools_drep_key_create "${directory}" mnemonic 0 "${bad_phrase}"; then fail 'invalid phrase accepted'; fi
[[ ! -e "${directory}/drep.skey" && ! -e "${directory}/drep.id" ]] || fail 'failed generation published keys'
if grep -Fq secretword "${TEST_ROOT}/test.log" || grep -Fq "${phrase}" "${TEST_ROOT}/test.log"; then fail 'recovery phrase logged'; fi
if grep -Fq test-passphrase-only "${TEST_ROOT}/test.log"; then fail 'password logged'; fi

# Simulate a failed second publication: no partial key set or foreign writes.
(
  rm -f "${directory}/drep.skey"
  ln() { [[ "${*: -1}" != */drep.vkey ]] || return 1; shift; "${REAL_LN}" "$@"; }
  if cntools_drep_key_create "${directory}" cli; then fail 'partial publication accepted'; fi
  [[ ! -e "${directory}/drep.skey" && ! -e "${directory}/drep.id" ]] || fail 'publication rollback left keys'
)

# Cached identity remains usable without CLI/network, without claiming a pair check.
(
  CNTOOLS_CLI=''
  cntools_drep_key_inspect "${CNTOOLS_WALLET_DIR}/cli" || fail 'cached offline inspection'
  [[ "${CNTOOLS_DREP_KEY_VERIFIED}" == N ]] || fail 'offline pair verification claimed'
)

# A protected wallet, stale artifact, symlink or mismatched ID must not be replaced.
touch "${directory}/payment.skey.gpg"
if cntools_drep_key_create "${directory}" cli; then fail 'protected wallet accepted'; fi
rm "${directory}/payment.skey.gpg"
ln -s "${TEST_ROOT}/outside" "${directory}/drep.skey"
if cntools_drep_key_create "${directory}" cli; then fail 'symlink accepted'; fi
[[ -L "${directory}/drep.skey" ]] || fail 'symlink changed'
directory="${CNTOOLS_WALLET_DIR}/cli"
cp "${CNTOOLS_WALLET_DIR}/mnemonic/drep.id" "${directory}/drep.id"
if cntools_drep_key_inspect "${directory}"; then fail 'mismatched ID accepted'; fi
cntools_wallet_material_cleanup
cntools_wallet_create_cleanup
if compgen -G "${CNTOOLS_WALLET_DIR}/.cntools-*" >/dev/null; then fail 'staging left behind'; fi
printf 'CNTools DRep key tests passed (cardano-cli %s).\n' "${version}"
