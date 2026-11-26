#!/usr/bin/env bash
# The stake pools a wallet is linked to: the pool its stake is delegated to
# and the pool registrations that name its stake address as an owner or as the
# reward account. Neither the node nor Koios can list the pools that name a
# stake address, so the registrations checked are those of the deployment's
# own pools and of the delegated pools. An owner's stake only counts toward the
# pledge while it is delegated to that pool, so that covers nearly every case.
# Local mode reads the registrations from the node; Koios adds tickers and
# answers for pools the node could not. Light mode uses Koios alone.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_LINK_POOLS=()
# By pool ID: the own pool's folder name, the Koios ticker, the state
# (registered, retiring:<epoch>, retired, not-registered, not-indexed; empty
# while unknown), the owners' stake addresses between spaces, the reward
# account's stake address, the same two for a pending update (set only when
# one exists), where the registration was read and the Koios pool_info record.
declare -Ag CNTOOLS_WALLET_LINK_OWN=() CNTOOLS_WALLET_LINK_TICKERS=() CNTOOLS_WALLET_LINK_STATES=()
declare -Ag CNTOOLS_WALLET_LINK_OWNERS=() CNTOOLS_WALLET_LINK_REWARDS=()
declare -Ag CNTOOLS_WALLET_LINK_NEXT_OWNERS=() CNTOOLS_WALLET_LINK_NEXT_REWARDS=()
declare -Ag CNTOOLS_WALLET_LINK_SOURCES=() CNTOOLS_WALLET_LINK_KOIOS=()
# Pools whose registration could be read by neither backend.
CNTOOLS_WALLET_LINK_UNCHECKED=0

cntools_wallet_link_reset() {
  CNTOOLS_WALLET_LINK_POOLS=()
  CNTOOLS_WALLET_LINK_OWN=(); CNTOOLS_WALLET_LINK_TICKERS=(); CNTOOLS_WALLET_LINK_STATES=()
  CNTOOLS_WALLET_LINK_OWNERS=(); CNTOOLS_WALLET_LINK_REWARDS=()
  CNTOOLS_WALLET_LINK_NEXT_OWNERS=(); CNTOOLS_WALLET_LINK_NEXT_REWARDS=()
  CNTOOLS_WALLET_LINK_SOURCES=(); CNTOOLS_WALLET_LINK_KOIOS=()
  CNTOOLS_WALLET_LINK_UNCHECKED=0
}

cntools_wallet_link_add_pool() {
  local link_pool='' link_hex=''
  cntools_pool_id_into link_pool link_hex "${1:-}" || return 1
  [[ " ${CNTOOLS_WALLET_LINK_POOLS[*]} " == *" ${link_pool} "* ]] ||
    CNTOOLS_WALLET_LINK_POOLS+=("${link_pool}")
}

# The deployment's own pools, named by their folders. A pool whose stored ID
# conflicts with its cold key is left out, as Pool → Show leaves it out.
cntools_wallet_link_own_pools() {
  local index=0 pool=''
  declare -F cntools_pool_catalog_build >/dev/null 2>&1 || return 0
  if ! cntools_pool_catalog_build; then
    cntools_wallet_log WARN 'Pool folders could not be read; only delegated pools are checked for pool roles'
    return 0
  fi
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    pool="${CNTOOLS_POOL_IDS[index]}"
    [[ -n "${pool}" && "${CNTOOLS_POOL_IDENTITIES[index]}" != 'Identity needs attention' ]] || continue
    [[ -n "${CNTOOLS_WALLET_LINK_OWN[${pool}]+x}" ]] || CNTOOLS_WALLET_LINK_OWN["${pool}"]="${CNTOOLS_POOL_NAMES[index]}"
    cntools_wallet_link_add_pool "${pool}" || true
  done
}

# A stake credential hash as the stake address of this network.
cntools_wallet_link_stake_address_into() {
  local _wlsa_output="$1" _wlsa_hash="${2,,}" _wlsa_kind="${3:-key}" _wlsa_header=e _wlsa_hrp=stake_test _wlsa_value=''
  [[ "${_wlsa_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${_wlsa_hash}" =~ ^[0-9a-f]{56}$ ]] || return 1
  [[ "${_wlsa_kind}" != script ]] || _wlsa_header=f
  if [[ "${CNTOOLS_NETWORK:-}" == mainnet ]]; then _wlsa_header+='1'; _wlsa_hrp=stake; else _wlsa_header+='0'; fi
  cntools_bech32_encode_into _wlsa_value "${_wlsa_header}${_wlsa_hash}" "${_wlsa_hrp}" || return 1
  printf -v "${_wlsa_output}" '%s' "${_wlsa_value}"
}

# "<hash> <hash>" or "<kind>:<hash>" from the node as stake addresses.
cntools_wallet_link_addresses_into() {
  local _wlas_output="$1" _wlas_list="$2" _wlas_item='' _wlas_address='' _wlas_result=''
  for _wlas_item in ${_wlas_list}; do
    if [[ "${_wlas_item}" == *:* ]]; then
      cntools_wallet_link_stake_address_into _wlas_address "${_wlas_item#*:}" "${_wlas_item%%:*}" || return 1
    else
      cntools_wallet_link_stake_address_into _wlas_address "${_wlas_item}" key || return 1
    fi
    _wlas_result+="${_wlas_result:+ }${_wlas_address}"
  done
  printf -v "${_wlas_output}" '%s' "${_wlas_result}"
}

cntools_wallet_link_parse_local() {
  local file="$1" rows='' hex='' state='' owners='' reward='' next_owners='' next_reward='' pool='' value='' bech=''
  shift
  jq -e '
    def hash: type == "string" and test("^[0-9a-f]{56}$");
    def params: type == "object" and (.spsOwners | type == "array" and all(.[]; hash)) and
      (.spsAccountId | type == "object" and ((.keyHash | hash) or (.scriptHash | hash)));
    type == "object" and all(to_entries[]; (.key | test("^[0-9a-f]{56}$")) and (.value | type == "object" and
      (.poolParams | params) and (.futurePoolParams == null or (.futurePoolParams | params)) and
      (.retiring == null or (.retiring | type == "number" and . >= 0 and floor == .))))
  ' "${file}" >/dev/null 2>&1 || return 1
  rows="$(jq -r '
    def account: if .spsAccountId.keyHash then "key:" + .spsAccountId.keyHash else "script:" + .spsAccountId.scriptHash end;
    to_entries[] | [.key,
      (if .value.retiring == null then "registered" else "retiring:" + (.value.retiring | tostring) end),
      (.value.poolParams.spsOwners | join(" ")), (.value.poolParams | account),
      (if .value.futurePoolParams == null then "-" else (.value.futurePoolParams.spsOwners | join(" ")) end),
      (if .value.futurePoolParams == null then "-" else (.value.futurePoolParams | account) end)] | join("\u001f")
  ' "${file}")" || return 1
  for pool in "$@"; do
    CNTOOLS_WALLET_LINK_STATES["${pool}"]=not-registered; CNTOOLS_WALLET_LINK_SOURCES["${pool}"]='Local node'
  done
  while IFS=$'\037' read -r hex state owners reward next_owners next_reward; do
    [[ -n "${hex}" ]] || continue
    cntools_pool_id_encode_into bech "${hex}" || return 1
    [[ -n "${CNTOOLS_WALLET_LINK_STATES[${bech}]+x}" ]] || continue
    CNTOOLS_WALLET_LINK_STATES["${bech}"]="${state}"
    cntools_wallet_link_addresses_into value "${owners}" && CNTOOLS_WALLET_LINK_OWNERS["${bech}"]="${value}" || return 1
    cntools_wallet_link_addresses_into value "${reward}" && CNTOOLS_WALLET_LINK_REWARDS["${bech}"]="${value}" || return 1
    [[ "${next_reward}" != - ]] || continue
    cntools_wallet_link_addresses_into value "${next_owners}" && CNTOOLS_WALLET_LINK_NEXT_OWNERS["${bech}"]="${value}" || return 1
    cntools_wallet_link_addresses_into value "${next_reward}" && CNTOOLS_WALLET_LINK_NEXT_REWARDS["${bech}"]="${value}" || return 1
  done <<< "${rows}"
}

# One pool-state query per batch of pools. A pool the node does not return is
# not registered (never registered, or retired).
cntools_wallet_link_query_local() {
  local response='' errors='' pool='' offset=0 status=0 failed=0
  local -a pools=("$@") batch=() arguments=()
  cntools_wallet_query_network_arguments || return 1
  for ((offset=0; offset<${#pools[@]}; offset+=25)); do
    batch=("${pools[@]:offset:25}"); arguments=()
    for pool in "${batch[@]}"; do arguments+=(--stake-pool-id "${pool}"); done
    cntools_wallet_query_temp_file response && cntools_wallet_query_temp_file errors || return 1
    status=0
    cntools_wallet_query_run_cli "${response}" "${errors}" "${CNTOOLS_CLI}" latest query pool-state "${arguments[@]}" \
      "${CNTOOLS_WALLET_NETWORK_ARGS[@]}" --socket-path "${CNTOOLS_SOCKET}" --output-json || status=$?
    if (( status != 0 )); then
      cntools_wallet_query_log_failure 'Local pool registration query failed' "${status}" "${errors}" "${response}"
      failed=1; continue
    fi
    if ! cntools_wallet_link_parse_local "${response}" "${batch[@]}"; then
      cntools_wallet_log ERROR 'Local pool registration query returned invalid JSON'
      for pool in "${batch[@]}"; do unset 'CNTOOLS_WALLET_LINK_STATES[${pool}]' 'CNTOOLS_WALLET_LINK_SOURCES[${pool}]'; done
      failed=1
    fi
  done
  return "${failed}"
}

# Tickers for every pool; the registration only for pools still unknown.
cntools_wallet_link_parse_koios() {
  local file="$1" ids='' rows='' pool='' state='' owners='' reward='' ticker='' record='' check='' hrp=stake_test
  shift
  [[ "${CNTOOLS_NETWORK:-}" != mainnet ]] || hrp=stake
  ids="$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')" || return 1
  jq -e --argjson ids "${ids}" --arg hrp "${hrp}" '
    def stake: type == "string" and test("^" + $hrp + "1[023456789acdefghjklmnpqrstuvwxyz]{53}$");
    type == "array" and ((map(.pool_id_bech32) | unique | length) == length) and all(.[];
      type == "object" and (.pool_id_bech32 as $id | $ids | index($id) != null) and
      (.pool_id_hex | type == "string" and test("^[0-9a-f]{56}$")) and
      (.pool_status == "registered" or .pool_status == "retiring" or .pool_status == "retired") and
      (.retiring_epoch == null or (.retiring_epoch | type == "number" and . >= 0 and floor == .)) and
      (.owners == null or (.owners | type == "array" and all(.[]; stake))) and
      (.reward_addr == null or (.reward_addr | stake)))
  ' "${file}" >/dev/null 2>&1 || return 1
  rows="$(jq -r '.[] | [.pool_id_bech32, .pool_id_hex,
      (if .pool_status == "retiring" and .retiring_epoch != null then "retiring:" + (.retiring_epoch | tostring) else .pool_status end),
      ((.owners // []) | join(" ")), (.reward_addr // ""),
      (.meta_json.ticker | if type == "string" then gsub("[[:cntrl:][:space:]]"; "") | .[0:12] else "" end)] | join("\u001f")' "${file}")" || return 1
  while IFS=$'\037' read -r pool record state owners reward ticker; do
    [[ -n "${pool}" ]] || continue
    cntools_pool_id_encode_into check "${record}" && [[ "${check}" == "${pool}" ]] || return 1
    CNTOOLS_WALLET_LINK_KOIOS["${pool}"]="$(jq -c --arg id "${pool}" '.[] | select(.pool_id_bech32 == $id)' "${file}")" || return 1
    [[ -z "${ticker}" ]] || CNTOOLS_WALLET_LINK_TICKERS["${pool}"]="${ticker}"
    [[ -z "${CNTOOLS_WALLET_LINK_STATES[${pool}]:-}" ]] || continue
    CNTOOLS_WALLET_LINK_STATES["${pool}"]="${state}"; CNTOOLS_WALLET_LINK_SOURCES["${pool}"]='Koios API'
    CNTOOLS_WALLET_LINK_OWNERS["${pool}"]="${owners}"; CNTOOLS_WALLET_LINK_REWARDS["${pool}"]="${reward}"
  done <<< "${rows}"
  # Koios does not index a pool that was never registered.
  for pool in "$@"; do
    [[ -n "${CNTOOLS_WALLET_LINK_STATES[${pool}]:-}" || -n "${CNTOOLS_WALLET_LINK_KOIOS[${pool}]+x}" ]] && continue
    CNTOOLS_WALLET_LINK_STATES["${pool}"]=not-indexed; CNTOOLS_WALLET_LINK_SOURCES["${pool}"]='Koios API'
  done
}

cntools_wallet_link_query_koios() {
  local response='' payload='' offset=0 failed=0
  local -a pools=("$@") batch=()
  for ((offset=0; offset<${#pools[@]}; offset+=100)); do
    batch=("${pools[@]:offset:100}")
    cntools_wallet_query_temp_file response || return 1
    payload="$(printf '%s\n' "${batch[@]}" | jq -Rsc '{_pool_bech32_ids:split("\n")[:-1]}')" || return 1
    if ! cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/pool_info" "${payload}" "${response}" 8388608; then
      cntools_wallet_log ERROR 'Koios pool_info request for pool roles failed'; failed=1; continue
    fi
    cntools_wallet_link_parse_koios "${response}" "${batch[@]}" ||
      { cntools_wallet_log ERROR 'Koios pool_info for pool roles returned invalid JSON'; failed=1; }
  done
  return "${failed}"
}

# cntools_wallet_link_collect <delegated pool>...: reads the registrations of
# the deployment's own pools and of the given delegated pools.
cntools_wallet_link_collect() {
  local pool='' koios=N
  local -a pending=()
  cntools_wallet_link_reset
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  cntools_wallet_link_own_pools
  for pool in "$@"; do [[ -z "${pool}" ]] || cntools_wallet_link_add_pool "${pool}" || true; done
  (( ${#CNTOOLS_WALLET_LINK_POOLS[@]} > 0 )) || return 0
  if [[ "${CNTOOLS_MODE}" == local ]]; then
    [[ "${CNTOOLS_KOIOS_ENABLED:-N}" != Y || "${CNTOOLS_KOIOS_API:-}" != https://* ]] || koios=Y
    if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true && -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" &&
          -z "${CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE:-}" ]] && cntools_wallet_query_local_socket_ready; then
      cntools_wallet_link_query_local "${CNTOOLS_WALLET_LINK_POOLS[@]}" ||
        cntools_wallet_log WARN 'Some pool registrations could not be read from the local node'
    fi
  elif [[ "${CNTOOLS_KOIOS_API:-}" == https://* ]]; then
    koios=Y
  fi
  [[ "${koios}" != Y ]] || cntools_wallet_link_query_koios "${CNTOOLS_WALLET_LINK_POOLS[@]}" || true
  for pool in "${CNTOOLS_WALLET_LINK_POOLS[@]}"; do
    [[ -n "${CNTOOLS_WALLET_LINK_STATES[${pool}]:-}" ]] || pending+=("${pool}")
  done
  CNTOOLS_WALLET_LINK_UNCHECKED="${#pending[@]}"
  cntools_wallet_log WALLET "pool links checked pools=${#CNTOOLS_WALLET_LINK_POOLS[@]} unchecked=${#pending[@]} koios=${koios}"
}

# A pool as the user knows it: ticker, own folder name, or the pool ID.
cntools_wallet_link_pool_label_into() {
  local _wlpl_output="$1" _wlpl_pool="$2" _wlpl_long="${3:-N}" _wlpl_ticker='' _wlpl_own='' _wlpl_label=''
  _wlpl_ticker="${CNTOOLS_WALLET_LINK_TICKERS[${_wlpl_pool}]:-}"; _wlpl_own="${CNTOOLS_WALLET_LINK_OWN[${_wlpl_pool}]:-}"
  _wlpl_label="${_wlpl_ticker:-${_wlpl_own}}"
  [[ -z "${_wlpl_ticker}" || -z "${_wlpl_own}" || "${_wlpl_ticker,,}" == "${_wlpl_own,,}" ]] || _wlpl_label+=" (${_wlpl_own})"
  if [[ -z "${_wlpl_label}" ]]; then _wlpl_label="${_wlpl_pool}"
  elif [[ "${_wlpl_long}" == Y ]]; then _wlpl_label+=" · ${_wlpl_pool}"; fi
  printf -v "${_wlpl_output}" '%s' "${_wlpl_label}"
}

# The delegated pool's state as "<note>\037<theme role>"; nothing while it
# is registered or unknown.
cntools_wallet_link_delegation_note() {
  local state="${CNTOOLS_WALLET_LINK_STATES[${1:-}]:-}"
  case "${state}" in
    retiring:*) printf 'pool retiring in epoch %s\037warning\n' "${state#retiring:}" ;;
    retired|not-registered) printf 'pool not registered, so this stake earns no rewards\037danger\n' ;;
  esac
}

# The roles of one stake address in the checked registrations, one line per
# role: pool, "Owner" or "Reward account", note, theme role (\037-separated).
# <registered> is yes, no or unknown; <delegated> the pool the stake follows.
cntools_wallet_link_roles() {
  local reward="${1:-}" registered="${2:-unknown}" delegated="${3:-}" pool='' now='' next='' note='' level=''
  [[ "${reward}" == stake* ]] || return 0
  for pool in "${CNTOOLS_WALLET_LINK_POOLS[@]}"; do
    case "${CNTOOLS_WALLET_LINK_STATES[${pool}]:-}" in registered|retiring:*) ;; *) continue ;; esac
    now=N; next=N
    [[ " ${CNTOOLS_WALLET_LINK_OWNERS[${pool}]:-} " != *" ${reward} "* ]] || now=Y
    if [[ -n "${CNTOOLS_WALLET_LINK_NEXT_REWARDS[${pool}]+x}" ]]; then
      [[ " ${CNTOOLS_WALLET_LINK_NEXT_OWNERS[${pool}]} " != *" ${reward} "* ]] || next=Y
    else next="${now}"; fi
    if [[ "${now}" == Y || "${next}" == Y ]]; then
      note=''; level=value
      if [[ "${now}" == N ]]; then note='added by a pending update'
      elif [[ "${next}" == N ]]; then note='removed by a pending update'; fi
      if [[ "${next}" == Y && "${registered}" == no ]]; then
        note+="${note:+ · }stake address not registered, so it does not count toward the pledge"; level=warning
      elif [[ "${next}" == Y && "${registered}" == yes && "${delegated}" != "${pool}" ]]; then
        note+="${note:+ · }stake not delegated to this pool, so it does not count toward the pledge"; level=warning
      fi
      printf '%s\037Owner\037%s\037%s\n' "${pool}" "${note}" "${level}"
    fi
    now=N; next=N
    [[ "${CNTOOLS_WALLET_LINK_REWARDS[${pool}]:-}" != "${reward}" ]] || now=Y
    if [[ -n "${CNTOOLS_WALLET_LINK_NEXT_REWARDS[${pool}]+x}" ]]; then
      [[ "${CNTOOLS_WALLET_LINK_NEXT_REWARDS[${pool}]}" != "${reward}" ]] || next=Y
    else next="${now}"; fi
    if [[ "${now}" == Y || "${next}" == Y ]]; then
      note=''; level=value
      if [[ "${now}" == N ]]; then note='added by a pending update'
      elif [[ "${next}" == N ]]; then note='removed by a pending update'; fi
      if [[ "${next}" == Y && "${registered}" == no ]]; then
        note+="${note:+ · }stake address not registered, so the pool's rewards go to the treasury"; level=danger
      fi
      printf '%s\037Reward account\037%s\037%s\n' "${pool}" "${note}" "${level}"
    fi
  done
}

# Where the checked registrations came from, for a table title.
cntools_wallet_link_source_into() {
  local _wl_output="$1" _wl_pool='' _wl_source='' _wl_seen=''
  shift
  for _wl_pool in "$@"; do
    _wl_source="${CNTOOLS_WALLET_LINK_SOURCES[${_wl_pool}]:-}"
    [[ -n "${_wl_source}" ]] || continue
    if [[ -z "${_wl_seen}" ]]; then _wl_seen="${_wl_source}"
    elif [[ "${_wl_seen}" != "${_wl_source}" ]]; then _wl_seen=mixed; fi
  done
  case "${_wl_seen}" in 'Local node') _wl_seen='local node' ;; 'Koios API') _wl_seen=Koios ;; *) _wl_seen='' ;; esac
  printf -v "${_wl_output}" '%s' "${_wl_seen}"
}

# Show: the wallet's pool roles as a table, drawn like its other tables.
cntools_wallet_link_role_rows() {
  local rows="${1:-}" pool='' role='' note='' level='' label=''
  cntools_table_row "Pool role" "Stake pool" || return 1
  while IFS=$'\037' read -r pool role note level; do
    [[ -n "${pool}" ]] || continue
    cntools_wallet_link_pool_label_into label "${pool}" Y
    [[ "${level}" != value ]] || level=identifier
    cntools_table_wrapped_pair "${role}" "${label}${note:+ · ${note}}" 16 "${level}" || return 1
  done <<< "${rows}"
}

cntools_wallet_link_render_roles() {
  local reward="${1:-}" registered="${2:-unknown}" delegated="${3:-}" rows='' pool='' role='' note='' level='' source=''
  local -a pools=()
  rows="$(cntools_wallet_link_roles "${reward}" "${registered}" "${delegated}")" || return 1
  [[ -n "${rows}" ]] || return 0
  while IFS=$'\037' read -r pool role note level; do [[ -z "${pool}" ]] || pools+=("${pool}"); done <<< "${rows}"
  cntools_wallet_link_source_into source "${pools[@]}"
  cntools_wallet_render_rows_table "Stake pool roles${source:+ · ${source}}" cntools_wallet_link_role_rows "${rows}"
}

# List: the pool delegation and pool roles of catalog wallet <index>, once
# its stake address was queried.
cntools_wallet_link_catalog_rows() {
  local index="${1:-}" reward='' registered='' delegated='' value='' role='' note='' level='' rows='' pool='' kind=''
  reward="${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]:-}"
  registered="${CNTOOLS_WALLET_LIST_STAKE_REGISTERED[index]:-}"
  delegated="${CNTOOLS_WALLET_LIST_POOL_DELEGATIONS[index]:-}"
  [[ -n "${reward}" && -n "${registered}" ]] || return 0
  if [[ -n "${delegated}" ]]; then
    cntools_wallet_link_pool_label_into value "${delegated}"
    role=identifier
    IFS=$'\037' read -r note level < <(cntools_wallet_link_delegation_note "${delegated}") || true
    [[ -z "${note}" ]] || { value+=" · ${note}"; role="${level}"; }
  elif [[ "${registered}" == yes ]]; then
    value='Not delegated'; role=muted
  else
    value='Not delegated · stake address not registered'; role=muted
  fi
  cntools_table_wrapped_triple "" "Pool delegation" "${value}" 20 22 "" value "${role}" || return 1
  rows="$(cntools_wallet_link_roles "${reward}" "${registered}" "${delegated}")" || return 1
  while IFS=$'\037' read -r pool kind note level; do
    [[ -n "${pool}" ]] || continue
    cntools_wallet_link_pool_label_into value "${pool}"
    [[ "${level}" != value ]] || level=identifier
    [[ "${kind}" == Owner ]] && kind='Pool owner' || kind='Pool reward account'
    cntools_table_wrapped_triple "" "${kind}" "${value}${note:+ · ${note}}" 20 22 "" value "${level}" || return 1
  done <<< "${rows}"
}
