#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2154
# Stage 4 compatibility action for the detailed wallet view. Sourcing defines
# functions only; the dispatcher supplies the authenticated context and the
# inherited legacy presentation and selection helpers.

_cntools_action_wallet_show_validation_failure() {
  builtin printf '%s\n' 'CNTools wallet-show action failed validation.' >&2
  return 70
}

_cntools_action_wallet_show_terminal_restore() {
  local restore_failed=0

  if [[ "${wallet_show_terminal_saved:-N}" == Y ]]; then
    tput rc >/dev/null 2>&1 || restore_failed=1
    tput ed >/dev/null 2>&1 || restore_failed=1
    wallet_show_terminal_saved=N
  fi
  return "${restore_failed}"
}

_cntools_action_wallet_show_cleanup() {
  local target="" cleanup_failed=0

  _cntools_action_wallet_show_terminal_restore || cleanup_failed=1
  for target in "${wallet_show_temp_files[@]:-}"; do
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${wallet_show_rm_path}" -f -- "${target}" >/dev/null 2>&1 ||
        cleanup_failed=1
    fi
  done
  wallet_show_temp_files=()
  return "${cleanup_failed}"
}

_cntools_action_wallet_show_file_validate() {
  local target="${1:-}" modes="${2:-}" maximum="${3:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -f "${target}" && ! -L "${target}" &&
     "${maximum}" =~ ^[1-9][0-9]*$ ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${size}" =~ ^[0-9]+$ && "${size}" -ge 1 &&
     "${size}" -le "${maximum}" &&
     ",${modes}," == *",${mode},"* ]]
}

_cntools_action_wallet_show_integer_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${value}" -le 45000000000000000 ]]
}

_cntools_action_wallet_show_integer_add() {
  local left="${1:-}" right="${2:-}" output_name="${3:-}" sum=0

  case "${output_name}" in
    amount|total_lovelace|wallet_show_vote_power_total) ;;
    *) return 1 ;;
  esac
  _cntools_action_wallet_show_integer_valid "${left}" &&
    _cntools_action_wallet_show_integer_valid "${right}" || return 1
  sum=$((left + right))
  (( sum >= left && sum >= right )) || return 1
  _cntools_action_wallet_show_integer_valid "${sum}" || return 1
  printf -v "${output_name}" '%s' "${sum}"
}

_cntools_action_wallet_show_name_valid() {
  local value="${1:-}"

  [[ "${#value}" -ge 1 && "${#value}" -le 128 &&
     "${value}" =~ ^[A-Za-z0-9._+@:-]+$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_wallet_show_terminal_value_valid() {
  local value="${1:-}" maximum="${2:-256}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ && "${#value}" -le "${maximum}" &&
     "${value}" != *$'\n'* && "${value}" != *$'\r'* &&
     ! "${value}" =~ [[:cntrl:]] ]]
}

_cntools_action_wallet_show_styled_value_valid() {
  local value="${1:-}" maximum="${2:-256}" color_name="" color_value=""

  for color_name in FG_BLACK FG_RED FG_GREEN FG_YELLOW FG_BLUE FG_MAGENTA \
      FG_CYAN FG_LGRAY FG_DGRAY FG_LBLUE FG_WHITE NC; do
    color_value="${!color_name:-}"
    [[ -z "${color_value}" ]] || value="${value//"${color_value}"/}"
  done
  _cntools_action_wallet_show_terminal_value_valid "${value}" "${maximum}"
}

_cntools_action_wallet_show_address_valid() {
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

_cntools_action_wallet_show_pool_valid() {
  [[ "${1:-}" =~ ^pool1[023456789ac-hj-np-z]{20,100}$ ]]
}

_cntools_action_wallet_show_input_usable() {
  _cntools_action_wallet_show_file_validate "${1:-}" '400,444,600,644' 65536
}

_cntools_action_wallet_show_cache_read() {
  local target="${1:-}" kind="${2:-}" output_name="${3:-}" value=""

  case "${kind}:${output_name}" in
    base:base_addr|payment:pay_addr|reward:reward_addr|credential:pay_cred|credential:stake_cred|credential:ms_pay_cred|credential:ms_stake_cred|credential:script_pay_cred|credential:script_stake_cred) ;;
    *) return 1 ;;
  esac
  _cntools_action_wallet_show_file_validate \
    "${target}" '400,444,600,644' 512 || return 1
  value="$(< "${target}")"
  if [[ "${kind}" == credential ]]; then
    [[ "${value}" =~ ^[0-9A-Fa-f]{56}$ ]]
  else
    _cntools_action_wallet_show_address_valid "${kind}" "${value}"
  fi || return 1
  printf -v "${output_name}" '%s' "${value}"
}

_cntools_action_wallet_show_cache_create() {
  local wallet="${1:-}" kind="${2:-}" target="${3:-}"
  local output_name="${4:-}" temporary="" value=""
  local pay_vkey="${wallet}/${WALLET_PAY_VK_FILENAME}"
  local stake_vkey="${wallet}/${WALLET_STAKE_VK_FILENAME}"
  local pay_script="${wallet}/${WALLET_PAY_SCRIPT_FILENAME}"
  local stake_script="${wallet}/${WALLET_STAKE_SCRIPT_FILENAME}"
  local -a arguments=()

  if [[ -e "${target}" || -L "${target}" ]]; then
    _cntools_action_wallet_show_cache_read \
      "${target}" "$([[ "${kind}" == *credential ]] && printf credential ||
        printf '%s' "${kind}")" "${output_name}" || return 70
    return 0
  fi
  temporary="$(${wallet_show_mktemp_path} \
    "${wallet}/.cntools-wallet-show.${kind}.XXXXXXXX")" || return 1
  wallet_show_temp_files+=("${temporary}")
  "${wallet_show_chmod_path}" 0600 "${temporary}" || return 1

  case "${kind}" in
    base)
      if _cntools_action_wallet_show_input_usable "${pay_vkey}" &&
         _cntools_action_wallet_show_input_usable "${stake_vkey}"; then
        arguments=(address build --payment-verification-key-file "${pay_vkey}"
          --stake-verification-key-file "${stake_vkey}")
      elif _cntools_action_wallet_show_input_usable "${pay_script}" &&
           _cntools_action_wallet_show_input_usable "${stake_script}"; then
        arguments=(address build --payment-script-file "${pay_script}"
          --stake-script-file "${stake_script}")
      elif _cntools_action_wallet_show_input_usable "${pay_script}" &&
           _cntools_action_wallet_show_input_usable "${stake_vkey}"; then
        arguments=(address build --payment-script-file "${pay_script}"
          --stake-verification-key-file "${stake_vkey}")
      elif _cntools_action_wallet_show_input_usable "${pay_vkey}" &&
           _cntools_action_wallet_show_input_usable "${stake_script}"; then
        arguments=(address build --payment-verification-key-file "${pay_vkey}"
          --stake-script-file "${stake_script}")
      else
        return 1
      fi
      ;;
    payment)
      if _cntools_action_wallet_show_input_usable "${pay_vkey}"; then
        arguments=(address build --payment-verification-key-file "${pay_vkey}")
      elif _cntools_action_wallet_show_input_usable "${pay_script}"; then
        arguments=(address build --payment-script-file "${pay_script}")
      else
        return 1
      fi
      ;;
    reward)
      if _cntools_action_wallet_show_input_usable "${stake_vkey}"; then
        arguments=(latest stake-address build
          --stake-verification-key-file "${stake_vkey}")
      elif _cntools_action_wallet_show_input_usable "${stake_script}"; then
        arguments=(latest stake-address build --stake-script-file "${stake_script}")
      else
        return 1
      fi
      ;;
    paycredential)
      _cntools_action_wallet_show_input_usable "${pay_vkey}" || return 1
      arguments=(address key-hash --payment-verification-key-file "${pay_vkey}")
      ;;
    stakecredential)
      _cntools_action_wallet_show_input_usable "${stake_vkey}" || return 1
      arguments=(latest stake-address key-hash
        --stake-verification-key-file "${stake_vkey}")
      ;;
    scriptpaycredential)
      _cntools_action_wallet_show_input_usable "${pay_script}" || return 1
      arguments=(hash script --script-file "${pay_script}")
      ;;
    scriptstakecredential)
      _cntools_action_wallet_show_input_usable "${stake_script}" || return 1
      arguments=(hash script --script-file "${stake_script}")
      ;;
    *) return 1 ;;
  esac
  arguments+=(--out-file "${temporary}")
  case "${kind}" in
    base|payment|reward) arguments+=("${wallet_show_network_args[@]}") ;;
  esac
  println ACTION 'cardano-cli wallet-show cache generation'
  "${wallet_show_ccli_path}" "${arguments[@]}" >/dev/null 2>&1 || return 1
  "${wallet_show_chmod_path}" 0600 "${temporary}" || return 1
  _cntools_action_wallet_show_file_validate "${temporary}" 600 512 || return 1
  value="$(< "${temporary}")"
  if [[ "${kind}" == *credential ]]; then
    [[ "${value}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 1
  else
    _cntools_action_wallet_show_address_valid "${kind}" "${value}" || return 1
  fi
  if ! "${wallet_show_ln_path}" -- "${temporary}" "${target}" \
      >/dev/null 2>&1; then
    _cntools_action_wallet_show_cache_read "${target}" \
      "$([[ "${kind}" == *credential ]] && printf credential ||
        printf '%s' "${kind}")" "${output_name}" && return 0
    return 70
  fi
  "${wallet_show_rm_path}" -f -- "${temporary}" >/dev/null 2>&1 || return 1
  _cntools_action_wallet_show_cache_read "${target}" \
    "$([[ "${kind}" == *credential ]] && printf credential ||
      printf '%s' "${kind}")" "${output_name}"
}

_cntools_action_wallet_show_cache_resolve() {
  local wallet="${1:-}" kind="${2:-}" output_name="${3:-}"
  local filename="" target="" read_kind="${kind}"

  case "${kind}:${output_name}" in
    base:base_addr) filename="${WALLET_BASE_ADDR_FILENAME}" ;;
    payment:pay_addr) filename="${WALLET_PAY_ADDR_FILENAME}" ;;
    reward:reward_addr) filename="${WALLET_STAKE_ADDR_FILENAME}" ;;
    paycredential:pay_cred) filename="${WALLET_PAY_CRED_FILENAME}"; read_kind=credential ;;
    stakecredential:stake_cred) filename="${WALLET_STAKE_CRED_FILENAME}"; read_kind=credential ;;
    scriptpaycredential:script_pay_cred) filename="${WALLET_PAY_SCRIPT_CRED_FILENAME}"; read_kind=credential ;;
    scriptstakecredential:script_stake_cred) filename="${WALLET_STAKE_SCRIPT_CRED_FILENAME}"; read_kind=credential ;;
    *) return 1 ;;
  esac
  target="${wallet}/${filename}"
  printf -v "${output_name}" '%s' ""
  if [[ -e "${target}" || -L "${target}" ]]; then
    _cntools_action_wallet_show_cache_read \
      "${target}" "${read_kind}" "${output_name}" || return 70
  else
    _cntools_action_wallet_show_cache_create \
      "${wallet}" "${kind}" "${target}" "${output_name}"
  fi
}

_cntools_action_wallet_show_private_file_create() {
  local label="${1:-}" output_name="${2:-}" created=""

  [[ "${label}" =~ ^[a-z0-9-]{1,32}$ ]] || return 1
  case "${output_name}" in
    response_file|summary_file|distribution_file|curl_response) ;;
    *) return 1 ;;
  esac
  created="$(${wallet_show_mktemp_path} \
    "${wallet_show_private_parent}/wallet-show-${label}.XXXXXXXX")" || return 1
  wallet_show_temp_files+=("${created}")
  "${wallet_show_chmod_path}" 0600 "${created}" || return 1
  printf -v "${output_name}" '%s' "${created}"
}

_cntools_action_wallet_show_response_validate() {
  local target="${1:-}" maximum="${2:-}"

  _cntools_action_wallet_show_file_validate "${target}" 600 "${maximum}"
}

_cntools_action_wallet_show_curl_json() {
  local label="${1:-}" method="${2:-}" endpoint="${3:-}"
  local payload="${4:-}" maximum="${5:-}" output_name="${6:-}"
  local curl_response=""
  local -a arguments=()

  case "${output_name}" in response_file|summary_file) ;; *) return 70 ;; esac
  [[ "${endpoint}" != *[[:space:]]* && "${endpoint}" != *\\* &&
     "${endpoint}" != *'#'* && "${#endpoint}" -le 1024 ]] || return 70
  _cntools_action_wallet_show_private_file_create \
    "${label}" curl_response || return 70
  arguments=("${wallet_show_curl_path}" --disable --silent --show-error
    --location --max-redirs 3 --proto '=https' --proto-redir '=https'
    --connect-timeout "${wallet_show_curl_timeout}"
    --max-time "${wallet_show_curl_timeout}" --fail
    --max-filesize "${maximum}" "${wallet_show_koios_headers[@]}")
  if [[ "${method}" == POST ]]; then
    [[ "${#payload}" -le 1024 ]] || return 70
    arguments+=(--request POST --header 'Content-Type: application/json'
      --header 'accept: application/json' --data "${payload}")
  elif [[ "${method}" == GET ]]; then
    [[ -z "${payload}" ]] || return 70
    arguments+=(--request GET --header 'accept: application/json')
  else
    return 70
  fi
  arguments+=(--output "${curl_response}"
    --url "${wallet_show_koios_api}/${endpoint}")
  println ACTION 'curl [configured headers redacted] CNTools wallet-show query'
  "${arguments[@]}" 2>/dev/null || return 1
  _cntools_action_wallet_show_response_validate \
    "${curl_response}" "${maximum}" || return 1
  printf -v "${output_name}" '%s' "${curl_response}"
}

_cntools_action_wallet_show_asset_add() {
  local address="${1:-}" asset="${2:-}" quantity="${3:-}"
  local key="${address},${asset}" amount=""

  amount="${wallet_show_assets[${key}]:-0}"

  _cntools_action_wallet_show_integer_add "${amount}" "${quantity}" amount ||
    return 1
  wallet_show_assets["${key}"]="${amount}"
}

_cntools_action_wallet_show_utxo_add() {
  local address="${1:-}" tx_ref="${2:-}" asset="${3:-}" quantity="${4:-}"
  local key="${address},${tx_ref}.${asset}"

  [[ -z "${wallet_show_utxos[${key}]+set}" ]] || return 1
  wallet_show_utxos["${key}"]="${quantity}"
  if [[ "${asset}" == ' ADA' ]]; then
    wallet_show_utxo_counts["${address}"]=$((${wallet_show_utxo_counts[${address}]:-0} + 1))
  fi
}

_cntools_action_wallet_show_local_utxo_query() {
  local address="${1:-}" label="${2:-}" response_file=""
  local tx_ref="" asset="" quantity="" rows="" expected_rows=""
  local row_count=0 asset_count=0

  _cntools_action_wallet_show_private_file_create \
    "local-${label}" response_file || return 70
  println ACTION 'cardano-cli wallet-show UTxO query'
  "${wallet_show_ccli_path}" query utxo --address "${address}" \
    "${wallet_show_network_args[@]}" --output-json \
    > "${response_file}" 2>/dev/null || return 1
  _cntools_action_wallet_show_response_validate \
    "${response_file}" 8388608 || return 1
  "${wallet_show_jq_path}" -e --arg address "${address}" '
    type == "object" and length <= 10000 and all(to_entries[];
      (.key | test("^[0-9A-Fa-f]{64}#[0-9]{1,5}$")) and
      (.value | type == "object") and
      (.value.address == $address) and
      (.value.value | type == "object" and length >= 1 and length <= 1001 and
        has("lovelace")) and
      all(.value.value | to_entries[];
        (.key == "lovelace" or
          (.key | test("^[0-9A-Fa-f]{56}([.][0-9A-Fa-f]{0,64})?$"))) and
        (.value | type == "number" and floor == . and
          . >= 0 and . <= 45000000000000000)))
  ' "${response_file}" >/dev/null 2>&1 || return 1
  expected_rows="$("${wallet_show_jq_path}" -er \
    '[to_entries[].value.value | length] | add // 0 | tostring' \
    "${response_file}" 2>/dev/null)" || return 1
  [[ "${expected_rows}" =~ ^(0|[1-9][0-9]{0,7})$ ]] || return 1
  rows="$("${wallet_show_jq_path}" -er '
    [to_entries[] as $utxo |
      $utxo.value.value | to_entries[] |
      [$utxo.key, .key, (.value | tostring)] | @tsv] | join("\n")
  ' "${response_file}" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r tx_ref asset quantity; do
    [[ -n "${tx_ref}" ]] || continue
    row_count=$((row_count + 1))
    [[ "${row_count}" -le 100000 &&
       "${tx_ref##*#}" -le 65535 ]] || return 1
    _cntools_action_wallet_show_integer_valid "${quantity}" || return 1
    if [[ "${asset}" == lovelace ]]; then
      _cntools_action_wallet_show_utxo_add \
        "${address}" "${tx_ref}" ' ADA' "${quantity}" || return 1
    else
      asset_count=$((asset_count + 1))
      [[ "${asset_count}" -le 100000 ]] || return 1
      _cntools_action_wallet_show_utxo_add \
        "${address}" "${tx_ref}" "${asset}" "${quantity}" || return 1
    fi
    _cntools_action_wallet_show_asset_add \
      "${address}" "${asset}" "${quantity}" || return 1
  done <<< "${rows}"
  [[ "${row_count}" == "${expected_rows}" ]] || return 1
  [[ -n "${wallet_show_assets[${address},lovelace]+set}" ]] ||
    wallet_show_assets["${address},lovelace"]=0
}

_cntools_action_wallet_show_light_utxo_query() {
  local joined="" payload="" response_file=""
  local address="" tx_hash="" tx_index="" value="" assets_json=""
  local policy="" asset_name="" quantity="" tx_ref="" rows="" inner_rows=""
  local expected_rows="" expected_inner=""
  local row_count=0 asset_count=0 inner_count=0
  local -a addresses=()

  [[ -n "${base_addr}" ]] && addresses+=("${base_addr}")
  [[ -n "${pay_addr}" ]] && addresses+=("${pay_addr}")
  (( ${#addresses[@]} > 0 )) || return 0
  printf -v joined '"%s",' "${addresses[@]}"
  payload='{"_addresses":['${joined%,}'],"_extended":true}'
  _cntools_action_wallet_show_curl_json address POST \
    'address_utxos?select=address,tx_hash,tx_index,value,asset_list' \
    "${payload}" 8388608 response_file || return $?
  "${wallet_show_jq_path}" -e --arg base "${base_addr}" --arg pay "${pay_addr}" '
    type == "array" and length <= 10000 and all(.[];
      type == "object" and
      (.address == $base or .address == $pay) and
      (.tx_hash | type == "string" and test("^[0-9A-Fa-f]{64}$")) and
      (.tx_index | type == "number" and floor == . and . >= 0 and . <= 65535) and
      (.value | type == "number" and floor == . and
        . >= 0 and . <= 45000000000000000) and
      (.asset_list | type == "array" and length <= 1000) and
      all(.asset_list[];
        type == "object" and
        (.policy_id | type == "string" and test("^[0-9A-Fa-f]{56}$")) and
        (.asset_name | type == "string" and test("^([0-9A-Fa-f]{2}){0,32}$")) and
        (.quantity | type == "number" and floor == . and
          . >= 0 and . <= 45000000000000000)))
  ' "${response_file}" >/dev/null 2>&1 || return 1
  expected_rows="$("${wallet_show_jq_path}" -er 'length | tostring' \
    "${response_file}" 2>/dev/null)" || return 1
  rows="$("${wallet_show_jq_path}" -cer '
    [.[] | [.address, .tx_hash, (.tx_index|tostring), (.value|tostring),
      (.asset_list|tojson)] | @tsv] | join("\n")
  ' "${response_file}" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r address tx_hash tx_index value assets_json; do
    [[ -n "${address}" ]] || continue
    row_count=$((row_count + 1))
    [[ "${row_count}" -le 10000 ]] || return 1
    tx_ref="${tx_hash}#${tx_index}"
    _cntools_action_wallet_show_utxo_add \
      "${address}" "${tx_ref}" ' ADA' "${value}" || return 1
    _cntools_action_wallet_show_asset_add \
      "${address}" lovelace "${value}" || return 1
    expected_inner="$("${wallet_show_jq_path}" -er 'length | tostring' \
      <<< "${assets_json}" 2>/dev/null)" || return 1
    inner_rows="$("${wallet_show_jq_path}" -er \
      '[.[] | [.policy_id, .asset_name, (.quantity | tostring)] | @tsv] | join("\n")' \
      <<< "${assets_json}" 2>/dev/null)" || return 1
    inner_count=0
    while IFS=$'\t' read -r policy asset_name quantity; do
      [[ -n "${policy}" ]] || continue
      inner_count=$((inner_count + 1))
      asset_count=$((asset_count + 1))
      [[ "${asset_count}" -le 100000 ]] || return 1
      _cntools_action_wallet_show_utxo_add "${address}" "${tx_ref}" \
        "${policy}.${asset_name}" "${quantity}" || return 1
      _cntools_action_wallet_show_asset_add "${address}" \
        "${policy}.${asset_name}" "${quantity}" || return 1
    done <<< "${inner_rows}"
    [[ "${inner_count}" == "${expected_inner}" ]] || return 1
  done <<< "${rows}"
  [[ "${row_count}" == "${expected_rows}" ]] || return 1
  [[ -z "${base_addr}" || -n "${wallet_show_assets[${base_addr},lovelace]+set}" ]] ||
    wallet_show_assets["${base_addr},lovelace"]=0
  [[ -z "${pay_addr}" || -n "${wallet_show_assets[${pay_addr},lovelace]+set}" ]] ||
    wallet_show_assets["${pay_addr},lovelace"]=0
}

_cntools_action_wallet_show_stake_values_validate() {
  _cntools_action_wallet_show_integer_valid "${wallet_show_reward_lovelace}" &&
    _cntools_action_wallet_show_integer_valid "${wallet_show_stake_deposit}" &&
    { [[ -z "${wallet_show_pool_delegation}" ]] ||
      _cntools_action_wallet_show_pool_valid "${wallet_show_pool_delegation}"; } &&
    { [[ -z "${wallet_show_vote_delegation}" ||
         "${wallet_show_vote_delegation}" == alwaysAbstain ||
         "${wallet_show_vote_delegation}" == alwaysNoConfidence ||
         "${wallet_show_vote_delegation}" =~ ^(keyHash|scriptHash)-[0-9A-Fa-f]{56}$ ]]; }
}

_cntools_action_wallet_show_local_stake_query() {
  local response_file="" parsed="" pool="" vote=""

  wallet_show_registered=no
  wallet_show_reward_lovelace=0
  wallet_show_stake_deposit=0
  wallet_show_pool_delegation=""
  wallet_show_vote_delegation=""
  [[ -n "${reward_addr}" ]] || return 0
  _cntools_action_wallet_show_private_file_create local-stake response_file ||
    return 70
  println ACTION 'cardano-cli wallet-show stake query'
  "${wallet_show_ccli_path}" query stake-address-info \
    "${wallet_show_network_args[@]}" --address "${reward_addr}" \
    > "${response_file}" 2>/dev/null || return 1
  _cntools_action_wallet_show_response_validate \
    "${response_file}" 1048576 || return 1
  "${wallet_show_jq_path}" -e --arg address "${reward_addr}" '
    type == "array" and length <= 1 and all(.[];
      type == "object" and (.address == $address) and
      (.rewardAccountBalance | type == "number" and floor == . and
        . >= 0 and . <= 45000000000000000) and
      ((.stakeRegistrationDeposit // 0) | type == "number" and floor == . and
        . >= 0 and . <= 45000000000000000) and
      ((.stakeDelegation // null) == null or
        ((.stakeDelegation | type) == "object" and
          (.stakeDelegation.stakePoolBech32 | type == "string"))) and
      ((.voteDelegation // null) == null or
        ((.voteDelegation | type) == "string") or
        ((.voteDelegation | type) == "object")))
  ' "${response_file}" >/dev/null 2>&1 || return 1
  [[ "$("${wallet_show_jq_path}" -er 'length' "${response_file}")" == 1 ]] ||
    return 0
  parsed="$("${wallet_show_jq_path}" -er '
    .[0] |
    def pool: (.stakeDelegation.stakePoolBech32 // "");
    def vote:
      (.voteDelegation // null) as $v |
      if ($v|type) == "string" then $v
      elif ($v|type) == "object" and ($v.keyHashLedger // "") != "" then
        "keyHash-\($v.keyHashLedger)"
      elif ($v|type) == "object" and ($v.scriptHashLedger // "") != "" then
        "scriptHash-\($v.scriptHashLedger)"
      else "" end;
    ["registered", (.rewardAccountBalance|tostring),
      ((.stakeRegistrationDeposit // 0)|tostring), pool, vote] | @tsv
  ' "${response_file}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r _ wallet_show_reward_lovelace \
    wallet_show_stake_deposit pool vote <<< "${parsed}" || return 1
  wallet_show_registered=yes
  wallet_show_pool_delegation="${pool}"
  wallet_show_vote_delegation="${vote}"
  _cntools_action_wallet_show_stake_values_validate
}

_cntools_action_wallet_show_light_stake_query() {
  local payload="" response_file="" parsed="" status=""
  local delegated_drep=""

  wallet_show_registered=no
  wallet_show_reward_lovelace=0
  wallet_show_stake_deposit=0
  wallet_show_pool_delegation=""
  wallet_show_vote_delegation=""
  [[ -n "${reward_addr}" ]] || return 0
  payload='{"_stake_addresses":["'${reward_addr}'"]}'
  _cntools_action_wallet_show_curl_json reward POST \
    'account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit' \
    "${payload}" 1048576 response_file || return $?
  "${wallet_show_jq_path}" -e --arg address "${reward_addr}" '
    type == "array" and length <= 1 and all(.[];
      type == "object" and .stake_address == $address and
      (.status == "registered" or .status == "not registered") and
      ((.delegated_pool // "") | type == "string" and length <= 128) and
      ((.delegated_drep // "") | type == "string" and length <= 256) and
      (.rewards_available | type == "number" and floor == . and
        . >= 0 and . <= 45000000000000000) and
      (.deposit | type == "number" and floor == . and
        . >= 0 and . <= 45000000000000000))
  ' "${response_file}" >/dev/null 2>&1 || return 1
  [[ "$("${wallet_show_jq_path}" -er 'length' "${response_file}")" == 1 ]] ||
    return 0
  parsed="$("${wallet_show_jq_path}" -er '
    .[0] | [.status, (.rewards_available|tostring), (.deposit|tostring),
      (.delegated_pool // ""), (.delegated_drep // "")] | @tsv
  ' "${response_file}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r status wallet_show_reward_lovelace \
    wallet_show_stake_deposit wallet_show_pool_delegation delegated_drep \
    <<< "${parsed}" || return 1
  [[ "${status}" == registered ]] && wallet_show_registered=yes
  case "${delegated_drep}" in
    '') ;;
    drep_always_abstain) wallet_show_vote_delegation=alwaysAbstain ;;
    drep_always_no_confidence) wallet_show_vote_delegation=alwaysNoConfidence ;;
    *)
      _cntools_action_wallet_show_terminal_value_valid \
        "${delegated_drep}" 256 || return 1
      wallet_show_drep_raw="$(bech32 <<< "${delegated_drep}")" || return 1
      if [[ "${wallet_show_drep_raw}" =~ ^22([0-9A-Fa-f]{56})$ ]]; then
        wallet_show_vote_delegation="keyHash-${BASH_REMATCH[1]}"
      elif [[ "${wallet_show_drep_raw}" =~ ^23([0-9A-Fa-f]{56})$ ]]; then
        wallet_show_vote_delegation="scriptHash-${BASH_REMATCH[1]}"
      else
        return 1
      fi
      ;;
  esac
  _cntools_action_wallet_show_stake_values_validate
}

_cntools_action_wallet_show_query_all() {
  wallet_show_utxos=()
  wallet_show_utxo_counts=()
  wallet_show_assets=()
  if [[ "${context_mode}" == light ]]; then
    _cntools_action_wallet_show_light_utxo_query || return $?
    _cntools_action_wallet_show_light_stake_query || return $?
  else
    [[ -z "${base_addr}" ]] ||
      _cntools_action_wallet_show_local_utxo_query "${base_addr}" base || return $?
    [[ -z "${pay_addr}" ]] ||
      _cntools_action_wallet_show_local_utxo_query "${pay_addr}" payment || return $?
    _cntools_action_wallet_show_local_stake_query || return $?
  fi
}

_cntools_action_wallet_show_formatted_lovelace() {
  local value="${1:-}" output_name="${2:-}" rendered=""

  [[ "${output_name}" == formatted ]] || return 1
  _cntools_action_wallet_show_integer_valid "${value}" || return 1
  rendered="$(formatLovelace "${value}")" || return 1
  [[ "${rendered}" =~ ^[0-9][0-9.,]{0,63}$ ]] || return 1
  printf -v "${output_name}" '%s' "${rendered}"
}

_cntools_action_wallet_show_formatted_asset() {
  local value="${1:-}" output_name="${2:-}" rendered=""

  [[ "${output_name}" == formatted ]] || return 1
  _cntools_action_wallet_show_integer_valid "${value}" || return 1
  rendered="$(formatAsset "${value}")" || return 1
  [[ "${rendered}" =~ ^[0-9][0-9.,]{0,63}$ ]] || return 1
  printf -v "${output_name}" '%s' "${rendered}"
}

_cntools_action_wallet_show_asset_display() {
  local asset="${1:-}" name_output="${2:-}" id_output="${3:-}"
  local policy="" asset_name="" rendered_name="" rendered_id=""

  [[ "${name_output}" == display_name && "${id_output}" == display_id &&
     "${asset}" =~ ^([0-9A-Fa-f]{56})[.]([0-9A-Fa-f]{0,64})$ ]] || return 1
  policy="${BASH_REMATCH[1]}"
  asset_name="${BASH_REMATCH[2]}"
  rendered_name="$(hexToAscii "${asset_name}")" || return 1
  rendered_name="${rendered_name//[![:print:]]/}"
  _cntools_action_wallet_show_terminal_value_valid "${rendered_name}" 64 || return 1
  rendered_id="$(getAssetIDBech32 "${policy}" "${asset_name}")" || return 1
  _cntools_action_wallet_show_terminal_value_valid "${rendered_id}" 256 || return 1
  printf -v "${name_output}" '%s' "${rendered_name}"
  printf -v "${id_output}" '%s' "${rendered_id}"
}

_cntools_action_wallet_show_render_address() {
  local address="${1:-}" address_type="${2:-}"
  local key="" relative="" tx_ref="" asset="" quantity="" formatted=""
  local display_name="" display_id="" lovelace=0 asset_count=0 summary_count=0
  local utxo_count="${wallet_show_utxo_counts[${address}]:-0}"
  local name_width=5 amount_width=12
  local -a sorted_utxos=() sorted_assets=()

  for key in "${!wallet_show_assets[@]}"; do
    [[ "${key}" == "${address},"* ]] || continue
    asset="${key#"${address},"}"
    quantity="${wallet_show_assets[${key}]}"
    if [[ "${asset}" == lovelace ]]; then
      lovelace="${quantity}"
      continue
    fi
    asset_count=$((asset_count + 1))
    _cntools_action_wallet_show_asset_display \
      "${asset}" display_name display_id || return 1
    _cntools_action_wallet_show_formatted_asset "${quantity}" formatted || return 1
    (( ${#display_name} > name_width )) && name_width=${#display_name}
    (( ${#formatted} > amount_width )) && amount_width=${#formatted}
  done
  _cntools_action_wallet_show_formatted_lovelace "${lovelace}" formatted || return 1
  (( ${#formatted} > amount_width )) && amount_width=${#formatted}

  echo
  println "${FG_LBLUE}${utxo_count} UTxO(s)${NC} found for ${FG_GREEN}${address_type}${NC} Address!"
  if (( utxo_count > 0 )); then
    echo
    println DEBUG "$(printf "%-68s ${FG_DGRAY}|${NC} %${name_width}s ${FG_DGRAY}|${NC} %-${amount_width}s\n" "UTxO Hash#Index" "Asset" "Amount")"
    println DEBUG "${FG_DGRAY}$(printf "%69s+%$((name_width+2))s+%$((amount_width+1))s\n" "" "" "" | "${wallet_show_tr_path}" " " "-")${NC}"
    mapfile -d '' sorted_utxos < <(printf '%s\0' "${!wallet_show_utxos[@]}" | LC_ALL=C "${wallet_show_sort_path}" -z)
    for key in "${sorted_utxos[@]}"; do
      [[ "${key}" == "${address},"* ]] || continue
      relative="${key#"${address},"}"
      tx_ref="${relative%%.*}"
      asset="${relative#*.}"
      quantity="${wallet_show_utxos[${key}]}"
      if [[ "${asset}" == ' ADA' ]]; then
        _cntools_action_wallet_show_formatted_lovelace "${quantity}" formatted || return 1
        println DEBUG "$(printf "%-68s ${FG_DGRAY}|${NC} ${FG_GREEN}%${name_width}s${NC} ${FG_DGRAY}|${NC} ${FG_LBLUE}%-${amount_width}s${NC}\n" "${tx_ref}" ADA "${formatted}")"
      else
        _cntools_action_wallet_show_asset_display \
          "${asset}" display_name display_id || return 1
        _cntools_action_wallet_show_formatted_asset "${quantity}" formatted || return 1
        println DEBUG "$(printf "${FG_DGRAY}%20s${NC}${FG_LGRAY}%-48s${NC} ${FG_DGRAY}|${NC} ${FG_MAGENTA}%${name_width}s${NC} ${FG_DGRAY}|${NC} ${FG_LBLUE}%-${amount_width}s${NC}\n" "Asset Fingerprint: " "${display_id}" "${display_name}" "${formatted}")"
      fi
    done
  fi
  summary_count="${asset_count}"
  [[ -z "${wallet_show_assets[${address},lovelace]+set}" ]] ||
    summary_count=$((summary_count + 1))
  if (( summary_count > 0 )); then
    println "\nASSET SUMMARY: ${FG_LBLUE}${summary_count} Asset-Type(s)${NC}\n"
    if (( summary_count > 1 )); then
      println DEBUG "$(printf "%${amount_width}s ${FG_DGRAY}|${NC} %-${name_width}s ${FG_DGRAY}|${NC} Asset Fingerprint\n" "Total Amount" "Asset")"
      println DEBUG "${FG_DGRAY}$(printf "%$((amount_width+1))s+%$((name_width+2))s+%57s\n" "" "" "" | "${wallet_show_tr_path}" " " "-")${NC}"
    else
      println DEBUG "$(printf "%${amount_width}s ${FG_DGRAY}|${NC} %-${name_width}s\n" "Total Amount" "Asset")"
      println DEBUG "${FG_DGRAY}$(printf "%$((amount_width+1))s+%$((name_width+2))s\n" "" "" | "${wallet_show_tr_path}" " " "-")${NC}"
    fi
    _cntools_action_wallet_show_formatted_lovelace "${lovelace}" formatted || return 1
    if (( asset_count > 0 )); then
      println DEBUG "$(printf "${FG_LBLUE}%${amount_width}s${NC} ${FG_DGRAY}|${NC} ${FG_GREEN}%-${name_width}s${NC} ${FG_DGRAY}|${NC}\n" "${formatted}" ADA)"
    else
      println DEBUG "$(printf "${FG_LBLUE}%${amount_width}s${NC} ${FG_DGRAY}|${NC} ${FG_GREEN}%-${name_width}s${NC}\n" "${formatted}" ADA)"
    fi
    mapfile -d '' sorted_assets < <(printf '%s\0' "${!wallet_show_assets[@]}" | LC_ALL=C "${wallet_show_sort_path}" -z)
    for key in "${sorted_assets[@]}"; do
      [[ "${key}" == "${address},"* ]] || continue
      asset="${key#"${address},"}"
      [[ "${asset}" != lovelace ]] || continue
      _cntools_action_wallet_show_asset_display \
        "${asset}" display_name display_id || return 1
      _cntools_action_wallet_show_formatted_asset \
        "${wallet_show_assets[${key}]}" formatted || return 1
      println DEBUG "$(printf "${FG_LBLUE}%${amount_width}s${NC} ${FG_DGRAY}|${NC} ${FG_MAGENTA}%-${name_width}s${NC} ${FG_DGRAY}|${NC} ${FG_LGRAY}%s${NC}\n" "${formatted}" "${display_name}" "${display_id}")"
    done
  fi
}

_cntools_action_wallet_show_wallet_type() {
  local wallet="${1:-}" description=""
  local pay_vkey="${wallet}/${WALLET_PAY_VK_FILENAME}"
  local stake_vkey="${wallet}/${WALLET_STAKE_VK_FILENAME}"

  wallet_show_wallet_type=""
  if _cntools_action_wallet_show_input_usable "${pay_vkey}" &&
     _cntools_action_wallet_show_input_usable "${stake_vkey}"; then
    description="$("${wallet_show_jq_path}" -er \
      '.description | strings | select(length <= 256)' \
      "${pay_vkey}" 2>/dev/null)" || return 1
    _cntools_action_wallet_show_terminal_value_valid "${description}" 256 || return 1
    if [[ "${description}" == *Hardware* ]]; then
      wallet_show_wallet_type=Hardware
    else
      wallet_show_wallet_type=CLI
    fi
  elif _cntools_action_wallet_show_input_usable \
      "${wallet}/${WALLET_PAY_SCRIPT_FILENAME}" ||
       _cntools_action_wallet_show_input_usable \
      "${wallet}/${WALLET_STAKE_SCRIPT_FILENAME}"; then
    wallet_show_wallet_type=MultiSig
  fi
}

_cntools_action_wallet_show_render_script() {
  local wallet="${1:-}" script=""
  local after="" required="" total="" signature="" header=""
  local date_value="" color="" credential="" candidate="" candidate_name=""
  local script_info="" signature_rows="" expected_signatures="" visited=0
  local ms_pay_cred=""
  local -a signatures=()

  script="${wallet}/${WALLET_PAY_SCRIPT_FILENAME}"

  [[ -e "${script}" || -L "${script}" ]] || return 0
  _cntools_action_wallet_show_input_usable "${script}" || return 1
  "${wallet_show_jq_path}" -e '
    def bounded:
      type == "object" and ((keys - ["type","keyHash","slot","required","scripts"])|length == 0) and
      (.type == "sig" or .type == "after" or .type == "before" or
       .type == "all" or .type == "any" or .type == "atLeast") and
      (if .type == "sig" then (.keyHash|type=="string" and test("^[0-9A-Fa-f]{56}$"))
       elif (.type == "after" or .type == "before") then
         (.slot|type=="number" and floor==. and .>=0 and .<=45000000000000000)
       elif .type == "atLeast" then
         (.required as $required | .scripts as $scripts |
          ($required|type=="number" and floor==. and .>=1) and
          ($scripts|type=="array" and length>=$required and length<=64))
       else (.scripts|type=="array" and length<=64) end);
    ([.. | objects] | length <= 256) and all(.. | objects; bounded)
  ' "${script}" >/dev/null 2>&1 || return 1
  after="$("${wallet_show_jq_path}" -er \
    '[.. | objects | select(.type=="after") | .slot] | if length==0 then "" elif length==1 then .[0] else error("multiple") end' \
    "${script}" 2>/dev/null)" || return 1
  script_info="$("${wallet_show_jq_path}" -er '
    [.. | objects | select(.type=="atLeast")] |
    if length==0 then ["",""] elif length==1 then
      [.[0].required, (.[0].scripts|length)] else error("multiple") end | @tsv
  ' "${script}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r required total <<< "${script_info}" || return 1
  expected_signatures="$("${wallet_show_jq_path}" -er \
    '[.. | objects | select(.type=="atLeast")] | if length==0 then 0 else ([.[0].scripts[] | select(.type=="sig")] | length) end | tostring' \
    "${script}" 2>/dev/null)" || return 1
  signature_rows="$("${wallet_show_jq_path}" -er \
    '[.. | objects | select(.type=="atLeast")] | if length==0 then "" else ([.[0].scripts[] | select(.type=="sig") | .keyHash] | join("\n")) end' \
    "${script}" 2>/dev/null)" || return 1
  while IFS= read -r signature; do
    [[ -n "${signature}" ]] || continue
    signatures+=("${signature}")
    visited=$((visited + 1))
  done <<< "${signature_rows}"
  [[ "${visited}" == "${expected_signatures}" ]] || return 1
  if [[ -n "${after}" ]]; then
    _cntools_action_wallet_show_integer_valid "${after}" || return 1
    date_value="$(getDateFromSlot "${after}" '%(%F %T %Z)T')" || return 1
    _cntools_action_wallet_show_terminal_value_valid "${date_value}" 128 || return 1
    if [[ "$(getSlotTipRef)" -gt "${after}" ]]; then color="${FG_GREEN}"; else color="${FG_YELLOW}"; fi
    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${color}%s${NC}" \
      'Time Locked Until' "${date_value}")"
  fi
  if [[ -n "${required}" ]]; then
    [[ "${required}" =~ ^[1-9][0-9]*$ && "${total}" =~ ^[1-9][0-9]*$ &&
       "${required}" -le "${total}" && "${total}" -le 64 ]] || return 1
    header="MultiSig Creds (${total})"
    for signature in "${signatures[@]}"; do
      credential=""
      ms_pay_cred=""
      while IFS= read -r -d '' candidate; do
        candidate_name="${candidate##*/}"
        _cntools_action_wallet_show_name_valid "${candidate_name}" || return 1
        if _cntools_action_wallet_show_cache_read \
            "${candidate}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}" \
            credential ms_pay_cred && [[ "${ms_pay_cred}" == "${signature}" ]]; then
          credential=" (${FG_GREEN}${candidate_name}${NC})"
          break
        fi
      done < <("${wallet_show_find_path}" "${wallet_show_wallet_root}" \
        -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C \
        "${wallet_show_sort_path}" -z)
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}%s" \
        "${header}" "${signature}" "${credential}")"
      header=""
    done
    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
      'Required signers' "${required}")"
  fi
}

_cntools_action_wallet_show_pool_name() {
  local target_id="${1:-}" output_name="${2:-}" pool="" name="" id=""

  [[ "${output_name}" == pool_name ]] || return 1
  pool_name=""
  [[ -n "${target_id}" && -d "${POOL_FOLDER:-}" &&
     ! -L "${POOL_FOLDER}" ]] || return 0
  _cntools_registry_path_has_no_symlinks "${POOL_FOLDER}" || return 1
  while IFS= read -r -d '' pool; do
    name="${pool##*/}"
    _cntools_action_wallet_show_name_valid "${name}" || return 1
    if _cntools_action_wallet_show_file_validate \
        "${pool}/${POOL_ID_FILENAME}" '400,444,600,644' 256; then
      id="$(< "${pool}/${POOL_ID_FILENAME}")"
      _cntools_action_wallet_show_pool_valid "${id}" || return 1
      if [[ "${id}" == "${target_id}" ]]; then
        pool_name="${name}"
        break
      fi
    fi
  done < <("${wallet_show_find_path}" "${POOL_FOLDER}" \
    -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C \
    "${wallet_show_sort_path}" -z)
}

_cntools_action_wallet_show_drep_ids() {
  local type="${1:-}" hash="${2:-}"

  [[ "${type}" == keyHash || "${type}" == scriptHash ]] || return 1
  [[ "${hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 1
  getDRepIds "${type}" "${hash}" || return 1
  _cntools_action_wallet_show_terminal_value_valid "${drep_id:-}" 256 &&
    _cntools_action_wallet_show_terminal_value_valid "${drep_id_cip129:-}" 256
}

_cntools_action_wallet_show_find_drep_wallet() {
  local hash="${1:-}" output_name="${2:-}" wallet="" name="" id_file=""
  local id_value="" raw=""

  [[ "${output_name}" == wallet_match && "${hash}" =~ ^[0-9A-Fa-f]{56}$ ]] ||
    return 1
  wallet_match=""
  while IFS= read -r -d '' wallet; do
    name="${wallet##*/}"
    _cntools_action_wallet_show_name_valid "${name}" || return 1
    id_file="${wallet}/${WALLET_GOV_DREP_ID_FILENAME}"
    _cntools_action_wallet_show_file_validate \
      "${id_file}" '400,444,600,644' 256 || continue
    id_value="$(< "${id_file}")"
    _cntools_action_wallet_show_terminal_value_valid "${id_value}" 256 || return 1
    raw="$(bech32 <<< "${id_value}")" || return 1
    [[ "${raw}" =~ ^(22)?([0-9A-Fa-f]{56})$ ]] || return 1
    if [[ "${BASH_REMATCH[2]}" == "${hash}" ]]; then
      wallet_match="${name}"
      break
    fi
  done < <("${wallet_show_find_path}" "${wallet_show_wallet_root}" \
    -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C \
    "${wallet_show_sort_path}" -z)
}

_cntools_action_wallet_show_vote_power_percent() {
  local power="${1:-}" total="${2:-}" output_name="${3:-}" percent=""

  [[ "${output_name}" == wallet_show_vote_power_pct ]] || return 1
  _cntools_action_wallet_show_integer_valid "${power}" &&
    _cntools_action_wallet_show_integer_valid "${total}" || return 1
  if [[ "${power}" == 0 || "${total}" == 0 ]]; then
    wallet_show_vote_power_pct=0.00
    return 0
  fi
  percent="$(${wallet_show_awk_path} -v power="${power}" -v total="${total}" \
    'BEGIN { printf "%.4f", (power * 100) / total }')" || return 1
  [[ "${percent}" =~ ^[0-9]{1,3}[.][0-9]{4}$ ]] || return 1
  while [[ "${percent}" == *0 ]]; do percent="${percent%0}"; done
  [[ "${percent}" == *.* ]] || percent+='.0'
  wallet_show_vote_power_pct="${percent}"
}

_cntools_action_wallet_show_governance_query() {
  local type="${1:-}" hash="${2:-}" response_file="" payload=""
  local parsed="" status="" epoch="" summary_file=""
  local distribution_file="" key=""

  wallet_show_drep_expiry=""
  wallet_show_anchor_url=""
  wallet_show_anchor_hash=""
  wallet_show_vote_power=0
  wallet_show_vote_power_total=0
  wallet_show_vote_power_pct=0.00
  if [[ "${type}" == alwaysAbstain || "${type}" == alwaysNoConfidence ]]; then
    if [[ "${context_mode}" == light ]]; then
      [[ "${type}" == alwaysAbstain ]] && key=drep_always_abstain ||
        key=drep_always_no_confidence
    else
      key="drep-${type}"
    fi
  else
    [[ "${type}" == keyHash || "${type}" == scriptHash ]] || return 1
    [[ "${hash}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 1
  fi

  if [[ "${context_mode}" == light ]]; then
    if [[ -z "${key}" ]]; then
      [[ "${type}" == keyHash ]] && key="$(bech32 drep <<< "22${hash}")" ||
        key="$(bech32 drep <<< "23${hash}")"
      _cntools_action_wallet_show_terminal_value_valid "${key}" 256 || return 1
    fi
    payload='{"_drep_ids":["'${key}'"]}'
    _cntools_action_wallet_show_curl_json drep POST \
      'drep_info?select=drep_status,deposit,active,expires_epoch_no,amount,meta_url,meta_hash' \
      "${payload}" 1048576 response_file || return $?
    "${wallet_show_jq_path}" -e '
      type=="array" and length==1 and (.[0] |
        type=="object" and
        .drep_status=="registered" and
        (.deposit|type=="number" and floor==. and .>=0 and .<=45000000000000000) and
        (.active|type=="boolean") and
        (.expires_epoch_no|type=="number" and floor==. and .>=0 and .<=1000000000) and
        (.amount|type=="number" and floor==. and .>=0 and .<=45000000000000000) and
        ((.meta_url//"")|type=="string" and length<=2048) and
        ((.meta_hash//"")|type=="string" and test("^([0-9A-Fa-f]{64})?$")))
    ' "${response_file}" >/dev/null 2>&1 || return 1
    parsed="$("${wallet_show_jq_path}" -er '
      .[0] | [.drep_status, (.active|tostring),
        (.expires_epoch_no|tostring), (.amount|tostring),
        (.meta_url//""), (.meta_hash//"")] | @tsv
    ' "${response_file}" 2>/dev/null)" || return 1
    IFS=$'\t' read -r status _ wallet_show_drep_expiry \
      wallet_show_vote_power wallet_show_anchor_url wallet_show_anchor_hash \
      <<< "${parsed}" || return 1
    epoch="$(getEpoch)" || return 1
    [[ "${epoch}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
    _cntools_action_wallet_show_curl_json drep-summary GET \
      "drep_epoch_summary?_epoch_no=${epoch}&select=amount" '' \
      1048576 summary_file || return $?
    "${wallet_show_jq_path}" -e '
      type=="array" and length==1 and (.[0] |
        type=="object" and
        (.amount|type=="number" and floor==. and .>=0 and .<=45000000000000000))
    ' "${summary_file}" >/dev/null 2>&1 || return 1
    wallet_show_vote_power_total="$("${wallet_show_jq_path}" -er \
      '.[0].amount|tostring' "${summary_file}" 2>/dev/null)" || return 1
  else
    _cntools_action_wallet_show_private_file_create drep-state response_file ||
      return 70
    if [[ -z "${key}" ]]; then
      println ACTION 'cardano-cli wallet-show DRep state query'
      if [[ "${type}" == keyHash ]]; then
        "${wallet_show_ccli_path}" latest query drep-state \
          --drep-key-hash "${hash}" "${wallet_show_network_args[@]}" \
          > "${response_file}" 2>/dev/null || return 1
      else
        "${wallet_show_ccli_path}" latest query drep-state \
          --drep-script-hash "${hash}" "${wallet_show_network_args[@]}" \
          > "${response_file}" 2>/dev/null || return 1
      fi
      _cntools_action_wallet_show_response_validate \
        "${response_file}" 1048576 || return 1
      "${wallet_show_jq_path}" -e '
        type=="array" and length==1 and (.[0] |
          type=="array" and length==2 and (.[1] |
            type=="object" and
            (.expiry|type=="number" and floor==. and .>=0 and .<=1000000000) and
            ((.anchor.url//"")|type=="string" and length<=2048) and
            ((.anchor.dataHash//"")|type=="string" and test("^([0-9A-Fa-f]{64})?$"))))
      ' "${response_file}" >/dev/null 2>&1 || return 1
      parsed="$("${wallet_show_jq_path}" -er \
        '.[0][1] | [(.expiry|tostring),(.anchor.url//""),(.anchor.dataHash//"")] | @tsv' \
        "${response_file}" 2>/dev/null)" || return 1
      IFS=$'\t' read -r wallet_show_drep_expiry \
        wallet_show_anchor_url wallet_show_anchor_hash <<< "${parsed}" || return 1
    fi
    _cntools_action_wallet_show_private_file_create \
      drep-distribution distribution_file || return 70
    println ACTION 'cardano-cli wallet-show DRep distribution query'
    "${wallet_show_ccli_path}" latest query drep-stake-distribution --all-dreps \
      "${wallet_show_network_args[@]}" > "${distribution_file}" \
      2>/dev/null || return 1
    _cntools_action_wallet_show_response_validate \
      "${distribution_file}" 8388608 || return 1
    "${wallet_show_jq_path}" -e '
      type=="object" and length<=100000 and all(to_entries[];
        (.key|type=="string" and length<=128) and
        (.value|type=="number" and floor==. and .>=0 and .<=45000000000000000))
    ' "${distribution_file}" >/dev/null 2>&1 || return 1
    wallet_show_vote_power_total="$("${wallet_show_jq_path}" -er \
      '[.[]] | add // 0 | tostring' "${distribution_file}" 2>/dev/null)" ||
      return 1
    if [[ -n "${key}" ]]; then
      wallet_show_vote_power="$("${wallet_show_jq_path}" -er --arg key "${key}" \
        '.[$key] // 0 | tostring' "${distribution_file}" 2>/dev/null)" || return 1
    else
      wallet_show_vote_power="$("${wallet_show_jq_path}" -er \
        --arg key "drep-${type}-${hash}" '.[$key] // 0 | tostring' \
        "${distribution_file}" 2>/dev/null)" || return 1
    fi
  fi
  _cntools_action_wallet_show_integer_valid "${wallet_show_vote_power}" &&
    _cntools_action_wallet_show_integer_valid "${wallet_show_vote_power_total}" ||
    return 1
  _cntools_action_wallet_show_vote_power_percent \
    "${wallet_show_vote_power}" "${wallet_show_vote_power_total}" \
    wallet_show_vote_power_pct
}

_cntools_action_wallet_show_anchor_render() {
  local url="${1:-}" expected_hash="${2:-}" response_file="" actual_hash=""

  [[ -n "${url}" ]] || return 0
  [[ "${#url}" -le 2048 && "${url}" == https://* &&
     "${url}" != *[[:space:]]* && "${url}" != *\\* ]] || return 1
  _cntools_action_wallet_show_private_file_create anchor response_file || return 70
  println ACTION 'curl [configured headers redacted] CNTools DRep anchor'
  "${wallet_show_curl_path}" --disable --silent --show-error --location \
    --max-redirs 3 --proto '=https' --proto-redir '=https' \
    --connect-timeout "${wallet_show_curl_timeout}" \
    --max-time "${wallet_show_curl_timeout}" --fail --max-filesize 1048576 \
    --output "${response_file}" --url "${url}" 2>/dev/null || return 1
  _cntools_action_wallet_show_response_validate \
    "${response_file}" 1048576 || return 1
  "${wallet_show_jq_path}" -e \
    'type=="object" and ([..|objects]|length<=10000)' \
    "${response_file}" >/dev/null 2>&1 || return 1
  actual_hash="$("${wallet_show_ccli_path}" hash anchor-data \
    --file-text "${response_file}" 2>/dev/null)" || return 1
  [[ "${actual_hash}" =~ ^[0-9A-Fa-f]{64}$ &&
     "${actual_hash,,}" == "${expected_hash,,}" ]] || return 2
  println "$(printf "%-20s ${FG_DGRAY}:${NC}\n${FG_LGRAY}" \
    'DRep anchor data')"
  "${wallet_show_jq_path}" -S . "${response_file}" || return 1
  println DEBUG "${NC}"
}

_cntools_action_wallet_show_render_governance() {
  local type="" hash="" wallet_match="" expire_status="" formatted=""

  [[ -n "${wallet_show_vote_delegation}" ]] || {
    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC} - %s" \
      Delegation undelegated \
      'please note that reward withdrawals will not work until wallet is vote delegated')"
    return 0
  }
  if [[ "${wallet_show_vote_delegation}" == alwaysAbstain ||
        "${wallet_show_vote_delegation}" == alwaysNoConfidence ]]; then
    type="${wallet_show_vote_delegation}"
    if [[ "${type}" == alwaysAbstain ]]; then
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
        Delegation 'Always abstain')"
    else
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
        Delegation 'Always no confidence')"
    fi
  else
    type="${wallet_show_vote_delegation%%-*}"
    hash="${wallet_show_vote_delegation#*-}"
    _cntools_action_wallet_show_drep_ids "${type}" "${hash}" || return 1
    _cntools_action_wallet_show_find_drep_wallet \
      "${hash}" wallet_match || return 1
    println "$(printf "%-20s ${FG_DGRAY}: CIP-105 =>${NC} ${FG_LGRAY}%s${NC}" \
      Delegation "${drep_id}")"
    println "$(printf "%-20s ${FG_DGRAY}: CIP-129 =>${NC} ${FG_LGRAY}%s${NC}" \
      '' "${drep_id_cip129}")"
    [[ -z "${wallet_match}" ]] || println "$(printf \
      "%-20s ${FG_DGRAY}: Wallet  =>${NC} ${FG_GREEN}%s${NC}" '' "${wallet_match}")"
    if [[ "${type}" == keyHash ]]; then
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
        'DRep Type' Key)"
    else
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
        'DRep Type' MultiSig)"
    fi
  fi
  _cntools_action_wallet_show_governance_query "${type}" "${hash}" || return 1
  if [[ -n "${wallet_show_drep_expiry}" && "${type}" != always* ]]; then
    if [[ "$(getEpoch)" -lt "${wallet_show_drep_expiry}" ]]; then
      expire_status="${FG_GREEN}active${NC}"
    else
      expire_status="${FG_RED}inactive${NC} (vote power does not count)"
    fi
    println "$(printf "%-20s ${FG_DGRAY}:${NC} epoch ${FG_LBLUE}%s${NC} - %s" \
      'DRep expiry' "${wallet_show_drep_expiry}" "${expire_status}")"
    if [[ -n "${wallet_show_anchor_url}" ]]; then
      _cntools_action_wallet_show_terminal_value_valid \
        "${wallet_show_anchor_url}" 2048 || return 1
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
        'DRep anchor url' "${wallet_show_anchor_url}")"
      if ! _cntools_action_wallet_show_anchor_render \
          "${wallet_show_anchor_url}" "${wallet_show_anchor_hash}"; then
        println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_YELLOW}%s${NC}" \
          'DRep anchor data' 'Invalid URL, content, hash, or currently not available')"
      fi
    fi
  fi
  _cntools_action_wallet_show_formatted_lovelace \
    "${wallet_show_vote_power}" formatted || return 1
  println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA (${FG_LBLUE}%s${NC} %%)" \
    'Active Vote power' "${formatted}" "${wallet_show_vote_power_pct}")"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local context_mode="" context_network="" network_magic="" filename=""
  local action_status=0 cache_status=0
  local wallet_show_wallet_root="" selected_wallet=""
  local base_addr="" pay_addr="" reward_addr="" query_status=0
  local pay_cred="" stake_cred="" ms_pay_cred="" ms_stake_cred=""
  local script_pay_cred="" script_stake_cred="" pool_name=""
  local derivation_path="" formatted="" total_lovelace=0
  local wallet_show_wallet_type="" wallet_show_drep_raw=""
  local wallet_show_private_parent="" wallet_show_terminal_saved=N
  local wallet_show_koios_api="" wallet_show_curl_timeout=""
  local wallet_show_registered=no wallet_show_reward_lovelace=0
  local wallet_show_stake_deposit=0 wallet_show_pool_delegation=""
  local wallet_show_vote_delegation="" wallet_show_drep_expiry=""
  local wallet_show_anchor_url="" wallet_show_anchor_hash=""
  local wallet_show_vote_power=0 wallet_show_vote_power_total=0
  local wallet_show_vote_power_pct=0.00
  local wallet_show_jq_path="" wallet_show_mktemp_path=""
  local wallet_show_chmod_path="" wallet_show_rm_path=""
  local wallet_show_ln_path="" wallet_show_find_path=""
  local wallet_show_sort_path="" wallet_show_curl_path=""
  local wallet_show_awk_path="" wallet_show_tr_path=""
  local wallet_show_ccli_path=""
  local header_index=0 header_value=""
  local -a wallet_show_temp_files=() wallet_show_network_args=()
  local -a wallet_show_koios_headers=()
  local -A wallet_show_utxos=() wallet_show_utxo_counts=()
  local -A wallet_show_assets=()

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
     ! builtin declare -F selectWallet >/dev/null 2>&1 ||
     ! builtin declare -F getPriceInfo >/dev/null 2>&1 ||
     ! builtin declare -F getPriceString >/dev/null 2>&1 ||
     ! builtin declare -F formatLovelace >/dev/null 2>&1 ||
     ! builtin declare -F formatAsset >/dev/null 2>&1 ||
     ! builtin declare -F hexToAscii >/dev/null 2>&1 ||
     ! builtin declare -F getAssetIDBech32 >/dev/null 2>&1 ||
     ! builtin declare -F getDateFromSlot >/dev/null 2>&1 ||
     ! builtin declare -F getSlotTipRef >/dev/null 2>&1 ||
     ! builtin declare -F getEpoch >/dev/null 2>&1 ||
     ! builtin declare -F getDRepIds >/dev/null 2>&1 ||
     ! builtin declare -F bech32 >/dev/null 2>&1 ||
     ! builtin declare -F versionCheck >/dev/null 2>&1; then
    _cntools_action_wallet_show_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  if [[ "${context_mode}" == local ]] &&
     ! cntools_context_has "${context_file}" capabilities local-cli; then
    _cntools_action_wallet_show_validation_failure
    return 70
  fi
  for filename in jq mktemp chmod rm ln find sort awk tr; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq wallet_show_jq_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp wallet_show_mktemp_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod wallet_show_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm wallet_show_rm_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln wallet_show_ln_path || action_status=70 ;;
      find) _cntools_registry_tool_path find wallet_show_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort wallet_show_sort_path || action_status=70 ;;
      awk) _cntools_registry_tool_path awk wallet_show_awk_path || action_status=70 ;;
      tr) _cntools_registry_tool_path tr wallet_show_tr_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  wallet_show_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${wallet_show_private_parent}" || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  [[ "${WALLET_FOLDER}" == /* && -d "${WALLET_FOLDER}" &&
     ! -L "${WALLET_FOLDER}" ]] || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  _cntools_registry_path_has_no_symlinks "${WALLET_FOLDER}" || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  wallet_show_wallet_root="$(cd -P -- "${WALLET_FOLDER}" && pwd -P)" || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  for filename in "${WALLET_PAY_VK_FILENAME}" \
      "${WALLET_STAKE_VK_FILENAME}" "${WALLET_PAY_SCRIPT_FILENAME}" \
      "${WALLET_STAKE_SCRIPT_FILENAME}" "${WALLET_PAY_ADDR_FILENAME}" \
      "${WALLET_BASE_ADDR_FILENAME}" "${WALLET_STAKE_ADDR_FILENAME}" \
      "${WALLET_PAY_CRED_FILENAME}" "${WALLET_STAKE_CRED_FILENAME}" \
      "${WALLET_PAY_SCRIPT_CRED_FILENAME}" \
      "${WALLET_STAKE_SCRIPT_CRED_FILENAME}" \
      "${WALLET_DERIVATION_PATH_FILENAME}" "${WALLET_GOV_DREP_SCRIPT_FILENAME}" \
      "${WALLET_GOV_DREP_ID_FILENAME}" "${POOL_ID_FILENAME}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9._-]{1,128}$ &&
       "${filename}" != . && "${filename}" != .. ]] || {
      _cntools_action_wallet_show_validation_failure; return 70; }
  done
  [[ "${WALLET_MULTISIG_PREFIX}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  case "${NETWORK_IDENTIFIER}" in
    --mainnet) wallet_show_network_args=(--mainnet) ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 ]] || {
        _cntools_action_wallet_show_validation_failure; return 70; }
      wallet_show_network_args=(--testnet-magic "${network_magic}")
      ;;
    *) _cntools_action_wallet_show_validation_failure; return 70 ;;
  esac
  if [[ "${context_network}" == mainnet &&
        "${wallet_show_network_args[0]}" != --mainnet ]] ||
     [[ "${context_network}" != mainnet &&
        "${wallet_show_network_args[0]}" != --testnet-magic ]]; then
    _cntools_action_wallet_show_validation_failure
    return 70
  fi
  wallet_show_ccli_path="$(builtin type -P "${CCLI:-}" 2>/dev/null)" || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  [[ "${wallet_show_ccli_path}" == /* && -x "${wallet_show_ccli_path}" ]] || {
    _cntools_action_wallet_show_validation_failure; return 70; }
  if [[ "${context_mode}" != offline ]]; then
    wallet_show_curl_timeout="${CURL_TIMEOUT:-10}"
    [[ "${wallet_show_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] || {
      _cntools_action_wallet_show_validation_failure; return 70; }
    _cntools_registry_tool_path curl wallet_show_curl_path || {
      _cntools_action_wallet_show_validation_failure; return 70; }
  fi
  if [[ "${context_mode}" == light ]]; then
    wallet_show_koios_api="${KOIOS_API%/}"
    [[ "${#wallet_show_koios_api}" -ge 9 &&
       "${#wallet_show_koios_api}" -le 2048 &&
       "${wallet_show_koios_api}" == https://* &&
       "${wallet_show_koios_api}" != *[[:space:]]* &&
       "${wallet_show_koios_api}" != *'?'* &&
       "${wallet_show_koios_api}" != *'#'* &&
       "${wallet_show_koios_api}" != *\\* ]] || {
      _cntools_action_wallet_show_validation_failure; return 70; }
    wallet_show_koios_headers=("${KOIOS_API_HEADERS[@]}")
    (( ${#wallet_show_koios_headers[@]} % 2 == 0 &&
       ${#wallet_show_koios_headers[@]} <= 8 )) || {
      _cntools_action_wallet_show_validation_failure; return 70; }
    for ((header_index=0; header_index<${#wallet_show_koios_headers[@]};
        header_index+=2)); do
      header_value="${wallet_show_koios_headers[header_index+1]}"
      [[ ( "${wallet_show_koios_headers[header_index]}" == -H ||
           "${wallet_show_koios_headers[header_index]}" == --header ) &&
         "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
         "${header_value}" == *:* && "${header_value}" != *$'\r'* &&
         "${header_value}" != *$'\n'* ]] || {
        _cntools_action_wallet_show_validation_failure; return 70; }
    done
  elif [[ -n "${KOIOS_API:-}" ]]; then
    _cntools_action_wallet_show_validation_failure
    return 70
  fi

  umask 077
  trap '_cntools_action_wallet_show_cleanup' EXIT
  trap '_cntools_action_wallet_show_cleanup; exit 70' HUP INT TERM
  clear
  [[ "${context_mode}" == offline ]] || getPriceInfo
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> WALLET >> SHOW'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  if [[ -z "$("${wallet_show_find_path}" "${wallet_show_wallet_root}" \
      -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)" ]]; then
    echo
    println "${FG_YELLOW}No wallets available!${NC}"
    waitToProceed
    _cntools_action_wallet_show_cleanup || action_status=70
    trap - EXIT HUP INT TERM
    [[ "${action_status}" == 0 ]] || _cntools_action_wallet_show_validation_failure
    return "${action_status}"
  fi
  if [[ "${context_mode}" == offline ]]; then
    println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, limited wallet info shown!"
  fi
  if tput sc >/dev/null 2>&1; then wallet_show_terminal_saved=Y; fi
  if selectWallet none; then
    action_status=0
  else
    action_status=$?
  fi
  _cntools_action_wallet_show_terminal_restore || action_status=70
  case "${action_status}" in
    0) ;;
    1) waitToProceed; action_status=0 ;;
    2) action_status=0 ;;
    *) action_status=70 ;;
  esac
  if [[ "${action_status}" != 0 || -z "${wallet_name:-}" ]]; then
    _cntools_action_wallet_show_cleanup || action_status=70
    trap - EXIT HUP INT TERM
    [[ "${action_status}" == 0 ]] || _cntools_action_wallet_show_validation_failure
    return "${action_status}"
  fi
  _cntools_action_wallet_show_name_valid "${wallet_name}" || {
    _cntools_action_wallet_show_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_show_validation_failure
    return 70
  }
  selected_wallet="${wallet_show_wallet_root}/${wallet_name}"
  [[ -d "${selected_wallet}" && ! -L "${selected_wallet}" ]] &&
    _cntools_registry_path_has_no_symlinks "${selected_wallet}" &&
    [[ "$(cd -P -- "${selected_wallet}" && pwd -P)" == "${selected_wallet}" ]] || {
      _cntools_action_wallet_show_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_show_validation_failure
      return 70
    }
  if [[ -n "$("${wallet_show_find_path}" "${selected_wallet}" \
      -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print -quit 2>/dev/null)" ]]; then
    println "Wallet: ${FG_GREEN}${wallet_name}${NC} (${FG_YELLOW}encrypted${NC})"
  else
    println "Wallet: ${FG_GREEN}${wallet_name}${NC}"
  fi
  if _cntools_action_wallet_show_cache_resolve \
      "${selected_wallet}" base base_addr; then :; else
    cache_status=$?
    [[ "${cache_status}" != 70 ]] || action_status=70
    base_addr=""
  fi
  if _cntools_action_wallet_show_cache_resolve \
      "${selected_wallet}" payment pay_addr; then :; else
    cache_status=$?
    [[ "${cache_status}" != 70 ]] || action_status=70
    pay_addr=""
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_show_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_show_validation_failure
    return 70
  fi
  if [[ -z "${base_addr}" && -z "${pay_addr}" ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: wallet missing pay/base addr files or vkey/script files to generate them!"
    waitToProceed
    _cntools_action_wallet_show_cleanup || action_status=70
    trap - EXIT HUP INT TERM
    [[ "${action_status}" == 0 ]] || _cntools_action_wallet_show_validation_failure
    return "${action_status}"
  fi
  if _cntools_action_wallet_show_cache_resolve \
      "${selected_wallet}" reward reward_addr; then :; else
    cache_status=$?
    [[ "${cache_status}" != 70 ]] || action_status=70
    reward_addr=""
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_show_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_show_validation_failure
    return 70
  fi

  if [[ "${context_mode}" != offline ]]; then
    if [[ "${context_mode}" == light ]]; then
      if tput sc >/dev/null 2>&1; then wallet_show_terminal_saved=Y; fi
      println OFF "\n${FG_YELLOW}> Querying Koios API for wallet information${NC}"
    fi
    if _cntools_action_wallet_show_query_all; then query_status=0; else query_status=$?; fi
    _cntools_action_wallet_show_terminal_restore || query_status=70
    if [[ "${query_status}" != 0 ]]; then
      wallet_show_utxos=(); wallet_show_utxo_counts=(); wallet_show_assets=()
      println ERROR "\n${FG_RED}ERROR${NC}: wallet information query failed; no wallet balances were displayed."
      waitToProceed
      _cntools_action_wallet_show_cleanup || action_status=70
      trap - EXIT HUP INT TERM
      if [[ "${query_status}" == 70 || "${action_status}" == 70 ]]; then
        _cntools_action_wallet_show_validation_failure
        return 70
      fi
      return 0
    fi
    [[ -z "${base_addr}" ]] ||
      _cntools_action_wallet_show_render_address "${base_addr}" Base || action_status=70
    [[ -z "${pay_addr}" || "${wallet_show_utxo_counts[${pay_addr}]:-0}" == 0 ]] ||
      _cntools_action_wallet_show_render_address "${pay_addr}" Payment || action_status=70
    [[ "${action_status}" == 0 ]] || {
      _cntools_action_wallet_show_cleanup || true
      trap - EXIT HUP INT TERM
      _cntools_action_wallet_show_validation_failure
      return 70
    }
    println DEBUG '\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
    if [[ "${wallet_show_registered}" == yes ]]; then
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_GREEN}%s${NC}" Registered Yes)"
    else
      println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_RED}%s${NC}" Registered No)"
    fi
  else
    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" Registered Unknown)"
  fi

  _cntools_action_wallet_show_wallet_type "${selected_wallet}" || action_status=70
  if [[ -n "${wallet_show_wallet_type}" ]]; then
    println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
      Type "${wallet_show_wallet_type}")"
  fi
  filename="${selected_wallet}/${WALLET_DERIVATION_PATH_FILENAME}"
  if [[ -e "${filename}" || -L "${filename}" ]]; then
    _cntools_action_wallet_show_file_validate \
      "${filename}" '400,444,600,644' 256 || action_status=70
    derivation_path="$(< "${filename}")"
    [[ "${derivation_path}" =~ ^[0-9]{1,10}H(/[0-9]{1,10}H?){4,10}$ ]] ||
      action_status=70
    [[ "${action_status}" != 0 ]] || println "$(printf \
      "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
      'Derivation Path' "${derivation_path}")"
  fi
  [[ "${action_status}" != 0 ]] ||
    _cntools_action_wallet_show_render_script "${selected_wallet}" || action_status=70

  [[ -n "${base_addr}" ]] && println "$(printf \
    "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" Address "${base_addr}")"
  [[ -z "${pay_addr}" ]] || println "$(printf \
    "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" 'Payment Address' "${pay_addr}")"
  [[ -n "${reward_addr}" ]] && println "$(printf \
    "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" \
    'Reward/Stake Address' "${reward_addr}")"
  if _cntools_action_wallet_show_cache_resolve \
      "${selected_wallet}" paycredential pay_cred; then :; else
    cache_status=$?; [[ "${cache_status}" != 70 ]] || action_status=70
    pay_cred=""
  fi
  if _cntools_action_wallet_show_cache_resolve \
      "${selected_wallet}" stakecredential stake_cred; then :; else
    cache_status=$?; [[ "${cache_status}" != 70 ]] || action_status=70
    stake_cred=""
  fi
  if _cntools_action_wallet_show_cache_resolve \
      "${selected_wallet}" scriptpaycredential script_pay_cred; then :; else
    cache_status=$?; [[ "${cache_status}" != 70 ]] || action_status=70
    script_pay_cred=""
  fi
  if _cntools_action_wallet_show_cache_resolve \
      "${selected_wallet}" scriptstakecredential script_stake_cred; then :; else
    cache_status=$?; [[ "${cache_status}" != 70 ]] || action_status=70
    script_stake_cred=""
  fi
  filename="${selected_wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
  if [[ -e "${filename}" || -L "${filename}" ]]; then
    _cntools_action_wallet_show_cache_read \
      "${filename}" credential ms_pay_cred || action_status=70
  fi
  filename="${selected_wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"
  if [[ -e "${filename}" || -L "${filename}" ]]; then
    _cntools_action_wallet_show_cache_read \
      "${filename}" credential ms_stake_cred || action_status=70
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_show_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_show_validation_failure
    return 70
  fi
  if [[ -n "${pay_cred}${stake_cred}${ms_pay_cred}${ms_stake_cred}${script_pay_cred}${script_stake_cred}" ]]; then
    println "${FG_DGRAY}# Credentials${NC}"
  fi
  [[ -z "${pay_cred}" ]] || println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" Payment "${pay_cred}")"
  [[ -z "${stake_cred}" ]] || println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" Stake "${stake_cred}")"
  [[ -z "${ms_pay_cred}" ]] || println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" 'MultiSig Payment' "${ms_pay_cred}")"
  [[ -z "${ms_stake_cred}" ]] || println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" 'MultiSig Stake' "${ms_stake_cred}")"
  [[ -z "${script_pay_cred}" ]] || println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" 'Script Payment' "${script_pay_cred}")"
  [[ -z "${script_stake_cred}" ]] || println "$(printf "%-20s ${FG_DGRAY}:${NC} ${FG_LGRAY}%s${NC}" 'Script Stake' "${script_stake_cred}")"

  if [[ "${context_mode}" != offline ]]; then
    println "${FG_DGRAY}# Funds${NC}"
    total_lovelace=0
    [[ -z "${base_addr}" ]] || _cntools_action_wallet_show_integer_add \
      "${total_lovelace}" "${wallet_show_assets[${base_addr},lovelace]:-0}" \
      total_lovelace || action_status=70
    [[ -z "${pay_addr}" ]] || _cntools_action_wallet_show_integer_add \
      "${total_lovelace}" "${wallet_show_assets[${pay_addr},lovelace]:-0}" \
      total_lovelace || action_status=70
    if [[ -n "${reward_addr}" ]]; then
      _cntools_action_wallet_show_integer_add "${total_lovelace}" \
        "${wallet_show_reward_lovelace}" total_lovelace || action_status=70
      getPriceString "${wallet_show_reward_lovelace}"
      _cntools_action_wallet_show_styled_value_valid "${price_str:-}" 256 ||
        action_status=70
      _cntools_action_wallet_show_formatted_lovelace \
        "${wallet_show_reward_lovelace}" formatted || action_status=70
      [[ "${action_status}" != 0 ]] || println "$(printf \
        "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA%s" \
        'Rewards Available' "${formatted}" "${price_str:-}")"
    fi
    getPriceString "${total_lovelace}"
    _cntools_action_wallet_show_styled_value_valid "${price_str:-}" 256 ||
      action_status=70
    _cntools_action_wallet_show_formatted_lovelace \
      "${total_lovelace}" formatted || action_status=70
    [[ "${action_status}" != 0 ]] || println "$(printf \
      "%-20s ${FG_DGRAY}:${NC} ${FG_LBLUE}%s${NC} ADA%s" \
      'Funds + Rewards' "${formatted}" "${price_str:-}")"
    if [[ -n "${wallet_show_pool_delegation}" ]]; then
      _cntools_action_wallet_show_pool_name \
        "${wallet_show_pool_delegation}" pool_name || action_status=70
      [[ "${action_status}" != 0 ]] || {
        echo
        println "${FG_RED}Delegated${NC} to ${FG_GREEN}${pool_name}${NC} ${FG_LGRAY}(${wallet_show_pool_delegation})${NC}"
      }
    fi
  fi
  [[ -n "${pay_addr}" ]] || println \
    "\n${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_PAY_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_PAY_VK_FILENAME}${NC}' to generate it!"
  [[ -n "${base_addr}" ]] || println \
    "\n${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_BASE_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_PAY_VK_FILENAME}${NC}/${FG_LGRAY}${WALLET_STAKE_VK_FILENAME}${NC}' to generate it!"
  [[ -n "${reward_addr}" ]] || println \
    "\n${FG_YELLOW}INFO${NC}: '${FG_LGRAY}${WALLET_STAKE_ADDR_FILENAME}${NC}' missing and '${FG_LGRAY}${WALLET_STAKE_VK_FILENAME}${NC}' to generate it!"

  filename="${selected_wallet}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
  if [[ -e "${filename}" || -L "${filename}" ]]; then
    _cntools_action_wallet_show_input_usable "${filename}" || action_status=70
  fi
  if [[ "${action_status}" == 0 && "${context_mode}" != offline &&
        ! -e "${filename}" ]] &&
     versionCheck 9.0 "${PROT_VERSION}"; then
    println DEBUG '\nGovernance Vote Delegation Status'
    _cntools_action_wallet_show_render_governance || action_status=70
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_wallet_show_cleanup || true
    trap - EXIT HUP INT TERM
    _cntools_action_wallet_show_validation_failure
    return 70
  fi
  waitToProceed
  _cntools_action_wallet_show_cleanup || action_status=70
  trap - EXIT HUP INT TERM
  [[ "${action_status}" == 0 ]] || _cntools_action_wallet_show_validation_failure
  return "${action_status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
