#!/usr/bin/env bash
# Compact, manually refreshed CNCLI block history in local/light/offline modes.
# shellcheck disable=SC2034

cntools_blocks_interact() {
  local status=0
  "$@" || status=$?
  if (( status == 1 || status == 130 )); then CNTOOLS_BLOCKS_CANCELLED=Y; fi
  return "${status}"
}

cntools_blocks_number_pair() {
  local value=''
  cntools_number_format_into value "$2" || value=Unavailable
  cntools_table_pair "$1" "${value}" number
}

cntools_blocks_status_into() {
  local -n _blocks_status="$1" _blocks_role="$2"
  _blocks_status="$3"; _blocks_role=warning
  case "$3" in
    confirmed) _blocks_status=Confirmed; _blocks_role=success ;;
    adopted) _blocks_status='Adopted · awaiting confirmation'; _blocks_role=success ;;
    leader) _blocks_status='Leader · scheduled / not yet validated'; _blocks_role=accent ;;
    missed|ghosted|stolen|invalid) _blocks_status="${3^}"; _blocks_role=danger ;;
    *) _blocks_status="Unknown · $3" ;;
  esac
}

cntools_blocks_summary_rows() {
  local record="$1" key='' value=''
  while IFS=$'\037' read -r key value; do
    [[ -n "${key}" ]] || continue
    if [[ "${key}" == 'Luck' ]]; then
      cntools_table_pair Luck "$(cntools_number_format "${value}")%" number || return 1
    else
      cntools_blocks_number_pair "${key}" "${value}"
    fi
  # Failure and unknown counts appear only when they occurred.
  done < <(jq -r '[["Scheduled slots",.scheduled],["Ideal blocks",.ideal],["Luck",.luck],
    ["Adopted (incl. confirmed)",.adopted],["Confirmed",.confirmed],["Pending validation",.pending],
    ["Missed",.missed],["Ghosted",.ghosted],["Stolen",.stolen],["Invalid",.invalid],["Unknown status",.unknown]][]
    | select(.[1]!=null)
    | select((.[0]|IN("Missed","Ghosted","Stolen","Invalid","Unknown status")|not) or .[1]!=0)
    | map(tostring) | join("\u001f")' <<< "${record}")
}

# Per-status counts of one epoch, then its ideal blocks and luck when recorded.
cntools_blocks_epoch_rows() {
  local snapshot="$1" stats="$2" key='' value=''
  while IFS=$'\037' read -r key value; do
    [[ -n "${key}" ]] || continue
    if [[ "${key}" == Luck ]]; then cntools_table_pair Luck "$(cntools_number_format "${value}")%" number
    else cntools_blocks_number_pair "${key}" "${value}"; fi
  done < <(jq -r --argjson stats "${stats}" '
    def count(s): map(select(.status==s))|length;
    [["Confirmed",count("confirmed")],["Adopted · awaiting confirmation",count("adopted")],
     ["Pending validation",count("leader")],["Missed",count("missed")],["Ghosted",count("ghosted")],
     ["Stolen",count("stolen")],["Invalid",count("invalid")],
     ["Unknown status",(map(select(.status|IN("confirmed","adopted","leader","missed","ghosted","stolen","invalid")|not))|length)],
     ["Ideal blocks",$stats.ideal],["Luck",$stats.luck]][]
    | select(.[1]!=null and .[1]!=0) | map(tostring) | join("\u001f")' <<< "${snapshot}")
}

cntools_blocks_record_rows() {
  local record="$1" detail="$2" key='' value='' status='' role='' date=''
  while IFS=$'\037' read -r key value; do
    [[ -n "${key}" ]] || continue
    case "${key}" in
      Status) cntools_blocks_status_into status role "${value}"; cntools_table_pair Status "${status}" "${role}" ;;
      'Scheduled at')
        cntools_timestamp_datetime_into date "${value}" || date=Unavailable
        cntools_table_pair 'Scheduled at' "${date}" ;;
      'Block hash') cntools_table_pair "${key}" "${value}" identifier ;;
      *) cntools_blocks_number_pair "${key}" "${value}" ;;
    esac
  done < <(jq -r --arg detail "${detail}" '([["Status",.status],["Scheduled at",.timestamp]] +
    (if .block>0 then [["Block",.block]] else [] end) +
    (if $detail=="Y" then [["Slot",.slot],["Slot in epoch",.slot_in_epoch]] +
      (if .size>0 then [["Size (bytes)",.size]] else [] end) +
      (if (.hash|test("^[0-9a-fA-F]{64}$")) then [["Block hash",.hash]] else [] end)
     else [] end))[] | select(.[1]!=null) | map(tostring | gsub("[\u0000-\u001f\u007f]";" ")) | join("\u001f")' <<< "${record}")
}

cntools_blocks_help() {
  cntools_ui_action_begin 'Status guide' '/ Blocks / Status guide'
  {
    cntools_table_pair Source 'Local CNCLI block log · last recorded validation state'
    cntools_table_pair Leader 'Scheduled slot; may be in the future or awaiting validation.' accent
    cntools_table_pair Adopted 'Created locally; includes blocks later confirmed.' success
    cntools_table_pair Confirmed 'Confirmed on chain by CNCLI at its configured confirmation depth.' success
    cntools_table_pair Missed 'No recorded block produced in the scheduled slot.' warning
    cntools_table_pair Ghosted 'Our block was orphaned; no other valid block in the same slot.' warning
    cntools_table_pair Stolen 'Another pool produced the valid block for that slot.' warning
    cntools_table_pair Invalid 'Block creation failed. Inspect CNCLI / node logs for the reason.' danger
    cntools_table_pair Ideal 'Expected block count from active stake; omitted if pool statistics are ambiguous.'
    cntools_table_pair Luck 'Assigned schedule relative to ideal blocks, as recorded by CNCLI.'
  } | cntools_table_render 'Block status' || return 1
  cntools_ui_wait
}

cntools_blocks_prompt_integer() {
  local -n _blocks_input="$1"
  local prompt="$2" default="$3" minimum="$4" maximum="$5" entered='' normalized=''
  while true; do
    cntools_blocks_interact cntools_ui_input entered "${prompt} (Enter for $(cntools_number_format "${default}"))" "${default}" || return $?
    if cntools_blocklog_integer_into normalized "${entered:-${default}}" &&
        (( normalized >= minimum && normalized <= maximum )); then
      _blocks_input="${normalized}"
      cntools_log CHOICE "Blocks ${prompt}=${normalized}" || true
      return 0
    fi
    cntools_ui_render_status warn "Enter a whole number from $(cntools_number_format "${minimum}") to $(cntools_number_format "${maximum}")."
  done
}

# A prompt inside a view: Esc (1) keeps the view (returns 1 with the cancel
# mark cleared), Ctrl+C (130) leaves the action.
cntools_blocks_prompt_in_view() {
  local in_view_status=0
  cntools_blocks_prompt_integer "$@" || in_view_status=$?
  ((in_view_status == 0 || in_view_status == 130)) && return "${in_view_status}"
  CNTOOLS_BLOCKS_CANCELLED=N
  return 1
}

# 3 = the error is shown and acknowledged; callers keep their current view.
cntools_blocks_load() {
  local kind="$1" value="$2"
  if ! cntools_ui_spin_function 'Reading CNCLI block history…' "cntools_blocklog_${kind,,}" "${value}"; then
    cntools_ui_render_status error "${CNTOOLS_BLOCKLOG_ERROR:-Could not read block history.}"
    cntools_ui_wait
    return 3
  fi
}

# choose=Y (the Epoch action) also offers another epoch from the menu.
cntools_blocks_epoch_view() {
  local epoch="$1" choose="${2:-N}" page=0 total=0 index=0 last=0 choice='' record='' number='' requested='' status=0
  local snapshot='' stats=''
  local -a options=()
  cntools_blocks_load Epoch "${epoch}" || return $?
  snapshot="${CNTOOLS_BLOCKLOG_DATA}"; stats="${CNTOOLS_BLOCKLOG_EPOCH_STATS}"
  while true; do
    total="$(jq 'length' <<< "${snapshot}")" || return 1
    cntools_ui_action_begin Epoch '/ Blocks / Epoch'
    {
      cntools_blocks_number_pair Epoch "${epoch}"
      cntools_blocks_number_pair 'Scheduled slots' "${total}"
      cntools_blocks_epoch_rows "${snapshot}" "${stats}"
      if (( total > 0 )); then
        cntools_table_pair Showing "$(cntools_number_format "$((page*5+1))")–$(cntools_number_format "$((page*5+5 <= total ? page*5+5 : total))") of $(cntools_number_format "${total}")"
      fi
      cntools_table_pair Source 'CNCLI block log · manually refreshed'
    } | cntools_table_render 'Epoch' || return 1
    last=$((page*5+5)); (( last <= total )) || last="${total}"
    for ((index=page*5;index<last;index++)); do
      record="$(jq -c ".[${index}]" <<< "${snapshot}")" || return 1
      cntools_blocks_record_rows "${record}" N | cntools_table_render "$(cntools_number_format "$((index+1))") · Slot $(cntools_number_format "$(jq -r '.slot' <<< "${record}")")" || return 1
    done
    (( total > 0 )) || cntools_ui_render_status info 'No scheduled blocks recorded for this epoch.'
    options=()
    (( last >= total )) || options+=('Next page')
    (( page == 0 )) || options+=('Previous page')
    (( total == 0 )) || options+=('Show block details')
    [[ "${choose}" != Y ]] || options+=('Choose epoch')
    options+=('Refresh' 'Status guide' 'Back')
    cntools_blocks_interact cntools_ui_choose choice 'Block history' "${options[@]}" || return $?
    cntools_log CHOICE "Blocks epoch=${epoch} page=${page} choice=${choice}" || true
    case "${choice}" in
      'Next page') page=$((page+1)) ;;
      'Previous page') page=$((page-1)) ;;
      Refresh) cntools_blocks_load Epoch "${epoch}" || continue; snapshot="${CNTOOLS_BLOCKLOG_DATA}"; stats="${CNTOOLS_BLOCKLOG_EPOCH_STATS}"; page=0 ;;
      'Choose epoch')
        requested="${epoch}"; status=0
        cntools_blocks_prompt_in_view requested 'Epoch' "${epoch}" 0 999999999 || status=$?
        ((status != 130)) || return 130
        ((status == 0)) || continue
        cntools_blocks_load Epoch "${requested}" || continue # Keeps the current epoch.
        epoch="${requested}"; snapshot="${CNTOOLS_BLOCKLOG_DATA}"; stats="${CNTOOLS_BLOCKLOG_EPOCH_STATS}"; page=0 ;;
      'Status guide') cntools_blocks_help || return 1 ;;
      'Show block details')
        status=0; cntools_blocks_prompt_in_view number 'Block number in this list' "$((page*5+1))" 1 "${total}" || status=$?
        ((status != 130)) || return 130
        ((status == 0)) || continue
        record="$(jq -c ".[${number}-1]" <<< "${snapshot}")" || return 1
        cntools_ui_action_begin 'Block details' '/ Blocks / Epoch'
        cntools_blocks_record_rows "${record}" Y | cntools_table_render "Slot $(cntools_number_format "$(jq -r '.slot' <<< "${record}")")" || return 1
        cntools_ui_wait ;;
      *) return 0 ;;
    esac
  done
}

cntools_blocks_wizard() {
  local kind="$1" count=10 epoch='' snapshot='' page=0 total=0 index=0 last=0 choice='' record='' status=0 requested=''
  local -a options=()
  cntools_ui_action_begin "${kind}" "/ Blocks / ${kind}"
  # Quick opens the history straight away (its Source row names the CNCLI
  # log), so the note is shown only where a prompt follows.
  cntools_flow_quick || cntools_ui_render_status info 'Read-only local CNCLI history, not a live chain query. CNCLI / logMonitor must maintain the journal for production statuses to stay current.'
  if [[ "${kind}" == Epoch ]]; then
    cntools_blocks_load Summary 1 || return $?
    # An empty journal has no latest epoch to open.
    if [[ "$(jq 'length' <<< "${CNTOOLS_BLOCKLOG_DATA}")" == 0 ]]; then
      cntools_ui_render_status info 'No block history recorded yet.'
      cntools_ui_wait
      return 0
    fi
    epoch="$(jq -r '.[0].epoch' <<< "${CNTOOLS_BLOCKLOG_DATA}")" || return 1
    # Quick opens the latest recorded epoch; 'Choose epoch' picks another.
    if cntools_flow_quick; then cntools_log CHOICE "Blocks epoch default=${epoch} flow=quick" || true
    else cntools_blocks_prompt_integer epoch 'Epoch (latest recorded)' "${epoch}" 0 999999999 || return $?; fi
    cntools_blocks_epoch_view "${epoch}" Y
    return $?
  fi
  # Quick shows the last 10 epochs; 'Change epoch count' asks for another.
  if cntools_flow_quick; then cntools_log CHOICE "Blocks summary epochs default=${count} flow=quick" || true
  else cntools_blocks_prompt_integer count 'Recent recorded epochs' 10 1 100 || return $?; fi
  cntools_blocks_load Summary "${count}" || return $?
  snapshot="${CNTOOLS_BLOCKLOG_DATA}"
  while true; do
    cntools_ui_action_begin Summary '/ Blocks / Summary'
    total="$(jq 'length' <<< "${snapshot}")" || return 1
    {
      cntools_table_pair Source 'CNCLI block log · Refresh to update'
      if (( total > 0 )); then
        cntools_table_pair 'Recorded epochs' "$(cntools_number_format "$((page*5+1))")–$(cntools_number_format "$((page*5+5 <= total ? page*5+5 : total))") of $(cntools_number_format "${total}")"
      fi
    } | cntools_table_render 'Summary' || return 1
    (( total > 0 )) || cntools_ui_render_status info 'No block history recorded yet.'
    last=$((page*5+5)); (( last <= total )) || last="${total}"
    for ((index=page*5;index<last;index++)); do
      record="$(jq -c ".[${index}]" <<< "${snapshot}")" || return 1
      cntools_blocks_summary_rows "${record}" | cntools_table_render "Epoch $(cntools_number_format "$(jq -r '.epoch' <<< "${record}")")" || return 1
    done
    options=()
    (( last >= total )) || options+=('Next page')
    (( page == 0 )) || options+=('Previous page')
    # An empty journal has no epoch to view.
    (( total == 0 )) || options+=('View epoch')
    options+=('Change epoch count' 'Refresh' 'Status guide' 'Back')
    cntools_blocks_interact cntools_ui_choose choice 'Block summary' "${options[@]}" || return $?
    cntools_log CHOICE "Blocks summary page=${page} choice=${choice}" || true
    case "${choice}" in
      'Next page') page=$((page+1)) ;;
      'Previous page') page=$((page-1)) ;;
      'View epoch')
        epoch="$(jq -r '.[0].epoch // 0' <<< "${snapshot}")" || return 1
        status=0; cntools_blocks_prompt_in_view epoch 'Epoch' "${epoch}" 0 999999999 || status=$?
        ((status != 130)) || return 130
        ((status == 0)) || continue
        status=0; cntools_blocks_epoch_view "${epoch}" || status=$?
        # Ctrl+C leaves the action; Esc/Back or an acknowledged load error
        # returns to this summary.
        ((status != 130)) || return 130
        if [[ "${CNTOOLS_BLOCKS_CANCELLED}" == Y ]]; then CNTOOLS_BLOCKS_CANCELLED=N;
        elif (( status != 0 && status != 3 )); then return "${status}"; fi ;;
      'Change epoch count')
        requested="${count}"; status=0
        cntools_blocks_prompt_in_view requested 'Recent recorded epochs' "${count}" 1 100 || status=$?
        ((status != 130)) || return 130
        ((status == 0)) || continue
        cntools_blocks_load Summary "${requested}" || continue # Keeps the current list.
        count="${requested}"; snapshot="${CNTOOLS_BLOCKLOG_DATA}"; page=0 ;;
      Refresh) cntools_blocks_load Summary "${count}" || continue; snapshot="${CNTOOLS_BLOCKLOG_DATA}"; page=0 ;;
      'Status guide') cntools_blocks_help || return 1 ;;
      *) return 0 ;;
    esac
  done
}

cntools_blocks_action() {
  local status=0
  CNTOOLS_BLOCKS_CANCELLED=N
  cntools_blocks_wizard "$1" || status=$?
  if [[ "${CNTOOLS_BLOCKS_CANCELLED}" == Y ]]; then
    cntools_log CHOICE 'Blocks cancelled' || true
    return 0
  fi
  ((status != 3)) || return 0 # The load error was shown and acknowledged.
  return "${status}"
}
