#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2154
# Stage 4 compatibility action for hardened hardware-wallet import.
# Sourcing defines functions only. The compatibility dispatcher supplies an
# authenticated context and the inherited CNTools prompt/display helpers.

_cntools_action_wallet_import_hardware_validation_failure() {
  builtin printf '%s\n' \
    'CNTools hardware wallet import action failed validation.' >&2
  return 70
}

_cntools_action_wallet_import_hardware_warning() {
  builtin printf '%s\n' \
    'WARNING: the hardware wallet was imported, but administrative cleanup needs attention.' >&2
}

_cntools_action_wallet_import_hardware_terminal_value_valid() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ && "${#value}" -le "${maximum}" &&
     ! "${value}" =~ [[:cntrl:]] && "${value}" != *\\* ]]
}

_cntools_action_wallet_import_hardware_name_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_import_hardware_index_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  (( 10#${value} <= 2147483647 ))
}

_cntools_action_wallet_import_hardware_metadata() {
  local target="${1:-}" output_variable="${2:-}" captured_metadata=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  captured_metadata="$(_cntools_result_stat "${target}")" || return 1
  printf -v "${output_variable}" '%s' "${captured_metadata}"
}

_cntools_action_wallet_import_hardware_directory_validate() {
  local target="${1:-}" expected_modes="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_wallet_import_hardware_metadata "${target}" metadata ||
    return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ",${expected_modes}," == *",${mode},"* ]]
}

_cntools_action_wallet_import_hardware_file_validate() {
  local target="${1:-}" maximum_size="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ "${maximum_size}" =~ ^[1-9][0-9]*$ && -f "${target}" &&
     ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_wallet_import_hardware_metadata "${target}" metadata ||
    return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == 600 && "${links}" == 1 &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le "${maximum_size}" ]]
}

_cntools_action_wallet_import_hardware_tool_resolve() {
  local configured="${1:-}" output_variable="${2:-}"
  local kind="" resolved="" metadata="" owner="" mode="" links="" size=""

  [[ "${output_variable}" =~ ^wallet_import_hardware_[a-z0-9_]+_path$ ]] ||
    return 70
  if [[ "${configured}" =~ ^[a-z][a-z0-9-]*$ ]]; then
    kind="$(builtin type -t "${configured}" 2>/dev/null || true)"
    [[ -n "${kind}" ]] || return 1
    [[ "${kind}" != function && "${kind}" != alias ]] || return 70
    resolved="$(builtin type -P "${configured}" 2>/dev/null || true)"
  elif [[ "${configured}" == /* ]]; then
    resolved="${configured}"
  else
    return 70
  fi
  [[ "${resolved}" == /* && "${resolved}" != */ &&
     "${resolved}" != *//* && "${resolved}" != *\\* &&
     ! "${resolved}" =~ [[:cntrl:]] && -f "${resolved}" &&
     -x "${resolved}" && ! -L "${resolved}" ]] || return 70
  _cntools_registry_path_has_no_symlinks "${resolved}" || return 70
  _cntools_action_wallet_import_hardware_metadata "${resolved}" metadata ||
    return 70
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 70
  mode="${mode#0}"
  [[ ( "${owner}" == 0 || "${owner}" == "${EUID}" ) &&
     "${mode}" =~ ^[57][0145][0145]$ && "${links}" == 1 &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 268435456 ]] ||
    return 70
  printf -v "${output_variable}" '%s' "${resolved}"
}

_cntools_action_wallet_import_hardware_directory_identity() {
  local target="${1:-}" output_variable="${2:-}" captured_identity=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if captured_identity="$("${wallet_import_hardware_stat_path}" -f $'%d\t%i' \
      "${target}" 2>/dev/null)"; then
    :
  else
    captured_identity="$("${wallet_import_hardware_stat_path}" -c $'%d\t%i' -- \
      "${target}" 2>/dev/null)" || return 1
  fi
  [[ "${captured_identity}" =~ ^[0-9]+$'\t'[0-9]+$ ]] || return 1
  printf -v "${output_variable}" '%s' "${captured_identity}"
}

_cntools_action_wallet_import_hardware_digest() {
  local target="${1:-}" output_variable="${2:-}" captured_digest=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "${wallet_import_hardware_hash_kind:-}" in
    sha256sum)
      captured_digest="$("${wallet_import_hardware_hash_path}" "${target}" \
        2>/dev/null)" || return 1
      captured_digest="${captured_digest%% *}"
      ;;
    shasum)
      captured_digest="$("${wallet_import_hardware_hash_path}" -a 256 \
        "${target}" 2>/dev/null)" || return 1
      captured_digest="${captured_digest%% *}"
      ;;
    *) return 1 ;;
  esac
  [[ "${captured_digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf -v "${output_variable}" '%s' "${captured_digest,,}"
}

_cntools_action_wallet_import_hardware_leaf_digest_capture() {
  local target="${1:-}" leaf="" digest=""

  [[ "${target}" == "${wallet_import_hardware_stage}/"* ]] || return 1
  leaf="${target##*/}"
  [[ -n "${wallet_import_hardware_expected[${leaf}]+set}" ]] || return 1
  _cntools_action_wallet_import_hardware_digest "${target}" digest || return 1
  wallet_import_hardware_leaf_digests["${leaf}"]="${digest}"
}

_cntools_action_wallet_import_hardware_root_authority_validate() {
  local current_identity=""

  _cntools_action_wallet_import_hardware_directory_validate \
    "${wallet_import_hardware_root}" '700,750,755' &&
    _cntools_action_wallet_import_hardware_directory_identity \
      "${wallet_import_hardware_root}" current_identity &&
    [[ "${current_identity}" == "${wallet_import_hardware_root_identity:-}" ]]
}

_cntools_action_wallet_import_hardware_lock_authority_validate() {
  local current_identity=""

  _cntools_action_wallet_import_hardware_directory_validate \
    "${wallet_import_hardware_lock}" 700 &&
    _cntools_action_wallet_import_hardware_directory_identity \
      "${wallet_import_hardware_lock}" current_identity &&
    [[ "${current_identity}" == "${wallet_import_hardware_lock_identity:-}" ]]
}

_cntools_action_wallet_import_hardware_stage_authority_validate() {
  local current_identity=""

  _cntools_action_wallet_import_hardware_directory_validate \
    "${wallet_import_hardware_stage}" 700 &&
    _cntools_action_wallet_import_hardware_directory_identity \
      "${wallet_import_hardware_stage}" current_identity &&
    [[ "${current_identity}" == "${wallet_import_hardware_stage_identity:-}" ]]
}

_cntools_action_wallet_import_hardware_publish_reconcile() {
  local current_identity=""

  [[ "${wallet_import_hardware_publish_attempt:-N}" == Y &&
     -n "${wallet_import_hardware_stage_identity:-}" ]] || return 1
  if [[ ! -e "${wallet_import_hardware_stage}" &&
        ! -L "${wallet_import_hardware_stage}" ]] &&
     _cntools_action_wallet_import_hardware_directory_validate \
       "${wallet_import_hardware_destination}" 700 &&
     _cntools_action_wallet_import_hardware_directory_identity \
       "${wallet_import_hardware_destination}" current_identity &&
     [[ "${current_identity}" == \
        "${wallet_import_hardware_stage_identity}" ]]; then
    wallet_import_hardware_committed=Y
    wallet_import_hardware_stage=""
    trap '_cntools_action_wallet_import_hardware_postcommit_signal' \
      HUP INT TERM
    return 0
  fi
  if _cntools_action_wallet_import_hardware_directory_validate \
       "${wallet_import_hardware_stage}" 700 &&
     _cntools_action_wallet_import_hardware_directory_identity \
       "${wallet_import_hardware_stage}" current_identity &&
     [[ "${current_identity}" == \
        "${wallet_import_hardware_stage_identity}" ]]; then
    wallet_import_hardware_committed=N
    return 1
  fi
  return 70
}

_cntools_action_wallet_import_hardware_cleanup() {
  local cleanup_target="" cleanup_status=0 current_identity=""
  local reconcile_status=0

  if [[ "${wallet_import_hardware_committed:-N}" == Y ]]; then
    trap '_cntools_action_wallet_import_hardware_postcommit_signal' \
      HUP INT TERM
  else
    trap '_cntools_action_wallet_import_hardware_signal' HUP INT TERM
  fi
  if [[ -n "${wallet_import_hardware_stage:-}" &&
        "${wallet_import_hardware_publish_attempt:-N}" == Y ]]; then
    _cntools_action_wallet_import_hardware_publish_reconcile ||
      reconcile_status=$?
    if [[ "${reconcile_status}" == 70 ]]; then
      cleanup_status=1
      wallet_import_hardware_stage=""
    fi
  fi
  if [[ -n "${wallet_import_hardware_stage:-}" ]]; then
    if _cntools_action_wallet_import_hardware_directory_identity \
         "${wallet_import_hardware_stage}" current_identity &&
       [[ "${current_identity}" == \
          "${wallet_import_hardware_stage_identity:-}" ]] &&
       _cntools_action_wallet_import_hardware_directory_validate \
         "${wallet_import_hardware_stage}" 700; then
      for cleanup_target in \
          "${wallet_import_hardware_stage_cleanup_files[@]:-}"; do
        [[ -n "${cleanup_target}" &&
           "${cleanup_target}" == "${wallet_import_hardware_stage}/"* ]] ||
          continue
        if [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
          "${wallet_import_hardware_rm_path}" -f -- "${cleanup_target}" \
            >/dev/null 2>&1 || cleanup_status=1
        fi
      done
      "${wallet_import_hardware_rmdir_path}" -- \
        "${wallet_import_hardware_stage}" >/dev/null 2>&1 || cleanup_status=1
    elif [[ -e "${wallet_import_hardware_stage}" ||
            -L "${wallet_import_hardware_stage}" ]]; then
      cleanup_status=1
    fi
  fi
  for cleanup_target in \
      "${wallet_import_hardware_private_cleanup_files[@]:-}"; do
    [[ -n "${cleanup_target}" &&
       "${cleanup_target}" == "${wallet_import_hardware_private_parent}/"* ]] ||
      continue
    if [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
      "${wallet_import_hardware_rm_path}" -f -- "${cleanup_target}" \
        >/dev/null 2>&1 || cleanup_status=1
    fi
  done
  wallet_import_hardware_stage_cleanup_files=()
  wallet_import_hardware_private_cleanup_files=()
  if [[ "${cleanup_status}" == 0 ]]; then
    wallet_import_hardware_stage=""
    wallet_import_hardware_stage_identity=""
  fi
  if [[ -n "${wallet_import_hardware_lock:-}" &&
        ( -e "${wallet_import_hardware_lock}" ||
          -L "${wallet_import_hardware_lock}" ) ]]; then
    if _cntools_action_wallet_import_hardware_directory_validate \
         "${wallet_import_hardware_lock}" 700 &&
       _cntools_action_wallet_import_hardware_directory_identity \
         "${wallet_import_hardware_lock}" current_identity &&
       [[ "${current_identity}" == \
          "${wallet_import_hardware_lock_identity:-}" ]]; then
      "${wallet_import_hardware_rmdir_path}" -- \
        "${wallet_import_hardware_lock}" >/dev/null 2>&1 || cleanup_status=1
    else
      cleanup_status=1
    fi
  fi
  [[ "${cleanup_status}" != 0 ]] || wallet_import_hardware_lock=""
  return "${cleanup_status}"
}

_cntools_action_wallet_import_hardware_signal() {
  local reconcile_status=1

  if [[ "${wallet_import_hardware_publish_attempt:-N}" == Y ]]; then
    if _cntools_action_wallet_import_hardware_publish_reconcile; then
      _cntools_action_wallet_import_hardware_postcommit_signal
    else
      reconcile_status=$?
      if [[ "${reconcile_status}" == 70 ]]; then
        _cntools_action_wallet_import_hardware_validation_failure
        exit 70
      fi
    fi
  fi
  if [[ "${wallet_import_hardware_committed:-N}" == Y ]]; then
    _cntools_action_wallet_import_hardware_postcommit_signal
  fi
  _cntools_action_wallet_import_hardware_cleanup >/dev/null 2>&1 || true
  _cntools_action_wallet_import_hardware_validation_failure
  exit 70
}

_cntools_action_wallet_import_hardware_postcommit_signal() {
  wallet_import_hardware_committed=Y
  wallet_import_hardware_stage=""
  _cntools_action_wallet_import_hardware_cleanup >/dev/null 2>&1 || true
  _cntools_action_wallet_import_hardware_warning
  exit 0
}

_cntools_action_wallet_import_hardware_defer_signal() {
  wallet_import_hardware_signal_pending=Y
}

_cntools_action_wallet_import_hardware_bounded_command() {
  local output_variable="${1:-}" label="${2:-}" output="" status=0
  shift 2 || return 70

  [[ "${output_variable}" =~ ^wallet_import_hardware_[a-z0-9_]+$ &&
     "${label}" =~ ^[a-z-]+$ && $# -ge 1 ]] || return 70
  output="$("${wallet_import_hardware_mktemp_path}" \
    "${wallet_import_hardware_private_parent}/wallet-import-hardware-${label}.XXXXXXXX")" ||
    return 70
  wallet_import_hardware_private_cleanup_files+=("${output}")
  "${wallet_import_hardware_chmod_path}" 0600 "${output}" || return 70
  (
    ulimit -f 32 >/dev/null 2>&1 || exit 70
    "$@" > "${output}" 2>&1
  ) || status=$?
  if [[ -s "${output}" ]]; then
    _cntools_action_wallet_import_hardware_file_validate "${output}" 16384 ||
      return 70
  elif [[ -e "${output}" || -L "${output}" ]]; then
    _cntools_action_wallet_import_hardware_file_validate "${output}" 16384 ||
      return 70
  else
    return 70
  fi
  [[ "${status}" == 0 ]] || return 1
  output="$(< "${output}")"
  _cntools_action_wallet_import_hardware_terminal_value_valid \
    "${output}" 16384 || return 70
  printf -v "${output_variable}" '%s' "${output}"
  return 0
}

_cntools_action_wallet_import_hardware_semver_split() {
  local value="${1:-}" prefix="${2:-}"
  local core="" suffix="" major="" minor="" patch=""

  [[ "${prefix}" =~ ^[a-z][a-z0-9_]*$ ]] || return 1
  value="${value#v}"
  [[ "${value}" =~ ^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}([-+][0-9A-Za-z.-]{1,64})?$ ]] ||
    return 1
  core="${value%%[-+]*}"
  suffix="${value#"${core}"}"
  IFS=. read -r major minor patch <<< "${core}" || return 1
  printf -v "${prefix}_major" '%s' "$((10#${major}))"
  printf -v "${prefix}_minor" '%s' "$((10#${minor}))"
  printf -v "${prefix}_patch" '%s' "$((10#${patch}))"
  printf -v "${prefix}_suffix" '%s' "${suffix}"
}

_cntools_action_wallet_import_hardware_semver_at_least() {
  local minimum="${1:-}" current="${2:-}"
  local minimum_major=0 minimum_minor=0 minimum_patch=0 minimum_suffix=""
  local current_major=0 current_minor=0 current_patch=0 current_suffix=""

  _cntools_action_wallet_import_hardware_semver_split \
    "${minimum}" minimum || return 1
  _cntools_action_wallet_import_hardware_semver_split \
    "${current}" current || return 1
  (( current_major > minimum_major )) && return 0
  (( current_major < minimum_major )) && return 1
  (( current_minor > minimum_minor )) && return 0
  (( current_minor < minimum_minor )) && return 1
  (( current_patch > minimum_patch )) && return 0
  (( current_patch < minimum_patch )) && return 1
  [[ -z "${minimum_suffix}" && -z "${current_suffix}" ]] && return 0
  [[ -n "${minimum_suffix}" && -z "${current_suffix}" ]] && return 0
  [[ -z "${minimum_suffix}" && -n "${current_suffix}" ]] && return 1
  [[ "${current_suffix}" == "${minimum_suffix}" ]]
}

_cntools_action_wallet_import_hardware_release_minimum() {
  local manifest="${1:-}" implementation="${2:-}"
  local metadata="" owner="" mode="" links="" size="" minimum=""

  [[ "${manifest}" == /* && -f "${manifest}" && ! -L "${manifest}" ]] ||
    return 70
  _cntools_registry_path_has_no_symlinks "${manifest}" || return 70
  _cntools_action_wallet_import_hardware_metadata "${manifest}" metadata ||
    return 70
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 70
  mode="${mode#0}"
  [[ ( "${owner}" == 0 || "${owner}" == "${EUID}" ) &&
     "${mode}" =~ ^[46][04][04]$ && "${links}" == 1 &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 1048576 ]] || return 70
  minimum="$("${wallet_import_hardware_jq_path}" -er \
    --arg implementation "${implementation}" '
      select(
        type == "object" and .schemaVersion == 1 and
        .implementation == $implementation and
        (.tools | type == "object") and
        (.tools["cardano-hw-cli"] | type == "object") and
        (.tools["cardano-hw-cli"].minimumVersion | type == "string" and
          test("^v?[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9}$"))
      ) | .tools["cardano-hw-cli"].minimumVersion
    ' "${manifest}" 2>/dev/null)" || return 70
  printf '%s\n' "${minimum}"
}

_cntools_action_wallet_import_hardware_version_check() {
  local manifest="${1:-}" implementation="${2:-}"
  local minimum="" output="" line="" current="" status=0

  minimum="$(_cntools_action_wallet_import_hardware_release_minimum \
    "${manifest}" "${implementation}")" || return $?
  println ACTION 'cardano-hw-cli version'
  _cntools_action_wallet_import_hardware_bounded_command \
    wallet_import_hardware_command_output version \
    "${wallet_import_hardware_hwcli_path}" version || status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  output="${wallet_import_hardware_command_output}"
  IFS=$'\n' read -r line _ <<< "${output}" || return 70
  [[ "${line}" =~ ^Cardano[[:space:]]HW[[:space:]]CLI[[:space:]]Tool[[:space:]]version[[:space:]](v?[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}([-+][0-9A-Za-z.-]{1,64})?)$ ]] ||
    return 70
  current="${BASH_REMATCH[1]}"
  _cntools_action_wallet_import_hardware_semver_at_least \
    "${minimum}" "${current}" || return 1
  wallet_import_hardware_hwcli_version="${current}"
}

_cntools_action_wallet_import_hardware_device_check() {
  local output="" status=0

  waitToProceed \
    'INFO: please connect and unlock hardware device' \
    $'\n  Ledger - Unlock with pin and open Cardano app' \
    $'\n  Trezor - Make sure trezor bridge is installed' \
    $'\n\nwhen done, press any key to continue'
  println ACTION 'cardano-hw-cli device version'
  _cntools_action_wallet_import_hardware_bounded_command \
    wallet_import_hardware_command_output device-version \
    "${wallet_import_hardware_hwcli_path}" device version || status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  output="${wallet_import_hardware_command_output}"
  [[ "${output}" =~ ^(Ledger|Trezor|Keystone)[[:space:]]app[[:space:]]version[[:space:]][0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$ ]] ||
    return 70
  wallet_import_hardware_device="${BASH_REMATCH[1]}"
}

_cntools_action_wallet_import_hardware_vkey_validate() {
  local target="${1:-}" expected_type="${2:-}"

  _cntools_action_wallet_import_hardware_file_validate "${target}" 16384 ||
    return 1
  "${wallet_import_hardware_jq_path}" -e --arg type "${expected_type}" '
    type == "object" and
    keys == ["cborHex", "description", "type"] and
    .type == $type and
    (.description | type == "string" and length <= 256) and
    (.cborHex | type == "string" and
      test("^5820[0-9A-Fa-f]{64}$"))
  ' "${target}" >/dev/null 2>&1
}

_cntools_action_wallet_import_hardware_hws_validate() {
  local target="${1:-}" expected_type="${2:-}" expected_path="${3:-}"

  _cntools_action_wallet_import_hardware_file_validate "${target}" 16384 ||
    return 1
  "${wallet_import_hardware_jq_path}" -e \
    --arg type "${expected_type}" --arg path "${expected_path}" '
      type == "object" and
      keys == ["cborXPubKeyHex", "description", "path", "type"] and
      .type == $type and .path == $path and
      (.description | type == "string" and length <= 256) and
      (.cborXPubKeyHex | type == "string" and
        test("^5840[0-9A-Fa-f]{128}$"))
    ' "${target}" >/dev/null 2>&1
}

_cntools_action_wallet_import_hardware_pair_validate() {
  local verification="${1:-}" signing="${2:-}"
  local verification_hex="" signing_hex=""

  verification_hex="$("${wallet_import_hardware_jq_path}" -er \
    '.cborHex | ascii_downcase' "${verification}" 2>/dev/null)" || return 1
  signing_hex="$("${wallet_import_hardware_jq_path}" -er \
    '.cborXPubKeyHex | ascii_downcase' "${signing}" 2>/dev/null)" || return 1
  [[ "${verification_hex}" == "5820${signing_hex:4:64}" ]]
}

_cntools_action_wallet_import_hardware_canonicalize() {
  local target="${1:-}" description="${2:-}" temporary="" status=0

  [[ "${target}" == "${wallet_import_hardware_stage}/"* ]] || return 70
  _cntools_action_wallet_import_hardware_terminal_value_valid \
    "${description}" 256 || return 70
  temporary="$("${wallet_import_hardware_mktemp_path}" \
    "${wallet_import_hardware_stage}/.cntools-hardware-json.XXXXXXXX")" ||
    return 70
  wallet_import_hardware_stage_cleanup_files+=("${temporary}")
  "${wallet_import_hardware_chmod_path}" 0600 "${temporary}" || return 70
  "${wallet_import_hardware_jq_path}" -S --arg description "${description}" \
    '.description = $description' "${target}" > "${temporary}" 2>/dev/null ||
    return 70
  _cntools_action_wallet_import_hardware_file_validate "${temporary}" 16384 ||
    return 70
  "${wallet_import_hardware_mv_path}" -f -- "${temporary}" "${target}" \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 && ! -e "${temporary}" && ! -L "${temporary}" ]] ||
    return 70
  _cntools_action_wallet_import_hardware_file_validate "${target}" 16384 ||
    return 70
}

_cntools_action_wallet_import_hardware_partial_outputs_safe() {
  local inventory="" target="" leaf="" visited_count=0
  local -A visited=()

  _cntools_action_wallet_import_hardware_stage_authority_validate || return 1
  inventory="$("${wallet_import_hardware_mktemp_path}" \
    "${wallet_import_hardware_private_parent}/wallet-import-hardware-partial.XXXXXXXX")" ||
    return 1
  wallet_import_hardware_private_cleanup_files+=("${inventory}")
  "${wallet_import_hardware_chmod_path}" 0600 "${inventory}" || return 1
  "${wallet_import_hardware_find_path}" "${wallet_import_hardware_stage}" \
    -mindepth 1 -maxdepth 1 -print0 > "${inventory}" || return 1
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${wallet_import_hardware_stage}/"* ]] || return 1
    leaf="${target#"${wallet_import_hardware_stage}/"}"
    [[ "${leaf}" != */* && -n "${wallet_import_hardware_expected[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 1
    visited["${leaf}"]=Y
    visited_count=$((visited_count + 1))
    _cntools_action_wallet_import_hardware_file_validate "${target}" 16384 ||
      return 1
  done < "${inventory}"
  (( visited_count <= ${#wallet_import_hardware_expected[@]} ))
}

_cntools_action_wallet_import_hardware_export() {
  local index=0 status=0 target=""
  local -a command=("${wallet_import_hardware_hwcli_path}" address key-gen)

  for target in "${wallet_import_hardware_paths[@]}"; do
    command+=(--path "${target}")
  done
  for target in "${wallet_import_hardware_verification_files[@]}"; do
    command+=(--verification-key-file "${target}")
  done
  for target in "${wallet_import_hardware_signing_files[@]}"; do
    command+=(--hw-signing-file "${target}")
  done
  println ACTION 'cardano-hw-cli wallet-import-hardware key export'
  "${command[@]}" >/dev/null 2>&1 || status=$?
  if [[ "${status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_partial_outputs_safe || return 70
    return 1
  fi
  _cntools_action_wallet_import_hardware_stage_authority_validate || return 70
  for ((index=0; index<${#wallet_import_hardware_paths[@]}; index++)); do
    "${wallet_import_hardware_chmod_path}" 0600 \
      "${wallet_import_hardware_verification_files[index]}" \
      "${wallet_import_hardware_signing_files[index]}" \
      >/dev/null 2>&1 || return 70
    _cntools_action_wallet_import_hardware_vkey_validate \
      "${wallet_import_hardware_verification_files[index]}" \
      "${wallet_import_hardware_verification_types[index]}" || return 70
    _cntools_action_wallet_import_hardware_hws_validate \
      "${wallet_import_hardware_signing_files[index]}" \
      "${wallet_import_hardware_signing_types[index]}" \
      "${wallet_import_hardware_paths[index]}" || return 70
    _cntools_action_wallet_import_hardware_pair_validate \
      "${wallet_import_hardware_verification_files[index]}" \
      "${wallet_import_hardware_signing_files[index]}" || return 70
    _cntools_action_wallet_import_hardware_canonicalize \
      "${wallet_import_hardware_verification_files[index]}" \
      "${wallet_import_hardware_verification_descriptions[index]}" ||
      return 70
    _cntools_action_wallet_import_hardware_canonicalize \
      "${wallet_import_hardware_signing_files[index]}" \
      "${wallet_import_hardware_signing_descriptions[index]}" || return 70
    _cntools_action_wallet_import_hardware_vkey_validate \
      "${wallet_import_hardware_verification_files[index]}" \
      "${wallet_import_hardware_verification_types[index]}" || return 70
    _cntools_action_wallet_import_hardware_hws_validate \
      "${wallet_import_hardware_signing_files[index]}" \
      "${wallet_import_hardware_signing_types[index]}" \
      "${wallet_import_hardware_paths[index]}" || return 70
    _cntools_action_wallet_import_hardware_pair_validate \
      "${wallet_import_hardware_verification_files[index]}" \
      "${wallet_import_hardware_signing_files[index]}" || return 70
    _cntools_action_wallet_import_hardware_leaf_digest_capture \
      "${wallet_import_hardware_verification_files[index]}" || return 70
    _cntools_action_wallet_import_hardware_leaf_digest_capture \
      "${wallet_import_hardware_signing_files[index]}" || return 70
  done
}

_cntools_action_wallet_import_hardware_copy_drep() {
  local source_vkey="${1:-}" source_hws="${2:-}"
  local target_vkey="${3:-}" target_hws="${4:-}" expected_path="${5:-}"

  "${wallet_import_hardware_cp_path}" -- "${source_vkey}" "${target_vkey}" \
    >/dev/null 2>&1 || return 70
  "${wallet_import_hardware_cp_path}" -- "${source_hws}" "${target_hws}" \
    >/dev/null 2>&1 || return 70
  "${wallet_import_hardware_chmod_path}" 0600 \
    "${target_vkey}" "${target_hws}" >/dev/null 2>&1 || return 70
  _cntools_action_wallet_import_hardware_canonicalize "${target_vkey}" \
    'MultiSig Delegate Representative Hardware Verification Key' || return 70
  _cntools_action_wallet_import_hardware_canonicalize "${target_hws}" \
    'MultiSig Delegate Representative Hardware Signing File' || return 70
  _cntools_action_wallet_import_hardware_vkey_validate "${target_vkey}" \
    DRepVerificationKey_ed25519 || return 70
  _cntools_action_wallet_import_hardware_hws_validate "${target_hws}" \
    DRepHWSigningFile_ed25519 "${expected_path}" || return 70
  _cntools_action_wallet_import_hardware_pair_validate \
    "${target_vkey}" "${target_hws}" || return 70
  _cntools_action_wallet_import_hardware_leaf_digest_capture \
    "${target_vkey}" || return 70
  _cntools_action_wallet_import_hardware_leaf_digest_capture \
    "${target_hws}" || return 70
}

_cntools_action_wallet_import_hardware_text_validate() {
  local target="${1:-}" kind="${2:-}" value=""

  _cntools_action_wallet_import_hardware_file_validate "${target}" 1024 ||
    return 1
  value="$(< "${target}")"
  _cntools_action_wallet_import_hardware_terminal_value_valid \
    "${value}" 512 || return 1
  case "${kind}" in
    base|payment)
      if [[ "${wallet_import_hardware_network_args[0]:-}" == --mainnet ]]; then
        [[ "${value}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]]
      else
        [[ "${wallet_import_hardware_network_args[0]:-}" == --testnet-magic &&
           "${value}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]]
      fi
      ;;
    reward)
      if [[ "${wallet_import_hardware_network_args[0]:-}" == --mainnet ]]; then
        [[ "${value}" =~ ^stake1[023456789ac-hj-np-z]{20,200}$ ]]
      else
        [[ "${wallet_import_hardware_network_args[0]:-}" == --testnet-magic &&
           "${value}" =~ ^stake_test1[023456789ac-hj-np-z]{20,200}$ ]]
      fi
      ;;
    credential) [[ "${value}" =~ ^[0-9A-Fa-f]{56}$ ]] ;;
    *) return 1 ;;
  esac
}

_cntools_action_wallet_import_hardware_derive() {
  local output="${1:-}" kind="${2:-}" status=0
  shift 2 || return 70

  [[ "${output}" == "${wallet_import_hardware_stage}/"* ]] || return 70
  println ACTION "cardano-cli wallet-import-hardware ${kind} derivation"
  "${wallet_import_hardware_ccli_path}" "$@" --out-file "${output}" \
    >/dev/null 2>&1 || status=$?
  if [[ "${status}" != 0 ]]; then
    if [[ -e "${output}" || -L "${output}" ]]; then
      _cntools_action_wallet_import_hardware_file_validate "${output}" 1024 ||
        return 70
    fi
    return 1
  fi
  "${wallet_import_hardware_chmod_path}" 0600 "${output}" \
    >/dev/null 2>&1 || return 70
  _cntools_action_wallet_import_hardware_text_validate "${output}" "${kind}" ||
    return 70
  _cntools_action_wallet_import_hardware_leaf_digest_capture "${output}" ||
    return 70
}

_cntools_action_wallet_import_hardware_inventory_validate() {
  local inventory="" target="" leaf="" digest=""
  local expected_count=0 visited_count=0
  local -A visited=()

  _cntools_action_wallet_import_hardware_stage_authority_validate || return 1
  expected_count="${#wallet_import_hardware_expected[@]}"
  if [[ "${wallet_import_hardware_governance}" == Y ]]; then
    (( expected_count == 24 )) || return 1
  else
    (( expected_count == 16 )) || return 1
  fi
  (( ${#wallet_import_hardware_leaf_digests[@]} == expected_count )) ||
    return 1
  inventory="$("${wallet_import_hardware_mktemp_path}" \
    "${wallet_import_hardware_private_parent}/wallet-import-hardware-inventory.XXXXXXXX")" ||
    return 1
  wallet_import_hardware_private_cleanup_files+=("${inventory}")
  "${wallet_import_hardware_chmod_path}" 0600 "${inventory}" || return 1
  "${wallet_import_hardware_find_path}" "${wallet_import_hardware_stage}" \
    -mindepth 1 -maxdepth 1 -print0 > "${inventory}" || return 1
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${wallet_import_hardware_stage}/"* ]] || return 1
    leaf="${target#"${wallet_import_hardware_stage}/"}"
    [[ "${leaf}" != */* && -n "${wallet_import_hardware_expected[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 1
    visited["${leaf}"]=Y
    visited_count=$((visited_count + 1))
  done < "${inventory}"
  (( visited_count == expected_count )) || return 1
  for leaf in "${!wallet_import_hardware_expected[@]}"; do
    [[ -n "${visited[${leaf}]+set}" ]] || return 1
    _cntools_action_wallet_import_hardware_file_validate \
      "${wallet_import_hardware_stage}/${leaf}" 16384 || return 1
    _cntools_action_wallet_import_hardware_digest \
      "${wallet_import_hardware_stage}/${leaf}" digest || return 1
    [[ "${digest}" == "${wallet_import_hardware_leaf_digests[${leaf}]:-}" ]] ||
      return 1
  done
}

_cntools_action_wallet_import_hardware_prompt_name() {
  local output_variable="${1:-}" prompted="" prompt_status=0

  [[ "${output_variable}" == wallet_import_hardware_name ]] || return 70
  getAnswerAnyCust prompted \
    'Name of wallet (ASCII letters, numbers, underscore and hyphen only)' ||
    prompt_status=$?
  [[ "${prompt_status}" == 0 ]] || {
    [[ "${prompt_status}" == 1 ]] && return 1
    return 70
  }
  _cntools_action_wallet_import_hardware_name_valid "${prompted}" || {
    println ERROR 'ERROR: Invalid wallet name, please retry!'
    waitToProceed
    return 1
  }
  printf -v "${output_variable}" '%s' "${prompted}"
}

_cntools_action_wallet_import_hardware_prompt_index() {
  local output_variable="${1:-}" prompt="${2:-}" prompted=""
  local prompt_status=0

  [[ "${output_variable}" == wallet_import_hardware_account ||
     "${output_variable}" == wallet_import_hardware_key ]] || return 70
  getAnswerAnyCust prompted "${prompt}" || prompt_status=$?
  [[ "${prompt_status}" == 0 ]] || {
    [[ "${prompt_status}" == 1 ]] && return 1
    return 70
  }
  prompted="${prompted:-0}"
  _cntools_action_wallet_import_hardware_index_valid "${prompted}" || {
    println ERROR 'ERROR: Invalid derivation index, please retry!'
    waitToProceed
    return 1
  }
  printf -v "${output_variable}" '%s' "${prompted}"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local context_mode="" context_network="" context_home=""
  local context_implementation="" network_magic="" filename=""
  local action_status=0 cleanup_status=0 resolve_status=0 export_status=0
  local derive_status=0 reconcile_status=0 choice_status=0
  local wallet_import_hardware_root="" wallet_import_hardware_name=""
  local wallet_import_hardware_account="" wallet_import_hardware_key=""
  local wallet_import_hardware_destination="" wallet_import_hardware_stage=""
  local wallet_import_hardware_lock="" wallet_import_hardware_private_parent=""
  local wallet_import_hardware_root_identity=""
  local wallet_import_hardware_lock_identity=""
  local wallet_import_hardware_stage_identity=""
  local wallet_import_hardware_publish_attempt=N
  local wallet_import_hardware_committed=N
  local wallet_import_hardware_signal_pending=N
  local wallet_import_hardware_governance=N
  local wallet_import_hardware_jq_path=""
  local wallet_import_hardware_mktemp_path=""
  local wallet_import_hardware_mkdir_path=""
  local wallet_import_hardware_chmod_path=""
  local wallet_import_hardware_rm_path=""
  local wallet_import_hardware_rmdir_path=""
  local wallet_import_hardware_mv_path=""
  local wallet_import_hardware_find_path=""
  local wallet_import_hardware_stat_path=""
  local wallet_import_hardware_cp_path=""
  local wallet_import_hardware_hash_path=""
  local wallet_import_hardware_hash_kind=""
  local wallet_import_hardware_hwcli_path=""
  local wallet_import_hardware_ccli_path=""
  local wallet_import_hardware_command_output=""
  # Populated indirectly by the bounded-command helper's validated variable name.
  # shellcheck disable=SC2034
  local wallet_import_hardware_hwcli_version=""
  # shellcheck disable=SC2034
  local wallet_import_hardware_device=""
  local derivation_file="" payment_vkey="" payment_hws=""
  local stake_vkey="" stake_hws="" drep_vkey="" drep_hws=""
  local cc_cold_vkey="" cc_cold_hws="" cc_hot_vkey="" cc_hot_hws=""
  local ms_payment_vkey="" ms_payment_hws=""
  local ms_stake_vkey="" ms_stake_hws="" ms_drep_vkey="" ms_drep_hws=""
  local base_file="" payment_file="" reward_file=""
  local payment_cred="" stake_cred="" ms_payment_cred="" ms_stake_cred=""
  local base_addr="" pay_addr="" leaf=""
  local -a wallet_import_hardware_network_args=()
  local -a wallet_import_hardware_paths=()
  local -a wallet_import_hardware_verification_files=()
  local -a wallet_import_hardware_signing_files=()
  local -a wallet_import_hardware_verification_types=()
  local -a wallet_import_hardware_signing_types=()
  local -a wallet_import_hardware_verification_descriptions=()
  local -a wallet_import_hardware_signing_descriptions=()
  local -a wallet_import_hardware_stage_cleanup_files=()
  local -a wallet_import_hardware_private_cleanup_files=()
  local -A wallet_import_hardware_expected=()
  local -A wallet_import_hardware_leaf_digests=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F cntools_context_has >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1 ||
     ! builtin declare -F select_opt >/dev/null 2>&1 ||
     ! builtin declare -F printWalletInfo >/dev/null 2>&1; then
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  context_home="$(cntools_context_get "${context_file}" nodeHome)" || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  context_implementation="$(cntools_context_get \
    "${context_file}" nodeImplementation)" || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  for filename in jq mktemp mkdir chmod rm rmdir mv find stat cp; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq wallet_import_hardware_jq_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp wallet_import_hardware_mktemp_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir wallet_import_hardware_mkdir_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod wallet_import_hardware_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_import_hardware_rm_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir wallet_import_hardware_rmdir_path || action_status=70 ;;
      mv) _cntools_registry_tool_path mv wallet_import_hardware_mv_path || action_status=70 ;;
      find) _cntools_registry_tool_path find wallet_import_hardware_find_path || action_status=70 ;;
      stat) _cntools_registry_tool_path stat wallet_import_hardware_stat_path || action_status=70 ;;
      cp) _cntools_registry_tool_path cp wallet_import_hardware_cp_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  if _cntools_registry_tool_path sha256sum \
      wallet_import_hardware_hash_path; then
    wallet_import_hardware_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum \
      wallet_import_hardware_hash_path; then
    wallet_import_hardware_hash_kind=shasum
  else
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi
  wallet_import_hardware_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate \
    "${wallet_import_hardware_private_parent}" || {
      _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  [[ "${WALLET_FOLDER}" == /* ]] || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  _cntools_action_wallet_import_hardware_directory_validate \
    "${WALLET_FOLDER}" '700,750,755' || {
      _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  wallet_import_hardware_root="$(cd -P -- "${WALLET_FOLDER}" && pwd -P)" || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  [[ "${wallet_import_hardware_root}" == "${WALLET_FOLDER}" &&
     "${wallet_import_hardware_root}" != \
       "${wallet_import_hardware_private_parent}" &&
     "${wallet_import_hardware_root}" != \
       "${wallet_import_hardware_private_parent}/"* &&
     "${wallet_import_hardware_private_parent}" != \
       "${wallet_import_hardware_root}/"* ]] || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  _cntools_action_wallet_import_hardware_directory_identity \
    "${wallet_import_hardware_root}" wallet_import_hardware_root_identity || {
      _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  for filename in "${WALLET_DERIVATION_PATH_FILENAME}" \
      "${WALLET_HW_PAY_SK_FILENAME}" "${WALLET_PAY_VK_FILENAME}" \
      "${WALLET_HW_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}" \
      "${WALLET_GOV_HW_DREP_SK_FILENAME}" "${WALLET_GOV_DREP_VK_FILENAME}" \
      "${WALLET_GOV_HW_CC_COLD_SK_FILENAME}" \
      "${WALLET_GOV_CC_COLD_VK_FILENAME}" \
      "${WALLET_GOV_HW_CC_HOT_SK_FILENAME}" \
      "${WALLET_GOV_CC_HOT_VK_FILENAME}" \
      "${WALLET_BASE_ADDR_FILENAME}" "${WALLET_PAY_ADDR_FILENAME}" \
      "${WALLET_STAKE_ADDR_FILENAME}" "${WALLET_PAY_CRED_FILENAME}" \
      "${WALLET_STAKE_CRED_FILENAME}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
      _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  done
  [[ "${WALLET_MULTISIG_PREFIX}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }
  case "${NETWORK_IDENTIFIER}" in
    --mainnet) wallet_import_hardware_network_args=(--mainnet) ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 ]] || {
        _cntools_action_wallet_import_hardware_validation_failure; return 70; }
      wallet_import_hardware_network_args=(--testnet-magic "${network_magic}")
      ;;
    *) _cntools_action_wallet_import_hardware_validation_failure; return 70 ;;
  esac
  if [[ "${context_network}" == mainnet &&
        "${wallet_import_hardware_network_args[0]}" != --mainnet ]] ||
     [[ "${context_network}" != mainnet &&
        "${wallet_import_hardware_network_args[0]}" != --testnet-magic ]]; then
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi
  _cntools_action_wallet_import_hardware_tool_resolve \
    "${CCLI:-}" wallet_import_hardware_ccli_path || resolve_status=$?
  [[ "${resolve_status}" == 0 ]] || {
    _cntools_action_wallet_import_hardware_validation_failure; return 70; }

  umask 077
  trap '_cntools_action_wallet_import_hardware_cleanup' EXIT
  trap '_cntools_action_wallet_import_hardware_signal' HUP INT TERM
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> WALLET >> IMPORT >> HARDWARE WALLET'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  println DEBUG 'NOTE: Make sure your hardware wallet is supported by Cardano and cardano-hw-cli.'
  echo

  resolve_status=0
  _cntools_action_wallet_import_hardware_tool_resolve cardano-hw-cli \
    wallet_import_hardware_hwcli_path || resolve_status=$?
  if [[ "${resolve_status}" == 1 ]]; then
    trap - EXIT HUP INT TERM
    println ERROR 'ERROR: cardano-hw-cli not found or not executable.'
    println ERROR 'Install hardware-wallet support with guild-deploy.sh -s w.'
    waitToProceed
    return 0
  elif [[ "${resolve_status}" != 0 ]]; then
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  action_status=0
  _cntools_action_wallet_import_hardware_version_check \
    "${context_home}/files/cnode-release.json" \
    "${context_implementation}" || action_status=$?
  if [[ "${action_status}" == 1 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    println ERROR 'ERROR: cardano-hw-cli is unavailable, incompatible, or below the required version.'
    waitToProceed
    return 0
  elif [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  choice_status=0
  _cntools_action_wallet_import_hardware_prompt_name \
    wallet_import_hardware_name || choice_status=$?
  if [[ "${choice_status}" == 1 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    return 0
  elif [[ "${choice_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi
  println DEBUG 'Enter a custom account index to derive keys for (enter for default)'
  choice_status=0
  _cntools_action_wallet_import_hardware_prompt_index \
    wallet_import_hardware_account 'Account (default: 0)' || choice_status=$?
  if [[ "${choice_status}" == 1 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    return 0
  elif [[ "${choice_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi
  println DEBUG $'\nEnter a custom key index to derive keys for (enter for default)'
  choice_status=0
  _cntools_action_wallet_import_hardware_prompt_index \
    wallet_import_hardware_key 'Key index (default: 0)' || choice_status=$?
  if [[ "${choice_status}" == 1 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    return 0
  elif [[ "${choice_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  wallet_import_hardware_destination="${wallet_import_hardware_root}/${wallet_import_hardware_name}"
  wallet_import_hardware_lock="${wallet_import_hardware_root}/.${wallet_import_hardware_name}.cntools-wallet-import-hardware.lock"
  if [[ -e "${wallet_import_hardware_destination}" ||
        -L "${wallet_import_hardware_destination}" ]]; then
    println "WARN: A wallet ${wallet_import_hardware_name} already exists"
    println '      Choose another name or delete the existing one'
    waitToProceed
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    return 0
  fi
  _cntools_action_wallet_import_hardware_root_authority_validate || {
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  }
  trap '_cntools_action_wallet_import_hardware_defer_signal' HUP INT TERM
  if ! "${wallet_import_hardware_mkdir_path}" -m 0700 -- \
      "${wallet_import_hardware_lock}" >/dev/null 2>&1; then
    trap '_cntools_action_wallet_import_hardware_signal' HUP INT TERM
    if [[ "${wallet_import_hardware_signal_pending}" == Y ]]; then
      _cntools_action_wallet_import_hardware_signal
    fi
    println ERROR 'ERROR: hardware wallet import is already in progress, please retry!'
    waitToProceed
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    return 0
  fi
  _cntools_action_wallet_import_hardware_directory_validate \
    "${wallet_import_hardware_lock}" 700 || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_directory_identity \
      "${wallet_import_hardware_lock}" \
      wallet_import_hardware_lock_identity || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_root_authority_validate ||
    action_status=70
  trap '_cntools_action_wallet_import_hardware_signal' HUP INT TERM
  [[ "${wallet_import_hardware_signal_pending}" != Y ]] ||
    _cntools_action_wallet_import_hardware_signal
  [[ ! -e "${wallet_import_hardware_destination}" &&
     ! -L "${wallet_import_hardware_destination}" ]] || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    wallet_import_hardware_stage="$("${wallet_import_hardware_mktemp_path}" -d \
      "${wallet_import_hardware_root}/.${wallet_import_hardware_name}.cntools-wallet-import-hardware.stage.XXXXXXXX")" ||
      action_status=70
  fi
  [[ "${action_status}" != 0 ]] ||
    "${wallet_import_hardware_chmod_path}" 0700 \
      "${wallet_import_hardware_stage}" || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_directory_validate \
      "${wallet_import_hardware_stage}" 700 || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_directory_identity \
      "${wallet_import_hardware_stage}" \
      wallet_import_hardware_stage_identity || action_status=70
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  derivation_file="${wallet_import_hardware_stage}/${WALLET_DERIVATION_PATH_FILENAME}"
  payment_vkey="${wallet_import_hardware_stage}/${WALLET_PAY_VK_FILENAME}"
  payment_hws="${wallet_import_hardware_stage}/${WALLET_HW_PAY_SK_FILENAME}"
  stake_vkey="${wallet_import_hardware_stage}/${WALLET_STAKE_VK_FILENAME}"
  stake_hws="${wallet_import_hardware_stage}/${WALLET_HW_STAKE_SK_FILENAME}"
  drep_vkey="${wallet_import_hardware_stage}/${WALLET_GOV_DREP_VK_FILENAME}"
  drep_hws="${wallet_import_hardware_stage}/${WALLET_GOV_HW_DREP_SK_FILENAME}"
  cc_cold_vkey="${wallet_import_hardware_stage}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
  cc_cold_hws="${wallet_import_hardware_stage}/${WALLET_GOV_HW_CC_COLD_SK_FILENAME}"
  cc_hot_vkey="${wallet_import_hardware_stage}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
  cc_hot_hws="${wallet_import_hardware_stage}/${WALLET_GOV_HW_CC_HOT_SK_FILENAME}"
  ms_payment_vkey="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  ms_payment_hws="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_SK_FILENAME}"
  ms_stake_vkey="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  ms_stake_hws="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_SK_FILENAME}"
  ms_drep_vkey="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
  ms_drep_hws="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_HW_DREP_SK_FILENAME}"
  base_file="${wallet_import_hardware_stage}/${WALLET_BASE_ADDR_FILENAME}"
  payment_file="${wallet_import_hardware_stage}/${WALLET_PAY_ADDR_FILENAME}"
  reward_file="${wallet_import_hardware_stage}/${WALLET_STAKE_ADDR_FILENAME}"
  payment_cred="${wallet_import_hardware_stage}/${WALLET_PAY_CRED_FILENAME}"
  stake_cred="${wallet_import_hardware_stage}/${WALLET_STAKE_CRED_FILENAME}"
  ms_payment_cred="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
  ms_stake_cred="${wallet_import_hardware_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"

  println 'Include governance (drep & committee) keys (only Ledger supported)?'
  if select_opt '[n] No' '[y] Yes'; then
    wallet_import_hardware_governance=N
  else
    choice_status=$?
    [[ "${choice_status}" == 1 ]] || {
      _cntools_action_wallet_import_hardware_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_import_hardware_validation_failure
      return 70
    }
    wallet_import_hardware_governance=Y
  fi

  for leaf in "${WALLET_DERIVATION_PATH_FILENAME}" \
      "${WALLET_HW_PAY_SK_FILENAME}" "${WALLET_PAY_VK_FILENAME}" \
      "${WALLET_HW_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}" \
      "${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_SK_FILENAME}" \
      "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}" \
      "${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_SK_FILENAME}" \
      "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}" \
      "${WALLET_BASE_ADDR_FILENAME}" "${WALLET_PAY_ADDR_FILENAME}" \
      "${WALLET_STAKE_ADDR_FILENAME}" "${WALLET_PAY_CRED_FILENAME}" \
      "${WALLET_STAKE_CRED_FILENAME}" \
      "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}" \
      "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"; do
    [[ -z "${wallet_import_hardware_expected[${leaf}]+set}" ]] || {
      _cntools_action_wallet_import_hardware_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_import_hardware_validation_failure
      return 70
    }
    wallet_import_hardware_expected["${leaf}"]=Y
  done
  if [[ "${wallet_import_hardware_governance}" == Y ]]; then
    for leaf in "${WALLET_GOV_HW_DREP_SK_FILENAME}" \
        "${WALLET_GOV_DREP_VK_FILENAME}" \
        "${WALLET_GOV_HW_CC_COLD_SK_FILENAME}" \
        "${WALLET_GOV_CC_COLD_VK_FILENAME}" \
        "${WALLET_GOV_HW_CC_HOT_SK_FILENAME}" \
        "${WALLET_GOV_CC_HOT_VK_FILENAME}" \
        "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_HW_DREP_SK_FILENAME}" \
        "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"; do
      [[ -z "${wallet_import_hardware_expected[${leaf}]+set}" ]] || {
        _cntools_action_wallet_import_hardware_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_import_hardware_validation_failure
        return 70
      }
      wallet_import_hardware_expected["${leaf}"]=Y
    done
  fi
  for leaf in "${!wallet_import_hardware_expected[@]}"; do
    wallet_import_hardware_stage_cleanup_files+=(
      "${wallet_import_hardware_stage}/${leaf}")
  done

  printf '1852H/1815H/%sH/x/%s\n' \
    "${wallet_import_hardware_account}" "${wallet_import_hardware_key}" \
    > "${derivation_file}" || action_status=70
  "${wallet_import_hardware_chmod_path}" 0600 "${derivation_file}" ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_file_validate \
      "${derivation_file}" 128 || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_leaf_digest_capture \
      "${derivation_file}" || action_status=70
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  action_status=0
  _cntools_action_wallet_import_hardware_device_check || action_status=$?
  if [[ "${action_status}" == 1 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    println ERROR 'ERROR: unable to access an unlocked supported hardware device.'
    waitToProceed
    return 0
  elif [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  wallet_import_hardware_paths=(
    "1852H/1815H/${wallet_import_hardware_account}H/0/${wallet_import_hardware_key}"
    "1852H/1815H/${wallet_import_hardware_account}H/2/${wallet_import_hardware_key}"
  )
  wallet_import_hardware_verification_files=("${payment_vkey}" "${stake_vkey}")
  wallet_import_hardware_signing_files=("${payment_hws}" "${stake_hws}")
  wallet_import_hardware_verification_types=(
    PaymentVerificationKeyShelley_ed25519 StakeVerificationKeyShelley_ed25519)
  wallet_import_hardware_signing_types=(
    PaymentHWSigningFileShelley_ed25519 StakeHWSigningFileShelley_ed25519)
  wallet_import_hardware_verification_descriptions=(
    'Payment Hardware Verification Key' 'Stake Hardware Verification Key')
  wallet_import_hardware_signing_descriptions=(
    'Payment Hardware Signing File' 'Stake Hardware Signing File')
  if [[ "${wallet_import_hardware_governance}" == Y ]]; then
    wallet_import_hardware_paths+=(
      "1852H/1815H/${wallet_import_hardware_account}H/3/${wallet_import_hardware_key}"
      "1852H/1815H/${wallet_import_hardware_account}H/4/${wallet_import_hardware_key}"
      "1852H/1815H/${wallet_import_hardware_account}H/5/${wallet_import_hardware_key}"
    )
    wallet_import_hardware_verification_files+=(
      "${drep_vkey}" "${cc_cold_vkey}" "${cc_hot_vkey}")
    wallet_import_hardware_signing_files+=(
      "${drep_hws}" "${cc_cold_hws}" "${cc_hot_hws}")
    wallet_import_hardware_verification_types+=(
      DRepVerificationKey_ed25519 CommitteeColdVerificationKey_ed25519
      CommitteeHotVerificationKey_ed25519)
    wallet_import_hardware_signing_types+=(
      DRepHWSigningFile_ed25519 CommitteeColdHWSigningFile_ed25519
      CommitteeHotHWSigningFile_ed25519)
    wallet_import_hardware_verification_descriptions+=(
      'Delegate Representative Hardware Verification Key'
      'Constitutional Committee Cold Hardware Verification Key'
      'Constitutional Committee Hot Hardware Verification Key')
    wallet_import_hardware_signing_descriptions+=(
      'Delegate Representative Hardware Signing File'
      'Constitutional Committee Cold Hardware Signing File'
      'Constitutional Committee Hot Hardware Signing File')
  fi
  wallet_import_hardware_paths+=(
    "1854H/1815H/${wallet_import_hardware_account}H/0/${wallet_import_hardware_key}"
    "1854H/1815H/${wallet_import_hardware_account}H/2/${wallet_import_hardware_key}"
  )
  wallet_import_hardware_verification_files+=("${ms_payment_vkey}" "${ms_stake_vkey}")
  wallet_import_hardware_signing_files+=("${ms_payment_hws}" "${ms_stake_hws}")
  wallet_import_hardware_verification_types+=(
    PaymentVerificationKeyShelley_ed25519 StakeVerificationKeyShelley_ed25519)
  wallet_import_hardware_signing_types+=(
    PaymentHWSigningFileShelley_ed25519 StakeHWSigningFileShelley_ed25519)
  wallet_import_hardware_verification_descriptions+=(
    'MultiSig Payment Hardware Verification Key'
    'MultiSig Stake Hardware Verification Key')
  wallet_import_hardware_signing_descriptions+=(
    'MultiSig Payment Hardware Signing File'
    'MultiSig Stake Hardware Signing File')

  export_status=0
  _cntools_action_wallet_import_hardware_export || export_status=$?
  if [[ "${export_status}" == 1 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    println ERROR 'ERROR: failure during hardware wallet key extraction!'
    waitToProceed
    return 0
  elif [[ "${export_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi
  if [[ "${wallet_import_hardware_governance}" == Y ]]; then
    _cntools_action_wallet_import_hardware_copy_drep \
      "${drep_vkey}" "${drep_hws}" "${ms_drep_vkey}" "${ms_drep_hws}" \
      "1852H/1815H/${wallet_import_hardware_account}H/3/${wallet_import_hardware_key}" ||
      action_status=70
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  _cntools_action_wallet_import_hardware_derive "${base_file}" base \
    address build --payment-verification-key-file "${payment_vkey}" \
    --stake-verification-key-file "${stake_vkey}" \
    "${wallet_import_hardware_network_args[@]}" || derive_status=$?
  [[ "${derive_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_derive "${payment_file}" payment \
      address build --payment-verification-key-file "${payment_vkey}" \
      "${wallet_import_hardware_network_args[@]}" || derive_status=$?
  [[ "${derive_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_derive "${reward_file}" reward \
      latest stake-address build --stake-verification-key-file "${stake_vkey}" \
      "${wallet_import_hardware_network_args[@]}" || derive_status=$?
  [[ "${derive_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_derive "${payment_cred}" credential \
      address key-hash --payment-verification-key-file "${payment_vkey}" ||
    derive_status=$?
  [[ "${derive_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_derive "${stake_cred}" credential \
      latest stake-address key-hash --stake-verification-key-file "${stake_vkey}" ||
    derive_status=$?
  [[ "${derive_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_derive \
      "${ms_payment_cred}" credential address key-hash \
      --payment-verification-key-file "${ms_payment_vkey}" || derive_status=$?
  [[ "${derive_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_derive \
      "${ms_stake_cred}" credential latest stake-address key-hash \
      --stake-verification-key-file "${ms_stake_vkey}" || derive_status=$?
  if [[ "${derive_status}" == 1 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    println ERROR 'ERROR: failure while deriving hardware wallet addresses.'
    waitToProceed
    return 0
  elif [[ "${derive_status}" != 0 ]]; then
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi

  _cntools_action_wallet_import_hardware_inventory_validate || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_root_authority_validate ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_lock_authority_validate ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_import_hardware_stage_authority_validate ||
    action_status=70
  [[ "${action_status}" != 0 ||
     ( ! -e "${wallet_import_hardware_destination}" &&
       ! -L "${wallet_import_hardware_destination}" ) ]] || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    base_addr="$(< "${base_file}")"
    pay_addr="$(< "${payment_file}")"
    _cntools_action_wallet_import_hardware_terminal_value_valid \
      "${base_addr}" 512 || action_status=70
    _cntools_action_wallet_import_hardware_terminal_value_valid \
      "${pay_addr}" 512 || action_status=70
  fi
  if [[ "${action_status}" == 0 ]]; then
    wallet_import_hardware_publish_attempt=Y
    trap '_cntools_action_wallet_import_hardware_signal' HUP INT TERM
    "${wallet_import_hardware_mv_path}" -n -- \
      "${wallet_import_hardware_stage}" \
      "${wallet_import_hardware_destination}" >/dev/null 2>&1 ||
      action_status=$?
    _cntools_action_wallet_import_hardware_publish_reconcile ||
      reconcile_status=$?
    if [[ "${wallet_import_hardware_committed}" == Y ]]; then
      action_status=0
    else
      action_status=70
    fi
  fi
  if [[ "${action_status}" != 0 ]]; then
    if [[ "${wallet_import_hardware_committed}" == Y ]]; then
      wallet_import_hardware_stage=""
      _cntools_action_wallet_import_hardware_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_import_hardware_warning
      waitToProceed
      return 0
    fi
    _cntools_action_wallet_import_hardware_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_import_hardware_validation_failure
    return 70
  fi
  if ! _cntools_action_wallet_import_hardware_cleanup; then
    cleanup_status=1
  fi
  trap - EXIT

  println "HW Wallet Imported : ${FG_GREEN}${wallet_import_hardware_name}${NC}"
  println "Address            : ${FG_LGRAY}${base_addr}${NC}"
  println "Payment Address    : ${FG_LGRAY}${pay_addr}${NC}"
  echo
  printWalletInfo
  [[ "${cleanup_status}" == 0 ]] ||
    _cntools_action_wallet_import_hardware_warning
  waitToProceed
  trap - HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
