#!/usr/bin/env bash
# Missing-only first operational certificate. Never rotate keys or rewind counters.
# shellcheck disable=SC2034
cntools_pool_kes_period_into() {
  local output="$1" slot='' periods="${CNTOOLS_SLOTS_PER_KES_PERIOD:-}" genesis="${CNTOOLS_SHELLEY_GENESIS:-}" config="${CNTOOLS_CONFIG:-}"
  if [[ -z "${periods}" ]]; then
    if [[ -z "${genesis}" ]] && cntools_pool_public_file_safe "${config}" 1048576; then
      genesis="$(jq -r '.ShelleyGenesisFile // empty' "${config}")" || return 1
      [[ -z "${genesis}" || "${genesis}" == /* ]] || genesis="${config%/*}/${genesis}"
    fi
    cntools_pool_public_file_safe "${genesis}" 1048576 || return 1
    periods="$(jq -er '.slotsPerKESPeriod | select(type == "number" and . > 0 and floor == .)' "${genesis}")" || return 1
  fi
  [[ "${periods}" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
  cntools_funding_tip_into slot "${CNTOOLS_WALLET_REGISTER_BACKEND}" || return 1
  printf -v "${output}" '%s' "$((slot / periods))"
}

# Copies the public inputs into the recovery stage and runs the issuing
# command. Nothing is issued unless this returns 0.
cntools_pool_opcert_sign() {
  local stage="$1" period="$2" kind="$3" directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" cold='' kes='' counter='' cert='' start='' response='' errors='' status=0
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into kes kes-vkey
  cntools_pool_file_name_into counter counter; cntools_pool_file_name_into cert opcert; cntools_pool_file_name_into start kes-start
  cp -- "${directory}/${cold}" "${directory}/${kes}" "${directory}/${counter}" "${stage}/" &&
    chmod 0600 "${stage}/${cold}" "${stage}/${kes}" "${stage}/${counter}" && printf '%s\n' "${period}" > "${stage}/${start}" || return 1
  cntools_transaction_log POOL "Issuing missing operational certificate pool=${CNTOOLS_POOL_REG_ID} KES=${period} recovery=${stage}"
  if [[ "${kind}" == cli ]]; then
    cntools_pool_cli latest node issue-op-cert --kes-verification-key-file "${stage}/${kes}" \
      --cold-signing-key-file "${CNTOOLS_POOL_REG_COLD_SOURCE}" --operational-certificate-issue-counter-file "${stage}/${counter}" \
      --kes-period "${period}" --out-file "${stage}/${cert}"
    return
  fi
  cntools_transaction_hardware_device_check || return 1
  cntools_transaction_temp_file response pool-opcert-hardware; cntools_transaction_temp_file errors pool-opcert-hardware-errors
  local CNTOOLS_TRANSACTION_TIMEOUT="${CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT:-${CNTOOLS_TRANSACTION_TIMEOUT:-60}}"
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_TRANSACTION_HWCLI}" node issue-op-cert \
    --kes-verification-key-file "${stage}/${kes}" --hw-signing-file "${CNTOOLS_POOL_REG_COLD_SOURCE}" \
    --operational-certificate-issue-counter-file "${stage}/${counter}" --kes-period "${period}" --out-file "${stage}/${cert}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Hardware operational certificate failed' "${status}" "${errors}" "${response}"; return 1; fi
}

# The lock records its recovery stage so Pool → Rotate can show it.
cntools_pool_opcert_unlock() {
  rm -f -- "$1/rotation" && rmdir -- "$1"
}

cntools_pool_opcert_issue() {
  local period="$1" directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" cold='' kes='' counter='' cert='' start='' stage='' kind='' original='' saved='' lock='' recovery=''
  [[ "${period}" =~ ^(0|[1-9][0-9]{0,9})$ ]] && cntools_pool_directory_writable "${directory}" &&
    cntools_pool_filenames_validate || return 1
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into kes kes-vkey
  cntools_pool_file_name_into counter counter; cntools_pool_file_name_into cert opcert; cntools_pool_file_name_into start kes-start
  [[ ! -e "${directory}/${cert}" && ! -L "${directory}/${cert}" && ! -e "${directory}/${start}" && ! -L "${directory}/${start}" ]] || {
    cntools_wallet_register_set_error 'Operational certificate or KES start already exists. Review operational setup separately; this wizard never rotates or overwrites existing artifacts.'; return 1;
  }
  cntools_pool_key_validate "${directory}/${kes}" kes verification && cntools_pool_public_records_prepare "${directory}" || return 1
  cntools_transaction_source_kind_into kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" || return 1
  [[ "$(jq -r .cborHex "${directory}/${cold}")" == "$(jq -r .cborHex "${CNTOOLS_POOL_REG_COLD_VKEY}")" ]] || return 1
  original="$(jq -cS . "${directory}/${counter}")" || return 1
  # Keep a durable recovery directory in the CNTools state folder, outside
  # ordinary transaction cleanup. The shared per-pool certificate lock
  # prevents a second issuance if publication is interrupted.
  cntools_pool_folder_name_supported "${directory}" || {
    cntools_wallet_register_set_error "$(cntools_pool_folder_unsupported_message "${directory}")"; return 1;
  }
  ! cntools_pool_legacy_opcert_lock "${directory}" || {
    cntools_wallet_register_set_error "An earlier CNTools build left an operational-certificate lock in ${directory}/.cntools-opcert-lock. Finish or inspect that operation manually before retrying."; return 1;
  }
  cntools_pool_opcert_lock_into lock "${directory}" && cntools_state_directory_into recovery recovery || {
    cntools_wallet_register_set_error 'The owner-only CNTools state folder (.cntools in the node home) is unavailable.'; return 1;
  }
  saved="$(umask)"; umask 077
  if ! mkdir -- "${lock}" 2>/dev/null; then
    umask "${saved}"; cntools_wallet_register_set_error "Another operational-certificate operation is pending for this pool. Open Pool → Rotate to inspect or release it (lock ${lock}, recovery files in ${recovery})."; return 1
  fi
  stage="$(mktemp -d "${recovery}/opcert-${directory##*/}.XXXXXX")" || { umask "${saved}"; rmdir -- "${lock}"; return 1; }
  umask "${saved}"
  printf '%s\n' "${stage##*/}" > "${lock}/rotation" || { cntools_pool_opcert_unlock "${lock}"; return 1; }
  CNTOOLS_POOL_OPCERT_RECOVERY="${stage}"
  # Until the issuing command succeeds nothing was issued: any failure (device
  # check, timeout) releases the lock and keeps the recovery copy.
  if ! cntools_pool_opcert_sign "${stage}" "${period}" "${kind}"; then
    if cntools_pool_opcert_unlock "${lock}"; then
      CNTOOLS_POOL_OPCERT_RECOVERY=''
      cntools_transaction_log POOL "First operational certificate not issued; lock released, recovery kept=${stage}"
    else cntools_transaction_log WARN "First operational certificate not issued; lock could not be released=${lock}"; fi
    return 1
  fi
  CNTOOLS_POOL_OPCERT_ISSUED=Y
  cntools_pool_public_records_prepare "${stage}" && chmod 0600 "${stage}/${cert}" "${stage}/${start}" || return 1
  [[ "$(jq -cS . "${directory}/${counter}")" == "${original}" ]] || {
    cntools_wallet_register_set_error "${counter} changed while the certificate was issued, so it was not installed."; return 1;
  }
  # Consume the issued counter BEFORE exposing the certificate. On any failure,
  # retain the signed certificate + advanced counter; never roll the counter back.
  cntools_pool_public_save "${directory}" "${counter}" "${stage}/${counter}" &&
    cntools_pool_publish_new_file "${stage}/${start}" "${directory}/${start}" &&
    cntools_pool_publish_new_file "${stage}/${cert}" "${directory}/${cert}" || return 1
  cntools_pool_new_file_lock "${directory}/${start}"; cntools_pool_new_file_lock "${directory}/${cert}"
  # Installed and its counter consumed: a lock left behind only blocks
  # Rotate, which can release it, so this is a warning, not a failure.
  if ! cntools_pool_opcert_unlock "${lock}"; then
    CNTOOLS_POOL_WRITE_WARNING="${CNTOOLS_POOL_WRITE_WARNING:+${CNTOOLS_POOL_WRITE_WARNING} }The certificate lock ${lock} could not be removed; open Pool → Rotate to release it."
    cntools_transaction_log WARN "Operational certificate published; lock could not be released=${lock}"
  fi
  CNTOOLS_POOL_OPCERT_RECOVERY=''
  cntools_transaction_log POOL "Operational certificate published; recovery copy retained=${stage}"
}

# What issuing the first certificate needs, checked before the question so
# a "Prepare certificate" answer cannot fail on a known problem. Sets the
# reason when it cannot be offered.
cntools_pool_opcert_ready_into() {
  local por_output="$1" por_directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" por_kes='' por_counter='' por_start='' por_lock='' por_reason=''
  cntools_pool_file_name_into por_kes kes-vkey; cntools_pool_file_name_into por_counter counter
  cntools_pool_file_name_into por_start kes-start
  if [[ -e "${por_directory}/${por_start}" || -L "${por_directory}/${por_start}" ]]; then
    por_reason="${por_start} exists without a certificate. Check the pool folder; Pool → Rotate issues certificates."
  elif ! cntools_pool_key_validate "${por_directory}/${por_kes}" kes verification; then
    por_reason="the KES public key (${por_kes}) is missing or invalid."
  elif ! cntools_pool_public_file_safe "${por_directory}/${por_counter}" ||
       ! jq -e '.type == "NodeOperationalCertificateIssueCounter"' "${por_directory}/${por_counter}" >/dev/null 2>&1; then
    por_reason="the issue counter (${por_counter}) is missing or does not belong to this pool. Restore the real counter; never reset it."
  elif ! cntools_pool_folder_name_supported "${por_directory}"; then
    por_reason="$(cntools_pool_folder_unsupported_message "${por_directory}")"
  elif ! cntools_pool_directory_writable "${por_directory}"; then
    por_reason='the pool folder must be owned, writable and protected from group/public writes.'
  elif cntools_pool_legacy_opcert_lock "${por_directory}"; then
    por_reason="an earlier CNTools build left ${por_directory}/.cntools-opcert-lock. Finish or inspect that operation first."
  elif cntools_pool_opcert_lock_into por_lock "${por_directory}" && [[ -e "${por_lock}" || -L "${por_lock}" ]]; then
    por_reason='another certificate operation is pending for this pool. Open Pool → Rotate to inspect or release it.'
  fi
  printf -v "${por_output}" '%s' "${por_reason}"
  [[ -z "${por_reason}" ]]
}

# Optional first certificate after the review. A failure here is reported and
# the pool transaction continues; Rotate can issue the certificate later.
# Without a local cold key the result's Next steps explain the offline steps.
# Esc at its questions returns 1: the caller goes back to the review.
CNTOOLS_POOL_OPCERT_OFFLINE=N CNTOOLS_POOL_OPCERT_NOTE='' CNTOOLS_POOL_OPCERT_ISSUED=N
cntools_pool_opcert_offer() {
  local workflow="$1" directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" cert='' start='' choice='' period='' input='' normalized='' kind='' prompt='Prepare the missing operational certificate?'
  local reason=''
  CNTOOLS_POOL_OPCERT_RECOVERY='' CNTOOLS_POOL_OPCERT_OFFLINE=N CNTOOLS_POOL_OPCERT_NOTE='' CNTOOLS_POOL_OPCERT_ISSUED=N
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-register ]] || return 0
  cntools_pool_file_name_into cert opcert; cntools_pool_file_name_into start kes-start
  [[ ! -e "${directory}/${cert}" ]] || return 0
  if [[ "${workflow}" == 'Create unsigned package' || -z "${CNTOOLS_POOL_REG_COLD_SOURCE}" ]]; then
    CNTOOLS_POOL_OPCERT_OFFLINE=Y
    cntools_transaction_log POOL 'First operational certificate left to the signing system; shown in Next steps'
    return 0
  fi
  if ! cntools_pool_opcert_ready_into reason; then
    # The result screen repeats this warning; Next steps keeps it.
    CNTOOLS_POOL_OPCERT_NOTE="Not prepared: ${reason}"
    cntools_transaction_log WARN "First operational certificate not offered: ${reason}"
    cntools_ui_render_status warn "The first operational certificate cannot be prepared here: ${reason}"
    return 0
  fi
  # The certificate starts at the chain's current KES period, as in Rotate;
  # only without a chain tip is it entered.
  cntools_ui_spin_function 'Checking the current KES period…' cntools_pool_kes_period_into period || period=''
  [[ -z "${period}" ]] || prompt="Prepare the missing operational certificate at KES period $(cntools_number_format "${period}")?"
  cntools_ui_render_status info 'No operational certificate exists. Prepare the first certificate with the existing KES keys? This advances the issue counter even if the pool transaction is later cancelled. Imported pools must use their real issue counter, not a reset counter.'
  [[ -n "${period}" ]] || cntools_ui_render_status warn 'The current KES period could not be calculated from the chain tip and Shelley genesis. Preparing asks for the period verified for this network.'
  cntools_pool_registration_choose choice "${prompt}" 'Prepare certificate' 'Keep operational setup separate' || return $?
  [[ "${choice}" == 'Prepare certificate' ]] || return 0
  if [[ -n "${period}" ]]; then
    input="${period}"
    cntools_transaction_log CHOICE "Pool KES start period=${period} (chain tip)"
  else
    while true; do
      cntools_pool_registration_input input 'Current KES period' 'Whole number verified for this network, for example from gLiveView' || return $?
      cntools_number_normalize_into normalized "${input}" 2>/dev/null || normalized=''
      if [[ "${normalized}" =~ ^(0|[1-9][0-9]{0,9})$ ]] && ((normalized < 2147483647)); then input="${normalized}"; break; fi
      cntools_ui_render_status warn 'Enter the current KES period as a whole number, for example the period shown by gLiveView.'
    done
  fi
  cntools_transaction_source_kind_into kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" || kind=''
  [[ "${kind}" != hardware ]] || cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'
  CNTOOLS_POOL_WRITE_ERROR='' CNTOOLS_POOL_WRITE_WARNING=''
  if ! cntools_ui_spin_function 'Issuing the first operational certificate…' cntools_pool_opcert_issue "${input}"; then
    # Never reported again as the transaction's own failure.
    reason="${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_POOL_WRITE_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-}}}"
    if [[ "${CNTOOLS_POOL_OPCERT_ISSUED}" == Y ]]; then
      cntools_ui_render_status warn "A certificate was issued but not fully installed.${reason:+ ${reason%.}.} The pool transaction continues without it. Never reset the counter: open Pool → Rotate to inspect the lock and the recovery files at ${CNTOOLS_POOL_OPCERT_RECOVERY}."
    else
      reason="${reason:-The operational certificate was not prepared}"
      cntools_ui_render_status warn "${reason%.}. Nothing was issued; the pool transaction continues without it, and Pool → Rotate can issue it later."
    fi
    cntools_transaction_log WARN "First operational certificate not prepared issued=${CNTOOLS_POOL_OPCERT_ISSUED}; registration continues recovery=${CNTOOLS_POOL_OPCERT_RECOVERY:-none}"
    CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
    cntools_ui_wait; return 0
  fi
  cntools_ui_render_status success "Operational certificate ready; KES start period ${input} recorded in ${directory}/${start}. Existing KES/VRF keys were not replaced."
  [[ -z "${CNTOOLS_POOL_WRITE_WARNING:-}" ]] || cntools_ui_render_status warn "${CNTOOLS_POOL_WRITE_WARNING}"
  cntools_ui_wait
}
