#!/usr/bin/env bash
# Public-participant, query and interaction contracts; no external services.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-drep-script-ui.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query transaction drep-id drep-key drep-query drep-script governance-wallet-ui drep-script-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/log"; }
hash1="$(printf 'ab%.0s' {1..28})" hash2="$(printf 'cd%.0s' {1..28})"
cntools_drep_script_participant_add "${hash1^^}" Alice
[[ "${CNTOOLS_DREP_SCRIPT_HASHES[0]}" == "${hash1}" ]] || fail 'hash normalization'
if cntools_drep_script_participant_add "${hash1}" Duplicate || cntools_drep_script_participant_add bad Invalid; then fail 'invalid participant accepted'; fi
for ((i=2;i<=20;i++)); do printf -v hash '%056x' "${i}"; cntools_drep_script_participant_add "${hash}" "Participant ${i}"; done
if cntools_drep_script_participant_add "${hash2}" Extra; then fail 'participant limit ignored'; fi

# Native-script targets use exact credential types in both backends.
cntools_drep_bech32_into id "23${hash1}"
jq -n --arg hash "${hash1}" '[[{scriptHash:$hash},{expiry:42,deposit:500000000}]]' > "${TEST_ROOT}/response"
cntools_drep_parse_local "${TEST_ROOT}/response" script "${hash1}" || fail 'script local state'
if cntools_drep_parse_local "${TEST_ROOT}/response" key "${hash1}"; then fail 'script state accepted for key'; fi
jq -n --arg id "${id}" --arg hash "${hash1}" '[{drep_id:$id,hex:$hash,has_script:true,drep_status:"registered",active:true}]' > "${TEST_ROOT}/response"
cntools_drep_parse_koios "${TEST_ROOT}/response" "${id}" script "${hash1}" || fail 'script Koios state'
if cntools_drep_parse_koios "${TEST_ROOT}/response" "${id}" key "${hash1}"; then fail 'Koios credential mismatch accepted'; fi
(
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_transaction_network_arguments_into() { local -n network_result="$1"; network_result=(--testnet-magic 2); }
  cntools_transaction_run_cli() {
    [[ "$*" == *"--drep-script-hash ${hash1}"* && "$*" != *--drep-key-hash* ]] || fail 'wrong local script flag'
    jq -n --arg hash "${hash1}" '[[{scriptHash:$hash},{expiry:42,deposit:500000000}]]' > "$1"
  }
  cntools_transaction_log() { :; }
  cntools_wallet_query_http() {
    [[ "$1" == https://example.invalid/api/v1/drep_info && "$(jq -r '._drep_ids[0]' <<< "$2")" == "${id}" ]] || fail 'wrong Koios target'
    cp "${TEST_ROOT}/response" "$3"
  }
  CNTOOLS_CLI=/unused CNTOOLS_SOCKET=/unused CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://example.invalid/api/v1
  cntools_drep_query "${id}" script "${hash1}" local || fail 'local query adapter'
  cntools_drep_query "${id}" script "${hash1}" koios || fail 'Koios query adapter'
  CNTOOLS_MODE=offline CNTOOLS_DREP_KEY_ID="${id}" CNTOOLS_DREP_KEY_HASH="${hash1}" CNTOOLS_DREP_KEY_KIND=script
  cntools_drep_query() { fail 'offline performed a query'; }
  cntools_governance_status_collect
  [[ "${CNTOOLS_DREP_SOURCE}:${CNTOOLS_DREP_STATUS}" == Offline:unknown ]] || fail 'offline status overstated'
)

# Publication cleanup removes our own links, never a competing replacement.
mkdir "${TEST_ROOT}/stage" "${TEST_ROOT}/target"
printf ours > "${TEST_ROOT}/stage/ours"; printf old > "${TEST_ROOT}/stage/replaced"
ln "${TEST_ROOT}/stage/ours" "${TEST_ROOT}/target/ours"; printf foreign > "${TEST_ROOT}/target/replaced"
cntools_wallet_create_stage_safe() { [[ "$1" == "${TEST_ROOT}/stage" ]]; }
CNTOOLS_DREP_SCRIPT_LINK_SOURCES=("${TEST_ROOT}/stage/ours" "${TEST_ROOT}/stage/replaced")
CNTOOLS_DREP_SCRIPT_LINK_TARGETS=("${TEST_ROOT}/target/ours" "${TEST_ROOT}/target/replaced")
cntools_drep_script_publication_cleanup || fail 'interrupted cleanup'
[[ ! -e "${TEST_ROOT}/target/ours" && "$(< "${TEST_ROOT}/target/replaced")" == foreign ]] || fail 'cleanup touched foreign file'

# Script Info & Status describes the script instead of nonexistent private
# keys, and cached-only inspection cannot imply verified signing authority.
(
  cntools_governance_wallet_select_into() { printf -v "$1" '%s' /wallet/Shared; }
  cntools_drep_key_inspect() {
    CNTOOLS_DREP_KEY_ID="${id}" CNTOOLS_DREP_KEY_HASH="${hash1}" CNTOOLS_DREP_KEY_KIND=script CNTOOLS_DREP_KEY_VERIFIED=N
    CNTOOLS_DREP_SCRIPT_THRESHOLD=2 CNTOOLS_DREP_SCRIPT_PARTICIPANTS=3 CNTOOLS_DREP_KEY_PATH=''
  }
  cntools_ui_action_begin() { :; }
  cntools_transaction_ui_table_widths_into() { printf -v "$1" '%s' 24,90; }
  cntools_transaction_ui_styled_row() { printf '%s: %s\n' "$1" "$2"; }
  cntools_ui_table() { cat; }
  cntools_ui_wait() { :; }
  cntools_public_metadata_offer() { :; }
  CNTOOLS_MODE=offline
  rows="$(cntools_governance_action_info)"
  [[ "${rows}" == *'Type: Native script DRep'* && "${rows}" == *'Threshold: 2 of 3'* &&
     "${rows}" == *'script hash not verified'* && "${rows}" != *'Private key:'* &&
     "${rows}" != *'Verification key:'* && "${rows}" == *'Not queried · offline'* ]] || fail 'script identity/status UI'
)

(
  cntools_wallet_catalog_build() { :; }
  cntools_wallet_choose() { printf -v "$1" 0; }
  CNTOOLS_WALLET_PATHS=(/wallet/participant)
  cntools_drep_key_inspect() { CNTOOLS_DREP_KEY_KIND=script CNTOOLS_DREP_KEY_VERIFIED=Y; }
  if cntools_drep_script_local_participant; then fail 'nested script used as signature participant'; fi
)

# Wizard defaults to all participants, cancels at every prompt and never
# requires private keys, builds a transaction or submits one.
cntools_gum_clear() { :; }
cntools_ui_action_begin() { :; }
cntools_ui_wait() { :; }
cntools_ui_render_status() { printf '%s\n' "$*" >> "${TEST_ROOT}/ui"; }
cntools_table_pair() { printf '%s\t%s\n' "$1" "$2"; }
cntools_table_render() { cat >> "${TEST_ROOT}/ui"; }
cntools_governance_wallet_select_into() { [[ "${scenario}" != wallet-cancel ]] || return 1; printf -v "$1" '%s' /wallet/Shared; }
cntools_drep_script_preflight() { :; }
cntools_transaction_require_cli() { :; }
cntools_ui_choose() { local -n result="$1"; result="${choices[choice_index]}"; choice_index=$((choice_index+1)); }
cntools_ui_input() { [[ "${scenario}" != threshold-cancel ]] || return 1; local -n result="$1"; result="${inputs[input_index]}"; input_index=$((input_index+1)); }
cntools_ui_confirm() { [[ "$2" == false ]] || fail 'confirmation not default No'; [[ "${scenario}" != confirm-cancel ]]; }
cntools_drep_script_local_participant() { cntools_drep_script_participant_add "${hash1}" Alice; }
cntools_drep_script_external_participant() { cntools_drep_script_participant_add "${hash2}" External; }
cntools_drep_script_create() { printf '%s\n' "$*" >> "${TEST_ROOT}/created"; }
cntools_drep_key_inspect() { CNTOOLS_DREP_KEY_ID="${id}"; }
scenario=success choices=('Add CNTools DRep keys' 'Add external participant' Done) inputs=('') choice_index=0 input_index=0
cntools_drep_script_workflow || fail 'default-threshold workflow'
[[ "$(< "${TEST_ROOT}/created")" == '/wallet/Shared 2' ]] || fail 'wrong default threshold/target'
for scenario in wallet-cancel participants-cancel threshold-cancel confirm-cancel; do
  choices=('Add CNTools DRep keys' Done) inputs=('') choice_index=0 input_index=0
  [[ "${scenario}" != participants-cancel ]] || choices=(Cancel)
  status=0; cntools_drep_script_workflow || status=$?
  [[ "${status}" == 1 ]] || fail "cancel ignored: ${scenario}"
done
[[ "$(wc -l < "${TEST_ROOT}/created" | tr -d ' ')" == 1 ]] || fail 'cancellation created identity'
scenario=success choices=(Done Cancel) choice_index=0 input_index=0
if cntools_drep_script_workflow; then fail 'empty participants accepted'; fi
choices=('Add CNTools DRep keys' Done) inputs=(0 2 1) choice_index=0 input_index=0
cntools_drep_script_workflow || fail 'invalid threshold retry'
[[ "$(tail -1 "${TEST_ROOT}/created")" == '/wallet/Shared 1' && "${input_index}" == 3 ]] || fail 'threshold validation/default'
printf 'CNTools script DRep interaction/query tests passed.\n'
