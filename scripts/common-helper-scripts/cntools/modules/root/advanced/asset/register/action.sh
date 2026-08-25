#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Stage 4 hardened compatibility action for token-registry registration.
# Sourcing defines functions only; the dispatcher supplies authenticated
# context and the legacy UI helpers.

_cntools_action_advanced_asset_register_validation_failure() {
  builtin printf '%s\n' 'CNTools asset-register action failed validation.' >&2
  return 70
}

_cntools_action_advanced_asset_register_uint_le() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]*)$ &&
     "${maximum}" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  (( ${#value} < ${#maximum} )) && return 0
  (( ${#value} == ${#maximum} )) || return 1
  [[ "${value}" == "${maximum}" || "${value}" < "${maximum}" ]]
}

_cntools_action_advanced_asset_register_leaf_name_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9._-]{1,192}$ &&
     "${value}" != . && "${value}" != .. &&
     "${value}" != -* && ! "${value}" =~ [[:cntrl:]] ]]
}

_cntools_action_advanced_asset_register_text_valid() {
  local value="${1-}" minimum="${2:-}" maximum="${3:-}"

  [[ "${minimum}" =~ ^[0-9]+$ && "${maximum}" =~ ^[1-9][0-9]*$ &&
     ${#value} -ge minimum && ${#value} -le maximum &&
     ! "${value}" =~ [[:cntrl:]] ]]
}

_cntools_action_advanced_asset_register_file_validate() {
  local target="${1:-}" allowed_modes="${2:-}" maximum_size="${3:-}"
  local allow_empty="${4:-N}" metadata="" owner="" mode="" links="" size=""

  [[ -f "${target}" && ! -L "${target}" &&
     "${maximum_size}" =~ ^[1-9][0-9]*$ &&
     ( "${allow_empty}" == Y || "${allow_empty}" == N ) ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${size}" =~ ^[0-9]+$ && "${size}" -le "${maximum_size}" &&
     ( "${allow_empty}" == Y || "${size}" -ge 1 ) &&
     ",${allowed_modes}," == *",${mode},"* ]]
}

_cntools_action_advanced_asset_register_directory_validate() {
  local target="${1:-}" allowed_modes="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ",${allowed_modes}," == *",${mode},"* ]]
}

_cntools_action_advanced_asset_register_hash_file() {
  local target="${1:-}" output=""

  if [[ "${asset_register_hash_flavor}" == sha256sum ]]; then
    output="$("${asset_register_hash_path}" -- "${target}")" || return 1
  else
    output="$("${asset_register_hash_path}" -a 256 -- "${target}")" || return 1
  fi
  output="${output%% *}"
  [[ "${output}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "${output}"
}

_cntools_action_advanced_asset_register_remove_leaf() {
  local target="${1:-}"

  [[ -n "${target}" ]] || return 0
  if [[ -e "${target}" || -L "${target}" ]]; then
    [[ ! -d "${target}" || -L "${target}" ]] || return 1
    "${asset_register_rm_path}" -f -- "${target}" >/dev/null 2>&1 || return 1
  fi
}

_cntools_action_advanced_asset_register_cleanup_transaction() {
  local leaf="" target="" cleanup_failed=0

  [[ -n "${asset_register_transaction_directory:-}" ]] || return 0
  for leaf in policy.script policy.skey original.asset asset.next \
      asset.next.tmp registry.next tool.log tool.out \
      "${asset_register_expected_registry:-}"; do
    [[ -n "${leaf}" ]] || continue
    _cntools_action_advanced_asset_register_remove_leaf \
      "${asset_register_transaction_directory}/${leaf}" || cleanup_failed=1
  done
  # The authenticated tool may leave an unexpected direct child. The private
  # transaction directory is action-created and 0700, so unlink only safe
  # direct leaves here; never recurse into an unexpected directory.
  if [[ -n "${asset_register_find_path:-}" &&
        -d "${asset_register_transaction_directory}" &&
        ! -L "${asset_register_transaction_directory}" ]]; then
    while IFS= read -r -d '' target; do
      if [[ -d "${target}" && ! -L "${target}" ]]; then
        cleanup_failed=1
      else
        _cntools_action_advanced_asset_register_remove_leaf "${target}" ||
          cleanup_failed=1
      fi
    done < <("${asset_register_find_path}" \
      "${asset_register_transaction_directory}" -mindepth 1 -maxdepth 1 \
      -print0 2>/dev/null)
  fi
  if [[ -d "${asset_register_transaction_directory}" &&
        ! -L "${asset_register_transaction_directory}" ]]; then
    "${asset_register_rmdir_path}" -- "${asset_register_transaction_directory}" \
      >/dev/null 2>&1 || cleanup_failed=1
  elif [[ -e "${asset_register_transaction_directory}" ||
          -L "${asset_register_transaction_directory}" ]]; then
    cleanup_failed=1
  fi
  [[ "${cleanup_failed}" == 0 ]] && asset_register_transaction_directory=""
  return "${cleanup_failed}"
}

_cntools_action_advanced_asset_register_release_lock() {
  [[ -n "${asset_register_lock_directory:-}" ]] || return 0
  [[ -d "${asset_register_lock_directory}" &&
     ! -L "${asset_register_lock_directory}" ]] || return 1
  "${asset_register_rmdir_path}" -- "${asset_register_lock_directory}" ||
    return 1
  asset_register_lock_directory=""
}

_cntools_action_advanced_asset_register_rollback_publish() {
  local rollback_failed=0

  if [[ "${asset_register_asset_published:-N}" == Y ]]; then
    if [[ "${asset_register_original_asset_exists:-N}" == Y ]]; then
      _cntools_action_advanced_asset_register_file_validate \
        "${asset_register_transaction_directory}/original.asset" 600 1048576 Y &&
        [[ "$(_cntools_action_advanced_asset_register_hash_file \
          "${asset_register_transaction_directory}/original.asset")" == \
          "${asset_register_backup_hash:-}" ]] &&
        "${asset_register_mv_path}" -f -- \
          "${asset_register_transaction_directory}/original.asset" \
          "${asset_register_asset_file}" >/dev/null 2>&1 || rollback_failed=1
    else
      _cntools_action_advanced_asset_register_remove_leaf \
        "${asset_register_asset_file}" || rollback_failed=1
    fi
  fi
  if [[ "${asset_register_registry_published:-N}" == Y ]]; then
    _cntools_action_advanced_asset_register_remove_leaf \
      "${asset_register_registry_file}" || rollback_failed=1
  fi
  asset_register_asset_published=N
  asset_register_registry_published=N
  asset_register_asset_publish_attempt=N
  asset_register_registry_publish_attempt=N
  return "${rollback_failed}"
}

_cntools_action_advanced_asset_register_reconcile_publish_attempts() {
  if [[ "${asset_register_registry_publish_attempt:-N}" == Y &&
        "${asset_register_registry_published:-N}" != Y &&
        -f "${asset_register_registry_file}" &&
        ! -L "${asset_register_registry_file}" &&
        "$(_cntools_action_advanced_asset_register_hash_file \
          "${asset_register_registry_file}")" == \
          "${asset_register_registry_hash:-}" ]]; then
    asset_register_registry_published=Y
  fi
  if [[ "${asset_register_asset_publish_attempt:-N}" == Y &&
        "${asset_register_asset_published:-N}" != Y &&
        ! -e "${asset_register_transaction_directory}/asset.next" &&
        ! -L "${asset_register_transaction_directory}/asset.next" &&
        -f "${asset_register_asset_file}" &&
        ! -L "${asset_register_asset_file}" &&
        "$(_cntools_action_advanced_asset_register_hash_file \
          "${asset_register_asset_file}")" == \
          "${asset_register_next_asset_hash:-}" ]]; then
    asset_register_asset_published=Y
  fi
}

_cntools_action_advanced_asset_register_cleanup() {
  local cleanup_failed=0

  trap - EXIT HUP INT TERM
  _cntools_action_advanced_asset_register_reconcile_publish_attempts
  if [[ "${asset_register_registry_published:-N}" == Y ||
        "${asset_register_asset_published:-N}" == Y ]]; then
    _cntools_action_advanced_asset_register_rollback_publish || cleanup_failed=1
  fi
  _cntools_action_advanced_asset_register_cleanup_transaction || cleanup_failed=1
  if [[ -n "${asset_register_lock_directory:-}" ]]; then
    _cntools_action_advanced_asset_register_release_lock || cleanup_failed=1
  fi
  return "${cleanup_failed}"
}

_cntools_action_advanced_asset_register_precommit_abort() {
  if _cntools_action_advanced_asset_register_cleanup; then
    return 0
  fi
  _cntools_action_advanced_asset_register_cleanup || true
  _cntools_action_advanced_asset_register_validation_failure
  return 70
}

_cntools_action_advanced_asset_register_postcommit_cleanup() {
  local cleanup_failed=0

  trap - EXIT HUP INT TERM
  _cntools_action_advanced_asset_register_cleanup_transaction || cleanup_failed=1
  if [[ -n "${asset_register_lock_directory:-}" ]]; then
    _cntools_action_advanced_asset_register_release_lock || {
      cleanup_failed=1
      _cntools_action_advanced_asset_register_release_lock || true
    }
  fi
  if [[ "${cleanup_failed}" != 0 ]]; then
    println ERROR "${FG_YELLOW}WARN${NC}: registration committed, but postcommit cleanup was incomplete."
  fi
  return 0
}

_cntools_action_advanced_asset_register_json_validate() {
  local target="${1:-}" subject="${2:-}"

  _cntools_action_advanced_asset_register_file_validate \
    "${target}" 600,644 1048576 N || return 1
  "${asset_register_jq_path}" -e --arg subject "${subject}" '
    type == "object" and .subject == $subject and
    (.. | strings | length <= 65536) and
    (.. | strings | test("[\\x{0000}-\\x{0008}\\x{000B}\\x{000C}\\x{000E}-\\x{001F}\\x{007F}-\\x{009F}]") | not)
  ' "${target}" >/dev/null 2>&1
}

_cntools_action_advanced_asset_register_inventory_validate() {
  local expected_registry="${1:-}" target="" leaf=""

  while IFS= read -r -d '' target; do
    leaf="${target##*/}"
    case "${leaf}" in
      policy.script|policy.skey|original.asset|asset.next|tool.log|tool.out|\
      "${expected_registry}") ;;
      *) return 1 ;;
    esac
    [[ -f "${target}" && ! -L "${target}" ]] || return 1
  done < <("${asset_register_find_path}" \
    "${asset_register_transaction_directory}" -mindepth 1 -maxdepth 1 \
    -print0 2>/dev/null)
}

_cntools_action_advanced_asset_register_tool_phase() {
  local phase="${1:-}" expected_registry="${2:-}" tool_status=0 output=""
  local registry_path="${asset_register_transaction_directory}/${expected_registry}"
  local -a argv=()

  _cntools_action_advanced_asset_register_remove_leaf \
    "${asset_register_transaction_directory}/tool.log" || return 70
  _cntools_action_advanced_asset_register_remove_leaf \
    "${asset_register_transaction_directory}/tool.out" || return 70
  ( umask 077; : > "${asset_register_transaction_directory}/tool.log" &&
    : > "${asset_register_transaction_directory}/tool.out" ) || return 70
  "${asset_register_chmod_path}" 0600 \
    "${asset_register_transaction_directory}/tool.log" \
    "${asset_register_transaction_directory}/tool.out" || return 70
  case "${phase}" in
    draft)
      argv=("${asset_register_tool_path}" entry "${asset_register_subject}"
        --init --name "${asset_register_meta_name}"
        --description "${asset_register_meta_desc}"
        --policy "${asset_register_transaction_directory}/policy.script")
      [[ -z "${asset_register_meta_ticker}" ]] ||
        argv+=(--ticker "${asset_register_meta_ticker}")
      [[ -z "${asset_register_meta_url}" ]] ||
        argv+=(--url "${asset_register_meta_url}")
      [[ -z "${asset_register_meta_decimals}" ]] ||
        argv+=(--decimals "${asset_register_meta_decimals}")
      [[ -z "${asset_register_meta_logo}" ]] ||
        argv+=(--logo "${asset_register_meta_logo}")
      ;;
    sign)
      argv=("${asset_register_tool_path}" entry "${asset_register_subject}"
        -a "${asset_register_transaction_directory}/policy.skey")
      ;;
    finalize)
      argv=("${asset_register_tool_path}" entry "${asset_register_subject}"
        --finalize)
      ;;
    validate)
      argv=("${asset_register_tool_path}" validate "${expected_registry}")
      ;;
    *) return 70 ;;
  esac
  (
    builtin cd -P -- "${asset_register_transaction_directory}" || exit 70
    "${argv[@]}"
  ) > "${asset_register_transaction_directory}/tool.out" \
    2> "${asset_register_transaction_directory}/tool.log" || tool_status=$?
  if [[ "${tool_status}" != 0 ]]; then
    return 1
  fi
  _cntools_action_advanced_asset_register_file_validate \
    "${asset_register_transaction_directory}/tool.out" 600 4096 N || return 70
  output="$(< "${asset_register_transaction_directory}/tool.out")"
  [[ "${output}" == "${expected_registry}" &&
     "$("${asset_register_wc_path}" -l < \
       "${asset_register_transaction_directory}/tool.out" | \
       "${asset_register_tr_path}" -d '[:space:]')" == 1 ]] ||
    return 70
  _cntools_action_advanced_asset_register_json_validate \
    "${registry_path}" "${asset_register_subject}" || return 70
  _cntools_action_advanced_asset_register_inventory_validate \
    "${expected_registry}" || return 70
  _cntools_action_advanced_asset_register_remove_leaf \
    "${asset_register_transaction_directory}/tool.log" || return 70
  _cntools_action_advanced_asset_register_remove_leaf \
    "${asset_register_transaction_directory}/tool.out" || return 70
  return 0
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local asset_register_private_parent="" asset_register_asset_root=""
  local asset_register_policy_name="" asset_register_policy_folder=""
  local asset_register_policy_sk_filename="${ASSET_POLICY_SK_FILENAME:-}"
  local asset_register_policy_script_filename="${ASSET_POLICY_SCRIPT_FILENAME:-}"
  local asset_register_policy_id_filename="${ASSET_POLICY_ID_FILENAME:-}"
  local asset_register_policy_sk_file="" asset_register_policy_script_file=""
  local asset_register_policy_id_file="" asset_register_policy_id=""
  local asset_register_policy_sk_hash="" asset_register_policy_script_hash=""
  local asset_register_policy_id_hash="" asset_register_asset_hash=""
  local asset_register_original_asset_exists=N asset_register_asset_name=""
  local asset_register_asset_file="" asset_register_subject=""
  local asset_register_meta_name="" asset_register_meta_desc=""
  local asset_register_meta_ticker="" asset_register_meta_url=""
  local asset_register_meta_decimals="" asset_register_meta_logo=""
  local asset_register_logo_header="" asset_register_sequence=0
  local asset_register_expected_registry="" asset_register_registry_file=""
  local asset_register_transaction_directory="" asset_register_lock_directory=""
  local asset_register_registry_published=N asset_register_asset_published=N
  local asset_register_registry_publish_attempt=N
  local asset_register_asset_publish_attempt=N
  local asset_register_registry_hash="" asset_register_next_asset_hash=""
  local asset_register_backup_hash=""
  local action_status=0 phase_status=0
  local asset_register_jq_path="" asset_register_find_path=""
  local asset_register_sort_path="" asset_register_mkdir_path=""
  local asset_register_mktemp_path="" asset_register_chmod_path=""
  local asset_register_cp_path="" asset_register_mv_path=""
  local asset_register_ln_path="" asset_register_tr_path=""
  local asset_register_rm_path="" asset_register_rmdir_path=""
  local asset_register_wc_path="" asset_register_od_path=""
  local asset_register_date_path="" asset_register_hash_path=""
  local asset_register_hash_flavor="" asset_register_tool_path=""
  local asset_register_metadata="" asset_register_owner=""
  local asset_register_mode="" asset_register_links="" asset_register_size=""
  local asset_register_existing="" asset_register_existing_name=""
  local asset_register_existing_minted="" asset_register_name_maxlen=5
  local asset_register_amount_maxlen=12 tool="" leaf="" now=""
  local LC_ALL=C

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks \
       >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate \
       >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1 ||
     ! builtin declare -F fileDialog >/dev/null 2>&1 ||
     ! builtin declare -F selectPolicy >/dev/null 2>&1; then
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  asset_register_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${asset_register_private_parent}" || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  for tool in jq find sort mkdir mktemp chmod cp mv ln rm rmdir wc tr od date; do
    case "${tool}" in
      jq) _cntools_registry_tool_path jq asset_register_jq_path || action_status=70 ;;
      find) _cntools_registry_tool_path find asset_register_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort asset_register_sort_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir asset_register_mkdir_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp asset_register_mktemp_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod asset_register_chmod_path || action_status=70 ;;
      cp) _cntools_registry_tool_path cp asset_register_cp_path || action_status=70 ;;
      mv) _cntools_registry_tool_path mv asset_register_mv_path || action_status=70 ;;
      ln) _cntools_registry_tool_path ln asset_register_ln_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm asset_register_rm_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir asset_register_rmdir_path || action_status=70 ;;
      wc) _cntools_registry_tool_path wc asset_register_wc_path || action_status=70 ;;
      tr) _cntools_registry_tool_path tr asset_register_tr_path || action_status=70 ;;
      od) _cntools_registry_tool_path od asset_register_od_path || action_status=70 ;;
      date) _cntools_registry_tool_path date asset_register_date_path || action_status=70 ;;
    esac
  done
  if _cntools_registry_tool_path sha256sum asset_register_hash_path; then
    asset_register_hash_flavor=sha256sum
  elif _cntools_registry_tool_path shasum asset_register_hash_path; then
    asset_register_hash_flavor=shasum
  else
    action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  [[ "${ASSET_FOLDER:-}" == /* && -d "${ASSET_FOLDER}" &&
     ! -L "${ASSET_FOLDER}" ]] || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  _cntools_registry_path_has_no_symlinks "${ASSET_FOLDER}" || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  asset_register_asset_root="$(cd -P -- "${ASSET_FOLDER}" && pwd -P)" || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  _cntools_action_advanced_asset_register_directory_validate \
    "${asset_register_asset_root}" 700,750,755 || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  for leaf in "${asset_register_policy_sk_filename}" \
      "${asset_register_policy_script_filename}" \
      "${asset_register_policy_id_filename}"; do
    _cntools_action_advanced_asset_register_leaf_name_valid "${leaf}" || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
  done
  [[ "${asset_register_policy_sk_filename}" != \
       "${asset_register_policy_script_filename}" &&
     "${asset_register_policy_sk_filename}" != \
       "${asset_register_policy_id_filename}" &&
     "${asset_register_policy_script_filename}" != \
       "${asset_register_policy_id_filename}" ]] || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }

  umask 077
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> ADVANCED >> ASSET >> REGISTER ASSET'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  if ! _cntools_registry_tool_path token-metadata-creator \
      asset_register_tool_path; then
    println ERROR 'Please follow instructions on Guild Operators site to download or build the tool:'
    println ERROR "${FG_YELLOW}https://cardano-community.github.io/guild-operators/Build/offchain-metadata-tools/${NC}"
    waitToProceed
    return 0
  fi
  if [[ -z "$("${asset_register_find_path}" "${asset_register_asset_root}" \
      -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo
    println "${FG_YELLOW}No policies found!${NC}\n\nPlease first create a policy to use for Cardano Token Registry"
    waitToProceed
    return 0
  fi
  println DEBUG 'Select the policy to use for Cardano Token Registry'
  selectPolicy all "${asset_register_policy_sk_filename}" \
    "${asset_register_policy_script_filename}" \
    "${asset_register_policy_id_filename}"
  case $? in
    1) waitToProceed; return 0 ;;
    2) return 0 ;;
  esac
  asset_register_policy_name="${policy_name:-}"
  _cntools_action_advanced_asset_register_leaf_name_valid \
    "${asset_register_policy_name}" || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  asset_register_policy_folder="${asset_register_asset_root}/${asset_register_policy_name}"
  _cntools_action_advanced_asset_register_directory_validate \
    "${asset_register_policy_folder}" 700,750,755 || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  asset_register_policy_sk_file="${asset_register_policy_folder}/${asset_register_policy_sk_filename}"
  asset_register_policy_script_file="${asset_register_policy_folder}/${asset_register_policy_script_filename}"
  asset_register_policy_id_file="${asset_register_policy_folder}/${asset_register_policy_id_filename}"
  _cntools_action_advanced_asset_register_file_validate \
    "${asset_register_policy_sk_file}" 400,440,444,600,640,644 65536 N || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  _cntools_action_advanced_asset_register_file_validate \
    "${asset_register_policy_script_file}" 400,440,444,600,640,644 65536 N || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  _cntools_action_advanced_asset_register_file_validate \
    "${asset_register_policy_id_file}" 400,440,444,600,640,644 128 N || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  asset_register_policy_id="$(< "${asset_register_policy_id_file}")"
  [[ "${asset_register_policy_id}" =~ ^[0-9a-f]{56}$ ]] || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  "${asset_register_jq_path}" -e 'type == "object"' \
    "${asset_register_policy_script_file}" >/dev/null 2>&1 || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }

  echo
  if [[ -n "$("${asset_register_find_path}" \
      "${asset_register_policy_folder}" -mindepth 1 -maxdepth 1 \
      -type f -name '*.asset' -print -quit 2>/dev/null)" ]]; then
    println DEBUG 'Assets previously minted for this Policy\n'
    while IFS= read -r -d '' asset_register_existing; do
      asset_register_existing_name="${asset_register_existing##*/}"
      asset_register_existing_name="${asset_register_existing_name%.*}"
      [[ -n "${asset_register_existing_name}" ]] || asset_register_existing_name='.'
      (( ${#asset_register_existing_name} <= asset_register_name_maxlen )) ||
        asset_register_name_maxlen=${#asset_register_existing_name}
      asset_register_existing_minted="$("${asset_register_jq_path}" -er \
        '.minted // 0 | if type == "number" then tostring else error("type") end' \
        "${asset_register_existing}" 2>/dev/null)" ||
        asset_register_existing_minted='?'
      (( ${#asset_register_existing_minted} <= asset_register_amount_maxlen )) ||
        asset_register_amount_maxlen=${#asset_register_existing_minted}
    done < <("${asset_register_find_path}" \
      "${asset_register_policy_folder}" -mindepth 1 -maxdepth 1 \
      -type f -name '*.asset' -print0 2>/dev/null | \
      "${asset_register_sort_path}" -z)
    println DEBUG "$(printf "%${asset_register_amount_maxlen}s | %s\n" \
      'Total Amount' 'Policy ID[.AssetName]')"
    println DEBUG "$(printf "%$((asset_register_amount_maxlen+1))s+%$((asset_register_name_maxlen+58))s\n" \
      '' '' | tr ' ' '-')"
    while IFS= read -r -d '' asset_register_existing; do
      asset_register_existing_name="${asset_register_existing##*/}"
      asset_register_existing_name="${asset_register_existing_name%.*}"
      asset_register_existing_minted="$("${asset_register_jq_path}" -er \
        '.minted // 0 | if type == "number" then tostring else error("type") end' \
        "${asset_register_existing}" 2>/dev/null)" ||
        asset_register_existing_minted='?'
      if [[ -z "${asset_register_existing_name}" ]]; then
        println DEBUG "$(printf "${FG_LBLUE}%${asset_register_amount_maxlen}s${NC} | %s\n" \
          "${asset_register_existing_minted}" \
          "${FG_LGRAY}${asset_register_policy_id}${NC}")"
      else
        println DEBUG "$(printf "${FG_LBLUE}%${asset_register_amount_maxlen}s${NC} | %s\n" \
          "${asset_register_existing_minted}" \
          "${FG_LGRAY}${asset_register_policy_id}.${FG_MAGENTA}${asset_register_existing_name}${NC}")"
      fi
    done < <("${asset_register_find_path}" \
      "${asset_register_policy_folder}" -mindepth 1 -maxdepth 1 \
      -type f -name '*.asset' -print0 2>/dev/null | \
      "${asset_register_sort_path}" -z)
    echo
  fi
  println 'Please enter the asset name as part of PolicyID.AssetName to create registry file for, either a previously minted coin or new'
  if ! getAnswerAnyCust asset_register_asset_name 'Asset Name (empty valid)'; then
    return 0
  fi
  if [[ ! "${asset_register_asset_name}" =~ ^[A-Za-z0-9]{0,32}$ ]]; then
    println ERROR "${FG_RED}ERROR${NC}: Asset name should only contain alphanumeric chars and be at most 32 chars in length!"
    waitToProceed
    return 0
  fi
  asset_register_asset_file="${asset_register_policy_folder}/${asset_register_asset_name}.asset"
  asset_register_subject="${asset_register_policy_id}"
  if [[ -n "${asset_register_asset_name}" ]]; then
    asset_register_metadata="$(builtin printf '%s' \
      "${asset_register_asset_name}" | "${asset_register_od_path}" -An -tx1 -v)" || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    asset_register_metadata="${asset_register_metadata//[[:space:]]/}"
    [[ "${asset_register_metadata}" =~ ^[0-9a-f]{2,64}$ ]] || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    asset_register_subject+="${asset_register_metadata}"
  fi
  asset_register_expected_registry="${asset_register_subject}.json"
  _cntools_action_advanced_asset_register_leaf_name_valid \
    "${asset_register_expected_registry}" || {
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  asset_register_registry_file="${asset_register_policy_folder}/${asset_register_expected_registry}"
  if [[ -e "${asset_register_registry_file}" ||
        -L "${asset_register_registry_file}" ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Registry destination already exists; refusing to overwrite it."
    waitToProceed
    return 0
  fi

  echo
  asset_register_lock_directory="${asset_register_policy_folder}/.cntools-register.lock"
  if ! "${asset_register_mkdir_path}" -m 0700 -- \
      "${asset_register_lock_directory}" 2>/dev/null; then
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  trap '_cntools_action_advanced_asset_register_cleanup' EXIT
  trap '_cntools_action_advanced_asset_register_cleanup; exit 70' HUP INT TERM
  asset_register_policy_sk_hash="$(_cntools_action_advanced_asset_register_hash_file \
    "${asset_register_policy_sk_file}")" || action_status=70
  asset_register_policy_script_hash="$(_cntools_action_advanced_asset_register_hash_file \
    "${asset_register_policy_script_file}")" || action_status=70
  asset_register_policy_id_hash="$(_cntools_action_advanced_asset_register_hash_file \
    "${asset_register_policy_id_file}")" || action_status=70
  if [[ -e "${asset_register_asset_file}" || -L "${asset_register_asset_file}" ]]; then
    _cntools_action_advanced_asset_register_file_validate \
      "${asset_register_asset_file}" 400,440,444,600,640,644 1048576 Y ||
      action_status=70
    asset_register_asset_hash="$(_cntools_action_advanced_asset_register_hash_file \
      "${asset_register_asset_file}")" || action_status=70
    "${asset_register_jq_path}" -e 'type == "object"' \
      "${asset_register_asset_file}" >/dev/null 2>&1 || action_status=70
    asset_register_original_asset_exists=Y
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  if [[ "${asset_register_original_asset_exists}" == Y ]] &&
     "${asset_register_jq_path}" -e '.metadata | type == "object"' \
       "${asset_register_asset_file}" >/dev/null 2>&1; then
    println DEBUG "${FG_YELLOW}Previous metadata registration found:${NC}"
    "${asset_register_jq_path}" -r '.metadata' "${asset_register_asset_file}"
    asset_register_sequence="$("${asset_register_jq_path}" -er \
      '.metadata.sequenceNumber // 0 | if type == "number" and floor == . and . >= 0 and . <= 2147483646 then tostring else error("sequence") end' \
      "${asset_register_asset_file}" 2>/dev/null)" || action_status=70
    asset_register_sequence=$((asset_register_sequence + 1))
    echo
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure; return 70; }

  println DEBUG 'Enter metadata (optional fields can be left empty)'
  if ! getAnswerAnyCust asset_register_meta_name \
      "Name        [${FG_RED}required${NC}] (Max. 50 chars) "; then
    _cntools_action_advanced_asset_register_precommit_abort
    return $?
  fi
  if ! _cntools_action_advanced_asset_register_text_valid \
      "${asset_register_meta_name}" 1 50; then
    println ERROR "\n${FG_RED}ERROR${NC}: Metadata name is a required field and limited to 50 chars in length!"
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  if ! getAnswerAnyCust asset_register_meta_desc \
      "Description [${FG_RED}required${NC}] (Max. 500 chars)"; then
    _cntools_action_advanced_asset_register_precommit_abort
    return $?
  fi
  if ! _cntools_action_advanced_asset_register_text_valid \
      "${asset_register_meta_desc}" 1 500; then
    println ERROR "\n${FG_RED}ERROR${NC}: Metadata description is a required field and limited to 500 chars in length!"
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  if ! getAnswerAnyCust asset_register_meta_ticker \
      "Ticker      [${FG_YELLOW}optional${NC}] (3-9 chars)     "; then
    _cntools_action_advanced_asset_register_precommit_abort
    return $?
  fi
  if [[ -n "${asset_register_meta_ticker}" ]] &&
     ! _cntools_action_advanced_asset_register_text_valid \
       "${asset_register_meta_ticker}" 3 9; then
    println ERROR "\n${FG_RED}ERROR${NC}: Metadata ticker is limited to 3-9 chars in length!"
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  if ! getAnswerAnyCust asset_register_meta_url \
      "URL         [${FG_YELLOW}optional${NC}] (Max. 250 chars)"; then
    _cntools_action_advanced_asset_register_precommit_abort
    return $?
  fi
  if [[ -n "${asset_register_meta_url}" ]] &&
     { ! _cntools_action_advanced_asset_register_text_valid \
         "${asset_register_meta_url}" 9 250 ||
       [[ ! "${asset_register_meta_url}" =~ ^https://[^[:space:]]+$ ]]; }; then
    println ERROR "\n${FG_RED}ERROR${NC}: Invalid metadata URL format or greater than 250 char limit!"
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  if ! getAnswerAnyCust asset_register_meta_decimals \
      "Decimals    [${FG_YELLOW}optional${NC}]"; then
    _cntools_action_advanced_asset_register_precommit_abort
    return $?
  fi
  if [[ -n "${asset_register_meta_decimals}" ]] &&
     ! _cntools_action_advanced_asset_register_uint_le \
       "${asset_register_meta_decimals}" 255; then
    println ERROR "\n${FG_RED}ERROR${NC}: Invalid decimal number"
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  if ! fileDialog "Logo/Icon   [${FG_YELLOW}optional${NC}] (PNG, <64kb)    " \
      "${TMP_DIR}/"; then
    _cntools_action_advanced_asset_register_precommit_abort
    return $?
  fi
  asset_register_meta_logo="${file:-}"
  if [[ -n "${asset_register_meta_logo}" ]]; then
    if [[ "${asset_register_meta_logo}" != /* ]] ||
       ! _cntools_action_advanced_asset_register_file_validate \
         "${asset_register_meta_logo}" 400,440,444,600,640,644 64000 N; then
      println ERROR "\n${FG_RED}ERROR${NC}: Logo must be a safe regular PNG file no larger than 64kb!"
      _cntools_action_advanced_asset_register_cleanup || {
        _cntools_action_advanced_asset_register_validation_failure; return 70; }
      waitToProceed
      return 0
    fi
    asset_register_logo_header="$("${asset_register_od_path}" -An -tx1 -N8 -v \
      "${asset_register_meta_logo}")" || asset_register_logo_header=""
    asset_register_logo_header="${asset_register_logo_header//[[:space:]]/}"
    if [[ "${asset_register_logo_header}" != 89504e470d0a1a0a ]]; then
      println ERROR "\n${FG_RED}ERROR${NC}: Logo not of PNG image type!"
      _cntools_action_advanced_asset_register_cleanup || {
        _cntools_action_advanced_asset_register_validation_failure; return 70; }
      waitToProceed
      return 0
    fi
  fi

  asset_register_transaction_directory="$("${asset_register_mktemp_path}" -d \
    "${asset_register_policy_folder}/.cntools-register.XXXXXXXX")" || {
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure; return 70; }
  "${asset_register_chmod_path}" 0700 \
    "${asset_register_transaction_directory}" || action_status=70
  "${asset_register_cp_path}" -- "${asset_register_policy_script_file}" \
    "${asset_register_transaction_directory}/policy.script" || action_status=70
  "${asset_register_cp_path}" -- "${asset_register_policy_sk_file}" \
    "${asset_register_transaction_directory}/policy.skey" || action_status=70
  "${asset_register_chmod_path}" 0600 \
    "${asset_register_transaction_directory}/policy.script" \
    "${asset_register_transaction_directory}/policy.skey" || action_status=70
  if [[ "${asset_register_original_asset_exists}" == Y ]]; then
    "${asset_register_cp_path}" -- "${asset_register_asset_file}" \
      "${asset_register_transaction_directory}/original.asset" || action_status=70
    "${asset_register_chmod_path}" 0600 \
      "${asset_register_transaction_directory}/original.asset" || action_status=70
    asset_register_backup_hash="$(_cntools_action_advanced_asset_register_hash_file \
      "${asset_register_transaction_directory}/original.asset")" || action_status=70
    [[ "${asset_register_backup_hash}" == "${asset_register_asset_hash}" ]] ||
      action_status=70
  fi
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure; return 70; }

  println DEBUG false '\nCreating Cardano Metadata Registry JSON draft file ...'
  _cntools_action_advanced_asset_register_tool_phase draft \
    "${asset_register_expected_registry}" || phase_status=$?
  if [[ "${phase_status}" == 1 ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator draft:\ntool diagnostic output was suppressed."
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  elif [[ "${phase_status}" != 0 ]]; then
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  println DEBUG " ${FG_GREEN}OK${NC}!"
  if [[ "${asset_register_sequence}" != 0 ]]; then
    println DEBUG false "Updating sequence number to ${FG_LBLUE}${asset_register_sequence}${NC} ..."
    "${asset_register_jq_path}" --argjson sequence "${asset_register_sequence}" \
      '.sequenceNumber = $sequence' \
      "${asset_register_transaction_directory}/${asset_register_expected_registry}" \
      > "${asset_register_transaction_directory}/registry.next" || action_status=70
    "${asset_register_chmod_path}" 0600 \
      "${asset_register_transaction_directory}/registry.next" || action_status=70
    _cntools_action_advanced_asset_register_json_validate \
      "${asset_register_transaction_directory}/registry.next" \
      "${asset_register_subject}" || action_status=70
    if [[ "${action_status}" == 0 ]]; then
      "${asset_register_mv_path}" -f -- \
        "${asset_register_transaction_directory}/registry.next" \
        "${asset_register_transaction_directory}/${asset_register_expected_registry}" ||
        action_status=70
    fi
    [[ "${action_status}" == 0 ]] || {
      _cntools_action_advanced_asset_register_cleanup || true
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    println DEBUG " ${FG_GREEN}OK${NC}!"
  fi

  phase_status=0
  println DEBUG false 'Signing draft file with policy signing key ...'
  _cntools_action_advanced_asset_register_tool_phase sign \
    "${asset_register_expected_registry}" || phase_status=$?
  if [[ "${phase_status}" == 1 ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator signing:\ntool diagnostic output was suppressed."
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  elif [[ "${phase_status}" != 0 ]]; then
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  println DEBUG " ${FG_GREEN}OK${NC}!"
  phase_status=0
  println DEBUG false 'Finalizing the draft file ...'
  _cntools_action_advanced_asset_register_tool_phase finalize \
    "${asset_register_expected_registry}" || phase_status=$?
  if [[ "${phase_status}" == 1 ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator finalize:\ntool diagnostic output was suppressed."
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  elif [[ "${phase_status}" != 0 ]]; then
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  println DEBUG " ${FG_GREEN}OK${NC}!"
  phase_status=0
  println DEBUG false 'Validating the final metadata registry submission file ...'
  _cntools_action_advanced_asset_register_tool_phase validate \
    "${asset_register_expected_registry}" || phase_status=$?
  if [[ "${phase_status}" == 1 ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during token-metadata-creator validation:\ntool diagnostic output was suppressed."
    _cntools_action_advanced_asset_register_cleanup || {
      _cntools_action_advanced_asset_register_validation_failure; return 70; }
    waitToProceed
    return 0
  elif [[ "${phase_status}" != 0 ]]; then
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  println DEBUG " ${FG_GREEN}OK${NC}!"

  if [[ "${asset_register_original_asset_exists}" == Y ]]; then
    _cntools_action_advanced_asset_register_file_validate \
      "${asset_register_transaction_directory}/original.asset" 600 1048576 Y ||
      action_status=70
    [[ "$(_cntools_action_advanced_asset_register_hash_file \
      "${asset_register_transaction_directory}/original.asset")" == \
      "${asset_register_backup_hash}" ]] || action_status=70
    "${asset_register_cp_path}" -- \
      "${asset_register_transaction_directory}/original.asset" \
      "${asset_register_transaction_directory}/asset.next" || action_status=70
  else
    builtin printf '{}\n' > \
      "${asset_register_transaction_directory}/asset.next" || action_status=70
  fi
  now="$("${asset_register_date_path}" -R)" || action_status=70
  "${asset_register_jq_path}" --arg name "${asset_register_meta_name}" \
    --arg description "${asset_register_meta_desc}" \
    --arg ticker "${asset_register_meta_ticker}" \
    --arg url "${asset_register_meta_url}" \
    --arg logo "${asset_register_meta_logo}" \
    --argjson sequence "${asset_register_sequence}" \
    --arg decimals "${asset_register_meta_decimals}" \
    --arg last_update "${now}" '
      . + {
        metadata: {
          name: $name,
          description: $description,
          ticker: $ticker,
          url: $url,
          logo: $logo,
          sequenceNumber: $sequence
        },
        lastUpdate: $last_update,
        lastAction: "created Cardano Token Registry submission file"
      } |
      if $decimals == "" then . else .metadata.decimals = ($decimals | tonumber) end
    ' "${asset_register_transaction_directory}/asset.next" \
    > "${asset_register_transaction_directory}/asset.next.tmp" || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    "${asset_register_mv_path}" -f -- \
      "${asset_register_transaction_directory}/asset.next.tmp" \
      "${asset_register_transaction_directory}/asset.next" || action_status=70
  fi
  "${asset_register_chmod_path}" 0644 \
    "${asset_register_transaction_directory}/asset.next" \
    "${asset_register_transaction_directory}/${asset_register_expected_registry}" ||
    action_status=70
  "${asset_register_jq_path}" -e 'type == "object" and (.metadata | type == "object")' \
    "${asset_register_transaction_directory}/asset.next" >/dev/null 2>&1 ||
    action_status=70
  _cntools_action_advanced_asset_register_json_validate \
    "${asset_register_transaction_directory}/${asset_register_expected_registry}" \
    "${asset_register_subject}" || action_status=70
  asset_register_registry_hash="$(_cntools_action_advanced_asset_register_hash_file \
    "${asset_register_transaction_directory}/${asset_register_expected_registry}")" ||
    action_status=70
  asset_register_next_asset_hash="$(_cntools_action_advanced_asset_register_hash_file \
    "${asset_register_transaction_directory}/asset.next")" || action_status=70
  _cntools_action_advanced_asset_register_remove_leaf \
    "${asset_register_transaction_directory}/policy.script" || action_status=70
  _cntools_action_advanced_asset_register_remove_leaf \
    "${asset_register_transaction_directory}/policy.skey" || action_status=70
  [[ "$(_cntools_action_advanced_asset_register_hash_file \
      "${asset_register_policy_sk_file}")" == "${asset_register_policy_sk_hash}" &&
     "$(_cntools_action_advanced_asset_register_hash_file \
      "${asset_register_policy_script_file}")" == "${asset_register_policy_script_hash}" &&
     "$(_cntools_action_advanced_asset_register_hash_file \
      "${asset_register_policy_id_file}")" == "${asset_register_policy_id_hash}" ]] ||
    action_status=70
  if [[ "${asset_register_original_asset_exists}" == Y ]]; then
    [[ -f "${asset_register_asset_file}" && ! -L "${asset_register_asset_file}" &&
       "$(_cntools_action_advanced_asset_register_hash_file \
         "${asset_register_asset_file}")" == "${asset_register_asset_hash}" ]] ||
      action_status=70
  else
    [[ ! -e "${asset_register_asset_file}" &&
       ! -L "${asset_register_asset_file}" ]] || action_status=70
  fi
  [[ ! -e "${asset_register_registry_file}" &&
     ! -L "${asset_register_registry_file}" ]] || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_register_cleanup || true
    _cntools_action_advanced_asset_register_validation_failure; return 70; }

  asset_register_registry_publish_attempt=Y
  "${asset_register_ln_path}" -- \
    "${asset_register_transaction_directory}/${asset_register_expected_registry}" \
    "${asset_register_registry_file}" || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    asset_register_registry_published=Y
    asset_register_registry_publish_attempt=N
    _cntools_action_advanced_asset_register_remove_leaf \
      "${asset_register_transaction_directory}/${asset_register_expected_registry}" ||
      action_status=70
  fi
  if [[ "${action_status}" != 0 ]] ||
     ! _cntools_action_advanced_asset_register_json_validate \
       "${asset_register_registry_file}" "${asset_register_subject}"; then
    action_status=70
  fi
  if [[ "${action_status}" == 0 ]]; then
    asset_register_asset_publish_attempt=Y
    "${asset_register_mv_path}" -f -- \
      "${asset_register_transaction_directory}/asset.next" \
      "${asset_register_asset_file}" || action_status=70
    if [[ "${action_status}" == 0 &&
          ! -e "${asset_register_transaction_directory}/asset.next" &&
          ! -L "${asset_register_transaction_directory}/asset.next" &&
          -f "${asset_register_asset_file}" &&
          ! -L "${asset_register_asset_file}" ]]; then
      asset_register_asset_published=Y
      asset_register_asset_publish_attempt=N
    else
      action_status=70
    fi
  fi
  if [[ "${action_status}" == 0 ]]; then
    # Both leaves are committed and verified while the cooperating lock is
    # still held. Cross the irreversible boundary before lock release so a
    # later signal or cleanup failure can never roll back without the lock or
    # report the already-committed registration as a failed transaction.
    trap '_cntools_action_advanced_asset_register_postcommit_cleanup; exit 0' \
      EXIT HUP INT TERM
    asset_register_registry_published=N
    asset_register_asset_published=N
    asset_register_registry_publish_attempt=N
    asset_register_asset_publish_attempt=N
    _cntools_action_advanced_asset_register_postcommit_cleanup
  fi
  if [[ "${action_status}" != 0 ]]; then
    if ! _cntools_action_advanced_asset_register_rollback_publish ||
       ! _cntools_action_advanced_asset_register_cleanup_transaction ||
       ! _cntools_action_advanced_asset_register_release_lock; then
      builtin printf '%s\n' \
        'CNTools asset-register action encountered an irreversible postcommit recovery failure.' >&2
      trap - EXIT HUP INT TERM
      return 70
    fi
    trap - EXIT HUP INT TERM
    _cntools_action_advanced_asset_register_validation_failure
    return 70
  fi
  trap - EXIT HUP INT TERM

  echo
  println 'Cardano Metadata Registry submission file successfully created!'
  println "Available at: ${asset_register_registry_file}"
  case "${NWMAGIC:-}" in
    764824073)
      println '\nPlease follow directions on CF Token Registry GitHub site to create a PR for the generated metadata file'
      println 'https://github.com/cardano-foundation/cardano-token-registry/wiki/How-to-submit-an-entry-to-the-registry'
      ;;
    *)
      println '\nPlease create a PR on IOHK Metadata Registry TestNet GitHub site for the generated metadata file'
      println 'https://github.com/input-output-hk/metadata-registry-testnet'
      ;;
  esac
  waitToProceed
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
