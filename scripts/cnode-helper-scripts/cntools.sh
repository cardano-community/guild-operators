#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034

########## Global tasks ###########################################

# get common env variables
# set locale for compatibility
export LC_ALL=en_US.UTF-8

. "$(dirname $0)"/env

# get cntools config parameters
. "$(dirname $0)"/cntools.config

# get helper functions from library file
. "$(dirname $0)"/cntools.library

# create temporary directory if missing
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  echo ""
  say "${RED}ERROR${NC}: Failed to create directory for temporary files:"
  say "${TMP_FOLDER}"
  echo ""
  exit 1
fi

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} --out-file "${TMP_FOLDER}"/protparams.json || {
  say "\n"
  say "${ORANGE}WARN${NC}: failed to query protocol parameters, node running and env parameters correct?"
  say "\n${BLUE}Press c to continue or any other key to quit${NC}"
  say "only offline functions will be available if you continue\n"
  read -r -n 1 -s -p "" answer
  [[ "${answer}" != "c" ]] && exit 1
}

# check for required command line tools
if ! need_cmd "curl" || \
   ! need_cmd "jq" || \
   ! need_cmd "bc" || \
   ! need_cmd "sed" || \
   ! need_cmd "awk" || \
   ! need_cmd "numfmt"; then exit 1
fi

# check to see if there are any updates available
clear
say "CNTools version check...\n"
URL="https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts"
wget -q -O "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library"
GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
if [[ "${CNTOOLS_MAJOR_VERSION}" != "${GIT_MAJOR_VERSION}" || "${CNTOOLS_MINOR_VERSION}" != "${GIT_MINOR_VERSION}" ]]; then
  say "A new version of CNTools is available" "log"
  echo ""
  say "Installed Version : ${CNTOOLS_MAJOR_VERSION}.${CNTOOLS_MINOR_VERSION}" "log"
  say "Available Version : ${GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}${NC}" "log"
  say "\nGo to Update section for upgrade"
  waitForInput "press any key to proceed to home menu"
fi

###################################################################

function main {

while true; do # Main loop

# Start with a clean slate after each completed or canceled command excluding protparams.json from purge
find "${TMP_FOLDER:?}" -type f -not -name 'protparams.json' -delete

clear
say "$(printf "%-52s %s" " >> CNTools $CNTOOLS_VERSION << " "A Guild Operators collaboration")" "log"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Main Menu"
echo ""
echo " ) Wallet  -  create, show, remove and protect wallets"
echo " ) Funds   -  send, withdraw and delegate"
echo " ) Pool    -  pool creation and management"
echo " ) Blocks  -  show core node leader slots"
echo " ) Update  -  update cntools script and library config files"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

say " What would you like to do?\n"
case $(select_opt "[w] Wallet" "[f] Funds" "[p] Pool" "[b] Blocks" "[u] Update" "[q] Quit") in
  0) OPERATION="wallet" ;;
  1) OPERATION="funds" ;;
  2) OPERATION="pool" ;;
  3) OPERATION="blocks" ;;
  4) OPERATION="update" ;;
  5) clear && exit ;;
esac

case $OPERATION in
  wallet)

  clear
  say " >> WALLET" "log"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo " Wallet Management"
  echo ""
  echo " ) New      -  create a new wallet"
  echo " ) List     -  list all available wallets in a compact view"
  echo " ) Show     -  show detailed view of a specific wallet"
  echo " ) Remove   -  remove a wallet"
  echo " ) Decrypt  -  remove write protection and decrypt wallet"
  echo " ) Encrypt  -  encrypt wallet keys and make all files immutable"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
  say " Select wallet operation\n"
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
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    read -r -p "Name of new wallet: " wallet_name
    # Remove unwanted characters from wallet name
    wallet_name=${wallet_name//[^[:alnum:]]/_}
    if [[ -z "${wallet_name}" ]]; then
      say "${RED}ERROR${NC}: Empty wallet name, please retry!"
      waitForInput && continue
    fi
    echo ""
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
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput && continue

    ;; ###################################################################

    list)
    
    clear
    say " >> WALLET >> LIST" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    pay_wallets_with_funds=()
    while IFS= read -r -d '' wallet; do
      wallet_name=$(basename ${wallet})
      enc_files=$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -printf '.' | wc -c)
      echo ""
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
        say "$(printf "%s\t\t\t${CYAN}%s${NC} ADA" "Funds"  "$(numfmt --grouping ${ada})")" "log"
      fi
      if [[ -n ${pay_addr} ]]; then
        getBalance ${pay_addr}
        if [[ ${lovelace} -gt 0 ]]; then
          say "$(printf "%s\t${CYAN}%s${NC} ADA" "Enterprise Funds"  "$(numfmt --grouping ${ada})")" "log"
          pay_wallets_with_funds+=("${wallet_name}")
        fi
      fi
      if [[ -z ${base_addr} && -z ${pay_addr} ]]; then
        say "${RED}Not a supporeted wallet${NC} - genesis address?"
        say "Use an external script to send funds to a CNTools compatible wallet"
        continue
      fi
      getRewards ${wallet_name}
      if [[ "${reward_lovelace}" -eq -1 ]]; then
        say "${ORANGE}Not a registered wallet on chain${NC}"
      else
        say "$(printf "%s\t\t\t${CYAN}%s${NC} ADA" "Rewards" "$(numfmt --grouping ${reward_ada})")" "log"
        delegation_pool_id=$(jq -r '.delegation // empty' <<< "${stakeAddressInfo}")
        if [[ -n ${delegation_pool_id} ]]; then
          unset poolName
          while IFS= read -r -d '' pool; do
            pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
            if [[ "${pool_id}" = "${delegation_pool_id}" ]]; then
              poolName=$(basename ${pool}) && break
            fi
          done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          say "${RED}Delegated to${NC} ${BLUE}${poolName}${NC} ${RED}(${delegation_pool_id})${NC}" "log"
        fi
      fi
    done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ ${#pay_wallets_with_funds[@]} -gt 0 ]]; then
      echo ""
      say "Wallets found with funds in payment/enterprise address:" "log"
      say "${GREEN}${pay_wallets_with_funds[*]}${NC}" "log"
      echo ""
      say "Do you want to upgrade these wallets to CNTools compatible wallets that can be delegated?\n"
      case $(select_opt "[n] No" "[y] Yes") in
        0) say "Upgrade process aborted!"
           ;;
        1) for wallet_name in "${pay_wallets_with_funds[@]}"; do
             say "Wallet: ${GREEN}${wallet_name}${NC}"
             # Wallet key filenames
             payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
             payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
             stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
             stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
             if [[ -f ${payment_vk_file} && -f ${payment_sk_file} && ! -f ${stake_vk_file} && ! -f ${stake_sk_file} ]]; then
               # create stake keys and addresses
               ${CCLI} shelley stake-address key-gen --verification-key-file "${stake_vk_file}" --signing-key-file "${stake_sk_file}"
             elif [[ ! -f ${payment_vk_file} || ! -f ${payment_sk_file} || ! -f ${stake_vk_file} || ! -f ${stake_sk_file} ]]; then
               say "${RED}ERROR${NC}: missing wallet files, unable to continue. Expecting these files to exist:"
               say "${payment_vk_file}"
               say "${payment_sk_file}"
               say "${stake_vk_file}"
               say "${stake_sk_file}"
             fi
             getPayAddress ${wallet_name}
             getBaseAddress ${wallet_name}
             getRewardAddress ${wallet_name}
             getBalance ${pay_addr}
             say "Sending all funds($(numfmt --grouping ${ada}) ADA) to wallets base address"
             if ! sendADA "${base_addr}" "${lovelace}" "${pay_addr}" "${payment_sk_file}" "yes" >/dev/null; then
               waitForInput "Failure while sending funds, press any key to continue"
             else
               echo ""
             fi
           done
           if ! waitNewBlockCreated; then
             waitForInput && continue
           fi 
           getBalance ${pay_addr}
           while [[ ${lovelace} -ne 0 ]]; do
             say ""
             say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${lovelace}) != 0)"
             if ! waitNewBlockCreated; then
               break
             fi
             getBalance ${pay_addr}
           done
           ;;
      esac
    fi
    
    waitForInput
    ;; ###################################################################

    show)
    
    clear
    say " >> WALLET >> SHOW" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
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
    
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
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
    base_ada=${ada}
    if [[ ${utx0_count} -gt 0 ]]; then
      echo ""
      say "${BLUE}UTxOs${NC}"
      head -n 2 "${TMP_FOLDER}"/fullUtxo.out
      head -n 10 "${TMP_FOLDER}"/balance.out
      [[ ${utx0_count} -gt 10 ]] && say "... (top 10 UTx0 with most lovelace)"
    fi
    
    getBalance ${pay_addr}
    pay_lovelace=${lovelace}
    pay_ada=${ada}
    if [[ ${utx0_count} -gt 0 ]]; then
      echo ""
      say "${BLUE}Enterprise UTxOs${NC}"
      head -n 2 "${TMP_FOLDER}"/fullUtxo.out
      head -n 10 "${TMP_FOLDER}"/balance.out
      [[ ${utx0_count} -gt 10 ]] && say "... (top 10 UTx0 with most lovelace)"
    fi
    
    echo ""
    say "$(printf "%-19s : %s" "Address" "${base_addr}")" "log"
    say "$(printf "%-19s : ${CYAN}%s${NC} ADA" "Funds" "$(numfmt --grouping ${base_ada})")" "log"
    say "$(printf "%-19s : %s" "Enterprise Address" "${pay_addr}")" "log"
    say "$(printf "%-19s : ${CYAN}%s${NC} ADA" "Enterprise Funds" "$(numfmt --grouping ${pay_ada})")" "log"
    getRewards ${wallet_name}
    if [[ "${reward_lovelace}" -eq -1 ]]; then
      echo ""
      say "${ORANGE}Not a registered wallet on chain${NC}"
    else
      say "$(printf "%-8s : ${CYAN}%s${NC} ADA" "Rewards" "$(numfmt --grouping ${reward_ada})")" "log"
      delegation_pool_id=$(jq -r '.delegation  // empty' <<< "${stakeAddressInfo}")
      if [[ -n ${delegation_pool_id} ]]; then
        unset poolName
        while IFS= read -r -d '' pool; do
          pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
          if [[ "${pool_id}" = "${delegation_pool_id}" ]]; then
            poolName=$(basename ${pool}) && break
          fi
        done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
        echo ""
        say "${RED}Delegated to${NC} ${BLUE}${poolName}${NC} ${RED}(${delegation_pool_id})${NC}" "log"
      fi
    fi
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput
    
    ;; ###################################################################

    remove)
    
    clear
    say " >> WALLET >> REMOVE" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
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
           echo "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
           ;;
        1) say "skipped removal process for ${GREEN}$wallet_name${NC}"
           ;;
      esac
      waitForInput && continue
    fi
    
    if [[ -n ${base_addr} ]]; then
      getBalance ${base_addr}
      base_lovelace=${lovelace}
      base_ada=${ada}
    else
      base_lovelace=0
      base_ada=0
    fi
    if [[ -n ${pay_addr} ]]; then
      getBalance ${pay_addr}
      pay_lovelace=${lovelace}
      pay_ada=${ada}
    else
      pay_lovelace=0
      pay_ada=0
    fi
    getRewards ${wallet_name}
    
    if [[ ${base_lovelace} -eq 0 && ${pay_lovelace} -eq 0 && ${reward_lovelace} -le 0 ]]; then
      say "INFO: This wallet appears to be empty"
      say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      say "Are you sure to delete wallet?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
           echo "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
           ;;
        1) say "skipped removal process for ${GREEN}$wallet_name${NC}"
           ;;
      esac
    else
      say "${RED}WARN${NC}: wallet not empty!"
      if [[ ${base_lovelace} -gt 0 ]]; then
        say "Funds : ${CYAN}$(numfmt --grouping ${base_ada})${NC} ADA"
      fi
      if [[ ${pay_lovelace} -gt 0 ]]; then
        say "Enterprise Funds : ${CYAN}$(numfmt --grouping ${base_ada})${NC} ADA"
      fi
      if [[ ${reward_lovelace} -gt 0 ]]; then
        say "Rewards : ${CYAN}$(numfmt --grouping ${reward_ada})${NC} ADA"
      fi
      echo ""
      say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
      say "Are you sure to delete wallet?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
           echo "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
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
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
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
    
    say " -- Removing write protection from all wallet files --" "log"
    while IFS= read -r -d '' file; do 
      if [[ $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}" && \
        chmod 600 "${file}" && \
        filesUnlocked=$((++filesUnlocked))
        say "${file}"
      fi
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)

    echo ""
    say " -- Decrypting GPG encrypted wallet files --" "log"
    echo ""
    say "Wallet ${GREEN}${wallet_name}${NC} Password"
    echo ""
    if ! getPassword; then # $password variable populated by getPassword function
      echo -e "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do 
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password
    
    echo ""
    say "Wallet unprotected: ${GREEN}${wallet_name}${NC}" "log"
    say "Files unlocked:     ${filesUnlocked}" "log"
    say "Files decrypted:    ${keysDecrypted}" "log"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
      echo ""
      say "${ORANGE}Wallet files are now unprotected${NC}"
      say "Use 'WALLET >> ENCRYPT' to re-lock"
    fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

    encrypt)
    
    clear
    say " >> WALLET >> ENCRYPT" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
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
    
    say " -- Encrypting sensitive wallet keys with GPG --" "log"
    echo ""
    say "Wallet ${GREEN}${wallet_name}${NC} Password"
    echo ""
    if ! getPassword confirm; then # $password variable populated by getPassword function
      echo -e "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    keyFiles=(
      "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
      "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
      "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
      "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_CERT_FILENAME}"
    )
    for keyFile in "${keyFiles[@]}"; do
      if [[ -f "${keyFile}" ]]; then
        chmod 400 "${keyFile}" && \
        encryptFile "${keyFile}" "${password}" && \
        keysEncrypted=$((++keysEncrypted))
      fi
    done
    unset password

    echo ""
    say " -- Write protecting all wallet files using 'chattr +i' --" "log"
    while IFS= read -r -d '' file; do
      if [[ ! $(lsattr -R "$file") =~ -i- ]]; then
        chmod 400 "${file}" && \
        sudo chattr +i "${file}" && \
        filesLocked=$((++filesLocked)) && \
        say "${file}"
      fi
    done < <(find "${WALLET_FOLDER}/${wallet_name}" -mindepth 1 -maxdepth 1 -type f -print0)
    
    echo ""
    say "Wallet protected: ${GREEN}${wallet_name}${NC}" "log"
    say "Files locked:     ${filesLocked}" "log"
    say "Files encrypted:  ${keysEncrypted}" "log"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      echo ""
      say "${BLUE}Wallet files are now protected${NC}"
      say "Use 'WALLET >> DECRYPT' to unlock"
    fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

  esac

  ;; ###################################################################

  funds)

  clear
  say " >> FUNDS" "log"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo " Handle Funds"
  echo ""
  echo " 1) Send      -  send ADA from a local wallet to an address or a wallet"
  echo " 2) Delegate  -  delegate stake wallet to a pool"
  echo " 3) Withdraw  -  withdraw earned rewards to base address"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
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
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""

    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getRewards ${dir}
        [[ ${reward_lovelace} -le 0 ]] && continue
        reward_ada=$(lovelacetoADA ${reward_lovelace})
        wallet_dirs+=("${dir} (Rewards: ${CYAN}$(numfmt --grouping ${reward_ada})${NC} ADA)")
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that have rewards to withdraw!"
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
      echo "Failed to locate any rewards associated with the chosen wallet, please try another one"
      waitForInput && continue
    fi
    
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds"  "$(numfmt --grouping ${ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(numfmt --grouping ${reward_ada})")" "log"

    if ! withdrawRewards "${stake_vk_file}" "${stake_sk_file}" "${pay_payment_sk_file}" "${base_addr}" "${reward_addr}" ${reward_lovelace}; then
      echo "" && say "${RED}ERROR${NC}: failure during withdrawal of rewards"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi
    
    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      echo ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${lovelace}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done
    
    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    getRewards ${wallet_name}

    echo ""
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds"  "$(numfmt --grouping ${ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(numfmt --grouping ${reward_ada})")" "log"
    waitForInput
    
    ;; ###################################################################

    send)
    
    clear
    say " >> FUNDS >> SEND" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    say " -- Source Wallet --"
    echo ""
    s_wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      s_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${s_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBaseAddress ${dir}
        getPayAddress ${dir}
        getBalance ${base_addr}
        base_lovelace=${lovelace}
        base_ada=${ada}
        getBalance ${pay_addr}
        pay_ada=${ada}
        pay_lovelace=${lovelace}
        if [[ ${base_lovelace} -gt 0 && ${pay_lovelace} -gt 0 ]]; then
          s_wallet_dirs+=("${dir} (Funds: ${CYAN}$(numfmt --grouping ${base_ada})${NC} ADA | Enterprise Funds: ${CYAN}$(numfmt --grouping ${pay_ada})${NC} ADA)")
        elif [[ ${base_lovelace} -gt 0 ]]; then
          s_wallet_dirs+=("${dir} (Funds: ${CYAN}$(numfmt --grouping ${base_ada})${NC} ADA)")
        elif [[ ${pay_lovelace} -gt 0 ]]; then
          s_wallet_dirs+=("${dir} (Enterprise Funds: ${CYAN}$(numfmt --grouping ${pay_ada})${NC} ADA)")
        fi
      else
        s_wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#s_wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that have funds to send!"
      waitForInput && continue
    fi
    say "Select Source Wallet:\n"
    if ! selectDir "${s_wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    s_wallet="$(echo ${dir_name} | cut -d' ' -f1)"
    
    getBaseAddress ${s_wallet}
    getPayAddress ${s_wallet}
    getBalance ${base_addr}
    base_lovelace=${lovelace}
    base_ada=${ada}
    getBalance ${pay_addr}
    pay_ada=${ada}
    pay_lovelace=${lovelace}
    
    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      say "Select source wallet address"
      say "$(printf "%s\t\t${CYAN}%s${NC} ADA" "Funds :"  "$(numfmt --grouping ${base_ada})")" "log"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(numfmt --grouping ${pay_ada})")" "log"
      echo ""
      case $(select_opt "[b] Base (default)" "[e] Enterprise" "[c] Cancel") in
        0) s_addr="${base_addr}" ;;
        1) s_addr="${pay_addr}" ;;
        2) continue ;;
      esac
    elif [[ ${pay_lovelace} -gt 0 ]]; then
      s_addr="${pay_addr}"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Enterprise Funds :"  "$(numfmt --grouping ${pay_ada})")" "log"
    elif [[ ${base_lovelace} -gt 0 ]]; then
      s_addr="${base_addr}" 
      say "$(printf "%s\t\t${CYAN}%s${NC} ADA" "Funds :"  "$(numfmt --grouping ${base_ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${s_wallet}${NC}"
      waitForInput && continue
    fi

    s_payment_sk_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_SK_FILENAME}"

    # Amount
    echo ""
    say " -- Amount to Send (in ADA) --"
    echo ""
    say "Valid entry:  ${BLUE}Integer (e.g. 15) or Decimal (e.g. 956.1235) - no commas allowed${NC}"
    say "              The string '${BLUE}all${NC}' to send all available funds in source wallet"
    echo ""
    say "Info:         If destination and source wallet is the same and amount set to 'all',"
    say "              wallet will be defraged, ie converts multiple UTxO's to one"
    echo ""
    read -r -p "Amount (ADA): " amountADA

    if  [[ "${amountADA}" != "all" ]]; then
      if ! ADAtoLovelace "${amountADA}" >/dev/null; then
        waitForInput && continue
      fi
      amountLovelace=$(ADAtoLovelace "${amountADA}")
      echo ""
      say " -- Transaction Fee --"
      echo ""
      say "Fee payed by sender? [else amount sent is reduced]\n"
      case $(select_opt "[y] Yes" "[n] No" "[c] Cancel") in
        0) include_fee="no" ;;
        1) include_fee="yes" ;;
        2) continue ;;
      esac
    else
      echo ""
      getBalance ${s_addr}
      amountADA=${ada}
      amountLovelace=${lovelace}
      say "ADA to send set to total supply: $(numfmt --grouping ${amountADA})" "log"
      echo ""
      include_fee="yes"
    fi
    
    # Destination
    say " -- Destination Address / Wallet --"
    echo ""
    d_wallet=""
    say "Is destination a local wallet or an address?\n"
    case $(select_opt "[w] Wallet" "[a] Address" "[c] Cancel") in
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
           case $(select_opt "[b] Base (default)" "[e] Enterprise" "[c] Cancel") in
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
      1) echo "" && read -r -p "Address: " d_addr ;;
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
    
    echo ""

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${s_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${lovelace}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${s_addr}
    done
    
    if [[ ${lovelace} -ne ${newBalance} ]]; then 
      waitForInput && continue
    fi

    s_balance_ada=${ada}

    getBalance ${d_addr}

    d_balance_ada=${ada}
    
    getPayAddress ${s_wallet}
    [[ "${pay_addr}" = "${s_addr}" ]] && s_wallet_type=" (Enterprise)" || s_wallet_type=""
    getPayAddress ${d_wallet}
    [[ "${pay_addr}" = "${d_addr}" ]] && d_wallet_type=" (Enterprise)" || d_wallet_type=""
    
    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say "Transaction" "log"
    say "  From          : ${GREEN}${s_wallet}${NC}${s_wallet_type}" "log"
    say "  Amount        : $(numfmt --grouping ${amountADA}) ADA" "log"
    if [[ -n "${d_wallet}" ]]; then
      say "  To            : ${GREEN}${d_wallet}${NC}${d_wallet_type}" "log"
    else
      say "  To            : ${d_addr}" "log"
    fi
    say "  Fees          : $(numfmt --grouping ${minFee}) Lovelaces" "log"
    say "  Balance" "log"
    say "  - Source      : $(numfmt --grouping ${s_balance_ada}) ADA" "log"
    say "  - Destination : $(numfmt --grouping ${d_balance_ada}) ADA" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    waitForInput

    ;; ###################################################################

    delegate)  # [WALLET NAME] [POOL NAME]

    clear
    say " >> FUNDS >> DELEGATE" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      if ! getBaseAddress ${dir} && [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]]; then continue; fi
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance ${base_addr}
        [[ ${lovelace} -eq 0 ]] && continue
        if getRewardAddress ${dir}; then
          delegation_pool_id=$(${CCLI} shelley query stake-address-info --testnet-magic ${NWMAGIC} --address "${reward_addr}" | jq -r '.[].delegation // empty')
          unset poolName
          if [[ -n ${delegation_pool_id} ]]; then
            while IFS= read -r -d '' pool; do
              pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
              if [[ "${pool_id}" = "${delegation_pool_id}" ]]; then
                poolName=$(basename ${pool}) && break
              fi
            done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          fi
          if [[ -n ${poolName} ]]; then
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
          elif [[ -n ${delegation_pool_id} ]]; then
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA - ${RED}delegated${NC} to external address)")
          else
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA)")
          fi
        else
          wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be delegated!"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"
    
    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in wallet:"  "$(numfmt --grouping ${ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${wallet_name}${NC}"
      waitForInput && continue
    fi
    getRewards ${wallet_name}
    
    if [[ reward_lovelace -eq -1 ]] && ! registerStakeWallet ${wallet_name}; then
      waitForInput && continue
    fi

    echo ""
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds"  "$(numfmt --grouping ${ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(numfmt --grouping ${reward_ada})")" "log"
    echo ""
    
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    
    say "Do you want to delegate to a local pool or specify the pools cold vkey cbor-hex?\n"
    case $(select_opt "[p] Pool" "[v] Vkey" "[c] Cancel") in
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
         echo "type: Node operator verification key" > "${pool_coldkey_vk_file}"
         echo "title: Stake pool operator key" >> "${pool_coldkey_vk_file}"
         echo "cbor-hex:" >> "${pool_coldkey_vk_file}"
         echo " ${vkey_cbor}" >> "${pool_coldkey_vk_file}"
         ;;
      2) continue ;;
    esac

    #Generated Files
    delegation_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"

    say " -- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${delegation_cert_file}"

    if ! delegate "${stake_vk_file}" "${stake_sk_file}" "${pay_payment_sk_file}" "${base_addr}" "${pool_coldkey_vk_file}" "${delegation_cert_file}" ; then
      echo "" && say "${RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
      rm -f "${delegation_cert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      echo ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${lovelace}) != $(numfmt --grouping ${newBalance}))"
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
    say "Amount : $(numfmt --grouping ${ada}) ADA" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""

    waitForInput && continue
    ;; ###################################################################

  esac

  ;; ###################################################################

  pool)

  clear
  say " >> POOL" "log"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo " Pool Management"
  echo ""
  echo " ) New       -  create a new pool"
  echo " ) Register  -  register created pool on chain using a stake wallet (pledge wallet)"
  echo " ) Modify    -  change pool parameters and register updated pool values on chain"
  echo " ) Retire    -  de-register stake pool from chain in specified epoch"
  echo " ) List      -  a compact list view of available local pools"
  echo " ) Show      -  detailed view of specified pool"
  echo " ) Rotate    -  rotate pool KES keys"
  echo " ) Decrypt   -  remove write protection and decrypt pool"
  echo " ) Encrypt   -  encrypt pool cold keys and make all files immutable"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
  say " Select wallet operation\n"
  case $(select_opt "[n] New" "[r] Register" "[m] Modify" "[x] Retire" "[l] List" "[s] Show" "[o] Rotate" "[d] Decrypt" "[e] Encrypt" "[h] Home") in
    0) SUBCOMMAND="new" ;;
    1) SUBCOMMAND="register" ;;
    2) SUBCOMMAND="modify" ;;
    3) SUBCOMMAND="retire" ;;
    4) SUBCOMMAND="list" ;;
    5) SUBCOMMAND="show" ;;
    6) SUBCOMMAND="rotate" ;;
    7) SUBCOMMAND="decrypt" ;;
    8) SUBCOMMAND="encrypt" ;;
    9) continue ;;
  esac

  case $SUBCOMMAND in
    new)

    clear
    say " >> POOL >> NEW" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    read -r -p "Pool Name: " pool_name
    # Remove unwanted characters from pool name
    pool_name=${pool_name//[^[:alnum:]]/_}
    if [[ -z "${pool_name}" ]]; then
      say "${RED}ERROR${NC}: Empty pool name, please retry!"
      waitForInput && continue
    fi
    echo ""
    mkdir -p "${POOL_FOLDER}/${pool_name}"

    pool_id_file="${POOL_FOLDER}/${pool_name}/${POOL_ID_FILENAME}"
    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
    pool_saved_kes_start="${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}"

    if [[ -f "${pool_hotkey_vk_file}" ]]; then
      say "${RED}WARN${NC}: A pool ${GREEN}$pool_name${NC} already exists"
      say "      Choose another name or delete the existing one"
      waitForInput && continue
    fi

    #Calculate appropriate KES period
    currSlot=$(getSlotTip)
    slotsPerKESPeriod=$(jq -r .slotsPerKESPeriod $GENESIS_JSON)
    start_kes_period=$(( currSlot / slotsPerKESPeriod  ))
    echo "${start_kes_period}" > ${pool_saved_kes_start}

    ${CCLI} shelley node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
    ${CCLI} shelley node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}"
    ${CCLI} shelley stake-pool id --verification-key-file "${pool_coldkey_vk_file}" > "${pool_id_file}"
    ${CCLI} shelley node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${start_kes_period}" --out-file "${pool_opcert_file}"
    ${CCLI} shelley node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"

    say "Pool: ${GREEN}${pool_name}${NC}" "log"
    say "PoolPubKey: $(cat "${pool_id_file}")" "log"
    say "Start cardano node with the following run arguments:" "log"
    say "--shelley-kes-key ${pool_hotkey_sk_file}" "log"
    say "--shelley-vrf-key ${pool_vrf_sk_file}" "log"
    say "--shelley-operational-certificate ${pool_opcert_file}" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    waitForInput && continue
    
    ;; ###################################################################

    register)

    clear
    say " >> POOL >> REGISTER" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    say "Dumping ledger-state from node, can take a while on larger networks...\n"
    
    pool_dirs=()
    timeout -k 5 30 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC} --out-file "${TMP_FOLDER}"/ledger-state.json
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_id=$(cat "${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '.esLState._delegationState._pstate._pParams."'"${pool_id}"'" // empty' "${TMP_FOLDER}"/ledger-state.json)
      [[ -n "${ledger_pool_state}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available that can be registered!"
      say "first create a pool"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    say " -- Pool Parameters --\n"
    pledge_ada=50000 # default pledge
    if [[ -f "${pool_config}" ]]; then
      pledge_ada=$(jq -r .pledgeADA "${pool_config}")
    fi
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
    if [[ -f "${pool_config}" ]]; then
      margin=$(jq -r .margin "${pool_config}")
    fi
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

    cost_ada=256 # default cost
    if [[ -f "${pool_config}" ]]; then
      cost_ada=$(jq -r .costADA "${pool_config}")
    fi
    read -r -p "Cost (in ADA, default: ${cost_ada}): " cost_enter
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    
    say "\n -- Pool Metadata --\n"
    meta_name="${pool_name}" # default name
    meta_ticker="${pool_name}" # default ticker
    meta_description="No Description" #default Description
    meta_homepage="https://foo.com" #default homepage
    meta_json_url="https://foo.bat/poolmeta.json" #default JSON
    pool_meta_file=${POOL_FOLDER}/${pool_name}/poolmeta.json
    if [[ -f "${pool_meta_file}" ]]; then
      meta_name=$(jq -r .name "${pool_meta_file}")
      meta_ticker=$(jq -r .ticker "${pool_meta_file}")
      meta_homepage=$(jq -r .homepage "${pool_meta_file}")
      meta_description=$(jq -r .description "${pool_meta_file}")
    fi
    if [[ -f "${pool_config}" ]]; then
      if [[ -z "$(jq -r .json_url ${pool_config})" ]]; then
        meta_json_url=$(jq -r .json_url "${pool_config}")
      fi
    fi
    read -r -p "Enter Pool's Name (default: ${meta_name}): " name_enter
    name_enter=${name_enter//[^[:alnum:]]/_}
    if [[ -n "${name_enter}" ]]; then
      meta_name="${name_enter}"
    fi
    read -r -p "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker}): " ticker_enter
    ticker_enter=${ticker_enter//[^[:alnum:]]/_}
    if [[ -n "${ticker_enter}" ]]; then
      meta_ticker="${ticker_enter}"
    fi
    if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
      say "${RED}ERROR${NC}: ticker must be between 3-5 characters"
      waitForInput && continue
    fi
    read -r -p "Enter Pool's Description (default: ${meta_description}): " desc_enter
    desc_enter=${desc_enter}
    if [[ -n "${desc_enter}" ]]; then
      meta_description="${desc_enter}"
    fi
    read -r -p "Enter Pool's Homepage (default: ${meta_homepage}): " homepage_enter
    homepage_enter="${homepage_enter}"
    if [[ -n "${homepage_enter}" ]]; then
      meta_homepage="${homepage_enter}"
    fi
    if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
      say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi
    read -r -p "Enter Pool's JSON URL to host metadata file - URL length should be less than 64 chars (default: ${meta_json_url}): " json_url_enter
    json_url_enter="${json_url_enter}"
    if [[ -n "${json_url_enter}" ]]; then
      meta_json_url="${json_url_enter}"
    fi
    if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
      say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi
    
    say "\n${ORANGE}Please make sure you host your metadata JSON file (with contents as below) at ${meta_json_url} :${NC}\n"
    say "{\n  \"name\": \"${meta_name}\",\n  \"ticker\": \"${meta_ticker}\",\n  \"description\": \"${meta_description}\",\n  \"homepage\": \"${meta_homepage}\"\n}" | tee "${pool_meta_file}"
    
    relay_counter=0
    relay_output=""
    relay_array=()
    say "\n -- Pool Relay Registration --\n"
    if [[ -f "${pool_config}" && -n $(jq '.relays //empty' "${pool_config}") ]]; then
      say "Previous relay configuration:\n"
      echo -e 'TYPE ADDRESS PORT\n---- ------- ----' | cat - <(jq -r -c '.relays[] | [.type //"-",.address //"-",.port //"-"] | @tsv //empty' "${pool_config}") | column -t
      echo ""
      
    fi
    # ToDo SRV & IPv6 support
    case $(select_opt "[d] A or AAAA DNS record (single)" "[4] IPv4 address (multiple)" "[c] Cancel") in 
      0) if [[ -f "${pool_config}" ]]; then
           relay_type=$(jq -r ".relays[${relay_counter}].type //empty" "${pool_config}")
           if [[ ${relay_type} = "DNS_A" ]]; then
             relay_address=$(jq -r ".relays[${relay_counter}].address //empty" "${pool_config}")
             relay_port=$(jq -r ".relays[${relay_counter}].port //empty" "${pool_config}")
           else
             relay_address=""
             relay_port=""
           fi
         fi
         read -r -p "Enter relays's DNS record, only A or AAAA DNS records (default: ${relay_address}): " relay_dns_enter
         if [[ -n "${relay_dns_enter}" ]]; then
           relay_address="${relay_dns_enter}"
         elif [[ -z "${relay_address}" ]]; then
           say "${RED}ERROR${NC}: DNS record can not be empty!"
           waitForInput && continue
         fi
         #ToDo - DNS format verficication?
         read -r -p "Enter relays's port (default: ${relay_port}): " relay_port_enter
         if [[ -n "${relay_port_enter}" ]]; then
           if [[ "${relay_port_enter}" =~ ^[0-9]+$ && "${relay_port_enter}" -ge 1 && "${relay_port_enter}" -le 65535 ]]; then
             relay_port="${relay_port_enter}"
           else
             say "${RED}ERROR${NC}: invalid port number!"
             waitForInput && continue
           fi
         elif [[ -z "${relay_port}" ]]; then
           say "${RED}ERROR${NC}: Port can not be empty!"
           waitForInput && continue
         fi
         relay_array+=( "type" "DNS_A" "address" "${relay_address}" "port" "${relay_port}" )
         relay_output="--single-host-pool-relay ${relay_address} --pool-relay-port ${relay_port}"
         ;;
      1) while true; do
           if [[ -f "${pool_config}" ]]; then
             relay_type=$(jq -r ".relays[${relay_counter}].type //empty" "${pool_config}")
             if [[ ${relay_type} = "IPv4" ]]; then
               relay_address=$(jq -r ".relays[${relay_counter}].address //empty" "${pool_config}")
               relay_port=$(jq -r ".relays[${relay_counter}].port //empty" "${pool_config}")
             else
               relay_address=""
               relay_port=""
             fi
           fi
           read -r -p "Enter relays's IPv4 address (default: ${relay_address}): " relay_ipv4_enter
           if [[ -n "${relay_ipv4_enter}" ]]; then
             if validIP "${relay_ipv4_enter}"; then
               relay_address="${relay_ipv4_enter}"
             else
               say "${RED}ERROR${NC}: invalid IPv4 address format!\n"
               continue
             fi
           elif [[ -z "${relay_address}" ]]; then
             say "${RED}ERROR${NC}: IPv4 address can not be empty!\n"
             continue
           fi
           read -r -p "Enter relays's port (default: ${relay_port}): " relay_port_enter
           if [[ -n "${relay_port_enter}" ]]; then
             if [[ "${relay_port_enter}" =~ ^[0-9]+$ && "${relay_port_enter}" -ge 1 && "${relay_port_enter}" -le 65535 ]]; then
               relay_port="${relay_port_enter}"
             else
               say "${RED}ERROR${NC}: invalid port number!\n"
               continue
             fi
           elif [[ -z "${relay_port}" ]]; then
             say "${RED}ERROR${NC}: Port can not be empty!\n"
             continue
           fi
           relay_array+=( "type" "IPv4" "address" "${relay_address}" "port" "${relay_port}" )
           relay_output+="--pool-relay-port ${relay_port} --pool-relay-ipv4 ${relay_address} "
           say "\nAdd more IPv4 entries?\n"
           case $(select_opt "[y] Yes" "[n] No" "[c] Cancel") in
             0) ((relay_counter++)) && continue ;;
             1) break ;;
             2) continue 2 ;;
           esac
         done
         ;;
      2) continue ;;
    esac
    
    echo ""

    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      if ! getBaseAddress ${dir} && [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]]; then continue; fi
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance ${base_addr}
        [[ ${lovelace} -eq 0 ]] && continue
        if getRewardAddress ${dir}; then
          delegation_pool_id=$(${CCLI} shelley query stake-address-info --testnet-magic ${NWMAGIC} --address "${reward_addr}" | jq -r '.[].delegation // empty')
          unset poolName
          if [[ -n ${delegation_pool_id} ]]; then
            while IFS= read -r -d '' pool; do
              pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
              if [[ "${pool_id}" = "${delegation_pool_id}" ]]; then
                poolName=$(basename ${pool}) && break
              fi
            done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          fi
          if [[ -n ${poolName} ]]; then
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
          elif [[ -n ${delegation_pool_id} ]]; then
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA - ${RED}delegated${NC} to external address)")
          else
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA)")
          fi
        else
          wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be used in pool registration as pledge wallet!"
      waitForInput && continue
    fi
    say "Select Pledge Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pledge_wallet="$(echo ${dir_name} | cut -d' ' -f1)"
    getBaseAddress ${pledge_wallet}
    getBalance ${base_addr}
    
    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in pledge wallet:"  "$(numfmt --grouping ${ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${pledge_wallet}${NC}"
      waitForInput && continue
    fi
    if ! isWalletRegistered ${pledge_wallet} && ! registerStakeWallet ${pledge_wallet}; then
      waitForInput && continue
    fi
    
    # Construct relay json array
    relay_json=$({
      echo '['
      printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
      echo ']'
    } | jq -c .)
    # Save pool config
    echo "{\"pledgeWallet\":\"$pledge_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada,\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"
    
    base_addr_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_BASE_ADDR_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_PAY_SK_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_STAKE_VK_FILENAME}"

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"

    if [[ ! -f "${base_addr_file}" || ! -f "${pay_payment_sk_file}" || ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" ]]; then
      say "${RED}ERROR${NC}: Source pledge wallet files missing, expecting these files to be available:"
      say "${base_addr_file}"
      say "${pay_payment_sk_file}"
      say "${stake_sk_file}"
      say "${stake_vk_file}"
      waitForInput && continue
    fi

    [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}"  || ! -f "${pool_vrf_vk_file}" ]] && {
      say "${RED}ERROR${NC}: pool files missing, expecting these files to be available:"
      say "${pool_coldkey_vk_file}"
      say "${pool_coldkey_sk_file}"
      say "${pool_vrf_vk_file}"
      waitForInput && continue
    }

    #Generated Files
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
    pool_pledgecert_file="${POOL_FOLDER}/${pool_name}/${POOL_PLEDGECERT_FILENAME}"
    
    echo ""
    say " ## Register Stake Pool ##" "log"
    echo ""
    say " -- creating registration cert --" "log"
    echo ""
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${stake_vk_file}" --pool-owner-stake-verification-key-file "${stake_vk_file}" --out-file "${pool_regcert_file}" --testnet-magic ${NWMAGIC} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} shelley stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output}
    say " -- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${pool_pledgecert_file}"
    
    say " -- Sending transaction to chain --" "log"
    if ! registerPool "$(cat ${base_addr_file})" "${pool_coldkey_sk_file}" "${stake_sk_file}" "${pool_regcert_file}" "${pool_pledgecert_file}" "${pay_payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool registration, removing newly created pledge and registration files"
      rm -f "${pool_regcert_file}" "${pool_pledgecert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${lovelace}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done
    
    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    echo ""
    say "Pool ${GREEN}${pool_name}${NC} successfully registered using wallet ${GREEN}${pledge_wallet}${NC} for pledge" "log"
    say "Pledge : $(numfmt --grouping ${pledge_ada}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(numfmt --grouping ${cost_ada}) ADA" "log"
    if [[ ${lovelace} -lt ${pledge_lovelace} ]]; then
      echo ""
      say "${ORANGE}WARN${NC}: Balance in pledge wallet is less than set pool pledge"
      say "      make sure to put enough funds in wallet to honor pledge"
    fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    waitForInput && continue
    
    ;; ###################################################################

    modify)

    clear
    say " >> POOL >> MODIFY" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    say "Dumping ledger-state from node, can take a while on larger networks...\n"
    
    pool_dirs=()
    timeout -k 5 30 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC} --out-file "${TMP_FOLDER}"/ledger-state.json
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_id=$(cat "${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '.esLState._delegationState._pstate._pParams."'"${pool_id}"'" // empty' "${TMP_FOLDER}"/ledger-state.json)
      [[ -z "${ledger_pool_state}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available that can be modified!"
      say "first register a pool"
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

    # Pledge wallet, also used to pay for pool update fee
    echo ""
    pledge_wallet=$(jq -r .pledgeWallet "${pool_config}") # old pledge wallet
    say " -- Pledge Wallet --"
    echo ""
    say "Old pledge wallet: ${GREEN}${pledge_wallet}${NC}"
    echo ""
    say "${ORANGE}If a new wallet is chosen as pledge a manual delegation to the pool with new wallet is needed${NC}"
    echo ""
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      if ! getBaseAddress ${dir} && [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]]; then continue; fi
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance ${base_addr}
        [[ ${lovelace} -eq 0 ]] && continue
        if getRewardAddress ${dir}; then
          delegation_pool_id=$(${CCLI} shelley query stake-address-info --testnet-magic ${NWMAGIC} --address "${reward_addr}" | jq -r '.[].delegation // empty')
          unset poolName
          if [[ -n ${delegation_pool_id} ]]; then
            while IFS= read -r -d '' pool; do
              pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
              if [[ "${pool_id}" = "${delegation_pool_id}" ]]; then
                poolName=$(basename ${pool}) && break
              fi
            done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          fi
          if [[ -n ${poolName} ]]; then
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
          elif [[ -n ${delegation_pool_id} ]]; then
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA - ${RED}delegated${NC} to external address)")
          else
            wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA)")
          fi
        else
          wallet_dirs+=("${dir} (${CYAN}${ada}${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be used in pool registration as pledge wallet!"
      waitForInput && continue
    fi
    say "Select Pledge Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pledge_wallet="$(echo ${dir_name} | cut -d' ' -f1)"
    getBaseAddress ${pledge_wallet}
    getBalance ${base_addr}
    
    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in pledge wallet:"  "$(numfmt --grouping ${ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${pledge_wallet}${NC}"
      waitForInput && continue
    fi
    if ! isWalletRegistered ${pledge_wallet} && ! registerStakeWallet ${pledge_wallet}; then
      waitForInput && continue
    fi
    
    say "\n -- Pool Parameters --\n"
    say "press enter to use old value\n"
    
    pledge_ada=$(jq -r .pledgeADA "${pool_config}")
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

    margin=$(jq -r .margin "${pool_config}")
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

    cost_ada=$(jq -r .costADA "${pool_config}")
    read -r -p "New Cost (in ADA, old: ${cost_ada}): " cost_enter
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    
    say "\n -- Pool Metadata --\n"
    say "press enter to use old value\n"
    
    pool_meta_file=${POOL_FOLDER}/${pool_name}/poolmeta.json
    if [[ -f "${pool_meta_file}" ]]; then
      meta_name=$(jq -r .name "${pool_meta_file}")
      meta_ticker=$(jq -r .ticker "${pool_meta_file}")
      meta_homepage=$(jq -r .homepage "${pool_meta_file}")
      meta_description=$(jq -r .description "${pool_meta_file}")
    fi
    if [[ -f "${pool_config}" ]]; then
      meta_json_url=$(jq -r .json_url "${pool_config}")
    fi
    read -r -p "Enter Pool's Name (default: ${meta_name}): " name_enter
    name_enter=${name_enter//[^[:alnum:]]/_}
    if [[ -n "${name_enter}" ]]; then
      meta_name="${name_enter}"
    fi
    read -r -p "Enter Pool's Ticker (default: ${meta_ticker}): " ticker_enter
    ticker_enter=${ticker_enter//[^[:alnum:]]/_}
    if [[ -n "${ticker_enter}" ]]; then
      meta_ticker="${ticker_enter}"
    fi
    if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
      say "${RED}ERROR${NC}: ticker must be between 3-5 characters"
      waitForInput && continue
    fi
    read -r -p "Enter Pool's Description (default: ${meta_description}): " desc_enter
    desc_enter=${desc_enter}
    if [[ -n "${desc_enter}" ]]; then
      meta_description="${desc_enter}"
    fi
    read -r -p "Enter Pool's Homepage (default: ${meta_homepage}): " homepage_enter
    homepage_enter="${homepage_enter}"
    if [[ -n "${homepage_enter}" ]]; then
      meta_homepage="${homepage_enter}"
    fi
    if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
      say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi
    read -r -p "Enter Pool's JSON URL to host metadata file (default: ${meta_json_url}): " json_url_enter
    json_url_enter="${json_url_enter}"
    if [[ -n "${json_url_enter}" ]]; then
      meta_json_url="${json_url_enter}"
    fi
    if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 64 ]]; then
      say "${RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
      waitForInput && continue
    fi

    say "\n${ORANGE}Please host ${pool_meta_file} file as-is at ${meta_json_url}!${NC}\n"
    echo -e "{\n  \"name\": \"${meta_name}\",\n  \"ticker\": \"${meta_ticker}\",\n  \"description\": \"${meta_description}\",\n  \"homepage\": \"${meta_homepage}\"\n}" > "${pool_meta_file}"

    relay_counter=0
    relay_output=""
    relay_array=()
    say "\n -- Pool Relay Registration --\n"
    if [[ -f "${pool_config}" && -n $(jq '.relays //empty' "${pool_config}") ]]; then
      say "Previous relay configuration:\n"
      echo -e 'TYPE ADDRESS PORT\n---- ------- ----' | cat - <(jq -r -c '.relays[] | [.type //"-",.address //"-",.port //"-"] | @tsv //empty' "${pool_config}") | column -t
      echo ""
      
    fi
    # ToDo SRV & IPv6 support
    case $(select_opt "[d] A or AAAA DNS record (single)" "[4] IPv4 address (multiple)" "[c] Cancel") in 
      0) if [[ -f "${pool_config}" ]]; then
           relay_type=$(jq -r ".relays[${relay_counter}].type //empty" "${pool_config}")
           if [[ ${relay_type} = "DNS_A" ]]; then
             relay_address=$(jq -r ".relays[${relay_counter}].address //empty" "${pool_config}")
             relay_port=$(jq -r ".relays[${relay_counter}].port //empty" "${pool_config}")
           else
             relay_address=""
             relay_port=""
           fi
         fi
         read -r -p "Enter relays's DNS record, only A or AAAA DNS records (default: ${relay_address}): " relay_dns_enter
         if [[ -n "${relay_dns_enter}" ]]; then
           relay_address="${relay_dns_enter}"
         elif [[ -z "${relay_address}" ]]; then
           say "${RED}ERROR${NC}: DNS record can not be empty!"
           waitForInput && continue
         fi
         #ToDo - DNS format verficication?
         read -r -p "Enter relays's port (default: ${relay_port}): " relay_port_enter
         if [[ -n "${relay_port_enter}" ]]; then
           if [[ "${relay_port_enter}" =~ ^[0-9]+$ && "${relay_port_enter}" -ge 1 && "${relay_port_enter}" -le 65535 ]]; then
             relay_port="${relay_port_enter}"
           else
             say "${RED}ERROR${NC}: invalid port number!"
             waitForInput && continue
           fi
         elif [[ -z "${relay_port}" ]]; then
           say "${RED}ERROR${NC}: Port can not be empty!"
           waitForInput && continue
         fi
         relay_array+=( "type" "DNS_A" "address" "${relay_address}" "port" "${relay_port}" )
         relay_output="--single-host-pool-relay ${relay_address} --pool-relay-port ${relay_port}"
         ;;
      1) while true; do
           if [[ -f "${pool_config}" ]]; then
             relay_type=$(jq -r ".relays[${relay_counter}].type //empty" "${pool_config}")
             if [[ ${relay_type} = "IPv4" ]]; then
               relay_address=$(jq -r ".relays[${relay_counter}].address //empty" "${pool_config}")
               relay_port=$(jq -r ".relays[${relay_counter}].port //empty" "${pool_config}")
             else
               relay_address=""
               relay_port=""
             fi
           fi
           read -r -p "Enter relays's IPv4 address (default: ${relay_address}): " relay_ipv4_enter
           if [[ -n "${relay_ipv4_enter}" ]]; then
             if validIP "${relay_ipv4_enter}"; then
               relay_address="${relay_ipv4_enter}"
             else
               say "${RED}ERROR${NC}: invalid IPv4 address format!\n"
               continue
             fi
           elif [[ -z "${relay_address}" ]]; then
             say "${RED}ERROR${NC}: IPv4 address can not be empty!\n"
             continue
           fi
           read -r -p "Enter relays's port (default: ${relay_port}): " relay_port_enter
           if [[ -n "${relay_port_enter}" ]]; then
             if [[ "${relay_port_enter}" =~ ^[0-9]+$ && "${relay_port_enter}" -ge 1 && "${relay_port_enter}" -le 65535 ]]; then
               relay_port="${relay_port_enter}"
             else
               say "${RED}ERROR${NC}: invalid port number!\n"
               continue
             fi
           elif [[ -z "${relay_port}" ]]; then
             say "${RED}ERROR${NC}: Port can not be empty!\n"
             continue
           fi
           relay_array+=( "type" "IPv4" "address" "${relay_address}" "port" "${relay_port}" )
           relay_output+="--pool-relay-port ${relay_port} --pool-relay-ipv4 ${relay_address} "
           say "\nAdd more IPv4 entries?\n"
           case $(select_opt "[y] Yes" "[n] No" "[c] Cancel") in
             0) ((relay_counter++)) && continue ;;
             1) break ;;
             2) continue 2 ;;
           esac
         done
         ;;
      2) continue ;;
    esac
    
    # Construct relay json array
    relay_json=$({
      echo '['
      printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
      echo ']'
    } | jq -c .)
    # Update pool config
    echo "{\"pledgeWallet\":\"$pledge_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada,\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"

    base_addr_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_BASE_ADDR_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_PAY_SK_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${pledge_wallet}/${WALLET_STAKE_VK_FILENAME}"

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"

    if [[ ! -f "${base_addr_file}" || ! -f "${pay_payment_sk_file}" || ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" ]]; then
      say "${RED}ERROR${NC}: ${GREEN}${pledge_wallet}${NC} wallet files missing, expecting these files to be available:"
      say "${base_addr_file}"
      say "${pay_payment_sk_file}"
      say "${stake_sk_file}"
      say "${stake_vk_file}"
      waitForInput && continue
    fi

    [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}"  || ! -f "${pool_vrf_vk_file}" ]] && {
      say "${RED}ERROR${NC}: ${GREEN}${pool_name}${NC} pool files missing, expecting these files to be available:"
      say "${pool_coldkey_vk_file}"
      say "${pool_coldkey_sk_file}"
      say "${pool_vrf_vk_file}"
      waitForInput && continue
    }

    #Generated Files
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
    
    echo ""
    say " -- creating registration cert --" "log"
    echo ""
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${stake_vk_file}" --pool-owner-stake-verification-key-file "${stake_vk_file}" --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} shelley stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output} --testnet-magic ${NWMAGIC} --out-file "${pool_regcert_file}"
    
    say " -- Sending transaction to chain --" "log"
    if ! modifyPool "${base_addr}" "${pool_coldkey_sk_file}" "${stake_sk_file}" "${pool_regcert_file}" "${pay_payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool update, removing newly created registration certificate"
      rm -f "${pool_regcert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${lovelace}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done
    
    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    echo ""
    say "Pool ${GREEN}${pool_name}${NC} successfully updated with new parameters using wallet ${GREEN}${pledge_wallet}${NC} to pay for registration fee" "log"
    say "Pledge : $(numfmt --grouping ${pledge_ada}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(numfmt --grouping ${cost_ada}) ADA" "log"
    if [[ ${lovelace} -lt ${pledge_lovelace} ]]; then
      echo ""
      say "${ORANGE}WARN${NC}: Balance in pledge wallet is less than set pool pledge"
      say "      make sure to put enough funds in wallet to honor pledge"
    fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    waitForInput && continue
    
    ;; ###################################################################

    retire)

    clear
    say " >> POOL >> RETIRE" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    say "Dumping ledger-state from node, can take a while on larger networks...\n"
    
    pool_dirs=()
    timeout -k 5 30 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC} --out-file "${TMP_FOLDER}"/ledger-state.json
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_id=$(cat "${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '.esLState._delegationState._pstate._pParams."'"${pool_id}"'" // empty' "${TMP_FOLDER}"/ledger-state.json)
      [[ -z "${ledger_pool_state}" ]] && continue
      pool_dirs+=("${dir}")
    done
    if [[ ${#pool_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No pools available that can be retired!"
      say "first register a pool"
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
    echo ""
  
    read -r -p "Enter epoch in which to retire pool (blank for ${epoch_start}): " epoch_enter
    [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch_start}
    
    if [[ ${epoch_enter} -lt ${epoch_start} || ${epoch_enter} -gt ${epoch_end} ]]; then
      say "${RED}ERROR${NC}: epoch invalid, valid range: ${epoch_start}-${epoch_end}"
      waitForInput && continue
    fi
    
    say "\nWallet for pool de-registration transaction fee"
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        if getBaseAddress ${dir}; then
          getBalance ${base_addr}
          [[ ${lovelace} -eq 0 ]] && continue
          wallet_dirs+=("${dir} (${CYAN}$(numfmt --grouping ${ada})${NC} ADA)")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that have funds to pay for pool retirement transaction fee!"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"
    getBaseAddress ${wallet_name}
    getBalance ${base_addr}
    
    if [[ ${lovelace} -gt 0 ]]; then
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in wallet:"  "$(numfmt --grouping ${ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available for wallet ${GREEN}${wallet_name}${NC}"
      say "funds needed to pay for tx fee sending deregistration certificate to chain"
      waitForInput && continue
    fi
    echo ""
    
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
    
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    
    say " -- creating de-registration cert --" "log"
    ${CCLI} shelley stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}
    
    if ! deRegisterPool "${pool_coldkey_sk_file}" "${pool_deregcert_file}" "${base_addr}" "${payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool de-registration"
      waitForInput && continue
    fi
    
    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${base_addr}

    while [[ ${lovelace} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${lovelace}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${base_addr}
    done
    
    if [[ ${lovelace} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi
    
    echo ""
    say "Pool ${GREEN}${pool_name}${NC} set to be retired in epoch ${BLUE}${epoch_enter}${NC}" "log"
    
    waitForInput
    
    ;; ###################################################################

    list)
    
    clear
    say " >> POOL >> LIST" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    say "Dumping ledger-state from node, can take a while on larger networks...\n"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    timeout -k 5 30 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC} --out-file "${TMP_FOLDER}"/ledger-state.json
    
    while IFS= read -r -d '' pool; do 
      echo ""
      pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '.esLState._delegationState._pstate._pParams."'"${pool_id}"'" // empty' "${TMP_FOLDER}"/ledger-state.json)
      [[ -n "${ledger_pool_state}" ]] && pool_registered="YES" || pool_registered="NO"
      say "${GREEN}$(basename ${pool})${NC} "
      say "$(printf "%-21s : %s" "ID" "${pool_id}")" "log"
      say "$(printf "%-21s : %s" "Registered" "${pool_registered}")" "log"
      if [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${pool}/${POOL_CURRENT_KES_START}")"
        say "$(printf "%-21s : %s" "KES expiration period" "${kes_expiration_period}")" "log"
        say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
      fi
    done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    waitForInput
    
    ;; ###################################################################

    show)
    
    clear
    say " >> POOL >> SHOW" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTools started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    pool_dirs=()
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_id="${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}"
      [[ ! -f "${pool_id}" ]] && continue
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
    timeout -k 5 45 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC} --out-file "${TMP_FOLDER}"/ledger-state.json
    
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    pool_id=$(cat "${POOL_FOLDER}/${pool_name}/${POOL_ID_FILENAME}")
    ledger_pool_state=$(jq -r '.esLState._delegationState._pstate._pParams."'"${pool_id}"'" // empty' "${TMP_FOLDER}"/ledger-state.json)
    [[ -n "${ledger_pool_state}" ]] && pool_registered="YES" || pool_registered="NO"
    say "${GREEN}${pool_name}${NC} "
    say "$(printf "%-21s : %s" "ID" "${pool_id}")" "log"
    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    if [[ -f "${pool_config}" ]]; then
      say "$(printf "%-21s : %s ADA" "Pledge" "$(numfmt --grouping "$(jq -r .pledgeADA "${pool_config}")")")" "log"
      say "$(printf "%-21s : %s %%" "Margin" "$(numfmt --grouping "$(jq -r .margin "${pool_config}")")")" "log"
      say "$(printf "%-21s : %s ADA" "Cost" "$(numfmt --grouping "$(jq -r .costADA "${pool_config}")")")" "log"
    fi
    pool_meta_file=${POOL_FOLDER}/${pool_name}/poolmeta.json
    if [[ -f "${pool_meta_file}" ]]; then
      say "$(printf "%-21s : %s" "Meta Name" "$(jq -r .name "${pool_meta_file}")")" "log"
      say "$(printf "%-21s : %s" "Meta Ticker" "$(jq -r .ticker "${pool_meta_file}")")" "log"
      say "$(printf "%-21s : %s" "Meta Homepage" "$(jq -r .homepage "${pool_meta_file}")")" "log"
      say "$(printf "%-21s : %s" "Meta Description" "$(jq -r .description "${pool_meta_file}")")" "log"
    fi
    if [[ -f "${pool_config}" ]]; then
      say "$(printf "%-21s : %s" "Meta Json URL" "$(jq -r .json_url "${pool_config}")")" "log"
      if [[ -n $(jq '.relays //empty' "${pool_config}") ]]; then
        jq -c '.relays[]' "${pool_config}" | while read -r relay; do
          say "$(printf "%-21s : %s" "Relay ($(jq -r '.type' <<< ${relay}))" "$(jq -r '. | .address + ":" + .port' <<< ${relay})")" "log"
        done
      fi
    fi
    say "$(printf "%-21s : %s" "Registered" "${pool_registered}")" "log"
    if [[ "${pool_registered}" = "YES" ]]; then
      if [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}")"
        say "$(printf "%-21s : %s" "KES expiration period" "${kes_expiration_period}")" "log"
        say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
      fi
      # get owners
      while read -r owner; do
        owner_wallet=$(grep -r ${owner} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
        owner_wallet="$(basename "$(dirname "${owner_wallet}")")"
        if [[ -n ${owner_wallet} ]]; then
          say "$(printf "%-21s : %s" "Owner wallet" "${GREEN}${owner_wallet}${NC}")" "log"
        else
          say "$(printf "%-21s : %s" "Owner account" "${owner}")" "log"
        fi
      done < <(jq -c -r '.owners[] // empty' <<< "${ledger_pool_state}")
      reward_account=$(jq -r '.rewardAccount.credential."key hash"' <<< "${ledger_pool_state}")
      if [[ -n ${reward_account} ]]; then
        reward_wallet=$(grep -r ${reward_account} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
        reward_wallet="$(basename "$(dirname "${reward_wallet}")")"
        if [[ -n ${reward_wallet} ]]; then
          say "$(printf "%-21s : %s" "Reward wallet" "${GREEN}${reward_wallet}${NC}")" "log"
        else
          say "$(printf "%-21s : %s" "Reward account" "${reward_account}")" "log"
        fi
      fi
      # Delegators
      printf "Looking for delegators, please wait..."
      non_myopic_delegators=$(jq -r ".esNonMyopic.snapNM._delegations | .[] | select(.[1] == \"${pool_id}\") | .[0][\"key hash\"]" "${TMP_FOLDER}"/ledger-state.json)
      snapshot_delegators=$(jq -r ".esSnapshots._pstakeSet._delegations | .[] | select(.[1] == \"${pool_id}\") | .[0][\"key hash\"]" "${TMP_FOLDER}"/ledger-state.json)
      lstate_delegators=$(jq -r ".esLState._delegationState._dstate._delegations | .[] | select(.[1] == \"${pool_id}\") | .[0][\"key hash\"]" "${TMP_FOLDER}"/ledger-state.json)
      delegators=$(echo "${non_myopic_delegators}" "${snapshot_delegators}" "${lstate_delegators}" | tr ' ' '\n' | sort -u)
      total_stake=0
      delegator=1
      for key in ${delegators}; do
        printf "\r"
        stake_address="581de0${key}"
        reward=$(jq -r ".esLState._delegationState._dstate._rewards | .[] | select(.[0][\"credential\"][\"key hash\"] == \"${key}\") | .[1]" "${TMP_FOLDER}"/ledger-state.json)
        stake=$(jq ".esLState._utxoState._utxo | .[] | select(.address | contains(\"${key}\")) | .amount" "${TMP_FOLDER}"/ledger-state.json | awk '{total = total + $1} END {print total}')
        total_stake=$((total_stake + stake))
        say "$(printf "%-21s : %s" "Delegator ${delegator} hex key" "${key}")" "log"
        say "$(printf "%-21s : ${CYAN}%s${NC} ADA (%s ADA)" " Stake (reward)" "$(numfmt --grouping "$(lovelacetoADA ${stake})")" "$(numfmt --grouping "$(lovelacetoADA ${reward})")")" "log"
        delegator=$((delegator+1))
      done
      say "$(printf "%-21s : ${GREEN}%s${NC} ADA" "Stake" "$(numfmt --grouping "$(lovelacetoADA ${total_stake})")")" "log"
      stake_pct=$(fractionToPCT "$(printf "%.10f" "$(${CCLI} shelley query stake-distribution --testnet-magic ${NWMAGIC} | grep "${pool_id}" | tr -s ' ' | cut -d ' ' -f 2)")")
      if validateDecimalNbr ${stake_pct}; then
        say "$(printf "%-21s : %s %%" "Stake distribution" "${stake_pct}")" "log"
      fi
    fi
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
    say "$(printf "%-21s : %s" "Run arguments" "--shelley-kes-key ${pool_hotkey_sk_file}")" "log"
    say "$(printf "%-21s   %s" "" "--shelley-vrf-key ${pool_vrf_sk_file}")" "log"
    say "$(printf "%-21s   %s" "" "--shelley-operational-certificate ${pool_opcert_file}")" "log"
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput
    
    ;; ###################################################################
    
    rotate)

    clear
    say " >> POOL >> ROTATE KES" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
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
      say "first create a pool"
      waitForInput && continue
    fi
    say "Select Pool:\n"
    if ! selectDir "${pool_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    pool_name="${dir_name}"

    # cold keys
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"

    # generated files
    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
    pool_saved_kes_start="${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"

    #Calculate appropriate KES period
    currSlot=$(getSlotTip)
    slotsPerKESPeriod=$(jq -r .slotsPerKESPeriod $GENESIS_JSON)
    start_kes_period=$(( currSlot / slotsPerKESPeriod  ))

    echo "${start_kes_period}" > ${pool_saved_kes_start}

    ${CCLI} shelley node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
    ${CCLI} shelley node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${start_kes_period}" --out-file "${pool_opcert_file}"
    
    kesExpiration "${start_kes_period}"

    echo ""
    say "Pool KES Keys Updated: ${GREEN}${pool_name}${NC}" "log"
    say "New KES start period: ${start_kes_period}" "log"
    say "KES keys will expire on kes period ${kes_expiration_period}, ${expiration_date}" "log"
    say "Restart your pool node for changes to take effect"

    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    waitForInput && continue
    
    ;; ###################################################################
    
    decrypt)
    
    clear
    say " >> POOL >> DECRYPT" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
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
    
    say " -- Removing write protection from all pool files --" "log"
    while IFS= read -r -d '' file; do
      if [[ $(lsattr -R "$file") =~ -i- ]]; then
        sudo chattr -i "${file}" && \
        chmod 600 "${file}" && \
        filesUnlocked=$((++filesUnlocked)) && \
        say "${file}"
      fi
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)
    
    echo ""
    say " -- Decrypting GPG encrypted pool files --" "log"
    echo ""
    say "Pool ${GREEN}${pool_name}${NC} Password"
    echo ""
    if ! getPassword; then # $password variable populated by getPassword function
      echo -e "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      waitForInput && continue
    fi
    while IFS= read -r -d '' file; do 
      decryptFile "${file}" "${password}" && \
      chmod 600 "${file::-4}" && \
      keysDecrypted=$((++keysDecrypted))
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
    unset password
    
    echo ""
    say "Pool decrypted:  ${GREEN}${pool_name}${NC}" "log"
    say "Files unlocked:  ${filesUnlocked}" "log"
    say "Files decrypted: ${keysDecrypted}" "log"
    if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then 
      echo ""
      say "${ORANGE}Pool files are now unprotected${NC}" "log"
      say "Use 'POOL >> ENCRYPT / LOCK' to re-lock"
    fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

    encrypt)
    
    clear
    say " >> POOL >> ENCRYPT" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
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

    say " -- Encrypting sensitive pool keys with GPG --" "log"
    echo ""
    say "Pool ${GREEN}${pool_name}${NC} Password"
    echo ""
    if ! getPassword confirm; then # $password variable populated by getPassword function
      echo -e "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
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
    
    echo ""
    say " -- Write protecting all pool files using 'chattr +i' --" "log"
    while IFS= read -r -d '' file; do
      if [[ ! $(lsattr -R "$file") =~ -i- ]]; then
        chmod 400 "$file" && \
        sudo chattr +i "$file" && \
        filesLocked=$((++filesLocked)) && \
        say "$file"
      fi
    done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)
    
    echo ""
    say "Pool encrypted:  ${GREEN}${pool_name}${NC}" "log"
    say "Files locked:    ${filesLocked}" "log"
    say "Files encrypted: ${keysEncrypted}" "log"
    if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
      echo ""
      say "${BLUE}Pool files are now protected${NC}" "log"
      say "Use 'POOL >> DECRYPT / UNLOCK' to unlock"
    fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    waitForInput

    ;; ###################################################################

  esac

  ;; ###################################################################

  blocks)
  
  clear
  say " >> BLOCKS" "log"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
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
  
  read -r -p "Enter epoch to list (enter for current): " epoch_enter
  [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch}
  
  blocks_file="${BLOCK_LOG_DIR}/blocks_${epoch_enter}.json"
  
  if [[ ! -f "${blocks_file}" ]]; then
    say "No blocks created in epoch ${epoch_enter}"
    waitForInput && continue
  fi
  
  block_count=$(jq -c '[.[]] | length' "${blocks_file}")
  [[ "${block_count}" =~ ^[0-9]+$ ]] || block_count=0
  
  say "\n${BLUE}${block_count}${NC} blocks created in epoch ${BLUE}${epoch_enter}${NC}" "log"
  
  if [[ ${block_count} -gt 0 ]]; then
    echo ""
    # print block table
    echo '[Slot,At,Size,Hash]' | cat - <(jq -c '.[] | [.slot,(.at|sub("\\.[0-9]+Z$"; "Z")|fromdate|strflocaltime("%Y-%m-%d %H:%M:%S %Z")),.size,.hash]' "${blocks_file}") | column -t -s'[],"'
  fi

  waitForInput

  ;; ###################################################################
  
  update) # not ready yet
  
  clear
  say " >> UPDATE" "log"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo ""

  URL="https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts"
  wget -q -O "${TMP_FOLDER}"/cntools.library "${URL}/cntools.library"
  GIT_MAJOR_VERSION=$(grep -r ^CNTOOLS_MAJOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
  GIT_MINOR_VERSION=$(grep -r ^CNTOOLS_MINOR_VERSION= "${TMP_FOLDER}"/cntools.library |sed -e "s#.*=##")
  if [ "$CNTOOLS_MAJOR_VERSION" != "$GIT_MAJOR_VERSION" ];then
    say "New major version available: ${GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}${NC} (Current: ${CNTOOLS_MAJOR_VERSION}.${CNTOOLS_MINOR_VERSION})\n"
    say "${RED}WARNING${NC}: Breaking changes were made to CNTools!\n"
    say "We will not overwrite your changes automatically."
    say "Please backup $CNODE_HOME/priv/wallet and $CNODE_HOME/priv/pool folders and then run the below:"
    say "  wget -O $CNODE_HOME/scripts/cntools.sh ${URL}/cntools.sh"
    say "  wget -O $CNODE_HOME/scripts/cntools.config ${URL}/cntools.config"
    say "  wget -O $CNODE_HOME/scripts/cntools.library ${URL}/cntools.library"
    say "  wget -O $CNODE_HOME/scripts/cntoolsBlockCollector.sh ${URL}/cntoolsBlockCollector.sh"
    say "  wget -O $CNODE_HOME/scripts/env ${URL}/env"
    say "  chmod 750 $CNODE_HOME/scripts/cntools.sh $CNODE_HOME/scripts/cntoolsBlockCollector.sh"
    say "  chmod 640 $CNODE_HOME/scripts/cntools.library $CNODE_HOME/scripts/env"
  elif [ "$CNTOOLS_MINOR_VERSION" != "$GIT_MINOR_VERSION" ];then
    say "New minor version available: ${GREEN}${GIT_MAJOR_VERSION}.${GIT_MINOR_VERSION}${NC} (Current: ${CNTOOLS_MAJOR_VERSION}.${CNTOOLS_MINOR_VERSION})\n"
    say "Applying minor version update (no changes required for operation)..."
    wget -q -O "$CNODE_HOME/scripts/cntools.sh" "$URL/cntools.sh"
    wget -q -O "$CNODE_HOME/scripts/cntools.library" "$URL/cntools.library"
    rc=$(wget -q -O "$CNODE_HOME/scripts/cntoolsBlockCollector.sh" "$URL/cntoolsBlockCollector.sh")
    if [[ $rc == 0 ]]; then
      say "Update applied successfully! Please start CNTools again !\n"
      chmod +x "$CNODE_HOME/scripts/cntools.sh" "$CNODE_HOME/scripts/cntoolsBlockCollector.sh"
      exit
    fi
  else
    say "${GREEN}Up to Date${NC}: You're using the latest version. No updates required!"
  fi
  waitForInput && continue

  if [ -f "${CCLI}" ]; then
    CURRENT_VERSION=$(${CCLI} --version | cut -f 2 -d " ")

    say "Currently installed: ${CURRENT_VERSION}" "log"
    say "Desired release:      ${DESIRED_RELEASE_CLEAN} (${DESIRED_RELEASE_PUBLISHED})" "log"
    if [ "${DESIRED_RELEASE_CLEAN}" != "${CURRENT_VERSION}" ]; then
      say "Would you like to upgrade to this release?\n"
      case $(select_opt "[y] Yes" "[n] No") in
        0) FILE="cardano-node-${DESIRED_RELEASE}-${ASSET_PLATTFORM}.tar.gz"
           URL="https://github.com/input-output-hk/cardano-node/releases/download/${DESIRED_RELEASE}/"${FILE}
           echo -e "\nDownload $FILE ..."
           curl --proto '=https' --tlsv1.2 -L -URL ${URL} -O ${CNODE_HOME}${FILE}
           tar -C ${CNODE_BIN_HOME} -xzf $FILE
           rm $FILE
           say "updated cardano-node from ${CURRENT_VERSION} to ${DESIRED_RELEASE_CLEAN}" "log"
           ;;
        1) say "upgrade canceled" ;;
      esac
    fi
  else #
    say "No cardano-cli binary found"
    say "Desired available release: ${DESIRED_RELEASE_CLEAN} (${DESIRED_RELEASE_PUBLISHED})" "log"
    say "Would you like to install this release?\n"
    case $(select_opt "[y] Yes" "[n] No") in
      0) FILE="cardano-node-${DESIRED_RELEASE}-${ASSET_PLATTFORM}.tar.gz"
         URL="https://github.com/input-output-hk/cardano-node/releases/download/${DESIRED_RELEASE}/"${FILE}
         echo -e "\nDownload $FILE ..."
         curl --proto '=https' --tlsv1.2 -L -URL ${URL} -O ${CNODE_HOME}${FILE}
         mkdir -p ${CNODE_BIN_HOME}
         tar -C ${CNODE_BIN_HOME} -xzf $FILE
         rm $FILE
         say "installed cardano-node ${DESIRED_RELEASE_CLEAN}" "log"
         ;;
      1) say "Well, that was a pleasant but brief pleasure. Bye bye!" ;;
    esac
  fi

  waitForInput

  ;; ###################################################################
  
esac # main OPERATION
done # main loop
}

##############################################################

main "$@"
