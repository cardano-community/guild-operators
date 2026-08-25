# Command     : getPayAddress [wallet name]
# Description : create and save payment address
# Parameters  : wallet name  >  the name of the wallet
# Return      : populates ${pay_addr}
getPayAddress() {
  unset pay_addr
  payment_vk_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_VK_FILENAME}"
  payment_script_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_SCRIPT_FILENAME}"
  payment_addr_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_ADDR_FILENAME}"
  [[ -f ${payment_addr_file} ]] && pay_addr=$(cat "${payment_addr_file}") && return 0
  if [[ -f "${payment_vk_file}" ]]; then
    println ACTION "${CCLI} address build --payment-verification-key-file ${payment_vk_file} --out-file ${payment_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} address build --payment-verification-key-file "${payment_vk_file}" --out-file "${payment_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      pay_addr=$(cat "${payment_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during payment address creation!\n${stdout}"
    fi
  elif [[ -f "${payment_script_file}" ]]; then
    println ACTION "${CCLI} address build --payment-script-file ${payment_script_file} --out-file ${payment_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} address build --payment-script-file "${payment_script_file}" --out-file "${payment_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      pay_addr=$(cat "${payment_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during payment script address creation!\n${stdout}"
    fi
  fi
  return 1
}

# Command     : getGovKeyInfo [wallet name]
# Description : generate DRep ID and committee key hash
getGovKeyInfo() {
  unset drep_id drep_id_cip129 drep_hash hash_type cc_cold_hash cc_cold_id cc_cold_id_cip129 cc_hot_hash cc_hot_id cc_hot_id_cip129 ms_drep_id ms_drep_hash
  drep_vk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_DREP_VK_FILENAME}"
  drep_sk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_DREP_SK_FILENAME}"
  drep_script_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
  drep_id_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_DREP_ID_FILENAME}"
  cc_cold_vk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
  cc_cold_sk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_CC_COLD_SK_FILENAME}"
  cc_cold_id_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_CC_COLD_ID_FILENAME}"
  cc_hot_vk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
  cc_hot_sk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_CC_HOT_SK_FILENAME}"
  cc_hot_id_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_CC_HOT_ID_FILENAME}"
  ms_drep_vk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
  ms_drep_sk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}"
  ms_drep_id_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_ID_FILENAME}"
  if [[ -f "${drep_vk_file}" && $(jq -r '.description' "${drep_vk_file}") = *"Hardware"* ]]; then # Hardware wallet
    drep_sk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_HW_DREP_SK_FILENAME}"
    cc_cold_sk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_HW_CC_COLD_SK_FILENAME}"
    cc_hot_sk_file="${WALLET_FOLDER}/${1}/${WALLET_GOV_HW_CC_HOT_SK_FILENAME}"
    ms_drep_sk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_HW_DREP_SK_FILENAME}"
  fi
  [[ -f ${drep_id_file} ]] && drep_id=$(cat "${drep_id_file}")
  [[ -f ${cc_cold_id_file} ]] && cc_cold_id=$(cat "${cc_cold_id_file}")
  [[ -f ${cc_hot_id_file} ]] && cc_hot_id=$(cat "${cc_hot_id_file}")
  [[ -f ${ms_drep_id_file} ]] && ms_drep_id=$(cat "${ms_drep_id_file}")
  if [[ -z ${drep_id} && -f ${drep_vk_file} ]]; then
    println ACTION "${CCLI} latest governance drep id --drep-verification-key-file ${drep_vk_file}"
    drep_id=$(${CCLI} latest governance drep id --drep-verification-key-file "${drep_vk_file}")
    printf "${drep_id}" > "${drep_id_file}"
  elif [[ -z ${drep_id} && -f ${drep_script_file} ]]; then
    println ACTION "${CCLI} hash script --script-file ${drep_script_file}"
    drep_id=$(${CCLI} hash script --script-file "${drep_script_file}")
    printf "${drep_id}" > "${drep_id_file}"
  fi
  if [[ -z ${ms_drep_id} && -f ${ms_drep_vk_file} ]]; then
    println ACTION "${CCLI} latest governance drep id --drep-verification-key-file ${ms_drep_vk_file}"
    ms_drep_id=$(${CCLI} latest governance drep id --drep-verification-key-file "${ms_drep_vk_file}")
    printf "${ms_drep_id}" > "${ms_drep_id_file}"
  fi
  if [[ -z ${cc_cold_id} && -f ${cc_cold_vk_file} ]]; then
    println ACTION "bech32 cc_cold <<< \$(${CCLI} latest governance committee key-hash --verification-key-file ${cc_cold_vk_file})"
    cc_cold_id=$(bech32 cc_cold <<< "$(${CCLI} latest governance committee key-hash --verification-key-file "${cc_cold_vk_file}")")
    printf "${cc_cold_id}" > "${cc_cold_id_file}"
  fi
  if [[ -z ${cc_hot_id} && -f ${cc_hot_vk_file} ]]; then
    println ACTION "bech32 cc_hot <<< \$(${CCLI} latest governance committee key-hash --verification-key-file ${cc_hot_vk_file})"
    cc_hot_id=$(bech32 cc_hot <<< "$(${CCLI} latest governance committee key-hash --verification-key-file "${cc_hot_vk_file}")")
    printf "${cc_hot_id}" > "${cc_hot_id_file}"
  fi
  if [[ -n ${drep_id} ]]; then
    if [[ ${drep_id} = drep* ]]; then
      hash_type="keyHash"
      drep_hash="$(bech32 <<< ${drep_id})"
      drep_id_cip129="$(bech32 drep <<< "22${drep_hash}")"
    else
      hash_type="scriptHash"
      drep_hash="${drep_id}"
      drep_id="$(bech32 drep_script <<< "${drep_hash}")"
      drep_id_cip129="$(bech32 drep <<< "23${drep_hash}")"
    fi
  fi
  if [[ -n ${ms_drep_id} ]]; then
    ms_drep_hash="$(bech32 <<< ${ms_drep_id})"
    ms_drep_id=$(bech32 drep_script <<< "${ms_drep_hash}")
  fi
  if [[ -n ${cc_cold_id} ]]; then
    cc_cold_hash=$(bech32 <<< "${cc_cold_id}")
    cc_cold_id_cip129=$(bech32 cc_cold <<< "12${cc_cold_hash}")
  fi
  if [[ -n ${cc_hot_id} ]]; then
    cc_hot_hash=$(bech32 <<< "${cc_hot_id}")
    cc_hot_id_cip129=$(bech32 cc_hot <<< "02${cc_hot_hash}")
  fi
}

# Command     : getDRepIds [type] [hash]
getDRepIds() {
  unset drep_id drep_id_cip129
  [[ -z $1 || -z $2 ]] && return 1
  if [[ $1 = keyHash ]]; then
    drep_id="$(bech32 drep <<< ${2})"
    drep_id_cip129="$(bech32 drep <<< "22${2}")"
  else
    drep_id="$(bech32 drep_script <<< ${2})"
    drep_id_cip129="$(bech32 drep <<< "23${2}")"
  fi
}

# Command     : parseDRepId [drep_id]
parseDRepId() {
  unset drep_id drep_id_cip129 drep_hash hash_type
  [[ -z $1 ]] && return 1
  drep_hash=$(bech32 <<< $1)
  if [[ ${#drep_hash} -eq 56 ]]; then
    if [[ $1 = drep_script* ]]; then
      hash_type=scriptHash
      drep_id=$(bech32 drep_script <<< "${drep_hash}")
      drep_id_cip129=$(bech32 drep <<< "23${drep_hash}")
    else
      hash_type=keyHash
      drep_id=$(bech32 drep <<< "${drep_hash}")
      drep_id_cip129=$(bech32 drep <<< "22${drep_hash}")
    fi
  elif [[ ${#drep_hash} -eq 58 ]]; then
    if [[ ${drep_hash:0:2} = 23 ]]; then
      hash_type=scriptHash
      drep_hash=${drep_hash:2}
      drep_id=$(bech32 drep_script <<< "${drep_hash}")
      drep_id_cip129=$1
    else
      hash_type=keyHash
      drep_hash=${drep_hash:2}
      drep_id=$(bech32 drep <<< "${drep_hash}")
      drep_id_cip129=$1
    fi
  fi
}

# Command     : getCCIds [type] [hash]
getCCIds() {
  unset cc_cold_id cc_hot_id cc_cold_id_cip129 cc_hot_id_cip129
  [[ -z $1 || -z $2 ]] && return 1
  if [[ $1 = keyHash ]]; then
    cc_cold_id="$(bech32 cc_cold <<< ${2})"
    cc_hot_id="$(bech32 cc_hot <<< ${2})"
    cc_cold_id_cip129="$(bech32 cc_cold <<< "12${2}")"
    cc_hot_id_cip129="$(bech32 cc_cold <<< "02${2}")"
  else
    cc_cold_id="$(bech32 cc_cold_script <<< ${2})"
    cc_hot_id="$(bech32 cc_hot_script <<< ${2})"
    cc_cold_id_cip129="$(bech32 cc_cold <<< "13${2}")"
    cc_hot_id_cip129="$(bech32 cc_cold <<< "03${2}")"
  fi
}

# Command     : getGovActionId [tx_id] [index]
getGovActionId() {
  unset action_id action_id_cip129
  [[ -z $1 || -z $2 ]] && return 1
  action_id="${1}#${2}"
  action_id_cip129=$(bech32 gov_action <<< "${1}$(printf '%02x' ${2})")
}

# Command     : parseGovActionId [gov_action_id]
parseGovActionId() {
  unset action_tx_id action_idx
  [[ -z $1 ]] && return 1
  action_hex=$(bech32 <<< "${1}")
  action_tx_id=${action_hex:0:64}
  action_idx=$(printf "%d" "0x${action_hex:64}")
}

# Command     : getDRepStatus [type] [hash]
# Description : query status of drep id
# Return      : populates ${hash_type} ${drep_hash} ${drep_anchor_url} ${drep_anchor_hash} ${drep_deposit_amt} ${drep_expiry} ${drep_active} ${drep_vote_power}
getDRepStatus() {
  unset hash_type drep_anchor_url drep_anchor_hash drep_deposit_amt drep_expiry drep_active drep_vote_power
  [[ -z $1 || -z $2 || ($1 != keyHash && $1 != scriptHash) ]] && return 1
  hash_type="$1"
  drep_hash="$2"
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    if [[ ${2} = alwaysAbstain ]]; then
      _param="drep_always_abstain"
    elif [[ ${2} = alwaysNoConfidence ]]; then
     _param="drep_always_no_confidence"
    else
      [[ ${hash_type} = keyHash ]] && _param=$(bech32 drep <<< "22${2}") || _param=$(bech32 drep <<< "23${2}")
    fi
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json" -H "accept: text/csv")
    println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '{\"_drep_ids\":[\"${_param}\"]}' ${KOIOS_API}/drep_info?select=drep_status,deposit,active,expires_epoch_no,amount,meta_url,meta_hash"
    ! drep_info_list=$(curl -sSL -f -X POST "${HEADERS[@]}" -d '{"_drep_ids":["'${_param}'"]}' "${KOIOS_API}/drep_info?select=drep_status,deposit,active,expires_epoch_no,amount,meta_url,meta_hash" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${drep_info_list}\n" && return 1 # print error and return
    [[ -z ${drep_info_list} ]] && return 1
    while IFS=',' read -r _drep_status _deposit _active _expires_epoch_no _amount _url _hash; do
      [[ ${_drep_status} != 'registered' ]] && return 1
      drep_anchor_url="${_url}"
      drep_anchor_hash="${_hash}"
      drep_deposit_amt="${_deposit}"
      drep_expiry="${_expires_epoch_no}"
      drep_active="${_active}"
      drep_vote_power="${_amount}"
      return 0
    done <<< "$(tail -n +2 <<< ${drep_info_list})"
  elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
    [[ ${hash_type} = keyHash ]] && hash_param="--drep-key-hash" || hash_param="--drep-script-hash"
    println ACTION "${CCLI} latest query drep-state ${hash_param} ${2} ${NETWORK_IDENTIFIER} | jq -r .[0][1]"
    drep_state=$(${CCLI} latest query drep-state ${hash_param} ${2} ${NETWORK_IDENTIFIER} | jq -r .[0][1])
    [[ ${drep_state} = null ]] && return 1
    IFS=',' read -r drep_anchor_url drep_anchor_hash drep_deposit_amt drep_expiry < <( jq -cr '"\(.anchor.url//""),\(.anchor.dataHash//""),\(.deposit),\(.expiry)"' <<< "${drep_state}" )
    return 0
  fi
  return 1
}

# Command     : getDRepAnchor [url] [hash]
# Description : download anchor data and verify hash
# Return      : populates ${drep_anchor_file} ${drep_anchor_real_hash}
#             : 0 = ok, 1 = invalid url, 2 = hash doesn't match
getDRepAnchor() {
  unset drep_anchor_file drep_anchor_real_hash
  [[ -z $1 ]] && return 1
  drep_anchor_file="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
  if ! curl -sL -m ${CURL_TIMEOUT} -o "${drep_anchor_file}" ${1}; then
    [[ -f "${drep_anchor_file}" ]] && rm -f "${drep_anchor_file}"
    unset drep_anchor_file
    return 1
  fi
  println ACTION "${CCLI} hash anchor-data --file-text ${drep_anchor_file}"
  drep_anchor_real_hash="$(${CCLI} hash anchor-data --file-text "${drep_anchor_file}")"
  [[ ${drep_anchor_real_hash} != "${2}" ]] && return 2
  return 0
}

# Command     : getDRepVotePower [type] <hash>
# Description : query status of drep id
# Return      : populates ${vote_power} ${vote_power_total} ${vote_power_pct}
getDRepVotePower() {
  unset vote_power vote_power_total vote_power_pct
  [[ -z $1 ]] && return 1
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    if [[ $1 = always* ]]; then
      getDRepStatus "-" "$1" || return 1
    elif [[ ${drep_hash} != "$2" ]] || ! isNumber ${drep_vote_power}; then
      getDRepStatus "$1" "$2" || return 1
    fi
    current_epoch=$(getEpoch)
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "accept: text/csv")
    println ACTION "curl -sSL -f -X GET ${HEADERS[*]} ${KOIOS_API}/drep_epoch_summary?_epoch_no=${current_epoch}&select=amount"
    vote_power_total=$(curl -sSL -f -X GET "${HEADERS[@]}" "${KOIOS_API}/drep_epoch_summary?_epoch_no=${current_epoch}&select=amount") || return 1
    vote_power_total=$(tail -n +2 <<< ${vote_power_total})
    vote_power="${drep_vote_power}"
  elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
    println ACTION "${CCLI} latest query drep-stake-distribution --all-dreps ${NETWORK_IDENTIFIER}"
    all_drep_vote_power=$(${CCLI} latest query drep-stake-distribution --all-dreps ${NETWORK_IDENTIFIER})
    vote_power_total=$(jq -r '[.[]] | add' <<< "${all_drep_vote_power}")
    search_string="drep-${1}"
    [[ -n $2 ]] && search_string+="-${2}"
    vote_power=$(jq -r --arg v "${search_string}" '.[$v] //empty' <<< "${all_drep_vote_power}")
    [[ -z ${vote_power} ]] && return 1
  else
    return 1
  fi
  [[ -z ${vote_power_total} ]] && vote_power_total=0
  [[ -z ${vote_power} ]] && vote_power=0
  if [[ ${vote_power_total} -eq 0 || ${vote_power} -eq 0 ]]; then
    vote_power_pct="0.00"
  else
    vote_power_pct=$(fractionToPCT "$(bc -l <<< "${vote_power}/${vote_power_total}")")
    [[ -z ${vote_power_pct%.*} || ${vote_power_pct%.*} = 0 ]] && pct_precision=4 || pct_precision=2
    vote_power_pct=$(printf "%.${pct_precision}f" ${vote_power_pct})
  fi
  return 0
}

# Command     : getLocalActiveDRepStakeDistribution
# Description : populate all_drep_vote_power with active local DRep stake distribution
getLocalActiveDRepStakeDistribution() {
  local all_drep_vote_power_raw drep_state_all active_drep_ids current_epoch

  current_epoch=$(getEpoch)
  println ACTION "${CCLI} latest query drep-stake-distribution --all-dreps ${NETWORK_IDENTIFIER}"
  all_drep_vote_power_raw=$(${CCLI} latest query drep-stake-distribution --all-dreps ${NETWORK_IDENTIFIER}) || return 1
  println ACTION "${CCLI} latest query drep-state --all-dreps ${NETWORK_IDENTIFIER}"
  drep_state_all=$(${CCLI} latest query drep-state --all-dreps ${NETWORK_IDENTIFIER}) || return 1

  # DReps only stop counting after the current epoch passes their expiry.
  active_drep_ids=$(jq -cr --argjson current_epoch "${current_epoch}" '[.[] | select((.[1].expiry // -1) >= $current_epoch) | if .[0].keyHash then "drep-keyHash-\(.[0].keyHash)" else "drep-scriptHash-\(.[0].scriptHash)" end]' <<< "${drep_state_all}") || return 1
  all_drep_vote_power=$(jq -cr --argjson active_drep_ids "${active_drep_ids}" 'with_entries(.key as $key | select($key == "drep-alwaysAbstain" or $key == "drep-alwaysNoConfidence" or ($active_drep_ids | index($key))))' <<< "${all_drep_vote_power_raw}") || return 1
}

# Command     : getWalletVoteDelegation [wallet name] [force]
# Description : check vote delegation status
# Parameters  : wallet name  >  the name of the wallet
# Return      : populates ${vote_delegation}
getWalletVoteDelegation() {
  unset vote_delegation
  if isWalletRegistered $1; then
    if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
      vote_delegation=${vote_delegations[${reward_addr}]}
    fi
    [[ -n ${vote_delegation} ]] && return 0
  fi
  return 1
}

# Command     : getGovAction [tx_id] [index]
# Description : fetch governance action information by id (cli format)
# Return      : populates ${vote_action} ${proposal_url} ${proposal_hash} ${proposal_type} ${isParameterSecurityGroup}
#             : 0 = ok, 1 = action not found, 2 = invalid url or content, 3 = hash doesn't match
getGovAction() {
  unset vote_action proposal_url proposal_hash proposal_meta_file proposal_type
  [[ -z $1 || -z $2 ]] && return 1
  isParameterSecurityGroup=N
  isNetworkGroup=N
  isEconomicGroup=N
  isTechnicalGroup=N
  isGovernanceGroup=N
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "accept: application/json")
    println ACTION "curl -sSL -f -X GET ${HEADERS[*]} ${KOIOS_API}/proposal_list?proposal_tx_hash=eq.${1}&proposal_index=eq.${2}"
    ! vote_action=$(curl -sSL -f -X GET "${HEADERS[@]}" "${KOIOS_API}/proposal_list?proposal_tx_hash=eq.${1}&proposal_index=eq.${2}" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${vote_action}\n" && return 1 # print error and return
    [[ ${vote_action} = '[]' ]] && return 1
    vote_action=$(jq -er .[0] <<< "${vote_action}")
    IFS=',' read -r proposal_url proposal_hash proposal_type < <( jq -cr '"\(.meta_url//""),\(.meta_hash//""),\(.proposal_type//"")"' <<< "${vote_action}" )
    [[ ${proposal_type} = "ParameterChange" ]] && parameterChange=$(jq -e '.param_proposal | keys[]' <<< "${vote_action}") && getParameterChangeGroups
  elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
    println ACTION "${CCLI} latest query gov-state ${NETWORK_IDENTIFIER} | jq -r --arg govActionId \"$1\" 'first(.proposals | to_entries[] | select(.value.actionId.txId | contains(\$govActionId))) | .value'"
    vote_action=$(${CCLI} latest query gov-state ${NETWORK_IDENTIFIER} | jq -r --arg govActionId "$1" 'first(.proposals | to_entries[] | select(.value.actionId.txId | contains($govActionId))) | .value')
    [[ -z ${vote_action} ]] && return 1
    IFS=',' read -r proposal_url proposal_hash proposal_type < <( jq -cr '"\(.proposalProcedure.anchor.url//""),\(.proposalProcedure.anchor.dataHash//""),\(.proposalProcedure.govAction.tag//"")"' <<< "${vote_action}" )
    [[ ${proposal_type} = "ParameterChange" ]] && parameterChange=$(jq -e '.proposalProcedure.govAction.contents[1] | keys[]' <<< "${vote_action}") && getParameterChangeGroups
  else
    return 1
  fi
  if [[ -n ${proposal_url} ]]; then
    proposal_meta_file="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
    [[ "${proposal_url}" = ipfs://* ]] && _proposal_url="https://ipfs.io/ipfs/${proposal_url:7}" || _proposal_url="${proposal_url}"
    [[ ! "${_proposal_url}" =~ https?://.* ]] && return 2
    if ! curl -sL -m ${CURL_TIMEOUT} -o "${proposal_meta_file}" ${_proposal_url}; then
      [[ -f "${proposal_meta_file}" ]] && rm -f "${proposal_meta_file}"
      return 2
    fi
    println ACTION "${CCLI} hash anchor-data --file-text ${proposal_meta_file}"
    proposal_meta_hash="$(${CCLI} hash anchor-data --file-text "${proposal_meta_file}")"
    [[ ${proposal_meta_hash} != "${proposal_hash}" ]] && return 3
  fi
  return 0
}

# Command     : getActiveGovActionCount
# Return      : get a count of currently active governance actions
getActiveGovActionCount() {
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    unset response
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "accept: text/csv")
    println ACTION "curl -sSL -f -X GET ${HEADERS[*]} ${KOIOS_API}/proposal_list?select=count()&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null"
    response=$(curl -sSL -f -X GET "${HEADERS[@]}" "${KOIOS_API}/proposal_list?select=count()&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null" 2>&1) || return 1
    vote_action_count=$(tail -n +2 <<< ${response})
  else
    println ACTION "${CCLI} latest query gov-state ${NETWORK_IDENTIFIER} | jq -er '.proposals | length'"
    vote_action_count=$(${CCLI} latest query gov-state ${NETWORK_IDENTIFIER} | jq -er '.proposals | length' 2>/dev/null)
    [[ -z ${vote_action_count} ]] && return 1
  fi
  return 0
}

# Command     : getAllGovActions
# Parameters  : 1: [int]   number of entries to fetch
#             : 2: [int]   offset
#             : 3: [true]  fetch new list of proposals
#             :    [false] re-use existing data (if any)
# Return      : csv array of governance actions with different data depending on LIGHT VS LOCAL mode
getAllGovActions() {
  unset vote_action_list _vote_action_summary _vote_action_votes own_drep_votes own_spo_votes own_cc_votes
  if ! isNumber ${1} || ! isNumber ${2}; then return 1; fi
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    if [[ -n $3 && $3 == true ]]; then
      unset vote_action_list_all
      getCurrentCommittee; getParameterThresholds # to fetch thresholds
      HEADERS=("${KOIOS_API_HEADERS[@]}" -H "accept: text/csv")
      println ACTION "curl -sSL -f -X GET ${HEADERS[*]} ${KOIOS_API}/proposal_list?select=block_time,ratified_epoch,enacted_epoch,dropped_epoch,expired_epoch,proposal_id,proposal_tx_hash,proposal_index,proposal_type,proposed_epoch,expiration,meta_url,param_proposal&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null&order=block_time.desc"
      vote_action_list_all=$(curl -sSL -f -X GET "${HEADERS[@]}" "${KOIOS_API}/proposal_list?select=block_time,ratified_epoch,enacted_epoch,dropped_epoch,expired_epoch,proposal_id,proposal_tx_hash,proposal_index,proposal_type,proposed_epoch,expiration,meta_url,param_proposal&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null&order=block_time.desc" 2>&1) || return 1
    fi
    vote_action_list=()
    idx=-1
    while IFS=',' read -r _block_time _ratified_epoch _enacted_epoch _dropped_epoch _expired_epoch _proposal_id _proposal_tx_hash _proposal_index _proposal_type _proposed_epoch _expiration _meta_url _param_proposal; do
      ((idx++))
      [[ ${idx} -lt ${2} ]] && continue
      [[ ${idx} -ge $(( ${2} + ${1} )) ]] && break
      println ACTION "curl -sSL -f -X GET ${HEADERS[*]} ${KOIOS_API}/proposal_voting_summary?_proposal_id=${_proposal_id}&select=drep_yes_votes_cast,drep_yes_vote_power,drep_yes_pct,drep_no_votes_cast,drep_no_vote_power,drep_no_pct,pool_yes_votes_cast,pool_yes_vote_power,pool_yes_pct,pool_no_votes_cast,pool_no_vote_power,pool_no_pct,committee_yes_votes_cast,committee_yes_pct,committee_no_votes_cast,committee_no_pct"
      _vote_action_summary=$(curl -sSL -f -X GET "${HEADERS[@]}" "${KOIOS_API}/proposal_voting_summary?_proposal_id=${_proposal_id}&select=drep_yes_votes_cast,drep_yes_vote_power,drep_yes_pct,drep_no_votes_cast,drep_no_vote_power,drep_no_pct,pool_yes_votes_cast,pool_yes_vote_power,pool_yes_pct,pool_no_votes_cast,pool_no_vote_power,pool_no_pct,committee_yes_votes_cast,committee_yes_pct,committee_no_votes_cast,committee_no_pct" 2>&1) || continue
      IFS=',' read -r drep_yes_votes_cast drep_yes_vote_power drep_yes_pct drep_no_votes_cast drep_no_vote_power drep_no_pct pool_yes_votes_cast pool_yes_vote_power pool_yes_pct pool_no_votes_cast pool_no_vote_power pool_no_pct committee_yes_votes_cast committee_yes_pct committee_no_votes_cast committee_no_pct <<< "$(tail -n +2 <<< ${_vote_action_summary})"
      drep_yes_pct=$(printf '%.2f' "${drep_yes_pct}" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      drep_no_pct=$(printf '%.2f' "${drep_no_pct}" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      pool_yes_pct=$(printf '%.2f' "${pool_yes_pct}" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      pool_no_pct=$(printf '%.2f' "${pool_no_pct}" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      committee_yes_pct=$(printf '%.2f' "${committee_yes_pct}" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      committee_no_pct=$(printf '%.2f' "${committee_no_pct}" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      isParameterSecurityGroup=N
      if [[ ${_proposal_type} = "ParameterChange" ]]; then
        param_proposal_unescaped=${_param_proposal:1: -1} # remove first and last char (quotation)
        param_proposal_unescaped=$(sed 's/""/"/g' <<< "${param_proposal_unescaped}") # remove all double quotes, sed seems to perform better than bash string manipulation
        parameterChange=$(jq -e '. | keys[]' <<< "${param_proposal_unescaped}")
        getParameterChangeGroups
      fi
      getVoteThreshold ${_proposal_type}
      println ACTION "curl -sSL -f -X GET ${HEADERS[*]} ${KOIOS_API}/proposal_votes?_proposal_id=${_proposal_id}&select=voter_role,voter_hex,vote"
      _vote_action_votes=$(curl -sSL -f -X GET "${HEADERS[@]}" "${KOIOS_API}/proposal_votes?_proposal_id=${_proposal_id}&select=voter_role,voter_hex,vote" 2>&1) || continue
      while IFS= read -r -d '' wallet; do
        wallet_name=$(basename ${wallet})
        getGovKeyInfo ${wallet_name}
        while IFS= read -r vote; do
          IFS=',' read -ra vote_arr <<< "${vote}"
          [[ ${vote_arr[0]} = DRep && ${vote_arr[1]} = "${drep_hash}" ]] && own_drep_votes+=( "${_proposal_tx_hash}#${_proposal_index};${wallet_name};${vote_arr[2]}" )
          [[ ${vote_arr[0]} = ConstitutionalCommittee && ${vote_arr[1]} = "${cc_hot_hash}" ]] && own_cc_votes+=( "${_proposal_tx_hash}#${_proposal_index};${wallet_name};${vote_arr[2]}" )
        done <<< "${_vote_action_votes}"
      done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
      while IFS= read -r -d '' pool; do
        pool_name=$(basename ${pool})
        getPoolID ${pool_name} || continue
        while IFS= read -r vote; do
          IFS=',' read -ra vote_arr <<< "${vote}"
          [[ ${vote_arr[0]} = SPO && ${vote_arr[1]} = "${pool_id}" ]] && own_spo_votes+=( "${_proposal_tx_hash}#${_proposal_index};${pool_name};${vote_arr[2]}" ) && continue 2
        done <<< "${_vote_action_votes}"
      done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
      vote_action_list+=( "${_proposal_tx_hash}#${_proposal_index},${_proposal_type},${_proposed_epoch},$((_expiration-1)),${_meta_url},${drep_yes_votes_cast},${drep_yes_vote_power},${drep_yes_pct},${drep_no_votes_cast},${drep_no_vote_power},${drep_no_pct},${pool_yes_votes_cast},${pool_yes_vote_power},${pool_yes_pct},${pool_no_votes_cast},${pool_no_vote_power},${pool_no_pct},${committee_yes_votes_cast},${committee_yes_pct},${committee_no_votes_cast},${committee_no_pct},${drep_vt},${spo_vt},${cc_vt},${isParameterSecurityGroup}" )
    done <<< "$(tail -n +2 <<< ${vote_action_list_all})"
  elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
    if [[ -n $3 && $3 == true ]]; then
      unset vote_action_list_all _vote_action_list
      vote_action_list_all=()
      getCurrentCommittee; getParameterThresholds # to fetch thresholds
      # get current DRep distribution excluding DReps whose expiry is behind the current epoch
      getLocalActiveDRepStakeDistribution || return 1
      # sum of all drep stake distribution entries without the alwaysAbstain
      drep_power_total=$(jq -r '[.[]] | add' <<< "${all_drep_vote_power}" 2>/dev/null)
      drep_power_always_abstain=$(jq -r '."drep-alwaysAbstain" //0' <<< "${all_drep_vote_power}" 2>/dev/null)
      # get current Pool distribution
      println ACTION "${CCLI} latest query spo-stake-distribution --all-spos ${NETWORK_IDENTIFIER}"
      all_spo_vote_power=$(${CCLI} latest query spo-stake-distribution --all-spos ${NETWORK_IDENTIFIER})
      spo_power_total=$(jq -r '[.[][1]] | add' <<< "${all_spo_vote_power}" 2>/dev/null)
      # get committee vote power (sum of authorized committee members)
      cc_power_authorized=$(jq -r 'reduce(select(.committee[].hotCredsAuthStatus.tag|strings=="MemberAuthorized")) as $_ (0; .+1)' <<< "${committee_info}")
      println ACTION "${CCLI} latest query gov-state ${NETWORK_IDENTIFIER} | jq -er '.proposals[] | @base64'"
      _vote_action_list=()
      while IFS= read -r _vote_action; do
        _vote_action_list+=( "${_vote_action}" )
      done < <(${CCLI} latest query gov-state ${NETWORK_IDENTIFIER} | jq -er '.proposals[] | @base64' 2>/dev/null)
      # reverse order
      for ((i=${#_vote_action_list[@]}-1; i>=0; i--)); do
        vote_action_list_all+=( "${_vote_action_list[$i]}" )
      done
    fi
    vote_action_list=()
    for vote_action in "${vote_action_list_all[@]:${2}:${1}}"; do
      IFS=',' read -r proposal_id proposal_type proposed_epoch expiration meta_url drep_yes_votes_cast drep_no_votes_cast spo_yes_votes_cast spo_no_votes_cast cc_yes_votes_cast cc_no_votes_cast < <( jq -cr '"\((.actionId.txId//"") + "#" + (.actionId.govActionIx//0|tostring)),\(.proposalProcedure.govAction.tag//""),\(.proposedIn//0),\(.expiresAfter//0),\(.proposalProcedure.anchor.url//""),\(.dRepVotes | reduce(..|select(strings=="VoteYes")) as $_ (0; .+1)),\(.dRepVotes | reduce(..|select(strings=="VoteNo")) as $_ (0; .+1)),\(.stakePoolVotes | reduce(..|select(strings=="VoteYes")) as $_ (0; .+1)),\(.stakePoolVotes | reduce(..|select(strings=="VoteNo")) as $_ (0; .+1)),\(.committeeVotes | reduce(..|select(strings=="VoteYes")) as $_ (0; .+1)),\(.committeeVotes | reduce(..|select(strings=="VoteNo")) as $_ (0; .+1))"' <<< "$(base64 -d <<< "${vote_action}")" )
      isParameterSecurityGroup=N
      if [[ $(jq -r '.proposalProcedure.govAction.tag' <<< "$(base64 -d <<< "${vote_action}")") = "ParameterChange" ]]; then
        parameterChange=$(jq -e '.proposalProcedure.govAction.contents[1] | keys[]' <<< "$(base64 -d <<< "${vote_action}")")
        getParameterChangeGroups
      fi
      getVoteThreshold "$(jq -r '.proposalProcedure.govAction.tag' <<< "$(base64 -d <<< "${vote_action}")")"

      # get list of drep voters based on vote
      drep_yes_voters="$(jq '[.dRepVotes | to_entries[] | select(.value=="VoteYes") | ("drep-" + .key)]' <<< "$(base64 -d <<< "${vote_action}")")"
      drep_no_voters="$(jq '[.dRepVotes | to_entries[] | select(.value=="VoteNo") | ("drep-" + .key)]' <<< "$(base64 -d <<< "${vote_action}")")"
      drep_abstain_voters="$(jq '[.dRepVotes | to_entries[] | select(.value=="Abstain") | ("drep-" + .key)]' <<< "$(base64 -d <<< "${vote_action}")")"
      # get sum of vote power for each type
      drep_yes_vote_power="$(jq -r --argjson v "${drep_yes_voters}" '[to_entries[] | select(.key | IN($v[])) | .value] | add //0' <<< "${all_drep_vote_power}")"
      drep_no_vote_power="$(jq -r --argjson v "${drep_no_voters}" '[to_entries[] | select(.key | IN($v[])) | .value] | add //0' <<< "${all_drep_vote_power}")"
      drep_abstain_vote_power="$(jq -r --argjson v "${drep_abstain_voters}" '[to_entries[] | select(.key | IN($v[])) | .value] | add //0' <<< "${all_drep_vote_power}")"
      drep_power_total_no_abstain=$(( drep_power_total - drep_power_always_abstain - drep_abstain_vote_power ))
      drep_no_vote_power_total=$(( drep_power_total_no_abstain - drep_yes_vote_power )) # total drep power - always abstain - proposal abstain - proposal yes
      if [[ ${proposal_type} = "NoConfidence" ]]; then
        # add alwaysNoConfidence power to yes vote
        drep_power_always_no_confidence="$(jq -r '."drep-alwaysNoConfidence" //0' <<< "${all_drep_vote_power}" 2>/dev/null)"
        drep_yes_vote_power=$(( drep_yes_vote_power + drep_power_always_no_confidence ))
        drep_no_vote_power_total=$(( drep_no_vote_power_total - (drep_power_always_no_confidence * 2) ))
      fi
      # calculate percentages
      drep_yes_pct=$(printf '%.2f' "$(bc -l <<< "(${drep_yes_vote_power}/${drep_power_total_no_abstain})*100")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      drep_no_pct=$(printf '%.2f' "$(bc -l <<< "(${drep_no_vote_power_total}/${drep_power_total_no_abstain})*100")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      # find votes by own DReps
      while IFS= read -r -d '' wallet; do
        wallet_name=$(basename ${wallet})
        getGovKeyInfo ${wallet_name}
        [[ -z ${drep_hash} ]] && continue
        for drep in "${drep_yes_voters[@]}"; do
          [[ ${drep} = *"${hash_type}-${drep_hash}"* ]] && own_drep_votes+=( "${proposal_id};${wallet_name};Yes" ) && continue 2
        done
        for drep in "${drep_no_voters[@]}"; do
          [[ ${drep} = *"${hash_type}-${drep_hash}"* ]] && own_drep_votes+=( "${proposal_id};${wallet_name};No" ) && continue 2
        done
        for drep in "${drep_abstain_voters[@]}"; do
          [[ ${drep} = *"${hash_type}-${drep_hash}"* ]] && own_drep_votes+=( "${proposal_id};${wallet_name};Abstain" ) && continue 2
        done
      done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

      # get list of spo voters based on vote
      spo_yes_voters="$(jq '[.stakePoolVotes | to_entries[] | select(.value=="VoteYes") | .key]' <<< "$(base64 -d <<< "${vote_action}")")"
      spo_no_voters="$(jq '[.stakePoolVotes | to_entries[] | select(.value=="VoteNo") | .key]' <<< "$(base64 -d <<< "${vote_action}")")"
      spo_abstain_voters="$(jq '[.stakePoolVotes | to_entries[] | select(.value=="Abstain") | .key]' <<< "$(base64 -d <<< "${vote_action}")")"
      # always abstain for reward address that haven't voted
      spo_power_always_abstain=$(jq -r --argjson v1 "${spo_yes_voters}" --argjson v2 "${spo_no_voters}" --argjson v3 "${spo_abstain_voters}" '[to_entries[] | select(.value[2] == "drep-alwaysAbstain") | select(.value[0] | IN($v1[]) | not) | select(.value[0] | IN($v2[]) | not) | select(.value[0] | IN($v3[]) | not) | .value[1]] | add //0' <<< "${all_spo_vote_power}" 2>/dev/null)
      # get sum of vote power for each type
      spo_yes_vote_power="$(jq -r --argjson v "${spo_yes_voters}" '[to_entries[] | select(.value[0] | IN($v[])) | .value[1]] | add //0' <<< "${all_spo_vote_power}")"
      spo_no_vote_power="$(jq -r --argjson v "${spo_no_voters}" '[to_entries[] | select(.value[0] | IN($v[])) | .value[1]] | add //0' <<< "${all_spo_vote_power}")"
      spo_abstain_vote_power="$(jq -r --argjson v "${spo_abstain_voters}" '[to_entries[] | select(.value[0] | IN($v[])) | .value[1]] | add //0' <<< "${all_spo_vote_power}")"
      spo_power_total_no_abstain=$(( spo_power_total - spo_power_always_abstain - spo_abstain_vote_power ))
      spo_no_vote_power_total=$(( spo_power_total_no_abstain - spo_yes_vote_power )) # total spo power - proposal abstain - proposal yes
      if [[ ${proposal_type} = "NoConfidence" ]]; then
        # add alwaysNoConfidence power to yes vote
        spo_power_always_no_confidence=$(jq -r --argjson v1 "${spo_yes_voters}" --argjson v2 "${spo_no_voters}" --argjson v3 "${spo_abstain_voters}" '[to_entries[] | select(.value[2] == "drep-alwaysNoConfidence") | select(.value[0] | IN($v1[]) | not) | select(.value[0] | IN($v2[]) | not) | select(.value[0] | IN($v3[]) | not) | .value[1]] | add //0' <<< "${all_spo_vote_power}" 2>/dev/null)
        spo_yes_vote_power=$(( spo_yes_vote_power + spo_power_always_no_confidence ))
        spo_no_vote_power_total=$(( spo_no_vote_power_total - (spo_power_always_no_confidence * 2) ))
      fi
      # calculate percentages
      spo_yes_pct=$(printf '%.2f' "$(bc -l <<< "(${spo_yes_vote_power}/${spo_power_total_no_abstain})*100")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      spo_no_pct=$(printf '%.2f' "$(bc -l <<< "(${spo_no_vote_power_total}/${spo_power_total_no_abstain})*100")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      # find votes by own pools
      while IFS= read -r -d '' pool; do
        pool_name=$(basename ${pool})
        getPoolID ${pool_name} || continue
        for spo in "${spo_yes_voters[@]}"; do
          [[ ${spo} = *"${pool_id}"* ]] && own_spo_votes+=( "${proposal_id};${pool_name};Yes" ) && continue 2
        done
        for spo in "${spo_no_voters[@]}"; do
          [[ ${spo} = *"${pool_id}"* ]] && own_spo_votes+=( "${proposal_id};${pool_name};No" ) && continue 2
        done
        for spo in "${spo_abstain_voters[@]}"; do
          [[ ${spo} = *"${pool_id}"* ]] && own_spo_votes+=( "${proposal_id};${pool_name};Abstain" ) && continue 2
        done
      done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

      # get list of cc voters based on vote
      cc_yes_voters="$(jq '[.committeeVotes | to_entries[] | select(.value=="VoteYes")] | length' <<< "$(base64 -d <<< "${vote_action}")")"
      cc_no_voters="$(jq '[.committeeVotes | to_entries[] | select(.value=="VoteNo")] | length' <<< "$(base64 -d <<< "${vote_action}")")"
      cc_abstain_voters="$(jq '[.committeeVotes | to_entries[] | select(.value=="Abstain")] | length' <<< "$(base64 -d <<< "${vote_action}")")"
      cc_power_total=$(( cc_power_authorized - cc_abstain_voters ))
      cc_no_voters_total=$(( cc_power_total - cc_yes_voters )) # total cc power - proposal abstain - proposal yes
      # calculate percentages
      if [[ ${cc_power_total} -eq 0 ]]; then
        cc_yes_pct=0
        cc_no_pct=0
      else
        cc_yes_pct=$(printf '%.2f' "$(bc -l <<< "(${cc_yes_voters}/${cc_power_total})*100")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
        cc_no_pct=$(printf '%.2f' "$(bc -l <<< "(${cc_no_voters_total}/${cc_power_total})*100")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
      fi
      while IFS= read -r -d '' wallet; do
        wallet_name=$(basename ${wallet})
        getGovKeyInfo ${wallet_name}
        [[ -z ${cc_hot_hash} ]] && continue
        for cc_hot in "${cc_yes_voters[@]}"; do
          [[ ${cc_hot} = *"${cc_hot_hash}"* ]] && own_cc_votes+=( "${proposal_id};${wallet_name};Yes" ) && continue 2
        done
        for cc_hot in "${cc_no_voters[@]}"; do
          [[ ${cc_hot} = *"${cc_hot_hash}"* ]] && own_cc_votes+=( "${proposal_id};${wallet_name};No" ) && continue 2
        done
        for cc_hot in "${cc_abstain_voters[@]}"; do
          [[ ${cc_hot} = *"${cc_hot_hash}"* ]] && own_cc_votes+=( "${proposal_id};${wallet_name};Abstain" ) && continue 2
        done
      done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

      vote_action_list+=( "${proposal_id},${proposal_type},${proposed_epoch},${expiration:=0},${meta_url},${drep_yes_votes_cast},${drep_yes_vote_power},${drep_yes_pct},${drep_no_votes_cast},${drep_no_vote_power_total},${drep_no_pct},${spo_yes_votes_cast},${spo_yes_vote_power},${spo_yes_pct},${spo_no_votes_cast},${spo_no_vote_power_total},${spo_no_pct},${cc_yes_votes_cast},${cc_yes_pct},${cc_no_votes_cast},${cc_no_pct},${drep_vt},${spo_vt},${cc_vt},${isParameterSecurityGroup}" )
    done
  fi
}

# Command     : getParameterChangeGroups
# Description : assumed parameterChange is populated with list of parameter changes, including quotation marks
# Return      : sets isParameterSecurityGroup isNetworkGroup isEconomicGroup isTechnicalGroup isGovernanceGroup
getParameterChangeGroups() {
  unset isParameterSecurityGroup isNetworkGroup isEconomicGroup isTechnicalGroup isGovernanceGroup
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    [[ $parameterChange =~ (\"max_block_size\"|\"max_tx_size\"|\"max_bh_size\"|\"max_val_size\"|\"max_block_ex_|\"min_fee_a\"|\"min_fee_b\"|\"coins_per_utxo_size\"|\"gov_action_deposit\"|\"min_fee_ref_script_cost_per_byte\") ]] && isParameterSecurityGroup=Y
    [[ $parameterChange =~ (\"max_block_size\"|\"max_tx_size\"|\"max_bh_size\"|\"max_val_size\"|\"max_tx_ex_|\"max_block_ex_|\"max_collateral_inputs\") ]] && isNetworkGroup=Y
    [[ $parameterChange =~ (\"min_fee_a\"|\"min_fee_b\"|\"key_deposit\"|\"pool_deposit\"|\"monetary_expand_rate\"|\"treasury_growth_rate\"|\"min_pool_cost\"|\"coins_per_utxo_size\"|\"coins_per_utxo_size\"|\"price_) ]] && isEconomicGroup=Y
    [[ $parameterChange =~ (\"influence\"|\"max_epoch\"|\"optimal_pool_count\"|\"cost_model_id\"|\"collateral_percent\") ]] && isTechnicalGroup=Y
    [[ $parameterChange =~ (\"gov_action_lifetime\"|\"gov_action_deposit\"|\"drep_deposit\"|\"drep_activity\"|\"committee_min_size\"|\"committee_max_term_length\"|\"pvt_|\"dvt_) ]] && isGovernanceGroup=Y
  elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
    [[ $parameterChange =~ (\"maxBlockBodySize\"|\"maxTxSize\"|\"maxBlockHeaderSize\"|\"maxValueSize\"|\"maxBlockExecutionUnits\"|\"txFeePerByte\"|\"txFeeFixed\"|\"utxoCostPerByte\"|\"govActionDeposit\"|\"minFeeRefScriptCostPerByte\") ]] && isParameterSecurityGroup=Y
    [[ $parameterChange =~ (\"maxBlockBodySize\"|\"maxTxSize\"|\"maxBlockHeaderSize\"|\"maxValueSize\"|\"maxTxExecutionUnits\"|\"maxBlockExecutionUnits\"|\"maxCollateralInputs\") ]] && isNetworkGroup=Y
    [[ $parameterChange =~ (\"txFeePerByte\"|\"txFeeFixed\"|\"stakeAddressDeposit\"|\"stakePoolDeposit\"|\"monetaryExpansion\"|\"treasuryCut\"|\"minPoolCost\"|\"utxoCostPerByte\"|\"executionUnitPrices\") ]] && isEconomicGroup=Y
    [[ $parameterChange =~ (\"poolPledgeInfluence\"|\"poolRetireMaxEpoch\"|\"stakePoolTargetNum\"|\"costModels\"|\"collateralPercentage\") ]] && isTechnicalGroup=Y
    [[ $parameterChange =~ (\"govActionLifetime\"|\"govActionDeposit\"|\"dRepDeposit\"|\"dRepActivity\"|\"committeeMinSize\"|\"committeeMaxTermLength\"|\"VotingThresholds\") ]] && isGovernanceGroup=Y
  fi
}

# Command     : getVoteThreshold [type]
# Description : assumed getCurrentCommittee, getParameterThresholds & getParameterChangeGroups are called before this one
# Return      : Threshold for each type returned as a percentage. '-' if not valid for type.
getVoteThreshold() {
  case ${1} in
    "InfoAction") unset drep_vt spo_vt cc_vt ;; # no thresholds
    "NoConfidence")
      drep_vt=${dvt_motionNoConf}
      spo_vt=${pvt_motionNoConf}
      unset cc_vt
      ;;
    "HardForkInitiation")
      drep_vt=${dvt_HFInit}
      spo_vt=${pvt_HFInit}
      cc_vt=${cc_threshold}
      ;;
    "NewCommittee"|"UpdateCommittee")
      # TODO: Are we in Normal or NoConfidence state?
      drep_vt=${dvt_newCCNormal}
      spo_vt=${pvt_newCCNormal}
      unset cc_vt
      ;;
    "TreasuryWithdrawals")
      drep_vt=${dvt_treasuryWithdrawal}
      unset spo_vt
      cc_vt=${cc_threshold}
      ;;
    "ParameterChange")
      if versionCheck "10.0" "${PROT_VERSION}"; then
        # get highest of matching groups
        drep_vt=0
          if [[ ${isNetworkGroup} = Y ]]    && (( $(bc -l <<< "${dvt_ppNetGrp}  > ${drep_vt}") )); then drep_vt=${dvt_ppNetGrp}
        elif [[ ${isEconomicGroup} = Y ]]   && (( $(bc -l <<< "${dvt_ppEcoGrp}  > ${drep_vt}") )); then drep_vt=${dvt_ppEcoGrp}
        elif [[ ${isTechnicalGroup} = Y ]]  && (( $(bc -l <<< "${dvt_ppTechGrp} > ${drep_vt}") )); then drep_vt=${dvt_ppTechGrp}
        elif [[ ${isGovernanceGroup} = Y ]] && (( $(bc -l <<< "${dvt_ppGovGrp}  > ${drep_vt}") )); then drep_vt=${dvt_ppGovGrp}
        else unset drep_vt
        fi
      else
        unset drep_vt
      fi
      [[ ${isParameterSecurityGroup} = Y ]] && spo_vt=${pvt_ppSecGrp} || unset spo_vt
      cc_vt=${cc_threshold}
      ;;
    "NewConstitution")
      drep_vt=${dvt_newConst}
      unset spo_vt
      cc_vt=${cc_threshold}
      ;;
  esac
}

# Command     : isAllowedToVote [role] [type] [isParameterSecurityGroup (Y|N)]
# Return      : 0 = ok
#               1 = not allowed by role
#               2 = parameter change not of type Security Group
#               3 = chang-1 limitation
isAllowedToVote() {
  [[ -z $1 || -z $2 || -z $3 ]] && return 1
  case ${2} in
    "NoConfidence")
      [[ $1 = committee ]] && return 1
      ;;
    "HardForkInitiation")
      [[ $1 = drep ]] && ! versionCheck "10.0" "${PROT_VERSION}" && return 3
      ;;
    "InfoAction")
      : ;; # always allowed by all
    "NewCommittee"|"UpdateCommittee")
      [[ $1 = committee ]] && return 1
      ;;
    "TreasuryWithdrawals")
      [[ $1 = spo ]] && return 1
      ;;
    "ParameterChange")
      [[ $1 = spo && $3 = N ]] && return 2
      [[ $1 = drep ]] && ! versionCheck "10.0" "${PROT_VERSION}" && return 3
      ;;
    "NewConstitution")
      [[ $1 = spo ]] && return 1
      ;;
  esac
  return 0
}

# Command     : getParameterThresholds
# Description : fetches DRep / SPO thresholds from PROT_PARAMS into variables
getParameterThresholds() {
  read -r dvt_newCCNoConf dvt_newCCNormal dvt_HFInit dvt_motionNoConf dvt_ppEcoGrp dvt_ppGovGrp dvt_ppNetGrp dvt_ppTechGrp dvt_treasuryWithdrawal dvt_newConst pvt_newCCNoConf pvt_newCCNormal pvt_HFInit pvt_motionNoConf pvt_ppSecGrp <<<"$(jq -r '[
    (.dRepVotingThresholds.committeeNoConfidence //0) * 100,
    (.dRepVotingThresholds.committeeNormal //0) * 100,
    (.dRepVotingThresholds.hardForkInitiation //0) * 100,
    (.dRepVotingThresholds.motionNoConfidence //0) * 100,
    (.dRepVotingThresholds.ppEconomicGroup //0) * 100,
    (.dRepVotingThresholds.ppGovGroup //0) * 100,
    (.dRepVotingThresholds.ppNetworkGroup //0) * 100,
    (.dRepVotingThresholds.ppTechnicalGroup //0) * 100,
    (.dRepVotingThresholds.treasuryWithdrawal //0) * 100,
    (.dRepVotingThresholds.updateToConstitution //0) * 100,
    (.poolVotingThresholds.committeeNoConfidence //0) * 100,
    (.poolVotingThresholds.committeeNormal //0) * 100,
    (.poolVotingThresholds.hardForkInitiation //0) * 100,
    (.poolVotingThresholds.motionNoConfidence //0) * 100,
    (.poolVotingThresholds.ppSecurityGroup //0) * 100
    ] | @tsv' <<<"${PROT_PARAMS}" 2>/dev/null)"
}

# Command     : getCurrentCommittee
# Return      : 0 = valid member, 1 = not a member, 2 = not authorized
getCurrentCommittee() {
  unset committee_info
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "accept: application/json")
    println ACTION "curl -sSL -f -X GET ${HEADERS[*]} ${KOIOS_API}/committee_info"
    committee_info=$(curl -sSL -f -X GET "${HEADERS[@]}" "${KOIOS_API}/committee_info")
    cc_threshold=$(printf '%.2f' "$(jq -r '(.[0].quorum_numerator //0) / (.[0].quorum_denominator //1) * 100' <<< "${committee_info}")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
  elif [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
    println ACTION "${CCLI} latest query committee-state ${NETWORK_IDENTIFIER}"
    committee_info=$(${CCLI} latest query committee-state ${NETWORK_IDENTIFIER})
    cc_threshold=$(printf '%.2f' "$(jq -r '(.threshold.numerator //0) / (.threshold.denominator //1) * 100' <<< "${committee_info}")" | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
  fi
}

# Command     : isCommitteeMember [cold hash] [hot hash]
# Description : check if supplied hash is part of current committee list
# Return      : 0 = valid member, 1 = not a member, 2 = not authorized, 3 = resigned
isCommitteeMember() {
  [[ -z $1 || -z $2 ]] && return 1
  getCurrentCommittee
  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    grep -q $1 <<< "${committee_info}" || return 1
    grep -q resigned <<< "${committee_info}" && return 3
    grep -q $2 <<< "${committee_info}" || return 2
  else
    committee_member=$(jq -r --arg cc_cold_hash "$1" 'first(.committee | to_entries[] | select(.key | contains($cc_cold_hash))) | .value' <<< "${committee_info}")
    [[ -z ${committee_member} ]] && return 1
    grep -i -q resigned <<< "${committee_member}" && return 3
    grep -q $2 <<< "$(jq -r '.hotCredsAuthStatus.contents // [] | .[]' <<< "$committee_member")" || return 1
  fi
  return 0
}

