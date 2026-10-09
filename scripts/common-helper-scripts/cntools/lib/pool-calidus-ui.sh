#!/usr/bin/env bash
# Calidus key setup plus explicit, separately confirmed registration workflows.
cntools_calidus_render() {
  local directory="$1" status=0
  cntools_calidus_inspect "${directory}" || status=$?
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
    cntools_table_pair 'On-chain registration' 'Use Check on-chain status · Koios API' muted
  } | cntools_table_render Calidus
  if ((status != 0)); then
    cntools_ui_render_status error "${CNTOOLS_POOL_WRITE_ERROR:-Calidus inspection failed.} See ${CNTOOLS_LOG} for details."
  fi
}

cntools_pool_action_calidus() {
  local selected='' directory='' choice='' kind='' source='' status=0
  cntools_ui_action_begin Calidus '/ Pool / Calidus'
  cntools_pool_catalog_build || { cntools_ui_render_status error 'The pool directory could not be read safely.'; cntools_ui_wait; return 1; }
  (( ${#CNTOOLS_POOL_NAMES[@]} > 0 )) || { cntools_ui_render_status info 'No pools are available.'; cntools_ui_wait; return 0; }
  cntools_pool_choose_into selected || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  directory="${CNTOOLS_POOL_DIRECTORIES[selected]}"
  while true; do
    cntools_ui_action_begin Calidus '/ Pool / Calidus'
    cntools_calidus_render "${directory}"
    status=0
    cntools_ui_choose choice Calidus 'Info & Status' 'Check on-chain status' 'Prepare registration metadata' \
      'Register / replace on-chain' 'Prepare revocation metadata' 'Revoke on-chain' \
      'Create CLI key' 'Import signing key' 'Import verification key (public only)' 'Repair missing public files' Back || status=$?
    ((status != 1)) || return 0; ((status == 0)) || return "${status}"
    [[ "${choice}" != Back ]] || return 0
    if [[ "${choice}" == 'Info & Status' ]]; then cntools_ui_wait; continue; fi
    case "${choice}" in
      'Check on-chain status') kind=status ;;
      'Prepare registration metadata') kind=metadata ;;
      'Register / replace on-chain') kind=register ;;
      'Prepare revocation metadata') kind=revoke-metadata ;;
      'Revoke on-chain') kind=revoke ;;
      *) kind='' ;;
    esac
    if [[ -n "${kind}" ]]; then
      cntools_calidus_registration_action "${selected}" "${kind}" || true
      cntools_transaction_cleanup
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
    if [[ "${kind}" == signing || "${kind}" == verification ]]; then
      status=0
      cntools_ui_input source 'Key file' 'Absolute path to a Cardano payment key envelope; source is retained' || status=$?
      ((status != 1)) || continue; ((status == 0)) || return "${status}"
    fi
    if ! cntools_calidus_preflight "${directory}" "${kind}"; then
      cntools_ui_render_status error "${CNTOOLS_POOL_WRITE_ERROR:-Cardano CLI is required.}"
      cntools_ui_wait; continue
    fi
    {
      cntools_table_pair Pool "${directory##*/}" identifier
      cntools_table_pair Operation "${choice}" value
      [[ -z "${source}" ]] || cntools_table_pair Source "${source}" identifier
      cntools_table_pair 'Existing files' 'Never overwritten' muted
    } | cntools_table_render 'Calidus plan'
    if [[ "${kind}" == create || "${kind}" == signing ]]; then
      cntools_ui_render_status warn 'The Calidus signing key is stored unencrypted. Keep a secure offline backup. Use Pool → Encrypt to protect it together with any local cold signing key.'
    fi
    cntools_ui_render_status info 'Cold, KES and VRF keys stay unchanged. This does not register or replace the Calidus key on-chain.'
    status=0; cntools_ui_confirm 'Proceed with this Calidus key setup?' false || status=$?
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
