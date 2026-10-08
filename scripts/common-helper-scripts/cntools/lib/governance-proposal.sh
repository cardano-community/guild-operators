#!/usr/bin/env bash
# Active proposal catalog. On-chain identities, not off-chain titles, are authoritative.
# shellcheck disable=SC2034
CNTOOLS_PROPOSALS='[]'
CNTOOLS_PROPOSAL_EPOCH=0
CNTOOLS_PROPOSAL_BACKEND=''
CNTOOLS_PROPOSAL_SELECTED='{}'

# CIP-129 uses a one-byte action index. The ledger/CLI also accepts Word16:
# retain hash#index for larger indices instead of truncating them to a CIP ID.
cntools_proposal_id_into() {
  local -n gp_id_result="$1"
  local gp_tx="$2" gp_ix="$3" gp_hex=''
  [[ "${gp_tx}" =~ ^[0-9a-f]{64}$ && "${gp_ix}" =~ ^(0|[1-9][0-9]{0,4})$ ]] || return 2
  (( gp_ix <= 65535 )) || return 2
  if (( gp_ix > 255 )); then gp_id_result="${gp_tx}#${gp_ix}"; return 0; fi
  printf -v gp_hex '%02x' "${gp_ix}"
  cntools_drep_bech32_into "${1}" "${gp_tx}${gp_hex}" gov_action
}

cntools_proposals_parse() {
  local file="$1" backend="$2" epoch="$3" normalized=''
  [[ "${epoch}" =~ ^(0|[1-9][0-9]{0,7})$ && "${backend}" =~ ^(local|koios)$ ]] || return 2
  normalized="$(jq -cse --arg backend "${backend}" --argjson epoch "${epoch}" '
    def epoch: type == "number" and . >= 0 and . <= 99999999 and floor == .;
    def voteMap: type == "object" and all(.[]; . == "VoteYes" or . == "VoteNo" or . == "Abstain" or . == "VoteAbstain");
    def totals: [to_entries[].value] | {Yes:(map(select(. == "VoteYes"))|length),No:(map(select(. == "VoteNo"))|length),Abstain:(map(select(. == "Abstain" or . == "VoteAbstain"))|length)};
    select(length == 1) | .[0] |
    (if $backend == "local" then
      .proposals | if type == "object" then [.[]] else . end |
      if type != "array" then error("Missing proposal array") else . end |
      map(if (.actionId.txId | type == "string") and (.actionId.govActionIx | type == "number") and
        (.proposedIn | epoch) and (.expiresAfter | epoch) and
        (.proposalProcedure.govAction | type == "object") and
        (.dRepVotes | voteMap) and (.committeeVotes | voteMap) and (.stakePoolVotes | voteMap)
        then {tx:.actionId.txId,index:.actionId.govActionIx,type:.proposalProcedure.govAction.tag,
          proposed:.proposedIn,expires:.expiresAfter,action:.proposalProcedure.govAction,
          anchor:(.proposalProcedure.anchor // null),deposit:(.proposalProcedure.deposit|tostring),
          returnAddress:.proposalProcedure.returnAddr,metadata:null,title:null,ratified:false,
          votes:.dRepVotes,counts:{DRep:(.dRepVotes|totals),Committee:(.committeeVotes|totals),SPO:(.stakePoolVotes|totals)}}
        else error("Malformed local proposal") end)
    else
      if type != "array" then error("Missing Koios proposal array") else . end |
      map(if (.proposal_tx_hash | type == "string") and (.proposal_index | type == "number") and
        (.proposed_epoch | epoch) and (.expiration | epoch) and (.proposal_description | type == "object")
        then {tx:.proposal_tx_hash,index:.proposal_index,type:(if .proposal_type == "NewCommittee" then "UpdateCommittee" else .proposal_type end),proposed:.proposed_epoch,expires:.expiration,
          action:.proposal_description,anchor:(if .meta_url == null then null else {url:.meta_url,dataHash:.meta_hash} end),
          deposit:(.deposit|tostring),returnAddress:.return_address,metadata:.meta_json,
          title:(.meta_json.body.title // null),ratified:(.ratified_epoch != null),
          closed:(.enacted_epoch != null or .dropped_epoch != null or .expired_epoch != null),votes:null,counts:null,
          id:.proposal_id}
        else error("Malformed Koios proposal") end)
    end) |
    if all(.[]; (.tx | test("^[0-9a-f]{64}$")) and
      (.index >= 0 and .index <= 65535 and (.index|floor) == .index) and
      (.type | type == "string" and IN("ParameterChange","HardForkInitiation","TreasuryWithdrawals","NoConfidence","UpdateCommittee","NewConstitution","InfoAction")) and
      .type == .action.tag and .proposed <= $epoch and .expires >= .proposed and
      (.anchor == null or (.anchor.url | type == "string") and (.anchor.dataHash | type == "string" and test("^[0-9a-f]{64}$"))))
    then map(select(.expires >= $epoch and .closed != true)) | sort_by(.proposed,.tx,.index) | reverse
    else error("Invalid proposal identity or epoch") end |
    if ([.[] | [.tx,.index]] | length == (unique|length)) then . else error("Duplicate proposal") end
  ' "${file}")" || {
    cntools_transaction_set_error 'The governance proposal response could not be interpreted safely.'; return 1;
  }
  local id='' expected='' tx='' index='' result='[]'
  local -a identities=()
  # Validate every Koios CIP-129 identity against its transaction and index.
  while IFS=$'\037' read -r tx index id; do
    [[ -n "${tx}" ]] || continue
    cntools_proposal_id_into expected "${tx}" "${index}" || return 1
    [[ -z "${id}" || "${id}" == "${expected}" ]] || {
      cntools_transaction_set_error 'Koios returned a proposal ID that does not match its transaction and index.'; return 1;
    }
    identities+=("${expected}")
  done < <(jq -r '.[] | [.tx,(.index|tostring),(.id // "")] | join("\u001f")' <<< "${normalized}")
  result="$(jq -cs '.[0] as $list | .[1] as $ids | $list | to_entries | map(.value + {id:$ids[.key]})' \
    <(printf '%s\n' "${normalized}") <(printf '%s\n' "${identities[@]}" | jq -Rsc 'split("\n") | map(select(length>0))'))" || return 1
  CNTOOLS_PROPOSALS="${result}" CNTOOLS_PROPOSAL_EPOCH="${epoch}" CNTOOLS_PROPOSAL_BACKEND="${backend}"
}

cntools_proposals_query_backend() {
  local backend="$1" output='' errors='' tip='' epoch='' status=0 part='' combined='' offset=0 count=0
  local -a network=()
  [[ "${CNTOOLS_MODE:-}" != offline ]] || { cntools_transaction_set_error 'Proposal lookup needs a local node or Koios; saved transactions can still be signed offline.'; return 1; }
  cntools_transaction_temp_file output proposals || return 1
  cntools_transaction_temp_file tip proposals-tip || return 1
  if [[ "${backend}" == local ]]; then
    cntools_transaction_temp_file errors proposals-errors || return 1
    cntools_transaction_network_arguments_into network || return 1
    cntools_transaction_run_cli "${tip}" "${errors}" -- "${CNTOOLS_CLI}" latest query tip "${network[@]}" --socket-path "${CNTOOLS_SOCKET}" || status=$?
    if ((status == 0)); then
      cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest query gov-state "${network[@]}" --socket-path "${CNTOOLS_SOCKET}" --output-json || status=$?
    fi
    if ((status != 0)); then cntools_transaction_log_cli_failure 'Governance state query failed' "${status}" "${errors}" "${output}"; return 1; fi
    epoch="$(jq -er '.epoch | select(type == "number")' "${tip}")" || return 1
  elif [[ "${backend}" == koios && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]]; then
    cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/tip" '' "${tip}" 4194304 GET || return 1
    epoch="$(jq -er 'select(type == "array" and length == 1) | .[0].epoch_no | select(type == "number")' "${tip}")" || return 1
    [[ "${epoch}" =~ ^(0|[1-9][0-9]{0,7})$ ]] || return 1
    cntools_transaction_temp_file part proposals-page || return 1
    cntools_transaction_temp_file combined proposals-combined || return 1
    printf '[]\n' > "${output}"
    # Paginate below PostgRESTs row cap. Never silently present a truncated catalog.
    while ((offset < 10000)); do
      cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/proposal_list?expiration=gte.${epoch}&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null&limit=500&offset=${offset}" '' "${part}" 33554432 GET || return 1
      count="$(jq -er 'select(type == "array" and length <= 500) | length' "${part}")" || return 1
      jq -cs '.[0]+.[1]' "${output}" "${part}" > "${combined}" || return 1
      cntools_transaction_file_safe "${combined}" 33554432 || {
        cntools_transaction_set_error 'The active proposal catalog exceeded the 32 MiB safety limit.'; return 1;
      }
      cp -- "${combined}" "${output}" || return 1
      (( count == 500 )) || break
      offset=$((offset+500))
    done
    ((offset < 10000)) || { cntools_transaction_set_error 'The proposal catalog exceeded the safety limit. Nothing was truncated or selected.'; return 1; }
  else return 2; fi
  cntools_transaction_file_safe "${output}" 33554432 || return 1
  cntools_proposals_parse "${output}" "${backend}" "${epoch}" || return 1
  cntools_transaction_log QUERY "Active proposals backend=${backend} epoch=${epoch} count=$(jq length <<< "${CNTOOLS_PROPOSALS}")"
}

cntools_proposals_query() {
  if cntools_transaction_local_backend_ready && cntools_proposals_query_backend local; then return 0; fi
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y ]] && cntools_proposals_query_backend koios; then return 0; fi
  cntools_transaction_set_error 'Active governance proposals could not be collected. Check the local node or Koios and the log.'
  return 1
}

cntools_proposal_select() {
  local selection="$1" count=0
  count="$(jq length <<< "${CNTOOLS_PROPOSALS}")" || return 1
  if [[ "${selection}" =~ ^[1-9][0-9]{0,4}$ ]] && ((selection <= count)); then
    CNTOOLS_PROPOSAL_SELECTED="$(jq -c --argjson n "$((selection-1))" '.[$n]' <<< "${CNTOOLS_PROPOSALS}")"
  else
    CNTOOLS_PROPOSAL_SELECTED="$(jq -ce --arg id "${selection}" '[.[] | select(.id == $id or (.tx+"#"+(.index|tostring)) == $id)] | select(length == 1) | .[0]' <<< "${CNTOOLS_PROPOSALS}")" || return 1
  fi
}
