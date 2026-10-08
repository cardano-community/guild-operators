#!/usr/bin/env bash
# Guided new/update registry entry, with explicit off-chain/manual publication.
# shellcheck disable=SC2034,SC2015
cntools_registry_prompt_into() {
  local output="$1" field="$2" hint="$3" entered=''
  while true; do
    cntools_ui_input entered "${field}" "${hint}" || return $?
    if cntools_registry_field_valid "${field}" "${entered}"; then printf -v "${output}" '%s' "${entered}"; return 0; fi
    cntools_ui_render_status warn "Invalid ${field}. ${hint}"
  done
}

cntools_registry_workflow() {
  local selected='' identity='' name='' description='' ticker='' url='' decimals='' logo='' previous='' kind='' status=0 repo=''
  cntools_policy_manage_begin 'Register Asset'
  cntools_ui_render_status info 'Prepare a signed Token Registry submission file. This does not mint tokens, attach transaction metadata or publish to a registry.'
  cntools_registry_require_tool || return 2
  cntools_policy_selection_into selected || return $?
  cntools_policy_prepare "${CNTOOLS_POLICY_PATHS[selected]}" || return 2
  [[ -n "${CNTOOLS_POLICY_SELECTED_SOURCE}" ]] || { cntools_policy_error 'Decrypt the policy before signing registry metadata.'; return 2; }
  cntools_policy_asset_catalog "${CNTOOLS_POLICY_PATHS[selected]}" "${CNTOOLS_POLICY_ID}" || return 2
  cntools_policy_asset_choose_into identity "${CNTOOLS_POLICY_ID}" || return $?
  cntools_ui_choose kind 'Registry entry' New 'Update existing entry' Cancel || return $?
  [[ "${kind}" != Cancel ]] || return 1
  if [[ "${kind}" == 'Update existing entry' ]]; then
    cntools_ui_input previous 'Current registry JSON file' 'Provide the current published entry to preserve fields and update sequences safely' || return $?
    [[ -n "${previous}" ]] || return 1
  fi
  cntools_registry_prompt_into name Name 'Required · 1–50 characters' &&
    cntools_registry_prompt_into description Description 'Required · 1–500 characters' &&
    cntools_registry_prompt_into ticker Ticker 'Optional · 2–9 characters; blank preserves an existing field' &&
    cntools_registry_prompt_into url URL 'Optional · https:// URL, at most 250 characters' &&
    cntools_registry_prompt_into decimals Decimals 'Optional · 0–255 (0 is supported)' || return $?
  cntools_ui_input logo 'Logo PNG file' 'Optional · at most 64 KiB; blank preserves an existing logo' || return $?
  {
    cntools_table_pair Subject "${identity/./}" identifier
    cntools_table_pair Name "${name}" value
    cntools_table_pair Description "${description}" value
    [[ -z "${ticker}" ]] || cntools_table_pair Ticker "${ticker}" value
    [[ -z "${url}" ]] || cntools_table_pair URL "${url}" identifier
    [[ -z "${decimals}" ]] || cntools_table_pair Decimals "${decimals}" number
    [[ -z "${logo}" ]] || cntools_table_pair Logo "${logo}" identifier
    cntools_table_pair Entry "${kind}" value
  } | cntools_table_render 'Token Registry entry' || return 2
  cntools_ui_render_status warn 'For an already registered asset, use Update with its current registry entry. Blank optional fields are preserved; this flow does not delete published fields.'
  cntools_ui_confirm 'Sign and save this registry submission?' false || return $?
  cntools_transaction_log CHOICE "Registry export confirmed asset=${identity} kind=${kind}"
  cntools_ui_spin_function 'Signing and validating registry metadata…' cntools_registry_export "${identity}" "${name}" "${description}" "${ticker}" "${url}" "${decimals}" "${logo}" "${previous}" || return 2
  [[ "${CNTOOLS_NETWORK}" == mainnet ]] && repo=https://github.com/cardano-foundation/cardano-token-registry || repo=https://github.com/input-output-hk/metadata-registry-testnet
  {
    cntools_table_pair Result 'Signed and validated; not published' success
    cntools_table_pair File "${CNTOOLS_REGISTRY_SAVED}" identifier
    cntools_table_pair Registry "${repo}" identifier
    cntools_table_pair 'Next step' "Submit the JSON file through the registry's review process" value
  } | cntools_table_render 'Registry submission'
}

cntools_registry_action() {
  local status=0
  CNTOOLS_POLICY_ERROR='' CNTOOLS_TRANSACTION_ERROR=''
  cntools_registry_workflow || status=$?
  if ! cntools_policy_cancelled "${status}" && ((status != 0)); then
    cntools_ui_render_status error "${CNTOOLS_POLICY_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Registry export failed.}} See ${CNTOOLS_LOG} for details."
  fi
  cntools_ui_wait
  cntools_policy_cancelled "${status}" && return 0
  return "${status}"
}
