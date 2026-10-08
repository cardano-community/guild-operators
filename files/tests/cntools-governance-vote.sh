#!/usr/bin/env bash
# Deterministic proposal/browser/vote safety tests; no node or network calls.
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-governance.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
umask 077
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
for lib in number wallet wallet-query transaction transaction-build utxo wallet-register governance-drep drep-id governance-proposal governance-proposal-ui governance-vote governance-vote-ui; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s (%s / %s)\n' "$*" "${CNTOOLS_WALLET_REGISTER_ERROR:-}" "${CNTOOLS_TRANSACTION_ERROR:-}" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
cntools_log() { :; }
REAL_CHMOD="$(type -P chmod)"
chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
tx=1ac710c7e4ec6e82a6b0ba37f1a44c1ee9da7ca398e29d858d2e07d39d40d3db
id=''; cntools_proposal_id_into id "${tx}" 0
eq "${id}" gov_action1rtr3p3lya3hg9f4shgmlrfzvrm5a5l9rnr3fmpvd9cra882q60dsqurjzc4 'public CIP-129 example'
cntools_proposal_id_into id "${tx}" 65535
eq "${id}" "${tx}#65535" 'large index not truncated'
if cntools_proposal_id_into id "${tx}" 65536; then fail 'oversized index accepted'; fi
cntools_proposal_id_into id "${tx}" 0
TEST_PROPOSAL_ID="${id}"
drep="$(printf 'ab%.0s' {1..28})" CNTOOLS_DREP_LIFECYCLE_HASH="$(printf 'ab%.0s' {1..28})"
jq -cn --arg tx "${tx}" --arg hash "${drep}" '{proposals:[{actionId:{txId:$tx,govActionIx:0},
 committeeVotes:{},dRepVotes:{("keyHash-"+$hash):"VoteYes"},stakePoolVotes:{},proposedIn:42,expiresAfter:43,
 proposalProcedure:{deposit:1000000000,returnAddr:"stake_test1fixture",anchor:null,govAction:{tag:"InfoAction"}}}]}' > "${TEST_ROOT}/local.json"
cntools_proposals_parse "${TEST_ROOT}/local.json" local 42 || fail 'current-epoch local proposal excluded'
eq "$(jq length <<< "${CNTOOLS_PROPOSALS}")" 1
cntools_proposal_select 1 || fail 'select by number'
local_record="${CNTOOLS_PROPOSAL_SELECTED}"
cntools_gov_vote_previous_into previous "${local_record}" || fail 'local previous vote'
eq "${previous}" '"VoteYes"'
CNTOOLS_DREP_LIFECYCLE_HASH="$(printf 'cd%.0s' {1..28})"
cntools_gov_vote_previous_into previous "${local_record}" || fail 'missing local vote'
eq "${previous}" null
CNTOOLS_DREP_LIFECYCLE_HASH="${drep}"
cntools_proposal_select "${tx}#0" || fail 'select hash#index'
cntools_proposal_select "${id}" || fail 'select CIP ID'
if cntools_proposal_select 2; then fail 'out-of-range selected'; fi
cntools_proposals_parse "${TEST_ROOT}/local.json" local 43 || fail 'last valid epoch should be inclusive'
cntools_proposals_parse "${TEST_ROOT}/local.json" local 44
eq "${CNTOOLS_PROPOSALS}" '[]' 'expired proposal removed'
jq '.proposals[0].actionId.txId = "wrong"' "${TEST_ROOT}/local.json" > "${TEST_ROOT}/bad.json"
if cntools_proposals_parse "${TEST_ROOT}/bad.json" local 42 2>/dev/null; then fail 'malformed identity accepted'; fi
jq '.proposals += .proposals' "${TEST_ROOT}/local.json" > "${TEST_ROOT}/bad.json"
if cntools_proposals_parse "${TEST_ROOT}/bad.json" local 42 2>/dev/null; then fail 'duplicate identity accepted'; fi
jq -cn --arg tx "${tx}" --arg id "${id}" '[{proposal_tx_hash:$tx,proposal_id:$id,proposal_index:0,proposal_type:"InfoAction",
 proposed_epoch:42,expiration:43,proposal_description:{tag:"InfoAction"},meta_url:null,meta_hash:null,
 deposit:"1000000000",return_address:"stake_test1fixture",ratified_epoch:null,enacted_epoch:null,dropped_epoch:null,expired_epoch:null,
 meta_json:{body:{title:"Informational proposal",abstract:"Description"}}}]' > "${TEST_ROOT}/koios.json"
cntools_proposals_parse "${TEST_ROOT}/koios.json" koios 42 || fail 'Koios proposal'
cntools_proposal_select 1
koios_record="${CNTOOLS_PROPOSAL_SELECTED}"
jq '.[0].proposal_id="gov_action1wrong"' "${TEST_ROOT}/koios.json" > "${TEST_ROOT}/bad.json"
if cntools_proposals_parse "${TEST_ROOT}/bad.json" koios 42; then fail 'mismatched CIP identity accepted'; fi
jq '.[0].proposal_type="NewCommittee" | .[0].proposal_description.tag="UpdateCommittee"' "${TEST_ROOT}/koios.json" > "${TEST_ROOT}/committee.json"
cntools_proposals_parse "${TEST_ROOT}/committee.json" koios 42 || fail 'Koios NewCommittee alias'
eq "$(jq -r '.[0].type' <<< "${CNTOOLS_PROPOSALS}")" UpdateCommittee
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_PROPOSAL_BACKEND=koios CNTOOLS_KOIOS_API=https://example.invalid/api/v1
VOTE_RESPONSE='[]' HTTP_STATUS=0
cntools_wallet_query_http() {
  [[ "$1" == *proposal_votes* ]] || fail 'unexpected API request'
  [[ "$1" == *voter_hex=eq."${drep}"* && "$1" == *voter_role=eq.DRep* && "$1" == *voter_has_script=eq.false* ]] || fail 'exact voter filters'
  eq "$(jq -r ._proposal_id <<< "$2")" "${id}" 'exact proposal'
  printf '%s' "${VOTE_RESPONSE}" > "$3"; return "${HTTP_STATUS}"
}
cntools_gov_vote_previous_into previous "${koios_record}" || fail 'empty prior votes'
eq "${previous}" null
VOTE_RESPONSE="$(jq -cn --arg hash "${drep}" '[{voter_hex:$hash,voter_role:"DRep",voter_has_script:false,vote:"No"}]')"
cntools_gov_vote_previous_into previous "${koios_record}" || fail 'prior Koios vote'
eq "${previous}" '"VoteNo"'
VOTE_RESPONSE="$(jq '.[0].voter_hex="wrong"' <<< "${VOTE_RESPONSE}")"
if cntools_gov_vote_previous_into previous "${koios_record}"; then fail 'wrong voter accepted'; fi
HTTP_STATUS=1
if cntools_gov_vote_previous_into previous "${koios_record}"; then fail 'failure interpreted as no prior vote'; fi
cp "${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json" "${TEST_ROOT}/protocol.json"
CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${TEST_ROOT}/protocol.json" CNTOOLS_PROPOSAL_EPOCH=42
cntools_gov_vote_eligible "${koios_record}" || fail 'eligible proposal'
jq '.protocolVersion.major=9' "${TEST_ROOT}/protocol.json" > "${TEST_ROOT}/bootstrap.json"
CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${TEST_ROOT}/bootstrap.json"
cntools_gov_vote_eligible "${koios_record}" || fail 'bootstrap InfoAction'
if cntools_gov_vote_eligible "$(jq '.type="NewConstitution"' <<< "${koios_record}")"; then fail 'bootstrap substantive action accepted'; fi
CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${TEST_ROOT}/protocol.json"
if cntools_gov_vote_eligible "$(jq '.ratified=true' <<< "${koios_record}")"; then fail 'ratified action accepted'; fi
# Decoded authority checks reject all unreviewed voters/actions/anchors/certificates.
CNTOOLS_GOV_VOTE_PROPOSAL="${koios_record}" CNTOOLS_GOV_VOTE_DECISION=Yes CNTOOLS_GOV_VOTE_PREVIOUS=null
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=addr_test1fixture CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=addr_test1fixture
CNTOOLS_WALLET_REGISTER_INPUTS=("${tx}#1") CNTOOLS_WALLET_REGISTER_FEE=200000 CNTOOLS_WALLET_REGISTER_EXPIRY=''
CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''
GOOD_VIEW="$(jq -cn --arg voter "drep-keyHash-${drep}" --arg tx "${tx}" '{voters:{($voter):{($tx+"#0"):{anchor:null,decision:"VoteYes"}}},
 inputs:[($tx+"#1")],fee:"200000 Lovelace",outputs:[{address:"addr_test1fixture"}]}')"
VIEW="${GOOD_VIEW}"
cntools_transaction_view_into() { printf -v "$1" '%s' "${VIEW}"; }
cntools_gov_vote_validate_body fixture || fail 'valid decoded vote'
for mutation in '.voters += {"other":{}}' '.certificates=[{}]' '.outputs[0].address="wrong"' '.fee="200001 Lovelace"' '.metadata={}' '."governance actions"=[{}]' '.voters |= with_entries(.value |= with_entries(.value.decision="VoteNo"))'; do
  VIEW="$(jq "${mutation}" <<< "${GOOD_VIEW}")"
  if cntools_gov_vote_validate_body fixture; then fail "unreviewed transaction accepted: ${mutation}"; fi
done
# Recheck only the selected proposal and our vote; other voters may change.
CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_FUNDING_SLOT=1000
CURRENT="${koios_record}" PRIOR=null STATE='{"registered":true}' SPENT=N SOURCE=koios
cntools_funding_collect() {
  CNTOOLS_FUNDING_BACKEND="${SOURCE}" CNTOOLS_FUNDING_PROTOCOL="${TEST_ROOT}/protocol.json"
  cntools_utxo_reset; [[ "${SPENT}" == Y ]] || cntools_utxo_add "${tx}#1" addr_test1fixture 10000000
}
cntools_drep_lifecycle_query_state_into() { printf -v "$1" '%s' "${STATE}"; }
cntools_proposals_query_backend() { CNTOOLS_PROPOSALS="[${CURRENT}]"; CNTOOLS_PROPOSAL_BACKEND="$1"; }
cntools_gov_vote_previous_into() { printf -v "$1" '%s' "${PRIOR}"; }
cntools_gov_vote_recheck || fail 'stable vote recheck'
CURRENT="$(jq '.counts={DRep:{Yes:99}}' <<< "${koios_record}")"
cntools_gov_vote_recheck || fail 'other votes must not invalidate review'
PRIOR='"VoteYes"'; if cntools_gov_vote_recheck; then fail 'changed prior vote accepted'; fi
PRIOR=null STATE='{"registered":false}'; if cntools_gov_vote_recheck; then fail 'retired DRep accepted'; fi
STATE='{"registered":true}' SPENT=Y; if cntools_gov_vote_recheck; then fail 'spent input accepted'; fi
SPENT=N SOURCE=local; if cntools_gov_vote_recheck; then fail 'backend switch accepted'; fi
SOURCE=koios CURRENT="$(jq '.ratified=true' <<< "${koios_record}")"; if cntools_gov_vote_recheck; then fail 'closed proposal accepted'; fi
CURRENT="${koios_record}" CNTOOLS_WALLET_REGISTER_EXPIRY=1000; if cntools_gov_vote_recheck; then fail 'expired transaction accepted'; fi
CNTOOLS_WALLET_REGISTER_EXPIRY=''; cntools_gov_vote_recheck || fail 'No expiry recheck'

# Real selection/confirmation controls never interpret cancellation as approval.
(
  CNTOOLS_PROPOSALS="[${koios_record}]" CNTOOLS_PROPOSAL_EPOCH=42
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${TEST_ROOT}/protocol.json"
  PRIOR=null CANCEL_AT='' REPLACEMENTS=0
  cntools_ui_choose() {
    local answer="$3"
    [[ "$2" != "${CANCEL_AT}" ]] || answer=Cancel
    case "$2" in
      'Vote decision') [[ "$2" == "${CANCEL_AT}" ]] || answer=No ;;
      'Vote rationale') [[ "$2" == "${CANCEL_AT}" ]] || answer='No rationale anchor' ;;
    esac
    printf -v "$1" '%s' "${answer}"
  }
  cntools_wallet_register_begin() { :; }
  cntools_ui_render_status() { :; }
  cntools_proposal_details() { eq "$(jq -r .id <<< "$1")" "${TEST_PROPOSAL_ID}" 'selected proposal review'; }
  cntools_ui_confirm() {
    eq "$2" false 'governance target/replacement requires explicit confirmation'
    if [[ "$1" == 'Prepare a replacement vote?' ]]; then
      REPLACEMENTS=$((REPLACEMENTS+1)); [[ "${CANCEL_AT}" != replacement ]] || return 1
    fi
  }
  cntools_gov_vote_choose || fail 'new vote choices'
  eq "${CNTOOLS_GOV_VOTE_DECISION}" No 'selected decision'
  eq "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" '' 'no rationale anchor'
  PRIOR='"VoteYes"'
  cntools_gov_vote_choose || fail 'replacement vote choices'
  eq "${REPLACEMENTS}" 1 'replacement confirmation'
  for CANCEL_AT in replacement 'Select governance proposal' 'Vote decision' 'Vote rationale'; do
    status=0; cntools_gov_vote_choose || status=$?
    eq "${status}" 1 'cancel must return to the menu without building'
  done
  CNTOOLS_PROPOSALS='[]'
  status=0; cntools_gov_vote_choose || status=$?
  eq "${status}" 2 'empty catalog cannot produce a vote'
)

# Exercise real query orchestration without contacting either backend.
(
  . "${CNTOOLS_ROOT}/lib/governance-proposal.sh"
  CNTOOLS_MODE=light CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_NETWORK=preview CNTOOLS_SOCKET=/fixture.socket CNTOOLS_CLI=fixture-cli
  HTTP_CALLS=0 CLI_CALLS=0
  cntools_wallet_query_http() {
    HTTP_CALLS=$((HTTP_CALLS+1)); eq "${5:-POST}" GET 'read-only proposal query method'
    case "$1" in
      */tip) printf '[{"epoch_no":42}]' > "$3" ;;
      *proposal_list*offset=0)
        [[ "$1" == *expiration=gte.42* && "$1" == *enacted_epoch=is.null* && "$1" == *expired_epoch=is.null* ]] || fail 'active proposal filters'
        jq -cn '[range(500)]' > "$3" ;;
      *proposal_list*offset=500) printf '[500]' > "$3" ;;
      *) fail 'unexpected pagination request' ;;
    esac
  }
  cntools_proposals_parse() { eq "$(jq length "$1")" 501 'pagination must not stop at first row cap'; CNTOOLS_PROPOSALS='[]'; CNTOOLS_PROPOSAL_EPOCH=42; CNTOOLS_PROPOSAL_BACKEND="$2"; }
  cntools_proposals_query_backend koios || fail 'Koios paginated query'
  eq "${HTTP_CALLS}" 3
  CNTOOLS_MODE=offline
  if cntools_proposals_query_backend koios; then fail 'offline proposal query accepted'; fi
  eq "${HTTP_CALLS}" 3 'offline must not call API'
  CNTOOLS_MODE=local
  cntools_transaction_run_cli() {
    CLI_CALLS=$((CLI_CALLS+1))
    [[ "$*" == *--socket-path* ]] || fail 'local socket missing'
    case "$*" in
      *'query tip'*) printf '{"epoch":42}' > "$1" ;;
      *'query gov-state'*) cp "${TEST_ROOT}/local.json" "$1" ;;
      *) fail 'query proposals must not exclude current epoch' ;;
    esac
  }
  . "${CNTOOLS_ROOT}/lib/governance-proposal.sh"
  cntools_proposals_query_backend local || fail 'local governance state query'
  eq "${CLI_CALLS}" 2
  eq "$(jq length <<< "${CNTOOLS_PROPOSALS}")" 1
  cntools_transaction_local_backend_ready() { return 0; }
  cntools_proposals_query_backend() { if [[ "$1" == local ]]; then return 1; fi; CNTOOLS_PROPOSAL_BACKEND=koios; return 0; }
  cntools_proposals_query || fail 'explicit read-only Koios fallback'
  eq "${CNTOOLS_PROPOSAL_BACKEND}" koios
)

# Browser pages, default size, selected details, refresh-to-empty and safe text.
(
  . "${CNTOOLS_ROOT}/lib/table.sh"
  CATALOG="$(jq -cn --argjson item "${koios_record}" '[range(7) | $item]')"
  QUERY_COUNT=0 MENU_STEP=0 INPUT_STEP=0 CNTOOLS_UI_COLUMNS=180
  cntools_ui_action_begin() { :; }
  cntools_ui_wait() { :; }
  cntools_ui_render_status() { :; }
  cntools_wallet_style_value_into() { printf -v "$1" '%s' "$3"; }
  cntools_ui_table() { cat; }
  cntools_ui_spin_function() { shift; "$@"; }
  cntools_proposals_query() {
    QUERY_COUNT=$((QUERY_COUNT+1)); CNTOOLS_PROPOSAL_BACKEND=koios CNTOOLS_PROPOSAL_EPOCH=42
    if ((QUERY_COUNT == 1)); then CNTOOLS_PROPOSALS="${CATALOG}"; else CNTOOLS_PROPOSALS='[]'; fi
  }
  cntools_ui_input() { INPUT_STEP=$((INPUT_STEP+1)); if ((INPUT_STEP == 1)); then printf -v "$1" '%s' ''; else printf -v "$1" '%s' 1; fi; }
  cntools_ui_choose() {
    local answer=''
    case "${MENU_STEP}" in
      0) [[ "$*" == *'Next page'* && "$*" != *'Previous page'* ]] || fail 'first page menu'; answer='Next page' ;;
      1) [[ "$*" == *'Previous page'* && "$*" != *'Next page'* ]] || fail 'last page menu'; answer='Previous page' ;;
      2) answer='View proposal details' ;;
      3) answer=Refresh ;;
      4) [[ "$*" != *'View proposal details'* ]] || fail 'empty catalog offered details'; answer=Back ;;
      *) fail 'unexpected browser step' ;;
    esac
    MENU_STEP=$((MENU_STEP+1)); printf -v "$1" '%s' "${answer}"
  }
  cntools_governance_action_proposals > "${TEST_ROOT}/browser.txt" || fail 'proposal browser'
  eq "${MENU_STEP}" 5 'browser pagination and refresh'
  eq "${QUERY_COUNT}" 2 'browser refresh'
  grep -q '6 · Informational proposal' "${TEST_ROOT}/browser.txt" || fail 'second page missing'
  grep -q 'Description' "${TEST_ROOT}/browser.txt" || fail 'metadata details missing'
)
cntools_transaction_cleanup
printf 'CNTools governance proposal and vote safety tests passed.\n'
