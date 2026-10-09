#!/usr/bin/env bash
# Offline backup round trips and hostile archive/no-overwrite regression tests.
# shellcheck disable=SC1090,SC2034,SC2015,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d)"; TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
GPG_TEST_ROOT="$(mktemp -d /tmp/cntools-backup-gpg.XXXXXXXX)"
cleanup() {
  cntools_backup_cleanup || true
  gpgconf --homedir "${GPG_TEST_ROOT}" --kill gpg-agent >/dev/null 2>&1 || true
  [[ "${TEST_ROOT}" != / && -d "${TEST_ROOT}" && -O "${TEST_ROOT}" ]] && rm -rf -- "${TEST_ROOT}"
  [[ "${GPG_TEST_ROOT}" == /tmp/cntools-backup-gpg.* && -d "${GPG_TEST_ROOT}" && ! -L "${GPG_TEST_ROOT}" && -O "${GPG_TEST_ROOT}" ]] && rm -rf -- "${GPG_TEST_ROOT}"
}
trap cleanup EXIT
for lib in transaction key-crypto backup-files backup; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$1 != $2"; }
mode='' original='' current=''
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() {
  shift 3
  printf '%q ' "$@" >> "${TEST_ROOT}/commands"; printf '\n' >> "${TEST_ROOT}/commands"
  "$@"
}
# Production requires GNU no-target-directory semantics. macOS exercises the
# same absence checks with a test-only adapter; Linux uses real GNU mv.
if [[ "${OSTYPE:-}" == darwin* ]]; then
  chmod() {
    local argument=''; local -a arguments=()
    for argument in "$@"; do [[ "${argument}" == -- ]] || arguments+=("${argument}"); done
    command chmod "${arguments[@]}"
  }
  mv() {
    if [[ "$1" == --help ]]; then printf '%s\n' '--no-target-directory --no-clobber'; return 0; fi
    if [[ "$1" == -T ]]; then
      shift 3
      [[ ! -e "$2" && ! -L "$2" ]] || return 0
      command mv -n -- "$1" "$2"
    else command mv "$@"; fi
  }
fi
umask 077
CNTOOLS_NODE_HOME="${TEST_ROOT}/source"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
CNTOOLS_WALLET_DIR="${CNTOOLS_NODE_HOME}/priv/wallet"
CNTOOLS_POOL_DIR="${CNTOOLS_NODE_HOME}/priv/pool"
CNTOOLS_ASSET_DIR="${CNTOOLS_NODE_HOME}/priv/asset"
CNTOOLS_NETWORK=preview
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey
CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred
CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred
CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile
CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr
CNTOOLS_POOL_COLD_SKEY_FILENAME=cold.skey
CNTOOLS_POOL_COLD_VKEY_FILENAME=cold.vkey
CNTOOLS_POOL_COUNTER_FILENAME=cold.counter
CNTOOLS_POOL_OPCERT_FILENAME=op.cert
CNTOOLS_POOL_CALIDUS_SKEY_FILENAME=calidus.skey
CNTOOLS_POOL_CALIDUS_VKEY_FILENAME=calidus.vkey
CNTOOLS_POOL_CALIDUS_ID_FILENAME=calidus.id
mkdir -p "${CNTOOLS_TMP_DIR}" "${CNTOOLS_WALLET_DIR}/Test" "${CNTOOLS_POOL_DIR}/Pool" "${CNTOOLS_POOL_DIR}/.cntools-kes-rotate.recovery" "${CNTOOLS_ASSET_DIR}/Asset" "${TEST_ROOT}/out"
printf 'private payment\n' > "${CNTOOLS_WALLET_DIR}/Test/payment.skey"
printf 'public payment\n' > "${CNTOOLS_WALLET_DIR}/Test/payment.vkey"
printf 'public hardware reference\n' > "${CNTOOLS_WALLET_DIR}/Test/payment.hwsfile"
printf 'addr_test\n' > "${CNTOOLS_WALLET_DIR}/Test/base.addr"
printf 'custom secret\n' > "${CNTOOLS_WALLET_DIR}/Test/my-seed.txt"
printf 'private cold\n' > "${CNTOOLS_POOL_DIR}/Pool/cold.skey"
printf 'cold public\n' > "${CNTOOLS_POOL_DIR}/Pool/cold.vkey"
printf 'private Calidus\n' > "${CNTOOLS_POOL_DIR}/Pool/calidus.skey"
printf 'public Calidus\n' > "${CNTOOLS_POOL_DIR}/Pool/calidus.vkey"
printf 'Calidus ID\n' > "${CNTOOLS_POOL_DIR}/Pool/calidus.id"
printf 'counter 9\n' > "${CNTOOLS_POOL_DIR}/Pool/cold.counter"
printf 'certificate 8\n' > "${CNTOOLS_POOL_DIR}/Pool/op.cert"
printf 'recovery hot key\n' > "${CNTOOLS_POOL_DIR}/.cntools-kes-rotate.recovery/hot.skey"
printf 'policy private\n' > "${CNTOOLS_ASSET_DIR}/Asset/policy.skey"
printf 'policy public\n' > "${CNTOOLS_ASSET_DIR}/Asset/policy.id"
mkdir -m700 "${CNTOOLS_WALLET_DIR}/Watch" "${CNTOOLS_WALLET_DIR}/Hardware" "${CNTOOLS_POOL_DIR}/MissingCold"
printf 'public only\n' > "${CNTOOLS_WALLET_DIR}/Watch/stake.vkey"
printf 'hardware public\n' > "${CNTOOLS_WALLET_DIR}/Hardware/payment.vkey"
printf 'hardware reference\n' > "${CNTOOLS_WALLET_DIR}/Hardware/payment.hwsfile"
printf 'pool public\n' > "${CNTOOLS_POOL_DIR}/MissingCold/cold.vkey"
cntools_backup_recovery_coverage || fail 'coverage preflight'
coverage="$(printf '%s\n' "${CNTOOLS_BACKUP_COVERAGE_LABELS[@]}" "${CNTOOLS_BACKUP_COVERAGE_VALUES[@]}")"
[[ "${coverage}" == *'wallets/Watch · stake.vkey'* && "${coverage}" == *'Missing stake.skey'* &&
   "${coverage}" == *'pools/MissingCold · cold.vkey'* && "${coverage}" == *'Missing cold.skey'* &&
   "${coverage}" == *'Hardware reference only'* && "${CNTOOLS_BACKUP_MISSING_KEYS}" == 2 ]] || fail 'missing keys/device coverage'
[[ "${coverage}" != *'wallets/Watch · payment.vkey'* ]] || fail 'invented payment role for stake-only wallet'
# Coverage-only fixtures must not alter the existing archive round-trip counts.
rm -r -- "${CNTOOLS_WALLET_DIR}/Watch" "${CNTOOLS_WALLET_DIR}/Hardware" "${CNTOOLS_POOL_DIR}/MissingCold"
cntools_backup_create "${TEST_ROOT}/out" full plain || fail "full backup: ${CNTOOLS_BACKUP_ERROR}"
FULL_BACKUP="${CNTOOLS_BACKUP_RESULT}"
cntools_backup_restore_prepare "${FULL_BACKUP}" || fail "prepare full: ${CNTOOLS_BACKUP_ERROR}"
eq "${CNTOOLS_BACKUP_KIND}" full; eq "${CNTOOLS_BACKUP_NETWORK}" preview
cmp "${CNTOOLS_WALLET_DIR}/Test/payment.skey" "${CNTOOLS_BACKUP_WORK}/restore/wallets/Test/payment.skey"
cmp "${CNTOOLS_POOL_DIR}/Pool/calidus.skey" "${CNTOOLS_BACKUP_WORK}/restore/pools/Pool/calidus.skey"
cntools_backup_create "${TEST_ROOT}/out" public plain || fail "public backup: ${CNTOOLS_BACKUP_ERROR}"
PUBLIC_BACKUP="${CNTOOLS_BACKUP_RESULT}"
cntools_backup_restore_prepare "${PUBLIC_BACKUP}" || fail 'public prepare'
[[ ! -e "${CNTOOLS_BACKUP_WORK}/restore/wallets/Test/payment.skey" &&
   ! -e "${CNTOOLS_BACKUP_WORK}/restore/wallets/Test/my-seed.txt" &&
   ! -e "${CNTOOLS_BACKUP_WORK}/restore/pools/.cntools-kes-rotate.recovery" &&
   -f "${CNTOOLS_BACKUP_WORK}/restore/wallets/Test/base.addr" &&
   -f "${CNTOOLS_BACKUP_WORK}/restore/wallets/Test/payment.hwsfile" ]] || fail 'public private-file omission/HWS retention'
[[ ! -e "${CNTOOLS_BACKUP_WORK}/restore/pools/Pool/calidus.skey" &&
   -f "${CNTOOLS_BACKUP_WORK}/restore/pools/Pool/calidus.vkey" &&
   -f "${CNTOOLS_BACKUP_WORK}/restore/pools/Pool/calidus.id" ]] || fail 'Calidus public/private backup boundary'

# Restore on a fresh deployment imports missing objects, but leaves KES stages
# inactive. Same-name objects are never merged, even on a repeat restore.
CNTOOLS_NODE_HOME="${TEST_ROOT}/target"
CNTOOLS_WALLET_DIR="${CNTOOLS_NODE_HOME}/priv/wallet"
CNTOOLS_POOL_DIR="${CNTOOLS_NODE_HOME}/priv/pool"
CNTOOLS_ASSET_DIR="${CNTOOLS_NODE_HOME}/priv/asset"
mkdir -p "${CNTOOLS_NODE_HOME}/priv" "${CNTOOLS_POOL_DIR}/Pool"
printf 'current counter 42\n' > "${CNTOOLS_POOL_DIR}/Pool/cold.counter"
cntools_backup_restore_prepare "${FULL_BACKUP}" && cntools_backup_restore_apply || fail "restore: ${CNTOOLS_BACKUP_ERROR}"
eq "${CNTOOLS_BACKUP_IMPORTED}" 2; eq "${CNTOOLS_BACKUP_SKIPPED}" 2
eq "$(< "${CNTOOLS_POOL_DIR}/Pool/cold.counter")" 'current counter 42'
[[ ! -e "${CNTOOLS_POOL_DIR}/Pool/cold.skey" && ! -e "${CNTOOLS_POOL_DIR}/.cntools-kes-rotate.recovery" &&
   -f "${CNTOOLS_BACKUP_RESULT}/pools/.cntools-kes-rotate.recovery/hot.skey" ]] || fail 'KES/conflict recovery copy'
cntools_filesystem_mode_into mode "${CNTOOLS_WALLET_DIR}/Test"; eq "${mode}" 700
cntools_filesystem_mode_into mode "${CNTOOLS_WALLET_DIR}/Test/payment.skey"; eq "${mode}" 600
cntools_backup_restore_prepare "${FULL_BACKUP}" && cntools_backup_restore_apply || fail 'repeat restore'
eq "${CNTOOLS_BACKUP_IMPORTED}" 0; eq "${CNTOOLS_BACKUP_SKIPPED}" 4

# Real GPG round trip, no secret logged or present in command arguments. Old
# encrypted backups with short passphrases remain decryptable.
if type -P gpg >/dev/null; then
  export GNUPGHOME="${GPG_TEST_ROOT}"
  cntools_backup_create "${TEST_ROOT}/out" full encrypted 'a secret passphrase' || {
    printf 'GPG backup error: %s\n' "${CNTOOLS_BACKUP_ERROR}" >&2
    [[ ! -f "${CNTOOLS_BACKUP_WORK}/errors" ]] || sed -n '1,6p' "${CNTOOLS_BACKUP_WORK}/errors" >&2
    fail 'GPG create'
  }
  ENCRYPTED="${CNTOOLS_BACKUP_RESULT}"
  cntools_backup_hash_into original "${ENCRYPTED}"
  cntools_backup_restore_prepare "${ENCRYPTED}" 'a secret passphrase' || fail 'GPG prepare'
  cntools_backup_hash_into current "${ENCRYPTED}"; eq "${original}" "${current}"
  if cntools_backup_restore_prepare "${ENCRYPTED}" wrong; then fail 'wrong password accepted'; fi
  cntools_backup_hash_into current "${ENCRYPTED}"; eq "${original}" "${current}"
  if cntools_backup_create "${TEST_ROOT}/out" full encrypted short; then fail 'short new passphrase accepted'; fi
  cntools_backup_environment
  : > "${CNTOOLS_BACKUP_WORK}/short"
  cntools_backup_crypto "$(type -P gpg)" encrypt "${FULL_BACKUP}" "${CNTOOLS_BACKUP_WORK}/short" short
  cp "${CNTOOLS_BACKUP_WORK}/short" "${TEST_ROOT}/short.tar.gz.gpg"
  cntools_backup_restore_prepare "${TEST_ROOT}/short.tar.gz.gpg" short || fail 'short old passphrase rejected'
  if rg -F 'a secret passphrase' "${TEST_ROOT}/commands" "${TEST_ROOT}/log"; then fail 'passphrase leaked'; fi
else fail 'GnuPG is required to run the backup encryption regressions'; fi

# A legacy absolute-source-layout archive can be restored into another node
# home. It is intentionally marked legacy/unverified and never modified.
tar -czf "${TEST_ROOT}/legacy.tar.gz" -C / "${TEST_ROOT#/}/source/priv/wallet/Test" "${TEST_ROOT#/}/source/priv/pool/Pool" "${TEST_ROOT#/}/source/priv/asset/Asset"
cntools_backup_restore_prepare "${TEST_ROOT}/legacy.tar.gz" || fail "legacy: ${CNTOOLS_BACKUP_ERROR}"
eq "${CNTOOLS_BACKUP_KIND}" legacy
[[ -f "${CNTOOLS_BACKUP_WORK}/restore/pools/Pool/cold.skey" ]] || fail 'legacy pool mapping'

mkdir -p "${TEST_ROOT}/bad/wallets/Bad"
printf 'payload\n' > "${TEST_ROOT}/bad/wallets/Bad/file"
expect_bad() { if cntools_backup_restore_prepare "$1"; then fail "unsafe archive accepted: $1"; fi; }
ln -s "${TEST_ROOT}/out" "${TEST_ROOT}/bad/wallets/Bad/link"
tar -czf "${TEST_ROOT}/link.tar.gz" -C "${TEST_ROOT}/bad" wallets
expect_bad "${TEST_ROOT}/link.tar.gz"
rm "${TEST_ROOT}/bad/wallets/Bad/link"
ln "${TEST_ROOT}/bad/wallets/Bad/file" "${TEST_ROOT}/bad/wallets/Bad/hardlink"
tar -czf "${TEST_ROOT}/hardlink.tar.gz" -C "${TEST_ROOT}/bad" wallets
expect_bad "${TEST_ROOT}/hardlink.tar.gz"
rm "${TEST_ROOT}/bad/wallets/Bad/hardlink"
tar -czf "${TEST_ROOT}/duplicate.tar.gz" -C "${TEST_ROOT}/bad" wallets/Bad/file wallets/Bad/file
expect_bad "${TEST_ROOT}/duplicate.tar.gz"
# Path traversal, control/newline names, files used as directories, unexpected
# top-level paths and corrupted manifests must fail before live publication.
if [[ "$(tar --version)" == bsdtar* ]]; then
  tar -czf "${TEST_ROOT}/traversal.tar.gz" -s '|wallets/Bad/file|../escape|' -C "${TEST_ROOT}/bad" wallets/Bad/file
else
  tar -czf "${TEST_ROOT}/traversal.tar.gz" --transform='s|wallets/Bad/file|../escape|' -C "${TEST_ROOT}/bad" wallets/Bad/file
fi
expect_bad "${TEST_ROOT}/traversal.tar.gz"
printf 'x\n' > "${TEST_ROOT}/bad/wallets/Bad/line"$'\n''break'
tar -czf "${TEST_ROOT}/newline.tar.gz" -C "${TEST_ROOT}/bad" wallets
expect_bad "${TEST_ROOT}/newline.tar.gz"
rm "${TEST_ROOT}/bad/wallets/Bad/line"$'\n''break'
tar -czf "${TEST_ROOT}/unknown.tar.gz" -C "${TEST_ROOT}/bad" wallets
expect_bad "${TEST_ROOT}/unknown.tar.gz" # no manifest and not a legacy source layout
cntools_backup_restore_prepare "${FULL_BACKUP}"
cp "${CNTOOLS_BACKUP_WORK}/manifest.json" "${CNTOOLS_BACKUP_WORK}/restore/manifest.json"
printf 'tampered\n' > "${CNTOOLS_BACKUP_WORK}/restore/wallets/Test/payment.skey"
tar -czf "${TEST_ROOT}/tampered.tar.gz" -C "${CNTOOLS_BACKUP_WORK}/restore" manifest.json wallets pools assets
expect_bad "${TEST_ROOT}/tampered.tar.gz"
cntools_backup_restore_prepare "${FULL_BACKUP}"
jq '.version=999' "${CNTOOLS_BACKUP_WORK}/manifest.json" > "${CNTOOLS_BACKUP_WORK}/restore/manifest.json"
tar -czf "${TEST_ROOT}/version.tar.gz" -C "${CNTOOLS_BACKUP_WORK}/restore" manifest.json wallets pools assets
expect_bad "${TEST_ROOT}/version.tar.gz"
CNTOOLS_BACKUP_MAX_BYTES=1; expect_bad "${FULL_BACKUP}"; CNTOOLS_BACKUP_MAX_BYTES=536870912
CNTOOLS_BACKUP_MAX_ENTRIES=1; expect_bad "${FULL_BACKUP}"; CNTOOLS_BACKUP_MAX_ENTRIES=20000
ln -s "${FULL_BACKUP}" "${TEST_ROOT}/linked.tar.gz"; expect_bad "${TEST_ROOT}/linked.tar.gz"

# Active counter issuance and source mutation must stop snapshot publication.
mkdir -p "${CNTOOLS_POOL_DIR}/Pool/.cntools-opcert-lock/busy"
if cntools_backup_create "${TEST_ROOT}/out" full plain; then fail 'busy pool snapshot accepted'; fi
rmdir "${CNTOOLS_POOL_DIR}/Pool/.cntools-opcert-lock/busy" "${CNTOOLS_POOL_DIR}/Pool/.cntools-opcert-lock"
ln -s "${TEST_ROOT}/out" "${CNTOOLS_WALLET_DIR}/Test/link"
if cntools_backup_create "${TEST_ROOT}/out" full plain; then fail 'source symlink accepted'; fi
rm "${CNTOOLS_WALLET_DIR}/Test/link"
if cntools_backup_create "${CNTOOLS_WALLET_DIR}" full plain; then fail 'self-referential destination accepted'; fi
chmod 777 "${TEST_ROOT}/out"
if cntools_backup_create "${TEST_ROOT}/out" full plain; then fail 'unsafe destination accepted'; fi
chmod 700 "${TEST_ROOT}/out"
chmod 777 "${CNTOOLS_WALLET_DIR}/Test"
if cntools_backup_create "${TEST_ROOT}/out" full plain; then fail 'unsafe source subdirectory accepted'; fi
chmod 700 "${CNTOOLS_WALLET_DIR}/Test"
(
  export TAR_OPTIONS='--transform=s,^,../escaped/,'
  cntools_backup_create "${TEST_ROOT}/out" full plain || fail 'inherited tar options affected creation'
  cntools_backup_restore_prepare "${CNTOOLS_BACKUP_RESULT}" || fail 'inherited tar options affected restore'
  [[ -f "${CNTOOLS_BACKUP_WORK}/restore/wallets/Test/payment.skey" ]] || fail 'inherited tar transform was not ignored'
)

# Mutation after a snapshot copy is detected by the final inventory pass.
(
  cp() {
    command cp "$@" || return $?
    if [[ "$*" == *'/wallet/Test/payment.skey'* ]]; then
      printf 'changed private key\n' > "${CNTOOLS_WALLET_DIR}/Test/payment.skey"
    fi
  }
  if cntools_backup_create "${TEST_ROOT}/out" full plain; then fail 'mutating snapshot published'; fi
  [[ "${CNTOOLS_BACKUP_ERROR}" == *changed* ]] || fail 'mutation diagnostic missing'
)
# Validate all roots before importing any object, even when a later root is
# unsafe. No live data is changed merely by opening/previewing an archive.
(
  CNTOOLS_NODE_HOME="${TEST_ROOT}/unsafe-target"
  CNTOOLS_WALLET_DIR="${CNTOOLS_NODE_HOME}/priv/wallet"
  CNTOOLS_POOL_DIR="${CNTOOLS_NODE_HOME}/priv/pool"
  CNTOOLS_ASSET_DIR="${CNTOOLS_NODE_HOME}/priv/asset"
  mkdir -p "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_POOL_DIR}" "${CNTOOLS_ASSET_DIR}"
  chmod 777 "${CNTOOLS_WALLET_DIR}"
  cntools_backup_restore_prepare "${FULL_BACKUP}"
  if cntools_backup_restore_apply; then fail 'unsafe restore root accepted'; fi
  [[ ! -e "${CNTOOLS_ASSET_DIR}/Asset" && ! -e "${CNTOOLS_POOL_DIR}/Pool" ]] || fail 'partial unsafe-root import'
)
# GNU mv -n can report success without moving anything. Publication must check
# that its source vanished, not mistake an existing destination for success.
cntools_backup_environment
printf 'new\n' > "${CNTOOLS_BACKUP_WORK}/publish"
printf 'existing\n' > "${TEST_ROOT}/out/existing"
if cntools_backup_publish "${CNTOOLS_BACKUP_WORK}/publish" "${TEST_ROOT}/out/existing"; then fail 'overwrite publication accepted'; fi
eq "$(< "${TEST_ROOT}/out/existing")" existing
[[ -f "${CNTOOLS_BACKUP_WORK}/publish" ]] || fail 'publication source lost'
stage_file="$(mktemp "${TEST_ROOT}/out/.cntools-backup.XXXXXXXX")"
stage_dir="$(mktemp -d "${TEST_ROOT}/out/.cntools-restore.XXXXXXXX")"
CNTOOLS_BACKUP_STAGES+=("${stage_file}" "${stage_dir}")
cntools_backup_cleanup
[[ ! -e "${stage_file}" && ! -e "${stage_dir}" && -f "${FULL_BACKUP}" && -f "${PUBLIC_BACKUP}" ]] || fail 'staging cleanup removed published data or left private temp files'
printf 'CNTools backup safety tests passed\n'
