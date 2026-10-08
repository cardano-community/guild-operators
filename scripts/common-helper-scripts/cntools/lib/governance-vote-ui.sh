#!/usr/bin/env bash
# DRep choices; technical transaction details stay in the log/shared signer view.
# shellcheck disable=SC2034,SC2015
cntools_gov_vote_render_rows() {
  cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_LIFECYCLE_ID}" identifier
  cntools_transaction_ui_styled_row 'Proposal ID' "$(jq -r .id <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")" identifier
  cntools_transaction_ui_styled_row 'Action type' "$(jq -r .type <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")" value
  cntools_transaction_ui_styled_row Vote "${CNTOOLS_GOV_VOTE_DECISION}" accent
  if [[ "${CNTOOLS_GOV_VOTE_PREVIOUS}" != null ]]; then
    cntools_transaction_ui_styled_row 'Replaces vote' "$(jq -r . <<< "${CNTOOLS_GOV_VOTE_PREVIOUS}")" warning
  fi
  if [[ -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
    cntools_transaction_ui_styled_row 'Rationale URL' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" address
    cntools_transaction_ui_styled_row 'Rationale hash' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" identifier
  fi
}

cntools_gov_vote_hash_into() {
  local target="$1" file="$2" output='' errors='' value='' status=0
  cntools_transaction_file_safe "${file}" 4194304 && jq -se 'length == 1 and (.[0]|type == "object")' "${file}" >/dev/null || {
    cntools_wallet_register_set_error 'Select a readable CIP-100 rationale JSON object, at most 4 MiB, not a symlink.'; return 1;
  }
  cntools_transaction_temp_file output vote-anchor-hash || return 1
  cntools_transaction_temp_file errors vote-anchor-errors || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" hash anchor-data --file-binary "${file}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Vote rationale hashing failed' "${status}" "${errors}" "${output}"; return 1; fi
  value="$(< "${output}")"; [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf -v "${target}" '%s' "${value}"
}

cntools_gov_vote_choose_rationale() {
  local choice='' method='' url='' hash='' file=''
  while true; do
    cntools_ui_choose choice 'Vote rationale' 'No rationale anchor' 'Add rationale anchor' Cancel || return $?
    case "${choice}" in
      Cancel) return 1 ;;
      'No rationale anchor') CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL='' CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=''; return 0 ;;
      'Add rationale anchor')
        cntools_ui_render_status info 'Publish a prepared CIP-100 rationale first. CNTools records its URL and exact-byte hash, but does not upload the document or validate its complete schema. The anchor is public.'
        cntools_ui_input url 'Published rationale URL' 'https://… or ipfs://… (maximum 128 bytes)' || return $?
        cntools_ui_choose method 'Rationale hash' 'Hash local JSON file' 'Enter known hash' Cancel || return $?
        case "${method}" in
          Cancel) continue ;;
          'Hash local JSON file')
            cntools_ui_input file 'Rationale JSON file' 'Absolute path to the exact published bytes' || return $?
            if ! cntools_ui_spin_function 'Hashing vote rationale…' cntools_gov_vote_hash_into hash "${file}"; then
              cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR:-Could not hash that rationale.}"; continue
            fi ;;
          'Enter known hash') cntools_ui_input hash 'Rationale hash' '64 hexadecimal characters (Blake2b-256)' || return $?; hash="${hash,,}" ;;
        esac
        if ! cntools_drep_lifecycle_anchor_valid "${url}" "${hash}"; then
          cntools_ui_render_status warn 'Use an HTTP(S) or IPFS URL of at most 128 bytes and a 64-character hexadecimal hash.'; continue
        fi
        CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL="${url}" CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="${hash}"
        cntools_transaction_log CHOICE "Vote rationale url=${url} hash=${hash}"
        return 0 ;;
    esac
  done
}

cntools_gov_vote_choose() {
  local record='' title='' selection='' ordinal=0 previous='' vote='' id=''
  local -a choices=()
  while IFS= read -r record; do
    [[ -n "${record}" ]] || continue
    ordinal=$((ordinal+1))
    if ! cntools_gov_vote_eligible "${record}"; then continue; fi
    title="$(jq -r '.title | if type == "string" and length > 0 then . else "Governance proposal" end' <<< "${record}")"
    cntools_wallet_sanitize_display_into title "${title}" || return 2
    id="$(jq -r '.tx[0:12]+"…#"+(.index|tostring)' <<< "${record}")" || return 2
    choices+=("${ordinal} · $(jq -r .type <<< "${record}") · ${title:0:70} · ${id}")
  done <<< "$(jq -c '.[]' <<< "${CNTOOLS_PROPOSALS}")"
  CNTOOLS_WALLET_REGISTER_ERROR=''
  if ((${#choices[@]} == 0)); then cntools_wallet_register_set_error 'No active proposals are currently eligible for a DRep vote.'; return 2; fi
  choices+=(Cancel)
  while true; do
    cntools_wallet_register_begin
    cntools_ui_choose selection 'Select governance proposal' "${choices[@]}" || return $?
    [[ "${selection}" != Cancel ]] || return 1
    cntools_proposal_select "${selection%% *}" || return 2
    CNTOOLS_GOV_VOTE_PROPOSAL="${CNTOOLS_PROPOSAL_SELECTED}"
    cntools_proposal_details "${CNTOOLS_GOV_VOTE_PROPOSAL}" || return 2
    if ! cntools_ui_confirm 'Use this proposal?' false; then continue; fi
    cntools_gov_vote_previous_into previous "${CNTOOLS_GOV_VOTE_PROPOSAL}" || {
      cntools_wallet_register_set_error 'Your previous vote could not be verified. Nothing was built.'; return 2;
    }
    CNTOOLS_GOV_VOTE_PREVIOUS="${previous}"
    if [[ "${previous}" != null ]]; then
      cntools_ui_render_status warn "This replaces your previous vote: $(jq -r . <<< "${previous}")."
      cntools_ui_confirm 'Prepare a replacement vote?' false || return $?
    fi
    cntools_ui_choose vote 'Vote decision' Yes No Abstain Cancel || return $?
    [[ "${vote}" != Cancel ]] || return 1
    CNTOOLS_GOV_VOTE_DECISION="${vote}"
    cntools_gov_vote_choose_rationale || return $?
    id="$(jq -r .id <<< "${CNTOOLS_GOV_VOTE_PROPOSAL}")"
    cntools_transaction_log CHOICE "Governance vote proposal=${id} drep=${CNTOOLS_DREP_LIFECYCLE_ID} decision=${vote} previous=${previous}"
    cntools_ui_render_status info 'Casting costs only the transaction fee. Voting does not renew DRep activity; use DRep Registration / Update if needed.'
    return 0
  done
}

cntools_governance_action_cast() {
  cntools_wallet_register_operation_set gov-vote || return 1
  cntools_wallet_action_stake_lifecycle
}
