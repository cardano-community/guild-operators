#!/usr/bin/env bash
# Public wizard drafts. Never persist transient paths, signing keys or passwords.
# shellcheck disable=SC2034
cntools_pool_public_save() {
  local directory="$1" filename="$2" source="$3" publish_file='' backup_file=''
  cntools_pool_directory_writable "${directory}" && cntools_pool_filenames_validate &&
    [[ "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] &&
    cntools_pool_public_file_safe "${source}" 1048576 || return 1
  if [[ -e "${directory}/${filename}" || -L "${directory}/${filename}" ]]; then
    cntools_pool_public_file_safe "${directory}/${filename}" 1048576 && [[ -O "${directory}/${filename}" ]] || return 1
    [[ ! -L "${directory}/${filename}.previous" && ! -d "${directory}/${filename}.previous" ]] || return 1
    cntools_pool_temp_into backup_file "${directory}" || return 1
    cp -- "${directory}/${filename}" "${backup_file}" && chmod 0600 "${backup_file}" || return 1
    mv -f -- "${backup_file}" "${directory}/${filename}.previous" || return 1
  fi
  cntools_pool_temp_into publish_file "${directory}" || return 1
  cp -- "${source}" "${publish_file}" && chmod 0600 "${publish_file}" &&
    mv -f -- "${publish_file}" "${directory}/${filename}" || return 1
  cntools_transaction_log POOL "Saved public wizard file=${directory}/${filename}"
}

cntools_pool_config_save() {
  local directory="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}" file='' filename='' record='' owners='[]' reward=''
  while IFS= read -r record; do
    record="$(jq --argjson public "$(jq . "$(jq -r .vkey <<< "${record}")")" '{label,hash,address,publicKey:$public}' <<< "${record}")" || return 1
    owners="$(jq -c --argjson record "${record}" '.+[$record]' <<< "${owners}")" || return 1
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}")
  reward="$(jq -cn --arg label "${CNTOOLS_POOL_REG_REWARD_LABEL}" --arg hash "${CNTOOLS_POOL_REG_REWARD_HASH}" \
    --argjson public "$(jq . "${CNTOOLS_POOL_REG_REWARD_VKEY}")" '{label:$label,hash:$hash,publicKey:$public}')" || return 1
  cntools_transaction_temp_file file pool-config || return 1
  jq -n --arg network "${CNTOOLS_NETWORK}" --arg pool "${CNTOOLS_POOL_REG_ID}" --arg pledge "${CNTOOLS_POOL_REG_PLEDGE}" \
    --arg cost "${CNTOOLS_POOL_REG_COST}" --arg margin "${CNTOOLS_POOL_REG_MARGIN}" --argjson owners "${owners}" \
    --argjson reward "${reward}" --argjson relays "${CNTOOLS_POOL_REG_RELAYS}" --argjson metadata "${CNTOOLS_POOL_REG_METADATA}" \
    '{schema:1,status:"Local draft; not proof of submission",network:$network,poolId:$pool,
      pledgeLovelace:$pledge,costLovelace:$cost,margin:$margin,owners:$owners,reward:$reward,relays:$relays,metadata:$metadata}' > "${file}" || return 1
  cntools_pool_file_name_into filename config && cntools_pool_public_save "${directory}" "${filename}" "${file}"
}

cntools_pool_config_record_into() {
  local output="$1" config_record="$2" public='' resolved_record='' index=0 expected=''
  expected="$(jq -er .hash <<< "${config_record}")" || return 1
  for index in "${!CNTOOLS_WALLET_NAMES[@]}"; do
    if cntools_pool_wallet_stake_record_into resolved_record "${index}" && [[ "$(jq -r .hash <<< "${resolved_record}")" == "${expected}" ]]; then
      printf -v "${output}" '%s' "${resolved_record}"; return 0
    fi
  done
  cntools_transaction_temp_file public saved-owner-public || return 1
  jq -e '.publicKey' <<< "${config_record}" > "${public}" || return 1
  cntools_pool_stake_record_into resolved_record "${public}" '' "$(jq -r .label <<< "${config_record}")" || return 1
  [[ "$(jq -r .hash <<< "${resolved_record}")" == "${expected}" ]] || return 1
  printf -v "${output}" '%s' "${resolved_record}"
}

cntools_pool_config_load() {
  local filename='' file='' json='' record='' candidate='' owners='[]' reward='' pledge='' cost='' margin='' relays='' metadata='null' index=0 label=''
  cntools_pool_file_name_into filename config || return 1
  file="${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}/${filename}"
  cntools_transaction_snapshot_into file "${file}" 1048576 pool-config-read || return 1
  json="$(jq -ce 'select(type == "object")' "${file}")" || return 1
  if [[ "$(jq -r '.schema // 0' <<< "${json}")" == 1 ]]; then
    jq -e --arg pool "${CNTOOLS_POOL_REG_ID}" --arg network "${CNTOOLS_NETWORK}" '.poolId == $pool and .network == $network' <<< "${json}" >/dev/null || return 1
    pledge="$(jq -r .pledgeLovelace <<< "${json}")"; cost="$(jq -r .costLovelace <<< "${json}")"; margin="$(jq -r .margin <<< "${json}")"
    while IFS= read -r record; do
      cntools_pool_config_record_into candidate "${record}" || return 1
      owners="$(jq -c --argjson record "${candidate}" '.+[$record]' <<< "${owners}")" || return 1
    done < <(jq -c '.owners[]' <<< "${json}")
    cntools_pool_config_record_into reward "$(jq -c .reward <<< "${json}")" || return 1
    relays="$(jq -c .relays <<< "${json}")"; metadata="$(jq -c .metadata <<< "${json}")"
  else
    cntools_number_units_into pledge "$(jq -r .pledgeADA <<< "${json}")" 6 &&
      cntools_number_units_into cost "$(jq -r .costADA <<< "${json}")" 6 &&
      cntools_pool_margin_into margin "$(jq -r .margin <<< "${json}")" || return 1
    while IFS= read -r label; do
      candidate=''
      for index in "${!CNTOOLS_WALLET_NAMES[@]}"; do
        [[ "${CNTOOLS_WALLET_NAMES[index]}" != "${label}" ]] || { cntools_pool_wallet_stake_record_into candidate "${index}" || return 1; break; }
      done
      [[ -n "${candidate}" ]] || return 1
      owners="$(jq -c --argjson record "${candidate}" '.+[$record]' <<< "${owners}")"
    done < <(jq -r 'if .owners then .owners[].wallet_name else .pledgeWallet end' <<< "${json}")
    label="$(jq -r '.rewardWallet // .pledgeWallet // .owners[0].wallet_name' <<< "${json}")"
    for index in "${!CNTOOLS_WALLET_NAMES[@]}"; do
      [[ "${CNTOOLS_WALLET_NAMES[index]}" != "${label}" ]] || { cntools_pool_wallet_stake_record_into reward "${index}" || return 1; break; }
    done
    [[ -n "${reward}" ]] || return 1
    relays="$(jq -c '(.relays // []) | map(if .type == "DNS_A" then {type:"dns",dns:.address,port:(.port|tonumber)}
      elif .type == "DNS_SRV" then {type:"srv",dns:.address}
      elif .type == "IPv4" then {type:"ip",ipv4:.address,ipv6:"",port:(.port|tonumber)}
      elif .type == "IPv6" then {type:"ip",ipv4:"",ipv6:.address,port:(.port|tonumber)} else . end)' <<< "${json}")" || return 1
  fi
  cntools_pool_parameter_uint "${pledge}" && cntools_pool_parameter_uint "${cost}" && cntools_pool_margin_number "${margin}" >/dev/null &&
    cntools_pool_metadata_valid "${metadata}" || return 1
  cntools_pool_relays_normalize_into relays "${relays}" || return 1
  jq -e 'length > 0 and (map(.hash)|unique|length) == length' <<< "${owners}" >/dev/null || return 1
  cntools_uint_greater_equal "${cost}" "${CNTOOLS_POOL_REG_MIN_COST}" || cost="${CNTOOLS_POOL_REG_MIN_COST}"
  CNTOOLS_POOL_REG_PLEDGE="${pledge}"; CNTOOLS_POOL_REG_COST="${cost}"; CNTOOLS_POOL_REG_MARGIN="${margin}"
  CNTOOLS_POOL_REG_OWNERS="${owners}"; CNTOOLS_POOL_REG_RELAYS="${relays}"; CNTOOLS_POOL_REG_METADATA="${metadata}"
  CNTOOLS_POOL_REG_METADATA_URL="$(jq -r '.metadata.url // .json_url // empty' <<< "${json}")"
  cntools_pool_reward_record_use "${reward}"
}
