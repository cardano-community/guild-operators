#!/usr/bin/env bash
# Guarded key deletion against disposable files and the cnode CLI deployment pin.
# shellcheck disable=SC1090,SC2034,SC2030,SC2031,SC2329,SC2154,SC2015
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the cnode deployment CLI pin}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-private-keys.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
for lib in wallet wallet-material wallet-key wallet-protection transaction catalyst-key private-keys; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command() { shift 2; "$@"; }
cntools_run_command_timeout() { shift 3; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- ]] || args+=("${a}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong cnode pin'
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}"
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets" CNTOOLS_POOL_DIR="${TEST_ROOT}/pools" CNTOOLS_ASSET_DIR="${TEST_ROOT}/policies"
CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey
CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey
CNTOOLS_WALLET_DREP_SKEY_FILENAME=drep.skey CNTOOLS_WALLET_DREP_VKEY_FILENAME=drep.vkey
CNTOOLS_POOL_COLD_SKEY_FILENAME=cold.skey CNTOOLS_POOL_COLD_VKEY_FILENAME=cold.vkey
CNTOOLS_POOL_KES_SKEY_FILENAME=hot.skey CNTOOLS_POOL_VRF_SKEY_FILENAME=vrf.skey
mkdir -m700 "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_POOL_DIR}" "${CNTOOLS_ASSET_DIR}" "${CNTOOLS_WALLET_DIR}/Example" "${CNTOOLS_POOL_DIR}/Example" "${CNTOOLS_ASSET_DIR}/Example"
wallet="${CNTOOLS_WALLET_DIR}/Example" pool="${CNTOOLS_POOL_DIR}/Example" policy="${CNTOOLS_ASSET_DIR}/Example"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${wallet}/payment.skey" --verification-key-file "${wallet}/payment.vkey"
"${CNTOOLS_CLI}" latest stake-address key-gen --signing-key-file "${wallet}/stake.skey" --verification-key-file "${wallet}/stake.vkey"
"${CNTOOLS_CLI}" latest governance drep key-gen --signing-key-file "${wallet}/drep.skey" --verification-key-file "${wallet}/drep.vkey"
"${CNTOOLS_CLI}" latest governance committee key-gen-cold --cold-signing-key-file "${wallet}/cc-cold.skey" --cold-verification-key-file "${wallet}/cc-cold.vkey"
"${CNTOOLS_CLI}" latest governance committee key-gen-hot --signing-key-file "${wallet}/cc-hot.skey" --verification-key-file "${wallet}/cc-hot.vkey"
for role in payment stake; do
  cp "${wallet}/${role}.skey" "${wallet}/ms_${role}.skey"
  cp "${wallet}/${role}.vkey" "${wallet}/ms_${role}.vkey"
done
"${CNTOOLS_CLI}" latest node key-gen --cold-signing-key-file "${pool}/cold.skey" --cold-verification-key-file "${pool}/cold.vkey" --operational-certificate-issue-counter-file "${pool}/cold.counter"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${pool}/calidus.skey" --verification-key-file "${pool}/calidus.vkey"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${policy}/policy.skey" --verification-key-file "${policy}/policy.vkey"
printf 'operational KES\n' > "${pool}/hot.skey"; printf 'operational VRF\n' > "${pool}/vrf.skey"
printf 'hardware reference\n' > "${wallet}/payment.hwsfile"; printf 'native script\n' > "${wallet}/payment.script"
printf 'private seed not selected\n' > "${wallet}/seed.txt"
printf 'encrypted key fixture\n' > "${wallet}/payment.skey.gpg"
# Avoid actual immutable mutations in this disposable unit suite.
cntools_wallet_protection_immutable_files_into() { local -n result="$1"; result=(); }
cntools_private_keys_inventory all N || fail "inventory: ${CNTOOLS_PRIVATE_KEY_ERROR}"
[[ ${#CNTOOLS_PRIVATE_KEY_FILES[@]} == 10 ]] || fail 'unexpected plaintext key count'
! cntools_private_keys_delete DELETE || fail 'missing explicit acknowledgement accepted'
[[ -f "${wallet}/payment.skey" ]] || fail 'deleted without confirmation'
# Retained public files are part of the reviewed identity too.
mv "${wallet}/payment.vkey" "${TEST_ROOT}/payment.vkey"
! cntools_private_keys_delete 'DELETE PRIVATE KEYS' || fail 'removed public key accepted after preview'
[[ "${CNTOOLS_PRIVATE_KEY_REMOVED}" == 0 && -f "${wallet}/payment.skey" ]] || fail 'deletion before public identity preflight'
mv "${TEST_ROOT}/payment.vkey" "${wallet}/payment.vkey"
# Preview identity includes content and inode. Changed keys stop all deletion.
printf 'changed\n' >> "${wallet}/payment.skey"
! cntools_private_keys_delete 'DELETE PRIVATE KEYS' || fail 'changed preview accepted'
[[ "${CNTOOLS_PRIVATE_KEY_REMOVED}" == 0 && -f "${pool}/cold.skey" ]] || fail 'partial deletion before preflight'
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${wallet}/payment.skey" --verification-key-file "${wallet}/payment.vkey"
ln -- "${wallet}/payment.skey" "${TEST_ROOT}/linked.skey"
! cntools_private_keys_inventory wallets N || fail 'hard-linked key accepted'
rm -- "${TEST_ROOT}/linked.skey"
mv "${wallet}/stake.vkey" "${TEST_ROOT}/stake.vkey"
! cntools_private_keys_inventory wallets N || fail 'missing public key accepted'
mv "${TEST_ROOT}/stake.vkey" "${wallet}/stake.vkey"
ln -s "${pool}" "${CNTOOLS_WALLET_DIR}/Unsafe"
! cntools_private_keys_inventory wallets N || fail 'linked wallet accepted'
rm -- "${CNTOOLS_WALLET_DIR}/Unsafe"
(
  CNTOOLS_POOL_COLD_SKEY_FILENAME=hot.skey
  ! cntools_private_keys_inventory pools N || fail 'operational key selected by bad configuration'
)
cntools_private_keys_inventory wallets N Example && cntools_private_keys_delete 'DELETE PRIVATE KEYS' || fail 'wallet-only deletion'
[[ "${CNTOOLS_PRIVATE_KEY_REMOVED}" == 7 && -f "${wallet}/payment.skey.gpg" && -f "${pool}/cold.skey" ]] || fail 'scope/encrypted exclusion failed'
cntools_private_keys_inventory all Y && cntools_private_keys_delete 'DELETE PRIVATE KEYS' || fail 'encrypted/pool/policy deletion'
[[ "${CNTOOLS_PRIVATE_KEY_REMOVED}" == 4 ]] || fail 'remaining key count incorrect'
for file in "${wallet}/payment.vkey" "${wallet}/stake.vkey" "${wallet}/drep.vkey" "${wallet}/cc-cold.vkey" "${wallet}/cc-hot.vkey" \
  "${wallet}/ms_payment.vkey" "${wallet}/ms_stake.vkey" "${wallet}/payment.hwsfile" \
  "${wallet}/payment.script" "${wallet}/seed.txt" "${pool}/cold.vkey" "${pool}/cold.counter" "${pool}/calidus.vkey" "${pool}/hot.skey" "${pool}/vrf.skey" "${policy}/policy.vkey"; do
  [[ -f "${file}" ]] || fail "retained artifact deleted: ${file}"
done
# Mid-operation failure reports the exact completed count and retains later keys.
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${wallet}/payment.skey" --verification-key-file "${wallet}/payment.vkey"
"${CNTOOLS_CLI}" latest stake-address key-gen --signing-key-file "${wallet}/stake.skey" --verification-key-file "${wallet}/stake.vkey"
cntools_private_keys_inventory wallets N Example
calls=0
cntools_run_command() { shift 2; calls=$((calls+1)); ((calls != 2)) || return 1; "$@"; }
! cntools_private_keys_delete 'DELETE PRIVATE KEYS' || fail 'unlink failure ignored'
[[ "${CNTOOLS_PRIVATE_KEY_REMOVED}" == 1 && ! -e "${wallet}/payment.skey" && -f "${wallet}/stake.skey" ]] || fail 'incorrect partial result'
# Restore protection only on the exact reviewed key, never a replacement path.
cntools_private_keys_inventory wallets N Example
CNTOOLS_PRIVATE_KEY_UNLOCKED=("${wallet}/stake.skey")
locks=0
cntools_wallet_protection_chattr_run() { [[ "$1" == +i ]] || fail 'unexpected lock operation'; locks=$((locks+1)); }
cntools_private_keys_restore_locks
[[ "${locks}" == 1 ]] || fail 'unchanged protection not restored'
CNTOOLS_PRIVATE_KEY_UNLOCKED=("${wallet}/stake.skey")
mv "${wallet}/stake.skey" "${TEST_ROOT}/old-stake.skey"
ln -s "${TEST_ROOT}/old-stake.skey" "${wallet}/stake.skey"
cntools_private_keys_restore_locks
[[ "${locks}" == 1 ]] || fail 'replacement path locked'
cntools_transaction_cleanup
printf 'CNTools private-key deletion pinned tests passed (%s)\n' "${pin}"
