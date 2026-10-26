#!/usr/bin/env bash
# Wallet-style public parameter editor and common transaction review/results.
# shellcheck disable=SC2034,SC2015
# Public settings only; private keys/passwords are never entered in this editor.
cntools_pool_registration_choose() {
  local -n pr_choice_ref="$1"
  local pr_choice_status=0
  cntools_ui_choose "$@" || pr_choice_status=$?
  cntools_transaction_log CHOICE "Pool menu=$2 selected=${pr_choice_ref} status=${pr_choice_status}"
  return "${pr_choice_status}"
}

cntools_pool_registration_input() {
  local -n pr_input_ref="$1"
  local pr_input_status=0
  cntools_ui_input "$@" || pr_input_status=$?
  cntools_transaction_log CHOICE "Pool input=$2 value=${pr_input_ref} status=${pr_input_status}"
  return "${pr_input_status}"
}

cntools_pool_registration_input_default() {
  local -n pid_result="$1"
  local pid_default="$3"
  cntools_pool_registration_input "$1" "$2${pid_default:+ · Enter keeps current}" "${pid_default}" || return $?
  if [[ -z "${pid_result}" ]]; then
    pid_result="${pid_default}"
    cntools_transaction_log CHOICE "Pool input=$2 kept default=${pid_default}"
  fi
}

cntools_pool_registration_begin() {
  cntools_ui_action_begin "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
}

# An owner or reward record's label; a hash without a local wallet or key
# file reads "Unknown owner · <hash>" (or "Unknown account" for rewards).
cntools_pool_registration_record_label() {
  jq -r --arg noun "${2:-owner}" 'if .label == .hash or .label == "" then "Unknown " + $noun + " · " + .hash else .label end' <<< "$1"
}

# One line per relay: "relay.example.com:3001", "1.2.3.4 / ::1:3001", "srv · SRV".
CNTOOLS_POOL_RELAY_TEXT_JQ='(if .type == "ip" then [.ipv4,.ipv6]|map(select(length>0))|join(" / ") else .dns end) +
  (if .port != null then ":"+(.port|tostring) else " · SRV" end)'

cntools_pool_registration_relay_rows() {
  local relay_text='' index=0
  while IFS= read -r relay_text; do
    index=$((index+1))
    cntools_table_pair "Relay ${index}" "${relay_text}" identifier
  done < <(jq -r ".[] | ${CNTOOLS_POOL_RELAY_TEXT_JQ}" <<< "${CNTOOLS_POOL_REG_RELAYS}")
  (( index != 0 )) || cntools_table_pair Relays 'None · private pool' muted
}

# Modify: "old → new" for a changed amount or margin.
cntools_pool_registration_change_value() {
  local before="$1" after="$2"
  [[ -n "${before}" && "${before}" != "${after}" ]] && printf '%s → %s' "${before}" "${after}" || printf '%s' "${after}"
}

cntools_pool_registration_rows() {
  local record='' index=0 margin='' owner_count='' hash='' state='' role='' changes='' retiring='' deposit=''
  local old_pledge='' old_cost='' old_margin='' old_reward='' old_metadata=''
  margin="$(cntools_pool_margin_percent "${CNTOOLS_POOL_REG_MARGIN}")" || return 1
  owner_count="$(jq length <<< "${CNTOOLS_POOL_REG_OWNERS}")"
  if [[ -n "${CNTOOLS_POOL_REG_BASELINE}" ]]; then
    old_pledge="$(cntools_number_format_lovelace "$(jq -r .pledge <<< "${CNTOOLS_POOL_REG_BASELINE}")")"
    old_cost="$(cntools_number_format_lovelace "$(jq -r .cost <<< "${CNTOOLS_POOL_REG_BASELINE}")")"
    old_margin="$(cntools_pool_margin_percent "$(jq -r '.margin|tostring' <<< "${CNTOOLS_POOL_REG_BASELINE}")/100000000") %"
    old_reward="$(jq -r .reward <<< "${CNTOOLS_POOL_REG_BASELINE}")"
    old_metadata="$(jq -r '.metadata.url // "None"' <<< "${CNTOOLS_POOL_REG_BASELINE}")"
    cntools_pool_registration_changes_into changes || return 1
  fi
  cntools_table_pair Pool "${CNTOOLS_POOL_REG_NAME}" identifier
  cntools_table_pair 'Pool ID' "${CNTOOLS_POOL_REG_ID}" identifier
  cntools_table_pair 'Funding wallet' "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
  [[ -z "${CNTOOLS_FUNDING_TOTAL:-}" ]] || cntools_table_pair 'Spendable ADA' "$(cntools_number_format_lovelace "${CNTOOLS_FUNDING_TOTAL}")" number
  retiring="$(jq -r '.retirement // ""' <<< "${CNTOOLS_POOL_REG_STATE}")"
  if [[ -n "${CNTOOLS_POOL_REG_BASELINE}" ]]; then
    if [[ -n "${changes}" ]]; then cntools_table_pair Changes "${changes}" accent
    elif [[ -n "${retiring}" ]]; then cntools_table_pair Changes 'None · re-registers to cancel the retirement' warning
    else cntools_table_pair Changes 'None · this would only pay a fee' warning; fi
  fi
  [[ -z "${retiring}" ]] || cntools_table_pair Retirement "Cancels the retirement scheduled for epoch $(cntools_number_format "${retiring}")" warning
  cntools_table_pair Pledge "$(cntools_pool_registration_change_value "${old_pledge}" "$(cntools_number_format_lovelace "${CNTOOLS_POOL_REG_PLEDGE}")")" number
  cntools_pool_stake_pledge_row
  cntools_table_pair 'Fixed cost' "$(cntools_pool_registration_change_value "${old_cost}" "$(cntools_number_format_lovelace "${CNTOOLS_POOL_REG_COST}")")" number
  cntools_table_pair Margin "$(cntools_pool_registration_change_value "${old_margin}" "${margin} %")" number
  if [[ -n "${CNTOOLS_POOL_REG_REWARD_HASH}" ]]; then
    record="$(jq -cn --arg reward_label "${CNTOOLS_POOL_REG_REWARD_LABEL}" --arg hash "${CNTOOLS_POOL_REG_REWARD_HASH}" '{label:$reward_label,hash:$hash}')"
    state=''; role=identifier
    cntools_pool_stake_state_into state role "${CNTOOLS_POOL_REG_REWARD_HASH}" reward || return 1
    cntools_table_pair 'Reward account' "$(cntools_pool_registration_record_label "${record}" account)${CNTOOLS_POOL_REG_REWARD_ADDRESS:+ · ${CNTOOLS_POOL_REG_REWARD_ADDRESS}}${state:+ · ${state}}" "${role}"
    [[ -z "${old_reward}" || "${old_reward}" == "${CNTOOLS_POOL_REG_REWARD_HASH}" ]] || cntools_table_pair 'Reward account · before' "${old_reward}" muted
  else
    cntools_table_pair 'Reward account' 'Not selected' warning
  fi
  while IFS= read -r record; do
    index=$((index+1)); hash="$(jq -r .hash <<< "${record}")"
    cntools_pool_stake_state_into state role "${hash}" owner || return 1
    cntools_table_pair "Owner ${index}$([[ "${index}" != 1 ]] || printf ' · main')" "$(cntools_pool_registration_record_label "${record}")${state:+ · ${state}}" "${role}"
    [[ "$(jq -r .vkey <<< "${record}")" != '' ]] || cntools_table_pair 'Public key' 'Required · select this owner to supply its public key or remove it' warning
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}")
  (( owner_count != 0 )) || cntools_table_pair Owners 'None selected' warning
  if [[ -n "${CNTOOLS_POOL_REG_BASELINE}" ]]; then
    while IFS= read -r hash; do cntools_table_pair 'Removed owner' "${hash}" warning; done < <(jq -r --argjson owners "${CNTOOLS_POOL_REG_OWNERS}" \
      '.owners - ($owners | map(.hash)) | .[]' <<< "${CNTOOLS_POOL_REG_BASELINE}")
  fi
  cntools_pool_registration_relay_rows
  [[ "${changes}" != *Relays* ]] || cntools_table_pair 'Relays · before' "$(jq -r "[.relays[] | ${CNTOOLS_POOL_RELAY_TEXT_JQ}] |
    if length == 0 then \"None\" else join(\", \") end" <<< "${CNTOOLS_POOL_REG_BASELINE}")" muted
  if [[ "${CNTOOLS_POOL_REG_METADATA}" == null ]]; then cntools_table_pair Metadata None muted
  else cntools_table_pair 'Metadata URL' "$(jq -r .url <<< "${CNTOOLS_POOL_REG_METADATA}")" identifier
    cntools_table_pair 'Metadata hash' "$(jq -r .hash <<< "${CNTOOLS_POOL_REG_METADATA}")" identifier
  fi
  [[ "${changes}" != *Metadata* ]] || cntools_table_pair 'Metadata · before' "${old_metadata}" muted
  deposit="${CNTOOLS_POOL_REG_POOL_DEPOSIT:-${CNTOOLS_WALLET_REGISTER_DEPOSIT}}"
  [[ "${deposit}" == 0 ]] || cntools_table_pair 'Pool deposit' "$(cntools_number_format_lovelace "${deposit}")" number
  [[ -z "${CNTOOLS_POOL_STAKE_SETUP_NOTE}" ]] || cntools_table_pair 'Stake setup' "${CNTOOLS_POOL_STAKE_SETUP_NOTE}" muted
  if [[ "${CNTOOLS_POOL_STAKE_PLAN:-[]}" != '[]' ]]; then
    cntools_table_pair 'Total deposits' "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")" number
  fi
}

cntools_pool_registration_render_plan() {
  local fee='' expiry=''
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]]; then
    cntools_pool_retirement_rows | cntools_table_render 'Pool retirement' || return 1
  else cntools_pool_registration_rows | cntools_table_render 'Pool settings' || return 1; fi
  cntools_transaction_ui_fee_into fee || return 1
  cntools_transaction_ui_expiry_label_into expiry "${CNTOOLS_WALLET_REGISTER_EXPIRY}"
  { cntools_table_pair Fee "$(cntools_number_format_lovelace "${fee}")" number
    cntools_table_pair Expires "${expiry}" number
    cntools_table_pair 'Input selection' "${CNTOOLS_TX_SELECTION_STRATEGY} · $(cntools_number_format "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}") inputs"
    cntools_table_pair 'Token fragmentation' "${CNTOOLS_CHANGE_TOKEN_STATUS}"
    cntools_table_pair 'ADA-only management' "${CNTOOLS_CHANGE_UTXO_STATUS}"
    cntools_table_pair 'Collateral candidate' "${CNTOOLS_CHANGE_COLLATERAL_STATUS}"
  } | cntools_table_render 'Transaction information'
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]]; then cntools_pool_retirement_notice
  else cntools_ui_render_status info 'Pledge is a commitment, not a transfer: every owner must stay registered, delegated to this pool and funded at rewards snapshots. This transaction does not start a node.'; fi
  [[ "${CNTOOLS_POOL_REG_COMBINE_HARDWARE}" != Y ]] || cntools_pool_registration_hardware_notice
}

cntools_pool_registration_hardware_notice() {
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]]; then
    cntools_ui_render_status info 'Hardware-funded retirement needs the funding payment key and pool cold key together on the same Ledger. Use a CLI/mnemonic funding wallet if the cold key is on a different device.'
  else cntools_ui_render_status info 'Pool operator signing needs the funding payment key and cold key on the same Ledger. Every hardware owner signs separately, including owners on that Ledger.'; fi
}

cntools_pool_registration_select_stake_into() {
  local output="$1" title="$2" choice='' selected='' file='' stake_record=''
  cntools_pool_registration_choose choice "${title}" 'CNTools wallet' 'External stake public key (offline signer)' Cancel || return $?
  case "${choice}" in
    'CNTools wallet')
      cntools_wallet_choose selected Cancel pool-owner || return $?
      # The editor redraws next and repeats this warning under its header.
      cntools_pool_wallet_stake_record_into stake_record "${selected}" || {
        cntools_ui_render_status warn 'The stake public key of this wallet could not be read or validated.'; return 3;
      } ;;
    'External stake public key (offline signer)')
      cntools_ui_pick_path file 'Stake verification key file' 'Choose a public .vkey; no private key is needed.' || return $?
      cntools_transaction_input_path_into file "${file}" && cntools_pool_stake_record_into stake_record "${file}" '' "${file##*/}" || {
        cntools_ui_render_status warn 'The stake public key could not be read or validated.'; return 3;
      } ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
  printf -v "${output}" '%s' "${stake_record}"
}

cntools_pool_registration_edit_owners() {
  local choice='' record='' display_record='' selected='' expected='' status=0 index=0 count=0
  local -a options=()
  while true; do
    cntools_pool_registration_begin
    index=0
    { while IFS= read -r display_record; do
        index=$((index+1))
        cntools_table_pair "Owner ${index}$([[ "${index}" != 1 ]] || printf ' · main')" "$(jq -r 'if .label == .hash or .label == "" then "Unknown owner · " + .hash else .label + " · " + .hash end' <<< "${display_record}")" identifier
      done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}");
    } | cntools_table_render Owners
    options=(Done 'Add owner'); count="$(jq length <<< "${CNTOOLS_POOL_REG_OWNERS}")"
    for ((index=0; index<count; index++)); do
      options+=("$((index+1)) · $(jq -r ".[${index}] | if .label == .hash or .label == \"\" then \"Unknown owner\" else .label end" <<< "${CNTOOLS_POOL_REG_OWNERS}")")
    done
    cntools_pool_registration_choose choice Owners "${options[@]}" Back || return $?
    case "${choice}" in
      Done|Back) return 0 ;;
      'Add owner')
        status=0; cntools_pool_registration_select_stake_into record 'Owner stake key' || status=$?
        ((status != 1 && status != 3)) || continue; ((status == 0)) || return "${status}"
        cntools_pool_owner_add "${record}" || return 2 ;;
      *)
        selected="${choice%% *}"; [[ "${selected}" =~ ^[0-9]+$ ]] || return 2
        index=$((selected-1)); expected="$(jq -r ".[${index}].hash" <<< "${CNTOOLS_POOL_REG_OWNERS}")"
        cntools_pool_registration_choose choice 'Owner key' 'Supply public key' 'Make main owner' 'Remove owner' Back || return $?
        case "${choice}" in
          'Remove owner') CNTOOLS_POOL_REG_OWNERS="$(jq -c --argjson index "${index}" 'del(.[$index])' <<< "${CNTOOLS_POOL_REG_OWNERS}")" ;;
          'Make main owner') CNTOOLS_POOL_REG_OWNERS="$(jq -c --argjson index "${index}" '[.[$index]] + del(.[$index])' <<< "${CNTOOLS_POOL_REG_OWNERS}")" ;;
          'Supply public key')
            status=0; cntools_pool_registration_select_stake_into record 'Matching owner stake key' || status=$?
            ((status != 1 && status != 3)) || continue; ((status == 0)) || return "${status}"
            if [[ "$(jq -r .hash <<< "${record}")" != "${expected}" ]]; then
              cntools_ui_render_status warn 'This key is not the selected owner. Remove the old owner and add a new one to change ownership.'; continue
            fi
            cntools_pool_owner_add "${record}" || return 2 ;;
          Back) continue ;;
          *) return 2 ;;
        esac ;;
    esac
  done
}

cntools_pool_registration_edit_relays() {
  local choice='' kind='' dns='' ipv4='' ipv6='' port='' relay='' index=0 count=0 status=0
  local -a options=()
  while true; do
    cntools_pool_registration_begin
    cntools_pool_registration_relay_rows | cntools_table_render Relays
    options=(Done 'Add DNS relay' 'Add IP relay' 'Add SRV relay')
    count="$(jq length <<< "${CNTOOLS_POOL_REG_RELAYS}")"
    for ((index=0; index<count; index++)); do options+=("Remove relay $((index+1))"); done
    cntools_pool_registration_choose choice Relays "${options[@]}" Back || return $?
    case "${choice}" in
      Done|Back) return 0 ;;
      'Remove relay '*) index="${choice##* }"; CNTOOLS_POOL_REG_RELAYS="$(jq -c --argjson index "$((index-1))" 'del(.[$index])' <<< "${CNTOOLS_POOL_REG_RELAYS}")"; continue ;;
      'Add DNS relay'|'Add SRV relay')
        kind=dns; [[ "${choice}" != 'Add SRV relay' ]] || kind=srv
        status=0; cntools_pool_registration_input dns 'Relay DNS name' 'relay.example.com or SRV record' || status=$?
        ((status != 1)) || continue; ((status == 0)) || return "${status}" ;;
      'Add IP relay')
        kind=ip; status=0
        cntools_pool_registration_input ipv4 'IPv4 (optional)' 'Leave empty for IPv6 only' || status=$?
        ((status != 1)) || continue; ((status == 0)) || return "${status}"
        cntools_pool_registration_input ipv6 'IPv6 (optional)' 'Canonical IPv6; leave empty for IPv4 only' || status=$?
        ((status != 1)) || continue; ((status == 0)) || return "${status}" ;;
      *) return 2 ;;
    esac
    if [[ "${kind}" != srv ]]; then
      status=0; cntools_pool_registration_input port 'Relay port (default: 3001)' 3001 || status=$?
      ((status != 1)) || continue; ((status == 0)) || return "${status}"
      [[ -n "${port}" ]] || port=3001
      [[ "${port}" =~ ^[0-9]{1,5}$ ]] || { cntools_ui_render_status warn 'Use a port from 1 to 65,535.'; continue; }
      port=$((10#${port}))
    fi
    case "${kind}" in
      dns) relay="$(jq -cn --arg dns "${dns}" --argjson port "${port}" '{type:"dns",dns:$dns,port:$port}')" ;;
      srv) relay="$(jq -cn --arg dns "${dns}" '{type:"srv",dns:$dns}')" ;;
      ip) relay="$(jq -cn --arg ip4 "${ipv4}" --arg ip6 "${ipv6}" --argjson port "${port}" '{type:"ip",ipv4:$ip4,ipv6:$ip6,port:$port}')" ;;
    esac
    if ! cntools_pool_relay_valid "${relay}"; then cntools_ui_render_status warn 'Invalid relay: check DNS/IP and port.'; continue; fi
    CNTOOLS_POOL_REG_RELAYS="$(jq -c --argjson relay "${relay}" '. + [$relay]' <<< "${CNTOOLS_POOL_REG_RELAYS}")"
  done
}

cntools_pool_registration_edit_metadata() {
  cntools_pool_metadata_wizard
}

# The Pool settings menu. From the review ("review"), Esc returns to it like
# Done; before the first review Esc cancels. 'Cancel transaction' always cancels.
# Validation warnings need no Enter: the next redraw repeats them.
cntools_pool_registration_edit_settings() {
  local mode="${1:-}" choice='' input='' amount='' record='' status=0 current='' changes=''
  local -a options=()
  while true; do
    cntools_pool_registration_begin
    cntools_pool_registration_rows | cntools_table_render 'Pool settings' || return 2
    options=(Done Pledge 'Fixed cost' Margin 'Reward account' Owners Relays Metadata)
    ! cntools_pool_wizard_saved_present || options+=('Reuse saved settings')
    status=0
    cntools_pool_registration_choose choice 'Pool settings' "${options[@]}" 'Cancel transaction' || status=$?
    if ((status == 1)) && [[ "${mode}" == review ]]; then choice=Done
    elif ((status != 0)); then return "${status}"; fi
    status=0
    case "${choice}" in
      Done)
        if ! cntools_pool_parameters_json >/dev/null; then
          cntools_ui_render_status warn 'Complete the reward public key and every owner public key, and use a cost at or above the protocol minimum. Review relays and metadata.'; continue
        fi
        # A Modify that changes nothing (and cancels no retirement) only pays a fee.
        cntools_pool_registration_changes_into changes || return 2
        if [[ -n "${CNTOOLS_POOL_REG_BASELINE}" && -z "${changes}" && -z "$(jq -r '.retirement // ""' <<< "${CNTOOLS_POOL_REG_STATE}")" ]]; then
          cntools_transaction_log CHOICE 'Pool settings unchanged; Done refused'
          cntools_ui_render_status warn 'Nothing changed yet. Change a setting, or choose Cancel transaction.'; continue
        fi
        return 0 ;;
      Pledge|'Fixed cost')
        current="${CNTOOLS_POOL_REG_PLEDGE}"; [[ "${choice}" != 'Fixed cost' ]] || current="${CNTOOLS_POOL_REG_COST}"
        cntools_pool_registration_input input "${choice} ADA (Enter keeps $(cntools_number_format_lovelace "${current}"))" 'Commas are accepted' || status=$?
        ((status != 1)) || continue; ((status == 0)) || return "${status}"; [[ -n "${input}" ]] || continue
        if ! cntools_number_units_into amount "${input}" 6 || ! cntools_pool_parameter_uint "${amount}"; then cntools_ui_render_status warn 'Use a nonnegative ADA amount with at most six decimal places.'; continue; fi
        if [[ "${choice}" == Pledge ]]; then CNTOOLS_POOL_REG_PLEDGE="${amount}"
        elif cntools_uint_greater_equal "${amount}" "${CNTOOLS_POOL_REG_MIN_COST}"; then CNTOOLS_POOL_REG_COST="${amount}"
        else cntools_ui_render_status warn "Minimum fixed cost: $(cntools_number_format_lovelace "${CNTOOLS_POOL_REG_MIN_COST}")."; fi ;;
      Margin)
        current="$(cntools_pool_margin_percent "${CNTOOLS_POOL_REG_MARGIN}")" || return 2
        cntools_pool_registration_input input "Margin percent (Enter keeps ${current} %)" '0–100; up to six decimal places' || status=$?
        ((status != 1)) || continue; ((status == 0)) || return "${status}"; [[ -n "${input}" ]] || continue
        cntools_pool_margin_into amount "${input}" && CNTOOLS_POOL_REG_MARGIN="${amount}" || cntools_ui_render_status warn 'Use a percentage from 0 to 100.' ;;
      'Reward account')
        cntools_pool_registration_select_stake_into record 'Reward account stake key' || status=$?
        ((status != 1 && status != 3)) || continue; ((status == 0)) || return "${status}"
        cntools_pool_reward_record_use "${record}" ;;
      Owners) cntools_pool_registration_edit_owners || status=$? ;;
      Relays) cntools_pool_registration_edit_relays || status=$? ;;
      'Reuse saved settings') cntools_pool_wizard_saved_apply || status=$? ;;
      Metadata)
        cntools_pool_registration_edit_metadata || status=$?
        if ((status == 3)); then cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR:-Invalid pool metadata URL, hash or JSON file.}"; status=0; fi ;;
      'Cancel transaction') return 1 ;;
      *) return 2 ;;
    esac
    ((status != 1)) || continue; ((status == 0)) || return "${status}"
  done
}

# A hardware funding wallet needs the cold key on the same Ledger (checked when
# the funding wallet is prepared), so the combined session is the only option.
cntools_pool_registration_hardware_session() {
  local kind=''
  CNTOOLS_POOL_REG_COMBINE_HARDWARE=N
  [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == Hardware ]] || return 0
  cntools_transaction_source_kind_into kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" && [[ "${kind}" == hardware ]] || return 2
  CNTOOLS_POOL_REG_COMBINE_HARDWARE=Y
  cntools_transaction_log CHOICE "Pool hardware session operation=${CNTOOLS_WALLET_REGISTER_OPERATION} funding and cold key on the same Ledger (required); owners remain separate"
}

# Keep the chosen workflow unless the keys no longer allow signing. An
# unsigned package forced by missing keys was no choice, so once the keys can
# sign the workflow is derived again (Quick's default; Detailed asks).
cntools_pool_registration_workflow_keep_into() {
  local -n prk_workflow="$1"
  local prk_can_sign="$2" prk_status=0
  if [[ "${prk_can_sign}" == Y ]]; then
    [[ "${prk_workflow}" == 'Create unsigned package' && "${CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED:-N}" == Y ]] || return 0
    cntools_transaction_log CHOICE 'Pool keys can sign now; choosing the workflow again'
  else
    [[ "${prk_workflow}" != 'Create unsigned package' ]] || return 0
    cntools_transaction_log CHOICE "Pool workflow=${prk_workflow} no longer signable; choosing again"
  fi
  cntools_transaction_ui_initial_workflow_into "$1" "${prk_can_sign}" || prk_status=$?
  # Esc keeps the unsigned package, which stays valid; Change workflow remains.
  if ((prk_status == 1)); then CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED=N; return 0; fi
  return "${prk_status}"
}

# Funding picker context: a CLI or public-only cold key cannot share a Ledger
# session with a hardware funding wallet, so those wallets are not offered.
cntools_pool_registration_funding_context() {
  local kind=''
  if [[ -n "${CNTOOLS_POOL_REG_COLD_SOURCE}" ]] && cntools_transaction_source_kind_into kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" &&
     [[ "${kind}" == hardware ]]; then printf funding; else printf funding-software; fi
}

# A pre-signing recheck found changed chain state (return 4): collect it
# again so the next build and review use it.
cntools_pool_registration_refresh() {
  cntools_transaction_log POOL "Pool chain state changed before signing; rebuilding reason=${CNTOOLS_WALLET_REGISTER_ERROR}"
  cntools_ui_render_status warn "${CNTOOLS_WALLET_REGISTER_ERROR%% Rebuild*} CNTools rebuilt the transaction with the latest state; review it again."
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_ui_spin_function 'Checking pool registration, protocol parameters and funding…' cntools_pool_registration_collect || return 2
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]] && return 0
  cntools_pool_registration_baseline_set
  # Owner/reward registration may have changed too: check and plan again.
  CNTOOLS_POOL_WIZARD_STAKE_INPUTS=''
  cntools_pool_wizard_prepare_stake
}

cntools_pool_registration_workflow() {
  local selected='' wallet='' workflow='' can_sign=N choice='' proceed='' staged='' status=0 offered=N
  local -a review_options=()
  CNTOOLS_POOL_REG_SAVED=''; CNTOOLS_POOL_REG_RESULT_SHOWN=N
  CNTOOLS_POOL_WIZARD_STAKE_INPUTS=''; CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS=''
  CNTOOLS_POOL_STAKE_SETUP_CHOSEN=(); CNTOOLS_POOL_PLEDGE_TOTAL=''; CNTOOLS_POOL_PLEDGE_UNKNOWN=N
  cntools_pool_registration_begin
  cntools_transaction_require_cli && cntools_pool_catalog_build || return 2
  (( ${#CNTOOLS_POOL_NAMES[@]} > 0 )) || { cntools_wallet_register_set_error 'No pools are available. Use Pool → New or Import first.'; return 2; }
  cntools_pool_registration_choose_eligible_into selected || return $?
  cntools_pool_registration_prepare_identity "${selected}" || return 2
  cntools_wallet_catalog_build || return 2
  cntools_wallet_choose wallet Cancel "$(cntools_pool_registration_funding_context)" || return $?
  cntools_pool_registration_prepare_funding "${CNTOOLS_WALLET_PATHS[wallet]}" || return 2
  cntools_ui_spin_function 'Checking pool registration, protocol parameters and funding…' cntools_pool_registration_collect || return 2
  cntools_pool_registration_defaults || return 2
  if [[ "$(jq -r .registered <<< "${CNTOOLS_POOL_REG_STATE}")" != true ]]; then
    local record=''
    if cntools_pool_wallet_stake_record_into record "${wallet}"; then cntools_pool_owner_add "${record}"; cntools_pool_reward_record_use "${record}"; fi
  fi
  cntools_pool_wizard_saved_offer || return $?
  if [[ "${CNTOOLS_POOL_CHAIN_STATUS[CNTOOLS_POOL_REG_INDEX]}" == 'Not indexed' ]]; then
    cntools_ui_render_status warn 'Koios has no record of this pool; this may be indexer lag, not proof that it is unregistered.'
    cntools_pool_registration_choose choice 'Registering a new or fully retired pool?' Cancel 'Yes, continue with registration' || return $?
    [[ "${choice}" == 'Yes, continue with registration' ]] || return 1
  fi
  # The settings screen repeats this warning under its header and has a
  # Retirement row, so it needs no extra Enter.
  [[ "${CNTOOLS_POOL_CHAIN_STATUS[CNTOOLS_POOL_REG_INDEX]}" != Retiring ]] ||
    cntools_ui_render_status warn 'Re-registering this retiring pool cancels its pending retirement.'
  cntools_pool_registration_edit_settings || return $?
  cntools_pool_wizard_prepare_stake || return $?
  cntools_pool_registration_can_sign_into can_sign
  cntools_transaction_ui_initial_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_initial_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $?
  cntools_pool_registration_hardware_session || return $?
  while true; do
    while true; do
      cntools_ui_spin_function 'Building and validating the pool transaction…' cntools_pool_registration_build_into staged || return 2
      cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
      review_options=('Edit pool settings')
      [[ "${CNTOOLS_POOL_STAKE_SETUP_ASKABLE}" != Y ]] || review_options+=('Change stake setup')
      cntools_transaction_ui_review_into choice "${staged}" "${proceed}" cntools_pool_registration_begin \
        cntools_pool_registration_render_plan "${review_options[@]}" 'Change expiry' 'Change workflow' || return $?
      case "${choice}" in
        "${proceed}") break ;;
        'Edit pool settings')
          cntools_pool_registration_edit_settings review || return $?
          cntools_pool_wizard_prepare_stake || return $?
          cntools_pool_registration_can_sign_into can_sign
          cntools_pool_registration_workflow_keep_into workflow "${can_sign}" || return $? ;;
        'Change stake setup')
          cntools_pool_stake_setup_change || return $?
          cntools_pool_registration_can_sign_into can_sign
          cntools_pool_registration_workflow_keep_into workflow "${can_sign}" || return $? ;;
        'Change workflow') cntools_pool_review_change cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $? ;;
        'Change expiry') cntools_pool_review_change cntools_transaction_ui_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $? ;;
        *) return 2 ;;
      esac
    done
    # Offered once; a rebuild after changed chain state does not ask again.
    [[ "${offered}" == Y ]] || { cntools_pool_opcert_offer "${workflow}" || return $?; offered=Y; }
    status=0; cntools_pool_transaction_finish "${staged}" "${workflow}" || status=$?
    ((status == 4)) || return "${status}"
    cntools_pool_registration_refresh || return $?
  done
}

# Registration, modification and retirement share export/sign/submit/results.
cntools_pool_transaction_finish() {
  local staged="$1" workflow="$2" signed='' saved='' backend='' txid='' body='' status=0
  # Changed chain state before signing is rebuilt and reviewed again (4); a
  # query that cannot complete is an error.
  CNTOOLS_POOL_REG_RECHECK_CHANGED=N
  cntools_ui_spin_function 'Rechecking pool state and selected inputs…' cntools_pool_registration_recheck || {
    [[ "${CNTOOLS_POOL_REG_RECHECK_CHANGED}" == Y ]] && return 4; return 2;
  }
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 2
    CNTOOLS_POOL_REG_SAVED="${saved}"; cntools_pool_registration_begin
    cntools_transaction_ui_render_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    CNTOOLS_POOL_REG_RESULT_SHOWN=Y; return 0
  fi
  cntools_transaction_signed_path_into signed || return 2
  cntools_ui_spin_function 'Signing the reviewed pool transaction…' cntools_transaction_sign_registered "${staged}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" && [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || return 2
  cntools_transaction_save_into saved "${signed}" signed "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 2
  CNTOOLS_POOL_REG_SAVED="${saved}"
  if [[ "${workflow}" == 'Create and sign' ]]; then
    cntools_pool_registration_begin
    cntools_transaction_ui_render_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    CNTOOLS_POOL_REG_RESULT_SHOWN=Y; return 0
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  local confirm_mode=''
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != pool-retire ]] || confirm_mode=always
  status=0; cntools_transaction_ui_confirm_submit "${backend}" "${confirm_mode}" || status=$?
  if ((status == 1)); then
    cntools_pool_registration_begin; cntools_transaction_ui_render_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    CNTOOLS_POOL_REG_RESULT_SHOWN=Y; return 0
  fi
  ((status == 0)) || return 2
  if ! cntools_ui_spin_function 'Rechecking and submitting the pool transaction…' cntools_pool_registration_submit_checked "${backend}" "${body}" "${txid}"; then
    cntools_pool_registration_begin
    cntools_transaction_ui_render_result danger "${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Submission failed.}} Signed package retained." "${txid}" "${saved}"
    CNTOOLS_POOL_REG_RESULT_SHOWN=Y; return 2
  fi
  cntools_pool_registration_begin
  cntools_transaction_ui_render_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not block inclusion." "${txid}" || return 2
  CNTOOLS_POOL_REG_RESULT_SHOWN=Y
  cntools_transaction_ui_offer_monitor "${txid}"
}

cntools_pool_registration_submit_checked() {
  cntools_pool_registration_recheck || { cntools_transaction_set_error "${CNTOOLS_WALLET_REGISTER_ERROR:-Pool state could not be rechecked.}"; return 1; }
  cntools_transaction_ui_submit_selected "$@"
}

# Status of a pool transaction action: 1/130 are cancels, 3 means the reason
# was already shown and acknowledged. A cancel returns straight to the menu
# unless a package was saved first.
cntools_pool_action_outcome() {
  local status="$1" title="$2"
  case "${status}" in
    0) [[ "${CNTOOLS_POOL_REG_RESULT_SHOWN}" != Y || "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]] ||
         cntools_pool_wizard_followups || true ;;
    3) return 0 ;;
    1|130)
      if [[ "${CNTOOLS_POOL_REG_RESULT_SHOWN}" == Y ]]; then :
      elif [[ -n "${CNTOOLS_POOL_REG_SAVED}" ]]; then
        cntools_transaction_log CHOICE "${title} cancelled; saved package retained=${CNTOOLS_POOL_REG_SAVED}"
        cntools_ui_render_status info "Cancelled. The saved package was kept: ${CNTOOLS_POOL_REG_SAVED}"
      else return "${status}"; fi ;;
    *)
      [[ "${CNTOOLS_POOL_REG_RESULT_SHOWN}" == Y ]] ||
        cntools_transaction_ui_render_result danger "${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-${title} failed. See ${CNTOOLS_LOG}.}}" '' "${CNTOOLS_POOL_REG_SAVED}" ;;
  esac
  cntools_ui_wait
  # An error the action already showed is not reported again by the menu.
  ((status == 0 || status == 130)) && return "${status}"
  return 1
}

cntools_pool_action_registration() {
  local status=0
  cntools_transaction_clear_error
  CNTOOLS_WALLET_REGISTER_ERROR=''
  cntools_pool_registration_operation_set "$1" || return 2
  cntools_pool_registration_workflow || status=$?
  cntools_pool_action_outcome "${status}" 'Pool transaction'
}
