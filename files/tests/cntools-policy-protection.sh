#!/usr/bin/env bash
# Real GPG compatibility and key-retention safety; optional pinned real CLI.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-policy-protection.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
GPG_TEST_ROOT="$(mktemp -d /tmp/cntools-gpg.XXXXXX)"
export GNUPGHOME="${GPG_TEST_ROOT}"
trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf -- "${TEST_ROOT}" "${GPG_TEST_ROOT}"' EXIT
for lib in number wallet wallet-key wallet-query transaction policy-files policy policy-catalog key-crypto policy-lock policy-protection; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { tail -10 "${TEST_ROOT}/log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
FAULT=''
cntools_run_command() { local mask="$1"; shift 2; (( ${#mask} == $# )) || fail 'audit mask'; [[ "${FAULT}" != retire || "$1" != rm ]] || return 17; "$@"; }
cntools_run_command_timeout() { shift 3; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_LN="$(type -P ln)"
  chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  ln() {
    if [[ "$1" == -T ]]; then shift; [[ "$1" != -- ]] || shift; [[ ! -e "$2" && ! -L "$2" ]] || return 1; fi
    "${REAL_LN}" "$@"
  }
fi
CNTOOLS_ASSET_DIR="${TEST_ROOT}/assets" CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_ENABLE_CHATTR=false
CNTOOLS_CLI="${1:-}"; mkdir -m700 "${CNTOOLS_ASSET_DIR}" "${CNTOOLS_ASSET_DIR}/Policy"
directory="${CNTOOLS_ASSET_DIR}/Policy"
if [[ -n "${CNTOOLS_CLI}" ]]; then
  pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
  [[ "$("${CNTOOLS_CLI}" version | head -1)" == "cardano-cli ${pin} "* ]] || fail 'wrong deployment pin'
  "${CNTOOLS_CLI}" address key-gen --verification-key-file "${directory}/policy.vkey" --signing-key-file "${directory}/policy.skey"
else
  jq -n --arg hex "5820$(printf 'aa%.0s' {1..32})" '{type:"PaymentSigningKeyShelley_ed25519",cborHex:$hex}' > "${directory}/policy.skey"
  # The standard test proves GPG/filesystem behavior, not CLI key derivation.
  cntools_policy_key_matches() { cntools_wallet_key_normal_envelope_valid "$1" payment signing; }
fi
chmod 600 "${directory}"/*; cp "${directory}/policy.skey" "${TEST_ROOT}/original"
! cntools_policy_protect "${directory}" encrypt short || fail 'new short password accepted'
cntools_policy_protection_cleanup
cntools_policy_protect "${directory}" encrypt 'long-test-password' || fail "encrypt: ${CNTOOLS_POLICY_ERROR}"
[[ -f "${directory}/policy.skey.gpg" && ! -e "${directory}/policy.skey" ]] || fail 'encryption publication'
cntools_policy_protect "${directory}" encrypt '' || fail 're-locking already encrypted policy'
! cntools_policy_protect "${directory}" decrypt wrong || fail 'wrong password accepted'
cntools_policy_protection_cleanup
[[ -f "${directory}/policy.skey.gpg" && ! -e "${directory}/policy.skey" ]] || fail 'wrong password changed keys'
cntools_policy_protect "${directory}" decrypt 'long-test-password' || fail 'decrypt'
cmp -s "${directory}/policy.skey" "${TEST_ROOT}/original" || fail 'key bytes changed'
FAULT=retire
! cntools_policy_protect "${directory}" encrypt 'long-test-password' || fail 'retirement failure accepted'
FAULT=''; cntools_policy_protection_cleanup
[[ -f "${directory}/policy.skey" && ! -e "${directory}/policy.skey.gpg" ]] || fail 'failed retirement lost original or left mixed keys'
# Existing ciphertext with a short legacy password remains decryptable.
errors="${TEST_ROOT}/error"; : > "${errors}"
: > "${directory}/policy.skey.gpg"; chmod 600 "${directory}/policy.skey.gpg"
cntools_key_crypto_run "$(type -P gpg)" encrypt "${directory}/policy.skey" "${directory}/policy.skey.gpg" old "${errors}" || fail 'legacy fixture'
rm "${directory}/policy.skey"
cntools_policy_protect "${directory}" decrypt old || fail 'short legacy decrypt'
cmp -s "${directory}/policy.skey" "${TEST_ROOT}/original" || fail 'legacy key changed'
ln -s "${TEST_ROOT}/original" "${directory}/linked"
! cntools_policy_protect "${directory}" encrypt 'long-test-password' || fail 'linked artifact accepted'
cntools_policy_protection_cleanup; cntools_transaction_cleanup
[[ -f "${directory}/policy.skey" ]] || fail 'cleanup lost private key'
printf 'Policy GPG compatibility and key-retention checks passed\n'
