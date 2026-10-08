#!/usr/bin/env bash
# Pool certificates on the shared exact-fee, lossless change and signing foundation.
# shellcheck disable=SC2034,SC2015
CNTOOLS_POOL_REG_INDEX=0
CNTOOLS_POOL_REG_NAME=''
CNTOOLS_POOL_REG_ID=''
CNTOOLS_POOL_REG_HEX=''
CNTOOLS_POOL_REG_COLD_VKEY=''
CNTOOLS_POOL_REG_COLD_SOURCE=''
CNTOOLS_POOL_REG_VRF_VKEY=''
CNTOOLS_POOL_REG_VRF_HASH=''
CNTOOLS_POOL_REG_STATE='{}'
CNTOOLS_POOL_REG_MIN_COST=0
CNTOOLS_POOL_REG_PROTOCOL_STATE=''
CNTOOLS_POOL_REG_COMBINE_HARDWARE=N

cntools_pool_registration_operation_set() {
  case "$1" in pool-register) CNTOOLS_WALLET_REGISTER_TITLE=Register ;; pool-modify) CNTOOLS_WALLET_REGISTER_TITLE=Modify ;; *) return 2 ;; esac
  CNTOOLS_WALLET_REGISTER_OPERATION="$1"
  CNTOOLS_WALLET_REGISTER_PATH="/ Pool / ${CNTOOLS_WALLET_REGISTER_TITLE}"
  CNTOOLS_WALLET_REGISTER_NOUN="pool ${CNTOOLS_WALLET_REGISTER_TITLE,,}"
  CNTOOLS_WALLET_REGISTER_INTENT="Pool ${CNTOOLS_WALLET_REGISTER_TITLE,,}"
  CNTOOLS_WALLET_REGISTER_FILE_SUFFIX="$1"
  CNTOOLS_WALLET_REGISTER_DEPOSIT_EFFECT=charged
  CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL='Pool deposit'
}

cntools_pool_registration_prepare_identity() {
  local index="$1" directory="${CNTOOLS_POOL_DIRECTORIES[$1]}" cold='' vrf='' hws='' skey='' response='' errors='' status=0 kind=''
  [[ "${CNTOOLS_POOL_IDENTITIES[index]}" == 'Verified cold public key' ]] &&
    cntools_transaction_directory_ancestry_safe "${directory}" || {
    cntools_wallet_register_set_error 'A safe, verified cold public key is required. Import/repair the public pool artifacts first.'; return 1;
  }
  CNTOOLS_POOL_REG_INDEX="${index}"; CNTOOLS_POOL_REG_NAME="${CNTOOLS_POOL_NAMES[index]}"
  CNTOOLS_POOL_REG_ID="${CNTOOLS_POOL_IDS[index]}"; CNTOOLS_POOL_REG_HEX="${CNTOOLS_POOL_HEX_IDS[index]}"
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into vrf vrf-vkey
  cntools_pool_file_name_into skey cold-skey; cntools_pool_file_name_into hws cold-hardware
  cntools_pool_key_validate "${directory}/${cold}" cold verification &&
    cntools_pool_key_validate "${directory}/${vrf}" vrf verification || {
    cntools_wallet_register_set_error 'The pool requires valid cold and VRF public keys.'; return 1;
  }
  cntools_transaction_snapshot_into CNTOOLS_POOL_REG_COLD_VKEY "${directory}/${cold}" 65536 pool-cold-public || return 1
  cntools_transaction_snapshot_into CNTOOLS_POOL_REG_VRF_VKEY "${directory}/${vrf}" 65536 pool-vrf-public || return 1
  CNTOOLS_POOL_REG_COLD_SOURCE=''
  if [[ -e "${directory}/${hws}" ]]; then
    [[ ! -e "${directory}/${skey}" && ! -e "${directory}/${skey}.gpg" ]] && cntools_pool_hardware_pair_validate "${directory}" || {
      cntools_wallet_register_set_error 'Mixed or invalid pool cold signing material.'; return 1;
    }
    cntools_transaction_source_kind_into kind "${directory}/${hws}" || return 1
    CNTOOLS_POOL_REG_COLD_SOURCE="${directory}/${hws}"
  elif [[ -e "${directory}/${skey}" ]]; then
    [[ ! -e "${directory}/${skey}.gpg" ]] && cntools_pool_key_validate "${directory}/${skey}" cold signing &&
      cntools_transaction_source_kind_into kind "${directory}/${skey}" || {
      cntools_wallet_register_set_error 'The cold signing key is invalid or mixed. Decrypt it or use a public-only pool for offline signing.'; return 1;
    }
    CNTOOLS_POOL_REG_COLD_SOURCE="${directory}/${skey}"
  fi
  cntools_transaction_temp_file response pool-vrf-hash; cntools_transaction_temp_file errors pool-vrf-errors
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest node key-hash-VRF \
    --verification-key-file "${CNTOOLS_POOL_REG_VRF_VKEY}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Pool VRF hashing failed' "${status}" "${errors}" "${response}"; return 1; fi
  CNTOOLS_POOL_REG_VRF_HASH="$(< "${response}")"
  [[ "${CNTOOLS_POOL_REG_VRF_HASH}" =~ ^[0-9a-f]{64}$ ]]
}

# Only registration parameters/pending changes/retirement affect the review.
# Exclude advancing stake totals, epoch and block statistics from rechecks.
cntools_pool_registration_state_into() {
  local output="$1" index="${CNTOOLS_POOL_REG_INDEX}" format='' pool_state='' reward='' owners='[]' address='' hash=''
  case "${CNTOOLS_POOL_CHAIN_STATUS[index]}" in
    'Not registered'|'Not indexed'|Retired)
      printf -v "${output}" '%s' '{"registered":false}'; return 0 ;;
    Registered|Retiring) ;;
    *) cntools_wallet_register_set_error 'Pool registration could not be verified. An unavailable query is not an unregistered pool.'; return 1 ;;
  esac
  format="${CNTOOLS_POOL_CHAIN_SOURCE[index]}"
  if [[ "${format}" == 'Local node' ]]; then
    pool_state="$(jq -cS --arg retirement "${CNTOOLS_POOL_RETIREMENT[index]}" --argjson pending "${CNTOOLS_POOL_FUTURE[index]}" '
      {registered:true,retirement:$retirement,current:{pledgeLovelace:(.spsPledge|tostring),costLovelace:(.spsCost|tostring),
       margin:(.spsMargin|tostring),vrf:.spsVrf,reward:.spsAccountId.keyHash,owners:(.spsOwners|sort),
       relays:.spsRelays,metadata:(.spsMetadata // null)},pending:$pending}' <<< "${CNTOOLS_POOL_CURRENT[index]}")" || return 1
  elif [[ "${format}" == 'Koios API' ]]; then
    address="$(jq -er .reward_addr <<< "${CNTOOLS_POOL_CURRENT[index]}")" || return 1
    cntools_wallet_reward_credential_into reward "${address}" || return 1
    while IFS= read -r address; do
      cntools_wallet_reward_credential_into hash "${address}" || return 1
      owners="$(jq -c --arg hash "${hash}" '. + [$hash]' <<< "${owners}")" || return 1
    done < <(jq -r '.owners[]' <<< "${CNTOOLS_POOL_CURRENT[index]}")
    pool_state="$(jq -cS --arg reward "${reward}" --argjson owners "${owners}" '
      {registered:true,retirement:(.retiring_epoch // "" | tostring),current:{pledgeLovelace:.pledge,costLovelace:.fixed_cost,
       margin:(.margin|tostring),vrf:.vrf_key_hash,reward:$reward,owners:($owners|sort),
       relays:(.relays|map(if .dns != null then {"single host name":{dnsName:.dns,port:.port}}
         elif .srv != null then {"multi host name":{dnsName:.srv}}
         else {"single host address":{IPv4:.ipv4,IPv6:.ipv6,port:.port}} end)),
       metadata:(if .meta_url == null and .meta_hash == null then null else {url:.meta_url,hash:.meta_hash} end)},pending:{}}' \
       <<< "${CNTOOLS_POOL_CURRENT[index]}")" || return 1
  else return 1; fi
  jq -e '.current | (.reward|type == "string" and test("^[0-9a-f]{56}$")) and
    (.vrf|type == "string" and test("^[0-9a-f]{64}$")) and (.owners|type == "array" and length > 0 and all(.[];type == "string" and test("^[0-9a-f]{56}$")))' <<< "${pool_state}" >/dev/null || {
    cntools_wallet_register_set_error 'Incomplete or unsupported pool state. This slice needs a key-based reward account and owner stake credentials.'; return 1;
  }
  printf -v "${output}" '%s' "${pool_state}"
}

cntools_pool_registration_query_state_into() {
  cntools_pool_inspect_reset
  if [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" == local ]]; then
    cntools_pool_inspect_local "${CNTOOLS_POOL_REG_INDEX}" || return 1
  else
    cntools_pool_inspect_koios "${CNTOOLS_POOL_REG_INDEX}" || return 1
  fi
  cntools_pool_registration_state_into "$1"
}

cntools_pool_registration_prepare_funding() {
  local directory="$1" field='' source_name='' cold_kind=''
  cntools_payment_prepare_wallet "${directory}" || return 1
  CNTOOLS_WALLET_REGISTER_WALLET="${CNTOOLS_PAYMENT_WALLET}"
  CNTOOLS_WALLET_REGISTER_DIRECTORY="${directory}"
  CNTOOLS_WALLET_REGISTER_WALLET_TYPE="${CNTOOLS_PAYMENT_TYPE}"
  for field in BASE_ADDRESS PAYMENT_ADDRESS PAYMENT_VKEY PAYMENT_SOURCE PAYMENT_CREDENTIAL; do
    case "${field}" in BASE_ADDRESS) source_name=CNTOOLS_PAYMENT_ADDRESS ;; PAYMENT_ADDRESS) source_name=CNTOOLS_PAYMENT_PAYMENT ;; *) source_name="CNTOOLS_${field}" ;; esac
    printf -v "CNTOOLS_WALLET_REGISTER_${field}" '%s' "${!source_name}"
  done
  [[ "${CNTOOLS_PAYMENT_TYPE}" != Hardware || -n "${CNTOOLS_PAYMENT_SOURCE}" ]] || {
    cntools_wallet_register_set_error 'A hardware funding wallet needs its public signing reference to prepare change.'; return 1;
  }
  # Pinned hw-cli operator mode requires a cold hardware reference and rejects
  # owner stake witnesses in that call. A hardware payer cannot fund a CLI cold
  # pool, even if the intended workflow is an unsigned package for later signing.
  if [[ "${CNTOOLS_PAYMENT_TYPE}" == Hardware ]]; then
    cntools_transaction_source_kind_into cold_kind "${CNTOOLS_POOL_REG_COLD_SOURCE}" && [[ "${cold_kind}" == hardware ]] || {
      cntools_wallet_register_set_error 'Hardware funding requires the pool cold key on the same Ledger device. Choose a CLI/mnemonic funding wallet for a CLI or public-only cold key.'; return 1;
    }
  fi
}

cntools_pool_registration_collect() {
  local registered=''
  cntools_wallet_register_reset_chain_state
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  CNTOOLS_WALLET_REGISTER_BACKEND="${CNTOOLS_FUNDING_BACKEND}"; CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${CNTOOLS_FUNDING_PROTOCOL}"
  CNTOOLS_WALLET_REGISTER_SOURCE="${CNTOOLS_FUNDING_BACKEND}"
  cntools_pool_registration_query_state_into CNTOOLS_POOL_REG_STATE || {
    cntools_wallet_register_set_error "${CNTOOLS_WALLET_REGISTER_ERROR:-Pool registration could not be verified from the selected chain source.}"; return 1;
  }
  registered="$(jq -r .registered <<< "${CNTOOLS_POOL_REG_STATE}")"
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-register && "${registered}" == true ]]; then
    cntools_wallet_register_set_error 'This pool is already registered. Use Pool → Modify.'; return 1
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-modify && "${registered}" != true ]]; then
    cntools_wallet_register_set_error 'This pool is not registered. Use Pool → Register.'; return 1
  fi
  if [[ "${registered}" == true && "$(jq -r .current.vrf <<< "${CNTOOLS_POOL_REG_STATE}")" != "${CNTOOLS_POOL_REG_VRF_HASH}" ]]; then
    cntools_wallet_register_set_error 'The local VRF key differs from the registered pool. Recover its original VRF key before modification.'; return 1
  fi
  if [[ "${registered}" == true && "$(jq -c '.pending // {}' <<< "${CNTOOLS_POOL_REG_STATE}")" != '{}' &&
        "$(jq -r .pending.spsVrf <<< "${CNTOOLS_POOL_REG_STATE}")" != "${CNTOOLS_POOL_REG_VRF_HASH}" ]]; then
    cntools_wallet_register_set_error 'A pending pool update uses a different VRF key. Resolve its VRF identity before modifying; the pending update will not be overwritten silently.'; return 1
  fi
  cntools_wallet_query_json_uint_field CNTOOLS_POOL_REG_MIN_COST "${CNTOOLS_FUNDING_PROTOCOL}" minPoolCost &&
    cntools_pool_parameter_uint "${CNTOOLS_POOL_REG_MIN_COST}" || return 1
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0
  if [[ "${registered}" != true ]]; then
    cntools_wallet_query_json_uint_field CNTOOLS_WALLET_REGISTER_DEPOSIT "${CNTOOLS_FUNDING_PROTOCOL}" stakePoolDeposit &&
      cntools_pool_parameter_uint "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" || return 1
  fi
  CNTOOLS_POOL_REG_PROTOCOL_STATE="$(jq -cS . "${CNTOOLS_FUNDING_PROTOCOL}")" || return 1
  cntools_wallet_register_inventory_use_all || return 1
  cntools_transaction_log TRANSACTION "Pool operation=${CNTOOLS_WALLET_REGISTER_OPERATION} pool=${CNTOOLS_POOL_REG_ID} backend=${CNTOOLS_WALLET_REGISTER_BACKEND} deposit=${CNTOOLS_WALLET_REGISTER_DEPOSIT} state=${CNTOOLS_POOL_REG_STATE}"
}

cntools_pool_registration_certificate_create() {
  local certificate='' response='' errors='' owner='' relay='' type='' status=0
  local -a args=(--cold-verification-key-file "${CNTOOLS_POOL_REG_COLD_VKEY}" --vrf-verification-key-file "${CNTOOLS_POOL_REG_VRF_VKEY}"
    --pool-pledge "${CNTOOLS_POOL_REG_PLEDGE}" --pool-cost "${CNTOOLS_POOL_REG_COST}" --pool-margin "${CNTOOLS_POOL_REG_MARGIN}"
    --pool-reward-account-verification-key-file "${CNTOOLS_POOL_REG_REWARD_VKEY}") network=()
  cntools_pool_relays_normalize_into CNTOOLS_POOL_REG_RELAYS "${CNTOOLS_POOL_REG_RELAYS}" || {
    cntools_wallet_register_set_error 'Pool relays are invalid. Review their DNS names, IP addresses and ports.'; return 1;
  }
  cntools_pool_parameters_json >/dev/null || { cntools_wallet_register_set_error 'Complete valid pool settings and public owner/reward keys before building.'; return 1; }
  while IFS= read -r owner; do args+=(--pool-owner-stake-verification-key-file "${owner}"); done < <(jq -r '.[].vkey' <<< "${CNTOOLS_POOL_REG_OWNERS}")
  while IFS= read -r relay; do
    type="$(jq -r .type <<< "${relay}")"
    case "${type}" in
      dns) args+=(--single-host-pool-relay "$(jq -r .dns <<< "${relay}")" --pool-relay-port "$(jq -r .port <<< "${relay}")") ;;
      srv) args+=(--multi-host-pool-relay "$(jq -r .dns <<< "${relay}")") ;;
      ip)
        [[ "$(jq -r .ipv4 <<< "${relay}")" == '' ]] || args+=(--pool-relay-ipv4 "$(jq -r .ipv4 <<< "${relay}")")
        [[ "$(jq -r .ipv6 <<< "${relay}")" == '' ]] || args+=(--pool-relay-ipv6 "$(jq -r .ipv6 <<< "${relay}")")
        args+=(--pool-relay-port "$(jq -r .port <<< "${relay}")") ;;
    esac
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_RELAYS}")
  if [[ "${CNTOOLS_POOL_REG_METADATA}" != null ]]; then
    args+=(--metadata-url "$(jq -r .url <<< "${CNTOOLS_POOL_REG_METADATA}")" --metadata-hash "$(jq -r .hash <<< "${CNTOOLS_POOL_REG_METADATA}")")
  fi
  cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_temp_file certificate pool-registration || return 1
  cntools_transaction_temp_file response pool-registration-output || return 1
  cntools_transaction_temp_file errors pool-registration-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-pool registration-certificate \
    "${args[@]}" "${network[@]}" --out-file "${certificate}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Pool certificate creation failed' "${status}" "${errors}" "${response}"; return 1; fi
  cntools_transaction_file_safe "${certificate}" 131072 || return 1
  CNTOOLS_WALLET_REGISTER_CERTIFICATE_FILE="${certificate}"
}

cntools_pool_registration_group_into() {
  local output="$1" source="$2" fallback="$3" kind='' session_group=''
  if [[ -n "${source}" ]]; then
    cntools_transaction_source_kind_into kind "${source}" || return 1
    if [[ "${kind}" == hardware ]]; then
      session_group="${fallback}"
      if [[ "${CNTOOLS_POOL_REG_COMBINE_HARDWARE}" == Y && ( "${fallback}" == pool-funding || "${fallback}" == pool-cold ) ]]; then session_group=pool-operator; fi
    fi
  fi
  printf -v "${output}" '%s' "${session_group}"
}

cntools_pool_registration_plan_create() {
  local payment_group='' cold_group='' group='' owner='' label='' vkey='' source='' hash='' inputs='' params='' summary='' fallback=''
  cntools_transaction_plan_reset "${CNTOOLS_WALLET_REGISTER_INTENT}" "${CNTOOLS_WALLET_REGISTER_INTENT} for ${CNTOOLS_POOL_REG_ID}; owners and cold identity witness the certificate." exact || return 1
  cntools_transaction_plan_set_validity '' "${CNTOOLS_WALLET_REGISTER_EXPIRY}" || return 1
  cntools_pool_registration_group_into payment_group "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" pool-funding || return 1
  cntools_pool_registration_group_into cold_group "${CNTOOLS_POOL_REG_COLD_SOURCE}" pool-cold || return 1
  cntools_transaction_plan_add_signer "${CNTOOLS_WALLET_REGISTER_WALLET} payment" spending "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" \
    "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL}" "${payment_group}" || return 1
  cntools_transaction_plan_add_signer "${CNTOOLS_POOL_REG_NAME} cold" certificate "${CNTOOLS_POOL_REG_COLD_VKEY}" \
    "${CNTOOLS_POOL_REG_COLD_SOURCE}" "${CNTOOLS_POOL_REG_HEX}" "${cold_group}" || return 1
  while IFS= read -r owner; do
    label="$(jq -r .label <<< "${owner}")"; vkey="$(jq -r .vkey <<< "${owner}")"
    source="$(jq -r .source <<< "${owner}")"; hash="$(jq -r .hash <<< "${owner}")"
    # Pinned hw-cli owner mode witnesses exactly one stake key and cannot be
    # mixed with spending/cold keys, even when all keys live on one device.
    fallback="owner-${hash}"
    cntools_pool_registration_group_into group "${source}" "${fallback}" || return 1
    cntools_transaction_plan_add_signer "${label} owner stake" certificate "${vkey}" "${source}" "${hash}" "${group}" || return 1
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}")
  if [[ -n "${payment_group}" ]]; then
    cntools_transaction_plan_add_change_key "${CNTOOLS_WALLET_REGISTER_WALLET} payment change" "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" \
      "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" "${payment_group}" || return 1
    if [[ "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" != "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" ]]; then
      cntools_transaction_plan_add_change_key "${CNTOOLS_WALLET_REGISTER_WALLET} stake change" \
        "${CNTOOLS_WALLET_REGISTER_DIRECTORY}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
        "${CNTOOLS_WALLET_REGISTER_DIRECTORY}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" "${payment_group}" || return 1
    fi
  fi
  inputs="$(printf '%s\n' "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')"
  params="$(cntools_pool_parameters_json)" || return 1
  summary="$(jq -cn --arg action "${CNTOOLS_WALLET_REGISTER_OPERATION}" --arg pool "${CNTOOLS_POOL_REG_ID}" \
    --arg wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" --arg deposit "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" \
    --arg change "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" --argjson inputs "${inputs}" --argjson params "${params}" \
    --argjson policy "${CNTOOLS_WALLET_REGISTER_POLICY_JSON}" --argjson previous "${CNTOOLS_POOL_REG_STATE}" \
    '{action:$action,poolId:$pool,fundingWallet:$wallet,depositLovelace:$deposit,changeAddress:$change,selectedInputs:$inputs,
      poolParameters:$params,transactionPolicy:$policy,previousPoolState:$previous}')" || return 1
  cntools_transaction_plan_set_summary "${summary}"
}

cntools_pool_registration_validate_body() {
  local view='' expected='' inputs=''
  cntools_transaction_view_into view "$1" || return 1
  expected="$(cntools_pool_parameters_json)" || return 1
  inputs="$(printf '%s\n' "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))|sort')"
  jq -e --argjson params "${expected}" --argjson inputs "${inputs}" --arg address "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
    --arg expiry "${CNTOOLS_WALLET_REGISTER_EXPIRY}" --arg fee "${CNTOOLS_WALLET_REGISTER_FEE} Lovelace" '
    (.certificates|type == "array" and length == 1) and (.certificates[0]|keys == ["Pool registration"]) and
    (.certificates[0]["Pool registration"]["pool params"] | .owners |= sort) == $params and
    (.inputs|sort) == $inputs and .fee == $fee and
    (."validity range"["upper bound"]|if . == null then "" else tostring end) == $expiry and ."validity range"["lower bound"] == null and
    (.outputs|length > 0 and all(.[];.address == $address and .datum == null and ."reference script" == null)) and
    (.withdrawals == null or .withdrawals == []) and .mint == null and .metadata == null and
    (."collateral inputs" == null or ."collateral inputs" == []) and (."reference inputs" == null or ."reference inputs" == []) and
    (.voters == null or .voters == {}) and (."governance actions" == null or ."governance actions" == []) and
    (.treasuryDonation == null or .treasuryDonation == 0) and .currentTreasuryValue == null
  ' <<< "${view}" >/dev/null || { cntools_wallet_register_set_error 'The decoded transaction does not match the reviewed pool parameters, inputs or change.'; return 1; }
}

cntools_pool_registration_build_into() {
  local output="$1" slot=''
  cntools_wallet_register_select_inputs || return 1
  CNTOOLS_WALLET_REGISTER_EXPIRY=''
  [[ "${CNTOOLS_WALLET_REGISTER_LIFETIME}" == 0 ]] || cntools_funding_tip_into slot "${CNTOOLS_WALLET_REGISTER_BACKEND}" || return 1
  cntools_transaction_expiry_into CNTOOLS_WALLET_REGISTER_EXPIRY "${slot}" "${CNTOOLS_WALLET_REGISTER_LIFETIME}" || return 1
  cntools_pool_registration_certificate_create || return 1
  cntools_wallet_register_build_balanced_into "${output}"
}

cntools_pool_registration_recheck() {
  local state='' ref='' backend="${CNTOOLS_WALLET_REGISTER_BACKEND}"
  cntools_funding_collect "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" || return 1
  [[ "${CNTOOLS_FUNDING_BACKEND}" == "${backend}" && "$(jq -cS . "${CNTOOLS_FUNDING_PROTOCOL}")" == "${CNTOOLS_POOL_REG_PROTOCOL_STATE}" ]] || {
    cntools_wallet_register_set_error 'The chain source or protocol parameters changed. Rebuild and review the pool transaction.'; return 1;
  }
  [[ -z "${CNTOOLS_WALLET_REGISTER_EXPIRY}" ]] || ((CNTOOLS_FUNDING_SLOT < CNTOOLS_WALLET_REGISTER_EXPIRY)) || {
    cntools_wallet_register_set_error 'The pool transaction expired. Rebuild and review it.'; return 1;
  }
  for ref in "${CNTOOLS_WALLET_REGISTER_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${ref}]+x}" ]] || { cntools_wallet_register_set_error 'A selected input was spent. Rebuild and review.'; return 1; }
  done
  cntools_pool_registration_query_state_into state || return 1
  [[ "${state}" == "${CNTOOLS_POOL_REG_STATE}" ]] || {
    cntools_wallet_register_set_error 'Pool registration, parameters or retirement changed. Rebuild and review the transaction.'; return 1;
  }
}
