#!/usr/bin/env bash
# Explicit self-collection. Reuse Send's verified payment-wallet preparation and
# signer plan, but never use its recipient, metadata or automatic input selection.
# shellcheck disable=SC2034
CNTOOLS_COLLECT_SCOPE=ada
CNTOOLS_COLLECT_FEE=0
CNTOOLS_COLLECT_BACKEND=""
CNTOOLS_COLLECT_SKIPPED=0
CNTOOLS_COLLECT_OUTPUT_COUNT=0
declare -ag CNTOOLS_COLLECT_INPUTS=()

cntools_collect_fail() { cntools_transaction_set_error "${1:-UTxO collection failed.}"; return 1; }

cntools_collect_select() {
  local index=0
  case "${CNTOOLS_COLLECT_SCOPE}" in ada|all) ;; *) return 2 ;; esac
  cntools_coin_reset
  CNTOOLS_COLLECT_SKIPPED=0
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    # Do not consume app data, reference scripts, or unverified destinations.
    if [[ "${CNTOOLS_UTXO_HAS_DATUM[index]}" != N || "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[index]}" != N ]] ||
        [[ "${CNTOOLS_COLLECT_SCOPE}" == ada && "${CNTOOLS_UTXO_ASSET_COUNTS[index]}" != 0 ]]; then
      CNTOOLS_COLLECT_SKIPPED=$((CNTOOLS_COLLECT_SKIPPED + 1)); continue
    fi
    [[ "${CNTOOLS_UTXO_ADDRESSES[index]}" == "${CNTOOLS_SEND_ADDRESS}" ||
       "${CNTOOLS_UTXO_ADDRESSES[index]}" == "${CNTOOLS_SEND_PAYMENT}" ]] || {
      cntools_collect_fail 'The funding inventory contains an address outside this wallet.'; return 1;
    }
    cntools_coin_add_index "${index}" || return 1
    (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} <= 1000 )) || {
      cntools_collect_fail 'More than 1,000 eligible inputs were found. This collection is too large for one transaction; no partial batch was created.'; return 1;
    }
  done
  (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} > 0 )) || {
    cntools_collect_fail 'No eligible UTxOs match this collection. Datum and reference-script outputs are left untouched.'; return 1;
  }
  if (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} == 1 )) &&
      [[ "${CNTOOLS_UTXO_ADDRESSES[CNTOOLS_COIN_SELECTED_INDICES[0]]}" == "${CNTOOLS_SEND_ADDRESS}" &&
         "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-N}" != Y && "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" != Y ]]; then
    cntools_collect_fail 'There is only one eligible UTxO at the return address and no change-shaping policy enabled. Nothing needs collecting.'; return 1
  fi
  CNTOOLS_COLLECT_INPUTS=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  CNTOOLS_COIN_SELECTION_REASON='Explicit collection of all eligible inputs'
}

cntools_collect_plan() {
  local policy="" summary=""
  cntools_send_plan_signers 'Collect UTxOs' \
    "Collect eligible funds within ${CNTOOLS_SEND_WALLET}; rewards, registration and delegation stay unchanged." || return 1
  policy="$(cntools_change_policy_json)" || return 1
  # This is explicit collection, not the automatic transaction funding strategy.
  policy="$(jq -c '.selection="collect-all-eligible"' <<< "${policy}")" || return 1
  summary="$(jq -cn --arg wallet "${CNTOOLS_SEND_WALLET}" --arg scope "${CNTOOLS_COLLECT_SCOPE}" \
    --arg address "${CNTOOLS_SEND_ADDRESS}" --arg source "${CNTOOLS_COLLECT_BACKEND}" \
    --arg total "${CNTOOLS_COIN_SELECTED_LOVELACE}" --arg fee "${CNTOOLS_COLLECT_FEE}" \
    --argjson policy "${policy}" --argjson skipped "${CNTOOLS_COLLECT_SKIPPED}" \
    '{action:"collect-utxos",wallet:$wallet,scope:$scope,returnAddress:$address,dataSource:$source,
      inputLovelace:$total,feeLovelace:$fee,excludedInputCount:$skipped,transactionPolicy:$policy}')" || return 1
  cntools_transaction_plan_set_summary "${summary}" || return 1
  cntools_transaction_log REVIEW "Collection intent summary=${summary}"
}

cntools_collect_validate_body() {
  local view=""
  cntools_transaction_view_into view "$1" || return 1
  jq -e --arg address "${CNTOOLS_SEND_ADDRESS}" --arg fee "${CNTOOLS_COLLECT_FEE} Lovelace" '
    .fee == $fee and
    (.certificates == null or .certificates == []) and
    (.withdrawals == null or .withdrawals == []) and .mint == null and .metadata == null and
    (.outputs | length > 0 and all(.[]; .address == $address))
  ' <<< "${view}" >/dev/null || {
    cntools_collect_fail 'The built transaction does not match the reviewed self-collection.'; return 1;
  }
}

cntools_collect_prepare_balanced_body() {
  local body='' input='' output='' accounted='' value=''
  local -a arguments=()
  cntools_change_plan_stake collect 0 "${CNTOOLS_COLLECT_FEE}" "${CNTOOLS_FUNDING_PROTOCOL}" "${CNTOOLS_SEND_ADDRESS}" || {
    cntools_collect_fail "${CNTOOLS_CHANGE_ERROR:-Insufficient ADA for fees and valid collection outputs.}"; return 1;
  }
  cntools_collect_plan || return 1
  arguments=()
  for input in "${CNTOOLS_COLLECT_INPUTS[@]}"; do
    arguments+=(--tx-in "${input}")
    [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || cntools_multisig_input_arguments arguments || return 1
  done
  accounted="${CNTOOLS_COLLECT_FEE}"
  for output in "${CNTOOLS_CHANGE_OUTPUTS[@]}" "${CNTOOLS_SEND_ADDRESS}+${CNTOOLS_CHANGE_RESIDUAL_LOVELACE}"; do
    cntools_transaction_validate_change_output "${output}" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
    value="${output#*+}"; value="${value%% *}"
    cntools_uint_add_into accounted "${accounted}" "${value}" || return 1
    arguments+=(--tx-out "${output}")
  done
  [[ "${accounted}" == "${CNTOOLS_COIN_SELECTED_LOVELACE}" ]] || {
    cntools_collect_fail 'Collection outputs and fee do not conserve the selected ADA.'; return 1;
  }
  CNTOOLS_COLLECT_OUTPUT_COUNT=$(( ${#CNTOOLS_CHANGE_OUTPUTS[@]} + 1 ))
  cntools_transaction_temp_file body collect-body || return 1
  cntools_transaction_temp_remove "${body}" || return 1
  cntools_transaction_build_body build-raw "${body}" -- "${arguments[@]}" --fee "${CNTOOLS_COLLECT_FEE}" || return 1
  CNTOOLS_TRANSACTION_TEMP_FILES+=("${body}")
  CNTOOLS_TRANSACTION_BALANCE_INPUT_COUNT="${#CNTOOLS_COLLECT_INPUTS[@]}"
  CNTOOLS_TRANSACTION_BALANCE_OUTPUT_COUNT="${CNTOOLS_COLLECT_OUTPUT_COUNT}"
  printf -v "$1" '%s' "${body}"
}

cntools_collect_build_into() {
  local -n collection_result="$1"
  collection_result=""
  cntools_collect_select || return 1
  CNTOOLS_COLLECT_FEE=0
  cntools_transaction_balance_into "$1" CNTOOLS_COLLECT_FEE "${CNTOOLS_FUNDING_PROTOCOL}" \
    cntools_collect_prepare_balanced_body "cntools_collect_validate_body" || return 1
}
cntools_collect_refresh_build_into() {
  local result_name="$1" lifetime="$2"
  [[ "${lifetime}" =~ ^(0|1800|7200|86400)$ ]] || return 2
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  CNTOOLS_COLLECT_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  cntools_transaction_expiry_into CNTOOLS_SEND_EXPIRY "${CNTOOLS_FUNDING_SLOT}" "${lifetime}" || return 1
  cntools_collect_build_into "${result_name}"
}

cntools_collect_recheck() {
  local input=""
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  [[ "${CNTOOLS_FUNDING_BACKEND}" == "${CNTOOLS_COLLECT_BACKEND}" ]] || {
    cntools_collect_fail 'The chain-data source changed. Rebuild and review the collection.'; return 1;
  }
  [[ -z "${CNTOOLS_SEND_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_SEND_EXPIRY )) || {
    cntools_collect_fail 'The collection expired. Rebuild and review it.'; return 1;
  }
  for input in "${CNTOOLS_COLLECT_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${input}]+x}" ]] || {
      cntools_collect_fail 'A selected input is no longer available. Rebuild and review the collection.'; return 1;
    }
  done
}
