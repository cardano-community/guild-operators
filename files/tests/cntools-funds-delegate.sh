#!/usr/bin/env bash
# Delegation identity, backend validation, cancellation and state-change guards.
# Sourced functions are intentionally replaced by mocks after their unit tests.
# shellcheck disable=SC1090,SC2034,SC2154,SC2218,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-delegate.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number transaction wallet-register pool-id pool-query funds-delegate funds-delegate-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: $1 != $2"; }
cntools_log() { :; }
hex=f9dca21a6c826ec8acb4cf395cbc24351937bfe6560b2683ab8b415f
pool=pool1l8w2yxnvsfhv3t95euu4e0pyx5vn00lx2c9jdqat3dq47avj9qx
cntools_pool_id_into bech raw "  ${pool}  " || fail 'valid pool ID rejected'
eq "${raw}" "${hex}" 'pinned CLI identity vector'; eq "${bech}" "${pool}" 'canonical ID'
cntools_pool_id_into bech raw "${hex^^}" || fail 'hex ID rejected'; eq "${bech}" "${pool}" 'hex normalization'
for bad in "${pool%?}p" "${pool^^}" 'pool1abc' "${hex}00" "${pool}"$'\nBAD' "pool1$(printf 'q%.0s' {1..51})"; do
  if cntools_pool_id_into bech raw "${bad}"; then fail 'invalid ID accepted'; fi
done
cntools_wallet_register_operation_set delegate
CNTOOLS_WALLET_REGISTERED=no CNTOOLS_WALLET_POOL_DELEGATION=''
cntools_delegate_chain_state_validate; eq "${CNTOOLS_DELEGATE_REGISTER}" Y 'registration required'
CNTOOLS_WALLET_REGISTERED=yes CNTOOLS_WALLET_POOL_DELEGATION="${hex}"
cntools_delegate_chain_state_validate; eq "${CNTOOLS_DELEGATE_REGISTER}" N 'no repeat deposit'
eq "${CNTOOLS_DELEGATE_CURRENT_POOL}" "${pool}" 'existing pool normalization'
CNTOOLS_WALLET_REGISTERED=unknown
if cntools_delegate_chain_state_validate; then fail 'unknown registration accepted'; fi
CNTOOLS_DELEGATE_REGISTER=Y CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=N
CNTOOLS_DELEGATE_POOL_ID="${pool}" CNTOOLS_DELEGATE_POOL_HEX="${hex}"
if cntools_delegate_certificate_create; then fail 'registration without consent'; fi

response="${TEST_ROOT}/pool.json"
jq -n --arg hex "${hex}" '{($hex):{poolParams:{id:$hex},futurePoolParams:null,retiring:null}}' > "${response}"
cntools_pool_parse_local "${response}" "${pool}" "${hex}" || fail 'local pool rejected'
eq "${CNTOOLS_POOL_STATUS}" registered 'local active pool'
jq -n --arg hex "${hex}" '{($hex):{poolParams:{id:$hex},futurePoolParams:null,retiring:42}}' > "${response}"
cntools_pool_parse_local "${response}" "${pool}" "${hex}"; eq "${CNTOOLS_POOL_RETIRING}" 42 'local retirement'
for invalid in '{}' '[]' '{"wrong":{"poolParams":{},"retiring":null}}'; do
  printf '%s' "${invalid}" > "${response}"
  if cntools_pool_parse_local "${response}" "${pool}" "${hex}"; then fail 'invalid local pool accepted'; fi
done
koios="$(jq -cn --arg hex "${hex}" --arg pool "${pool}" '[{pool_id_hex:$hex,pool_id_bech32:$pool,pool_status:"registered",retiring_epoch:null,meta_json:{name:"Example",ticker:"EX"}}]')"
printf '%s' "${koios}" > "${response}"
cntools_pool_parse_koios "${response}" "${pool}" "${hex}" || fail 'Koios pool rejected'
eq "${CNTOOLS_POOL_NAME}" Example 'pool metadata'
for mutation in '. + .' '.[0].pool_status="retired"' '.[0].pool_id_hex="wrong"' '.[0].pool_status="retiring"' '.[0].retiring_epoch=-1' '[]'; do
  jq "${mutation}" <<< "${koios}" > "${response}"
  if cntools_pool_parse_koios "${response}" "${pool}" "${hex}"; then fail "bad Koios accepted: ${mutation}"; fi
done
jq '.[0].pool_status="retiring" | .[0].retiring_epoch=42' <<< "${koios}" > "${response}"
cntools_pool_parse_koios "${response}" "${pool}" "${hex}"; eq "${CNTOOLS_POOL_RETIRING}" 42 'Koios retirement'

# Backend routing uses one exact pool ID; a local query failure is not hidden.
(
  CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1 CNTOOLS_NETWORK=preview CNTOOLS_CLI=fixture CNTOOLS_SOCKET=/fixture.socket
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_transaction_network_arguments_into() { local -n args="$1"; args=(--testnet-magic 2); }
  cntools_wallet_query_http() {
    eq "$1" https://koios.invalid/api/v1/pool_info 'pool endpoint'
    eq "$(jq -r '._pool_bech32_ids | join(",")' <<< "$2")" "${pool}" 'exact pool request'
    printf '%s' "${koios}" > "$3"
  }
  cntools_transaction_run_cli() {
    [[ "$*" == *"latest query pool-state --stake-pool-id ${pool} --testnet-magic 2 --socket-path /fixture.socket --output-json" ]] || fail 'local pool query arguments'
    jq -n --arg hex "${hex}" '{($hex):{poolParams:{id:$hex},retiring:null}}' > "$1"
  }
  cntools_pool_query "${pool}" "${hex}" koios || fail 'Koios routing'
  eq "${CNTOOLS_POOL_SOURCE}" 'Koios API' 'Koios provenance'
  cntools_pool_query "${pool}" "${hex}" local || fail 'local routing'
  eq "${CNTOOLS_POOL_SOURCE}" 'Local node' 'local provenance'
)

# Body review binds the stake key and target, not only the descriptive intent.
(
  CNTOOLS_DELEGATE_REGISTER=N CNTOOLS_WALLET_REGISTER_DEPOSIT=0 CNTOOLS_WALLET_REGISTER_FEE=1000
  CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL="${hex}" CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=base
  original="$(jq -cn --arg pool "${hex}" '{fee:"1000 Lovelace",certificates:[{"Stake address delegation":{"stake credential":{keyHash:$pool},delegatee:{"delegatee type":"stake","key hash":$pool}}}],outputs:[{address:"base"}]}')"
  decoded="${original}"
  cntools_transaction_view_into() { printf -v "$1" '%s' "${decoded}"; }
  cntools_delegate_validate_body fixture || fail 'valid delegation body rejected'
  for mutation in '.fee="2000 Lovelace"' '.outputs[0].address="other"' '.certificates[0]["Stake address delegation"].delegatee["delegatee type"]="stake vote"' '.certificates[0]["Stake address delegation"].delegatee["key hash"]="other"' '.certificates += .certificates' '.withdrawals=[{}]'; do
    decoded="$(jq "${mutation}" <<< "${original}")"
    if cntools_delegate_validate_body fixture; then fail "body mutation accepted: ${mutation}"; fi
  done
)

# Standalone registration shares balancing but must accept only its own certificate.
(
  CNTOOLS_WALLET_REGISTER_OPERATION=register
  CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000 CNTOOLS_WALLET_REGISTER_FEE=1000
  CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL="${hex}" CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=base
  original="$(jq -cn --arg stake "${hex}" '{fee:"1000 Lovelace",certificates:[{"Stake address registration":{"stake credential":{keyHash:$stake},deposit:2000000}}],outputs:[{address:"base"}]}')"
  decoded="${original}"
  cntools_transaction_view_into() { printf -v "$1" '%s' "${decoded}"; }
  cntools_wallet_register_validate_body fixture || fail 'valid registration body rejected'
  for mutation in '.fee="2000 Lovelace"' '.outputs[0].address="other"' '.certificates[0]["Stake address registration"].deposit=4000000' '.certificates[0]["Stake address registration"]["stake credential"].keyHash="other"' '.certificates += .certificates' '.withdrawals=[{}]' '.mint={}' '.metadata={}' '.certificates=[]'; do
    decoded="$(jq "${mutation}" <<< "${original}")"
    if cntools_wallet_register_validate_body fixture; then fail "registration mutation accepted: ${mutation}"; fi
  done
  CNTOOLS_WALLET_REGISTER_OPERATION=register
  CNTOOLS_COIN_SELECTED_INDICES=(0)
  CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT=(Y)
  rejected=""
  if cntools_wallet_register_build_balanced_into rejected; then fail 'reference script input accepted'; fi
  [[ "${CNTOOLS_WALLET_REGISTER_ERROR}" == *'reference script'* ]] || fail 'missing reference-script explanation'
)

# Deregistration validates the refund and both collectors use the historical deposit.
(
  cntools_wallet_register_operation_set deregister
  CNTOOLS_WALLET_REGISTER_DEPOSIT=2345678 CNTOOLS_WALLET_REGISTER_FEE=1000
  CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL="${hex}" CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=base
  original="$(jq -cn --arg stake "${hex}" '{fee:"1000 Lovelace",certificates:[{"Stake address deregistration":{"stake credential":{keyHash:$stake},refund:2345678}}],outputs:[{address:"base"}]}')"
  decoded="${original}"
  cntools_transaction_view_into() { printf -v "$1" '%s' "${decoded}"; }
  cntools_wallet_register_validate_body fixture || fail 'valid deregistration body rejected'
  for mutation in '.certificates[0]["Stake address deregistration"].refund=2000000' '.certificates[0]["Stake address deregistration"].refund=4691356' 'del(.certificates[0]["Stake address deregistration"].refund)' '.certificates[0]["Stake address deregistration"]["stake credential"].keyHash="other"' '.outputs[0].address="other"' '.withdrawals=[{}]' '.certificates=[{"Stake address registration":{}}]'; do
    decoded="$(jq "${mutation}" <<< "${original}")"
    if cntools_wallet_register_validate_body fixture; then fail "deregistration mutation accepted: ${mutation}"; fi
  done

  # Both collectors must replace today's protocol deposit with the recorded refund.
  cntools_wallet_query_network_arguments() { :; }
  cntools_wallet_query_local_stake() {
    CNTOOLS_WALLET_REGISTERED=yes CNTOOLS_WALLET_REWARD_LOVELACE=0 CNTOOLS_WALLET_STAKE_DEPOSIT=2345678
  }
  cntools_wallet_query_koios_stake() { cntools_wallet_query_local_stake; }
  cntools_wallet_register_protocol_local() { CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000; }
  cntools_wallet_register_protocol_koios() { cntools_wallet_register_protocol_local; }
  cntools_wallet_register_utxos_local() { :; }
  cntools_wallet_register_utxos_koios() { :; }
  cntools_wallet_register_funding_validate() { :; }
  cntools_wallet_register_select_inputs() { eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 2345678 'recorded refund survives protocol fetch'; }
  CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
  cntools_wallet_register_collect_local || fail 'local historical refund'
  cntools_wallet_register_collect_koios || fail 'Koios historical refund'
)

# Local pool discovery honors configured public filenames and ignores links.
(
  CNTOOLS_POOL_DIR="${TEST_ROOT}/pools" CNTOOLS_POOL_ID_FILENAME=custom.id CNTOOLS_POOL_COLD_VKEY_FILENAME=custom.vkey
  CNTOOLS_CLI=fixture
  mkdir -p "${CNTOOLS_POOL_DIR}/Example"
  printf '%s' "${hex}" > "${CNTOOLS_POOL_DIR}/Example/custom.id"
  ln -s "${CNTOOLS_POOL_DIR}/Example" "${CNTOOLS_POOL_DIR}/Linked"
  cntools_ui_choose() {
    [[ "$*" != *Linked* ]] || fail 'symlink pool offered'
    printf -v "$1" '%s' Example
  }
  cntools_delegate_pool_local_into chosen || fail 'stored local pool ID rejected'
  eq "${chosen}" "${hex}" 'custom pool ID filename'
  printf '{}' > "${CNTOOLS_POOL_DIR}/Example/custom.vkey"
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_transaction_run_cli() {
    [[ "$*" == *"--cold-verification-key-file ${CNTOOLS_POOL_DIR}/Example/custom.vkey --output-bech32" ]] || fail 'wrong local key command'
    printf '%s' "${pool}" > "$1"
  }
  cntools_delegate_pool_local_into chosen || fail 'local public key rejected'
  eq "${chosen}" "${pool}" 'public key takes precedence over cached ID'
)

# Recheck failures must not modify the approved identity or build a new body.
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=base CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=payment CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS=reward
CNTOOLS_WALLET_REGISTER_INPUTS=(input) CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_EXPIRY=2000
CNTOOLS_DELEGATE_CURRENT_POOL='' CNTOOLS_DELEGATE_REGISTER=N CNTOOLS_DELEGATE_RETIRING=''
declare -A CNTOOLS_UTXO_INDEX_BY_REF=()
cntools_funding_collect() {
  CNTOOLS_FUNDING_BACKEND=koios CNTOOLS_FUNDING_SLOT="${SLOT}" CNTOOLS_FUNDING_PROTOCOL=fixture
  CNTOOLS_UTXO_INDEX_BY_REF=(); [[ "${SPENT}" == Y ]] || CNTOOLS_UTXO_INDEX_BY_REF[input]=0
}
cntools_wallet_query_reset() { CNTOOLS_WALLET_POOL_DELEGATION=''; }
cntools_wallet_query_koios_stake() { CNTOOLS_WALLET_REGISTERED="${REGISTERED}"; CNTOOLS_WALLET_POOL_DELEGATION="${CURRENT}"; }
cntools_pool_query() { CNTOOLS_POOL_RETIRING="${RETIRING}"; return "${POOL_STATUS}"; }
SLOT=1000 SPENT=N REGISTERED=yes CURRENT='' RETIRING='' POOL_STATUS=0
cntools_delegate_recheck || fail 'unchanged state rejected'
for change in expired spent registered current retired retirement; do
  (
    case "${change}" in
      expired) SLOT=2000 ;; spent) SPENT=Y ;; registered) REGISTERED=no ;;
      current) CURRENT="${pool}" ;; retired) POOL_STATUS=4 ;; retirement) RETIRING=42 ;;
    esac
    if cntools_delegate_recheck; then fail "state change accepted: ${change}"; fi
    eq "${CNTOOLS_DELEGATE_POOL_ID}" "${pool}" 'target not replaced'
  )
done
CNTOOLS_WALLET_REGISTER_EXPIRY=''; SLOT=5000
cntools_delegate_recheck || fail 'No expiry rejected'
SPENT=Y
if cntools_delegate_recheck; then fail 'No expiry bypassed input check'; fi

# UI consent and cancellation: none of these tests signs or submits.
cntools_wallet_register_begin() { :; }
cntools_transaction_ui_table_widths_into() { printf -v "$1" '%s' 22,80; }
cntools_transaction_ui_styled_row() { printf '%s\t%s\n' "$1" "$2"; }
cntools_ui_table() { cat >/dev/null; }
cntools_ui_render_status() { printf '%s\n' "$2" >> "${TEST_ROOT}/ui"; }
cntools_ui_wait() { :; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_wallet_format_lovelace() { printf '%s ADA' "$(cntools_number_format_units "$1" 6)"; }
cntools_ui_choose() { printf -v "$1" '%s' "${MENU}"; }
cntools_ui_input() { printf -v "$1" '%s' "${pool}"; }
cntools_ui_confirm() { printf '%s\n' "$1" >> "${TEST_ROOT}/questions"; return "${CONFIRM}"; }
cntools_pool_query() { CNTOOLS_POOL_STATUS=registered CNTOOLS_POOL_RETIRING='' CNTOOLS_POOL_SOURCE=fixture; }
CNTOOLS_WALLET_REGISTER_WALLET=Test CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000
CNTOOLS_DELEGATE_REGISTER=Y MENU='Enter pool ID' CONFIRM=1
status=0; cntools_delegate_choose_target || status=$?
eq "${status}" 1 'declined registration cancels'; eq "${CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED}" N 'decline retained'
CONFIRM=0
cntools_delegate_choose_target || fail 'approved registration rejected'
eq "${CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED}" Y 'registration consent recorded'
grep -q '2.000000 ADA' "${TEST_ROOT}/questions" || fail 'deposit not shown before consent'
MENU=Cancel
status=0; cntools_delegate_choose_target || status=$?; eq "${status}" 1 'cancel returns without build'
cntools_delegate_reminder
grep -q 'reward withdrawals require voting delegation' "${TEST_ROOT}/ui" || fail 'DRep reminder missing'
grep -q 'ordinary fund transfers are unaffected' "${TEST_ROOT}/ui" || fail 'reminder too broad'

# Exercise Delegate through the actual shared lifecycle orchestrator.
. "${CNTOOLS_ROOT}/lib/wallet-register-ui.sh"
cntools_ui_action_begin() { :; }
cntools_transaction_require_cli() { :; }
cntools_wallet_catalog_build() { CNTOOLS_WALLET_NAMES=(Test); CNTOOLS_WALLET_PATHS=(/fixture); }
cntools_wallet_choose() { printf -v "$1" '%s' 0; }
cntools_wallet_register_prepare_wallet() { CNTOOLS_WALLET_REGISTER_CAN_SIGN=Y; }
cntools_transaction_ui_workflow_into() { printf -v "$1" '%s' "${WORKFLOW}"; }
cntools_transaction_ui_expiry_into() { printf -v "$1" '%s' 0; }
cntools_wallet_register_collect() { :; }
cntools_delegate_choose_target() { :; }
cntools_wallet_register_build_package_into() { printf -v "$1" '%s' /staged; }
cntools_transaction_ui_proceed_into() { printf -v "$1" '%s' Proceed; }
cntools_transaction_ui_review_into() { printf -v "$1" '%s' Proceed; }
cntools_transaction_save_into() { printf -v "$1" '%s' "/saved/$3.json"; }
cntools_transaction_signed_path_into() { printf -v "$1" '%s' /signed; }
cntools_wallet_register_sign() { SIGNED=$((SIGNED+1)); }
cntools_delegate_recheck() { RECHECKS=$((RECHECKS+1)); (( RECHECKS != FAIL_RECHECK )); }
cntools_transaction_submit_input_prepare() { CNTOOLS_TRANSACTION_SIGNED_FILE=/body; CNTOOLS_TRANSACTION_SUBMIT_ID=fixture; }
cntools_transaction_ui_submission_backend_into() { printf -v "$1" '%s' koios; }
cntools_transaction_ui_confirm_submit() { :; }
cntools_transaction_ui_submit_selected() { SUBMITTED=$((SUBMITTED+1)); }
cntools_transaction_ui_offer_monitor() { :; }
cntools_transaction_ui_render_result() { :; }
cntools_transaction_ui_cancel() { :; }
cntools_delegate_reminder() { REMINDED=$((REMINDED+1)); }
CNTOOLS_LOG=fixture CNTOOLS_TRANSACTION_ID=fixture CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=Accepted
for WORKFLOW in 'Create, sign and submit' 'Create and sign' 'Create unsigned package'; do
  SIGNED=0 SUBMITTED=0 RECHECKS=0 REMINDED=0 FAIL_RECHECK=0
  cntools_funds_action_delegate || fail 'Delegate workflow failed'
  eq "${REMINDED}" 1 'completion reminder'
  case "${WORKFLOW}" in
    'Create, sign and submit') eq "${SUBMITTED}" 1 'live submit'; eq "${RECHECKS}" 2 'sign and submit rechecks' ;;
    'Create and sign') eq "${SIGNED}" 1 'sign only'; eq "${SUBMITTED}" 0 'no auto submit' ;;
    'Create unsigned package') eq "${SIGNED}" 0 'offline no signatures'; eq "${RECHECKS}" 0 'offline does not require online signing' ;;
  esac
done
for FAIL_RECHECK in 1 2; do
  WORKFLOW='Create, sign and submit' SIGNED=0 SUBMITTED=0 RECHECKS=0 REMINDED=0
  if cntools_funds_action_delegate; then fail 'failed recheck accepted'; fi
  eq "${SUBMITTED}" 0 'no submission after failed recheck'
  [[ "${FAIL_RECHECK}" != 1 ]] || eq "${SIGNED}" 0 'no signing after failed recheck'
  [[ "${FAIL_RECHECK}" != 2 ]] || eq "${CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE}" /saved/signed.json 'signed package retained'
done
printf 'CNTools delegation tests passed.\n'
