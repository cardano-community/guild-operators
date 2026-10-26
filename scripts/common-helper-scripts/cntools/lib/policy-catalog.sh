#!/usr/bin/env bash
# Read-only policy/asset inventory, including legacy .asset records.
# shellcheck disable=SC2034,SC2015
declare -a CNTOOLS_POLICY_NAMES=() CNTOOLS_POLICY_PATHS=() CNTOOLS_POLICY_IDS=() CNTOOLS_POLICY_STATES=() CNTOOLS_POLICY_WARNINGS=()
declare -a CNTOOLS_POLICY_WINDOWS=() CNTOOLS_POLICY_BEFORE=() CNTOOLS_POLICY_AFTER=() CNTOOLS_POLICY_SUPPORTED=()
declare -a CNTOOLS_POLICY_ASSET_IDS=() CNTOOLS_POLICY_ASSET_RECORDS=()
CNTOOLS_POLICY_SELECTED_SCRIPT='' CNTOOLS_POLICY_SELECTED_VKEY='' CNTOOLS_POLICY_SELECTED_SOURCE=''
CNTOOLS_POLICY_SELECTED_CREDENTIAL='' CNTOOLS_POLICY_SELECTED_BEFORE='' CNTOOLS_POLICY_SELECTED_AFTER=''

cntools_policy_directory_safe() {
  [[ "${1%/*}" == "${CNTOOLS_ASSET_DIR%/}" && -d "$1" && ! -L "$1" && -r "$1" && -x "$1" ]] &&
    cntools_filesystem_path_components_safe "$1"
}

cntools_policy_public_file() { cntools_transaction_file_safe "$1" "${2:-65536}"; }

cntools_policy_read_id_into() {
  local output="$1" directory="$2" stored='' calculated=''
  cntools_policy_directory_safe "${directory}" && cntools_policy_filenames_validate || return 1
  cntools_transaction_native_script_valid "${directory}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}" || return 1
  cntools_policy_public_file "${directory}/${CNTOOLS_POLICY_ID_FILENAME:-policy.id}" 128 || return 1
  stored="$(< "${directory}/${CNTOOLS_POLICY_ID_FILENAME:-policy.id}")"
  [[ "${stored}" =~ ^[0-9a-f]{56}$ ]] || return 1
  if [[ -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" && ! -d "${CNTOOLS_CLI}" ]]; then
    cntools_transaction_native_script_hash_into calculated "${directory}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}" || return 1
    [[ "${calculated}" == "${stored}" ]] || return 1
  fi
  printf -v "${output}" '%s' "${stored}"
}

# Linear-policy time bounds: the earliest before-slot and the latest after-slot.
cntools_policy_script_bounds_into() {
  local _bounds_before="$1" _bounds_after="$2" _bounds_script="$3"
  printf -v "${_bounds_before}" ''; printf -v "${_bounds_after}" ''
  cntools_transaction_native_script_valid "${_bounds_script}" && jq -e '
    def linear: .type=="sig" or .type=="before" or .type=="after" or (.type=="all" and all(.scripts[];linear)); linear
    ' "${_bounds_script}" >/dev/null 2>&1 || return 1
  printf -v "${_bounds_before}" '%s' "$(jq -r '[..|objects|select(.type=="before")|.slot]|min // empty' "${_bounds_script}")"
  printf -v "${_bounds_after}" '%s' "$(jq -r '[..|objects|select(.type=="after")|.slot]|max // empty' "${_bounds_script}")"
}

# Single-signer policies cntools_policy_prepare accepts: linear
# sig/before/after/all with exactly one distinct key hash.
cntools_policy_script_supported() {
  cntools_transaction_native_script_valid "$1" && jq -e '
    def linear: .type=="sig" or .type=="before" or .type=="after" or (.type=="all" and all(.scripts[];linear));
    linear and ([..|objects|select(.type=="sig")|.keyHash|ascii_downcase]|unique|length)==1
    ' "$1" >/dev/null 2>&1
}

# valid · expired · pending (not valid yet) · unknown (no clock for this network).
cntools_policy_window_state_into() {
  local _window_output="$1" _window_before="$2" _window_after="$3" _window_now='' _window_state=valid
  _window_now="$(cntools_health_reference_slot "${CNTOOLS_NETWORK:-}" 2>/dev/null)" && [[ "${_window_now}" =~ ^[0-9]+$ ]] || _window_state=unknown
  if [[ "${_window_state}" == valid ]]; then
    if [[ "${_window_before}" =~ ^[0-9]+$ ]] && (( _window_now >= _window_before )); then _window_state=expired
    elif [[ "${_window_after}" =~ ^[0-9]+$ ]] && (( _window_now < _window_after )); then _window_state=pending; fi
  fi
  printf -v "${_window_output}" '%s' "${_window_state}"
}

cntools_policy_catalog_build() {
  local directory='' id='' state='' warning='' skey='' before='' after='' window='' supported=''
  CNTOOLS_POLICY_NAMES=(); CNTOOLS_POLICY_PATHS=(); CNTOOLS_POLICY_IDS=(); CNTOOLS_POLICY_STATES=(); CNTOOLS_POLICY_WARNINGS=()
  CNTOOLS_POLICY_WINDOWS=(); CNTOOLS_POLICY_BEFORE=(); CNTOOLS_POLICY_AFTER=(); CNTOOLS_POLICY_SUPPORTED=()
  [[ -n "${CNTOOLS_ASSET_DIR:-}" && "${CNTOOLS_ASSET_DIR}" == /* && "${CNTOOLS_ASSET_DIR}" != / ]] || return 1
  [[ -e "${CNTOOLS_ASSET_DIR}" || -L "${CNTOOLS_ASSET_DIR}" ]] || return 0
  [[ -d "${CNTOOLS_ASSET_DIR}" && -r "${CNTOOLS_ASSET_DIR}" && ! -L "${CNTOOLS_ASSET_DIR}" ]] &&
    cntools_filesystem_path_components_safe "${CNTOOLS_ASSET_DIR}" || return 1
  cntools_policy_filenames_validate || return 1
  for directory in "${CNTOOLS_ASSET_DIR%/}"/*; do
    [[ -e "${directory}" || -L "${directory}" ]] || continue
    [[ "${directory##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || continue
    cntools_policy_directory_safe "${directory}" || continue
    id=''; warning=''; state='Watch-only'
    cntools_policy_read_id_into id "${directory}" || warning='Policy script/ID invalid or inconsistent'
    [[ -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" ]] || warning="${warning:+${warning}; }CLI unavailable; ID not verified"
    skey="${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"
    if [[ -e "${skey}" || -L "${skey}" ]]; then state=Open; fi
    if [[ -e "${skey}.gpg" || -L "${skey}.gpg" ]]; then
      [[ "${state}" != Open ]] && state=Encrypted || state=Mixed
    fi
    window='' # Empty: not a linear sig/before/after policy, so no window is shown.
    if cntools_policy_script_bounds_into before after "${directory}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}"; then
      cntools_policy_window_state_into window "${before}" "${after}"
    fi
    supported=N
    ! cntools_policy_script_supported "${directory}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}" || supported=Y
    CNTOOLS_POLICY_NAMES+=("${directory##*/}"); CNTOOLS_POLICY_PATHS+=("${directory}"); CNTOOLS_POLICY_IDS+=("${id}")
    CNTOOLS_POLICY_STATES+=("${state}"); CNTOOLS_POLICY_WARNINGS+=("${warning}")
    CNTOOLS_POLICY_WINDOWS+=("${window}"); CNTOOLS_POLICY_BEFORE+=("${before}"); CNTOOLS_POLICY_AFTER+=("${after}")
    CNTOOLS_POLICY_SUPPORTED+=("${supported}")
    [[ -z "${warning}" ]] || cntools_transaction_log WARN "Policy=${directory##*/} ${warning}"
  done
}

# Filters need a valid ID and a single-signer script: transact (inside its
# time window), sign (an unencrypted signing key; registry attestations need
# no time window). Empty offers every policy.
cntools_policy_eligible() {
  local index="$1" filter="${2:-}"
  [[ -n "${filter}" ]] || return 0
  [[ -n "${CNTOOLS_POLICY_IDS[index]}" && "${CNTOOLS_POLICY_SUPPORTED[index]}" == Y ]] || return 1
  case "${filter}" in
    transact) [[ "${CNTOOLS_POLICY_WINDOWS[index]}" != expired && "${CNTOOLS_POLICY_WINDOWS[index]}" != pending ]] ;;
    sign) [[ "${CNTOOLS_POLICY_STATES[index]}" == Open ]] ;;
    *) return 1 ;;
  esac
}

# Why no policy passed a filter, naming only the causes that occurred.
cntools_policy_ineligible_reason_into() {
  local _ineligible_output="$1" _ineligible_filter="$2" _ineligible_index=0 _ineligible_cause='' _ineligible_text='' _ineligible_last=''
  local -a _ineligible_causes=()
  local -A _ineligible_seen=()
  for _ineligible_index in "${!CNTOOLS_POLICY_NAMES[@]}"; do
    if [[ -z "${CNTOOLS_POLICY_IDS[_ineligible_index]}" ]]; then _ineligible_cause='has an invalid script/ID'
    elif [[ "${CNTOOLS_POLICY_SUPPORTED[_ineligible_index]}" != Y ]]; then _ineligible_cause='uses a script form CNTools cannot sign'
    elif [[ "${_ineligible_filter}" == transact ]]; then
      case "${CNTOOLS_POLICY_WINDOWS[_ineligible_index]}" in expired) _ineligible_cause='is expired' ;; pending) _ineligible_cause='is not valid yet' ;; *) continue ;; esac
    else
      case "${CNTOOLS_POLICY_STATES[_ineligible_index]}" in
        Encrypted) _ineligible_cause='has an encrypted signing key' ;;
        Mixed) _ineligible_cause='has both plain and encrypted signing keys' ;;
        Watch-only) _ineligible_cause='has no signing key here' ;;
        *) continue ;;
      esac
    fi
    [[ -n "${_ineligible_seen[${_ineligible_cause}]+x}" ]] || { _ineligible_seen["${_ineligible_cause}"]=Y; _ineligible_causes+=("${_ineligible_cause}"); }
  done
  if (( ${#_ineligible_causes[@]} > 1 )); then
    _ineligible_last="${_ineligible_causes[-1]}"; unset '_ineligible_causes[-1]'
    printf -v _ineligible_text '%s, ' "${_ineligible_causes[@]}"
    _ineligible_text="${_ineligible_text%, } or ${_ineligible_last}"
  else _ineligible_text="${_ineligible_causes[0]:-is unsuitable}"; fi
  (( ${#CNTOOLS_POLICY_NAMES[@]} == 1 )) && _ineligible_text="The only policy ${_ineligible_text}" || _ineligible_text="Each policy ${_ineligible_text}"
  if [[ "${_ineligible_filter}" == transact ]]; then _ineligible_text="No policy can mint or burn now. ${_ineligible_text}."
  else _ineligible_text="No policy can sign here. ${_ineligible_text}."; fi
  [[ -z "${_ineligible_seen['has an encrypted signing key']+x}" ]] || _ineligible_text+=' Use Decrypt / Unlock Policy first.'
  printf -v "${_ineligible_output}" '%s' "${_ineligible_text}"
}

cntools_policy_choose_into() {
  local output="$1" filter="${2:-}" selected='' index=0 row=''
  local -a choices=() indices=()
  for index in "${!CNTOOLS_POLICY_NAMES[@]}"; do
    cntools_policy_eligible "${index}" "${filter}" || continue
    row="$((index+1)) · ${CNTOOLS_POLICY_NAMES[index]} · ${CNTOOLS_POLICY_STATES[index]}"
    # Sign lists expired policies too; the mark still shows their state.
    case "${CNTOOLS_POLICY_WINDOWS[index]}" in expired) row+=' · Expired' ;; pending) row+=' · Not valid yet' ;; esac
    [[ -n "${CNTOOLS_POLICY_IDS[index]}" ]] || row+=' · Invalid'
    choices+=("${row}"); indices+=("${index}")
  done
  (( ${#choices[@]} > 0 )) || return 3
  # A lone policy needs no picker; the next screen names it.
  if (( ${#choices[@]} == 1 )); then
    printf -v "${output}" '%s' "${indices[0]}"
    cntools_transaction_log CHOICE "Policy auto-selected=${CNTOOLS_POLICY_NAMES[indices[0]]}"
    return 0
  fi
  cntools_ui_choose selected Policy "${choices[@]}" Cancel || return $?
  [[ "${selected}" != Cancel ]] || return 1
  for index in "${!choices[@]}"; do
    [[ "${choices[index]}" != "${selected}" ]] || { printf -v "${output}" '%s' "${indices[index]}"; return 0; }
  done
  return 2
}

cntools_policy_asset_catalog() {
  local directory="$1" policy="$2" file='' identity='' hex='' legacy_name=''
  local -A seen=()
  CNTOOLS_POLICY_ASSET_IDS=(); CNTOOLS_POLICY_ASSET_RECORDS=()
  cntools_policy_directory_safe "${directory}" && [[ "${policy}" =~ ^[0-9a-f]{56}$ ]] || return 1
  # Explicit hidden empty-name legacy record, without accepting other hidden files.
  for file in "${directory}"/*.asset "${directory}/.asset"; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    cntools_policy_public_file "${file}" || { cntools_transaction_log WARN "Unsafe asset record skipped=${file}"; continue; }
    jq -es --arg p "${policy}" 'length==1 and (.[0]|type=="object") and .[0].policyID==$p' "${file}" >/dev/null || continue
    if jq -e 'has("assetName")' "${file}" >/dev/null; then
      hex="$(jq -er '.assetName|select(type=="string" and test("^([0-9a-fA-F]{2}){0,32}$"))|ascii_downcase' "${file}")" || continue
    else
      legacy_name="$(jq -er '.name|select(type=="string" and (test("[[:cntrl:]]")|not))' "${file}")" &&
        cntools_policy_asset_name_into hex text "${legacy_name}" || { cntools_transaction_log WARN "Invalid asset record skipped=${file}"; continue; }
    fi
    identity="${policy}.${hex}"
    [[ -z "${seen[${identity}]+x}" ]] || continue
    seen["${identity}"]=Y
    CNTOOLS_POLICY_ASSET_IDS+=("${identity}"); CNTOOLS_POLICY_ASSET_RECORDS+=("${file}")
  done
}

# Freeze public authority before transaction/registry use. Legacy single-signer
# all/sig/before/after policies are supported; complex branches need a separate
# multisignature signer-selection workflow, never guessed here.
cntools_policy_prepare() {
  local directory="$1" expected_policy='' frozen='' source='' key_hash='' derived='' public=''
  CNTOOLS_POLICY_ERROR=''
  cntools_transaction_require_cli && cntools_policy_read_id_into expected_policy "${directory}" || { cntools_policy_error 'The policy script and ID could not be verified.'; return 1; }
  cntools_transaction_snapshot_into frozen "${directory}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}" 65536 policy-script || return 1
  cntools_transaction_native_script_hash_into key_hash "${frozen}" && [[ "${key_hash}" == "${expected_policy}" ]] || return 1
  public="${directory}/${CNTOOLS_POLICY_VKEY_FILENAME:-policy.vkey}"
  source="${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"
  CNTOOLS_POLICY_SELECTED_SOURCE=''
  if [[ -e "${source}" && -e "${source}.gpg" ]]; then cntools_policy_error 'Mixed plaintext/encrypted policy keys must be resolved first.'; return 1; fi
  if [[ -e "${source}" ]]; then
    cntools_wallet_key_normal_envelope_valid "${source}" payment signing && cntools_transaction_private_file_safe "${source}" || { cntools_policy_error 'The policy signing key is invalid or not owner-private.'; return 1; }
    cntools_transaction_snapshot_into CNTOOLS_POLICY_SELECTED_SOURCE "${source}" 65536 policy-signing-key || return 1
    cntools_transaction_temp_file derived policy-derived-public || return 1
    cntools_policy_cli '' key verification-key --signing-key-file "${CNTOOLS_POLICY_SELECTED_SOURCE}" --verification-key-file "${derived}" || return 1
    if [[ -e "${public}" || -L "${public}" ]]; then
      cntools_wallet_key_normal_envelope_valid "${public}" payment verification &&
        jq -es 'length==2 and (.[0].cborHex|ascii_downcase)==(.[1].cborHex|ascii_downcase)' "${public}" "${derived}" >/dev/null || { cntools_policy_error 'Policy private/public keys do not match.'; return 1; }
    fi
    public="${derived}"
  fi
  cntools_wallet_key_normal_envelope_valid "${public}" payment verification || { cntools_policy_error 'A policy verification key is required (decrypt the policy if it must be regenerated).'; return 1; }
  cntools_transaction_snapshot_into CNTOOLS_POLICY_SELECTED_VKEY "${public}" 65536 policy-verification-key || return 1
  cntools_policy_cli key_hash address key-hash --payment-verification-key-file "${CNTOOLS_POLICY_SELECTED_VKEY}" || return 1
  jq -e --arg hash "${key_hash}" '
    def supported: .type=="sig" or .type=="before" or .type=="after" or (.type=="all" and all(.scripts[];supported));
    supported and ([..|objects|select(.type=="sig")|.keyHash|ascii_downcase]|unique)==[$hash]
  ' "${frozen}" >/dev/null || { cntools_policy_error 'This policy needs a multisignature/branch-selection workflow; this action supports single-signer policies only.'; return 1; }
  CNTOOLS_POLICY_SELECTED_BEFORE="$(jq -r '[..|objects|select(.type=="before")|.slot]|min // empty' "${frozen}")"
  CNTOOLS_POLICY_SELECTED_AFTER="$(jq -r '[..|objects|select(.type=="after")|.slot]|max // empty' "${frozen}")"
  CNTOOLS_POLICY_SELECTED_CREDENTIAL="${key_hash}"; CNTOOLS_POLICY_SELECTED_SCRIPT="${frozen}"; CNTOOLS_POLICY_ID="${expected_policy}"
}

cntools_policy_asset_name_into() {
  local _name_output="$1" _name_form="$2" _name_entered="$3" _name_encoded='' LC_ALL=C
  case "${_name_form}" in
    hex) [[ "${_name_entered}" =~ ^([0-9a-fA-F]{2}){0,32}$ ]] || return 2; _name_encoded="${_name_entered,,}" ;;
    text)
      (( ${#_name_entered} <= 32 )) && [[ ! "${_name_entered}" =~ [[:cntrl:]] ]] || return 2
      _name_encoded="$(printf '%s' "${_name_entered}" | od -An -v -tx1 | tr -d ' \n')" || return 1 ;;
    *) return 2 ;;
  esac
  printf -v "${_name_output}" '%s' "${_name_encoded}"
}

cntools_policy_asset_remember() {
  local directory="$1" identity="$2" operation="$3" quantity="$4" txid="$5" state="$6" record='' stage='' existing='{}' now=''
  [[ "${identity}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ && "${txid}" =~ ^[0-9a-f]{64}$ ]] || return 1
  cntools_policy_directory_safe "${directory}" && cntools_transaction_directory_safe "${directory}" || return 1
  record="${directory}/asset-${identity#*.}.asset"
  # The record is replaced, not written in place: a read-only one left by an
  # older Encrypt / Lock Policy is updated too; an immutable one is not.
  if [[ -e "${record}" || -L "${record}" ]]; then
    cntools_policy_public_file "${record}" && [[ -O "${record}" ]] || return 1
    existing="$(< "${record}")"
    jq -e --arg policy "${identity%%.*}" --arg name "${identity#*.}" '.policyID==$policy and .assetName==$name' <<< "${existing}" >/dev/null || return 1
  fi
  cntools_policy_work_into stage "${directory}" || return 1
  printf -v now '%(%s)T' -1
  jq -n --argjson old "${existing}" --arg p "${identity%%.*}" --arg a "${identity#*.}" --arg op "${operation}" \
    --arg q "${quantity}" --arg tx "${txid}" --arg state "${state}" --argjson now "${now}" '
      $old + {schema:2,policyID:$p,assetName:$a,actions:((($old.actions // []) +
      [{operation:$op,quantity:$q,txId:$tx,state:$state,time:$now}])|.[-10:])}
    ' > "${stage}" || return 1
  # Tracking is advisory: never modifies supply counters or an existing legacy
  # record. An unmodifiable/immutable record does not invalidate a saved tx.
  if [[ -e "${record}" ]]; then
    cntools_run_command 000000 -- mv -f -T -- "${stage}" "${record}"
  else
    cntools_run_command 00000 -- ln -T -- "${stage}" "${record}"
  fi
}
