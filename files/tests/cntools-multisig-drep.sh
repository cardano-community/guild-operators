#!/usr/bin/env bash
# Threshold/DRep role isolation, stale-state and prior-vote contracts.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
. "${REPO_ROOT}/files/tests/fixtures/cntools-wallet-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-ms-drep-ui.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet-query-transport wallet-query-local asset-metadata wallet-query-koios wallet-list-query asset-view wallet-view wallet-query transaction wallet-register drep-id drep-query governance-drep governance-proposal governance-vote multisig-spend multisig-drep; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_log() { :; }
hash="$(printf 'ab%.0s' {1..28})" keyid="$(printf 'ab%.0s' {1..32})"
CNTOOLS_DREP_LIFECYCLE_KIND=script CNTOOLS_DREP_LIFECYCLE_HASH="${hash}" CNTOOLS_DREP_LIFECYCLE_ID=drep1fixture
CNTOOLS_MULTISIG_DREP_SCRIPT=/public/drep.script CNTOOLS_MULTISIG_DREP_THRESHOLD=2
CNTOOLS_MULTISIG_SPEND_SCRIPT=/public/payment.script CNTOOLS_MULTISIG_SPEND_THRESHOLD=1
CNTOOLS_MULTISIG_SIGNER_IDS=(payment-id) CNTOOLS_MULTISIG_SIGNER_HASHES=(payment-hash)
CNTOOLS_MULTISIG_SIGNER_SOURCES=(/private/payment.skey) CNTOOLS_MULTISIG_SIGNER_LABELS=(Payment)
CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=/private/payment.skey CNTOOLS_WALLET_REGISTER_WALLET_TYPE=CLI
(
  scenario=cancel
  cntools_multisig_spend_choose_signers() {
    [[ "$2" == drep && "${CNTOOLS_MULTISIG_SPEND_SCRIPT}" == /public/drep.script ]] || fail 'DRep role not isolated'
    CNTOOLS_MULTISIG_SIGNER_IDS=("${keyid}") CNTOOLS_MULTISIG_SIGNER_HASHES=("${hash}")
    CNTOOLS_MULTISIG_SIGNER_SOURCES=('') CNTOOLS_MULTISIG_SIGNER_LABELS=(External)
    [[ "${scenario}" != cancel ]] || return 1
  }
  if cntools_multisig_drep_choose_signers; then fail 'cancel ignored'; fi
  [[ "${CNTOOLS_MULTISIG_SIGNER_IDS[*]}:${CNTOOLS_MULTISIG_SPEND_SCRIPT}" == payment-id:/public/payment.script ]] || fail 'cancel overwrote payment subset'
  scenario=success
  cntools_multisig_drep_choose_signers
  [[ "${CNTOOLS_MULTISIG_DREP_IDS[*]}" == "${keyid}" && "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" == N ]] || fail 'public-only DRep offered direct signing'
  [[ "${CNTOOLS_MULTISIG_SIGNER_IDS[*]}" == payment-id && "${CNTOOLS_MULTISIG_SPEND_THRESHOLD}" == 1 ]] || fail 'DRep selection corrupted payment state'
)
CNTOOLS_MULTISIG_DREP_AFTER=150 CNTOOLS_MULTISIG_DREP_BEFORE=15000
CNTOOLS_MULTISIG_SPEND_AFTER=100 CNTOOLS_MULTISIG_SPEND_BEFORE=20000
CNTOOLS_WALLET_REGISTER_WALLET_TYPE=MultiSig
expiry=''; cntools_transaction_plan_reset test '' exact
cntools_multisig_drep_validity expiry 1000 || fail 'interval intersection'
[[ "${expiry}:${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" == 15000:150 ]] || fail 'No expiry bypassed script bounds'
expiry=12000; cntools_multisig_drep_validity expiry 1000; [[ "${expiry}" == 12000 ]] || fail 'user TTL overridden'
expiry=''; if cntools_multisig_drep_validity expiry 149; then fail 'future script accepted'; fi
expiry=''; if cntools_multisig_drep_validity expiry 15000; then fail 'expired script accepted'; fi

# Key and script voters are distinct even if their 28-byte hashes are equal.
CNTOOLS_PROPOSAL_BACKEND=local
record="$(jq -cn --arg hash "${hash}" '{votes:{("scriptHash-"+$hash):"VoteYes",("keyHash-"+$hash):"VoteNo"}}')"
cntools_gov_vote_previous_into previous "${record}"; [[ "${previous}" == '"VoteYes"' ]] || fail 'local script previous vote'
CNTOOLS_PROPOSAL_BACKEND=koios
cntools_transaction_temp_file() { printf -v "$1" '%s' "${TEST_ROOT}/response"; }
response_script=true
cntools_wallet_query_http() {
  [[ "$1" == *voter_has_script=eq.true ]] || fail 'Koios did not filter script voters'
  jq -cn --arg hash "${hash}" --argjson scripted "${response_script}" '[{voter_hex:$hash,voter_role:"DRep",voter_has_script:$scripted,vote:"Yes"}]' > "$3"
}
CNTOOLS_KOIOS_API=https://example.invalid/api/v1
cntools_gov_vote_previous_into previous '{"id":"gov_action1fixture"}' || fail 'Koios script vote'
response_script=false
if cntools_gov_vote_previous_into previous '{"id":"gov_action1fixture"}'; then fail 'key vote accepted as script vote'; fi

# Script credentials and mandatory intervals must survive the authoritative
# operation-specific review, including the common embedded-script validator.
(
  CNTOOLS_WALLET_REGISTER_WALLET_TYPE=CLI CNTOOLS_WALLET_REGISTER_OPERATION=drep-register
  CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=addr_test1fixture CNTOOLS_WALLET_REGISTER_FEE=200000
  CNTOOLS_WALLET_REGISTER_DEPOSIT=500000000 CNTOOLS_WALLET_REGISTER_EXPIRY=15000
  CNTOOLS_WALLET_REGISTER_INPUTS=() CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE=150
  CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''
  script_match=Y script_checks=0
  cntools_transaction_body_matches_plan() { script_checks=$((script_checks+1)); [[ "${script_match}" == Y ]]; }
  cntools_transaction_view_into() { printf -v "$1" '%s' "${body_view}"; }
  certificate_view="$(jq -cn --arg hash "${hash}" '{
    certificates:[{"Drep registration certificate":{certificate:{scriptHash:$hash},deposit:500000000,anchor:null}}],
    inputs:[],outputs:[{address:"addr_test1fixture"}],fee:"200000 Lovelace",
    "validity range":{"lower bound":150,"upper bound":15000}}')"
  body_view="${certificate_view}"
  cntools_drep_lifecycle_validate_body fixture || fail 'script DRep certificate validation'
  [[ "${script_checks}" == 1 ]] || fail 'embedded certificate script not validated'
  for mutation in '.certificates[0]["Drep registration certificate"].certificate |= {keyHash:.scriptHash}' '."validity range"["lower bound"]=null' '.certificates[0]["Drep registration certificate"].deposit=0' '.outputs[0].datum={}' '.redeemers=[{}]' '.scripts=[{"script data":{"type":"plutus"}}]'; do
    body_view="$(jq "${mutation}" <<< "${certificate_view}")"
    if cntools_drep_lifecycle_validate_body fixture; then fail "unreviewed script certificate accepted: ${mutation}"; fi
  done
  body_view="${certificate_view}" script_match=N
  if cntools_drep_lifecycle_validate_body fixture; then fail 'common script validation failure ignored'; fi

  script_match=Y CNTOOLS_WALLET_REGISTER_OPERATION=gov-vote CNTOOLS_GOV_VOTE_DECISION=Yes
  proposal_tx="$(printf 'cd%.0s' {1..32})"
  CNTOOLS_GOV_VOTE_PROPOSAL="$(jq -cn --arg tx "${proposal_tx}" '{tx:$tx,index:1}')"
  vote_view="$(jq -cn --arg hash "${hash}" --arg tx "${proposal_tx}" '{
    voters:{("drep-scriptHash-"+$hash):{($tx+"#1"):{decision:"VoteYes",anchor:null}}},
    inputs:[],outputs:[{address:"addr_test1fixture"}],fee:"200000 Lovelace",
    "validity range":{"lower bound":150,"upper bound":15000}}')"
  body_view="${vote_view}"
  cntools_gov_vote_validate_body fixture || fail 'script DRep vote validation'
  body_view="$(jq '.voters |= with_entries(.key |= sub("scriptHash";"keyHash"))' <<< "${vote_view}")"
  if cntools_gov_vote_validate_body fixture; then fail 'key voter substituted for script voter'; fi
  body_view="${vote_view}" script_match=N
  if cntools_gov_vote_validate_body fixture; then fail 'common vote script validation failure ignored'; fi
  script_match=Y body_view="$(jq '.scripts=[{"script data":{"type":"plutus"}}]' <<< "${vote_view}")"
  if cntools_gov_vote_validate_body fixture; then fail 'unexpected Plutus vote script accepted'; fi
)

# Query failures never establish absence, and state changes block submission.
CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=addr_test1fixture CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=addr_test1fixture
CNTOOLS_WALLET_REGISTER_OPERATION=drep-retire CNTOOLS_WALLET_REGISTER_EXPIRY='' CNTOOLS_WALLET_REGISTER_INPUTS=()
CNTOOLS_DREP_LIFECYCLE_STATE='{"registered":true,"deposit":"450000000","url":null,"hash":null}'
CNTOOLS_FUNDING_BACKEND=koios CNTOOLS_FUNDING_SLOT=1000
cntools_funding_collect() { :; }
query_status=0 query_deposit=450000000
cntools_drep_query() {
  [[ "$2" == script ]] || fail 'DRep query forced key identity'
  CNTOOLS_DREP_STATUS=registered CNTOOLS_DREP_DETAILS="{\"deposit\":\"${query_deposit}\",\"meta_url\":null,\"meta_hash\":null}"
  return "${query_status}"
}
cntools_drep_lifecycle_recheck || fail 'stable script DRep state'
CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE=150
CNTOOLS_FUNDING_SLOT=149
if cntools_drep_lifecycle_recheck; then fail 'recheck accepted not-yet-valid script'; fi
CNTOOLS_FUNDING_SLOT=1000
query_deposit=449999999
if cntools_drep_lifecycle_recheck; then fail 'changed refund accepted'; fi
query_status=1
if cntools_drep_lifecycle_query_state_into state; then fail 'query failure treated as absence'; fi
printf 'CNTools multisig DRep safety/interaction tests passed.\n'
