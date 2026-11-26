#!/usr/bin/env bash
# Compact review and explicit confirmation before creating policy authority.
cntools_policy_cancelled() {
  [[ "$1" == 1 || "$1" == 130 ]] || return 1
  cntools_transaction_log CHOICE 'Policy creation cancelled'
}

cntools_policy_action_create() {
  local name='' target='' duration='' seconds=0 expiry='' date='' status=0
  cntools_ui_action_begin 'Create Policy' '/ Advanced / Asset / Create Policy'
  # Tool and folder problems stop the action before any question.
  cntools_policy_preflight_environment || {
    cntools_ui_render_status error "${CNTOOLS_POLICY_ERROR}"; cntools_ui_wait; return 1;
  }
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
    cntools_ui_input duration 'Policy expiry' '0 = none · a duration (90d, 12h) · seconds · a date (YYYY-MM-DD)' || status=$?
    cntools_policy_cancelled "${status}" && return 0
    ((status == 0)) || return "${status}"
    status=0; cntools_policy_expiry_seconds_into seconds "${duration}" || status=$?
    if ((status == 0)) && cntools_policy_expiry_into expiry "${seconds}"; then break; fi
    cntools_transaction_log CHOICE 'Invalid policy expiry rejected'
    if ((status == 3)); then cntools_ui_render_status warn 'That date has already passed. Enter a future date, a duration or 0 for no expiry.'
    else cntools_ui_render_status warn "Enter 0 for no expiry, a duration such as 90d, 12h or 3600 (seconds), or a date as YYYY-MM-DD with optional HH:MM (${CNTOOLS_TIMEZONE:-UTC}). An expiry needs a supported network and an accurate system clock."; fi
  done
  date='No expiry'
  if [[ "${expiry}" != 0 ]]; then
    cntools_slot_datetime_into date "${expiry}" || { cntools_ui_render_status error 'The policy expiry could not be displayed.'; cntools_ui_wait; return 1; }
    if (( seconds >= 172800 )); then date+=" · in $(cntools_number_format "$((seconds / 86400))") days"
    elif (( seconds >= 7200 )); then date+=" · in $((seconds / 3600)) hours"
    else date+=" · in $(( (seconds + 59) / 60 )) minutes"; fi
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
  # New key material is asked in both flow styles; a permanent expiry
  # defaults to No: a mistyped duration cannot be undone once tokens are minted.
  status=0
  if [[ "${expiry}" == 0 ]]; then cntools_ui_confirm "Create policy ${name} now?" || status=$?
  else cntools_ui_confirm "Create policy ${name} expiring ${date%% · *}? The expiry cannot be changed." false || status=$?; fi
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
  # A failure is shown and acknowledged above: no second menu banner.
  ((status == 0)) || return 1
}
