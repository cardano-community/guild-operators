#!/usr/bin/env bash
# Verified public stake identities; missing/encrypted signing keys stay offline.
# shellcheck disable=SC2034
cntools_pool_stake_record_into() {
  local output="$1" file="$2" source="$3" label="$4" public='' key_id='' hash='' address='' response='' errors='' status=0 kind=''
  local -a network=()
  cntools_wallet_key_validate "${file}" stake any || {
    cntools_wallet_register_set_error 'Choose a valid stake verification key, not a payment key or script.'; return 1;
  }
  cntools_transaction_snapshot_into public "${file}" 65536 pool-owner-public || return 1
  cntools_transaction_key_id_from_verification_file_into key_id "${public}" &&
    cntools_transaction_credential_from_key_id_into hash "${key_id}" || return 1
  if [[ -n "${source}" ]]; then
    cntools_transaction_source_kind_into kind "${source}" || source=''
  fi
  cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_temp_file response pool-stake-address; cntools_transaction_temp_file errors pool-stake-errors
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-address build \
    --stake-verification-key-file "${public}" "${network[@]}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Pool stake address derivation failed' "${status}" "${errors}" "${response}"; return 1; fi
  address="$(< "${response}")"
  cntools_wallet_bech32_valid "${address}" "$(cntools_wallet_address_hrp reward)" reward || return 1
  printf -v "${output}" '%s' "$(jq -cn --arg label "${label}" --arg vkey "${public}" --arg source "${source}" --arg hash "${hash}" \
    --arg address "${address}" '{label:$label,vkey:$vkey,source:$source,hash:$hash,address:$address}')"
}

cntools_pool_wallet_stake_record_into() {
  local output="$1" index="$2" directory="${CNTOOLS_WALLET_PATHS[$2]}" source='' kind=''
  cntools_wallet_directory_safe "${directory}" && cntools_wallet_prepare_selected_material "${directory}" || return 1
  [[ "$(cntools_wallet_type "${directory}")" != MultiSig ]] || return 1
  source="${directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
  [[ ! -f "${directory}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" ]] || source="${directory}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
  cntools_transaction_source_kind_into kind "${source}" || source=''
  cntools_pool_stake_record_into "${output}" "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" "${source}" "${CNTOOLS_WALLET_NAMES[index]}"
}

cntools_pool_owner_add() {
  local record="$1" hash='' count=0
  hash="$(jq -er .hash <<< "${record}")" || return 1
  count="$(jq length <<< "${CNTOOLS_POOL_REG_OWNERS}")"
  if (( count >= 20 )) && ! jq -e --arg hash "${hash}" 'any(.[];.hash == $hash)' <<< "${CNTOOLS_POOL_REG_OWNERS}" >/dev/null; then
    cntools_wallet_register_set_error 'At most 20 pool owners are supported in this flow.'; return 1
  fi
  CNTOOLS_POOL_REG_OWNERS="$(jq -c --argjson record "${record}" 'map(select(.hash != $record.hash)) + [$record]' <<< "${CNTOOLS_POOL_REG_OWNERS}")"
}

cntools_pool_registration_defaults() {
  local current='{}' margin='' hash='' record='' index=0 owner=''
  CNTOOLS_POOL_REG_PLEDGE=0; CNTOOLS_POOL_REG_COST="${CNTOOLS_POOL_REG_MIN_COST}"; CNTOOLS_POOL_REG_MARGIN=0
  CNTOOLS_POOL_REG_METADATA=null; CNTOOLS_POOL_REG_RELAYS='[]'; CNTOOLS_POOL_REG_OWNERS='[]'
  CNTOOLS_POOL_REG_REWARD_VKEY=''; CNTOOLS_POOL_REG_REWARD_HASH=''; CNTOOLS_POOL_REG_REWARD_ADDRESS=''; CNTOOLS_POOL_REG_REWARD_LABEL=''
  [[ "$(jq -r .registered <<< "${CNTOOLS_POOL_REG_STATE}")" == true ]] || return 0
  current="$(jq -c '.current' <<< "${CNTOOLS_POOL_REG_STATE}")"
  # Local pending parameters take precedence; changing only one field must not
  # accidentally undo a previously submitted update waiting for the next epoch.
  if [[ "$(jq -c .pending <<< "${CNTOOLS_POOL_REG_STATE}")" != '{}' ]]; then
    current="$(jq -c '.pending | {pledgeLovelace:(.spsPledge|tostring),costLovelace:(.spsCost|tostring),margin:(.spsMargin|tostring),
      reward:.spsAccountId.keyHash,owners:.spsOwners,relays:.spsRelays,metadata:(.spsMetadata // null)}' <<< "${CNTOOLS_POOL_REG_STATE}")"
  fi
  CNTOOLS_POOL_REG_PLEDGE="$(jq -r .pledgeLovelace <<< "${current}")"; CNTOOLS_POOL_REG_COST="$(jq -r .costLovelace <<< "${current}")"
  CNTOOLS_POOL_REG_MARGIN="$(jq -r .margin <<< "${current}")"; CNTOOLS_POOL_REG_METADATA="$(jq -c .metadata <<< "${current}")"
  CNTOOLS_POOL_REG_RELAYS="$(jq -c '.relays | map(if has("single host name") then .["single host name"] | {type:"dns",dns:.dnsName,port:.port}
    elif has("multi host name") then .["multi host name"] | {type:"srv",dns:.dnsName}
    else .["single host address"] | {type:"ip",ipv4:(.IPv4 // ""),ipv6:(.IPv6 // ""),port:.port} end)' <<< "${current}")"
  CNTOOLS_POOL_REG_REWARD_HASH="$(jq -r .reward <<< "${current}")"
  while IFS= read -r hash; do
    owner="$(jq -cn --arg hash "${hash}" '{label:$hash,hash:$hash,vkey:"",source:"",address:""}')"
    for index in "${!CNTOOLS_WALLET_NAMES[@]}"; do
      # Look only at wallets with a stake public key or a derivable stake key.
      [[ -f "${CNTOOLS_WALLET_PATHS[index]}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" ||
         -f "${CNTOOLS_WALLET_PATHS[index]}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" ]] || continue
      if cntools_pool_wallet_stake_record_into record "${index}" && [[ "$(jq -r .hash <<< "${record}")" == "${hash}" ]]; then owner="${record}"; break; fi
    done
    cntools_pool_owner_add "${owner}" || return 1
  done < <(jq -r '.owners[]' <<< "${current}")
  for index in "${!CNTOOLS_WALLET_NAMES[@]}"; do
    [[ -f "${CNTOOLS_WALLET_PATHS[index]}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" ]] || continue
    if cntools_pool_wallet_stake_record_into record "${index}" && [[ "$(jq -r .hash <<< "${record}")" == "${CNTOOLS_POOL_REG_REWARD_HASH}" ]]; then
      cntools_pool_reward_record_use "${record}"; break
    fi
  done
}

cntools_pool_reward_record_use() {
  CNTOOLS_POOL_REG_REWARD_VKEY="$(jq -r .vkey <<< "$1")"
  CNTOOLS_POOL_REG_REWARD_HASH="$(jq -r .hash <<< "$1")"
  CNTOOLS_POOL_REG_REWARD_ADDRESS="$(jq -r .address <<< "$1")"
  CNTOOLS_POOL_REG_REWARD_LABEL="$(jq -r .label <<< "$1")"
}

cntools_pool_registration_can_sign_into() {
  local -n pcs_result="$1"
  local source='' record=''
  pcs_result=N
  [[ -n "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" && -n "${CNTOOLS_POOL_REG_COLD_SOURCE}" ]] || return 0
  while IFS= read -r record; do
    source="$(jq -r .source <<< "${record}")"; [[ -n "${source}" ]] || return 0
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}")
  pcs_result=Y
}
