#!/usr/bin/env bash
# Read-only proposal browser; display text never serves as a transaction identity.
cntools_proposal_render() {
  local record="$1" ordinal="${2:-}" title='' kind='' id='' expires='' proposed='' role='' count='' yes='' no='' abstain=''
  title="$(jq -r '.title | if type == "string" and length > 0 then . else "Governance proposal" end' <<< "${record}")" || return 1
  kind="$(jq -r .type <<< "${record}")"; id="$(jq -r .id <<< "${record}")"
  proposed="$(jq -r .proposed <<< "${record}")"; expires="$(jq -r .expires <<< "${record}")"
  [[ -z "${ordinal}" ]] || title="${ordinal} · ${title}"
  {
    cntools_table_pair Type "${kind}" accent
    cntools_table_pair 'Proposal ID' "${id}" identifier
    cntools_table_pair 'Proposed epoch' "$(cntools_number_format "${proposed}")" number
    cntools_table_pair 'Last voting epoch' "$(cntools_number_format "${expires}")" number
    if [[ "$(jq -r .ratified <<< "${record}")" == true ]]; then cntools_table_pair Status 'Ratified · awaiting enactment' success; fi
    for role in DRep Committee SPO; do
      count="$(jq -r --arg role "${role}" '.counts[$role] | if . == null then "" else [.Yes,.No,.Abstain] | map(tostring) | join(" ") end' <<< "${record}")"
      if [[ -n "${count}" ]]; then
        read -r yes no abstain <<< "${count}"
        cntools_table_pair "${role} votes" "Yes $(cntools_number_format "${yes}") · No $(cntools_number_format "${no}") · Abstain $(cntools_number_format "${abstain}")" number
      fi
    done
  } | cntools_table_render "${title}"
  cntools_voting_stats_render "${record}"
}

cntools_proposal_tree() {
  local data="$1" heading="$2" rows='' path='' value=''
  rows="$(jq -r '
    [paths(scalars) as $p | select(getpath($p) != null) |
      [($p | map(tostring) | join(" / ")), (getpath($p)|tostring)] |
      map(gsub("[\u0000-\u001f\u007f]";" ")) | join("\u001f")] |
    if length <= 400 then .[] else .[0:400][], "…\u001fRemaining fields omitted from this view" end
  ' <<< "${data}")" || return 1
  {
    while IFS=$'\037' read -r path value; do
      [[ -z "${path}" ]] || cntools_table_pair "${path}" "${value}"
    done <<< "${rows}"
  } | cntools_table_render "${heading}"
}

cntools_proposal_details() {
  local record="$1" url='' hash='' deposit='' returned='' metadata='' action=''
  [[ -n "${CNTOOLS_VOTING_PARAMETERS_SOURCE}" ]] || cntools_ui_spin_function 'Checking voting thresholds…' cntools_voting_parameters_collect || true
  cntools_ui_spin_function 'Checking indexed voting power…' cntools_voting_stats_collect "${record}" || true
  cntools_proposal_render "${record}" || return 1
  url="$(jq -r '.anchor.url // ""' <<< "${record}")"; hash="$(jq -r '.anchor.dataHash // ""' <<< "${record}")"
  deposit="$(jq -r '.deposit // ""' <<< "${record}")"; returned="$(jq -r '.returnAddress // "" | if type == "string" then . else tojson end' <<< "${record}")"
  {
    [[ ! "${deposit}" =~ ^[0-9]+$ ]] || cntools_table_pair 'Proposal deposit' "$(cntools_number_format_lovelace "${deposit}")" number
    [[ -z "${returned}" ]] || cntools_table_pair 'Deposit return address' "${returned}" address
    [[ -z "${url}" ]] || cntools_table_pair 'Metadata URL' "${url}" address
    [[ -z "${hash}" ]] || cntools_table_pair 'Metadata hash' "${hash}" identifier
  } | cntools_table_render 'Proposal details'
  action="$(jq -c '.action | del(.tag)' <<< "${record}")" || return 1
  cntools_proposal_tree "${action}" 'On-chain action' || return 1
  metadata="$(jq -c '.metadata.body // .metadata // {}' <<< "${record}")" || return 1
  if [[ "${metadata}" != '{}' ]]; then
    cntools_ui_render_status info 'Proposal metadata is indexed by Koios. It is untrusted descriptive content, not independently hash-verified by CNTools.'
    cntools_proposal_tree "${metadata}" 'Metadata · Koios API' || return 1
  fi
  cntools_public_metadata_offer "${url}" "${hash}"
}

cntools_governance_action_proposals() {
  local size='' page=0 total=0 first=0 last=0 index=0 record='' choice='' selection=''
  local -a choices=()
  cntools_ui_action_begin 'List Proposals' '/ Vote / Governance / List Proposals'
  if ! cntools_ui_spin_function 'Collecting active governance proposals…' cntools_proposals_query; then
    cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR:-Proposal lookup failed.}"; cntools_ui_wait; return 1
  fi
  total="$(jq length <<< "${CNTOOLS_PROPOSALS}")" || return 1
  if ((total == 0)); then cntools_ui_render_status info 'There are no active governance proposals.'; cntools_ui_wait; return 0; fi
  while true; do
    cntools_ui_input size 'Proposals per page (1–10; Enter uses 5)' '5 (default)' || return 0
    size="${size:-5}"
    [[ "${size}" =~ ^([1-9]|10)$ ]] && break
    cntools_ui_render_status warn 'Enter a whole number from 1 to 10.'
  done
  while true; do
    [[ "${CNTOOLS_VOTING_PARAMETERS_CHECKED}" == Y ]] || cntools_ui_spin_function 'Checking voting thresholds…' cntools_voting_parameters_collect || true
    cntools_ui_action_begin 'List Proposals' '/ Vote / Governance / List Proposals'
    total="$(jq length <<< "${CNTOOLS_PROPOSALS}")" || return 1
    first=$((page*size)); last=$((first+size)); ((last <= total)) || last="${total}"
    {
      if [[ "${CNTOOLS_PROPOSAL_BACKEND}" == local ]]; then cntools_table_pair Source 'Local node' identifier
      else cntools_table_pair Source 'Koios API' identifier; fi
      cntools_table_pair 'Current epoch' "$(cntools_number_format "${CNTOOLS_PROPOSAL_EPOCH}")" number
      cntools_table_pair 'Active proposals' "$(cntools_number_format "${total}")" number
      ((total == 0)) || cntools_table_pair Showing "$((first+1))–${last}" number
    } | cntools_table_render 'Governance'
    for ((index=first; index<last; index++)); do
      record="$(jq -c --argjson n "${index}" '.[$n]' <<< "${CNTOOLS_PROPOSALS}")" || return 1
      cntools_ui_spin_function 'Checking indexed voting power…' cntools_voting_stats_collect "${record}" || true
      cntools_proposal_render "${record}" "$((index+1))" || return 1
    done
    choices=()
    ((total == 0)) || choices+=('View proposal details')
    ((last >= total)) || choices+=('Next page')
    ((page == 0)) || choices+=('Previous page')
    choices+=(Refresh Back)
    cntools_ui_choose choice 'Proposals' "${choices[@]}" || return 0
    case "${choice}" in
      'Next page') page=$((page+1)) ;;
      'Previous page') page=$((page-1)) ;;
      Refresh)
        if cntools_ui_spin_function 'Refreshing governance proposals…' cntools_proposals_query; then page=0
        else cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR}"; cntools_ui_wait; fi ;;
      'View proposal details')
        cntools_ui_input selection 'Proposal number or ID' 'Number from the list, gov_action1… or transaction-hash#index' || continue
        if cntools_proposal_select "${selection}"; then
          cntools_ui_action_begin 'Proposal details' '/ Vote / Governance / List Proposals'
          cntools_proposal_details "${CNTOOLS_PROPOSAL_SELECTED}" || return 1
        else cntools_ui_render_status warn 'Choose an active proposal from this catalog.'; fi
        cntools_ui_wait ;;
      Back) return 0 ;;
    esac
  done
}
