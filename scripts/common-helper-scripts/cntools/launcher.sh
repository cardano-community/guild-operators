#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# Installed Stage 3 diagnostic launcher. Sourcing defines functions only.
#
# Trust boundary: this launcher and an uncompromised Bash/system toolchain are
# the canary TCB. The launcher does not authenticate its own bytes. Instead it
# accepts only a physically installed generation that is bound by the node's
# deployment receipt and metadata, then authenticates every subsequently
# sourced generation byte.

_cntools_launcher_authority_error() {
  builtin printf '%s\n' \
    'CNTools generation is not bound to deployment authority.' >&2
}

_cntools_launcher_tool_path() {
  builtin local tool="${1:-}" output_name="${2:-}" kind="" path=""

  [[ "${tool}" =~ ^[a-z][a-z0-9-]*$ &&
     "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || builtin return 1
  kind="$(builtin type -t "${tool}" 2>/dev/null || builtin true)"
  [[ "${kind}" != "alias" && "${kind}" != "function" ]] ||
    builtin return 1
  path="$(builtin type -P "${tool}" 2>/dev/null || builtin true)"
  [[ "${path}" == /* && -f "${path}" && -x "${path}" ]] ||
    builtin return 1
  builtin printf -v "${output_name}" '%s' "${path}"
}

_cntools_launcher_clean_shell() {
  builtin local incoming_jq="" fixed_jq="" functions="" aliases=""
  builtin local declaration="" flag="" name="" extra=""

  # `builtin` is the explicit control primitive in the launcher TCB. Before
  # resolving or invoking any external tool, admit only definitions supplied
  # by this launcher itself. This closes imported-function shadowing of shell
  # builtins and of lifecycle/lock utilities without a brittle command list.
  functions="$(builtin declare -F 2>/dev/null)" || builtin return 1
  while IFS=' ' builtin read -r declaration flag name extra; do
    [[ "${declaration}" == "declare" && "${flag}" == "-f" &&
       -n "${name}" && -z "${extra}" ]] || builtin return 1
    case "${name}" in
      _cntools_launcher_authority_error|\
      _cntools_launcher_tool_path|\
      _cntools_launcher_clean_shell|\
      _cntools_launcher_sha256_file|\
      _cntools_launcher_sha256_stream|\
      _cntools_launcher_path_mode|\
      _cntools_launcher_path_has_no_symlinks|\
      _cntools_launcher_relative_path_valid|\
      _cntools_launcher_layout|\
      _cntools_launcher_authority_validate|\
      _cntools_launcher_generation_preflight|\
      cntools_launcher_main) ;;
      *) builtin return 1 ;;
    esac
  done <<< "${functions}"
  aliases="$(builtin alias -p 2>/dev/null || builtin true)"
  [[ -z "${aliases}" ]] || builtin return 1

  incoming_jq="$(builtin type -P jq 2>/dev/null || builtin true)"
  [[ "${incoming_jq}" == /* ]] || builtin return 1

  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  LC_ALL=C
  LANG=C
  IFS=$' \t\n'
  builtin export PATH LC_ALL LANG
  builtin unset BASH_ENV ENV CDPATH GLOBIGNORE 2>/dev/null || builtin return 1
  builtin hash -r
  builtin shopt -u expand_aliases
  builtin unalias -a 2>/dev/null || builtin true
  builtin set +e +u
  builtin set +o pipefail
  builtin set +f
  builtin umask 077

  fixed_jq="$(builtin type -P jq 2>/dev/null || builtin true)"
  [[ "${fixed_jq}" == /* && "${incoming_jq}" == "${fixed_jq}" ]] ||
    builtin return 1
  _cntools_launcher_tool_path jq fixed_jq || builtin return 1
}

_cntools_launcher_sha256_file() {
  local file="${1:-}" digest="" hash_path="" tr_path=""

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  if _cntools_launcher_tool_path sha256sum hash_path; then
    digest="$("${hash_path}" -- "${file}" 2>/dev/null)" || return 1
  elif _cntools_launcher_tool_path shasum hash_path; then
    digest="$("${hash_path}" -a 256 -- "${file}" 2>/dev/null)" || return 1
  else
    return 1
  fi
  _cntools_launcher_tool_path tr tr_path || return 1
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  builtin printf '%s' "${digest}" | "${tr_path}" '[:upper:]' '[:lower:]'
  builtin printf '\n'
}

_cntools_launcher_sha256_stream() {
  local digest="" hash_path="" tr_path=""

  if _cntools_launcher_tool_path sha256sum hash_path; then
    digest="$("${hash_path}" 2>/dev/null)" || return 1
  elif _cntools_launcher_tool_path shasum hash_path; then
    digest="$("${hash_path}" -a 256 2>/dev/null)" || return 1
  else
    return 1
  fi
  _cntools_launcher_tool_path tr tr_path || return 1
  digest="${digest%% *}"
  [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  builtin printf '%s' "${digest}" | "${tr_path}" '[:upper:]' '[:lower:]'
  builtin printf '\n'
}

_cntools_launcher_path_mode() {
  local target="${1:-}" mode="" find_path="" stat_path=""

  [[ -e "${target}" && ! -L "${target}" ]] || return 1
  _cntools_launcher_tool_path find find_path || return 1
  mode="$("${find_path}" "${target}" -prune -printf '%m' 2>/dev/null ||
    builtin true)"
  if [[ -z "${mode}" ]]; then
    _cntools_launcher_tool_path stat stat_path || return 1
    mode="$("${stat_path}" -f '%Lp' "${target}" 2>/dev/null || builtin true)"
  fi
  case "${mode}" in
    [0-7][0-7][0-7]) builtin printf '0%s\n' "${mode}" ;;
    [0-7][0-7][0-7][0-7]) builtin printf '%s\n' "${mode}" ;;
    *) return 1 ;;
  esac
}

_cntools_launcher_path_has_no_symlinks() {
  local target="${1:-}" current="" component=""
  local -a components=()

  [[ "${target}" == /* && "${target}" != "/" ]] || return 1
  IFS='/' builtin read -r -a components <<< "${target}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    [[ "${component}" != "." && "${component}" != ".." ]] || return 1
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || return 1
    if [[ -e "${current}" && "${current}" != "${target}" ]]; then
      [[ -d "${current}" ]] || return 1
    fi
  done
}

_cntools_launcher_relative_path_valid() {
  local path="${1:-}" component=""
  local -a components=()

  [[ -n "${path}" && "${path}" != /* && "${path}" != */ &&
     "${path}" != *//* && ! "${path}" =~ [[:cntrl:]] &&
     "${path}" =~ ^[A-Za-z0-9._/+@:-]+$ ]] || return 1
  IFS='/' builtin read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

_cntools_launcher_layout() {
  local runtime_root="${1:-}" output_root="${2:-}" output_node="${3:-}"
  local generations="" state_root="" scripts="" node_home="" mode=""

  [[ "${runtime_root}" == /* && "${runtime_root}" != "/" &&
     "${output_root}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${output_node}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${runtime_root##*/}" =~ ^[0-9a-f]{64}$ &&
     -d "${runtime_root}" && ! -L "${runtime_root}" && -O "${runtime_root}" ]] ||
    return 1
  _cntools_launcher_path_has_no_symlinks "${runtime_root}" || return 1
  generations="${runtime_root%/*}"
  state_root="${generations%/*}"
  scripts="${state_root%/*}"
  node_home="${scripts%/*}"
  [[ "${generations}" == "${state_root}/generations" &&
     "${state_root}" == "${scripts}/.cntools" &&
     "${scripts}" == "${node_home}/scripts" &&
     -d "${node_home}" && ! -L "${node_home}" && -O "${node_home}" &&
     -d "${state_root}" && ! -L "${state_root}" && -O "${state_root}" &&
     -d "${generations}" && ! -L "${generations}" && -O "${generations}" ]] ||
    return 1
  _cntools_launcher_path_has_no_symlinks "${node_home}" || return 1
  mode="$(_cntools_launcher_path_mode "${state_root}")" || return 1
  [[ "${mode}" == "0700" ]] || return 1
  mode="$(_cntools_launcher_path_mode "${generations}")" || return 1
  [[ "${mode}" == "0700" ]] || return 1
  mode="$(_cntools_launcher_path_mode "${runtime_root}")" || return 1
  [[ "${mode}" == "0555" ]] || return 1
  builtin printf -v "${output_root}" '%s' "${state_root}"
  builtin printf -v "${output_node}" '%s' "${node_home}"
}

_cntools_launcher_authority_validate() {
  local runtime_root="${1:-}" node="${2:-}" id="" relative=""
  local receipt="${node}/.guild-source-receipt.json"
  local metadata="${node}/.deployment.json"
  local journal="${node}/.guild-deploy-transaction"
  local manifest="${runtime_root}/cntools/manifest.json"
  local generation_receipt="${runtime_root}/.generation.json"
  local jq_path="" receipt_hash="" manifest_hash="" generation_receipt_hash=""

  id="${runtime_root##*/}"
  relative="scripts/.cntools/generations/${id}"

  [[ ! -e "${journal}" && ! -L "${journal}" ]] || return 1
  [[ -f "${receipt}" && ! -L "${receipt}" && -O "${receipt}" &&
     -f "${metadata}" && ! -L "${metadata}" && -O "${metadata}" ]] || return 1
  _cntools_launcher_path_has_no_symlinks "${receipt}" || return 1
  _cntools_launcher_path_has_no_symlinks "${metadata}" || return 1
  [[ "$(_cntools_launcher_path_mode "${receipt}")" == "0644" &&
     "$(_cntools_launcher_path_mode "${metadata}")" == "0644" ]] || return 1
  _cntools_launcher_tool_path jq jq_path || return 1
  receipt_hash="$(_cntools_launcher_sha256_file "${receipt}")" || return 1
  manifest_hash="$(_cntools_launcher_sha256_file "${manifest}")" || return 1
  generation_receipt_hash="$(_cntools_launcher_sha256_file \
    "${generation_receipt}")" || return 1

  "${jq_path}" -e --arg id "${id}" --arg relative "${relative}" \
    --arg manifest_hash "${manifest_hash}" \
    --arg generation_receipt_hash "${generation_receipt_hash}" '
      . as $receipt |
      type == "object" and
      keys == ["cntoolsGeneration", "files", "implementation", "network",
        "schemaVersion", "source"] and
      .schemaVersion == 2 and
      (.implementation == "cnode" or .implementation == "dingo") and
      (.network | type == "string" and length > 0) and
      (.source as $source |
        ($source | type == "object") and
        (($source.dirty == false and
          ($source |
          keys == ["channel", "dirty", "mode", "ref", "repository",
            "revision"])) or
         ($source.dirty == true and
          ($source |
          keys == ["channel", "dirty", "mode", "ref", "repository",
            "revision", "treeDigest"]) and
          ($source.treeDigest | type == "string" and
            test("^[0-9a-f]{64}$")))) and
        ($source.repository | type == "string" and length > 0) and
        ($source.channel | type == "string" and length > 0) and
        ($source.ref | type == "string" and test("^refs/(heads|tags)/")) and
        ($source.revision | type == "string" and test("^[0-9a-f]{40,64}$")) and
        ($source.mode == "managed" or $source.mode == "cached" or
          $source.mode == "local")) and
      (.cntoolsGeneration as $generation |
        ($generation | type == "object") and
        ($generation | keys == ["active", "fileCount", "generationReceipt",
          "generationReceiptSha256", "id", "path", "payloadManifest",
          "payloadManifestSha256", "schemaVersion", "version"]) and
        $generation.schemaVersion == 1 and $generation.active == false and
        $generation.fileCount == 152 and $generation.id == $id and
        $generation.version == "13.5.7" and $generation.path == $relative and
        $generation.payloadManifest == ($relative + "/cntools/manifest.json") and
        $generation.payloadManifestSha256 == $manifest_hash and
        $generation.generationReceipt == ($relative + "/.generation.json") and
        $generation.generationReceiptSha256 == $generation_receipt_hash) and
      (.files | type == "array" and
        length == (if $receipt.implementation == "cnode" then 48 else 25 end)) and
      ([.files[].path] | length == (unique | length)) and
      all(.files[];
        type == "object" and
        keys == ["installedSha256", "managed", "mode", "path", "policy",
          "source", "sourceSha256"] and
        (.path | type == "string" and
          test("^(scripts|files)/[A-Za-z0-9._/+@:-]+$") and
          (contains("//") | not) and
          (split("/") | all(. != "" and . != "." and . != ".."))) and
        (.source | type == "string" and
          test("^(scripts|files)/[A-Za-z0-9._/+@:-]+$") and
          (contains("//") | not) and
          (split("/") | all(. != "" and . != "." and . != ".."))) and
        (.mode | type == "string" and test("^0[0-7]{3}$")) and
        (.policy | type == "string" and length > 0) and
        (.sourceSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.installedSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.managed | type == "boolean"))
    ' "${receipt}" >/dev/null 2>&1 || return 1

  # Bind the outer deployment claim to the authenticated inner version fields
  # before either lifecycle or bootstrap code can be sourced.
  "${jq_path}" -e -s '
      length == 3 and
      .[0].cntoolsGeneration.version == "13.5.7" and
      .[1].version == "13.5.7" and
      .[2].version == "13.5.7" and
      .[0].cntoolsGeneration.version == .[1].version and
      .[1].version == .[2].version
    ' "${receipt}" "${manifest}" "${generation_receipt}" \
    >/dev/null 2>&1 || return 1

  "${jq_path}" -e --arg receipt_hash "${receipt_hash}" '
      type == "object" and
      ((.sourceDirty == false and
        keys == ["branch", "capabilities", "deploymentStatus",
          "implementation", "metricsProvider", "network", "nodePort",
          "nodeVersion", "payloadReceipt", "payloadReceiptSha256",
          "repository", "schemaVersion", "serviceName", "sourceDirty",
          "sourceMode", "sourceRef", "sourceRevision", "sourceSchemaVersion",
          "targetNodeVersion", "transactionId"]) or
       (.sourceDirty == true and
        keys == ["branch", "capabilities", "deploymentStatus",
          "implementation", "metricsProvider", "network", "nodePort",
          "nodeVersion", "payloadReceipt", "payloadReceiptSha256",
          "repository", "schemaVersion", "serviceName", "sourceDirty",
          "sourceMode", "sourceRef", "sourceRevision", "sourceSchemaVersion",
          "sourceTreeDigest", "targetNodeVersion", "transactionId"] and
        .sourceMode == "local" and
        (.sourceTreeDigest | type == "string" and test("^[0-9a-f]{64}$")))) and
      .schemaVersion == 1 and .deploymentStatus == "deployed" and
      (.implementation == "cnode" or .implementation == "dingo") and
      (.network | type == "string" and length > 0) and
      (.branch | type == "string" and length > 0) and
      (.repository | type == "string" and
        test("^[A-Za-z0-9_.-]+/guild-operators$")) and
      (.serviceName | type == "string" and length > 0) and
      (.nodePort | type == "number" and . >= 1 and . <= 65535 and
        floor == .) and
      (.nodeVersion | type == "string") and
      (.targetNodeVersion | type == "string") and
      (.metricsProvider | type == "string" and length > 0) and
      (.capabilities as $capabilities |
        ($capabilities | type == "object") and
        ($capabilities | keys == ["forging", "localCli", "metrics", "n2c"]) and
        all($capabilities[]; type == "boolean")) and
      .sourceSchemaVersion == 2 and
      (.sourceMode == "managed" or .sourceMode == "cached" or
        .sourceMode == "local") and
      (.sourceRef | type == "string" and test("^refs/(heads|tags)/")) and
      (.sourceRevision | type == "string" and test("^[0-9a-f]{40,64}$")) and
      (.sourceDirty | type == "boolean") and
      .payloadReceipt == ".guild-source-receipt.json" and
      .payloadReceiptSha256 == $receipt_hash and
      .transactionId == $receipt_hash[0:24]
    ' "${metadata}" >/dev/null 2>&1 || return 1

  "${jq_path}" -e -s '
      .[0] as $receipt | .[1] as $metadata |
      $metadata.implementation == $receipt.implementation and
      $metadata.network == $receipt.network and
      $metadata.repository == $receipt.source.repository and
      $metadata.branch == $receipt.source.channel and
      $metadata.sourceSchemaVersion == $receipt.schemaVersion and
      $metadata.sourceMode == $receipt.source.mode and
      $metadata.sourceRef == $receipt.source.ref and
      $metadata.sourceRevision == $receipt.source.revision and
      $metadata.sourceDirty == $receipt.source.dirty and
      (if $receipt.source.dirty then
         $metadata.sourceTreeDigest == $receipt.source.treeDigest
       else
         ($metadata | has("sourceTreeDigest") | not) and
         ($receipt.source | has("treeDigest") | not)
       end)
    ' "${receipt}" "${metadata}" >/dev/null 2>&1
}

_cntools_launcher_generation_preflight() {
  local runtime_root="${1:-}" receipt="" manifest="" id=""
  local jq_path="" find_path="" grep_path="" sort_path="" wc_path=""
  local relative_path="" declared_source="" expected_mode="" validator=""
  local expected_hash="" extra="" target="" actual_mode="" actual_hash=""
  local canonical_row="" canonical_text="" calculated_id="" manifest_hash=""
  local directory="" file_count="" record_count=0
  local -a canonical_rows=()

  receipt="${runtime_root}/.generation.json"
  manifest="${runtime_root}/cntools/manifest.json"
  id="${runtime_root##*/}"

  [[ -d "${runtime_root}" && ! -L "${runtime_root}" && -O "${runtime_root}" &&
     -f "${receipt}" && ! -L "${receipt}" && -O "${receipt}" &&
     -f "${manifest}" && ! -L "${manifest}" && -O "${manifest}" &&
     "$(_cntools_launcher_path_mode "${runtime_root}")" == "0555" &&
     "$(_cntools_launcher_path_mode "${receipt}")" == "0444" ]] || return 1
  _cntools_launcher_tool_path jq jq_path || return 1
  _cntools_launcher_tool_path find find_path || return 1
  _cntools_launcher_tool_path grep grep_path || return 1
  _cntools_launcher_tool_path sort sort_path || return 1
  _cntools_launcher_tool_path wc wc_path || return 1
  manifest_hash="$(_cntools_launcher_sha256_file "${manifest}")" || return 1

  "${jq_path}" -e -s --arg id "${id}" --arg manifest_hash "${manifest_hash}" '
      .[0] as $receipt | .[1] as $manifest |
      ($manifest | (type == "object" and
        keys == ["compatibilityLibrary", "contextApiVersion", "entrypoint",
          "files", "generationIdAlgorithm", "legacyBundle", "libraryManifest",
          "moduleApiVersion", "moduleSchema", "moduleSchemaVersion",
          "releaseStage", "rootModule", "runtimeApiVersion", "schemaVersion",
          "version"] and
        .schemaVersion == 3 and .moduleApiVersion == 1 and
        .moduleSchemaVersion == 2 and (.files | length == 151))) and
      ($receipt | (type == "object" and
        keys == ["files", "generationIdAlgorithm", "id", "payloadManifest",
          "payloadManifestSha256", "schemaVersion", "version"] and
        .schemaVersion == 3 and .id == $id and
        .version == $manifest.version and
        .generationIdAlgorithm == "sha256-path-mode-content-v1" and
        .payloadManifest == "cntools/manifest.json" and
        .payloadManifestSha256 == $manifest_hash and
        (.files | type == "array" and length == 152) and
        ([.files[].path] == ([.files[].path] | sort)) and
        ([.files[].path] | length == (unique | length)) and
        all(.files[];
          type == "object" and
          keys == ["mode", "path", "sha256", "source", "validator"] and
          (.path | type == "string" and test("^[A-Za-z0-9._/+@:-]+$") and
            (contains("//") | not) and
            (split("/") | all(. != "" and . != "." and . != ".."))) and
          (.source | type == "string" and
            test("^scripts/[A-Za-z0-9._/+@:-]+$") and
            (contains("//") | not)) and
          (.mode == "0444" or .mode == "0555") and
          (.validator == "shell" or .validator == "json" or
            .validator == "text" or .validator == "config") and
          (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))) and
      ($manifest.files | sort_by(.path)) ==
        ($receipt.files | map(select(.path != "cntools/manifest.json")) |
          sort_by(.path)) and
      ([ $receipt.files[] | select(.path == "cntools/core/bootstrap.sh" and
          .mode == "0444" and .validator == "shell") ] | length == 1) and
      ([ $receipt.files[] | select(.path == "cntools/core/lifecycle.sh" and
          .mode == "0444" and .validator == "shell") ] | length == 1)
    ' "${receipt}" "${manifest}" >/dev/null 2>&1 || return 1

  if "${find_path}" "${runtime_root}" -type l -print -quit 2>/dev/null |
      "${grep_path}" -q .; then
    return 1
  fi
  if "${find_path}" "${runtime_root}" ! -type d ! -type f -print -quit \
      2>/dev/null | "${grep_path}" -q .; then
    return 1
  fi
  while IFS= builtin read -r directory; do
    [[ -O "${directory}" &&
       "$(_cntools_launcher_path_mode "${directory}")" == "0555" ]] || return 1
  done < <("${find_path}" "${runtime_root}" -type d -print)

  while IFS=$'\t' builtin read -r relative_path declared_source expected_mode \
      validator expected_hash extra; do
    [[ -n "${relative_path}" && -n "${declared_source}" &&
       -n "${validator}" && -z "${extra}" ]] || return 1
    _cntools_launcher_relative_path_valid "${relative_path}" || return 1
    target="${runtime_root}/${relative_path}"
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || return 1
    _cntools_launcher_path_has_no_symlinks "${target}" || return 1
    actual_mode="$(_cntools_launcher_path_mode "${target}")" || return 1
    actual_hash="$(_cntools_launcher_sha256_file "${target}")" || return 1
    [[ "${actual_mode}" == "${expected_mode}" &&
       "${actual_hash}" == "${expected_hash}" ]] || return 1
    case "${validator}" in
      shell) "${BASH}" -n "${target}" >/dev/null 2>&1 || return 1 ;;
      json) "${jq_path}" -e . "${target}" >/dev/null 2>&1 || return 1 ;;
      text|config) [[ -s "${target}" ]] || return 1 ;;
      *) return 1 ;;
    esac
    builtin printf -v canonical_row '%s\t%s\t%s' \
      "${relative_path}" "${expected_mode}" "${actual_hash}" || return 1
    canonical_rows+=("${canonical_row}")
    record_count=$((record_count + 1))
  done < <("${jq_path}" -er '.files[] |
    [.path,.source,.mode,.validator,.sha256] | @tsv' "${receipt}")
  (( record_count == 152 )) || return 1
  canonical_text="$(builtin printf '%s\n' "${canonical_rows[@]}" |
    LC_ALL=C "${sort_path}")" || return 1
  calculated_id="$(builtin printf '%s\n' "${canonical_text}" |
    _cntools_launcher_sha256_stream)" || return 1
  [[ "${calculated_id}" == "${id}" ]] || return 1
  file_count="$("${find_path}" "${runtime_root}" -type f -print |
    "${wc_path}" -l)" || return 1
  file_count="${file_count//[[:space:]]/}"
  [[ "${file_count}" == "153" ]]
}

cntools_launcher_main() {
  builtin local launcher_path="${BASH_SOURCE[0]}" launcher_dir=""
  builtin local launcher_file="" dirname_path="" runtime_root=""
  builtin local cntools_root="" node="" lifecycle="" bootstrap=""
  builtin local generation_id="" output="" status=0 lock_acquired="N"

  if (( BASH_VERSINFO[0] < 4 ||
        (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    builtin printf 'CNTools requires Bash 4.4 or newer.\n' >&2
    builtin return 64
  fi
  if ! _cntools_launcher_clean_shell; then
    _cntools_launcher_authority_error
    builtin return 70
  fi
  _cntools_launcher_tool_path dirname dirname_path || {
    _cntools_launcher_authority_error
    builtin return 70
  }
  launcher_dir="$(builtin cd -P -- \
    "$("${dirname_path}" -- "${launcher_path}")" 2>/dev/null && builtin pwd -P)" || {
    _cntools_launcher_authority_error
    return 70
  }
  launcher_file="${launcher_dir}/${launcher_path##*/}"
  runtime_root="${launcher_dir}"
  if [[ "${launcher_path##*/}" != "cntools.sh" ||
        ! -f "${launcher_file}" || -L "${launcher_file}" ||
        ! -O "${launcher_file}" ]] ||
     ! _cntools_launcher_path_has_no_symlinks "${launcher_file}" ||
     ! _cntools_launcher_layout "${runtime_root}" cntools_root node ||
     ! _cntools_launcher_authority_validate "${runtime_root}" "${node}" ||
     ! _cntools_launcher_generation_preflight "${runtime_root}"; then
    _cntools_launcher_authority_error
    return 70
  fi

  generation_id="${runtime_root##*/}"
  lifecycle="${runtime_root}/cntools/core/lifecycle.sh"
  bootstrap="${runtime_root}/cntools/core/bootstrap.sh"
  if ! builtin source "${lifecycle}" >/dev/null 2>&1 ||
     ! builtin declare -F cntools_generation_validate >/dev/null 2>&1 ||
     ! builtin declare -F cntools_generation_lock_acquire >/dev/null 2>&1 ||
     ! builtin declare -F cntools_generation_lock_release >/dev/null 2>&1 ||
     ! cntools_generation_validate "${runtime_root}" "${generation_id}" ||
     ! cntools_generation_lock_acquire "${cntools_root}"; then
    _cntools_launcher_authority_error
    return 70
  fi
  lock_acquired="Y"

  if ! _cntools_launcher_authority_validate "${runtime_root}" "${node}" ||
     ! _cntools_launcher_generation_preflight "${runtime_root}" ||
     ! cntools_generation_validate "${runtime_root}" "${generation_id}" ||
     ! builtin source "${bootstrap}" >/dev/null 2>&1 ||
     ! builtin declare -F cntools_bootstrap_main >/dev/null 2>&1; then
    cntools_generation_lock_release "${cntools_root}" >/dev/null 2>&1 ||
      builtin true
    _cntools_launcher_authority_error
    return 70
  fi

  output="$(cntools_bootstrap_main "${runtime_root}" "$@")" || status=$?
  if [[ "${lock_acquired}" == "Y" ]] &&
     ! cntools_generation_lock_release "${cntools_root}"; then
    [[ ${status} -ne 0 ]] || status=70
  fi
  if [[ ${status} -eq 0 ]]; then
    [[ -z "${output}" ]] || builtin printf '%s\n' "${output}"
  elif [[ ${status} -eq 70 ]]; then
    _cntools_launcher_authority_error
  fi
  return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cntools_launcher_main "$@"
fi
