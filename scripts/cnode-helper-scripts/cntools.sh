#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2154
# ,SC2034,SC2143,SC2046,
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

while true; do # Main loop

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

echo "" && read -r -n 1 -s -p "press any key to return to home menu"

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
         trap 'rm -rf ${WALLET_FOLDER:?}/${wallet_name}' INT TERM
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
      echo "" && read -r -n 1 -s -p "press any key to return to home menu"

      ;; ###################################################################

      staking)

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

      say "Wallet: ${wallet_name}" "log"
      say "Payment Address: $(cat ${payment_addr_file})" "log"
      say "Staking Address: $(cat ${staking_addr_file})" "log"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo "" && read -r -n 1 -s -p "press any key to return to home menu"

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
    echo "" && read -r -n 1 -s -p "press any key to return to home menu"
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
    echo "" && read -r -n 1 -s -p "press any key to return to home menu"
	  ;; ###################################################################

	  remove)
    clear
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

		echo "" && read -r -n 1 -s -p "press any key to return to home menu"

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
      say "Wallet: ${GREEN}${wallet_name##*/}${NC} "
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

		echo "" && read -r -n 1 -s -p "press any key to return to home menu"

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
    [[ -z "${amount}" ]] && error "amount can not be empty!" && exit 1

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
      error "source wallet address file not found:" "${s_payment_addr_file}"
      exit 1
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
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${s_payment_sk_file}.gpg"
        exit 1
      }
      echo ""
      getPassword # $password variable populated by getPassword function
      if ! decryptFile "${s_payment_sk_file}.gpg" "${password}"; then
        unset password
        exit 1
      fi
    else
      [[ ! -f "${s_payment_sk_file}" ]] && error "source wallet signing key file not found:" "${s_payment_sk_file}" && exit 1

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

    echo "" && read -r -n 1 -s -p "press any key to return to home menu"

    ;; ###################################################################

    delegate)  # [WALLET NAME] [POOL NAME]

    error "Sorry! not ready yet in cntools"
    exit 1

	  ;; ###################################################################

	esac

  ;; ###################################################################

  pool)

  clear
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "   Pool Management"
  echo ""
  echo "   1) new"
  echo "   2) register"
  echo "   q) quit"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  while true; do
    read -r -n 1 -p "What pool operation would you like to perform? (1): " SUBCOMMAND
    echo ""
    case ${SUBCOMMAND:0:1} in
      1) SUBCOMMAND="new" && break
        ;;
      2) SUBCOMMAND="register" && break
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
    read -r -p "Name of new pool: " pool_name
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
      exit 1
    fi
    ${CCLI} shelley node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}"
    ${CCLI} shelley node key-gen --verification-key-file "${pool_coldkey_vk_file}" --signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter "${pool_opcert_counter_file}"
    ${CCLI} shelley node issue-op-cert --hot-kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter "${pool_opcert_counter_file}" --kes-period 0 --out-file "${pool_opcert_file}"
    ${CCLI} shelley node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}"


    ## TODO: Should we encrypt any more of the keys?

    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      trap "rm -rf ${POOL_FOLDER:?}/${pool_name}" INT TERM
      getPassword confirm # $password variable populated by getPassword function
      if ! encryptFile "${pool_coldkey_vk_file}" "${password}" || \
          ! encryptFile "${pool_coldkey_sk_file}" "${password}"; then
        rm -rf "${POOL_FOLDER:?}/${pool_name}"
        exit 1
      fi
    fi

    say "Pool: ${pool_name}" "log"
    say "PoolPubKey: TODO" "log"
    say "Start your cardano node with the following:" "log"
    say "--shelley-kes-key ${pool_hotkey_sk_file}  --shelley-vrf-key ${pool_vrf_sk_file} --shelley-operational-certificate ${pool_opcert_file}" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    exit 1
    ;;

    register)

    clear
    say "Select Pool:"
    select pool_name in $(find ${POOL_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${pool_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""

    if [[ ! -d "${POOL_FOLDER}/${pool_name}" ]]; then
      say "Pool: ${GREEN}${POOL_FOLDER##*/}${NC} "
      say "${RED}WARN${NC}: pool not found"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      exit 1
    fi

    pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${pool_coldkey_vk_file}.gpg" ]] && {
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${pool_coldkey_vk_file}.gpg"
        exit 1
      }
      echo ""
      getPassword # $password variable populated by getPassword function
      if ! decryptFile "${pool_coldkey_vk_file}.gpg" "${password}"; then
        error "Unable to decrypt coldkey vk file" "${pool_coldkey_vk_file}.gpg"
        unset password
        exit 1
      else
        encryptFile "${pool_coldkey_vk_file}" "${password}"  # re-encrypt until we are through UI part
      fi
    fi

    pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${pool_coldkey_sk_file}.gpg" ]] && {
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${pool_coldkey_sk_file}.gpg"
        exit 1
      }
      echo ""
      if ! decryptFile "${pool_coldkey_sk_file}.gpg" "${password}"; then
        error "Unable to decrypt coldkey sk file" "${pool_coldkey_sk_file}.gpg"
        unset password
        exit 1
      else
        encryptFile "${pool_coldkey_sk_file}" "${password}"  # re-encrypt until we are through UI part
      fi
    fi

    poolpassword=$password # Save pool credentials password

    saved_pledge="${POOL_FOLDER}/${pool_name}/${POOL_SAVED_PLEDGE_FILENAME}"
    pledgeada=50000 # default pledge
    if [[ -f "${saved_pledge}" ]]; then
      pledgeada="$(cat ${saved_pledge})"
    fi
    echo "" && read -r -p "Pledge in ADA (default: ${pledgeada}): " pledgeenter
    if [[ ! -z "${pledgeenter}" ]]; then
      pledgeada=$pledgeenter
    fi
    $(echo "${pledgeada}" > ${saved_pledge})

    saved_margin="${POOL_FOLDER}/${pool_name}/${POOL_SAVED_MARGIN_FILENAME}"
    margin=0.07 # default margin
    if [[ -f "${saved_margin}" ]]; then
      margin="$(cat ${saved_margin})"
    fi
    echo "" && read -r -p "Margin (default: ${margin}): " marginenter
    if [[ ! -z "${marginenter}" ]]; then
      margin=$marginenter
    fi
    $(echo "${margin}" > ${saved_margin})

    saved_cost="${POOL_FOLDER}/${pool_name}/${POOL_SAVED_COST_FILENAME}"
    costada=256 # default cost
    if [[ -f "${saved_cost}" ]]; then
      costada="$(cat ${saved_cost})"
    fi
    echo "" && read -r -p "Cost in ADA (default: ${costada}): " costenter
    if [[ ! -z "${costenter}" ]]; then
      costada=$costenter
    fi
    $(echo "${costada}" > ${saved_cost})

    say "Select Wallet to pay fees from:"
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
      unset poolpassword
      exit 1
    fi

    pay_payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    if [[ ! -f "${pay_payment_addr_file}" ]]; then
      error "source wallet address file not found:" "${pay_payment_addr_file}"
      unset poolpassword
      exit 1
    fi
    pay_addr="$(cat ${pay_payment_addr_file})"


    pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${pay_payment_sk_file}.gpg" ]] && {
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${pay_payment_sk_file}.gpg"
        unset poolpassword
        exit 1
      }
      echo ""
      getPassword # $password variable populated by getPassword function
      #password="Hannam11!"
      if ! decryptFile "${pay_payment_sk_file}.gpg" "${password}"; then
        error "Unable to decrypt coldkey sk file" "${pay_payment_sk_file}.gpg"
        unset password
        unset poolpassword
        exit 1
      else
        [[ ! -f "${pay_payment_sk_file}" ]] && error "source wallet signing key file not found:" "${pay_payment_sk_file}"
        encryptFile "${pay_payment_sk_file}" "${password}"  # re-encrypt until we are through UI part
      fi
    fi


    paypassword=$password # save off paypassword so we can re-encrypt later



    say "Select Wallet pledge/reward from:"
		select pledge_wallet_name in $(find ${WALLET_FOLDER}/* -maxdepth 1 -type d | sed 's#.*/##'); do
      test -n "${pledge_wallet_name}" && break
      say ">>> Invalid Selection (ctrl+c to quit)"
    done
    echo ""

    if [[ ! -d "${WALLET_FOLDER}/${pledge_wallet_name}" ]]; then
      say "Wallet: ${GREEN}${WALLET_NAME##*/}${NC} "
      say "${RED}WARN${NC}: wallet not found"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      exit 1
    fi

    staking_addr_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_ADDR_FILENAME}"
    if [[ ! -f "${staking_addr_file}" ]]; then
      error "source wallet does not have a staking address:" "${staking_addr_file}"
      unset paypassword
      unset poolpassword
      exit 1
    fi
    stake_addr="$(cat ${staking_addr_file})"


    staking_sk_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_SK_FILENAME}"
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${staking_sk_file}.gpg" ]] && {
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${staking_sk_file}.gpg"
        unset paypassword
        unset poolpassword
        exit 1
      }
      echo ""
      getPassword # $password variable populated by getPassword function
      if ! decryptFile "${staking_sk_file}.gpg" "${password}"; then
        error "Unable to decrypt coldkey sk file" "${staking_sk_file}.gpg"
        unset password
        unset paypassword
        unset poolpassword
        exit 1
      else
        [[ ! -f "${staking_sk_file}" ]] && error "staking wallet signing key file not found:" "${staking_sk_file}"
        encryptFile "${staking_sk_file}" "${password}"  # re-encrypt until we are through UI part
      fi
    fi

    staking_vk_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_VK_FILENAME}"
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${staking_vk_file}.gpg" ]] && {
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${staking_vk_file}.gpg"
        exit 1
      }
      echo ""
      if ! decryptFile "${staking_vk_file}.gpg" "${password}"; then
        error "Unable to decrypt coldkey sk file" "${staking_vk_file}.gpg"
        unset password
        unset paypassword
        unset poolpassword
        exit 1
      else
        [[ ! -f "${staking_vk_file}" ]] && error "staking wallet verification key file not found:" "${staking_vk_file}"
        encryptFile "${staking_vk_file}" "${password}"  # re-encrypt until we are through UI part
      fi
    fi

    #Unencrypted Files
    #pay_payment_addr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
    [[ ! -f "${pay_payment_addr_file}" ]] && error "payment address file not found:" "${pay_payment_addr_file}"

    #staking_addr_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_ADDR_FILENAME}"
    [[ ! -f "${staking_addr_file}" ]] && error "staking address file not found:" "${staking_addr_file}"

    pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
    [[ ! -f "${pool_vrf_vk_file}" ]] && error "pool vrf vk file not found:" "${pool_vrf_vk_file}"

    #Encrypted Files
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      if ! decryptFile "${pool_coldkey_vk_file}.gpg" "${poolpassword}" || \
          ! decryptFile "${pool_coldkey_sk_file}.gpg" "${poolpassword}" || \
          ! decryptFile "${pay_payment_sk_file}.gpg" "${paypassword}" || \
          ! decryptFile "${staking_vk_file}.gpg" "${password}" || \
          ! decryptFile "${staking_sk_file}.gpg" "${password}"; then
        error "failure during key decryption!"
      fi
    fi
    ##pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
    ##pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
    ##pay_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
    ##staking_vk_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_VK_FILENAME}"
    ##staking_sk_file="${WALLET_FOLDER}/${pledge_wallet_name}/${WALLET_STAKING_SK_FILENAME}"

    #Generated Files
    pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
    pool_pledgecert_file="${POOL_FOLDER}/${pool_name}/${POOL_PLEDGECERT_FILENAME}"



    say "-- creating registration cert --" "log"
    ${CCLI} shelley stake-pool registration-certificate --stake-pool-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge $(( pledgeada * 1000000 )) --pool-cost $(( costada * 1000000 )) --pool-margin ${margin} --reward-account-verification-key-file "${staking_vk_file}" --pool-owner-staking-verification-key "${staking_vk_file}" --out-file "${pool_regcert_file}"
    say "-- creating delegation cert --" "log"
    ${CCLI} shelley stake-address delegation-certificate --staking-verification-key-file "${staking_vk_file}" --stake-pool-verification-key-file "${pool_coldkey_vk_file}" --out-file "${pool_pledgecert_file}"
    say "-- Sending transaction to chain --" "log"

    if ! registerPoolAndRewardAndPledge "$(cat ${pay_payment_addr_file})" "${pool_coldkey_sk_file}" "${staking_sk_file}" "${pool_regcert_file}" "${pool_pledgecert_file}" "${pay_payment_sk_file}"; then
      error "failure during pool registration, removing newly created pledge and registration files"
      rm -f "${pool_regcert_file}" "${pool_pledgecert_file}"
      if [[ "${PROTECT_KEYS}" = "yes" ]]; then
        if ! encryptFile "${pool_coldkey_vk_file}" "${poolpassword}" || \
            ! encryptFile "${pool_coldkey_sk_file}" "${poolpassword}" || \
            ! encryptFile "${pay_payment_sk_file}" "${paypassword}" || \
            ! encryptFile "${staking_vk_file}" "${password}" || \
            ! encryptFile "${staking_sk_file}" "${password}"; then
          error "failure during key encryption!"
        fi
      fi
      exit 1
    fi

    # Encrypt keys before we wait for tx to go through
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      if ! encryptFile "${pool_coldkey_vk_file}" "${poolpassword}" || \
          ! encryptFile "${pool_coldkey_sk_file}" "${poolpassword}" || \
          ! encryptFile "${pay_payment_sk_file}" "${paypassword}" || \
          ! encryptFile "${staking_vk_file}" "${password}" || \
          ! encryptFile "${staking_sk_file}" "${password}"; then
        error "failure during key encryption!"
      fi
    fi

    waitNewBlockCreated

    say ""
    say "--- Balance Check Source Address -------------------------------------------------------" "log"
    getBalance $(cat ${pay_payment_addr_file})

    while [[ ${TOTALBALANCE} -ne ${newBalance} ]]; do
      say ""
      error "Balance missmatch, transaction not included in latest block ($(numfmt --grouping ${TOTALBALANCE}) != $(numfmt --grouping ${newBalance}))" "log"
      waitNewBlockCreated
      say ""
      say "--- Balance Check Source Address -------------------------------------------------------" "log"
      getBalance $(cat ${pay_payment_addr_file})
    done

    say "Wallet: ${WALLET_NAME}" "log"
    say "Payment Address: $(cat ${pay_payment_addr_file})" "log"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""

    ;; ###################################################################

  esac

  ;; ###################################################################

esac # main OPERATION
done # main loop
}

##############################################################

main "$@"
