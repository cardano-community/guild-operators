#!/usr/bin/env bash
# Deterministic pool write/protection safety tests; optional real deployment pin.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-pool-manage.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
GPG_TEST_ROOT="$(mktemp -d /tmp/cntools-gpg.XXXXXX)"
trap 'gpgconf --homedir "${GPG_TEST_ROOT}" --kill gpg-agent >/dev/null 2>&1 || true; chmod -R u+rwX "${TEST_ROOT}" 2>/dev/null || true; rm -rf -- "${TEST_ROOT}" "${GPG_TEST_ROOT}"' EXIT
for lib in number wallet wallet-query transaction pool-id table pool pool-files pool-key wallet-hardware pool-create key-crypto pool-lock pool-protection pool-manage-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { tail -8 "${TEST_ROOT}/log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
CNTOOLS_POOL_DIR="${TEST_ROOT}/pools" CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_MODE=offline CNTOOLS_NETWORK=preview
CNTOOLS_CLI="${1:-${BASH}}" CNTOOLS_ENABLE_CHATTR=false CNTOOLS_LOG="${TEST_ROOT}/log"
export GNUPGHOME="${GPG_TEST_ROOT}"
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command() { local mask="$1"; shift 2; (( ${#mask} == $# )) || fail 'command audit mask mismatch'; "$@"; }
cntools_run_command_timeout() { local mask="$2"; shift 3; (( ${#mask} == $# )) || fail 'timeout audit mask mismatch'; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_MV="$(type -P mv)" REAL_LN="$(type -P ln)"
  chmod() { local arg=""; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  # Publication contract double only on macOS; Linux CI uses real GNU mv.
  mv() { if [[ "$1" == --help ]]; then printf '%s\n' '--no-target-directory --no-clobber'; else shift 3; [[ ! -e "$2" && ! -L "$2" ]] || return 0; "${REAL_MV}" -n "$1" "$2"; fi; }
  ln() { if [[ "${1:-}" == -T ]]; then shift; [[ ! -d "${3}" ]] || return 1; fi; "${REAL_LN}" "$@"; }
fi
if (( $# == 0 )); then
  # Only key generation/derivation is doubled; file safety and GPG are real.
  hex="$(printf 'ab%.0s' {1..28})"; cntools_pool_id_into fixture_id hex "${hex}"
  cntools_run_command_timeout() {
    local mask="$2"
    shift 3
    (( ${#mask} == $# )) || fail 'timeout audit mask mismatch'
    if [[ "$1" == "${CNTOOLS_CLI}" ]]; then
      local argument="" previous="" skey="" vkey="" counter="" source="" role=cold
      [[ "$*" != *key-gen-KES* ]] || role=kes
      [[ "$*" != *key-gen-VRF* ]] || role=vrf
      for argument in "$@"; do
        case "${previous}" in
          --cold-signing-key-file|--signing-key-file) skey="${argument}" ;;
          --cold-verification-key-file|--verification-key-file) vkey="${argument}" ;;
          --operational-certificate-issue-counter-file) counter="${argument}" ;;
        esac
        previous="${argument}"
      done
      if [[ "$*" == *'stake-pool id'* ]]; then printf '%s\n' "${fixture_id}"; return 0; fi
      if [[ "$*" == *'key verification-key'* ]]; then
        case "$(jq -r '.type' "${skey}")" in Kes*) role=kes ;; Vrf*) role=vrf ;; esac
      fi
      local sktype=StakePoolSigningKey_ed25519 vktype=StakePoolVerificationKey_ed25519 skhex=""
      skhex="5820$(printf 'aa%.0s' {1..32})"
      case "${role}" in kes) sktype='KesSigningKey_ed25519_kes_2^6'; vktype='KesVerificationKey_ed25519_kes_2^6'; skhex="590260$(printf 'aa%.0s' {1..608})" ;;
        vrf) sktype=VrfSigningKey_PraosVRF; vktype=VrfVerificationKey_PraosVRF; skhex="5840$(printf 'aa%.0s' {1..64})" ;; esac
      [[ -z "${vkey}" ]] || jq -n --arg type "${vktype}" --arg hex "5820$(printf 'aa%.0s' {1..32})" '{type:$type,cborHex:$hex}' > "${vkey}"
      if [[ "$*" != *'key verification-key'* && -n "${skey}" ]]; then jq -n --arg type "${sktype}" --arg hex "${skhex}" '{type:$type,cborHex:$hex}' > "${skey}"; fi
      [[ -z "${counter}" ]] || jq -n --arg hex "82005820$(printf 'aa%.0s' {1..32})" '{type:"NodeOperationalCertificateIssueCounter",cborHex:$hex}' > "${counter}"
      return 0
    fi
    printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"
    "$@"
  }
else
  version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
  eq "${version}" "$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")" 'cnode deployment CLI pin'
fi
cntools_pool_create NewPool || fail "create: ${CNTOOLS_POOL_WRITE_ERROR}"
directory="${CNTOOLS_POOL_WRITTEN_DIRECTORY}" id="${CNTOOLS_POOL_WRITTEN_ID}"
eq "$(find "${directory}" -type f | wc -l | tr -d ' ')" 9 'complete new artifacts'
[[ ! -e "${directory}/op.cert" && ! -e "${directory}/kes.start" ]] || fail 'new pool pretends to have an active KES period'
eq "$(stat -c '%a' "${directory}" 2>/dev/null || stat -f '%Lp' "${directory}")" 700 'private pool directory'
for file in "${directory}"/*; do eq "$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}")" 600 'private staged artifact'; done
if cntools_pool_create NewPool; then fail 'existing pool overwritten'; fi
for name in '' '../escape' '.hidden' 'bad name' 'a/b'; do if cntools_pool_create "${name}"; then fail 'invalid pool name accepted'; fi; done
# Validate preservation of a real certificate and advanced issue counter.
if (( $# > 0 )); then
  "${CNTOOLS_CLI}" latest node issue-op-cert --kes-verification-key-file "${directory}/hot.vkey" \
    --cold-signing-key-file "${directory}/cold.skey" --operational-certificate-issue-counter-file "${directory}/cold.counter" \
    --kes-period 0 --out-file "${directory}/op.cert"
else
  jq -n --arg hex "82845820$(printf 'aa%.0s' {1..32})00005840$(printf 'aa%.0s' {1..64})5820$(printf 'aa%.0s' {1..32})" \
    '{type:"NodeOperationalCertificate",cborHex:$hex}' > "${directory}/op.cert"
fi
before="$(cksum "${directory}"/*)"
cntools_pool_import_directory CopyPool "${directory}" || fail "import: ${CNTOOLS_POOL_WRITE_ERROR}"
eq "${CNTOOLS_POOL_WRITTEN_ID}" "${id}" 'import identity'
eq "$(cksum "${directory}"/*)" "${before}" 'source unchanged'
cmp -s "${directory}/cold.counter" "${CNTOOLS_POOL_WRITTEN_DIRECTORY}/cold.counter" || fail 'counter reset by import'
cmp -s "${directory}/op.cert" "${CNTOOLS_POOL_WRITTEN_DIRECTORY}/op.cert" || fail 'certificate changed by import'
mkdir -m 700 "${TEST_ROOT}/bad-certificate"
cp "${directory}"/* "${TEST_ROOT}/bad-certificate/"
jq '.cborHex += "00"' "${directory}/op.cert" > "${TEST_ROOT}/bad-certificate/op.cert"
if cntools_pool_import_directory BadCertificate "${TEST_ROOT}/bad-certificate"; then fail 'malformed certificate imported'; fi
cntools_pool_files_cleanup
# Missing public artifacts are regenerated only in the destination staging.
mkdir -m 700 "${TEST_ROOT}/minimal"
cp "${directory}/cold.skey" "${TEST_ROOT}/minimal/cold.skey"
cntools_pool_import_directory Minimal "${TEST_ROOT}/minimal" || fail 'private-key-only import'
[[ -e "${CNTOOLS_POOL_WRITTEN_DIRECTORY}/cold.vkey" && ! -e "${TEST_ROOT}/minimal/cold.vkey" ]] || fail 'source mutated during public derivation'
ln -s "${directory}/cold.skey" "${TEST_ROOT}/minimal/link"
if cntools_pool_import_directory Linked "${TEST_ROOT}/minimal"; then fail 'linked source file accepted'; fi
[[ ! -e "${CNTOOLS_POOL_DIR}/Linked" ]] || fail 'partial linked import published'
cntools_pool_files_cleanup

# Hardware export contract double: no cold private material ever leaves a device.
(
  original_timeout="$(declare -f cntools_run_command_timeout)"
  eval "${original_timeout/cntools_run_command_timeout/test_original_timeout}"
  cntools_wallet_hardware_require() { CNTOOLS_WALLET_HARDWARE_BIN=/test/hardware; CNTOOLS_WALLET_HARDWARE_TIMEOUT=10; }
  cntools_wallet_hardware_device_check() { return 0; }
  cntools_run_command_timeout() {
    [[ "$4" == /test/hardware ]] || { test_original_timeout "$@"; return $?; }
    local mask="$2" arg="" previous="" path="" hws="" vkey="" counter=""
    shift 3; (( ${#mask} == $# )) || fail 'hardware audit mask mismatch'
    for arg in "$@"; do
      case "${previous}" in --path) path="${arg}" ;; --hw-signing-file) hws="${arg}" ;; --cold-verification-key-file) vkey="${arg}" ;; --operational-certificate-issue-counter-file) counter="${arg}" ;; esac
      previous="${arg}"
    done
    eq "${path}" '1853H/1815H/0H/7H' 'hardware cold path'
    cp "${directory}/cold.vkey" "${vkey}"
    jq -n --arg path "${path}" --arg hex "5840$(jq -r '.cborHex[4:]' "${vkey}")$(printf 'bb%.0s' {1..32})" \
      '{type:"StakePoolHWSigningFile_ed25519",path:$path,cborXPubKeyHex:$hex}' > "${hws}"
    jq -n --arg hex "82005820$(jq -r '.cborHex[4:]' "${vkey}")" \
      '{type:"NodeOperationalCertificateIssueCounter",cborHex:$hex}' > "${counter}"
  }
  cntools_pool_import_hardware HardwarePool 7 || fail "hardware import: ${CNTOOLS_POOL_WRITE_ERROR}"
  hardware="${CNTOOLS_POOL_WRITTEN_DIRECTORY}"
  [[ -e "${hardware}/cold.hwsfile" && ! -e "${hardware}/cold.skey" && ! -e "${hardware}/op.cert" ]] || fail 'hardware cold key exposure'
  cntools_pool_protect "${hardware}" encrypt '' || fail 'hardware lock without password'
  cntools_pool_protect "${hardware}" decrypt '' || fail 'hardware unlock without password'
  jq '.path="1852H/1815H/0H/0/0"' "${hardware}/cold.hwsfile" > "${TEST_ROOT}/bad-hardware"
  cp "${TEST_ROOT}/bad-hardware" "${hardware}/cold.hwsfile"
  if cntools_pool_hardware_pair_validate "${hardware}"; then fail 'unsupported hardware cold path accepted'; fi
  cntools_pool_protection_cleanup
)

# Cancel/error before confirmation must never reach a write callback.
(
  cntools_ui_action_begin() { :; }; cntools_ui_render_status() { :; }
  cntools_table_render() { while IFS= read -r _; do :; done; }
  cntools_ui_input() { printf -v "$1" '%s' CancelledPool; }
  cntools_ui_spin_function() { fail 'cancelled pool UI mutated files'; }
  cntools_ui_confirm() { return 1; }
  cntools_pool_action_new || fail 'declined creation reported error'
  [[ ! -e "${CNTOOLS_POOL_DIR}/CancelledPool" ]] || fail 'declined pool created'
  cntools_ui_confirm() { return 2; }
  status=0; cntools_pool_action_new || status=$?
  eq "${status}" 2 'UI error preserved'
  cntools_ui_choose() { return 1; }
  cntools_pool_action_import || fail 'cancelled import reported error'
)
(
  CNTOOLS_POOL_COLD_VKEY_FILENAME=hot.vkey
  if cntools_pool_create Collision; then fail 'filename collision'; fi
)
(
  cntools_pool_cli() { cntools_pool_write_error 'Injected CLI failure'; }
  if cntools_pool_create Broken; then fail 'failed generation succeeded'; fi
  [[ ! -e "${CNTOOLS_POOL_DIR}/Broken" ]] || fail 'partial pool published'
  cntools_pool_files_cleanup
)
# Publication races do not overwrite another user's destination.
cntools_pool_stage_into prepared
mkdir "${CNTOOLS_POOL_DIR}/Race"
if cntools_pool_stage_publish "${prepared}" Race; then fail 'race destination overwritten'; fi
cntools_pool_files_cleanup

if ! type -P gpg >/dev/null && ! type -P gpg2 >/dev/null; then
  printf 'SKIP: real GPG protection checks (GnuPG absent)\n'
else
  password='pool-test-password-DO-NOT-LOG'
  cold_original="$(cksum "${directory}/cold.skey" | cut -d ' ' -f1-2)"
  runtime_original="$(cksum "${directory}/hot.skey" "${directory}/vrf.skey")"
  if cntools_pool_protect "${directory}" encrypt short; then fail 'short encryption password'; fi
  cntools_pool_protection_cleanup
  cntools_pool_protect "${directory}" encrypt "${password}" || fail "encrypt: ${CNTOOLS_POOL_WRITE_ERROR}"
  [[ -f "${directory}/cold.skey.gpg" && ! -e "${directory}/cold.skey" ]] || fail 'encrypted publication'
  eq "$(cksum "${directory}/hot.skey" "${directory}/vrf.skey")" "${runtime_original}" 'node runtime keys unchanged'
  encrypted_original="$(cksum "${directory}/cold.skey.gpg")"
  if cntools_pool_protect "${directory}" decrypt wrong; then fail 'wrong password accepted'; fi
  cntools_pool_protection_cleanup
  eq "$(cksum "${directory}/cold.skey.gpg")" "${encrypted_original}" 'wrong-password encrypted source retained'
  cntools_pool_protect "${directory}" decrypt "${password}" || fail "decrypt: ${CNTOOLS_POOL_WRITE_ERROR}"
  eq "$(cksum "${directory}/cold.skey" | cut -d ' ' -f1-2)" "${cold_original}" 'plaintext preserved exactly'
  [[ ! -e "${directory}/cold.skey.gpg" ]] || fail 'encrypted source not retired'
  # Older short passphrases remain decryptable.
  cntools_pool_temp_into legacy "${directory}"; cntools_pool_temp_into errors "${directory}"
  binary="$(type -P gpg || type -P gpg2)"
  cntools_key_crypto_run "${binary}" encrypt "${directory}/cold.skey" "${legacy}" old "${errors}"
  ln "${legacy}" "${directory}/cold.skey.gpg"; rm "${directory}/cold.skey"
  cntools_pool_files_cleanup_temps
  cntools_pool_protect "${directory}" decrypt old || fail 'short legacy password'
  # Failure to retire a source cannot discard it or leave a new mixed pair.
  (
    cntools_run_command() { if [[ "$*" == *"rm -f -- ${directory}/cold.skey"* ]]; then return 1; fi; shift 2; "$@"; }
    if cntools_pool_protect "${directory}" encrypt "${password}"; then fail 'retirement failure swallowed'; fi
    [[ -f "${directory}/cold.skey" && ! -e "${directory}/cold.skey.gpg" ]] || fail 'retirement rollback'
    cntools_pool_protection_cleanup
  )
  # A directory racing into the destination must never receive the new key.
  (
    original_ln="$(declare -f ln 2>/dev/null || true)"
    ln() {
      if [[ "${*: -1}" == "${directory}/cold.skey.gpg" ]]; then
        mkdir "${directory}/cold.skey.gpg"
      fi
      if [[ -n "${original_ln}" ]]; then
        local renamed="${original_ln/ln /test_original_ln }"
        eval "${renamed}"; test_original_ln "$@"
      else command ln "$@"; fi
    }
    if cntools_pool_protect "${directory}" encrypt "${password}"; then fail 'directory publication race accepted'; fi
    [[ -f "${directory}/cold.skey" && -d "${directory}/cold.skey.gpg" ]] || fail 'race lost original key'
    [[ -z "$(find "${directory}/cold.skey.gpg" -type f -print -quit)" ]] || fail 'key published inside racing directory'
    cntools_pool_protection_cleanup
    rmdir "${directory}/cold.skey.gpg"
  )
  [[ "$(< "${TEST_ROOT}/log")" != *"${password}"* ]] || fail 'password logged'
fi
# Interrupted publication: remove only our counterpart while an original exists.
cntools_pool_temp_into interrupted "${directory}"
printf 'test-counterpart' > "${interrupted}"
ln "${interrupted}" "${directory}/cold.skey.gpg"
cntools_pool_temp_into snapshot "${directory}"
cp "${directory}/cold.skey" "${snapshot}"
CNTOOLS_POOL_PROTECTION_SOURCES=("${directory}/cold.skey")
CNTOOLS_POOL_PROTECTION_TARGETS=("${directory}/cold.skey.gpg")
CNTOOLS_POOL_PROTECTION_STAGED=("${interrupted}")
CNTOOLS_POOL_PROTECTION_SNAPSHOTS=("${snapshot}")
CNTOOLS_POOL_PROTECTION_MODES=(600)
cntools_pool_protection_cleanup
[[ -f "${directory}/cold.skey" && ! -e "${directory}/cold.skey.gpg" ]] || fail 'interrupted counterpart rollback'
# After retirement, cleanup must retain the final copy.
cntools_pool_temp_into interrupted "${directory}"
printf 'test-counterpart' > "${interrupted}"
ln "${interrupted}" "${directory}/retained-copy"
CNTOOLS_POOL_PROTECTION_SOURCES=("${directory}/already-retired")
CNTOOLS_POOL_PROTECTION_TARGETS=("${directory}/retained-copy")
CNTOOLS_POOL_PROTECTION_STAGED=("${interrupted}")
cntools_pool_protection_cleanup
[[ -f "${directory}/retained-copy" ]] || fail 'cleanup removed last copy'
rm "${directory}/retained-copy"
# Immutable locking is optional, and a partially successful lock is undone.
(
  CNTOOLS_ENABLE_CHATTR=true
  cntools_pool_chattr_prepare() { return 1; }
  cntools_pool_locks_apply "${directory}" encrypt || fail 'read-only fallback'
  [[ "${CNTOOLS_POOL_WRITE_WARNING}" == *'unavailable'* ]] || fail 'fallback not explained'
  cntools_pool_chattr_prepare() { return 0; }
  cntools_pool_chattr() {
    printf '%s %s\n' "$1" "${2##*/}" >> "${TEST_ROOT}/locks"
    [[ "$1" != +i || "$2" != "${directory}/hot.skey" ]]
  }
  cntools_pool_locks_apply "${directory}" encrypt || fail 'partial immutable fallback'
  [[ "${CNTOOLS_POOL_WRITE_WARNING}" == *'incomplete'* ]] || fail 'partial lock not explained'
  [[ "$(< "${TEST_ROOT}/locks")" == *'-i cold.skey'* ]] || fail 'partial immutable lock not undone'
  CNTOOLS_POOL_UNLOCKED=("${directory}/cold.skey")
  cntools_pool_locks_restore || fail 'original immutable lock restoration'
  (( ${#CNTOOLS_POOL_UNLOCKED[@]} == 0 )) || fail 'restored lock state not cleared'
)
cntools_pool_locks_apply "${directory}" decrypt
[[ -z "$(find "${CNTOOLS_POOL_DIR}" -name '.cntools-*' -print -quit)" ]] || fail 'private staging leftovers'
printf 'CNTools pool creation/import/protection tests passed%s.\n' "${version:+ (CLI ${version})}"
