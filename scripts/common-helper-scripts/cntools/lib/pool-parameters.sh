#!/usr/bin/env bash
# Public registration parameters, relay validation and metadata hashing.
# shellcheck disable=SC2034
CNTOOLS_POOL_REG_PLEDGE=0
CNTOOLS_POOL_REG_COST=170000000
CNTOOLS_POOL_REG_MARGIN=0
CNTOOLS_POOL_REG_REWARD_VKEY=''
CNTOOLS_POOL_REG_REWARD_HASH=''
CNTOOLS_POOL_REG_REWARD_ADDRESS=''
CNTOOLS_POOL_REG_REWARD_LABEL=''
CNTOOLS_POOL_REG_OWNERS='[]'
CNTOOLS_POOL_REG_RELAYS='[]'
CNTOOLS_POOL_REG_METADATA=null

cntools_pool_parameter_uint() {
  # Keep certificate JSON comparisons exact with jq's numeric representation.
  [[ "$1" =~ ^(0|[1-9][0-9]{0,15})$ ]] && cntools_uint_greater_equal 9007199254740991 "$1"
}

cntools_pool_margin_into() {
  local output="$1" input="$2" units=''
  cntools_number_units_into units "${input}" 6 && cntools_uint_greater_equal 100000000 "${units}" || return 1
  printf -v "${output}" '%s' "${units}/100000000"
}

cntools_pool_margin_number() {
  jq -ner --arg margin "$1" '$margin | if contains("/") then split("/") | (.[0]|tonumber)/(.[1]|tonumber) else tonumber end | select(. >= 0 and . <= 1)'
}

# Match the CLI's canonical IPv6 spelling before comparing decoded certificates.
cntools_pool_ipv6_into() {
  local -n pi6_result="$1"
  local pi6_ip="${2,,}" pi6_left='' pi6_right='' pi6_tail='' pi6_group='' pi6_hex='' pi6_text=''
  local pi6_i=0 pi6_missing=0 pi6_start=0 pi6_run=0 pi6_best_start=-1 pi6_best_length=0
  local -a pi6_parts=() pi6_lparts=() pi6_rparts=() pi6_octets=()
  [[ "${pi6_ip}" =~ ^[0-9a-f:.]+$ && "${pi6_ip}" != *:::* && ${#pi6_ip} -le 45 ]] || return 1
  [[ "${pi6_ip}" != :* || "${pi6_ip}" == ::* ]] && [[ "${pi6_ip}" != *: || "${pi6_ip}" == *:: ]] || return 1
  if [[ "${pi6_ip}" == *.* ]]; then
    pi6_tail="${pi6_ip##*:}"
    [[ "${pi6_tail}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a pi6_octets <<< "${pi6_tail}"
    for pi6_group in "${pi6_octets[@]}"; do ((10#${pi6_group} <= 255)) || return 1; done
    printf -v pi6_hex '%x:%x' "$((10#${pi6_octets[0]}*256+10#${pi6_octets[1]}))" "$((10#${pi6_octets[2]}*256+10#${pi6_octets[3]}))"
    pi6_ip="${pi6_ip%:*}:${pi6_hex}"
  fi
  if [[ "${pi6_ip}" == *::* ]]; then
    pi6_left="${pi6_ip%%::*}"; pi6_right="${pi6_ip#*::}"
    [[ "${pi6_right}" != *::* ]] || return 1
    [[ -z "${pi6_left}" ]] || IFS=: read -r -a pi6_lparts <<< "${pi6_left}"
    [[ -z "${pi6_right}" ]] || IFS=: read -r -a pi6_rparts <<< "${pi6_right}"
    pi6_missing=$((8-${#pi6_lparts[@]}-${#pi6_rparts[@]})); ((pi6_missing > 0)) || return 1
    pi6_parts=("${pi6_lparts[@]}")
    for ((pi6_i=0; pi6_i<pi6_missing; pi6_i++)); do pi6_parts+=(0); done
    pi6_parts+=("${pi6_rparts[@]}")
  else
    [[ "${pi6_ip}" != :* && "${pi6_ip}" != *: ]] || return 1
    IFS=: read -r -a pi6_parts <<< "${pi6_ip}"
    (( ${#pi6_parts[@]} == 8 )) || return 1
  fi
  for pi6_i in "${!pi6_parts[@]}"; do
    pi6_group="${pi6_parts[pi6_i]}"; [[ "${pi6_group}" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf -v 'pi6_parts[pi6_i]' '%x' "$((16#${pi6_group}))"
    if [[ "${pi6_parts[pi6_i]}" == 0 ]]; then
      ((pi6_run != 0)) || pi6_start="${pi6_i}"
      pi6_run=$((pi6_run+1))
      if ((pi6_run > pi6_best_length)); then pi6_best_start="${pi6_start}"; pi6_best_length="${pi6_run}"; fi
    else pi6_run=0; fi
  done
  for ((pi6_i=0; pi6_i<8; pi6_i++)); do
    if ((pi6_best_length >= 2 && pi6_i == pi6_best_start)); then
      pi6_text+='::'; pi6_i=$((pi6_i+pi6_best_length-1)); continue
    fi
    [[ -z "${pi6_text}" || "${pi6_text}" == *: ]] || pi6_text+=':'
    pi6_text+="${pi6_parts[pi6_i]}"
  done
  pi6_result="${pi6_text}"
}

cntools_pool_relays_normalize_into() {
  local -n prn_result="$1"
  local prn_json="$2" prn_relay='' prn_ipv6='' prn_normalized='[]'
  jq -e 'type == "array" and length <= 20' <<< "${prn_json}" >/dev/null || return 1
  while IFS= read -r prn_relay; do
    cntools_pool_relay_valid "${prn_relay}" || return 1
    if [[ "$(jq -r '.type' <<< "${prn_relay}")" == ip ]]; then
      prn_ipv6="$(jq -r .ipv6 <<< "${prn_relay}")"
      [[ -z "${prn_ipv6}" ]] || cntools_pool_ipv6_into prn_ipv6 "${prn_ipv6}" || return 1
      prn_relay="$(jq -c --arg ip6 "${prn_ipv6}" '.ipv6=$ip6' <<< "${prn_relay}")" || return 1
    fi
    prn_normalized="$(jq -c --argjson relay "${prn_relay}" '. + [$relay]' <<< "${prn_normalized}")" || return 1
  done < <(jq -c '.[]' <<< "${prn_json}")
  prn_result="${prn_normalized}"
}

cntools_pool_relay_valid() {
  local json="$1" kind='' dns='' ip='' octet='' canonical='' LC_ALL=C
  local -a octets=() labels=()
  jq -e 'type == "object" and
    (if .type == "dns" then keys == ["dns","port","type"] and (.dns|type == "string")
     elif .type == "srv" then keys == ["dns","type"] and (.dns|type == "string")
     elif .type == "ip" then keys == ["ipv4","ipv6","port","type"] and (.ipv4|type == "string") and (.ipv6|type == "string")
     else false end) and (.type == "srv" or (.port|type == "number" and . >= 1 and . <= 65535 and floor == .))' <<< "${json}" >/dev/null || return 1
  kind="$(jq -r .type <<< "${json}")"
  if [[ "${kind}" == dns || "${kind}" == srv ]]; then
    dns="$(jq -r .dns <<< "${json}")"
    [[ -n "${dns%.}" && ${#dns} -le 64 && "${dns}" != *..* ]] || return 1
    [[ "${kind}" != dns || "${dns}" != *_* ]] || return 1
    IFS=. read -r -a labels <<< "${dns%.}"
    for octet in "${labels[@]}"; do [[ "${octet}" =~ ^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$ && ${#octet} -le 63 ]] || return 1; done
  else
    ip="$(jq -r .ipv4 <<< "${json}")"
    if [[ -n "${ip}" ]]; then
      [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
      IFS=. read -r -a octets <<< "${ip}"
      for octet in "${octets[@]}"; do [[ "${octet}" == 0 || "${octet}" != 0* ]] && ((10#${octet} <= 255)) || return 1; done
    fi
    ip="$(jq -r .ipv6 <<< "${json}")"
    [[ -z "${ip}" ]] || cntools_pool_ipv6_into canonical "${ip}" || return 1
    [[ -n "${ip}" || "$(jq -r .ipv4 <<< "${json}")" != '' ]] || return 1
  fi
}

cntools_pool_metadata_valid() {
  local json="$1" url='' LC_ALL=C
  [[ "${json}" != null ]] || return 0
  jq -e 'type == "object" and keys == ["hash","url"] and
    (.hash|type == "string" and test("^[0-9a-f]{64}$")) and (.url|type == "string")' <<< "${json}" >/dev/null || return 1
  url="$(jq -r .url <<< "${json}")"
  [[ "${url}" =~ ^https?://[^[:space:][:cntrl:]]+$ && ${#url} -le 128 ]]
}

cntools_pool_metadata_file_hash_into() {
  local output_name="$1" file="$2" snapshot='' response='' errors='' pmh_hash='' status=0
  cntools_transaction_snapshot_into snapshot "${file}" 512 pool-metadata || return 1
  jq -se 'length == 1 and (.[0] | type == "object" and
    (.name|type == "string" and length > 0 and length <= 50) and
    (.description|type == "string" and length <= 255) and
    (.ticker|type == "string" and length >= 3 and length <= 5) and
    (.homepage|type == "string" and test("^https?://[^\\s]+$")))' "${snapshot}" >/dev/null || {
    cntools_transaction_set_error 'Pool metadata must be a JSON object of at most 512 bytes with name, description, ticker and homepage.'; return 1;
  }
  cntools_transaction_temp_file response pool-metadata-hash || return 1
  cntools_transaction_temp_file errors pool-metadata-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-pool metadata-hash \
    --pool-metadata-file "${snapshot}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Pool metadata hashing failed' "${status}" "${errors}" "${response}"; return 1; fi
  pmh_hash="$(< "${response}")"; [[ "${pmh_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf -v "${output_name}" '%s' "${pmh_hash}"
}

# Canonical ledger relay representation used for certificate verification.
cntools_pool_relays_ledger() {
  jq -ce 'map(if .type == "dns" then {"single host name":{dnsName:.dns,port:.port}}
    elif .type == "srv" then {"multi host name":{dnsName:.dns}}
    else {"single host address":{IPv4:(if .ipv4 == "" then null else .ipv4 end),IPv6:(if .ipv6 == "" then null else .ipv6 end),port:.port}} end)' <<< "$1"
}

cntools_pool_parameters_json() {
  local margin='' owners='' relays='' relay=''
  cntools_pool_parameter_uint "${CNTOOLS_POOL_REG_PLEDGE}" && cntools_pool_parameter_uint "${CNTOOLS_POOL_REG_COST}" &&
    cntools_uint_greater_equal "${CNTOOLS_POOL_REG_COST}" "${CNTOOLS_POOL_REG_MIN_COST}" || return 1
  margin="$(cntools_pool_margin_number "${CNTOOLS_POOL_REG_MARGIN}")" || return 1
  jq -e 'type == "array" and length > 0 and length <= 20 and
    ((map(.hash)|unique|length) == length) and all(.[]; (.hash|type == "string" and test("^[0-9a-f]{56}$")) and (.vkey|type == "string" and length > 0))' \
    <<< "${CNTOOLS_POOL_REG_OWNERS}" >/dev/null || return 1
  [[ "${CNTOOLS_POOL_REG_REWARD_HASH}" =~ ^[0-9a-f]{56}$ && -n "${CNTOOLS_POOL_REG_REWARD_VKEY}" ]] || return 1
  cntools_pool_metadata_valid "${CNTOOLS_POOL_REG_METADATA}" || return 1
  jq -e 'type == "array" and length <= 20' <<< "${CNTOOLS_POOL_REG_RELAYS}" >/dev/null || return 1
  while IFS= read -r relay; do cntools_pool_relay_valid "${relay}" || return 1; done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_RELAYS}")
  owners="$(jq -c 'map(.hash)|sort' <<< "${CNTOOLS_POOL_REG_OWNERS}")"
  relays="$(cntools_pool_relays_ledger "${CNTOOLS_POOL_REG_RELAYS}")" || return 1
  jq -cn --arg pool "${CNTOOLS_POOL_REG_HEX}" --arg vrf "${CNTOOLS_POOL_REG_VRF_HASH}" \
    --arg pledge "${CNTOOLS_POOL_REG_PLEDGE}" --arg cost "${CNTOOLS_POOL_REG_COST}" --argjson margin "${margin}" \
    --arg reward "${CNTOOLS_POOL_REG_REWARD_HASH}" --arg network "$([[ "${CNTOOLS_NETWORK}" == mainnet ]] && printf Mainnet || printf Testnet)" \
    --argjson owners "${owners}" --argjson relays "${relays}" --argjson metadata "${CNTOOLS_POOL_REG_METADATA}" '
    {poolId:$pool,vrf:$vrf,pledge:($pledge|tonumber),cost:($cost|tonumber),margin:$margin,
     accountAddress:{credential:{keyHash:$reward},network:$network},owners:$owners,relays:$relays,metadata:$metadata}'
}
