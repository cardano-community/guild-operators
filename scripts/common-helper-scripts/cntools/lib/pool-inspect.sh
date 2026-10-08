#!/usr/bin/env bash
# Optional read-only chain inspection. Koios requests are batched; no metadata URL fetching.
# shellcheck disable=SC2034
declare -a CNTOOLS_POOL_CHAIN_STATUS=() CNTOOLS_POOL_CHAIN_SOURCE=() CNTOOLS_POOL_CURRENT=() CNTOOLS_POOL_FUTURE=()
declare -a CNTOOLS_POOL_RETIREMENT=() CNTOOLS_POOL_CHAIN_METADATA=()

cntools_pool_inspect_reset() {
  local index=0
  CNTOOLS_POOL_CHAIN_STATUS=(); CNTOOLS_POOL_CHAIN_SOURCE=(); CNTOOLS_POOL_CURRENT=(); CNTOOLS_POOL_FUTURE=()
  CNTOOLS_POOL_RETIREMENT=(); CNTOOLS_POOL_CHAIN_METADATA=()
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    CNTOOLS_POOL_CHAIN_STATUS[index]='Not checked'; CNTOOLS_POOL_CHAIN_SOURCE[index]=''
    CNTOOLS_POOL_CURRENT[index]='{}'; CNTOOLS_POOL_FUTURE[index]='{}'
    CNTOOLS_POOL_RETIREMENT[index]=''; CNTOOLS_POOL_CHAIN_METADATA[index]='{}'
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

cntools_pool_inspect_show() {
  cntools_pool_inspect_catalog "$1" && cntools_pool_inspect_metadata "$1"
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
