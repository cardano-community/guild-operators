#!/usr/bin/env bash
# Compact, shared-table backup wizard. Works without a node or Cardano CLI.
# shellcheck disable=SC2034

cntools_backup_begin() {
  cntools_ui_action_begin "$1" "/ Backup / $1"
}

cntools_backup_interact() {
  local interaction_status=0
  "$@" || interaction_status=$?
  if (( interaction_status == 1 || interaction_status == 130 )); then
    CNTOOLS_BACKUP_CANCELLED=Y
    cntools_log CHOICE 'backup wizard cancelled or declined' || true
  fi
  return "${interaction_status}"
}

cntools_backup_action_run() {
  local operation="$1" action_status=0
  CNTOOLS_BACKUP_CANCELLED=N
  CNTOOLS_BACKUP_ERROR=''; CNTOOLS_BACKUP_RESULT=''
  "cntools_backup_${operation,,}_wizard" || action_status=$?
  if [[ "${CNTOOLS_BACKUP_CANCELLED}" == Y ]]; then return 0; fi
  return "${action_status}"
}

cntools_backup_action_create() { cntools_backup_action_run Create; }
cntools_backup_action_restore() { cntools_backup_action_run Restore; }

cntools_backup_password_into() {
  local -n password_output="$1"
  local operation="$2" first='' second='' feedback=''
  password_output=''
  while true; do
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    cntools_ui_password first "$([[ "${operation}" == encrypt ]] && printf 'New backup passphrase' || printf 'Backup passphrase')" || return $?
    [[ -n "${first}" && "${first}" != *$'\n'* && "${first}" != *$'\r'* ]] || { feedback='Enter a nonempty, single-line passphrase.'; continue; }
    if [[ "${operation}" == encrypt ]]; then
      (( ${#first} >= 12 )) || { feedback='New backup passphrases require at least 12 characters.'; continue; }
      cntools_ui_password second 'Confirm backup passphrase' || return $?
      [[ "${first}" == "${second}" ]] || { feedback='The passphrases did not match.'; unset first second; continue; }
    fi
    password_output="${first}"
    unset first second
    return 0
  done
}

cntools_backup_result() {
  local operation="$1" status="$2"
  cntools_backup_begin "${operation}"
  if (( status != 0 )); then
    [[ -n "${CNTOOLS_BACKUP_ERROR}" ]] || cntools_backup_error "Backup ${operation,,} failed (status ${status}). See ${CNTOOLS_LOG:-the CNTools log}."
    cntools_ui_render_status error "${CNTOOLS_BACKUP_ERROR}"
  else
    cntools_ui_render_status success "$([[ "${operation}" == Create ]] && printf 'Backup created; archive integrity verified.' || printf 'Restore completed; existing folders were preserved.')"
  fi
  if [[ -n "${CNTOOLS_BACKUP_RESULT}" ]]; then
    {
      cntools_table_pair "$([[ "${operation}" == Create ]] && printf 'Backup file' || printf 'Recovery copy')" "${CNTOOLS_BACKUP_RESULT}" identifier
      if [[ "${operation}" == Restore ]]; then
        cntools_table_pair 'Imported folders' "$(cntools_number_format "${CNTOOLS_BACKUP_IMPORTED}")" number
        cntools_table_pair 'Preserved / recovery only' "$(cntools_number_format "${CNTOOLS_BACKUP_SKIPPED}")" number
      fi
    } | cntools_table_render 'Result'
  fi
  cntools_ui_wait
  return "${status}"
}

cntools_backup_create_wizard() {
  local include='' encryption='' destination='' password='' status=0
  cntools_backup_begin Create
  cntools_ui_render_status info 'Back up wallet, pool and asset folders, including pool operational files and KES recovery data. Scripts, node configuration/database, settings and transaction packages are not included. Pause other wallet/pool operations while backing up.'
  cntools_backup_interact cntools_ui_choose include 'Backup contents' 'Full backup (includes private keys)' 'Public artifacts only' 'Cancel' || return $?
  cntools_log CHOICE "backup contents selection=${include}" || true
  case "${include}" in 'Full backup (includes private keys)') include=full ;; 'Public artifacts only') include=public ;; *) return 0 ;; esac
  if [[ "${include}" == public ]]; then
    cntools_ui_render_status warn 'Only known public artifact filenames are included. Private keys, nested files and unknown custom files are omitted. This is not a recovery backup for signing keys.'
  else
    cntools_backup_recovery_coverage || { cntools_backup_error 'Could not inspect backup recovery coverage safely.'; cntools_backup_result Create 1; return 1; }
    if (( ${#CNTOOLS_BACKUP_COVERAGE_LABELS[@]} > 0 )); then
      local coverage_index=0
      {
        for ((coverage_index=0; coverage_index<${#CNTOOLS_BACKUP_COVERAGE_LABELS[@]}; coverage_index++)); do
          cntools_table_pair "${CNTOOLS_BACKUP_COVERAGE_LABELS[coverage_index]}" "${CNTOOLS_BACKUP_COVERAGE_VALUES[coverage_index]}" \
            "$([[ "${CNTOOLS_BACKUP_COVERAGE_VALUES[coverage_index]}" == 'Signing key present'* ]] && printf success || printf warning)"
        done
      } | cntools_table_render 'Signing-key recovery coverage'
    fi
    cntools_ui_render_status warn 'A full backup contains only files that are present. Missing/external keys, hardware devices and their recovery seeds are not recovered by archive verification. Keep encrypted-key passphrases separately.'
  fi
  cntools_backup_interact cntools_ui_choose encryption 'Backup protection' 'Encrypt with GPG (recommended)' 'Unencrypted archive' 'Cancel' || return $?
  cntools_log CHOICE "backup protection selection=${encryption}" || true
  case "${encryption}" in
    'Encrypt with GPG (recommended)') encryption=encrypted ;;
    'Unencrypted archive') encryption=plain
      if [[ "${include}" == full ]]; then
        cntools_ui_render_status warn 'An unencrypted full backup exposes every private file it contains. Existing encrypted keys stay encrypted, but open signing keys do not.'
        cntools_backup_interact cntools_ui_confirm 'Create an unencrypted full backup anyway?' false || return $?
      fi ;;
    *) return 0 ;;
  esac
  destination="${CNTOOLS_NODE_HOME}/backups"
  cntools_backup_interact cntools_ui_input destination 'Existing backup directory (Enter for default)' "${destination}" || return $?
  destination="${destination:-${CNTOOLS_NODE_HOME}/backups}"; destination="${destination%/}"
  # Create only the advertised default, never an arbitrary recursive path.
  if [[ "${destination}" == "${CNTOOLS_NODE_HOME}/backups" && ! -e "${destination}" && ! -L "${destination}" ]]; then
    cntools_backup_directory_safe "${CNTOOLS_NODE_HOME}" && mkdir -m 0700 -- "${destination}" || return 1
  fi
  cntools_backup_directory_safe "${destination}" || { cntools_backup_error 'Choose an existing owned, writable directory without group/public write access.'; cntools_backup_result Create 1; return 1; }
  {
    cntools_table_pair Contents "$([[ "${include}" == full ]] && printf 'Full · includes available private files' || printf 'Public artifacts only')" accent
    cntools_table_pair Protection "$([[ "${encryption}" == encrypted ]] && printf 'GPG · AES-256' || printf Unencrypted)" "$([[ "${encryption}" == encrypted ]] && printf success || printf warning)"
    cntools_table_pair Destination "${destination}" identifier
  } | cntools_table_render 'Backup'
  cntools_backup_interact cntools_ui_confirm 'Create this backup?' false || return $?
  if [[ "${encryption}" == encrypted ]]; then
    cntools_ui_render_status warn 'Keep the backup passphrase safe. It cannot be recovered. Use at least 12 characters.'
    cntools_backup_interact cntools_backup_password_into password encrypt || return $?
  fi
  cntools_log CHOICE "backup contents=${include} protection=${encryption} destination=${destination}" || true
  cntools_ui_spin_function 'Creating and verifying backup…' cntools_backup_create "${destination}" "${include}" "${encryption}" "${password}" || status=$?
  unset password
  cntools_backup_result Create "${status}"
}

cntools_backup_restore_preview() {
  local object='' root='' name='' decision=''
  {
    cntools_table_pair 'Backup contents' "${CNTOOLS_BACKUP_KIND}" accent
    cntools_table_pair 'Backup network' "${CNTOOLS_BACKUP_NETWORK}" accent
    for object in "${CNTOOLS_BACKUP_OBJECTS[@]}"; do
      cntools_backup_role_root_into root "${object%%/*}" || return 1
      name="${object#*/}"; decision=Import
      if [[ "${name}" == .* || -e "${CNTOOLS_BACKUP_WORK}/restore/${object}/.cntools-opcert-lock" ]]; then
        decision='Recovery copy only · KES/unfinished data'
      elif [[ -e "${root}/${name}" || -L "${root}/${name}" ]]; then
        decision='Preserve existing folder · recovery copy only'
      fi
      cntools_table_pair "${object}" "${decision}" "$([[ "${decision}" == Import ]] && printf success || printf warning)"
    done
  } | cntools_table_render 'Restore preview'
}

cntools_backup_restore_wizard() {
  local source='' password='' status=0
  cntools_backup_begin Restore
  cntools_ui_render_status info 'Restore imports only missing wallet, pool and asset folders. A complete, decrypted owner-private recovery copy is kept separately; existing .gpg keys stay encrypted. Existing folders are never merged or overwritten. Use only a backup you trust.'
  cntools_backup_interact cntools_ui_input source 'Backup file (.tar.gz or .tar.gz.gpg)' || return $?
  [[ -n "${source}" ]] || return 0
  cntools_log CHOICE "backup restore selected file=${source}" || true
  if [[ "${source}" == *.gpg ]]; then cntools_backup_interact cntools_backup_password_into password decrypt || return $?; fi
  cntools_ui_spin_function 'Opening and validating backup…' cntools_backup_restore_prepare "${source}" "${password}" || status=$?
  unset password
  if (( status != 0 )); then cntools_backup_result Restore "${status}"; return "${status}"; fi
  cntools_backup_begin Restore
  cntools_backup_restore_preview || return 1
  [[ "${CNTOOLS_BACKUP_KIND}" != legacy ]] || cntools_ui_render_status warn 'Legacy archive: no CNTools checksum manifest is available. Encrypted archives must still pass GPG verification.'
  [[ "${CNTOOLS_BACKUP_NETWORK}" == unknown || "${CNTOOLS_BACKUP_NETWORK}" == "${CNTOOLS_NETWORK}" ]] || cntools_ui_render_status warn 'This backup was created for a different network. Restoring files does not convert their addresses or registration state.'
  cntools_ui_render_status warn 'For pools, do not start a node using old operational files or counters. Verify the current issuance counter and complete a fresh KES rotation first. Immutable flags are not restored; imported files have owner-only access.'
  cntools_backup_interact cntools_ui_confirm 'Keep a recovery copy and import the missing folders?' false || return $?
  cntools_log CHOICE 'backup restore confirmed; existing folders preserved' || true
  status=0
  cntools_ui_spin_function 'Restoring missing folders…' cntools_backup_restore_apply || status=$?
  cntools_backup_result Restore "${status}"
}
