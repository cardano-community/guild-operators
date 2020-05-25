#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2034,SC2143,SC2046
# Creators: gufmar, Scitz0
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
mkdir -p ${TMP_FOLDER} # Create if missing
rm -f ${TMP_FOLDER}/*

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} > ${TMP_FOLDER}/protparams.json || {
  error "failed to query protocol parameters, node running and env parameters correct?"
  exit 1
}

# check for required command line tools
need_cmd "curl"
need_cmd "jq"
[[ "${PROTECT_KEYS}" = "yes" ]] && need_cmd "gpg"

###################################################################

function main {

clear
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "   CNTOOLS v0.1                                 Creators: Scitz0[AHL], gufmar[CLIO1]"
echo ""
echo "   1) update"
echo "   2) wallet  [list|show|remove|decrypt|encrypt]"
echo "   3) funds   [send|delegate]"
echo "   4) pool    [register]"
echo "   q) quit"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
while true; do
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
    q) echo "" && exit
      ;;
    *) say ">>> Invalid Selection"
      ;;
  esac
done

case $OPERATION in

  update) # not ready yet. ToDo when binary releases become available

	error "Sorry! not ready yet in cntools"
  exit 1
  
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

  ;; ###################################################################

  wallet) 

  clear
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "   Wallet Management"
  echo ""
  echo "   1) new"
  echo "   2) list"
  echo "   3) show"
  echo "   4) remove"
  echo "   5) decrypt"
  echo "   6) encrypt"
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
      q) echo "" && exit
        ;;
      *) say ">>> Invalid Selection"
        ;;
    esac
  done
	
	case $SUBCOMMAND in
	  new)
    
    clear
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "   Wallet Type"
    echo ""
    echo "   1) payment  - first step for a new wallet"
    echo "   2) staking  - upgrade existing payment wallet"
    echo "                 a payment wallet need to exist for before upgrade"
    echo "                 make sure there are funds available in payment wallet before upgrade"
    echo ""
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
        q) echo "" && exit
          ;;
        *) say ">>> Invalid Selection"
          ;;
      esac
    done
    
    case $wallet_type in
      payment)
      
      clear
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
        exit 1
      fi
      
      ${CCLI} shelley address key-gen --verification-key-file "${payment_vk_file}" --signing-key-file "${payment_sk_file}"
      ${CCLI} shelley address build --payment-verification-key-file "${payment_vk_file}" > "${payment_addr_file}"
      
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        trap "rm -rf ${WALLET_FOLDER:?}/${wallet_name}" INT TERM
        getPassword confirm # $password variable populated by getPassword function
        if ! encryptFile "${payment_vk_file}" "${password}" || \
           ! encryptFile "${payment_sk_file}" "${password}"; then
          rm -rf "${WALLET_FOLDER:?}/${wallet_name}"
          exit 1
        fi
      fi
      
      say "Wallet: ${wallet_name}" "log"
      say "Payment Address: $(cat ${payment_addr_file})" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      
      ;; ###################################################################
	
      staking)
      
      echo ""
      error "Sorry! not ready yet in cntools"
      exit 1
      
      clear
      say "Select Wallet:"
      select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do 
        test -n "${wallet_name}" && break
        say ">>> Invalid Selection (ctrl+c to quit)"
      done

      # Wallet key filenames
      payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
      payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
      staking_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_VK_FILENAME}"
      staking_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_SK_FILENAME}"
      staking_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_ADDR_FILENAME}"
      staking_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_CERT_FILENAME}"
      
      if [[ ! -f "${payment_addr_file}" ]]; then
        say "${RED}WARN${NC}: No payment wallet found with name: ${GREEN}$wallet_name${NC}"
        say "      A payment wallet with funds available needed to upgrade to staking"
        exit 1
      elif [[ -f "${staking_addr_file}" ]]; then
        say "${RED}WARN${NC}: A staking wallet ${GREEN}$wallet_name${NC} already exists"
        say "      Choose another name or delete the existing one"
        exit 1
      fi
      
      ${CCLI} shelley stake-address key-gen --verification-key-file "${staking_vk_file}" --signing-key-file "${staking_sk_file}"
      ${CCLI} shelley stake-address build --staking-verification-key-file "${staking_vk_file}" > "${staking_addr_file}"
      ${CCLI} shelley stake-address registration-certificate --staking-verification-key-file "${staking_vk_file}" --out-file "${staking_cert_file}"
      
      # Decrypt payment signing key if needed, reencrypted together with staking keys later
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        [[ ! -f "${payment_sk_file}.gpg" ]] && {
          error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${payment_sk_file}.gpg"
          exit 1
        }
        echo ""
        getPassword # $password variable populated by getPassword function
        if ! decryptFile "${payment_sk_file}.gpg" "${password}"; then
          unset password
          exit 1
        fi
      fi
      
      # Register on chain      
      if ! registerStaking "$(cat ${payment_addr_file})" "${payment_sk_file}" "${staking_sk_file}" "${staking_cert_file}"; then
        error "failure during staking key registration, removing newly created staking keys"
        rm -f "${staking_vk_file}" "${staking_sk_file}" "${staking_addr_file}" "${staking_cert_file}"
        [[ "${PROTECT_KEYS}" = "yes" ]] && encryptFile "${payment_sk_file}" "${password}"
        exit 1
      fi
      
      # Encrypt keys before we wait for tx to go through
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        if ! encryptFile "${staking_vk_file}" "${password}" || \
           ! encryptFile "${staking_sk_file}" "${password}" || \
           ! encryptFile "${staking_cert_file}" "${password}" || \
           ! encryptFile "${payment_sk_file}" "${password}"; then
          error "failure during key encryption!"
        fi
      fi
      
      waitNewBlockCreated

      say ""
      say "--- Balance Check Source Address -------------------------------------------------------" "log"
      getBalance ${sAddr}

      while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
        say ""
        error "Balance missmatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))" "log"
        waitNewBlockCreated
        say ""
        say "--- Balance Check Source Address -------------------------------------------------------" "log"
        getBalance ${sAddr}
      done
      
      say "Wallet: ${WALLET_NAME}" "log"
      say "Payment Address: $(cat ${payment_addr_file})" "log"
      say "Staking Address: $(cat ${staking_addr_file})" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      
      ;; ###################################################################
      
    esac
    
	  ;; ###################################################################
	
	  list)
    clear
	  
		for wallet_folder_name in "${WALLET_FOLDER}"/*/
		do
			wallet_name=${wallet_folder_name%*/} 
			if [ -f "${wallet_folder_name}${WALLET_PAY_ADDR_FILENAME}" ]; then
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
				payment_addr_file=$(cat "${wallet_folder_name}${WALLET_PAY_ADDR_FILENAME}")
				say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
				echo ""
        say "Payment Address: ${payment_addr_file}"
				say "Balance:"
        getBalance ${payment_addr_file}
        echo ""
        if [ -f "${wallet_folder_name}${WALLET_STAKING_ADDR_FILENAME}" ]; then
          staking_addr_file=$(cat "${wallet_folder_name}${WALLET_STAKING_ADDR_FILENAME}")
          say "Reward Address:  ${staking_addr_file}"
          say "Balance:"
          getBalance ${staking_addr_file}
          echo ""
        fi
			else
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
				say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
				say "${RED}WARN${NC}: missing wallet address file:"
				say "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
        echo ""
			fi
		done
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		
	  ;; ###################################################################
	
	  show)
    clear
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
      if [ -f "${staking_addr_file}" ]; then
        staking_addr=$(cat "${staking_addr_file}")
        say "Reward Address:  ${staking_addr}"
        say "Balance:"
        getBalance ${staking_addr}
        echo ""
      fi
		else
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
			say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
			say "${RED}WARN${NC}: missing wallet address file:"
			say "${payment_addr_file}"
			echo ""
		fi
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		
	  ;; ###################################################################
	
	  remove)
    clear
    # TODO - Make sure staking address is empty as well !!!!
    say "Select Wallet:"
		select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do 
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done

    # Wallet key filenames
    payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"

		if [ -f "${payment_addr_file}" ]; then
      getBalance $(cat ${payment_addr_file}) >/dev/null
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
		
	  ;; ###################################################################
    
    decrypt)
    clear
    say "Select Wallet:"
		select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do 
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""
    
    if [[ ! -d "${WALLET_FOLDER}/${wallet_name}" ]]; then
      say "Wallet: ${GREEN}${WALLET_NAME##*/}${NC} "
      say "${RED}WARN${NC}: wallet not found"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      exit 1
    fi
    
    # Wallet key filenames
    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    staking_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_VK_FILENAME}"
    staking_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_SK_FILENAME}"
    staking_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_CERT_FILENAME}"
    
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
    
    [[ ${keysDecrypted} -eq 0 ]] && exit 1
		
		say "Wallet decrypted: ${wallet_name}" "log"
    say "Files decrypted: ${keysDecrypted}" "log"
		echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo ""

	  ;; ###################################################################
    
    encrypt)
    clear
    say "Select Wallet:"
		select wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do 
      test -n "${wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""
    
    if [[ ! -d "${WALLET_FOLDER}/${wallet_name}" ]]; then
      say "Wallet: ${GREEN}${WALLET_NAME##*/}${NC} "
      say "${RED}WARN${NC}: wallet not found"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      exit 1
    fi
    
    # Wallet key filenames
    payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
    payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    staking_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_VK_FILENAME}"
    staking_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_SK_FILENAME}"
    staking_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKING_CERT_FILENAME}"
    
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
    
    [[ ${keysEncrypted} -eq 0 ]] && exit 1
		
		say "Wallet encrypted: ${wallet_name}" "log"
    say "Files encrypted: ${keysEncrypted}" "log"
		echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo ""

	  ;; ###################################################################

	esac
	  
  ;; ###################################################################

  funds) 
  
  clear
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "   Handle Funds"
  echo ""
  echo "   1) send"
  echo "   2) delegate"
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
      q) echo "" && exit
        ;;
      *) say ">>> Invalid Selection"
        ;;
    esac
  done
	
	case $SUBCOMMAND in
    send)  # [DESTINATION ADDRESS|WALLET] [AMOUNT] [SOURCE WALLET] [optional:--include-fee]
    echo ""
    
    # Destination
    while true; do
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
            error "destination wallet address file not found:" "${d_payment_addr_file}"
            exit 1
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
    echo "" && read -r -p "Amount: " amount
    [[ -z "${amount}" ]] && error "amount can not be empty!" && exit 1
    
    # Source
    echo "" && say "Select Source Wallet:"
    select s_wallet in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do 
      test -n "${s_wallet}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    s_payment_addr_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_ADDR_FILENAME}"
    if [[ ! -f "${s_payment_addr_file}" ]]; then
      error "source wallet address file not found:" "${s_payment_addr_file}"
      exit 1
    fi
    s_addr="$(cat ${s_payment_addr_file})"
    
    # Source Sign Key
    # decrypt signing key if needed and make sure to encrypt again even on failure
    s_payment_sk_file="${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_SK_FILENAME}"
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${s_payment_sk_file}.gpg" ]] && {
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${s_payment_sk_file}.gpg"
        exit 1
      }
      echo ""
      getPassword # $password variable populated by getPassword function
      if ! decryptFile "${s_payment_sk_file}.gpg" "${password}"; then
        unset password
        exit 1
      fi
    fi
    [[ ! -f "${s_payment_sk_file}" ]] && error "source wallet signing key file not found:" "${s_payment_sk_file}"
    
    read -n 1 -r -p "Fee payed by sender (y/n)? " answer
    echo ""
    case ${answer:0:1} in
      n|N ) include_fee="yes"
      ;;
      * ) include_fee="no"
      ;;
    esac

    if ! sendADA "${d_addr}" "${amount}" "${s_addr}" "${s_payment_sk_file}" "${include_fee}"; then 
      delayExit=1
    else
      delayExit=0
    fi
    
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      encryptFile "${s_payment_sk_file}" "${password}" 
      unset password
    fi
    
    [[ ${delayExit} -eq 1 ]] && exit 1
    
    waitNewBlockCreated

    say ""
    say "--- Balance Check Source Address -------------------------------------------------------" "log"
    getBalance ${s_addr}

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      error "Balance missmatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))" "log"
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
    
    ;; ###################################################################
    
    delegate)  # [WALLET NAME] [POOL NAME]
    
    error "Sorry! not ready yet in cntools"
    exit 1
		
	  ;; ###################################################################

	esac

  ;; ###################################################################

  pool)

	error "Sorry! not ready yet in cntools"
  exit 1
  
  ;; ###################################################################

esac # main OPERATION
}
   
##############################################################

main "$@"
