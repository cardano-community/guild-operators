#!/usr/bin/env bash
# Stage 4 compatibility action for a hardened, read-only block epoch view.
# Sourcing defines functions only; the dispatcher supplies the inherited
# compatibility helpers and globals inside its isolated subshell.

_cntools_action_blocks_epoch_validation_failure() {
  printf '%s\n' 'CNTools blocks-epoch action failed validation.' >&2
  return 70
}

_cntools_action_blocks_epoch_uint_valid() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})$ &&
     "${maximum}" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
  (( value <= maximum ))
}

_cntools_action_blocks_epoch_performance_valid() {
  local value="${1:-}" integer_part=""

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,9})(\.[0-9]{1,15})?$ ]] ||
    return 1
  integer_part="${value%%.*}"
  _cntools_action_blocks_epoch_uint_valid \
    "${integer_part}" 1000000000 || return 1
  [[ "${integer_part}" != 1000000000 || "${value}" != *.* ]]
}

_cntools_action_blocks_epoch_database_validate() {
  local metadata="" owner="" mode="" links="" size=""

  [[ "${BLOCKLOG_DB:-}" == /* && -f "${BLOCKLOG_DB}" &&
     ! -L "${BLOCKLOG_DB}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${BLOCKLOG_DB}" || return 1
  metadata="$(_cntools_result_stat "${BLOCKLOG_DB}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${mode}" =~ ^(400|440|444|600|640|644)$ &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 1073741824 ]]
}

_cntools_action_blocks_epoch_query() {
  local output_variable="${1:-}" query="${2:-}" maximum_bytes="${3:-}"
  local query_output=""

  [[ "${output_variable}" == blocks_epoch_query_output &&
     -n "${query}" && "${maximum_bytes}" =~ ^[1-9][0-9]*$ &&
     "${maximum_bytes}" -le 8388608 ]] || return 1
  query_output="$("${blocks_epoch_sqlite_path}" -readonly -batch \
    -noheader -separator '|' "${BLOCKLOG_DB}" "${query}" 2>/dev/null)" ||
    return 1
  (( ${#query_output} <= maximum_bytes )) || return 1
  printf -v "${output_variable}" '%s' "${query_output}"
}

_cntools_action_blocks_epoch_load() {
  local line="" extra="" status="" status_length="" block=""
  local block_type="" slot="" slot_type="" slot_in_epoch=""
  local slot_in_epoch_type="" at_epoch="" at_type="" at_length=""
  local size="" size_type="" hash="" hash_length="" row_count=0
  local pool_candidate="" pool_length="" ideal="" ideal_type=""
  local performance="" performance_type=""

  blocks_epoch_rows=()
  blocks_epoch_pool_id=""
  blocks_epoch_ideal="-"
  blocks_epoch_performance="-"
  blocks_epoch_invalid=0
  blocks_epoch_missed=0
  blocks_epoch_ghosted=0
  blocks_epoch_stolen=0
  blocks_epoch_confirmed=0
  blocks_epoch_adopted_raw=0
  blocks_epoch_leader_raw=0
  blocks_epoch_status_width=6
  blocks_epoch_block_width=5
  blocks_epoch_slot_width=4
  blocks_epoch_slot_in_epoch_width=11
  blocks_epoch_size_width=4
  blocks_epoch_hash_width=4

  _cntools_action_blocks_epoch_query blocks_epoch_query_output \
    "SELECT substr(status,1,17), length(status), block, typeof(block), slot, typeof(slot), slot_in_epoch, typeof(slot_in_epoch), CAST(strftime('%s', at) AS INTEGER), typeof(at), length(at), size, typeof(size), substr(hash,1,513), length(hash) FROM blocklog WHERE epoch=${blocks_epoch_selected_epoch} ORDER BY slot ASC, id ASC LIMIT 10001;" \
    8388608 || return 1
  if [[ -n "${blocks_epoch_query_output}" ]]; then
    while IFS= read -r line; do
      IFS='|' read -r status status_length block block_type slot slot_type \
        slot_in_epoch slot_in_epoch_type at_epoch at_type at_length size \
        size_type hash hash_length extra <<< "${line}" || return 1
      [[ -z "${extra}" && "${status_length}" =~ ^[1-9][0-9]*$ &&
         "${status_length}" -le 16 && "${#status}" == "${status_length}" &&
         "${block_type}" == integer && "${slot_type}" == integer &&
         "${slot_in_epoch_type}" == integer && "${at_type}" == text &&
         "${size_type}" == integer && "${at_length}" =~ ^[1-9][0-9]*$ &&
         "${at_length}" -le 128 && "${hash_length}" =~ ^[0-9]+$ &&
         "${hash_length}" -le 512 && "${#hash}" == "${hash_length}" ]] ||
        return 1
      case "${status}" in
        invalid) blocks_epoch_invalid=$((blocks_epoch_invalid + 1)) ;;
        missed) blocks_epoch_missed=$((blocks_epoch_missed + 1)) ;;
        ghosted) blocks_epoch_ghosted=$((blocks_epoch_ghosted + 1)) ;;
        stolen) blocks_epoch_stolen=$((blocks_epoch_stolen + 1)) ;;
        confirmed) blocks_epoch_confirmed=$((blocks_epoch_confirmed + 1)) ;;
        adopted) blocks_epoch_adopted_raw=$((blocks_epoch_adopted_raw + 1)) ;;
        leader) blocks_epoch_leader_raw=$((blocks_epoch_leader_raw + 1)) ;;
        *) return 1 ;;
      esac
      _cntools_action_blocks_epoch_uint_valid "${block}" 2147483647 ||
        return 1
      _cntools_action_blocks_epoch_uint_valid "${slot}" 4294967295 ||
        return 1
      _cntools_action_blocks_epoch_uint_valid \
        "${slot_in_epoch}" 4294967295 || return 1
      _cntools_action_blocks_epoch_uint_valid "${at_epoch}" 4294967295 ||
        return 1
      _cntools_action_blocks_epoch_uint_valid "${size}" 16777216 ||
        return 1
      [[ "${hash}" =~ ^[-A-Za-z0-9+/=_:.]*$ ]] || return 1
      blocks_epoch_rows+=(
        "${status}|${block}|${slot}|${slot_in_epoch}|${at_epoch}|${size}|${hash}"
      )
      row_count=$((row_count + 1))
      (( row_count <= 10000 )) || return 1
      (( ${#status} > blocks_epoch_status_width )) &&
        blocks_epoch_status_width=${#status}
      (( ${#block} > blocks_epoch_block_width )) &&
        blocks_epoch_block_width=${#block}
      (( ${#slot} > blocks_epoch_slot_width )) &&
        blocks_epoch_slot_width=${#slot}
      (( ${#slot_in_epoch} > blocks_epoch_slot_in_epoch_width )) &&
        blocks_epoch_slot_in_epoch_width=${#slot_in_epoch}
      (( ${#size} > blocks_epoch_size_width )) &&
        blocks_epoch_size_width=${#size}
      (( ${#hash} > blocks_epoch_hash_width )) &&
        blocks_epoch_hash_width=${#hash}
    done <<< "${blocks_epoch_query_output}"
  fi

  _cntools_action_blocks_epoch_query blocks_epoch_query_output \
    "SELECT substr(pool_id,1,57), length(pool_id) FROM epochdata WHERE epoch=${blocks_epoch_selected_epoch} ORDER BY pool_id COLLATE BINARY ASC LIMIT 2;" \
    512 || return 1
  if [[ -n "${blocks_epoch_query_output}" ]]; then
    while IFS= read -r line; do
      IFS='|' read -r pool_candidate pool_length extra <<< "${line}" ||
        return 1
      [[ -z "${extra}" && "${pool_length}" == 56 &&
         "${pool_candidate}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 1
      [[ -n "${blocks_epoch_pool_id}" ]] ||
        blocks_epoch_pool_id="${pool_candidate}"
    done <<< "${blocks_epoch_query_output}"
  fi
  if [[ -n "${blocks_epoch_pool_id}" ]]; then
    _cntools_action_blocks_epoch_query blocks_epoch_query_output \
      "SELECT epoch_slots_ideal, typeof(epoch_slots_ideal), printf('%.15g', max_performance), typeof(max_performance) FROM epochdata WHERE epoch=${blocks_epoch_selected_epoch} AND pool_id='${blocks_epoch_pool_id}' ORDER BY id ASC LIMIT 2;" \
      512 || return 1
    [[ -n "${blocks_epoch_query_output}" &&
       "${blocks_epoch_query_output}" != *$'\n'* ]] || return 1
    IFS='|' read -r ideal ideal_type performance performance_type extra \
      <<< "${blocks_epoch_query_output}" || return 1
    [[ -z "${extra}" && "${ideal_type}" == integer &&
       ( "${performance_type}" == integer ||
         "${performance_type}" == real ) ]] || return 1
    _cntools_action_blocks_epoch_uint_valid "${ideal}" 1000000000 ||
      return 1
    _cntools_action_blocks_epoch_performance_valid "${performance}" ||
      return 1
    blocks_epoch_ideal="${ideal}"
    blocks_epoch_performance="${performance}%"
  fi

  blocks_epoch_adopted=$((blocks_epoch_adopted_raw + blocks_epoch_confirmed))
  blocks_epoch_leader=$((${#blocks_epoch_rows[@]}))
  return 0
}

_cntools_action_blocks_epoch_timestamp() {
  local timestamp="${1:-}" formatted=""

  _cntools_action_blocks_epoch_uint_valid "${timestamp}" 4294967295 ||
    return 1
  formatted="$(TZ="${blocks_epoch_timezone}" \
    printf '%(%F %T %Z)T' "${timestamp}")" || return 1
  [[ "${formatted}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ \
[0-9]{2}:[0-9]{2}:[0-9]{2}\ [A-Za-z0-9+_-]{1,16}$ ]] || return 1
  printf '%s\n' "${formatted}"
}

_cntools_action_blocks_epoch_divider() {
  local width="${1:-}" divider=""

  [[ "${width}" =~ ^[1-9][0-9]{0,3}$ && "${width}" -le 4096 ]] ||
    return 1
  printf -v divider "%${width}s" ''
  printf '|%s|\n' "${divider// /=}"
}

_cntools_action_blocks_epoch_summary() {
  local ideal_len=5 luck_len=4 divider_width=0

  (( ${#blocks_epoch_ideal} > ideal_len )) && ideal_len=${#blocks_epoch_ideal}
  (( ${#blocks_epoch_performance} > luck_len )) &&
    luck_len=${#blocks_epoch_performance}
  divider_width=$((6 + ideal_len + luck_len + 7 + 9 + 6 + 7 + 6 + 7 + 24 + 2))
  _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
  printf "| %-6s | %-${ideal_len}s | %-${luck_len}s | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" \
    Leader Ideal Luck Adopted Confirmed Missed Ghosted Stolen Invalid
  _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
  printf "| ${FG_LGRAY}%-6s${NC} | ${FG_LGRAY}%-${ideal_len}s${NC} | ${FG_LGRAY}%-${luck_len}s${NC} | ${FG_LBLUE}%-7s${NC} | ${FG_GREEN}%-9s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} | ${FG_RED}%-6s${NC} | ${FG_RED}%-7s${NC} |\n" \
    "${blocks_epoch_leader}" "${blocks_epoch_ideal}" \
    "${blocks_epoch_performance}" "${blocks_epoch_adopted}" \
    "${blocks_epoch_confirmed}" "${blocks_epoch_missed}" \
    "${blocks_epoch_ghosted}" "${blocks_epoch_stolen}" \
    "${blocks_epoch_invalid}"
  _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
}

_cntools_action_blocks_epoch_rows() {
  local view="${1:-}" row="" status="" block="" slot=""
  local slot_in_epoch="" at_epoch="" size="" hash="" formatted_at=""
  local block_count=1 divider_width=0

  case "${view}" in
    1)
      divider_width=$((${#blocks_epoch_leader} + blocks_epoch_status_width +
        blocks_epoch_block_width + blocks_epoch_slot_width +
        blocks_epoch_slot_in_epoch_width + 24 + 17))
      _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
      printf "| %-${#blocks_epoch_leader}s | %-${blocks_epoch_status_width}s | %-${blocks_epoch_block_width}s | %-${blocks_epoch_slot_width}s | %-${blocks_epoch_slot_in_epoch_width}s | %-24s |\n" \
        '#' Status Block Slot SlotInEpoch 'Scheduled At'
      _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
      ;;
    2)
      divider_width=$((${#blocks_epoch_leader} + blocks_epoch_status_width +
        blocks_epoch_slot_width + blocks_epoch_size_width +
        blocks_epoch_hash_width + 14))
      _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
      printf "| %-${#blocks_epoch_leader}s | %-${blocks_epoch_status_width}s | %-${blocks_epoch_slot_width}s | %-${blocks_epoch_size_width}s | %-${blocks_epoch_hash_width}s |\n" \
        '#' Status Slot Size Hash
      _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
      ;;
    3)
      divider_width=$((${#blocks_epoch_leader} + blocks_epoch_status_width +
        blocks_epoch_block_width + blocks_epoch_slot_width +
        blocks_epoch_slot_in_epoch_width + 24 + blocks_epoch_size_width +
        blocks_epoch_hash_width + 23))
      _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
      printf "| %-${#blocks_epoch_leader}s | %-${blocks_epoch_status_width}s | %-${blocks_epoch_block_width}s | %-${blocks_epoch_slot_width}s | %-${blocks_epoch_slot_in_epoch_width}s | %-24s | %-${blocks_epoch_size_width}s | %-${blocks_epoch_hash_width}s |\n" \
        '#' Status Block Slot SlotInEpoch 'Scheduled At' Size Hash
      _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
      ;;
    *) return 1 ;;
  esac
  for row in "${blocks_epoch_rows[@]}"; do
    IFS='|' read -r status block slot slot_in_epoch at_epoch size hash \
      <<< "${row}" || return 1
    [[ "${block}" == 0 ]] && block='-'
    [[ "${size}" == 0 ]] && size='-'
    [[ -n "${hash}" ]] || hash='-'
    case "${view}" in
      1)
        formatted_at="$(_cntools_action_blocks_epoch_timestamp \
          "${at_epoch}")" || return 1
        printf "| ${FG_LGRAY}%-${#blocks_epoch_leader}s${NC} | ${FG_LGRAY}%-${blocks_epoch_status_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_block_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_slot_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_slot_in_epoch_width}s${NC} | ${FG_LGRAY}%-24s${NC} |\n" \
          "${block_count}" "${status}" "${block}" "${slot}" \
          "${slot_in_epoch}" "${formatted_at}"
        ;;
      2)
        printf "| ${FG_LGRAY}%-${#blocks_epoch_leader}s${NC} | ${FG_LGRAY}%-${blocks_epoch_status_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_slot_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_size_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_hash_width}s${NC} |\n" \
          "${block_count}" "${status}" "${slot}" "${size}" "${hash}"
        ;;
      3)
        formatted_at="$(_cntools_action_blocks_epoch_timestamp \
          "${at_epoch}")" || return 1
        printf "| ${FG_LGRAY}%-${#blocks_epoch_leader}s${NC} | ${FG_LGRAY}%-${blocks_epoch_status_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_block_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_slot_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_slot_in_epoch_width}s${NC} | ${FG_LGRAY}%-24s${NC} | ${FG_LGRAY}%-${blocks_epoch_size_width}s${NC} | ${FG_LGRAY}%-${blocks_epoch_hash_width}s${NC} |\n" \
          "${block_count}" "${status}" "${block}" "${slot}" \
          "${slot_in_epoch}" "${formatted_at}" "${size}" "${hash}"
        ;;
    esac
    block_count=$((block_count + 1))
  done
  _cntools_action_blocks_epoch_divider "${divider_width}" || return 1
}

_cntools_action_blocks_epoch_info() {
  println OFF 'Block Status:\n'
  println OFF 'Leader    - Scheduled to make block at this slot'
  println OFF 'Ideal     - Expected/Ideal number of blocks assigned based on active stake (sigma)'
  println OFF 'Luck      - Leader slots assigned vs Ideal slots for this epoch'
  println OFF 'Adopted   - Block created successfully'
  println OFF 'Confirmed - Block created validated to be on-chain with the certainty'
  println OFF "            set in 'cncli.sh' for 'CONFIRM_BLOCK_CNT'"
  println OFF 'Missed    - Scheduled at slot but no record of it in cncli DB and no'
  println OFF '            other pool has made a block for this slot'
  println OFF 'Ghosted   - Block created but marked as orphaned and no other pool has made'
  println OFF '            a valid block for this slot, height battle or block propagation issue'
  println OFF 'Stolen    - Another pool has a valid block registered on-chain for the same slot'
  println OFF 'Invalid   - Pool failed to create block, base64 encoded error message'
  println OFF "            can be decoded with 'echo <base64 hash> | base64 -d | jq -r'"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local blocks_epoch_sqlite_path="" blocks_epoch_query_output=""
  local blocks_epoch_timezone="${BLOCKLOG_TZ:-UTC}"
  local blocks_epoch_selected_epoch="" blocks_epoch_current_epoch=""
  local blocks_epoch_pool_id="" blocks_epoch_ideal='-'
  local blocks_epoch_performance='-' blocks_epoch_view=1
  local blocks_epoch_view_output="${FG_YELLOW}[1] View 1${NC} | [2] View 2 | [3] View 3 | [i] Info"
  local blocks_epoch_key="" blocks_epoch_next_exists=""
  local blocks_epoch_invalid=0 blocks_epoch_missed=0
  local blocks_epoch_ghosted=0 blocks_epoch_stolen=0
  local blocks_epoch_confirmed=0 blocks_epoch_adopted_raw=0
  local blocks_epoch_leader_raw=0 blocks_epoch_adopted=0
  local blocks_epoch_leader=0 blocks_epoch_status_width=6
  local blocks_epoch_block_width=5 blocks_epoch_slot_width=4
  local blocks_epoch_slot_in_epoch_width=11 blocks_epoch_size_width=4
  local blocks_epoch_hash_width=4 load_status=0
  local -a blocks_epoch_rows=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F cntools_context_has >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1 ||
     ! builtin declare -F getEpoch >/dev/null 2>&1; then
    _cntools_action_blocks_epoch_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_blocks_epoch_validation_failure
    return 70
  }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_blocks_epoch_validation_failure
    return 70
  }
  cntools_context_has "${context_file}" features blocklog || {
    _cntools_action_blocks_epoch_validation_failure
    return 70
  }
  if ! _cntools_registry_tool_path sqlite3 blocks_epoch_sqlite_path; then
    println ERROR "${FG_RED}ERROR${NC}: sqlite3 not found!"
    waitToProceed
    return 20
  fi
  if ! _cntools_action_blocks_epoch_database_validate; then
    println ERROR "${FG_RED}ERROR${NC}: blocklog database not found!"
    waitToProceed
    return 20
  fi
  [[ "${blocks_epoch_timezone}" =~ ^(UTC|Etc/[A-Za-z0-9_+.-]{1,64}|[A-Za-z][A-Za-z0-9_+.-]{0,63}/[A-Za-z0-9_+.-]{1,64})$ ]] || {
    _cntools_action_blocks_epoch_validation_failure
    return 70
  }
  blocks_epoch_current_epoch="$(getEpoch)" || blocks_epoch_current_epoch=""
  _cntools_action_blocks_epoch_uint_valid \
    "${blocks_epoch_current_epoch}" 2147483646 || {
    _cntools_action_blocks_epoch_validation_failure
    return 70
  }
  _cntools_action_blocks_epoch_query blocks_epoch_query_output \
    "SELECT CASE WHEN EXISTS(SELECT 1 FROM blocklog WHERE epoch=$((blocks_epoch_current_epoch + 1)) LIMIT 1) THEN 1 ELSE 0 END;" \
    8 || {
    _cntools_action_blocks_epoch_validation_failure
    return 70
  }
  [[ "${blocks_epoch_query_output}" == 0 ||
     "${blocks_epoch_query_output}" == 1 ]] || {
    _cntools_action_blocks_epoch_validation_failure
    return 70
  }
  blocks_epoch_next_exists="${blocks_epoch_query_output}"
  if [[ "${blocks_epoch_next_exists}" == 1 ]]; then
    println DEBUG \
      "\n${FG_YELLOW}Leader schedule for next epoch[$((blocks_epoch_current_epoch + 1))] available${NC}"
  fi
  echo
  getAnswerAnyCust blocks_epoch_selected_epoch \
    'Enter epoch to list (enter for current)'
  [[ -n "${blocks_epoch_selected_epoch}" ]] ||
    blocks_epoch_selected_epoch="${blocks_epoch_current_epoch}"
  if ! _cntools_action_blocks_epoch_uint_valid \
      "${blocks_epoch_selected_epoch}" 2147483647; then
    println ERROR "\n${FG_RED}ERROR${NC}: epoch must be a canonical integer between 0 and 2147483647"
    waitToProceed
    return 20
  fi
  if ! _cntools_action_blocks_epoch_load; then
    _cntools_action_blocks_epoch_validation_failure
    return 70
  fi
  if (( ${#blocks_epoch_rows[@]} == 0 )); then
    println "No blocks in epoch ${blocks_epoch_selected_epoch}"
    waitToProceed
    return 20
  fi

  while true; do
    clear
    println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
    println ' >> BLOCKS'
    println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
    blocks_epoch_current_epoch="$(getEpoch)" || blocks_epoch_current_epoch=""
    _cntools_action_blocks_epoch_uint_valid \
      "${blocks_epoch_current_epoch}" 2147483646 || {
      _cntools_action_blocks_epoch_validation_failure
      return 70
    }
    println DEBUG "Current epoch  : ${FG_LBLUE}${blocks_epoch_current_epoch}${NC}"
    println DEBUG "Selected epoch : ${FG_LBLUE}${blocks_epoch_selected_epoch}${NC}\n"
    _cntools_action_blocks_epoch_summary || {
      _cntools_action_blocks_epoch_validation_failure
      return 70
    }
    echo
    if (( blocks_epoch_view == 4 )); then
      _cntools_action_blocks_epoch_info
    else
      _cntools_action_blocks_epoch_rows "${blocks_epoch_view}" || {
        _cntools_action_blocks_epoch_validation_failure
        return 70
      }
    fi
    echo
    println OFF "[h] Home | ${blocks_epoch_view_output} | [*] Refresh"
    read -rsn1 blocks_epoch_key
    case "${blocks_epoch_key}" in
      h) return 20 ;;
      1)
        blocks_epoch_view=1
        blocks_epoch_view_output="${FG_YELLOW}[1] View 1${NC} | [2] View 2 | [3] View 3 | [i] Info"
        ;;
      2)
        blocks_epoch_view=2
        blocks_epoch_view_output="[1] View 1 | ${FG_YELLOW}[2] View 2${NC} | [3] View 3 | [i] Info"
        ;;
      3)
        blocks_epoch_view=3
        blocks_epoch_view_output="[1] View 1 | [2] View 2 | ${FG_YELLOW}[3] View 3${NC} | [i] Info"
        ;;
      i)
        blocks_epoch_view=4
        blocks_epoch_view_output="[1] View 1 | [2] View 2 | [3] View 3 | ${FG_YELLOW}[i] Info${NC}"
        ;;
      *)
        load_status=0
        _cntools_action_blocks_epoch_load || load_status=$?
        [[ "${load_status}" == 0 && ${#blocks_epoch_rows[@]} -gt 0 ]] || {
          _cntools_action_blocks_epoch_validation_failure
          return 70
        }
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
