#!/usr/bin/env bash
# shellcheck disable=SC2154
# Stage 4 compatibility action for hardened CLI wallet creation.
# Sourcing defines functions only; the dispatcher supplies an authenticated
# context and the inherited CNTools prompt, display and wait helpers.

_cntools_action_wallet_new_cli_validation_failure() {
  builtin printf '%s\n' \
    'CNTools CLI wallet creation action failed validation.' >&2
  return 70
}

_cntools_action_wallet_new_cli_warning() {
  builtin printf '%s\n' \
    'WARNING: the wallet was created, but administrative cleanup needs attention.' >&2
}

_cntools_action_wallet_new_cli_terminal_value_valid() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ && "${#value}" -le "${maximum}" &&
     ! "${value}" =~ [[:cntrl:]] && "${value}" != *\\* ]]
}

_cntools_action_wallet_new_cli_name_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_new_cli_metadata() {
  local target="${1:-}" output_variable="${2:-}"
  local stat_result=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  stat_result="$(_cntools_result_stat "${target}")" || return 1
  printf -v "${output_variable}" '%s' "${stat_result}"
}

_cntools_action_wallet_new_cli_directory_validate() {
  local target="${1:-}" expected_modes="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_wallet_new_cli_metadata "${target}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ",${expected_modes}," == *",${mode},"* ]]
}

_cntools_action_wallet_new_cli_file_validate() {
  local target="${1:-}" maximum_size="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ "${maximum_size}" =~ ^[1-9][0-9]*$ && -f "${target}" &&
     ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_wallet_new_cli_metadata "${target}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == 600 && "${links}" == 1 &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le "${maximum_size}" ]]
}

_cntools_action_wallet_new_cli_key_validate() {
  local target="${1:-}" expected_type="${2:-}"
  local type=""

  [[ "${expected_type}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  _cntools_action_wallet_new_cli_file_validate "${target}" 16384 || return 1
  type="$("${wallet_new_cli_jq_path}" -er '
    if type == "object" and
       keys == ["cborHex", "description", "type"] and
       (.type | type == "string" and length >= 1 and length <= 128 and
         test("^[A-Za-z0-9_-]+$")) and
       (.description | type == "string" and length >= 1 and length <= 256 and
         test("^[ -~]+$")) and
       (.cborHex | type == "string" and length >= 66 and length <= 1024 and
         test("^[0-9A-Fa-f]+$"))
    then .type
    else error("invalid key")
    end
  ' "${target}" 2>/dev/null)" || return 1
  [[ "${type}" == "${expected_type}" ]]
}

_cntools_action_wallet_new_cli_text_validate() {
  local target="${1:-}" kind="${2:-}" value=""

  _cntools_action_wallet_new_cli_file_validate "${target}" 1024 || return 1
  value="$(< "${target}")"
  _cntools_action_wallet_new_cli_terminal_value_valid "${value}" 512 || return 1
  case "${kind}" in
    base|payment)
      if [[ "${wallet_new_cli_network_args[0]:-}" == --mainnet ]]; then
        [[ "${value}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]]
      else
        [[ "${wallet_new_cli_network_args[0]:-}" == --testnet-magic &&
           "${value}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]]
      fi
      ;;
    reward)
      if [[ "${wallet_new_cli_network_args[0]:-}" == --mainnet ]]; then
        [[ "${value}" =~ ^stake1[023456789ac-hj-np-z]{20,200}$ ]]
      else
        [[ "${wallet_new_cli_network_args[0]:-}" == --testnet-magic &&
           "${value}" =~ ^stake_test1[023456789ac-hj-np-z]{20,200}$ ]]
      fi
      ;;
    credential)
      [[ "${value}" =~ ^[0-9A-Fa-f]{56}$ ]]
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_wallet_new_cli_cleanup() {
  local cleanup_target="" cleanup_status=0 current_identity=""
  local reconcile_status=0

  if [[ "${wallet_new_cli_committed:-N}" == Y ]]; then
    trap '_cntools_action_wallet_new_cli_postcommit_signal' HUP INT TERM
  else
    trap '_cntools_action_wallet_new_cli_signal' HUP INT TERM
  fi
  if [[ -n "${wallet_new_cli_stage:-}" &&
        "${wallet_new_cli_publish_attempt:-N}" == Y ]]; then
    _cntools_action_wallet_new_cli_publish_reconcile || reconcile_status=$?
    if [[ "${reconcile_status}" == 70 ]]; then
      cleanup_status=1
      # The stage/destination authority is ambiguous. Never traverse either
      # pathname from cleanup in this state.
      wallet_new_cli_stage=""
    fi
  fi
  if [[ -n "${wallet_new_cli_stage:-}" ]]; then
    if _cntools_action_wallet_new_cli_directory_identity \
         "${wallet_new_cli_stage}" current_identity &&
       [[ "${current_identity}" == "${wallet_new_cli_stage_identity:-}" ]] &&
       _cntools_action_wallet_new_cli_directory_validate \
         "${wallet_new_cli_stage}" 700; then
      for cleanup_target in "${wallet_new_cli_stage_cleanup_files[@]:-}"; do
        [[ -n "${cleanup_target}" ]] || continue
        [[ "${cleanup_target}" == "${wallet_new_cli_stage}/"* ]] || continue
        if [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
          "${wallet_new_cli_rm_path}" -f -- "${cleanup_target}" \
            >/dev/null 2>&1 || cleanup_status=1
        fi
      done
      "${wallet_new_cli_rmdir_path}" -- "${wallet_new_cli_stage}" \
        >/dev/null 2>&1 || cleanup_status=1
    elif [[ -e "${wallet_new_cli_stage}" ||
            -L "${wallet_new_cli_stage}" ]]; then
      cleanup_status=1
    fi
  fi
  for cleanup_target in "${wallet_new_cli_private_cleanup_files[@]:-}"; do
    [[ -n "${cleanup_target}" ]] || continue
    [[ "${cleanup_target}" == "${wallet_new_cli_private_parent}/"* ]] || continue
    if [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
      "${wallet_new_cli_rm_path}" -f -- "${cleanup_target}" \
        >/dev/null 2>&1 || cleanup_status=1
    fi
  done
  wallet_new_cli_stage_cleanup_files=()
  wallet_new_cli_private_cleanup_files=()
  if [[ "${cleanup_status}" == 0 ]]; then
    wallet_new_cli_stage=""
    wallet_new_cli_stage_identity=""
  fi
  if [[ -n "${wallet_new_cli_lock:-}" &&
        ( -e "${wallet_new_cli_lock}" || -L "${wallet_new_cli_lock}" ) ]]; then
    if _cntools_action_wallet_new_cli_directory_validate \
         "${wallet_new_cli_lock}" 700 &&
       _cntools_action_wallet_new_cli_directory_identity \
         "${wallet_new_cli_lock}" current_identity &&
       [[ "${current_identity}" == "${wallet_new_cli_lock_identity:-}" ]]; then
      "${wallet_new_cli_rmdir_path}" -- "${wallet_new_cli_lock}" \
        >/dev/null 2>&1 || cleanup_status=1
    else
      cleanup_status=1
    fi
  fi
  [[ "${cleanup_status}" != 0 ]] || wallet_new_cli_lock=""
  return "${cleanup_status}"
}

_cntools_action_wallet_new_cli_inventory_validate() {
  local directory="${1:-}" inventory_file="" target="" leaf="" digest=""
  local expected_count=0 visited_count=0
  local -A expected=() visited=()

  _cntools_action_wallet_new_cli_directory_validate "${directory}" 700 ||
    return 1
  for leaf in "${wallet_new_cli_expected_leaves[@]:-}"; do
    [[ "${leaf}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
       -z "${expected[${leaf}]+set}" ]] || return 1
    expected["${leaf}"]=Y
    expected_count=$((expected_count + 1))
  done
  (( expected_count == 23 )) || return 1
  (( ${#wallet_new_cli_leaf_digests[@]} == expected_count )) || return 1
  inventory_file="$("${wallet_new_cli_mktemp_path}" \
    "${wallet_new_cli_private_parent}/wallet-new-cli-inventory.XXXXXXXX")" ||
    return 1
  wallet_new_cli_private_cleanup_files+=("${inventory_file}")
  "${wallet_new_cli_chmod_path}" 0600 "${inventory_file}" || return 1
  "${wallet_new_cli_find_path}" "${directory}" -mindepth 1 -maxdepth 1 \
    -print0 > "${inventory_file}" || return 1
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${directory}/"* ]] || return 1
    leaf="${target#"${directory}/"}"
    [[ "${leaf}" != */* && -n "${expected[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 1
    visited["${leaf}"]=Y
    visited_count=$((visited_count + 1))
  done < "${inventory_file}"
  (( visited_count == expected_count )) || return 1
  for leaf in "${wallet_new_cli_expected_leaves[@]}"; do
    [[ -n "${visited[${leaf}]+set}" ]] || return 1
    case "${leaf}" in
      "${WALLET_PAY_VK_FILENAME}"|"${WALLET_STAKE_VK_FILENAME}"|\
        "${WALLET_GOV_DREP_VK_FILENAME}"|\
        "${WALLET_GOV_CC_COLD_VK_FILENAME}"|\
        "${WALLET_GOV_CC_HOT_VK_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}")
        case "${leaf}" in
          "${WALLET_PAY_VK_FILENAME}"|\
            "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" PaymentVerificationKeyShelley_ed25519 ||
              return 1
            ;;
          "${WALLET_STAKE_VK_FILENAME}"|\
            "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" StakeVerificationKeyShelley_ed25519 ||
              return 1
            ;;
          "${WALLET_GOV_DREP_VK_FILENAME}"|\
            "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" DRepVerificationKey_ed25519 || return 1
            ;;
          "${WALLET_GOV_CC_COLD_VK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" ConstitutionalCommitteeColdVerificationKey_ed25519 ||
              return 1
            ;;
          "${WALLET_GOV_CC_HOT_VK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" ConstitutionalCommitteeHotVerificationKey_ed25519 ||
              return 1
            ;;
          *) return 1 ;;
        esac
        ;;
      "${WALLET_PAY_SK_FILENAME}"|"${WALLET_STAKE_SK_FILENAME}"|\
        "${WALLET_GOV_DREP_SK_FILENAME}"|\
        "${WALLET_GOV_CC_COLD_SK_FILENAME}"|\
        "${WALLET_GOV_CC_HOT_SK_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}")
        case "${leaf}" in
          "${WALLET_PAY_SK_FILENAME}"|\
            "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" PaymentSigningKeyShelley_ed25519 || return 1
            ;;
          "${WALLET_STAKE_SK_FILENAME}"|\
            "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" StakeSigningKeyShelley_ed25519 || return 1
            ;;
          "${WALLET_GOV_DREP_SK_FILENAME}"|\
            "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" DRepSigningKey_ed25519 || return 1
            ;;
          "${WALLET_GOV_CC_COLD_SK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" ConstitutionalCommitteeColdSigningKey_ed25519 ||
              return 1
            ;;
          "${WALLET_GOV_CC_HOT_SK_FILENAME}")
            _cntools_action_wallet_new_cli_key_validate \
              "${directory}/${leaf}" ConstitutionalCommitteeHotSigningKey_ed25519 ||
              return 1
            ;;
          *) return 1 ;;
        esac
        ;;
      "${WALLET_BASE_ADDR_FILENAME}")
        _cntools_action_wallet_new_cli_text_validate \
          "${directory}/${leaf}" base || return 1
        ;;
      "${WALLET_PAY_ADDR_FILENAME}")
        _cntools_action_wallet_new_cli_text_validate \
          "${directory}/${leaf}" payment || return 1
        ;;
      "${WALLET_STAKE_ADDR_FILENAME}")
        _cntools_action_wallet_new_cli_text_validate \
          "${directory}/${leaf}" reward || return 1
        ;;
      "${WALLET_PAY_CRED_FILENAME}"|"${WALLET_STAKE_CRED_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"|\
        "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}")
        _cntools_action_wallet_new_cli_text_validate \
          "${directory}/${leaf}" credential || return 1
        ;;
      *) return 1 ;;
    esac
    _cntools_action_wallet_new_cli_digest "${directory}/${leaf}" digest ||
      return 1
    [[ "${digest}" == "${wallet_new_cli_leaf_digests[${leaf}]:-}" ]] ||
      return 1
  done
}

_cntools_action_wallet_new_cli_directory_identity() {
  local target="${1:-}" output_variable="${2:-}" identity=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if identity="$("${wallet_new_cli_stat_path}" -f $'%d\t%i' \
      "${target}" 2>/dev/null)"; then
    :
  else
    identity="$("${wallet_new_cli_stat_path}" -c $'%d\t%i' -- \
      "${target}" 2>/dev/null)" || return 1
  fi
  [[ "${identity}" =~ ^[0-9]+$'\t'[0-9]+$ ]] || return 1
  printf -v "${output_variable}" '%s' "${identity}"
}

_cntools_action_wallet_new_cli_digest() {
  local target="${1:-}" output_variable="${2:-}" digest=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "${wallet_new_cli_hash_kind:-}" in
    sha256sum)
      digest="$("${wallet_new_cli_hash_path}" "${target}" 2>/dev/null)" ||
        return 1
      digest="${digest%% *}"
      ;;
    shasum)
      digest="$("${wallet_new_cli_hash_path}" -a 256 \
        "${target}" 2>/dev/null)" || return 1
      digest="${digest%% *}"
      ;;
    *) return 1 ;;
  esac
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf -v "${output_variable}" '%s' "${digest,,}"
}

_cntools_action_wallet_new_cli_leaf_digest_capture() {
  local target="${1:-}" leaf="" digest=""

  [[ "${target}" == "${wallet_new_cli_stage}/"* ]] || return 1
  leaf="${target##*/}"
  [[ -n "${wallet_new_cli_leaf_seen[${leaf}]+set}" ]] || return 1
  _cntools_action_wallet_new_cli_digest "${target}" digest || return 1
  wallet_new_cli_leaf_digests["${leaf}"]="${digest}"
}

_cntools_action_wallet_new_cli_root_authority_validate() {
  local current_identity=""

  _cntools_action_wallet_new_cli_directory_validate \
    "${wallet_new_cli_root}" '700,750,755' &&
    _cntools_action_wallet_new_cli_directory_identity \
      "${wallet_new_cli_root}" current_identity &&
    [[ "${current_identity}" == "${wallet_new_cli_root_identity:-}" ]]
}

_cntools_action_wallet_new_cli_lock_authority_validate() {
  local current_identity=""

  _cntools_action_wallet_new_cli_directory_validate \
    "${wallet_new_cli_lock}" 700 &&
    _cntools_action_wallet_new_cli_directory_identity \
      "${wallet_new_cli_lock}" current_identity &&
    [[ "${current_identity}" == "${wallet_new_cli_lock_identity:-}" ]]
}

_cntools_action_wallet_new_cli_stage_authority_validate() {
  local current_identity=""

  _cntools_action_wallet_new_cli_directory_validate \
    "${wallet_new_cli_stage}" 700 &&
    _cntools_action_wallet_new_cli_directory_identity \
      "${wallet_new_cli_stage}" current_identity &&
    [[ "${current_identity}" == "${wallet_new_cli_stage_identity:-}" ]]
}

_cntools_action_wallet_new_cli_ccli_resolve() {
  local configured="${1:-}" output_variable="${2:-}"
  local metadata="" owner="" mode="" links="" size="" resolved=""

  [[ "${output_variable}" == wallet_new_cli_ccli_path ]] || return 1
  if [[ "${configured}" =~ ^[a-z][a-z0-9-]*$ ]]; then
    _cntools_registry_tool_path "${configured}" resolved || return 1
  elif [[ "${configured}" == /* ]]; then
    resolved="${configured}"
  else
    return 1
  fi
  [[ "${resolved}" == /* && "${resolved}" != */ &&
     "${resolved}" != *//* && "${resolved}" != *\\* &&
     ! "${resolved}" =~ [[:cntrl:]] && -f "${resolved}" &&
     -x "${resolved}" && ! -L "${resolved}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${resolved}" || return 1
  _cntools_action_wallet_new_cli_metadata "${resolved}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ ( "${owner}" == 0 || "${owner}" == "${EUID}" ) &&
     "${mode}" =~ ^[57][0145][0145]$ && "${links}" == 1 &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 134217728 ]] || return 1
  printf -v "${output_variable}" '%s' "${resolved}"
}

_cntools_action_wallet_new_cli_publish_reconcile() {
  local current_identity=""

  [[ "${wallet_new_cli_publish_attempt:-N}" == Y &&
     -n "${wallet_new_cli_stage_identity:-}" ]] || return 1
  if [[ ! -e "${wallet_new_cli_stage}" &&
        ! -L "${wallet_new_cli_stage}" ]] &&
     _cntools_action_wallet_new_cli_directory_validate \
       "${wallet_new_cli_destination}" 700 &&
     _cntools_action_wallet_new_cli_directory_identity \
       "${wallet_new_cli_destination}" current_identity &&
     [[ "${current_identity}" == "${wallet_new_cli_stage_identity}" ]]; then
    wallet_new_cli_committed=Y
    wallet_new_cli_stage=""
    trap '_cntools_action_wallet_new_cli_postcommit_signal' HUP INT TERM
    return 0
  fi
  if _cntools_action_wallet_new_cli_directory_validate \
       "${wallet_new_cli_stage}" 700 &&
     _cntools_action_wallet_new_cli_directory_identity \
       "${wallet_new_cli_stage}" current_identity &&
     [[ "${current_identity}" == "${wallet_new_cli_stage_identity}" ]]; then
    wallet_new_cli_committed=N
    return 1
  fi
  return 70
}

_cntools_action_wallet_new_cli_signal() {
  local reconcile_status=1

  if [[ "${wallet_new_cli_publish_attempt:-N}" == Y ]]; then
    if _cntools_action_wallet_new_cli_publish_reconcile; then
      _cntools_action_wallet_new_cli_postcommit_signal
    else
      reconcile_status=$?
      [[ "${reconcile_status}" != 70 ]] || exit 70
    fi
  fi
  if [[ "${wallet_new_cli_committed:-N}" == Y ]]; then
    _cntools_action_wallet_new_cli_postcommit_signal
  fi
  _cntools_action_wallet_new_cli_cleanup >/dev/null 2>&1 || true
  exit 70
}

_cntools_action_wallet_new_cli_postcommit_signal() {
  wallet_new_cli_committed=Y
  wallet_new_cli_stage=""
  _cntools_action_wallet_new_cli_cleanup >/dev/null 2>&1 || true
  _cntools_action_wallet_new_cli_warning
  exit 0
}

_cntools_action_wallet_new_cli_defer_signal() {
  wallet_new_cli_signal_pending=Y
}

_cntools_action_wallet_new_cli_run_keygen() {
  local label="${1:-}" verification_file="${2:-}" signing_file="${3:-}"
  local verification_type="${4:-}" signing_type="${5:-}"
  shift 5 || return 1

  [[ "${label}" =~ ^[a-z-]+$ && "${verification_file}" == "${wallet_new_cli_stage}/"* &&
     "${signing_file}" == "${wallet_new_cli_stage}/"* &&
     "${verification_type}" =~ ^[A-Za-z0-9_-]{1,128}$ &&
     "${signing_type}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 70
  println ACTION "cardano-cli wallet-new-cli ${label} key generation"
  if ! "${wallet_new_cli_ccli_path}" "$@" >/dev/null 2>&1; then
    if [[ ( -e "${verification_file}" || -L "${verification_file}" ) &&
          ( ! -f "${verification_file}" || -L "${verification_file}" ) ]] ||
       [[ ( -e "${signing_file}" || -L "${signing_file}" ) &&
          ( ! -f "${signing_file}" || -L "${signing_file}" ) ]]; then
      return 70
    fi
    if [[ -f "${verification_file}" ]] &&
       ! _cntools_action_wallet_new_cli_file_validate \
          "${verification_file}" 16384; then
      return 70
    fi
    if [[ -f "${signing_file}" ]] &&
       ! _cntools_action_wallet_new_cli_file_validate \
          "${signing_file}" 16384; then
      return 70
    fi
    return 1
  fi
  "${wallet_new_cli_chmod_path}" 0600 \
    "${verification_file}" "${signing_file}" >/dev/null 2>&1 || return 70
  _cntools_action_wallet_new_cli_key_validate \
    "${verification_file}" "${verification_type}" || return 70
  _cntools_action_wallet_new_cli_key_validate \
    "${signing_file}" "${signing_type}" || return 70
  _cntools_action_wallet_new_cli_leaf_digest_capture \
    "${verification_file}" || return 70
  _cntools_action_wallet_new_cli_leaf_digest_capture \
    "${signing_file}" || return 70
}

_cntools_action_wallet_new_cli_derive() {
  local output="${1:-}" kind="${2:-}"
  shift 2 || return 1

  [[ "${output}" == "${wallet_new_cli_stage}/"* ]] || return 1
  println ACTION "cardano-cli wallet-new-cli ${kind} derivation"
  "${wallet_new_cli_ccli_path}" "$@" --out-file "${output}" \
    >/dev/null 2>&1 || return 1
  "${wallet_new_cli_chmod_path}" 0600 "${output}" \
    >/dev/null 2>&1 || return 1
  _cntools_action_wallet_new_cli_text_validate "${output}" "${kind}" ||
    return 1
  _cntools_action_wallet_new_cli_leaf_digest_capture "${output}"
}

_cntools_action_wallet_new_cli_prompt() {
  local output_variable="${1:-}" prompted_value=""

  [[ "${output_variable}" == wallet_new_cli_name ]] || return 70
  getAnswerAnyCust prompted_value \
    'Name of wallet (ASCII letters, numbers, underscore and hyphen only)' ||
    return 1
  _cntools_action_wallet_new_cli_name_valid "${prompted_value}" || {
    println ERROR 'ERROR: Invalid wallet name, please retry!'
    waitToProceed
    return 1
  }
  printf -v "${output_variable}" '%s' "${prompted_value}"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local context_mode="" context_network="" network_magic="" filename=""
  local leaf_name="" keygen_status=0 reconcile_status=0
  local action_status=0 cleanup_status=0
  local wallet_new_cli_root="" wallet_new_cli_name=""
  local wallet_new_cli_root_identity=""
  local wallet_new_cli_destination="" wallet_new_cli_stage=""
  local wallet_new_cli_lock="" wallet_new_cli_committed=N
  local wallet_new_cli_lock_identity="" wallet_new_cli_stage_identity=""
  local wallet_new_cli_publish_attempt=N wallet_new_cli_signal_pending=N
  local wallet_new_cli_private_parent=""
  local wallet_new_cli_jq_path="" wallet_new_cli_mktemp_path=""
  local wallet_new_cli_mkdir_path="" wallet_new_cli_chmod_path=""
  local wallet_new_cli_rm_path="" wallet_new_cli_rmdir_path=""
  local wallet_new_cli_mv_path="" wallet_new_cli_find_path=""
  local wallet_new_cli_stat_path="" wallet_new_cli_ccli_path=""
  local wallet_new_cli_hash_path="" wallet_new_cli_hash_kind=""
  local payment_vk="" payment_sk="" stake_vk="" stake_sk=""
  local drep_vk="" drep_sk="" cc_cold_vk="" cc_cold_sk=""
  local cc_hot_vk="" cc_hot_sk="" ms_payment_vk="" ms_payment_sk=""
  local ms_stake_vk="" ms_stake_sk="" ms_drep_vk="" ms_drep_sk=""
  local base_addr_file="" pay_addr_file="" reward_addr_file=""
  local pay_cred_file="" stake_cred_file="" ms_pay_cred_file=""
  local ms_stake_cred_file="" base_addr="" pay_addr=""
  local -a wallet_new_cli_network_args=()
  local -a wallet_new_cli_stage_cleanup_files=()
  local -a wallet_new_cli_private_cleanup_files=()
  local -a wallet_new_cli_expected_leaves=()
  local -A wallet_new_cli_leaf_seen=()
  local -A wallet_new_cli_leaf_digests=()

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
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1; then
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  if [[ "${context_mode}" == local ]] &&
     ! cntools_context_has "${context_file}" capabilities local-cli; then
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi
  for filename in jq mktemp mkdir chmod rm rmdir mv find stat; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq wallet_new_cli_jq_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp wallet_new_cli_mktemp_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir wallet_new_cli_mkdir_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod wallet_new_cli_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_new_cli_rm_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir wallet_new_cli_rmdir_path || action_status=70 ;;
      mv) _cntools_registry_tool_path mv wallet_new_cli_mv_path || action_status=70 ;;
      find) _cntools_registry_tool_path find wallet_new_cli_find_path || action_status=70 ;;
      stat) _cntools_registry_tool_path stat wallet_new_cli_stat_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  if _cntools_registry_tool_path sha256sum wallet_new_cli_hash_path; then
    wallet_new_cli_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum wallet_new_cli_hash_path; then
    wallet_new_cli_hash_kind=shasum
  else
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi
  wallet_new_cli_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${wallet_new_cli_private_parent}" || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  [[ "${WALLET_FOLDER}" == /* ]] || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  _cntools_action_wallet_new_cli_directory_validate \
    "${WALLET_FOLDER}" '700,750,755' || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  wallet_new_cli_root="$(cd -P -- "${WALLET_FOLDER}" && pwd -P)" || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  [[ "${wallet_new_cli_root}" == "${WALLET_FOLDER}" &&
     "${wallet_new_cli_root}" != "${wallet_new_cli_private_parent}" &&
     "${wallet_new_cli_root}" != "${wallet_new_cli_private_parent}/"* &&
     "${wallet_new_cli_private_parent}" != "${wallet_new_cli_root}/"* ]] || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  _cntools_action_wallet_new_cli_directory_identity \
    "${wallet_new_cli_root}" wallet_new_cli_root_identity || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  for filename in "${WALLET_PAY_SK_FILENAME}" "${WALLET_PAY_VK_FILENAME}" \
      "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}" \
      "${WALLET_GOV_DREP_SK_FILENAME}" "${WALLET_GOV_DREP_VK_FILENAME}" \
      "${WALLET_GOV_CC_COLD_SK_FILENAME}" "${WALLET_GOV_CC_COLD_VK_FILENAME}" \
      "${WALLET_GOV_CC_HOT_SK_FILENAME}" "${WALLET_GOV_CC_HOT_VK_FILENAME}" \
      "${WALLET_BASE_ADDR_FILENAME}" "${WALLET_PAY_ADDR_FILENAME}" \
      "${WALLET_STAKE_ADDR_FILENAME}" "${WALLET_PAY_CRED_FILENAME}" \
      "${WALLET_STAKE_CRED_FILENAME}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
      _cntools_action_wallet_new_cli_validation_failure; return 70; }
  done
  [[ "${WALLET_MULTISIG_PREFIX}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }
  wallet_new_cli_expected_leaves=(
    "${WALLET_PAY_SK_FILENAME}" "${WALLET_PAY_VK_FILENAME}"
    "${WALLET_STAKE_SK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"
    "${WALLET_GOV_DREP_SK_FILENAME}" "${WALLET_GOV_DREP_VK_FILENAME}"
    "${WALLET_GOV_CC_COLD_SK_FILENAME}" "${WALLET_GOV_CC_COLD_VK_FILENAME}"
    "${WALLET_GOV_CC_HOT_SK_FILENAME}" "${WALLET_GOV_CC_HOT_VK_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
    "${WALLET_BASE_ADDR_FILENAME}" "${WALLET_PAY_ADDR_FILENAME}"
    "${WALLET_STAKE_ADDR_FILENAME}" "${WALLET_PAY_CRED_FILENAME}"
    "${WALLET_STAKE_CRED_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
    "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"
  )
  for leaf_name in "${wallet_new_cli_expected_leaves[@]}"; do
    [[ "${leaf_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
       -z "${wallet_new_cli_leaf_seen[${leaf_name}]+set}" ]] || {
      _cntools_action_wallet_new_cli_validation_failure; return 70; }
    wallet_new_cli_leaf_seen["${leaf_name}"]=Y
  done
  case "${NETWORK_IDENTIFIER}" in
    --mainnet) wallet_new_cli_network_args=(--mainnet) ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 ]] || {
        _cntools_action_wallet_new_cli_validation_failure; return 70; }
      wallet_new_cli_network_args=(--testnet-magic "${network_magic}")
      ;;
    *) _cntools_action_wallet_new_cli_validation_failure; return 70 ;;
  esac
  if [[ "${context_network}" == mainnet &&
        "${wallet_new_cli_network_args[0]}" != --mainnet ]] ||
     [[ "${context_network}" != mainnet &&
        "${wallet_new_cli_network_args[0]}" != --testnet-magic ]]; then
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi
  _cntools_action_wallet_new_cli_ccli_resolve \
    "${CCLI:-}" wallet_new_cli_ccli_path || {
    _cntools_action_wallet_new_cli_validation_failure; return 70; }

  trap '_cntools_action_wallet_new_cli_cleanup' EXIT
  trap '_cntools_action_wallet_new_cli_signal' HUP INT TERM
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> WALLET >> NEW >> CLI'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  if ! _cntools_action_wallet_new_cli_prompt wallet_new_cli_name; then
    trap - EXIT HUP INT TERM
    return 0
  fi
  wallet_new_cli_destination="${wallet_new_cli_root}/${wallet_new_cli_name}"
  wallet_new_cli_lock="${wallet_new_cli_root}/.${wallet_new_cli_name}.cntools-wallet-new-cli.lock"
  if [[ -e "${wallet_new_cli_destination}" || -L "${wallet_new_cli_destination}" ]]; then
    println "WARN: A wallet ${wallet_new_cli_name} already exists"
    println '      Choose another name or delete the existing one'
    waitToProceed
    trap - EXIT HUP INT TERM
    return 0
  fi
  if ! _cntools_action_wallet_new_cli_root_authority_validate; then
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi
  trap '_cntools_action_wallet_new_cli_defer_signal' HUP INT TERM
  if ! "${wallet_new_cli_mkdir_path}" -m 0700 -- "${wallet_new_cli_lock}" \
      >/dev/null 2>&1; then
    trap '_cntools_action_wallet_new_cli_signal' HUP INT TERM
    if [[ "${wallet_new_cli_signal_pending}" == Y ]]; then
      _cntools_action_wallet_new_cli_signal
    fi
    println ERROR 'ERROR: wallet creation is already in progress, please retry!'
    waitToProceed
    trap - EXIT HUP INT TERM
    return 0
  fi
  _cntools_action_wallet_new_cli_directory_validate \
    "${wallet_new_cli_lock}" 700 || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_directory_identity \
      "${wallet_new_cli_lock}" wallet_new_cli_lock_identity ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_root_authority_validate ||
    action_status=70
  trap '_cntools_action_wallet_new_cli_signal' HUP INT TERM
  if [[ "${wallet_new_cli_signal_pending}" == Y ]]; then
    _cntools_action_wallet_new_cli_signal
  fi
  [[ ! -e "${wallet_new_cli_destination}" &&
     ! -L "${wallet_new_cli_destination}" ]] || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    wallet_new_cli_stage="$("${wallet_new_cli_mktemp_path}" -d \
      "${wallet_new_cli_root}/.${wallet_new_cli_name}.cntools-wallet-new-cli.stage.XXXXXXXX")" ||
      action_status=70
  fi
  [[ "${action_status}" != 0 ]] ||
    "${wallet_new_cli_chmod_path}" 0700 "${wallet_new_cli_stage}" || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_directory_validate "${wallet_new_cli_stage}" 700 ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_directory_identity \
      "${wallet_new_cli_stage}" wallet_new_cli_stage_identity ||
    action_status=70
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_new_cli_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi

  payment_vk="${wallet_new_cli_stage}/${WALLET_PAY_VK_FILENAME}"
  payment_sk="${wallet_new_cli_stage}/${WALLET_PAY_SK_FILENAME}"
  stake_vk="${wallet_new_cli_stage}/${WALLET_STAKE_VK_FILENAME}"
  stake_sk="${wallet_new_cli_stage}/${WALLET_STAKE_SK_FILENAME}"
  drep_vk="${wallet_new_cli_stage}/${WALLET_GOV_DREP_VK_FILENAME}"
  drep_sk="${wallet_new_cli_stage}/${WALLET_GOV_DREP_SK_FILENAME}"
  cc_cold_vk="${wallet_new_cli_stage}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
  cc_cold_sk="${wallet_new_cli_stage}/${WALLET_GOV_CC_COLD_SK_FILENAME}"
  cc_hot_vk="${wallet_new_cli_stage}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
  cc_hot_sk="${wallet_new_cli_stage}/${WALLET_GOV_CC_HOT_SK_FILENAME}"
  ms_payment_vk="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  ms_payment_sk="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
  ms_stake_vk="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  ms_stake_sk="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
  ms_drep_vk="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
  ms_drep_sk="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}"
  for leaf_name in "${wallet_new_cli_expected_leaves[@]}"; do
    wallet_new_cli_stage_cleanup_files+=("${wallet_new_cli_stage}/${leaf_name}")
  done

  _cntools_action_wallet_new_cli_run_keygen payment "${payment_vk}" "${payment_sk}" \
    PaymentVerificationKeyShelley_ed25519 PaymentSigningKeyShelley_ed25519 \
    address key-gen --verification-key-file "${payment_vk}" \
    --signing-key-file "${payment_sk}" || {
      keygen_status=$?
      [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
    }
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_run_keygen stake "${stake_vk}" "${stake_sk}" \
      StakeVerificationKeyShelley_ed25519 StakeSigningKeyShelley_ed25519 \
      latest stake-address key-gen --verification-key-file "${stake_vk}" \
      --signing-key-file "${stake_sk}" || {
        keygen_status=$?
        [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
      }
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_run_keygen drep "${drep_vk}" "${drep_sk}" \
      DRepVerificationKey_ed25519 DRepSigningKey_ed25519 \
      latest governance drep key-gen --verification-key-file "${drep_vk}" \
      --signing-key-file "${drep_sk}" || {
        keygen_status=$?
        [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
      }
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_run_keygen committee-cold \
      "${cc_cold_vk}" "${cc_cold_sk}" \
      ConstitutionalCommitteeColdVerificationKey_ed25519 \
      ConstitutionalCommitteeColdSigningKey_ed25519 \
      latest governance committee key-gen-cold \
      --cold-verification-key-file "${cc_cold_vk}" \
      --cold-signing-key-file "${cc_cold_sk}" || {
        keygen_status=$?
        [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
      }
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_run_keygen committee-hot \
      "${cc_hot_vk}" "${cc_hot_sk}" \
      ConstitutionalCommitteeHotVerificationKey_ed25519 \
      ConstitutionalCommitteeHotSigningKey_ed25519 \
      latest governance committee key-gen-hot \
      --verification-key-file "${cc_hot_vk}" \
      --signing-key-file "${cc_hot_sk}" || {
        keygen_status=$?
        [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
      }
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_run_keygen multisig-payment \
      "${ms_payment_vk}" "${ms_payment_sk}" \
      PaymentVerificationKeyShelley_ed25519 PaymentSigningKeyShelley_ed25519 \
      address key-gen \
      --verification-key-file "${ms_payment_vk}" \
      --signing-key-file "${ms_payment_sk}" || {
        keygen_status=$?
        [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
      }
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_run_keygen multisig-stake \
      "${ms_stake_vk}" "${ms_stake_sk}" \
      StakeVerificationKeyShelley_ed25519 StakeSigningKeyShelley_ed25519 \
      latest stake-address key-gen \
      --verification-key-file "${ms_stake_vk}" \
      --signing-key-file "${ms_stake_sk}" || {
        keygen_status=$?
        [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
      }
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_run_keygen multisig-drep \
      "${ms_drep_vk}" "${ms_drep_sk}" \
      DRepVerificationKey_ed25519 DRepSigningKey_ed25519 \
      latest governance drep key-gen \
      --verification-key-file "${ms_drep_vk}" \
      --signing-key-file "${ms_drep_sk}" || {
        keygen_status=$?
        [[ "${keygen_status}" == 1 ]] && action_status=1 || action_status=70
      }
  if [[ "${action_status}" != 0 ]]; then
    cleanup_status=0
    _cntools_action_wallet_new_cli_cleanup || cleanup_status=$?
    trap - EXIT HUP INT TERM
    if [[ "${action_status}" == 1 && "${cleanup_status}" == 0 ]]; then
      println ERROR 'ERROR: failure during CLI wallet key creation!'
      waitToProceed
      return 0
    fi
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi

  base_addr_file="${wallet_new_cli_stage}/${WALLET_BASE_ADDR_FILENAME}"
  pay_addr_file="${wallet_new_cli_stage}/${WALLET_PAY_ADDR_FILENAME}"
  reward_addr_file="${wallet_new_cli_stage}/${WALLET_STAKE_ADDR_FILENAME}"
  pay_cred_file="${wallet_new_cli_stage}/${WALLET_PAY_CRED_FILENAME}"
  stake_cred_file="${wallet_new_cli_stage}/${WALLET_STAKE_CRED_FILENAME}"
  ms_pay_cred_file="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
  ms_stake_cred_file="${wallet_new_cli_stage}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"
  _cntools_action_wallet_new_cli_derive "${base_addr_file}" base \
    address build --payment-verification-key-file "${payment_vk}" \
    --stake-verification-key-file "${stake_vk}" \
    "${wallet_new_cli_network_args[@]}" || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_derive "${pay_addr_file}" payment \
      address build --payment-verification-key-file "${payment_vk}" \
      "${wallet_new_cli_network_args[@]}" || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_derive "${reward_addr_file}" reward \
      latest stake-address build --stake-verification-key-file "${stake_vk}" \
      "${wallet_new_cli_network_args[@]}" || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_derive "${pay_cred_file}" credential \
      address key-hash --payment-verification-key-file "${payment_vk}" ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_derive "${stake_cred_file}" credential \
      latest stake-address key-hash --stake-verification-key-file "${stake_vk}" ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_derive "${ms_pay_cred_file}" credential \
      address key-hash --payment-verification-key-file "${ms_payment_vk}" ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_derive "${ms_stake_cred_file}" credential \
      latest stake-address key-hash --stake-verification-key-file "${ms_stake_vk}" ||
    action_status=70
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_new_cli_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi

  # Revalidate the exact staged inventory immediately before the publish step.
  _cntools_action_wallet_new_cli_inventory_validate "${wallet_new_cli_stage}" ||
    action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_root_authority_validate || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_lock_authority_validate || action_status=70
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_new_cli_stage_authority_validate || action_status=70
  [[ "${action_status}" != 0 ||
     ( ! -e "${wallet_new_cli_destination}" &&
       ! -L "${wallet_new_cli_destination}" ) ]] || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    base_addr="$(< "${base_addr_file}")"
    pay_addr="$(< "${pay_addr_file}")"
    _cntools_action_wallet_new_cli_terminal_value_valid \
      "${base_addr}" 512 || action_status=70
    _cntools_action_wallet_new_cli_terminal_value_valid \
      "${pay_addr}" 512 || action_status=70
  fi
  if [[ "${action_status}" == 0 ]]; then
    wallet_new_cli_publish_attempt=Y
    trap '_cntools_action_wallet_new_cli_signal' HUP INT TERM
    "${wallet_new_cli_mv_path}" -n -- "${wallet_new_cli_stage}" \
      "${wallet_new_cli_destination}" >/dev/null 2>&1 || action_status=$?
    reconcile_status=0
    _cntools_action_wallet_new_cli_publish_reconcile || reconcile_status=$?
    if [[ "${wallet_new_cli_committed}" == Y ]]; then
      action_status=0
    elif [[ "${reconcile_status}" == 1 && "${action_status}" != 0 ]]; then
      action_status=70
    else
      action_status=70
    fi
  fi
  if [[ "${action_status}" != 0 ]]; then
    if [[ "${wallet_new_cli_committed}" == Y ]]; then
      wallet_new_cli_stage=""
      _cntools_action_wallet_new_cli_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_new_cli_warning
      waitToProceed
      return 0
    fi
    _cntools_action_wallet_new_cli_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_new_cli_validation_failure
    return 70
  fi
  if ! _cntools_action_wallet_new_cli_cleanup; then
    cleanup_status=1
  fi
  trap - EXIT

  println "New Wallet      : ${FG_GREEN}${wallet_new_cli_name}${NC}"
  println "Address         : ${FG_LGRAY}${base_addr}${NC}"
  println "Payment Address : ${FG_LGRAY}${pay_addr}${NC}"
  println DEBUG '\nYou can now send and receive ADA using the above addresses.'
  println DEBUG 'Note that Payment Address will not take part in staking.'
  println DEBUG 'Wallet will be automatically registered on chain if you\nchoose to delegate or pledge wallet when registering a stake pool.'
  [[ "${cleanup_status}" == 0 ]] || _cntools_action_wallet_new_cli_warning
  waitToProceed
  trap - HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
