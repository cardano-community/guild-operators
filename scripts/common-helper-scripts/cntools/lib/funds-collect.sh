#!/usr/bin/env bash
# Explicit self-collection. Reuse Send's verified payment-wallet preparation and
# signer plan, but never use its recipient, metadata or automatic input selection.
# shellcheck disable=SC2034
CNTOOLS_COLLECT_SCOPE=ada
CNTOOLS_COLLECT_FEE=0
CNTOOLS_COLLECT_BACKEND=""
CNTOOLS_COLLECT_SKIPPED=0 CNTOOLS_COLLECT_SKIPPED_TOKENS=0 CNTOOLS_COLLECT_SKIPPED_SCRIPTS=0
CNTOOLS_COLLECT_OUTPUT_COUNT=0
CNTOOLS_COLLECT_NOTHING_REASON=""
# One transaction collects at most a batch of the eligible UTxOs; the batch
# shrinks when the signed transaction would exceed the protocol size limit.
CNTOOLS_COLLECT_BATCH_MAX=300
CNTOOLS_COLLECT_BATCH="${CNTOOLS_COLLECT_BATCH_MAX}"
CNTOOLS_COLLECT_ELIGIBLE=0
declare -ag CNTOOLS_COLLECT_INPUTS=() CNTOOLS_COLLECT_SCOPES=()
declare -Ag CNTOOLS_COLLECT_SCOPE_COUNTS=()

cntools_collect_fail() { cntools_transaction_set_error "${1:-UTxO collection failed.}"; return 1; }

# Selects up to CNTOOLS_COLLECT_BATCH of the eligible UTxOs (all counted in
# CNTOOLS_COLLECT_ELIGIBLE); a wallet with more is collected in several runs.
cntools_collect_select() {
  local index=0
  case "${CNTOOLS_COLLECT_SCOPE}" in ada|all) ;; *) return 2 ;; esac
  cntools_coin_reset
  CNTOOLS_COLLECT_SKIPPED=0 CNTOOLS_COLLECT_SKIPPED_TOKENS=0 CNTOOLS_COLLECT_SKIPPED_SCRIPTS=0 CNTOOLS_COLLECT_ELIGIBLE=0
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    # Do not consume app data, reference scripts, or unverified destinations.
    if [[ "${CNTOOLS_UTXO_HAS_DATUM[index]}" != N || "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[index]}" != N ]]; then
      CNTOOLS_COLLECT_SKIPPED_SCRIPTS=$((CNTOOLS_COLLECT_SKIPPED_SCRIPTS + 1))
      CNTOOLS_COLLECT_SKIPPED=$((CNTOOLS_COLLECT_SKIPPED + 1)); continue
    elif [[ "${CNTOOLS_COLLECT_SCOPE}" == ada && "${CNTOOLS_UTXO_ASSET_COUNTS[index]}" != 0 ]]; then
      CNTOOLS_COLLECT_SKIPPED_TOKENS=$((CNTOOLS_COLLECT_SKIPPED_TOKENS + 1))
      CNTOOLS_COLLECT_SKIPPED=$((CNTOOLS_COLLECT_SKIPPED + 1)); continue
    fi
    [[ "${CNTOOLS_UTXO_ADDRESSES[index]}" == "${CNTOOLS_SEND_ADDRESS}" ||
       "${CNTOOLS_UTXO_ADDRESSES[index]}" == "${CNTOOLS_SEND_PAYMENT}" ]] || {
      cntools_collect_fail 'The funding inventory contains an address outside this wallet.'; return 1;
    }
    CNTOOLS_COLLECT_ELIGIBLE=$((CNTOOLS_COLLECT_ELIGIBLE + 1))
    (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} < CNTOOLS_COLLECT_BATCH )) || continue
    cntools_coin_add_index "${index}" || return 1
  done
  (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} > 0 )) || {
    cntools_collect_fail "Nothing to collect: ${CNTOOLS_SEND_WALLET} has no eligible UTxOs. Datum and reference-script UTxOs are left untouched."; return 1;
  }
  # Token fragmentation can only reshape a UTxO with more assets than one
  # output may hold.
  if (( CNTOOLS_COLLECT_ELIGIBLE == 1 )) &&
      [[ "${CNTOOLS_UTXO_ADDRESSES[CNTOOLS_COIN_SELECTED_INDICES[0]]}" == "${CNTOOLS_SEND_ADDRESS}" &&
         "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" != Y ]] &&
      { [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-N}" != Y ]] ||
        (( CNTOOLS_COIN_SELECTED_ASSET_COUNT <= ${CNTOOLS_TX_TOKEN_MAX_ASSETS:-20} )); }; then
    cntools_collect_fail "Nothing to collect: ${CNTOOLS_SEND_WALLET} has one eligible UTxO, already at its return address, and no change setting would reshape it."; return 1
  fi
  CNTOOLS_COLLECT_INPUTS=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  CNTOOLS_COIN_SELECTION_REASON='Explicit collection of all eligible inputs'
  (( CNTOOLS_COLLECT_ELIGIBLE == ${#CNTOOLS_COLLECT_INPUTS[@]} )) ||
    CNTOOLS_COIN_SELECTION_REASON="Explicit collection of ${#CNTOOLS_COLLECT_INPUTS[@]} of ${CNTOOLS_COLLECT_ELIGIBLE} eligible inputs (one transaction's limit)"
}

# Run in a subshell: prints the eligible count, or the reason and fails.
cntools_collect_try_scope() {
  CNTOOLS_COLLECT_SCOPE="$1"
  cntools_collect_select >/dev/null 2>&1 || { printf '%s' "${CNTOOLS_TRANSACTION_ERROR:-}"; return 1; }
  printf '%s' "${CNTOOLS_COLLECT_ELIGIBLE}"
}

# Scopes that have something to collect, tried in subshells so the current
# selection is untouched, with their eligible counts for the scope menu.
# Equal counts offer only the ADA-only scope.
cntools_collect_scopes_into() {
  local -n collect_scopes_ref="$1"
  local -n collect_reason_ref="$2"
  local scope='' result='' previous=''
  collect_scopes_ref=(); collect_reason_ref=''; CNTOOLS_COLLECT_SCOPE_COUNTS=()
  for scope in ada all; do
    if result="$(cntools_collect_try_scope "${scope}")"; then
      if [[ "${result}" != "${previous}" ]]; then
        collect_scopes_ref+=("${scope}"); CNTOOLS_COLLECT_SCOPE_COUNTS["${scope}"]="${result}"
      fi
      previous="${result}"
    else
      collect_reason_ref="${result}"
    fi
  done
  cntools_transaction_log TRANSACTION "Collection scopes available=${collect_scopes_ref[*]:-none}"
}

# Funds and scopes are checked before any question is asked. An empty
# wallet is an outcome like any other with nothing to collect.
cntools_collect_check() {
  CNTOOLS_COLLECT_SCOPES=(); CNTOOLS_COLLECT_NOTHING_REASON=''
  if ! cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}"; then
    [[ "${CNTOOLS_FUNDING_EMPTY:-N}" == Y ]] || return 1
    CNTOOLS_COLLECT_NOTHING_REASON="Nothing to collect: ${CNTOOLS_SEND_WALLET} has no UTxOs."
    cntools_transaction_log TRANSACTION 'Collection scopes available=none (no UTxOs)'
    return 0
  fi
  CNTOOLS_COLLECT_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  cntools_collect_scopes_into CNTOOLS_COLLECT_SCOPES CNTOOLS_COLLECT_NOTHING_REASON
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

# A batch too large for one signed transaction is retried with fewer inputs.
cntools_collect_build_into() {
  local -n collection_result="$1"
  collection_result=""
  while true; do
    cntools_collect_select || return 1
    CNTOOLS_COLLECT_FEE=0
    cntools_transaction_balance_into "$1" CNTOOLS_COLLECT_FEE "${CNTOOLS_FUNDING_PROTOCOL}" \
      cntools_collect_prepare_balanced_body "cntools_collect_validate_body" && return 0
    [[ "${CNTOOLS_TRANSACTION_BALANCE_OVERSIZE:-N}" == Y && ${#CNTOOLS_COLLECT_INPUTS[@]} -gt 2 ]] || return 1
    CNTOOLS_COLLECT_BATCH=$(( ${#CNTOOLS_COLLECT_INPUTS[@]} * 2 / 3 ))
    cntools_transaction_log TRANSACTION "Collection batch too large for one transaction; retrying with ${CNTOOLS_COLLECT_BATCH} inputs"
  done
}
cntools_collect_refresh_build_into() {
  [[ "$2" =~ ^(0|[1-9][0-9]{0,7})$ ]] && (( $2 <= 31536000 )) || return 2
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  CNTOOLS_COLLECT_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  cntools_collect_current_build_into "$@"
}

# Build from the funds already checked. Quick uses it only when nothing was
# asked since the check; after any question the caller refreshes first.
cntools_collect_current_build_into() {
  local result_name="$1" lifetime="$2"
  [[ "${lifetime}" =~ ^(0|[1-9][0-9]{0,7})$ ]] && (( lifetime <= 31536000 )) || return 2
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
