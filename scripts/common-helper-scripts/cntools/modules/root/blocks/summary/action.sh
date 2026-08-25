#!/usr/bin/env bash
# Stage 4 compatibility action for the characterized legacy block summary.
# Sourcing defines functions only; the dispatcher supplies the inherited
# legacy helpers and globals inside its isolated compatibility subshell.

cntools_action_main() {
  local context_file="${1:-}"
  local result_file="${2:-}"
  local epoch_enter="" view=1
  local view_output="${FG_YELLOW}[b] Block View${NC} | [i] Info"
  local key="" current_epoch=0 first_epoch=0 ideal_len=0 luck_len=0
  local invalid_cnt=0 missed_cnt=0 ghosted_cnt=0 stolen_cnt=0
  local confirmed_cnt=0 adopted_cnt=0 leader_cnt=0
  local summary_pool_id="" pool_predicate=" AND 0"
  local -a epoch_stats=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64

  if ! command -v sqlite3 >/dev/null 2>&1; then
    println ERROR "${FG_RED}ERROR${NC}: sqlite3 not found!"
    waitToProceed
    return 20
  fi
  if [[ ! -f "${BLOCKLOG_DB}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: blocklog database not found!"
    waitToProceed
    return 20
  fi

  getAnswerAnyCust epoch_enter \
    "Enter number of epochs to show (enter for 10)"
  epoch_enter=${epoch_enter:-10}
  if [[ ! "${epoch_enter}" =~ ^(0|[1-9][0-9]{0,2}|1000)$ ]] ||
     ! isNumber "${epoch_enter}"; then
    println ERROR "\n${FG_RED}ERROR${NC}: not a number between 0 and 1000"
    waitToProceed
    return 20
  fi

  while true; do
    clear
    println DEBUG \
      "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println " >> BLOCKS"
    println DEBUG \
      "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    current_epoch=$(getEpoch)
    println DEBUG "Current epoch: ${FG_LBLUE}${current_epoch}${NC}\n"
    if [[ ${view} -eq 1 ]]; then
      [[ $(sqlite3 -readonly "${BLOCKLOG_DB}" \
        "SELECT EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((current_epoch+1)) LIMIT 1);" \
        2>/dev/null) -eq 1 ]] && ((current_epoch++))
      first_epoch=$(( current_epoch - epoch_enter ))
      [[ ${first_epoch} -lt 0 ]] && first_epoch=0

      summary_pool_id=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
        "SELECT pool_id FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch} ORDER BY epoch DESC, pool_id ASC LIMIT 1;" \
        2>/dev/null)
      pool_predicate=" AND 0"
      if [[ "${summary_pool_id}" =~ ^[0-9a-fA-F]{56}$ ]]; then
        pool_predicate=" AND pool_id='${summary_pool_id}'"
      fi
      ideal_len=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
        "SELECT LENGTH(epoch_slots_ideal) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch}${pool_predicate} ORDER BY LENGTH(epoch_slots_ideal) DESC LIMIT 1;")
      [[ ${ideal_len} -lt 5 ]] && ideal_len=5
      luck_len=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
        "SELECT LENGTH(max_performance) FROM epochdata WHERE epoch BETWEEN ${first_epoch} and ${current_epoch}${pool_predicate} ORDER BY LENGTH(max_performance) DESC LIMIT 1;")
      [[ $((luck_len+1)) -le 4 ]] && luck_len=4 || luck_len=$((luck_len+1))
      printf '|'
      printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" "" | tr " " "="
      printf '|\n'
      printf "| %-5s | %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" \
        "Epoch" "Leader" "Ideal" "Luck" "Adopted" "Confirmed" \
        "Missed" "Ghosted" "Stolen" "Invalid"
      printf '|'
      printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" "" | tr " " "="
      printf '|\n'
      while [[ ${current_epoch} -gt ${first_epoch} ]]; do
        invalid_cnt=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='invalid';" 2>/dev/null)
        missed_cnt=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='missed';" 2>/dev/null)
        ghosted_cnt=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='ghosted';" 2>/dev/null)
        stolen_cnt=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='stolen';" 2>/dev/null)
        confirmed_cnt=$(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='confirmed';" 2>/dev/null)
        adopted_cnt=$(( $(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='adopted';" 2>/dev/null) + confirmed_cnt ))
        leader_cnt=$(( $(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT COUNT(*) FROM blocklog WHERE epoch=${current_epoch} AND status='leader';" 2>/dev/null) + adopted_cnt + invalid_cnt + missed_cnt + ghosted_cnt + stolen_cnt ))
        IFS='|' read -ra epoch_stats <<< "$(sqlite3 -readonly "${BLOCKLOG_DB}" \
          "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=${current_epoch}${pool_predicate} LIMIT 1;" \
          2>/dev/null)"
        IFS=' '
        if [[ ${#epoch_stats[@]} -eq 0 ]]; then
          epoch_stats=("-" "-")
        else
          epoch_stats[1]="${epoch_stats[1]}%"
        fi
        printf "| ${FG_LGRAY}%-5s${NC} | ${FG_LGRAY}%-6s${NC} | ${FG_LGRAY}%-${ideal_len}s${NC} | ${FG_LGRAY}%-${luck_len}s${NC} | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" \
          "${current_epoch}" "${leader_cnt}" "${epoch_stats[0]}" \
          "${epoch_stats[1]}" "${adopted_cnt}" "${confirmed_cnt}" \
          "${missed_cnt}" "${ghosted_cnt}" "${stolen_cnt}" "${invalid_cnt}"
        ((current_epoch--))
      done
      printf '|'
      printf "%$((5+6+ideal_len+luck_len+7+9+6+7+6+7+27+2))s" "" | tr " " "="
      printf '|\n'
    else
      println OFF "Block Status:\n"
      println OFF "Leader    - Scheduled to make block at this slot"
      println OFF "Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)"
      println OFF "Luck      - Leader slots assigned vs Ideal slots for this epoch"
      println OFF "Adopted   - Block created successfully"
      println OFF "Confirmed - Block created validated to be on-chain with the certainty"
      println OFF "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
      println OFF "Missed    - Scheduled at slot but no record of it in cncli DB and no"
      println OFF "            other pool has made a block for this slot"
      println OFF "Ghosted   - Block created but marked as orphaned and no other pool has made"
      println OFF "            a valid block for this slot, height battle or block propagation issue"
      println OFF "Stolen    - Another pool has a valid block registered on-chain for the same slot"
      println OFF "Invalid   - Pool failed to create block, base64 encoded error message"
      println OFF "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
    fi
    echo
    println OFF "[h] Home | ${view_output} | [*] Refresh"
    read -rsn1 key
    case ${key} in
      h ) return 20 ;;
      b ) view=1; view_output="${FG_YELLOW}[b] Block View${NC} | [i] Info" ;;
      i ) view=2; view_output="[b] Block View | ${FG_YELLOW}[i] Info${NC}" ;;
      * ) continue ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
