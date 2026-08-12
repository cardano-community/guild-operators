# Command     : getBaseAddress [wallet name] | [payment.vkey] [stake.vkey]
# Description : create, store and save base address
# Parameters  : wallet name  >  the name of the wallet
# Return      : populates ${base_addr}
getBaseAddress() {
  payment_vk_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_VK_FILENAME}"
  stake_vk_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_VK_FILENAME}"
  payment_script_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_SCRIPT_FILENAME}"
  stake_script_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_SCRIPT_FILENAME}"
  base_addr_file="${WALLET_FOLDER}/${1}/${WALLET_BASE_ADDR_FILENAME}"
  [[ -f ${base_addr_file} ]] && base_addr=$(cat "${base_addr_file}") && return 0
  unset base_addr
  if [[ -f "${payment_vk_file}" && -f "${stake_vk_file}" ]]; then
    println ACTION "${CCLI} address build --payment-verification-key-file ${payment_vk_file} --stake-verification-key-file ${stake_vk_file} --out-file ${base_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} address build --payment-verification-key-file "${payment_vk_file}" --stake-verification-key-file "${stake_vk_file}" --out-file "${base_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      base_addr=$(cat "${base_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during base address creation!\n${stdout}"
    fi
  elif [[ -f "${payment_script_file}" && -f "${stake_script_file}" ]]; then
    println ACTION "${CCLI} address build --payment-script-file ${payment_script_file} --stake-script-file ${stake_script_file} --out-file ${base_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} address build --payment-script-file "${payment_script_file}" --stake-script-file "${stake_script_file}" --out-file "${base_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      base_addr=$(cat "${base_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during base address creation!\n${stdout}"
    fi
  elif [[ -f "${payment_script_file}" && -f "${stake_vk_file}" ]]; then
    println ACTION "${CCLI} address build --payment-script-file ${payment_script_file} --stake-verification-key-file ${stake_vk_file} --out-file ${base_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} address build --payment-script-file "${payment_script_file}" --stake-verification-key-file "${stake_vk_file}" --out-file "${base_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      base_addr=$(cat "${base_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during base address creation!\n${stdout}"
    fi
  elif [[ -f "${payment_vk_file}" && -f "${stake_script_file}" ]]; then
    println ACTION "${CCLI} address build --payment-verification-key-file ${payment_vk_file} --stake-script-file ${stake_script_file} --out-file ${base_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} address build --payment-verification-key-file "${payment_vk_file}" --stake-script-file "${stake_script_file}" --out-file "${base_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      base_addr=$(cat "${base_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during base address creation!\n${stdout}"
    fi
  elif [[ $# -eq 2 && -f "${1}" && -f "${2}" ]]; then
    println ACTION "${CCLI} address build --payment-verification-key-file ${1} --stake-verification-key-file ${2} ${NETWORK_IDENTIFIER}"
    if base_addr=$(${CCLI} address build --payment-verification-key-file "${1}" --stake-verification-key-file "${2}" ${NETWORK_IDENTIFIER} 2>&1); then
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during base address creation!\n${base_addr}"
    fi
  fi
  return 1
}

# Command     : getRewardAddress [wallet name]
# Description : create, store and save reward address
# Parameters  : wallet name  >  the name of the wallet
# Return      : populates ${reward_addr} ${is_reward_script_addr}
getRewardAddress() {
  unset reward_addr is_reward_script_addr
  stake_vk_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_VK_FILENAME}"
  stake_script_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_SCRIPT_FILENAME}"
  stake_addr_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_ADDR_FILENAME}"
  [[ -f "${stake_script_file}" ]] && is_reward_script_addr=true || is_reward_script_addr=false
  [[ -f ${stake_addr_file} ]] && reward_addr=$(cat "${stake_addr_file}") && return 0
  if [[ -f "${stake_vk_file}" ]]; then
    println ACTION "${CCLI} latest stake-address build --stake-verification-key-file ${stake_vk_file} --out-file ${stake_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} latest stake-address build --stake-verification-key-file "${stake_vk_file}" --out-file "${stake_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      reward_addr=$(cat "${stake_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during reward address creation!\n${stdout}"
    fi
  elif [[ -f "${stake_script_file}" ]]; then
    println ACTION "${CCLI} latest stake-address build --stake-script-file ${stake_script_file} --out-file ${stake_addr_file} ${NETWORK_IDENTIFIER}"
    if stdout=$(${CCLI} latest stake-address build --stake-script-file "${stake_script_file}" --out-file "${stake_addr_file}" ${NETWORK_IDENTIFIER} 2>&1); then
      reward_addr=$(cat "${stake_addr_file}")
      return 0
    else
      println LOG "\n${FG_RED}ERROR${NC}: failure during reward script address creation!\n${stdout}"
    fi
  elif [[ -f "${1}" ]]; then
    getRewardAddressFromKey ${1}
    return $?
  fi
  return 1
}

# Command     : getRewardAddressFromKey [stake vkey]
# Description : get reward address from a stake key
# Parameters  : stake key  >  path to stake.vkey file
# Return      : populates ${reward_addr}
getRewardAddressFromKey() {
  println ACTION "${CCLI} latest stake-address build --stake-verification-key-file ${1} ${NETWORK_IDENTIFIER}"
  if ! reward_addr=$(${CCLI} latest stake-address build --stake-verification-key-file "${1}" ${NETWORK_IDENTIFIER} 2>&1); then
    println LOG "\n${FG_RED}ERROR${NC}: failure during reward address creation!\n${base_addr}"
    return 1
  fi
}

# Command     : getCredential [type] [file]
# Description : create and save wallet credentials (key hash) for payment and stake keys (incl MultiSig)
# Parameters  : type  >  payment | stake | drep
#             : file  >  path to verification file
# Return      : populates ${cred}
getCredential() {
  unset cred
  [[ ! -f "$2" ]] && return 1
  if [[ $1 = drep ]]; then
    println ACTION "${CCLI} latest governance drep id --drep-verification-key-file $2 | bech32"
    if ! _drep_id=$(${CCLI} latest governance drep id --drep-verification-key-file "$2" 2>&1); then
      println LOG "\n${FG_RED}ERROR${NC}: failure during key hash creation!\n${cred}"
      unset cred
      return 1
    fi
    cred=$(bech32 <<< "${_drep_id}")
  else
    [[ $1 = payment ]] && CLI_ARGS=("--payment-verification-key-file" "$2") || CLI_ARGS=("--stake-verification-key-file" "$2")
    println ACTION "${CCLI} address key-hash ${CLI_ARGS[*]}"
    if ! cred=$(${CCLI} address key-hash "${CLI_ARGS[@]}" 2>&1); then
      println LOG "\n${FG_RED}ERROR${NC}: failure during key hash creation!\n${cred}"
      unset cred
      return 1
    fi
  fi
  return 0
}

# Command     : getCredentials [wallet name]
# Description : create and save wallet credentials (key hash) for payment and stake keys (incl MultiSig)
# Parameters  : wallet name  >  the name of the wallet
getCredentials() {
  unset pay_cred stake_cred ms_pay_cred ms_stake_cred script_pay_cred script_stake_cred
  payment_cred_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_CRED_FILENAME}"
  stake_cred_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_CRED_FILENAME}"
  ms_payment_cred_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}"
  ms_stake_cred_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"
  script_payment_cred_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_SCRIPT_CRED_FILENAME}"
  script_stake_cred_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_SCRIPT_CRED_FILENAME}"
  [[ -f ${payment_cred_file} ]] && pay_cred=$(cat "${payment_cred_file}")
  [[ -f ${stake_cred_file} ]] && stake_cred=$(cat "${stake_cred_file}")
  [[ -f ${ms_payment_cred_file} ]] && ms_pay_cred=$(cat "${ms_payment_cred_file}")
  [[ -f ${ms_stake_cred_file} ]] && ms_stake_cred=$(cat "${ms_stake_cred_file}")
  [[ -f ${script_payment_cred_file} ]] && script_pay_cred=$(cat "${script_payment_cred_file}")
  [[ -f ${script_stake_cred_file} ]] && script_stake_cred=$(cat "${script_stake_cred_file}")
  if [[ -z ${pay_cred} ]]; then
    payment_vk_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_VK_FILENAME}"
    if [[ -f "${payment_vk_file}" ]]; then
      println ACTION "${CCLI} address key-hash --payment-verification-key-file ${payment_vk_file} --out-file ${payment_cred_file}"
      if stdout=$(${CCLI} address key-hash --payment-verification-key-file "${payment_vk_file}" --out-file "${payment_cred_file}" 2>&1); then
        pay_cred=$(cat "${payment_cred_file}")
      else
        println LOG "\n${FG_RED}ERROR${NC}: failure during payment key hash creation!\n${stdout}"
        return 1
      fi
    fi
  fi
  if [[ -z ${stake_cred} ]]; then
    stake_vk_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_VK_FILENAME}"
    if [[ -f "${stake_vk_file}" ]]; then
      println ACTION "${CCLI} latest stake-address key-hash --stake-verification-key-file ${stake_vk_file} --out-file ${stake_cred_file}"
      if stdout=$(${CCLI} latest stake-address key-hash --stake-verification-key-file "${stake_vk_file}" --out-file "${stake_cred_file}" 2>&1); then
        stake_cred=$(cat "${stake_cred_file}")
      else
        println LOG "\n${FG_RED}ERROR${NC}: failure during stake key hash creation!\n${stdout}"
        return 1
      fi
    fi
  fi
  if [[ -z ${ms_pay_cred} ]]; then
    ms_payment_vk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
    if [[ -f "${ms_payment_vk_file}" ]]; then
      println ACTION "${CCLI} address key-hash --payment-verification-key-file ${ms_payment_vk_file} --out-file ${ms_payment_cred_file}"
      if stdout=$(${CCLI} address key-hash --payment-verification-key-file "${ms_payment_vk_file}" --out-file "${ms_payment_cred_file}" 2>&1); then
        ms_pay_cred=$(cat "${ms_payment_cred_file}")
      else
        println LOG "\n${FG_RED}ERROR${NC}: failure during MultiSig payment key hash creation!\n${stdout}"
        return 1
      fi
    fi
  fi
  if [[ -z ${ms_stake_cred} ]]; then
    ms_stake_vk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
    if [[ -f "${ms_stake_vk_file}" ]]; then
      println ACTION "${CCLI} latest stake-address key-hash --stake-verification-key-file ${ms_stake_vk_file} --out-file ${ms_stake_cred_file}"
      if stdout=$(${CCLI} latest stake-address key-hash --stake-verification-key-file "${ms_stake_vk_file}" --out-file "${ms_stake_cred_file}" 2>&1); then
        ms_stake_cred=$(cat "${ms_stake_cred_file}")
      else
        println LOG "\n${FG_RED}ERROR${NC}: failure during MultiSig stake key hash creation!\n${stdout}"
        return 1
      fi
    fi
  fi
  if [[ -z ${script_pay_cred} ]]; then
    payment_script_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_SCRIPT_FILENAME}"
    if [[ -f "${payment_script_file}" ]]; then
      println ACTION "${CCLI} hash script --script-file ${payment_script_file} --out-file ${script_payment_cred_file}"
      if stdout=$(${CCLI} hash script --script-file "${payment_script_file}" --out-file "${script_payment_cred_file}" 2>&1); then
        script_pay_cred=$(cat "${script_payment_cred_file}")
      else
        println LOG "\n${FG_RED}ERROR${NC}: failure during script payment policy creation!\n${stdout}"
        return 1
      fi
    fi
  fi
  if [[ -z ${script_stake_cred} ]]; then
    stake_script_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_SCRIPT_FILENAME}"
    if [[ -f "${stake_script_file}" ]]; then
      println ACTION "${CCLI} hash script --script-file ${stake_script_file} --out-file ${script_stake_cred_file}"
      if stdout=$(${CCLI} hash script --script-file "${stake_script_file}" --out-file "${script_stake_cred_file}" 2>&1); then
        script_stake_cred=$(cat "${script_stake_cred_file}")
      else
        println LOG "\n${FG_RED}ERROR${NC}: failure during script stake policy creation!\n${stdout}"
        return 1
      fi
    fi
  fi
}

# Command     : getAddressInfo [address]
# Description : get address info from from node
# Parameters  : address  >  the wallet address to query
# Return      : populates ${address_info}
getAddressInfo() {
  println ACTION "${CCLI} address info --address $1"
  if ! address_info=$(${CCLI} address info --address $1 2>&1); then
    println LOG "\n${FG_RED}ERROR${NC}: failure during reward address creation!\n${base_addr}"
    return 1
  fi
}

# Command     : getBalance [address]
# Description : check balance for provided address
# Parameters  : address  >  the wallet address to query
getBalance() {
  declare -gA utxos=(); declare -gA assets=()
  assets["lovelace"]=0; utxo_cnt=0
  asset_name_maxlen=5; asset_amount_maxlen=12
  tx_in=""

  println ACTION "${CCLI} query utxo --address ${1} ${NETWORK_IDENTIFIER} --output-text"
  if [[ -z ${1} ]] || ! utxo_raw=$(${CCLI} query utxo --address "${1}" ${NETWORK_IDENTIFIER} --output-text); then return 1; fi
  [[ -z ${utxo_raw} ]] && return

  while IFS= read -r line; do
    IFS=' ' read -ra utxo_entry <<< "${line}"
    [[ ${#utxo_entry[@]} -lt 4 ]] && continue
    ((utxo_cnt++))
    tx_in+=" --tx-in ${utxo_entry[0]}#${utxo_entry[1]}"
    if [[ ${utxo_entry[3]} = "lovelace" ]]; then
      utxos["${utxo_entry[0]}#${utxo_entry[1]}. ADA"]=${utxo_entry[2]} # Space added before 'ADA' for sort to place it first
      assets["lovelace"]=$(( ${assets["lovelace"]:-0} + utxo_entry[2] ))
      idx=5
    else
      utxos["${utxo_entry[0]}#${utxo_entry[1]}. ADA"]=0 # Space added before 'ADA' for sort to place it first
      assets["lovelace"]=0
      idx=2
    fi
    if [[ ${#utxo_entry[@]} -gt "${idx}" ]]; then
      while [[ ${#utxo_entry[@]} -gt ${idx} ]]; do
        asset_amount=${utxo_entry[${idx}]}
        if ! isNumber "${asset_amount}"; then break; fi
        asset_hash_name="${utxo_entry[$((idx+1))]}"
        IFS='.' read -ra asset <<< "${asset_hash_name}"
        tname="$(hexToAscii ${asset[1]})"
        tname="${tname//[![:print:]]/}"
        [[ ${#asset[@]} -eq 2 && ${#tname} -gt ${asset_name_maxlen} ]] && asset_name_maxlen=${#tname}
        asset_amount_fmt="$(formatAsset ${asset_amount})"
        [[ ${#asset_amount_fmt} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#asset_amount_fmt}
        assets["${asset_hash_name}"]=$(( ${assets["${asset_hash_name}"]:-0} + asset_amount ))
        utxos["${utxo_entry[0]}#${utxo_entry[1]}.${asset_hash_name}"]=${asset_amount}
        idx=$(( idx + 3 ))
      done
    fi
  done <<< "${utxo_raw}"

  [[ ${asset_name_maxlen} -ne 5 ]] && asset_name_maxlen=$(( asset_name_maxlen / 2 ))
  lovelace_fmt="$(formatLovelace ${assets["lovelace"]})"
  [[ ${#lovelace_fmt} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#lovelace_fmt}
}

# Command     : queryAddressUtxosKoiosBatch extended [addresses...]
# Description : query and parse a single Koios address_utxos batch
# Parameters  : extended  >  [true|false] should additional assets on utxo be parsed or not
#             : addresses >  bech32 addresses to include in the batch request
queryAddressUtxosKoiosBatch() {
  local extended=$1
  shift
  local -a addr_batch=( "$@" )
  local addr_list_joined payload address_utxo_list index_prefix asset_list_unescaped tname asset_amount_fmt
  local _address _tx_hash _tx_index _value _asset_list _policy_id _asset_name _quantity

  [[ ${#addr_batch[@]} -eq 0 ]] && return 0

  printf -v addr_list_joined '\"%s\",' "${addr_batch[@]}"
  payload='{"_addresses":['${addr_list_joined%,}'],"_extended":'${extended}'}'
  println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '${payload}' ${KOIOS_API}/address_utxos?select=address,tx_hash,tx_index,value,asset_list"
  ! address_utxo_list=$(curl -sSL -f -X POST "${HEADERS[@]}" -d "${payload}" "${KOIOS_API}/address_utxos?select=address,tx_hash,tx_index,value,asset_list" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${address_utxo_list}\n" && return 1 # print error and return
  [[ -z ${address_utxo_list} ]] && return 0

  while IFS=',' read -r _address _tx_hash _tx_index _value _asset_list; do
    index_prefix="${_address},"
    assets["${index_prefix}lovelace"]=$(( ${assets["${index_prefix}lovelace"]:-0} + _value ))
    utxos["${index_prefix}${_tx_hash}#${_tx_index}. ADA"]=${_value}
    utxos_cnt["${_address}"]=$(( ${utxos_cnt["${_address}"]:-0} + 1 ))
    tx_in_arr["${_address}"]="${tx_in_arr["${_address}"]} --tx-in ${_tx_hash}#${_tx_index}"
    if [[ ${extended} = true ]]; then
      asset_list_unescaped=${_asset_list:1: -1} # remove first and last char (quotation)
      asset_list_unescaped=$(sed 's/""/"/g' <<< "${asset_list_unescaped}") # remove all double quotes, sed seems to perform better than bash string manipulation
      while IFS=',' read -r _policy_id _asset_name _quantity; do
        tname="$(hexToAscii ${_asset_name})"
        tname="${tname//[![:print:]]/}"
        [[ ${#tname} -gt ${asset_name_maxlen_arr["${_address}"]:-5} ]] && asset_name_maxlen_arr["${_address}"]=${#tname}
        asset_amount_fmt="$(formatAsset ${_quantity})"
        [[ ${#asset_amount_fmt} -gt ${asset_amount_maxlen_arr["${_address}"]:-12} ]] && asset_amount_maxlen_arr["${_address}"]=${#asset_amount_fmt}
        assets["${index_prefix}${_policy_id}.${_asset_name}"]=$(( ${assets["${index_prefix}${_policy_id}.${_asset_name}"]:-0} + _quantity ))
        utxos["${index_prefix}${_tx_hash}#${_tx_index}.${_policy_id}.${_asset_name}"]=${_quantity}
      done < <( jq -cr '.[] | "\(.policy_id),\(.asset_name),\(.quantity)"' <<< "${asset_list_unescaped}" )
    fi
  done < <(tail -n +2 <<< "${address_utxo_list}")
}

# Command     : getBalanceKoios parse_assets
# Description : check balance for provided addresses using Koios API
# Parameters  : parse_assets  >  [true|false] should additional assets on utxo be parsed or not (default=true)
getBalanceKoios() {
  # generate different arrays using key constructed in format: <address>,<additional fields...>
  # Ex: ( [addr123,lovelace]=1000 [addr456,policy.name]=500 )
  # Its assumed that an array called addr_list has been populated with all addresses to fetch balance for

  local -a addr_batch=() candidate_batch=()
  local addr_list_joined payload extended _address
  local koios_payload_max_bytes=1024 # keep each request within the Koios public-tier body limit

  declare -gA utxos=(); declare -gA utxos_cnt=(); declare -gA assets=(); declare -gA tx_in_arr=(); declare -gA asset_name_maxlen_arr=(); declare -gA asset_amount_maxlen_arr=()

  if [[ -n ${KOIOS_API} && -n ${addr_list+x} ]]; then
    [[ $1 != false ]] && extended=true || extended=false
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json" -H "accept: text/csv")
    for _address in "${addr_list[@]}"; do
      candidate_batch=( "${addr_batch[@]}" "${_address}" )
      printf -v addr_list_joined '\"%s\",' "${candidate_batch[@]}"
      payload='{"_addresses":['${addr_list_joined%,}'],"_extended":'${extended}'}'
      if [[ ${#payload} -gt ${koios_payload_max_bytes} && ${#addr_batch[@]} -gt 0 ]]; then
        queryAddressUtxosKoiosBatch "${extended}" "${addr_batch[@]}" || return 1
        addr_batch=( "${_address}" )
      else
        addr_batch=( "${candidate_batch[@]}" )
      fi
    done
    queryAddressUtxosKoiosBatch "${extended}" "${addr_batch[@]}" || return 1
  fi
}

# Command     : getWalletBalance [wallet name] [force] [base] [pay] [asset]
# Description : get balance for wallet
# Parameters  : force  >  optional: [true|false] force update of balance (default = false)
#             : base   >  optional: [true|false] get base address balance (default = true)
#             : pay    >  optional: [true|false] get payment address balance (default = true)
#             : asset  >  optional: [true|false] fetch additional koios asset data (default = false)
getWalletBalance() {
  addr_list=()
  declare -gA base_assets=(); declare -gA pay_assets=()
  [[ $2 = true ]] && declare -gA balances=()
  [[ $5 = true ]] && asset_info=true || asset_info=false
  if [[ $3 != false ]] && getBaseAddress $1 && [[ -n ${base_addr} ]]; then
    if [[ -v balances[${base_addr}] ]]; then
      base_lovelace=${balances[${base_addr}]}
    else
      if [[ -n ${KOIOS_API} ]]; then
        addr_list+=(${base_addr})
      else
        getBalance ${base_addr}
        base_lovelace=${assets[lovelace]:-0}
        for idx in "${!assets[@]}"; do base_assets[${idx}]=${assets[${idx}]}; done
      fi
    fi
  else
    base_lovelace=0
  fi
  if [[ $4 != false ]] && getPayAddress $1 && [[ -n ${pay_addr} ]]; then
    if [[ -v balances[${pay_addr}] ]]; then
      pay_lovelace=${balances[${pay_addr}]}
    else
      if [[ -n ${KOIOS_API} ]]; then
        addr_list+=(${pay_addr})
      else
        getBalance ${pay_addr}
        pay_lovelace=${assets[lovelace]:-0}
        for idx in "${!assets[@]}"; do pay_assets[${idx}]=${assets[${idx}]}; done
      fi
    fi
  else
    pay_lovelace=0
  fi
  if [[ ${#addr_list[@]} -gt 0 ]]; then
    getBalanceKoios ${asset_info}
    if [[ -n ${base_addr} ]]; then
      base_lovelace=${assets["${base_addr},lovelace"]:-0}
      for idx in "${!assets[@]}"; do [[ ${idx} != "${base_addr},"* ]] && continue; base_assets[${idx#*,}]=${assets[${idx}]}; done
    fi
    if [[ -n ${pay_addr} ]]; then
      pay_lovelace=${assets["${pay_addr},lovelace"]:-0}
      for idx in "${!assets[@]}"; do [[ ${idx} != "${pay_addr},"* ]] && continue; pay_assets[${idx#*,}]=${assets[${idx}]}; done
    fi
  fi
}

# Command     : getAddressBalance [address] [force] [asset]
# Description : get balance for address
# Parameters  : force  >  optional: [true|false] force update of balance (default = false)
#             : asset  >  optional: [true|false] fetch additional koios asset data (default = false)
getAddressBalance() {
  [[ $2 = true ]] && declare -gA balances=()
  [[ $3 = true ]] && asset_info=true || asset_info=false
  if [[ -n ${1} ]]; then
    if [[ -v balances[${1}] ]]; then
      lovelace=${balances[${1}]}
    else
      if [[ -n ${KOIOS_API} ]]; then
        addr_list=(${1})
        getBalanceKoios ${asset_info}
        lovelace=${assets["${1},lovelace"]:-0}
      else
        getBalance ${1}
        lovelace=${assets[lovelace]:-0}
      fi
    fi
  else
    lovelace=0
  fi
}

# Command     : getAssetsTxOut [PolicyID.AssetName] [Amount]
# Description : generate tx out string for multi-assets in wallet
#               getBalance assumed to be run before calling this function
#               address variable assumed to be set to selected wallet bech32 address
# Parameters  : PolicyID.AssetName  >  optional: Adjust balance for this asset before generating output
#               Amount              >  optional: The amount to adjust balance
# Return      : populates ${assets_tx_out}
getAssetsTxOut() {
  assets_tx_out=""
  if [[ $# -eq 2 ]]; then
    old_value=assets[$1]
    assets[$1]=$(( old_value + $2 ))
  fi
  for idx in "${!assets[@]}"; do
    [[ ${idx} = *lovelace ]] && continue
    [[ ${assets[${idx}]} -gt 0 ]] && assets_tx_out+="+${assets[${idx}]} ${idx#*,}"
  done
}

# Command     : getMinUTxO [string]
# Description : calculate minimum balance needed in transaction output to be valid
#             : string as passed to --tx-out parameter
# Return      : populates ${min_utxo_out}
getMinUTxO() {
  unset min_utxo_out
  min_utxo_args=(
    latest
    transaction calculate-min-required-utxo
    --protocol-params-file "${TMP_DIR}"/protparams.json
    --tx-out "$1"
  )
  println ACTION "${CCLI} ${min_utxo_args[*]}"
  if ! stdout=$(${CCLI} "${min_utxo_args[@]}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during min utxo calculation!\n${stdout}"
    return 1
  fi
  min_utxo_out=$([[ ${stdout} =~ ([0-9]+) ]] && echo ${BASH_REMATCH[1]})
}

# Command     : getWalletRewards [wallet name] [force]
# Description : check balance of reward address
# Parameters  : wallet name  >  the name of the wallet
# Return      : populates ${reward_lovelace}
getWalletRewards() {
  reward_lovelace=-1
  if [[ $2 = true ]]; then
    declare -gA rewards_available=(); declare -gA reward_status=(); declare -gA pool_delegations=();
  fi
  if isWalletRegistered $1; then
    if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
      : # do nothing, variables populated through isWalletRegistered
    else
      reward_lovelace=${rewards_available[${reward_addr}]:-0}
      stake_deposit=${stake_deposits[${reward_addr}]}
    fi
  fi
}

# Command     : getRewardInfoKoios
# Description : check status and rewards for provided reward addresses using Koios API
getRewardInfoKoios() {
  # generate different arrays using reward address as key, rewards available, status and delegated pool if any
  # Its assumed that an array called reward_addr_list has been populated with all reward addresses to fetch data for

  declare -gA rewards_available=(); declare -gA reward_status=(); declare -gA pool_delegations=(); declare -gA vote_delegations=(); declare -gA stake_deposits=();

  # set defaults
  for _reward_addr in "${reward_addr_list[@]}"; do
    reward_status["${_reward_addr}"]="not registered"
    rewards_available["${_reward_addr}"]=0
    unset 'pool_delegations[${_reward_addr}]'
    unset 'vote_delegations[${_reward_addr}]'
  done

  if [[ -n ${KOIOS_API} && -n ${reward_addr_list+x} ]]; then
    printf -v addr_list_joined '\"%s\",' "${reward_addr_list[@]}"
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json" -H "accept: text/csv")
    println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '{\"_stake_addresses\":[${addr_list_joined%,}]}' ${KOIOS_API}/account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit"
    ! account_info_list=$(curl -sSL -f -X POST "${HEADERS[@]}" -d '{"_stake_addresses":['${addr_list_joined%,}']}' "${KOIOS_API}/account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${account_info_list}\n" && return 1 # print error and return
    [[ -z ${account_info_list} ]] && return
    while IFS=',' read -r stake_address status delegated_pool delegated_drep rewards_available deposit; do
      reward_status["${stake_address}"]="${status}"
      rewards_available["${stake_address}"]="${rewards_available}"
      [[ -n ${delegated_pool} ]] && pool_delegations["${stake_address}"]="${delegated_pool}"
      if [[ -n ${delegated_drep} ]]; then
        if [[ ${delegated_drep} = drep_always_abstain ]]; then
          vote_delegations["${stake_address}"]="alwaysAbstain"
        elif [[ ${delegated_drep} = drep_always_no_confidence ]]; then
          vote_delegations["${stake_address}"]="alwaysNoConfidence"
        else
          # convert to cli format <type>-<hash>
          vote_delegation_raw=$(bech32 <<< "${delegated_drep}")
          if [[ ${vote_delegation_raw:0:2} = '22' ]]; then
            vote_delegations["${stake_address}"]="keyHash-${vote_delegation_raw:2}"
          else
            vote_delegations["${stake_address}"]="scriptHash-${vote_delegation_raw:2}"
          fi
        fi
      fi
      stake_deposits["${stake_address}"]="${deposit}"
    done <<< "$(tail -n +2 <<< ${account_info_list})"
  fi
}

# Command     : getRewardsFromAddr [stake address]
# Description : check balance of reward address
# Parameters  : stake address  >  the address from stake.vkey
# Return      : populates ${reward_lovelace}
getRewardsFromAddr() {
  unset stake_address pool_delegation vote_delegation
  reward_lovelace=0; stake_deposit=0
  println ACTION "${CCLI} query stake-address-info ${NETWORK_IDENTIFIER} --address ${1}"
  ! stake_address_info=$(${CCLI} query stake-address-info ${NETWORK_IDENTIFIER} --address ${1}) && println "ERROR" "\n${FG_RED}NODE CLI ERROR${NC}: ${stake_address_info}\n" && return 1 # print error and return
  IFS=$'\037' read -r stake_address reward_lovelace stake_deposit gov_action_deposits pool_delegation vote_delegation < <( jq -cr '
    def poolDelegation:
      (.[0].stakeDelegation // null) as $delegation
      | if ($delegation | type) == "object" then $delegation.stakePoolBech32 // "" else "" end;
    def voteDelegation:
      (.[0].voteDelegation // null) as $delegation
      | if ($delegation | type) == "string" then
          $delegation
        elif ($delegation | type) == "object" then
          if ($delegation.keyHashLedger // "") != "" then
            "keyHash-\($delegation.keyHashLedger)"
          elif ($delegation.scriptHashLedger // "") != "" then
            "scriptHash-\($delegation.scriptHashLedger)"
          elif ($delegation.keyHash // "") != "" then
            "keyHash-\($delegation.keyHash)"
          elif ($delegation.scriptHash // "") != "" then
            "scriptHash-\($delegation.scriptHash)"
          elif ($delegation.cip129Hex // "") != "" then
            if ($delegation.cip129Hex | startswith("22")) then
              "keyHash-\($delegation.cip129Hex[2:])"
            else
              "scriptHash-\($delegation.cip129Hex[2:])"
            end
          else
            ""
          end
        else
          ""
        end;
    [
      .[0].address // "",
      .[0].rewardAccountBalance // 0,
      .[0].stakeRegistrationDeposit // 0,
      (.[0].govActionDeposits // {} | tostring),
      poolDelegation,
      voteDelegation
    ] | map(tostring) | join("\u001f")
  ' <<< "${stake_address_info}" )
}

# Command     : isWalletRegistered [wallet name]
# Description : check if wallet is registered on chain
# Parameters  : wallet name  >  the name of the wallet
isWalletRegistered() {
  if getRewardAddress $1; then
    if [[ -n ${KOIOS_API} ]]; then
      [[ ! -v "reward_status[${reward_addr}]" ]] && reward_addr_list=( ${reward_addr} ) && getRewardInfoKoios
      [[ ${reward_status[${reward_addr}]} = registered ]] && return 0
    else
      getRewardsFromAddr ${reward_addr}
      [[ -n "${stake_address}" ]] && return 0
    fi
  fi
  return 1
}

# Command     : getWalletType [wallet name]
# Description : check if wallet is a hardware wallet, 0=hw, 1=cli, 2=cli & encrypted, 3=signing keys missing, 4=verification keys missing, 5=MultiSig
# Parameters  : wallet name  >  the name of the wallet
getWalletType() {
  payment_vk_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_VK_FILENAME}"
  payment_sk_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_SK_FILENAME}"
  payment_script_file="${WALLET_FOLDER}/${1}/${WALLET_PAY_SCRIPT_FILENAME}"
  stake_vk_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_VK_FILENAME}"
  stake_sk_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_SK_FILENAME}"
  stake_script_file="${WALLET_FOLDER}/${1}/${WALLET_STAKE_SCRIPT_FILENAME}"
  ms_payment_vk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  ms_payment_sk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
  ms_stake_vk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  ms_stake_sk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
  if [[ -f "${payment_vk_file}" && -f "${stake_vk_file}" ]]; then # CNTools wallet
    wallet_desc=$(jq -r '.description' "${payment_vk_file}")
    if [[ ${wallet_desc} = *"Hardware"* ]]; then
      payment_sk_file="${WALLET_FOLDER}/${1}/${WALLET_HW_PAY_SK_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${1}/${WALLET_HW_STAKE_SK_FILENAME}"
      ms_payment_vk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_VK_FILENAME}"
      ms_payment_sk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_PAY_SK_FILENAME}"
      ms_stake_vk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_VK_FILENAME}"
      ms_stake_sk_file="${WALLET_FOLDER}/${1}/${WALLET_MULTISIG_PREFIX}${WALLET_HW_STAKE_SK_FILENAME}"
      [[ ${op_mode} = "online" && ( ! -f ${payment_sk_file} || ! -f ${stake_sk_file} ) ]] && return 3 || return 0
    elif [[ -f "${WALLET_FOLDER}/${1}/${WALLET_PAY_SK_FILENAME}.gpg" || -f "${WALLET_FOLDER}/${1}/${WALLET_STAKE_SK_FILENAME}.gpg" ]]; then
      return 2
    else
      [[ ${op_mode} = "online" && ( ! -f ${payment_sk_file} || ! -f ${stake_sk_file} ) ]] && return 3 || return 1
    fi
  elif [[ -f "${WALLET_FOLDER}/${1}/${WALLET_PAY_SCRIPT_FILENAME}" || -f "${WALLET_FOLDER}/${1}/${WALLET_STAKE_SCRIPT_FILENAME}" ]]; then # CNTools MultiSig wallet
    return 5
  else
    return 4
  fi
}

# Command     : getAllMultiSigKeys [script]
# Description : parse json MultiSig script for all signatures
# Parameters  : script      > the native script in json format
# Return      : populates: ${script_sig_list} (associative array that acts as a set)
getAllMultiSigKeys() {
  unset script_sig_list
  declare -gA script_sig_list=()
  while read -r _keyHash; do
    script_sig_list[${_keyHash}]=1
  done < <( jq -r '.. | select(.type?=="sig") | .keyHash' <<< "$1" )
}

# Command     : validateMultiSigScript [verbose] [script] [sigs...]
# Description : parse json MultiSig script to check if needed signatures exist
#             : NOTE !! please unset required_total before calling this function
# Parameters  : verbose     > true|false, print time lock warnings
#             : script      > the native script in json format
#             : sigs        > array of creds for wallets found
# Return      : 0 = success, 1 = failed, populates ${required_total} with total needed signatures
validateMultiSigScript() {
  local found=0
  local required=1
  local verbose=$1
  local script=$2
  shift
  IFS=',' read -r _type _scripts _scripts_cnt _required <<< "$(jq -cr '"\(.type),\(.scripts|@base64),\(.scripts|length),\(.required)"' <<< "${script}")"
  if [[ ${_type} = atLeast ]]; then
    required=${_required}
  elif [[ ${_type} = all ]]; then
    required=${_scripts_cnt}
  fi
  while IFS=',' read -r __type __key_hash __slot __script; do
    if [[ ${__type} = sig ]]; then
      for _sig in "$@"; do
        [[ ${_sig} = "${__key_hash}" ]] && ((found++))
      done
    elif [[ ${__type} = before ]]; then
      if [[ $(getSlotTipRef) -lt ${__slot} ]]; then
        ((found++))
      else
        [[ ${verbose} = true ]] && println ERROR "${FG_RED}Time locked!${NC} This script is locked with a before condition that has passed, before slot = ${__slot}, current slot = $(getSlotTipRef)"
      fi
    elif [[ ${__type} = after ]]; then
      if [[ $(getSlotTipRef) -gt ${__slot} ]]; then
        ((found++))
      else
        [[ ${verbose} = true ]] && println ERROR "${FG_RED}Time locked!${NC} This script is locked with an after condition that has yet to pass, after slot = ${__slot}, current slot = $(getSlotTipRef)"
      fi
    else
      validateMultiSigScript ${verbose} "$(base64 -d <<< ${__script})" "$@" && ((found++))
    fi
  done < <( base64 -d <<< ${_scripts} | jq -cr '.[] | "\(.type),\(.keyHash),\(.slot),\(.|@base64)"' )
  required_total=$(( required_total + required ))
  [[ ${found} -ge ${required} ]] && return 0 || return 1
}

# Command     : getPoolType [pool name]
# Description : check if pool is a hardware pool, 0=yes, 1=cli, 2=cli & encrypted, 3=signing keys missing, 4=verification keys missing
# Parameters  : pool name  >  the name of the pool
getPoolType() {
  pool_coldkey_vk_file="${POOL_FOLDER}/${1}/${POOL_COLDKEY_VK_FILENAME}"
  pool_coldkey_sk_file="${POOL_FOLDER}/${1}/${POOL_COLDKEY_SK_FILENAME}"
  if [[ -f "${POOL_FOLDER}/${1}/${POOL_COLDKEY_VK_FILENAME}" ]]; then # CNTools pool
    if [[ $(jq -r '.description' "${pool_coldkey_vk_file}") = *"Hardware"* ]]; then
      pool_coldkey_sk_file="${POOL_FOLDER}/${1}/${POOL_HW_COLDKEY_SK_FILENAME}"
      ([[ ${op_mode} = "online" && ( ! -f ${pool_coldkey_sk_file} ) ]]) && return 3 || return 0
    elif [[ -f "${POOL_FOLDER}/${1}/${POOL_COLDKEY_SK_FILENAME}.gpg" ]]; then
      return 2
    else
      ([[ ${op_mode} = "online" && ( ! -f ${pool_coldkey_sk_file} ) ]]) && return 3 || return 1
    fi
  else
    return 4
  fi
}

# Command     : getTTL [force, true|false]
# Description : query node for slot tip and calculate/get TTL from input depending on op_mode
getTTL() {
  tip_ref=$(getSlotTipRef)
  if [[ ${op_mode} = "hybrid" || $1 = true ]]; then
    println DEBUG "\nHow long do you want the transaction to be valid?"
    getAnswerAnyCust ttl_enter "TTL (in seconds, default: 1800/30min)"
    ttl_enter=${ttl_enter:-1800}
    if ! isNumber ${ttl_enter}; then
      println ERROR "\n${FG_RED}ERROR${NC}: invalid TTL number, non digit characters found: ${ttl_enter}"
      return 1
    fi
    ttl=$(( tip_ref + (ttl_enter/SLOT_LENGTH) ))
  else
    ttl=$(( tip_ref + (TX_TTL/SLOT_LENGTH) ))
  fi
  println LOG "Current slot is ${tip_ref}, setting ttl to ${ttl}"
}

# Command     : getCustomDerivationPath
# Description : ask user for custom derivation path (account and key index)
# Return      : populates: ${acct_idx} ${key_idx}
getCustomDerivationPath() {
  println DEBUG "Enter a custom account index to derive keys for (enter for default)"
  getAnswerAnyCust acct_idx "Account (default: 0)"
  acct_idx=${acct_idx:-0}
  if ! isNumber ${acct_idx}; then
    println ERROR "${FG_RED}ERROR${NC}: Invalid account index, must be a number!"
    waitToProceed && return 1
  fi
  println DEBUG "\nEnter a custom key index to derive keys for (enter for default)"
  getAnswerAnyCust key_idx "Key index (default: 0)"
  key_idx=${key_idx:-0}
  if ! isNumber ${key_idx}; then
    println ERROR "${FG_RED}ERROR${NC}: Invalid key index, must be a number!"
    waitToProceed && return 1
  fi
  return 0
}

# Command     : getSavedDerivationPath [derivation_path_file]
# Description : parse saved derivation path file for acct_idx and key_idx
# Return      : populates: ${derivation_path} ${acct_idx} ${key_idx}
getSavedDerivationPath() {
  unset derivation_path acct_idx key_idx
  [[ ! -f $1 ]] && return 1
  derivation_path=$(cat "$1")
  IFS='/' read -ra array <<< "${derivation_path}"
  acct_idx="${array[2]//H}"
  key_idx="${array[4]}"
  return 0
}

