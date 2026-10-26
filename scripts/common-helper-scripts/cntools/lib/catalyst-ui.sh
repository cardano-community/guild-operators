#!/usr/bin/env bash
# Catalyst registration, QR and official snapshot status using shared tables.
# shellcheck disable=SC2034,SC2015

# What a cancelled registration leaves behind (a new key, saved metadata).
CNTOOLS_CATALYST_SAVED_NOTE=''

cntools_catalyst_begin() { cntools_ui_action_begin Catalyst '/ Vote / Catalyst / Registration'; }

# Menu status for Catalyst actions: cancel returns quietly unless something was
# saved; "nothing to choose" (3) was already explained.
cntools_catalyst_action_finish() {
  local status="$1" failure="$2"
  if ((status == 1 || status == 130)); then
    [[ -n "${CNTOOLS_CATALYST_SAVED_NOTE}" ]] || return "${status}"
    cntools_ui_render_status info "${CNTOOLS_CATALYST_SAVED_NOTE}"
  elif ((status == 3)); then
    return 0
  elif ((status != 0)); then
    cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR:-${failure}} See ${CNTOOLS_LOG} for details."
  fi
  cntools_ui_wait
  return "${status}"
}

cntools_catalyst_render_identity() {
  local stake_address=''
  cntools_wallet_read_address "${CNTOOLS_CATALYST_DIRECTORY}" reward stake_address || stake_address=''
  {
    cntools_table_pair Wallet "${CNTOOLS_CATALYST_DIRECTORY##*/}" identifier
    # The authorizing stake key; its stake is the voting power.
    [[ -z "${stake_address}" ]] || cntools_table_pair 'Stake address' "${stake_address}" identifier
    cntools_table_pair 'Voting public key' "${CNTOOLS_CATALYST_PUBLIC}" identifier
    cntools_table_pair 'Rewards address' "${CNTOOLS_CATALYST_REWARD}" identifier
    [[ -z "${CNTOOLS_CATALYST_NONCE}" ]] || cntools_table_pair Nonce "$(cntools_number_format "${CNTOOLS_CATALYST_NONCE}")" number
    cntools_table_pair Format 'CIP-36 · Catalyst voting purpose 0' value
  } | cntools_table_render 'Catalyst registration'
  cntools_ui_render_status info 'Registration inclusion is not fund eligibility. Check the current fund snapshot and requirements through Verify.'
  [[ "${CNTOOLS_NETWORK}" == mainnet ]] || cntools_ui_render_status warn 'This is a testnet registration and cannot grant mainnet Catalyst voting eligibility.'
}

cntools_catalyst_recheck() {
  local frozen="${1:-${CNTOOLS_CATALYST_METADATA}}"
  cntools_catalyst_identity "${CNTOOLS_CATALYST_DIRECTORY}" && cntools_catalyst_keys_prepare "${CNTOOLS_CATALYST_DIRECTORY}" &&
    cntools_catalyst_verify_metadata "${frozen}"
}

cntools_catalyst_registration_workflow() {
  local selected='' choice='' nonce='' metadata='' saved='' status=0 context='' nonce_auto=N decision=''
  CNTOOLS_CATALYST_NONCE=''; CNTOOLS_CATALYST_METADATA=''; CNTOOLS_CATALYST_SAVED_NOTE=''
  cntools_wallet_catalog_build && cntools_transaction_require_cli || return 2
  cntools_wallet_choose selected Cancel catalyst || return $?
  cntools_catalyst_identity "${CNTOOLS_WALLET_PATHS[selected]}" || return 2
  CNTOOLS_CATALYST_DIRECTORY="${CNTOOLS_WALLET_PATHS[selected]}"
  local -a names=()
  cntools_catalyst_names_into names || return 2
  if [[ -e "${CNTOOLS_CATALYST_DIRECTORY}/${names[0]}" || -L "${CNTOOLS_CATALYST_DIRECTORY}/${names[0]}" ||
        -e "${CNTOOLS_CATALYST_DIRECTORY}/${names[0]}.gpg" || -L "${CNTOOLS_CATALYST_DIRECTORY}/${names[0]}.gpg" ]]; then
    cntools_ui_spin_function 'Validating the existing voting identity…' cntools_catalyst_keys_prepare "${CNTOOLS_CATALYST_DIRECTORY}" || return 2
  elif [[ ! -e "${CNTOOLS_CATALYST_DIRECTORY}/${names[1]}" && ! -L "${CNTOOLS_CATALYST_DIRECTORY}/${names[1]}" ]]; then
    cntools_ui_render_status warn 'A new voting key will be saved in this wallet. Back it up separately; it is not recoverable from the payment wallet mnemonic.'
    cntools_ui_flow_confirm 'Create and save a Catalyst voting key?' false || return $?
    cntools_ui_spin_function 'Generating and validating the voting key…' cntools_catalyst_keys_prepare "${CNTOOLS_CATALYST_DIRECTORY}" create || return 2
    CNTOOLS_CATALYST_SAVED_NOTE="The new Catalyst voting key was kept in ${CNTOOLS_CATALYST_DIRECTORY##*/}. Back it up separately."
  else
    cntools_catalyst_keys_prepare "${CNTOOLS_CATALYST_DIRECTORY}" || return 2
  fi
  cntools_catalyst_render_identity || return 2
  # Offer only what can work: offline cannot import for submission, and an
  # encrypted/watch-only stake key cannot sign here.
  local -a options=()
  local hint='The original file is retained; its registration signature is verified before use.' entered='' encoded=''
  ! cntools_catalyst_stake_signable || options+=('Authorize with wallet stake key')
  [[ "${CNTOOLS_MODE}" == offline ]] || options+=('Import metadata signed offline')
  if ((${#options[@]} == 0)); then
    cntools_catalyst_fail 'This wallet cannot sign the Catalyst authorization here. Decrypt its stake key, or sign offline and import the metadata online.'; return 2
  elif ((${#options[@]} == 1)); then
    choice="${options[0]}"
    cntools_transaction_log CHOICE "Catalyst authorization auto=${choice} only option"
    if [[ "${choice}" == 'Import metadata signed offline' ]]; then
      hint="This wallet's stake key cannot sign here, so import registration metadata signed offline. ${hint}"
    else
      cntools_ui_render_status info 'Offline mode: authorizing with the wallet stake key. Import the saved metadata online to submit it.'
    fi
  else
    cntools_ui_choose choice 'Registration authorization' "${options[@]}" Cancel || return $?
  fi
  [[ "${choice}" != Cancel ]] || return 1
  if [[ "${choice}" == 'Import metadata signed offline' ]]; then
    cntools_ui_pick_path metadata 'Signed CIP-36 JSON metadata' "${hint}" "${CNTOOLS_ROOT}/.transactions" || return $?
    cntools_ui_spin_function 'Verifying the stake-key signature and registration…' cntools_catalyst_verify_metadata "${metadata}" || return 2
  else
    if [[ "${CNTOOLS_MODE}" != offline ]]; then
      cntools_ui_spin_function 'Fetching the current slot…' cntools_funding_collect "${CNTOOLS_PAYMENT_ADDRESS}" "${CNTOOLS_PAYMENT_PAYMENT}" || return 2
      nonce="${CNTOOLS_FUNDING_SLOT}"
    fi
    # Quick uses the current slot online (offline there is no default); its
    # authorize step then offers to change it.
    if [[ -n "${nonce}" ]] && cntools_flow_quick && cntools_catalyst_cbor_uint_into encoded "${nonce}"; then
      nonce_auto=Y
      cntools_transaction_log CHOICE "Catalyst nonce default=${nonce} flow=quick"
    fi
    cntools_ui_render_status warn 'The nonce must exceed previous registrations for this stake key. Catalyst fund snapshots may not include a new registration until their next update.'
    [[ "${CNTOOLS_PAYMENT_TYPE}" != Hardware ]] || cntools_ui_render_status info 'Connect/unlock the hardware wallet and approve Catalyst registration on the device.'
    while true; do
      if [[ "${nonce_auto}" != Y ]]; then
        status=0
        cntools_ui_input entered 'Registration nonce' "${nonce:-Whole nonce · higher than any previous registration}" || status=$?
        # Esc while changing the Quick default keeps it.
        if ((status == 1)) && [[ "${nonce_auto}" == changing ]]; then nonce_auto=Y; continue; fi
        ((status == 0)) || return "${status}"
        entered="${entered:-${nonce}}"
        cntools_number_normalize_into entered "${entered}" || entered=invalid
        if ! cntools_catalyst_cbor_uint_into encoded "${entered}"; then
          cntools_ui_render_status warn 'Enter a whole nonce from 0 to 9,007,199,254,740,991.'; continue
        fi
        nonce="${entered}"
      fi
      if [[ "${nonce_auto}" == Y ]]; then
        cntools_ui_choose decision "Authorize with the wallet stake key · nonce $(cntools_number_format "${nonce}") (current slot)" \
          Authorize 'Change nonce' Cancel || return $?
        cntools_transaction_log CHOICE "Catalyst authorization decision=${decision}"
        case "${decision}" in
          Authorize) break ;;
          'Change nonce') nonce_auto=changing; continue ;;
          *) return 1 ;;
        esac
      fi
      cntools_ui_confirm 'Authorize this voting key and rewards address with the wallet stake key?' false || return $?
      break
    done
    cntools_ui_spin_function 'Signing and verifying Catalyst authorization…' cntools_catalyst_authorize "${nonce}" || return 2
  fi
  cntools_transaction_save_into saved "${CNTOOLS_CATALYST_METADATA}" metadata catalyst-authorization || return 2
  CNTOOLS_CATALYST_METADATA="${saved}"
  CNTOOLS_CATALYST_SAVED_NOTE="The signed authorization was kept: ${saved}. Use Registration → Import metadata signed offline to submit it later."
  if [[ "${CNTOOLS_MODE}" == offline ]]; then
    cntools_catalyst_begin
    {
      cntools_table_pair Status 'Stake authorization verified · not submitted' success
      cntools_table_pair 'Metadata file' "${saved}" identifier
    } | cntools_table_render 'Catalyst authorization'
    cntools_ui_render_status info 'Move only this public metadata and the voting public key online. Choose Registration → Import metadata signed offline, then export/sign/submit the funding transaction.'
    return 0
  fi
  cntools_send_prepare_wallet "${CNTOOLS_CATALYST_DIRECTORY}" || return 2
  context="$(jq -cn --arg key "${CNTOOLS_CATALYST_PUBLIC}" --arg nonce "${CNTOOLS_CATALYST_NONCE}" '{action:"catalyst-register",votingKey:$key,nonce:$nonce,format:"CIP-36"}')" || return 2
  cntools_metadata_transaction_workflow catalyst-register 'Register for Catalyst' 'Publish the reviewed stake-key authorization; only the funding fee is spent.' \
    "${context}" "${saved}" cntools_catalyst_begin cntools_catalyst_render_identity cntools_catalyst_recheck "${CNTOOLS_CATALYST_DIRECTORY}"
}

cntools_catalyst_action_registration() {
  local status=0
  cntools_transaction_clear_error; cntools_catalyst_begin
  cntools_catalyst_registration_workflow || status=$?
  cntools_catalyst_action_finish "${status}" 'Catalyst registration failed.'
}

cntools_catalyst_qr_workflow() {
  local selected='' pin='' repeated='' status=0 directory=''
  cntools_wallet_catalog_build && cntools_transaction_require_cli || return 2
  cntools_wallet_choose selected Cancel catalyst-qr || return $?
  directory="${CNTOOLS_WALLET_PATHS[selected]}"
  cntools_ui_render_status warn 'The QR contains the voting secret protected by a four-digit PIN. Keep it private and save the PIN separately. Toolbox briefly exposes the PIN to same-user process inspection.'
  cntools_ui_flow_confirm 'Display and save a new PIN-protected voting QR?' false || return $?
  # A mistyped PIN or confirmation asks for both again.
  while true; do
    cntools_ui_password pin 'Four-digit QR PIN' || { status=$?; unset pin; return "${status}"; }
    if [[ ! "${pin}" =~ ^[0-9]{4}$ ]]; then
      unset pin; cntools_ui_render_status warn 'Enter exactly four digits, including any leading zeros.'; continue
    fi
    cntools_ui_password repeated 'Confirm QR PIN' || { status=$?; unset pin repeated; return "${status}"; }
    [[ "${pin}" != "${repeated}" ]] || break
    unset pin repeated; cntools_ui_render_status warn 'The PINs did not match. Enter the PIN again.'
  done
  cntools_ui_spin_function 'Generating the encrypted voting QR…' cntools_catalyst_qr_create "${directory}" "${pin}" || status=$?
  unset pin repeated
  ((status == 0)) || return 2
  cntools_ui_action_begin 'Display QR' '/ Vote / Catalyst / Display QR'
  {
    cntools_table_pair Wallet "${directory##*/}" identifier
    cntools_table_pair 'Encrypted QR image' "${CNTOOLS_CATALYST_QR_OUTPUT}" identifier
  } | cntools_table_render 'Voting QR'
  # QR console output is intentionally visible to the operator, never logged.
  printf '%s\n' "$(< "${CNTOOLS_CATALYST_QR_TEXT}")"
  cntools_ui_render_status info 'Scan with the Catalyst Voting app. This QR alone does not prove registration or eligibility.'
}

cntools_catalyst_action_qr() {
  local status=0
  cntools_transaction_clear_error; cntools_ui_action_begin 'Display QR' '/ Vote / Catalyst / Display QR'
  CNTOOLS_CATALYST_SAVED_NOTE=''
  cntools_catalyst_qr_workflow || status=$?
  cntools_catalyst_action_finish "${status}" 'Voting QR generation failed.'
}

cntools_catalyst_verify_render() {
  local public="$1" details="$2" value='' date_label='' timestamp='' address='' delegator_file='' local_wallet='' stake_address='' index=0
  cntools_ui_action_begin Verify '/ Vote / Catalyst / Verify'
  {
    cntools_table_pair 'Voting public key' "${public}" identifier
    cntools_table_pair Status "${CNTOOLS_CATALYST_STATUS}" value
    cntools_table_pair Source 'Official Catalyst API · fund snapshot' muted
    if jq -e 'has("error")' "${CNTOOLS_CATALYST_STATUS_FILE}" >/dev/null; then
      cntools_table_pair 'API response' "$(jq -r '.error|tostring' "${CNTOOLS_CATALYST_STATUS_FILE}")" warning
    else
      value="$(jq -r '.voter_info.voting_power|tostring' "${CNTOOLS_CATALYST_STATUS_FILE}")"
      cntools_table_pair 'Snapshot voting power' "$(cntools_number_format_lovelace "${value}")" number
      value="$(jq -r '.voter_info.delegations_count|tostring' "${CNTOOLS_CATALYST_STATUS_FILE}")"
      cntools_table_pair Delegations "$(cntools_number_format "${value}")" number
      cntools_table_pair Finalized "$(jq -r 'if .final == true then "Yes" elif .final == false then "No" else "Unknown" end' "${CNTOOLS_CATALYST_STATUS_FILE}")" value
      value="$(jq -r '.last_updated // empty' "${CNTOOLS_CATALYST_STATUS_FILE}")"
      if [[ -n "${value}" ]]; then
        timestamp="$(date -d "${value}" +%s 2>/dev/null || true)"
        if cntools_timestamp_datetime_into date_label "${timestamp}"; then cntools_table_pair 'Snapshot updated' "${date_label}" number; fi
      fi
    fi
  } | cntools_table_render 'Catalyst snapshot'
  while IFS= read -r address; do
    [[ -n "${address}" ]] || continue
    index=$((index+1)); delegator_file=''; local_wallet=''; stake_address=''
    cntools_catalyst_delegator_wallet_into local_wallet "${address}" || true
    cntools_catalyst_delegator_address_into stake_address "${address}" || true
    if [[ "${details}" == Y ]]; then
      cntools_ui_spin_function "Checking delegator ${index}…" cntools_catalyst_delegator_lookup_into delegator_file "${address}" || true
    fi
    {
      [[ -z "${local_wallet}" ]] || cntools_table_pair Wallet "${local_wallet}" accent
      cntools_table_pair 'Stake public key' "${address}" identifier
      [[ -z "${stake_address}" ]] || cntools_table_pair 'Stake address' "${stake_address}" identifier
      if [[ -n "${delegator_file}" ]]; then
        cntools_table_pair 'Reward address' "$(jq -r '.reward_address' "${delegator_file}")" identifier
        if [[ "$(jq -r '.reward_payable' "${delegator_file}")" == true ]]; then
          cntools_table_pair 'Reward payable' Yes success
        else
          cntools_table_pair 'Reward payable' No warning
        fi
        cntools_table_pair 'Individual voting power' "$(cntools_number_format_lovelace "$(jq -r '.raw_power|tostring' "${delegator_file}")")" number
      elif [[ "${details}" == Y ]]; then
        cntools_table_pair 'Reward / power details' Unavailable warning
      fi
    } | cntools_table_render "${index} · Delegator"
  done < <(jq -r '.voter_info.delegator_addresses // [] | .[]' "${CNTOOLS_CATALYST_STATUS_FILE}")
  cntools_ui_render_status info 'Snapshot status is separate from current Cardano registration inclusion. Check the current fund rules and dates before voting.'
}

cntools_catalyst_verify_workflow() {
  local choice='' public='' value='' index=0 status=0
  local -a labels=() paths=()
  # Snapshots exist on mainnet only: say so before any prompt.
  if [[ "${CNTOOLS_NETWORK:-}" != mainnet ]]; then
    cntools_ui_render_status info 'Catalyst fund snapshot verification is available on mainnet only. Testnet registration metadata does not grant voting eligibility.'
    cntools_ui_wait; return 3
  fi
  # One picker: wallets with a voting key, plus an external key.
  if cntools_wallet_catalog_build; then
    for index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
      cntools_wallet_selection_candidate_into value "${index}" catalyst-key || continue
      labels+=("Wallet · ${CNTOOLS_WALLET_NAMES[index]}"); paths+=("${CNTOOLS_WALLET_PATHS[index]}")
    done
  fi
  choice='External voting public key'
  if ((${#labels[@]} > 0)); then
    cntools_ui_choose choice 'Voting key to verify' "${labels[@]}" 'External voting public key' Cancel || return $?
    [[ "${choice}" != Cancel ]] || return 1
  else
    cntools_ui_render_status info 'No CNTools wallet has a Catalyst voting key. Enter an external voting public key.'
  fi
  cntools_log CHOICE "Catalyst verify key source=${choice}" || true
  if [[ "${choice}" == 'External voting public key' ]]; then
    while true; do
      cntools_ui_input public 'Voting public key' '64 hexadecimal characters' || return $?
      cntools_recipient_trim_into public "${public}"; public="${public,,}"; public="${public#0x}"
      [[ "${public}" =~ ^[0-9a-f]{64}$ ]] && break
      cntools_ui_render_status warn 'Enter exactly 64 hexadecimal characters.'
    done
  else
    for index in "${!labels[@]}"; do
      [[ "${labels[index]}" != "${choice}" ]] || value="${paths[index]}"
    done
    local -a names=()
    [[ -n "${value}" ]] && cntools_catalyst_names_into names && cntools_catalyst_public_into public "${value}/${names[1]}" || {
      cntools_catalyst_fail 'The selected wallet has no valid Catalyst public key.'; return 2;
    }
  fi
  cntools_ui_spin_function 'Checking the official Catalyst snapshot…' cntools_catalyst_lookup "${public}" || return 2
  cntools_wallet_catalog_build || true
  cntools_catalyst_verify_render "${public}" N || return 2
  jq -e '.voter_info.delegator_addresses|length>0' "${CNTOOLS_CATALYST_STATUS_FILE}" >/dev/null 2>&1 || return 0
  # Both styles: the per-delegator lookup is optional and asked after the table.
  status=0
  cntools_ui_choose choice 'Delegators' Done 'Fetch delegator voting power and rewards' || status=$?
  ((status != 130)) || return 130
  ((status == 0)) || return 4
  [[ "${choice}" != Done ]] || return 4
  cntools_catalyst_verify_render "${public}" Y || return 2
}

cntools_catalyst_action_verify() {
  local status=0
  cntools_transaction_clear_error; cntools_ui_action_begin Verify '/ Vote / Catalyst / Verify'
  CNTOOLS_CATALYST_SAVED_NOTE=''
  cntools_catalyst_verify_workflow || status=$?
  # 4: the result was acknowledged at its own final prompt.
  ((status != 4)) || return 0
  cntools_catalyst_action_finish "${status}" 'Catalyst verification failed.'
}
