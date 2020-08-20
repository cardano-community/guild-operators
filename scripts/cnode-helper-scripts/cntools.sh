#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034,SC2012

########## Global tasks ###########################################

# get common env variables
. "$(dirname $0)"/env

# get cntools config parameters
. "$(dirname $0)"/cntools.config

# get helper functions from library file
. "$(dirname $0)"/cntools.library

# create temporary directory if missing
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  say ""
  say "${RED}ERROR${NC}: Failed to create directory for temporary files:"
  say "${TMP_FOLDER}"
  say ""
  exit 1
fi

# check to see if there are any updates available
clear
say "CNTools version check...\n"
URL="https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts"
if wget -q -T 10 -O "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library"; then
  GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
  GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
  GIT_PATCH_VERSION=$(grep -r ^CNTOOLS_PATCH_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
  if [[ "$GIT_PATCH_VERSION" -eq 999  ]]; then
    ((GIT_MAJOR_VERSION++))
    GIT_MINOR_VERSION=0
    GIT_PATCH_VERSION=0
  fi
  if [[ "$CNTOOLS_PATCH_VERSION" -eq 999  ]]; then
    # CNTools was updated using special 999 patch tag, apply correct version in cntools.library and update variables already sourced
    sed -i "s/CNTOOLS_MAJOR_VERSION=[[:digit:]]\+/CNTOOLS_MAJOR_VERSION=$((++CNTOOLS_MAJOR_VERSION))/" "$CNODE_HOME/scripts/cntools.library"
    sed -i "s/CNTOOLS_MINOR_VERSION=[[:digit:]]\+/CNTOOLS_MINOR_VERSION=0/" "$CNODE_HOME/scripts/cntools.library"
    sed -i "s/CNTOOLS_PATCH_VERSION=[[:digit:]]\+/CNTOOLS_PATCH_VERSION=0/" "$CNODE_HOME/scripts/cntools.library"
    # CNTOOLS_MAJOR_VERSION variable already updated in sed replace command
    CNTOOLS_MINOR_VERSION=0
    CNTOOLS_PATCH_VERSION=0
    CNTOOLS_VERSION="${CNTOOLS_MAJOR_VERSION}.${CNTOOLS_MINOR_VERSION}.${CNTOOLS_PATCH_VERSION}"
  fi
  if [[ "${CNTOOLS_MAJOR_VERSION}" != "${GIT_MAJOR_VERSION}" || "${CNTOOLS_MINOR_VERSION}" != "${GIT_MINOR_VERSION}" || "${CNTOOLS_PATCH_VERSION}" != "${GIT_PATCH_VERSION}" ]]; then
    say "A new version of CNTools is available" "log"
    say ""
    say "Installed Version : ${CNTOOLS_VERSION}" "log"
    say "Available Version : ${GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}${NC}" "log"
    say "\nGo to Update section for upgrade\n\nAlternately, follow https://cardano-community.github.io/guild-operators/#/basics?id=pre-requisites to update cntools as well alongwith any other files"
    waitForInput "press any key to proceed"
  else
    # check if CNTools was recently updated, if so show whats new
    URL_DOCS="https://raw.githubusercontent.com/cardano-community/guild-operators/master/docs/Scripts"
    if wget -q -T 10 -O "${TMP_FOLDER}"/cntools-changelog.md "${URL_DOCS}/cntools-changelog.md"; then
      if ! cmp -s "${TMP_FOLDER}"/cntools-changelog.md "$CNODE_HOME/scripts/cntools-changelog.md"; then
        # Latest changes not shown, show whats new and copy changelog
        clear 
        say "~ CNTools - What's New ~"
        if [[ ! -f "$CNODE_HOME/scripts/cntools-changelog.md" ]]; then 
          # special case for first installation or 5.0.0 upgrade, print release notes until previous major version
          waitForInput "Press any key to show what's new in last major release, use 'q' to quit viewer"
          sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[$((CNTOOLS_MAJOR_VERSION-1))\.[0-9]\.[0-9]\]/p" "${TMP_FOLDER}"/cntools-changelog.md | head -n -2 | less
        else
          # print release notes from current until previously installed version
          waitForInput "Press any key to show what's new compared to currently installed release, use 'q' to quit viewer"
          [[ $(cat "$CNODE_HOME/scripts/cntools-changelog.md") =~ \[([[:digit:]])\.([[:digit:]])\.([[:digit:]])\] ]]
          sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[${BASH_REMATCH[1]}\.${BASH_REMATCH[2]}\.${BASH_REMATCH[3]}\]/p" "${TMP_FOLDER}"/cntools-changelog.md | head -n -2 | less
        fi
        cp "${TMP_FOLDER}"/cntools-changelog.md "$CNODE_HOME/scripts/cntools-changelog.md"
      fi
    else
      say "\n${RED}ERROR${NC}: failed to download changelog from GitHub!\n"
      waitForInput "press any key to proceed"
    fi
  fi
else
  say "\n${RED}ERROR${NC}: failed to download cntools.library from GitHub, unable to perform version check!\n"
  waitForInput "press any key to proceed"
fi
clear

# check for required command line tools
if ! need_cmd "curl" || \
   ! need_cmd "jq" || \
   ! need_cmd "bc" || \
   ! need_cmd "sed" || \
   ! need_cmd "awk" || \
   ! need_cmd "column"; then exit 1
fi

# Check if config is a valid json file
if ! jq -e . >/dev/null 2>&1 "${CONFIG}"; then
  say "\n${RED}ERROR${NC}: Please ensure that your config file is in JSON format\n"
  say "Config file: ${CONFIG}"
  exit 1
fi

# Verify that Prometheus is enabled in config file
prom_port=$(jq -r '.hasPrometheus[1] //empty' ${CONFIG} 2>/dev/null)
prom_host=$(jq -r '.hasPrometheus[0] //empty' ${CONFIG} 2>/dev/null)

if [[ -z "${prom_port}" ]]; then
  say "\n${RED}ERROR${NC}: Please ensure that hasPrometheus is enabled, if unsure - rerun \"<path>/prereqs.sh -s\" again - and it would overwrite the config file\n"
  exit 1
fi

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
[[ -f "${TMP_FOLDER}"/protparams.json ]] && rm -f "${TMP_FOLDER}"/protparams.json 2>/dev/null
${CCLI} shelley query protocol-parameters ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} >"${TMP_FOLDER}/protparams.json" 2>&1
if grep -q "Network.Socket.connect" "${TMP_FOLDER}/protparams.json"; then
  say "\n${ORANGE}WARN${NC}: node socket path wrongly configured or node not running, please verify that socket set in env file match what is used to run the node"
  say "\n${BLUE}Press c to continue or any other key to quit${NC}"
  say "only offline functions will be available if you continue\n"
  read -r -n 1 -s -p "" answer
  [[ "${answer}" != "c" ]] && exit 1
elif ! jq . "${TMP_FOLDER}/protparams.json" &>/dev/null; then
  say "\n${ORANGE}WARN${NC}: failed to query protocol parameters, ensure your node is running with correct genesis (the node needs to be in sync to 1 epoch after the hardfork)"
  say "\nError message: $(cat "${TMP_FOLDER}/protparams.json")"
  say "\n${BLUE}Press c to continue or any other key to quit${NC}"
  say "only offline functions will be available if you continue\n"
  read -r -n 1 -s -p "" answer
  [[ "${answer}" != "c" ]] && exit 1
fi

# Verify if the combinator network is already on shelley and if so, the epoch of transition
if [[ "${PROTOCOL}" == "Cardano" ]]; then
  shelleyTransitionEpoch=$(cat "${SHELLEY_TRANS_FILENAME}" 2>/dev/null)
  if [[ -z "${shelleyTransitionEpoch}" ]]; then
    clear
    getPromMetrics
    slot_in_epoch=$(grep "cardano_node_ChainDB_metrics_slotInEpoch_int" "${TMP_FOLDER}"/prom_metrics | awk '{print $2}')
    slot_num=$(grep "cardano_node_ChainDB_metrics_slotNum_int" "${TMP_FOLDER}"/prom_metrics | awk '{print $2}')
    epoch=$(grep "cardano_node_ChainDB_metrics_epoch_int" "${TMP_FOLDER}"/prom_metrics | awk '{print $2}')
    calc_slot=0
    byron_epochs=${epoch}
    shelley_epochs=0
    while [[ ${byron_epochs} -ge 0 ]]; do
      calc_slot=$(( (byron_epochs*byron_epoch_length) + (shelley_epochs*epoch_length) + slot_in_epoch ))
      [[ ${calc_slot} -eq ${slot_num} ]] && break
      ((byron_epochs--))
      ((shelley_epochs++))
    done
    say "\nNODE SYNC:"
    printTable ',' "$(echo -e "Epoch,Slot in Epoch,Slot\n${epoch},${slot_in_epoch},${slot_num}")"
    if [[ "${NETWORK_IDENTIFIER}" == "--mainnet" ]]; then
      shelleyTransitionEpoch="208"
    elif [[ ${calc_slot} -ne ${slot_num} ]]; then
      say "\n${ORANGE}WARN${NC}: Failed to calculate shelley transition epoch\n"
      exit 1
    elif [[ ${shelley_epochs} -eq 0 ]]; then
      say "\n${ORANGE}WARN${NC}: The network has not reached the hard fork from Byron to shelley, please wait to use CNTools until your node is in shelley era\n"
      exit 1
    else
      shelleyTransitionEpoch=${byron_epochs}
    fi
    echo "${shelleyTransitionEpoch}" > "${SHELLEY_TRANS_FILENAME}"
  fi
fi

# check if there are pools in need of KES key rotation
clear
kes_rotation_needed="no"
while IFS= read -r -d '' pool; do
  if [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
    kesExpiration "$(cat "${pool}/${POOL_CURRENT_KES_START}")"
    if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
      kes_rotation_needed="yes"
      say "\n** WARNING **\nPool ${GREEN}$(basename ${pool})${NC} in need of KES key rotation"
      if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
        say "${RED}Keys expired!${NC} : ${RED}$(showTimeLeft ${expiration_time_sec_diff:1})${NC} ago"
      else
        say "Time left : ${RED}$(showTimeLeft ${expiration_time_sec_diff})${NC}"
      fi
    elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
      kes_rotation_needed="yes"
      say "\nPool ${GREEN}$(basename ${pool})${NC} soon in need of KES key rotation"
      say "Time left : ${ORANGE}$(showTimeLeft ${expiration_time_sec_diff})${NC}"
    fi
  fi
done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
[[ ${kes_rotation_needed} = "yes" ]] && waitForInput "press any key to proceed"

###################################################################

function main {

while true; do # Main loop

# Start with a clean slate after each completed or canceled command excluding protparams.json from purge
find "${TMP_FOLDER:?}" -type f -not -name 'protparams.json' -delete

clear
say "$(printf "%-52s %s" " >> CNTools $CNTOOLS_VERSION << " "A Guild Operators collaboration")" "log"
say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
say " Main Menu"
say ""
say " ) Wallet  -  create, show, remove and protect wallets"
say " ) Funds   -  send, withdraw and delegate"
say " ) Pool    -  pool creation and management"
say " ) Blocks  -  show core node leader slots"
say " ) Update  -  update cntools script and library config files"
say " ) Backup  -  backup & restore of wallet/pool/config"
say " ) Refresh -  reload home screen content"
say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
say "$(printf "%84s" "Epoch $(getEpoch) - $(timeUntilNextEpoch) until next")"
tip_diff=$(getSlotTipDiff)
slot_interval=$(slotInterval)
if [[ ${tip_diff} -le ${slot_interval} ]]; then
  say "$(printf " %-20s %73s" "What would you like to do?" "Node Sync: ${GREEN}-${tip_diff} :)${NC}")"
elif [[ ${tip_diff} -le $(( slot_interval * 2 )) ]]; then
  say "$(printf " %-20s %73s" "What would you like to do?" "Node Sync: ${LGRAY1}-${tip_diff} :|${NC}")"
else
  say "$(printf " %-20s %73s" "What would you like to do?" "Node Sync: ${RED}-${tip_diff} :(${NC}")"
fi
say ""
case $(select_opt "[w] Wallet" "[f] Funds" "[p] Pool" "[b] Blocks" "[u] Update" "[z] Backup & Restore" "[r] Refresh" "[q] Quit") in
  0) OPERATION="wallet" ;;
  1) OPERATION="funds" ;;
  2) OPERATION="pool" ;;
  3) OPERATION="blocks" ;;
  4) OPERATION="update" ;;
  5) OPERATION="backup" ;;
  6) continue ;;
  7) clear && exit ;;
esac

case $OPERATION in
  wallet)

  clear
  say " >> WALLET" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say " Wallet Management"
  say ""
  say " ) New      -  create a new wallet"
  say " ) List     -  list all available wallets in a compact view"
  say " ) Show     -  show detailed view of a specific wallet"
  say " ) Remove   -  remove a wallet"
  say " ) Decrypt  -  remove write protection and decrypt wallet"
  say " ) Encrypt  -  encrypt wallet keys and make all files immutable"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  say " Select Wallet operation\n"
  case $(select_opt "[n] New" "[l] List" "[s] Show" "[r] Remove" "[d] Decrypt" "[e] Encrypt" "[h] Home") in
    0) SUBCOMMAND="new" ;;
    1) SUBCOMMAND="list" ;;
    2) SUBCOMMAND="show" ;;
    3) SUBCOMMAND="remove" ;;
    4) SUBCOMMAND="decrypt" ;;
    5) SUBCOMMAND="encrypt" ;;
    6) continue ;;
  esac

  case $SUBCOMMAND in
    new)

    clear
    say " >> WALLET >> NEW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""
    read -r -p "Name of new wallet: " wallet_name
    # Remove unwanted characters from wallet name
    wallet_name=${wallet_name//[^[:alnum:]]/_}
    if [[ -z "${wallet_name}" ]]; then
      say "${RED}ERROR${NC}: Empty wallet name, please retry!"
      waitForInput && continue
    fi
    say ""
    mkdir -p "${WALLET_FOLDER}/${wallet_name}"

    # Wallet key filenames
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"

    if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -printf '.' | wc -c) -gt 0 ]]; then
      say "${RED}WARN${NC}: A wallet ${GREEN}$wallet_name${NC} already exists"
      say "      Choose another name or delete the existing one"
      waitForInput && continue
    fi

    ${CCLI} shelley address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}"
    ${CCLI} shelley stake-address key-gen --verification-key-file "${stake_vk_file}" --signing-key-file "${stake_sk_file}"
    getBaseAddress ${wallet_name}
    getPayAddress ${wallet_name}
    getRewardAddress ${wallet_name}

    say "New Wallet          : ${GREEN}${wallet_name}${NC}" "log"
    say "Address             : ${base_addr}" "log"
    say "Enterprise Address  : ${pay_addr}" "log"
    say "\nYou can now send and receive ADA using the above. Note that Enterprise Address will not take part in staking."
    say "Wallet will be automatically registered on chain if you\nchoose to delegate or pledge wallet when registering a stake pool."
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    list)

    clear
    say " >> WALLET >> LIST" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    while IFS= read -r -d '' wallet; do
      wallet_name=$(basename ${wallet})
      enc_files=$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -printf '.' | wc -c)
      say ""
      if [[ ${enc_files} -gt 0 ]]; then
        say "${GREEN}${wallet_name}${NC} (${ORANGE}encrypted${NC})" "log"
        base_addr=$(cat "${wallet}/${WALLET_BASE_ADDR_FILENAME}")
        pay_addr=$(cat "${wallet}/${WALLET_PAY_ADDR_FILENAME}")
      else
        say "${GREEN}${wallet_name}${NC}" "log"
        getBaseAddress ${wallet_name}
        getPayAddress ${wallet_name}
      fi
      if [[ -n ${base_addr} ]]; then
        getBalance ${base_addr}
        say "$(printf "%s\t\t\t${CYAN}%s${NC} ADA" "Funds"  "$(formatLovelace ${lovelace})")" "log"
      fi
      if [[ -n ${pay_addr} ]]; then
        getBalance ${pay_addr}
        if [[ ${lovelace} -gt 0 ]]; then
          say "$(printf "%s\t${CYAN}%s${NC} ADA" "Enterprise Funds"  "$(formatLovelace ${lovelace})")" "log"
        fi
      fi
      if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
        say "${RED}Not a supporeted wallet${NC} - genesis address?"
        say "Use an external script to send funds to a CNTools compatible wallet"
        continue
      fi
      getRewards ${wallet_name}
      if [[ "${reward_lovelace}" -ge 0 ]]; then
        say "$(printf "%s\t\t\t${CYAN}%s${NC} ADA" "Rewards" "$(formatLovelace ${reward_lovelace})")" "log"
        delegation_pool_id=$(jq -r '.delegation // empty' <<< "${stakeAddressInfo}")
        if [[ -n ${delegation_pool_id} ]]; then
          unset poolName
          while IFS= read -r -d '' pool; do
            getPoolID "$(basename ${pool})"
            if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
              poolName=$(basename ${pool}) && break
            fi
          done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          say "${RED}Delegated to${NC} ${BLUE}${poolName}${NC} ${RED}(${delegation_pool_id})${NC}" "log"
        fi
      fi
    done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput
    ;; ###################################################################

    show)

    clear
    say " >> WALLET >> SHOW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    for dir in "${dirs[@]}"; do
      enc_files=$(find "${WALLET_FOLDER}/${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -printf '.' | wc -c)
      if ! getBaseAddress "${dir}" && ! getPayAddress "${dir}" && [[ ${enc_files} -eq 0 ]]; then continue; fi
      wallet_dirs+=("${dir}")
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available!"
      say "first create a wallet"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name=${dir_name}
    enc_files=$(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -printf '.' | wc -c)

    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""
    if [[ ${enc_files} -gt 0 ]]; then
      base_addr=$(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}")
      pay_addr=$(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}")
      say "$(printf "%-8s ${GREEN}%s${NC} ${ORANGE}%s${NC}" "Wallet" "${wallet_name}" "(encrypted)")" "log"
    else
      getBaseAddress ${wallet_name}
      getPayAddress ${wallet_name}
      say "$(printf "%-8s ${GREEN}%s${NC}" "Wallet" "${wallet_name}")" "log"
    fi

    getBalance ${base_addr}
    base_lovelace=${lovelace}
    if [[ ${utx0_count} -gt 0 ]]; then
      say ""
      say "${BLUE}UTxOs${NC}"
      head -n 2 "${TMP_FOLDER}"/fullUtxo.out
      head -n 10 "${TMP_FOLDER}"/balance.out
      [[ ${utx0_count} -gt 10 ]] && say "... (top 10 UTx0 with most lovelace)"
    fi

    getBalance ${pay_addr}
    pay_lovelace=${lovelace}
    if [[ ${utx0_count} -gt 0 ]]; then
      say ""
      say "${BLUE}Enterprise UTxOs${NC}"
      head -n 2 "${TMP_FOLDER}"/fullUtxo.out
      head -n 10 "${TMP_FOLDER}"/balance.out
      [[ ${utx0_count} -gt 10 ]] && say "... (top 10 UTx0 with most lovelace)"
    fi

    say ""
    say "$(printf "%-19s : %s" "Address" "${base_addr}")" "log"
    say "$(printf "%-19s : ${CYAN}%s${NC} ADA" "Funds" "$(formatLovelace ${base_lovelace})")" "log"
    getAddressInfo "${base_addr}"
    say "$(printf "%-19s : %s" "Era" "$(jq -r '.era' <<< ${address_info})")" "log"
    say "$(printf "%-19s : %s" "Encoding" "$(jq -r '.encoding' <<< ${address_info})")" "log"
    say "$(printf "%-19s : %s" "Enterprise Address" "${pay_addr}")" "log"
    say "$(printf "%-19s : ${CYAN}%s${NC} ADA" "Enterprise Funds" "$(formatLovelace ${pay_lovelace})")" "log"
    getRewards ${wallet_name}
    if [[ "${reward_lovelace}" -ge 0 ]]; then
      say "$(printf "%-19s : ${CYAN}%s${NC} ADA" "Rewards" "$(formatLovelace ${reward_lovelace})")" "log"
      delegation_pool_id=$(jq -r '.delegation  // empty' <<< "${stakeAddressInfo}")
      if [[ -n ${delegation_pool_id} ]]; then
        unset poolName
        while IFS= read -r -d '' pool; do
          getPoolID "$(basename ${pool})"
          if [[ "${pool_id_bech32}" = "${delegation_pool_id}" ]]; then
            poolName=$(basename ${pool}) && break
          fi
        done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
        say ""
        say "${RED}Delegated to${NC} ${BLUE}${poolName}${NC} ${RED}(${delegation_pool_id})${NC}" "log"
      fi
    fi
    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput

    ;; ###################################################################

    remove)

    clear
    say " >> WALLET >> REMOVE" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    if [[ ${#dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available!"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="${dir_name}"

    if ! getBaseAddress ${wallet_name} && ! getPayAddress ${wallet_name}; then
      say "${RED}WARN${NC}: unable to get address for wallet and do a balance check"
      say "\nAre you sure to delete wallet anyway?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
           say "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
           ;;
        1) say "skipped removal process for ${GREEN}$wallet_name${NC}"
           ;;
      esac
      waitForInput && continue
    fi

    if [[ -n ${base_addr} ]]; then
      getBalance ${base_addr}
      base_lovelace=${lovelace}
    else
      base_lovelace=0
    fi
    if [[ -n ${pay_addr} ]]; then
      getBalance ${pay_addr}
      pay_lovelace=${lovelace}
    else
      pay_lovelace=0
    fi
    getRewards ${wallet_name}

    if [[ ${base_lovelace} -eq 0 && ${pay_lovelace} -eq 0 && ${reward_lovelace} -le 0 ]]; then
      say "INFO: This wallet appears to be empty"
      say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      say "Are you sure to delete wallet?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
           say "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
           ;;
        1) say "skipped removal process for ${GREEN}$wallet_name${NC}"
           ;;
      esac
    else
      say "${RED}WARN${NC}: wallet not empty!"
      [[ ${base_lovelace} -gt 0 ]] && say "Funds : ${CYAN}$(formatLovelace ${base_lovelace})${NC} ADA"
      [[ ${pay_lovelace} -gt 0 ]] && say "Enterprise Funds : ${CYAN}$(formatLovelace ${base_lovelace})${NC} ADA"
      [[ ${reward_lovelace} -gt 0 ]] && say "Rewards : ${CYAN}$(formatLovelace ${reward_lovelace})${NC} ADA"
      say ""
      say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      say "Are you sure to delete wallet?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
           say "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
           ;;
        1) say "skipped removal process for ${GREEN}$wallet_name${NC}"
           ;;
      esac
    fi

    waitForInput

    ;; ###################################################################

    decrypt)

    clear
    say " >> WALLET >> DECRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    protectionPreRequisites || continue

    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    if [[ ${#dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available!"
      say "first create a wallet"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="${dir_name}"

    filesUnlocked=0
    keysDecrypted=0

    say "# Removing write protection from all wallet files" "log"
    while IFS= read -r -d '' file; do
      if [[ $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}" && \
        chmod 600 "${file}" && \
        filesUnlocked=$((++filesUnlocked))
        say "${file}"
      fi
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    say ""
    say "# Decrypting GPG encrypted wallet files" "log"
    say ""
    say "Wallet ${GREEN}${wallet_name}${NC} Password"
    say ""
    if ! getPassword; then # $password variable populated by getPassword function
      say "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password

    say ""
    say "Wallet unprotected: ${GREEN}${wallet_name}${NC}" "log"
    say "Files unlocked:     ${filesUnlocked}" "log"
    say "Files decrypted:    ${keysDecrypted}" "log"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
      say ""
      say "${ORANGE}Wallet files are now unprotected${NC}"
      say "Use 'WALLET >> ENCRYPT' to re-lock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

    encrypt)

    clear
    say " >> WALLET >> ENCRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    protectionPreRequisites || continue

    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    if [[ ${#dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available!"
      say "first create a wallet"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="${dir_name}"

    filesLocked=0
    keysEncrypted=0

    say "# Encrypting sensitive wallet keys with GPG" "log"
    say ""
    say "Wallet ${GREEN}${wallet_name}${NC} Password"
    say ""
    if ! getPassword confirm; then # $password variable populated by getPassword function
      say "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    keyFiles=(
      "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    )
    for keyFile in "${keyFiles[@]}"; do
      if [[ -f "${keyFile}" ]]; then
        chmod 400 "${keyFile}" && \
        encryptFile "${keyFile}" "${password}" && \
        keysEncrypted=$((++keysEncrypted))
      fi
    done
    unset password

    say ""
    say "# Write protecting all wallet keys using 'chattr +i'" "log"
    while IFS= read -r -d '' file; do
      if [[ ${file} != *.addr && ! $(lsattr -R "$file") =~ -i- ]]; then
        chmod 400 "${file}" && \
        sudo chattr +i "${file}" && \
        filesLocked=$((++filesLocked)) && \
        say "${file}"
      fi
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    say ""
    say "Wallet protected: ${GREEN}${wallet_name}${NC}" "log"
    say "Files locked:     ${filesLocked}" "log"
    say "Files encrypted:  ${keysEncrypted}" "log"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      say ""
      say "${BLUE}Wallet files are now protected${NC}"
      say "Use 'WALLET >> DECRYPT' to unlock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

  esac

  ;; ###################################################################

  funds)

  clear
  say " >> FUNDS" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say " Handle Funds"
  say ""
  say " 1) Send      -  send ADA from a local wallet to an address or a wallet"
  say " 2) Delegate  -  delegate stake wallet to a pool"
  say " 3) Withdraw  -  withdraw earned rewards to base address"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  say " Select funds operation\n"
  case $(select_opt "[s] Send" "[d] Delegate" "[w] Withdraw Rewards" "[h] Home") in
    0) SUBCOMMAND="send" ;;
    1) SUBCOMMAND="delegate" ;;
    2) SUBCOMMAND="withdrawrewards" ;;
    3) continue ;;
  esac

  case $SUBCOMMAND in
    withdrawrewards)

    clear
    say " >> FUNDS >> WITHDRAW REWARDS" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]] && say "Balance checking wallets...\n"
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getRewards ${dir}
        [[ ${reward_lovelace} -le 0 ]] && continue
        wallet_dirs+=("${dir} (Rewards: ${CYAN}$(formatLovelace ${reward_lovelace})${NC} ADA)")
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that have rewards to withdraw!"
      say "Encrypted wallets not checked, please decrypt wallet first if encrypted"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"

    getBaseAddress ${wallet_name}
    stake_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_ADDR_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

    getBalance ${base_addr}
    getRewards ${wallet_name}

    if [[ ${reward_lovelace} -le 0 ]]; then
      say "Failed to locate any rewards associated with the chosen wallet, please try another one"
      waitForInput && continue
    elif [[ ${lovelace} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No funds in base address, please send funds to base address of wallet to cover withdraw transaction fee"
      waitForInput && continue
    fi

    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds"  "$(formatLovelace ${lovelace})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(formatLovelace ${reward_lovelace})")" "log"

    if ! withdrawRewards "${stake_vk_file}" "${stake_sk_file}" "${pay_payment_sk_file}" "${base_addr}" "${reward_addr}" ${reward_lovelace}; then
      say "" && say "${RED}ERROR${NC}: failure during withdrawal of rewards"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    getRewards ${wallet_name}

    say ""
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds"  "$(formatLovelace ${lovelace})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(formatLovelace ${reward_lovelace})")" "log"
    waitForInput

    ;; ###################################################################

    send)

    clear
    say " >> FUNDS >> SEND" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    s_wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]] && say "Balance checking wallets...\n"
    for dir in "${dirs[@]}"; do
      s_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${s_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBaseAddress ${dir}
        getPayAddress ${dir}
        getBalance ${base_addr}
        base_lovelace=${lovelace}
        getBalance ${pay_addr}
        pay_lovelace=${lovelace}
        if [[ ${base_lovelace} -gt 0 && ${pay_lovelace} -gt 0 ]]; then
          s_wallet_dirs+=("${dir} (Funds: ${CYAN}$(formatLovelace ${base_lovelace})${NC} ADA | Enterprise Funds: ${CYAN}$(formatLovelace ${pay_lovelace})${NC} ADA)")
        elif [[ ${base_lovelace} -gt 0 ]]; then
          s_wallet_dirs+=("${dir} (Funds: ${CYAN}$(formatLovelace ${base_lovelace})${NC} ADA)")
        elif [[ ${pay_lovelace} -gt 0 ]]; then
          s_wallet_dirs+=("${dir} (Enterprise Funds: ${CYAN}$(formatLovelace ${pay_lovelace})${NC} ADA)")
        fi
      else
        s_wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#s_wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that have funds to send!"
      say "Encrypted wallets not checked, please decrypt wallet first if encrypted"
      waitForInput && continue
    fi
    say "Select Source Wallet:\n"
    if ! selectDir "${s_wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    s_wallet="$(echo ${dir_name} | cut -d' ' -f1)"

    getBaseAddress ${s_wallet}
    getPayAddress ${s_wallet}
    getBalance ${base_addr}
    base_lovelace=${lovelace}
    getBalance ${pay_addr}
    pay_lovelace=${lovelace}

    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      say "Select source wallet address"
      say "$(printf "%s\t\t${CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
      say ""
      case $(select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel") in
        0) s_addr="${base_addr}" ;;
        1) s_addr="${pay_addr}" ;;
        2) continue ;;
      esac
    elif [[ ${pay_lovelace} -gt 0 ]]; then
      s_addr="${pay_addr}"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(formatLovelace ${pay_lovelace})")" "log"
    elif [[ ${base_lovelace} -gt 0 ]]; then
      s_addr="${base_addr}"
      say "$(printf "%s\t\t${CYAN}%s${NC} ADA" "Funds :"  "$(formatLovelace ${base_lovelace})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${s_wallet}${NC}"
      waitForInput && continue
    fi

    s_payment_sk_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_SK_FILENAME}"

    # Amount
    say ""
    say " -- Amount to Send (in ADA) --"
    say ""
    say "Valid entry:  ${BLUE}Integer (e.g. 15) or Decimal (e.g. 956.1235) - no commas allowed${NC}"
    say "              The string '${BLUE}all${NC}' to send all available funds in source wallet"
    say ""
    say "Info:         If destination and source wallet is the same and amount set to 'all',"
    say "              wallet will be defraged, ie converts multiple UTxO's to one"
    say ""
    read -r -p "Amount (ADA): " amountADA

    if  [[ "${amountADA}" != "all" ]]; then
      if ! ADAtoLovelace "${amountADA}" >/dev/null; then
        waitForInput && continue
      fi
      amountLovelace=$(ADAtoLovelace "${amountADA}")
      say ""
      say "Fee payed by sender? [else amount sent is reduced]\n"
      case $(select_opt "[y] Yes" "[n] No" "[Esc] Cancel") in
        0) include_fee="no" ;;
        1) include_fee="yes" ;;
        2) continue ;;
      esac
    else
      say ""
      getBalance ${s_addr}
      amountLovelace=${lovelace}
      say "ADA to send set to total supply: $(formatLovelace ${amountLovelace})" "log"
      say ""
      include_fee="yes"
    fi

    # Destination
    d_wallet=""
    say "Is destination a local wallet or an address?\n"
    case $(select_opt "[w] Wallet" "[a] Address" "[Esc] Cancel") in
      0) d_wallet_dirs=()
         if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
         for dir in "${dirs[@]}"; do
           if getBaseAddress ${dir} || getPayAddress ${dir}; then
             d_wallet_dirs+=("${dir}")
           fi
         done
         say "Select Destination Wallet:\n"
         if ! selectDir "${d_wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
         d_wallet="${dir_name}"

         getBaseAddress ${d_wallet}
         getPayAddress ${d_wallet}

         if [[ -n "${base_addr}" && "${base_addr}" != "${s_addr}" && -n "${pay_addr}" && "${pay_addr}" != "${s_addr}" ]]; then
           # Both base and enterprise address available, let user choose what to use
           say "Select destination wallet address"
           case $(select_opt "[b] Base (default)" "[e] Enterprise" "[Esc] Cancel") in
             0) d_addr="${base_addr}" ;;
             1) d_addr="${pay_addr}" ;;
             2) continue ;;
           esac
         elif [[ -n "${base_addr}" && "${base_addr}" != "${s_addr}" ]]; then
           d_addr="${base_addr}"
         elif [[ -n "${pay_addr}" && "${pay_addr}" != "${s_addr}" ]]; then
           d_addr="${pay_addr}"
         elif [[ "${base_addr}" = "${s_addr}" || "${pay_addr}" = "${s_addr}" ]]; then
           say "${RED}ERROR${NC}: sending to same address as source not supported"
           waitForInput && continue
         else
           say "${RED}ERROR${NC}: no address found for wallet ${GREEN}${d_wallet}${NC} :("
           waitForInput && continue
         fi
         ;;
      1) say "" && read -r -p "Address: " d_addr ;;
      2) continue ;;
    esac
    # Destination could be empty, if so without getting a valid address
    if [[ -z ${d_addr} ]]; then
      say "${RED}ERROR${NC}: destination address field empty"
      waitForInput && continue
    fi

    if ! sendADA "${d_addr}" "${amountLovelace}" "${s_addr}" "${s_payment_sk_file}" "${include_fee}"; then
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${s_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${s_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    s_balance=${lovelace}

    getBalance ${d_addr}

    d_balance=${lovelace}

    getPayAddress ${s_wallet}
    [[ "${pay_addr}" = "${s_addr}" ]] && s_wallet_type=" (Enterprise)" || s_wallet_type=""
    getPayAddress ${d_wallet}
    [[ "${pay_addr}" = "${d_addr}" ]] && d_wallet_type=" (Enterprise)" || d_wallet_type=""

    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say "Transaction" "log"
    say "  From          : ${GREEN}${s_wallet}${NC}${s_wallet_type}" "log"
    say "  Amount        : $(formatLovelace ${amountLovelace}) ADA" "log"
    if [[ -n "${d_wallet}" ]]; then
      say "  To            : ${GREEN}${d_wallet}${NC}${d_wallet_type}" "log"
    else
      say "  To            : ${d_addr}" "log"
    fi
    say "  Fees          : $(formatLovelace ${minFee}) ADA" "log"
    say "  Balance" "log"
    say "  - Source      : $(formatLovelace ${s_balance}) ADA" "log"
    say "  - Destination : $(formatLovelace ${d_balance}) ADA" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    waitForInput

    ;; ###################################################################

    delegate)  # [WALLET NAME] [POOL NAME]

    clear
    say " >> FUNDS >> DELEGATE" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]] && say "Balance checking wallets...\n"
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      if ! getBaseAddress ${dir} && [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]]; then continue; fi
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance ${base_addr}
        [[ ${lovelace} -eq 0 ]] && continue
        if getRewardAddress ${dir}; then
          delegation_pool_id=$(${CCLI} shelley query stake-address-info ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --address "${reward_addr}" | jq -r '.[0].delegation // empty')
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
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
          elif [[ -n ${delegation_pool_id} ]]; then
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA - ${RED}delegated${NC} to external address)")
          else
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA)")
          fi
        else
          wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be delegated!"
      say "Encrypted wallets not checked, please decrypt wallet first if encrypted"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"

    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in wallet:"  "$(formatLovelace ${lovelace})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${wallet_name}${NC}"
      waitForInput && continue
    fi
    getRewards ${wallet_name}

    if [[ reward_lovelace -eq -1 ]] && ! registerStakeWallet ${wallet_name}; then
      waitForInput && continue
    fi

    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

    say ""
    say "Do you want to delegate to a local pool or specify the pools cold vkey cbor-hex?\n"
    case $(select_opt "[p] Pool" "[v] Vkey" "[Esc] Cancel") in
      0) pool_dirs=()
         if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
         for dir in "${dirs[@]}"; do
           pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
           [[ ! -f "${pool_coldkey_vk_file}" ]] && continue
           pool_dirs+=("${dir}")
         done
         if [[ ${#pool_dirs[@]} -eq 0 ]]; then
           say "${ORANGE}WARN${NC}: No pools available to delegate to!"
           say "first create and register a pool or choose to delegate using pools cold vkey cbor-hex"
           waitForInput && continue
         fi
         say "Select Pool:\n"
         if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
         pool_name="${dir_name}"
         pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
         ;;
      1) read -r -p "vkey cbor-hex(blank to cancel): " vkey_cbor
         [[ -z "${vkey_cbor}" ]] && continue
         pool_name="${vkey_cbor}"
         pool_coldkey_vk_file="${TMP_FOLDER}"/pool_delegation.vkey
         printf "{\"type\":\"StakePoolVerificationKey_ed25519\",\"description\":\"Stake Pool Operator Verification Key\",\"cborHex\":\"%s\"}" ${vkey_cbor} > "${pool_coldkey_vk_file}"
         ;;
      2) continue ;;
    esac

    #Generated Files
    delegation_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"

    say "creating delegation cert" 1 "log"
    say "$ ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file ${stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${delegation_cert_file}" 2
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${delegation_cert_file}"

    if ! delegate "${stake_vk_file}" "${stake_sk_file}" "${pay_payment_sk_file}" "${base_addr}" "${pool_coldkey_vk_file}" "${delegation_cert_file}" ; then
      say "" && say "${RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
      rm -f "${delegation_cert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    say "Delegation successfully registered"
    say "Wallet : ${GREEN}${wallet_name}${NC}"
    say "Pool   : ${GREEN}${pool_name}${NC}" "log"
    say "Amount : $(formatLovelace ${lovelace}) ADA" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput && continue
    ;; ###################################################################

  esac

  ;; ###################################################################

  pool)

  clear
  say " >> POOL" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say " Pool Management"
  say ""
  say " ) New        -  create a new pool"
  say " ) Register   -  register created pool on chain using a stake wallet (pledge wallet)"
  say " ) Modify     -  change pool parameters and register updated pool values on chain"
  say " ) Retire     -  de-register stake pool from chain in specified epoch"
  say " ) List       -  a compact list view of available local pools"
  say " ) Show       -  detailed view of specified pool"
  say " ) Delegators -  list all delegators for pool"
  say " ) Rotate     -  rotate pool KES keys"
  say " ) Decrypt    -  remove write protection and decrypt pool"
  say " ) Encrypt    -  encrypt pool cold keys and make all files immutable"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  say " Select Pool operation\n"
  case $(select_opt "[n] New" "[r] Register" "[m] Modify" "[x] Retire" "[l] List" "[s] Show" "[g] Delegators" "[o] Rotate" "[d] Decrypt" "[e] Encrypt" "[h] Home") in
    0) SUBCOMMAND="new" ;;
    1) SUBCOMMAND="register" ;;
    2) SUBCOMMAND="modify" ;;
    3) SUBCOMMAND="retire" ;;
    4) SUBCOMMAND="list" ;;
    5) SUBCOMMAND="show" ;;
    6) SUBCOMMAND="delegators" ;;
    7) SUBCOMMAND="rotate" ;;
    8) SUBCOMMAND="decrypt" ;;
    9) SUBCOMMAND="encrypt" ;;
    10) continue ;;
  esac

  case $SUBCOMMAND in
    new)

    clear
    say " >> POOL >> NEW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""
    read -r -p "Pool Name: " pool_name
    # Remove unwanted characters from pool name
    pool_name=${pool_name//[^[:alnum:]]/_}
    if [[ -z "${pool_name}" ]]; then
      say "${RED}ERROR${NC}: Empty pool name, please retry!"
      waitForInput && continue
    fi
    say ""
    mkdir -p "${POOL_FOLDER}/${pool_name}"

    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"

    if [[ -f "${pool_hotkey_vk_file}" ]]; then
      say "${RED}WARN${NC}: A pool ${GREEN}$pool_name${NC} already exists"
      say "      Choose another name or delete the existing one"
      waitForInput && continue
    fi

    ${CCLI} shelley node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
    if [ -f "${POOL_FOLDER}-pregen/${pool_name}/${POOL_ID_FILENAME}" ]; then
      mv ${POOL_FOLDER}'-pregen/'${pool_name}/* ${POOL_FOLDER}/${pool_name}/
      rm -r ${POOL_FOLDER}'-pregen/'${pool_name}
    else
      ${CCLI} shelley node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}"
    fi
    ${CCLI} shelley node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"
    getPoolID ${pool_name}

    say "Pool: ${GREEN}${pool_name}${NC}" "log"
    [[ -n ${pool_id} ]] && say "ID (hex)    : ${pool_id}" "log"
    [[ -n ${pool_id_bech32} ]] && say "ID (bech32) : ${pool_id_bech32}" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    register)

    clear
    say " >> POOL >> REGISTER" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    pool_dirs=()
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      pool_regcert_file="${POOL_FOLDER}/${dir}/${POOL_REGCERT_FILENAME}"
      [[ -f "${pool_regcert_file}" || ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available that can be registered!"
      say "first create a pool or decrypt existing if encrypted"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"

    say "# Pool Parameters\n"
    say "press enter to use default value\n"

    pledge_ada=50000 # default pledge
    [[ -f "${pool_config}" ]] && pledge_ada=$(jq -r '.pledgeADA //0' "${pool_config}")
    read -r -p "Pledge (in ADA, default: ${pledge_ada}): " pledge_enter
    if [[ -n "${pledge_enter}" ]]; then
      if ! ADAtoLovelace "${pledge_enter}" >/dev/null; then
        waitForInput && continue
      fi
      pledge_lovelace=$(ADAtoLovelace "${pledge_enter}")
      pledge_ada="${pledge_enter}"
    else
      pledge_lovelace=$(ADAtoLovelace "${pledge_ada}")
    fi

    margin=7.5 # default margin in %
    [[ -f "${pool_config}" ]] && margin=$(jq -r '.margin //0' "${pool_config}")
    read -r -p "Margin (in %, default: ${margin}): " margin_enter
    if [[ -n "${margin_enter}" ]]; then
      if ! pctToFraction "${margin_enter}" >/dev/null; then
        waitForInput && continue
      fi
      margin_fraction=$(pctToFraction "${margin_enter}")
      margin="${margin_enter}"
    else
      margin_fraction=$(pctToFraction "${margin}")
    fi

    minPoolCost=$(( $(jq -r '.minPoolCost //0' "${TMP_FOLDER}"/protparams.json) / 1000000 )) # convert to ADA
    [[ ${minPoolCost} -gt 0 ]] && cost_ada=${minPoolCost} || cost_ada=400 # default cost
    if [[ -f "${pool_config}" ]]; then
      cost_ada_saved=$(jq -r '.costADA //0' "${pool_config}")
      [[ ${cost_ada_saved} -gt ${minPoolCost} ]] && cost_ada=${cost_ada_saved}
    fi
    read -r -p "Cost (in ADA, minimum: ${minPoolCost}, default: ${cost_ada}): " cost_enter
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    if [[ ${cost_ada} -lt ${minPoolCost} ]]; then
      say "\n${RED}ERROR${NC}: cost set lower than allowed"
      waitForInput && continue
    fi

    say "\n# Pool Metadata\n"
    meta_name="${pool_name}" # default name
    meta_ticker="${pool_name}" # default ticker
    meta_description="No Description" #default Description
    meta_homepage="https://foo.com" #default homepage
    meta_extended="https://foo.com/metadata/extended.json" #default extended
    meta_json_url="https://foo.bat/poolmeta.json" #default JSON
    pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
    if [[ -f "${pool_config}" ]]; then
      [[ "$(jq -r .json_url ${pool_config})" ]] && meta_json_url=$(jq -r .json_url "${pool_config}")
    fi

    read -r -p "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url}): " json_url_enter
    [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
    if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
      say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi

    metadata_done=false
    if wget -q -T 10 $meta_json_url -O "$TMP_FOLDER/url_poolmeta.json"; then
      say "\nMetadata exists at URL.  Use existing data?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) mv "$TMP_FOLDER/url_poolmeta.json" "${POOL_FOLDER}/${pool_name}/poolmeta.json"
           metadata_done=true
           ;;
        1) rm "$TMP_FOLDER/url_poolmeta.json" ;; # clean up temp file
      esac
    fi
    if [ ${metadata_done} = false ]; then
      # ToDo align with wallet and smash
      if [[ -f "${pool_meta_file}" ]]; then
        meta_name=$(jq -r .name "${pool_meta_file}")
        meta_ticker=$(jq -r .ticker "${pool_meta_file}")
        meta_homepage=$(jq -r .homepage "${pool_meta_file}")
        meta_description=$(jq -r .description "${pool_meta_file}")
        meta_extended=$(jq -r .extended "${pool_meta_file}")
      fi

      read -r -p "Enter Pool's Name (default: ${meta_name}): " name_enter
      [[ -n "${name_enter}" ]] && meta_name="${name_enter}"
      if [[ ${#meta_name} -gt 50 ]]; then
        say "${RED}ERROR${NC}: Name cannot exceed 50 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker}): " ticker_enter
      ticker_enter=${ticker_enter//[^[:alnum:]]/_}
      [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter}"
      if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
        say "${RED}ERROR${NC}: ticker must be between 3-5 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Description (default: ${meta_description}): " desc_enter
      [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
      if [[ ${#meta_description} -gt 255 ]]; then
        say "${RED}ERROR${NC}: Description cannot exceed 255 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Homepage (default: ${meta_homepage}): " homepage_enter
      [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
      if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
        say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
        waitForInput && continue
      fi
      say "\nOptionally set an extended metadata URL?\n"
      case $(select_opt "[n] No" "[y] Yes") in
        0) meta_extended_option=""
           ;;
        1) read -r -p "Enter URL to extended metadata (default: ${meta_extended}): " extended_enter
          extended_enter="${extended_enter}"
          [[ -n "${extended_enter}" ]] && meta_extended="${extended_enter}"
          if [[ ! "${meta_extended}" =~ https?://.* || ${#meta_extended} -gt 64 ]]; then
            say "${RED}ERROR${NC}: invalid extended URL format or more than 64 chars in length"
            waitForInput && continue
          else
            meta_extended_option=",\"extended\":\"${meta_extended}\"" 
          fi
      esac

      new_pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta-$(date '+%Y%m%d%H%M%S').json"
      echo -e "{\"name\":\"${meta_name}\",\"ticker\":\"${meta_ticker}\",\"description\":\"${meta_description}\",\"homepage\":\"${meta_homepage}\",\"nonce\":\"$(date +%s)\"${meta_extended_option}}" > "${new_pool_meta_file}"
      jq . "${new_pool_meta_file}"
      metadata_size=$(stat -c%s "${new_pool_meta_file}")
      if [[ ${metadata_size} -gt 512 ]]; then
        say "${RED}ERROR${NC}: Total metadata size cannot exceed 512 chars in length, current length: ${metadata_size}"
        waitForInput && continue
      else
        cp -f "${new_pool_meta_file}" "${pool_meta_file}"
      fi

      say "\n${ORANGE}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
      waitForInput "Press any key to proceed with registration after metadata file is uploaded"
    fi

    relay_output=""
    relay_array=()
    say "\n# Pool Relay Registration\n"
    # ToDo SRV & IPv6 support
    if [[ -f "${pool_config}" && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
      say "Previous relay configuration:\n"
      printTable ',' "$(say 'Type,Address,Port' | cat - <(jq -r -c '.relays[] | [.type //"-",.address //"-",.port //"-"] | @csv //empty' "${pool_config}") | tr -d '"')"
      say "\nReuse previous configuration?\n"
      case $(select_opt "[y] Yes" "[n] No" "[Esc] Cancel") in
        0) while read -r type address port; do
             relay_array+=( "type" "${type}" "address" "${address}" "port" "${port}" )
             if [[ ${type} = "DNS_A" ]]; then
               relay_output+="--single-host-pool-relay ${address} --pool-relay-port ${port} "
             elif [[ ${type} = "IPv4" ]]; then
               relay_output+="--pool-relay-port ${port} --pool-relay-ipv4 ${address} "
             fi
           done< <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
           ;;
        1) : ;; # Do nothing
        2) continue ;;
      esac
    fi
    if [[ -z ${relay_output} ]]; then
      while true; do
        case $(select_opt "[d] A or AAAA DNS record (single)" "[4] IPv4 address (multiple)" "[Esc] Cancel") in
          0) read -r -p "Enter relays's DNS record, only A or AAAA DNS records: " relay_dns_enter
             if [[ -z "${relay_dns_enter}" ]]; then
               say "\n${RED}ERROR${NC}: DNS record can not be empty!\n"
               continue
             fi
             #ToDo - DNS format verficication?
             read -r -p "Enter relays's port: " relay_port_enter
             if [[ -n "${relay_port_enter}" ]]; then
               if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                 say "\n${RED}ERROR${NC}: invalid port number!\n"
                 continue
               fi
             else
               say "\n${RED}ERROR${NC}: Port can not be empty!\n"
               continue
             fi
             relay_array+=( "type" "DNS_A" "address" "${relay_dns_enter}" "port" "${relay_port_enter}" )
             relay_output+="--single-host-pool-relay ${relay_dns_enter} --pool-relay-port ${relay_port_enter} "
             ;;
          1) read -r -p "Enter relays's IPv4 address: " relay_ipv4_enter
             if [[ -n "${relay_ipv4_enter}" ]]; then
               if ! validIP "${relay_ipv4_enter}"; then
                 say "\n${RED}ERROR${NC}: invalid IPv4 address format!\n"
                 continue
               fi
             else
               say "\n${RED}ERROR${NC}: IPv4 address can not be empty!\n"
               continue
             fi
             read -r -p "Enter relays's port: " relay_port_enter
             if [[ -n "${relay_port_enter}" ]]; then
               if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                 say "\n${RED}ERROR${NC}: invalid port number!\n"
                 continue
               fi
             else
               say "\n${RED}ERROR${NC}: Port can not be empty!\n"
               continue
             fi
             relay_array+=( "type" "IPv4" "address" "${relay_ipv4_enter}" "port" "${relay_port_enter}" )
             relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv4 ${relay_ipv4_enter} "
             ;;
          2) continue 2 ;;
        esac
        say "\nAdd more relay entries?\n"
        case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
          0) break ;;
          1) continue ;;
          2) continue 2 ;;
        esac
      done
    fi

    say ""

    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]] && say "Balance checking wallets...\n"
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      if ! getBaseAddress ${dir} && [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]]; then continue; fi
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance ${base_addr}
        [[ ${lovelace} -eq 0 ]] && continue
        if getRewardAddress ${dir}; then
          delegation_pool_id=$(${CCLI} shelley query stake-address-info ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --address "${reward_addr}" | jq -r '.[0].delegation // empty')
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
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
          elif [[ -n ${delegation_pool_id} ]]; then
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA - ${RED}delegated${NC} to external address)")
          else
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA)")
          fi
        else
          wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be used in pool registration as pledge wallet!"
      say "Encrypted wallets not checked, please decrypt wallet first if encrypted"
      waitForInput && continue
    fi
    say "Select Owner Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    owner_wallet="$(echo ${dir_name} | cut -d' ' -f1)"
    getBaseAddress ${owner_wallet}
    getBalance ${base_addr}

    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in owner wallet:"  "$(formatLovelace ${lovelace})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available in base address for wallet ${GREEN}${owner_wallet}${NC}"
      waitForInput && continue
    fi
    if ! isWalletRegistered ${owner_wallet} && ! registerStakeWallet ${owner_wallet}; then
      waitForInput && continue
    fi

    say "\nUse a different wallet for rewards?\n"
    case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
      0) reward_wallet="${owner_wallet}" ;;
      1) if ! selectDir "${wallet_dirs[@]}"; then continue; fi
         reward_wallet="$(echo ${dir_name} | cut -d' ' -f1)"
         if ! isWalletRegistered ${reward_wallet}; then
           getBaseAddress ${reward_wallet}
           getBalance ${base_addr}
           if [[ ${lovelace} -gt 0 ]]; then
             say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in reward wallet:"  "$(formatLovelace ${lovelace})")" "log"
           else
             say "${RED}ERROR${NC}: no funds available in base address for wallet ${GREEN}${reward_wallet}${NC}, needed to pay for registration fee"
             waitForInput && continue
           fi
           if ! registerStakeWallet ${reward_wallet}; then
             waitForInput && continue
           fi
         fi
         ;;
      2) continue ;;
    esac

    multi_owner_output=""
    multi_owner_skeys=()
    say "\nRegister a multi-owner pool using stake vkey/skey files?\n"
    case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
      0) : ;;
      1) while true; do
           read -r -p "Enter full path to stake vkey file: " stake_vk_file_enter
           read -r -p "Enter full path to stake skey file: " stake_sk_file_enter
           if [[ ! -f "${stake_vk_file_enter}" || ! -f "${stake_sk_file_enter}" ]]; then
             say "${RED}ERROR${NC}: One or both files missing, please try again"
             waitForInput
           else
             multi_owner_output+="--pool-owner-stake-verification-key-file ${stake_vk_file_enter} "
             multi_owner_skeys+=( "${stake_sk_file_enter}" )
           fi
           say "\nAdd more owners?\n"
           case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
             0) break ;;
             1) : ;;
             2) continue 2 ;;
           esac
         done
         ;;
      2) continue ;;
    esac

    # Construct relay json array
    relay_json=$({
      say '['
      printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
      say ']'
    } | jq -c .)
    # Save pool config
    echo "{\"pledgeWallet\":\"$owner_wallet\",\"rewardWallet\":\"$reward_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada,\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"

    pay_payment_sk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_PAY_SK_FILENAME}"
    owner_stake_sk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_STAKE_SK_FILENAME}"
    owner_stake_vk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_STAKE_VK_FILENAME}"
    owner_delegation_cert_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_DELEGCERT_FILENAME}"
    reward_stake_sk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_SK_FILENAME}"
    reward_stake_vk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_VK_FILENAME}"
    reward_delegation_cert_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_DELEGCERT_FILENAME}"

    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
    pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
    pool_saved_kes_start="${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}"
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"

    say ""
    say "# Register Stake Pool" "log"

    start_kes_period=$(getCurrentKESperiod)
    echo "${start_kes_period}" > ${pool_saved_kes_start}
    say "creating operational certificate" 1 "log"
    ${CCLI} shelley node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${start_kes_period}" --out-file "${pool_opcert_file}"

    say "creating registration certificate" 1 "log"
    say "$ ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --out-file ${pool_regcert_file} ${NETWORK_IDENTIFIER} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} shelley stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output}" 2
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --out-file "${pool_regcert_file}" ${NETWORK_IDENTIFIER} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} shelley stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output}
    say "creating delegation certificate for owner wallet" 1 "log"
    say "$ ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file ${owner_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${owner_delegation_cert_file}" 2
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${owner_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${owner_delegation_cert_file}"
    delegate_reward_wallet="false"
    if [[ ! "${owner_wallet}" = "${reward_wallet}" ]]; then
      say "\nRe-stake reward wallet to pool?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) delegate_reward_wallet="true"
           say "creating delegation certificate for reward wallet" 1 "log"
           say "$ ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file ${reward_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${reward_delegation_cert_file}" 2
           ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${reward_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${reward_delegation_cert_file}" 
           ;;
        1) : ;;
      esac
    fi

    say "sending transaction to chain" 1 "log"
    if ! registerPool "${pool_name}" "${reward_wallet}" "${delegate_reward_wallet}" "${owner_wallet}" "${multi_owner_skeys[@]}"; then
      say "${RED}ERROR${NC}: failure during pool registration, removing newly created pledge and registration files"
      rm -f "${pool_regcert_file}" "${owner_delegation_cert_file}"
      [[ "${delegate_reward_wallet}" = "true" ]] && rm -f "${reward_delegation_cert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBaseAddress ${owner_wallet}
    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    say ""
    say "Pool ${GREEN}${pool_name}${NC} successfully registered using wallet ${GREEN}${owner_wallet}${NC} for pledge" "log"
    say "Owner  : ${GREEN}${owner_wallet}${NC}" "log"
    [[ ${multi_owner_count} -gt 0 ]] && say "         ${BLUE}${multi_owner_count}${NC} extra owner(s) using stake keys" "log"
    say "Reward : ${GREEN}${reward_wallet}${NC}" "log"
    say "Pledge : $(formatLovelace ${pledge_lovelace}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(formatLovelace ${cost_lovelace}) ADA" "log"
    say ""
    say "Append cardano node start command with the following run arguments:" "log"
    say "--shelley-kes-key ${pool_hotkey_sk_file} \\" "log"
    say "--shelley-vrf-key ${pool_vrf_sk_file} \\" "log"
    say "--shelley-operational-certificate ${pool_opcert_file}" "log"
    if [[ ${lovelace} -lt ${pledge_lovelace} ]]; then
      say ""
      say "${ORANGE}WARN${NC}: Balance in pledge wallet is less than set pool pledge"
      say "      make sure to put enough funds in wallet to honor pledge"
    fi
    if [[ ${multi_owner_count} -gt 0 ]]; then
      say ""
      say "${BLUE}INFO${NC}: All multi-owner wallets added by keys need to be manually delegated to pool!"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    modify)

    clear
    say " >> POOL >> MODIFY" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    pool_dirs=()
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      pool_regcert_file="${POOL_FOLDER}/${dir}/${POOL_REGCERT_FILENAME}"
      [[ ! -f "${pool_regcert_file}" || ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available that can be modified!"
      say "first register a pool or decrypt existing if encrypted"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"

    if [[ ! -f ${pool_config} ]]; then
      say "${ORANGE}WARN${NC}: Missing pool config file, please first register your pool"
      say "${pool_config}"
      waitForInput && continue
    fi

    say "# Pool Parameters\n"
    say "press enter to use old value\n"

    pledge_ada=$(jq -r '.pledgeADA //0' "${pool_config}")
    read -r -p "New Pledge (in ADA, old: ${pledge_ada}): " pledge_enter
    if [[ -n "${pledge_enter}" ]]; then
      if ! ADAtoLovelace "${pledge_enter}" >/dev/null; then
        waitForInput && continue
      fi
      pledge_lovelace=$(ADAtoLovelace "${pledge_enter}")
      pledge_ada="${pledge_enter}"
    else
      pledge_lovelace=$(ADAtoLovelace "${pledge_ada}")
    fi

    margin=$(jq -r '.margin //0' "${pool_config}")
    read -r -p "New Margin (in %, old: ${margin}): " margin_enter
    if [[ -n "${margin_enter}" ]]; then
      if ! pctToFraction "${margin_enter}" >/dev/null; then
        waitForInput && continue
      fi
      margin_fraction=$(pctToFraction "${margin_enter}")
      margin="${margin_enter}"
    else
      margin_fraction=$(pctToFraction "${margin}")
    fi

    minPoolCost=$(( $(jq -r '.minPoolCost //0' "${TMP_FOLDER}"/protparams.json) / 1000000 )) # convert to ADA
    cost_ada=$(jq -r '.costADA //0' "${pool_config}")
    read -r -p "New Cost (in ADA, minimum: ${minPoolCost}, old: ${cost_ada}): " cost_enter
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    if [[ ${cost_ada} -lt ${minPoolCost} ]]; then
      say "\n${RED}ERROR${NC}: cost set lower than allowed"
      waitForInput && continue
    fi

    say "\n# Pool Metadata\n"

    pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
    if [[ -f "${pool_config}" ]]; then
      [[ "$(jq -r .json_url ${pool_config})" ]] && meta_json_url=$(jq -r .json_url "${pool_config}")
    fi

    read -r -p "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url}): " json_url_enter
    json_url_enter="${json_url_enter}"
    [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
    if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
      say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi

    metadata_done=false
    if wget -q -T 10 $meta_json_url -O "$TMP_FOLDER/url_poolmeta.json"; then
      say "\nMetadata exists at URL.  Use existing data?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) mv "$TMP_FOLDER/url_poolmeta.json" "${POOL_FOLDER}/${pool_name}/poolmeta.json"
           metadata_done=true
           ;;
        1) rm "$TMP_FOLDER/url_poolmeta.json" ;; # clean up temp file
      esac
    fi

    if [ ${metadata_done} = false ]; then
      # ToDo align with wallet and smash
      if [[ -f "${pool_meta_file}" ]]; then
        meta_name=$(jq -r .name "${pool_meta_file}")
        meta_ticker=$(jq -r .ticker "${pool_meta_file}")
        meta_homepage=$(jq -r .homepage "${pool_meta_file}")
        meta_description=$(jq -r .description "${pool_meta_file}")
        meta_extended=$(jq -r .extended "${pool_meta_file}")
      fi

      read -r -p "Enter Pool's Name (default: ${meta_name}): " name_enter
      [[ -n "${name_enter}" ]] && meta_name="${name_enter}"
      if [[ ${#meta_name} -gt 50 ]]; then
        say "${RED}ERROR${NC}: Name cannot exceed 50 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker}): " ticker_enter
      ticker_enter=${ticker_enter//[^[:alnum:]]/_}
      [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter}"
      if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
        say "${RED}ERROR${NC}: ticker must be between 3-5 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Description (default: ${meta_description}): " desc_enter
      [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
      if [[ ${#meta_description} -gt 255 ]]; then
        say "${RED}ERROR${NC}: Description cannot exceed 255 characters"
        waitForInput && continue
      fi
      read -r -p "Enter Pool's Homepage (default: ${meta_homepage}): " homepage_enter
      [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
      if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
        say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
        waitForInput && continue
      fi
      say "\nOptionally set an extended metadata URL?\n"
      case $(select_opt "[n] No" "[y] Yes") in
        0) meta_extended_option=""
           ;;
        1) read -r -p "Enter URL to extended metadata (default: ${meta_extended}): " extended_enter
          extended_enter="${extended_enter}"
          if [[ -n "${extended_enter}" ]]; then
            meta_extended="${extended_enter}"
          fi
          if [[ ! "${meta_extended}" =~ https?://.* || ${#meta_extended} -gt 64 ]]; then
            say "${RED}ERROR${NC}: invalid extended URL format or more than 64 chars in length"
            waitForInput && continue
          else
            meta_extended_option=",\"extended\":\"${meta_extended}\"" 
          fi
      esac

      new_pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta-$(date '+%Y%m%d%H%M%S').json"
      echo -e "{\"name\":\"${meta_name}\",\"ticker\":\"${meta_ticker}\",\"description\":\"${meta_description}\",\"homepage\":\"${meta_homepage}\",\"nonce\":\"$(date +%s)\"${meta_extended_option}}" > "${new_pool_meta_file}"
      jq . "${new_pool_meta_file}"
      metadata_size=$(stat -c%s "${new_pool_meta_file}")
      if [[ ${metadata_size} -gt 512 ]]; then
        say "${RED}ERROR${NC}: Total metadata size cannot exceed 512 chars in length, current length: ${metadata_size}"
        waitForInput && continue
      else
        cp -f "${new_pool_meta_file}" "${pool_meta_file}"
      fi

      say "\n${ORANGE}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
      waitForInput "Press any key to proceed with re-registration after metadata file is uploaded"
    fi

    relay_output=""
    relay_array=()
    say "\n# Pool Relay Registration\n"
    # ToDo SRV & IPv6 support
    if [[ -f "${pool_config}" && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
      say "Previous relay configuration:\n"
      printTable ',' "$(say 'Type,Address,Port' | cat - <(jq -r -c '.relays[] | [.type //"-",.address //"-",.port //"-"] | @csv //empty' "${pool_config}") | tr -d '"')"
      say "\nReuse previous configuration?\n"
      case $(select_opt "[y] Yes" "[n] No" "[Esc] Cancel") in
        0) while read -r type address port; do
             relay_array+=( "type" "${type}" "address" "${address}" "port" "${port}" )
             if [[ ${type} = "DNS_A" ]]; then
               relay_output+="--single-host-pool-relay ${address} --pool-relay-port ${port} "
             elif [[ ${type} = "IPv4" ]]; then
               relay_output+="--pool-relay-port ${port} --pool-relay-ipv4 ${address} "
             fi
           done < <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
           ;;
        1) : ;; # Do nothing
        2) continue ;;
      esac
    fi
    if [[ -z ${relay_output} ]]; then
      while true; do
        case $(select_opt "[d] A or AAAA DNS record (single)" "[4] IPv4 address (multiple)" "[Esc] Cancel") in
          0) read -r -p "Enter relays's DNS record, only A or AAAA DNS records: " relay_dns_enter
             if [[ -z "${relay_dns_enter}" ]]; then
               say "\n${RED}ERROR${NC}: DNS record can not be empty!\n"
               continue
             fi
             #ToDo - DNS format verficication?
             read -r -p "Enter relays's port: " relay_port_enter
             if [[ -n "${relay_port_enter}" ]]; then
               if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                 say "\n${RED}ERROR${NC}: invalid port number!\n"
                 continue
               fi
             else
               say "\n${RED}ERROR${NC}: Port can not be empty!\n"
               continue
             fi
             relay_array+=( "type" "DNS_A" "address" "${relay_dns_enter}" "port" "${relay_port_enter}" )
             relay_output+="--single-host-pool-relay ${relay_dns_enter} --pool-relay-port ${relay_port_enter} "
             ;;
          1) read -r -p "Enter relays's IPv4 address: " relay_ipv4_enter
             if [[ -n "${relay_ipv4_enter}" ]]; then
               if ! validIP "${relay_ipv4_enter}"; then
                 say "\n${RED}ERROR${NC}: invalid IPv4 address format!\n"
                 continue
               fi
             else
               say "\n${RED}ERROR${NC}: IPv4 address can not be empty!\n"
               continue
             fi
             read -r -p "Enter relays's port: " relay_port_enter
             if [[ -n "${relay_port_enter}" ]]; then
               if [[ ! "${relay_port_enter}" =~ ^[0-9]+$ || "${relay_port_enter}" -lt 1 || "${relay_port_enter}" -gt 65535 ]]; then
                 say "\n${RED}ERROR${NC}: invalid port number!\n"
                 continue
               fi
             else
               say "\n${RED}ERROR${NC}: Port can not be empty!\n"
               continue
             fi
             relay_array+=( "type" "IPv4" "address" "${relay_ipv4_enter}" "port" "${relay_port_enter}" )
             relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv4 ${relay_ipv4_enter} "
             ;;
          2) continue 2 ;;
        esac
        say "\nAdd more relay entries?\n"
        case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
          0) break ;;
          1) continue ;;
          2) continue 2 ;;
        esac
      done
    fi

    # Owner wallet, also used to pay for pool update fee
    owner_wallet=$(jq -r .pledgeWallet "${pool_config}")
    reward_wallet=$(jq -r .rewardWallet "${pool_config}")
    say "Old owner wallet:  ${GREEN}${owner_wallet}${NC}"
    say "Old reward wallet: ${GREEN}${reward_wallet}${NC}"
    say ""
    say "${ORANGE}If a new wallet is chosen for owner/reward, a manual delegation to the pool with new wallet is needed${NC}"
    say ""
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]] && say "Balance checking wallets...\n"
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      if ! getBaseAddress ${dir} && [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]]; then continue; fi
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance ${base_addr}
        [[ ${lovelace} -eq 0 ]] && continue
        if getRewardAddress ${dir}; then
          delegation_pool_id=$(${CCLI} shelley query stake-address-info ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --address "${reward_addr}" | jq -r '.[0].delegation // empty')
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
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
          elif [[ -n ${delegation_pool_id} ]]; then
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA - ${RED}delegated${NC} to external address)")
          else
            wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA)")
          fi
        else
          wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be used in pool registration as owner wallet!"
      say "Encrypted wallets not checked, please decrypt wallet first if encrypted"
      waitForInput && continue
    fi
    say "Select Owner Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    owner_wallet="$(echo ${dir_name} | cut -d' ' -f1)"
    getBaseAddress ${owner_wallet}
    getBalance ${base_addr}

    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in base address for owner wallet:"  "$(formatLovelace ${lovelace})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${owner_wallet}${NC}"
      waitForInput && continue
    fi
    if ! isWalletRegistered ${owner_wallet} && ! registerStakeWallet ${owner_wallet}; then
      waitForInput && continue
    fi

    say "\nUse a different wallet for rewards?\n"
    case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
      0) reward_wallet="${owner_wallet}" ;;
      1) if ! selectDir "${wallet_dirs[@]}"; then continue; fi
         reward_wallet="$(echo ${dir_name} | cut -d' ' -f1)"
         if ! isWalletRegistered ${reward_wallet}; then
           getBaseAddress ${reward_wallet}
           getBalance ${base_addr}
           if [[ ${lovelace} -gt 0 ]]; then
             say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in reward wallet:"  "$(formatLovelace ${lovelace})")" "log"
           else
             say "${RED}ERROR${NC}: no funds available in base address for wallet ${GREEN}${reward_wallet}${NC}, needed to pay for registration fee"
             waitForInput && continue
           fi
           if ! registerStakeWallet ${reward_wallet}; then
             waitForInput && continue
           fi
         fi
         ;;
      2) continue ;;
    esac

    multi_owner_output=""
    multi_owner_skeys=()
    say "\nRegister a multi-owner pool using stake vkey/skey files?\n"
    case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
      0) : ;;
      1) while true; do
           read -r -p "Enter full path to stake vkey file: " stake_vk_file_enter
           read -r -p "Enter full path to stake skey file: " stake_sk_file_enter
           if [[ ! -f "${stake_vk_file_enter}" || ! -f "${stake_sk_file_enter}" ]]; then
             say "${RED}ERROR${NC}: One or both files missing, please try again"
             waitForInput
           else
             multi_owner_output+="--pool-owner-stake-verification-key-file ${stake_vk_file_enter} "
             multi_owner_skeys+=( "${stake_sk_file_enter}" )
           fi
           say "\nAdd more owners?\n"
           case $(select_opt "[n] No" "[y] Yes" "[Esc] Cancel") in
             0) break ;;
             1) : ;;
             2) continue 2 ;;
           esac
         done
         ;;
      2) continue ;;
    esac

    # Construct relay json array
    relay_json=$({
      say '['
      printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
      say ']'
    } | jq -c .)
    # Update pool config
    say "{\"pledgeWallet\":\"$owner_wallet\",\"rewardWallet\":\"$reward_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada,\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"

    pay_payment_sk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_PAY_SK_FILENAME}"
    owner_stake_sk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_STAKE_SK_FILENAME}"
    owner_stake_vk_file="${WALLET_FOLDER}/${owner_wallet}/${WALLET_STAKE_VK_FILENAME}"
    reward_stake_sk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_SK_FILENAME}"
    reward_stake_vk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_VK_FILENAME}"

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"

    #Generated Files
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
    # Make a backup of current reg cert
    cp -f "${pool_regcert_file}" "${pool_regcert_file}.tmp"

    say ""
    say "# Modify Stake Pool" "log"
    say "creating registration certificate" 1 "log"
    say "$ ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} shelley stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output} ${NETWORK_IDENTIFIER} --out-file ${pool_regcert_file}" 2
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} shelley stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output} ${NETWORK_IDENTIFIER} --out-file "${pool_regcert_file}"

    say "sending transaction to chain" 1 "log"
    if ! modifyPool "${pool_name}" "${reward_wallet}" "${owner_wallet}" "${multi_owner_skeys[@]}"; then
      say "${RED}ERROR${NC}: failure during pool update, removing newly created registration certificate"
      mv -f "${pool_regcert_file}.tmp" "${pool_regcert_file}" # restore reg cert backup
      waitForInput && continue
    else
      rm -f "${pool_regcert_file}.tmp" # remove backup of old reg cert
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBaseAddress ${owner_wallet}
    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    say ""
    say "Pool ${GREEN}${pool_name}${NC} successfully updated with new parameters using wallet ${GREEN}${owner_wallet}${NC} to pay for registration fee" "log"
    say "Owner  : ${GREEN}${owner_wallet}${NC}" "log"
    [[ ${multi_owner_count} -gt 0 ]] && say "         ${BLUE}${multi_owner_count}${NC} extra owner(s) using stake keys" "log"
    say "Reward : ${GREEN}${reward_wallet}${NC}" "log"
    say "Pledge : $(formatLovelace ${pledge_lovelace}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(formatLovelace ${cost_lovelace}) ADA" "log"
    if [[ ${lovelace} -lt ${pledge_lovelace} ]]; then
      say ""
      say "${ORANGE}WARN${NC}: Balance in pledge wallet is less than set pool pledge"
      say "      make sure to put enough funds in wallet to honor pledge"
    fi
    if [[ ${multi_owner_count} -gt 0 ]]; then
      say ""
      say "${BLUE}INFO${NC}: All multi-owner wallets added by keys need to be manually delegated to pool if not done already!"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    retire)

    clear
    say " >> POOL >> RETIRE" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    pool_dirs=()
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      pool_regcert_file="${POOL_FOLDER}/${dir}/${POOL_REGCERT_FILENAME}"
      [[ ! -f "${pool_regcert_file}" || ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available that can be retired!"
      say "first register a pool or decrypt existing if encrypted"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    epoch=$(getEpoch)
    eMax=$(jq -r '.eMax' "${TMP_FOLDER}"/protparams.json)

    say "Current epoch: ${BLUE}${epoch}${NC}" "log"
    epoch_start=$((epoch + 1))
    epoch_end=$((epoch + eMax))
    say "earlist epoch to retire pool is ${BLUE}${epoch_start}${NC} and latest ${BLUE}${epoch_end}${NC}" "log"
    say ""

    read -r -p "Enter epoch in which to retire pool (blank for ${epoch_start}): " epoch_enter
    [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch_start}

    if [[ ${epoch_enter} -lt ${epoch_start} || ${epoch_enter} -gt ${epoch_end} ]]; then
      say "${RED}ERROR${NC}: epoch invalid, valid range: ${epoch_start}-${epoch_end}"
      waitForInput && continue
    fi

    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]] && say "Balance checking wallets...\n"
    for dir in "${dirs[@]}"; do
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        if getBaseAddress ${dir}; then
          getBalance ${base_addr}
          [[ ${lovelace} -eq 0 ]] && continue
          wallet_dirs+=("${dir} (${CYAN}$(formatLovelace ${lovelace})${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that have funds to pay for pool retirement transaction fee!"
      say "Encrypted wallets not checked, please decrypt wallet first if encrypted"
      waitForInput && continue
    fi
    say "Select wallet for pool de-registration transaction fee:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"
    getBaseAddress ${wallet_name}
    getBalance ${base_addr}

    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in wallet:"  "$(formatLovelace ${lovelace})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${wallet_name}${NC}"
      say "funds needed to pay for tx fee sending deregistration certificate to chain"
      waitForInput && continue
    fi
    say ""

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"

    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

    say "creating de-registration cert" 1 "log"
    say "$ ${CCLI} shelley stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}" 2
    ${CCLI} shelley stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}

    if ! deRegisterPool "${pool_coldkey_sk_file}" "${pool_deregcert_file}" "${base_addr}" "${payment_sk_file}"; then
      say "\n${RED}ERROR${NC}: failure during pool de-registration"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done

    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    say ""
    say "Pool ${GREEN}${pool_name}${NC} set to be retired in epoch ${BLUE}${epoch_enter}${NC}" "log"

    waitForInput

    ;; ###################################################################

    list)

    clear
    say " >> POOL >> LIST" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    while IFS= read -r -d '' pool; do
      say ""
      getPoolID "$(basename ${pool})"
      pool_regcert_file="${pool}/${POOL_REGCERT_FILENAME}"
      [[ -f "${pool_regcert_file}" ]] && pool_registered="YES" || pool_registered="NO"
      say "${GREEN}$(basename ${pool})${NC} "
      say "$(printf "%-21s : %s" "ID (hex)" "${pool_id}")" "log"
      [[ -n ${pool_id_bech32} ]] && say "$(printf "%-21s : %s" "ID (bech32)" "${pool_id_bech32}")" "log"
      say "$(printf "%-21s : %s" "Registered" "${pool_registered}")" "log"
      if [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${pool}/${POOL_CURRENT_KES_START}")"
        if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
          if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
            say "$(printf "%-21s : %s - ${RED}%s${NC} %s ago" "KES expiration date" "${expiration_date}" "EXPIRED!" "$(showTimeLeft ${expiration_time_sec_diff:1})")" "log"
          else
            say "$(printf "%-21s : %s - ${RED}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "ALERT!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
          fi
        elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
          say "$(printf "%-21s : %s - ${ORANGE}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "WARNING!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
        else
          say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
        fi
      fi
    done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

    show)

    clear
    say " >> POOL >> SHOW" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    pool_dirs=()
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_id_file="${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}"
      [[ ! -f "${pool_id_file}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available!"
      say "first create a pool"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    say "Dumping ledger-state from node, can take a while on larger networks...\n"
    if ! timeout -k 5 $TIMEOUT_LEDGER_STATE ${CCLI} shelley query ledger-state ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --out-file "${TMP_FOLDER}"/ledger-state.json; then
      say "${RED}ERROR${NC}: ledger dump failed/timed out"
      say "increase timeout value in cntools.config"
      waitForInput && continue
    fi

    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""
    getPoolID ${pool_name}
    ledger_pParams=$(jq -r '.esLState._delegationState._pstate._pParams."'"${pool_id}"'" // empty' "${TMP_FOLDER}"/ledger-state.json)
    ledger_fPParams=$(jq -r '.esLState._delegationState._pstate._fPParams."'"${pool_id}"'" // empty' "${TMP_FOLDER}"/ledger-state.json)
    [[ -z "${ledger_fPParams}" ]] && ledger_fPParams="${ledger_pParams}"
    [[ -n "${ledger_pParams}" ]] && pool_registered="YES" || pool_registered="NO"
    say "${GREEN}${pool_name}${NC} "
    say "$(printf "%-21s : %s" "ID (hex)" "${pool_id}")" "log"
    [[ -n ${pool_id_bech32} ]] && say "$(printf "%-21s : %s" "ID (bech32)" "${pool_id_bech32}")" "log"
    say "$(printf "%-21s : %s" "Registered" "${pool_registered}")" "log"
    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    if [[ -f "${pool_config}" ]]; then
      meta_json_url=$(jq -r .json_url "${pool_config}")
      if wget -q -T 10 ${meta_json_url} -O "$TMP_FOLDER/url_poolmeta.json"; then
        say "Metadata" "log"
        say "$(printf "  %-19s : %s" "Name" "$(jq -r .name "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "Ticker" "$(jq -r .ticker "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "Homepage" "$(jq -r .homepage "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "Description" "$(jq -r .description "$TMP_FOLDER/url_poolmeta.json")")" "log"
        say "$(printf "  %-19s : %s" "URL" "$(jq -r .json_url "${pool_config}")")" "log"
        meta_hash_url="$(${CCLI} shelley stake-pool metadata-hash --pool-metadata-file "$TMP_FOLDER/url_poolmeta.json" )"
        meta_hash_pParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_pParams}")
        meta_hash_fPParams=$(jq -r '.metadata.hash //empty' <<< "${ledger_fPParams}")
        say "$(printf "  %-19s : %s" "Hash URL" "${meta_hash_url}")" "log"
        if [[ "${meta_hash_pParams}" = "${meta_hash_fPParams}" ]]; then
          say "$(printf "  %-19s : %s" "Hash Ledger" "${meta_hash_pParams}")" "log"
        else
          say "$(printf "  %-13s (${ORANGE}%s${NC}) : %s" "Hash Ledger" "old" "${meta_hash_pParams}")" "log"
          say "$(printf "  %-13s (${ORANGE}%s${NC}) : %s" "Hash Ledger" "new" "${meta_hash_fPParams}")" "log"
        fi
      else
        say "$(printf "%-21s : %s" "Metadata" "download failed for ${meta_json_url}")" "log"
      fi
    fi
    if [[ "${pool_registered}" = "YES" ]]; then
      pParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_pParams}")
      fPParams_pledge=$(jq -r '.pledge //0' <<< "${ledger_fPParams}")
      if [[ ${pParams_pledge} -eq ${fPParams_pledge} ]]; then
        say "$(printf "%-21s : %s ADA" "Pledge" "$(formatLovelace "${pParams_pledge}")")" "log"
      else
        say "$(printf "%-15s (${ORANGE}%s${NC}) : %s ADA" "Pledge" "new" "$(formatLovelace "${fPParams_pledge}")" )" "log"
      fi
      pParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_pParams}")")
      fPParams_margin=$(LC_NUMERIC=C printf "%.4f" "$(jq -r '.margin //0' <<< "${ledger_fPParams}")")
      if [[ "${pParams_margin}" = "${fPParams_margin}" ]]; then
        say "$(printf "%-21s : %s %%" "Margin" "$(fractionToPCT "${pParams_margin}")")" "log"
      else
        say "$(printf "%-15s (${ORANGE}%s${NC}) : %s %%" "Margin" "new" "$(fractionToPCT "${fPParams_margin}")" )" "log"
      fi
      pParams_cost=$(jq -r '.cost //0' <<< "${ledger_pParams}")
      fPParams_cost=$(jq -r '.cost //0' <<< "${ledger_fPParams}")
      if [[ ${pParams_cost} -eq ${fPParams_cost} ]]; then
        say "$(printf "%-21s : %s ADA" "Cost" "$(formatLovelace "${pParams_cost}")")" "log"
      else
        say "$(printf "%-15s (${ORANGE}%s${NC}) : %s ADA" "Cost" "new" "$(formatLovelace "${fPParams_cost}")" )" "log"
      fi
      if [[ ! $(jq -c '.relays[] //empty' <<< "${ledger_pParams}") = $(jq -c '.relays[] //empty' <<< "${ledger_fPParams}") ]]; then
        say "$(printf "%-23s ${ORANGE}%s${NC}" "" "Relay(s) updated, showing latest registered")" "log"
      fi
      ledger_relays=$(jq -c '.relays[] //empty' <<< "${ledger_fPParams}")
      relay_title="Relay(s)"
      if [[ -n "${ledger_relays}" ]]; then
        while read -r relay; do
          relay_ipv4="$(jq -r '."single host address".IPv4 //empty' <<< ${relay})"
          relay_dns="$(jq -r '."single host name".dnsName //empty' <<< ${relay})"
          if [[ -n ${relay_ipv4} ]]; then
            relay_port="$(jq -r '."single host address".port //empty' <<< ${relay})"
            say "$(printf "%-21s : %s:%s" "${relay_title}" "${relay_ipv4}" "${relay_port}")" "log"
          elif [[ -n ${relay_dns} ]]; then
            relay_port="$(jq -r '."single host name".port //empty' <<< ${relay})"
            say "$(printf "%-21s : %s:%s" "${relay_title}" "${relay_dns}" "${relay_port}")" "log"
          else
            say "$(printf "%-21s : %s" "${relay_title}" "unknown type (only IPv4/DNS supported in CNTools)")" "log"
          fi
          relay_title=""
        done <<< "${ledger_relays}"
      fi
      if [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}")"
        if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
          if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
            say "$(printf "%-21s : %s - ${RED}%s${NC} %s ago" "KES expiration date" "${expiration_date}" "EXPIRED!" "$(showTimeLeft ${expiration_time_sec_diff:1})")" "log"
          else
            say "$(printf "%-21s : %s - ${RED}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "ALERT!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
          fi
        elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
          say "$(printf "%-21s : %s - ${ORANGE}%s${NC} %s until expiration" "KES expiration date" "${expiration_date}" "WARNING!" "$(showTimeLeft ${expiration_time_sec_diff})")" "log"
        else
          say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
        fi
      fi
      # get owners
      if [[ ! $(jq -c -r '.owners[] // empty' <<< "${ledger_pParams}") = $(jq -c -r '.owners[] // empty' <<< "${ledger_fPParams}") ]]; then
        say "$(printf "%-23s ${ORANGE}%s${NC}" "" "Owner(s) updated, showing latest registered")" "log"
      fi
      owner_title="Owners(s)"
      while read -r owner; do
        owner_wallet=$(grep -r ${owner} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
        if [[ -n ${owner_wallet} ]]; then
          owner_wallet="$(basename "$(dirname "${owner_wallet}")")"
          say "$(printf "%-21s : %s" "${owner_title}" "${GREEN}${owner_wallet}${NC}")" "log"
        else
          say "$(printf "%-21s : %s" "${owner_title}" "${owner}")" "log"
        fi
        owner_title=""
      done < <(jq -c -r '.owners[] // empty' <<< "${ledger_fPParams}")
      if [[ ! $(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_pParams}") = $(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_fPParams}") ]]; then
        say "$(printf "%-23s ${ORANGE}%s${NC}" "" "Reward account updated, showing latest registered")" "log"
      fi
      reward_account=$(jq -r '.rewardAccount.credential."key hash" // empty' <<< "${ledger_fPParams}")
      if [[ -n ${reward_account} ]]; then
        reward_wallet=$(grep -r ${reward_account} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
        if [[ -n ${reward_wallet} ]]; then
          reward_wallet="$(basename "$(dirname "${reward_wallet}")")"
          say "$(printf "%-21s : %s" "Reward wallet" "${GREEN}${reward_wallet}${NC}")" "log"
        else
          say "$(printf "%-21s : %s" "Reward account" "${reward_account}")" "log"
        fi
      fi
      stake_pct=$(fractionToPCT "$(LC_NUMERIC=C printf "%.10f" "$(${CCLI} shelley query stake-distribution ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} | grep "${pool_id}" | tr -s ' ' | cut -d ' ' -f 2)")")
      if validateDecimalNbr ${stake_pct}; then
        say "$(printf "%-21s : %s %%" "Stake distribution" "${stake_pct}")" "log"
      fi
    fi
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
    say "$(printf "%-21s : %s" "Run arguments" "--shelley-kes-key ${pool_hotkey_sk_file} \\")" "log"
    say "$(printf "%-21s   %s" "" "--shelley-vrf-key ${pool_vrf_sk_file} \\")" "log"
    say "$(printf "%-21s   %s" "" "--shelley-operational-certificate ${pool_opcert_file}")" "log"
    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput
    
    ;; ###################################################################

    delegators)
    
    clear
    say " >> POOL >> DELEGATORS" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    pool_dirs=()
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_id_file="${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}"
      [[ ! -f "${pool_id_file}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available!"
      say "first create a pool"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"
    getPoolID ${pool_name}
    
    say "Looking for delegators, please wait..."
    if ! getDelegators ${pool_id}; then
      waitForInput && continue
    fi
    
    clear
    say " >> POOL >> DELEGATORS" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""
    say "${BLUE}${delegator_nbr}${NC} wallet(s) delegated to ${GREEN}${pool_name}${NC} of which ${ORANGE}${owner_nbr}${NC} are owner(s)\n"
    say "Total Stake: $(formatLovelace ${total_stake}) ADA [ owners pledge: $(formatLovelace ${total_pledged}) | delegators: $(formatLovelace $((total_stake-total_pledged))) ]\n"
    
    if [[ ${total_pledged} -lt ${pledge} ]]; then
      say "${ORANGE}WARN${NC}: Owners pledge does not cover registered pledge of $(formatLovelace ${pledge}) ADA\n"
    fi
    
    printTable ';' "$(say 'Hex Key;Stake;Rewards' | cat - <(jq -r -c '.[] | "\(.hex_key);\(.stake);\(.rewards)"' <<< "${delegators_json}"))"
    
    waitForInput && continue

    ;; ###################################################################

    rotate)

    clear
    say " >> POOL >> ROTATE KES" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi

    pool_dirs=()
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_hotkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_HOTKEY_VK_FILENAME}"
      pool_hotkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_HOTKEY_SK_FILENAME}"
      pool_opcert_counter_file="${POOL_FOLDER}/${dir}/${POOL_OPCERT_COUNTER_FILENAME}"
      [[ ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_hotkey_vk_file}"  || ! -f "${pool_hotkey_sk_file}" || ! -f "${pool_opcert_counter_file}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available to rotate KES keys for!"
      say "first create a pool or decrypt existing if encrypted"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    if ! rotatePoolKeys "${pool_name}"; then
      waitForInput && continue
    fi

    say ""
    say "Pool KES Keys Updated: ${GREEN}${pool_name}${NC}" "log"
    say "New KES start period: ${start_kes_period}" "log"
    say "KES keys will expire on kes period ${kes_expiration_period}, ${expiration_date}" "log"
    say "Restart your pool node for changes to take effect"

    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    decrypt)

    clear
    say " >> POOL >> DECRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    protectionPreRequisites || continue

    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    if [[ ${#dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available!"
      say "first create a pool"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    filesUnlocked=0
    keysDecrypted=0

    say "# Removing write protection from all pool files" "log"
    while IFS= read -r -d '' file; do
      if [[ $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}" && \
        chmod 600 "${file}" && \
        filesUnlocked=$((++filesUnlocked)) && \
        say "${file}"
      fi
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    say ""
    say "# Decrypting GPG encrypted pool files" "log"
    say ""
    say "Pool ${GREEN}${pool_name}${NC} Password"
    say ""
    if ! getPassword; then # $password variable populated by getPassword function
      say "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password

    say ""
    say "Pool decrypted:  ${GREEN}${pool_name}${NC}" "log"
    say "Files unlocked:  ${filesUnlocked}" "log"
    say "Files decrypted: ${keysDecrypted}" "log"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
      say ""
      say "${ORANGE}Pool files are now unprotected${NC}" "log"
      say "Use 'POOL >> ENCRYPT / LOCK' to re-lock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

    encrypt)

    clear
    say " >> POOL >> ENCRYPT" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    protectionPreRequisites || continue

    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    if [[ ${#dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available!"
      say "first create a pool"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    filesLocked=0
    keysEncrypted=0

    say "# Encrypting sensitive pool keys with GPG" "log"
    say ""
    say "Pool ${GREEN}${pool_name}${NC} Password"
    say ""
    if ! getPassword confirm; then # $password variable populated by getPassword function
      say "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    keyFiles=(
      "${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
      "${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    )
    for keyFile in "${keyFiles[@]}"; do
      if [[ -f "${keyFile}" ]]; then
        chmod 400 "${keyFile}" && \
        encryptFile "${keyFile}" "${password}" && \
        keysEncrypted=$((++keysEncrypted))
      fi
    done
    unset password

    say ""
    say "# Write protecting all pool files using 'chattr +i'" "log"
    while IFS= read -r -d '' file; do
      if [[ ! $(lsattr -R "$file") =~ -i- ]]; then
        chmod 400 "$file" && \
        sudo chattr +i "$file" && \
        filesLocked=$((++filesLocked)) && \
        say "$file"
      fi
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    say ""
    say "Pool encrypted:  ${GREEN}${pool_name}${NC}" "log"
    say "Files locked:    ${filesLocked}" "log"
    say "Files encrypted: ${keysEncrypted}" "log"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      say ""
      say "${BLUE}Pool files are now protected${NC}" "log"
      say "Use 'POOL >> DECRYPT / UNLOCK' to unlock"
    fi
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

  esac

  ;; ###################################################################

  blocks)

  clear
  say " >> BLOCKS" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

  if [[ ! -d "${BLOCK_LOG_DIR}" ]]; then
    say "${RED}ERROR${NC}: block log directory not found!"
    say "run cntoolsBlockCollector.sh script to start collecting blocks from json log file"
    say "log file to parse grabbed from node config file specified in env"
    say "if BLOCK_LOG_DIR has been modified cntoolsBlockCollector.sh script has to be restarted"
    say "one file for each epoch created containing that epochs created blocks"
    waitForInput && continue
  fi

  epoch=$(getEpoch)

  say "Current epoch: ${epoch}\n"

  say "Show a block summary for all epochs or a detailed view for a specific epoch?\n"
  case $(select_opt "[s] Summary" "[e] Epoch" "[Esc] Cancel") in
    0) block_table="Epoch,${BLUE}Leader Slots${NC},${GREEN}Adopted Blocks${NC},${RED}Invalid Blocks${NC}\n"
       current_epoch=${epoch}
       read -r -p "Enter number of epochs to show (enter for 10): " epoch_enter
       say ""
       epoch_enter=${epoch_enter:-10}
       if ! [[ ${epoch_enter} =~ ^[0-9]+$ ]]; then
         say "${RED}ERROR${NC}: not a number"
         waitForInput && continue
       fi
       first_epoch=$(( epoch - epoch_enter ))
       [[ ${first_epoch} -lt 0 ]] && first_epoch=0
       while [[ ${current_epoch} -gt ${first_epoch} ]]; do
         blocks_file="${BLOCK_LOG_DIR}/blocks_${current_epoch}.json"
         if [[ ! -f "${blocks_file}" ]]; then
           block_table+="${current_epoch},0,0,0\n"
         else
           leader_count=$(jq -c '[.[].slot //empty] | length' "${blocks_file}")
           invalid_count=$(jq -c '[.[].hash //empty | select(startswith("Invalid"))] | length' "${blocks_file}")
           adopted_count=$(( $(jq -c '[.[].hash //empty] | length' "${blocks_file}") - invalid_count ))
           block_table+="${current_epoch},${leader_count},${adopted_count},${invalid_count}\n"
         fi
         ((current_epoch--))
       done
       printTable ',' "$(echo -e ${block_table})"
       ;;
    1) read -r -p "Enter epoch to list (enter for current): " epoch_enter
       [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch}
       blocks_file="${BLOCK_LOG_DIR}/blocks_${epoch_enter}.json"
       if [[ ! -f "${blocks_file}" ]]; then
         say "No blocks created in epoch ${epoch_enter}"
         waitForInput && continue
       fi
       leader_count=$(jq -c '[.[].slot //empty] | length' "${blocks_file}")
       invalid_count=$(jq -c '[.[].hash //empty | select(startswith("Invalid"))] | length' "${blocks_file}")
       adopted_count=$(( $(jq -c '[.[].hash //empty] | length' "${blocks_file}") - invalid_count ))
       say "\nLeader: ${BLUE}${leader_count}${NC}  -  Adopted: ${GREEN}${adopted_count}${NC}  -  Invalid: ${RED}${invalid_count}${NC}" "log"
       if [[ ${leader_count} -gt 0 ]]; then
         say ""
         # print block table
         printTable ',' "$(say 'Slot,At,Size,Hash' | cat - <(jq -rc '.[] | [.slot,(.at|sub("\\.[0-9]+Z$"; "Z")|fromdate|strflocaltime("%Y-%m-%d %H:%M:%S %Z")),.size,.hash] | @csv' "${blocks_file}") | tr -d '"')"
       fi
       ;;
    2) continue ;;
  esac



  waitForInput

  ;; ###################################################################

  update)

  clear
  say " >> UPDATE" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say ""
  say "Full changelog available at:\nhttps://cardano-community.github.io/guild-operators/#/Scripts/cntools-changelog"
  say ""

  URL="https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts"
  URL_DOCS="https://raw.githubusercontent.com/cardano-community/guild-operators/master/docs/Scripts"
  if wget -q -T 10 -O "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library"; then
    GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    GIT_PATCH_VERSION=$(grep -r ^CNTOOLS_PATCH_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
    if [[ "$CNTOOLS_MAJOR_VERSION" != "$GIT_MAJOR_VERSION" ]];then
      say "New major version available: ${GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}${NC} (Current: ${CNTOOLS_VERSION})\n"
      say "${RED}WARNING${NC}: Breaking changes were made to CNTools!"
      say "\nPlease read changelog available at the above URL carefully and then follow directions below"
																									 
      waitForInput "We will not overwrite your changes automatically, press any key for update instructions"
      say "\n\n1) Please backup cntools.config / env files if changes has been made as well as wallet / pool folders"
      say "   Use the built in Backup option in CNTools to do this for you"
      say "\n2) After backup, re-run updated prereqs.sh script with -o -s switches, follow directions here:"
      say "   https://cardano-community.github.io/guild-operators/#/basics?id=pre-requisites"
      say "\n3) As the last step, restore modified parameters in cntools.config / env files if needed"
    elif [[ "$CNTOOLS_MINOR_VERSION" != "$GIT_MINOR_VERSION" || "$CNTOOLS_PATCH_VERSION" != "$GIT_PATCH_VERSION" ]];then
      if [[ "$GIT_PATCH_VERSION" -eq 999  ]]; then
        ((GIT_MAJOR_VERSION++))
        GIT_MINOR_VERSION=0
        GIT_PATCH_VERSION=0
      fi
      say "New version available: ${GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}.${GIT_PATCH_VERSION}${NC} (Current: ${CNTOOLS_VERSION})\n"
      say "${BLUE}INFO${NC} - The following files will be overwritten:"
      say "$CNODE_HOME/scripts/cntools.sh"
      say "$CNODE_HOME/scripts/cntools.config"
      say "$CNODE_HOME/scripts/cntools.library"
      say "$CNODE_HOME/scripts/cntoolsBlockCollector.sh"
      backup_folder="$CNODE_HOME/scripts/cntools_${CNTOOLS_VERSION}"
      say "\nA backup of current files will be saved in ${backup_folder} as <file>_${CNTOOLS_VERSION}"
      say "\nProceed with update?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) : ;; # do nothing
        1) continue ;; 
      esac
      say "Applying update..."
      if mkdir -p "${backup_folder}" &&
         cp -f "$CNODE_HOME/scripts/cntools.sh" "${backup_folder}/cntools.sh_${CNTOOLS_VERSION}" &&
         cp -f "$CNODE_HOME/scripts/cntools.config" "${backup_folder}/cntools.config_${CNTOOLS_VERSION}" &&
         cp -f "$CNODE_HOME/scripts/cntools.library" "${backup_folder}/cntools.library_${CNTOOLS_VERSION}" &&
         cp -f "$CNODE_HOME/scripts/cntoolsBlockCollector.sh" "${backup_folder}/cntoolsBlockCollector.sh_${CNTOOLS_VERSION}" &&
         wget -q -T 10 -O "$CNODE_HOME/scripts/cntools.sh" "$URL/cntools.sh" &&
         wget -q -T 10 -O "$CNODE_HOME/scripts/cntools.config" "$URL/cntools.config" &&
         wget -q -T 10 -O "$CNODE_HOME/scripts/cntools.library" "$URL/cntools.library" &&
         wget -q -T 10 -O "$CNODE_HOME/scripts/cntoolsBlockCollector.sh" "$URL/cntoolsBlockCollector.sh"; then
        chmod 750 "$CNODE_HOME/scripts/"*.sh
        chmod 640 "$CNODE_HOME/scripts/cntools.library" "$CNODE_HOME/scripts/cntools.config"
        say "\nUpdate applied successfully!\n\nPlease start CNTools again !\n"
        exit
      else
        say "\n${RED}ERROR${NC}: update unsuccessful, backup or GitHub download failed!\n"
      fi
    else
      say "${GREEN}Up to Date${NC}: You're using the latest version. No updates required!"
    fi
  else
    say "\n${RED}ERROR${NC}: download from GitHub failed, unable to perform version check!\n"
  fi
  waitForInput && continue
  
  ;; ###################################################################

  backup)

  clear
  say " >> BACKUP & RESTORE" "log"
  say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  say ""
  say "Create or restore a backup of CNTools wallets, pools and configuration files"
  say ""
  say "Backup or Restore?\n"
  case $(select_opt "[b] Backup" "[r] Restore" "[Esc] Cancel") in
    0) read -r -p "Enter full path for backup directory(created if non existent): " backup_path
       if [[ ! "${backup_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
         say "${RED}ERROR${NC}: invalid path, please specify the full path to backup directory (space not allowed)"
         waitForInput && continue
       fi
       mkdir -p "${backup_path}" # Create if missing
       if [[ ! -d "${backup_path}" ]]; then
         say "${RED}ERROR${NC}: failed to create backup directory:"
         say "${backup_path}"
         waitForInput && continue
       fi
       backup_list=(
         "${WALLET_FOLDER}"
         "${POOL_FOLDER}"
         "${BLOCK_LOG_DIR}"
         "$(dirname $0)"/env
         "$(dirname $0)"/cntools.config
       )
       backup_file="${backup_path}/cntools-$(date '+%Y%m%d%H%M%S').tgz"
       if ! tar cfz "${backup_file}" --files-from <(ls -d "${backup_list[@]}" 2>/dev/null); then
         say "${RED}ERROR${NC}: failure during backup creation :("
         waitForInput && continue
       fi
       say "\nEncrypt backup?\n"
       case $(select_opt "[y] Yes" "[n] No") in
         0) if getPassword confirm; then # $password variable populated by getPassword function
              encryptFile "${backup_file}" "${password}"
              backup_file="${backup_file}.gpg"
              unset password
            else
              say "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
            fi
            ;;
         1) : ;; # do nothing
       esac
       say "Backup file ${backup_file} successfully created" "log"
       say "\nDo you want to delete private keys?\n"
       case $(select_opt "[n] No" "[y] Yes") in
         0) : ;; # do nothing
         1) while IFS= read -r -d '' file; do
              safeDel "${file}"
            done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_PAY_SK_FILENAME}*" -print0)
            while IFS= read -r -d '' file; do
              safeDel "${file}"
            done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_STAKE_SK_FILENAME}*" -print0)
            while IFS= read -r -d '' file; do
              safeDel "${file}"
            done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_VK_FILENAME}*" -print0)
            while IFS= read -r -d '' file; do
              safeDel "${file}"
            done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}*" -print0)
            ;;
       esac
       ;;
    1) say "Backups created contain absolute path to files and directories"
       say "Restoring a backup does not replace existing files"
       say "Please restore to a temporary directory and copy files to restore to appropriate folders\n"
       read -r -p "Enter path to backup file to restore: " backup_file
       if [[ ! -f "${backup_file}" ]]; then
         say "${RED}ERROR${NC}: file not found: ${backup_file}"
         waitForInput && continue
       fi
       read -r -p "Enter full path for restore directory(created if non existent): " restore_path
       if [[ ! "${restore_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
         say "${RED}ERROR${NC}: invalid path, please specify the full path to restore directory (space not allowed)"
         waitForInput && continue
       fi
       restore_path="${restore_path}/$(basename ${backup_file%%.*})"
       mkdir -p "${restore_path}" # Create restore directory
       if [[ ! -d "${restore_path}" ]]; then
         say "${RED}ERROR${NC}: failed to create restore directory:"
         say "${restore_path}"
         waitForInput && continue
       fi
       if [ "${backup_file##*.}" = "gpg" ]; then
         say "\nBackup GPG encrypted, enter password to decrypt"
         if getPassword; then # $password variable populated by getPassword function
           decryptFile "${backup_file}" "${password}"
           backup_file="${backup_file%.*}"
           unset password
         else
           say "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
           waitForInput && continue
         fi
       fi
       if ! tar xfzk "${backup_file}" -C "${restore_path}" >/dev/null; then
         say "${RED}ERROR${NC}: failure during backup restore :("
         waitForInput && continue
       fi
       say ""
       say "Backup successfully restored to ${restore_path}" "log"
       ;;
    2) continue ;;
  esac
  
  waitForInput && continue

  ;; ###################################################################

esac # main OPERATION
done # main loop
}

##############################################################

main "$@"
