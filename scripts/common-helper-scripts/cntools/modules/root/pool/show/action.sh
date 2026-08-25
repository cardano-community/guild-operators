#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154
# Stage 4 compatibility action for the characterized pool detail view.
# All remote and node responses are bounded and parsed before display. Pool IDs
# are resolved in memory; this read-only action never materializes cache files.

_cntools_action_pool_show_validation_failure() {
  builtin printf '%s\n' 'CNTools pool-show action failed validation.' >&2
  return 70
}

_cntools_action_pool_show_cleanup() {
  local target="" failed=0

  for target in "${pool_show_temp_files[@]:-}"; do
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${pool_show_rm_path}" -f -- "${target}" >/dev/null 2>&1 || failed=1
    fi
  done
  pool_show_temp_files=()
  return "${failed}"
}

_cntools_action_pool_show_finish() {
  local status="${1:-70}"

  _cntools_action_pool_show_cleanup || status=70
  trap - EXIT HUP INT TERM
  if (( status == 70 )); then
    _cntools_action_pool_show_validation_failure
  fi
  return "${status}"
}

_cntools_action_pool_show_component_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._+@:-]{1,128}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_pool_show_file_validate() {
  local target="${1:-}" expected_modes="${2:-}" maximum_size="${3:-}"
  local minimum_size="${4:-1}" metadata="" owner="" mode="" links="" size=""

  [[ -f "${target}" && ! -L "${target}" &&
     "${maximum_size}" =~ ^[1-9][0-9]*$ &&
     "${minimum_size}" =~ ^[0-9]+$ ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${size}" =~ ^[0-9]+$ && "${size}" -ge "${minimum_size}" &&
     "${size}" -le "${maximum_size}" &&
     ",${expected_modes}," == *",${mode},"* ]]
}

_cntools_action_pool_show_private_file_create() {
  local output_variable="${1:-}" label="${2:-response}" created=""

  case "${output_variable}" in
    pool_show_response_file|pool_show_auxiliary_file|pool_show_directory_file) ;;
    *) return 1 ;;
  esac
  [[ "${label}" =~ ^[a-z-]{1,32}$ ]] || return 1
  created="$("${pool_show_mktemp_path}" \
    "${pool_show_private_parent}/pool-show-${label}.XXXXXXXX")" || return 1
  pool_show_temp_files+=("${created}")
  "${pool_show_chmod_path}" 0600 "${created}" || return 1
  printf -v "${output_variable}" '%s' "${created}"
}

_cntools_action_pool_show_pool_id_valid() {
  local kind="${1:-}" value="${2:-}"

  case "${kind}" in
    hex) [[ "${value}" =~ ^[0-9A-Fa-f]{56}$ ]] ;;
    bech32) [[ "${value}" =~ ^pool1[023456789ac-hj-np-z]{20,100}$ ]] ;;
    *) return 1 ;;
  esac
}

_cntools_action_pool_show_ccli_resolve() {
  [[ -n "${pool_show_ccli_path}" ]] && return 0
  pool_show_ccli_path="$(builtin type -P "${CCLI:-}" 2>/dev/null)" || return 1
  [[ "${pool_show_ccli_path}" == /* && -x "${pool_show_ccli_path}" ]]
}

_cntools_action_pool_show_id_resolve() {
  local cold_key="${pool_show_pool_directory}/${POOL_COLDKEY_VK_FILENAME}"
  local derived_hex="" derived_bech32=""

  _cntools_action_pool_show_file_validate \
    "${cold_key}" '400,444,600,644' 65536 || return 1
  _cntools_action_pool_show_ccli_resolve || return 1
  println ACTION 'cardano-cli pool-show ID derivation'
  derived_hex="$("${pool_show_ccli_path}" latest stake-pool id \
    --cold-verification-key-file "${cold_key}" --output-format hex \
    2>/dev/null)" || return 1
  derived_bech32="$("${pool_show_ccli_path}" latest stake-pool id \
    --cold-verification-key-file "${cold_key}" 2>/dev/null)" || return 1
  _cntools_action_pool_show_pool_id_valid hex "${derived_hex}" || return 1
  _cntools_action_pool_show_pool_id_valid bech32 "${derived_bech32}" || return 1
  pool_id="${derived_hex}"
  pool_id_bech32="${derived_bech32}"
}

_cntools_action_pool_show_https_valid() {
  local value="${1:-}"

  [[ "${#value}" -ge 9 && "${#value}" -le 2048 &&
     "${value}" == https://* && "${value}" != *'?'* &&
     "${value}" != *'#'* && "${value}" != *\\* &&
     ! "${value}" =~ [[:cntrl:][:space:]] ]]
}

_cntools_action_pool_show_response_validate() {
  local target="${1:-}" maximum_size="${2:-}"

  _cntools_action_pool_show_file_validate \
    "${target}" '600' "${maximum_size}" 1
}

_cntools_action_pool_show_koios_query() {
  local endpoint="${1:-}" payload="${2:-}" maximum_size="${3:-262144}"
  local method="${4:-auto}"
  local -a command_arguments=()

  [[ "${endpoint}" =~ ^/[a-z_]{1,64}(\?[A-Za-z0-9_.=-]{1,255})?$ &&
     "${maximum_size}" =~ ^[1-9][0-9]*$ &&
     ( "${method}" == auto || "${method}" == post ) ]] || return 70
  pool_show_response_file=""
  _cntools_action_pool_show_private_file_create \
    pool_show_response_file koios || return 70
  command_arguments=(
    "${pool_show_curl_path}"
    --disable --silent --show-error --location --max-redirs 3
    --proto '=https' --proto-redir '=https'
    --connect-timeout "${pool_show_curl_timeout}"
    --max-time "${pool_show_curl_timeout}"
    --fail --max-filesize "${maximum_size}"
    "${pool_show_koios_headers[@]}"
    --header 'Accept: application/json'
  )
  if [[ -n "${payload}" ]]; then
    command_arguments+=(
      --header 'Content-Type: application/json'
      --data "${payload}"
    )
  elif [[ "${method}" == post ]]; then
    command_arguments+=(--request POST)
  fi
  command_arguments+=(
    --output "${pool_show_response_file}"
    --url "${pool_show_koios_api}${endpoint}"
  )
  println ACTION 'curl [configured headers redacted] CNTools pool-show query'
  "${command_arguments[@]}" 2>/dev/null || return 1
  _cntools_action_pool_show_response_validate \
    "${pool_show_response_file}" "${maximum_size}" || return 2
}

_cntools_action_pool_show_metadata_schema() {
  local target="${1:-}"

  "${pool_show_jq_path}" -e '
    def plain($minimum; $maximum):
      type == "string" and length >= $minimum and length <= $maximum and
      test("^[ -~]+$") and (contains("\\") | not);
    type == "object" and
    (.name | plain(1; 50)) and
    (.ticker | plain(1; 5) and test("^[A-Za-z0-9._-]+$")) and
    (.homepage | plain(1; 128) and startswith("https://")) and
    (.description | plain(1; 255))
  ' "${target}" >/dev/null 2>&1
}

_cntools_action_pool_show_metadata_read() {
  local target="${1:-}" record=""

  _cntools_action_pool_show_file_validate \
    "${target}" '400,444,600,644' 16384 || return 1
  _cntools_action_pool_show_metadata_schema "${target}" || return 1
  record="$("${pool_show_jq_path}" -er \
    '[.name,.ticker,.homepage,.description] | @tsv' "${target}")" ||
    return 1
  IFS=$'\t' read -r metadata_name metadata_ticker metadata_homepage \
    metadata_description <<< "${record}" || return 1
}

_cntools_action_pool_show_metadata_download() {
  local url="${1:-}" target="" metadata="" owner="" mode="" links="" size=""
  local -a command_arguments=()

  _cntools_action_pool_show_https_valid "${url}" || return 2
  pool_show_response_file=""
  _cntools_action_pool_show_private_file_create \
    pool_show_response_file metadata || return 70
  target="${pool_show_response_file}"
  command_arguments=(
    "${pool_show_curl_path}"
    --disable --silent --show-error --location --max-redirs 3
    --proto '=https' --proto-redir '=https'
    --connect-timeout "${pool_show_curl_timeout}"
    --max-time "${pool_show_curl_timeout}"
    --fail --max-filesize 16384
    --header 'Accept: application/json'
    --output "${target}" --url "${url}"
  )
  println ACTION 'curl CNTools pool-show metadata query'
  "${command_arguments[@]}" 2>/dev/null || return 1
  _cntools_action_pool_show_response_validate "${target}" 16384 || return 1
  _cntools_action_pool_show_metadata_schema "${target}" || return 2
  pool_show_metadata_file="${target}"
}

_cntools_action_pool_show_metadata_hash() {
  local target="${1:-}" output_variable="${2:-}" value=""

  case "${output_variable}" in
    metadata_hash|metadata_hash_url) ;;
    *) return 1 ;;
  esac
  _cntools_action_pool_show_ccli_resolve || return 1
  value="$("${pool_show_ccli_path}" latest stake-pool metadata-hash \
    --pool-metadata-file "${target}" 2>/dev/null)" || return 1
  [[ "${value}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf -v "${output_variable}" '%s' "${value}"
}

_cntools_action_pool_show_config_validate() {
  local target="${1:-}"

  _cntools_action_pool_show_file_validate \
    "${target}" '400,444,600,644' 262144 || return 1
  "${pool_show_jq_path}" -e '
    def component:
      type == "string" and length >= 1 and length <= 128 and
      test("^[A-Za-z0-9._+@:-]+$") and . != "." and . != "..";
    def decimal:
      type == "number" and . >= 0 and . <= 45000000;
    def relay:
      type == "object" and keys == ["address","port","type"] and
      (.type | type == "string" and length >= 1 and length <= 32 and
        test("^[A-Za-z0-9_-]+$")) and
      (.address | type == "string" and length >= 1 and length <= 255 and
        test("^[A-Za-z0-9.:-]+$")) and
      (.port | type == "number" and floor == . and . >= 0 and . <= 65535);
    type == "object" and
    ((keys - ["costADA","json_url","margin","pledgeADA","pledgeWallet",
      "relays","rewardWallet"]) | length == 0) and
    (.json_url | type == "string" and length >= 9 and length <= 2048 and
      startswith("https://") and test("^[!-~]+$") and
      (contains("\\") | not)) and
    (.pledgeADA | decimal) and (.margin | decimal and . <= 100) and
    (.costADA | decimal) and (.pledgeWallet | component) and
    (.rewardWallet | component) and
    (.relays | type == "array" and length <= 100 and all(.[]; relay))
  ' "${target}" >/dev/null 2>&1
}

_cntools_action_pool_show_local_query() {
  local pool_state_file="" default_vote_file="" vote=""

  _cntools_action_pool_show_ccli_resolve || return 70
  pool_show_response_file=""
  _cntools_action_pool_show_private_file_create \
    pool_show_response_file pool-state || return 70
  pool_state_file="${pool_show_response_file}"
  println ACTION 'cardano-cli pool-show local pool-state query'
  "${pool_show_ccli_path}" query pool-state --stake-pool-id \
    "${pool_id_bech32}" "${pool_show_network_arguments[@]}" \
    > "${pool_state_file}" 2>/dev/null || return 1
  _cntools_action_pool_show_response_validate \
    "${pool_state_file}" 1048576 || return 2
  "${pool_show_jq_path}" -e --arg id "${pool_id_bech32}" '
    def token:
      type == "string" and length >= 1 and length <= 256 and
      test("^[A-Za-z0-9._:+@-]+$");
    def dns:
      type == "string" and length >= 1 and length <= 253 and
      test("^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$");
    def ipv4:
      type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") and
      (split(".") | length == 4 and all(.[]; (tonumber >= 0 and tonumber <= 255)));
    def ipv6:
      type == "string" and length >= 2 and length <= 45 and
      test("^[0-9A-Fa-f:]+$") and contains(":");
    def uint:
      type == "number" and floor == . and . >= 0 and . <= 45000000000000000;
    def port: . == null or (type == "number" and floor == . and . >= 1 and . <= 65535);
    def relay:
      type == "object" and
      ((keys == ["single host name"] and
        (. ["single host name"] |
          type == "object" and keys == ["dnsName","port"] and
          (.dnsName | dns) and (.port | port))) or
       (keys == ["single host address"] and
        (. ["single host address"] |
          type == "object" and
          ((keys == ["IPv4","port"] and (.IPv4 | ipv4) and (.port | port)) or
           (keys == ["IPv6","port"] and (.IPv6 | ipv6) and (.port | port))))));
    def metadata:
      . == null or
      (type == "object" and keys == ["hash","url"] and
       (.url | type == "string" and length >= 9 and length <= 2048 and
         startswith("https://") and test("^[!-~]+$") and
         (contains("\\") | not)) and
       (.hash | type == "string" and test("^[0-9A-Fa-f]{64}$")));
    def params:
      type == "object" and
      (.spsPledge | uint) and
      (.spsMargin | type == "number" and . >= 0 and . <= 1) and
      (.spsCost | uint) and
      (.spsRelays | type == "array" and length <= 100 and all(.[]; relay)) and
      (.spsOwners | type == "array" and length <= 100 and
        length == (unique | length) and all(.[]; token)) and
      (.spsAccountId | type == "object" and (.keyHash | token)) and
      (.spsMetadata | metadata);
    type == "object" and keys == [$id] and
    (.[$id] | type == "object" and
      (.poolParams == null or (.poolParams | params)) and
      (.futurePoolParams == null or (.futurePoolParams | params)) and
      (.retiring == null or
        (.retiring | type == "number" and floor == . and . >= 0 and
          . <= 2147483647)))
  ' "${pool_state_file}" >/dev/null 2>&1 || return 2
  pool_show_current_params="$("${pool_show_jq_path}" -cer \
    --arg id "${pool_id_bech32}" '.[$id].poolParams // empty' \
    "${pool_state_file}")" || pool_show_current_params=""
  pool_show_future_params="$("${pool_show_jq_path}" -cer \
    --arg id "${pool_id_bech32}" '.[$id].futurePoolParams // empty' \
    "${pool_state_file}")" || pool_show_future_params=""
  pool_show_retiring_epoch="$("${pool_show_jq_path}" -er \
    --arg id "${pool_id_bech32}" '.[$id].retiring // 0' \
    "${pool_state_file}")" || return 70
  [[ -n "${pool_show_future_params}" ]] || \
    pool_show_future_params="${pool_show_current_params}"
  pool_default_vote=""
  if _cntools_action_pool_show_file_validate \
      "${pool_show_pool_directory}/${POOL_COLDKEY_VK_FILENAME}" \
      '400,444,600,644' 65536; then
    pool_show_response_file=""
    _cntools_action_pool_show_private_file_create \
      pool_show_response_file default-vote || return 70
    default_vote_file="${pool_show_response_file}"
    println ACTION 'cardano-cli pool-show default-vote query'
    if "${pool_show_ccli_path}" latest query stake-pool-default-vote \
        --spo-verification-key-file \
        "${pool_show_pool_directory}/${POOL_COLDKEY_VK_FILENAME}" \
        "${pool_show_network_arguments[@]}" \
        > "${default_vote_file}" 2>/dev/null &&
       _cntools_action_pool_show_response_validate \
         "${default_vote_file}" 256; then
      vote="$("${pool_show_jq_path}" -er \
        'select(type == "string" and
          (. == "DefaultAbstain" or . == "DefaultNoConfidence"))' \
        "${default_vote_file}" 2>/dev/null)" || vote=""
      [[ -n "${vote}" ]] && pool_default_vote="${vote#Default}"
    fi
  fi
  return 0
}

_cntools_action_pool_show_light_query() {
  local payload="" query_status=0 record="" response_length=""

  payload="$("${pool_show_jq_path}" -nc --arg id "${pool_id_bech32}" \
    '{_pool_bech32_ids:[$id]}')" || return 70
  _cntools_action_pool_show_koios_query /pool_info "${payload}" 262144 ||
    query_status=$?
  [[ "${query_status}" == 0 ]] || return "${query_status}"
  "${pool_show_jq_path}" -e --arg id "${pool_id_bech32}" '
    def token($maximum):
      type == "string" and length >= 1 and length <= $maximum and
      test("^[A-Za-z0-9._:+@-]+$");
    def uint:
      type == "number" and floor == . and . >= 0 and . <= 45000000000000000;
    def epoch:
      type == "number" and floor == . and . >= 0 and . <= 2147483647;
    def dns:
      type == "string" and length >= 1 and length <= 253 and
      test("^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$");
    def ipv4:
      type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") and
      (split(".") | length == 4 and all(.[]; (tonumber >= 0 and tonumber <= 255)));
    def ipv6:
      type == "string" and length >= 2 and length <= 45 and
      test("^[0-9A-Fa-f:]+$") and contains(":");
    def url:
      . == null or (type == "string" and length >= 9 and length <= 2048 and
        startswith("https://") and test("^[!-~]+$") and
        (contains("\\") | not));
    def relay:
      type == "object" and
      ((keys - ["dns","ipv4","ipv6","port","srv"]) | length == 0) and
      ([.ipv4,.ipv6,.dns,.srv] | map(select(. != null)) | length) <= 1 and
      (.ipv4 == null or (.ipv4 | ipv4)) and
      (.ipv6 == null or (.ipv6 | ipv6)) and
      (.dns == null or (.dns | dns)) and
      (.srv == null or (.srv | dns)) and
      (.port == null or
        (.port | type == "number" and floor == . and . >= 1 and . <= 65535));
    type == "array" and length <= 1 and
    all(.[];
      type == "object" and .pool_id_bech32 == $id and
      (.active_epoch_no | epoch) and (.vrf_key_hash | token(256)) and
      (.margin | type == "number" and . >= 0 and . <= 1) and
      (.fixed_cost | uint) and (.pledge | uint) and
      (.reward_addr | token(256)) and
      (.owners | type == "array" and length <= 100 and
        length == (unique | length) and all(.[]; token(256))) and
      (.relays | type == "array" and length <= 100 and all(.[]; relay)) and
      (.meta_url | url) and
      (.meta_hash == null or
        (.meta_hash | type == "string" and test("^[0-9A-Fa-f]{64}$"))) and
      (.pool_status == "registered" or .pool_status == "retiring" or
        .pool_status == "retired") and
      (if .pool_status == "registered" then .retiring_epoch == null
       else (.retiring_epoch | epoch) end) and
      (.op_cert == null or (.op_cert | token(256))) and
      (.op_cert_counter == null or
        (.op_cert_counter | type == "number" and floor == . and
          . >= 0 and . <= 2147483646)) and
      (.active_stake | uint) and (.block_count | uint) and
      (.live_pledge | uint) and (.live_stake | uint) and
      (.live_delegators | type == "number" and floor == . and
        . >= 0 and . <= 100000000) and
      (.live_saturation | type == "number" and . >= 0 and . <= 100)
    )
  ' "${pool_show_response_file}" >/dev/null 2>&1 || return 2
  response_length="$("${pool_show_jq_path}" -er 'length' \
    "${pool_show_response_file}")" || return 70
  if [[ "${response_length}" == 0 ]]; then
    pool_show_light_status=unregistered
    return 0
  fi
  record="$("${pool_show_jq_path}" -er '.[0] | [
      .active_epoch_no,.vrf_key_hash,.margin,.fixed_cost,.pledge,
      .reward_addr,(.meta_url // ""),(.meta_hash // ""),.pool_status,
      (.retiring_epoch // 0),(.op_cert // ""),(.op_cert_counter // "null"),
      .active_stake,.block_count,.live_pledge,.live_stake,
      .live_delegators,.live_saturation] | @tsv' \
    "${pool_show_response_file}")" || return 70
  IFS=$'\t' read -r p_active_epoch_no p_vrf_key_hash p_margin \
    p_fixed_cost p_pledge p_reward_addr p_meta_url p_meta_hash \
    pool_show_light_status p_retiring_epoch p_op_cert p_op_cert_counter \
    p_active_stake p_block_count p_live_pledge p_live_stake \
    p_live_delegators p_live_saturation <<< "${record}" || return 70
  p_owners="$("${pool_show_jq_path}" -cer '.[0].owners' \
    "${pool_show_response_file}")" || return 70
  p_relays="$("${pool_show_jq_path}" -cer '.[0].relays' \
    "${pool_show_response_file}")" || return 70
}

_cntools_action_pool_show_wallet_lookup() {
  local sought="${1:-}" directory="" physical="" address_file="" value=""
  local directory_file="" candidate="" visited=0

  pool_show_wallet_match=""
  [[ "${sought}" =~ ^[A-Za-z0-9._:+@-]{1,255}$ ]] || return 1
  pool_show_directory_file=""
  _cntools_action_pool_show_private_file_create \
    pool_show_directory_file wallets || return 70
  directory_file="${pool_show_directory_file}"
  "${pool_show_find_path}" "${pool_show_wallet_root_physical}" \
    -mindepth 1 -maxdepth 1 -type d -print0 > "${directory_file}" || return 70
  _cntools_action_pool_show_file_validate \
    "${directory_file}" '600' 2097152 0 || return 70
  while IFS= read -r -d '' directory; do
    visited=$((visited + 1))
    (( visited <= 10000 )) || return 70
    _cntools_action_pool_show_component_valid "${directory##*/}" || return 70
    physical="$(cd -P -- "${directory}" >/dev/null 2>&1 && pwd -P)" || return 70
    [[ "${physical}" == "${pool_show_wallet_root_physical}/${directory##*/}" ]] ||
      return 70
    _cntools_registry_path_has_no_symlinks "${physical}" || return 70
    address_file="${physical}/${WALLET_STAKE_ADDR_FILENAME}"
    [[ -e "${address_file}" || -L "${address_file}" ]] || continue
    _cntools_action_pool_show_file_validate \
      "${address_file}" '400,444,600,644' 1024 || return 70
    value="$(< "${address_file}")"
    [[ "${value}" =~ ^[A-Za-z0-9._:+@-]{1,255}$ ]] || return 70
    if [[ "${value}" == "${sought}" ]]; then
      candidate="${directory##*/}"
      if [[ -z "${pool_show_wallet_match}" ||
            "${candidate}" < "${pool_show_wallet_match}" ]]; then
        pool_show_wallet_match="${candidate}"
      fi
    fi
  done < "${directory_file}"
  [[ -n "${pool_show_wallet_match}" ]]
}

_cntools_action_pool_show_print_metadata_fields() {
  println 'Metadata'
  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" 'Name' \
    "${metadata_name}")"
  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" 'Ticker' \
    "${metadata_ticker}")"
  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" 'Homepage' \
    "${metadata_homepage}")"
  println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" 'Description' \
    "${metadata_description}")"
}

_cntools_action_pool_show_print_relays() {
  local source="${1:-}" params="${2:-}" relay="" relay_title='Relay(s)'
  local address="" port="" relay_type="" records="" expected=0 visited=0

  case "${source}" in
    local)
      expected="$("${pool_show_jq_path}" -er 'length' \
        <<< "${params}")" || return 70
      records="$("${pool_show_jq_path}" -cer '.[]' \
        <<< "${params}")" || return 70
      (( expected == 0 )) && return 0
      while IFS= read -r relay; do
        visited=$((visited + 1))
        address="$("${pool_show_jq_path}" -er \
          '.["single host address"].IPv4 //
           .["single host name"].dnsName //
           .["single host address"].IPv6' <<< "${relay}")" || return 70
        port="$("${pool_show_jq_path}" -er \
          '.["single host address"].port //
           .["single host name"].port // ""' <<< "${relay}")" || return 70
        println "$(printf "%-21s : ${FG_LGRAY}%s:%s${NC}" \
          "${relay_title}" "${address}" "${port}")"
        relay_title=""
      done <<< "${records}"
      ;;
    light)
      expected="$("${pool_show_jq_path}" -er 'length' <<< "${params}")" ||
        return 70
      records="$("${pool_show_jq_path}" -cer '.[]' <<< "${params}")" ||
        return 70
      (( expected == 0 )) && return 0
      while IFS= read -r relay; do
        visited=$((visited + 1))
        address="$("${pool_show_jq_path}" -er \
          '.ipv4 // .dns // .ipv6 // .srv // "unknown type"' \
          <<< "${relay}")" || return 70
        port="$("${pool_show_jq_path}" -er '.port // ""' \
          <<< "${relay}")" || return 70
        println "$(printf "%-21s : ${FG_LGRAY}%s:%s${NC}" \
          "${relay_title}" "${address}" "${port}")"
        relay_title=""
      done <<< "${records}"
      ;;
    offline)
      expected="$("${pool_show_jq_path}" -er '.relays | length' \
        <<< "${params}")" || return 70
      records="$("${pool_show_jq_path}" -er \
        '.relays[] | [.type,.address,.port] | @tsv' <<< "${params}")" ||
        return 70
      (( expected == 0 )) && return 0
      while IFS=$'\t' read -r relay_type address port; do
        visited=$((visited + 1))
        if [[ "${relay_type}" == DNS_A || "${relay_type}" == IPv4 ||
              "${relay_type}" == IPv6 ]]; then
          println "$(printf "%-21s : ${FG_LGRAY}%s:%s${NC}" \
            "${relay_title}" "${address}" "${port}")"
        else
          println "$(printf "%-21s : ${FG_YELLOW}%s${NC}" \
            "${relay_title}" \
            'unknown type (only IPv4/v6/DNS supported in CNTools)')"
        fi
        relay_title=""
      done <<< "${records}"
      ;;
    *) return 70 ;;
  esac
  (( visited == expected ))
}

_cntools_action_pool_show_print_owners() {
  local owners_json="${1:-}" owner="" owner_title='Owner(s)' records=""
  local expected=0 visited=0

  expected="$("${pool_show_jq_path}" -er 'length' <<< "${owners_json}")" ||
    return 70
  records="$("${pool_show_jq_path}" -er '.[]' <<< "${owners_json}")" ||
    return 70
  (( expected == 0 )) && return 0
  while IFS= read -r owner; do
    visited=$((visited + 1))
    if _cntools_action_pool_show_wallet_lookup "${owner}"; then
      println "$(printf "%-21s : ${FG_GREEN}%s${NC}" \
        "${owner_title}" "${pool_show_wallet_match}")"
    else
      [[ $? == 1 ]] || return 70
      println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" \
        "${owner_title}" "${owner}")"
    fi
    owner_title=""
  done <<< "${records}"
  (( visited == expected ))
}

_cntools_action_pool_show_print_kes() {
  local kes_counter="${1:-null}" kes_counter_string="" opcert_file=""
  local kes_file="" op_cert_counter="" query_status=0
  local pool_kes_start=""

  if [[ "${pool_show_context_mode}" == light ]]; then
    if [[ "${kes_counter}" == null ]]; then
      kes_counter_string="${FG_LGRAY}No blocks minted so far with active operational certificate. Use counter ${FG_LBLUE}0${FG_LGRAY} for rotation in offline mode.${NC}"
    else
      kes_counter_string="${FG_LBLUE}${kes_counter}${FG_LGRAY} - use counter ${FG_LBLUE}$((kes_counter + 1))${FG_LGRAY} for rotation in offline mode.${NC}"
    fi
    println "$(printf '%-21s : %s' 'KES counter' "${kes_counter_string}")"
  elif [[ "${pool_show_context_mode}" == local ]]; then
    opcert_file="${pool_show_pool_directory}/${POOL_OPCERT_FILENAME}"
    if ! _cntools_action_pool_show_file_validate \
        "${opcert_file}" '400,444,600,644' 1048576; then
      kes_counter_string="${FG_RED}ERROR${NC}: operational certificate is unavailable or invalid."
    else
      pool_show_response_file=""
      _cntools_action_pool_show_private_file_create \
        pool_show_response_file kes || return 70
      kes_file="${pool_show_response_file}"
      println ACTION 'cardano-cli pool-show KES query'
      "${pool_show_ccli_path}" query kes-period-info --op-cert-file \
        "${opcert_file}" "${pool_show_network_arguments[@]}" \
        > "${kes_file}" 2>/dev/null || query_status=$?
      if [[ "${query_status}" != 0 ]] ||
         ! _cntools_action_pool_show_response_validate "${kes_file}" 262144; then
        kes_counter_string="${FG_RED}ERROR${NC}: KES counter query failed."
      else
        pool_show_auxiliary_file=""
        _cntools_action_pool_show_private_file_create \
          pool_show_auxiliary_file kes-json || return 70
        "${pool_show_awk_path}" '/^[[:space:]]*\{/{found=1} found{print}' \
          "${kes_file}" > "${pool_show_auxiliary_file}" || return 70
        if _cntools_action_pool_show_response_validate \
             "${pool_show_auxiliary_file}" 262144 &&
           op_cert_counter="$("${pool_show_jq_path}" -er '
             select(type == "object" and
               (.qKesNodeStateOperationalCertificateNumber |
                 type == "number" and floor == . and . >= 0 and
                 . <= 2147483646)) |
             .qKesNodeStateOperationalCertificateNumber
           ' "${pool_show_auxiliary_file}" 2>/dev/null)"; then
          kes_counter_string="${FG_LBLUE}${op_cert_counter}${FG_LGRAY} - use counter ${FG_LBLUE}$((op_cert_counter + 1))${FG_LGRAY} for rotation in offline mode.${NC}"
        else
          kes_counter_string="${FG_LGRAY}No blocks minted so far with active operational certificate. Use counter ${FG_LBLUE}0${FG_LGRAY} for rotation in offline mode.${NC}"
        fi
      fi
    fi
    println "$(printf '%-21s : %s' 'KES counter' "${kes_counter_string}")"
    getNodeMetrics
  fi

  if _cntools_action_pool_show_file_validate \
      "${pool_show_pool_directory}/${POOL_CURRENT_KES_START}" \
      '400,444,600,644' 64; then
    pool_kes_start="$(< \
      "${pool_show_pool_directory}/${POOL_CURRENT_KES_START}")"
    [[ "${pool_kes_start}" =~ ^(0|[1-9][0-9]{0,18})$ ]] || pool_kes_start=""
  fi
  unset remaining_kes_periods
  if [[ -z "${pool_kes_start}" ]] || ! kesExpiration "${pool_kes_start}"; then
    println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC}%s${FG_GREEN}%s${NC}" \
      'KES expiration date' 'ERROR' ': failure during KES calculation for ' \
      "${pool_name}")"
  elif [[ "${expiration_time_sec_diff}" -lt "${KES_ALERT_PERIOD}" ]]; then
    if [[ "${expiration_time_sec_diff}" -lt 0 ]]; then
      println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s ago" \
        'KES expiration date' "${kes_expiration}" 'EXPIRED!' \
        "$(timeLeft "${expiration_time_sec_diff:1}")")"
    else
      println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_RED}%s${NC} %s until expiration" \
        'KES expiration date' "${kes_expiration}" 'ALERT!' \
        "$(timeLeft "${expiration_time_sec_diff}")")"
    fi
  elif [[ "${expiration_time_sec_diff}" -lt "${KES_WARNING_PERIOD}" ]]; then
    println "$(printf "%-21s : ${FG_LGRAY}%s${NC} - ${FG_YELLOW}%s${NC} %s until expiration" \
      'KES expiration date' "${kes_expiration}" 'WARNING!' \
      "$(timeLeft "${expiration_time_sec_diff}")")"
  else
    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" \
      'KES expiration date' "${kes_expiration}")"
  fi
}

_cntools_action_pool_show_print_calidus() {
  local query_status=0 response_length="" pc_status="" pc_epoch_no=""
  local pc_block_time="" pc_id="" record=""

  println 'Calidus Key'
  _cntools_action_pool_show_koios_query \
    "/pool_calidus_keys?pool_id_bech32=eq.${pool_id_bech32}" '' 65536 post ||
    query_status=$?
  if [[ "${query_status}" != 0 ]]; then
    println "$(printf "${FG_RED}%-21s${NC} : ${FG_LGRAY}%s${NC}" \
      '  Error' 'pool Calidus information is unavailable or invalid.')"
    return 0
  fi
  "${pool_show_jq_path}" -e '
    def token($maximum):
      type == "string" and length >= 1 and length <= $maximum and
      test("^[A-Za-z0-9._:+@-]+$");
    type == "array" and length <= 1 and all(.[];
      type == "object" and
      (.pool_status | token(32)) and
      (.calidus_id_bech32 | token(256)) and
      (.epoch_no | type == "number" and floor == . and . >= 0 and
        . <= 2147483647) and
      (.block_time | type == "number" and floor == . and . >= 0 and
        . <= 4102444800)
    )
  ' "${pool_show_response_file}" >/dev/null 2>&1 || {
    println "$(printf "${FG_RED}%-21s${NC} : ${FG_LGRAY}%s${NC}" \
      '  Error' 'pool Calidus information is unavailable or invalid.')"
    return 0
  }
  response_length="$("${pool_show_jq_path}" -er 'length' \
    "${pool_show_response_file}")" || return 70
  if [[ "${response_length}" == 0 ]]; then
    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" \
      '  Status' 'No valid key registered')"
    return 0
  fi
  record="$("${pool_show_jq_path}" -er \
      '.[0] | [.pool_status,.epoch_no,.block_time,.calidus_id_bech32] | @tsv' \
      "${pool_show_response_file}")" || return 70
  IFS=$'\t' read -r pc_status pc_epoch_no pc_block_time pc_id \
    <<< "${record}" || return 70
  if [[ "${pc_status}" != registered ]]; then
    println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" \
      '  Status' 'No valid key registered')"
    return 0
  fi
  println "$(printf "%-21s : ${FG_LGRAY}%s${NC} ${FG_LBLUE}%s${NC} (${FG_LGRAY}%s${NC})" \
    '  Status' 'Registered epoch' "${pc_epoch_no}" \
    "$(printf '%(%F %T %Z)T' "${pc_block_time}")")"
  println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" '  Id' "${pc_id}")"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local context_mode="" context_network="" network_magic=""
  local pool_root_physical="" selected_physical="" selection_status=0
  local current_epoch="" action_status=0 query_status=0 header_index=0
  local header_value="" filename="" pool_registered="" registration_yes=N
  local metadata_file="" pool_config="" meta_json_url="" metadata_hash=""
  local metadata_hash_url="" metadata_hash_current="" metadata_hash_future=""
  local metadata_name="" metadata_ticker="" metadata_homepage=""
  local metadata_description="" pool_show_metadata_file=""
  local p_current_pledge="" p_future_pledge="" p_current_margin=""
  local p_future_margin="" p_current_cost="" p_future_cost=""
  local owners_current="" owners_future="" reward_current="" reward_future=""
  local relays_current="" relays_future="" stake_file="" stake_pct=""
  local conf_pledge="" conf_margin="" conf_cost="" conf_owner=""
  local conf_reward="" config_json="" config_record="" price_str=""
  local pool_show_context_mode="" pool_show_private_parent=""
  local pool_show_pool_directory="" pool_show_wallet_root_physical=""
  local pool_show_curl_timeout="" pool_show_koios_api=""
  local pool_show_jq_path="" pool_show_curl_path="" pool_show_mktemp_path=""
  local pool_show_chmod_path="" pool_show_rm_path="" pool_show_find_path=""
  local pool_show_awk_path="" pool_show_ccli_path=""
  local pool_show_response_file="" pool_show_auxiliary_file=""
  local pool_show_directory_file="" pool_directory_file=""
  local pool_show_current_params="" pool_show_future_params=""
  local pool_show_retiring_epoch=0 pool_show_light_status=""
  local pool_show_wallet_match="" pool_default_vote=""
  local pool_id="" pool_id_bech32="" pool_name=""
  local p_active_epoch_no="" p_vrf_key_hash="" p_margin="" p_fixed_cost=""
  local p_pledge="" p_reward_addr="" p_meta_url="" p_meta_hash=""
  local p_retiring_epoch=0 p_op_cert="" p_op_cert_counter="null"
  local p_active_stake="" p_block_count="" p_live_pledge=""
  local p_live_stake="" p_live_delegators="" p_live_saturation=""
  local p_owners="[]" p_relays="[]"
  local -a pool_show_temp_files=() pool_show_koios_headers=()
  local -a pool_show_network_arguments=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  for required_function in cntools_context_get _cntools_registry_tool_path \
      _cntools_registry_path_has_no_symlinks _cntools_result_stat \
      _cntools_result_private_parent_validate println getPriceInfo selectPool \
      waitToProceed getEpoch getPriceString formatLovelace ADAToLovelace \
      fractionToPCT kesExpiration getNodeMetrics timeLeft; do
    builtin declare -F "${required_function}" >/dev/null 2>&1 || action_status=70
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_pool_show_validation_failure
    return 70
  }
  context_mode="$(cntools_context_get "${context_file}" mode)" || action_status=70
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" ||
    action_status=70
  pool_show_context_mode="${context_mode}"
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || action_status=70
  for filename in "${POOL_ID_FILENAME:-}" "${POOL_COLDKEY_VK_FILENAME:-}" \
      "${POOL_REGCERT_FILENAME:-}" "${POOL_CURRENT_KES_START:-}" \
      "${POOL_CONFIG_FILENAME:-}" "${POOL_OPCERT_FILENAME:-}" \
      "${WALLET_STAKE_ADDR_FILENAME:-}"; do
    _cntools_action_pool_show_component_valid "${filename}" || action_status=70
  done
  for filename in jq mktemp chmod rm find awk; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq pool_show_jq_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp pool_show_mktemp_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod pool_show_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm pool_show_rm_path || action_status=70 ;;
      find) _cntools_registry_tool_path find pool_show_find_path || action_status=70 ;;
      awk) _cntools_registry_tool_path awk pool_show_awk_path || action_status=70 ;;
    esac
  done
  pool_show_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${pool_show_private_parent}" ||
    action_status=70
  [[ "${POOL_FOLDER:-}" == /* && -d "${POOL_FOLDER}" &&
     ! -L "${POOL_FOLDER}" ]] || action_status=70
  [[ "${WALLET_FOLDER:-}" == /* && -d "${WALLET_FOLDER}" &&
     ! -L "${WALLET_FOLDER}" ]] || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    _cntools_registry_path_has_no_symlinks "${POOL_FOLDER}" || action_status=70
    _cntools_registry_path_has_no_symlinks "${WALLET_FOLDER}" || action_status=70
    pool_root_physical="$(cd -P -- "${POOL_FOLDER}" >/dev/null 2>&1 && pwd -P)" ||
      action_status=70
    pool_show_wallet_root_physical="$(cd -P -- "${WALLET_FOLDER}" \
      >/dev/null 2>&1 && pwd -P)" || action_status=70
  fi
  case "${NETWORK_IDENTIFIER:-}" in
    --mainnet)
      [[ "${context_network}" == mainnet ]] || action_status=70
      pool_show_network_arguments=(--mainnet)
      ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 &&
         "${context_network}" != mainnet ]] || action_status=70
      pool_show_network_arguments=(--testnet-magic "${network_magic}")
      ;;
    *) action_status=70 ;;
  esac
  [[ "${KES_ALERT_PERIOD:-}" =~ ^[0-9]{1,12}$ &&
     "${KES_WARNING_PERIOD:-}" =~ ^[0-9]{1,12}$ &&
     "${KES_ALERT_PERIOD}" -le "${KES_WARNING_PERIOD}" ]] || action_status=70
  if [[ "${context_mode}" != offline ]]; then
    _cntools_registry_tool_path curl pool_show_curl_path || action_status=70
    pool_show_curl_timeout="${CURL_TIMEOUT:-10}"
    [[ "${pool_show_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] ||
      action_status=70
  fi
  if [[ "${context_mode}" == light ]]; then
    pool_show_koios_api="${KOIOS_API%/}"
    _cntools_action_pool_show_https_valid "${pool_show_koios_api}" ||
      action_status=70
    pool_show_koios_headers=("${KOIOS_API_HEADERS[@]}")
    (( ${#pool_show_koios_headers[@]} % 2 == 0 &&
       ${#pool_show_koios_headers[@]} <= 8 )) || action_status=70
    for ((header_index=0; header_index<${#pool_show_koios_headers[@]};
        header_index+=2)); do
      header_value="${pool_show_koios_headers[header_index+1]}"
      [[ ( "${pool_show_koios_headers[header_index]}" == -H ||
           "${pool_show_koios_headers[header_index]}" == --header ) &&
         "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
         "${header_value}" == *:* && "${header_value}" != *$'\r'* &&
         "${header_value}" != *$'\n'* ]] || action_status=70
    done
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_pool_show_validation_failure
    return 70
  }

  umask 077
  trap '_cntools_action_pool_show_cleanup' EXIT
  trap '_cntools_action_pool_show_cleanup; exit 70' HUP INT TERM
  clear
  [[ "${context_mode}" == offline ]] || getPriceInfo
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> POOL >> SHOW'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  pool_show_directory_file=""
  _cntools_action_pool_show_private_file_create \
    pool_show_directory_file pools || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  pool_directory_file="${pool_show_directory_file}"
  "${pool_show_find_path}" "${pool_root_physical}" \
    -mindepth 1 -maxdepth 1 -type d -print0 > "${pool_directory_file}" || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  _cntools_action_pool_show_file_validate \
    "${pool_directory_file}" '600' 2097152 0 || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  if [[ ! -s "${pool_directory_file}" ]]; then
    echo
    println "${FG_YELLOW}No pools available!${NC}"
    waitToProceed
    _cntools_action_pool_show_finish 0
    return $?
  fi
  if [[ "${context_mode}" == offline ]]; then
    println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, locally saved info shown!"
  fi
  tput sc
  selectPool all "${POOL_ID_FILENAME}" || selection_status=$?
  tput rc && tput ed
  case "${selection_status}" in
    0) ;;
    1)
      waitToProceed
      _cntools_action_pool_show_finish 0
      return $?
      ;;
    2)
      _cntools_action_pool_show_finish 0
      return $?
      ;;
    *)
      _cntools_action_pool_show_finish 70
      return $?
      ;;
  esac
  _cntools_action_pool_show_component_valid "${pool_name}" || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  selected_physical="$(cd -P -- "${pool_root_physical}/${pool_name}" \
    >/dev/null 2>&1 && pwd -P)" || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  [[ "${selected_physical}" == "${pool_root_physical}/${pool_name}" ]] || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  _cntools_registry_path_has_no_symlinks "${selected_physical}" || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  pool_show_pool_directory="${selected_physical}"
  current_epoch="$(getEpoch)" || current_epoch=""
  [[ "${current_epoch}" =~ ^(0|[1-9][0-9]{0,9})$ &&
     "${current_epoch}" -le 2147483647 ]] || {
    _cntools_action_pool_show_finish 70
    return $?
  }
  if ! _cntools_action_pool_show_id_resolve; then
    println ERROR 'ERROR: pool identity is unavailable or invalid.'
    waitToProceed
    _cntools_action_pool_show_finish 0
    return $?
  fi

  case "${context_mode}" in
    offline)
      pool_registered="${FG_LGRAY}status unavailable in offline mode${NC}"
      ;;
    local)
      tput sc
      println DEBUG 'Querying pool parameters from node, can take a while...\n'
      _cntools_action_pool_show_local_query || query_status=$?
      tput rc && tput ed
      case "${query_status}" in
        0) ;;
        1|2)
          println ERROR 'ERROR: local pool information is unavailable or invalid.'
          waitToProceed
          _cntools_action_pool_show_finish 0
          return $?
          ;;
        *)
          _cntools_action_pool_show_finish 70
          return $?
          ;;
      esac
      if [[ -n "${pool_show_current_params}" ]]; then
        pool_registered="${FG_GREEN}Yes${NC}"
        registration_yes=Y
      else
        pool_registered="${FG_RED}No${NC}"
      fi
      if (( pool_show_retiring_epoch > 0 )); then
        if (( current_epoch < pool_show_retiring_epoch )); then
          pool_registered="${FG_YELLOW}Yes${NC} - Retiring in epoch ${FG_LBLUE}${pool_show_retiring_epoch}${NC}"
          registration_yes=Y
        else
          pool_registered="${FG_RED}No${NC} - Retired in epoch ${FG_LBLUE}${pool_show_retiring_epoch}${NC}"
          registration_yes=N
        fi
      fi
      ;;
    light)
      println OFF "\n${FG_YELLOW}> Querying Koios API for pool information (some data can have a small delay)${NC}"
      _cntools_action_pool_show_light_query || query_status=$?
      case "${query_status}" in
        0) ;;
        1|2)
          println ERROR '\nKOIOS_API ERROR: pool information is unavailable or invalid.'
          waitToProceed
          _cntools_action_pool_show_finish 0
          return $?
          ;;
        *)
          _cntools_action_pool_show_finish 70
          return $?
          ;;
      esac
      case "${pool_show_light_status}" in
        unregistered) pool_registered="${FG_RED}No${NC}" ;;
        registered)
          pool_registered="${FG_GREEN}Yes${NC}"
          registration_yes=Y
          ;;
        retiring)
          if (( current_epoch < p_retiring_epoch )); then
            pool_registered="${FG_YELLOW}Yes${NC} - Retiring in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
            registration_yes=Y
          else
            pool_registered="${FG_RED}No${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
          fi
          ;;
        retired)
          pool_registered="${FG_RED}No${NC} - Retired in epoch ${FG_LBLUE}${p_retiring_epoch}${NC}"
          ;;
        *)
          _cntools_action_pool_show_finish 70
          return $?
          ;;
      esac
      ;;
  esac

  echo
  if [[ -n "${p_active_epoch_no}" &&
        "${p_active_epoch_no}" -gt "${current_epoch}" ]]; then
    println "${FG_YELLOW}Pool modified recently, displaying latest registration update.${NC}\n"
  fi
  println "$(printf "%-21s : ${FG_GREEN}%s${NC}" 'Pool Name' "${pool_name}")"
  println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" 'ID (hex)' "${pool_id}")"
  println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" 'ID (bech32)' "${pool_id_bech32}")"
  println "$(printf '%-21s : %s' 'Registered' "${pool_registered}")"
  if [[ -n "${pool_default_vote}" ]]; then
    println "$(printf '%-21s : %s' 'Default vote' "${pool_default_vote}")"
  fi

  metadata_file="${pool_show_pool_directory}/poolmeta.json"
  pool_config="${pool_show_pool_directory}/${POOL_CONFIG_FILENAME}"
  if [[ "${context_mode}" == offline ]]; then
    if [[ -e "${metadata_file}" || -L "${metadata_file}" ]]; then
      if ! _cntools_action_pool_show_metadata_read "${metadata_file}" ||
         ! _cntools_action_pool_show_metadata_hash \
           "${metadata_file}" metadata_hash; then
        println ERROR 'ERROR: local pool metadata is unavailable or invalid.'
        waitToProceed
        _cntools_action_pool_show_finish 0
        return $?
      fi
      if [[ -e "${pool_config}" || -L "${pool_config}" ]]; then
        if ! _cntools_action_pool_show_config_validate "${pool_config}"; then
          println ERROR 'ERROR: local pool configuration is unavailable or invalid.'
          waitToProceed
          _cntools_action_pool_show_finish 0
          return $?
        fi
        config_json="$("${pool_show_jq_path}" -cer . "${pool_config}")" || {
          _cntools_action_pool_show_finish 70
          return $?
        }
        meta_json_url="$("${pool_show_jq_path}" -er '.json_url' \
          <<< "${config_json}")" || {
          _cntools_action_pool_show_finish 70
          return $?
        }
      else
        meta_json_url='---'
      fi
      _cntools_action_pool_show_print_metadata_fields
      println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" 'URL' "${meta_json_url}")"
      println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" 'Hash' "${metadata_hash}")"
    fi
  elif [[ "${registration_yes}" == Y ]]; then
    if [[ "${context_mode}" == light ]]; then
      meta_json_url="${p_meta_url}"
    else
      meta_json_url="$("${pool_show_jq_path}" -er \
        '.spsMetadata.url // empty' <<< "${pool_show_future_params}")" ||
        meta_json_url=""
    fi
    if [[ -n "${meta_json_url}" ]]; then
      query_status=0
      _cntools_action_pool_show_metadata_download "${meta_json_url}" ||
        query_status=$?
      if [[ "${query_status}" == 0 ]] &&
         _cntools_action_pool_show_metadata_read "${pool_show_metadata_file}" &&
         _cntools_action_pool_show_metadata_hash \
           "${pool_show_metadata_file}" metadata_hash_url; then
        _cntools_action_pool_show_print_metadata_fields
        println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" \
          'URL' "${meta_json_url}")"
        println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" \
          'Hash URL' "${metadata_hash_url}")"
        if [[ "${context_mode}" == local ]]; then
          metadata_hash_current="$("${pool_show_jq_path}" -er \
            '.spsMetadata.hash // empty' <<< "${pool_show_current_params}")" ||
            metadata_hash_current=""
          metadata_hash_future="$("${pool_show_jq_path}" -er \
            '.spsMetadata.hash // empty' <<< "${pool_show_future_params}")" ||
            metadata_hash_future=""
        else
          metadata_hash_current="${p_meta_hash}"
          metadata_hash_future="${p_meta_hash}"
        fi
        if [[ "${metadata_hash_current}" == "${metadata_hash_future}" ]]; then
          println "$(printf "  %-19s : ${FG_LGRAY}%s${NC}" \
            'Hash Ledger' "${metadata_hash_current}")"
        else
          println "$(printf "  %-13s (${FG_LGRAY}%s${NC}) : %s" \
            'Hash Ledger' 'old' "${metadata_hash_current}")"
          println "$(printf "  %-13s (${FG_YELLOW}%s${NC}) : %s" \
            'Hash Ledger' 'new' "${metadata_hash_future}")"
        fi
      else
        println "$(printf '%-21s : %s' 'Metadata' \
          "download failed for ${meta_json_url}")"
      fi
    fi
  fi

  if [[ "${context_mode}" == offline &&
        ( -e "${pool_config}" || -L "${pool_config}" ) ]]; then
    if [[ -z "${config_json}" ]]; then
      _cntools_action_pool_show_config_validate "${pool_config}" || {
        println ERROR 'ERROR: local pool configuration is unavailable or invalid.'
        waitToProceed
        _cntools_action_pool_show_finish 0
        return $?
      }
      config_json="$("${pool_show_jq_path}" -cer . "${pool_config}")" || {
        _cntools_action_pool_show_finish 70
        return $?
      }
    fi
    config_record="$("${pool_show_jq_path}" -er \
      '[.pledgeADA,.margin,.costADA,.pledgeWallet,.rewardWallet] | @tsv' \
      <<< "${config_json}")" || {
      _cntools_action_pool_show_finish 70
      return $?
    }
    IFS=$'\t' read -r conf_pledge conf_margin conf_cost conf_owner \
      conf_reward <<< "${config_record}" || {
      _cntools_action_pool_show_finish 70
      return $?
    }
    println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" 'Pledge' \
      "$(formatLovelace "$(ADAToLovelace "${conf_pledge}")")")"
    println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" \
      'Margin' "${conf_margin}")"
    println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" 'Cost' \
      "$(formatLovelace "$(ADAToLovelace "${conf_cost}")")")"
    println "$(printf "%-21s : ${FG_GREEN}%s${NC} (%s)" 'Owner Wallet' \
      "${conf_owner}" 'primary only, use online mode for multi-owner')"
    println "$(printf "%-21s : ${FG_GREEN}%s${NC}" \
      'Reward Wallet' "${conf_reward}")"
    _cntools_action_pool_show_print_relays offline "${config_json}" || {
      _cntools_action_pool_show_finish 70
      return $?
    }
  elif [[ "${registration_yes}" == Y ]]; then
    if [[ "${context_mode}" == local ]]; then
      p_current_pledge="$("${pool_show_jq_path}" -er '.spsPledge' \
        <<< "${pool_show_current_params}")" || action_status=70
      p_future_pledge="$("${pool_show_jq_path}" -er '.spsPledge' \
        <<< "${pool_show_future_params}")" || action_status=70
      p_current_margin="$(LC_NUMERIC=C printf '%.4f' \
        "$("${pool_show_jq_path}" -er '.spsMargin' \
          <<< "${pool_show_current_params}")")" || action_status=70
      p_future_margin="$(LC_NUMERIC=C printf '%.4f' \
        "$("${pool_show_jq_path}" -er '.spsMargin' \
          <<< "${pool_show_future_params}")")" || action_status=70
      p_current_cost="$("${pool_show_jq_path}" -er '.spsCost' \
        <<< "${pool_show_current_params}")" || action_status=70
      p_future_cost="$("${pool_show_jq_path}" -er '.spsCost' \
        <<< "${pool_show_future_params}")" || action_status=70
      relays_current="$("${pool_show_jq_path}" -cer '.spsRelays' \
        <<< "${pool_show_current_params}")" || action_status=70
      relays_future="$("${pool_show_jq_path}" -cer '.spsRelays' \
        <<< "${pool_show_future_params}")" || action_status=70
      owners_current="$("${pool_show_jq_path}" -cer '.spsOwners' \
        <<< "${pool_show_current_params}")" || action_status=70
      owners_future="$("${pool_show_jq_path}" -cer '.spsOwners' \
        <<< "${pool_show_future_params}")" || action_status=70
      reward_current="$("${pool_show_jq_path}" -er '.spsAccountId.keyHash' \
        <<< "${pool_show_current_params}")" || action_status=70
      reward_future="$("${pool_show_jq_path}" -er '.spsAccountId.keyHash' \
        <<< "${pool_show_future_params}")" || action_status=70
    else
      p_current_pledge="${p_pledge}"; p_future_pledge="${p_pledge}"
      p_current_margin="$(LC_NUMERIC=C printf '%.4f' "${p_margin}")"
      p_future_margin="${p_current_margin}"
      p_current_cost="${p_fixed_cost}"; p_future_cost="${p_fixed_cost}"
      relays_current="${p_relays}"; relays_future="${p_relays}"
      owners_current="${p_owners}"; owners_future="${p_owners}"
      reward_current="${p_reward_addr}"; reward_future="${p_reward_addr}"
    fi
    [[ "${action_status}" == 0 ]] || {
      _cntools_action_pool_show_finish 70
      return $?
    }
    if [[ "${p_current_pledge}" == "${p_future_pledge}" ]]; then
      getPriceString "${p_current_pledge}"
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA%s" 'Pledge' \
        "$(formatLovelace "${p_current_pledge}")" "${price_str}")"
    else
      getPriceString "${p_future_pledge}"
      println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} ADA%s" \
        'Pledge' 'new' "$(formatLovelace "${p_future_pledge}")" \
        "${price_str}")"
    fi
    if [[ "${context_mode}" == light ]]; then
      getPriceString "${p_live_pledge}"
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA%s" 'Live Pledge' \
        "$(formatLovelace "${p_live_pledge}")" "${price_str}")"
    fi
    if [[ "${p_current_margin}" == "${p_future_margin}" ]]; then
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" 'Margin' \
        "$(fractionToPCT "${p_current_margin}")")"
    else
      println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} %%" \
        'Margin' 'new' "$(fractionToPCT "${p_future_margin}")")"
    fi
    if [[ "${p_current_cost}" == "${p_future_cost}" ]]; then
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" 'Cost' \
        "$(formatLovelace "${p_current_cost}")")"
    else
      println "$(printf "%-15s (${FG_YELLOW}%s${NC}) : ${FG_LBLUE}%s${NC} ADA" \
        'Cost' 'new' "$(formatLovelace "${p_future_cost}")")"
    fi
    if [[ "${relays_current}" != "${relays_future}" ]]; then
      println "$(printf "%-23s ${FG_YELLOW}%s${NC}" '' \
        'Relay(s) updated, showing latest registered')"
    fi
    _cntools_action_pool_show_print_relays \
      "${context_mode}" "${relays_future}" || {
      _cntools_action_pool_show_finish 70
      return $?
    }
    if [[ "${owners_current}" != "${owners_future}" ]]; then
      println "$(printf "%-23s ${FG_YELLOW}%s${NC}" '' \
        'Owner(s) updated, showing latest registered')"
    fi
    _cntools_action_pool_show_print_owners "${owners_future}" || {
      _cntools_action_pool_show_finish 70
      return $?
    }
    if [[ "${reward_current}" != "${reward_future}" ]]; then
      println "$(printf "%-23s ${FG_YELLOW}%s${NC}" '' \
        'Reward account updated, showing latest registered')"
    fi
    if _cntools_action_pool_show_wallet_lookup "${reward_future}"; then
      println "$(printf "%-21s : ${FG_GREEN}%s${NC}" \
        'Reward wallet' "${pool_show_wallet_match}")"
    else
      [[ $? == 1 ]] || {
        _cntools_action_pool_show_finish 70
        return $?
      }
      println "$(printf "%-21s : ${FG_LGRAY}%s${NC}" \
        'Reward account' "${reward_future}")"
    fi
    if [[ "${context_mode}" == local ]]; then
      pool_show_response_file=""
      _cntools_action_pool_show_private_file_create \
        pool_show_response_file stake || {
        _cntools_action_pool_show_finish 70
        return $?
      }
      stake_file="${pool_show_response_file}"
      println ACTION 'cardano-cli pool-show stake-distribution query'
      if "${pool_show_ccli_path}" query stake-distribution \
          "${pool_show_network_arguments[@]}" > "${stake_file}" 2>/dev/null &&
         _cntools_action_pool_show_response_validate "${stake_file}" 1048576 &&
         "${pool_show_jq_path}" -e --arg id "${pool_id_bech32}" '
           type == "object" and has($id) and
           (.[$id] | type == "object" and keys == ["denominator","numerator"] and
             (.numerator | type == "number" and floor == . and . >= 0 and
               . <= 45000000000000000) and
             (.denominator | type == "number" and floor == . and . >= 1 and
               . <= 45000000000000000))
         ' "${stake_file}" >/dev/null 2>&1; then
        stake_pct="$("${pool_show_jq_path}" -er --arg id "${pool_id_bech32}" \
          '.[$id] | (.numerator / .denominator * 100)' "${stake_file}")" ||
          stake_pct=""
        [[ "${stake_pct}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
          println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" \
            'Stake distribution' "${stake_pct}")"
      else
        println ERROR 'ERROR: local stake distribution is unavailable or invalid.'
      fi
    else
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" \
        'Active Stake' "$(formatLovelace "${p_active_stake}")")"
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC}" \
        'Lifetime Blocks' "${p_block_count}")"
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} ADA" \
        'Live Stake' "$(formatLovelace "${p_live_stake}")")"
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} (incl owners)" \
        'Delegators' "${p_live_delegators}")"
      println "$(printf "%-21s : ${FG_LBLUE}%s${NC} %%" \
        'Saturation' "${p_live_saturation}")"
    fi
    _cntools_action_pool_show_print_kes "${p_op_cert_counter}" || {
      _cntools_action_pool_show_finish 70
      return $?
    }
    if [[ "${context_mode}" == light ]]; then
      _cntools_action_pool_show_print_calidus || {
        _cntools_action_pool_show_finish 70
        return $?
      }
    fi
  fi

  waitToProceed
  _cntools_action_pool_show_finish 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
