#!/usr/bin/env bash
# Compact, manually refreshed block history in local/light/offline modes.
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
    leader)
      if [[ "${CNTOOLS_BLOCKLOG_HAS_RESULTS:-Y}" == Y ]]; then _blocks_status='Leader · scheduled / not yet validated'
      else _blocks_status='Leader · no block results recorded'; fi
      _blocks_role=accent ;;
    stolen) _blocks_status='Stolen · slot battle'; _blocks_role=danger ;;
    heightbattle) _blocks_status='Height battle'; _blocks_role=danger ;;
    unknown) _blocks_status='Unknown · not decided yet'; _blocks_role=warning ;;
    missed|ghosted|invalid) _blocks_status="${3^}"; _blocks_role=danger ;;
    *) _blocks_status="Unknown · $3" ;;
  esac
}

# A row that says why adopted and lost counts are missing: nothing records
# block results in this block log yet.
cntools_blocks_results_note() {
  [[ "${CNTOOLS_BLOCKLOG_HAS_RESULTS:-Y}" != Y ]] || return 0
  cntools_table_pair 'Block results' 'Not recorded · the validate service of cncli.sh (cardano-node) or amaru-leaderlog.sh (Amaru) records them' warning
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
  done < <(jq -r --arg results "${CNTOOLS_BLOCKLOG_HAS_RESULTS:-Y}" '[["Scheduled slots",.scheduled],["Ideal blocks",.ideal],["Luck",.luck],
    ["Adopted (incl. confirmed)",.adopted],["Confirmed",.confirmed],["Pending validation",.pending],
    ["Missed",.missed],["Ghosted",.ghosted],["Stolen",.stolen],["Height battles",.heightbattle],["Invalid",.invalid],["Unknown status",.unknown]][]
    | select(.[1]!=null)
    | select((.[0]|IN("Missed","Ghosted","Stolen","Height battles","Invalid","Unknown status")|not) or .[1]!=0)
    | select($results=="Y" or (.[0]|IN("Adopted (incl. confirmed)","Confirmed","Pending validation")|not))
    | map(tostring) | join("\u001f")' <<< "${record}")
}

# Per-status counts of one epoch, then its ideal blocks and luck when recorded.
cntools_blocks_epoch_rows() {
  local snapshot="$1" stats="$2" key='' value=''
  while IFS=$'\037' read -r key value; do
    [[ -n "${key}" ]] || continue
    if [[ "${key}" == Luck ]]; then cntools_table_pair Luck "$(cntools_number_format "${value}")%" number
    else cntools_blocks_number_pair "${key}" "${value}"; fi
  # Without block results every slot is pending, which Scheduled slots shows.
  done < <(jq -r --argjson stats "${stats}" --arg results "${CNTOOLS_BLOCKLOG_HAS_RESULTS:-Y}" '
    def count(s): map(select(.status==s))|length;
    [["Confirmed",count("confirmed")],["Adopted · awaiting confirmation",count("adopted")],
     ["Pending validation",count("leader")],["Missed",count("missed")],["Ghosted",count("ghosted")],
     ["Stolen",count("stolen")],["Height battles",count("heightbattle")],["Invalid",count("invalid")],
     ["Unknown status",(map(select(.status|IN("confirmed","adopted","leader","missed","ghosted","stolen","heightbattle","invalid")|not))|length)],
     ["Ideal blocks",$stats.ideal],["Luck",$stats.luck]][]
    | select(.[1]!=null and .[1]!=0)
    | select($results=="Y" or .[0]!="Pending validation") | map(tostring) | join("\u001f")' <<< "${snapshot}")
}

# Battle and timing rows of a record from its block details. Times are in
# milliseconds after the start of each block's own slot, as this node saw them.
CNTOOLS_BLOCKS_DETAIL_JQ='
  def secs: ((. / 10 | floor) / 100 | tostring) + " s";
  def who($ticker; $pool): if ($ticker // "") != "" then $ticker elif ($pool // "") != "" then $pool else "another pool" end;
  def reason_text: {"woke_late": "The node woke late for the slot", "tip_ahead": "The chain tip was already past the slot",
    "ocert_expired": "The operational certificate had expired", "ocert_not_yet_valid": "The operational certificate was not yet valid",
    "parent_not_stored": "The parent block was not stored", "ledger_tip_changed": "The ledger tip changed while forging",
    "not_led": "The node found it was not the leader", "NodeCannotForge": "The node could not forge",
    "BlockFromFuture": "Block from the future: check the clock", "SlotIsImmutable": "The slot was already immutable",
    "NoLedgerState": "No ledger state for the slot", "NoLedgerView": "No ledger state for the slot",
    "ForgedInvalidBlock": "The node forged an invalid block",
    "no_koios": "Nothing can tell yet whether our block is on the chain, and there is no Koios to ask",
    "koios_failed": "Nothing can tell yet whether our block is on the chain: Koios could not tell, checked again"}[.] // gsub("_"; " ");
  def gap($from; $to): ($to - $from) | if . > 0 then "\(.) s later" elif . < 0 then "\(-.) s earlier" else "same slot" end;
  def battle($slot; $status; $d):
    if $status == "heightbattle" and $d.winner_slot != null then
      [["Battle", "Height battle: \(who($d.winner_ticker; $d.winner_pool)) won with slot \($d.winner_slot), \(gap($slot; $d.winner_slot)), on the same parent"]]
    elif $status == "stolen" then
      [["Battle", "Slot battle with \(who($d.winner_ticker; $d.winner_pool))" +
        (if $d.vrf_lower == 1 then ", their VRF was lower" elif $d.vrf_lower == 0 then ", our VRF was lower" else "" end)]]
    elif $status == "ghosted" and $d.reason == "fork" then [["Battle", "Our block was built on a block that lost a fork"]]
    elif ($status == "missed" or $status == "invalid" or $status == "unknown") and ($d.reason // "") != "" then [["Reason", ($d.reason | reason_text)]]
    else [] end;
  def around($label; $slot; $at; $ticker; $pool; $ms):
    if $at == null then [] else
      [[$label, "Slot \($at), \(gap($slot; $at)) · \(who($ticker; $pool))" + (if $ms != null then " · reached us \($ms | secs) after its slot" else "" end)]]
    end;
  def timings($slot; $status; $d):
    (if $d.forge_ms != null then [["Our block forged", "\($d.forge_ms | secs) after the slot started"]] else [] end) +
    (if $d.winner_ms != null and ($status == "heightbattle" or $status == "stolen" or $status == "ghosted") then
      [["Their block arrived", "\($d.winner_ms | secs) after its slot" +
        (if $d.winner_slot != null and $d.winner_slot < $slot then
          (($d.winner_ms + ($d.winner_slot - $slot) * 1000) | if . > 0 then ", \(secs) into our slot" else ", \(-. | secs) before our slot" end)
         else "" end)]] else [] end) +
    around("Previous block"; $slot; $d.prev_slot; $d.prev_ticker; $d.prev_pool; $d.prev_ms) +
    around("Next block"; $slot; $d.next_slot; $d.next_ticker; $d.next_pool; $d.next_ms) +
    (if $d.forge_ms != null or $d.winner_ms != null or $d.prev_ms != null or $d.next_ms != null then
      [["Times", "As this node saw them. When our block reached other pools is not measured here."]] else [] end);
'

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
      Battle|Reason|'Our block forged'|'Their block arrived'|'Previous block'|'Next block'|Times)
        cntools_table_pair "${key}" "${value}" ;;
      *) cntools_blocks_number_pair "${key}" "${value}" ;;
    esac
  done < <(jq -r --arg detail "${detail}" "${CNTOOLS_BLOCKS_DETAIL_JQ}"'
    .slot as $slot | .status as $status | (.detail // {}) as $d |
    ([["Status",.status],["Scheduled at",.timestamp]] +
    (if .block>0 then [["Block",.block]] else [] end) +
    battle($slot; $status; $d) +
    (if $detail=="Y" then [["Slot",.slot],["Slot in epoch",.slot_in_epoch]] +
      (if .size>0 then [["Size (bytes)",.size]] else [] end) +
      (if (.hash|test("^[0-9a-fA-F]{64}$")) then [["Block hash",.hash]] else [] end) +
      timings($slot; $status; $d)
     else [] end))[] | select(.[1]!=null) | map(tostring | gsub("[\u0000-\u001f\u007f]";" ")) | join("\u001f")' <<< "${record}")
}

cntools_blocks_help() {
  cntools_ui_action_begin 'Status guide' '/ Blocks / Status guide'
  {
    cntools_table_pair Source 'Local block log · last recorded validation state'
    cntools_table_pair Leader 'Scheduled slot; may be in the future or awaiting validation.' accent
    cntools_table_pair 'Block results' 'Recorded by the validate service: cncli.sh on cardano-node, amaru-leaderlog.sh on Amaru.'
    cntools_table_pair Adopted 'Created locally; includes blocks later confirmed.' success
    cntools_table_pair Confirmed 'On chain at the configured confirmation depth.' success
    cntools_table_pair Missed 'No block produced in the scheduled slot; the reason is shown when the node logged one.' warning
    cntools_table_pair Stolen 'Slot battle: another pool led the same slot and its block won.' warning
    cntools_table_pair 'Height battle' 'Another pool built on the same parent in a nearby slot and won: one of the two blocks did not reach the other pool in time.' warning
    cntools_table_pair Ghosted 'Our block is not on the chain: built on a block that lost a fork, or lost for another reason.' warning
    cntools_table_pair Invalid 'Block creation failed. Inspect CNCLI / node logs for the reason.' danger
    cntools_table_pair Ideal 'Expected block count from active stake; omitted if pool statistics are ambiguous.'
    cntools_table_pair Luck 'Assigned schedule relative to ideal blocks, as recorded in the block log.'
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
  if ! cntools_ui_spin_function 'Reading block history…' "cntools_blocklog_${kind,,}" "${value}"; then
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
      cntools_table_pair Source 'Block log · manually refreshed'
      cntools_blocks_results_note
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
  # Quick opens the history straight away (its Source row names the block
  # log), so the note is shown only where a prompt follows.
  cntools_flow_quick || cntools_ui_render_status info 'Read-only local block log, not a live chain query. The validate service keeps block results current: cncli.sh on cardano-node, amaru-leaderlog.sh on Amaru.'
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
      cntools_table_pair Source 'Block log · Refresh to update'
      cntools_blocks_results_note
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
