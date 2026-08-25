#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154
# Stage 4 compatibility action for hardened MultiSig key derivation.
# Sourcing defines functions only. The dispatcher supplies an authenticated
# context plus the inherited CNTools prompt, display, selection, and wait APIs.

_cntools_action_advanced_multisig_derive_keys_validation_failure() {
  builtin printf '%s\n' \
    'CNTools MultiSig key derivation action failed validation.' >&2
  return 70
}

_cntools_action_advanced_multisig_derive_keys_warning() {
  builtin printf '%s\n' \
    'WARNING: MultiSig keys were derived, but administrative cleanup needs attention.' >&2
}

_cntools_action_advanced_multisig_derive_keys_xtrace_disable() {
  [[ "${multisig_derive_xtrace_restore:-N}" != Y ]] || return 0
  if [[ "$-" == *x* ]]; then
    builtin set +x
    multisig_derive_xtrace_restore=Y
  fi
}

_cntools_action_advanced_multisig_derive_keys_xtrace_restore() {
  if [[ "${multisig_derive_xtrace_restore:-N}" == Y ]]; then
    multisig_derive_xtrace_restore=N
    builtin set -x
  fi
}

_cntools_action_advanced_multisig_derive_keys_terminal_valid() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ && "${#value}" -le "${maximum}" &&
     ! "${value}" =~ [[:cntrl:]] && "${value}" != *\\* ]]
}

_cntools_action_advanced_multisig_derive_keys_name_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_advanced_multisig_derive_keys_index_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  (( 10#${value} <= 2147483647 ))
}

_cntools_action_advanced_multisig_derive_keys_metadata() {
  local target="${1:-}" output_variable="${2:-}" captured=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  captured="$(_cntools_result_stat "${target}")" || return 1
  builtin printf -v "${output_variable}" '%s' "${captured}"
}

_cntools_action_advanced_multisig_derive_keys_directory_validate() {
  local target="${1:-}" expected_modes="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_advanced_multisig_derive_keys_metadata \
    "${target}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ",${expected_modes}," == *",${mode},"* ]]
}

_cntools_action_advanced_multisig_derive_keys_file_validate() {
  local target="${1:-}" maximum_size="${2:-}" expected_modes="${3:-600}"
  local expected_links="${4:-1}"
  local metadata="" owner="" mode="" links="" size=""

  [[ "${maximum_size}" =~ ^[1-9][0-9]*$ && -f "${target}" &&
     "${expected_links}" =~ ^[1-9][0-9]*$ && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_advanced_multisig_derive_keys_metadata \
    "${target}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ",${expected_modes}," == *",${mode},"* &&
     "${links}" == "${expected_links}" &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le "${maximum_size}" ]]
}

_cntools_action_advanced_multisig_derive_keys_private_output_validate() {
  local target="${1:-}" maximum_size="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ "${maximum_size}" =~ ^[1-9][0-9]*$ && -f "${target}" &&
     ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_advanced_multisig_derive_keys_metadata \
    "${target}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == 600 && "${links}" == 1 &&
     "${size}" =~ ^[0-9]+$ && "${size}" -le "${maximum_size}" ]]
}

_cntools_action_advanced_multisig_derive_keys_tool_resolve() {
  local configured="${1:-}" output_variable="${2:-}"
  local kind="" resolved="" metadata="" owner="" mode="" links="" size=""

  [[ "${output_variable}" =~ ^multisig_derive_[a-z0-9_]+_path$ ]] || return 70
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
  _cntools_action_advanced_multisig_derive_keys_metadata \
    "${resolved}" metadata || return 70
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 70
  mode="${mode#0}"
  [[ ( "${owner}" == 0 || "${owner}" == "${EUID}" ) &&
     "${mode}" =~ ^[57][0145][0145]$ && "${links}" == 1 &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 268435456 ]] || return 70
  builtin printf -v "${output_variable}" '%s' "${resolved}"
}

_cntools_action_advanced_multisig_derive_keys_identity() {
  local target="${1:-}" output_variable="${2:-}" captured=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if captured="$("${multisig_derive_stat_path}" -f $'%d\t%i' \
      "${target}" 2>/dev/null)"; then
    :
  else
    captured="$("${multisig_derive_stat_path}" -c $'%d\t%i' -- \
      "${target}" 2>/dev/null)" || return 1
  fi
  [[ "${captured}" =~ ^[0-9]+$'\t'[0-9]+$ ]] || return 1
  builtin printf -v "${output_variable}" '%s' "${captured}"
}

_cntools_action_advanced_multisig_derive_keys_digest() {
  local target="${1:-}" output_variable="${2:-}" captured=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "${multisig_derive_hash_kind:-}" in
    sha256sum)
      captured="$("${multisig_derive_hash_path}" "${target}" \
        2>/dev/null)" || return 1
      ;;
    shasum)
      captured="$("${multisig_derive_hash_path}" -a 256 "${target}" \
        2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  captured="${captured%% *}"
  [[ "${captured}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  builtin printf -v "${output_variable}" '%s' "${captured,,}"
}

_cntools_action_advanced_multisig_derive_keys_root_authority() {
  local current=""

  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${multisig_derive_root}" '700,750,755' &&
    _cntools_action_advanced_multisig_derive_keys_identity \
      "${multisig_derive_root}" current &&
    [[ "${current}" == "${multisig_derive_root_identity:-}" ]]
}

_cntools_action_advanced_multisig_derive_keys_wallet_authority() {
  local current=""

  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${multisig_derive_wallet}" '700,750,755' &&
    _cntools_action_advanced_multisig_derive_keys_identity \
      "${multisig_derive_wallet}" current &&
    [[ "${current}" == "${multisig_derive_wallet_identity:-}" ]]
}

_cntools_action_advanced_multisig_derive_keys_lock_authority() {
  local current=""

  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${multisig_derive_lock}" 700 &&
    _cntools_action_advanced_multisig_derive_keys_identity \
      "${multisig_derive_lock}" current &&
    [[ "${current}" == "${multisig_derive_lock_identity:-}" ]]
}

_cntools_action_advanced_multisig_derive_keys_stage_authority() {
  local current=""

  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${multisig_derive_stage}" 700 &&
    _cntools_action_advanced_multisig_derive_keys_identity \
      "${multisig_derive_stage}" current &&
    [[ "${current}" == "${multisig_derive_stage_identity:-}" ]]
}

_cntools_action_advanced_multisig_derive_keys_key_validate() {
  local target="${1:-}" expected_type="${2:-}"
  local expected_description="${3:-}" cbor_pattern="${4:-}"

  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 16384 600 || return 1
  "${multisig_derive_jq_path}" -e \
    --arg type "${expected_type}" \
    --arg description "${expected_description}" \
    --arg pattern "${cbor_pattern}" '
      type == "object" and
      keys == ["cborHex", "description", "type"] and
      .type == $type and .description == $description and
      (.cborHex | type == "string" and test($pattern))
    ' "${target}" >/dev/null 2>&1
}

_cntools_action_advanced_multisig_derive_keys_key_output_validate() {
  local target="${1:-}" expected_type="${2:-}" cbor_pattern="${3:-}"
  local description=""

  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 16384 600 || return 1
  "${multisig_derive_jq_path}" -e \
    --arg type "${expected_type}" \
    --arg pattern "${cbor_pattern}" '
      type == "object" and
      keys == ["cborHex", "description", "type"] and
      .type == $type and
      (.description | type == "string") and
      (.cborHex | type == "string" and test($pattern))
    ' "${target}" >/dev/null 2>&1 || return 1
  description="$("${multisig_derive_jq_path}" -er \
    '.description' "${target}" 2>/dev/null)" || return 1
  _cntools_action_advanced_multisig_derive_keys_terminal_valid \
    "${description}" 256
}

_cntools_action_advanced_multisig_derive_keys_hws_validate() {
  local target="${1:-}" expected_type="${2:-}"
  local expected_description="${3:-}" expected_path="${4:-}"

  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 16384 600 || return 1
  "${multisig_derive_jq_path}" -e \
    --arg type "${expected_type}" \
    --arg description "${expected_description}" \
    --arg path "${expected_path}" '
      type == "object" and
      keys == ["cborXPubKeyHex", "description", "path", "type"] and
      .type == $type and .description == $description and .path == $path and
      (.cborXPubKeyHex | type == "string" and
        test("^5840[0-9A-Fa-f]{128}$"))
    ' "${target}" >/dev/null 2>&1
}

_cntools_action_advanced_multisig_derive_keys_hws_output_validate() {
  local target="${1:-}" expected_type="${2:-}" expected_path="${3:-}"
  local description=""

  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 16384 600 || return 1
  "${multisig_derive_jq_path}" -e \
    --arg type "${expected_type}" \
    --arg path "${expected_path}" '
      type == "object" and
      keys == ["cborXPubKeyHex", "description", "path", "type"] and
      .type == $type and .path == $path and
      (.description | type == "string") and
      (.cborXPubKeyHex | type == "string" and
        test("^5840[0-9A-Fa-f]{128}$"))
    ' "${target}" >/dev/null 2>&1 || return 1
  description="$("${multisig_derive_jq_path}" -er \
    '.description' "${target}" 2>/dev/null)" || return 1
  _cntools_action_advanced_multisig_derive_keys_terminal_valid \
    "${description}" 256
}

_cntools_action_advanced_multisig_derive_keys_hardware_pair_validate() {
  local verification="${1:-}" signing="${2:-}"
  local verification_hex="" signing_hex=""

  verification_hex="$("${multisig_derive_jq_path}" -er \
    '.cborHex | ascii_downcase' "${verification}" 2>/dev/null)" || return 1
  signing_hex="$("${multisig_derive_jq_path}" -er \
    '.cborXPubKeyHex | ascii_downcase' "${signing}" 2>/dev/null)" || return 1
  [[ "${verification_hex}" == "5820${signing_hex:4:64}" ]]
}

_cntools_action_advanced_multisig_derive_keys_credential_validate() {
  local target="${1:-}" value=""

  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 128 600 || return 1
  value="$(< "${target}")"
  [[ "${value}" =~ ^[0-9A-Fa-f]{56}$ ]]
}

_cntools_action_advanced_multisig_derive_keys_path_validate() {
  local target="${1:-}" output_account="${2:-}" output_key="${3:-}"
  local value="" account="" key=""

  [[ "${output_account}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${output_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 128 '400,440,444,600,640,644' || return 1
  value="$(< "${target}")"
  [[ "${value}" =~ ^1852H/1815H/((0|[1-9][0-9]{0,9}))H/x/((0|[1-9][0-9]{0,9}))$ ]] ||
    return 1
  account="${BASH_REMATCH[1]}"
  key="${BASH_REMATCH[3]}"
  _cntools_action_advanced_multisig_derive_keys_index_valid "${account}" &&
    _cntools_action_advanced_multisig_derive_keys_index_valid "${key}" ||
    return 1
  builtin printf -v "${output_account}" '%s' "${account}"
  builtin printf -v "${output_key}" '%s' "${key}"
}

_cntools_action_advanced_multisig_derive_keys_expected_add() {
  local leaf="${1:-}" kind="${2:-}" type="${3:-}"
  local description="${4:-}" path="${5:-}"

  [[ "${leaf}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
     -z "${multisig_derive_expected_kind[${leaf}]+set}" ]] || return 70
  multisig_derive_expected_leaves+=("${leaf}")
  multisig_derive_expected_kind["${leaf}"]="${kind}"
  multisig_derive_expected_type["${leaf}"]="${type}"
  multisig_derive_expected_description["${leaf}"]="${description}"
  multisig_derive_expected_path["${leaf}"]="${path}"
}

_cntools_action_advanced_multisig_derive_keys_private_temp() {
  local label="${1:-}" output_variable="${2:-}" target=""

  [[ "${label}" =~ ^[a-z0-9-]{1,48}$ &&
     "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 70
  target="$("${multisig_derive_mktemp_path}" \
    "${multisig_derive_private_parent}/multisig-derive-${label}.XXXXXXXX")" ||
    return 70
  [[ "${target}" == "${multisig_derive_private_parent}/multisig-derive-${label}."* &&
     "${#target}" -le 4096 && ! "${target}" =~ [[:cntrl:]] ]] || return 70
  multisig_derive_private_cleanup_files+=("${target}")
  _cntools_action_advanced_multisig_derive_keys_private_output_validate \
    "${target}" 16384 || return 70
  [[ ! -s "${target}" ]] || return 70
  builtin printf -v "${output_variable}" '%s' "${target}"
}

_cntools_action_advanced_multisig_derive_keys_bounded_secret_command() {
  local output_variable="${1:-}" label="${2:-}" input_variable="${3:-}"
  local output="" value="" status=0 before_identity="" after_identity=""
  shift 3 || return 70

  [[ "${output_variable}" =~ ^multisig_derive_[a-z0-9_]+$ &&
     "${label}" =~ ^[a-z0-9-]{1,48}$ && $# -ge 1 &&
     ( -z "${input_variable}" ||
       "${input_variable}" =~ ^multisig_derive_[a-z0-9_]+$ ) ]] || return 70
  [[ -z "${input_variable}" || "$-" != *x* ]] || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    "${label}" output || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${output}" before_identity || return 70
  (
    ulimit -f 32 >/dev/null 2>&1 || exit 70
    if [[ -n "${input_variable}" ]]; then
      "$@" <<< "${!input_variable}" > "${output}" 2>&1
    else
      "$@" > "${output}" 2>&1
    fi
  ) || status=$?
  _cntools_action_advanced_multisig_derive_keys_private_output_validate \
    "${output}" 16384 || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${output}" after_identity || return 70
  [[ "${before_identity}" == "${after_identity}" ]] || return 70
  [[ -s "${output}" || "${status}" != 0 ]] || return 70
  [[ "${status}" == 0 ]] || return 1
  value="$(< "${output}")"
  [[ "${value}" =~ ^[A-Za-z0-9_.-]+$ && "${#value}" -le 4096 ]] || return 70
  builtin printf -v "${output_variable}" '%s' "${value}"
}

_cntools_action_advanced_multisig_derive_keys_trusted_gate() {
  local label="${1:-}" gate="${2:-}" capture="" status=0
  local before_identity="" after_identity=""
  shift 2 || return 70

  [[ "${label}" =~ ^[a-z0-9-]{1,48}$ &&
     ( "${gate}" == HWCLIversionCheck || "${gate}" == unlockHWDevice ) &&
     "$(builtin type -t "${gate}" 2>/dev/null || true)" == function ]] ||
    return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    "${label}" capture || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${capture}" before_identity || return 70
  (
    ulimit -f 32 >/dev/null 2>&1 || exit 70
    "${gate}" "$@"
  ) > "${capture}" 2>&1 || status=$?
  _cntools_action_advanced_multisig_derive_keys_private_output_validate \
    "${capture}" 16384 || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${capture}" after_identity || return 70
  [[ "${before_identity}" == "${after_identity}" ]] || return 70
  [[ "${status}" == 0 ]] || return 1
}

_cntools_action_advanced_multisig_derive_keys_inventory_write() {
  local root="${1:-}" output="${2:-}" before_identity=""
  local after_identity=""

  [[ "${root}" == "${multisig_derive_wallet}" ||
     "${root}" == "${multisig_derive_stage}" ]] || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${output}" before_identity || return 70
  "${multisig_derive_find_path}" "${root}" \
    -mindepth 1 -maxdepth 1 -print0 > "${output}" || return 70
  _cntools_action_advanced_multisig_derive_keys_private_output_validate \
    "${output}" 1048576 || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${output}" after_identity || return 70
  [[ "${before_identity}" == "${after_identity}" ]]
}

_cntools_action_advanced_multisig_derive_keys_canonicalize() {
  local target="${1:-}" description="${2:-}" temporary="" status=0
  local before_identity="" after_identity=""

  [[ "${target}" == "${multisig_derive_stage}/"* ]] || return 70
  _cntools_action_advanced_multisig_derive_keys_terminal_valid \
    "${description}" 256 || return 70
  temporary="$("${multisig_derive_mktemp_path}" \
    "${multisig_derive_stage}/.multisig-json.XXXXXXXX")" || return 70
  [[ "${temporary}" == "${multisig_derive_stage}/.multisig-json."* &&
     "${#temporary}" -le 4096 && ! "${temporary}" =~ [[:cntrl:]] ]] ||
    return 70
  multisig_derive_stage_cleanup_files+=("${temporary}")
  _cntools_action_advanced_multisig_derive_keys_private_output_validate \
    "${temporary}" 16384 || return 70
  [[ ! -s "${temporary}" ]] || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${temporary}" before_identity || return 70
  "${multisig_derive_jq_path}" -S --arg description "${description}" \
    '.description = $description' "${target}" > "${temporary}" 2>/dev/null ||
    return 70
  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${temporary}" 16384 600 || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${temporary}" after_identity || return 70
  [[ "${before_identity}" == "${after_identity}" ]] || return 70
  "${multisig_derive_mv_path}" -f -- "${temporary}" "${target}" \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 && ! -e "${temporary}" && ! -L "${temporary}" ]] ||
    return 70
  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 16384 600 || return 70
}

_cntools_action_advanced_multisig_derive_keys_wallet_inventory_capture() {
  local inventory="" target="" leaf="" metadata="" digest="" count=0

  _cntools_action_advanced_multisig_derive_keys_wallet_authority || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    wallet-inventory inventory || return 70
  _cntools_action_advanced_multisig_derive_keys_inventory_write \
    "${multisig_derive_wallet}" "${inventory}" || return 70
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${multisig_derive_wallet}/"* ]] || return 70
    leaf="${target#"${multisig_derive_wallet}/"}"
    [[ "${leaf}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
       -z "${multisig_derive_original_digest[${leaf}]+set}" ]] || return 70
    _cntools_action_advanced_multisig_derive_keys_file_validate \
      "${target}" 1048576 '400,440,444,600,640,644' || return 70
    _cntools_action_advanced_multisig_derive_keys_metadata \
      "${target}" metadata || return 70
    _cntools_action_advanced_multisig_derive_keys_digest \
      "${target}" digest || return 70
    multisig_derive_original_leaves+=("${leaf}")
    multisig_derive_original_metadata["${leaf}"]="${metadata}"
    multisig_derive_original_digest["${leaf}"]="${digest}"
    [[ "${leaf}" != "${WALLET_MULTISIG_PREFIX}"* ]] ||
      multisig_derive_existing_ms=Y
    count=$((count + 1))
    (( count <= 256 )) || return 70
  done < "${inventory}"
}

_cntools_action_advanced_multisig_derive_keys_wallet_inventory_validate() {
  local phase="${1:-original}" inventory="" target="" leaf=""
  local metadata="" digest="" count=0 expected_count=0
  local -A visited=()

  [[ "${phase}" == original || "${phase}" == published ]] || return 70
  _cntools_action_advanced_multisig_derive_keys_wallet_authority || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    wallet-recheck inventory || return 70
  _cntools_action_advanced_multisig_derive_keys_inventory_write \
    "${multisig_derive_wallet}" "${inventory}" || return 70
  expected_count="${#multisig_derive_original_leaves[@]}"
  [[ "${phase}" != published ]] ||
    expected_count=$((expected_count + ${#multisig_derive_published_leaves[@]}))
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${multisig_derive_wallet}/"* ]] || return 70
    leaf="${target#"${multisig_derive_wallet}/"}"
    [[ "${leaf}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
       -z "${visited[${leaf}]+set}" ]] || return 70
    visited["${leaf}"]=Y
    if [[ -n "${multisig_derive_original_digest[${leaf}]+set}" ]]; then
      _cntools_action_advanced_multisig_derive_keys_file_validate \
        "${target}" 1048576 '400,440,444,600,640,644' || return 70
      _cntools_action_advanced_multisig_derive_keys_metadata \
        "${target}" metadata || return 70
      _cntools_action_advanced_multisig_derive_keys_digest \
        "${target}" digest || return 70
      [[ "${metadata}" == "${multisig_derive_original_metadata[${leaf}]}" &&
         "${digest}" == "${multisig_derive_original_digest[${leaf}]}" ]] ||
        return 70
    elif [[ "${phase}" == published &&
            -n "${multisig_derive_published_set[${leaf}]+set}" ]]; then
      _cntools_action_advanced_multisig_derive_keys_file_validate \
        "${target}" 16384 600 2 || return 70
      _cntools_action_advanced_multisig_derive_keys_digest \
        "${target}" digest || return 70
      [[ "${digest}" == "${multisig_derive_stage_digest[${leaf}]}" ]] ||
        return 70
    else
      return 70
    fi
    count=$((count + 1))
    (( count <= 512 )) || return 70
  done < "${inventory}"
  (( count == expected_count )) || return 70
}

_cntools_action_advanced_multisig_derive_keys_partial_stage_safe() {
  local inventory="" target="" leaf="" count=0
  local -A visited=()

  _cntools_action_advanced_multisig_derive_keys_stage_authority || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    partial-stage inventory || return 70
  _cntools_action_advanced_multisig_derive_keys_inventory_write \
    "${multisig_derive_stage}" "${inventory}" || return 70
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${multisig_derive_stage}/"* ]] || return 70
    leaf="${target#"${multisig_derive_stage}/"}"
    [[ "${leaf}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
       -n "${multisig_derive_expected_kind[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 70
    visited["${leaf}"]=Y
    _cntools_action_advanced_multisig_derive_keys_file_validate \
      "${target}" 16384 600 || return 70
    count=$((count + 1))
    (( count <= ${#multisig_derive_expected_leaves[@]} )) || return 70
  done < "${inventory}"
}

_cntools_action_advanced_multisig_derive_keys_stage_inventory_validate() {
  local inventory="" target="" leaf="" kind="" digest="" count=0
  local -A visited=()

  _cntools_action_advanced_multisig_derive_keys_stage_authority || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    final-stage inventory || return 70
  _cntools_action_advanced_multisig_derive_keys_inventory_write \
    "${multisig_derive_stage}" "${inventory}" || return 70
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${multisig_derive_stage}/"* ]] || return 70
    leaf="${target#"${multisig_derive_stage}/"}"
    [[ "${leaf}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
       -n "${multisig_derive_expected_kind[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 70
    visited["${leaf}"]=Y
    kind="${multisig_derive_expected_kind[${leaf}]}"
    case "${kind}" in
      vkey|skey)
        _cntools_action_advanced_multisig_derive_keys_key_validate \
          "${target}" "${multisig_derive_expected_type[${leaf}]}" \
          "${multisig_derive_expected_description[${leaf}]}" \
          "${multisig_derive_expected_path[${leaf}]}" || return 70
        ;;
      hws)
        _cntools_action_advanced_multisig_derive_keys_hws_validate \
          "${target}" "${multisig_derive_expected_type[${leaf}]}" \
          "${multisig_derive_expected_description[${leaf}]}" \
          "${multisig_derive_expected_path[${leaf}]}" || return 70
        ;;
      credential)
        _cntools_action_advanced_multisig_derive_keys_credential_validate \
          "${target}" || return 70
        ;;
      path)
        _cntools_action_advanced_multisig_derive_keys_path_validate \
          "${target}" multisig_derive_checked_account \
          multisig_derive_checked_key || return 70
        [[ "${multisig_derive_checked_account}" == "${multisig_derive_account}" &&
           "${multisig_derive_checked_key}" == "${multisig_derive_key}" ]] ||
          return 70
        ;;
      *) return 70 ;;
    esac
    _cntools_action_advanced_multisig_derive_keys_digest \
      "${target}" digest || return 70
    multisig_derive_stage_digest["${leaf}"]="${digest}"
    count=$((count + 1))
  done < "${inventory}"
  (( count == ${#multisig_derive_expected_leaves[@]} )) || return 70
}

_cntools_action_advanced_multisig_derive_keys_publish_current_reconcile() {
  local leaf="${multisig_derive_current_publish_leaf:-}" source="" target=""
  local source_identity="" target_identity="" digest=""

  [[ -n "${leaf}" && -n "${multisig_derive_expected_kind[${leaf}]+set}" ]] ||
    return 1
  source="${multisig_derive_stage}/${leaf}"
  target="${multisig_derive_wallet}/${leaf}"
  if [[ ! -e "${target}" && ! -L "${target}" ]]; then
    return 1
  fi
  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${source}" 16384 600 2 || return 70
  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${target}" 16384 600 2 || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${source}" source_identity || return 70
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${target}" target_identity || return 70
  _cntools_action_advanced_multisig_derive_keys_digest \
    "${target}" digest || return 70
  [[ "${source_identity}" == "${target_identity}" &&
     "${digest}" == "${multisig_derive_stage_digest[${leaf}]}" ]] || return 70
  if [[ -z "${multisig_derive_published_set[${leaf}]+set}" ]]; then
    multisig_derive_published_leaves+=("${leaf}")
    multisig_derive_published_set["${leaf}"]=Y
  fi
  multisig_derive_current_publish_leaf=""
  return 0
}

_cntools_action_advanced_multisig_derive_keys_publish_one() {
  local leaf="${1:-}" source="" target="" raw_status=0 reconcile_status=0

  [[ -n "${multisig_derive_expected_kind[${leaf}]+set}" &&
     -z "${multisig_derive_published_set[${leaf}]+set}" ]] || return 70
  _cntools_action_advanced_multisig_derive_keys_root_authority &&
    _cntools_action_advanced_multisig_derive_keys_wallet_authority &&
    _cntools_action_advanced_multisig_derive_keys_lock_authority &&
    _cntools_action_advanced_multisig_derive_keys_stage_authority || return 70
  source="${multisig_derive_stage}/${leaf}"
  target="${multisig_derive_wallet}/${leaf}"
  [[ ! -e "${target}" && ! -L "${target}" ]] || return 70
  multisig_derive_current_publish_leaf="${leaf}"
  "${multisig_derive_ln_path}" -- "${source}" "${target}" \
    >/dev/null 2>&1 || raw_status=$?
  _cntools_action_advanced_multisig_derive_keys_publish_current_reconcile ||
    reconcile_status=$?
  [[ "${reconcile_status}" == 0 ]] || return 70
  # A tool that reports failure after creating the authenticated hardlink is
  # reconciled as success. The inode/digest is the authority, not raw status.
  : "${raw_status}"
}

_cntools_action_advanced_multisig_derive_keys_cleanup() {
  local cleanup_status=0 leaf="" target="" source="" current=""
  local source_identity="" target_identity="" digest="" index=0

  trap '' HUP INT TERM
  unset multisig_derive_mnemonic multisig_derive_root_secret
  unset multisig_derive_payment_secret multisig_derive_stake_secret
  unset multisig_derive_payment_public multisig_derive_stake_public
  unset multisig_derive_payment_secret_hex multisig_derive_stake_secret_hex
  unset multisig_derive_payment_public_hex multisig_derive_stake_public_hex
  unset multisig_derive_words payment_cbor stake_cbor

  if [[ "${multisig_derive_committed:-N}" != Y &&
        -n "${multisig_derive_current_publish_leaf:-}" ]]; then
    _cntools_action_advanced_multisig_derive_keys_publish_current_reconcile \
      >/dev/null 2>&1 || {
        [[ ! -e "${multisig_derive_wallet}/${multisig_derive_current_publish_leaf}" &&
           ! -L "${multisig_derive_wallet}/${multisig_derive_current_publish_leaf}" ]] ||
          cleanup_status=1
      }
    multisig_derive_current_publish_leaf=""
  fi
  if [[ "${multisig_derive_committed:-N}" != Y ]]; then
    for ((index=${#multisig_derive_published_leaves[@]}-1; index>=0; index--)); do
      leaf="${multisig_derive_published_leaves[index]}"
      source="${multisig_derive_stage}/${leaf}"
      target="${multisig_derive_wallet}/${leaf}"
      if [[ -e "${target}" || -L "${target}" ]]; then
        _cntools_action_advanced_multisig_derive_keys_file_validate \
          "${source}" 16384 600 2 &&
          _cntools_action_advanced_multisig_derive_keys_file_validate \
            "${target}" 16384 600 2 &&
          _cntools_action_advanced_multisig_derive_keys_identity \
            "${source}" source_identity &&
          _cntools_action_advanced_multisig_derive_keys_identity \
            "${target}" target_identity &&
          _cntools_action_advanced_multisig_derive_keys_digest \
            "${target}" digest &&
          [[ "${source_identity}" == "${target_identity}" &&
             "${digest}" == "${multisig_derive_stage_digest[${leaf}]}" ]] || {
            cleanup_status=1
            continue
          }
        "${multisig_derive_rm_path}" -f -- "${target}" \
          >/dev/null 2>&1 || true
        [[ ! -e "${target}" && ! -L "${target}" ]] || cleanup_status=1
      fi
    done
  fi
  if [[ -n "${multisig_derive_stage:-}" ]]; then
    if _cntools_action_advanced_multisig_derive_keys_stage_authority; then
      for target in "${multisig_derive_stage_cleanup_files[@]:-}"; do
        [[ -n "${target}" && "${target}" == "${multisig_derive_stage}/"* ]] ||
          continue
        if [[ -e "${target}" || -L "${target}" ]]; then
          "${multisig_derive_rm_path}" -f -- "${target}" \
            >/dev/null 2>&1 || true
          [[ ! -e "${target}" && ! -L "${target}" ]] || cleanup_status=1
        fi
      done
      "${multisig_derive_rmdir_path}" -- "${multisig_derive_stage}" \
        >/dev/null 2>&1 || true
      [[ ! -e "${multisig_derive_stage}" && ! -L "${multisig_derive_stage}" ]] ||
        cleanup_status=1
    elif [[ -e "${multisig_derive_stage}" || -L "${multisig_derive_stage}" ]]; then
      cleanup_status=1
    fi
  fi
  for target in "${multisig_derive_private_cleanup_files[@]:-}"; do
    [[ -n "${target}" && "${target}" == "${multisig_derive_private_parent}/"* ]] ||
      continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${multisig_derive_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || true
      [[ ! -e "${target}" && ! -L "${target}" ]] || cleanup_status=1
    fi
  done
  if [[ -n "${multisig_derive_lock:-}" &&
        ( -e "${multisig_derive_lock}" || -L "${multisig_derive_lock}" ) ]]; then
    if _cntools_action_advanced_multisig_derive_keys_lock_authority; then
      "${multisig_derive_rmdir_path}" -- "${multisig_derive_lock}" \
        >/dev/null 2>&1 || true
      [[ ! -e "${multisig_derive_lock}" && ! -L "${multisig_derive_lock}" ]] ||
        cleanup_status=1
    else
      cleanup_status=1
    fi
  fi
  if [[ "${cleanup_status}" == 0 ]]; then
    multisig_derive_stage=""
    multisig_derive_lock=""
  fi
  _cntools_action_advanced_multisig_derive_keys_xtrace_restore
  return "${cleanup_status}"
}

_cntools_action_advanced_multisig_derive_keys_signal() {
  _cntools_action_advanced_multisig_derive_keys_cleanup >/dev/null 2>&1 || true
  _cntools_action_advanced_multisig_derive_keys_validation_failure
  exit 70
}

_cntools_action_advanced_multisig_derive_keys_postcommit_signal() {
  multisig_derive_committed=Y
  _cntools_action_advanced_multisig_derive_keys_cleanup >/dev/null 2>&1 || true
  _cntools_action_advanced_multisig_derive_keys_warning
  exit 0
}

_cntools_action_advanced_multisig_derive_keys_defer_signal() {
  multisig_derive_signal_pending=Y
}

_cntools_action_advanced_multisig_derive_keys_handled() {
  local message="${1:-}" cleanup_status=0

  _cntools_action_advanced_multisig_derive_keys_cleanup || cleanup_status=1
  trap - EXIT HUP INT TERM
  [[ "${cleanup_status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure
    return 70
  }
  [[ -z "${message}" ]] || println ERROR "${message}"
  waitToProceed
  return 0
}

_cntools_action_advanced_multisig_derive_keys_cancel() {
  local cleanup_status=0

  _cntools_action_advanced_multisig_derive_keys_cleanup || cleanup_status=1
  trap - EXIT HUP INT TERM
  [[ "${cleanup_status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure
    return 70
  }
  return 0
}

_cntools_action_advanced_multisig_derive_keys_invariant() {
  _cntools_action_advanced_multisig_derive_keys_cleanup >/dev/null 2>&1 || true
  trap - EXIT HUP INT TERM
  _cntools_action_advanced_multisig_derive_keys_validation_failure
  return 70
}

_cntools_action_advanced_multisig_derive_keys_prompt_index() {
  local output_variable="${1:-}" prompt="${2:-}" prompted="" status=0

  [[ "${output_variable}" == multisig_derive_account ||
     "${output_variable}" == multisig_derive_key ]] || return 70
  getAnswerAnyCust prompted "${prompt}" || status=$?
  [[ "${status}" == 0 ]] || {
    [[ "${status}" == 1 ]] && return 1
    return 70
  }
  prompted="${prompted:-0}"
  _cntools_action_advanced_multisig_derive_keys_index_valid "${prompted}" ||
    return 2
  builtin printf -v "${output_variable}" '%s' "${prompted}"
}

_cntools_action_advanced_multisig_derive_keys_prepare_common_expected() {
  local source="${1:-}"
  local payment_vkey="${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  local stake_vkey="${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  local payment_cred="${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
  local stake_cred="${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"
  local payment_description='MultiSig Payment Verification Key'
  local stake_description='MultiSig Stake Verification Key'

  [[ "${source}" == cli || "${source}" == mnemonic ||
     "${source}" == hardware ]] || return 70
  if [[ "${source}" == hardware ]]; then
    payment_description='MultiSig Payment Hardware Verification Key'
    stake_description='MultiSig Stake Hardware Verification Key'
  fi

  _cntools_action_advanced_multisig_derive_keys_expected_add \
    "${payment_vkey}" vkey PaymentVerificationKeyShelley_ed25519 \
    "${payment_description}" '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_expected_add \
    "${stake_vkey}" vkey StakeVerificationKeyShelley_ed25519 \
    "${stake_description}" '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_expected_add \
    "${payment_cred}" credential '' '' '' || return 70
  _cntools_action_advanced_multisig_derive_keys_expected_add \
    "${stake_cred}" credential '' '' '' || return 70
}

_cntools_action_advanced_multisig_derive_keys_prepare_software_expected() {
  local extended="${1:-N}"
  local payment_sk="${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
  local stake_sk="${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"

  if [[ "${extended}" == Y ]]; then
    _cntools_action_advanced_multisig_derive_keys_expected_add \
      "${payment_sk}" skey PaymentExtendedSigningKeyShelley_ed25519_bip32 \
      'MultiSig Payment Signing Key' '^5880[0-9A-Fa-f]{192}$' || return 70
    _cntools_action_advanced_multisig_derive_keys_expected_add \
      "${stake_sk}" skey StakeExtendedSigningKeyShelley_ed25519_bip32 \
      'MultiSig Stake Signing Key' '^5880[0-9A-Fa-f]{192}$' || return 70
  else
    _cntools_action_advanced_multisig_derive_keys_expected_add \
      "${payment_sk}" skey PaymentSigningKeyShelley_ed25519 \
      'MultiSig Payment Signing Key' '^5820[0-9A-Fa-f]{64}$' || return 70
    _cntools_action_advanced_multisig_derive_keys_expected_add \
      "${stake_sk}" skey StakeSigningKeyShelley_ed25519 \
      'MultiSig Stake Signing Key' '^5820[0-9A-Fa-f]{64}$' || return 70
  fi
}

_cntools_action_advanced_multisig_derive_keys_prepare_hardware_expected() {
  local payment_hws="${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_SK_FILENAME}"
  local stake_hws="${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_SK_FILENAME}"
  local payment_path="1854H/1815H/${multisig_derive_account}H/0/${multisig_derive_key}"
  local stake_path="1854H/1815H/${multisig_derive_account}H/2/${multisig_derive_key}"

  _cntools_action_advanced_multisig_derive_keys_expected_add \
    "${payment_hws}" hws PaymentHWSigningFileShelley_ed25519 \
    'MultiSig Payment Hardware Signing File' "${payment_path}" || return 70
  _cntools_action_advanced_multisig_derive_keys_expected_add \
    "${stake_hws}" hws StakeHWSigningFileShelley_ed25519 \
    'MultiSig Stake Hardware Signing File' "${stake_path}" || return 70
}

_cntools_action_advanced_multisig_derive_keys_write_path() {
  local target="${multisig_derive_stage}/${WALLET_DERIVATION_PATH_FILENAME}"

  printf '1852H/1815H/%sH/x/%s\n' \
    "${multisig_derive_account}" "${multisig_derive_key}" > "${target}" ||
    return 70
  _cntools_action_advanced_multisig_derive_keys_path_validate \
    "${target}" multisig_derive_checked_account \
    multisig_derive_checked_key || return 70
  [[ "${multisig_derive_checked_account}" == "${multisig_derive_account}" &&
     "${multisig_derive_checked_key}" == "${multisig_derive_key}" ]] ||
    return 70
}

_cntools_action_advanced_multisig_derive_keys_derive_credentials() {
  local payment_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  local stake_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  local payment_cred="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
  local stake_cred="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"
  local status=0

  "${multisig_derive_ccli_path}" address key-hash \
    --payment-verification-key-file "${payment_vkey}" \
    --out-file "${payment_cred}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_partial_stage_safe || return 70
    return 1
  }
  _cntools_action_advanced_multisig_derive_keys_credential_validate \
    "${payment_cred}" || return 70
  status=0
  "${multisig_derive_ccli_path}" latest stake-address key-hash \
    --stake-verification-key-file "${stake_vkey}" \
    --out-file "${stake_cred}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_partial_stage_safe || return 70
    return 1
  }
  _cntools_action_advanced_multisig_derive_keys_credential_validate \
    "${stake_cred}" || return 70
}

_cntools_action_advanced_multisig_derive_keys_derive_cli() {
  local payment_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  local payment_skey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
  local stake_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  local stake_skey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
  local status=0

  println ACTION "${CCLI} address key-gen --verification-key-file ${multisig_derive_wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME} --signing-key-file ${multisig_derive_wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
  "${multisig_derive_ccli_path}" address key-gen \
    --verification-key-file "${payment_vkey}" \
    --signing-key-file "${payment_skey}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_partial_stage_safe || return 70
    return 1
  }
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${payment_vkey}" PaymentVerificationKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${payment_skey}" PaymentSigningKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${payment_vkey}" 'MultiSig Payment Verification Key' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${payment_skey}" 'MultiSig Payment Signing Key' || return 70
  println ACTION "${CCLI} latest stake-address key-gen --verification-key-file ${multisig_derive_wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME} --signing-key-file ${multisig_derive_wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
  status=0
  "${multisig_derive_ccli_path}" latest stake-address key-gen \
    --verification-key-file "${stake_vkey}" \
    --signing-key-file "${stake_skey}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_partial_stage_safe || return 70
    return 2
  }
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${stake_vkey}" StakeVerificationKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${stake_skey}" StakeSigningKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${stake_vkey}" 'MultiSig Stake Verification Key' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${stake_skey}" 'MultiSig Stake Signing Key' || return 70
}

_cntools_action_advanced_multisig_derive_keys_derive_mnemonic() {
  local payment_skey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
  local stake_skey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
  local payment_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  local stake_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  local payment_evkey="" stake_evkey="" payment_cbor_file=""
  local stake_cbor_file="" payment_cbor="" stake_cbor=""
  local version="" status=0
  local -a public_args=()

  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_caddr_version mnemonic-version '' \
    "${multisig_derive_cardano_address_path}" -v || status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  version="${multisig_derive_caddr_version}"
  [[ "${version}" =~ ^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$ ]] || return 70
  [[ "${version%%.*}" == 3 ]] && public_args=(--with-chain-code)
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_root_secret mnemonic-root multisig_derive_mnemonic \
    "${multisig_derive_cardano_address_path}" key from-recovery-phrase Shelley ||
    status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  unset multisig_derive_mnemonic
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_payment_secret mnemonic-payment-child \
    multisig_derive_root_secret \
    "${multisig_derive_cardano_address_path}" key child \
    "1854H/1815H/${multisig_derive_account}H/0/${multisig_derive_key}" ||
    status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_stake_secret mnemonic-stake-child \
    multisig_derive_root_secret \
    "${multisig_derive_cardano_address_path}" key child \
    "1854H/1815H/${multisig_derive_account}H/2/${multisig_derive_key}" ||
    status=$?
  unset multisig_derive_root_secret
  [[ "${status}" == 0 ]] || return "${status}"
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_payment_public mnemonic-payment-public \
    multisig_derive_payment_secret \
    "${multisig_derive_cardano_address_path}" key public \
    "${public_args[@]}" || status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_stake_public mnemonic-stake-public \
    multisig_derive_stake_secret \
    "${multisig_derive_cardano_address_path}" key public \
    "${public_args[@]}" || status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_payment_secret_hex mnemonic-payment-secret-hex \
    multisig_derive_payment_secret "${multisig_derive_bech32_path}" ||
    status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_stake_secret_hex mnemonic-stake-secret-hex \
    multisig_derive_stake_secret "${multisig_derive_bech32_path}" ||
    status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_payment_public_hex mnemonic-payment-public-hex \
    multisig_derive_payment_public "${multisig_derive_bech32_path}" ||
    status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  status=0
  _cntools_action_advanced_multisig_derive_keys_bounded_secret_command \
    multisig_derive_stake_public_hex mnemonic-stake-public-hex \
    multisig_derive_stake_public "${multisig_derive_bech32_path}" ||
    status=$?
  [[ "${status}" == 0 ]] || return "${status}"
  [[ "${multisig_derive_payment_secret_hex}" =~ ^[0-9A-Fa-f]+$ &&
     "${#multisig_derive_payment_secret_hex}" -ge 128 &&
     "${#multisig_derive_payment_secret_hex}" -le 512 &&
     "${multisig_derive_stake_secret_hex}" =~ ^[0-9A-Fa-f]+$ &&
     "${#multisig_derive_stake_secret_hex}" -ge 128 &&
     "${#multisig_derive_stake_secret_hex}" -le 512 &&
     "${multisig_derive_payment_public_hex}" =~ ^[0-9A-Fa-f]{64}$ &&
     "${multisig_derive_stake_public_hex}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 70
  payment_cbor="5880${multisig_derive_payment_secret_hex:0:128}${multisig_derive_payment_public_hex}"
  stake_cbor="5880${multisig_derive_stake_secret_hex:0:128}${multisig_derive_stake_public_hex}"
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    payment-signing-cbor payment_cbor_file || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    stake-signing-cbor stake_cbor_file || return 70
  builtin printf '%s\n' "${payment_cbor}" > "${payment_cbor_file}" || return 70
  builtin printf '%s\n' "${stake_cbor}" > "${stake_cbor_file}" || return 70
  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${payment_cbor_file}" 1024 600 || return 70
  _cntools_action_advanced_multisig_derive_keys_file_validate \
    "${stake_cbor_file}" 1024 600 || return 70
  unset payment_cbor stake_cbor
  "${multisig_derive_jq_path}" -nS --rawfile cbor "${payment_cbor_file}" \
    '{type:"PaymentExtendedSigningKeyShelley_ed25519_bip32",description:"MultiSig Payment Signing Key",cborHex:($cbor | rtrimstr("\n"))}' \
    > "${payment_skey}" 2>/dev/null || return 70
  "${multisig_derive_jq_path}" -nS --rawfile cbor "${stake_cbor_file}" \
    '{type:"StakeExtendedSigningKeyShelley_ed25519_bip32",description:"MultiSig Stake Signing Key",cborHex:($cbor | rtrimstr("\n"))}' \
    > "${stake_skey}" 2>/dev/null || return 70
  unset multisig_derive_payment_secret multisig_derive_stake_secret
  unset multisig_derive_payment_public multisig_derive_stake_public
  unset multisig_derive_payment_secret_hex multisig_derive_stake_secret_hex
  unset multisig_derive_payment_public_hex multisig_derive_stake_public_hex
  _cntools_action_advanced_multisig_derive_keys_key_validate \
    "${payment_skey}" PaymentExtendedSigningKeyShelley_ed25519_bip32 \
    'MultiSig Payment Signing Key' '^5880[0-9A-Fa-f]{192}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_key_validate \
    "${stake_skey}" StakeExtendedSigningKeyShelley_ed25519_bip32 \
    'MultiSig Stake Signing Key' '^5880[0-9A-Fa-f]{192}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    payment-evkey payment_evkey || return 70
  _cntools_action_advanced_multisig_derive_keys_private_temp \
    stake-evkey stake_evkey || return 70
  status=0
  "${multisig_derive_ccli_path}" key verification-key \
    --signing-key-file "${payment_skey}" \
    --verification-key-file "${payment_evkey}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || return 1
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${payment_evkey}" PaymentExtendedVerificationKeyShelley_ed25519_bip32 \
    '^5840[0-9A-Fa-f]{128}$' || return 70
  status=0
  "${multisig_derive_ccli_path}" key verification-key \
    --signing-key-file "${stake_skey}" \
    --verification-key-file "${stake_evkey}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || return 1
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${stake_evkey}" StakeExtendedVerificationKeyShelley_ed25519_bip32 \
    '^5840[0-9A-Fa-f]{128}$' || return 70
  status=0
  "${multisig_derive_ccli_path}" key non-extended-key \
    --extended-verification-key-file "${payment_evkey}" \
    --verification-key-file "${payment_vkey}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || return 1
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${payment_vkey}" PaymentVerificationKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  status=0
  "${multisig_derive_ccli_path}" key non-extended-key \
    --extended-verification-key-file "${stake_evkey}" \
    --verification-key-file "${stake_vkey}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || return 1
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${stake_vkey}" StakeVerificationKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${payment_vkey}" 'MultiSig Payment Verification Key' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${stake_vkey}" 'MultiSig Stake Verification Key' || return 70
}

_cntools_action_advanced_multisig_derive_keys_derive_hardware() {
  local payment_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  local stake_vkey="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  local payment_hws="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_SK_FILENAME}"
  local stake_hws="${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_SK_FILENAME}"
  local payment_path="1854H/1815H/${multisig_derive_account}H/0/${multisig_derive_key}"
  local stake_path="1854H/1815H/${multisig_derive_account}H/2/${multisig_derive_key}"
  local status=0
  local -a command=("${multisig_derive_hwcli_path}" address key-gen
    --path "${payment_path}" --path "${stake_path}"
    --verification-key-file "${payment_vkey}"
    --verification-key-file "${stake_vkey}"
    --hw-signing-file "${payment_hws}"
    --hw-signing-file "${stake_hws}")

  println ACTION 'cardano-hw-cli address key-gen (MultiSig payment/stake paths)'
  "${command[@]}" >/dev/null 2>&1 || status=$?
  [[ "${status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_partial_stage_safe || return 70
    return 1
  }
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${payment_vkey}" PaymentVerificationKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_key_output_validate \
    "${stake_vkey}" StakeVerificationKeyShelley_ed25519 \
    '^5820[0-9A-Fa-f]{64}$' || return 70
  _cntools_action_advanced_multisig_derive_keys_hws_output_validate \
    "${payment_hws}" PaymentHWSigningFileShelley_ed25519 \
    "${payment_path}" || return 70
  _cntools_action_advanced_multisig_derive_keys_hws_output_validate \
    "${stake_hws}" StakeHWSigningFileShelley_ed25519 \
    "${stake_path}" || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${payment_vkey}" 'MultiSig Payment Hardware Verification Key' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${stake_vkey}" 'MultiSig Stake Hardware Verification Key' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${payment_hws}" 'MultiSig Payment Hardware Signing File' || return 70
  _cntools_action_advanced_multisig_derive_keys_canonicalize \
    "${stake_hws}" 'MultiSig Stake Hardware Signing File' || return 70
  _cntools_action_advanced_multisig_derive_keys_hardware_pair_validate \
    "${payment_vkey}" "${payment_hws}" || return 70
  _cntools_action_advanced_multisig_derive_keys_hardware_pair_validate \
    "${stake_vkey}" "${stake_hws}" || return 70
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local context_network="" context_home="" filename="" status=0
  local resolve_status=0 wallet_type=0 choice_status=0 derive_status=0
  local cleanup_status=0 leaf="" path_file="" words_count=0 word=""
  local payment_credential="" stake_credential=""
  local multisig_derive_root="" multisig_derive_wallet=""
  local multisig_derive_wallet_name="" multisig_derive_private_parent=""
  local multisig_derive_lock="" multisig_derive_stage=""
  local multisig_derive_root_identity="" multisig_derive_wallet_identity=""
  local multisig_derive_lock_identity="" multisig_derive_stage_identity=""
  local multisig_derive_existing_ms=N multisig_derive_new_path=N
  local multisig_derive_committed=N multisig_derive_signal_pending=N
  local multisig_derive_xtrace_restore=N
  local multisig_derive_current_publish_leaf=""
  local multisig_derive_account="" multisig_derive_key=""
  local multisig_derive_checked_account="" multisig_derive_checked_key=""
  local multisig_derive_source="" multisig_derive_mnemonic=""
  local multisig_derive_root_secret="" multisig_derive_payment_secret=""
  local multisig_derive_stake_secret="" multisig_derive_payment_public=""
  local multisig_derive_stake_public="" multisig_derive_payment_secret_hex=""
  local multisig_derive_stake_secret_hex="" multisig_derive_payment_public_hex=""
  local multisig_derive_stake_public_hex="" multisig_derive_caddr_version=""
  local multisig_derive_jq_path="" multisig_derive_mktemp_path=""
  local multisig_derive_mkdir_path=""
  local multisig_derive_rm_path="" multisig_derive_rmdir_path=""
  local multisig_derive_mv_path="" multisig_derive_ln_path=""
  local multisig_derive_find_path="" multisig_derive_stat_path=""
  local multisig_derive_hash_path="" multisig_derive_hash_kind=""
  local multisig_derive_ccli_path="" multisig_derive_cardano_address_path=""
  local multisig_derive_bech32_path="" multisig_derive_hwcli_path=""
  local -a multisig_derive_original_leaves=()
  local -a multisig_derive_expected_leaves=()
  local -a multisig_derive_published_leaves=()
  local -a multisig_derive_stage_cleanup_files=()
  local -a multisig_derive_private_cleanup_files=()
  local -a multisig_derive_words=()
  local -A multisig_derive_original_metadata=()
  local -A multisig_derive_original_digest=()
  local -A multisig_derive_expected_kind=()
  local -A multisig_derive_expected_type=()
  local -A multisig_derive_expected_description=()
  local -A multisig_derive_expected_path=()
  local -A multisig_derive_stage_digest=()
  local -A multisig_derive_published_set=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F selectWallet >/dev/null 2>&1 ||
     ! builtin declare -F getWalletType >/dev/null 2>&1 ||
     ! builtin declare -F select_opt >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1; then
    _cntools_action_advanced_multisig_derive_keys_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  context_home="$(cntools_context_get "${context_file}" nodeHome)" || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  [[ "${context_mode}" == local || "${context_mode}" == light ||
     "${context_mode}" == offline ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" &&
     "${context_network}" =~ ^[A-Za-z0-9._-]{1,64}$ &&
     "${context_home}" == /* && "${context_home}" != *\\* &&
     ! "${context_home}" =~ [[:cntrl:]] ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  for filename in jq mktemp mkdir rm rmdir mv ln find stat; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq multisig_derive_jq_path || status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp multisig_derive_mktemp_path || status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir multisig_derive_mkdir_path || status=70 ;;
      rm) _cntools_registry_tool_path rm multisig_derive_rm_path || status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir multisig_derive_rmdir_path || status=70 ;;
      mv) _cntools_registry_tool_path mv multisig_derive_mv_path || status=70 ;;
      ln) _cntools_registry_tool_path ln multisig_derive_ln_path || status=70 ;;
      find) _cntools_registry_tool_path find multisig_derive_find_path || status=70 ;;
      stat) _cntools_registry_tool_path stat multisig_derive_stat_path || status=70 ;;
    esac
  done
  [[ "${status}" == 0 ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  if _cntools_registry_tool_path sha256sum multisig_derive_hash_path; then
    multisig_derive_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum multisig_derive_hash_path; then
    multisig_derive_hash_kind=shasum
  else
    _cntools_action_advanced_multisig_derive_keys_validation_failure
    return 70
  fi
  _cntools_action_advanced_multisig_derive_keys_tool_resolve \
    "${CCLI:-}" multisig_derive_ccli_path || {
      _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  multisig_derive_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${multisig_derive_private_parent}" || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  [[ "${WALLET_FOLDER}" == /* && "${WALLET_FOLDER}" != *\\* &&
     ! "${WALLET_FOLDER}" =~ [[:cntrl:]] ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${WALLET_FOLDER}" '700,750,755' || {
      _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  multisig_derive_root="$(cd -P -- "${WALLET_FOLDER}" && pwd -P)" || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  [[ "${multisig_derive_root}" == "${WALLET_FOLDER}" &&
     "${multisig_derive_root}" != "${multisig_derive_private_parent}" &&
     "${multisig_derive_root}" != "${multisig_derive_private_parent}/"* &&
     "${multisig_derive_private_parent}" != "${multisig_derive_root}/"* ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${multisig_derive_root}" multisig_derive_root_identity || {
      _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  for filename in "${WALLET_PAY_SK_FILENAME}" "${WALLET_PAY_VK_FILENAME}" \
      "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}" \
      "${WALLET_HW_PAY_SK_FILENAME}" "${WALLET_HW_STAKE_SK_FILENAME}" \
      "${WALLET_PAY_CRED_FILENAME}" "${WALLET_STAKE_CRED_FILENAME}" \
      "${WALLET_DERIVATION_PATH_FILENAME}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
      _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }
  done
  [[ "${WALLET_MULTISIG_PREFIX}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
    _cntools_action_advanced_multisig_derive_keys_validation_failure; return 70; }

  umask 077
  trap '_cntools_action_advanced_multisig_derive_keys_cleanup' EXIT
  trap '_cntools_action_advanced_multisig_derive_keys_signal' HUP INT TERM
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> ADVANCED >> MULTISIG >> DERIVE KEYS'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  println DEBUG 'Select wallet to derive MultiSig keys for (only wallets with missing keys shown)'
  selectWallet non-ms || status=$?
  case "${status}" in
    0) multisig_derive_wallet_name="${wallet_name:-}" ;;
    1)
      _cntools_action_advanced_multisig_derive_keys_handled ''
      return $?
      ;;
    2)
      _cntools_action_advanced_multisig_derive_keys_cancel
      return $?
      ;;
    *) _cntools_action_advanced_multisig_derive_keys_invariant; return 70 ;;
  esac
  _cntools_action_advanced_multisig_derive_keys_name_valid \
    "${multisig_derive_wallet_name}" || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  multisig_derive_wallet="${multisig_derive_root}/${multisig_derive_wallet_name}"
  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${multisig_derive_wallet}" '700,750,755' || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  _cntools_action_advanced_multisig_derive_keys_identity \
    "${multisig_derive_wallet}" multisig_derive_wallet_identity || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  _cntools_action_advanced_multisig_derive_keys_wallet_inventory_capture || {
    _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  status=0
  getWalletType "${multisig_derive_wallet_name}" || status=$?
  case "${status}" in
    0) wallet_type=0 ;;
    1|2|3|4) wallet_type=1 ;;
    *) _cntools_action_advanced_multisig_derive_keys_invariant; return 70 ;;
  esac
  _cntools_action_advanced_multisig_derive_keys_wallet_inventory_validate original || {
    _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  if [[ "${multisig_derive_existing_ms}" == Y ]]; then
    _cntools_action_advanced_multisig_derive_keys_handled \
      $'\nERROR: MultiSig key material already exists for selected wallet!'
    return $?
  fi
  multisig_derive_lock="${multisig_derive_root}/.${multisig_derive_wallet_name}.cntools-multisig-derive.lock"
  _cntools_action_advanced_multisig_derive_keys_root_authority || {
    _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  trap '_cntools_action_advanced_multisig_derive_keys_defer_signal' HUP INT TERM
  status=0
  "${multisig_derive_mkdir_path}" -m 0700 -- "${multisig_derive_lock}" \
    >/dev/null 2>&1 || status=$?
  if [[ "${status}" != 0 ]]; then
    multisig_derive_lock=""
    trap '_cntools_action_advanced_multisig_derive_keys_signal' HUP INT TERM
    [[ "${multisig_derive_signal_pending}" != Y ]] ||
      _cntools_action_advanced_multisig_derive_keys_signal
    _cntools_action_advanced_multisig_derive_keys_handled \
      'ERROR: MultiSig key derivation is already in progress, please retry!'
    return $?
  fi
  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${multisig_derive_lock}" 700 &&
    _cntools_action_advanced_multisig_derive_keys_identity \
      "${multisig_derive_lock}" multisig_derive_lock_identity || {
        _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  trap '_cntools_action_advanced_multisig_derive_keys_signal' HUP INT TERM
  [[ "${multisig_derive_signal_pending}" != Y ]] ||
    _cntools_action_advanced_multisig_derive_keys_signal

  if [[ "${wallet_type}" == 0 ]]; then
    resolve_status=0
    _cntools_action_advanced_multisig_derive_keys_tool_resolve cardano-hw-cli \
      multisig_derive_hwcli_path || resolve_status=$?
    if [[ "${resolve_status}" == 1 ]]; then
      _cntools_action_advanced_multisig_derive_keys_handled \
        $'ERROR: cardano-hw-cli not found in path or executable permission not set.\nPlease run guild-deploy.sh -s w to install hardware wallet support.'
      return $?
    elif [[ "${resolve_status}" != 0 ]]; then
      _cntools_action_advanced_multisig_derive_keys_invariant
      return 70
    fi
    status=0
    _cntools_action_advanced_multisig_derive_keys_trusted_gate \
      hardware-version HWCLIversionCheck || status=$?
    if [[ "${status}" == 1 ]]; then
      _cntools_action_advanced_multisig_derive_keys_handled \
        'ERROR: cardano-hw-cli version compatibility check failed!'
      return $?
    elif [[ "${status}" != 0 ]]; then
      _cntools_action_advanced_multisig_derive_keys_invariant
      return 70
    fi
    multisig_derive_source=hardware
  else
    println DEBUG 'Is selected wallet a CLI generated wallet or derived from mnemonic?'
    status=0
    select_opt '[c] CLI' '[m] Mnemonic' || status=$?
    case "${status}" in
      0) multisig_derive_source=cli ;;
      1) multisig_derive_source=mnemonic ;;
      *) _cntools_action_advanced_multisig_derive_keys_invariant; return 70 ;;
    esac
  fi

  if [[ "${multisig_derive_source}" == mnemonic ]]; then
    resolve_status=0
    _cntools_action_advanced_multisig_derive_keys_tool_resolve bech32 \
      multisig_derive_bech32_path || resolve_status=$?
    if [[ "${resolve_status}" == 0 ]]; then
      _cntools_action_advanced_multisig_derive_keys_tool_resolve cardano-address \
        multisig_derive_cardano_address_path || resolve_status=$?
    fi
    if [[ "${resolve_status}" == 1 ]]; then
      _cntools_action_advanced_multisig_derive_keys_handled \
        $'ERROR: bech32 and/or cardano-address not found in \x27$PATH\x27\nPlease run updated guild-deploy.sh and re-build/re-download cardano-node'
      return $?
    elif [[ "${resolve_status}" != 0 ]]; then
      _cntools_action_advanced_multisig_derive_keys_invariant
      return 70
    fi
    _cntools_action_advanced_multisig_derive_keys_xtrace_disable || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
    status=0
    getAnswerAnyCust multisig_derive_mnemonic false \
      '24 or 15 word mnemonic(space separated)' || status=$?
    if [[ "${status}" == 1 ]]; then
      unset multisig_derive_mnemonic
      _cntools_action_advanced_multisig_derive_keys_cancel
      return $?
    elif [[ "${status}" != 0 ]]; then
      _cntools_action_advanced_multisig_derive_keys_invariant
      return 70
    fi
    echo
    IFS=' ' read -r -a multisig_derive_words <<< "${multisig_derive_mnemonic}"
    words_count="${#multisig_derive_words[@]}"
    if [[ "${words_count}" != 15 && "${words_count}" != 24 ]]; then
      unset multisig_derive_mnemonic multisig_derive_words
      _cntools_action_advanced_multisig_derive_keys_handled \
        "ERROR: 24 or 15 words expected, found ${words_count}"
      return $?
    fi
    for word in "${multisig_derive_words[@]}"; do
      [[ "${word}" =~ ^[a-z]{1,16}$ ]] || {
        unset multisig_derive_mnemonic multisig_derive_words
        _cntools_action_advanced_multisig_derive_keys_invariant
        return 70
      }
    done
    [[ "${multisig_derive_mnemonic}" == "${multisig_derive_words[*]}" &&
       "${#multisig_derive_mnemonic}" -le 512 ]] || {
      unset multisig_derive_mnemonic multisig_derive_words
      _cntools_action_advanced_multisig_derive_keys_invariant
      return 70
    }
    unset multisig_derive_words
  fi

  path_file="${multisig_derive_wallet}/${WALLET_DERIVATION_PATH_FILENAME}"
  if [[ "${multisig_derive_source}" != cli ]]; then
    if [[ -e "${path_file}" || -L "${path_file}" ]]; then
      _cntools_action_advanced_multisig_derive_keys_path_validate \
        "${path_file}" multisig_derive_account multisig_derive_key || {
          _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
    else
      println DEBUG 'Enter a custom account index to derive keys for (enter for default)'
      choice_status=0
      _cntools_action_advanced_multisig_derive_keys_prompt_index \
        multisig_derive_account 'Account (default: 0)' || choice_status=$?
      case "${choice_status}" in
        0) ;;
        1) _cntools_action_advanced_multisig_derive_keys_cancel; return $? ;;
        2)
          _cntools_action_advanced_multisig_derive_keys_handled \
            'ERROR: Invalid account index, must be a number between 0 and 2147483647!'
          return $?
          ;;
        *) _cntools_action_advanced_multisig_derive_keys_invariant; return 70 ;;
      esac
      println DEBUG $'\nEnter a custom key index to derive keys for (enter for default)'
      choice_status=0
      _cntools_action_advanced_multisig_derive_keys_prompt_index \
        multisig_derive_key 'Key index (default: 0)' || choice_status=$?
      case "${choice_status}" in
        0) multisig_derive_new_path=Y ;;
        1) _cntools_action_advanced_multisig_derive_keys_cancel; return $? ;;
        2)
          _cntools_action_advanced_multisig_derive_keys_handled \
            'ERROR: Invalid key index, must be a number between 0 and 2147483647!'
          return $?
          ;;
        *) _cntools_action_advanced_multisig_derive_keys_invariant; return 70 ;;
      esac
    fi
  fi

  if [[ "${multisig_derive_source}" == hardware ]]; then
    println DEBUG 'Connect and unlock the hardware device, then open its Cardano app.'
    status=0
    _cntools_action_advanced_multisig_derive_keys_trusted_gate \
      hardware-unlock unlockHWDevice 'extract MultiSig keys' || status=$?
    if [[ "${status}" == 1 ]]; then
      _cntools_action_advanced_multisig_derive_keys_handled \
        'ERROR: hardware device unlock or device-version validation failed!'
      return $?
    elif [[ "${status}" != 0 ]]; then
      _cntools_action_advanced_multisig_derive_keys_invariant
      return 70
    fi
  fi

  _cntools_action_advanced_multisig_derive_keys_prepare_common_expected \
    "${multisig_derive_source}" || {
    _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  case "${multisig_derive_source}" in
    cli)
      _cntools_action_advanced_multisig_derive_keys_prepare_software_expected N || {
        _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
      ;;
    mnemonic)
      _cntools_action_advanced_multisig_derive_keys_prepare_software_expected Y || {
        _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
      ;;
    hardware)
      _cntools_action_advanced_multisig_derive_keys_prepare_hardware_expected || {
        _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
      ;;
    *) _cntools_action_advanced_multisig_derive_keys_invariant; return 70 ;;
  esac
  if [[ "${multisig_derive_new_path}" == Y ]]; then
    _cntools_action_advanced_multisig_derive_keys_expected_add \
      "${WALLET_DERIVATION_PATH_FILENAME}" path '' '' '' || {
        _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  fi
  for leaf in "${multisig_derive_expected_leaves[@]}"; do
    [[ ! -e "${multisig_derive_wallet}/${leaf}" &&
       ! -L "${multisig_derive_wallet}/${leaf}" ]] || {
      _cntools_action_advanced_multisig_derive_keys_handled \
        $'\nERROR: MultiSig key material already exists for selected wallet!'
      return $?
    }
  done
  multisig_derive_stage="$("${multisig_derive_mktemp_path}" -d \
    "${multisig_derive_root}/.${multisig_derive_wallet_name}.cntools-multisig-derive.stage.XXXXXXXX")" || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  [[ "${multisig_derive_stage}" == \
       "${multisig_derive_root}/.${multisig_derive_wallet_name}.cntools-multisig-derive.stage."* &&
     "${#multisig_derive_stage}" -le 4096 &&
     ! "${multisig_derive_stage}" =~ [[:cntrl:]] ]] || {
       _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  _cntools_action_advanced_multisig_derive_keys_directory_validate \
    "${multisig_derive_stage}" 700 &&
    _cntools_action_advanced_multisig_derive_keys_identity \
      "${multisig_derive_stage}" multisig_derive_stage_identity || {
        _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  for leaf in "${multisig_derive_expected_leaves[@]}"; do
    multisig_derive_stage_cleanup_files+=("${multisig_derive_stage}/${leaf}")
  done
  if [[ "${multisig_derive_new_path}" == Y ]]; then
    _cntools_action_advanced_multisig_derive_keys_write_path || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  fi

  derive_status=0
  case "${multisig_derive_source}" in
    cli) _cntools_action_advanced_multisig_derive_keys_derive_cli || derive_status=$? ;;
    mnemonic) _cntools_action_advanced_multisig_derive_keys_derive_mnemonic || derive_status=$? ;;
    hardware) _cntools_action_advanced_multisig_derive_keys_derive_hardware || derive_status=$? ;;
  esac
  if [[ "${derive_status}" == 1 ]]; then
    _cntools_action_advanced_multisig_derive_keys_wallet_inventory_validate original || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
    case "${multisig_derive_source}" in
      cli) _cntools_action_advanced_multisig_derive_keys_handled \
        'ERROR: failure during MultiSig payment key creation!' ;;
      mnemonic) _cntools_action_advanced_multisig_derive_keys_handled \
        'ERROR: failure during mnemonic MultiSig key derivation!' ;;
      hardware) _cntools_action_advanced_multisig_derive_keys_handled \
        'ERROR: failure during hardware MultiSig key extraction!' ;;
    esac
    return $?
  elif [[ "${derive_status}" == 2 ]]; then
    _cntools_action_advanced_multisig_derive_keys_wallet_inventory_validate original || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
    _cntools_action_advanced_multisig_derive_keys_handled \
      'ERROR: failure during MultiSig stake key creation!'
    return $?
  elif [[ "${derive_status}" != 0 ]]; then
    _cntools_action_advanced_multisig_derive_keys_invariant
    return 70
  fi
  derive_status=0
  _cntools_action_advanced_multisig_derive_keys_derive_credentials ||
    derive_status=$?
  if [[ "${derive_status}" == 1 ]]; then
    _cntools_action_advanced_multisig_derive_keys_wallet_inventory_validate original || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
    _cntools_action_advanced_multisig_derive_keys_handled \
      'ERROR: failure during MultiSig credential derivation!'
    return $?
  elif [[ "${derive_status}" != 0 ]]; then
    _cntools_action_advanced_multisig_derive_keys_invariant
    return 70
  fi
  _cntools_action_advanced_multisig_derive_keys_stage_inventory_validate &&
    _cntools_action_advanced_multisig_derive_keys_root_authority &&
    _cntools_action_advanced_multisig_derive_keys_wallet_authority &&
    _cntools_action_advanced_multisig_derive_keys_lock_authority &&
    _cntools_action_advanced_multisig_derive_keys_stage_authority &&
    _cntools_action_advanced_multisig_derive_keys_wallet_inventory_validate original || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  payment_credential="$(< "${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}")"
  stake_credential="$(< "${multisig_derive_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}")"
  _cntools_action_advanced_multisig_derive_keys_terminal_valid \
    "${payment_credential}" 128 &&
    _cntools_action_advanced_multisig_derive_keys_terminal_valid \
      "${stake_credential}" 128 || {
        _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  for leaf in "${multisig_derive_expected_leaves[@]}"; do
    _cntools_action_advanced_multisig_derive_keys_publish_one "${leaf}" || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  done
  _cntools_action_advanced_multisig_derive_keys_wallet_inventory_validate published &&
    _cntools_action_advanced_multisig_derive_keys_root_authority &&
    _cntools_action_advanced_multisig_derive_keys_wallet_authority &&
    _cntools_action_advanced_multisig_derive_keys_lock_authority || {
      _cntools_action_advanced_multisig_derive_keys_invariant; return 70; }
  # Signals across the commit boundary are deferred until both the durable
  # publication state and its post-commit signal authority agree.
  trap '_cntools_action_advanced_multisig_derive_keys_defer_signal' HUP INT TERM
  multisig_derive_committed=Y
  trap '_cntools_action_advanced_multisig_derive_keys_postcommit_signal' \
    HUP INT TERM
  [[ "${multisig_derive_signal_pending}" != Y ]] ||
    _cntools_action_advanced_multisig_derive_keys_postcommit_signal
  _cntools_action_advanced_multisig_derive_keys_cleanup || cleanup_status=1
  trap - EXIT HUP INT TERM

  echo
  println "Wallet   : ${FG_GREEN}${multisig_derive_wallet_name}${NC}"
  println 'MultiSig Credentials'
  println "Payment  : ${payment_credential}"
  println "Stake    : ${stake_credential}"
  [[ "${cleanup_status}" == 0 ]] ||
    _cntools_action_advanced_multisig_derive_keys_warning
  waitToProceed
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
