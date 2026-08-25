#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154
# Stage 4 hardened compatibility action for wallet stake de-registration.
# Sourcing defines functions only. The dispatcher supplies an authenticated
# context plus the inherited presentation and wallet-selection surfaces.

_cntools_action_wallet_deregister_validation_failure() {
  builtin printf '%s\n' 'CNTools wallet-deregister action failed validation.' >&2
  return 70
}

_cntools_action_wallet_deregister_component_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. &&
     ! "${value}" =~ [[:cntrl:]] ]]
}

_cntools_action_wallet_deregister_leaf_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_deregister_paths_disjoint() {
  local left="${1:-}" right="${2:-}"

  [[ -n "${left}" && -n "${right}" && "${left}" != "${right}" &&
     "${left}" != "${right}/"* && "${right}" != "${left}/"* ]]
}

_cntools_action_wallet_deregister_uint_valid() {
  local value="${1:-}" maximum="${2:-45000000000000000}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${maximum}" =~ ^[1-9][0-9]{0,17}$ ]] || return 1
  (( ${#value} < ${#maximum} )) && return 0
  (( ${#value} == ${#maximum} )) || return 1
  [[ "${value}" == "${maximum}" || "${value}" < "${maximum}" ]]
}

_cntools_action_wallet_deregister_uint_add() {
  local left="${1:-}" right="${2:-}" output_name="${3:-}" value=0

  [[ "${output_name}" =~ ^wallet_deregister_(base_lovelace|asset_total|available_lovelace)$ ]] ||
    return 1
  _cntools_action_wallet_deregister_uint_valid "${left}" &&
    _cntools_action_wallet_deregister_uint_valid "${right}" || return 1
  value=$((left + right))
  (( value >= left && value >= right )) || return 1
  _cntools_action_wallet_deregister_uint_valid "${value}" || return 1
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_deregister_address_valid() {
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

_cntools_action_wallet_deregister_stat() {
  local target="${1:-}" metadata=""

  [[ -n "${wallet_deregister_stat_path:-}" ]] || return 1
  if metadata="$("${wallet_deregister_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' "${target}" 2>/dev/null)"; then
    builtin printf '%s\n' "${metadata}"
    return 0
  fi
  "${wallet_deregister_stat_path}" -c $'%u\t%a\t%h\t%s\t%d\t%i' \
    -- "${target}" 2>/dev/null
}

_cntools_action_wallet_deregister_directory_identity() {
  local target="${1:-}" modes="${2:-}" output_name="${3:-}"
  local metadata="" owner="" mode="" links="" size="" device="" inode=""

  [[ "${output_name}" =~ ^wallet_deregister_(root|wallet|tmp|lock|stage|check)_identity$ &&
     -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_deregister_stat "${target}")" || return 1
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && ",${modes}," == *",${mode},"* &&
     "${links}" =~ ^[1-9][0-9]*$ && "${device}" =~ ^[0-9]+$ &&
     "${inode}" =~ ^[0-9]+$ ]] || return 1
  builtin printf -v "${output_name}" '%s:%s:%s' \
    "${device}" "${inode}" "${mode}"
}

_cntools_action_wallet_deregister_directory_same() {
  local target="${1:-}" expected="${2:-}" modes="${3:-}" actual=""

  _cntools_action_wallet_deregister_directory_identity \
    "${target}" "${modes}" wallet_deregister_check_identity || return 1
  actual="${wallet_deregister_check_identity}"
  [[ "${actual}" == "${expected}" ]]
}

_cntools_action_wallet_deregister_path_metadata() {
  local target="${1:-}" modes="${2:-}" minimum="${3:-}"
  local maximum="${4:-}" links_allowed="${5:-1}" output_name="${6:-}"
  local metadata="" owner="" mode="" links="" size="" device="" inode=""

  [[ "${minimum}" =~ ^[0-9]+$ && "${maximum}" =~ ^[0-9]+$ &&
     "${minimum}" -le "${maximum}" &&
     "${links_allowed}" =~ ^(1|2|1\|2)$ &&
     "${output_name}" =~ ^wallet_deregister_[A-Za-z0-9_]+$ &&
     -f "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_deregister_stat "${target}")" || return 1
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

_cntools_action_wallet_deregister_descriptor_same() {
  local fd="${1:-}" expected_identity="${2:-}" expected_mode="${3:-}"
  local minimum="${4:-}" maximum="${5:-}" expected_links="${6:-1}"
  local metadata="" owner="" mode="" links="" size="" device="" inode=""
  local fd_path="/dev/fd/${fd}"

  [[ "${fd}" =~ ^[1-9][0-9]*$ &&
     "${expected_identity}" =~ ^[0-9]+:[0-9]+$ &&
     "${expected_mode}" =~ ^[0-7]{3,4}$ &&
     "${minimum}" =~ ^[0-9]+$ && "${maximum}" =~ ^[0-9]+$ &&
     "${expected_links}" =~ ^[12]$ ]] || return 1
  [[ -f "${fd_path}" ]] || return 1
  if metadata="$("${wallet_deregister_stat_path}" -f \
      $'%u\t%Lp\t%l\t%z\t%d\t%i' <&"${fd}" 2>/dev/null)"; then
    :
  else
    metadata="$("${wallet_deregister_stat_path}" -c \
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

_cntools_action_wallet_deregister_open_bound() {
  local target="${1:-}" expected_identity="${2:-}" expected_mode="${3:-}"
  local minimum="${4:-}" maximum="${5:-}" expected_links="${6:-1}"
  local output_name="${7:-}" fd=""

  [[ "${output_name}" =~ ^wallet_deregister_[A-Za-z0-9_]*fd$ ]] || return 1
  # All action-created leaves and accepted wallet inputs are owner-writable.
  # O_RDWR makes a raced FIFO nonblocking; descriptor authentication then
  # rejects every non-regular or wrong inode before a consumer sees it.
  exec {fd}<> "${target}" || return 1
  if ! _cntools_action_wallet_deregister_descriptor_same "${fd}" \
      "${expected_identity}" "${expected_mode}" "${minimum}" "${maximum}" \
      "${expected_links}"; then
    exec {fd}>&-
    return 1
  fi
  builtin printf -v "${output_name}" '%s' "${fd}"
}

_cntools_action_wallet_deregister_hash_fd() {
  local fd="${1:-}" expected_identity="${2:-}" expected_mode="${3:-}"
  local minimum="${4:-}" maximum="${5:-}" expected_links="${6:-1}"
  local output_name="${7:-}" digest=""

  [[ "${output_name}" =~ ^wallet_deregister_[A-Za-z0-9_]+$ ]] || return 1
  case "${wallet_deregister_hash_kind}" in
    sha256sum)
      digest="$("${wallet_deregister_hash_path}" "/dev/fd/${fd}" 2>/dev/null)" ||
        return 1
      ;;
    shasum)
      digest="$("${wallet_deregister_hash_path}" -a 256 \
        "/dev/fd/${fd}" 2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  _cntools_action_wallet_deregister_descriptor_same "${fd}" \
    "${expected_identity}" "${expected_mode}" "${minimum}" "${maximum}" \
    "${expected_links}" || {
      return 1
    }
  builtin printf -v "${output_name}" '%s' "${digest}"
}

_cntools_action_wallet_deregister_hash_path() {
  local target="${1:-}" output_name="${2:-}" digest=""

  [[ "${output_name}" =~ ^wallet_deregister_[A-Za-z0-9_]+$ ]] || return 1
  case "${wallet_deregister_hash_kind}" in
    sha256sum)
      digest="$("${wallet_deregister_hash_path}" "${target}" 2>/dev/null)" ||
        return 1
      ;;
    shasum)
      digest="$("${wallet_deregister_hash_path}" -a 256 "${target}" \
        2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  builtin printf -v "${output_name}" '%s' "${digest}"
}

_cntools_action_wallet_deregister_executable_capture() {
  local target="${1:-}" key="${2:-}" metadata="" repeated=""
  local owner="" mode="" links="" size="" device="" inode="" digest=""

  [[ "${key}" =~ ^(ccli|hwcli|curl|jq|date|stat|hash|mkdir|rmdir|rm|ln|find|sort)$ &&
     -f "${target}" &&
     -x "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_deregister_stat "${target}")" || return 1
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  [[ ( "${owner}" == 0 || "${owner}" == "${EUID}" ) &&
     "${mode}" =~ ^[1357][0145][0145]$ && "${links}" =~ ^[1-9][0-9]*$ &&
     ( "${owner}" == 0 || "${links}" == 1 ) &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 134217728 &&
     "${device}" =~ ^[0-9]+$ && "${inode}" =~ ^[0-9]+$ ]] || return 1
  _cntools_action_wallet_deregister_hash_path "${target}" \
    wallet_deregister_tool_digest || return 1
  digest="${wallet_deregister_tool_digest}"
  repeated="$(_cntools_action_wallet_deregister_stat "${target}")" || return 1
  [[ "${repeated}" == "${metadata}" && -f "${target}" && -x "${target}" &&
     ! -L "${target}" ]] || return 1
  wallet_deregister_tool_paths["${key}"]="${target}"
  wallet_deregister_tool_metadata["${key}"]="${owner}:${mode}:${links}:${size}:${device}:${inode}"
  wallet_deregister_tool_digests["${key}"]="${digest}"
}

_cntools_action_wallet_deregister_executable_same() {
  local key="${1:-}" target="" metadata="" owner="" mode="" links=""
  local size="" device="" inode="" normalized="" digest="" repeated=""

  [[ -n "${wallet_deregister_tool_paths[${key}]+set}" ]] || return 1
  target="${wallet_deregister_tool_paths[${key}]}"
  [[ -f "${target}" && -x "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_action_wallet_deregister_stat "${target}")" || return 1
  IFS=$'\t' builtin read -r owner mode links size device inode <<< "${metadata}" ||
    return 1
  mode="${mode#0}"
  normalized="${owner}:${mode}:${links}:${size}:${device}:${inode}"
  [[ "${normalized}" == "${wallet_deregister_tool_metadata[${key}]}" ]] ||
    return 1
  _cntools_action_wallet_deregister_hash_path "${target}" \
    wallet_deregister_tool_digest || return 1
  digest="${wallet_deregister_tool_digest}"
  [[ "${digest}" == "${wallet_deregister_tool_digests[${key}]}" ]] || return 1
  repeated="$(_cntools_action_wallet_deregister_stat "${target}")" || return 1
  [[ "${repeated}" == "${metadata}" ]]
}

_cntools_action_wallet_deregister_tools_same() {
  local key=""

  (( $# > 0 )) || return 1
  for key in "$@"; do
    _cntools_action_wallet_deregister_executable_same "${key}" || return 1
  done
}

_cntools_action_wallet_deregister_cleanup_tools_same() {
  local key=""

  # Cleanup is intentionally unavailable after *any* captured critical tool
  # changes.  Retaining the authenticated lock/stage is safer than attempting
  # recovery with a process whose trusted execution surface has drifted.
  _cntools_action_wallet_deregister_tools_same stat hash || return 1
  for key in mkdir rmdir rm ln find sort jq date ccli curl hwcli; do
    [[ -z "${wallet_deregister_tool_paths[${key}]+set}" ]] ||
      _cntools_action_wallet_deregister_executable_same "${key}" || return 1
  done
  _cntools_action_wallet_deregister_tools_same hash stat
}

_cntools_action_wallet_deregister_find_capture() {
  local output_name="${1:-}" value="" command_status=0
  shift || return 1

  [[ "${output_name}" =~ ^wallet_deregister_(found|inventory)$ ]] || return 1
  _cntools_action_wallet_deregister_tools_same stat hash find || return 1
  value="$("${wallet_deregister_find_path}" "$@" 2>/dev/null)" ||
    command_status=1
  _cntools_action_wallet_deregister_tools_same find hash stat || return 1
  (( command_status == 0 )) || return 1
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_deregister_sort_capture() {
  local output_name="${1:-}" value="" command_status=0
  shift || return 1

  [[ "${output_name}" == wallet_deregister_sorted_assets ]] || return 1
  _cntools_action_wallet_deregister_tools_same stat hash sort || return 1
  value="$(builtin printf '%s\n' "$@" | "${wallet_deregister_sort_path}")" ||
    command_status=1
  _cntools_action_wallet_deregister_tools_same sort hash stat || return 1
  (( command_status == 0 )) || return 1
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_deregister_capture_input() {
  local target="${1:-}" key="${2:-}" maximum="${3:-65536}"
  local modes="${4:-600,640,644}" metadata="" mode="" size=""
  local identity="" links="" fd="" digest=""

  [[ "${key}" =~ ^[a-z][a-z0-9_]*$ &&
     "${modes}" =~ ^600(,640,644)?$ ]] || return 1
  _cntools_action_wallet_deregister_path_metadata "${target}" "${modes}" \
    1 "${maximum}" 1 wallet_deregister_metadata || return 1
  metadata="${wallet_deregister_metadata}"
  IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" || return 1
  _cntools_action_wallet_deregister_open_bound "${target}" "${identity}" \
    "${mode}" 1 "${maximum}" 1 wallet_deregister_input_fd || return 1
  fd="${wallet_deregister_input_fd}"
  _cntools_action_wallet_deregister_hash_fd "${fd}" "${identity}" "${mode}" \
    1 "${maximum}" 1 wallet_deregister_input_digest || {
      exec {fd}>&-
      return 1
    }
  digest="${wallet_deregister_input_digest}"
  exec {fd}>&-
  wallet_deregister_input_paths["${key}"]="${target}"
  wallet_deregister_input_modes["${key}"]="${mode}"
  wallet_deregister_input_identities["${key}"]="${identity}"
  wallet_deregister_input_digests["${key}"]="${digest}"
  wallet_deregister_input_maximums["${key}"]="${maximum}"
}

_cntools_action_wallet_deregister_input_open() {
  local key="${1:-}" output_name="${2:-}" path="" mode="" identity=""
  local maximum="" fd="" verify_fd="" digest=""

  [[ -n "${wallet_deregister_input_paths[${key}]+set}" ]] || return 1
  path="${wallet_deregister_input_paths[${key}]}"
  mode="${wallet_deregister_input_modes[${key}]}"
  identity="${wallet_deregister_input_identities[${key}]}"
  maximum="${wallet_deregister_input_maximums[${key}]}"
  _cntools_action_wallet_deregister_open_bound "${path}" "${identity}" \
    "${mode}" 1 "${maximum}" 1 "${output_name}" || return 1
  fd="${!output_name}"
  _cntools_action_wallet_deregister_open_bound "${path}" "${identity}" \
    "${mode}" 1 "${maximum}" 1 wallet_deregister_verify_fd || {
      exec {fd}>&-
      return 1
    }
  verify_fd="${wallet_deregister_verify_fd}"
  _cntools_action_wallet_deregister_hash_fd "${verify_fd}" "${identity}" "${mode}" \
    1 "${maximum}" 1 wallet_deregister_check_digest || {
      exec {verify_fd}>&-
      exec {fd}>&-
      return 1
    }
  exec {verify_fd}>&-
  digest="${wallet_deregister_check_digest}"
  [[ "${digest}" == "${wallet_deregister_input_digests[${key}]}" ]] || {
    exec {fd}>&-
    return 1
  }
}

_cntools_action_wallet_deregister_input_read() {
  local key="${1:-}" output_name="${2:-}" fd="" verify_fd="" value=""

  [[ "${output_name}" =~ ^(base_addr|pay_addr|reward_addr|wallet_deregister_script_(payment|stake))$ ]] ||
    return 1
  _cntools_action_wallet_deregister_input_open \
    "${key}" wallet_deregister_read_fd || return 1
  fd="${wallet_deregister_read_fd}"
  value="$(< "/dev/fd/${fd}")"
  _cntools_action_wallet_deregister_descriptor_same "${fd}" \
    "${wallet_deregister_input_identities[${key}]}" \
    "${wallet_deregister_input_modes[${key}]}" 1 \
    "${wallet_deregister_input_maximums[${key}]}" 1 || {
      exec {fd}>&-
      return 1
  }
  exec {fd}>&-
  _cntools_action_wallet_deregister_input_open \
    "${key}" wallet_deregister_check_fd || return 1
  verify_fd="${wallet_deregister_check_fd}"
  exec {verify_fd}>&-
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_deregister_input_close_verified() {
  local key="${1:-}" fd="${2:-}" verify_fd="" status=0

  [[ "${fd}" =~ ^[1-9][0-9]*$ &&
     -n "${wallet_deregister_input_paths[${key}]+set}" ]] || return 1
  _cntools_action_wallet_deregister_descriptor_same "${fd}" \
    "${wallet_deregister_input_identities[${key}]}" \
    "${wallet_deregister_input_modes[${key}]}" 1 \
    "${wallet_deregister_input_maximums[${key}]}" 1 || status=1
  _cntools_action_wallet_deregister_input_open \
    "${key}" wallet_deregister_rebind_fd || status=1
  verify_fd="${wallet_deregister_rebind_fd:-}"
  [[ -z "${verify_fd}" ]] || exec {verify_fd}>&-
  exec {fd}>&-
  return "${status}"
}

_cntools_action_wallet_deregister_stage_leaf_create() {
  local leaf="${1:-}" path="" metadata="" mode="" size="" identity="" links=""

  _cntools_action_wallet_deregister_leaf_valid "${leaf}" || return 1
  [[ -z "${wallet_deregister_stage_identities[${leaf}]+set}" ]] || return 1
  path="${wallet_deregister_stage}/${leaf}"
  [[ ! -e "${path}" && ! -L "${path}" ]] || return 1
  (builtin umask 077
    builtin set -o noclobber
    : > "${path}") 2>/dev/null || return 1
  _cntools_action_wallet_deregister_path_metadata "${path}" 600 0 0 1 \
    wallet_deregister_metadata || return 1
  metadata="${wallet_deregister_metadata}"
  IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" || return 1
  wallet_deregister_stage_identities["${leaf}"]="${identity}"
  wallet_deregister_stage_leaves+=("${leaf}")
}

_cntools_action_wallet_deregister_stage_open() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}"
  local output_name="${4:-}" expected_links="${5:-1}"
  local path="${wallet_deregister_stage}/${leaf}"

  [[ -n "${wallet_deregister_stage_identities[${leaf}]+set}" ]] || return 1
  _cntools_action_wallet_deregister_open_bound "${path}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 \
    "${minimum}" "${maximum}" "${expected_links}" "${output_name}"
}

_cntools_action_wallet_deregister_stage_hash() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}"
  local output_name="${4:-}" expected_links="${5:-1}" fd=""

  wallet_deregister_digest_fd=""
  _cntools_action_wallet_deregister_stage_open "${leaf}" "${minimum}" \
    "${maximum}" wallet_deregister_digest_fd "${expected_links}" || return 1
  fd="${wallet_deregister_digest_fd}"
  _cntools_action_wallet_deregister_hash_fd "${fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 \
    "${minimum}" "${maximum}" "${expected_links}" "${output_name}" || {
      exec {fd}>&-
      return 1
    }
  exec {fd}>&-
}

_cntools_action_wallet_deregister_stage_rebind() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}" fd=""

  wallet_deregister_rebind_fd=""
  _cntools_action_wallet_deregister_stage_open "${leaf}" "${minimum}" \
    "${maximum}" wallet_deregister_rebind_fd || return 1
  fd="${wallet_deregister_rebind_fd}"
  exec {fd}>&-
}

_cntools_action_wallet_deregister_stage_capture() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}" digest=""

  wallet_deregister_capture_digest=""
  _cntools_action_wallet_deregister_stage_hash "${leaf}" "${minimum}" \
    "${maximum}" wallet_deregister_capture_digest || return 1
  digest="${wallet_deregister_capture_digest}"
  wallet_deregister_stage_digests["${leaf}"]="${digest}"
}

_cntools_action_wallet_deregister_stage_close_verified() {
  local leaf="${1:-}" fd="${2:-}" minimum="${3:-}" maximum="${4:-}"
  local digest="" status=0

  [[ "${fd}" =~ ^[1-9][0-9]*$ &&
     -n "${wallet_deregister_stage_digests[${leaf}]+set}" ]] || return 1
  _cntools_action_wallet_deregister_descriptor_same "${fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 \
    "${minimum}" "${maximum}" 1 || status=1
  wallet_deregister_close_digest=""
  _cntools_action_wallet_deregister_stage_hash "${leaf}" "${minimum}" \
    "${maximum}" wallet_deregister_close_digest || status=1
  digest="${wallet_deregister_close_digest:-}"
  [[ "${digest}" == "${wallet_deregister_stage_digests[${leaf}]}" ]] || status=1
  exec {fd}>&-
  return "${status}"
}

_cntools_action_wallet_deregister_stage_verify() {
  local leaf="${1:-}" minimum="${2:-}" maximum="${3:-}" digest=""

  [[ -n "${wallet_deregister_stage_digests[${leaf}]+set}" ]] || return 1
  wallet_deregister_close_digest=""
  _cntools_action_wallet_deregister_stage_hash "${leaf}" "${minimum}" \
    "${maximum}" wallet_deregister_close_digest || return 1
  digest="${wallet_deregister_close_digest}"
  [[ "${digest}" == "${wallet_deregister_stage_digests[${leaf}]}" ]]
}

_cntools_action_wallet_deregister_stage_jq() {
  local leaf="${1:-}" output_name="${2:-}" filter="${3:-}" fd="" output=""
  shift 3 || return 1

  [[ "${output_name}" =~ ^wallet_deregister_[A-Za-z0-9_]+$ ]] || return 1
  _cntools_action_wallet_deregister_executable_same jq || return 1
  _cntools_action_wallet_deregister_stage_open "${leaf}" 1 1048576 \
    wallet_deregister_jq_fd || return 1
  fd="${wallet_deregister_jq_fd}"
  output="$("${wallet_deregister_jq_path}" -er "$@" "${filter}" \
    "/dev/fd/${fd}" 2>/dev/null)" || {
      exec {fd}>&-
      return 1
    }
  _cntools_action_wallet_deregister_executable_same jq || {
    exec {fd}>&-
    return 1
  }
  _cntools_action_wallet_deregister_descriptor_same "${fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 1 1048576 1 || {
      exec {fd}>&-
      return 1
    }
  exec {fd}>&-
  builtin printf -v "${output_name}" '%s' "${output}"
}

_cntools_action_wallet_deregister_stage_read() {
  local leaf="${1:-}" output_name="${2:-}" maximum="${3:-4096}"
  local fd="" value=""

  [[ "${output_name}" =~ ^wallet_deregister_[A-Za-z0-9_]+$ ]] || return 1
  _cntools_action_wallet_deregister_stage_open "${leaf}" 1 "${maximum}" \
    wallet_deregister_read_fd || return 1
  fd="${wallet_deregister_read_fd}"
  value="$(< "/dev/fd/${fd}")"
  _cntools_action_wallet_deregister_descriptor_same "${fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 1 "${maximum}" 1 || {
      exec {fd}>&-
      return 1
    }
  exec {fd}>&-
  builtin printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_deregister_stage_generate_json() {
  local leaf="${1:-}" filter="${2:-}" output_fd="" command_status=0
  shift 2 || return 70

  _cntools_action_wallet_deregister_executable_same jq || return 70
  _cntools_action_wallet_deregister_stage_open "${leaf}" 0 1048576 \
    wallet_deregister_json_output_fd || return 70
  output_fd="${wallet_deregister_json_output_fd}"
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 0 0 1 ||
    command_status=70
  if (( command_status == 0 )); then
    "${wallet_deregister_jq_path}" -cnS "$@" "${filter}" \
      1>&"${output_fd}" 2>/dev/null || command_status=70
  fi
  _cntools_action_wallet_deregister_executable_same jq || command_status=70
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 1 1048576 1 ||
    command_status=70
  exec {output_fd}>&-
  _cntools_action_wallet_deregister_stage_rebind "${leaf}" 1 1048576 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_deregister_stage_capture "${leaf}" 1 1048576 ||
      command_status=70
  fi
  [[ "${wallet_deregister_signal_pending}" == N ]] || command_status=70
  return "${command_status}"
}

_cntools_action_wallet_deregister_build_curl_config() {
  local output_fd="" header_index=0 header_value="" escaped=""
  local command_status=0

  _cntools_action_wallet_deregister_stage_open curl.config 0 65536 \
    wallet_deregister_config_fd || return 70
  output_fd="${wallet_deregister_config_fd}"
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[curl.config]}" 600 0 0 1 ||
    command_status=70
  if (( command_status == 0 )); then
    for ((header_index=1; header_index<${#wallet_deregister_koios_headers[@]};
        header_index+=2)); do
      header_value="${wallet_deregister_koios_headers[header_index]}"
      escaped="${header_value//\\/\\\\}"
      escaped="${escaped//\"/\\\"}"
      builtin printf 'header = "%s"\n' "${escaped}" 1>&"${output_fd}" || {
        command_status=70
        break
      }
    done
  fi
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[curl.config]}" 600 0 65536 1 ||
    command_status=70
  exec {output_fd}>&-
  _cntools_action_wallet_deregister_stage_rebind curl.config 0 65536 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_deregister_stage_capture curl.config 0 65536 ||
      command_status=70
  fi
  [[ "${wallet_deregister_signal_pending}" == N ]] || command_status=70
  return "${command_status}"
}

_cntools_action_wallet_deregister_run_output() {
  local leaf="${1:-}" option="${2:-}" label="${3:-}" output_fd=""
  local command_status=0 tool_key=""
  shift 3 || return 70

  if [[ "${1:-}" == "${wallet_deregister_ccli_path:-}" ]]; then
    tool_key=ccli
  elif [[ "${1:-}" == "${wallet_deregister_hwcli_path:-}" ]]; then
    tool_key=hwcli
  else
    return 70
  fi
  _cntools_action_wallet_deregister_executable_same "${tool_key}" || return 70
  _cntools_action_wallet_deregister_stage_open "${leaf}" 0 1048576 \
    wallet_deregister_tool_output_fd || return 70
  output_fd="${wallet_deregister_tool_output_fd}"
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 0 0 1 ||
    command_status=70
  if (( command_status == 0 )); then
    println ACTION "${label}"
    if [[ "${option}" == stdout || "${option}" == stdout-submit ]]; then
      if [[ "${option}" == stdout-submit &&
            "${wallet_deregister_signal_pending}" != N ]]; then
        command_status=70
      else
        [[ "${option}" != stdout-submit ]] ||
          wallet_deregister_submit_started=Y
        "$@" 1>&"${output_fd}" 2>/dev/null ||
          command_status=1
      fi
    else
      "$@" "${option}" "/dev/fd/${output_fd}" \
        >/dev/null 2>/dev/null || command_status=1
    fi
  fi
  _cntools_action_wallet_deregister_executable_same "${tool_key}" || command_status=70
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 0 1048576 1 ||
    command_status=70
  exec {output_fd}>&-
  _cntools_action_wallet_deregister_stage_rebind "${leaf}" 0 1048576 ||
    command_status=70
  if [[ "${wallet_deregister_signal_pending}" != N &&
        "${wallet_deregister_commit_window:-N}" != Y ]]; then
    command_status=70
  fi
  return "${command_status}"
}

_cntools_action_wallet_deregister_remove_leaf() {
  local leaf="${1:-}" target="" metadata="" mode="" size="" identity=""
  local links="" expected_links=1 command_status=0

  _cntools_action_wallet_deregister_leaf_valid "${leaf}" || return 1
  [[ -n "${wallet_deregister_stage_identities[${leaf}]+set}" ]] || return 1
  target="${wallet_deregister_stage}/${leaf}"
  [[ -e "${target}" || -L "${target}" ]] || return 0
  [[ "${wallet_deregister_published[${leaf}]:-N}" != Y ]] || expected_links=2
  _cntools_action_wallet_deregister_path_metadata "${target}" 600 0 1048576 \
    "${expected_links}" wallet_deregister_metadata || return 1
  metadata="${wallet_deregister_metadata}"
  IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" || return 1
  [[ "${identity}" == "${wallet_deregister_stage_identities[${leaf}]}" ]] ||
    return 1
  _cntools_action_wallet_deregister_tools_same stat hash rm || return 1
  "${wallet_deregister_rm_path}" -f -- "${target}" >/dev/null 2>&1 ||
    command_status=1
  _cntools_action_wallet_deregister_tools_same rm hash stat || return 1
  # Reconcile from authenticated post-state.  A successful deletion is
  # authoritative even when rm reports an error; a surviving path is never
  # treated as removed.
  if [[ ! -e "${target}" && ! -L "${target}" ]]; then
    return 0
  fi
  (( command_status == 0 )) || return 1
  return 1
}

_cntools_action_wallet_deregister_stage_inventory_valid() {
  local found="" target="" leaf="" metadata="" mode="" size="" identity=""
  local links="" expected_links=1 count=0

  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_root}" \
    "${wallet_deregister_root_identity}" '700,750,755' || return 1
  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_lock}" \
    "${wallet_deregister_lock_identity}" 700 || return 1
  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_stage}" \
    "${wallet_deregister_stage_identity}" 700 || return 1
  _cntools_action_wallet_deregister_find_capture wallet_deregister_inventory \
    "${wallet_deregister_stage}" -mindepth 1 -maxdepth 1 -print || return 1
  found="${wallet_deregister_inventory}"
  while IFS= builtin read -r target; do
    [[ -n "${target}" ]] || continue
    leaf="${target#"${wallet_deregister_stage}/"}"
    [[ "${leaf}" != */* &&
       -n "${wallet_deregister_stage_identities[${leaf}]+set}" ]] || return 1
    expected_links=1
    [[ "${wallet_deregister_published[${leaf}]:-N}" != Y ]] || expected_links=2
    _cntools_action_wallet_deregister_path_metadata "${target}" 600 0 1048576 \
      "${expected_links}" wallet_deregister_metadata || return 1
    metadata="${wallet_deregister_metadata}"
    IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" || return 1
    [[ "${identity}" == "${wallet_deregister_stage_identities[${leaf}]}" ]] ||
      return 1
    count=$((count + 1))
  done <<< "${found}"
  (( count == ${#wallet_deregister_stage_leaves[@]} )) || return 1
  for leaf in "${wallet_deregister_stage_leaves[@]}"; do
    [[ -f "${wallet_deregister_stage}/${leaf}" &&
       ! -L "${wallet_deregister_stage}/${leaf}" ]] || return 1
  done
}

_cntools_action_wallet_deregister_publish_reconcile() {
  local destination="" leaf="" expected_identity="" metadata=""
  local mode="" size="" identity="" links="" digest=""

  for leaf in certificate.json offline.json; do
    case "${leaf}" in
      certificate.json) destination="${wallet_deregister_certificate_destination}" ;;
      offline.json) destination="${wallet_deregister_offline_destination}" ;;
    esac
    [[ -n "${destination}" ]] || continue
    [[ "${wallet_deregister_publish_attempts[${leaf}]:-N}" == Y &&
       "${wallet_deregister_published[${leaf}]:-N}" != Y ]] || continue
    if [[ -f "${destination}" && ! -L "${destination}" ]]; then
      _cntools_action_wallet_deregister_path_metadata "${destination}" 600 \
        1 1048576 2 wallet_deregister_metadata || return 1
      metadata="${wallet_deregister_metadata}"
      IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
        return 1
      expected_identity="${wallet_deregister_stage_identities[${leaf}]}"
      [[ "${identity}" == "${expected_identity}" ]] || return 1
      _cntools_action_wallet_deregister_stage_hash "${leaf}" 1 1048576 \
        wallet_deregister_check_digest 2 || return 1
      digest="${wallet_deregister_check_digest}"
      [[ "${digest}" == "${wallet_deregister_stage_digests[${leaf}]}" ]] ||
        return 1
      wallet_deregister_published["${leaf}"]=Y
    elif [[ -e "${destination}" || -L "${destination}" ]]; then
      return 1
    fi
  done
}

_cntools_action_wallet_deregister_rollback_publication() {
  local leaf="" destination="" metadata="" mode="" size="" identity=""
  local links="" command_status=0

  _cntools_action_wallet_deregister_publish_reconcile || return 1
  for leaf in offline.json certificate.json; do
    [[ "${wallet_deregister_published[${leaf}]:-N}" == Y ]] || continue
    case "${leaf}" in
      certificate.json) destination="${wallet_deregister_certificate_destination}" ;;
      offline.json) destination="${wallet_deregister_offline_destination}" ;;
    esac
    _cntools_action_wallet_deregister_path_metadata "${destination}" 600 \
      1 1048576 2 wallet_deregister_metadata || return 1
    metadata="${wallet_deregister_metadata}"
    IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
      return 1
    [[ "${identity}" == "${wallet_deregister_stage_identities[${leaf}]}" ]] ||
      return 1
    _cntools_action_wallet_deregister_tools_same stat hash rm || return 1
    command_status=0
    "${wallet_deregister_rm_path}" -f -- "${destination}" >/dev/null 2>&1 ||
      command_status=1
    _cntools_action_wallet_deregister_tools_same rm hash stat || return 1
    if [[ ! -e "${destination}" && ! -L "${destination}" ]]; then
      # Bind the surviving private inode before recording that the public link
      # is gone.  This also makes rm-success-plus-error safely resumable.
      _cntools_action_wallet_deregister_stage_hash "${leaf}" 1 1048576 \
        wallet_deregister_check_digest || return 1
      [[ "${wallet_deregister_check_digest}" == \
         "${wallet_deregister_stage_digests[${leaf}]}" ]] || return 1
      wallet_deregister_published["${leaf}"]=N
      wallet_deregister_publish_attempts["${leaf}"]=N
      continue
    fi
    (( command_status == 0 )) || return 1
    return 1
  done
}

_cntools_action_wallet_deregister_cleanup_stage() {
  local leaf="" target="" found="" cleanup_failed=0 command_status=0

  [[ -n "${wallet_deregister_lock:-}" ]] || return 0
  _cntools_action_wallet_deregister_cleanup_tools_same || return 1
  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_root}" \
    "${wallet_deregister_root_identity}" '700,750,755' || return 1
  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_lock}" \
    "${wallet_deregister_lock_identity}" 700 || return 1
  if [[ -n "${wallet_deregister_stage:-}" ]]; then
    _cntools_action_wallet_deregister_directory_same "${wallet_deregister_stage}" \
      "${wallet_deregister_stage_identity}" 700 || return 1
    _cntools_action_wallet_deregister_find_capture wallet_deregister_inventory \
      "${wallet_deregister_stage}" -mindepth 1 -maxdepth 1 -print || return 1
    found="${wallet_deregister_inventory}"
    while IFS= builtin read -r target; do
      [[ -n "${target}" ]] || continue
      leaf="${target#"${wallet_deregister_stage}/"}"
      [[ "${leaf}" != */* &&
         -n "${wallet_deregister_stage_identities[${leaf}]+set}" ]] ||
        cleanup_failed=1
    done <<< "${found}"
    (( cleanup_failed == 0 )) || return 1
    for leaf in "${wallet_deregister_stage_leaves[@]}"; do
      target="${wallet_deregister_stage}/${leaf}"
      [[ -e "${target}" || -L "${target}" ]] || continue
      _cntools_action_wallet_deregister_remove_leaf "${leaf}" || cleanup_failed=1
    done
    (( cleanup_failed == 0 )) || return 1
    _cntools_action_wallet_deregister_tools_same stat hash rmdir || return 1
    command_status=0
    "${wallet_deregister_rmdir_path}" -- "${wallet_deregister_stage}" \
      >/dev/null 2>&1 || command_status=1
    _cntools_action_wallet_deregister_tools_same rmdir hash stat || return 1
    [[ ! -e "${wallet_deregister_stage}" && ! -L "${wallet_deregister_stage}" ]] ||
      return 1
    wallet_deregister_stage=""
  fi
  _cntools_action_wallet_deregister_find_capture wallet_deregister_inventory \
    "${wallet_deregister_lock}" -mindepth 1 -maxdepth 1 -print || return 1
  found="${wallet_deregister_inventory}"
  [[ -z "${found}" ]] || return 1
  _cntools_action_wallet_deregister_tools_same stat hash rmdir || return 1
  command_status=0
  "${wallet_deregister_rmdir_path}" -- "${wallet_deregister_lock}" \
    >/dev/null 2>&1 || command_status=1
  _cntools_action_wallet_deregister_tools_same rmdir hash stat || return 1
  [[ ! -e "${wallet_deregister_lock}" && ! -L "${wallet_deregister_lock}" ]] ||
    return 1
  wallet_deregister_lock=""
  _cntools_action_wallet_deregister_cleanup_tools_same
}

_cntools_action_wallet_deregister_cleanup() {
  _cntools_action_wallet_deregister_cleanup_tools_same || return 1
  if [[ "${wallet_deregister_committed:-N}" != Y ]]; then
    # Publication reconciliation owns the decision about whether any public
    # hardlink may be removed.  If that proof is ambiguous, preserve the
    # inode-bound stage and lock as recovery authority; deleting them would
    # destroy the only authenticated record of the attempted publication.
    _cntools_action_wallet_deregister_rollback_publication || return 1
  fi
  _cntools_action_wallet_deregister_cleanup_stage
}

_cntools_action_wallet_deregister_finish_no_commit() {
  local message="${1:-}" wait_flag="${2:-Y}" status=0

  _cntools_action_wallet_deregister_cleanup || status=70
  if [[ "${status}" == 70 ]]; then
    _cntools_action_wallet_deregister_validation_failure
    trap - HUP INT TERM
    return 70
  fi
  [[ -z "${message}" ]] || println ERROR "${message}"
  [[ "${wait_flag}" != Y ]] || waitToProceed
  # Close the precommit signal window before inspecting its deferred state.
  # A signal delivered during the user wait must not turn an interrupted
  # operation into a handled status-zero result.
  trap '' HUP INT TERM
  if [[ "${wallet_deregister_signal_pending}" != N ]]; then
    _cntools_action_wallet_deregister_validation_failure
    trap - HUP INT TERM
    return 70
  fi
  trap - HUP INT TERM
  return 0
}

_cntools_action_wallet_deregister_finish_invariant() {
  local cleanup_status=0

  _cntools_action_wallet_deregister_cleanup || cleanup_status=70
  _cntools_action_wallet_deregister_validation_failure
  (( cleanup_status == 0 )) || println ERROR \
    'Wallet de-registration cleanup is incomplete; authenticated recovery authority was retained.'
  trap - HUP INT TERM
  return 70
}

_cntools_action_wallet_deregister_finish_submit_ambiguous() {
  println ERROR \
    'Wallet de-registration submission outcome is ambiguous; the certificate and authenticated recovery authority were retained.'
  waitToProceed
  trap - HUP INT TERM
  return 70
}

_cntools_action_wallet_deregister_signal() {
  wallet_deregister_signal_pending=Y
}

_cntools_action_wallet_deregister_publish_leaf() {
  local leaf="${1:-}" destination="${2:-}" parent
  parent="${destination%/*}"
  local parent_identity="${3:-}" parent_modes="${4:-}" metadata=""
  local mode="" size="" identity="" links="" command_status=0

  [[ -n "${wallet_deregister_stage_digests[${leaf}]+set}" &&
     ! -e "${destination}" && ! -L "${destination}" ]] || return 1
  _cntools_action_wallet_deregister_directory_same "${parent}" \
    "${parent_identity}" "${parent_modes}" || return 1
  _cntools_action_wallet_deregister_stage_hash "${leaf}" 1 1048576 \
    wallet_deregister_check_digest || return 70
  [[ "${wallet_deregister_check_digest}" == \
     "${wallet_deregister_stage_digests[${leaf}]}" ]] || return 70
  wallet_deregister_publish_attempts["${leaf}"]=Y
  _cntools_action_wallet_deregister_tools_same stat hash ln || return 70
  "${wallet_deregister_ln_path}" -- "${wallet_deregister_stage}/${leaf}" \
    "${destination}" >/dev/null 2>&1 || command_status=1
  _cntools_action_wallet_deregister_tools_same ln hash stat || return 70
  # Always reconcile the exact destination.  This records a hardlink created
  # by ln even when the creator reports an error.
  _cntools_action_wallet_deregister_publish_reconcile || return 70
  if [[ "${wallet_deregister_published[${leaf}]:-N}" != Y ]]; then
    (( command_status == 0 )) || return 1
    return 70
  fi
  _cntools_action_wallet_deregister_path_metadata "${destination}" 600 \
    1 1048576 2 wallet_deregister_metadata || return 70
  metadata="${wallet_deregister_metadata}"
  IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
    return 70
  [[ "${identity}" == "${wallet_deregister_stage_identities[${leaf}]}" ]] ||
    return 70
  _cntools_action_wallet_deregister_stage_hash "${leaf}" 1 1048576 \
    wallet_deregister_check_digest 2 || return 70
  [[ "${wallet_deregister_check_digest}" == \
     "${wallet_deregister_stage_digests[${leaf}]}" ]] || return 70
  wallet_deregister_published["${leaf}"]=Y
  wallet_deregister_publish_attempts["${leaf}"]=N
  [[ "${wallet_deregister_signal_pending}" == N ]] || return 70
}

_cntools_action_wallet_deregister_published_final_verify() {
  local leaf="" destination="" parent="" parent_identity="" metadata=""
  local mode="" size="" identity="" links="" fd="" digest=""

  for leaf in certificate.json offline.json; do
    [[ "${wallet_deregister_published[${leaf}]:-N}" == Y ]] || continue
    case "${leaf}" in
      certificate.json)
        destination="${wallet_deregister_certificate_destination}"
        parent="${wallet_deregister_wallet}"
        parent_identity="${wallet_deregister_wallet_identity}"
        ;;
      offline.json)
        destination="${wallet_deregister_offline_destination}"
        parent="${wallet_deregister_tmp_root}"
        parent_identity="${wallet_deregister_tmp_identity}"
        ;;
    esac
    _cntools_action_wallet_deregister_directory_same "${parent}" \
      "${parent_identity}" '700,750,755' || return 1
    _cntools_action_wallet_deregister_path_metadata "${destination}" 600 \
      1 1048576 1 wallet_deregister_metadata || return 1
    metadata="${wallet_deregister_metadata}"
    IFS=$'\t' builtin read -r mode size identity links <<< "${metadata}" ||
      return 1
    [[ "${identity}" == "${wallet_deregister_stage_identities[${leaf}]}" ]] ||
      return 1
    _cntools_action_wallet_deregister_open_bound "${destination}" "${identity}" \
      600 1 1048576 1 wallet_deregister_published_fd || return 1
    fd="${wallet_deregister_published_fd}"
    _cntools_action_wallet_deregister_hash_fd "${fd}" "${identity}" 600 \
      1 1048576 1 wallet_deregister_published_digest || {
        exec {fd}>&-
        return 1
      }
    digest="${wallet_deregister_published_digest}"
    exec {fd}>&-
    [[ "${digest}" == "${wallet_deregister_stage_digests[${leaf}]}" ]] ||
      return 1
  done
}

_cntools_action_wallet_deregister_ccli_resolve() {
  local candidate="${1:-}" output_name="${2:-}" resolved="" kind=""

  [[ "${output_name}" =~ ^wallet_deregister_(ccli|hwcli)_path$ ]] || return 1
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

_cntools_action_wallet_deregister_run_hardware_witness() {
  local body_fd="" payment_fd="" stake_fd="" payment_output_fd=""
  local stake_output_fd="" command_status=0

  _cntools_action_wallet_deregister_executable_same hwcli || return 70
  wallet_deregister_hardware_fd=""; wallet_deregister_payment_fd=""
  wallet_deregister_stake_fd=""; wallet_deregister_witness_payment_fd=""
  wallet_deregister_witness_stake_fd=""
  _cntools_action_wallet_deregister_stage_open tx.hardware 1 1048576 \
    wallet_deregister_hardware_fd || command_status=70
  body_fd="${wallet_deregister_hardware_fd:-}"
  _cntools_action_wallet_deregister_input_open payment_sk \
    wallet_deregister_payment_fd || command_status=70
  payment_fd="${wallet_deregister_payment_fd:-}"
  _cntools_action_wallet_deregister_input_open stake_sk \
    wallet_deregister_stake_fd || command_status=70
  stake_fd="${wallet_deregister_stake_fd:-}"
  _cntools_action_wallet_deregister_stage_open witness.payment 0 1048576 \
    wallet_deregister_witness_payment_fd || command_status=70
  payment_output_fd="${wallet_deregister_witness_payment_fd:-}"
  _cntools_action_wallet_deregister_stage_open witness.stake 0 1048576 \
    wallet_deregister_witness_stake_fd || command_status=70
  stake_output_fd="${wallet_deregister_witness_stake_fd:-}"
  if (( command_status == 0 )); then
    _cntools_action_wallet_deregister_descriptor_same "${payment_output_fd}" \
      "${wallet_deregister_stage_identities[witness.payment]}" 600 0 0 1 ||
      command_status=70
    _cntools_action_wallet_deregister_descriptor_same "${stake_output_fd}" \
      "${wallet_deregister_stage_identities[witness.stake]}" 600 0 0 1 ||
      command_status=70
  fi
  if (( command_status == 0 )); then
    println ACTION 'cardano-hw-cli wallet-deregister transaction witness'
    "${wallet_deregister_hwcli_path}" transaction witness \
      --tx-file "/dev/fd/${body_fd}" \
      --hw-signing-file "/dev/fd/${payment_fd}" \
      --change-output-key-file "/dev/fd/${payment_fd}" \
      --out-file "/dev/fd/${payment_output_fd}" \
      --hw-signing-file "/dev/fd/${stake_fd}" \
      --change-output-key-file "/dev/fd/${stake_fd}" \
      --out-file "/dev/fd/${stake_output_fd}" \
      "${wallet_deregister_network_args[@]}" >/dev/null 2>/dev/null ||
      command_status=1
  fi
  _cntools_action_wallet_deregister_executable_same hwcli || command_status=70
  if [[ -n "${payment_output_fd}" ]]; then
    _cntools_action_wallet_deregister_descriptor_same "${payment_output_fd}" \
      "${wallet_deregister_stage_identities[witness.payment]}" 600 \
      0 1048576 1 || command_status=70
    exec {payment_output_fd}>&-
  fi
  if [[ -n "${stake_output_fd}" ]]; then
    _cntools_action_wallet_deregister_descriptor_same "${stake_output_fd}" \
      "${wallet_deregister_stage_identities[witness.stake]}" 600 \
      0 1048576 1 || command_status=70
    exec {stake_output_fd}>&-
  fi
  if [[ -n "${payment_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      payment_sk "${payment_fd}" || command_status=70
  fi
  if [[ -n "${stake_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      stake_sk "${stake_fd}" || command_status=70
  fi
  if [[ -n "${body_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      tx.hardware "${body_fd}" 1 1048576 || command_status=70
  fi
  _cntools_action_wallet_deregister_stage_rebind witness.payment 0 1048576 ||
    command_status=70
  _cntools_action_wallet_deregister_stage_rebind witness.stake 0 1048576 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_deregister_stage_capture witness.payment 1 1048576 ||
      command_status=70
    _cntools_action_wallet_deregister_stage_capture witness.stake 1 1048576 ||
      command_status=70
  fi
  [[ "${wallet_deregister_signal_pending}" == N ]] || command_status=70
  return "${command_status}"
}

_cntools_action_wallet_deregister_local_query() {
  local schema="" rows="" stake_state="" tx_ref="" asset="" quantity=""
  local previous_ref="" row=""

  _cntools_action_wallet_deregister_run_output utxo.json --out-file \
    'cardano-cli wallet-deregister UTxO query' \
    "${wallet_deregister_ccli_path}" query utxo --address "${base_addr}" \
    "${wallet_deregister_network_args[@]}" || return $?
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
  _cntools_action_wallet_deregister_stage_jq utxo.json wallet_deregister_query_value \
    "${schema}" --arg address "${base_addr}" || return 70
  [[ "${wallet_deregister_query_value}" == true ]] || return 70
  _cntools_action_wallet_deregister_stage_jq utxo.json wallet_deregister_query_rows \
    'if length == 0 then "__cntools_empty_utxo__"
     else to_entries | sort_by(.key)[] | .key as $tx |
       .value.value | to_entries | sort_by(.key)[] |
       [$tx, .key, (.value|tostring)] | @tsv end' || return 70
  rows="${wallet_deregister_query_rows}"
  [[ "${rows}" != __cntools_empty_utxo__ ]] || rows=""
  while IFS=$'\t' builtin read -r tx_ref asset quantity; do
    [[ -n "${tx_ref}" && -n "${asset}" && -n "${quantity}" ]] || continue
    [[ "${tx_ref}" =~ ^[0-9a-fA-F]{64}#[0-9]{1,10}$ &&
       "${asset}" =~ ^(lovelace|[0-9a-fA-F]{56}(\.[0-9a-fA-F]{0,64})?)$ ]] ||
      return 70
    _cntools_action_wallet_deregister_uint_valid "${quantity}" || return 70
    if [[ -z "${wallet_deregister_tx_seen[${tx_ref}]+set}" ]]; then
      wallet_deregister_tx_seen["${tx_ref}"]=Y
      wallet_deregister_tx_inputs+=("${tx_ref}")
    fi
    if [[ "${asset}" == lovelace ]]; then
      _cntools_action_wallet_deregister_uint_add "${wallet_deregister_base_lovelace}" \
        "${quantity}" wallet_deregister_base_lovelace || return 70
    else
      wallet_deregister_asset_total="${wallet_deregister_assets[${asset}]:-0}"
      _cntools_action_wallet_deregister_uint_add "${wallet_deregister_asset_total}" \
        "${quantity}" wallet_deregister_asset_total || return 70
      wallet_deregister_assets["${asset}"]="${wallet_deregister_asset_total}"
    fi
  done <<< "${rows}"
  (( ${#wallet_deregister_tx_inputs[@]} <= 1024 )) || return 70

  _cntools_action_wallet_deregister_run_output stake.json --out-file \
    'cardano-cli wallet-deregister stake query' \
    "${wallet_deregister_ccli_path}" query stake-address-info \
    --address "${reward_addr}" "${wallet_deregister_network_args[@]}" || return $?
  _cntools_action_wallet_deregister_stage_jq stake.json wallet_deregister_query_value \
    'type == "array" and length <= 1 and
      all(.[]; type == "object" and .address == $address and
        ((.rewardAccountBalance // 0) | type == "number" and floor == . and
          . >= 0 and . <= 45000000000000000) and
        ((.stakeRegistrationDeposit // 0) | type == "number" and floor == . and
          . >= 0 and . <= 45000000000000000))' \
    --arg address "${reward_addr}" || return 70
  [[ "${wallet_deregister_query_value}" == true ]] || return 70
  _cntools_action_wallet_deregister_stage_jq stake.json wallet_deregister_query_value \
    'if length == 0 then "not registered\t0\t0"
     else [.[0].address, (.[0].rewardAccountBalance // 0),
       (.[0].stakeRegistrationDeposit // 0)] | @tsv end' || return 70
  if [[ "${wallet_deregister_query_value}" == $'not registered\t0\t0' ]]; then
    wallet_deregister_registered=N
  else
    IFS=$'\t' builtin read -r stake_state wallet_deregister_reward_lovelace \
      wallet_deregister_stake_deposit <<< "${wallet_deregister_query_value}" || return 70
    [[ "${stake_state}" == "${reward_addr}" ]] || return 70
    _cntools_action_wallet_deregister_uint_valid \
      "${wallet_deregister_reward_lovelace}" || return 70
    _cntools_action_wallet_deregister_uint_valid \
      "${wallet_deregister_stake_deposit}" || return 70
    (( wallet_deregister_stake_deposit > 0 )) || return 70
    wallet_deregister_registered=Y
  fi
}

_cntools_action_wallet_deregister_curl_query() {
  local leaf="${1:-}" endpoint="${2:-}" payload_leaf="${3:-}"
  local output_fd="" payload_fd="" config_fd="" command_status=0
  local -a arguments=()

  case "${endpoint}" in
    'address_utxos?select=address,tx_hash,tx_index,value,asset_list'|\
      'account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit'|\
      'tx_status?select=tx_hash,num_confirmations') ;;
    *) return 70 ;;
  esac
  _cntools_action_wallet_deregister_stage_open "${leaf}" 0 1048576 \
    wallet_deregister_tool_output_fd || return 70
  output_fd="${wallet_deregister_tool_output_fd}"
  _cntools_action_wallet_deregister_stage_open "${payload_leaf}" 1 1048576 \
    wallet_deregister_payload_fd || command_status=70
  payload_fd="${wallet_deregister_payload_fd:-}"
  _cntools_action_wallet_deregister_stage_open curl.config 0 65536 \
    wallet_deregister_config_fd || command_status=70
  config_fd="${wallet_deregister_config_fd:-}"
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 0 0 1 ||
    command_status=70
  arguments=("${wallet_deregister_curl_path}" --config "/dev/fd/${config_fd}"
    --disable --silent --show-error
    --proto '=https' --connect-timeout "${wallet_deregister_curl_timeout}"
    --max-time "${wallet_deregister_curl_timeout}" --fail
    --max-filesize 1048576 --header 'content-type: application/json'
    --request POST --data-binary "@/dev/fd/${payload_fd}"
    --output "/dev/fd/${output_fd}"
    --url "${wallet_deregister_koios_api}/${endpoint}")
  _cntools_action_wallet_deregister_executable_same curl || command_status=70
  if (( command_status == 0 )); then
    println ACTION 'curl [configured headers redacted] CNTools wallet-deregister query'
    "${arguments[@]}" >/dev/null 2>/dev/null || command_status=1
  fi
  _cntools_action_wallet_deregister_executable_same curl || command_status=70
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[${leaf}]}" 600 0 1048576 1 ||
    command_status=70
  exec {output_fd}>&-
  if [[ -n "${payload_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      "${payload_leaf}" "${payload_fd}" 1 1048576 || command_status=70
  fi
  if [[ -n "${config_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      curl.config "${config_fd}" 0 65536 || command_status=70
  fi
  _cntools_action_wallet_deregister_stage_rebind "${leaf}" 0 1048576 ||
    command_status=70
  [[ "${wallet_deregister_signal_pending}" == N ]] || command_status=70
  return "${command_status}"
}

_cntools_action_wallet_deregister_light_query() {
  local rows="" tx_hash="" tx_index="" value="" policy=""
  local asset_name="" quantity="" tx_ref="" asset="" stake_state=""

  _cntools_action_wallet_deregister_stage_generate_json utxo.payload \
    '{_addresses:[$address]}' --arg address "${base_addr}" || return 70
  _cntools_action_wallet_deregister_curl_query utxo.json \
    'address_utxos?select=address,tx_hash,tx_index,value,asset_list' \
    utxo.payload || return $?
  _cntools_action_wallet_deregister_stage_jq utxo.json wallet_deregister_query_value \
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
  [[ "${wallet_deregister_query_value}" == true ]] || return 70
  _cntools_action_wallet_deregister_stage_jq utxo.json wallet_deregister_query_rows \
    'if length == 0 then "__cntools_empty_utxo__"
     else . | sort_by(.tx_hash,.tx_index)[] |
       [.tx_hash, (.tx_index|tostring), (.value|tostring),
        ((.asset_list // []) | map([.policy_id,.asset_name,(.quantity|tostring)] | join(":")) | join(","))] |
       @tsv end' || return 70
  rows="${wallet_deregister_query_rows}"
  [[ "${rows}" != __cntools_empty_utxo__ ]] || rows=""
  while IFS=$'\t' builtin read -r tx_hash tx_index value wallet_deregister_asset_rows; do
    [[ -n "${tx_hash}" && -n "${tx_index}" && -n "${value}" ]] || continue
    [[ "${tx_hash}" =~ ^[0-9a-fA-F]{64}$ && "${tx_index}" =~ ^[0-9]+$ ]] ||
      return 70
    _cntools_action_wallet_deregister_uint_valid "${value}" || return 70
    tx_ref="${tx_hash}#${tx_index}"
    [[ -z "${wallet_deregister_tx_seen[${tx_ref}]+set}" ]] || return 70
    wallet_deregister_tx_seen["${tx_ref}"]=Y
    wallet_deregister_tx_inputs+=("${tx_ref}")
    _cntools_action_wallet_deregister_uint_add "${wallet_deregister_base_lovelace}" \
      "${value}" wallet_deregister_base_lovelace || return 70
    [[ -z "${wallet_deregister_asset_rows}" ]] || {
      while IFS=: builtin read -r policy asset_name quantity; do
        [[ "${policy}" =~ ^[0-9a-fA-F]{56}$ &&
           "${asset_name}" =~ ^[0-9a-fA-F]{0,64}$ ]] || return 70
        _cntools_action_wallet_deregister_uint_valid "${quantity}" || return 70
        asset="${policy}"
        [[ -z "${asset_name}" ]] || asset+=".${asset_name}"
        wallet_deregister_asset_total="${wallet_deregister_assets[${asset}]:-0}"
        _cntools_action_wallet_deregister_uint_add "${wallet_deregister_asset_total}" \
          "${quantity}" wallet_deregister_asset_total || return 70
        wallet_deregister_assets["${asset}"]="${wallet_deregister_asset_total}"
      done <<< "${wallet_deregister_asset_rows//,/$'\n'}"
    }
  done <<< "${rows}"

  _cntools_action_wallet_deregister_stage_generate_json stake.payload \
    '{_stake_addresses:[$address]}' --arg address "${reward_addr}" || return 70
  _cntools_action_wallet_deregister_curl_query stake.json \
    'account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit' \
    stake.payload || return $?
  _cntools_action_wallet_deregister_stage_jq stake.json wallet_deregister_query_value \
    'type == "array" and length <= 1 and
      all(.[]; type == "object" and .stake_address == $address and
        (.status == "registered" or .status == "not registered") and
        ((.rewards_available // 0) | type == "number" and floor == . and
          . >= 0 and . <= 45000000000000000) and
        ((.deposit // 0) | type == "number" and floor == . and
          . >= 0 and . <= 45000000000000000))' \
    --arg address "${reward_addr}" || return 70
  [[ "${wallet_deregister_query_value}" == true ]] || return 70
  _cntools_action_wallet_deregister_stage_jq stake.json wallet_deregister_query_value \
    'if length == 0 then "not registered\t0\t0"
     else [.[0].status, (.[0].rewards_available // 0),
       (.[0].deposit // 0)] | @tsv end' || return 70
  if [[ "${wallet_deregister_query_value}" == $'not registered\t0\t0' ]]; then
    wallet_deregister_registered=N
  else
    IFS=$'\t' builtin read -r stake_state wallet_deregister_reward_lovelace \
      wallet_deregister_stake_deposit <<< "${wallet_deregister_query_value}" || return 70
    [[ "${stake_state}" == registered ]] || {
      wallet_deregister_registered=N
      return 0
    }
    _cntools_action_wallet_deregister_uint_valid \
      "${wallet_deregister_reward_lovelace}" || return 70
    _cntools_action_wallet_deregister_uint_valid \
      "${wallet_deregister_stake_deposit}" || return 70
    (( wallet_deregister_stake_deposit > 0 )) || return 70
    wallet_deregister_registered=Y
  fi
}

_cntools_action_wallet_deregister_tx_schema() {
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
  _cntools_action_wallet_deregister_stage_jq "${leaf}" wallet_deregister_query_value \
    "${filter}" || return 1
  [[ "${wallet_deregister_query_value}" == true ]]
}

_cntools_action_wallet_deregister_certificate_schema() {
  _cntools_action_wallet_deregister_stage_jq certificate.json \
    wallet_deregister_query_value '
      type == "object" and keys == ["cborHex","description","type"] and
      (.type | type == "string" and
        test("^StakeAddressDeregistrationCertificate")) and
      (.description | type == "string" and length <= 256) and
      (.cborHex | type == "string" and test("^[0-9a-fA-F]{2,32768}$") and
       (length % 2 == 0))' || return 1
  [[ "${wallet_deregister_query_value}" == true ]]
}

_cntools_action_wallet_deregister_derive_txid() {
  local signed_fd="" command_status=0 value=""
  local -a arguments=()

  _cntools_action_wallet_deregister_stage_open tx.signed 1 1048576 \
    wallet_deregister_signed_fd || return 70
  signed_fd="${wallet_deregister_signed_fd}"
  arguments=("${wallet_deregister_ccli_path}" latest transaction txid
    --output-text --tx-file "/dev/fd/${signed_fd}")
  _cntools_action_wallet_deregister_run_output txid.out stdout \
    'cardano-cli wallet-deregister transaction identifier' \
    "${arguments[@]}" || command_status=$?
  _cntools_action_wallet_deregister_stage_close_verified \
    tx.signed "${signed_fd}" 1 1048576 || command_status=70
  (( command_status == 0 )) || return "${command_status}"
  _cntools_action_wallet_deregister_stage_read txid.out \
    wallet_deregister_output_value 128 || return 70
  value="${wallet_deregister_output_value}"
  [[ "${value}" =~ ^[0-9a-fA-F]{64}$ ]] || return 70
  wallet_deregister_tx_id="${value,,}"
  _cntools_action_wallet_deregister_stage_capture txid.out 64 128 || return 70
}

_cntools_action_wallet_deregister_build_submit_payload() {
  local signed_fd="" output_fd="" command_status=0

  _cntools_action_wallet_deregister_stage_open tx.signed 1 1048576 \
    wallet_deregister_signed_fd || return 70
  signed_fd="${wallet_deregister_signed_fd}"
  _cntools_action_wallet_deregister_stage_open submit.payload 0 1048576 \
    wallet_deregister_json_output_fd || command_status=70
  output_fd="${wallet_deregister_json_output_fd:-}"
  _cntools_action_wallet_deregister_executable_same jq || command_status=70
  if (( command_status == 0 )); then
    "${wallet_deregister_jq_path}" -ce '
      {jsonrpc:"2.0",method:"submitTransaction",
       params:{transaction:{cbor:.cborHex}}}' \
      "/dev/fd/${signed_fd}" 1>&"${output_fd}" 2>/dev/null ||
      command_status=70
  fi
  _cntools_action_wallet_deregister_executable_same jq || command_status=70
  if [[ -n "${output_fd}" ]]; then
    _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
      "${wallet_deregister_stage_identities[submit.payload]}" 600 \
      1 1048576 1 || command_status=70
    exec {output_fd}>&-
  fi
  _cntools_action_wallet_deregister_stage_close_verified \
    tx.signed "${signed_fd}" 1 1048576 || command_status=70
  _cntools_action_wallet_deregister_stage_rebind submit.payload 1 1048576 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_deregister_stage_capture submit.payload 1 1048576 ||
      command_status=70
  fi
  (( command_status == 0 )) || return "${command_status}"
  _cntools_action_wallet_deregister_stage_jq submit.payload \
    wallet_deregister_query_value '
      type == "object" and keys == ["jsonrpc","method","params"] and
      .jsonrpc == "2.0" and .method == "submitTransaction" and
      (.params | type == "object" and keys == ["transaction"]) and
      (.params.transaction | type == "object" and keys == ["cbor"]) and
      (.params.transaction.cbor | type == "string" and
       length >= 2 and length <= 1048574 and test("^[0-9a-fA-F]+$") and
       (length % 2 == 0))' || return 70
  [[ "${wallet_deregister_query_value}" == true ]] || return 70
}

_cntools_action_wallet_deregister_light_submit_once() {
  local output_fd="" payload_fd="" config_fd="" command_status=0
  local -a arguments=()

  _cntools_action_wallet_deregister_stage_open submit.out 0 1048576 \
    wallet_deregister_tool_output_fd || return 70
  output_fd="${wallet_deregister_tool_output_fd}"
  _cntools_action_wallet_deregister_stage_open submit.payload 1 1048576 \
    wallet_deregister_payload_fd || command_status=70
  payload_fd="${wallet_deregister_payload_fd:-}"
  _cntools_action_wallet_deregister_stage_open curl.config 0 65536 \
    wallet_deregister_config_fd || command_status=70
  config_fd="${wallet_deregister_config_fd:-}"
  _cntools_action_wallet_deregister_executable_same curl || command_status=70
  arguments=("${wallet_deregister_curl_path}" --config "/dev/fd/${config_fd}"
    --disable --silent --show-error --proto '=https'
    --connect-timeout "${wallet_deregister_curl_timeout}"
    --max-time "${wallet_deregister_curl_timeout}" --fail
    --max-filesize 1048576 --header 'accept: application/json'
    --header 'content-type: application/json' --request POST
    --data-binary "@/dev/fd/${payload_fd}" --output "/dev/fd/${output_fd}"
    --url "${wallet_deregister_koios_api}/ogmios/")
  if (( command_status == 0 )); then
    println ACTION \
      'curl [configured headers and body redacted] CNTools wallet-deregister submit attempt'
    if [[ "${wallet_deregister_signal_pending}" != N ]]; then
      command_status=70
    else
      wallet_deregister_submit_started=Y
      "${arguments[@]}" >/dev/null 2>/dev/null || command_status=1
    fi
  fi
  _cntools_action_wallet_deregister_executable_same curl || command_status=70
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[submit.out]}" 600 0 1048576 1 ||
    command_status=70
  exec {output_fd}>&-
  if [[ -n "${payload_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      submit.payload "${payload_fd}" 1 1048576 || command_status=70
  fi
  if [[ -n "${config_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      curl.config "${config_fd}" 0 65536 || command_status=70
  fi
  _cntools_action_wallet_deregister_stage_rebind submit.out 0 1048576 ||
    command_status=70
  (( command_status == 0 )) || return "${command_status}"
  _cntools_action_wallet_deregister_stage_jq submit.out \
    wallet_deregister_query_value '
      type == "object" and has("result") and (.result != null) and
      (has("error") | not)' || return 70
  [[ "${wallet_deregister_query_value}" == true ]] || return 70
  _cntools_action_wallet_deregister_stage_capture submit.out 1 1048576 ||
    return 70
}

_cntools_action_wallet_deregister_confirm() {
  local attempt=0 leaf="" phase_status=0 tx_ref=""

  wallet_deregister_confirmation_state=pending
  println DEBUG "Submitted transaction ID: ${wallet_deregister_tx_id}"
  println DEBUG \
    'Checking confirmation up to three times; press any key to cancel the check.'
  tx_ref="${wallet_deregister_tx_id}#0"
  for ((attempt=1; attempt<=3; attempt++)); do
    if [[ -t 0 ]] && builtin read -r -n 1 -s -t 1; then
      wallet_deregister_confirmation_state=canceled
      return 1
    fi
    leaf="verify.${attempt}.json"
    phase_status=0
    if [[ "${context_mode}" == local ]]; then
      _cntools_action_wallet_deregister_run_output "${leaf}" --out-file \
        'cardano-cli wallet-deregister bounded confirmation query' \
        "${wallet_deregister_ccli_path}" query utxo --tx-in "${tx_ref}" \
        "${wallet_deregister_network_args[@]}" || phase_status=$?
      [[ "${phase_status}" == 0 ]] || {
        [[ "${phase_status}" == 1 ]] && continue
        return 70
      }
      _cntools_action_wallet_deregister_stage_jq "${leaf}" \
        wallet_deregister_query_value '
          if (type == "object" and length <= 1024 and
              all(keys[]; test("^[0-9a-fA-F]{64}#[0-9]{1,10}$"))) then
            if has($tx) then "confirmed" else "pending" end
          else error("invalid confirmation response") end' \
        --arg tx "${tx_ref}" || return 70
    else
      _cntools_action_wallet_deregister_curl_query "${leaf}" \
        'tx_status?select=tx_hash,num_confirmations' verify.payload ||
        phase_status=$?
      [[ "${phase_status}" == 0 ]] || {
        [[ "${phase_status}" == 1 ]] && continue
        return 70
      }
      _cntools_action_wallet_deregister_stage_jq "${leaf}" \
        wallet_deregister_query_value '
          if (type == "array" and length <= 1 and
              all(.[]; type == "object" and .tx_hash == $tx and
                (.num_confirmations | type == "number" and floor == . and
                 . >= 0 and . <= 1000000000))) then
            if length == 1 then "confirmed" else "pending" end
          else error("invalid confirmation response") end' \
        --arg tx "${wallet_deregister_tx_id}" || return 70
    fi
    if [[ "${wallet_deregister_query_value}" == confirmed ]]; then
      wallet_deregister_confirmation_state=confirmed
      return 0
    fi
  done
  return 1
}

_cntools_action_wallet_deregister_build_offline() {
  local output_fd="" tx_fd="" pay_fd="" stake_fd=""
  local payment_script_fd="" stake_script_fd="" command_status=0
  local created="" identifier="" expires="" total_fee=0
  local -a arguments=()

  _cntools_action_wallet_deregister_executable_same date || return 70
  identifier="$("${wallet_deregister_date_path}" +%s 2>/dev/null)" || return 70
  _cntools_action_wallet_deregister_executable_same date || return 70
  [[ "${identifier}" =~ ^[1-9][0-9]{8,15}$ ]] || return 70
  created="$("${wallet_deregister_date_path}" -u '+%Y-%m-%dT%H:%M:%SZ' \
    2>/dev/null)" ||
    return 70
  _cntools_action_wallet_deregister_executable_same date || return 70
  [[ "${created}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    return 70
  expires="${created}"
  total_fee="${wallet_deregister_min_fee}"
  _cntools_action_wallet_deregister_uint_valid "${total_fee}" || return 70
  wallet_deregister_offline_leaf="offline_tx_${identifier}.json"
  _cntools_action_wallet_deregister_leaf_valid "${wallet_deregister_offline_leaf}" ||
    return 70
  wallet_deregister_offline_destination="${wallet_deregister_tmp_root}/${wallet_deregister_offline_leaf}"
  [[ ! -e "${wallet_deregister_offline_destination}" &&
     ! -L "${wallet_deregister_offline_destination}" ]] || return 1

  _cntools_action_wallet_deregister_stage_open offline.json 0 1048576 \
    wallet_deregister_offline_fd || return 70
  output_fd="${wallet_deregister_offline_fd}"
  _cntools_action_wallet_deregister_stage_open tx.raw 1 1048576 \
    wallet_deregister_tx_fd || command_status=70
  tx_fd="${wallet_deregister_tx_fd:-}"
  if (( command_status == 0 )); then
    if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
      _cntools_action_wallet_deregister_input_open payment_script \
        wallet_deregister_payment_script_fd || command_status=70
      payment_script_fd="${wallet_deregister_payment_script_fd:-}"
      _cntools_action_wallet_deregister_input_open stake_script \
        wallet_deregister_stake_script_fd || command_status=70
      stake_script_fd="${wallet_deregister_stake_script_fd:-}"
    else
      _cntools_action_wallet_deregister_input_open payment_vk \
        wallet_deregister_payment_vk_fd || command_status=70
      pay_fd="${wallet_deregister_payment_vk_fd:-}"
      _cntools_action_wallet_deregister_input_open stake_vk \
        wallet_deregister_stake_vk_fd || command_status=70
      stake_fd="${wallet_deregister_stake_vk_fd:-}"
    fi
  fi
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[offline.json]}" 600 0 0 1 ||
    command_status=70
  if (( command_status == 0 )); then
    _cntools_action_wallet_deregister_executable_same jq || command_status=70
  fi
  if (( command_status == 0 )); then
    arguments=("${wallet_deregister_jq_path}" -nS
      --arg id "${identifier}" --arg wallet "${wallet_deregister_wallet_name}"
      --arg created "${created}" --arg expires "${expires}"
      --argjson ttl "${wallet_deregister_ttl}"
      --argjson fee "${total_fee}"
      --argjson amount "${wallet_deregister_stake_deposit}"
      --slurpfile txBody "/dev/fd/${tx_fd}")
    if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
      arguments+=(--slurpfile payment "/dev/fd/${payment_script_fd}"
        --slurpfile stake "/dev/fd/${stake_script_fd}"
        '{id:$id,type:"Wallet De-Registration","wallet-name":$wallet,
          "amount-returned":$amount,"date-created":$created,
          "date-expire":$expires,ttl:$ttl,txFee:$fee,
          txBody:$txBody[0],"signed-txBody":{},"signing-file":[],witness:[],
          "script-file":[
            {name:("Wallet " + $wallet + " payment script"),script:$payment[0]},
            {name:("Wallet " + $wallet + " stake script"),script:$stake[0]}]}')
    else
      arguments+=(--slurpfile payment "/dev/fd/${pay_fd}"
        --slurpfile stake "/dev/fd/${stake_fd}"
        '{id:$id,type:"Wallet De-Registration","wallet-name":$wallet,
          "amount-returned":$amount,"date-created":$created,
          "date-expire":$expires,ttl:$ttl,txFee:$fee,
          txBody:$txBody[0],"signed-txBody":{},"script-file":[],witness:[],
          "signing-file":[
            {name:("Wallet " + $wallet + " payment signing key"),vkey:$payment[0]},
            {name:("Wallet " + $wallet + " stake signing key"),vkey:$stake[0]}]}')
    fi
    "${arguments[@]}" 1>&"${output_fd}" 2>/dev/null ||
      command_status=70
  fi
  _cntools_action_wallet_deregister_executable_same jq || command_status=70
  if [[ -n "${tx_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      tx.raw "${tx_fd}" 1 1048576 || command_status=70
  fi
  if [[ -n "${pay_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      payment_vk "${pay_fd}" || command_status=70
  fi
  if [[ -n "${stake_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      stake_vk "${stake_fd}" || command_status=70
  fi
  if [[ -n "${payment_script_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      payment_script "${payment_script_fd}" || command_status=70
  fi
  if [[ -n "${stake_script_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      stake_script "${stake_script_fd}" || command_status=70
  fi
  _cntools_action_wallet_deregister_descriptor_same "${output_fd}" \
    "${wallet_deregister_stage_identities[offline.json]}" 600 1 1048576 1 ||
    command_status=70
  exec {output_fd}>&-
  _cntools_action_wallet_deregister_stage_rebind offline.json 0 1048576 ||
    command_status=70
  [[ "${wallet_deregister_signal_pending}" == N ]] || command_status=70
  (( command_status == 0 )) || return "${command_status}"
  _cntools_action_wallet_deregister_stage_jq offline.json wallet_deregister_query_value '
    type == "object" and
    keys == ["amount-returned","date-created","date-expire","id","script-file","signed-txBody","signing-file","ttl","txBody","txFee","type","wallet-name","witness"] and
    .id == $id and .type == "Wallet De-Registration" and
    ."wallet-name" == $wallet and (.ttl|type=="number") and
    (."amount-returned" == $amount) and (.txFee == $fee) and
    (.txBody|type=="object") and
    (."signed-txBody"|type=="object") and
    (."signing-file"|type=="array" and length<=2) and
    (."script-file"|type=="array" and length<=2) and
    (.witness|type=="array" and length==0)' \
    --arg id "${identifier}" --arg wallet "${wallet_deregister_wallet_name}" \
    --argjson amount "${wallet_deregister_stake_deposit}" \
    --argjson fee "${total_fee}" ||
    return 70
  [[ "${wallet_deregister_query_value}" == true ]] || return 70
  _cntools_action_wallet_deregister_stage_capture offline.json 1 1048576 ||
    return 70
}

_cntools_action_wallet_deregister_prefixed_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local context_network="" network_magic="" private_parent="" filename=""
  local action_status=0 selection_status=0 wallet_type_status=0 query_status=0
  local mkdir_status=0
  local phase_status=0 header_index=0 header_value="" found="" target=""
  local header_declaration="" ambient_declaration=""
  local wallet_name="" op_mode="${op_mode:-}" ttl="" required_total=""
  local metadata="" mode="" size="" identity="" links="" leaf=""
  local wallet_deregister_root="" wallet_deregister_wallet="" wallet_deregister_tmp_root=""
  local wallet_deregister_root_identity="" wallet_deregister_wallet_identity=""
  local wallet_deregister_tmp_identity="" wallet_deregister_lock=""
  local wallet_deregister_stage="" wallet_deregister_lock_identity=""
  local wallet_deregister_stage_identity="" wallet_deregister_check_identity=""
  local wallet_deregister_wallet_real=""
  local wallet_deregister_wallet_name="" wallet_deregister_wallet_type=""
  local wallet_deregister_certificate_destination=""
  local wallet_deregister_offline_destination="" wallet_deregister_offline_leaf=""
  local wallet_deregister_registered=N wallet_deregister_committed=N
  local wallet_deregister_signal_pending=N wallet_deregister_trace_was_on=N
  local wallet_deregister_commit_window=N wallet_deregister_submit_started=N
  local wallet_deregister_submission_ambiguous=N
  local wallet_deregister_jq_path="" wallet_deregister_mkdir_path=""
  local wallet_deregister_rmdir_path="" wallet_deregister_rm_path=""
  local wallet_deregister_ln_path="" wallet_deregister_find_path=""
  local wallet_deregister_sort_path="" wallet_deregister_stat_path=""
  local wallet_deregister_hash_path="" wallet_deregister_hash_kind=""
  local wallet_deregister_tool_digest=""
  local wallet_deregister_date_path="" wallet_deregister_curl_path=""
  local wallet_deregister_ccli_path="" wallet_deregister_hwcli_path=""
  local wallet_deregister_curl_timeout=""
  local wallet_deregister_koios_api="" wallet_deregister_metadata=""
  local wallet_deregister_input_fd="" wallet_deregister_input_digest=""
  local wallet_deregister_verify_fd="" wallet_deregister_rebind_fd=""
  local wallet_deregister_check_digest="" wallet_deregister_read_fd=""
  local wallet_deregister_digest_fd="" wallet_deregister_jq_fd=""
  local wallet_deregister_published_fd="" wallet_deregister_published_digest=""
  local wallet_deregister_tool_output_fd="" wallet_deregister_tool_log_fd=""
  local wallet_deregister_json_output_fd="" wallet_deregister_config_fd=""
  local wallet_deregister_payload_fd=""
  local wallet_deregister_certificate_fd="" wallet_deregister_draft_fd=""
  local wallet_deregister_offline_fd="" wallet_deregister_tx_fd=""
  local wallet_deregister_payment_fd="" wallet_deregister_stake_fd=""
  local wallet_deregister_hardware_fd=""
  local wallet_deregister_payment_script_fd="" wallet_deregister_stake_script_fd=""
  local wallet_deregister_payment_vk_fd="" wallet_deregister_stake_vk_fd=""
  local wallet_deregister_protocol_fd="" wallet_deregister_raw_fd=""
  local wallet_deregister_signed_fd="" wallet_deregister_witness_payment_fd=""
  local wallet_deregister_witness_stake_fd="" wallet_deregister_check_fd=""
  local wallet_deregister_offline_digest=""
  local wallet_deregister_tx_id="" wallet_deregister_confirmation_state=""
  local wallet_deregister_capture_digest="" wallet_deregister_close_digest=""
  local wallet_deregister_query_value="" wallet_deregister_query_rows=""
  local wallet_deregister_found="" wallet_deregister_inventory=""
  local wallet_deregister_sorted_assets=""
  local wallet_deregister_asset_rows="" wallet_deregister_asset_total=0
  local wallet_deregister_base_lovelace=0 wallet_deregister_assets_suffix=""
  local wallet_deregister_available_lovelace=0
  local wallet_deregister_reward_lovelace=0 wallet_deregister_stake_deposit=0
  local wallet_deregister_min_fee=0 wallet_deregister_min_utxo=0
  local wallet_deregister_ttl=0 wallet_deregister_dummy_balance=0
  local base_addr="" pay_addr="" reward_addr="" tx_ref="" asset=""
  local quantity="" tx_out="" formatted="" witness_count=2
  local payment_vk_file="" payment_sk_file="" payment_script_file=""
  local stake_vk_file="" stake_sk_file="" stake_script_file=""
  local expected_payment_sk_file="" expected_stake_sk_file=""
  local certificate_fd="" draft_fd="" raw_fd="" protocol_fd=""
  local payment_fd="" stake_fd="" witness_payment_fd=""
  local witness_stake_fd="" signed_fd="" wallet_deregister_output_value=""
  local payment_script_fd="" stake_script_fd=""
  local wallet_deregister_body_leaf=tx.raw
  local tx_id=""
  local wallet_deregister_script_payment="" wallet_deregister_script_stake=""
  local -a wallet_deregister_network_args=() wallet_deregister_koios_headers=()
  local -a wallet_deregister_stage_leaves=() wallet_deregister_tx_inputs=()
  local -a build_arguments=() command_arguments=() witness_arguments=()
  local -A wallet_deregister_stage_identities=() wallet_deregister_stage_digests=()
  local -A wallet_deregister_input_paths=() wallet_deregister_input_modes=()
  local -A wallet_deregister_input_identities=() wallet_deregister_input_digests=()
  local -A wallet_deregister_input_maximums=() wallet_deregister_tx_seen=()
  local -A wallet_deregister_assets=() wallet_deregister_publish_attempts=()
  local -A wallet_deregister_published=()
  local -A wallet_deregister_tool_paths=() wallet_deregister_tool_metadata=()
  local -A wallet_deregister_tool_digests=()
  local LC_ALL=C

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  case "$-" in *x*) wallet_deregister_trace_was_on=Y; builtin set +x ;; esac
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F cntools_context_has >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_target_validate >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate >/dev/null 2>&1 ||
     ! builtin declare -F clear >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F selectOpMode >/dev/null 2>&1 ||
     ! builtin declare -F selectWallet >/dev/null 2>&1 ||
     ! builtin declare -F getWalletType >/dev/null 2>&1 ||
     ! builtin declare -F getTTL >/dev/null 2>&1 ||
     ! builtin declare -F versionCheck >/dev/null 2>&1; then
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 64
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  [[ "${context_mode}" == local || "${context_mode}" == light ]] || {
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 64
  }
  if [[ "${context_mode}" == local ]] &&
     ! cntools_context_has "${context_file}" capabilities local-cli; then
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 64
  fi
  for filename in jq mkdir rmdir rm ln find sort stat date; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq wallet_deregister_jq_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir wallet_deregister_mkdir_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir wallet_deregister_rmdir_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_deregister_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln wallet_deregister_ln_path || action_status=70 ;;
      find) _cntools_registry_tool_path find wallet_deregister_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort wallet_deregister_sort_path || action_status=70 ;;
      stat) _cntools_registry_tool_path stat wallet_deregister_stat_path || action_status=70 ;;
      date) _cntools_registry_tool_path date wallet_deregister_date_path || action_status=70 ;;
    esac
  done
  if _cntools_registry_tool_path sha256sum wallet_deregister_hash_path; then
    wallet_deregister_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum wallet_deregister_hash_path; then
    wallet_deregister_hash_kind=shasum
  else
    action_status=70
  fi
  if (( action_status == 0 )); then
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_stat_path}" stat || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_hash_path}" hash || action_status=70
  fi
  if (( action_status == 0 )); then
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_mkdir_path}" mkdir || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_rmdir_path}" rmdir || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_rm_path}" rm || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_ln_path}" ln || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_find_path}" find || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_sort_path}" sort || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_jq_path}" jq || action_status=70
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_date_path}" date || action_status=70
  fi
  _cntools_action_wallet_deregister_ccli_resolve "${CCLI:-}" \
    wallet_deregister_ccli_path || action_status=70
  (( action_status != 0 )) ||
    _cntools_action_wallet_deregister_executable_capture \
      "${wallet_deregister_ccli_path}" ccli || action_status=70
  if [[ "${context_mode}" == light ]]; then
    _cntools_registry_tool_path curl wallet_deregister_curl_path || action_status=70
    (( action_status != 0 )) ||
      _cntools_action_wallet_deregister_executable_capture \
        "${wallet_deregister_curl_path}" curl || action_status=70
  fi
  (( action_status != 0 )) ||
    _cntools_action_wallet_deregister_tools_same stat hash mkdir rmdir rm ln find sort jq date ccli ||
    action_status=70
  if [[ "${context_mode}" == light && "${action_status}" == 0 ]]; then
    _cntools_action_wallet_deregister_executable_same curl || action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }

  _cntools_result_target_validate "${result_file}" || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${private_parent}" || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  [[ "${WALLET_FOLDER:-}" == /* && "${TMP_DIR:-}" == /* ]] || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  wallet_deregister_root="$(builtin cd -P -- "${WALLET_FOLDER}" && builtin pwd -P)" ||
    action_status=70
  wallet_deregister_tmp_root="$(builtin cd -P -- "${TMP_DIR}" && builtin pwd -P)" ||
    action_status=70
  [[ "${wallet_deregister_root}" == "${WALLET_FOLDER}" &&
     "${wallet_deregister_tmp_root}" == "${TMP_DIR}" ]] || action_status=70
  _cntools_action_wallet_deregister_paths_disjoint \
    "${wallet_deregister_root}" "${wallet_deregister_tmp_root}" || action_status=70
  _cntools_action_wallet_deregister_paths_disjoint \
    "${wallet_deregister_root}" "${private_parent}" || action_status=70
  _cntools_action_wallet_deregister_paths_disjoint \
    "${wallet_deregister_tmp_root}" "${private_parent}" || action_status=70
  _cntools_action_wallet_deregister_directory_identity "${wallet_deregister_root}" \
    '700,750,755' wallet_deregister_root_identity || action_status=70
  _cntools_action_wallet_deregister_directory_identity "${wallet_deregister_tmp_root}" \
    '700,750,755' wallet_deregister_tmp_identity || action_status=70
  for filename in "${WALLET_PAY_VK_FILENAME:-}" \
      "${WALLET_PAY_SK_FILENAME:-}" "${WALLET_STAKE_VK_FILENAME:-}" \
      "${WALLET_STAKE_SK_FILENAME:-}" "${WALLET_PAY_SCRIPT_FILENAME:-}" \
      "${WALLET_STAKE_SCRIPT_FILENAME:-}" "${WALLET_BASE_ADDR_FILENAME:-}" \
      "${WALLET_PAY_ADDR_FILENAME:-}" "${WALLET_STAKE_ADDR_FILENAME:-}" \
      "${WALLET_STAKE_DEREG_FILENAME:-}"; do
    _cntools_action_wallet_deregister_leaf_valid "${filename}" || action_status=70
  done
  [[ "${DUMMYFEE:-}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${PROT_VERSION:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$ ]] ||
    action_status=70
  case "${NETWORK_IDENTIFIER:-}" in
    --mainnet)
      wallet_deregister_network_args=(--mainnet)
      [[ "${context_network}" == mainnet ]] || action_status=64
      ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 &&
         "${context_network}" != mainnet ]] || action_status=64
      wallet_deregister_network_args=(--testnet-magic "${network_magic}")
      ;;
    *) action_status=64 ;;
  esac
  if [[ "${context_mode}" == light ]]; then
    wallet_deregister_curl_timeout="${CURL_TIMEOUT:-10}"
    [[ "${wallet_deregister_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] ||
      action_status=70
    wallet_deregister_koios_api="${KOIOS_API%/}"
    [[ "${#wallet_deregister_koios_api}" -ge 9 &&
       "${#wallet_deregister_koios_api}" -le 2048 &&
       "${wallet_deregister_koios_api}" == https://* &&
       "${wallet_deregister_koios_api}" != *[[:space:]]* &&
       "${wallet_deregister_koios_api}" != *@* &&
       "${wallet_deregister_koios_api}" != *'?'* &&
       "${wallet_deregister_koios_api}" != *'#'* &&
       "${wallet_deregister_koios_api}" != *\\* ]] || action_status=70
    if header_declaration="$(
        builtin declare -p KOIOS_API_HEADERS 2>/dev/null
      )"; then
      [[ "${header_declaration}" == 'declare -a '* ]] || action_status=70
      wallet_deregister_koios_headers=("${KOIOS_API_HEADERS[@]}")
    else
      wallet_deregister_koios_headers=()
    fi
    (( ${#wallet_deregister_koios_headers[@]} % 2 == 0 &&
       ${#wallet_deregister_koios_headers[@]} <= 8 )) || action_status=70
    for ((header_index=0; header_index<${#wallet_deregister_koios_headers[@]};
        header_index+=2)); do
      header_value="${wallet_deregister_koios_headers[header_index+1]}"
      [[ ( "${wallet_deregister_koios_headers[header_index]}" == -H ||
           "${wallet_deregister_koios_headers[header_index]}" == --header ) &&
         "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
         "${header_value}" == *:* &&
         ! "${header_value}" =~ [[:cntrl:]] ]] || action_status=70
    done
    if ambient_declaration="$(builtin declare -p HEADERS 2>/dev/null)"; then
      [[ ! "${ambient_declaration}" =~ ^declare\ -[^\ ]*[rx] ]] ||
        action_status=70
    fi
    if (( action_status == 0 )); then
      # Shadow the inherited header variables with non-exported empty locals.
      # The only credential-bearing copy is rendered into curl.config below.
      local -a KOIOS_API_HEADERS=()
      builtin declare +x KOIOS_API_HEADERS
      local HEADERS=""
      builtin declare +x HEADERS
    fi
  elif [[ -n "${KOIOS_API:-}" ]]; then
    action_status=70
  fi
  if [[ "${action_status}" == 64 ]]; then
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 64
  elif [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi

  builtin umask 077
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> WALLET >> DE-REGISTER'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  if selectOpMode; then selection_status=0; else selection_status=$?; fi
  if [[ "${selection_status}" != 0 ]]; then
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 0
  fi
  [[ "${op_mode:-}" == online || "${op_mode:-}" == hybrid ]] || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  println DEBUG 'Select wallet to de-register (only registered wallets shown)'
  if selectWallet reg; then selection_status=0; else selection_status=$?; fi
  case "${selection_status}" in
    0) ;;
    1)
      println ERROR 'No registered wallets are available.'
      waitToProceed
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 0
      ;;
    2)
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 0
      ;;
    *)
      _cntools_action_wallet_deregister_validation_failure
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 70
      ;;
  esac
  wallet_deregister_wallet_name="${wallet_name:-}"
  _cntools_action_wallet_deregister_component_valid \
    "${wallet_deregister_wallet_name}" || {
      _cntools_action_wallet_deregister_validation_failure
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 70
  }
  wallet_deregister_wallet="${wallet_deregister_root}/${wallet_deregister_wallet_name}"
  wallet_deregister_wallet_real="$(
    builtin cd -P -- "${wallet_deregister_wallet}" && builtin pwd -P
  )" || action_status=70
  [[ -d "${wallet_deregister_wallet}" && ! -L "${wallet_deregister_wallet}" &&
     "${wallet_deregister_wallet_real}" == "${wallet_deregister_wallet}" ]] ||
    action_status=70
  _cntools_action_wallet_deregister_directory_identity "${wallet_deregister_wallet}" \
    '700,750,755' wallet_deregister_wallet_identity || action_status=70
  _cntools_action_wallet_deregister_find_capture wallet_deregister_found \
    "${wallet_deregister_root}" -mindepth 1 -maxdepth 1 -type d \
    -name "${wallet_deregister_wallet_name}" -print || action_status=70
  found="${wallet_deregister_found}"
  [[ "${found}" == "${wallet_deregister_wallet}" ]] || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  if getWalletType "${wallet_deregister_wallet_name}"; then
    wallet_type_status=0
  else
    wallet_type_status=$?
  fi
  case "${wallet_type_status}" in
    0|1|5) wallet_deregister_wallet_type="${wallet_type_status}" ;;
    2)
      println ERROR 'ERROR: signing keys encrypted, please decrypt before use!'
      waitToProceed
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 0
      ;;
    3|4)
      println ERROR 'ERROR: required payment or stake wallet keys are missing!'
      waitToProceed
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 0
      ;;
    *)
      _cntools_action_wallet_deregister_validation_failure
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 70
      ;;
  esac
  expected_payment_sk_file="${wallet_deregister_wallet}/${WALLET_PAY_SK_FILENAME}"
  expected_stake_sk_file="${wallet_deregister_wallet}/${WALLET_STAKE_SK_FILENAME}"
  if [[ "${wallet_deregister_wallet_type}" == 0 ]]; then
    _cntools_action_wallet_deregister_leaf_valid \
      "${WALLET_HW_PAY_SK_FILENAME:-}" || action_status=70
    _cntools_action_wallet_deregister_leaf_valid \
      "${WALLET_HW_STAKE_SK_FILENAME:-}" || action_status=70
    expected_payment_sk_file="${wallet_deregister_wallet}/${WALLET_HW_PAY_SK_FILENAME:-}"
    expected_stake_sk_file="${wallet_deregister_wallet}/${WALLET_HW_STAKE_SK_FILENAME:-}"
  fi
  [[ "${payment_vk_file:-}" == "${wallet_deregister_wallet}/${WALLET_PAY_VK_FILENAME}" &&
     "${payment_sk_file:-}" == "${expected_payment_sk_file}" &&
     "${stake_vk_file:-}" == "${wallet_deregister_wallet}/${WALLET_STAKE_VK_FILENAME}" &&
     "${stake_sk_file:-}" == "${expected_stake_sk_file}" &&
     "${payment_script_file:-}" == "${wallet_deregister_wallet}/${WALLET_PAY_SCRIPT_FILENAME}" &&
     "${stake_script_file:-}" == "${wallet_deregister_wallet}/${WALLET_STAKE_SCRIPT_FILENAME}" ]] ||
    action_status=70
  if [[ "${wallet_deregister_wallet_type}" == 0 && "${op_mode}" == online ]]; then
    _cntools_action_wallet_deregister_ccli_resolve \
      "${HWCLI:-cardano-hw-cli}" wallet_deregister_hwcli_path || action_status=70
    if [[ "${action_status}" == 0 ]]; then
      _cntools_action_wallet_deregister_executable_capture \
        "${wallet_deregister_hwcli_path}" hwcli || action_status=70
    fi
    builtin declare -F unlockHWDevice >/dev/null 2>&1 || action_status=70
  fi
  for leaf in base payment reward; do
    case "${leaf}" in
      base) filename="${WALLET_BASE_ADDR_FILENAME}" ;;
      payment) filename="${WALLET_PAY_ADDR_FILENAME}" ;;
      reward) filename="${WALLET_STAKE_ADDR_FILENAME}" ;;
    esac
    _cntools_action_wallet_deregister_capture_input \
      "${wallet_deregister_wallet}/${filename}" "${leaf}_address" 512 ||
      action_status=70
    (( action_status == 0 )) || break
  done
  if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
    op_mode=hybrid
    _cntools_action_wallet_deregister_capture_input \
      "${payment_script_file}" payment_script 65536 || action_status=70
    _cntools_action_wallet_deregister_capture_input \
      "${stake_script_file}" stake_script 65536 || action_status=70
  else
    _cntools_action_wallet_deregister_capture_input \
      "${payment_vk_file}" payment_vk 65536 || action_status=70
    _cntools_action_wallet_deregister_capture_input \
      "${stake_vk_file}" stake_vk 65536 || action_status=70
    if [[ "${op_mode}" == online ]]; then
      _cntools_action_wallet_deregister_capture_input \
        "${payment_sk_file}" payment_sk 65536 600 || action_status=70
      _cntools_action_wallet_deregister_capture_input \
        "${stake_sk_file}" stake_sk 65536 600 || action_status=70
    fi
  fi
  _cntools_action_wallet_deregister_input_read base_address base_addr || action_status=70
  _cntools_action_wallet_deregister_input_read payment_address pay_addr || action_status=70
  _cntools_action_wallet_deregister_input_read reward_address reward_addr || action_status=70
  _cntools_action_wallet_deregister_address_valid base "${base_addr}" || action_status=70
  _cntools_action_wallet_deregister_address_valid payment "${pay_addr}" || action_status=70
  _cntools_action_wallet_deregister_address_valid reward "${reward_addr}" || action_status=70
  if [[ "${wallet_deregister_network_args[0]}" == --mainnet ]]; then
    [[ "${base_addr}" == addr1* && "${pay_addr}" == addr1* &&
       "${reward_addr}" == stake1* ]] || action_status=70
  else
    [[ "${base_addr}" == addr_test1* && "${pay_addr}" == addr_test1* &&
       "${reward_addr}" == stake_test1* ]] || action_status=70
  fi
  wallet_deregister_certificate_destination="${wallet_deregister_wallet}/${WALLET_STAKE_DEREG_FILENAME}"
  if [[ -e "${wallet_deregister_certificate_destination}" ||
        -L "${wallet_deregister_certificate_destination}" ]]; then
    if [[ -f "${wallet_deregister_certificate_destination}" &&
          ! -L "${wallet_deregister_certificate_destination}" ]] &&
       _cntools_action_wallet_deregister_path_metadata \
         "${wallet_deregister_certificate_destination}" '600,640,644' \
         1 1048576 1 wallet_deregister_metadata; then
      println ERROR 'A stake de-registration certificate already exists for this wallet.'
      waitToProceed
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 0
    fi
    action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }

  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_root}" \
    "${wallet_deregister_root_identity}" '700,750,755' || action_status=70
  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_wallet}" \
    "${wallet_deregister_wallet_identity}" '700,750,755' || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  }
  wallet_deregister_lock="${wallet_deregister_root}/.${wallet_deregister_wallet_name}.cntools-wallet-deregister.lock"
  if [[ -e "${wallet_deregister_lock}" || -L "${wallet_deregister_lock}" ]]; then
    if _cntools_action_wallet_deregister_directory_identity \
        "${wallet_deregister_lock}" 700 wallet_deregister_check_identity; then
      println ERROR 'Wallet de-registration is already in progress; please retry later.'
      waitToProceed
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return 0
    fi
    _cntools_action_wallet_deregister_validation_failure
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi
  # Install the deferred handler before the first filesystem mutation.  From
  # this point onward every signal is reconciled against owned lock/stage state.
  trap '_cntools_action_wallet_deregister_signal' HUP INT TERM
  _cntools_action_wallet_deregister_tools_same stat hash mkdir || action_status=70
  if (( action_status == 0 )); then
    "${wallet_deregister_mkdir_path}" -m 0700 -- "${wallet_deregister_lock}" \
      >/dev/null 2>&1 || mkdir_status=$?
  fi
  _cntools_action_wallet_deregister_tools_same mkdir hash stat || action_status=70
  if ! _cntools_action_wallet_deregister_directory_identity \
      "${wallet_deregister_lock}" 700 wallet_deregister_lock_identity; then
    # Without an authenticated exact lock inode there is no authority to
    # mutate whatever now occupies the pathname.
    _cntools_action_wallet_deregister_validation_failure
    trap - HUP INT TERM
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi
  _cntools_action_wallet_deregister_find_capture wallet_deregister_found \
    "${wallet_deregister_lock}" -mindepth 1 -maxdepth 1 -print ||
    action_status=70
  found="${wallet_deregister_found}"
  [[ -z "${found}" ]] || action_status=70
  _cntools_action_wallet_deregister_directory_same "${wallet_deregister_lock}" \
    "${wallet_deregister_lock_identity}" 700 || action_status=70
  target="${wallet_deregister_lock}/stage"
  [[ ! -e "${target}" && ! -L "${target}" ]] || action_status=70
  mkdir_status=0
  if (( action_status == 0 )); then
    _cntools_action_wallet_deregister_tools_same stat hash mkdir || action_status=70
  fi
  if (( action_status == 0 )); then
    "${wallet_deregister_mkdir_path}" -m 0700 -- "${target}" \
      >/dev/null 2>&1 || mkdir_status=$?
  fi
  _cntools_action_wallet_deregister_tools_same mkdir hash stat || action_status=70
  if [[ -d "${target}" && ! -L "${target}" ]] &&
     _cntools_action_wallet_deregister_directory_identity "${target}" 700 \
       wallet_deregister_stage_identity; then
    wallet_deregister_stage="${target}"
    _cntools_action_wallet_deregister_find_capture wallet_deregister_found \
      "${target}" -mindepth 1 -maxdepth 1 -print || action_status=70
    found="${wallet_deregister_found}"
    [[ -z "${found}" ]] || action_status=70
    _cntools_action_wallet_deregister_directory_same "${target}" \
      "${wallet_deregister_stage_identity}" 700 || action_status=70
  else
    action_status=70
  fi
  for leaf in utxo.json stake.json certificate.json fee.out min-utxo.out submit.out \
      tx.draft tx.raw tx.hardware witness.payment witness.stake tx.signed offline.json \
      curl.config utxo.payload stake.payload submit.payload verify.payload txid.out \
      verify.1.json verify.2.json verify.3.json; do
    (( action_status == 0 )) || break
    _cntools_action_wallet_deregister_stage_leaf_create "${leaf}" || action_status=70
  done
  (( action_status != 0 )) ||
    _cntools_action_wallet_deregister_stage_inventory_valid || action_status=70
  if [[ "${context_mode}" == light && "${action_status}" == 0 ]]; then
    _cntools_action_wallet_deregister_build_curl_config || action_status=70
    wallet_deregister_koios_headers=()
  fi
  (( action_status != 0 )) ||
    _cntools_action_wallet_deregister_stage_inventory_valid || action_status=70
  [[ "${wallet_deregister_signal_pending}" == N ]] || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  if [[ "${context_mode}" == local ]]; then
    _cntools_action_wallet_deregister_local_query || query_status=$?
  else
    _cntools_action_wallet_deregister_light_query || query_status=$?
  fi
  case "${query_status}" in
    0) ;;
    1)
      _cntools_action_wallet_deregister_finish_no_commit \
        'Wallet de-registration query failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
      ;;
    *)
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
      ;;
  esac
  if [[ "${wallet_deregister_registered}" != Y ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'The selected wallet is not registered on chain.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  if [[ "${wallet_deregister_reward_lovelace}" != 0 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'Withdraw all stake rewards before de-registering this wallet.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  if [[ "${wallet_deregister_base_lovelace}" == 0 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'No funds are available in the wallet base address for the de-registration fee.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi

  if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
    builtin declare -F validateMultiSigScript >/dev/null 2>&1 || action_status=70
    _cntools_action_wallet_deregister_input_read payment_script \
      wallet_deregister_script_payment || action_status=70
    _cntools_action_wallet_deregister_input_read stake_script \
      wallet_deregister_script_stake || action_status=70
    if (( action_status == 0 )); then
      required_total=
      validateMultiSigScript false "${wallet_deregister_script_payment}" ||
        action_status=70
      [[ "${required_total:-}" =~ ^[1-9][0-9]{0,3}$ ]] || action_status=70
      witness_count="${required_total:-0}"
      required_total=
      validateMultiSigScript false "${wallet_deregister_script_stake}" ||
        action_status=70
      [[ "${required_total:-}" =~ ^[1-9][0-9]{0,3}$ ]] || action_status=70
      witness_count=$((witness_count + ${required_total:-0}))
    fi
  fi
  if getTTL "$([[ "${wallet_deregister_wallet_type}" == 5 ]] && builtin printf true)"; then
    wallet_deregister_ttl="${ttl:-}"
  else
    phase_status=1
  fi
  [[ "${wallet_deregister_ttl}" =~ ^[1-9][0-9]{0,15}$ ]] ||
    [[ "${phase_status}" == 1 ]] || action_status=70
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'Wallet de-registration validity selection was canceled or failed.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  phase_status=0
  if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
    _cntools_action_wallet_deregister_input_open stake_script \
      wallet_deregister_stake_fd || action_status=70
    stake_fd="${wallet_deregister_stake_fd:-}"
    command_arguments=("${wallet_deregister_ccli_path}" latest stake-address
      deregistration-certificate --stake-script-file "/dev/fd/${stake_fd}")
  else
    _cntools_action_wallet_deregister_input_open stake_vk \
      wallet_deregister_stake_fd || action_status=70
    stake_fd="${wallet_deregister_stake_fd:-}"
    command_arguments=("${wallet_deregister_ccli_path}" latest stake-address
      deregistration-certificate --stake-verification-key-file "/dev/fd/${stake_fd}")
  fi
  if versionCheck 9.0 "${PROT_VERSION}"; then
    command_arguments+=(--key-reg-deposit-amt "${wallet_deregister_stake_deposit}")
  fi
  if (( action_status == 0 )); then
    _cntools_action_wallet_deregister_run_output certificate.json --out-file \
      'cardano-cli wallet-deregister certificate' "${command_arguments[@]}" ||
      phase_status=$?
  fi
  if [[ -n "${stake_fd}" ]]; then
    if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
      _cntools_action_wallet_deregister_input_close_verified \
        stake_script "${stake_fd}" || phase_status=70
    else
      _cntools_action_wallet_deregister_input_close_verified \
        stake_vk "${stake_fd}" || phase_status=70
    fi
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'Stake de-registration certificate creation failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
       ! _cntools_action_wallet_deregister_certificate_schema; then
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_deregister_stage_capture certificate.json 1 1048576 ||
    action_status=70

  wallet_deregister_assets_suffix=""
  _cntools_action_wallet_deregister_sort_capture wallet_deregister_sorted_assets \
    "${!wallet_deregister_assets[@]}" || action_status=70
  while IFS= builtin read -r asset; do
    [[ -n "${asset}" ]] || continue
    quantity="${wallet_deregister_assets[${asset}]}"
    wallet_deregister_assets_suffix+="+${quantity} ${asset}"
  done <<< "${wallet_deregister_sorted_assets}"
  _cntools_action_wallet_deregister_uint_add "${wallet_deregister_base_lovelace}" \
    "${wallet_deregister_stake_deposit}" wallet_deregister_available_lovelace ||
    action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  (( wallet_deregister_available_lovelace >= DUMMYFEE )) || {
    _cntools_action_wallet_deregister_finish_no_commit \
      'Not enough ADA is available for the de-registration draft fee.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  wallet_deregister_dummy_balance=$((wallet_deregister_available_lovelace - DUMMYFEE))
  build_arguments=(latest transaction build-raw)
  for tx_ref in "${wallet_deregister_tx_inputs[@]}"; do
    build_arguments+=(--tx-in "${tx_ref}")
  done
  certificate_fd=""; payment_script_fd=""; stake_script_fd=""
  _cntools_action_wallet_deregister_stage_open certificate.json 1 1048576 \
    wallet_deregister_certificate_fd || action_status=70
  certificate_fd="${wallet_deregister_certificate_fd:-}"
  if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
    _cntools_action_wallet_deregister_input_open payment_script \
      wallet_deregister_payment_script_fd || action_status=70
    payment_script_fd="${wallet_deregister_payment_script_fd:-}"
    _cntools_action_wallet_deregister_input_open stake_script \
      wallet_deregister_stake_script_fd || action_status=70
    stake_script_fd="${wallet_deregister_stake_script_fd:-}"
    build_arguments+=(--tx-in-script-file "/dev/fd/${payment_script_fd}"
      --certificate-script-file "/dev/fd/${stake_script_fd}")
  fi
  build_arguments+=(--tx-out "${base_addr}+${wallet_deregister_dummy_balance}${wallet_deregister_assets_suffix}"
    --invalid-hereafter "${wallet_deregister_ttl}" --fee "${DUMMYFEE}"
    --certificate-file "/dev/fd/${certificate_fd}")
  phase_status=0
  if (( action_status == 0 )); then
    _cntools_action_wallet_deregister_run_output tx.draft --out-file \
      'cardano-cli wallet-deregister draft transaction' \
      "${wallet_deregister_ccli_path}" "${build_arguments[@]}" || phase_status=$?
  fi
  if [[ -n "${certificate_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      certificate.json "${certificate_fd}" 1 1048576 || phase_status=70
  fi
  if [[ -n "${payment_script_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      payment_script "${payment_script_fd}" || phase_status=70
  fi
  if [[ -n "${stake_script_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      stake_script "${stake_script_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'De-registration transaction drafting failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
       ! _cntools_action_wallet_deregister_tx_schema tx.draft body; then
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_deregister_stage_capture tx.draft 1 1048576 ||
    action_status=70

  target="${wallet_deregister_tmp_root}/protparams.json"
  _cntools_action_wallet_deregister_capture_input "${target}" protocol 1048576 ||
    action_status=70
  _cntools_action_wallet_deregister_input_open protocol wallet_deregister_protocol_fd ||
    action_status=70
  protocol_fd="${wallet_deregister_protocol_fd:-}"
  _cntools_action_wallet_deregister_stage_open tx.draft 1 1048576 \
    wallet_deregister_draft_fd || action_status=70
  draft_fd="${wallet_deregister_draft_fd:-}"
  if (( action_status == 0 )); then
    command_arguments=("${wallet_deregister_ccli_path}" latest transaction
      calculate-min-fee --tx-body-file "/dev/fd/${draft_fd}"
      --tx-in-count "${#wallet_deregister_tx_inputs[@]}" --tx-out-count 1
      --witness-count "${witness_count}" --byron-witness-count 0
      --protocol-params-file "/dev/fd/${protocol_fd}")
    _cntools_action_wallet_deregister_run_output fee.out stdout \
      'cardano-cli wallet-deregister minimum fee' "${command_arguments[@]}" ||
      phase_status=$?
  fi
  if [[ -n "${draft_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      tx.draft "${draft_fd}" 1 1048576 || phase_status=70
  fi
  if [[ -n "${protocol_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      protocol "${protocol_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'De-registration fee calculation failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_deregister_stage_read fee.out \
    wallet_deregister_output_value 256 ||
    action_status=70
  if [[ "${wallet_deregister_output_value}" =~ ^([0-9]+)([[:space:]]+[Ll]ovelace)?$ ]]; then
    wallet_deregister_min_fee="${BASH_REMATCH[1]}"
  else
    action_status=70
  fi
  _cntools_action_wallet_deregister_uint_valid "${wallet_deregister_min_fee}" ||
    action_status=70
  (( wallet_deregister_available_lovelace >= wallet_deregister_min_fee )) || {
    _cntools_action_wallet_deregister_finish_no_commit \
      'Not enough ADA is available for the de-registration fee.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  wallet_deregister_dummy_balance=$((wallet_deregister_available_lovelace -
    wallet_deregister_min_fee))
  tx_out="${base_addr}+${wallet_deregister_dummy_balance}${wallet_deregister_assets_suffix}"
  protocol_fd=""
  _cntools_action_wallet_deregister_input_open protocol \
    wallet_deregister_protocol_fd || action_status=70
  protocol_fd="${wallet_deregister_protocol_fd:-}"
  command_arguments=("${wallet_deregister_ccli_path}" latest transaction
    calculate-min-required-utxo --protocol-params-file
    "/dev/fd/${protocol_fd}" --tx-out "${tx_out}")
  phase_status=0
  if (( action_status == 0 )); then
    _cntools_action_wallet_deregister_run_output min-utxo.out stdout \
      'cardano-cli wallet-deregister minimum UTxO' "${command_arguments[@]}" ||
      phase_status=$?
  fi
  if [[ -n "${protocol_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      protocol "${protocol_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'Minimum UTxO calculation failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_deregister_stage_read min-utxo.out \
    wallet_deregister_output_value 256 ||
    action_status=70
  if [[ "${wallet_deregister_output_value}" =~ ^([0-9]+)([[:space:]]+[Ll]ovelace)?$ ]]; then
    wallet_deregister_min_utxo="${BASH_REMATCH[1]}"
  else
    action_status=70
  fi
  _cntools_action_wallet_deregister_uint_valid "${wallet_deregister_min_utxo}" ||
    action_status=70
  (( wallet_deregister_dummy_balance >= wallet_deregister_min_utxo )) || {
    _cntools_action_wallet_deregister_finish_no_commit \
      'The de-registration output would be below the minimum UTxO value.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  build_arguments=(latest transaction build-raw)
  for tx_ref in "${wallet_deregister_tx_inputs[@]}"; do
    build_arguments+=(--tx-in "${tx_ref}")
  done
  certificate_fd=""; payment_script_fd=""; stake_script_fd=""
  _cntools_action_wallet_deregister_stage_open certificate.json 1 1048576 \
    wallet_deregister_certificate_fd || action_status=70
  certificate_fd="${wallet_deregister_certificate_fd:-}"
  if [[ "${wallet_deregister_wallet_type}" == 5 ]]; then
    _cntools_action_wallet_deregister_input_open payment_script \
      wallet_deregister_payment_script_fd || action_status=70
    payment_script_fd="${wallet_deregister_payment_script_fd:-}"
    _cntools_action_wallet_deregister_input_open stake_script \
      wallet_deregister_stake_script_fd || action_status=70
    stake_script_fd="${wallet_deregister_stake_script_fd:-}"
    build_arguments+=(--tx-in-script-file "/dev/fd/${payment_script_fd}"
      --certificate-script-file "/dev/fd/${stake_script_fd}")
  fi
  build_arguments+=(--tx-out "${tx_out}" --invalid-hereafter
    "${wallet_deregister_ttl}" --fee "${wallet_deregister_min_fee}"
    --certificate-file "/dev/fd/${certificate_fd}"
    --out-canonical-cbor)
  phase_status=0
  if (( action_status == 0 )); then
    _cntools_action_wallet_deregister_run_output tx.raw --out-file \
      'cardano-cli wallet-deregister final transaction' \
      "${wallet_deregister_ccli_path}" "${build_arguments[@]}" || phase_status=$?
  fi
  if [[ -n "${certificate_fd}" ]]; then
    _cntools_action_wallet_deregister_stage_close_verified \
      certificate.json "${certificate_fd}" 1 1048576 || phase_status=70
  fi
  if [[ -n "${payment_script_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      payment_script "${payment_script_fd}" || phase_status=70
  fi
  if [[ -n "${stake_script_fd}" ]]; then
    _cntools_action_wallet_deregister_input_close_verified \
      stake_script "${stake_script_fd}" || phase_status=70
  fi
  if [[ "${phase_status}" == 1 ]]; then
    _cntools_action_wallet_deregister_finish_no_commit \
      'Final de-registration transaction construction failed; diagnostic output was suppressed.' Y
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
       ! _cntools_action_wallet_deregister_tx_schema tx.raw body; then
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  fi
  _cntools_action_wallet_deregister_stage_capture tx.raw 1 1048576 ||
    action_status=70

  for leaf in "${!wallet_deregister_input_paths[@]}"; do
    _cntools_action_wallet_deregister_input_open "${leaf}" wallet_deregister_check_fd ||
      action_status=70
    [[ -z "${wallet_deregister_check_fd:-}" ]] ||
      exec {wallet_deregister_check_fd}>&-
    (( action_status == 0 )) || break
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_deregister_finish_invariant
    action_status=$?
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return "${action_status}"
  }

  if [[ "${op_mode}" == hybrid ]]; then
    _cntools_action_wallet_deregister_build_offline || phase_status=$?
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_deregister_finish_no_commit \
        'The offline de-registration package destination already exists.' Y
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 ]]; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_deregister_stage_inventory_valid || {
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    }
    _cntools_action_wallet_deregister_publish_leaf certificate.json \
      "${wallet_deregister_certificate_destination}" \
      "${wallet_deregister_wallet_identity}" '700,750,755' || phase_status=$?
    [[ "${phase_status}" == 0 ]] &&
      _cntools_action_wallet_deregister_publish_leaf offline.json \
        "${wallet_deregister_offline_destination}" \
        "${wallet_deregister_tmp_identity}" '700,750,755' || phase_status=$?
    if [[ "${phase_status}" != 0 ]]; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    [[ "${wallet_deregister_signal_pending}" == N ]] || {
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    }
    wallet_deregister_committed=Y wallet_deregister_commit_window=N
  else
    phase_status=0
    wallet_deregister_body_leaf=tx.raw
    if [[ "${wallet_deregister_wallet_type}" == 0 ]]; then
      wallet_deregister_raw_fd=""
      _cntools_action_wallet_deregister_stage_open tx.raw 1 1048576 \
        wallet_deregister_raw_fd || action_status=70
      raw_fd="${wallet_deregister_raw_fd:-}"
      if (( action_status == 0 )); then
        command_arguments=("${wallet_deregister_hwcli_path}" transaction transform
          --tx-file "/dev/fd/${raw_fd}")
        _cntools_action_wallet_deregister_run_output tx.hardware --out-file \
          'cardano-hw-cli wallet-deregister transaction transform' \
          "${command_arguments[@]}" || phase_status=$?
      fi
      if [[ -n "${raw_fd}" ]]; then
        _cntools_action_wallet_deregister_stage_close_verified \
          tx.raw "${raw_fd}" 1 1048576 || phase_status=70
        raw_fd=""
      fi
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        _cntools_action_wallet_deregister_tx_schema tx.hardware body ||
          phase_status=70
      fi
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        _cntools_action_wallet_deregister_stage_capture tx.hardware 1 1048576 ||
          phase_status=70
      fi
      wallet_deregister_body_leaf=tx.hardware
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        if unlockHWDevice 'witness the wallet de-registration transaction'; then
          _cntools_action_wallet_deregister_run_hardware_witness || phase_status=$?
        else
          phase_status=1
        fi
      fi
    else
      _cntools_action_wallet_deregister_input_open payment_sk wallet_deregister_payment_fd ||
        action_status=70
      payment_fd="${wallet_deregister_payment_fd:-}"
      stake_fd=""
      _cntools_action_wallet_deregister_stage_open tx.raw 1 1048576 \
        wallet_deregister_raw_fd || action_status=70
      raw_fd="${wallet_deregister_raw_fd:-}"
      if (( action_status == 0 )); then
        command_arguments=("${wallet_deregister_ccli_path}" latest transaction witness
          --tx-body-file "/dev/fd/${raw_fd}" --signing-key-file
          "/dev/fd/${payment_fd}" "${wallet_deregister_network_args[@]}")
        _cntools_action_wallet_deregister_run_output witness.payment --out-file \
          'cardano-cli wallet-deregister payment witness' \
          "${command_arguments[@]}" || phase_status=$?
      fi
      if [[ -n "${payment_fd}" ]]; then
        _cntools_action_wallet_deregister_input_close_verified \
          payment_sk "${payment_fd}" || phase_status=70
        payment_fd=""
      fi
      _cntools_action_wallet_deregister_stage_verify tx.raw 1 1048576 ||
        phase_status=70
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        wallet_deregister_stake_fd=""
        _cntools_action_wallet_deregister_input_open stake_sk \
          wallet_deregister_stake_fd || action_status=70
        stake_fd="${wallet_deregister_stake_fd:-}"
      fi
      if [[ "${phase_status}" == 0 && "${action_status}" == 0 ]]; then
        command_arguments=("${wallet_deregister_ccli_path}" latest transaction witness
          --tx-body-file "/dev/fd/${raw_fd}" --signing-key-file
          "/dev/fd/${stake_fd}" "${wallet_deregister_network_args[@]}")
        _cntools_action_wallet_deregister_run_output witness.stake --out-file \
          'cardano-cli wallet-deregister stake witness' \
          "${command_arguments[@]}" || phase_status=$?
      fi
      if [[ -n "${stake_fd}" ]]; then
        _cntools_action_wallet_deregister_input_close_verified \
          stake_sk "${stake_fd}" || phase_status=70
        stake_fd=""
      fi
      if [[ -n "${raw_fd}" ]]; then
        _cntools_action_wallet_deregister_stage_close_verified \
          tx.raw "${raw_fd}" 1 1048576 || phase_status=70
        raw_fd=""
      fi
    fi
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_deregister_finish_no_commit \
        'De-registration transaction signing failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
         ! _cntools_action_wallet_deregister_tx_schema witness.payment witness ||
         ! _cntools_action_wallet_deregister_tx_schema witness.stake witness; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_deregister_stage_capture witness.payment 1 1048576 ||
      action_status=70
    _cntools_action_wallet_deregister_stage_capture witness.stake 1 1048576 ||
      action_status=70
    _cntools_action_wallet_deregister_stage_open "${wallet_deregister_body_leaf}" 1 1048576 \
      wallet_deregister_raw_fd || action_status=70
    raw_fd="${wallet_deregister_raw_fd:-}"
    _cntools_action_wallet_deregister_stage_open witness.payment 1 1048576 \
      wallet_deregister_witness_payment_fd || action_status=70
    witness_payment_fd="${wallet_deregister_witness_payment_fd:-}"
    _cntools_action_wallet_deregister_stage_open witness.stake 1 1048576 \
      wallet_deregister_witness_stake_fd || action_status=70
    witness_stake_fd="${wallet_deregister_witness_stake_fd:-}"
    if (( action_status == 0 )); then
      command_arguments=("${wallet_deregister_ccli_path}" latest transaction assemble
        --tx-body-file "/dev/fd/${raw_fd}"
        --witness-file "/dev/fd/${witness_payment_fd}"
        --witness-file "/dev/fd/${witness_stake_fd}" --out-canonical-cbor)
      _cntools_action_wallet_deregister_run_output tx.signed --out-file \
        'cardano-cli wallet-deregister transaction assembly' \
        "${command_arguments[@]}" || phase_status=$?
    fi
    if [[ -n "${raw_fd}" ]]; then
      _cntools_action_wallet_deregister_stage_close_verified \
        "${wallet_deregister_body_leaf}" "${raw_fd}" 1 1048576 || phase_status=70
    fi
    if [[ -n "${witness_payment_fd}" ]]; then
      _cntools_action_wallet_deregister_stage_close_verified \
        witness.payment "${witness_payment_fd}" 1 1048576 || phase_status=70
    fi
    if [[ -n "${witness_stake_fd}" ]]; then
      _cntools_action_wallet_deregister_stage_close_verified \
        witness.stake "${witness_stake_fd}" 1 1048576 || phase_status=70
    fi
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_deregister_finish_no_commit \
        'De-registration transaction assembly failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]] ||
         ! _cntools_action_wallet_deregister_tx_schema tx.signed signed; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_deregister_stage_capture tx.signed 1 1048576 ||
      action_status=70
    phase_status=0
    if (( action_status == 0 )); then
      _cntools_action_wallet_deregister_derive_txid || phase_status=$?
    fi
    if [[ "${phase_status}" == 1 ]]; then
      _cntools_action_wallet_deregister_finish_no_commit \
        'Transaction identifier derivation failed; diagnostic output was suppressed.' Y
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    if [[ "${context_mode}" == light ]]; then
      _cntools_action_wallet_deregister_build_submit_payload || action_status=70
      _cntools_action_wallet_deregister_stage_generate_json verify.payload \
        '{_tx_hashes:[$tx]}' --arg tx "${wallet_deregister_tx_id}" ||
        action_status=70
    fi
    if [[ "${action_status}" != 0 ]]; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    _cntools_action_wallet_deregister_stage_inventory_valid || {
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    }
    _cntools_action_wallet_deregister_publish_leaf certificate.json \
      "${wallet_deregister_certificate_destination}" \
      "${wallet_deregister_wallet_identity}" '700,750,755' || phase_status=$?
    if [[ "${phase_status}" != 0 ]]; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    signed_fd=""
    if [[ "${context_mode}" == local ]]; then
      _cntools_action_wallet_deregister_stage_open tx.signed 1 1048576 \
        wallet_deregister_signed_fd || action_status=70
      signed_fd="${wallet_deregister_signed_fd:-}"
    else
      _cntools_action_wallet_deregister_stage_verify tx.signed 1 1048576 ||
        action_status=70
    fi
    _cntools_action_wallet_deregister_stage_inventory_valid || action_status=70
    [[ "${wallet_deregister_signal_pending}" == N ]] || action_status=70
    if (( action_status == 0 )); then
      # Enter the deferred-signal commit window before the last pending-state
      # check. A signal observed by that check prevents submission; one
      # delivered during the call makes its outcome ambiguous and retains the
      # authenticated recovery authority.
      wallet_deregister_commit_window=Y
      if [[ "${wallet_deregister_signal_pending}" == N ]]; then
        if [[ "${context_mode}" == local ]]; then
          command_arguments=("${wallet_deregister_ccli_path}" latest transaction submit
            --tx-file "/dev/fd/${signed_fd}" "${wallet_deregister_network_args[@]}")
          _cntools_action_wallet_deregister_run_output submit.out stdout-submit \
            'cardano-cli wallet-deregister transaction submission' \
            "${command_arguments[@]}" || phase_status=$?
        else
          _cntools_action_wallet_deregister_light_submit_once || phase_status=$?
        fi
      else
        wallet_deregister_commit_window=N
        action_status=70
      fi
    fi
    if [[ -n "${signed_fd}" ]]; then
      _cntools_action_wallet_deregister_stage_close_verified \
        tx.signed "${signed_fd}" 1 1048576 || phase_status=70
    fi
    if [[ "${wallet_deregister_submit_started}" == Y &&
          "${wallet_deregister_signal_pending}" != N ]]; then
      phase_status=70
    fi
    if [[ "${wallet_deregister_submit_started}" == Y &&
          "${phase_status}" == 0 ]]; then
      # The paired assignment is one shell command: after a signal-free,
      # authenticated submit, no deferred handler can observe a half-commit.
      wallet_deregister_committed=Y wallet_deregister_commit_window=N
    else
      wallet_deregister_commit_window=N
    fi
    if [[ "${wallet_deregister_submit_started}" == Y &&
          "${phase_status}" != 0 ]]; then
      wallet_deregister_submission_ambiguous=Y
      _cntools_action_wallet_deregister_finish_submit_ambiguous
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    elif [[ "${phase_status}" != 0 || "${action_status}" != 0 ]]; then
      _cntools_action_wallet_deregister_finish_invariant
      action_status=$?
      [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
      return "${action_status}"
    fi
    if [[ "${wallet_deregister_signal_pending}" == N ]]; then
      if ! _cntools_action_wallet_deregister_confirm; then
        case "${wallet_deregister_confirmation_state}" in
          canceled)
            println ERROR \
              'WARN: confirmation check canceled; the de-registration remains submitted.'
            ;;
          *)
            println ERROR \
              'WARN: de-registration was submitted, but confirmation is still pending.'
            ;;
        esac
      fi
    fi
  fi

  if ! _cntools_action_wallet_deregister_cleanup_stage; then
    _cntools_action_wallet_deregister_validation_failure
    println ERROR \
      'Wallet de-registration committed, but authenticated cleanup is incomplete.'
    waitToProceed
    trap - HUP INT TERM
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi
  if ! _cntools_action_wallet_deregister_published_final_verify; then
    _cntools_action_wallet_deregister_validation_failure
    println ERROR \
      'Wallet de-registration committed, but final artifact verification failed.'
    waitToProceed
    trap - HUP INT TERM
    [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
    return 70
  fi
  if [[ "${op_mode}" == hybrid ]]; then
    println "Offline de-registration package created: ${wallet_deregister_offline_destination}"
  else
    println "${wallet_deregister_wallet_name} successfully de-registered on chain."
    println "Stake deposit returned: ${wallet_deregister_stake_deposit} lovelace"
  fi
  waitToProceed
  # Keep the postcommit handler installed through the final wait, then close
  # the delivery window before consuming the deferred state.  This makes a
  # signal during the wait observable without ever rolling back committed
  # artifacts or changing the committed status.
  trap '' HUP INT TERM
  if [[ "${wallet_deregister_signal_pending}" == Y ]]; then
    println ERROR 'WARN: wallet de-registration committed while an interrupt was pending.'
  fi
  trap - HUP INT TERM
  [[ "${wallet_deregister_trace_was_on}" != Y ]] || builtin set -x
  [[ "${op_mode}" == hybrid ]] && return 0
  return 21
}

cntools_action_main() {
  (( $# == 2 )) || return 64
  _cntools_action_wallet_deregister_prefixed_main "$1" "$2"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  builtin printf '%s\n' \
    'CNTools actions are launched by the dispatcher, not directly.' >&2
  builtin exit 64
fi
