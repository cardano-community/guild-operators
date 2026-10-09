#!/usr/bin/env bash
# Real GPG and deployment-pinned key identities. No node/network/user keys.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329,SC2015
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the cnode deployment CLI pin}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-calidus-protection.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
# macOS Unix sockets have a small path limit; keep the disposable GPG home
# short and separate from its much longer system temporary directory.
GPG_TEST_ROOT="$(mktemp -d /tmp/cntools-gpg.XXXXXX)"
export GNUPGHOME="${GPG_TEST_ROOT}"
trap 'gpgconf --homedir "${GNUPGHOME}" --kill gpg-agent >/dev/null 2>&1 || true; chmod -R u+rwX "${TEST_ROOT}" 2>/dev/null || true; rm -rf -- "${TEST_ROOT}" "${GPG_TEST_ROOT}"' EXIT
umask 077
for lib in number wallet wallet-key wallet-query transaction pool-id pool pool-files pool-key drep-id calidus-id pool-calidus key-crypto pool-lock pool-protection pool-manage-ui; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; tail -8 "${TEST_ROOT}/log" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
TEST_FAULT=''
cntools_run_command() {
  local mask="$1"; shift 2
  (( ${#mask} == $# )) || fail 'command audit mask'
  if [[ "$1" == rm && "${TEST_FAULT}" == retire-second* && "${*: -1}" == *calidus.skey* ]]; then return 17; fi
  "$@"
}
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
REAL_LN="$(type -P ln)"
base_ln() {
  if [[ "${OSTYPE:-}" == darwin* && "$1" == -T ]]; then
    shift; [[ "$1" != -- ]] || shift; [[ ! -e "$2" && ! -L "$2" ]] || return 1
  fi
  "${REAL_LN}" "$@"
}
ln() {
  if [[ "${TEST_FAULT}" == publish-second && "${*: -1}" == *calidus.skey* ]]; then return 18; fi
  if [[ "${TEST_FAULT}" == retire-second-no-restore && "${*: -1}" == "${pool}/cold.skey" ]]; then return 19; fi
  base_ln "$@"
}
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
CNTOOLS_POOL_DIR="${TEST_ROOT}/pools" CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_ENABLE_CHATTR=false CNTOOLS_MODE=offline CNTOOLS_NETWORK=preview
mkdir -m700 "${CNTOOLS_POOL_DIR}" "${CNTOOLS_POOL_DIR}/Pool"
pool="${CNTOOLS_POOL_DIR}/Pool"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong CLI pin'
"${CNTOOLS_CLI}" latest node key-gen --cold-signing-key-file "${pool}/cold.skey" --cold-verification-key-file "${pool}/cold.vkey" --operational-certificate-issue-counter-file "${pool}/cold.counter"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${pool}/calidus.skey" --verification-key-file "${pool}/calidus.vkey"
cntools_calidus_id_into id "${pool}/calidus.vkey"
printf '%s\n' "${id}" > "${pool}/calidus.id"
printf 'runtime KES fixture\n' > "${pool}/hot.skey"
printf 'runtime VRF fixture\n' > "${pool}/vrf.skey"
chmod 600 "${pool}"/*
cp "${pool}/cold.skey" "${TEST_ROOT}/cold.original"; cp "${pool}/calidus.skey" "${TEST_ROOT}/calidus.original"
cp "${pool}/calidus.vkey" "${TEST_ROOT}/calidus-public.original"
runtime="$(cksum "${pool}/hot.skey" "${pool}/vrf.skey" "${pool}/cold.counter" "${pool}/cold.vkey")"
password='calidus-test-password-DO-NOT-LOG'
gpg_binary="$(type -P gpg || type -P gpg2)"
assert_clear() {
  cmp -s "${pool}/cold.skey" "${TEST_ROOT}/cold.original" && cmp -s "${pool}/calidus.skey" "${TEST_ROOT}/calidus.original" || fail 'clear key bytes changed/lost'
  [[ ! -e "${pool}/cold.skey.gpg" && ! -e "${pool}/calidus.skey.gpg" ]] || fail 'mixed keys after rollback'
}
! cntools_pool_protect "${pool}" encrypt short || fail 'short encryption password'
cntools_pool_protection_cleanup; assert_clear
cntools_pool_protect "${pool}" encrypt "${password}" || fail "two-key encryption: ${CNTOOLS_POOL_WRITE_ERROR}"
[[ "${CNTOOLS_POOL_PROTECTION_KEYS}" == 2 && ! -e "${pool}/cold.skey" && ! -e "${pool}/calidus.skey" ]] || fail 'plaintext remains after encryption'
for key in cold calidus; do
  cntools_transaction_mode_into mode "${pool}/${key}.skey.gpg"
  [[ "${mode}" == 400 ]] || fail 'ciphertext not locked read-only'
done
encrypted="$(cksum "${pool}/cold.skey.gpg" "${pool}/calidus.skey.gpg")"
! cntools_pool_protect "${pool}" decrypt wrong || fail 'wrong password accepted'
cntools_pool_protection_cleanup
[[ "$(cksum "${pool}/cold.skey.gpg" "${pool}/calidus.skey.gpg")" == "${encrypted}" ]] || fail 'wrong password altered ciphertext'
cntools_pool_protect "${pool}" decrypt "${password}" || fail 'two-key decryption'
assert_clear
[[ "${CNTOOLS_POOL_PROTECTION_KEYS}" == 2 && "$(cksum "${pool}/hot.skey" "${pool}/vrf.skey" "${pool}/cold.counter" "${pool}/cold.vkey")" == "${runtime}" ]] || fail 'runtime/public node artifacts changed'
# Fail after the first counterpart is published and after the first original
# is retired, for both directions. Neither half can become a lost key.
for operation in encrypt decrypt; do
  if [[ "${operation}" == decrypt ]]; then
    cntools_pool_protect "${pool}" encrypt "${password}"
    encrypted="$(cksum "${pool}/cold.skey.gpg" "${pool}/calidus.skey.gpg")"
  fi
  for TEST_FAULT in publish-second retire-second; do
    ! cntools_pool_protect "${pool}" "${operation}" "${password}" || fail "${operation} ${TEST_FAULT} accepted"
    TEST_FAULT=''; cntools_pool_protection_cleanup
    if [[ "${operation}" == encrypt ]]; then assert_clear
    else
      [[ "$(cksum "${pool}/cold.skey.gpg" "${pool}/calidus.skey.gpg")" == "${encrypted}" && ! -e "${pool}/cold.skey" && ! -e "${pool}/calidus.skey" ]] || fail 'decrypt rollback did not restore ciphertext'
    fi
    [[ -z "$(find "${pool}" -name '.cntools-*' -print -quit)" ]] || fail 'private staging remains after rollback'
  done
  [[ "${operation}" != decrypt ]] || cntools_pool_protect "${pool}" decrypt "${password}"
done
# Rollback restores immutable flags only after snapshot aliases are removed,
# otherwise a restored original and its temporary hard link both become +i.
(
  TEST_FAULT=retire-second
  restored=0
  cntools_pool_locks_unlock() { CNTOOLS_POOL_UNLOCKED=("${pool}/cold.skey" "${pool}/calidus.skey"); }
  cntools_pool_locks_restore() {
    local file=''
    for file in "${CNTOOLS_POOL_PROTECTION_SNAPSHOTS[@]}"; do [[ ! -e "${file}" ]] || fail 'immutable lock applied before alias cleanup'; done
    restored=$((restored+1)); CNTOOLS_POOL_UNLOCKED=()
  }
  ! cntools_pool_protect "${pool}" encrypt "${password}" || fail 'immutable rollback fault accepted'
  assert_clear
  [[ "${restored}" == 1 ]] || fail 'original immutable flags not restored'
)
# A failed rollback publication retains the validated encrypted key instead
# of deleting the last copy. Recover it explicitly with the same password.
TEST_FAULT=retire-second-no-restore
! cntools_pool_protect "${pool}" encrypt "${password}" || fail 'failed restoration accepted'
TEST_FAULT=''; cntools_pool_protection_cleanup
[[ -f "${pool}/cold.skey.gpg" && ! -e "${pool}/cold.skey" && -f "${pool}/calidus.skey" && ! -e "${pool}/calidus.skey.gpg" ]] || fail 'last validated key lost'
cntools_pool_protect "${pool}" decrypt "${password}" || fail 'retained key recovery'
assert_clear
# Public-key and cached-ID mismatches reject the whole operation before
# publication. Original Calidus verification/ID files are not corrected.
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${TEST_ROOT}/other.skey" --verification-key-file "${TEST_ROOT}/other.vkey"
cp "${TEST_ROOT}/other.vkey" "${pool}/calidus.vkey"
! cntools_pool_protect "${pool}" encrypt "${password}" || fail 'Calidus public-key mismatch accepted'
cntools_pool_protection_cleanup; assert_clear
cp "${TEST_ROOT}/calidus-public.original" "${pool}/calidus.vkey"
printf 'wrong\n' > "${pool}/calidus.id"
! cntools_pool_protect "${pool}" encrypt "${password}" || fail 'Calidus ID mismatch accepted'
cntools_pool_protection_cleanup; assert_clear
printf '%s\n' "${id}" > "${pool}/calidus.id"
# Legacy short passwords on both keys remain valid. A different password on
# the second key must leave even the successfully opened first key encrypted.
for key in cold calidus; do
  output="${pool}/${key}.skey.gpg"; errors="${TEST_ROOT}/errors"; : > "${output}"; : > "${errors}"
  old_password=old; [[ "${key}" != calidus ]] || old_password=other
  cntools_key_crypto_run "${gpg_binary}" encrypt "${pool}/${key}.skey" "${output}" "${old_password}" "${errors}"
  rm "${pool}/${key}.skey"
done
encrypted="$(cksum "${pool}/cold.skey.gpg" "${pool}/calidus.skey.gpg")"
! cntools_pool_protect "${pool}" decrypt old || fail 'different second password accepted'
cntools_pool_protection_cleanup
[[ "$(cksum "${pool}/cold.skey.gpg" "${pool}/calidus.skey.gpg")" == "${encrypted}" && ! -e "${pool}/cold.skey" ]] || fail 'first key exposed after second key failure'
# Normalize this fixture externally, as users with differently encrypted keys
# must do; CNTools never partially decrypts a password-mismatched set.
: > "${TEST_ROOT}/calidus.clear"
cntools_key_crypto_run "${gpg_binary}" decrypt "${pool}/calidus.skey.gpg" "${TEST_ROOT}/calidus.clear" other "${errors}"
cntools_key_crypto_run "${gpg_binary}" encrypt "${TEST_ROOT}/calidus.clear" "${pool}/calidus.skey.gpg" old "${errors}"
cntools_pool_protect "${pool}" decrypt old || fail 'short legacy password'
assert_clear
# Extended Calidus envelopes and hardware/watch-only cold identities work too.
mkdir -m700 "${CNTOOLS_POOL_DIR}/Extended"
"${CNTOOLS_CLI}" key generate-mnemonic --size 24 > "${TEST_ROOT}/mnemonic"
"${CNTOOLS_CLI}" key derive-from-mnemonic --payment-key-with-number 0 --account-number 0 --mnemonic-from-file "${TEST_ROOT}/mnemonic" --signing-key-file "${CNTOOLS_POOL_DIR}/Extended/calidus.skey"
cp "${CNTOOLS_POOL_DIR}/Extended/calidus.skey" "${TEST_ROOT}/extended.original"
printf 'public hardware reference\n' > "${CNTOOLS_POOL_DIR}/Extended/cold.hwsfile"
cntools_pool_protect "${CNTOOLS_POOL_DIR}/Extended" encrypt "${password}" || fail 'extended-only encryption'
[[ "${CNTOOLS_POOL_PROTECTION_KEYS}" == 1 ]] || fail 'hardware cold counted as secret'
cntools_pool_protect "${CNTOOLS_POOL_DIR}/Extended" decrypt "${password}" || fail 'extended-only decryption'
cmp -s "${CNTOOLS_POOL_DIR}/Extended/calidus.skey" "${TEST_ROOT}/extended.original" || fail 'extended secret changed'
[[ -f "${CNTOOLS_POOL_DIR}/Extended/cold.hwsfile" && ! -e "${CNTOOLS_POOL_DIR}/Extended/cold.hwsfile.gpg" ]] || fail 'hardware public reference encrypted'
cntools_pool_protection_cleanup; cntools_transaction_cleanup
[[ "$(< "${TEST_ROOT}/log")" != *"${password}"* ]] || fail 'password logged'
for secret in cold.original calidus.original extended.original; do
  ! rg -F "$(jq -r .cborHex "${TEST_ROOT}/${secret}")" "${TEST_ROOT}/log" >/dev/null || fail 'private key logged'
done
[[ -z "$(find "${CNTOOLS_POOL_DIR}" -name '.cntools-*' -print -quit)" ]] || fail 'private staging leftovers'
printf 'PASS: cold/Calidus GPG round trips, legacy passwords, staged pair validation, rollback and extended keys (CLI %s)\n' "${pin}"
