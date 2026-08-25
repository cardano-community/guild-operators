#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Stage 4 compatibility action for encrypting and locking one asset policy.
# The selected policy is completely validated before mutation. Encryption is
# staged privately and lock failures roll back every change that can be proven.

_cntools_action_advanced_asset_encrypt_policy_validation_failure() {
  builtin printf '%s\n' \
    'CNTools asset encrypt-policy action failed validation.' >&2
  return 70
}

_cntools_action_advanced_asset_encrypt_policy_terminal_restore() {
  local failed=0

  if [[ "${encrypt_policy_terminal_saved:-N}" == Y ]]; then
    tput rc >/dev/null 2>&1 || failed=1
    tput ed >/dev/null 2>&1 || failed=1
    encrypt_policy_terminal_saved=N
  fi
  return "${failed}"
}

_cntools_action_advanced_asset_encrypt_policy_secret_clear() {
  encrypt_policy_secret=
  builtin unset encrypt_policy_secret password 2>/dev/null || true
}

_cntools_action_advanced_asset_encrypt_policy_stat() {
  local target="${1:-}" metadata=""

  [[ -n "${encrypt_policy_stat_path:-}" ]] || return 1
  if metadata="$("${encrypt_policy_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' "${target}" 2>/dev/null)"; then
    builtin printf '%s\n' "${metadata}"
    return 0
  fi
  "${encrypt_policy_stat_path}" -c $'%u\t%a\t%h\t%s\t%d\t%i' \
    -- "${target}" 2>/dev/null
}

_cntools_action_advanced_asset_encrypt_policy_component_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_advanced_asset_encrypt_policy_file_read() {
  local target="${1:-}" metadata="" owner="" mode="" links="" size=""
  local device="" inode="" output_prefix="${2:-}"

  [[ "${output_prefix}" =~ ^encrypt_policy_(entry|source)$ ]] || return 1
  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_advanced_asset_encrypt_policy_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" =~ ^[4-7][0145][0145]$ &&
     "${links}" == 1 && "${size}" =~ ^[0-9]+$ &&
     "${size}" -le 16777216 && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]] || return 1
  builtin printf -v "${output_prefix}_mode" '%s' "${mode}"
  builtin printf -v "${output_prefix}_size" '%s' "${size}"
  builtin printf -v "${output_prefix}_identity" '%s:%s' \
    "${device}" "${inode}"
}

_cntools_action_advanced_asset_encrypt_policy_directory_validate() {
  local target="${1:-}" metadata="" owner="" mode="" links="" size=""
  local device="" inode=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_advanced_asset_encrypt_policy_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" =~ ^7[0145][0145]$ &&
     "${links}" =~ ^[1-9][0-9]*$ && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]]
}

_cntools_action_advanced_asset_encrypt_policy_file_same() {
  local target="${1:-}" expected_identity="${2:-}" metadata=""
  local owner="" mode="" links="" size="" device="" inode=""

  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_advanced_asset_encrypt_policy_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${device}:${inode}" == "${expected_identity}" ]]
}

_cntools_action_advanced_asset_encrypt_policy_immutable_read() {
  local target="${1:-}" output_name="${2:-}" raw="" flags=""

  [[ "${output_name}" =~ ^encrypt_policy_(entry|cipher)_immutable$ &&
     -n "${encrypt_policy_lsattr_path:-}" ]] || return 1
  raw="$("${encrypt_policy_lsattr_path}" -d -- "${target}" 2>/dev/null)" ||
    return 1
  [[ "${raw}" != *$'\n'* && "${raw}" == *' '* ]] || return 1
  flags="${raw%% *}"
  [[ "${flags}" =~ ^[A-Za-z-]{5,64}$ ]] || return 1
  if [[ "${flags}" == *i* ]]; then
    builtin printf -v "${output_name}" '%s' Y
  else
    builtin printf -v "${output_name}" '%s' N
  fi
}

_cntools_action_advanced_asset_encrypt_policy_cleanup_new() {
  local failed=0

  if [[ -n "${encrypt_policy_temp:-}" &&
        ( -e "${encrypt_policy_temp}" || -L "${encrypt_policy_temp}" ) ]]; then
    "${encrypt_policy_rm_path}" -f -- "${encrypt_policy_temp}" \
      >/dev/null 2>&1 || failed=1
  fi
  encrypt_policy_temp=
  if [[ "${encrypt_policy_cipher_created:-N}" == Y &&
        -n "${encrypt_policy_cipher:-}" &&
        ( -e "${encrypt_policy_cipher}" || -L "${encrypt_policy_cipher}" ) ]]; then
    "${encrypt_policy_rm_path}" -f -- "${encrypt_policy_cipher}" \
      >/dev/null 2>&1 || failed=1
  fi
  [[ "${encrypt_policy_cipher_created:-N}" != Y ||
     ( ! -e "${encrypt_policy_cipher:-}" &&
       ! -L "${encrypt_policy_cipher:-}" ) ]] || failed=1
  encrypt_policy_cipher_created=N
  return "${failed}"
}

_cntools_action_advanced_asset_encrypt_policy_lock_release() {
  local failed=0

  if [[ "${encrypt_policy_lock_acquired:-N}" == Y ]]; then
    [[ -n "${encrypt_policy_lock:-}" &&
       -d "${encrypt_policy_lock}" && ! -L "${encrypt_policy_lock}" ]] ||
      failed=1
    if [[ "${failed}" == 0 ]]; then
      "${encrypt_policy_rmdir_path}" -- "${encrypt_policy_lock}" \
        >/dev/null 2>&1 || failed=1
    fi
    if [[ ! -e "${encrypt_policy_lock}" &&
          ! -L "${encrypt_policy_lock}" ]]; then
      encrypt_policy_lock_acquired=N
      encrypt_policy_lock=
    else
      failed=1
    fi
  fi
  return "${failed}"
}

_cntools_action_advanced_asset_encrypt_policy_rollback() {
  local index=0 failed=0 target="" expected=""

  if [[ -n "${encrypt_policy_source_backup:-}" ]]; then
    if [[ "${encrypt_policy_source_moved:-N}" == Y ]]; then
      if [[ ( -e "${encrypt_policy_source_backup}" ||
              -L "${encrypt_policy_source_backup}" ) &&
            ! -e "${encrypt_policy_source}" &&
            ! -L "${encrypt_policy_source}" ]] &&
         _cntools_action_advanced_asset_encrypt_policy_file_same \
           "${encrypt_policy_source_backup}" \
           "${encrypt_policy_source_identity}" &&
         "${encrypt_policy_mv_path}" -- "${encrypt_policy_source_backup}" \
           "${encrypt_policy_source}" >/dev/null 2>&1; then
        encrypt_policy_source_backup=
        encrypt_policy_source_moved=N
      else
        failed=1
      fi
    else
      if [[ -e "${encrypt_policy_source_backup}" ||
            -L "${encrypt_policy_source_backup}" ]]; then
        "${encrypt_policy_rm_path}" -f -- \
          "${encrypt_policy_source_backup}" >/dev/null 2>&1 || failed=1
      fi
      if [[ ! -e "${encrypt_policy_source_backup}" &&
            ! -L "${encrypt_policy_source_backup}" ]]; then
        encrypt_policy_source_backup=
      else
        failed=1
      fi
    fi
  fi

  for (( index=${#encrypt_policy_immutable_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${encrypt_policy_immutable_changed_paths[index]}"
    expected="${encrypt_policy_immutable_changed_identities[index]}"
    _cntools_action_advanced_asset_encrypt_policy_file_same \
      "${target}" "${expected}" || { failed=1; continue; }
    "${encrypt_policy_sudo_path}" "${encrypt_policy_chattr_path}" \
      -i -- "${target}" >/dev/null 2>&1 || failed=1
    encrypt_policy_entry_immutable=Y
    _cntools_action_advanced_asset_encrypt_policy_immutable_read \
      "${target}" encrypt_policy_entry_immutable || failed=1
    [[ "${encrypt_policy_entry_immutable}" == N ]] || failed=1
  done
  encrypt_policy_immutable_changed_paths=()
  encrypt_policy_immutable_changed_identities=()

  for (( index=${#encrypt_policy_mode_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${encrypt_policy_mode_changed_paths[index]}"
    expected="${encrypt_policy_mode_changed_identities[index]}"
    _cntools_action_advanced_asset_encrypt_policy_file_same \
      "${target}" "${expected}" || { failed=1; continue; }
    "${encrypt_policy_chmod_path}" \
      "${encrypt_policy_mode_changed_modes[index]}" "${target}" \
      >/dev/null 2>&1 || failed=1
  done
  encrypt_policy_mode_changed_paths=()
  encrypt_policy_mode_changed_modes=()
  encrypt_policy_mode_changed_identities=()
  _cntools_action_advanced_asset_encrypt_policy_cleanup_new || failed=1
  return "${failed}"
}

_cntools_action_advanced_asset_encrypt_policy_cleanup() {
  local failed=0

  trap - EXIT HUP INT TERM
  _cntools_action_advanced_asset_encrypt_policy_secret_clear
  _cntools_action_advanced_asset_encrypt_policy_terminal_restore || failed=1
  if [[ -n "${encrypt_policy_temp:-}" ||
        -n "${encrypt_policy_source_backup:-}" ||
        "${encrypt_policy_cipher_created:-N}" == Y ]]; then
    _cntools_action_advanced_asset_encrypt_policy_rollback || failed=1
  fi
  _cntools_action_advanced_asset_encrypt_policy_lock_release || failed=1
  return "${failed}"
}

_cntools_action_advanced_asset_encrypt_policy_signal() {
  if [[ "${encrypt_policy_committed:-N}" == Y ]]; then
    if ! _cntools_action_advanced_asset_encrypt_policy_cleanup \
        >/dev/null 2>&1; then
      builtin printf '%s\n' \
        'CNTools policy encryption committed, but administrative cleanup is required.' >&2
    fi
    exit 0
  fi
  _cntools_action_advanced_asset_encrypt_policy_rollback >/dev/null 2>&1 || true
  _cntools_action_advanced_asset_encrypt_policy_cleanup >/dev/null 2>&1 || true
  exit 70
}

_cntools_action_advanced_asset_encrypt_policy_handled_error() {
  local message="${1:-}"

  if ! _cntools_action_advanced_asset_encrypt_policy_lock_release; then
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi
  println ERROR "\n${FG_RED}ERROR${NC}: ${message}"
  waitToProceed
  return 0
}

_cntools_action_advanced_asset_encrypt_policy_sort_entries() {
  local index=0 scan=0 value=""

  for (( index=1; index<${#encrypt_policy_entries[@]}; index++ )); do
    value="${encrypt_policy_entries[index]}"
    scan=$((index - 1))
    while (( scan >= 0 )) &&
      [[ "${encrypt_policy_entries[scan]}" > "${value}" ]]; do
      encrypt_policy_entries[scan + 1]="${encrypt_policy_entries[scan]}"
      scan=$((scan - 1))
    done
    encrypt_policy_entries[scan + 1]="${value}"
  done
}

_cntools_action_advanced_asset_encrypt_policy_inventory_same() {
  local entry="" value="" scan=0 index=0 metadata=""
  local owner="" mode="" links="" size="" device="" inode=""
  local -a discovered=() current=()

  shopt -s nullglob dotglob
  discovered=("${selected_policy}"/*)
  shopt -u nullglob dotglob
  for entry in "${discovered[@]}"; do
    [[ "${entry}" == "${encrypt_policy_temp}" ]] && continue
    current+=("${entry}")
  done
  (( ${#current[@]} == ${#encrypt_policy_entries[@]} )) || return 1
  for (( index=1; index<${#current[@]}; index++ )); do
    value="${current[index]}"
    scan=$((index - 1))
    while (( scan >= 0 )) && [[ "${current[scan]}" > "${value}" ]]; do
      current[scan + 1]="${current[scan]}"
      scan=$((scan - 1))
    done
    current[scan + 1]="${value}"
  done
  for (( index=0; index<${#current[@]}; index++ )); do
    entry="${current[index]}"
    [[ "${entry}" == "${encrypt_policy_entries[index]}" ]] || return 1
    metadata="$(_cntools_action_advanced_asset_encrypt_policy_stat \
      "${entry}")" || return 1
    IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
      return 1
    mode="${mode#0}"
    [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
       "${mode}" == "${encrypt_policy_entry_modes[index]}" &&
       "${size}" == "${encrypt_policy_entry_sizes[index]}" &&
       "${device}:${inode}" == \
         "${encrypt_policy_entry_identities[index]}" ]] || return 1
  done
}

_cntools_action_advanced_asset_encrypt_policy_hash() {
  local target="${1:-}" output_name="${2:-}" digest=""

  [[ "${output_name}" =~ ^encrypt_policy_(source|backup)_digest$ ]] ||
    return 1
  case "${encrypt_policy_hash_kind:-}" in
    sha256sum)
      digest="$("${encrypt_policy_hash_path}" "${target}" 2>/dev/null)" ||
        return 1
      digest="${digest%% *}"
      ;;
    shasum)
      digest="$("${encrypt_policy_hash_path}" -a 256 \
        "${target}" 2>/dev/null)" || return 1
      digest="${digest%% *}"
      ;;
    *) return 1 ;;
  esac
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  builtin printf -v "${output_name}" '%s' "${digest,,}"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local asset_root_physical="" policy_physical="" selected_policy=""
  local entry="" leaf="" metadata="" owner="" mode="" links="" size=""
  local device="" inode="" index=0 total_size=0 action_status=0
  local encrypt_policy_entry_mode="" encrypt_policy_entry_size=""
  local encrypt_policy_entry_identity="" encrypt_policy_source_mode=""
  local encrypt_policy_source_size="" encrypt_policy_source_identity=""
  local encrypt_policy_source="" encrypt_policy_source_backup=""
  local encrypt_policy_source_moved=N
  local encrypt_policy_cipher="" encrypt_policy_cipher_identity=""
  local encrypt_policy_temp="" encrypt_policy_cipher_created=N
  local encrypt_policy_secret="" encrypt_policy_terminal_saved=N
  local encrypt_policy_stat_path="" encrypt_policy_chmod_path=""
  local encrypt_policy_rm_path="" encrypt_policy_ln_path=""
  local encrypt_policy_mv_path="" encrypt_policy_mktemp_path=""
  local encrypt_policy_mkdir_path="" encrypt_policy_rmdir_path=""
  local encrypt_policy_hash_path="" encrypt_policy_hash_kind=""
  local encrypt_policy_lsattr_path="" encrypt_policy_chattr_path=""
  local encrypt_policy_sudo_path="" encrypt_policy_gpg_path=""
  local encrypt_policy_lock="" encrypt_policy_lock_acquired=N
  local encrypt_policy_source_digest="" encrypt_policy_backup_digest=""
  local encrypt_policy_committed=N encrypt_policy_postcommit_warning=N
  local encrypt_policy_entry_immutable=N encrypt_policy_cipher_immutable=N
  local gpg_status=0
  local -a encrypt_policy_entries=()
  local -a encrypt_policy_entry_modes=() encrypt_policy_entry_sizes=()
  local -a encrypt_policy_entry_identities=()
  local -a encrypt_policy_entry_immutables=()
  local -a encrypt_policy_mode_changed_paths=()
  local -a encrypt_policy_mode_changed_modes=()
  local -a encrypt_policy_mode_changed_identities=()
  local -a encrypt_policy_immutable_changed_paths=()
  local -a encrypt_policy_immutable_changed_identities=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64

  encrypt_policy_terminal_saved=N
  encrypt_policy_temp=
  encrypt_policy_cipher=
  encrypt_policy_cipher_created=N
  encrypt_policy_secret=
  encrypt_policy_entries=()
  encrypt_policy_mode_changed_paths=()
  encrypt_policy_mode_changed_modes=()
  encrypt_policy_mode_changed_identities=()
  encrypt_policy_immutable_changed_paths=()
  encrypt_policy_immutable_changed_identities=()

  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F selectPolicy >/dev/null 2>&1 ||
     ! builtin declare -F getPasswordCust >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1; then
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  [[ "${context_mode}" =~ ^(local|light|offline)$ &&
     "${CNTOOLS_MODE,,}" == "${context_mode}" &&
     ( "${ENABLE_CHATTR:-}" == true ||
       "${ENABLE_CHATTR:-}" == false ) &&
     "${ASSET_POLICY_SK_FILENAME:-}" =~ ^[A-Za-z0-9._-]{1,128}$ &&
     "${ASSET_POLICY_SK_FILENAME}" != . &&
     "${ASSET_POLICY_SK_FILENAME}" != .. &&
     "${ASSET_FOLDER:-}" == /* ]] || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  _cntools_registry_tool_path stat encrypt_policy_stat_path || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  _cntools_action_advanced_asset_encrypt_policy_directory_validate \
    "${ASSET_FOLDER}" || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  asset_root_physical="$(cd -P -- "${ASSET_FOLDER}" \
    >/dev/null 2>&1 && pwd -P)" || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  [[ "${asset_root_physical}" == "${ASSET_FOLDER}" ]] || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  for entry in chmod rm ln mv mktemp mkdir rmdir; do
    case "${entry}" in
      chmod) _cntools_registry_tool_path chmod encrypt_policy_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm encrypt_policy_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln encrypt_policy_ln_path || action_status=70 ;;
      mv) _cntools_registry_tool_path mv encrypt_policy_mv_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp encrypt_policy_mktemp_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir encrypt_policy_mkdir_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir encrypt_policy_rmdir_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  if _cntools_registry_tool_path sha256sum encrypt_policy_hash_path; then
    encrypt_policy_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum encrypt_policy_hash_path; then
    encrypt_policy_hash_kind=shasum
  else
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi
  if [[ "${ENABLE_CHATTR}" == true ]]; then
    _cntools_registry_tool_path lsattr encrypt_policy_lsattr_path ||
      action_status=70
    _cntools_registry_tool_path chattr encrypt_policy_chattr_path ||
      action_status=70
    _cntools_registry_tool_path sudo encrypt_policy_sudo_path ||
      action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }

  trap '_cntools_action_advanced_asset_encrypt_policy_cleanup' EXIT
  trap '_cntools_action_advanced_asset_encrypt_policy_signal' HUP INT TERM

  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> ADVANCED >> ASSET >> ENCRYPT / LOCK POLICY'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  shopt -s nullglob dotglob
  encrypt_policy_entries=("${ASSET_FOLDER}"/*)
  shopt -u nullglob dotglob
  if (( ${#encrypt_policy_entries[@]} == 0 )); then
    println "${FG_YELLOW}No policies available!${NC}"
    waitToProceed
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi
  println DEBUG 'Select policy to encrypt'
  if tput sc >/dev/null 2>&1; then encrypt_policy_terminal_saved=Y; fi
  if selectPolicy encrypted; then
    action_status=0
  else
    action_status=$?
  fi
  _cntools_action_advanced_asset_encrypt_policy_terminal_restore || action_status=70
  case "${action_status}" in
    0) ;;
    1) waitToProceed; action_status=0 ;;
    2) action_status=0 ;;
    *) action_status=70 ;;
  esac
  if [[ "${action_status}" != 0 || -z "${policy_name:-}" ]]; then
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi
  _cntools_action_advanced_asset_encrypt_policy_component_valid \
    "${policy_name}" || {
    _cntools_action_advanced_asset_encrypt_policy_handled_error \
      'selected policy failed security validation!'
    action_status=$?
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  }
  selected_policy="${ASSET_FOLDER}/${policy_name}"
  _cntools_action_advanced_asset_encrypt_policy_directory_validate \
    "${selected_policy}" || {
    _cntools_action_advanced_asset_encrypt_policy_handled_error \
      'selected policy failed security validation!'
    action_status=$?
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  }
  policy_physical="$(cd -P -- "${selected_policy}" \
    >/dev/null 2>&1 && pwd -P)" || policy_physical=
  if [[ "${policy_physical}" != "${asset_root_physical}/${policy_name}" ]]; then
    _cntools_action_advanced_asset_encrypt_policy_handled_error \
      'selected policy failed security validation!'
    action_status=$?
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi

  encrypt_policy_lock="${ASSET_FOLDER}/.${policy_name}.cntools-encrypt.lock"
  if [[ -e "${encrypt_policy_lock}" || -L "${encrypt_policy_lock}" ]]; then
    _cntools_action_advanced_asset_encrypt_policy_handled_error \
      'selected policy is already being modified!'
    action_status=$?
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi
  if ! "${encrypt_policy_mkdir_path}" -m 0700 -- \
      "${encrypt_policy_lock}" >/dev/null 2>&1; then
    if [[ -e "${encrypt_policy_lock}" || -L "${encrypt_policy_lock}" ]]; then
      _cntools_action_advanced_asset_encrypt_policy_handled_error \
        'selected policy is already being modified!'
      action_status=$?
    else
      action_status=70
    fi
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi
  encrypt_policy_lock_acquired=Y
  if ! _cntools_action_advanced_asset_encrypt_policy_directory_validate \
      "${encrypt_policy_lock}"; then
    _cntools_action_advanced_asset_encrypt_policy_cleanup || true
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi

  shopt -s nullglob dotglob
  encrypt_policy_entries=("${selected_policy}"/*)
  shopt -u nullglob dotglob
  (( ${#encrypt_policy_entries[@]} <= 1024 )) || action_status=70
  _cntools_action_advanced_asset_encrypt_policy_sort_entries
  encrypt_policy_source="${selected_policy}/${ASSET_POLICY_SK_FILENAME}"
  encrypt_policy_cipher="${encrypt_policy_source}.gpg"
  for entry in "${encrypt_policy_entries[@]}"; do
    leaf="${entry##*/}"
    _cntools_action_advanced_asset_encrypt_policy_component_valid "${leaf}" ||
      action_status=70
    [[ "${leaf}" != .cntools-policy-* ]] || action_status=70
    encrypt_policy_entry_mode=
    encrypt_policy_entry_size=
    encrypt_policy_entry_identity=
    _cntools_action_advanced_asset_encrypt_policy_file_read \
      "${entry}" encrypt_policy_entry || action_status=70
    encrypt_policy_entry_modes+=("${encrypt_policy_entry_mode}")
    encrypt_policy_entry_sizes+=("${encrypt_policy_entry_size}")
    encrypt_policy_entry_identities+=("${encrypt_policy_entry_identity}")
    total_size=$((total_size + ${encrypt_policy_entry_size:-0}))
    (( total_size <= 67108864 )) || action_status=70
    if [[ "${ENABLE_CHATTR}" == true ]]; then
      encrypt_policy_entry_immutable=N
      _cntools_action_advanced_asset_encrypt_policy_immutable_read \
        "${entry}" encrypt_policy_entry_immutable || action_status=70
      encrypt_policy_entry_immutables+=("${encrypt_policy_entry_immutable}")
      if [[ "${entry}" == "${encrypt_policy_source}" &&
            "${encrypt_policy_entry_immutable}" == Y ]]; then
        action_status=70
      fi
      if [[ "${encrypt_policy_entry_immutable}" == Y &&
            "${encrypt_policy_entry_mode}" != 400 ]]; then
        action_status=70
      fi
    else
      encrypt_policy_entry_immutables+=(N)
    fi
  done
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_encrypt_policy_handled_error \
      'selected policy failed security validation!'
    action_status=$?
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi
  for entry in "${encrypt_policy_entries[@]}"; do
    if [[ "${entry}" == *.gpg ]]; then
      echo
      println "${FG_YELLOW}NOTE${NC}: found GPG encrypted files in folder, please decrypt/unlock policy files before encrypting"
      _cntools_action_advanced_asset_encrypt_policy_lock_release ||
        action_status=70
      [[ "${action_status}" == 0 ]] || {
        _cntools_action_advanced_asset_encrypt_policy_cleanup || true
        _cntools_action_advanced_asset_encrypt_policy_validation_failure
        return 70
      }
      waitToProceed
      _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
      [[ "${action_status}" == 0 ]] ||
        _cntools_action_advanced_asset_encrypt_policy_validation_failure
      return "${action_status}"
    fi
  done
  encrypt_policy_source_mode=
  encrypt_policy_source_size=
  encrypt_policy_source_identity=
  if ! _cntools_action_advanced_asset_encrypt_policy_file_read \
      "${encrypt_policy_source}" encrypt_policy_source ||
     [[ "${encrypt_policy_source_size:-0}" -lt 1 ]]; then
    _cntools_action_advanced_asset_encrypt_policy_handled_error \
      'policy signing key is missing or unsafe!'
    action_status=$?
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi

  echo
  println 'Encrypting policy signing key with GPG'
  if ! getPasswordCust confirm; then
    println '\n\n'
    println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
    _cntools_action_advanced_asset_encrypt_policy_secret_clear
    _cntools_action_advanced_asset_encrypt_policy_lock_release ||
      action_status=70
    [[ "${action_status}" == 0 ]] || {
      _cntools_action_advanced_asset_encrypt_policy_cleanup || true
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
      return 70
    }
    waitToProceed
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi
  encrypt_policy_secret="${password-}"
  builtin unset password
  if (( ${#encrypt_policy_secret} < 8 ||
        ${#encrypt_policy_secret} > 1024 )); then
    _cntools_action_advanced_asset_encrypt_policy_secret_clear
    _cntools_action_advanced_asset_encrypt_policy_handled_error \
      'password input failed validation!'
    action_status=$?
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return "${action_status}"
  fi
  _cntools_registry_tool_path gpg encrypt_policy_gpg_path || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_encrypt_policy_secret_clear
    _cntools_action_advanced_asset_encrypt_policy_cleanup || true
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  umask 077
  encrypt_policy_temp="$("${encrypt_policy_mktemp_path}" \
    "${selected_policy}/.cntools-policy-encrypt.XXXXXXXX" \
    2>/dev/null)" ||
    action_status=70
  [[ "${action_status}" == 0 && -f "${encrypt_policy_temp}" &&
     ! -L "${encrypt_policy_temp}" ]] || {
    _cntools_action_advanced_asset_encrypt_policy_secret_clear
    _cntools_action_advanced_asset_encrypt_policy_cleanup || true
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  }
  "${encrypt_policy_chmod_path}" 0600 "${encrypt_policy_temp}" \
    >/dev/null 2>&1 ||
    action_status=70
  _cntools_action_advanced_asset_encrypt_policy_file_same \
    "${encrypt_policy_source}" "${encrypt_policy_source_identity}" ||
    action_status=70
  _cntools_action_advanced_asset_encrypt_policy_hash \
    "${encrypt_policy_source}" encrypt_policy_source_digest ||
    action_status=70
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_encrypt_policy_secret_clear
    _cntools_action_advanced_asset_encrypt_policy_cleanup || true
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi
  if "${encrypt_policy_gpg_path}" --symmetric --yes --batch --no-tty \
      --pinentry-mode loopback --cipher-algo AES256 --passphrase-fd 0 \
      --output "${encrypt_policy_temp}" -- "${encrypt_policy_source}" \
      <<< "${encrypt_policy_secret}" >/dev/null 2>&1; then
    gpg_status=0
  else
    gpg_status=$?
  fi
  _cntools_action_advanced_asset_encrypt_policy_secret_clear
  if [[ "${gpg_status}" != 0 ]] ||
     ! "${encrypt_policy_chmod_path}" 0600 "${encrypt_policy_temp}" \
       >/dev/null 2>&1 ||
     ! _cntools_action_advanced_asset_encrypt_policy_file_read \
       "${encrypt_policy_temp}" encrypt_policy_entry ||
     [[ "${encrypt_policy_entry_size:-0}" -lt 1 ]]; then
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    if [[ "${action_status}" == 0 ]]; then
      _cntools_action_advanced_asset_encrypt_policy_handled_error \
        'failed to encrypt policy signing key!'
      return $?
    fi
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi
  # Revalidate the exact original inventory and source bytes immediately
  # before the commit phase.
  _cntools_action_advanced_asset_encrypt_policy_inventory_same ||
    action_status=70
  encrypt_policy_backup_digest=
  _cntools_action_advanced_asset_encrypt_policy_hash \
    "${encrypt_policy_source}" encrypt_policy_backup_digest ||
    action_status=70
  [[ "${encrypt_policy_backup_digest}" == \
     "${encrypt_policy_source_digest}" ]] || action_status=70
  [[ ! -e "${encrypt_policy_cipher}" &&
     ! -L "${encrypt_policy_cipher}" ]] || action_status=70
  if [[ "${action_status}" != 0 ]] ||
     ! "${encrypt_policy_ln_path}" -- \
       "${encrypt_policy_temp}" "${encrypt_policy_cipher}" \
       >/dev/null 2>&1; then
    _cntools_action_advanced_asset_encrypt_policy_cleanup || action_status=70
    if [[ "${action_status}" == 0 ]]; then
      _cntools_action_advanced_asset_encrypt_policy_handled_error \
        'selected policy changed before encryption could be committed!'
      return $?
    fi
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi
  encrypt_policy_cipher_created=Y
  if "${encrypt_policy_rm_path}" -f -- "${encrypt_policy_temp}" \
       >/dev/null 2>&1 &&
     [[ ! -e "${encrypt_policy_temp}" &&
        ! -L "${encrypt_policy_temp}" ]]; then
    encrypt_policy_temp=
  else
    action_status=70
  fi
  encrypt_policy_entry_mode=
  encrypt_policy_entry_size=
  encrypt_policy_entry_identity=
  _cntools_action_advanced_asset_encrypt_policy_file_read \
    "${encrypt_policy_cipher}" encrypt_policy_entry || action_status=70
  encrypt_policy_cipher_identity="${encrypt_policy_entry_identity}"
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_encrypt_policy_rollback || true
    _cntools_action_advanced_asset_encrypt_policy_cleanup || true
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi

  # Lock every final file. The source remains untouched until all lock
  # operations and immutable-state verification have succeeded.
  for (( index=0; index<${#encrypt_policy_entries[@]}; index++ )); do
    entry="${encrypt_policy_entries[index]}"
    [[ "${entry}" == "${encrypt_policy_source}" ]] && continue
    if [[ "${encrypt_policy_entry_modes[index]}" != 400 ]]; then
      encrypt_policy_mode_changed_paths+=("${entry}")
      encrypt_policy_mode_changed_modes+=("${encrypt_policy_entry_modes[index]}")
      encrypt_policy_mode_changed_identities+=(
        "${encrypt_policy_entry_identities[index]}")
      "${encrypt_policy_chmod_path}" 0400 "${entry}" \
        >/dev/null 2>&1 || action_status=1
    fi
    [[ "${action_status}" == 0 ]] || break
  done
  if [[ "${action_status}" == 0 ]]; then
    "${encrypt_policy_chmod_path}" 0400 "${encrypt_policy_cipher}" \
      >/dev/null 2>&1 ||
      action_status=1
  fi
  if [[ "${action_status}" == 0 && "${ENABLE_CHATTR}" == true ]]; then
    for (( index=0; index<${#encrypt_policy_entries[@]}; index++ )); do
      entry="${encrypt_policy_entries[index]}"
      [[ "${entry}" == "${encrypt_policy_source}" ]] && continue
      [[ "${encrypt_policy_entry_immutables[index]}" == Y ]] && continue
      "${encrypt_policy_sudo_path}" "${encrypt_policy_chattr_path}" \
        +i -- "${entry}" >/dev/null 2>&1 || { action_status=1; break; }
      encrypt_policy_entry_immutable=N
      _cntools_action_advanced_asset_encrypt_policy_immutable_read \
        "${entry}" encrypt_policy_entry_immutable || action_status=1
      [[ "${encrypt_policy_entry_immutable}" == Y ]] || action_status=1
      if [[ "${action_status}" != 0 ]]; then
        "${encrypt_policy_sudo_path}" "${encrypt_policy_chattr_path}" \
          -i -- "${entry}" >/dev/null 2>&1 || action_status=70
        encrypt_policy_entry_immutable=Y
        _cntools_action_advanced_asset_encrypt_policy_immutable_read \
          "${entry}" encrypt_policy_entry_immutable || action_status=70
        [[ "${encrypt_policy_entry_immutable}" == N ]] || action_status=70
      else
        encrypt_policy_immutable_changed_paths+=("${entry}")
        encrypt_policy_immutable_changed_identities+=(
          "${encrypt_policy_entry_identities[index]}")
      fi
      [[ "${action_status}" == 0 ]] || break
    done
    if [[ "${action_status}" == 0 ]]; then
      "${encrypt_policy_sudo_path}" "${encrypt_policy_chattr_path}" \
        +i -- "${encrypt_policy_cipher}" >/dev/null 2>&1 || action_status=1
      encrypt_policy_cipher_immutable=N
      _cntools_action_advanced_asset_encrypt_policy_immutable_read \
        "${encrypt_policy_cipher}" encrypt_policy_cipher_immutable ||
        action_status=1
      [[ "${encrypt_policy_cipher_immutable}" == Y ]] || action_status=1
      if [[ "${action_status}" != 0 ]]; then
        "${encrypt_policy_sudo_path}" "${encrypt_policy_chattr_path}" \
          -i -- "${encrypt_policy_cipher}" >/dev/null 2>&1 || action_status=70
        encrypt_policy_cipher_immutable=Y
        _cntools_action_advanced_asset_encrypt_policy_immutable_read \
          "${encrypt_policy_cipher}" encrypt_policy_cipher_immutable ||
          action_status=70
        [[ "${encrypt_policy_cipher_immutable}" == N ]] || action_status=70
      else
        encrypt_policy_immutable_changed_paths+=("${encrypt_policy_cipher}")
        encrypt_policy_immutable_changed_identities+=(
          "${encrypt_policy_cipher_identity}")
      fi
    fi
  fi
  if [[ "${action_status}" != 0 ]]; then
    if _cntools_action_advanced_asset_encrypt_policy_rollback; then
      _cntools_action_advanced_asset_encrypt_policy_handled_error \
        'failed to lock policy files; original policy was preserved!'
      action_status=$?
      _cntools_action_advanced_asset_encrypt_policy_cleanup || {
        _cntools_action_advanced_asset_encrypt_policy_validation_failure
        return 70
      }
      return "${action_status}"
    fi
    _cntools_action_advanced_asset_encrypt_policy_cleanup || true
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi

  # Locking is now proven. Move the original key to an exact private backup,
  # verify its identity, and only then remove that final plaintext link.
  encrypt_policy_source_backup="$("${encrypt_policy_mktemp_path}" \
    "${selected_policy}/.cntools-policy-source.XXXXXXXX" \
    2>/dev/null)" ||
    action_status=1
  if [[ "${action_status}" == 0 ]]; then
    "${encrypt_policy_rm_path}" -f -- \
      "${encrypt_policy_source_backup}" >/dev/null 2>&1 || action_status=1
  fi
  if [[ "${action_status}" == 0 ]]; then
    "${encrypt_policy_mv_path}" -- "${encrypt_policy_source}" \
      "${encrypt_policy_source_backup}" >/dev/null 2>&1 || action_status=1
    if [[ ! -e "${encrypt_policy_source}" &&
          ! -L "${encrypt_policy_source}" ]] &&
       _cntools_action_advanced_asset_encrypt_policy_file_same \
         "${encrypt_policy_source_backup}" \
         "${encrypt_policy_source_identity}"; then
      encrypt_policy_source_moved=Y
    elif _cntools_action_advanced_asset_encrypt_policy_file_same \
           "${encrypt_policy_source}" \
           "${encrypt_policy_source_identity}" &&
         [[ ! -e "${encrypt_policy_source_backup}" &&
            ! -L "${encrypt_policy_source_backup}" ]]; then
      encrypt_policy_source_moved=N
    else
      action_status=1
    fi
  fi
  if [[ "${action_status}" == 0 ]]; then
    _cntools_action_advanced_asset_encrypt_policy_file_same \
      "${encrypt_policy_source_backup}" \
      "${encrypt_policy_source_identity}" || action_status=1
    _cntools_action_advanced_asset_encrypt_policy_hash \
      "${encrypt_policy_source_backup}" encrypt_policy_backup_digest ||
      action_status=1
    [[ "${encrypt_policy_backup_digest}" == \
       "${encrypt_policy_source_digest}" ]] || action_status=1
  fi
  if [[ "${action_status}" == 0 ]]; then
    "${encrypt_policy_rm_path}" -f -- \
      "${encrypt_policy_source_backup}" >/dev/null 2>&1 || action_status=1
    [[ ! -e "${encrypt_policy_source_backup}" &&
       ! -L "${encrypt_policy_source_backup}" ]] || action_status=1
    [[ "${action_status}" != 0 ]] || encrypt_policy_source_moved=N
  fi
  if [[ "${action_status}" != 0 ]]; then
    if _cntools_action_advanced_asset_encrypt_policy_rollback; then
      _cntools_action_advanced_asset_encrypt_policy_handled_error \
        'failed to commit encrypted policy; original policy was preserved!'
      action_status=$?
      _cntools_action_advanced_asset_encrypt_policy_cleanup || {
        _cntools_action_advanced_asset_encrypt_policy_validation_failure
        return 70
      }
      return "${action_status}"
    fi
    _cntools_action_advanced_asset_encrypt_policy_cleanup || true
    _cntools_action_advanced_asset_encrypt_policy_validation_failure
    return 70
  fi
  encrypt_policy_source_backup=
  encrypt_policy_source_moved=N

  # This is the irreversible commit boundary: the validated ciphertext is in
  # place, every final leaf is locked, and the verified plaintext backup is
  # absent. Nothing after this point may report a generic action failure.
  encrypt_policy_committed=Y

  encrypt_policy_cipher_created=N
  encrypt_policy_mode_changed_paths=()
  encrypt_policy_mode_changed_modes=()
  encrypt_policy_mode_changed_identities=()
  encrypt_policy_immutable_changed_paths=()
  encrypt_policy_immutable_changed_identities=()
  if ! _cntools_action_advanced_asset_encrypt_policy_lock_release; then
    encrypt_policy_postcommit_warning=Y
  fi
  println DEBUG "${encrypt_policy_source} successfully encrypted"
  echo
  println "Write protecting all policy files with 400 permission and if enabled 'chattr +i'"
  for (( index=0; index<${#encrypt_policy_entries[@]}; index++ )); do
    entry="${encrypt_policy_entries[index]}"
    [[ "${entry}" == "${encrypt_policy_source}" ]] && continue
    println DEBUG "${entry}"
  done
  println DEBUG "${encrypt_policy_cipher}"
  echo
  println "Policy encrypted : ${FG_GREEN}${policy_name}${NC}"
  println "Files locked     : ${FG_LBLUE}${#encrypt_policy_entries[@]}${NC}"
  println "Files encrypted  : ${FG_LBLUE}1${NC}"
  println INFO "\n${FG_GREEN}INFO${NC}: policy files are now protected\nUse 'ADVANCED >> ASSET >> DECRYPT / UNLOCK POLICY' to unlock"
  if [[ "${encrypt_policy_postcommit_warning}" == Y ]]; then
    println ERROR "\n${FG_YELLOW}WARNING${NC}: policy encryption committed, but the policy operation lock could not be removed; administrative cleanup is required!"
  fi
  waitToProceed
  if ! _cntools_action_advanced_asset_encrypt_policy_cleanup; then
    # The warning above covers the only remaining fallible resource: the
    # literal operation-lock directory. The commit must remain status 0.
    encrypt_policy_postcommit_warning=Y
  fi
  [[ "${encrypt_policy_committed}" == Y ]] || return 70
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
