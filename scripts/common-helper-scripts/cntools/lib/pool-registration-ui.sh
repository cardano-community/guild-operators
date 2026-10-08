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

cntools_pool_registration_rows() {
  local record='' index=0 margin='' owner_count=''
  margin="$(cntools_pool_margin_number "${CNTOOLS_POOL_REG_MARGIN}" | jq -r '. * 100')" || return 1
  owner_count="$(jq length <<< "${CNTOOLS_POOL_REG_OWNERS}")"
  cntools_table_pair Pool "${CNTOOLS_POOL_REG_NAME}" identifier
  cntools_table_pair 'Pool ID' "${CNTOOLS_POOL_REG_ID}" identifier
  cntools_table_pair 'Funding wallet' "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
  [[ -z "${CNTOOLS_FUNDING_TOTAL:-}" ]] || cntools_table_pair 'Spendable ADA' "$(cntools_wallet_format_lovelace "${CNTOOLS_FUNDING_TOTAL}")" number
  cntools_table_pair Pledge "$(cntools_wallet_format_lovelace "${CNTOOLS_POOL_REG_PLEDGE}")" number
  cntools_table_pair 'Fixed cost' "$(cntools_wallet_format_lovelace "${CNTOOLS_POOL_REG_COST}")" number
  cntools_table_pair Margin "${margin} %" number
  cntools_table_pair 'Reward account' "${CNTOOLS_POOL_REG_REWARD_ADDRESS:-${CNTOOLS_POOL_REG_REWARD_HASH:-Not selected}}" identifier
  while IFS= read -r record; do
    index=$((index+1))
    cntools_table_pair "Owner ${index}$([[ "${index}" != 1 ]] || printf ' · main')" "$(jq -r '.label + " · " + (if .address == "" then .hash else .address end)' <<< "${record}")" identifier
    [[ "$(jq -r .vkey <<< "${record}")" != '' ]] || cntools_table_pair 'Public key' 'Required · select this owner to supply its public key or remove it' warning
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}")
  (( owner_count != 0 )) || cntools_table_pair Owners 'None selected' warning
  index=0
  while IFS= read -r record; do
    index=$((index+1))
    cntools_table_pair "Relay ${index}" "$(jq -r 'if .type == "ip" then [.ipv4,.ipv6]|map(select(length>0))|join(" / ") else .dns end' <<< "${record}")$(jq -r 'if .port != null then ":"+(.port|tostring) else " · SRV" end' <<< "${record}")" identifier
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_RELAYS}")
  (( index != 0 )) || cntools_table_pair Relays 'None · private pool' muted
  if [[ "${CNTOOLS_POOL_REG_METADATA}" == null ]]; then cntools_table_pair Metadata None muted
  else cntools_table_pair 'Metadata URL' "$(jq -r .url <<< "${CNTOOLS_POOL_REG_METADATA}")" identifier
    cntools_table_pair 'Metadata hash' "$(jq -r .hash <<< "${CNTOOLS_POOL_REG_METADATA}")" identifier
  fi
  cntools_table_pair 'Pool deposit' "$(cntools_wallet_format_lovelace "${CNTOOLS_POOL_REG_POOL_DEPOSIT:-${CNTOOLS_WALLET_REGISTER_DEPOSIT}}")" number
  if [[ "${CNTOOLS_POOL_STAKE_PLAN:-[]}" != '[]' ]]; then
    while IFS= read -r record; do
      cntools_table_pair 'Included stake setup' "$(jq -r '.label + " · " + .setup' <<< "${record}")" success
    done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_STAKE_PLAN}")
    cntools_table_pair 'Total deposits' "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")" number
  fi
}

cntools_pool_registration_render_plan() {
  local fee='' expiry=''
  cntools_pool_registration_rows | cntools_table_render 'Pool settings' || return 1
  cntools_transaction_ui_fee_into fee || return 1
  cntools_transaction_ui_expiry_label_into expiry "${CNTOOLS_WALLET_REGISTER_EXPIRY}"
  { cntools_table_pair Fee "$(cntools_wallet_format_lovelace "${fee}")" number
    cntools_table_pair Expires "${expiry}" number
    cntools_table_pair 'Input selection' "${CNTOOLS_TX_SELECTION_STRATEGY} · $(cntools_number_format "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}") inputs"
    cntools_table_pair 'Token fragmentation' "${CNTOOLS_CHANGE_TOKEN_STATUS}"
    cntools_table_pair 'ADA-only management' "${CNTOOLS_CHANGE_UTXO_STATUS}"
    cntools_table_pair 'Collateral candidate' "${CNTOOLS_CHANGE_COLLATERAL_STATUS}"
  } | cntools_table_render 'Transaction information'
  cntools_ui_render_status info 'Pledge is a commitment, not a transfer. Only explicitly selected stake setup is included. Operational setup is handled separately; this transaction does not start a node.'
}

cntools_pool_registration_select_stake_into() {
  local output="$1" title="$2" choice='' selected='' file='' stake_record=''
  cntools_pool_registration_choose choice "${title}" 'CNTools wallet' 'External stake public key (offline signer)' Cancel || return $?
  case "${choice}" in
    'CNTools wallet')
      cntools_wallet_choose selected || return $?
      cntools_pool_wallet_stake_record_into stake_record "${selected}" || {
        cntools_ui_render_status warn 'Select a wallet with a valid stake public key; script owners are not supported.'; cntools_ui_wait; return 3;
      } ;;
    'External stake public key (offline signer)')
      cntools_pool_registration_input file 'Stake verification key file' 'Absolute path to public .vkey; no private key is needed' || return $?
      cntools_transaction_input_path_into file "${file}" && cntools_pool_stake_record_into stake_record "${file}" '' "${file##*/}" || {
        cntools_ui_render_status warn 'The stake public key could not be read or validated.'; cntools_ui_wait; return 3;
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
    { while IFS= read -r display_record; do
        cntools_table_pair "$(jq -r .label <<< "${display_record}")" "$(jq -r .hash <<< "${display_record}")" identifier
      done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}");
    } | cntools_table_render Owners
    options=(Done 'Add owner'); count="$(jq length <<< "${CNTOOLS_POOL_REG_OWNERS}")"
    for ((index=0; index<count; index++)); do options+=("$((index+1)) · $(jq -r ".[${index}].label" <<< "${CNTOOLS_POOL_REG_OWNERS}")"); done
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
              cntools_ui_render_status warn 'This key is not the selected owner. Remove the old owner and add a new one to change ownership.'; cntools_ui_wait; continue
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
      [[ "${port}" =~ ^[0-9]{1,5}$ ]] || { cntools_ui_render_status warn 'Use a port from 1 to 65,535.'; cntools_ui_wait; continue; }
      port=$((10#${port}))
    fi
    case "${kind}" in
      dns) relay="$(jq -cn --arg dns "${dns}" --argjson port "${port}" '{type:"dns",dns:$dns,port:$port}')" ;;
      srv) relay="$(jq -cn --arg dns "${dns}" '{type:"srv",dns:$dns}')" ;;
      ip) relay="$(jq -cn --arg ip4 "${ipv4}" --arg ip6 "${ipv6}" --argjson port "${port}" '{type:"ip",ipv4:$ip4,ipv6:$ip6,port:$port}')" ;;
    esac
    if ! cntools_pool_relay_valid "${relay}"; then cntools_ui_render_status warn 'Invalid relay: check DNS/IP and port.'; cntools_ui_wait; continue; fi
    CNTOOLS_POOL_REG_RELAYS="$(jq -c --argjson relay "${relay}" '. + [$relay]' <<< "${CNTOOLS_POOL_REG_RELAYS}")"
  done
}

cntools_pool_registration_edit_metadata() {
  cntools_pool_metadata_wizard
}

cntools_pool_registration_edit_settings() {
  local choice='' input='' amount='' record='' status=0 current=''
  while true; do
    cntools_pool_registration_begin
    cntools_pool_registration_rows | cntools_table_render 'Pool settings' || return 2
    cntools_pool_registration_choose choice 'Pool settings' Done Pledge 'Fixed cost' Margin 'Reward account' Owners Relays Metadata 'Reuse saved settings' 'Cancel transaction' || return $?
    status=0
    case "${choice}" in
      Done)
        if cntools_pool_parameters_json >/dev/null; then return 0; fi
        cntools_ui_render_status warn 'Complete the reward public key and every owner public key, and use a cost at or above the protocol minimum. Review relays and metadata.'; cntools_ui_wait ;;
      Pledge|'Fixed cost')
        current="${CNTOOLS_POOL_REG_PLEDGE}"; [[ "${choice}" != 'Fixed cost' ]] || current="${CNTOOLS_POOL_REG_COST}"
        cntools_pool_registration_input input "${choice} ADA (Enter keeps $(cntools_wallet_format_lovelace "${current}"))" 'Commas are accepted' || status=$?
        ((status != 1)) || continue; ((status == 0)) || return "${status}"; [[ -n "${input}" ]] || continue
        if ! cntools_number_units_into amount "${input}" 6 || ! cntools_pool_parameter_uint "${amount}"; then cntools_ui_render_status warn 'Use a nonnegative ADA amount with at most six decimal places.'; cntools_ui_wait; continue; fi
        if [[ "${choice}" == Pledge ]]; then CNTOOLS_POOL_REG_PLEDGE="${amount}"
        elif cntools_uint_greater_equal "${amount}" "${CNTOOLS_POOL_REG_MIN_COST}"; then CNTOOLS_POOL_REG_COST="${amount}"
        else cntools_ui_render_status warn "Minimum fixed cost: $(cntools_wallet_format_lovelace "${CNTOOLS_POOL_REG_MIN_COST}")."; cntools_ui_wait; fi ;;
      Margin)
        cntools_pool_registration_input input 'Margin percent (Enter keeps current)' '0–100; up to six decimal places' || status=$?
        ((status != 1)) || continue; ((status == 0)) || return "${status}"; [[ -n "${input}" ]] || continue
        cntools_pool_margin_into amount "${input}" && CNTOOLS_POOL_REG_MARGIN="${amount}" || { cntools_ui_render_status warn 'Use a percentage from 0 to 100.'; cntools_ui_wait; } ;;
      'Reward account')
        cntools_pool_registration_select_stake_into record 'Reward account stake key' || status=$?
        ((status != 1 && status != 3)) || continue; ((status == 0)) || return "${status}"
        cntools_pool_reward_record_use "${record}" ;;
      Owners) cntools_pool_registration_edit_owners || status=$? ;;
      Relays) cntools_pool_registration_edit_relays || status=$? ;;
      'Reuse saved settings') cntools_pool_wizard_saved_offer || status=$? ;;
      Metadata)
        cntools_pool_registration_edit_metadata || status=$?
        if ((status == 3)); then cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR:-Invalid pool metadata URL, hash or JSON file.}"; cntools_ui_wait; status=0; fi ;;
      'Cancel transaction') return 1 ;;
      *) return 2 ;;
    esac
    ((status != 1)) || continue; ((status == 0)) || return "${status}"
  done
}

cntools_pool_registration_hardware_choice() {
  local kind='' choice=''
  CNTOOLS_POOL_REG_COMBINE_HARDWARE=N
  [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == Hardware ]] || return 0
  cntools_transaction_source_kind_into kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" && [[ "${kind}" == hardware ]] || return 2
  cntools_ui_render_status info 'Pool operator signing needs the funding payment key and cold key on the same Ledger. Every hardware owner signs separately, including owners on that Ledger.'
  cntools_pool_registration_choose choice 'Funding and cold keys on the same Ledger?' 'Yes, same Ledger device' 'No, use another funding wallet' Cancel || return $?
  case "${choice}" in
    'Yes, same Ledger device') CNTOOLS_POOL_REG_COMBINE_HARDWARE=Y ;;
    'No, use another funding wallet') cntools_wallet_register_set_error 'Restart this action with a CLI/mnemonic funding wallet, or a funding wallet on the pool cold key Ledger.'; return 2 ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
  cntools_transaction_log CHOICE "Pool operator hardware session selected=${choice}; owners remain separate"
}

cntools_pool_registration_workflow() {
  local selected='' wallet='' workflow='' can_sign=N choice='' proceed='' staged='' signed='' saved='' backend='' txid='' body='' status=0
  CNTOOLS_POOL_REG_SAVED=''; CNTOOLS_POOL_REG_RESULT_SHOWN=N
  cntools_pool_registration_begin
  cntools_transaction_require_cli && cntools_pool_catalog_build || return 2
  (( ${#CNTOOLS_POOL_NAMES[@]} > 0 )) || { cntools_wallet_register_set_error 'No pools are available. Use Pool → New or Import first.'; return 2; }
  cntools_pool_registration_choose_eligible_into selected || return $?
  cntools_pool_registration_prepare_identity "${selected}" || return 2
  cntools_wallet_catalog_build || return 2
  (( ${#CNTOOLS_WALLET_NAMES[@]} > 0 )) || { cntools_wallet_register_set_error 'No funding wallets are available.'; return 2; }
  cntools_wallet_choose wallet || return $?
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
  [[ "${CNTOOLS_POOL_CHAIN_STATUS[CNTOOLS_POOL_REG_INDEX]}" != Retiring ]] || cntools_ui_render_status warn 'Re-registering this retiring pool cancels its pending retirement.'
  cntools_ui_wait
  cntools_pool_registration_edit_settings || return $?
  cntools_pool_wizard_prepare_stake || return $?
  cntools_pool_registration_can_sign_into can_sign
  cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $?
  CNTOOLS_POOL_REG_COMBINE_HARDWARE=N
  cntools_pool_registration_hardware_choice || return $?
  while true; do
    cntools_ui_spin_function 'Building and validating the pool transaction…' cntools_pool_registration_build_into staged || return 2
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into choice "${staged}" "${proceed}" cntools_pool_registration_begin \
      cntools_pool_registration_render_plan 'Edit pool settings' 'Change workflow' || return $?
    case "${choice}" in
      "${proceed}") break ;;
      'Edit pool settings')
        cntools_pool_registration_edit_settings || return $?
        cntools_pool_wizard_prepare_stake || return $?
        cntools_pool_registration_can_sign_into can_sign
        cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?
        cntools_pool_registration_hardware_choice || return $? ;;
      'Change workflow') cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $? ;;
      *) return 2 ;;
    esac
  done
  cntools_pool_opcert_offer "${workflow}" || return $?
  cntools_ui_spin_function 'Rechecking pool state and selected inputs…' cntools_pool_registration_recheck || return 2
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
  status=0; cntools_transaction_ui_confirm_submit "${backend}" || status=$?
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

cntools_pool_action_registration() {
  local status=0
  cntools_transaction_clear_error
  CNTOOLS_WALLET_REGISTER_ERROR=''
  cntools_pool_registration_operation_set "$1" || return 2
  cntools_pool_registration_workflow || status=$?
  if ((status == 0)) && [[ "${CNTOOLS_POOL_REG_RESULT_SHOWN}" == Y ]]; then cntools_pool_wizard_followups || true; fi
  if ((status == 1)); then cntools_transaction_ui_cancel 'Pool transaction cancelled; saved packages retained'
  elif ((status != 0)) && [[ "${CNTOOLS_POOL_REG_RESULT_SHOWN}" != Y ]]; then
    cntools_transaction_ui_render_result danger "${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Pool transaction failed. See ${CNTOOLS_LOG}.}}" '' "${CNTOOLS_POOL_REG_SAVED}"
  fi
  cntools_ui_wait
  ((status <= 1))
}
