#!/usr/bin/env bash
# Guided new/update registry entry, with explicit off-chain/manual publication.
# shellcheck disable=SC2034,SC2015

# With a current value, Enter keeps it (the previous entry's field on Update).
# Optional fields (clearable=Y) take "-" to clear a value set in this review.
cntools_registry_prompt_into() {
  local output="$1" field="$2" hint="$3" current="${4:-}" clearable="${5:-N}" entered='' placeholder="$3"
  if [[ -n "${current}" ]]; then
    placeholder="Enter keeps: ${current:0:60}$( (( ${#current} > 60 )) && printf '…')"
    [[ "${clearable}" != Y ]] || placeholder+=' · - clears'
  fi
  while true; do
    cntools_ui_input entered "${field}" "${placeholder}" || return $?
    if [[ "${clearable}" == Y && "${entered}" == - ]]; then entered=''
    elif [[ -z "${entered}" && -n "${current}" ]]; then entered="${current}"; fi
    if cntools_registry_field_valid "${field}" "${entered}"; then printf -v "${output}" '%s' "${entered}"; return 0; fi
    cntools_ui_render_status warn "Invalid ${field}. ${hint}"
  done
}

# Fields of the chosen current entry, used as the Update defaults. A value
# with control characters is not offered (the prompt would not accept it).
cntools_registry_previous_fields_into() {
  local _previous_file="$1" _previous_subject="$2" _previous_row=''
  shift 2
  cntools_transaction_file_safe "${_previous_file}" 378880 || return 1
  _previous_row="$(jq -er --arg s "${_previous_subject}" 'select(.subject==$s)|
    [.name.value, .description.value, .ticker.value, .url.value, (.decimals.value|if .==null then null else tostring end)]
    | map(if type=="string" and (test("[\u0000-\u001f\u007f]")|not) then . else "" end) | join("\u001f")' "${_previous_file}" 2>/dev/null)" || return 1
  IFS=$'\037' read -r "$@" <<< "${_previous_row}"
}

cntools_registry_workflow() {
  local selected='' identity='' name='' description='' ticker='' url='' decimals='' logo='' previous='' kind='' status=0 repo='' feedback='' label=''
  local old_name='' old_description='' old_ticker='' old_url='' old_decimals='' keep='' logo_keep='' clearable=Y choice='' field='' chosen_logo=''
  cntools_policy_manage_begin 'Register Asset'
  cntools_ui_render_status info 'Prepare a signed Token Registry submission file. This does not mint tokens, attach transaction metadata or publish to a registry.'
  cntools_registry_require_tool || return 2
  # Only policies whose signing key is open here can sign the attestations.
  cntools_policy_selection_into selected sign || return $?
  cntools_policy_prepare "${CNTOOLS_POLICY_PATHS[selected]}" || return 2
  [[ -n "${CNTOOLS_POLICY_SELECTED_SOURCE}" ]] || { cntools_policy_error 'Decrypt the policy before signing registry metadata.'; return 2; }
  cntools_policy_asset_catalog "${CNTOOLS_POLICY_PATHS[selected]}" "${CNTOOLS_POLICY_ID}" || return 2
  cntools_policy_asset_choose_into identity "${CNTOOLS_POLICY_ID}" || return $?
  cntools_ui_choose kind 'Registry entry' New 'Update existing entry' Cancel || return $?
  [[ "${kind}" != Cancel ]] || return 1
  if [[ "${kind}" == 'Update existing entry' ]]; then
    while true; do
      cntools_ui_pick_path previous 'Current registry JSON file' 'Choose the current published entry to preserve fields and update sequences safely.' \
        '' file '' '' "${feedback}" || return $?
      [[ -n "${previous}" ]] || return 1
      cntools_registry_previous_fields_into "${previous}" "${identity/./}" old_name old_description old_ticker old_url old_decimals && break
      feedback='That file is not a registry entry for this asset. Choose its current entry JSON.'
    done
    cntools_transaction_log CHOICE "Registry update defaults loaded from previous entry asset=${identity}"
    # Update leaves a blank optional field as published, so it cannot clear one.
    keep='; blank keeps the published value'; logo_keep='; skipping keeps the published logo'; clearable=N
  fi
  cntools_registry_prompt_into name Name 'Required · 1–50 characters' "${old_name}" &&
    cntools_registry_prompt_into description Description 'Required · 1–500 characters' "${old_description}" &&
    cntools_registry_prompt_into ticker Ticker "Optional · 2–9 characters${keep}" "${old_ticker}" &&
    cntools_registry_prompt_into url URL "Optional · https:// URL, at most 250 characters${keep}" "${old_url}" &&
    cntools_registry_prompt_into decimals Decimals "Optional · 0–255 (0 is supported)${keep}" "${old_decimals}" || return $?
  cntools_ui_pick_path logo 'Logo PNG file' "Optional · a PNG of at most 64 KiB${logo_keep}." '' file 'Skip logo' || return $?
  cntools_asset_label_into label "${identity}" 1 || label="${identity#*.}"
  # A typo is fixed here, field by field; nothing is signed before 'Sign and save'.
  while true; do
    cntools_policy_manage_begin 'Register Asset'
    {
      cntools_table_pair Policy "${CNTOOLS_POLICY_NAMES[selected]}" identifier
      cntools_table_pair Asset "${label}" accent
      cntools_table_pair Subject "${identity/./}" identifier
      cntools_table_pair Name "${name}" value
      cntools_table_pair Description "${description}" value
      [[ -z "${ticker}" ]] || cntools_table_pair Ticker "${ticker}" value
      [[ -z "${url}" ]] || cntools_table_pair URL "${url}" identifier
      [[ -z "${decimals}" ]] || cntools_table_pair Decimals "${decimals}" number
      [[ -z "${logo}" ]] || cntools_table_pair Logo "${logo}" identifier
      cntools_table_pair Entry "${kind}" value
    } | cntools_table_render 'Token Registry entry' || return 2
    if [[ "${kind}" == New ]]; then
      cntools_ui_render_status info 'A new entry is for an asset that is not registered yet. For a registered asset, use Update with its current entry.'
    else
      cntools_ui_render_status warn 'Blank optional fields keep their published values; this flow does not delete published fields.'
    fi
    cntools_ui_choose choice 'Review registry entry' 'Sign and save registry file' 'Change a field' Cancel || return $?
    case "${choice}" in
      'Sign and save registry file') break ;;
      'Change a field') ;;
      *) return 1 ;;
    esac
    status=0
    cntools_ui_choose field 'Field' Name Description Ticker URL Decimals Logo Cancel || status=$?
    ((status != 1)) || continue
    ((status == 0)) || return "${status}"
    # Esc keeps the current value; Ctrl+C cancels.
    case "${field}" in
      Name) cntools_registry_prompt_into name Name 'Required · 1–50 characters' "${name}" || status=$? ;;
      Description) cntools_registry_prompt_into description Description 'Required · 1–500 characters' "${description}" || status=$? ;;
      Ticker) cntools_registry_prompt_into ticker Ticker "Optional · 2–9 characters${keep}" "${ticker}" "${clearable}" || status=$? ;;
      URL) cntools_registry_prompt_into url URL "Optional · https:// URL, at most 250 characters${keep}" "${url}" "${clearable}" || status=$? ;;
      Decimals) cntools_registry_prompt_into decimals Decimals "Optional · 0–255 (0 is supported)${keep}" "${decimals}" "${clearable}" || status=$? ;;
      Logo)
        cntools_ui_pick_path chosen_logo 'Logo PNG file' "Optional · a PNG of at most 64 KiB${logo_keep}." '' file 'Skip logo' || status=$?
        ((status != 0)) || logo="${chosen_logo}" ;;
      *) continue ;;
    esac
    ((status == 0 || status == 1)) || return "${status}"
  done
  cntools_transaction_log CHOICE "Registry export confirmed asset=${identity} kind=${kind}"
  cntools_ui_spin_function 'Signing and validating registry metadata…' cntools_registry_export "${identity}" "${name}" "${description}" "${ticker}" "${url}" "${decimals}" "${logo}" "${previous}" || return 2
  [[ "${CNTOOLS_NETWORK}" == mainnet ]] && repo=https://github.com/cardano-foundation/cardano-token-registry || repo=https://github.com/input-output-hk/metadata-registry-testnet
  cntools_policy_manage_begin 'Register Asset'
  {
    cntools_table_pair Result 'Signed and validated; not published' success
    cntools_table_pair File "${CNTOOLS_REGISTRY_SAVED}" identifier
    cntools_table_pair Registry "${repo}" identifier
    cntools_table_pair 'Next step' "Submit the JSON file through the registry's review process" value
  } | cntools_table_render 'Registry submission'
}

cntools_registry_action() {
  local status=0
  CNTOOLS_POLICY_ERROR='' CNTOOLS_TRANSACTION_ERROR='' CNTOOLS_REGISTRY_SAVED=''
  cntools_registry_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait; return 0 ;;
    3) return 0 ;; # Nothing to choose; the reason was shown and acknowledged.
    1|130)
      cntools_transaction_log CHOICE 'Registry export cancelled'
      return "${status}" ;;
  esac
  cntools_ui_render_status error "${CNTOOLS_POLICY_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Registry export failed.}} See ${CNTOOLS_LOG} for details."
  cntools_ui_wait
  return 1 # Shown and acknowledged above; no second failure banner.
}
