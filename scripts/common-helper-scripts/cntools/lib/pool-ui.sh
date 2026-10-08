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
  if [[ "${detailed}" == Y ]]; then
    for kind in kes-skey vrf-skey; do
      cntools_pool_key_state_into state "${CNTOOLS_POOL_DIRECTORIES[index]}" "${kind}" || return 1
      [[ "${kind}" != kes-skey ]] && title='VRF key' || title='KES key'
      cntools_table_pair "${title}" "${state}" "$([[ "${state}" == Missing ]] && printf warning || printf value)"
    done
    for kind in kes-vkey vrf-vkey counter opcert; do
      cntools_pool_file_name_into filename "${kind}" || return 1
      state=Missing; role=warning
      if cntools_pool_public_file_safe "${CNTOOLS_POOL_DIRECTORIES[index]}/${filename}"; then state=Present; role=value; fi
      case "${kind}" in kes-vkey) title='KES public key' ;; vrf-vkey) title='VRF public key' ;; counter) title='Certificate counter' ;; opcert) title='Operational certificate' ;; esac
      cntools_table_pair "${title}" "${state}" "${role}"
    done
  fi
  cntools_table_pair 'Pool registration' "${CNTOOLS_POOL_CHAIN_STATUS[index]}" "$(cntools_pool_status_role "${CNTOOLS_POOL_CHAIN_STATUS[index]}")"
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
    def row($label; $value; $kind):
      if ($value | type == "string" or type == "number") then [$label, ($value|tostring), $kind] | join("\u001f") else empty end;
    if $format == "local" then
      row("Pledge"; .spsPledge; "lovelace"), row("Fixed cost"; .spsCost; "lovelace"),
      row("Margin"; (.spsMargin * 100); "percent"), row("Reward credential"; (.spsAccountId.keyHash // .spsAccountId.scriptHash); "identifier"),
      row("VRF hash"; .spsVrf; "identifier"), row("Pool deposit"; .spsDeposit; "lovelace"),
      row("Metadata URL"; .spsMetadata.url; "identifier"), row("Metadata hash"; .spsMetadata.hash; "identifier")
    elif $format == "koios" then
      row("Pledge"; .pledge; "lovelace"), row("Fixed cost"; .fixed_cost; "lovelace"), row("Margin"; (.margin * 100); "percent"),
      row("Effective epoch"; .active_epoch_no; "number"), row("Reward address"; .reward_addr; "address"),
      row("Reward DRep delegation"; .reward_addr_delegated_drep; "identifier"), row("VRF hash"; .vrf_key_hash; "identifier"),
      row("Pool deposit"; .deposit; "lovelace"), row("Metadata URL"; .meta_url; "identifier"), row("Metadata hash"; .meta_hash; "identifier"),
      row("Active stake"; .active_stake; "lovelace"), row("Live stake"; .live_stake; "lovelace"), row("Live pledge"; .live_pledge; "lovelace"),
      row("Delegators"; .live_delegators; "number"), row("Saturation"; .live_saturation; "percent"), row("Blocks produced"; .block_count; "number")
    elif .schema == 1 then
      row("Pledge"; .pledgeLovelace; "lovelace"), row("Fixed cost"; .costLovelace; "lovelace"),
      row("Margin"; (try (.margin | if test("^[0-9]+/[1-9][0-9]*$") then split("/") | (.[0]|tonumber)/(.[1]|tonumber)*100 else tonumber*100 end) catch empty); "percent"),
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
        formatted="$(cntools_wallet_format_lovelace "${value}")" || return 1; kind=number ;;
      ada|percent|number)
        cntools_number_format_into formatted "${value}" || continue
        [[ "${kind}" != ada ]] || formatted+=' ADA'
        [[ "${kind}" != percent ]] || formatted+=' %'
        kind=number ;;
      *) formatted="${value}" ;;
    esac
    cntools_table_pair "${label}" "${formatted}" "${kind}" || return 1
  done <<< "${records}"
}

cntools_pool_members_rows() {
  local json="$1" format="$2" records="" label="" value="" role=""
  records="$(jq -r --arg format "${format}" '
    def row($label; $value; $role): [$label, $value, $role] | map(tostring | gsub("[[:cntrl:]]"; " ")) | join("\u001f");
    (if $format == "local" then .spsOwners else .owners end | if type == "array" then . else [] end) | to_entries[] |
      (if $format == "config" then .value | if type == "object" then (.label // .wallet_name) else null end else .value end) as $owner |
      select($owner | type == "string") | row("Owner " + ((.key+1)|tostring); $owner; "identifier")
  ' <<< "${json}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r label value role; do [[ -z "${role}" ]] || cntools_table_pair "${label}" "${value}" "${role}"; done <<< "${records}"
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

cntools_pool_render_settings() {
  local title="$1" json="$2" format="$3" members="" relays="" settings=""
  [[ "${json}" != '{}' ]] || return 0
  settings="$(cntools_pool_settings_rows "${json}" "${format}")" || return 1
  members="$(cntools_pool_members_rows "${json}" "${format}")" || return 1
  relays="$(cntools_pool_relays_rows "${json}" "${format}")" || return 1
  [[ -z "${settings}${members}${relays}" ]] || {
    printf '\n'; printf '%s\n%s\n%s\n' "${settings}" "${members}" "${relays}" | cntools_table_render "${title}"
  }
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

cntools_pool_render_catalog() {
  local index=0
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    ((index == 0)) || printf '\n'
    cntools_pool_identity_rows "${index}" | cntools_table_render "$((index + 1)) · ${CNTOOLS_POOL_NAMES[index]}" || return 1
  done
}

cntools_pool_action_list() {
  local status=0
  cntools_ui_action_begin List '/ Pool / List'
  if ! cntools_pool_catalog_build; then
    cntools_ui_render_status error "The pool directory could not be read safely. See ${CNTOOLS_LOG}."; cntools_ui_wait; return 1
  fi
  if (( ${#CNTOOLS_POOL_NAMES[@]} == 0 )); then
    cntools_ui_render_status info 'No local pools are available.'; cntools_ui_wait; return 0
  fi
  cntools_pool_inspect_reset
  if [[ "${CNTOOLS_MODE:-offline}" != offline ]]; then
    if cntools_ui_confirm 'Fetch on-chain information for all pools now?' false; then
      cntools_transaction_log CHOICE 'Pool list chain information requested'
      cntools_ui_spin_function 'Fetching pool information…' cntools_pool_inspect_catalog || return 1
    else
      status=$?; (( status == 1 )) || return "${status}"
      cntools_transaction_log CHOICE 'Pool list chain information skipped'
    fi
  fi
  cntools_pool_render_catalog || return 1
  cntools_ui_wait
}

cntools_pool_action_show() {
  local selected="" config="" metadata="" format="" status=0
  cntools_ui_action_begin Show '/ Pool / Show'
  if ! cntools_pool_catalog_build; then
    cntools_ui_render_status error "The pool directory could not be read safely. See ${CNTOOLS_LOG}."; cntools_ui_wait; return 1
  fi
  if (( ${#CNTOOLS_POOL_NAMES[@]} == 0 )); then
    cntools_ui_render_status info 'No local pools are available.'; cntools_ui_wait; return 0
  fi
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
  cntools_pool_identity_rows "${selected}" Y | cntools_table_render Pool || return 1
  cntools_pool_render_settings 'Local configuration · not proof of registration' "${config}" config || return 1
  if [[ "${CNTOOLS_POOL_CHAIN_SOURCE[selected]}" == 'Local node' ]]; then
    format=local
    cntools_pool_render_settings 'Current on-chain settings · local node' "${CNTOOLS_POOL_CURRENT[selected]}" "${format}" || return 1
    cntools_pool_render_settings 'Pending settings · next epoch' "${CNTOOLS_POOL_FUTURE[selected]}" "${format}" || return 1
  else
    format=koios
    cntools_pool_render_settings 'Latest indexed registration · Koios API' "${CNTOOLS_POOL_CURRENT[selected]}" "${format}" || return 1
  fi
  cntools_pool_render_metadata 'Local metadata · descriptive only' "${metadata}" || return 1
  cntools_pool_render_metadata 'Indexed metadata · Koios API · descriptive only' "${CNTOOLS_POOL_CHAIN_METADATA[selected]}" || return 1
  cntools_ui_wait
}
