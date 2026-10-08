#!/usr/bin/env bash
# Pool keys are prepared privately and published as one no-clobber directory.
# shellcheck disable=SC2034,SC2015
cntools_pool_generate_runtime_keys() {
  local directory="$1" skey="" vkey="" role="" command=""
  for role in kes vrf; do
    cntools_pool_file_name_into skey "${role}-skey"; cntools_pool_file_name_into vkey "${role}-vkey"
    [[ "${role}" != kes ]] && command=key-gen-VRF || command=key-gen-KES
    cntools_pool_cli latest node "${command}" --verification-key-file "${directory}/${vkey}" --signing-key-file "${directory}/${skey}" || return 1
    cntools_pool_key_pair_prepare "${directory}" "${role}" || return 1
  done
}

cntools_pool_create() {
  local name="$1" stage="" cold="" vkey="" counter=""
  cntools_pool_write_environment "${name}" || return 1
  cntools_pool_stage_into stage || return 1
  cntools_pool_file_name_into cold cold-skey; cntools_pool_file_name_into vkey cold-vkey; cntools_pool_file_name_into counter counter
  if ! cntools_pool_cli latest node key-gen --cold-signing-key-file "${stage}/${cold}" \
      --cold-verification-key-file "${stage}/${vkey}" --operational-certificate-issue-counter-file "${stage}/${counter}" ||
      ! cntools_pool_generate_runtime_keys "${stage}" || ! cntools_pool_key_pair_prepare "${stage}" cold ||
      ! cntools_pool_public_records_prepare "${stage}"; then
    [[ -n "${CNTOOLS_POOL_WRITE_ERROR}" ]] || cntools_pool_write_error 'The generated pool artifacts did not pass validation.'
    return 1
  fi
  cntools_pool_files_cleanup_temps
  cntools_pool_stage_publish "${stage}" "${name}"
}

cntools_pool_import_directory() {
  local name="$1" source="$2" stage="" entry="" base="" role="" hws="" cold="" vkey="" imported=0
  [[ "${source}" == /* && "${source}" != / && -d "${source}" && -r "${source}" && -x "${source}" ]] &&
    cntools_transaction_path_components_safe "${source}" || { cntools_pool_write_error 'Choose a readable pool source directory without symbolic links.'; return 1; }
  cntools_pool_write_environment "${name}" || return 1
  cntools_pool_stage_into stage || return 1
  # Copy regular top-level files, including legacy metadata, without modifying
  # sources or recursively copying another directory's private data.
  for entry in "${source}"/* "${source}"/.[!.]* "${source}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    base="${entry##*/}"
    if [[ "${base}" == .cntools-* || ! "${base}" =~ ^[A-Za-z0-9_.-]+$ ]] ||
        ! cntools_pool_public_file_safe "${entry}" 1048576; then
      cntools_pool_write_error "Unsupported, oversized or linked source entry: ${base}"; return 1
    fi
    cntools_run_command 0000 -- cp -- "${entry}" "${stage}/${base}" && chmod 0600 "${stage}/${base}" || return 1
    imported=$((imported+1))
  done
  (( imported > 0 )) || { cntools_pool_write_error 'The source directory is empty.'; return 1; }
  cntools_pool_file_name_into cold cold-skey; cntools_pool_file_name_into hws cold-hardware; cntools_pool_file_name_into vkey cold-vkey
  if [[ ( -e "${stage}/${cold}" && ( -e "${stage}/${cold}.gpg" || -e "${stage}/${hws}" ) ) ||
        ( -e "${stage}/${cold}.gpg" && -e "${stage}/${hws}" ) ]]; then
    cntools_pool_write_error 'Mixed cold signing material was not imported.'; return 1
  fi
  for role in cold kes vrf; do
    cntools_pool_key_pair_prepare "${stage}" "${role}" || { cntools_pool_write_error "Invalid or mismatched ${role} keys. The source was not changed."; return 1; }
  done
  if [[ -e "${stage}/${hws}" ]]; then
    cntools_pool_hardware_pair_validate "${stage}" || { cntools_pool_write_error 'The hardware cold reference does not match its public key or supported CIP-1853 path.'; return 1; }
  fi
  cntools_pool_public_records_prepare "${stage}" || { cntools_pool_write_error 'Pool identity/certificate artifacts are invalid or inconsistent. The source was not changed.'; return 1; }
  CNTOOLS_POOL_WRITE_WARNING='Imported counters and certificates were preserved, not refreshed or checked against the live chain. Missing operational artifacts were not regenerated.'
  cntools_pool_files_cleanup_temps
  cntools_pool_stage_publish "${stage}" "${name}"
}

cntools_pool_import_hardware() {
  local name="$1" index="$2" stage="" cold="" hws="" counter="" response="" errors="" status=0 path=""
  [[ "${index}" =~ ^[0-9]{1,10}$ ]] && ((10#${index} <= 2147483647)) || return 2
  path="1853H/1815H/0H/$((10#${index}))H"
  cntools_pool_write_environment "${name}" && cntools_wallet_hardware_require && cntools_wallet_hardware_device_check || {
    [[ -z "${CNTOOLS_WALLET_HARDWARE_ERROR:-}" ]] || cntools_pool_write_error "${CNTOOLS_WALLET_HARDWARE_ERROR}"; return 1;
  }
  cntools_pool_stage_into stage || return 1
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into hws cold-hardware; cntools_pool_file_name_into counter counter
  cntools_transaction_temp_file response pool-hardware-output; cntools_transaction_temp_file errors pool-hardware-errors
  cntools_run_command_timeout "${CNTOOLS_WALLET_HARDWARE_TIMEOUT}" 00000000000 -- "${CNTOOLS_WALLET_HARDWARE_BIN}" node key-gen \
    --path "${path}" --hw-signing-file "${stage}/${hws}" --cold-verification-key-file "${stage}/${cold}" \
    --operational-certificate-issue-counter-file "${stage}/${counter}" > "${response}" 2> "${errors}" || status=$?
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure 'Hardware pool import failed' "${status}" "${errors}" "${response}"
    cntools_pool_write_error "${CNTOOLS_TRANSACTION_ERROR}"; return 1
  fi
  if ! cntools_pool_hardware_pair_validate "${stage}" || ! cntools_pool_generate_runtime_keys "${stage}" ||
      ! cntools_pool_public_records_prepare "${stage}"; then
    cntools_pool_write_error 'Hardware pool artifacts failed complete validation.'; return 1
  fi
  CNTOOLS_POOL_WRITE_WARNING='New KES/VRF keys and a zero counter were prepared. For an existing on-chain pool, recover its real counter/VRF before registration or certificate issuance. No operational certificate was issued.'
  cntools_pool_files_cleanup_temps
  cntools_pool_stage_publish "${stage}" "${name}"
}
