#!/usr/bin/env bash
# Shared, read-only paginated wallet explorers. API content is untrusted text.
# shellcheck disable=SC2034
CNTOOLS_HISTORY_METADATA="ask"

cntools_history_number_pair() {
  local formatted=""
  cntools_number_format_into formatted "$2" || return 1
  cntools_detail_pair "$1" "${formatted}" number
}

cntools_history_date_pair() {
  local formatted=""
  cntools_timestamp_datetime_into formatted "$2" || formatted="Unavailable"
  cntools_detail_pair "$1" "${formatted}"
}

cntools_history_metadata_offer() {
  local file="$1" identities="" choice=""
  local -a assets=()
  [[ "${CNTOOLS_HISTORY_METADATA}" != N ]] || return 0
  cntools_history_available || { CNTOOLS_HISTORY_METADATA=N; return 0; }
  identities="$(cntools_history_asset_ids "${file}")" || return 1
  [[ -n "${identities}" ]] || return 0
  mapfile -t assets <<< "${identities}"
  if [[ "${CNTOOLS_HISTORY_METADATA}" == ask ]]; then
    if cntools_flow_quick; then
      choice="Use asset names and decimal amounts"
    else
      cntools_ui_choose choice "Asset metadata (Koios API / one-day cache)" \
        "Use asset names and decimal amounts" "Keep raw asset identifiers and quantities" || choice="Keep raw asset identifiers and quantities"
    fi
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

cntools_history_overview_rows() {
  local address="" count="" first=0 last=0
  cntools_table_row Property Value
  cntools_detail_pair Wallet "${CNTOOLS_HISTORY_WALLET}" identifier
  if [[ "${CNTOOLS_HISTORY_BACKEND}" == local ]]; then
    cntools_detail_pair Source 'Local node'
    cntools_detail_pair Lookup 'Saved wallet addresses only'
  elif [[ "${CNTOOLS_HISTORY_LOOKUP}" == stake ]]; then
    cntools_detail_pair Source 'Koios API'
    cntools_detail_pair Lookup "Stake address"
  else
    cntools_detail_pair Source 'Koios API'
    cntools_detail_pair Lookup "Payment credential"
  fi
  cntools_history_number_pair "Matching ${CNTOOLS_HISTORY_KIND}" "${CNTOOLS_HISTORY_TOTAL}"
  if (( CNTOOLS_HISTORY_TOTAL > 0 )); then
    first=$((CNTOOLS_HISTORY_PAGE * CNTOOLS_HISTORY_SIZE + 1))
    last=$((first + CNTOOLS_HISTORY_SIZE - 1))
    (( last <= CNTOOLS_HISTORY_TOTAL )) || last="${CNTOOLS_HISTORY_TOTAL}"
    cntools_detail_pair Showing "${first}–${last}"
  fi
  if [[ "${CNTOOLS_HISTORY_KIND}" == utxos ]]; then
    while IFS=$'\037' read -r address count; do
      [[ -n "${address}" ]] || continue
      cntools_detail_pair Address "${address}" identifier
      cntools_history_number_pair "Unspent outputs" "${count}"
    done < <(jq -r 'group_by(.address)[] | [.[0].address,(length|tostring)] | join("\u001f")' "${CNTOOLS_HISTORY_LIST}")
  fi
}

cntools_history_summary_rows() {
  local record="$1" key="" value="" identity="" name="" names="" ordinal=0
  cntools_table_row Property Value
  while IFS=$'\037' read -r key value; do
    case "${key}" in
      Date) cntools_history_date_pair "${key}" "${value}" ;;
      Fee|"Total outputs"|ADA)
        cntools_detail_pair "${key}" "$(cntools_number_format_lovelace "${value}")" number ;;
      Block|Inputs|Outputs|"Native assets"|"Output assets") cntools_history_number_pair "${key}" "${value}" ;;
      *) cntools_detail_pair "${key}" "${value}" identifier ;;
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
     end)[] | select(.[1] != null) | map(tostring | gsub("[\u0000-\u001f\u007f]";" ")) | join("\u001f")
  ' <<< "${record}")
  if [[ "${CNTOOLS_HISTORY_KIND}" == utxos ]]; then
    while IFS= read -r identity; do
      ordinal=$((ordinal + 1))
      cntools_detail_asset_title_into name "${identity}" "${ordinal}" || return 1
      [[ -z "${names}" ]] || names+=", "
      names+="${name}"
    done < <(jq -r '.asset_list[]? | .policy_id + "." + .asset_name' <<< "${record}")
    [[ -z "${names}" ]] || cntools_detail_pair "Asset names" "${names}"
  fi
}


cntools_history_detail_view() {
  local selection="" display="" prompt="Item number"
  local CNTOOLS_HISTORY_METADATA="${CNTOOLS_HISTORY_METADATA}"
  local CNTOOLS_TABLE_MARGIN=4 # Space for Gum pager borders/padding.
  [[ "${CNTOOLS_HISTORY_KIND}" != transactions ]] || prompt="Transaction number or transaction ID"
  cntools_ui_input selection "${prompt}" "Number from the full list" || return 0
  if ! cntools_ui_spin_function "Loading item details…" cntools_history_detail_load "${selection}"; then
    cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR}"
    cntools_ui_wait
    return 0
  fi
  # A user who kept page summaries raw can still enrich a particular detail view.
  cntools_wallet_log CHOICE "wallet history detail=${selection//[[:space:]]/}"
  [[ "${CNTOOLS_HISTORY_METADATA}" != N ]] || CNTOOLS_HISTORY_METADATA=ask
  cntools_history_metadata_offer "${CNTOOLS_HISTORY_DETAIL}" || return 1
  cntools_wallet_query_temp_file display || return 1
  cntools_detail_transaction_render "${CNTOOLS_HISTORY_DETAIL}" 'Overview · Koios API' > "${display}" || return 1
  cntools_ui_page_file "${display}"
}

cntools_history_action() {
  local kind="$1" title="Transaction List" selected="" directory="" type="" credential=""
  local size="" choice="" record="" number=0 target=0 stake="" lookup=payment summary_title=""
  local -a choices=()
  [[ "${kind}" != utxos ]] || title="UTxO List"
  cntools_ui_action_begin "${title}" "/ Wallet / ${title}"
  if ! cntools_history_available && ! { [[ "${kind}" == utxos ]] && cntools_history_local_available; }; then
    cntools_ui_render_status warn "Koios is unavailable. These views require an online Koios connection."
    cntools_ui_wait
    return 0
  fi
  if [[ "${kind}" == utxos ]]; then
    cntools_ui_render_status info "Only unspent outputs are shown in the UTxO list."
  fi
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
  if [[ "${kind}" == utxos ]] && ! cntools_history_available; then
    lookup=addresses
  elif [[ -n "${credential}" && -n "${stake}" ]]; then
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
  if ! cntools_history_available || ! cntools_ui_spin_function "Fetching wallet inventory from Koios…" cntools_history_load "${kind}" "${credential}" "${lookup}"; then
    if [[ "${kind}" != utxos ]] || ! cntools_history_local_available; then
      cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR:-Koios is unavailable.}"
      cntools_ui_wait; return 1
    fi
    cntools_ui_render_status info 'Koios is unavailable. Using the local node for saved wallet addresses only; linked addresses and block dates cannot be discovered.'
    cntools_ui_spin_function 'Fetching unspent outputs from the local node…' cntools_history_load_local "${directory}" || {
      cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR}"; cntools_ui_wait; return 1;
    }
  fi
  while :; do
    if ! cntools_ui_spin_function "Loading wallet inventory page…" cntools_history_page_load "${target}"; then
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
    if [[ "${CNTOOLS_HISTORY_BACKEND}" == koios ]] && (( CNTOOLS_HISTORY_TOTAL == 1000 )); then
      cntools_ui_render_status warn "Koios returns at most 1,000 matches; only the last 1,000 matching ${kind} can be displayed."
    fi
    number=$((CNTOOLS_HISTORY_PAGE * CNTOOLS_HISTORY_SIZE))
    while IFS= read -r record; do
      number=$((number + 1))
      if [[ "${kind}" == transactions ]]; then
        summary_title="${number} · $(cntools_history_transaction_tags "${record}")" || return 1
      else
        summary_title="$(cntools_detail_utxo_title "${record}" "${number}")" || return 1
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
