#!/usr/bin/env bash
# CNTools filesystem-backed menu discovery and navigation. Functions only.
# Menu identity is consumed dynamically by the separately sourced logger.
# shellcheck disable=SC2034

cntools_menu_fail() {
  CNTOOLS_MENU_ERROR="${1:-menu validation failed}"
  return 1
}

cntools_menu_directory_within_root() {
  local directory="${1:-}"
  local root="${CNTOOLS_MODULE_ROOT:-}"
  local physical_directory=""
  local physical_root=""

  [[ -n "${directory}" && -n "${root}" &&
     -d "${directory}" && ! -L "${directory}" &&
     -d "${root}" && ! -L "${root}" ]] || return 1
  physical_directory="$(cd -- "${directory}" && pwd -P)" || return 1
  physical_root="$(cd -- "${root}" && pwd -P)" || return 1
  [[ "${physical_directory}" == "${physical_root}" ||
     "${physical_directory}" == "${physical_root}/"* ]]
}

cntools_menu_validate_metadata() {
  local module_directory="${1:-}"
  local context="${2:-child}"
  local metadata="${module_directory}/module.json"
  local kind=""
  local child=""
  local bash_bin="${CNTOOLS_VALIDATION_BASH:-bash}"

  CNTOOLS_MENU_ERROR=""
  [[ "${context}" == "root" || "${context}" == "child" ]] ||
    cntools_menu_fail "Unknown metadata validation context: ${context}" || return 1
  [[ -d "${module_directory}" && ! -L "${module_directory}" ]] ||
    cntools_menu_fail "Module directory is missing or is a symbolic link: ${module_directory}" || return 1
  if [[ "${context}" == "child" ]]; then
    [[ "$(basename "${module_directory}")" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
      cntools_menu_fail "Module directory names must use lowercase kebab-case: ${module_directory}" || return 1
  fi
  [[ -f "${metadata}" && ! -L "${metadata}" && -s "${metadata}" ]] ||
    cntools_menu_fail "Module metadata is missing or unsafe: ${metadata}" || return 1

  kind="$(jq -er '.kind | select(type == "string")' "${metadata}" 2>/dev/null)" ||
    cntools_menu_fail "Module metadata has no valid kind: ${metadata}" || return 1
  case "${context}:${kind}" in
    root:menu)
      jq -e '
        def line: type == "string" and length > 0 and
          (test("[[:cntrl:]]") | not);
        type == "object" and
        keys == ["description", "kind", "label"] and
        .kind == "menu" and (.label | line) and (.description | line)
      ' "${metadata}" >/dev/null 2>&1 ||
        cntools_menu_fail "Root module metadata is invalid: ${metadata}" || return 1
      ;;
    child:menu)
      jq -e '
        def line: type == "string" and length > 0 and
          (test("[[:cntrl:]]") | not);
        type == "object" and
        has("kind") and has("label") and has("description") and
        has("shortcut") and has("order") and
        ((keys - ["advanced", "description", "kind", "label", "order", "shortcut"]) | length == 0) and
        .kind == "menu" and (.label | line) and (.description | line) and
        (.shortcut | type == "string" and test("^[a-z0-9]$")) and
        (.order | type == "number" and floor == . and
          . >= 0 and . <= 2147483647) and
        ((has("advanced") | not) or (.advanced | type == "boolean"))
      ' "${metadata}" >/dev/null 2>&1 ||
        cntools_menu_fail "Menu metadata is invalid: ${metadata}" || return 1
      ;;
    child:action)
      jq -e '
        def line: type == "string" and length > 0 and
          (test("[[:cntrl:]]") | not);
        def safe_lib:
          type == "string" and test("^[a-z0-9][a-z0-9._/-]*[.]sh$") and
          (contains("//") | not) and
          (split("/") | all(. != "." and . != ".." and length > 0));
        type == "object" and
        has("kind") and has("label") and has("description") and
        has("shortcut") and has("order") and has("modes") and
        ((keys - ["description", "kind", "label", "libs", "modes", "order", "shortcut"]) | length == 0) and
        .kind == "action" and (.label | line) and (.description | line) and
        (.shortcut | type == "string" and test("^[a-z0-9]$")) and
        (.order | type == "number" and floor == . and
          . >= 0 and . <= 2147483647) and
        (.modes | type == "array" and length > 0 and
          length == (unique | length) and
          all(. == "local" or . == "light" or . == "offline")) and
        ((has("libs") | not) or
          (.libs | type == "array" and length == (unique | length) and all(safe_lib)))
      ' "${metadata}" >/dev/null 2>&1 ||
        cntools_menu_fail "Action metadata is invalid: ${metadata}" || return 1
      ;;
    *)
      cntools_menu_fail "Invalid module kind '${kind}' for ${context}: ${metadata}"
      return 1
      ;;
  esac

  if [[ "${kind}" == "menu" ]]; then
    [[ ! -e "${module_directory}/action.sh" &&
       ! -L "${module_directory}/action.sh" ]] ||
      cntools_menu_fail "Menu modules must not contain action.sh: ${module_directory}" || return 1
  else
    [[ -f "${module_directory}/action.sh" &&
       ! -L "${module_directory}/action.sh" &&
       -s "${module_directory}/action.sh" ]] ||
      cntools_menu_fail "Action entrypoint is missing or unsafe: ${module_directory}/action.sh" || return 1
    "${bash_bin}" -n "${module_directory}/action.sh" >/dev/null 2>&1 ||
      cntools_menu_fail "Action entrypoint failed shell validation: ${module_directory}/action.sh" || return 1
    for child in \
      "${module_directory}"/* \
      "${module_directory}"/.[!.]* \
      "${module_directory}"/..?*; do
      [[ -e "${child}" || -L "${child}" ]] || continue
      if [[ -d "${child}" ]]; then
        cntools_menu_fail "Action modules must not contain child directories: ${module_directory}"
        return 1
      fi
    done
  fi
}

cntools_menu_library_path() {
  local relative_path="${1:-}"
  local current="${CNTOOLS_LIB_DIR:-}"
  local component=""
  local -a components=()

  [[ -n "${relative_path}" && "${relative_path}" != /* &&
     "${relative_path}" =~ ^[a-z0-9][a-z0-9._/-]*[.]sh$ &&
     "${relative_path}" != *//* ]] || return 1
  [[ -d "${current}" && ! -L "${current}" ]] || return 1
  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." && "${component}" != ".." ]] || return 1
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || return 1
  done
  [[ -f "${current}" && -s "${current}" ]] || return 1
  printf '%s\n' "${current}"
}

cntools_menu_validate_action_libraries() {
  local module_directory="${1:-}"
  local relative_path=""
  local library_path=""
  local library_list=""
  local bash_bin="${CNTOOLS_VALIDATION_BASH:-bash}"

  if ! library_list="$(jq -r '.libs[]?' \
    "${module_directory}/module.json")"; then
    cntools_menu_fail "Could not read declared libraries: ${module_directory}"
    return 1
  fi
  while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    library_path="$(cntools_menu_library_path "${relative_path}")" ||
      cntools_menu_fail "Declared library is missing or unsafe: ${relative_path}" || return 1
    "${bash_bin}" -n "${library_path}" >/dev/null 2>&1 ||
      cntools_menu_fail "Declared library failed shell validation: ${relative_path}" || return 1
  done <<< "${library_list}"
}

cntools_menu_insert_item() {
  local path="$1" id="$2" name="$3" kind="$4" label="$5"
  local description="$6" shortcut="$7" order="$8" enabled="$9"
  local reason="${10}" insert_at=0 index=0 count="${#CNTOOLS_MENU_PATHS[@]}"

  insert_at="${count}"
  for (( index = 0; index < count; index++ )); do
    if (( order < CNTOOLS_MENU_ORDERS[index] )) ||
       { (( order == CNTOOLS_MENU_ORDERS[index] )) &&
         [[ "${name}" < "${CNTOOLS_MENU_NAMES[index]}" ]]; }; then
      insert_at="${index}"
      break
    fi
  done
  for (( index = count; index > insert_at; index-- )); do
    CNTOOLS_MENU_PATHS[index]="${CNTOOLS_MENU_PATHS[index-1]}"
    CNTOOLS_MENU_IDS[index]="${CNTOOLS_MENU_IDS[index-1]}"
    CNTOOLS_MENU_NAMES[index]="${CNTOOLS_MENU_NAMES[index-1]}"
    CNTOOLS_MENU_KINDS[index]="${CNTOOLS_MENU_KINDS[index-1]}"
    CNTOOLS_MENU_LABELS[index]="${CNTOOLS_MENU_LABELS[index-1]}"
    CNTOOLS_MENU_DESCRIPTIONS[index]="${CNTOOLS_MENU_DESCRIPTIONS[index-1]}"
    CNTOOLS_MENU_SHORTCUTS[index]="${CNTOOLS_MENU_SHORTCUTS[index-1]}"
    CNTOOLS_MENU_ORDERS[index]="${CNTOOLS_MENU_ORDERS[index-1]}"
    CNTOOLS_MENU_ENABLED[index]="${CNTOOLS_MENU_ENABLED[index-1]}"
    CNTOOLS_MENU_DISABLED_REASONS[index]="${CNTOOLS_MENU_DISABLED_REASONS[index-1]}"
  done
  CNTOOLS_MENU_PATHS[insert_at]="${path}"
  CNTOOLS_MENU_IDS[insert_at]="${id}"
  CNTOOLS_MENU_NAMES[insert_at]="${name}"
  CNTOOLS_MENU_KINDS[insert_at]="${kind}"
  CNTOOLS_MENU_LABELS[insert_at]="${label}"
  CNTOOLS_MENU_DESCRIPTIONS[insert_at]="${description}"
  CNTOOLS_MENU_SHORTCUTS[insert_at]="${shortcut}"
  CNTOOLS_MENU_ORDERS[insert_at]="${order}"
  CNTOOLS_MENU_ENABLED[insert_at]="${enabled}"
  CNTOOLS_MENU_DISABLED_REASONS[insert_at]="${reason}"
}

cntools_menu_open() {
  local menu_directory="${1:-}"
  local root_directory=""
  local physical_menu=""
  local context="child"
  local reserved='|h|'
  local seen='|'
  local child="" metadata="" kind="" label="" description=""
  local shortcut="" order=0 name="" id="" enabled="Y" reason=""
  local advanced="false"

  CNTOOLS_MENU_PATHS=()
  CNTOOLS_MENU_IDS=()
  CNTOOLS_MENU_NAMES=()
  CNTOOLS_MENU_KINDS=()
  CNTOOLS_MENU_LABELS=()
  CNTOOLS_MENU_DESCRIPTIONS=()
  CNTOOLS_MENU_SHORTCUTS=()
  CNTOOLS_MENU_ORDERS=()
  CNTOOLS_MENU_ENABLED=()
  CNTOOLS_MENU_DISABLED_REASONS=()

  cntools_menu_directory_within_root "${menu_directory}" ||
    cntools_menu_fail "Menu is outside the module root or unsafe: ${menu_directory}" || return 1
  root_directory="$(cd -- "${CNTOOLS_MODULE_ROOT}" && pwd -P)" || return 1
  physical_menu="$(cd -- "${menu_directory}" && pwd -P)" || return 1
  if [[ "${physical_menu}" == "${root_directory}" ]]; then
    context="root"
    reserved='|r|q|'
  fi
  cntools_menu_validate_metadata "${physical_menu}" "${context}" || return 1
  [[ "$(jq -r '.kind' "${physical_menu}/module.json")" == "menu" ]] ||
    cntools_menu_fail "Cannot open an action as a menu: ${physical_menu}" || return 1

  for child in \
    "${physical_menu}"/* \
    "${physical_menu}"/.[!.]* \
    "${physical_menu}"/..?*; do
    [[ -e "${child}" || -L "${child}" ]] || continue
    [[ -d "${child}" || -L "${child}" ]] || continue
    cntools_menu_validate_metadata "${child}" child || return 1
    metadata="${child}/module.json"
    shortcut="$(jq -r '.shortcut' "${metadata}")" || return 1
    [[ "${reserved}" != *"|${shortcut}|"* ]] ||
      cntools_menu_fail "Shortcut '${shortcut}' is reserved in ${physical_menu}" || return 1
    [[ "${seen}" != *"|${shortcut}|"* ]] ||
      cntools_menu_fail "Duplicate shortcut '${shortcut}' in ${physical_menu}" || return 1
    seen+="${shortcut}|"

    kind="$(jq -r '.kind' "${metadata}")"
    label="$(jq -r '.label' "${metadata}")"
    description="$(jq -r '.description' "${metadata}")"
    order="$(jq -r '.order' "${metadata}")"
    name="$(basename "${child}")"
    id="${child#"${root_directory}"/}"
    enabled="Y"
    reason=""
    if [[ "${kind}" == "menu" ]]; then
      advanced="$(jq -r '.advanced // false' "${metadata}")"
      if [[ "${advanced}" == "true" && "${CNTOOLS_ADVANCED:-N}" != "Y" ]]; then
        continue
      fi
    elif ! jq -e --arg mode "${CNTOOLS_MODE:-local}" \
      '.modes | index($mode) != null' "${metadata}" >/dev/null; then
      enabled="N"
      reason="Not available in ${CNTOOLS_MODE:-current} mode"
    fi
    cntools_menu_insert_item \
      "${child}" "${id}" "${name}" "${kind}" "${label}" \
      "${description}" "${shortcut}" "${order}" "${enabled}" "${reason}"
  done
}

cntools_menu_validate_tree_directory() {
  local directory="${1:-}"
  local context="${2:-child}"
  local child=""
  local kind=""

  cntools_menu_validate_metadata "${directory}" "${context}" || return 1
  kind="$(jq -r '.kind' "${directory}/module.json")" || return 1
  if [[ "${kind}" == "action" ]]; then
    cntools_menu_validate_action_libraries "${directory}" || return $?
    return 0
  fi
  cntools_menu_open "${directory}" || return 1
  for child in \
    "${directory}"/* \
    "${directory}"/.[!.]* \
    "${directory}"/..?*; do
    [[ -e "${child}" || -L "${child}" ]] || continue
    [[ -d "${child}" || -L "${child}" ]] || continue
    cntools_menu_validate_tree_directory "${child}" child || return 1
  done
}

cntools_menu_validate_tree() {
  local saved_advanced="${CNTOOLS_ADVANCED:-N}"
  local status=0
  CNTOOLS_ADVANCED="Y"
  cntools_menu_validate_tree_directory "${CNTOOLS_MODULE_ROOT}" root || status=$?
  CNTOOLS_ADVANCED="${saved_advanced}"
  return "${status}"
}

cntools_menu_breadcrumb() {
  local directory="${1:-${CNTOOLS_MODULE_ROOT:-}}"
  local root=""
  local relative=""
  local current=""
  local component=""
  local breadcrumb=""
  local label=""
  local -a components=()

  root="$(cd -- "${CNTOOLS_MODULE_ROOT}" && pwd -P)" || return 1
  directory="$(cd -- "${directory}" && pwd -P)" || return 1
  breadcrumb="$(jq -r '.label' "${root}/module.json")" || return 1
  [[ "${directory}" != "${root}" ]] || {
    printf '%s\n' "${breadcrumb}"
    return 0
  }
  relative="${directory#"${root}"/}"
  current="${root}"
  IFS='/' read -r -a components <<< "${relative}"
  for component in "${components[@]}"; do
    current="${current}/${component}"
    label="$(jq -r '.label' "${current}/module.json")" || return 1
    breadcrumb+=" / ${label}"
  done
  printf '%s\n' "${breadcrumb}"
}

cntools_menu_run() {
  local -a menu_stack=("${CNTOOLS_MODULE_ROOT}")
  local current="" context="" label="" breadcrumb="" key=""
  local status_level="" status_message="" selected=0 count=0 index=0
  local action_status=0

  while :; do
    current="${menu_stack[${#menu_stack[@]}-1]}"
    context="N"
    (( ${#menu_stack[@]} > 1 )) && context="Y"
    if ! cntools_menu_open "${current}"; then
      cntools_log ERROR "${CNTOOLS_MENU_ERROR}" || true
      printf 'CNTools: %s\n' "${CNTOOLS_MENU_ERROR}" >&2
      return 1
    fi
    count="${#CNTOOLS_MENU_PATHS[@]}"
    (( count > 0 )) || selected=0
    (( selected < count )) || selected=$((count - 1))
    (( selected >= 0 )) || selected=0
    label="$(jq -r '.label' "${current}/module.json")" || return 1
    breadcrumb="$(cntools_menu_breadcrumb "${current}")" || return 1
    CNTOOLS_MENU_ID="${current#"${CNTOOLS_MODULE_ROOT}"/}"
    [[ "${current}" != "${CNTOOLS_MODULE_ROOT}" ]] || CNTOOLS_MENU_ID="root"
    cntools_update_state_load || true

    cntools_ui_render_begin "${label}" "${breadcrumb}"
    if [[ "${CNTOOLS_MENU_ID}" == "root" ]]; then
      cntools_update_render_banner
    elif [[ "${CNTOOLS_MENU_ID}" == "update" ]]; then
      cntools_update_render_summary
    fi
    if (( count == 0 )); then
      cntools_ui_render_empty
    else
      for (( index = 0; index < count; index++ )); do
        if (( index == selected )); then
          cntools_ui_render_row Y "${CNTOOLS_MENU_ENABLED[index]}" \
            "${CNTOOLS_MENU_SHORTCUTS[index]}" "${CNTOOLS_MENU_LABELS[index]}" \
            "${CNTOOLS_MENU_DESCRIPTIONS[index]}"
        else
          cntools_ui_render_row N "${CNTOOLS_MENU_ENABLED[index]}" \
            "${CNTOOLS_MENU_SHORTCUTS[index]}" "${CNTOOLS_MENU_LABELS[index]}" \
            "${CNTOOLS_MENU_DESCRIPTIONS[index]}"
        fi
      done
    fi
    cntools_ui_render_status "${status_level}" "${status_message}"
    cntools_ui_render_footer "${context}"
    status_level=""
    status_message=""

    cntools_ui_read_key key || key="quit"
    case "${key}" in
      up)
        if (( count > 0 )); then
          selected=$(( (selected + count - 1) % count ))
        fi
        continue
        ;;
      down)
        if (( count > 0 )); then
          selected=$(( (selected + 1) % count ))
        fi
        continue
        ;;
      quit)
        cntools_log MENU "quit (input closed)" || true
        return 0
        ;;
      q)
        if [[ "${context}" == "N" ]]; then
          cntools_log MENU "quit" || true
          return 0
        fi
        ;;
      r)
        if [[ "${context}" == "N" ]]; then
          cntools_log MENU "refresh" || true
          status_level="success"
          status_message="Menu refreshed"
          continue
        fi
        ;;
      h)
        if [[ "${context}" == "Y" ]]; then
          menu_stack=("${CNTOOLS_MODULE_ROOT}")
          selected=0
          cntools_log MENU "home" || true
          continue
        fi
        ;;
      escape)
        if [[ "${context}" == "Y" ]]; then
          unset "menu_stack[$((${#menu_stack[@]} - 1))]"
          selected=0
          cntools_log MENU "back" || true
        fi
        continue
        ;;
      enter) ;;
      *) ;;
    esac

    if [[ "${key}" != "enter" ]]; then
      for (( index = 0; index < count; index++ )); do
        if [[ "${CNTOOLS_MENU_SHORTCUTS[index]}" == "${key}" ]]; then
          selected="${index}"
          key="enter"
          break
        fi
      done
      [[ "${key}" == "enter" ]] || continue
    fi

    (( count > 0 )) || continue
    if [[ "${CNTOOLS_MENU_KINDS[selected]}" == "menu" ]]; then
      cntools_log MENU "selected ${CNTOOLS_MENU_IDS[selected]}" || true
      menu_stack+=("${CNTOOLS_MENU_PATHS[selected]}")
      selected=0
      continue
    fi
    if [[ "${CNTOOLS_MENU_ENABLED[selected]}" != "Y" ]]; then
      status_level="warn"
      status_message="${CNTOOLS_MENU_DISABLED_REASONS[selected]}"
      cntools_log ACTION \
        "blocked ${CNTOOLS_MENU_IDS[selected]}: ${CNTOOLS_MENU_DISABLED_REASONS[selected]}" || true
      continue
    fi

    cntools_ui_restore_terminal
    if cntools_action_run "${CNTOOLS_MENU_PATHS[selected]}"; then
      action_status=0
    else
      action_status=$?
    fi
    cntools_ui_restore_terminal
    if cntools_startup_deployment_was_started; then
      cntools_log SESSION \
        "Guild Deploy completed with status ${action_status}; closing the current CNTools process" || true
      return "${action_status}"
    fi
    if [[ ${action_status} -eq 0 ]]; then
      status_level="success"
      status_message="Returned from ${CNTOOLS_MENU_LABELS[selected]}"
    else
      status_level="error"
      status_message="${CNTOOLS_MENU_LABELS[selected]} failed (status ${action_status})"
      cntools_log ERROR \
        "action ${CNTOOLS_MENU_IDS[selected]} failed with status ${action_status}" || true
    fi
  done
}
