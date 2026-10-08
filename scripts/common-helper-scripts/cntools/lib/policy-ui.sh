#!/usr/bin/env bash
# Compact review and explicit confirmation before creating policy authority.
cntools_policy_cancelled() {
  [[ "$1" == 1 || "$1" == 130 ]] || return 1
  cntools_transaction_log CHOICE 'Policy creation cancelled'
}

cntools_policy_action_create() {
  local name='' target='' duration='' expiry='' date='' status=0
  cntools_ui_action_begin 'Create Policy' '/ Advanced / Asset / Create Policy'
  while true; do
    status=0
    cntools_ui_input name 'Policy name' 'Letters, numbers, dots, underscores and hyphens (1–64)' || status=$?
    cntools_policy_cancelled "${status}" && return 0
    ((status == 0)) || return "${status}"
    if cntools_policy_target_into target "${name}" && [[ ! -e "${target}" && ! -L "${target}" ]]; then break; fi
    cntools_transaction_log CHOICE 'Invalid or existing policy name rejected'
    cntools_ui_render_status warn 'Use a valid name that is not already used by a policy folder.'
  done
  cntools_policy_preflight "${name}" || {
    cntools_ui_render_status error "${CNTOOLS_POLICY_ERROR}"; cntools_ui_wait; return 1;
  }
  cntools_transaction_log CHOICE "Policy name selected name=${name}"
  while true; do
    status=0
    cntools_ui_input duration 'Expiry in seconds (default: 0 = no expiry)' '0' || status=$?
    cntools_policy_cancelled "${status}" && return 0
    ((status == 0)) || return "${status}"
    if cntools_policy_expiry_into expiry "${duration}"; then break; fi
    cntools_transaction_log CHOICE 'Invalid policy expiry duration rejected'
    cntools_ui_render_status warn 'Use a whole number of seconds (0–9,999,999,999). A supported network and accurate system clock are needed for an expiry.'
  done
  date='No expiry'
  if [[ "${expiry}" != 0 ]]; then
    cntools_slot_datetime_into date "${expiry}" || { cntools_ui_render_status error 'The policy expiry could not be displayed.'; cntools_ui_wait; return 1; }
  fi
  cntools_transaction_log CHOICE "Policy expiry selected slot=${expiry}"
  cntools_ui_action_begin 'Create Policy' '/ Advanced / Asset / Create Policy'
  {
    cntools_table_pair Name "${name}" identifier
    cntools_table_pair Authority 'New single-signature native policy' value
    cntools_table_pair Expiry "${date}" warning
    cntools_table_pair Directory "${target}" identifier
  } | cntools_table_render 'Create policy' || return 1
  if [[ "${expiry}" == 0 ]]; then
    cntools_ui_render_status warn 'The policy cannot be changed after creation. With no expiry, the signing key remains authorized indefinitely.'
  else
    cntools_ui_render_status warn 'The policy cannot be changed after creation. Expiry permanently prevents both minting and burning. Check your system clock before proceeding.'
  fi
  cntools_ui_render_status info 'This creates keys and a policy only: no tokens, transaction or fee.'
  status=0; cntools_ui_confirm 'Create this policy?' false || status=$?
  cntools_policy_cancelled "${status}" && return 0
  ((status == 0)) || return "${status}"
  cntools_transaction_log CHOICE "Policy creation confirmed name=${name} expiry=${expiry}"
  status=0
  cntools_ui_spin_function 'Creating and validating native policy…' cntools_policy_create "${name}" "${expiry}" || status=$?
  cntools_ui_action_begin 'Create Policy' '/ Advanced / Asset / Create Policy'
  if ((status == 0)); then
    {
      cntools_table_pair Policy "${name}" identifier
      cntools_table_pair 'Policy ID' "${CNTOOLS_POLICY_ID}" identifier
      cntools_table_pair Expiry "${date}" warning
      cntools_table_pair Directory "${CNTOOLS_POLICY_DIRECTORY}" identifier
      cntools_table_pair Result Created success
    } | cntools_table_render Policy
    cntools_ui_render_status warn 'Back up the signing key securely. Anyone with that key can mint or burn under this policy while it remains valid.'
  else
    [[ -n "${CNTOOLS_POLICY_ERROR}" ]] || cntools_policy_error 'Policy creation failed; no incomplete policy was published.' || true
    cntools_ui_render_status error "${CNTOOLS_POLICY_ERROR} See ${CNTOOLS_LOG} for details."
  fi
  cntools_ui_wait
  return "${status}"
}
