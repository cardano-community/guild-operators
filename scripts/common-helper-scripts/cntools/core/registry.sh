#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2034,SC2178
# Strict discovery, validation, and deterministic shadow-menu serialization for
# the on-disk CNTools module registry. Sourcing this file defines functions only.

_cntools_registry_tool_path() {
  local tool="${1:-}"
  local output_name="${2:-}"
  local tool_kind="" tool_path=""

  [[ "${tool}" =~ ^[a-z][a-z0-9-]*$ &&
     "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  tool_kind="$(builtin type -t "${tool}" 2>/dev/null || true)"
  [[ "${tool_kind}" != "alias" && "${tool_kind}" != "function" ]] || return 2
  tool_path="$(builtin type -P "${tool}" 2>/dev/null || true)"
  [[ "${tool_path}" == /* && -f "${tool_path}" && -x "${tool_path}" ]] || return 2
  builtin printf -v "${output_name}" '%s' "${tool_path}"
}

_cntools_registry_path_has_no_symlinks() {
  local target="${1:-}"
  local current="" component="" normalized=""
  local -a components=()

  [[ "${target}" == /* && "${target}" != "/" ]] || return 1
  IFS='/' builtin read -r -a components <<< "${target}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    [[ "${component}" != "." && "${component}" != ".." ]] || return 1
    normalized="${normalized}/${component}"
  done
  [[ -n "${normalized}" ]] || return 1
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || return 1
    if [[ -e "${current}" && "${current}" != "${normalized}" ]]; then
      [[ -d "${current}" ]] || return 1
    fi
  done
}

# Purpose: validate one menu or action metadata document.
# Parameters: module.json path.
# Result: no output.
# Status: 0 valid, 1 unsafe/malformed, 2 jq unavailable or shadowed.
# Runtime context/side effects: reads metadata only; no writes.
# External commands: jq by resolved absolute path. Metadata is never evaluated.
cntools_registry_validate_metadata() {
  local metadata_file="${1:-}"
  local cmp_path="" jq_path=""

  _cntools_registry_tool_path jq jq_path || return 2
  _cntools_registry_tool_path cmp cmp_path || return 2
  [[ "${metadata_file}" == /* && -f "${metadata_file}" &&
     ! -L "${metadata_file}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${metadata_file}" || return 1
  # The canonical byte form is part of schema v2. Besides making metadata
  # reproducible, comparing the original bytes with jq's parsed rendering
  # rejects duplicate object keys before jq's last-key semantics can hide them.
  "${cmp_path}" -s -- "${metadata_file}" <(
    "${jq_path}" -S . "${metadata_file}" 2>/dev/null
  ) || return 1
  "${jq_path}" -e '
    def identifier:
      type == "string" and test("^[a-z][a-z0-9.-]{0,127}$");
    def stable_id:
      type == "string" and
      test("^(root|[a-z][a-z0-9-]*(\\.[a-z][a-z0-9-]*)*)$") and
      length <= 128;
    def ordered_modes:
      . == ["local"] or . == ["light"] or . == ["offline"] or
      . == ["local", "light"] or . == ["local", "offline"] or
      . == ["light", "offline"] or
      . == ["local", "light", "offline"];
    def features:
      type == "array" and . == sort and length == (unique | length) and
      all(.[]; . == "advanced" or . == "blocklog");
    def capabilities:
      type == "array" and . == sort and length == (unique | length) and
      all(.[];
        . == "forging" or . == "local-cli" or . == "metrics" or . == "n2c");
    def requirements:
      type == "object" and
      keys == ["features", "modes", "nodeCapabilities"] and
      (.modes | type == "array" and ordered_modes) and
      (.features | features) and
      (.nodeCapabilities | capabilities);
    def display_text($maximum):
      type == "string" and length > 0 and length <= $maximum and
      (test("[\\x{0000}-\\x{001F}\\x{007F}-\\x{009F}\\x{202A}-\\x{202E}\\x{2066}-\\x{2069}]") | not);
    def common:
      .schemaVersion == 2 and
      (.id | stable_id) and
      (.label | display_text(80)) and
      (.description | display_text(240)) and
      (.visibility | requirements);
    type == "object" and common and
    if .kind == "menu" then
      (.controlPolicy == "root" or .controlPolicy == "home" or
       .controlPolicy == "back-home" or .controlPolicy == "escape-root") and
      if .id == "root" then
        keys == ["controlPolicy", "description", "id", "kind", "label",
          "schemaVersion", "visibility"] and
        .controlPolicy == "root"
      else
        keys == ["controlPolicy", "description", "id", "kind", "label",
          "order", "schemaVersion", "shortcut", "visibility"] and
        .controlPolicy != "root" and
        (.order | type == "number" and floor == . and . >= 0 and . <= 9999 and
          (tostring | test("^(0|[1-9][0-9]{0,3})$"))) and
        (.shortcut | type == "string" and test("^[a-z0-9]$"))
      end
    elif .kind == "action" then
      . as $module |
      keys == ["description", "executionRequirements", "id", "kind", "label",
        "order", "runtime", "schemaVersion", "shortcut", "visibility"] and
      .id != "root" and
      (.order | type == "number" and floor == . and . >= 0 and . <= 9999 and
        (tostring | test("^(0|[1-9][0-9]{0,3})$"))) and
      (.shortcut | type == "string" and test("^[a-z0-9]$")) and
      (.executionRequirements | requirements) and
      all($module.executionRequirements.modes[];
        . as $mode | $module.visibility.modes | index($mode) != null) and
      all($module.visibility.features[];
        . as $feature |
        $module.executionRequirements.features | index($feature) != null) and
      all($module.visibility.nodeCapabilities[];
        . as $capability |
        $module.executionRequirements.nodeCapabilities | index($capability) != null) and
      (.runtime | type == "object" and
        keys == ["apiVersion", "libraries"] and
        .apiVersion == 1 and
        (.libraries | type == "array" and . == sort and
          length == (unique | length) and all(.[]; identifier)))
    else
      false
    end
  ' "${metadata_file}" >/dev/null 2>&1
}

# Purpose: validate the library ID/path/dependency graph as data.
# Parameters: library manifest JSON path.
# Result: no output.
# Status: 0 valid and acyclic, 1 invalid, 2 jq unavailable or shadowed.
# Runtime context/side effects: reads the manifest only; no writes or sourcing.
cntools_registry_validate_library_manifest() {
  local manifest_file="${1:-}"
  local jq_path=""

  _cntools_registry_tool_path jq jq_path || return 2
  [[ "${manifest_file}" == /* && -f "${manifest_file}" &&
     ! -L "${manifest_file}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${manifest_file}" || return 1
  "${jq_path}" -e '
    def identifier:
      type == "string" and test("^[a-z][a-z0-9.-]{0,127}$");
    def visit($libraries; $id; $stack):
      if ($stack | index($id)) != null then false
      else
        ($libraries[] | select(.id == $id)) as $library |
        all($library.dependencies[]; visit($libraries; .; $stack + [$id]))
      end;
    type == "object" and
    keys == ["libraries", "runtimeApiVersion", "schemaVersion"] and
    .schemaVersion == 1 and .runtimeApiVersion == 1 and
    (.libraries | type == "array" and . == sort_by(.id)) and
    all(.libraries[];
      type == "object" and
      keys == ["apiVersion", "dependencies", "id", "path"] and
      .apiVersion == 1 and
      (.id | identifier) and
      (.path | type == "string" and
        test("^libs/[a-z][a-z0-9._/-]*\\.sh$") and
        (contains("//") | not) and
        (split("/") | all(. != "" and . != "." and . != ".."))) and
      (.dependencies | type == "array" and . == sort and
        length == (unique | length) and all(.[]; identifier))) and
    ((.libraries | map(.id) | length) ==
      (.libraries | map(.id) | unique | length)) and
    ((.libraries | map(.path) | length) ==
      (.libraries | map(.path) | unique | length)) and
    (.libraries as $libraries |
      ($libraries | map(.id)) as $ids |
      all($libraries[].dependencies[];
        . as $dependency | $ids | index($dependency) != null) and
      all($libraries[].id; . as $id | visit($libraries; $id; [])))
  ' "${manifest_file}" >/dev/null 2>&1
}

# Purpose: return the deterministic dependency-first library load order.
# Parameters: library manifest, caller-declared indexed-array name.
# Result: fills the output array with library IDs.
# Status: 0 success, 1 invalid graph, 2 caller/tool error.
cntools_registry_library_load_order() {
  local manifest_file="${1:-}"
  local output_name="${2:-}"
  local declaration="" jq_path=""
  local -a ordered=()

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  declaration="$(builtin declare -p "${output_name}" 2>/dev/null)" || return 2
  [[ "${declaration}" == 'declare -a '* ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=()
  cntools_registry_validate_library_manifest "${manifest_file}" || return $?
  _cntools_registry_tool_path jq jq_path || return 2
  builtin mapfile -t ordered < <("${jq_path}" -er '
    def visit($by_id; $id; $state):
      if ($state.done | index($id)) != null then $state
      else
        (reduce $by_id[$id].dependencies[] as $dependency
          ($state; visit($by_id; $dependency; .))) |
        .done += [$id] | .order += [$id]
      end;
    (.libraries | map({key: .id, value: .}) | from_entries) as $by_id |
    reduce (.libraries[].id) as $id
      ({done: [], order: []}; visit($by_id; $id; .)) |
    .order[]
  ' "${manifest_file}")
  [[ ${#ordered[@]} -eq $("${jq_path}" -er '.libraries | length' "${manifest_file}") ]] ||
    return 1
  output_ref=("${ordered[@]}")
}

_cntools_registry_walk() {
  local directory="${1:-}"
  local output_name="${2:-}"
  local metadata="${directory}/module.json"
  local kind="" entry="" entry_name="" line=""
  local action_found="N" entrypoint_count=0
  local child="" child_id="" child_order="" row=""
  local jq_path="" sort_path="" bash_path=""
  local entrypoint_pattern='^[[:space:]]*cntools_action_main[[:space:]]*\(\)[[:space:]]*\{'
  local -a child_directories=() sorted_rows=()

  local -n modules_ref="${output_name}"
  [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${directory}" || return 1
  cntools_registry_validate_metadata "${metadata}" || return $?
  _cntools_registry_tool_path jq jq_path || return 2
  kind="$("${jq_path}" -er '.kind' "${metadata}" 2>/dev/null)" || return 1
  modules_ref+=("${directory}")

  for entry in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    entry_name="${entry##*/}"
    [[ "${entry_name}" != "module.json" ]] || continue
    [[ ! -L "${entry}" ]] || return 1
    if [[ -d "${entry}" ]]; then
      [[ "${entry_name}" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
      child_directories+=("${entry}")
    elif [[ -f "${entry}" && "${entry_name}" == "action.sh" ]]; then
      action_found="Y"
    else
      return 1
    fi
  done

  if [[ "${kind}" == "menu" ]]; then
    [[ "${action_found}" == "N" ]] || return 1
    _cntools_registry_tool_path sort sort_path || return 2
    for child in "${child_directories[@]}"; do
      cntools_registry_validate_metadata "${child}/module.json" || return $?
      IFS=$'\t' builtin read -r child_order child_id < <(
        "${jq_path}" -er '[.order, .id] | @tsv' "${child}/module.json"
      ) || return 1
      builtin printf -v row '%04d\t%s\t%s' \
        "${child_order}" "${child_id}" "${child}" || return 1
      sorted_rows+=("${row}")
    done
    if (( ${#sorted_rows[@]} > 0 )); then
      builtin mapfile -t sorted_rows < <(
        builtin printf '%s\n' "${sorted_rows[@]}" |
          LC_ALL=C "${sort_path}" -t $'\t' -k1,1n -k2,2
      )
      (( ${#sorted_rows[@]} == ${#child_directories[@]} )) || return 1
    fi
    for row in "${sorted_rows[@]}"; do
      IFS=$'\t' builtin read -r child_order child_id child <<< "${row}"
      [[ -n "${child}" ]] || return 1
      _cntools_registry_walk "${child}" "${output_name}" || return $?
    done
  else
    [[ "${action_found}" == "Y" && ${#child_directories[@]} -eq 0 ]] || return 1
    [[ -f "${directory}/action.sh" && ! -L "${directory}/action.sh" ]] || return 1
    _cntools_registry_path_has_no_symlinks "${directory}/action.sh" || return 1
    _cntools_registry_tool_path bash bash_path || return 2
    "${bash_path}" -n "${directory}/action.sh" >/dev/null 2>&1 || return 1
    while IFS= builtin read -r line || [[ -n "${line}" ]]; do
      if [[ "${line}" =~ ${entrypoint_pattern} ]]; then
        entrypoint_count=$((entrypoint_count + 1))
      fi
    done < "${directory}/action.sh"
    (( entrypoint_count == 1 )) || return 1
  fi
}

# Purpose: discover and structurally validate every module below root.
# Parameters: modules directory, caller-declared indexed-array name.
# Result: module-directory paths in deterministic lexical path order.
# Status: 0 valid tree, 1 invalid tree, 2 caller/tool error.
cntools_registry_collect() {
  local modules_root="${1:-}"
  local output_name="${2:-}"
  local declaration="" entry="" entry_name=""
  local sort_path=""
  local -a discovered=()

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  declaration="$(builtin declare -p "${output_name}" 2>/dev/null)" || return 2
  [[ "${declaration}" == 'declare -a '* ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=()
  [[ "${modules_root}" == /* && -d "${modules_root}" && ! -L "${modules_root}" ]] ||
    return 1
  _cntools_registry_path_has_no_symlinks "${modules_root}" || return 1

  for entry in "${modules_root}"/* "${modules_root}"/.[!.]* \
    "${modules_root}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    entry_name="${entry##*/}"
    [[ "${entry_name}" == "root" && -d "${entry}" && ! -L "${entry}" ]] ||
      return 1
  done
  _cntools_registry_walk "${modules_root}/root" discovered || return $?
  _cntools_registry_tool_path sort sort_path || return 2
  builtin mapfile -t discovered < <(
    builtin printf '%s\n' "${discovered[@]}" | LC_ALL=C "${sort_path}"
  )
  output_ref=("${discovered[@]}")
}

_cntools_registry_collect_preorder() {
  local modules_root="${1:-}"
  local output_name="${2:-}"
  local declaration="" entry="" entry_name=""
  local -a discovered=()

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  declaration="$(builtin declare -p "${output_name}" 2>/dev/null)" || return 2
  [[ "${declaration}" == 'declare -a '* ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=()
  [[ "${modules_root}" == /* && -d "${modules_root}" &&
     ! -L "${modules_root}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${modules_root}" || return 1

  for entry in "${modules_root}"/* "${modules_root}"/.[!.]* \
    "${modules_root}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    entry_name="${entry##*/}"
    [[ "${entry_name}" == "root" && -d "${entry}" && ! -L "${entry}" ]] ||
      return 1
  done
  _cntools_registry_walk "${modules_root}/root" discovered || return $?
  output_ref=("${discovered[@]}")
}

# Purpose: validate the complete module tree against its library registry.
# Parameters: modules directory, library manifest.
# Result: no output.
# Status: 0 valid, 1 invalid, 2 missing tool/caller failure.
cntools_registry_validate_tree() {
  local modules_root="${1:-}"
  local library_manifest="${2:-}"
  local module_dir="" metadata="" module_id="" kind="" parent_dir=""
  local parent_id="" expected_prefix="" child_segment="" expected_id=""
  local shortcut="" order="" policy="" library_id="" library_path=""
  local key="" menu_dir="" reserved_shortcut="" reserved_control_id=""
  local runtime_root=""
  local jq_path=""
  local -a module_directories=() reserved_shortcuts=()
  local -A ids=() directory_ids=() directory_kinds=() menu_policies=()
  local -A sibling_shortcuts=() sibling_orders=() libraries=()

  cntools_registry_validate_library_manifest "${library_manifest}" || return $?
  cntools_registry_collect "${modules_root}" module_directories || return $?
  _cntools_registry_tool_path jq jq_path || return 2

  runtime_root="${library_manifest%/*}"
  runtime_root="${runtime_root%/*}"
  [[ "${runtime_root}" == /* && -d "${runtime_root}" && ! -L "${runtime_root}" ]] ||
    return 1
  while IFS=$'\t' builtin read -r library_id library_path; do
    [[ -n "${library_id}" && -n "${library_path}" ]] || return 1
    libraries["${library_id}"]="Y"
  done < <("${jq_path}" -r '.libraries[] | [.id, .path] | @tsv' "${library_manifest}")

  for module_dir in "${module_directories[@]}"; do
    metadata="${module_dir}/module.json"
    IFS=$'\t' builtin read -r module_id kind shortcut order policy < <(
      "${jq_path}" -er '[.id, .kind, (.shortcut // "-"), (.order // "-"),
        (.controlPolicy // "-")] | @tsv' "${metadata}"
    ) || return 1
    [[ -z "${ids[${module_id}]+set}" ]] || return 1
    ids["${module_id}"]="Y"
    directory_ids["${module_dir}"]="${module_id}"
    directory_kinds["${module_dir}"]="${kind}"

    if [[ "${module_dir}" == "${modules_root}/root" ]]; then
      [[ "${module_id}" == "root" && "${kind}" == "menu" &&
         "${policy}" == "root" ]] || return 1
    else
      expected_id="${module_dir#"${modules_root}"/root/}"
      expected_id="${expected_id//\//.}"
      [[ "${module_id}" == "${expected_id}" ]] || return 1
      parent_dir="${module_dir%/*}"
      parent_id="${directory_ids[${parent_dir}]:-}"
      [[ -n "${parent_id}" && "${directory_kinds[${parent_dir}]:-}" == "menu" ]] ||
        return 1
      if [[ "${parent_id}" == "root" ]]; then
        [[ "${module_id}" != *.* ]] || return 1
      else
        expected_prefix="${parent_id}."
        [[ "${module_id}" == "${expected_prefix}"* ]] || return 1
        child_segment="${module_id#"${expected_prefix}"}"
        [[ "${child_segment}" != *.* &&
           "${child_segment}" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
      fi
      key="${parent_dir}"$'\t'"${shortcut}"
      [[ -z "${sibling_shortcuts[${key}]+set}" ]] || return 1
      sibling_shortcuts["${key}"]="Y"
      key="${parent_dir}"$'\t'"${order}"
      [[ -z "${sibling_orders[${key}]+set}" ]] || return 1
      sibling_orders["${key}"]="Y"
    fi

    if [[ "${kind}" == "menu" ]]; then
      menu_policies["${module_dir}"]="${policy}"
      parent_dir="${module_dir%/*}"
      parent_id="${directory_ids[${parent_dir}]:-}"
      case "${policy}" in
        root) [[ "${module_id}" == "root" ]] || return 1 ;;
        home) [[ "${parent_id}" == "root" ]] || return 1 ;;
        back-home) [[ -n "${parent_id}" && "${parent_id}" != "root" ]] || return 1 ;;
        escape-root) [[ "${parent_id}" == "root" ]] || return 1 ;;
        *) return 1 ;;
      esac
    else
      while IFS= builtin read -r library_id; do
        [[ -n "${libraries[${library_id}]+set}" ]] || return 1
      done < <("${jq_path}" -r '.runtime.libraries[]' "${metadata}")
    fi
  done

  [[ "${ids[root]:-}" == "Y" ]] || return 1
  for menu_dir in "${!menu_policies[@]}"; do
    reserved_shortcuts=()
    reserved_control_id="${directory_ids[${menu_dir}]}"
    case "${menu_policies[${menu_dir}]}" in
      root)
        reserved_shortcuts=(r q)
        [[ -z "${ids[${reserved_control_id}.refresh]+set}" &&
           -z "${ids[${reserved_control_id}.quit]+set}" ]] || return 1
        ;;
      home)
        reserved_shortcuts=(h)
        [[ -z "${ids[${reserved_control_id}.home]+set}" ]] || return 1
        ;;
      back-home)
        reserved_shortcuts=(b h)
        [[ -z "${ids[${reserved_control_id}.back]+set}" &&
           -z "${ids[${reserved_control_id}.home]+set}" ]] || return 1
        ;;
      escape-root)
        reserved_shortcuts=()
        [[ -z "${ids[${reserved_control_id}.escape]+set}" ]] || return 1
        ;;
      *) return 1 ;;
    esac
    for reserved_shortcut in "${reserved_shortcuts[@]}"; do
      key="${menu_dir}"$'\t'"${reserved_shortcut}"
      [[ -z "${sibling_shortcuts[${key}]+set}" ]] || return 1
    done
  done
}

# Purpose: serialize the complete validated shadow menu without runtime context.
# Parameters: modules directory, library manifest.
# Result: deterministic JSON on stdout, including dispatcher-owned controls.
# Status: 0 success, 1 invalid tree/dump, 2 missing tool/caller failure.
# Side effects: none. Output is buffered and published only after success.
cntools_registry_dump_menu() {
  local modules_root="${1:-}"
  local library_manifest="${2:-}"
  local module_dir="" dump="" jq_path=""
  local -a module_directories=() metadata_files=()

  cntools_registry_validate_tree "${modules_root}" "${library_manifest}" || return $?
  _cntools_registry_collect_preorder "${modules_root}" module_directories || return $?
  _cntools_registry_tool_path jq jq_path || return 2
  for module_dir in "${module_directories[@]}"; do
    metadata_files+=("${module_dir}/module.json")
  done

  dump="$("${jq_path}" -S -s '
    def parent_id($id):
      if $id == "root" then null
      elif ($id | contains(".")) then ($id | split(".") | .[0:-1] | join("."))
      else "root"
      end;
    def child_option:
      {id, kind, order, shortcut, label, description, visibility} +
      (if .kind == "action" then
         {executionRequirements, runtime}
       else {} end);
    def controls($menu):
      if $menu.controlPolicy == "root" then [
        {id: ($menu.id + ".refresh"), kind: "control", shortcut: "r",
         label: "Refresh", navigation: "refresh-root"},
        {id: ($menu.id + ".quit"), kind: "control", shortcut: "q",
         label: "Quit", navigation: "exit"}
      ] elif $menu.controlPolicy == "home" then [
        {id: ($menu.id + ".home"), kind: "control", shortcut: "h",
         label: "Home", navigation: "root"}
      ] elif $menu.controlPolicy == "back-home" then [
        {id: ($menu.id + ".back"), kind: "control", shortcut: "b",
         label: "Back", navigation: parent_id($menu.id)},
        {id: ($menu.id + ".home"), kind: "control", shortcut: "h",
         label: "Home", navigation: "root"}
      ] else [
        {id: ($menu.id + ".escape"), kind: "control", shortcut: "Esc",
         label: "Cancel", navigation: "root"}
      ] end;
    . as $nodes |
    ($nodes | map(select(.kind == "menu"))) as $menus |
    ($nodes | map(select(.kind == "action")) | length) as $action_count |
    ($menus | length) as $menu_count |
    ([$menus[] | if .controlPolicy == "root" or .controlPolicy == "back-home"
       then 2 else 1 end] | add // 0) as $control_count |
    ({
      schemaVersion: 1,
      moduleSchemaVersion: 2,
      counts: {
        actions: $action_count,
        controls: $control_count,
        menus: $menu_count,
        modules: ($nodes | length),
        options: (($nodes | length) - 1 + $control_count)
      },
      menus: [
        $menus[] as $menu |
        {
          id: $menu.id,
          parent: parent_id($menu.id),
          label: $menu.label,
          description: $menu.description,
          visibility: $menu.visibility,
          controlPolicy: $menu.controlPolicy,
          options:
            (([$nodes[] |
                select(.id != "root" and parent_id(.id) == $menu.id)] |
              sort_by(.order, .id) | map(child_option)) + controls($menu))
        }
      ]
    }) as $dump |
    ([$dump.menus[].options[].id]) as $option_ids |
    if ($option_ids | length) == ($option_ids | unique | length)
    then $dump else error("duplicate emitted option ID") end
  ' "${metadata_files[@]}" 2>/dev/null)" || return 1
  [[ -n "${dump}" ]] || return 1
  builtin printf '%s\n' "${dump}"
}
