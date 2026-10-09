#!/usr/bin/env bash
# Guided retirement on the common pool review/sign/export/submit workflow.
# shellcheck disable=SC2034
cntools_pool_retirement_rows() {
  local reward='' pending=''
  cntools_table_pair Pool "${CNTOOLS_POOL_REG_NAME}" identifier
  cntools_table_pair 'Pool ID' "${CNTOOLS_POOL_REG_ID}" identifier
  cntools_table_pair 'Funding wallet' "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
  cntools_table_pair 'Spendable ADA' "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE}")" number
  cntools_table_pair 'Current epoch' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_CURRENT}")" number
  [[ -z "${CNTOOLS_POOL_RETIRE_EPOCH}" ]] || cntools_table_pair 'Retirement epoch' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_EPOCH}")" number
  cntools_table_pair 'Allowed epochs' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_MIN}")–$(cntools_number_format "${CNTOOLS_POOL_RETIRE_MAX}")" number
  pending="$(jq -r '.retirement // empty' <<< "${CNTOOLS_POOL_REG_STATE}")"
  [[ -z "${pending}" ]] || cntools_table_pair 'Already scheduled' "Epoch $(cntools_number_format "${pending}") · this transaction replaces that schedule" warning
  reward="$(jq -r '.current.reward_addr // .current.spsAccountId.keyHash // .current.spsAccountId.scriptHash // empty' <<< "${CNTOOLS_POOL_REG_STATE}")"
  [[ -z "${reward}" ]] || cntools_table_pair 'Deposit return account / credential' "${reward}" identifier
  pending="$(jq -r '.pending.spsAccountId.keyHash // .pending.spsAccountId.scriptHash // empty' <<< "${CNTOOLS_POOL_REG_STATE}")"
  [[ -z "${pending}" ]] || cntools_table_pair 'Pending return credential' "${pending}" warning
  cntools_table_pair 'Deposit refund in this transaction' 'None · returned at retirement, not to the funding wallet' muted
}

cntools_pool_retirement_notice() {
  cntools_ui_render_status warn 'The pool deposit is returned to its registered reward account when retirement takes effect. Keep that stake account registered; otherwise the deposit can be lost to the treasury. This does not withdraw rewards, remove keys or stop your node.'
}

cntools_pool_retirement_select_epoch() {
  local answer='' normalized='' default=''
  cntools_ui_spin_function 'Checking the allowed retirement epochs…' cntools_pool_retirement_window_collect || return 2
  default="${CNTOOLS_POOL_RETIRE_EPOCH:-${CNTOOLS_POOL_RETIRE_MIN}}"
  while true; do
    cntools_pool_registration_begin
    cntools_pool_retirement_rows | cntools_table_render 'Pool retirement' || return 2
    cntools_pool_retirement_notice
    cntools_pool_registration_input answer "Retirement epoch (default: ${default})" 'Enter uses the default; commas are accepted' || return $?
    [[ -n "${answer}" ]] || answer="${default}"
    if cntools_number_normalize_into normalized "${answer}" && cntools_pool_retirement_uint_valid "${normalized}" &&
        ((normalized >= CNTOOLS_POOL_RETIRE_MIN && normalized <= CNTOOLS_POOL_RETIRE_MAX)); then
      CNTOOLS_POOL_RETIRE_EPOCH="${normalized}"
      cntools_transaction_log CHOICE "Pool retirement epoch=${normalized} pool=${CNTOOLS_POOL_REG_ID}"
      return 0
    fi
    cntools_ui_render_status warn "Choose an integer epoch from ${CNTOOLS_POOL_RETIRE_MIN} to ${CNTOOLS_POOL_RETIRE_MAX}."
    cntools_ui_wait
  done
}

cntools_pool_retirement_workflow() {
  local selected='' wallet='' workflow='' can_sign=N choice='' proceed='' staged=''
  CNTOOLS_POOL_REG_SAVED=''; CNTOOLS_POOL_REG_RESULT_SHOWN=N
  CNTOOLS_POOL_RETIRE_EPOCH=''; CNTOOLS_POOL_REG_OWNERS='[]'; CNTOOLS_POOL_REG_COMBINE_HARDWARE=N
  cntools_pool_registration_begin
  cntools_transaction_require_cli && cntools_pool_catalog_build || return 2
  cntools_pool_registration_choose_eligible_into selected || return $?
  cntools_pool_registration_prepare_identity "${selected}" || return 2
  cntools_wallet_catalog_build || return 2
  (( ${#CNTOOLS_WALLET_NAMES[@]} > 0 )) || { cntools_wallet_register_set_error 'No funding wallets are available.'; return 2; }
  cntools_wallet_choose wallet || return $?
  cntools_pool_registration_prepare_funding "${CNTOOLS_WALLET_PATHS[wallet]}" || return 2
  cntools_ui_spin_function 'Checking pool state, retirement limits and funding…' cntools_pool_registration_collect || return 2
  cntools_pool_retirement_select_epoch || return $?
  cntools_pool_registration_can_sign_into can_sign
  cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $?
  cntools_pool_registration_hardware_choice || return $?
  while true; do
    cntools_ui_spin_function 'Building and validating the retirement transaction…' cntools_pool_registration_build_into staged || return 2
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into choice "${staged}" "${proceed}" cntools_pool_registration_begin \
      cntools_pool_registration_render_plan 'Change retirement epoch' 'Change workflow' || return $?
    case "${choice}" in
      "${proceed}") break ;;
      'Change retirement epoch') cntools_pool_retirement_select_epoch || return $? ;;
      'Change workflow') cntools_transaction_ui_workflow_into workflow "${can_sign}" || return $? ;;
      *) return 2 ;;
    esac
  done
  cntools_pool_transaction_finish "${staged}" "${workflow}"
}

cntools_pool_action_retire() {
  local status=0
  cntools_transaction_clear_error
  CNTOOLS_WALLET_REGISTER_ERROR=''; CNTOOLS_POOL_REG_SAVED=''; CNTOOLS_POOL_REG_RESULT_SHOWN=N
  cntools_pool_registration_operation_set pool-retire || return 2
  cntools_pool_retirement_workflow || status=$?
  if ((status == 1)); then cntools_transaction_ui_cancel 'Pool retirement cancelled; saved packages retained'
  elif ((status != 0)) && [[ "${CNTOOLS_POOL_REG_RESULT_SHOWN}" != Y ]]; then
    cntools_transaction_ui_render_result danger "${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Pool retirement failed. See ${CNTOOLS_LOG}.}}" '' "${CNTOOLS_POOL_REG_SAVED}"
  fi
  cntools_ui_wait
  ((status <= 1))
}
