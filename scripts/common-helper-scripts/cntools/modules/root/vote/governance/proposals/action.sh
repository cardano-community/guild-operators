#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2154
# Stage 4 compatibility action for the read-only governance proposal browser.
# Sourcing defines functions only; the dispatcher supplies the authenticated
# context and inherited CNTools presentation helpers.

_cntools_action_vote_governance_proposals_validation_failure() {
  builtin printf '%s\n' \
    'CNTools governance-proposals action failed validation.' >&2
  return 70
}

_cntools_action_vote_governance_proposals_terminal_restore() {
  local restore_failed=0

  if [[ "${governance_proposals_terminal_saved:-N}" == Y ]]; then
    tput rc >/dev/null 2>&1 || restore_failed=1
    tput ed >/dev/null 2>&1 || restore_failed=1
    governance_proposals_terminal_saved=N
  fi
  return "${restore_failed}"
}

_cntools_action_vote_governance_proposals_cleanup() {
  local target="" cleanup_failed=0

  trap - EXIT HUP INT TERM
  _cntools_action_vote_governance_proposals_terminal_restore ||
    cleanup_failed=1
  for target in "${governance_proposals_temp_files[@]:-}"; do
    [[ -n "${target}" ]] || continue
    if [[ -e "${target}" || -L "${target}" ]]; then
      "${governance_proposals_rm_path}" -f -- "${target}" \
        >/dev/null 2>&1 || cleanup_failed=1
    fi
  done
  governance_proposals_temp_files=()
  return "${cleanup_failed}"
}

_cntools_action_vote_governance_proposals_file_validate() {
  local target="${1:-}" modes="${2:-}" maximum="${3:-}"
  local allow_empty="${4:-N}" metadata="" owner="" mode="" links="" size=""

  [[ -f "${target}" && ! -L "${target}" &&
     "${maximum}" =~ ^[1-9][0-9]*$ &&
     ( "${allow_empty}" == Y || "${allow_empty}" == N ) ]] || return 1
  _cntools_registry_path_has_no_symlinks "${target}" || return 1
  metadata="$(_cntools_result_stat "${target}")" || return 1
  IFS=$'\t' read -r owner mode links size <<< "${metadata}" || return 1
  mode="${mode#0}"
  [[ "${owner}" == "${EUID}" && "${links}" == 1 &&
     "${size}" =~ ^[0-9]+$ && "${size}" -le "${maximum}" &&
     ( "${allow_empty}" == Y || "${size}" -ge 1 ) &&
     ",${modes}," == *",${mode},"* ]]
}

_cntools_action_vote_governance_proposals_file_size() {
  local target="${1:-}" size=""

  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  size="$("${governance_proposals_wc_path}" -c < "${target}" 2>/dev/null)" ||
    return 1
  size="${size//[[:space:]]/}"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  builtin printf '%s\n' "${size}"
}

_cntools_action_vote_governance_proposals_private_create() {
  local label="${1:-}" output_name="${2:-}" created=""

  [[ "${label}" =~ ^[a-z][a-z0-9-]{0,31}$ &&
     "${output_name}" =~ ^governance_proposals_[a-z0-9_]+_file$ ]] ||
    return 1
  created="$("${governance_proposals_mktemp_path}" \
    "${governance_proposals_private_parent}/governance-proposals-${label}.XXXXXXXX")" ||
    return 1
  governance_proposals_temp_files+=("${created}")
  "${governance_proposals_chmod_path}" 0600 "${created}" || return 1
  _cntools_action_vote_governance_proposals_file_validate \
    "${created}" 600 1 Y || return 1
  builtin printf -v "${output_name}" '%s' "${created}"
}

_cntools_action_vote_governance_proposals_private_release() {
  local output_name="${1:-}" target=""

  [[ "${output_name}" =~ ^governance_proposals_[a-z0-9_]+_file$ ]] ||
    return 1
  target="${!output_name:-}"
  [[ -n "${target}" ]] || return 0
  "${governance_proposals_rm_path}" -f -- "${target}" \
    >/dev/null 2>&1 || return 1
  builtin printf -v "${output_name}" '%s' ''
}

_cntools_action_vote_governance_proposals_integer_valid() {
  local value="${1:-}" maximum="${2:-45000000000000000}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,16})$ &&
     "${maximum}" =~ ^[1-9][0-9]{0,16}$ &&
     "${value}" -le "${maximum}" ]]
}

_cntools_action_vote_governance_proposals_decimal_valid() {
  local value="${1:-}"

  [[ "${value}" =~ ^(0|[1-9][0-9]{0,15})([.][0-9]{1,16})?$ ]] ||
    return 1
  "${governance_proposals_awk_path}" -v value="${value}" \
    'BEGIN { exit !(value >= 0 && value <= 100) }' </dev/null
}

_cntools_action_vote_governance_proposals_terminal_value_valid() {
  local value="${1:-}" maximum="${2:-2048}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ &&
     "${#value}" -le "${maximum}" &&
     "${value}" != *$'\n'* && "${value}" != *$'\r'* &&
     ! "${value}" =~ [[:cntrl:]] ]]
}

_cntools_action_vote_governance_proposals_name_valid() {
  local value="${1:-}"

  [[ "${#value}" -ge 1 && "${#value}" -le 128 &&
     "${value}" =~ ^[A-Za-z0-9._+@:-]+$ &&
     "${value}" != . && "${value}" != .. ]]
}

_cntools_action_vote_governance_proposals_url_valid() {
  local value="${1:-}" authority=""

  [[ "${#value}" -ge 9 && "${#value}" -le 2048 &&
     "${value}" == https://* && "${value}" != *\\* &&
     "${value}" != *'#'* && ! "${value}" =~ [[:cntrl:][:space:]] ]] ||
    return 1
  authority="${value#https://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  [[ -n "${authority}" && "${authority}" != .* &&
     "${authority}" != *..* &&
     "${authority}" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]
}

_cntools_action_vote_governance_proposals_api_base_valid() {
  local value="${1:-}"

  _cntools_action_vote_governance_proposals_url_valid "${value}" &&
    [[ "${value}" != *'?'* && "${value}" != */ ]]
}

_cntools_action_vote_governance_proposals_input_file_valid() {
  _cntools_action_vote_governance_proposals_file_validate \
    "${1:-}" 400,440,444,600,640,644 65536 N
}

_cntools_action_vote_governance_proposals_output_capture() {
  local maximum="${1:-}" output_name="${2:-}" output_file="" value=""
  shift 2 || return 1

  [[ "${maximum}" =~ ^[1-9][0-9]*$ &&
     "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $# -gt 0 ]] ||
    return 1
  _cntools_action_vote_governance_proposals_private_create command \
    governance_proposals_command_file || return 70
  if ! "$@" > "${governance_proposals_command_file}" 2>/dev/null; then
    _cntools_action_vote_governance_proposals_private_release \
      governance_proposals_command_file || return 70
    return 1
  fi
  _cntools_action_vote_governance_proposals_file_validate \
    "${governance_proposals_command_file}" 600 "${maximum}" N || return 70
  IFS= read -r value < "${governance_proposals_command_file}" || return 70
  [[ -n "${value}" && "${#value}" -le "${maximum}" &&
     "$(( $("${governance_proposals_wc_path}" -l < \
       "${governance_proposals_command_file}") ))" -eq 1 ]] || return 70
  builtin printf -v "${output_name}" '%s' "${value}"
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_command_file || return 70
}

_cntools_action_vote_governance_proposals_fetch() {
  local kind="${1:-}" url="${2:-}" target="${3:-}"
  local limit="" curl_status=0 size=""
  local -a command=()

  case "${kind}" in
    count) limit=16384 ;;
    list) limit=1048576 ;;
    summary|committee) limit=65536 ;;
    votes|detail) limit=524288 ;;
    metadata) limit=262144 ;;
    *) return 70 ;;
  esac
  _cntools_action_vote_governance_proposals_url_valid "${url}" || return 2
  _cntools_action_vote_governance_proposals_file_validate \
    "${target}" 600 1 Y || return 70
  command=(
    "${governance_proposals_curl_path}"
    --disable
    --silent
    --location
    --max-redirs 3
    --proto '=https'
    --proto-redir '=https'
    --max-time "${governance_proposals_curl_timeout}"
    --fail
    --max-filesize "${limit}"
  )
  if [[ "${kind}" != metadata ]]; then
    command+=("${governance_proposals_koios_headers[@]}")
    command+=(--header 'Accept: application/json')
    println ACTION 'curl [configured headers redacted] CNTools proposal query'
  else
    println ACTION 'curl CNTools governance proposal anchor query'
  fi
  command+=(--output "${target}" --url "${url}")
  if "${command[@]}" 2>/dev/null; then
    curl_status=0
  else
    curl_status=$?
  fi
  size="$(_cntools_action_vote_governance_proposals_file_size "${target}")" ||
    return 70
  if [[ "${curl_status}" == 63 || "${size}" -gt "${limit}" ]]; then
    return 63
  fi
  [[ "${curl_status}" == 0 && "${size}" -ge 1 ]] || return 1
}

_cntools_action_vote_governance_proposals_query_begin() {
  local message="${1:-}"

  _cntools_action_vote_governance_proposals_terminal_value_valid \
    "${message}" 256 || return 70
  tput sc || return 70
  governance_proposals_terminal_saved=Y
  println DEBUG "${message}"
}

_cntools_action_vote_governance_proposals_query_end() {
  _cntools_action_vote_governance_proposals_terminal_restore || return 70
}

_cntools_action_vote_governance_proposals_action_id_encode() {
  local tx="${1:-}" index="${2:-}" output_name="${3:-}" encoded=""

  [[ "${tx}" =~ ^[0-9A-Fa-f]{64}$ &&
     "${index}" =~ ^(0|[1-9][0-9]{0,2})$ && "${index}" -le 255 &&
     "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _cntools_action_vote_governance_proposals_output_capture 160 encoded \
    "${governance_proposals_bech32_path}" gov_action \
    <<< "${tx,,}$(builtin printf '%02x' "${index}")" || return $?
  [[ "${encoded}" =~ ^gov_action1[023456789ac-hj-np-z]{1,140}$ ]] || return 70
  builtin printf -v "${output_name}" '%s' "${encoded}"
}

_cntools_action_vote_governance_proposals_action_id_parse() {
  local input="${1:-}" decoded="" reencoded="" index_hex=""

  action_tx_id="" action_idx=""
  if [[ "${input}" =~ ^([0-9A-Fa-f]{64})#(0|[1-9][0-9]{0,2})$ ]]; then
    action_tx_id="${BASH_REMATCH[1],,}"
    action_idx="${BASH_REMATCH[2]}"
    [[ "${action_idx}" -le 255 ]] || return 1
    return 0
  fi
  [[ "${input}" =~ ^gov_action1[023456789ac-hj-np-z]{1,140}$ ]] || return 1
  _cntools_action_vote_governance_proposals_output_capture 132 decoded \
    "${governance_proposals_bech32_path}" <<< "${input}" || return 1
  [[ "${decoded}" =~ ^[0-9A-Fa-f]{66}$ ]] || return 1
  action_tx_id="${decoded:0:64}"
  index_hex="${decoded:64:2}"
  action_idx="$((16#${index_hex}))"
  _cntools_action_vote_governance_proposals_action_id_encode \
    "${action_tx_id}" "${action_idx}" reencoded || return 1
  [[ "${reencoded}" == "${input}" ]]
}

_cntools_action_vote_governance_proposals_directory_list() {
  local root="${1:-}" output_name="${2:-}" unsorted=""

  [[ "${output_name}" =~ ^governance_proposals_(wallet|pool)_list_file$ ]] ||
    return 1
  _cntools_action_vote_governance_proposals_private_create directories \
    governance_proposals_scan_file || return 70
  unsorted="${governance_proposals_scan_file}"
  "${governance_proposals_find_path}" "${root}" -mindepth 1 -maxdepth 1 \
    -type d -print0 > "${unsorted}" 2>/dev/null || return 70
  _cntools_action_vote_governance_proposals_file_validate \
    "${unsorted}" 600 1048576 Y || return 70
  _cntools_action_vote_governance_proposals_private_create directories \
    "${output_name}" || return 70
  LC_ALL=C "${governance_proposals_sort_path}" -z "${unsorted}" \
    > "${!output_name}" || return 70
  _cntools_action_vote_governance_proposals_file_validate \
    "${!output_name}" 600 1048576 Y || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_scan_file || return 70
}

_cntools_action_vote_governance_proposals_identity_append() {
  local role="${1:-}" hex="${2:-}" name="${3:-}"

  case "${role}" in DRep|ConstitutionalCommittee|SPO) ;; *) return 1 ;; esac
  [[ "${hex}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 1
  _cntools_action_vote_governance_proposals_name_valid "${name}" || return 1
  "${governance_proposals_jq_path}" -cn \
    --arg role "${role}" --arg hex "${hex,,}" --arg name "${name}" \
    '{role:$role,hex:$hex,name:$name}' \
    >> "${governance_proposals_identities_ndjson_file}" || return 70
}

_cntools_action_vote_governance_proposals_identities() {
  local directory="" name="" key_file="" output="" decoded=""

  _cntools_action_vote_governance_proposals_private_create identities \
    governance_proposals_identities_ndjson_file || return 70
  _cntools_action_vote_governance_proposals_directory_list \
    "${governance_proposals_wallet_root_physical}" \
    governance_proposals_wallet_list_file || return 70
  while IFS= read -r -d '' directory; do
    [[ "${directory%/*}" == "${governance_proposals_wallet_root_physical}" &&
       -d "${directory}" && ! -L "${directory}" ]] || return 70
    _cntools_registry_path_has_no_symlinks "${directory}" || return 70
    name="${directory##*/}"
    _cntools_action_vote_governance_proposals_name_valid "${name}" || return 70
    key_file="${directory}/${WALLET_GOV_DREP_VK_FILENAME}"
    if [[ -e "${key_file}" || -L "${key_file}" ]]; then
      _cntools_action_vote_governance_proposals_input_file_valid \
        "${key_file}" || return 70
      _cntools_action_vote_governance_proposals_output_capture 256 output \
        "${governance_proposals_ccli_path}" latest governance drep id \
        --drep-verification-key-file "${key_file}" || return 70
      _cntools_action_vote_governance_proposals_output_capture 132 decoded \
        "${governance_proposals_bech32_path}" <<< "${output}" || return 70
      [[ "${decoded}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
      _cntools_action_vote_governance_proposals_identity_append \
        DRep "${decoded}" "${name}" || return 70
    fi
    key_file="${directory}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
    if [[ -e "${key_file}" || -L "${key_file}" ]]; then
      _cntools_action_vote_governance_proposals_input_file_valid \
        "${key_file}" || return 70
      _cntools_action_vote_governance_proposals_output_capture 132 output \
        "${governance_proposals_ccli_path}" latest governance committee \
        key-hash --verification-key-file "${key_file}" || return 70
      [[ "${output}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
      _cntools_action_vote_governance_proposals_identity_append \
        ConstitutionalCommittee "${output}" "${name}" || return 70
    fi
  done < "${governance_proposals_wallet_list_file}"
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_wallet_list_file || return 70

  _cntools_action_vote_governance_proposals_directory_list \
    "${governance_proposals_pool_root_physical}" \
    governance_proposals_pool_list_file || return 70
  while IFS= read -r -d '' directory; do
    [[ "${directory%/*}" == "${governance_proposals_pool_root_physical}" &&
       -d "${directory}" && ! -L "${directory}" ]] || return 70
    _cntools_registry_path_has_no_symlinks "${directory}" || return 70
    name="${directory##*/}"
    _cntools_action_vote_governance_proposals_name_valid "${name}" || return 70
    key_file="${directory}/${POOL_COLDKEY_VK_FILENAME}"
    if [[ -e "${key_file}" || -L "${key_file}" ]]; then
      _cntools_action_vote_governance_proposals_input_file_valid \
        "${key_file}" || return 70
      _cntools_action_vote_governance_proposals_output_capture 132 output \
        "${governance_proposals_ccli_path}" latest stake-pool id \
        --cold-verification-key-file "${key_file}" --output-format hex ||
        return 70
      [[ "${output}" =~ ^[0-9A-Fa-f]{56}$ ]] || return 70
      _cntools_action_vote_governance_proposals_identity_append \
        SPO "${output}" "${name}" || return 70
    fi
  done < "${governance_proposals_pool_list_file}"
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_pool_list_file || return 70

  _cntools_action_vote_governance_proposals_private_create identities \
    governance_proposals_identities_file || return 70
  "${governance_proposals_jq_path}" -s \
    'sort_by(.role,.name,.hex) | unique_by(.role,.name,.hex)' \
    "${governance_proposals_identities_ndjson_file}" \
    > "${governance_proposals_identities_file}" || return 70
  _cntools_action_vote_governance_proposals_file_validate \
    "${governance_proposals_identities_file}" 600 1048576 N || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_identities_ndjson_file || return 70
}

_cntools_action_vote_governance_proposals_threshold() {
  local action_type="${1:-}" security="${2:-N}" role="${3:-}"
  local query="" value=""

  case "${action_type}:${role}" in
    InfoAction:*) return 1 ;;
    NoConfidence:DRep) query='.dRepVotingThresholds.motionNoConfidence' ;;
    NoConfidence:SPO) query='.poolVotingThresholds.motionNoConfidence' ;;
    HardForkInitiation:DRep) query='.dRepVotingThresholds.hardForkInitiation' ;;
    HardForkInitiation:SPO) query='.poolVotingThresholds.hardForkInitiation' ;;
    HardForkInitiation:Committee) value="${governance_proposals_cc_threshold}" ;;
    NewCommittee:DRep|UpdateCommittee:DRep) query='.dRepVotingThresholds.committeeNormal' ;;
    NewCommittee:SPO|UpdateCommittee:SPO) query='.poolVotingThresholds.committeeNormal' ;;
    TreasuryWithdrawals:DRep) query='.dRepVotingThresholds.treasuryWithdrawal' ;;
    TreasuryWithdrawals:Committee) value="${governance_proposals_cc_threshold}" ;;
    ParameterChange:DRep)
      query='[
        .dRepVotingThresholds.ppEconomicGroup,
        .dRepVotingThresholds.ppGovGroup,
        .dRepVotingThresholds.ppNetworkGroup,
        .dRepVotingThresholds.ppTechnicalGroup
      ] | max'
      ;;
    ParameterChange:SPO)
      [[ "${security}" == Y ]] || return 1
      query='.poolVotingThresholds.ppSecurityGroup'
      ;;
    ParameterChange:Committee) value="${governance_proposals_cc_threshold}" ;;
    NewConstitution:DRep) query='.dRepVotingThresholds.updateToConstitution' ;;
    NewConstitution:Committee) value="${governance_proposals_cc_threshold}" ;;
    *) return 1 ;;
  esac
  if [[ -n "${query}" ]]; then
    value="$("${governance_proposals_jq_path}" -er \
      "(${query}) * 100" <<< "${PROT_PARAMS}" 2>/dev/null)" || return 70
    _cntools_action_vote_governance_proposals_decimal_valid "${value}" ||
      return 70
    value="$("${governance_proposals_awk_path}" -v value="${value}" '
      BEGIN {
        formatted=sprintf("%.8f",value)
        sub(/0+$/, "", formatted); sub(/\.$/, "", formatted)
        print formatted
      }
    ' </dev/null)" || return 70
  fi
  _cntools_action_vote_governance_proposals_decimal_valid "${value}" ||
    return 70
  builtin printf '%s\n' "${value}"
}

_cntools_action_vote_governance_proposals_role_allowed() {
  local role="${1:-}" action_type="${2:-}" security="${3:-N}"

  case "${action_type}" in
    InfoAction) return 0 ;;
    NoConfidence|NewCommittee|UpdateCommittee)
      [[ "${role}" != Committee ]]
      ;;
    HardForkInitiation)
      if [[ "${role}" == DRep ]]; then
        versionCheck '10.0' "${PROT_VERSION}"
      else
        return 0
      fi
      ;;
    TreasuryWithdrawals|NewConstitution) [[ "${role}" != SPO ]] ;;
    ParameterChange)
      if [[ "${role}" == SPO ]]; then
        [[ "${security}" == Y ]]
      elif [[ "${role}" == DRep ]]; then
        versionCheck '10.0' "${PROT_VERSION}"
      else
        return 0
      fi
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_vote_governance_proposals_protocol_validate() {
  [[ "${#PROT_PARAMS}" -le 65536 &&
     "${PROT_VERSION}" =~ ^[0-9]{1,3}([.][0-9]{1,3}){0,2}$ ]] || return 1
  "${governance_proposals_jq_path}" -e '
    def threshold: type == "number" and . >= 0 and . <= 1;
    type == "object" and
    (.dRepVotingThresholds | type == "object") and
    (.poolVotingThresholds | type == "object") and
    all([
      .dRepVotingThresholds.committeeNormal,
      .dRepVotingThresholds.hardForkInitiation,
      .dRepVotingThresholds.motionNoConfidence,
      .dRepVotingThresholds.ppEconomicGroup,
      .dRepVotingThresholds.ppGovGroup,
      .dRepVotingThresholds.ppNetworkGroup,
      .dRepVotingThresholds.ppTechnicalGroup,
      .dRepVotingThresholds.treasuryWithdrawal,
      .dRepVotingThresholds.updateToConstitution,
      .poolVotingThresholds.committeeNormal,
      .poolVotingThresholds.hardForkInitiation,
      .poolVotingThresholds.motionNoConfidence,
      .poolVotingThresholds.ppSecurityGroup
    ][]; threshold)
  ' <<< "${PROT_PARAMS}" >/dev/null 2>&1
}

_cntools_action_vote_governance_proposals_remote_schema() {
  local kind="${1:-}" target="${2:-}"

  case "${kind}" in
    count)
      "${governance_proposals_jq_path}" -e '
        type == "array" and length == 1 and
        (.[0] | type == "object" and keys == ["count"] and
          (.count | type == "number" and floor == . and . >= 0 and . <= 100))
      ' "${target}" >/dev/null 2>&1
      ;;
    list)
      "${governance_proposals_jq_path}" -e '
        def uint($max): type == "number" and floor == . and . >= 0 and . <= $max;
        def text($max): type == "string" and length <= $max and
          (test("[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]") | not);
        def safe:
          if type == "string" then text(8192)
          elif type == "array" then length <= 4096 and all(.[]; safe)
          elif type == "object" then length <= 4096 and all(keys[]; text(256)) and all(.[]; safe)
          else true end;
        type == "array" and length <= 100 and
        all(.[];
          type == "object" and safe and
          keys == ["block_time","expiration","meta_url","param_proposal","proposal_id","proposal_index","proposal_tx_hash","proposal_type","proposed_epoch"] and
          (.block_time | uint(45000000000000000)) and
          (.proposal_id | text(256) and test("^[A-Za-z0-9._:-]{1,256}$")) and
          (.proposal_tx_hash | text(64) and test("^[0-9A-Fa-f]{64}$")) and
          (.proposal_index | uint(255)) and
          (.proposal_type | IN("InfoAction","NoConfidence","HardForkInitiation","NewCommittee","UpdateCommittee","TreasuryWithdrawals","ParameterChange","NewConstitution")) and
          (.proposed_epoch | uint(4294967295)) and
          (.expiration | uint(4294967295) and . >= 1) and
          (.meta_url | text(2048)) and
          (.param_proposal | type == "object" and safe))
      ' "${target}" >/dev/null 2>&1
      ;;
    summary)
      "${governance_proposals_jq_path}" -e '
        def uint($max): type == "number" and floor == . and . >= 0 and . <= $max;
        def pct: type == "number" and . >= 0 and . <= 100;
        type == "array" and length == 1 and
        (.[0] | type == "object" and keys == [
          "committee_no_pct","committee_no_votes_cast","committee_yes_pct","committee_yes_votes_cast",
          "drep_no_pct","drep_no_vote_power","drep_no_votes_cast","drep_yes_pct","drep_yes_vote_power","drep_yes_votes_cast",
          "pool_no_pct","pool_no_vote_power","pool_no_votes_cast","pool_yes_pct","pool_yes_vote_power","pool_yes_votes_cast"
        ] and
        all([.drep_yes_votes_cast,.drep_no_votes_cast,.pool_yes_votes_cast,.pool_no_votes_cast,.committee_yes_votes_cast,.committee_no_votes_cast][]; uint(100000000)) and
        all([.drep_yes_vote_power,.drep_no_vote_power,.pool_yes_vote_power,.pool_no_vote_power][]; uint(45000000000000000)) and
        all([.drep_yes_pct,.drep_no_pct,.pool_yes_pct,.pool_no_pct,.committee_yes_pct,.committee_no_pct][]; pct))
      ' "${target}" >/dev/null 2>&1
      ;;
    votes)
      "${governance_proposals_jq_path}" -e '
        type == "array" and length <= 10000 and
        all(.[]; type == "object" and keys == ["vote","voter_hex","voter_role"] and
          (.voter_role | IN("DRep","ConstitutionalCommittee","SPO")) and
          (.voter_hex | type == "string" and test("^[0-9A-Fa-f]{56}$")) and
          (.vote | IN("Yes","No","Abstain")))
      ' "${target}" >/dev/null 2>&1
      ;;
    committee)
      "${governance_proposals_jq_path}" -e '
        type == "array" and length == 1 and
        (.[0] | type == "object" and
          keys == ["quorum_denominator","quorum_numerator"] and
          (.quorum_numerator | type == "number" and floor == . and . >= 0 and . <= 1000000) and
          (.quorum_denominator | type == "number" and floor == . and . >= 1 and . <= 1000000))
      ' "${target}" >/dev/null 2>&1
      ;;
    detail)
      "${governance_proposals_jq_path}" -e '
        def safe:
          if type == "string" then length <= 8192 and
            (test("[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]") | not)
          elif type == "array" then length <= 4096 and all(.[]; safe)
          elif type == "object" then length <= 4096 and all(keys[]; safe) and all(.[]; safe)
          else true end;
        type == "array" and length <= 1 and safe and
        all(.[];
          keys == ["expiration","meta_hash","meta_url","param_proposal","proposal_index","proposal_tx_hash","proposal_type","proposed_epoch"] and
          (.proposal_tx_hash | type == "string" and test("^[0-9A-Fa-f]{64}$")) and
          (.proposal_index | type == "number" and floor == . and . >= 0 and . <= 255) and
          (.meta_url | type == "string" and length <= 2048) and
          (.meta_hash | type == "string" and (length == 0 or test("^[0-9A-Fa-f]{64}$"))))
      ' "${target}" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

_cntools_action_vote_governance_proposals_committee_remote() {
  local numerator="" denominator="" fields=""

  _cntools_action_vote_governance_proposals_private_create committee \
    governance_proposals_committee_file || return 70
  _cntools_action_vote_governance_proposals_fetch committee \
    "${governance_proposals_koios_api}/committee_info" \
    "${governance_proposals_committee_file}" || return 1
  _cntools_action_vote_governance_proposals_remote_schema committee \
    "${governance_proposals_committee_file}" || return 1
  fields="$("${governance_proposals_jq_path}" -r \
    '.[0] | [.quorum_numerator,.quorum_denominator] | @tsv' \
    "${governance_proposals_committee_file}")" || return 70
  IFS=$'\t' read -r numerator denominator <<< "${fields}" || return 70
  governance_proposals_cc_threshold="$("${governance_proposals_awk_path}" \
    -v numerator="${numerator}" -v denominator="${denominator}" \
    'BEGIN { printf "%.2f", numerator / denominator * 100 }' </dev/null)" ||
    return 70
  _cntools_action_vote_governance_proposals_decimal_valid \
    "${governance_proposals_cc_threshold}" || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_committee_file || return 70
}

_cntools_action_vote_governance_proposals_remote() {
  local count="" list_count="" index=0 proposal="" proposal_id=""
  local tx="" action_index="" action_type="" proposed="" expiration=""
  local anchor="" block_time="" parameter="" security=N summary="" own=""
  local drep_threshold="" spo_threshold="" cc_threshold="" fetch_status=0
  local fields=""

  _cntools_action_vote_governance_proposals_private_create count \
    governance_proposals_count_file || return 70
  if ! _cntools_action_vote_governance_proposals_fetch count \
      "${governance_proposals_koios_api}/proposal_list?select=count()&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null" \
      "${governance_proposals_count_file}"; then
    return 1
  fi
  _cntools_action_vote_governance_proposals_remote_schema count \
    "${governance_proposals_count_file}" || return 1
  count="$("${governance_proposals_jq_path}" -er '.[0].count' \
    "${governance_proposals_count_file}")" || return 70
  governance_proposals_vote_action_count="${count}"
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_count_file || return 70
  [[ "${count}" -gt 0 ]] || return 0

  _cntools_action_vote_governance_proposals_identities || return 70
  _cntools_action_vote_governance_proposals_committee_remote || return $?
  _cntools_action_vote_governance_proposals_private_create proposals \
    governance_proposals_source_file || return 70
  if ! _cntools_action_vote_governance_proposals_fetch list \
      "${governance_proposals_koios_api}/proposal_list?select=block_time,proposal_id,proposal_tx_hash,proposal_index,proposal_type,proposed_epoch,expiration,meta_url,param_proposal&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null&order=block_time.desc,proposal_tx_hash.asc,proposal_index.asc" \
      "${governance_proposals_source_file}"; then
    return 1
  fi
  _cntools_action_vote_governance_proposals_remote_schema list \
    "${governance_proposals_source_file}" || return 1
  list_count="$("${governance_proposals_jq_path}" -er 'length' \
    "${governance_proposals_source_file}")" || return 70
  [[ "${list_count}" == "${count}" ]] || return 1
  _cntools_action_vote_governance_proposals_private_create records \
    governance_proposals_records_ndjson_file || return 70
  for ((index=0; index<count; index++)); do
    proposal="$("${governance_proposals_jq_path}" -ce ".[${index}]" \
      "${governance_proposals_source_file}")" || return 70
    fields="$("${governance_proposals_jq_path}" -r \
      '[.block_time,.proposal_id,.proposal_tx_hash,.proposal_index,.proposal_type,.proposed_epoch,.expiration,.meta_url] | @tsv' \
      <<< "${proposal}")" || return 70
    IFS=$'\t' read -r block_time proposal_id tx action_index action_type \
      proposed expiration anchor <<< "${fields}" || return 70
    parameter="$("${governance_proposals_jq_path}" -c '.param_proposal' \
      <<< "${proposal}")" || return 70
    security=N
    if "${governance_proposals_jq_path}" -e '
        keys | any(. == "max_block_size" or . == "max_tx_size" or
          . == "max_bh_size" or . == "max_val_size" or
          . == "max_block_ex_units" or . == "min_fee_a" or
          . == "min_fee_b" or . == "coins_per_utxo_size" or
          . == "gov_action_deposit" or
          . == "min_fee_ref_script_cost_per_byte")
      ' <<< "${parameter}" >/dev/null 2>&1; then
      security=Y
    fi
    drep_threshold="$(_cntools_action_vote_governance_proposals_threshold \
      "${action_type}" "${security}" DRep)" || {
        [[ $? == 1 ]] && drep_threshold="" || return 70;
      }
    spo_threshold="$(_cntools_action_vote_governance_proposals_threshold \
      "${action_type}" "${security}" SPO)" || {
        [[ $? == 1 ]] && spo_threshold="" || return 70;
      }
    cc_threshold="$(_cntools_action_vote_governance_proposals_threshold \
      "${action_type}" "${security}" Committee)" || {
        [[ $? == 1 ]] && cc_threshold="" || return 70;
      }
    _cntools_action_vote_governance_proposals_private_create summary \
      governance_proposals_summary_file || return 70
    if _cntools_action_vote_governance_proposals_fetch summary \
        "${governance_proposals_koios_api}/proposal_voting_summary?_proposal_id=${proposal_id}&select=drep_yes_votes_cast,drep_yes_vote_power,drep_yes_pct,drep_no_votes_cast,drep_no_vote_power,drep_no_pct,pool_yes_votes_cast,pool_yes_vote_power,pool_yes_pct,pool_no_votes_cast,pool_no_vote_power,pool_no_pct,committee_yes_votes_cast,committee_yes_pct,committee_no_votes_cast,committee_no_pct" \
        "${governance_proposals_summary_file}"; then
      fetch_status=0
    else
      fetch_status=$?
    fi
    [[ "${fetch_status}" == 0 ]] || return 1
    _cntools_action_vote_governance_proposals_remote_schema summary \
      "${governance_proposals_summary_file}" || return 1
    summary="$("${governance_proposals_jq_path}" -ce '.[0]' \
      "${governance_proposals_summary_file}")" || return 70
    _cntools_action_vote_governance_proposals_private_release \
      governance_proposals_summary_file || return 70
    _cntools_action_vote_governance_proposals_private_create votes \
      governance_proposals_votes_file || return 70
    if _cntools_action_vote_governance_proposals_fetch votes \
        "${governance_proposals_koios_api}/proposal_votes?_proposal_id=${proposal_id}&select=voter_role,voter_hex,vote" \
        "${governance_proposals_votes_file}"; then
      fetch_status=0
    else
      fetch_status=$?
    fi
    [[ "${fetch_status}" == 0 ]] || return 1
    _cntools_action_vote_governance_proposals_remote_schema votes \
      "${governance_proposals_votes_file}" || return 1
    own="$("${governance_proposals_jq_path}" -c \
      --slurpfile identities "${governance_proposals_identities_file}" '
        . as $votes |
        [$identities[0][] as $identity |
          $votes[] |
          select(.voter_role == $identity.role and
            (.voter_hex | ascii_downcase) == $identity.hex) |
          {role:.voter_role,name:$identity.name,vote:.vote}]
        | sort_by(.role,.name,.vote) | unique_by(.role,.name,.vote)
      ' "${governance_proposals_votes_file}")" || return 70
    _cntools_action_vote_governance_proposals_private_release \
      governance_proposals_votes_file || return 70
    "${governance_proposals_jq_path}" -cn \
      --argjson raw "${proposal}" --argjson summary "${summary}" \
      --argjson own "${own}" --arg blockTime "${block_time}" \
      --arg proposalId "${proposal_id}" --arg tx "${tx,,}" \
      --arg index "${action_index}" --arg type "${action_type}" \
      --arg proposed "${proposed}" --arg expires "$((expiration - 1))" \
      --arg anchor "${anchor}" --arg security "${security}" \
      --arg drepThreshold "${drep_threshold}" \
      --arg spoThreshold "${spo_threshold}" --arg ccThreshold "${cc_threshold}" '
        {
          blockTime:($blockTime|tonumber), proposalId:$proposalId,
          tx:$tx,index:($index|tonumber),id:($tx+"#"+$index),type:$type,
          proposedIn:($proposed|tonumber),expiresAfter:($expires|tonumber),
          anchorUrl:$anchor,metaHash:"",security:$security,
          drep:{yesCount:$summary.drep_yes_votes_cast,yesPower:$summary.drep_yes_vote_power,yesPct:$summary.drep_yes_pct,
            noCount:$summary.drep_no_votes_cast,noPower:$summary.drep_no_vote_power,noPct:$summary.drep_no_pct,threshold:$drepThreshold},
          spo:{yesCount:$summary.pool_yes_votes_cast,yesPower:$summary.pool_yes_vote_power,yesPct:$summary.pool_yes_pct,
            noCount:$summary.pool_no_votes_cast,noPower:$summary.pool_no_vote_power,noPct:$summary.pool_no_pct,threshold:$spoThreshold},
          committee:{yesCount:$summary.committee_yes_votes_cast,yesPower:0,yesPct:$summary.committee_yes_pct,
            noCount:$summary.committee_no_votes_cast,noPower:0,noPct:$summary.committee_no_pct,threshold:$ccThreshold},
          ownVotes:$own,raw:$raw
        }
      ' >> "${governance_proposals_records_ndjson_file}" || return 70
  done
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_source_file || return 70
  _cntools_action_vote_governance_proposals_private_create records \
    governance_proposals_records_file || return 70
  "${governance_proposals_jq_path}" -s \
    'sort_by([(-.blockTime),.tx,.index])' \
    "${governance_proposals_records_ndjson_file}" \
    > "${governance_proposals_records_file}" || return 70
  _cntools_action_vote_governance_proposals_file_validate \
    "${governance_proposals_records_file}" 600 4194304 N || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_records_ndjson_file || return 70
}

_cntools_action_vote_governance_proposals_local_query() {
  local label="${1:-}" target_name="${2:-}"
  shift 2 || return 1

  _cntools_action_vote_governance_proposals_private_create "${label}" \
    "${target_name}" || return 70
  if ! "${governance_proposals_ccli_path}" "$@" \
      "${governance_proposals_network_args[@]}" > "${!target_name}" \
      2>/dev/null; then
    return 1
  fi
  _cntools_action_vote_governance_proposals_file_validate \
    "${!target_name}" 600 4194304 N || return 70
}

_cntools_action_vote_governance_proposals_local() {
  local count="" fields=""

  _cntools_action_vote_governance_proposals_local_query govstate \
    governance_proposals_govstate_file latest query gov-state || return $?
  "${governance_proposals_jq_path}" -e '
    def uint($max): type == "number" and floor == . and . >= 0 and . <= $max;
    def safe:
      if type == "string" then length <= 8192 and
        (test("[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]") | not)
      elif type == "array" then length <= 4096 and all(.[]; safe)
      elif type == "object" then length <= 4096 and all(keys[]; safe) and all(.[]; safe)
      else true end;
    type == "object" and safe and
    (.proposals | (type == "object" or type == "array") and length <= 100 and
      all(.[];
        (.actionId.txId | type == "string" and test("^[0-9A-Fa-f]{64}$")) and
        (.actionId.govActionIx | uint(255)) and
        (.proposedIn | uint(4294967295)) and
        (.expiresAfter | uint(4294967295)) and
        (.proposalProcedure.govAction.tag | IN("InfoAction","NoConfidence","HardForkInitiation","NewCommittee","UpdateCommittee","TreasuryWithdrawals","ParameterChange","NewConstitution")) and
        (.proposalProcedure.anchor.url | type == "string" and length <= 2048) and
        (.proposalProcedure.anchor.dataHash | type == "string" and (length == 0 or test("^[0-9A-Fa-f]{64}$"))) and
        all([.dRepVotes,.stakePoolVotes,.committeeVotes][];
          type == "object" and length <= 10000 and
          all(keys[]; test("^[A-Za-z]+Hash-[0-9A-Fa-f]{56}$|^[0-9A-Fa-f]{56}$")) and
          all(.[]; IN("VoteYes","VoteNo","Abstain")))))
  ' "${governance_proposals_govstate_file}" >/dev/null 2>&1 || return 1
  count="$("${governance_proposals_jq_path}" -er '.proposals | length' \
    "${governance_proposals_govstate_file}")" || return 70
  governance_proposals_vote_action_count="${count}"
  [[ "${count}" -gt 0 ]] || return 0
  _cntools_action_vote_governance_proposals_identities || return 70
  _cntools_action_vote_governance_proposals_local_query committee \
    governance_proposals_committee_file latest query committee-state || return $?
  _cntools_action_vote_governance_proposals_local_query drep-power \
    governance_proposals_drep_power_file latest query \
    drep-stake-distribution --all-dreps || return $?
  _cntools_action_vote_governance_proposals_local_query drep-state \
    governance_proposals_drep_state_file latest query drep-state --all-dreps ||
    return $?
  _cntools_action_vote_governance_proposals_local_query spo-power \
    governance_proposals_spo_power_file latest query \
    spo-stake-distribution --all-spos || return $?
  "${governance_proposals_jq_path}" -e '
    type == "object" and
    (.threshold.numerator | type == "number" and floor == . and . >= 0 and . <= 1000000) and
    (.threshold.denominator | type == "number" and floor == . and . >= 1 and . <= 1000000) and
    (.committee | type == "object" and length <= 10000 and
      all(.[]; .hotCredsAuthStatus.tag | IN("MemberAuthorized","MemberNotAuthorized","MemberResigned")))
  ' "${governance_proposals_committee_file}" >/dev/null 2>&1 || return 1
  "${governance_proposals_jq_path}" -e '
    type == "object" and length <= 10000 and
    all(keys[]; test("^drep-(keyHash|scriptHash)-[0-9A-Fa-f]{56}$|^drep-always(Abstain|NoConfidence)$")) and
    all(.[]; type == "number" and floor == . and . >= 0 and . <= 45000000000000000)
  ' "${governance_proposals_drep_power_file}" >/dev/null 2>&1 || return 1
  "${governance_proposals_jq_path}" -e '
    type == "array" and length <= 10000 and
    all(.[]; type == "array" and length == 2 and
      (.[0] | type == "object" and
        ((.keyHash | type == "string" and test("^[0-9A-Fa-f]{56}$")) or
         (.scriptHash | type == "string" and test("^[0-9A-Fa-f]{56}$")))) and
      (.[1].expiry | type == "number" and floor == . and . >= 0 and . <= 4294967295))
  ' "${governance_proposals_drep_state_file}" >/dev/null 2>&1 || return 1
  "${governance_proposals_jq_path}" -e '
    type == "object" and length <= 10000 and
    all(.[]; type == "array" and length == 3 and
      (.[0] | type == "string" and test("^[0-9A-Fa-f]{56}$")) and
      (.[1] | type == "number" and floor == . and . >= 0 and . <= 45000000000000000) and
      (.[2] | type == "string" and length <= 128))
  ' "${governance_proposals_spo_power_file}" >/dev/null 2>&1 || return 1
  fields="$("${governance_proposals_jq_path}" -r \
    '[.threshold.numerator,.threshold.denominator] | @tsv' \
    "${governance_proposals_committee_file}")" || return 70
  IFS=$'\t' read -r governance_proposals_cc_numerator \
    governance_proposals_cc_denominator <<< "${fields}" || return 70
  governance_proposals_cc_threshold="$("${governance_proposals_awk_path}" \
    -v numerator="${governance_proposals_cc_numerator}" \
    -v denominator="${governance_proposals_cc_denominator}" \
    'BEGIN { printf "%.2f", numerator / denominator * 100 }' </dev/null)" ||
    return 70
  _cntools_action_vote_governance_proposals_decimal_valid \
    "${governance_proposals_cc_threshold}" || return 70
  _cntools_action_vote_governance_proposals_private_create records \
    governance_proposals_records_file || return 70
  "${governance_proposals_jq_path}" -n \
    --argjson epoch "${governance_proposals_current_epoch}" \
    --slurpfile gov "${governance_proposals_govstate_file}" \
    --slurpfile committee "${governance_proposals_committee_file}" \
    --slurpfile drepPower "${governance_proposals_drep_power_file}" \
    --slurpfile drepState "${governance_proposals_drep_state_file}" \
    --slurpfile spoPower "${governance_proposals_spo_power_file}" \
    --slurpfile identities "${governance_proposals_identities_file}" '
      def sum: add // 0;
      def pct($part;$total): if $total == 0 then 0 else ($part / $total * 100) end;
      def vote($map;$key): $map[$key] // empty;
      ($drepState[0] | map(select(.[1].expiry >= $epoch) |
        if .[0].keyHash then "drep-keyHash-" + .[0].keyHash
        else "drep-scriptHash-" + .[0].scriptHash end)) as $active |
      ($drepPower[0] | with_entries(.key as $key | select(
        ($key == "drep-alwaysAbstain") or
        ($key == "drep-alwaysNoConfidence") or
        ($active | index($key))))) as $drep |
      ($committee[0].committee | [.[] |
        select(.hotCredsAuthStatus.tag == "MemberAuthorized")] | length) as $ccTotal |
      [$gov[0].proposals[]] |
      sort_by([(-.proposedIn),(.actionId.txId|ascii_downcase),.actionId.govActionIx]) |
      map(. as $p |
        ($p.dRepVotes | to_entries | map(select(.value=="VoteYes") | "drep-"+.key)) as $dy |
        ($p.dRepVotes | to_entries | map(select(.value=="VoteNo") | "drep-"+.key)) as $dn |
        ($p.dRepVotes | to_entries | map(select(.value=="Abstain") | "drep-"+.key)) as $da |
        ([$drep | to_entries[] | .key as $key | select($dy | index($key)) | .value] | sum) as $dyPower0 |
        ([$drep | to_entries[] | .key as $key | select($da | index($key)) | .value] | sum) as $daPower |
        ($drep."drep-alwaysAbstain" // 0) as $alwaysAbstain |
        ($drep."drep-alwaysNoConfidence" // 0) as $alwaysNoConfidence |
        (($drep | [.[]] | sum) - $alwaysAbstain - $daPower) as $dEligible |
        ($dyPower0 + (if $p.proposalProcedure.govAction.tag == "NoConfidence" then $alwaysNoConfidence else 0 end)) as $dyPower |
        (($dEligible - $dyPower) | if . < 0 then 0 else . end) as $dnPower |
        ($p.stakePoolVotes | to_entries | map(select(.value=="VoteYes") | .key)) as $sy |
        ($p.stakePoolVotes | to_entries | map(select(.value=="VoteNo") | .key)) as $sn |
        ($p.stakePoolVotes | to_entries | map(select(.value=="Abstain") | .key)) as $sa |
        ([$spoPower[0][] | .[0] as $pool | select($sy | index($pool)) | .[1]] | sum) as $syPower0 |
        ([$spoPower[0][] | .[0] as $pool | select($sa | index($pool)) | .[1]] | sum) as $saPower |
        ([$spoPower[0][] | . as $entry | select($entry[2] == "drep-alwaysAbstain" and
          (($sy+$sn+$sa) | index($entry[0]) | not)) | $entry[1]] | sum) as $sAlwaysAbstain |
        ([$spoPower[0][] | . as $entry | select($entry[2] == "drep-alwaysNoConfidence" and
          (($sy+$sn+$sa) | index($entry[0]) | not)) | $entry[1]] | sum) as $sAlwaysNoConfidence |
        (([$spoPower[0][][1]] | sum) - $sAlwaysAbstain - $saPower) as $sEligible |
        ($syPower0 + (if $p.proposalProcedure.govAction.tag == "NoConfidence" then $sAlwaysNoConfidence else 0 end)) as $syPower |
        (($sEligible - $syPower) | if . < 0 then 0 else . end) as $snPower |
        ([$p.committeeVotes[] | select(.=="VoteYes")] | length) as $cy |
        ([$p.committeeVotes[] | select(.=="VoteNo")] | length) as $cn |
        ([$p.committeeVotes[] | select(.=="Abstain")] | length) as $ca |
        (($ccTotal - $ca) | if . < 0 then 0 else . end) as $cEligible |
        ([ $identities[0][] as $identity |
          if $identity.role == "DRep" then
            ((vote($p.dRepVotes;"keyHash-"+$identity.hex) //
              vote($p.dRepVotes;"scriptHash-"+$identity.hex)) as $v |
              select($v != null) | {role:$identity.role,name:$identity.name,vote:($v|sub("^Vote";""))})
          elif $identity.role == "SPO" then
            (vote($p.stakePoolVotes;$identity.hex) as $v |
              select($v != null) | {role:$identity.role,name:$identity.name,vote:($v|sub("^Vote";""))})
          else
            ((vote($p.committeeVotes;$identity.hex) //
              vote($p.committeeVotes;"keyHash-"+$identity.hex)) as $v |
              select($v != null) | {role:$identity.role,name:$identity.name,vote:($v|sub("^Vote";""))})
          end ] | sort_by(.role,.name,.vote) | unique_by(.role,.name,.vote)) as $own |
        ($p.proposalProcedure.govAction.contents[1] // {}) as $params |
        ($params | keys | any(. == "maxBlockBodySize" or . == "maxTxSize" or
          . == "maxBlockHeaderSize" or . == "maxValueSize" or
          . == "maxBlockExecutionUnits" or . == "txFeePerByte" or
          . == "txFeeFixed" or . == "utxoCostPerByte" or
          . == "govActionDeposit" or . == "minFeeRefScriptCostPerByte")) as $security |
        {
          blockTime:$p.proposedIn,proposalId:"",
          tx:($p.actionId.txId|ascii_downcase),index:$p.actionId.govActionIx,
          id:(($p.actionId.txId|ascii_downcase)+"#"+($p.actionId.govActionIx|tostring)),
          type:$p.proposalProcedure.govAction.tag,proposedIn:$p.proposedIn,
          expiresAfter:$p.expiresAfter,anchorUrl:$p.proposalProcedure.anchor.url,
          metaHash:$p.proposalProcedure.anchor.dataHash,
          security:(if $security then "Y" else "N" end),
          drep:{yesCount:($dy|length),yesPower:$dyPower,yesPct:pct($dyPower;$dEligible),
            noCount:($dn|length),noPower:$dnPower,noPct:pct($dnPower;$dEligible),threshold:""},
          spo:{yesCount:($sy|length),yesPower:$syPower,yesPct:pct($syPower;$sEligible),
            noCount:($sn|length),noPower:$snPower,noPct:pct($snPower;$sEligible),threshold:""},
          committee:{yesCount:$cy,yesPower:0,yesPct:pct($cy;$cEligible),
            noCount:$cn,noPower:0,noPct:pct(($cEligible-$cy);$cEligible),threshold:""},
          ownVotes:$own,raw:$p
        })
    ' > "${governance_proposals_records_file}" 2>/dev/null || return 1
  _cntools_action_vote_governance_proposals_file_validate \
    "${governance_proposals_records_file}" 600 4194304 N || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_drep_power_file || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_drep_state_file || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_spo_power_file || return 70
  _cntools_action_vote_governance_proposals_private_release \
    governance_proposals_committee_file || return 70
}

_cntools_action_vote_governance_proposals_pct_text() {
  local value="${1:-}" output_name="${2:-}" formatted=""

  _cntools_action_vote_governance_proposals_decimal_valid "${value}" ||
    return 70
  formatted="$("${governance_proposals_awk_path}" -v value="${value}" '
    BEGIN {
      formatted=sprintf("%.2f",value)
      sub(/0+$/, "", formatted); sub(/\.$/, "", formatted)
      print formatted
    }
  ' </dev/null)" || return 70
  builtin printf -v "${output_name}" '%s' "${formatted}"
}

_cntools_action_vote_governance_proposals_render_role() {
  local role="${1:-}" json="${2:-}" action_type="${3:-}" security="${4:-N}"
  local yes_count="" yes_power="" yes_pct="" no_count="" no_power=""
  local no_pct="" threshold="" yes_power_human="" no_power_human=""
  local status="" fields=""

  fields="$("${governance_proposals_jq_path}" -r \
    '[.yesCount,.yesPower,.yesPct,.noCount,.noPower,.noPct,.threshold] | @tsv' \
    <<< "${json}")" || return 70
  IFS=$'\t' read -r yes_count yes_power yes_pct no_count no_power no_pct \
    threshold <<< "${fields}" || return 70
  _cntools_action_vote_governance_proposals_integer_valid "${yes_count}" 100000000 &&
    _cntools_action_vote_governance_proposals_integer_valid "${no_count}" 100000000 &&
    _cntools_action_vote_governance_proposals_integer_valid "${yes_power}" &&
    _cntools_action_vote_governance_proposals_integer_valid "${no_power}" || return 70
  _cntools_action_vote_governance_proposals_pct_text "${yes_pct}" yes_pct || return 70
  _cntools_action_vote_governance_proposals_pct_text "${no_pct}" no_pct || return 70
  if [[ -z "${threshold}" ]]; then
    threshold="$(_cntools_action_vote_governance_proposals_threshold \
      "${action_type}" "${security}" "${role}")" || {
        [[ $? == 1 ]] && threshold="" || return 70;
      }
  fi
  if ! _cntools_action_vote_governance_proposals_role_allowed \
      "${role}" "${action_type}" "${security}"; then
    builtin printf '| %-13s : %sN|A%s\n' "${role}" "${FG_DGRAY}" "${NC}"
    return 0
  fi
  yes_power_human="$(formatLovelaceHuman "${yes_power}")" || return 70
  no_power_human="$(formatLovelaceHuman "${no_power}")" || return 70
  _cntools_action_vote_governance_proposals_terminal_value_valid \
    "${yes_power_human}" 128 &&
    _cntools_action_vote_governance_proposals_terminal_value_valid \
      "${no_power_human}" 128 || return 70
  status="${yes_pct}%"
  if [[ -n "${threshold}" ]]; then
    _cntools_action_vote_governance_proposals_decimal_valid "${threshold}" ||
      return 70
    if "${governance_proposals_awk_path}" -v left="${yes_pct}" \
        -v right="${threshold}" 'BEGIN { exit !(left >= right) }' </dev/null; then
      status="${ICON_CHECK} ${status} VT: ${threshold}%"
    else
      status="${ICON_CROSS} ${status} VT: ${threshold}%"
    fi
  fi
  if [[ "${role}" == Committee ]]; then
    builtin printf '| %-13s : %s%s%s YES | %s%s%s NO | %s\n' \
      "${role}" "${FG_LBLUE}" "${yes_count}" "${NC}" \
      "${FG_LBLUE}" "${no_count}" "${NC}" "${status}"
  else
    builtin printf '| %-13s : %s%s%s @ %s%s%s VP | %s%s%s @ %s%s%s VP | %s\n' \
      "${role}" "${FG_LBLUE}" "${yes_count}" "${NC}" \
      "${FG_LBLUE}" "${yes_power_human}" "${NC}" \
      "${FG_LBLUE}" "${no_count}" "${NC}" \
      "${FG_LBLUE}" "${no_power_human}" "${NC}" "${status}"
  fi
}

_cntools_action_vote_governance_proposals_render_record() {
  local record="${1:-}" action_id="" tx="" index="" action_type=""
  local proposed="" expires="" anchor="" security="" cip129=""
  local role_json="" own_role="" own_name="" own_vote=""
  local chunk="" offset=0 label="" fields="" own_lines=""
  local own_expected=0 own_visited=0

  fields="$("${governance_proposals_jq_path}" -r \
    '[.id,.tx,.index,.type,.proposedIn,.expiresAfter,.anchorUrl,.security] | @tsv' \
    <<< "${record}")" || return 70
  IFS=$'\t' read -r action_id tx index action_type proposed expires anchor \
    security <<< "${fields}" || return 70
  _cntools_action_vote_governance_proposals_terminal_value_valid "${action_id}" 70 &&
    _cntools_action_vote_governance_proposals_terminal_value_valid "${action_type}" 64 &&
    _cntools_action_vote_governance_proposals_terminal_value_valid "${anchor}" 2048 &&
    _cntools_action_vote_governance_proposals_integer_valid "${proposed}" 4294967295 &&
    _cntools_action_vote_governance_proposals_integer_valid "${expires}" 4294967295 ||
    return 70
  _cntools_action_vote_governance_proposals_action_id_encode \
    "${tx}" "${index}" cip129 || return 70
  println DEBUG '\n|========================================================================================|'
  builtin printf '| %-13s : %s%-70s%s |\n' 'Action ID' "${FG_LGRAY}" "${action_id}" "${NC}"
  builtin printf '| %-13s : %s%-70s%s |\n' '  CIP-129' "${FG_LGRAY}" "${cip129}" "${NC}"
  builtin printf '| %-13s : %s%-70s%s |\n' Type "${FG_LGRAY}" "${action_type}" "${NC}"
  builtin printf '| %-13s : epoch %s%-64s%s |\n' 'Proposed In' "${FG_LBLUE}" "${proposed}" "${NC}"
  if [[ "${expires}" -lt "${governance_proposals_current_epoch}" ]]; then
    builtin printf '| %-13s : epoch %s%-64s%s |\n' 'Expires After' "${FG_RED}" "${expires}" "${NC}"
  else
    builtin printf '| %-13s : epoch %s%-64s%s |\n' 'Expires After' "${FG_LBLUE}" "${expires}" "${NC}"
  fi
  offset=0
  while [[ "${offset}" -lt "${#anchor}" ]]; do
    chunk="${anchor:offset:70}"
    [[ "${offset}" == 0 ]] && label='Anchor URL' || label=''
    builtin printf '| %-13s : %s%-70s%s |\n' "${label}" "${FG_LGRAY}" "${chunk}" "${NC}"
    offset=$((offset + 70))
  done
  for own_role in DRep SPO Committee; do
    case "${own_role}" in
      DRep) role_json="$("${governance_proposals_jq_path}" -c '.drep' <<< "${record}")" ;;
      SPO) role_json="$("${governance_proposals_jq_path}" -c '.spo' <<< "${record}")" ;;
      Committee) role_json="$("${governance_proposals_jq_path}" -c '.committee' <<< "${record}")" ;;
    esac
    _cntools_action_vote_governance_proposals_render_role \
      "${own_role}" "${role_json}" "${action_type}" "${security}" || return 70
  done
  own_expected="$("${governance_proposals_jq_path}" -er \
    '.ownVotes | length' <<< "${record}")" || return 70
  _cntools_action_vote_governance_proposals_integer_valid \
    "${own_expected}" 30000 || return 70
  own_lines="$("${governance_proposals_jq_path}" -r \
    '.ownVotes[] | [.role,.name,.vote] | @tsv' <<< "${record}")" || return 70
  while IFS=$'\t' read -r own_role own_name own_vote; do
    [[ -n "${own_role}" ]] || continue
    own_visited=$((own_visited + 1))
    _cntools_action_vote_governance_proposals_name_valid "${own_name}" &&
      [[ "${own_vote}" == Yes || "${own_vote}" == No || "${own_vote}" == Abstain ]] ||
      return 70
    case "${own_role}" in
      DRep) builtin printf '| You voted %s with DRep wallet %s\n' "${own_vote}" "${own_name}" ;;
      SPO) builtin printf '| You voted %s with pool %s\n' "${own_vote}" "${own_name}" ;;
      ConstitutionalCommittee)
        builtin printf '| You voted %s with committee wallet %s\n' "${own_vote}" "${own_name}"
        ;;
      *) return 70 ;;
    esac
  done <<< "${own_lines}"
  [[ "${own_visited}" == "${own_expected}" ]] || return 70
  println DEBUG '|========================================================================================|'
}

_cntools_action_vote_governance_proposals_render_page() {
  local page="${1:-}" pages="${2:-}" start=0 end=0 index=0 record=""

  _cntools_action_vote_governance_proposals_integer_valid "${page}" 100 &&
    _cntools_action_vote_governance_proposals_integer_valid "${pages}" 100 ||
    return 70
  start=$(((page - 1) * 2))
  end=$((start + 2))
  [[ "${end}" -le "${governance_proposals_vote_action_count}" ]] ||
    end="${governance_proposals_vote_action_count}"
  clear
  println DEBUG "Current epoch : ${FG_LBLUE}${governance_proposals_current_epoch}${NC}"
  println DEBUG "Proposals     : ${FG_LBLUE}${governance_proposals_vote_action_count}${NC}"
  for ((index=start; index<end; index++)); do
    record="$("${governance_proposals_jq_path}" -ce ".[${index}]" \
      "${governance_proposals_records_file}")" || return 70
    _cntools_action_vote_governance_proposals_render_record "${record}" || return 70
  done
  println DEBUG "\n${FG_GREEN}Yes${NC}    = Total power of 'yes' votes."
  println DEBUG "${FG_RED}No${NC}     = Total power of 'no' votes, including buckets of 'no vote cast' and 'always no confidence'."
  println DEBUG "         ${FG_LGRAY}For motion of no confidence, 'always no confidence' power is switched to yes bucket.${NC}"
  println DEBUG "${FG_DGRAY}STATUS${NC} = Percent of yes votes compared to total valid vote power. If above vote threshold for all, proposal is to be enacted."
  println DEBUG "\n${FG_LGRAY}Info action doesn't have any threshold.${NC}"
  println OFF "\nPage ${FG_LBLUE}${page}${NC} of ${FG_LGRAY}${pages}${NC}\n"
  if [[ "${pages}" -eq 1 ]]; then
    println OFF '[r] Return | [d] Details | [h] Home'
  elif [[ "${page}" -eq 1 ]]; then
    println OFF "${FG_DGRAY}[p] Previous Page${NC} | [n] Next Page | [r] Return | [d] Details | [h] Home"
  elif [[ "${page}" -eq "${pages}" ]]; then
    println OFF "[p] Previous Page | ${FG_DGRAY}[n] Next Page${NC} | [r] Return | [d] Details | [h] Home"
  else
    println OFF '[p] Previous Page | [n] Next Page | [r] Return | [d] Details | [h] Home'
  fi
}

_cntools_action_vote_governance_proposals_metadata() {
  local url="${1:-}" expected_hash="${2:-}" actual_hash="" fetch_status=0

  governance_proposals_metadata_valid=N
  _cntools_action_vote_governance_proposals_url_valid "${url}" || return 2
  [[ "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 2
  _cntools_action_vote_governance_proposals_private_create metadata \
    governance_proposals_metadata_file || return 70
  if _cntools_action_vote_governance_proposals_fetch metadata "${url}" \
      "${governance_proposals_metadata_file}"; then
    fetch_status=0
  else
    fetch_status=$?
  fi
  case "${fetch_status}" in 0) ;; 1|2|63) return 2 ;; *) return 70 ;; esac
  "${governance_proposals_jq_path}" -e '
    def safe:
      if type == "string" then length <= 8192 and
        (test("[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]") | not)
      elif type == "array" then length <= 4096 and all(.[]; safe)
      elif type == "object" then length <= 4096 and all(keys[]; safe) and all(.[]; safe)
      else true end;
    (type == "object" or type == "array") and safe
  ' "${governance_proposals_metadata_file}" >/dev/null 2>&1 || return 2
  _cntools_action_vote_governance_proposals_output_capture 132 actual_hash \
    "${governance_proposals_ccli_path}" hash anchor-data \
    --file-text "${governance_proposals_metadata_file}" || return 70
  [[ "${actual_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 70
  governance_proposals_metadata_actual_hash="${actual_hash,,}"
  [[ "${actual_hash,,}" == "${expected_hash,,}" ]] || return 3
  governance_proposals_metadata_valid=Y
}

_cntools_action_vote_governance_proposals_details() {
  local tx="${1:-}" index="${2:-}" detail="" anchor="" expected_hash=""
  local raw="" fetch_status=0 metadata_status=0

  governance_proposals_metadata_file=""
  governance_proposals_metadata_valid=N
  if [[ "${governance_proposals_context_mode}" == light ]]; then
    _cntools_action_vote_governance_proposals_private_create detail \
      governance_proposals_detail_file || return 70
    if _cntools_action_vote_governance_proposals_fetch detail \
        "${governance_proposals_koios_api}/proposal_list?proposal_tx_hash=eq.${tx}&proposal_index=eq.${index}&select=expiration,meta_hash,meta_url,param_proposal,proposal_index,proposal_tx_hash,proposal_type,proposed_epoch" \
        "${governance_proposals_detail_file}"; then
      fetch_status=0
    else
      fetch_status=$?
    fi
    [[ "${fetch_status}" == 0 ]] || return 2
    _cntools_action_vote_governance_proposals_remote_schema detail \
      "${governance_proposals_detail_file}" || return 2
    [[ "$("${governance_proposals_jq_path}" -r 'length' \
      "${governance_proposals_detail_file}")" == 1 ]] || return 1
    detail="$("${governance_proposals_jq_path}" -ce '.[0]' \
      "${governance_proposals_detail_file}")" || return 70
    [[ "$("${governance_proposals_jq_path}" -r '.proposal_tx_hash|ascii_downcase' \
      <<< "${detail}")" == "${tx}" &&
       "$("${governance_proposals_jq_path}" -r '.proposal_index' \
      <<< "${detail}")" == "${index}" ]] || return 2
    anchor="$("${governance_proposals_jq_path}" -r '.meta_url' <<< "${detail}")" || return 70
    expected_hash="$("${governance_proposals_jq_path}" -r '.meta_hash' <<< "${detail}")" || return 70
    raw="${detail}"
  else
    detail="$("${governance_proposals_jq_path}" -ce \
      --arg tx "${tx}" --argjson index "${index}" \
      '[.[] | select(.tx==$tx and .index==$index)][0] // empty' \
      "${governance_proposals_records_file}")" || return 1
    anchor="$("${governance_proposals_jq_path}" -r '.anchorUrl' <<< "${detail}")" || return 70
    expected_hash="$("${governance_proposals_jq_path}" -r '.metaHash' <<< "${detail}")" || return 70
    raw="$("${governance_proposals_jq_path}" -c '.raw' <<< "${detail}")" || return 70
  fi
  if [[ -n "${anchor}" || -n "${expected_hash}" ]]; then
    if _cntools_action_vote_governance_proposals_metadata \
        "${anchor}" "${expected_hash}"; then
      metadata_status=0
    else
      metadata_status=$?
    fi
  fi
  case "${metadata_status}" in
    0) ;;
    2)
      println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor url or content"
      return 0
      ;;
    3)
      println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor hash"
      println DEBUG "Action hash : ${FG_LGRAY}${expected_hash}${NC}"
      println DEBUG "Real hash   : ${FG_LGRAY}${governance_proposals_metadata_actual_hash}${NC}"
      ;;
    *) return 70 ;;
  esac
  println DEBUG "\nGovernance Action Details${FG_LGRAY}"
  "${governance_proposals_jq_path}" . <<< "${raw}" || return 70
  println DEBUG '\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  if [[ "${governance_proposals_metadata_valid}" == Y ]]; then
    println DEBUG "\nGovernance Action Anchor Content${FG_LGRAY}"
    "${governance_proposals_jq_path}" . \
      "${governance_proposals_metadata_file}" || return 70
  fi
  return 0
}

cntools_action_main() {
  local context_file="${1:-}" result_file="${2:-}"
  local governance_proposals_context_mode="" governance_proposals_context_network=""
  local governance_proposals_private_parent="" governance_proposals_wallet_root=""
  local governance_proposals_pool_root="" governance_proposals_wallet_root_physical=""
  local governance_proposals_pool_root_physical="" governance_proposals_curl_timeout=""
  local governance_proposals_koios_api="" governance_proposals_jq_path=""
  local governance_proposals_curl_path="" governance_proposals_mktemp_path=""
  local governance_proposals_chmod_path="" governance_proposals_rm_path=""
  local governance_proposals_wc_path="" governance_proposals_find_path=""
  local governance_proposals_sort_path="" governance_proposals_awk_path=""
  local governance_proposals_bech32_path="" governance_proposals_ccli_path=""
  local governance_proposals_current_epoch="" governance_proposals_cc_threshold=""
  local governance_proposals_cc_numerator="" governance_proposals_cc_denominator=""
  local governance_proposals_vote_action_count=0 governance_proposals_terminal_saved=N
  local governance_proposals_command_file="" governance_proposals_scan_file=""
  local governance_proposals_wallet_list_file="" governance_proposals_pool_list_file=""
  local governance_proposals_identities_ndjson_file="" governance_proposals_identities_file=""
  local governance_proposals_count_file="" governance_proposals_source_file=""
  local governance_proposals_records_ndjson_file="" governance_proposals_records_file=""
  local governance_proposals_summary_file="" governance_proposals_votes_file=""
  local governance_proposals_committee_file="" governance_proposals_govstate_file=""
  local governance_proposals_drep_power_file="" governance_proposals_drep_state_file=""
  local governance_proposals_spo_power_file="" governance_proposals_detail_file=""
  local governance_proposals_metadata_file="" governance_proposals_metadata_valid=N
  local governance_proposals_metadata_actual_hash="" network_magic="" filename=""
  local header_index=0 header_value="" action_status=0 query_status=0 cleanup_status=0
  local page=1 pages=0 key="" action_id="" action_tx_id="" action_idx=""
  local detail_status=0 start=0 end=0
  local -a governance_proposals_temp_files=() governance_proposals_network_args=()
  local -a governance_proposals_koios_headers=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64
  if ! builtin declare -F cntools_context_get >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_stat >/dev/null 2>&1 ||
     ! builtin declare -F _cntools_result_private_parent_validate >/dev/null 2>&1 ||
     ! builtin declare -F println >/dev/null 2>&1 ||
     ! builtin declare -F waitToProceed >/dev/null 2>&1 ||
     ! builtin declare -F getEpoch >/dev/null 2>&1 ||
     ! builtin declare -F getAnswerAnyCust >/dev/null 2>&1 ||
     ! builtin declare -F formatLovelaceHuman >/dev/null 2>&1 ||
     ! builtin declare -F versionCheck >/dev/null 2>&1; then
    _cntools_action_vote_governance_proposals_validation_failure
    return 70
  fi
  governance_proposals_context_mode="$(cntools_context_get \
    "${context_file}" mode)" || action_status=70
  governance_proposals_context_network="$(cntools_context_get \
    "${context_file}" nodeNetwork)" || action_status=70
  [[ "${action_status}" == 0 &&
     "${CNTOOLS_MODE,,}" == "${governance_proposals_context_mode}" ]] || {
    _cntools_action_vote_governance_proposals_validation_failure
    return 70
  }
  governance_proposals_private_parent="${result_file%/*}"
  _cntools_result_private_parent_validate \
    "${governance_proposals_private_parent}" || action_status=70
  for filename in WALLET_GOV_DREP_VK_FILENAME WALLET_GOV_CC_HOT_VK_FILENAME \
      POOL_COLDKEY_VK_FILENAME; do
    [[ "${!filename:-}" =~ ^[A-Za-z0-9._-]{1,128}$ &&
       "${!filename}" != . && "${!filename}" != .. ]] || action_status=70
  done
  for filename in jq mktemp chmod rm wc find sort awk; do
    case "${filename}" in
      jq) _cntools_registry_tool_path jq governance_proposals_jq_path || action_status=70 ;;
      mktemp) _cntools_registry_tool_path mktemp governance_proposals_mktemp_path || action_status=70 ;;
      chmod) _cntools_registry_tool_path chmod governance_proposals_chmod_path || action_status=70 ;;
      rm) _cntools_registry_tool_path rm governance_proposals_rm_path || action_status=70 ;;
      wc) _cntools_registry_tool_path wc governance_proposals_wc_path || action_status=70 ;;
      find) _cntools_registry_tool_path find governance_proposals_find_path || action_status=70 ;;
      sort) _cntools_registry_tool_path sort governance_proposals_sort_path || action_status=70 ;;
      awk) _cntools_registry_tool_path awk governance_proposals_awk_path || action_status=70 ;;
    esac
  done
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_vote_governance_proposals_validation_failure
    return 70
  }
  umask 077
  trap '_cntools_action_vote_governance_proposals_cleanup' EXIT
  trap '_cntools_action_vote_governance_proposals_cleanup; exit 70' HUP INT TERM
  clear
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  println ' >> VOTE >> GOVERNANCE >> LIST PROPOSALS'
  println DEBUG '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
  echo
  if [[ "${governance_proposals_context_mode}" == offline ]]; then
    println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, proposal queries are unavailable."
    waitToProceed
    _cntools_action_vote_governance_proposals_cleanup || cleanup_status=1
    [[ "${cleanup_status}" == 0 ]] || {
      _cntools_action_vote_governance_proposals_validation_failure; return 70;
    }
    return 0
  fi
  governance_proposals_wallet_root="${WALLET_FOLDER:-}"
  governance_proposals_pool_root="${POOL_FOLDER:-}"
  for filename in governance_proposals_wallet_root governance_proposals_pool_root; do
    [[ "${!filename}" == /* && -d "${!filename}" && ! -L "${!filename}" ]] ||
      action_status=70
    _cntools_registry_path_has_no_symlinks "${!filename}" || action_status=70
  done
  governance_proposals_wallet_root_physical="$(cd -P -- \
    "${governance_proposals_wallet_root}" >/dev/null 2>&1 && pwd -P)" ||
    action_status=70
  governance_proposals_pool_root_physical="$(cd -P -- \
    "${governance_proposals_pool_root}" >/dev/null 2>&1 && pwd -P)" ||
    action_status=70
  _cntools_registry_tool_path bech32 governance_proposals_bech32_path || action_status=70
  governance_proposals_ccli_path="$(builtin type -P "${CCLI:-}" 2>/dev/null)" ||
    action_status=70
  [[ "${governance_proposals_ccli_path}" == /* &&
     -x "${governance_proposals_ccli_path}" ]] || action_status=70
  case "${governance_proposals_context_network}" in
    mainnet) governance_proposals_network_args=(--mainnet) ;;
    *)
      network_magic="${NWMAGIC:-}"
      [[ "${network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ &&
         "${network_magic}" -le 4294967295 ]] || action_status=70
      governance_proposals_network_args=(--testnet-magic "${network_magic}")
      ;;
  esac
  governance_proposals_curl_timeout="${CURL_TIMEOUT:-}"
  [[ "${governance_proposals_curl_timeout}" =~ ^([1-9]|[1-9][0-9]|[12][0-9][0-9]|300)$ ]] ||
    action_status=70
  _cntools_registry_tool_path curl governance_proposals_curl_path || action_status=70
  if [[ "${governance_proposals_context_mode}" == light ]]; then
    governance_proposals_koios_api="${KOIOS_API:-}"
    _cntools_action_vote_governance_proposals_api_base_valid \
      "${governance_proposals_koios_api}" || action_status=70
    governance_proposals_koios_api="${governance_proposals_koios_api%/}"
    governance_proposals_koios_headers=("${KOIOS_API_HEADERS[@]}")
    (( ${#governance_proposals_koios_headers[@]} % 2 == 0 &&
       ${#governance_proposals_koios_headers[@]} <= 8 )) || action_status=70
    for ((header_index=0; header_index<${#governance_proposals_koios_headers[@]}; header_index+=2)); do
      header_value="${governance_proposals_koios_headers[header_index+1]}"
      [[ ( "${governance_proposals_koios_headers[header_index]}" == -H ||
           "${governance_proposals_koios_headers[header_index]}" == --header ) &&
         "${#header_value}" -ge 3 && "${#header_value}" -le 8192 &&
         "${header_value}" == *:* && "${header_value}" != *$'\r'* &&
         "${header_value}" != *$'\n'* ]] || action_status=70
    done
  fi
  governance_proposals_current_epoch="$(getEpoch)" || action_status=70
  _cntools_action_vote_governance_proposals_integer_valid \
    "${governance_proposals_current_epoch}" 4294967295 || action_status=70
  _cntools_action_vote_governance_proposals_protocol_validate || action_status=70
  [[ "${action_status}" == 0 ]] || {
    _cntools_action_vote_governance_proposals_cleanup || true
    _cntools_action_vote_governance_proposals_validation_failure
    return 70
  }
  _cntools_action_vote_governance_proposals_query_begin \
    'Querying for number of active proposals...\n' || action_status=70
  if [[ "${governance_proposals_context_mode}" == light ]]; then
    _cntools_action_vote_governance_proposals_remote || query_status=$?
  else
    _cntools_action_vote_governance_proposals_local || query_status=$?
  fi
  _cntools_action_vote_governance_proposals_query_end || action_status=70
  [[ "${action_status}" == 0 ]] || query_status=70
  case "${query_status}" in
    0) ;;
    1|2|63)
      println "${FG_RED}Failed to grab list of proposals!${NC}"
      waitToProceed
      _cntools_action_vote_governance_proposals_cleanup || cleanup_status=1
      [[ "${cleanup_status}" == 0 ]] || {
        _cntools_action_vote_governance_proposals_validation_failure; return 70;
      }
      return 0
      ;;
    *)
      _cntools_action_vote_governance_proposals_cleanup || true
      _cntools_action_vote_governance_proposals_validation_failure
      return 70
      ;;
  esac
  if [[ "${governance_proposals_vote_action_count}" -eq 0 ]]; then
    println "${FG_YELLOW}No active proposals to vote on!${NC}"
    waitToProceed
    _cntools_action_vote_governance_proposals_cleanup || cleanup_status=1
    [[ "${cleanup_status}" == 0 ]] || {
      _cntools_action_vote_governance_proposals_validation_failure; return 70;
    }
    return 0
  fi
  println "${FG_LBLUE}${governance_proposals_vote_action_count}${NC} active proposals to vote on found!"
  waitToProceed
  pages=$(((governance_proposals_vote_action_count + 1) / 2))
  page=1
  while true; do
    _cntools_action_vote_governance_proposals_render_page \
      "${page}" "${pages}" || {
        _cntools_action_vote_governance_proposals_cleanup || true
        _cntools_action_vote_governance_proposals_validation_failure
        return 70
      }
    if ! IFS= read -rsn1 key; then
      key=r
    fi
    case "${key}" in
      r)
        _cntools_action_vote_governance_proposals_cleanup || cleanup_status=1
        [[ "${cleanup_status}" == 0 ]] || {
          _cntools_action_vote_governance_proposals_validation_failure; return 70;
        }
        return 0
        ;;
      h)
        _cntools_action_vote_governance_proposals_cleanup || cleanup_status=1
        [[ "${cleanup_status}" == 0 ]] || {
          _cntools_action_vote_governance_proposals_validation_failure; return 70;
        }
        return 20
        ;;
      p) [[ "${page}" -gt 1 ]] && page=$((page - 1)) ;;
      n) [[ "${page}" -lt "${pages}" ]] && page=$((page + 1)) ;;
      d)
        action_id=""
        getAnswerAnyCust action_id \
          "\nGovernance Action ID [<tx_id>#<action_idx> | CIP-129] (blank to cancel)"
        [[ -n "${action_id}" ]] || continue
        if ! _cntools_action_vote_governance_proposals_action_id_parse \
            "${action_id}"; then
          println ERROR "\n${FG_RED}ERROR${NC}: invalid action id!"
          waitToProceed
          continue
        fi
        _cntools_action_vote_governance_proposals_query_begin \
          '\nFetching proposal details and metadata...\n' || detail_status=70
        if [[ "${detail_status}" == 0 ]]; then
          _cntools_action_vote_governance_proposals_details \
            "${action_tx_id}" "${action_idx}" || detail_status=$?
        fi
        _cntools_action_vote_governance_proposals_query_end || detail_status=70
        case "${detail_status}" in
          0) waitToProceed ;;
          1)
            println ERROR "\n${FG_RED}ERROR${NC}: governance action id not found!"
            waitToProceed
            ;;
          2)
            println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor url or content"
            waitToProceed
            ;;
          *)
            _cntools_action_vote_governance_proposals_cleanup || true
            _cntools_action_vote_governance_proposals_validation_failure
            return 70
            ;;
        esac
        detail_status=0
        ;;
      *) : ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
