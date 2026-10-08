#!/usr/bin/env bash
# Voting delegation, with explicitly approved first stake registration.
# shellcheck disable=SC2034
CNTOOLS_VOTE_TARGET=""
CNTOOLS_VOTE_KIND=""
CNTOOLS_VOTE_HASH=""
CNTOOLS_VOTE_CURRENT=""
CNTOOLS_VOTE_CURRENT_POOL=""
CNTOOLS_VOTE_INACTIVE_CONFIRMED=N
CNTOOLS_VOTE_REGISTER=N
CNTOOLS_VOTE_REGISTRATION_CONFIRMED=N

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
  CNTOOLS_VOTE_REGISTER=N
  case "${CNTOOLS_WALLET_REGISTERED}" in yes) ;; no) CNTOOLS_VOTE_REGISTER=Y ;; *) return 1 ;; esac
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
  local certificate="" output="" errors="" status=0 command=vote-delegation-certificate
  local -a arguments=()
  local -a stake_arguments=()
  [[ "${CNTOOLS_VOTE_TARGET}" != "${CNTOOLS_VOTE_CURRENT}" ]] || return 1
  cntools_vote_target_arguments_into arguments || return 1
  if [[ "${CNTOOLS_VOTE_REGISTER}" == Y ]]; then
    [[ "${CNTOOLS_VOTE_REGISTRATION_CONFIRMED}" == Y ]] || return 1
    command=registration-and-vote-delegation-certificate
    arguments+=(--key-reg-deposit-amt "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")
  else
    [[ "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" == 0 ]] || return 1
  fi
  cntools_transaction_temp_file certificate voting-delegation-certificate || return 1
  cntools_transaction_temp_file output voting-delegation-output || return 1
  cntools_transaction_temp_file errors voting-delegation-errors || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == MultiSig ]]; then cntools_stake_credential_arguments_into stake_arguments || return 1
  else stake_arguments=(--stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}"); fi
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-address "${command}" \
    "${stake_arguments[@]}" \
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
  local view="" drep="" kind='Stake address delegation'
  local credential_kind=keyHash
  [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" != MultiSig ]] || credential_kind=scriptHash
  [[ "${CNTOOLS_VOTE_REGISTER}" != Y ]] || kind='Stake address registration and delegation'
  case "${CNTOOLS_VOTE_KIND}" in
    key) drep="drep-keyHash-${CNTOOLS_VOTE_HASH}" ;;
    script) drep="drep-scriptHash-${CNTOOLS_VOTE_HASH}" ;;
    abstain) drep='drep-alwaysAbstain' ;;
    no-confidence) drep='drep-alwaysNoConfidence' ;;
    *) return 1 ;;
  esac
  cntools_transaction_view_into view "$1" || return 1
  jq -e --arg drep "${drep}" --arg stake "${CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL}" \
    --arg address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" --arg fee "${CNTOOLS_WALLET_REGISTER_FEE} Lovelace" \
    --arg credentialKind "${credential_kind}" \
    --arg kind "${kind}" --arg registration "${CNTOOLS_VOTE_REGISTER}" --arg deposit "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" '
      (.certificates | type == "array" and length == 1) and
      (.certificates[0] | keys == [$kind]) and
      (.certificates[0][$kind] |
        keys == (if $registration == "Y" then ["delegatee","deposit","stake credential"] else ["delegatee","stake credential"] end) and
        .["stake credential"] == {($credentialKind):$stake} and
        .delegatee == {"delegatee type":"vote",DRep:$drep} and
        (if $registration == "Y" then (.deposit | tostring) == $deposit else (has("deposit") | not) end)) and
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
  local current_vote="" ref="" expected=yes deposit=""
  [[ "${CNTOOLS_VOTE_REGISTER}" != Y ]] || expected=no
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
  if [[ "${CNTOOLS_VOTE_REGISTER}" == Y ]]; then
    cntools_wallet_query_json_uint_field deposit "${CNTOOLS_FUNDING_PROTOCOL}" stakeAddressDeposit || return 1
    [[ "${deposit}" == "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" ]] || {
      cntools_wallet_register_set_error 'The stake deposit changed. Rebuild and review the delegation.'; return 1;
    }
  fi
  cntools_wallet_query_reset
  if [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" == local ]]; then
    cntools_wallet_query_network_arguments || return 1
    cntools_wallet_query_local_stake "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" || return 1
  else
    cntools_wallet_query_koios_stake "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" || return 1
  fi
  cntools_vote_current_into current_vote || return 1
  [[ "${CNTOOLS_WALLET_REGISTERED}" == "${expected}" && "${current_vote}" == "${CNTOOLS_VOTE_CURRENT}" &&
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
