#!/usr/bin/env bash
# Guided retirement on the common pool review/sign/export/submit workflow.
# shellcheck disable=SC2034
# A reward credential as a stake address (local node data has only the hash).
cntools_pool_retirement_reward_address_into() {
  local destination="$1" credential="$2" kind="${3:-key}" header='e' encoded=''
  [[ "${credential}" =~ ^[0-9a-f]{56}$ ]] || { printf -v "${destination}" '%s' "${credential}"; return 0; }
  [[ "${kind}" == key ]] || header='f'
  [[ "${CNTOOLS_NETWORK:-}" == mainnet ]] && header+='1' || header+='0'
  cntools_bech32_encode_into encoded "${header}${credential}" "$([[ "${CNTOOLS_NETWORK:-}" == mainnet ]] && printf stake || printf stake_test)" ||
    encoded="${credential}"
  printf -v "${destination}" '%s' "${encoded}"
}

cntools_pool_retirement_rows() {
  local pending='' kind=key refund='' reward="${CNTOOLS_POOL_RETIRE_REWARD_ADDRESS:-}"
  cntools_table_pair Pool "${CNTOOLS_POOL_REG_NAME}" identifier
  cntools_table_pair 'Pool ID' "${CNTOOLS_POOL_REG_ID}" identifier
  cntools_table_pair 'Funding wallet' "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
  cntools_table_pair 'Spendable ADA' "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_AVAILABLE_LOVELACE}")" number
  cntools_table_pair 'Current epoch' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_CURRENT}")" number
  [[ -z "${CNTOOLS_POOL_RETIRE_EPOCH}" ]] || cntools_table_pair 'Retirement epoch' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_EPOCH}")" number
  cntools_table_pair 'Allowed epochs' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_MIN}")–$(cntools_number_format "${CNTOOLS_POOL_RETIRE_MAX}")" number
  pending="$(jq -r '.retirement // empty' <<< "${CNTOOLS_POOL_REG_STATE}")"
  [[ -z "${pending}" ]] || cntools_table_pair 'Already scheduled' "Epoch $(cntools_number_format "${pending}") · this transaction replaces that schedule" warning
  # One row for where the deposit goes: it is refunded at retirement, not
  # here, and only to a registered reward account.
  refund="$(cntools_number_format_lovelace "${CNTOOLS_POOL_RETIRE_DEPOSIT:-0}")"
  case "${CNTOOLS_POOL_RETIRE_REWARD_STATE:-unknown}" in
    no) cntools_table_pair 'Pool deposit refund' "${refund} → treasury · reward account ${reward} is not registered" warning ;;
    yes) cntools_table_pair 'Pool deposit refund' "${refund} → ${reward} · at retirement" value ;;
    *) cntools_table_pair 'Pool deposit refund' "${refund} → ${reward:-the registered reward account} · at retirement, if still registered" value ;;
  esac
  jq -e '.pending.spsAccountId.scriptHash // empty' <<< "${CNTOOLS_POOL_REG_STATE}" >/dev/null 2>&1 && kind=script
  pending="$(jq -r '.pending.spsAccountId.keyHash // .pending.spsAccountId.scriptHash // empty' <<< "${CNTOOLS_POOL_REG_STATE}")"
  if [[ -n "${pending}" ]]; then
    cntools_pool_retirement_reward_address_into pending "${pending}" "${kind}"
    cntools_table_pair 'Pending reward account' "${pending} · takes effect next epoch" warning
  fi
}

cntools_pool_retirement_notice() {
  if [[ "${CNTOOLS_POOL_RETIRE_REWARD_STATE:-unknown}" == no ]]; then
    cntools_ui_render_status warn "The reward account ${CNTOOLS_POOL_RETIRE_REWARD_ADDRESS} is not registered, so the deposit refund would go to the treasury. Register it (Wallet → Register) before the retirement epoch. Retiring does not withdraw rewards, remove keys or stop your node."
  else
    cntools_ui_render_status warn 'Keep that reward account registered until the deposit is refunded; otherwise the deposit goes to the treasury. Retiring does not withdraw rewards, remove keys or stop your node.'
  fi
}

# Detailed asks for the epoch on a compact screen (the review shows the rest);
# Quick starts from the earliest epoch, and the review can change it. "ask"
# (review → Change retirement epoch) reads the allowed window again and asks
# in both styles; "again" asks with the window just read. The first call
# uses the window the collection read.
cntools_pool_retirement_select_epoch() {
  local mode="${1:-}" answer='' normalized='' default=''
  if [[ "${mode}" == ask ]]; then
    cntools_ui_spin_function 'Checking the allowed retirement epochs…' cntools_pool_retirement_window_collect || return 2
  fi
  default="${CNTOOLS_POOL_RETIRE_MIN}"
  ! cntools_pool_retirement_epoch_allowed || default="${CNTOOLS_POOL_RETIRE_EPOCH}"
  if [[ -z "${mode}" && -z "${CNTOOLS_POOL_RETIRE_EPOCH}" ]] && cntools_flow_quick; then
    CNTOOLS_POOL_RETIRE_EPOCH="${default}"
    cntools_transaction_log CHOICE "Pool retirement epoch default=${default} (earliest) flow=quick pool=${CNTOOLS_POOL_REG_ID}"
    return 0
  fi
  while true; do
    cntools_pool_registration_begin
    { cntools_table_pair Pool "${CNTOOLS_POOL_REG_NAME}" identifier
      cntools_table_pair 'Current epoch' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_CURRENT}")" number
      cntools_table_pair 'Allowed epochs' "$(cntools_number_format "${CNTOOLS_POOL_RETIRE_MIN}")–$(cntools_number_format "${CNTOOLS_POOL_RETIRE_MAX}")" number
    } | cntools_table_render 'Retirement epoch' || return 2
    cntools_pool_registration_input answer "Retirement epoch (Enter for ${default})" 'Enter uses the default; commas are accepted' || return $?
    [[ -n "${answer}" ]] || answer="${default}"
    if cntools_number_normalize_into normalized "${answer}" && cntools_pool_retirement_uint_valid "${normalized}" &&
        ((normalized >= CNTOOLS_POOL_RETIRE_MIN && normalized <= CNTOOLS_POOL_RETIRE_MAX)); then
      CNTOOLS_POOL_RETIRE_EPOCH="${normalized}"
      cntools_transaction_log CHOICE "Pool retirement epoch=${normalized} pool=${CNTOOLS_POOL_REG_ID}"
      return 0
    fi
    # The redraw repeats this warning; no extra Enter.
    cntools_ui_render_status warn "Choose an integer epoch from ${CNTOOLS_POOL_RETIRE_MIN} to ${CNTOOLS_POOL_RETIRE_MAX}."
  done
}

cntools_pool_retirement_epoch_allowed() {
  cntools_pool_retirement_uint_valid "${CNTOOLS_POOL_RETIRE_EPOCH}" &&
    (( CNTOOLS_POOL_RETIRE_EPOCH >= CNTOOLS_POOL_RETIRE_MIN && CNTOOLS_POOL_RETIRE_EPOCH <= CNTOOLS_POOL_RETIRE_MAX ))
}

# After a rebuild for changed chain state: an epoch the chain moved past is
# reset to the new earliest (Quick) or asked again (Detailed).
cntools_pool_retirement_epoch_refresh() {
  local previous="${CNTOOLS_POOL_RETIRE_EPOCH}"
  ! cntools_pool_retirement_epoch_allowed || return 0
  if cntools_flow_quick; then
    CNTOOLS_POOL_RETIRE_EPOCH="${CNTOOLS_POOL_RETIRE_MIN}"
    cntools_transaction_log CHOICE "Pool retirement epoch reset previous=${previous} default=${CNTOOLS_POOL_RETIRE_EPOCH} (earliest) flow=quick"
    cntools_ui_render_status warn "The epoch advanced past retirement epoch $(cntools_number_format "${previous}"), so it is now the new earliest, $(cntools_number_format "${CNTOOLS_POOL_RETIRE_EPOCH}")."
    return 0
  fi
  cntools_pool_retirement_select_epoch again
}

cntools_pool_retirement_workflow() {
  local selected='' wallet='' workflow='' can_sign=N choice='' proceed='' staged='' status=0 rebuild=N what='' before=''
  CNTOOLS_POOL_REG_SAVED=''; CNTOOLS_POOL_REG_RESULT_SHOWN=N
  CNTOOLS_POOL_RETIRE_EPOCH=''; CNTOOLS_POOL_REG_OWNERS='[]'; CNTOOLS_POOL_REG_COMBINE_HARDWARE=N
  cntools_pool_registration_begin
  cntools_transaction_require_cli && cntools_pool_catalog_build || return 2
  (( ${#CNTOOLS_POOL_NAMES[@]} > 0 )) || { cntools_pool_empty_notice; return 3; }
  cntools_pool_registration_choose_eligible_into selected || return $?
  cntools_pool_registration_prepare_identity "${selected}" || return 2
  cntools_wallet_catalog_build || return 2
  cntools_pool_registration_choose_funding_into wallet || return $?
  cntools_pool_registration_hwcli_check || return 2
  cntools_pool_retirement_select_epoch || return $?
  cntools_pool_registration_can_sign_into can_sign
  cntools_transaction_ui_initial_workflow_into workflow "${can_sign}" || return $?
  cntools_transaction_ui_initial_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $?
  cntools_pool_registration_hardware_session || return $?
  cntools_pool_registration_build_ui_into staged || return $?
  while true; do
    while true; do
      # Rebuilt only after a change; Esc in a "Change …" keeps the build.
      if [[ "${rebuild}" == Y ]]; then cntools_pool_registration_rebuild_into staged "${what}" || return $?; rebuild=N; fi
      cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
      cntools_transaction_ui_review_into choice "${staged}" "${proceed}" cntools_pool_registration_begin \
        cntools_pool_registration_render_plan 'Change retirement epoch' 'Change expiry' 'Change workflow' || return $?
      case "${choice}" in
        "${proceed}") break ;;
        'Change retirement epoch')
          cntools_pool_registration_save
          before="${CNTOOLS_POOL_RETIRE_EPOCH}"
          status=0; cntools_pool_retirement_select_epoch ask || status=$?
          ((status <= 1)) || return "${status}"
          [[ "${status}" == 0 && "${CNTOOLS_POOL_RETIRE_EPOCH}" != "${before}" ]] || continue
          rebuild=Y what='retirement epoch' ;;
        'Change workflow'|'Change expiry')
          status=0; cntools_pool_registration_change_common "${choice}" workflow "${can_sign}" || status=$?
          ((status <= 1)) || return "${status}"
          ((status == 0)) || continue
          rebuild=Y what=expiry ;;
        *) return 2 ;;
      esac
    done
    status=0; cntools_pool_transaction_finish "${staged}" "${workflow}" || status=$?
    ((status == 4)) || return "${status}"
    cntools_pool_registration_refresh || return $?
    cntools_pool_registration_build_ui_into staged || return $?
  done
}

cntools_pool_action_retire() {
  local status=0
  cntools_transaction_clear_error
  CNTOOLS_WALLET_REGISTER_ERROR=''; CNTOOLS_POOL_REG_SAVED=''; CNTOOLS_POOL_REG_RESULT_SHOWN=N
  cntools_pool_registration_operation_set pool-retire || return 2
  cntools_pool_retirement_workflow || status=$?
  cntools_pool_action_outcome "${status}" 'Pool retirement'
}
