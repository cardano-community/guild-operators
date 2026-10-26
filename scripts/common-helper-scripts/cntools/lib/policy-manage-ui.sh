#!/usr/bin/env bash
# Policy/asset inspection and GPG controls using common responsive tables.
# shellcheck disable=SC2034,SC2015
cntools_policy_manage_begin() { cntools_ui_action_begin "$1" "/ Advanced / Asset / $1"; }

# 3 = nothing to choose: the reason is shown and acknowledged here, once.
# 1 stays a plain Cancel. The filter is passed to cntools_policy_choose_into.
cntools_policy_selection_into() {
  local output="$1" filter="${2:-}" chosen='' status=0 reason=''
  cntools_policy_catalog_build || { cntools_policy_error 'The asset directory could not be inspected safely.'; return 2; }
  cntools_policy_choose_into chosen "${filter}" || status=$?
  if ((status == 3)); then
    case "${filter}" in
      transact) reason='No policy can mint or burn now: each one is expired, not valid yet or has an invalid script/ID.' ;;
      sign) reason='No policy has an unencrypted signing key. Use Decrypt / Unlock Policy first.' ;;
    esac
    (( ${#CNTOOLS_POLICY_NAMES[@]} > 0 )) || reason='No policy folders are available. Use Create Policy first.'
    cntools_ui_render_status info "${reason:-No suitable policy is available.}"
    cntools_ui_wait
    return 3
  fi
  ((status == 0)) || return "${status}"
  printf -v "${output}" '%s' "${chosen}"
  cntools_transaction_log CHOICE "Policy selected=${CNTOOLS_POLICY_NAMES[chosen]}"
}

# An error shown and acknowledged here returns 1: no second menu banner.
cntools_policy_show_error() {
  cntools_ui_render_status error "${CNTOOLS_POLICY_ERROR:-${1:-The policy could not be read.}} See ${CNTOOLS_LOG} for details."
  cntools_ui_wait
  return 1
}

cntools_policy_asset_input_into() {
  local output="$1" form='' entered='' input_hex=''
  cntools_ui_choose form 'Asset name format' Text Hex Cancel || return $?
  [[ "${form}" != Cancel ]] || return 1
  while true; do
    cntools_ui_input entered "Asset name (${form}; empty is valid)" '' || return $?
    if cntools_policy_asset_name_into input_hex "${form,,}" "${entered}"; then
      printf -v "${output}" '%s' "${input_hex}"
      cntools_transaction_log CHOICE "Asset name selected hex=${input_hex:-(empty)}"
      return 0
    fi
    cntools_ui_render_status warn 'Use at most 32 bytes of text, or 0–64 hexadecimal characters in complete byte pairs.'
  done
}

cntools_policy_asset_choose_into() {
  local output="$1" policy="$2" selected='' label='' index=0 encoded=''
  local -a choices=()
  for index in "${!CNTOOLS_POLICY_ASSET_IDS[@]}"; do
    cntools_asset_label_into label "${CNTOOLS_POLICY_ASSET_IDS[index]}" "$((index+1))" || return 2
    choices+=("$((index+1)) · ${label} · ${CNTOOLS_POLICY_ASSET_IDS[index]#*.}")
  done
  if (( ${#choices[@]} > 0 )); then
    cntools_ui_choose selected Asset "${choices[@]}" 'Enter asset name' Cancel || return $?
    [[ "${selected}" != Cancel ]] || return 1
    for index in "${!choices[@]}"; do
      [[ "${choices[index]}" != "${selected}" ]] || { printf -v "${output}" '%s' "${CNTOOLS_POLICY_ASSET_IDS[index]}"; return 0; }
    done
    [[ "${selected}" == 'Enter asset name' ]] || return 2
  fi
  cntools_policy_asset_input_into encoded || return $?
  printf -v "${output}" '%s' "${policy}.${encoded}"
}

cntools_policy_render() {
  local index="$1" date='' role=warning
  {
    cntools_table_pair 'Policy ID' "${CNTOOLS_POLICY_IDS[index]:-Unavailable}" identifier
    cntools_table_pair 'Key protection' "${CNTOOLS_POLICY_STATES[index]}" status
    cntools_table_pair 'Known assets' "${#CNTOOLS_POLICY_ASSET_IDS[@]}" number
    if [[ -n "${CNTOOLS_POLICY_WINDOWS[index]}" ]]; then
      if [[ -n "${CNTOOLS_POLICY_BEFORE[index]}" ]] && cntools_slot_datetime_into date "${CNTOOLS_POLICY_BEFORE[index]}"; then
        [[ "${CNTOOLS_POLICY_WINDOWS[index]}" != expired ]] || { date="Expired · ${date}"; role=danger; }
        cntools_table_pair 'Policy expires' "${date}" "${role}"
      else cntools_table_pair 'Policy expires' 'No before-slot limit' value; fi
      if [[ -n "${CNTOOLS_POLICY_AFTER[index]}" ]] && cntools_slot_datetime_into date "${CNTOOLS_POLICY_AFTER[index]}"; then
        [[ "${CNTOOLS_POLICY_WINDOWS[index]}" != pending ]] && cntools_table_pair 'Valid from' "${date}" value ||
          cntools_table_pair 'Valid from' "Not valid yet · ${date}" warning
      fi
    fi
    cntools_table_pair Directory "${CNTOOLS_POLICY_PATHS[index]}" identifier
  } | cntools_table_render "${CNTOOLS_POLICY_NAMES[index]}"
  [[ -z "${CNTOOLS_POLICY_WARNINGS[index]}" ]] || cntools_ui_render_status warn "${CNTOOLS_POLICY_WARNINGS[index]}"
}

# The asset tables name their metadata source, so no extra notice is drawn.
cntools_policy_asset_enrich() {
  (( $# > 0 )) || return 0
  [[ "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && -n "${CNTOOLS_KOIOS_API:-}" ]] || return 0
  cntools_ui_flow_confirm 'Fetch token supply and metadata from Koios (one-day cache)?' true || return 0
  cntools_transaction_log CHOICE 'Policy asset Koios metadata lookup confirmed'
  cntools_ui_spin_function 'Fetching Koios asset details…' cntools_asset_details_for_ids "$@" || true
}

# Last mint/burn this system recorded in the asset's local .asset file.
cntools_policy_asset_last_action_into() {
  local _last_output="$1" _last_record="$2" _last_row='' _last_operation='' _last_quantity='' _last_state='' _last_time='' _last_date=''
  printf -v "${_last_output}" ''
  [[ -n "${_last_record}" ]] && cntools_policy_public_file "${_last_record}" || return 0
  _last_row="$(jq -r '(.actions // [])|last|select(type=="object")|
    [(.operation|tostring),(.quantity|tostring),(.state|tostring),(.time|tostring)]|map(gsub("[\u0000-\u001f\u007f]";" "))|join("\u001f")' "${_last_record}" 2>/dev/null)" || return 0
  [[ -n "${_last_row}" ]] || return 0
  IFS=$'\037' read -r _last_operation _last_quantity _last_state _last_time <<< "${_last_row}"
  [[ "${_last_operation}" =~ ^(mint|burn)$ && "${_last_quantity}" =~ ^[0-9]+$ ]] || return 0
  _last_row="${_last_operation^} $(cntools_number_format "${_last_quantity}") · ${_last_state}"
  [[ ! "${_last_time}" =~ ^[0-9]{1,12}$ ]] || ! cntools_timestamp_datetime_into _last_date "${_last_time}" || _last_row+=" · ${_last_date}"
  printf -v "${_last_output}" '%s' "${_last_row}"
}

# Arguments: identity, detailed (Y/N), local .asset record, source row (Y/N).
cntools_policy_asset_render() {
  local identity="$1" detailed="${2:-N}" record="${3:-}" show_source="${4:-Y}" label='' fingerprint='' source='' supply='' decimals='' last=''
  cntools_asset_label_into label "${identity}" 1 || return 1
  cntools_wallet_asset_fingerprint_into fingerprint "${identity%%.*}" "${identity#*.}" || fingerprint=Unavailable
  cntools_wallet_asset_metadata_source_into source "${identity}" || source=Unavailable
  cntools_policy_asset_last_action_into last "${record}"
  supply="${CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES[${identity}]:-}"
  decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${identity}]:-}"
  {
    # The policy table above already names the policy ID.
    if [[ -n "${identity#*.}" ]]; then cntools_table_pair 'Asset name (hex)' "${identity#*.}" identifier
    else cntools_table_pair 'Asset name (hex)' '(empty)' muted; fi
    cntools_table_pair Fingerprint "${fingerprint}" identifier
    if [[ "${supply}" =~ ^[0-9]+$ ]]; then
      cntools_wallet_format_token_amount_into supply "${supply}" "${decimals}" || return 1
      cntools_table_pair 'Total supply' "${supply}" number
    fi
    [[ -z "${last}" ]] || cntools_table_pair 'Last local action' "${last}" value
    [[ "${show_source}" != Y ]] || cntools_table_pair 'Metadata source' "${source}" muted
    [[ -z "${CNTOOLS_WALLET_ASSET_METADATA_NAMES[${identity}]:-}" ]] || cntools_table_pair Name "${CNTOOLS_WALLET_ASSET_METADATA_NAMES[${identity}]}" value
    if [[ "${detailed}" == Y && -n "${CNTOOLS_WALLET_ASSET_METADATA_JSON[${identity}]:-}" ]]; then
      local field='' value=''
      while IFS=$'\037' read -r field value; do
        cntools_table_pair "${field}" "${value}" value
      done < <(jq -r '.[] | [.property,.value]|join("\u001f")' <<< "${CNTOOLS_WALLET_ASSET_METADATA_JSON[${identity}]}")
    fi
  } | cntools_table_render "${label}"
}

cntools_policy_action_list() {
  local index=0 position=0
  cntools_policy_manage_begin 'List Assets'
  cntools_policy_catalog_build || { cntools_ui_render_status error 'The policy directory could not be read safely.'; cntools_ui_wait; return 1; }
  (( ${#CNTOOLS_POLICY_NAMES[@]} > 0 )) || cntools_ui_render_status info 'No policies are available.'
  for index in "${!CNTOOLS_POLICY_NAMES[@]}"; do
    cntools_policy_asset_catalog "${CNTOOLS_POLICY_PATHS[index]}" "${CNTOOLS_POLICY_IDS[index]}" || { CNTOOLS_POLICY_ASSET_IDS=(); CNTOOLS_POLICY_ASSET_RECORDS=(); }
    cntools_policy_render "${index}" || return 1
    # List reads local records only, so the Koios source row is left out.
    for position in "${!CNTOOLS_POLICY_ASSET_IDS[@]}"; do
      cntools_policy_asset_render "${CNTOOLS_POLICY_ASSET_IDS[position]}" N "${CNTOOLS_POLICY_ASSET_RECORDS[position]}" N || return 1
    done
  done
  cntools_ui_render_status info 'Known assets come from local .asset records. Saved/signed/submitted actions are not proof of block inclusion or total supply.'
  cntools_ui_wait
}

cntools_policy_action_show() {
  local selected='' identity='' view='' status=0 record='' position=0
  cntools_policy_manage_begin 'Show Asset'
  cntools_policy_selection_into selected || status=$?
  ((status != 3)) || return 0
  ((status != 2)) || { cntools_policy_show_error; return 1; }
  ((status == 0)) || return "${status}"
  if ! cntools_policy_asset_catalog "${CNTOOLS_POLICY_PATHS[selected]}" "${CNTOOLS_POLICY_IDS[selected]}"; then
    # An invalid script/ID lists no assets; show why instead of failing silently.
    CNTOOLS_POLICY_ASSET_IDS=(); CNTOOLS_POLICY_ASSET_RECORDS=()
    cntools_policy_manage_begin 'Show Asset'
    cntools_policy_render "${selected}" || return 1
    cntools_ui_render_status error 'Assets cannot be listed for this policy until its script and ID are valid.'
    cntools_ui_wait
    return 1
  fi
  cntools_policy_asset_choose_into identity "${CNTOOLS_POLICY_IDS[selected]}" || return $?
  cntools_policy_asset_enrich "${identity}"
  # Both views match without metadata; Quick shows every known field.
  if [[ -z "${CNTOOLS_WALLET_ASSET_METADATA_JSON[${identity}]:-}" ]]; then
    view=Simple
  elif cntools_flow_quick; then
    view=Detailed
    cntools_transaction_log CHOICE 'Asset details default=Detailed flow=quick'
  else
    cntools_ui_choose view 'Asset details' Simple Detailed Cancel || return $?
    [[ "${view}" != Cancel ]] || return 1
  fi
  for position in "${!CNTOOLS_POLICY_ASSET_IDS[@]}"; do
    [[ "${CNTOOLS_POLICY_ASSET_IDS[position]}" != "${identity}" ]] || record="${CNTOOLS_POLICY_ASSET_RECORDS[position]}"
  done
  cntools_policy_manage_begin 'Show Asset'
  cntools_policy_render "${selected}" || return 1
  [[ "${view}" == Detailed ]] && view=Y || view=N
  cntools_policy_asset_render "${identity}" "${view}" "${record}" || return 1
  cntools_ui_wait
}

cntools_policy_action_protection_inner() {
  local operation="$1" title='' selected='' directory='' key='' password='' confirmation='' status=0 result='' feedback=''
  [[ "${operation}" == encrypt ]] && title='Encrypt / Lock Policy' || title='Decrypt / Unlock Policy'
  cntools_policy_manage_begin "${title}"
  cntools_policy_selection_into selected || status=$?
  ((status != 3)) || return 0
  ((status != 2)) || { cntools_policy_show_error; return 1; }
  ((status == 0)) || return "${status}"
  directory="${CNTOOLS_POLICY_PATHS[selected]}"; key="${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"
  [[ "${operation}" != decrypt ]] || key+='.gpg'
  # A key operation needs GnuPG: check before any password is typed.
  if [[ -f "${key}" && ! -L "${key}" ]] && ! type -P gpg >/dev/null 2>&1 && ! type -P gpg2 >/dev/null 2>&1; then
    cntools_policy_error 'GnuPG (gpg) is required to encrypt or decrypt a policy key. Install it and try again.' || true
    cntools_policy_show_error
    return 1
  fi
  while true; do
    cntools_policy_manage_begin "${title}"
    {
      cntools_table_pair Policy "${CNTOOLS_POLICY_NAMES[selected]}" identifier
      cntools_table_pair 'Key protection' "${CNTOOLS_POLICY_STATES[selected]}" status
      cntools_table_pair Action "${title}" value
      cntools_table_pair Directory "${directory}" identifier
    } | cntools_table_render Policy || return 1
    if [[ "${operation}" == encrypt ]]; then
      cntools_ui_render_status warn 'Keep a secure backup: an encryption password cannot be recovered.'
    else
      cntools_ui_render_status warn 'Decrypt / Unlock leaves the signing key unencrypted and removes file write protection.'
    fi
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    # Decrypt always confirms (once). Encrypting a key asks for a new password
    # on this screen (Esc cancels), which is the commitment; lock-only is a flow step.
    if [[ "${operation}" == decrypt && -z "${feedback}" ]]; then
      cntools_ui_confirm "${title}?" false || return $?
    elif [[ "${operation}" == encrypt && ( ! -f "${key}" || -L "${key}" ) ]]; then
      cntools_ui_flow_confirm "${title}?" false || return $?
    fi
    if [[ -f "${key}" && ! -L "${key}" ]]; then
      while true; do
        cntools_ui_password password 'Policy password' || { status=$?; unset password; return "${status}"; }
        if [[ "${operation}" == encrypt ]]; then
          (( ${#password} >= 12 )) || { cntools_ui_render_status warn 'Use at least 12 characters for new encryption.'; unset password; continue; }
          cntools_ui_password confirmation 'Confirm password' || { status=$?; unset password confirmation; return "${status}"; }
          [[ "${password}" == "${confirmation}" ]] || { cntools_ui_render_status warn 'Passwords did not match.'; unset password confirmation; continue; }
        fi
        break
      done
    fi
    cntools_transaction_log CHOICE "Policy protection confirmed policy=${directory##*/} operation=${operation}"
    status=0
    cntools_ui_spin_function 'Verifying and updating policy protection…' cntools_policy_protect "${directory}" "${operation}" "${password:-}" || status=$?
    unset password confirmation
    # A wrong decrypt password changes nothing: ask again (Esc cancels).
    if ((status != 0)) && [[ "${operation}" == decrypt && "${CNTOOLS_POLICY_PASSWORD_REJECTED:-N}" == Y ]]; then
      cntools_policy_files_cleanup
      feedback='The password did not open the policy key. Nothing was changed; try again or press Esc to cancel.'
      continue
    fi
    break
  done
  cntools_policy_manage_begin "${title}"
  if ((status == 0)); then
    if [[ "${operation}" == encrypt && -f "${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}.gpg" ]]; then result='Encrypted · files locked'
    elif [[ "${operation}" == decrypt && -f "${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}" ]]; then result='Open · files unlocked'
    elif [[ "${operation}" == encrypt ]]; then result='Files locked · no private key present'
    else result='Files unlocked · no private key present'; fi
    {
      cntools_table_pair Policy "${directory##*/}" identifier
      cntools_table_pair Result "${result}" success
      cntools_table_pair Protection "${CNTOOLS_POLICY_LOCK_METHOD}" value
    } | cntools_table_render Policy
  else cntools_ui_render_status error "${CNTOOLS_POLICY_ERROR:-Policy protection failed.} See ${CNTOOLS_LOG} for details."; fi
  [[ -z "${CNTOOLS_POLICY_WARNING}" ]] || cntools_ui_render_status warn "${CNTOOLS_POLICY_WARNING}"
  cntools_ui_wait
  # A failure is shown and acknowledged above: no second menu banner.
  ((status == 0)) || return 1
}

cntools_policy_action_protection() {
  local traced=N result=0
  case "$-" in *x*) traced=Y; set +x ;; esac
  cntools_policy_action_protection_inner "$1" || result=$?
  [[ "${traced}" != Y ]] || set -x
  return "${result}"
}
