#!/usr/bin/env bash
# Real, node-free KES rotation and offline issuance with the cnode deployment pin.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
CNTOOLS_CLI="${1:?Pass the verified pinned cnode CLI}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-kes-pinned.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'chmod -R u+rwX "${TEST_ROOT}" 2>/dev/null || true; rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
. "${CNTOOLS_ROOT}/core/health.sh"
for lib in number wallet wallet-query transaction transaction-sign transaction-funding pool-id table pool pool-files pool-key pool-lock pool-protection pool-inspect pool-health pool-opcert-validation pool-kes pool-kes-ui; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { tail -12 "${TEST_ROOT}/log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command() { local mask="$1"; shift 2; (( ${#mask} == $# )) || fail 'audit mask'; printf '%q ' "$@" >> "${TEST_ROOT}/log"; printf '\n' >> "${TEST_ROOT}/log"; "$@"; }
cntools_run_command_timeout() { shift; cntools_run_command "$@"; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_ui_render_status() { :; }
cntools_ui_action_begin() { :; }
cntools_ui_wait() { :; }
cntools_table_render() { cat; }
cntools_table_pair() { printf '%s: %s\n' "$1" "$2"; }
# macOS test adapters only. Linux CI exercises actual GNU file replacement.
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_MV="$(type -P mv)"
  chmod() { local arg; local -a args=(); for arg in "$@"; do [[ "$arg" == -- ]] || args+=("$arg"); done; "${REAL_CHMOD}" "${args[@]}"; }
  mv() {
    if [[ "$1" == --help ]]; then printf '%s\n' '--no-target-directory'; return 0; fi
    [[ "$1" == -Tf && "$2" == -- ]] || fail 'unexpected replacement command'
    [[ ! -d "$4" && ! -L "$4" ]] || return 1
    "${REAL_MV}" -f "$3" "$4"
  }
fi
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
eq "${version}" "$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")" 'cnode pin'
if [[ -n "${2:-}" ]]; then
  hw_help="$("$2" node issue-op-cert --help 2>&1)" || fail 'pinned hardware CLI opcert help'
  for option in --kes-verification-key-file --operational-certificate-issue-counter-file --kes-period --out-file --hw-signing-file; do
    [[ "${hw_help}" == *"${option}"* ]] || fail "pinned hardware CLI missing ${option}"
  done
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_POOL_DIR="${TEST_ROOT}/pools" CNTOOLS_MODE=offline CNTOOLS_NETWORK=preview
CNTOOLS_ENABLE_CHATTR=false CNTOOLS_KOIOS_ENABLED=N CNTOOLS_LOG="${TEST_ROOT}/log"
mkdir -m 700 "${CNTOOLS_POOL_DIR}" "${CNTOOLS_POOL_DIR}/Node" "${CNTOOLS_POOL_DIR}/Signer"
node="${CNTOOLS_POOL_DIR}/Node" signer="${CNTOOLS_POOL_DIR}/Signer"
"${CNTOOLS_CLI}" latest node key-gen --cold-verification-key-file "${node}/cold.vkey" --cold-signing-key-file "${node}/cold.skey" --operational-certificate-issue-counter-file "${node}/cold.counter"
"${CNTOOLS_CLI}" latest node key-gen-KES --verification-key-file "${node}/hot.vkey" --signing-key-file "${node}/hot.skey"
"${CNTOOLS_CLI}" latest node key-gen-VRF --verification-key-file "${node}/vrf.vkey" --signing-key-file "${node}/vrf.skey"
"${CNTOOLS_CLI}" latest node issue-op-cert --kes-verification-key-file "${node}/hot.vkey" --cold-signing-key-file "${node}/cold.skey" --operational-certificate-issue-counter-file "${node}/cold.counter" --kes-period 0 --out-file "${node}/op.cert"
printf '0\n' > "${node}/kes.start"
cp "${node}"/* "${signer}/"
chmod 0400 "${node}"/* "${signer}"/*
untouched="$(cksum "${node}/cold.vkey" "${node}/cold.skey" "${node}/vrf.vkey" "${node}/vrf.skey")"
before="$(cksum "${node}/hot.vkey" "${node}/hot.skey" "${node}/op.cert" "${node}/kes.start" "${node}/cold.counter")"
cntools_kes_environment || fail 'environment'
cntools_pool_catalog_build || fail 'catalog'
cntools_pool_inspect_reset
cntools_kes_identity 0 || fail 'identity'
CNTOOLS_KES_COUNTER_APPROVED=Y CNTOOLS_KES_CURRENT=20
CNTOOLS_POOL_CERT_CHAIN[0]=0
if cntools_kes_prepare 19; then fail 'past period accepted'; fi
CNTOOLS_KES_NEXT=2
if cntools_kes_counter_guard; then fail 'counter jumped past ledger'; fi
CNTOOLS_KES_NEXT=1
cntools_kes_prepare 20 || fail "prepare: ${CNTOOLS_POOL_WRITE_ERROR}"
rotation="${CNTOOLS_KES_STAGE}"
if cntools_kes_lock_acquire rotate; then fail 'concurrent issuance lock accepted'; fi
linked_counter="${TEST_ROOT}/linked.counter"
ln -s "${node}/cold.counter" "${linked_counter}"
if cntools_pool_counter_into next "${linked_counter}" "${node}/cold.vkey"; then fail 'linked issue counter accepted'; fi
eq "$(cksum "${node}/hot.vkey" "${node}/hot.skey" "${node}/op.cert" "${node}/kes.start" "${node}/cold.counter")" "${before}" 'preparation changed active files'
eq "$(find "${rotation}/request" -type f | wc -l | tr -d ' ')" 4 'public request files'
[[ ! -e "${rotation}/request/hot.skey" && ! -e "${rotation}/request/cold.skey" ]] || fail 'private key in request'
# Cancellation/normal cleanup preserves the prepared rotation and releases busy only.
cntools_kes_cleanup
[[ -d "${rotation}" && -d "${node}/.cntools-opcert-lock" && ! -e "${node}/.cntools-opcert-lock/busy" ]] || fail 'cleanup removed recovery'
cntools_kes_pending_load || fail 'pending reload'
cntools_kes_offline_instructions
eq "$(< "${rotation}/phase")" awaiting 'export did not prevent local issuance'
if cntools_kes_issue; then fail 'issued again after offline hand-off'; fi
cntools_kes_cleanup

# Signing-side uses its own real counter, never the transferred counter as authority.
cntools_kes_identity 1 || fail 'signer identity'
CNTOOLS_KES_COUNTER_APPROVED=Y CNTOOLS_POOL_CERT_CHAIN[1]=0
signer_before="$(cksum "${signer}/hot.vkey" "${signer}/hot.skey" "${signer}/op.cert" "${signer}/kes.start")"
cntools_kes_sign_request "${rotation}/request" || fail "offline sign: ${CNTOOLS_POOL_WRITE_ERROR} ${CNTOOLS_TRANSACTION_ERROR}"
response="${CNTOOLS_KES_STAGE}/replacement"
eq "$(cksum "${signer}/hot.vkey" "${signer}/hot.skey" "${signer}/op.cert" "${signer}/kes.start")" "${signer_before}" 'offline signer changed active KES'
cntools_pool_counter_into next "${signer}/cold.counter" "${signer}/cold.vkey"; eq "${next}" 2
cntools_kes_identity 1 || fail 'replayed signer identity'
if cntools_kes_sign_request "${rotation}/request"; then fail 'stale offline request signed again'; fi

cntools_kes_identity 0 || fail 'node identity after offline signing'
cntools_kes_pending_load || fail 'node pending'
mkdir -m 700 "${TEST_ROOT}/bad-response"
cp "${response}"/* "${TEST_ROOT}/bad-response/"
jq '.cborHex |= (.[0:10]+"00"+.[12:])' "${response}/op.cert" > "${TEST_ROOT}/bad-response/op.cert"
if cntools_kes_import_response "${TEST_ROOT}/bad-response"; then fail 'altered signed response accepted'; fi
eq "$(cksum "${node}/hot.vkey" "${node}/hot.skey" "${node}/op.cert" "${node}/kes.start" "${node}/cold.counter")" "${before}" 'failed import changed active files'
cntools_kes_import_response "${response}" || fail "import: ${CNTOOLS_POOL_WRITE_ERROR}"
eq "$(< "${rotation}/phase")" issued
cntools_pool_counter_into next "${node}/cold.counter" "${node}/cold.vkey"; eq "${next}" 2
CNTOOLS_KES_NODE_STOPPED=N
if cntools_kes_publish; then fail 'publication without stopped-node confirmation'; fi
CNTOOLS_KES_NODE_STOPPED=Y
cp "${rotation}/replacement/hot.skey" "${TEST_ROOT}/saved-new.skey"
"${CNTOOLS_CLI}" latest node key-gen-KES --verification-key-file "${TEST_ROOT}/wrong.vkey" --signing-key-file "${rotation}/replacement/hot.skey"
if cntools_kes_publish; then fail 'wrong KES private key published'; fi
cp "${TEST_ROOT}/saved-new.skey" "${rotation}/replacement/hot.skey"

# Inject one publication failure. Counter remains advanced; mixed set is recoverable
# with the node stopped, and continuing never generates another certificate.
eval "$(declare -f cntools_kes_replace | sed '1s/cntools_kes_replace/cntools_kes_replace_real/')"
injected=N
cntools_kes_replace() { if [[ "$1" == kes-vkey && "${injected}" == N ]]; then injected=Y; return 1; fi; cntools_kes_replace_real "$@"; }
CNTOOLS_KES_NODE_STOPPED=Y
if cntools_kes_publish; then fail 'injected failure did not fail'; fi
eq "$(< "${rotation}/phase")" publishing
[[ -d "${node}/.cntools-opcert-lock" ]] || fail 'failure removed lock'
cntools_pool_counter_into next "${node}/cold.counter" "${node}/cold.vkey"; eq "${next}" 2 'counter rolled back'
cntools_kes_cleanup
cntools_kes_identity 0 && cntools_kes_pending_load || fail 'publication recovery reload'
cntools_kes_publish || fail "resume: ${CNTOOLS_POOL_WRITE_ERROR}"
eq "$(< "${rotation}/phase")" complete
[[ ! -e "${node}/.cntools-opcert-lock" ]] || fail 'successful rotation remained locked'
eq "$(cksum "${node}/cold.vkey" "${node}/cold.skey" "${node}/vrf.vkey" "${node}/vrf.skey")" "${untouched}" 'cold or VRF keys changed'
cntools_pool_opcert_verify "${node}/op.cert" "${node}/cold.vkey" "${node}/hot.vkey" 1 20 || fail 'published signature'
eq "$(< "${node}/kes.start")" 20
cmp -s "${rotation}/original/kes-skey" "${signer}/hot.skey" || fail 'old key backup missing'
[[ -f "${rotation}/replacement/hot.skey" ]] || fail 'new key recovery missing'
eq "$(stat -c '%a' "${node}/hot.skey" 2>/dev/null || stat -f '%Lp' "${node}/hot.skey")" 400 'read-only protection lost'

# Real local issuance plus interrupted-issuance validation, with no re-issuance.
CNTOOLS_POOL_CERT_CHAIN[0]=1 CNTOOLS_KES_COUNTER_APPROVED=Y
cntools_kes_identity 0 || fail 'second rotation identity'
CNTOOLS_KES_CURRENT=21
cntools_kes_prepare 21 && cntools_kes_issue || fail "local issuance: ${CNTOOLS_POOL_WRITE_ERROR}"
second="${CNTOOLS_KES_STAGE}"
cntools_kes_phase_set issuing
cntools_kes_consume_counter || fail 'issued output recovery'
cntools_pool_counter_into next "${node}/cold.counter" "${node}/cold.vkey"; eq "${next}" 3
cntools_kes_publish || fail 'local publish'
cntools_pool_opcert_verify "${node}/op.cert" "${node}/cold.vkey" "${node}/hot.vkey" 2 21 || fail 'second certificate'
[[ -d "${second}" && -d "${rotation}" ]] || fail 'durable backups removed'

# Hardware dispatch: real signed opcert output, with only the physical device
# boundary doubled. The cold private key exists solely in this test fixture.
mv -Tf -- "${node}/cold.skey" "${TEST_ROOT}/device-cold.skey"
jq -n --arg hex "$(jq -r '.cborHex[4:]' "${node}/cold.vkey")" \
  '{type:"StakePoolHWSigningFile_ed25519",path:"1853H/1815H/0H/0H",cborXPubKeyHex:("5840"+$hex+"0000000000000000000000000000000000000000000000000000000000000000")}' > "${node}/cold.hwsfile"
CNTOOLS_POOL_CERT_CHAIN[0]=2 CNTOOLS_KES_COUNTER_APPROVED=Y
cntools_kes_identity 0 || fail 'hardware cold identity'
eq "${CNTOOLS_KES_KIND}" hardware
CNTOOLS_KES_CURRENT=22
cntools_kes_prepare 22 || fail 'hardware preparation'
eval "$(declare -f cntools_transaction_run_cli | sed '1s/cntools_transaction_run_cli/cntools_transaction_run_cli_real/')"
device_checks=0 hardware_calls=0
cntools_transaction_hardware_device_check() { device_checks=$((device_checks+1)); CNTOOLS_TRANSACTION_HWCLI=/usr/bin/true; }
cntools_transaction_run_cli() {
  if [[ "${4:-}" != /usr/bin/true ]]; then cntools_transaction_run_cli_real "$@"; return $?; fi
  local stdout="$1" stderr="$2" argument='' previous='' hot='' counter='' period='' cert='' reference=''
  shift 3
  [[ "$2" == node && "$3" == issue-op-cert ]] || fail 'wrong hardware command'
  for argument in "$@"; do
    case "${previous}" in
      --kes-verification-key-file) hot="${argument}" ;; --operational-certificate-issue-counter-file) counter="${argument}" ;;
      --kes-period) period="${argument}" ;; --out-file) cert="${argument}" ;; --hw-signing-file) reference="${argument}" ;;
    esac
    previous="${argument}"
  done
  [[ -n "${reference}" && "$(jq -r .type "${reference}")" == StakePoolHWSigningFile_ed25519 &&
     "$*" != *--cold-signing-key-file* ]] || fail 'hardware dispatch used a CLI cold key'
  hardware_calls=$((hardware_calls+1))
  cntools_transaction_run_cli_real "${stdout}" "${stderr}" -- "${CNTOOLS_CLI}" latest node issue-op-cert \
    --kes-verification-key-file "${hot}" --cold-signing-key-file "${TEST_ROOT}/device-cold.skey" \
    --operational-certificate-issue-counter-file "${counter}" --kes-period "${period}" --out-file "${cert}"
}
# Simulate an immutable-lock restoration failure after counter replacement.
# The recorded original intent must survive and be reapplied on recovery.
printf 'Y\n' > "${CNTOOLS_KES_STAGE}/protection-counter"
immutable_attempts=0
cntools_pool_chattr_prepare() { :; }
cntools_pool_chattr() {
  if [[ "$1" == +i ]]; then
    immutable_attempts=$((immutable_attempts+1))
    ((immutable_attempts != 1)) || return 1
  fi
}
if cntools_kes_issue; then fail 'injected immutable restoration failure ignored'; fi
eq "$(< "${CNTOOLS_KES_STAGE}/phase")" issuing
cntools_pool_counter_into next "${node}/cold.counter" "${node}/cold.vkey"; eq "${next}" 4 'immutable failure rewound counter'
cntools_kes_consume_counter && cntools_kes_publish || fail "hardware issuance recovery/publication: ${CNTOOLS_POOL_WRITE_ERROR}"
((immutable_attempts >= 2)) || fail 'original immutable protection was not retried'
eq "${device_checks}" 1; eq "${hardware_calls}" 1
cntools_pool_opcert_verify "${node}/op.cert" "${node}/cold.vkey" "${node}/hot.vkey" 3 22 || fail 'hardware certificate output'
eq "$(jq -r .type "${node}/cold.hwsfile")" StakePoolHWSigningFile_ed25519 'hardware reference changed'
cntools_pool_protection_preflight "${node}" decrypt || fail 'rotation archives prevent pool protection'
cntools_pool_catalog_build || fail 'catalog with hidden rotation archives'
eq "${#CNTOOLS_POOL_NAMES[@]}" 2 'recovery directory appeared as a pool'
cntools_kes_cleanup
printf 'CNTools pinned KES rotation tests passed (cardano-cli %s).\n' "${version}"
