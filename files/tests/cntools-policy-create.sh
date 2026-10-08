#!/usr/bin/env bash
# Filesystem/UI contracts; optional real cnode CLI deployment pin (no node).
# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-policy-create.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet wallet-query wallet-key transaction table policy-files policy policy-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
. "${CNTOOLS_ROOT}/core/health.sh"
. "${CNTOOLS_ROOT}/lib/backup.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
CNTOOLS_ASSET_DIR="${TEST_ROOT}/assets" CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_MODE=offline
CNTOOLS_NETWORK=preview CNTOOLS_TIMEZONE=UTC CNTOOLS_CLI="${1:-${BASH}}" CNTOOLS_LOG="${TEST_ROOT}/log"
TEST_FAULT='' TEST_RACE=N
expiry='' date=''
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${CNTOOLS_LOG}"; }
cntools_run_command() {
  local mask="$1" destination=''; shift 2
  (( ${#mask} == $# )) || fail 'command audit mask mismatch'
  printf '%q ' "$@" >> "${CNTOOLS_LOG}"; printf '\n' >> "${CNTOOLS_LOG}"
  if [[ "${TEST_RACE}" == Y && "$1" == mv ]]; then
    destination="${!#}"
    mkdir -m 700 -- "${destination}"; printf 'existing\n' > "${destination}/sentinel"
  fi
  "$@"
}
REAL_MV="$(type -P mv)"
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local argument=''; local -a args=(); for argument in "$@"; do [[ "${argument}" == -- ]] || args+=("${argument}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  # Only the atomic GNU publication boundary is doubled on macOS.
  mv() {
    if [[ "$1" == --help ]]; then printf '%s\n' '--no-target-directory --no-clobber'; return 0; fi
    shift 3
    [[ ! -e "$2" && ! -L "$2" ]] || return 0
    "${REAL_MV}" -n "$1" "$2"
  }
fi
MOCK_CLI=N
if (( $# == 0 )); then MOCK_CLI=Y; else
  version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
  eq "${version}" "$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")" 'cnode deployment pin'
fi
cntools_run_command_timeout() {
  local mask="$2" skey='' vkey='' script='' argument='' previous=''
  shift 3
  (( ${#mask} == $# )) || fail 'timeout audit mask mismatch'
  printf '%q ' "$@" >> "${CNTOOLS_LOG}"; printf '\n' >> "${CNTOOLS_LOG}"
  [[ "$*" != *query* ]] || fail 'policy queried a node'
  [[ "${TEST_FAULT}" != cli ]] || { printf 'injected CLI failure\n' >&2; return 17; }
  for argument in "$@"; do
    case "${previous}" in
      --signing-key-file) skey="${argument}" ;;
      --verification-key-file) vkey="${argument}" ;;
      --script-file) script="${argument}" ;;
    esac
    previous="${argument}"
  done
  if [[ "${TEST_FAULT}" == mismatch && "$*" == *'key verification-key'* ]]; then
    jq -n --arg hex "5820$(printf 'bb%.0s' {1..32})" '{type:"PaymentVerificationKeyShelley_ed25519",cborHex:$hex}' > "${vkey}"; return 0
  fi
  if [[ "${TEST_FAULT}" == hash && "$*" == *'hash script'* ]]; then printf 'bad hash\n'; return 0; fi
  if [[ "${TEST_FAULT}" == id-mismatch && "$*" == *'hash script'* ]]; then printf 'ee%.0s' {1..28}; printf '\n'; return 0; fi
  if [[ "${TEST_FAULT}" == envelope && "$*" == *'address key-gen'* ]]; then
    printf '{}\n' > "${skey}"; printf '{}\n' > "${vkey}"; return 0
  fi
  if [[ "${MOCK_CLI}" == N ]]; then "$@"; return $?; fi
  case "$*" in
    *'address key-gen'*)
      jq -n --arg hex "5820$(printf 'aa%.0s' {1..32})" '{type:"PaymentSigningKeyShelley_ed25519",cborHex:$hex}' > "${skey}"
      jq -n --arg hex "5820$(printf 'aa%.0s' {1..32})" '{type:"PaymentVerificationKeyShelley_ed25519",cborHex:$hex}' > "${vkey}" ;;
    *'key verification-key'*)
      jq '{type:"PaymentVerificationKeyShelley_ed25519",cborHex:.cborHex}' "${skey}" > "${vkey}" ;;
    *'address key-hash'*) printf 'ab%.0s' {1..28}; printf '\n' ;;
    *'transaction policyid'*|*'hash script'*)
      jq -e 'type == "object"' "${script}" >/dev/null
      printf 'cd%.0s' {1..28}; printf '\n' ;;
    *) fail "unexpected CLI command: $*" ;;
  esac
}
cntools_policy_preflight Unlimited || fail "preflight: ${CNTOOLS_POLICY_ERROR}"
[[ ! -e "${CNTOOLS_ASSET_DIR}" ]] || fail 'preflight created root'
cntools_policy_expiry_into expiry '' || fail 'blank TTL default'
eq "${expiry}" 0
cntools_policy_create Unlimited "${expiry}" || fail "create: ${CNTOOLS_POLICY_ERROR}"
directory="${CNTOOLS_POLICY_DIRECTORY}" id="${CNTOOLS_POLICY_ID}"
eq "$(find "${directory}" -type f | wc -l | tr -d ' ')" 4 'complete artifacts'
eq "$(stat -c '%a' "${directory}" 2>/dev/null || stat -f '%Lp' "${directory}")" 700 'private directory'
for file in "${directory}"/*; do eq "$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}")" 600 'private artifacts'; done
jq -e '.type == "sig" and (.keyHash|test("^[a-f0-9]{56}$"))' "${directory}/policy.script" >/dev/null || fail 'unlimited policy'
eq "$(< "${directory}/policy.id")" "${id}" 'saved policy ID'
[[ "${id}" =~ ^[a-f0-9]{56}$ ]] || fail 'invalid ID'
if [[ "${MOCK_CLI}" == N ]]; then
  eq "$("${CNTOOLS_CLI}" latest transaction policyid --script-file "${directory}/policy.script")" "${id}" 'real ledger policy hash'
fi
if grep -Eq '5820[a-f0-9]{64}' "${CNTOOLS_LOG}"; then fail 'key bytes logged'; fi
before="$(cksum "${directory}"/*)"
if cntools_policy_create Unlimited 0; then fail 'existing folder overwritten'; fi
eq "$(cksum "${directory}"/*)" "${before}" 'existing files preserved'
for name in '' .hidden '../escape' 'bad name' 'a/b'; do if cntools_policy_create "${name}" 0; then fail 'invalid name accepted'; fi; done
for ttl in '-1' '1.5' '1,00' '10000000000' '1e3'; do if cntools_policy_expiry_into expiry "${ttl}"; then fail 'invalid duration accepted'; fi; done
cntools_policy_expiry_into expiry '3,600' || fail 'comma TTL rejected'
reviewed="${expiry}"
cntools_slot_datetime_into date "${expiry}" || fail 'expiry date'
[[ "${date}" == *UTC* ]] || fail 'timezone missing'
cntools_policy_create Expiring "${reviewed}" || fail "expiring create: ${CNTOOLS_POLICY_ERROR}"
jq -e --argjson slot "${reviewed}" '.type == "all" and .scripts[0] == {type:"before",slot:$slot} and .scripts[1].type == "sig"' "${CNTOOLS_POLICY_DIRECTORY}/policy.script" >/dev/null || fail 'reviewed expiry changed'
if cntools_policy_create Expired 1; then fail 'already expired policy published'; fi
ln -s "${directory}" "${CNTOOLS_ASSET_DIR}/Linked"
if cntools_policy_create Linked 0; then fail 'symlink destination accepted'; fi
for fault in cli mismatch hash id-mismatch envelope; do
  TEST_FAULT="${fault}"
  if cntools_policy_create "Failure_${fault}" 0; then fail "fault ${fault} published"; fi
  [[ ! -e "${CNTOOLS_ASSET_DIR}/Failure_${fault}" && -n "${CNTOOLS_POLICY_ERROR}" ]] || fail 'failure lacks diagnostic/published target'
  cntools_policy_files_cleanup; cntools_transaction_cleanup
done
TEST_FAULT=''
grep -F 'injected CLI failure' "${CNTOOLS_LOG}" >/dev/null || fail 'CLI diagnostic not logged'
TEST_RACE=Y
if cntools_policy_create Race 0; then fail 'publication race overwrote destination'; fi
eq "$(< "${CNTOOLS_ASSET_DIR}/Race/sentinel")" existing 'racing destination preserved'
TEST_RACE=N
cntools_policy_files_cleanup; cntools_transaction_cleanup
[[ -e "${directory}/policy.skey" ]] || fail 'cleanup removed published policy'
[[ -z "$(find "${CNTOOLS_ASSET_DIR}" -name '.cntools-policy-*' -print)" ]] || fail 'staging leftovers'
chmod 0770 "${CNTOOLS_ASSET_DIR}"
if cntools_policy_create Unsafe 0; then fail 'group writable root accepted'; fi
chmod 0700 "${CNTOOLS_ASSET_DIR}"
(
  CNTOOLS_ASSET_DIR="${TEST_ROOT}/linked-root"
  ln -s "${TEST_ROOT}/assets" "${CNTOOLS_ASSET_DIR}"
  if cntools_policy_create LinkedRoot 0; then fail 'symlink root accepted'; fi
  CNTOOLS_ASSET_DIR="${TEST_ROOT}/assets" CNTOOLS_CLI=''
  if cntools_policy_preflight NoCLI; then fail 'missing CLI accepted'; fi
)
(
  checks=0
  cntools_policy_expiry_valid() { checks=$((checks+1)); ((checks == 1)); }
  if cntools_policy_create ExpiredDuringCreation 500; then fail 'expiry during creation accepted'; fi
  [[ ! -e "${CNTOOLS_ASSET_DIR}/ExpiredDuringCreation" ]] || fail 'expired policy published'
  cntools_policy_files_cleanup; cntools_transaction_cleanup
)
for mode in local light; do
  CNTOOLS_MODE="${mode}"
  cntools_policy_create "Mode_${mode}" 0 || fail "${mode} mode policy creation"
done
CNTOOLS_MODE=offline
CNTOOLS_POLICY_VKEY_FILENAME=custom.vkey CNTOOLS_POLICY_SKEY_FILENAME=secret-key CNTOOLS_POLICY_SCRIPT_FILENAME=custom.script CNTOOLS_POLICY_ID_FILENAME=custom.id
cntools_policy_create Custom 0 || fail 'configured filenames'
[[ -e "${CNTOOLS_POLICY_DIRECTORY}/secret-key" && -e "${CNTOOLS_POLICY_DIRECTORY}/custom.id" ]] || fail 'custom files missing'
cntools_backup_public_file assets custom.vkey || fail 'custom public key excluded from backup'
if cntools_backup_public_file assets secret-key; then fail 'custom signing key leaked to public backup'; fi
CNTOOLS_POLICY_SKEY_FILENAME=custom.id
if cntools_policy_create Collision 0; then fail 'filename collision accepted'; fi
if cntools_backup_public_file assets custom.id; then fail 'colliding secret leaked to public backup'; fi
CNTOOLS_POLICY_SKEY_FILENAME=custom.vkey.gpg
if cntools_policy_create Collision2 0; then fail 'encrypted filename collision accepted'; fi
CNTOOLS_POLICY_SKEY_FILENAME='../secret'
if cntools_policy_create Traversal 0; then fail 'unsafe filename accepted'; fi
CNTOOLS_POLICY_SKEY_FILENAME=secret-key CNTOOLS_POLICY_SCRIPT_FILENAME=bad.json
if cntools_policy_create BadExtension 0; then fail 'unsupported script extension accepted'; fi
unset CNTOOLS_POLICY_VKEY_FILENAME CNTOOLS_POLICY_SKEY_FILENAME CNTOOLS_POLICY_SCRIPT_FILENAME CNTOOLS_POLICY_ID_FILENAME

# Same-shell UI doubles: cancellation, retries, default review, spinner and errors.
cntools_ui_action_begin() { printf 'VIEW %s\n' "$1"; }
cntools_ui_render_status() { printf '%s %s\n' "$1" "$2"; }
cntools_ui_wait() { :; }
cntools_table_render() { while IFS= read -r line; do printf '%s\n' "${line}"; done; }
cntools_ui_input() {
  local result="$1" answer="${TEST_INPUTS[TEST_INPUT_INDEX]}"
  TEST_INPUT_INDEX=$((TEST_INPUT_INDEX+1))
  [[ "${answer}" != __cancel__ ]] || return 130
  printf -v "${result}" '%s' "${answer}"
}
cntools_ui_confirm() { eq "$2" false 'confirmation must default to No'; return "${TEST_CONFIRM}"; }
cntools_ui_spin_function() { printf 'SPIN %s\n' "$1"; shift; "$@"; }
TEST_INPUT_INDEX=0 TEST_CONFIRM=0
TEST_INPUTS=('bad name' UI '1.5' '')
cntools_policy_action_create > "${TEST_ROOT}/ui" || fail 'UI retries/defaults'
grep -F 'No expiry' "${TEST_ROOT}/ui" >/dev/null || fail 'UI default expiry not shown'
grep -F 'SPIN' "${TEST_ROOT}/ui" >/dev/null || fail 'UI missing spinner'
[[ -e "${CNTOOLS_ASSET_DIR}/UI/policy.skey" ]] || fail 'UI failed to publish'
TEST_INPUT_INDEX=0 TEST_CONFIRM=1 TEST_INPUTS=(Declined '')
CNTOOLS_ASSET_DIR="${TEST_ROOT}/declined-assets"
cntools_policy_action_create > "${TEST_ROOT}/ui" || fail 'decline failed'
[[ ! -e "${CNTOOLS_ASSET_DIR}" ]] || fail 'decline created asset root'
CNTOOLS_ASSET_DIR="${TEST_ROOT}/assets"
TEST_INPUT_INDEX=0 TEST_INPUTS=(__cancel__)
cntools_policy_action_create > "${TEST_ROOT}/ui" || fail 'input escape treated as failure'
TEST_INPUT_INDEX=0 TEST_INPUTS=(CancelExpiry __cancel__)
cntools_policy_action_create > "${TEST_ROOT}/ui" || fail 'expiry escape treated as failure'
TEST_INPUT_INDEX=0 TEST_CONFIRM=130 TEST_INPUTS=(CancelConfirm '')
cntools_policy_action_create > "${TEST_ROOT}/ui" || fail 'confirmation escape treated as failure'
TEST_INPUT_INDEX=0 TEST_CONFIRM=0 TEST_INPUTS=(UIFault '') TEST_FAULT=cli
if cntools_policy_action_create > "${TEST_ROOT}/ui"; then fail 'UI hides CLI failure'; fi
grep -F 'injected CLI failure' "${TEST_ROOT}/ui" >/dev/null || fail 'UI loses command diagnostic'
cntools_policy_files_cleanup; cntools_transaction_cleanup
printf 'CNTools native policy creation tests passed (real pinned CLI: %s).\n' "$([[ "${MOCK_CLI}" == N ]] && printf yes || printf no)"
