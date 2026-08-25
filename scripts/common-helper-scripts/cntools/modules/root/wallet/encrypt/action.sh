#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Stage 4 compatibility action for encrypting and locking one wallet.
# Both signing keys are staged before mutation. The original wallet remains
# recoverable until the validated encrypted form has crossed the commit point.

_cntools_action_wallet_encrypt_validation_failure() {
  builtin printf '%s\n' \
    'CNTools wallet encryption action failed validation.' >&2
  return 70
}

_cntools_action_wallet_encrypt_terminal_restore() {
  local failed=0

  if [[ "${wallet_encrypt_terminal_saved:-N}" == Y ]]; then
    tput rc >/dev/null 2>&1 || failed=1
    tput ed >/dev/null 2>&1 || failed=1
    wallet_encrypt_terminal_saved=N
  fi
  return "${failed}"
}

_cntools_action_wallet_encrypt_secret_clear() {
  wallet_encrypt_secret=
  builtin unset wallet_encrypt_secret password 2>/dev/null || true
}

_cntools_action_wallet_encrypt_stat() {
  local target="${1:-}" metadata=""

  [[ -n "${wallet_encrypt_stat_path:-}" ]] || return 1
  if metadata="$("${wallet_encrypt_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' "${target}" 2>/dev/null)"; then
    builtin printf '%s\n' "${metadata}"
    return 0
  fi
  "${wallet_encrypt_stat_path}" -c $'%u\t%a\t%h\t%s\t%d\t%i' \
    -- "${target}" 2>/dev/null
}

_cntools_action_wallet_encrypt_component_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_encrypt_file_read() {
  local target="${1:-}" metadata="" owner="" mode="" links="" size=""
  local device="" inode="" output_prefix="${2:-}"

  [[ "${output_prefix}" =~ ^wallet_encrypt_(entry|source|temp|cipher|backup)$ ]] ||
    return 1
  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_encrypt_stat \
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

_cntools_action_wallet_encrypt_directory_validate() {
  local target="${1:-}" metadata="" owner="" mode="" links="" size=""
  local device="" inode=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_encrypt_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ( "${mode}" == 700 || "${mode}" == 750 || "${mode}" == 755 ) &&
     "${links}" =~ ^[1-9][0-9]*$ && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]]
}

_cntools_action_wallet_encrypt_directory_identity() {
  local target="${1:-}" output_name="${2:-}" metadata=""
  local owner="" mode="" links="" size="" device="" inode=""

  [[ "${output_name}" =~ ^wallet_encrypt_(root|wallet|lock)_identity$ ]] ||
    return 1
  _cntools_action_wallet_encrypt_directory_validate "${target}" || return 1
  metadata="$(_cntools_action_wallet_encrypt_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  builtin printf -v "${output_name}" '%s:%s:%s' \
    "${device}" "${inode}" "${mode}"
}

_cntools_action_wallet_encrypt_directory_same() {
  local target="${1:-}" expected_identity="${2:-}" expected_mode="${3:-}"
  local metadata="" owner="" mode="" links="" size="" device="" inode=""

  [[ "${expected_identity}" =~ ^[0-9]+:[0-9]+:(700|750|755)$ &&
     "${expected_mode}" =~ ^7[015][015]$ ]] || return 1
  _cntools_action_wallet_encrypt_directory_validate "${target}" || return 1
  metadata="$(_cntools_action_wallet_encrypt_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == "${expected_mode}" &&
     "${device}:${inode}:${mode}" == "${expected_identity}" ]]
}

_cntools_action_wallet_encrypt_file_same() {
  local target="${1:-}" expected_identity="${2:-}"
  local expected_digest="${3:-}" allowed_links="${4:-1}" metadata=""
  local owner="" mode="" links="" size="" device="" inode="" digest=""

  [[ "${allowed_links}" == 1 || "${allowed_links}" == '1|2' ]] || return 1
  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_encrypt_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  [[ "${owner}" == "${EUID}" &&
     "${device}:${inode}" == "${expected_identity}" ]] || return 1
  if [[ "${allowed_links}" == 1 ]]; then
    [[ "${links}" == 1 ]] || return 1
  else
    [[ "${links}" == 1 || "${links}" == 2 ]] || return 1
  fi
  if [[ -n "${expected_digest}" ]]; then
    case "${wallet_encrypt_hash_kind:-}" in
      sha256sum)
        digest="$("${wallet_encrypt_hash_path}" "${target}" 2>/dev/null)" ||
          return 1
        digest="${digest%% *}"
        ;;
      shasum)
        digest="$("${wallet_encrypt_hash_path}" -a 256 \
          "${target}" 2>/dev/null)" || return 1
        digest="${digest%% *}"
        ;;
      *) return 1 ;;
    esac
    [[ "${digest,,}" == "${expected_digest}" ]] || return 1
  fi
}

_cntools_action_wallet_encrypt_immutable_read() {
  local target="${1:-}" output_name="${2:-}" raw="" flags=""

  [[ "${output_name}" =~ ^wallet_encrypt_(entry|cipher|check)_immutable$ &&
     -n "${wallet_encrypt_lsattr_path:-}" ]] || return 1
  raw="$("${wallet_encrypt_lsattr_path}" -d -- "${target}" 2>/dev/null)" ||
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

_cntools_action_wallet_encrypt_lock_release() {
  local failed=0

  if [[ "${wallet_encrypt_lock_acquired:-N}" == Y ]]; then
    [[ -n "${wallet_encrypt_lock:-}" ]] || failed=1
    if [[ "${failed}" == 0 ]] &&
       _cntools_action_wallet_encrypt_directory_same \
         "${wallet_encrypt_lock}" "${wallet_encrypt_lock_identity:-}" 700; then
      "${wallet_encrypt_rmdir_path}" -- "${wallet_encrypt_lock}" \
        >/dev/null 2>&1 || failed=1
    else
      failed=1
    fi
    if [[ ! -e "${wallet_encrypt_lock}" &&
          ! -L "${wallet_encrypt_lock}" ]]; then
      wallet_encrypt_lock_acquired=N
      wallet_encrypt_lock=
    else
      failed=1
    fi
  fi
  return "${failed}"
}

_cntools_action_wallet_encrypt_defer_signal() {
  wallet_encrypt_signal_pending=Y
}

_cntools_action_wallet_encrypt_resume_signal() {
  trap '_cntools_action_wallet_encrypt_signal' HUP INT TERM
  if [[ "${wallet_encrypt_signal_pending:-N}" == Y ]]; then
    _cntools_action_wallet_encrypt_signal
  fi
}

_cntools_action_wallet_encrypt_authority_same() {
  _cntools_action_wallet_encrypt_directory_same \
    "${WALLET_FOLDER}" "${wallet_encrypt_root_identity:-}" \
    "${wallet_encrypt_root_identity##*:}" &&
  _cntools_action_wallet_encrypt_directory_same \
    "${selected_wallet}" "${wallet_encrypt_wallet_identity:-}" \
    "${wallet_encrypt_wallet_identity##*:}" &&
  _cntools_action_wallet_encrypt_directory_same \
    "${wallet_encrypt_lock}" "${wallet_encrypt_lock_identity:-}" 700
}

_cntools_action_wallet_encrypt_temp_remove() {
  local target="${1:-}" expected_identity="${2:-}" metadata=""
  local owner="" mode="" links="" size="" device="" inode=""

  [[ -n "${wallet_encrypt_lock:-}" &&
     "${target}" == "${wallet_encrypt_lock}/cipher."* &&
     "${target#"${wallet_encrypt_lock}/"}" != */* ]] || return 1
  _cntools_action_wallet_encrypt_directory_same \
    "${wallet_encrypt_lock}" "${wallet_encrypt_lock_identity:-}" 700 ||
    return 1
  if [[ -L "${target}" ]]; then
    "${wallet_encrypt_rm_path}" -f -- "${target}" >/dev/null 2>&1
    return $?
  fi
  [[ -f "${target}" ]] || return 1
  metadata="$(_cntools_action_wallet_encrypt_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  [[ "${owner}" == "${EUID}" && "${device}:${inode}" == \
     "${expected_identity}" && "${links}" =~ ^[1-9][0-9]*$ ]] || return 1
  "${wallet_encrypt_rm_path}" -f -- "${target}" >/dev/null 2>&1
}

_cntools_action_wallet_encrypt_rollback() {
  local index=0 failed=0 target="" backup="" identity="" digest=""

  for (( index=${#wallet_encrypt_immutable_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_encrypt_immutable_changed_paths[index]}"
    identity="${wallet_encrypt_immutable_changed_identities[index]}"
    _cntools_action_wallet_encrypt_file_same \
      "${target}" "${identity}" || { failed=1; continue; }
    "${wallet_encrypt_sudo_path}" "${wallet_encrypt_chattr_path}" \
      -i -- "${target}" >/dev/null 2>&1 || failed=1
    wallet_encrypt_entry_immutable=Y
    _cntools_action_wallet_encrypt_immutable_read \
      "${target}" wallet_encrypt_entry_immutable || failed=1
    [[ "${wallet_encrypt_entry_immutable}" == N ]] || failed=1
  done
  wallet_encrypt_immutable_changed_paths=()
  wallet_encrypt_immutable_changed_identities=()

  for (( index=${#wallet_encrypt_mode_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_encrypt_mode_changed_paths[index]}"
    identity="${wallet_encrypt_mode_changed_identities[index]}"
    _cntools_action_wallet_encrypt_file_same \
      "${target}" "${identity}" || { failed=1; continue; }
    "${wallet_encrypt_chmod_path}" \
      "${wallet_encrypt_mode_changed_modes[index]}" "${target}" \
      >/dev/null 2>&1 || failed=1
  done
  wallet_encrypt_mode_changed_paths=()
  wallet_encrypt_mode_changed_modes=()
  wallet_encrypt_mode_changed_identities=()

  for (( index=${#wallet_encrypt_source_backup_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_encrypt_source_paths[index]}"
    backup="${wallet_encrypt_source_backup_paths[index]}"
    identity="${wallet_encrypt_source_identities[index]}"
    digest="${wallet_encrypt_source_digests[index]}"
    if [[ -e "${backup}" || -L "${backup}" ]]; then
      if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        if _cntools_action_wallet_encrypt_file_same \
             "${backup}" "${identity}" "${digest}"; then
          "${wallet_encrypt_ln_path}" -- "${backup}" "${target}" \
            >/dev/null 2>&1 || true
        fi
        if [[ -e "${target}" && ! -L "${target}" ]] &&
           _cntools_action_wallet_encrypt_file_same \
             "${target}" "${identity}" "${digest}" '1|2' &&
           _cntools_action_wallet_encrypt_file_same \
             "${backup}" "${identity}" "${digest}" '1|2'; then
          "${wallet_encrypt_rm_path}" -f -- "${backup}" \
            >/dev/null 2>&1 || true
          [[ ! -e "${backup}" && ! -L "${backup}" ]] &&
            _cntools_action_wallet_encrypt_file_same \
              "${target}" "${identity}" "${digest}" || failed=1
        else
          failed=1
        fi
      elif _cntools_action_wallet_encrypt_file_same \
             "${target}" "${identity}" "${digest}" '1|2' &&
           _cntools_action_wallet_encrypt_file_same \
             "${backup}" "${identity}" "${digest}" '1|2'; then
        "${wallet_encrypt_rm_path}" -f -- "${backup}" \
          >/dev/null 2>&1 || true
        [[ ! -e "${backup}" && ! -L "${backup}" ]] &&
          _cntools_action_wallet_encrypt_file_same \
            "${target}" "${identity}" "${digest}" || failed=1
      else
        failed=1
      fi
    elif [[ ! -e "${target}" && ! -L "${target}" ]]; then
      failed=1
    fi
  done
  wallet_encrypt_source_backup_paths=()

  for (( index=${#wallet_encrypt_published_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_encrypt_published_paths[index]}"
    identity="${wallet_encrypt_published_identities[index]}"
    digest="${wallet_encrypt_published_digests[index]}"
    if [[ -e "${target}" || -L "${target}" ]]; then
      _cntools_action_wallet_encrypt_file_same \
        "${target}" "${identity}" "${digest}" '1|2' || {
          failed=1
          continue
        }
      "${wallet_encrypt_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || failed=1
    fi
  done
  wallet_encrypt_published_paths=()
  wallet_encrypt_published_identities=()
  wallet_encrypt_published_digests=()

  for (( index=${#wallet_encrypt_temp_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_encrypt_temp_paths[index]}"
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      _cntools_action_wallet_encrypt_temp_remove \
        "${target}" "${wallet_encrypt_temp_identities[index]:-}" || failed=1
    fi
  done
  wallet_encrypt_temp_paths=()
  return "${failed}"
}

_cntools_action_wallet_encrypt_precommit_cleanup() {
  local failed=0

  # Cleanup is one non-reentrant critical section. A second signal must not
  # interrupt restoration midway or bypass the fixed status-70 boundary.
  trap - EXIT
  trap '' HUP INT TERM
  _cntools_action_wallet_encrypt_secret_clear
  _cntools_action_wallet_encrypt_terminal_restore || failed=1
  _cntools_action_wallet_encrypt_rollback || failed=1
  _cntools_action_wallet_encrypt_lock_release || failed=1
  return "${failed}"
}

_cntools_action_wallet_encrypt_signal() {
  _cntools_action_wallet_encrypt_precommit_cleanup >/dev/null 2>&1 || true
  _cntools_action_wallet_encrypt_validation_failure
  exit 70
}

_cntools_action_wallet_encrypt_handled_error() {
  local message="${1:-}" failed=0

  # Disable all precommit traps before cleanup so an asynchronous signal
  # cannot re-enter rollback or race the fixed handled outcome.
  _cntools_action_wallet_encrypt_precommit_cleanup || failed=1
  if [[ "${failed}" != 0 ]]; then
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi
  trap - HUP INT TERM
  println ERROR "\n${FG_RED}ERROR${NC}: ${message}"
  waitToProceed
  return 0
}

_cntools_action_wallet_encrypt_postcommit_cleanup() {
  local index=0 failed=0 target="" identity="" digest=""

  _cntools_action_wallet_encrypt_secret_clear
  for (( index=${#wallet_encrypt_source_backup_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_encrypt_source_backup_paths[index]}"
    [[ -e "${target}" || -L "${target}" ]] || continue
    identity="${wallet_encrypt_source_identities[index]:-}"
    digest="${wallet_encrypt_source_digests[index]:-}"
    _cntools_action_wallet_encrypt_file_same \
      "${target}" "${identity}" "${digest}" || {
        failed=1
        continue
      }
    "${wallet_encrypt_rm_path}" -f -- "${target}" \
      >/dev/null 2>&1 || failed=1
    [[ ! -e "${target}" && ! -L "${target}" ]] || failed=1
  done
  for (( index=${#wallet_encrypt_temp_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_encrypt_temp_paths[index]}"
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      _cntools_action_wallet_encrypt_temp_remove \
        "${target}" "${wallet_encrypt_temp_identities[index]:-}" || failed=1
    fi
  done
  if [[ "${failed}" == 0 ]]; then
    wallet_encrypt_source_backup_paths=()
    wallet_encrypt_temp_paths=()
    _cntools_action_wallet_encrypt_lock_release || failed=1
  fi
  return "${failed}"
}

_cntools_action_wallet_encrypt_commit_transition() {
  local cleanup_failed=0

  trap - EXIT
  trap '' HUP INT TERM
  if [[ "${wallet_encrypt_committed:-N}" == Y ]]; then
    _cntools_action_wallet_encrypt_postcommit_cleanup || cleanup_failed=1
    if [[ "${cleanup_failed}" == 0 ]]; then
      builtin printf '%s\n' \
        'CNTools wallet encryption committed; interrupted during post-commit cleanup.' >&2
    else
      builtin printf '%s\n' \
        'CNTools wallet encryption committed; private cleanup is incomplete and the operation lock was retained.' >&2
    fi
    exit 0
  fi
  _cntools_action_wallet_encrypt_precommit_cleanup >/dev/null 2>&1 || true
  _cntools_action_wallet_encrypt_validation_failure
  exit 70
}

_cntools_action_wallet_encrypt_postcommit_signal() {
  trap - EXIT
  trap '' HUP INT TERM
  _cntools_action_wallet_encrypt_secret_clear
  if [[ -n "${wallet_encrypt_lock:-}" &&
        ( -e "${wallet_encrypt_lock}" || -L "${wallet_encrypt_lock}" ) ]]; then
    builtin printf '%s\n' \
      'CNTools wallet encryption committed; interrupted after commit and private cleanup is incomplete.' >&2
  else
    builtin printf '%s\n' \
      'CNTools wallet encryption committed; interrupted after commit.' >&2
  fi
  exit 0
}

_cntools_action_wallet_encrypt_sort_entries() {
  local index=0 scan=0 value=""

  for (( index=1; index<${#wallet_encrypt_entries[@]}; index++ )); do
    value="${wallet_encrypt_entries[index]}"
    scan=$((index - 1))
    while (( scan >= 0 )) &&
      [[ "${wallet_encrypt_entries[scan]}" > "${value}" ]]; do
      wallet_encrypt_entries[scan + 1]="${wallet_encrypt_entries[scan]}"
      scan=$((scan - 1))
    done
    wallet_encrypt_entries[scan + 1]="${value}"
  done
}

_cntools_action_wallet_encrypt_inventory_same() {
  local entry="" value="" scan=0 index=0 metadata="" digest=""
  local owner="" mode="" links="" size="" device="" inode=""
  local -a discovered=() current=()

  shopt -s nullglob dotglob
  discovered=("${selected_wallet}"/*)
  shopt -u nullglob dotglob
  for entry in "${discovered[@]}"; do
    current+=("${entry}")
  done
  (( ${#current[@]} == ${#wallet_encrypt_entries[@]} )) || return 1
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
    [[ "${entry}" == "${wallet_encrypt_entries[index]}" ]] || return 1
    metadata="$(_cntools_action_wallet_encrypt_stat \
      "${entry}")" || return 1
    IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
      return 1
    mode="${mode#0}"
    [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
       "${mode}" == "${wallet_encrypt_entry_modes[index]}" &&
       "${size}" == "${wallet_encrypt_entry_sizes[index]}" &&
       "${device}:${inode}" == \
         "${wallet_encrypt_entry_identities[index]}" ]] || return 1
    case "${wallet_encrypt_hash_kind}" in
      sha256sum)
        digest="$("${wallet_encrypt_hash_path}" "${entry}" 2>/dev/null)" ||
          return 1
        digest="${digest%% *}"
        ;;
      shasum)
        digest="$("${wallet_encrypt_hash_path}" -a 256 \
          "${entry}" 2>/dev/null)" || return 1
        digest="${digest%% *}"
        ;;
    esac
    [[ "${digest,,}" == "${wallet_encrypt_entry_digests[index]}" ]] ||
      return 1
  done
}

_cntools_action_wallet_encrypt_hash() {
  local target="${1:-}" output_name="${2:-}" digest=""

  [[ "${output_name}" =~ ^wallet_encrypt_(entry|source|temp|cipher|backup)_digest$ ]] ||
    return 1
  case "${wallet_encrypt_hash_kind:-}" in
    sha256sum)
      digest="$("${wallet_encrypt_hash_path}" "${target}" 2>/dev/null)" ||
        return 1
      digest="${digest%% *}"
      ;;
    shasum)
      digest="$("${wallet_encrypt_hash_path}" -a 256 \
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
  local wallet_root_physical="" wallet_physical="" selected_wallet=""
  local wallet_encrypt_private_parent="" wallet_encrypt_root_identity=""
  local wallet_encrypt_wallet_identity="" wallet_encrypt_lock_identity=""
  local entry="" leaf="" metadata="" owner="" mode="" links="" size=""
  local device="" inode="" index=0 source_index=0 total_size=0
  local action_status=0 operation_status=0 current_mode=""
  local wallet_encrypt_entry_mode="" wallet_encrypt_entry_size=""
  local wallet_encrypt_entry_identity="" wallet_encrypt_entry_digest=""
  local wallet_encrypt_source_mode="" wallet_encrypt_source_size=""
  local wallet_encrypt_source_identity="" wallet_encrypt_source_digest=""
  local wallet_encrypt_temp_mode="" wallet_encrypt_temp_size=""
  local wallet_encrypt_temp_identity="" wallet_encrypt_temp_digest=""
  local wallet_encrypt_cipher_mode="" wallet_encrypt_cipher_size=""
  local wallet_encrypt_cipher_identity="" wallet_encrypt_cipher_digest=""
  local wallet_encrypt_backup_mode="" wallet_encrypt_backup_size=""
  local wallet_encrypt_backup_identity="" wallet_encrypt_backup_digest=""
  local wallet_encrypt_entry_immutable=N wallet_encrypt_check_immutable=N
  local wallet_encrypt_secret="" wallet_encrypt_terminal_saved=N
  local wallet_encrypt_stat_path="" wallet_encrypt_chmod_path=""
  local wallet_encrypt_rm_path="" wallet_encrypt_ln_path=""
  local wallet_encrypt_mktemp_path="" wallet_encrypt_mkdir_path=""
  local wallet_encrypt_rmdir_path="" wallet_encrypt_hash_path=""
  local wallet_encrypt_hash_kind="" wallet_encrypt_gpg_path=""
  local wallet_encrypt_lsattr_path="" wallet_encrypt_chattr_path=""
  local wallet_encrypt_sudo_path="" wallet_encrypt_lock=""
  local wallet_encrypt_lock_acquired=N wallet_encrypt_committed=N
  local wallet_encrypt_signal_pending=N wallet_encrypt_postcommit_warning=N
  local temp="" target="" backup="" identity="" digest="" gpg_status=0
  local files_locked=0 keys_encrypted=0 cleanup_status=0
  local -a wallet_encrypt_entries=()
  local -a wallet_encrypt_entry_modes=() wallet_encrypt_entry_sizes=()
  local -a wallet_encrypt_entry_identities=() wallet_encrypt_entry_digests=()
  local -a wallet_encrypt_entry_immutables=()
  local -a wallet_encrypt_source_paths=() wallet_encrypt_source_indexes=()
  local -a wallet_encrypt_source_identities=() wallet_encrypt_source_digests=()
  local -a wallet_encrypt_temp_paths=() wallet_encrypt_temp_identities=()
  local -a wallet_encrypt_temp_digests=()
  local -a wallet_encrypt_cipher_paths=() wallet_encrypt_cipher_identities=()
  local -a wallet_encrypt_cipher_digests=()
  local -a wallet_encrypt_published_paths=()
  local -a wallet_encrypt_published_identities=()
  local -a wallet_encrypt_published_digests=()
  local -a wallet_encrypt_source_backup_paths=()
  local -a wallet_encrypt_mode_changed_paths=()
  local -a wallet_encrypt_mode_changed_modes=()
  local -a wallet_encrypt_mode_changed_identities=()
  local -a wallet_encrypt_immutable_changed_paths=()
  local -a wallet_encrypt_immutable_changed_identities=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate \
       >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F selectWallet >/dev/null 2>&1 ||
     ! builtin declare -F getPasswordCust >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1; then
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  [[ "${context_mode}" =~ ^(local|light|offline)$ &&
     "${CNTOOLS_MODE,,}" == "${context_mode}" &&
     ( "${ENABLE_CHATTR:-}" == true ||
       "${ENABLE_CHATTR:-}" == false ) &&
     "${WALLET_FOLDER:-}" == /* &&
     "${WALLET_PAY_SK_FILENAME:-}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${WALLET_STAKE_SK_FILENAME:-}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${WALLET_PAY_SK_FILENAME}" != "${WALLET_STAKE_SK_FILENAME}" &&
     "${WALLET_PAY_SK_FILENAME}" != *.gpg &&
     "${WALLET_STAKE_SK_FILENAME}" != *.gpg &&
     "${WALLET_PAY_SK_FILENAME}" != *.addr &&
     "${WALLET_STAKE_SK_FILENAME}" != *.addr ]] || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  if [[ "${WALLET_FOLDER}" == *\\* ||
        "${WALLET_FOLDER}" =~ [[:cntrl:]] ]]; then
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi
  _cntools_registry_tool_path stat wallet_encrypt_stat_path || action_status=70
  for entry in chmod rm ln mktemp mkdir rmdir; do
    case "${entry}" in
      chmod) _cntools_registry_tool_path chmod wallet_encrypt_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_encrypt_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln wallet_encrypt_ln_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp wallet_encrypt_mktemp_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir wallet_encrypt_mkdir_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir wallet_encrypt_rmdir_path || action_status=70 ;;
    esac
  done
  if _cntools_registry_tool_path sha256sum wallet_encrypt_hash_path; then
    wallet_encrypt_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum wallet_encrypt_hash_path; then
    wallet_encrypt_hash_kind=shasum
  else
    action_status=70
  fi
  if [[ "${ENABLE_CHATTR}" == true ]]; then
    _cntools_registry_tool_path lsattr wallet_encrypt_lsattr_path || action_status=70
    _cntools_registry_tool_path chattr wallet_encrypt_chattr_path || action_status=70
    _cntools_registry_tool_path sudo wallet_encrypt_sudo_path || action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  _cntools_action_wallet_encrypt_directory_validate "${WALLET_FOLDER}" || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  wallet_root_physical="$(cd -P -- "${WALLET_FOLDER}" \
    >/dev/null 2>&1 && pwd -P)" || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  [[ "${wallet_root_physical}" == "${WALLET_FOLDER}" ]] || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  wallet_encrypt_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${wallet_encrypt_private_parent}" || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  [[ "${wallet_root_physical}" != "${wallet_encrypt_private_parent}" &&
     "${wallet_root_physical}" != "${wallet_encrypt_private_parent}/"* &&
     "${wallet_encrypt_private_parent}" != "${wallet_root_physical}/"* ]] || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }
  _cntools_action_wallet_encrypt_directory_identity \
    "${WALLET_FOLDER}" wallet_encrypt_root_identity || {
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }

  trap '_cntools_action_wallet_encrypt_precommit_cleanup' EXIT
  trap '_cntools_action_wallet_encrypt_signal' HUP INT TERM

  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> WALLET >> ENCRYPT'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  shopt -s nullglob dotglob
  wallet_encrypt_entries=("${WALLET_FOLDER}"/*)
  shopt -u nullglob dotglob
  if (( ${#wallet_encrypt_entries[@]} == 0 )); then
    echo
    println "${FG_YELLOW}No wallets available!${NC}"
    trap - EXIT HUP INT TERM
    waitToProceed
    _cntools_action_wallet_encrypt_secret_clear
    return 0
  fi
  println DEBUG 'Select wallet to encrypt'
  builtin unset wallet_name 2>/dev/null || true
  if tput sc >/dev/null 2>&1; then wallet_encrypt_terminal_saved=Y; fi
  if selectWallet encrypted; then action_status=0; else action_status=$?; fi
  _cntools_action_wallet_encrypt_terminal_restore || action_status=70
  case "${action_status}" in
    0) ;;
    1)
      trap - EXIT HUP INT TERM
      waitToProceed
      _cntools_action_wallet_encrypt_secret_clear
      return 0
      ;;
    2)
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_encrypt_secret_clear
      return 0
      ;;
    *)
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_encrypt_secret_clear
      _cntools_action_wallet_encrypt_validation_failure
      return 70
      ;;
  esac
  if [[ -z "${wallet_name:-}" ]] ||
     ! _cntools_action_wallet_encrypt_component_valid "${wallet_name}"; then
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi
  selected_wallet="${WALLET_FOLDER}/${wallet_name}"
  wallet_physical="$(cd -P -- "${selected_wallet}" \
    >/dev/null 2>&1 && pwd -P)" || wallet_physical=
  if ! _cntools_action_wallet_encrypt_directory_validate \
       "${selected_wallet}" ||
     [[ "${wallet_physical}" != \
        "${wallet_root_physical}/${wallet_name}" ]]; then
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi
  _cntools_action_wallet_encrypt_directory_identity \
    "${selected_wallet}" wallet_encrypt_wallet_identity || {
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }

  wallet_encrypt_lock="${WALLET_FOLDER}/.${wallet_name}.cntools-encrypt.lock"
  if [[ -e "${wallet_encrypt_lock}" || -L "${wallet_encrypt_lock}" ]]; then
    _cntools_action_wallet_encrypt_handled_error \
      'selected wallet is already being modified!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi
  trap '_cntools_action_wallet_encrypt_defer_signal' HUP INT TERM
  if ! "${wallet_encrypt_mkdir_path}" -m 0700 -- \
      "${wallet_encrypt_lock}" >/dev/null 2>&1; then
    trap '_cntools_action_wallet_encrypt_signal' HUP INT TERM
    if [[ -e "${wallet_encrypt_lock}" || -L "${wallet_encrypt_lock}" ]]; then
      _cntools_action_wallet_encrypt_handled_error \
        'selected wallet is already being modified!'
      action_status=$?
    else
      action_status=70
    fi
    trap - EXIT HUP INT TERM
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_wallet_encrypt_validation_failure
    return "${action_status}"
  fi
  wallet_encrypt_lock_acquired=Y
  if ! _cntools_action_wallet_encrypt_directory_same \
       "${WALLET_FOLDER}" "${wallet_encrypt_root_identity}" \
       "${wallet_encrypt_root_identity##*:}" ||
     ! _cntools_action_wallet_encrypt_directory_identity \
       "${wallet_encrypt_lock}" wallet_encrypt_lock_identity ||
     ! _cntools_action_wallet_encrypt_directory_same \
       "${wallet_encrypt_lock}" "${wallet_encrypt_lock_identity}" 700; then
    trap '_cntools_action_wallet_encrypt_signal' HUP INT TERM
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi
  trap '_cntools_action_wallet_encrypt_signal' HUP INT TERM
  if [[ "${wallet_encrypt_signal_pending}" == Y ]]; then
    _cntools_action_wallet_encrypt_signal
  fi

  shopt -s nullglob dotglob
  wallet_encrypt_entries=("${selected_wallet}"/*)
  shopt -u nullglob dotglob
  (( ${#wallet_encrypt_entries[@]} <= 1024 )) || action_status=70
  _cntools_action_wallet_encrypt_sort_entries
  for entry in "${wallet_encrypt_entries[@]}"; do
    [[ "${action_status}" == 0 ]] || break
    leaf="${entry##*/}"
    if ! _cntools_action_wallet_encrypt_component_valid "${leaf}" ||
       [[ "${leaf}" == .cntools-wallet-* ]]; then
      action_status=70
      break
    fi
    wallet_encrypt_entry_mode=
    wallet_encrypt_entry_size=
    wallet_encrypt_entry_identity=
    wallet_encrypt_entry_digest=
    if ! _cntools_action_wallet_encrypt_file_read \
         "${entry}" wallet_encrypt_entry ||
       ! _cntools_action_wallet_encrypt_hash \
         "${entry}" wallet_encrypt_entry_digest; then
      action_status=70
      break
    fi
    wallet_encrypt_entry_modes+=("${wallet_encrypt_entry_mode}")
    wallet_encrypt_entry_sizes+=("${wallet_encrypt_entry_size}")
    wallet_encrypt_entry_identities+=("${wallet_encrypt_entry_identity}")
    wallet_encrypt_entry_digests+=("${wallet_encrypt_entry_digest}")
    if (( wallet_encrypt_entry_size > 67108864 - total_size )); then
      action_status=70
      break
    fi
    total_size=$((total_size + wallet_encrypt_entry_size))
    wallet_encrypt_entry_immutable=N
    if [[ "${ENABLE_CHATTR}" == true ]]; then
      _cntools_action_wallet_encrypt_immutable_read \
        "${entry}" wallet_encrypt_entry_immutable || action_status=70
      if [[ "${wallet_encrypt_entry_immutable}" == Y &&
            "${wallet_encrypt_entry_mode}" != 400 &&
            "${leaf}" != *.addr ]]; then
        action_status=70
      fi
    fi
    wallet_encrypt_entry_immutables+=("${wallet_encrypt_entry_immutable}")
    [[ "${leaf}" == *.addr ]] || files_locked=$((files_locked + 1))
  done
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi
  for entry in "${wallet_encrypt_entries[@]}"; do
    if [[ "${entry}" == *.gpg ]]; then
      echo
      println "${FG_YELLOW}NOTE${NC}: found GPG encrypted files in folder, please decrypt/unlock wallet files before encrypting"
      _cntools_action_wallet_encrypt_precommit_cleanup || action_status=70
      [[ "${action_status}" == 0 ]] || {
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_encrypt_validation_failure
        return 70
      }
      trap - HUP INT TERM
      waitToProceed
      trap - EXIT HUP INT TERM
      return 0
    fi
  done
  wallet_encrypt_source_paths=(
    "${selected_wallet}/${WALLET_PAY_SK_FILENAME}"
    "${selected_wallet}/${WALLET_STAKE_SK_FILENAME}"
  )
  for entry in "${wallet_encrypt_source_paths[@]}"; do
    source_index=-1
    for (( index=0; index<${#wallet_encrypt_entries[@]}; index++ )); do
      if [[ "${wallet_encrypt_entries[index]}" == "${entry}" ]]; then
        source_index="${index}"
        break
      fi
    done
    if (( source_index < 0 )) ||
       [[ "${wallet_encrypt_entry_sizes[source_index]:-0}" -lt 1 ||
          "${wallet_encrypt_entry_immutables[source_index]:-N}" == Y ]]; then
      _cntools_action_wallet_encrypt_handled_error \
        'wallet signing keys are missing or unsafe!'
      action_status=$?
      trap - EXIT HUP INT TERM
      return "${action_status}"
    fi
    wallet_encrypt_source_indexes+=("${source_index}")
    wallet_encrypt_source_identities+=(
      "${wallet_encrypt_entry_identities[source_index]}")
    wallet_encrypt_source_digests+=(
      "${wallet_encrypt_entry_digests[source_index]}")
  done

  echo
  println 'Encrypting sensitive wallet keys with GPG'
  echo
  if ! getPasswordCust confirm; then
    _cntools_action_wallet_encrypt_precommit_cleanup || action_status=70
    [[ "${action_status}" == 0 ]] || {
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_encrypt_validation_failure
      return 70
    }
    trap - HUP INT TERM
    println '\n\n'
    println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
    waitToProceed
    trap - EXIT HUP INT TERM
    return 0
  fi
  wallet_encrypt_secret="${password-}"
  builtin unset password 2>/dev/null || true
  if (( ${#wallet_encrypt_secret} < 8 ||
        ${#wallet_encrypt_secret} > 1024 )); then
    _cntools_action_wallet_encrypt_secret_clear
    _cntools_action_wallet_encrypt_handled_error \
      'password input failed validation!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi
  _cntools_registry_tool_path gpg wallet_encrypt_gpg_path || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_encrypt_secret_clear
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  }

  umask 077
  for (( source_index=0;
         source_index<${#wallet_encrypt_source_paths[@]};
         source_index++ )); do
    entry="${wallet_encrypt_source_paths[source_index]}"
    trap '_cntools_action_wallet_encrypt_defer_signal' HUP INT TERM
    temp="$("${wallet_encrypt_mktemp_path}" \
      "${wallet_encrypt_lock}/cipher.${source_index}.XXXXXXXX" 2>/dev/null)" ||
      action_status=70
    if [[ "${temp}" == "${wallet_encrypt_lock}/cipher.${source_index}."* &&
          "${temp#"${wallet_encrypt_lock}/"}" != */* &&
          ( -e "${temp}" || -L "${temp}" ) ]]; then
      wallet_encrypt_temp_paths+=("${temp}")
      wallet_encrypt_temp_mode=
      wallet_encrypt_temp_size=
      wallet_encrypt_temp_identity=
      _cntools_action_wallet_encrypt_file_read \
        "${temp}" wallet_encrypt_temp || action_status=70
      wallet_encrypt_temp_identities+=("${wallet_encrypt_temp_identity}")
      wallet_encrypt_temp_digests+=("")
    else
      action_status=70
    fi
    _cntools_action_wallet_encrypt_resume_signal
    [[ "${action_status}" == 0 ]] || break
    "${wallet_encrypt_chmod_path}" 0600 "${temp}" \
      >/dev/null 2>&1 || { action_status=70; break; }
    gpg_status=0
    builtin printf '%s\n' "${wallet_encrypt_secret}" | \
      "${wallet_encrypt_gpg_path}" --symmetric --yes --batch --no-tty \
        --pinentry-mode loopback --cipher-algo AES256 --passphrase-fd 0 \
        --output "${temp}" -- "${entry}" >/dev/null 2>&1 || gpg_status=$?
    if [[ "${gpg_status}" != 0 ]]; then
      action_status=1
      break
    fi
    identity="${wallet_encrypt_temp_identities[source_index]}"
    wallet_encrypt_temp_mode=
    wallet_encrypt_temp_size=
    wallet_encrypt_temp_identity=
    wallet_encrypt_temp_digest=
    _cntools_action_wallet_encrypt_file_read \
      "${temp}" wallet_encrypt_temp || action_status=70
    [[ "${wallet_encrypt_temp_identity}" == "${identity}" &&
       "${wallet_encrypt_temp_mode}" == 600 &&
       "${wallet_encrypt_temp_size:-0}" -ge 1 ]] || action_status=70
    _cntools_action_wallet_encrypt_hash \
      "${temp}" wallet_encrypt_temp_digest || action_status=70
    wallet_encrypt_temp_digests[source_index]="${wallet_encrypt_temp_digest}"
    [[ "${action_status}" == 0 ]] || break
  done
  _cntools_action_wallet_encrypt_secret_clear
  if [[ "${action_status}" != 0 ]]; then
    if [[ "${action_status}" == 1 ]]; then
      _cntools_action_wallet_encrypt_handled_error \
        'failed to encrypt wallet signing keys; original wallet was preserved!'
      action_status=$?
    else
      _cntools_action_wallet_encrypt_precommit_cleanup || true
      _cntools_action_wallet_encrypt_validation_failure
      action_status=70
    fi
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi

  if ! _cntools_action_wallet_encrypt_authority_same ||
     ! _cntools_action_wallet_encrypt_inventory_same; then
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi

  for (( source_index=0;
         source_index<${#wallet_encrypt_source_paths[@]};
         source_index++ )); do
    if ! _cntools_action_wallet_encrypt_authority_same; then
      action_status=70
      break
    fi
    temp="${wallet_encrypt_temp_paths[source_index]}"
    target="${wallet_encrypt_source_paths[source_index]}.gpg"
    identity="${wallet_encrypt_temp_identities[source_index]}"
    digest="${wallet_encrypt_temp_digests[source_index]}"
    [[ ! -e "${target}" && ! -L "${target}" ]] || {
      action_status=70
      break
    }
    # Register the exact possible side effect before invoking ln so a signal
    # after link creation cannot strand an untracked ciphertext.
    wallet_encrypt_published_paths+=("${target}")
    wallet_encrypt_published_identities+=("${identity}")
    wallet_encrypt_published_digests+=("${digest}")
    operation_status=0
    "${wallet_encrypt_ln_path}" -- "${temp}" "${target}" \
      >/dev/null 2>&1 || operation_status=$?
    if [[ -e "${target}" || -L "${target}" ]]; then
      if _cntools_action_wallet_encrypt_file_same \
           "${target}" "${identity}" "${digest}" '1|2'; then
        wallet_encrypt_cipher_paths+=("${target}")
        wallet_encrypt_cipher_identities+=("${identity}")
        wallet_encrypt_cipher_digests+=("${digest}")
        if [[ "${operation_status}" != 0 ]]; then
          action_status=1
          break
        fi
      else
        action_status=70
        break
      fi
    else
      [[ "${operation_status}" != 0 ]] || action_status=70
      [[ "${action_status}" != 0 ]] || action_status=1
      break
    fi
    operation_status=0
    "${wallet_encrypt_rm_path}" -f -- "${temp}" \
      >/dev/null 2>&1 || operation_status=$?
    if [[ ! -e "${temp}" && ! -L "${temp}" ]]; then
      wallet_encrypt_temp_paths[source_index]=
      if _cntools_action_wallet_encrypt_file_same \
           "${target}" "${identity}" "${digest}"; then
        [[ "${operation_status}" == 0 ]] || action_status=1
      else
        action_status=70
      fi
    elif [[ "${operation_status}" != 0 ]] &&
         _cntools_action_wallet_encrypt_file_same \
           "${temp}" "${identity}" "${digest}" '1|2' &&
         _cntools_action_wallet_encrypt_file_same \
           "${target}" "${identity}" "${digest}" '1|2'; then
      action_status=1
    else
      action_status=70
    fi
    [[ "${action_status}" == 0 ]] || break
  done
  if [[ "${action_status}" != 0 ]]; then
    if [[ "${action_status}" == 1 ]]; then
      _cntools_action_wallet_encrypt_handled_error \
        'failed to stage encrypted wallet keys; original wallet was preserved!'
      action_status=$?
      trap - EXIT HUP INT TERM
      return "${action_status}"
    fi
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi

  # Lock all non-address, non-source leaves. Sources remain untouched until
  # both encrypted outputs and every other final lock have been proven.
  for (( index=0; index<${#wallet_encrypt_entries[@]}; index++ )); do
    if ! _cntools_action_wallet_encrypt_authority_same; then
      action_status=70
      break
    fi
    entry="${wallet_encrypt_entries[index]}"
    leaf="${entry##*/}"
    [[ "${leaf}" == *.addr ]] && continue
    if [[ "${entry}" == "${wallet_encrypt_source_paths[0]}" ||
          "${entry}" == "${wallet_encrypt_source_paths[1]}" ]]; then
      continue
    fi
    identity="${wallet_encrypt_entry_identities[index]}"
    digest="${wallet_encrypt_entry_digests[index]}"
    if [[ "${wallet_encrypt_entry_modes[index]}" != 400 ]]; then
      trap '_cntools_action_wallet_encrypt_defer_signal' HUP INT TERM
      wallet_encrypt_mode_changed_paths+=("${entry}")
      wallet_encrypt_mode_changed_modes+=("${wallet_encrypt_entry_modes[index]}")
      wallet_encrypt_mode_changed_identities+=("${identity}")
      operation_status=0
      "${wallet_encrypt_chmod_path}" 0400 "${entry}" \
        >/dev/null 2>&1 || operation_status=$?
      metadata="$(_cntools_action_wallet_encrypt_stat "${entry}")" ||
        action_status=70
      if [[ "${action_status}" == 0 ]]; then
        IFS=$'\t' read -r owner current_mode links size device inode \
          <<< "${metadata}" || action_status=70
        current_mode="${current_mode#0}"
      fi
      if [[ "${action_status}" == 0 && "${current_mode}" == 400 ]]; then
        [[ "${operation_status}" == 0 ]] || action_status=1
      elif [[ "${action_status}" == 0 &&
              "${current_mode}" == "${wallet_encrypt_entry_modes[index]}" &&
              "${operation_status}" != 0 ]]; then
        action_status=1
      else
        action_status=70
      fi
      _cntools_action_wallet_encrypt_resume_signal
    fi
    if [[ "${action_status}" == 0 && "${ENABLE_CHATTR}" == true &&
          "${wallet_encrypt_entry_immutables[index]}" == N ]]; then
      trap '_cntools_action_wallet_encrypt_defer_signal' HUP INT TERM
      wallet_encrypt_immutable_changed_paths+=("${entry}")
      wallet_encrypt_immutable_changed_identities+=("${identity}")
      operation_status=0
      "${wallet_encrypt_sudo_path}" "${wallet_encrypt_chattr_path}" \
        +i -- "${entry}" >/dev/null 2>&1 || operation_status=$?
      wallet_encrypt_check_immutable=N
      _cntools_action_wallet_encrypt_immutable_read \
        "${entry}" wallet_encrypt_check_immutable || action_status=70
      if [[ "${action_status}" == 0 &&
            "${wallet_encrypt_check_immutable}" == Y ]]; then
        [[ "${operation_status}" == 0 ]] || action_status=1
      elif [[ "${action_status}" == 0 && "${operation_status}" != 0 ]]; then
        action_status=1
      else
        action_status=70
      fi
      _cntools_action_wallet_encrypt_resume_signal
    fi
    _cntools_action_wallet_encrypt_file_same \
      "${entry}" "${identity}" "${digest}" || action_status=70
    [[ "${action_status}" == 0 ]] || break
  done

  if [[ "${action_status}" == 0 ]]; then
    for (( source_index=0;
           source_index<${#wallet_encrypt_cipher_paths[@]};
           source_index++ )); do
      if ! _cntools_action_wallet_encrypt_authority_same; then
        action_status=70
        break
      fi
      target="${wallet_encrypt_cipher_paths[source_index]}"
      identity="${wallet_encrypt_cipher_identities[source_index]}"
      digest="${wallet_encrypt_cipher_digests[source_index]}"
      trap '_cntools_action_wallet_encrypt_defer_signal' HUP INT TERM
      operation_status=0
      "${wallet_encrypt_chmod_path}" 0400 "${target}" \
        >/dev/null 2>&1 || operation_status=$?
      wallet_encrypt_cipher_mode=
      wallet_encrypt_cipher_size=
      wallet_encrypt_cipher_identity=
      _cntools_action_wallet_encrypt_file_read \
        "${target}" wallet_encrypt_cipher || action_status=70
      if [[ "${action_status}" == 0 &&
            "${wallet_encrypt_cipher_mode}" == 400 ]]; then
        [[ "${operation_status}" == 0 ]] || action_status=1
      elif [[ "${action_status}" == 0 && "${operation_status}" != 0 ]]; then
        action_status=1
      else
        action_status=70
      fi
      _cntools_action_wallet_encrypt_resume_signal
      if [[ "${action_status}" == 0 && "${ENABLE_CHATTR}" == true ]]; then
        trap '_cntools_action_wallet_encrypt_defer_signal' HUP INT TERM
        wallet_encrypt_immutable_changed_paths+=("${target}")
        wallet_encrypt_immutable_changed_identities+=("${identity}")
        operation_status=0
        "${wallet_encrypt_sudo_path}" "${wallet_encrypt_chattr_path}" \
          +i -- "${target}" >/dev/null 2>&1 || operation_status=$?
        wallet_encrypt_check_immutable=N
        _cntools_action_wallet_encrypt_immutable_read \
          "${target}" wallet_encrypt_check_immutable || action_status=70
        if [[ "${action_status}" == 0 &&
              "${wallet_encrypt_check_immutable}" == Y ]]; then
          [[ "${operation_status}" == 0 ]] || action_status=1
        elif [[ "${action_status}" == 0 && "${operation_status}" != 0 ]]; then
          action_status=1
        else
          action_status=70
        fi
        _cntools_action_wallet_encrypt_resume_signal
      fi
      _cntools_action_wallet_encrypt_file_same \
        "${target}" "${identity}" "${digest}" || action_status=70
      [[ "${action_status}" == 0 ]] || break
    done
  fi
  if [[ "${action_status}" != 0 ]]; then
    if [[ "${action_status}" == 1 ]]; then
      _cntools_action_wallet_encrypt_handled_error \
        'failed to lock wallet files; original wallet was preserved!'
      action_status=$?
      trap - EXIT HUP INT TERM
      return "${action_status}"
    fi
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi

  _cntools_action_wallet_encrypt_authority_same || action_status=70
  for (( source_index=0;
         source_index<${#wallet_encrypt_source_paths[@]};
         source_index++ )); do
    [[ "${action_status}" == 0 ]] || break
    _cntools_action_wallet_encrypt_authority_same || {
      action_status=70
      break
    }
    entry="${wallet_encrypt_source_paths[source_index]}"
    identity="${wallet_encrypt_source_identities[source_index]}"
    digest="${wallet_encrypt_source_digests[source_index]}"
    backup="${wallet_encrypt_lock}/source.${source_index}.backup"
    _cntools_action_wallet_encrypt_file_same \
      "${entry}" "${identity}" "${digest}" || { action_status=70; break; }
    [[ ! -e "${backup}" && ! -L "${backup}" ]] || { action_status=70; break; }
    # Register the possible backup before ln so a signal after link creation
    # can always restore or remove the authenticated source inode.
    wallet_encrypt_source_backup_paths+=("${backup}")
    operation_status=0
    "${wallet_encrypt_ln_path}" -- "${entry}" "${backup}" \
      >/dev/null 2>&1 || operation_status=$?
    if [[ -e "${backup}" || -L "${backup}" ]]; then
      if _cntools_action_wallet_encrypt_file_same \
           "${backup}" "${identity}" "${digest}" '1|2' &&
         _cntools_action_wallet_encrypt_file_same \
           "${entry}" "${identity}" "${digest}" '1|2'; then
        if [[ "${operation_status}" != 0 ]]; then
          action_status=1
          break
        fi
      else
        action_status=70
        break
      fi
    else
      [[ "${operation_status}" != 0 ]] || action_status=70
      [[ "${action_status}" != 0 ]] || action_status=1
      break
    fi
    _cntools_action_wallet_encrypt_authority_same || {
      action_status=70
      break
    }
    operation_status=0
    "${wallet_encrypt_rm_path}" -f -- "${entry}" \
      >/dev/null 2>&1 || operation_status=$?
    if [[ ! -e "${entry}" && ! -L "${entry}" ]] &&
       _cntools_action_wallet_encrypt_file_same \
         "${backup}" "${identity}" "${digest}"; then
      [[ "${operation_status}" == 0 ]] || action_status=1
    elif [[ "${operation_status}" != 0 ]] &&
         _cntools_action_wallet_encrypt_file_same \
           "${entry}" "${identity}" "${digest}" '1|2' &&
         _cntools_action_wallet_encrypt_file_same \
           "${backup}" "${identity}" "${digest}" '1|2'; then
      action_status=1
    else
      action_status=70
    fi
  done
  if [[ "${action_status}" != 0 ]]; then
    if [[ "${action_status}" == 1 ]]; then
      _cntools_action_wallet_encrypt_handled_error \
        'failed to commit encrypted wallet; original wallet was preserved!'
      action_status=$?
      trap - EXIT HUP INT TERM
      return "${action_status}"
    fi
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi

  _cntools_action_wallet_encrypt_authority_same || action_status=70
  for (( source_index=0;
         source_index<${#wallet_encrypt_source_paths[@]};
         source_index++ )); do
    target="${wallet_encrypt_cipher_paths[source_index]}"
    identity="${wallet_encrypt_cipher_identities[source_index]}"
    digest="${wallet_encrypt_cipher_digests[source_index]}"
    _cntools_action_wallet_encrypt_file_same \
      "${target}" "${identity}" "${digest}" || action_status=70
    [[ ! -e "${wallet_encrypt_source_paths[source_index]}" &&
       ! -L "${wallet_encrypt_source_paths[source_index]}" ]] || action_status=70
    backup="${wallet_encrypt_source_backup_paths[source_index]}"
    _cntools_action_wallet_encrypt_file_same \
      "${backup}" "${wallet_encrypt_source_identities[source_index]}" \
      "${wallet_encrypt_source_digests[source_index]}" || action_status=70
  done
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_encrypt_precommit_cleanup || true
    _cntools_action_wallet_encrypt_validation_failure
    return 70
  fi

  trap '_cntools_action_wallet_encrypt_commit_transition' EXIT HUP INT TERM
  wallet_encrypt_committed=Y
  keys_encrypted=${#wallet_encrypt_source_paths[@]}
  wallet_encrypt_published_paths=()
  wallet_encrypt_published_identities=()
  wallet_encrypt_published_digests=()
  wallet_encrypt_mode_changed_paths=()
  wallet_encrypt_mode_changed_modes=()
  wallet_encrypt_mode_changed_identities=()
  wallet_encrypt_immutable_changed_paths=()
  wallet_encrypt_immutable_changed_identities=()
  trap '_cntools_action_wallet_encrypt_postcommit_signal' HUP INT TERM
  if ! _cntools_action_wallet_encrypt_postcommit_cleanup; then
    wallet_encrypt_postcommit_warning=Y
  fi
  trap - EXIT

  for entry in "${wallet_encrypt_source_paths[@]}"; do
    println DEBUG "${entry} successfully encrypted"
  done
  echo
  println "Write protecting all wallet keys with 400 permission and if enabled 'chattr +i'"
  for (( index=0; index<${#wallet_encrypt_entries[@]}; index++ )); do
    entry="${wallet_encrypt_entries[index]}"
    leaf="${entry##*/}"
    [[ "${leaf}" == *.addr ]] && continue
    if [[ "${entry}" == "${wallet_encrypt_source_paths[0]}" ||
          "${entry}" == "${wallet_encrypt_source_paths[1]}" ]]; then
      continue
    fi
    println DEBUG "${entry}"
  done
  for target in "${wallet_encrypt_cipher_paths[@]}"; do
    println DEBUG "${target}"
  done
  echo
  println "Wallet protected : ${FG_GREEN}${wallet_name}${NC}"
  println "Files locked     : ${FG_LBLUE}${files_locked}${NC}"
  println "Files encrypted  : ${FG_LBLUE}${keys_encrypted}${NC}"
  if (( files_locked != 0 || keys_encrypted != 0 )); then
    echo
    println DEBUG "${FG_BLUE}INFO${NC}: wallet files are now protected"
    println DEBUG "Use 'WALLET >> DECRYPT' to unlock"
  fi
  if [[ "${wallet_encrypt_postcommit_warning}" == Y ]]; then
    println ERROR "\n${FG_YELLOW}WARNING${NC}: wallet encryption committed, but private cleanup is incomplete; the operation lock was retained."
  fi
  waitToProceed
  trap - HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
