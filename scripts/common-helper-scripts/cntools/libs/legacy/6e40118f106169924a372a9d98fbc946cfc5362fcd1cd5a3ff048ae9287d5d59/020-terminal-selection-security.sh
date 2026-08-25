cursor_blink_on()  { printf "${ESC}[?25h"; }
cursor_blink_off() { printf "${ESC}[?25l"; }
cursor_to()        { printf "${ESC}[$1;${2:-1}H"; }
print_option()     { printf "  $1 "; }
print_selected()   { printf " ${ESC}[7m $1 ${ESC}[27m$2"; }
get_cursor_row()   { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
key_input()        { key2=""
                     read -rsn1 key1   # get 1 character
                     if [[ $key1 == "${ESC}" ]]; then
                       read -rsn2 -t 0.3 key2 # read 2 more chars, 1s timeout
                     fi
                       if [[ ${key2} = "[A" ]]; then echo up;
                     elif [[ ${key2} = "[B" ]]; then echo down;
                     elif [[ ${key1} = "${ESC}" && ${key2} = "" ]]; then echo Esc;
                     elif [[ ${key1} = ""   ]]; then echo enter;
                     else echo ${key1}; fi; }
opt_shortcut()     { [[ "$1" =~ ^\[([[:alnum:]]+)\].* ]] && echo ${BASH_REMATCH[1]}; }
opt_firstchar()    { printf "${1:0:1}" | tr '[:upper:]' '[:lower:]'; }
clrbuf()           { read -r -t 0.1 -s; stty echo echok; }
selectOption() {

  # initially print empty new lines (scroll down if at bottom of screen)
  printf "\n" && for opt; do printf "\n"; done

  # determine current screen position for overwriting the options or return -1 on failure
  clrbuf
  local startrow=-1
  for i in {1..10}; do
    local cursor_row;cursor_row=$(get_cursor_row)
    isNumber ${cursor_row} && startrow=$(( cursor_row - $# - 1 )) && break
  done
  [[ ${startrow} -eq -1 ]] && return 255

  cursor_blink_off

  local shortcut_found="no"
  local selected=0
  while true; do
    # print options by overwriting the last lines
    local idx=0
    for opt; do
      opt_part2=""
      if [[ "$opt" =~ ^(.*)[[:space:]](\(.*) ]]; then
        opt_part1="${BASH_REMATCH[1]}"
        opt_part2=" ${BASH_REMATCH[2]}"
      else
        opt_part1="$opt"
      fi
      cursor_to $(( startrow + idx ))
      if [ ${idx} -eq ${selected} ]; then
        print_selected "${opt_part1}" "${opt_part2}"
      else
        print_option "${opt_part1}${opt_part2}"
      fi
      ((idx++))
    done

    [[ "${shortcut_found}" = "yes" ]] && break

    # user key control
    key_pressed=$(key_input)
    case ${key_pressed} in
      enter) break;;
      up)    ((selected--));
             if [ ${selected} -lt 0 ]; then selected=$(($# - 1)); fi;;
      down)  ((selected++));
             if [ ${selected} -ge $# ]; then selected=0; fi;;
      *)     # shortcut available for selected key?
             i=0
             for opt; do
               [[ ${key_pressed} = $(opt_shortcut "${opt}") ]] && selected=${i} && shortcut_found="yes" && break
               ((i++))
             done
             # If no shortcut is found, lets see if it matches the first char of any of the options
             j=0
             for opt; do
               [[ "${shortcut_found}" != "yes" && ${key_pressed} = $(opt_firstchar "${opt}") ]] && selected=${j} && break
               ((j++))
             done
             ;;
    esac
  done

  # clear menu
  cursor_blink_on
  cursor_to $startrow
  tput ed

  return $selected
}

# Command     : select_opt [opt1] [opt2] ...
# Description : Helper function to selectOption
# Parameters  : optX  >  a list of available options to choose from
select_opt() {
  local opts=()
  for item in "$@"; do
    [[ -n ${item} ]] && opts+=("${item}")
  done
  selectOption "${opts[@]}"
  local answer=$?
  if [[ ${answer} -eq 255 ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Failed to print menu, default selection used!\n"
    return 0
  fi
  selected_value="${opts[${answer}]}"
  println DEBUG "Selected value: ${selected_value}"
  return $answer
}

# Command     : getDirs [path to folder]
# Description : A helper function to get all subdirs for a directory
# Parameters  : path to folder    >   full path to folder, subdirs of this folder returned
# Return      : populates ${dirs} array
getDirs() {
  if [[ ! -d "$1" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: Missing folder: $1"
    waitToProceed && return 1
  fi
  dirs=()
  while IFS= read -r -d '' dir; do
    dirs+=("$(basename ${dir})")
  done < <(find "${1}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  return 0
}

# Command     : selectDir [type] [dir1 dir2 ...]
# Description : A helper function to selectOption() specifically for directory selection
# Parameters  : type  >  'wallet' 'pool' 'policy' 'asset'
#             : dirX  >  array of dirs to include in selection, '[Esc] Cancel' option added to all selections
# Return      : populates ${dir_name} variable
selectDir() {
  local type=$1 && shift
  dirs=( "$@" )
  dirs+=("[Esc] Cancel")
  selectOption "${dirs[@]}"
  local answer=$?
  if [[ ${answer} -eq 255 ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Failed to print menu, please try again or report issue!"
    return 1
  fi
  dir_name=${dirs[${answer}]}
  [[ "${dir_name}" = "[Esc] Cancel" ]] && return 2
  println DEBUG "Selected ${type}: ${dir_name}"
}

# Command     : selectWallet [mode] [file1 file2 ... | wallet_name1 wallet_name1 ... ]
# Description : A helper function to select a CNTools wallet
# Parameters  : mode       >  a string containing some of the following: none|encrypted|non-reg|reg|balance|delegate|reward|assets|non-ms|non-gov to be added next to wallet in selection menu
#             : arg array  >  array of files required to exist in wallet folder for it to be selectable **OR** the name of wallet to exclude from selection
# Return      : populates ${wallet_name} variable with wallet selection
selectWallet() {

  mode=$1 && shift

  if [[ ${mode} = "cache" && ${#wallet_dirs_filtered[@]} -gt 0 ]]; then
    selectDir "wallet" "${wallet_dirs_filtered[@]}" || return $? # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"
    return 0
  fi

  wallet_dirs=()

  if ! getDirs "${WALLET_FOLDER}"; then return 1; fi # dirs() array populated with all wallet folders
  if [[ ${CNTOOLS_MODE} != "OFFLINE" && ${mode} != "none" && ${mode} != "non-ms" && ${mode} != "non-gov" ]]; then
    tput sc
    wallet_count=${#dirs[@]}
    if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
      if [[ -n ${KOIOS_API} ]]; then
        println OFF "${FG_YELLOW}> Querying Koios API for wallet balance${NC}"
      else
        println OFF "${FG_YELLOW}> Querying node for wallet balance${NC}"
      fi
    else
      println OFF "${FG_YELLOW}> Max wallet count exceeded for balance/filtering (${wallet_count}/${WALLET_SELECTION_FILTER_LIMIT}).\nUpdate 'WALLET_SELECTION_FILTER_LIMIT' setting to increase this limit${NC}"
    fi
  fi

  unset reward_status
  addr_list=()
  reward_addr_list=()
  declare -gA asset_cnt=()
  declare -gA balances=()
  declare -gA pool_delegations=()
  declare -gA rewards_available=()

  for dir in "${dirs[@]}"; do
    for arg in "$@"; do # check if wallet is missing a required file or name matches execution, if so hide it
      [[ ${arg} == *"."* && ! -f "${WALLET_FOLDER}/${dir}/${arg}" ]] && continue 2
      [[ ${arg} != *"."* && ${dir} = "${arg}" ]] && continue 2
    done
    if [[ ${mode} = "encrypted" ]]; then
      enc_files=$(find "${WALLET_FOLDER}/${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
      if [[ ${enc_files} -gt 0 ]]; then
        wallet_dirs+=("${dir} (${FG_GREEN}encrypted${NC})")
      else
        wallet_dirs+=("${dir} (${FG_YELLOW}unprotected${NC})")
      fi
    elif [[ ${mode} = "non-ms" ]]; then
      ms_payment_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
      ms_stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
      if [[ -f "${ms_payment_vk_file}" || -f "${ms_stake_vk_file}" ]]; then continue; else wallet_dirs+=("${dir}"); fi
    elif [[ ${mode} = "non-gov" ]]; then
      drep_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
      cc_cold_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_CC_COLD_VK_FILENAME}"
      cc_hot_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_CC_HOT_VK_FILENAME}"
      if [[ -f "${drep_vk_file}" || -f "${cc_cold_vk_file}" || -f "${cc_hot_vk_file}" ]]; then continue; else wallet_dirs+=("${dir}"); fi
    elif [[ ${CNTOOLS_MODE} != "OFFLINE" && ${mode} != "none" && ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
      if [[ ${mode} = "reg" || ${mode} = "non-reg" ]]; then
        if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
          if [[ ${mode} = "reg" ]]; then
            ! isWalletRegistered ${dir} && continue
          else
            isWalletRegistered ${dir} && continue
          fi
        else
          getRewardAddress ${dir}
          [[ -n ${reward_addr} ]] && reward_addr_list+=(${reward_addr})
        fi
      fi
      if [[ ${mode} = "balance" || ${mode} = "non-reg" || ${mode} = "reg" ]]; then
        getBaseAddress ${dir}
        getPayAddress ${dir}
        [[ -z ${base_addr} || -z ${pay_addr} ]] && wallet_dirs+=("${dir}") && continue # ignore and add wallet without extra details
        addr_list+=(${base_addr} ${pay_addr})
        if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
          getBalance ${base_addr}
          balances["${base_addr}"]=${assets[lovelace]}
          [[ ${#assets[@]} -gt 1 ]] && asset_cnt["${base_addr}"]="$((${#assets[@]}-1))"
          getBalance ${pay_addr}
          balances["${pay_addr}"]=${assets[lovelace]}
          [[ ${#assets[@]} -gt 1 ]] && asset_cnt["${pay_addr}"]="$((${#assets[@]}-1))"
        fi
        wallet_dirs+=("${dir}_balance_")
      elif [[ ${mode} = "delegate" ]]; then
        getBaseAddress ${dir}
        [[ -z ${base_addr} ]] && wallet_dirs+=("${dir}") && continue # ignore and add wallet without extra details
        addr_list+=(${base_addr})
        getRewardAddress ${dir}
        if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
          getBalance ${base_addr}
          balances["${base_addr}"]=${assets[lovelace]}
          if [[ -n ${reward_addr} ]]; then
            delegation_pool_id=$(${CCLI} query stake-address-info ${NETWORK_IDENTIFIER} --address "${reward_addr}" | jq -r '.[0].stakeDelegation.stakePoolBech32 // empty')
            [[ -n ${delegation_pool_id} ]] && pool_delegations[${reward_addr}]=${delegation_pool_id}
          fi
        else
           [[ -n ${reward_addr} ]] && reward_addr_list+=(${reward_addr})
        fi
        wallet_dirs+=("${dir}_balance_")
      elif [[ ${mode} = "reward" ]]; then
        if [[ -n ${KOIOS_API} ]]; then
          getRewardAddress ${dir}
          [[ -n ${reward_addr} ]] && reward_addr_list+=(${reward_addr})
        else
          getWalletRewards ${dir}
          [[ ${reward_lovelace} -le 0 ]] && continue
          rewards_available[${reward_addr}]=${reward_lovelace}
        fi
        wallet_dirs+=("${dir}_balance_")
      fi
    else
      wallet_dirs+=("${dir}")
    fi
  done

  if [[ -n ${KOIOS_API} ]]; then
    if [[ ${#addr_list[@]} -gt 0 ]]; then
      getBalanceKoios false
      for key in "${!assets[@]}"; do
        if [[ ${key} = *lovelace ]]; then
          _address=${key%,*}
          balances[${_address}]=${assets[${key}]}
        fi
      done
    fi
    [[ ${#reward_addr_list[@]} -gt 0 ]] && getRewardInfoKoios
  fi

  wallet_dirs_filtered=()

  for dir in "${wallet_dirs[@]}"; do
    if [[ ${dir} = *_balance_ ]]; then
      wallet_dir=${dir%%_balance_}
      unset base_addr
      getBaseAddress ${wallet_dir}
      base_lovelace=${balances[${base_addr}]:-0}
      if [[ ${mode} = "reg" || ${mode} = "non-reg" ]]; then
        getRewardAddress ${wallet_dir}
        if [[ -n ${reward_addr} ]]; then
          if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
            if [[ ${mode} = "reg" ]]; then
              if [[ ! -v reward_status[${reward_addr}] || ${reward_status[${reward_addr}]} != "registered" ]]; then continue; fi
            else
              [[ -v reward_status[${reward_addr}] && ${reward_status[${reward_addr}]} = "registered" ]] && continue
            fi
          fi
        fi
      elif [[ ${mode} = "delegate" ]]; then
        getRewardAddress ${wallet_dir}
        if [[ -n ${reward_addr} ]]; then
          delegation_pool_id=${pool_delegations[${reward_addr}]}
          unset poolName
          if [[ -n ${delegation_pool_id} ]]; then
            while IFS= read -r -d '' pool; do
              getPoolID "$(basename ${pool})"
              if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
                poolName=$(basename ${pool}) && break
              fi
            done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          fi
          if [[ -n ${poolName} ]]; then
            wallet_dirs_filtered+=("${wallet_dir} (${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA - ${FG_RED}delegated${NC} to ${FG_GREEN}${poolName}${NC})")
          elif [[ -n ${delegation_pool_id} ]]; then
            wallet_dirs_filtered+=("${wallet_dir} (${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA - ${FG_RED}delegated${NC} to ${FG_LGRAY}${delegation_pool_id:0:6}...${delegation_pool_id: -6}${NC})")
          else
            wallet_dirs_filtered+=("${wallet_dir} (${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA)")
          fi
        else
          wallet_dirs_filtered+=("${wallet_dir} (${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA)")
        fi
        continue
      elif [[ ${mode} = "reward" ]]; then
        getRewardAddress ${wallet_dir}
        if [[ -n ${reward_addr} && -v rewards_available[${reward_addr}] && ${rewards_available[${reward_addr}]} -gt 0 ]]; then
          wallet_dirs_filtered+=("${wallet_dir} (Rewards: ${FG_LBLUE}$(formatLovelace ${rewards_available[${reward_addr}]})${NC} ADA)")
        fi
        continue
      fi
      getPayAddress ${wallet_dir}
      pay_lovelace=${balances[${pay_addr}]:-0}
      [[ -v asset_cnt[${base_addr}] ]] && base_asset_str=" + ${FG_LBLUE}${asset_cnt[${base_addr}]}${NC} additional assets" || unset base_asset_str
      [[ -v asset_cnt[${pay_addr}] ]] && pay_asset_str=" + ${FG_LBLUE}${asset_cnt[${pay_addr}]}${NC} additional assets" || unset pay_asset_str
      if [[ ${base_lovelace} -gt 0 && ${pay_lovelace} -gt 0 ]]; then
        wallet_dirs_filtered+=("${wallet_dir} (Base Funds: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA${base_asset_str} | Payment Funds: ${FG_LBLUE}$(formatLovelace ${pay_lovelace})${NC} ADA${pay_asset_str})")
      elif [[ ${pay_lovelace} -gt 0 ]]; then
        wallet_dirs_filtered+=("${wallet_dir} (Payment Funds: ${FG_LBLUE}$(formatLovelace ${pay_lovelace})${NC} ADA${pay_asset_str})")
      else
        wallet_dirs_filtered+=("${wallet_dir} (Base Funds: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA${base_asset_str})")
      fi
    else
      wallet_dirs_filtered+=("${dir}")
    fi
  done

  if [[ ${CNTOOLS_MODE} != "OFFLINE" && ${mode} != "none" && ${mode} != "non-ms" && ${mode} != "non-gov" && ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then tput rc && tput ed; fi
  if [[ ${#wallet_dirs_filtered[@]} -eq 0 ]]; then
    if [[ ${mode} = "balance" ]]; then
      println INFO "\n${FG_YELLOW}WARN${NC}: No wallets available for selection!"
    elif [[ ${mode} = "delegate" ]]; then
      println INFO "\n${FG_YELLOW}WARN${NC}: No wallets available that can be delegated or used as pool pledge/owner/reward wallet! Required files:\n$(printf '%b\n' "$@")"
    elif [[ ${mode} = "reward" ]]; then
      println INFO "\n${FG_YELLOW}WARN${NC}: No wallets available that have rewards to withdraw or signing keys to do so!"
    elif [[ ${mode} = "reg" ]]; then
      println INFO "\n${FG_YELLOW}WARN${NC}: No wallets available that are registered on chain!"
    elif [[ ${mode} = "non-reg" ]]; then
      println INFO "\n${FG_YELLOW}WARN${NC}: No wallets available that are unregistered!"
    else
      println INFO "\n${FG_YELLOW}WARN${NC}: No wallets available for selection! Required files:\n$(printf '%b\n' "$@")"
    fi
    required_files=()
    already_selected_wallets=()
    for arg in "$@"; do
      [[ ${arg} = *"."* ]] && required_files+=("${arg}")
      [[ ${arg} != *"."* ]] && already_selected_wallets+=("${arg}")
    done
    [[ "${#already_selected_wallets[@]}" -gt 0 ]] && println INFO "Already selected wallets:\n$(printf '  %b\n' "${already_selected_wallets[@]}")"
    [[ "${#required_files[@]}" -gt 0 ]] && println INFO "Required files:\n$(printf '  %b\n' "${required_files[@]}")"
    return 1
  fi

  selectDir "wallet" "${wallet_dirs_filtered[@]}" || return $? # ${dir_name} populated by selectDir function
  wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"
}

# Command     : selectPool [mode] [file1 file2 ...]
# Description : A helper function to select a CNTools pool
# Parameters  : mode   >  a string containing some of the following: reg|non-reg|encrypted
#             : fileX  >  array of files required to exist in pool folder for it to be selectable
# Return      : populates ${pool_name} variable with pool selection
selectPool() {
  pool_dirs=()
  mode=$1 && shift
  enc_req_files=0
  if ! getDirs "${POOL_FOLDER}"; then return 1; fi # dirs() array populated with all pool folders
  for dir in "${dirs[@]}"; do
    for req_file in "$@"; do # check if pool is missing a required file and if so hide it
      [[ -f "${POOL_FOLDER}/${dir}/${req_file}.gpg" ]] && ((enc_req_files++))
      [[ ! -f "${POOL_FOLDER}/${dir}/${req_file}" ]] && continue 2
    done
    if [[ ${mode} = "encrypted" ]]; then
      enc_files=$(find "${POOL_FOLDER}/${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
      if [[ ${enc_files} -gt 0 ]]; then
        pool_dirs+=("${dir} (${FG_GREEN}encrypted${NC})")
      else
        pool_dirs+=("${dir} (${FG_YELLOW}unprotected${NC})")
      fi
      continue
    elif [[ ${mode} = "non-reg" || ${mode} = "reg" ]]; then
      isPoolRegistered "${dir}"
      case $? in
        0) println "ERROR" "KOIOS_API: ${error_msg}" &>/dev/null ;; # log error without printing but show pool
        1) [[ ${mode} = "reg" ]] && continue ;;
        2) [[ ${mode} = "non-reg" ]] && continue ;;
        3) [[ ${mode} = "non-reg" ]] && continue ;;
        4) [[ ${mode} = "reg" ]] && continue ;;
      esac
    fi
    pool_dirs+=("${dir}")
  done
  if [[ ${#pool_dirs[@]} -eq 0 ]]; then
    println ERROR "${FG_YELLOW}WARN${NC}: No pools available that can be selected! Required files:\n$(printf '%b\n' "$@")"
    [[ ${enc_req_files} -gt 0 ]] && println DEBUG "\n${FG_YELLOW}* Encrypted pools found but not listed *${NC}"
    return 1
  fi
  [[ ${enc_req_files} -gt 0 ]] && println DEBUG "${FG_YELLOW}encrypted pools found but NOT listed, please decrypt to show${NC}"
  selectDir "pool" "${pool_dirs[@]}" || return $? # ${dir_name} populated by selectDir function
  pool_name="$(echo ${dir_name} | cut -d' ' -f1)"
}

# Command     : isPoolRegistered [pool_name]
# Description : check if pool is registered on chain
#               existence of POOL_REGCERT_FILENAME checked when KOIOS API is not available
# Parameters  : pool_name   >  the name of the pool to check
# Return      : 0 => error quering KOIOS API (error message saved in ${error_msg})
#               1 => NOT registered
#               2 => registered
#               3 => retiring (only for KOIOS API)
#               4 => retired (only for KOIOS API)
isPoolRegistered() {
  unset error_msg pool_info pool_info_tsv pool_info_arr
  unset p_active_epoch_no p_vrf_key_hash p_margin p_fixed_cost p_pledge p_reward_addr p_owners p_relays p_meta_url p_meta_hash p_meta_json p_pool_status
  unset p_retiring_epoch p_op_cert p_op_cert_counter p_active_stake p_epoch_block_cnt p_live_stake p_live_delegators p_live_saturation
  if [[ ${CNTOOLS_MODE} != "LIGHT" ]]; then
    [[ -f "${POOL_FOLDER}/${1}/${POOL_REGCERT_FILENAME}" ]] && return 2 || (rm -f "${POOL_FOLDER}/${1}/${POOL_CURRENT_KES_START}" && return 1)
  else
    getPoolID "$1"
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json")
    println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '{\"_pool_bech32_ids\":[\"${pool_id_bech32}\"]}' ${KOIOS_API}/pool_info"
    ! pool_info=$(curl -sSL -f -X POST "${HEADERS[@]}" -d '{"_pool_bech32_ids":["'${pool_id_bech32}'"]}' "${KOIOS_API}/pool_info" 2>&1) && error_msg=${pool_info} && return 0
    if [[ ${pool_info} = '[]' ]]; then
      # possibly more cleanup needed, like rm -rf "${POOL_FOLDER}/${1}/${POOL_CURRENT_KES_START}" and ${POOL_REGCERT_FILENAME} if retirement was issued outside of CNTools?
      return 1
    fi
    pool_info_tsv=$(jq -r '[
    .[0].active_epoch_no //0,
    .[0].vrf_key_hash //"-",
    .[0].margin //0,
    .[0].fixed_cost //0,
    .[0].pledge //0,
    .[0].reward_addr //"-",
    (.[0].owners|@json),
    (.[0].relays|@json),
    .[0].meta_url //"-",
    .[0].meta_hash //"-",
    (.[0].meta_json|@base64),
    .[0].pool_status //"-",
    .[0].retiring_epoch //"-",
    .[0].op_cert //"-",
    .[0].op_cert_counter //"null",
    .[0].active_stake //0,
    .[0].block_count //0,
    .[0].live_pledge //0,
    .[0].live_stake //0,
    .[0].live_delegators //0,
    .[0].live_saturation //0
    ] | @tsv' <<< "${pool_info}")

    read -ra pool_info_arr <<< ${pool_info_tsv}

    p_active_epoch_no=${pool_info_arr[0]}
    p_vrf_key_hash=${pool_info_arr[1]}
    p_margin=${pool_info_arr[2]}
    p_fixed_cost=${pool_info_arr[3]}
    p_pledge=${pool_info_arr[4]}
    p_reward_addr=${pool_info_arr[5]}
    p_owners=${pool_info_arr[6]}
    p_relays=${pool_info_arr[7]}
    p_meta_url=${pool_info_arr[8]}
    p_meta_hash=${pool_info_arr[9]}
    p_meta_json=$(base64 -d <<< ${pool_info_arr[10]})
    p_pool_status=${pool_info_arr[11]}
    p_retiring_epoch=${pool_info_arr[12]}
    p_op_cert=${pool_info_arr[13]}
    p_op_cert_counter=${pool_info_arr[14]}
    p_active_stake=${pool_info_arr[15]}
    p_block_count=${pool_info_arr[16]}
    p_live_pledge=${pool_info_arr[17]}
    p_live_stake=${pool_info_arr[18]}
    p_live_delegators=${pool_info_arr[19]}
    p_live_saturation=${pool_info_arr[20]}

    [[ ${p_pool_status} = 'registered' ]] && return 2
    [[ ${p_pool_status} = 'retiring' ]] && return 3 || return 4
  fi
}

# Command     : isPoolRegistered [pool_name]
# Description : check if pool has a valid pool calidus key registered
# Parameters  : pool_name   >  the name of the pool to check
# Return      : 0 => error quering KOIOS API (error message saved in ${error_msg})
#               1 => No key registered
#               2 => registered
poolCalidusInfo() {
  unset error_msg
  if [[ ${CNTOOLS_MODE} != "LIGHT" ]]; then
    error_msg="Pool calidus key check only possible in light mode" && return 0
  else
    getPoolID "$1"
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json")
    println ACTION "curl -sSL -f -X POST ${HEADERS[*]} ${KOIOS_API}/pool_calidus_keys?pool_id_bech32=eq.${pool_id_bech32}"
    ! pool_calidus=$(curl -sSL -f -X POST "${HEADERS[@]}" "${KOIOS_API}/pool_calidus_keys?pool_id_bech32=eq.${pool_id_bech32}" 2>&1) && error_msg=${pool_calidus} && return 0
    [[ ${pool_calidus} = '[]' ]] && return 1
    pool_calidus_tsv=$(jq -r '[
    .[0].pool_status //"-",
    .[0].calidus_nonce //0,
    .[0].calidus_pub_key //"-",
    .[0].calidus_id_bech32 //"-",
    .[0].tx_hash //"-",
    .[0].epoch_no //0,
    .[0].block_height //0,
    .[0].block_time //0
    ] | @tsv' <<< "${pool_calidus}")

    read -ra pool_calidus_arr <<< ${pool_calidus_tsv}

    pc_status=${pool_calidus_arr[0]}
    pc_nonce=${pool_calidus_arr[1]}
    pc_pub_key=${pool_calidus_arr[2]}
    pc_id=${pool_calidus_arr[3]}
    pc_tx_hash=${pool_calidus_arr[4]}
    pc_epoch_no=${pool_calidus_arr[5]}
    pc_block_height=${pool_calidus_arr[6]}
    pc_block_time=${pool_calidus_arr[7]}

    if [[ ${pc_status} = 'registered' ]]; then return 2; else return 1; fi
  fi
}

# Command     : getAssetInfo [policy_id] [asset_name_hex]
# Description : Query Koios for asset information.
# Return      : 0: data saved in asset_<koios_field>
#               1: on error ($error_msg contains error message)
#               2: offline/disabled/no result
getAssetInfo() {
  unset
  if [[ ${CNTOOLS_MODE} != "LIGHT" || $# -lt 1 ]]; then
    return 2
  else
    println ACTION "curl -sSL -f ${KOIOS_API_HEADERS[*]} -d _asset_policy=$1 -d _asset_name=$2  ${KOIOS_API}/asset_info"
    ! asset_info=$(curl -sSL -f "${KOIOS_API_HEADERS[@]}" -d _asset_policy=$1 -d _asset_name=$2 "${KOIOS_API}/asset_info" 2>&1) && error_msg="${asset_info}" && return 1
    if [[ ${asset_info} = '[]' ]]; then
      return 2
    fi
    asset_info_tsv=$(jq -r '[
    (.[0].asset_name_ascii //"-" | @base64),
    .[0].fingerprint //"-",
    .[0].minting_tx_hash //"-",
    .[0].total_supply //0,
    .[0].mint_cnt //0,
    .[0].burn_cnt //0,
    .[0].creation_time //0,
    (.[0].minting_tx_metadata //"-" | @base64),
    (.[0].token_registry_metadata //"-" | @base64)
    ] | @tsv' <<< "${asset_info}")

    read -ra asset_info_arr <<< ${asset_info_tsv}

    a_asset_name_ascii=$(base64 -d <<< ${asset_info_arr[0]})
    a_fingerprint=${asset_info_arr[1]}
    a_minting_tx_hash=${asset_info_arr[2]}
    a_total_supply=${asset_info_arr[3]}
    a_mint_cnt=${asset_info_arr[4]}
    a_burn_cnt=${asset_info_arr[5]}
    a_creation_time=${asset_info_arr[6]}
    a_minting_tx_metadata=$(base64 -d <<< ${asset_info_arr[7]})
    a_token_registry_metadata=$(base64 -d <<< ${asset_info_arr[8]})
  fi
}

# Command     : selectPolicy [mode] [file1 file2 ...]
# Description : A helper function to select a Multi-Asset policy
# Parameters  : fileX  >  array of files required to exist in policy folder for it to be selectable
# Return      : populates ${policy_name} variable with selected policy
selectPolicy() {
  policy_dirs=()
  mode=$1 && shift
  enc_req_files=0
  if ! getDirs "${ASSET_FOLDER}"; then return 1; fi
  for dir in "${dirs[@]}"; do
    for req_file in "$@"; do # check if policy folder contain required files
      [[ -f "${ASSET_FOLDER}/${dir}/${req_file}.gpg" ]] && ((enc_req_files++))
      [[ ! -f "${ASSET_FOLDER}/${dir}/${req_file}" ]] && continue 2
    done
    if [[ ${mode} = "encrypted" ]]; then
      enc_files=$(find "${ASSET_FOLDER}/${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c)
      if [[ ${enc_files} -gt 0 ]]; then
        policy_dirs+=("${dir} (${FG_GREEN}encrypted${NC})")
      else
        policy_dirs+=("${dir} (${FG_YELLOW}unprotected${NC})")
      fi
      continue
    fi
    policy_dirs+=("${dir}")
  done
  if [[ ${#policy_dirs[@]} -eq 0 ]]; then
    println ERROR "${FG_YELLOW}WARN${NC}: No policies available that can be selected! Required files:\n$(printf '%b\n' "$@")"
    [[ ${enc_req_files} -gt 0 ]] && println DEBUG "\n${FG_YELLOW}* Encrypted policies found but not listed *${NC}"
    return 1
  fi
  [[ ${enc_req_files} -gt 0 ]] && println DEBUG "${FG_YELLOW}encrypted policies found but NOT listed, please decrypt to show${NC}"
  selectDir "policy" "${policy_dirs[@]}" || return $? # ${dir_name} populated by selectDir function
  policy_name="$(echo ${dir_name} | cut -d' ' -f1)"
}

# Command     : selectAsset
# Description : A helper function to select a Multi-Asset minted on device
# Return      : populates ${policy_dir}, ${asset_name} & ${asset_file} variables
selectAsset() {
  asset_list=() # <policy_id>.<asset_name>
  if ! getDirs "${ASSET_FOLDER}"; then return 1; fi
  for dir in "${dirs[@]}"; do
    if [[ $(find "${ASSET_FOLDER}/${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
      while IFS= read -r -d '' asset; do
        asset_file=${asset##*/}
        asset_list+=("${dir}/${asset_file%%.*}")
      done < <(find "${ASSET_FOLDER}/${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
    fi
  done
  if [[ ${#asset_list[@]} -eq 0 ]]; then
    println ERROR "${FG_YELLOW}WARN${NC}: No assets found on disk!"
    return 1
  fi
  selectDir "asset" "${asset_list[@]}" || return $? # ${dir_name} populated by selected value
  policy_dir="${dir_name%%/*}"
  asset_name="${dir_name##*/}"
  asset_file="${ASSET_FOLDER}/${policy_dir}/${asset_name}.asset"
}

# Command     : getPasswordCust [optional: confirm]
# Description : Get password from user on STDIN
# Parameters  : confirm  >  [optional] force user to provide password twice for confirmation
# Return      : populates ${password} variable, make sure to unset variable when done
getPasswordCust() {
  getPassword 8 $1
  return_code=$?
  return ${return_code}
}

# Command     : encryptFile [file] [password]
# Description : Encrypt file with GPG
# Parameters  : file      >  Path for file to encrypt, will get a new .gpg file extention added to filename
#             : password  >  Password to encrypt file with
encryptFile() {
  echo "${2}" | gpg --symmetric --yes --batch --cipher-algo AES256 --passphrase-fd 0 --output "${1}.gpg" "${1}" &>/dev/null && \
  safeDel "${1}" >/dev/null || {
    println ERROR "${FG_RED}ERROR${NC}: failed to encrypt ${1}"
    return 1
  }
  println DEBUG "${1} successfully encrypted"
}


# Command     : decryptFile [file] [password]
# Description : Decrypt file with GPG
# Parameters  : file      >  Path for file to decrypt, file extension .gpg required
#             : password  >  Password to decrypt file with
decryptFile() {
  echo "${2}" | gpg --decrypt --batch --yes --passphrase-fd 0 --output "${1%.*}" "${1}" &>/dev/null && \
  rm -f "${1}" || {
    println ERROR "${FG_RED}ERROR${NC}: failed to decrypt ${1}"
    return 1
  }
  println DEBUG "${1} successfully decrypted"
}

# Command     : unlockFile [file]
# Description : Unlock/remove write protection from file
# Parameters  : file      >  Path for file to unlock
unlockFile() {
  if [[ ${ENABLE_CHATTR} = true && $(lsattr -R "$1") =~ -i- ]]; then
    sudo chattr -i "${1}"
  fi
  chmod 600 "${1}"
}

# Command     : lockFile [file]
# Description : Lock/write protect file with chattr if enabled and Linux file permissions
# Parameters  : file      >  Path for file to lock
lockFile() {
  chmod 400 "$1"
  if [[ ${ENABLE_CHATTR} = true && ! $(lsattr -R "$1") =~ -i- ]]; then
    sudo chattr +i "$1"
  fi
}

# Command     : verifyTx [address]
# Description : Verify that the transaction was successfully registered by checking address balance against $newBalance
# Parameters  : address  >  the address to compare with
verifyTx() {
  [[ -z ${tx_id} ]] && println "\n${FG_RED}ERROR${NC}: transaction id not set, unable to verify transaction!" && return 1
  println DEBUG "Waiting for transaction to be seen on chain"
  if [[ ${NWMAGIC} == "764824073" ]]; then
    println DEBUG "Explore in detail: ${EXPLORER_TX//__tx_id__/${tx_id}}"
  else
    println DEBUG "Transaction ID: ${tx_id}"
  fi
  println DEBUG "${FG_BLUE}INFO${NC}: press any key to cancel and return (won't stop transaction)"
  while :; do
    read -r -n 1 -s -t 5 abort
    if [[ $? -eq 0 ]]; then
      println "\n${FG_YELLOW}WARN${NC}: aborted!! transaction still in queue!"
      return 1
    fi
    if [[ -n ${KOIOS_API} ]]; then
      HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json" -H "accept: text/csv")
      println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '{\"_tx_hashes\":[\"${tx_id}\"]' ${KOIOS_API}/tx_status?select=num_confirmations"
      ! num_confirmations=$(curl -sSL -f -X POST "${HEADERS[@]}" -d '{"_tx_hashes":["'${tx_id}'"]}' "${KOIOS_API}/tx_status?select=num_confirmations" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${num_confirmations}\n" && return 1 # print error and return
      result=$(tail -n +2 <<< ${num_confirmations})
    else
      println ACTION "${CCLI} query utxo --tx-in ${tx_id}#0 --output-text ${NETWORK_IDENTIFIER} | tail -n +3"
      result=$(${CCLI} query utxo --tx-in "${tx_id}#0" --output-text ${NETWORK_IDENTIFIER} | tail -n +3)
    fi
    [[ -n "${result}" ]] && { println DEBUG "\nTx put on chain !!"; break; } || printf .
  done
}

