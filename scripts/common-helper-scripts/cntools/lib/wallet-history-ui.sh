#!/usr/bin/env bash
# Shared, read-only paginated wallet explorers. API content is untrusted text.
# shellcheck disable=SC2034
CNTOOLS_HISTORY_METADATA="ask"
# Y once Show details asked about asset metadata in this action.
CNTOOLS_HISTORY_DETAIL_ASKED="N"

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
  local file="$1" identities="" choice="" status=0
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
      status=0
      cntools_ui_choose choice "Asset metadata (Koios API / one-day cache)" \
        "Use asset names and decimal amounts" "Keep raw asset identifiers and quantities" || status=$?
      # Ctrl+C cancels; Esc keeps the raw identifiers.
      (( status != 130 )) || return 130
      (( status == 0 )) || choice="Keep raw asset identifiers and quantities"
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
  local address="" count="" first=0 last=0 addresses=0 kind_label="transactions"
  [[ "${CNTOOLS_HISTORY_KIND}" != utxos ]] || kind_label="UTxOs"
  cntools_table_row Property Value
  cntools_detail_pair Wallet "${CNTOOLS_HISTORY_WALLET}" identifier
  if [[ "${CNTOOLS_HISTORY_BACKEND}" == local ]]; then
    cntools_detail_pair Source 'Local node'
    cntools_detail_pair Lookup 'Saved wallet addresses only'
    cntools_detail_pair Limits 'Koios unavailable · no linked addresses or block dates'
  elif [[ "${CNTOOLS_HISTORY_LOOKUP}" == stake ]]; then
    cntools_detail_pair Source 'Koios API'
    cntools_detail_pair Lookup "Stake address"
  else
    cntools_detail_pair Source 'Koios API'
    cntools_detail_pair Lookup "Payment credential"
  fi
  cntools_history_number_pair "Matching ${kind_label}" "${CNTOOLS_HISTORY_TOTAL}"
  if (( CNTOOLS_HISTORY_TOTAL > 0 )); then
    first=$((CNTOOLS_HISTORY_PAGE * CNTOOLS_HISTORY_SIZE + 1))
    last=$((first + CNTOOLS_HISTORY_SIZE - 1))
    (( last <= CNTOOLS_HISTORY_TOTAL )) || last="${CNTOOLS_HISTORY_TOTAL}"
    cntools_detail_pair Showing "${first}–${last}"
  fi
  if [[ "${CNTOOLS_HISTORY_KIND}" == utxos ]]; then
    cntools_history_utxo_address_count_into addresses
    while IFS=$'\037' read -r address count; do
      [[ -n "${address}" ]] || continue
      cntools_detail_pair Address "${address}" identifier
      # One address holds them all: its count is the total above.
      (( addresses < 2 )) || cntools_history_number_pair "Unspent outputs" "${count}"
    done < <(jq -r 'group_by(.address)[] | [.[0].address,(length|tostring)] | join("\u001f")' "${CNTOOLS_HISTORY_LIST}")
  fi
}

cntools_history_utxo_address_count_into() {
  local _cntools_address_count=0
  _cntools_address_count="$(jq '[.[].address] | unique | length' "${CNTOOLS_HISTORY_LIST}" 2>/dev/null)" ||
    _cntools_address_count=0
  printf -v "$1" '%s' "${_cntools_address_count:-0}"
}

cntools_history_summary_rows() {
  local record="$1" key="" value="" identity="" name="" names="" ordinal=0 net=""
  cntools_table_row Property Value
  while IFS=$'\037' read -r key value; do
    case "${key}" in
      Date) cntools_history_date_pair "${key}" "${value}" ;;
      Fee|ADA)
        cntools_detail_pair "${key}" "$(cntools_number_format_lovelace "${value}")" number ;;
      "Wallet net change")
        cntools_history_net_change_into net "${record}" || return 1
        cntools_detail_pair "${key}" "${net:0:1}$(cntools_number_format_lovelace "${net:1}")" number ;;
      Block|Inputs|Outputs|"Native assets"|"Output assets") cntools_history_number_pair "${key}" "${value}" ;;
      *) cntools_detail_pair "${key}" "${value}" identifier ;;
    esac || return 1
  done < <(jq -r --arg kind "${CNTOOLS_HISTORY_KIND}" '
    (if $kind == "transactions" then
      [["Transaction ID",.tx_hash],["Date",.tx_timestamp],["Block",.block_height],
       ["Fee",.fee],["Wallet net change",""],["Inputs",(.inputs|length)],
       ["Outputs",(.outputs|length)],
       ["Output assets",([.outputs[]?.asset_list[]? | [.policy_id,.asset_name]]|unique|length)]]
     else
      [["UTxO",(.tx_hash+"#"+(.tx_index|tostring))],
       ["ADA",.value],["Native assets",((.asset_list // [])|length)],
       ["Date",.block_time],["Block",.block_height]] +
      (if .datum_hash != null or .inline_datum != null then [["Datum","Present"]] else [] end) +
      (if .reference_script != null then [["Reference script","Present"]] else [] end)
     end)[] | select(.[1] != null) |
    select((.[0] == "Output assets" or .[0] == "Native assets") and .[1] == 0 | not) | map(tostring | gsub("[\u0000-\u001f\u007f]";" ")) | join("\u001f")
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


# Returns 0 back to the page, 130 on Ctrl+C, other statuses on errors.
cntools_history_detail_view() {
  local selection="" display="" prompt="Item number" status=0
  local CNTOOLS_TABLE_MARGIN=4 # Space for Gum pager borders/padding.
  [[ "${CNTOOLS_HISTORY_KIND}" != transactions ]] || prompt="Transaction number or transaction ID"
  cntools_ui_input selection "${prompt}" "Number from the full list" || status=$?
  (( status != 130 )) || return 130
  (( status == 0 )) || return 0
  if ! cntools_ui_spin_function "Loading item details…" cntools_history_detail_load "${selection}"; then
    cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR}"
    cntools_ui_wait
    return 0
  fi
  cntools_wallet_log CHOICE "wallet history detail=${selection//[[:space:]]/}"
  # A user who kept page summaries raw is asked once more, for details only;
  # the answer is kept for the rest of this action.
  if [[ "${CNTOOLS_HISTORY_METADATA}" == N && "${CNTOOLS_HISTORY_DETAIL_ASKED}" != Y ]]; then
    CNTOOLS_HISTORY_METADATA=ask
  fi
  [[ "${CNTOOLS_HISTORY_METADATA}" != ask ]] || CNTOOLS_HISTORY_DETAIL_ASKED=Y
  status=0
  cntools_history_metadata_offer "${CNTOOLS_HISTORY_DETAIL}" || status=$?
  (( status == 0 )) || return "${status}"
  cntools_wallet_query_temp_file display || return 1
  cntools_detail_transaction_render "${CNTOOLS_HISTORY_DETAIL}" 'Overview · Koios API' > "${display}" || return 1
  cntools_ui_page_file "${display}"
}

# Returns 1 on Esc (keep the size) and 130 on Ctrl+C.
cntools_history_prompt_page_size() {
  local size="" status=0
  while :; do
    status=0
    cntools_ui_input size "Items per page (1–10; Enter keeps ${CNTOOLS_HISTORY_SIZE})" "${CNTOOLS_HISTORY_SIZE}" || status=$?
    (( status != 130 )) || return 130
    (( status == 0 )) || return 1
    [[ -n "${size//[[:space:]]/}" ]] || size="${CNTOOLS_HISTORY_SIZE}"
    cntools_history_page_size "${size}" && return 0
    cntools_ui_render_status warn "Choose a whole number from 1 to 10."
  done
}

cntools_history_action() {
  local kind="$1" title="Transaction List" selected="" directory="" type="" credential=""
  local choice="" record="" number=0 target=0 stake="" lookup=payment summary_title=""
  local payment_credential="" status=0 shown="" addresses=0
  local -a choices=()
  [[ "${kind}" != utxos ]] || title="UTxO List"
  cntools_ui_action_begin "${title}" "/ Wallet / ${title}"
  if ! cntools_history_available && ! { [[ "${kind}" == utxos ]] && cntools_history_local_available; }; then
    cntools_ui_render_status warn "Koios is unavailable. These views require an online Koios connection."
    cntools_ui_wait
    return 0
  fi
  cntools_wallet_query_reset
  CNTOOLS_HISTORY_METADATA=ask
  CNTOOLS_HISTORY_DETAIL_ASKED=N
  if ! cntools_wallet_catalog_build; then
    cntools_ui_render_status error "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  status=0
  cntools_wallet_choose selected || status=$?
  # 3: no wallets, already shown and acknowledged.
  (( status != 1 && status != 3 && status != 130 )) || return 0
  (( status == 0 )) || return "${status}"
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
  elif [[ -n "${credential}" && -n "${stake}" ]] && cntools_flow_quick; then
    # The page menu offers 'Change lookup'.
    cntools_wallet_log CHOICE "wallet history lookup default=payment flow=quick"
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
  payment_credential="${credential}"
  [[ "${lookup}" != stake ]] || credential="${stake}"
  # Five items per page in both styles; the page menu offers 'Page size'.
  cntools_history_page_size 5 || return 1
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
      # Back returns to the last page shown, if any, rather than ending.
      status=0
      cntools_ui_choose choice "Page unavailable" Retry Back || status=$?
      (( status != 130 )) || return 130
      (( status == 0 )) || choice=Back
      [[ "${choice}" == Retry ]] && continue
      [[ "${shown}" =~ ^[0-9]+$ && "${shown}" != "${target}" ]] || return 0
      target="${shown}"
      continue
    fi
    shown="${target}"
    if [[ "${kind}" == utxos ]]; then
      status=0
      cntools_history_metadata_offer "${CNTOOLS_HISTORY_PAGE_FILE}" || status=$?
      (( status != 130 )) || return 130
      (( status == 0 )) || return 2
    fi
    cntools_ui_action_begin "${title}" "/ Wallet / ${title}"
    cntools_history_overview_rows | cntools_table_render "${title}" || return 2
    if [[ "${CNTOOLS_HISTORY_BACKEND}" == koios ]] && (( CNTOOLS_HISTORY_TOTAL == 1000 )); then
      cntools_ui_render_status warn "Koios returns at most 1,000 matches; only the last 1,000 matching $([[ "${kind}" == utxos ]] && printf UTxOs || printf transactions) can be displayed."
    fi
    number=$((CNTOOLS_HISTORY_PAGE * CNTOOLS_HISTORY_SIZE))
    [[ "${kind}" != utxos ]] || cntools_history_utxo_address_count_into addresses
    while IFS= read -r record; do
      number=$((number + 1))
      if [[ "${kind}" == transactions ]]; then
        summary_title="${number} · $(cntools_history_transaction_tags "${record}")" || return 1
      elif (( addresses > 1 )); then
        summary_title="$(cntools_detail_utxo_title "${record}" "${number}")" || return 1
      else
        # The overview names the only address; the UTxO row identifies it.
        cntools_number_format_into summary_title "${number}" || return 1
      fi
      cntools_history_summary_rows "${record}" | cntools_table_render "${summary_title}" || return 1
    done < <(jq -c '.[]' "${CNTOOLS_HISTORY_PAGE_FILE}")
    choices=()
    (( (CNTOOLS_HISTORY_PAGE + 1) * CNTOOLS_HISTORY_SIZE >= CNTOOLS_HISTORY_TOTAL )) || choices+=("Next page")
    (( CNTOOLS_HISTORY_PAGE == 0 )) || choices+=("Previous page")
    if [[ "${kind}" == transactions ]] || (( CNTOOLS_HISTORY_TOTAL > 0 )); then choices+=("Show details"); fi
    choices+=("Page size")
    if [[ -n "${payment_credential}" && -n "${stake}" && "${CNTOOLS_HISTORY_BACKEND}" == koios ]]; then
      choices+=("Change lookup")
    fi
    choices+=("Back")
    status=0
    cntools_ui_choose choice "${title}" "${choices[@]}" || status=$?
    (( status != 130 )) || return 130
    (( status == 0 )) || return 0
    cntools_wallet_log CHOICE "wallet history page=$((CNTOOLS_HISTORY_PAGE + 1)) choice=${choice}"
    case "${choice}" in
      "Next page") target=$((CNTOOLS_HISTORY_PAGE + 1)) ;;
      "Previous page") target=$((CNTOOLS_HISTORY_PAGE - 1)) ;;
      "Show details")
        status=0
        cntools_history_detail_view || status=$?
        (( status != 130 )) || return 130
        (( status == 0 )) || return 2
        # Redraw the page that was shown.
        target="${CNTOOLS_HISTORY_PAGE}" ;;
      "Page size")
        # Esc keeps the current size and page; a new size starts at page 1;
        # Ctrl+C cancels.
        status=0
        cntools_history_prompt_page_size || status=$?
        (( status != 130 )) || return 130
        (( status == 0 )) || { target="${CNTOOLS_HISTORY_PAGE}"; continue; }
        shown="" target="${CNTOOLS_HISTORY_PAGE}" ;;
      "Change lookup")
        if [[ "${lookup}" == stake ]]; then lookup=payment; credential="${payment_credential}"
        else lookup=stake; credential="${stake}"; fi
        cntools_wallet_log CHOICE "wallet history lookup changed lookup=${lookup}"
        if ! cntools_ui_spin_function "Fetching wallet inventory from Koios…" cntools_history_load "${kind}" "${credential}" "${lookup}"; then
          # The previous inventory is untouched: show the error, keep the page.
          cntools_ui_render_status error "${CNTOOLS_HISTORY_ERROR:-Koios is unavailable.}"; cntools_ui_wait
          lookup="${CNTOOLS_HISTORY_LOOKUP}"
          if [[ "${lookup}" == stake ]]; then credential="${stake}"; else credential="${payment_credential}"; fi
          target="${CNTOOLS_HISTORY_PAGE}"
          continue
        fi
        shown="" target=0 ;;
      *) return 0 ;;
    esac
  done
}
