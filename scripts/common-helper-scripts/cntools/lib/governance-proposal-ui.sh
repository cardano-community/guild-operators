#!/usr/bin/env bash
# Read-only proposal browser; display text never serves as a transaction identity.
# With an ordinal (a list page) one compact card that leaves page-wide facts
# to the page header; without one, the card and the full statistics table.
cntools_proposal_render() {
  local record="$1" ordinal="${2:-}" title='' kind='' id='' expires='' proposed='' role='' count='' yes='' no='' abstain='' stats=N untitled=N roles=''
  title="$(jq -r '.title | if type == "string" and length > 0 then . else "" end' <<< "${record}")" || return 1
  cntools_text_sanitize_into title "${title}" || title=''
  kind="$(jq -r .type <<< "${record}")"; id="$(jq -r .id <<< "${record}")"
  cntools_proposal_type_label_into kind "${kind}"
  # Without an off-chain title the type names the card (no repeated Type row).
  [[ -n "${title}" ]] || { title="${kind}"; untitled=Y; }
  proposed="$(jq -r .proposed <<< "${record}")"; expires="$(jq -r .expires <<< "${record}")"
  [[ -z "${ordinal}" ]] || title="${ordinal} · ${title}"
  ! cntools_voting_stats_present "${record}" || stats=Y
  cntools_voting_roles_into roles "${record}"
  {
    [[ "${untitled}" == Y ]] || cntools_table_pair Type "${kind}" accent
    cntools_table_pair 'Proposal ID' "${id}" identifier
    cntools_table_pair 'Proposed epoch' "$(cntools_number_format "${proposed}")" number
    cntools_table_pair 'Last voting epoch' "$(cntools_number_format "${expires}")" number
    if [[ "$(jq -r .ratified <<< "${record}")" == true ]]; then cntools_table_pair Status 'Ratified · awaiting enactment' success; fi
    # Indexed statistics already count the votes per role; only the roles
    # that vote on this kind of action are listed.
    for role in DRep Committee SPO; do
      [[ "${stats}" == N ]] || break
      [[ " ${roles} " == *" ${role} "* ]] || continue
      count="$(jq -r --arg role "${role}" '.counts[$role] | if . == null then "" else [.Yes,.No,.Abstain] | map(tostring) | join(" ") end' <<< "${record}")"
      if [[ -n "${count}" ]]; then
        read -r yes no abstain <<< "${count}"
        cntools_table_pair "${role} votes" "Yes $(cntools_number_format "${yes}") · No $(cntools_number_format "${no}") · Abstain $(cntools_number_format "${abstain}")" number
      fi
    done
    [[ -z "${ordinal}" ]] || cntools_voting_stats_rows "${record}" page
  } | cntools_table_render "${title}"
  [[ -n "${ordinal}" ]] || cntools_voting_stats_render "${record}"
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

# Optional "vote": the caller offers the metadata check in its own menu, so
# no download is offered here. CNTOOLS_PROPOSAL_METADATA_SHOWN says whether
# indexed metadata is on screen. Returns 130 on Ctrl+C.
cntools_proposal_details() {
  local record="$1" mode="${2:-}" url='' hash='' deposit='' returned='' metadata='' action=''
  CNTOOLS_PROPOSAL_METADATA_SHOWN=N
  # Checked once per catalog, also when nothing was available.
  if [[ "${CNTOOLS_VOTING_PARAMETERS_CHECKED:-N}" != Y ]]; then
    if [[ "${mode}" == vote && -n "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE:-}" && "${CNTOOLS_PROPOSAL_BACKEND}" == local ]]; then
      # Cast already holds the current parameters and the local committee.
      cntools_voting_parameters_collect "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}" 'Local node' || true
    elif [[ "${mode}" == vote && -n "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE:-}" ]]; then
      cntools_ui_spin_function 'Checking voting thresholds…' cntools_voting_parameters_collect "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}" 'Koios API' || true
    else
      cntools_ui_spin_function 'Checking voting thresholds…' cntools_voting_parameters_collect || true
    fi
  fi
  # A spinner only when Koios is actually asked.
  if cntools_voting_stats_pending "${record}"; then
    cntools_ui_spin_function 'Checking indexed voting power…' cntools_voting_stats_collect "${record}" || true
  else
    cntools_voting_stats_collect "${record}" || true
  fi
  cntools_proposal_render "${record}" || return 1
  url="$(jq -r '.anchor.url // ""' <<< "${record}")"; hash="$(jq -r '.anchor.dataHash // ""' <<< "${record}")"
  deposit="$(jq -r '.deposit // ""' <<< "${record}")"
  cntools_proposal_return_address_into returned "$(jq -c '.returnAddress // ""' <<< "${record}")"
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
    CNTOOLS_PROPOSAL_METADATA_SHOWN=Y
  fi
  [[ "${mode}" != vote ]] || return 0
  # Already shown: a download then only verifies the published hash.
  if [[ "${CNTOOLS_PROPOSAL_METADATA_SHOWN}" == Y ]]; then
    cntools_public_metadata_offer "${url}" "${hash}" 262144 shown
  else
    cntools_public_metadata_offer "${url}" "${hash}"
  fi
}

# Page-wide facts once: source, epochs, statistics and threshold sources.
cntools_proposal_page_header() {
  local total="$1" first="$2" last="$3" index=0 record='' id='' epoch='' epochs=''
  for ((index=first; index<last; index++)); do
    record="$(jq -c --argjson n "${index}" '.[$n]' <<< "${CNTOOLS_PROPOSALS}")" || return 1
    cntools_voting_stats_present "${record}" || continue
    id="$(jq -r .id <<< "${record}")" || continue
    epoch="$(jq -r .epoch_no <<< "${CNTOOLS_VOTING_STATS[${id}]}")" || continue
    [[ " ${epochs//, / } " == *" ${epoch} "* ]] || epochs+="${epochs:+, }${epoch}"
  done
  {
    if [[ "${CNTOOLS_PROPOSAL_BACKEND}" == local ]]; then cntools_table_pair Source 'Local node' identifier
    else cntools_table_pair Source 'Koios API' identifier; fi
    cntools_table_pair 'Current epoch' "$(cntools_number_format "${CNTOOLS_PROPOSAL_EPOCH}")" number
    cntools_table_pair 'Active proposals' "$(cntools_number_format "${total}")" number
    ((total == 0)) || cntools_table_pair Showing "$((first+1))–${last}" number
    if [[ -n "${epochs}" ]]; then
      cntools_table_pair 'Voting power' "Koios API · indexed snapshot · epoch ${epochs}" muted
    else
      cntools_table_pair 'Voting power' 'Unavailable · vote counts are not voting power' muted
    fi
    cntools_voting_sources_rows
    cntools_table_pair Thresholds 'Advisory · not a ratification decision' muted
  } | cntools_table_render 'Governance'
}

# Asks for proposals per page; returns 1 on Esc, 130 on Ctrl+C.
cntools_proposal_page_size_into() {
  local pp_output="$1" pp_entered='' pp_normalized=''
  while true; do
    cntools_ui_input pp_entered 'Proposals per page (1–10; Enter uses 5)' '5 (default)' || return $?
    pp_entered="${pp_entered:-5}"
    if cntools_number_normalize_into pp_normalized "${pp_entered}" && [[ "${pp_normalized}" =~ ^([1-9]|10)$ ]]; then
      printf -v "${pp_output}" '%s' "${pp_normalized}"; return 0
    fi
    cntools_ui_render_status warn 'Enter a whole number from 1 to 10.'
  done
}

# Picks any proposal in the catalog, not only the current page; a single
# proposal needs no picker. Returns 1 on Back/Esc, 130 on Ctrl+C.
cntools_proposal_pick_into() {
  local pp_output="$1" pp_total=0 pp_index=0 pp_record='' pp_label='' pp_choice=''
  local -a pp_choices=()
  pp_total="$(jq length <<< "${CNTOOLS_PROPOSALS}")" || return 2
  if ((pp_total == 1)); then printf -v "${pp_output}" '%s' 1; return 0; fi
  for ((pp_index=0; pp_index<pp_total; pp_index++)); do
    pp_record="$(jq -c --argjson n "${pp_index}" '.[$n]' <<< "${CNTOOLS_PROPOSALS}")" || return 2
    cntools_proposal_label_into pp_label "${pp_record}" "$((pp_index+1))"
    pp_choices+=("${pp_label}")
  done
  cntools_ui_choose pp_choice 'Proposal details' "${pp_choices[@]}" Back || return $?
  [[ "${pp_choice}" != Back ]] || return 1
  printf -v "${pp_output}" '%s' "${pp_choice%% *}"
}

# Statistics for one page, behind one spinner only when Koios is asked.
cntools_proposal_page_stats() {
  local ps_index=0 ps_record='' ps_pending=N
  for ((ps_index=$1; ps_index<$2; ps_index++)); do
    ps_record="$(jq -c --argjson n "${ps_index}" '.[$n]' <<< "${CNTOOLS_PROPOSALS}")" || return 1
    ! cntools_voting_stats_pending "${ps_record}" || { ps_pending=Y; break; }
  done
  if [[ "${ps_pending}" == Y ]]; then
    cntools_ui_spin_function 'Checking indexed voting power…' cntools_voting_stats_collect_range "$1" "$2" || true
  else
    cntools_voting_stats_collect_range "$1" "$2" || true
  fi
}

cntools_governance_action_proposals() {
  local size=5 resized='' page=0 total=0 first=0 last=0 index=0 record='' choice='' selection='' status=0
  local -a choices=()
  cntools_ui_action_begin 'List Proposals' '/ Vote / Governance / List Proposals'
  if ! cntools_ui_spin_function 'Collecting active governance proposals…' cntools_proposals_query; then
    cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR:-Proposal lookup failed.}"; cntools_ui_wait; return 1
  fi
  total="$(jq length <<< "${CNTOOLS_PROPOSALS}")" || return 1
  if ((total == 0)); then cntools_ui_render_status info 'There are no active governance proposals.'; cntools_ui_wait; return 0; fi
  # Both styles start at five per page; 'Page size' changes it.
  cntools_log CHOICE 'Proposals per page default=5' || true
  while true; do
    [[ "${CNTOOLS_VOTING_PARAMETERS_CHECKED}" == Y ]] || cntools_ui_spin_function 'Checking voting thresholds…' cntools_voting_parameters_collect || true
    total="$(jq length <<< "${CNTOOLS_PROPOSALS}")" || return 1
    first=$((page*size)); last=$((first+size)); ((last <= total)) || last="${total}"
    cntools_proposal_page_stats "${first}" "${last}"
    cntools_ui_action_begin 'List Proposals' '/ Vote / Governance / List Proposals'
    cntools_proposal_page_header "${total}" "${first}" "${last}" || return 1
    for ((index=first; index<last; index++)); do
      record="$(jq -c --argjson n "${index}" '.[$n]' <<< "${CNTOOLS_PROPOSALS}")" || return 1
      cntools_proposal_render "${record}" "$((index+1))" || return 1
    done
    choices=()
    ((total == 0)) || choices+=('View proposal details')
    ((last >= total)) || choices+=('Next page')
    ((page == 0)) || choices+=('Previous page')
    choices+=('Page size' Refresh Back)
    status=0
    cntools_ui_choose choice 'Proposals' "${choices[@]}" || status=$?
    ((status != 130)) || return 130
    ((status == 0)) || return 0
    case "${choice}" in
      'Next page') page=$((page+1)) ;;
      'Previous page') page=$((page-1)) ;;
      'Page size')
        # Keep the first proposal on screen visible on the resized page.
        status=0
        cntools_proposal_page_size_into resized || status=$?
        ((status != 130)) || return 130
        if ((status == 0)); then page=$((first/resized)); size="${resized}"; fi ;;
      Refresh)
        if cntools_ui_spin_function 'Refreshing governance proposals…' cntools_proposals_query; then page=0
        else cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR}"; cntools_ui_wait; fi ;;
      'View proposal details')
        status=0
        cntools_proposal_pick_into selection || status=$?
        ((status != 130)) || return 130
        ((status == 0)) || continue
        cntools_proposal_select "${selection}" || return 1
        cntools_ui_action_begin 'Proposal details' '/ Vote / Governance / List Proposals'
        status=0
        cntools_proposal_details "${CNTOOLS_PROPOSAL_SELECTED}" || status=$?
        ((status != 130)) || return 130
        ((status == 0)) || return 1
        cntools_ui_wait ;;
      Back) return 0 ;;
    esac
  done
}
