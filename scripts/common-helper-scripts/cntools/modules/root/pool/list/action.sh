#!/usr/bin/env bash
# shellcheck disable=SC2154
# Stage 4 compatibility action for the characterized legacy pool listing.
# The action is observational: pool IDs are resolved in memory and listing
# never deletes or creates operator state.

_cntools_action_pool_list_validation_failure() {
  builtin printf '%s\n' 'CNTools pool-list action failed validation.' >&2
  return 70
}

_cntools_action_pool_list_cleanup() {
  local target="" failed=0

  for target in "${pool_list_temp_files[@]:-}"; do
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${pool_list_rm_path}" -f -- "${target}" >/dev/null 2>&1 || failed=1
    fi
  done
  pool_list_temp_files=()
  return "${failed}"
}

_cntools_action_pool_list_file_validate() {
  local target="${1:-}" expected_modes="${2:-}" maximum_size="${3:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -f "${target}" && ! -L "${target}" &&
     "${maximum_size}" =~ ^[1-9][0-9]*$ ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${size}" =~ ^[0-9]+$ && "${size}" -ge 1 &&
     "${size}" -le "${maximum_size}" &&
     ",${expected_modes}," == *",${mode},"* ]]
}

_cntools_action_pool_list_pool_id_valid() {
  local kind="${1:-}" value="${2:-}"

  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || return 1
  case "${kind}" in
    hex) [[ "${value}" =~ ^[0-9A-Fa-f]{56}$ ]] ;;
    bech32) [[ "${value}" =~ ^pool1[023456789ac-hj-np-z]{20,100}$ ]] ;;
    *) return 1 ;;
  esac
}

_cntools_action_pool_list_id_read() {
  local target="${1:-}" kind="${2:-}" output_variable="${3:-}"
  local value=""

  case "${output_variable}" in
    pool_id|pool_id_bech32) ;;
    *) return 1 ;;
  esac
  _cntools_action_pool_list_file_validate \
    "${target}" '400,444,600,644' 256 ||
    return 1
  value="$(< "${target}")"
  _cntools_action_pool_list_pool_id_valid "${kind}" "${value}" || return 1
  printf -v "${output_variable}" '%s' "${value}"
}

_cntools_action_pool_list_id_resolve() {
  local pool_directory="${1:-}" cold_key="" hex_cache="" bech32_cache=""
  local derived_hex="" derived_bech32=""

  cold_key="${pool_directory}/${POOL_COLDKEY_VK_FILENAME}"
  hex_cache="${pool_directory}/${POOL_ID_FILENAME}"
  bech32_cache="${pool_directory}/${POOL_ID_FILENAME}-bech32"
  pool_id=""
  pool_id_bech32=""
  if _cntools_action_pool_list_id_read "${hex_cache}" hex pool_id &&
     _cntools_action_pool_list_id_read \
       "${bech32_cache}" bech32 pool_id_bech32; then
    return 0
  fi
  _cntools_action_pool_list_file_validate \
    "${cold_key}" '400,444,600,644' 65536 ||
    return 1
  if [[ -z "${pool_list_ccli_path}" ]]; then
    pool_list_ccli_path="$(builtin type -P "${CCLI:-}" 2>/dev/null)" ||
      return 1
    [[ "${pool_list_ccli_path}" == /* &&
       -x "${pool_list_ccli_path}" ]] || return 1
  fi
  println ACTION 'cardano-cli pool-list ID derivation'
  derived_hex="$("${pool_list_ccli_path}" latest stake-pool id \
    --cold-verification-key-file "${cold_key}" --output-format hex \
    2>/dev/null)" || return 1
  derived_bech32="$("${pool_list_ccli_path}" latest stake-pool id \
    --cold-verification-key-file "${cold_key}" 2>/dev/null)" || return 1
  _cntools_action_pool_list_pool_id_valid hex "${derived_hex}" || return 1
  _cntools_action_pool_list_pool_id_valid bech32 "${derived_bech32}" ||
    return 1
  pool_id="${derived_hex}"
  pool_id_bech32="${derived_bech32}"
}

_cntools_action_pool_list_private_file_create() {
  local output_variable="${1:-}" created=""

  [[ "${output_variable}" == response_file ]] || return 1
  created="$(${pool_list_mktemp_path} \
    "${pool_list_private_parent}/pool-list-response.XXXXXXXX")" || return 1
  pool_list_temp_files+=("${created}")
  "${pool_list_chmod_path}" 0600 "${created}" || return 1
  printf -v "${output_variable}" '%s' "${created}"
}

_cntools_action_pool_list_koios_query() {
  local response_file="" payload="" metadata="" owner="" mode=""
  local links="" size="" parse_status=0
  local -a command_arguments=()

  pool_list_status=""
  pool_list_retiring_epoch=0
  _cntools_action_pool_list_private_file_create response_file || return 70
  payload="$(${pool_list_jq_path} -nc --arg id "${pool_id_bech32}" \
    '{_pool_bech32_ids:[$id]}')" || return 70
  command_arguments=(
    "${pool_list_curl_path}"
    --disable
    --silent
    --show-error
    --location
    --max-redirs 3
    --proto '=https'
    --proto-redir '=https'
    --connect-timeout "${pool_list_curl_timeout}"
    --max-time "${pool_list_curl_timeout}"
    --fail
    --max-filesize 262144
    "${pool_list_koios_headers[@]}"
    --header 'Content-Type: application/json'
    --data "${payload}"
    --output "${response_file}"
    --url "${pool_list_koios_api}/pool_info"
  )
  println ACTION 'curl [configured headers redacted] CNTools pool-list query'
  "${command_arguments[@]}" 2>/dev/null || return 1
  metadata="$(_cntools_result_stat "${response_file}")" || return 70
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 70
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == 600 &&
     "${links}" == 1 && "${size}" =~ ^[0-9]+$ &&
     "${size}" -ge 1 && "${size}" -le 262144 ]] || return 1
  "${pool_list_jq_path}" -e --arg id "${pool_id_bech32}" '
    type == "array" and length <= 1 and
    all(.[];
      type == "object" and
      (.pool_id_bech32 == $id) and
      (.pool_status | type == "string" and
        (. == "registered" or . == "retiring" or . == "retired")) and
      (if .pool_status == "registered" then
         .retiring_epoch == null
       else
         (.retiring_epoch | type == "number" and floor == . and
          . >= 0 and . <= 2147483647)
       end)
    )
  ' "${response_file}" >/dev/null 2>&1 || return 1
  if [[ "$("${pool_list_jq_path}" -er 'length' "${response_file}")" == 0 ]]; then
    pool_list_status=unregistered
    return 0
  fi
  IFS=$'\t' read -r pool_list_status pool_list_retiring_epoch < <(
    "${pool_list_jq_path}" -er \
      '.[0] | [.pool_status, (.retiring_epoch // 0)] | @tsv' \
      "${response_file}"
  ) || parse_status=$?
  [[ "${parse_status}" == 0 ]] || return 1
  case "${pool_list_status}" in
    registered) pool_list_retiring_epoch=0 ;;
    retiring|retired)
      [[ "${pool_list_retiring_epoch}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${pool_list_retiring_epoch}" -le 2147483647 ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_pool_list_registration_status() {
  local pool_directory="${1:-}"
  local registration_file="${pool_directory}/${POOL_REGCERT_FILENAME}"

  pool_list_status=""
  pool_list_retiring_epoch=0
  if [[ "${pool_list_context_mode}" == light ]]; then
    _cntools_action_pool_list_koios_query
    return $?
  fi
  if [[ -e "${registration_file}" || -L "${registration_file}" ]]; then
    _cntools_action_pool_list_file_validate \
      "${registration_file}" '400,444,600,644' 1048576 || return 70
    pool_list_status=registered
  else
    pool_list_status=unregistered
  fi
  return 0
}

_cntools_action_pool_list_kes_start() {
  local target="${1:-}" value=""

  _cntools_action_pool_list_file_validate \
    "${target}" '400,444,600,644' 64 ||
    return 1
  value="$(< "${target}")"
  [[ "${value}" =~ ^(0|[1-9][0-9]{0,18})$ ]] || return 1
  printf '%s\n' "${value}"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local context_mode="" context_network="" pool_root_physical=""
  local pool="" pool_physical=""
  local pool_name="" pool_registered="" pool_kes_start=""
  local current_epoch=0 encrypted="N" query_status=0 action_status=0
  local header_index=0 header_value="" network_magic=""
  local pool_list_context_mode="" pool_list_private_parent=""
  local pool_list_curl_timeout="" pool_list_koios_api=""
  local pool_list_status="" pool_list_retiring_epoch=0
  local pool_list_jq_path="" pool_list_curl_path=""
  local pool_list_mktemp_path="" pool_list_chmod_path=""
  local pool_list_rm_path="" pool_list_find_path="" pool_list_sort_path=""
  local pool_list_ccli_path=""
  local pool_id="" pool_id_bech32=""
  local -a pool_directories=() pool_list_temp_files=()
  local -a pool_list_koios_headers=()

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
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getEpoch >/dev/null 2>&1 ||
     ! builtin declare -F kesExpiration >/dev/null 2>&1 ||
     ! builtin declare -F timeLeft >/dev/null 2>&1; then
    _cntools_action_pool_list_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  pool_list_context_mode="${context_mode}"
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  for tool in find sort; do
    case "${tool}" in
      find) _cntools_registry_tool_path find pool_list_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort pool_list_sort_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  pool_list_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${pool_list_private_parent}" || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  [[ "${POOL_FOLDER}" == /* && -d "${POOL_FOLDER}" &&
     ! -L "${POOL_FOLDER}" ]] || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  _cntools_registry_path_has_no_symlinks "${POOL_FOLDER}" || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  pool_root_physical="$(cd -P -- "${POOL_FOLDER}" >/dev/null 2>&1 && pwd -P)" || {
    _cntools_action_pool_list_validation_failure
    return 70
  }
  for filename in "${POOL_ID_FILENAME}" "${POOL_COLDKEY_VK_FILENAME}" \
      "${POOL_REGCERT_FILENAME}" "${POOL_CURRENT_KES_START}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9._-]{1,128}$ &&
       "${filename}" != . && "${filename}" != .. ]] || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
  done
  case "${NETWORK_IDENTIFIER}" in
    --mainnet)
      [[ "${context_network}" == mainnet ]] || {
        _cntools_action_pool_list_validation_failure
        return 70
      }
      ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 &&
         "${context_network}" != mainnet ]] || {
        _cntools_action_pool_list_validation_failure
        return 70
      }
      ;;
    *)
      _cntools_action_pool_list_validation_failure
      return 70
      ;;
  esac
  while IFS= read -r -d '' pool; do
    pool_name="${pool##*/}"
    [[ "${pool_name}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
       "${pool_name}" != . && "${pool_name}" != .. ]] || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    pool_physical="$(cd -P -- "${pool}" >/dev/null 2>&1 && pwd -P)" || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    [[ "${pool_physical}" == "${pool_root_physical}/${pool_name}" ]] || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    _cntools_registry_path_has_no_symlinks "${pool_physical}" || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    pool_directories+=("${pool_physical}")
    [[ "${#pool_directories[@]}" -le 1000 ]] || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
  done < <("${pool_list_find_path}" "${pool_root_physical}" \
    -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C \
    "${pool_list_sort_path}" -z)

  if [[ "${context_mode}" == light ]]; then
    for tool in jq curl mktemp chmod rm; do
      case "${tool}" in
        jq) _cntools_registry_tool_path jq pool_list_jq_path || action_status=70 ;;
        curl) _cntools_registry_tool_path curl pool_list_curl_path || action_status=70 ;;
        mktemp) _cntools_registry_tool_path mktemp pool_list_mktemp_path || action_status=70 ;;
        chmod) _cntools_registry_tool_path chmod pool_list_chmod_path || action_status=70 ;;
        rm) _cntools_registry_tool_path rm pool_list_rm_path || action_status=70 ;;
      esac
    done
    [[ "${action_status}" == 0 ]] || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    pool_list_curl_timeout="${CURL_TIMEOUT:-10}"
    [[ "${pool_list_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    pool_list_koios_api="${KOIOS_API%/}"
    [[ "${#pool_list_koios_api}" -ge 9 &&
       "${#pool_list_koios_api}" -le 2048 &&
       "${pool_list_koios_api}" == https://* &&
       "${pool_list_koios_api}" != *'?'* &&
       "${pool_list_koios_api}" != *'#'* &&
       "${pool_list_koios_api}" != *\\* &&
       ! "${pool_list_koios_api}" =~ [[:cntrl:][:space:]] ]] || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    pool_list_koios_headers=("${KOIOS_API_HEADERS[@]}")
    (( ${#pool_list_koios_headers[@]} % 2 == 0 &&
       ${#pool_list_koios_headers[@]} <= 8 )) || {
      _cntools_action_pool_list_validation_failure
      return 70
    }
    for ((header_index=0; header_index<${#pool_list_koios_headers[@]};
        header_index+=2)); do
      header_value="${pool_list_koios_headers[header_index+1]}"
      [[ ( "${pool_list_koios_headers[header_index]}" == -H ||
           "${pool_list_koios_headers[header_index]}" == --header ) &&
         "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
         "${header_value}" == *:* && "${header_value}" != *$'\r'* &&
         "${header_value}" != *$'\n'* ]] || {
        _cntools_action_pool_list_validation_failure
        return 70
      }
    done
  fi

  umask 077
  trap '_cntools_action_pool_list_cleanup' EXIT
  trap '_cntools_action_pool_list_cleanup; exit 70' HUP INT TERM
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> POOL >> LIST'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  if (( ${#pool_directories[@]} == 0 )); then
    echo
    println "${FG_YELLOW}No pools available!${NC}"
    waitToProceed
    _cntools_action_pool_list_cleanup || {
      trap - EXIT HUP INT TERM
      _cntools_action_pool_list_validation_failure
      return 70
    }
    trap - EXIT HUP INT TERM
    return 0
  fi
  current_epoch="$(getEpoch)" || current_epoch=""
  [[ "${current_epoch}" =~ ^(0|[1-9][0-9]{0,9})$ &&
     "${current_epoch}" -le 2147483647 ]] || {
    _cntools_action_pool_list_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_pool_list_validation_failure
    return 70
  }
  for pool in "${pool_directories[@]}"; do
    echo
    pool_name="${pool##*/}"
    if ! _cntools_action_pool_list_id_resolve "${pool}"; then
      println ERROR 'ERROR: pool identity is unavailable or invalid.'
      waitToProceed
      continue
    fi
    query_status=0
    _cntools_action_pool_list_registration_status "${pool}" || query_status=$?
    case "${query_status}" in
      0) ;;
      1)
        println ERROR 'KOIOS_API ERROR: pool information is unavailable or invalid.'
        waitToProceed
        continue
        ;;
      *)
        _cntools_action_pool_list_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_pool_list_validation_failure
        return 70
        ;;
    esac
    case "${pool_list_status}" in
      unregistered) pool_registered="${FG_RED}No${NC}" ;;
      registered) pool_registered="${FG_GREEN}Yes${NC}" ;;
      retiring)
        if [[ "${current_epoch}" -lt "${pool_list_retiring_epoch}" ]]; then
          pool_registered="${FG_YELLOW}Yes${NC} - Retiring in epoch ${FG_LBLUE}${pool_list_retiring_epoch}${NC}"
        else
          pool_registered="${FG_RED}No${NC} - Retired in epoch ${FG_LBLUE}${pool_list_retiring_epoch}${NC}"
        fi
        ;;
      retired)
        pool_registered="${FG_RED}No${NC} - Retired in epoch ${FG_LBLUE}${pool_list_retiring_epoch}${NC}"
        ;;
      *)
        _cntools_action_pool_list_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_pool_list_validation_failure
        return 70
        ;;
    esac
    encrypted=N
    if [[ -n "$("${pool_list_find_path}" "${pool}" -mindepth 1 \
        -maxdepth 1 -type f -name '*.gpg' -print -quit 2>/dev/null)" ]]; then
      encrypted=Y
    fi
    if [[ "${encrypted}" == Y ]]; then
      println "${FG_GREEN}${pool_name}${NC} (${FG_YELLOW}encrypted${NC})"
    else
      println "${FG_GREEN}${pool_name}${NC}"
    fi
    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" \
      'ID (hex)' "${pool_id}")"
    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" \
      'ID (bech32)' "${pool_id_bech32}")"
    println "$(printf '%-21s : %s' 'Registered' "${pool_registered}")"
    if [[ "${pool_list_status}" == registered ||
          "${pool_list_status}" == retiring ]]; then
      pool_kes_start="$(_cntools_action_pool_list_kes_start \
        "${pool}/${POOL_CURRENT_KES_START}")" || pool_kes_start=""
      unset remaining_kes_periods
      if [[ -z "${pool_kes_start}" ]] ||
         ! kesExpiration "${pool_kes_start}"; then
        println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC}%s${FG_GREEN}%s${NC}" \
          'KES expiration date' 'ERROR' \
          ': failure during KES calculation for ' "${pool_name}")"
      elif [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
        if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
          println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s ago" \
            'KES expiration date' "${kes_expiration}" 'EXPIRED!' \
            "$(timeLeft "${expiration_time_sec_diff:1}")")"
        else
          println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s until expiration" \
            'KES expiration date' "${kes_expiration}" 'ALERT!' \
            "$(timeLeft "${expiration_time_sec_diff}")")"
        fi
      elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
        println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_YELLOW}%s${NC} %s until expiration" \
          'KES expiration date' "${kes_expiration}" 'WARNING!' \
          "$(timeLeft "${expiration_time_sec_diff}")")"
      else
        println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" 'KES expiration date' \
          "${kes_expiration}")"
      fi
    fi
  done
  echo
  waitToProceed
  _cntools_action_pool_list_cleanup || {
    trap - EXIT HUP INT TERM
    _cntools_action_pool_list_validation_failure
    return 70
  }
  trap - EXIT HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
