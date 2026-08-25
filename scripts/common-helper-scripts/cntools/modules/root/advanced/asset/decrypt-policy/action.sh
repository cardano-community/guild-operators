#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Stage 4 compatibility action for decrypting and unlocking one asset policy.
# The selected policy is inventoried before mutation. Plaintext is staged in a
# private operation directory and ciphertext remains recoverable until commit.

_cntools_action_advanced_asset_decrypt_policy_validation_failure() {
  builtin printf '%s\n' \
    'CNTools asset decrypt-policy action failed validation.' >&2
  return 70
}

_cntools_action_advanced_asset_decrypt_policy_terminal_restore() {
  local failed=0

  if [[ "${decrypt_policy_terminal_saved:-N}" == Y ]]; then
    tput rc >/dev/null 2>&1 || failed=1
    tput ed >/dev/null 2>&1 || failed=1
    decrypt_policy_terminal_saved=N
  fi
  return "${failed}"
}

_cntools_action_advanced_asset_decrypt_policy_secret_clear() {
  decrypt_policy_secret=
  builtin unset decrypt_policy_secret password 2>/dev/null || true
}

_cntools_action_advanced_asset_decrypt_policy_stat() {
  local target="${1:-}" metadata=""

  [[ -n "${decrypt_policy_stat_path:-}" ]] || return 1
  if metadata="$("${decrypt_policy_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' "${target}" 2>/dev/null)"; then
    builtin printf '%s\n' "${metadata}"
    return 0
  fi
  "${decrypt_policy_stat_path}" -c $'%u\t%a\t%h\t%s\t%d\t%i' \
    -- "${target}" 2>/dev/null
}

_cntools_action_advanced_asset_decrypt_policy_component_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_advanced_asset_decrypt_policy_directory_validate() {
  local target="${1:-}" metadata="" owner="" mode="" links=""
  local size="" device="" inode=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_advanced_asset_decrypt_policy_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" =~ ^7[015][015]$ &&
     "${links}" =~ ^[1-9][0-9]*$ && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]]
}

_cntools_action_advanced_asset_decrypt_policy_file_read() {
  local target="${1:-}" output_prefix="${2:-}" metadata=""
  local owner="" mode="" links="" size="" device="" inode=""

  [[ "${output_prefix}" =~ ^decrypt_policy_(entry|temp|target|backup)$ ]] ||
    return 1
  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_advanced_asset_decrypt_policy_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" =~ ^[46][04][04]$ &&
     "${links}" == 1 && "${size}" =~ ^[0-9]+$ &&
     "${size}" -le 16777216 && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]] || return 1
  builtin printf -v "${output_prefix}_mode" '%s' "${mode}"
  builtin printf -v "${output_prefix}_size" '%s' "${size}"
  builtin printf -v "${output_prefix}_identity" '%s:%s' \
    "${device}" "${inode}"
}

_cntools_action_advanced_asset_decrypt_policy_hash() {
  local target="${1:-}" output_name="${2:-}" digest=""

  [[ "${output_name}" =~ ^decrypt_policy_(entry|temp|target|backup)_digest$ ]] ||
    return 1
  case "${decrypt_policy_hash_kind:-}" in
    sha256sum)
      digest="$("${decrypt_policy_hash_path}" "${target}" 2>/dev/null)" ||
        return 1
      digest="${digest%% *}"
      ;;
    shasum)
      digest="$("${decrypt_policy_hash_path}" -a 256 \
        "${target}" 2>/dev/null)" || return 1
      digest="${digest%% *}"
      ;;
    *) return 1 ;;
  esac
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  builtin printf -v "${output_name}" '%s' "${digest,,}"
}

_cntools_action_advanced_asset_decrypt_policy_file_same() {
  local target="${1:-}" expected_identity="${2:-}"
  local expected_digest="${3:-}" metadata="" owner="" mode=""
  local links="" size="" device="" inode="" digest=""

  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_advanced_asset_decrypt_policy_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${device}:${inode}" == "${expected_identity}" ]] || return 1
  if [[ -n "${expected_digest}" ]]; then
    case "${decrypt_policy_hash_kind}" in
      sha256sum)
        digest="$("${decrypt_policy_hash_path}" "${target}" 2>/dev/null)" ||
          return 1
        digest="${digest%% *}"
        ;;
      shasum)
        digest="$("${decrypt_policy_hash_path}" -a 256 \
          "${target}" 2>/dev/null)" || return 1
        digest="${digest%% *}"
        ;;
    esac
    [[ "${digest,,}" == "${expected_digest}" ]] || return 1
  fi
}

_cntools_action_advanced_asset_decrypt_policy_immutable_read() {
  local target="${1:-}" output_name="${2:-}" raw="" flags=""

  [[ "${output_name}" =~ ^decrypt_policy_(entry|check)_immutable$ &&
     -n "${decrypt_policy_lsattr_path:-}" ]] || return 1
  raw="$("${decrypt_policy_lsattr_path}" -d -- \
    "${target}" 2>/dev/null)" || return 1
  [[ "${raw}" != *$'\n'* && "${raw}" == *' '* ]] || return 1
  flags="${raw%% *}"
  [[ "${flags}" =~ ^[A-Za-z-]{5,64}$ ]] || return 1
  if [[ "${flags}" == *i* ]]; then
    builtin printf -v "${output_name}" '%s' Y
  else
    builtin printf -v "${output_name}" '%s' N
  fi
}

_cntools_action_advanced_asset_decrypt_policy_sort_entries() {
  local index=0 scan=0 value=""

  for (( index=1; index<${#decrypt_policy_entries[@]}; index++ )); do
    value="${decrypt_policy_entries[index]}"
    scan=$((index - 1))
    while (( scan >= 0 )) &&
      [[ "${decrypt_policy_entries[scan]}" > "${value}" ]]; do
      decrypt_policy_entries[scan + 1]="${decrypt_policy_entries[scan]}"
      scan=$((scan - 1))
    done
    decrypt_policy_entries[scan + 1]="${value}"
  done
}

_cntools_action_advanced_asset_decrypt_policy_inventory_same() {
  local entry="" value="" scan=0 index=0 metadata="" digest=""
  local owner="" mode="" links="" size="" device="" inode=""
  local -a current=()

  shopt -s nullglob dotglob
  current=("${selected_policy}"/*)
  shopt -u nullglob dotglob
  (( ${#current[@]} == ${#decrypt_policy_entries[@]} )) || return 1
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
    [[ "${entry}" == "${decrypt_policy_entries[index]}" ]] || return 1
    metadata="$(_cntools_action_advanced_asset_decrypt_policy_stat \
      "${entry}")" || return 1
    IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
      return 1
    mode="${mode#0}"
    [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
       "${mode}" == "${decrypt_policy_entry_modes[index]}" &&
       "${size}" == "${decrypt_policy_entry_sizes[index]}" &&
       "${device}:${inode}" == \
         "${decrypt_policy_entry_identities[index]}" ]] || return 1
    case "${decrypt_policy_hash_kind}" in
      sha256sum)
        digest="$("${decrypt_policy_hash_path}" "${entry}" 2>/dev/null)" ||
          return 1
        digest="${digest%% *}"
        ;;
      shasum)
        digest="$("${decrypt_policy_hash_path}" -a 256 \
          "${entry}" 2>/dev/null)" || return 1
        digest="${digest%% *}"
        ;;
    esac
    [[ "${digest,,}" == "${decrypt_policy_entry_digests[index]}" ]] ||
      return 1
  done
}

_cntools_action_advanced_asset_decrypt_policy_lock_release() {
  local failed=0

  if [[ "${decrypt_policy_lock_acquired:-N}" == Y ]]; then
    [[ -n "${decrypt_policy_lock:-}" && -d "${decrypt_policy_lock}" &&
       ! -L "${decrypt_policy_lock}" ]] || failed=1
    if [[ "${failed}" == 0 ]]; then
      "${decrypt_policy_rmdir_path}" -- "${decrypt_policy_lock}" \
        >/dev/null 2>&1 || failed=1
    fi
    if [[ ! -e "${decrypt_policy_lock}" &&
          ! -L "${decrypt_policy_lock}" ]]; then
      decrypt_policy_lock_acquired=N
      decrypt_policy_lock=
    else
      failed=1
    fi
  fi
  return "${failed}"
}

_cntools_action_advanced_asset_decrypt_policy_rollback() {
  local index=0 failed=0 target="" backup="" identity="" digest=""

  for (( index=${#decrypt_policy_backup_paths[@]}-1;
         index>=0; index-- )); do
    target="${decrypt_policy_cipher_paths[index]}"
    backup="${decrypt_policy_backup_paths[index]}"
    identity="${decrypt_policy_cipher_identities[index]}"
    digest="${decrypt_policy_cipher_digests[index]}"
    if [[ -e "${backup}" || -L "${backup}" ]]; then
      if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        if _cntools_action_advanced_asset_decrypt_policy_file_same \
             "${backup}" "${identity}" "${digest}" &&
           "${decrypt_policy_ln_path}" -- "${backup}" "${target}" \
             >/dev/null 2>&1 &&
           "${decrypt_policy_rm_path}" -f -- "${backup}" \
             >/dev/null 2>&1; then
          :
        else
          failed=1
        fi
      else
        if _cntools_action_advanced_asset_decrypt_policy_file_same \
             "${target}" "${identity}" "${digest}"; then
          "${decrypt_policy_rm_path}" -f -- "${backup}" \
            >/dev/null 2>&1 || failed=1
        else
          # Retain the authenticated backup when the canonical ciphertext path
          # no longer names the original file. Discarding it would turn a
          # concurrent replacement into unrecoverable data loss.
          failed=1
        fi
      fi
    fi
  done
  decrypt_policy_backup_paths=()

  for (( index=${#decrypt_policy_published_paths[@]}-1;
         index>=0; index-- )); do
    target="${decrypt_policy_published_paths[index]}"
    identity="${decrypt_policy_published_identities[index]}"
    digest="${decrypt_policy_published_digests[index]}"
    if [[ -e "${target}" || -L "${target}" ]]; then
      _cntools_action_advanced_asset_decrypt_policy_file_same \
        "${target}" "${identity}" "${digest}" || { failed=1; continue; }
      "${decrypt_policy_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || failed=1
    fi
  done
  decrypt_policy_published_paths=()
  decrypt_policy_published_identities=()
  decrypt_policy_published_digests=()

  for (( index=${#decrypt_policy_temp_paths[@]}-1;
         index>=0; index-- )); do
    target="${decrypt_policy_temp_paths[index]}"
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${decrypt_policy_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || failed=1
    fi
  done
  decrypt_policy_temp_paths=()

  for (( index=${#decrypt_policy_mode_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${decrypt_policy_mode_changed_paths[index]}"
    identity="${decrypt_policy_mode_changed_identities[index]}"
    _cntools_action_advanced_asset_decrypt_policy_file_same \
      "${target}" "${identity}" || { failed=1; continue; }
    "${decrypt_policy_chmod_path}" \
      "${decrypt_policy_mode_changed_modes[index]}" "${target}" \
      >/dev/null 2>&1 || failed=1
  done
  decrypt_policy_mode_changed_paths=()
  decrypt_policy_mode_changed_modes=()
  decrypt_policy_mode_changed_identities=()

  for (( index=${#decrypt_policy_immutable_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${decrypt_policy_immutable_changed_paths[index]}"
    identity="${decrypt_policy_immutable_changed_identities[index]}"
    _cntools_action_advanced_asset_decrypt_policy_file_same \
      "${target}" "${identity}" || { failed=1; continue; }
    "${decrypt_policy_sudo_path}" "${decrypt_policy_chattr_path}" \
      +i -- "${target}" >/dev/null 2>&1 || failed=1
    decrypt_policy_check_immutable=N
    _cntools_action_advanced_asset_decrypt_policy_immutable_read \
      "${target}" decrypt_policy_check_immutable || failed=1
    [[ "${decrypt_policy_check_immutable}" == Y ]] || failed=1
  done
  decrypt_policy_immutable_changed_paths=()
  decrypt_policy_immutable_changed_identities=()
  return "${failed}"
}

_cntools_action_advanced_asset_decrypt_policy_precommit_cleanup() {
  local failed=0

  trap - EXIT HUP INT TERM
  _cntools_action_advanced_asset_decrypt_policy_secret_clear
  _cntools_action_advanced_asset_decrypt_policy_terminal_restore || failed=1
  _cntools_action_advanced_asset_decrypt_policy_rollback || failed=1
  _cntools_action_advanced_asset_decrypt_policy_lock_release || failed=1
  return "${failed}"
}

_cntools_action_advanced_asset_decrypt_policy_signal() {
  _cntools_action_advanced_asset_decrypt_policy_precommit_cleanup \
    >/dev/null 2>&1 || true
  exit 70
}

_cntools_action_advanced_asset_decrypt_policy_handled_error() {
  local message="${1:-}" failed=0

  _cntools_action_advanced_asset_decrypt_policy_secret_clear
  _cntools_action_advanced_asset_decrypt_policy_rollback || failed=1
  _cntools_action_advanced_asset_decrypt_policy_lock_release || failed=1
  if [[ "${failed}" != 0 ]]; then
    trap - EXIT HUP INT TERM
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  fi
  println ERROR "\n${FG_RED}ERROR${NC}: ${message}"
  waitToProceed
  return 0
}

_cntools_action_advanced_asset_decrypt_policy_postcommit_cleanup() {
  local index=0 failed=0 target=""

  _cntools_action_advanced_asset_decrypt_policy_secret_clear
  for (( index=${#decrypt_policy_backup_paths[@]}-1;
         index>=0; index-- )); do
    target="${decrypt_policy_backup_paths[index]}"
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${decrypt_policy_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || failed=1
    fi
  done
  for target in "${decrypt_policy_temp_paths[@]}"; do
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${decrypt_policy_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || failed=1
    fi
  done
  if [[ "${failed}" == 0 ]]; then
    decrypt_policy_backup_paths=()
    decrypt_policy_temp_paths=()
    _cntools_action_advanced_asset_decrypt_policy_lock_release || failed=1
  fi
  return "${failed}"
}

_cntools_action_advanced_asset_decrypt_policy_commit_transition() {
  local cleanup_failed=0

  # One trap command installs this transition for EXIT and every handled
  # signal. Until the following commit assignment, a trap still rolls the
  # operation back; after it, published plaintext is never removed.
  trap - EXIT
  trap '' HUP INT TERM
  if [[ "${decrypt_policy_committed:-N}" == Y ]]; then
    _cntools_action_advanced_asset_decrypt_policy_postcommit_cleanup ||
      cleanup_failed=1
    if [[ "${cleanup_failed}" == 0 ]]; then
      builtin printf '%s\n' \
        'CNTools asset decrypt-policy action committed; interrupted during post-commit cleanup.' >&2
    else
      builtin printf '%s\n' \
        'CNTools asset decrypt-policy action committed; private cleanup is incomplete and the operation lock was retained.' >&2
    fi
    exit 0
  fi
  _cntools_action_advanced_asset_decrypt_policy_precommit_cleanup \
    >/dev/null 2>&1 || true
  exit 70
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local asset_root_physical="" policy_physical="" selected_policy=""
  local entry="" leaf="" plain_leaf="" plain_path="" metadata=""
  local index=0 cipher_index=0 total_size=0 action_status=0 cleanup_status=0
  local decrypt_policy_entry_mode="" decrypt_policy_entry_size=""
  local decrypt_policy_entry_identity="" decrypt_policy_entry_digest=""
  local decrypt_policy_temp_mode="" decrypt_policy_temp_size=""
  local decrypt_policy_temp_identity="" decrypt_policy_temp_digest=""
  local decrypt_policy_target_mode="" decrypt_policy_target_size=""
  local decrypt_policy_target_identity="" decrypt_policy_target_digest=""
  local decrypt_policy_backup_mode="" decrypt_policy_backup_size=""
  local decrypt_policy_backup_identity="" decrypt_policy_backup_digest=""
  local decrypt_policy_check_immutable=N decrypt_policy_entry_immutable=N
  local decrypt_policy_secret="" decrypt_policy_terminal_saved=N
  local decrypt_policy_stat_path="" decrypt_policy_chmod_path=""
  local decrypt_policy_rm_path="" decrypt_policy_ln_path=""
  local decrypt_policy_mktemp_path="" decrypt_policy_mkdir_path=""
  local decrypt_policy_rmdir_path="" decrypt_policy_hash_path=""
  local decrypt_policy_hash_kind="" decrypt_policy_gpg_path=""
  local decrypt_policy_lsattr_path="" decrypt_policy_chattr_path=""
  local decrypt_policy_sudo_path="" decrypt_policy_lock=""
  local decrypt_policy_lock_acquired=N decrypt_policy_committed=N
  local decrypt_policy_postcommit_warning=N filesUnlocked=0 keysDecrypted=0
  local temp="" target="" backup="" identity="" digest=""
  local -a decrypt_policy_entries=()
  local -a decrypt_policy_entry_modes=() decrypt_policy_entry_sizes=()
  local -a decrypt_policy_entry_identities=() decrypt_policy_entry_digests=()
  local -a decrypt_policy_entry_immutables=()
  local -a decrypt_policy_cipher_paths=()
  local -a decrypt_policy_cipher_identities=()
  local -a decrypt_policy_cipher_digests=()
  local -a decrypt_policy_plain_paths=()
  local -a decrypt_policy_temp_paths=()
  local -a decrypt_policy_temp_identities=()
  local -a decrypt_policy_temp_digests=()
  local -a decrypt_policy_published_paths=()
  local -a decrypt_policy_published_identities=()
  local -a decrypt_policy_published_digests=()
  local -a decrypt_policy_backup_paths=()
  local -a decrypt_policy_mode_changed_paths=()
  local -a decrypt_policy_mode_changed_modes=()
  local -a decrypt_policy_mode_changed_identities=()
  local -a decrypt_policy_immutable_changed_paths=()
  local -a decrypt_policy_immutable_changed_identities=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F selectPolicy >/dev/null 2>&1 ||
     ! builtin declare -F getPasswordCust >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1; then
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
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
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  }
  _cntools_registry_tool_path stat decrypt_policy_stat_path || action_status=70
  for entry in chmod rm ln mktemp mkdir rmdir gpg; do
    case "${entry}" in
      chmod) _cntools_registry_tool_path chmod decrypt_policy_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm decrypt_policy_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln decrypt_policy_ln_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp decrypt_policy_mktemp_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir decrypt_policy_mkdir_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir decrypt_policy_rmdir_path || action_status=70 ;;
      gpg) _cntools_registry_tool_path gpg decrypt_policy_gpg_path || action_status=70 ;;
    esac
  done
  if _cntools_registry_tool_path sha256sum decrypt_policy_hash_path; then
    decrypt_policy_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum decrypt_policy_hash_path; then
    decrypt_policy_hash_kind=shasum
  else
    action_status=70
  fi
  if [[ "${ENABLE_CHATTR}" == true ]]; then
    _cntools_registry_tool_path lsattr decrypt_policy_lsattr_path || action_status=70
    _cntools_registry_tool_path chattr decrypt_policy_chattr_path || action_status=70
    _cntools_registry_tool_path sudo decrypt_policy_sudo_path || action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  }
  _cntools_action_advanced_asset_decrypt_policy_directory_validate \
    "${ASSET_FOLDER}" || {
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  }
  asset_root_physical="$(cd -P -- "${ASSET_FOLDER}" \
    >/dev/null 2>&1 && pwd -P)" || {
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  }
  [[ "${asset_root_physical}" == "${ASSET_FOLDER}" ]] || {
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  }

  trap '_cntools_action_advanced_asset_decrypt_policy_precommit_cleanup' EXIT
  trap '_cntools_action_advanced_asset_decrypt_policy_signal' HUP INT TERM

  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> ADVANCED >> ASSET >> DECRYPT / UNLOCK POLICY'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  shopt -s nullglob dotglob
  decrypt_policy_entries=("${ASSET_FOLDER}"/*)
  shopt -u nullglob dotglob
  if (( ${#decrypt_policy_entries[@]} == 0 )); then
    println "${FG_YELLOW}No policies available!${NC}"
    waitToProceed
    trap - EXIT HUP INT TERM
    _cntools_action_advanced_asset_decrypt_policy_secret_clear
    return 0
  fi
  println DEBUG 'Select policy to decrypt'
  if tput sc >/dev/null 2>&1; then decrypt_policy_terminal_saved=Y; fi
  if selectPolicy encrypted; then action_status=0; else action_status=$?; fi
  _cntools_action_advanced_asset_decrypt_policy_terminal_restore || action_status=70
  case "${action_status}" in
    0) ;;
    1) waitToProceed; action_status=0 ;;
    2) action_status=0 ;;
    *) action_status=70 ;;
  esac
  if [[ "${action_status}" != 0 || -z "${policy_name:-}" ]]; then
    trap - EXIT HUP INT TERM
    _cntools_action_advanced_asset_decrypt_policy_secret_clear
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return "${action_status}"
  fi
  if ! _cntools_action_advanced_asset_decrypt_policy_component_valid \
      "${policy_name}"; then
    _cntools_action_advanced_asset_decrypt_policy_handled_error \
      'selected policy failed security validation!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi
  selected_policy="${ASSET_FOLDER}/${policy_name}"
  policy_physical="$(cd -P -- "${selected_policy}" \
    >/dev/null 2>&1 && pwd -P)" || policy_physical=
  if ! _cntools_action_advanced_asset_decrypt_policy_directory_validate \
       "${selected_policy}" ||
     [[ "${policy_physical}" != \
        "${asset_root_physical}/${policy_name}" ]]; then
    _cntools_action_advanced_asset_decrypt_policy_handled_error \
      'selected policy failed security validation!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi

  decrypt_policy_lock="${ASSET_FOLDER}/.${policy_name}.cntools-decrypt.lock"
  if [[ -e "${decrypt_policy_lock}" || -L "${decrypt_policy_lock}" ]]; then
    _cntools_action_advanced_asset_decrypt_policy_handled_error \
      'selected policy is already being modified!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi
  if ! "${decrypt_policy_mkdir_path}" -m 0700 -- \
      "${decrypt_policy_lock}" >/dev/null 2>&1; then
    if [[ -e "${decrypt_policy_lock}" || -L "${decrypt_policy_lock}" ]]; then
      _cntools_action_advanced_asset_decrypt_policy_handled_error \
        'selected policy is already being modified!'
      action_status=$?
    else
      action_status=70
    fi
    trap - EXIT HUP INT TERM
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return "${action_status}"
  fi
  decrypt_policy_lock_acquired=Y
  if ! _cntools_action_advanced_asset_decrypt_policy_directory_validate \
      "${decrypt_policy_lock}"; then
    _cntools_action_advanced_asset_decrypt_policy_precommit_cleanup || true
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  fi

  shopt -s nullglob dotglob
  decrypt_policy_entries=("${selected_policy}"/*)
  shopt -u nullglob dotglob
  (( ${#decrypt_policy_entries[@]} <= 1024 )) || action_status=70
  _cntools_action_advanced_asset_decrypt_policy_sort_entries
  for entry in "${decrypt_policy_entries[@]}"; do
    leaf="${entry##*/}"
    _cntools_action_advanced_asset_decrypt_policy_component_valid "${leaf}" ||
      action_status=70
    [[ "${leaf}" != .cntools-policy-* ]] || action_status=70
    decrypt_policy_entry_mode=
    decrypt_policy_entry_size=
    decrypt_policy_entry_identity=
    decrypt_policy_entry_digest=
    _cntools_action_advanced_asset_decrypt_policy_file_read \
      "${entry}" decrypt_policy_entry || action_status=70
    _cntools_action_advanced_asset_decrypt_policy_hash \
      "${entry}" decrypt_policy_entry_digest || action_status=70
    decrypt_policy_entry_modes+=("${decrypt_policy_entry_mode}")
    decrypt_policy_entry_sizes+=("${decrypt_policy_entry_size}")
    decrypt_policy_entry_identities+=("${decrypt_policy_entry_identity}")
    decrypt_policy_entry_digests+=("${decrypt_policy_entry_digest}")
    total_size=$((total_size + ${decrypt_policy_entry_size:-0}))
    (( total_size <= 67108864 )) || action_status=70
    decrypt_policy_entry_immutable=N
    if [[ "${ENABLE_CHATTR}" == true ]]; then
      _cntools_action_advanced_asset_decrypt_policy_immutable_read \
        "${entry}" decrypt_policy_entry_immutable || action_status=70
    fi
    decrypt_policy_entry_immutables+=("${decrypt_policy_entry_immutable}")
    if [[ "${leaf}" == *.gpg ]]; then
      plain_leaf="${leaf%.gpg}"
      _cntools_action_advanced_asset_decrypt_policy_component_valid \
        "${plain_leaf}" || action_status=70
      [[ "${plain_leaf}" != *.gpg ]] || action_status=70
      plain_path="${selected_policy}/${plain_leaf}"
      [[ ! -e "${plain_path}" && ! -L "${plain_path}" ]] || action_status=70
      [[ "${decrypt_policy_entry_size:-0}" -ge 1 ]] || action_status=70
      decrypt_policy_cipher_paths+=("${entry}")
      decrypt_policy_cipher_identities+=("${decrypt_policy_entry_identity}")
      decrypt_policy_cipher_digests+=("${decrypt_policy_entry_digest}")
      decrypt_policy_plain_paths+=("${plain_path}")
    elif [[ -e "${entry}.gpg" || -L "${entry}.gpg" ]]; then
      action_status=70
    fi
  done
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_decrypt_policy_handled_error \
      'selected policy failed security validation!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi

  echo
  println DEBUG 'Removing write protection from all policy files'
  for entry in "${decrypt_policy_entries[@]}"; do
    println DEBUG "${entry}"
  done

  if (( ${#decrypt_policy_cipher_paths[@]} > 0 )); then
    echo
    println 'Decrypting GPG encrypted policy key'
    if ! getPasswordCust; then
      _cntools_action_advanced_asset_decrypt_policy_secret_clear
      if ! _cntools_action_advanced_asset_decrypt_policy_lock_release; then
        trap - EXIT HUP INT TERM
        _cntools_action_advanced_asset_decrypt_policy_validation_failure
        return 70
      fi
      println "\n\n"
      println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
      waitToProceed
      trap - EXIT HUP INT TERM
      return 0
    fi
    decrypt_policy_secret="${password-}"
    builtin unset password 2>/dev/null || true

    for (( cipher_index=0;
           cipher_index<${#decrypt_policy_cipher_paths[@]};
           cipher_index++ )); do
      temp="$("${decrypt_policy_mktemp_path}" \
        "${decrypt_policy_lock}/plain.${cipher_index}.XXXXXXXX")" ||
        action_status=70
      [[ "${action_status}" == 0 ]] || break
      decrypt_policy_temp_paths+=("${temp}")
      "${decrypt_policy_chmod_path}" 0600 "${temp}" \
        >/dev/null 2>&1 || { action_status=70; break; }
      if ! builtin printf '%s\n' "${decrypt_policy_secret}" | \
          "${decrypt_policy_gpg_path}" --decrypt --batch --yes --no-tty \
            --pinentry-mode loopback --passphrase-fd 0 --output "${temp}" \
            -- "${decrypt_policy_cipher_paths[cipher_index]}" \
            >/dev/null 2>&1; then
        action_status=1
        break
      fi
      decrypt_policy_temp_mode=
      decrypt_policy_temp_size=
      decrypt_policy_temp_identity=
      decrypt_policy_temp_digest=
      _cntools_action_advanced_asset_decrypt_policy_file_read \
        "${temp}" decrypt_policy_temp || action_status=70
      [[ "${decrypt_policy_temp_mode}" == 600 &&
         "${decrypt_policy_temp_size:-0}" -ge 1 ]] || action_status=70
      _cntools_action_advanced_asset_decrypt_policy_hash \
        "${temp}" decrypt_policy_temp_digest || action_status=70
      decrypt_policy_temp_identities+=("${decrypt_policy_temp_identity}")
      decrypt_policy_temp_digests+=("${decrypt_policy_temp_digest}")
      [[ "${action_status}" == 0 ]] || break
    done
    _cntools_action_advanced_asset_decrypt_policy_secret_clear
    if [[ "${action_status}" != 0 ]]; then
      if [[ "${action_status}" == 1 ]]; then
        _cntools_action_advanced_asset_decrypt_policy_handled_error \
          'failed to decrypt policy files; original encrypted policy was preserved!'
        action_status=$?
      else
        _cntools_action_advanced_asset_decrypt_policy_precommit_cleanup || true
        _cntools_action_advanced_asset_decrypt_policy_validation_failure
        return 70
      fi
      trap - EXIT HUP INT TERM
      return "${action_status}"
    fi
    for entry in "${decrypt_policy_cipher_paths[@]}"; do
      println DEBUG "${entry} successfully decrypted"
    done
  fi

  if ! _cntools_action_advanced_asset_decrypt_policy_inventory_same; then
    _cntools_action_advanced_asset_decrypt_policy_precommit_cleanup || true
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  fi

  for (( index=0; index<${#decrypt_policy_entries[@]}; index++ )); do
    entry="${decrypt_policy_entries[index]}"
    identity="${decrypt_policy_entry_identities[index]}"
    digest="${decrypt_policy_entry_digests[index]}"
    if [[ "${decrypt_policy_entry_immutables[index]}" == Y ]]; then
      decrypt_policy_immutable_changed_paths+=("${entry}")
      decrypt_policy_immutable_changed_identities+=("${identity}")
      if ! "${decrypt_policy_sudo_path}" "${decrypt_policy_chattr_path}" \
           -i -- "${entry}" >/dev/null 2>&1; then
        action_status=1
        break
      fi
      decrypt_policy_check_immutable=Y
      _cntools_action_advanced_asset_decrypt_policy_immutable_read \
        "${entry}" decrypt_policy_check_immutable || action_status=1
      [[ "${decrypt_policy_check_immutable}" == N ]] || action_status=1
    fi
    if [[ "${action_status}" == 0 &&
          "${decrypt_policy_entry_modes[index]}" != 600 ]]; then
      decrypt_policy_mode_changed_paths+=("${entry}")
      decrypt_policy_mode_changed_modes+=("${decrypt_policy_entry_modes[index]}")
      decrypt_policy_mode_changed_identities+=("${identity}")
      "${decrypt_policy_chmod_path}" 0600 "${entry}" \
        >/dev/null 2>&1 || action_status=1
    fi
    _cntools_action_advanced_asset_decrypt_policy_file_same \
      "${entry}" "${identity}" "${digest}" || action_status=1
    metadata="$(_cntools_action_advanced_asset_decrypt_policy_stat \
      "${entry}")" || action_status=1
    [[ "${metadata}" == *$'\t600\t'* ]] || action_status=1
    [[ "${action_status}" == 0 ]] || break
  done

  if [[ "${action_status}" == 0 ]]; then
    for (( cipher_index=0;
           cipher_index<${#decrypt_policy_temp_paths[@]};
           cipher_index++ )); do
      temp="${decrypt_policy_temp_paths[cipher_index]}"
      target="${decrypt_policy_plain_paths[cipher_index]}"
      identity="${decrypt_policy_temp_identities[cipher_index]}"
      digest="${decrypt_policy_temp_digests[cipher_index]}"
      [[ ! -e "${target}" && ! -L "${target}" ]] || {
        action_status=1; break;
      }
      if ! "${decrypt_policy_ln_path}" -- "${temp}" "${target}" \
           >/dev/null 2>&1; then
        action_status=1
        break
      fi
      decrypt_policy_published_paths+=("${target}")
      decrypt_policy_published_identities+=("${identity}")
      decrypt_policy_published_digests+=("${digest}")
      if ! "${decrypt_policy_rm_path}" -f -- "${temp}" \
           >/dev/null 2>&1; then
        action_status=1
        break
      fi
      decrypt_policy_temp_paths[cipher_index]=
      _cntools_action_advanced_asset_decrypt_policy_file_same \
        "${target}" "${identity}" "${digest}" || action_status=1
      decrypt_policy_target_mode=
      decrypt_policy_target_size=
      decrypt_policy_target_identity=
      _cntools_action_advanced_asset_decrypt_policy_file_read \
        "${target}" decrypt_policy_target || action_status=1
      [[ "${decrypt_policy_target_mode}" == 600 ]] || action_status=1
      [[ "${action_status}" == 0 ]] || break
    done
  fi

  if [[ "${action_status}" == 0 ]]; then
    for (( cipher_index=0;
           cipher_index<${#decrypt_policy_cipher_paths[@]};
           cipher_index++ )); do
      entry="${decrypt_policy_cipher_paths[cipher_index]}"
      identity="${decrypt_policy_cipher_identities[cipher_index]}"
      digest="${decrypt_policy_cipher_digests[cipher_index]}"
      backup="${decrypt_policy_lock}/cipher.${cipher_index}.backup"
      [[ ! -e "${backup}" && ! -L "${backup}" ]] || {
        action_status=1; break;
      }
      _cntools_action_advanced_asset_decrypt_policy_file_same \
        "${entry}" "${identity}" "${digest}" || { action_status=1; break; }
      if ! "${decrypt_policy_ln_path}" -- "${entry}" "${backup}" \
           >/dev/null 2>&1; then
        action_status=1
        break
      fi
      decrypt_policy_backup_paths+=("${backup}")
      if ! "${decrypt_policy_rm_path}" -f -- "${entry}" \
           >/dev/null 2>&1; then
        action_status=1
        break
      fi
      _cntools_action_advanced_asset_decrypt_policy_file_same \
        "${backup}" "${identity}" "${digest}" || action_status=1
      [[ ! -e "${entry}" && ! -L "${entry}" ]] || action_status=1
      [[ "${action_status}" == 0 ]] || break
    done
  fi

  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_decrypt_policy_handled_error \
      'failed to unlock/decrypt policy files; original encrypted policy was preserved!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi

  for (( cipher_index=0;
         cipher_index<${#decrypt_policy_plain_paths[@]};
         cipher_index++ )); do
    target="${decrypt_policy_plain_paths[cipher_index]}"
    identity="${decrypt_policy_temp_identities[cipher_index]}"
    digest="${decrypt_policy_temp_digests[cipher_index]}"
    _cntools_action_advanced_asset_decrypt_policy_file_same \
      "${target}" "${identity}" "${digest}" || action_status=70
    [[ ! -e "${decrypt_policy_cipher_paths[cipher_index]}" &&
       ! -L "${decrypt_policy_cipher_paths[cipher_index]}" ]] ||
      action_status=70
  done
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_decrypt_policy_precommit_cleanup || true
    _cntools_action_advanced_asset_decrypt_policy_validation_failure
    return 70
  fi
  # Replace every rollback-capable trap in one builtin before marking the
  # operation committed. The transition handler still rolls back if invoked
  # before the assignment, and can only perform bounded post-commit cleanup
  # after it.
  trap '_cntools_action_advanced_asset_decrypt_policy_commit_transition' \
    EXIT HUP INT TERM
  decrypt_policy_committed=Y
  filesUnlocked=${#decrypt_policy_entries[@]}
  keysDecrypted=${#decrypt_policy_cipher_paths[@]}
  if ! _cntools_action_advanced_asset_decrypt_policy_postcommit_cleanup; then
    decrypt_policy_postcommit_warning=Y
  fi
  trap - EXIT HUP INT TERM

  echo
  println "Policy decrypted : ${FG_GREEN}${policy_name}${NC}"
  println "Files unlocked   : ${FG_LBLUE}${filesUnlocked}${NC}"
  println "Files decrypted  : ${FG_LBLUE}${keysDecrypted}${NC}"
  if (( filesUnlocked != 0 || keysDecrypted != 0 )); then
    echo
    println DEBUG "${FG_YELLOW}Policy files are now unprotected${NC}"
    println DEBUG "Use 'ADVANCED >> ASSET >> ENCRYPT / LOCK POLICY' to re-lock"
  fi
  if [[ "${decrypt_policy_postcommit_warning}" == Y ]]; then
    println ERROR "\n${FG_YELLOW}WARN${NC}: policy decryption committed, but private cleanup was incomplete; the operation lock was retained."
  fi
  waitToProceed
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
