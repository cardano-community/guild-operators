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

# A hash from the chain settings the action started with, labelled as it was
# then ("Unknown owner · <hash>" without a local wallet or key).
cntools_pool_registration_initial_label() {
  local labels="${CNTOOLS_POOL_REG_INITIAL_LABELS:-}"
  [[ -n "${labels}" ]] || labels='{}'
  jq -rn --arg hash "$1" --arg noun "${2:-owner}" --argjson labels "${labels}" \
    '($labels[$hash] // "") as $known | if $known == "" or $known == $hash then "Unknown " + $noun + " · " + $hash else $known end'
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
    elif [[ -n "${retiring}" ]]; then cntools_table_pair Changes None muted
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
    [[ -z "${old_reward}" || "${old_reward}" == "${CNTOOLS_POOL_REG_REWARD_HASH}" ]] ||
      cntools_table_pair 'Reward account · before' "$(cntools_pool_registration_initial_label "${old_reward}" account)" muted
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
    while IFS= read -r hash; do cntools_table_pair 'Removed owner' "$(cntools_pool_registration_initial_label "${hash}")" warning; done < <(jq -r --argjson owners "${CNTOOLS_POOL_REG_OWNERS}" \
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
  # Only when stake setup adds a deposit to the pool deposit.
  if [[ "${CNTOOLS_POOL_STAKE_PLAN:-[]}" != '[]' && "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" != "${deposit}" ]]; then
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
    cntools_pool_policy_rows "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}"
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

# "owners" as $3 skips wallets that are already owners.
cntools_pool_registration_select_stake_into() {
  local output="$1" title="$2" skip="${3:-}" choice='' selected='' file='' stake_record='' pick_status=0
  cntools_pool_registration_choose choice "${title}" 'CNTools wallet' 'External stake public key (offline signer)' Cancel || return $?
  case "${choice}" in
    'CNTools wallet')
      CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
      [[ "${skip}" != owners ]] ||
        mapfile -t CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS < <(jq -r '.[].walletDirectory // empty' <<< "${CNTOOLS_POOL_REG_OWNERS}")
      cntools_wallet_choose selected Cancel pool-owner || pick_status=$?
      CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
      ((pick_status == 0)) || return "${pick_status}"
      # The editor redraws next and repeats this warning under its header.
      cntools_pool_wallet_stake_record_cached_into stake_record "${selected}" || {
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
  local -a options=() owner_options=()
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
        status=0; cntools_pool_registration_select_stake_into record 'Owner stake key' owners || status=$?
        ((status != 1 && status != 3)) || continue; ((status == 0)) || return "${status}"
        cntools_pool_owner_add "${record}" || return 2 ;;
      *)
        selected="${choice%% *}"; [[ "${selected}" =~ ^[0-9]+$ ]] || return 2
        index=$((selected-1)); expected="$(jq -r ".[${index}].hash" <<< "${CNTOOLS_POOL_REG_OWNERS}")"
        # Only actions that change something for this owner.
        owner_options=()
        [[ -n "$(jq -r ".[${index}].vkey" <<< "${CNTOOLS_POOL_REG_OWNERS}")" ]] || owner_options+=('Supply public key')
        ((index == 0)) || owner_options+=('Make main owner')
        owner_options+=('Remove owner')
        cntools_pool_registration_choose choice 'Owner key' "${owner_options[@]}" Back || return $?
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

# Each field is checked as it is entered; a relay already listed is refused
# and one other pools cannot reach (private, loopback, local name) is added
# with a warning. Esc at a field returns to the relay menu.
cntools_pool_registration_edit_relays() {
  local choice='' kind='' dns='' ipv4='' ipv6='' port='' relay='' index=0 count=0 status=0 note='' normalized='' existing=''
  local -a options=()
  while true; do
    cntools_pool_registration_begin
    cntools_pool_registration_relay_rows | cntools_table_render Relays
    options=(Done 'Add DNS relay' 'Add IP relay' 'Add SRV relay')
    count="$(jq length <<< "${CNTOOLS_POOL_REG_RELAYS}")"
    for ((index=0; index<count; index++)); do options+=("Remove relay $((index+1))"); done
    cntools_pool_registration_choose choice Relays "${options[@]}" Back || return $?
    dns='' ipv4='' ipv6='' port=''
    case "${choice}" in
      Done|Back) return 0 ;;
      'Remove relay '*) index="${choice##* }"; CNTOOLS_POOL_REG_RELAYS="$(jq -c --argjson index "$((index-1))" 'del(.[$index])' <<< "${CNTOOLS_POOL_REG_RELAYS}")"; continue ;;
      'Add DNS relay'|'Add SRV relay')
        kind=dns; [[ "${choice}" != 'Add SRV relay' ]] || kind=srv
        while true; do
          status=0; cntools_pool_registration_input dns 'Relay DNS name' "$([[ "${kind}" == srv ]] && printf '_cardano._tcp.example.com' || printf 'relay.example.com')" || status=$?
          ((status != 1)) || continue 2; ((status == 0)) || return "${status}"
          cntools_pool_relay_dns_valid "${dns}" "${kind}" && break
          cntools_ui_render_status warn "Use a DNS name of up to 64 characters: letters, digits and hyphens between dots$([[ "${kind}" != srv ]] || printf ', and underscores for SRV records')."
        done ;;
      'Add IP relay')
        kind=ip
        while true; do
          status=0; cntools_pool_registration_input ipv4 'IPv4 (optional)' 'Leave empty for IPv6 only' || status=$?
          ((status != 1)) || continue 2; ((status == 0)) || return "${status}"
          [[ -n "${ipv4}" ]] && ! cntools_pool_relay_ipv4_valid "${ipv4}" || break
          cntools_ui_render_status warn 'Use four numbers from 0 to 255 separated by dots, without leading zeros, for example 203.0.113.10.'
        done
        while true; do
          status=0; cntools_pool_registration_input ipv6 'IPv6 (optional)' "$([[ -n "${ipv4}" ]] && printf 'Leave empty for IPv4 only' || printf 'Required without an IPv4 address')" || status=$?
          ((status != 1)) || continue 2; ((status == 0)) || return "${status}"
          if [[ -z "${ipv6}" && -z "${ipv4}" ]]; then cntools_ui_render_status warn 'Enter an IPv4 or an IPv6 address.'; continue; fi
          normalized=''
          [[ -n "${ipv6}" ]] && ! cntools_pool_ipv6_into normalized "${ipv6}" || break
          cntools_ui_render_status warn 'Use a valid IPv6 address, for example 2001:db8::10.'
        done ;;
      *) return 2 ;;
    esac
    if [[ "${kind}" != srv ]]; then
      while true; do
        status=0; cntools_pool_registration_input port 'Relay port (default: 3001)' 3001 || status=$?
        ((status != 1)) || continue 2; ((status == 0)) || return "${status}"
        [[ -n "${port}" ]] || port=3001
        if [[ "${port}" =~ ^[0-9]{1,5}$ ]] && ((10#${port} >= 1 && 10#${port} <= 65535)); then port=$((10#${port})); break; fi
        cntools_ui_render_status warn 'Use a port from 1 to 65,535.'
      done
    fi
    case "${kind}" in
      dns) relay="$(jq -cn --arg dns "${dns}" --argjson port "${port}" '{type:"dns",dns:$dns,port:$port}')" ;;
      srv) relay="$(jq -cn --arg dns "${dns}" '{type:"srv",dns:$dns}')" ;;
      ip) relay="$(jq -cn --arg ip4 "${ipv4}" --arg ip6 "${ipv6}" --argjson port "${port}" '{type:"ip",ipv4:$ip4,ipv6:$ip6,port:$port}')" ;;
    esac
    if ! cntools_pool_relay_valid "${relay}"; then cntools_ui_render_status warn 'Invalid relay: check DNS/IP and port.'; continue; fi
    # Compare in canonical form: DNS names ignore case, IPv6 has one spelling.
    normalized="[${relay}]" existing="${CNTOOLS_POOL_REG_RELAYS}"
    cntools_pool_relays_normalize_into normalized "${normalized}" || normalized="[${relay}]"
    cntools_pool_relays_normalize_into existing "${existing}" || existing="${CNTOOLS_POOL_REG_RELAYS}"
    if jq -e --argjson relay "${normalized}" 'def key: if .type == "ip" then . else .dns |= ascii_downcase end;
        ($relay[0] | key) as $new | any(.[]; key == $new)' <<< "${existing}" >/dev/null 2>&1; then
      cntools_ui_render_status warn "$(jq -r ".[0] | ${CNTOOLS_POOL_RELAY_TEXT_JQ}" <<< "${normalized}") is already listed."
      continue
    fi
    CNTOOLS_POOL_REG_RELAYS="$(jq -c --argjson relay "${relay}" '. + [$relay]' <<< "${CNTOOLS_POOL_REG_RELAYS}")"
    cntools_pool_relay_private_into note "${relay}"
    # The relay list redraws next and repeats this warning.
    [[ -z "${note}" ]] || cntools_ui_render_status warn "Added, but ${note} that other pools cannot reach. Use the relay's public address or name."
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
# sign the workflow is derived again (Quick's default; Detailed asks). A
# forced unsigned package gets Quick's day to be signed elsewhere, as when it
# is chosen in the review.
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
  if ((prk_status == 1)); then CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED=N; prk_status=0
  elif ((prk_status != 0)); then return "${prk_status}"; fi
  cntools_transaction_ui_unsigned_lifetime_into CNTOOLS_WALLET_REGISTER_LIFETIME "${prk_workflow}" || true
}

# Funding picker context: a CLI or public-only cold key cannot share a Ledger
# session with a hardware funding wallet, so those wallets are not offered.
cntools_pool_registration_funding_context() {
  local kind=''
  if [[ -n "${CNTOOLS_POOL_REG_COLD_SOURCE}" ]] && cntools_transaction_source_kind_into kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" &&
     [[ "${kind}" == hardware ]]; then printf funding; else printf funding-software; fi
}

# A hardware funding wallet or cold key signs through cardano-hw-cli: report
# a missing one right after the choice, before any settings (X-HW).
cntools_pool_registration_hwcli_check() {
  local phc_kind=''
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == Hardware ]] ||
     { [[ -n "${CNTOOLS_POOL_REG_COLD_SOURCE}" ]] && cntools_transaction_source_kind_into phc_kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" &&
       [[ "${phc_kind}" == hardware ]]; }; then
    cntools_transaction_require_hwcli || return 2
  fi
}

# What the funding wallet must hold at least: the pool deposit (Register)
# plus about 1 ADA for the fee and the change output.
cntools_pool_registration_funds_needed_into() {
  local pfn_output="$1" pfn_needed=''
  cntools_uint_add_into pfn_needed "${CNTOOLS_WALLET_REGISTER_DEPOSIT:-0}" 1000000 || return 1
  printf -v "${pfn_output}" '%s' "${pfn_needed}"
}

# Chooses and checks the funding wallet right away, before any settings: a
# wallet that cannot pay the deposit and fee is named, and another one is
# offered while one is left. 3: none can fund it (shown and acknowledged).
cntools_pool_registration_choose_funding_into() {
  local pcf_output="$1" pcf_context='' pcf_wallet='' pcf_status=0 pcf_needed='' pcf_index=0 pcf_note='' pcf_other=N pcf_tried='' pcf_message=''
  local -a pcf_skipped=()
  pcf_context="$(cntools_pool_registration_funding_context)"
  while true; do
    pcf_status=0
    CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=("${pcf_skipped[@]}")
    cntools_wallet_choose pcf_wallet Cancel "${pcf_context}" || pcf_status=$?
    CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
    ((pcf_status == 0)) || return "${pcf_status}"
    cntools_pool_registration_prepare_funding "${CNTOOLS_WALLET_PATHS[pcf_wallet]}" || return 2
    cntools_ui_spin_function "$([[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]] && printf 'Checking pool state, retirement limits and funding…' ||
      printf 'Checking pool registration, protocol parameters and funding…')" cntools_pool_registration_collect || return 2
    cntools_pool_registration_funds_needed_into pcf_needed || return 2
    if cntools_uint_greater_equal "${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE:-0}" "${pcf_needed}"; then
      printf -v "${pcf_output}" '%s' "${pcf_wallet}"; return 0
    fi
    pcf_message="${CNTOOLS_WALLET_NAMES[pcf_wallet]} has $(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE:-0}") spendable; "
    if [[ "${CNTOOLS_WALLET_REGISTER_DEPOSIT:-0}" != 0 ]]; then
      pcf_message+="${CNTOOLS_WALLET_REGISTER_TITLE} needs the $(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}") pool deposit plus about 1 ADA for the fee and change."
    else
      pcf_message+="${CNTOOLS_WALLET_REGISTER_TITLE} needs about 1 ADA for the fee and change."
    fi
    cntools_transaction_log POOL "Funding wallet=${CNTOOLS_WALLET_NAMES[pcf_wallet]} short available=${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE:-0} needed=${pcf_needed}"
    pcf_skipped+=("${CNTOOLS_WALLET_PATHS[pcf_wallet]}")
    # Another wallet the picker would still offer?
    pcf_other=N
    for pcf_index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
      for pcf_tried in "${pcf_skipped[@]}"; do [[ "${pcf_tried}" != "${CNTOOLS_WALLET_PATHS[pcf_index]}" ]] || continue 2; done
      cntools_wallet_selection_candidate_into pcf_note "${pcf_index}" "${pcf_context}" || continue
      pcf_other=Y; break
    done
    if [[ "${pcf_other}" != Y ]]; then
      cntools_pool_registration_begin
      cntools_ui_render_status info "${pcf_message} No other wallet can fund it; add funds and try again."
      cntools_ui_wait; return 3
    fi
    # The picker redraws next and repeats this warning.
    cntools_ui_render_status warn "${pcf_message} Choose another wallet."
  done
}

# Values a review "Change …" can alter, saved before it so that a failed
# rebuild restores them, together with the stake checks behind them. Callers
# add their own locals (workflow, can_sign) by name.
CNTOOLS_POOL_REG_SNAPSHOT_NAMES=(CNTOOLS_POOL_REG_PLEDGE CNTOOLS_POOL_REG_COST CNTOOLS_POOL_REG_MARGIN
  CNTOOLS_POOL_REG_REWARD_VKEY CNTOOLS_POOL_REG_REWARD_HASH CNTOOLS_POOL_REG_REWARD_ADDRESS CNTOOLS_POOL_REG_REWARD_LABEL
  CNTOOLS_POOL_REG_REWARD_SOURCE CNTOOLS_POOL_REG_OWNERS CNTOOLS_POOL_REG_RELAYS CNTOOLS_POOL_REG_METADATA CNTOOLS_POOL_REG_METADATA_URL
  CNTOOLS_POOL_STAKE_PLAN CNTOOLS_POOL_EXTRA_RECORDS CNTOOLS_POOL_EXTRA_EXPECTED CNTOOLS_POOL_STAKE_SETUP_ASKABLE
  CNTOOLS_POOL_STAKE_SETUP_NOTE CNTOOLS_WALLET_REGISTER_DEPOSIT CNTOOLS_POOL_PLEDGE_TOTAL CNTOOLS_POOL_PLEDGE_UNKNOWN
  CNTOOLS_POOL_PLEDGE_APPROVED CNTOOLS_POOL_WIZARD_STAKE_INPUTS CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS CNTOOLS_POOL_CONFIG_SAVED
  CNTOOLS_WALLET_REGISTER_LIFETIME CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED CNTOOLS_TRANSACTION_UI_EXPIRY_CHOSEN
  CNTOOLS_TRANSACTION_UI_UNSIGNED_REASON CNTOOLS_POOL_RETIRE_EPOCH)
declare -ag CNTOOLS_POOL_REG_SNAPSHOT=()
declare -Ag CNTOOLS_POOL_REG_SNAPSHOT_STATUS=() CNTOOLS_POOL_REG_SNAPSHOT_DELEGATION=() CNTOOLS_POOL_REG_SNAPSHOT_BALANCE=() CNTOOLS_POOL_REG_SNAPSHOT_CHOSEN=()

cntools_pool_registration_assoc_copy() {
  declare -p "$1" >/dev/null 2>&1 && declare -p "$2" >/dev/null 2>&1 || return 0
  local -n prc_from="$1" prc_to="$2"
  local prc_key=''
  prc_to=()
  for prc_key in "${!prc_from[@]}"; do prc_to["${prc_key}"]="${prc_from[${prc_key}]}"; done
}

cntools_pool_registration_save() {
  local prs_name=''
  CNTOOLS_POOL_REG_SNAPSHOT=()
  for prs_name in "${CNTOOLS_POOL_REG_SNAPSHOT_NAMES[@]}" "$@"; do
    [[ -n "${!prs_name+x}" ]] || continue
    CNTOOLS_POOL_REG_SNAPSHOT+=("${prs_name}" "${!prs_name}")
  done
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_STAKE_STATUS CNTOOLS_POOL_REG_SNAPSHOT_STATUS
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_STAKE_DELEGATION CNTOOLS_POOL_REG_SNAPSHOT_DELEGATION
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_STAKE_BALANCE CNTOOLS_POOL_REG_SNAPSHOT_BALANCE
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_STAKE_SETUP_CHOSEN CNTOOLS_POOL_REG_SNAPSHOT_CHOSEN
}

cntools_pool_registration_restore() {
  local prr_index=0
  for ((prr_index = 0; prr_index + 1 < ${#CNTOOLS_POOL_REG_SNAPSHOT[@]}; prr_index += 2)); do
    printf -v "${CNTOOLS_POOL_REG_SNAPSHOT[prr_index]}" '%s' "${CNTOOLS_POOL_REG_SNAPSHOT[prr_index+1]}"
  done
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_REG_SNAPSHOT_STATUS CNTOOLS_POOL_STAKE_STATUS
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_REG_SNAPSHOT_DELEGATION CNTOOLS_POOL_STAKE_DELEGATION
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_REG_SNAPSHOT_BALANCE CNTOOLS_POOL_STAKE_BALANCE
  cntools_pool_registration_assoc_copy CNTOOLS_POOL_REG_SNAPSHOT_CHOSEN CNTOOLS_POOL_STAKE_SETUP_CHOSEN
}

# The settings a rebuild depends on, to tell whether an edit changed anything.
cntools_pool_registration_signature() {
  jq -cn --arg pledge "${CNTOOLS_POOL_REG_PLEDGE:-}" --arg cost "${CNTOOLS_POOL_REG_COST:-}" --arg margin "${CNTOOLS_POOL_REG_MARGIN:-}" \
    --arg reward "${CNTOOLS_POOL_REG_REWARD_HASH:-}" --arg reward_key "${CNTOOLS_POOL_REG_REWARD_VKEY:+Y}" \
    --arg reward_signer "${CNTOOLS_POOL_REG_REWARD_SOURCE:+Y}" --argjson owners "${CNTOOLS_POOL_REG_OWNERS:-[]}" \
    --argjson relays "${CNTOOLS_POOL_REG_RELAYS:-[]}" --argjson metadata "${CNTOOLS_POOL_REG_METADATA:-null}" '
    {pledge:$pledge,cost:$cost,margin:$margin,reward:$reward,rewardKey:$reward_key,rewardSigner:$reward_signer,
     owners:($owners|map({hash,key:((.vkey // "") != ""),signer:((.source // "") != "")})),relays:$relays,metadata:$metadata}'
}

# Builds the reviewed transaction. A retirement epoch the chain passed while
# the review was open takes the new earliest epoch (Quick) or is asked again
# (Detailed) before building once more. 2: the build failed.
cntools_pool_registration_build_ui_into() {
  local pbu_target="$1" pbu_title='Building and validating the pool transaction…'
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != pool-retire ]] || pbu_title='Building and validating the retirement transaction…'
  CNTOOLS_POOL_REG_RECHECK_CHANGED=N
  cntools_ui_spin_function "${pbu_title}" cntools_pool_registration_build_into "${pbu_target}" && return 0
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire && "${CNTOOLS_POOL_REG_RECHECK_CHANGED}" == Y ]] &&
    ! cntools_pool_retirement_epoch_allowed || return 2
  cntools_transaction_log POOL "Retirement epoch=${CNTOOLS_POOL_RETIRE_EPOCH} left the allowed window; choosing again"
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_pool_retirement_epoch_refresh || return $?
  cntools_ui_spin_function "${pbu_title}" cntools_pool_registration_build_into "${pbu_target}" || return 2
}

# Rebuild after a review "Change …" (values saved before it). A failed
# rebuild restores the saved values, rebuilds those and warns; the review
# continues. Esc or Ctrl+C at a renewed epoch question cancels.
cntools_pool_registration_rebuild_into() {
  local prb_target="$1" prb_what="$2" prb_reason='' prb_status=0
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_pool_registration_build_ui_into "${prb_target}" || prb_status=$?
  ((prb_status != 0)) || return 0
  ((prb_status != 1 && prb_status != 130)) || return "${prb_status}"
  prb_reason="${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-The transaction could not be built.}}"
  cntools_pool_registration_restore
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_ui_spin_function 'Restoring the reviewed transaction…' cntools_pool_registration_build_into "${prb_target}" || return 2
  # Keep the local draft equal to the settings under review.
  if [[ "${prb_what}" == 'pool settings' ]] && declare -F cntools_pool_config_save >/dev/null 2>&1; then
    cntools_pool_config_save || cntools_transaction_log WARN "Pool draft not restored pool=${CNTOOLS_POOL_REG_NAME}"
  fi
  cntools_transaction_log CHOICE "${CNTOOLS_WALLET_REGISTER_TITLE} rebuild failed; previous ${prb_what} kept reason=${prb_reason}"
  cntools_ui_render_status warn "The changed ${prb_what} could not be built, so the reviewed transaction is kept. ${prb_reason}"
}

# Review "Change workflow" and "Change expiry", shared by Register, Modify and
# Retire. 0: changed and rebuild needed (what in the second variable); 1:
# kept (Esc, or nothing to rebuild); others end the action.
cntools_pool_registration_change_common() {
  local pcc_choice="$1" pcc_workflow_name="$2" pcc_can_sign="$3" pcc_status=0
  case "${pcc_choice}" in
    'Change workflow')
      cntools_pool_registration_save "${pcc_workflow_name}"
      cntools_transaction_ui_workflow_into "${pcc_workflow_name}" "${pcc_can_sign}" || pcc_status=$?
      ((pcc_status == 0)) || return "${pcc_status}"
      # Quick gives an unsigned package a day to be signed; only that rebuilds.
      cntools_transaction_ui_unsigned_lifetime_into CNTOOLS_WALLET_REGISTER_LIFETIME "${!pcc_workflow_name}" || return 1 ;;
    'Change expiry')
      cntools_pool_registration_save
      cntools_transaction_ui_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $? ;;
    *) return 2 ;;
  esac
}

# A pre-signing recheck found changed chain state (return 4): collect it
# again so the next build and review use it.
cntools_pool_registration_refresh() {
  cntools_transaction_log POOL "Pool chain state changed before signing; rebuilding reason=${CNTOOLS_WALLET_REGISTER_ERROR}"
  cntools_ui_render_status warn "${CNTOOLS_WALLET_REGISTER_ERROR%% Rebuild*} CNTools rebuilt the transaction with the latest state; review it again."
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_ui_spin_function 'Checking pool registration, protocol parameters and funding…' cntools_pool_registration_collect || return 2
  # A retirement epoch the new epoch left behind is set again before the review.
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]]; then cntools_pool_retirement_epoch_refresh; return $?; fi
  cntools_pool_registration_baseline_set
  # Owner/reward registration may have changed too: check again, keeping the
  # earlier answers while their registration and delegation are unchanged.
  cntools_pool_wizard_prepare_stake refresh
}

cntools_pool_registration_workflow() {
  local selected='' wallet='' workflow='' can_sign=N choice='' proceed='' staged='' status=0 offered=N rebuild=N what='' before=''
  local -a review_options=()
  CNTOOLS_POOL_REG_SAVED=''; CNTOOLS_POOL_REG_RESULT_SHOWN=N
  CNTOOLS_POOL_WIZARD_STAKE_INPUTS=''; CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS=''
  CNTOOLS_POOL_STAKE_SETUP_CHOSEN=(); CNTOOLS_POOL_PLEDGE_TOTAL=''; CNTOOLS_POOL_PLEDGE_UNKNOWN=N; CNTOOLS_POOL_PLEDGE_APPROVED=''
  CNTOOLS_POOL_OPCERT_OFFLINE=N; CNTOOLS_POOL_OPCERT_NOTE=''; CNTOOLS_POOL_WALLET_STAKE_CACHE=()
  cntools_pool_registration_begin
  cntools_transaction_require_cli && cntools_pool_catalog_build || return 2
  (( ${#CNTOOLS_POOL_NAMES[@]} > 0 )) || { cntools_pool_empty_notice; return 3; }
  cntools_pool_registration_choose_eligible_into selected || return $?
  # Asked before funding and settings: the answer decides whether to go on.
  if [[ "${CNTOOLS_POOL_CHAIN_STATUS[selected]}" == 'Not indexed' ]]; then
    cntools_ui_render_status warn 'Koios has no record of this pool; this may be indexer lag, not proof that it is unregistered.'
    cntools_pool_registration_choose choice 'Registering a new or fully retired pool?' Cancel 'Yes, continue with registration' || return $?
    [[ "${choice}" == 'Yes, continue with registration' ]] || return 1
  fi
  cntools_pool_registration_prepare_identity "${selected}" || return 2
  cntools_wallet_catalog_build || return 2
  cntools_pool_registration_choose_funding_into wallet || return $?
  cntools_pool_registration_hwcli_check || return 2
  if [[ "$(jq -r .registered <<< "${CNTOOLS_POOL_REG_STATE}")" == true ]]; then
    cntools_ui_spin_function 'Matching owners and the reward account to local wallets…' cntools_pool_registration_defaults || return 2
  else
    cntools_pool_registration_defaults || return 2
    local record=''
    if cntools_pool_wallet_stake_record_cached_into record "${wallet}"; then cntools_pool_owner_add "${record}"; cntools_pool_reward_record_use "${record}"; fi
  fi
  # A retiring pool's settings show the cancellation in their Retirement row.
  cntools_pool_registration_edit_settings || return $?
  cntools_pool_wizard_prepare_stake || return $?
  cntools_pool_registration_can_sign_into can_sign
  cntools_transaction_ui_initial_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_initial_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $?
  cntools_pool_registration_hardware_session || return $?
  cntools_pool_registration_build_ui_into staged || return $?
  while true; do
    while true; do
      # Rebuilt only after a change; Esc in a "Change …" keeps the build.
      if [[ "${rebuild}" == Y ]]; then cntools_pool_registration_rebuild_into staged "${what}" || return $?; rebuild=N; fi
      cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
      review_options=('Edit pool settings')
      [[ "${CNTOOLS_POOL_STAKE_SETUP_ASKABLE}" != Y ]] || review_options+=('Change stake setup')
      cntools_transaction_ui_review_into choice "${staged}" "${proceed}" cntools_pool_registration_begin \
        cntools_pool_registration_render_plan "${review_options[@]}" 'Change expiry' 'Change workflow' || return $?
      case "${choice}" in
        "${proceed}") break ;;
        'Edit pool settings')
          cntools_pool_registration_save workflow can_sign
          before="$(cntools_pool_registration_signature)"
          # Esc on a stake setup or pledge question returns to the settings.
          while true; do
            cntools_pool_registration_edit_settings review || return $?
            status=0
            # Settings back where they were: the reviewed transaction stands.
            if [[ "$(cntools_pool_registration_signature)" == "${before}" ]]; then status=1; break; fi
            cntools_pool_wizard_prepare_stake review || status=$?
            ((status == 1)) || break
            cntools_transaction_log CHOICE 'Pool stake/pledge question cancelled; back to pool settings'
          done
          if ((status == 1)); then
            cntools_pool_registration_restore
            cntools_transaction_log CHOICE 'Pool settings unchanged; reviewed transaction kept'
            continue
          fi
          ((status == 0)) || return "${status}"
          cntools_pool_registration_can_sign_into can_sign
          cntools_pool_registration_workflow_keep_into workflow "${can_sign}" || return $?
          rebuild=Y what='pool settings' ;;
        'Change stake setup')
          cntools_pool_registration_save workflow can_sign
          before="${CNTOOLS_POOL_STAKE_PLAN}"
          cntools_pool_stake_setup_change || return $?
          [[ "${CNTOOLS_POOL_STAKE_PLAN}" != "${before}" ]] || continue
          cntools_pool_registration_can_sign_into can_sign
          cntools_pool_registration_workflow_keep_into workflow "${can_sign}" || return $?
          rebuild=Y what='stake setup' ;;
        'Change workflow'|'Change expiry')
          status=0; cntools_pool_registration_change_common "${choice}" workflow "${can_sign}" || status=$?
          ((status <= 1)) || return "${status}"
          ((status == 0)) || continue
          rebuild=Y what=expiry ;;
        *) return 2 ;;
      esac
    done
    # Offered once; a rebuild after changed chain state does not ask again.
    # Esc at its questions goes back to the review.
    if [[ "${offered}" != Y ]]; then
      status=0; cntools_pool_opcert_offer "${workflow}" || status=$?
      if ((status == 1)); then cntools_transaction_log CHOICE 'First operational certificate question left; back to the review'; continue; fi
      ((status == 0)) || return "${status}"
      offered=Y
    fi
    status=0; cntools_pool_transaction_finish "${staged}" "${workflow}" || status=$?
    ((status == 4)) || return "${status}"
    cntools_pool_registration_refresh || return $?
    cntools_pool_registration_build_ui_into staged || return $?
  done
}

# Registration, modification and retirement share export/sign/submit/results.
# 4: chain state changed before signing; rebuild and review again.
cntools_pool_transaction_finish() {
  local staged="$1" workflow="$2" signed='' saved='' backend='' txid='' body='' status=0 recheck=Y title=''
  # Changed chain state before signing is rebuilt and reviewed again (4); a
  # query that cannot complete is an error.
  CNTOOLS_POOL_REG_RECHECK_CHANGED=N
  cntools_ui_spin_function 'Rechecking pool state and selected inputs…' cntools_pool_registration_recheck || {
    [[ "${CNTOOLS_POOL_REG_RECHECK_CHANGED}" == Y ]] && return 4; return 2;
  }
  cntools_transaction_ui_recheck_mark
  if [[ "${workflow}" != 'Create unsigned package' ]]; then
    cntools_transaction_signed_path_into signed || return 2
    # A device or key failure offers Retry, Save unsigned package or Cancel.
    status=0; cntools_transaction_ui_sign_staged 'the reviewed pool transaction' "${staged}" "${signed}" || status=$?
    case "${status}" in
      0) ;;
      4) workflow='Create unsigned package' ;;
      *) return "${status}" ;;
    esac
  fi
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 2
    CNTOOLS_POOL_REG_SAVED="${saved}"; cntools_pool_registration_begin
    cntools_transaction_ui_render_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    CNTOOLS_POOL_REG_RESULT_SHOWN=Y; return 0
  fi
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
  # Only a retirement asks again; the review choice confirms the others.
  status=0
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-retire ]]; then
    cntools_transaction_ui_confirm_submit "${backend}" always 'pool retirement' || status=$?
  else cntools_transaction_ui_confirm_submit "${backend}" || status=$?; fi
  if ((status == 1 || status == 130)); then
    cntools_pool_registration_begin; cntools_transaction_ui_render_result warning 'Not submitted · signed package remains available' "${txid}" "${saved}"
    CNTOOLS_POOL_REG_RESULT_SHOWN=Y; return 0
  fi
  ((status == 0)) || return 2
  # Rechecked again only when time passed since the pre-signing recheck
  # (a device or a slow answer); local keys sign at once.
  cntools_transaction_ui_recheck_due || recheck=N
  title='Rechecking and submitting the pool transaction…'
  [[ "${recheck}" == Y ]] || title='Submitting the pool transaction…'
  if ! cntools_ui_spin_function "${title}" cntools_pool_registration_submit_checked "${recheck}" "${backend}" "${body}" "${txid}"; then
    cntools_pool_registration_begin
    cntools_transaction_ui_render_result danger "${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Submission failed.}} The signed package remains available." "${txid}" "${saved}"
    CNTOOLS_POOL_REG_RESULT_SHOWN=Y; return 2
  fi
  cntools_pool_registration_begin
  cntools_transaction_ui_render_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not block inclusion." "${txid}" || return 2
  CNTOOLS_POOL_REG_RESULT_SHOWN=Y
  cntools_transaction_ui_offer_monitor "${txid}"
}

# Y as $1 rechecks the pool state and inputs first.
cntools_pool_registration_submit_checked() {
  if [[ "$1" == Y ]]; then
    cntools_pool_registration_recheck || { cntools_transaction_set_error "${CNTOOLS_WALLET_REGISTER_ERROR:-Pool state could not be rechecked.}"; return 1; }
    cntools_transaction_ui_recheck_mark
  fi
  shift
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
        cntools_ui_render_status info "Cancelled. The saved package remains available: ${CNTOOLS_POOL_REG_SAVED}"
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
