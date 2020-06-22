#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034
# ,SC2034,SC2143,SC2046,

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
  echo ""
  say "${RED}ERROR${NC}: Failed to create directory for temporary files:"
  say "${TMP_FOLDER}"
  echo ""
  exit 1
fi

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} --out-file ${TMP_FOLDER}/protparams.json || {
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

###################################################################

function main {

while true; do # Main loop

# Start with a clean slate after each completed or canceled command excluding protparams.json from purge
find "${TMP_FOLDER:?}" -type f -not -name 'protparams.json' -delete

clear
say " >> CNTOOLS <<                                       A Guild Operators collaboration" "log"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Main Menu"
echo ""
echo " ) Wallet  -  create, show, remove and protect wallets"
echo " ) Funds   -  send and delegate ADA"
echo " ) Pool    -  pool creation and management"
echo " ) Blocks  -  show core node block log if available"
echo " ) Update  -  install or upgrade latest available binary of Haskell Cardano"
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
  echo " ) New      -  create a new payment wallet or upgrade existing to a stake wallet"
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
    echo " Wallet Type"
    echo ""
    echo " ) Payment  -  First step for a new wallet"
    echo "               A payment wallet can send and receive funds but not delegate/pledge."
    echo ""
    echo " ) Stake    -  Upgrade existing payment wallet to a stake wallet"
    echo "               Make sure there are funds available in payment wallet before upgrade"
    echo "               as this is needed to pay for the stake wallet registration fee."
    echo "               A stake wallet is needed to be able to delegate and pledge to a pool."
    echo "               All funds from payment address will be moved to base address."
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    say " Choose wallet type\n"
    case $(select_opt "[p] Payment" "[s] Stake" "[h] Home") in
      0) wallet_type="payment" ;;
      1) wallet_type="stake" ;;
      2) continue ;;
    esac

    case $wallet_type in
      payment)

      clear
      say " >> WALLET >> NEW >> PAYMENT" "log"
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
      payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
      payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"

      if [[ -f "${payment_addr_file}" ]]; then
        say "${RED}WARN${NC}: A wallet ${GREEN}$wallet_name${NC} already exists"
        say "      Choose another name or delete the existing one"
        waitForInput && continue
      fi

      ${CCLI} shelley address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}"
      ${CCLI} shelley address build --payment-verification-key-file "${payment_vk_file}" --out-file "${payment_addr_file}" --testnet-magic ${NWMAGIC}

      say "New Wallet: ${GREEN}${wallet_name}${NC}" "log"
      say "Payment Address: $(cat ${payment_addr_file})" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      waitForInput

      ;; ###################################################################

      stake)

      clear
      say " >> WALLET >> NEW >> STAKE" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      
      if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
        say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
        waitForInput && continue
      fi
      
      wallet_dirs=()
      if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
      for dir in "${dirs[@]}"; do
        payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
        payment_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_VK_FILENAME}"
        payment_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_ADDR_FILENAME}"
        [[ ! -f "${payment_addr_file}" || ! -f "${payment_vk_file}" || ! -f "${payment_sk_file}" ]] && continue
        stake_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_ADDR_FILENAME}"
        [[ -f "${stake_addr_file}" ]] && continue # already a stake wallet
        getBalance "$(cat ${payment_addr_file})" >/dev/null
        [[ ${TOTALBALANCE} -eq 0 ]] && continue
        wallet_dirs+=("${dir} (${CYAN}$(numfmt --grouping ${totalBalanceADA})${NC} ADA)")
      done
      if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
        say "${ORANGE}WARN${NC}: No wallets available that can be upgraded!"
        say "first create a payment wallet and fund it"
        waitForInput && continue
      fi
      say "Select Wallet:\n"
      if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
      wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"

      # Wallet key filenames
      payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
      payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
      stake_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_ADDR_FILENAME}"
      stake_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_CERT_FILENAME}"
      base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"

      ${CCLI} shelley stake-address key-gen --verification-key-file "${stake_vk_file}" --signing-key-file "${stake_sk_file}"
      ${CCLI} shelley stake-address build --stake-verification-key-file "${stake_vk_file}" --out-file "${stake_addr_file}" --testnet-magic ${NWMAGIC}
      # upgrade the payment address to an address that delegates to the new stake address
      ${CCLI} shelley address build --payment-verification-key-file "${payment_vk_file}" --stake-verification-key-file "${stake_vk_file}" --out-file "${base_addr_file}" --testnet-magic ${NWMAGIC}

      ${CCLI} shelley stake-address registration-certificate --stake-verification-key-file "${stake_vk_file}" --out-file "${stake_cert_file}"

      payment_addr="$(cat ${payment_addr_file})"
      base_addr="$(cat ${base_addr_file})"

      # Register on chain
      if ! registerStakeWallet "${payment_addr}" "${base_addr}" "${payment_sk_file}" "${stake_sk_file}" "${stake_cert_file}"; then
        say "${RED}ERROR${NC}: failure during stake key registration, removing newly created stake keys"
        rm -f "${stake_vk_file}" "${stake_sk_file}" "${stake_addr_file}" "${stake_cert_file}" "${base_addr_file}"
        waitForInput && continue
      fi

      if ! waitNewBlockCreated; then
        waitForInput && continue
      fi

      getBalance "${payment_addr}" >/dev/null

      while [[ ${TOTALBALANCE} -ne 0 ]]; do
        say ""
        say "${ORANGE}WARN${NC}: Payment address balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != 0)"
        if ! waitNewBlockCreated; then
          break
        fi
        getBalance "${payment_addr}" >/dev/null
      done
      
      if [[ ${TOTALBALANCE} -ne 0 ]]; then
        # balance check aborted, return to main menu
        continue
      fi
      
      getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}" "no"

      say "New Stake Wallet : ${GREEN}${wallet_name}${NC}" "log"
      say "Payment Address  : ${payment_addr}" "log"
      say "Payment Balance  : ${CYAN}$(numfmt --grouping ${payment_ada})${NC} ADA" "log"
      say "Base Address     : ${base_addr}" "log"
      say "Base Balance     : ${CYAN}$(numfmt --grouping ${base_ada})${NC} ADA" "log"
      say "Reward Address   : $(cat ${stake_addr_file})" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      waitForInput

      ;; ###################################################################

    esac

    ;; ###################################################################

    list)
    
    clear
    say " >> WALLET >> LIST" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ ! -f "${TMP_FOLDER}"/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    ledger_state=$(timeout -k 3 4 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC})
    while IFS= read -r -d '' wallet; do
      getBalanceAllAddr "${wallet}" "yes"
      echo ""
      say "${GREEN}$(basename ${wallet})${NC}" "log"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
      if [[ -f "${base_addr_file}" ]]; then
        say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base" "$(numfmt --grouping ${base_ada})")" "log"
        if [[ "${reward_lovelace}" -eq -1 ]]; then
          say "${ORANGE}Not a registered stake wallet on chain${NC}"
          continue
        fi
        say "$(printf "%s\t${CYAN}%s${NC} ADA" "Reward" "$(numfmt --grouping ${reward_ada})")" "log"
        stake_addr=$(cat ${stake_addr_file})
        delegation_pool_id=$(jq -r -c '._delegationState._dstate._delegations[] // empty' <<< "${ledger_state}" | grep "${stake_addr:6}" | jq -r '.[1] // empty')
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
    
    waitForInput
    ;; ###################################################################

    show)
    
    clear
    say " >> WALLET >> SHOW" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    for dir in "${dirs[@]}"; do
      payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      payment_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_VK_FILENAME}"
      payment_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_ADDR_FILENAME}"
      [[ ! -f "${payment_addr_file}" || ! -f "${payment_vk_file}" || ! -f "${payment_sk_file}" ]] && continue
      wallet_dirs+=("${dir}")
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available!"
      say "first create a wallet"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="${dir_name}"

    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    say "$(printf "%-8s ${GREEN}%s${NC}" "Wallet" "${wallet_name}")" "log"
    echo ""

    getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}" "yes"

    if [[ -s ${TMP_FOLDER}/balance_payment.out ]]; then
      say "${BLUE}Payment UTxOs${NC}"
      head -n 2 ${TMP_FOLDER}/fullUtxo_payment.out
      head -n 10 ${TMP_FOLDER}/balance_payment.out
      echo -e "\n"
    fi
    if [[ -s ${TMP_FOLDER}/balance_base.out ]]; then
      say "${BLUE}Base UTxOs${NC}"
      head -n 2 ${TMP_FOLDER}/fullUtxo_base.out
      head -n 10 ${TMP_FOLDER}/balance_base.out
      echo -e "\n"
    fi
    
    say "$(printf "${BLUE}%-8s${NC} %-7s: %s" "Payment" "address" "${payment_addr}")" "log"
    say "$(printf "%-8s %-7s: ${CYAN}%s${NC} ADA" "" "amount" "$(numfmt --grouping ${payment_ada})")" "log"
    
    if [[ -f "${base_addr_file}" ]]; then
      say "$(printf "${BLUE}%-8s${NC} %-7s: %s" "Base" "address" "${base_addr}")" "log"
      say "$(printf "%-8s %-7s: ${CYAN}%s${NC} ADA" "" "amount" "$(numfmt --grouping ${base_ada})")" "log"
      if [[ "${reward_lovelace}" -eq -1 ]]; then
        say "${ORANGE}Not a registered stake wallet on chain${NC}"
      else
        say "$(printf "${BLUE}%-8s${NC} %-7s: %s" "Reward" "address" "${stake_addr}")" "log"
        say "$(printf "%-8s %-7s: ${CYAN}%s${NC} ADA" "" "amount" "$(numfmt --grouping ${reward_ada})")" "log"
        delegation_pool_id=$(${CCLI} shelley query stake-address-info --testnet-magic ${NWMAGIC} --address "$(cat ${stake_addr_file})" | jq -r '.[].delegation  // empty')
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
    fi
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput
    
    ;; ###################################################################

    remove) ## TODO - Check reward address
    
    clear
    say " >> WALLET >> REMOVE" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
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

    # Wallet key filename
    payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
    
    if [[ ! -f "${payment_addr_file}" && ! -f "${base_addr_file}" ]]; then
      say "${RED}WARN${NC}: no payment or base address files found in wallet"
      say "${payment_addr_file}"
      say "${base_addr_file}"
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
    
    getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}" "no"
    
    if [[ ${payment_lovelace} -eq 0 && ${base_lovelace} -eq 0 ]]; then
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
      if [[ ${payment_lovelace} -gt 0 ]]; then
        say "Payment address balance: ${BLUE}$(numfmt --grouping ${payment_ada})${NC} ADA"
      fi
      if [[ ${base_lovelace} -gt 0 ]]; then
        say "Base address balance: ${BLUE}$(numfmt --grouping ${base_ada})${NC} ADA"
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
      say "Use 'WALLET >> ENCRYPT / LOCK' to re-lock"
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
    
    say " -- Encrypting sensitive pool keys with GPG --" "log"
    echo ""
    say "Pool ${GREEN}${wallet_name}${NC} Password"
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
    say " -- Write protecting all pool files using 'chattr +i' --" "log"
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
      say "Use 'WALLET >> DECRYPT / UNLOCK' to unlock"
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

    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      base_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_BASE_ADDR_FILENAME}"
      stake_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_ADDR_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${base_addr_file}" || ! -f "${stake_addr_file}" || ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        reward_lovelace=$(${CCLI} shelley query stake-address-info --testnet-magic ${NWMAGIC} --address $(cat "${stake_addr_file}") | jq -r '.[].rewardAccountBalance // empty')
        [[ "${reward_lovelace}" =~ ^[0-9]+$ ]] || reward_lovelace=0
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
      
    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
    stake_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_ADDR_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    
    getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}" "yes"

    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(numfmt --grouping ${reward_ada})")" "log"
    
    if [[ ${reward_lovelace} -le 0 ]]; then
      echo "Failed to locate any rewards associated with the chosen wallet, please try another one"
      waitForInput && continue
    fi

    if ! withdrawRewards "${stake_vk_file}" "${stake_sk_file}" "${pay_payment_sk_file}" "$(cat ${base_addr_file})" "$(cat ${stake_addr_file})" ${reward_lovelace}; then
      echo "" && say "${RED}ERROR${NC}: failure during withdrawal of rewards"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi
    
    getBalance "$(cat ${base_addr_file})" >/dev/null

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      echo ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance "$(cat ${base_addr_file})" >/dev/null
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    say ""
    say "--- Balance Check -------------------------------------------------------"
    getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}" "yes"

    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(numfmt --grouping ${reward_ada})")" "log"
    waitForInput
    
    ;; ###################################################################

    send)
    
    clear
    say " >> FUNDS >> SEND" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    say " -- Source Wallet --"
    echo ""
    s_wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      s_payment_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_ADDR_FILENAME}"
      s_base_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_BASE_ADDR_FILENAME}"
      [[ ! -f "${s_payment_addr_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalanceAllAddr "${WALLET_FOLDER}/${dir}" "no"
        [[ ${payment_lovelace} -eq 0 && ${base_lovelace} -eq 0 ]] && continue
        s_wallet_dirs+=("${dir} (Payment: ${CYAN}$(numfmt --grouping ${payment_ada})${NC} ADA - Base: ${CYAN}$(numfmt --grouping ${base_ada})${NC} ADA)")
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
    
    s_payment_addr_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_ADDR_FILENAME}"
    s_base_addr_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_BASE_ADDR_FILENAME}"
    
    getBalanceAllAddr "${WALLET_FOLDER}/${s_wallet}" "no"
    
    if [[ ${payment_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      say "Both payment and base address available with funds, choose address"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
      echo ""
      case $(select_opt "[p] Payment" "[b] Base" "[c] Cancel") in
        0) s_addr_file="${s_payment_addr_file}"
           totalAmountLovelace=${payment_lovelace}
           totalAmountADA=${payment_ada}
           ;;
        1) s_addr_file="${s_base_addr_file}" 
           totalAmountLovelace=${base_lovelace}
           totalAmountADA=${base_ada}
           ;;
        2) continue ;;
      esac
    elif [[ ${payment_lovelace} -gt 0 ]]; then
      s_addr_file="${s_payment_addr_file}"
      totalAmountLovelace=${payment_lovelace}
      totalAmountADA=${payment_ada}
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
    elif [[ ${base_lovelace} -gt 0 ]]; then
      s_addr_file="${s_base_addr_file}"
      totalAmountLovelace=${base_lovelace}
      totalAmountADA=${base_ada}
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available in either payment or base address for wallet ${GREEN}${s_wallet}${NC}"
      waitForInput && continue
    fi
    s_addr="$(cat ${s_addr_file})"

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
      amountADA=${totalAmountADA}
      amountLovelace=${totalAmountLovelace}
      say "ADA to send set to total supply: $(numfmt --grouping ${amountADA})" "log"
      echo ""
      include_fee="yes"
    fi
    
    # Destination
    say " -- Destination Address / Wallet --"
    echo ""
    d_addr_file=""
    say "Is destination a local wallet or an address?\n"
    case $(select_opt "[w] Wallet" "[a] Address" "[c] Cancel") in
      0) d_wallet_dirs=()
         if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
         for dir in "${dirs[@]}"; do
           d_payment_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_ADDR_FILENAME}"
           d_base_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_BASE_ADDR_FILENAME}"
           [[ ! -f ${d_payment_addr_file} && ! -f ${d_base_addr_file} ]] && continue
           d_wallet_dirs+=("${dir}")
         done
         say "Select Destination Wallet:\n"
         if ! selectDir "${d_wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
         d_wallet="${dir_name}"

         d_payment_addr_file="${WALLET_FOLDER}/${d_wallet}/${WALLET_PAY_ADDR_FILENAME}"
         d_base_addr_file="${WALLET_FOLDER}/${d_wallet}/${WALLET_BASE_ADDR_FILENAME}"
    
         if [[ -f "${d_payment_addr_file}" && -f "${d_base_addr_file}" ]]; then
           # Both payment and base address available, let user choose what to use
           say "Both payment and base address available, choose address\n"
           case $(select_opt "[p] Payment" "[b] Base" "[c] Cancel") in
             0) d_addr_file="${d_payment_addr_file}" ;;
             1) d_addr_file="${d_base_addr_file}" ;;
             2) continue ;;
           esac
         elif [[ -f "${d_payment_addr_file}" ]]; then
           d_addr_file="${d_payment_addr_file}"
         elif [[ -f "${d_base_addr_file}" ]]; then
           d_addr_file="${d_base_addr_file}"
         else
           say "${RED}ERROR${NC}: no payment or base address file found for wallet ${GREEN}${d_wallet}${NC}"
           say "${d_payment_addr_file}"
           say "${d_base_addr_file}"
           waitForInput && continue
         fi
         d_addr="$(cat ${d_addr_file})"
         ;;
      1) echo "" && read -r -p "Address: " d_addr ;;
      2) continue ;;
    esac
    # Destination could be empty, if so  without getting a valid address
    if [[ -z ${d_addr} ]]; then
      say "${RED}ERROR${NC}: destination address field empty"
      waitForInput && continue
    fi

    # Source Sign Key
    # decrypt signing key if needed and make sure to encrypt again even on failure
    s_payment_sk_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_SK_FILENAME}"
    if [[ ! -f "${s_payment_sk_file}" ]]; then
      say "${RED}ERROR${NC}: source wallet signing key file not found:"
      say "${s_payment_sk_file}"
      waitForInput && continue
    fi

    if ! sendADA "${d_addr}" "${amountLovelace}" "${s_addr}" "${s_payment_sk_file}" "${include_fee}"; then
      waitForInput && continue
    fi
    
    echo ""

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance ${s_addr} >/dev/null

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance ${s_addr} >/dev/null
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then 
      waitForInput && continue
    fi

    s_balance_ada=${totalBalanceADA}

    getBalance ${d_addr} >/dev/null

    d_balance_ada=${totalBalanceADA}

    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say "Transaction" "log"
    [[ "${s_addr_file}" = "${s_payment_addr_file}" ]] && s_wallet_type="payment" || s_wallet_type="base"
    say "  From          : ${GREEN}${s_wallet}${NC} (${s_wallet_type})" "log"
    say "  Amount        : $(numfmt --grouping ${amountADA}) ADA" "log"
    if [[ "${d_addr_file}" = "${d_payment_addr_file}" ]]; then
      say "  To            : ${GREEN}${d_wallet}${NC} (payment)" "log"
    elif [[ "${d_addr_file}" = "${d_base_addr_file}" ]]; then
      say "  To            : ${GREEN}${d_wallet}${NC} (base)" "log"
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
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
      ledger_state=$(timeout -k 3 4 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC})
    fi
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      base_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_BASE_ADDR_FILENAME}"
      stake_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_ADDR_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${base_addr_file}" || ! -f "${stake_addr_file}" || ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance "$(cat ${base_addr_file})" >/dev/null
        stake_addr=$(cat ${stake_addr_file})
        delegation_pool_id=$(jq -r -c '._delegationState._dstate._delegations[] // empty' <<< "${ledger_state}" | grep "${stake_addr:6}" | jq -r '.[1] // empty')
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
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC} - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
        elif [[ -n ${delegation_pool_id} ]]; then
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC} - ${RED}delegated${NC} to external address)")
        else
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC})")
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
    
    getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}" "yes"

    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
    say "$(printf "%s\t${CYAN}%s${NC} ADA" "Rewards"  "$(numfmt --grouping ${reward_ada})")" "log"
    echo ""
    
    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
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
         pool_coldkey_vk_file="${TMP_FOLDER}/pool_delegation.vkey"
         echo "type: Node operator verification key" > "${pool_coldkey_vk_file}"
         echo "title: Stake pool operator key" >> "${pool_coldkey_vk_file}"
         echo "cbor-hex:" >> "${pool_coldkey_vk_file}"
         echo " ${vkey_cbor}" >> "${pool_coldkey_vk_file}"
         ;;
      2) continue ;;
    esac

    #Generated Files
    delegation_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"

    say "-- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${delegation_cert_file}"

    #[stake vkey] [stake skey] [pay skey] [pay addr] [pool vkey] [deleg cert]
    if ! delegate "${stake_vk_file}" "${stake_sk_file}" "${pay_payment_sk_file}" "$(cat ${base_addr_file})" "${pool_coldkey_vk_file}" "${delegation_cert_file}" ; then
      echo "" && say "${RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
      rm -f "${delegation_cert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance "$(cat ${base_addr_file})" >/dev/null

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      echo ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance "$(cat ${base_addr_file})" >/dev/null
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    say "Delegation successfully registered"
    say "Wallet : ${GREEN}${wallet_name}${NC}"
    say "Pool   : ${GREEN}${pool_name}${NC}" "log"
    say "Amount : $(numfmt --grouping ${totalBalanceADA}) ADA" "log"
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
    currSlot=$(getTip slot)
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
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    pool_dirs=()
    ledger_state=$(timeout -k 3 4 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC})
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_id=$(cat "${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '._delegationState._pstate._pParams."'"${pool_id}"'" // empty' <<< "${ledger_state}")
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
    echo "" && read -r -p "Margin (in %, default: ${margin}): " margin_enter
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
    echo "" && read -r -p "Cost (in ADA, default: ${cost_ada}): " cost_enter
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    
    echo ""

    wallet_dirs=()
    if ! getDirs "${WALLET_FOLDER}"; then continue; fi # dirs() array populated with all wallet folders
    wallet_count=${#dirs[@]}
    for dir in "${dirs[@]}"; do
      base_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_BASE_ADDR_FILENAME}"
      stake_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_ADDR_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${base_addr_file}" || ! -f "${stake_addr_file}" || ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance "$(cat ${base_addr_file})" >/dev/null
        stake_addr=$(cat ${stake_addr_file})
        delegation_pool_id=$(jq -r -c '._delegationState._dstate._delegations[] // empty' <<< "${ledger_state}" | grep "${stake_addr:6}" | jq -r '.[1] // empty')
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
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC} - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
        elif [[ -n ${delegation_pool_id} ]]; then
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC} - ${RED}delegated${NC} to external address)")
        else
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC})")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be used in pool registration as pledge wallet!"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"
    
    # Save pool config
    echo "{\"pledgeWallet\":\"$wallet_name\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada}" > "${pool_config}"

    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"

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

    say "-- creating registration cert --" "log"
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${stake_vk_file}" --pool-owner-stake-verification-key-file "${stake_vk_file}" --out-file "${pool_regcert_file}" --testnet-magic ${NWMAGIC}
    say "-- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${pool_pledgecert_file}"
    say "-- Sending transaction to chain --" "log"

    if ! registerPool "$(cat ${base_addr_file})" "${pool_coldkey_sk_file}" "${stake_sk_file}" "${pool_regcert_file}" "${pool_pledgecert_file}" "${pay_payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool registration, removing newly created pledge and registration files"
      rm -f "${pool_regcert_file}" "${pool_pledgecert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance "$(cat ${base_addr_file})" >/dev/null

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance "$(cat ${base_addr_file})" >/dev/null
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi

    echo ""
    say "Pool ${GREEN}${pool_name}${NC} successfully registered using wallet ${GREEN}${wallet_name}${NC} for pledge" "log"
    say "Pledge : $(numfmt --grouping ${pledge_ada}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(numfmt --grouping ${cost_ada}) ADA" "log"
    if [[ ${TOTALBALANCE} -lt ${pledge_lovelace} ]]; then
      echo ""
      say "${ORANGE}WARN${NC}: Balance in pledge wallet base address is less than set pool pledge"
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
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    pool_dirs=()
    ledger_state=$(timeout -k 3 4 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC})
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_id=$(cat "${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '._delegationState._pstate._pParams."'"${pool_id}"'" // empty' <<< "${ledger_state}")
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
      base_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_BASE_ADDR_FILENAME}"
      stake_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_ADDR_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_SK_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${dir}/${WALLET_STAKE_VK_FILENAME}"
      pay_payment_sk_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_SK_FILENAME}"
      [[ ! -f "${base_addr_file}" || ! -f "${stake_addr_file}" || ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]] && continue
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalance "$(cat ${base_addr_file})" >/dev/null
        stake_addr=$(cat ${stake_addr_file})
        delegation_pool_id=$(jq -r -c '._delegationState._dstate._delegations[] // empty' <<< "${ledger_state}" | grep "${stake_addr:6}" | jq -r '.[1] // empty')
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
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC} - ${RED}delegated${NC} to ${BLUE}${poolName}${NC})")
        elif [[ -n ${delegation_pool_id} ]]; then
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC} - ${RED}delegated${NC} to external address)")
        else
          wallet_dirs+=("${dir} (Base: ${CYAN}${totalBalanceADA}${NC})")
        fi
      else
        wallet_dirs+=("${dir}")
      fi
    done
    if [[ ${#wallet_dirs[@]} -eq 0 ]]; then
      say "${ORANGE}WARN${NC}: No wallets available that can be used in pool registration as pledge wallet!"
      waitForInput && continue
    fi
    say "Select Wallet:\n"
    if ! selectDir "${wallet_dirs[@]}"; then continue; fi # ${dir_name} populated by selectDir function
    wallet_name="$(echo ${dir_name} | cut -d' ' -f1)"
    
    say "Enter new pool parameters, press enter to use old value"
    echo ""
    
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
    echo "" && read -r -p "New Margin (in %, old: ${margin}): " margin_enter
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
    echo "" && read -r -p "New Cost (in ADA, old: ${cost_ada}): " cost_enter
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}" >/dev/null; then
        waitForInput && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    
    echo ""

    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"

    if [[ ! -f "${base_addr_file}" || ! -f "${pay_payment_sk_file}" || ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" ]]; then
      say "${RED}ERROR${NC}: ${GREEN}${wallet_name}${NC} wallet files missing, expecting these files to be available:"
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

    say "-- creating registration cert --" "log"
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${stake_vk_file}" --pool-owner-stake-verification-key-file "${stake_vk_file}" --out-file "${pool_regcert_file}" --testnet-magic ${NWMAGIC}
    say "-- Sending transaction to chain --" "log"

    if ! modifyPool "$(cat ${base_addr_file})" "${pool_coldkey_sk_file}" "${stake_sk_file}" "${pool_regcert_file}" "${pay_payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool update, removing newly created registration certificate"
      rm -f "${pool_regcert_file}"
      waitForInput && continue
    fi

    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance "$(cat ${base_addr_file})" >/dev/null

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance "$(cat ${base_addr_file})" >/dev/null
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
      waitForInput && continue
    fi
    
    # Update pool config
    echo "{\"pledgeWallet\":\"$pledge_wallet\",\"pledgeADA\":$pledge_ada,\"margin\":$margin,\"costADA\":$cost_ada}" > "${pool_config}"

    echo ""
    say "Pool ${GREEN}${pool_name}${NC} successfully updated with new parameters using wallet ${GREEN}${wallet_name}${NC} to pay for registration fee" "log"
    say "Pledge : $(numfmt --grouping ${pledge_ada}) ADA" "log"
    say "Margin : ${margin}%" "log"
    say "Cost   : $(numfmt --grouping ${cost_ada}) ADA" "log"
    if [[ ${TOTALBALANCE} -lt ${pledge_lovelace} ]]; then
      echo ""
      say "${ORANGE}WARN${NC}: Balance in pledge wallet base address is less than set pool pledge"
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
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    pool_dirs=()
    ledger_state=$(timeout -k 3 4 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC})
    if ! getDirs "${POOL_FOLDER}"; then continue; fi # dirs() array populated with all pool folders
    for dir in "${dirs[@]}"; do
      pool_coldkey_vk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_VK_FILENAME}"
      pool_coldkey_sk_file="${POOL_FOLDER}/${dir}/${POOL_COLDKEY_SK_FILENAME}"
      pool_vrf_vk_file="${POOL_FOLDER}/${dir}/${POOL_VRF_VK_FILENAME}"
      [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_vrf_vk_file}" ]] && continue
      pool_id=$(cat "${POOL_FOLDER}/${dir}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '._delegationState._pstate._pParams."'"${pool_id}"'" // empty' <<< "${ledger_state}")
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
      payment_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_PAY_ADDR_FILENAME}"
      base_addr_file="${WALLET_FOLDER}/${dir}/${WALLET_BASE_ADDR_FILENAME}"
      if [[ ${wallet_count} -le ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
        getBalanceAllAddr "${WALLET_FOLDER}/${dir}" "no"
        [[ ${payment_lovelace} -eq 0 && ${base_lovelace} -eq 0 ]] && continue
        wallet_dirs+=("${dir} (Payment: ${CYAN}$(numfmt --grouping ${payment_ada})${NC} ADA - Base: ${CYAN}$(numfmt --grouping ${base_ada})${NC} ADA)")
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
    
    payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
    
    getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}" "no"
    
    if [[ ${payment_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      say "Both payment and base address available with funds, choose address"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
      echo ""
      case $(select_opt "[p] Payment" "[b] Base" "[c] Cancel") in
        0) addr_file="${payment_addr_file}" ;;
        1) addr_file="${base_addr_file}" ;;
        2) continue ;;
      esac
    elif [[ ${payment_lovelace} -gt 0 ]]; then
      addr_file="${payment_addr_file}"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
    elif [[ ${base_lovelace} -gt 0 ]]; then
      addr_file="${base_addr_file}"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available in either payment or base address for wallet ${GREEN}${wallet_name}${NC}"
      waitForInput && continue
    fi
    addr="$(cat ${addr_file})"
    echo ""
    
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
    
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    
    say "-- creating de-registration cert --" "log"
    ${CCLI} shelley stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}
    
    if ! deRegisterPool "${pool_coldkey_sk_file}" "${pool_deregcert_file}" "${addr}" "${payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool de-registration"
      waitForInput && continue
    fi
    
    if ! waitNewBlockCreated; then
      waitForInput && continue
    fi

    getBalance "${addr}" >/dev/null

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      getBalance "${addr}" >/dev/null
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
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
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      waitForInput && continue
    fi
    
    ledger_state=$(timeout -k 3 4 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC})
    
    while IFS= read -r -d '' pool; do 
      echo ""
      pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
      ledger_pool_state=$(jq -r '._delegationState._pstate._pParams."'"${pool_id}"'" // empty' <<< "${ledger_state}")
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
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    waitForInput
    
    ;; ###################################################################

    show)
    
    clear
    say " >> POOL >> SHOW" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
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
    
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    ledger_state=$(timeout -k 3 4 ${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC})
    pool_id=$(cat "${POOL_FOLDER}/${pool_name}/${POOL_ID_FILENAME}")
    ledger_pool_state=$(jq -r '._delegationState._pstate._pParams."'"${pool_id}"'" // empty' <<< "${ledger_state}")
    [[ -n "${ledger_pool_state}" ]] && pool_registered="YES" || pool_registered="NO"
    say "${GREEN}${pool_name}${NC} "
    say "$(printf "%-21s : %s" "ID" "${pool_id}")" "log"
    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    if [[ -f "${pool_config}" ]]; then
      say "$(printf "%-21s : %s ADA" "Pledge" "$(numfmt --grouping "$(jq -r .pledgeADA "${pool_config}")")")" "log"
      say "$(printf "%-21s : %s %%" "Margin" "$(numfmt --grouping "$(jq -r .margin "${pool_config}")")")" "log"
      say "$(printf "%-21s : %s ADA" "Cost" "$(numfmt --grouping "$(jq -r .costADA "${pool_config}")")")" "log"
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
      done < <(jq -c -r '._poolOwners[] // empty' <<< "${ledger_pool_state}")
      reward_account=$(jq -r '._poolRAcnt.getRwdCred.contents' <<< "${ledger_pool_state}")
      if [[ -n ${reward_account} ]]; then
        reward_wallet=$(grep -r ${reward_account} "${WALLET_FOLDER}" | head -1 | cut -d':' -f1)
        reward_wallet="$(basename "$(dirname "${reward_wallet}")")"
        if [[ -n ${reward_wallet} ]]; then
          say "$(printf "%-21s : %s" "Reward wallet" "${GREEN}${reward_wallet}${NC}")" "log"
        else
          say "$(printf "%-21s : %s" "Reward account" "${reward_account}")" "log"
        fi
      fi
      # delegator count
      delegator_count=$(jq -r '[._delegationState._dstate._delegations[] | select(.[] == "'"${pool_id}"'")] | length' <<< "${ledger_state}")
      say "$(printf "%-21s : %s" "Delegators" "${delegator_count}")" "log"
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
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    waitForInput
    
    ;; ###################################################################
    
    rotate)

    clear
    say " >> POOL >> ROTATE KES" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
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
    currSlot=$(getTip slot)
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
  
  update) # not ready yet. ToDo when binary releases become available
  
  clear
  say " >> UPDATE" "log"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo ""
  say "${RED}ERROR${NC}: Sorry! not ready yet in cntools"
  waitForInput && continue

  if [ ${#} -lt 2 ]; then
    DESIRED_RELEASE_JSON=$(curl --proto '=https' --tlsv1.2 -sSf https://api.github.com/repos/input-output-hk/cardano-node/releases/latest)
  else
    DESIRED_RELEASE_JSON=$(curl --proto '=https' --tlsv1.2 -sSf https://api.github.com/repos/input-output-hk/cardano-node/releases/tags/${2})
  fi
  DESIRED_RELEASE=$(echo $DESIRED_RELEASE_JSON | jq -r .tag_name)
  DESIRED_RELEASE_PUBLISHED=$(echo $DESIRED_RELEASE_JSON | jq -r .published_at)
  DESIRED_RELEASE_CLEAN=$(echo ${DESIRED_RELEASE} | cut -c2-)

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
