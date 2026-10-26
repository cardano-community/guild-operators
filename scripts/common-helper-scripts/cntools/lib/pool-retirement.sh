#!/usr/bin/env bash
# Retirement schedules pool removal; its deposit is NOT credited in this tx.
# shellcheck disable=SC2034
CNTOOLS_POOL_RETIRE_EPOCH=''
CNTOOLS_POOL_RETIRE_CURRENT=0
CNTOOLS_POOL_RETIRE_MIN=0
CNTOOLS_POOL_RETIRE_MAX=0
CNTOOLS_POOL_RETIRE_DEPOSIT=''
CNTOOLS_POOL_RETIRE_REWARD_ADDRESS='' CNTOOLS_POOL_RETIRE_REWARD_STATE=unknown

cntools_pool_retirement_uint_valid() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,9})$ ]] && (( $1 <= 2147483647 ))
}

cntools_pool_retirement_state_into() {
  local target="$1" index="${CNTOOLS_POOL_REG_INDEX}" retirement_state=''
  case "${CNTOOLS_POOL_CHAIN_STATUS[index]}" in
    Registered|Retiring) ;;
    'Not registered'|'Not indexed'|Retired) printf -v "${target}" '%s' '{"registered":false}'; return 0 ;;
    *) cntools_wallet_register_set_error 'Pool registration could not be verified. No retirement can be prepared from unavailable data.'; return 1 ;;
  esac
  case "${CNTOOLS_POOL_CHAIN_SOURCE[index]}" in
    'Local node')
      retirement_state="$(jq -cS --arg retirement "${CNTOOLS_POOL_RETIREMENT[index]}" --argjson pending "${CNTOOLS_POOL_FUTURE[index]}" \
        '{registered:true,retirement:$retirement,current:.,pending:$pending}' <<< "${CNTOOLS_POOL_CURRENT[index]}")" || return 1 ;;
    'Koios API')
      retirement_state="$(jq -cS '{registered:true,retirement:(.retiring_epoch // "" | tostring),
        current:{reward_addr,pledge,fixed_cost,margin,vrf_key_hash,owners,relays,meta_url,meta_hash,deposit},pending:{}}' \
        <<< "${CNTOOLS_POOL_CURRENT[index]}")" || return 1 ;;
    *) return 1 ;;
  esac
  printf -v "${target}" '%s' "${retirement_state}"
}

# Use the same source as funding, not wall-clock approximations or header cache.
# Ledger POOL rule: current epoch < retirement <= current epoch + eMax.
cntools_pool_retirement_window_collect() {
  local retirement_slot='' max_interval=''
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] &&
    cntools_funding_tip_into retirement_slot "${CNTOOLS_WALLET_REGISTER_BACKEND}" &&
    cntools_pool_retirement_uint_valid "${CNTOOLS_FUNDING_EPOCH:-}" &&
    cntools_wallet_query_json_uint_field max_interval "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}" poolRetireMaxEpoch &&
    cntools_pool_retirement_uint_valid "${max_interval}" && ((max_interval > 0)) || {
    cntools_wallet_register_set_error 'Current epoch and pool retirement limits could not be verified from the funding source.'; return 1;
  }
  CNTOOLS_POOL_RETIRE_CURRENT="${CNTOOLS_FUNDING_EPOCH}"
  CNTOOLS_POOL_RETIRE_MIN=$((CNTOOLS_POOL_RETIRE_CURRENT+1))
  CNTOOLS_POOL_RETIRE_MAX=$((CNTOOLS_POOL_RETIRE_CURRENT+max_interval))
  cntools_pool_retirement_uint_valid "${CNTOOLS_POOL_RETIRE_MAX}" || return 1
  cntools_transaction_log TRANSACTION "Pool retirement window current=${CNTOOLS_POOL_RETIRE_CURRENT} min=${CNTOOLS_POOL_RETIRE_MIN} max=${CNTOOLS_POOL_RETIRE_MAX} backend=${CNTOOLS_WALLET_REGISTER_BACKEND}"
}

cntools_pool_retirement_window_check() {
  cntools_pool_retirement_window_collect || return 1
  cntools_pool_retirement_uint_valid "${CNTOOLS_POOL_RETIRE_EPOCH}" &&
    (( CNTOOLS_POOL_RETIRE_EPOCH >= CNTOOLS_POOL_RETIRE_MIN && CNTOOLS_POOL_RETIRE_EPOCH <= CNTOOLS_POOL_RETIRE_MAX )) || {
    CNTOOLS_POOL_REG_RECHECK_CHANGED=Y
    cntools_wallet_register_set_error "The epoch advanced: retirement epoch ${CNTOOLS_POOL_RETIRE_EPOCH} is outside the allowed ${CNTOOLS_POOL_RETIRE_MIN}–${CNTOOLS_POOL_RETIRE_MAX}. Rebuild and review."; return 1;
  }
}

cntools_pool_retirement_collect() {
  [[ "$(jq -r .registered <<< "${CNTOOLS_POOL_REG_STATE}")" == true ]] || {
    cntools_wallet_register_set_error 'This pool is not currently registered. An unindexed or retired pool cannot be retired.'; return 1;
  }
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0
  # The refund is the deposit paid at registration; chain data has it, the
  # protocol parameter is the fallback.
  CNTOOLS_POOL_RETIRE_DEPOSIT="$(jq -r '.current.spsDeposit // .current.deposit // empty | tostring' <<< "${CNTOOLS_POOL_REG_STATE}")"
  [[ "${CNTOOLS_POOL_RETIRE_DEPOSIT}" =~ ^[0-9]+$ ]] ||
    cntools_wallet_query_json_uint_field CNTOOLS_POOL_RETIRE_DEPOSIT "${CNTOOLS_FUNDING_PROTOCOL}" stakePoolDeposit || CNTOOLS_POOL_RETIRE_DEPOSIT=''
  CNTOOLS_POOL_REG_PROTOCOL_STATE="$(jq -cS . "${CNTOOLS_FUNDING_PROTOCOL}")" || return 1
  cntools_pool_retirement_window_collect && cntools_wallet_register_inventory_use_all || return 1
  cntools_pool_retirement_reward_check
}

# Where the deposit refund goes at retirement: the reward account of the
# parameters in force then (a pending update's, when there is one). Only a
# registered account receives it; otherwise it goes to the treasury. Best
# effort: an account that cannot be checked stays "unknown".
cntools_pool_retirement_reward_check() {
  local pending_key='' pending_script='' current_key='' current_script='' koios='' credential='' kind=key address='' hash=''
  CNTOOLS_POOL_RETIRE_REWARD_ADDRESS='' CNTOOLS_POOL_RETIRE_REWARD_STATE=unknown
  # Unit separators keep empty fields (tabs are whitespace to read).
  IFS=$'\037' read -r pending_key pending_script current_key current_script koios < <(jq -r '
    [.pending.spsAccountId.keyHash // "", .pending.spsAccountId.scriptHash // "", .current.spsAccountId.keyHash // "",
     .current.spsAccountId.scriptHash // "", .current.reward_addr // ""] | map(tostring) | join("\u001f")' <<< "${CNTOOLS_POOL_REG_STATE}" 2>/dev/null) || return 0
  if [[ -n "${pending_key}" ]]; then credential="${pending_key}"
  elif [[ -n "${pending_script}" ]]; then credential="${pending_script}" kind=script
  elif [[ -n "${current_key}" ]]; then credential="${current_key}"
  elif [[ -n "${current_script}" ]]; then credential="${current_script}" kind=script
  fi
  if [[ -n "${credential}" ]]; then
    cntools_pool_retirement_reward_address_into address "${credential}" "${kind}"
    hash="${credential}"
  elif [[ -n "${koios}" ]]; then
    address="${koios}"
    cntools_wallet_reward_credential_into hash "${address}" 2>/dev/null || hash="${address}"
  fi
  CNTOOLS_POOL_RETIRE_REWARD_ADDRESS="${address}"
  [[ "${address}" =~ ^stake(_test)?1[a-z0-9]+$ ]] && declare -F cntools_pool_stake_collect >/dev/null 2>&1 || return 0
  # The shared owner/reward check, with this account as the only record.
  CNTOOLS_POOL_REG_OWNERS='[]' CNTOOLS_POOL_REG_REWARD_HASH="${hash}" CNTOOLS_POOL_REG_REWARD_ADDRESS="${address}"
  CNTOOLS_POOL_REG_REWARD_LABEL='' CNTOOLS_POOL_REG_REWARD_VKEY='' CNTOOLS_POOL_REG_REWARD_SOURCE=''
  cntools_pool_stake_collect || return 0
  CNTOOLS_POOL_RETIRE_REWARD_STATE="${CNTOOLS_POOL_STAKE_STATUS[${hash}]:-unknown}"
  cntools_transaction_log POOL "Retirement refund account=${address} registered=${CNTOOLS_POOL_RETIRE_REWARD_STATE}"
}

cntools_pool_retirement_certificate_create() {
  local certificate='' output='' errors='' status=0
  cntools_pool_retirement_uint_valid "${CNTOOLS_POOL_RETIRE_EPOCH}" || return 1
  cntools_transaction_temp_file certificate pool-retirement || return 1
  cntools_transaction_temp_file output pool-retirement-output || return 1
  cntools_transaction_temp_file errors pool-retirement-errors || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-pool deregistration-certificate \
    --cold-verification-key-file "${CNTOOLS_POOL_REG_COLD_VKEY}" --epoch "${CNTOOLS_POOL_RETIRE_EPOCH}" --out-file "${certificate}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Pool retirement certificate creation failed' "${status}" "${errors}" "${output}"; return 1; fi
  cntools_transaction_file_safe "${certificate}" 131072 || return 1
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE="${certificate}"
}

cntools_pool_retirement_validate_certificate() {
  jq -e --arg hash "${CNTOOLS_POOL_REG_HEX}" --argjson epoch "${CNTOOLS_POOL_RETIRE_EPOCH}" '
    .certificates == [{"Pool retirement":{"epoch":$epoch,"stake pool key hash":$hash}}]
  ' <<< "$1" >/dev/null || {
    cntools_wallet_register_set_error 'The decoded certificate does not match the selected pool and retirement epoch.'; return 1;
  }
}
