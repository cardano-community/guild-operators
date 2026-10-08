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

cntools_pool_opcert_issue() {
  local period="$1" directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" cold='' kes='' counter='' cert='' start='' stage='' kind='' response='' errors='' status=0 original='' saved=''
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
  # Keep a durable recovery directory, outside ordinary transaction cleanup.
  # The lock prevents a second issuance if publication is interrupted.
  saved="$(umask)"; umask 077
  if ! mkdir -- "${directory}/.cntools-opcert-lock" 2>/dev/null; then
    umask "${saved}"; cntools_wallet_register_set_error 'Operational certificate preparation is locked. Inspect .cntools-opcert-lock and recovery files before retrying.'; return 1
  fi
  stage="$(mktemp -d "${directory}/.cntools-opcert-recovery.XXXXXX")" || { umask "${saved}"; return 1; }
  umask "${saved}"
  CNTOOLS_POOL_OPCERT_RECOVERY="${stage}"
  cp -- "${directory}/${cold}" "${directory}/${kes}" "${directory}/${counter}" "${stage}/" || return 1
  chmod 0600 "${stage}/${cold}" "${stage}/${kes}" "${stage}/${counter}" || return 1
  printf '%s\n' "${period}" > "${stage}/${start}" || return 1
  cntools_transaction_log POOL "Issuing missing operational certificate pool=${CNTOOLS_POOL_REG_ID} KES=${period} recovery=${stage}"
  if [[ "${kind}" == cli ]]; then
    cntools_pool_cli latest node issue-op-cert --kes-verification-key-file "${stage}/${kes}" \
      --cold-signing-key-file "${CNTOOLS_POOL_REG_COLD_SOURCE}" --operational-certificate-issue-counter-file "${stage}/${counter}" \
      --kes-period "${period}" --out-file "${stage}/${cert}" || return 1
  else
    cntools_transaction_hardware_device_check || return 1
    cntools_transaction_temp_file response pool-opcert-hardware; cntools_transaction_temp_file errors pool-opcert-hardware-errors
    cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_TRANSACTION_HWCLI}" node issue-op-cert \
      --kes-verification-key-file "${stage}/${kes}" --hw-signing-file "${CNTOOLS_POOL_REG_COLD_SOURCE}" \
      --operational-certificate-issue-counter-file "${stage}/${counter}" --kes-period "${period}" --out-file "${stage}/${cert}" || status=$?
    if ((status != 0)); then cntools_transaction_log_cli_failure 'Hardware operational certificate failed' "${status}" "${errors}" "${response}"; return 1; fi
  fi
  cntools_pool_public_records_prepare "${stage}" && chmod 0600 "${stage}/${cert}" "${stage}/${start}" || return 1
  [[ "$(jq -cS . "${directory}/${counter}")" == "${original}" ]] || return 1
  # Consume the issued counter BEFORE exposing the certificate. On any failure,
  # retain the signed certificate + advanced counter; never roll the counter back.
  cntools_pool_public_save "${directory}" "${counter}" "${stage}/${counter}" &&
    ln -- "${stage}/${start}" "${directory}/${start}" && ln -- "${stage}/${cert}" "${directory}/${cert}" || return 1
  rmdir -- "${directory}/.cntools-opcert-lock" || return 1
  CNTOOLS_POOL_OPCERT_RECOVERY=''
  cntools_transaction_log POOL "Operational certificate published; recovery copy retained=${stage}"
}

cntools_pool_opcert_offer() {
  local workflow="$1" directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" cert='' start='' choice='' period='' input=''
  CNTOOLS_POOL_OPCERT_RECOVERY=''
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-register ]] || return 0
  cntools_pool_file_name_into cert opcert; cntools_pool_file_name_into start kes-start
  [[ ! -e "${directory}/${cert}" ]] || return 0
  if [[ "${workflow}" == 'Create unsigned package' || -z "${CNTOOLS_POOL_REG_COLD_SOURCE}" ]]; then
    cntools_ui_render_status info "Offline setup: issue ${cert} using the existing KES public key and real cold.counter on your signing system. Record its start period in ${start}; return ${cert}, ${start} and the advanced counter to this pool directory. Never transfer a private cold key to the node."
    cntools_ui_wait; return 0
  fi
  cntools_ui_render_status info 'No operational certificate exists. Prepare the first certificate with the existing KES keys? This advances the issue counter even if the pool transaction is later cancelled. Imported pools must use their real issue counter, not a reset counter.'
  cntools_pool_registration_choose choice 'Prepare missing operational certificate?' 'Prepare certificate' 'Keep operational setup separate' || return $?
  [[ "${choice}" == 'Prepare certificate' ]] || return 0
  if ! cntools_pool_kes_period_into period; then
    cntools_ui_render_status warn 'KES start could not be calculated from the chain tip and Shelley genesis. Enter the current period verified for this network.'
  fi
  cntools_pool_registration_input input "KES start period (Enter keeps ${period:-no default})" "${period}" || return $?
  [[ -n "${input}" ]] || input="${period}"
  if ! cntools_ui_spin_function 'Issuing the first operational certificate…' cntools_pool_opcert_issue "${input}"; then
    cntools_wallet_register_set_error "Operational certificate preparation failed. Do not reset the counter. Inspect recovery files at ${CNTOOLS_POOL_OPCERT_RECOVERY:-${directory}} before retrying."; return 2
  fi
  cntools_ui_render_status success "Operational certificate ready; KES start recorded in ${directory}/${start}. Existing KES/VRF keys were not replaced."
  cntools_ui_wait
}
