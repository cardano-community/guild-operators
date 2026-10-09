#!/usr/bin/env bash
# Consistent pool plans/results using the same tables and choices as wallet actions.
cntools_pool_manage_result() {
  local title="$1"
  if [[ -n "${CNTOOLS_POOL_WRITE_ERROR}" ]]; then
    cntools_ui_render_status error "${CNTOOLS_POOL_WRITE_ERROR} See ${CNTOOLS_LOG} for details."
  else
    {
      cntools_table_pair Pool "${CNTOOLS_POOL_WRITTEN_DIRECTORY##*/}" identifier
      cntools_table_pair 'Pool ID' "${CNTOOLS_POOL_WRITTEN_ID}" identifier
      cntools_table_pair Directory "${CNTOOLS_POOL_WRITTEN_DIRECTORY}" identifier
      cntools_table_pair Result "${title}" success
    } | cntools_table_render Pool
    cntools_ui_render_status info 'Back up the pool keys securely. No registration transaction or operational certificate was created.'
  fi
  [[ -z "${CNTOOLS_POOL_WRITE_WARNING}" ]] || cntools_ui_render_status warn "${CNTOOLS_POOL_WRITE_WARNING}"
  cntools_ui_wait
}

cntools_pool_manage_name_into() {
  local output="$1" title="$2" entered="" target=""
  while true; do
    cntools_ui_input entered 'Pool name' 'Letters, numbers, dots, underscores and hyphens (1–64)' || return $?
    if cntools_pool_target_into target "${entered}" && [[ ! -e "${target}" && ! -L "${target}" ]]; then
      printf -v "${output}" '%s' "${entered}"
      cntools_transaction_log CHOICE "Pool ${title} name=${entered}"
      return 0
    fi
    cntools_ui_render_status warn 'Use a valid name that is not already used by another pool.'
  done
}

cntools_pool_action_new() {
  local name="" status=0 target=""
  cntools_ui_action_begin New '/ Pool / New'
  cntools_pool_manage_name_into name create || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  cntools_pool_target_into target "${name}" || return 1
  cntools_ui_action_begin New '/ Pool / New'
  {
    cntools_table_pair Name "${name}" identifier
    cntools_table_pair Directory "${target}" identifier
    cntools_table_pair 'Cold identity' 'New CLI signing and verification keys' value
    cntools_table_pair 'Node keys' 'New KES and VRF key pairs' value
    cntools_table_pair Counter 'New issue counter (0)' number
  } | cntools_table_render 'Create pool'
  cntools_ui_render_status info 'This prepares keys only. Registration and a KES start period/certificate are separate steps.'
  status=0; cntools_ui_confirm 'Create this pool?' false || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  cntools_transaction_log CHOICE "Pool creation confirmed name=${name}"
  status=0
  cntools_ui_spin_function 'Creating and validating pool keys…' cntools_pool_create "${name}" || status=$?
  if (( status != 0 )) && [[ -z "${CNTOOLS_POOL_WRITE_ERROR}" ]]; then cntools_pool_write_error 'Pool creation failed; no incomplete pool was published.' || true; fi
  cntools_ui_action_begin New '/ Pool / New'
  cntools_pool_manage_result Created
  return "${status}"
}

cntools_pool_action_import() {
  local name="" choice="" source="" index="" status=0 target=""
  cntools_ui_action_begin Import '/ Pool / Import'
  cntools_ui_choose choice 'Import source' 'Existing pool directory' 'Hardware cold key' Cancel || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  [[ "${choice}" != Cancel ]] || return 0
  cntools_pool_manage_name_into name import || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  case "${choice}" in
    'Existing pool directory')
      cntools_ui_input source 'Source pool directory' 'Absolute path; the source is copied, never modified' || status=$?
      ((status != 1)) || return 0; ((status == 0)) || return "${status}" ;;
    'Hardware cold key')
      while true; do
        cntools_ui_input index 'Cold key index (default: 0)' '0' || status=$?
        ((status != 1)) || return 0; ((status == 0)) || return "${status}"
        [[ -n "${index}" ]] || index=0
        [[ "${index}" =~ ^[0-9]{1,10}$ ]] && ((10#${index} <= 2147483647)) && break
        cntools_ui_render_status warn 'Use a whole number from 0 to 2,147,483,647.'
      done
      source="1853H/1815H/0H/$((10#${index}))H"
      ;;
    *) return 2 ;;
  esac
  cntools_pool_target_into target "${name}" || return 1
  cntools_ui_action_begin Import '/ Pool / Import'
  {
    cntools_table_pair Name "${name}" identifier
    cntools_table_pair Source "${source}" identifier
    cntools_table_pair Destination "${target}" identifier
    cntools_table_pair Method "${choice}" value
  } | cntools_table_render 'Import pool'
  if [[ "${choice}" == 'Hardware cold key' ]]; then
    cntools_ui_render_status warn 'Connect and unlock the hardware device and open its Cardano app. Only the cold public identity/reference is exported. New KES/VRF keys and a zero counter will be created; existing pools need their original VRF/counter recovered before use.'
  else
    cntools_ui_render_status info 'Only regular top-level files are accepted. Existing keys, counters and certificates are preserved; mismatched identities are rejected.'
  fi
  status=0; cntools_ui_confirm 'Import this pool without overwriting any existing pool?' false || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  cntools_transaction_log CHOICE "Pool import confirmed name=${name} method=${choice}"
  status=0
  if [[ "${choice}" == 'Hardware cold key' ]]; then
    cntools_ui_spin_function 'Exporting cold identity and preparing node keys…' cntools_pool_import_hardware "${name}" "${index}" || status=$?
  else
    cntools_ui_spin_function 'Copying and validating pool artifacts…' cntools_pool_import_directory "${name}" "${source}" || status=$?
  fi
  if ((status != 0)) && [[ -z "${CNTOOLS_POOL_WRITE_ERROR}" ]]; then cntools_pool_write_error 'Pool import failed; the source was retained and no incomplete pool was published.' || true; fi
  cntools_ui_action_begin Import '/ Pool / Import'
  cntools_pool_manage_result Imported
  return "${status}"
}

cntools_pool_action_protection() {
  local operation="$1" title="" selected="" directory="" cold="" calidus="" calidus_state="" source="" calidus_source="" password="" confirmation="" status=0
  [[ "${operation}" != encrypt ]] && title=Decrypt || title=Encrypt
  cntools_ui_action_begin "${title}" "/ Pool / ${title}"
  cntools_pool_catalog_build || { cntools_ui_render_status error 'The pool directory could not be read safely.'; cntools_ui_wait; return 1; }
  (( ${#CNTOOLS_POOL_NAMES[@]} > 0 )) || { cntools_ui_render_status info 'No pools are available.'; cntools_ui_wait; return 0; }
  cntools_pool_choose_into selected || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  directory="${CNTOOLS_POOL_DIRECTORIES[selected]}"
  cntools_pool_file_name_into cold cold-skey
  cntools_pool_file_name_into calidus calidus-skey
  source="${directory}/${cold}"
  calidus_source="${directory}/${calidus}"
  [[ "${operation}" != decrypt ]] || { source+='.gpg'; calidus_source+='.gpg'; }
  cntools_pool_key_state_into calidus_state "${directory}" calidus-skey || return 1
  {
    cntools_table_pair Pool "${CNTOOLS_POOL_NAMES[selected]}" identifier
    cntools_table_pair 'Cold key' "${CNTOOLS_POOL_PROTECTIONS[selected]}" value
    [[ "${calidus_state}" == Missing ]] || cntools_table_pair 'Calidus key' "${calidus_state}" value
    if [[ "${operation}" == encrypt ]]; then
      cntools_table_pair Result 'Cold and Calidus signing keys encrypted when present; pool files locked' value
    else
      cntools_table_pair Result 'Cold and Calidus signing keys decrypted when present; pool files unlocked' value
    fi
    cntools_table_pair 'Node keys' 'KES and VRF keys remain readable by the node' muted
  } | cntools_table_render "${title} pool"
  cntools_ui_render_status warn 'Keep offline backups. Password loss cannot be recovered. Both signing keys use the same password; decryption opens all protected keys together.'
  status=0; cntools_ui_confirm "${title} this pool?" false || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  if [[ ( -f "${source}" && ! -L "${source}" ) || ( -f "${calidus_source}" && ! -L "${calidus_source}" ) ]]; then
    while true; do
      cntools_ui_password password 'Pool signing-key password' || {
        status=$?; unset password; ((status != 1)) || return 0; return "${status}";
      }
      if [[ -z "${password}" || "${password}" == *$'\n'* || "${password}" == *$'\r'* ]] ||
          { [[ "${operation}" == encrypt ]] && (( ${#password} < 12 )); }; then
        cntools_ui_render_status warn 'New encryption passwords need at least 12 characters; decryption accepts shorter legacy passwords. No line breaks.'
        unset password; continue
      fi
      if [[ "${operation}" == encrypt ]]; then
        cntools_ui_password confirmation 'Confirm pool signing-key password' || {
          status=$?; unset password confirmation; ((status != 1)) || return 0; return "${status}";
        }
        if [[ "${password}" != "${confirmation}" ]]; then
          cntools_ui_render_status warn 'Passwords did not match. Try again.'; unset password confirmation; continue
        fi
      fi
      break
    done
  fi
  cntools_transaction_log CHOICE "Pool protection confirmed pool=${directory##*/} operation=${operation}"
  status=0
  cntools_ui_spin_function "${title}ing pool signing keys and file protection…" cntools_pool_protect "${directory}" "${operation}" "${password:-}" || status=$?
  unset password confirmation
  cntools_ui_action_begin "${title}" "/ Pool / ${title}"
  if ((status == 0)); then
    { cntools_table_pair Pool "${directory##*/}" identifier; cntools_table_pair Result "${title} completed" success;
      cntools_table_pair 'Signing keys processed' "$(cntools_number_format "${CNTOOLS_POOL_PROTECTION_KEYS}")" number;
      [[ "${operation}" != encrypt ]] || cntools_table_pair Protection "${CNTOOLS_POOL_LOCK_METHOD}" value;
    } | cntools_table_render Pool
  else
    cntools_ui_render_status error "${CNTOOLS_POOL_WRITE_ERROR:-Pool protection failed.} See ${CNTOOLS_LOG}."
  fi
  [[ -z "${CNTOOLS_POOL_WRITE_WARNING}" ]] || cntools_ui_render_status warn "${CNTOOLS_POOL_WRITE_WARNING}"
  cntools_ui_wait
  return "${status}"
}
