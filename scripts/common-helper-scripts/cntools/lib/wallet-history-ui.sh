#!/usr/bin/env bash
# Shared, read-only paginated wallet explorers. API content is untrusted text.
# shellcheck disable=SC2034
CNTOOLS_HISTORY_METADATA="ask"

cntools_history_pair() {
  cntools_table_pair "$1" "$2" "${3:-value}"
}

cntools_history_number_pair() {
  local formatted=""
  cntools_number_format_into formatted "$2" || return 1
  cntools_history_pair "$1" "${formatted}" number
}

cntools_history_date_pair() {
  local formatted=""
  cntools_timestamp_datetime_into formatted "$2" || formatted="Unavailable"
  cntools_history_pair "$1" "${formatted}"
}

cntools_history_metadata_offer() {
  local file="$1" identities="" choice=""
  local -a assets=()
  [[ "${CNTOOLS_HISTORY_METADATA}" != N ]] || return 0
  identities="$(cntools_history_asset_ids "${file}")" || return 1
  [[ -n "${identities}" ]] || return 0
  mapfile -t assets <<< "${identities}"
  if [[ "${CNTOOLS_HISTORY_METADATA}" == ask ]]; then
    cntools_ui_choose choice "Asset metadata (Koios API / one-day cache)" \
      "Use asset names and decimal amounts" "Keep raw asset identifiers and quantities" || choice="Keep raw asset identifiers and quantities"
    if [[ "${choice}" == "Use asset names and decimal amounts" ]]; then
      CNTOOLS_HISTORY_METADATA=Y
    else
      CNTOOLS_HISTORY_METADATA=N
    fi
    cntools_wallet_log CHOICE "wallet history asset metadata=${CNTOOLS_HISTORY_METADATA}"
  fi
  if [[ "${CNTOOLS_HISTORY_METADATA}" == Y ]]; then
    if ! cntools_ui_spin_function "Fetching asset metadata from Koios…" cntools_asset_details_for_ids "${assets[@]}"; then
      cntools_ui_render_status warn "Some asset metadata is unavailable; raw identities and quantities remain visible."
      cntools_ui_wait
    fi
  fi
}

cntools_history_asset_display() {
  local asset="$1" prefix="${2:-Asset}" identity="" quantity="" label="" formatted="" decimals=""
  identity="$(jq -r '.policy_id + "." + .asset_name' <<< "${asset}")" || return 1
  quantity="$(jq -r '.quantity // "" | tostring' <<< "${asset}")" || return 1
  [[ "${identity}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] || return 0
  if [[ "${CNTOOLS_HISTORY_METADATA}" == Y ]]; then
    cntools_asset_label_into label "${identity}" 1 || return 1
    cntools_history_pair "${prefix} name" "${label}" || return 1
    decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${identity}]:-}"
    if [[ "${quantity}" =~ ^[0-9]+$ && "${decimals}" =~ ^[0-9]+$ ]]; then
      cntools_wallet_format_token_amount_into formatted "${quantity}" "${decimals}" || return 1
      cntools_history_pair "${prefix} amount" "${formatted}" number || return 1
    fi
  fi
}

cntools_history_overview_rows() {
  local address="" count="" first=0 last=0
  cntools_wallet_table_row Property Value
  cntools_history_pair Wallet "${CNTOOLS_HISTORY_WALLET}" identifier
  cntools_history_pair Source "Koios API · ${CNTOOLS_NETWORK}"
  if [[ "${CNTOOLS_HISTORY_LOOKUP}" == stake ]]; then
    cntools_history_pair Lookup "Stake address"
  else
    cntools_history_pair Lookup "Payment credential"
  fi
  cntools_history_number_pair "Matching ${CNTOOLS_HISTORY_KIND}" "${CNTOOLS_HISTORY_TOTAL}"
  if (( CNTOOLS_HISTORY_TOTAL > 0 )); then
    first=$((CNTOOLS_HISTORY_PAGE * CNTOOLS_HISTORY_SIZE + 1))
    last=$((first + CNTOOLS_HISTORY_SIZE - 1))
    (( last <= CNTOOLS_HISTORY_TOTAL )) || last="${CNTOOLS_HISTORY_TOTAL}"
    cntools_history_pair Showing "${first}–${last}"
  fi
  if [[ "${CNTOOLS_HISTORY_KIND}" == utxos ]]; then
    while IFS=$'\037' read -r address count; do
      [[ -n "${address}" ]] || continue
      cntools_history_pair Address "${address}" identifier
      cntools_history_number_pair "Unspent outputs" "${count}"
    done < <(jq -r 'group_by(.address)[] | [.[0].address,(length|tostring)] | join("\u001f")' "${CNTOOLS_HISTORY_LIST}")
  fi
}

cntools_history_summary_rows() {
  local record="$1" key="" value="" asset="" ordinal=0
  cntools_wallet_table_row Property Value
  while IFS=$'\037' read -r key value; do
    case "${key}" in
      Date) cntools_history_date_pair "${key}" "${value}" ;;
      Fee|"Total outputs"|ADA)
        cntools_history_pair "${key}" "$(cntools_wallet_format_lovelace "${value}")" number ;;
      Block|Inputs|Outputs|"Native assets"|"Output assets") cntools_history_number_pair "${key}" "${value}" ;;
      *) cntools_history_pair "${key}" "${value}" identifier ;;
    esac || return 1
  done < <(jq -r --arg kind "${CNTOOLS_HISTORY_KIND}" '
    (if $kind == "transactions" then
      [["Transaction ID",.tx_hash],["Date",.tx_timestamp],["Block",.block_height],
       ["Fee",.fee],["Total outputs",.total_output],["Inputs",(.inputs|length)],
       ["Outputs",(.outputs|length)],
       ["Output assets",([.outputs[]?.asset_list[]? | [.policy_id,.asset_name]]|unique|length)]]
     else
      [["UTxO",(.tx_hash+"#"+(.tx_index|tostring))],
       ["ADA",.value],["Native assets",((.asset_list // [])|length)],
       ["Date",.block_time],["Block",.block_height]] +
      (if .datum_hash != null or .inline_datum != null then [["Datum","Present"]] else [] end) +
      (if .reference_script != null then [["Reference script","Present"]] else [] end)
     end)[] | map(tostring | gsub("[\u0000-\u001f\u007f]";" ")) | join("\u001f")
  ' <<< "${record}")
  if [[ "${CNTOOLS_HISTORY_KIND}" == utxos ]]; then
    while IFS= read -r asset; do
      ordinal=$((ordinal + 1))
      cntools_history_asset_display "${asset}" "Asset ${ordinal}" || return 1
      cntools_history_pair "Asset ${ordinal} ID" "$(jq -r '.policy_id + "." + .asset_name' <<< "${asset}")" identifier
      value="$(jq -r '.quantity | tostring' <<< "${asset}")"
      cntools_history_number_pair "Raw quantity" "${value}" || return 1
    done < <(jq -c '.asset_list[:3][]?' <<< "${record}")
    value="$(jq '(.asset_list // []) | length' <<< "${record}")"
    if (( value > 3 )); then
      cntools_history_pair "Other assets" "$((value - 3)) · Show details for the full list" muted
    fi
  fi
}

# Input/output records are already isolated, so paths never repeat the I/O
# ordinal or payment address. Optional nulls and empty structures stay hidden.
cntools_history_tree_rows() {
  local file="$1" section="$2" path="" type="" value="" role="value" formatted=""
  local decimals="${3:-}"
  cntools_wallet_table_row Field Value
  while IFS=$'\037' read -r path type value; do
    role=value
    if [[ "${type}" == asset ]]; then
      cntools_history_asset_display "${value}" "${path}" || return 1
      continue
    fi
    if [[ "${section}" =~ ^(Overview|Record)$ && "${path}" =~ ^(tx_timestamp|block_time)$ ]]; then
      cntools_timestamp_datetime_into formatted "${value}" && value="${formatted}"
    elif [[ "${section}" == Overview && "${path}" =~ ^(invalid_before|invalid_after)$ && "${type}" != null ]]; then
      cntools_slot_datetime_into formatted "${value}" && value="${formatted}"
    elif [[ "${type}" == string && "${value}" =~ ^-?[0-9]+$ ]] &&
         { [[ "${section}" == Overview &&
              "${path}" =~ ^(value|fee|deposit|treasury_donation|total_output)$ ]] ||
           [[ "${section}" =~ ^(Record|inputs|outputs|collateral_inputs|collateral_output|reference_inputs)$ &&
              "${path}" =~ ^(\[[0-9]+\]\ /\ )?value$ ]]; }; then
      if [[ "${value}" == -* ]]; then
        value="-$(cntools_wallet_format_lovelace "${value#-}")"
      else
        value="$(cntools_wallet_format_lovelace "${value}")"
      fi
      role=number
    elif [[ "${type}" == number || ( "${section}" != metadata &&
            "${path}" == *quantity && "${value}" =~ ^-?[0-9]+$ ) ]]; then
      cntools_number_format_into formatted "${value}" && value="${formatted}"
      role=number
    elif [[ "${path}" =~ (hash|fingerprint|address|bech32|cred|policy_id|asset_name)$ ]]; then
      role=identifier
    fi
    if [[ "${section}" == Asset ]]; then
      case "${path}" in
        quantity) path="Raw quantity" ;;
        policy_id) path="Policy ID" ;;
        asset_name) path="Asset name (hex)" ;;
        fingerprint) path=Fingerprint ;;
        decimals) path=Decimals ;;
      esac
    fi
    cntools_history_pair "${path}" "${value}" "${role}" || return 1
  done < <(jq -r --arg section "${section}" --arg decimals "${decimals}" '
    def clean: tostring | gsub("[\u0000-\u001f\u007f]";" ");
    def leaves($path):
      if . == null or . == [] or . == {} then empty
      elif type == "object" and length > 0 then
        (if $section != "Asset" and (.policy_id? | type == "string") and (.asset_name? | type == "string")
          then [$path,"asset",tojson] else empty end),
        (to_entries[] | .key as $key | .value | leaves(if $path == "" then $key else $path + " / " + $key end))
      elif type == "array" and length > 0 then
        to_entries[] | .key as $key | .value | leaves($path + "[" + (($key+1)|tostring) + "]")
      else [$path,type,(if type == "string" then (if . == "" then "(empty string)" else . end) else tojson end)] end;
    (if $section == "Overview" then with_entries(select(.value | type != "array" and type != "object"))
     elif $section == "Record" then del(.payment_addr,.payment_cred,.address,.asset_list)
     elif $section == "Asset" then
       if $decimals != "" then .decimals=($decimals|tonumber) else . end
     else .[$section] end) |
    leaves("") | map(clean) | join("\u001f")
  ' "${file}")
}

cntools_history_asset_title_into() {
  # Declining enrichment still permits a locally decoded name, but never uses
  # cached metadata from another view or triggers an API request.
  if [[ "${CNTOOLS_HISTORY_METADATA}" != Y ]]; then
    local -A CNTOOLS_WALLET_ASSET_TICKERS=() CNTOOLS_WALLET_ASSET_CLASSES=()
    local -A CNTOOLS_WALLET_ASSET_METADATA_NAMES=() CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
  fi
  cntools_asset_label_into "$1" "$2" "$3"
}

cntools_history_asset_rows() {
  local asset="$1" identity="$2" decimals="" quantity="" formatted=""
  if [[ "${CNTOOLS_HISTORY_METADATA}" == Y ]]; then
    decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${identity}]:-}"
    quantity="$(jq -r '.quantity | tostring' <<< "${asset}")" || return 1
    if [[ "${quantity}" =~ ^[0-9]+$ && "${decimals}" =~ ^[0-9]+$ ]]; then
      cntools_wallet_format_token_amount_into formatted "${quantity}" "${decimals}" || return 1
      cntools_history_pair Amount "${formatted}" number || return 1
    else
      decimals=""
    fi
  fi
  cntools_history_tree_rows <(printf '%s\n' "${asset}") Asset "${decimals}"
}

cntools_history_assets_render() {
  local record="$1" asset="" identity="" title="" rendered="" line="" index=0
  local CNTOOLS_TABLE_MARGIN=$(( ${CNTOOLS_TABLE_MARGIN:-0} + 2 ))
  local CNTOOLS_TABLE_TITLE_ROLE=accent
  while IFS= read -r asset; do
    index=$((index + 1))
    identity="$(jq -r '.policy_id + "." + .asset_name' <<< "${asset}")" || return 1
    cntools_history_asset_title_into title "${identity}" "${index}" || return 1
    rendered="$(cntools_history_asset_rows "${asset}" "${identity}" |
      cntools_table_render "${title}")" || return 1
    while IFS= read -r line; do
      printf '  %s\n' "${line}"
    done <<< "${rendered}"
    printf '\n'
  done < <(jq -c '.asset_list | if type == "array" then .[] else empty end' <<< "${record}")
}

cntools_history_record_render() {
  local record="$1" title="$2"
  cntools_history_tree_rows <(printf '%s\n' "${record}") Record | cntools_table_render "${title}" || return 1
  cntools_history_assets_render "${record}"
}

cntools_history_record_title() {
  local record="$1" number="$2" address="" formatted=""
  address="$(jq -r '((try .payment_addr.bech32 catch null) // .address) |
    if type == "string" and length > 0 then . else "Address unavailable" end' <<< "${record}")" || return 1
  cntools_wallet_sanitize_display_into address "${address}" || return 1
  cntools_number_format_into formatted "${number}" || return 1
  printf '%s · %s\n' "${formatted}" "${address}"
}

cntools_history_io_render() {
  local file="$1" section="$2" title="$3" record="" heading="" index=0
  local CNTOOLS_TABLE_TITLE_ROLE=identifier
  cntools_table_heading "━━ ${title} ━━" accent || return 1
  while IFS= read -r record; do
    index=$((index + 1))
    heading="$(cntools_history_record_title "${record}" "${index}")" || return 1
    cntools_history_record_render "${record}" "${heading}" || return 1
  done < <(jq -c --arg section "${section}" '.[$section] | if type == "array" then .[] else . end' "${file}")
}

cntools_history_metadata_render() {
  local file="$1" entry="" label="" type="" line="" number=0 extra=""
  if ! jq -e '.metadata | type == "object"' "${file}" >/dev/null; then
    cntools_table_heading "Metadata" || return 1
    while IFS= read -r line; do cntools_table_heading "${line}" value || return 1; done < <(jq '.metadata' "${file}")
    printf '\n'
    return 0
  fi
  while IFS= read -r entry; do
    label="$(jq -r '.key' <<< "${entry}")" || return 1
    type="Custom metadata"
    case "${label}" in
      674)
        if jq -e '.value | type == "object" and .enc == "basic"' <<< "${entry}" >/dev/null; then
          type="CIP-83 encrypted message"
        elif jq -e '.value | type == "object" and (has("enc")|not) and
            (.msg | type == "array" and length > 0 and all(type == "string"))' <<< "${entry}" >/dev/null; then
          type="CIP-20 message"
        fi ;;
      721) type="CIP-25 asset metadata" ;;
      20) type="Fungible token metadata" ;;
    esac
    cntools_table_heading "${label} · ${type}" accent || return 1
    if [[ "${type}" == "CIP-20 message" ]]; then
      number=0
      while IFS= read -r line; do
        number=$((number + 1))
        # Each msg array item stays one numbered message line; controls are
        # replaced, never interpreted as terminal escape sequences.
        cntools_table_heading "${number} · ${line}" value || return 1
      done < <(jq -r '.value.msg[] | gsub("[\u0000-\u001f\u007f]";" ")' <<< "${entry}")
      extra="$(jq '.value | del(.msg) | select(length > 0)' <<< "${entry}")" || return 1
      if [[ -n "${extra}" ]]; then
        while IFS= read -r line; do cntools_table_heading "${line}" value || return 1; done <<< "${extra}"
      fi
    else
      while IFS= read -r line; do cntools_table_heading "${line}" value || return 1; done < <(jq '.value' <<< "${entry}")
    fi
    printf '\n'
  done < <(jq -c '.metadata | to_entries[]' "${file}")
}

cntools_history_detail_render() {
  local file="$1" section="" title="" encoded="" record=""
  if jq -e 'has("is_spent") and has("address")' "${file}" >/dev/null; then
    record="$(jq -c . "${file}")" || return 1
    title="$(cntools_history_record_title "${record}" "${CNTOOLS_HISTORY_DETAIL_NUMBER:-1}")" || return 1
    cntools_table_heading '━━ Unspent output ━━' accent || return 1
    local CNTOOLS_TABLE_TITLE_ROLE=identifier
    cntools_history_record_render "${record}" "${title}"
    return $?
  fi
  cntools_history_tree_rows "${file}" Overview | cntools_table_render "Overview · Koios API" || return 1
  # Put ordinary inputs/outputs first; optional sections retain source order.
  while IFS= read -r encoded; do
    section="$(jq -r . <<< "${encoded}")" || return 1
    case "${section}" in
      inputs) cntools_history_io_render "${file}" "${section}" Inputs ;;
      outputs) cntools_history_io_render "${file}" "${section}" Outputs ;;
      collateral_inputs) cntools_history_io_render "${file}" "${section}" 'Collateral inputs' ;;
      collateral_output) cntools_history_io_render "${file}" "${section}" 'Collateral output' ;;
      reference_inputs) cntools_history_io_render "${file}" "${section}" 'Reference inputs' ;;
      metadata) cntools_history_metadata_render "${file}" ;;
      *)
        cntools_wallet_sanitize_display_into title "${section//_/ }" || return 1
        cntools_history_tree_rows "${file}" "${section}" | cntools_table_render "${title}"
        ;;
    esac || return 1
  done < <(jq -c '
    . as $tx |
    (["inputs","outputs"] + [keys_unsorted[] | select(. != "inputs" and . != "outputs")])[] as $key |
    select($tx[$key] | (type == "array" or type == "object") and length > 0) | $key
  ' "${file}")
}

cntools_history_detail_view() {
  local selection="" display="" prompt="Item number"
  local CNTOOLS_HISTORY_METADATA="${CNTOOLS_HISTORY_METADATA}"
  local CNTOOLS_TABLE_MARGIN=4 # Space for Gum pager borders/padding.
  [[ "${CNTOOLS_HISTORY_KIND}" != transactions ]] || prompt="Transaction number or transaction ID"
  cntools_ui_input selection "${prompt}" "Number from the full list" || return 0
  if ! cntools_ui_spin_function "Fetching details from Koios…" cntools_history_detail_load "${selection}"; then
    cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR}"
    cntools_ui_wait
    return 0
  fi
  # A user who kept page summaries raw can still enrich a particular detail view.
  cntools_wallet_log CHOICE "wallet history detail=${selection//[[:space:]]/}"
  [[ "${CNTOOLS_HISTORY_METADATA}" != N ]] || CNTOOLS_HISTORY_METADATA=ask
  cntools_history_metadata_offer "${CNTOOLS_HISTORY_DETAIL}" || return 1
  cntools_wallet_query_temp_file display || return 1
  cntools_history_detail_render "${CNTOOLS_HISTORY_DETAIL}" > "${display}" || return 1
  cntools_ui_page_file "${display}"
}

cntools_history_action() {
  local kind="$1" title="Transaction List" selected="" directory="" type="" credential=""
  local size="" choice="" record="" number=0 target=0 stake="" lookup=payment summary_title=""
  local -a choices=()
  [[ "${kind}" != utxos ]] || title="UTxO List"
  cntools_ui_action_begin "${title}" "/ Wallet / ${title}"
  cntools_history_available || {
    cntools_ui_render_status warn "Koios is unavailable. These views require an online Koios connection."
    cntools_ui_wait
    return 0
  }
  cntools_wallet_query_reset
  CNTOOLS_HISTORY_METADATA=ask
  cntools_wallet_catalog_build || return 1
  if (( ${#CNTOOLS_WALLET_NAMES[@]} == 0 )); then
    cntools_ui_render_status warn "No wallets are available."
    cntools_ui_wait
    return 0
  fi
  cntools_wallet_choose selected || return 0
  directory="${CNTOOLS_WALLET_PATHS[selected]}"
  CNTOOLS_HISTORY_WALLET="${CNTOOLS_WALLET_NAMES[selected]}"
  cntools_wallet_prepare_selected_material "${directory}" || true
  type="$(cntools_wallet_type "${directory}")" || return 1
  if [[ "${type}" == MultiSig ]]; then type=script-payment; else type=payment; fi
  cntools_wallet_id_read_credential "${directory}" "${type}" credential || credential=""
  cntools_wallet_read_address "${directory}" reward stake || stake=""
  CNTOOLS_HISTORY_PAYMENT="${credential,,}" CNTOOLS_HISTORY_STAKE="${stake}"
  if [[ -n "${credential}" && -n "${stake}" ]]; then
    cntools_ui_choose choice "Look up by" \
      "Payment credential · matching base and payment-only addresses" \
      "Stake address · all linked addresses (no payment-only addresses)" || return 0
    case "${choice}" in
      "Payment credential · matching base and payment-only addresses") ;;
      "Stake address · all linked addresses (no payment-only addresses)") lookup=stake ;;
      *) return 0 ;;
    esac
  elif [[ -n "${stake}" ]]; then
    lookup=stake
  elif [[ -z "${credential}" ]]; then
    cntools_ui_render_status warn "No valid payment credential or stake address is available for this wallet."
    cntools_ui_wait
    return 0
  fi
  [[ "${lookup}" != stake ]] || credential="${stake}"
  while :; do
    cntools_ui_input size "Items per page (1–10; Enter uses 5)" "5 (default)" || return 0
    cntools_history_page_size "${size}" && break
    cntools_ui_render_status warn "Choose a whole number from 1 to 10."
  done
  cntools_wallet_log CHOICE "wallet history kind=${kind} wallet=${CNTOOLS_HISTORY_WALLET} lookup=${lookup} page_size=${CNTOOLS_HISTORY_SIZE}"
  if ! cntools_ui_spin_function "Fetching wallet inventory from Koios…" cntools_history_load "${kind}" "${credential}" "${lookup}"; then
    cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR}"
    cntools_ui_wait
    return 1
  fi
  while :; do
    if ! cntools_ui_spin_function "Loading page from Koios…" cntools_history_page_load "${target}"; then
      cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR}"
      cntools_ui_choose choice "Page unavailable" Retry Back || return 0
      [[ "${choice}" == Retry ]] && continue
      return 0
    fi
    if [[ "${kind}" == utxos ]]; then
      cntools_history_metadata_offer "${CNTOOLS_HISTORY_PAGE_FILE}" || return 1
    fi
    cntools_ui_action_begin "${title}" "/ Wallet / ${title}"
    cntools_history_overview_rows | cntools_table_render "${title}" || return 1
    if (( CNTOOLS_HISTORY_TOTAL == 1000 )); then
      cntools_ui_render_status warn "Koios returns at most 1,000 matches; only the last 1,000 matching ${kind} can be displayed."
    fi
    number=$((CNTOOLS_HISTORY_PAGE * CNTOOLS_HISTORY_SIZE))
    while IFS= read -r record; do
      number=$((number + 1))
      if [[ "${kind}" == transactions ]]; then
        summary_title="${number} · $(cntools_history_transaction_tags "${record}")" || return 1
      else
        summary_title="$(cntools_history_record_title "${record}" "${number}")" || return 1
      fi
      cntools_history_summary_rows "${record}" | cntools_table_render "${summary_title}" || return 1
    done < <(jq -c '.[]' "${CNTOOLS_HISTORY_PAGE_FILE}")
    choices=()
    (( (CNTOOLS_HISTORY_PAGE + 1) * CNTOOLS_HISTORY_SIZE >= CNTOOLS_HISTORY_TOTAL )) || choices+=("Next page")
    (( CNTOOLS_HISTORY_PAGE == 0 )) || choices+=("Previous page")
    if [[ "${kind}" == transactions ]] || (( CNTOOLS_HISTORY_TOTAL > 0 )); then choices+=("Show details"); fi
    choices+=("Back")
    cntools_ui_choose choice "${title}" "${choices[@]}" || return 0
    cntools_wallet_log CHOICE "wallet history page=$((CNTOOLS_HISTORY_PAGE + 1)) choice=${choice}"
    case "${choice}" in
      "Next page") target=$((CNTOOLS_HISTORY_PAGE + 1)) ;;
      "Previous page") target=$((CNTOOLS_HISTORY_PAGE - 1)) ;;
      "Show details") cntools_history_detail_view || return 1 ;;
      *) return 0 ;;
    esac
  done
}
