#!/usr/bin/env bash
# Governance delegation identities, exact-target queries, UI and state guards.
# No network access or real signing/submission.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-vote.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet-query transaction wallet-register drep-id drep-query governance-delegate governance-delegate-ui; do
  . "${CNTOOLS_ROOT}/lib/${lib}.sh"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_log() { :; }
hash="$(printf 'ab%.0s' {1..28})"
cntools_drep_bech32_into key_id "22${hash}"
cntools_drep_bech32_into script_id "23${hash}"
for type in key script; do
  target="${key_id}" header=22 hrp=drep
  [[ "${type}" != script ]] || { target="${script_id}"; header=23; hrp=drep_script; }
  cntools_drep_id_into id kind raw " ${target} "
  eq "${id}" "${target}"; eq "${kind}" "${type}"; eq "${raw}" "${hash}"
  cntools_drep_bech32_into legacy "${hash}" "${hrp}"
  cntools_drep_id_into id kind raw "${legacy}"
  eq "${id}" "${target}" 'legacy canonicalization'; eq "${kind}" "${type}"
done
for bad in "${key_id%?}q" "${key_id^^}" "${hash}" "22${hash}" 'drep1abc' "${key_id}"$'\nBAD'; do
  if cntools_drep_id_into id kind raw "${bad}"; then fail 'invalid or ambiguous ID accepted'; fi
done
cntools_drep_id_into id kind raw alwaysAbstain; eq "${id}" drep_always_abstain; eq "${kind}" abstain
cntools_drep_id_into id kind raw alwaysNoConfidence; eq "${kind}" no-confidence

CNTOOLS_WALLET_REGISTERED=yes CNTOOLS_WALLET_DREP_DELEGATION_VALID=Y
CNTOOLS_WALLET_DREP_DELEGATION=alwaysAbstain CNTOOLS_WALLET_POOL_DELEGATION=pool-fixture
cntools_wallet_register_operation_set vote-delegate
cntools_vote_chain_state_validate
eq "${CNTOOLS_VOTE_CURRENT}" drep_always_abstain
CNTOOLS_WALLET_REGISTERED=no
status=0; cntools_vote_chain_state_validate || status=$?; eq "${status}" 7
CNTOOLS_WALLET_REGISTERED=unknown
if cntools_vote_chain_state_validate; then fail 'unknown registration accepted'; fi
CNTOOLS_WALLET_REGISTERED=yes CNTOOLS_WALLET_DREP_DELEGATION_VALID=N
if cntools_vote_chain_state_validate; then fail 'ambiguous existing delegation accepted'; fi
CNTOOLS_WALLET_DREP_DELEGATION_VALID=Y

# Both collectors must zero the protocol stake deposit for voting-only actions.
(
  CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS=reward CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
  cntools_wallet_query_network_arguments() { :; }
  cntools_wallet_query_local_stake() { CNTOOLS_WALLET_REGISTERED=yes; }
  cntools_wallet_query_koios_stake() { CNTOOLS_WALLET_REGISTERED=yes; }
  cntools_wallet_register_protocol_local() { CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000; }
  cntools_wallet_register_protocol_koios() { CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000; }
  cntools_wallet_register_utxos_local() { :; }
  cntools_wallet_register_utxos_koios() { :; }
  cntools_wallet_register_funding_validate() { eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 0 'voting must not charge registration deposit'; }
  cntools_wallet_register_select_inputs() { :; }
  cntools_wallet_register_collect_local
  cntools_wallet_register_collect_koios
)

response="${TEST_ROOT}/state.json"
for type in key script; do
  target="${key_id}" field=keyHash
  [[ "${type}" != script ]] || { target="${script_id}"; field=scriptHash; }
  local_json="$(jq -nc --arg field "${field}" --arg hash "${hash}" '[[{($field):$hash},{expiry:42,deposit:500000000}]]')"
  printf '%s' "${local_json}" > "${response}"
  cntools_drep_parse_local "${response}" "${type}" "${hash}" || fail 'local state'
  eq "${CNTOOLS_DREP_ACTIVE}" unknown 'no guessed local activity'
  printf '%s\n%s\n' "${local_json}" "${local_json}" > "${response}"
  if cntools_drep_parse_local "${response}" "${type}" "${hash}"; then fail 'multiple local JSON documents accepted'; fi
  for mutate in '. + .' '.[0][0]={keyHash:"foreign"}' '.[0][1].expiry="bad"'; do
    jq "${mutate}" <<< "${local_json}" > "${response}"
    if cntools_drep_parse_local "${response}" "${type}" "${hash}"; then fail 'bad local state accepted'; fi
  done
  koios="$(jq -nc --arg id "${target}" --arg hash "${hash}" --arg type "${type}" \
    '[{drep_id:$id,hex:$hash,has_script:($type=="script"),drep_status:"registered",active:false}]')"
  printf '%s' "${koios}" > "${response}"
  cntools_drep_parse_koios "${response}" "${target}" "${type}" "${hash}" || fail 'inactive registered DRep rejected'
  eq "${CNTOOLS_DREP_ACTIVE}" false
  printf '%s\n%s\n' "${koios}" "${koios}" > "${response}"
  if cntools_drep_parse_koios "${response}" "${target}" "${type}" "${hash}"; then fail 'multiple Koios JSON documents accepted'; fi
  for mutate in '. + .' '.[0].drep_id="foreign"' '.[0].hex="foreign"' '.[0].has_script=(. [0].has_script|not)' '.[0].active="false"' '.[0].drep_status="unknown"'; do
    jq "${mutate}" <<< "${koios}" > "${response}"
    if cntools_drep_parse_koios "${response}" "${target}" "${type}" "${hash}"; then fail "invalid Koios accepted: ${mutate}"; fi
  done
  for mutate in '[]' '.[0].drep_status="deregistered"' '.[0].drep_status="not_registered"'; do
    jq "${mutate}" <<< "${koios}" > "${response}"
    status=0; cntools_drep_parse_koios "${response}" "${target}" "${type}" "${hash}" || status=$?
    eq "${status}" 4 'absent/retired target'
  done
done

# Logged query routing, no fallback after a local target-check failure.
(
  CNTOOLS_CLI=fixture CNTOOLS_SOCKET=/node.socket CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
  calls=0
  cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/$2"; }
  cntools_transaction_network_arguments_into() { local -n net="$1"; net=(--testnet-magic 2); }
  cntools_transaction_run_cli() {
    calls=$((calls+1))
    [[ "$*" == *"latest query drep-state --drep-script-hash ${hash} --testnet-magic 2 --socket-path /node.socket --output-json" ]] || fail 'local query argv'
    jq -nc --arg hash "${hash}" '[[{scriptHash:$hash},{expiry:42,deposit:500000000}]]' > "$1"
  }
  cntools_wallet_query_http() {
    calls=$((calls+1))
    eq "$1" "${CNTOOLS_KOIOS_API}/drep_info"
    eq "$(jq -r '._drep_ids | join(",")' <<< "$2")" "${script_id}"
    jq -nc --arg id "${script_id}" --arg hash "${hash}" '[{drep_id:$id,hex:$hash,has_script:true,drep_status:"registered",active:true}]' > "$3"
  }
  cntools_drep_query "${script_id}" script "${hash}" local
  eq "${CNTOOLS_DREP_SOURCE}" 'Local node'
  cntools_drep_query "${script_id}" script "${hash}" koios
  eq "${CNTOOLS_DREP_SOURCE}" 'Koios API'
  cntools_drep_query drep_always_abstain abstain '' koios
  eq "${calls}" 2 'predefined option makes no query'
  if cntools_drep_query "${script_id}" key "${hash}" local; then fail 'key/script mismatch'; fi
  eq "${calls}" 2 'invalid identity queried'
)

# Bind the ledger certificate exactly: target, kind, stake signer, no deposit,
# no pool change, no extra certificates or transaction effects.
(
  CNTOOLS_VOTE_KIND=script CNTOOLS_VOTE_HASH="${hash}" CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL="${hash}"
  CNTOOLS_WALLET_REGISTER_FEE=1000 CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=base
  original="$(jq -nc --arg hash "${hash}" '{fee:"1000 Lovelace",outputs:[{address:"base"}],certificates:[{"Stake address delegation":{
    "stake credential":{keyHash:$hash},delegatee:{"delegatee type":"vote",DRep:("drep-scriptHash-"+$hash)}}}]}')"
  decoded="${original}"
  cntools_transaction_view_into() { printf -v "$1" '%s' "${decoded}"; }
  cntools_vote_validate_body fixture
  for mutate in '.fee="1 Lovelace"' '.outputs[0].address="other"' '.certificates += .certificates' \
    '.certificates[0]["Stake address delegation"].deposit=0' \
    '.certificates[0]["Stake address delegation"].delegatee.DRep="drep-alwaysAbstain"' \
    '.certificates[0]["Stake address delegation"].delegatee["delegatee type"]="stake vote"' \
    '.certificates[0]["Stake address delegation"]["stake credential"].keyHash="foreign"' '.withdrawals=[{}]' '.metadata={}' '.mint={}' '.voters={"foreign":{}}' '."governance actions"=[{}]' '.treasuryDonation=1'; do
    decoded="$(jq "${mutate}" <<< "${original}")"
    if cntools_vote_validate_body fixture; then fail "body mutation accepted: ${mutate}"; fi
  done
)

# Recheck selected inputs and unchanged delegation, including inactivity that
# requires renewed consent. No expiry remains valid without an upper slot.
(
  CNTOOLS_VOTE_TARGET="${key_id}" CNTOOLS_VOTE_KIND=key CNTOOLS_VOTE_HASH="${hash}"
  CNTOOLS_VOTE_CURRENT=drep_always_abstain CNTOOLS_VOTE_CURRENT_POOL=pool-fixture
  CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=base CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=payment
  CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS=reward CNTOOLS_WALLET_REGISTER_EXPIRY=100 CNTOOLS_WALLET_REGISTER_INPUTS=(ref)
  declare -A CNTOOLS_UTXO_INDEX_BY_REF=([ref]=0)
  fault=''
  cntools_funding_collect() { CNTOOLS_FUNDING_BACKEND=koios CNTOOLS_FUNDING_SLOT=10; [[ "${fault}" != backend ]] || CNTOOLS_FUNDING_BACKEND=local; [[ "${fault}" != expired ]] || CNTOOLS_FUNDING_SLOT=100; }
  cntools_wallet_query_reset() { :; }
  cntools_wallet_query_koios_stake() {
    CNTOOLS_WALLET_REGISTERED=yes CNTOOLS_WALLET_DREP_DELEGATION=alwaysAbstain CNTOOLS_WALLET_POOL_DELEGATION=pool-fixture
    case "${fault}" in unregistered) CNTOOLS_WALLET_REGISTERED=no ;; changed) CNTOOLS_WALLET_DREP_DELEGATION=alwaysNoConfidence ;; pool) CNTOOLS_WALLET_POOL_DELEGATION=other ;; esac
  }
  cntools_drep_query() { CNTOOLS_DREP_ACTIVE=true; [[ "${fault}" != inactive ]] || CNTOOLS_DREP_ACTIVE=false; [[ "${fault}" != retired ]]; }
  cntools_vote_recheck || fail 'valid recheck'
  for fault in backend expired unregistered changed pool inactive retired; do
    if cntools_vote_recheck; then fail "state change accepted: ${fault}"; fi
  done
  fault=inactive CNTOOLS_VOTE_INACTIVE_CONFIRMED=Y
  cntools_vote_recheck || fail 'explicit inactivity consent lost'
  fault=expired CNTOOLS_WALLET_REGISTER_EXPIRY=''
  cntools_vote_recheck || fail 'no-expiry recheck'
  unset 'CNTOOLS_UTXO_INDEX_BY_REF[ref]'
  if cntools_vote_recheck; then fail 'spent input accepted'; fi
)

# Target selection cancellation, same-delegation refusal, and explicit inactive consent.
(
  CNTOOLS_WALLET_REGISTER_WALLET=Test CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_VOTE_CURRENT=drep_always_abstain
  selection=Cancel choices=0 confirmation=1 queries=0
  cntools_wallet_register_begin() { :; }
  cntools_transaction_ui_table_widths_into() { printf -v "$1" '%s' '26,64'; }
  cntools_transaction_ui_styled_row() { :; }
  cntools_ui_table() { cat >/dev/null; }
  cntools_ui_render_status() { :; }
  cntools_ui_wait() { :; }
  cntools_ui_choose() { choices=$((choices+1)); if ((choices>1)); then printf -v "$1" Cancel; else printf -v "$1" '%s' "${selection}"; fi; }
  cntools_ui_input() { printf -v "$1" '%s' "${key_id}"; }
  cntools_ui_confirm() { eq "$2" false 'inactive consent default'; return "${confirmation}"; }
  cntools_ui_spin_function() { shift; "$@"; }
  cntools_drep_query() { queries=$((queries+1)); CNTOOLS_DREP_ACTIVE=false; }
  status=0; cntools_vote_choose_target || status=$?; eq "${status}" 1; eq "${queries}" 0
  choices=0 selection='Always Abstain'
  status=0; cntools_vote_choose_target || status=$?; eq "${status}" 1; eq "${queries}" 0 'same delegation never queried'
  choices=0 selection='Specific DRep'
  status=0; cntools_vote_choose_target || status=$?; eq "${status}" 1; eq "${CNTOOLS_VOTE_INACTIVE_CONFIRMED}" N
  choices=0 confirmation=0
  cntools_vote_choose_target; eq "${CNTOOLS_VOTE_INACTIVE_CONFIRMED}" Y
)
printf 'CNTools governance delegation tests passed\n'
