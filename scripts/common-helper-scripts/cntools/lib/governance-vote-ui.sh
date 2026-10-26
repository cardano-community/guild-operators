#!/usr/bin/env bash
# DRep choices; technical transaction details stay in the log/shared signer view.
# shellcheck disable=SC2034,SC2015
cntools_gov_vote_render_rows() {
  local title='' previous='' kind=''
  title="$(jq -r '.title | if type == "string" and length > 0 then . else "" end' <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"
  cntools_text_sanitize_into title "${title}" || title=''
  cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_LIFECYCLE_ID}" identifier
  [[ -z "${CNTOOLS_GOV_VOTE_POWER}" ]] ||
    cntools_transaction_ui_styled_row "${CNTOOLS_DREP_POWER_LABEL:-Voting power}" "$(cntools_number_format_lovelace "${CNTOOLS_GOV_VOTE_POWER}")" number
  [[ -z "${title}" ]] || cntools_transaction_ui_styled_row Proposal "${title:0:90}" value
  cntools_transaction_ui_styled_row 'Proposal ID' "$(jq -r .id <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")" identifier
  cntools_proposal_type_label_into kind "$(jq -r .type <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"
  cntools_transaction_ui_styled_row 'Action type' "${kind}" value
  cntools_transaction_ui_styled_row Vote "${CNTOOLS_GOV_VOTE_DECISION}" accent
  if [[ "${CNTOOLS_GOV_VOTE_PREVIOUS}" != null ]]; then
    cntools_gov_vote_label_into previous "${CNTOOLS_GOV_VOTE_PREVIOUS}"
    cntools_transaction_ui_styled_row 'Replaces vote' "${previous}" warning
  fi
  if [[ -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
    cntools_transaction_ui_styled_row 'Rationale URL' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" address
    cntools_transaction_ui_styled_row 'Rationale hash' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" identifier
  fi
}

cntools_gov_vote_hash_into() {
  local target="$1" file="$2" output='' errors='' value='' status=0
  # Errors go to CNTOOLS_TRANSACTION_ERROR, which the anchor prompt shows and clears.
  cntools_transaction_file_safe "${file}" 4194304 && jq -se 'length == 1 and (.[0]|type == "object")' "${file}" >/dev/null 2>&1 || {
    cntools_transaction_set_error 'Select a readable CIP-100 rationale JSON object, at most 4 MiB, not a symlink.'; return 1;
  }
  cntools_transaction_temp_file output vote-anchor-hash || return 1
  cntools_transaction_temp_file errors vote-anchor-errors || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" hash anchor-data --file-binary "${file}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Vote rationale hashing failed' "${status}" "${errors}" "${output}"; return 1; fi
  value="$(< "${output}")"
  [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || { cntools_transaction_set_error 'Cardano CLI returned an invalid rationale hash.'; return 1; }
  printf -v "${target}" '%s' "${value}"
}

# Optional "change" (from the review): the current rationale can be kept.
cntools_gov_vote_choose_rationale() {
  local choice='' url='' hash='' status=0
  local -a choices=('No rationale anchor' 'Add rationale anchor' Cancel)
  [[ "${1:-}" != change || -z "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]] ||
    choices=('Keep current rationale' 'Replace rationale anchor' 'Remove rationale anchor' Cancel)
  while true; do
    cntools_ui_choose choice 'Vote rationale' "${choices[@]}" || return $?
    case "${choice}" in
      Cancel) return 1 ;;
      'Keep current rationale') return 0 ;;
      'No rationale anchor'|'Remove rationale anchor') CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''; return 0 ;;
      'Add rationale anchor'|'Replace rationale anchor')
        cntools_ui_render_status info 'Publish a prepared CIP-100 rationale first. CNTools records its URL and exact-byte hash, but does not upload the document or validate its complete schema. The anchor is public.'
        status=0
        cntools_ui_input url 'Published rationale URL' 'https://… or ipfs://… (maximum 128 bytes)' || status=$?
        ((status == 0)) || { ((status == 1)) && continue; return "${status}"; }
        if ! cntools_drep_lifecycle_anchor_valid "${url}" "$(printf '%064d' 0)"; then
          cntools_ui_render_status warn 'Use an HTTP(S) or IPFS URL of at most 128 bytes.'; continue
        fi
        cntools_public_metadata_anchor_hash_into hash "${url}" 'vote rationale' Rationale cntools_gov_vote_hash_into 4194304 || status=$?
        ((status == 0)) || { ((status == 1)) && continue; return "${status}"; }
        if ! cntools_drep_lifecycle_anchor_valid "${url}" "${hash}"; then
          cntools_ui_render_status warn 'Use an HTTP(S) or IPFS URL of at most 128 bytes and a 64-character hexadecimal hash.'; continue
        fi
        CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL="${url}" CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="${hash}"
        cntools_transaction_log CHOICE "Vote rationale url=${url} hash=${hash}"
        return 0 ;;
      *) return 2 ;;
    esac
  done
}

# The decision menu for the selected proposal, with the published-metadata
# check offered alongside the votes. Optional current decision is marked.
# Returns 1 on Esc or Back.
cntools_gov_vote_decision_into() {
  local vd_output="$1" vd_current="${2:-}" vd_choice='' vd_url='' vd_hash='' vd_option='' vd_back="${3:-Back to proposals}"
  local -a vd_choices=()
  vd_url="$(jq -r '.anchor.url // ""' <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"; vd_hash="$(jq -r '.anchor.dataHash // ""' <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"
  for vd_option in Yes No Abstain; do
    [[ "${vd_option}" != "${vd_current}" ]] || vd_option+=' · current'
    vd_choices+=("${vd_option}")
  done
  ! cntools_public_metadata_verifiable "${vd_url}" "${vd_hash}" || vd_choices+=('Verify published metadata')
  while true; do
    cntools_ui_choose vd_choice 'Vote decision' "${vd_choices[@]}" "${vd_back}" || return $?
    case "${vd_choice}" in
      'Verify published metadata')
        # Checked once; the result stays on screen above the menu.
        vd_choices=("${vd_choices[@]:0:3}")
        if [[ "${CNTOOLS_PROPOSAL_METADATA_SHOWN:-N}" == Y ]]; then
          cntools_public_metadata_verify "${vd_url}" "${vd_hash}" 262144 shown
        else
          cntools_public_metadata_verify "${vd_url}" "${vd_hash}"
        fi ;;
      "${vd_back}") return 1 ;;
      *) printf -v "${vd_output}" '%s' "${vd_choice% · current}"; return 0 ;;
    esac
  done
}

# Declining a replacement, or Esc/Back at the decision or rationale, returns
# to the proposal list; only Cancel there (or Ctrl+C) ends the action.
cntools_gov_vote_choose() {
  local record='' title='' selection='' ordinal=0 previous='' label='' vote='' id='' kind='' status=0
  local -a choices=()
  while IFS= read -r record; do
    [[ -n "${record}" ]] || continue
    ordinal=$((ordinal+1))
    if ! cntools_gov_vote_eligible "${record}"; then continue; fi
    title="$(jq -r '.title | if type == "string" and length > 0 then . else "Governance proposal" end' <<< "${record}")"
    cntools_text_sanitize_into title "${title}" || return 2
    id="$(jq -r '.tx[0:12]+"…#"+(.index|tostring)' <<< "${record}")" || return 2
    cntools_proposal_type_label_into kind "$(jq -r .type <<< "${record}")"
    choices+=("${ordinal} · ${kind} · ${title:0:70} · ${id}")
  done <<< "$(jq -c '.[]' <<< "${CNTOOLS_PROPOSALS}")"
  CNTOOLS_WALLET_REGISTER_ERROR=''
  # Collect already returned 7 for this; kept for a proposal set that changed.
  if ((${#choices[@]} == 0)); then cntools_gov_vote_any_eligible; return 2; fi
  choices+=(Cancel)
  while true; do
    cntools_wallet_register_begin
    cntools_ui_choose selection 'Select governance proposal' "${choices[@]}" || return $?
    [[ "${selection}" != Cancel ]] || return 1
    cntools_proposal_select "${selection%% *}" || return 2
    CNTOOLS_GOV_VOTE_PROPOSAL="${CNTOOLS_PROPOSAL_SELECTED}"
    status=0
    cntools_proposal_details "${CNTOOLS_GOV_VOTE_PROPOSAL}" vote || status=$?
    ((status != 130)) || return 130
    ((status == 0)) || return 2
    cntools_gov_vote_previous_into previous "${CNTOOLS_GOV_VOTE_PROPOSAL}" || {
      cntools_wallet_register_set_error 'Your previous vote could not be verified. Nothing was built.'; return 2;
    }
    CNTOOLS_GOV_VOTE_PREVIOUS="${previous}"
    if [[ "${previous}" != null ]]; then
      cntools_gov_vote_label_into label "${previous}"
      cntools_ui_render_status warn "This replaces your previous vote: ${label}."
      status=0
      cntools_ui_confirm 'Prepare a replacement vote?' false || status=$?
      ((status != 130)) || return 130
      ((status == 0)) || continue
    fi
    status=0
    cntools_gov_vote_decision_into vote || status=$?
    ((status != 130)) || return 130
    ((status == 0)) || continue
    CNTOOLS_GOV_VOTE_DECISION="${vote}"
    status=0
    cntools_gov_vote_choose_rationale || status=$?
    ((status != 1)) || continue
    ((status == 0)) || return "${status}"
    id="$(jq -r .id <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"
    cntools_transaction_log CHOICE "Governance vote proposal=${id} drep=${CNTOOLS_DREP_LIFECYCLE_ID} decision=${vote} previous=${previous}"
    return 0
  done
}

# Review step 'Change vote': decision and rationale for the selected proposal.
# Esc keeps the reviewed values (1), Ctrl+C cancels (130); 0 when anything
# changed, so the caller rebuilds.
cntools_gov_vote_change() {
  local cv_decision="${CNTOOLS_GOV_VOTE_DECISION}" cv_url="${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" cv_hash="${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}"
  local cv_vote='' cv_status=0
  # The review is on screen, not the indexed metadata: a check shows the bytes.
  local CNTOOLS_PROPOSAL_METADATA_SHOWN=N
  cntools_gov_vote_decision_into cv_vote "${cv_decision}" Cancel || cv_status=$?
  if ((cv_status == 0)); then
    CNTOOLS_GOV_VOTE_DECISION="${cv_vote}"
    cntools_gov_vote_choose_rationale change || cv_status=$?
  fi
  if ((cv_status != 0)); then
    CNTOOLS_GOV_VOTE_DECISION="${cv_decision}" CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL="${cv_url}" CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="${cv_hash}"
    ((cv_status == 130)) && return 130
    return 1
  fi
  [[ "${CNTOOLS_GOV_VOTE_DECISION}|${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}|${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" != "${cv_decision}|${cv_url}|${cv_hash}" ]] || return 1
  cntools_transaction_log CHOICE "Governance vote changed decision=${CNTOOLS_GOV_VOTE_DECISION} previous_decision=${cv_decision} rationale=${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL:-none}"
}

cntools_governance_action_cast() {
  cntools_wallet_register_operation_set gov-vote || return 1
  cntools_wallet_action_stake_lifecycle
}
