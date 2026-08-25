#!/usr/bin/env bash
# shellcheck disable=SC2154
# Stage 4 compatibility action for hardened MultiSig wallet creation.
# Sourcing defines functions only. The compatibility dispatcher supplies an
# authenticated context and the inherited CNTools prompt/display/wait helpers.

_cntools_action_advanced_multisig_create_validation_failure() {
  builtin printf '%s\n' \
    'CNTools MultiSig wallet creation action failed validation.' >&2
  return 70
}

_cntools_action_advanced_multisig_create_warning() {
  builtin printf '%s\n' \
    'WARNING: MultiSig wallet was created, but administrative cleanup needs attention.' >&2
}

_cntools_action_advanced_multisig_create_terminal_valid() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ && "${#value}" -le "${maximum}" &&
     ! "${value}" =~ [[:cntrl:]] && "${value}" != *\\* ]]
}

_cntools_action_advanced_multisig_create_name_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_advanced_multisig_create_uint_valid() {
  local value="${1:-}" maximum="${2:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,15})$ &&
     "${maximum}" =~ ^[1-9][0-9]{0,15}$ ]] || return 1
  (( 10#${value} <= 10#${maximum} ))
}

_cntools_action_advanced_multisig_create_hash_valid() {
  [[ "${1:-}" =~ ^[0-9a-f]{56}$ ]]
}

_cntools_action_advanced_multisig_create_metadata() {
  local target="${1:-}" output_variable="${2:-}" captured=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  captured="$(_cntools_result_stat "${target}")" || return 1
  builtin printf -v "${output_variable}" '%s' "${captured}"
}

_cntools_action_advanced_multisig_create_directory_validate() {
  local target="${1:-}" expected_modes="${2:-}"
  local metadata="" owner="" mode="" links="" size=""

  [[ -d "${target}" && ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_advanced_multisig_create_metadata \
    "${target}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ",${expected_modes}," == *",${mode},"* ]]
}

_cntools_action_advanced_multisig_create_file_validate() {
  local target="${1:-}" maximum_size="${2:-}"
  local expected_modes="${3:-600}" minimum_size="${4:-1}"
  local expected_links="${5:-1}"
  local metadata="" owner="" mode="" links="" size=""

  [[ "${maximum_size}" =~ ^[1-9][0-9]*$ &&
     "${minimum_size}" =~ ^[0-9]+$ &&
     "${expected_links}" =~ ^[1-9][0-9]*$ && -f "${target}" &&
     ! -L "${target}" ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  _cntools_action_advanced_multisig_create_metadata \
    "${target}" metadata || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" &&
     ",${expected_modes}," == *",${mode},"* &&
     "${links}" == "${expected_links}" &&
     "${size}" =~ ^[0-9]+$ && "${size}" -ge "${minimum_size}" &&
     "${size}" -le "${maximum_size}" ]]
}

_cntools_action_advanced_multisig_create_identity() {
  local target="${1:-}" output_variable="${2:-}" captured=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if captured="$("${multisig_create_stat_path}" -f $'%d\t%i' \
      "${target}" 2>/dev/null)"; then
    :
  else
    captured="$("${multisig_create_stat_path}" -c $'%d\t%i' -- \
      "${target}" 2>/dev/null)" || return 1
  fi
  [[ "${captured}" =~ ^[0-9]+$'\t'[0-9]+$ ]] || return 1
  builtin printf -v "${output_variable}" '%s' "${captured}"
}

_cntools_action_advanced_multisig_create_digest() {
  local target="${1:-}" output_variable="${2:-}" captured=""

  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "${multisig_create_hash_kind:-}" in
    sha256sum)
      captured="$("${multisig_create_hash_path}" "${target}" \
        2>/dev/null)" || return 1
      ;;
    shasum)
      captured="$("${multisig_create_hash_path}" -a 256 "${target}" \
        2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  captured="${captured%% *}"
  [[ "${captured}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  builtin printf -v "${output_variable}" '%s' "${captured,,}"
}

_cntools_action_advanced_multisig_create_root_authority() {
  local current=""

  _cntools_action_advanced_multisig_create_directory_validate \
    "${multisig_create_root}" '700,750,755' &&
    _cntools_action_advanced_multisig_create_identity \
      "${multisig_create_root}" current &&
    [[ "${current}" == "${multisig_create_root_identity:-}" ]]
}

_cntools_action_advanced_multisig_create_private_parent_authority() {
  local current=""

  _cntools_result_private_parent_validate "${multisig_create_private_parent}" &&
    _cntools_action_advanced_multisig_create_identity \
      "${multisig_create_private_parent}" current &&
    [[ "${current}" == "${multisig_create_private_parent_identity:-}" ]]
}

_cntools_action_advanced_multisig_create_private_temp_path_valid() {
  local target="${1:-}" label="${2:-}" prefix="" suffix=""

  [[ "${label}" =~ ^[a-z0-9-]{1,48}$ ]] || return 1
  prefix="${multisig_create_private_parent}/multisig-create-${label}."
  [[ "${target}" == "${prefix}"* ]] || return 1
  suffix="${target#"${prefix}"}"
  [[ "${suffix}" =~ ^[A-Za-z0-9]{8}$ ]]
}

_cntools_action_advanced_multisig_create_private_file_authority() {
  local target="${1:-}" maximum_size="${2:-65536}"
  local minimum_size="${3:-0}" leaf="" current=""

  [[ "${target}" == "${multisig_create_private_parent}/"* ]] || return 1
  leaf="${target#"${multisig_create_private_parent}/"}"
  [[ "${leaf}" =~ ^multisig-create-[a-z0-9-]{1,48}\.[A-Za-z0-9]{8}$ &&
     -n "${multisig_create_private_file_identities[${target}]+set}" ]] ||
    return 1
  _cntools_action_advanced_multisig_create_private_parent_authority &&
    _cntools_action_advanced_multisig_create_file_validate \
      "${target}" "${maximum_size}" 600 "${minimum_size}" &&
    _cntools_action_advanced_multisig_create_identity "${target}" current &&
    [[ "${current}" == "${multisig_create_private_file_identities[${target}]}" ]]
}

_cntools_action_advanced_multisig_create_stage_path_valid() {
  local prefix="" suffix=""

  prefix="${multisig_create_root}/.${multisig_create_name}.cntools-multisig-create.stage."
  [[ "${multisig_create_stage}" == "${prefix}"* ]] || return 1
  suffix="${multisig_create_stage#"${prefix}"}"
  [[ "${suffix}" =~ ^[A-Za-z0-9]{8}$ ]]
}

_cntools_action_advanced_multisig_create_lock_authority() {
  local current=""

  _cntools_action_advanced_multisig_create_root_authority &&
    _cntools_action_advanced_multisig_create_directory_validate \
      "${multisig_create_lock}" 700 &&
    _cntools_action_advanced_multisig_create_identity \
      "${multisig_create_lock}" current &&
    [[ "${current}" == "${multisig_create_lock_identity:-}" ]]
}

_cntools_action_advanced_multisig_create_stage_authority() {
  local current=""

  _cntools_action_advanced_multisig_create_root_authority &&
    _cntools_action_advanced_multisig_create_stage_path_valid &&
    _cntools_action_advanced_multisig_create_directory_validate \
      "${multisig_create_stage}" 700 &&
    _cntools_action_advanced_multisig_create_identity \
      "${multisig_create_stage}" current &&
    [[ "${current}" == "${multisig_create_stage_identity:-}" ]]
}

_cntools_action_advanced_multisig_create_stage_leaf_authority() {
  local leaf="${1:-}" maximum_size="${2:-16384}"
  local minimum_size="${3:-0}" target="" current=""

  [[ "${leaf}" != */* && -n "${multisig_create_leaf_set[${leaf}]+set}" &&
     -n "${multisig_create_leaf_identities[${leaf}]+set}" ]] || return 1
  target="${multisig_create_stage}/${leaf}"
  _cntools_action_advanced_multisig_create_stage_authority &&
    _cntools_action_advanced_multisig_create_file_validate \
      "${target}" "${maximum_size}" 600 "${minimum_size}" &&
    _cntools_action_advanced_multisig_create_identity "${target}" current &&
    [[ "${current}" == "${multisig_create_leaf_identities[${leaf}]}" ]]
}

_cntools_action_advanced_multisig_create_stage_link_pair_authority() {
  local source="${1:-}" leaf="${2:-}" target="" source_identity=""
  local target_identity=""

  [[ -n "${multisig_create_private_file_identities[${source}]+set}" &&
     "${leaf}" != */* && -n "${multisig_create_leaf_set[${leaf}]+set}" ]] ||
    return 1
  target="${multisig_create_stage}/${leaf}"
  source_identity="${multisig_create_private_file_identities[${source}]}"
  _cntools_action_advanced_multisig_create_private_parent_authority &&
    _cntools_action_advanced_multisig_create_stage_authority &&
    _cntools_action_advanced_multisig_create_file_validate \
      "${source}" 1 600 0 2 &&
    _cntools_action_advanced_multisig_create_file_validate \
      "${target}" 1 600 0 2 &&
    _cntools_action_advanced_multisig_create_identity \
      "${source}" source_identity &&
    [[ "${source_identity}" == "${multisig_create_private_file_identities[${source}]}" ]] &&
    _cntools_action_advanced_multisig_create_identity \
      "${target}" target_identity &&
    [[ "${target_identity}" == "${source_identity}" ]]
}

_cntools_action_advanced_multisig_create_stage_leaf_create() {
  local leaf="${1:-}" index="${2:-}" source="" target="" identity=""

  [[ "${index}" =~ ^[0-9]+$ && "${leaf}" != */* &&
     -n "${multisig_create_leaf_set[${leaf}]+set}" &&
     -z "${multisig_create_leaf_identities[${leaf}]+set}" ]] || return 70
  target="${multisig_create_stage}/${leaf}"
  _cntools_action_advanced_multisig_create_stage_authority || return 70
  [[ ! -e "${target}" && ! -L "${target}" ]] || return 70
  _cntools_action_advanced_multisig_create_private_temp \
    "stage-leaf-${index}" source || return 70
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${source}" 1 0 || return 70
  "${multisig_create_ln_path}" -- "${source}" "${target}" \
    >/dev/null 2>&1 || true
  _cntools_action_advanced_multisig_create_stage_link_pair_authority \
    "${source}" "${leaf}" || return 70
  "${multisig_create_rm_path}" -f -- "${source}" >/dev/null 2>&1 || true
  [[ ! -e "${source}" && ! -L "${source}" ]] || return 70
  _cntools_action_advanced_multisig_create_file_validate \
    "${target}" 1 600 0 || return 70
  _cntools_action_advanced_multisig_create_identity \
    "${target}" identity || return 70
  [[ "${identity}" == \
     "${multisig_create_private_file_identities[${source}]}" ]] || return 70
  multisig_create_leaf_identities["${leaf}"]="${identity}"
  _cntools_action_advanced_multisig_create_stage_leaf_authority \
    "${leaf}" 1 0 || return 70
}

_cntools_action_advanced_multisig_create_destination_authority() {
  local current=""

  _cntools_action_advanced_multisig_create_root_authority &&
    _cntools_action_advanced_multisig_create_directory_validate \
      "${multisig_create_destination}" 700 &&
    _cntools_action_advanced_multisig_create_identity \
      "${multisig_create_destination}" current &&
    [[ "${current}" == "${multisig_create_stage_identity:-}" ]]
}

_cntools_action_advanced_multisig_create_tool_resolve() {
  local configured="${1:-}" output_variable="${2:-}"
  local kind="" resolved="" metadata="" owner="" mode="" links="" size=""

  [[ "${output_variable}" == multisig_create_ccli_path ]] || return 70
  if [[ "${configured}" =~ ^[a-z][a-z0-9-]*$ ]]; then
    kind="$(builtin type -t "${configured}" 2>/dev/null || true)"
    [[ -n "${kind}" && "${kind}" != function && "${kind}" != alias ]] ||
      return 70
    _cntools_registry_tool_path "${configured}" resolved || return 70
  elif [[ "${configured}" == /* ]]; then
    resolved="${configured}"
  else
    return 70
  fi
  [[ "${resolved}" == /* && "${resolved}" != */ &&
     "${resolved}" != *//* && "${resolved}" != *\\* &&
     ! "${resolved}" =~ [[:cntrl:]] && -f "${resolved}" &&
     -x "${resolved}" && ! -L "${resolved}" ]] || return 70
  _cntools_registry_path_has_no_symlinks "${resolved}" || return 70
  _cntools_action_advanced_multisig_create_metadata \
    "${resolved}" metadata || return 70
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 70
  mode="${mode#0}"
  [[ ( "${owner}" == 0 || "${owner}" == "${EUID}" ) &&
     "${mode}" =~ ^[57][0145][0145]$ && "${links}" == 1 &&
     "${size}" =~ ^[1-9][0-9]*$ && "${size}" -le 268435456 ]] || return 70
  builtin printf -v "${output_variable}" '%s' "${resolved}"
}

_cntools_action_advanced_multisig_create_private_temp() {
  local label="${1:-}" output_variable="${2:-}" target="" identity=""

  [[ "${label}" =~ ^[a-z0-9-]{1,48}$ &&
     "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 70
  target="$("${multisig_create_mktemp_path}" \
    "${multisig_create_private_parent}/multisig-create-${label}.XXXXXXXX")" ||
    return 70
  _cntools_action_advanced_multisig_create_private_temp_path_valid \
    "${target}" "${label}" || return 70
  _cntools_action_advanced_multisig_create_private_parent_authority || return 70
  _cntools_action_advanced_multisig_create_file_validate \
    "${target}" 65536 600 0 || return 70
  _cntools_action_advanced_multisig_create_identity \
    "${target}" identity || return 70
  multisig_create_private_file_identities["${target}"]="${identity}"
  multisig_create_private_files+=("${target}")
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${target}" 65536 0 || return 70
  builtin printf -v "${output_variable}" '%s' "${target}"
}

_cntools_action_advanced_multisig_create_stage_empty_validate() {
  local inventory="" target="" count=0

  _cntools_action_advanced_multisig_create_stage_authority || return 1
  _cntools_action_advanced_multisig_create_private_temp \
    stage-empty inventory || return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  (
    ulimit -f 128 >/dev/null 2>&1 || exit 1
    "${multisig_create_find_path}" "${multisig_create_stage}" \
      -mindepth 1 -maxdepth 1 -print0 > "${inventory}"
  ) || return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${multisig_create_stage}/"* ]] || return 1
    count=$((count + 1))
  done < "${inventory}"
  _cntools_action_advanced_multisig_create_stage_authority || return 1
  (( count == 0 ))
}

_cntools_action_advanced_multisig_create_ccli_version_validate() {
  local output="" status=0 value=""

  _cntools_action_advanced_multisig_create_private_temp version output ||
    return 70
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${output}" 65536 0 || return 70
  (
    ulimit -f 32 >/dev/null 2>&1 || exit 70
    "${multisig_create_ccli_path}" --version > "${output}" 2>&1
  ) || status=$?
  [[ "${status}" == 0 ]] || return 70
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${output}" 16384 1 || return 70
  value="$(< "${output}")"
  _cntools_action_advanced_multisig_create_terminal_valid "${value}" 1024 ||
    return 70
  [[ "${value}" =~ ^cardano-cli[[:space:]][0-9]+(\.[0-9]+){2,4}([[:space:]][ -~]+)?$ ]]
}

_cntools_action_advanced_multisig_create_vkey_validate() {
  local target="${1:-}" expected_type="${2:-}"

  _cntools_action_advanced_multisig_create_file_validate \
    "${target}" 16384 '400,440,444,600,640,644' || return 1
  "${multisig_create_jq_path}" -e --arg expected "${expected_type}" '
    type == "object" and keys == ["cborHex", "description", "type"] and
    .type == $expected and
    (.description | type == "string" and length >= 1 and length <= 256 and
      test("^[ -~]+$")) and
    (.cborHex | type == "string" and test("^5820[0-9A-Fa-f]{64}$"))
  ' "${target}" >/dev/null 2>&1
}

_cntools_action_advanced_multisig_create_text_validate() {
  local target="${1:-}" kind="${2:-}" value=""

  _cntools_action_advanced_multisig_create_file_validate \
    "${target}" 1024 600 || return 1
  value="$(< "${target}")"
  _cntools_action_advanced_multisig_create_terminal_valid "${value}" 512 ||
    return 1
  case "${kind}" in
    base|payment)
      if [[ "${multisig_create_network_args[0]:-}" == --mainnet ]]; then
        [[ "${value}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]]
      else
        [[ "${value}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]]
      fi
      ;;
    reward)
      if [[ "${multisig_create_network_args[0]:-}" == --mainnet ]]; then
        [[ "${value}" =~ ^stake1[023456789ac-hj-np-z]{20,200}$ ]]
      else
        [[ "${value}" =~ ^stake_test1[023456789ac-hj-np-z]{20,200}$ ]]
      fi
      ;;
    credential) _cntools_action_advanced_multisig_create_hash_valid "${value}" ;;
    *) return 1 ;;
  esac
}

_cntools_action_advanced_multisig_create_script_validate() {
  local target="${1:-}" role="${2:-}" index=0 actual=""

  _cntools_action_advanced_multisig_create_file_validate \
    "${target}" 16384 600 || return 1
  case "${role}" in
    payment)
      if [[ -n "${multisig_create_timelock_after:-}" ]]; then
        "${multisig_create_jq_path}" -e \
          --argjson required "${multisig_create_required}" \
          --argjson after "${multisig_create_timelock_after}" \
          --argjson count "${#multisig_create_pay_hashes[@]}" '
          type == "object" and keys == ["scripts", "type"] and
          .type == "all" and (.scripts | type == "array" and length == 2) and
          .scripts[0] == {slot:$after,type:"after"} and
          (.scripts[1] | type == "object" and
            keys == ["required", "scripts", "type"] and
            .type == "atLeast" and .required == $required and
            (.scripts | type == "array" and length == $count and
              all(.[]; type == "object" and keys == ["keyHash", "type"] and
                .type == "sig" and
                (.keyHash | type == "string" and test("^[0-9a-f]{56}$")))))
        ' "${target}" >/dev/null 2>&1 || return 1
        for ((index=0; index<${#multisig_create_pay_hashes[@]}; index++)); do
          actual="$("${multisig_create_jq_path}" -er \
            --argjson index "${index}" '.scripts[1].scripts[$index].keyHash' \
            "${target}" 2>/dev/null)" || return 1
          [[ "${actual}" == "${multisig_create_pay_hashes[index]}" ]] || return 1
        done
      else
        "${multisig_create_jq_path}" -e \
          --argjson required "${multisig_create_required}" \
          --argjson count "${#multisig_create_pay_hashes[@]}" '
          type == "object" and keys == ["required", "scripts", "type"] and
          .type == "atLeast" and .required == $required and
          (.scripts | type == "array" and length == $count and
            all(.[]; type == "object" and keys == ["keyHash", "type"] and
              .type == "sig" and
              (.keyHash | type == "string" and test("^[0-9a-f]{56}$"))))
        ' "${target}" >/dev/null 2>&1 || return 1
        for ((index=0; index<${#multisig_create_pay_hashes[@]}; index++)); do
          actual="$("${multisig_create_jq_path}" -er \
            --argjson index "${index}" '.scripts[$index].keyHash' \
            "${target}" 2>/dev/null)" || return 1
          [[ "${actual}" == "${multisig_create_pay_hashes[index]}" ]] || return 1
        done
      fi
      ;;
    stake)
      "${multisig_create_jq_path}" -e \
        --argjson required "${multisig_create_required}" \
        --argjson count "${#multisig_create_stake_hashes[@]}" '
        type == "object" and keys == ["required", "scripts", "type"] and
        .type == "atLeast" and .required == $required and
        (.scripts | type == "array" and length == $count and
          all(.[]; type == "object" and keys == ["keyHash", "type"] and
            .type == "sig" and
            (.keyHash | type == "string" and test("^[0-9a-f]{56}$"))))
      ' "${target}" >/dev/null 2>&1 || return 1
      for ((index=0; index<${#multisig_create_stake_hashes[@]}; index++)); do
        actual="$("${multisig_create_jq_path}" -er \
          --argjson index "${index}" '.scripts[$index].keyHash' \
          "${target}" 2>/dev/null)" || return 1
        [[ "${actual}" == "${multisig_create_stake_hashes[index]}" ]] || return 1
      done
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_advanced_multisig_create_leaf_validate() {
  local directory="${1:-}" leaf="${2:-}"

  case "${leaf}" in
    "${WALLET_PAY_SCRIPT_FILENAME}")
      _cntools_action_advanced_multisig_create_script_validate \
        "${directory}/${leaf}" payment
      ;;
    "${WALLET_STAKE_SCRIPT_FILENAME}")
      _cntools_action_advanced_multisig_create_script_validate \
        "${directory}/${leaf}" stake
      ;;
    "${WALLET_BASE_ADDR_FILENAME}")
      _cntools_action_advanced_multisig_create_text_validate \
        "${directory}/${leaf}" base
      ;;
    "${WALLET_PAY_ADDR_FILENAME}")
      _cntools_action_advanced_multisig_create_text_validate \
        "${directory}/${leaf}" payment
      ;;
    "${WALLET_STAKE_ADDR_FILENAME}")
      _cntools_action_advanced_multisig_create_text_validate \
        "${directory}/${leaf}" reward
      ;;
    "${WALLET_PAY_SCRIPT_CRED_FILENAME}"|"${WALLET_STAKE_SCRIPT_CRED_FILENAME}")
      _cntools_action_advanced_multisig_create_text_validate \
        "${directory}/${leaf}" credential
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_advanced_multisig_create_inventory_validate() {
  local directory="${1:-}" inventory="" target="" leaf="" digest=""
  local count=0
  local -A visited=()

  if [[ "${directory}" == "${multisig_create_stage}" ]]; then
    _cntools_action_advanced_multisig_create_stage_authority || return 1
  elif [[ "${directory}" == "${multisig_create_destination}" ]]; then
    _cntools_action_advanced_multisig_create_destination_authority || return 1
  else
    return 1
  fi
  _cntools_action_advanced_multisig_create_private_temp inventory inventory ||
    return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  "${multisig_create_find_path}" "${directory}" -mindepth 1 -maxdepth 1 \
    -print0 > "${inventory}" || return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${directory}/"* ]] || return 1
    leaf="${target#"${directory}/"}"
    [[ "${leaf}" != */* && -n "${multisig_create_leaf_set[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 1
    visited["${leaf}"]=Y
    count=$((count + 1))
  done < "${inventory}"
  (( count == ${#multisig_create_leaves[@]} )) || return 1
  for leaf in "${multisig_create_leaves[@]}"; do
    [[ -n "${visited[${leaf}]+set}" ]] || return 1
    if [[ "${directory}" == "${multisig_create_stage}" ]]; then
      _cntools_action_advanced_multisig_create_stage_leaf_authority \
        "${leaf}" 16384 1 || return 1
    fi
    _cntools_action_advanced_multisig_create_leaf_validate \
      "${directory}" "${leaf}" || return 1
    _cntools_action_advanced_multisig_create_digest \
      "${directory}/${leaf}" digest || return 1
    [[ "${digest}" == "${multisig_create_leaf_digests[${leaf}]:-}" ]] ||
      return 1
  done
}

_cntools_action_advanced_multisig_create_partial_stage_safe() {
  local inventory="" target="" leaf="" count=0
  local -A visited=()

  _cntools_action_advanced_multisig_create_stage_authority || return 1
  _cntools_action_advanced_multisig_create_private_temp partial inventory ||
    return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  "${multisig_create_find_path}" "${multisig_create_stage}" \
    -mindepth 1 -maxdepth 1 -print0 > "${inventory}" || return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${multisig_create_stage}/"* ]] || return 1
    leaf="${target#"${multisig_create_stage}/"}"
    [[ "${leaf}" != */* && -n "${multisig_create_leaf_set[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 1
    visited["${leaf}"]=Y
    _cntools_action_advanced_multisig_create_stage_leaf_authority \
      "${leaf}" 16384 0 || return 1
    count=$((count + 1))
    (( count <= ${#multisig_create_leaves[@]} )) || return 1
  done < "${inventory}"
}

_cntools_action_advanced_multisig_create_partial_destination_safe() {
  local inventory="" target="" leaf="" digest="" count=0
  local -A visited=()

  _cntools_action_advanced_multisig_create_destination_authority || return 1
  _cntools_action_advanced_multisig_create_private_temp partial-published \
    inventory || return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  "${multisig_create_find_path}" "${multisig_create_destination}" \
    -mindepth 1 -maxdepth 1 -print0 > "${inventory}" || return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${inventory}" 65536 0 || return 1
  while IFS= read -r -d '' target; do
    [[ "${target}" == "${multisig_create_destination}/"* ]] || return 1
    leaf="${target#"${multisig_create_destination}/"}"
    [[ "${leaf}" != */* && -n "${multisig_create_leaf_set[${leaf}]+set}" &&
       -z "${visited[${leaf}]+set}" ]] || return 1
    visited["${leaf}"]=Y
    _cntools_action_advanced_multisig_create_leaf_validate \
      "${multisig_create_destination}" "${leaf}" || return 1
    _cntools_action_advanced_multisig_create_digest \
      "${target}" digest || return 1
    [[ "${digest}" == "${multisig_create_leaf_digests[${leaf}]:-}" ]] ||
      return 1
    count=$((count + 1))
    (( count <= ${#multisig_create_leaves[@]} )) || return 1
  done < "${inventory}"
}

_cntools_action_advanced_multisig_create_publish_state() {
  [[ "${multisig_create_publish_attempt:-N}" == Y ]] || return 70
  if [[ ! -e "${multisig_create_stage}" && ! -L "${multisig_create_stage}" ]] &&
     _cntools_action_advanced_multisig_create_inventory_validate \
       "${multisig_create_destination}"; then
    return 0
  fi
  if [[ ! -e "${multisig_create_destination}" &&
        ! -L "${multisig_create_destination}" ]] &&
     _cntools_action_advanced_multisig_create_inventory_validate \
       "${multisig_create_stage}"; then
    return 1
  fi
  return 70
}

_cntools_action_advanced_multisig_create_remove_directory() {
  local directory="${1:-}" leaf="" target="" digest=""
  local attempt=0 pass_failed=0

  [[ "${directory}" == "${multisig_create_stage}" ||
     "${directory}" == "${multisig_create_destination}" ]] || return 1
  while (( attempt < 2 )); do
    attempt=$((attempt + 1))
    pass_failed=0
    if [[ "${directory}" == "${multisig_create_stage}" ]]; then
      _cntools_action_advanced_multisig_create_partial_stage_safe || return 1
    else
      _cntools_action_advanced_multisig_create_partial_destination_safe ||
        return 1
    fi
    for leaf in "${multisig_create_leaves[@]}"; do
      target="${directory}/${leaf}"
      if [[ -e "${target}" || -L "${target}" ]]; then
        if [[ "${directory}" == "${multisig_create_stage}" ]]; then
          _cntools_action_advanced_multisig_create_stage_leaf_authority \
            "${leaf}" 16384 0 || return 1
        else
          _cntools_action_advanced_multisig_create_leaf_validate \
            "${directory}" "${leaf}" || return 1
          _cntools_action_advanced_multisig_create_digest \
            "${target}" digest || return 1
          [[ "${digest}" == "${multisig_create_leaf_digests[${leaf}]:-}" ]] ||
            return 1
        fi
        "${multisig_create_rm_path}" -f -- "${target}" \
          >/dev/null 2>&1 || true
        if [[ -e "${target}" || -L "${target}" ]]; then
          pass_failed=1
        fi
      fi
    done
    if [[ "${directory}" == "${multisig_create_stage}" ]]; then
      _cntools_action_advanced_multisig_create_partial_stage_safe || return 1
    else
      _cntools_action_advanced_multisig_create_partial_destination_safe ||
        return 1
    fi
    if [[ "${pass_failed}" == 0 ]]; then
      "${multisig_create_rmdir_path}" -- "${directory}" \
        >/dev/null 2>&1 || true
      [[ ! -e "${directory}" && ! -L "${directory}" ]] && return 0
    fi
  done
  return 1
}

_cntools_action_advanced_multisig_create_cleanup() {
  local cleanup_status=0 publish_state=0 target="" attempt=0
  local -a remaining_private_files=()

  trap '' HUP INT TERM
  if ! _cntools_action_advanced_multisig_create_root_authority; then
    [[ -z "${multisig_create_lock:-}${multisig_create_stage:-}" &&
       ( -z "${multisig_create_destination:-}" ||
         ( ! -e "${multisig_create_destination}" &&
           ! -L "${multisig_create_destination}" ) ) ]] || cleanup_status=1
  elif [[ "${multisig_create_committed:-N}" != Y ]]; then
    if [[ "${multisig_create_publish_attempt:-N}" == Y ]]; then
      if [[ "${multisig_create_cleanup_payload_done:-N}" == Y ]]; then
        :
      elif [[ -n "${multisig_create_cleanup_directory:-}" ]]; then
        if [[ ( "${multisig_create_cleanup_directory}" == "${multisig_create_stage}" ||
                "${multisig_create_cleanup_directory}" == "${multisig_create_destination}" ) &&
              ( -e "${multisig_create_cleanup_directory}" ||
                -L "${multisig_create_cleanup_directory}" ) ]]; then
          _cntools_action_advanced_multisig_create_remove_directory \
            "${multisig_create_cleanup_directory}" || cleanup_status=1
          if [[ "${cleanup_status}" == 0 ]]; then
            multisig_create_cleanup_payload_done=Y
            multisig_create_cleanup_directory=""
          fi
        else
          cleanup_status=1
        fi
      else
        _cntools_action_advanced_multisig_create_publish_state || publish_state=$?
        case "${publish_state}" in
          0)
            multisig_create_cleanup_directory="${multisig_create_destination}"
            _cntools_action_advanced_multisig_create_remove_directory \
              "${multisig_create_cleanup_directory}" || cleanup_status=1
            if [[ "${cleanup_status}" == 0 ]]; then
              multisig_create_cleanup_payload_done=Y
              multisig_create_cleanup_directory=""
            fi
            ;;
          1)
            multisig_create_cleanup_directory="${multisig_create_stage}"
            _cntools_action_advanced_multisig_create_remove_directory \
              "${multisig_create_cleanup_directory}" || cleanup_status=1
            if [[ "${cleanup_status}" == 0 ]]; then
              multisig_create_cleanup_payload_done=Y
              multisig_create_cleanup_directory=""
            fi
            ;;
          *) cleanup_status=1 ;;
        esac
      fi
    elif [[ -n "${multisig_create_stage:-}" ]]; then
      if [[ -e "${multisig_create_stage}" || -L "${multisig_create_stage}" ]]; then
        _cntools_action_advanced_multisig_create_remove_directory \
          "${multisig_create_stage}" || cleanup_status=1
      fi
    fi
  fi
  for target in "${multisig_create_private_files[@]:-}"; do
    [[ -n "${target}" && "${target}" == "${multisig_create_private_parent}/"* ]] ||
      continue
    attempt=0
    while [[ -e "${target}" || -L "${target}" ]]; do
      _cntools_action_advanced_multisig_create_private_file_authority \
        "${target}" 65536 0 || break
      "${multisig_create_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || true
      [[ ! -e "${target}" && ! -L "${target}" ]] && break
      attempt=$((attempt + 1))
      (( attempt < 2 )) || break
    done
    if [[ -e "${target}" || -L "${target}" ]]; then
      cleanup_status=1
      remaining_private_files+=("${target}")
    fi
  done
  multisig_create_private_files=("${remaining_private_files[@]}")
  if [[ "${cleanup_status}" == 0 && -n "${multisig_create_lock:-}" &&
        ( -e "${multisig_create_lock}" || -L "${multisig_create_lock}" ) ]]; then
    if _cntools_action_advanced_multisig_create_lock_authority; then
      attempt=0
      while [[ -e "${multisig_create_lock}" || -L "${multisig_create_lock}" ]]; do
        _cntools_action_advanced_multisig_create_lock_authority || {
          cleanup_status=1
          break
        }
        "${multisig_create_rmdir_path}" -- "${multisig_create_lock}" \
          >/dev/null 2>&1 || true
        [[ ! -e "${multisig_create_lock}" &&
           ! -L "${multisig_create_lock}" ]] && break
        attempt=$((attempt + 1))
        if (( attempt >= 2 )); then
          cleanup_status=1
          break
        fi
      done
    else
      cleanup_status=1
    fi
  fi
  if [[ "${cleanup_status}" == 0 ]]; then
    multisig_create_stage=""
    multisig_create_lock=""
  fi
  return "${cleanup_status}"
}

_cntools_action_advanced_multisig_create_signal() {
  _cntools_action_advanced_multisig_create_cleanup >/dev/null 2>&1 || true
  _cntools_action_advanced_multisig_create_validation_failure
  exit 70
}

_cntools_action_advanced_multisig_create_postcommit_signal() {
  multisig_create_committed=Y
  multisig_create_stage=""
  trap '' HUP INT TERM
  _cntools_action_advanced_multisig_create_cleanup >/dev/null 2>&1 || true
  trap - EXIT HUP INT TERM
  _cntools_action_advanced_multisig_create_warning
  exit 0
}

_cntools_action_advanced_multisig_create_defer_signal() {
  multisig_create_signal_pending=Y
}

_cntools_action_advanced_multisig_create_handled() {
  local message="${1:-}" cleanup_status=0

  _cntools_action_advanced_multisig_create_cleanup || cleanup_status=1
  if [[ "${cleanup_status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_validation_failure
    return 70
  fi
  trap - EXIT HUP INT TERM
  [[ -z "${message}" ]] || println ERROR "${message}"
  waitToProceed
  return 0
}

_cntools_action_advanced_multisig_create_cancel() {
  local cleanup_status=0

  _cntools_action_advanced_multisig_create_cleanup || cleanup_status=1
  if [[ "${cleanup_status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_validation_failure
    return 70
  fi
  trap - EXIT HUP INT TERM
  return 0
}

_cntools_action_advanced_multisig_create_invariant() {
  local cleanup_status=0

  _cntools_action_advanced_multisig_create_cleanup || cleanup_status=1
  [[ "${cleanup_status}" != 0 ]] || trap - EXIT HUP INT TERM
  _cntools_action_advanced_multisig_create_validation_failure
  return 70
}

_cntools_action_advanced_multisig_create_add_signer() {
  local payment="${1:-}" stake="${2:-}"

  _cntools_action_advanced_multisig_create_hash_valid "${payment}" &&
    _cntools_action_advanced_multisig_create_hash_valid "${stake}" || return 1
  [[ -z "${multisig_create_pay_seen[${payment}]+set}" &&
     -z "${multisig_create_stake_seen[${stake}]+set}" ]] || return 2
  (( ${#multisig_create_pay_hashes[@]} < 64 )) || return 3
  multisig_create_pay_hashes+=("${payment}")
  multisig_create_stake_hashes+=("${stake}")
  multisig_create_pay_seen["${payment}"]=Y
  multisig_create_stake_seen["${stake}"]=Y
}

_cntools_action_advanced_multisig_create_wallet_signer() {
  local selected="${wallet_name:-}" wallet="" wallet_identity="" current=""
  local payment_vkey="" stake_vkey="" payment_output="" stake_output=""
  local payment="" stake="" status=0

  _cntools_action_advanced_multisig_create_name_valid "${selected}" || return 70
  wallet="${multisig_create_root}/${selected}"
  _cntools_action_advanced_multisig_create_directory_validate \
    "${wallet}" '700,750,755' || return 70
  _cntools_action_advanced_multisig_create_identity \
    "${wallet}" wallet_identity ||
    return 70
  payment_vkey="${wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  stake_vkey="${wallet}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  [[ -e "${payment_vkey}" && ! -L "${payment_vkey}" ]] || {
    [[ ! -e "${payment_vkey}" && ! -L "${payment_vkey}" ]] && return 1
    return 70
  }
  [[ -e "${stake_vkey}" && ! -L "${stake_vkey}" ]] || {
    [[ ! -e "${stake_vkey}" && ! -L "${stake_vkey}" ]] && return 2
    return 70
  }
  _cntools_action_advanced_multisig_create_vkey_validate \
    "${payment_vkey}" PaymentVerificationKeyShelley_ed25519 || return 70
  _cntools_action_advanced_multisig_create_vkey_validate \
    "${stake_vkey}" StakeVerificationKeyShelley_ed25519 || return 70
  _cntools_action_advanced_multisig_create_private_temp \
    signer-payment payment_output || return 70
  _cntools_action_advanced_multisig_create_private_temp \
    signer-stake stake_output || return 70
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${payment_output}" 65536 0 || return 70
  (
    ulimit -f 32 >/dev/null 2>&1 || exit 70
    CNTOOLS_MULTISIG_CREATE_ACTION_PID="${multisig_create_action_pid}" \
      "${multisig_create_ccli_path}" address key-hash \
      --payment-verification-key-file "${payment_vkey}" \
      --out-file "${payment_output}" >/dev/null 2>&1
  ) || status=$?
  [[ "${status}" == 0 ]] || return 1
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${payment_output}" 128 1 || return 70
  status=0
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${stake_output}" 65536 0 || return 70
  (
    ulimit -f 32 >/dev/null 2>&1 || exit 70
    CNTOOLS_MULTISIG_CREATE_ACTION_PID="${multisig_create_action_pid}" \
      "${multisig_create_ccli_path}" latest stake-address key-hash \
      --stake-verification-key-file "${stake_vkey}" \
      --out-file "${stake_output}" >/dev/null 2>&1
  ) || status=$?
  [[ "${status}" == 0 ]] || return 2
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${payment_output}" 128 1 || return 70
  _cntools_action_advanced_multisig_create_private_file_authority \
    "${stake_output}" 128 1 || return 70
  payment="$(< "${payment_output}")"
  stake="$(< "${stake_output}")"
  _cntools_action_advanced_multisig_create_hash_valid "${payment}" &&
    _cntools_action_advanced_multisig_create_hash_valid "${stake}" || return 70
  _cntools_action_advanced_multisig_create_directory_validate \
    "${wallet}" '700,750,755' &&
    _cntools_action_advanced_multisig_create_identity "${wallet}" current &&
    [[ "${current}" == "${wallet_identity}" ]] &&
    _cntools_action_advanced_multisig_create_root_authority || return 70
  builtin printf -v multisig_create_candidate_pay '%s' "${payment}"
  builtin printf -v multisig_create_candidate_stake '%s' "${stake}"
}

_cntools_action_advanced_multisig_create_build_scripts() {
  local payment_json="" stake_json="" temporary="" hash="" status=0

  payment_json="$("${multisig_create_jq_path}" -nS \
    --argjson required "${multisig_create_required}" \
    '{required:$required,scripts:[],type:"atLeast"}' 2>/dev/null)" || return 1
  stake_json="${payment_json}"
  for hash in "${multisig_create_pay_hashes[@]}"; do
    payment_json="$("${multisig_create_jq_path}" -S --arg hash "${hash}" \
      '.scripts += [{keyHash:$hash,type:"sig"}]' \
      <<< "${payment_json}" 2>/dev/null)" || return 1
  done
  for hash in "${multisig_create_stake_hashes[@]}"; do
    stake_json="$("${multisig_create_jq_path}" -S --arg hash "${hash}" \
      '.scripts += [{keyHash:$hash,type:"sig"}]' \
      <<< "${stake_json}" 2>/dev/null)" || return 1
  done
  if [[ -n "${multisig_create_timelock_after}" ]]; then
    payment_json="$("${multisig_create_jq_path}" -nS \
      --argjson after "${multisig_create_timelock_after}" \
      --argjson script "${payment_json}" \
      '{scripts:[{slot:$after,type:"after"},$script],type:"all"}' \
      2>/dev/null)" || return 1
  fi
  _cntools_action_advanced_multisig_create_stage_authority || return 70
  _cntools_action_advanced_multisig_create_stage_leaf_authority \
    "${WALLET_PAY_SCRIPT_FILENAME}" 16384 0 || return 70
  builtin printf '%s\n' "${payment_json}" > \
    "${multisig_create_stage}/${WALLET_PAY_SCRIPT_FILENAME}" || status=$?
  [[ "${status}" == 0 ]] || return 1
  _cntools_action_advanced_multisig_create_stage_leaf_authority \
    "${WALLET_PAY_SCRIPT_FILENAME}" 16384 1 || return 70
  _cntools_action_advanced_multisig_create_stage_leaf_authority \
    "${WALLET_STAKE_SCRIPT_FILENAME}" 16384 0 || return 70
  builtin printf '%s\n' "${stake_json}" > \
    "${multisig_create_stage}/${WALLET_STAKE_SCRIPT_FILENAME}" || status=$?
  [[ "${status}" == 0 ]] || return 1
  _cntools_action_advanced_multisig_create_stage_leaf_authority \
    "${WALLET_STAKE_SCRIPT_FILENAME}" 16384 1 || return 70
  _cntools_action_advanced_multisig_create_script_validate \
    "${multisig_create_stage}/${WALLET_PAY_SCRIPT_FILENAME}" payment || return 70
  _cntools_action_advanced_multisig_create_script_validate \
    "${multisig_create_stage}/${WALLET_STAKE_SCRIPT_FILENAME}" stake || return 70
  for temporary in "${WALLET_PAY_SCRIPT_FILENAME}" \
      "${WALLET_STAKE_SCRIPT_FILENAME}"; do
    _cntools_action_advanced_multisig_create_digest \
      "${multisig_create_stage}/${temporary}" hash || return 70
    multisig_create_leaf_digests["${temporary}"]="${hash}"
  done
}

_cntools_action_advanced_multisig_create_derive_leaf() {
  local leaf="${1:-}" kind="${2:-}" label="${3:-}" status=0 digest=""
  shift 3 || return 70

  [[ -n "${multisig_create_leaf_set[${leaf}]+set}" &&
     "${leaf}" != "${WALLET_PAY_SCRIPT_FILENAME}" &&
     "${leaf}" != "${WALLET_STAKE_SCRIPT_FILENAME}" ]] || return 70
  _cntools_action_advanced_multisig_create_stage_authority || return 70
  _cntools_action_advanced_multisig_create_stage_leaf_authority \
    "${leaf}" 16384 0 || return 70
  println ACTION "cardano-cli MultiSig ${label} derivation"
  (
    ulimit -f 32 >/dev/null 2>&1 || exit 70
    CNTOOLS_MULTISIG_CREATE_ACTION_PID="${multisig_create_action_pid}" \
      "${multisig_create_ccli_path}" "$@" \
      --out-file "${multisig_create_stage}/${leaf}" >/dev/null 2>&1
  ) || status=$?
  if [[ "${status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_partial_stage_safe || return 70
    return 1
  fi
  _cntools_action_advanced_multisig_create_stage_authority || return 70
  _cntools_action_advanced_multisig_create_stage_leaf_authority \
    "${leaf}" 1024 1 || return 70
  _cntools_action_advanced_multisig_create_text_validate \
    "${multisig_create_stage}/${leaf}" "${kind}" || return 70
  _cntools_action_advanced_multisig_create_digest \
    "${multisig_create_stage}/${leaf}" digest || return 70
  multisig_create_leaf_digests["${leaf}"]="${digest}"
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local multisig_create_action_pid="${BASHPID}"
  local context_mode="" context_network="" context_home=""
  local filename="" network_magic="" status=0 add_status=0 attempts=0
  local leaf_index=0
  local publish_status=0 raw_publish_status=0 cleanup_status=0 leaf=""
  local base_addr="" pay_addr="" reward_addr="" payment_credential=""
  local stake_credential=""
  local multisig_create_root="" multisig_create_root_identity=""
  local multisig_create_private_parent=""
  local multisig_create_private_parent_identity="" multisig_create_name=""
  local multisig_create_destination="" multisig_create_lock=""
  local multisig_create_lock_identity="" multisig_create_stage=""
  local multisig_create_stage_identity="" multisig_create_required=""
  local multisig_create_timelock_after="" multisig_create_candidate_pay=""
  local multisig_create_candidate_stake="" multisig_create_signal_pending=N
  local multisig_create_publish_attempt=N multisig_create_committed=N
  local multisig_create_cleanup_directory=""
  local multisig_create_cleanup_payload_done=N
  local multisig_create_jq_path="" multisig_create_mktemp_path=""
  local multisig_create_mkdir_path="" multisig_create_ln_path=""
  local multisig_create_rm_path="" multisig_create_rmdir_path=""
  local multisig_create_mv_path="" multisig_create_find_path=""
  local multisig_create_stat_path="" multisig_create_hash_path=""
  local multisig_create_hash_kind="" multisig_create_ccli_path=""
  local -a multisig_create_network_args=()
  local -a multisig_create_leaves=()
  local -a multisig_create_private_files=()
  local -a multisig_create_pay_hashes=()
  local -a multisig_create_stake_hashes=()
  local -a multisig_create_selected_wallets=()
  local -A multisig_create_leaf_set=()
  local -A multisig_create_leaf_digests=()
  local -A multisig_create_leaf_identities=()
  local -A multisig_create_private_file_identities=()
  local -A multisig_create_pay_seen=()
  local -A multisig_create_stake_seen=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1 ||
     ! builtin declare -F select_opt >/dev/null 2>&1 ||
     ! builtin declare -F selectWallet >/dev/null 2>&1 ||
     ! builtin declare -F getEpochStart >/dev/null 2>&1 ||
     ! builtin declare -F clear >/dev/null 2>&1; then
    _cntools_action_advanced_multisig_create_validation_failure
    return 70
  fi
  context_mode="$(cntools_context_get "${context_file}" mode)" || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  context_network="$(cntools_context_get "${context_file}" nodeNetwork)" || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  context_home="$(cntools_context_get "${context_file}" nodeHome)" || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  [[ "${context_mode}" == local || "${context_mode}" == light ||
     "${context_mode}" == offline ]] || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  [[ "${CNTOOLS_MODE,,}" == "${context_mode}" &&
     "${context_network}" =~ ^[A-Za-z0-9._-]{1,64}$ &&
     "${context_home}" == /* && "${context_home}" != *\\* &&
     ! "${context_home}" =~ [[:cntrl:]] ]] || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  for filename in jq mktemp mkdir ln rm rmdir mv find stat; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq multisig_create_jq_path || status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp multisig_create_mktemp_path || status=70 ;;
      mkdir) _cntools_registry_tool_path mkdir multisig_create_mkdir_path || status=70 ;;
      ln) _cntools_registry_tool_path ln multisig_create_ln_path || status=70 ;;
      rm) _cntools_registry_tool_path rm multisig_create_rm_path || status=70 ;;
      rmdir) _cntools_registry_tool_path rmdir multisig_create_rmdir_path || status=70 ;;
      mv) _cntools_registry_tool_path mv multisig_create_mv_path || status=70 ;;
      find) _cntools_registry_tool_path find multisig_create_find_path || status=70 ;;
      stat) _cntools_registry_tool_path stat multisig_create_stat_path || status=70 ;;
    esac
  done
  [[ "${status}" == 0 ]] || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  if _cntools_registry_tool_path sha256sum multisig_create_hash_path; then
    multisig_create_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum multisig_create_hash_path; then
    multisig_create_hash_kind=shasum
  else
    _cntools_action_advanced_multisig_create_validation_failure
    return 70
  fi
  multisig_create_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate "${multisig_create_private_parent}" || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  _cntools_action_advanced_multisig_create_identity \
    "${multisig_create_private_parent}" \
    multisig_create_private_parent_identity || {
      _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  _cntools_action_advanced_multisig_create_private_parent_authority || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  [[ "${WALLET_FOLDER}" == /* && "${WALLET_FOLDER}" != / &&
     "${WALLET_FOLDER}" != */ && "${WALLET_FOLDER}" != *//* &&
     "${WALLET_FOLDER}" != *\\* && ! "${WALLET_FOLDER}" =~ [[:cntrl:]] ]] || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  _cntools_action_advanced_multisig_create_directory_validate \
    "${WALLET_FOLDER}" '700,750,755' || {
      _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  multisig_create_root="$(cd -P -- "${WALLET_FOLDER}" && pwd -P)" || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  [[ "${multisig_create_root}" == "${WALLET_FOLDER}" &&
     "${multisig_create_root}" != "${multisig_create_private_parent}" &&
     "${multisig_create_root}" != "${multisig_create_private_parent}/"* &&
     "${multisig_create_private_parent}" != "${multisig_create_root}/"* ]] || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  _cntools_action_advanced_multisig_create_identity \
    "${multisig_create_root}" multisig_create_root_identity || {
      _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  multisig_create_leaves=(
    "${WALLET_PAY_SCRIPT_FILENAME}" "${WALLET_STAKE_SCRIPT_FILENAME}"
    "${WALLET_BASE_ADDR_FILENAME}" "${WALLET_PAY_ADDR_FILENAME}"
    "${WALLET_STAKE_ADDR_FILENAME}" "${WALLET_PAY_SCRIPT_CRED_FILENAME}"
    "${WALLET_STAKE_SCRIPT_CRED_FILENAME}"
  )
  for filename in "${multisig_create_leaves[@]}" \
      "${WALLET_PAY_VK_FILENAME}" "${WALLET_STAKE_VK_FILENAME}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
      _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  done
  [[ "${WALLET_MULTISIG_PREFIX}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
    _cntools_action_advanced_multisig_create_validation_failure; return 70; }
  for leaf in "${multisig_create_leaves[@]}"; do
    [[ -z "${multisig_create_leaf_set[${leaf}]+set}" ]] || {
      _cntools_action_advanced_multisig_create_validation_failure; return 70; }
    multisig_create_leaf_set["${leaf}"]=Y
  done
  case "${NETWORK_IDENTIFIER}" in
    --mainnet)
      [[ "${NWMAGIC:-}" == 764824073 && "${context_network}" == mainnet ]] || {
        _cntools_action_advanced_multisig_create_validation_failure; return 70; }
      multisig_create_network_args=(--mainnet)
      ;;
    --testnet-magic\ *)
      network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      _cntools_action_advanced_multisig_create_uint_valid \
        "${network_magic}" 4294967295 &&
        [[ "${NWMAGIC:-}" == "${network_magic}" &&
           "${context_network}" != mainnet ]] || {
          _cntools_action_advanced_multisig_create_validation_failure; return 70; }
      multisig_create_network_args=(--testnet-magic "${network_magic}")
      ;;
    *) _cntools_action_advanced_multisig_create_validation_failure; return 70 ;;
  esac
  _cntools_action_advanced_multisig_create_tool_resolve \
    "${CCLI:-}" multisig_create_ccli_path || {
      _cntools_action_advanced_multisig_create_validation_failure; return 70; }

  umask 077
  trap '_cntools_action_advanced_multisig_create_cleanup' EXIT
  trap '_cntools_action_advanced_multisig_create_signal' HUP INT TERM
  _cntools_action_advanced_multisig_create_ccli_version_validate || {
    _cntools_action_advanced_multisig_create_invariant; return 70; }
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> ADVANCED >> MULTISIG >> CREATE WALLET'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  status=0
  getAnswerAnyCust multisig_create_name \
    'Name of wallet (ASCII letters, numbers, underscore and hyphen only)' ||
    status=$?
  case "${status}" in
    0) ;;
    1) _cntools_action_advanced_multisig_create_cancel; return $? ;;
    *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
  esac
  _cntools_action_advanced_multisig_create_name_valid \
    "${multisig_create_name}" || {
      _cntools_action_advanced_multisig_create_handled \
        'ERROR: Invalid wallet name, please retry!'; return $?; }
  multisig_create_destination="${multisig_create_root}/${multisig_create_name}"
  multisig_create_lock="${multisig_create_root}/.${multisig_create_name}.cntools-multisig-create.lock"
  if [[ -e "${multisig_create_destination}" ||
        -L "${multisig_create_destination}" ]]; then
    println "WARN: A wallet ${multisig_create_name} already exists"
    println '      Choose another name or delete the existing one'
    _cntools_action_advanced_multisig_create_handled ''
    return $?
  fi

  println OFF 'Select wallet(s) / credentials (key hashes) to include in MultiSig wallet'
  println OFF '! Please use 1854H (MultiSig) derived keys according to CIP-1854!'
  println OFF '! Only wallets with these keys will be listed, use Derive Keys to generate them.'
  echo
  while (( attempts < 128 )); do
    attempts=$((attempts + 1))
    println DEBUG 'Select wallet or manually enter credentials?'
    status=0
    select_opt '[w] Wallet' '[c] Credentials' "[d] I'm done" '[Esc] Cancel' ||
      status=$?
    multisig_create_candidate_pay=""
    multisig_create_candidate_stake=""
    case "${status}" in
      0)
        status=0
        selectWallet balance "${multisig_create_selected_wallets[@]}" \
          "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}" \
          "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}" || status=$?
        case "${status}" in
          0)
            status=0
            _cntools_action_advanced_multisig_create_wallet_signer || status=$?
            case "${status}" in
              0) multisig_create_selected_wallets+=("${wallet_name}") ;;
              1)
                println ERROR 'ERROR: wallet MultiSig payment credential is invalid!'
                waitToProceed
                continue
                ;;
              2)
                println ERROR 'ERROR: wallet MultiSig stake credential is invalid!'
                waitToProceed
                continue
                ;;
              *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
            esac
            ;;
          1) waitToProceed; continue ;;
          2) continue ;;
          *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
        esac
        ;;
      1)
        status=0
        getAnswerAnyCust multisig_create_candidate_pay \
          'MultiSig Payment Credential (key hash)' || status=$?
        case "${status}" in
          0) ;;
          1) _cntools_action_advanced_multisig_create_cancel; return $? ;;
          *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
        esac
        if ! _cntools_action_advanced_multisig_create_hash_valid \
          "${multisig_create_candidate_pay}"; then
          println ERROR 'ERROR: invalid payment credential entered!'
          waitToProceed
          continue
        fi
        status=0
        getAnswerAnyCust multisig_create_candidate_stake \
          'MultiSig Stake Credential (key hash)' || status=$?
        case "${status}" in
          0) ;;
          1) _cntools_action_advanced_multisig_create_cancel; return $? ;;
          *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
        esac
        if ! _cntools_action_advanced_multisig_create_hash_valid \
          "${multisig_create_candidate_stake}"; then
          println ERROR 'ERROR: invalid stake credential entered!'
          waitToProceed
          continue
        fi
        ;;
      2) break ;;
      3) _cntools_action_advanced_multisig_create_cancel; return $? ;;
      *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
    esac
    add_status=0
    _cntools_action_advanced_multisig_create_add_signer \
      "${multisig_create_candidate_pay}" \
      "${multisig_create_candidate_stake}" || add_status=$?
    case "${add_status}" in
      0) ;;
      1) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
      2)
        println ERROR 'ERROR: duplicate MultiSig credential entered!'
        waitToProceed
        continue
        ;;
      3)
        _cntools_action_advanced_multisig_create_handled \
          'ERROR: MultiSig signer limit exceeded!'
        return $?
        ;;
      *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
    esac
    println DEBUG "MultiSig size: ${#multisig_create_pay_hashes[@]} - Add more wallets / credentials to MultiSig?"
    status=0
    select_opt '[n] No' '[y] Yes' '[Esc] Cancel' || status=$?
    case "${status}" in
      0) break ;;
      1) ;;
      2) _cntools_action_advanced_multisig_create_cancel; return $? ;;
      *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
    esac
  done
  (( attempts < 128 )) || {
    _cntools_action_advanced_multisig_create_invariant; return 70; }
  (( ${#multisig_create_pay_hashes[@]} > 0 )) || {
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: no signers added, please add at least one'; return $?; }
  println DEBUG "${#multisig_create_pay_hashes[@]} wallets / credentials added to MultiSig, how many are required to witness the transaction?"
  status=0
  getAnswerAnyCust multisig_create_required 'Number of Required signatures' ||
    status=$?
  case "${status}" in
    0) ;;
    1) _cntools_action_advanced_multisig_create_cancel; return $? ;;
    *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
  esac
  _cntools_action_advanced_multisig_create_uint_valid \
    "${multisig_create_required}" "${#multisig_create_pay_hashes[@]}" &&
    (( 10#${multisig_create_required} >= 1 )) || {
      _cntools_action_advanced_multisig_create_handled \
        'ERROR: invalid signature count entered!'; return $?; }
  println DEBUG 'Add time lock by only allowing spending after a certain epoch start?'
  status=0
  select_opt '[n] No' '[y] Yes' '[Esc] Cancel' || status=$?
  case "${status}" in
    0) ;;
    1)
      status=0
      getAnswerAnyCust epoch_no 'Epoch' || status=$?
      case "${status}" in
        0) ;;
        1) _cntools_action_advanced_multisig_create_cancel; return $? ;;
        *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
      esac
      _cntools_action_advanced_multisig_create_uint_valid \
        "${epoch_no}" 2147483647 || {
          _cntools_action_advanced_multisig_create_handled \
            'ERROR: invalid epoch number entered!'; return $?; }
      multisig_create_timelock_after="$(getEpochStart "${epoch_no}")" || {
        _cntools_action_advanced_multisig_create_invariant; return 70; }
      _cntools_action_advanced_multisig_create_uint_valid \
        "${multisig_create_timelock_after}" 9007199254740991 || {
          _cntools_action_advanced_multisig_create_invariant; return 70; }
      ;;
    2) _cntools_action_advanced_multisig_create_cancel; return $? ;;
    *) _cntools_action_advanced_multisig_create_invariant; return 70 ;;
  esac

  _cntools_action_advanced_multisig_create_root_authority || {
    _cntools_action_advanced_multisig_create_invariant; return 70; }
  [[ ! -e "${multisig_create_destination}" &&
     ! -L "${multisig_create_destination}" ]] || {
    _cntools_action_advanced_multisig_create_invariant; return 70; }
  trap '_cntools_action_advanced_multisig_create_defer_signal' HUP INT TERM
  status=0
  "${multisig_create_mkdir_path}" -m 0700 -- "${multisig_create_lock}" \
    >/dev/null 2>&1 || status=$?
  if [[ "${status}" != 0 ]]; then
    # The failed mkdir did not grant authority over a pre-existing lock.
    multisig_create_lock=""
    trap '_cntools_action_advanced_multisig_create_signal' HUP INT TERM
    if [[ "${multisig_create_signal_pending}" == Y ]]; then
      _cntools_action_advanced_multisig_create_signal
    fi
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: MultiSig wallet creation is already in progress, please retry!'
    return $?
  fi
  _cntools_action_advanced_multisig_create_directory_validate \
    "${multisig_create_lock}" 700 &&
    _cntools_action_advanced_multisig_create_identity \
      "${multisig_create_lock}" multisig_create_lock_identity &&
    _cntools_action_advanced_multisig_create_lock_authority || {
      _cntools_action_advanced_multisig_create_invariant; return 70; }
  trap '_cntools_action_advanced_multisig_create_signal' HUP INT TERM
  if [[ "${multisig_create_signal_pending}" == Y ]]; then
    _cntools_action_advanced_multisig_create_signal
  fi
  trap '_cntools_action_advanced_multisig_create_defer_signal' HUP INT TERM
  multisig_create_stage="$("${multisig_create_mktemp_path}" -d \
    "${multisig_create_root}/.${multisig_create_name}.cntools-multisig-create.stage.XXXXXXXX")" || {
      _cntools_action_advanced_multisig_create_invariant; return 70; }
  _cntools_action_advanced_multisig_create_stage_path_valid &&
    _cntools_action_advanced_multisig_create_root_authority &&
  _cntools_action_advanced_multisig_create_directory_validate \
    "${multisig_create_stage}" 700 &&
    _cntools_action_advanced_multisig_create_identity \
      "${multisig_create_stage}" multisig_create_stage_identity &&
    _cntools_action_advanced_multisig_create_stage_authority || {
      _cntools_action_advanced_multisig_create_invariant; return 70; }
  _cntools_action_advanced_multisig_create_stage_empty_validate || {
    _cntools_action_advanced_multisig_create_invariant; return 70; }
  for leaf in "${multisig_create_leaves[@]}"; do
    _cntools_action_advanced_multisig_create_stage_leaf_create \
      "${leaf}" "${leaf_index}" || {
        _cntools_action_advanced_multisig_create_invariant; return 70; }
    leaf_index=$((leaf_index + 1))
  done
  _cntools_action_advanced_multisig_create_stage_authority || {
    _cntools_action_advanced_multisig_create_invariant; return 70; }
  trap '_cntools_action_advanced_multisig_create_signal' HUP INT TERM
  if [[ "${multisig_create_signal_pending}" == Y ]]; then
    _cntools_action_advanced_multisig_create_signal
  fi
  _cntools_action_advanced_multisig_create_build_scripts || status=$?
  if [[ "${status}" == 1 ]]; then
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: failure during MultiSig script creation!'
    return $?
  elif [[ "${status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_invariant
    return 70
  fi
  status=0
  _cntools_action_advanced_multisig_create_derive_leaf \
    "${WALLET_BASE_ADDR_FILENAME}" base base-address address build \
    --payment-script-file "${multisig_create_stage}/${WALLET_PAY_SCRIPT_FILENAME}" \
    --stake-script-file "${multisig_create_stage}/${WALLET_STAKE_SCRIPT_FILENAME}" \
    "${multisig_create_network_args[@]}" || status=$?
  if [[ "${status}" == 1 ]]; then
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: failure during MultiSig base address creation!'
    return $?
  elif [[ "${status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_invariant
    return 70
  fi
  status=0
  _cntools_action_advanced_multisig_create_derive_leaf \
    "${WALLET_PAY_ADDR_FILENAME}" payment payment-address address build \
    --payment-script-file "${multisig_create_stage}/${WALLET_PAY_SCRIPT_FILENAME}" \
    "${multisig_create_network_args[@]}" || status=$?
  if [[ "${status}" == 1 ]]; then
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: failure during MultiSig payment address creation!'
    return $?
  elif [[ "${status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_invariant
    return 70
  fi
  status=0
  _cntools_action_advanced_multisig_create_derive_leaf \
    "${WALLET_STAKE_ADDR_FILENAME}" reward reward-address latest stake-address build \
    --stake-script-file "${multisig_create_stage}/${WALLET_STAKE_SCRIPT_FILENAME}" \
    "${multisig_create_network_args[@]}" || status=$?
  if [[ "${status}" == 1 ]]; then
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: failure during MultiSig reward address creation!'
    return $?
  elif [[ "${status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_invariant
    return 70
  fi
  status=0
  _cntools_action_advanced_multisig_create_derive_leaf \
    "${WALLET_PAY_SCRIPT_CRED_FILENAME}" credential payment-credential hash script \
    --script-file "${multisig_create_stage}/${WALLET_PAY_SCRIPT_FILENAME}" ||
    status=$?
  if [[ "${status}" == 1 ]]; then
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: failure during MultiSig payment credential creation!'
    return $?
  elif [[ "${status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_invariant
    return 70
  fi
  status=0
  _cntools_action_advanced_multisig_create_derive_leaf \
    "${WALLET_STAKE_SCRIPT_CRED_FILENAME}" credential stake-credential hash script \
    --script-file "${multisig_create_stage}/${WALLET_STAKE_SCRIPT_FILENAME}" ||
    status=$?
  if [[ "${status}" == 1 ]]; then
    _cntools_action_advanced_multisig_create_handled \
      'ERROR: failure during MultiSig stake credential creation!'
    return $?
  elif [[ "${status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_invariant
    return 70
  fi
  _cntools_action_advanced_multisig_create_inventory_validate \
    "${multisig_create_stage}" &&
    _cntools_action_advanced_multisig_create_lock_authority || {
      _cntools_action_advanced_multisig_create_invariant; return 70; }
  base_addr="$(< "${multisig_create_stage}/${WALLET_BASE_ADDR_FILENAME}")"
  pay_addr="$(< "${multisig_create_stage}/${WALLET_PAY_ADDR_FILENAME}")"
  reward_addr="$(< "${multisig_create_stage}/${WALLET_STAKE_ADDR_FILENAME}")"
  payment_credential="$(< "${multisig_create_stage}/${WALLET_PAY_SCRIPT_CRED_FILENAME}")"
  stake_credential="$(< "${multisig_create_stage}/${WALLET_STAKE_SCRIPT_CRED_FILENAME}")"
  [[ "${base_addr}" != "${pay_addr}" ]] || {
    _cntools_action_advanced_multisig_create_invariant; return 70; }
  multisig_create_publish_attempt=Y
  trap '_cntools_action_advanced_multisig_create_defer_signal' HUP INT TERM
  "${multisig_create_mv_path}" -- "${multisig_create_stage}" \
    "${multisig_create_destination}" >/dev/null 2>&1 || raw_publish_status=$?
  publish_status=0
  _cntools_action_advanced_multisig_create_publish_state || publish_status=$?
  if [[ "${publish_status}" != 0 ]]; then
    trap '_cntools_action_advanced_multisig_create_signal' HUP INT TERM
    if [[ "${multisig_create_signal_pending}" == Y ]]; then
      _cntools_action_advanced_multisig_create_signal
    fi
  fi
  if [[ "${publish_status}" == 1 ]]; then
    if [[ "${raw_publish_status}" != 0 ]]; then
      _cntools_action_advanced_multisig_create_handled \
        'ERROR: failure during MultiSig wallet publication!'
      return $?
    fi
    _cntools_action_advanced_multisig_create_invariant
    return 70
  elif [[ "${publish_status}" != 0 ]]; then
    _cntools_action_advanced_multisig_create_invariant
    return 70
  fi
  multisig_create_committed=Y
  multisig_create_stage=""
  trap '_cntools_action_advanced_multisig_create_postcommit_signal' HUP INT TERM
  if [[ "${multisig_create_signal_pending}" == Y ]]; then
    _cntools_action_advanced_multisig_create_postcommit_signal
  fi
  _cntools_action_advanced_multisig_create_cleanup || cleanup_status=1
  trap '_cntools_action_advanced_multisig_create_postcommit_signal' HUP INT TERM
  trap - EXIT

  echo
  println "New MultiSig Wallet : ${FG_GREEN}${multisig_create_name}${NC}"
  println "Address             : ${FG_LGRAY}${base_addr}${NC}"
  println "Payment Address     : ${FG_LGRAY}${pay_addr}${NC}"
  println "Reward Address      : ${FG_LGRAY}${reward_addr}${NC}"
  println "Payment Credential  : ${FG_LGRAY}${payment_credential}${NC}"
  println "Reward Credential   : ${FG_LGRAY}${stake_credential}${NC}"
  println DEBUG 'You can now send and receive ADA using the Address or Payment Address.'
  println DEBUG 'Note that Payment Address will not take part in staking.'
  [[ "${cleanup_status}" == 0 ]] ||
    _cntools_action_advanced_multisig_create_warning
  waitToProceed
  trap - HUP INT TERM
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
