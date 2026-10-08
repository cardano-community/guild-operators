#!/usr/bin/env bash
# Retirement schedules pool removal; its deposit is NOT credited in this tx.
# shellcheck disable=SC2034
CNTOOLS_POOL_RETIRE_EPOCH=''
CNTOOLS_POOL_RETIRE_CURRENT=0
CNTOOLS_POOL_RETIRE_MIN=0
CNTOOLS_POOL_RETIRE_MAX=0

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
        current:{reward_addr,pledge,fixed_cost,margin,vrf_key_hash,owners,relays,meta_url,meta_hash},pending:{}}' \
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
    cntools_wallet_register_set_error "Retirement epoch must be between ${CNTOOLS_POOL_RETIRE_MIN} and ${CNTOOLS_POOL_RETIRE_MAX}. The epoch may have advanced; rebuild and review."; return 1;
  }
}

cntools_pool_retirement_collect() {
  [[ "$(jq -r .registered <<< "${CNTOOLS_POOL_REG_STATE}")" == true ]] || {
    cntools_wallet_register_set_error 'This pool is not currently registered. An unindexed or retired pool cannot be retired.'; return 1;
  }
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0
  CNTOOLS_POOL_REG_PROTOCOL_STATE="$(jq -cS . "${CNTOOLS_FUNDING_PROTOCOL}")" || return 1
  cntools_pool_retirement_window_collect && cntools_wallet_register_inventory_use_all
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
