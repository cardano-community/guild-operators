#!/usr/bin/env bash
# Catalyst registration, QR and official snapshot status using shared tables.
# shellcheck disable=SC2034,SC2015

cntools_catalyst_begin() { cntools_ui_action_begin Catalyst '/ Vote / Catalyst / Registration'; }

cntools_catalyst_render_identity() {
  {
    cntools_table_pair Wallet "${CNTOOLS_CATALYST_DIRECTORY##*/}" identifier
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
  local selected='' choice='' nonce='' metadata='' saved='' status=0 context=''
  CNTOOLS_CATALYST_NONCE=''; CNTOOLS_CATALYST_METADATA=''
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
    cntools_ui_confirm 'Create and save a Catalyst voting key?' false || return $?
    cntools_ui_spin_function 'Generating and validating the voting key…' cntools_catalyst_keys_prepare "${CNTOOLS_CATALYST_DIRECTORY}" create || return 2
  else
    cntools_catalyst_keys_prepare "${CNTOOLS_CATALYST_DIRECTORY}" || return 2
  fi
  cntools_catalyst_render_identity || return 2
  local -a options=('Authorize with wallet stake key' 'Import metadata signed offline' Cancel)
  [[ "${CNTOOLS_MODE}" != offline ]] || options=('Authorize with wallet stake key' Cancel)
  cntools_ui_choose choice 'Registration authorization' "${options[@]}" || return $?
  [[ "${choice}" != Cancel ]] || return 1
  if [[ "${choice}" == 'Import metadata signed offline' ]]; then
    cntools_ui_input metadata 'Signed CIP-36 JSON metadata' 'Absolute path · original retained' || return $?
    cntools_ui_spin_function 'Verifying the stake-key signature and registration…' cntools_catalyst_verify_metadata "${metadata}" || return 2
  else
    if [[ "${CNTOOLS_MODE}" != offline ]]; then
      cntools_ui_spin_function 'Fetching the current slot…' cntools_funding_collect "${CNTOOLS_PAYMENT_ADDRESS}" "${CNTOOLS_PAYMENT_PAYMENT}" || return 2
      nonce="${CNTOOLS_FUNDING_SLOT}"
    fi
    while true; do
      cntools_ui_input selected 'Registration nonce' "${nonce:-Whole nonce · higher than any previous registration}" || return $?
      selected="${selected:-${nonce}}"
      cntools_number_normalize_into selected "${selected}" || selected=invalid
      if cntools_catalyst_cbor_uint_into choice "${selected}"; then nonce="${selected}"; break; fi
      cntools_ui_render_status warn 'Enter a whole nonce from 0 to 9,007,199,254,740,991.'
    done
    cntools_ui_render_status warn 'The nonce must exceed previous registrations for this stake key. Catalyst fund snapshots may not include a new registration until their next update.'
    [[ "${CNTOOLS_PAYMENT_TYPE}" != Hardware ]] || cntools_ui_render_status info 'Connect/unlock the hardware wallet and approve Catalyst registration on the device.'
    cntools_ui_confirm 'Authorize this voting key and rewards address with the wallet stake key?' false || return $?
    cntools_ui_spin_function 'Signing and verifying Catalyst authorization…' cntools_catalyst_authorize "${nonce}" || return 2
  fi
  cntools_transaction_save_into saved "${CNTOOLS_CATALYST_METADATA}" metadata catalyst-authorization || return 2
  CNTOOLS_CATALYST_METADATA="${saved}"
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
    "${context}" "${saved}" cntools_catalyst_begin cntools_catalyst_render_identity cntools_catalyst_recheck
}

cntools_catalyst_action_registration() {
  local status=0
  cntools_transaction_clear_error; cntools_catalyst_begin
  cntools_catalyst_registration_workflow || status=$?
  if ((status == 1)); then cntools_ui_render_status info 'Cancelled. Already saved voting keys and exported packages were retained.'
  elif ((status != 0)); then cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR:-Catalyst registration failed.} See ${CNTOOLS_LOG} for details."; fi
  cntools_ui_wait
  ((status <= 1))
}

cntools_catalyst_qr_workflow() {
  local selected='' pin='' repeated='' status=0 directory=''
  cntools_wallet_catalog_build && cntools_transaction_require_cli || return 2
  cntools_wallet_choose selected Cancel || return $?
  directory="${CNTOOLS_WALLET_PATHS[selected]}"
  cntools_ui_render_status warn 'The QR contains the voting secret protected by a four-digit PIN. Keep it private and save the PIN separately. Toolbox briefly exposes the PIN to same-user process inspection.'
  cntools_ui_confirm 'Display and save a new PIN-protected voting QR?' false || return $?
  while true; do
    cntools_ui_password pin 'Four-digit QR PIN' || return $?
    [[ "${pin}" =~ ^[0-9]{4}$ ]] && break
    unset pin; cntools_ui_render_status warn 'Enter exactly four digits, including any leading zeros.'
  done
  cntools_ui_password repeated 'Confirm QR PIN' || { unset pin repeated; return 1; }
  if [[ "${pin}" != "${repeated}" ]]; then unset pin repeated; cntools_catalyst_fail 'The PINs did not match. No QR was created.'; return 2; fi
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
  cntools_catalyst_qr_workflow || status=$?
  if ((status == 1)); then cntools_ui_render_status info Cancelled
  elif ((status != 0)); then cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR:-Voting QR generation failed.} See ${CNTOOLS_LOG} for details."; fi
  cntools_ui_wait; ((status <= 1))
}

cntools_catalyst_verify_workflow() {
  local choice='' public='' selected='' value='' date_label='' timestamp='' address=''
  cntools_ui_choose choice 'Voting key to verify' 'CNTools wallet' 'External voting public key' Cancel || return $?
  [[ "${choice}" != Cancel ]] || return 1
  if [[ "${choice}" == 'CNTools wallet' ]]; then
    cntools_wallet_catalog_build && cntools_wallet_choose selected Cancel || return $?
    local -a names=()
    cntools_catalyst_names_into names && cntools_catalyst_public_into public "${CNTOOLS_WALLET_PATHS[selected]}/${names[1]}" || {
      cntools_catalyst_fail 'The selected wallet has no valid Catalyst public key.'; return 2;
    }
  else
    while true; do
      cntools_ui_input public 'Voting public key' '64 hexadecimal characters · no prefix' || return $?
      cntools_recipient_trim_into public "${public}"; public="${public,,}"
      [[ "${public}" =~ ^[0-9a-f]{64}$ ]] && break
      cntools_ui_render_status warn 'Enter exactly 64 hexadecimal characters.'
    done
  fi
  cntools_ui_spin_function 'Checking the official Catalyst snapshot…' cntools_catalyst_lookup "${public}" || return 2
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
      cntools_table_pair Finalized "$(jq -r 'if (.final|type)=="boolean" then .final|tostring else "Unknown" end' "${CNTOOLS_CATALYST_STATUS_FILE}")" value
      value="$(jq -r '.last_updated // empty' "${CNTOOLS_CATALYST_STATUS_FILE}")"
      if [[ -n "${value}" ]]; then
        timestamp="$(date -d "${value}" +%s 2>/dev/null || true)"
        if cntools_timestamp_datetime_into date_label "${timestamp}"; then cntools_table_pair 'Snapshot updated' "${date_label}" number; fi
      fi
    fi
  } | cntools_table_render 'Catalyst snapshot'
  if jq -e '.voter_info.delegator_addresses|length>0' "${CNTOOLS_CATALYST_STATUS_FILE}" >/dev/null; then
    local details=N snapshot="${CNTOOLS_CATALYST_STATUS_FILE}" delegator_file='' local_wallet='' stake_address='' index=0
    if cntools_ui_confirm 'Fetch individual delegator voting power and reward details?' false; then details=Y; fi
    cntools_wallet_catalog_build || true
    while IFS= read -r address; do
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
          value="$(jq -r '.reward_payable|tostring' "${delegator_file}")"
          cntools_table_pair 'Reward payable' "${value}" "$([[ "${value}" == true ]] && printf success || printf warning)"
          cntools_table_pair 'Individual voting power' "$(cntools_number_format_lovelace "$(jq -r '.raw_power|tostring' "${delegator_file}")")" number
        elif [[ "${details}" == Y ]]; then
          cntools_table_pair 'Reward / power details' Unavailable warning
        fi
      } | cntools_table_render "${index} · Delegator"
    done < <(jq -r '.voter_info.delegator_addresses[]' "${snapshot}")
  fi
  cntools_ui_render_status info 'Snapshot status is separate from current Cardano registration inclusion. Check the current fund rules and dates before voting.'
}

cntools_catalyst_action_verify() {
  local status=0
  cntools_transaction_clear_error; cntools_ui_action_begin Verify '/ Vote / Catalyst / Verify'
  cntools_catalyst_verify_workflow || status=$?
  if ((status == 1)); then cntools_ui_render_status info Cancelled
  elif ((status != 0)); then cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR:-Catalyst verification failed.} See ${CNTOOLS_LOG} for details."; fi
  cntools_ui_wait; ((status <= 1))
}
