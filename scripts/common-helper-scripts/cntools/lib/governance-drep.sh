#!/usr/bin/env bash
# Key-DRep lifecycle. Reuse coin selection, change balancing and package signing.
# shellcheck disable=SC2034,SC2015 # Chained validation failures share one error.
CNTOOLS_DREP_LIFECYCLE_ID=""
CNTOOLS_DREP_LIFECYCLE_HASH=""
CNTOOLS_DREP_LIFECYCLE_VKEY=""
CNTOOLS_DREP_LIFECYCLE_SOURCE=""
CNTOOLS_DREP_LIFECYCLE_STATE='{}'
CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL=""
CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=""

cntools_drep_lifecycle_operation_set() {
  local operation="$1" noun="" command="" label="Deposit" effect=charged
  case "${operation}" in
    drep-register) noun=registration; command=registration-certificate ;;
    drep-update) noun=update; command=update-certificate ;;
    drep-retire) noun=retirement; command=retirement-certificate; label='Deposit refund'; effect=refunded ;;
    *) return 2 ;;
  esac
  CNTOOLS_WALLET_REGISTER_OPERATION="${operation}"
  CNTOOLS_WALLET_REGISTER_TITLE='DRep Registration / Update'
  [[ "${operation}" != drep-retire ]] || CNTOOLS_WALLET_REGISTER_TITLE='DRep Retire'
  CNTOOLS_WALLET_REGISTER_PATH="/ Vote / Governance / ${CNTOOLS_WALLET_REGISTER_TITLE}"
  CNTOOLS_WALLET_REGISTER_NOUN="DRep ${noun}"
  CNTOOLS_WALLET_REGISTER_VERB="perform DRep ${noun}"
  CNTOOLS_WALLET_REGISTER_PAST="${noun}"
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_COMMAND="${command}"
  CNTOOLS_WALLET_REGISTER_INTENT="DRep ${noun}"
  CNTOOLS_WALLET_REGISTER_SUMMARY_ACTION="${operation}"
  CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL="${label}"
  CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT="${effect}"
  CNTOOLS_WALLET_REGISTER_FILE_SUFFIX="${operation}"
}

cntools_drep_lifecycle_prepare_wallet() {
  local directory="$1" source="" kind=""
  cntools_payment_prepare_wallet "${directory}" || return 1
  cntools_drep_key_inspect "${directory}" || {
    cntools_wallet_register_set_error "${CNTOOLS_DREP_KEY_ERROR:-This wallet needs DRep keys. Use Vote → Governance → Derive Keys first.}"; return 1;
  }
  [[ "${CNTOOLS_DREP_KEY_VERIFIED}" == Y && "${CNTOOLS_DREP_KEY_KIND}" == key ]] || {
    cntools_wallet_register_set_error 'The DRep verification key must be available and verified. Script DReps are not supported by this action.'; return 1;
  }
  CNTOOLS_DREP_LIFECYCLE_ID="${CNTOOLS_DREP_KEY_ID}"
  CNTOOLS_DREP_LIFECYCLE_HASH="${CNTOOLS_DREP_KEY_HASH}"
  CNTOOLS_DREP_LIFECYCLE_VKEY="${directory}/${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}"
  CNTOOLS_DREP_LIFECYCLE_SOURCE=""
  source="${directory}/${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}"
  [[ ! -e "${directory}/${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" ]] || source="${directory}/${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}"
  if cntools_transaction_source_kind_into kind "${source}" && [[ "${kind}" == cli || "${kind}" == hardware ]]; then
    CNTOOLS_DREP_LIFECYCLE_SOURCE="${source}"
  fi
  CNTOOLS_WALLET_REGISTER_WALLET="${2:-${directory##*/}}"
  CNTOOLS_WALLET_REGISTER_DIRECTORY="${directory}"
  CNTOOLS_WALLET_REGISTER_WALLET_TYPE="${CNTOOLS_PAYMENT_TYPE}"
  CNTOOLS_WALLET_REGISTER_BASE_ADDRESS="${CNTOOLS_PAYMENT_ADDRESS}"
  CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS="${CNTOOLS_PAYMENT_PAYMENT}"
  CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS=""
  CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY="${CNTOOLS_PAYMENT_VKEY}"
  CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${CNTOOLS_PAYMENT_SOURCE}"
  CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL="${CNTOOLS_PAYMENT_CREDENTIAL}"
  CNTOOLS_WALLET_REGISTER_CAN_SIGN=N
  if [[ -n "${CNTOOLS_PAYMENT_SOURCE}" && -n "${CNTOOLS_DREP_LIFECYCLE_SOURCE}" ]]; then CNTOOLS_WALLET_REGISTER_CAN_SIGN=Y; fi
  if [[ "${CNTOOLS_PAYMENT_TYPE}" == Hardware && -z "${CNTOOLS_PAYMENT_SOURCE}" ]]; then
    cntools_wallet_register_set_error 'A hardware funding wallet needs its payment HWS file to prepare change safely.'; return 1;
  fi
}

# Only registration, deposit and anchor affect this lifecycle decision. Activity
# and expiry may advance between queries without changing the reviewed action.
cntools_drep_lifecycle_state_into() {
  local -n drep_state_result="$1"
  if [[ "${CNTOOLS_DREP_STATUS}" == not_registered || "${CNTOOLS_DREP_STATUS}" == deregistered ]]; then
    drep_state_result='{"registered":false}'
    return 0
  fi
  [[ "${CNTOOLS_DREP_STATUS}" == registered ]] || return 1
  drep_state_result="$(jq -cer '
    def uint: if type == "string" then test("^(0|[1-9][0-9]{0,16})$")
      elif type == "number" then . >= 0 and . <= 9007199254740991 and floor == . else false end;
    select(.deposit | uint) | select(
      ((.meta_url == null and .meta_hash == null) or
       (.meta_url | type == "string" and length > 0) and
       (.meta_hash | type == "string" and test("^[0-9a-fA-F]{64}$")))) |
    {registered:true,deposit:(.deposit|tostring),url:.meta_url,hash:(.meta_hash | if . == null then . else ascii_downcase end)}
  ' <<< "${CNTOOLS_DREP_DETAILS}")" || return 1
  local deposit=""
  deposit="$(jq -r .deposit <<< "${drep_state_result}")" || return 1
  cntools_uint_greater_equal 45000000000000000 "${deposit}"
}

cntools_drep_lifecycle_query_state_into() {
  local output="$1" status=0
  cntools_drep_query "${CNTOOLS_DREP_LIFECYCLE_ID}" key "${CNTOOLS_DREP_LIFECYCLE_HASH}" \
    "${CNTOOLS_WALLET_REGISTER_BACKEND}" || status=$?
  if ((status != 0 && status != 4)); then
    cntools_wallet_register_set_error 'DRep registration could not be verified. A failed query is not evidence of an unregistered DRep.'; return 1
  fi
  cntools_drep_lifecycle_state_into "${output}" || {
    cntools_wallet_register_set_error 'The DRep deposit or metadata anchor could not be interpreted safely.'; return 1;
  }
}

cntools_drep_lifecycle_collect() {
  local registered="" deposit=0
  cntools_wallet_register_reset_chain_state
  CNTOOLS_DREP_LIFECYCLE_STATE='{}'
  CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL="" CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH=""
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  CNTOOLS_WALLET_REGISTER_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${CNTOOLS_FUNDING_PROTOCOL}"
  CNTOOLS_WALLET_REGISTER_SOURCE="${CNTOOLS_FUNDING_BACKEND}"
  cntools_drep_lifecycle_query_state_into CNTOOLS_DREP_LIFECYCLE_STATE || return 1
  registered="$(jq -r .registered <<< "${CNTOOLS_DREP_LIFECYCLE_STATE}")" || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-retire ]]; then
    [[ "${registered}" == true ]] || {
      cntools_wallet_register_set_error 'This DRep is not registered on this network. There is no deposit to refund.'; return 7;
    }
    deposit="$(jq -r .deposit <<< "${CNTOOLS_DREP_LIFECYCLE_STATE}")" || return 1
  elif [[ "${registered}" == true ]]; then
    cntools_drep_lifecycle_operation_set drep-update || return 1
  else
    cntools_drep_lifecycle_operation_set drep-register || return 1
    cntools_wallet_query_json_uint_field deposit "${CNTOOLS_FUNDING_PROTOCOL}" dRepDeposit &&
      cntools_uint_greater_equal 45000000000000000 "${deposit}" || {
        cntools_wallet_register_set_error 'Protocol parameters do not contain a safe, exact DRep deposit.'; return 1;
      }
  fi
  CNTOOLS_WALLET_REGISTER_DEPOSIT="${deposit}"
  cntools_wallet_register_inventory_use_all || return 1
  cntools_wallet_register_select_inputs
}

cntools_drep_lifecycle_anchor_valid() {
  local url="${1:-}" hash="${2:-}" LC_ALL=C
  [[ -z "${url}" && -z "${hash}" ]] && return 0
  [[ "${url}" =~ ^(https?://|ipfs://)[^[:space:][:cntrl:]]+$ && ${#url} -le 128 && "${hash}" =~ ^[0-9a-f]{64}$ ]]
}

cntools_drep_lifecycle_hash_file_into() {
  local target="$1" file="$2" output="" errors="" status=0 computed=""
  cntools_transaction_file_safe "${file}" 4194304 && jq -se 'length == 1 and (.[0] | type == "object")' "${file}" >/dev/null || {
    cntools_wallet_register_set_error 'Choose a readable JSON metadata object (at most 4 MiB), not a symlink.'; return 1;
  }
  cntools_transaction_temp_file output drep-anchor-hash || return 1
  cntools_transaction_temp_file errors drep-anchor-errors || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest governance drep metadata-hash \
    --drep-metadata-file "${file}" || status=$?
  if ((status != 0)); then
    cntools_transaction_log_cli_failure 'DRep metadata hashing failed' "${status}" "${errors}" "${output}"; return 1
  fi
  computed="$(< "${output}")"
  [[ "${computed}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf -v "${target}" '%s' "${computed}"
}

cntools_drep_lifecycle_certificate_create() {
  local certificate="" output="" errors="" status=0
  local -a arguments=(--drep-verification-key-file "${CNTOOLS_DREP_LIFECYCLE_VKEY}")
  cntools_drep_lifecycle_anchor_valid "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" || return 1
  case "${CNTOOLS_WALLET_REGISTER_OPERATION}" in
    drep-register) arguments+=(--key-reg-deposit-amt "${CNTOOLS_WALLET_REGISTER_DEPOSIT}") ;;
    drep-update) [[ "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" == 0 ]] || return 1 ;;
    drep-retire) arguments+=(--deposit-amt "${CNTOOLS_WALLET_REGISTER_DEPOSIT}") ;;
    *) return 2 ;;
  esac
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-retire && -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
    arguments+=(--drep-metadata-url "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" --drep-metadata-hash "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}")
  fi
  cntools_transaction_temp_file certificate drep-certificate || return 1
  cntools_transaction_temp_file output drep-certificate-output || return 1
  cntools_transaction_temp_file errors drep-certificate-errors || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest governance drep \
    "${CNTOOLS_WALLET_REGISTER_CERTIFICATE_COMMAND}" "${arguments[@]}" --out-file "${certificate}" || status=$?
  if ((status != 0)); then
    cntools_transaction_log_cli_failure 'DRep certificate creation failed' "${status}" "${errors}" "${output}"
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"; return 1
  fi
  cntools_transaction_file_safe "${certificate}" 131072 &&
    jq -e '.cborHex | type == "string" and length > 0 and test("^([0-9a-fA-F]{2})+$")' "${certificate}" >/dev/null || return 1
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE="${certificate}"
}

cntools_drep_lifecycle_plan_create() {
  local payment_group="" drep_group="" kind="" summary="" inputs="[]" policy="${CNTOOLS_WALLET_REGISTER_POLICY_JSON}" stake_source=""
  cntools_transaction_plan_reset "${CNTOOLS_WALLET_REGISTER_INTENT}" \
    "${CNTOOLS_WALLET_REGISTER_INTENT} for ${CNTOOLS_DREP_LIFECYCLE_ID}; return change to the selected wallet." exact || return 1
  cntools_transaction_plan_set_validity '' "${CNTOOLS_WALLET_REGISTER_EXPIRY}" || return 1
  [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" != Hardware ]] || payment_group=wallet-drep
  if [[ -n "${CNTOOLS_DREP_LIFECYCLE_SOURCE}" ]]; then
    cntools_transaction_source_kind_into kind "${CNTOOLS_DREP_LIFECYCLE_SOURCE}" || return 1
    [[ "${kind}" != hardware ]] || drep_group=wallet-drep
  fi
  cntools_transaction_plan_add_signer "${CNTOOLS_WALLET_REGISTER_WALLET} payment key" spending \
    "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" \
    "${CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL}" "${payment_group}" || return 1
  cntools_transaction_plan_add_signer "${CNTOOLS_WALLET_REGISTER_WALLET} DRep key" "${1:-certificate}" \
    "${CNTOOLS_DREP_LIFECYCLE_VKEY}" "${CNTOOLS_DREP_LIFECYCLE_SOURCE}" "${CNTOOLS_DREP_LIFECYCLE_HASH}" "${drep_group}" || return 1
  if [[ -n "${payment_group}" ]]; then
    cntools_transaction_plan_add_change_key "${CNTOOLS_WALLET_REGISTER_WALLET} payment key" \
      "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" "${payment_group}" || return 1
    if [[ "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" != "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" ]]; then
      stake_source="${CNTOOLS_WALLET_REGISTER_DIRECTORY}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
      cntools_transaction_plan_add_change_key "${CNTOOLS_WALLET_REGISTER_WALLET} stake change reference" \
        "${CNTOOLS_WALLET_REGISTER_DIRECTORY}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" "${stake_source}" "${payment_group}" || return 1
    fi
  fi
  inputs="$(printf '%s\n' "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  summary="$(jq -cn --arg action "${CNTOOLS_WALLET_REGISTER_OPERATION}" --arg wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" \
    --arg drepId "${CNTOOLS_DREP_LIFECYCLE_ID}" --arg drepHash "${CNTOOLS_DREP_LIFECYCLE_HASH}" \
    --arg deposit "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" --arg effect "${CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT}" \
    --arg url "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" --arg hash "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" \
    --arg changeAddress "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" --arg source "${CNTOOLS_WALLET_REGISTER_BACKEND}" \
    --arg fee "${CNTOOLS_WALLET_REGISTER_FEE}" --argjson inputs "${inputs}" --argjson policy "${policy}" \
    --argjson previous "${CNTOOLS_DREP_LIFECYCLE_STATE}" '
    {action:$action,wallet:$wallet,drepId:$drepId,drepHash:$drepHash,depositLovelace:$deposit,depositEffect:$effect,
     metadataAnchor:(if $url == "" then null else {url:$url,dataHash:$hash} end),previousDrepState:$previous,
     changeAddress:$changeAddress,dataSource:$source,feeLovelace:$fee,selectedInputs:$inputs,transactionPolicy:$policy}')" || return 1
  cntools_transaction_plan_set_summary "${summary}"
}

# These are the pinned CLI's authoritative decoded certificate fields (including
# the trailing space in its update anchor key). Never rely on intent JSON alone.
cntools_drep_lifecycle_validate_body() {
  local view="" kind="" credential=certificate amount=deposit anchor=anchor expected="null" inputs="[]"
  case "${CNTOOLS_WALLET_REGISTER_OPERATION}" in
    drep-register) kind='Drep registration certificate' ;;
    drep-update) kind='Drep certificate update'; credential='Drep credential'; amount=''; anchor='anchor ' ;;
    drep-retire) kind='Drep unregistration certificate'; amount=refund; anchor='' ;;
    *) return 2 ;;
  esac
  if [[ -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" && "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-retire ]]; then
    expected="$(jq -cn --arg url "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" --arg hash "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" '{url:$url,dataHash:$hash}')" || return 1
  fi
  cntools_transaction_view_into view "$1" || return 1
  inputs="$(printf '%s\n' "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')" || return 1
  jq -e --arg kind "${kind}" --arg credential "${credential}" --arg hash "${CNTOOLS_DREP_LIFECYCLE_HASH}" \
    --arg amount "${amount}" --arg deposit "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" --arg anchor "${anchor}" --argjson expected "${expected}" \
    --arg address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" --arg fee "${CNTOOLS_WALLET_REGISTER_FEE} Lovelace" \
    --argjson inputs "${inputs}" --arg expiry "${CNTOOLS_WALLET_REGISTER_EXPIRY}" '
    (.certificates | type == "array" and length == 1) and
    (.certificates[0] | keys == [$kind]) and
    (.certificates[0][$kind] | .[$credential] == {keyHash:$hash} and
      (if $amount == "" then true else (.[$amount]|tostring) == $deposit end) and
      (if $anchor == "" then true else .[$anchor] == $expected end)) and
    (.inputs | sort) == $inputs and
    (."validity range"["upper bound"] | if . == null then "" else tostring end) == $expiry and
    ."validity range"["lower bound"] == null and
    (."collateral inputs" == null or ."collateral inputs" == []) and
    (."reference inputs" == null or ."reference inputs" == []) and
    .fee == $fee and (.withdrawals == null or .withdrawals == []) and .mint == null and .metadata == null and
    (.outputs | length > 0 and all(.[]; .address == $address)) and
    (.voters == null or .voters == {}) and (."governance actions" == null or ."governance actions" == []) and
    (.treasuryDonation == null or .treasuryDonation == 0) and .currentTreasuryValue == null
  ' <<< "${view}" >/dev/null || {
    cntools_wallet_register_set_error 'The built transaction does not match the reviewed DRep certificate, deposit, metadata or change address.'; return 1;
  }
}

cntools_drep_lifecycle_recheck() {
  local state="" reference="" deposit=""
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  [[ "${CNTOOLS_FUNDING_BACKEND}" == "${CNTOOLS_WALLET_REGISTER_BACKEND}" ]] || {
    cntools_wallet_register_set_error 'The chain-data source changed. Rebuild and review the DRep transaction.'; return 1;
  }
  [[ -z "${CNTOOLS_WALLET_REGISTER_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_WALLET_REGISTER_EXPIRY )) || {
    cntools_wallet_register_set_error 'The DRep transaction expired. Rebuild and review it.'; return 1;
  }
  for reference in "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${reference}]+x}" ]] || {
      cntools_wallet_register_set_error 'A selected input was spent. Rebuild and review the DRep transaction.'; return 1;
    }
  done
  cntools_drep_lifecycle_query_state_into state || return 1
  [[ "${state}" == "${CNTOOLS_DREP_LIFECYCLE_STATE}" ]] || {
    cntools_wallet_register_set_error 'DRep registration, deposit or metadata changed. Rebuild and review the transaction.'; return 1;
  }
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-register ]]; then
    cntools_wallet_query_json_uint_field deposit "${CNTOOLS_FUNDING_PROTOCOL}" dRepDeposit &&
      [[ "${deposit}" == "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" ]] || {
        cntools_wallet_register_set_error 'The current DRep deposit changed. Rebuild and review the registration.'; return 1;
      }
  fi
}
