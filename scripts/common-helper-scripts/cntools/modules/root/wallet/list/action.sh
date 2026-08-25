#!/usr/bin/env bash
# shellcheck disable=SC2154
# Stage 4 compatibility action for the characterized legacy wallet listing.
# Sourcing defines functions only; the dispatcher supplies the authenticated
# context plus inherited legacy display, price, wallet, and local-query helpers.

_cntools_action_wallet_list_validation_failure() {
  builtin printf '%s\n' \
    'CNTools wallet-list action failed validation.' >&2
  return 70
}

_cntools_action_wallet_list_cleanup() {
  local cleanup_target=""
  local cleanup_failed=0

  if [[ "${wallet_list_terminal_saved:-N}" == "Y" ]]; then
    tput rc >/dev/null 2>&1 || cleanup_failed=1
    tput ed >/dev/null 2>&1 || cleanup_failed=1
    wallet_list_terminal_saved="N"
  fi
  for cleanup_target in "${wallet_list_temp_files[@]:-}"; do
    [[ -n "${cleanup_target}" ]] || continue
    if [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
      "${wallet_list_rm_path}" -f -- "${cleanup_target}" \
        >/dev/null 2>&1 || cleanup_failed=1
    fi
  done
  wallet_list_temp_files=()
  return "${cleanup_failed}"
}

_cntools_action_wallet_list_file_validate() {
  local target="${1:-}" expected_modes="${2:-}" maximum_size="${3:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -f "${target}" && ! -L "${target}" &&
     "${maximum_size}" =~ ^[1-9][0-9]*$ ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == "1" &&
     "${size}" =~ ^[0-9]+$ && "${size}" -ge 1 &&
     "${size}" -le "${maximum_size}" &&
     ",${expected_modes}," == *",${mode},"* ]]
}

_cntools_action_wallet_list_address_valid() {
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

_cntools_action_wallet_list_input_usable() {
  local target="${1:-}"

  _cntools_action_wallet_list_file_validate "${target}" "400,600" 65536
}

_cntools_action_wallet_list_cache_read() {
  local target="${1:-}" kind="${2:-}" output_variable="${3:-}"
  local value=""

  case "${output_variable}" in
    base_addr|pay_addr|reward_addr) ;;
    *) return 1 ;;
  esac
  _cntools_action_wallet_list_file_validate "${target}" 600 512 || return 1
  value="$(< "${target}")"
  _cntools_action_wallet_list_address_valid "${kind}" "${value}" || return 1
  printf -v "${output_variable}" '%s' "${value}"
}

_cntools_action_wallet_list_cache_create() {
  local wallet_directory="${1:-}" kind="${2:-}"
  local target="${3:-}" output_variable="${4:-}"
  local payment_vkey="${wallet_directory}/${WALLET_PAY_VK_FILENAME}"
  local payment_script="${wallet_directory}/${WALLET_PAY_SCRIPT_FILENAME}"
  local stake_vkey="${wallet_directory}/${WALLET_STAKE_VK_FILENAME}"
  local stake_script="${wallet_directory}/${WALLET_STAKE_SCRIPT_FILENAME}"
  local temporary="" value=""
  local -a command_arguments=()

  [[ ! -e "${target}" && ! -L "${target}" ]] ||
    _cntools_action_wallet_list_cache_read \
      "${target}" "${kind}" "${output_variable}"
  temporary="$(${wallet_list_mktemp_path} \
    "${wallet_directory}/.cntools-wallet-list.${kind}.XXXXXXXX")" || return 1
  wallet_list_temp_files+=("${temporary}")
  "${wallet_list_chmod_path}" 0600 "${temporary}" || return 1

  case "${kind}" in
    base)
      if _cntools_action_wallet_list_input_usable "${payment_vkey}" &&
         _cntools_action_wallet_list_input_usable "${stake_vkey}"; then
        command_arguments=(address build
          --payment-verification-key-file "${payment_vkey}"
          --stake-verification-key-file "${stake_vkey}")
      elif _cntools_action_wallet_list_input_usable "${payment_script}" &&
           _cntools_action_wallet_list_input_usable "${stake_script}"; then
        command_arguments=(address build
          --payment-script-file "${payment_script}"
          --stake-script-file "${stake_script}")
      elif _cntools_action_wallet_list_input_usable "${payment_script}" &&
           _cntools_action_wallet_list_input_usable "${stake_vkey}"; then
        command_arguments=(address build
          --payment-script-file "${payment_script}"
          --stake-verification-key-file "${stake_vkey}")
      elif _cntools_action_wallet_list_input_usable "${payment_vkey}" &&
           _cntools_action_wallet_list_input_usable "${stake_script}"; then
        command_arguments=(address build
          --payment-verification-key-file "${payment_vkey}"
          --stake-script-file "${stake_script}")
      else
        return 1
      fi
      ;;
    payment)
      if _cntools_action_wallet_list_input_usable "${payment_vkey}"; then
        command_arguments=(address build
          --payment-verification-key-file "${payment_vkey}")
      elif _cntools_action_wallet_list_input_usable "${payment_script}"; then
        command_arguments=(address build
          --payment-script-file "${payment_script}")
      else
        return 1
      fi
      ;;
    reward)
      if _cntools_action_wallet_list_input_usable "${stake_vkey}"; then
        command_arguments=(latest stake-address build
          --stake-verification-key-file "${stake_vkey}")
      elif _cntools_action_wallet_list_input_usable "${stake_script}"; then
        command_arguments=(latest stake-address build
          --stake-script-file "${stake_script}")
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  command_arguments+=(--out-file "${temporary}" "${wallet_list_network_args[@]}")
  println ACTION "cardano-cli wallet-list address-cache generation"
  "${wallet_list_ccli_path}" "${command_arguments[@]}" \
    >/dev/null 2>&1 || return 1
  "${wallet_list_chmod_path}" 0600 "${temporary}" || return 1
  _cntools_action_wallet_list_file_validate "${temporary}" 600 512 || return 1
  value="$(< "${temporary}")"
  _cntools_action_wallet_list_address_valid "${kind}" "${value}" || return 1

  if ! "${wallet_list_ln_path}" -- "${temporary}" "${target}" \
      >/dev/null 2>&1; then
    _cntools_action_wallet_list_cache_read \
      "${target}" "${kind}" "${output_variable}" && return 0
    return 1
  fi
  "${wallet_list_rm_path}" -f -- "${temporary}" >/dev/null 2>&1 || return 1
  _cntools_action_wallet_list_cache_read \
    "${target}" "${kind}" "${output_variable}"
}

_cntools_action_wallet_list_address_resolve() {
  local wallet_directory="${1:-}" kind="${2:-}"
  local output_variable="${3:-}" filename="" target=""

  case "${kind}:${output_variable}" in
    base:base_addr) filename="${WALLET_BASE_ADDR_FILENAME}" ;;
    payment:pay_addr) filename="${WALLET_PAY_ADDR_FILENAME}" ;;
    reward:reward_addr) filename="${WALLET_STAKE_ADDR_FILENAME}" ;;
    *) return 1 ;;
  esac
  target="${wallet_directory}/${filename}"
  printf -v "${output_variable}" '%s' ""
  if [[ -e "${target}" || -L "${target}" ]]; then
    _cntools_action_wallet_list_cache_read \
      "${target}" "${kind}" "${output_variable}"
  else
    _cntools_action_wallet_list_cache_create \
      "${wallet_directory}" "${kind}" "${target}" "${output_variable}"
  fi
}

_cntools_action_wallet_list_private_file_create() {
  local label="${1:-}" output_variable="${2:-}" created=""

  [[ "${label}" == "address" || "${label}" == "reward" ]] || return 1
  [[ "${output_variable}" == "fetched_file" ]] || return 1
  created="$(${wallet_list_mktemp_path} \
    "${wallet_list_private_parent}/wallet-list-${label}.XXXXXXXX")" || return 1
  wallet_list_temp_files+=("${created}")
  "${wallet_list_chmod_path}" 0600 "${created}" || return 1
  printf -v "${output_variable}" '%s' "${created}"
}

_cntools_action_wallet_list_fetch() {
  local response_kind="${1:-}" payload="${2:-}"
  local output_variable="${3:-}" fetched_file="" endpoint="" limit=""
  local metadata="" owner="" mode="" links="" size=""
  local -a curl_command=()

  case "${response_kind}" in
    address)
      endpoint='address_utxos?select=address,tx_hash,tx_index,value,asset_list'
      limit=8388608
      ;;
    reward)
      endpoint='account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit'
      limit=1048576
      ;;
    *) return 70 ;;
  esac
  _cntools_action_wallet_list_private_file_create \
    "${response_kind}" fetched_file || return 70
  curl_command=(
    "${wallet_list_curl_path}"
    --disable
    --silent
    --show-error
    --location
    --max-redirs 3
    --proto '=https'
    --proto-redir '=https'
    --connect-timeout "${wallet_list_curl_timeout}"
    --max-time "${wallet_list_curl_timeout}"
    --fail
    --max-filesize "${limit}"
    "${wallet_list_koios_headers[@]}"
    --header 'Content-Type: application/json'
    --header 'accept: text/csv'
    --data "${payload}"
    --output "${fetched_file}"
    --url "${wallet_list_koios_api}/${endpoint}"
  )
  println ACTION 'curl [configured headers redacted] CNTools wallet-list query'
  "${curl_command[@]}" 2>/dev/null || return 1
  metadata="$(_cntools_result_stat "${fetched_file}")" || return 70
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 70
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == 600 &&
     "${links}" == 1 && "${size}" =~ ^[0-9]+$ &&
     "${size}" -ge 1 && "${size}" -le "${limit}" ]] || return 1
  printf -v "${output_variable}" '%s' "${fetched_file}"
}

_cntools_action_wallet_list_integer_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${value}" -le 45000000000000000 ]]
}

_cntools_action_wallet_list_address_response_parse() {
  local response_file="${1:-}" header="" row=""
  local address="" tx_hash="" tx_index="" value="" asset_csv=""
  local asset_json="" policy_id="" asset_name="" quantity=""
  local utxo_key="" index_prefix="" asset_count=0

  exec 8< "${response_file}" || return 70
  IFS= read -r header <&8 || { exec 8<&-; return 1; }
  [[ "${header}" == \
    'address,tx_hash,tx_index,value,asset_list' ]] || {
      exec 8<&-
      return 1
    }
  while IFS= read -r row <&8 || [[ -n "${row}" ]]; do
    wallet_list_address_row_count=$((wallet_list_address_row_count + 1))
    [[ "${wallet_list_address_row_count}" -le 50000 ]] || {
      exec 8<&-
      return 1
    }
    IFS=',' read -r address tx_hash tx_index value asset_csv <<< "${row}"
    [[ -n "${wallet_list_requested_addresses[${address}]+set}" &&
       "${tx_hash}" =~ ^[0-9A-Fa-f]{64}$ &&
       "${tx_index}" =~ ^(0|[1-9][0-9]{0,4})$ &&
       "${tx_index}" -le 65535 ]] || { exec 8<&-; return 1; }
    _cntools_action_wallet_list_integer_valid "${value}" || {
      exec 8<&-
      return 1
    }
    utxo_key="${address},${tx_hash}#${tx_index}"
    [[ -z "${wallet_list_seen_utxos[${utxo_key}]+set}" ]] || {
      exec 8<&-
      return 1
    }
    wallet_list_seen_utxos["${utxo_key}"]=1
    [[ "${asset_csv}" == \"*\" && "${#asset_csv}" -ge 2 ]] || {
      exec 8<&-
      return 1
    }
    asset_json="${asset_csv:1:${#asset_csv}-2}"
    asset_json="${asset_json//\"\"/\"}"
    "${wallet_list_jq_path}" -e '
      type == "array" and length <= 1000 and all(.[];
        type == "object" and keys == ["asset_name", "policy_id", "quantity"] and
        (.policy_id | type == "string" and test("^[0-9A-Fa-f]{56}$")) and
        (.asset_name | type == "string" and test("^([0-9A-Fa-f]{2}){0,32}$")) and
        (.quantity | type == "number" and floor == . and
          . >= 0 and . <= 45000000000000000))
    ' <<< "${asset_json}" >/dev/null 2>&1 || { exec 8<&-; return 1; }
    asset_count="$(${wallet_list_jq_path} -er 'length' \
      <<< "${asset_json}" 2>/dev/null)" || { exec 8<&-; return 70; }
    wallet_list_asset_row_count=$((wallet_list_asset_row_count + asset_count))
    [[ "${wallet_list_asset_row_count}" -le 100000 ]] || {
      exec 8<&-
      return 1
    }
    index_prefix="${address},"
    wallet_list_assets["${index_prefix}lovelace"]=$((
      ${wallet_list_assets["${index_prefix}lovelace"]:-0} + value
    ))
    while IFS=$'\t' read -r policy_id asset_name quantity; do
      [[ -n "${policy_id}" ]] || continue
      wallet_list_assets["${index_prefix}${policy_id}.${asset_name}"]="${quantity}"
    done < <("${wallet_list_jq_path}" -er \
      '.[] | [.policy_id, .asset_name, (.quantity | tostring)] | @tsv' \
      <<< "${asset_json}" 2>/dev/null)
  done
  exec 8<&-
}

_cntools_action_wallet_list_reward_response_parse() {
  local response_file="${1:-}" header="" row=""
  local stake_address="" status="" delegated_pool="" delegated_drep=""
  local rewards="" deposit=""

  exec 8< "${response_file}" || return 70
  IFS= read -r header <&8 || { exec 8<&-; return 1; }
  [[ "${header}" == \
    'stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit' ]] || {
      exec 8<&-
      return 1
    }
  while IFS= read -r row <&8 || [[ -n "${row}" ]]; do
    wallet_list_reward_row_count=$((wallet_list_reward_row_count + 1))
    [[ "${wallet_list_reward_row_count}" -le 1000 ]] || {
      exec 8<&-
      return 1
    }
    IFS=',' read -r stake_address status delegated_pool delegated_drep \
      rewards deposit <<< "${row}"
    [[ -n "${wallet_list_requested_rewards[${stake_address}]+set}" &&
       -z "${wallet_list_seen_rewards[${stake_address}]+set}" &&
       ( "${status}" == registered || "${status}" == 'not registered' ) &&
       "${#delegated_drep}" -le 256 &&
       "${delegated_drep}" =~ ^[A-Za-z0-9_]*$ &&
       "${deposit}" != *,* ]] || { exec 8<&-; return 1; }
    if [[ -n "${delegated_pool}" ]] &&
       [[ ! "${delegated_pool}" =~ ^pool1[023456789ac-hj-np-z]{20,100}$ ]]; then
      exec 8<&-
      return 1
    fi
    _cntools_action_wallet_list_integer_valid "${rewards}" &&
      _cntools_action_wallet_list_integer_valid "${deposit}" || {
        exec 8<&-
        return 1
      }
    wallet_list_seen_rewards["${stake_address}"]=1
    wallet_list_reward_status["${stake_address}"]="${status}"
    wallet_list_rewards["${stake_address}"]="${rewards}"
    if [[ -n "${delegated_pool}" ]]; then
      wallet_list_pool_delegations["${stake_address}"]="${delegated_pool}"
    fi
  done
  exec 8<&-
}

_cntools_action_wallet_list_query_batch() {
  local response_kind="${1:-}"
  shift || return 70
  local joined="" payload="" response_file="" query_status=0

  (( $# > 0 )) || return 0
  printf -v joined '\"%s\",' "$@"
  case "${response_kind}" in
    address)
      payload='{"_addresses":['${joined%,}'],"_extended":true}'
      ;;
    reward)
      payload='{"_stake_addresses":['${joined%,}']}'
      ;;
    *) return 70 ;;
  esac
  if _cntools_action_wallet_list_fetch \
      "${response_kind}" "${payload}" response_file; then
    query_status=0
  else
    query_status=$?
  fi
  if [[ "${query_status}" == 0 ]]; then
    if [[ "${response_kind}" == address ]]; then
      _cntools_action_wallet_list_address_response_parse "${response_file}" ||
        query_status=$?
    else
      _cntools_action_wallet_list_reward_response_parse "${response_file}" ||
        query_status=$?
    fi
  fi
  "${wallet_list_rm_path}" -f -- "${response_file}" >/dev/null 2>&1 ||
    return 70
  return "${query_status}"
}

_cntools_action_wallet_list_query_all() {
  local response_kind="${1:-}" source_name="${2:-}"
  local address="" joined="" payload="" query_status=0
  local -a batch=() candidate=()
  local -n source_addresses="${source_name}"

  for address in "${source_addresses[@]}"; do
    candidate=("${batch[@]}" "${address}")
    printf -v joined '\"%s\",' "${candidate[@]}"
    if [[ "${response_kind}" == address ]]; then
      payload='{"_addresses":['${joined%,}'],"_extended":true}'
    else
      payload='{"_stake_addresses":['${joined%,}']}'
    fi
    if [[ "${#payload}" -gt 1024 && "${#batch[@]}" -gt 0 ]]; then
      _cntools_action_wallet_list_query_batch \
        "${response_kind}" "${batch[@]}" || return $?
      batch=("${address}")
    else
      batch=("${candidate[@]}")
    fi
  done
  if (( ${#batch[@]} > 0 )); then
    _cntools_action_wallet_list_query_batch \
      "${response_kind}" "${batch[@]}" || query_status=$?
  fi
  return "${query_status}"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local context_mode="" context_network="" wallet_root_physical=""
  local wallet="" wallet_physical="" wallet_name="" pool=""
  local base_addr="" pay_addr="" reward_addr="" pool_name=""
  local registered="no" encrypted="no" wallet_type=4
  local lovelace=0 asset_cnt=0 reward_lovelace=0 pool_delegation=""
  local key="" query_status=0 use_koios="N" local_available="N"
  local header_index=0 header_value="" action_status=0
  local wallet_list_private_parent="" wallet_list_curl_timeout=""
  local wallet_list_koios_api="" wallet_list_terminal_saved="N"
  local wallet_list_address_row_count=0 wallet_list_asset_row_count=0
  local wallet_list_reward_row_count=0
  local wallet_list_jq_path="" wallet_list_curl_path=""
  local wallet_list_mktemp_path="" wallet_list_chmod_path=""
  local wallet_list_rm_path="" wallet_list_ln_path=""
  local wallet_list_find_path="" wallet_list_sort_path=""
  local wallet_list_ccli_path=""
  local -a wallet_directories=() address_list=() reward_address_list=()
  local -a wallet_list_temp_files=() wallet_list_koios_headers=()
  local -a wallet_list_network_args=()
  local -A wallet_base_addresses=() wallet_pay_addresses=()
  local -A wallet_reward_addresses=() seen_addresses=() seen_rewards=()
  local -A wallet_list_requested_addresses=()
  local -A wallet_list_requested_rewards=() wallet_list_seen_utxos=()
  local -A wallet_list_seen_rewards=() wallet_list_assets=()
  local -A wallet_list_rewards=() wallet_list_reward_status=()
  local -A wallet_list_pool_delegations=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F cntools_context_has >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate \
       >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getPriceInfo >/dev/null 2>&1 ||
     ! builtin declare -F getPriceString >/dev/null 2>&1 ||
     ! builtin declare -F formatLovelace >/dev/null 2>&1 ||
     ! builtin declare -F getWalletType >/dev/null 2>&1 ||
     ! builtin declare -F getBalance >/dev/null 2>&1 ||
     ! builtin declare -F getRewardsFromAddr >/dev/null 2>&1 ||
     ! builtin declare -F getPoolID >/dev/null 2>&1; then
    _cntools_action_wallet_list_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  if cntools_context_has "${context_file}" capabilities local-cli; then
    local_available="Y"
  fi
  for tool in jq mktemp chmod rm ln find sort; do
    case "${tool}" in
      jq) _cntools_registry_tool_path jq wallet_list_jq_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp wallet_list_mktemp_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod wallet_list_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_list_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln wallet_list_ln_path || action_status=70 ;;
      find) _cntools_registry_tool_path find wallet_list_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort wallet_list_sort_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  wallet_list_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${wallet_list_private_parent}" || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  [[ "${WALLET_FOLDER}" == /* && -d "${WALLET_FOLDER}" &&
     ! -L "${WALLET_FOLDER}" ]] || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  _cntools_registry_path_has_no_symlinks "${WALLET_FOLDER}" || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  wallet_root_physical="$(cd -P -- "${WALLET_FOLDER}" \
    >/dev/null 2>&1 && pwd -P)" || {
      _cntools_action_wallet_list_validation_failure
      return 70
    }
  for filename in "${WALLET_PAY_VK_FILENAME}" \
      "${WALLET_STAKE_VK_FILENAME}" "${WALLET_PAY_SCRIPT_FILENAME}" \
      "${WALLET_STAKE_SCRIPT_FILENAME}" "${WALLET_PAY_ADDR_FILENAME}" \
      "${WALLET_BASE_ADDR_FILENAME}" "${WALLET_STAKE_ADDR_FILENAME}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9._-]{1,128}$ &&
       "${filename}" != . && "${filename}" != .. ]] || {
      _cntools_action_wallet_list_validation_failure
      return 70
    }
  done
  case "${NETWORK_IDENTIFIER}" in
    --mainnet) wallet_list_network_args=(--mainnet) ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 ]] || {
        _cntools_action_wallet_list_validation_failure
        return 70
      }
      wallet_list_network_args=(--testnet-magic "${network_magic}")
      ;;
    *)
      _cntools_action_wallet_list_validation_failure
      return 70
      ;;
  esac
  if [[ "${context_network}" == mainnet &&
        "${wallet_list_network_args[0]}" != --mainnet ]] ||
     [[ "${context_network}" != mainnet &&
        "${wallet_list_network_args[0]}" != --testnet-magic ]]; then
    _cntools_action_wallet_list_validation_failure
    return 70
  fi
  wallet_list_ccli_path="$(builtin type -P "${CCLI:-}" 2>/dev/null)" || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  [[ "${wallet_list_ccli_path}" == /* && -x "${wallet_list_ccli_path}" ]] || {
    _cntools_action_wallet_list_validation_failure
    return 70
  }

  while IFS= read -r -d '' wallet; do
    wallet_name="${wallet##*/}"
    [[ "${wallet_name}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
       "${wallet_name}" != . && "${wallet_name}" != .. ]] || {
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    wallet_physical="$(cd -P -- "${wallet}" >/dev/null 2>&1 && pwd -P)" || {
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    [[ "${wallet_physical}" == "${wallet_root_physical}/${wallet_name}" ]] || {
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    _cntools_registry_path_has_no_symlinks "${wallet_physical}" || {
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    wallet_directories+=("${wallet_physical}")
    [[ "${#wallet_directories[@]}" -le 1000 ]] || {
      _cntools_action_wallet_list_validation_failure
      return 70
    }
  done < <("${wallet_list_find_path}" "${wallet_root_physical}" \
    -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C \
    "${wallet_list_sort_path}" -z)

  umask 077
  trap '_cntools_action_wallet_list_cleanup' EXIT
  trap '_cntools_action_wallet_list_cleanup; exit 70' HUP INT TERM

  clear
  [[ "${context_mode}" != offline ]] && getPriceInfo
  println DEBUG \
    "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> WALLET >> LIST"
  println DEBUG \
    "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  if (( ${#wallet_directories[@]} == 0 )); then
    echo
    println "${FG_YELLOW}No wallets available!${NC}"
    waitToProceed
    _cntools_action_wallet_list_cleanup || {
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    trap - EXIT HUP INT TERM
    return 0
  fi
  if [[ "${context_mode}" == offline ]]; then
    println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, wallet balance not shown!"
  fi

  for wallet in "${wallet_directories[@]}"; do
    wallet_name="${wallet##*/}"
    base_addr="" pay_addr="" reward_addr=""
    _cntools_action_wallet_list_address_resolve \
      "${wallet}" base base_addr || base_addr=""
    _cntools_action_wallet_list_address_resolve \
      "${wallet}" payment pay_addr || pay_addr=""
    _cntools_action_wallet_list_address_resolve \
      "${wallet}" reward reward_addr || reward_addr=""
    wallet_base_addresses["${wallet_name}"]="${base_addr}"
    wallet_pay_addresses["${wallet_name}"]="${pay_addr}"
    wallet_reward_addresses["${wallet_name}"]="${reward_addr}"
    if [[ -n "${base_addr}" && -z "${seen_addresses[${base_addr}]+set}" ]]; then
      seen_addresses["${base_addr}"]=1
      address_list+=("${base_addr}")
      wallet_list_requested_addresses["${base_addr}"]=1
    fi
    if [[ -n "${pay_addr}" && -z "${seen_addresses[${pay_addr}]+set}" ]]; then
      seen_addresses["${pay_addr}"]=1
      address_list+=("${pay_addr}")
      wallet_list_requested_addresses["${pay_addr}"]=1
    fi
    if [[ -n "${reward_addr}" && -z "${seen_rewards[${reward_addr}]+set}" ]]; then
      seen_rewards["${reward_addr}"]=1
      reward_address_list+=("${reward_addr}")
      wallet_list_requested_rewards["${reward_addr}"]=1
      wallet_list_reward_status["${reward_addr}"]='not registered'
      wallet_list_rewards["${reward_addr}"]=0
    fi
  done

  if [[ -n "${KOIOS_API:-}" && "${context_mode}" != offline ]]; then
    wallet_list_koios_api="${KOIOS_API%/}"
    [[ "${#wallet_list_koios_api}" -ge 9 &&
       "${#wallet_list_koios_api}" -le 2048 &&
       "${wallet_list_koios_api}" == https://* &&
       "${wallet_list_koios_api}" != *'?'* &&
       "${wallet_list_koios_api}" != *'#'* &&
       "${wallet_list_koios_api}" != *\\* &&
       ! "${wallet_list_koios_api}" =~ [[:cntrl:][:space:]] ]] || {
      _cntools_action_wallet_list_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    wallet_list_curl_timeout="${CURL_TIMEOUT:-10}"
    [[ "${wallet_list_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] || {
      _cntools_action_wallet_list_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    _cntools_registry_tool_path curl wallet_list_curl_path || {
      _cntools_action_wallet_list_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    wallet_list_koios_headers=("${KOIOS_API_HEADERS[@]}")
    (( ${#wallet_list_koios_headers[@]} % 2 == 0 &&
       ${#wallet_list_koios_headers[@]} <= 8 )) || {
      _cntools_action_wallet_list_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    for ((header_index=0; header_index<${#wallet_list_koios_headers[@]};
        header_index+=2)); do
      header_value="${wallet_list_koios_headers[header_index+1]}"
      [[ ( "${wallet_list_koios_headers[header_index]}" == -H ||
           "${wallet_list_koios_headers[header_index]}" == --header ) &&
         "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
         "${header_value}" == *:* && "${header_value}" != *$'\r'* &&
         "${header_value}" != *$'\n'* ]] || {
        _cntools_action_wallet_list_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_list_validation_failure
        return 70
      }
    done
    tput sc >/dev/null 2>&1 && wallet_list_terminal_saved="Y"
    println OFF "\n${FG_YELLOW}> Querying Koios API for wallet information${NC}"
    query_status=0
    if (( ${#address_list[@]} > 0 )); then
      _cntools_action_wallet_list_query_all address address_list ||
        query_status=$?
    fi
    if [[ "${query_status}" == 0 && ${#reward_address_list[@]} -gt 0 ]]; then
      _cntools_action_wallet_list_query_all reward reward_address_list ||
        query_status=$?
    fi
    if [[ "${wallet_list_terminal_saved}" == Y ]]; then
      tput rc >/dev/null 2>&1 || query_status=70
      tput ed >/dev/null 2>&1 || query_status=70
      wallet_list_terminal_saved="N"
    fi
    case "${query_status}" in
      0) use_koios="Y" ;;
      1)
        wallet_list_assets=()
        wallet_list_rewards=()
        wallet_list_reward_status=()
        wallet_list_pool_delegations=()
        if [[ "${context_mode}" == local && "${local_available}" == Y ]]; then
          println ERROR "\n${FG_YELLOW}WARN${NC}: Koios wallet query failed; using local node data."
          KOIOS_API=""
        else
          println ERROR "\n${FG_RED}ERROR${NC}: Koios wallet query failed; wallet balances are unavailable."
          waitToProceed
          _cntools_action_wallet_list_cleanup || {
            trap - EXIT HUP INT TERM
            _cntools_action_wallet_list_validation_failure
            return 70
          }
          trap - EXIT HUP INT TERM
          return 0
        fi
        ;;
      *)
        _cntools_action_wallet_list_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_list_validation_failure
        return 70
        ;;
    esac
  elif [[ "${context_mode}" == light ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Koios wallet query is unavailable; wallet balances are unavailable."
    waitToProceed
    _cntools_action_wallet_list_cleanup || {
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_list_validation_failure
      return 70
    }
    trap - EXIT HUP INT TERM
    return 0
  fi

  for wallet in "${wallet_directories[@]}"; do
    wallet_name="${wallet##*/}"
    base_addr="${wallet_base_addresses[${wallet_name}]}"
    pay_addr="${wallet_pay_addresses[${wallet_name}]}"
    reward_addr="${wallet_reward_addresses[${wallet_name}]}"
    registered="no" encrypted="no" reward_lovelace=0 pool_delegation=""
    if [[ -n "$("${wallet_list_find_path}" "${wallet}" -mindepth 1 \
        -maxdepth 1 -type f -name '*.gpg' -print -quit 2>/dev/null)" ]]; then
      encrypted="yes"
    fi
    if [[ "${context_mode}" != offline ]]; then
      if [[ "${use_koios}" == Y ]]; then
        [[ "${wallet_list_reward_status[${reward_addr}]:-}" == registered ]] &&
          registered="yes"
      elif [[ -n "${reward_addr}" ]]; then
        unset stake_address
        reward_lovelace=0
        pool_delegation=""
        if getRewardsFromAddr "${reward_addr}" &&
           [[ -n "${stake_address:-}" ]]; then
          registered="yes"
        fi
      fi
    fi
    echo
    if [[ "${registered}" == yes && "${encrypted}" == yes ]]; then
      println "${FG_GREEN}${wallet_name}${NC} - ${FG_LGRAY}REGISTERED${NC} (${FG_YELLOW}encrypted${NC})"
    elif [[ "${registered}" == yes ]]; then
      println "${FG_GREEN}${wallet_name}${NC} - ${FG_LGRAY}REGISTERED${NC}"
    elif [[ "${encrypted}" == yes ]]; then
      println "${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})"
    else
      println "${FG_GREEN}${wallet_name}${NC}"
    fi
    if getWalletType "${wallet_name}"; then
      wallet_type=0
    else
      wallet_type=$?
    fi
    case "${wallet_type}" in
      0) println "$(printf "%-15s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "Hardware")" ;;
      1|2) println "$(printf "%-15s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "CLI")" ;;
      5) println "$(printf "%-15s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" "Type" "MultiSig")" ;;
    esac
    if [[ -z "${base_addr}" && -z "${pay_addr}" ]]; then
      println ERROR "${FG_RED}ERROR${NC}: wallet missing pay/base addr files or vkey/script files to generate them!"
      continue
    fi
    if [[ "${context_mode}" == offline ]]; then
      [[ -n "${base_addr}" ]] && println \
        "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Address" "${base_addr}")"
      [[ -n "${pay_addr}" ]] && println \
        "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Payment Addr" "${pay_addr}")"
      continue
    fi
    if [[ -n "${base_addr}" ]]; then
      lovelace=0 asset_cnt=0
      if [[ "${use_koios}" == Y ]]; then
        for key in "${!wallet_list_assets[@]}"; do
          [[ "${key}" == "${base_addr},lovelace" ]] && {
            lovelace="${wallet_list_assets[${key}]}"
            continue
          }
          [[ "${key}" == "${base_addr},"* ]] && ((asset_cnt++))
        done
      else
        getBalance "${base_addr}"
        lovelace="${assets[lovelace]:-0}"
        asset_cnt=$(( ${#assets[@]} - 1 ))
        (( asset_cnt < 0 )) && asset_cnt=0
      fi
      _cntools_action_wallet_list_integer_valid "${lovelace}" || {
        _cntools_action_wallet_list_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_list_validation_failure
        return 70
      }
      getPriceString "${lovelace}"
      println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Address" "${base_addr}")"
      if [[ "${asset_cnt}" -eq 0 ]]; then
        println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Funds" "$(formatLovelace "${lovelace}")")"
      else
        println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str} - ${FG_LBLUE}%s${NC} additional asset(s) on address! [WALLET >> SHOW for details]" "Base Funds" "$(formatLovelace "${lovelace}")" "${asset_cnt}")"
      fi
    fi
    if [[ -n "${pay_addr}" ]]; then
      lovelace=0 asset_cnt=0
      if [[ "${use_koios}" == Y ]]; then
        for key in "${!wallet_list_assets[@]}"; do
          [[ "${key}" == "${pay_addr},lovelace" ]] && {
            lovelace="${wallet_list_assets[${key}]}"
            continue
          }
          [[ "${key}" == "${pay_addr},"* ]] && ((asset_cnt++))
        done
      else
        getBalance "${pay_addr}"
        lovelace="${assets[lovelace]:-0}"
        asset_cnt=$(( ${#assets[@]} - 1 ))
        (( asset_cnt < 0 )) && asset_cnt=0
      fi
      _cntools_action_wallet_list_integer_valid "${lovelace}" || {
        _cntools_action_wallet_list_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_list_validation_failure
        return 70
      }
      getPriceString "${lovelace}"
      if [[ "${lovelace}" -gt 0 ]]; then
        println "$(printf "%-15s : ${FG_LGRAY}%s${NC}" "Payment Addr" "${pay_addr}")"
        if [[ "${asset_cnt}" -eq 0 ]]; then
          println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Payment Funds" "$(formatLovelace "${lovelace}")")"
        else
          println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str} - ${FG_LBLUE}%s${NC} additional asset(s) on address! [WALLET >> SHOW for details]" "Payment Funds" "$(formatLovelace "${lovelace}")" "${asset_cnt}")"
        fi
      fi
    fi
    if [[ "${use_koios}" == Y ]]; then
      reward_lovelace="${wallet_list_rewards[${reward_addr}]:-0}"
      pool_delegation="${wallet_list_pool_delegations[${reward_addr}]:-}"
    fi
    if [[ -n "${pool_delegation}" ]]; then
      _cntools_action_wallet_list_integer_valid "${reward_lovelace}" || {
        _cntools_action_wallet_list_cleanup || true
        trap - EXIT HUP INT TERM
        _cntools_action_wallet_list_validation_failure
        return 70
      }
      getPriceString "${reward_lovelace}"
      println "$(printf "%-15s : ${FG_LBLUE}%s${NC} ADA${price_str}" "Rewards" "$(formatLovelace "${reward_lovelace}")")"
      pool_name=""
      if [[ -d "${POOL_FOLDER}" && ! -L "${POOL_FOLDER}" ]]; then
        while IFS= read -r -d '' pool; do
          [[ "${pool##*/}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ ]] || continue
          if getPoolID "${pool##*/}" &&
             [[ "${pool_id_bech32:-}" == "${pool_delegation}" ]]; then
            pool_name="${pool##*/}"
            break
          fi
        done < <("${wallet_list_find_path}" "${POOL_FOLDER}" \
          -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | LC_ALL=C \
          "${wallet_list_sort_path}" -z)
      fi
      println "${FG_RED}Delegated${NC} to ${FG_GREEN}${pool_name}${NC} ${FG_LGRAY}(${pool_delegation})${NC}"
    fi
  done

  waitToProceed
  _cntools_action_wallet_list_cleanup || {
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_list_validation_failure
    return 70
  }
  trap - EXIT HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
