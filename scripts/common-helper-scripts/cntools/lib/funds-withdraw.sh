#!/usr/bin/env bash
# Full reward withdrawal to the same key wallet. No certificates or delegation changes.
# shellcheck disable=SC2034

CNTOOLS_WITHDRAW_REWARDS="0"
CNTOOLS_WITHDRAW_FEE="0"
CNTOOLS_WITHDRAW_EXPIRY=""
CNTOOLS_WITHDRAW_BACKEND=""
declare -ag CNTOOLS_WITHDRAW_INPUTS=()

cntools_withdraw_fail() {
  cntools_transaction_set_error "${1:-Reward withdrawal failed.}"
  return 1
}

cntools_withdraw_query_stake() {
  # Reset first: an empty response must not retain an earlier wallet's delegation.
  cntools_wallet_query_reset
  case "${CNTOOLS_WITHDRAW_BACKEND}" in
    local)
      cntools_wallet_query_network_arguments || return 1
      cntools_wallet_query_local_stake "${CNTOOLS_STAKE_REWARD_ADDRESS}" ||
        { cntools_withdraw_fail 'The local node could not verify the reward account.'; return 1; }
      ;;
    koios)
      cntools_wallet_query_koios_stake "${CNTOOLS_STAKE_REWARD_ADDRESS}" ||
        { cntools_withdraw_fail 'Koios could not verify the reward account.'; return 1; }
      ;;
    *) return 2 ;;
  esac
  [[ "${CNTOOLS_WALLET_REGISTERED}" == yes ]] || {
    cntools_withdraw_fail 'The stake address is not registered; there are no registered rewards to withdraw.'; return 1;
  }
  cntools_uint_normalize_into CNTOOLS_WALLET_REWARD_LOVELACE "${CNTOOLS_WALLET_REWARD_LOVELACE}" || {
    cntools_withdraw_fail 'The reward balance could not be determined exactly.'; return 1;
  }
  [[ "${CNTOOLS_WALLET_REWARD_LOVELACE}" != 0 ]] || {
    cntools_withdraw_fail 'There are no claimable rewards to withdraw.'; return 1;
  }
  # Conway protocol 10/11 requires voting delegation after bootstrap. Do not
  # silently add delegation, require an active DRep, or extrapolate to future eras.
  local major=""
  major="$(jq -er '.protocolVersion.major | select(type == "number" and . >= 0 and floor == .)' "${CNTOOLS_FUNDING_PROTOCOL}")" || {
    cntools_withdraw_fail 'The protocol version could not be verified.'; return 1;
  }
  if [[ "${major}" == 10 || "${major}" == 11 ]] && [[ -z "${CNTOOLS_WALLET_DREP_DELEGATION:-}" ]]; then
    cntools_withdraw_fail 'This network requires voting delegation before rewards can be withdrawn. Delegate to a DRep, Always Abstain, or Always No Confidence first. This action will not change delegation.'
    return 1
  fi
}

cntools_withdraw_collect() {
  cntools_funding_collect "${CNTOOLS_STAKE_BASE_ADDRESS}" "${CNTOOLS_STAKE_PAYMENT_ADDRESS}" || return 1
  CNTOOLS_WITHDRAW_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  cntools_withdraw_query_stake || return 1
  CNTOOLS_WITHDRAW_REWARDS="${CNTOOLS_WALLET_REWARD_LOVELACE}"
  cntools_transaction_log TRANSACTION "Withdrawal rewards=${CNTOOLS_WITHDRAW_REWARDS} backend=${CNTOOLS_WITHDRAW_BACKEND} account=${CNTOOLS_STAKE_REWARD_ADDRESS}"
}

cntools_withdraw_select() {
  local reserve="" required="" status=0 attempt=0 index=0
  cntools_coin_fee_reserve_into reserve "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
  cntools_coin_required_for_stake_into required withdraw "${CNTOOLS_WITHDRAW_REWARDS}" "${reserve}" || return 1
  for (( attempt=0; attempt<4; attempt++ )); do
    cntools_coin_select_lovelace "${required}" "${CNTOOLS_TX_SELECTION_STRATEGY}" || {
      cntools_withdraw_fail "${CNTOOLS_COIN_ERROR:-No eligible spending input can fund this withdrawal.}"; return 1;
    }
    # This slice does not price or consume stored reference scripts. Do not
    # silently destroy one or calculate its fee as though its size were zero.
    for index in "${CNTOOLS_COIN_SELECTED_INDICES[@]}"; do
      [[ "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[index]}" == N ]] || {
        cntools_withdraw_fail 'A selected input contains a reference script. Use Balanced selection with sufficient ordinary UTxOs; reference-script spending is not supported for reward withdrawals.'
        return 1
      }
    done
    status=0
    cntools_change_plan_stake withdraw "${CNTOOLS_WITHDRAW_REWARDS}" "${reserve}" \
      "${CNTOOLS_FUNDING_PROTOCOL}" "${CNTOOLS_STAKE_BASE_ADDRESS}" || status=$?
    (( status != 0 )) || return 0
    (( status == 3 )) || break
    cntools_uint_add_into required "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${CNTOOLS_CHANGE_REQUIRED_EXTRA}" || return 1
  done
  cntools_withdraw_fail "${CNTOOLS_CHANGE_ERROR:-Insufficient ADA for fees and valid change.}"
}

cntools_withdraw_plan() {
  local group="" summary="" policy=""
  cntools_transaction_plan_reset 'Withdraw rewards' \
    "Withdraw all claimable rewards for ${CNTOOLS_STAKE_WALLET} to its base address; registration and delegation remain unchanged." exact || return 1
  [[ "${CNTOOLS_STAKE_WALLET_TYPE}" != Hardware ]] || group=withdraw-wallet
  cntools_transaction_plan_add_signer "${CNTOOLS_STAKE_WALLET} payment" spending \
    "${CNTOOLS_STAKE_PAYMENT_VKEY}" "${CNTOOLS_STAKE_PAYMENT_SOURCE}" "${CNTOOLS_STAKE_PAYMENT_CREDENTIAL}" "${group}" || return 1
  cntools_transaction_plan_add_signer "${CNTOOLS_STAKE_WALLET} stake" withdrawal \
    "${CNTOOLS_STAKE_STAKE_VKEY}" "${CNTOOLS_STAKE_STAKE_SOURCE}" "${CNTOOLS_STAKE_STAKE_CREDENTIAL}" "${group}" || return 1
  if [[ -n "${group}" ]]; then
    cntools_transaction_plan_add_change_key 'Payment change' "${CNTOOLS_STAKE_PAYMENT_VKEY}" "${CNTOOLS_STAKE_PAYMENT_SOURCE}" "${group}" || return 1
    cntools_transaction_plan_add_change_key 'Stake change' "${CNTOOLS_STAKE_STAKE_VKEY}" "${CNTOOLS_STAKE_STAKE_SOURCE}" "${group}" || return 1
  fi
  cntools_transaction_plan_set_validity "" "${CNTOOLS_WITHDRAW_EXPIRY}" || return 1
  policy="$(cntools_change_policy_json)" || return 1
  summary="$(jq -cn --arg wallet "${CNTOOLS_STAKE_WALLET}" --arg rewards "${CNTOOLS_WITHDRAW_REWARDS}" \
    --arg address "${CNTOOLS_STAKE_REWARD_ADDRESS}" --arg destination "${CNTOOLS_STAKE_BASE_ADDRESS}" \
    --arg source "${CNTOOLS_WITHDRAW_BACKEND}" --argjson policy "${policy}" \
    '{action:"withdraw-rewards",wallet:$wallet,rewardsLovelace:$rewards,rewardAccount:$address,returnAddress:$destination,dataSource:$source,transactionPolicy:$policy}')" || return 1
  cntools_transaction_plan_set_summary "${summary}" || return 1
  cntools_transaction_log REVIEW "Withdrawal intent summary=${summary}"
}

cntools_withdraw_build_into() {
  local -n withdraw_result="$1"
  local body="" withdraw_package_path="" input="" output="" next_fee="" view_fee=""
  local output_count=0 max_size=0 body_bytes=0 witness_count=0 attempt=0
  local -a arguments=()
  withdraw_result=""
  cntools_withdraw_select || return 1
  CNTOOLS_WITHDRAW_INPUTS=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  CNTOOLS_WITHDRAW_FEE=0
  max_size="$(jq -er '.maxTxSize | select(type == "number" and . > 0 and . <= 100000)' "${CNTOOLS_FUNDING_PROTOCOL}")" || return 1
  # Explicit balancing avoids build-estimate's withdrawal-credit discrepancy.
  # Select once with a conservative fee reserve, then converge the actual fee.
  for (( attempt=0; attempt<20; attempt++ )); do
    cntools_change_plan_stake withdraw "${CNTOOLS_WITHDRAW_REWARDS}" "${CNTOOLS_WITHDRAW_FEE}" \
      "${CNTOOLS_FUNDING_PROTOCOL}" "${CNTOOLS_STAKE_BASE_ADDRESS}" || {
      cntools_withdraw_fail "${CNTOOLS_CHANGE_ERROR:-Could not fund valid withdrawal change.}"; return 1;
    }
    cntools_withdraw_plan || return 1
    arguments=()
    for input in "${CNTOOLS_WITHDRAW_INPUTS[@]}"; do arguments+=(--tx-in "${input}"); done
    for output in "${CNTOOLS_CHANGE_OUTPUTS[@]}"; do
      cntools_withdraw_validate_output "${output}" || return 1
      arguments+=(--tx-out "${output}")
    done
    cntools_withdraw_validate_output "${CNTOOLS_STAKE_BASE_ADDRESS}+${CNTOOLS_CHANGE_RESIDUAL_LOVELACE}" || return 1
    arguments+=(--tx-out "${CNTOOLS_STAKE_BASE_ADDRESS}+${CNTOOLS_CHANGE_RESIDUAL_LOVELACE}"
      --withdrawal "${CNTOOLS_STAKE_REWARD_ADDRESS}+${CNTOOLS_WITHDRAW_REWARDS}")
    output_count=$(("${#CNTOOLS_CHANGE_OUTPUTS[@]}"+1))
    cntools_transaction_temp_file body withdraw-body || return 1
    cntools_transaction_temp_remove "${body}" || return 1
    cntools_transaction_build_body build-raw "${body}" -- "${arguments[@]}" --fee "${CNTOOLS_WITHDRAW_FEE}" || return 1
    CNTOOLS_TRANSACTION_TEMP_FILES+=("${body}")
    cntools_transaction_calculate_min_fee_into next_fee "${body}" "${#CNTOOLS_WITHDRAW_INPUTS[@]}" \
      "${output_count}" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
    if cntools_uint_greater "${next_fee}" "${CNTOOLS_WITHDRAW_FEE}"; then
      CNTOOLS_WITHDRAW_FEE="${next_fee}"; continue
    fi
    cntools_transaction_package_create_staged_into withdraw_package_path "${body}" || return 1
    cntools_transaction_package_load "${withdraw_package_path}" || return 1
    # Hardware preparation can change encoding; recheck the final body's fee.
    cntools_transaction_calculate_min_fee_into next_fee "${CNTOOLS_TRANSACTION_BODY_FILE}" \
      "${#CNTOOLS_WITHDRAW_INPUTS[@]}" "${output_count}" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
    if cntools_uint_greater "${next_fee}" "${CNTOOLS_WITHDRAW_FEE}"; then
      CNTOOLS_WITHDRAW_FEE="${next_fee}"; continue
    fi
    cntools_transaction_view_into CNTOOLS_TRANSACTION_UI_VIEW "${CNTOOLS_TRANSACTION_BODY_FILE}" || return 1
    view_fee="$(jq -er '.fee | capture("^(?<fee>[0-9]+) Lovelace$").fee' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}")" || return 1
    [[ "${view_fee}" == "${CNTOOLS_WITHDRAW_FEE}" ]] || {
      cntools_withdraw_fail 'The final fee does not match the withdrawal plan.'; return 1;
    }
    jq -e --arg stake "${CNTOOLS_STAKE_REWARD_ADDRESS}" --arg amount "${CNTOOLS_WITHDRAW_REWARDS} Lovelace" \
      --arg destination "${CNTOOLS_STAKE_BASE_ADDRESS}" '
      (.withdrawals | length == 1) and .withdrawals[0].address == $stake and
      .withdrawals[0].amount == $amount and
      (.certificates == null or .certificates == []) and
      .mint == null and .metadata == null and
      (.outputs | length > 0 and all(.[]; .address == $destination))
    ' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}" >/dev/null || {
      cntools_withdraw_fail 'The final transaction does not match the reward withdrawal plan.'; return 1;
    }
    body_bytes="$(jq -er '.cborHex | length / 2' "${CNTOOLS_TRANSACTION_BODY_FILE}")" || return 1
    witness_count="$(cntools_transaction_plan_witness_count)" || return 1
    (( body_bytes + witness_count * 112 + 32 <= max_size )) || {
      cntools_withdraw_fail 'The withdrawal would exceed the transaction size limit. Reduce input consolidation or change fragmentation.'; return 1;
    }
    withdraw_result="${withdraw_package_path}"
    cntools_transaction_log TRANSACTION "Withdrawal built rewards=${CNTOOLS_WITHDRAW_REWARDS} fee=${CNTOOLS_WITHDRAW_FEE} inputs=${#CNTOOLS_WITHDRAW_INPUTS[@]} witnesses=${witness_count}"
    return 0
  done
  cntools_withdraw_fail 'Withdrawal fees did not converge safely. Nothing was signed.'
}

cntools_withdraw_validate_output() {
  local output="$1" part="" value_bytes=12 maximum="" minimum="" amount=""
  local -a parts=()
  maximum="$(jq -er '.maxValueSize | select(type == "number" and . > 0 and . <= 100000)' "${CNTOOLS_FUNDING_PROTOCOL}")" || return 1
  read -r -a parts <<< "${output}"
  for part in "${parts[@]}"; do
    if [[ "${part}" =~ ^[0-9a-f]{56}(\.([0-9a-f]{2}){0,32})?$ ]]; then
      value_bytes=$((value_bytes + 52 + (${#part} - 56) / 2))
    fi
  done
  (( value_bytes <= maximum )) || {
    cntools_withdraw_fail 'A token change bundle exceeds the conservative value-size limit. Enable token fragmentation or lower its maximum assets per output.'; return 1;
  }
  cntools_transaction_calculate_min_utxo_into minimum "${CNTOOLS_FUNDING_PROTOCOL}" "${output}" || return 1
  amount="${output#*+}"; amount="${amount%% *}"
  cntools_uint_greater_equal "${amount}" "${minimum}" || {
    cntools_withdraw_fail 'A withdrawal change output does not contain the minimum required ADA.'; return 1;
  }
}

cntools_withdraw_refresh_build_into() {
  local result_name="$1" lifetime="$2"
  [[ "${lifetime}" =~ ^(0|1800|7200|86400)$ ]] || return 2
  cntools_withdraw_collect || return 1
  # All supported deployment networks use one-second Shelley slots.
  cntools_transaction_expiry_into CNTOOLS_WITHDRAW_EXPIRY "${CNTOOLS_FUNDING_SLOT}" "${lifetime}" || return 1
  cntools_withdraw_build_into "${result_name}"
}

cntools_withdraw_recheck() {
  local input="" expected="${CNTOOLS_WITHDRAW_REWARDS}"
  cntools_funding_collect "${CNTOOLS_STAKE_BASE_ADDRESS}" "${CNTOOLS_STAKE_PAYMENT_ADDRESS}" || return 1
  CNTOOLS_WITHDRAW_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  cntools_withdraw_query_stake || return 1
  [[ "${CNTOOLS_WALLET_REWARD_LOVELACE}" == "${expected}" ]] || {
    cntools_withdraw_fail 'The reward balance changed. Rebuild and review the withdrawal; no amount was changed silently.'; return 1;
  }
  [[ -z "${CNTOOLS_WITHDRAW_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_WITHDRAW_EXPIRY )) || {
    cntools_withdraw_fail 'The withdrawal expired. Build and review a new transaction.'; return 1;
  }
  for input in "${CNTOOLS_WITHDRAW_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${input}]+x}" ]] || {
      cntools_withdraw_fail 'A selected input is no longer available. Build and review a new transaction.'; return 1;
    }
  done
}
