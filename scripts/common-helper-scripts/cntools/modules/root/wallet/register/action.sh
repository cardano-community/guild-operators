#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154
# Stage 4 hardened compatibility action for wallet stake registration.
# Sourcing defines functions only. The dispatcher supplies an authenticated
# context plus the inherited presentation and wallet-selection surfaces.

_cntools_action_wallet_register_validation_failure() {
  builtin printf '%s\n' 'CNTools wallet-register action failed validation.' >&2
  return 70
}

_cntools_action_wallet_register_callback_dispatch() {
  local callback="${1:-}" fields="${2:-}" keep_ui_fd="${3:-}"
  local callback_status=0 field="" protected_before="" protected_after=""
  local secret_name="" candidate_fd="" candidate_value=""
  local candidate_declaration="" candidate_attributes="" candidate_type=scalar
  local callback_kind=state
  local -a field_names=() secret_names=() authority_fds=()
  shift 3 || return 70

  case "${callback}" in
    clear|println|waitToProceed) callback_kind=presentation ;;
    selectOpMode|selectWallet|select_opt|getWalletType|getTTL|versionCheck|\
      validateMultiSigScript|unlockHWDevice) ;;
    *) return 70 ;;
  esac
  [[ -z "${keep_ui_fd}" ||
     "${keep_ui_fd}" =~ ^([3-9]|[1-9][0-9]+)$ ]] || return 70

  # The inherited functions are outside the action's trust boundary.  Remove
  # every dynamically visible action/dispatcher-private value, including all
  # underlying scopes, then retain an empty type-correct local shadow while the
  # callback runs.  This inventory includes the compatibility dispatcher's
  # generation/snapshot aliases, every non-prefixed main-action local, callback
  # wrapper state, helper path/FD aliases, and credential import temporaries.
  # Callback inputs travel only through "$@" plus the non-secret `op_mode`
  # value required by the inherited getWalletType/getTTL ABI; requested
  # callback outputs are read from empty local shadows and emitted in the
  # bounded record.  Shell mutations remain confined to the callback child.
  secret_names=(
    KOIOS_API_HEADERS header_declaration header_value
    action_id action_relative action_directory action_file action_file_relative
    action_source_relative action_status cleanup_status lock_acquired
    module_file module_path module_relative module_source_relative
    payload payload_file payload_path
    receipt metadata state_root generation_id generation generation_manifest
    generation_receipt lifecycle expected_lifecycle_hash receipt_hash
    metadata_hash current_receipt_hash current_metadata_hash
    current_generation_id context_mode context_network context_file context_path
    result_file result_path private_parent private_root node_home_physical
    source_module source_action snapshot_directory snapshot_module
    snapshot_action snapshot_mnemonic_sidecar expected_module_hash
    expected_action_hash expected_context_hash mnemonic_sidecar_required
    legacy_bundle_id legacy_bundle_relative mnemonic_member_relative
    mnemonic_member_source_relative source_mnemonic_sidecar
    expected_mnemonic_hash expected_mnemonic_size mnemonic_metadata
    receipt_mnemonic_hash mnemonic_before_functions mnemonic_before_variables
    jq_path mktemp_path mkdir_path cp_path chmod_path rm_path rmdir_path bash_path
    presentation_ui_fd status output_name callback_ui_fd record
    network_magic filename selection_status wallet_type_status query_status
    phase_status tool_status found target wallet_name ttl ttl_enter
    required_total metadata mode size identity links leaf
    base_addr pay_addr reward_addr tx_ref asset quantity tx_out formatted
    witness_count payment_vk_file payment_sk_file payment_script_file
    stake_vk_file stake_sk_file stake_script_file expected_payment_sk_file
    expected_stake_sk_file certificate_fd draft_fd raw_fd protocol_fd payment_fd
    stake_fd witness_payment_fd witness_stake_fd signed_fd payment_script_fd
    stake_script_fd selected_value build_arguments command_arguments
    witness_arguments
    body_fd output_fd log_fd headers_fd request_fd write_fd read_fd verify_fd
    digest_fd jq_fd published_fd rebind_fd acceptance_fd input_fd check_fd
    hardware_fd response_writer_fd response_reader_fd response_hash_fd
    tool_output_fd tool_log_fd submit_request_fd tx_fd offline_fd pay_fd
    payment_output_fd stake_output_fd payment_vk_fd stake_vk_fd
    payment_script_fd stake_script_fd
    path fd fd_path parent parent_identity destination expected_identity
    expected_mode minimum maximum expected_links expected_mode expected_size
    expected_hash actual_hash actual metadata_file manifest_file source_path
    target_path directory runtime_root scripts node lifecycle_file
    LC_ALL
  )
  while IFS= builtin read -r secret_name; do
    [[ -n "${secret_name}" ]] || continue
    secret_names+=("${secret_name}")
    case "${secret_name}" in
      wallet_register_*_fd)
        candidate_value="${!secret_name-}"
        [[ -z "${candidate_value}" ||
           "${candidate_value}" =~ ^([3-9]|[1-9][0-9]+)$ ]] || return 70
        [[ -z "${candidate_value}" ]] || authority_fds+=("${candidate_value}")
        ;;
    esac
  done < <(builtin compgen -A variable 'wallet_register_')

  # Close only descriptors owned by the action.  Closing every /dev/fd entry
  # would also close Bash 4.4's private redirection-restoration descriptors.
  # Aliases such as payment_fd are shadowed below; their authenticated action
  # descriptor is represented in this authority list.
  for candidate_fd in "${authority_fds[@]}"; do
    [[ "${candidate_fd}" == "${keep_ui_fd}" ]] && continue
    [[ -e "/dev/fd/${candidate_fd}" ]] || continue
    exec {candidate_fd}>&- || return 70
  done
  for secret_name in "${secret_names[@]}"; do
    [[ "${secret_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 70
    candidate_type=scalar
    if candidate_declaration="$(
        builtin declare -p "${secret_name}" 2>/dev/null
      )"; then
      candidate_attributes="${candidate_declaration#declare -}"
      candidate_attributes="${candidate_attributes%% *}"
      case "${candidate_attributes}" in
        *A*) candidate_type=associative ;;
        *a*) candidate_type=indexed ;;
      esac
    fi
    while builtin declare -p "${secret_name}" >/dev/null 2>&1; do
      builtin unset -v "${secret_name}" || return 70
    done
    case "${candidate_type}" in
      associative) builtin local -A "${secret_name}" || return 70 ;;
      indexed) builtin local -a "${secret_name}" || return 70 ;;
      scalar) builtin local "${secret_name}=" || return 70 ;;
      *) return 70 ;;
    esac
  done
  candidate_declaration=""
  candidate_attributes=""
  candidate_value=""

  protected_before="$(_cntools_action_wallet_register_callback_protected_state)" ||
    return 70
  if [[ -n "${keep_ui_fd}" ]]; then
    "${callback}" "$@" 1>&"${keep_ui_fd}" || callback_status=$?
  else
    "${callback}" "$@" || callback_status=$?
  fi
  protected_after="$(_cntools_action_wallet_register_callback_protected_state)" ||
    return 70
  [[ "${protected_after}" == "${protected_before}" ]] || return 70
  [[ "${callback_kind}" != presentation ]] || return "${callback_status}"

  [[ -z "${fields}" ]] || IFS=',' builtin read -r -a field_names <<< "${fields}"
  builtin printf '%s' "${callback_status}"
  for field in "${field_names[@]}"; do
    [[ "${field}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 70
    builtin printf '\034%s' "${!field-}"
  done
}

_cntools_action_wallet_register_present() {
  local callback="${1:-}" presentation_ui_fd="" status=0
  shift || return 70

  case "${callback}" in
    clear|println|waitToProceed) ;;
    *) return 70 ;;
  esac
  exec {presentation_ui_fd}>&1 || return 70
  ( _cntools_action_wallet_register_callback_dispatch \
    "${callback}" '' "${presentation_ui_fd}" "$@" ) || status=$?
  exec {presentation_ui_fd}>&- || status=70
  _cntools_action_wallet_register_callback_boundary_verify || status=70
  return "${status}"
}

_cntools_action_wallet_register_submission_authority_reset() {
  wallet_register_committed=N
  wallet_register_submit_authority=N
  wallet_register_submit_started=N
  wallet_register_submit_rejected=N
  wallet_register_submit_ambiguous=N
  wallet_register_submission_ambiguous=N
  wallet_register_postcommit_warning=N
  wallet_register_acceptance_reconciled=N
  wallet_register_reconciliation_attempted=N
  wallet_register_submit_failure_status=21
}

_cntools_action_wallet_register_callback_protected_state() {
  local name=""

  for name in ${!wallet_register_@}; do
    builtin declare -p "${name}" || return 70
  done
  while IFS= builtin read -r name; do
    [[ -n "${name}" ]] || continue
    builtin declare -f "${name}" || return 70
  done < <(builtin compgen -A function '_cntools_action_wallet_register_')
}

_cntools_action_wallet_register_callback_filesystem_same() {
  local metadata="" digest=""

  [[ "${wallet_register_callback_boundary_active:-N}" == Y &&
     -n "${wallet_register_callback_result_path:-}" &&
     -n "${wallet_register_callback_context_path:-}" &&
     -n "${wallet_register_callback_private_parent:-}" ]] || return 70
  _cntools_action_wallet_register_runtime_tools_same stat hash || return 70
  [[ ! -e "${wallet_register_callback_result_path}" &&
     ! -L "${wallet_register_callback_result_path}" ]] || return 70
  _cntools_action_wallet_register_directory_identity \
    "${wallet_register_callback_private_parent}" 700 \
    wallet_register_callback_check_parent_identity || return 70
  [[ "${wallet_register_callback_check_parent_identity}" == \
     "${wallet_register_callback_private_parent_identity}" ]] || return 70
  _cntools_action_wallet_register_path_metadata \
    "${wallet_register_callback_context_path}" '400,600' 1 1048576 1 \
    wallet_register_callback_check_context_metadata || return 70
  metadata="${wallet_register_callback_check_context_metadata}"
  [[ "${metadata}" == "${wallet_register_callback_context_metadata}" ]] ||
    return 70
  _cntools_action_wallet_register_hash_path \
    "${wallet_register_callback_context_path}" \
    wallet_register_callback_check_context_digest || return 70
  digest="${wallet_register_callback_check_context_digest}"
  [[ "${digest}" == "${wallet_register_callback_context_digest}" ]]
}

_cntools_action_wallet_register_callback_boundary_verify() {
  if _cntools_action_wallet_register_callback_filesystem_same; then
    return 0
  fi
  wallet_register_callback_violation=Y
  if [[ -n "${wallet_register_callback_result_path:-}" &&
        ( -e "${wallet_register_callback_result_path}" ||
          -L "${wallet_register_callback_result_path}" ) &&
        ( ! -d "${wallet_register_callback_result_path}" ||
          -L "${wallet_register_callback_result_path}" ) ]] &&
     _cntools_action_wallet_register_runtime_tools_same rm; then
    "${wallet_register_rm_path}" -f -- \
      "${wallet_register_callback_result_path}" >/dev/null 2>&1 || builtin true
    _cntools_action_wallet_register_runtime_tools_same rm || return 70
  fi
  return 70
}

_cntools_action_wallet_register_callback_isolated() {
  local output_name="${1:-}" callback="${2:-}" fields="${3:-}"
  local callback_ui_fd="" record="" status=0
  shift 3 || return 70

  [[ "${output_name}" == wallet_register_callback_record ]] || return 70
  case "${callback}" in
    selectOpMode|selectWallet|select_opt|getWalletType|getTTL|versionCheck|\
      validateMultiSigScript|unlockHWDevice)
      ;;
    *) return 70 ;;
  esac
  exec {callback_ui_fd}>&1 || return 70
  record="$(_cntools_action_wallet_register_callback_dispatch \
    "${callback}" "${fields}" "${callback_ui_fd}" "$@")" || status=70
  exec {callback_ui_fd}>&- || status=70
  _cntools_action_wallet_register_callback_boundary_verify || status=70
  (( status == 0 )) || return 70
  [[ "${record}" != *$'\n'* && "${record}" != *$'\r'* ]] || return 70
  builtin printf -v "${output_name}" '%s' "${record}"
}

_cntools_action_wallet_register_component_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. &&
     ! "${value}" =~ [[:cntrl:]] ]]
}

_cntools_action_wallet_register_leaf_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_register_paths_disjoint() {
  local left="${1:-}" right="${2:-}"

  [[ -n "${left}" && -n "${right}" && "${left}" != "${right}" &&
     "${left}" != "${right}/"* && "${right}" != "${left}/"* ]]
}

_cntools_action_wallet_register_uint_valid() {
  local value="${1:-}" maximum="${2:-45000000000000000}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${maximum}" =~ ^[1-9][0-9]{0,17}$ ]] || return 1
  (( ${#value} < ${#maximum} )) && return 0
  (( ${#value} == ${#maximum} )) || return 1
  [[ "${value}" == "${maximum}" || "${value}" < "${maximum}" ]]
}

_cntools_action_wallet_register_uint_add() {
  local left="${1:-}" right="${2:-}" output_name="${3:-}" value=0

  [[ "${output_name}" =~ ^wallet_register_(base_lovelace|asset_total)$ ]] ||
    return 1
  _cntools_action_wallet_register_uint_valid "${left}" &&
    _cntools_action_wallet_register_uint_valid "${right}" || return 1
  value=$((left + right))
  (( value >= left && value >= right )) || return 1
  _cntools_action_wallet_register_uint_valid "${value}" || return 1
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_register_epoch_add() {
  local epoch="${1:-}" duration="${2:-}" output_name="${3:-}"
  local value=0

  [[ "${epoch}" =~ ^(0|[1-9][0-9]{0,11})$ &&
     "${duration}" =~ ^[1-9][0-9]{0,9}$ &&
     "${output_name}" == wallet_register_expiry_epoch ]] || return 1
  (( 10#${epoch} <= 253402300799 &&
     10#${duration} <= 2147483647 &&
     10#${epoch} <= 253402300799 - 10#${duration} )) || return 1
  value=$((10#${epoch} + 10#${duration}))
  (( value > 10#${epoch} && value <= 253402300799 )) || return 1
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_register_address_valid() {
  local kind="${1:-}" value="${2:-}"

  [[ "${#value}" -le 256 ]] || return 1
  case "${kind}" in
    base|payment)
      [[ "${value}" =~ ^addr(_test)?1[023456789ac-hj-np-z]{20,200}$ ]]
      ;;
    reward)
      [[ "${value}" =~ ^stake(_test)?1[023456789ac-hj-np-z]{20,200}$ ]]
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_wallet_register_stat() {
  local target="${1:-}" metadata=""

  [[ -n "${wallet_register_stat_path:-}" ]] || return 1
  if metadata="$("${wallet_register_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' "${target}" 2>/dev/null)"; then
    builtin printf '%s\n' "${metadata}"
    return 0
  fi
  "${wallet_register_stat_path}" -c $'%u\t%a\t%h\t%s\t%d\t%i' \
    -- "${target}" 2>/dev/null
}

_cntools_action_wallet_register_directory_identity() {
  local target="${1:-}" modes="${2:-}" output_name="${3:-}"
  local metadata="" owner="" mode="" links="" size="" device="" inode=""

  [[ "${output_name}" =~ ^wallet_register_(root|wallet|tmp|lock|stage|check|callback_(private_parent|check_parent))_identity$ &&
     -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_register_stat "${target}")" || return 1
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && ",${modes}," == *",${mode},"* &&
     "${links}" =~ ^[1-9][0-9]*$ && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]] || return 1
  builtin printf -v "${output_name}" '%s:%s:%s' \
    "${device}" "${inode}" "${mode}"
}

_cntools_action_wallet_register_directory_same() {
  local target="${1:-}" expected="${2:-}" modes="${3:-}" actual=""

  _cntools_action_wallet_register_directory_identity \
    "${target}" "${modes}" wallet_register_check_identity || return 1
  actual="${wallet_register_check_identity}"
  [[ "${actual}" == "${expected}" ]]
}

_cntools_action_wallet_register_path_metadata() {
  local target="${1:-}" modes="${2:-}" minimum="${3:-}"
  local maximum="${4:-}" links_allowed="${5:-1}" output_name="${6:-}"
  local metadata="" owner="" mode="" links="" size="" device="" inode=""

  [[ "${minimum}" =~ ^[0-9]+$ && "${maximum}" =~ ^[0-9]+$ &&
     "${minimum}" -le "${maximum}" &&
     "${links_allowed}" =~ ^(1|2|1\|2)$ &&
     "${output_name}" =~ ^wallet_register_[A-Za-z0-9_]+$ &&
     -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_register_stat "${target}")" || return 1
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && ",${modes}," == *",${mode},"* &&
     "${size}" =~ ^[0-9]+$ && "${size}" -ge "${minimum}" &&
     "${size}" -le "${maximum}" && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]] || return 1
  case "${links_allowed}" in
    1|2) [[ "${links}" == "${links_allowed}" ]] || return 1 ;;
    '1|2') [[ "${links}" == 1 || "${links}" == 2 ]] || return 1 ;;
  esac
  builtin printf -v "${output_name}" '%s\t%s\t%s:%s\t%s' \
    "${mode}" "${size}" "${device}" "${inode}" "${links}"
}

_cntools_action_wallet_register_descriptor_same() {
  local fd="${1:-}" expected_identity="${2:-}" expected_mode="${3:-}"
  local minimum="${4:-}" maximum="${5:-}" expected_links="${6:-1}"
  local metadata="" owner="" mode="" links="" size="" device="" inode=""
  local fd_path="/dev/fd/${fd}"

  [[ "${fd}" =~ ^[1-9][0-9]*$ &&
     "${expected_identity}" =~ ^[0-9]+:[0-9]+$ &&
     "${expected_mode}" =~ ^[0-7]{3,4}$ &&
     "${minimum}" =~ ^[0-9]+$ && "${maximum}" =~ ^[0-9]+$ &&
     "${expected_links}" =~ ^[012]$ ]] || return 1
  [[ -f "${fd_path}" ]] || return 1
  if metadata="$("${wallet_register_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' <&"${fd}" 2>/dev/null)"; then
    :
  else
    metadata="$("${wallet_register_stat_path}" -c \
      $'%u\t%a\t%h\t%s\t%d\t%i' -- "${fd_path}" 2>/dev/null)" || return 1
  fi
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == "${expected_mode#0}" &&
     "${links}" == "${expected_links}" && "${size}" =~ ^[0-9]+$ &&
     "${size}" -ge "${minimum}" && "${size}" -le "${maximum}" &&
     "${device}:${inode}" == "${expected_identity}" && -f "${fd_path}" ]]
}

_cntools_action_wallet_register_open_bound() {
  local target="${1:-}" expected_identity="${2:-}" expected_mode="${3:-}"
  local minimum="${4:-}" maximum="${5:-}" expected_links="${6:-1}"
  local output_name="${7:-}" fd=""

  [[ "${output_name}" =~ ^wallet_register_[A-Za-z0-9_]*fd$ ]] || return 1
  # All action-created leaves and accepted wallet inputs are owner-writable.
  # O_RDWR makes a raced FIFO nonblocking; descriptor authentication then
  # rejects every non-regular or wrong inode before a consumer sees it.
  exec {fd}<> "${target}" || return 1
  if ! _cntools_action_wallet_register_descriptor_same "${fd}" \
      "${expected_identity}" "${expected_mode}" "${minimum}" "${maximum}" \
      "${expected_links}"; then
    exec {fd}>&-
    return 1
  fi
  builtin printf -v "${output_name}" '%s' "${fd}"
}

_cntools_action_wallet_register_hash_fd() {
  local fd="${1:-}" expected_identity="${2:-}" expected_mode="${3:-}"
  local minimum="${4:-}" maximum="${5:-}" expected_links="${6:-1}"
  local output_name="${7:-}" digest=""

  [[ "${output_name}" =~ ^wallet_register_[A-Za-z0-9_]+$ ]] || return 1
  case "${wallet_register_hash_kind}" in
    sha256sum)
      digest="$("${wallet_register_hash_path}" "/dev/fd/${fd}" 2>/dev/null)" ||
        return 1
      ;;
    shasum)
      digest="$("${wallet_register_hash_path}" -a 256 \
        "/dev/fd/${fd}" 2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  _cntools_action_wallet_register_descriptor_same "${fd}" \
    "${expected_identity}" "${expected_mode}" "${minimum}" "${maximum}" \
    "${expected_links}" || return 1
  builtin printf -v "${output_name}" '%s' "${digest}"
}

_cntools_action_wallet_register_hash_path() {
  local target="${1:-}" output_name="${2:-}" digest=""

  [[ "${output_name}" =~ ^wallet_register_[A-Za-z0-9_]+$ ]] || return 1
  case "${wallet_register_hash_kind}" in
    sha256sum)
      digest="$("${wallet_register_hash_path}" "${target}" 2>/dev/null)" ||
        return 1
      ;;
    shasum)
      digest="$("${wallet_register_hash_path}" -a 256 "${target}" \
        2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  builtin printf -v "${output_name}" '%s' "${digest}"
}

_cntools_action_wallet_register_executable_capture() {
  local target="${1:-}" key="${2:-}" metadata="" repeated=""
  local owner="" mode="" links="" size="" device="" inode="" digest=""

  [[ "${key}" =~ ^(ccli|hwcli|curl|jq|mkdir|rmdir|rm|ln|find|sort|stat|date|hash)$ &&
     -f "${target}" &&
     -x "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_register_stat "${target}")" || return 1
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ ( "${owner}" == 0 || "${owner}" == "${EUID}" ) &&
     "${mode}" =~ ^[1357][0145][0145]$ &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 134217728 &&
     "${device}" =~ ^[0-9]+$ && "${inode}" =~ ^[0-9]+$ ]] || return 1
  if [[ "${owner}" == 0 ]]; then
    [[ "${links}" =~ ^([1-9]|1[0-6])$ ]] || return 1
  else
    [[ "${owner}" == "${EUID}" && "${links}" == 1 ]] || return 1
  fi
  _cntools_action_wallet_register_hash_path "${target}" \
    wallet_register_tool_digest || return 1
  digest="${wallet_register_tool_digest}"
  repeated="$(_cntools_action_wallet_register_stat "${target}")" || return 1
  [[ "${repeated}" == "${metadata}" && -f "${target}" && -x "${target}" &&
     ! -L "${target}" ]] || return 1
  wallet_register_tool_paths["${key}"]="${target}"
  wallet_register_tool_metadata["${key}"]="${owner}:${mode}:${links}:${size}:${device}:${inode}"
  wallet_register_tool_digests["${key}"]="${digest}"
}

_cntools_action_wallet_register_executable_same() {
  local key="${1:-}" target="" metadata="" owner="" mode="" links=""
  local size="" device="" inode="" normalized="" digest="" repeated=""

  [[ -n "${wallet_register_tool_paths[${key}]+set}" ]] || return 1
  target="${wallet_register_tool_paths[${key}]}"
  [[ -f "${target}" && -x "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_register_stat "${target}")" || return 1
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  normalized="${owner}:${mode}:${links}:${size}:${device}:${inode}"
  [[ "${normalized}" == "${wallet_register_tool_metadata[${key}]}" ]] ||
    return 1
  _cntools_action_wallet_register_hash_path "${target}" \
    wallet_register_tool_digest || return 1
  digest="${wallet_register_tool_digest}"
  [[ "${digest}" == "${wallet_register_tool_digests[${key}]}" ]] || return 1
  repeated="$(_cntools_action_wallet_register_stat "${target}")" || return 1
  [[ "${repeated}" == "${metadata}" ]]
}

_cntools_action_wallet_register_runtime_tools_same() {
  local key=""

  for key in stat hash "$@"; do
    _cntools_action_wallet_register_executable_same "${key}" || return 1
  done
}

_cntools_action_wallet_register_capture_input() {
  local target="${1:-}" key="${2:-}" maximum="${3:-65536}"
  local modes="${4:-600,640,644}" metadata="" mode="" size=""
  local identity="" links="" fd="" digest=""

  [[ "${key}" =~ ^[a-z][a-z0-9_]*$ &&
     "${modes}" =~ ^600(,640,644)?$ ]] || return 1
  _cntools_action_wallet_register_path_metadata "${target}" "${modes}" \
    1 "${maximum}" 1 wallet_register_metadata || return 1
  metadata="${wallet_register_metadata}"
  IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" || return 1
  _cntools_action_wallet_register_open_bound "${target}" "${identity}" \
    "${mode}" 1 "${maximum}" 1 wallet_register_input_fd || return 1
  fd="${wallet_register_input_fd}"
  _cntools_action_wallet_register_hash_fd "${fd}" "${identity}" "${mode}" \
    1 "${maximum}" 1 wallet_register_input_digest || {
      exec {fd}>&-
      return 1
    }
  digest="${wallet_register_input_digest}"
  exec {fd}>&-
  wallet_register_input_paths["${key}"]="${target}"
  wallet_register_input_modes["${key}"]="${mode}"
  wallet_register_input_identities["${key}"]="${identity}"
  wallet_register_input_digests["${key}"]="${digest}"
  wallet_register_input_maximums["${key}"]="${maximum}"
}

_cntools_action_wallet_register_input_open() {
  local key="${1:-}" output_name="${2:-}" path="" mode="" identity=""
  local maximum="" fd="" verify_fd="" digest=""

  [[ -n "${wallet_register_input_paths[${key}]+set}" ]] || return 1
  path="${wallet_register_input_paths[${key}]}"
  mode="${wallet_register_input_modes[${key}]}"
  identity="${wallet_register_input_identities[${key}]}"
  maximum="${wallet_register_input_maximums[${key}]}"
  _cntools_action_wallet_register_open_bound "${path}" "${identity}" \
    "${mode}" 1 "${maximum}" 1 "${output_name}" || return 1
  fd="${!output_name}"
  wallet_register_verify_fd=""
  _cntools_action_wallet_register_open_bound "${path}" "${identity}" \
    "${mode}" 1 "${maximum}" 1 wallet_register_verify_fd || {
      exec {fd}>&-
      return 1
    }
  verify_fd="${wallet_register_verify_fd}"
  _cntools_action_wallet_register_hash_fd "${verify_fd}" "${identity}" "${mode}" \
    1 "${maximum}" 1 wallet_register_check_digest || {
      exec {verify_fd}>&-
      exec {fd}>&-
      return 1
    }
  exec {verify_fd}>&-
  digest="${wallet_register_check_digest}"
  [[ "${digest}" == "${wallet_register_input_digests[${key}]}" ]] || {
    exec {fd}>&-
    return 1
  }
}

_cntools_action_wallet_register_input_read() {
  local key="${1:-}" output_name="${2:-}" fd="" verify_fd="" value=""

  [[ "${output_name}" =~ ^(base_addr|pay_addr|reward_addr|wallet_register_script_(payment|stake))$ ]] ||
    return 1
  wallet_register_rebind_fd=""
  _cntools_action_wallet_register_input_open \
    "${key}" wallet_register_read_fd || return 1
  fd="${wallet_register_read_fd}"
  value="$(< "/dev/fd/${fd}")"
  _cntools_action_wallet_register_descriptor_same "${fd}" \
    "${wallet_register_input_identities[${key}]}" \
    "${wallet_register_input_modes[${key}]}" 1 \
    "${wallet_register_input_maximums[${key}]}" 1 || {
      exec {fd}>&-
      return 1
  }
  exec {fd}>&-
  _cntools_action_wallet_register_input_open \
    "${key}" wallet_register_check_fd || return 1
  verify_fd="${wallet_register_check_fd}"
  exec {verify_fd}>&-
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_register_input_close_verified() {
  local key="${1:-}" fd="${2:-}" verify_fd="" status=0

  [[ "${fd}" =~ ^[1-9][0-9]*$ &&
     -n "${wallet_register_input_paths[${key}]+set}" ]] || return 1
  _cntools_action_wallet_register_descriptor_same "${fd}" \
    "${wallet_register_input_identities[${key}]}" \
    "${wallet_register_input_modes[${key}]}" 1 \
    "${wallet_register_input_maximums[${key}]}" 1 || status=1
  _cntools_action_wallet_register_input_open \
    "${key}" wallet_register_rebind_fd || status=1
  verify_fd="${wallet_register_rebind_fd:-}"
  [[ -z "${verify_fd}" ]] || exec {verify_fd}>&-
  exec {fd}>&-
  return "${status}"
}

_cntools_action_wallet_register_stage_leaf_create() {
  local leaf="${1:-}" path="" metadata="" mode="" size="" identity="" links=""

  _cntools_action_wallet_register_leaf_valid "${leaf}" || return 1
  [[ -z "${wallet_register_stage_identities[${leaf}]+set}" ]] || return 1
  path="${wallet_register_stage}/${leaf}"
  [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
  (builtin umask 077
    builtin set -o noclobber
    : > "${path}") 2>/dev/null || return 1
  _cntools_action_wallet_register_path_metadata "${path}" 600 0 0 1 \
    wallet_register_metadata || return 1
  metadata="${wallet_register_metadata}"
  IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" || return 1
  wallet_register_stage_identities["${leaf}"]="${identity}"
  wallet_register_stage_leaves+=("${leaf}")
}

_cntools_action_wallet_register_stage_open() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}"
  local output_name="${4:-}" expected_links="${5:-1}"
  local path="${wallet_register_stage}/${leaf}"

  [[ -n "${wallet_register_stage_identities[${leaf}]+set}" ]] || return 1
  _cntools_action_wallet_register_open_bound "${path}" \
    "${wallet_register_stage_identities[${leaf}]}" 600 \
    "${minimum}" "${maximum}" "${expected_links}" "${output_name}"
}

_cntools_action_wallet_register_stage_hash() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}"
  local output_name="${4:-}" expected_links="${5:-1}" fd=""

  wallet_register_digest_fd=""
  _cntools_action_wallet_register_stage_open "${leaf}" "${minimum}" \
    "${maximum}" wallet_register_digest_fd "${expected_links}" || return 1
  fd="${wallet_register_digest_fd}"
  _cntools_action_wallet_register_hash_fd "${fd}" \
    "${wallet_register_stage_identities[${leaf}]}" 600 \
    "${minimum}" "${maximum}" "${expected_links}" "${output_name}" || {
      exec {fd}>&-
      return 1
    }
  exec {fd}>&-
}

_cntools_action_wallet_register_stage_capture() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}" digest=""

  wallet_register_capture_digest=""
  _cntools_action_wallet_register_stage_hash "${leaf}" "${minimum}" \
    "${maximum}" wallet_register_capture_digest || return 1
  digest="${wallet_register_capture_digest}"
  wallet_register_stage_digests["${leaf}"]="${digest}"
}

_cntools_action_wallet_register_stage_rebind() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}" fd=""

  wallet_register_rebind_fd=""
  _cntools_action_wallet_register_stage_open "${leaf}" "${minimum}" \
    "${maximum}" wallet_register_rebind_fd || return 1
  fd="${wallet_register_rebind_fd}"
  exec {fd}>&-
}

_cntools_action_wallet_register_stage_close_verified() {
  local leaf="${1:-}" fd="${2:-}" minimum="${3:-}" maximum="${4:-}"
  local digest="" status=0

  [[ "${fd}" =~ ^[1-9][0-9]*$ &&
     -n "${wallet_register_stage_digests[${leaf}]+set}" ]] || return 1
  _cntools_action_wallet_register_descriptor_same "${fd}" \
    "${wallet_register_stage_identities[${leaf}]}" 600 \
    "${minimum}" "${maximum}" 1 || status=1
  wallet_register_close_digest=""
  _cntools_action_wallet_register_stage_hash "${leaf}" "${minimum}" \
    "${maximum}" wallet_register_close_digest || status=1
  digest="${wallet_register_close_digest:-}"
  [[ "${digest}" == "${wallet_register_stage_digests[${leaf}]}" ]] || status=1
  exec {fd}>&-
  return "${status}"
}

_cntools_action_wallet_register_stage_verify() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}" digest=""

  [[ -n "${wallet_register_stage_digests[${leaf}]+set}" ]] || return 1
  wallet_register_close_digest=""
  _cntools_action_wallet_register_stage_hash "${leaf}" "${minimum}" \
    "${maximum}" wallet_register_close_digest || return 1
  digest="${wallet_register_close_digest}"
  [[ "${digest}" == "${wallet_register_stage_digests[${leaf}]}" ]]
}

_cntools_action_wallet_register_response_hash() {
  local output_name="${1:-}" digest=""

  [[ "${output_name}" == wallet_register_response_check_digest ]] || return 1
  _cntools_action_wallet_register_runtime_tools_same hash || return 1
  case "${wallet_register_hash_kind}" in
    sha256sum)
      digest="$(builtin printf '%s' "${wallet_register_response_value}" |
        "${wallet_register_hash_path}" 2>/dev/null)" || return 1
      ;;
    shasum)
      digest="$(builtin printf '%s' "${wallet_register_response_value}" |
        "${wallet_register_hash_path}" -a 256 2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  _cntools_action_wallet_register_runtime_tools_same hash || return 1
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  builtin printf -v "${output_name}" '%s' "${digest}"
}

_cntools_action_wallet_register_response_same() {
  [[ "${wallet_register_response_leaf:-}" =~ ^(utxo\.json|stake\.json|submit\.out|verify\.out)$ &&
     "${wallet_register_response_digest:-}" =~ ^[0-9a-f]{64}$ &&
     "${wallet_register_response_raw_digest:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  wallet_register_response_check_digest=""
  _cntools_action_wallet_register_response_hash \
    wallet_register_response_check_digest || return 1
  [[ "${wallet_register_response_check_digest}" == \
     "${wallet_register_response_digest}" ]]
}

_cntools_action_wallet_register_response_descriptors_same() {
  local minimum="${1:-0}" maximum="${2:-1048576}"

  [[ "${wallet_register_response_writer_fd:-}" =~ ^[1-9][0-9]*$ &&
     "${wallet_register_response_reader_fd:-}" =~ ^[1-9][0-9]*$ &&
     "${wallet_register_response_hash_fd:-}" =~ ^[1-9][0-9]*$ &&
     "${wallet_register_response_identity:-}" =~ ^[0-9]+:[0-9]+$ &&
     "${wallet_register_response_unlinked:-N}" == Y ]] || return 1
  _cntools_action_wallet_register_descriptor_same \
    "${wallet_register_response_writer_fd}" \
    "${wallet_register_response_identity}" 600 "${minimum}" "${maximum}" 0 ||
    return 1
  _cntools_action_wallet_register_descriptor_same \
    "${wallet_register_response_reader_fd}" \
    "${wallet_register_response_identity}" 600 "${minimum}" "${maximum}" 0 ||
    return 1
  _cntools_action_wallet_register_descriptor_same \
    "${wallet_register_response_hash_fd}" \
    "${wallet_register_response_identity}" 600 "${minimum}" "${maximum}" 0
}

_cntools_action_wallet_register_response_clear() {
  local status=0

  if [[ -n "${wallet_register_response_writer_fd:-}" ]]; then
    exec {wallet_register_response_writer_fd}>&- || status=1
  fi
  if [[ -n "${wallet_register_response_reader_fd:-}" ]]; then
    exec {wallet_register_response_reader_fd}>&- || status=1
  fi
  if [[ -n "${wallet_register_response_hash_fd:-}" ]]; then
    exec {wallet_register_response_hash_fd}>&- || status=1
  fi
  wallet_register_response_writer_fd=""
  wallet_register_response_reader_fd=""
  wallet_register_response_hash_fd=""
  if [[ "${wallet_register_response_unlinked:-N}" == Y &&
        -n "${wallet_register_response_leaf:-}" ]]; then
    unset 'wallet_register_stage_identities['"${wallet_register_response_leaf}"']'
    unset 'wallet_register_stage_digests['"${wallet_register_response_leaf}"']'
  fi
  wallet_register_response_unlinked=N
  wallet_register_response_identity=""
  wallet_register_response_leaf=""
  wallet_register_response_value=""
  wallet_register_response_digest=""
  wallet_register_response_raw_digest=""
  wallet_register_response_check_digest=""
  return "${status}"
}

_cntools_action_wallet_register_response_open() {
  local leaf="${1:-}" status=0

  [[ "${leaf}" =~ ^(utxo\.json|stake\.json|submit\.out|verify\.out)$ ]] ||
    return 70
  _cntools_action_wallet_register_response_clear || return 70
  if [[ -z "${wallet_register_stage_identities[${leaf}]+set}" ]]; then
    _cntools_action_wallet_register_stage_leaf_create "${leaf}" || return 70
  fi
  wallet_register_response_leaf="${leaf}"
  _cntools_action_wallet_register_stage_open "${leaf}" 0 0 \
    wallet_register_response_writer_fd || return 70
  _cntools_action_wallet_register_stage_open "${leaf}" 0 0 \
    wallet_register_response_reader_fd || status=70
  if (( status == 0 )); then
    _cntools_action_wallet_register_stage_open "${leaf}" 0 0 \
      wallet_register_response_hash_fd || status=70
  fi
  wallet_register_response_identity="${wallet_register_stage_identities[${leaf}]:-}"
  if (( status == 0 )); then
    _cntools_action_wallet_register_runtime_tools_same rm || status=70
  fi
  if (( status == 0 )); then
    "${wallet_register_rm_path}" -f -- "${wallet_register_stage}/${leaf}" \
      >/dev/null 2>&1 || status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same rm || status=70
  [[ ! -e "${wallet_register_stage}/${leaf}" &&
     ! -L "${wallet_register_stage}/${leaf}" ]] || status=70
  if (( status == 0 )); then
    wallet_register_response_unlinked=Y
    _cntools_action_wallet_register_response_descriptors_same 0 0 || status=70
  fi
  [[ "${wallet_register_signal_pending}" == N ]] || status=70
  return "${status}"
}

_cntools_action_wallet_register_response_capture() {
  local minimum="${1:-0}" maximum="${2:-1048576}" status=0 value=""

  _cntools_action_wallet_register_response_descriptors_same \
    "${minimum}" "${maximum}" || status=70
  if (( status == 0 )); then
    wallet_register_response_raw_digest=""
    _cntools_action_wallet_register_hash_fd \
      "${wallet_register_response_hash_fd}" \
      "${wallet_register_response_identity}" 600 \
      "${minimum}" "${maximum}" 0 wallet_register_response_raw_digest ||
      status=70
  fi
  if [[ -n "${wallet_register_response_hash_fd:-}" ]]; then
    exec {wallet_register_response_hash_fd}>&- || status=70
  fi
  wallet_register_response_hash_fd=""
  if (( status == 0 )); then
    _cntools_action_wallet_register_runtime_tools_same jq || status=70
  fi
  if (( status == 0 )); then
    # jq consumes the raw binary carrier directly. Bash receives only jq's
    # validated canonical JSON, so embedded NUL can never be normalized away.
    value="$("${wallet_register_jq_path}" -ceS . \
      "/dev/fd/${wallet_register_response_reader_fd}" 2>/dev/null)" ||
      status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same jq || status=70
  if (( status == 0 )); then
    _cntools_action_wallet_register_descriptor_same \
      "${wallet_register_response_writer_fd}" \
      "${wallet_register_response_identity}" 600 \
      "${minimum}" "${maximum}" 0 || status=70
    _cntools_action_wallet_register_descriptor_same \
      "${wallet_register_response_reader_fd}" \
      "${wallet_register_response_identity}" 600 \
      "${minimum}" "${maximum}" 0 || status=70
  fi
  if [[ -n "${wallet_register_response_writer_fd:-}" ]]; then
    exec {wallet_register_response_writer_fd}>&- || status=70
  fi
  if [[ -n "${wallet_register_response_reader_fd:-}" ]]; then
    exec {wallet_register_response_reader_fd}>&- || status=70
  fi
  wallet_register_response_writer_fd=""
  wallet_register_response_reader_fd=""
  wallet_register_response_hash_fd=""
  if [[ "${wallet_register_response_unlinked:-N}" == Y ]]; then
    unset 'wallet_register_stage_identities['"${wallet_register_response_leaf}"']'
    unset 'wallet_register_stage_digests['"${wallet_register_response_leaf}"']'
  fi
  wallet_register_response_unlinked=N
  wallet_register_response_identity=""
  wallet_register_response_value="${value}"
  (( ${#wallet_register_response_value} <= maximum )) || status=70
  if (( status == 0 )); then
    wallet_register_response_check_digest=""
    _cntools_action_wallet_register_response_hash \
      wallet_register_response_check_digest || status=70
    wallet_register_response_digest="${wallet_register_response_check_digest}"
  fi
  [[ "${wallet_register_signal_pending}" == N ]] || status=70
  return "${status}"
}

_cntools_action_wallet_register_stage_jq() {
  local leaf="${1:-}" output_name="${2:-}" filter="${3:-}" fd="" output=""
  shift 3 || return 1

  [[ "${output_name}" =~ ^wallet_register_[A-Za-z0-9_]+$ ]] || return 1
  _cntools_action_wallet_register_runtime_tools_same jq || return 1
  if [[ "${leaf}" == "${wallet_register_response_leaf:-}" ]]; then
    _cntools_action_wallet_register_response_same || return 1
    output="$(builtin printf '%s' "${wallet_register_response_value}" |
      "${wallet_register_jq_path}" -er "$@" "${filter}" 2>/dev/null)" ||
      return 1
    _cntools_action_wallet_register_runtime_tools_same jq || return 1
    _cntools_action_wallet_register_response_same || return 1
    builtin printf -v "${output_name}" '%s' "${output}"
    return 0
  fi
  _cntools_action_wallet_register_stage_verify "${leaf}" 1 1048576 ||
    return 1
  _cntools_action_wallet_register_stage_open "${leaf}" 1 1048576 \
    wallet_register_jq_fd || return 1
  fd="${wallet_register_jq_fd}"
  output="$("${wallet_register_jq_path}" -er "$@" "${filter}" \
    "/dev/fd/${fd}" 2>/dev/null)" || {
      exec {fd}>&-
      return 1
    }
  _cntools_action_wallet_register_descriptor_same "${fd}" \
    "${wallet_register_stage_identities[${leaf}]}" 600 1 1048576 1 || {
      exec {fd}>&-
      return 1
    }
  _cntools_action_wallet_register_runtime_tools_same jq || {
    exec {fd}>&-
    return 1
  }
  _cntools_action_wallet_register_stage_verify "${leaf}" 1 1048576 || {
    exec {fd}>&-
    return 1
  }
  exec {fd}>&-
  builtin printf -v "${output_name}" '%s' "${output}"
}

_cntools_action_wallet_register_stage_read() {
  local leaf="${1:-}" output_name="${2:-}" maximum="${3:-4096}"
  local fd="" value=""

  [[ "${output_name}" =~ ^wallet_register_[A-Za-z0-9_]+$ ]] || return 1
  _cntools_action_wallet_register_stage_verify "${leaf}" 1 "${maximum}" ||
    return 1
  _cntools_action_wallet_register_stage_open "${leaf}" 1 "${maximum}" \
    wallet_register_read_fd || return 1
  fd="${wallet_register_read_fd}"
  value="$(< "/dev/fd/${fd}")"
  _cntools_action_wallet_register_descriptor_same "${fd}" \
    "${wallet_register_stage_identities[${leaf}]}" 600 1 "${maximum}" 1 || {
      exec {fd}>&-
      return 1
    }
  _cntools_action_wallet_register_stage_verify "${leaf}" 1 "${maximum}" || {
    exec {fd}>&-
    return 1
  }
  exec {fd}>&-
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_register_run_output() {
  local leaf="${1:-}" option="${2:-}" label="${3:-}" output_fd="" log_fd=""
  local tool_key="${4:-}" command_path="" command_status=0
  shift 4 || return 70

  [[ "${tool_key}" == ccli || "${tool_key}" == hwcli ]] || return 70
  # Callers still supply the legacy argv[0] slot while migrating their arrays;
  # discard it unconditionally. Execution authority comes only from the
  # authenticated map entry selected by the explicit tool key.
  (( $# > 0 )) || return 70
  shift
  _cntools_action_wallet_register_runtime_tools_same "${tool_key}" || return 70
  command_path="${wallet_register_tool_paths[${tool_key}]:-}"
  [[ "${command_path}" == /* ]] || return 70

  _cntools_action_wallet_register_stage_open "${leaf}" 0 1048576 \
    wallet_register_tool_output_fd || return 70
  output_fd="${wallet_register_tool_output_fd}"
  _cntools_action_wallet_register_stage_open tool.log 0 65536 \
    wallet_register_tool_log_fd || {
      exec {output_fd}>&-
      return 70
    }
  log_fd="${wallet_register_tool_log_fd}"
  _cntools_action_wallet_register_descriptor_same "${output_fd}" \
    "${wallet_register_stage_identities[${leaf}]}" 600 0 0 1 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_present println ACTION "${label}" ||
      command_status=70
  fi
  if (( command_status == 0 )); then
    if [[ "${option}" == stdout ]]; then
      if [[ "${leaf}" == submit.out &&
            "${wallet_register_submit_authority}" == local ]]; then
        _cntools_action_wallet_register_runtime_tools_same "${tool_key}" ||
          command_status=70
        _cntools_action_wallet_register_descriptor_same "${output_fd}" \
          "${wallet_register_stage_identities[${leaf}]}" 600 0 0 1 ||
          command_status=70
        _cntools_action_wallet_register_descriptor_same "${log_fd}" \
          "${wallet_register_stage_identities[tool.log]}" 600 0 65536 1 ||
          command_status=70
        [[ "${wallet_register_signal_pending}" == N ]] || command_status=70
        if (( command_status == 0 )); then
          # This is the ambiguity boundary: every tool and descriptor preflight
          # has completed, and the very next operation is the submit invocation.
          wallet_register_submit_started=Y
          if "${command_path}" "$@" 1>&"${output_fd}" 2>&"${log_fd}"; then
            wallet_register_committed=Y
          else
            command_status=1
          fi
        fi
      elif ! "${command_path}" "$@" 1>&"${output_fd}" 2>&"${log_fd}"; then
        command_status=1
      fi
    else
      "${command_path}" "$@" "${option}" "/dev/fd/${output_fd}" \
        >/dev/null 2>&"${log_fd}" || command_status=1
    fi
  fi
  _cntools_action_wallet_register_runtime_tools_same "${tool_key}" ||
    command_status=70
  _cntools_action_wallet_register_descriptor_same "${output_fd}" \
    "${wallet_register_stage_identities[${leaf}]}" 600 0 1048576 1 ||
    command_status=70
  _cntools_action_wallet_register_descriptor_same "${log_fd}" \
    "${wallet_register_stage_identities[tool.log]}" 600 0 65536 1 ||
    command_status=70
  exec {output_fd}>&-
  exec {log_fd}>&-
  _cntools_action_wallet_register_stage_rebind "${leaf}" 0 1048576 ||
    command_status=70
  _cntools_action_wallet_register_stage_rebind tool.log 0 65536 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_stage_capture "${leaf}" 0 1048576 ||
      command_status=70
  fi
  [[ "${wallet_register_signal_pending}" == N ]] || command_status=70
  return "${command_status}"
}

_cntools_action_wallet_register_remove_leaf() {
  local target="${1:-}" key="" status=0

  [[ -n "${target}" ]] || return 0
  if [[ -d "${target}" && ! -L "${target}" ]]; then
    key='rmdir'
    _cntools_action_wallet_register_runtime_tools_same "${key}" || return 1
    "${wallet_register_rmdir_path}" -- "${target}" >/dev/null 2>&1 || status=1
  elif [[ -e "${target}" || -L "${target}" ]]; then
    key='rm'
    _cntools_action_wallet_register_runtime_tools_same "${key}" || return 1
    "${wallet_register_rm_path}" -f -- "${target}" >/dev/null 2>&1 || status=1
  fi
  [[ -z "${key}" ]] ||
    _cntools_action_wallet_register_runtime_tools_same "${key}" || return 1
  return "${status}"
}

_cntools_action_wallet_register_publish_reconcile() {
  local destination="" leaf="" expected_identity="" metadata=""
  local mode="" size="" identity="" links="" digest=""

  for leaf in certificate.json offline.json; do
    case "${leaf}" in
      certificate.json) destination="${wallet_register_certificate_destination}" ;;
      offline.json) destination="${wallet_register_offline_destination}" ;;
    esac
    [[ -n "${destination}" ]] || continue
    [[ "${wallet_register_publish_attempts[${leaf}]:-N}" == Y &&
       "${wallet_register_published[${leaf}]:-N}" != Y ]] || continue
    if [[ -f "${destination}" && ! -L "${destination}" ]]; then
      _cntools_action_wallet_register_path_metadata "${destination}" 600 \
        1 1048576 2 wallet_register_metadata || return 1
      metadata="${wallet_register_metadata}"
      IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
        return 1
      expected_identity="${wallet_register_stage_identities[${leaf}]}"
      [[ "${identity}" == "${expected_identity}" ]] || return 1
      _cntools_action_wallet_register_stage_hash "${leaf}" 1 1048576 \
        wallet_register_check_digest 2 || return 1
      digest="${wallet_register_check_digest}"
      [[ "${digest}" == "${wallet_register_stage_digests[${leaf}]}" ]] ||
        return 1
      wallet_register_published["${leaf}"]=Y
    elif [[ -e "${destination}" || -L "${destination}" ]]; then
      return 1
    fi
  done
}

_cntools_action_wallet_register_rollback_publication() {
  local leaf="" destination="" metadata="" mode="" size="" identity=""
  local links="" remove_status=0

  _cntools_action_wallet_register_publish_reconcile || return 1
  for leaf in offline.json certificate.json; do
    [[ "${wallet_register_published[${leaf}]:-N}" == Y ]] || continue
    case "${leaf}" in
      certificate.json) destination="${wallet_register_certificate_destination}" ;;
      offline.json) destination="${wallet_register_offline_destination}" ;;
    esac
    _cntools_action_wallet_register_path_metadata "${destination}" 600 \
      1 1048576 2 wallet_register_metadata || return 1
    metadata="${wallet_register_metadata}"
    IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
      return 1
    [[ "${identity}" == "${wallet_register_stage_identities[${leaf}]}" ]] ||
      return 1
    _cntools_action_wallet_register_runtime_tools_same rm || return 1
    "${wallet_register_rm_path}" -f -- "${destination}" >/dev/null 2>&1 ||
      remove_status=1
    _cntools_action_wallet_register_runtime_tools_same rm || return 1
    (( remove_status == 0 )) || return 1
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
    wallet_register_published["${leaf}"]=N
    wallet_register_publish_attempts["${leaf}"]=N
  done
}

_cntools_action_wallet_register_cleanup_stage() {
  local leaf="" target="" found="" cleanup_failed=0 rmdir_status=0

  [[ -n "${wallet_register_lock:-}" ]] || return 0
  _cntools_action_wallet_register_directory_same "${wallet_register_root}" \
    "${wallet_register_root_identity}" '700,750,755' || return 1
  _cntools_action_wallet_register_directory_same "${wallet_register_lock}" \
    "${wallet_register_lock_identity}" 700 || return 1
  if [[ -z "${wallet_register_stage_identity:-}" ]]; then
    [[ ! -e "${wallet_register_stage}" && ! -L "${wallet_register_stage}" ]] ||
      return 1
    _cntools_action_wallet_register_runtime_tools_same find rmdir || return 1
    found="$("${wallet_register_find_path}" "${wallet_register_lock}" \
      -mindepth 1 -maxdepth 1 -print 2>/dev/null)" || return 1
    [[ -z "${found}" ]] || return 1
    "${wallet_register_rmdir_path}" -- "${wallet_register_lock}" \
      >/dev/null 2>&1 || rmdir_status=1
    _cntools_action_wallet_register_runtime_tools_same find rmdir || return 1
    (( rmdir_status == 0 )) || return 1
    wallet_register_stage=""
    wallet_register_lock=""
    return 0
  fi
  _cntools_action_wallet_register_directory_same "${wallet_register_stage}" \
    "${wallet_register_stage_identity}" 700 || return 1
  _cntools_action_wallet_register_runtime_tools_same find || return 1
  found="$("${wallet_register_find_path}" "${wallet_register_stage}" \
    -mindepth 1 -maxdepth 1 -print 2>/dev/null)" || return 1
  _cntools_action_wallet_register_runtime_tools_same find || return 1
  while IFS= builtin read -r target; do
    [[ -n "${target}" ]] || continue
    leaf="${target#"${wallet_register_stage}/"}"
    [[ "${leaf}" != */* &&
       -n "${wallet_register_stage_identities[${leaf}]+set}" ]] ||
      cleanup_failed=1
  done <<< "${found}"
  (( cleanup_failed == 0 )) || return 1
  for leaf in "${wallet_register_stage_leaves[@]}"; do
    target="${wallet_register_stage}/${leaf}"
    [[ -e "${target}" || -L "${target}" ]] || continue
    _cntools_action_wallet_register_remove_leaf "${target}" || cleanup_failed=1
  done
  (( cleanup_failed == 0 )) || return 1
  _cntools_action_wallet_register_runtime_tools_same rmdir || return 1
  "${wallet_register_rmdir_path}" -- "${wallet_register_stage}" \
    >/dev/null 2>&1 || rmdir_status=1
  (( rmdir_status == 0 )) &&
    "${wallet_register_rmdir_path}" -- "${wallet_register_lock}" \
      >/dev/null 2>&1 || rmdir_status=1
  _cntools_action_wallet_register_runtime_tools_same rmdir || return 1
  (( rmdir_status == 0 )) || return 1
  wallet_register_stage=""
  wallet_register_lock=""
}

_cntools_action_wallet_register_cleanup() {
  local cleanup_failed=0

  _cntools_action_wallet_register_headers_close || cleanup_failed=1
  _cntools_action_wallet_register_response_clear || cleanup_failed=1
  if [[ "${wallet_register_committed:-N}" != Y ]]; then
    _cntools_action_wallet_register_rollback_publication || cleanup_failed=1
  fi
  _cntools_action_wallet_register_cleanup_stage || cleanup_failed=1
  return "${cleanup_failed}"
}

_cntools_action_wallet_register_finish_committed() {
  local postcommit_warning="${wallet_register_postcommit_warning:-N}"
  local callback_status=0

  [[ "${wallet_register_committed:-N}" == Y ]] || return 70
  [[ "${wallet_register_callback_violation:-N}" != Y ]] || {
    _cntools_action_wallet_register_validation_failure
    return 70
  }
  _cntools_action_wallet_register_headers_close || postcommit_warning=Y
  _cntools_action_wallet_register_response_clear || postcommit_warning=Y
  _cntools_action_wallet_register_cleanup_stage || postcommit_warning=Y
  _cntools_action_wallet_register_published_final_verify || postcommit_warning=Y
  if [[ "${postcommit_warning}" == Y ]]; then
    _cntools_action_wallet_register_present println ERROR \
      'WARN: wallet registration committed; post-commit cleanup or verification requires attention.' ||
      callback_status=70
  fi
  if [[ "${wallet_register_signal_pending}" == Y ]]; then
    _cntools_action_wallet_register_present println ERROR \
      'WARN: wallet registration committed while an interrupt was pending.' ||
      callback_status=70
  fi
  if [[ "${wallet_register_submission_ambiguous:-N}" == Y ]]; then
    _cntools_action_wallet_register_present println ERROR \
      'WARN: wallet registration submission outcome is ambiguous; the authenticated certificate was retained.' ||
      callback_status=70
  elif [[ "${op_mode}" == hybrid ]]; then
    _cntools_action_wallet_register_present println \
      "Offline registration package created: ${wallet_register_offline_destination}" ||
      callback_status=70
  else
    _cntools_action_wallet_register_present println \
      "${wallet_register_wallet_name} successfully registered on chain!" ||
      callback_status=70
  fi
  _cntools_action_wallet_register_present waitToProceed || callback_status=70
  if (( callback_status != 0 )) ||
     [[ "${wallet_register_callback_violation:-N}" == Y ]]; then
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi
  [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
  return 0
}

_cntools_action_wallet_register_finish_no_commit() {
  local message="${1:-}" wait_flag="${2:-Y}" status=21

  if [[ "${wallet_register_committed:-N}" == Y ]]; then
    _cntools_action_wallet_register_finish_committed
    return $?
  fi
  _cntools_action_wallet_register_cleanup || status=70
  [[ "${wallet_register_signal_pending}" == N ]] || status=70
  if [[ "${status}" == 70 ]]; then
    _cntools_action_wallet_register_validation_failure
    return 70
  fi
  [[ -z "${message}" ]] ||
    _cntools_action_wallet_register_present println ERROR "${message}" ||
    status=70
  [[ "${wait_flag}" != Y ]] ||
    _cntools_action_wallet_register_present waitToProceed || status=70
  if [[ "${wallet_register_signal_pending}" != N ||
        "${wallet_register_callback_violation:-N}" == Y ||
        "${status}" == 70 ]]; then
    _cntools_action_wallet_register_validation_failure
    return 70
  fi
  return 21
}

_cntools_action_wallet_register_finish_invariant() {
  if [[ "${wallet_register_committed:-N}" == Y ]]; then
    _cntools_action_wallet_register_finish_committed
    return $?
  fi
  _cntools_action_wallet_register_cleanup || true
  _cntools_action_wallet_register_validation_failure
  return 70
}

_cntools_action_wallet_register_signal() {
  wallet_register_signal_pending=Y
}

_cntools_action_wallet_register_publish_leaf() {
  local leaf="${1:-}" destination="${2:-}" parent
  parent="${destination%/*}"
  local parent_identity="${3:-}" parent_modes="${4:-}" metadata=""
  local mode="" size="" identity="" links="" link_status=0

  [[ -n "${wallet_register_stage_digests[${leaf}]+set}" &&
     ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  _cntools_action_wallet_register_directory_same "${parent}" \
    "${parent_identity}" "${parent_modes}" || return 1
  _cntools_action_wallet_register_stage_hash "${leaf}" 1 1048576 \
    wallet_register_check_digest || return 70
  [[ "${wallet_register_check_digest}" == \
     "${wallet_register_stage_digests[${leaf}]}" ]] || return 70
  wallet_register_publish_attempts["${leaf}"]=Y
  _cntools_action_wallet_register_runtime_tools_same ln || return 70
  "${wallet_register_ln_path}" -- "${wallet_register_stage}/${leaf}" \
    "${destination}" >/dev/null 2>&1 || link_status=1
  _cntools_action_wallet_register_runtime_tools_same ln || return 70
  if (( link_status != 0 )); then
      _cntools_action_wallet_register_publish_reconcile || return 70
      [[ "${wallet_register_published[${leaf}]:-N}" == Y ]] || return 1
  fi
  _cntools_action_wallet_register_path_metadata "${destination}" 600 \
    1 1048576 2 wallet_register_metadata || return 70
  metadata="${wallet_register_metadata}"
  IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
    return 70
  [[ "${identity}" == "${wallet_register_stage_identities[${leaf}]}" ]] ||
    return 70
  _cntools_action_wallet_register_stage_hash "${leaf}" 1 1048576 \
    wallet_register_check_digest 2 || return 70
  [[ "${wallet_register_check_digest}" == \
     "${wallet_register_stage_digests[${leaf}]}" ]] || return 70
  wallet_register_published["${leaf}"]=Y
  wallet_register_publish_attempts["${leaf}"]=N
  [[ "${wallet_register_signal_pending}" == N ]] || return 70
}

_cntools_action_wallet_register_published_final_verify() {
  local leaf="" destination="" parent="" parent_identity="" metadata=""
  local mode="" size="" identity="" links="" fd="" digest=""

  for leaf in certificate.json offline.json; do
    [[ "${wallet_register_published[${leaf}]:-N}" == Y ]] || continue
    case "${leaf}" in
      certificate.json)
        destination="${wallet_register_certificate_destination}"
        parent="${wallet_register_wallet}"
        parent_identity="${wallet_register_wallet_identity}"
        ;;
      offline.json)
        destination="${wallet_register_offline_destination}"
        parent="${wallet_register_tmp_root}"
        parent_identity="${wallet_register_tmp_identity}"
        ;;
    esac
    _cntools_action_wallet_register_directory_same "${parent}" \
      "${parent_identity}" '700,750,755' || return 1
    _cntools_action_wallet_register_path_metadata "${destination}" 600 \
      1 1048576 1 wallet_register_metadata || return 1
    metadata="${wallet_register_metadata}"
    IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
      return 1
    [[ "${identity}" == "${wallet_register_stage_identities[${leaf}]}" ]] ||
      return 1
    _cntools_action_wallet_register_open_bound "${destination}" "${identity}" \
      600 1 1048576 1 wallet_register_published_fd || return 1
    fd="${wallet_register_published_fd}"
    _cntools_action_wallet_register_hash_fd "${fd}" "${identity}" 600 \
      1 1048576 1 wallet_register_published_digest || {
        exec {fd}>&-
        return 1
      }
    digest="${wallet_register_published_digest}"
    exec {fd}>&-
    [[ "${digest}" == "${wallet_register_stage_digests[${leaf}]}" ]] ||
      return 1
  done
}

_cntools_action_wallet_register_ccli_resolve() {
  local candidate="${1:-}" output_name="${2:-}" resolved="" kind=""

  [[ "${output_name}" =~ ^wallet_register_(ccli|hwcli)_path$ ]] || return 1
  if [[ "${candidate}" == /* ]]; then
    resolved="${candidate}"
  elif [[ "${candidate}" =~ ^[a-z][a-z0-9-]{0,63}$ ]]; then
    kind="$(builtin type -t "${candidate}" 2>/dev/null || true)"
    [[ "${kind}" != alias && "${kind}" != function ]] || return 1
    _cntools_registry_tool_path "${candidate}" resolved || return 1
  else
    return 1
  fi
  [[ "${resolved}" == /* && -f "${resolved}" && -x "${resolved}" &&
     ! -L "${resolved}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${resolved}" || return 1
  builtin printf -v "${output_name}" '%s' "${resolved}"
}

_cntools_action_wallet_register_run_hardware_witness() {
  local body_fd="" payment_fd="" stake_fd="" payment_output_fd=""
  local stake_output_fd="" log_fd="" command_status=0

  _cntools_action_wallet_register_runtime_tools_same hwcli || return 70

  wallet_register_hardware_fd=""; wallet_register_payment_fd=""
  wallet_register_stake_fd=""; wallet_register_witness_payment_fd=""
  wallet_register_witness_stake_fd=""; wallet_register_tool_log_fd=""
  _cntools_action_wallet_register_stage_open tx.hardware 1 1048576 \
    wallet_register_hardware_fd || command_status=70
  body_fd="${wallet_register_hardware_fd:-}"
  _cntools_action_wallet_register_input_open payment_sk \
    wallet_register_payment_fd || command_status=70
  payment_fd="${wallet_register_payment_fd:-}"
  _cntools_action_wallet_register_input_open stake_sk \
    wallet_register_stake_fd || command_status=70
  stake_fd="${wallet_register_stake_fd:-}"
  _cntools_action_wallet_register_stage_open witness.payment 0 1048576 \
    wallet_register_witness_payment_fd || command_status=70
  payment_output_fd="${wallet_register_witness_payment_fd:-}"
  _cntools_action_wallet_register_stage_open witness.stake 0 1048576 \
    wallet_register_witness_stake_fd || command_status=70
  stake_output_fd="${wallet_register_witness_stake_fd:-}"
  _cntools_action_wallet_register_stage_open tool.log 0 65536 \
    wallet_register_tool_log_fd || command_status=70
  log_fd="${wallet_register_tool_log_fd:-}"
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_descriptor_same "${payment_output_fd}" \
      "${wallet_register_stage_identities[witness.payment]}" 600 0 0 1 ||
      command_status=70
    _cntools_action_wallet_register_descriptor_same "${stake_output_fd}" \
      "${wallet_register_stage_identities[witness.stake]}" 600 0 0 1 ||
      command_status=70
  fi
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_present println ACTION \
      'cardano-hw-cli wallet-register transaction witness' || command_status=70
  fi
  if (( command_status == 0 )); then
    "${wallet_register_tool_paths[hwcli]}" transaction witness \
      --tx-file "/dev/fd/${body_fd}" \
      --hw-signing-file "/dev/fd/${payment_fd}" \
      --change-output-key-file "/dev/fd/${payment_fd}" \
      --out-file "/dev/fd/${payment_output_fd}" \
      --hw-signing-file "/dev/fd/${stake_fd}" \
      --change-output-key-file "/dev/fd/${stake_fd}" \
      --out-file "/dev/fd/${stake_output_fd}" \
      "${wallet_register_network_args[@]}" \
      >/dev/null 2>&"${log_fd}" || command_status=1
  fi
  _cntools_action_wallet_register_runtime_tools_same hwcli || command_status=70
  if [[ -n "${payment_output_fd}" ]]; then
    _cntools_action_wallet_register_descriptor_same "${payment_output_fd}" \
      "${wallet_register_stage_identities[witness.payment]}" 600 \
      1 1048576 1 || command_status=70
    exec {payment_output_fd}>&-
  fi
  if [[ -n "${stake_output_fd}" ]]; then
    _cntools_action_wallet_register_descriptor_same "${stake_output_fd}" \
      "${wallet_register_stage_identities[witness.stake]}" 600 \
      1 1048576 1 || command_status=70
    exec {stake_output_fd}>&-
  fi
  if [[ -n "${log_fd}" ]]; then
    _cntools_action_wallet_register_descriptor_same "${log_fd}" \
      "${wallet_register_stage_identities[tool.log]}" 600 0 65536 1 ||
      command_status=70
    exec {log_fd}>&-
  fi
  if [[ -n "${payment_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      payment_sk "${payment_fd}" || command_status=70
  fi
  if [[ -n "${stake_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      stake_sk "${stake_fd}" || command_status=70
  fi
  if [[ -n "${body_fd}" ]]; then
    _cntools_action_wallet_register_stage_close_verified \
      tx.hardware "${body_fd}" 1 1048576 || command_status=70
  fi
  _cntools_action_wallet_register_stage_rebind witness.payment 0 1048576 ||
    command_status=70
  _cntools_action_wallet_register_stage_rebind witness.stake 0 1048576 ||
    command_status=70
  _cntools_action_wallet_register_stage_rebind tool.log 0 65536 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_stage_capture witness.payment 1 1048576 ||
      command_status=70
    _cntools_action_wallet_register_stage_capture witness.stake 1 1048576 ||
      command_status=70
  fi
  [[ "${wallet_register_signal_pending}" == N ]] || command_status=70
  return "${command_status}"
}

_cntools_action_wallet_register_local_query() {
  local schema="" rows="" stake_state="" tx_ref="" asset="" quantity=""
  local previous_ref="" row=""

  _cntools_action_wallet_register_run_output utxo.json --out-file \
    'cardano-cli wallet-register UTxO query' ccli \
    "${wallet_register_ccli_path}" query utxo --address "${base_addr}" \
    "${wallet_register_network_args[@]}" || return $?
  schema='type == "object" and length <= 1024 and
    all(to_entries[];
      (.key | test("^[0-9a-fA-F]{64}#[0-9]{1,10}$")) and
      (.value | type == "object") and .value.address == $address and
      (.value.value | type == "object" and has("lovelace")) and
      all(.value.value | to_entries[];
        (.key == "lovelace" or
         (.key | test("^[0-9a-fA-F]{56}(\\.[0-9a-fA-F]{0,64})?$"))) and
        (.value | type == "number" and floor == . and . >= 0 and
         . <= 45000000000000000)))'
  _cntools_action_wallet_register_stage_jq utxo.json wallet_register_query_value \
    "${schema}" --arg address "${base_addr}" || return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
  _cntools_action_wallet_register_stage_jq utxo.json wallet_register_query_rows \
    '[to_entries | sort_by(.key)[] | .key as $tx |
      .value.value | to_entries | sort_by(.key)[] |
      [$tx, .key, (.value|tostring)] | @tsv] | join("\n")' || return 70
  rows="${wallet_register_query_rows}"
  while IFS=$'\t' builtin read -r tx_ref asset quantity; do
    [[ -n "${tx_ref}" && -n "${asset}" && -n "${quantity}" ]] || continue
    [[ "${tx_ref}" =~ ^[0-9a-fA-F]{64}#[0-9]{1,10}$ &&
       "${asset}" =~ ^(lovelace|[0-9a-fA-F]{56}(\.[0-9a-fA-F]{0,64})?)$ ]] ||
      return 70
    _cntools_action_wallet_register_uint_valid "${quantity}" || return 70
    if [[ -z "${wallet_register_tx_seen[${tx_ref}]+set}" ]]; then
      wallet_register_tx_seen["${tx_ref}"]=Y
      wallet_register_tx_inputs+=("${tx_ref}")
    fi
    if [[ "${asset}" == lovelace ]]; then
      _cntools_action_wallet_register_uint_add "${wallet_register_base_lovelace}" \
        "${quantity}" wallet_register_base_lovelace || return 70
    else
      wallet_register_asset_total="${wallet_register_assets[${asset}]:-0}"
      _cntools_action_wallet_register_uint_add "${wallet_register_asset_total}" \
        "${quantity}" wallet_register_asset_total || return 70
      wallet_register_assets["${asset}"]="${wallet_register_asset_total}"
    fi
  done <<< "${rows}"
  (( ${#wallet_register_tx_inputs[@]} <= 1024 )) || return 70
  if (( ${#wallet_register_tx_inputs[@]} == 0 )); then
    [[ "${wallet_register_base_lovelace}" == 0 &&
       ${#wallet_register_assets[@]} == 0 ]] || return 70
  fi

  _cntools_action_wallet_register_run_output stake.json --out-file \
    'cardano-cli wallet-register stake query' ccli \
    "${wallet_register_ccli_path}" query stake-address-info \
    --address "${reward_addr}" "${wallet_register_network_args[@]}" || return $?
  _cntools_action_wallet_register_stage_jq stake.json wallet_register_query_value \
    'type == "array" and length <= 1 and
      all(.[]; type == "object" and .address == $address and
        ((.rewardAccountBalance // 0) | type == "number" and . >= 0) and
        ((.stakeRegistrationDeposit // 0) | type == "number" and . >= 0))' \
    --arg address "${reward_addr}" || return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
  _cntools_action_wallet_register_stage_jq stake.json wallet_register_query_value \
    'length | tostring' || return 70
  [[ "${wallet_register_query_value}" == 0 ]] || wallet_register_registered=Y
}

_cntools_action_wallet_register_select_light_wallet() {
  local candidate="" name="" current="" selected="" index=0 inner=0

  wallet_register_inventory=()
  wallet_register_inventory_options=()
  builtin shopt -s nullglob dotglob
  for candidate in "${wallet_register_root}"/*; do
    [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
    name="${candidate##*/}"
    [[ "${name}" != .* ]] || continue
    _cntools_action_wallet_register_component_valid "${name}" || return 70
    _cntools_action_wallet_register_directory_identity "${candidate}" \
      '700,750,755' wallet_register_check_identity || return 70
    wallet_register_inventory+=("${name}")
    (( ${#wallet_register_inventory[@]} <= wallet_register_inventory_limit )) ||
      return 70
  done
  (( ${#wallet_register_inventory[@]} > 0 )) || return 1

  for ((index=1; index<${#wallet_register_inventory[@]}; index++)); do
    current="${wallet_register_inventory[index]}"
    inner=$((index - 1))
    while (( inner >= 0 )) &&
        [[ "${current}" < "${wallet_register_inventory[inner]}" ]]; do
      wallet_register_inventory[inner+1]="${wallet_register_inventory[inner]}"
      inner=$((inner - 1))
    done
    wallet_register_inventory[inner+1]="${current}"
  done
  wallet_register_inventory_options=("${wallet_register_inventory[@]}"
    '[Esc] Cancel')
  selected_value=""
  wallet_register_callback_record=""
  _cntools_action_wallet_register_callback_isolated \
    wallet_register_callback_record select_opt selected_value \
    "${wallet_register_inventory_options[@]}" || return 70
  IFS=$'\034' builtin read -r index selected_value \
    wallet_register_callback_extra <<< "${wallet_register_callback_record}" ||
    return 70
  [[ -z "${wallet_register_callback_extra}" && "${index}" =~ ^[0-9]+$ ]] ||
    return 70
  (( index >= 0 && index < ${#wallet_register_inventory_options[@]} )) ||
    return 70
  selected="${wallet_register_inventory_options[index]}"
  [[ "${selected_value:-}" == "${selected}" ]] || return 70
  [[ "${selected}" != '[Esc] Cancel' ]] || return 2
  wallet_name="${selected}"
}

_cntools_action_wallet_register_prepare_curl_headers() {
  local header_declaration="" header_value="" header_index=0

  wallet_register_koios_headers=()
  [[ -z "${wallet_register_headers_fd:-}" &&
     "${wallet_register_signal_pending}" == N ]] || return 70
  if header_declaration="$(
      builtin declare -p KOIOS_API_HEADERS 2>/dev/null
    )"; then
    [[ "${header_declaration}" == 'declare -a '* ||
       "${header_declaration}" == 'declare -ax '* ]] || return 70
    wallet_register_koios_headers=("${KOIOS_API_HEADERS[@]}")
  fi
  (( ${#wallet_register_koios_headers[@]} % 2 == 0 &&
     ${#wallet_register_koios_headers[@]} <= 8 )) || return 70
  for ((header_index=0; header_index<${#wallet_register_koios_headers[@]};
      header_index+=2)); do
    header_value="${wallet_register_koios_headers[header_index+1]}"
    [[ ( "${wallet_register_koios_headers[header_index]}" == -H ||
         "${wallet_register_koios_headers[header_index]}" == --header ) &&
       "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
       "${header_value}" == *:* && "${header_value}" != *$'\r'* &&
       "${header_value}" != *$'\n'* ]] || return 70
  done
}

_cntools_action_wallet_register_headers_open() {
  local write_fd="" read_fd="" header_index=0 header_value="" status=0

  _cntools_action_wallet_register_prepare_curl_headers || return 70
  wallet_register_curl_headers_fd=""
  wallet_register_headers_fd=""
  wallet_register_headers_identity=""
  wallet_register_headers_unlinked=N
  _cntools_action_wallet_register_stage_leaf_create curl.headers || return 70
  _cntools_action_wallet_register_stage_open curl.headers 0 0 \
    wallet_register_curl_headers_fd || return 70
  write_fd="${wallet_register_curl_headers_fd}"
  _cntools_action_wallet_register_stage_open curl.headers 0 0 \
    wallet_register_headers_fd || status=70
  read_fd="${wallet_register_headers_fd:-}"
  wallet_register_headers_identity="${wallet_register_stage_identities[curl.headers]:-}"
  if (( status == 0 )); then
    _cntools_action_wallet_register_runtime_tools_same rm || status=70
  fi
  if (( status == 0 )); then
    "${wallet_register_rm_path}" -f -- \
      "${wallet_register_stage}/curl.headers" >/dev/null 2>&1 || status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same rm || status=70
  [[ ! -e "${wallet_register_stage}/curl.headers" &&
     ! -L "${wallet_register_stage}/curl.headers" ]] || status=70
  if (( status == 0 )); then
    wallet_register_headers_unlinked=Y
    _cntools_action_wallet_register_descriptor_same "${write_fd}" \
      "${wallet_register_headers_identity}" 600 0 0 0 || status=70
    _cntools_action_wallet_register_descriptor_same "${read_fd}" \
      "${wallet_register_headers_identity}" 600 0 0 0 || status=70
  fi
  if (( status == 0 )); then
    # The authenticated inode is anonymous before any credential byte exists.
    # The independent read descriptor remains at offset zero for curl.
    for ((header_index=0; header_index<${#wallet_register_koios_headers[@]};
        header_index+=2)); do
      header_value="${wallet_register_koios_headers[header_index+1]}"
      builtin printf '%s\n' "${header_value}" >&"${write_fd}" || status=70
    done
    builtin printf '%s\n' 'content-type: application/json' >&"${write_fd}" ||
      status=70
    _cntools_action_wallet_register_descriptor_same "${write_fd}" \
      "${wallet_register_headers_identity}" 600 1 65536 0 || status=70
    _cntools_action_wallet_register_descriptor_same "${read_fd}" \
      "${wallet_register_headers_identity}" 600 1 65536 0 || status=70
  fi
  # From this point the only credential copy is held by the anonymous carrier.
  # No inherited callback can see the array or inherit its descriptor.
  wallet_register_koios_headers=()
  header_value=""
  exec {write_fd}>&- || status=70
  [[ "${wallet_register_signal_pending}" == N ]] || status=70
  return "${status}"
}

_cntools_action_wallet_register_headers_same() {
  local fd="${wallet_register_headers_fd:-}"

  [[ "${fd}" =~ ^[1-9][0-9]*$ &&
     "${wallet_register_headers_unlinked:-N}" == Y ]] || return 1
  _cntools_action_wallet_register_descriptor_same "${fd}" \
    "${wallet_register_headers_identity}" 600 1 65536 0
}

_cntools_action_wallet_register_headers_close() {
  local fd="${wallet_register_headers_fd:-}" status=0

  [[ -n "${fd}" ]] || return 0
  if [[ "${wallet_register_headers_unlinked:-N}" == Y ]]; then
    _cntools_action_wallet_register_headers_same || status=1
  fi
  exec {wallet_register_headers_fd}>&- || status=1
  wallet_register_headers_fd=""
  if [[ "${wallet_register_headers_unlinked:-N}" == Y ]]; then
    unset 'wallet_register_stage_identities[curl.headers]'
    unset 'wallet_register_stage_digests[curl.headers]'
  fi
  wallet_register_headers_identity=""
  wallet_register_headers_unlinked=N
  return "${status}"
}

_cntools_action_wallet_register_curl_query() {
  local leaf="${1:-}" endpoint="${2:-}" payload="${3:-}"
  local output_fd="" headers_fd="" command_status=0
  local -a arguments=()

  _cntools_action_wallet_register_runtime_tools_same curl || return 70

  _cntools_action_wallet_register_response_open "${leaf}" || return 70
  output_fd="${wallet_register_response_writer_fd}"
  _cntools_action_wallet_register_headers_open || command_status=70
  headers_fd="${wallet_register_headers_fd:-}"
  _cntools_action_wallet_register_response_descriptors_same 0 0 ||
    command_status=70
  arguments=("${wallet_register_curl_path}" --disable --silent --show-error
    --proto '=https' --connect-timeout "${wallet_register_curl_timeout}"
    --max-time "${wallet_register_curl_timeout}" --fail
    --max-filesize 1048576 --header "@/dev/fd/${headers_fd}"
    --request POST --data "${payload}"
    --output "/dev/fd/${output_fd}"
    --url "${wallet_register_koios_api}/${endpoint}")
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_present println ACTION \
      'curl [configured headers redacted] CNTools wallet-register query' ||
      command_status=70
  fi
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_runtime_tools_same curl || command_status=70
    _cntools_action_wallet_register_headers_same || command_status=70
    _cntools_action_wallet_register_response_descriptors_same 0 0 ||
      command_status=70
    [[ "${wallet_register_signal_pending}" == N ]] || command_status=70
    if (( command_status == 0 )); then
      "${arguments[@]}" >/dev/null 2>/dev/null || command_status=1
    fi
  fi
  _cntools_action_wallet_register_runtime_tools_same curl || command_status=70
  _cntools_action_wallet_register_headers_close || command_status=70
  _cntools_action_wallet_register_response_capture 0 1048576 ||
    command_status=70
  [[ "${wallet_register_signal_pending}" == N ]] || command_status=70
  return "${command_status}"
}

_cntools_action_wallet_register_local_tx_seen() {
  local tx_id="${1:-}" value=""

  [[ "${tx_id}" =~ ^[0-9a-fA-F]{64}$ ]] || return 70
  _cntools_action_wallet_register_run_output verify.out --out-file \
    'cardano-cli wallet-register submission reconciliation' ccli \
    "${wallet_register_ccli_path}" query utxo --tx-in "${tx_id}#0" \
    "${wallet_register_network_args[@]}" || return $?
  _cntools_action_wallet_register_stage_jq verify.out \
    wallet_register_query_value '
      type == "object" and length <= 1 and
      all(to_entries[];
        .key == $reference and (.value|type=="object"))' \
    --arg reference "${tx_id}#0" || return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
  _cntools_action_wallet_register_stage_jq verify.out \
    wallet_register_query_value 'length | tostring' || return 70
  value="${wallet_register_query_value}"
  [[ "${value}" == 0 ]] && return 1
  [[ "${value}" == 1 ]] || return 70
  return 0
}

_cntools_action_wallet_register_light_tx_seen() {
  local tx_id="${1:-}" payload="" value=""

  [[ "${tx_id}" =~ ^[0-9a-fA-F]{64}$ ]] || return 70
  _cntools_action_wallet_register_runtime_tools_same jq || return 70
  payload="$("${wallet_register_jq_path}" -cn --arg tx "${tx_id}" \
    '{_tx_hashes:[$tx]}')" || return 70
  _cntools_action_wallet_register_runtime_tools_same jq || return 70
  _cntools_action_wallet_register_curl_query verify.out \
    'tx_status?select=tx_hash,num_confirmations' "${payload}" || return $?
  _cntools_action_wallet_register_stage_jq verify.out \
    wallet_register_query_value '
      type == "array" and length <= 1 and
      all(.[]; type == "object" and .tx_hash == $tx and
        (.num_confirmations|type=="number" and floor==. and .>=0 and
         .<=9999999999))' --arg tx "${tx_id}" || return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
  _cntools_action_wallet_register_stage_jq verify.out \
    wallet_register_query_value 'length | tostring' || return 70
  value="${wallet_register_query_value}"
  [[ "${value}" == 0 ]] && return 1
  [[ "${value}" == 1 ]] || return 70
  return 0
}

_cntools_action_wallet_register_build_light_submit_request() {
  local output_fd="" signed_fd="" log_fd="" command_status=0

  wallet_register_submit_request_fd=""; wallet_register_signed_fd=""
  wallet_register_tool_log_fd=""
  _cntools_action_wallet_register_stage_open submit.request 0 0 \
    wallet_register_submit_request_fd || return 70
  output_fd="${wallet_register_submit_request_fd}"
  _cntools_action_wallet_register_stage_open tx.signed 1 1048576 \
    wallet_register_signed_fd || command_status=70
  signed_fd="${wallet_register_signed_fd:-}"
  _cntools_action_wallet_register_stage_open tool.log 0 65536 \
    wallet_register_tool_log_fd || command_status=70
  log_fd="${wallet_register_tool_log_fd:-}"
  _cntools_action_wallet_register_descriptor_same "${output_fd}" \
    "${wallet_register_stage_identities[submit.request]}" 600 0 0 1 ||
    command_status=70
  _cntools_action_wallet_register_runtime_tools_same jq || command_status=70
  if (( command_status == 0 )); then
    "${wallet_register_jq_path}" -nS \
      --slurpfile tx "/dev/fd/${signed_fd}" '
        {jsonrpc:"2.0",method:"submitTransaction",
         params:{transaction:{cbor:$tx[0].cborHex}}}' \
      1>&"${output_fd}" 2>&"${log_fd}" || command_status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same jq || command_status=70
  if [[ -n "${signed_fd}" ]]; then
    _cntools_action_wallet_register_stage_close_verified \
      tx.signed "${signed_fd}" 1 1048576 || command_status=70
  fi
  _cntools_action_wallet_register_descriptor_same "${output_fd}" \
    "${wallet_register_stage_identities[submit.request]}" 600 1 1048576 1 ||
    command_status=70
  [[ -z "${log_fd}" ]] || {
    _cntools_action_wallet_register_descriptor_same "${log_fd}" \
      "${wallet_register_stage_identities[tool.log]}" 600 0 65536 1 ||
      command_status=70
  }
  exec {output_fd}>&-
  [[ -z "${log_fd}" ]] || exec {log_fd}>&-
  _cntools_action_wallet_register_stage_rebind submit.request 1 1048576 ||
    command_status=70
  _cntools_action_wallet_register_stage_rebind tool.log 0 65536 ||
    command_status=70
  (( command_status == 0 )) || return "${command_status}"
  _cntools_action_wallet_register_stage_capture submit.request 1 1048576 ||
    return 70
  _cntools_action_wallet_register_stage_jq submit.request \
    wallet_register_query_value '
      type=="object" and keys==["jsonrpc","method","params"] and
      .jsonrpc=="2.0" and .method=="submitTransaction" and
      (.params|type=="object" and keys==["transaction"]) and
      (.params.transaction|type=="object" and keys==["cbor"]) and
      (.params.transaction.cbor|type=="string" and length>=2 and
       length<=1048574 and test("^[0-9a-fA-F]+$") and length%2==0)' ||
    return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
}

_cntools_action_wallet_register_light_submit() {
  local output_fd="" request_fd="" headers_fd=""
  local transport_status=0 command_status=0 response_state=invalid
  local -a arguments=()

  wallet_register_submit_ambiguous=N
  wallet_register_submit_rejected=N
  wallet_register_submit_failure_status=21
  _cntools_action_wallet_register_runtime_tools_same curl jq || return 70
  wallet_register_submit_request_fd=""
  _cntools_action_wallet_register_response_open submit.out || return 70
  output_fd="${wallet_register_response_writer_fd}"
  _cntools_action_wallet_register_stage_open submit.request 1 1048576 \
    wallet_register_submit_request_fd || command_status=70
  request_fd="${wallet_register_submit_request_fd:-}"
  _cntools_action_wallet_register_headers_open || command_status=70
  headers_fd="${wallet_register_headers_fd:-}"
  arguments=("${wallet_register_curl_path}" --disable --silent --show-error
    --proto '=https' --connect-timeout "${wallet_register_curl_timeout}"
    --max-time "${wallet_register_curl_timeout}" --fail
    --max-filesize 1048576 --header "@/dev/fd/${headers_fd}"
    --request POST --data-binary "@/dev/fd/${request_fd}"
    --output "/dev/fd/${output_fd}"
    --url "${wallet_register_koios_api}/ogmios/")
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_present println ACTION \
      'curl [configured headers and transaction body redacted] CNTools wallet-register submission' ||
      command_status=70
  fi
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_runtime_tools_same curl || command_status=70
    _cntools_action_wallet_register_headers_same || command_status=70
    _cntools_action_wallet_register_response_descriptors_same 0 0 ||
      command_status=70
    _cntools_action_wallet_register_descriptor_same "${request_fd}" \
      "${wallet_register_stage_identities[submit.request]}" 600 1 1048576 1 ||
      command_status=70
    [[ "${wallet_register_signal_pending}" == N ]] || command_status=70
    if (( command_status == 0 )); then
      # As with LOCAL submission, no fallible preflight remains after this
      # marker and before the transport process is invoked.
      wallet_register_submit_started=Y
      "${arguments[@]}" >/dev/null 2>/dev/null || transport_status=$?
    else
      transport_status=70
    fi
  else
    transport_status=70
  fi
  _cntools_action_wallet_register_headers_close || command_status=70
  _cntools_action_wallet_register_response_capture 0 1048576 ||
    command_status=70

  if [[ "${wallet_register_submit_started}" == Y ]]; then
    if _cntools_action_wallet_register_stage_jq submit.out \
        wallet_register_response_state '
          if type=="object" and .jsonrpc=="2.0" and
             (.result|type=="object") and
             .result.transaction.id==$tx and (has("error")|not)
          then "accepted"
          elif type=="object" and .jsonrpc=="2.0" and (.error|type=="object")
          then "rejected" else "invalid" end' \
        --arg tx "${wallet_register_tx_id}"; then
      response_state="${wallet_register_response_state}"
    else
      command_status=70
    fi
  fi

  _cntools_action_wallet_register_runtime_tools_same curl || command_status=70
  [[ -z "${request_fd}" ]] ||
    _cntools_action_wallet_register_stage_close_verified \
      submit.request "${request_fd}" 1 1048576 || command_status=70
  if [[ "${wallet_register_submit_started}" != Y ]]; then
    wallet_register_committed=N
    wallet_register_submit_ambiguous=N
    wallet_register_submit_rejected=N
    wallet_register_submission_ambiguous=N
    wallet_register_acceptance_reconciled=N
    wallet_register_reconciliation_attempted=N
    return 70
  fi
  if [[ "${response_state}" == accepted ]]; then
    wallet_register_committed=Y
  fi
  if [[ "${wallet_register_committed}" == Y ]]; then
    return "${command_status}"
  fi
  if (( command_status == 0 && transport_status == 0 )) &&
     [[ "${response_state}" == rejected &&
        "${wallet_register_signal_pending}" == N ]]; then
    wallet_register_submit_rejected=Y
    return 1
  fi
  [[ "${wallet_register_submit_started}" == Y ]] || return 70
  wallet_register_submit_ambiguous=Y
  wallet_register_submit_failure_status=21
  return 1
}

_cntools_action_wallet_register_light_query() {
  local payload="" rows="" tx_hash="" tx_index="" value="" policy=""
  local asset_name="" quantity="" tx_ref="" asset=""

  _cntools_action_wallet_register_runtime_tools_same jq || return 70
  payload="$("${wallet_register_jq_path}" -cn --arg address "${base_addr}" \
    '{_addresses:[$address]}')" || return 70
  _cntools_action_wallet_register_runtime_tools_same jq || return 70
  _cntools_action_wallet_register_curl_query utxo.json \
    'address_utxos?select=address,tx_hash,tx_index,value,asset_list' \
    "${payload}" || return $?
  _cntools_action_wallet_register_stage_jq utxo.json wallet_register_query_value \
    'type == "array" and length <= 1024 and
      all(.[]; type == "object" and .address == $address and
        (.tx_hash | type == "string" and test("^[0-9a-fA-F]{64}$")) and
        (.tx_index | type == "number" and floor == . and . >= 0 and . <= 9999999999) and
        (.value | type == "number" and floor == . and . >= 0 and . <= 45000000000000000) and
        (.asset_list | type == "array" and length <= 4096) and
        all(.asset_list[]; type == "object" and
          (.policy_id | type == "string" and test("^[0-9a-fA-F]{56}$")) and
          (.asset_name | type == "string" and test("^[0-9a-fA-F]{0,64}$")) and
          (.quantity | type == "number" and floor == . and . >= 0 and
           . <= 45000000000000000)))' --arg address "${base_addr}" || return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
  _cntools_action_wallet_register_stage_jq utxo.json wallet_register_query_rows \
    '[. | sort_by(.tx_hash,.tx_index)[] |
      [.tx_hash, (.tx_index|tostring), (.value|tostring),
       ((.asset_list // []) | map([.policy_id,.asset_name,(.quantity|tostring)] | join(":")) | join(","))] |
      @tsv] | join("\n")' || return 70
  rows="${wallet_register_query_rows}"
  while IFS=$'\t' builtin read -r tx_hash tx_index value wallet_register_asset_rows; do
    [[ "${tx_hash}" =~ ^[0-9a-fA-F]{64}$ && "${tx_index}" =~ ^[0-9]+$ ]] ||
      return 70
    _cntools_action_wallet_register_uint_valid "${value}" || return 70
    tx_ref="${tx_hash}#${tx_index}"
    [[ -z "${wallet_register_tx_seen[${tx_ref}]+set}" ]] || return 70
    wallet_register_tx_seen["${tx_ref}"]=Y
    wallet_register_tx_inputs+=("${tx_ref}")
    _cntools_action_wallet_register_uint_add "${wallet_register_base_lovelace}" \
      "${value}" wallet_register_base_lovelace || return 70
    [[ -z "${wallet_register_asset_rows}" ]] || {
      while IFS=: builtin read -r policy asset_name quantity; do
        [[ "${policy}" =~ ^[0-9a-fA-F]{56}$ &&
           "${asset_name}" =~ ^[0-9a-fA-F]{0,64}$ ]] || return 70
        _cntools_action_wallet_register_uint_valid "${quantity}" || return 70
        asset="${policy}"
        [[ -z "${asset_name}" ]] || asset+=".${asset_name}"
        wallet_register_asset_total="${wallet_register_assets[${asset}]:-0}"
        _cntools_action_wallet_register_uint_add "${wallet_register_asset_total}" \
          "${quantity}" wallet_register_asset_total || return 70
        wallet_register_assets["${asset}"]="${wallet_register_asset_total}"
      done <<< "${wallet_register_asset_rows//,/$'\n'}"
    }
  done <<< "${rows}"

  _cntools_action_wallet_register_runtime_tools_same jq || return 70
  payload="$("${wallet_register_jq_path}" -cn --arg address "${reward_addr}" \
    '{_stake_addresses:[$address]}')" || return 70
  _cntools_action_wallet_register_runtime_tools_same jq || return 70
  _cntools_action_wallet_register_curl_query stake.json \
    'account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit' \
    "${payload}" || return $?
  _cntools_action_wallet_register_stage_jq stake.json wallet_register_query_value \
    'type == "array" and length <= 1 and
      all(.[]; type == "object" and .stake_address == $address and
        (.status == "registered" or .status == "not registered") and
        ((.rewards_available // 0) | type == "number" and . >= 0) and
        ((.deposit // 0) | type == "number" and . >= 0))' \
    --arg address "${reward_addr}" || return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
  _cntools_action_wallet_register_stage_jq stake.json wallet_register_query_value \
    'if length == 0 then "not registered" else .[0].status end' || return 70
  [[ "${wallet_register_query_value}" != registered ]] ||
    wallet_register_registered=Y
  # No authenticated response is retained across the following inherited TTL
  # and version callbacks, even though their child environments are sanitized.
  _cntools_action_wallet_register_response_clear || return 70
}

_cntools_action_wallet_register_tx_schema() {
  local leaf="${1:-}" kind="${2:-}" filter=""

  case "${kind}" in
    body)
      filter='type == "object" and
        (.type | type == "string" and test("^(TxBody|Unwitnessed Tx).{0,128}$")) and
        (.description | type == "string" and length <= 256) and
        (.cborHex | type == "string" and length >= 8 and length <= 1048574 and
         test("^[0-9a-fA-F]+$") and
         (length % 2 == 0))'
      ;;
    witness)
      filter='type == "object" and
        (.type | type == "string" and test("Witness")) and
        (.description | type == "string" and length <= 256) and
        ((.cborHex // "00") | type == "string" and length >= 2 and
         length <= 1048574 and test("^[0-9a-fA-F]+$") and
         (length % 2 == 0))'
      ;;
    signed)
      filter='type == "object" and
        (.type | type == "string" and test("^(Tx |Signed Tx|Witnessed Tx).{0,128}$")) and
        (.description | type == "string" and length <= 256) and
        ((.cborHex // "00") | type == "string" and length >= 2 and
         length <= 1048574 and test("^[0-9a-fA-F]+$") and
         (length % 2 == 0))'
      ;;
    *) return 1 ;;
  esac
  _cntools_action_wallet_register_stage_jq "${leaf}" wallet_register_query_value \
    "${filter}" || return 1
  [[ "${wallet_register_query_value}" == true ]]
}

_cntools_action_wallet_register_certificate_schema() {
  _cntools_action_wallet_register_stage_jq certificate.json \
    wallet_register_query_value '
      type == "object" and keys == ["cborHex","description","type"] and
      (.type | type == "string" and
        test("^StakeAddressRegistrationCertificate")) and
      (.description | type == "string" and length <= 256) and
      (.cborHex | type == "string" and test("^[0-9a-fA-F]{2,32768}$") and
       (length % 2 == 0))' || return 1
  [[ "${wallet_register_query_value}" == true ]]
}

_cntools_action_wallet_register_epoch_iso() {
  local epoch="${1:-}" output_name="${2:-}" value=""

  [[ "${epoch}" =~ ^(0|[1-9][0-9]{0,11})$ &&
     "${output_name}" =~ ^(created|expires)$ ]] || return 1
  _cntools_action_wallet_register_runtime_tools_same date || return 1
  if value="$("${wallet_register_date_path}" -u -r "${epoch}" \
      '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    :
  elif value="$("${wallet_register_date_path}" -u -d "@${epoch}" \
      '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    :
  else
    return 1
  fi
  _cntools_action_wallet_register_runtime_tools_same date || return 1
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    return 1
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_register_build_offline() {
  local output_fd="" log_fd="" tx_fd="" pay_fd="" stake_fd=""
  local payment_script_fd="" stake_script_fd="" command_status=0
  local created="" identifier="" expires="" expiry_epoch=0 total_fee=0
  local -a arguments=()

  _cntools_action_wallet_register_runtime_tools_same date || return 70
  identifier="$("${wallet_register_date_path}" +%s 2>/dev/null)" || return 70
  [[ "${identifier}" =~ ^[1-9][0-9]{8,11}$ ]] || return 70
  _cntools_action_wallet_register_runtime_tools_same date || return 70
  [[ "${wallet_register_duration}" =~ ^[1-9][0-9]{0,9}$ &&
     "${wallet_register_duration}" -le 2147483647 ]] || return 70
  _cntools_action_wallet_register_epoch_add "${identifier}" \
    "${wallet_register_duration}" wallet_register_expiry_epoch || return 70
  expiry_epoch="${wallet_register_expiry_epoch}"
  _cntools_action_wallet_register_epoch_iso "${identifier}" created || return 70
  _cntools_action_wallet_register_epoch_iso "${expiry_epoch}" expires || return 70
  [[ "${created}" != "${expires}" ]] || return 70
  total_fee=$((wallet_register_min_fee + KEY_DEPOSIT))
  _cntools_action_wallet_register_uint_valid "${total_fee}" || return 70
  wallet_register_offline_leaf="offline_tx_${identifier}.json"
  _cntools_action_wallet_register_leaf_valid "${wallet_register_offline_leaf}" ||
    return 70
  wallet_register_offline_destination="${wallet_register_tmp_root}/${wallet_register_offline_leaf}"
  [[ ! -e "${wallet_register_offline_destination}" &&
     ! -L "${wallet_register_offline_destination}" ]] || return 1

  wallet_register_offline_fd=""; wallet_register_tool_log_fd=""
  wallet_register_tx_fd=""; wallet_register_payment_script_fd=""
  wallet_register_stake_script_fd=""; wallet_register_payment_vk_fd=""
  wallet_register_stake_vk_fd=""
  _cntools_action_wallet_register_stage_open offline.json 0 1048576 \
    wallet_register_offline_fd || return 70
  output_fd="${wallet_register_offline_fd}"
  _cntools_action_wallet_register_stage_open tool.log 0 65536 \
    wallet_register_tool_log_fd || {
      exec {output_fd}>&-
      return 70
    }
  log_fd="${wallet_register_tool_log_fd}"
  _cntools_action_wallet_register_stage_open tx.raw 1 1048576 \
    wallet_register_tx_fd || command_status=70
  tx_fd="${wallet_register_tx_fd:-}"
  if (( command_status == 0 )); then
    if [[ "${wallet_register_wallet_type}" == 5 ]]; then
      _cntools_action_wallet_register_input_open payment_script \
        wallet_register_payment_script_fd || command_status=70
      payment_script_fd="${wallet_register_payment_script_fd:-}"
      _cntools_action_wallet_register_input_open stake_script \
        wallet_register_stake_script_fd || command_status=70
      stake_script_fd="${wallet_register_stake_script_fd:-}"
    else
      _cntools_action_wallet_register_input_open payment_vk \
        wallet_register_payment_vk_fd || command_status=70
      pay_fd="${wallet_register_payment_vk_fd:-}"
      _cntools_action_wallet_register_input_open stake_vk \
        wallet_register_stake_vk_fd || command_status=70
      stake_fd="${wallet_register_stake_vk_fd:-}"
    fi
  fi
  _cntools_action_wallet_register_descriptor_same "${output_fd}" \
    "${wallet_register_stage_identities[offline.json]}" 600 0 0 1 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_register_runtime_tools_same jq || command_status=70
  fi
  if (( command_status == 0 )); then
    arguments=("${wallet_register_jq_path}" -nS
      --arg id "${identifier}" --arg wallet "${wallet_register_wallet_name}"
      --arg created "${created}" --arg expires "${expires}"
      --argjson ttl "${wallet_register_ttl}"
      --argjson fee "${total_fee}"
      --slurpfile txBody "/dev/fd/${tx_fd}")
    if [[ "${wallet_register_wallet_type}" == 5 ]]; then
      arguments+=(--slurpfile payment "/dev/fd/${payment_script_fd}"
        --slurpfile stake "/dev/fd/${stake_script_fd}"
        '{id:$id,type:"Wallet Registration","wallet-name":$wallet,
          "date-created":$created,"date-expire":$expires,ttl:$ttl,txFee:$fee,
          txBody:$txBody[0],"signed-txBody":{},"signing-file":[],witness:[],
          "script-file":[
            {name:("Wallet " + $wallet + " payment script"),script:$payment[0]},
            {name:("Wallet " + $wallet + " stake script"),script:$stake[0]}]}')
    else
      arguments+=(--slurpfile payment "/dev/fd/${pay_fd}"
        --slurpfile stake "/dev/fd/${stake_fd}"
        '{id:$id,type:"Wallet Registration","wallet-name":$wallet,
          "date-created":$created,"date-expire":$expires,ttl:$ttl,txFee:$fee,
          txBody:$txBody[0],"signed-txBody":{},"script-file":[],witness:[],
          "signing-file":[
            {name:("Wallet " + $wallet + " payment signing key"),vkey:$payment[0]},
            {name:("Wallet " + $wallet + " stake signing key"),vkey:$stake[0]}]}')
    fi
    "${arguments[@]}" 1>&"${output_fd}" 2>&"${log_fd}" ||
      command_status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same jq || command_status=70
  if [[ -n "${tx_fd}" ]]; then
    _cntools_action_wallet_register_stage_close_verified \
      tx.raw "${tx_fd}" 1 1048576 || command_status=70
  fi
  if [[ -n "${pay_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      payment_vk "${pay_fd}" || command_status=70
  fi
  if [[ -n "${stake_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      stake_vk "${stake_fd}" || command_status=70
  fi
  if [[ -n "${payment_script_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      payment_script "${payment_script_fd}" || command_status=70
  fi
  if [[ -n "${stake_script_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      stake_script "${stake_script_fd}" || command_status=70
  fi
  _cntools_action_wallet_register_descriptor_same "${output_fd}" \
    "${wallet_register_stage_identities[offline.json]}" 600 1 1048576 1 ||
    command_status=70
  exec {output_fd}>&-
  exec {log_fd}>&-
  _cntools_action_wallet_register_stage_rebind offline.json 0 1048576 ||
    command_status=70
  _cntools_action_wallet_register_stage_rebind tool.log 0 65536 ||
    command_status=70
  (( command_status == 0 )) || return "${command_status}"
  _cntools_action_wallet_register_stage_capture offline.json 1 1048576 ||
    return 70
  _cntools_action_wallet_register_stage_jq offline.json wallet_register_query_value '
    type == "object" and
    keys == ["date-created","date-expire","id","script-file","signed-txBody","signing-file","ttl","txBody","txFee","type","wallet-name","witness"] and
    .id == $id and .type == "Wallet Registration" and
    ."wallet-name" == $wallet and ."date-created" == $created and
    ."date-expire" == $expires and .ttl == $ttl and .txFee == $fee and
    (.txBody|type=="object") and
    (."signed-txBody"|type=="object") and
    (."signing-file"|type=="array" and length<=2) and
    (."script-file"|type=="array" and length<=2) and
    (.witness|type=="array" and length==0)' \
    --arg id "${identifier}" --arg wallet "${wallet_register_wallet_name}" \
    --arg created "${created}" --arg expires "${expires}" \
    --argjson ttl "${wallet_register_ttl}" --argjson fee "${total_fee}" ||
    return 70
  [[ "${wallet_register_query_value}" == true ]] || return 70
  _cntools_action_wallet_register_stage_capture offline.json 1 1048576 ||
    return 70
}

_cntools_action_wallet_register_prefixed_main() {
  (( $# == 2 )) || return 64
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local context_network="" network_magic="" private_parent="" filename=""
  local action_status=0 selection_status=0 wallet_type_status=0 query_status=0
  local phase_status=0 tool_status=0 found="" target=""
  local wallet_name="" op_mode="${op_mode:-}" ttl="" ttl_enter=""
  local required_total=""
  local metadata="" mode="" size="" identity="" links="" leaf=""
  local wallet_register_root="" wallet_register_wallet="" wallet_register_tmp_root=""
  local wallet_register_root_identity="" wallet_register_wallet_identity=""
  local wallet_register_tmp_identity="" wallet_register_lock=""
  local wallet_register_stage="" wallet_register_lock_identity=""
  local wallet_register_stage_identity="" wallet_register_check_identity=""
  local wallet_register_wallet_real=""
  local wallet_register_wallet_name="" wallet_register_wallet_type=""
  local wallet_register_certificate_destination=""
  local wallet_register_offline_destination="" wallet_register_offline_leaf=""
  local wallet_register_registered=N wallet_register_committed=N
  local wallet_register_submit_authority=N
  local wallet_register_submit_started=N wallet_register_submit_rejected=N
  local wallet_register_submission_ambiguous=N
  local wallet_register_postcommit_warning=N
  local wallet_register_signal_pending=N wallet_register_trace_was_on=N
  local wallet_register_jq_path="" wallet_register_mkdir_path=""
  local wallet_register_rmdir_path="" wallet_register_rm_path=""
  local wallet_register_ln_path="" wallet_register_find_path=""
  local wallet_register_sort_path="" wallet_register_stat_path=""
  local wallet_register_hash_path="" wallet_register_hash_kind=""
  local wallet_register_date_path="" wallet_register_curl_path=""
  local wallet_register_hwcli_path=""
  local wallet_register_ccli_path="" wallet_register_curl_timeout=""
  local wallet_register_koios_api="" wallet_register_metadata=""
  local wallet_register_input_fd="" wallet_register_input_digest=""
  local wallet_register_verify_fd=""
  local wallet_register_check_digest="" wallet_register_read_fd=""
  local wallet_register_digest_fd="" wallet_register_jq_fd=""
  local wallet_register_published_fd="" wallet_register_published_digest=""
  local wallet_register_rebind_fd="" wallet_register_capture_digest=""
  local wallet_register_close_digest=""
  local wallet_register_tool_digest=""
  local wallet_register_tool_output_fd="" wallet_register_tool_log_fd=""
  local wallet_register_acceptance_fd="" wallet_register_submit_request_fd=""
  local wallet_register_certificate_fd="" wallet_register_draft_fd=""
  local wallet_register_offline_fd="" wallet_register_tx_fd=""
  local wallet_register_payment_fd="" wallet_register_stake_fd=""
  local wallet_register_payment_script_fd="" wallet_register_stake_script_fd=""
  local wallet_register_payment_vk_fd="" wallet_register_stake_vk_fd=""
  local wallet_register_protocol_fd="" wallet_register_raw_fd=""
  local wallet_register_signed_fd="" wallet_register_witness_payment_fd=""
  local wallet_register_witness_stake_fd="" wallet_register_check_fd=""
  local wallet_register_hardware_fd=""
  local wallet_register_curl_headers_fd="" wallet_register_headers_fd=""
  local wallet_register_headers_identity=""
  local wallet_register_headers_unlinked=N
  local wallet_register_response_writer_fd=""
  local wallet_register_response_reader_fd=""
  local wallet_register_response_hash_fd=""
  local wallet_register_response_identity=""
  local wallet_register_response_unlinked=N
  local wallet_register_response_leaf="" wallet_register_response_value=""
  local wallet_register_response_digest=""
  local wallet_register_response_raw_digest=""
  local wallet_register_response_check_digest=""
  local wallet_register_response_state=""
  local wallet_register_offline_digest=""
  local wallet_register_query_value="" wallet_register_query_rows=""
  local wallet_register_asset_rows="" wallet_register_asset_total=0
  local wallet_register_base_lovelace=0 wallet_register_assets_suffix=""
  local wallet_register_min_fee=0 wallet_register_min_utxo=0
  local wallet_register_ttl=0 wallet_register_dummy_balance=0
  local wallet_register_duration=""
  local wallet_register_expiry_epoch=""
  local wallet_register_tx_id="" wallet_register_submit_ambiguous=N
  local wallet_register_submit_failure_status=21
  local wallet_register_acceptance_reconciled=N
  local wallet_register_reconciliation_attempted=N
  local wallet_register_callback_boundary_active=N
  local wallet_register_callback_violation=N
  local wallet_register_callback_result_path=""
  local wallet_register_callback_context_path=""
  local wallet_register_callback_private_parent=""
  local wallet_register_callback_context_metadata=""
  local wallet_register_callback_context_digest=""
  local wallet_register_callback_private_parent_identity=""
  local wallet_register_callback_check_context_metadata=""
  local wallet_register_callback_check_context_digest=""
  local wallet_register_callback_check_parent_identity=""
  local base_addr="" pay_addr="" reward_addr="" tx_ref="" asset=""
  local quantity="" tx_out="" formatted="" witness_count=2
  local payment_vk_file="" payment_sk_file="" payment_script_file=""
  local stake_vk_file="" stake_sk_file="" stake_script_file=""
  local expected_payment_sk_file="" expected_stake_sk_file=""
  local certificate_fd="" draft_fd="" raw_fd="" protocol_fd=""
  local payment_fd="" stake_fd="" witness_payment_fd=""
  local witness_stake_fd="" signed_fd="" wallet_register_output_value=""
  local payment_script_fd="" stake_script_fd=""
  local wallet_register_script_payment="" wallet_register_script_stake=""
  local wallet_register_body_leaf=tx.raw
  local wallet_register_inventory_limit="${WALLET_SELECTION_FILTER_LIMIT:-100}"
  local selected_value="" wallet_register_callback_record=""
  local wallet_register_callback_extra=""
  local -a wallet_register_network_args=() wallet_register_koios_headers=()
  local -a wallet_register_stage_leaves=() wallet_register_tx_inputs=()
  local -a wallet_register_inventory=() wallet_register_inventory_options=()
  local -a build_arguments=() command_arguments=() witness_arguments=()
  local -A wallet_register_stage_identities=() wallet_register_stage_digests=()
  local -A wallet_register_input_paths=() wallet_register_input_modes=()
  local -A wallet_register_input_identities=() wallet_register_input_digests=()
  local -A wallet_register_input_maximums=() wallet_register_tx_seen=()
  local -A wallet_register_assets=() wallet_register_publish_attempts=()
  local -A wallet_register_published=()
  local -A wallet_register_tool_paths=() wallet_register_tool_metadata=()
  local -A wallet_register_tool_digests=()
  local LC_ALL=C

  # Positional parameters are not callback inputs.  Clear them after the two
  # authenticated dispatcher paths have been captured so Bash_ARGV cannot
  # disclose either path through a later inherited callback.
  builtin set --
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  case "$-" in *x*) wallet_register_trace_was_on=Y; builtin set +x ;; esac
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F cntools_context_has >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_target_validate >/dev/null 2>&1 ||
     ! builtin declare -F clear >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F selectOpMode >/dev/null 2>&1 ||
     ! builtin declare -F getWalletType >/dev/null 2>&1 ||
     ! builtin declare -F getTTL >/dev/null 2>&1 ||
     ! builtin declare -F versionCheck >/dev/null 2>&1; then
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 64
  fi

  # Readonly credential arrays cannot be removed from a descendant shell and
  # therefore cannot share a process with inherited callbacks.  Probe only an
  # unused slot in a child: no configured header value is read or copied, and
  # readonly-assignment diagnostics are suppressed behind the canonical action
  # validation boundary.  Mutable -a/-ax arrays are validated at carrier open.
  case "${CNTOOLS_MODE:-}" in
    LIGHT|light)
      if ! ( KOIOS_API_HEADERS[4096]= ) 2>/dev/null; then
        _cntools_action_wallet_register_validation_failure
        [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
        return 70
      fi
      ;;
  esac

  _cntools_registry_tool_path stat wallet_register_stat_path || action_status=70
  _cntools_registry_tool_path jq wallet_register_jq_path || action_status=70
  if _cntools_registry_tool_path sha256sum wallet_register_hash_path; then
    wallet_register_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum wallet_register_hash_path; then
    wallet_register_hash_kind=shasum
  else
    action_status=70
  fi
  if [[ "${action_status}" == 0 ]]; then
    _cntools_action_wallet_register_executable_capture \
      "${wallet_register_stat_path}" stat || action_status=70
    _cntools_action_wallet_register_executable_capture \
      "${wallet_register_hash_path}" hash || action_status=70
    _cntools_action_wallet_register_executable_capture \
      "${wallet_register_jq_path}" jq || action_status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same jq || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }

  tool_status=0
  context_mode="$(cntools_context_get "${context_file}" mode)" || tool_status=$?
  _cntools_action_wallet_register_runtime_tools_same jq || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  (( tool_status == 0 )) || {
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  tool_status=0
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" ||
    tool_status=$?
  _cntools_action_wallet_register_runtime_tools_same jq || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  (( tool_status == 0 )) || {
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  [[ "${context_mode}" == local || "${context_mode}" == light ]] || {
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  if [[ "${context_mode}" == local ]]; then
    builtin declare -F selectWallet >/dev/null 2>&1 || {
        [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
        return 64
      }
  else
    builtin declare -F select_opt >/dev/null 2>&1 || {
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 64
    }
  fi
  if [[ "${context_mode}" == local ]]; then
    tool_status=0
    cntools_context_has "${context_file}" capabilities local-cli ||
      tool_status=$?
    _cntools_action_wallet_register_runtime_tools_same jq || {
      _cntools_action_wallet_register_validation_failure
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 70
    }
    if (( tool_status != 0 )); then
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 64
    fi
  fi
  for filename in mkdir rmdir rm ln find sort date; do
    case "${filename}" in
      mkdir) _cntools_registry_tool_path mkdir wallet_register_mkdir_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir wallet_register_rmdir_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_register_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln wallet_register_ln_path || action_status=70 ;;
      find) _cntools_registry_tool_path find wallet_register_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort wallet_register_sort_path || action_status=70 ;;
      date) _cntools_registry_tool_path date wallet_register_date_path || action_status=70 ;;
    esac
  done
  if [[ "${action_status}" == 0 ]]; then
    for filename in mkdir rmdir rm ln find sort date; do
      case "${filename}" in
        mkdir) target="${wallet_register_mkdir_path}" ;;
        rmdir) target="${wallet_register_rmdir_path}" ;;
        rm) target="${wallet_register_rm_path}" ;;
        ln) target="${wallet_register_ln_path}" ;;
        find) target="${wallet_register_find_path}" ;;
        sort) target="${wallet_register_sort_path}" ;;
        date) target="${wallet_register_date_path}" ;;
      esac
      _cntools_action_wallet_register_executable_capture \
        "${target}" "${filename}" || action_status=70
      (( action_status == 0 )) || break
    done
  fi
  _cntools_action_wallet_register_ccli_resolve "${CCLI:-}" \
    wallet_register_ccli_path || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    _cntools_action_wallet_register_executable_capture \
      "${wallet_register_ccli_path}" ccli || action_status=70
  fi
  if [[ "${context_mode}" == light ]]; then
    _cntools_registry_tool_path curl wallet_register_curl_path || action_status=70
    if [[ "${action_status}" == 0 ]]; then
      _cntools_action_wallet_register_executable_capture \
        "${wallet_register_curl_path}" curl || action_status=70
    fi
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }

  _cntools_result_target_validate "${result_file}" || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${private_parent}" || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  [[ "${WALLET_FOLDER:-}" == /* && "${TMP_DIR:-}" == /* ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  wallet_register_root="$(builtin cd -P -- "${WALLET_FOLDER}" && builtin pwd -P)" ||
    action_status=70
  wallet_register_tmp_root="$(builtin cd -P -- "${TMP_DIR}" && builtin pwd -P)" ||
    action_status=70
  [[ "${wallet_register_root}" == "${WALLET_FOLDER}" &&
     "${wallet_register_tmp_root}" == "${TMP_DIR}" ]] || action_status=70
  _cntools_action_wallet_register_paths_disjoint \
    "${wallet_register_root}" "${wallet_register_tmp_root}" || action_status=70
  _cntools_action_wallet_register_paths_disjoint \
    "${wallet_register_root}" "${private_parent}" || action_status=70
  _cntools_action_wallet_register_paths_disjoint \
    "${wallet_register_tmp_root}" "${private_parent}" || action_status=70
  _cntools_action_wallet_register_directory_identity "${wallet_register_root}" \
    '700,750,755' wallet_register_root_identity || action_status=70
  _cntools_action_wallet_register_directory_identity "${wallet_register_tmp_root}" \
    '700,750,755' wallet_register_tmp_identity || action_status=70
  for filename in "${WALLET_PAY_VK_FILENAME:-}" \
      "${WALLET_PAY_SK_FILENAME:-}" "${WALLET_STAKE_VK_FILENAME:-}" \
      "${WALLET_STAKE_SK_FILENAME:-}" "${WALLET_HW_PAY_SK_FILENAME:-}" \
      "${WALLET_HW_STAKE_SK_FILENAME:-}" "${WALLET_PAY_SCRIPT_FILENAME:-}" \
      "${WALLET_STAKE_SCRIPT_FILENAME:-}" "${WALLET_BASE_ADDR_FILENAME:-}" \
      "${WALLET_PAY_ADDR_FILENAME:-}" "${WALLET_STAKE_ADDR_FILENAME:-}" \
      "${WALLET_STAKE_CERT_FILENAME:-}"; do
    _cntools_action_wallet_register_leaf_valid "${filename}" || action_status=70
  done
  [[ "${KEY_DEPOSIT:-}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${DUMMYFEE:-}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${TX_TTL:-}" =~ ^[1-9][0-9]{0,9}$ &&
     "${TX_TTL}" -le 2147483647 &&
     "${wallet_register_inventory_limit}" =~ ^[1-9][0-9]{0,2}$ &&
     "${wallet_register_inventory_limit}" -le 1000 &&
     "${PROT_VERSION:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$ ]] ||
    action_status=70
  case "${NETWORK_IDENTIFIER:-}" in
    --mainnet)
      wallet_register_network_args=(--mainnet)
      [[ "${context_network}" == mainnet ]] || action_status=64
      ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 &&
         "${context_network}" != mainnet ]] || action_status=64
      wallet_register_network_args=(--testnet-magic "${network_magic}")
      ;;
    *) action_status=64 ;;
  esac
  if [[ "${context_mode}" == light ]]; then
    wallet_register_curl_timeout="${CURL_TIMEOUT:-10}"
    [[ "${wallet_register_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] ||
      action_status=70
    wallet_register_koios_api="${KOIOS_API%/}"
    [[ "${#wallet_register_koios_api}" -ge 9 &&
       "${#wallet_register_koios_api}" -le 2048 &&
       "${wallet_register_koios_api}" == https://* &&
       "${wallet_register_koios_api}" != *[[:space:]]* &&
       "${wallet_register_koios_api}" != *'?'* &&
       "${wallet_register_koios_api}" != *'#'* &&
       "${wallet_register_koios_api}" != *\\* ]] || action_status=70
  elif [[ -n "${KOIOS_API:-}" ]]; then
    action_status=70
  fi
  if [[ "${action_status}" == 64 ]]; then
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 64
  elif [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi

  wallet_register_callback_result_path="${result_file}"
  wallet_register_callback_context_path="${context_file}"
  wallet_register_callback_private_parent="${private_parent}"
  _cntools_action_wallet_register_path_metadata \
    "${wallet_register_callback_context_path}" '400,600' 1 1048576 1 \
    wallet_register_callback_context_metadata || action_status=70
  _cntools_action_wallet_register_hash_path \
    "${wallet_register_callback_context_path}" \
    wallet_register_callback_context_digest || action_status=70
  _cntools_action_wallet_register_directory_identity \
    "${wallet_register_callback_private_parent}" 700 \
    wallet_register_callback_private_parent_identity || action_status=70
  [[ ! -e "${wallet_register_callback_result_path}" &&
     ! -L "${wallet_register_callback_result_path}" ]] || action_status=70
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi
  wallet_register_callback_boundary_active=Y

  builtin umask 077
  _cntools_action_wallet_register_present clear || action_status=70
  _cntools_action_wallet_register_present println DEBUG \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' || action_status=70
  _cntools_action_wallet_register_present println ' >> WALLET >> REGISTER' ||
    action_status=70
  _cntools_action_wallet_register_present println DEBUG \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  wallet_register_callback_record=""
  _cntools_action_wallet_register_callback_isolated \
    wallet_register_callback_record selectOpMode op_mode || action_status=70
  IFS=$'\034' builtin read -r selection_status op_mode \
    wallet_register_callback_extra <<< "${wallet_register_callback_record}" ||
    action_status=70
  [[ -z "${wallet_register_callback_extra}" &&
     "${selection_status}" =~ ^[0-9]+$ ]] || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  if [[ "${selection_status}" != 0 ]]; then
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 21
  fi
  [[ "${op_mode:-}" == online || "${op_mode:-}" == hybrid ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  if [[ "${context_mode}" == light ]]; then
    _cntools_action_wallet_register_present println DEBUG \
      'Select wallet to register' || action_status=70
    if [[ "${action_status}" == 0 ]] &&
       _cntools_action_wallet_register_select_light_wallet; then
      selection_status=0
    else
      selection_status=$?
      [[ "${action_status}" == 0 ]] || selection_status=70
    fi
  else
    _cntools_action_wallet_register_present println DEBUG \
      'Select wallet to register (only non-registered wallets shown)' ||
      action_status=70
    wallet_register_callback_record=""
    [[ "${action_status}" == 0 ]] &&
      _cntools_action_wallet_register_callback_isolated \
      wallet_register_callback_record selectWallet wallet_name non-reg ||
      action_status=70
    IFS=$'\034' builtin read -r selection_status wallet_name \
      wallet_register_callback_extra <<< "${wallet_register_callback_record}" ||
      action_status=70
    [[ -z "${wallet_register_callback_extra}" &&
       "${selection_status}" =~ ^[0-9]+$ ]] || action_status=70
    [[ "${action_status}" == 0 ]] || selection_status=70
  fi
  case "${selection_status}" in
    0) ;;
    1)
      if ! _cntools_action_wallet_register_present println ERROR \
          'No unregistered wallets are available.' ||
         ! _cntools_action_wallet_register_present waitToProceed; then
        _cntools_action_wallet_register_validation_failure
        [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
        return 70
      fi
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 21
      ;;
    2)
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 21
      ;;
    *)
      _cntools_action_wallet_register_validation_failure
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 70
      ;;
  esac
  wallet_register_wallet_name="${wallet_name:-}"
  _cntools_action_wallet_register_component_valid \
    "${wallet_register_wallet_name}" || {
      _cntools_action_wallet_register_validation_failure
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 70
  }
  wallet_register_wallet="${wallet_register_root}/${wallet_register_wallet_name}"
  wallet_register_wallet_real="$(
    builtin cd -P -- "${wallet_register_wallet}" && builtin pwd -P
  )" || action_status=70
  [[ -d "${wallet_register_wallet}" && ! -L "${wallet_register_wallet}" &&
     "${wallet_register_wallet_real}" == "${wallet_register_wallet}" ]] ||
    action_status=70
  _cntools_action_wallet_register_directory_identity "${wallet_register_wallet}" \
    '700,750,755' wallet_register_wallet_identity || action_status=70
  _cntools_action_wallet_register_runtime_tools_same find || action_status=70
  if (( action_status == 0 )); then
    found="$("${wallet_register_find_path}" "${wallet_register_root}" \
      -mindepth 1 -maxdepth 1 -type d -name "${wallet_register_wallet_name}" \
      -print 2>/dev/null)" || action_status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same find || action_status=70
  [[ "${found}" == "${wallet_register_wallet}" ]] || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  wallet_register_callback_record=""
  _cntools_action_wallet_register_callback_isolated \
    wallet_register_callback_record getWalletType \
    'payment_vk_file,payment_sk_file,payment_script_file,stake_vk_file,stake_sk_file,stake_script_file' \
    "${wallet_register_wallet_name}" || action_status=70
  IFS=$'\034' builtin read -r wallet_type_status payment_vk_file \
    payment_sk_file payment_script_file stake_vk_file stake_sk_file \
    stake_script_file wallet_register_callback_extra \
    <<< "${wallet_register_callback_record}" || action_status=70
  [[ -z "${wallet_register_callback_extra}" &&
     "${wallet_type_status}" =~ ^[0-9]+$ ]] || action_status=70
  [[ "${action_status}" == 0 ]] || wallet_type_status=70
  case "${wallet_type_status}" in
    0|1|5) wallet_register_wallet_type="${wallet_type_status}" ;;
    2)
      if ! _cntools_action_wallet_register_present println ERROR \
          'ERROR: signing keys encrypted, please decrypt before use!' ||
         ! _cntools_action_wallet_register_present waitToProceed; then
        _cntools_action_wallet_register_validation_failure
        [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
        return 70
      fi
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 21
      ;;
    3|4)
      if ! _cntools_action_wallet_register_present println ERROR \
          'ERROR: required payment or stake wallet keys are missing!' ||
         ! _cntools_action_wallet_register_present waitToProceed; then
        _cntools_action_wallet_register_validation_failure
        [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
        return 70
      fi
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 21
      ;;
    *)
      _cntools_action_wallet_register_validation_failure
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 70
      ;;
  esac
  expected_payment_sk_file="${wallet_register_wallet}/${WALLET_PAY_SK_FILENAME}"
  expected_stake_sk_file="${wallet_register_wallet}/${WALLET_STAKE_SK_FILENAME}"
  if [[ "${wallet_register_wallet_type}" == 0 ]]; then
    expected_payment_sk_file="${wallet_register_wallet}/${WALLET_HW_PAY_SK_FILENAME}"
    expected_stake_sk_file="${wallet_register_wallet}/${WALLET_HW_STAKE_SK_FILENAME}"
  fi
  [[ "${payment_vk_file:-}" == "${wallet_register_wallet}/${WALLET_PAY_VK_FILENAME}" &&
     "${payment_sk_file:-}" == "${expected_payment_sk_file}" &&
     "${stake_vk_file:-}" == "${wallet_register_wallet}/${WALLET_STAKE_VK_FILENAME}" &&
     "${stake_sk_file:-}" == "${expected_stake_sk_file}" &&
     "${payment_script_file:-}" == "${wallet_register_wallet}/${WALLET_PAY_SCRIPT_FILENAME}" &&
     "${stake_script_file:-}" == "${wallet_register_wallet}/${WALLET_STAKE_SCRIPT_FILENAME}" ]] ||
    action_status=70
  if [[ "${wallet_register_wallet_type}" == 0 && "${op_mode}" == online ]]; then
    _cntools_action_wallet_register_ccli_resolve \
      "${HWCLI:-cardano-hw-cli}" wallet_register_hwcli_path || action_status=70
    if [[ "${action_status}" == 0 ]]; then
      _cntools_action_wallet_register_executable_capture \
        "${wallet_register_hwcli_path}" hwcli || action_status=70
    fi
    builtin declare -F unlockHWDevice >/dev/null 2>&1 || action_status=70
  fi
  for leaf in base payment reward; do
    case "${leaf}" in
      base) filename="${WALLET_BASE_ADDR_FILENAME}" ;;
      payment) filename="${WALLET_PAY_ADDR_FILENAME}" ;;
      reward) filename="${WALLET_STAKE_ADDR_FILENAME}" ;;
    esac
    _cntools_action_wallet_register_capture_input \
      "${wallet_register_wallet}/${filename}" "${leaf}_address" 512 ||
      action_status=70
    (( action_status == 0 )) || break
  done
  if [[ "${wallet_register_wallet_type}" == 5 ]]; then
    op_mode=hybrid
    _cntools_action_wallet_register_capture_input \
      "${payment_script_file}" payment_script 65536 || action_status=70
    _cntools_action_wallet_register_capture_input \
      "${stake_script_file}" stake_script 65536 || action_status=70
  else
    _cntools_action_wallet_register_capture_input \
      "${payment_vk_file}" payment_vk 65536 || action_status=70
    _cntools_action_wallet_register_capture_input \
      "${stake_vk_file}" stake_vk 65536 || action_status=70
    if [[ "${op_mode}" == online ]]; then
      _cntools_action_wallet_register_capture_input \
        "${payment_sk_file}" payment_sk 65536 600 || action_status=70
      _cntools_action_wallet_register_capture_input \
        "${stake_sk_file}" stake_sk 65536 600 || action_status=70
    fi
  fi
  _cntools_action_wallet_register_input_read base_address base_addr || action_status=70
  _cntools_action_wallet_register_input_read payment_address pay_addr || action_status=70
  _cntools_action_wallet_register_input_read reward_address reward_addr || action_status=70
  _cntools_action_wallet_register_address_valid base "${base_addr}" || action_status=70
  _cntools_action_wallet_register_address_valid payment "${pay_addr}" || action_status=70
  _cntools_action_wallet_register_address_valid reward "${reward_addr}" || action_status=70
  if [[ "${wallet_register_network_args[0]}" == --mainnet ]]; then
    [[ "${base_addr}" == addr1* && "${pay_addr}" == addr1* &&
       "${reward_addr}" == stake1* ]] || action_status=70
  else
    [[ "${base_addr}" == addr_test1* && "${pay_addr}" == addr_test1* &&
       "${reward_addr}" == stake_test1* ]] || action_status=70
  fi
  wallet_register_certificate_destination="${wallet_register_wallet}/${WALLET_STAKE_CERT_FILENAME}"
  if [[ -e "${wallet_register_certificate_destination}" ||
        -L "${wallet_register_certificate_destination}" ]]; then
    if [[ -f "${wallet_register_certificate_destination}" &&
          ! -L "${wallet_register_certificate_destination}" ]] &&
       _cntools_action_wallet_register_path_metadata \
         "${wallet_register_certificate_destination}" '600,640,644' \
         1 1048576 1 wallet_register_metadata; then
      if ! _cntools_action_wallet_register_present println ERROR \
          'A stake registration certificate already exists for this wallet.' ||
         ! _cntools_action_wallet_register_present waitToProceed; then
        _cntools_action_wallet_register_validation_failure
        [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
        return 70
      fi
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 21
    fi
    action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }

  wallet_register_lock="${wallet_register_root}/.${wallet_register_wallet_name}.cntools-wallet-register.lock"
  _cntools_action_wallet_register_runtime_tools_same mkdir || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  tool_status=0
  "${wallet_register_mkdir_path}" -m 0700 -- "${wallet_register_lock}" \
    >/dev/null 2>&1 || tool_status=$?
  _cntools_action_wallet_register_runtime_tools_same mkdir || {
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  if (( tool_status != 0 )); then
    if _cntools_action_wallet_register_directory_identity \
        "${wallet_register_lock}" 700 wallet_register_check_identity; then
      if ! _cntools_action_wallet_register_present println ERROR \
          'Wallet registration is already in progress; please retry later.' ||
         ! _cntools_action_wallet_register_present waitToProceed; then
        _cntools_action_wallet_register_validation_failure
        [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
        return 70
      fi
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return 21
    fi
    _cntools_action_wallet_register_validation_failure
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi
  trap '_cntools_action_wallet_register_signal' HUP INT TERM
  _cntools_action_wallet_register_directory_identity "${wallet_register_lock}" 700 \
    wallet_register_lock_identity || action_status=70
  wallet_register_stage="${wallet_register_lock}/stage"
  _cntools_action_wallet_register_runtime_tools_same mkdir || action_status=70
  if (( action_status == 0 )); then
    "${wallet_register_mkdir_path}" -m 0700 -- "${wallet_register_stage}" \
      >/dev/null 2>&1 || action_status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same mkdir || action_status=70
  _cntools_action_wallet_register_directory_identity "${wallet_register_stage}" 700 \
    wallet_register_stage_identity || action_status=70
  for leaf in tool.log fee.out min-utxo.out txid.out submit.out \
      verify.out submit.request utxo.json stake.json certificate.json tx.draft \
      tx.raw tx.hardware witness.payment witness.stake tx.signed offline.json; do
    (( action_status == 0 )) || break
    _cntools_action_wallet_register_stage_leaf_create "${leaf}" || action_status=70
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  if [[ "${context_mode}" == local ]]; then
    _cntools_action_wallet_register_local_query || query_status=$?
  else
    _cntools_action_wallet_register_light_query || query_status=$?
  fi
  case "${query_status}" in
    0) ;;
    1)
      _cntools_action_wallet_register_finish_no_commit \
        'Wallet registration query failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
      ;;
    *)
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
      ;;
  esac
  if [[ "${wallet_register_registered}" == Y ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'The selected wallet is already registered on chain.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  if [[ "${wallet_register_base_lovelace}" == 0 ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'No funds are available in the wallet base address for registration.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi

  if [[ "${wallet_register_wallet_type}" == 5 ]]; then
    builtin declare -F validateMultiSigScript >/dev/null 2>&1 || action_status=70
    _cntools_action_wallet_register_input_read payment_script \
      wallet_register_script_payment || action_status=70
    _cntools_action_wallet_register_input_read stake_script \
      wallet_register_script_stake || action_status=70
    if (( action_status == 0 )); then
      required_total=
      wallet_register_callback_record=""
      _cntools_action_wallet_register_callback_isolated \
        wallet_register_callback_record validateMultiSigScript required_total \
        false "${wallet_register_script_payment}" || action_status=70
      IFS=$'\034' builtin read -r tool_status required_total \
        wallet_register_callback_extra <<< "${wallet_register_callback_record}" ||
        action_status=70
      [[ -z "${wallet_register_callback_extra}" && "${tool_status}" == 0 ]] ||
        action_status=70
      [[ "${required_total:-}" =~ ^[1-9][0-9]{0,3}$ ]] || action_status=70
      witness_count="${required_total:-0}"
      required_total=
      wallet_register_callback_record=""
      _cntools_action_wallet_register_callback_isolated \
        wallet_register_callback_record validateMultiSigScript required_total \
        false "${wallet_register_script_stake}" || action_status=70
      IFS=$'\034' builtin read -r tool_status required_total \
        wallet_register_callback_extra <<< "${wallet_register_callback_record}" ||
        action_status=70
      [[ -z "${wallet_register_callback_extra}" && "${tool_status}" == 0 ]] ||
        action_status=70
      [[ "${required_total:-}" =~ ^[1-9][0-9]{0,3}$ ]] || action_status=70
      witness_count=$((witness_count + ${required_total:-0}))
    fi
  fi
  wallet_register_callback_record=""
  _cntools_action_wallet_register_callback_isolated \
    wallet_register_callback_record getTTL 'ttl,ttl_enter' \
    "$([[ "${wallet_register_wallet_type}" == 5 ]] && builtin printf true)" ||
    action_status=70
  IFS=$'\034' builtin read -r tool_status ttl ttl_enter \
    wallet_register_callback_extra <<< "${wallet_register_callback_record}" ||
    action_status=70
  [[ -z "${wallet_register_callback_extra}" && "${tool_status}" =~ ^[0-9]+$ ]] ||
    action_status=70
  if [[ "${action_status}" == 0 && "${tool_status}" == 0 ]]; then
    wallet_register_ttl="${ttl:-}"
    wallet_register_duration="${TX_TTL}"
    if [[ "${op_mode}" == hybrid ]]; then
      wallet_register_duration="${ttl_enter:-}"
    fi
  else
    [[ "${action_status}" != 0 ]] || phase_status=1
  fi
  _cntools_action_wallet_register_uint_valid "${wallet_register_ttl}" \
    9007199254740991 ||
    [[ "${phase_status}" == 1 ]] || action_status=70
  [[ "${wallet_register_duration}" =~ ^[1-9][0-9]{0,9}$ &&
     "${wallet_register_duration}" -le 2147483647 ]] ||
    [[ "${phase_status}" == 1 ]] || action_status=70
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'Wallet registration validity selection was canceled or failed.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  phase_status=0
  stake_fd=""; wallet_register_stake_fd=""
  if [[ "${wallet_register_wallet_type}" == 5 ]]; then
    _cntools_action_wallet_register_input_open stake_script \
      wallet_register_stake_fd || action_status=70
    stake_fd="${wallet_register_stake_fd:-}"
    command_arguments=("${wallet_register_ccli_path}" latest stake-address
      registration-certificate --stake-script-file "/dev/fd/${stake_fd}")
  else
    _cntools_action_wallet_register_input_open stake_vk \
      wallet_register_stake_fd || action_status=70
    stake_fd="${wallet_register_stake_fd:-}"
    command_arguments=("${wallet_register_ccli_path}" latest stake-address
      registration-certificate --stake-verification-key-file "/dev/fd/${stake_fd}")
  fi
  wallet_register_callback_record=""
  _cntools_action_wallet_register_callback_isolated \
    wallet_register_callback_record versionCheck '' 9.0 "${PROT_VERSION}" ||
    action_status=70
  IFS=$'\034' builtin read -r tool_status wallet_register_callback_extra \
    <<< "${wallet_register_callback_record}" || action_status=70
  [[ -z "${wallet_register_callback_extra}" && "${tool_status}" =~ ^[0-9]+$ ]] ||
    action_status=70
  if [[ "${action_status}" == 0 && "${tool_status}" == 0 ]]; then
    command_arguments+=(--key-reg-deposit-amt "${KEY_DEPOSIT}")
  fi
  if (( action_status == 0 )); then
    _cntools_action_wallet_register_run_output certificate.json --out-file \
      'cardano-cli wallet-register certificate' ccli \
      "${command_arguments[@]}" ||
      phase_status=$?
  fi
  if [[ -n "${stake_fd}" ]]; then
    if [[ "${wallet_register_wallet_type}" == 5 ]]; then
      _cntools_action_wallet_register_input_close_verified \
        stake_script "${stake_fd}" || phase_status=70
    else
      _cntools_action_wallet_register_input_close_verified \
        stake_vk "${stake_fd}" || phase_status=70
    fi
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'Stake registration certificate creation failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
       ! _cntools_action_wallet_register_certificate_schema; then
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_register_stage_capture certificate.json 1 1048576 ||
    action_status=70

  wallet_register_assets_suffix=""
  _cntools_action_wallet_register_runtime_tools_same sort || action_status=70
  if (( action_status == 0 )); then
    found="$(builtin printf '%s\n' "${!wallet_register_assets[@]}" | \
      "${wallet_register_sort_path}")" || action_status=70
  fi
  _cntools_action_wallet_register_runtime_tools_same sort || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  while IFS= builtin read -r asset; do
    [[ -n "${asset}" ]] || continue
    [[ -n "${wallet_register_assets[${asset}]+set}" ]] || action_status=70
    [[ "${asset}" =~ ^[0-9a-fA-F]{56}(\.[0-9a-fA-F]{0,64})?$ ]] ||
      action_status=70
    (( action_status == 0 )) || break
    quantity="${wallet_register_assets[${asset}]}"
    wallet_register_assets_suffix+="+${quantity} ${asset}"
  done <<< "${found}"
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  wallet_register_dummy_balance=$((wallet_register_base_lovelace - KEY_DEPOSIT))
  (( wallet_register_dummy_balance >= 0 )) || {
    _cntools_action_wallet_register_finish_no_commit \
      'Not enough ADA is available for the registration deposit and fee.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  build_arguments=(latest transaction build-raw)
  for tx_ref in "${wallet_register_tx_inputs[@]}"; do
    build_arguments+=(--tx-in "${tx_ref}")
  done
  certificate_fd=""; payment_script_fd=""; stake_script_fd=""
  wallet_register_certificate_fd=""
  wallet_register_payment_script_fd=""; wallet_register_stake_script_fd=""
  _cntools_action_wallet_register_stage_open certificate.json 1 1048576 \
    wallet_register_certificate_fd || action_status=70
  certificate_fd="${wallet_register_certificate_fd:-}"
  if [[ "${wallet_register_wallet_type}" == 5 ]]; then
    _cntools_action_wallet_register_input_open payment_script \
      wallet_register_payment_script_fd || action_status=70
    payment_script_fd="${wallet_register_payment_script_fd:-}"
    _cntools_action_wallet_register_input_open stake_script \
      wallet_register_stake_script_fd || action_status=70
    stake_script_fd="${wallet_register_stake_script_fd:-}"
    build_arguments+=(--tx-in-script-file "/dev/fd/${payment_script_fd}"
      --certificate-script-file "/dev/fd/${stake_script_fd}")
  fi
  build_arguments+=(--tx-out "${base_addr}+${wallet_register_dummy_balance}${wallet_register_assets_suffix}"
    --invalid-hereafter "${wallet_register_ttl}" --fee "${DUMMYFEE}"
    --certificate-file "/dev/fd/${certificate_fd}")
  phase_status=0
  if (( action_status == 0 )); then
    _cntools_action_wallet_register_run_output tx.draft --out-file \
      'cardano-cli wallet-register draft transaction' ccli \
      "${wallet_register_ccli_path}" "${build_arguments[@]}" || phase_status=$?
  fi
  if [[ -n "${certificate_fd}" ]]; then
    _cntools_action_wallet_register_stage_close_verified \
      certificate.json "${certificate_fd}" 1 1048576 || phase_status=70
  fi
  if [[ -n "${payment_script_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      payment_script "${payment_script_fd}" || phase_status=70
  fi
  if [[ -n "${stake_script_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      stake_script "${stake_script_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'Registration transaction drafting failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
       ! _cntools_action_wallet_register_tx_schema tx.draft body; then
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_register_stage_capture tx.draft 1 1048576 ||
    action_status=70

  target="${wallet_register_tmp_root}/protparams.json"
  _cntools_action_wallet_register_capture_input "${target}" protocol 1048576 ||
    action_status=70
  protocol_fd=""; draft_fd=""
  wallet_register_protocol_fd=""; wallet_register_draft_fd=""
  _cntools_action_wallet_register_input_open protocol wallet_register_protocol_fd ||
    action_status=70
  protocol_fd="${wallet_register_protocol_fd:-}"
  _cntools_action_wallet_register_stage_open tx.draft 1 1048576 \
    wallet_register_draft_fd || action_status=70
  draft_fd="${wallet_register_draft_fd:-}"
  if (( action_status == 0 )); then
    command_arguments=("${wallet_register_ccli_path}" latest transaction
      calculate-min-fee --tx-body-file "/dev/fd/${draft_fd}"
      --tx-in-count "${#wallet_register_tx_inputs[@]}" --tx-out-count 1
      --witness-count "${witness_count}" --byron-witness-count 0
      --protocol-params-file "/dev/fd/${protocol_fd}")
    _cntools_action_wallet_register_run_output fee.out stdout \
      'cardano-cli wallet-register minimum fee' ccli \
      "${command_arguments[@]}" ||
      phase_status=$?
  fi
  if [[ -n "${draft_fd}" ]]; then
    _cntools_action_wallet_register_stage_close_verified \
      tx.draft "${draft_fd}" 1 1048576 || phase_status=70
  fi
  if [[ -n "${protocol_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      protocol "${protocol_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'Registration fee calculation failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_register_stage_read fee.out \
    wallet_register_output_value 256 ||
    action_status=70
  if [[ "${wallet_register_output_value}" =~ ^([0-9]+)([[:space:]]+[A-Za-z]+)?$ ]]; then
    wallet_register_min_fee="${BASH_REMATCH[1]}"
  else
    action_status=70
  fi
  _cntools_action_wallet_register_uint_valid "${wallet_register_min_fee}" ||
    action_status=70
  (( wallet_register_base_lovelace >= wallet_register_min_fee + KEY_DEPOSIT )) || {
    _cntools_action_wallet_register_finish_no_commit \
      'Not enough ADA is available for the registration deposit and fee.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  wallet_register_dummy_balance=$((wallet_register_base_lovelace -
    wallet_register_min_fee - KEY_DEPOSIT))
  tx_out="${base_addr}+${wallet_register_dummy_balance}${wallet_register_assets_suffix}"
  protocol_fd=""; wallet_register_protocol_fd=""
  _cntools_action_wallet_register_input_open protocol \
    wallet_register_protocol_fd || action_status=70
  protocol_fd="${wallet_register_protocol_fd:-}"
  command_arguments=("${wallet_register_ccli_path}" latest transaction
    calculate-min-required-utxo --protocol-params-file
    "/dev/fd/${protocol_fd}" --tx-out "${tx_out}")
  phase_status=0
  if (( action_status == 0 )); then
    _cntools_action_wallet_register_run_output min-utxo.out stdout \
      'cardano-cli wallet-register minimum UTxO' ccli \
      "${command_arguments[@]}" ||
      phase_status=$?
  fi
  if [[ -n "${protocol_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      protocol "${protocol_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'Minimum UTxO calculation failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_register_stage_read min-utxo.out \
    wallet_register_output_value 256 ||
    action_status=70
  if [[ "${wallet_register_output_value}" =~ ^([0-9]+)([[:space:]]+[A-Za-z]+)?$ ]]; then
    wallet_register_min_utxo="${BASH_REMATCH[1]}"
  else
    action_status=70
  fi
  _cntools_action_wallet_register_uint_valid "${wallet_register_min_utxo}" ||
    action_status=70
  (( wallet_register_dummy_balance >= wallet_register_min_utxo )) || {
    _cntools_action_wallet_register_finish_no_commit \
      'The registration output would be below the minimum UTxO value.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  build_arguments=(latest transaction build-raw)
  for tx_ref in "${wallet_register_tx_inputs[@]}"; do
    build_arguments+=(--tx-in "${tx_ref}")
  done
  certificate_fd=""; payment_script_fd=""; stake_script_fd=""
  wallet_register_certificate_fd=""
  wallet_register_payment_script_fd=""; wallet_register_stake_script_fd=""
  _cntools_action_wallet_register_stage_open certificate.json 1 1048576 \
    wallet_register_certificate_fd || action_status=70
  certificate_fd="${wallet_register_certificate_fd:-}"
  if [[ "${wallet_register_wallet_type}" == 5 ]]; then
    _cntools_action_wallet_register_input_open payment_script \
      wallet_register_payment_script_fd || action_status=70
    payment_script_fd="${wallet_register_payment_script_fd:-}"
    _cntools_action_wallet_register_input_open stake_script \
      wallet_register_stake_script_fd || action_status=70
    stake_script_fd="${wallet_register_stake_script_fd:-}"
    build_arguments+=(--tx-in-script-file "/dev/fd/${payment_script_fd}"
      --certificate-script-file "/dev/fd/${stake_script_fd}")
  fi
  build_arguments+=(--tx-out "${tx_out}" --invalid-hereafter
    "${wallet_register_ttl}" --fee "${wallet_register_min_fee}"
    --certificate-file "/dev/fd/${certificate_fd}"
    --out-canonical-cbor)
  phase_status=0
  if (( action_status == 0 )); then
    _cntools_action_wallet_register_run_output tx.raw --out-file \
      'cardano-cli wallet-register final transaction' ccli \
      "${wallet_register_ccli_path}" "${build_arguments[@]}" || phase_status=$?
  fi
  if [[ -n "${certificate_fd}" ]]; then
    _cntools_action_wallet_register_stage_close_verified \
      certificate.json "${certificate_fd}" 1 1048576 || phase_status=70
  fi
  if [[ -n "${payment_script_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      payment_script "${payment_script_fd}" || phase_status=70
  fi
  if [[ -n "${stake_script_fd}" ]]; then
    _cntools_action_wallet_register_input_close_verified \
      stake_script "${stake_script_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_register_finish_no_commit \
      'Final registration transaction construction failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
       ! _cntools_action_wallet_register_tx_schema tx.raw body; then
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_register_stage_capture tx.raw 1 1048576 ||
    action_status=70

  for leaf in "${!wallet_register_input_paths[@]}"; do
    _cntools_action_wallet_register_input_open "${leaf}" wallet_register_check_fd ||
      action_status=70
    [[ -z "${wallet_register_check_fd:-}" ]] ||
      exec {wallet_register_check_fd}>&-
    (( action_status == 0 )) || break
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_register_finish_invariant
    action_status=$?
    [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  # Re-establish authority after inherited selection and wallet callbacks.
  _cntools_action_wallet_register_submission_authority_reset
  if [[ "${op_mode}" == hybrid ]]; then
    _cntools_action_wallet_register_build_offline || phase_status=$?
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_register_finish_no_commit \
        'The offline registration package destination already exists.' Y
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 ]]; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_register_publish_leaf certificate.json \
      "${wallet_register_certificate_destination}" \
      "${wallet_register_wallet_identity}" '700,750,755' || phase_status=$?
    [[ "${phase_status}" == 0 ]] &&
      _cntools_action_wallet_register_publish_leaf offline.json \
        "${wallet_register_offline_destination}" \
        "${wallet_register_tmp_identity}" '700,750,755' || phase_status=$?
    if [[ "${phase_status}" != 0 ]]; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    wallet_register_committed=Y
  else
    phase_status=0
    wallet_register_body_leaf=tx.raw
    if [[ "${wallet_register_wallet_type}" == 0 ]]; then
      raw_fd=""; wallet_register_raw_fd=""
      _cntools_action_wallet_register_stage_open tx.raw 1 1048576 \
        wallet_register_raw_fd || action_status=70
      raw_fd="${wallet_register_raw_fd:-}"
      if (( action_status == 0 )); then
        command_arguments=("${wallet_register_hwcli_path}" transaction transform
          --tx-file "/dev/fd/${raw_fd}")
        _cntools_action_wallet_register_run_output tx.hardware --out-file \
          'cardano-hw-cli wallet-register transaction transform' hwcli \
          "${command_arguments[@]}" || phase_status=$?
      fi
      if [[ -n "${raw_fd}" ]]; then
        _cntools_action_wallet_register_stage_close_verified \
          tx.raw "${raw_fd}" 1 1048576 || phase_status=70
      fi
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        _cntools_action_wallet_register_tx_schema tx.hardware body ||
          phase_status=70
      fi
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        _cntools_action_wallet_register_stage_capture tx.hardware 1 1048576 ||
          phase_status=70
      fi
      wallet_register_body_leaf=tx.hardware
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        wallet_register_callback_record=""
        _cntools_action_wallet_register_callback_isolated \
          wallet_register_callback_record unlockHWDevice '' \
          'witness the wallet registration transaction' || action_status=70
        IFS=$'\034' builtin read -r tool_status wallet_register_callback_extra \
          <<< "${wallet_register_callback_record}" || action_status=70
        [[ -z "${wallet_register_callback_extra}" &&
           "${tool_status}" =~ ^[0-9]+$ ]] || action_status=70
        if [[ "${action_status}" == 0 && "${tool_status}" == 0 ]]; then
          _cntools_action_wallet_register_run_hardware_witness || phase_status=$?
        else
          [[ "${action_status}" != 0 ]] || phase_status=1
        fi
      fi
    else
    payment_fd=""; stake_fd=""; raw_fd=""
    wallet_register_payment_fd=""; wallet_register_stake_fd=""
    wallet_register_raw_fd=""
    _cntools_action_wallet_register_input_open payment_sk wallet_register_payment_fd ||
      action_status=70
    payment_fd="${wallet_register_payment_fd:-}"
    _cntools_action_wallet_register_input_open stake_sk wallet_register_stake_fd ||
      action_status=70
    stake_fd="${wallet_register_stake_fd:-}"
    _cntools_action_wallet_register_stage_open tx.raw 1 1048576 \
      wallet_register_raw_fd || action_status=70
    raw_fd="${wallet_register_raw_fd:-}"
    if (( action_status == 0 )); then
      command_arguments=("${wallet_register_ccli_path}" latest transaction witness
        --tx-body-file "/dev/fd/${raw_fd}" --signing-key-file
        "/dev/fd/${payment_fd}" "${wallet_register_network_args[@]}")
      _cntools_action_wallet_register_run_output witness.payment --out-file \
        'cardano-cli wallet-register payment witness' ccli \
        "${command_arguments[@]}" || phase_status=$?
    fi
    if [[ -n "${payment_fd}" ]]; then
      _cntools_action_wallet_register_input_close_verified \
        payment_sk "${payment_fd}" || phase_status=70
      payment_fd=""
    fi
    if [[ -n "${raw_fd}" ]]; then
      _cntools_action_wallet_register_stage_close_verified \
        tx.raw "${raw_fd}" 1 1048576 || phase_status=70
      raw_fd=""
    fi
    if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
      wallet_register_raw_fd=""
      _cntools_action_wallet_register_stage_open tx.raw 1 1048576 \
        wallet_register_raw_fd || phase_status=70
      raw_fd="${wallet_register_raw_fd:-}"
    fi
    if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
      command_arguments=("${wallet_register_ccli_path}" latest transaction witness
        --tx-body-file "/dev/fd/${raw_fd}" --signing-key-file
        "/dev/fd/${stake_fd}" "${wallet_register_network_args[@]}")
      _cntools_action_wallet_register_run_output witness.stake --out-file \
        'cardano-cli wallet-register stake witness' ccli \
        "${command_arguments[@]}" || phase_status=$?
    fi
    if [[ -n "${stake_fd}" ]]; then
      _cntools_action_wallet_register_input_close_verified \
        stake_sk "${stake_fd}" || phase_status=70
      stake_fd=""
    fi
    if [[ -n "${raw_fd}" ]]; then
      _cntools_action_wallet_register_stage_close_verified \
        tx.raw "${raw_fd}" 1 1048576 || phase_status=70
      raw_fd=""
    fi
    fi
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_register_finish_no_commit \
        'Registration transaction signing failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
         ! _cntools_action_wallet_register_tx_schema witness.payment witness ||
         ! _cntools_action_wallet_register_tx_schema witness.stake witness; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_register_stage_capture witness.payment 1 1048576 ||
      action_status=70
    _cntools_action_wallet_register_stage_capture witness.stake 1 1048576 ||
      action_status=70
    raw_fd=""; witness_payment_fd=""; witness_stake_fd=""
    wallet_register_raw_fd=""; wallet_register_witness_payment_fd=""
    wallet_register_witness_stake_fd=""
    _cntools_action_wallet_register_stage_open "${wallet_register_body_leaf}" 1 1048576 \
      wallet_register_raw_fd || action_status=70
    raw_fd="${wallet_register_raw_fd:-}"
    _cntools_action_wallet_register_stage_open witness.payment 1 1048576 \
      wallet_register_witness_payment_fd || action_status=70
    witness_payment_fd="${wallet_register_witness_payment_fd:-}"
    _cntools_action_wallet_register_stage_open witness.stake 1 1048576 \
      wallet_register_witness_stake_fd || action_status=70
    witness_stake_fd="${wallet_register_witness_stake_fd:-}"
    if (( action_status == 0 )); then
      command_arguments=("${wallet_register_ccli_path}" latest transaction assemble
        --tx-body-file "/dev/fd/${raw_fd}"
        --witness-file "/dev/fd/${witness_payment_fd}"
        --witness-file "/dev/fd/${witness_stake_fd}" --out-canonical-cbor)
      _cntools_action_wallet_register_run_output tx.signed --out-file \
        'cardano-cli wallet-register transaction assembly' ccli \
        "${command_arguments[@]}" || phase_status=$?
    fi
    if [[ -n "${raw_fd}" ]]; then
      _cntools_action_wallet_register_stage_close_verified \
        "${wallet_register_body_leaf}" "${raw_fd}" 1 1048576 || phase_status=70
    fi
    if [[ -n "${witness_payment_fd}" ]]; then
      _cntools_action_wallet_register_stage_close_verified \
        witness.payment "${witness_payment_fd}" 1 1048576 || phase_status=70
    fi
    if [[ -n "${witness_stake_fd}" ]]; then
      _cntools_action_wallet_register_stage_close_verified \
        witness.stake "${witness_stake_fd}" 1 1048576 || phase_status=70
    fi
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_register_finish_no_commit \
        'Registration transaction assembly failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
         ! _cntools_action_wallet_register_tx_schema tx.signed signed; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_register_stage_capture tx.signed 1 1048576 ||
      action_status=70
    if [[ "${action_status}" != 0 ]]; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi

    phase_status=0
    signed_fd=""; wallet_register_signed_fd=""
    _cntools_action_wallet_register_stage_open tx.signed 1 1048576 \
      wallet_register_signed_fd || action_status=70
    signed_fd="${wallet_register_signed_fd:-}"
    if (( action_status == 0 )); then
      command_arguments=("${wallet_register_ccli_path}" latest transaction txid
        --output-text --tx-file "/dev/fd/${signed_fd}")
      _cntools_action_wallet_register_run_output txid.out stdout \
        'cardano-cli wallet-register transaction identifier' ccli \
        "${command_arguments[@]}" || phase_status=$?
    fi
    if [[ -n "${signed_fd}" ]]; then
      _cntools_action_wallet_register_stage_close_verified \
        tx.signed "${signed_fd}" 1 1048576 || phase_status=70
    fi
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_register_finish_no_commit \
        'Registration transaction identifier calculation failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_register_stage_read txid.out \
      wallet_register_tx_id 128 || action_status=70
    [[ "${wallet_register_tx_id}" =~ ^[0-9a-fA-F]{64}$ ]] || action_status=70
    if [[ "${context_mode}" == light && "${action_status}" == 0 ]]; then
      _cntools_action_wallet_register_build_light_submit_request ||
        action_status=$?
    fi
    if [[ "${action_status}" != 0 ]]; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi

    # All inherited selection, wallet, hardware, and presentation callbacks
    # have completed before publication. Re-establish the complete authority
    # state here; only the action-owned invocation boundaries below may change
    # it afterward.
    _cntools_action_wallet_register_submission_authority_reset

    _cntools_action_wallet_register_publish_leaf certificate.json \
      "${wallet_register_certificate_destination}" \
      "${wallet_register_wallet_identity}" '700,750,755' || phase_status=$?
    if [[ "${phase_status}" != 0 ]]; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi

    phase_status=0
    if [[ "${context_mode}" == local ]]; then
      signed_fd=""; wallet_register_signed_fd=""
      _cntools_action_wallet_register_stage_open tx.signed 1 1048576 \
        wallet_register_signed_fd || action_status=70
      signed_fd="${wallet_register_signed_fd:-}"
      if (( action_status == 0 )); then
        command_arguments=("${wallet_register_ccli_path}" latest transaction submit
          --tx-file "/dev/fd/${signed_fd}" "${wallet_register_network_args[@]}")
        wallet_register_submit_authority=local
        _cntools_action_wallet_register_run_output submit.out stdout \
          'cardano-cli wallet-register transaction submission' ccli \
          "${command_arguments[@]}" || phase_status=$?
        wallet_register_submit_authority=N
      fi
      if [[ -n "${signed_fd}" ]]; then
        _cntools_action_wallet_register_stage_close_verified \
          tx.signed "${signed_fd}" 1 1048576 || phase_status=70
      fi
      if [[ "${phase_status}" == 1 &&
            "${wallet_register_submit_started}" != Y ]]; then
        phase_status=70
      elif [[ "${phase_status}" == 1 ]]; then
        wallet_register_reconciliation_attempted=Y
        if _cntools_action_wallet_register_local_tx_seen \
            "${wallet_register_tx_id}"; then
          wallet_register_committed=Y
          wallet_register_acceptance_reconciled=Y
          phase_status=0
        else
          tool_status=$?
          wallet_register_committed=Y
          wallet_register_submission_ambiguous=Y
          phase_status=0
        fi
      fi
    else
      _cntools_action_wallet_register_light_submit || phase_status=$?
      if [[ "${phase_status}" == 1 &&
            "${wallet_register_submit_started}" == Y &&
            "${wallet_register_submit_ambiguous}" == Y ]]; then
        wallet_register_reconciliation_attempted=Y
        if _cntools_action_wallet_register_light_tx_seen \
            "${wallet_register_tx_id}"; then
          wallet_register_committed=Y
          wallet_register_acceptance_reconciled=Y
          phase_status=0
        else
          tool_status=$?
          if [[ "${tool_status}" == 1 ]]; then
            wallet_register_committed=Y
            wallet_register_submission_ambiguous=Y
            phase_status=0
          else
            wallet_register_committed=Y
            wallet_register_submission_ambiguous=Y
            phase_status=0
          fi
        fi
      fi
    fi

    if [[ "${wallet_register_submit_started}" == Y &&
          "${wallet_register_submit_rejected}" != Y &&
          "${wallet_register_committed}" != Y ]]; then
      wallet_register_committed=Y
      wallet_register_submission_ambiguous=Y
      wallet_register_postcommit_warning=Y
      phase_status=0
    fi

    if [[ "${wallet_register_committed}" == Y &&
          ( "${phase_status}" != 0 || "${action_status}" != 0 ) ]]; then
      wallet_register_postcommit_warning=Y
      _cntools_action_wallet_register_finish_committed
      return $?
    fi
    if [[ "${phase_status}" == 1 || "${phase_status}" == 21 ]]; then
      _cntools_action_wallet_register_finish_no_commit \
        'Registration transaction submission failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    [[ "${wallet_register_committed}" == Y ]] || {
      _cntools_action_wallet_register_finish_invariant
      action_status=$?
      [[ "${wallet_register_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    }
    if [[ "${wallet_register_acceptance_reconciled}" != Y &&
          "${wallet_register_reconciliation_attempted}" != Y ]]; then
      if [[ "${context_mode}" == local ]]; then
        _cntools_action_wallet_register_local_tx_seen \
          "${wallet_register_tx_id}" >/dev/null 2>&1 ||
          _cntools_action_wallet_register_present println ERROR \
            'WARN: registration was submitted, but confirmation is still pending.'
      else
        _cntools_action_wallet_register_light_tx_seen \
          "${wallet_register_tx_id}" >/dev/null 2>&1 ||
          _cntools_action_wallet_register_present println ERROR \
            'WARN: registration was submitted, but confirmation is still pending.'
      fi
    fi
  fi

  _cntools_action_wallet_register_finish_committed
}

cntools_action_main() {
  local wallet_register_entry_context="" wallet_register_entry_result=""

  (( $# == 2 )) || return 64
  wallet_register_entry_context="$1"
  wallet_register_entry_result="$2"
  builtin set --
  ( _cntools_action_wallet_register_prefixed_main \
    "${wallet_register_entry_context}" "${wallet_register_entry_result}" )
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  builtin printf '%s\n' \
    'CNTools actions are launched by the dispatcher, not directly.' >&2
  builtin exit 64
fi
