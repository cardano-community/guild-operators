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
  local -
  set +x # Backup passphrases must never reach an xtrace log.
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
  elif [[ "${operation}" == Create ]]; then
    cntools_ui_render_status success 'Backup created; archive integrity verified.'
  elif (( CNTOOLS_BACKUP_IMPORTED == 0 )); then
    cntools_ui_render_status success 'Nothing was imported; existing folders were preserved.'
  else
    cntools_ui_render_status success 'Restore completed; existing folders were preserved.'
  fi
  if [[ "${operation}" == Create && -n "${CNTOOLS_BACKUP_RESULT}" ]]; then
    cntools_table_pair 'Backup file' "${CNTOOLS_BACKUP_RESULT}" identifier | cntools_table_render 'Result'
  elif [[ "${operation}" == Restore && ( "${status}" == 0 || -n "${CNTOOLS_BACKUP_RESULT}" ) ]]; then
    {
      cntools_table_pair 'Imported folders' "$(cntools_number_format "${CNTOOLS_BACKUP_IMPORTED}")" number
      cntools_table_pair 'Not imported' "$(cntools_number_format "${CNTOOLS_BACKUP_SKIPPED}")" number
      [[ -z "${CNTOOLS_BACKUP_RESULT}" ]] ||
        cntools_table_pair "Recovery copy $(cntools_backup_copy_label)" "${CNTOOLS_BACKUP_RESULT}" warning
    } | cntools_table_render 'Result'
  fi
  cntools_ui_wait
  (( status == 0 )) || return 1
}

# Why a destination cannot take a backup, or empty when it can. The default
# folder may be missing: it is created on Create when its parent is safe.
cntools_backup_destination_problem_into() {
  local _cntools_problem_destination="$2" _cntools_problem_default="${CNTOOLS_NODE_HOME}/backups" _cntools_problem=''
  if [[ "${_cntools_problem_destination}" == "${_cntools_problem_default}" &&
        ! -e "${_cntools_problem_destination}" && ! -L "${_cntools_problem_destination}" ]]; then
    cntools_backup_directory_safe "${CNTOOLS_NODE_HOME}" ||
      _cntools_problem="The default folder ${_cntools_problem_default} does not exist and cannot be created safely in ${CNTOOLS_NODE_HOME}. Choose another folder."
  elif [[ ! -d "${_cntools_problem_destination}" ]]; then
    _cntools_problem="${_cntools_problem_destination} is not an existing folder. Choose another folder."
  elif ! cntools_backup_directory_safe "${_cntools_problem_destination}"; then
    _cntools_problem="${_cntools_problem_destination} must be owned by you, writable and without group/public write access. Fix its permissions or choose another folder."
  fi
  printf -v "$1" '%s' "${_cntools_problem}"
}

cntools_backup_choose_folder_into() {
  local _cntools_folder_value='' _cntools_folder_default="${CNTOOLS_NODE_HOME}/backups"
  cntools_ui_pick_path _cntools_folder_value 'Backup directory' \
    "Choose an existing backup folder, or use the default: ${_cntools_folder_default}. Only the default folder is created automatically." \
    "${!1:-${_cntools_folder_default}}" directory 'Use default backup folder' "${_cntools_folder_default}" "${2:-}" || return $?
  _cntools_folder_value="${_cntools_folder_value:-${_cntools_folder_default}}"
  printf -v "$1" '%s' "${_cntools_folder_value%/}"
  cntools_log CHOICE "backup destination selected=${_cntools_folder_value%/}" || true
}

# The recommended protection comes first: GPG for a full backup, none for a
# public-only one (it holds no private keys).
cntools_backup_choose_protection_into() {
  local _cntools_protection_choice='' _cntools_protection_include="${3:-full}"
  local -a _cntools_protection_rows=('Encrypt with GPG (recommended)' 'Unencrypted archive')
  [[ "${_cntools_protection_include}" != public ]] ||
    _cntools_protection_rows=('Unencrypted archive (recommended for public files)' 'Encrypt with GPG')
  [[ -z "${2:-}" ]] || _cntools_protection_rows+=("$2")
  cntools_ui_choose _cntools_protection_choice 'Backup protection' "${_cntools_protection_rows[@]}" || return $?
  case "${_cntools_protection_choice}" in
    'Encrypt with GPG (recommended)'|'Encrypt with GPG') printf -v "$1" '%s' encrypted ;;
    'Unencrypted archive'|'Unencrypted archive (recommended for public files)') printf -v "$1" '%s' plain ;;
    *) return 1 ;;
  esac
  cntools_log CHOICE "backup protection selection=${!1}" || true
}

cntools_backup_choose_contents_into() {
  local _cntools_contents_choice=''
  local -a _cntools_contents_rows=('Full backup (includes private keys)' 'Public artifacts only')
  [[ -z "${2:-}" ]] || _cntools_contents_rows+=("$2")
  cntools_ui_choose _cntools_contents_choice 'Backup contents' "${_cntools_contents_rows[@]}" || return $?
  case "${_cntools_contents_choice}" in
    'Full backup (includes private keys)') printf -v "$1" '%s' full ;;
    'Public artifacts only') printf -v "$1" '%s' public ;;
    *) return 1 ;;
  esac
  cntools_log CHOICE "backup contents selection=${!1}" || true
}

# Skipped source paths worth naming for this backup kind: a public backup
# never takes nested or unknown files, so only folders and public files.
cntools_backup_excluded_into() {
  local -n _cntools_excluded_output="$1"
  local _cntools_excluded_include="$2" _cntools_excluded_path='' _cntools_excluded_relative=''
  _cntools_excluded_output=()
  for _cntools_excluded_path in "${CNTOOLS_BACKUP_EXCLUDED[@]}"; do
    if [[ "${_cntools_excluded_include}" == public ]]; then
      _cntools_excluded_relative="${_cntools_excluded_path#*/}"
      if [[ "${_cntools_excluded_path}" == */ ]]; then
        [[ "${_cntools_excluded_relative%/}" != */* ]] || continue
      else
        [[ "${_cntools_excluded_relative}" == */* && "${_cntools_excluded_relative}" != */*/* ]] || continue
        cntools_backup_public_file "${_cntools_excluded_path%%/*}" "${_cntools_excluded_relative}" || continue
      fi
    fi
    _cntools_excluded_output+=("${_cntools_excluded_path}")
  done
}

cntools_backup_create_review() {
  local include="$1" encryption="$2" destination="$3" gpg="$4" problem="$5" index=0 gaps=0 coverage='' skipped=''
  local -a excluded=()
  if [[ "${include}" == full ]]; then
    gaps=$(( ${#CNTOOLS_BACKUP_COVERAGE_LABELS[@]} - CNTOOLS_BACKUP_PRESENT_KEYS - CNTOOLS_BACKUP_HARDWARE_KEYS ))
    coverage="$(cntools_number_format "${CNTOOLS_BACKUP_PRESENT_KEYS}") signing key(s) included"
    (( CNTOOLS_BACKUP_HARDWARE_KEYS == 0 )) || coverage+=" · $(cntools_number_format "${CNTOOLS_BACKUP_HARDWARE_KEYS}") hardware-only"
    (( gaps == 0 )) || coverage+=" · $(cntools_number_format "${gaps}") not recoverable"
  fi
  {
    cntools_table_pair Contents "$([[ "${include}" == full ]] && printf 'Full · includes available private files' || printf 'Public artifacts only')" accent
    [[ -z "${coverage}" ]] || cntools_table_pair 'Key coverage' "${coverage}" "$( (( gaps == 0 )) && printf success || printf warning)"
    cntools_table_pair Protection "$([[ "${encryption}" == encrypted ]] && printf 'GPG · AES-256' || printf Unencrypted)" "$([[ "${encryption}" == encrypted ]] && printf success || printf warning)"
    cntools_table_pair Destination "${destination}" identifier
  } | cntools_table_render 'Backup'
  # Only the gaps: keys present in the archive need no row each.
  if (( gaps > 0 )); then
    {
      for ((index=0; index<${#CNTOOLS_BACKUP_COVERAGE_LABELS[@]}; index++)); do
        [[ "${CNTOOLS_BACKUP_COVERAGE_VALUES[index]}" != 'Signing key present'* &&
           "${CNTOOLS_BACKUP_COVERAGE_VALUES[index]}" != 'Hardware reference only'* ]] || continue
        cntools_table_pair "${CNTOOLS_BACKUP_COVERAGE_LABELS[index]}" "${CNTOOLS_BACKUP_COVERAGE_VALUES[index]}" warning
      done
    } | cntools_table_render 'Not recoverable from this backup'
  fi
  if [[ "${include}" == public ]]; then
    cntools_ui_render_status warn 'Only known public artifact filenames are included. Private keys, nested files and unknown custom files are omitted. This is not a recovery backup for signing keys.'
  else
    cntools_ui_render_status warn 'Hardware devices, their recovery seeds and encrypted-key passphrases are never in a backup; keep them separately.'
  fi
  [[ "${gpg}" == Y ]] ||
    cntools_ui_render_status warn 'GnuPG is not installed, so only an unencrypted archive can be created. Install GnuPG for an encrypted backup.'
  [[ "${include}" != full || "${encryption}" != plain ]] ||
    cntools_ui_render_status warn 'An unencrypted full backup exposes every private file it contains. Existing encrypted keys stay encrypted, but open signing keys do not.'
  cntools_backup_excluded_into excluded "${include}"
  if (( ${#excluded[@]} > 0 )); then
    # Names may contain spaces: join with commas.
    for ((index=0; index<${#excluded[@]} && index<5; index++)); do
      skipped+="${skipped:+, }${excluded[index]}"
    done
    (( ${#excluded[@]} <= 5 )) || skipped+=" and $(( ${#excluded[@]} - 5 )) more"
    cntools_ui_render_status warn "Skipped, the names cannot be archived safely: ${skipped}. Rename them with letters, digits, spaces and . _ - ~ + @ , = to include them."
  fi
  [[ -z "${problem}" ]] || cntools_ui_render_status error "${problem}"
}

cntools_backup_create_wizard() {
  local include='' encryption='' destination="${CNTOOLS_NODE_HOME}/backups" password='' status=0 gpg=N choice='' problem=''
  local protection_chosen=N previous=''
  local -a options=()
  cntools_backup_begin Create
  cntools_ui_render_status info 'Backs up wallet, pool and asset folders (incl. KES recovery data); not scripts, node files, settings or packages.'
  cntools_backup_interact cntools_backup_choose_contents_into include Cancel || return $?
  # Tools, folders and every path are checked before any other question.
  cntools_ui_spin_function 'Checking the folders to back up…' cntools_backup_inventory_check || status=$?
  if (( status == 3 )); then
    cntools_backup_begin Create
    cntools_ui_render_status info 'There are no wallet, pool or asset folders to back up yet.'
    cntools_ui_wait
    return 0
  elif (( status != 0 )); then
    cntools_backup_result Create "${status}"; return 1
  fi
  if [[ "${include}" == full ]]; then
    cntools_backup_recovery_coverage || { cntools_backup_error 'Could not inspect backup recovery coverage safely.'; cntools_backup_result Create 1; return 1; }
  fi
  { type -P gpg || type -P gpg2; } >/dev/null 2>&1 && gpg=Y
  if [[ "${gpg}" == N ]]; then
    # Offering GPG without GnuPG would only fail after the passphrase.
    encryption=plain
    cntools_log CHOICE 'backup protection default=plain gpg=missing' || true
  elif cntools_flow_quick; then
    # Public files need no passphrase; the review offers 'Change protection'.
    encryption=encrypted
    [[ "${include}" != public ]] || encryption=plain
    cntools_log CHOICE "backup protection default=${encryption} contents=${include} flow=quick" || true
  else
    cntools_backup_interact cntools_backup_choose_protection_into encryption Cancel "${include}" || return $?
    protection_chosen=Y
  fi
  # Quick writes to the default folder; the review menu offers another.
  if ! cntools_flow_quick; then
    cntools_backup_interact cntools_backup_choose_folder_into destination || return $?
  else
    cntools_log CHOICE "backup destination default=${destination} flow=quick" || true
  fi
  while true; do
    cntools_backup_destination_problem_into problem "${destination}"
    cntools_backup_begin Create
    cntools_backup_create_review "${include}" "${encryption}" "${destination}" "${gpg}" "${problem}"
    options=()
    [[ -n "${problem}" ]] || options+=('Create backup')
    options+=('Change contents')
    [[ "${gpg}" == N ]] || options+=('Change protection')
    options+=('Change folder' 'Cancel')
    cntools_backup_interact cntools_ui_choose choice 'Backup' "${options[@]}" || return $?
    cntools_log CHOICE "backup review choice=${choice}" || true
    status=0
    case "${choice}" in
      'Create backup') break ;;
      # Esc in a Change step keeps the current value; Ctrl+C cancels.
      'Change contents')
        previous="${include}"
        cntools_backup_choose_contents_into include || status=$?
        if (( status == 0 )) && [[ "${include}" != "${previous}" ]]; then
          if [[ "${include}" == full ]] && ! cntools_backup_recovery_coverage; then
            cntools_backup_error 'Could not inspect backup recovery coverage safely.'; cntools_backup_result Create 1; return 1
          fi
          # A default protection follows the contents; a chosen one stays.
          if [[ "${gpg}" == Y && "${protection_chosen}" == N ]]; then
            encryption=encrypted; [[ "${include}" != public ]] || encryption=plain
          fi
        fi ;;
      'Change protection')
        cntools_backup_choose_protection_into encryption '' "${include}" || status=$?
        (( status != 0 )) || protection_chosen=Y ;;
      'Change folder') cntools_backup_choose_folder_into destination "${problem}" || status=$? ;;
      *) CNTOOLS_BACKUP_CANCELLED=Y; return 0 ;;
    esac
    (( status != 130 )) || { CNTOOLS_BACKUP_CANCELLED=Y; return 130; }
  done
  # Create only the advertised default, never an arbitrary recursive path.
  if [[ "${destination}" == "${CNTOOLS_NODE_HOME}/backups" && ! -e "${destination}" && ! -L "${destination}" ]]; then
    mkdir -m 0700 -- "${destination}" || {
      cntools_backup_error "The default backup folder ${destination} could not be created."; cntools_backup_result Create 1; return 1;
    }
  fi
  if [[ "${encryption}" == encrypted ]]; then
    cntools_backup_begin Create
    cntools_ui_render_status info "Encrypting the backup for ${destination}."
    cntools_ui_render_status warn 'Keep the backup passphrase safe. It cannot be recovered. Use at least 12 characters.'
    cntools_backup_interact cntools_backup_password_into password encrypt || return $?
  fi
  cntools_log CHOICE "backup contents=${include} protection=${encryption} destination=${destination}" || true
  cntools_ui_spin_function 'Creating and verifying backup…' cntools_backup_create "${destination}" "${include}" "${encryption}" "${password}" || status=$?
  unset password
  cntools_backup_result Create "${status}"
}

# How the recovery copy is labelled: it is never encrypted.
cntools_backup_copy_label() {
  if [[ "${CNTOOLS_BACKUP_KIND}" == public ]]; then printf '(unencrypted)'
  else printf '(unencrypted, contains private keys)'; fi
}

cntools_backup_restore_preview() {
  local object='' decision='' role='' contents='' created="${CNTOOLS_BACKUP_CREATED}"
  case "${CNTOOLS_BACKUP_KIND}" in
    full) contents='Full · includes private files' ;;
    public) contents='Public artifacts only' ;;
    *) contents='Legacy archive' ;;
  esac
  [[ -z "${created}" ]] || { created="${created/T/ }"; created="${created:0:16} UTC"; }
  cntools_backup_restore_plan || return 1
  {
    cntools_table_pair 'Backup contents' "${contents}" "$([[ "${CNTOOLS_BACKUP_KIND}" == legacy ]] && printf warning || printf accent)"
    [[ "${CNTOOLS_BACKUP_NETWORK}" == unknown ]] ||
      cntools_table_pair Network "${CNTOOLS_BACKUP_NETWORK}" "$([[ "${CNTOOLS_BACKUP_NETWORK}" == "${CNTOOLS_NETWORK}" ]] && printf value || printf warning)"
    [[ -z "${created}" ]] || cntools_table_pair Created "${created}" value
    for object in "${CNTOOLS_BACKUP_OBJECTS[@]}"; do
      role=warning
      case "${CNTOOLS_BACKUP_DECISIONS[${object}]}" in
        import) decision=Import; role=success ;;
        preserve) decision='Exists here · not changed' ;;
        *) decision='KES/recovery data · not activated' ;;
      esac
      cntools_table_pair "${object}" "${decision}" "${role}"
    done
  } | cntools_table_render 'Restore preview'
}

cntools_backup_restore_wizard() {
  local source='' password='' status=0 feedback='' keep_copy=N choice='' import_label='' copy_label=''
  cntools_backup_begin Restore
  cntools_ui_render_status info 'Restore adds only missing wallet, pool and asset folders and never overwrites existing ones.'
  cntools_backup_interact cntools_ui_pick_path source 'Backup file (.tar.gz or .tar.gz.gpg)' \
    'Choose a trusted backup archive. Its contents and integrity are checked before restore.' "${CNTOOLS_NODE_HOME}/backups" || return $?
  [[ -n "${source}" ]] || return 0
  cntools_log CHOICE "backup restore selected file=${source}" || true
  # Check GnuPG before asking for a passphrase it could not use.
  if [[ "${source}" == *.gpg ]] && ! { type -P gpg || type -P gpg2; } >/dev/null 2>&1; then
    cntools_backup_error 'Install GnuPG to open this encrypted backup.'; cntools_backup_result Restore 1; return 1
  fi
  while true; do
    if [[ "${source}" == *.gpg ]]; then
      cntools_backup_begin Restore
      cntools_ui_render_status info "Decrypting ${source##*/}."
      [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
      cntools_backup_interact cntools_backup_password_into password decrypt || return $?
    fi
    status=0
    cntools_ui_spin_function 'Opening and validating backup…' cntools_backup_restore_prepare "${source}" "${password}" || status=$?
    unset password
    # A wrong passphrase is retried; Esc at the prompt cancels.
    [[ "${status}" != 0 && "${CNTOOLS_BACKUP_DECRYPT_FAILED}" == Y ]] || break
    feedback="${CNTOOLS_BACKUP_ERROR}"
  done
  if (( status != 0 )); then cntools_backup_result Restore "${status}"; return 1; fi
  cntools_backup_begin Restore
  cntools_backup_restore_preview || return 1
  [[ "${CNTOOLS_BACKUP_KIND}" != legacy ]] || cntools_ui_render_status warn 'Legacy archive: no CNTools checksum manifest is available. Encrypted archives must still pass GPG verification.'
  [[ "${CNTOOLS_BACKUP_NETWORK}" == unknown || "${CNTOOLS_BACKUP_NETWORK}" == "${CNTOOLS_NETWORK}" ]] || cntools_ui_render_status warn 'This backup was created for a different network. Restoring files does not convert their addresses or registration state.'
  if (( CNTOOLS_BACKUP_IMPORTABLE > 0 )); then
    if [[ " ${CNTOOLS_BACKUP_OBJECTS[*]} " == *' pools/'* || " ${CNTOOLS_BACKUP_OBJECTS[*]} " == *' recovery/'* ]]; then
      cntools_ui_render_status warn 'For pools, do not start a node using old operational files or counters. Verify the current issuance counter and complete a fresh KES rotation first. Immutable flags are not restored; imported files have owner-only access.'
    else
      cntools_ui_render_status info 'Immutable flags are not restored; imported files have owner-only access.'
    fi
  fi
  copy_label="$(cntools_backup_copy_label)"
  import_label="Import $(cntools_number_format "${CNTOOLS_BACKUP_IMPORTABLE}") folder$( (( CNTOOLS_BACKUP_IMPORTABLE == 1 )) || printf s)"
  if (( CNTOOLS_BACKUP_IMPORTABLE == 0 )); then
    # Nothing to import: only an explicit Yes writes a copy (default No).
    cntools_ui_render_status info 'Nothing to import: every folder in this backup already exists here or is recovery-only data.'
    cntools_backup_interact cntools_ui_confirm "Keep a recovery copy of the $(cntools_number_format "${CNTOOLS_BACKUP_SKIPPABLE}") skipped folder$( (( CNTOOLS_BACKUP_SKIPPABLE == 1 )) || printf s) ${copy_label} in ${CNTOOLS_NODE_HOME}/backups?" false || return $?
    keep_copy=Y
  elif (( CNTOOLS_BACKUP_SKIPPABLE == 0 )); then
    cntools_backup_interact cntools_ui_confirm "${import_label}?" false || return $?
  else
    cntools_backup_interact cntools_ui_choose choice 'Restore' "${import_label}" \
      "${import_label} and keep a recovery copy of the other $(cntools_number_format "${CNTOOLS_BACKUP_SKIPPABLE}") ${copy_label}" Cancel || return $?
    case "${choice}" in
      "${import_label}") ;;
      Cancel) CNTOOLS_BACKUP_CANCELLED=Y; return 0 ;;
      *) keep_copy=Y ;;
    esac
  fi
  cntools_log CHOICE "backup restore confirmed import=${CNTOOLS_BACKUP_IMPORTABLE} keep_copy=${keep_copy}; existing folders preserved" || true
  status=0
  cntools_ui_spin_function "$( (( CNTOOLS_BACKUP_IMPORTABLE > 0 )) && printf 'Restoring missing folders…' || printf 'Writing the recovery copy…')" \
    cntools_backup_restore_apply "${keep_copy}" || status=$?
  cntools_backup_result Restore "${status}"
}
