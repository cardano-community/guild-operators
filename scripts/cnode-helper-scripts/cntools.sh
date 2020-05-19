#!/bin/bash

# 2020-05-19 cntools initial release (concept)

############### script settings ###################################

. "$(dirname $0)"/env
# get config values from common env file, or set individual (temp) settings:
#CCLI=$(which cardano-cli)
#CNODE_HOME=/opt/cardano/cnode
#CONFIG=$CNODE_HOME/files/cnode_ptn.yaml
#GENESIS_JSON=$CNODE_HOME/files/genesis.json
#MAGIC=$(jq -r .protocolMagicId < $GENESIS_JSON)
#NWMAGIC=$(jq -r .networkMagic < $GENESIS_JSON)

# each wallet and pool has a friendly name and subfolder containing all related keys, certificates, ...
WALLET_FOLDER=$CNODE_HOME"/priv/wallet"
POOL_FOLDER=$CNODE_HOME"/priv/pool"
# standardized names for all wallet/pool related files 
WALLET_VKS_FILENAME="VerificationKeyShelley.vkey"
WALLET_SKS_FILENAME="SigningKeyShelley.skey"
WALLET_PAY_FILENAME="Payment.addr"
#POOL_...
PROTECT_SIGN_KEYS="yes"

# log cntools activities (comment out to disable)
CNTOOLS_LOG=${CNODE_HOME}/logs/cntools-history.log

# for binary install/update function
CNODE_BIN_HOME="${HOME}/.cabal/bin/"
# update from asset (todo as soon as binary releases are available)
#ASSET_PLATTFORM="x86_64-unknown-linux-gnu-generic"		# Debian, Ubuntu, CentOS 8,...
#ASSET_PLATTFORM="x86_64-unknown-linux-musl"	# CentOS 7, ...
#ASSET_PLATTFORM="aarch64-unknown-linux-gnu" 	# Armbian, Raspian, RockPi, ARM 64bit, ...

# decimal separators for readable lovelace values
DD="."  # Decimal point delimiter, to separate whole and fractional values
TD=","  # Add thousands separator using (,) to separate every three digits

#coloured console output
GREEN="\e[1;32m"; RED="\e[1;31m"; ORANGE="\e[33;5m"; NC="\e[0m"; CYAN="\e[0;36m"; LGRAY1="\e[1;37m"; LGRAY="\e[2;37m";

###################################################################


usage() {
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "Usage:"
    echo ""
    echo "   $0 update [optional:DESIRED_RELEASE_TAG]"
    echo ""
    echo "   $0 wallet new [WALLET_NAME] [optional:WALLET_TYPE]"
    echo "   $0 wallet list"
    echo "   $0 wallet show [WALLET_NAME]"
    echo "   $0 wallet remove [WALLET_NAME]"
    echo ""
    echo "   $0 funds send [SOURCE_WALLET] [AMOUNT] [DESTINATION_ADDRESS|WALLET]"
    echo "           Note: Amount is an Integer value in Lovelaces"
    echo ""
    echo "   $0 pool register [POOL_NAME] [WALLET_OWNER] [WALLET_REWARDS] "
	echo "                    [TAX_FIXED] [TAX_PERMILLE] [optional:TAX_LIMIT]"
    echo "           Note: you can use the same wallet for owner and rewards"
    echo ""
    echo "   $0 stake delegate [WALLET_NAME] [POOL_NAME] [WALLET_TXFEE]"
    echo ""
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}


function main {

if [ ${#} -lt 1 ]; then
    usage ${0}
    exit 1
fi

# check for required command line tools
need_cmd "curl"
need_cmd "jq"

if [ "${PROTECT_SIGN_KEYS}" == "yes" ]; then
	need_cmd "7z"
fi

OPERATION=${1}
case $OPERATION in

  update) # not ready yet. ToDo when binary releases become available
	
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
			read -n 1 -p "Would you like to upgrade to this release? (y/N)? " answer
			case ${answer:0:1} in
				y|Y )
					FILE="cardano-node-"${DESIRED_RELEASE}"-"${ASSET_PLATTFORM}".tar.gz"
					URL="https://github.com/input-output-hk/cardano-node/releases/download/"${DESIRED_RELEASE}"/"${FILE}
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
		read -n 1 -p "Would you like to install this release? (Y/n)? " answer
		case ${answer:0:1} in
			n|N )
				say "Well, that was a pleasant but brief pleasure. Bye bye!"
			;;
			* )
				FILE="cardano-node-"${DESIRED_RELEASE}"-"${ASSET_PLATTFORM}".tar.gz"
				URL="https://github.com/input-output-hk/cardano-node/releases/download/"${DESIRED_RELEASE}"/"${FILE}
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

	SUBCOMMAND=${2}
	
	case $SUBCOMMAND in
	  new) # [WALLET_NAME] [WALLET_TYPE]
	
		if [ ${#} -lt 3 ]; then
			usage ${0}
			exit 1
		fi

		WALLET_NAME=${3}
		WALLET_PREFIX=${4}
		mkdir -p "${WALLET_FOLDER}/${WALLET_NAME}"
		
		if [  -f "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_VKS_FILENAME}" ]; then
			say "WARN: A wallet $WALLET_NAME already exists"
			say "      Choose another name or delete the existing one"
			exit 1
		fi
		
		# create a personal wallet key
		MY_vkey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_VKS_FILENAME}"
		MY_skey_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_SKS_FILENAME}"
		MY_payment_file="${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}"
		
		${CCLI} shelley address key-gen --verification-key-file $MY_vkey_file --signing-key-file $MY_skey_file
		if [ "${PROTECT_SIGN_KEYS}" == "yes" ]; then
			MY_ZIP_PASS="12345"
			$(7z a ${MY_skey_file}.7z ${WALLET_FOLDER}/${WALLET_NAME}/*.skey -sdel -p${MY_ZIP_PASS})
		fi
		# TODO build different 
		${CCLI} shelley address build --payment-verification-key-file $MY_vkey_file > $MY_payment_file

		
		say "New wallet ${LGRAY1}${WALLET_NAME}${NC}" "log"
		say "address:     $(cat $MY_payment_file)" "log"
		echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo ""

	  ;; ###################################################################
	
	  list) # no parameters
	  
		for WALLET_FOLDER_NAME in ${WALLET_FOLDER}/*/     
		do
			WALLET_NAME=${WALLET_FOLDER_NAME%*/} 
			if [ -f "${WALLET_FOLDER_NAME}${WALLET_PAY_FILENAME}" ]; then
				WALLET_ADDRESS=$(cat ${WALLET_FOLDER_NAME}${WALLET_PAY_FILENAME})
				# TODO: sum up multiple utxo's
				WALLET_BALANCE=$(${CCLI} shelley query filtered-utxo --testnet-magic $NWMAGIC --address ${WALLET_ADDRESS} | tail -n +3 | awk '{ print $3 }' )
				WALLET_BALANCE_NICE=$(printf "%'d Lovelaces" ${WALLET_BALANCE})
				say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
				say "Address: ${WALLET_ADDRESS}"
				say "Balance: ${WALLET_BALANCE_NICE}"
				echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
				echo ""
			else
				say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
				say "Warn: missing wallet address file:"
				say "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}"
				echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
				echo ""
			fi
		done

		
	  ;; ###################################################################
	
	  show) # [WALLET_NAME]
		
		WALLET_NAME=${3}
		
		if [ -f "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}" ]; then
			WALLET_ADDRESS=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}")
			WALLET_BALANCE=$(${CCLI} shelley query filtered-utxo --testnet-magic $NWMAGIC --address ${WALLET_ADDRESS} | tail -n +3 | awk '{ print $3 }' )
			WALLET_BALANCE_NICE=$(printf "%'d Lovelaces" ${WALLET_BALANCE})
			say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
			say "  Address: ${WALLET_ADDRESS}"
			say "  Balance: ${WALLET_BALANCE_NICE}"
			echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
			echo ""
			
		else
			say "Wallet: ${LGRAY1}${WALLET_NAME##*/}${NC} "
			say "Warn: missing wallet address file:"
			say "${WALLET_FOLDER}/${WALLET_NAME}/${WALLET_PAY_FILENAME}"
			echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
			echo ""
		fi
		
	  ;; ###################################################################
	
	  remove) # [WALLET_NAME]
	
		if [ ${#} -lt 3 ]; then
			usage ${0}
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
				read -n 1 -p "Are you sure to delete secret/public key pairs (y/n)? " answer
				case ${answer:0:1} in
					y|Y )
						rm -rf "${WALLET_FOLDER}/${WALLET_NAME}"
						say "\nremoved ${WALLET_NAME}"
					;;
					* )
						echo -e "\nskipped removal process for $WALLET_NAME"
					;;
				esac
			else
				if [[ ${WALLET_BALANCE} == "0" ]]; then
					say "INFO: found local wallet file with current balance 0"
					rm -r "${WALLET_FOLDER}/${WALLET_NAME}"
					echo "removed ${WALLET_NAME}"
				else
					say "${RED}WARN: this wallet file has a balance of ${WALLET_BALANCE_NICE}${NC}"
					say "${RED}WARN: By deleting this keys you can no longer access the wallet${NC}"
					read -n 1 -p "      Are you sure to delete secret/public key pairs (y/n)? " answer
					case ${answer:0:1} in
						y|Y )
							rm -rf "${WALLET_FOLDER}/${WALLET_NAME}"
							echo -e "\nremoved ${WALLET_NAME}"
						;;
						* )
							echo -e "\nskipped removal process for $WALLET_NAME"
						;;
					esac
				fi
			fi
		else
			say "INFO: no wallet $WALLET_NAME found"
			exit 1
		fi
		
	  ;; ###################################################################

	  *)
		usage ${0}
		exit 1
	  ;;

	esac
	  
  ;; ###################################################################

  funds)
  
	SUBCOMMAND=${2}

	# TODO implement for cardano-node/cli
	echo "Sorry! not ready yet in cntools"
	exit 1

	case $SUBCOMMAND in
	  send) #[SOURCE_WALLET] [AMOUNT] [DESTINATION_WALLET|ADDRESS]

		if [ ${#} -lt 5 ]; then
			usage ${0}
			exit 1
		fi
		
		WALLET_NAME=${3}
		
		if [ -f "${WALLET_FOLDER}/${WALLET_NAME}/ed25519.account" ]; then
			SOURCE_ADDRESS=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/ed25519.account")
			SOURCE_KEY=$(cat "${WALLET_FOLDER}/${WALLET_NAME}/ed25519.key")
		else
			echo "Error: no source wallet $WALLET_NAME found"
			usage ${0}
			exit 1
		fi
		
		if [ ${4} -eq ${4} 2>/dev/null ]; then 
			AMOUNT=${4}
			AMOUNT_NICE=$(printf "%'d Lovelaces" ${AMOUNT})
		else
			echo "ERROR: $(AMOUNT) is no valid (integer) amount"
			usage ${0}
			exit 1
		fi

		if [ ${#5} -gt "61" ]; then # looks like a 62+ char account address
			DESTINATION_ADDRESS=${5}
		else # look for a local wallet account address
			if [ -f "$WALLET_FOLDER/${5}/ed25519.account" ]; then
				DESTINATION_ADDRESS=$(cat "$WALLET_FOLDER/${5}/ed25519.account")
			else
				echo "Error: no destination wallet ${5} found"
				usage ${0}
				exit 1
			fi
		fi
		
		# get the source wallet's state
		SOURCE_BALANCE=$(${CCLI} rest v0 account get "${SOURCE_ADDRESS}" --host "${NODE_REST_URL}" | grep '^value:' | sed -e 's/value: //' )
		if (( $SOURCE_BALANCE == 0 )); then
			echo "ERROR: source wallet balance is zero"
			exit 1
		fi
		SOURCE_BALANCE_NICE=$(printf "%'d Lovelaces" ${SOURCE_BALANCE})
		SOURCE_COUNTER=$(${CCLI} rest v0 account get "${SOURCE_ADDRESS}" --host "${NODE_REST_URL}" | grep '^counter:' | sed -e 's/counter: //' )
		
		# read the nodes blockchain settings (parameters are required for the next transactions)
		settings="$(curl -s ${NODE_REST_URL}/v0/settings)"
		FEE_CONSTANT=$(echo $settings | jq -r .fees.constant)
		FEE_COEFFICIENT=$(echo $settings | jq -r .fees.coefficient)
		FEE_CERTIFICATE=$(echo $settings | jq -r .fees.certificate)
		BLOCK0_HASH=$(echo $settings | jq -r .block0Hash)
		FEES=$((${FEE_CONSTANT} + 2 * ${FEE_COEFFICIENT}))
		FEES_NICE=$(printf "%'d Lovelaces" ${FEES})
		AMOUNT_WITH_FEES=$((${AMOUNT} + ${FEES}))

		if (( $AMOUNT_WITH_FEES = $SOURCE_BALANCE )); then
			echo "ERROR: source wallet ($SOURCE_BALANCE) has not enough funds to send $AMOUNT and pay $((${FEE_CONSTANT} + 2 * ${FEE_COEFFICIENT})) in fees"
			exit 1
		fi

		TMPDIR=$(mktemp -d)
		STAGING_FILE="${TMPDIR}/staging.$$.transaction"
		${CCLI} transaction new --staging ${STAGING_FILE}
		${CCLI} transaction add-account "${SOURCE_ADDRESS}" "${AMOUNT_WITH_FEES}" --staging "${STAGING_FILE}"
		${CCLI} transaction add-output "${DESTINATION_ADDRESS}" "${AMOUNT}" --staging "${STAGING_FILE}"
		${CCLI} transaction finalize --staging ${STAGING_FILE}
		TRANSACTION_ID=$(${CCLI} transaction data-for-witness --staging ${STAGING_FILE})
		WITNESS_SECRET_FILE="${TMPDIR}/witness.secret.$$"
		WITNESS_OUTPUT_FILE="${TMPDIR}/witness.out.$$"

		printf "${SOURCE_KEY}" > ${WITNESS_SECRET_FILE}

		${CCLI} transaction make-witness ${TRANSACTION_ID} \
			--genesis-block-hash ${BLOCK0_HASH} \
			--type "account" --account-spending-counter "${SOURCE_COUNTER}" \
			${WITNESS_OUTPUT_FILE} ${WITNESS_SECRET_FILE}
		${CCLI} transaction add-witness ${WITNESS_OUTPUT_FILE} --staging "${STAGING_FILE}"

		# Finalize the transaction and send it
		${CCLI} transaction seal --staging "${STAGING_FILE}"
		TXID=$(${CCLI} transaction to-message --staging "${STAGING_FILE}" | ${CCLI} rest v0 message post --host "${NODE_REST_URL}")

		rm -r ${TMPDIR}

		say "Transaction ${WALLET_NAME} > ${DESTINATION_ADDRESS}" "log"
		say "  From:       ${SOURCE_ADDRESS}" "log"
		say "  Balance:    ${SOURCE_BALANCE_NICE}" "log"
		say "  Amount:     ${AMOUNT_NICE}" "log"
		say "  To:         ${DESTINATION_ADDRESS}" "log"
		say "  Fees:       ${FEES_NICE}" "log"
		say "  TX-ID:      ${TXID}" "log"
		say "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

	
	  ;; ###################################################################
	
	  *)
		usage ${0} #unknown sub command
		exit 1
	  ;;

	esac

  ;; ###################################################################

  pool)

	# TODO implement for cardano-node/cli
	echo "Sorry! not ready yet in cntools"
	exit 1

	if [ ${#} -lt 3 ]; then
		usage ${0}
		exit 1
	fi

	SUBCOMMAND=${2}
	
	case $SUBCOMMAND in
	  register)  # [POOL_NAME] [WALLET_OWNER] [WALLET_REWARDS] [TAX_FIXED] [TAX_PERMILLE] [optional:TAX_LIMIT]

		POOL_NAME=${3}
		WALLET_OWNER=${4}
		WALLET_REWARDS=${5}
		TAX_FIXED=${6}
		TAX_PERMILLE=${7}
		TAX_LIMIT=${8}

		if [ ${#} -lt 7 ]; then
			usage ${0}
			exit 1
		fi

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
		if (( $OWNER_BALANCE == 0 )); then
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
		AMOUNT_WITH_FEES=$((${FEE_CONSTANT} + ${FEE_COEFFICIENT} + ${FEE_CERTIFICATE}))
		AMOUNT_WITH_FEES_NICE=$(printf "%'d Lovelaces" ${AMOUNT_WITH_FEES})

		if (( $OWNER_BALANCE <= AMOUNT_WITH_FEES )); then
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
			cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool_kes.key" | ${CCLI} key to-public > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_kes.pub"
			${CCLI} key generate --type=Curve25519_2HashDH > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.key"
			cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.key" | ${CCLI} key to-public > "${POOL_FOLDER}/${POOL_NAME}/stake_pool_vrf.pub"
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
		cat "${POOL_FOLDER}/${POOL_NAME}/stake_pool.cert" | ${CCLI} certificate get-stake-pool-id > "${POOL_FOLDER}/${POOL_NAME}/stake_pool.id"
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
		printf "${OWNER_KEY}" > ${WITNESS_SECRET_FILE}
		
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
		usage ${0} #unknown sub command
		exit 1
	  ;;

	esac
	
  ;; ###################################################################

  stake)

	# TODO implement for cardano-node/cli
	echo "Sorry! not ready yet in cntools"
	exit 1

	if [ ${#} -lt 3 ]; then
		usage ${0}
		exit 1
	fi

	SUBCOMMAND=${2}
	
	case $SUBCOMMAND in
	  delegate)  # [WALLET_NAME] [POOL_NAME]
		
		WALLET_NAME=${3}
		POOL_NAME=${4}
		
		if [ ${#} -lt 4 ]; then
			usage ${0}
			exit 1
		fi
		
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
		if (( $SOURCE_BALANCE == 0 )); then
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
		AMOUNT_WITH_FEES=$((${FEE_CONSTANT} + ${FEE_COEFFICIENT} + ${FEE_CERTIFICATE}))
		AMOUNT_WITH_FEES_NICE=$(printf "%'d Lovelaces" ${AMOUNT_WITH_FEES})
		if (( $SOURCE_BALANCE <= AMOUNT_WITH_FEES )); then
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

		printf "${SOURCE_KEY}" > ${WITNESS_SECRET_FILE}
		
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
		usage ${0} #unknown sub command
		exit 1
	  ;;

	esac
	
  ;; ###################################################################

  *)
	usage ${0} #unknown main command
	exit 1
  ;;

esac # main OPERATION
}


need_cmd() {
	if ! check_cmd "$1"; then
		echo "WARN: need '$1' (command not found)"
		echo "try 'sudo apt install $1'"
		exit 1
	fi
}

check_cmd() {
	command -v "$1" > /dev/null 2>&1
}

say() {
	echo -e $1
	if [[ $2 == "log" && "${CNTOOLS_LOG}" != "" ]]; then 
		echo "$(date -Iseconds) - $1" >> ${CNTOOLS_LOG}
	fi
}

   
##############################################################

main "$@"
