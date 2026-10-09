#!/usr/bin/env bash
# Indexed weighted statistics, separate from authoritative local proposal identity.
# Advisory thresholds use current parameters, not a promise of ratification.
# shellcheck disable=SC2034
declare -Ag CNTOOLS_VOTING_STATS=()
CNTOOLS_VOTING_PROTOCOL='{}' CNTOOLS_VOTING_COMMITTEE='{}' CNTOOLS_VOTING_PARAMETERS_SOURCE=''
CNTOOLS_VOTING_COMMITTEE_SOURCE='' CNTOOLS_VOTING_PARAMETERS_CHECKED=N

cntools_voting_parameters_collect() {
  local response='' errors=''
  CNTOOLS_VOTING_PROTOCOL='{}' CNTOOLS_VOTING_COMMITTEE='{}' CNTOOLS_VOTING_PARAMETERS_SOURCE=''
  CNTOOLS_VOTING_COMMITTEE_SOURCE='' CNTOOLS_VOTING_PARAMETERS_CHECKED=Y
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  cntools_transaction_temp_file response voting-parameters && cntools_transaction_temp_file errors voting-parameter-errors || return 1
  local -a network=()
  if cntools_transaction_local_backend_ready; then
    cntools_transaction_network_arguments_into network || return 1
    if cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest query protocol-parameters \
        "${network[@]}" --socket-path "${CNTOOLS_SOCKET}" --output-json; then
      CNTOOLS_VOTING_PROTOCOL="$(jq -cse 'select(length == 1) | .[0] | select(type == "object")' "${response}")" || CNTOOLS_VOTING_PROTOCOL='{}'
      CNTOOLS_VOTING_PARAMETERS_SOURCE='Local node'
    fi
    if [[ -n "${CNTOOLS_PROPOSAL_GOV_STATE:-}" ]]; then
      CNTOOLS_VOTING_COMMITTEE="$(jq -cse 'select(length == 1) | .[0].committee // {} | select(type == "object")' "${CNTOOLS_PROPOSAL_GOV_STATE}")" || CNTOOLS_VOTING_COMMITTEE='{}'
      [[ "${CNTOOLS_VOTING_COMMITTEE}" == '{}' ]] || CNTOOLS_VOTING_COMMITTEE_SOURCE='Local node'
    fi
  fi
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" == https://* ]]; then
    if [[ "${CNTOOLS_VOTING_PROTOCOL}" == '{}' ]] && cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/cli_protocol_params" '' "${response}" 4194304 GET; then
      CNTOOLS_VOTING_PROTOCOL="$(jq -cse 'select(length == 1) | .[0] | select(type == "object")' "${response}")" || CNTOOLS_VOTING_PROTOCOL='{}'
      CNTOOLS_VOTING_PARAMETERS_SOURCE='Koios API'
    fi
    if [[ "${CNTOOLS_VOTING_COMMITTEE}" == '{}' ]] && cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/committee_info" '' "${response}" 4194304 GET; then
      CNTOOLS_VOTING_COMMITTEE="$(jq -cse 'select(length == 1) | .[0] | select(type == "array" and length == 1) | .[0] |
        select((.quorum_numerator | type == "number" and floor == . and . >= 0) and
          (.quorum_denominator | type == "number" and floor == . and . > 0) and .quorum_numerator <= .quorum_denominator) |
        {threshold:(.quorum_numerator/.quorum_denominator),members}' "${response}")" || CNTOOLS_VOTING_COMMITTEE='{}'
      [[ "${CNTOOLS_VOTING_COMMITTEE}" == '{}' ]] || CNTOOLS_VOTING_COMMITTEE_SOURCE='Koios API'
    fi
  fi
}

cntools_voting_stats_collect() {
  local record="$1" id='' response='' expected=''
  id="$(jq -r .id <<< "${record}")" || return 1
  [[ -z "${CNTOOLS_VOTING_STATS[${id}]+x}" ]] || return 0
  CNTOOLS_VOTING_STATS["${id}"]='{}'
  [[ "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" == https://* && "${id}" =~ ^gov_action1[0-9a-z]+$ ]] || return 0
  cntools_transaction_temp_file response voting-summary || return 1
  if ! cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/proposal_voting_summary?_proposal_id=${id}" '' "${response}" 4194304 GET; then
    cntools_transaction_log WARN "Optional voting-power statistics unavailable proposal=${id}"; return 0
  fi
  expected="$(jq -r 'if .type == "UpdateCommittee" then "NewCommittee" else .type end' <<< "${record}")"
  if ! jq -se --arg expected "${expected}" 'length == 1 and (.[0] | type == "array" and length == 1 and
    .[0].proposal_type == $expected and (.[0].epoch_no | type == "number" and floor == . and . >= 0) and
    (.[0] | to_entries | all(.[];
      if (.key | endswith("_pct")) then (.value == null or (.value | type == "number" and . >= 0 and . <= 100))
      elif (.key | endswith("_power")) then (.value == null or (.value | type == "string" and test("^[0-9]+$")))
      elif (.key | endswith("_cast")) then (.value == null or (.value | type == "number" and floor == . and . >= 0))
      else true end)))' "${response}" >/dev/null; then
    cntools_transaction_log WARN "Invalid voting-power statistics ignored proposal=${id}"; return 0
  fi
  CNTOOLS_VOTING_STATS["${id}"]="$(jq -c '.[0]' "${response}")"
}

cntools_voting_thresholds() {
  jq -nr --argjson proposal "$1" --argjson protocol "${CNTOOLS_VOTING_PROTOCOL}" --argjson committee "${CNTOOLS_VOTING_COMMITTEE}" '
    def ratio($v):
      if ($v|type) == "number" then $v
      elif ($v|type) == "object" and ($v.numerator|type) == "number" and ($v.denominator|type) == "number" and
        $v.numerator >= 0 and $v.denominator > 0 and $v.numerator <= $v.denominator and
        ($v.numerator|floor) == $v.numerator and ($v.denominator|floor) == $v.denominator then $v.numerator/$v.denominator
      else null end;
    def row($label;$raw): ratio($raw) as $v |
      [$label, (if ($v|type) == "number" and $v >= 0 and $v <= 1 then ((($v*10000|round)/100)|tostring)+" %" else "Unavailable" end)] | join("\u001f");
    $proposal.type as $type | $protocol.dRepVotingThresholds as $d | $protocol.poolVotingThresholds as $s |
    if $type == "InfoAction" then ["Ratification","Informational action · no ratification threshold"]|join("\u001f")
    else
      (if $type == "UpdateCommittee" then
         row("DRep · committee normal";$d.committeeNormal), row("DRep · no confidence";$d.committeeNoConfidence),
         row("SPO · committee normal";$s.committeeNormal), row("SPO · no confidence";$s.committeeNoConfidence)
       elif $type == "NoConfidence" then row("DRep threshold";$d.motionNoConfidence),row("SPO threshold";$s.motionNoConfidence)
       elif $type == "HardForkInitiation" then row("DRep threshold";$d.hardForkInitiation),row("SPO threshold";$s.hardForkInitiation)
       elif $type == "TreasuryWithdrawals" then row("DRep threshold";$d.treasuryWithdrawal)
       elif $type == "NewConstitution" then row("DRep threshold";$d.updateToConstitution)
       elif $type == "ParameterChange" then
         ($proposal.action.contents[1] | if type == "object" then keys else [] end) as $keys |
         {maxBlockBodySize:"ppNetworkGroup",maxTxSize:"ppNetworkGroup",maxBlockHeaderSize:"ppNetworkGroup",
          maxTxExecutionUnits:"ppNetworkGroup",maxBlockExecutionUnits:"ppNetworkGroup",maxValueSize:"ppNetworkGroup",maxCollateralInputs:"ppNetworkGroup",
          txFeePerByte:"ppEconomicGroup",txFeeFixed:"ppEconomicGroup",stakeAddressDeposit:"ppEconomicGroup",stakePoolDeposit:"ppEconomicGroup",
          monetaryExpansion:"ppEconomicGroup",treasuryCut:"ppEconomicGroup",minPoolCost:"ppEconomicGroup",utxoCostPerByte:"ppEconomicGroup",executionUnitPrices:"ppEconomicGroup",
          poolRetireMaxEpoch:"ppTechnicalGroup",stakePoolTargetNum:"ppTechnicalGroup",poolPledgeInfluence:"ppTechnicalGroup",costModels:"ppTechnicalGroup",collateralPercentage:"ppTechnicalGroup",
          poolVotingThresholds:"ppGovGroup",dRepVotingThresholds:"ppGovGroup",committeeMinSize:"ppGovGroup",committeeMaxTermLength:"ppGovGroup",
          govActionLifetime:"ppGovGroup",govActionDeposit:"ppGovGroup",dRepDeposit:"ppGovGroup",dRepActivity:"ppGovGroup",minFeeRefScriptCostPerByte:"ppEconomicGroup"} as $groups |
         if ($keys|length) > 0 and all($keys[]; $groups[.] != null) then row("DRep threshold"; ([$keys[] | $d[$groups[.]]] | if all(.[]; type == "number") then max else null end))
         else row("DRep threshold";null) end,
         if any($keys[]; IN("txFeePerByte","txFeeFixed","maxBlockBodySize","maxTxSize","maxBlockHeaderSize","utxoCostPerByte","maxBlockExecutionUnits","maxValueSize","govActionDeposit"))
         then row("SPO threshold";$s.ppSecurityGroup) else empty end
       else empty end),
      (if ($type|IN("NoConfidence","UpdateCommittee")) then empty else row("Committee quorum";$committee.threshold) end)
    end'
}

cntools_voting_stats_render() {
  local record="$1" id='' data='' label='' value='' role='' prefix='' vote='' percentage='' power='' count=''
  id="$(jq -r .id <<< "${record}")"; data="${CNTOOLS_VOTING_STATS[${id}]:-}"
  [[ -n "${data}" ]] || data='{}'
  {
    if [[ "${data}" != '{}' ]]; then
      cntools_table_pair Source 'Koios API · indexed weighted snapshot' muted
      cntools_table_pair 'Snapshot epoch' "$(jq -r .epoch_no <<< "${data}")" number
      for prefix in drep pool committee; do
        case "${prefix}" in drep) role=DRep ;; pool) role=SPO ;; *) role=Committee ;; esac
        for vote in yes no abstain; do
          count="$(jq -r --arg key "${prefix}_${vote}_votes_cast" '.[$key] // ""' <<< "${data}")"
          percentage="$(jq -r --arg key "${prefix}_${vote}_pct" '.[$key] // ""' <<< "${data}")"
          power="$(jq -r --arg key "${prefix}_${vote}_vote_power" '.[$key] // ""' <<< "${data}")"
          [[ -n "${power}" || "${vote}" != abstain ]] || power="$(jq -r --arg key "${prefix}_active_abstain_vote_power" '.[$key] // ""' <<< "${data}")"
          value=''
          [[ -z "${count}" ]] || value="$(cntools_number_format "${count}") votes"
          [[ -z "${power}" ]] || value+=" · $(cntools_number_format_lovelace "${power}") voting power"
          [[ -z "${percentage}" ]] || value+=" · $(cntools_number_format "${percentage}") %"
          [[ -z "${value}" ]] || cntools_table_pair "${role} · ${vote^}" "${value}" number
        done
      done
    else cntools_table_pair 'Voting power' 'Unavailable · vote counts are not voting power' muted; fi
    while IFS=$'\037' read -r label value; do
      [[ -z "${label}" ]] || cntools_table_pair "${label}" "${value}" number
    done < <(cntools_voting_thresholds "${record}")
    [[ -z "${CNTOOLS_VOTING_PARAMETERS_SOURCE}" ]] || cntools_table_pair 'Threshold source' "${CNTOOLS_VOTING_PARAMETERS_SOURCE} · current parameters" muted
    [[ -z "${CNTOOLS_VOTING_COMMITTEE_SOURCE}" ]] || cntools_table_pair 'Quorum source' "${CNTOOLS_VOTING_COMMITTEE_SOURCE} · current committee" muted
  } | cntools_table_render 'Voting power & thresholds · advisory, not a ratification decision'
}
