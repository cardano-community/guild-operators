#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Stage 4 hardened compatibility action for policy creation. Sourcing defines
# functions only; the dispatcher supplies authenticated context and legacy UI.

_cntools_action_advanced_asset_create_policy_validation_failure() {
  builtin printf '%s\n' \
    'CNTools asset-create-policy action failed validation.' >&2
  return 70
}

_cntools_action_advanced_asset_create_policy_remove_leaf() {
  local target="${1:-}"

  [[ -n "${target}" ]] || return 0
  if [[ -e "${target}" || -L "${target}" ]]; then
    [[ ! -d "${target}" || -L "${target}" ]] || return 1
    "${asset_create_rm_path}" -f -- "${target}" >/dev/null 2>&1 || return 1
  fi
}

_cntools_action_advanced_asset_create_policy_cleanup_directory() {
  local directory="${1:-}" filename="" cleanup_failed=0

  [[ -n "${directory}" ]] || return 0
  for filename in "${asset_create_policy_id_filename}" \
      "${asset_create_policy_script_filename}" \
      "${asset_create_policy_sk_filename}" \
      "${asset_create_policy_vk_filename}" .keygen.log .keyhash.log \
      .scripthash.log; do
    _cntools_action_advanced_asset_create_policy_remove_leaf \
      "${directory}/${filename}" || cleanup_failed=1
  done
  if [[ -d "${directory}" && ! -L "${directory}" ]]; then
    "${asset_create_rmdir_path}" -- "${directory}" >/dev/null 2>&1 ||
      cleanup_failed=1
  elif [[ -e "${directory}" || -L "${directory}" ]]; then
    cleanup_failed=1
  fi
  return "${cleanup_failed}"
}

_cntools_action_advanced_asset_create_policy_cleanup() {
  local nested_staging="" cleanup_failed=0

  trap - EXIT HUP INT TERM
  if [[ "${asset_create_published_uncommitted:-N}" == Y &&
        -n "${asset_create_final_directory:-}" ]]; then
    _cntools_action_advanced_asset_create_policy_cleanup_directory \
      "${asset_create_final_directory}" || cleanup_failed=1
  fi
  if [[ -n "${asset_create_staging_directory:-}" ]]; then
    _cntools_action_advanced_asset_create_policy_cleanup_directory \
      "${asset_create_staging_directory}" || cleanup_failed=1
    if [[ -n "${asset_create_final_directory:-}" ]]; then
      nested_staging="${asset_create_final_directory}/${asset_create_staging_directory##*/}"
      if [[ "${nested_staging}" != "${asset_create_staging_directory}" ]]; then
        _cntools_action_advanced_asset_create_policy_cleanup_directory \
          "${nested_staging}" || cleanup_failed=1
      fi
    fi
  fi
  if [[ -n "${asset_create_lock_directory:-}" ]]; then
    if [[ -d "${asset_create_lock_directory}" &&
          ! -L "${asset_create_lock_directory}" ]]; then
      "${asset_create_rmdir_path}" -- "${asset_create_lock_directory}" \
        >/dev/null 2>&1 || cleanup_failed=1
    elif [[ -e "${asset_create_lock_directory}" ||
            -L "${asset_create_lock_directory}" ]]; then
      cleanup_failed=1
    fi
  fi
  asset_create_staging_directory=""
  asset_create_lock_directory=""
  asset_create_published_uncommitted=N
  return "${cleanup_failed}"
}

_cntools_action_advanced_asset_create_policy_uint_le() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]*)$ &&
     "${maximum}" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  (( ${#value} < ${#maximum} )) && return 0
  (( ${#value} == ${#maximum} )) || return 1
  [[ "${value}" == "${maximum}" || "${value}" < "${maximum}" ]]
}

_cntools_action_advanced_asset_create_policy_file_validate() {
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

_cntools_action_advanced_asset_create_policy_log_reset() {
  local target="${1:-}"

  [[ "${target}" == "${asset_create_staging_directory}/.keygen.log" ||
     "${target}" == "${asset_create_staging_directory}/.keyhash.log" ||
     "${target}" == "${asset_create_staging_directory}/.scripthash.log" ]] ||
    return 1
  ( umask 077; : > "${target}" ) || return 1
  "${asset_create_chmod_path}" 0600 "${target}" || return 1
  _cntools_action_advanced_asset_create_policy_file_validate \
    "${target}" 600 1 Y
}

_cntools_action_advanced_asset_create_policy_key_validate() {
  local target="${1:-}" expected_type="${2:-}"

  _cntools_action_advanced_asset_create_policy_file_validate \
    "${target}" 400,600 65536 N || return 1
  "${asset_create_jq_path}" -e --arg expected "${expected_type}" '
    type == "object" and
    keys == ["cborHex", "description", "type"] and
    .type == $expected and
    (.description | type == "string" and length <= 1024 and
      (test("[\\x{0000}-\\x{001F}\\x{007F}-\\x{009F}]") | not)) and
    (.cborHex | type == "string" and length >= 64 and length <= 2048 and
      (length % 2 == 0) and test("^[0-9a-f]+$"))
  ' "${target}" >/dev/null 2>&1
}

_cntools_action_advanced_asset_create_policy_script_validate() {
  local target="${1:-}" ttl="${2:-}" key_hash="${3:-}"

  _cntools_action_advanced_asset_create_policy_file_validate \
    "${target}" 600 4096 N || return 1
  if [[ "${ttl}" == 0 ]]; then
    "${asset_create_jq_path}" -e --arg key_hash "${key_hash}" '
      type == "object" and keys == ["keyHash", "type"] and
      .keyHash == $key_hash and .type == "sig"
    ' "${target}" >/dev/null 2>&1
  else
    "${asset_create_jq_path}" -e --arg key_hash "${key_hash}" \
      --argjson ttl "${ttl}" '
        type == "object" and keys == ["scripts", "type"] and
        .type == "all" and (.scripts | type == "array" and length == 2) and
        .scripts[0] == {"slot": $ttl, "type": "before"} and
        .scripts[1] == {"keyHash": $key_hash, "type": "sig"}
      ' "${target}" >/dev/null 2>&1
  fi
}

_cntools_action_advanced_asset_create_policy_release_lock() {
  [[ -n "${asset_create_lock_directory:-}" ]] || return 0
  [[ -d "${asset_create_lock_directory}" &&
     ! -L "${asset_create_lock_directory}" ]] || return 1
  "${asset_create_rmdir_path}" -- "${asset_create_lock_directory}" ||
    return 1
  asset_create_lock_directory=""
}

_cntools_action_advanced_asset_create_policy_published_validate() {
  local directory="${1:-}" ttl="${2:-}" key_hash="${3:-}"
  local policy_id="${4:-}" metadata="" owner="" mode="" links="" size=""
  local unexpected=""

  [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${directory}" || return 1
  metadata="$(_cntools_result_stat "${directory}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${mode}" == 755 ]] || return 1
  _cntools_action_advanced_asset_create_policy_key_validate \
    "${directory}/${asset_create_policy_vk_filename}" \
    PaymentVerificationKeyShelley_ed25519 || return 1
  _cntools_action_advanced_asset_create_policy_key_validate \
    "${directory}/${asset_create_policy_sk_filename}" \
    PaymentSigningKeyShelley_ed25519 || return 1
  _cntools_action_advanced_asset_create_policy_script_validate \
    "${directory}/${asset_create_policy_script_filename}" \
    "${ttl}" "${key_hash}" || return 1
  _cntools_action_advanced_asset_create_policy_file_validate \
    "${directory}/${asset_create_policy_id_filename}" 600 128 N || return 1
  [[ "$(< "${directory}/${asset_create_policy_id_filename}")" == \
     "${policy_id}" ]] || return 1
  unexpected="$("${asset_create_find_path}" "${directory}" -mindepth 1 \
    -maxdepth 1 ! \( -type f \( \
      -name "${asset_create_policy_vk_filename}" -o \
      -name "${asset_create_policy_sk_filename}" -o \
      -name "${asset_create_policy_script_filename}" -o \
      -name "${asset_create_policy_id_filename}" \) \) \
    -print -quit 2>/dev/null)" || return 1
  [[ -z "${unexpected}" ]]
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}" context_mode=""
  local asset_create_asset_root="" asset_create_policy_input=""
  local asset_create_policy_name="" asset_create_policy_key_hash=""
  local asset_create_policy_id="" asset_create_ttl_input="" ttl=0
  local asset_create_tip="" asset_create_slot_delta=0
  local asset_create_tool_status=0
  local asset_create_private_parent="" asset_create_metadata=""
  local asset_create_owner="" asset_create_mode="" asset_create_links=""
  local asset_create_size="" asset_create_staging_directory=""
  local asset_create_lock_directory="" asset_create_final_directory=""
  local asset_create_published_uncommitted=N
  local asset_create_policy_vk_filename="${ASSET_POLICY_VK_FILENAME:-}"
  local asset_create_policy_sk_filename="${ASSET_POLICY_SK_FILENAME:-}"
  local asset_create_policy_script_filename="${ASSET_POLICY_SCRIPT_FILENAME:-}"
  local asset_create_policy_id_filename="${ASSET_POLICY_ID_FILENAME:-}"
  local asset_create_policy_vk_file="" asset_create_policy_sk_file=""
  local asset_create_policy_script_file="" asset_create_policy_id_file=""
  local asset_create_keygen_log="" asset_create_keyhash_log=""
  local asset_create_scripthash_log="" asset_create_jq_path=""
  local asset_create_mktemp_path="" asset_create_mkdir_path=""
  local asset_create_chmod_path="" asset_create_rm_path=""
  local asset_create_rmdir_path="" asset_create_mv_path=""
  local asset_create_find_path=""
  local asset_create_ccli_path="" tool="" action_status=0
  local LC_ALL=C
  local -a asset_create_keygen_argv=() asset_create_keyhash_argv=()
  local -a asset_create_scripthash_argv=()

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
     ! builtin declare -F getSlotTipRef >/dev/null 2>&1 ||
     ! builtin declare -F getDateFromSlot >/dev/null 2>&1 ||
     ! builtin declare -F timeLeft >/dev/null 2>&1; then
    _cntools_action_advanced_asset_create_policy_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" ]] || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  asset_create_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${asset_create_private_parent}" || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  for tool in jq mktemp mkdir chmod rm rmdir mv find; do
    case "${tool}" in
      jq) _cntools_registry_tool_path jq asset_create_jq_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp asset_create_mktemp_path || action_status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir asset_create_mkdir_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod asset_create_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm asset_create_rm_path || action_status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir asset_create_rmdir_path || action_status=70 ;;
      mv) _cntools_registry_tool_path mv asset_create_mv_path || action_status=70 ;;
      find) _cntools_registry_tool_path find asset_create_find_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  case "${CCLI:-}" in
    /*)
      asset_create_ccli_path="${CCLI}"
      [[ "${asset_create_ccli_path}" != *//* &&
         "${asset_create_ccli_path}" != *\\* &&
         ! "${asset_create_ccli_path}" =~ [[:cntrl:]] &&
         -f "${asset_create_ccli_path}" &&
         ! -L "${asset_create_ccli_path}" &&
         -x "${asset_create_ccli_path}" ]] || {
        _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
      ;;
    [a-z][a-z0-9-]*)
      _cntools_registry_tool_path "${CCLI}" asset_create_ccli_path || {
        _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
      ;;
    *)
      _cntools_action_advanced_asset_create_policy_validation_failure
      return 70
      ;;
  esac
  [[ "${ASSET_FOLDER:-}" == /* && -d "${ASSET_FOLDER}" &&
     ! -L "${ASSET_FOLDER}" ]] || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  _cntools_registry_path_has_no_symlinks "${ASSET_FOLDER}" || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  asset_create_asset_root="$(cd -P -- "${ASSET_FOLDER}" && pwd -P)" || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  asset_create_metadata="$(_cntools_result_stat "${asset_create_asset_root}")" || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  IFS=$'\t' read -r asset_create_owner asset_create_mode \
    asset_create_links asset_create_size <<< "${asset_create_metadata}" || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  asset_create_mode="${asset_create_mode#0}"
  [[ "${asset_create_owner}" == "${EUID}" &&
     "${asset_create_mode}" =~ ^[37][0145][0145]$ ]] || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  for tool in "${asset_create_policy_vk_filename}" \
      "${asset_create_policy_sk_filename}" \
      "${asset_create_policy_script_filename}" \
      "${asset_create_policy_id_filename}"; do
    [[ "${tool}" =~ ^[A-Za-z0-9._-]{1,128}$ &&
       "${tool}" != . && "${tool}" != .. ]] || {
      _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  done
  [[ "${asset_create_policy_vk_filename}" != "${asset_create_policy_sk_filename}" &&
     "${asset_create_policy_vk_filename}" != "${asset_create_policy_script_filename}" &&
     "${asset_create_policy_vk_filename}" != "${asset_create_policy_id_filename}" &&
     "${asset_create_policy_sk_filename}" != "${asset_create_policy_script_filename}" &&
     "${asset_create_policy_sk_filename}" != "${asset_create_policy_id_filename}" &&
     "${asset_create_policy_script_filename}" != "${asset_create_policy_id_filename}" ]] || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  _cntools_action_advanced_asset_create_policy_uint_le \
    "${SLOT_LENGTH:-}" 86400 && [[ "${SLOT_LENGTH}" != 0 ]] || {
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }

  umask 077
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> ADVANCED >> ASSET >> CREATE POLICY'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  if ! getAnswerAnyCust asset_create_policy_input \
      'Internal name to give the generated policy'; then
    return 0
  fi
  asset_create_policy_name="${asset_create_policy_input//[^A-Za-z0-9]/_}"
  if [[ -z "${asset_create_policy_name}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: Empty policy name, please retry!"
    waitToProceed
    return 0
  fi
  if (( ${#asset_create_policy_name} > 128 )) ||
     [[ "${asset_create_policy_name}" != *[A-Za-z0-9]* ]]; then
    println ERROR "${FG_RED}ERROR${NC}: Policy name must contain an ASCII letter or digit and be at most 128 characters."
    waitToProceed
    return 0
  fi
  asset_create_final_directory="${asset_create_asset_root}/${asset_create_policy_name}"
  asset_create_lock_directory="${asset_create_asset_root}/.${asset_create_policy_name}.create.lock"
  echo
  if [[ -e "${asset_create_final_directory}" ||
        -L "${asset_create_final_directory}" ]]; then
    println "${FG_RED}WARN${NC}: A policy ${FG_GREEN}${asset_create_policy_name}${NC} already exist!"
    println '      Choose another name or delete the existing one'
    waitToProceed
    return 0
  fi
  if ! "${asset_create_mkdir_path}" -m 0700 -- \
      "${asset_create_lock_directory}" 2>/dev/null; then
    _cntools_action_advanced_asset_create_policy_validation_failure
    return 70
  fi
  trap '_cntools_action_advanced_asset_create_policy_cleanup' EXIT
  trap '_cntools_action_advanced_asset_create_policy_cleanup; exit 70' HUP INT TERM
  if [[ -e "${asset_create_final_directory}" ||
        -L "${asset_create_final_directory}" ]]; then
    _cntools_action_advanced_asset_create_policy_cleanup || {
      _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
    println "${FG_RED}WARN${NC}: A policy ${FG_GREEN}${asset_create_policy_name}${NC} already exist!"
    println '      Choose another name or delete the existing one'
    waitToProceed
    return 0
  fi
  asset_create_staging_directory="$(${asset_create_mktemp_path} -d \
    "${asset_create_asset_root}/.${asset_create_policy_name}.staging.XXXXXXXX")" || {
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  "${asset_create_chmod_path}" 0700 "${asset_create_staging_directory}" || {
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
  asset_create_policy_vk_file="${asset_create_staging_directory}/${asset_create_policy_vk_filename}"
  asset_create_policy_sk_file="${asset_create_staging_directory}/${asset_create_policy_sk_filename}"
  asset_create_policy_script_file="${asset_create_staging_directory}/${asset_create_policy_script_filename}"
  asset_create_policy_id_file="${asset_create_staging_directory}/${asset_create_policy_id_filename}"
  asset_create_keygen_log="${asset_create_staging_directory}/.keygen.log"
  asset_create_keyhash_log="${asset_create_staging_directory}/.keyhash.log"
  asset_create_scripthash_log="${asset_create_staging_directory}/.scripthash.log"
  asset_create_keygen_argv=("${asset_create_ccli_path}" address key-gen
    --verification-key-file "${asset_create_policy_vk_file}"
    --signing-key-file "${asset_create_policy_sk_file}")
  asset_create_keyhash_argv=("${asset_create_ccli_path}" address key-hash
    --payment-verification-key-file "${asset_create_policy_vk_file}")
  asset_create_scripthash_argv=("${asset_create_ccli_path}" hash script
    --script-file "${asset_create_policy_script_file}"
    --out-file "${asset_create_policy_id_file}")

  _cntools_action_advanced_asset_create_policy_log_reset \
    "${asset_create_keygen_log}" || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    println ACTION "cardano-cli address key-gen --verification-key-file ${asset_create_policy_vk_file} --signing-key-file ${asset_create_policy_sk_file}"
    "${asset_create_keygen_argv[@]}" >"${asset_create_keygen_log}" 2>&1 ||
      asset_create_tool_status=$?
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure
    return 70
  elif [[ "${asset_create_tool_status}" != 0 ]]; then
    println ERROR "${FG_RED}ERROR${NC}: failure during policy key creation!\ncardano-cli command failed; diagnostic output was suppressed."
    _cntools_action_advanced_asset_create_policy_cleanup || {
      _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  "${asset_create_chmod_path}" 0600 "${asset_create_policy_vk_file}" \
    "${asset_create_policy_sk_file}" || action_status=70
  _cntools_action_advanced_asset_create_policy_key_validate \
    "${asset_create_policy_vk_file}" PaymentVerificationKeyShelley_ed25519 ||
    action_status=70
  _cntools_action_advanced_asset_create_policy_key_validate \
    "${asset_create_policy_sk_file}" PaymentSigningKeyShelley_ed25519 ||
    action_status=70
  _cntools_action_advanced_asset_create_policy_remove_leaf \
    "${asset_create_keygen_log}" || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }

  _cntools_action_advanced_asset_create_policy_log_reset \
    "${asset_create_keyhash_log}" || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    println ACTION "cardano-cli address key-hash --payment-verification-key-file ${asset_create_policy_vk_file}"
    "${asset_create_keyhash_argv[@]}" >"${asset_create_keyhash_log}" 2>&1 ||
      asset_create_tool_status=$?
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure
    return 70
  elif [[ "${asset_create_tool_status}" != 0 ]]; then
    println ERROR "${FG_RED}ERROR${NC}: failure during policy verification key hashing!\ncardano-cli command failed; diagnostic output was suppressed."
    _cntools_action_advanced_asset_create_policy_cleanup || {
      _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  _cntools_action_advanced_asset_create_policy_file_validate \
    "${asset_create_keyhash_log}" 600 128 N || action_status=70
  asset_create_policy_key_hash="$(< "${asset_create_keyhash_log}")"
  [[ "${asset_create_policy_key_hash}" =~ ^[0-9a-f]{56}$ ]] || action_status=70
  _cntools_action_advanced_asset_create_policy_remove_leaf \
    "${asset_create_keyhash_log}" || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }

  println DEBUG 'How long do you want the policy to be valid? (0/blank=unlimited)'
  println DEBUG "${FG_YELLOW}Setting a limit will prevent you from minting/burning assets after the policy expire !!\nLeave blank/unlimited if unsure and just press enter${NC}"
  if ! getAnswerAnyCust asset_create_ttl_input 'TTL (in seconds)'; then
    _cntools_action_advanced_asset_create_policy_cleanup || {
      _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
    return 0
  fi
  asset_create_ttl_input="${asset_create_ttl_input:-0}"
  if ! _cntools_action_advanced_asset_create_policy_uint_le \
      "${asset_create_ttl_input}" 3155760000; then
    println ERROR "\n${FG_RED}ERROR${NC}: TTL must be 0/blank or a canonical integer between 1 and 3155760000."
    _cntools_action_advanced_asset_create_policy_cleanup || {
      _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  if [[ "${asset_create_ttl_input}" == 0 ]]; then
    printf '{ "keyHash": "%s", "type": "sig" }\n' \
      "${asset_create_policy_key_hash}" > "${asset_create_policy_script_file}" ||
      action_status=70
  else
    asset_create_tip="$(getSlotTipRef)" || asset_create_tip=""
    _cntools_action_advanced_asset_create_policy_uint_le \
      "${asset_create_tip}" 9007199254740991 || action_status=70
    asset_create_slot_delta=$((asset_create_ttl_input / SLOT_LENGTH))
    if (( asset_create_tip > 9007199254740991 - asset_create_slot_delta )); then
      action_status=70
    else
      ttl=$((asset_create_tip + asset_create_slot_delta))
      printf '{ "type": "all", "scripts": [ { "slot": %s, "type": "before" }, { "keyHash": "%s", "type": "sig" } ] }\n' \
        "${ttl}" "${asset_create_policy_key_hash}" \
        > "${asset_create_policy_script_file}" || action_status=70
    fi
  fi
  "${asset_create_chmod_path}" 0600 "${asset_create_policy_script_file}" ||
    action_status=70
  _cntools_action_advanced_asset_create_policy_script_validate \
    "${asset_create_policy_script_file}" "${ttl}" \
    "${asset_create_policy_key_hash}" || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }

  _cntools_action_advanced_asset_create_policy_log_reset \
    "${asset_create_scripthash_log}" || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    println ACTION "cardano-cli hash script --script-file ${asset_create_policy_script_file} --out-file ${asset_create_policy_id_file}"
    asset_create_tool_status=0
    "${asset_create_scripthash_argv[@]}" \
      >"${asset_create_scripthash_log}" 2>&1 || asset_create_tool_status=$?
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure
    return 70
  elif [[ "${asset_create_tool_status}" != 0 ]]; then
    println ERROR "${FG_RED}ERROR${NC}: failure during policy ID generation!\ncardano-cli command failed; diagnostic output was suppressed."
    _cntools_action_advanced_asset_create_policy_cleanup || {
      _cntools_action_advanced_asset_create_policy_validation_failure; return 70; }
    waitToProceed
    return 0
  fi
  _cntools_action_advanced_asset_create_policy_file_validate \
    "${asset_create_policy_id_file}" 400,600 128 N || action_status=70
  asset_create_policy_id="$(< "${asset_create_policy_id_file}")"
  [[ "${asset_create_policy_id}" =~ ^[0-9a-f]{56}$ ]] || action_status=70
  _cntools_action_advanced_asset_create_policy_remove_leaf \
    "${asset_create_scripthash_log}" || action_status=70
  "${asset_create_chmod_path}" 0600 "${asset_create_policy_vk_file}" \
    "${asset_create_policy_sk_file}" "${asset_create_policy_script_file}" \
    "${asset_create_policy_id_file}" || action_status=70
  "${asset_create_chmod_path}" 0755 "${asset_create_staging_directory}" ||
    action_status=70
  [[ "${action_status}" == 0 && ! -e "${asset_create_final_directory}" &&
     ! -L "${asset_create_final_directory}" ]] || action_status=70
  if [[ "${action_status}" == 0 ]]; then
    # The per-policy lock serializes cooperating CNTools processes. As with the
    # rest of the compatibility runner, hostile same-UID replacement is not a
    # security boundary. On an unchanged destination this same-filesystem move
    # publishes the complete directory with one atomic rename.
    "${asset_create_mv_path}" -n -- "${asset_create_staging_directory}" \
      "${asset_create_final_directory}" || action_status=70
    if [[ "${action_status}" == 0 &&
          ! -e "${asset_create_staging_directory}" &&
          ! -L "${asset_create_staging_directory}" ]] &&
       _cntools_action_advanced_asset_create_policy_published_validate \
         "${asset_create_final_directory}" "${ttl}" \
         "${asset_create_policy_key_hash}" "${asset_create_policy_id}"; then
      asset_create_published_uncommitted=Y
    else
      action_status=70
    fi
  fi
  if [[ "${action_status}" == 0 ]]; then
    _cntools_action_advanced_asset_create_policy_release_lock ||
      action_status=70
  fi
  if [[ "${action_status}" != 0 ]]; then
    _cntools_action_advanced_asset_create_policy_cleanup || true
    _cntools_action_advanced_asset_create_policy_validation_failure
    return 70
  fi
  asset_create_staging_directory=""
  asset_create_published_uncommitted=N
  trap - EXIT HUP INT TERM

  echo
  println "Policy Name   : ${FG_GREEN}${asset_create_policy_name}${NC}"
  println "Policy ID     : ${FG_LGRAY}${asset_create_policy_id}${NC}"
  if [[ "${asset_create_ttl_input}" == 0 ]]; then
    println "Policy Expire : ${FG_LGRAY}unlimited${NC}"
  else
    println "Policy Expire : ${FG_LGRAY}$(getDateFromSlot "${ttl}" '%(%F %T %Z)T')${NC}, ${FG_LGRAY}$(timeLeft $((ttl-asset_create_tip)))${NC} remaining"
  fi
  println DEBUG '\nYou can now start minting your custom assets using this Policy!'
  waitToProceed
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
