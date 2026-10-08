#!/usr/bin/env bash
# Generated test identities only; no node, network, submission or real wallet.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the cnode deployment-pinned CLI}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-script-drep.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'cntools_drep_script_publication_cleanup; cntools_wallet_material_cleanup; cntools_wallet_create_cleanup; cntools_transaction_cleanup; rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
fail() { printf 'FAIL: %s\n' "$*" >&2; tail -15 "${TEST_ROOT}/log" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
for lib in number wallet wallet-material wallet-key wallet-create wallet-query key-crypto wallet-protection transaction drep-id drep-key drep-query drep-script multisig-wallet backup; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
REAL_LN="$(type -P ln)"
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- ]] || args+=("${a}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  ln() { [[ "${1:-}" != -T ]] || shift; [[ ! -e "${3}" && ! -L "${3}" ]] || return 1; "${REAL_LN}" "$@"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=offline
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"; mkdir -m700 "${CNTOOLS_WALLET_DIR}"
CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey
CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey
CNTOOLS_WALLET_PAY_ADDR_FILENAME=payment.addr CNTOOLS_WALLET_STAKE_ADDR_FILENAME=reward.addr CNTOOLS_WALLET_BASE_ADDR_FILENAME=base.addr
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
CNTOOLS_WALLET_PAY_CRED_FILENAME=payment.cred CNTOOLS_WALLET_STAKE_CRED_FILENAME=stake.cred
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path CNTOOLS_WALLET_DREP_ID_FILENAME=drep.id CNTOOLS_WALLET_DREP_SCRIPT_FILENAME=drep.script
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
pin="$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")"
[[ "${version}" == "${pin}" ]] || fail 'CLI must match the cnode deployment pin'

directory="${CNTOOLS_WALLET_DIR}/Shared"; mkdir "${directory}"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${directory}/payment.skey" --verification-key-file "${directory}/payment.vkey"
before="$(cksum "${directory}/payment.skey")"
for participant in Alice Bob Carol; do
  pdir="${CNTOOLS_WALLET_DIR}/${participant}"; mkdir "${pdir}"
  "${CNTOOLS_CLI}" latest governance drep key-gen --signing-key-file "${pdir}/drep.skey" --verification-key-file "${pdir}/drep.vkey"
  cntools_drep_script_vkey_hash_into hash "${pdir}/drep.vkey" || fail 'external public-key participant'
  expected="$("${CNTOOLS_CLI}" latest governance drep id --drep-verification-key-file "${pdir}/drep.vkey" --output-hex)"
  [[ "${hash}" == "${expected}" ]] || fail 'public-key hash mismatch'
  cntools_drep_script_participant_add "${hash}" "${participant}" || fail 'participant add'
done
if cntools_drep_script_participant_add "${hash}" Duplicate; then fail 'duplicate accepted'; fi
if cntools_drep_script_create "${directory}" 0 || cntools_drep_script_create "${directory}" 4; then fail 'invalid threshold accepted'; fi
cntools_drep_script_create "${directory}" 2 || fail 'create script DRep'
[[ "$(cksum "${directory}/payment.skey")" == "${before}" ]] || fail 'payment signing key changed'
[[ ! -e "${directory}/drep.skey" && ! -e "${directory}/drep.vkey" ]] || fail 'participant private/public keys copied'
jq -e '.type == "atLeast" and .required == 2 and (.scripts|length==3) and
  ([.scripts[].keyHash] == ([.scripts[].keyHash]|sort))' "${directory}/drep.script" >/dev/null || fail 'deterministic threshold'
cntools_drep_key_inspect "${directory}" || fail 'verified script inspection'
id="${CNTOOLS_DREP_KEY_ID}" hash="${CNTOOLS_DREP_KEY_HASH}"
[[ "${CNTOOLS_DREP_KEY_KIND}:${CNTOOLS_DREP_KEY_VERIFIED}:${CNTOOLS_DREP_SCRIPT_THRESHOLD}:${CNTOOLS_DREP_SCRIPT_PARTICIPANTS}" == script:Y:2:3 ]] || fail 'script identity/summary'
[[ "${hash}" == "$("${CNTOOLS_CLI}" hash script --script-file "${directory}/drep.script")" ]] || fail 'CLI script-hash mismatch'
# Published CIP-129 vector verifies the shared encoder independently of its
# decoder. Script payload/header is checked above against the CLI script hash.
cntools_drep_bech32_into known "22$(printf '00%.0s' {1..28})"
[[ "${known}" == drep1ygqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7vlc9n ]] || fail 'CIP-129 published vector'
for file in drep.script drep.id; do
  cntools_wallet_create_mode_into mode "${directory}/${file}"; [[ "${mode}" == 600 ]] || fail 'unsafe public-file mode'
  cntools_backup_public_file wallets "${file}" || fail 'public backup excludes script identity'
done
if cntools_drep_script_create "${directory}" 1; then fail 'existing identity overwritten'; fi
rm "${directory}/drep.id"
cntools_drep_key_inspect "${directory}" || fail 'missing-ID regeneration'
[[ "${CNTOOLS_DREP_KEY_ID}" == "${id}" ]] || fail 'regenerated ID changed'
(
  CNTOOLS_CLI=''
  cntools_drep_key_inspect "${directory}" || fail 'cached offline script inspection'
  [[ "${CNTOOLS_DREP_KEY_VERIFIED}" == N && "${CNTOOLS_DREP_KEY_ID}" == "${id}" ]] || fail 'offline script verification overstated'
  rm "${directory}/drep.id"
  if cntools_drep_key_inspect "${directory}"; then fail 'missing offline ID accepted'; fi
)
printf '%s\n' "${id}" > "${directory}/drep.id"
cntools_drep_bech32_into wrong "23$(printf 'ff%.0s' {1..28})"
printf '%s\n' "${wrong}" > "${directory}/drep.id"
if cntools_drep_key_inspect "${directory}"; then fail 'stale script ID accepted'; fi
[[ "$(< "${directory}/drep.id")" == "${wrong}" ]] || fail 'stale ID overwritten'
printf '%s\n' "${id}" > "${directory}/drep.id"
cp "${CNTOOLS_WALLET_DIR}/Alice/drep.vkey" "${directory}/drep.vkey"
if cntools_drep_key_inspect "${directory}"; then fail 'mixed key/script identity accepted'; fi
rm "${directory}/drep.vkey"

# Fail the second link: remove our first link, preserve a racing replacement.
(
  directory="${CNTOOLS_WALLET_DIR}/Rollback"; mkdir "${directory}"
  ln() {
    [[ "${1:-}" != -T ]] || shift
    if [[ "${3}" == */drep.script ]]; then
      rm "${directory}/drep.id"; printf foreign > "${directory}/drep.id"; return 1
    fi
    "${REAL_LN}" "$@"
  }
  if cntools_drep_script_create "${directory}" 2; then fail 'partial publication accepted'; fi
  [[ ! -e "${directory}/drep.script" && "$(< "${directory}/drep.id")" == foreign ]] || fail 'foreign replacement lost'
)
(
  directory="${CNTOOLS_WALLET_DIR}/Partial"; mkdir "${directory}"
  ln() { [[ "${1:-}" != -T ]] || shift; [[ "${3}" != */drep.script ]] || return 1; "${REAL_LN}" "$@"; }
  if cntools_drep_script_create "${directory}" 2; then fail 'partial publication accepted'; fi
  [[ ! -e "${directory}/drep.script" && ! -e "${directory}/drep.id" ]] || fail 'rollback left partial identity'
)
(
  directory="${CNTOOLS_WALLET_DIR}/Linked"; mkdir "${directory}"; ln -s "${TEST_ROOT}/outside" "${directory}/drep.script"
  if cntools_drep_script_create "${directory}" 2; then fail 'symlink target accepted'; fi
  [[ -L "${directory}/drep.script" ]] || fail 'symlink removed'
)

# EXIT cleanup at either publication boundary also handles interruption. The
# signal targets only the isolated test subshell, never the runner or a wallet.
for stop_at in drep.script drep.id; do
  directory="${CNTOOLS_WALLET_DIR}/Interrupted-${stop_at}"; mkdir "${directory}"
  status=0
  (
    trap 'cntools_drep_script_publication_cleanup; cntools_wallet_create_cleanup' EXIT
    trap 'exit 143' TERM
    ln() {
      [[ "${1:-}" != -T ]] || shift
      "${REAL_LN}" "$@" || return 1
      [[ "${3##*/}" != "${stop_at}" ]] || kill -TERM "${BASHPID}"
    }
    cntools_drep_script_create "${directory}" 2
  ) || status=$?
  [[ "${status}" == 143 && ! -e "${directory}/drep.script" && ! -e "${directory}/drep.id" ]] || fail 'interrupted publication left identity files'
done

(
  directory="${CNTOOLS_WALLET_DIR}/Protected"; mkdir "${directory}"
  # Public augmentation must not require decrypting or even reading private
  # key contents. The existing encrypted file is deliberately only a fixture.
  printf encrypted-fixture > "${directory}/payment.skey.gpg"; chmod 0400 "${directory}/payment.skey.gpg"
  protected_before="$(cksum "${directory}/payment.skey.gpg")"
  cntools_drep_script_create "${directory}" 2 || fail 'public augmentation of protected wallet'
  [[ "$(cksum "${directory}/payment.skey.gpg")" == "${protected_before}" && ! -e "${directory}/payment.skey" ]] || fail 'encrypted key changed'
)
(
  directory="${CNTOOLS_WALLET_DIR}/Shared"
  cp "${directory}/drep.script" "${TEST_ROOT}/script-before"
  printf '{"type":"atLeast","required":2,"scripts":[]}' > "${directory}/drep.script"
  if cntools_drep_key_inspect "${directory}"; then fail 'invalid script accepted'; fi
  cmp "${directory}/drep.script" <(printf '{"type":"atLeast","required":2,"scripts":[]}') || fail 'invalid script overwritten'
  cp "${TEST_ROOT}/script-before" "${directory}/drep.script"
  CNTOOLS_WALLET_DREP_SCRIPT_FILENAME=payment.skey
  if cntools_drep_script_preflight "${directory}"; then fail 'configured filename collision accepted'; fi
)
cntools_wallet_material_cleanup; cntools_wallet_create_cleanup; cntools_transaction_cleanup
if compgen -G "${CNTOOLS_WALLET_DIR}/.cntools-*" >/dev/null; then fail 'staging left behind'; fi
printf 'CNTools script DRep tests passed (cardano-cli %s).\n' "${version}"
