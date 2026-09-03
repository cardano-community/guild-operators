#!/usr/bin/env bash
# Shared CNTools transaction context and portable package contract. Functions only.
# shellcheck disable=SC2034,SC2178

CNTOOLS_TRANSACTION_SCHEMA="org.cardano-community.cntools.transaction"
CNTOOLS_TRANSACTION_SCHEMA_VERSION=1
CNTOOLS_TRANSACTION_MAX_BODY_BYTES=4194304
CNTOOLS_TRANSACTION_MAX_WITNESS_BYTES=524288
CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES=16777216
CNTOOLS_TRANSACTION_CARDANO_CLI_VERSION="11.0.0.0"
CNTOOLS_TRANSACTION_TIMEOUT="${CNTOOLS_TRANSACTION_TIMEOUT:-60}"
[[ "${CNTOOLS_TRANSACTION_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
  CNTOOLS_TRANSACTION_TIMEOUT=60
CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TRANSACTION_OPENSSL:-}"
CNTOOLS_TRANSACTION_XXD="${CNTOOLS_TRANSACTION_XXD:-}"
# RFC 8410 SubjectPublicKeyInfo header for an Ed25519 OID followed by a
# 32-byte raw public key. Cardano API 11 signs the raw 32-byte transaction-body
# hash, which is the binary value represented by `cardano-cli transaction txid`.
CNTOOLS_TRANSACTION_ED25519_SPKI_PREFIX="302a300506032b6570032100"
CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH=""
CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION=""

declare -ag CNTOOLS_TRANSACTION_TEMP_FILES=()
CNTOOLS_TRANSACTION_TEMP_DIR=""
CNTOOLS_TRANSACTION_TEMP_BASE=""
declare -ag CNTOOLS_TRANSACTION_NETWORK_ARGS=()
declare -Ag CNTOOLS_TRANSACTION_RUNTIME_SOURCES=()
declare -Ag CNTOOLS_TRANSACTION_RUNTIME_SOURCE_KINDS=()
declare -Ag CNTOOLS_TRANSACTION_RUNTIME_CHANGE_SOURCES=()
declare -Ag CNTOOLS_TRANSACTION_CREDENTIAL_CACHE=()

CNTOOLS_TRANSACTION_ERROR=""
CNTOOLS_TRANSACTION_PLAN_READY="N"
CNTOOLS_TRANSACTION_PLAN_INTENT=""
CNTOOLS_TRANSACTION_PLAN_DESCRIPTION=""
CNTOOLS_TRANSACTION_PLAN_ASSURANCE="exact"
CNTOOLS_TRANSACTION_PLAN_SUMMARY='{}'
CNTOOLS_TRANSACTION_PLAN_REQUIRED='[]'
CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS='[]'
CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS='[]'
CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE=""
CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER=""

CNTOOLS_TRANSACTION_PACKAGE_FILE=""
CNTOOLS_TRANSACTION_BODY_FILE=""
CNTOOLS_TRANSACTION_SIGNED_FILE=""
CNTOOLS_TRANSACTION_ID=""
CNTOOLS_TRANSACTION_PACKAGE_NETWORK=""
CNTOOLS_TRANSACTION_PACKAGE_ASSURANCE=""
CNTOOLS_TRANSACTION_PACKAGE_INTENT=""
CNTOOLS_TRANSACTION_PACKAGE_DESCRIPTION=""
CNTOOLS_TRANSACTION_PACKAGE_INVALID_BEFORE=""
CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER=""
CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED="N"
CNTOOLS_TRANSACTION_REQUIRED_COUNT=0
CNTOOLS_TRANSACTION_WITNESS_COUNT=0
CNTOOLS_TRANSACTION_COMPLETE="N"

cntools_transaction_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_transaction_set_error() {
  CNTOOLS_TRANSACTION_ERROR="${1:-Transaction operation failed.}"
  cntools_transaction_log ERROR "${CNTOOLS_TRANSACTION_ERROR}"
}

cntools_transaction_clear_error() {
  CNTOOLS_TRANSACTION_ERROR=""
}

cntools_transaction_text_control_free() {
  local value="${1:-}"
  local LC_ALL=C

  [[ -n "${value}" && ! "${value}" =~ [[:cntrl:]] ]]
}

cntools_transaction_reference_input_valid() {
  local reference_input="${1:-}"
  local output_index=""

  [[ "${reference_input}" =~ ^[0-9a-f]{64}#(0|[1-9][0-9]*)$ ]] ||
    return 1
  output_index="${reference_input##*#}"
  # Cardano transaction output indexes are Word32 values. Limit the decimal
  # representation before arithmetic so even malicious input cannot overflow
  # Bash's signed integer parser.
  (( ${#output_index} <= 10 )) || return 1
  (( 10#${output_index} <= 4294967295 ))
}

cntools_transaction_path_components_safe() {
  local path="${1:-}"
  local current="/"
  local component=""
  local -a components=()

  [[ "${path}" = /* ]] || return 1
  cntools_transaction_text_control_free "${path}" || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ ! -L "${current}" ]] || return 1
  done
}

cntools_transaction_size_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_size=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_size="$(stat -c '%s' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_size="$(stat -f '%z' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_size}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_size}"
}

cntools_transaction_file_safe() {
  local file="${1:-}"
  local maximum_bytes="${2:-${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}}"
  local size=""

  [[ -n "${file}" && "${file}" = /* &&
     "${maximum_bytes}" =~ ^[1-9][0-9]*$ &&
     -f "${file}" && ! -L "${file}" && -r "${file}" ]] || return 1
  cntools_transaction_path_components_safe "${file}" || return 1
  cntools_transaction_size_into size "${file}" || return 1
  [[ "${size}" =~ ^[1-9][0-9]*$ && ${size} -le ${maximum_bytes} ]]
}

cntools_transaction_mode_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_mode=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_mode="$(stat -c '%a' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_mode="$(stat -f '%Lp' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  _cntools_output_ref="${_cntools_mode}"
}

cntools_transaction_uid_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_uid=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_uid="$(stat -c '%u' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_uid="$(stat -f '%u' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_uid}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_uid}"
}

# Files used by external signing tools must not sit below a directory another
# user can replace. Root-owned and current-user-owned ancestors are trusted;
# shared writable ancestors are only accepted when protected by the sticky bit
# (for example /tmp with mode 1777).
cntools_transaction_directory_ancestry_safe() {
  local directory="${1:-}"
  local current="/"
  local component=""
  local mode=""
  local uid=""
  local permissions=0
  local -a components=()

  [[ -n "${directory}" && "${directory}" = /* ]] || return 1
  cntools_transaction_text_control_free "${directory}" || return 1
  IFS='/' read -r -a components <<< "${directory}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
    cntools_transaction_uid_into uid "${current}" || return 1
    [[ "${uid}" == "${EUID}" || "${uid}" == "0" ]] || return 1
    cntools_transaction_mode_into mode "${current}" || return 1
    permissions=$((8#${mode}))
    if (( (permissions & 0022) != 0 &&
          (permissions & 01000) == 0 )); then
      return 1
    fi
  done
}

cntools_transaction_directory_safe() {
  local directory="${1:-}"
  local mode=""
  local permissions=0

  [[ -n "${directory}" && "${directory}" = /* &&
     -d "${directory}" && ! -L "${directory}" &&
     -O "${directory}" && -w "${directory}" &&
     -x "${directory}" ]] || return 1
  cntools_transaction_text_control_free "${directory}" || return 1
  cntools_transaction_path_components_safe "${directory}" || return 1
  cntools_transaction_directory_ancestry_safe "${directory}" || return 1
  cntools_transaction_mode_into mode "${directory}" || return 1
  permissions=$((8#${mode}))
  (( (permissions & 0022) == 0 ))
}

cntools_transaction_temp_directory_ensure() {
  local base="${CNTOOLS_TMP_DIR:-}"
  local directory=""
  local previous_umask=""
  local mode=""

  if [[ -n "${CNTOOLS_TRANSACTION_TEMP_DIR}" ]]; then
    cntools_transaction_directory_safe \
      "${CNTOOLS_TRANSACTION_TEMP_BASE}" || return 1
    cntools_transaction_directory_safe \
      "${CNTOOLS_TRANSACTION_TEMP_DIR}" || return 1
    cntools_transaction_mode_into \
      mode "${CNTOOLS_TRANSACTION_TEMP_DIR}" || return 1
    [[ "${mode}" == "700" || "${mode}" == "0700" ]] || return 1
    return 0
  fi
  if ! cntools_transaction_directory_safe "${base}"; then
    cntools_transaction_set_error \
      "The CNTools temporary directory must be owned, writable, and protected from group or public writes."
    return 1
  fi
  previous_umask="$(umask)"
  umask 077
  directory="$(mktemp -d \
    "${base}/.cntools-transaction-action.XXXXXX")" || {
    umask "${previous_umask}"
    cntools_transaction_set_error \
      "A private transaction workspace could not be created."
    return 1
  }
  umask "${previous_umask}"
  if ! chmod 0700 -- "${directory}" ||
     ! cntools_transaction_directory_safe "${directory}" ||
     ! cntools_transaction_mode_into mode "${directory}" ||
     [[ "${mode}" != "700" && "${mode}" != "0700" ]]; then
    rmdir -- "${directory}" 2>/dev/null || true
    cntools_transaction_set_error \
      "The private transaction workspace failed its permission check."
    return 1
  fi
  CNTOOLS_TRANSACTION_TEMP_BASE="${base}"
  CNTOOLS_TRANSACTION_TEMP_DIR="${directory}"
}

cntools_transaction_private_file_safe() {
  local file="${1:-}"
  local mode=""
  local permissions=0

  cntools_transaction_file_safe "${file}" 65536 || return 1
  # Key and hardware-signing files are reopened by cardano-cli/cardano-hw-cli
  # after CNTools has inspected them. A private file in a replaceable shared
  # directory would therefore still be vulnerable to a path-swap race.
  cntools_transaction_directory_safe "${file%/*}" || return 1
  [[ -O "${file}" ]] || return 1
  cntools_transaction_mode_into mode "${file}" || return 1
  permissions=$((8#${mode}))
  # Signing sources are private material. Refuse group/public access entirely,
  # not only writes, so a copied or accidentally relaxed key is never used.
  (( (permissions & 0077) == 0 ))
}

cntools_transaction_input_path_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_input="${2:-}"
  local _cntools_parent=""
  local _cntools_name=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_text_control_free "${_cntools_input}" || return 1
  if [[ "${_cntools_input}" != /* ]]; then
    _cntools_input="${PWD%/}/${_cntools_input}"
  fi
  _cntools_parent="${_cntools_input%/*}"
  _cntools_name="${_cntools_input##*/}"
  [[ -n "${_cntools_parent}" && -n "${_cntools_name}" &&
     "${_cntools_name}" != "." && "${_cntools_name}" != ".." &&
     -d "${_cntools_parent}" && ! -L "${_cntools_parent}" ]] || return 1
  _cntools_parent="$(cd -- "${_cntools_parent}" 2>/dev/null && pwd -P)" ||
    return 1
  _cntools_output_ref="${_cntools_parent}/${_cntools_name}"
}

cntools_transaction_output_path_safe() {
  local output="${1:-}"
  local parent=""

  [[ -n "${output}" && "${output}" = /* &&
     ! -e "${output}" && ! -L "${output}" ]] || return 1
  cntools_transaction_text_control_free "${output}" || return 1
  parent="${output%/*}"
  cntools_transaction_directory_safe "${parent}"
}

cntools_transaction_temp_untrack() {
  local tracked_file="${1:-}"
  local candidate=""
  local -a remaining=()

  for candidate in "${CNTOOLS_TRANSACTION_TEMP_FILES[@]}"; do
    [[ "${candidate}" == "${tracked_file}" ]] || remaining+=("${candidate}")
  done
  CNTOOLS_TRANSACTION_TEMP_FILES=("${remaining[@]}")
}

cntools_transaction_temp_remove() {
  local temporary_file="${1:-}"
  local candidate=""
  local tracked="N"

  for candidate in "${CNTOOLS_TRANSACTION_TEMP_FILES[@]}"; do
    if [[ "${candidate}" == "${temporary_file}" ]]; then
      tracked="Y"
      break
    fi
  done
  [[ "${tracked}" == "Y" ]] || return 2
  if [[ -f "${temporary_file}" && ! -L "${temporary_file}" &&
        -O "${temporary_file}" ]]; then
    rm -f -- "${temporary_file}" 2>/dev/null || true
  fi
  cntools_transaction_temp_untrack "${temporary_file}"
}

cntools_transaction_cleanup() {
  local temporary_file=""
  local temporary_directory="${CNTOOLS_TRANSACTION_TEMP_DIR:-}"

  for temporary_file in "${CNTOOLS_TRANSACTION_TEMP_FILES[@]}"; do
    cntools_transaction_temp_remove "${temporary_file}" || true
  done
  CNTOOLS_TRANSACTION_TEMP_FILES=()
  if [[ -n "${temporary_directory}" &&
        "${temporary_directory}" = \
          "${CNTOOLS_TRANSACTION_TEMP_BASE:-/invalid}/.cntools-transaction-action."* &&
        -d "${temporary_directory}" && ! -L "${temporary_directory}" &&
        -O "${temporary_directory}" ]]; then
    rmdir -- "${temporary_directory}" 2>/dev/null || true
  fi
  CNTOOLS_TRANSACTION_TEMP_DIR=""
  CNTOOLS_TRANSACTION_TEMP_BASE=""
  CNTOOLS_TRANSACTION_BODY_FILE=""
  CNTOOLS_TRANSACTION_SIGNED_FILE=""
}

cntools_transaction_temp_file() {
  local _cntools_output_name="${1:-}"
  local _cntools_label="${2:-artifact}"
  local _cntools_parent="${3:-}"
  local _cntools_previous_umask=""
  local _cntools_file=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if [[ -z "${_cntools_parent}" ]]; then
    cntools_transaction_temp_directory_ensure || return 1
    _cntools_parent="${CNTOOLS_TRANSACTION_TEMP_DIR}"
  fi
  cntools_transaction_directory_safe "${_cntools_parent}" || return 1

  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_file="$(mktemp \
    "${_cntools_parent}/.cntools-transaction-${_cntools_label}.XXXXXX")" || {
    umask "${_cntools_previous_umask}"
    return 1
  }
  umask "${_cntools_previous_umask}"
  [[ -f "${_cntools_file}" && ! -L "${_cntools_file}" &&
     -O "${_cntools_file}" ]] || {
    rm -f -- "${_cntools_file}" 2>/dev/null || true
    return 1
  }
  chmod 0600 -- "${_cntools_file}" || {
    rm -f -- "${_cntools_file}" 2>/dev/null || true
    return 1
  }
  CNTOOLS_TRANSACTION_TEMP_FILES+=("${_cntools_file}")
  _cntools_output_ref="${_cntools_file}"
}

cntools_transaction_snapshot_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_source="${2:-}"
  local _cntools_maximum_bytes="${3:-}"
  local _cntools_label="${4:-input}"
  local _cntools_snapshot=""
  local _cntools_limit=0
  local _cntools_status=0
  local _cntools_mask="00000"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_maximum_bytes}" =~ ^[1-9][0-9]*$ &&
     "${_cntools_label}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_file_safe \
    "${_cntools_source}" "${_cntools_maximum_bytes}" || return 1
  cntools_transaction_temp_file \
    _cntools_snapshot "${_cntools_label}" || return 1
  _cntools_limit=$((_cntools_maximum_bytes + 1))
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
      "${_cntools_mask}" -- head -c "${_cntools_limit}" -- \
      "${_cntools_source}" > "${_cntools_snapshot}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    if (( _cntools_status == 124 )); then
      cntools_transaction_set_error \
        "The selected transaction input could not be snapshotted before the ${CNTOOLS_TRANSACTION_TIMEOUT}-second safety timeout."
    else
      cntools_transaction_set_error \
        "The selected transaction input could not be copied into the private session (status ${_cntools_status})."
    fi
    return 1
  fi
  if ! cntools_transaction_file_safe \
      "${_cntools_snapshot}" "${_cntools_maximum_bytes}"; then
    cntools_transaction_set_error \
      "The selected transaction input changed, became oversized, or became unsafe while it was copied."
    return 1
  fi
  _cntools_output_ref="${_cntools_snapshot}"
}

cntools_transaction_json_temp_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_label="${2:-json}"
  local _cntools_value="${3:-}"
  local _cntools_json_file=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     -n "${_cntools_value}" ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_temp_file \
    _cntools_json_file "${_cntools_label}" || return 1
  printf '%s\n' "${_cntools_value}" > "${_cntools_json_file}" || return 1
  jq -e 'length == 1' --slurp \
    "${_cntools_json_file}" >/dev/null 2>&1 || {
    cntools_transaction_set_error \
      "CNTools could not stage a valid JSON value for transaction processing."
    return 1
  }
  _cntools_output_ref="${_cntools_json_file}"
}

cntools_transaction_publish() {
  local staged_file="${1:-}"
  local output_file="${2:-}"
  local method=""
  local previous_umask=""

  if ! cntools_transaction_file_safe \
      "${staged_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" ||
     [[ ! -O "${staged_file}" ]] ||
     ! cntools_transaction_directory_safe "${staged_file%/*}"; then
    cntools_transaction_set_error \
      "The staged transaction output is missing, oversized, or not protected from replacement."
    return 1
  fi
  cntools_transaction_output_path_safe "${output_file}" || {
    cntools_transaction_set_error \
      "The transaction output must be a new file in an owned writable directory protected from group or public writes."
    return 1
  }
  chmod 0600 -- "${staged_file}" || return 1

  # A hard link publishes the fully written inode atomically and fails if the
  # requested name already exists. It is the preferred same-filesystem path.
  if ln -- "${staged_file}" "${output_file}" 2>/dev/null; then
    method="hard-link"
  else
    # Removable FAT/exFAT filesystems and cross-filesystem destinations cannot
    # hard-link. Open the final name with noclobber/O_EXCL and stream through
    # that already-open descriptor. The destination directory is private from
    # other users, so nobody else can unlink and replace the new entry. This
    # fallback is no-overwrite, although readers may observe it while copying.
    cntools_transaction_output_path_safe "${output_file}" || {
      cntools_transaction_set_error \
        "The output file appeared before publication; nothing was overwritten: ${output_file}"
      return 1
    }
    previous_umask="$(umask)"
    umask 077
    if (set -o noclobber; cat -- "${staged_file}" > "${output_file}") \
        2>/dev/null; then
      method="exclusive-copy"
    else
      umask "${previous_umask}"
      cntools_transaction_set_error \
        "The transaction output could not be published without replacing another file. Nothing was overwritten; inspect the requested path before retrying: ${output_file}"
      return 1
    fi
    umask "${previous_umask}"
    if ! chmod 0600 -- "${output_file}" ||
       ! cntools_transaction_file_safe \
         "${output_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" ||
       ! cmp -s -- "${staged_file}" "${output_file}"; then
      cntools_transaction_set_error \
        "The transaction output was created but failed its post-publication integrity check: ${output_file}"
      return 1
    fi
  fi

  cntools_transaction_temp_remove "${staged_file}" || true
  cntools_transaction_log TRANSACTION \
    "published file=${output_file} method=${method}"
}

cntools_transaction_first_diagnostic_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_line=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ -f "${_cntools_file}" && ! -L "${_cntools_file}" ]] || return 1
  while IFS= read -r _cntools_line; do
    [[ -n "${_cntools_line//[[:space:]]/}" ]] || continue
    _cntools_line="${_cntools_line:0:400}"
    if declare -F cntools_log_sanitize_line >/dev/null 2>&1; then
      _cntools_line="$(cntools_log_sanitize_line "${_cntools_line}")"
    fi
    _cntools_output_ref="${_cntools_line}"
    return 0
  done < "${_cntools_file}"
  return 1
}

cntools_transaction_require_cli() {
  local version_output=""
  local error_output=""
  local version_line=""
  local reported_version=""
  local error_size=""
  local status=0

  if [[ -z "${CNTOOLS_CLI:-}" || "${CNTOOLS_CLI}" != /* ||
        ! -x "${CNTOOLS_CLI}" || -d "${CNTOOLS_CLI}" ]] ||
     ! cntools_transaction_text_control_free "${CNTOOLS_CLI}"; then
    cntools_transaction_set_error \
      "Cardano CLI is required for transaction building, inspection, signing, and assembly."
    return 1
  fi
  if [[ "${CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH}" == "${CNTOOLS_CLI}" &&
        "${CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION}" == \
          "${CNTOOLS_TRANSACTION_CARDANO_CLI_VERSION}" ]]; then
    return 0
  fi

  cntools_transaction_temp_file version_output cli-version-output || return 1
  cntools_transaction_temp_file error_output cli-version-error || return 1
  if cntools_transaction_run_cli \
      "${version_output}" "${error_output}" -- "${CNTOOLS_CLI}" version; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Could not validate the Cardano CLI transaction contract" "${status}" \
      "${error_output}" "${version_output}"
    cntools_transaction_temp_remove "${version_output}" || true
    cntools_transaction_temp_remove "${error_output}" || true
    return 1
  fi
  if ! cntools_transaction_file_safe "${version_output}" 65536 ||
     ! cntools_transaction_size_into error_size "${error_output}" ||
     [[ ! "${error_size}" =~ ^[0-9]+$ ]] || (( error_size > 65536 )); then
    cntools_transaction_set_error \
      "Cardano CLI returned an oversized or unsafe version response."
    cntools_transaction_temp_remove "${version_output}" || true
    cntools_transaction_temp_remove "${error_output}" || true
    return 1
  fi
  IFS= read -r version_line < "${version_output}" || true
  if [[ "${version_line}" =~ ^cardano-cli[[:space:]]+([^[:space:]]+)([[:space:]]|$) ]]; then
    reported_version="${BASH_REMATCH[1]}"
  fi
  cntools_transaction_temp_remove "${version_output}" || true
  cntools_transaction_temp_remove "${error_output}" || true
  if [[ "${reported_version}" != \
        "${CNTOOLS_TRANSACTION_CARDANO_CLI_VERSION}" ]]; then
    CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH=""
    CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION=""
    cntools_transaction_set_error \
      "CNTools transaction support requires Cardano CLI ${CNTOOLS_TRANSACTION_CARDANO_CLI_VERSION}; the selected executable reports ${reported_version:-an unsupported version}. Refresh the pinned deployment before continuing."
    return 1
  fi
  CNTOOLS_TRANSACTION_VALIDATED_CLI_PATH="${CNTOOLS_CLI}"
  CNTOOLS_TRANSACTION_VALIDATED_CLI_VERSION="${reported_version}"
  cntools_transaction_log TRANSACTION \
    "cardano-cli contract validated version=${reported_version}"
}

cntools_transaction_require_signature_tools() {
  local configured_openssl="${CNTOOLS_TRANSACTION_OPENSSL:-}"
  local openssl_candidate=""
  local selected_openssl=""
  local xxd_candidate="${CNTOOLS_TRANSACTION_XXD:-}"
  local openssl_version=""
  local openssl_algorithms=""
  local openssl_major=""
  local last_version=""
  local candidate_name=""
  local -a openssl_candidates=()

  if [[ -n "${configured_openssl}" ]]; then
    openssl_candidates+=("${configured_openssl}")
  else
    for candidate_name in openssl openssl3; do
      openssl_candidate="$(type -P "${candidate_name}" 2>/dev/null || true)"
      [[ -n "${openssl_candidate}" ]] || continue
      if (( ${#openssl_candidates[@]} == 0 )) ||
         [[ "${openssl_candidate}" != "${openssl_candidates[0]}" ]]; then
        openssl_candidates+=("${openssl_candidate}")
      fi
    done
  fi
  if [[ -z "${xxd_candidate}" ]]; then
    xxd_candidate="$(type -P xxd 2>/dev/null || true)"
  fi
  if [[ "${xxd_candidate}" != /* || ! -x "${xxd_candidate}" ||
        -d "${xxd_candidate}" ]] ||
     ! cntools_transaction_text_control_free "${xxd_candidate}"; then
    cntools_transaction_set_error \
      "OpenSSL 3 or newer and xxd are required to validate transaction witnesses. Re-run guild-deploy.sh with -s p."
    return 1
  fi
  for openssl_candidate in "${openssl_candidates[@]}"; do
    [[ "${openssl_candidate}" = /* && -x "${openssl_candidate}" &&
       ! -d "${openssl_candidate}" ]] || continue
    cntools_transaction_text_control_free "${openssl_candidate}" || continue
    openssl_version="$(
      cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 00 -- \
        "${openssl_candidate}" version 2>/dev/null
    )" || continue
    last_version="${openssl_version}"
    [[ "${openssl_version}" =~ ^OpenSSL[[:space:]]+([0-9]+)\. ]] ||
      continue
    openssl_major="${BASH_REMATCH[1]}"
    (( openssl_major >= 3 )) || continue
    openssl_algorithms="$(
      cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 000 -- \
        "${openssl_candidate}" list -signature-algorithms 2>/dev/null
    )" || continue
    [[ "${openssl_algorithms^^}" == *ED25519* ]] || continue
    selected_openssl="${openssl_candidate}"
    break
  done
  if [[ -z "${selected_openssl}" ]]; then
    if [[ -n "${configured_openssl}" &&
          "${last_version}" =~ ^OpenSSL[[:space:]]+[0-9]+\. ]]; then
      cntools_transaction_set_error \
        "OpenSSL 3 or newer with Ed25519 support is required to validate transaction witnesses; found ${last_version}."
    else
      cntools_transaction_set_error \
        "OpenSSL 3 or newer with Ed25519 support is required to validate transaction witnesses. Re-run guild-deploy.sh with -s p."
    fi
    return 1
  fi
  CNTOOLS_TRANSACTION_OPENSSL="${selected_openssl}"
  CNTOOLS_TRANSACTION_XXD="${xxd_candidate}"
}

cntools_transaction_verify_ed25519_signature() {
  local transaction_id="${1:-}"
  local public_key="${2:-}"
  local signature="${3:-}"
  local transaction_id_file=""
  local public_key_file=""
  local signature_file=""
  local output_file=""
  local error_file=""
  local status=0
  local mask=""
  local -a command=()
  local -a temporary_files=()

  [[ "${transaction_id}" =~ ^[0-9a-f]{64}$ &&
     "${public_key}" =~ ^[0-9a-f]{64}$ &&
     "${signature}" =~ ^[0-9a-f]{128}$ &&
     "${CNTOOLS_TRANSACTION_OPENSSL:-}" = /* &&
     "${CNTOOLS_TRANSACTION_XXD:-}" = /* ]] || return 2
  cntools_transaction_temp_file transaction_id_file witness-txid || return 1
  temporary_files+=("${transaction_id_file}")
  cntools_transaction_temp_file public_key_file witness-public || return 1
  temporary_files+=("${public_key_file}")
  cntools_transaction_temp_file signature_file witness-signature || return 1
  temporary_files+=("${signature_file}")
  cntools_transaction_temp_file output_file witness-verify-output || return 1
  temporary_files+=("${output_file}")
  cntools_transaction_temp_file error_file witness-verify-error || return 1
  temporary_files+=("${error_file}")

  if ! cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 000 -- \
      "${CNTOOLS_TRANSACTION_XXD}" -r -p \
      > "${transaction_id_file}" <<< "${transaction_id}" ||
     ! cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 000 -- \
      "${CNTOOLS_TRANSACTION_XXD}" -r -p \
      > "${signature_file}" <<< "${signature}" ||
     ! cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 000 -- \
      "${CNTOOLS_TRANSACTION_XXD}" -r -p \
      > "${public_key_file}" \
      <<< "${CNTOOLS_TRANSACTION_ED25519_SPKI_PREFIX}${public_key}"; then
    cntools_transaction_set_error \
      "A transaction witness could not be decoded for signature verification."
    for output_file in "${temporary_files[@]}"; do
      cntools_transaction_temp_remove "${output_file}" || true
    done
    return 1
  fi

  command=("${CNTOOLS_TRANSACTION_OPENSSL}" pkeyutl -verify -pubin
    -inkey "${public_key_file}" -keyform DER -rawin
    -in "${transaction_id_file}" -sigfile "${signature_file}")
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
      "${mask}" -- "${command[@]}" \
      > "${output_file}" 2> "${error_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    if (( status == 124 )); then
      cntools_transaction_set_error \
        "Transaction witness signature verification timed out after ${CNTOOLS_TRANSACTION_TIMEOUT} seconds."
    else
      cntools_transaction_set_error \
        "A transaction witness contains an invalid Ed25519 signature."
    fi
  fi
  for output_file in "${temporary_files[@]}"; do
    cntools_transaction_temp_remove "${output_file}" || true
  done
  (( status == 0 ))
}

cntools_transaction_witness_signature_valid() {
  cntools_transaction_verify_ed25519_signature "$@"
}

cntools_transaction_witness_signatures_valid() {
  local transaction_id="${1:-}"
  local witnesses_json="${2:-}"
  local witness_count=0
  local index=0
  local public_key=""
  local signature=""

  [[ "${transaction_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  witness_count="$(jq -er '
    if type == "array" and length <= 128 and
       all(.[];
         type == "object" and keys == ["keyId", "signature"] and
         (.keyId | type == "string" and test("^[0-9a-f]{64}$")) and
         (.signature | type == "string" and test("^[0-9a-f]{128}$")))
    then length else error("invalid witness signature set") end
  ' <<< "${witnesses_json}" 2>/dev/null)" || return 1
  (( witness_count > 0 )) || return 0
  cntools_transaction_require_signature_tools || return 1
  for (( index = 0; index < witness_count; index++ )); do
    public_key="$(jq -er --argjson index "${index}" \
      '.[$index].keyId' <<< "${witnesses_json}")" || return 1
    signature="$(jq -er --argjson index "${index}" \
      '.[$index].signature' <<< "${witnesses_json}")" || return 1
    cntools_transaction_witness_signature_valid \
      "${transaction_id}" "${public_key}" "${signature}" || return 1
  done
}

cntools_transaction_run_cli() {
  local output_file="${1:-}"
  local error_file="${2:-}"
  local mask=""
  shift 2 2>/dev/null || return 2
  [[ "${1:-}" == "--" ]] || return 2
  shift
  (( $# > 0 )) || return 2
  [[ -f "${output_file}" && ! -L "${output_file}" &&
     -O "${output_file}" &&
     -f "${error_file}" && ! -L "${error_file}" &&
     -O "${error_file}" ]] || return 2
  printf -v mask '%*s' "$#" ''
  mask="${mask// /0}"
  cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
    "${mask}" -- "$@" > "${output_file}" 2> "${error_file}"
}

cntools_transaction_log_cli_failure() {
  local context="${1:-Cardano CLI transaction command failed}"
  local status="${2:-1}"
  local error_file="${3:-}"
  local output_file="${4:-}"
  local detail=""

  if [[ "${status}" == "124" ]]; then
    detail="timed out after ${CNTOOLS_TRANSACTION_TIMEOUT} seconds"
  else
    cntools_transaction_first_diagnostic_into detail "${error_file}" ||
      cntools_transaction_first_diagnostic_into detail "${output_file}" || true
  fi
  cntools_transaction_set_error \
    "${context} (status ${status})${detail:+: ${detail}}"
}

cntools_transaction_network_arguments_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_network="${2:-${CNTOOLS_NETWORK:-}}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=()
  case "${_cntools_network}" in
    mainnet) _cntools_output_ref=(--mainnet) ;;
    guild) _cntools_output_ref=(--testnet-magic 141) ;;
    preprod) _cntools_output_ref=(--testnet-magic 1) ;;
    preview) _cntools_output_ref=(--testnet-magic 2) ;;
    *) return 1 ;;
  esac
}

cntools_transaction_network_magic() {
  case "${1:-${CNTOOLS_NETWORK:-}}" in
    mainnet) printf 'null\n' ;;
    guild) printf '141\n' ;;
    preprod) printf '1\n' ;;
    preview) printf '2\n' ;;
    *) return 1 ;;
  esac
}

cntools_transaction_envelope_kind_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_detected_kind=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_file_safe \
    "${_cntools_file}" "${CNTOOLS_TRANSACTION_MAX_BODY_BYTES}" || return 1
  _cntools_detected_kind="$(jq -ers '
    if length != 1 or (.[0] | type) != "object" or
       (.[0].type | type) != "string" or
       (.[0].cborHex | type) != "string" or
       (.[0].cborHex | test("^([0-9a-fA-F]{2})+$") | not) or
       (.[0].cborHex | length) > 8388608
    then ""
    elif (.[0].type | test("^TxBody[[:space:]]+.+Era$")) then "body"
    elif (.[0].type | test("^TxWitness[[:space:]]+.+Era$")) then "witness"
    # cardano-cli 11 emits `Tx <Era>` for both an unsigned builder result and
    # an assembled transaction. Callers determine its role from context.
    elif (.[0].type | test("^Tx[[:space:]]+.+Era$")) then "transaction"
    else ""
    end
  ' "${_cntools_file}" 2>/dev/null)" || return 1
  [[ -n "${_cntools_detected_kind}" ]] || return 1
  if [[ "${_cntools_detected_kind}" == "witness" ]]; then
    cntools_transaction_file_safe \
      "${_cntools_file}" "${CNTOOLS_TRANSACTION_MAX_WITNESS_BYTES}" || return 1
  fi
  _cntools_output_ref="${_cntools_detected_kind}"
}

cntools_transaction_envelope_compact_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_kind="${3:-}"
  local _cntools_actual_kind=""
  local _cntools_json=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_envelope_kind_into \
    _cntools_actual_kind "${_cntools_file}" || return 1
  case "${_cntools_kind}:${_cntools_actual_kind}" in
    :*|body:body|body:transaction|signed:transaction|witness:witness) ;;
    *) return 1 ;;
  esac
  _cntools_json="$(jq -ec . "${_cntools_file}" 2>/dev/null)" || return 1
  _cntools_output_ref="${_cntools_json}"
}

cntools_transaction_id_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_kind=""
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_id=""
  local _cntools_status=0
  local -a _cntools_command=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_require_cli || return 1
  cntools_transaction_envelope_kind_into _cntools_kind "${_cntools_file}" || {
    cntools_transaction_set_error "The selected file is not a supported Cardano transaction envelope."
    return 1
  }
  case "${_cntools_kind}" in
    body)
      _cntools_command=("${CNTOOLS_CLI}" latest transaction txid
        --tx-body-file "${_cntools_file}" --output-text)
      ;;
    transaction)
      _cntools_command=("${CNTOOLS_CLI}" latest transaction txid
        --tx-file "${_cntools_file}" --output-text)
      ;;
    *) return 2 ;;
  esac
  cntools_transaction_temp_file _cntools_output_file txid-output || return 1
  cntools_transaction_temp_file _cntools_error_file txid-error || return 1
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${_cntools_command[@]}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Could not calculate the transaction ID" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  IFS= read -r _cntools_id < "${_cntools_output_file}" || true
  _cntools_id="${_cntools_id,,}"
  [[ "${_cntools_id}" =~ ^[0-9a-f]{64}$ ]] || {
    cntools_transaction_set_error "Cardano CLI returned an invalid transaction ID."
    return 1
  }
  _cntools_output_ref="${_cntools_id}"
}

cntools_transaction_view_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_kind=""
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_decoded_view=""
  local _cntools_status=0
  local -a _cntools_command=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_require_cli || return 1
  cntools_transaction_envelope_kind_into _cntools_kind "${_cntools_file}" ||
    return 1
  case "${_cntools_kind}" in
    body)
      _cntools_command=("${CNTOOLS_CLI}" debug transaction view
        --output-json --tx-body-file "${_cntools_file}")
      ;;
    transaction)
      _cntools_command=("${CNTOOLS_CLI}" debug transaction view
        --output-json --tx-file "${_cntools_file}")
      ;;
    *) return 2 ;;
  esac
  cntools_transaction_temp_file _cntools_output_file view-output || return 1
  cntools_transaction_temp_file _cntools_error_file view-error || return 1
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${_cntools_command[@]}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Could not decode the transaction for review" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  _cntools_decoded_view="$(< "${_cntools_output_file}")"
  [[ -n "${_cntools_decoded_view}" &&
     ${#_cntools_decoded_view} -le 1048576 ]] || {
    cntools_transaction_set_error "Cardano CLI returned an empty or oversized transaction review."
    return 1
  }
  _cntools_output_ref="${_cntools_decoded_view}"
}

cntools_transaction_view_witnesses_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_view="${2:-}"
  local _cntools_witness_records_json=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     -n "${_cntools_view}" && ${#_cntools_view} -le 1048576 ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_witness_records_json="$(jq -cer '
    if (.witnesses | type) != "array" then error("missing witnesses")
    else
      [.witnesses[] |
        if (.key | type) != "string" or
           (.signature | type) != "string"
        then error("invalid witness")
        else {
          keyId: (.key |
            capture("^VKey \\(VerKeyEd25519DSIGN \\\"(?<id>[0-9a-fA-F]{64})\\\"\\)$").id |
            ascii_downcase),
          signature: (.signature |
            capture("^SignedDSIGN \\(SigEd25519DSIGN \\\"(?<signature>[0-9a-fA-F]{128})\\\"\\)$").signature |
            ascii_downcase)
        }
        end] |
      if length == ([.[].keyId] | unique | length) then sort_by(.keyId)
      else error("duplicate witness key")
      end
    end
  ' <<< "${_cntools_view}" 2>/dev/null)" || return 1
  _cntools_output_ref="${_cntools_witness_records_json}"
}

cntools_transaction_view_witness_key_ids_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_view="${2:-}"
  local _cntools_parsed_witnesses=""
  local _cntools_parsed_witness_ids=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_view_witnesses_into \
    _cntools_parsed_witnesses "${_cntools_view}" || return 1
  _cntools_parsed_witness_ids="$(jq -cer \
    '[.[].keyId]' <<< "${_cntools_parsed_witnesses}")" || return 1
  _cntools_output_ref="${_cntools_parsed_witness_ids}"
}

cntools_transaction_file_witnesses_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_view=""
  local _cntools_file_witnesses=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_view_into _cntools_view "${_cntools_file}" || return 1
  cntools_transaction_view_witnesses_into \
    _cntools_file_witnesses "${_cntools_view}" || return 1
  _cntools_output_ref="${_cntools_file_witnesses}"
}

cntools_transaction_file_witness_key_ids_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_view=""
  local _cntools_file_witness_ids=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_view_into _cntools_view "${_cntools_file}" || return 1
  cntools_transaction_view_witness_key_ids_into \
    _cntools_file_witness_ids "${_cntools_view}" || return 1
  _cntools_output_ref="${_cntools_file_witness_ids}"
}

cntools_transaction_file_witness_count_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_counted_witness_ids=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_file_witness_key_ids_into \
    _cntools_counted_witness_ids "${_cntools_file}" || return 1
  _cntools_output_ref="$(jq -r 'length' \
    <<< "${_cntools_counted_witness_ids}")" || return 1
}

cntools_transaction_assemble_witness_files() {
  local output_file="${1:-}"
  local body_file="${2:-}"
  local witness_file=""
  local command_output=""
  local error_file=""
  local kind=""
  local status=0
  local mask=""
  local -a command=()
  shift 2 2>/dev/null || return 2

  [[ -f "${output_file}" && ! -L "${output_file}" &&
     -O "${output_file}" ]] || return 2
  cntools_transaction_require_cli || return 1
  cntools_transaction_envelope_compact_into kind "${body_file}" body ||
    return 1
  : "${kind}"
  command=("${CNTOOLS_CLI}" latest transaction assemble
    --tx-body-file "${body_file}")
  for witness_file in "$@"; do
    cntools_transaction_envelope_compact_into \
      kind "${witness_file}" witness || return 1
    command+=(--witness-file "${witness_file}")
  done
  command+=(--out-canonical-cbor --out-file "${output_file}")
  cntools_transaction_temp_file command_output assemble-output || return 1
  cntools_transaction_temp_file error_file assemble-error || return 1
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
      "${mask}" -- "${command[@]}" \
      > "${command_output}" 2> "${error_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Transaction assembly failed" "${status}" \
      "${error_file}" "${command_output}"
    return 1
  fi
  cntools_transaction_envelope_kind_into kind "${output_file}" || return 1
  [[ "${kind}" == "transaction" ]] || {
    cntools_transaction_set_error \
      "Cardano CLI did not produce a valid assembled transaction."
    return 1
  }
}

cntools_transaction_witness_matches_key() {
  local body_file="${1:-}"
  local witness_file="${2:-}"
  local expected_key_id="${3:-}"
  local assembled_file=""
  local transaction_id=""
  local witnesses=""

  [[ "${expected_key_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  cntools_transaction_temp_file assembled_file witness-check || return 1
  cntools_transaction_assemble_witness_files \
    "${assembled_file}" "${body_file}" "${witness_file}" || return 1
  cntools_transaction_file_witnesses_into \
    witnesses "${assembled_file}" || return 1
  jq -e --arg id "${expected_key_id}" \
    'length == 1 and .[0].keyId == $id' \
    <<< "${witnesses}" >/dev/null 2>&1 || return 1
  cntools_transaction_id_into transaction_id "${body_file}" || return 1
  cntools_transaction_witness_signatures_valid \
    "${transaction_id}" "${witnesses}"
}

cntools_transaction_key_id_from_verification_file_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_cbor=""
  local _cntools_id=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_file_safe "${_cntools_file}" 65536 || return 1
  _cntools_cbor="$(jq -ers '
    if length == 1 and (.[0] | type) == "object" and
       (.[0].type | type) == "string" and
       (.[0].type | test("VerificationKey")) and
       (.[0].type | test("SigningKey") | not) and
       (.[0].cborHex | type) == "string" and
       (.[0].cborHex | test("^58(20[0-9a-fA-F]{64}|40[0-9a-fA-F]{128})$"))
    then .[0].cborHex | ascii_downcase
    else ""
    end
  ' "${_cntools_file}" 2>/dev/null)" || return 1
  [[ -n "${_cntools_cbor}" ]] || return 1
  case "${_cntools_cbor:0:4}" in
    5820|5840) _cntools_id="${_cntools_cbor:4:64}" ;;
    *) return 1 ;;
  esac
  [[ "${_cntools_id}" =~ ^[0-9a-f]{64}$ ]] || return 1
  _cntools_output_ref="${_cntools_id}"
}

cntools_transaction_source_kind_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_detected_kind=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_private_file_safe "${_cntools_file}" || return 1
  _cntools_detected_kind="$(jq -ers '
    if length != 1 or (.[0] | type) != "object" or
       (.[0].type | type) != "string"
    then ""
    elif (.[0].type | test("HWSigningFile")) and
         (.[0].type | test("Byron|Bootstrap") | not) and
         (.[0].cborXPubKeyHex | type) == "string" and
         (.[0].cborXPubKeyHex | test("^5840[0-9a-fA-F]{128}$")) and
         (.[0].path | type) == "string" and
         (.[0].path | test("^[0-9]+H(/[0-9]+H?){2,9}$")) and
         (.[0].path | test("^44H/") | not)
    then "hardware"
    elif (.[0].type | test("^(Payment|PaymentExtended|Stake|StakeExtended|StakePool|StakePoolExtended|Genesis|GenesisExtended|GenesisDelegate|GenesisDelegateExtended|GenesisUTxO|DRep|DRepExtended|ConstitutionalCommitteeCold|ConstitutionalCommitteeColdExtended|ConstitutionalCommitteeHot|ConstitutionalCommitteeHotExtended)SigningKey")) and
         (.[0].cborHex | type) == "string" and
         (.[0].cborHex | test("^([0-9a-fA-F]{2})+$")) and
         (.[0].cborHex | length) <= 4096
    then "cli"
    else ""
    end
  ' "${_cntools_file}" 2>/dev/null)" || return 1
  [[ "${_cntools_detected_kind}" == "cli" ||
     "${_cntools_detected_kind}" == "hardware" ]] ||
    return 1
  _cntools_output_ref="${_cntools_detected_kind}"
}

cntools_transaction_hardware_change_source_valid() {
  local file="${1:-}"
  local kind=""

  cntools_transaction_source_kind_into kind "${file}" || return 1
  [[ "${kind}" == "hardware" ]] || return 1
  jq -e '
    (type == "object") and
    ((.type == "PaymentHWSigningFileShelley_ed25519" and
      (.path | test("^1852H/1815H/[0-9]+H/[01]/[0-9]+$"))) or
     (.type == "StakeHWSigningFileShelley_ed25519" and
      (.path | test("^1852H/1815H/[0-9]+H/2/[0-9]+$"))))
  ' "${file}" >/dev/null 2>&1
}

cntools_transaction_source_key_id_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_kind=""
  local _cntools_value=""
  local _cntools_vkey=""
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_source_kind_into _cntools_kind "${_cntools_file}" ||
    return 1
  if [[ "${_cntools_kind}" == "hardware" ]]; then
    _cntools_value="$(jq -er '.cborXPubKeyHex | ascii_downcase' \
      "${_cntools_file}" 2>/dev/null)" || return 1
    _cntools_value="${_cntools_value:4:64}"
    [[ "${_cntools_value}" =~ ^[0-9a-f]{64}$ ]] || return 1
    _cntools_output_ref="${_cntools_value}"
    return 0
  fi

  cntools_transaction_require_cli || return 1
  cntools_transaction_temp_file _cntools_vkey source-vkey || return 1
  cntools_transaction_temp_file _cntools_output_file source-output || return 1
  cntools_transaction_temp_file _cntools_error_file source-error || return 1
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${CNTOOLS_CLI}" key verification-key \
      --signing-key-file "${_cntools_file}" \
      --verification-key-file "${_cntools_vkey}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Could not derive the selected signing key's verification key" \
      "${_cntools_status}" "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  cntools_transaction_key_id_from_verification_file_into \
    _cntools_value "${_cntools_vkey}" || {
    cntools_transaction_set_error \
      "The selected signing key produced an unsupported verification key."
    return 1
  }
  _cntools_output_ref="${_cntools_value}"
}

cntools_transaction_credential_from_key_id_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_key_id="${2:-}"
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_credential=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_key_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_credential="${CNTOOLS_TRANSACTION_CREDENTIAL_CACHE[${_cntools_key_id}]:-}"
  if [[ "${_cntools_credential}" =~ ^[0-9a-f]{56}$ ]]; then
    _cntools_output_ref="${_cntools_credential}"
    return 0
  fi
  cntools_transaction_require_cli || return 1
  cntools_transaction_temp_file _cntools_output_file credential-output || return 1
  cntools_transaction_temp_file _cntools_error_file credential-error || return 1
  # Stake and payment credentials use the same Blake2b-224 key hash. The
  # stake command accepts a raw hexadecimal verification key, so it provides
  # one role-neutral, pinned-CLI derivation path for every Shelley signer.
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${CNTOOLS_CLI}" latest stake-address key-hash \
      --stake-verification-key "${_cntools_key_id}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Could not derive the signer's credential hash" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  IFS= read -r _cntools_credential < "${_cntools_output_file}" || true
  _cntools_credential="${_cntools_credential,,}"
  [[ "${_cntools_credential}" =~ ^[0-9a-f]{56}$ ]] || {
    cntools_transaction_set_error \
      "Cardano CLI returned an invalid signing credential hash."
    return 1
  }
  CNTOOLS_TRANSACTION_CREDENTIAL_CACHE["${_cntools_key_id}"]="${_cntools_credential}"
  _cntools_output_ref="${_cntools_credential}"
}

cntools_transaction_plan_reset() {
  local intent="${1:-Transaction}"
  local description="${2:-}"
  local assurance="${3:-exact}"

  [[ -n "${intent}" && ${#intent} -le 80 &&
     "${intent}" != *$'\n'* && "${intent}" != *$'\r'* &&
     ${#description} -le 240 && "${description}" != *$'\n'* &&
     "${description}" != *$'\r'* ]] || return 2
  case "${assurance}" in exact|manual) ;; *) return 2 ;; esac
  CNTOOLS_TRANSACTION_PLAN_READY="Y"
  CNTOOLS_TRANSACTION_PLAN_INTENT="${intent}"
  CNTOOLS_TRANSACTION_PLAN_DESCRIPTION="${description}"
  CNTOOLS_TRANSACTION_PLAN_ASSURANCE="${assurance}"
  CNTOOLS_TRANSACTION_PLAN_SUMMARY='{}'
  CNTOOLS_TRANSACTION_PLAN_REQUIRED='[]'
  CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS='[]'
  CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS='[]'
  CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE=""
  CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER=""
  CNTOOLS_TRANSACTION_RUNTIME_SOURCES=()
  CNTOOLS_TRANSACTION_RUNTIME_SOURCE_KINDS=()
  CNTOOLS_TRANSACTION_RUNTIME_CHANGE_SOURCES=()
  cntools_transaction_clear_error
}

cntools_transaction_plan_set_summary() {
  local summary="${1:-}"

  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" &&
     -n "${summary}" && ${#summary} -le 262144 ]] || return 2
  jq -e 'type == "object"' <<< "${summary}" >/dev/null 2>&1 || return 1
  CNTOOLS_TRANSACTION_PLAN_SUMMARY="$(jq -c . <<< "${summary}")" || return 1
}

cntools_transaction_slot_value_valid() {
  # Stay within both Bash integer and jq's exact integer range.
  [[ -z "${1:-}" || "${1}" =~ ^(0|[1-9][0-9]{0,14})$ ]]
}

cntools_transaction_plan_set_validity() {
  local invalid_before="${1:-}"
  local invalid_hereafter="${2:-}"

  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" ]] || return 2
  cntools_transaction_slot_value_valid "${invalid_before}" || return 1
  cntools_transaction_slot_value_valid "${invalid_hereafter}" || return 1
  if [[ -n "${invalid_before}" && -n "${invalid_hereafter}" ]]; then
    # The deployment targets practical Cardano slot ranges within Bash's
    # signed integer range; reject an inverted interval without float parsing.
    (( 10#${invalid_before} < 10#${invalid_hereafter} )) || return 1
  fi
  CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE="${invalid_before}"
  CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER="${invalid_hereafter}"
}

cntools_transaction_signer_fields_valid() {
  local label="${1:-}"
  local role="${2:-}"
  local key_id="${3:-}"
  local credential="${4:-}"
  local preferred_kind="${5:-either}"
  local hardware_group="${6:-}"

  [[ -n "${label}" && ${#label} -le 120 &&
     "${label}" != *$'\n'* && "${label}" != *$'\r'* &&
     "${label}" != *$'\t'* &&
     "${role}" =~ ^[a-z][a-z0-9-]{0,31}$ &&
     "${key_id}" =~ ^[0-9a-f]{64}$ &&
     "${credential}" =~ ^[0-9a-f]{56}$ &&
     ( -z "${hardware_group}" ||
       "${hardware_group}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ) ]] ||
    return 1
  case "${preferred_kind}" in cli|hardware|either) ;; *) return 1 ;; esac
  [[ -z "${hardware_group}" || "${preferred_kind}" == "hardware" ]]
}

cntools_transaction_plan_add_public_signer() {
  local label="${1:-}"
  local role="${2:-}"
  local key_id="${3:-}"
  local credential="${4:-}"
  local preferred_kind="${5:-either}"
  local hardware_group="${6:-}"
  local existing_credential=""
  local existing_kind=""
  local existing_group=""
  local derived_credential=""
  local merged_kind=""
  local updated=""

  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" ]] || return 2
  key_id="${key_id,,}"
  credential="${credential,,}"
  cntools_transaction_credential_from_key_id_into \
    derived_credential "${key_id}" || return 1
  if [[ -n "${credential}" && "${credential}" != "${derived_credential}" ]]; then
    cntools_transaction_set_error \
      "The supplied credential hash does not match its public signing key."
    return 1
  fi
  credential="${derived_credential}"
  cntools_transaction_signer_fields_valid \
    "${label}" "${role}" "${key_id}" "${credential}" \
    "${preferred_kind}" "${hardware_group}" || return 1
  existing_credential="$(jq -r --arg id "${key_id}" \
    '.[] | select(.keyId == $id) | .credential // ""' \
    <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
  existing_kind="$(jq -r --arg id "${key_id}" \
    '.[] | select(.keyId == $id) | .preferredKind // ""' \
    <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
  existing_group="$(jq -r --arg id "${key_id}" \
    '.[] | select(.keyId == $id) | .hardwareGroup // ""' \
    <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
  if [[ -n "${existing_credential}" && -n "${credential}" &&
        "${existing_credential}" != "${credential}" ]]; then
    cntools_transaction_set_error \
      "One public signing key was registered with conflicting credential hashes."
    return 1
  fi
  if [[ -n "${existing_group}" && -n "${hardware_group}" &&
        "${existing_group}" != "${hardware_group}" ]]; then
    cntools_transaction_set_error \
      "One public signing key was registered in conflicting hardware sessions."
    return 1
  fi
  [[ -n "${hardware_group}" ]] || hardware_group="${existing_group}"
  if [[ ( -n "${existing_group}" || -n "${hardware_group}" ) &&
        -n "${existing_kind}" && "${existing_kind}" != "${preferred_kind}" ]]; then
    cntools_transaction_set_error \
      "A signer in a hardware session cannot also use a different signing method."
    return 1
  elif [[ -n "${existing_kind}" && "${existing_kind}" != "${preferred_kind}" ]]; then
    merged_kind="either"
  else
    merged_kind="${preferred_kind}"
  fi
  updated="$(jq -c \
    --arg id "${key_id}" --arg label "${label}" --arg role "${role}" \
    --arg credential "${credential}" --arg preferred "${merged_kind}" \
    --arg hardware_group "${hardware_group}" '
      if any(.[]; .keyId == $id) then
        map(if .keyId == $id then
          .labels = ((.labels + [$label]) | unique) |
          .roles = ((.roles + [$role]) | unique) |
          .credential = $credential |
          .hardwareGroup =
            (if (.hardwareGroup // "") == "" and $hardware_group != ""
             then $hardware_group else .hardwareGroup end) |
          .preferredKind = $preferred
        else . end)
      else
        . + [{
          keyId: $id,
          credential: $credential,
          hardwareGroup:
            (if $hardware_group == "" then null else $hardware_group end),
          labels: [$label],
          roles: [$role],
          preferredKind: $preferred
        }]
      end
    ' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
  CNTOOLS_TRANSACTION_PLAN_REQUIRED="${updated}"
  cntools_transaction_log TRANSACTION \
    "signer registered key=${key_id:0:16}… role=${role} label=${label}"
}

cntools_transaction_plan_add_signer() {
  local label="${1:-}"
  local role="${2:-}"
  local verification_file="${3:-}"
  local source_file="${4:-}"
  local credential="${5:-}"
  local hardware_group="${6:-}"
  local key_id=""
  local source_id=""
  local source_kind="either"

  cntools_transaction_key_id_from_verification_file_into \
    key_id "${verification_file}" || {
    cntools_transaction_set_error "The signer verification key is invalid or unsupported."
    return 1
  }
  if [[ -n "${source_file}" ]]; then
    cntools_transaction_source_kind_into source_kind "${source_file}" || {
      cntools_transaction_set_error "The signer source is unsafe or unsupported."
      return 1
    }
    cntools_transaction_source_key_id_into source_id "${source_file}" || return 1
    if [[ "${source_id}" != "${key_id}" ]]; then
      cntools_transaction_set_error \
        "The signer source does not match its verification key."
      return 1
    fi
  fi
  cntools_transaction_plan_add_public_signer \
    "${label}" "${role}" "${key_id}" "${credential}" "${source_kind}" \
    "${hardware_group}" ||
    return $?
  if [[ -n "${source_file}" ]]; then
    CNTOOLS_TRANSACTION_RUNTIME_SOURCES["${key_id}"]="${source_file}"
    CNTOOLS_TRANSACTION_RUNTIME_SOURCE_KINDS["${key_id}"]="${source_kind}"
  fi
}

cntools_transaction_plan_witness_count() {
  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" ]] || return 2
  jq -er 'length' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}"
}

cntools_transaction_plan_add_public_change_key() {
  local label="${1:-Change address}"
  local key_id="${2:-}"
  local hardware_group="${3:-}"
  local updated=""

  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" ]] || return 2
  key_id="${key_id,,}"
  [[ -n "${label}" && ${#label} -le 120 &&
     "${label}" != *$'\n'* && "${label}" != *$'\r'* &&
     "${label}" != *$'\t'* &&
     "${key_id}" =~ ^[0-9a-f]{64}$ &&
     "${hardware_group}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    return 2
  jq -e --arg group "${hardware_group}" '
    any(.[]; .hardwareGroup == $group and .preferredKind == "hardware")
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" >/dev/null 2>&1 || {
    cntools_transaction_set_error \
      "A hardware change reference must belong to an existing hardware signing session."
    return 1
  }
  updated="$(jq -c \
    --arg id "${key_id}" --arg label "${label}" \
    --arg group "${hardware_group}" '
      if any(.[]; .keyId == $id) then
        map(if .keyId == $id then
          if .hardwareGroup != $group then
            error("conflicting hardware group")
          else .labels = ((.labels + [$label]) | unique)
          end
        else . end)
      else . + [{keyId: $id, labels: [$label], hardwareGroup: $group}]
      end
    ' <<< "${CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS}" 2>/dev/null)" || {
    cntools_transaction_set_error \
      "One hardware change key was registered in conflicting sessions."
    return 1
  }
  CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS="${updated}"
}

cntools_transaction_plan_add_change_key() {
  local label="${1:-Change address}"
  local verification_file="${2:-}"
  local source_file="${3:-}"
  local hardware_group="${4:-}"
  local key_id=""
  local source_id=""
  local source_kind=""

  cntools_transaction_key_id_from_verification_file_into \
    key_id "${verification_file}" || {
    cntools_transaction_set_error \
      "The hardware change verification key is invalid or unsupported."
    return 1
  }
  if [[ -n "${source_file}" ]]; then
    cntools_transaction_source_kind_into source_kind "${source_file}" || {
      cntools_transaction_set_error \
        "The hardware change source is unsafe or unsupported."
      return 1
    }
    [[ "${source_kind}" == "hardware" ]] || {
      cntools_transaction_set_error \
        "A hardware change reference must be a hardware signing file."
      return 1
    }
    cntools_transaction_hardware_change_source_valid "${source_file}" || {
      cntools_transaction_set_error \
        "A hardware change reference must be a standard CIP-1852 payment or stake hardware key."
      return 1
    }
    cntools_transaction_source_key_id_into source_id "${source_file}" || return 1
    [[ "${source_id}" == "${key_id}" ]] || {
      cntools_transaction_set_error \
        "The hardware change source does not match its verification key."
      return 1
    }
  fi
  cntools_transaction_plan_add_public_change_key \
    "${label}" "${key_id}" "${hardware_group}" || return 1
  if [[ -n "${source_file}" ]]; then
    CNTOOLS_TRANSACTION_RUNTIME_CHANGE_SOURCES["${key_id}"]="${source_file}"
  fi
}

cntools_transaction_plan_mark_change_key() {
  local key_id="${1:-}"
  local label=""
  local hardware_group=""
  local runtime_source=""
  local runtime_kind=""

  key_id="${key_id,,}"
  label="$(jq -r --arg id "${key_id}" \
    '.[] | select(.keyId == $id) | .labels[0] // "Change address"' \
    <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
  hardware_group="$(jq -r --arg id "${key_id}" \
    '.[] | select(.keyId == $id) | .hardwareGroup // ""' \
    <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
  [[ -n "${hardware_group}" ]] || {
    cntools_transaction_set_error \
      "A signer used for hardware change must belong to a hardware session."
    return 1
  }
  cntools_transaction_plan_add_public_change_key \
    "${label}" "${key_id}" "${hardware_group}" || return 1
  runtime_source="${CNTOOLS_TRANSACTION_RUNTIME_SOURCES[${key_id}]:-}"
  if [[ -n "${runtime_source}" ]]; then
    cntools_transaction_source_kind_into \
      runtime_kind "${runtime_source}" || return 1
    [[ "${runtime_kind}" == "hardware" ]] || {
      cntools_transaction_set_error \
        "A hardware change reference cannot use a CLI signing source."
      return 1
    }
    cntools_transaction_hardware_change_source_valid "${runtime_source}" || {
      cntools_transaction_set_error \
        "A hardware change reference must be a standard CIP-1852 payment or stake hardware key."
      return 1
    }
    CNTOOLS_TRANSACTION_RUNTIME_CHANGE_SOURCES["${key_id}"]="${runtime_source}"
  fi
}

cntools_transaction_native_script_valid() {
  local script_file="${1:-}"

  cntools_transaction_file_safe "${script_file}" 262144 || return 1
  jq -e '
    def valid_script:
      type == "object" and
      if .type == "sig" then
        keys == ["keyHash", "type"] and
        (.keyHash | type == "string" and test("^[0-9a-fA-F]{56}$"))
      elif .type == "before" or .type == "after" then
        keys == ["slot", "type"] and
        (.slot | type == "number" and floor == . and . >= 0)
      elif .type == "all" or .type == "any" then
        keys == ["scripts", "type"] and
        (.scripts | type == "array" and length > 0 and all(.[]; valid_script))
      elif .type == "atLeast" then
        keys == ["required", "scripts", "type"] and
        (.required | type == "number" and floor == . and . >= 0) and
        (.scripts | type == "array" and length > 0 and
          .required <= length and all(.[]; valid_script))
      else false
      end;
    valid_script
  ' "${script_file}" >/dev/null 2>&1
}

cntools_transaction_native_script_satisfied() {
  local script_file="${1:-}"
  local credentials_file="${2:-}"
  local invalid_before="${3:-}"
  local invalid_hereafter="${4:-}"
  local before_json="null"
  local hereafter_json="null"

  cntools_transaction_native_script_valid "${script_file}" || return 1
  cntools_transaction_file_safe "${credentials_file}" 262144 || return 1
  [[ -z "${invalid_before}" ]] || before_json="${invalid_before}"
  [[ -z "${invalid_hereafter}" ]] || hereafter_json="${invalid_hereafter}"
  jq -ne --slurpfile script "${script_file}" \
    --slurpfile credentials "${credentials_file}" \
    --argjson invalid_before "${before_json}" \
    --argjson invalid_hereafter "${hereafter_json}" '
      ($script | length) == 1 and
      ($credentials | length) == 1 and
      ($credentials[0] | type == "array" and
        all(.[]; type == "string" and test("^[0-9a-f]{56}$"))) and
      ($script[0] as $script |
       $credentials[0] as $credentials |
      def sat($node):
        if $node.type == "sig" then
          any($credentials[]; ascii_downcase == ($node.keyHash | ascii_downcase))
        elif $node.type == "before" then
          $invalid_hereafter != null and $invalid_hereafter <= $node.slot
        elif $node.type == "after" then
          $invalid_before != null and $invalid_before >= $node.slot
        elif $node.type == "all" then
          all($node.scripts[]; sat(.))
        elif $node.type == "any" then
          any($node.scripts[]; sat(.))
        elif $node.type == "atLeast" then
          ([$node.scripts[] | sat(.)] | map(select(.)) | length) >= $node.required
        else false
        end;
      sat($script))
    ' >/dev/null 2>&1
}

cntools_transaction_native_script_hash_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_script_file="${2:-}"
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_hash=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_native_script_valid "${_cntools_script_file}" || return 1
  cntools_transaction_require_cli || return 1
  cntools_transaction_temp_file _cntools_output_file script-hash-output || return 1
  cntools_transaction_temp_file _cntools_error_file script-hash-error || return 1
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${CNTOOLS_CLI}" latest transaction policyid \
      --script-file "${_cntools_script_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Could not calculate the native script hash" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  IFS= read -r _cntools_hash < "${_cntools_output_file}" || true
  _cntools_hash="${_cntools_hash,,}"
  [[ "${_cntools_hash}" =~ ^[0-9a-f]{56}$ ]] || {
    cntools_transaction_set_error \
      "Cardano CLI returned an invalid native script hash."
    return 1
  }
  _cntools_output_ref="${_cntools_hash}"
}

cntools_transaction_plan_add_native_script_internal() {
  local label="${1:-}"
  local purpose="${2:-}"
  local source="${3:-}"
  local script_file="${4:-}"
  local reference_input="${5:-}"
  local selected_key_id=""
  local script_hash=""
  local selected_json='[]'
  local credentials_json='[]'
  local credential=""
  local credentials_file=""
  local selected_file=""
  local native_scripts_file=""
  shift 5 2>/dev/null || return 2

  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" &&
     -n "${label}" && ${#label} -le 120 &&
     "${label}" != *$'\n'* && "${label}" != *$'\r'* ]] || return 2
  case "${purpose}" in
    spend|mint|certificate|withdrawal|vote|proposal) ;;
    *) return 2 ;;
  esac
  case "${source}" in
    embedded)
      [[ -z "${reference_input}" ]] || return 2
      ;;
    reference)
      cntools_transaction_reference_input_valid "${reference_input}" ||
        return 2
      ;;
    *) return 2 ;;
  esac
  cntools_transaction_native_script_valid "${script_file}" || {
    cntools_transaction_set_error "The ${purpose} native script is invalid or unsupported."
    return 1
  }
  cntools_transaction_native_script_hash_into \
    script_hash "${script_file}" || return 1
  for selected_key_id in "$@"; do
    selected_key_id="${selected_key_id,,}"
    [[ "${selected_key_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
    credential="$(jq -r --arg id "${selected_key_id}" '
      .[] | select(.keyId == $id) | .credential // ""
    ' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
    [[ "${credential}" =~ ^[0-9a-f]{56}$ ]] || {
      cntools_transaction_set_error \
        "Every native-script participant must have a known credential hash."
      return 1
    }
    selected_json="$(jq -c --arg value "${selected_key_id}" \
      '. + [$value] | unique' <<< "${selected_json}")" || return 1
    credentials_json="$(jq -c --arg value "${credential}" \
      '. + [$value] | unique' <<< "${credentials_json}")" || return 1
  done
  cntools_transaction_json_temp_into \
    credentials_file native-credentials "${credentials_json}" || return 1
  if ! cntools_transaction_native_script_satisfied \
      "${script_file}" "${credentials_file}" \
      "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" \
      "${CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER}"; then
    cntools_transaction_set_error \
      "The selected signers and validity interval do not satisfy the ${label} native script."
    return 1
  fi
  cntools_transaction_json_temp_into \
    selected_file native-selected "${selected_json}" || return 1
  cntools_transaction_json_temp_into \
    native_scripts_file native-plan \
    "${CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS}" || return 1
  CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS="$(jq -c \
    --arg label "${label}" --arg purpose "${purpose}" \
    --arg source "${source}" --arg script_hash "${script_hash}" \
    --arg reference_input "${reference_input}" \
    --slurpfile script "${script_file}" \
    --slurpfile selected "${selected_file}" '
      . + [{label: $label, purpose: $purpose, script: $script[0],
            scriptHash: $script_hash,
            referenceInput:
              (if $source == "reference" then $reference_input else null end),
            selectedKeyIds: $selected[0],
            source: $source}]
    ' "${native_scripts_file}")" || return 1
  cntools_transaction_log TRANSACTION \
    "native script registered purpose=${purpose} label=${label} source=${source} reference=${reference_input:-none} selected=$(jq -r 'length' <<< "${selected_json}")"
}

cntools_transaction_plan_add_native_script() {
  local label="${1:-}"
  local purpose="${2:-}"
  local script_file="${3:-}"
  shift 3 2>/dev/null || return 2
  cntools_transaction_plan_add_native_script_internal \
    "${label}" "${purpose}" embedded "${script_file}" "" "$@"
}

cntools_transaction_plan_add_native_reference_script() {
  local label="${1:-}"
  local purpose="${2:-}"
  local script_file="${3:-}"
  local reference_input="${4:-}"
  shift 4 2>/dev/null || return 2
  cntools_transaction_plan_add_native_script_internal \
    "${label}" "${purpose}" reference "${script_file}" \
    "${reference_input}" "$@" || return $?
  # The transaction body is now bound to the selected reference input, but it
  # does not carry that input's output or script. Without querying the UTxO,
  # its script hash cannot be verified from a portable offline package alone.
  CNTOOLS_TRANSACTION_PLAN_ASSURANCE="manual"
  cntools_transaction_log TRANSACTION \
    "signer-plan assurance changed to manual for reference script"
}

cntools_transaction_body_matches_plan() {
  local body_file="${1:-}"
  local view=""
  local record=""
  local actual_before=""
  local actual_hereafter=""
  local actual_required=""
  local expected_required=""
  local actual_native_scripts=""
  local expected_native_scripts=""
  local actual_reference_inputs=""
  local expected_reference_inputs=""
  local witness_count=""

  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" ]] || return 2
  cntools_transaction_view_into view "${body_file}" || return 1
  record="$(jq -er '
    def slot:
      if . == null then ""
      elif type == "number" and floor == . and . >= 0 then tostring
      elif type == "string" and test("^(0|[1-9][0-9]*)$") then .
      else error("invalid slot")
      end;
    def required:
      if . == null then []
      elif type == "array" and
           all(.[]; type == "string" and test("^[0-9a-fA-F]{56}$"))
      then map(ascii_downcase) | unique | sort
      else error("invalid required signer set")
      end;
    def reference_inputs:
      if . == null then []
      elif type == "array" and all(.[];
        type == "string" and
        test("^[0-9a-fA-F]{64}#(0|[1-9][0-9]{0,9})$") and
        ((split("#")[1] | tonumber) <= 4294967295))
      then map(ascii_downcase) | unique | sort
      else error("invalid reference input set")
      end;
    [
      (."validity range"."lower bound" | slot),
      (."validity range"."upper bound" | slot),
      (."required signers (payment key hashes needed for scripts)" |
        required | tojson),
      (if (.scripts | type) == "array" and
          all(.scripts[];
            (."script hash" | type) == "string" and
            (."script hash" | test("^[0-9a-fA-F]{56}$")) and
            (."script data" | type) == "object" and
            (."script data".type == "native" or
             ."script data".type == "plutus"))
       then [.scripts[] | select(."script data".type == "native") |
         ."script hash" | ascii_downcase] | unique | sort | tojson
       else error("invalid script set") end),
      (if has("reference inputs")
       then (."reference inputs" | reference_inputs | tojson)
       else error("missing reference input set") end),
      (if (.witnesses | type) == "array" then (.witnesses | length | tostring)
       else error("invalid witnesses") end)
    ] | join("\u001f")
  ' <<< "${view}" 2>/dev/null)" || {
    cntools_transaction_set_error \
      "Cardano CLI returned an unsupported transaction review structure."
    return 1
  }
  IFS=$'\037' read -r actual_before actual_hereafter \
    actual_required actual_native_scripts actual_reference_inputs \
    witness_count <<< "${record}"
  expected_required="$(jq -c \
    '[.[].credential] | unique | sort' \
    <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")" || return 1
  expected_native_scripts="$(jq -c '
    [.[] | select(.source == "embedded") | .scriptHash] | unique | sort
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS}")" || return 1
  expected_reference_inputs="$(jq -c '
    [.[] | select(.source == "reference") | .referenceInput] | unique | sort
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS}")" || return 1
  if [[ "${actual_before}" != "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" ||
        "${actual_hereafter}" != "${CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER}" ]]; then
    cntools_transaction_set_error \
      "The built transaction validity interval does not match its signer plan."
    return 1
  fi
  if [[ "${actual_required}" != "${expected_required}" ]]; then
    cntools_transaction_set_error \
      "The built transaction's explicit required signers do not match its signer plan."
    return 1
  fi
  if [[ "${actual_native_scripts}" != "${expected_native_scripts}" ]]; then
    cntools_transaction_set_error \
      "The built transaction's embedded native scripts do not match its signer plan."
    return 1
  fi
  if ! jq -en --argjson expected "${expected_reference_inputs}" \
      --argjson actual "${actual_reference_inputs}" \
      '($expected - $actual) | length == 0' >/dev/null; then
    cntools_transaction_set_error \
      "The built transaction is missing a native script's planned reference input."
    return 1
  fi
  if [[ "${actual_reference_inputs}" != "[]" &&
        "${CNTOOLS_TRANSACTION_PLAN_ASSURANCE}" != "manual" ]]; then
    cntools_transaction_set_error \
      "A transaction using reference inputs requires manual review assurance."
    return 1
  fi
  if [[ "${witness_count}" != "0" ]]; then
    cntools_transaction_set_error \
      "A new transaction body must not contain pre-existing key witnesses."
    return 1
  fi
}

cntools_transaction_package_body_matches_metadata() {
  local package_file="${1:-}"
  local body_file="${2:-}"
  local view=""
  local view_file=""

  cntools_transaction_view_into view "${body_file}" || return 1
  cntools_transaction_json_temp_into \
    view_file package-body-view "${view}" || return 1
  jq -ne --slurpfile package "${package_file}" \
    --slurpfile body "${view_file}" '
    def slot:
      if . == null then null
      elif type == "number" and floor == . and . >= 0 then .
      elif type == "string" and test("^(0|[1-9][0-9]*)$") then tonumber
      else error("invalid slot")
      end;
    def required:
      if . == null then []
      elif type == "array" and
           all(.[]; type == "string" and test("^[0-9a-fA-F]{56}$"))
      then map(ascii_downcase) | unique | sort
      else error("invalid required signer set")
      end;
    def reference_inputs:
      if . == null then []
      elif type == "array" and all(.[];
        type == "string" and
        test("^[0-9a-fA-F]{64}#(0|[1-9][0-9]{0,9})$") and
        ((split("#")[1] | tonumber) <= 4294967295))
      then map(ascii_downcase) | unique | sort
      else error("invalid reference input set")
      end;
    ($package | length) == 1 and ($body | length) == 1 and
    ($package[0] as $package | $body[0] as $body |
    ($body."validity range"."lower bound" | slot) ==
      $package.validity.invalidBefore and
    ($body."validity range"."upper bound" | slot) ==
      $package.validity.invalidHereafter and
    ($body."required signers (payment key hashes needed for scripts)" |
      required) ==
      ([$package.signing.required[].credential] | unique | sort) and
    (if ($body.scripts | type) == "array" then
       [$body.scripts[] | select(."script data".type == "native") |
         ."script hash" | ascii_downcase] | unique | sort
     else error("invalid script set") end) ==
      ([$package.signing.nativeScripts[] |
        select(.source == "embedded") | .scriptHash] | unique | sort) and
    ($body | has("reference inputs")) and
    ((([$package.signing.nativeScripts[] |
         select(.source == "reference") | .referenceInput] | unique) -
       ($body."reference inputs" | reference_inputs)) | length == 0) and
    ((($body."reference inputs" | reference_inputs) | length) == 0 or
      $package.signing.assurance == "manual") and
    (($body.witnesses | type) == "array" and
      ($body.witnesses | length) == 0))
  ' >/dev/null 2>&1 || {
    cntools_transaction_set_error \
      "The transaction body does not match its validity, required-signer, native-script, or reference-input plan."
    return 1
  }
}

cntools_transaction_package_structure_valid() {
  local package_file="${1:-}"
  local allow_pending_assembly="${2:-N}"

  case "${allow_pending_assembly}" in Y|N) ;; *) return 2 ;; esac

  cntools_transaction_file_safe \
    "${package_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" || return 1
  jq -e --arg schema "${CNTOOLS_TRANSACTION_SCHEMA}" \
    --argjson schema_version "${CNTOOLS_TRANSACTION_SCHEMA_VERSION}" \
    --argjson allow_pending_assembly \
      "$([[ "${allow_pending_assembly}" == "Y" ]] && printf true || printf false)" '
    def clean($maximum):
      type == "string" and length > 0 and length <= $maximum and
      (test("[\u0000-\u001f\u007f]") | not);
    def hex($count):
      type == "string" and length == $count and test("^[0-9a-f]+$");
    def safe_summary:
      if type == "string" then
        length <= 4096 and (test("[\u0000-\u001f\u007f]") | not)
      elif type == "array" then
        length <= 256 and all(.[]; safe_summary)
      elif type == "object" then
        length <= 256 and all(to_entries[];
          (.key | clean(120)) and (.value | safe_summary))
      else type == "null" or type == "boolean" or type == "number"
      end;
    def envelope($kind):
      type == "object" and
      (.type | type == "string") and
      (.cborHex | type == "string" and length > 0 and length <= 8388608 and
        test("^([0-9a-fA-F]{2})+$")) and
      (if $kind == "body" then
         (.type | test("^(TxBody|Tx)[[:space:]]+.+Era$"))
       elif $kind == "witness" then (.type | test("^TxWitness[[:space:]]+.+Era$"))
       else (.type | test("^Tx[[:space:]]+.+Era$")) end);
    type == "object" and
    keys == ["createdAt", "intent", "network", "schema", "schemaVersion",
             "signedTransaction", "signing", "transaction", "validity"] and
    .schema == $schema and .schemaVersion == $schema_version and
    (.createdAt | clean(40)) and
    (.network | type == "object" and keys == ["magic", "name"] and
      ((.name == "mainnet" and .magic == null) or
       (.name == "guild" and .magic == 141) or
       (.name == "preprod" and .magic == 1) or
       (.name == "preview" and .magic == 2))) and
    (.intent | type == "object" and keys == ["description", "kind", "summary"] and
      (.kind | clean(80)) and
      (.description | type == "string" and length <= 240 and
        (test("[\u0000-\u001f\u007f]") | not)) and
      (.summary | type == "object" and safe_summary)) and
    (.validity | type == "object" and keys == ["invalidBefore", "invalidHereafter"] and
      all(.[]; . == null or (type == "number" and floor == . and . >= 0))) and
    (.transaction | type == "object" and
      keys == ["body", "hardwarePrepared", "id"] and
      (.id | hex(64)) and (.hardwarePrepared | type == "boolean") and
      (.body | envelope("body"))) and
    (.signing | . as $signing |
      type == "object" and
      keys == ["assurance", "changeKeys", "nativeScripts", "required", "witnesses"] and
      ($signing.assurance == "exact" or $signing.assurance == "manual") and
      ($signing.required | type == "array" and length <= 128 and
        all(.[];
          type == "object" and
          keys == ["credential", "hardwareGroup", "keyId", "labels", "preferredKind", "roles"] and
          (.keyId | hex(64)) and
          (.credential | hex(56)) and
          (.hardwareGroup == null or
            (.hardwareGroup | type == "string" and
              test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))) and
          (.labels | type == "array" and length > 0 and length <= 16 and
            all(.[]; clean(120))) and
          (.roles | type == "array" and length > 0 and length <= 16 and
            all(.[]; type == "string" and test("^[a-z][a-z0-9-]{0,31}$"))) and
          (.preferredKind == "cli" or .preferredKind == "hardware" or
           .preferredKind == "either") and
          (.hardwareGroup == null or .preferredKind == "hardware")) and
        ([.[].keyId] | length == (unique | length))) and
      ($signing.changeKeys |
        type == "array" and length <= 32 and
        all(.[];
          type == "object" and
          keys == ["hardwareGroup", "keyId", "labels"] and
          (.keyId | hex(64)) and
          (.hardwareGroup | type == "string" and
            test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
          (.labels | type == "array" and length > 0 and length <= 16 and
            all(.[]; clean(120)))) and
        ([.[].keyId] | length == (unique | length)) and
        ([.[].hardwareGroup] -
          [$signing.required[].hardwareGroup | select(. != null)] |
          length == 0)) and
      ($signing.nativeScripts | type == "array" and length <= 64 and
        all(.[];
          type == "object" and
          keys == ["label", "purpose", "referenceInput", "script", "scriptHash", "selectedKeyIds", "source"] and
          (.label | clean(120)) and
          (.purpose == "spend" or .purpose == "mint" or
           .purpose == "certificate" or .purpose == "withdrawal" or
           .purpose == "vote" or .purpose == "proposal") and
          (.script | type == "object") and
          (.scriptHash | hex(56)) and
          ((.source == "embedded" and .referenceInput == null) or
           (.source == "reference" and
            (.referenceInput | type == "string" and
             test("^[0-9a-f]{64}#(0|[1-9][0-9]{0,9})$") and
             ((split("#")[1] | tonumber) <= 4294967295)))) and
          (.selectedKeyIds | type == "array" and length <= 128 and
            all(.[]; hex(64)) and length == (unique | length))) and
        ([.[].selectedKeyIds[]] - [$signing.required[].keyId] |
          length == 0)) and
      ((any($signing.nativeScripts[]; .source == "reference") | not) or
        $signing.assurance == "manual") and
      ($signing.witnesses | type == "array" and length <= 128 and
        all(.[];
          type == "object" and
          keys == ["createdAt", "keyId", "kind", "witness"] and
          (.createdAt | clean(40)) and (.keyId | hex(64)) and
          (.kind == "cli" or .kind == "hardware") and
          (.witness | envelope("witness"))) and
        ([.[].keyId] | length == (unique | length))) and
      ([$signing.witnesses[].keyId] - [$signing.required[].keyId] |
        length == 0) and
      (all($signing.witnesses[];
        . as $witness |
        any($signing.required[];
          .keyId == $witness.keyId and
          (.preferredKind == "either" or
           .preferredKind == $witness.kind))))) and
    (([.signing.required[].keyId] - [.signing.witnesses[].keyId]) | length) as $missing |
    (.signedTransaction == null or (.signedTransaction | envelope("signed"))) and
    (if .signedTransaction == null then
       $missing > 0 or $allow_pending_assembly
     else $missing == 0
     end)
  ' "${package_file}" >/dev/null 2>&1
}

cntools_transaction_package_hardware_groups_valid() {
  local package_file="${1:-}"
  local allow_pending_assembly="${2:-N}"

  cntools_transaction_package_structure_valid \
    "${package_file}" "${allow_pending_assembly}" || return 1
  jq -e '
    . as $package |
    [$package.signing.required[].hardwareGroup | select(. != null)] | unique |
    all(.[];
      . as $group |
      ([$package.signing.required[] |
        select(.hardwareGroup == $group) | .keyId] | sort) as $required |
      ([$package.signing.witnesses[] as $witness |
        $package.signing.required[] |
        select(.hardwareGroup == $group and
               .keyId == $witness.keyId) | .keyId] | sort) as $witnessed |
      ($witnessed | length) == 0 or $witnessed == $required)
  ' "${package_file}" >/dev/null 2>&1 || {
    cntools_transaction_set_error \
      "A hardware signing session is only partially recorded in this transaction package."
    return 1
  }
}

cntools_transaction_package_credentials_valid() {
  local package_file="${1:-}"
  local allow_pending_assembly="${2:-N}"
  local record=""
  local key_id=""
  local credential=""
  local derived=""

  cntools_transaction_package_structure_valid \
    "${package_file}" "${allow_pending_assembly}" || return 1
  while IFS= read -r record; do
    IFS=$'\037' read -r key_id credential <<< "${record}"
    cntools_transaction_credential_from_key_id_into \
      derived "${key_id}" || return 1
    if [[ "${derived}" != "${credential}" ]]; then
      cntools_transaction_set_error \
        "A planned signing key does not match its recorded credential hash."
      return 1
    fi
  done < <(jq -r '.signing.required[] |
    [.keyId, .credential] | join("\u001f")' "${package_file}")
}

cntools_transaction_package_reset_loaded() {
  CNTOOLS_TRANSACTION_PACKAGE_FILE=""
  CNTOOLS_TRANSACTION_BODY_FILE=""
  CNTOOLS_TRANSACTION_SIGNED_FILE=""
  CNTOOLS_TRANSACTION_ID=""
  CNTOOLS_TRANSACTION_PACKAGE_NETWORK=""
  CNTOOLS_TRANSACTION_PACKAGE_ASSURANCE=""
  CNTOOLS_TRANSACTION_PACKAGE_INTENT=""
  CNTOOLS_TRANSACTION_PACKAGE_DESCRIPTION=""
  CNTOOLS_TRANSACTION_PACKAGE_INVALID_BEFORE=""
  CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER=""
  CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED="N"
  CNTOOLS_TRANSACTION_REQUIRED_COUNT=0
  CNTOOLS_TRANSACTION_WITNESS_COUNT=0
  CNTOOLS_TRANSACTION_COMPLETE="N"
}

cntools_transaction_package_native_scripts_valid() {
  local package_file="${1:-}"
  local count=0
  local index=0
  local script_file=""
  local credentials_file=""
  local invalid_before=""
  local invalid_hereafter=""
  local expected_hash=""
  local actual_hash=""

  cntools_transaction_file_safe \
    "${package_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" || return 1
  count="$(jq -er '.signing.nativeScripts | length' "${package_file}")" ||
    return 1
  invalid_before="$(jq -r \
    '.validity.invalidBefore // ""' "${package_file}")" ||
    return 1
  invalid_hereafter="$(jq -r \
    '.validity.invalidHereafter // ""' "${package_file}")" ||
    return 1
  for (( index = 0; index < count; index++ )); do
    cntools_transaction_temp_file script_file native-script || return 1
    jq --argjson index "${index}" \
      '.signing.nativeScripts[$index].script' \
      "${package_file}" > "${script_file}" || return 1
    cntools_transaction_native_script_valid "${script_file}" || return 1
    expected_hash="$(jq -r --argjson index "${index}" \
      '.signing.nativeScripts[$index].scriptHash' \
      "${package_file}")" || return 1
    cntools_transaction_native_script_hash_into \
      actual_hash "${script_file}" || return 1
    [[ "${actual_hash}" == "${expected_hash}" ]] || return 1
    cntools_transaction_temp_file \
      credentials_file native-credentials || return 1
    jq -c --argjson index "${index}" '
      . as $package |
      [.signing.nativeScripts[$index].selectedKeyIds[] as $id |
       $package.signing.required[] |
       select(.keyId == $id) | .credential] |
      if any(.[]; . == null) then null else unique end
    ' "${package_file}" > "${credentials_file}" || return 1
    ! jq -e '. == null' "${credentials_file}" >/dev/null 2>&1 || return 1
    cntools_transaction_native_script_satisfied \
      "${script_file}" "${credentials_file}" \
      "${invalid_before}" "${invalid_hereafter}" || return 1
  done
}

cntools_transaction_package_witnesses_valid() {
  local package_file="${1:-}"
  local body_file="${2:-}"
  local transaction_id="${3:-}"
  local witness_count=0
  local index=0
  local witness_file=""
  local assembled_file=""
  local signed_file=""
  local assembled_ids=""
  local assembled_witnesses=""
  local signed_ids=""
  local recorded_ids=""
  local assembled_cbor=""
  local signed_cbor=""
  local -a witness_files=()

  [[ "${transaction_id}" =~ ^[0-9a-f]{64}$ ]] || return 2

  witness_count="$(jq -er '.signing.witnesses | length' \
    "${package_file}")" || return 1
  recorded_ids="$(jq -c \
    '[.signing.witnesses[].keyId] | sort' "${package_file}")" || return 1
  if (( witness_count == 0 )); then
    if jq -e '.signedTransaction != null' "${package_file}" >/dev/null; then
      cntools_transaction_temp_file assembled_file witness-set-check || return 1
      cntools_transaction_assemble_witness_files \
        "${assembled_file}" "${body_file}" || return 1
      cntools_transaction_temp_file signed_file witness-signed-check || return 1
      jq '.signedTransaction' "${package_file}" > "${signed_file}" || return 1
      cntools_transaction_file_witness_key_ids_into \
        signed_ids "${signed_file}" || return 1
      [[ "${signed_ids}" == "${recorded_ids}" ]] || return 1
      assembled_cbor="$(jq -er '.cborHex | ascii_downcase' \
        "${assembled_file}")" || return 1
      signed_cbor="$(jq -er '.cborHex | ascii_downcase' \
        "${signed_file}")" || return 1
      [[ "${assembled_cbor}" == "${signed_cbor}" ]] || return 1
    fi
    return 0
  fi
  for (( index = 0; index < witness_count; index++ )); do
    cntools_transaction_temp_file witness_file package-witness || return 1
    jq --argjson index "${index}" \
      '.signing.witnesses[$index].witness' \
      "${package_file}" > "${witness_file}" || return 1
    witness_files+=("${witness_file}")
  done
  cntools_transaction_temp_file assembled_file witness-set-check || return 1
  cntools_transaction_assemble_witness_files \
    "${assembled_file}" "${body_file}" "${witness_files[@]}" || return 1
  cntools_transaction_file_witnesses_into \
    assembled_witnesses "${assembled_file}" || return 1
  assembled_ids="$(jq -cer '[.[].keyId]' \
    <<< "${assembled_witnesses}")" || return 1
  [[ "${assembled_ids}" == "${recorded_ids}" ]] || return 1
  cntools_transaction_witness_signatures_valid \
    "${transaction_id}" "${assembled_witnesses}" || return 1

  if jq -e '.signedTransaction != null' "${package_file}" >/dev/null; then
    cntools_transaction_temp_file signed_file witness-signed-check || return 1
    jq '.signedTransaction' "${package_file}" > "${signed_file}" || return 1
    cntools_transaction_file_witness_key_ids_into \
      signed_ids "${signed_file}" || return 1
    [[ "${signed_ids}" == "${recorded_ids}" ]] || return 1
  fi

  # A matching transaction ID proves only that the transaction body is the
  # same. Bind the complete signed envelope to the body's scripts, datums,
  # redeemers, auxiliary data, and the authenticated detached witnesses by
  # comparing it with a fresh canonical assembly.
  if [[ -n "${signed_file}" ]]; then
    assembled_cbor="$(jq -er '.cborHex | ascii_downcase' \
      "${assembled_file}")" || return 1
    signed_cbor="$(jq -er '.cborHex | ascii_downcase' \
      "${signed_file}")" || return 1
    [[ "${assembled_cbor}" == "${signed_cbor}" ]] || return 1
  fi
}

cntools_transaction_package_load() {
  local requested_file="${1:-}"
  local allow_pending_assembly="${2:-N}"
  local package_file=""
  local body_file=""
  local signed_file=""
  local calculated_id=""
  local signed_id=""
  local signed_present="N"
  local body_witness_count=""

  case "${allow_pending_assembly}" in Y|N) ;; *) return 2 ;; esac

  cntools_transaction_package_reset_loaded
  cntools_transaction_clear_error
  if ! cntools_transaction_file_safe \
      "${requested_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}"; then
    cntools_transaction_set_error \
      "The selected transaction package is missing, unreadable, oversized, or unsafe."
    return 1
  fi
  # All validation and later signing use one private snapshot. An artifact on
  # removable media or in another writable directory therefore cannot change
  # between review, witness authentication, and assembly.
  cntools_transaction_snapshot_into \
    package_file "${requested_file}" \
    "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" package-input || return 1
  if ! cntools_transaction_package_structure_valid \
      "${package_file}" "${allow_pending_assembly}"; then
    cntools_transaction_set_error \
      "The selected file is not a valid CNTools transaction package."
    return 1
  fi
  cntools_transaction_package_credentials_valid \
    "${package_file}" "${allow_pending_assembly}" || return 1
  if ! cntools_transaction_package_native_scripts_valid "${package_file}"; then
    cntools_transaction_set_error \
      "The transaction package contains an invalid or unsatisfied native-script plan."
    return 1
  fi
  cntools_transaction_package_hardware_groups_valid \
    "${package_file}" "${allow_pending_assembly}" ||
    return 1
  cntools_transaction_temp_file body_file package-body || return 1
  jq '.transaction.body' "${package_file}" > "${body_file}" || return 1
  cntools_transaction_package_body_matches_metadata \
    "${package_file}" "${body_file}" || return 1
  if ! cntools_transaction_id_into calculated_id "${body_file}"; then
    return 1
  fi
  if [[ "${calculated_id}" != \
        "$(jq -r '.transaction.id' "${package_file}")" ]]; then
    cntools_transaction_set_error \
      "The transaction body does not match the transaction ID recorded in the package."
    return 1
  fi
  cntools_transaction_file_witness_count_into \
    body_witness_count "${body_file}" || return 1
  if [[ "${body_witness_count}" != "0" ]]; then
    cntools_transaction_set_error \
      "A CNTools package body must not contain pre-existing key witnesses."
    return 1
  fi
  if ! cntools_transaction_package_witnesses_valid \
      "${package_file}" "${body_file}" "${calculated_id}"; then
    if [[ -z "${CNTOOLS_TRANSACTION_ERROR}" ]]; then
      cntools_transaction_set_error \
        "The transaction package contains an invalid witness or one that does not match its recorded signing key."
    fi
    return 1
  fi
  if jq -e '.signedTransaction != null' "${package_file}" >/dev/null; then
    signed_present="Y"
    cntools_transaction_temp_file signed_file package-signed || return 1
    jq '.signedTransaction' "${package_file}" > "${signed_file}" || return 1
    if ! cntools_transaction_id_into signed_id "${signed_file}"; then
      return 1
    fi
    if [[ "${signed_id}" != "${calculated_id}" ]]; then
      cntools_transaction_set_error \
        "The signed transaction does not contain the package transaction body."
      return 1
    fi
  fi

  CNTOOLS_TRANSACTION_PACKAGE_FILE="${package_file}"
  CNTOOLS_TRANSACTION_BODY_FILE="${body_file}"
  CNTOOLS_TRANSACTION_SIGNED_FILE="${signed_file}"
  CNTOOLS_TRANSACTION_ID="${calculated_id}"
  CNTOOLS_TRANSACTION_PACKAGE_NETWORK="$(jq -r '.network.name' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_ASSURANCE="$(jq -r '.signing.assurance' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_INTENT="$(jq -r '.intent.kind' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_DESCRIPTION="$(jq -r '.intent.description' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_INVALID_BEFORE="$(jq -r \
    '.validity.invalidBefore // ""' "${package_file}")"
  CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER="$(jq -r \
    '.validity.invalidHereafter // ""' "${package_file}")"
  if jq -e '.transaction.hardwarePrepared' "${package_file}" >/dev/null; then
    CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED="Y"
  fi
  CNTOOLS_TRANSACTION_REQUIRED_COUNT="$(jq -r \
    '.signing.required | length' "${package_file}")"
  CNTOOLS_TRANSACTION_WITNESS_COUNT="$(jq -r \
    '.signing.witnesses | length' "${package_file}")"
  if [[ "${signed_present}" == "Y" ]]; then
    CNTOOLS_TRANSACTION_COMPLETE="Y"
  fi
  cntools_transaction_log TRANSACTION \
    "package loaded id=${CNTOOLS_TRANSACTION_ID} network=${CNTOOLS_TRANSACTION_PACKAGE_NETWORK} witnesses=${CNTOOLS_TRANSACTION_WITNESS_COUNT}/${CNTOOLS_TRANSACTION_REQUIRED_COUNT} assurance=${CNTOOLS_TRANSACTION_PACKAGE_ASSURANCE}"
}

cntools_transaction_package_create_staged_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_body_file="${2:-}"
  local _cntools_hardware_prepared="N"
  local _cntools_hardware_planned="N"
  local _cntools_runtime_kind=""
  local _cntools_prepared_body=""
  local _cntools_body_snapshot=""
  local _cntools_body_kind=""
  local _cntools_summary_file=""
  local _cntools_required_file=""
  local _cntools_change_keys_file=""
  local _cntools_native_scripts_file=""
  local _cntools_transaction_id=""
  local _cntools_network_magic=""
  local _cntools_invalid_before="null"
  local _cntools_invalid_hereafter="null"
  local _cntools_created_at=""
  local _cntools_staged_file=""
  local _cntools_complete_file=""
  local _cntools_signed_file=""
  local _cntools_witness_count=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ "${CNTOOLS_TRANSACTION_PLAN_READY}" == "Y" ]] || return 2
  [[ "$(cntools_transaction_plan_witness_count)" =~ ^[0-9]+$ ]] || {
    cntools_transaction_set_error \
      "The transaction signer plan returned an invalid witness count."
    return 1
  }
  if jq -e 'any(.[]; .preferredKind == "hardware")' \
      <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" >/dev/null; then
    _cntools_hardware_planned="Y"
  fi
  for _cntools_runtime_kind in \
      "${CNTOOLS_TRANSACTION_RUNTIME_SOURCE_KINDS[@]}"; do
    [[ "${_cntools_runtime_kind}" != "hardware" ]] ||
      _cntools_hardware_planned="Y"
  done
  if [[ "${_cntools_hardware_planned}" == "Y" ]]; then
    if ! declare -F cntools_transaction_prepare_hardware_body_into \
        >/dev/null 2>&1; then
      cntools_transaction_set_error \
        "The hardware signing library must be loaded before packaging a transaction with hardware signers."
      return 1
    fi
    cntools_transaction_prepare_hardware_body_into \
      _cntools_prepared_body "${_cntools_body_file}" 0 || return 1
    _cntools_body_file="${_cntools_prepared_body}"
    _cntools_hardware_prepared="Y"
  fi
  cntools_transaction_envelope_kind_into \
    _cntools_body_kind "${_cntools_body_file}" || {
    cntools_transaction_set_error "The transaction builder did not produce a valid body envelope."
    return 1
  }
  [[ "${_cntools_body_kind}" == "body" ||
     "${_cntools_body_kind}" == "transaction" ]] || {
    cntools_transaction_set_error \
      "The transaction builder did not produce a valid body envelope."
    return 1
  }
  # Freeze the exact body before deriving its ID, validating its signer plan,
  # and embedding it. This closes the mutable/removable-media boundary without
  # ever moving a multi-megabyte envelope through an external command argument.
  cntools_transaction_snapshot_into \
    _cntools_body_snapshot "${_cntools_body_file}" \
    "${CNTOOLS_TRANSACTION_MAX_BODY_BYTES}" package-body || return 1
  jq -e . "${_cntools_body_snapshot}" >/dev/null 2>&1 || return 1
  _cntools_body_file="${_cntools_body_snapshot}"
  cntools_transaction_body_matches_plan "${_cntools_body_file}" || return 1
  cntools_transaction_id_into \
    _cntools_transaction_id "${_cntools_body_file}" || return 1
  _cntools_network_magic="$(cntools_transaction_network_magic)" || {
    cntools_transaction_set_error "The current Cardano network is unsupported."
    return 1
  }
  [[ -z "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" ]] ||
    _cntools_invalid_before="${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}"
  [[ -z "${CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER}" ]] ||
    _cntools_invalid_hereafter="${CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER}"
  cntools_transaction_json_temp_into \
    _cntools_summary_file package-summary \
    "${CNTOOLS_TRANSACTION_PLAN_SUMMARY}" || return 1
  cntools_transaction_json_temp_into \
    _cntools_required_file package-required \
    "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" || return 1
  cntools_transaction_json_temp_into \
    _cntools_change_keys_file package-change-keys \
    "${CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS}" || return 1
  cntools_transaction_json_temp_into \
    _cntools_native_scripts_file package-native-scripts \
    "${CNTOOLS_TRANSACTION_PLAN_NATIVE_SCRIPTS}" || return 1
  _cntools_created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  cntools_transaction_temp_file _cntools_staged_file package || return 1
  jq -n \
    --arg schema "${CNTOOLS_TRANSACTION_SCHEMA}" \
    --argjson schema_version "${CNTOOLS_TRANSACTION_SCHEMA_VERSION}" \
    --arg created_at "${_cntools_created_at}" \
    --arg network "${CNTOOLS_NETWORK}" \
    --argjson magic "${_cntools_network_magic}" \
    --arg intent "${CNTOOLS_TRANSACTION_PLAN_INTENT}" \
    --arg description "${CNTOOLS_TRANSACTION_PLAN_DESCRIPTION}" \
    --slurpfile summary "${_cntools_summary_file}" \
    --argjson invalid_before "${_cntools_invalid_before}" \
    --argjson invalid_hereafter "${_cntools_invalid_hereafter}" \
    --arg transaction_id "${_cntools_transaction_id}" \
    --slurpfile body "${_cntools_body_file}" \
    --argjson hardware_prepared \
      "$([[ "${_cntools_hardware_prepared}" == "Y" ]] && printf true || printf false)" \
    --arg assurance "${CNTOOLS_TRANSACTION_PLAN_ASSURANCE}" \
    --slurpfile required "${_cntools_required_file}" \
    --slurpfile change_keys "${_cntools_change_keys_file}" \
    --slurpfile native_scripts "${_cntools_native_scripts_file}" '
      {
        schema: $schema,
        schemaVersion: $schema_version,
        createdAt: $created_at,
        network: {name: $network, magic: $magic},
        intent: {
          kind: $intent,
          description: $description,
          summary: $summary[0]
        },
        validity: {
          invalidBefore: $invalid_before,
          invalidHereafter: $invalid_hereafter
        },
        transaction: {
          id: $transaction_id,
          body: $body[0],
          hardwarePrepared: $hardware_prepared
        },
        signing: {
          assurance: $assurance,
          required: $required[0],
          changeKeys: $change_keys[0],
          nativeScripts: $native_scripts[0],
          witnesses: []
        },
        signedTransaction: null
      }
    ' > "${_cntools_staged_file}" || return 1
  cntools_transaction_package_structure_valid \
    "${_cntools_staged_file}" Y || {
    cntools_transaction_set_error "The generated transaction package failed validation."
    return 1
  }
  _cntools_witness_count="$(cntools_transaction_plan_witness_count)" || return 1
  if [[ "${_cntools_witness_count}" == "0" ]]; then
    cntools_transaction_temp_file _cntools_signed_file keyless-signed || return 1
    cntools_transaction_assemble_witness_files \
      "${_cntools_signed_file}" "${_cntools_body_file}" || return 1
    cntools_transaction_temp_file _cntools_complete_file package || return 1
    jq --slurpfile signed "${_cntools_signed_file}" \
      '.signedTransaction = $signed[0]' "${_cntools_staged_file}" \
      > "${_cntools_complete_file}" || return 1
    cntools_transaction_package_structure_valid \
      "${_cntools_complete_file}" || return 1
    _cntools_staged_file="${_cntools_complete_file}"
  fi
  cntools_transaction_package_load "${_cntools_staged_file}" || {
    cntools_transaction_set_error \
      "The generated transaction package failed final semantic validation."
    return 1
  }
  _cntools_output_ref="${_cntools_staged_file}"
}

cntools_transaction_package_create() {
  local body_file="${1:-}"
  local output_file="${2:-}"
  local staged_file=""

  cntools_transaction_package_create_staged_into \
    staged_file "${body_file}" || return 1
  cntools_transaction_publish "${staged_file}" "${output_file}"
}

cntools_transaction_default_output_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_input_file="${2:-}"
  local _cntools_suffix="${3:-signed}"
  local _cntools_parent=""
  local _cntools_name=""
  local _cntools_stem=""
  local _cntools_candidate=""
  local _cntools_index=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_suffix}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_parent="${_cntools_input_file%/*}"
  _cntools_name="${_cntools_input_file##*/}"
  [[ -n "${_cntools_parent}" && -n "${_cntools_name}" ]] || return 1
  _cntools_stem="${_cntools_name%.*}"
  [[ -n "${_cntools_stem}" ]] || _cntools_stem="transaction"
  _cntools_candidate="${_cntools_parent}/${_cntools_stem}.${_cntools_suffix}.json"
  while [[ -e "${_cntools_candidate}" || -L "${_cntools_candidate}" ]]; do
    _cntools_index=$((_cntools_index + 1))
    (( _cntools_index <= 999 )) || return 1
    _cntools_candidate="${_cntools_parent}/${_cntools_stem}.${_cntools_suffix}.${_cntools_index}.json"
  done
  _cntools_output_ref="${_cntools_candidate}"
}
