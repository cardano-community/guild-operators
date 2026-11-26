#!/usr/bin/env bash
# Optional read-only chain inspection. Koios requests are batched; no metadata URL fetching.
# shellcheck disable=SC2034
declare -a CNTOOLS_POOL_CHAIN_STATUS=() CNTOOLS_POOL_CHAIN_SOURCE=() CNTOOLS_POOL_CURRENT=() CNTOOLS_POOL_FUTURE=()
declare -a CNTOOLS_POOL_RETIREMENT=() CNTOOLS_POOL_CHAIN_METADATA=()
# Calidus registration (CIP-151 metadata, so Koios only): status text, its
# theme role and the registered Calidus ID. Empty while not checked.
declare -a CNTOOLS_POOL_CALIDUS_STATUS=() CNTOOLS_POOL_CALIDUS_ROLE=() CNTOOLS_POOL_CALIDUS_ID=()

cntools_pool_inspect_reset() {
  local index=0
  CNTOOLS_POOL_CHAIN_STATUS=(); CNTOOLS_POOL_CHAIN_SOURCE=(); CNTOOLS_POOL_CURRENT=(); CNTOOLS_POOL_FUTURE=()
  CNTOOLS_POOL_RETIREMENT=(); CNTOOLS_POOL_CHAIN_METADATA=()
  CNTOOLS_POOL_CALIDUS_STATUS=(); CNTOOLS_POOL_CALIDUS_ROLE=(); CNTOOLS_POOL_CALIDUS_ID=()
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    CNTOOLS_POOL_CHAIN_STATUS[index]='Not checked'; CNTOOLS_POOL_CHAIN_SOURCE[index]=''
    CNTOOLS_POOL_CURRENT[index]='{}'; CNTOOLS_POOL_FUTURE[index]='{}'
    CNTOOLS_POOL_RETIREMENT[index]=''; CNTOOLS_POOL_CHAIN_METADATA[index]='{}'
    CNTOOLS_POOL_CALIDUS_STATUS[index]=''; CNTOOLS_POOL_CALIDUS_ROLE[index]=''; CNTOOLS_POOL_CALIDUS_ID[index]=''
  done
}

cntools_pool_inspect_eligible() {
  [[ -n "${CNTOOLS_POOL_IDS[$1]}" && "${CNTOOLS_POOL_IDENTITIES[$1]}" != 'Identity needs attention' ]]
}

cntools_pool_inspect_local_parse() {
  local index="$1" file="$2" data="" current="" future="" retirement=""
  data="$(jq -ce --arg hex "${CNTOOLS_POOL_HEX_IDS[index]}" --arg bech "${CNTOOLS_POOL_IDS[index]}" '
    select(type == "object") |
    if length == 0 then {} elif length == 1 then (.[$hex] // .[$bech] // error("pool identity mismatch"))
    else error("unexpected pools") end
  ' "${file}" 2>/dev/null)" || return 1
  if [[ "${data}" == '{}' ]]; then
    CNTOOLS_POOL_CHAIN_STATUS[index]='Not registered'; CNTOOLS_POOL_CHAIN_SOURCE[index]='Local node'; return 0
  fi
  jq -e '
    def uint: (type == "number" and . >= 0 and floor == .) or (type == "string" and test("^[0-9]+$"));
    def params: type == "object" and (.spsPledge | uint) and (.spsCost | uint) and
      (.spsMargin | type == "number" and . >= 0 and . <= 1) and
      (.spsOwners | type == "array") and (.spsRelays | type == "array");
    (.poolParams | params) and (has("futurePoolParams")) and
    (.futurePoolParams == null or (.futurePoolParams | params)) and has("retiring") and
    (.retiring == null or (.retiring | type == "number" and . >= 0 and floor == .))
  ' <<< "${data}" >/dev/null 2>&1 || return 1
  current="$(jq -c '.poolParams' <<< "${data}")" || return 1
  future="$(jq -c '.futurePoolParams // {}' <<< "${data}")" || return 1
  retirement="$(jq -r '.retiring // empty' <<< "${data}")" || return 1
  CNTOOLS_POOL_CURRENT[index]="${current}"; CNTOOLS_POOL_FUTURE[index]="${future}"
  CNTOOLS_POOL_RETIREMENT[index]="${retirement}"; CNTOOLS_POOL_CHAIN_SOURCE[index]='Local node'
  CNTOOLS_POOL_CHAIN_STATUS[index]=Registered
  [[ -z "${retirement}" ]] || CNTOOLS_POOL_CHAIN_STATUS[index]=Retiring
}

cntools_pool_inspect_local() {
  local index="$1" response="" errors="" status=0
  local -a network=()
  cntools_transaction_temp_file response pool-inspect || return 1
  cntools_transaction_temp_file errors pool-inspect-errors || return 1
  cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest query pool-state \
    --stake-pool-id "${CNTOOLS_POOL_IDS[index]}" "${network[@]}" --socket-path "${CNTOOLS_SOCKET}" --output-json || status=$?
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure 'Pool inspection failed' "${status}" "${errors}" "${response}"; return 1
  fi
  if ! cntools_pool_inspect_local_parse "${index}" "${response}"; then
    cntools_transaction_log ERROR "Invalid local pool-state response pool=${CNTOOLS_POOL_IDS[index]}"
    return 1
  fi
}

cntools_pool_inspect_koios_parse() {
  local file="$1" index=0 record="" count=0 ids=""
  shift
  # Validate the complete response before applying any results. Duplicates or
  # unrelated pools are malformed data, not evidence of an unregistered pool.
  ids="$(printf '%s\n' "$@" | while read -r index; do printf '%s\n' "${CNTOOLS_POOL_IDS[index]}"; done | jq -Rsc 'split("\n")[:-1]')" || return 1
  jq -e --argjson ids "${ids}" '
    type == "array" and (length <= ($ids | length)) and
    ((map(.pool_id_bech32) | unique | length) == length) and all(.[];
      type == "object" and (.pool_id_bech32 as $id | $ids | index($id) != null) and
      (.pool_id_hex | type == "string" and test("^[0-9a-f]{56}$")) and
      (.pool_status == "registered" or .pool_status == "retiring" or .pool_status == "retired") and
      has("retiring_epoch") and (.retiring_epoch == null or (.retiring_epoch | type == "number" and . >= 0 and floor == .)) and
      (.pool_status != "retiring" or .retiring_epoch != null) and
      (.pledge | type == "string" and test("^[0-9]+$")) and
      (.fixed_cost | type == "string" and test("^[0-9]+$")) and
      (.margin | type == "number" and . >= 0 and . <= 1) and
      (.owners | type == "array") and (.relays | type == "array"))
  ' "${file}" >/dev/null 2>&1 || return 1
  for index in "$@"; do
    count="$(jq --arg id "${CNTOOLS_POOL_IDS[index]}" '[.[] | select(.pool_id_bech32 == $id)] | length' "${file}")" || return 1
    if (( count != 0 )); then
      jq -e --arg id "${CNTOOLS_POOL_IDS[index]}" --arg hex "${CNTOOLS_POOL_HEX_IDS[index]}" \
        '.[] | select(.pool_id_bech32 == $id) | .pool_id_hex == $hex' "${file}" >/dev/null || return 1
    fi
  done
  for index in "$@"; do
    record="$(jq -c --arg id "${CNTOOLS_POOL_IDS[index]}" '[.[] | select(.pool_id_bech32 == $id)] | .[0] // {}' "${file}")" || return 1
    CNTOOLS_POOL_CHAIN_SOURCE[index]='Koios API'
    if [[ "${record}" == '{}' ]]; then
      CNTOOLS_POOL_CHAIN_STATUS[index]='Not indexed'; continue
    fi
    case "$(jq -r '.pool_status' <<< "${record}")" in
      registered) CNTOOLS_POOL_CHAIN_STATUS[index]=Registered ;;
      retiring) CNTOOLS_POOL_CHAIN_STATUS[index]=Retiring ;;
      retired) CNTOOLS_POOL_CHAIN_STATUS[index]=Retired ;;
    esac
    CNTOOLS_POOL_RETIREMENT[index]="$(jq -r '.retiring_epoch // empty' <<< "${record}")"
    CNTOOLS_POOL_CURRENT[index]="${record}"
    CNTOOLS_POOL_CHAIN_METADATA[index]="$(jq -c '.meta_json | if type == "object" then . else {} end' <<< "${record}")"
  done
}

cntools_pool_inspect_koios() {
  local response="" payload="" index=0
  cntools_transaction_temp_file response pool-inspect-koios || return 1
  payload="$(printf '%s\n' "$@" | while read -r index; do printf '%s\n' "${CNTOOLS_POOL_IDS[index]}"; done |
    jq -Rsc '{_pool_bech32_ids:(split("\n")[:-1] | unique)}')" || return 1
  cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/pool_info" "${payload}" "${response}" 8388608 || return 1
  cntools_pool_inspect_koios_parse "${response}" "$@"
}

cntools_pool_inspect_catalog() {
  local index=0 offset=0
  local -a pending=() batch=() indices=("$@")
  cntools_pool_inspect_reset
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  (( ${#indices[@]} != 0 )) || indices=("${!CNTOOLS_POOL_NAMES[@]}")
  for index in "${indices[@]}"; do
    cntools_pool_inspect_eligible "${index}" || continue
    CNTOOLS_POOL_CHAIN_STATUS[index]=Unavailable
    if [[ "${CNTOOLS_MODE}" == local && "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true && -n "${CNTOOLS_SOCKET:-}" ]]; then
      if cntools_pool_inspect_local "${index}"; then continue; fi
      cntools_transaction_log WARN "Local pool inspection unavailable pool=${CNTOOLS_POOL_NAMES[index]}; considering Koios fallback"
    fi
    pending+=("${index}")
  done
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]]; then
    # Bounded requests, including all requested IDs; no response-side limit.
    for ((offset=0; offset<${#pending[@]}; offset+=100)); do
      batch=("${pending[@]:offset:100}")
      if ! cntools_pool_inspect_koios "${batch[@]}"; then
        cntools_transaction_log ERROR 'Koios pool inspection failed or returned invalid data'
      fi
    done
  fi
  for index in "${indices[@]}"; do
    cntools_transaction_log POOL "Inspection pool=${CNTOOLS_POOL_NAMES[index]} status=${CNTOOLS_POOL_CHAIN_STATUS[index]} source=${CNTOOLS_POOL_CHAIN_SOURCE[index]:-none}"
  done
}

# The node has metadata URL/hash, not its content. Enrich a successful local
# Show through Koios without replacing authoritative local state or pending data.
cntools_pool_inspect_metadata() {
  local index="$1" response="" payload="" metadata=""
  [[ "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_POOL_CHAIN_SOURCE[index]}" == 'Local node' &&
     "${CNTOOLS_POOL_CURRENT[index]}" != '{}' && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y &&
     "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]] || return 0
  cntools_transaction_temp_file response pool-metadata || return 1
  payload="$(jq -cn --arg pool "${CNTOOLS_POOL_IDS[index]}" '{_pool_bech32_ids:[$pool]}')" || return 1
  if cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/pool_info" "${payload}" "${response}" &&
      metadata="$(jq -ce --arg id "${CNTOOLS_POOL_IDS[index]}" --arg hex "${CNTOOLS_POOL_HEX_IDS[index]}" '
        select(type == "array" and length <= 1) |
        if length == 0 then {} else .[0] | select(.pool_id_bech32 == $id and .pool_id_hex == $hex) |
          .meta_json | if type == "object" then . else {} end end
      ' "${response}" 2>/dev/null)"; then
    CNTOOLS_POOL_CHAIN_METADATA[index]="${metadata}"
  else
    cntools_transaction_log WARN "Optional Koios pool metadata unavailable pool=${CNTOOLS_POOL_IDS[index]}"
  fi
}

# The public key of a pool's Calidus verification key (normal or extended
# envelope), read without the CLI. Empty without one; 1 when it is invalid.
cntools_pool_calidus_local_public_into() {
  local output="$1" index="$2" filename='' file='' cbor=''
  printf -v "${output}" '%s' ''
  cntools_pool_file_name_into filename calidus-vkey || return 1
  file="${CNTOOLS_POOL_DIRECTORIES[index]}/${filename}"
  [[ -e "${file}" || -L "${file}" ]] || return 0
  cntools_pool_public_file_safe "${file}" 65536 || return 1
  cbor="$(jq -er 'select(.type == "PaymentVerificationKeyShelley_ed25519" or
    .type == "PaymentExtendedVerificationKeyShelley_ed25519") | .cborHex | ascii_downcase' "${file}" 2>/dev/null)" || return 1
  [[ "${cbor}" =~ ^5820([0-9a-f]{64})$ || "${cbor}" =~ ^5840([0-9a-f]{64})[0-9a-f]{64}$ ]] || return 1
  printf -v "${output}" '%s' "${BASH_REMATCH[1]}"
}

cntools_pool_calidus_status_set() {
  CNTOOLS_POOL_CALIDUS_STATUS[$1]="$2"; CNTOOLS_POOL_CALIDUS_ROLE[$1]="$3"; CNTOOLS_POOL_CALIDUS_ID[$1]="${4:-}"
}

# Calidus registration of the given pools (default: all) from Koios
# pool_calidus_keys, compared with each pool's local Calidus key. CIP-151
# registrations are transaction metadata, not ledger state, so the node cannot
# answer. A pool without a local key shows a status only when one is on chain.
cntools_pool_inspect_calidus() {
  local index=0 offset=0 response='' url='' record='' state='' public='' key=N epoch='' status='' role='' ids=''
  local -a indices=("$@") pools=() batch=()
  local -A has_key=() local_public=() records=() failed=()
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  (( ${#indices[@]} != 0 )) || indices=("${!CNTOOLS_POOL_NAMES[@]}")
  for index in "${indices[@]}"; do
    cntools_pool_inspect_eligible "${index}" || continue
    cntools_pool_key_state_into state "${CNTOOLS_POOL_DIRECTORIES[index]}" calidus-skey || return 1
    key=N; [[ "${state}" == Missing ]] || key=Y
    if cntools_pool_calidus_local_public_into public "${index}"; then
      [[ -z "${public}" ]] || key=Y
    else
      key=Y; public=invalid
    fi
    has_key["${index}"]="${key}"; local_public["${index}"]="${public}"
    pools+=("${index}")
  done
  (( ${#pools[@]} != 0 )) || return 0
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" != Y || ! "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]]; then
    for index in "${pools[@]}"; do
      [[ "${has_key[${index}]}" != Y ]] || cntools_pool_calidus_status_set "${index}" 'Not checked · needs Koios' muted
    done
    return 0
  fi
  for ((offset=0; offset<${#pools[@]}; offset+=40)); do
    batch=("${pools[@]:offset:40}")
    ids="$(for index in "${batch[@]}"; do printf '%s\n' "${CNTOOLS_POOL_IDS[index]}"; done | jq -Rsc 'split("\n")[:-1]')" || return 1
    url="${CNTOOLS_KOIOS_API%/}/pool_calidus_keys?pool_id_bech32=in.%28$(jq -r 'join("%2C")' <<< "${ids}")%29"
    url+='&select=pool_id_bech32%2Ccalidus_nonce%3A%3Atext%2Ccalidus_pub_key%2Ccalidus_id_bech32%2Ctx_hash%2Cepoch_no%2Cregistered'
    cntools_transaction_temp_file response pool-calidus-status || return 1
    if cntools_wallet_query_http "${url}" '' "${response}" 2097152 GET && jq -e --argjson ids "${ids}" '
        type == "array" and ((map(.pool_id_bech32) | unique | length) == length) and all(.[];
          (.pool_id_bech32 as $id | $ids | index($id) != null) and
          (.calidus_nonce | type == "string" and test("^(0|[1-9][0-9]*)$")) and
          (.calidus_pub_key | type == "string" and test("^[0-9a-f]{64}$")) and
          (.tx_hash | type == "string" and test("^[0-9a-f]{64}$")) and
          (.epoch_no == null or (.epoch_no | type == "number" and . >= 0 and floor == .)) and
          (.registered | type == "boolean") and (.registered == (.calidus_pub_key != ("0" * 64))) and
          (if .registered then (.calidus_id_bech32 | type == "string" and test("^calidus1[0-9a-z]+$")) else true end))
      ' "${response}" >/dev/null 2>&1; then
      for index in "${batch[@]}"; do
        records["${index}"]="$(jq -c --arg id "${CNTOOLS_POOL_IDS[index]}" '.[] | select(.pool_id_bech32 == $id)' "${response}")" || return 1
      done
    else
      cntools_transaction_log WARN 'Koios Calidus registration lookup failed or returned invalid data'
      for index in "${batch[@]}"; do failed["${index}"]=Y; done
    fi
  done
  for index in "${pools[@]}"; do
    key="${has_key[${index}]}"; public="${local_public[${index}]}"; record="${records[${index}]:-}"
    if [[ -n "${failed[${index}]:-}" ]]; then
      [[ "${key}" != Y ]] || cntools_pool_calidus_status_set "${index}" Unavailable muted
      continue
    fi
    if [[ -z "${record}" ]]; then
      [[ "${key}" != Y ]] || cntools_pool_calidus_status_set "${index}" 'Not registered' warning
      continue
    fi
    epoch="$(jq -r '.epoch_no // empty' <<< "${record}")"
    if [[ "$(jq -r .registered <<< "${record}")" == true ]]; then
      if [[ "${public}" == "$(jq -r .calidus_pub_key <<< "${record}")" ]]; then status='Registered · this key'; role=success
      elif [[ "${public}" == invalid ]]; then status='Registered · local verification key is invalid'; role=warning
      elif [[ -n "${public}" ]]; then status='A different key is registered'; role=warning
      elif [[ "${key}" == Y ]]; then status='Registered · not compared, no Calidus verification key'; role=value
      else status='Registered · key not in this pool folder'; role=value; fi
      [[ -z "${epoch}" ]] || status+=" · epoch ${epoch}"
      cntools_pool_calidus_status_set "${index}" "${status}" "${role}" "$(jq -r .calidus_id_bech32 <<< "${record}")"
    else
      status=Revoked; [[ -z "${epoch}" ]] || status+=" · epoch ${epoch}"
      cntools_pool_calidus_status_set "${index}" "${status}" "$([[ "${key}" == Y ]] && printf warning || printf muted)"
    fi
    cntools_transaction_log POOL "Calidus pool=${CNTOOLS_POOL_NAMES[index]} status=${CNTOOLS_POOL_CALIDUS_STATUS[index]}"
  done
}

cntools_pool_inspect_show() {
  cntools_pool_inspect_catalog "$1" && cntools_pool_inspect_metadata "$1" && cntools_pool_inspect_calidus "$1"
}

# Pool List: every pool's registration and Calidus registration.
cntools_pool_inspect_list() {
  cntools_pool_inspect_catalog && cntools_pool_inspect_calidus
}

# Read public local JSON only. Missing/invalid data never hides the pool itself.
cntools_pool_local_json_into() {
  local output="$1" index="$2" kind="$3" filename="" file="" document='{}'
  cntools_pool_file_name_into filename "${kind}" || return 2
  file="${CNTOOLS_POOL_DIRECTORIES[index]}/${filename}"
  if [[ -e "${file}" || -L "${file}" ]]; then
    if cntools_pool_public_file_safe "${file}" 262144 && document="$(jq -ce 'select(type == "object")' "${file}" 2>/dev/null)"; then
      :
    else
      document='{}'; cntools_pool_warning_add "${index}" "Invalid or unsafe ${filename} ignored"
    fi
  fi
  printf -v "${output}" '%s' "${document}"
}
