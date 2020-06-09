#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034
# ,SC2034,SC2143,SC2046,
# Creators: gufmar, Scitz0, Papacarp
# 2020-05-19 cntools initial release (concept)
# 2020-05-24 helper functions moved cnlibrary & configuration to env file

########## Global tasks ###########################################

# get common env variables
. "$(dirname $0)"/env

# get cntools config parameters
. "$(dirname $0)"/cntools.config

# get helper functions from library file
. "$(dirname $0)"/cntools.library

# Start with a clean slate
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  echo ""
  say "${RED}ERROR${NC}: Failed to create directory for temporary files:"
  say "${TMP_FOLDER}"
  echo ""
  exit 1
fi
rm -f "${TMP_FOLDER:?}"/*

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

clear
echo " >> CNTOOLS <<                                       A Guild Operators collaboration"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Main Menu"
echo ""
echo " ) Update  -  install or upgrade latest available binary of Haskell Cardano"
echo " ) Wallet  -  create, show, remove and protect wallets"
echo " ) Funds   -  send and delegate ADA"
echo " ) Pool    -  pool creation and management"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

say " What would you like to do?"
case $(select_opt "Update" "Wallet" "Funds" "Pool" "Quit") in
  0) OPERATION="update" ;;
  1) OPERATION="wallet" ;;
  2) OPERATION="funds" ;;
  3) OPERATION="pool" ;;
  4) clear && exit ;;
esac

case $OPERATION in
  update) # not ready yet. ToDo when binary releases become available
  
  clear
  echo " >> UPDATE"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo ""
  say "${RED}ERROR${NC}: Sorry! not ready yet in cntools"
  echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue

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
      say "Would you like to upgrade to this release?"
      case $(select_opt "Yes" "No") in
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
    say "Would you like to install this release?"
    case $(select_opt "Yes" "No") in
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

  echo "" && read -r -n 1 -s -p "press any key to return to home menu"

  ;; ###################################################################

  wallet)

  clear
  echo " >> WALLET"
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
  
  say " Select wallet operation"
  case $(select_opt "New" "List" "Show" "Remove" "Decrypt" "Encrypt" "<- Home") in
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
    echo " >> WALLET >> NEW"
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
    
    say " Choose wallet type"
    case $(select_opt "Payment" "Stake" "<- Home") in
      0) wallet_type="payment" ;;
      1) wallet_type="stake" ;;
      2) continue ;;
    esac

    case $wallet_type in
      payment)

      clear
      echo " >> WALLET >> NEW >> PAYMENT"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      read -r -p "Name of new wallet: " wallet_name
      # Remove unwanted characters from wallet name
      wallet_name=${wallet_name//[^[:alnum:]]/_}
      if [[ -z "${wallet_name}" ]]; then
        say "${RED}ERROR${NC}: Empty wallet name, please retry!"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi

      ${CCLI} shelley address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}"
      ${CCLI} shelley address build --payment-verification-key-file "${payment_vk_file}" --out-file "${payment_addr_file}" --testnet-magic ${NWMAGIC}

      say "New Wallet: ${GREEN}${wallet_name}${NC}" "log"
      say "Payment Address: $(cat ${payment_addr_file})" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu"

      ;; ###################################################################

      stake)

      clear
      echo " >> WALLET >> NEW >> STAKE"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      
      if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
        say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
      
      if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function

      # Wallet key filenames
      payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
      payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
      stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
      stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
      stake_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_ADDR_FILENAME}"
      stake_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_CERT_FILENAME}"
      base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"


      if [[ ! -f "${payment_addr_file}" || ! -f "${payment_vk_file}" || ! -f "${payment_sk_file}" ]]; then
        say "${RED}WARN${NC}: Payment wallet files missing or misconfiguration for wallet filenames: ${GREEN}$wallet_name${NC}"
        say "Expect the following files to exist:"
        say "${payment_addr_file}"
        say "${payment_vk_file}"
        say "${payment_sk_file}"
        say "      A payment wallet with funds available needed to upgrade to stake wallet"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      elif [[ -f "${stake_addr_file}" ]]; then
        say "${RED}WARN${NC}: A stake wallet ${GREEN}$wallet_name${NC} already exists"
        say "      Choose another name or delete the existing one"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi

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
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi

      if ! waitNewBlockCreated; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi

      say ""
      say "--- Balance Check Source Address -------------------------------------------------------" "log"
      getBalance "${payment_addr}"

      while [[ ${TOTALBALANCE} -ne 0 ]]; do
        say ""
        say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != 0"
        if ! waitNewBlockCreated; then
          break
        fi
        say ""
        say "--- Balance Check Source Address -------------------------------------------------------"
        getBalance "${payment_addr}"
      done
      
      if [[ ${TOTALBALANCE} -ne 0 ]]; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi

      say "New Stake Wallet: ${GREEN}${wallet_name}${NC}" "log"
      say "Payment Address: ${payment_addr}" "log"
      say "Reward Address:  $(cat ${stake_addr_file})" "log"
      say "Base Address:    ${base_addr}" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu"

      ;; ###################################################################

    esac

    ;; ###################################################################

    list)
    
    clear
    echo " >> WALLET >> LIST"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    while IFS= read -r -d '' wallet; do
      getBalanceAllAddr "${wallet}"
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
        delegation_pool_id=$(grep -oP ',KeyHash \K\w+' <<< "${stake_address_info}") # stake_address_info populated in getBalanceAllAddr()
        if [[ -n ${delegation_pool_id} ]]; then
          unset poolName
          while IFS= read -r -d '' pool; do
            pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
            if [[ "${pool_id}" = "${delegation_pool_id}" ]]; then
              poolName=$(basename ${pool})
            fi
          done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          say "${RED}Delegated to${NC} ${BLUE}${poolName}${NC} ${RED}(${delegation_pool_id})${NC}" "log"
        fi
      fi
    done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    read -r -n 1 -s -p "press any key to return to home menu"
    ;; ###################################################################

    show)
    
    clear
    echo " >> WALLET >> SHOW"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function

    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    say "$(printf "%-8s ${GREEN}%s${NC}" "Wallet" "${wallet_name}")" "log"
    echo ""

    getBalanceAllAddr "${WALLET_FOLDER}/${wallet_name}"

    say "$(printf "${BLUE}%-8s${NC} %-7s: %s" "Payment" "address" "${payment_addr}")" "log"
    say "$(printf "%-8s %-7s: ${CYAN}%s${NC} ADA" "" "amount" "$(numfmt --grouping ${payment_ada})")" "log"
    if [[ -s ${TMP_FOLDER}/balance_payment.out ]]; then
      echo ""
      head -n 2 ${TMP_FOLDER}/fullUtxo_payment.out
      head -n 10 ${TMP_FOLDER}/balance_payment.out
      echo ""
    fi
    
    if [[ -f "${base_addr_file}" ]]; then
      echo ""
      say "$(printf "${BLUE}%-8s${NC} %-7s: %s" "Base" "address" "${base_addr}")" "log"
      say "$(printf "%-8s %-7s: ${CYAN}%s${NC} ADA" "" "amount" "$(numfmt --grouping ${base_ada})")" "log"
      if [[ -s ${TMP_FOLDER}/balance_base.out ]]; then
        echo ""
        head -n 2 ${TMP_FOLDER}/fullUtxo_base.out
        head -n 10 ${TMP_FOLDER}/balance_base.out
        echo ""
      fi
      
      if [[ "${reward_lovelace}" -eq -1 ]]; then
        say "${ORANGE}Not a registered stake wallet on chain${NC}"
      else
        echo ""
        say "$(printf "${BLUE}%-8s${NC} %-7s: %s" "Reward" "address" "${base_addr}")" "log"
        say "$(printf "%-8s %-7s: ${CYAN}%s${NC} ADA" "" "amount" "$(numfmt --grouping ${reward_ada})")" "log"
        delegation_pool_id=$(grep -oP ',KeyHash \K\w+' <<< "${stake_address_info}") # stake_address_info populated in getBalanceAllAddr()
        if [[ -n ${delegation_pool_id} ]]; then
          unset poolName
          while IFS= read -r -d '' pool; do
            pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
            if [[ "${pool_id}" = "${delegation_pool_id}" ]]; then
              poolName=$(basename ${pool})
            fi
          done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
          echo ""
          say "${RED}Delegated to${NC} ${BLUE}${poolName}${NC} ${RED}(${delegation_pool_id})${NC}" "log"
        fi
      fi
    fi
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "" && read -r -n 1 -s -p "press any key to return to home menu"
    
    ;; ###################################################################

    remove) ## TODO - Check reward address
    
    clear
    echo " >> WALLET >> REMOVE"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function

    # Wallet key filename
    payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
    
    if [[ ! -f "${payment_addr_file}" && ! -f "${base_addr_file}" ]]; then
      say "${RED}WARN${NC}: no payment or base address files found in wallet"
      say "${payment_addr_file}"
      say "${base_addr_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu"
    fi
    if [[ -f "${payment_addr_file}" ]]; then
      getBalance "$(cat ${payment_addr_file})" >/dev/null
      payment_balance=${TOTALBALANCE}
      payment_balance_ada=${totalBalanceADA}
    fi
    if [[ -f "${base_addr_file}" ]]; then
      getBalance "$(cat ${base_addr_file})" >/dev/null
      base_balance=${TOTALBALANCE}
      base_balance_ada=${totalBalanceADA}
    fi
    
    if [[ ${payment_balance} -eq 0 && ${base_balance} -eq 0 ]]; then
      say "INFO: This wallet appears to be empty"
      say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup"
      say ""
      say "Are you sure to delete wallet? "
      case $(select_opt "Yes" "No") in
        0) rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
           echo "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
           ;;
        1) say "skipped removal process for ${GREEN}$wallet_name${NC}"
           ;;
      esac
    else
      say "${RED}WARN${NC}: wallet not empty!"
      if [[ $(bc <<< "${payment_balance_ada} > 0" ) -eq 1 ]]; then
        say "Payment address balance: ${BLUE}$(numfmt --grouping ${payment_balance_ada})${NC} ADA"
      fi
      if [[ $(bc <<< "${base_balance_ada} > 0" ) -eq 1 ]]; then
        say "Base address balance: ${BLUE}$(numfmt --grouping ${base_balance_ada})${NC} ADA"
      fi
      echo ""
      say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup"
      say "Are you sure to delete wallet? "
      case $(select_opt "Yes" "No") in
        0) rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
           echo "" && say "removed ${GREEN}${wallet_name}${NC}" "log"
           ;;
        1) say "skipped removal process for ${GREEN}$wallet_name${NC}"
           ;;
      esac
    fi

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    decrypt)
    
    clear
    echo " >> WALLET >> DECRYPT"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    protectionPreRequisites || continue
    
    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function
    
    filesUnlocked=0
    keysDecrypted=0
    
    say " -- Removing write protection from all wallet files --" "log"
    while IFS= read -r -d '' file; do 
      if [[ $(lsattr -R "$file" 2>/dev/null | grep -c -P "(?<=-)i(?=-)") -ne 0 ]]; then
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
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    encrypt)
    
    clear
    echo " >> WALLET >> ENCRYPT"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    protectionPreRequisites || continue
    
    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function

    filesLocked=0
    keysEncrypted=0
    
    say " -- Encrypting sensitive pool keys with GPG --" "log"
    echo ""
    say "Pool ${GREEN}${wallet_name}${NC} Password"
    echo ""
    if ! getPassword confirm; then # $password variable populated by getPassword function
      echo -e "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      if [[ $(lsattr -R "$file" 2>/dev/null | grep -c -P "(?<=-)i(?=-)") -eq 0 ]]; then
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

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

  esac

  ;; ###################################################################

  funds)

  clear
  echo " >> FUNDS"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo " Handle Funds"
  echo ""
  echo " 1) Send      -  send ADA from a local wallet to an address or a wallet"
  echo " 2) Delegate  -  delegate stake wallet to a pool"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
  say " Select funds operation"
  case $(select_opt "Send" "Delegate" "<- Home") in
    0) SUBCOMMAND="send" ;;
    1) SUBCOMMAND="delegate" ;;
    2) continue ;;
  esac

  case $SUBCOMMAND in
    send)
    
    clear
    echo " >> FUNDS >> SEND"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    say " -- Source Wallet --"
    echo ""
    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function
    s_wallet="${wallet_name}"
    
    s_payment_addr_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_ADDR_FILENAME}"
    s_base_addr_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_BASE_ADDR_FILENAME}"
    
    getBalanceAllAddr "${WALLET_FOLDER}/${s_wallet}"
    
    if [[ ${payment_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
      # Both payment and base address available with funds, let user choose what to use
      say "Both payment and base address available with funds, choose address"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
      echo ""
      case $(select_opt "Payment" "Base" "Cancel") in
        0) s_addr_file="${s_payment_addr_file}" 
           amountLovelace=${payment_lovelace}
           amountADA=${payment_ada}
           ;;
        1) s_addr_file="${s_base_addr_file}" 
           amountLovelace=${base_lovelace}
           amountADA=${base_ada}
           ;;
        2) continue ;;
      esac
    elif [[ ${payment_lovelace} -gt 0 ]]; then
      s_addr_file="${s_payment_addr_file}"
      amountLovelace=${payment_lovelace}
      amountADA=${payment_ada}
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Payment"  "$(numfmt --grouping ${payment_ada})")" "log"
    elif [[ ${base_lovelace} -gt 0 ]]; then
      s_addr_file="${s_base_addr_file}"
      amountLovelace=${base_lovelace}
      amountADA=${base_ada}
      say "$(printf "%s\t${CYAN}%s${NC} ADA" "Base"  "$(numfmt --grouping ${base_ada})")" "log"
    else
      say "${RED}ERROR${NC}: no funds available in either payment or base address for wallet ${GREEN}${s_wallet}${NC}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      if ! ADAtoLovelace "${amountADA}"; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
      amountLovelace=$(ADAtoLovelace "${amountADA}")
      echo ""
      say " -- Transaction Fee --"
      echo ""
      say "Fee payed by sender? [else amount sent is reduced]"
      case $(select_opt "Yes" "No" "Cancel") in
        0) include_fee="no" ;;
        1) include_fee="yes" ;;
        2) continue ;;
      esac
    else
      echo ""
      say "ADA to send set to total supply: $(numfmt --grouping ${amountADA})" "log"
      echo ""
      include_fee="yes"
    fi

    # Destination
    say " -- Destination Address / Wallet --"
    echo ""
    say "Is destination a local wallet or an address?"
    case $(select_opt "Wallet" "Address" "Cancel") in
      0) if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function
         d_wallet="${wallet_name}"
         d_payment_addr_file="${WALLET_FOLDER}/${d_wallet}/${WALLET_PAY_ADDR_FILENAME}"
         d_base_addr_file="${WALLET_FOLDER}/${d_wallet}/${WALLET_BASE_ADDR_FILENAME}"
    
         if [[ -f "${d_payment_addr_file}" && -f "${d_base_addr_file}" ]]; then
           # Both payment and base address available, let user choose what to use
           say "Both payment and base address available, choose address"
           echo ""
           case $(select_opt "Payment" "Base" "Cancel") in
             0) d_addr_file="${d_payment_addr_file}" ;;
             1) d_addr_file="${d_base_addr_file}" ;;
             2) continue ;;
           esac
         elif [[ -f "${d_payment_addr_file}" ]]; then
           d_addr_file="${d_payment_addr_file}"
         elif [[ -f "${d_base_addr_file}" ]]; then
           d_addr_file="${d_base_addr_file}"
         else
           say "${RED}ERROR${NC}: no payment or base address file found for wallet ${GREEN}${s_wallet}${NC}"
           say "${d_payment_addr_file}"
           say "${d_base_addr_file}"
           echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
         fi
         d_addr="$(cat ${d_addr_file})"
         ;;
      1) echo "" && read -r -p "Address: " d_addr ;;
      2) continue ;;
    esac
    # Destination could be empty, if so  without getting a valid address
    if [[ -z ${d_addr} ]]; then
      say "${RED}ERROR${NC}: destination address field empty"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    # Source Sign Key
    # decrypt signing key if needed and make sure to encrypt again even on failure
    s_payment_sk_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_SK_FILENAME}"
    if [[ ! -f "${s_payment_sk_file}" ]]; then
      say "${RED}ERROR${NC}: source wallet signing key file not found:"
      say "${s_payment_sk_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    if ! sendADA "${d_addr}" "${amountLovelace}" "${s_addr}" "${s_payment_sk_file}" "${include_fee}"; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    echo ""

    if ! waitNewBlockCreated; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    say ""
    say "--- Balance Check Source Address -------------------------------------------------------"
    getBalance ${s_addr}

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      say ""
      say "--- Balance Check Source Address -------------------------------------------------------"
      getBalance ${s_addr}
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then 
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    s_balance_ada=${totalBalanceADA}

    say ""
    say "--- Balance Check Destination Address --------------------------------------------------"
    getBalance ${d_addr}

    d_balance_ada=${totalBalanceADA}

    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say "Transaction" "log"
    [[ "${s_wallet_type,,}" = "b" ]] && s_wallet_type="base" || s_wallet_type="payment"
    say "  From:        ${GREEN}${s_wallet}${NC} (${s_wallet_type})" "log"
    say "  Amount:      $(numfmt --grouping ${amountADA}) ADA" "log"
    if [[ ${d_type,,} = "a" ]]; then
      say "  To:          ${d_addr}" "log"
    else
      [[ "${d_wallet_type,,}" = "b" ]] && d_wallet_type="base" || d_wallet_type="payment"
      say "  To:          ${GREEN}${d_wallet}${NC} (${d_wallet_type})" "log"
    fi
    say "  Fees:        $(numfmt --grouping ${minFee}) Lovelaces" "log"
    say "  Balance:" "log"
    say "  Source:      $(numfmt --grouping ${s_balance_ada}) ADA" "log"
    say "  Destination: $(numfmt --grouping ${d_balance_ada}) ADA" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    delegate)  # [WALLET NAME] [POOL NAME]

    clear
    echo " >> FUNDS >> DELEGATE"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function
    
    base_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
    
    if [[ ! -f "${base_addr_file}" ]]; then
      say "${RED}ERROR${NC}: 'wallet base address file not found (are you sure this is a stake wallet?):"
      say "${base_addr_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
    stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    
    if [[ ! -f "${stake_sk_file}" || ! -f "${stake_vk_file}" || ! -f "${pay_payment_sk_file}" ]]; then
      say "${RED}ERROR${NC}: 'Source wallet keys missing, expecting these files to be in wallet:"
      say "${stake_sk_file}"
      say "${stake_vk_file}"
      say "${pay_payment_sk_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    if ! selectPool; then continue; fi # ${pool_name} populated by selectPool function
    
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    
    if [[ ! -f "${pool_coldkey_vk_file}" ]]; then
      say "${RED}ERROR${NC}: 'Pool cold verification key missing:"
      say "${pool_coldkey_vk_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    #Generated Files
    delegation_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"

    say "-- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${delegation_cert_file}"

    #[stake vkey] [stake skey] [pay skey] [pay addr] [pool vkey] [deleg cert]
    if ! delegate "${stake_vk_file}" "${stake_sk_file}" "${pay_payment_sk_file}" "$(cat ${base_addr_file})" "${pool_coldkey_vk_file}" "${delegation_cert_file}" ; then
      echo "" && say "${RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
      rm -f "${delegation_cert_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    if ! waitNewBlockCreated; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    echo ""
    say "--- Balance Check Source Address -------------------------------------------------------"
    getBalance "$(cat ${base_addr_file})"

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      echo ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      echo ""
      say "--- Balance Check Source Address -------------------------------------------------------"
      getBalance "$(cat ${base_addr_file})"
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    say "Delegation successfully registered"
    say "Wallet : ${GREEN}${wallet_name}${NC}"
    say "Pool   : ${GREEN}${pool_name}${NC}" "log"
    say "Amount : $(numfmt --grouping ${totalBalanceADA}) ADA" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""

    echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    ;; ###################################################################

  esac

  ;; ###################################################################

  pool)

  clear
  echo " >> POOL"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo " Pool Management"
  echo ""
  echo " ) New       -  create a new pool"
  echo " ) Register  -  register created pool on chain using a stake wallet (pledge wallet)"
  echo " ) Modify    -  change pool parameters and register updated pool values on chain"
  echo " ) List      -  a compact list view of available local pools"
  echo " ) Show      -  detailed view of specified pool"
  echo " ) Rotate    -  rotate pool KES keys"
  echo " ) Decrypt   -  remove write protection and decrypt pool"
  echo " ) Encrypt   -  encrypt pool cold keys and make all files immutable"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  
  say " Select wallet operation"
  case $(select_opt "New" "Register" "Modify" "List" "Show" "Rotate" "Decrypt" "Encrypt" "<- Home") in
    0) SUBCOMMAND="new" ;;
    1) SUBCOMMAND="register" ;;
    2) SUBCOMMAND="modify" ;;
    3) SUBCOMMAND="list" ;;
    4) SUBCOMMAND="show" ;;
    5) SUBCOMMAND="rotate" ;;
    6) SUBCOMMAND="decrypt" ;;
    7) SUBCOMMAND="encrypt" ;;
    8) continue ;;
  esac

  case $SUBCOMMAND in
    new)

    clear
    echo " >> POOL >> NEW"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    read -r -p "Pool Name: " pool_name
    # Remove unwanted characters from pool name
    pool_name=${pool_name//[^[:alnum:]]/_}
    if [[ -z "${pool_name}" ]]; then
      say "${RED}ERROR${NC}: Empty pool name, please retry!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
    read -r -n 1 -s -p "press any key to return to home menu" && continue
    
    ;; ###################################################################

    register)

    clear
    echo " >> POOL >> REGISTER"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    if ! selectPool; then continue; fi # ${pool_name} populated by selectPool function

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    
    pledge_ada=50000 # default pledge
    if [[ -f "${pool_config}" ]]; then
      pledge_ada=$(jq -r .pledgeADA "${pool_config}")
    fi
    read -r -p "Pledge (in ADA, default: ${pledge_ada}): " pledge_enter
    if [[ -n "${pledge_enter}" ]]; then
      if ! ADAtoLovelace "${pledge_enter}"; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      if ! pctToFraction "${margin_enter}"; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      if ! ADAtoLovelace "${cost_enter}"; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
      cost_lovelace=$(ADAtoLovelace "${cost_enter}")
      cost_ada="${cost_enter}"
    else
      cost_lovelace=$(ADAtoLovelace "${cost_ada}")
    fi
    
    echo ""

    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function
    
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
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}"  || ! -f "${pool_vrf_vk_file}" ]] && {
      say "${RED}ERROR${NC}: pool files missing, expecting these files to be available:"
      say "${pool_coldkey_vk_file}"
      say "${pool_coldkey_sk_file}"
      say "${pool_vrf_vk_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    if ! waitNewBlockCreated; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    say ""
    say "--- Balance Check Source Address -------------------------------------------------------"
    getBalance "$(cat ${base_addr_file})"

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      say ""
      say "--- Balance Check Source Address -------------------------------------------------------"
      getBalance "$(cat ${base_addr_file})"
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
    read -r -n 1 -s -p "press any key to return to home menu" && continue
    
    ;; ###################################################################

    modify)

    clear
    echo " >> POOL >> MODIFY"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    if ! selectPool; then continue; fi # ${pool_name} populated by selectPool function

    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    
    if [[ ! -f ${pool_config} ]]; then
      say "${ORANGE}WARN${NC}: Missing pool config file, please first register your pool"
      say "${pool_config}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
    if ! selectWallet; then continue; fi # ${wallet_name} populated by selectWallet function
    
    say "Enter new pool parameters, press enter to use old value"
    echo ""
    
    pledge_ada=$(jq -r .pledgeADA "${pool_config}")
    read -r -p "New Pledge (in ADA, old: ${pledge_ada}): " pledge_enter
    if [[ -n "${pledge_enter}" ]]; then
      if ! ADAtoLovelace "${pledge_enter}"; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
      pledge_lovelace=$(ADAtoLovelace "${pledge_enter}")
      pledge_ada="${pledge_enter}"
    else
      pledge_lovelace=$(ADAtoLovelace "${pledge_ada}")
    fi

    margin=$(jq -r .margin "${pool_config}")
    echo "" && read -r -p "New Margin (in %, old: ${margin}): " margin_enter
    if [[ -n "${margin_enter}" ]]; then
      if ! pctToFraction "${margin_enter}"; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
      margin_fraction=$(pctToFraction "${margin_enter}")
      margin="${margin_enter}"
    else
      margin_fraction=$(pctToFraction "${margin}")
    fi

    cost_ada=$(jq -r .costADA "${pool_config}")
    echo "" && read -r -p "New Cost (in ADA, old: ${cost_ada}): " cost_enter
    if [[ -n "${cost_enter}" ]]; then
      if ! ADAtoLovelace "${cost_enter}"; then
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    [[ ! -f "${pool_coldkey_vk_file}" || ! -f "${pool_coldkey_sk_file}"  || ! -f "${pool_vrf_vk_file}" ]] && {
      say "${RED}ERROR${NC}: ${GREEN}${pool_name}${NC} pool files missing, expecting these files to be available:"
      say "${pool_coldkey_vk_file}"
      say "${pool_coldkey_sk_file}"
      say "${pool_vrf_vk_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    }

    #Generated Files
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"

    say "-- creating registration cert --" "log"
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${stake_vk_file}" --pool-owner-stake-verification-key-file "${stake_vk_file}" --out-file "${pool_regcert_file}" --testnet-magic ${NWMAGIC}
    say "-- Sending transaction to chain --" "log"

    if ! modifyPool "$(cat ${base_addr_file})" "${pool_coldkey_sk_file}" "${stake_sk_file}" "${pool_regcert_file}" "${pay_payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool update, removing newly created registration certificate"
      rm -f "${pool_regcert_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    if ! waitNewBlockCreated; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    say ""
    say "--- Balance Check Wallet Address -------------------------------------------------------"
    getBalance "$(cat ${base_addr_file})"

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))"
      if ! waitNewBlockCreated; then
        break
      fi
      say ""
      say "--- Balance Check Wallet Address -------------------------------------------------------"
      getBalance "$(cat ${base_addr_file})"
    done
    
    if [[ ${TOTALBALANCE} -ne ${newBalance} ]]; then
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
    read -r -n 1 -s -p "press any key to return to home menu" && continue
    
    ;; ###################################################################

    list)
    
    clear
    echo " >> POOL >> LIST"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    while IFS= read -r -d '' pool; do 
      echo ""
      pool_id=$(cat "${pool}/${POOL_ID_FILENAME}")
      ledger_status=$(${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC} | grep "poolPubKey" | grep "${pool_id}")
      [[ -n "${ledger_status}" ]] && ledger_status="YES" || ledger_status="NO"
      say "${GREEN}$(basename ${pool})${NC} "
      say "$(printf "%-21s : %s" "ID" "${pool_id}")" "log"
      say "$(printf "%-21s : %s" "Registered" "${ledger_status}")" "log"
      if [[ -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
        kesExpiration "$(cat "${pool}/${POOL_CURRENT_KES_START}")"
        say "$(printf "%-21s : %s" "KES expiration period" "${kes_expiration_period}")" "log"
        say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
      fi
    done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    read -r -n 1 -s -p "press any key to return to home menu"
    
    ;; ###################################################################

    show)
    
    clear
    echo " >> POOL >> SHOW"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    if ! selectPool; then continue; fi # ${pool_name} populated by selectPool function
    
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    pool_id=$(cat "${POOL_FOLDER}/${pool_name}/${POOL_ID_FILENAME}")
    ledger_status=$(${CCLI} shelley query ledger-state --testnet-magic ${NWMAGIC} | grep "poolPubKey" | grep "${pool_id}")
    [[ -n "${ledger_status}" ]] && ledger_status="YES" || ledger_status="NO"
    say "${GREEN}${pool_name}${NC} "
    say "$(printf "%-21s : %s" "ID" "${pool_id}")" "log"
    pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
    if [[ -f "${pool_config}" ]]; then
      say "$(printf "%-21s : %s ADA" "Pledge" "$(numfmt --grouping "$(jq -r .pledgeADA "${pool_config}")")")" "log"
      say "$(printf "%-21s : %s %%" "Margin" "$(numfmt --grouping "$(jq -r .margin "${pool_config}")")")" "log"
      say "$(printf "%-21s : %s ADA" "Cost" "$(numfmt --grouping "$(jq -r .costADA "${pool_config}")")")" "log"
    fi
    say "$(printf "%-21s : %s" "Registered" "${ledger_status}")" "log"
    if [[ -f "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}" ]]; then
      kesExpiration "$(cat "${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}")"
      say "$(printf "%-21s : %s" "KES expiration period" "${kes_expiration_period}")" "log"
      say "$(printf "%-21s : %s" "KES expiration date" "${expiration_date}")" "log"
    fi
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
    say "$(printf "%-21s : %s" "Run arguments" "--shelley-kes-key ${pool_hotkey_sk_file}")" "log"
    say "$(printf "%-21s   %s" "" "--shelley-vrf-key ${pool_vrf_sk_file}")" "log"
    say "$(printf "%-21s   %s" "" "--shelley-operational-certificate ${pool_opcert_file}")" "log"
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "" && read -r -n 1 -s -p "press any key to return to home menu"
    
    ;; ###################################################################
    
    rotate)

    clear
    echo " >> POOL >> ROTATE KES"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    if [[ ! -f ${TMP_FOLDER}/protparams.json ]]; then
      say "${RED}ERROR${NC}: CNTOOLS started without node access, only offline functions available!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    
    if ! selectPool; then continue; fi # ${pool_name} populated by selectPool function

    # cold keys
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"

    # generated files
    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
    pool_saved_kes_start="${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
    
    [[ ! -f "${pool_coldkey_sk_file}" || ! -f "${pool_hotkey_vk_file}"  || ! -f "${pool_hotkey_sk_file}" || ! -f "${pool_opcert_counter_file}" ]] && {
      say "${RED}ERROR${NC}: pool files missing, expecting these files to be available:"
      say "${pool_coldkey_sk_file}"
      say "${pool_hotkey_vk_file}"
      say "${pool_hotkey_sk_file}"
      say "${pool_opcert_counter_file}"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    }

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
    read -r -n 1 -s -p "press any key to return to home menu" && continue
    
    ;; ###################################################################
    
    decrypt)
    
    clear
    echo " >> POOL >> DECRYPT"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    protectionPreRequisites || continue
    
    if ! selectPool; then continue; fi # ${pool_name} populated by selectPool function
    
    filesUnlocked=0
    keysDecrypted=0
    
    say " -- Removing write protection from all pool files --" "log"
    while IFS= read -r -d '' file; do
      if [[ $(lsattr -R "$file" 2>/dev/null | grep -c -P "(?<=-)i(?=-)") -ne 0 ]]; then
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
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    encrypt)
    
    clear
    echo " >> POOL >> ENCRYPT"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    
    protectionPreRequisites || continue
    
    if ! selectPool; then continue; fi # ${pool_name} populated by selectPool function

    filesLocked=0
    keysEncrypted=0

    say " -- Encrypting sensitive pool keys with GPG --" "log"
    echo ""
    say "Pool ${GREEN}${pool_name}${NC} Password"
    echo ""
    if ! getPassword confirm; then # $password variable populated by getPassword function
      echo -e "\n\n" && say "${RED}ERROR${NC}: password input aborted!"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
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
      if [[ $(lsattr -R "$file" 2>/dev/null | grep -c -P "(?<=-)i(?=-)") -eq 0 ]]; then
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

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

  esac

  ;; ###################################################################

esac # main OPERATION
done # main loop
}

##############################################################

main "$@"
