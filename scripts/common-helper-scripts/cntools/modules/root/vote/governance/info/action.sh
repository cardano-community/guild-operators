#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154
# Stage 4 compatibility action for governance information and status.
# Sourcing defines functions only; the dispatcher supplies the authenticated
# context plus inherited legacy display, selection, wallet, and format helpers.

_cntools_action_vote_governance_info_validation_failure() {
  builtin printf '%s\n' \
    'CNTools governance-info action failed validation.' >&2
  return 70
}

_cntools_action_vote_governance_info_cleanup() {
  local cleanup_target="" cleanup_failed=0

  trap - EXIT HUP INT TERM
  for cleanup_target in "${governance_info_temp_files[@]:-}"; do
    [[ -n "${cleanup_target}" ]] || continue
    if [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
      "${governance_info_rm_path}" -f -- "${cleanup_target}" \
        >/dev/null 2>&1 || cleanup_failed=1
    fi
  done
  governance_info_temp_files=()
  return "${cleanup_failed}"
}

_cntools_action_vote_governance_info_file_metadata() {
  local target="${1:-}" allowed_modes="${2:-}" maximum_size="${3:-}"
  local allow_empty="${4:-N}" metadata="" owner="" mode="" links="" size=""

  [[ -f "${target}" && ! -L "${target}" &&
     "${maximum_size}" =~ ^[1-9][0-9]*$ &&
     ( "${allow_empty}" == Y || "${allow_empty}" == N ) ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${size}" =~ ^[0-9]+$ && "${size}" -le "${maximum_size}" &&
     ( "${allow_empty}" == Y || "${size}" -ge 1 ) &&
     ",${allowed_modes}," == *",${mode},"* ]]
}

_cntools_action_vote_governance_info_file_size() {
  local target="${1:-}" size=""

  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  size="$("${governance_info_wc_path}" -c < "${target}" 2>/dev/null)" ||
    return 1
  size="${size//[[:space:]]/}"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${size}"
}

_cntools_action_vote_governance_info_private_file_create() {
  local label="${1:-}" output_variable="${2:-}" created=""

  [[ "${label}" =~ ^(status|power|anchor)$ &&
     "${output_variable}" =~ ^governance_info_(status|power|anchor)_file$ ]] ||
    return 1
  created="$("${governance_info_mktemp_path}" \
    "${governance_info_private_parent}/governance-${label}.XXXXXXXX")" ||
    return 1
  governance_info_temp_files+=("${created}")
  "${governance_info_chmod_path}" 0600 "${created}" || return 1
  _cntools_action_vote_governance_info_file_metadata \
    "${created}" 600 1 Y || return 1
  printf -v "${output_variable}" '%s' "${created}"
}

_cntools_action_vote_governance_info_private_file_release() {
  local output_variable="${1:-}" target=""

  [[ "${output_variable}" =~ ^governance_info_(status|power|anchor)_file$ ]] ||
    return 1
  target="${!output_variable:-}"
  [[ -n "${target}" ]] || return 0
  "${governance_info_rm_path}" -f -- "${target}" >/dev/null 2>&1 ||
    return 1
  printf -v "${output_variable}" '%s' ''
}

_cntools_action_vote_governance_info_safe_component() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. && "${value}" != *\\* ]]
}

_cntools_action_vote_governance_info_wallet_directory() {
  local wallet_name_value="${1:-}" output_variable="${2:-}"
  local candidate="" physical=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _cntools_action_vote_governance_info_safe_component \
    "${wallet_name_value}" || return 1
  candidate="${governance_info_wallet_root}/${wallet_name_value}"
  [[ -d "${candidate}" && ! -L "${candidate}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${candidate}" || return 1
  physical="$(cd -P -- "${candidate}" >/dev/null 2>&1 && pwd -P)" ||
    return 1
  [[ "${physical}" == \
    "${governance_info_wallet_root_physical}/${wallet_name_value}" ]] ||
    return 1
  printf -v "${output_variable}" '%s' "${physical}"
}

_cntools_action_vote_governance_info_input_file_usable() {
  local target="${1:-}"

  _cntools_action_vote_governance_info_file_metadata \
    "${target}" 400,440,444,600,640,644 65536 N
}

_cntools_action_vote_governance_info_cache_value_valid() {
  local kind="${1:-}" value="${2:-}"

  case "${kind}" in
    drep)
      [[ "${value}" =~ ^([0-9A-Fa-f]{56}|drep1[023456789ac-hj-np-z]{1,200})$ ]]
      ;;
    cc-cold)
      [[ "${value}" =~ ^cc_cold1[023456789ac-hj-np-z]{1,200}$ ]]
      ;;
    cc-hot)
      [[ "${value}" =~ ^cc_hot1[023456789ac-hj-np-z]{1,200}$ ]]
      ;;
    reward)
      [[ "${value}" =~ ^stake(_test)?1[023456789A-Za-z]{1,200}$ ]]
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_vote_governance_info_cache_read() {
  local target="${1:-}" kind="${2:-}" output_variable="${3:-}"
  local value=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if [[ "${kind}" == reward ]]; then
    _cntools_action_vote_governance_info_file_metadata \
      "${target}" 400,440,444,600,640,644 512 N || return 1
  else
    _cntools_action_vote_governance_info_file_metadata \
      "${target}" 400,444,600,644 512 N || return 1
  fi
  value="$(< "${target}")"
  _cntools_action_vote_governance_info_cache_value_valid \
    "${kind}" "${value}" || return 1
  printf -v "${output_variable}" '%s' "${value}"
}

_cntools_action_vote_governance_info_cache_publish() {
  local wallet_directory="${1:-}" kind="${2:-}" target="${3:-}"
  local value="${4:-}" output_variable="${5:-}" temporary=""

  [[ "${target%/*}" == "${wallet_directory}" &&
     "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _cntools_action_vote_governance_info_cache_value_valid \
    "${kind}" "${value}" || return 1
  if [[ -e "${target}" || -L "${target}" ]]; then
    _cntools_action_vote_governance_info_cache_read \
      "${target}" "${kind}" "${output_variable}"
    return $?
  fi
  temporary="$("${governance_info_mktemp_path}" \
    "${wallet_directory}/.cntools-governance-info.${kind}.XXXXXXXX")" ||
    return 1
  governance_info_temp_files+=("${temporary}")
  "${governance_info_chmod_path}" 0600 "${temporary}" || return 1
  builtin printf '%s' "${value}" > "${temporary}" || return 1
  _cntools_action_vote_governance_info_file_metadata \
    "${temporary}" 600 512 N || return 1
  if ! "${governance_info_ln_path}" -- "${temporary}" "${target}" \
      >/dev/null 2>&1; then
    _cntools_action_vote_governance_info_cache_read \
      "${target}" "${kind}" "${output_variable}" && return 0
    return 1
  fi
  "${governance_info_rm_path}" -f -- "${temporary}" \
    >/dev/null 2>&1 || return 1
  _cntools_action_vote_governance_info_cache_read \
    "${target}" "${kind}" "${output_variable}"
}

_cntools_action_vote_governance_info_bech32() {
  local prefix="${1:-}" input="${2:-}" output_variable="${3:-}"
  local encoded=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${input}" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  if [[ -n "${prefix}" ]]; then
    encoded="$("${governance_info_bech32_path}" "${prefix}" \
      <<< "${input}" 2>/dev/null)" || return 1
  else
    encoded="$("${governance_info_bech32_path}" \
      <<< "${input}" 2>/dev/null)" || return 1
  fi
  case "${prefix}" in
    '')
      [[ "${encoded}" =~ ^([0-9A-Fa-f]{56}|[0-9A-Fa-f]{58})$ ]] ||
        return 1
      ;;
    drep) [[ "${encoded}" =~ ^drep1[023456789ac-hj-np-z]{1,200}$ ]] || return 1 ;;
    drep_script)
      [[ "${encoded}" =~ ^drep_script1[023456789ac-hj-np-z]{1,200}$ ]] ||
        return 1
      ;;
    cc_cold)
      [[ "${encoded}" =~ ^cc_cold1[023456789ac-hj-np-z]{1,200}$ ]] ||
        return 1
      ;;
    cc_hot)
      [[ "${encoded}" =~ ^cc_hot1[023456789ac-hj-np-z]{1,200}$ ]] ||
        return 1
      ;;
    *) return 1 ;;
  esac
  printf -v "${output_variable}" '%s' "${encoded}"
}

_cntools_action_vote_governance_info_command_output() {
  local output_variable="${1:-}"
  shift || return 1
  local output=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $# -gt 0 ]] ||
    return 1
  output="$("$@" 2>/dev/null)" || return 1
  [[ -n "${output}" && "${#output}" -le 256 &&
     ! "${output}" =~ [[:cntrl:][:space:]] ]] || return 1
  printf -v "${output_variable}" '%s' "${output}"
}

_cntools_action_vote_governance_info_key_info() {
  local wallet_name_value="${1:-}" wallet_directory=""
  local drep_vk_file="" drep_script_file="" drep_id_file=""
  local cc_cold_vk_file="" cc_cold_id_file=""
  local cc_hot_vk_file="" cc_hot_id_file=""
  local generated=""

  drep_id="" drep_id_cip129="" drep_hash="" hash_type=""
  cc_cold_hash="" cc_cold_id="" cc_cold_id_cip129=""
  cc_hot_hash="" cc_hot_id="" cc_hot_id_cip129=""
  _cntools_action_vote_governance_info_wallet_directory \
    "${wallet_name_value}" wallet_directory || return 70
  drep_vk_file="${wallet_directory}/${WALLET_GOV_DREP_VK_FILENAME}"
  drep_script_file="${wallet_directory}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
  drep_id_file="${wallet_directory}/${WALLET_GOV_DREP_ID_FILENAME}"
  cc_cold_vk_file="${wallet_directory}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
  cc_cold_id_file="${wallet_directory}/${WALLET_GOV_CC_COLD_ID_FILENAME}"
  cc_hot_vk_file="${wallet_directory}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
  cc_hot_id_file="${wallet_directory}/${WALLET_GOV_CC_HOT_ID_FILENAME}"

  if [[ -e "${drep_id_file}" || -L "${drep_id_file}" ]]; then
    _cntools_action_vote_governance_info_cache_read \
      "${drep_id_file}" drep drep_id || return 70
  elif [[ -e "${drep_vk_file}" || -L "${drep_vk_file}" ]]; then
    _cntools_action_vote_governance_info_input_file_usable \
      "${drep_vk_file}" || return 70
    _cntools_action_vote_governance_info_command_output generated \
      "${governance_info_ccli_path}" latest governance drep id \
      --drep-verification-key-file "${drep_vk_file}" || return 70
    _cntools_action_vote_governance_info_cache_publish \
      "${wallet_directory}" drep "${drep_id_file}" "${generated}" drep_id ||
      return 70
  elif [[ -e "${drep_script_file}" || -L "${drep_script_file}" ]]; then
    _cntools_action_vote_governance_info_input_file_usable \
      "${drep_script_file}" || return 70
    _cntools_action_vote_governance_info_command_output generated \
      "${governance_info_ccli_path}" hash script \
      --script-file "${drep_script_file}" || return 70
    [[ "${generated}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
    _cntools_action_vote_governance_info_cache_publish \
      "${wallet_directory}" drep "${drep_id_file}" "${generated}" drep_id ||
      return 70
  fi

  if [[ -e "${cc_cold_id_file}" || -L "${cc_cold_id_file}" ]]; then
    _cntools_action_vote_governance_info_cache_read \
      "${cc_cold_id_file}" cc-cold cc_cold_id || return 70
  elif [[ -e "${cc_cold_vk_file}" || -L "${cc_cold_vk_file}" ]]; then
    _cntools_action_vote_governance_info_input_file_usable \
      "${cc_cold_vk_file}" || return 70
    _cntools_action_vote_governance_info_command_output generated \
      "${governance_info_ccli_path}" latest governance committee key-hash \
      --verification-key-file "${cc_cold_vk_file}" || return 70
    [[ "${generated}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
    _cntools_action_vote_governance_info_bech32 cc_cold \
      "${generated}" generated || return 70
    _cntools_action_vote_governance_info_cache_publish \
      "${wallet_directory}" cc-cold "${cc_cold_id_file}" \
      "${generated}" cc_cold_id || return 70
  fi

  if [[ -e "${cc_hot_id_file}" || -L "${cc_hot_id_file}" ]]; then
    _cntools_action_vote_governance_info_cache_read \
      "${cc_hot_id_file}" cc-hot cc_hot_id || return 70
  elif [[ -e "${cc_hot_vk_file}" || -L "${cc_hot_vk_file}" ]]; then
    _cntools_action_vote_governance_info_input_file_usable \
      "${cc_hot_vk_file}" || return 70
    _cntools_action_vote_governance_info_command_output generated \
      "${governance_info_ccli_path}" latest governance committee key-hash \
      --verification-key-file "${cc_hot_vk_file}" || return 70
    [[ "${generated}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
    _cntools_action_vote_governance_info_bech32 cc_hot \
      "${generated}" generated || return 70
    _cntools_action_vote_governance_info_cache_publish \
      "${wallet_directory}" cc-hot "${cc_hot_id_file}" \
      "${generated}" cc_hot_id || return 70
  fi

  if [[ -n "${drep_id}" ]]; then
    if [[ "${drep_id}" == drep1* ]]; then
      hash_type=keyHash
      _cntools_action_vote_governance_info_bech32 "" \
        "${drep_id}" drep_hash || return 70
      [[ "${drep_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
      _cntools_action_vote_governance_info_bech32 drep \
        "22${drep_hash}" drep_id_cip129 || return 70
    else
      hash_type=scriptHash
      drep_hash="${drep_id}"
      _cntools_action_vote_governance_info_bech32 drep_script \
        "${drep_hash}" drep_id || return 70
      _cntools_action_vote_governance_info_bech32 drep \
        "23${drep_hash}" drep_id_cip129 || return 70
    fi
  fi
  if [[ -n "${cc_cold_id}" ]]; then
    _cntools_action_vote_governance_info_bech32 "" \
      "${cc_cold_id}" cc_cold_hash || return 70
    [[ "${cc_cold_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
    _cntools_action_vote_governance_info_bech32 cc_cold \
      "12${cc_cold_hash}" cc_cold_id_cip129 || return 70
  fi
  if [[ -n "${cc_hot_id}" ]]; then
    _cntools_action_vote_governance_info_bech32 "" \
      "${cc_hot_id}" cc_hot_hash || return 70
    [[ "${cc_hot_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
    _cntools_action_vote_governance_info_bech32 cc_hot \
      "02${cc_hot_hash}" cc_hot_id_cip129 || return 70
  fi
  return 0
}

_cntools_action_vote_governance_info_drep_ids() {
  local requested_type="${1:-}" requested_hash="${2:-}"

  drep_id="" drep_id_cip129=""
  [[ "${requested_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 1
  case "${requested_type}" in
    keyHash)
      _cntools_action_vote_governance_info_bech32 drep \
        "${requested_hash}" drep_id || return 1
      _cntools_action_vote_governance_info_bech32 drep \
        "22${requested_hash}" drep_id_cip129 || return 1
      ;;
    scriptHash)
      _cntools_action_vote_governance_info_bech32 drep_script \
        "${requested_hash}" drep_id || return 1
      _cntools_action_vote_governance_info_bech32 drep \
        "23${requested_hash}" drep_id_cip129 || return 1
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_vote_governance_info_reward_address() {
  local wallet_directory="${1:-}" output_variable="${2:-}"
  local target="${wallet_directory}/${WALLET_STAKE_ADDR_FILENAME}"
  local stake_vkey="${wallet_directory}/${WALLET_STAKE_VK_FILENAME}"
  local stake_script="${wallet_directory}/${WALLET_STAKE_SCRIPT_FILENAME}"
  local generated=""
  local -a address_arguments=()

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 70
  if [[ -e "${target}" || -L "${target}" ]]; then
    _cntools_action_vote_governance_info_cache_read \
      "${target}" reward "${output_variable}" || return 70
    return 0
  fi
  if [[ -e "${stake_vkey}" || -L "${stake_vkey}" ]]; then
    _cntools_action_vote_governance_info_input_file_usable \
      "${stake_vkey}" || return 70
    address_arguments=(latest stake-address build \
      --stake-verification-key-file "${stake_vkey}")
  elif [[ -e "${stake_script}" || -L "${stake_script}" ]]; then
    _cntools_action_vote_governance_info_input_file_usable \
      "${stake_script}" || return 70
    address_arguments=(latest stake-address build \
      --stake-script-file "${stake_script}")
  else
    return 1
  fi
  address_arguments+=("${governance_info_network_args[@]}")
  _cntools_action_vote_governance_info_command_output generated \
    "${governance_info_ccli_path}" "${address_arguments[@]}" || return 70
  _cntools_action_vote_governance_info_cache_value_valid \
    reward "${generated}" || return 70
  _cntools_action_vote_governance_info_cache_publish \
    "${wallet_directory}" reward "${target}" "${generated}" \
    "${output_variable}" || return 70
}

_cntools_action_vote_governance_info_delegation_parse() {
  local raw="${1:-}" output_variable="${2:-}" decoded=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "${raw}" in
    alwaysAbstain|drep_always_abstain)
      printf -v "${output_variable}" '%s' alwaysAbstain
      ;;
    alwaysNoConfidence|drep_always_no_confidence)
      printf -v "${output_variable}" '%s' alwaysNoConfidence
      ;;
    keyHash-[0-9A-Fa-f]*|scriptHash-[0-9A-Fa-f]*)
      [[ "${raw}" =~ ^(keyHash|scriptHash)-[0-9A-Fa-f]{56}$ ]] || return 1
      printf -v "${output_variable}" '%s' "${raw}"
      ;;
    drep1*)
      _cntools_action_vote_governance_info_bech32 "" \
        "${raw}" decoded || return 1
      [[ "${decoded}" =~ ^(22|23)[0-9A-Fa-f]{56}$ ]] || return 1
      if [[ "${decoded:0:2}" == 22 ]]; then
        printf -v "${output_variable}" 'keyHash-%s' "${decoded:2}"
      else
        printf -v "${output_variable}" 'scriptHash-%s' "${decoded:2}"
      fi
      ;;
    '') printf -v "${output_variable}" '%s' '' ;;
    *) return 1 ;;
  esac
}

_cntools_action_vote_governance_info_delegation_local() {
  local reward_address_value="${1:-}" response="" size="" raw=""
  local file_created="N"

  if [[ -z "${governance_info_status_file}" ]]; then
    _cntools_action_vote_governance_info_private_file_create status \
      governance_info_status_file || return 70
    file_created=Y
  fi
  println ACTION 'cardano-cli governance delegation query'
  if ! "${governance_info_ccli_path}" query stake-address-info \
      "${governance_info_network_args[@]}" --address \
      "${reward_address_value}" > "${governance_info_status_file}" \
      2>/dev/null; then
    if [[ "${file_created}" == Y ]]; then
      _cntools_action_vote_governance_info_private_file_release \
        governance_info_status_file || return 70
    fi
    println ERROR "${FG_RED}ERROR${NC}: failure during local governance delegation query!"
    return 2
  fi
  size="$(_cntools_action_vote_governance_info_file_size \
    "${governance_info_status_file}")" || return 70
  if [[ "${size}" -gt 1048576 ]]; then
    if [[ "${file_created}" == Y ]]; then
      _cntools_action_vote_governance_info_private_file_release \
        governance_info_status_file || return 70
    fi
    println ERROR "${FG_RED}ERROR${NC}: local governance delegation response exceeded the 1048576-byte safety limit!"
    return 2
  fi
  response="$("${governance_info_jq_path}" -er \
    --arg reward "${reward_address_value}" '
    def delegation:
      .voteDelegation as $delegation |
      if $delegation == null then "undelegated"
      elif ($delegation | type) == "string" and
        ($delegation == "alwaysAbstain" or
         $delegation == "alwaysNoConfidence") then $delegation
      elif ($delegation | type) == "object" and
        (($delegation | keys | length) <= 8) then
        if ($delegation.keyHashLedger // "") != "" then
          "keyHash-\($delegation.keyHashLedger)"
        elif ($delegation.scriptHashLedger // "") != "" then
          "scriptHash-\($delegation.scriptHashLedger)"
        elif ($delegation.keyHash // "") != "" then
          "keyHash-\($delegation.keyHash)"
        elif ($delegation.scriptHash // "") != "" then
          "scriptHash-\($delegation.scriptHash)"
        elif ($delegation.cip129Hex // "") != "" then
          if ($delegation.cip129Hex | startswith("22")) then
            "keyHash-\($delegation.cip129Hex[2:])"
          elif ($delegation.cip129Hex | startswith("23")) then
            "scriptHash-\($delegation.cip129Hex[2:])"
          else error("invalid CIP-129 delegation") end
        else "" end
      else error("invalid delegation") end;
    if type == "array" and length == 0 then "unregistered"
    elif type == "array" and length == 1 and
      (.[0] | type == "object" and length <= 12 and
        (.address == $reward) and
        (keys | all(.[]; . == "address" or . == "delegationDeposit" or
          . == "govActionDeposits" or . == "rewardAccountBalance" or
          . == "stakeDelegation" or . == "stakeRegistrationDeposit" or
          . == "voteDelegation")) and
        (.rewardAccountBalance == null or
          (.rewardAccountBalance | type == "number" and floor == . and
            . >= 0 and . <= 45000000000000000)) and
        (.stakeRegistrationDeposit == null or
          (.stakeRegistrationDeposit | type == "number" and floor == . and
            . >= 0 and . <= 45000000000000000)) and
        (.delegationDeposit == null or
          (.delegationDeposit | type == "number" and floor == . and
            . >= 0 and . <= 45000000000000000)) and
        (.govActionDeposits == null or
          (.govActionDeposits | type == "object" and length <= 100)) and
        (.stakeDelegation == null or
          (.stakeDelegation | type == "string" and length <= 256 and
            test("^[A-Za-z0-9_:-]+$"))))
    then (.[0] | delegation) as $delegation |
      if $delegation == "undelegated" or $delegation == "alwaysAbstain" or
         $delegation == "alwaysNoConfidence" or
         ($delegation | test("^(keyHash|scriptHash)-[0-9A-Fa-f]{56}$"))
      then $delegation else error("invalid delegation value") end
    else error("invalid local delegation response") end
  ' "${governance_info_status_file}" 2>/dev/null)" || response=""
  if [[ "${file_created}" == Y ]]; then
    _cntools_action_vote_governance_info_private_file_release \
      governance_info_status_file || return 70
  fi
  if [[ "${response}" == unregistered ]]; then return 1; fi
  if [[ "${response}" == undelegated ]]; then return 1; fi
  if [[ -z "${response}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: local governance delegation query returned an invalid response!"
    return 2
  fi
  raw="${response}"
  _cntools_action_vote_governance_info_delegation_parse \
    "${raw}" vote_delegation || {
      println ERROR "${FG_RED}ERROR${NC}: local governance delegation query returned an invalid response!"
      return 2
    }
  return 0
}

_cntools_action_vote_governance_info_delegation_remote() {
  local reward_address_value="${1:-}" payload="" url=""
  local response="" fetch_status=0 file_created="N"

  payload="{\"_stake_addresses\":[\"${reward_address_value}\"]}"
  url="${governance_info_koios_api}/account_info?select=stake_address,status,delegated_drep"
  if [[ -z "${governance_info_status_file}" ]]; then
    _cntools_action_vote_governance_info_private_file_create status \
      governance_info_status_file || return 70
    file_created=Y
  fi
  if _cntools_action_vote_governance_info_fetch status "${url}" \
      "${governance_info_status_file}" "${payload}"; then
    fetch_status=0
  else
    fetch_status=$?
  fi
  case "${fetch_status}" in
    0) ;;
    3)
      if [[ "${file_created}" == Y ]]; then
        _cntools_action_vote_governance_info_private_file_release \
          governance_info_status_file || return 70
      fi
      return 1
      ;;
    63)
      if [[ "${file_created}" == Y ]]; then
        _cntools_action_vote_governance_info_private_file_release \
          governance_info_status_file || return 70
      fi
      println ERROR "${FG_RED}ERROR${NC}: governance delegation response exceeded the 262144-byte safety limit!"
      return 2
      ;;
    1)
      if [[ "${file_created}" == Y ]]; then
        _cntools_action_vote_governance_info_private_file_release \
          governance_info_status_file || return 70
      fi
      println ERROR "${FG_RED}ERROR${NC}: failure during governance delegation query!"
      return 2
      ;;
    *) return 70 ;;
  esac
  response="$("${governance_info_jq_path}" -er \
    --arg reward "${reward_address_value}" '
    if type == "array" and length == 0 then "unregistered"
    elif type == "array" and length == 1 and
      (.[0] | type == "object" and
       keys == ["delegated_drep", "stake_address", "status"]) and
      (.[0].stake_address == $reward) and
      (.[0].status == "registered" or .[0].status == "not registered") and
      (.[0].delegated_drep == null or
       (.[0].delegated_drep | type == "string" and length <= 256 and
        test("^[A-Za-z0-9_]+$")))
    then if .[0].status == "registered" then
      (.[0].delegated_drep // "undelegated") else "unregistered" end
    else error("invalid governance delegation response") end
  ' "${governance_info_status_file}" 2>/dev/null)" || response=""
  if [[ "${file_created}" == Y ]]; then
    _cntools_action_vote_governance_info_private_file_release \
      governance_info_status_file || return 70
  fi
  if [[ "${response}" == unregistered ]]; then return 1; fi
  if [[ "${response}" == undelegated ]]; then return 1; fi
  if [[ -z "${response}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: governance delegation service returned an invalid response!"
    return 2
  fi
  _cntools_action_vote_governance_info_delegation_parse \
    "${response}" vote_delegation || {
      println ERROR "${FG_RED}ERROR${NC}: governance delegation service returned an invalid response!"
      return 2
    }
  return 0
}

_cntools_action_vote_governance_info_wallet_delegation() {
  local wallet_directory="${1:-}" reward_address_value=""
  local status=0

  vote_delegation=""
  if _cntools_action_vote_governance_info_reward_address \
      "${wallet_directory}" reward_address_value; then
    :
  else
    status=$?
    [[ "${status}" == 1 ]] && return 1
    return 70
  fi
  case "${governance_info_context_mode}" in
    local)
      _cntools_action_vote_governance_info_delegation_local \
        "${reward_address_value}"
      ;;
    light)
      _cntools_action_vote_governance_info_delegation_remote \
        "${reward_address_value}"
      ;;
    *) return 70 ;;
  esac
}

_cntools_action_vote_governance_info_url_valid() {
  local value="${1:-}" authority=""

  [[ "${#value}" -ge 9 && "${#value}" -le 2048 &&
     "${value}" == https://* && "${value}" != *\\* &&
     "${value}" != *'#'* && ! "${value}" =~ [[:cntrl:][:space:]] ]] ||
    return 1
  authority="${value#https://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  [[ -n "${authority}" && "${authority}" != .* &&
     "${authority}" != *..* &&
     "${authority}" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]
}

_cntools_action_vote_governance_info_api_base_valid() {
  local value="${1:-}"

  _cntools_action_vote_governance_info_url_valid "${value}" &&
    [[ "${value}" != *'?'* && "${value}" != */ ]]
}

_cntools_action_vote_governance_info_fetch() {
  local kind="${1:-}" url="${2:-}" target="${3:-}" payload="${4:-}"
  local limit="" curl_status=0 size=""
  local -a curl_command=()

  case "${kind}" in
    status) limit=262144 ;;
    power) limit=65536 ;;
    anchor) limit=262144 ;;
    *) return 70 ;;
  esac
  _cntools_action_vote_governance_info_url_valid "${url}" || return 2
  _cntools_action_vote_governance_info_file_metadata \
    "${target}" 600 1 Y || return 70
  curl_command=(
    "${governance_info_curl_path}"
    --disable
    --silent
    --location
    --max-redirs 3
    --proto '=https'
    --proto-redir '=https'
    --max-time "${governance_info_curl_timeout}"
    --fail
    --max-filesize "${limit}"
  )
  if [[ "${kind}" == status || "${kind}" == power ]]; then
    curl_command+=("${governance_info_koios_headers[@]}")
    curl_command+=(--header 'Accept: application/json')
  fi
  if [[ "${kind}" == status ]]; then
    curl_command+=(--header 'Content-Type: application/json' \
      --data "${payload}")
  fi
  curl_command+=(--output "${target}" --url "${url}")
  if [[ "${kind}" == anchor ]]; then
    println ACTION 'curl CNTools governance anchor query'
  else
    println ACTION 'curl [configured headers redacted] CNTools governance query'
  fi
  if "${curl_command[@]}" 2>/dev/null; then
    curl_status=0
  else
    curl_status=$?
  fi
  size="$(_cntools_action_vote_governance_info_file_size "${target}")" ||
    return 70
  if [[ "${curl_status}" == 63 || "${size}" -gt "${limit}" ]]; then
    return 63
  fi
  [[ "${curl_status}" == 0 ]] || return 1
  [[ "${size}" -ge 1 ]] || return 3
}

_cntools_action_vote_governance_info_integer_valid() {
  local value="${1:-}" maximum="${2:-45000000000000000}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${value}" -le "${maximum}" ]]
}

_cntools_action_vote_governance_info_status_remote() {
  local requested_type="${1:-}" requested_hash="${2:-}"
  local parameter="" payload="" url="" response="" fetch_status=0

  case "${requested_hash}" in
    alwaysAbstain) parameter=drep_always_abstain ;;
    alwaysNoConfidence) parameter=drep_always_no_confidence ;;
    *)
      [[ "${requested_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
      case "${requested_type}" in
        keyHash) parameter_prefix=22 ;;
        scriptHash) parameter_prefix=23 ;;
        *) return 70 ;;
      esac
      _cntools_action_vote_governance_info_bech32 drep \
        "${parameter_prefix}${requested_hash}" parameter || return 70
      ;;
  esac
  payload="{\"_drep_ids\":[\"${parameter}\"]}"
  url="${governance_info_koios_api}/drep_info?select=drep_status,deposit,active,expires_epoch_no,amount,meta_url,meta_hash"
  _cntools_action_vote_governance_info_private_file_create status \
    governance_info_status_file || return 70
  if _cntools_action_vote_governance_info_fetch status "${url}" \
      "${governance_info_status_file}" "${payload}"; then
    fetch_status=0
  else
    fetch_status=$?
  fi
  case "${fetch_status}" in
    0) ;;
    3) return 1 ;;
    63)
      println ERROR "${FG_RED}ERROR${NC}: governance status response exceeded the 262144-byte safety limit!"
      return 2
      ;;
    1)
      println ERROR "${FG_RED}ERROR${NC}: failure during governance status query!"
      return 2
      ;;
    *) return 70 ;;
  esac
  response="$("${governance_info_jq_path}" -er '
    def integer($maximum):
      (type == "number" and floor == . and . >= 0 and . <= $maximum) or
      (type == "string" and test("^(0|[1-9][0-9]{0,16})$") and
        (tonumber <= $maximum));
    if type == "array" and length == 0 then "unregistered"
    elif type == "array" and length == 1 and
      (.[0] | type == "object" and
        keys == ["active", "amount", "deposit", "drep_status",
          "expires_epoch_no", "meta_hash", "meta_url"]) and
      (.[0].drep_status == "registered") and
      (.[0].deposit | integer(45000000000000000)) and
      (.[0].active | type == "boolean") and
      (.[0].expires_epoch_no | integer(4294967295)) and
      (.[0].amount | integer(45000000000000000)) and
      ((.[0].meta_url == null and .[0].meta_hash == null) or
       ((.[0].meta_url | type == "string") and
        (.[0].meta_hash | type == "string" and
          test("^[0-9A-Fa-f]{64}$"))))
    then [
      (.[0].meta_url // "-"), (.[0].meta_hash // "-"),
      (.[0].deposit | tostring), (.[0].expires_epoch_no | tostring),
      (.[0].active | tostring), (.[0].amount | tostring)
    ] | @tsv
    else error("invalid governance status response") end
  ' "${governance_info_status_file}" 2>/dev/null)" || response=""
  if [[ "${response}" == unregistered ]]; then return 1; fi
  if [[ -z "${response}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: governance status service returned an invalid response!"
    return 2
  fi
  IFS=$'\t' read -r drep_anchor_url drep_anchor_hash drep_deposit_amt \
    drep_expiry drep_active drep_vote_power <<< "${response}" || return 70
  [[ "${drep_anchor_url}" != - ]] || drep_anchor_url=""
  [[ "${drep_anchor_hash}" != - ]] || drep_anchor_hash=""
  _cntools_action_vote_governance_info_integer_valid \
    "${drep_deposit_amt}" || return 70
  _cntools_action_vote_governance_info_integer_valid \
    "${drep_expiry}" 4294967295 || return 70
  _cntools_action_vote_governance_info_integer_valid \
    "${drep_vote_power}" || return 70
  if [[ -n "${drep_anchor_url}" ]] &&
     ! _cntools_action_vote_governance_info_url_valid \
       "${drep_anchor_url}"; then
    println ERROR "${FG_RED}ERROR${NC}: governance status service returned an invalid response!"
    drep_anchor_url="" drep_anchor_hash=""
    return 2
  fi
  return 0
}

_cntools_action_vote_governance_info_status_local() {
  local requested_type="${1:-}" requested_hash="${2:-}"
  local response="" size="" identity_key=""
  local -a hash_arguments=()

  [[ "${requested_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
  case "${requested_type}" in
    keyHash) hash_arguments=(--drep-key-hash "${requested_hash}"); identity_key=keyHash ;;
    scriptHash) hash_arguments=(--drep-script-hash "${requested_hash}"); identity_key=scriptHash ;;
    *) return 70 ;;
  esac
  _cntools_action_vote_governance_info_private_file_create status \
    governance_info_status_file || return 70
  println ACTION 'cardano-cli governance drep-state query'
  if ! "${governance_info_ccli_path}" latest query drep-state \
      "${hash_arguments[@]}" "${governance_info_network_args[@]}" \
      > "${governance_info_status_file}" 2>/dev/null; then
    println ERROR "${FG_RED}ERROR${NC}: failure during local governance status query!"
    return 2
  fi
  size="$(_cntools_action_vote_governance_info_file_size \
    "${governance_info_status_file}")" || return 70
  if [[ "${size}" -gt 1048576 ]]; then
    println ERROR "${FG_RED}ERROR${NC}: local governance status response exceeded the 1048576-byte safety limit!"
    return 2
  fi
  response="$("${governance_info_jq_path}" -er \
    --arg identity_key "${identity_key}" --arg requested "${requested_hash}" '
    def integer($maximum):
      type == "number" and floor == . and . >= 0 and . <= $maximum;
    if type == "array" and length == 0 then "unregistered"
    elif type == "array" and length == 1 and
      (.[0] | type == "array" and length == 2) and
      (.[0][0] | type == "object" and .[$identity_key] == $requested) and
      (.[0][1] | type == "object") and
      (.[0][1].deposit | integer(45000000000000000)) and
      (.[0][1].expiry | integer(4294967295)) and
      ((.[0][1].anchor == null) or
       (.[0][1].anchor | type == "object" and
        (.url | type == "string") and
        (.dataHash | type == "string" and test("^[0-9A-Fa-f]{64}$"))))
    then [
      (.[0][1].anchor.url // "-"), (.[0][1].anchor.dataHash // "-"),
      (.[0][1].deposit | tostring), (.[0][1].expiry | tostring)
    ] | @tsv
    else error("invalid local governance status response") end
  ' "${governance_info_status_file}" 2>/dev/null)" || response=""
  if [[ "${response}" == unregistered ]]; then return 1; fi
  if [[ -z "${response}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: local governance query returned an invalid response!"
    return 2
  fi
  IFS=$'\t' read -r drep_anchor_url drep_anchor_hash drep_deposit_amt \
    drep_expiry <<< "${response}" || return 70
  [[ "${drep_anchor_url}" != - ]] || drep_anchor_url=""
  [[ "${drep_anchor_hash}" != - ]] || drep_anchor_hash=""
  _cntools_action_vote_governance_info_integer_valid \
    "${drep_deposit_amt}" || return 70
  _cntools_action_vote_governance_info_integer_valid \
    "${drep_expiry}" 4294967295 || return 70
  if [[ -n "${drep_anchor_url}" ]] &&
     ! _cntools_action_vote_governance_info_url_valid \
       "${drep_anchor_url}"; then
    println ERROR "${FG_RED}ERROR${NC}: local governance query returned an invalid response!"
    drep_anchor_url="" drep_anchor_hash=""
    return 2
  fi
  return 0
}

_cntools_action_vote_governance_info_status() {
  local requested_type="${1:-}" requested_hash="${2:-}"

  hash_type="${requested_type}" drep_hash="${requested_hash}"
  drep_anchor_url="" drep_anchor_hash="" drep_deposit_amt=""
  drep_expiry="" drep_active="" drep_vote_power=""
  case "${governance_info_context_mode}" in
    light)
      _cntools_action_vote_governance_info_status_remote \
        "${requested_type}" "${requested_hash}"
      ;;
    local)
      _cntools_action_vote_governance_info_status_local \
        "${requested_type}" "${requested_hash}"
      ;;
    *) return 70 ;;
  esac
}

_cntools_action_vote_governance_info_power_total() {
  local response_file="${1:-}" format="${2:-}" total=0 value="" count=0
  local values=""

  case "${format}" in
    local)
      values="$("${governance_info_jq_path}" -er '
        if type == "object" and length <= 100000 and
          all(keys[]; test("^drep-(keyHash|scriptHash)-[0-9A-Fa-f]{56}$") or
            . == "drep-alwaysAbstain" or . == "drep-alwaysNoConfidence") and
          all(.[]; type == "number" and floor == . and
            . >= 0 and . <= 45000000000000000)
        then .[] | tostring
        else error("invalid vote-power response") end
      ' "${response_file}" 2>/dev/null)" || return 1
      if [[ -n "${values}" ]]; then
        while IFS= read -r value; do
          count=$((count + 1))
          [[ "${count}" -le 100000 ]] || return 1
          _cntools_action_vote_governance_info_integer_valid "${value}" ||
            return 1
          [[ "${total}" -le 45000000000000000 &&
             "${value}" -le $((45000000000000000 - total)) ]] ||
            return 1
          total=$((total + value))
        done <<< "${values}"
      fi
      ;;
    remote)
      value="$("${governance_info_jq_path}" -er '
        def integer:
          (type == "number" and floor == . and
            . >= 0 and . <= 45000000000000000) or
          (type == "string" and test("^(0|[1-9][0-9]{0,16})$") and
            (tonumber <= 45000000000000000));
        if type == "array" and length == 1 and
          (.[0] | type == "object") and (.[0].amount | integer)
        then .[0].amount | tostring
        else error("invalid vote-power response") end
      ' "${response_file}" 2>/dev/null)" || return 1
      _cntools_action_vote_governance_info_integer_valid "${value}" ||
        return 1
      total="${value}"
      ;;
    *) return 1 ;;
  esac
  _cntools_action_vote_governance_info_integer_valid "${total}" || return 1
  printf '%s\n' "${total}"
}

_cntools_action_vote_governance_info_vote_power() {
  local requested_type="${1:-}" requested_hash="${2:-}"
  local search_key="" size="" total="" fraction="" fetch_status=0

  vote_power="" vote_power_total="" vote_power_pct=""
  if [[ "${governance_info_context_mode}" == light ]]; then
    if [[ "${requested_hash}" == always* ||
          "${drep_hash}" != "${requested_hash}" ]] ||
       ! _cntools_action_vote_governance_info_integer_valid \
         "${drep_vote_power}"; then
      _cntools_action_vote_governance_info_status \
        "${requested_type}" "${requested_hash}" || return 1
    fi
    _cntools_action_vote_governance_info_private_file_create power \
      governance_info_power_file || return 70
    if _cntools_action_vote_governance_info_fetch power \
        "${governance_info_koios_api}/drep_epoch_summary?_epoch_no=${current_epoch}&select=amount" \
        "${governance_info_power_file}" ""; then
      fetch_status=0
    else
      fetch_status=$?
    fi
    case "${fetch_status}" in
      0) ;;
      63)
        println ERROR "${FG_RED}ERROR${NC}: governance vote-power response exceeded the 65536-byte safety limit!"
        return 1
        ;;
      1|3)
        println ERROR "${FG_RED}ERROR${NC}: failure during governance vote-power query!"
        return 1
        ;;
      *) return 70 ;;
    esac
    total="$(_cntools_action_vote_governance_info_power_total \
      "${governance_info_power_file}" remote)" || {
        println ERROR "${FG_RED}ERROR${NC}: governance vote-power service returned an invalid response!"
        return 1
      }
    vote_power="${drep_vote_power}"
    vote_power_total="${total}"
  elif [[ "${governance_info_context_mode}" == local ]]; then
    case "${requested_hash}" in
      alwaysAbstain) search_key=drep-alwaysAbstain ;;
      alwaysNoConfidence) search_key=drep-alwaysNoConfidence ;;
      *)
        [[ "${requested_type}" == keyHash || \
           "${requested_type}" == scriptHash ]] || return 70
        [[ "${requested_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
        search_key="drep-${requested_type}-${requested_hash}"
        ;;
    esac
    _cntools_action_vote_governance_info_private_file_create power \
      governance_info_power_file || return 70
    println ACTION 'cardano-cli governance vote-power query'
    if ! "${governance_info_ccli_path}" latest query \
        drep-stake-distribution --all-dreps \
        "${governance_info_network_args[@]}" \
        > "${governance_info_power_file}" 2>/dev/null; then
      println ERROR "${FG_RED}ERROR${NC}: failure during local governance vote-power query!"
      return 1
    fi
    size="$(_cntools_action_vote_governance_info_file_size \
      "${governance_info_power_file}")" || return 70
    if [[ "${size}" -gt 8388608 ]]; then
      println ERROR "${FG_RED}ERROR${NC}: local governance vote-power response exceeded the 8388608-byte safety limit!"
      return 1
    fi
    total="$(_cntools_action_vote_governance_info_power_total \
      "${governance_info_power_file}" local)" || {
        println ERROR "${FG_RED}ERROR${NC}: local governance vote-power query returned an invalid response!"
        return 1
      }
    vote_power="$("${governance_info_jq_path}" -er --arg key "${search_key}" \
      '.[$key] | select(type == "number" and floor == . and . >= 0 and
        . <= 45000000000000000) | tostring' \
      "${governance_info_power_file}" 2>/dev/null)" || vote_power=""
    _cntools_action_vote_governance_info_integer_valid "${vote_power}" ||
      return 1
    vote_power_total="${total}"
  else
    return 70
  fi
  if [[ "${vote_power_total}" == 0 || "${vote_power}" == 0 ]]; then
    vote_power_pct=0.00
    return 0
  fi
  fraction="$("${governance_info_bc_path}" -l \
    <<< "${vote_power}/${vote_power_total}" 2>/dev/null)" || return 70
  vote_power_pct="$(fractionToPCT "${fraction}")" || return 70
  [[ "${vote_power_pct}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 70
  if [[ -z "${vote_power_pct%.*}" || "${vote_power_pct%.*}" == 0 ]]; then
    vote_power_pct="$(printf '%.4f' "${vote_power_pct}")" || return 70
  else
    vote_power_pct="$(printf '%.2f' "${vote_power_pct}")" || return 70
  fi
  return 0
}

_cntools_action_vote_governance_info_anchor() {
  local anchor_url="${1:-}" expected_hash="${2:-}"
  local actual_hash="" fetch_status=0

  drep_anchor_file="" drep_anchor_real_hash=""
  _cntools_action_vote_governance_info_url_valid "${anchor_url}" || return 1
  [[ "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  _cntools_action_vote_governance_info_private_file_create anchor \
    governance_info_anchor_file || return 70
  if _cntools_action_vote_governance_info_fetch anchor "${anchor_url}" \
      "${governance_info_anchor_file}" ""; then
    fetch_status=0
  else
    fetch_status=$?
  fi
  case "${fetch_status}" in
    0) ;;
    1|2|3|63) return 1 ;;
    *) return 70 ;;
  esac
  "${governance_info_jq_path}" -e '
    def safe:
      if type == "string" then
        length <= 8192 and
        (test("[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]") | not)
      elif type == "array" then length <= 4096 and all(.[]; safe)
      elif type == "object" then length <= 4096 and
        all(keys[]; safe) and all(.[]; safe)
      else true end;
    (type == "object" or type == "array") and safe
  ' "${governance_info_anchor_file}" >/dev/null 2>&1 || return 1
  _cntools_action_vote_governance_info_command_output actual_hash \
    "${governance_info_ccli_path}" hash anchor-data \
    --file-text "${governance_info_anchor_file}" || return 70
  [[ "${actual_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 70
  drep_anchor_file="${governance_info_anchor_file}"
  drep_anchor_real_hash="${actual_hash}"
  [[ "${actual_hash,,}" == "${expected_hash,,}" ]] || return 2
  return 0
}

_cntools_action_vote_governance_info_render_anchor() {
  local status=0

  if _cntools_action_vote_governance_info_anchor \
      "${drep_anchor_url}" "${drep_anchor_hash}"; then
    status=0
  else
    status=$?
  fi
  case "${status}" in
    0)
      println "$(printf '%-20s :\n' 'DRep anchor data')"
      "${governance_info_jq_path}" -c . "${drep_anchor_file}" 2>/dev/null ||
        return 70
      println DEBUG "${NC}"
      ;;
    1)
      println "$(printf '%-20s : %s' 'DRep anchor data' \
        'Invalid URL or currently not available')"
      ;;
    2)
      println "$(printf '%-20s :\n' 'DRep anchor data')"
      "${governance_info_jq_path}" -c . "${drep_anchor_file}" 2>/dev/null ||
        return 70
      println "$(printf '%-20s : %s' 'DRep anchor hash' 'mismatch')"
      println "$(printf '%-20s : %s' '  registered' "${drep_anchor_hash}")"
      println "$(printf '%-20s : %s' '  actual' "${drep_anchor_real_hash}")"
      ;;
    *) return 70 ;;
  esac
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local governance_info_context_mode="" governance_info_context_network=""
  local governance_info_private_parent="" governance_info_wallet_root=""
  local governance_info_wallet_root_physical="" governance_info_curl_timeout=""
  local governance_info_koios_api="" governance_info_jq_path=""
  local governance_info_curl_path="" governance_info_mktemp_path=""
  local governance_info_chmod_path="" governance_info_rm_path=""
  local governance_info_ln_path="" governance_info_wc_path=""
  local governance_info_find_path="" governance_info_sort_path=""
  local governance_info_bech32_path="" governance_info_ccli_path=""
  local governance_info_bc_path="" governance_info_status_file=""
  local governance_info_power_file="" governance_info_anchor_file=""
  local wallet_directory="" wallet_candidate="" wallet_candidate_name=""
  local wallet_name="" walletName="" current_epoch="" drep_script_file=""
  local vote_delegation="" vote_delegation_hash=""
  local vote_delegation_type="" status_result=0 cleanup_status=0
  local drep_id="" drep_id_cip129="" drep_hash="" hash_type=""
  local drep_anchor_url="" drep_anchor_hash="" drep_anchor_file=""
  local drep_anchor_real_hash="" drep_deposit_amt="" drep_expiry=""
  local drep_active="" drep_vote_power="" vote_power=""
  local vote_power_total="" vote_power_pct="" expire_status=""
  local cc_cold_hash="" cc_cold_id="" cc_cold_id_cip129=""
  local cc_hot_hash="" cc_hot_id="" cc_hot_id_cip129=""
  local parameter_prefix="" filename="" header_index=0 header_value=""
  local network_magic="" action_status=0
  local -a governance_info_temp_files=() governance_info_network_args=()
  local -a governance_info_koios_headers=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate \
       >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F versionCheck >/dev/null 2>&1 ||
     ! builtin declare -F selectWallet >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getEpoch >/dev/null 2>&1 ||
     ! builtin declare -F formatLovelace >/dev/null 2>&1 ||
     ! builtin declare -F fractionToPCT >/dev/null 2>&1; then
    _cntools_action_vote_governance_info_validation_failure
    return 70
  fi
  governance_info_context_mode="$(cntools_context_get \
    "${context_file}" mode)" || action_status=70
  governance_info_context_network="$(cntools_context_get \
    "${context_file}" nodeNetwork)" || action_status=70
  [[ "${action_status}" == 0 &&
     "${CNTOOLS_MODE,,}" == "${governance_info_context_mode}" ]] || {
    _cntools_action_vote_governance_info_validation_failure
    return 70
  }
  for filename in "${WALLET_GOV_DREP_VK_FILENAME}" \
      "${WALLET_GOV_DREP_SCRIPT_FILENAME}" \
      "${WALLET_GOV_DREP_ID_FILENAME}" \
      "${WALLET_GOV_CC_COLD_VK_FILENAME}" \
      "${WALLET_GOV_CC_COLD_ID_FILENAME}" \
      "${WALLET_GOV_CC_HOT_VK_FILENAME}" \
      "${WALLET_GOV_CC_HOT_ID_FILENAME}" \
      "${WALLET_STAKE_ADDR_FILENAME}" \
      "${WALLET_STAKE_VK_FILENAME}" \
      "${WALLET_STAKE_SCRIPT_FILENAME}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9._-]{1,128}$ &&
       "${filename}" != . && "${filename}" != .. ]] || action_status=70
  done
  governance_info_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate \
    "${governance_info_private_parent}" || action_status=70
  governance_info_wallet_root="${WALLET_FOLDER:-}"
  [[ "${governance_info_wallet_root}" == /* &&
     -d "${governance_info_wallet_root}" &&
     ! -L "${governance_info_wallet_root}" ]] || action_status=70
  _cntools_registry_path_has_no_symlinks \
    "${governance_info_wallet_root}" || action_status=70
  governance_info_wallet_root_physical="$(cd -P -- \
    "${governance_info_wallet_root}" >/dev/null 2>&1 && pwd -P)" ||
    action_status=70
  for filename in jq curl mktemp chmod rm ln wc find sort bech32 bc; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq governance_info_jq_path || action_status=70 ;;
      curl)
        if [[ "${governance_info_context_mode}" != offline ]]; then
          _cntools_registry_tool_path curl governance_info_curl_path ||
            action_status=70
        fi
        ;;
      mktemp) _cntools_registry_tool_path mktemp governance_info_mktemp_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod governance_info_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm governance_info_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln governance_info_ln_path || action_status=70 ;;
      wc) _cntools_registry_tool_path wc governance_info_wc_path || action_status=70 ;;
      find) _cntools_registry_tool_path find governance_info_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort governance_info_sort_path || action_status=70 ;;
      bech32) _cntools_registry_tool_path bech32 governance_info_bech32_path || action_status=70 ;;
      bc)
        if [[ "${governance_info_context_mode}" != offline ]]; then
          _cntools_registry_tool_path bc governance_info_bc_path ||
            action_status=70
        fi
        ;;
    esac
  done
  governance_info_ccli_path="$(builtin type -P "${CCLI:-}" 2>/dev/null)" ||
    action_status=70
  [[ "${governance_info_ccli_path}" == /* &&
     -x "${governance_info_ccli_path}" ]] || action_status=70
  case "${governance_info_context_network}" in
    mainnet) governance_info_network_args=(--mainnet) ;;
    *)
      network_magic="${NWMAGIC:-}"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 ]] || action_status=70
      governance_info_network_args=(--testnet-magic "${network_magic}")
      ;;
  esac
  governance_info_curl_timeout="${CURL_TIMEOUT:-}"
  if [[ "${governance_info_context_mode}" != offline ]]; then
    [[ "${governance_info_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] ||
      action_status=70
  fi
  if [[ "${governance_info_context_mode}" == light ]]; then
    governance_info_koios_api="${KOIOS_API:-}"
    _cntools_action_vote_governance_info_api_base_valid \
      "${governance_info_koios_api}" || action_status=70
    governance_info_koios_api="${governance_info_koios_api%/}"
    governance_info_koios_headers=("${KOIOS_API_HEADERS[@]}")
    (( ${#governance_info_koios_headers[@]} % 2 == 0 &&
       ${#governance_info_koios_headers[@]} <= 8 )) || action_status=70
    for ((header_index=0;
        header_index<${#governance_info_koios_headers[@]};
        header_index+=2)); do
      header_value="${governance_info_koios_headers[header_index+1]}"
      [[ ( "${governance_info_koios_headers[header_index]}" == -H ||
           "${governance_info_koios_headers[header_index]}" == --header ) &&
         "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
         "${header_value}" == *:* && "${header_value}" != *$'\r'* &&
         "${header_value}" != *$'\n'* ]] || action_status=70
    done
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_vote_governance_info_validation_failure
    return 70
  }

  umask 077
  trap '_cntools_action_vote_governance_info_cleanup' EXIT
  trap '_cntools_action_vote_governance_info_cleanup; exit 70' HUP INT TERM
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> VOTE >> GOVERNANCE >> INFO & STATUS'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  if ! versionCheck '9.0' "${PROT_VERSION}"; then
    println INFO "${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"
    waitToProceed
    _cntools_action_vote_governance_info_cleanup || cleanup_status=1
    [[ "${cleanup_status}" == 0 ]] || {
      _cntools_action_vote_governance_info_validation_failure; return 70;
    }
    return 0
  fi
  if [[ -z "$("${governance_info_find_path}" \
      "${governance_info_wallet_root_physical}" -mindepth 1 -maxdepth 1 \
      -type d -print -quit 2>/dev/null)" ]]; then
    echo
    println "${FG_YELLOW}No wallets available!${NC}"
    waitToProceed
    _cntools_action_vote_governance_info_cleanup || cleanup_status=1
    [[ "${cleanup_status}" == 0 ]] || {
      _cntools_action_vote_governance_info_validation_failure; return 70;
    }
    return 0
  fi
  println DEBUG 'Select wallet (derive governance keys if missing)'
  selectWallet none
  case $? in
    0) ;;
    1)
      waitToProceed
      _cntools_action_vote_governance_info_cleanup || cleanup_status=1
      [[ "${cleanup_status}" == 0 ]] || {
        _cntools_action_vote_governance_info_validation_failure; return 70;
      }
      return 0
      ;;
    2)
      _cntools_action_vote_governance_info_cleanup || cleanup_status=1
      [[ "${cleanup_status}" == 0 ]] || {
        _cntools_action_vote_governance_info_validation_failure; return 70;
      }
      return 0
      ;;
    *)
      _cntools_action_vote_governance_info_cleanup || true
      _cntools_action_vote_governance_info_validation_failure
      return 70
      ;;
  esac
  _cntools_action_vote_governance_info_wallet_directory \
    "${wallet_name}" wallet_directory || {
      _cntools_action_vote_governance_info_cleanup || true
      _cntools_action_vote_governance_info_validation_failure
      return 70
    }
  current_epoch="$(getEpoch)" || current_epoch=""
  _cntools_action_vote_governance_info_integer_valid \
    "${current_epoch}" 4294967295 || {
      _cntools_action_vote_governance_info_cleanup || true
      _cntools_action_vote_governance_info_validation_failure
      return 70
    }
  drep_script_file="${wallet_directory}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
  if [[ "${governance_info_context_mode}" != offline &&
        ! -f "${drep_script_file}" ]]; then
    println DEBUG "\n${BOLD}~~ Vote Delegation Status ~~${NC}"
    walletName=""
    if _cntools_action_vote_governance_info_wallet_delegation \
        "${wallet_directory}"; then
      status_result=0
    else
      status_result=$?
    fi
    if [[ "${status_result}" == 0 ]]; then
      vote_delegation_hash=""
      case "${vote_delegation}" in
        alwaysAbstain)
          vote_delegation_type=alwaysAbstain
          println "$(printf '%-20s : %s' Delegation 'Always abstain')"
          ;;
        alwaysNoConfidence)
          vote_delegation_type=alwaysNoConfidence
          println "$(printf '%-20s : %s' Delegation 'Always no confidence')"
          ;;
        keyHash-*|scriptHash-*)
          vote_delegation_type="${vote_delegation%%-*}"
          vote_delegation_hash="${vote_delegation#*-}"
          [[ ( "${vote_delegation_type}" == keyHash ||
               "${vote_delegation_type}" == scriptHash ) &&
             "${vote_delegation_hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || {
            _cntools_action_vote_governance_info_cleanup || true
            _cntools_action_vote_governance_info_validation_failure
            return 70
          }
          while IFS= read -r -d '' wallet_candidate; do
            wallet_candidate_name="${wallet_candidate##*/}"
            _cntools_action_vote_governance_info_safe_component \
              "${wallet_candidate_name}" || continue
            if _cntools_action_vote_governance_info_key_info \
                "${wallet_candidate_name}"; then
              if [[ "${drep_hash}" == "${vote_delegation_hash}" ]]; then
                walletName="${wallet_candidate_name}"
                break
              fi
            elif [[ $? == 70 ]]; then
              _cntools_action_vote_governance_info_cleanup || true
              _cntools_action_vote_governance_info_validation_failure
              return 70
            fi
          done < <("${governance_info_find_path}" \
            "${governance_info_wallet_root_physical}" -mindepth 1 \
            -maxdepth 1 -type d -print0 | LC_ALL=C \
            "${governance_info_sort_path}" -z)
          _cntools_action_vote_governance_info_drep_ids \
            "${vote_delegation_type}" "${vote_delegation_hash}" || {
              _cntools_action_vote_governance_info_cleanup || true
              _cntools_action_vote_governance_info_validation_failure
              return 70
            }
          println "$(printf '%-20s : CIP-105 => %s' Delegation "${drep_id}")"
          println "$(printf '%-20s : CIP-129 => %s' '' "${drep_id_cip129}")"
          if [[ -n "${walletName}" ]]; then
            println "$(printf '%-20s : Wallet  => %s' '' "${walletName}")"
          fi
          if [[ "${vote_delegation_type}" == keyHash ]]; then
            println "$(printf '%-20s : %s' 'DRep Type' Key)"
          else
            println "$(printf '%-20s : %s' 'DRep Type' MultiSig)"
          fi
          if _cntools_action_vote_governance_info_status \
              "${vote_delegation_type}" "${vote_delegation_hash}"; then
            status_result=0
          else
            status_result=$?
          fi
          case "${status_result}" in
            0)
              if [[ "${current_epoch}" -lt "${drep_expiry}" ]]; then
                expire_status=active
              else
                expire_status='inactive (vote power does not count)'
              fi
              println "$(printf '%-20s : epoch %s - %s' \
                'DRep expiry' "${drep_expiry}" "${expire_status}")"
              if [[ -n "${drep_anchor_url}" ]]; then
                println "$(printf '%-20s : %s' \
                  'DRep anchor url' "${drep_anchor_url}")"
                _cntools_action_vote_governance_info_render_anchor || {
                  _cntools_action_vote_governance_info_cleanup || true
                  _cntools_action_vote_governance_info_validation_failure
                  return 70
                }
              fi
              ;;
            1|2)
              println "$(printf '%-20s : %s' Status \
                'Unable to get DRep status, retired?')"
              ;;
            *)
              _cntools_action_vote_governance_info_cleanup || true
              _cntools_action_vote_governance_info_validation_failure
              return 70
              ;;
          esac
          ;;
        *)
          _cntools_action_vote_governance_info_cleanup || true
          _cntools_action_vote_governance_info_validation_failure
          return 70
          ;;
      esac
      if _cntools_action_vote_governance_info_vote_power \
          "${vote_delegation_type}" \
          "${vote_delegation_hash:-${vote_delegation_type}}"; then :; fi
      vote_power="${vote_power:-0}"
      vote_power_pct="${vote_power_pct:-0}"
      println "$(printf '%-20s : %s ADA (%s %%)' \
        'Active Vote power' "$(formatLovelace "${vote_power}")" \
        "${vote_power_pct}")"
    elif [[ "${status_result}" == 1 || "${status_result}" == 2 ]]; then
      if versionCheck '10.0' "${PROT_VERSION}"; then
        println "$(printf '%-20s : %s - %s' Delegation undelegated \
          'please note that reward withdrawals will not work until wallet is vote delegated')"
      else
        println "$(printf '%-20s : %s' Delegation undelegated)"
      fi
    else
      _cntools_action_vote_governance_info_cleanup || true
      _cntools_action_vote_governance_info_validation_failure
      return 70
    fi
  fi
  if ! _cntools_action_vote_governance_info_key_info "${wallet_name}"; then
    _cntools_action_vote_governance_info_cleanup || true
    _cntools_action_vote_governance_info_validation_failure
    return 70
  fi
  println DEBUG "\n${BOLD}~~ Own DRep Status ~~${NC}"
  if [[ -z "${drep_id}" ]]; then
    println "$(printf '%-20s : %s' Status \
      'Governance keys missing, please derive them if needed')"
    waitToProceed
    _cntools_action_vote_governance_info_cleanup || cleanup_status=1
    [[ "${cleanup_status}" == 0 ]] || {
      _cntools_action_vote_governance_info_validation_failure; return 70;
    }
    return 0
  fi
  println "$(printf '%-20s : CIP-105 => %s' 'DRep ID' "${drep_id}")"
  println "$(printf '%-20s : CIP-129 => %s' '' "${drep_id_cip129}")"
  println "$(printf '%-20s : %s' 'DRep Hash' "${drep_hash}")"
  if [[ "${hash_type}" == keyHash ]]; then
    println "$(printf '%-20s : %s' 'DRep Type' Key)"
  else
    println "$(printf '%-20s : %s' 'DRep Type' MultiSig)"
  fi
  if [[ "${governance_info_context_mode}" != offline ]]; then
    if _cntools_action_vote_governance_info_status \
        "${hash_type}" "${drep_hash}"; then
      status_result=0
    else
      status_result=$?
    fi
    case "${status_result}" in
      0)
        if [[ "${current_epoch}" -lt "${drep_expiry}" ]]; then
          expire_status=active
        else
          expire_status='inactive (vote power does not count)'
        fi
        println "$(printf '%-20s : epoch %s - %s' \
          'DRep expiry' "${drep_expiry}" "${expire_status}")"
        if [[ -n "${drep_anchor_url}" ]]; then
          println "$(printf '%-20s : %s' \
            'DRep anchor url' "${drep_anchor_url}")"
          _cntools_action_vote_governance_info_render_anchor || {
            _cntools_action_vote_governance_info_cleanup || true
            _cntools_action_vote_governance_info_validation_failure
            return 70
          }
        fi
        if _cntools_action_vote_governance_info_vote_power \
            "${hash_type}" "${drep_hash}"; then :; fi
        vote_power="${vote_power:-0}"
        vote_power_pct="${vote_power_pct:-0}"
        println "$(printf '%-20s : %s ADA (%s %%)' \
          'Active Vote power' "$(formatLovelace "${vote_power}")" \
          "${vote_power_pct}")"
        ;;
      1|2)
        println "$(printf '%-20s : %s' Status 'DRep key not registered')"
        ;;
      *)
        _cntools_action_vote_governance_info_cleanup || true
        _cntools_action_vote_governance_info_validation_failure
        return 70
        ;;
    esac
  fi
  if [[ -n "${cc_cold_id}" ]]; then
    echo
    println "$(printf '%-20s : CIP-105 => %s' \
      'Committee Cold ID' "${cc_cold_id}")"
    println "$(printf '%-20s : CIP-129 => %s' '' "${cc_cold_id_cip129}")"
    println "$(printf '%-20s : CIP-105 => %s' \
      'Committee Hot ID' "${cc_hot_id}")"
    println "$(printf '%-20s : CIP-129 => %s' '' "${cc_hot_id_cip129}")"
  fi
  waitToProceed
  _cntools_action_vote_governance_info_cleanup || cleanup_status=1
  [[ "${cleanup_status}" == 0 ]] || {
    _cntools_action_vote_governance_info_validation_failure
    return 70
  }
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
