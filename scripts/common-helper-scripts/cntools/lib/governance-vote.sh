#!/usr/bin/env bash
# One verified key-DRep vote, funded by its wallet. Shared balancing/signing applies.
# shellcheck disable=SC2034
CNTOOLS_GOV_VOTE_PROPOSAL='{}'
CNTOOLS_GOV_VOTE_PREVIOUS='null'
CNTOOLS_GOV_VOTE_DECISION=''

cntools_gov_vote_operation_set() {
  CNTOOLS_WALLET_REGISTER_OPERATION=gov-vote
  CNTOOLS_WALLET_REGISTER_TITLE='Cast vote'
  CNTOOLS_WALLET_REGISTER_PATH='/ Vote / Governance / Cast vote'
  CNTOOLS_WALLET_REGISTER_NOUN='governance vote'
  CNTOOLS_WALLET_REGISTER_VERB='cast a DRep vote'
  CNTOOLS_WALLET_REGISTER_INTENT='DRep governance vote'
  CNTOOLS_WALLET_REGISTER_SUMMARY_ACTION=gov-vote
  CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT=charged
  CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL='Deposit'
  CNTOOLS_WALLET_REGISTER_FILE_SUFFIX=governance-vote
  CNTOOLS_GOV_VOTE_PROPOSAL='{}' CNTOOLS_GOV_VOTE_PREVIOUS='null' CNTOOLS_GOV_VOTE_DECISION=''
  CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''
}

cntools_gov_vote_collect() {
  cntools_wallet_register_reset_chain_state
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  CNTOOLS_WALLET_REGISTER_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${CNTOOLS_FUNDING_PROTOCOL}" CNTOOLS_WALLET_REGISTER_SOURCE="${CNTOOLS_FUNDING_BACKEND}"
  cntools_drep_lifecycle_query_state_into CNTOOLS_DREP_LIFECYCLE_STATE || return 1
  jq -e '.registered == true' <<< "${CNTOOLS_DREP_LIFECYCLE_STATE}" >/dev/null || {
    cntools_wallet_register_set_error 'Register this DRep before casting a governance vote.'; return 7;
  }
  cntools_proposals_query_backend "${CNTOOLS_WALLET_REGISTER_BACKEND}" || return 1
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0
  cntools_wallet_register_inventory_use_all || return 1
  cntools_wallet_register_select_inputs
}

cntools_gov_vote_eligible() {
  local proposal="$1" major=''
  jq -e --argjson epoch "${CNTOOLS_PROPOSAL_EPOCH}" '.expires >= $epoch and .ratified == false' <<< "${proposal}" >/dev/null || {
    cntools_wallet_register_set_error 'This proposal is no longer open for voting.'; return 1;
  }
  major="$(jq -er '.protocolVersion.major | select(type == "number" and . >= 9 and . <= 1000 and floor == .)' "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}")" || {
    cntools_wallet_register_set_error 'The governance protocol version is unavailable.'; return 1;
  }
  if ((major == 9)) && [[ "$(jq -r .type <<< "${proposal}")" != InfoAction ]]; then
    cntools_wallet_register_set_error 'During the Conway bootstrap phase DReps may vote only on informational actions.'; return 1
  fi
}

cntools_gov_vote_previous_into() {
  local -n gv_previous_result="$1"
  local record="$2" output='' payload='' id='' key="keyHash-${CNTOOLS_DREP_LIFECYCLE_HASH}"
  if [[ "${CNTOOLS_PROPOSAL_BACKEND}" == local ]]; then
    gv_previous_result="$(jq -c --arg key "${key}" '.votes[$key] // null' <<< "${record}")" || return 1
  else
    id="$(jq -r .id <<< "${record}")" || return 1
    # The single-byte CIP ID is required by Koios proposal_votes.
    [[ "${id}" == gov_action1* ]] || return 1
    payload="$(jq -cn --arg id "${id}" '{_proposal_id:$id}')" || return 1
    cntools_transaction_temp_file output governance-prior-vote || return 1
    cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/proposal_votes?voter_hex=eq.${CNTOOLS_DREP_LIFECYCLE_HASH}&voter_role=eq.DRep&voter_has_script=eq.false" "${payload}" "${output}" || return 1
    gv_previous_result="$(jq -cs --arg hash "${CNTOOLS_DREP_LIFECYCLE_HASH}" '
      select(length == 1) | .[0] | select(type == "array" and length <= 1) |
      if length == 0 then null else .[0] | select(.voter_hex == $hash and .voter_role == "DRep" and .voter_has_script == false) |
      .vote | if . == "Yes" then "VoteYes" elif . == "No" then "VoteNo"
        elif . == "Abstain" then "Abstain" else error("Unknown vote") end end' "${output}")" || return 1
  fi
  [[ "${gv_previous_result}" == null || "${gv_previous_result}" == '"VoteYes"' || "${gv_previous_result}" == '"VoteNo"' || "${gv_previous_result}" == '"Abstain"' || "${gv_previous_result}" == '"VoteAbstain"' ]]
}

cntools_gov_vote_file_create() {
  local output='' errors='' artifact='' tx='' index='' status=0
  local -a arguments=()
  cntools_gov_vote_eligible "${CNTOOLS_GOV_VOTE_PROPOSAL}" || return 1
  case "${CNTOOLS_GOV_VOTE_DECISION}" in Yes) arguments+=(--yes) ;; No) arguments+=(--no) ;; Abstain) arguments+=(--abstain) ;; *) return 2 ;; esac
  cntools_drep_lifecycle_anchor_valid "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" || return 1
  tx="$(jq -r .tx <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"; index="$(jq -r .index <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"
  local verified_id=''
  cntools_proposal_id_into verified_id "${tx}" "${index}" || return 1
  [[ "${verified_id}" == "$(jq -r .id <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")" ]] || return 1
  arguments+=(--governance-action-tx-id "${tx}" --governance-action-index "${index}" --drep-verification-key-file "${CNTOOLS_DREP_LIFECYCLE_VKEY}")
  if [[ -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
    arguments+=(--anchor-url "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" --anchor-data-hash "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}")
  fi
  cntools_transaction_temp_file artifact governance-vote || return 1
  cntools_transaction_temp_file output governance-vote-output || return 1
  cntools_transaction_temp_file errors governance-vote-errors || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest governance vote create "${arguments[@]}" --out-file "${artifact}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Governance vote creation failed' "${status}" "${errors}" "${output}"; return 1; fi
  cntools_transaction_file_safe "${artifact}" 131072 && jq -e '.cborHex | type == "string" and test("^([0-9a-fA-F]{2})+$")' "${artifact}" >/dev/null || return 1
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE="${artifact}"
}

cntools_gov_vote_plan_create() {
  # Payment/change and DRep source registration are identical to the lifecycle;
  # the signer role and the descriptive intent are different, not the key logic.
  cntools_drep_lifecycle_plan_create vote || return 1
  local summary=''
  summary="$(jq -c --argjson proposal "${CNTOOLS_GOV_VOTE_PROPOSAL}" --arg decision "${CNTOOLS_GOV_VOTE_DECISION}" \
    --argjson previous "${CNTOOLS_GOV_VOTE_PREVIOUS}" '. + {proposalId:$proposal.id,proposalTx:$proposal.tx,proposalIndex:$proposal.index,
      proposalType:$proposal.type,decision:$decision,previousVote:$previous} | del(.previousDrepState)' <<< "${CNTOOLS_TRANSACTION_PLAN_SUMMARY}")" || return 1
  cntools_transaction_plan_set_summary "${summary}"
}

cntools_gov_vote_validate_body() {
  local view='' identity='' decision="Vote${CNTOOLS_GOV_VOTE_DECISION}" anchor=null inputs='[]'
  [[ "${CNTOOLS_GOV_VOTE_DECISION}" != Abstain ]] || decision=Abstain
  identity="$(jq -r '.tx+"#"+(.index|tostring)' <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")" || return 1
  if [[ -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
    anchor="$(jq -cn --arg url "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" --arg hash "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" '{url:$url,dataHash:$hash}')" || return 1
  fi
  cntools_transaction_view_into view "$1" || return 1
  inputs="$(printf '%s\n' "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))|sort')" || return 1
  jq -e --arg voter "drep-keyHash-${CNTOOLS_DREP_LIFECYCLE_HASH}" --arg identity "${identity}" --arg decision "${decision}" \
    --argjson anchor "${anchor}" --argjson inputs "${inputs}" --arg expiry "${CNTOOLS_WALLET_REGISTER_EXPIRY}" \
    --arg fee "${CNTOOLS_WALLET_REGISTER_FEE} Lovelace" --arg address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" '
    .voters == {($voter):{($identity):{anchor:$anchor,decision:$decision}}} and
    (.certificates == null or .certificates == []) and (.inputs|sort) == $inputs and .fee == $fee and
    (."validity range"["upper bound"] | if . == null then "" else tostring end) == $expiry and
    ."validity range"["lower bound"] == null and
    (.outputs | length > 0 and all(.[]; .address == $address and .datum == null and ."reference script" == null)) and
    (.withdrawals == null or .withdrawals == []) and .mint == null and .metadata == null and
    (."governance actions" == null or ."governance actions" == []) and
    (."collateral inputs" == null or ."collateral inputs" == []) and (."reference inputs" == null or ."reference inputs" == []) and
    (.treasuryDonation == null or .treasuryDonation == 0) and .currentTreasuryValue == null and
    (."auxiliary scripts" == null or ."auxiliary scripts" == []) and (.scripts == null or .scripts == []) and
    (.redeemers == null or .redeemers == [])
  ' <<< "${view}" >/dev/null || {
    cntools_wallet_register_set_error 'The built transaction does not match the reviewed DRep, proposal, vote, rationale or wallet change.'; return 1;
  }
}

cntools_gov_vote_recheck() {
  local state='' identity='' current='' previous='' reference=''
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  [[ "${CNTOOLS_FUNDING_BACKEND}" == "${CNTOOLS_WALLET_REGISTER_BACKEND}" ]] || { cntools_wallet_register_set_error 'The chain-data source changed. Rebuild the vote.'; return 1; }
  [[ -z "${CNTOOLS_WALLET_REGISTER_EXPIRY}" ]] || ((CNTOOLS_FUNDING_SLOT < CNTOOLS_WALLET_REGISTER_EXPIRY)) || { cntools_wallet_register_set_error 'The vote transaction expired. Rebuild it.'; return 1; }
  for reference in "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${reference}]+x}" ]] || { cntools_wallet_register_set_error 'A selected input was spent. Rebuild the vote.'; return 1; }
  done
  cntools_drep_lifecycle_query_state_into state || return 1
  jq -e '.registered == true' <<< "${state}" >/dev/null || { cntools_wallet_register_set_error 'This DRep is no longer registered.'; return 1; }
  # Use fresh protocol parameters to check bootstrap eligibility as well.
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${CNTOOLS_FUNDING_PROTOCOL}"
  cntools_proposals_query_backend "${CNTOOLS_WALLET_REGISTER_BACKEND}" || return 1
  identity="$(jq -r .id <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")" || return 1
  if ! cntools_proposal_select "${identity}"; then cntools_wallet_register_set_error 'The proposal is no longer active. Nothing was submitted.'; return 1; fi
  current="${CNTOOLS_PROPOSAL_SELECTED}"
  cntools_gov_vote_eligible "${current}" || return 1
  [[ "$(jq -Sc '{tx,index,type,action,anchor,expires}' <<< "${current}")" == "$(jq -Sc '{tx,index,type,action,anchor,expires}' <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")" ]] || {
    cntools_wallet_register_set_error 'The reviewed proposal changed. Rebuild the vote.'; return 1;
  }
  cntools_gov_vote_previous_into previous "${current}" || return 1
  [[ "${previous}" == "${CNTOOLS_GOV_VOTE_PREVIOUS}" ]] || { cntools_wallet_register_set_error 'Your on-chain vote changed since review. Rebuild and review the replacement.'; return 1; }
}
