#!/usr/bin/env bash
# Deterministic regression checks for implemented legacy parity additions.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-parity.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
. "${CNTOOLS_ROOT}/core/health.sh"
for lib in number wallet wallet-material wallet-key wallet-query asset utxo transaction table \
  wallet-history wallet-utxo-local wallet-history-ui wallet-selection key-crypto \
  wallet-protection wallet-protection-ui funds-send-ui public-metadata pool-id pool pool-health \
  drep-id governance-voting-stats wallet-delegation-info; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_run_command() { shift 2; "$@"; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_text_style_into() { printf -v "$1" '%s' "$3"; }
cntools_ui_table() { cat; }
cntools_ui_render_status() { printf '%s: %s\n' "$1" "$2"; }
cntools_ui_wait() { :; }
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_TIMEZONE=UTC
CNTOOLS_MODE=local CNTOOLS_KOIOS_API=https://example.invalid/api/v1 CNTOOLS_KOIOS_ENABLED=Y
CNTOOLS_LOCAL_CLI_CAPABLE=false CNTOOLS_CLI=/usr/bin/true CNTOOLS_UI_COLUMNS=180
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey
CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
CNTOOLS_WALLET_DERIVATION_PATH_FILENAME=derivation.path
file_mode() { stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
mkdir -p "${CNTOOLS_WALLET_DIR}/Hardware" "${CNTOOLS_WALLET_DIR}/Public"
printf '%s' '{"type":"fixture hardware public reference"}' > "${CNTOOLS_WALLET_DIR}/Hardware/payment.hwsfile"
printf '%s' '{"type":"PaymentVerificationKeyShelley_ed25519"}' > "${CNTOOLS_WALLET_DIR}/Public/payment.vkey"

# Hardware/watch-only locking changes permissions, not encryption or a device.
(
  CNTOOLS_ENABLE_CHATTR=false
  cntools_wallet_protection_immutable_files_into() { local -n result="$1"; result=(); }
  for directory in "${CNTOOLS_WALLET_DIR}/Hardware" "${CNTOOLS_WALLET_DIR}/Public"; do
    cntools_wallet_protection_lock_only "${directory}" || fail 'public wallet rejected'
    cntools_wallet_protection_lock_files "${directory}" encrypt || fail 'file locking'
    eq "${CNTOOLS_WALLET_PROTECTION_KEYS}" 0 'lock-only claims encryption'
    eq "${CNTOOLS_WALLET_PROTECTION_FILES}" 1 'public file not locked'
    for file in "${directory}"/*; do eq "$(file_mode "${file}")" 400; done
    cntools_wallet_protection_lock_files "${directory}" decrypt || fail 'file unlocking'
    for file in "${directory}"/*; do eq "$(file_mode "${file}")" 600; done
  done
  printf 'secret' > "${CNTOOLS_WALLET_DIR}/Public/unknown.skey"
  if cntools_wallet_protection_lock_only "${CNTOOLS_WALLET_DIR}/Public"; then fail 'unknown private key silently locked'; fi
)

# Optional Send change selection cannot change the funding address scope.
(
  CNTOOLS_SEND_ADDRESS=addr_base CNTOOLS_SEND_PAYMENT=addr_payment CNTOOLS_SEND_CHOOSE_CHANGE=N
  cntools_ui_choose() { fail 'change prompt without opt-in'; }
  cntools_send_choose_change; eq "${CNTOOLS_SEND_CHANGE_ADDRESS}" addr_base
  CNTOOLS_SEND_CHOOSE_CHANGE=Y
  cntools_ui_choose() { printf -v "$1" '%s' 'Payment-only address'; }
  cntools_send_choose_change; eq "${CNTOOLS_SEND_CHANGE_ADDRESS}" addr_payment
  eq "${CNTOOLS_SEND_ADDRESS}" addr_base; eq "${CNTOOLS_SEND_PAYMENT}" addr_payment
  cntools_ui_choose() { printf -v "$1" '%s' 'Primary / base address (default)'; }
  cntools_send_choose_change; eq "${CNTOOLS_SEND_CHANGE_ADDRESS}" addr_base
  CNTOOLS_SEND_PAYMENT=addr_base
  cntools_ui_choose() { fail 'single address change prompt'; }
  cntools_send_choose_change
)

# Suitability is an advisory bulk check; unknown state stays selectable.
(
  CNTOOLS_WALLET_PATHS=("${CNTOOLS_WALLET_DIR}/Public") CNTOOLS_WALLET_TYPES=(CLI)
  printf '{}' > "${CNTOOLS_WALLET_DIR}/Public/stake.vkey"
  cntools_wallet_read_address() { printf -v "$3" '%s' stake_fixture; }
  calls=0 fault=N
  cntools_wallet_query_http() {
    calls=$((calls+1)); [[ "${fault}" != Y ]] || return 22
    eq "$1" "${CNTOOLS_KOIOS_API}/account_info"
    jq -e '._stake_addresses == ["stake_fixture"]' <<< "$2" >/dev/null || fail 'wrong account batch'
    printf '%s' '[{"stake_address":"stake_fixture","status":"registered","rewards_available":"1234567"}]' > "$3"
  }
  cntools_wallet_selection_collect register; eq "${calls}" 1
  if cntools_wallet_selection_candidate_into annotation 0 register; then fail 'registered wallet offered'; fi
  cntools_wallet_selection_candidate_into annotation 0 withdraw
  [[ "${annotation}" == *'1.234567 ADA'* ]] || fail 'reward annotation'
  cntools_wallet_selection_collect withdraw; eq "${calls}" 1 'cached lookup'
  CNTOOLS_SELECTION_CHECKED=0 fault=Y
  cntools_wallet_selection_collect register
  cntools_wallet_selection_candidate_into annotation 0 register || fail 'unknown state hidden'
  eq "${annotation}" 'Stake status checked after selection'
  CNTOOLS_WALLET_TYPES=(MultiSig)
  CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script
  printf '{}' > "${CNTOOLS_WALLET_DIR}/Public/payment.script"
  printf '{}' > "${CNTOOLS_WALLET_DIR}/Public/stake.script"
  for action in register deregister delegate vote-delegate withdraw send collect; do
    cntools_wallet_selection_candidate_into annotation 0 "${action}" || fail "script wallet excluded from ${action}"
  done
  ! cntools_wallet_selection_candidate_into annotation 0 drep-register || fail 'multisig DRep lifecycle enabled'
  CNTOOLS_SELECTION_REGISTERED[stake_fixture]=yes
  ! cntools_wallet_selection_candidate_into annotation 0 register || fail 'registered script wallet offered'
  CNTOOLS_SELECTION_REWARDS[stake_fixture]=0
  ! cntools_wallet_selection_candidate_into annotation 0 withdraw || fail 'zero reward script wallet offered'
  rm "${CNTOOLS_WALLET_DIR}/Public/stake.script"
  ! cntools_wallet_selection_candidate_into annotation 0 delegate || fail 'payment-only script wallet offered for delegation'
  cntools_wallet_selection_candidate_into annotation 0 send || fail 'payment-only script wallet excluded from send'
  CNTOOLS_MODE=offline
  cntools_wallet_selection_collect register
  eq "${#CNTOOLS_SELECTION_REGISTERED[@]}" 0 'online annotations retained offline'
)
(
  CNTOOLS_WALLET_PATHS=() calls=0
  for ((i=0;i<205;i++)); do CNTOOLS_WALLET_PATHS+=("${TEST_ROOT}/${i}"); done
  cntools_wallet_read_address() { printf -v "$3" '%s' "stake_${1##*/}"; }
  cntools_wallet_query_http() {
    calls=$((calls+1)); count="$(jq '._stake_addresses|length' <<< "$2")"
    ((count <= 100)) || fail 'oversized suitability batch'
    printf '[]' > "$3"
  }
  cntools_wallet_selection_collect register
  eq "${calls}" 3; eq "${#CNTOOLS_SELECTION_REGISTERED[@]}" 205
)

# Local UTxO fallback preserves both addresses and large asset quantities.
(
  CNTOOLS_LOCAL_CLI_CAPABLE=true CNTOOLS_SOCKET=/fixture.socket
  cntools_wallet_query_local_socket_ready() { return 0; }
  cntools_wallet_read_address() { printf -v "$3" '%s' "addr_$2"; }
  policy="$(printf 'ab%.0s' {1..28})" tx="$(printf 'cd%.0s' {1..32})"
  cntools_wallet_query_run_cli() {
    [[ "$*" == *'--address addr_base'* && "$*" == *'--address addr_payment'* && "$*" == *'--socket-path /fixture.socket'* ]] || fail 'wrong local UTxO scope'
    jq -n --arg tx "${tx}" --arg policy "${policy}" '{($tx+"#0"):{address:"addr_base",datum:null,datumhash:null,
      inlineDatum:null,referenceScript:null,value:{lovelace:5000000,($policy):{"54455354":9007199254740993}}},
      ($tx+"#1"):{address:"addr_payment",datum:null,datumhash:null,inlineDatum:null,referenceScript:null,value:{lovelace:1000000}}}' > "$1"
  }
  cntools_history_load_local "${CNTOOLS_WALLET_DIR}/Public" || fail 'local UTxO fallback'
  eq "${CNTOOLS_HISTORY_BACKEND}" local; eq "${CNTOOLS_HISTORY_TOTAL}" 2
  eq "$(jq -r '.[0].asset_list[0].quantity' "${CNTOOLS_HISTORY_LIST}")" 9007199254740993
  cntools_history_page_size ''; cntools_history_page_load 0; cntools_history_detail_load 1
  rows="$(cntools_history_overview_rows)"
  [[ "${rows}" == *'Local node'* && "${rows}" != *'Koios API'* ]] || fail 'fallback provenance'
  rows="$(cntools_history_summary_rows "$(jq -c '.[0]' "${CNTOOLS_HISTORY_LIST}")")"
  [[ "${rows}" != *'Date'* && "${rows}" != *'Block'* ]] || fail 'invented local block data'
  CNTOOLS_MODE=offline
  if cntools_history_local_available; then fail 'local query permitted offline'; fi
)

# Koios is preferred even in local mode; runtime errors trigger local fallback.
(
  CNTOOLS_LOCAL_CLI_CAPABLE=true CNTOOLS_SOCKET=/fixture.socket
  cntools_wallet_query_local_socket_ready() { return 0; }
  cntools_wallet_catalog_build() { CNTOOLS_WALLET_NAMES=(Public); CNTOOLS_WALLET_PATHS=("${CNTOOLS_WALLET_DIR}/Public"); }
  cntools_wallet_choose() { printf -v "$1" '%s' 0; }
  cntools_wallet_prepare_selected_material() { :; }
  cntools_wallet_id_read_credential() { printf -v "$3" '%s' "$(printf 'ab%.0s' {1..28})"; }
  cntools_wallet_read_address() { printf -v "$3" '%s' stake_fixture; }
  cntools_ui_input() { printf -v "$1" '%s' ''; }
  cntools_ui_action_begin() { :; }
  cntools_ui_choose() {
    if [[ "$2" == 'Look up by' ]]; then printf -v "$1" '%s' "$3"
    else printf -v "$1" '%s' Back; fi
  }
  printf '[]' > "${TEST_ROOT}/empty-inventory"
  api_calls=0 local_calls=0 fault=N
  cntools_history_load() {
    api_calls=$((api_calls+1)); [[ "${fault}" != Y ]] || return 22
    CNTOOLS_HISTORY_LIST="${TEST_ROOT}/empty-inventory" CNTOOLS_HISTORY_TOTAL=0
    CNTOOLS_HISTORY_BACKEND=koios CNTOOLS_HISTORY_LOOKUP=payment CNTOOLS_HISTORY_KIND=utxos
    CNTOOLS_HISTORY_PAGE=0 CNTOOLS_HISTORY_PAGES=()
  }
  cntools_history_load_local() {
    local_calls=$((local_calls+1))
    CNTOOLS_HISTORY_LIST="${TEST_ROOT}/empty-inventory" CNTOOLS_HISTORY_TOTAL=0
    CNTOOLS_HISTORY_BACKEND=local CNTOOLS_HISTORY_LOOKUP=addresses CNTOOLS_HISTORY_KIND=utxos
    CNTOOLS_HISTORY_PAGE=0 CNTOOLS_HISTORY_PAGES=()
  }
  cntools_history_action utxos > "${TEST_ROOT}/history-ui"
  eq "${api_calls}" 1; eq "${local_calls}" 0 'local startup displaced Koios'
  fault=Y
  cntools_history_action utxos > "${TEST_ROOT}/history-ui"
  eq "${api_calls}" 2; eq "${local_calls}" 1; eq "${CNTOOLS_HISTORY_BACKEND}" local
  CNTOOLS_KOIOS_ENABLED=N
  cntools_history_action utxos > "${TEST_ROOT}/history-ui"
  eq "${api_calls}" 2; eq "${local_calls}" 2
)

# Persistent custom TTL accepts defaults and comma-separated seconds.
(
  . "${CNTOOLS_ROOT}/modules/root/settings/transaction-defaults/action.sh"
  cntools_ui_input() { printf -v "$1" '%s' ''; }
  cntools_settings_action_input_integer duration Seconds 1800 0 31536000
  eq "${duration}" 1800
  cntools_ui_input() { printf -v "$1" '%s' 31,536,000; }
  cntools_settings_action_input_integer duration Seconds 1800 0 31536000
  eq "${duration}" 31536000
  cntools_ui_input() { printf -v "$1" '%s' 0; }
  cntools_settings_action_input_integer duration Seconds 1800 0 31536000
  eq "${duration}" 0
)

# Public anchors never receive Koios credentials and are hashed as exact bytes.
(
  hash="$(printf 'ef%.0s' {1..32})" calls=0
  cntools_api_request() {
    eq "$1" GET; calls=$((calls+1))
    [[ "$*" != *Authorization* && "$*" != *Bearer* && "$*" != *secret-token* ]] || fail 'public metadata credentials leak'
    [[ "$*" == *'--max-filesize 262144'* && "$*" == *'--proto-redir =https'* ]] || fail 'unsafe/unbounded fetch'
    printf '%s' '{"name":"Example"}' > "$3"
  }
  cntools_wallet_query_run_cli() {
    [[ "$*" == *'hash anchor-data --file-binary'* ]] || fail 'wrong byte hashing'
    printf '%s\n' "${hash}" > "$1"
  }
  CNTOOLS_KOIOS_TOKEN=secret-token
  cntools_public_metadata_fetch https://example.invalid/anchor "${hash}" || fail 'matching metadata hash'
  eq "${CNTOOLS_PUBLIC_METADATA_HASH}" "${hash}"
  status=0
  cntools_public_metadata_fetch https://example.invalid/anchor "$(printf 'aa%.0s' {1..32})" || status=$?
  eq "${status}" 3 'mismatching metadata accepted'
  cid="$(printf 'a%.0s' {1..46})"
  cntools_public_metadata_fetch "ipfs://${cid}/metadata.json" "${hash}"
  before="${calls}"
  if cntools_public_metadata_fetch "ipfs://${cid}/.."; then fail 'IPFS traversal'; fi
  eq "${calls}" "${before}"
  CNTOOLS_MODE=offline
  if cntools_public_metadata_fetch https://example.invalid/anchor; then fail 'offline metadata fetch'; fi
)

# Weighted snapshots are type-bound and cached; thresholds remain advisory.
(
  calls=0 fault=N record='{"id":"gov_action1fixture","type":"NoConfidence"}'
  cntools_wallet_query_http() {
    calls=$((calls+1)); eq "$5" GET
    [[ "$1" == *'proposal_voting_summary?_proposal_id=gov_action1fixture' ]] || fail 'wrong voting endpoint'
    printf '%s' '[{"proposal_type":"NoConfidence","epoch_no":100,"drep_yes_vote_power":"1234000000","drep_yes_pct":75,"drep_yes_votes_cast":3}]' > "$3"
    [[ "${fault}" != Y ]] || printf '%s' '[{"proposal_type":"NoConfidence","epoch_no":100,"drep_yes_pct":101}]' > "$3"
  }
  cntools_voting_stats_collect "${record}"; cntools_voting_stats_collect "${record}"
  eq "${calls}" 1 'voting snapshot cache'
  CNTOOLS_VOTING_PROTOCOL='{"dRepVotingThresholds":{"motionNoConfidence":0.67},"poolVotingThresholds":{"motionNoConfidence":0.51}}'
  rows="$(cntools_voting_stats_render "${record}")"
  [[ "${rows}" == *'1,234.000000 ADA voting power'* && "${rows}" == *'75 %'* && "${rows}" == *'67 %'* ]] || fail 'weighted display/thresholds'
  fault=Y CNTOOLS_VOTING_STATS=()
  cntools_voting_stats_collect "${record}"; eq "${CNTOOLS_VOTING_STATS[gov_action1fixture]}" '{}'
  CNTOOLS_VOTING_PROTOCOL='{"dRepVotingThresholds":{"ppEconomicGroup":0.5,"ppTechnicalGroup":0.75},"poolVotingThresholds":{"ppSecurityGroup":0.51}}'
  rows="$(cntools_voting_thresholds '{"type":"ParameterChange","action":{"contents":[null,{"txFeeFixed":1,"costModels":{}}]}}')"
  [[ "${rows}" == *'75 %'* && "${rows}" == *'51 %'* ]] || fail 'parameter/security thresholds'
  rows="$(cntools_voting_thresholds '{"type":"ParameterChange","action":{"contents":[null,{"futureUnknown":1}]}}')"
  [[ "${rows}" == *Unavailable* ]] || fail 'invented unknown threshold'
  CNTOOLS_VOTING_COMMITTEE='{"threshold":{"numerator":2,"denominator":3}}'
  rows="$(cntools_voting_thresholds '{"type":"NewConstitution"}')"
  [[ "${rows}" == *'Committee quorum'*'66.67 %'* ]] || fail 'local rational quorum'
)
cntools_wallet_query_cleanup
printf 'CNTools feature-parity regression tests passed.\n'
