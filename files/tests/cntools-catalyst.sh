#!/usr/bin/env bash
# Catalyst API semantics, QR transport/secrecy and cancellable interaction.
# shellcheck disable=SC1090,SC2034,SC2030,SC2031,SC2329,SC2154,SC2015
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-catalyst.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
for lib in number wallet wallet-material transaction drep-id catalyst-key catalyst-qr catalyst-query catalyst-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
cntools_run_command_timeout() {
  local timeout="$1" mask="$2" argument='' index=0
  shift 3
  for argument in "$@"; do
    if [[ "${mask:index:1}" == 1 ]]; then printf '<redacted> ' >> "${TEST_ROOT}/log"
    else printf '%s ' "${argument}" >> "${TEST_ROOT}/log"; fi
    index=$((index+1))
  done
  printf '\n' >> "${TEST_ROOT}/log"; "$@"
}
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)"
  chmod() { local a=''; local -a args=(); for a in "$@"; do [[ "${a}" == -- ]] || args+=("${a}"); done; "${REAL_CHMOD}" "${args[@]}"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_MODE=light CNTOOLS_NETWORK=mainnet
CNTOOLS_LOG="${TEST_ROOT}/log" CNTOOLS_CATALYST_API=https://catalyst.invalid/api/v1
calls=0 api_status=0 api_payload='{"last_updated":"2026-10-01T12:00:00Z","final":true,"voter_info":{"voting_power":500000000,"delegations_count":1,"delegator_addresses":["stake1example"]}}'
cntools_api_request() {
  [[ "$1" == GET && "$2" == "https://catalyst.invalid/api/v1/registration/voter/0x"*'?with_delegators=true' ]] || fail 'wrong Catalyst API call'
  calls=$((calls+1)); printf '%s\n' "${api_payload}" > "$3"; return "${api_status}"
}
public="$(printf 'ab%.0s' {1..32})"
cntools_catalyst_lookup "${public}" || fail 'snapshot lookup'
[[ "${CNTOOLS_CATALYST_STATUS}" == 'Reported in snapshot' && "${calls}" == 1 ]] || fail 'snapshot state'
api_payload='{"error":"Not found in snapshot"}'
cntools_catalyst_lookup "${public}" || fail 'no snapshot data called transport failure'
[[ "${CNTOOLS_CATALYST_STATUS}" == 'Not reported in snapshot' ]] || fail 'missing snapshot conflated with confirmed inclusion'
api_status=1
! cntools_catalyst_lookup "${public}" || fail 'HTTP failure ignored'
[[ "${CNTOOLS_CATALYST_STATUS}" == Unavailable ]] || fail 'failure called unregistered'
api_status=0 api_payload='[]'
! cntools_catalyst_lookup "${public}" || fail 'malformed API accepted'
CNTOOLS_NETWORK=preview
! cntools_catalyst_lookup "${public}" || fail 'testnet eligibility claimed'
CNTOOLS_NETWORK=mainnet CNTOOLS_MODE=offline
before="${calls}"; ! cntools_catalyst_lookup "${public}" || fail 'offline lookup accepted'
[[ "${calls}" == "${before}" ]] || fail 'offline API request'
# QR transport: only encrypted output is published, no existing QR overwrite.
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"; mkdir -m700 "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_WALLET_DIR}/Example"
directory="${CNTOOLS_WALLET_DIR}/Example"
private="$(printf 'cd%.0s' {1..128})"
jq -n --arg key "5880${private}" '{type:"CIP36VoteExtendedSigningKey_ed25519",cborHex:$key}' > "${directory}/catalyst.skey"
jq -n --arg key "5820${public}" '{type:"CIP36VoteVerificationKey_ed25519",cborHex:$key}' > "${directory}/catalyst.vkey"
cp "${REPO_ROOT}/files/tests/fixtures/catalyst-toolbox.sh" "${TEST_ROOT}/toolbox"; chmod 700 "${TEST_ROOT}/toolbox"
CNTOOLS_CATALYST_TOOLBOX="${TEST_ROOT}/toolbox"
cntools_transaction_require_cli() { :; }
cntools_catalyst_pair_valid() { :; } # Actual identity proof is in the pinned suite.
cntools_catalyst_qr_create "${directory}" 0042 || fail "QR generation: ${CNTOOLS_TRANSACTION_ERROR}"
[[ "${CNTOOLS_CATALYST_QR_OUTPUT}" == "${directory}/catalyst-qrcode.png" && -f "${CNTOOLS_CATALYST_QR_OUTPUT}" ]] || fail 'QR artifact'
first="${CNTOOLS_CATALYST_QR_OUTPUT}"
cntools_catalyst_qr_create "${directory}" 0042 || fail 'repeat QR'
[[ "${CNTOOLS_CATALYST_QR_OUTPUT}" != "${first}" && -f "${first}" ]] || fail 'overwrote prior QR'
! rg -F '0042' "${TEST_ROOT}/log" >/dev/null || fail 'PIN logged'
! rg -F "${private}" "${TEST_ROOT}/log" >/dev/null || fail 'voting secret logged'
! rg 'ed25519e_sk1' "${TEST_ROOT}/log" >/dev/null || fail 'Bech32 secret logged'
export TOOLBOX_TEST_FAIL=Y
! cntools_catalyst_qr_create "${directory}" 0042 || fail 'toolbox failure ignored'
unset TOOLBOX_TEST_FAIL
[[ ! -e "${directory}/catalyst-qrcode-2.png" ]] || fail 'failed QR published'
cntools_catalyst_cleanup
[[ -f "${first}" && -z "$(find "${directory}" -maxdepth 1 -name '.cntools-*' -print)" ]] || fail 'cleanup boundary'
# A cancelled first selector never generates keys, calls APIs or deletes files.
cntools_wallet_catalog_build() { :; }
cntools_wallet_choose() { return 1; }
cntools_ui_choose() { printf -v "$1" Cancel; }
cntools_ui_action_begin() { :; }
cntools_ui_render_status() { :; }
cntools_ui_wait() { :; }
cntools_catalyst_action_registration || fail 'registration cancel treated as failure'
cntools_catalyst_action_qr || fail 'QR cancel treated as failure'
cntools_catalyst_action_verify || fail 'verify cancel treated as failure'
# Offline registration exports only public authorization; no chain query/build.
(
  CNTOOLS_MODE=offline CNTOOLS_WALLET_PATHS=("${directory}") CNTOOLS_PAYMENT_TYPE=CLI
  authorizations=0 exports=0
  cntools_wallet_choose() { [[ "$*" == *catalyst* ]] || fail 'wallet eligibility context'; printf -v "$1" '%s' 0; }
  cntools_catalyst_identity() { CNTOOLS_CATALYST_REWARD=reward; }
  cntools_catalyst_keys_prepare() { CNTOOLS_CATALYST_PUBLIC="${public}"; }
  cntools_catalyst_render_identity() { :; }
  cntools_ui_choose() { printf -v "$1" '%s' 'Authorize with wallet stake key'; }
  cntools_ui_input() { printf -v "$1" '%s' 123; }
  cntools_ui_confirm() { [[ "$2" == false ]] || fail 'authorization must default No'; }
  cntools_catalyst_cbor_uint_into() { [[ "$2" == 123 ]] || fail 'nonce input'; printf -v "$1" '%s' 187b; }
  cntools_catalyst_authorize() { authorizations=$((authorizations+1)); CNTOOLS_CATALYST_METADATA=/public/metadata.json; }
  cntools_transaction_save_into() { [[ "$3" == metadata && "$4" == catalyst-authorization ]] || fail 'offline export'; exports=$((exports+1)); printf -v "$1" '%s' /saved/metadata.json; }
  cntools_table_pair() { :; }
  cntools_table_render() { :; }
  cntools_ui_spin_function() { shift; "$@"; }
  cntools_funding_collect() { fail 'offline funding query'; }
  cntools_metadata_transaction_workflow() { fail 'offline funding build'; }
  cntools_catalyst_registration_workflow || fail 'offline authorization workflow'
  [[ "${authorizations}" == 1 && "${exports}" == 1 ]] || fail 'offline authorization/export not completed'
)
printf 'CNTools Catalyst API/QR/interaction tests passed\n'
