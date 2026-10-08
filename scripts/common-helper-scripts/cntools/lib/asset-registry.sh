#!/usr/bin/env bash
# Signed Token Registry exports. No on-chain transaction or automatic PR.
# shellcheck disable=SC2034,SC2015
declare -a CNTOOLS_REGISTRY_STAGES=()
CNTOOLS_REGISTRY_TOOL='' CNTOOLS_REGISTRY_SAVED=''

cntools_registry_cleanup() {
  local stage=''
  for stage in "${CNTOOLS_REGISTRY_STAGES[@]}"; do
    [[ "${stage##*/}" == .cntools-registry.* && -d "${stage}" && ! -L "${stage}" && -O "${stage}" ]] || continue
    cntools_transaction_path_components_safe "${stage}" || continue
    rm -rf -- "${stage}"
  done
  CNTOOLS_REGISTRY_STAGES=()
}

cntools_registry_require_tool() {
  CNTOOLS_REGISTRY_TOOL="$(type -P token-metadata-creator)"
  [[ "${CNTOOLS_REGISTRY_TOOL}" == /* && -x "${CNTOOLS_REGISTRY_TOOL}" ]] || {
    cntools_policy_error 'Install token-metadata-creator to prepare a signed Token Registry submission.'; return 1;
  }
}

cntools_registry_field_valid() {
  local field="$1" value="$2"
  [[ ! "${value}" =~ [[:cntrl:]] ]] || return 1
  case "${field}" in
    Name) jq -en --arg v "${value}" '$v|length>=1 and length<=50' >/dev/null ;;
    Description) jq -en --arg v "${value}" '$v|length>=1 and length<=500' >/dev/null ;;
    Ticker) [[ -z "${value}" ]] || jq -en --arg v "${value}" '$v|length>=2 and length<=9' >/dev/null ;;
    URL) [[ -z "${value}" ]] || { [[ "${value}" == https://* && "${value}" != *' '* ]] && jq -en --arg v "${value}" '$v|length<=250' >/dev/null; } ;;
    Decimals) [[ -z "${value}" ]] || { [[ "${value}" =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((value <= 255)); } ;;
    *) return 2 ;;
  esac
}

cntools_registry_run() {
  local directory="$1" output='' errors='' status=0; shift
  cntools_transaction_temp_file output registry-output && cntools_transaction_temp_file errors registry-error || return 1
  (umask 077; cd -- "${directory}" && cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_REGISTRY_TOOL}" "$@") || status=$?
  ((status == 0)) || { cntools_transaction_log_cli_failure 'Token Registry preparation failed' "${status}" "${errors}" "${output}"; return 1; }
}

# The upstream tool increments sequence numbers only on changed values and
# preserves unchanged fields/attestations when revising an existing entry.
cntools_registry_export() {
  local identity="$1" name="$2" description="$3" ticker="$4" url="$5" decimals="$6" logo="$7" previous="${8:-}"
  local subject="${identity/./}" temp='' work='' old='' frozen='' final='' export_root='' destination='' png=''
  local -a arguments=()
  CNTOOLS_REGISTRY_SAVED=''
  [[ "${identity}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ && "${identity%%.*}" == "${CNTOOLS_POLICY_ID}" ]] || return 2
  [[ -n "${CNTOOLS_POLICY_SELECTED_SOURCE}" ]] && cntools_transaction_private_file_safe "${CNTOOLS_POLICY_SELECTED_SOURCE}" || {
    cntools_policy_error 'Decrypt the policy signing key before preparing Token Registry attestations.'; return 1;
  }
  cntools_registry_field_valid Name "${name}" && cntools_registry_field_valid Description "${description}" &&
    cntools_registry_field_valid Ticker "${ticker}" && cntools_registry_field_valid URL "${url}" &&
    cntools_registry_field_valid Decimals "${decimals}" || { cntools_policy_error 'Invalid Token Registry field.'; return 1; }
  cntools_registry_require_tool && cntools_transaction_temp_file temp registry-workspace || return 1
  work="$(umask 077; mktemp -d "${temp%/*}/.cntools-registry.XXXXXX")" || return 1
  CNTOOLS_REGISTRY_STAGES+=("${work}")
  # The creator accepts JSON values. Encode strings explicitly so leading
  # hyphens, quotes and JSON-looking names cannot be reinterpreted by its parser.
  arguments=(entry "${subject}" --policy "${CNTOOLS_POLICY_SELECTED_SCRIPT}" --name "$(jq -cn --arg v "${name}" '$v')" --description "$(jq -cn --arg v "${description}" '$v')")
  if [[ -n "${previous}" ]]; then
    cntools_transaction_snapshot_into frozen "${previous}" 378880 registry-previous || return 1
    jq -e --arg s "${subject}" '.subject==$s' "${frozen}" >/dev/null || { cntools_policy_error 'The previous registry entry belongs to another asset.'; return 1; }
    mkdir -m700 -- "${work}/previous" || return 1
    old="${work}/previous/${subject}.json"
    cp -- "${frozen}" "${old}" && cp -- "${frozen}" "${work}/${subject}.json" || return 1
    cntools_registry_run "${work}" validate "${old}" || return 1
  else arguments+=(--init); fi
  [[ -z "${ticker}" ]] || arguments+=(--ticker "$(jq -cn --arg v "${ticker}" '$v')")
  [[ -z "${url}" ]] || arguments+=(--url "$(jq -cn --arg v "${url}" '$v')")
  [[ -z "${decimals}" ]] || arguments+=(--decimals "${decimals}")
  if [[ -n "${logo}" ]]; then
    cntools_transaction_snapshot_into png "${logo}" 65536 registry-logo || return 1
    [[ "$(od -An -N8 -tx1 "${png}" | tr -d ' \n')" == 89504e470d0a1a0a ]] || { cntools_policy_error 'Logo must be a PNG file no larger than 64 KiB.'; return 1; }
    arguments+=(--logo "${png}")
  fi
  cntools_registry_run "${work}" "${arguments[@]}" &&
    cntools_registry_run "${work}" entry "${subject}" -a "${CNTOOLS_POLICY_SELECTED_SOURCE}" &&
    cntools_registry_run "${work}" entry "${subject}" --finalize || return 1
  final="${work}/${subject}.json"
  cntools_transaction_private_file_safe "${final}" && cntools_transaction_file_safe "${final}" 378880 || return 1
  jq -e --arg s "${subject}" --arg n "${name}" --arg d "${description}" --arg t "${ticker}" --arg u "${url}" --arg dec "${decimals}" '
    .subject==$s and .name.value==$n and .description.value==$d and
    ($t=="" or .ticker.value==$t) and ($u=="" or .url.value==$u) and
    ($dec=="" or (.decimals.value|tostring)==$dec) and
    all(.name,.description; (.sequenceNumber|type=="number" and .>=0) and (.signatures|length>0))
  ' "${final}" >/dev/null || { cntools_policy_error 'The signed registry file does not match the reviewed fields.'; return 1; }
  if [[ -n "${old}" ]]; then cntools_registry_run "${work}" validate "${old}" "${final}" || return 1
  else cntools_registry_run "${work}" validate "${final}" || return 1; fi
  export_root="${CNTOOLS_NODE_HOME%/}/asset-registry"
  cntools_transaction_directory_safe "${CNTOOLS_NODE_HOME}" || return 1
  [[ -e "${export_root}" || -L "${export_root}" ]] || (umask 077; mkdir -- "${export_root}") || return 1
  cntools_transaction_directory_safe "${export_root}" || return 1
  destination="$(umask 077; mktemp -d "${export_root}/.cntools-registry.XXXXXX")" || return 1
  CNTOOLS_REGISTRY_STAGES+=("${destination}")
  cntools_run_command 00000 -- ln -T -- "${final}" "${destination}/${subject}.json" || return 1
  cntools_transaction_private_file_safe "${destination}/${subject}.json" || return 1
  CNTOOLS_REGISTRY_SAVED="${destination}/${subject}.json"
  # Detach the successfully saved export from temporary-file cleanup.
  unset 'CNTOOLS_REGISTRY_STAGES[${#CNTOOLS_REGISTRY_STAGES[@]}-1]'
  cntools_transaction_log ASSET "Registry entry exported subject=${subject} file=${CNTOOLS_REGISTRY_SAVED}; manual submission required"
}
