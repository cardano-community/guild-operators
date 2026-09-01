#!/usr/bin/env bash
# Transactional GPG protection for local wallet signing keys. Loaded after
# wallet.sh, wallet-material.sh, and wallet-key.sh.
# shellcheck disable=SC2034,SC2178

declare -ag CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=()
declare -ag CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS=()
declare -ag CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES=()
declare -ag CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE=()
declare -g CNTOOLS_WALLET_PROTECTION_ERROR=""
declare -g CNTOOLS_WALLET_PROTECTION_WARNING=""
declare -g CNTOOLS_WALLET_PROTECTION_LOCK_METHOD="read-only permissions"
declare -g CNTOOLS_WALLET_PROTECTION_KEYS=0
declare -g CNTOOLS_WALLET_PROTECTION_FILES=0
declare -g CNTOOLS_WALLET_PROTECTION_GPG=""

cntools_wallet_protection_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_protection_set_error() {
  CNTOOLS_WALLET_PROTECTION_ERROR="${1:-Wallet protection failed.}"
  cntools_wallet_protection_log ERROR "${CNTOOLS_WALLET_PROTECTION_ERROR}"
}

cntools_wallet_protection_set_warning() {
  local message="${1:-}"

  [[ -n "${message}" ]] || return 0
  if [[ -n "${CNTOOLS_WALLET_PROTECTION_WARNING}" ]]; then
    CNTOOLS_WALLET_PROTECTION_WARNING+=" ${message}"
  else
    CNTOOLS_WALLET_PROTECTION_WARNING="${message}"
  fi
  cntools_wallet_protection_log WARN "${message}"
}

cntools_wallet_protection_reset_result() {
  CNTOOLS_WALLET_PROTECTION_ERROR=""
  CNTOOLS_WALLET_PROTECTION_WARNING=""
  CNTOOLS_WALLET_PROTECTION_LOCK_METHOD="read-only permissions"
  CNTOOLS_WALLET_PROTECTION_KEYS=0
  CNTOOLS_WALLET_PROTECTION_FILES=0
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS=()
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES=()
  CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=()
  CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE=()
}

cntools_wallet_protection_resolve_command_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_candidate=""
  local _cntools_resolved=""
  shift || return 2

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  for _cntools_candidate in "$@"; do
    _cntools_resolved="$(type -P "${_cntools_candidate}" 2>/dev/null || true)"
    [[ -n "${_cntools_resolved}" && "${_cntools_resolved}" = /* &&
       -x "${_cntools_resolved}" && ! -d "${_cntools_resolved}" ]] || continue
    _cntools_output_ref="${_cntools_resolved}"
    return 0
  done
  return 1
}

cntools_wallet_protection_environment_ready() {
  CNTOOLS_WALLET_PROTECTION_GPG=""
  cntools_wallet_root_safe || {
    cntools_wallet_protection_set_error \
      "The wallet directory is unavailable or unsafe: ${CNTOOLS_WALLET_DIR:-unset}"
    return 1
  }
  cntools_wallet_protection_resolve_command_into \
    CNTOOLS_WALLET_PROTECTION_GPG gpg gpg2 || {
    cntools_wallet_protection_set_error \
      "GnuPG is required for wallet encryption and decryption but was not found."
    return 1
  }
}

cntools_wallet_protection_directory_mutable() {
  local wallet_directory="${1:-}"
  local mode=""
  local mode_value=0

  cntools_wallet_directory_safe "${wallet_directory}" &&
    [[ -O "${wallet_directory}" && -w "${wallet_directory}" &&
       -x "${wallet_directory}" ]] || return 1
  if mode="$(stat -c '%a' -- "${wallet_directory}" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "${wallet_directory}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  mode_value=$((8#${mode}))
  (( (mode_value & 0022) == 0 ))
}

cntools_wallet_protection_material_tracked() {
  local requested="${1:-}"
  local tracked=""

  for tracked in "${CNTOOLS_WALLET_MATERIAL_TEMP_FILES[@]}"; do
    [[ "${tracked}" == "${requested}" ]] && return 0
  done
  return 1
}

cntools_wallet_protection_entries_safe() {
  local wallet_directory="${1:-}"
  local entry=""
  local -a entries=()

  cntools_wallet_protection_directory_mutable "${wallet_directory}" || {
    cntools_wallet_protection_set_error \
      "The wallet directory must be owned, writable, and protected from group or public writes."
    return 1
  }
  entries=(
    "${wallet_directory}"/*
    "${wallet_directory}"/.[!.]*
    "${wallet_directory}"/..?*
  )
  for entry in "${entries[@]}"; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    if [[ "${entry##*/}" == .cntools-* ]]; then
      cntools_wallet_protection_material_tracked "${entry}" && continue
      cntools_wallet_protection_set_error \
        "The wallet contains an unfinished CNTools transaction file."
      return 1
    fi
    [[ ! -L "${entry}" ]] || {
      cntools_wallet_protection_set_error \
        "The wallet contains an unsafe symbolic link: ${entry##*/}"
      return 1
    }
    [[ ! -f "${entry}" || -O "${entry}" ]] || {
      cntools_wallet_protection_set_error \
        "The wallet contains a file not owned by the current user: ${entry##*/}"
      return 1
    }
  done
}

cntools_wallet_protection_keys_into() {
  local _cntools_files_name="${1:-}"
  local _cntools_roles_name="${2:-}"
  local _cntools_operation="${3:-}"
  local _cntools_wallet_directory="${4:-}"
  local _cntools_role=""
  local _cntools_filename=""
  local _cntools_clear_file=""
  local _cntools_encrypted_file=""
  local _cntools_candidate=""
  local _cntools_allowed_gpg=""
  local _cntools_signing_form=""
  local _cntools_encrypted_entry_count=0
  local -a _cntools_all_gpg=()

  [[ "${_cntools_files_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_roles_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_files_ref="${_cntools_files_name}"
  local -n _cntools_roles_ref="${_cntools_roles_name}"
  _cntools_files_ref=()
  _cntools_roles_ref=()
  cntools_wallet_protection_entries_safe \
    "${_cntools_wallet_directory}" || return 1

  if [[ "${_cntools_operation}" == "encrypt" ]]; then
    _cntools_all_gpg=("${_cntools_wallet_directory}"/*.gpg)
    for _cntools_candidate in "${_cntools_all_gpg[@]}"; do
      [[ -e "${_cntools_candidate}" || -L "${_cntools_candidate}" ]] || continue
      cntools_wallet_protection_set_error \
        "The wallet already contains encrypted or mixed key material. Decrypt or repair it before encrypting."
      return 1
    done
  elif [[ "${_cntools_operation}" == "decrypt" ]]; then
    _cntools_all_gpg=("${_cntools_wallet_directory}"/*.gpg)
    for _cntools_candidate in "${_cntools_all_gpg[@]}"; do
      [[ -e "${_cntools_candidate}" || -L "${_cntools_candidate}" ]] || continue
      _cntools_encrypted_entry_count=$((_cntools_encrypted_entry_count + 1))
      _cntools_allowed_gpg="${_cntools_candidate##*/}"
      case "${_cntools_allowed_gpg}" in
        "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}.gpg"|\
        "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}.gpg") ;;
        *)
          cntools_wallet_protection_set_error \
            "The wallet contains an unsupported encrypted file: ${_cntools_allowed_gpg}"
          return 1
          ;;
      esac
    done
  fi

  for _cntools_role in payment stake; do
    if [[ "${_cntools_role}" == "payment" ]]; then
      _cntools_filename="${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
    else
      _cntools_filename="${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
    fi
    _cntools_clear_file="${_cntools_wallet_directory}/${_cntools_filename}"
    _cntools_encrypted_file="${_cntools_clear_file}.gpg"
    case "${_cntools_operation}" in
      encrypt)
        if [[ -e "${_cntools_encrypted_file}" || -L "${_cntools_encrypted_file}" ]]; then
          cntools_wallet_protection_set_error \
            "Both clear and encrypted ${_cntools_role} key entries must not coexist."
          return 1
        fi
        [[ -e "${_cntools_clear_file}" || -L "${_cntools_clear_file}" ]] || continue
        if [[ ! -f "${_cntools_clear_file}" || -L "${_cntools_clear_file}" ||
              ! -O "${_cntools_clear_file}" ]] ||
           ! cntools_wallet_key_signing_type \
             "${_cntools_role}" "${_cntools_clear_file}" _cntools_signing_form; then
          cntools_wallet_protection_set_error \
            "The ${_cntools_role} signing key is unsafe or invalid."
          return 1
        fi
        _cntools_files_ref+=("${_cntools_clear_file}")
        ;;
      decrypt)
        if [[ -e "${_cntools_clear_file}" || -L "${_cntools_clear_file}" ]]; then
          if (( _cntools_encrypted_entry_count > 0 )); then
            cntools_wallet_protection_set_error \
              "Clear and encrypted signing keys coexist in this wallet. Neither was changed."
            return 1
          fi
          continue
        fi
        [[ -e "${_cntools_encrypted_file}" || -L "${_cntools_encrypted_file}" ]] || continue
        if ! cntools_wallet_safe_regular_file \
             "${_cntools_encrypted_file}" 1048576 ||
           [[ ! -O "${_cntools_encrypted_file}" ]]; then
          cntools_wallet_protection_set_error \
            "The encrypted ${_cntools_role} signing key is unsafe or invalid."
          return 1
        fi
        _cntools_files_ref+=("${_cntools_encrypted_file}")
        ;;
      *) return 2 ;;
    esac
    _cntools_roles_ref+=("${_cntools_role}")
  done
  if (( ${#_cntools_files_ref[@]} == 0 )); then
    if [[ "${_cntools_operation}" == "encrypt" ]]; then
      cntools_wallet_protection_set_error \
        "This wallet has no clear payment or stake signing keys to encrypt."
    else
      cntools_wallet_protection_set_error \
        "This wallet has no encrypted payment or stake signing keys to decrypt."
    fi
    return 1
  fi
}

cntools_wallet_protection_gpg_error() {
  local operation="${1:-operation}"
  local status="${2:-1}"
  local error_file="${3:-}"
  local detail=""

  if [[ -f "${error_file}" && ! -L "${error_file}" ]]; then
    IFS= read -r detail < "${error_file}" || true
    detail="${detail:0:300}"
    if declare -F cntools_log_sanitize_line >/dev/null 2>&1; then
      detail="$(cntools_log_sanitize_line "${detail}")"
    fi
  fi
  cntools_wallet_protection_log ERROR \
    "GPG ${operation} failed status=${status}${detail:+: ${detail}}"
}

cntools_wallet_protection_gpg_run() {
  local operation="${1:-}"
  local source_file="${2:-}"
  local output_file="${3:-}"
  local passphrase="${4:-}"
  local error_file="${5:-}"
  local mask=""
  local status=0
  local -a command=()

  [[ -n "${CNTOOLS_WALLET_PROTECTION_GPG}" &&
     -x "${CNTOOLS_WALLET_PROTECTION_GPG}" &&
     -f "${source_file}" && ! -L "${source_file}" &&
     -f "${output_file}" && ! -L "${output_file}" &&
     -f "${error_file}" && ! -L "${error_file}" &&
     "${passphrase}" != *$'\n'* && "${passphrase}" != *$'\r'* ]] || return 2
  command=(
    "${CNTOOLS_WALLET_PROTECTION_GPG}"
    --no-options --quiet --batch --yes --no-tty
    --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3
    --output "${output_file}"
  )
  case "${operation}" in
    encrypt)
      command+=(--symmetric --cipher-algo AES256 "${source_file}")
      ;;
    decrypt)
      command+=(--decrypt "${source_file}")
      ;;
    *) return 2 ;;
  esac
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  if cntools_run_command_timeout 60 "${mask}" -- \
      "${command[@]}" 3<<< "${passphrase}" \
      >/dev/null 2> "${error_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_protection_gpg_error \
      "${operation}" "${status}" "${error_file}"
  fi
  return "${status}"
}

cntools_wallet_protection_stage_encrypt() {
  local _cntools_output_name="${1:-}"
  local _cntools_source_file="${2:-}"
  local _cntools_role="${3:-}"
  local _cntools_passphrase="${4:-}"
  local _cntools_wallet_directory="${_cntools_source_file%/*}"
  local _cntools_staged=""
  local _cntools_roundtrip=""
  local _cntools_error=""
  local _cntools_signing_form=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_key_signing_type \
    "${_cntools_role}" "${_cntools_source_file}" _cntools_signing_form || return 1
  cntools_wallet_material_temp_file \
    _cntools_staged "${_cntools_wallet_directory}" \
    "protect-${_cntools_role}-encrypted" || return 1
  cntools_wallet_material_temp_file \
    _cntools_roundtrip "${_cntools_wallet_directory}" \
    "protect-${_cntools_role}-roundtrip" || return 1
  cntools_wallet_material_temp_file \
    _cntools_error "${_cntools_wallet_directory}" \
    "protect-${_cntools_role}-gpg-error" || return 1
  if ! cntools_wallet_protection_gpg_run encrypt \
      "${_cntools_source_file}" "${_cntools_staged}" \
      "${_cntools_passphrase}" "${_cntools_error}" ||
     ! cntools_wallet_safe_regular_file "${_cntools_staged}" 1048576 ||
     ! cntools_wallet_protection_gpg_run decrypt \
       "${_cntools_staged}" "${_cntools_roundtrip}" \
       "${_cntools_passphrase}" "${_cntools_error}" ||
     ! cntools_wallet_key_signing_type \
       "${_cntools_role}" "${_cntools_roundtrip}" _cntools_signing_form ||
     ! jq -e -s 'length == 2 and .[0] == .[1]' \
       "${_cntools_source_file}" "${_cntools_roundtrip}" >/dev/null 2>&1; then
    cntools_wallet_protection_set_error \
      "The ${_cntools_role} signing key could not be encrypted and verified."
    return 1
  fi
  chmod 0600 -- "${_cntools_staged}" || return 1
  cntools_wallet_material_remove_temp "${_cntools_roundtrip}" || true
  cntools_wallet_material_remove_temp "${_cntools_error}" || true
  _cntools_output_ref="${_cntools_staged}"
}

cntools_wallet_protection_stage_decrypt() {
  local _cntools_output_name="${1:-}"
  local _cntools_source_file="${2:-}"
  local _cntools_role="${3:-}"
  local _cntools_passphrase="${4:-}"
  local _cntools_wallet_directory="${_cntools_source_file%/*}"
  local _cntools_staged=""
  local _cntools_error=""
  local _cntools_signing_form=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_material_temp_file \
    _cntools_staged "${_cntools_wallet_directory}" \
    "unprotect-${_cntools_role}-clear" || return 1
  cntools_wallet_material_temp_file \
    _cntools_error "${_cntools_wallet_directory}" \
    "unprotect-${_cntools_role}-gpg-error" || return 1
  if ! cntools_wallet_protection_gpg_run decrypt \
      "${_cntools_source_file}" "${_cntools_staged}" \
      "${_cntools_passphrase}" "${_cntools_error}" ||
     ! cntools_wallet_key_signing_type \
       "${_cntools_role}" "${_cntools_staged}" _cntools_signing_form; then
    cntools_wallet_protection_set_error \
      "The encrypted wallet could not be opened. Check the passphrase and encrypted files."
    return 1
  fi
  chmod 0600 -- "${_cntools_staged}" || return 1
  cntools_wallet_material_remove_temp "${_cntools_error}" || true
  _cntools_output_ref="${_cntools_staged}"
}

cntools_wallet_protection_publish() {
  local staged_file="${1:-}"
  local target_file="${2:-}"
  local source_file="${3:-}"

  [[ -f "${staged_file}" && ! -L "${staged_file}" && -O "${staged_file}" &&
     ! -e "${target_file}" && ! -L "${target_file}" &&
     "${target_file%/*}" == "${source_file%/*}" ]] || return 1
  chmod 0600 -- "${staged_file}" || return 1
  ln -- "${staged_file}" "${target_file}" 2>/dev/null || return 1
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS+=("${target_file}")
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES+=("${source_file}")
}

cntools_wallet_protection_remove_published() {
  local target=""

  for target in "${CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS[@]}"; do
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || continue
    rm -f -- "${target}" 2>/dev/null || true
  done
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS=()
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES=()
}

cntools_wallet_protection_files_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_wallet_directory="${2:-}"
  local _cntools_entry=""
  local -a _cntools_entries=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=()
  cntools_wallet_protection_entries_safe \
    "${_cntools_wallet_directory}" || return 1
  _cntools_entries=(
    "${_cntools_wallet_directory}"/*
    "${_cntools_wallet_directory}"/.[!.]*
    "${_cntools_wallet_directory}"/..?*
  )
  for _cntools_entry in "${_cntools_entries[@]}"; do
    [[ -f "${_cntools_entry}" && ! -L "${_cntools_entry}" ]] || continue
    [[ "${_cntools_entry##*/}" != .cntools-* ]] || continue
    [[ "${_cntools_entry}" != *.addr ]] || continue
    _cntools_output_ref+=("${_cntools_entry}")
  done
}

cntools_wallet_protection_chattr_run() {
  local flag="${1:-}"
  local file="${2:-}"
  local mask=""
  local -a command=("${CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND[@]}")

  [[ "${flag}" == "+i" || "${flag}" == "-i" ]] || return 2
  (( ${#command[@]} > 0 )) || return 2
  command+=("${flag}" -- "${file}")
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  cntools_run_command "${mask}" -- "${command[@]}" >/dev/null 2>&1
}

cntools_wallet_protection_chattr_prepare() {
  local wallet_directory="${1:-}"
  local chattr=""
  local sudo_command=""
  local test_file=""
  local candidate_status=1

  CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=()
  cntools_wallet_protection_resolve_command_into chattr chattr || return 1
  cntools_wallet_material_temp_file \
    test_file "${wallet_directory}" "protect-chattr-test" || return 1

  CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=("${chattr}")
  if cntools_wallet_protection_chattr_run +i "${test_file}" &&
     cntools_wallet_protection_chattr_run -i "${test_file}"; then
    candidate_status=0
  else
    CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=()
  fi
  if (( candidate_status != 0 )) &&
     cntools_wallet_protection_resolve_command_into sudo_command sudo; then
    CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=("${sudo_command}" -n "${chattr}")
    if cntools_wallet_protection_chattr_run +i "${test_file}" &&
       cntools_wallet_protection_chattr_run -i "${test_file}"; then
      candidate_status=0
    else
      CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=()
    fi
  fi
  cntools_wallet_material_remove_temp "${test_file}" || true
  return "${candidate_status}"
}

cntools_wallet_protection_immutable_files_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_wallet_directory="${2:-}"
  local _cntools_lsattr=""
  local _cntools_file=""
  local _cntools_attributes=""
  local _cntools_mask=""
  local -a _cntools_files=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=()
  cntools_wallet_protection_resolve_command_into _cntools_lsattr lsattr || return 0
  cntools_wallet_protection_files_into \
    _cntools_files "${_cntools_wallet_directory}" || return 1
  for _cntools_file in "${_cntools_files[@]}"; do
    printf -v _cntools_mask '%*s' 4 ''
    _cntools_mask="${_cntools_mask// /0}"
    _cntools_attributes="$(cntools_run_command "${_cntools_mask}" -- \
      "${_cntools_lsattr}" -d -- "${_cntools_file}" 2>/dev/null || true)"
    _cntools_attributes="${_cntools_attributes%% *}"
    [[ "${_cntools_attributes}" == *i* ]] || continue
    _cntools_output_ref+=("${_cntools_file}")
  done
}

cntools_wallet_protection_apply_locks() {
  local wallet_directory="${1:-}"
  local file=""
  local applied=""
  local failures=0
  local -a files=()
  local -a immutable_applied=()

  cntools_wallet_protection_files_into files "${wallet_directory}" || return 1
  for file in "${files[@]}"; do
    if ! cntools_run_command 000 -- chmod 0400 "${file}" >/dev/null 2>&1; then
      failures=$((failures + 1))
    fi
  done
  CNTOOLS_WALLET_PROTECTION_FILES="${#files[@]}"
  if (( failures > 0 )); then
    cntools_wallet_protection_set_warning \
      "${failures} wallet file(s) could not be made read-only."
  fi

  [[ "${CNTOOLS_ENABLE_CHATTR:-true}" == "true" ]] || return 0
  if ! cntools_wallet_protection_chattr_prepare "${wallet_directory}"; then
    cntools_wallet_protection_set_warning \
      "Immutable file locking was unavailable; read-only permissions remain active."
    return 0
  fi
  for file in "${files[@]}"; do
    if cntools_wallet_protection_chattr_run +i "${file}"; then
      immutable_applied+=("${file}")
    else
      for applied in "${immutable_applied[@]}"; do
        cntools_wallet_protection_chattr_run -i "${applied}" || true
      done
      cntools_wallet_protection_set_warning \
        "Immutable file locking could not be applied completely; read-only permissions remain active."
      return 0
    fi
  done
  CNTOOLS_WALLET_PROTECTION_LOCK_METHOD="read-only permissions + immutable flag"
}

cntools_wallet_protection_clear_immutable() {
  local wallet_directory="${1:-}"
  local file=""
  local restored=""
  local -a immutable_files=()
  local -a cleared=()

  cntools_wallet_protection_immutable_files_into \
    immutable_files "${wallet_directory}" || return 1
  CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE=()
  (( ${#immutable_files[@]} > 0 )) || return 0
  if ! cntools_wallet_protection_chattr_prepare "${wallet_directory}"; then
    cntools_wallet_protection_set_error \
      "The wallet is immutable and CNTools could not obtain chattr permission to unlock it."
    return 1
  fi
  for file in "${immutable_files[@]}"; do
    if cntools_wallet_protection_chattr_run -i "${file}"; then
      cleared+=("${file}")
      CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE+=("${file}")
    else
      for restored in "${cleared[@]}"; do
        cntools_wallet_protection_chattr_run +i "${restored}" || true
      done
      cntools_wallet_protection_set_error \
        "Immutable wallet files could not all be unlocked. No key files were changed."
      CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE=()
      return 1
    fi
  done
}

cntools_wallet_protection_restore_immutable() {
  local file=""

  (( ${#CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE[@]} > 0 )) || return 0
  (( ${#CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND[@]} > 0 )) || return 1
  for file in "${CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE[@]}"; do
    [[ -f "${file}" && ! -L "${file}" ]] || continue
    cntools_wallet_protection_chattr_run +i "${file}" || return 1
  done
  CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE=()
}

cntools_wallet_protection_unlock_permissions() {
  local wallet_directory="${1:-}"
  local file=""
  local failures=0
  local -a files=()

  cntools_wallet_protection_files_into files "${wallet_directory}" || return 1
  for file in "${files[@]}"; do
    if ! cntools_run_command 000 -- chmod 0600 "${file}" >/dev/null 2>&1; then
      failures=$((failures + 1))
    fi
  done
  CNTOOLS_WALLET_PROTECTION_FILES="${#files[@]}"
  if (( failures > 0 )); then
    cntools_wallet_protection_set_warning \
      "${failures} wallet file(s) could not be restored to owner-only write access."
  fi
}

cntools_wallet_protection_remove_sources() {
  local file=""
  local failures=0

  for file in "$@"; do
    if ! cntools_run_command 0000 -- rm -f -- "${file}" >/dev/null 2>&1; then
      failures=$((failures + 1))
    fi
  done
  (( failures == 0 ))
}

cntools_wallet_protection_encrypt() {
  local wallet_directory="${1:-}"
  local passphrase="${2:-}"
  local index=0
  local staged=""
  local target=""
  local recovery=""
  local source=""
  local role=""
  local rollback_failed=0
  local -a sources=()
  local -a roles=()
  local -a staged_files=()

  cntools_wallet_protection_reset_result
  [[ ${#passphrase} -ge 12 && "${passphrase}" != *$'\n'* &&
     "${passphrase}" != *$'\r'* ]] || {
    cntools_wallet_protection_set_error \
      "New wallet passphrases must contain at least 12 characters and no line breaks."
    return 2
  }
  cntools_wallet_protection_environment_ready || return 1
  cntools_wallet_protection_keys_into \
    sources roles encrypt "${wallet_directory}" || return 1
  cntools_wallet_protection_log WALLET \
    "encrypting wallet=${wallet_directory##*/} keys=${#sources[@]} cipher=AES256"

  for ((index = 0; index < ${#sources[@]}; index++)); do
    if ! cntools_wallet_protection_stage_encrypt staged \
        "${sources[index]}" "${roles[index]}" "${passphrase}"; then
      cntools_wallet_material_cleanup
      return 1
    fi
    staged_files+=("${staged}")
  done
  for ((index = 0; index < ${#sources[@]}; index++)); do
    target="${sources[index]}.gpg"
    if ! cntools_wallet_protection_publish \
        "${staged_files[index]}" "${target}" "${sources[index]}"; then
      cntools_wallet_protection_set_error \
        "The encrypted signing keys could not be published atomically."
      cntools_wallet_protection_remove_published
      cntools_wallet_material_cleanup
      return 1
    fi
  done
  if ! cntools_wallet_protection_remove_sources "${sources[@]}"; then
    # Recover any clear key already removed before discarding the new encrypted
    # targets. This path is deliberately conservative and should only be
    # reachable after a concurrent filesystem or permission change.
    for ((index = 0; index < ${#sources[@]}; index++)); do
      source="${sources[index]}"
      [[ -e "${source}" || -L "${source}" ]] && continue
      target="${source}.gpg"
      if cntools_wallet_protection_stage_decrypt recovery \
          "${target}" "${roles[index]}" "${passphrase}" &&
         cntools_wallet_protection_publish \
          "${recovery}" "${source}" "${target}"; then
        :
      else
        rollback_failed=$((rollback_failed + 1))
      fi
    done
    if (( rollback_failed == 0 )); then
      for target in "${sources[@]}"; do
        rm -f -- "${target}.gpg" 2>/dev/null || true
      done
    fi
    cntools_wallet_protection_set_error \
      "The clear signing keys could not all be retired after encryption. Review the wallet before retrying."
    cntools_wallet_material_cleanup
    return 1
  fi

  CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS=()
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES=()
  CNTOOLS_WALLET_PROTECTION_KEYS="${#sources[@]}"
  cntools_wallet_material_cleanup
  cntools_wallet_protection_apply_locks "${wallet_directory}" || {
    cntools_wallet_protection_set_warning \
      "Wallet encryption succeeded, but file locking could not be completed."
  }
  cntools_wallet_protection_log WALLET \
    "encrypted wallet=${wallet_directory##*/} keys=${CNTOOLS_WALLET_PROTECTION_KEYS} files=${CNTOOLS_WALLET_PROTECTION_FILES} lock=${CNTOOLS_WALLET_PROTECTION_LOCK_METHOD}"
}

cntools_wallet_protection_decrypt() {
  local wallet_directory="${1:-}"
  local passphrase="${2:-}"
  local index=0
  local staged=""
  local target=""
  local source=""
  local backup=""
  local published_index=0
  local published_target=""
  local published_source=""
  local restore_failures=0
  local -a sources=()
  local -a roles=()
  local -a staged_files=()
  local -a backup_files=()

  cntools_wallet_protection_reset_result
  [[ -n "${passphrase}" && "${passphrase}" != *$'\n'* &&
     "${passphrase}" != *$'\r'* ]] || {
    cntools_wallet_protection_set_error \
      "Enter the wallet passphrase without line breaks."
    return 2
  }
  cntools_wallet_protection_environment_ready || return 1
  cntools_wallet_protection_keys_into \
    sources roles decrypt "${wallet_directory}" || return 1
  cntools_wallet_protection_log WALLET \
    "decrypting wallet=${wallet_directory##*/} keys=${#sources[@]}"

  for ((index = 0; index < ${#sources[@]}; index++)); do
    if ! cntools_wallet_protection_stage_decrypt staged \
        "${sources[index]}" "${roles[index]}" "${passphrase}"; then
      cntools_wallet_material_cleanup
      return 1
    fi
    staged_files+=("${staged}")
    cntools_wallet_material_temp_file backup "${wallet_directory}" \
      "unprotect-${roles[index]}-encrypted-backup" || {
        cntools_wallet_protection_set_error \
          "An encrypted-key rollback copy could not be prepared."
        cntools_wallet_material_cleanup
        return 1
      }
    if ! cntools_run_command 0000 -- \
       cp -- "${sources[index]}" "${backup}" >/dev/null 2>&1 ||
       ! chmod 0600 -- "${backup}"; then
      cntools_wallet_protection_set_error \
        "An encrypted-key rollback copy could not be prepared."
      cntools_wallet_material_cleanup
      return 1
    fi
    backup_files+=("${backup}")
  done

  cntools_wallet_protection_clear_immutable "${wallet_directory}" || {
    cntools_wallet_material_cleanup
    return 1
  }
  for ((index = 0; index < ${#sources[@]}; index++)); do
    target="${sources[index]%.gpg}"
    if ! cntools_wallet_protection_publish \
        "${staged_files[index]}" "${target}" "${sources[index]}"; then
      cntools_wallet_protection_set_error \
        "The clear signing keys could not be published atomically."
      cntools_wallet_protection_remove_published
      cntools_wallet_protection_restore_immutable || true
      cntools_wallet_material_cleanup
      return 1
    fi
  done
  if ! cntools_wallet_protection_remove_sources "${sources[@]}"; then
    for ((index = 0; index < ${#sources[@]}; index++)); do
      source="${sources[index]}"
      [[ -e "${source}" || -L "${source}" ]] && continue
      if ln -- "${backup_files[index]}" "${source}" 2>/dev/null &&
         chmod 0400 -- "${source}" 2>/dev/null; then
        :
      else
        restore_failures=$((restore_failures + 1))
      fi
    done
    # Remove a newly published plaintext only when its encrypted counterpart
    # is known to exist. If rollback publication itself failed, retaining the
    # validated plaintext is safer than discarding the last usable key copy.
    for ((published_index = 0;
         published_index < ${#CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS[@]};
         published_index++)); do
      published_target="${CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS[published_index]}"
      published_source="${CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES[published_index]:-}"
      [[ -f "${published_source}" && ! -L "${published_source}" ]] || continue
      rm -f -- "${published_target}" 2>/dev/null || true
    done
    CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS=()
    CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES=()
    cntools_wallet_protection_restore_immutable || true
    if (( restore_failures == 0 )); then
      cntools_wallet_protection_set_error \
        "The encrypted signing keys could not all be retired. The protected wallet was retained."
    else
      cntools_wallet_protection_set_error \
        "The encrypted signing keys could not all be retired or restored. Validated plaintext was retained where required; review the wallet before retrying."
    fi
    cntools_wallet_material_cleanup
    return 1
  fi

  CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS=()
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES=()
  CNTOOLS_WALLET_PROTECTION_KEYS="${#sources[@]}"
  CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE=()
  cntools_wallet_material_cleanup
  cntools_wallet_protection_unlock_permissions "${wallet_directory}" || {
    cntools_wallet_protection_set_warning \
      "Wallet decryption succeeded, but some file permissions could not be restored."
  }
  cntools_wallet_protection_log WALLET \
    "decrypted wallet=${wallet_directory##*/} keys=${CNTOOLS_WALLET_PROTECTION_KEYS} files=${CNTOOLS_WALLET_PROTECTION_FILES}"
}

cntools_wallet_protection_cleanup() {
  local index=0
  local target=""
  local source=""

  # If an action is interrupted before committing, retain its original source
  # and discard only the newly published counterpart.
  for ((index = 0;
       index < ${#CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS[@]};
       index++)); do
    target="${CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS[index]}"
    source="${CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES[index]:-}"
    [[ -f "${source}" && ! -L "${source}" ]] || continue
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || continue
    rm -f -- "${target}" 2>/dev/null || true
  done
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_TARGETS=()
  CNTOOLS_WALLET_PROTECTION_PUBLISHED_SOURCES=()
  CNTOOLS_WALLET_PROTECTION_CHATTR_COMMAND=()
  CNTOOLS_WALLET_PROTECTION_CLEARED_IMMUTABLE=()
  cntools_wallet_material_cleanup
}
