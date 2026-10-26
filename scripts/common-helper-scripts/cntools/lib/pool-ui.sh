#!/usr/bin/env bash
# Pool views share the content-sized, themed key/value tables used by wallets.

cntools_pool_status_role() {
  case "$1" in Registered) printf success ;; Retiring|Unavailable|Retired) printf warning ;; *) printf muted ;; esac
}

cntools_pool_identity_rows() {
  local index="$1" detailed="${2:-N}" state="" kind="" filename="" title="" role=""
  cntools_table_pair Name "${CNTOOLS_POOL_NAMES[index]}" identifier
  [[ -z "${CNTOOLS_POOL_IDS[index]}" ]] || cntools_table_pair 'Pool ID' "${CNTOOLS_POOL_IDS[index]}" identifier
  if [[ "${detailed}" == Y && -n "${CNTOOLS_POOL_HEX_IDS[index]}" ]]; then
    cntools_table_pair 'Pool ID (hex)' "${CNTOOLS_POOL_HEX_IDS[index]}" identifier
  fi
  role=muted
  [[ "${CNTOOLS_POOL_IDENTITIES[index]}" != 'Verified cold public key' ]] || role=success
  [[ "${CNTOOLS_POOL_IDENTITIES[index]}" != 'Identity needs attention' ]] || role=warning
  cntools_table_pair Identity "${CNTOOLS_POOL_IDENTITIES[index]}" "${role}"
  cntools_table_pair 'Cold key' "${CNTOOLS_POOL_PROTECTIONS[index]}" "$([[ "${CNTOOLS_POOL_PROTECTIONS[index]}" == Missing ]] && printf warning || printf value)"
  cntools_pool_key_state_into state "${CNTOOLS_POOL_DIRECTORIES[index]}" calidus-skey || return 1
  if [[ "${state}" == Missing ]] && cntools_pool_file_name_into filename calidus-vkey &&
     [[ -f "${CNTOOLS_POOL_DIRECTORIES[index]}/${filename}" && ! -L "${CNTOOLS_POOL_DIRECTORIES[index]}/${filename}" ]]; then
    state='Public only'
  fi
  [[ "${state}" == Missing ]] || cntools_table_pair 'Calidus key' "${state}" value
  if [[ "${detailed}" == Y ]]; then
    for kind in kes-skey vrf-skey; do
      cntools_pool_key_state_into state "${CNTOOLS_POOL_DIRECTORIES[index]}" "${kind}" || return 1
      [[ "${kind}" != kes-skey ]] && title='VRF key' || title='KES key'
      cntools_table_pair "${title}" "${state}" "$([[ "${state}" == Missing ]] && printf warning || printf value)"
    done
    for kind in kes-vkey vrf-vkey counter opcert; do
      # The health rows below show the counter and certificate values; a
      # presence row would repeat them.
      [[ "${kind}" != counter || -z "${CNTOOLS_POOL_CERT_NEXT[index]:-}" ]] || continue
      [[ "${kind}" != opcert || -z "${CNTOOLS_POOL_CERT_DISK[index]:-}" ]] || continue
      cntools_pool_file_name_into filename "${kind}" || return 1
      state=Missing; role=warning
      if cntools_pool_public_file_safe "${CNTOOLS_POOL_DIRECTORIES[index]}/${filename}"; then state=Present; role=value; fi
      case "${kind}" in kes-vkey) title='KES public key' ;; vrf-vkey) title='VRF public key' ;; counter) title="Issue counter · ${filename}" ;; opcert) title="Operational certificate · ${filename}" ;; esac
      cntools_table_pair "${title}" "${state}" "${role}"
    done
  fi
  cntools_table_pair 'Pool registration' "${CNTOOLS_POOL_CHAIN_STATUS[index]}" "$(cntools_pool_status_role "${CNTOOLS_POOL_CHAIN_STATUS[index]}")"
  cntools_pool_health_rows "${index}" "${detailed}"
  [[ -z "${CNTOOLS_POOL_RETIREMENT[index]}" ]] || cntools_table_pair 'Retirement epoch' "$(cntools_number_format "${CNTOOLS_POOL_RETIREMENT[index]}")" warning
  [[ -z "${CNTOOLS_POOL_CHAIN_SOURCE[index]}" ]] || cntools_table_pair 'Data source' "${CNTOOLS_POOL_CHAIN_SOURCE[index]}" muted
  if [[ "${detailed}" != Y && "${CNTOOLS_POOL_CURRENT[index]}" != '{}' ]]; then
    local format=local label="" value="" value_role=""
    [[ "${CNTOOLS_POOL_CHAIN_SOURCE[index]}" != 'Koios API' ]] || format=koios
    while IFS=$'\037' read -r label value value_role; do
      case "${label}" in Pledge|'Fixed cost'|Margin) cntools_table_pair "${label}" "${value}" "${value_role}" ;; esac
    done < <(cntools_pool_settings_rows "${CNTOOLS_POOL_CURRENT[index]}" "${format}")
  fi
  [[ -z "${CNTOOLS_POOL_WARNINGS[index]}" ]] || cntools_table_pair Attention "${CNTOOLS_POOL_WARNINGS[index]}" warning
}

# Parse only known public fields, never render arbitrary pool.config contents.
cntools_pool_settings_rows() {
  local json="$1" format="$2" label="" value="" kind="" formatted="" records=""
  records="$(jq -r --arg format "${format}" '
    def row($caption; $value; $kind):
      if ($value | type == "string" or type == "number") then [$caption, ($value|tostring), $kind] | join("\u001f") else empty end;
    # A fraction as a percent with at most six decimals (no float artefacts).
    def pct: (. * 100000000 | round) as $u |
      ($u / 1000000 | floor | tostring) + (($u % 1000000) as $f | if $f == 0 then "" else "." + ((1000000 + $f) | tostring | .[1:] | sub("0+$"; "")) end);
    if $format == "local" then
      row("Pledge"; .spsPledge; "lovelace"), row("Fixed cost"; .spsCost; "lovelace"),
      row("Margin"; (.spsMargin | pct); "percent"),
      (if .spsAccountId.keyHash then row("Reward account"; .spsAccountId.keyHash; "stakekey")
       else row("Reward account"; .spsAccountId.scriptHash; "stakescript") end),
      row("VRF hash"; .spsVrf; "identifier"), row("Pool deposit"; .spsDeposit; "lovelace"),
      row("Metadata URL"; .spsMetadata.url; "identifier"), row("Metadata hash"; .spsMetadata.hash; "identifier")
    elif $format == "koios" then
      row("Pledge"; .pledge; "lovelace"), row("Fixed cost"; .fixed_cost; "lovelace"), row("Margin"; (.margin | pct); "percent"),
      row("Effective epoch"; .active_epoch_no; "number"), row("Reward account"; .reward_addr; "stakeaddress"),
      row("Reward DRep delegation"; .reward_addr_delegated_drep; "identifier"), row("VRF hash"; .vrf_key_hash; "identifier"),
      row("Pool deposit"; .deposit; "lovelace"), row("Metadata URL"; .meta_url; "identifier"), row("Metadata hash"; .meta_hash; "identifier"),
      row("Active stake"; .active_stake; "lovelace"), row("Live stake"; .live_stake; "lovelace"), row("Live pledge"; .live_pledge; "lovelace"),
      row("Delegators"; .live_delegators; "number"), row("Saturation"; .live_saturation; "percent"), row("Blocks produced"; .block_count; "number")
    elif .schema == 1 then
      row("Pledge"; .pledgeLovelace; "lovelace"), row("Fixed cost"; .costLovelace; "lovelace"),
      row("Margin"; (try (.margin | if test("^[0-9]+/[1-9][0-9]*$") then split("/") | (.[0]|tonumber)/(.[1]|tonumber) else tonumber end | pct) catch empty); "percent"),
      row("Reward wallet"; .reward.label; "identifier"), row("Main owner"; .owners[0].label; "identifier"),
      row("Metadata URL"; .metadata.url; "identifier")
    else
      row("Pledge"; .pledgeADA; "ada"), row("Fixed cost"; .costADA; "ada"), row("Margin"; .margin; "percent"),
      row("Reward wallet"; .rewardWallet; "identifier"), row("Pledge wallet"; .pledgeWallet; "identifier"), row("Metadata URL"; .json_url; "identifier")
    end | gsub("[\\r\\n\\t]"; " ")
  ' <<< "${json}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r label value kind; do
    [[ -n "${kind}" ]] || continue
    case "${kind}" in
      lovelace)
        [[ "${value}" =~ ^[0-9]+$ ]] || continue
        formatted="$(cntools_number_format_lovelace "${value}")" || return 1; kind=number ;;
      ada|percent|number)
        cntools_number_format_into formatted "${value}" || continue
        [[ "${kind}" != ada ]] || formatted+=' ADA'
        [[ "${kind}" != percent ]] || formatted+=' %'
        kind=number ;;
      stakekey|stakescript|stakeaddress)
        cntools_pool_ui_account_into formatted "${value}" "${kind}"; kind=address ;;
      *) formatted="${value}" ;;
    esac
    cntools_table_pair "${label}" "${formatted}" "${kind}" || return 1
  done <<< "${records}"
}

# A stake credential from local node data as its stake address, with the
# local wallet that holds it when one does: "stake1… · wallet".
declare -Ag CNTOOLS_POOL_UI_WALLET_BY_ACCOUNT=()
CNTOOLS_POOL_UI_WALLETS_READ=N
cntools_pool_ui_account_into() {
  local pua_output="$1" pua_value="$2" pua_kind="${3:-stakekey}" pua_header='e' pua_address='' pua_index=0 pua_reward=''
  if [[ "${pua_value}" =~ ^[0-9a-f]{56}$ ]] && declare -F cntools_bech32_encode_into >/dev/null 2>&1; then
    [[ "${pua_kind}" != stakescript ]] || pua_header='f'
    [[ "${CNTOOLS_NETWORK:-}" == mainnet ]] && pua_header+='1' || pua_header+='0'
    cntools_bech32_encode_into pua_address "${pua_header}${pua_value}" "$([[ "${CNTOOLS_NETWORK:-}" == mainnet ]] && printf stake || printf stake_test)" ||
      pua_address=''
  elif [[ "${pua_value}" == stake* ]]; then
    pua_address="${pua_value}"
  fi
  [[ -n "${pua_address}" ]] || { printf -v "${pua_output}" '%s' "${pua_value}"; return 0; }
  # Local wallets' cached reward addresses, read once per action.
  if [[ "${CNTOOLS_POOL_UI_WALLETS_READ}" != Y ]]; then
    CNTOOLS_POOL_UI_WALLETS_READ=Y
    if declare -F cntools_wallet_catalog_build >/dev/null 2>&1 && declare -F cntools_wallet_read_address >/dev/null 2>&1 &&
       cntools_wallet_catalog_build >/dev/null 2>&1; then
      for pua_index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
        pua_reward=''
        cntools_wallet_read_address "${CNTOOLS_WALLET_PATHS[pua_index]}" reward pua_reward >/dev/null 2>&1 && [[ -n "${pua_reward}" ]] || continue
        CNTOOLS_POOL_UI_WALLET_BY_ACCOUNT["${pua_reward}"]="${CNTOOLS_WALLET_NAMES[pua_index]}"
      done
    fi
  fi
  printf -v "${pua_output}" '%s' "${pua_address}${CNTOOLS_POOL_UI_WALLET_BY_ACCOUNT[${pua_address}]:+ · ${CNTOOLS_POOL_UI_WALLET_BY_ACCOUNT[${pua_address}]}}"
}

cntools_pool_members_rows() {
  local json="$1" format="$2" records="" label="" value="" role=""
  records="$(jq -r --arg format "${format}" '
    def row($caption; $value; $role): [$caption, $value, $role] | map(tostring | gsub("[[:cntrl:]]"; " ")) | join("\u001f");
    (if $format == "local" then .spsOwners else .owners end | if type == "array" then . else [] end) | to_entries[] |
      (if $format == "config" then .value | if type == "object" then (.label // .wallet_name) else null end else .value end) as $owner |
      select($owner | type == "string") | row("Owner " + ((.key+1)|tostring); $owner; (if $format == "config" then "identifier" else "account" end))
  ' <<< "${json}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r label value role; do
    [[ -n "${role}" ]] || continue
    # Owners from chain data read as stake addresses and local wallet names.
    if [[ "${role}" == account ]]; then cntools_pool_ui_account_into value "${value}" stakekey; role=address; fi
    cntools_table_pair "${label}" "${value}" "${role}"
  done <<< "${records}"
}

cntools_pool_relays_rows() {
  local json="$1" format="$2" records="" label="" value="" role=""
  records="$(jq -r --arg format "${format}" '
    (if $format == "local" then .spsRelays else .relays end | if type == "array" then . else [] end) | to_entries[] |
    .key as $index | .value | select(type == "object") |
    (if $format == "local" then (."single host address" // ."single host name" // ."multi host name") else . end) |
    select(type == "object") |
    [(.type // empty), (.address // empty), (.IPv4 // .ipv4 // empty), (.IPv6 // .ipv6 // empty), (.dnsName // .dns // .srv // empty),
     (if (.port | type == "number" or type == "string") and .port != "" then "port " + (.port|tostring) else empty end)] |
    map(select(type == "string" or type == "number") | tostring) |
    ["Relay " + (($index+1)|tostring), join(" · "), "identifier"] |
    map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")
  ' <<< "${json}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r label value role; do [[ -z "${role}" ]] || cntools_table_pair "${label}" "${value}" "${role}"; done <<< "${records}"
}

# All rows of one settings record: values, owners and relays.
cntools_pool_settings_all_rows() {
  cntools_pool_settings_rows "$1" "$2" && cntools_pool_members_rows "$1" "$2" && cntools_pool_relays_rows "$1" "$2"
}

# With a baseline record (the current settings), only rows that differ.
cntools_pool_render_settings() {
  local title="$1" json="$2" format="$3" baseline="${4:-}" rows="" record="" shown=""
  local -A unchanged=()
  [[ "${json}" != '{}' ]] || return 0
  rows="$(cntools_pool_settings_all_rows "${json}" "${format}")" || return 1
  if [[ -n "${baseline}" && "${baseline}" != '{}' ]]; then
    while IFS= read -r record; do [[ -z "${record}" ]] || unchanged["${record}"]=Y; done < <(cntools_pool_settings_all_rows "${baseline}" "${format}")
  fi
  while IFS= read -r record; do
    [[ -n "${record}" && -z "${unchanged[${record}]:-}" ]] || continue
    shown+="${record}"$'\n'
  done <<< "${rows}"
  [[ -z "${shown}" ]] || { printf '\n'; printf '%s' "${shown}" | cntools_table_render "${title}"; }
}

# The descriptive fields Show compares and renders.
cntools_pool_metadata_fields() {
  jq -cS '{name, ticker, homepage, description} | with_entries(select(.value | type == "string" and length > 0))' <<< "$1" 2>/dev/null
}

cntools_pool_render_metadata() {
  local title="$1" json="$2" records="" key="" value=""
  records="$(jq -r '
    ["name", "ticker", "homepage", "description"][] as $key | .[$key] |
    select(type == "string" and length > 0) | [$key, gsub("[[:cntrl:]]"; " ")] | join("\u001f")
  ' <<< "${json}" 2>/dev/null)" || return 1
  [[ -n "${records}" ]] || return 0
  printf '\n'
  {
    while IFS=$'\037' read -r key value; do
      cntools_table_pair "${key^}" "${value}" "$([[ "${key}" == homepage ]] && printf identifier || printf value)"
    done <<< "${records}"
  } | cntools_table_render "${title}"
}

# Comparable chain settings: amounts in lovelace, margin in exact units,
# reward and owners as credential hashes (null when one cannot be read).
cntools_pool_chain_compare_into() {
  local pcc_output="$1" pcc_json="$2" pcc_format="$3" pcc_hrp=stake_test pcc_raw='' pcc_address='' pcc_reward=null pcc_owners='[]' pcc_result=''
  if [[ "${pcc_format}" == koios ]]; then
    [[ "${CNTOOLS_NETWORK:-}" != mainnet ]] || pcc_hrp=stake
    pcc_address="$(jq -r '.reward_addr // empty' <<< "${pcc_json}")" || return 1
    if [[ -n "${pcc_address}" ]] && cntools_bech32_decode_into pcc_raw "${pcc_address}" "${pcc_hrp}" && [[ "${pcc_raw}" =~ ^e[01][0-9a-f]{56}$ ]]; then
      pcc_reward="\"${pcc_raw:2}\""
    fi
    while IFS= read -r pcc_address; do
      pcc_raw=''
      if cntools_bech32_decode_into pcc_raw "${pcc_address}" "${pcc_hrp}" && [[ "${pcc_raw}" =~ ^e[01][0-9a-f]{56}$ ]]; then
        pcc_owners="$(jq -c --arg hash "${pcc_raw:2}" '. + [$hash]' <<< "${pcc_owners}")" || return 1
      else pcc_owners=null; break; fi
    done < <(jq -r '.owners // [] | .[]' <<< "${pcc_json}")
  fi
  pcc_result="$(jq -c --arg format "${pcc_format}" --argjson reward "${pcc_reward}" --argjson owners "${pcc_owners}" '
    def units: if type == "number" then . * 100000000 | round else null end;
    if $format == "local" then
      {pledge:(.spsPledge|tostring), cost:(.spsCost|tostring), margin:(.spsMargin|units), metadata:(.spsMetadata.url // ""),
       reward:(.spsAccountId.keyHash // .spsAccountId.scriptHash), owners:(.spsOwners // [] | sort)}
    else
      {pledge:(.pledge|tostring), cost:(.fixed_cost|tostring), margin:(.margin|units), metadata:(.meta_url // ""),
       reward:$reward, owners:(if $owners == null then null else $owners | sort end)}
    end' <<< "${pcc_json}" 2>/dev/null)" || return 1
  printf -v "${pcc_output}" '%s' "${pcc_result}"
}

# Local draft rows that differ from both the current and pending chain
# settings. Only pledge, fixed cost, margin, metadata URL, reward account and
# owners are compared; relays are compared on chain, not against the draft.
cntools_pool_render_config_changes() {
  local config="$1" format="$2" index="$3" current='' pending=null records='' label='' value='' kind='' formatted='' rows=''
  [[ "${config}" != '{}' ]] || return 0
  cntools_pool_chain_compare_into current "${CNTOOLS_POOL_CURRENT[index]}" "${format}" || return 1
  if [[ "${CNTOOLS_POOL_FUTURE[index]}" != '{}' ]]; then
    cntools_pool_chain_compare_into pending "${CNTOOLS_POOL_FUTURE[index]}" "${format}" || return 1
  fi
  records="$(jq -r --argjson current "${current}" --argjson pending "${pending}" '
    def units: if type == "number" then . * 100000000 | round
      elif type == "string" and test("^[0-9]+/[1-9][0-9]*$") then split("/") | (.[0]|tonumber) * (100000000 / (.[1]|tonumber)) | round
      elif type == "string" then (try (tonumber * 100000000 | round) catch null) else null end;
    def lovelace: try ((tonumber * 1000000) | round | tostring) catch null;
    def pct: (. / 1000000 | floor | tostring) + ((. % 1000000) as $f | if $f == 0 then "" else "." + ((1000000 + $f) | tostring | .[1:] | sub("0+$"; "")) end);
    (if .schema == 1 then
      {pledge:(.pledgeLovelace|tostring), cost:(.costLovelace|tostring), margin:(.margin|units), metadata:(.metadata.url // ""),
       reward:(.reward.hash // null), owners:(.owners // [] | map(.hash) | if all(.[]; type == "string") then sort else null end),
       rewardLabel:(.reward.label // .reward.hash // ""), ownerLabels:(.owners // [] | map(.label // .hash) | join(", "))}
    else
      {pledge:(.pledgeADA|lovelace), cost:(.costADA|lovelace), margin:(try ((.margin|tonumber) * 1000000 | round) catch null),
       metadata:(.json_url // ""), reward:null, owners:null}
    end) as $draft |
    def differs($field): $draft[$field] != null and $current[$field] != null and $draft[$field] != $current[$field] and
      ($pending == null or $pending[$field] == null or $draft[$field] != $pending[$field]);
    (if differs("pledge") then ["Pledge", $draft.pledge, "lovelace"] else empty end),
    (if differs("cost") then ["Fixed cost", $draft.cost, "lovelace"] else empty end),
    (if differs("margin") then ["Margin", ($draft.margin | pct), "percent"] else empty end),
    (if differs("reward") then ["Reward wallet", $draft.rewardLabel, "identifier"] else empty end),
    (if differs("owners") then ["Owners", $draft.ownerLabels, "identifier"] else empty end),
    (if differs("metadata") then ["Metadata URL", (if $draft.metadata == "" then "None" else $draft.metadata end), "identifier"] else empty end)
    | map(tostring | gsub("[[:cntrl:]]"; " ")) | join("\u001f")
  ' <<< "${config}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r label value kind; do
    [[ -n "${kind}" ]] || continue
    case "${kind}" in
      lovelace) [[ "${value}" =~ ^[0-9]+$ ]] || continue; formatted="$(cntools_number_format_lovelace "${value}")" || return 1; kind=number ;;
      percent) cntools_number_format_into formatted "${value}" || continue; formatted+=' %'; kind=number ;;
      *) formatted="${value}" ;;
    esac
    rows+="$(cntools_table_pair "${label}" "${formatted}" "${kind}")"$'\n' || return 1
  done <<< "${records}"
  [[ -z "${rows}" ]] || { printf '\n'; printf '%s' "${rows}" | cntools_table_render 'Local draft · differs from chain'; }
}

cntools_pool_render_catalog() {
  local index=0
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    ((index == 0)) || printf '\n'
    cntools_pool_identity_rows "${index}" | cntools_table_render "$((index + 1)) · ${CNTOOLS_POOL_NAMES[index]}" || return 1
  done
}

cntools_pool_action_list() {
  local status=0 index=0 query_node=N
  cntools_ui_action_begin List '/ Pool / List'
  if ! cntools_pool_catalog_build; then
    cntools_ui_render_status error "The pool directory could not be read safely. See ${CNTOOLS_LOG}."; cntools_ui_wait; return 1
  fi
  if (( ${#CNTOOLS_POOL_NAMES[@]} == 0 )); then cntools_pool_empty_notice; return 0; fi
  cntools_pool_inspect_reset
  # As Wallet List: node queries can be slow, so local mode asks in both
  # styles; Koios (light mode) is fetched at once.
  if [[ "${CNTOOLS_MODE:-offline}" != offline ]]; then
    status=0
    if [[ "${CNTOOLS_MODE}" == local && "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true ]]; then
      cntools_ui_confirm 'Fetch on-chain information for all pools now? This can take a while on mainnet.' || status=$?
    fi
    if ((status == 0)); then
      cntools_transaction_log CHOICE 'Pool list chain information requested'
      cntools_ui_spin_function 'Fetching pool information…' cntools_pool_inspect_catalog || return 1
      query_node=Y
    else
      (( status == 1 )) || return "${status}"
      cntools_transaction_log CHOICE 'Pool list chain information skipped'
    fi
  fi
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    cntools_ui_spin_function 'Checking pool KES health…' cntools_pool_health_collect "${index}" "${query_node}" || return 1
  done
  cntools_pool_render_catalog || return 1
  cntools_ui_wait
}

cntools_pool_action_show() {
  local selected="" config="" metadata="" format="" status=0
  cntools_ui_action_begin Show '/ Pool / Show'
  if ! cntools_pool_catalog_build; then
    cntools_ui_render_status error "The pool directory could not be read safely. See ${CNTOOLS_LOG}."; cntools_ui_wait; return 1
  fi
  if (( ${#CNTOOLS_POOL_NAMES[@]} == 0 )); then cntools_pool_empty_notice; return 0; fi
  cntools_pool_choose_into selected || status=$?
  ((status != 1)) || return 0
  ((status == 0)) || return "${status}"
  cntools_pool_local_json_into config "${selected}" config || return 1
  cntools_pool_local_json_into metadata "${selected}" metadata || return 1
  if [[ "${CNTOOLS_MODE:-offline}" == offline ]]; then
    cntools_pool_inspect_reset
  else
    cntools_ui_spin_function 'Fetching pool information…' cntools_pool_inspect_show "${selected}" || return 1
  fi
  cntools_ui_action_begin Show '/ Pool / Show'
  cntools_ui_spin_function 'Checking pool KES health…' cntools_pool_health_collect "${selected}" || return 1
  cntools_pool_identity_rows "${selected}" Y | cntools_table_render Pool || return 1
  local anchor_url='' anchor_hash='' local_fields='' shown_fields=''
  if [[ "${CNTOOLS_POOL_CHAIN_SOURCE[selected]}" == 'Local node' ]]; then
    format=local
    cntools_pool_render_settings 'Current on-chain settings · local node' "${CNTOOLS_POOL_CURRENT[selected]}" "${format}" || return 1
    cntools_pool_render_settings 'Pending changes · next epoch' "${CNTOOLS_POOL_FUTURE[selected]}" "${format}" "${CNTOOLS_POOL_CURRENT[selected]}" || return 1
  else
    format=koios
    cntools_pool_render_settings 'Latest indexed registration · Koios API' "${CNTOOLS_POOL_CURRENT[selected]}" "${format}" || return 1
  fi
  # A registered pool's draft only matters where it differs from the chain.
  if [[ "${CNTOOLS_POOL_CURRENT[selected]}" != '{}' ]]; then
    cntools_pool_render_config_changes "${config}" "${format}" "${selected}" || return 1
  else
    cntools_pool_render_settings 'Local configuration · not proof of registration' "${config}" config || return 1
  fi
  # One metadata table: indexed content when Koios has it, otherwise the
  # verified published bytes on request; a local copy only when it differs.
  local_fields="$(cntools_pool_metadata_fields "${metadata}")" || local_fields='{}'
  if [[ "${CNTOOLS_POOL_CHAIN_METADATA[selected]}" != '{}' ]]; then
    cntools_pool_render_metadata 'Indexed metadata · Koios API · descriptive only' "${CNTOOLS_POOL_CHAIN_METADATA[selected]}" || return 1
    shown_fields="$(cntools_pool_metadata_fields "${CNTOOLS_POOL_CHAIN_METADATA[selected]}")" || shown_fields=''
  else
    anchor_url="$(jq -r '.spsMetadata.url // .meta_url // ""' <<< "${CNTOOLS_POOL_CURRENT[selected]}")"
    anchor_hash="$(jq -r '.spsMetadata.hash // .meta_hash // ""' <<< "${CNTOOLS_POOL_CURRENT[selected]}")"
    CNTOOLS_PUBLIC_METADATA_FILE=''
    cntools_public_metadata_offer "${anchor_url}" "${anchor_hash}" 1024 || return 1
    if [[ -n "${CNTOOLS_PUBLIC_METADATA_FILE}" && -z "${CNTOOLS_PUBLIC_METADATA_ERROR}" ]]; then
      shown_fields="$(cntools_pool_metadata_fields "$(< "${CNTOOLS_PUBLIC_METADATA_FILE}")")" || shown_fields=''
    fi
  fi
  if [[ "${local_fields}" != '{}' && "${local_fields}" != "${shown_fields}" ]]; then
    cntools_pool_render_metadata "$([[ -n "${shown_fields}" ]] && printf 'Local metadata · differs from published' || printf 'Local metadata · descriptive only')" "${metadata}" || return 1
  fi
  cntools_ui_wait
}
