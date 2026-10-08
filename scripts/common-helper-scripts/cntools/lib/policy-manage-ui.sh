#!/usr/bin/env bash
# Policy/asset inspection and GPG controls using common responsive tables.
# shellcheck disable=SC2034,SC2015
cntools_policy_manage_begin() { cntools_ui_action_begin "$1" "/ Advanced / Asset / $1"; }

cntools_policy_selection_into() {
  local output="$1" chosen='' status=0
  cntools_policy_catalog_build || { cntools_policy_error 'The asset directory could not be inspected safely.'; return 2; }
  (( ${#CNTOOLS_POLICY_NAMES[@]} > 0 )) || { cntools_ui_render_status info 'No policy folders are available.'; return 1; }
  cntools_policy_choose_into chosen || status=$?
  ((status == 0)) || return "${status}"
  printf -v "${output}" '%s' "${chosen}"
  cntools_transaction_log CHOICE "Policy selected=${CNTOOLS_POLICY_NAMES[chosen]}"
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
  local index="$1" script="${CNTOOLS_POLICY_PATHS[$1]}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}" bound='' date=''
  {
    cntools_table_pair 'Policy ID' "${CNTOOLS_POLICY_IDS[index]:-Unavailable}" identifier
    cntools_table_pair 'Key protection' "${CNTOOLS_POLICY_STATES[index]}" status
    cntools_table_pair 'Known assets' "${#CNTOOLS_POLICY_ASSET_IDS[@]}" number
    if cntools_transaction_native_script_valid "${script}" && jq -e '
      def linear: .type=="sig" or .type=="before" or .type=="after" or (.type=="all" and all(.scripts[];linear)); linear
      ' "${script}" >/dev/null; then
      bound="$(jq -r '[..|objects|select(.type=="before")|.slot]|min // empty' "${script}")"
      if [[ -n "${bound}" ]] && cntools_slot_datetime_into date "${bound}"; then
        cntools_table_pair 'Policy expires' "${date}" warning
      else cntools_table_pair 'Policy expires' 'No before-slot limit' value; fi
      bound="$(jq -r '[..|objects|select(.type=="after")|.slot]|max // empty' "${script}")"
      if [[ -n "${bound}" ]] && cntools_slot_datetime_into date "${bound}"; then cntools_table_pair 'Valid from' "${date}" value; fi
    fi
    cntools_table_pair Directory "${CNTOOLS_POLICY_PATHS[index]}" identifier
  } | cntools_table_render "${CNTOOLS_POLICY_NAMES[index]}"
  [[ -z "${CNTOOLS_POLICY_WARNINGS[index]}" ]] || cntools_ui_render_status warn "${CNTOOLS_POLICY_WARNINGS[index]}"
}

cntools_policy_asset_enrich() {
  (( $# > 0 )) || return 0
  [[ "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && -n "${CNTOOLS_KOIOS_API:-}" ]] || return 0
  cntools_ui_confirm 'Fetch token supply and metadata from Koios (one-day cache)?' true || return 0
  cntools_transaction_log CHOICE 'Policy asset Koios metadata lookup confirmed'
  cntools_ui_spin_function 'Fetching Koios asset details…' cntools_asset_details_for_ids "$@" || true
  cntools_ui_render_status info 'Token metadata and supply are from Koios API/cache, not local policy records.'
}

cntools_policy_asset_render() {
  local identity="$1" detailed="${2:-N}" label='' fingerprint='' source='' supply='' decimals=''
  cntools_asset_label_into label "${identity}" 1 || return 1
  cntools_wallet_asset_fingerprint_into fingerprint "${identity%%.*}" "${identity#*.}" || fingerprint=Unavailable
  cntools_wallet_asset_metadata_source_into source "${identity}" || source=Unavailable
  supply="${CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES[${identity}]:-}"
  decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${identity}]:-}"
  {
    if [[ "${supply}" =~ ^[0-9]+$ ]]; then
      [[ "${supply}" != 1 ]] && cntools_table_pair Type FT value || cntools_table_pair Type NFT value
      if [[ "${supply}" != 1 ]]; then
        cntools_wallet_format_token_amount_into supply "${supply}" "${decimals}" || return 1
        cntools_table_pair 'Total supply' "${supply}" number
      fi
    fi
    cntools_table_pair 'Policy ID' "${identity%%.*}" identifier
    cntools_table_pair 'Asset name (hex)' "${identity#*.}" identifier
    cntools_table_pair Fingerprint "${fingerprint}" identifier
    cntools_table_pair 'Metadata source' "${source}" muted
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
  local index=0 identity=''
  cntools_policy_manage_begin 'List Assets'
  cntools_policy_catalog_build || { cntools_ui_render_status error 'The policy directory could not be read safely.'; cntools_ui_wait; return 1; }
  (( ${#CNTOOLS_POLICY_NAMES[@]} > 0 )) || cntools_ui_render_status info 'No policies are available.'
  for index in "${!CNTOOLS_POLICY_NAMES[@]}"; do
    cntools_policy_asset_catalog "${CNTOOLS_POLICY_PATHS[index]}" "${CNTOOLS_POLICY_IDS[index]}" || { CNTOOLS_POLICY_ASSET_IDS=(); CNTOOLS_POLICY_ASSET_RECORDS=(); }
    cntools_policy_render "${index}" || return 1
    for identity in "${CNTOOLS_POLICY_ASSET_IDS[@]}"; do cntools_policy_asset_render "${identity}" || return 1; done
  done
  cntools_ui_render_status info 'Known assets come from local .asset records. Saved/signed/submitted actions are not proof of block inclusion or total supply.'
  cntools_ui_wait
}

cntools_policy_action_show() {
  local selected='' identity='' view='' status=0
  cntools_policy_manage_begin 'Show Asset'
  cntools_policy_selection_into selected || status=$?
  cntools_policy_cancelled "${status}" && { cntools_ui_wait; return 0; }
  ((status == 0)) || return "${status}"
  cntools_policy_asset_catalog "${CNTOOLS_POLICY_PATHS[selected]}" "${CNTOOLS_POLICY_IDS[selected]}" || return 1
  cntools_policy_asset_choose_into identity "${CNTOOLS_POLICY_IDS[selected]}" || status=$?
  cntools_policy_cancelled "${status}" && return 0
  ((status == 0)) || return "${status}"
  cntools_policy_asset_enrich "${identity}"
  cntools_ui_choose view 'Asset details' Simple Detailed Cancel || status=$?
  cntools_policy_cancelled "${status}" && return 0
  ((status == 0)) || return "${status}"
  [[ "${view}" != Cancel ]] || return 0
  cntools_policy_manage_begin 'Show Asset'
  cntools_policy_render "${selected}" || return 1
  [[ "${view}" == Detailed ]] && view=Y || view=N
  cntools_policy_asset_render "${identity}" "${view}" || return 1
  cntools_ui_wait
}

cntools_policy_action_protection_inner() {
  local operation="$1" title='' selected='' directory='' key='' password='' confirmation='' status=0 result=''
  [[ "${operation}" == encrypt ]] && title='Encrypt / Lock Policy' || title='Decrypt / Unlock Policy'
  cntools_policy_manage_begin "${title}"
  cntools_policy_selection_into selected || status=$?
  cntools_policy_cancelled "${status}" && { cntools_ui_wait; return 0; }
  ((status == 0)) || return "${status}"
  directory="${CNTOOLS_POLICY_PATHS[selected]}"; key="${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"
  [[ "${operation}" != decrypt ]] || key+='.gpg'
  {
    cntools_table_pair Policy "${CNTOOLS_POLICY_NAMES[selected]}" identifier
    cntools_table_pair 'Key protection' "${CNTOOLS_POLICY_STATES[selected]}" status
    cntools_table_pair Action "${title}" value
    cntools_table_pair Directory "${directory}" identifier
  } | cntools_table_render Policy || return 1
  cntools_ui_render_status warn 'Keep a secure backup. Encryption passwords cannot be recovered. Decrypt/Unlock removes file write protection.'
  cntools_ui_confirm "${title}?" false || { status=$?; cntools_policy_cancelled "${status}" && return 0; return "${status}"; }
  if [[ -f "${key}" && ! -L "${key}" ]]; then
    while true; do
      cntools_ui_password password 'Policy password' || { status=$?; unset password; cntools_policy_cancelled "${status}" && return 0; return "${status}"; }
      if [[ "${operation}" == encrypt ]]; then
        (( ${#password} >= 12 )) || { cntools_ui_render_status warn 'Use at least 12 characters for new encryption.'; unset password; continue; }
        cntools_ui_password confirmation 'Confirm password' || { status=$?; unset password confirmation; cntools_policy_cancelled "${status}" && return 0; return "${status}"; }
        [[ "${password}" == "${confirmation}" ]] || { cntools_ui_render_status warn 'Passwords did not match.'; unset password confirmation; continue; }
      fi
      break
    done
  fi
  cntools_transaction_log CHOICE "Policy protection confirmed policy=${directory##*/} operation=${operation}"
  cntools_ui_spin_function 'Verifying and updating policy protection…' cntools_policy_protect "${directory}" "${operation}" "${password:-}" || status=$?
  unset password confirmation
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
  return "${status}"
}

cntools_policy_action_protection() {
  local traced=N result=0
  case "$-" in *x*) traced=Y; set +x ;; esac
  cntools_policy_action_protection_inner "$1" || result=$?
  [[ "${traced}" != Y ]] || set -x
  return "${result}"
}
