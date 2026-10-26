#!/usr/bin/env bash
# Calidus key setup plus explicit, separately confirmed registration workflows.
# Sets CNTOOLS_CALIDUS_INSPECT_STATUS for the menu built after the render.
CNTOOLS_CALIDUS_INSPECT_STATUS=0
cntools_calidus_render() {
  local directory="$1" status=0
  cntools_calidus_inspect "${directory}" || status=$?
  CNTOOLS_CALIDUS_INSPECT_STATUS="${status}"
  {
    cntools_table_pair Pool "${directory##*/}" identifier
    if ((status == 0)); then
      cntools_table_pair 'Calidus key' "${CNTOOLS_CALIDUS_STATE}" value
      if [[ -n "${CNTOOLS_CALIDUS_ID}" ]]; then
        cntools_table_pair 'Calidus ID' "${CNTOOLS_CALIDUS_ID}" identifier
        cntools_table_pair 'Public key' "${CNTOOLS_CALIDUS_PUBLIC}" identifier
      fi
    else
      cntools_table_pair 'Calidus key' 'Needs attention' warning
    fi
  } | cntools_table_render Calidus
  if ((status != 0)); then
    cntools_ui_render_status error "${CNTOOLS_POOL_WRITE_ERROR:-Calidus inspection failed.} See ${CNTOOLS_LOG} for details."
  fi
}

# Only actions that can succeed for this key state and mode. Revocation never
# needs local Calidus material; on-chain actions need Koios.
cntools_calidus_menu_options_into() {
  local -n cmo_options="$1"
  local cmo_directory="$2" cmo_online=N cmo_key=N cmo_name='' cmo_missing=N cmo_cold=''
  local -a cmo_names=()
  [[ "${CNTOOLS_MODE:-offline}" == offline || "${CNTOOLS_KOIOS_ENABLED:-N}" != Y ]] || cmo_online=Y
  [[ "${CNTOOLS_CALIDUS_INSPECT_STATUS}" != 0 || "${CNTOOLS_CALIDUS_STATE}" == Missing ]] || cmo_key=Y
  cmo_options=()
  if [[ "${CNTOOLS_CALIDUS_INSPECT_STATUS}" == 0 ]]; then
    [[ "${cmo_online}" != Y ]] || cmo_options+=('Check on-chain status')
    if [[ "${cmo_key}" == Y ]]; then
      cmo_options+=('Prepare registration metadata')
      [[ "${cmo_online}" != Y ]] || cmo_options+=('Register / replace on-chain')
    fi
  fi
  cmo_options+=('Prepare revocation metadata')
  [[ "${cmo_online}" != Y ]] || cmo_options+=('Revoke on-chain')
  if [[ "${CNTOOLS_CALIDUS_INSPECT_STATUS}" == 0 && "${cmo_key}" != Y ]]; then
    # An encrypted pool takes no unencrypted Calidus signing key.
    cntools_pool_file_name_into cmo_cold cold-skey || cmo_cold=''
    [[ -n "${cmo_cold}" && ( -e "${cmo_directory}/${cmo_cold}.gpg" || -L "${cmo_directory}/${cmo_cold}.gpg" ) ]] ||
      cmo_options+=('Create CLI key' 'Import signing key')
    cmo_options+=('Import verification key (public only)')
  elif [[ "${cmo_key}" == Y ]] && cntools_calidus_names_into cmo_names; then
    for cmo_name in "${cmo_names[1]}" "${cmo_names[2]}"; do
      [[ -e "${cmo_directory}/${cmo_name}" || -L "${cmo_directory}/${cmo_name}" ]] || cmo_missing=Y
    done
    [[ "${cmo_missing}" != Y ]] || cmo_options+=('Repair missing public files')
  fi
  cmo_options+=(Back)
}

cntools_pool_action_calidus() {
  local selected='' directory='' choice='' kind='' source='' status=0
  local -a menu_options=()
  cntools_ui_action_begin Calidus '/ Pool / Calidus'
  cntools_pool_catalog_build || { cntools_ui_render_status error 'The pool directory could not be read safely.'; cntools_ui_wait; return 1; }
  (( ${#CNTOOLS_POOL_NAMES[@]} > 0 )) || { cntools_ui_render_status info 'No pools are available.'; cntools_ui_wait; return 0; }
  cntools_pool_choose_into selected || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  directory="${CNTOOLS_POOL_DIRECTORIES[selected]}"
  while true; do
    cntools_ui_action_begin Calidus '/ Pool / Calidus'
    cntools_calidus_render "${directory}"
    cntools_calidus_menu_options_into menu_options "${directory}"
    status=0
    cntools_ui_choose choice Calidus "${menu_options[@]}" || status=$?
    ((status != 1)) || return 0; ((status == 0)) || return "${status}"
    [[ "${choice}" != Back ]] || return 0
    case "${choice}" in
      'Check on-chain status') kind=status ;;
      'Prepare registration metadata') kind=metadata ;;
      'Register / replace on-chain') kind=register ;;
      'Prepare revocation metadata') kind=revoke-metadata ;;
      'Revoke on-chain') kind=revoke ;;
      *) kind='' ;;
    esac
    if [[ -n "${kind}" ]]; then
      status=0; cntools_calidus_registration_action "${selected}" "${kind}" || status=$?
      cntools_transaction_cleanup
      ((status != 130)) || return 130
      continue
    fi
    source=''
    case "${choice}" in
      'Create CLI key') kind=create ;;
      'Import signing key') kind=signing ;;
      'Import verification key (public only)') kind=verification ;;
      'Repair missing public files') kind=repair ;;
      *) return 2 ;;
    esac
    # Check before asking for a file: a pool that cannot take Calidus files
    # fails here, not after the path prompt.
    if ! cntools_calidus_preflight "${directory}" "${kind}"; then
      cntools_ui_render_status error "${CNTOOLS_POOL_WRITE_ERROR:-Cardano CLI is required.}"
      cntools_ui_wait; continue
    fi
    if [[ "${kind}" == signing || "${kind}" == verification ]]; then
      status=0
      cntools_ui_pick_path source 'Key file' 'Choose a Cardano payment key envelope; the source is retained.' "${directory}" || status=$?
      ((status != 1)) || continue; ((status == 0)) || return "${status}"
    fi
    {
      cntools_table_pair Pool "${directory##*/}" identifier
      cntools_table_pair Operation "${choice}" value
      [[ -z "${source}" ]] || cntools_table_pair Source "${source}" identifier
    } | cntools_table_render 'Calidus plan'
    if [[ "${kind}" == create || "${kind}" == signing ]]; then
      cntools_ui_render_status warn 'The Calidus signing key is stored unencrypted. Keep a secure offline backup. Use Pool → Encrypt to protect it together with any local cold signing key.'
    fi
    cntools_ui_render_status info 'Existing files are never overwritten. Cold, KES and VRF keys stay unchanged, and nothing is registered on-chain.'
    status=0; cntools_ui_flow_confirm 'Proceed with this Calidus key setup?' false || status=$?
    ((status != 1)) || continue; ((status == 0)) || return "${status}"
    cntools_transaction_log CHOICE "Calidus setup confirmed pool=${directory##*/} operation=${kind}"
    status=0
    cntools_ui_spin_function 'Preparing and validating Calidus identity…' cntools_calidus_prepare "${directory}" "${kind}" "${source}" || status=$?
    cntools_ui_action_begin Calidus '/ Pool / Calidus'
    if ((status == 0)); then
      cntools_calidus_render "${directory}"
      cntools_ui_render_status success 'Calidus key setup completed. Back up the signing key securely; no transaction was created.'
    else
      cntools_ui_render_status error "${CNTOOLS_POOL_WRITE_ERROR:-Calidus setup failed; existing files were retained.} See ${CNTOOLS_LOG} for details."
    fi
    cntools_ui_wait
    cntools_calidus_publication_cleanup
    cntools_pool_files_cleanup
    cntools_transaction_cleanup
  done
}
