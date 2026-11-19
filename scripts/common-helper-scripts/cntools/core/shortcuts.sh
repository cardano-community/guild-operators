#!/usr/bin/env bash
# Go to and saved shortcuts. Every menu has a "Go to" row (00) that jumps to
# any menu or action; a shortcut is a saved code of 1 to 4 letters or digits
# typed there. Functions only; sourced by the CNTools entrypoint after
# settings.sh and gum.sh, whose private state folder and prompts it uses.
# shellcheck disable=SC2034

CNTOOLS_SHORTCUTS_SCHEMA_VERSION=1
CNTOOLS_SHORTCUTS_MAX=100
CNTOOLS_SHORTCUTS_CODE_PATTERN='^[a-z0-9]{1,4}$'
# Menu entry ids are their folders below modules/root, such as pool/register.
CNTOOLS_SHORTCUTS_TARGET_PATTERN='^[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)*$'
CNTOOLS_SHORTCUTS_FILE=""
CNTOOLS_SHORTCUTS_STAGE_FILE=""
CNTOOLS_SHORTCUTS_ASIDE_FILE=""
# What the last load found: none (no file yet), ok, invalid (a file CNTools
# cannot read, which is never overwritten) or unavailable (no state folder).
CNTOOLS_SHORTCUTS_STATE="none"
declare -ag CNTOOLS_SHORTCUTS_CODES=()
declare -ag CNTOOLS_SHORTCUTS_TARGETS=()
# Every menu and action in this session's menu cache, each menu followed by
# its own entries, in menu order. Advanced entries hidden without -a are not
# in the cache.
declare -ag CNTOOLS_SHORTCUTS_ENTRY_IDS=()
declare -ag CNTOOLS_SHORTCUTS_ENTRY_KINDS=()
declare -ag CNTOOLS_SHORTCUTS_ENTRY_NAMES=()
declare -ag CNTOOLS_SHORTCUTS_ENTRY_DESCRIPTIONS=()
declare -ag CNTOOLS_SHORTCUTS_ENTRY_ENABLED=()
declare -ag CNTOOLS_SHORTCUTS_ENTRY_REASONS=()
declare -ag CNTOOLS_SHORTCUTS_ENTRY_ROWS=()

cntools_shortcuts_log() {
  if declare -F cntools_log >/dev/null 2>&1; then
    cntools_log "${1:-INFO}" "${2:-}" || true
  fi
}

# Shortcuts live next to the transaction settings, in the folder that
# cntools_settings_init checked at startup.
cntools_shortcuts_paths() {
  CNTOOLS_SHORTCUTS_FILE=""
  [[ -n "${CNTOOLS_ROOT:-}" && -n "${CNTOOLS_SETTINGS_STATE_DIR:-}" &&
     "${CNTOOLS_SETTINGS_STATE_DIR}" == "${CNTOOLS_ROOT}/.state" ]] || return 1
  CNTOOLS_SHORTCUTS_FILE="${CNTOOLS_SETTINGS_STATE_DIR}/shortcuts.json"
}

cntools_shortcuts_file_valid() {
  local file="${CNTOOLS_SHORTCUTS_FILE:-}"
  local size=""

  cntools_settings_state_directory_safe || return 1
  [[ -n "${file}" && -f "${file}" && ! -L "${file}" && -O "${file}" ]] ||
    return 1
  cntools_theme_private_path "${file}" || return 1
  size="$(wc -c < "${file}" 2>/dev/null)" || return 1
  size="${size//[[:space:]]/}"
  [[ "${size}" =~ ^[0-9]+$ && ${size} -gt 0 && ${size} -le 16384 ]] ||
    return 1
  jq -e --argjson schema "${CNTOOLS_SHORTCUTS_SCHEMA_VERSION}" \
    --argjson max "${CNTOOLS_SHORTCUTS_MAX}" \
    --arg code_pattern "${CNTOOLS_SHORTCUTS_CODE_PATTERN}" \
    --arg target_pattern "${CNTOOLS_SHORTCUTS_TARGET_PATTERN}" '
    type == "object" and keys == ["schemaVersion", "shortcuts"] and
    .schemaVersion == $schema and
    (.shortcuts | type == "array" and length <= $max and
      all(.[]; type == "object" and keys == ["code", "target"] and
        (.code | type == "string" and test($code_pattern)) and
        (.target | type == "string" and length <= 256 and
          test($target_pattern))) and
      ([.[].code] | length == (unique | length)) and
      ([.[].target] | length == (unique | length)))
  ' "${file}" >/dev/null 2>&1
}

# Reads the saved shortcuts, sorted by code. A missing or unreadable file is
# not an error: CNTOOLS_SHORTCUTS_STATE says which it was.
cntools_shortcuts_load() {
  local code=""
  local target=""

  CNTOOLS_SHORTCUTS_CODES=()
  CNTOOLS_SHORTCUTS_TARGETS=()
  if ! cntools_shortcuts_paths; then
    CNTOOLS_SHORTCUTS_STATE="unavailable"
    return 0
  fi
  if [[ ! -e "${CNTOOLS_SHORTCUTS_FILE}" && ! -L "${CNTOOLS_SHORTCUTS_FILE}" ]]; then
    CNTOOLS_SHORTCUTS_STATE="none"
    return 0
  fi
  if ! cntools_shortcuts_file_valid; then
    CNTOOLS_SHORTCUTS_STATE="invalid"
    return 0
  fi
  while IFS=$'\t' read -r code target; do
    [[ -n "${code}" ]] || continue
    CNTOOLS_SHORTCUTS_CODES+=("${code}")
    CNTOOLS_SHORTCUTS_TARGETS+=("${target}")
  done < <(jq -r '.shortcuts | sort_by(.code)[] | [.code, .target] | @tsv' \
    "${CNTOOLS_SHORTCUTS_FILE}" 2>/dev/null)
  CNTOOLS_SHORTCUTS_STATE="ok"
}

cntools_shortcuts_cleanup() {
  local stage="${CNTOOLS_SHORTCUTS_STAGE_FILE:-}"

  if [[ -n "${stage}" &&
        "${stage}" == "${CNTOOLS_SETTINGS_STATE_DIR:-/invalid}/.shortcuts."* &&
        -f "${stage}" && ! -L "${stage}" && -O "${stage}" ]]; then
    rm -f -- "${stage}" 2>/dev/null || true
  fi
  CNTOOLS_SHORTCUTS_STAGE_FILE=""
}

# Writes CNTOOLS_SHORTCUTS_CODES and CNTOOLS_SHORTCUTS_TARGETS. A file this
# session could not read is never overwritten; it has to be set aside first.
cntools_shortcuts_save() {
  local content=""
  local index=0
  local count="${#CNTOOLS_SHORTCUTS_CODES[@]}"

  [[ "${CNTOOLS_SHORTCUTS_STATE}" == none ||
     "${CNTOOLS_SHORTCUTS_STATE}" == ok ]] || return 1
  (( count == ${#CNTOOLS_SHORTCUTS_TARGETS[@]} &&
     count <= CNTOOLS_SHORTCUTS_MAX )) || return 1
  for (( index = 0; index < count; index++ )); do
    [[ "${CNTOOLS_SHORTCUTS_CODES[index]}" =~ ${CNTOOLS_SHORTCUTS_CODE_PATTERN} &&
       "${CNTOOLS_SHORTCUTS_TARGETS[index]}" =~ ${CNTOOLS_SHORTCUTS_TARGET_PATTERN} ]] ||
      return 1
  done
  cntools_shortcuts_paths || return 1
  cntools_settings_state_directory_ready || return 1
  content="$(
    for (( index = 0; index < count; index++ )); do
      printf '%s\t%s\n' "${CNTOOLS_SHORTCUTS_CODES[index]}" \
        "${CNTOOLS_SHORTCUTS_TARGETS[index]}"
    done | jq -R -s --argjson schema "${CNTOOLS_SHORTCUTS_SCHEMA_VERSION}" '
      {schemaVersion: $schema,
       shortcuts: ([split("\n")[] | select(length > 0) | split("\t")
         | {code: .[0], target: .[1]}] | sort_by(.code))}'
  )" || return 1
  cntools_shortcuts_cleanup
  CNTOOLS_SHORTCUTS_STAGE_FILE="$(mktemp \
    "${CNTOOLS_SETTINGS_STATE_DIR}/.shortcuts.XXXXXX")" || return 1
  if ! chmod 0600 "${CNTOOLS_SHORTCUTS_STAGE_FILE}" ||
     ! printf '%s\n' "${content}" > "${CNTOOLS_SHORTCUTS_STAGE_FILE}" ||
     ! mv -f -- "${CNTOOLS_SHORTCUTS_STAGE_FILE}" "${CNTOOLS_SHORTCUTS_FILE}"; then
    cntools_shortcuts_cleanup
    return 1
  fi
  CNTOOLS_SHORTCUTS_STAGE_FILE=""
  cntools_shortcuts_load
  [[ "${CNTOOLS_SHORTCUTS_STATE}" == ok ]]
}

# Saves <code> for <target>. The target loses any code it had, and the code
# moves away from any other target. The file is read again first, so changes
# another CNTools session saved in the meantime are kept.
# Returns 2 for an invalid code or target, 3 when the list is full.
cntools_shortcuts_assign() {
  local code="${1:-}"
  local target="${2:-}"
  local index=0
  local -a codes=()
  local -a targets=()

  [[ "${code}" =~ ${CNTOOLS_SHORTCUTS_CODE_PATTERN} &&
     "${target}" =~ ${CNTOOLS_SHORTCUTS_TARGET_PATTERN} ]] || return 2
  cntools_shortcuts_load
  for (( index = 0; index < ${#CNTOOLS_SHORTCUTS_CODES[@]}; index++ )); do
    if [[ "${CNTOOLS_SHORTCUTS_CODES[index]}" == "${code}" ||
          "${CNTOOLS_SHORTCUTS_TARGETS[index]}" == "${target}" ]]; then
      continue
    fi
    codes+=("${CNTOOLS_SHORTCUTS_CODES[index]}")
    targets+=("${CNTOOLS_SHORTCUTS_TARGETS[index]}")
  done
  (( ${#codes[@]} < CNTOOLS_SHORTCUTS_MAX )) || return 3
  CNTOOLS_SHORTCUTS_CODES=("${codes[@]}" "${code}")
  CNTOOLS_SHORTCUTS_TARGETS=("${targets[@]}" "${target}")
  cntools_shortcuts_save || return 1
  cntools_shortcuts_log SETTINGS "shortcut ${code} saved for ${target}"
}

cntools_shortcuts_remove() {
  local code="${1:-}"
  local index=0
  local -a codes=()
  local -a targets=()

  [[ "${code}" =~ ${CNTOOLS_SHORTCUTS_CODE_PATTERN} ]] || return 2
  cntools_shortcuts_load
  for (( index = 0; index < ${#CNTOOLS_SHORTCUTS_CODES[@]}; index++ )); do
    [[ "${CNTOOLS_SHORTCUTS_CODES[index]}" != "${code}" ]] || continue
    codes+=("${CNTOOLS_SHORTCUTS_CODES[index]}")
    targets+=("${CNTOOLS_SHORTCUTS_TARGETS[index]}")
  done
  CNTOOLS_SHORTCUTS_CODES=("${codes[@]}")
  CNTOOLS_SHORTCUTS_TARGETS=("${targets[@]}")
  cntools_shortcuts_save || return 1
  cntools_shortcuts_log SETTINGS "shortcut ${code} removed"
}

cntools_shortcuts_remove_all() {
  cntools_shortcuts_load
  CNTOOLS_SHORTCUTS_CODES=()
  CNTOOLS_SHORTCUTS_TARGETS=()
  cntools_shortcuts_save || return 1
  cntools_shortcuts_log SETTINGS "all shortcuts removed"
}

# Moves a file CNTools cannot read aside as shortcuts.json.invalid-<time>,
# so the next save starts an empty list without losing the old file.
cntools_shortcuts_set_aside() {
  local stamp=""
  local aside=""

  CNTOOLS_SHORTCUTS_ASIDE_FILE=""
  cntools_shortcuts_paths || return 1
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null)" || stamp=old
  aside="${CNTOOLS_SHORTCUTS_FILE}.invalid-${stamp}"
  [[ ( -e "${CNTOOLS_SHORTCUTS_FILE}" || -L "${CNTOOLS_SHORTCUTS_FILE}" ) &&
     ! -e "${aside}" && ! -L "${aside}" ]] || return 1
  mv -n -- "${CNTOOLS_SHORTCUTS_FILE}" "${aside}" 2>/dev/null || return 1
  [[ ! -e "${CNTOOLS_SHORTCUTS_FILE}" && ! -L "${CNTOOLS_SHORTCUTS_FILE}" ]] ||
    return 1
  CNTOOLS_SHORTCUTS_ASIDE_FILE="${aside}"
  cntools_shortcuts_log WARN "Saved shortcuts could not be read; moved to ${aside}"
  cntools_shortcuts_load
}

# 0 when <target> is in this session's menus. 3 when it exists but is hidden
# (advanced entries need -a), 4 when no such menu or action exists.
cntools_shortcuts_target_status() {
  local target="${1:-}"

  [[ "${target}" =~ ${CNTOOLS_SHORTCUTS_TARGET_PATTERN} ]] || return 4
  [[ -z "${CNTOOLS_MENU_CACHE_ROUTE_BREADCRUMBS[${target}]:-}" ]] || return 0
  if [[ -f "${CNTOOLS_MODULE_ROOT:-/invalid}/${target}/module.json" &&
        ! -L "${CNTOOLS_MODULE_ROOT:-/invalid}/${target}/module.json" ]]; then
    return 3
  fi
  return 4
}

# The menu path of <target>, such as "Pool / Register". A hidden entry's path
# is read from its module files; a removed one is shown by its id.
cntools_shortcuts_target_name_into() {
  local _cstn_output="${1:-}"
  local _cstn_target="${2:-}"
  local _cstn_name=""
  local _cstn_status=0

  [[ "${_cstn_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  cntools_shortcuts_target_status "${_cstn_target}" || _cstn_status=$?
  if (( _cstn_status == 0 )); then
    _cstn_name="${CNTOOLS_MENU_CACHE_ROUTE_BREADCRUMBS[${_cstn_target}]}"
  elif (( _cstn_status == 3 )) &&
       _cstn_name="$(cntools_menu_breadcrumb \
         "${CNTOOLS_MODULE_ROOT}/${_cstn_target}" 2>/dev/null)"; then
    :
  else
    _cstn_name="${_cstn_target}"
  fi
  printf -v "${_cstn_output}" '%s' "${_cstn_name#/ }"
}

# Looks up the saved shortcut <code>: 0 with its target, 1 when no shortcut
# has that code, and 3 or 4 (see cntools_shortcuts_target_status) with a
# target this session doesn't show.
cntools_shortcuts_resolve_into() {
  local _csr_output="${1:-}"
  local _csr_code="${2:-}"
  local _csr_index=0

  [[ "${_csr_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  printf -v "${_csr_output}" '%s' ''
  [[ "${_csr_code}" =~ ${CNTOOLS_SHORTCUTS_CODE_PATTERN} ]] || return 1
  for (( _csr_index = 0; _csr_index < ${#CNTOOLS_SHORTCUTS_CODES[@]}; _csr_index++ )); do
    [[ "${CNTOOLS_SHORTCUTS_CODES[_csr_index]}" == "${_csr_code}" ]] || continue
    printf -v "${_csr_output}" '%s' "${CNTOOLS_SHORTCUTS_TARGETS[_csr_index]}"
    cntools_shortcuts_target_status "${CNTOOLS_SHORTCUTS_TARGETS[_csr_index]}" ||
      return $?
    return 0
  done
  return 1
}

cntools_shortcuts_code_for_into() {
  local _cscf_output="${1:-}"
  local _cscf_target="${2:-}"
  local _cscf_index=0

  [[ "${_cscf_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  printf -v "${_cscf_output}" '%s' ''
  for (( _cscf_index = 0; _cscf_index < ${#CNTOOLS_SHORTCUTS_TARGETS[@]}; _cscf_index++ )); do
    if [[ "${CNTOOLS_SHORTCUTS_TARGETS[_cscf_index]}" == "${_cscf_target}" ]]; then
      printf -v "${_cscf_output}" '%s' "${CNTOOLS_SHORTCUTS_CODES[_cscf_index]}"
      return 0
    fi
  done
  return 1
}

cntools_shortcuts_entries_walk() {
  local menu_id="${1:-}"
  local index=0
  local count=0
  local record=""
  local path="" id="" name="" kind="" label="" description=""
  local shortcut="" order="" enabled="" reason="" route=""

  count="${CNTOOLS_MENU_CACHE_MENU_COUNTS[${menu_id}]:-0}"
  for (( index = 0; index < count; index++ )); do
    record="${CNTOOLS_MENU_CACHE_ITEMS[${menu_id}:${index}]:-}"
    [[ -n "${record}" ]] || continue
    IFS=$'\037' read -r path id name kind label description shortcut order \
      enabled reason <<< "${record}"
    route="${CNTOOLS_MENU_CACHE_ROUTE_BREADCRUMBS[${id}]:-/ ${label}}"
    CNTOOLS_SHORTCUTS_ENTRY_IDS+=("${id}")
    CNTOOLS_SHORTCUTS_ENTRY_KINDS+=("${kind}")
    CNTOOLS_SHORTCUTS_ENTRY_NAMES+=("${route#/ }")
    CNTOOLS_SHORTCUTS_ENTRY_DESCRIPTIONS+=("${description}")
    CNTOOLS_SHORTCUTS_ENTRY_ENABLED+=("${enabled}")
    CNTOOLS_SHORTCUTS_ENTRY_REASONS+=("${reason}")
    if [[ "${kind}" == "menu" ]]; then
      cntools_shortcuts_entries_walk "${id}" || return 1
    fi
  done
}

# Lists every menu and action of the session's menu cache as rows for a
# chooser: marker, menu path, description and any shortcut code. Gum trims
# leading spaces from its input, so no row may start with one.
cntools_shortcuts_entries_collect() {
  local index=0
  local width=20
  local code=""
  local marker=""
  local suffix=""

  CNTOOLS_SHORTCUTS_ENTRY_IDS=()
  CNTOOLS_SHORTCUTS_ENTRY_KINDS=()
  CNTOOLS_SHORTCUTS_ENTRY_NAMES=()
  CNTOOLS_SHORTCUTS_ENTRY_DESCRIPTIONS=()
  CNTOOLS_SHORTCUTS_ENTRY_ENABLED=()
  CNTOOLS_SHORTCUTS_ENTRY_REASONS=()
  CNTOOLS_SHORTCUTS_ENTRY_ROWS=()
  [[ "${CNTOOLS_MENU_CACHE_READY:-N}" == "Y" ]] || return 1
  cntools_shortcuts_entries_walk "${CNTOOLS_MENU_ROOT_ID}" || return 1
  (( ${#CNTOOLS_SHORTCUTS_ENTRY_IDS[@]} > 0 )) || return 1
  for (( index = 0; index < ${#CNTOOLS_SHORTCUTS_ENTRY_NAMES[@]}; index++ )); do
    (( ${#CNTOOLS_SHORTCUTS_ENTRY_NAMES[index]} <= width )) ||
      width="${#CNTOOLS_SHORTCUTS_ENTRY_NAMES[index]}"
  done
  (( width <= 50 )) || width=50
  for (( index = 0; index < ${#CNTOOLS_SHORTCUTS_ENTRY_IDS[@]}; index++ )); do
    cntools_shortcuts_code_for_into code "${CNTOOLS_SHORTCUTS_ENTRY_IDS[index]}" || true
    marker="•"
    suffix=""
    [[ "${CNTOOLS_SHORTCUTS_ENTRY_KINDS[index]}" != "menu" ]] || marker="›"
    if [[ "${CNTOOLS_SHORTCUTS_ENTRY_ENABLED[index]}" != "Y" ]]; then
      marker="×"
      suffix="  [${CNTOOLS_SHORTCUTS_ENTRY_REASONS[index]}]"
    fi
    [[ -z "${code}" ]] || suffix+="  · shortcut ${code}"
    printf -v "CNTOOLS_SHORTCUTS_ENTRY_ROWS[index]" '%s %-*s  %s%s' \
      "${marker}" "${width}" "${CNTOOLS_SHORTCUTS_ENTRY_NAMES[index]}" \
      "${CNTOOLS_SHORTCUTS_ENTRY_DESCRIPTIONS[index]}" "${suffix}"
  done
}

# Picks a menu or action from cntools_shortcuts_entries_collect's rows, with
# <purpose> above the list. With <text>, the list opens filtered by it, and a
# single match is picked without showing the list. Returns as
# cntools_ui_choose does.
cntools_shortcuts_pick_entry_into() {
  local _cspe_output="${1:-}"
  local _cspe_purpose="${2:-}"
  local _cspe_text="${3:-}"
  local _cspe_row=""
  local _cspe_select="N"
  local _cspe_index=0

  [[ "${_cspe_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "${_cspe_purpose}" ]] ||
    return 2
  printf -v "${_cspe_output}" '%s' ''
  (( ${#CNTOOLS_SHORTCUTS_ENTRY_ROWS[@]} > 0 )) || return 2
  [[ -z "${_cspe_text}" ]] || _cspe_select="Y"
  cntools_ui_choose_matching _cspe_row "Filter menus and actions…" \
    "${_cspe_text}" "${_cspe_select}" "${_cspe_purpose}" \
    "${CNTOOLS_SHORTCUTS_ENTRY_ROWS[@]}" || return $?
  for (( _cspe_index = 0; _cspe_index < ${#CNTOOLS_SHORTCUTS_ENTRY_ROWS[@]}; _cspe_index++ )); do
    if [[ "${CNTOOLS_SHORTCUTS_ENTRY_ROWS[_cspe_index]}" == "${_cspe_row}" ]]; then
      printf -v "${_cspe_output}" '%s' "${CNTOOLS_SHORTCUTS_ENTRY_IDS[_cspe_index]}"
      return 0
    fi
  done
  return 2
}

# The saved shortcuts as a table, with a note for a target this session
# doesn't show.
cntools_shortcuts_render_table() {
  local index=0
  local name=""
  local note=""
  local status=0
  local table_width=""

  (( ${#CNTOOLS_SHORTCUTS_CODES[@]} > 0 )) || return 0
  table_width="$(cntools_ui_content_width 120 42)" || return 1
  cntools_ui_render_detail "Shortcuts" || return 1
  {
    printf 'Shortcut\tGoes to\n'
    for (( index = 0; index < ${#CNTOOLS_SHORTCUTS_CODES[@]}; index++ )); do
      status=0
      cntools_shortcuts_target_status "${CNTOOLS_SHORTCUTS_TARGETS[index]}" || status=$?
      cntools_shortcuts_target_name_into name "${CNTOOLS_SHORTCUTS_TARGETS[index]}" || return 1
      case "${status}" in
        0) note="" ;;
        3) note=" · shown only when CNTools starts with -a" ;;
        *) note=" · no longer exists" ;;
      esac
      printf '%s\t%s%s\n' "${CNTOOLS_SHORTCUTS_CODES[index]}" "${name}" "${note}"
    done
  } | cntools_ui_table --keep-header --separator $'\t' \
    --widths "10,$((table_width - 17))"
}

# The Go to screen, opened from the 00 row of every menu. A saved shortcut
# code goes straight to its target; any other text searches every menu and
# action, and Enter alone lists them all. Returns 0 with the chosen entry's
# id, 1 when cancelled, or the status of a failed prompt.
cntools_shortcuts_goto_into() {
  local _csg_output="${1:-}"
  local _csg_text=""
  local _csg_target=""
  local _csg_name=""
  local _csg_level=""
  local _csg_message=""
  local _csg_status=0

  [[ "${_csg_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  printf -v "${_csg_output}" '%s' ''
  while true; do
    cntools_shortcuts_load
    cntools_ui_render_begin "Go to" "/ Go to" || return 1
    if [[ -n "${_csg_message}" ]]; then
      cntools_ui_render_status "${_csg_level}" "${_csg_message}"
      _csg_message=""
    fi
    if [[ "${CNTOOLS_SHORTCUTS_STATE}" == "invalid" ]]; then
      cntools_ui_render_status warn \
        "Saved shortcuts could not be read. Open Settings / Shortcuts to start again."
    elif (( ${#CNTOOLS_SHORTCUTS_CODES[@]} > 0 )); then
      cntools_shortcuts_render_table || return 1
    else
      cntools_ui_render_status info \
        "No shortcuts yet. Add them in Settings / Shortcuts, or type to search."
    fi
    cntools_ui_input _csg_text "Go to" \
      "Shortcut or search text · Enter alone lists everything" || return $?
    _csg_text="${_csg_text,,}"

    _csg_status=0
    cntools_shortcuts_resolve_into _csg_target "${_csg_text}" || _csg_status=$?
    if (( _csg_status == 0 )); then
      printf -v "${_csg_output}" '%s' "${_csg_target}"
      cntools_shortcuts_log MENU "go to ${_csg_target} (shortcut ${_csg_text})"
      return 0
    elif (( _csg_status == 3 || _csg_status == 4 )); then
      cntools_shortcuts_target_name_into _csg_name "${_csg_target}" || return 1
      _csg_level="warn"
      if (( _csg_status == 3 )); then
        _csg_message="Shortcut ${_csg_text} goes to ${_csg_name}, which is shown only when CNTools starts with -a."
      else
        _csg_message="Shortcut ${_csg_text} goes to ${_csg_name}, which no longer exists. Change or remove it in Settings / Shortcuts."
      fi
      continue
    fi

    cntools_shortcuts_entries_collect || return 1
    cntools_ui_render_begin "Go to" "/ Go to" || return 1
    _csg_status=0
    cntools_shortcuts_pick_entry_into _csg_target "Menu or action to open" \
      "${_csg_text}" || _csg_status=$?
    # Escape returns to the Go to prompt.
    (( _csg_status != 1 )) || continue
    (( _csg_status == 0 )) || return "${_csg_status}"
    printf -v "${_csg_output}" '%s' "${_csg_target}"
    cntools_shortcuts_log MENU "go to ${_csg_target}"
    return 0
  done
}
