#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2034,SC2143,SC2046
# Creators: gufmar, Scitz0
# 2020-05-19 cntools initial release (concept)
# 2020-05-24 helper functions moved cnlibrary & configuration to env file

########## Global tasks ###########################################

# Global tasks and parameters
# Start with a clean slate
rm -f /tmp/fullUtxo.out
rm -f /tmp/balance.txt
rm -f /tmp/protparams.json
rm -f /tmp/tx.signed
rm -f /tmp/tx.raw

# get config values from common env file
. "$(dirname $0)"/env

# get helper functions from library file
. "$(dirname $0)"/cntoolslibrary

# Get protocol parameters and save to /tmp/protparams.json
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} > /tmp/protparams.json || {
  error "failed to query protocol parameters, node running and env parameters correct?"
  exit 1
}

# Error handling, catch EXIT/ERR from functions
catch () {
  say ""
  say "Debug: 'eval $1'"
  eval "$1"
}

###################################################################

scriptName=$(basename "$0")

usage() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} update [optional:DESIRED_RELEASE_TAG]"
  echo ""
  echo "   ${scriptName} wallet new [WALLET NAME]"
  echo "   ${scriptName} wallet list"
  echo "   ${scriptName} wallet show [WALLET NAME]"
  echo "   ${scriptName} wallet remove [WALLET NAME]"
  echo "   ${scriptName} wallet [decrypt|encrypt] [WALLET NAME]"
  echo ""
  echo "   ${scriptName} funds send [DESTINATION ADDRESS|WALLET] [AMOUNT] [SOURCE WALLET] [optional:--include-fee]"
  echo "   ${scriptName} funds delegate [WALLET NAME] [POOL NAME]"
  echo ""
  echo "   ${scriptName} pool register [POOL NAME] [WALLET OWNER] [WALLET REWARDS] "
  echo "                    [TAX FIXED] [TAX PERMILLE] [optional:TAX LIMIT]"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

# SUBCOMMAND usage
usageWalletNew() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} wallet new [WALLET_NAME]"
  echo ""
  echo "   Wallet Name           >   Name of new wallet"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

usageWalletShow() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} wallet show [WALLET_NAME]"
  echo ""
  echo "   Wallet Name           >   Name of wallet to show"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

usageWalletRemove() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} wallet remove [WALLET_NAME]"
  echo ""
  echo "   Wallet Name           >   Name of wallet to remove"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

usageWalletCrypt() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} wallet [decrypt|encrypt] [WALLET NAME]"
  echo ""
  echo "   decrypt               >   Decrypt wallet KES/VRF keys"
  echo "   encrypt               >   Encrypt wallet KES/VRF keys"
  echo "   Wallet Name           >   Name of wallet"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

usageFundsSend() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} send [DESTINATION ADDRESS|WALLET] [AMOUNT] [SOURCE WALLET] [optional:--include-fee]"
  echo ""
  echo "   Dest. Addr/Wallet     >   Address or destination wallet name"
  echo "   Amount                >   Amount in ADA, number(fraction of ADA valid) or the string 'all'"
  echo "   Source Wallet         >   Source wallet name"
  echo "   --include-fee         >   Optional argument to specify that amount to send should be reduced by fee instead of payed by sender"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

usageFundsDelegate() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} funds delegate [WALLET NAME] [POOL NAME]"
  echo ""
  echo "   Wallet Name           >   Source wallet name to delegate from"
  echo "   Pool Name             >   Name or Address of pool to delegate to"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

usagePoolRegister() {
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "Usage:"
  echo ""
  echo "   ${scriptName} pool register [POOL NAME] [WALLET OWNER] [WALLET REWARDS] "
  echo "                    [TAX FIXED] [TAX PERMILLE] [optional:TAX LIMIT]"
  echo ""
  echo "   Note: you can use the same wallet for owner and rewards"
  echo ""
  echo "   Pool Name             >   The name of pool to register"
  echo "   ... TBD"
  echo ""
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

###################################################################

function main {

if [ ${#} -lt 1 ]; then
  usage ${0}
  exit 1
fi

# check for required command line tools
need_cmd "curl"
need_cmd "jq"
[[ "${PROTECT_KEYS}" = "yes" ]] && need_cmd "gpg"

OPERATION=${1}
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

	if [ ${#} -lt 2 ]; then
    usage
    exit 1
  fi
  
  SUBCOMMAND=${2}
	
	case $SUBCOMMAND in
	  new) # [WALLET_NAME]
	
		if [ ${#} -lt 3 ]; then
			usageWalletNew
			exit 1
		fi

		WALLET_NAME=${3}
		mkdir -p "${WALLET_FOLDER}/${WALLET_NAME}"
		
		if [[ -f "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}" ]]; then
			say "${RED}WARN${NC}: A wallet $WALLET_NAME already exists"
			say "      Choose another name or delete the existing one"
			exit 1
		fi
		
		# create a personal wallet key
		MY_vkey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_VKS_FILENAME}"
		MY_skey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_SKS_FILENAME}"
		MY_payment_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}"
		
		${CCLI} shelley address key-gen --verification-key-file "${MY_vkey_file}" --signing-key-file "${MY_skey_file}"
		${CCLI} shelley address build --payment-verification-key-file "${MY_vkey_file}" > "${MY_payment_file}"
    
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      trap "catch 'rm -rf ${WALLET_FOLDER}/${WALLET_NAME}'" INT TERM
      encryptFile "${MY_vkey_file}" "${MY_skey_file}"
      [[ $? -ne 0 ]] && {
        rm -rf "${WALLET_FOLDER}/${WALLET_NAME}"
        exit 1
      }
    fi
		
		say "New wallet: ${WALLET_NAME}" "log"
		say "Address:    $(cat $MY_payment_file)" "log"
		echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo ""

	  ;; ###################################################################
	
	  list) # no parameters
	  
		for WALLET_FOLDER_NAME in "${WALLET_FOLDER}"/*/
		do
			WALLET_NAME=${WALLET_FOLDER_NAME%*/} 
			if [ -f "${WALLET_FOLDER_NAME}${WALLET_PAY_FILENAME}" ]; then
        echo ""
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
				WALLET_ADDRESS=$(cat ${WALLET_FOLDER_NAME}${WALLET_PAY_FILENAME})
				say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
				say "Address: ${WALLET_ADDRESS}"
				say "Balance:"
        getBalance ${WALLET_ADDRESS}
        echo ""
			else
        echo ""
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
				say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
				say "${RED}WARN${NC}: missing wallet address file:"
				say "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}"
        echo ""
			fi
		done
		
	  ;; ###################################################################
	
	  show) # [WALLET_NAME]
		
    if [ ${#} -lt 3 ]; then
			usageWalletShow
			exit 1
		fi
    
		WALLET_NAME=${3}
		
		if [ -f "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}" ]; then
      echo ""
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
			WALLET_ADDRESS=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}")
			say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
			say "  Address: ${WALLET_ADDRESS}"
			say "  Balance:"
      getBalance ${WALLET_ADDRESS}
			echo ""
		else
      echo ""
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
			say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
			say "${RED}WARN${NC}: missing wallet address file:"
			say "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}"
			echo ""
		fi
		
	  ;; ###################################################################
	
	  remove) # [WALLET_NAME]
    
    if [ ${#} -lt 3 ]; then
			usageWalletRemove
			exit 1
		fi

		WALLET_NAME=${3}

		if [ -f "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}" ]; then
			WALLET_ADDRESS=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}")
			WALLET_BALANCE=$(${CCLI} shelley query filtered-utxo --testnet-magic $NWMAGIC --address ${WALLET_ADDRESS} | tail -n +3 | awk '{ print $3 }' )
			WALLET_BALANCE_NICE=$(printf "%'d Lovelaces" ${WALLET_BALANCE})
			echo "DBG: " $WALLET_BALANCE
			echo "DBG: " $WALLET_BALANCE_NICE
			if [[ ${WALLET_BALANCE} == "" ]]; then
				say "INFO: This wallet appears to be empty"
				say "${RED}WARN: By deleting this keys you can no longer access the wallet${NC}"
				read -n 1 -r -p "Are you sure to delete secret/public key pairs (y/n)? " answer
				case ${answer:0:1} in
					y|Y )
						rm -rf "${WALLET_FOLDER:?}/${WALLET_NAME}"
						say "\nremoved ${WALLET_NAME}"
					;;
					* )
						echo -e "\nskipped removal process for $WALLET_NAME"
					;;
				esac
			else
				if [[ ${WALLET_BALANCE} == "0" ]]; then
					say "INFO: found local wallet file with current balance 0"
					rm -r "${WALLET_FOLDER:?}/${WALLET_NAME}"
					echo "removed ${WALLET_NAME}"
				else
					say "${RED}WARN${NC}: this wallet file has a balance of ${WALLET_BALANCE_NICE}"
					say "${RED}WARN${NC}: By deleting this keys you can no longer access the wallet"
					read -n 1 -r -p "      Are you sure to delete secret/public key pairs (y/n)? " answer
					case ${answer:0:1} in
						y|Y )
							rm -rf "${WALLET_FOLDER:?}/${WALLET_NAME}"
							echo -e "\nremoved ${WALLET_NAME}"
						;;
						* )
							echo -e "\nskipped removal process for $WALLET_NAME"
						;;
					esac
				fi
			fi
		else
			say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
			say "${RED}WARN${NC}: missing wallet address file:"
			say "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}"
			echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
			echo ""
		fi
		
	  ;; ###################################################################
    
    decrypt) # [WALLET_NAME]
	
		if [[ ${#} -lt 3 ]]; then
			usageWalletCrypt
			exit 1
		fi

		WALLET_NAME=${3}
    # wallet keys
		MY_vkey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_VKS_FILENAME}"
		MY_skey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_SKS_FILENAME}"
    
    if [[ -f "${MY_vkey_file}" && -f "${MY_skey_file}" ]]; then
      say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
      say "${RED}WARN${NC}: wallet not encrypted"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      exit 1
    fi
    
    password="" # password variable, populated by getPassword function
    if [[ -f "${MY_vkey_file}.gpg" ]]; then
      getPassword
      decryptFile "${MY_vkey_file}.gpg" "${password}"
    elif [[ -f "${MY_vkey_file}" ]]; then
      say "VKS key already decrypted"
    else
      error "unable to find VKS key, wallet exist?"
      say "${MY_vkey_file}"
      exit 1
    fi
    
    if [[ -f "${MY_skey_file}.gpg" ]]; then
      [[ -z "${password}" ]] && getPassword
      decryptFile "${MY_skey_file}.gpg" "${password}"
    elif [[ -f "${MY_skey_file}" ]]; then
      say "SKS key already decrypted"
    else
      error "unable to find SKS key, wallet exist?"
      say "${MY_skey_file}"
      exit 1
    fi
    unset password
		
		say "Wallet decrypted: ${WALLET_NAME}" "log"
    say "VKS: ${MY_vkey_file}" "log"
    say "SKS: ${MY_skey_file}" "log"
		echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo ""

	  ;; ###################################################################
    
    encrypt) # [WALLET_NAME]
	
		if [[ ${#} -lt 3 ]]; then
			usageWalletCrypt
			exit 1
		fi

		WALLET_NAME=${3}
    # wallet keys
		MY_vkey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_VKS_FILENAME}"
		MY_skey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_SKS_FILENAME}"
    
    if [[ -f "${MY_vkey_file}.gpg" && -f "${MY_skey_file}.gpg" ]]; then
      say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
      say "${RED}WARN${NC}: wallet already encrypted"
      echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
      echo ""
      exit 1
    fi
    
    password="" # password variable, populated by getPassword function
    if [[ -f "${MY_vkey_file}" ]]; then
      getPassword confirm
      encryptFile "${MY_vkey_file}" "${password}"
    elif [[ -f "${MY_vkey_file}.gpg" ]]; then
      say "VKS key already encrypted"
    else
      error "unable to find VKS key, wallet exist?"
      say "${MY_vkey_file}"
      exit 1
    fi
    
    if [[ -f "${MY_skey_file}" ]]; then
      [[ -z "${password}" ]] && getPassword confirm
      encryptFile "${MY_skey_file}" "${password}"
    elif [[ -f "${MY_skey_file}.gpg" ]]; then
      say "SKS key already encrypted"
    else
      error "unable to find SKS key, wallet exist?"
      say "${MY_skey_file}"
      exit 1
    fi
    unset password
		
		say "Wallet encrypted: ${WALLET_NAME}" "log"
    say "VKS: ${MY_vkey_file}.gpg" "log"
    say "SKS: ${MY_skey_file}.gpg" "log"
		echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo ""

	  ;; ###################################################################

	  *)
		usage
		exit 1
	  ;;

	esac
	  
  ;; ###################################################################

  funds) 

	if [ ${#} -lt 2 ]; then
    usage
    exit 1
  fi
  
  SUBCOMMAND=${2}
	
	case $SUBCOMMAND in
    send)  # [DESTINATION ADDRESS|WALLET] [AMOUNT] [SOURCE WALLET] [optional:--include-fee]
  
    if [ ${#} -lt 5 ]; then
      usageFundsSend
      exit 1
    fi
    
    # DESTINATION ADDRESS|WALLET
    # assume address if 72+ characters
    [[ ${#3} -ge "72" ]] && dAddr="$3" || {
      dAddr="${WALLET_FOLDER}/${3}/${WALLET_PAY_FILENAME}"
      [[ -f "${dAddr}" ]] && dAddr="$(cat ${dAddr})" || {
        error "destination wallet address file not found:" "${dAddr}"
        exit 1
      }
    }
    
    # SOURCE WALLET
    sAddr="${WALLET_FOLDER}/${5}/${WALLET_PAY_FILENAME}"
    sSignKey="${WALLET_FOLDER}/${5}/${WALLET_SKS_FILENAME}"
    [[ -f "${sAddr}" ]] && sAddr="$(cat ${sAddr})" || {
      error "source wallet address file not found:" "${sAddr}"
      exit 1
    }
    # Decrypt signing key if needed and make sure to encrypt again even on failure
    if [[ "${PROTECT_KEYS}" = "yes" ]]; then
      [[ ! -f "${sSignKey}.gpg" ]] && {
        error "'PROTECT_KEYS=yes' but no gpg encrypted file found on disk:" "${sSignKey}.gpg"
        exit 1
      }
      password="" # password variable, populated by getPassword function
      getPassword
      decryptFile "${sSignKey}.gpg" "${password}"
      [[ $? -ne 0 ]] && unset password && exit 1
      trap "catch 'encryptFile ${sSignKey} ${password}'" INT TERM
    fi
    [[ ! -f "${sSignKey}" ]] && error "source wallet signing key file not found:" "${sSignKey}"
    
    sendADA "${dAddr}" "${4}" "${sAddr}" "${sSignKey}" "${6}"
    [[ $? -ne 0 ]] && delayExit=1
    
    [[ "${PROTECT_KEYS}" = "yes" ]] && encryptFile "${sSignKey}" "${password}" && unset password
    
    [[ ${delayExit} -eq 1 ]] && exit 1
    
    newBalanceADA=$(echo "${newBalance}/1000000" | bc -l | sed '/\./ s/\.\{0,1\}0\{1,\}$//')

    say ""
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say "Transaction" "log"
    say "  From:       ${5}" "log"
    say "  Amount:     $(numfmt --grouping ${4})" "log"
    say "  To:         ${3}" "log"
    say "  Fees:       $(numfmt --grouping ${minFee}) Lovelaces" "log"
    say "  Balance:    $(numfmt --grouping ${newBalance}) Lovelaces ($(numfmt --grouping ${newBalanceADA}) ADA)" "log"
    say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    say ""
    
    ;; ###################################################################
    
    delegate)  # [WALLET NAME] [POOL NAME]
    
    # TODO implement for cardano-node/cli
    echo "Sorry! not ready yet in cntools"
    exit 1
    
    if [ ${#} -lt 4 ]; then
			usageFundsDelegate
			exit 1
		fi
		
		WALLET_NAME=${3}
		POOL_NAME=${4}
		
		if [ -f "${POOL_FOLDER}/${POOL_NAME}/stake_pool.id" ]; then
			POOLID=$(cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool.id")
		else
			if [ ${#POOL_NAME} -eq "64" ]; then # looks like a 64 char pool ID
				POOLID=${POOL_NAME}
				POOL_DATA=$(${CCLI} rest v0 stake-pool get ${POOLID})
				echo -e "Pool data:\n${POOL_DATA}"
				read -p "Delegate to this pool? (y/n)" -n 1 -r
				echo    # (optional) move to a new line
				if [[ ! $REPLY =~ ^[Yy]$ ]]; then
					exit 1
				fi
			else
				echo "Error: no pool $POOL_NAME found"
				exit 1
			fi
		fi
		
		if [ -f "${WALLET_FOLDER}/${WALLET_NAME}/ed25519.account" ]; then
			SOURCE_ADDRESS=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/ed25519.account")
			SOURCE_KEY=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/ed25519.key")
			SOURCE_PUB=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/ed25519.pub")
			SOURCE_FILE="${WALLET_FOLDER}/${WALLET_NAME}/ed25519.key"
		else
			echo "Error: no wallet $WALLET_NAME found"
			exit 1
		fi
		SOURCE_BALANCE=$(${CCLI} rest v0 account get "${SOURCE_ADDRESS}" --host "${NODE_REST_URL}" | grep '^value:' | sed -e 's/value: //' )
		SOURCE_BALANCE_NICE=$(printf "%'d Lovelaces" ${SOURCE_BALANCE})
		if (( SOURCE_BALANCE == 0 )); then
			echo "ERROR: fee wallet balance is zero"
			exit 1
		fi
		
		SOURCE_COUNTER=$(${CCLI} rest v0 account get "${SOURCE_ADDRESS}" --host "${NODE_REST_URL}" | grep '^counter:' | sed -e 's/counter: //' )

		# read the nodes blockchain settings (parameters are required for the next transactions)
		settings="$(curl -s ${NODE_REST_URL}/v0/settings)"
		FEE_CONSTANT=$(echo $settings | jq -r .fees.constant)
		FEE_COEFFICIENT=$(echo $settings | jq -r .fees.coefficient)
		if [ -z "$(echo $settings | grep "certificate_pool_registration")" ]; then
			FEE_CERTIFICATE=$(echo $settings | jq -r .fees.certificate)
		else
			FEE_CERTIFICATE=$(echo $settings | jq -r .fees.per_certificate_fees.certificate_stake_delegation)
		fi
		BLOCK0_HASH=$(echo $settings | jq -r .block0Hash)
		AMOUNT_WITH_FEES=$(( FEE_CONSTANT + FEE_COEFFICIENT + FEE_CERTIFICATE ))
		AMOUNT_WITH_FEES_NICE=$(printf "%'d Lovelaces" ${AMOUNT_WITH_FEES})
		if (( SOURCE_BALANCE <= AMOUNT_WITH_FEES )); then
			echo "ERROR: wallet balance is not sufficient to pay the registration fees"
			exit 1
		fi

		if [  -f "${WALLET_FOLDER}/${WALLET_NAME}/stake_delegation_${POOL_NAME}.cert" ]; then
			say "WARN: A stake key for wallet ${WALLET_NAME} already exists"
			exit 1
		fi
		
		# generate a delegation certificate (private wallet > stake pool)
		${CCLI} certificate new stake-delegation ${SOURCE_PUB} ${POOLID} > "${WALLET_FOLDER}/${WALLET_NAME}/stake_delegation_${POOL_NAME}.cert"
		
		TMPDIR=$(mktemp -d)
		STAGING_FILE="${TMPDIR}/staging.$$.transaction"
		${CCLI} transaction new --staging ${STAGING_FILE}
		${CCLI} transaction add-account "${SOURCE_ADDRESS}" "${AMOUNT_WITH_FEES}" --staging "${STAGING_FILE}"
		${CCLI} transaction add-certificate --staging ${STAGING_FILE} $(cat "${WALLET_FOLDER}/${WALLET_NAME}/stake_delegation_${POOL_NAME}.cert")
		${CCLI} transaction finalize --staging ${STAGING_FILE}
		TRANSACTION_ID=$(${CCLI} transaction data-for-witness --staging ${STAGING_FILE})
		WITNESS_SECRET_FILE="${TMPDIR}/witness.secret.$$"
		WITNESS_OUTPUT_FILE="${TMPDIR}/witness.out.$$"

		echo "${SOURCE_KEY}" > ${WITNESS_SECRET_FILE}
		
		${CCLI} transaction make-witness ${TRANSACTION_ID} \
			--genesis-block-hash ${BLOCK0_HASH} \
			--type "account" --account-spending-counter "${SOURCE_COUNTER}" \
			${WITNESS_OUTPUT_FILE} ${WITNESS_SECRET_FILE}
		${CCLI} transaction add-witness ${WITNESS_OUTPUT_FILE} --staging "${STAGING_FILE}"

		# Finalize the transaction and send it
		${CCLI} transaction seal --staging "${STAGING_FILE}"
		${CCLI} transaction auth -k ${WITNESS_SECRET_FILE} --staging "${STAGING_FILE}"
		TXID=$(${CCLI} transaction to-message --staging "${STAGING_FILE}" | ${CCLI} rest v0 message post --host "${NODE_REST_URL}")

		rm -r ${TMPDIR}

		say "Delegate wallet ${WALLET_NAME} to Pool ${POOL_NAME}" "log"
		say "  Pool-ID:    ${POOLID}" "log"
		say "  Stake:      ${SOURCE_BALANCE_NICE}" "log"
		say "  Fees:       ${AMOUNT_WITH_FEES_NICE}" "log"
		say "  TX-ID:      ${TXID}" "log"
		say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		
	  ;; ###################################################################

	  *)
		usage
		exit 1
	  ;;

	esac

  ;; ###################################################################

  pool)

	if [ ${#} -lt 2 ]; then
		usage
		exit 1
	fi

	SUBCOMMAND=${2}
	
	case $SUBCOMMAND in
	  register)  # [POOL_NAME] [WALLET_OWNER] [WALLET_REWARDS] [TAX_FIXED] [TAX_PERMILLE] [optional:TAX_LIMIT]

    # TODO implement for cardano-node/cli
    echo "Sorry! not ready yet in cntools"
    exit 1
    
    if [ ${#} -lt 7 ]; then
			usagePoolRegister
			exit 1
		fi

		POOL_NAME=${3}
		WALLET_OWNER=${4}
		WALLET_REWARDS=${5}
		TAX_FIXED=${6}
		TAX_PERMILLE=${7}
		TAX_LIMIT=${8}

		if [ -f "$WALLET_FOLDER/${WALLET_OWNER}/ed25519.account" ]; then
			OWNER_ADDRESS=$(cat "${WALLET_FOLDER}/${WALLET_OWNER}/ed25519.account")
			OWNER_KEY=$(cat "${WALLET_FOLDER}/${WALLET_OWNER}/ed25519.key")
			OWNER_PUB=$(cat "${WALLET_FOLDER}/${WALLET_OWNER}/ed25519.pub")
			OWNER_FILE="${WALLET_FOLDER}/${WALLET_OWNER}/ed25519.key"
		else
			echo "Error: no wallet $WALLET_OWNER found (${WALLET_FOLDER}/${WALLET_OWNER}/ed25519.account)"
			exit 1
		fi
		
		if [ -f "$WALLET_FOLDER/${WALLET_REWARDS}/ed25519.account" ]; then
			REWARDS_ADDRESS=$(cat "${WALLET_FOLDER}/${WALLET_REWARDS}/ed25519.account")
			REWARDS_KEY=$(cat "${WALLET_FOLDER}/${WALLET_REWARDS}/ed25519.key")
			REWARDS_PUB=$(cat "${WALLET_FOLDER}/${WALLET_REWARDS}/ed25519.pub")
			REWARDS_FILE="${WALLET_FOLDER}/${WALLET_REWARDS}/ed25519.key"
		else
			echo "Error: no wallet $WALLET_REWARDS found (${WALLET_FOLDER}/${WALLET_REWARDS}/ed25519.account)"
			exit 1
		fi
		
		OWNER_BALANCE=$(${CCLI} rest v0 account get "${OWNER_ADDRESS}" --host "${NODE_REST_URL}" | grep '^value:' | sed -e 's/value: //' )
		if (( OWNER_BALANCE == 0 )); then
			echo "ERROR: wallet $WALLET_OWNER balance is zero"
			exit 1
		fi
		OWNER_BALANCE_NICE=$(printf "%'d Lovelaces" ${OWNER_BALANCE})
		OWNER_COUNTER=$(${CCLI} rest v0 account get "${OWNER_ADDRESS}" --host "${NODE_REST_URL}" | grep '^counter:' | sed -e 's/counter: //' )
		if [ -f "${POOL_FOLDER}/${POOL_NAME}/stake_pool.id" ]; then
			echo "INFO: Pool $POOL_NAME already exists. Register again with same keys and new tax values"
			POOL_REGISTER_NEW=false
		else
			POOL_REGISTER_NEW=true
		fi
		
		if [[ "$TAX_FIXED" =~ ^[0-9]+$ ]]; then
			TAXES=$TAXES" --tax-fixed ${TAX_FIXED}"
		fi
		if [[ "$TAX_PERMILLE" =~ ^[0-9]+$ ]]; then
			TAXES=$TAXES" --tax-ratio ${TAX_PERMILLE}/1000"
		fi
		if [[ "$TAX_LIMIT" =~ ^[0-9]+$ ]]; then
			TAXES=$TAXES" --tax-limit ${TAX_LIMIT}"
		fi
		
		# read the nodes blockchain settings (parameters are required for the next transactions)
		settings="$(curl -s ${NODE_REST_URL}/v0/settings)"
		FEE_CONSTANT=$(echo $settings | jq -r .fees.constant)
		FEE_COEFFICIENT=$(echo $settings | jq -r .fees.coefficient)
		if [ -z "$(echo $settings | grep "certificate_pool_registration")" ]; then
			FEE_CERTIFICATE=$(echo $settings | jq -r .fees.certificate)
		else
			FEE_CERTIFICATE=$(echo $settings | jq -r .fees.per_certificate_fees.certificate_pool_registration)
		fi
		BLOCK0_HASH=$(echo $settings | jq -r .block0Hash)
		AMOUNT_WITH_FEES=$(( FEE_CONSTANT + FEE_COEFFICIENT + FEE_CERTIFICATE ))
		AMOUNT_WITH_FEES_NICE=$(printf "%'d Lovelaces" ${AMOUNT_WITH_FEES})

		if (( OWNER_BALANCE <= AMOUNT_WITH_FEES )); then
			echo "ERROR: owner wallet balance is not sufficient to pay the registration fee"
			exit 1
		fi

		if [ "$POOL_REGISTER_NEW" = true ]; then
			mkdir -p "${POOL_FOLDER}/${POOL_NAME}"

			# generate pool owner wallet
			#${CCLI} key generate --type=Ed25519 > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_owner_wallet.key"
			#cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool_owner_wallet.key" | ${CCLI} key to-public > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_owner_wallet.pub"
			#${CCLI} address account "$(cat ${POOL_FOLDER}/${POOL_NAME}/stake_pool_owner_wallet.pub)" --testing > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_owner_wallet.address"

			# generate pool KES and VRF certificates
			${CCLI} key generate --type=SumEd25519_12 > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_kes.key"
			${CCLI} key to-public > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_kes.pub" < "${POOL_FOLDER}/${POOL_NAME}/stake_pool_kes.key"
			${CCLI} key generate --type=Curve25519_2HashDH > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.key"
			${CCLI} key to-public > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.pub" < "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.key"
		fi

		# build stake pool certificate
		${CCLI} certificate new stake-pool-registration \
		--kes-key $(cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool_kes.pub") \
		--vrf-key $(cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.pub") \
		--owner ${OWNER_PUB} \
		--reward-account ${REWARDS_ADDRESS} \
		--management-threshold 1 \
		--start-validity 0 > "$POOL_FOLDER/${POOL_NAME}/stake_pool.cert" \
		${TAXES}

		# get the stake pool ID
		${CCLI} certificate get-stake-pool-id > "${POOL_FOLDER}/${POOL_NAME}/stake_pool.id" < "${POOL_FOLDER}/${POOL_NAME}/stake_pool.cert"
		POOLID=$(cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool.id")

		# note pool-ID, vrf and KES keys into a secret file
		jq -n '.genesis.node_id = "'$POOLID'" | .genesis.vrf_key = "'$(cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.key")'" | .genesis.sig_key = "'$(cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool_kes.key")'"' > "${POOL_FOLDER}/${POOL_NAME}/secret.yaml"
		
		TMPDIR=$(mktemp -d)
		STAGING_FILE="${TMPDIR}/staging.$$.transaction"
		${CCLI} transaction new --staging ${STAGING_FILE}
		${CCLI} transaction add-account "${OWNER_ADDRESS}" "${AMOUNT_WITH_FEES}" --staging "${STAGING_FILE}"
		${CCLI} transaction add-certificate --staging ${STAGING_FILE} $(cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool.cert")
		${CCLI} transaction finalize --staging ${STAGING_FILE}
		TRANSACTION_ID=$(${CCLI} transaction data-for-witness --staging ${STAGING_FILE})
		WITNESS_SECRET_FILE="${TMPDIR}/witness.secret.$$"
		WITNESS_OUTPUT_FILE="${TMPDIR}/witness.out.$$"
		echo "${OWNER_KEY}" > ${WITNESS_SECRET_FILE}
		
		${CCLI} transaction make-witness ${TRANSACTION_ID} \
			--genesis-block-hash ${BLOCK0_HASH} \
			--type "account" --account-spending-counter "${OWNER_COUNTER}" \
			${WITNESS_OUTPUT_FILE} ${WITNESS_SECRET_FILE}
		${CCLI} transaction add-witness ${WITNESS_OUTPUT_FILE} --staging "${STAGING_FILE}"

		# Finalize the transaction and send it
		${CCLI} transaction seal --staging "${STAGING_FILE}"
		${CCLI} transaction auth -k ${WITNESS_SECRET_FILE} --staging "${STAGING_FILE}"
		TXID=$(${CCLI} transaction to-message --staging "${STAGING_FILE}" | ${CCLI} rest v0 message post --host "${NODE_REST_URL}")

		rm -r ${TMPDIR}

		say "Registered new Pool ${POOL_NAME}" "log"
		say "  Pool-ID:    ${POOLID}" "log"
		say "  Owner:      ${OWNER_PUB}" "log"
		say "  Rewards:    ${REWARDS_ADDRESS}" "log"
		say "  Fees:       ${AMOUNT_WITH_FEES_NICE}" "log"
		say "  TX-ID:      ${TXID}" "log"
		say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

	  ;; ###################################################################

	  show)  # [POOL_ID]
		
		printf '%b\n' $(${CCLI} rest v0 stake-pools get --host "${NODE_REST_URL}" | grep ${3})
	
	  ;; ###################################################################

	  *)
		usage #unknown sub command
		exit 1
	  ;;

	esac
	
  ;; ###################################################################

  *)
	usage #unknown main command
	exit 1
  ;;

esac # main OPERATION
}
   
##############################################################

main "$@"
