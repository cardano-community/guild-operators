#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154,SC2034
# ,SC2034,SC2143,SC2046,
# Creators: gufmar, Scitz0, Papacarp
# 2020-05-19 cntools initial release (concept)
# 2020-05-24 helper functions moved cnlibrary & configuration to env file

########## Global tasks ###########################################

# get common env variables
. "$(dirname $0)"/env_guild

# get cntools config parameters
. "$(dirname $0)"/cntools.config

# get helper functions from library file
. "$(dirname $0)"/cntools.library

# Start with a clean slate
mkdir -p ${TMP_FOLDER} # Create if missing
rm -f ${TMP_FOLDER}/*

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} > ${TMP_FOLDER}/protparams.json || {
  say "${RED}ERROR${NC}: failed to query protocol parameters, node running and env parameters correct?" "log"
  exit 1
}

# check for required command line tools
need_cmd "curl"
need_cmd "jq"
[[ "${PROTECT_KEYS}" = "yes" ]] && need_cmd "gpg"

###################################################################

function main {

while true; do # Main loop

clear
echo " >> CNTOOLS <<                                       A Guild Operators collaboration"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "   Main Menu"
echo ""
echo "   1) update"
echo "   2) wallet  [new/upgrade|list|show|remove|decrypt|encrypt]"
echo "   3) funds   [send|delegate]"
echo "   4) pool    [new|register]"
echo "   q) quit"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

while true; do # Home menu
  read -r -n 1 -p "What would you like to do? (1-4): " OPERATION
  echo ""
  case ${OPERATION:0:1} in
    1) OPERATION="update" && break
      ;;
    2) OPERATION="wallet" && break
      ;;
    3) OPERATION="funds" && break
      ;;
    4) OPERATION="pool" && break
      ;;
    q) clear && exit
      ;;
    *) say ">>> Invalid Selection"
      ;;
  esac
done

case $OPERATION in

  update) # not ready yet. ToDo when binary releases become available
  clear
  echo " >> UPDATE"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo ""
  say "${RED}ERROR${NC}: Sorry! not ready yet in cntools" "log"
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

    say "Currently installed: ${CURRENT_VERSION}"
    say "Desired release:      ${DESIRED_RELEASE_CLEAN} (${DESIRED_RELEASE_PUBLISHED})"
    if [ "${DESIRED_RELEASE_CLEAN}" != "${CURRENT_VERSION}" ]; then
      read -r -n 1 -p "Would you like to upgrade to this release? (y/N)? " answer
      case ${answer:0:1} in
        y|Y )
          FILE="cardano-node-${DESIRED_RELEASE}-${ASSET_PLATTFORM}.tar.gz"
          URL="https://github.com/input-output-hk/cardano-node/releases/download/${DESIRED_RELEASE}/"${FILE}
          echo -e "\nDownload $FILE ..."
          curl --proto '=https' --tlsv1.2 -L -URL ${URL} -O ${CNODE_HOME}${FILE}
          tar -C ${CNODE_BIN_HOME} -xzf $FILE
          rm $FILE

          say "updated cardano-node from ${CURRENT_VERSION} to ${DESIRED_RELEASE_CLEAN}" "log"
        ;;
      esac

    fi
  else #
    say "No cardano-cli binary found"
    say "Desired available release: ${DESIRED_RELEASE_CLEAN} (${DESIRED_RELEASE_PUBLISHED})"
    read -n 1 -r -p "Would you like to install this release? (Y/n)? " answer
    case ${answer:0:1} in
      n|N )
        say "Well, that was a pleasant but brief pleasure. Bye bye!"
      ;;
      * )
        FILE="cardano-node-${DESIRED_RELEASE}-${ASSET_PLATTFORM}.tar.gz"
        URL="https://github.com/input-output-hk/cardano-node/releases/download/${DESIRED_RELEASE}/"${FILE}
        echo -e "\nDownload $FILE ..."
        curl --proto '=https' --tlsv1.2 -L -URL ${URL} -O ${CNODE_HOME}${FILE}
        mkdir -p ${CNODE_BIN_HOME}
        tar -C ${CNODE_BIN_HOME} -xzf $FILE
        rm $FILE
        say "installed Jormungandr ${DESIRED_RELEASE_CLEAN}" "log"
      ;;
    esac

  fi

  echo "" && read -r -n 1 -s -p "press any key to return to home menu"

  ;; ###################################################################

  wallet)

  clear
  echo " >> WALLET"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "   Wallet Management"
  echo ""
  echo "   1) new / upgrade"
  echo "   2) list"
  echo "   3) show"
  echo "   4) remove"
  echo "   5) decrypt"
  echo "   6) encrypt"
  echo "   h) home"
  echo "   q) quit"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  while true; do
    read -r -n 1 -p "What wallet operation would you like to perform? (1-6): " SUBCOMMAND
    echo ""
    case ${SUBCOMMAND:0:1} in
      1) SUBCOMMAND="new" && break
        ;;
      2) SUBCOMMAND="list" && break
        ;;
      3) SUBCOMMAND="show" && break
        ;;
      4) SUBCOMMAND="remove" && break
        ;;
      5) SUBCOMMAND="decrypt" && break
        ;;
      6) SUBCOMMAND="encrypt" && break
        ;;
      h) break
        ;;
      q) clear && exit
        ;;
      *) say ">>> Invalid Selection"
        ;;
    esac
  done

  case $SUBCOMMAND in
    new)

    clear
    echo " >> WALLET >> NEW / UPGRADE"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "   Wallet Type"
    echo ""
    echo "   1) payment  - first step for a new wallet"
    echo "   2) staking  - upgrade existing payment wallet"
    echo "                 a payment wallet need to exist for before upgrade"
    echo "                 make sure there are funds available in payment wallet before upgrade"
    echo "   h) home"
    echo "   q) quit"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    while true; do
      read -r -n 1 -p "Choose wallet type (1-2): " wallet_type
      echo ""
      case ${wallet_type:0:1} in
        1) wallet_type="payment" && break
          ;;
        2) wallet_type="staking" && break
          ;;
        h) break
          ;;
        q) clear && exit
          ;;
        *) say ">>> Invalid Selection"
          ;;
      esac
    done

    case $wallet_type in
      payment)

      clear
      echo " >> WALLET >> NEW >> PAYMENT"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      read -r -p "Name of new wallet: " wallet_name
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
      ${CCLI} shelley address build --payment-verification-key-file "${payment_vk_file}" > "${payment_addr_file}"

      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        trap 'rm -rf ${WALLET_FOLDER:?}/${wallet_name}' INT TERM
        say " -- Wallet ${GREEN}${wallet_name}${NC} Password --"
        getPassword confirm # $password variable populated by getPassword function
        if ! encryptFile "${payment_vk_file}" "${password}" || \
          ! encryptFile "${payment_sk_file}" "${password}"; then
          rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
          echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
        fi
      fi

      say "Wallet: ${wallet_name}" "log"
      say "Payment Address: $(cat ${payment_addr_file})" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu"

      ;; ###################################################################

      staking)

      clear
      echo " >> WALLET >> NEW >> STAKING"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      say "Select Wallet:"
      select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
        test -n "${wallet_name}" && break
        say ">>> Invalid Selection (ctrl+c to quit)"
      done

      # Wallet key filenames
      payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
      payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
      staking_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_VK_FILENAME}"
      staking_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_SK_FILENAME}"
      staking_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_ADDR_FILENAME}"
      staking_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_CERT_FILENAME}"
      stakepayment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKEPAY_ADDR_FILENAME}"


      if [[ ! -f "${payment_addr_file}" ]]; then
        say "${RED}WARN${NC}: No payment wallet found with name: ${GREEN}$wallet_name${NC}"
        say "      A payment wallet with funds available needed to upgrade to staking"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      elif [[ -f "${staking_addr_file}" ]]; then
        say "${RED}WARN${NC}: A staking wallet ${GREEN}$wallet_name${NC} already exists"
        say "      Choose another name or delete the existing one"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi

      # Decrypt payment verification key if needed, reencrypted together with staking keys later
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        [[ ! -f "${payment_vk_file}.gpg" ]] && {
          say "${RED}ERROR${NC}: 'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "log"
          say "${payment_vk_file}.gpg" "log"
          echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
        }
        echo ""
        say " -- Wallet ${GREEN}${wallet_name}${NC} Password --"
        getPassword # $password variable populated by getPassword function
        if ! decryptFile "${payment_vk_file}.gpg" "${password}"; then
          unset password
          echo "" && say "${RED}ERROR${NC}: failure during payment verification key decryption" "log"
          echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
        fi
      fi

      ${CCLI} shelley stake-address key-gen --verification-key-file "${staking_vk_file}" --signing-key-file "${staking_sk_file}"
      ${CCLI} shelley stake-address build --stake-verification-key-file "${staking_vk_file}" > "${staking_addr_file}"
      # upgrade the payment address to an address that delegates to the new stake address
      ${CCLI} shelley address build --payment-verification-key-file "${payment_vk_file}" --stake-verification-key-file "${staking_vk_file}" > "${stakepayment_addr_file}"

      ${CCLI} shelley stake-address registration-certificate --stake-verification-key-file "${staking_vk_file}" --out-file "${staking_cert_file}"

      # Decrypt payment signing key if needed, reencrypted together with staking keys later
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        [[ ! -f "${payment_sk_file}.gpg" ]] && {
          say "${RED}ERROR${NC}: 'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "log"
          say "${payment_sk_file}.gpg" "log"
          echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
        }
        echo ""
        if ! decryptFile "${payment_sk_file}.gpg" "${password}"; then
          unset password
          rm -f "${staking_vk_file}" "${staking_sk_file}" "${staking_addr_file}" "${staking_cert_file}"
          echo "" && say "${RED}ERROR${NC}: failure during payment signing key decryption, removing newly created staking keys" "log"
          echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
        fi
      fi

      payment_addr="$(cat ${payment_addr_file})"
      stakepayment_addr="$(cat ${stakepayment_addr_file})"

      # Register on chain
      if ! registerStaking "${payment_addr}" "${stakepayment_addr}" "${payment_sk_file}" "${staking_sk_file}" "${staking_cert_file}"; then
        say "${RED}ERROR${NC}: failure during staking key registration, removing newly created staking keys" "log"
        rm -f "${staking_vk_file}" "${staking_sk_file}" "${staking_addr_file}" "${staking_cert_file}"
        if [[ "${PROTECT_KEYS}" = "yes" ]]; then
          if ! encryptFile "${payment_sk_file}" "${password}" || \
              ! encryptFile "${payment_vk_file}" "${password}"; then
            say "${RED}ERROR${NC}: failure during key encryption!" "log"
            say "${ORANGE}Please make sure all of these keys are encrypted for wallet ${wallet_name}, else manually re-encrypt!${NC}"
            say "File should have extension .gpg"
            say "${payment_sk_file}.gpg" "log"
            say "${payment_vk_file}.gpg" "log"
          fi
        fi
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi

      # Encrypt keys before we wait for tx to go through
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        if ! encryptFile "${staking_vk_file}" "${password}" || \
          ! encryptFile "${payment_vk_file}" "${password}" || \
          ! encryptFile "${staking_sk_file}" "${password}" || \
          ! encryptFile "${staking_cert_file}" "${password}" || \
          ! encryptFile "${payment_sk_file}" "${password}"; then
          say "${RED}ERROR${NC}: failure during key encryption!" "log"
        fi
      fi

      waitNewBlockCreated

      say ""
      say "--- Balance Check Source Address -------------------------------------------------------" "log"
      getBalance "${payment_addr}"

      while [[ ${TOTALBALANCE} -ne 0 ]]; do
        say ""
        say "${ORANGE}WARN${NC}: Balance missmatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != 0" "log"
        waitNewBlockCreated
        say ""
        say "--- Balance Check Source Address -------------------------------------------------------" "log"
        getBalance "${payment_addr}"
      done

      say "Wallet: ${wallet_name}" "log"
      say "Payment Address: $(cat ${payment_addr_file})" "log"
      say "Staking Address: $(cat ${staking_addr_file})" "log"
      say "StakePayment Address: ${stakepayment_addr}" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu"

      ;; ###################################################################

    esac

    ;; ###################################################################

    list)
    clear
    echo " >> WALLET >> LIST"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    for wallet_folder_name in "${WALLET_FOLDER}"/*/
    do
      wallet_name=${wallet_folder_name%*/}
      if [ -f "${wallet_folder_name}${WALLET_PAY_ADDR_FILENAME}" ]; then
        payment_addr_file=$(cat "${wallet_folder_name}${WALLET_PAY_ADDR_FILENAME}")
        say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
        echo ""
        say "Payment Address: ${payment_addr_file}"
        say "Balance:"
        getBalance ${payment_addr_file}
        echo ""
        # TODO - Can reward address be listed?
        # if [ -f "${wallet_folder_name}${WALLET_STAKING_ADDR_FILENAME}" ]; then
        #  staking_addr_file=$(cat "${wallet_folder_name}${WALLET_STAKING_ADDR_FILENAME}")
        #  say "Reward Address:  ${staking_addr_file}"
        #  say "Balance:"
        #  getBalance ${staking_addr_file}
        #  echo ""
        # fi
        if [ -f "${wallet_folder_name}${WALLET_STAKEPAY_ADDR_FILENAME}" ]; then
         staking_addr_file=$(cat "${wallet_folder_name}${WALLET_STAKEPAY_ADDR_FILENAME}")
         say "Staking Address:  ${staking_addr_file}"
         say "Balance:"
         getBalance ${staking_addr_file}
         echo ""
        fi

      else
        say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
        say "${RED}WARN${NC}: missing wallet address file:"
        say "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
        echo ""
      fi
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
    done
    read -r -n 1 -s -p "press any key to return to home menu"
    ;; ###################################################################

    show)
    clear
    echo " >> WALLET >> SHOW"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    say "Select Wallet:"
    select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""

    # Wallet key filenames
    payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    staking_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_ADDR_FILENAME}"

    if [ -f "${payment_addr_file}" ]; then
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      payment_addr=$(cat "${payment_addr_file}")
      say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
      echo ""
      say "Payemnt Address: ${payment_addr}"
      say "Balance:"
      getBalance ${payment_addr}
      echo ""
      # TODO - Can reward address be listed?
      #if [ -f "${staking_addr_file}" ]; then
      #  staking_addr=$(cat "${staking_addr_file}")
      #  say "Reward Address:  ${staking_addr}"
      #  say "Balance:"
      #  getBalance ${staking_addr}
      #  echo ""
      #fi
    else
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
      say "${RED}WARN${NC}: missing wallet address file:"
      say "${payment_addr_file}"
      echo ""
    fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "" && read -r -n 1 -s -p "press any key to return to home menu"
    ;; ###################################################################

    remove)
    clear
    echo " >> WALLET >> REMOVE"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    say "Select Wallet:"
    select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done

    # Wallet key filename
    payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"

    if [ -f "${payment_addr_file}" ]; then
      getBalance "$(cat ${payment_addr_file})" >/dev/null
      if [[ ${TOTALBALANCE} -eq 0 ]]; then
        say ""
        say "INFO: This wallet appears to be empty"
        say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup"
        say ""
        read -n 1 -r -p "Are you sure to delete wallet (y/n)? " answer
        say ""
        case ${answer:0:1} in
          y|Y )
            rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
            say "removed ${GREEN}${wallet_name}${NC}"
          ;;
          * )
            say "skipped removal process for ${GREEN}$wallet_name${NC}"
          ;;
        esac
      else
        say ""
        say "${RED}WARN${NC}: this wallet has a balance of $(numfmt --grouping ${totalBalanceADA}) ADA"
        say "${RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup"
        read -n 1 -r -p "Are you sure to delete wallet (y/n)? " answer
        say ""
        case ${answer:0:1} in
          y|Y )
            rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
            say "removed ${GREEN}${wallet_name}${NC}"
          ;;
          * )
            say "skipped removal process for ${GREEN}$wallet_name${NC}"
          ;;
        esac
      fi
    else
      say ""
      say "Wallet: ${GREEN}${wallet_name}${NC} "
      say "${RED}WARN${NC}: missing wallet address file:"
      say "${payment_addr_file}"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
    fi

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    decrypt)
    clear
    echo " >> WALLET >> DECRYPT"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    say "Select Wallet:"
    select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""

    if [[ ! -d "${WALLET_FOLDER}/${wallet_name}" ]]; then
      say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
      say "${RED}WARN${NC}: wallet not found"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    # Wallet key filenames
    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    staking_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_VK_FILENAME}"
    staking_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_SK_FILENAME}"
    staking_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_CERT_FILENAME}"

    say " -- Wallet ${GREEN}${wallet_name}${NC} Password --"
    getPassword # $password variable populated by getPassword function

    keysDecrypted=0
    if [[ -f "${payment_vk_file}.gpg" ]]; then
      if decryptFile "${payment_vk_file}.gpg" "${password}"; then
        keysDecrypted=$((++keysDecrypted))
      fi
    fi
    if [[ -f "${payment_sk_file}.gpg" ]]; then
      if decryptFile "${payment_sk_file}.gpg" "${password}"; then
        keysDecrypted=$((++keysDecrypted))
      fi
    fi
    if [[ -f "${staking_vk_file}.gpg" ]]; then
      if decryptFile "${staking_vk_file}.gpg" "${password}"; then
        keysDecrypted=$((++keysDecrypted))
      fi
    fi
    if [[ -f "${staking_sk_file}.gpg" ]]; then
      if decryptFile "${staking_sk_file}.gpg" "${password}"; then
        keysDecrypted=$((++keysDecrypted))
      fi
    fi
    if [[ -f "${staking_cert_file}.gpg" ]]; then
      if decryptFile "${staking_cert_file}.gpg" "${password}"; then
        keysDecrypted=$((++keysDecrypted))
      fi
    fi

    unset password

    say "Wallet decrypted: ${wallet_name}" "log"
    say "Files decrypted: ${keysDecrypted}" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    encrypt)
    clear
    echo " >> WALLET >> ENCRYPT"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    say "Select Wallet:"
    select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""

    if [[ ! -d "${WALLET_FOLDER}/${wallet_name}" ]]; then
      say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
      say "${RED}WARN${NC}: wallet not found"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    # Wallet key filenames
    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    staking_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_VK_FILENAME}"
    staking_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_SK_FILENAME}"
    staking_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_CERT_FILENAME}"

    say " -- Wallet ${GREEN}${wallet_name}${NC} Password --"
    getPassword confirm # $password variable populated by getPassword function

    keysEncrypted=0
    if [[ -f "${payment_vk_file}" ]]; then
      if encryptFile "${payment_vk_file}" "${password}"; then
        keysEncrypted=$((++keysEncrypted))
      fi
    fi
    if [[ -f "${payment_sk_file}" ]]; then
      if encryptFile "${payment_sk_file}" "${password}"; then
        keysEncrypted=$((++keysEncrypted))
      fi
    fi
    if [[ -f "${staking_vk_file}" ]]; then
      if encryptFile "${staking_vk_file}" "${password}"; then
        keysEncrypted=$((++keysEncrypted))
      fi
    fi
    if [[ -f "${staking_sk_file}" ]]; then
      if encryptFile "${staking_sk_file}" "${password}"; then
        keysEncrypted=$((++keysEncrypted))
      fi
    fi
    if [[ -f "${staking_cert_file}" ]]; then
      if encryptFile "${staking_cert_file}" "${password}"; then
        keysEncrypted=$((++keysEncrypted))
      fi
    fi

    unset password

    say "Wallet encrypted: ${wallet_name}" "log"
    say "Files encrypted: ${keysEncrypted}" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

  esac

  ;; ###################################################################

  funds)

  clear
  echo " >> FUNDS"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "   Handle Funds"
  echo ""
  echo "   1) send"
  echo "   2) delegate"
  echo "   h) home"
  echo "   q) quit"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  while true; do
    read -r -n 1 -p "What wallet operation would you like to perform? (1-2): " SUBCOMMAND
    echo ""
    case ${SUBCOMMAND:0:1} in
      1) SUBCOMMAND="send" && break
        ;;
      2) SUBCOMMAND="delegate" && break
        ;;
      h) break
        ;;
      q) clear && exit
        ;;
      *) say ">>> Invalid Selection"
        ;;
    esac
  done

  case $SUBCOMMAND in
    send)
    clear
    echo " >> FUNDS >> SEND"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""

    # Destination
    while true; do
      say " -- Destination Address / Wallet --"
      echo ""
      read -n 1 -r -p "Do you want to specify destination as an Address or Wallet (a/w)? " d_type
      say ""
      case ${d_type:0:1} in
        a|A )
          echo "" && read -r -p "Address: " d_addr
          test -n "${d_type}" && break
        ;;
        w|W )
          echo "" && say "Select Destination Wallet:"
          select dWallet in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
            test -n "${dWallet}" && break
            say ">>> Invalid Selection (ctrl+c to quit)"
          done
          d_payment_addr_file="${WALLET_FOLDER}/${dWallet}/${WALLET_PAY_ADDR_FILENAME}"
          if [[ ! -f "${d_payment_addr_file}" ]]; then
            say "${RED}ERROR${NC}: destination wallet address file not found:" "log"
            say "${d_payment_addr_file}" "log"
            echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
          fi
          d_addr="$(cat ${d_payment_addr_file})"
          break
        ;;
        * )
          say ">>> Invalid Selection"
        ;;
      esac
    done

    # Amount
    echo ""
    say " -- Amount to Send --"
    echo ""
    say "Valid entry:  ${BLUE}Integer${NC}"
    say "              ${BLUE}Fraction number${NC} with a decimal dot"
    say "              The string '${BLUE}all${NC}' to send all available funds in source wallet"
    echo ""
    say "Info:         If destination and source wallet is the same and amount set to 'all',"
    say "              wallet will be defraged, ie converts multiple UTxO's to one"
    echo ""
    read -r -p "Amount: " amount
    [[ -z "${amount}" ]] && say "${RED}ERROR${NC}: amount can not be empty!" "log" && echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue

    # Source
    echo ""
    say " -- Source Wallet --"
    echo "" && say "Select Source Wallet:"
    select s_wallet in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${s_wallet}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    s_payment_addr_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_ADDR_FILENAME}"
    if [[ ! -f "${s_payment_addr_file}" ]]; then
      say "${RED}ERROR${NC}: source wallet address file not found:" "log"
      say "${s_payment_addr_file}" "log"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    s_addr="$(cat ${s_payment_addr_file})"

    echo ""
    say " -- Transaction Fee --"
    echo ""
    read -n 1 -r -p "Fee payed by sender (y/n)? [else amount sent reduced] " answer
    echo ""
    case ${answer:0:1} in
      n|N ) include_fee="yes"
      ;;
      * ) include_fee="no"
      ;;
    esac

    # Source Sign Key
    # decrypt signing key if needed and make sure to encrypt again even on failure
    s_payment_sk_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_SK_FILENAME}"
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${s_payment_sk_file}.gpg" ]] && {
        say "${RED}ERROR${NC}: 'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "log"
        say "${s_payment_sk_file}.gpg" "log"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      }
      echo ""
      say " -- Wallet ${GREEN}${s_wallet}${NC} Password --"
      getPassword # $password variable populated by getPassword function
      if ! decryptFile "${s_payment_sk_file}.gpg" "${password}"; then
        unset password
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
    else
      if [[ ! -f "${s_payment_sk_file}" ]]; then
        say "${RED}ERROR${NC}: source wallet signing key file not found:" "log"
        say "${s_payment_sk_file}" "log"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
    fi

    say "${ORANGE}Source wallet signing key decrypted, make sure key is re-encrypted in case of error or cancelation${NC}"
    read -r -n 1 -s -p "press any key to continue"
    echo ""

    if ! sendADA "${d_addr}" "${amount}" "${s_addr}" "${s_payment_sk_file}" "${include_fee}"; then
      delayExit=1
    else
      delayExit=0
    fi

    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      encryptFile "${s_payment_sk_file}" "${password}"
      unset password
    fi

    [[ ${delayExit} -eq 1 ]] && echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue

    waitNewBlockCreated

    say ""
    say "--- Balance Check Source Address -------------------------------------------------------" "log"
    getBalance ${s_addr}

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance missmatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))" "log"
      waitNewBlockCreated
      say ""
      say "--- Balance Check Source Address -------------------------------------------------------" "log"
      getBalance ${s_addr}
    done

    say ""
    say "--- Balance Check Destination Address --------------------------------------------------" "log"
    getBalance ${d_addr}

    newBalanceADA=$(echo "${newBalance}/1000000" | bc -l | sed '/\./ s/\.\{0,1\}0\{1,\}$//')

    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say "Transaction" "log"
    say "  From:       ${s_wallet}" "log"
    say "  Amount:     $(numfmt --grouping ${amount})" "log"
    say "  To:         ${d_addr}" "log"
    say "  Fees:       $(numfmt --grouping ${minFee}) Lovelaces" "log"
    say "  Balance:    $(numfmt --grouping ${newBalance}) Lovelaces ($(numfmt --grouping ${newBalanceADA}) ADA)" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    delegate)  # [WALLET NAME] [POOL NAME]

    clear
    echo " >> FUNDS >> DELEGATE"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""

    say "Select Wallet to Delegate from:"
    select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""
    stakepayment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKEPAY_ADDR_FILENAME}"
    #pay_payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    if [[ ! -f "${stakepayment_addr_file}" ]]; then
      say "${RED}ERROR${NC}: 'Source wallet staking address file not found (are you sure this is a staking wallet?):" "log"
      say "${stakepayment_addr_file}" "log"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      say " -- Wallet ${GREEN}${wallet_name}${NC} Password --"
      getPassword # $password variable populated by getPassword function
      walletpassword=$password # save for later
      echo ""
    fi
    staking_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_SK_FILENAME}"
    staking_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_VK_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"

    say "Select Pool:"
    select pool_name in $(find ${POOL_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${pool_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      say " -- Pool ${GREEN}${pool_name}${NC} Password --"
      getPassword # $password variable populated by getPassword function
      echo ""
    fi
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"

    # Encrypted Files to decrypt
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      if ! decryptFile "${pool_coldkey_vk_file}.gpg" "${password}"; then
        say "${RED}ERROR${NC}: failure during pool cold key decryption!" "log"
        unset password walletpassword
        # No need to continue as we failed to decrypt some of the files
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      elif ! decryptFile "${pay_payment_sk_file}.gpg" "${walletpassword}" || \
          ! decryptFile "${staking_vk_file}.gpg" "${walletpassword}" || \
          ! decryptFile "${staking_sk_file}.gpg" "${walletpassword}"; then
        say "${RED}ERROR${NC}: Pool decryption successful but failure during wallet key decryption!" "log"
        say "re-encrypting pool cold key"
        encryptFile "${pool_coldkey_vk_file}" "${password}"
        unset password walletpassword
        # No need to continue as we failed to decrypt some of the files
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
    fi

    #Generated Files
    delegation_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"

    say "-- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${staking_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${delegation_cert_file}"

    #[stake vkey] [stake skey] [pay skey] [pay addr] [pool vkey] [deleg cert]
    if ! delegate "${staking_vk_file}" "${staking_sk_file}" "${pay_payment_sk_file}" "$(cat ${stakepayment_addr_file})" "${pool_coldkey_vk_file}"  "${delegation_cert_file}" ; then
      echo "" && say "${RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file" "log"
      rm -f "${delegation_cert_file}"
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        if ! encryptFile "${pool_coldkey_vk_file}" "${password}" || \
            ! encryptFile "${pay_payment_sk_file}" "${walletpassword}" || \
            ! encryptFile "${staking_vk_file}" "${walletpassword}" || \
            ! encryptFile "${staking_sk_file}" "${walletpassword}"; then
          echo "" && say "${RED}ERROR${NC}: failure during key encryption!" "log"
          say "${ORANGE}Please make sure all of these keys are encrypted for wallet ${wallet_name} and pool ${pool_name}, else manually re-encrypt!${NC}"
          say "File should have extension .gpg"
          say "${pool_coldkey_vk_file}.gpg" "log"
          say "${pay_payment_sk_file}.gpg" "log"
          say "${staking_vk_file}.gpg" "log"
          say "${staking_sk_file}.gpg" "log"
          # No need to continue as we failed to decrypt some of the files
        fi
      fi
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    # Encrypt keys before we wait for tx to go through
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      if ! encryptFile "${pool_coldkey_vk_file}" "${password}" || \
          ! encryptFile "${pay_payment_sk_file}" "${walletpassword}" || \
          ! encryptFile "${staking_vk_file}" "${walletpassword}" || \
          ! encryptFile "${staking_sk_file}" "${walletpassword}"; then
        echo "" && say "${RED}ERROR${NC}: failure during key encryption!" "log"
        say "${ORANGE}Please make sure all of these keys are encrypted for wallet ${wallet_name} and pool ${pool_name}, else manually re-encrypt!${NC}"
        say "File should have extension .gpg"
        say "${pool_coldkey_vk_file}.gpg" "log"
        say "${pay_payment_sk_file}.gpg" "log"
        say "${staking_vk_file}.gpg" "log"
        say "${staking_sk_file}.gpg" "log"
        # No need to continue as we failed to decrypt some of the files
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
    fi

    waitNewBlockCreated

    echo ""
    say "--- Balance Check Source Address -------------------------------------------------------" "log"
    getBalance "$(cat ${stakepayment_addr_file})"

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      echo ""
      say "${ORANGE}WARN${NC}: Balance missmatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))" "log"
      waitNewBlockCreated
      echo ""
      say "--- Balance Check Source Address -------------------------------------------------------" "log"
      getBalance "$(cat ${stakepayment_addr_file})"
    done

    say "Wallet: ${wallet_name}" "log"
    say "Payment Address: $(cat ${stakepayment_addr_file})" "log"
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
  echo "   Pool Management"
  echo ""
  echo "   1) new"
  echo "   2) register"
  echo "   h) home"
  echo "   q) quit"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  while true; do
    read -r -n 1 -p "What pool operation would you like to perform? (1-2): " SUBCOMMAND
    echo ""
    case ${SUBCOMMAND:0:1} in
      1) SUBCOMMAND="new" && break
        ;;
      2) SUBCOMMAND="register" && break
        ;;
      h) break
        ;;
      q) clear && exit
        ;;
      *) say ">>> Invalid Selection"
        ;;
    esac
  done
  case $SUBCOMMAND in
    new)

    clear
    echo " >> POOL >> NEW"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    read -r -p "Pool Name: " pool_name
    echo ""
    mkdir -p "${POOL_FOLDER}/${pool_name}"

    pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
    pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
    pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
    pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"

    if [[ -f "${pool_hotkey_vk_file}" ]]; then
      say "${RED}WARN${NC}: A pool ${GREEN}$pool_name${NC} already exists"
      say "      Choose another name or delete the existing one"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi
    ${CCLI} shelley node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
    ${CCLI} shelley node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter "${pool_opcert_counter_file}"
    ${CCLI} shelley node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter "${pool_opcert_counter_file}" --kes-period 0 --out-file "${pool_opcert_file}"
    ${CCLI} shelley node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"

    ## TODO: Should we encrypt any more of the keys?

    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      trap 'rm -rf ${POOL_FOLDER:?}/${pool_name}' INT TERM
      say " -- Pool ${GREEN}${pool_name}${NC} Password --"
      getPassword confirm # $password variable populated by getPassword function
      if ! encryptFile "${pool_coldkey_vk_file}" "${password}" || \
          ! encryptFile "${pool_coldkey_sk_file}" "${password}"; then
        rm -rf "${POOL_FOLDER:?}/${pool_name}"
        echo "" && say "${RED}ERROR${NC}: failure during pool cold key encryption, removing newly created ${GREEN}$pool_name${NC} pool" "log"
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
    fi

    say "Pool: ${pool_name}" "log"
    say "PoolPubKey: TODO" "log" # TODO: extract from pool_coldkey_vk_file
    say "Start your cardano node with the following:" "log"
    say "--shelley-kes-key ${pool_hotkey_sk_file}  --shelley-vrf-key ${pool_vrf_sk_file} --shelley-operational-certificate ${pool_opcert_file}" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    read -r -n 1 -s -p "press any key to return to home menu" && continue
    ;;

    register)

    clear
    echo " >> POOL >> REGISTER"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    say "Select Pool:"
    select pool_name in $(find ${POOL_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${pool_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""

    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      say " -- Pool ${GREEN}${pool_name}${NC} Password --"
      getPassword # $password variable populated by getPassword function
      poolpassword=$password # Save pool credentials password
      echo ""
    fi

    saved_pledge="${POOL_FOLDER}/${pool_name}/${POOL_SAVED_PLEDGE_FILENAME}"
    pledgeada=50000 # default pledge
    if [[ -f "${saved_pledge}" ]]; then
      pledgeada="$(cat ${saved_pledge})"
    fi
    read -r -p "Pledge in ADA (default: ${pledgeada}): " pledgeenter
    if [[ -n "${pledgeenter}" ]]; then
      pledgeada=$pledgeenter
    fi
    echo "${pledgeada}" > ${saved_pledge}

    saved_margin="${POOL_FOLDER}/${pool_name}/${POOL_SAVED_MARGIN_FILENAME}"
    margin=0.07 # default margin
    if [[ -f "${saved_margin}" ]]; then
      margin="$(cat ${saved_margin})"
    fi
    echo "" && read -r -p "Margin (default: ${margin}): " marginenter
    if [[ -n "${marginenter}" ]]; then
      margin=$marginenter
    fi
    echo "${margin}" > ${saved_margin}

    saved_cost="${POOL_FOLDER}/${pool_name}/${POOL_SAVED_COST_FILENAME}"
    costada=256 # default cost
    if [[ -f "${saved_cost}" ]]; then
      costada="$(cat ${saved_cost})"
    fi
    echo "" && read -r -p "Cost in ADA (default: ${costada}): " costenter
    if [[ -n "${costenter}" ]]; then
      costada=$costenter
    fi
    echo "${costada}" > ${saved_cost}
    echo ""

    say "Select Wallet pledge/reward from:"
    select pledge_wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${pledge_wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""

    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      say " -- Wallet ${GREEN}${pledge_wallet_name}${NC} Password --"
      getPassword # $password variable populated by getPassword function
      echo ""
    fi
    stakepayment_addr_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKEPAY_ADDR_FILENAME}"
    #pay_payment_addr_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    pay_payment_sk_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_PAY_SK_FILENAME}"
    staking_sk_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_SK_FILENAME}"
    staking_vk_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_VK_FILENAME}"

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"

    if [[ ! -f "${stakepayment_addr_file}" ]]; then
      say "${RED}ERROR${NC}: source wallet staking address file not found:" "log"
      say "${stakepayment_addr_file}" "log"
      unset password poolpassword
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    [[ ! -f "${pool_vrf_vk_file}" ]] && {
      say "${RED}ERROR${NC}: pool vrf vk file not found:" "log"
      say "${pool_vrf_vk_file}" "log"
      unset password poolpassword
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    }

    #Encrypted Files
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      if ! decryptFile "${pool_coldkey_vk_file}.gpg" "${poolpassword}" || \
          ! decryptFile "${pool_coldkey_sk_file}.gpg" "${poolpassword}"; then
        say "${RED}ERROR${NC}: failure during key decryption!" "log"
        unset password poolpassword
        # No need to continue as we failed to decrypt some of the files
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      elif ! decryptFile "${pay_payment_sk_file}.gpg" "${password}" || \
          ! decryptFile "${staking_vk_file}.gpg" "${password}" || \
          ! decryptFile "${staking_sk_file}.gpg" "${password}"; then
        say "${RED}ERROR${NC}: Pool decryption successful but failure during wallet key decryption!" "log"
        say "re-encrypting pool cold keys"
        encryptFile "${pool_coldkey_vk_file}" "${poolpassword}"
        encryptFile "${pool_coldkey_sk_file}" "${poolpassword}"
        unset password poolpassword
        # No need to continue as we failed to decrypt some of the files
        echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
      fi
    fi

    #Generated Files
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
    pool_pledgecert_file="${POOL_FOLDER}/${pool_name}/${POOL_PLEDGECERT_FILENAME}"

    say "-- creating registration cert --" "log"
    ${CCLI} shelley stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge $(( pledgeada * 1000000 )) --pool-cost $(( costada * 1000000 )) --pool-margin ${margin} --reward-account-verification-key-file "${staking_vk_file}" --pool-owner-staking-verification-key "${staking_vk_file}" --out-file "${pool_regcert_file}"
    say "-- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --stake-verification-key-file "${staking_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${pool_pledgecert_file}"
    say "-- Sending transaction to chain --" "log"

    if ! registerPool "$(cat ${stakepayment_addr_file})" "${pool_coldkey_sk_file}" "${staking_sk_file}" "${pool_regcert_file}" "${pool_pledgecert_file}" "${pay_payment_sk_file}"; then
      say "${RED}ERROR${NC}: failure during pool registration, removing newly created pledge and registration files" "log"
      rm -f "${pool_regcert_file}" "${pool_pledgecert_file}"
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        if ! encryptFile "${pool_coldkey_vk_file}" "${poolpassword}" || \
            ! encryptFile "${pool_coldkey_sk_file}" "${poolpassword}" || \
            ! encryptFile "${pay_payment_sk_file}" "${password}" || \
            ! encryptFile "${staking_vk_file}" "${password}" || \
            ! encryptFile "${staking_sk_file}" "${password}"; then
          say "${RED}ERROR${NC}: failure during key encryption!" "log"
          say "${ORANGE}Please make sure all of these keys are encrypted for wallet ${wallet_name} and pool ${pool_name}, else manually re-encrypt!${NC}"
          say "File should have extension .gpg"
          say "${pool_coldkey_vk_file}.gpg" "log"
          say "${pool_coldkey_sk_file}.gpg" "log"
          say "${pay_payment_sk_file}.gpg" "log"
          say "${staking_vk_file}.gpg" "log"
          say "${staking_sk_file}.gpg" "log"
        fi
      fi
      echo "" && read -r -n 1 -s -p "press any key to return to home menu" && continue
    fi

    # Encrypt keys before we wait for tx to go through
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      if ! encryptFile "${pool_coldkey_vk_file}" "${poolpassword}" || \
          ! encryptFile "${pool_coldkey_sk_file}" "${poolpassword}" || \
          ! encryptFile "${pay_payment_sk_file}" "${password}" || \
          ! encryptFile "${staking_vk_file}" "${password}" || \
          ! encryptFile "${staking_sk_file}" "${password}"; then
        say "${RED}ERROR${NC}: failure during key encryption!" "log"
        say "${ORANGE}Please make sure all of these keys are encrypted for wallet ${wallet_name} and pool ${pool_name}, else manually re-encrypt!${NC}"
        say "File should have extension .gpg"
        say "${pool_coldkey_vk_file}.gpg" "log"
        say "${pool_coldkey_sk_file}.gpg" "log"
        say "${pay_payment_sk_file}.gpg" "log"
        say "${staking_vk_file}.gpg" "log"
        say "${staking_sk_file}.gpg" "log"
        read -r -n 1 -s -p "press any key to continue"
      fi
    fi
    unset password poolpassword

    waitNewBlockCreated

    say ""
    say "--- Balance Check Source Address -------------------------------------------------------" "log"
    getBalance "$(cat ${pay_payment_addr_file})"

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      say "${ORANGE}WARN${NC}: Balance missmatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))" "log"
      waitNewBlockCreated
      say ""
      say "--- Balance Check Source Address -------------------------------------------------------" "log"
      getBalance "$(cat ${pay_payment_addr_file})"
    done

    say "Wallet: ${wallet_name}" "log"
    say "Payment Address: $(cat ${pay_payment_addr_file})" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    read -r -n 1 -s -p "press any key to return to home menu" && continue

    ;; ###################################################################

  esac

  ;; ###################################################################

esac # main OPERATION
done # main loop
}

##############################################################

main "$@"
