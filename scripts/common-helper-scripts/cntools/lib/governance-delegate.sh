#!/usr/bin/env bash
# Voting delegation only: registered key stake credentials, no deposit or pool change.
# shellcheck disable=SC2034
CNTOOLS_VOTE_TARGET=""
CNTOOLS_VOTE_KIND=""
CNTOOLS_VOTE_HASH=""
CNTOOLS_VOTE_CURRENT=""
CNTOOLS_VOTE_CURRENT_POOL=""
CNTOOLS_VOTE_INACTIVE_CONFIRMED=N

cntools_vote_current_into() {
  local result="$1" current="" kind="" hash=""
  [[ "${CNTOOLS_WALLET_DREP_DELEGATION_VALID:-Y}" == Y ]] || {
    cntools_wallet_register_set_error 'The current voting delegation could not be interpreted safely.'; return 1;
  }
  if [[ -n "${CNTOOLS_WALLET_DREP_DELEGATION:-}" ]]; then
    cntools_drep_id_into current kind hash "${CNTOOLS_WALLET_DREP_DELEGATION}" || {
      cntools_wallet_register_set_error 'The current voting delegation ID is invalid.'; return 1;
    }
  fi
  printf -v "${result}" '%s' "${current}"
}

cntools_vote_chain_state_validate() {
  case "${CNTOOLS_WALLET_REGISTERED}" in yes) ;; no) return 7 ;; *) return 1 ;; esac
  cntools_vote_current_into CNTOOLS_VOTE_CURRENT || return 1
  CNTOOLS_VOTE_CURRENT_POOL="${CNTOOLS_WALLET_POOL_DELEGATION:-}"
}

cntools_vote_target_arguments_into() {
  local -n vote_arguments="$1"
  local canonical="" kind="" hash=""
  cntools_drep_id_into canonical kind hash "${CNTOOLS_VOTE_TARGET}" || return 1
  [[ "${canonical}" == "${CNTOOLS_VOTE_TARGET}" && "${kind}" == "${CNTOOLS_VOTE_KIND}" && "${hash}" == "${CNTOOLS_VOTE_HASH}" ]] || return 1
  case "${kind}" in
    key) vote_arguments=(--drep-key-hash "${hash}") ;;
    script) vote_arguments=(--drep-script-hash "${hash}") ;;
    abstain) vote_arguments=(--always-abstain) ;;
    no-confidence) vote_arguments=(--always-no-confidence) ;;
    *) return 1 ;;
  esac
}

cntools_vote_certificate_create() {
  local certificate="" output="" errors="" status=0
  local -a arguments=()
  [[ "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" == 0 && "${CNTOOLS_VOTE_TARGET}" != "${CNTOOLS_VOTE_CURRENT}" ]] || return 1
  cntools_vote_target_arguments_into arguments || return 1
  cntools_transaction_temp_file certificate voting-delegation-certificate || return 1
  cntools_transaction_temp_file output voting-delegation-output || return 1
  cntools_transaction_temp_file errors voting-delegation-errors || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-address vote-delegation-certificate \
    --stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" \
    "${arguments[@]}" --out-file "${certificate}" || status=$?
  if ((status != 0)); then
    cntools_transaction_log_cli_failure 'Voting delegation certificate creation failed' "${status}" "${errors}" "${output}"
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"; return 1
  fi
  cntools_transaction_file_safe "${certificate}" 131072 &&
    jq -e '.cborHex | type == "string" and length > 0 and test("^([0-9a-fA-F]{2})+$")' "${certificate}" >/dev/null || return 1
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE="${certificate}"
}

cntools_vote_validate_body() {
  local view="" drep=""
  case "${CNTOOLS_VOTE_KIND}" in
    key) drep="drep-keyHash-${CNTOOLS_VOTE_HASH}" ;;
    script) drep="drep-scriptHash-${CNTOOLS_VOTE_HASH}" ;;
    abstain) drep='drep-alwaysAbstain' ;;
    no-confidence) drep='drep-alwaysNoConfidence' ;;
    *) return 1 ;;
  esac
  cntools_transaction_view_into view "$1" || return 1
  jq -e --arg drep "${drep}" --arg stake "${CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL}" \
    --arg address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" --arg fee "${CNTOOLS_WALLET_REGISTER_FEE} Lovelace" '
      .certificates == [{"Stake address delegation":{
        "stake credential":{keyHash:$stake},delegatee:{"delegatee type":"vote",DRep:$drep}}}] and
      .fee == $fee and (.withdrawals == null or .withdrawals == []) and .mint == null and .metadata == null and
      (.outputs | length > 0 and all(.[]; .address == $address)) and
      (.voters == null or .voters == {}) and
      (."governance actions" == null or ."governance actions" == []) and
      (.treasuryDonation == null or .treasuryDonation == 0) and .currentTreasuryValue == null
    ' <<< "${view}" >/dev/null || {
      cntools_wallet_register_set_error 'The built transaction does not match the reviewed voting delegation.'; return 1;
    }
}

cntools_vote_recheck() {
  local current_vote="" ref=""
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  [[ "${CNTOOLS_FUNDING_BACKEND}" == "${CNTOOLS_WALLET_REGISTER_BACKEND}" ]] || {
    cntools_wallet_register_set_error 'The chain-data source changed. Rebuild and review the voting delegation.'; return 1;
  }
  [[ -z "${CNTOOLS_WALLET_REGISTER_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_WALLET_REGISTER_EXPIRY )) || {
    cntools_wallet_register_set_error 'The voting delegation expired. Rebuild and review it.'; return 1;
  }
  for ref in "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${ref}]+x}" ]] || {
      cntools_wallet_register_set_error 'A selected input was spent. Rebuild and review the voting delegation.'; return 1;
    }
  done
  cntools_wallet_query_reset
  if [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" == local ]]; then
    cntools_wallet_query_network_arguments || return 1
    cntools_wallet_query_local_stake "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" || return 1
  else
    cntools_wallet_query_koios_stake "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" || return 1
  fi
  cntools_vote_current_into current_vote || return 1
  [[ "${CNTOOLS_WALLET_REGISTERED}" == yes && "${current_vote}" == "${CNTOOLS_VOTE_CURRENT}" &&
     "${CNTOOLS_WALLET_POOL_DELEGATION:-}" == "${CNTOOLS_VOTE_CURRENT_POOL}" ]] || {
    cntools_wallet_register_set_error 'Stake registration or delegation changed. Rebuild and review the transaction.'; return 1;
  }
  cntools_drep_query "${CNTOOLS_VOTE_TARGET}" "${CNTOOLS_VOTE_KIND}" "${CNTOOLS_VOTE_HASH}" "${CNTOOLS_WALLET_REGISTER_BACKEND}" || {
    cntools_wallet_register_set_error 'The target DRep is no longer registered or could not be verified.'; return 1;
  }
  [[ "${CNTOOLS_DREP_ACTIVE}" != false || "${CNTOOLS_VOTE_INACTIVE_CONFIRMED}" == Y ]] || {
    cntools_wallet_register_set_error 'The target DRep is now inactive. Rebuild and review the delegation.'; return 1;
  }
}
