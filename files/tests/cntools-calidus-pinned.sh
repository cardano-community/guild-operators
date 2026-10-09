#!/usr/bin/env bash
# Generated test keys only. No node/API access, registration or submission.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329,SC2015
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the cnode deployment-pinned CLI}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-calidus.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'cntools_calidus_publication_cleanup; cntools_pool_files_cleanup; cntools_transaction_cleanup; rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
for lib in number wallet wallet-key wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query transaction pool-id pool pool-files drep-id calidus-id pool-calidus backup; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; tail -10 "${TEST_ROOT}/log" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() { shift 3; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
REAL_LN="$(type -P ln)"
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- ]] || args+=("${a}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  ln() { [[ "${1:-}" != -T ]] || shift; [[ ! -e "${3}" && ! -L "${3}" ]] || return 1; "${REAL_LN}" "$@"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=offline
CNTOOLS_POOL_DIR="${TEST_ROOT}/pools"; mkdir -m700 "${CNTOOLS_POOL_DIR}"
CNTOOLS_POOL_CALIDUS_SKEY_FILENAME=calidus.skey CNTOOLS_POOL_CALIDUS_VKEY_FILENAME=calidus.vkey CNTOOLS_POOL_CALIDUS_ID_FILENAME=calidus.id
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
[[ "${version}" == "$(jq -er '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")" ]] || fail 'CLI must match cnode deployment pin'

# Independent published cardano-signer example, not an encoder round-trip.
jq -n '{type:"PaymentVerificationKeyShelley_ed25519",cborHex:"5820369b9aa06aa9389d6ba87b524846056c69b8b0221bdeb91bef814f1883cc86c3"}' > "${TEST_ROOT}/vector.vkey"
cntools_calidus_id_into vector "${TEST_ROOT}/vector.vkey" || fail 'vector derivation'
[[ "${vector}" == calidus1590nq56cdgkca3m82ga3mpyzm9un80qte26h7cvkjxgrc3chqexdf ]] || fail 'published identifier mismatch'
if cntools_drep_bech32_into vector "22$(printf '00%.0s' {1..28})" calidus; then fail 'non-Calidus prefix accepted'; fi

directory="${CNTOOLS_POOL_DIR}/Example"; mkdir -m700 "${directory}"
for file in cold.skey hot.skey vrf.skey; do printf existing > "${directory}/${file}"; done
before="$(cksum "${directory}/cold.skey" "${directory}/hot.skey" "${directory}/vrf.skey")"
cntools_calidus_inspect "${directory}" || fail 'empty identity inspection'
[[ "${CNTOOLS_CALIDUS_STATE}" == Missing ]] || fail 'missing state'
# Do not rely on the caller having a restrictive umask.
umask 022
cntools_calidus_prepare "${directory}" create || fail "create: ${CNTOOLS_POOL_WRITE_ERROR}"
umask 077
cntools_calidus_inspect "${directory}" || fail 'created identity inspection'
id="${CNTOOLS_CALIDUS_ID}"
[[ "${CNTOOLS_CALIDUS_STATE}" == Open && "$(< "${directory}/calidus.id")" == "${id}" ]] || fail 'created identity summary'
[[ "$(cksum "${directory}/cold.skey" "${directory}/hot.skey" "${directory}/vrf.skey")" == "${before}" ]] || fail 'node/cold keys changed'
for file in calidus.skey calidus.vkey calidus.id; do
  cntools_filesystem_mode_into mode "${directory}/${file}"; [[ "${mode}" == 600 ]] || fail 'unsafe artifact permissions'
done
if cntools_calidus_prepare "${directory}" create; then fail 'existing identity overwritten'; fi
mkdir -m700 "${CNTOOLS_POOL_DIR}/Imported"
cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/Imported" signing "${directory}/calidus.skey" || fail 'normal signing import'
[[ "$(< "${CNTOOLS_POOL_DIR}/Imported/calidus.id")" == "${id}" ]] || fail 'import identity changed'
[[ -f "${directory}/calidus.skey" ]] || fail 'import source removed'
mkdir -m700 "${CNTOOLS_POOL_DIR}/Watch"
cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/Watch" verification "${directory}/calidus.vkey" || fail 'watch-only import'
cntools_calidus_inspect "${CNTOOLS_POOL_DIR}/Watch" || fail 'watch-only inspection'
[[ "${CNTOOLS_CALIDUS_STATE}" == 'Public only' && ! -e "${CNTOOLS_POOL_DIR}/Watch/calidus.skey" ]] || fail 'watch-only created signing key'
cntools_backup_public_file pools calidus.vkey && cntools_backup_public_file pools calidus.id || fail 'public backup excludes Calidus identity'
if cntools_backup_public_file pools calidus.skey || cntools_backup_public_file pools calidus.skey.gpg; then fail 'private Calidus key in public backup'; fi

# Extended signing/verification envelopes from the pinned CLI are accepted;
# only copied public keys are normalized. The secret and its source stay intact.
"${CNTOOLS_CLI}" key generate-mnemonic --size 24 > "${TEST_ROOT}/mnemonic"
"${CNTOOLS_CLI}" key derive-from-mnemonic --payment-key-with-number 0 --account-number 0 \
  --mnemonic-from-file "${TEST_ROOT}/mnemonic" --signing-key-file "${TEST_ROOT}/extended.skey"
"${CNTOOLS_CLI}" key verification-key --signing-key-file "${TEST_ROOT}/extended.skey" --verification-key-file "${TEST_ROOT}/extended.vkey"
mkdir -m700 "${CNTOOLS_POOL_DIR}/Extended" "${CNTOOLS_POOL_DIR}/ExtendedWatch"
cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/Extended" signing "${TEST_ROOT}/extended.skey" || fail 'extended signing import'
cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/ExtendedWatch" verification "${TEST_ROOT}/extended.vkey" || fail 'extended verification import'
cmp -s "${TEST_ROOT}/extended.skey" "${CNTOOLS_POOL_DIR}/Extended/calidus.skey" || fail 'extended secret changed'
cmp -s "${CNTOOLS_POOL_DIR}/Extended/calidus.id" "${CNTOOLS_POOL_DIR}/ExtendedWatch/calidus.id" || fail 'extended identity mismatch'

rm "${directory}/calidus.vkey" "${directory}/calidus.id"
cntools_calidus_prepare "${directory}" repair || fail 'missing public artifacts repair'
[[ "$(< "${directory}/calidus.id")" == "${id}" ]] || fail 'repair changed identity'
before="$(cksum "${directory}/calidus.skey" "${directory}/calidus.vkey" "${directory}/calidus.id")"
cntools_calidus_prepare "${directory}" repair || fail 'complete identity repair'
[[ "$(cksum "${directory}/calidus.skey" "${directory}/calidus.vkey" "${directory}/calidus.id")" == "${before}" ]] || fail 'repair rewrote files'
printf '%s\n' wrong > "${directory}/calidus.id"
if cntools_calidus_prepare "${directory}" repair; then fail 'stale ID accepted'; fi
[[ "$(< "${directory}/calidus.id")" == wrong ]] || fail 'stale ID overwritten'
printf '%s\n' "${id}" > "${directory}/calidus.id"
cp "${CNTOOLS_POOL_DIR}/Extended/calidus.vkey" "${directory}/calidus.vkey"
if cntools_calidus_inspect "${directory}"; then fail 'mismatched pair accepted'; fi
rm "${directory}/calidus.vkey"
cntools_calidus_prepare "${directory}" repair || fail 'restore matching public key'
(
  cntools_calidus_id_into() {
    printf -v "$1" '%s' "${id}"
    cp "${CNTOOLS_POOL_DIR}/Extended/calidus.vkey" "${directory}/calidus.vkey"
  }
  if cntools_calidus_inspect "${directory}"; then fail 'public key path swap accepted'; fi
)
rm "${directory}/calidus.vkey"
cntools_calidus_prepare "${directory}" repair || fail 'restore after inspection race'
(
  cntools_calidus_prepare_files() { return 1; }
  if cntools_calidus_prepare "${directory}" repair; then fail 'silent setup failure accepted'; fi
  [[ -n "${CNTOOLS_POOL_WRITE_ERROR}" ]] || fail 'setup failure not recorded'
)

mkdir -m700 "${CNTOOLS_POOL_DIR}/Encrypted"
cp "${directory}/calidus.vkey" "${CNTOOLS_POOL_DIR}/Encrypted/calidus.vkey"
printf encrypted-fixture > "${CNTOOLS_POOL_DIR}/Encrypted/calidus.skey.gpg"
cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/Encrypted" repair || fail 'public repair for encrypted Calidus key'
cntools_calidus_inspect "${CNTOOLS_POOL_DIR}/Encrypted" || fail 'encrypted public identity'
[[ "${CNTOOLS_CALIDUS_STATE}" == Encrypted && ! -e "${CNTOOLS_POOL_DIR}/Encrypted/calidus.skey" ]] || fail 'public repair decrypted key'
cp "${directory}/calidus.skey" "${CNTOOLS_POOL_DIR}/Encrypted/calidus.skey"
if cntools_calidus_inspect "${CNTOOLS_POOL_DIR}/Encrypted"; then fail 'mixed clear/encrypted Calidus keys accepted'; fi

mkdir -m700 "${CNTOOLS_POOL_DIR}/Protected" "${CNTOOLS_POOL_DIR}/Linked" "${CNTOOLS_POOL_DIR}/Unsafe" "${CNTOOLS_POOL_DIR}/LooseKey"
printf encrypted-fixture > "${CNTOOLS_POOL_DIR}/Protected/cold.skey.gpg"
if cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/Protected" create; then fail 'unencrypted secret added to protected pool'; fi
ln -s "${TEST_ROOT}/outside" "${CNTOOLS_POOL_DIR}/Linked/calidus.vkey"
if cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/Linked" create; then fail 'symlink destination accepted'; fi
chmod 0770 "${CNTOOLS_POOL_DIR}/Unsafe"
if cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/Unsafe" create; then fail 'shared writable pool accepted'; fi
cp "${directory}/calidus.skey" "${TEST_ROOT}/loose.skey"; chmod 0644 "${TEST_ROOT}/loose.skey"
if cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/LooseKey" signing "${TEST_ROOT}/loose.skey"; then fail 'publicly readable secret accepted'; fi
(
  CNTOOLS_POOL_CALIDUS_VKEY_FILENAME=cold.skey
  if cntools_calidus_prepare "${CNTOOLS_POOL_DIR}/LooseKey" create; then fail 'filename collision accepted'; fi
)

# Roll back owned links only, retaining any racing replacement.
for race in N Y; do
  (
    directory="${CNTOOLS_POOL_DIR}/Rollback${race}"; mkdir -m700 "${directory}"
    ln() {
      [[ "${1:-}" != -T ]] || shift
      if [[ "${3##*/}" == calidus.vkey ]]; then
        if [[ "${race}" == Y ]]; then rm "${directory}/calidus.skey"; printf foreign > "${directory}/calidus.skey"; fi
        return 1
      fi
      "${REAL_LN}" "$@"
    }
    if cntools_calidus_prepare "${directory}" create; then fail 'partial publication succeeded'; fi
    [[ ! -e "${directory}/calidus.vkey" && ! -e "${directory}/calidus.id" ]] || fail 'partial public identity remained'
    if [[ "${race}" == Y ]]; then [[ "$(< "${directory}/calidus.skey")" == foreign ]] || fail 'foreign replacement removed'
    else [[ ! -e "${directory}/calidus.skey" ]] || fail 'partial signing key remained'; fi
  )
done
for boundary in calidus.skey calidus.vkey calidus.id; do
  directory="${CNTOOLS_POOL_DIR}/Stop-${boundary}"; mkdir -m700 "${directory}"
  status=0
  (
    trap 'cntools_calidus_publication_cleanup; cntools_pool_files_cleanup; cntools_transaction_cleanup' EXIT
    trap 'exit 143' TERM
    ln() {
      [[ "${1:-}" != -T ]] || shift
      "${REAL_LN}" "$@" || return 1
      [[ "${3##*/}" != "${boundary}" ]] || kill -TERM "${BASHPID}"
    }
    cntools_calidus_prepare "${directory}" create
  ) || status=$?
  [[ "${status}" == 143 && ! -e "${directory}/calidus.skey" && ! -e "${directory}/calidus.vkey" && ! -e "${directory}/calidus.id" ]] || fail 'interrupted publication left files'
done
private_hex="$(jq -r '.cborHex' "${TEST_ROOT}/extended.skey")"
if rg -F "${private_hex}" "${TEST_ROOT}/log" >/dev/null; then fail 'secret key logged'; fi
if rg -n 'query |transaction submit|curl ' "${TEST_ROOT}/log" >/dev/null; then fail 'offline setup contacted backend'; fi
printf 'PASS: Calidus identity and safe publication against cnode CLI %s\n' "${version}"
