#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Stage 4 compatibility action for decrypting and unlocking one wallet.
# The selected wallet is inventoried before mutation. Plaintext is staged in a
# private operation directory and ciphertext remains recoverable until commit.

_cntools_action_wallet_decrypt_validation_failure() {
  builtin printf '%s\n' \
    'CNTools wallet decryption action failed validation.' >&2
  return 70
}

_cntools_action_wallet_decrypt_terminal_restore() {
  local failed=0

  if [[ "${wallet_decrypt_terminal_saved:-N}" == Y ]]; then
    tput rc >/dev/null 2>&1 || failed=1
    tput ed >/dev/null 2>&1 || failed=1
    wallet_decrypt_terminal_saved=N
  fi
  return "${failed}"
}

_cntools_action_wallet_decrypt_secret_clear() {
  wallet_decrypt_secret=
  builtin unset wallet_decrypt_secret password 2>/dev/null || true
}

_cntools_action_wallet_decrypt_stat() {
  local target="${1:-}" metadata=""

  [[ -n "${wallet_decrypt_stat_path:-}" ]] || return 1
  if metadata="$("${wallet_decrypt_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' "${target}" 2>/dev/null)"; then
    builtin printf '%s\n' "${metadata}"
    return 0
  fi
  "${wallet_decrypt_stat_path}" -c $'%u\t%a\t%h\t%s\t%d\t%i' \
    -- "${target}" 2>/dev/null
}

_cntools_action_wallet_decrypt_component_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_decrypt_directory_validate() {
  local target="${1:-}" metadata="" owner="" mode="" links=""
  local size="" device="" inode=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_decrypt_stat \
    "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ( "${mode}" == 700 || "${mode}" == 750 || "${mode}" == 755 ) &&
     "${links}" =~ ^[1-9][0-9]*$ && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]]
}

_cntools_action_wallet_decrypt_directory_identity() {
  local target="${1:-}" output_name="${2:-}" metadata=""
  local owner="" mode="" links="" size="" device="" inode=""

  [[ "${output_name}" =~ ^wallet_decrypt_(root|wallet|lock)_identity$ ]] ||
    return 1
  _cntools_action_wallet_decrypt_directory_validate "${target}" || return 1
  metadata="$(_cntools_action_wallet_decrypt_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  [[ "${device}" =~ ^[0-9]+$ && "${inode}" =~ ^[0-9]+$ ]] || return 1
  mode="${mode#0}"
  builtin printf -v "${output_name}" '%s:%s:%s' \
    "${device}" "${inode}" "${mode}"
}

_cntools_action_wallet_decrypt_directory_same() {
  local target="${1:-}" expected_identity="${2:-}"
  local expected_mode="${3:-}" metadata="" owner="" mode="" links=""
  local size="" device="" inode=""

  [[ "${expected_identity}" =~ ^[0-9]+:[0-9]+:(700|750|755)$ &&
     "${expected_mode}" =~ ^7[015][015]$ ]] || return 1
  _cntools_action_wallet_decrypt_directory_validate "${target}" || return 1
  metadata="$(_cntools_action_wallet_decrypt_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == "${expected_mode}" &&
     "${device}:${inode}:${mode}" == "${expected_identity}" ]]
}

_cntools_action_wallet_decrypt_file_read() {
  local target="${1:-}" output_prefix="${2:-}" metadata=""
  local owner="" mode="" links="" size="" device="" inode=""

  [[ "${output_prefix}" =~ ^wallet_decrypt_(entry|temp|target|backup)$ ]] ||
    return 1
  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_decrypt_stat \
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

_cntools_action_wallet_decrypt_hash() {
  local target="${1:-}" output_name="${2:-}" digest=""

  [[ "${output_name}" =~ ^wallet_decrypt_(entry|temp|target|backup)_digest$ ]] ||
    return 1
  case "${wallet_decrypt_hash_kind:-}" in
    sha256sum)
      digest="$("${wallet_decrypt_hash_path}" "${target}" 2>/dev/null)" ||
        return 1
      digest="${digest%% *}"
      ;;
    shasum)
      digest="$("${wallet_decrypt_hash_path}" -a 256 \
        "${target}" 2>/dev/null)" || return 1
      digest="${digest%% *}"
      ;;
    *) return 1 ;;
  esac
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  builtin printf -v "${output_name}" '%s' "${digest,,}"
}

_cntools_action_wallet_decrypt_file_same() {
  local target="${1:-}" expected_identity="${2:-}"
  local expected_digest="${3:-}" metadata="" owner="" mode=""
  local allowed_links="${4:-1}" links="" size="" device="" inode="" digest=""

  [[ "${allowed_links}" == 1 || "${allowed_links}" == '1|2' ]] || return 1

  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_decrypt_stat \
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
    case "${wallet_decrypt_hash_kind}" in
      sha256sum)
        digest="$("${wallet_decrypt_hash_path}" "${target}" 2>/dev/null)" ||
          return 1
        digest="${digest%% *}"
        ;;
      shasum)
        digest="$("${wallet_decrypt_hash_path}" -a 256 \
          "${target}" 2>/dev/null)" || return 1
        digest="${digest%% *}"
        ;;
    esac
    [[ "${digest,,}" == "${expected_digest}" ]] || return 1
  fi
}

_cntools_action_wallet_decrypt_immutable_read() {
  local target="${1:-}" output_name="${2:-}" raw="" flags=""

  [[ "${output_name}" =~ ^wallet_decrypt_(entry|check)_immutable$ &&
     -n "${wallet_decrypt_lsattr_path:-}" ]] || return 1
  raw="$("${wallet_decrypt_lsattr_path}" -d -- \
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

_cntools_action_wallet_decrypt_sort_entries() {
  local index=0 scan=0 value=""

  for (( index=1; index<${#wallet_decrypt_entries[@]}; index++ )); do
    value="${wallet_decrypt_entries[index]}"
    scan=$((index - 1))
    while (( scan >= 0 )) &&
      [[ "${wallet_decrypt_entries[scan]}" > "${value}" ]]; do
      wallet_decrypt_entries[scan + 1]="${wallet_decrypt_entries[scan]}"
      scan=$((scan - 1))
    done
    wallet_decrypt_entries[scan + 1]="${value}"
  done
}

_cntools_action_wallet_decrypt_inventory_same() {
  local entry="" value="" scan=0 index=0 metadata="" digest=""
  local owner="" mode="" links="" size="" device="" inode=""
  local -a current=()

  shopt -s nullglob dotglob
  current=("${selected_wallet}"/*)
  shopt -u nullglob dotglob
  (( ${#current[@]} == ${#wallet_decrypt_entries[@]} )) || return 1
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
    [[ "${entry}" == "${wallet_decrypt_entries[index]}" ]] || return 1
    metadata="$(_cntools_action_wallet_decrypt_stat \
      "${entry}")" || return 1
    IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
      return 1
    mode="${mode#0}"
    [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
       "${mode}" == "${wallet_decrypt_entry_modes[index]}" &&
       "${size}" == "${wallet_decrypt_entry_sizes[index]}" &&
       "${device}:${inode}" == \
         "${wallet_decrypt_entry_identities[index]}" ]] || return 1
    case "${wallet_decrypt_hash_kind}" in
      sha256sum)
        digest="$("${wallet_decrypt_hash_path}" "${entry}" 2>/dev/null)" ||
          return 1
        digest="${digest%% *}"
        ;;
      shasum)
        digest="$("${wallet_decrypt_hash_path}" -a 256 \
          "${entry}" 2>/dev/null)" || return 1
        digest="${digest%% *}"
        ;;
    esac
    [[ "${digest,,}" == "${wallet_decrypt_entry_digests[index]}" ]] ||
      return 1
  done
}

_cntools_action_wallet_decrypt_lock_release() {
  local failed=0

  if [[ "${wallet_decrypt_lock_acquired:-N}" == Y ]]; then
    [[ -n "${wallet_decrypt_lock:-}" ]] || failed=1
    if [[ "${failed}" == 0 ]]; then
      _cntools_action_wallet_decrypt_directory_same \
        "${wallet_decrypt_lock}" "${wallet_decrypt_lock_identity:-}" 700 ||
        failed=1
    fi
    if [[ "${failed}" == 0 ]]; then
      "${wallet_decrypt_rmdir_path}" -- "${wallet_decrypt_lock}" \
        >/dev/null 2>&1 || failed=1
    fi
    if [[ ! -e "${wallet_decrypt_lock}" &&
          ! -L "${wallet_decrypt_lock}" ]]; then
      wallet_decrypt_lock_acquired=N
      wallet_decrypt_lock=
    else
      failed=1
    fi
  fi
  return "${failed}"
}

_cntools_action_wallet_decrypt_defer_signal() {
  wallet_decrypt_signal_pending=Y
}

_cntools_action_wallet_decrypt_authority_same() {
  _cntools_action_wallet_decrypt_directory_same \
    "${WALLET_FOLDER}" "${wallet_decrypt_root_identity:-}" \
    "${wallet_decrypt_root_identity##*:}" &&
  _cntools_action_wallet_decrypt_directory_same \
    "${selected_wallet}" "${wallet_decrypt_wallet_identity:-}" \
    "${wallet_decrypt_wallet_identity##*:}" &&
  _cntools_action_wallet_decrypt_directory_same \
    "${wallet_decrypt_lock}" "${wallet_decrypt_lock_identity:-}" 700
}

_cntools_action_wallet_decrypt_temp_remove() {
  local target="${1:-}" expected_identity="${2:-}" metadata=""
  local owner="" mode="" links="" size="" device="" inode=""

  [[ -n "${wallet_decrypt_lock:-}" &&
     "${target}" == "${wallet_decrypt_lock}/plain."* &&
     "${target#"${wallet_decrypt_lock}/"}" != */* ]] || return 1
  _cntools_action_wallet_decrypt_directory_same \
    "${wallet_decrypt_lock}" "${wallet_decrypt_lock_identity:-}" 700 ||
    return 1
  if [[ -L "${target}" ]]; then
    "${wallet_decrypt_rm_path}" -f -- "${target}" >/dev/null 2>&1
    return $?
  fi
  [[ -f "${target}" ]] || return 1
  metadata="$(_cntools_action_wallet_decrypt_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  [[ "${owner}" == "${EUID}" && "${device}:${inode}" == \
     "${expected_identity}" && "${links}" =~ ^[1-9][0-9]*$ ]] || return 1
  if (( links > 1 )); then
    : > "${target}" || return 1
    metadata="$(_cntools_action_wallet_decrypt_stat "${target}")" || return 1
    IFS=$'\t' read -r owner mode links size device inode <<< "${metadata}" ||
      return 1
    [[ "${owner}" == "${EUID}" && "${device}:${inode}" == \
       "${expected_identity}" && "${size}" == 0 ]] || return 1
  fi
  "${wallet_decrypt_rm_path}" -f -- "${target}" >/dev/null 2>&1
}

_cntools_action_wallet_decrypt_rollback() {
  local index=0 failed=0 target="" backup="" identity="" digest=""

  for (( index=${#wallet_decrypt_backup_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_decrypt_cipher_paths[index]}"
    backup="${wallet_decrypt_backup_paths[index]}"
    identity="${wallet_decrypt_cipher_identities[index]}"
    digest="${wallet_decrypt_cipher_digests[index]}"
    if [[ -e "${backup}" || -L "${backup}" ]]; then
      if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        if _cntools_action_wallet_decrypt_file_same \
             "${backup}" "${identity}" "${digest}" &&
           "${wallet_decrypt_ln_path}" -- "${backup}" "${target}" \
             >/dev/null 2>&1 &&
           "${wallet_decrypt_rm_path}" -f -- "${backup}" \
             >/dev/null 2>&1; then
          :
        else
          failed=1
        fi
      else
        if _cntools_action_wallet_decrypt_file_same \
             "${target}" "${identity}" "${digest}" '1|2' &&
           _cntools_action_wallet_decrypt_file_same \
             "${backup}" "${identity}" "${digest}" '1|2'; then
          "${wallet_decrypt_rm_path}" -f -- "${backup}" \
            >/dev/null 2>&1 || true
          if [[ -e "${backup}" || -L "${backup}" ]] ||
             ! _cntools_action_wallet_decrypt_file_same \
               "${target}" "${identity}" "${digest}"; then
            failed=1
          fi
        else
          # Retain the authenticated backup when the canonical ciphertext path
          # no longer names the original file. Discarding it would turn a
          # concurrent replacement into unrecoverable data loss.
          failed=1
        fi
      fi
    fi
  done
  wallet_decrypt_backup_paths=()

  for (( index=${#wallet_decrypt_published_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_decrypt_published_paths[index]}"
    identity="${wallet_decrypt_published_identities[index]}"
    digest="${wallet_decrypt_published_digests[index]}"
    if [[ -e "${target}" || -L "${target}" ]]; then
      _cntools_action_wallet_decrypt_file_same \
        "${target}" "${identity}" "${digest}" '1|2' || {
          failed=1
          continue
        }
      "${wallet_decrypt_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || failed=1
    fi
  done
  wallet_decrypt_published_paths=()
  wallet_decrypt_published_identities=()
  wallet_decrypt_published_digests=()

  for (( index=${#wallet_decrypt_temp_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_decrypt_temp_paths[index]}"
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      identity="${wallet_decrypt_temp_identities[index]:-}"
      _cntools_action_wallet_decrypt_temp_remove \
        "${target}" "${identity}" || failed=1
    fi
  done
  wallet_decrypt_temp_paths=()

  for (( index=${#wallet_decrypt_mode_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_decrypt_mode_changed_paths[index]}"
    identity="${wallet_decrypt_mode_changed_identities[index]}"
    _cntools_action_wallet_decrypt_file_same \
      "${target}" "${identity}" || { failed=1; continue; }
    "${wallet_decrypt_chmod_path}" \
      "${wallet_decrypt_mode_changed_modes[index]}" "${target}" \
      >/dev/null 2>&1 || failed=1
  done
  wallet_decrypt_mode_changed_paths=()
  wallet_decrypt_mode_changed_modes=()
  wallet_decrypt_mode_changed_identities=()

  for (( index=${#wallet_decrypt_immutable_changed_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_decrypt_immutable_changed_paths[index]}"
    identity="${wallet_decrypt_immutable_changed_identities[index]}"
    _cntools_action_wallet_decrypt_file_same \
      "${target}" "${identity}" || { failed=1; continue; }
    "${wallet_decrypt_sudo_path}" "${wallet_decrypt_chattr_path}" \
      +i -- "${target}" >/dev/null 2>&1 || failed=1
    wallet_decrypt_check_immutable=N
    _cntools_action_wallet_decrypt_immutable_read \
      "${target}" wallet_decrypt_check_immutable || failed=1
    [[ "${wallet_decrypt_check_immutable}" == Y ]] || failed=1
  done
  wallet_decrypt_immutable_changed_paths=()
  wallet_decrypt_immutable_changed_identities=()
  return "${failed}"
}

_cntools_action_wallet_decrypt_precommit_cleanup() {
  local failed=0

  trap - EXIT HUP INT TERM
  _cntools_action_wallet_decrypt_secret_clear
  _cntools_action_wallet_decrypt_terminal_restore || failed=1
  _cntools_action_wallet_decrypt_rollback || failed=1
  _cntools_action_wallet_decrypt_lock_release || failed=1
  return "${failed}"
}

_cntools_action_wallet_decrypt_signal() {
  _cntools_action_wallet_decrypt_precommit_cleanup \
    >/dev/null 2>&1 || true
  _cntools_action_wallet_decrypt_validation_failure
  exit 70
}

_cntools_action_wallet_decrypt_handled_error() {
  local message="${1:-}" failed=0

  _cntools_action_wallet_decrypt_secret_clear
  _cntools_action_wallet_decrypt_rollback || failed=1
  _cntools_action_wallet_decrypt_lock_release || failed=1
  if [[ "${failed}" != 0 ]]; then
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  fi
  println ERROR "\n${FG_RED}ERROR${NC}: ${message}"
  waitToProceed
  return 0
}

_cntools_action_wallet_decrypt_postcommit_cleanup() {
  local index=0 failed=0 target="" identity="" digest=""

  _cntools_action_wallet_decrypt_secret_clear
  for (( index=${#wallet_decrypt_backup_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_decrypt_backup_paths[index]}"
    if [[ -e "${target}" || -L "${target}" ]]; then
      identity="${wallet_decrypt_cipher_identities[index]:-}"
      digest="${wallet_decrypt_cipher_digests[index]:-}"
      _cntools_action_wallet_decrypt_file_same \
        "${target}" "${identity}" "${digest}" || {
          failed=1
          continue
        }
      "${wallet_decrypt_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || failed=1
    fi
  done
  for (( index=${#wallet_decrypt_temp_paths[@]}-1;
         index>=0; index-- )); do
    target="${wallet_decrypt_temp_paths[index]}"
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      identity="${wallet_decrypt_temp_identities[index]:-}"
      _cntools_action_wallet_decrypt_temp_remove \
        "${target}" "${identity}" || failed=1
    fi
  done
  if [[ "${failed}" == 0 ]]; then
    wallet_decrypt_backup_paths=()
    wallet_decrypt_temp_paths=()
    _cntools_action_wallet_decrypt_lock_release || failed=1
  fi
  return "${failed}"
}

_cntools_action_wallet_decrypt_commit_transition() {
  local cleanup_failed=0

  # One trap command installs this transition for EXIT and every handled
  # signal. Until the following commit assignment, a trap still rolls the
  # operation back; after it, published plaintext is never removed.
  trap - EXIT
  trap '' HUP INT TERM
  if [[ "${wallet_decrypt_committed:-N}" == Y ]]; then
    _cntools_action_wallet_decrypt_postcommit_cleanup ||
      cleanup_failed=1
    if [[ "${cleanup_failed}" == 0 ]]; then
      builtin printf '%s\n' \
        'CNTools wallet decryption action committed; interrupted during post-commit cleanup.' >&2
    else
      builtin printf '%s\n' \
        'CNTools wallet decryption action committed; private cleanup is incomplete and the operation lock was retained.' >&2
    fi
    exit 0
  fi
  _cntools_action_wallet_decrypt_precommit_cleanup \
    >/dev/null 2>&1 || true
  exit 70
}

_cntools_action_wallet_decrypt_postcommit_signal() {
  trap '' HUP INT TERM
  _cntools_action_wallet_decrypt_secret_clear
  if [[ -n "${wallet_decrypt_lock:-}" &&
        ( -e "${wallet_decrypt_lock}" || -L "${wallet_decrypt_lock}" ) ]]; then
    builtin printf '%s\n' \
      'CNTools wallet decryption action committed; interrupted after commit and private cleanup is incomplete.' >&2
  else
    builtin printf '%s\n' \
      'CNTools wallet decryption action committed; interrupted after commit.' >&2
  fi
  exit 0
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local wallet_root_physical="" wallet_physical="" selected_wallet=""
  local wallet_decrypt_private_parent="" wallet_decrypt_root_identity=""
  local wallet_decrypt_wallet_identity="" wallet_decrypt_lock_identity=""
  local entry="" leaf="" plain_leaf="" plain_path="" metadata=""
  local index=0 cipher_index=0 total_size=0 action_status=0 cleanup_status=0
  local wallet_decrypt_entry_mode="" wallet_decrypt_entry_size=""
  local wallet_decrypt_entry_identity="" wallet_decrypt_entry_digest=""
  local wallet_decrypt_temp_mode="" wallet_decrypt_temp_size=""
  local wallet_decrypt_temp_identity="" wallet_decrypt_temp_digest=""
  local wallet_decrypt_target_mode="" wallet_decrypt_target_size=""
  local wallet_decrypt_target_identity="" wallet_decrypt_target_digest=""
  local wallet_decrypt_backup_mode="" wallet_decrypt_backup_size=""
  local wallet_decrypt_backup_identity="" wallet_decrypt_backup_digest=""
  local wallet_decrypt_check_immutable=N wallet_decrypt_entry_immutable=N
  local wallet_decrypt_secret="" wallet_decrypt_terminal_saved=N
  local wallet_decrypt_stat_path="" wallet_decrypt_chmod_path=""
  local wallet_decrypt_rm_path="" wallet_decrypt_ln_path=""
  local wallet_decrypt_mktemp_path="" wallet_decrypt_mkdir_path=""
  local wallet_decrypt_rmdir_path="" wallet_decrypt_hash_path=""
  local wallet_decrypt_hash_kind="" wallet_decrypt_gpg_path=""
  local wallet_decrypt_lsattr_path="" wallet_decrypt_chattr_path=""
  local wallet_decrypt_sudo_path="" wallet_decrypt_lock=""
  local wallet_decrypt_lock_acquired=N wallet_decrypt_committed=N
  local wallet_decrypt_signal_pending=N wallet_decrypt_lock_created=N
  local wallet_decrypt_postcommit_warning=N filesUnlocked=0 keysDecrypted=0
  local temp="" target="" backup="" identity="" digest=""
  local operation_status=0 current_mode="" owner="" links="" size=""
  local device="" inode=""
  local -a wallet_decrypt_entries=()
  local -a wallet_decrypt_entry_modes=() wallet_decrypt_entry_sizes=()
  local -a wallet_decrypt_entry_identities=() wallet_decrypt_entry_digests=()
  local -a wallet_decrypt_entry_immutables=()
  local -a wallet_decrypt_cipher_paths=()
  local -a wallet_decrypt_cipher_identities=()
  local -a wallet_decrypt_cipher_digests=()
  local -a wallet_decrypt_plain_paths=()
  local -a wallet_decrypt_temp_paths=()
  local -a wallet_decrypt_temp_identities=()
  local -a wallet_decrypt_temp_digests=()
  local -a wallet_decrypt_published_paths=()
  local -a wallet_decrypt_published_identities=()
  local -a wallet_decrypt_published_digests=()
  local -a wallet_decrypt_backup_paths=()
  local -a wallet_decrypt_mode_changed_paths=()
  local -a wallet_decrypt_mode_changed_modes=()
  local -a wallet_decrypt_mode_changed_identities=()
  local -a wallet_decrypt_immutable_changed_paths=()
  local -a wallet_decrypt_immutable_changed_identities=()

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
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  [[ "${context_mode}" =~ ^(local|light|offline)$ &&
     "${CNTOOLS_MODE,,}" == "${context_mode}" &&
     ( "${ENABLE_CHATTR:-}" == true ||
       "${ENABLE_CHATTR:-}" == false ) &&
     "${WALLET_FOLDER:-}" == /* ]] || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  if [[ "${WALLET_FOLDER}" == *\\* ||
        "${WALLET_FOLDER}" =~ [[:cntrl:]] ]]; then
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  fi
  _cntools_registry_tool_path stat wallet_decrypt_stat_path || action_status=70
  for entry in chmod rm ln mktemp mkdir rmdir gpg; do
    case "${entry}" in
      chmod) _cntools_registry_tool_path chmod wallet_decrypt_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_decrypt_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln wallet_decrypt_ln_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp wallet_decrypt_mktemp_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir wallet_decrypt_mkdir_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir wallet_decrypt_rmdir_path || action_status=70 ;;
      gpg) _cntools_registry_tool_path gpg wallet_decrypt_gpg_path || action_status=70 ;;
    esac
  done
  if _cntools_registry_tool_path sha256sum wallet_decrypt_hash_path; then
    wallet_decrypt_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum wallet_decrypt_hash_path; then
    wallet_decrypt_hash_kind=shasum
  else
    action_status=70
  fi
  if [[ "${ENABLE_CHATTR}" == true ]]; then
    _cntools_registry_tool_path lsattr wallet_decrypt_lsattr_path || action_status=70
    _cntools_registry_tool_path chattr wallet_decrypt_chattr_path || action_status=70
    _cntools_registry_tool_path sudo wallet_decrypt_sudo_path || action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  _cntools_action_wallet_decrypt_directory_validate \
    "${WALLET_FOLDER}" || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  wallet_root_physical="$(cd -P -- "${WALLET_FOLDER}" \
    >/dev/null 2>&1 && pwd -P)" || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  [[ "${wallet_root_physical}" == "${WALLET_FOLDER}" ]] || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  wallet_decrypt_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${wallet_decrypt_private_parent}" || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  [[ "${wallet_root_physical}" != "${wallet_decrypt_private_parent}" &&
     "${wallet_root_physical}" != "${wallet_decrypt_private_parent}/"* &&
     "${wallet_decrypt_private_parent}" != "${wallet_root_physical}/"* ]] || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }
  _cntools_action_wallet_decrypt_directory_identity \
    "${WALLET_FOLDER}" wallet_decrypt_root_identity || {
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  }

  trap '_cntools_action_wallet_decrypt_precommit_cleanup' EXIT
  trap '_cntools_action_wallet_decrypt_signal' HUP INT TERM

  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> WALLET >> DECRYPT'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  shopt -s nullglob dotglob
  wallet_decrypt_entries=("${WALLET_FOLDER}"/*)
  shopt -u nullglob dotglob
  if (( ${#wallet_decrypt_entries[@]} == 0 )); then
    println "${FG_YELLOW}No wallets available!${NC}"
    waitToProceed
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_decrypt_secret_clear
    return 0
  fi
  println DEBUG 'Select wallet to decrypt'
  builtin unset wallet_name 2>/dev/null || true
  if tput sc >/dev/null 2>&1; then wallet_decrypt_terminal_saved=Y; fi
  if selectWallet encrypted; then action_status=0; else action_status=$?; fi
  _cntools_action_wallet_decrypt_terminal_restore || action_status=70
  case "${action_status}" in
    0) ;;
    1)
      waitToProceed
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_decrypt_secret_clear
      return 0
      ;;
    2)
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_decrypt_secret_clear
      return 0
      ;;
    *)
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_decrypt_secret_clear
      _cntools_action_wallet_decrypt_validation_failure
      return 70
      ;;
  esac
  if [[ -z "${wallet_name:-}" ]]; then
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_decrypt_secret_clear
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  fi
  if ! _cntools_action_wallet_decrypt_component_valid \
      "${wallet_name}"; then
    _cntools_action_wallet_decrypt_precommit_cleanup || true
    _cntools_action_wallet_decrypt_validation_failure
    action_status=70
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi
  selected_wallet="${WALLET_FOLDER}/${wallet_name}"
  wallet_physical="$(cd -P -- "${selected_wallet}" \
    >/dev/null 2>&1 && pwd -P)" || wallet_physical=
  if ! _cntools_action_wallet_decrypt_directory_validate \
       "${selected_wallet}" ||
     [[ "${wallet_physical}" != \
        "${wallet_root_physical}/${wallet_name}" ]]; then
    _cntools_action_wallet_decrypt_precommit_cleanup || true
    _cntools_action_wallet_decrypt_validation_failure
    action_status=70
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi
  _cntools_action_wallet_decrypt_directory_identity \
    "${selected_wallet}" wallet_decrypt_wallet_identity || {
    _cntools_action_wallet_decrypt_precommit_cleanup || true
    _cntools_action_wallet_decrypt_validation_failure
    action_status=70
    trap - EXIT HUP INT TERM
    return "${action_status}"
  }

  wallet_decrypt_lock="${WALLET_FOLDER}/.${wallet_name}.cntools-decrypt.lock"
  if [[ -e "${wallet_decrypt_lock}" || -L "${wallet_decrypt_lock}" ]]; then
    _cntools_action_wallet_decrypt_handled_error \
      'selected wallet is already being modified!'
    action_status=$?
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi
  trap '_cntools_action_wallet_decrypt_defer_signal' HUP INT TERM
  if ! "${wallet_decrypt_mkdir_path}" -m 0700 -- \
      "${wallet_decrypt_lock}" >/dev/null 2>&1; then
    trap '_cntools_action_wallet_decrypt_signal' HUP INT TERM
    if [[ -e "${wallet_decrypt_lock}" || -L "${wallet_decrypt_lock}" ]]; then
      _cntools_action_wallet_decrypt_handled_error \
        'selected wallet is already being modified!'
      action_status=$?
    else
      action_status=70
    fi
    trap - EXIT HUP INT TERM
    [[ "${action_status}" == 0 ]] ||
      _cntools_action_wallet_decrypt_validation_failure
    return "${action_status}"
  fi
  wallet_decrypt_lock_created=Y
  if ! _cntools_action_wallet_decrypt_directory_same \
       "${WALLET_FOLDER}" "${wallet_decrypt_root_identity}" \
       "${wallet_decrypt_root_identity##*:}" ||
     ! _cntools_action_wallet_decrypt_directory_identity \
       "${wallet_decrypt_lock}" wallet_decrypt_lock_identity ||
     ! _cntools_action_wallet_decrypt_directory_same \
       "${wallet_decrypt_lock}" "${wallet_decrypt_lock_identity}" 700; then
    trap '_cntools_action_wallet_decrypt_signal' HUP INT TERM
    wallet_decrypt_lock_acquired=Y
    wallet_decrypt_lock_created=N
    _cntools_action_wallet_decrypt_precommit_cleanup || true
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  fi
  wallet_decrypt_lock_acquired=Y
  wallet_decrypt_lock_created=N
  trap '_cntools_action_wallet_decrypt_signal' HUP INT TERM
  if [[ "${wallet_decrypt_signal_pending}" == Y ]]; then
    _cntools_action_wallet_decrypt_signal
  fi

  shopt -s nullglob dotglob
  wallet_decrypt_entries=("${selected_wallet}"/*)
  shopt -u nullglob dotglob
  (( ${#wallet_decrypt_entries[@]} <= 1024 )) || action_status=70
  _cntools_action_wallet_decrypt_sort_entries
  for entry in "${wallet_decrypt_entries[@]}"; do
    leaf="${entry##*/}"
    _cntools_action_wallet_decrypt_component_valid "${leaf}" ||
      action_status=70
    [[ "${leaf}" != .cntools-wallet-* ]] || action_status=70
    wallet_decrypt_entry_mode=
    wallet_decrypt_entry_size=
    wallet_decrypt_entry_identity=
    wallet_decrypt_entry_digest=
    _cntools_action_wallet_decrypt_file_read \
      "${entry}" wallet_decrypt_entry || action_status=70
    _cntools_action_wallet_decrypt_hash \
      "${entry}" wallet_decrypt_entry_digest || action_status=70
    wallet_decrypt_entry_modes+=("${wallet_decrypt_entry_mode}")
    wallet_decrypt_entry_sizes+=("${wallet_decrypt_entry_size}")
    wallet_decrypt_entry_identities+=("${wallet_decrypt_entry_identity}")
    wallet_decrypt_entry_digests+=("${wallet_decrypt_entry_digest}")
    total_size=$((total_size + ${wallet_decrypt_entry_size:-0}))
    (( total_size <= 67108864 )) || action_status=70
    wallet_decrypt_entry_immutable=N
    if [[ "${ENABLE_CHATTR}" == true ]]; then
      _cntools_action_wallet_decrypt_immutable_read \
        "${entry}" wallet_decrypt_entry_immutable || action_status=70
    fi
    wallet_decrypt_entry_immutables+=("${wallet_decrypt_entry_immutable}")
    if [[ "${leaf}" == *.gpg ]]; then
      plain_leaf="${leaf%.gpg}"
      _cntools_action_wallet_decrypt_component_valid \
        "${plain_leaf}" || action_status=70
      [[ "${plain_leaf}" != *.gpg ]] || action_status=70
      plain_path="${selected_wallet}/${plain_leaf}"
      [[ ! -e "${plain_path}" && ! -L "${plain_path}" ]] || action_status=70
      [[ "${wallet_decrypt_entry_size:-0}" -ge 1 ]] || action_status=70
      wallet_decrypt_cipher_paths+=("${entry}")
      wallet_decrypt_cipher_identities+=("${wallet_decrypt_entry_identity}")
      wallet_decrypt_cipher_digests+=("${wallet_decrypt_entry_digest}")
      wallet_decrypt_plain_paths+=("${plain_path}")
    elif [[ -e "${entry}.gpg" || -L "${entry}.gpg" ]]; then
      action_status=70
    fi
  done
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_decrypt_precommit_cleanup || true
    _cntools_action_wallet_decrypt_validation_failure
    action_status=70
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi

  echo
  println DEBUG 'Removing write protection from all wallet files'
  for entry in "${wallet_decrypt_entries[@]}"; do
    println DEBUG "${entry}"
  done

  if (( ${#wallet_decrypt_cipher_paths[@]} > 0 )); then
    echo
    println 'Decrypting GPG encrypted wallet files'
    if ! getPasswordCust; then
      _cntools_action_wallet_decrypt_secret_clear
      if ! _cntools_action_wallet_decrypt_lock_release; then
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_decrypt_validation_failure
        return 70
      fi
      println "\n\n"
      println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
      waitToProceed
      trap - EXIT HUP INT TERM
      return 0
    fi
    wallet_decrypt_secret="${password-}"
    builtin unset password 2>/dev/null || true

    for (( cipher_index=0;
           cipher_index<${#wallet_decrypt_cipher_paths[@]};
           cipher_index++ )); do
      temp="$("${wallet_decrypt_mktemp_path}" \
        "${wallet_decrypt_lock}/plain.${cipher_index}.XXXXXXXX")" ||
        action_status=70
      [[ "${action_status}" == 0 ]] || break
      [[ "${temp}" == "${wallet_decrypt_lock}/plain.${cipher_index}."* &&
         "${temp#"${wallet_decrypt_lock}/"}" != */* ]] || {
        action_status=70
        break
      }
      wallet_decrypt_temp_paths+=("${temp}")
      wallet_decrypt_temp_mode=
      wallet_decrypt_temp_size=
      wallet_decrypt_temp_identity=
      _cntools_action_wallet_decrypt_file_read \
        "${temp}" wallet_decrypt_temp || action_status=70
      wallet_decrypt_temp_identities+=("${wallet_decrypt_temp_identity}")
      wallet_decrypt_temp_digests+=("")
      [[ "${action_status}" == 0 ]] || break
      "${wallet_decrypt_chmod_path}" 0600 "${temp}" \
        >/dev/null 2>&1 || { action_status=70; break; }
      wallet_decrypt_temp_mode=
      wallet_decrypt_temp_size=
      wallet_decrypt_temp_identity=
      _cntools_action_wallet_decrypt_file_read \
        "${temp}" wallet_decrypt_temp || action_status=70
      [[ "${wallet_decrypt_temp_mode}" == 600 ]] || action_status=70
      [[ "${action_status}" == 0 ]] || break
      if ! builtin printf '%s\n' "${wallet_decrypt_secret}" | \
          "${wallet_decrypt_gpg_path}" --decrypt --batch --yes --no-tty \
            --pinentry-mode loopback --passphrase-fd 0 --output "${temp}" \
            -- "${wallet_decrypt_cipher_paths[cipher_index]}" \
            >/dev/null 2>&1; then
        action_status=1
        break
      fi
      identity="${wallet_decrypt_temp_identities[cipher_index]}"
      wallet_decrypt_temp_mode=
      wallet_decrypt_temp_size=
      wallet_decrypt_temp_identity=
      wallet_decrypt_temp_digest=
      _cntools_action_wallet_decrypt_file_read \
        "${temp}" wallet_decrypt_temp || action_status=70
      [[ "${wallet_decrypt_temp_identity}" == "${identity}" &&
         "${wallet_decrypt_temp_mode}" == 600 &&
         "${wallet_decrypt_temp_size:-0}" -ge 1 ]] || action_status=70
      _cntools_action_wallet_decrypt_hash \
        "${temp}" wallet_decrypt_temp_digest || action_status=70
      wallet_decrypt_temp_digests[cipher_index]="${wallet_decrypt_temp_digest}"
      [[ "${action_status}" == 0 ]] || break
    done
    _cntools_action_wallet_decrypt_secret_clear
    if [[ "${action_status}" != 0 ]]; then
      if [[ "${action_status}" == 1 ]]; then
        _cntools_action_wallet_decrypt_handled_error \
          'failed to decrypt wallet files; original encrypted wallet was preserved!'
        action_status=$?
      else
        _cntools_action_wallet_decrypt_precommit_cleanup || true
        _cntools_action_wallet_decrypt_validation_failure
        return 70
      fi
      trap - EXIT HUP INT TERM
      return "${action_status}"
    fi
    for entry in "${wallet_decrypt_cipher_paths[@]}"; do
      println DEBUG "${entry} successfully decrypted"
    done
  fi

  if ! _cntools_action_wallet_decrypt_authority_same ||
     ! _cntools_action_wallet_decrypt_inventory_same; then
    _cntools_action_wallet_decrypt_precommit_cleanup || true
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  fi

  for (( index=0; index<${#wallet_decrypt_entries[@]}; index++ )); do
    entry="${wallet_decrypt_entries[index]}"
    identity="${wallet_decrypt_entry_identities[index]}"
    digest="${wallet_decrypt_entry_digests[index]}"
    if [[ "${wallet_decrypt_entry_immutables[index]}" == Y ]]; then
      operation_status=0
      "${wallet_decrypt_sudo_path}" "${wallet_decrypt_chattr_path}" \
        -i -- "${entry}" >/dev/null 2>&1 || operation_status=$?
      wallet_decrypt_check_immutable=Y
      if ! _cntools_action_wallet_decrypt_immutable_read \
          "${entry}" wallet_decrypt_check_immutable; then
        action_status=70
      elif [[ "${wallet_decrypt_check_immutable}" == N ]]; then
        wallet_decrypt_immutable_changed_paths+=("${entry}")
        wallet_decrypt_immutable_changed_identities+=("${identity}")
        [[ "${operation_status}" == 0 ]] || action_status=1
      else
        [[ "${operation_status}" != 0 ]] || action_status=70
        [[ "${action_status}" != 0 ]] || action_status=1
      fi
    fi
    if [[ "${action_status}" == 0 &&
          "${wallet_decrypt_entry_modes[index]}" != 600 ]]; then
      operation_status=0
      "${wallet_decrypt_chmod_path}" 0600 "${entry}" \
        >/dev/null 2>&1 || operation_status=$?
      metadata="$(_cntools_action_wallet_decrypt_stat \
        "${entry}")" || action_status=70
      if [[ "${action_status}" == 0 ]]; then
        IFS=$'\t' read -r owner current_mode links size device inode \
          <<< "${metadata}" || action_status=70
        current_mode="${current_mode#0}"
      fi
      if [[ "${action_status}" == 0 && "${current_mode}" == 600 ]]; then
        wallet_decrypt_mode_changed_paths+=("${entry}")
        wallet_decrypt_mode_changed_modes+=("${wallet_decrypt_entry_modes[index]}")
        wallet_decrypt_mode_changed_identities+=("${identity}")
        [[ "${operation_status}" == 0 ]] || action_status=1
      elif [[ "${action_status}" == 0 &&
              "${current_mode}" == "${wallet_decrypt_entry_modes[index]}" &&
              "${operation_status}" != 0 ]]; then
        action_status=1
      else
        action_status=70
      fi
    fi
    _cntools_action_wallet_decrypt_file_same \
      "${entry}" "${identity}" "${digest}" || action_status=70
    metadata="$(_cntools_action_wallet_decrypt_stat \
      "${entry}")" || action_status=70
    [[ "${action_status}" != 0 || "${metadata}" == *$'\t600\t'* ]] ||
      action_status=70
    [[ "${action_status}" == 0 ]] || break
  done

  if [[ "${action_status}" == 0 ]]; then
    _cntools_action_wallet_decrypt_authority_same || action_status=70
  fi

  if [[ "${action_status}" == 0 ]]; then
    for (( cipher_index=0;
           cipher_index<${#wallet_decrypt_temp_paths[@]};
           cipher_index++ )); do
      temp="${wallet_decrypt_temp_paths[cipher_index]}"
      target="${wallet_decrypt_plain_paths[cipher_index]}"
      identity="${wallet_decrypt_temp_identities[cipher_index]}"
      digest="${wallet_decrypt_temp_digests[cipher_index]}"
      [[ ! -e "${target}" && ! -L "${target}" ]] || {
        action_status=1; break;
      }
      operation_status=0
      "${wallet_decrypt_ln_path}" -- "${temp}" "${target}" \
        >/dev/null 2>&1 || operation_status=$?
      if [[ -e "${target}" || -L "${target}" ]]; then
        if _cntools_action_wallet_decrypt_file_same \
             "${target}" "${identity}" "${digest}" '1|2'; then
          wallet_decrypt_published_paths+=("${target}")
          wallet_decrypt_published_identities+=("${identity}")
          wallet_decrypt_published_digests+=("${digest}")
          if [[ "${operation_status}" != 0 ]]; then
            action_status=1
            break
          fi
        else
          action_status=70
          break
        fi
      else
        if [[ "${operation_status}" == 0 ]]; then
          action_status=70
        else
          action_status=1
        fi
        break
      fi
      if ! "${wallet_decrypt_rm_path}" -f -- "${temp}" \
           >/dev/null 2>&1; then
        action_status=1
        break
      fi
      wallet_decrypt_temp_paths[cipher_index]=
      _cntools_action_wallet_decrypt_file_same \
        "${target}" "${identity}" "${digest}" || action_status=1
      wallet_decrypt_target_mode=
      wallet_decrypt_target_size=
      wallet_decrypt_target_identity=
      _cntools_action_wallet_decrypt_file_read \
        "${target}" wallet_decrypt_target || action_status=70
      [[ "${wallet_decrypt_target_mode}" == 600 ]] || action_status=70
      [[ "${action_status}" == 0 ]] || break
    done
  fi

  if [[ "${action_status}" == 0 ]]; then
    _cntools_action_wallet_decrypt_authority_same || action_status=70
  fi

  if [[ "${action_status}" == 0 ]]; then
    for (( cipher_index=0;
           cipher_index<${#wallet_decrypt_cipher_paths[@]};
           cipher_index++ )); do
      entry="${wallet_decrypt_cipher_paths[cipher_index]}"
      identity="${wallet_decrypt_cipher_identities[cipher_index]}"
      digest="${wallet_decrypt_cipher_digests[cipher_index]}"
      backup="${wallet_decrypt_lock}/cipher.${cipher_index}.backup"
      [[ ! -e "${backup}" && ! -L "${backup}" ]] || {
        action_status=1; break;
      }
      _cntools_action_wallet_decrypt_file_same \
        "${entry}" "${identity}" "${digest}" || { action_status=1; break; }
      operation_status=0
      "${wallet_decrypt_ln_path}" -- "${entry}" "${backup}" \
        >/dev/null 2>&1 || operation_status=$?
      if [[ -e "${backup}" || -L "${backup}" ]]; then
        if _cntools_action_wallet_decrypt_file_same \
             "${backup}" "${identity}" "${digest}" '1|2'; then
          wallet_decrypt_backup_paths+=("${backup}")
          if [[ "${operation_status}" != 0 ]]; then
            action_status=1
            break
          fi
        else
          action_status=70
          break
        fi
      else
        if [[ "${operation_status}" == 0 ]]; then
          action_status=70
        else
          action_status=1
        fi
        break
      fi
      if ! "${wallet_decrypt_rm_path}" -f -- "${entry}" \
           >/dev/null 2>&1; then
        action_status=1
        break
      fi
      _cntools_action_wallet_decrypt_file_same \
        "${backup}" "${identity}" "${digest}" || action_status=70
      [[ ! -e "${entry}" && ! -L "${entry}" ]] || action_status=70
      [[ "${action_status}" == 0 ]] || break
    done
  fi

  if [[ "${action_status}" != 0 ]]; then
    if [[ "${action_status}" == 1 ]]; then
      _cntools_action_wallet_decrypt_handled_error \
        'failed to unlock/decrypt wallet files; original encrypted wallet was preserved!'
      action_status=$?
    else
      _cntools_action_wallet_decrypt_precommit_cleanup || true
      _cntools_action_wallet_decrypt_validation_failure
      action_status=70
    fi
    trap - EXIT HUP INT TERM
    return "${action_status}"
  fi

  _cntools_action_wallet_decrypt_authority_same || action_status=70
  for (( cipher_index=0;
         cipher_index<${#wallet_decrypt_plain_paths[@]};
         cipher_index++ )); do
    target="${wallet_decrypt_plain_paths[cipher_index]}"
    identity="${wallet_decrypt_temp_identities[cipher_index]}"
    digest="${wallet_decrypt_temp_digests[cipher_index]}"
    _cntools_action_wallet_decrypt_file_same \
      "${target}" "${identity}" "${digest}" || action_status=70
    [[ ! -e "${wallet_decrypt_cipher_paths[cipher_index]}" &&
       ! -L "${wallet_decrypt_cipher_paths[cipher_index]}" ]] ||
      action_status=70
  done
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_decrypt_precommit_cleanup || true
    _cntools_action_wallet_decrypt_validation_failure
    return 70
  fi
  # Replace every rollback-capable trap in one builtin before marking the
  # operation committed. The transition handler still rolls back if invoked
  # before the assignment, and can only perform bounded post-commit cleanup
  # after it.
  trap '_cntools_action_wallet_decrypt_commit_transition' \
    EXIT HUP INT TERM
  wallet_decrypt_committed=Y
  filesUnlocked=${#wallet_decrypt_entries[@]}
  keysDecrypted=${#wallet_decrypt_cipher_paths[@]}
  if ! _cntools_action_wallet_decrypt_postcommit_cleanup; then
    wallet_decrypt_postcommit_warning=Y
  fi
  trap '_cntools_action_wallet_decrypt_postcommit_signal' HUP INT TERM
  trap - EXIT

  echo
  println "Wallet unprotected : ${FG_GREEN}${wallet_name}${NC}"
  println "Files unlocked     : ${FG_LBLUE}${filesUnlocked}${NC}"
  println "Files decrypted    : ${FG_LBLUE}${keysDecrypted}${NC}"
  if (( filesUnlocked != 0 || keysDecrypted != 0 )); then
    echo
    println DEBUG "${FG_YELLOW}Wallet files are now unprotected${NC}"
    println DEBUG "Use 'WALLET >> ENCRYPT' to re-lock"
  fi
  if [[ "${wallet_decrypt_postcommit_warning}" == Y ]]; then
    println ERROR "\n${FG_YELLOW}WARN${NC}: wallet decryption committed, but private cleanup was incomplete; the operation lock was retained."
  fi
  waitToProceed
  trap - HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
