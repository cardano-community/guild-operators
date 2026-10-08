#!/usr/bin/env bash
# Delegation-specific state and certificates; reuse the stake transaction builder.
# shellcheck disable=SC2034
CNTOOLS_DELEGATE_POOL_ID=""
CNTOOLS_DELEGATE_POOL_HEX=""
CNTOOLS_DELEGATE_CURRENT_POOL=""
CNTOOLS_DELEGATE_REGISTER=N
CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=N
CNTOOLS_DELEGATE_RETIRING=""


cntools_delegate_chain_state_validate() {
  local unused=""
  [[ "${CNTOOLS_WALLET_REGISTERED}" == yes || "${CNTOOLS_WALLET_REGISTERED}" == no ]] || return 1
  CNTOOLS_DELEGATE_REGISTER=N
  [[ "${CNTOOLS_WALLET_REGISTERED}" == yes ]] || CNTOOLS_DELEGATE_REGISTER=Y
  CNTOOLS_DELEGATE_CURRENT_POOL=""
  if [[ -n "${CNTOOLS_WALLET_POOL_DELEGATION:-}" ]]; then
    cntools_pool_id_into CNTOOLS_DELEGATE_CURRENT_POOL unused "${CNTOOLS_WALLET_POOL_DELEGATION}" || {
      cntools_wallet_register_set_error 'The current stake pool delegation is invalid.'; return 1;
    }
  fi
}

cntools_delegate_certificate_create() {
  local certificate="" output="" errors="" status=0
  local command=stake-delegation-certificate
  local -a args=()
  local -a stake_arguments=()
  [[ -n "${CNTOOLS_DELEGATE_POOL_ID}" && -n "${CNTOOLS_DELEGATE_POOL_HEX}" ]] || return 1
  if [[ "${CNTOOLS_DELEGATE_REGISTER}" == Y ]]; then
    [[ "${CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED}" == Y ]] || {
      cntools_wallet_register_set_error 'Stake registration must be approved before building delegation.'; return 1;
    }
    command=registration-and-delegation-certificate
    args+=(--key-reg-deposit-amt "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")
  fi
  cntools_transaction_temp_file certificate delegation-certificate || return 1
  cntools_transaction_temp_file output delegation-output || return 1
  cntools_transaction_temp_file errors delegation-errors || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == MultiSig ]]; then cntools_stake_credential_arguments_into stake_arguments || return 1
  else stake_arguments=(--stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}"); fi
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-address "${command}" \
    "${stake_arguments[@]}" \
    --stake-pool-id "${CNTOOLS_DELEGATE_POOL_ID}" "${args[@]}" --out-file "${certificate}" || status=$?
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure 'Delegation certificate creation failed' "${status}" "${errors}" "${output}"
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"; return 1
  fi
  cntools_transaction_file_safe "${certificate}" 131072 &&
    jq -e '.cborHex | type == "string" and length > 0 and test("^([0-9a-fA-F]{2})+$")' "${certificate}" >/dev/null || return 1
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE="${certificate}"
}

cntools_delegate_validate_body() {
  local view="" kind='Stake address delegation'
  local credential_kind=keyHash
  [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" != MultiSig ]] || credential_kind=scriptHash
  [[ "${CNTOOLS_DELEGATE_REGISTER}" != Y ]] || kind='Stake address registration and delegation'
  cntools_transaction_view_into view "$1" || return 1
  jq -e --arg kind "${kind}" --arg pool "${CNTOOLS_DELEGATE_POOL_HEX}" \
    --arg stake "${CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL}" \
    --arg credentialKind "${credential_kind}" \
    --arg address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
    --arg registration "${CNTOOLS_DELEGATE_REGISTER}" --arg deposit "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" \
    --arg fee "${CNTOOLS_WALLET_REGISTER_FEE} Lovelace" '
      (.certificates | type == "array" and length == 1) and
      (.certificates[0] | keys == [$kind]) and
      (.certificates[0][$kind] |
        .["stake credential"] == {($credentialKind):$stake} and
        .delegatee == {"delegatee type":"stake", "key hash":$pool} and
        (if $registration == "Y" then (.deposit | tostring) == $deposit else (has("deposit") | not) end)) and
      .fee == $fee and
      (.withdrawals == null or .withdrawals == []) and .mint == null and .metadata == null and
      (.outputs | length > 0 and all(.[]; .address == $address))
    ' <<< "${view}" >/dev/null || {
      cntools_wallet_register_set_error 'The built transaction does not match the reviewed stake pool delegation.'; return 1;
    }
}

# Preserve the reviewed plan. Never rebuild, substitute a pool, or change the
# registration deposit silently after confirmation or hardware signing.
cntools_delegate_recheck() {
  local current="" unused="" expected=yes ref="" deposit=""
  [[ "${CNTOOLS_DELEGATE_REGISTER}" != Y ]] || expected=no
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  [[ "${CNTOOLS_FUNDING_BACKEND}" == "${CNTOOLS_WALLET_REGISTER_BACKEND}" ]] || {
    cntools_wallet_register_set_error 'The chain-data source changed. Rebuild and review the delegation.'; return 1;
  }
  [[ -z "${CNTOOLS_WALLET_REGISTER_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_WALLET_REGISTER_EXPIRY )) || {
    cntools_wallet_register_set_error 'The delegation expired. Rebuild and review it.'; return 1;
  }
  for ref in "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${ref}]+x}" ]] || {
      cntools_wallet_register_set_error 'A selected input was spent. Rebuild and review the delegation.'; return 1;
    }
  done
  if [[ "${CNTOOLS_DELEGATE_REGISTER}" == Y ]]; then
    cntools_wallet_query_json_uint_field deposit "${CNTOOLS_FUNDING_PROTOCOL}" stakeAddressDeposit || return 1
    [[ "${deposit}" == "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" ]] || {
      cntools_wallet_register_set_error 'The stake registration deposit changed. Rebuild and review the delegation.'; return 1;
    }
  fi
  cntools_wallet_query_reset
  if [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" == local ]]; then
    cntools_wallet_query_network_arguments || return 1
    cntools_wallet_query_local_stake "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" || return 1
  else
    cntools_wallet_query_koios_stake "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" || return 1
  fi
  if [[ -n "${CNTOOLS_WALLET_POOL_DELEGATION}" ]]; then
    cntools_pool_id_into current unused "${CNTOOLS_WALLET_POOL_DELEGATION}" || return 1
  fi
  [[ "${CNTOOLS_WALLET_REGISTERED}" == "${expected}" && "${current}" == "${CNTOOLS_DELEGATE_CURRENT_POOL}" ]] || {
    cntools_wallet_register_set_error 'Stake registration or delegation changed. Rebuild and review the transaction.'; return 1;
  }
  cntools_pool_query "${CNTOOLS_DELEGATE_POOL_ID}" "${CNTOOLS_DELEGATE_POOL_HEX}" "${CNTOOLS_WALLET_REGISTER_BACKEND}" || {
    cntools_wallet_register_set_error 'The target pool is no longer available or could not be verified.'; return 1;
  }
  [[ "${CNTOOLS_POOL_RETIRING}" == "${CNTOOLS_DELEGATE_RETIRING}" ]] || {
    cntools_wallet_register_set_error 'The target pool retirement schedule changed. Rebuild and review the delegation.'; return 1;
  }
}
